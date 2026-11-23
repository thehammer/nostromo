//! The MCP panel's daemon half: `mcp_status`, `mcp_reconnect` and `mcp_toggle`
//! through a session's CLI, answered as `ServerMsg::SessionMcpResult`.
//!
//! Three rules shape this module:
//!
//! * **No configuration leaves.** A server's `config` can hold env values,
//!   headers, URLs and command lines. [`McpServerView::from_cli`] is the only
//!   place a CLI server entry becomes wire data, and it reads name, status,
//!   scope, source, transport, the tool count and a scrubbed error: nothing else.
//! * **Explicit, rate-limited.** One reconnect or toggle in flight per
//!   (session, server) and 5 s between starts; `status` is served from the
//!   last list when asked again within 1 s. The limits live here, so a client
//!   that ignores its own cannot hammer a CLI.
//! * **Honest outcomes.** A timeout, an old CLI, a CLI refusal and a session
//!   that is not running each get their own outcome.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::control::{
    control_within, says_unsupported, ControlFailure, CONTROL_TIMEOUT, SESSION_EXITED,
};
use super::{Shared, TOOLS_RECONNECT_TIMEOUT};
use crate::data::work::untrusted::sanitize_block;
use crate::ipc::protocol::{McpAction, McpOutcome, McpServerView};
use crate::ipc::task_output::truncate_chars;
use crate::mcp::socket::MCP_SERVER_NAME;

/// Least time between two reconnects or toggles of one server of one session.
pub const ACTION_GAP: Duration = Duration::from_secs(5);
/// Least time between two real `mcp_status` calls for one session.
pub const STATUS_GAP: Duration = Duration::from_secs(1);
/// How long a session's limiter entry is kept once nothing is running and nothing is recent.
pub const LIMITER_TTL: Duration = Duration::from_secs(60);

const NAME_CHARS: usize = 128;
const WORD_CHARS: usize = 32;
const ERROR_CHARS: usize = 240;
const MAX_SERVERS: usize = 200;

const NOT_RUNNING: &str = "the session is not running";
const TOO_OLD: &str = "this Claude Code is too old for MCP control";

/// What one request ends with.
#[derive(Debug, Clone, PartialEq)]
pub struct McpReply {
    pub outcome: McpOutcome,
    pub message: Option<String>,
    pub servers: Option<Vec<McpServerView>>,
}

impl McpReply {
    fn plain(outcome: McpOutcome, message: impl Into<String>) -> Self {
        Self {
            outcome,
            message: Some(message.into()),
            servers: None,
        }
    }
}

#[derive(Default)]
struct TagLimits {
    status_at: Option<Instant>,
    last_list: Option<Vec<McpServerView>>,
    actions: HashMap<String, ActionSlot>,
    /// Held for the length of a real `status` fetch: a second caller waits here
    /// and then reuses the list the first one stored.
    fetch: Arc<tokio::sync::Mutex<()>>,
}

impl TagLimits {
    /// Nothing here is running or recent: the entry can go.
    fn is_idle(&self, ttl: Duration) -> bool {
        self.status_at.is_none_or(|at| at.elapsed() >= ttl)
            && self
                .actions
                .values()
                .all(|a| !a.in_flight && a.started.elapsed() >= ttl)
            && Arc::strong_count(&self.fetch) == 1
    }
}

/// Holds one (session, server) in-flight slot and gives it back when dropped,
/// so a request whose future is dropped never leaves the server "already running".
pub struct ActionGuard {
    panel: McpPanelState,
    tag: String,
    server: String,
}

impl Drop for ActionGuard {
    fn drop(&mut self) {
        self.panel.release_action(&self.tag, &self.server);
    }
}

struct ActionSlot {
    started: Instant,
    in_flight: bool,
}

/// The per-session limiter state and the waits, shared by clones.
#[derive(Clone)]
pub struct McpPanelState {
    tags: Arc<Mutex<HashMap<String, TagLimits>>>,
    control_timeout: Duration,
    reconnect_timeout: Duration,
    ttl: Duration,
}

impl Default for McpPanelState {
    fn default() -> Self {
        Self {
            tags: Arc::default(),
            control_timeout: CONTROL_TIMEOUT,
            reconnect_timeout: TOOLS_RECONNECT_TIMEOUT,
            ttl: LIMITER_TTL,
        }
    }
}

impl McpPanelState {
    /// Shorten both waits (a test hook).
    pub fn with_timeouts(mut self, wait: Duration) -> Self {
        self.control_timeout = wait;
        self.reconnect_timeout = wait;
        self
    }

    /// Shorten how long an idle session's entry is kept (a test hook).
    pub fn with_limiter_ttl(mut self, ttl: Duration) -> Self {
        self.ttl = ttl;
        self
    }

    /// How many sessions have limiter state (a test hook).
    pub fn tracked_sessions(&self) -> usize {
        self.tags.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    fn limits<R>(&self, tag: &str, f: impl FnOnce(&mut TagLimits) -> R) -> R {
        let mut tags = self.tags.lock().unwrap_or_else(|e| e.into_inner());
        // Entries of sessions that went quiet are dropped here, on the next request of any session.
        let ttl = self.ttl;
        tags.retain(|name, t| name == tag || !t.is_idle(ttl));
        f(tags.entry(tag.to_owned()).or_default())
    }

    /// Reserve the one in-flight slot of (`tag`, `server`), or say how long to wait.
    /// The slot is released when the guard drops.
    fn reserve_action(&self, tag: &str, server: &str) -> Result<ActionGuard, String> {
        self.limits(tag, |t| {
            if let Some(slot) = t.actions.get(server) {
                if slot.in_flight {
                    return Err(format!(
                        "a request for {} is already running",
                        log_name(server)
                    ));
                }
                let since = slot.started.elapsed();
                if since < ACTION_GAP {
                    let left = (ACTION_GAP - since).as_secs_f64().ceil() as u64;
                    return Err(format!(
                        "wait {left} s before trying {} again",
                        log_name(server)
                    ));
                }
            }
            t.actions.insert(
                server.to_owned(),
                ActionSlot {
                    started: Instant::now(),
                    in_flight: true,
                },
            );
            Ok(())
        })?;
        Ok(ActionGuard {
            panel: self.clone(),
            tag: tag.to_owned(),
            server: server.to_owned(),
        })
    }

    fn release_action(&self, tag: &str, server: &str) {
        self.limits(tag, |t| {
            if let Some(slot) = t.actions.get_mut(server) {
                slot.in_flight = false;
            }
        });
    }

    /// The last list, when a real `status` ran less than [`STATUS_GAP`] ago.
    fn fresh_list(&self, tag: &str) -> Option<Vec<McpServerView>> {
        self.limits(tag, |t| match (t.status_at, &t.last_list) {
            (Some(at), Some(list)) if at.elapsed() < STATUS_GAP => Some(list.clone()),
            _ => None,
        })
    }

    /// The lock a real `status` fetch holds, so concurrent callers share one fetch.
    fn fetch_lock(&self, tag: &str) -> Arc<tokio::sync::Mutex<()>> {
        self.limits(tag, |t| Arc::clone(&t.fetch))
    }

    fn keep_list(&self, tag: &str, list: &[McpServerView]) {
        self.limits(tag, |t| {
            t.status_at = Some(Instant::now());
            t.last_list = Some(list.to_vec());
        });
    }
}

impl McpServerView {
    /// A CLI `mcpServers` entry as wire data, or `None` without a name. Reads
    /// only the keys below and never touches `config`, `serverInfo` or `urlHost`.
    pub fn from_cli(entry: &Value) -> Option<Self> {
        let name = one_line_capped(entry.get("name")?.as_str()?, NAME_CHARS);
        if name.is_empty() {
            return None;
        }
        let word = |key: &str| {
            entry
                .get(key)
                .and_then(Value::as_str)
                .map(|s| one_line_capped(s, WORD_CHARS))
                .filter(|s| !s.is_empty())
        };
        Some(Self {
            status: word("status").unwrap_or_else(|| "unknown".to_owned()),
            scope: word("scope"),
            source: word("source"),
            transport: word("transport"),
            tool_count: entry
                .get("tools")
                .and_then(Value::as_array)
                .map(|t| u32::try_from(t.len()).unwrap_or(u32::MAX)),
            error: entry
                .get("error")
                .and_then(Value::as_str)
                .map(scrub_text)
                .filter(|s| !s.is_empty()),
            nostromo_bridge: None,
            name,
        })
    }
}

/// A server name as one line in a log: no control characters, bounded.
pub fn log_name(name: &str) -> String {
    one_line_capped(name, 64)
}

fn one_line_capped(text: &str, max: usize) -> String {
    let flat: String = sanitize_block(text)
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    truncate_chars(flat.trim(), max)
}

/// CLI text that may reach the screen: sanitised, URL query strings and
/// fragments cut, secrets redacted, capped.
fn scrub_text(text: &str) -> String {
    let clean = sanitize_block(text);
    let cut = cut_url_tails(&clean);
    let (redacted, _) = crate::terminal::redact::Redactor::new().redact(&cut);
    let flat: String = redacted
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    truncate_chars(flat.trim(), ERROR_CHARS)
}

/// Remove `?query` and `#fragment` from every `scheme://…` in `text`.
fn cut_url_tails(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find("://") {
        let (head, tail) = rest.split_at(at + 3);
        out.push_str(head);
        let end = tail
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ')' | '>' | '<'))
            .unwrap_or(tail.len());
        let (url, after) = tail.split_at(end);
        let keep = url.find(['?', '#']).unwrap_or(url.len());
        out.push_str(&url[..keep]);
        rest = after;
    }
    out.push_str(rest);
    out
}

/// What [`begin`] settled synchronously.
enum Step {
    Done(McpReply),
    Run(Box<Job>),
}

struct Job {
    /// The in-flight slot of a reconnect or toggle; released when the job ends or is dropped.
    guard: Option<ActionGuard>,
    panel: McpPanelState,
    shared: Shared,
    bridges: Option<Arc<crate::mcp::BridgeRegistry>>,
    tag: String,
    kind: JobKind,
}

enum JobKind {
    Status,
    Reconnect { server: String },
    Toggle { server: String, enabled: bool },
}

/// Decide the request now (checks and limits under the caller's lock), and
/// return the future that does the CLI work without it.
pub(super) fn begin(
    panel: McpPanelState,
    shared: Option<Shared>,
    bridges: Option<Arc<crate::mcp::BridgeRegistry>>,
    tag: &str,
    action: McpAction,
    server: Option<String>,
    enabled: Option<bool>,
) -> impl std::future::Future<Output = McpReply> + Send + 'static {
    let step = decide(panel, shared, bridges, tag, action, server, enabled);
    async move {
        match step {
            Step::Done(reply) => reply,
            Step::Run(job) => job.run().await,
        }
    }
}

fn decide(
    panel: McpPanelState,
    shared: Option<Shared>,
    bridges: Option<Arc<crate::mcp::BridgeRegistry>>,
    tag: &str,
    action: McpAction,
    server: Option<String>,
    enabled: Option<bool>,
) -> Step {
    let invalid = |why: &str| Step::Done(McpReply::plain(McpOutcome::Invalid, why));
    let Some(shared) = shared else {
        return Step::Done(McpReply::plain(McpOutcome::NotRunning, NOT_RUNNING));
    };
    let server = server.filter(|s| !s.trim().is_empty());
    if server.as_deref().is_some_and(|s| s.chars().count() > 256) {
        return invalid("the server name is too long");
    }
    let kind = match (action, server, enabled) {
        (McpAction::Status, ..) => {
            if let Some(mut list) = panel.fresh_list(tag) {
                mark_bridge(&mut list, bridges.as_deref(), tag);
                return Step::Done(McpReply {
                    outcome: McpOutcome::Ok,
                    message: None,
                    servers: Some(list),
                });
            }
            JobKind::Status
        }
        (McpAction::Reconnect, Some(server), _) => JobKind::Reconnect { server },
        (McpAction::Toggle, Some(server), Some(enabled)) => {
            if !enabled && server == MCP_SERVER_NAME {
                return invalid("Nostromo's own tools cannot be disabled from here");
            }
            JobKind::Toggle { server, enabled }
        }
        (McpAction::Reconnect | McpAction::Toggle, None, _) => {
            return invalid("this request needs a server name")
        }
        (McpAction::Toggle, Some(_), None) => return invalid("toggle needs enabled or disabled"),
        (McpAction::Unknown, ..) => return invalid("unknown MCP action"),
    };
    let mut guard = None;
    if let JobKind::Reconnect { server } | JobKind::Toggle { server, .. } = &kind {
        match panel.reserve_action(tag, server) {
            Ok(g) => guard = Some(g),
            Err(wait) => return Step::Done(McpReply::plain(McpOutcome::RateLimited, wait)),
        }
    }
    Step::Run(Box::new(Job {
        guard,
        panel,
        shared,
        bridges,
        tag: tag.to_owned(),
        kind,
    }))
}

fn mark_bridge(
    list: &mut [McpServerView],
    bridges: Option<&crate::mcp::BridgeRegistry>,
    tag: &str,
) {
    let up = bridges.and_then(|b| b.connected(tag));
    for server in list.iter_mut().filter(|s| s.name == MCP_SERVER_NAME) {
        server.nostromo_bridge = up;
    }
}

impl Job {
    async fn run(mut self) -> McpReply {
        match &self.kind {
            JobKind::Status => {
                // One real fetch at a time per session: a caller that waited reuses the list the
                // first one stored, so two requests at once reach the CLI once.
                let lock = self.panel.fetch_lock(&self.tag);
                let _fetching = lock.lock().await;
                if let Some(mut list) = self.panel.fresh_list(&self.tag) {
                    mark_bridge(&mut list, self.bridges.as_deref(), &self.tag);
                    return ok(Some(list), None);
                }
                match self.fetch_list().await {
                    Ok(list) => ok(Some(list), None),
                    Err(failure) => classify(failure),
                }
            }
            JobKind::Reconnect { server } => {
                let result = self
                    .call(
                        json!({"subtype": "mcp_reconnect", "serverName": server}),
                        self.panel.reconnect_timeout,
                    )
                    .await;
                self.guard.take();
                match result {
                    Ok(()) => self.then_list(None).await,
                    Err(failure) => classify(failure),
                }
            }
            JobKind::Toggle { server, enabled } => {
                let result = self
                    .call(
                        json!({"subtype": "mcp_toggle", "serverName": server, "enabled": enabled}),
                        self.panel.control_timeout,
                    )
                    .await;
                self.guard.take();
                match result {
                    Ok(()) => self.then_list(None).await,
                    // Enabling a server that cannot connect answers an error,
                    // yet the enable took effect: the list decides.
                    Err(failure) if failure.refused && !says_unsupported(&failure.reason) => {
                        let text = scrub_text(&failure.reason);
                        match self.fetch_list().await {
                            Ok(list) if self.has_state(&list, server, *enabled) => {
                                ok(Some(list), Some(text))
                            }
                            Ok(list) => McpReply {
                                outcome: McpOutcome::Refused,
                                message: Some(text),
                                servers: Some(list),
                            },
                            Err(_) => McpReply::plain(McpOutcome::Refused, text),
                        }
                    }
                    Err(failure) => classify(failure),
                }
            }
        }
    }

    fn has_state(&self, list: &[McpServerView], server: &str, enabled: bool) -> bool {
        list.iter()
            .find(|s| s.name == *server)
            .is_some_and(|s| (s.status == "disabled") != enabled)
    }

    async fn call(&self, request: Value, wait: Duration) -> Result<(), ControlFailure> {
        control_within(&self.shared, request, wait)
            .await
            .map(|_| ())
    }

    /// The fresh list after a change that succeeded. If only the list fails,
    /// the change still happened: say so.
    async fn then_list(&self, note: Option<String>) -> McpReply {
        match self.fetch_list().await {
            Ok(list) => ok(Some(list), note),
            Err(failure) => McpReply {
                outcome: McpOutcome::Ok,
                message: Some(format!(
                    "Done, but the list could not be refreshed: {}",
                    scrub_text(&failure.reason)
                )),
                servers: None,
            },
        }
    }

    async fn fetch_list(&self) -> Result<Vec<McpServerView>, ControlFailure> {
        let reply = control_within(
            &self.shared,
            json!({"subtype": "mcp_status"}),
            self.panel.control_timeout,
        )
        .await?;
        let mut list: Vec<McpServerView> = reply
            .body
            .get("mcpServers")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(McpServerView::from_cli)
                    .take(MAX_SERVERS)
                    .collect()
            })
            .unwrap_or_default();
        self.panel.keep_list(&self.tag, &list);
        mark_bridge(&mut list, self.bridges.as_deref(), &self.tag);
        Ok(list)
    }
}

fn ok(servers: Option<Vec<McpServerView>>, message: Option<String>) -> McpReply {
    McpReply {
        outcome: McpOutcome::Ok,
        message,
        servers,
    }
}

fn classify(failure: ControlFailure) -> McpReply {
    if failure.timed_out {
        return McpReply::plain(McpOutcome::Timeout, scrub_text(&failure.reason));
    }
    if failure.reason == SESSION_EXITED {
        return McpReply::plain(McpOutcome::NotRunning, NOT_RUNNING);
    }
    if says_unsupported(&failure.reason) {
        return McpReply::plain(McpOutcome::Unsupported, TOO_OLD);
    }
    McpReply::plain(McpOutcome::Refused, scrub_text(&failure.reason))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_queries_and_fragments_are_cut_but_the_path_stays() {
        assert_eq!(
            cut_url_tails("502 from https://x.example/mcp?key=abc#frag (retry)"),
            "502 from https://x.example/mcp (retry)"
        );
        assert_eq!(cut_url_tails("no url here"), "no url here");
    }

    #[test]
    fn a_view_reads_only_the_listed_keys() {
        let v = McpServerView::from_cli(&json!({
            "name": "s", "status": "weird", "config": {"env": {"K": "SECRET"}},
            "serverInfo": {"name": "SECRET"}, "urlHost": "SECRET", "extra": 1,
            "tools": [{}, {}], "transport": "stdio", "scope": "user"
        }))
        .unwrap();
        let wire = serde_json::to_string(&v).unwrap();
        assert!(!wire.contains("SECRET"));
        assert_eq!(v.tool_count, Some(2));
        assert_eq!(v.status, "weird");
    }

    #[test]
    fn a_dropped_guard_frees_the_slot_but_a_held_one_blocks() {
        let panel = McpPanelState::default();
        let guard = panel.reserve_action("t", "s").unwrap();
        assert!(panel
            .reserve_action("t", "s")
            .err()
            .unwrap()
            .contains("already running"));
        drop(guard);
        assert!(!panel
            .reserve_action("t", "s")
            .err()
            .unwrap()
            .contains("already running"));
    }

    #[test]
    fn idle_sessions_are_pruned_and_busy_ones_are_not() {
        let panel = McpPanelState::default().with_limiter_ttl(Duration::ZERO);
        let busy = panel.reserve_action("busy", "s").unwrap();
        let done = panel.reserve_action("done", "s").unwrap();
        drop(done);
        assert_eq!(panel.tracked_sessions(), 2);
        // The next request, for any session, drops the idle "done" and keeps the busy one.
        panel.fetch_lock("other");
        assert_eq!(panel.tracked_sessions(), 2, "busy and other; done is gone");
        drop(busy);
        panel.fetch_lock("other");
        assert_eq!(
            panel.tracked_sessions(),
            1,
            "only the one being asked about"
        );
    }

    #[test]
    fn a_session_whose_first_fetch_is_running_is_not_pruned() {
        let panel = McpPanelState::default().with_limiter_ttl(Duration::ZERO);
        // The fetch lock is out with a caller: no list, no action, nothing "recent", but it is running.
        let fetching = panel.fetch_lock("fetching");
        panel.fetch_lock("other");
        assert_eq!(panel.tracked_sessions(), 2, "the fetching session stays");
        assert!(
            Arc::ptr_eq(&fetching, &panel.fetch_lock("fetching")),
            "a second caller gets the same lock, so the fetch is shared, not run twice"
        );
        drop(fetching);
        panel.fetch_lock("other");
        assert_eq!(panel.tracked_sessions(), 1, "once the fetch is over it goes");
    }

    #[test]
    fn an_entry_without_a_name_is_skipped() {
        assert!(McpServerView::from_cli(&json!({"status": "connected"})).is_none());
    }
}
