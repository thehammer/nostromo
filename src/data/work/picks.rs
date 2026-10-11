//! Teri's picks: 3–7 agent-chosen next actions, each with a one-sentence reason
//! (design contract §8).
//!
//! - [`PicksStore`] holds the current [`PicksSnapshot`], persists it to
//!   `~/.nostromo/teri/picks.json` and broadcasts every change as the retained
//!   `TeriPicks` frame. It is also the only place that validates a publish and
//!   recomputes `done_since`.
//! - [`PicksGenerator`] runs one generation at a time in an **ephemeral hidden
//!   daemon session** (tag [`PICKS_TAG`]): spawn, seed with [`PICKS_PROMPT`],
//!   wait for the agent's `teri.publish_picks` call or a timeout, then always
//!   end the session. The session never joins the focus registry, so it never
//!   reaches the sidebar or the user's Teri chat.
//! - [`PicksSessionHost`] is the seam to the session manager, so tests need no
//!   real `claude`.
//!
//! The agent is never trusted for anything but the item ids and reasons: the
//! daemon fills each pick's source and title from the hub, and computes
//! `unavailable_sources` from its own source states.

use std::collections::HashSet;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use chrono::Utc;
use serde::Deserialize;
use tokio::sync::{broadcast, watch};
use tokio::time::Instant;
use tracing::warn;

use crate::ipc::protocol::ServerMsg;
use crate::ipc::SessionManager;

use super::hub::WorkHub;
use super::model::{Pick, PicksSnapshot, SourceState, SourceStatus, WorkError, WorkSource};

/// Tag of the hidden generation session.
pub const PICKS_TAG: &str = "teri-picks";
/// Agent the generation session runs as.
pub const PICKS_AGENT: &str = "teri:teri";
/// The one message the generation session is seeded with.
pub const PICKS_PROMPT: &str = "You are generating Teri's picks for Hammer. \
Call teri_list_work_items for each source (todos, repo_docs, jira, sentry) and fred_get_state for today's meetings. \
Choose 3 to 7 items he should do next. \
For each, write one sentence that cites a concrete fact: a count, a date, a linked item or a meeting. \
Do not invent facts. \
Then call teri_publish_picks once with {picks:[{item_id, reason}]}. \
Do not do anything else. \
(These are the Nostromo MCP tools; if they are deferred, load them with ToolSearch first, e.g. \
select:mcp__nostromo__teri_list_work_items,mcp__nostromo__fred_get_state,mcp__nostromo__teri_publish_picks.)";

pub const MIN_PICKS: usize = 3;
pub const MAX_PICKS: usize = 7;
pub const MAX_REASON_CHARS: usize = 240;

/// How long a generation may take before it is given up on.
pub const GENERATION_TIMEOUT: Duration = Duration::from_secs(5 * 60);

/// How often a running generation checks that its session is still alive.
const ALIVE_POLL: Duration = Duration::from_millis(500);

/// One entry of a `teri.publish_picks` call.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct PickEntry {
    pub item_id: String,
    pub reason: String,
}

/// Why a publish was refused. The message names the offending ids.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PublishError {
    WrongCount(usize),
    DuplicateIds(Vec<String>),
    UnknownIds(Vec<String>),
    /// Item ids whose reason is blank or longer than [`MAX_REASON_CHARS`].
    BadReasons(Vec<String>),
}

impl fmt::Display for PublishError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PublishError::WrongCount(n) => {
                write!(f, "publish {MIN_PICKS} to {MAX_PICKS} picks; got {n}")
            }
            PublishError::DuplicateIds(ids) => {
                write!(f, "each item may be picked once; repeated: {}", ids.join(", "))
            }
            PublishError::UnknownIds(ids) => write!(
                f,
                "not current work items (use ids from teri.list_work_items): {}",
                ids.join(", ")
            ),
            PublishError::BadReasons(ids) => write!(
                f,
                "each reason must be 1 to {MAX_REASON_CHARS} characters; fix the reason for: {}",
                ids.join(", ")
            ),
        }
    }
}

impl std::error::Error for PublishError {}

/// The ids one source currently holds, with its status: what `done_since` is
/// decided from.
pub struct SourcePresence {
    pub status: SourceStatus,
    pub ids: HashSet<String>,
}

// ── store ─────────────────────────────────────────────────────────────────────

/// The current picks, persisted and broadcast on every change.
pub struct PicksStore {
    path: Option<PathBuf>,
    tx: broadcast::Sender<ServerMsg>,
    snapshot: Mutex<PicksSnapshot>,
    /// Counts successful publishes: a generation waits on it.
    publishes: watch::Sender<u64>,
}

impl PicksStore {
    /// Load the picks saved at `path` (`None`: memory only). A missing or
    /// unreadable file gives an empty snapshot; `generating` always starts
    /// false, since nothing is generating in a fresh process.
    pub fn load(path: Option<PathBuf>, tx: broadcast::Sender<ServerMsg>) -> Arc<Self> {
        let mut snapshot = path
            .as_deref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<PicksSnapshot>(&bytes).ok())
            .unwrap_or_default();
        snapshot.generating = false;
        Arc::new(Self { path, tx, snapshot: Mutex::new(snapshot), publishes: watch::channel(0).0 })
    }

    pub fn snapshot(&self) -> PicksSnapshot {
        self.lock().clone()
    }

    /// Validate `entries` against the hub's current items, store them as the new
    /// picks and broadcast. Nothing changes when the publish is refused.
    pub fn publish(&self, entries: &[PickEntry], hub: &WorkHub) -> Result<PicksSnapshot, PublishError> {
        if !(MIN_PICKS..=MAX_PICKS).contains(&entries.len()) {
            return Err(PublishError::WrongCount(entries.len()));
        }
        let mut seen = HashSet::new();
        let duplicates: Vec<String> = entries
            .iter()
            .filter(|e| !seen.insert(e.item_id.as_str()))
            .map(|e| e.item_id.clone())
            .collect();
        if !duplicates.is_empty() {
            return Err(PublishError::DuplicateIds(duplicates));
        }
        let known = hub.item_headlines(seen);
        let unknown: Vec<String> =
            entries.iter().filter(|e| !known.contains_key(&e.item_id)).map(|e| e.item_id.clone()).collect();
        if !unknown.is_empty() {
            return Err(PublishError::UnknownIds(unknown));
        }
        let bad_reasons: Vec<String> = entries
            .iter()
            .filter(|e| {
                let n = e.reason.trim().chars().count();
                n == 0 || n > MAX_REASON_CHARS
            })
            .map(|e| e.item_id.clone())
            .collect();
        if !bad_reasons.is_empty() {
            return Err(PublishError::BadReasons(bad_reasons));
        }

        let unavailable = unavailable_sources(&hub.statuses());
        let items: Vec<Pick> = entries
            .iter()
            .map(|e| {
                let (source, title) = known[&e.item_id].clone();
                Pick {
                    item_id: e.item_id.clone(),
                    source,
                    title,
                    reason: e.reason.trim().to_string(),
                    done_since: false,
                }
            })
            .collect();

        let snapshot = self.update(|snap| {
            snap.generated_at = Some(Utc::now());
            snap.unavailable_sources = unavailable;
            snap.items = items;
            snap.error = None;
            // A publish is what a running generation is waiting for.
            snap.generating = false;
            snap.clone()
        });
        self.publishes.send_modify(|n| *n = n.wrapping_add(1));
        Ok(snapshot)
    }

    /// Re-decide `done_since` for every pick from the hub's sources: true when
    /// the item is absent from a fresh snapshot of its source. A source that is
    /// loading, stale or failing says nothing, so its picks keep their value.
    pub fn recompute_done_since(&self, hub: &WorkHub) {
        if self.lock().items.is_empty() {
            return;
        }
        let presence = hub.source_presence();
        self.update(|snap| {
            for pick in &mut snap.items {
                let Some(source) = presence.iter().find(|p| p.status.source == pick.source) else {
                    continue;
                };
                if !is_authoritative(&source.status) || repo_group_failed(&source.status, &pick.item_id) {
                    continue;
                }
                pick.done_since = !source.ids.contains(&pick.item_id);
            }
        });
    }

    /// Send the current snapshot as a `TeriPicks` frame.
    pub fn broadcast(&self) {
        let snapshot = self.snapshot();
        // No receiver (no client connected) is fine.
        let _ = self.tx.send(ServerMsg::TeriPicks { picks: snapshot });
    }

    fn set_generating(&self) {
        self.update(|snap| snap.generating = true);
    }

    /// End a generation: `generating` goes false, and `error` is set when it failed.
    fn finish_generation(&self, error: Option<String>) {
        self.update(|snap| {
            snap.generating = false;
            if error.is_some() {
                snap.error = error;
            }
        });
    }

    fn subscribe_publishes(&self) -> watch::Receiver<u64> {
        self.publishes.subscribe()
    }

    /// Apply `change`; when it altered the snapshot, persist and broadcast it
    /// (under the lock, so frames go out in the order the changes happened).
    fn update<R>(&self, change: impl FnOnce(&mut PicksSnapshot) -> R) -> R {
        let mut guard = self.lock();
        let before = guard.clone();
        let result = change(&mut guard);
        if *guard != before {
            self.persist(&guard);
            let _ = self.tx.send(ServerMsg::TeriPicks { picks: guard.clone() });
        }
        result
    }

    fn lock(&self) -> MutexGuard<'_, PicksSnapshot> {
        self.snapshot.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Write the snapshot atomically (temp file, then rename). `generating` is
    /// never saved: it is a property of this process.
    fn persist(&self, snapshot: &PicksSnapshot) {
        let Some(path) = &self.path else { return };
        let saved = PicksSnapshot { generating: false, ..snapshot.clone() };
        let result = (|| -> std::io::Result<()> {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let tmp = path.with_extension("json.tmp");
            std::fs::write(&tmp, serde_json::to_vec_pretty(&saved)?)?;
            std::fs::rename(&tmp, path)
        })();
        if let Err(e) = result {
            warn!(path = %path.display(), "could not save picks: {e}");
        }
    }
}

/// Where the picks are kept: `<teri dir>/picks.json`.
pub fn default_path() -> PathBuf {
    super::sent::teri_dir().join("picks.json")
}

/// Sources the daemon could not give the agent items from: anything but fresh,
/// empty or stale (a stale source still holds items to pick from).
fn unavailable_sources(statuses: &[SourceStatus]) -> Vec<WorkSource> {
    statuses
        .iter()
        .filter(|s| !matches!(s.state, SourceState::Fresh | SourceState::Empty | SourceState::Stale))
        .map(|s| s.source)
        .collect()
}

/// Does `status` describe a complete, current listing, so that an item missing
/// from it is really gone? A fresh list with a note (for instance "results
/// truncated") is not complete.
fn is_authoritative(status: &SourceStatus) -> bool {
    matches!(status.state, SourceState::Fresh | SourceState::Empty) && status.reason.is_none()
}

/// A repo-docs item whose repo failed to scan is missing because of the failure.
fn repo_group_failed(status: &SourceStatus, item_id: &str) -> bool {
    let Some(rest) = item_id.strip_prefix("doc:") else { return false };
    let repo = rest.split(':').next().unwrap_or("");
    status.group_errors.iter().any(|e| e.group == repo)
}

// ── generation ────────────────────────────────────────────────────────────────

/// What the generator needs from the daemon's session manager.
pub trait PicksSessionHost: Send + Sync {
    /// Start a fresh hidden session. Must not register it as a focus.
    fn spawn(&self, tag: &str, agent: &str, cwd: &Path) -> Result<(), String>;
    /// Send the session its one message.
    fn send(&self, tag: &str, text: &str) -> Result<(), String>;
    fn is_alive(&self, _tag: &str) -> bool {
        true
    }
    /// End the session and forget it. Always called when a generation ends.
    fn stop(&self, tag: &str);
}

/// [`PicksSessionHost`] backed by the daemon's `SessionManager`.
pub struct SessionManagerHost {
    mgr: Arc<Mutex<SessionManager>>,
}

impl SessionManagerHost {
    pub fn new(mgr: Arc<Mutex<SessionManager>>) -> Self {
        Self { mgr }
    }

    fn mgr(&self) -> MutexGuard<'_, SessionManager> {
        self.mgr.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl PicksSessionHost for SessionManagerHost {
    fn spawn(&self, tag: &str, agent: &str, cwd: &Path) -> Result<(), String> {
        let mut mgr = self.mgr();
        // Every generation starts from a blank conversation, never a resumed one.
        mgr.new_session(tag);
        mgr.spawn_session(tag.into(), agent.into(), "Teri picks".into(), Some(cwd.to_path_buf()), None, false)
            .map(|_| ())
            .map_err(|e| format!("{e:#}"))
    }

    fn send(&self, tag: &str, text: &str) -> Result<(), String> {
        self.mgr().send_user_message(tag, text, &[]).map_err(|e| format!("{e:#}"))
    }

    fn is_alive(&self, tag: &str) -> bool {
        self.mgr().has_live_session(tag)
    }

    fn stop(&self, tag: &str) {
        // Stops the child, drops the entry and forgets the saved session id.
        self.mgr().new_session(tag);
    }
}

/// Runs picks generations, one at a time.
pub struct PicksGenerator {
    store: Arc<PicksStore>,
    host: Arc<dyn PicksSessionHost>,
    timeout: Duration,
    in_flight: AtomicBool,
}

impl PicksGenerator {
    pub fn new(store: Arc<PicksStore>, host: Arc<dyn PicksSessionHost>, timeout: Duration) -> Arc<Self> {
        Arc::new(Self { store, host, timeout, in_flight: AtomicBool::new(false) })
    }

    /// Handle a `PicksRefresh`. `first_open` and `manual` start a generation
    /// unless one is already running; `retention_lag` only re-sends the picks
    /// the daemon has. Returns once the generation has started.
    pub async fn refresh(self: &Arc<Self>, reason: &str) -> Result<(), WorkError> {
        match reason {
            "first_open" | "manual" => {}
            "retention_lag" => {
                self.store.broadcast();
                return Ok(());
            }
            _ => return Err(WorkError::new("invalid_argument", "unknown picks refresh reason")),
        }
        if self.in_flight.swap(true, Ordering::SeqCst) {
            return Ok(());
        }
        self.store.set_generating();
        let publishes = self.store.subscribe_publishes();
        let this = Arc::clone(self);
        tokio::spawn(async move { this.run(publishes).await });
        Ok(())
    }

    /// True from the moment a generation was accepted until its session is ended.
    pub fn is_generating(&self) -> bool {
        self.in_flight.load(Ordering::SeqCst)
    }

    async fn run(self: Arc<Self>, publishes: watch::Receiver<u64>) {
        let outcome = self.drive(publishes).await;
        // The session ends on every path, before anyone is told it is over.
        self.host.stop(PICKS_TAG);
        match outcome {
            Ok(()) => self.store.finish_generation(None),
            Err(reason) => self.store.finish_generation(Some(format!("Picks refresh failed: {reason}"))),
        }
        self.in_flight.store(false, Ordering::SeqCst);
    }

    /// Start the session, seed it and wait for it to publish.
    async fn drive(&self, mut publishes: watch::Receiver<u64>) -> Result<(), String> {
        let cwd = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
        self.host.spawn(PICKS_TAG, PICKS_AGENT, &cwd).map_err(|e| format!("could not start the session: {e}"))?;
        self.host.send(PICKS_TAG, PICKS_PROMPT).map_err(|e| format!("could not send the request: {e}"))?;

        let deadline = Instant::now() + self.timeout;
        loop {
            let wake = deadline.min(Instant::now() + ALIVE_POLL);
            tokio::select! {
                changed = publishes.changed() => {
                    return changed.map_err(|_| "the picks store went away".to_string());
                }
                _ = tokio::time::sleep_until(wake) => {}
            }
            if Instant::now() >= deadline {
                return Err(format!("timed out after {}", describe(self.timeout)));
            }
            if !self.host.is_alive(PICKS_TAG) {
                return Err("the session ended before it published".to_string());
            }
        }
    }
}

fn describe(d: Duration) -> String {
    let secs = d.as_secs();
    if secs >= 60 && secs.is_multiple_of(60) {
        let minutes = secs / 60;
        format!("{minutes} minute{}", if minutes == 1 { "" } else { "s" })
    } else if secs >= 1 {
        format!("{secs} s")
    } else {
        format!("{} ms", d.as_millis())
    }
}
