//! MCP tool handlers for Perri-specific mutations.
//!
//! ## Tools
//! - `perri.load_pr({ number, repo, highlights? })`
//! - `perri.clear_current_pr()`
//! - `perri.set_selected_index({ index })`
//! - `perri.get_selected_index()`
//!
//! ## Two hosts
//!
//! Each handler branches on `state.daemon`:
//!
//! - **Daemon-hosted** (`nostromd`): `load_pr`/`clear_current_pr` write
//!   through [`crate::data::perri_current_pr`] — the same file contract
//!   `PerriView` (TUI) writes — signal the native sources' refresh channels,
//!   and push `ServerMsg::PaneContent` broadcasts for the caller's `diff`
//!   (and, for `clear_current_pr`, `queue`) pane via
//!   [`super::apply_layout::fetch`], so rendering can never disagree with
//!   `apply_layout`/`refresh_pane_content`. `set_selected_index`/
//!   `get_selected_index` read/write an agent-scoped
//!   `Arc<AtomicUsize>` on `DaemonMcpBackend::perri` — it moves no GUI
//!   highlight (see `PerriDaemonState` doc comment).
//! - **TUI-hosted**: unchanged from before this fix — posts an
//!   `AppEvent::McpCommand` and awaits a reply from `PerriView` via the app's
//!   own event loop.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{oneshot, watch};

use crate::data::{perri_current_pr, perri_pr::PrSnapshot};
use crate::event::AppEvent;
use crate::ipc::pane_registry::PaneRegistry;
use crate::ipc::protocol::{PaneContentWire, PaneFreshness};
use crate::mcp::pane_sources::{broadcast_loading_if_first_paint, broadcast_pane_content};
use crate::mcp::state::DaemonMcpBackend;
use crate::mcp::tools::apply_layout::{self, SOURCE_CURRENT_PR, SOURCE_PR_QUEUE};
use crate::mcp::tools::show;
use crate::mcp::{command::McpCommand, state::McpSharedState};

const COMMAND_TIMEOUT_SECS: u64 = 5;

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `perri.load_pr({ number, repo, highlights? })`.
pub async fn load_pr(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let number = match args.get("number").and_then(|v| v.as_u64()) {
        Some(n) if n > 0 => n,
        _ => return json!({ "error": "invalid_args", "detail": "missing or invalid number" }),
    };
    let repo = match args.get("repo").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return json!({ "error": "invalid_args", "detail": "missing repo" }),
    };
    if let Err(e) = perri_current_pr::validate_repo_slug(&repo) {
        return json!({ "error": "invalid_args", "detail": e });
    }
    let highlights = args
        .get("highlights")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return load_pr_daemon(
            state,
            daemon,
            args,
            pty_id,
            number,
            &repo,
            highlights.as_deref(),
        )
        .await;
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriLoadPr {
        number,
        repo,
        highlights,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.clear_current_pr()`.
pub async fn clear_current_pr(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return clear_current_pr_daemon(state, daemon, args, pty_id).await;
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriClearCurrentPr { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.set_selected_index({ index })`.
pub async fn set_selected_index(
    state: &McpSharedState,
    args: &Value,
    _pty_id: Option<&str>,
) -> Value {
    let index = match args.get("index").and_then(|v| v.as_u64()) {
        Some(n) => n as usize,
        None => return json!({ "error": "invalid_args", "detail": "missing or invalid index" }),
    };

    // ── daemon-hosted path ──────────────────────────────────────────────────
    // Clamp exactly as `PerriView::set_selected_pr_index` does: to `len - 1`,
    // or `0` when the queue is empty. This is an agent-scoped in-memory cell —
    // it moves no GUI highlight (see `PerriDaemonState` doc comment).
    if let Some(daemon) = &state.daemon {
        let len = state
            .perri_queue_rx
            .borrow()
            .as_ref()
            .map(|s| s.items.len())
            .unwrap_or(0);
        let clamped = if len == 0 { 0 } else { index.min(len - 1) };
        daemon.perri.selected_index.store(clamped, Ordering::SeqCst);
        return json!({ "ok": true });
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPerriSelectedIndex { index, reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.get_selected_index()`.
pub async fn get_selected_index(state: &McpSharedState, _pty_id: Option<&str>) -> Value {
    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return json!({ "index": daemon.perri.selected_index.load(Ordering::SeqCst) });
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::GetPerriSelectedIndex { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(idx))) => json!({ "index": idx }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

// ── daemon-hosted implementations ───────────────────────────────────────────

/// Daemon branch of `perri.load_pr`. See the module doc comment and plan
/// design decisions D1/D3/D4/D5 for the shape of this logic.
async fn load_pr_daemon(
    state: &McpSharedState,
    daemon: &DaemonMcpBackend,
    args: &Value,
    pty_id: Option<&str>,
    number: u64,
    repo: &str,
    highlights: Option<&str>,
) -> Value {
    let Some(state_dir) = daemon.perri.state_dir.clone() else {
        return json!({
            "error": "not_supported",
            "detail": "perri.load_pr requires the daemon's Perri state_dir to be configured",
        });
    };

    if let Err(e) = perri_current_pr::write_pointer(&state_dir, number, repo, highlights) {
        return json!({ "error": "io_error", "detail": e });
    }

    if let Some(tx) = &daemon.perri.pr_refresh_tx {
        let _ = tx.send(());
    }

    let tag = apply_layout::target_tag(args, pty_id).map(|s| s.to_string());

    // R8 (W5 — curated-agent-views): the PR under review just moved, so the
    // previous review's `file`/`ticket` tabs and any other PR's
    // conversation/diff close. Done before any content push below, so the
    // operator never sees the new PR's content sitting beside the old PR's
    // evidence. A no-op for a focus with no curated regions, which is every
    // focus still driving `perri-standard` through the raw tools.
    if let Some(t) = tag.as_deref() {
        show::reset_for_pr_change(daemon, t, Some((repo, number)));
    }

    let mut warnings = Vec::new();
    let mut pending = false;

    match highlights {
        Some(text) => {
            // D4: highlights are agent-authored final content — sever the
            // diff pane's live binding, or the broadcaster would clobber them
            // with the plain rendered summary within seconds.
            if let Some(t) = tag.as_deref() {
                daemon.pane_registry.lock().unwrap().unbind_source(t, "diff");
            }
            // D3: highlights are the pane's final content — no fetch, no wait.
            push_pane_content(
                daemon,
                tag.as_deref(),
                "diff",
                PaneContentWire::Text {
                    text: text.to_string(),
                },
                None,
                &mut warnings,
            );
        }
        None => {
            // D4: no highlights — diff renders straight from
            // perri.get_current_pr, so keep (or re-establish) that binding.
            if let Some(t) = tag.as_deref() {
                daemon
                    .pane_registry
                    .lock()
                    .unwrap()
                    .bind_source(t, "diff", SOURCE_CURRENT_PR);
            }
            push_pane_content(
                daemon,
                tag.as_deref(),
                "diff",
                PaneContentWire::Loading,
                None,
                &mut warnings,
            );

            let mut pr_rx = state.perri_pr_rx.clone();
            let matched =
                wait_for_matching_snapshot(&mut pr_rx, repo, number, daemon.perri.settle_timeout)
                    .await;

            if matched {
                match apply_layout::fetch(SOURCE_CURRENT_PR, state, apply_layout::FetchArgs::default()) {
                    Ok(content) => {
                        let fr = apply_layout::freshness(SOURCE_CURRENT_PR, state);
                        push_pane_content(
                            daemon,
                            tag.as_deref(),
                            "diff",
                            content,
                            Some(fr),
                            &mut warnings,
                        )
                    }
                    Err(e) => {
                        warnings.push(json!({ "pane_id": "diff", "error": e.code() }));
                        push_pane_content(
                            daemon,
                            tag.as_deref(),
                            "diff",
                            PaneContentWire::Error {
                                message: format!(
                                    "perri.load_pr: perri.get_current_pr fetch failed ({})",
                                    e.code()
                                ),
                            },
                            None,
                            &mut warnings,
                        );
                    }
                }
            } else {
                pending = true;
                push_pane_content(
                    daemon,
                    tag.as_deref(),
                    "diff",
                    PaneContentWire::Text {
                        text: format!("Fetching {repo}#{number}\u{2026} (still loading)"),
                    },
                    None,
                    &mut warnings,
                );
            }
        }
    }

    // D5: coherence win — if the loaded PR is in the current queue, move the
    // agent-scoped selected index to it. Leave it unchanged otherwise.
    if let Some(snap) = state.perri_queue_rx.borrow().as_ref() {
        if let Some(idx) = snap
            .items
            .iter()
            .position(|item| item.repo == repo && item.number == number)
        {
            daemon.perri.selected_index.store(idx, Ordering::SeqCst);
        }
    }

    let mut result = json!({ "ok": true });
    if pending {
        result["pending"] = json!(true);
        result["detail"] = json!(format!(
            "refetch for {repo}#{number} still in flight after {:?}",
            daemon.perri.settle_timeout
        ));
    }
    if !warnings.is_empty() {
        result["warnings"] = json!(warnings);
    }
    result
}

/// Daemon branch of `perri.clear_current_pr`.
async fn clear_current_pr_daemon(
    state: &McpSharedState,
    daemon: &DaemonMcpBackend,
    args: &Value,
    pty_id: Option<&str>,
) -> Value {
    let Some(state_dir) = daemon.perri.state_dir.clone() else {
        return json!({
            "error": "not_supported",
            "detail": "perri.clear_current_pr requires the daemon's Perri state_dir to be configured",
        });
    };

    if let Err(e) = perri_current_pr::clear_pointer(&state_dir) {
        return json!({ "error": "io_error", "detail": e });
    }
    if let Err(e) = perri_current_pr::touch_queue_dirty(&state_dir) {
        return json!({ "error": "io_error", "detail": e });
    }

    if let Some(tx) = &daemon.perri.pr_refresh_tx {
        let _ = tx.send(());
    }
    if let Some(tx) = &daemon.perri.queue_refresh_tx {
        let _ = tx.send(());
    }

    let tag = apply_layout::target_tag(args, pty_id).map(|s| s.to_string());

    // R8 (W5 — curated-agent-views): nothing is under review any more, so
    // every curated review tab closes and the detail region goes with its last
    // one. The queue is a singleton belonging to no PR and is never closed.
    // Must run *before* resolving targets below: this is what prunes closed
    // panes (and their bindings) out of the tree, so the resolver never
    // targets a pane that's about to disappear.
    let closed: Vec<String> = tag
        .as_deref()
        .map(|t| show::reset_for_pr_change(daemon, t, None))
        .unwrap_or_default();

    let mut warnings = Vec::new();

    // D1/D2: resolve which of the focus's *live* panes hold PR content and
    // which hold the queue, from the freshly pruned tree/bindings — never
    // from a fixed template vocabulary. A curated focus's surviving paramless
    // PR pane (Context 2) and `perri-standard`'s fixed `diff`/`queue` panes
    // both fall out of this for free.
    let (pr_panes, queue_panes) = match tag.as_deref() {
        Some(t) => {
            let reg = daemon.pane_registry.lock().unwrap();
            let targets = resolve_perri_targets(&reg, t);
            (targets.pr, targets.queue)
        }
        None => (Vec::new(), Vec::new()),
    };

    // D4: a pane already bound to a PR-backed source stays bound to it — the
    // placeholder is that source's own empty state (the same string
    // `fetch(SOURCE_CURRENT_PR, ..)` returns for a no-PR snapshot), so the
    // pane goes live again the instant a PR loads. Only an *unbound* survivor
    // (D2's legacy `perri-standard` case, left behind by
    // `perri.load_pr({highlights})`'s `unbind_source`) gets (re)bound here —
    // never repurpose a pane already bound to `perri.get_pr_diff` /
    // `perri.get_pr_conversation` onto a different source.
    if let Some(t) = tag.as_deref() {
        let mut reg = daemon.pane_registry.lock().unwrap();
        for pane in &pr_panes {
            if reg.source_for(t, pane).is_none() {
                reg.bind_source(t, pane, SOURCE_CURRENT_PR);
            }
        }
        for pane in &queue_panes {
            reg.bind_source(t, pane, SOURCE_PR_QUEUE);
        }
    }

    for pane in &pr_panes {
        push_pane_content(
            daemon,
            tag.as_deref(),
            pane,
            PaneContentWire::Text {
                text: apply_layout::NO_PR_LOADED_PLACEHOLDER.to_string(),
            },
            None,
            &mut warnings,
        );
    }

    if !queue_panes.is_empty() {
        for pane in &queue_panes {
            push_pane_content(
                daemon,
                tag.as_deref(),
                pane,
                PaneContentWire::Loading,
                None,
                &mut warnings,
            );
        }
        // Fetch once, push the same content to every queue pane — there is
        // only ever one queue pane per focus today, but nothing here assumes
        // that.
        match apply_layout::fetch(SOURCE_PR_QUEUE, state, apply_layout::FetchArgs::default()) {
            Ok(content) => {
                let fr = apply_layout::freshness(SOURCE_PR_QUEUE, state);
                for pane in &queue_panes {
                    push_pane_content(
                        daemon,
                        tag.as_deref(),
                        pane,
                        content.clone(),
                        Some(fr.clone()),
                        &mut warnings,
                    );
                }
            }
            Err(e) => {
                for pane in &queue_panes {
                    warnings.push(json!({ "pane_id": pane, "error": e.code() }));
                    push_pane_content(
                        daemon,
                        tag.as_deref(),
                        pane,
                        PaneContentWire::Error {
                            message: format!(
                                "perri.clear_current_pr: perri.list_pr_queue fetch failed ({})",
                                e.code()
                            ),
                        },
                        None,
                        &mut warnings,
                    );
                }
            }
        }
    }

    let mut result = json!({
        "ok": true,
        "cleared": pr_panes,
        "queue": queue_panes,
        "closed": closed,
    });
    if !warnings.is_empty() {
        result["warnings"] = json!(warnings);
    }
    result
}

/// Which of `tag`'s live panes currently hold PR-review content, and which
/// hold the review queue — resolved from the focus's actual tree and
/// bindings (D1), so this is correct for any layout template, including one
/// this code has never heard of: a schema-declared pane is bound by
/// `apply_layout` and therefore resolves here for free.
///
/// The two literal ids in the `None` arms are the one narrow legacy bridge
/// (D2), scoped to a pane with *no* binding at all: `perri.load_pr` with
/// `highlights` deliberately severs the `diff` pane's binding
/// (`unbind_source`, see `load_pr_daemon` above) so agent-authored highlights
/// aren't clobbered by the live broadcaster, and a `clear_current_pr` right
/// after that must still treat that pane as PR content. A curated focus never
/// has a pane literally named `diff`/`queue` with no binding, so this can't
/// fire there.
#[derive(Debug, Default, PartialEq, Eq)]
struct PerriTargets {
    pr: Vec<String>,
    queue: Vec<String>,
}

fn resolve_perri_targets(reg: &PaneRegistry, tag: &str) -> PerriTargets {
    let mut out = PerriTargets::default();
    for pane_id in reg.pane_ids(tag) {
        match reg.source_for(tag, &pane_id) {
            Some(s) if apply_layout::PR_BACKED_SOURCES.contains(&s) => out.pr.push(pane_id),
            Some(s) if s == SOURCE_PR_QUEUE => out.queue.push(pane_id),
            Some(_) => {} // file / ticket: not PR content
            None if pane_id == "diff" => out.pr.push(pane_id),
            None if pane_id == "queue" => out.queue.push(pane_id),
            None => {} // repl, or an unbound agent-authored pane
        }
    }
    out
}

// ── shared daemon helpers ───────────────────────────────────────────────────

/// Push `content` to `pane_id` within `tag`'s pane tree — but only when the
/// registry actually has that pane registered for `tag` (D7). A resolved tag
/// with no such pane, or no tag at all, degrades to a `warnings` entry
/// instead of failing the call or broadcasting to a pane that doesn't exist.
///
/// Delegates the actual send to the D5 choke point: a `Loading` push goes
/// through [`broadcast_loading_if_first_paint`] (so a pane that's already
/// showing content never sees a spinner), everything else goes through
/// [`broadcast_pane_content`] with the given `freshness`.
fn push_pane_content(
    daemon: &DaemonMcpBackend,
    tag: Option<&str>,
    pane_id: &str,
    content: PaneContentWire,
    freshness: Option<PaneFreshness>,
    warnings: &mut Vec<Value>,
) {
    let Some(tag) = tag else {
        if !warnings.iter().any(|w| w.get("pane_push").is_some()) {
            warnings.push(json!({ "pane_push": "unidentified_caller" }));
        }
        return;
    };

    let known = daemon
        .pane_registry
        .lock()
        .unwrap()
        .pane_ids(tag)
        .iter()
        .any(|p| p == pane_id);

    if known {
        if matches!(content, PaneContentWire::Loading) {
            broadcast_loading_if_first_paint(daemon, tag, pane_id);
        } else {
            broadcast_pane_content(daemon, tag, pane_id, content, freshness);
        }
    } else if !warnings
        .iter()
        .any(|w| w.get("pane_id").and_then(|v| v.as_str()) == Some(pane_id))
    {
        warnings.push(json!({ "pane_id": pane_id, "skipped": "unknown_pane" }));
    }
}

/// Poll `rx` (a clone of `McpSharedState::perri_pr_rx`) until it publishes a
/// snapshot whose `(repo, pr_number)` matches the request, or `timeout`
/// elapses. Checks the already-published value first, so a snapshot for the
/// right PR that's already sitting in the channel resolves immediately
/// without waiting for a change. A snapshot for the right PR that carries an
/// `error` still counts as a match — that's a real (if unhappy) answer, not
/// something to keep waiting past.
async fn wait_for_matching_snapshot(
    rx: &mut watch::Receiver<Option<PrSnapshot>>,
    repo: &str,
    number: u64,
    timeout: Duration,
) -> bool {
    fn matches(snap: &Option<PrSnapshot>, repo: &str, number: u64) -> bool {
        matches!(snap, Some(s) if s.repo == repo && s.pr_number == Some(number))
    }

    if matches(&rx.borrow(), repo, number) {
        return true;
    }

    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return false;
        }
        match tokio::time::timeout(remaining, rx.changed()).await {
            Ok(Ok(())) => {
                if matches(&rx.borrow(), repo, number) {
                    return true;
                }
            }
            Ok(Err(_)) => return false, // sender dropped
            Err(_) => return false,     // overall timeout elapsed
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::perri_pr::PrSnapshot;
    use crate::data::perri_queue::PrQueueSnapshot;
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::protocol::{PaneTree, ServerMsg, SplitDirection};
    use crate::ipc::SessionManager;
    use crate::mcp::{DaemonMcpBackend, PerriDaemonState};
    use std::sync::atomic::AtomicUsize;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;
    use tokio::sync::broadcast;

    /// The daemon-backed `McpSharedState` innards shared by every
    /// `make_*_daemon_state` variant below: a real registry and session store
    /// on a temp dir (so no test ever touches `~/.claude/state/perri`), and a
    /// broadcast sender the caller subscribes to *after* seeding a layout —
    /// otherwise the seeding call's own `FocusLayout`/`PaneContent`
    /// broadcasts would show up in every test's first `recv()`.
    fn build_daemon_state(tmp: &TempDir) -> (McpSharedState, broadcast::Sender<ServerMsg>) {
        let perri_state_dir = tmp.path().join("perri-state");
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx) = broadcast::channel(64);

        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx: broadcast_tx.clone(),
            perri: PerriDaemonState {
                state_dir: Some(perri_state_dir),
                pr_refresh_tx: None,
                queue_refresh_tx: None,
                selected_index: Arc::new(AtomicUsize::new(0)),
                settle_timeout: Duration::from_millis(50),
            },
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
        };
        (McpSharedState::for_daemon(backend), broadcast_tx)
    }

    /// Build a daemon-hosted `McpSharedState`, apply `layout_name` to the
    /// "perri" focus, and subscribe to broadcasts *after* seeding — otherwise
    /// the seeding call's own `FocusLayout`/`PaneContent` broadcasts would
    /// show up in every test's first `recv()`.
    async fn make_daemon_state_with_layout(
        layout_name: &str,
    ) -> (McpSharedState, TempDir, broadcast::Receiver<ServerMsg>) {
        let tmp = TempDir::new().unwrap();
        let (state, broadcast_tx) = build_daemon_state(&tmp);

        let _ = apply_layout::apply_layout(&state, &json!({ "name": layout_name }), Some("perri"))
            .await;

        let bcast = broadcast_tx.subscribe();
        (state, tmp, bcast)
    }

    /// Build a daemon-hosted `McpSharedState` seeded with the standard
    /// queue/diff/repl layout ("perri-standard") so pane-existence checks
    /// (D7) pass by default.
    async fn make_daemon_state() -> (McpSharedState, TempDir, broadcast::Receiver<ServerMsg>) {
        make_daemon_state_with_layout("perri-standard").await
    }

    /// Like [`make_daemon_state`], but seeded with `perri-curated`'s starting
    /// layout (a bound `queue`, a `repl`, no detail region yet) — the W5
    /// curated-agent-views focus shape `resolve_perri_targets` must resolve
    /// correctly, instead of only the legacy fixed `diff`/`queue` names
    /// `perri-standard` happens to also produce.
    async fn make_curated_daemon_state() -> (McpSharedState, TempDir, broadcast::Receiver<ServerMsg>)
    {
        make_daemon_state_with_layout("perri-curated").await
    }

    /// Add a `detail` region to `tag`'s curated tree with two review tabs:
    /// `detail.0` bound *paramless* to `perri.get_pr_diff` (the survivor case
    /// — `derive::pr_identity` falls back to whatever is under review, so
    /// once a clear makes that `None` too, the tab has no PR identity at all
    /// and R8 doesn't recognise it as a stale review tab), and `detail.1`
    /// bound *with params* naming a PR that a clear's `new_pr: None` can
    /// never match (the stale case — see
    /// `placement::reset_for_pr_change`/D5's `(repo, number) == new_pr`
    /// check).
    fn seed_curated_detail_tabs(state: &McpSharedState, tag: &str) {
        let reg = state.daemon.as_ref().unwrap().pane_registry.clone();
        let mut reg = reg.lock().unwrap();
        reg.set_layout(
            tag,
            &json!({ "tree": PaneTree::Split {
                direction: SplitDirection::Vertical,
                children: vec![
                    PaneTree::Leaf { pane_id: "queue".into() },
                    PaneTree::Tabs {
                        children: vec![
                            PaneTree::Leaf { pane_id: "detail.0".into() },
                            PaneTree::Leaf { pane_id: "detail.1".into() },
                        ],
                        labels: vec!["A".into(), "B".into()],
                        active: 0,
                        region: Some("detail".into()),
                    },
                    PaneTree::Leaf { pane_id: "repl".into() },
                ],
                ratios: vec![0.3, 0.4, 0.3],
            }}),
        )
        .unwrap();
        reg.bind_source(tag, "queue", SOURCE_PR_QUEUE);
        reg.bind_source(tag, "detail.0", apply_layout::SOURCE_PR_DIFF);
        reg.bind_source_with_params(
            tag,
            "detail.1",
            apply_layout::SOURCE_PR_DIFF,
            Some(json!({ "repo": "acme/other", "number": 7 })),
        );
    }

    /// Every message currently sitting in `bcast`, without waiting.
    /// `clear_current_pr_daemon`/`load_pr_daemon` never `.await` between a
    /// broadcast send and returning, so by the time the handler's future
    /// resolves, every message it sent is already in the channel — no need
    /// to race a timeout against a background task the way `recv_pane_content`
    /// does for the app's own event loop.
    fn drain_broadcasts(bcast: &mut broadcast::Receiver<ServerMsg>) -> Vec<ServerMsg> {
        let mut out = Vec::new();
        while let Ok(msg) = bcast.try_recv() {
            out.push(msg);
        }
        out
    }

    fn seed_queue(state: &mut McpSharedState, items: Value) {
        let snapshot: PrQueueSnapshot = serde_json::from_value(json!({
            "generated_at": null, "items": items, "stale": false, "error": null
        }))
        .unwrap();
        let (_tx, rx) = watch::channel(Some(snapshot));
        state.perri_queue_rx = rx;
    }

    fn pr_snapshot(repo: &str, number: u64, title: &str) -> PrSnapshot {
        serde_json::from_value(json!({
            "pr_number": number, "repo": repo, "title": title,
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": null, "additions": 1, "deletions": 1,
            "changed_files": 1, "head_sha": "abc123", "diff_too_large": false
        }))
        .unwrap()
    }

    async fn recv_pane_content(
        bcast: &mut broadcast::Receiver<ServerMsg>,
    ) -> (String, PaneContentWire) {
        match tokio::time::timeout(Duration::from_millis(500), bcast.recv())
            .await
            .expect("a PaneContent broadcast within 500ms")
            .unwrap()
        {
            ServerMsg::PaneContent {
                pane_id, content, ..
            } => (pane_id, content),
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    // ── load_pr ──────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn load_pr_with_highlights_writes_pointer_and_pushes_text_once() {
        let (state, tmp, mut bcast) = make_daemon_state().await;

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        let content =
            std::fs::read_to_string(tmp.path().join("perri-state").join("current-pr.json"))
                .unwrap();
        let parsed: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["number"], 42);
        assert_eq!(parsed["repo"], "acme/web");
        assert!(tmp.path().join("perri-state/current-pr.dirty").exists());

        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, "check auth"),
            other => panic!("expected Text, got {other:?}"),
        }

        // Highlights are final content — no second broadcast follows.
        assert!(
            tokio::time::timeout(Duration::from_millis(100), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn load_pr_signals_pr_refresh_exactly_once() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        let (refresh_tx, mut refresh_rx) = tokio::sync::mpsc::unbounded_channel::<()>();
        if let Some(daemon) = &mut state.daemon {
            daemon.perri.pr_refresh_tx = Some(refresh_tx);
        }

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        assert!(refresh_rx.try_recv().is_ok(), "expected exactly one signal");
        assert!(
            refresh_rx.try_recv().is_err(),
            "expected exactly one signal, found a second"
        );
    }

    #[tokio::test]
    async fn load_pr_no_highlights_with_snapshot_already_published() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;

        let (_tx, pr_rx) = watch::channel(Some(pr_snapshot("acme/web", 42, "Add widget")));
        state.perri_pr_rx = pr_rx;

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to its final content.
        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => {
                assert!(text.contains("Add widget"));
                assert!(text.contains("acme/web#42"));
            }
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_no_highlights_snapshot_arrives_during_wait() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;

        let (tx, pr_rx) = watch::channel(None);
        state.perri_pr_rx = pr_rx;
        // Increase settle_timeout for this test so the delayed send lands
        // well inside the window.
        if let Some(daemon) = &mut state.daemon {
            daemon.perri.settle_timeout = Duration::from_secs(2);
        }

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let _ = tx.send(Some(pr_snapshot("acme/web", 42, "Add widget")));
        });

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert!(text.contains("Add widget")),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_no_highlights_times_out_leaves_pane_on_text_not_loading() {
        let (state, _tmp, mut bcast) = make_daemon_state().await;
        // perri_pr_rx stays at its default None — never matches.

        let args = json!({ "number": 99, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["pending"], true);

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to the "still loading" placeholder text.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert!(text.contains("acme/web#99")),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_rejects_invalid_args() {
        let (state, tmp, _bcast) = make_daemon_state().await;

        for args in [
            json!({ "repo": "acme/web" }),
            json!({ "number": 0, "repo": "acme/web" }),
            json!({ "number": 1 }),
            json!({ "number": 1, "repo": "org/repo;rm -rf /" }),
        ] {
            let result = load_pr(&state, &args, Some("perri")).await;
            assert_eq!(result["error"], "invalid_args", "args: {args}");
        }

        assert!(!tmp.path().join("perri-state/current-pr.json").exists());
    }

    #[tokio::test]
    async fn load_pr_no_state_dir_returns_not_supported() {
        let (event_tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let dir = TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx2) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
        };
        let mut state = McpSharedState::for_daemon(backend);
        state.event_tx = event_tx;

        let args = json!({ "number": 1, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }

    #[tokio::test]
    async fn load_pr_sets_selected_index_when_pr_is_in_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "acme/web", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "acme/web", "number": 42, "title": "b", "author": "y",
                  "bucket": "requested", "ci_state": "success", "url": "https://y" },
            ]),
        );

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(daemon.perri.selected_index.load(Ordering::SeqCst), 1);
        }
    }

    #[tokio::test]
    async fn load_pr_leaves_selected_index_unchanged_when_pr_not_in_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        if let Some(daemon) = &state.daemon {
            daemon.perri.selected_index.store(3, Ordering::SeqCst);
        }
        seed_queue(&mut state, json!([]));

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(daemon.perri.selected_index.load(Ordering::SeqCst), 3);
        }
    }

    #[tokio::test]
    async fn load_pr_diff_text_matches_apply_layout_fetch_output() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;
        let (_tx, pr_rx) = watch::channel(Some(pr_snapshot("acme/web", 42, "Add widget")));
        state.perri_pr_rx = pr_rx;

        let expected = match apply_layout::fetch("perri.get_current_pr", &state, apply_layout::FetchArgs::default()).unwrap() {
            PaneContentWire::Text { text } => text,
            other => panic!("expected Text, got {other:?}"),
        };

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, expected),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_unknown_pane_adds_warning_and_still_mutates_state() {
        let (state, tmp, _bcast) = make_daemon_state().await;
        // Register a focus with only a "repl" leaf — no "diff" pane.
        if let Some(daemon) = &state.daemon {
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.get_or_init("no-diff-here");
        }

        let args = json!({
            "number": 42, "repo": "acme/web", "highlights": "notes",
            "view_id": "no-diff-here"
        });
        let result = load_pr(&state, &args, None).await;
        assert_eq!(result["ok"], true);
        let warnings = result["warnings"].as_array().expect("warnings array");
        assert!(warnings
            .iter()
            .any(|w| w["pane_id"] == "diff" && w["skipped"] == "unknown_pane"));
        assert!(
            tmp.path().join("perri-state/current-pr.json").exists(),
            "state mutation must still happen even when the pane is missing"
        );
    }

    #[tokio::test]
    async fn load_pr_unidentified_caller_still_mutates_state_and_warns_once() {
        let (state, tmp, _bcast) = make_daemon_state().await;

        // No highlights + no matching snapshot means the diff pane is pushed
        // to twice (Loading, then the timed-out placeholder) — this proves
        // the "no resolvable tag" warning is deduplicated across pushes,
        // not appended once per attempted push.
        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, None).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["pending"], true);
        let warnings = result["warnings"].as_array().expect("warnings array");
        assert_eq!(
            warnings
                .iter()
                .filter(|w| w["pane_push"] == "unidentified_caller")
                .count(),
            1,
            "no resolvable tag must warn exactly once, not once per pane push"
        );
        assert!(
            tmp.path().join("perri-state/current-pr.json").exists(),
            "state mutation must still happen even with no resolvable tag"
        );
    }

    // ── load_pr / diff binding ────────────────────────────────────────────────

    #[tokio::test]
    async fn load_pr_with_highlights_severs_the_diff_pane_s_live_binding() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        // make_daemon_state() applies "perri-standard", which binds "diff" to
        // perri.get_current_pr — confirm the starting point before mutating.
        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                Some("perri.get_current_pr")
            );
        }

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                None,
                "agent-authored highlights are final content — the diff pane must no \
                 longer be considered live, or the broadcaster would clobber them on \
                 the next queue/PR change"
            );
        }
    }

    #[tokio::test]
    async fn load_pr_without_highlights_keeps_diff_bound_to_its_live_source() {
        let (state, _tmp, _bcast) = make_daemon_state().await;

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                Some("perri.get_current_pr"),
                "no-highlights load_pr must keep (or re-establish) the diff pane's \
                 live binding, since its rendered content came from that source"
            );
        }
    }

    // ── clear_current_pr ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn clear_current_pr_removes_file_signals_and_pushes_content() {
        let (state, tmp, mut bcast) = make_daemon_state().await;
        let state_dir = tmp.path().join("perri-state");
        perri_current_pr::write_pointer(&state_dir, 1, "acme/web", None).unwrap();
        assert!(state_dir.join("current-pr.json").exists());

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);

        assert!(!state_dir.join("current-pr.json").exists());
        assert!(state_dir.join("current-pr.dirty").exists());
        assert!(state_dir.join("queue.dirty").exists());

        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, "No PR loaded."),
            other => panic!("expected Text, got {other:?}"),
        }

        // make_daemon_state() already painted "queue" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to the refetched list.
        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "queue");
        assert!(matches!(content, PaneContentWire::PrList { .. }));
    }

    #[tokio::test]
    async fn clear_current_pr_leaves_diff_and_queue_bound_to_their_live_sources() {
        let (state, _tmp, _bcast) = make_daemon_state().await;

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert_eq!(
                reg.source_for("perri", "diff"),
                Some("perri.get_current_pr"),
                "clearing the current PR must leave diff ready to go live again \
                 the moment a PR is loaded"
            );
            assert_eq!(
                reg.source_for("perri", "queue"),
                Some("perri.list_pr_queue")
            );
        }
    }

    #[tokio::test]
    async fn clear_current_pr_rebinds_and_repaints_diff_after_load_pr_severed_its_binding() {
        // perri-standard's legacy bridge: `perri.load_pr({ highlights })`
        // deliberately unbinds "diff" so agent-authored highlights aren't
        // clobbered by the live broadcaster. A `clear_current_pr` right after
        // that must still find and treat "diff" as PR content (D2), even
        // though it currently has no binding to classify by source.
        let (state, _tmp, mut bcast) = make_daemon_state().await;

        let load_args = json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" });
        let load_result = load_pr(&state, &load_args, Some("perri")).await;
        assert_eq!(load_result["ok"], true);
        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                None,
                "sanity: highlights must have severed diff's binding first"
            );
        }
        let _ = drain_broadcasts(&mut bcast); // load_pr's own broadcast, not under test

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["cleared"], json!(["diff"]));

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                Some("perri.get_current_pr"),
                "clear_current_pr must rebind an unbound legacy diff pane so it goes live \
                 again the moment a PR loads"
            );
        }

        let messages = drain_broadcasts(&mut bcast);
        let got_placeholder = messages.iter().any(|m| {
            matches!(
                m,
                ServerMsg::PaneContent { pane_id, content: PaneContentWire::Text { text }, .. }
                if pane_id == "diff" && text == "No PR loaded."
            )
        });
        assert!(got_placeholder, "expected diff to receive the placeholder; got {messages:?}");
    }

    #[tokio::test]
    async fn clear_current_pr_closes_a_stale_params_bound_pr_diff_tab_in_curated_layout() {
        let (state, _tmp, mut bcast) = make_curated_daemon_state().await;
        seed_curated_detail_tabs(&state, "perri");

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("warnings").is_none(), "unexpected warnings: {result}");
        assert!(result["cleared"].is_array());
        assert!(result["queue"].is_array());

        let closed: Vec<String> = result["closed"]
            .as_array()
            .expect("closed array")
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        assert!(
            closed.contains(&"detail.1".to_string()),
            "the params-bound tab naming a PR that can never equal `None` must close: {closed:?}"
        );

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(
                !reg.pane_ids("perri").contains(&"detail.1".to_string()),
                "the closed tab must actually be gone from the tree"
            );
            assert!(reg.source_for("perri", "detail.1").is_none());
        }

        let messages = drain_broadcasts(&mut bcast);
        for msg in &messages {
            if let ServerMsg::PaneContent { pane_id, .. } = msg {
                assert_ne!(
                    pane_id, "detail.1",
                    "a tab that was just closed must never receive a content push"
                );
            }
        }
    }

    #[tokio::test]
    async fn clear_current_pr_pushes_placeholder_to_a_surviving_paramless_pr_diff_tab_in_curated_layout(
    ) {
        // This is the test that proves the actual fix: a curated focus's
        // paramless PR pane is neither "diff" nor "queue" by name, so only
        // resolving targets from the live tree/bindings (rather than the
        // legacy hardcoded ids) finds it at all.
        let (state, _tmp, mut bcast) = make_curated_daemon_state().await;
        seed_curated_detail_tabs(&state, "perri");

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(
                reg.pane_ids("perri").contains(&"detail.0".to_string()),
                "the paramless survivor must not be closed by the teardown"
            );
        }

        let cleared: Vec<String> = result["cleared"]
            .as_array()
            .expect("cleared array")
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect();
        assert!(
            cleared.contains(&"detail.0".to_string()),
            "detail.0 must be resolved as PR content: {cleared:?}"
        );

        let messages = drain_broadcasts(&mut bcast);
        let got_placeholder = messages.iter().any(|m| {
            matches!(
                m,
                ServerMsg::PaneContent { pane_id, content: PaneContentWire::Text { text }, .. }
                if pane_id == "detail.0" && text == "No PR loaded."
            )
        });
        assert!(
            got_placeholder,
            "expected detail.0 to receive the No PR loaded placeholder; got {messages:?}"
        );
    }

    #[tokio::test]
    async fn clear_current_pr_refreshes_a_curated_focus_queue_pane() {
        let (state, _tmp, mut bcast) = make_curated_daemon_state().await;
        // perri-curated's starting tree: just a bound "queue" and a "repl",
        // no detail region yet.

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["queue"], json!(["queue"]));

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "queue"),
                Some("perri.list_pr_queue")
            );
        }

        let messages = drain_broadcasts(&mut bcast);
        let got_queue_list = messages.iter().any(|m| {
            matches!(
                m,
                ServerMsg::PaneContent { pane_id, content: PaneContentWire::PrList { .. }, .. }
                if pane_id == "queue"
            )
        });
        assert!(
            got_queue_list,
            "expected the curated focus's queue pane to be refreshed; got {messages:?}"
        );
    }

    /// True when `result["warnings"]` (if present) contains an
    /// `{"skipped":"unknown_pane"}` entry.
    fn has_unknown_pane_warning(result: &Value) -> bool {
        result
            .get("warnings")
            .and_then(|w| w.as_array())
            .map(|warnings| {
                warnings
                    .iter()
                    .any(|w| w.get("skipped").and_then(|s| s.as_str()) == Some("unknown_pane"))
            })
            .unwrap_or(false)
    }

    #[tokio::test]
    async fn clear_current_pr_never_reports_an_unknown_pane_warning_on_the_healthy_path() {
        // Regression guard: before this fix, a curated focus's real panes
        // were invisible to the hardcoded "diff"/"queue" pushes, which
        // produced a `{"pane_id":"diff","skipped":"unknown_pane"}` warning on
        // every clear. Once targets are resolved from the live tree, that
        // warning is unreachable on any focus that actually applied a layout.
        let (standard_state, _tmp1, _bcast1) = make_daemon_state().await;
        let result = clear_current_pr(&standard_state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(
            !has_unknown_pane_warning(&result),
            "perri-standard: unexpected unknown_pane warning in {result}"
        );

        let (curated_state, _tmp2, _bcast2) = make_curated_daemon_state().await;
        seed_curated_detail_tabs(&curated_state, "perri");
        let result = clear_current_pr(&curated_state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(
            !has_unknown_pane_warning(&result),
            "perri-curated: unexpected unknown_pane warning in {result}"
        );
    }

    #[tokio::test]
    async fn clear_current_pr_noop_when_no_pointer_file_is_success() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
    }

    #[tokio::test]
    async fn clear_current_pr_no_state_dir_returns_not_supported() {
        let dir = TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
        };
        let state = McpSharedState::for_daemon(backend);

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }

    // ── set_selected_index / get_selected_index ─────────────────────────────

    #[tokio::test]
    async fn set_selected_index_clamps_to_single_item_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "acme/web", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
            ]),
        );

        let result = set_selected_index(&state, &json!({ "index": 5 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 0);
    }

    #[tokio::test]
    async fn set_selected_index_clamps_to_zero_on_empty_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(&mut state, json!([]));

        let result = set_selected_index(&state, &json!({ "index": 9 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 0);
    }

    #[tokio::test]
    async fn set_selected_index_round_trips_within_bounds() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "a/a", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "a/b", "number": 2, "title": "b", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "a/c", "number": 3, "title": "c", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
            ]),
        );

        let result = set_selected_index(&state, &json!({ "index": 2 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 2);
    }

    #[tokio::test]
    async fn set_selected_index_missing_index_is_invalid_args() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        let result = set_selected_index(&state, &json!({}), None).await;
        assert_eq!(result["error"], "invalid_args");
    }

    // ── resolve_perri_targets ────────────────────────────────────────────────
    //
    // `resolve_perri_targets` is a pure function of `(&PaneRegistry, &str)` —
    // exercised directly here, independent of the daemon harness above, since
    // that's the cheapest way to pin every classification rule (D1/D2).

    fn strs(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    /// A tag registered against an in-memory registry with a flat tree of
    /// `ids` plus a mandatory trailing `repl` leaf — every id in `ids` starts
    /// out unbound; callers bind whichever ones their test cares about.
    fn registry_with_panes(tag: &str, ids: &[&str]) -> PaneRegistry {
        let mut children: Vec<PaneTree> = ids
            .iter()
            .map(|id| PaneTree::Leaf { pane_id: id.to_string() })
            .collect();
        children.push(PaneTree::Leaf { pane_id: "repl".into() });
        let n = children.len();
        let mut reg = PaneRegistry::in_memory();
        reg.get_or_init(tag);
        reg.set_layout(
            tag,
            &json!({ "tree": PaneTree::Split {
                direction: SplitDirection::Vertical,
                ratios: vec![1.0 / n as f32; n],
                children,
            }}),
        )
        .unwrap();
        reg
    }

    #[test]
    fn resolve_perri_targets_classifies_every_pr_backed_source_as_pr() {
        let tag = "focus";
        let mut reg = registry_with_panes(tag, &["cp", "pd", "pc"]);
        reg.bind_source(tag, "cp", apply_layout::SOURCE_CURRENT_PR);
        reg.bind_source(tag, "pd", apply_layout::SOURCE_PR_DIFF);
        reg.bind_source(tag, "pc", apply_layout::SOURCE_PR_CONVERSATION);

        let targets = resolve_perri_targets(&reg, tag);
        assert_eq!(targets.pr, strs(&["cp", "pd", "pc"]));
        assert!(targets.queue.is_empty());
    }

    #[test]
    fn resolve_perri_targets_classifies_a_queue_bound_pane_as_queue() {
        let tag = "focus";
        let mut reg = registry_with_panes(tag, &["q"]);
        reg.bind_source(tag, "q", SOURCE_PR_QUEUE);

        let targets = resolve_perri_targets(&reg, tag);
        assert_eq!(targets.queue, strs(&["q"]));
        assert!(targets.pr.is_empty());
    }

    #[test]
    fn resolve_perri_targets_classifies_file_and_ticket_bound_panes_as_neither() {
        let tag = "focus";
        let mut reg = registry_with_panes(tag, &["f", "tk"]);
        reg.bind_source(tag, "f", apply_layout::SOURCE_FILE);
        reg.bind_source(tag, "tk", apply_layout::SOURCE_TICKET);

        let targets = resolve_perri_targets(&reg, tag);
        assert!(targets.pr.is_empty());
        assert!(targets.queue.is_empty());
    }

    #[test]
    fn resolve_perri_targets_treats_unbound_legacy_diff_and_queue_ids_as_pr_and_queue() {
        // D2's narrow legacy bridge: a pane literally named "diff"/"queue"
        // with *no* binding at all — perri-standard's shape immediately after
        // `perri.load_pr({ highlights })` severed diff's binding.
        let tag = "focus";
        let reg = registry_with_panes(tag, &["diff", "queue"]);
        // deliberately left unbound

        let targets = resolve_perri_targets(&reg, tag);
        assert_eq!(targets.pr, strs(&["diff"]));
        assert_eq!(targets.queue, strs(&["queue"]));
    }

    #[test]
    fn resolve_perri_targets_treats_other_unbound_panes_as_neither() {
        // Neither an agent-authored unbound pane nor the mandatory "repl"
        // leaf (also unbound, and appended by `registry_with_panes`) is PR or
        // queue content just because it exists.
        let tag = "focus";
        let reg = registry_with_panes(tag, &["notes"]);

        let targets = resolve_perri_targets(&reg, tag);
        assert!(targets.pr.is_empty());
        assert!(targets.queue.is_empty());
    }

    #[test]
    fn resolve_perri_targets_returns_empty_for_an_unregistered_tag() {
        let reg = PaneRegistry::in_memory();
        let targets = resolve_perri_targets(&reg, "no-such-focus");
        assert_eq!(targets, PerriTargets::default());
    }
}
