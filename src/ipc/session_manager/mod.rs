//! Daemon-side persistent stream-json session manager.
//!
//! `SessionManager` owns long-lived `claude` child processes on behalf of
//! `nostromd` so a session survives the GUI disconnecting, crashing, or
//! restarting. It is the daemon-side home of the persistent
//! `--input-format stream-json --output-format stream-json` session host.
//!
//! ## One process per focus
//!
//! Each focus `tag` is backed by **one** long-lived child:
//!
//! ```text
//! claude --dangerously-skip-permissions \
//!        --input-format stream-json --output-format stream-json --verbose \
//!        --replay-user-messages --agent <agent> -n <view> \
//!        [--remote-control <view>] (--session-id <uuid> | --resume <uuid>)
//! ```
//!
//! `--replay-user-messages` is always passed so every stdin-origin user message
//! is re-emitted on stdout tagged `"isReplay": true`. The daemon therefore
//! renders **all** user messages off the output stream (the unified input
//! model) — `send_user_message` only injects to stdin and never separately
//! broadcasts the local message; it comes back on the output stream like any
//! other turn. (Spike-confirmed against `claude` 2.1.158.)
//!
//! ## Output fan-out
//!
//! A blocking reader thread parses the child's stdout line-by-line into the
//! shared [`SessionTranscript`] and broadcasts [`SessionEvent`]s. A per-attached
//! client forwarder converts events into `ServerMsg::SessionTurnDelta` /
//! `SessionState` / `SessionExited` and writes them to the client's
//! per-connection sender; **multiple** clients may attach to one tag (mirroring is a broadcast).

use std::collections::{HashMap, HashSet, VecDeque};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, Result};
use tokio::sync::{broadcast, mpsc, oneshot};
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use serde::{Deserialize, Serialize};

use crate::approvals::broker::{
    deny_response, ApprovalBroker, Incoming, SessionInfo as ApprovalSessionInfo, SessionSink,
    APPROVAL_UNAVAILABLE_MESSAGE, INVALID_REQUEST_MESSAGE, UNSUPPORTED_REQUEST_ERROR,
};

use super::auth_failure::{classify_line, TurnAuthTracker};
use super::claude_login::{LoginCoordinator, LOGIN_QUEUE_CAP};
use super::decisions::DecisionRegistry;
use super::orphans::{
    self, child_unreaped, ledger_path_beside, ChildLedger, Target, MARKER_ENV,
    SESSIONS_LEAD_OWN_GROUP, SHUTDOWN_GRACE,
};
use super::pane_registry::{
    PaneContentProvider, PaneRegistry, PerriStateProvider, TrackerFrameProvider,
};
use super::peer::{
    in_work_send, is_huey_agent, is_teri_or_fred_agent, registry_path_beside, SensitiveTags,
};
use super::protocol::{FocusMeta, ServerMsg, SessionInfo, TaskDetailMsg, TasksSnapshot};
use super::stream_json::{
    load_scrollback, parse_line, ParsedLine, SessionState, SessionTranscript, TurnDelta,
    NOSTROMO_NOTE_CLOSE, NOSTROMO_NOTE_OPEN, SCROLLBACK_TURNS,
};
use crate::model::hub::ModelHub;
use crate::model::notes::{self, NoteKind};
use crate::model::store as model_store;
use crate::model::{Actor, ModelPaths, ModelTarget};
use crate::mother::origin::OriginCaller;
use crate::mother::{OriginBook, SessionHistory};

mod control;
mod inject;
#[cfg(test)]
mod inject_tests;
mod login;
mod model_switch;
mod task_runtime;
use control::ControlReply;
pub use control::CONTROL_TIMEOUT;
use inject::PendingOrigin;
pub use inject::{SessionEndHook, INJECT_MERGE_CAP, SELECTION_KEY_PREFIX};
pub use login::{ResendOutcome, ResendTrigger};
use model_switch::{
    emit_note, model_args, on_model_report, publish_model_state, spawn_apply, ModelRuntime,
    SessionCtx,
};
pub use model_switch::{ModelRequestOutcome, ModelSweep, SwitchRequest, SwitchTicket};
use task_runtime::{
    detail_msg, drive_timer, ensure_poller, ensure_probe, forward_session_events, read_output,
    stop_task, tasks_msg, TaskRuntime,
};
pub use task_runtime::{OutputReply, StopReport, TaskIoConfig};

/// Env var overriding the resolved `claude` binary path (used by tests and by
/// operators with a non-standard install).
pub const CLAUDE_BIN_ENV: &str = "NOSTROMO_CLAUDE_BIN";

/// Crash-loop guard: at most this many auto-restarts within the sliding window.
const MAX_RESTARTS: u32 = 3;
/// Sliding-window span. A crash older than this falls off the back of the
/// crash-timestamp deque and no longer counts toward the guard.
const RESTART_WINDOW_SECS: u64 = 30;
/// Exponential-backoff base: wait `BACKOFF_BASE_SECS * 2^(n-1)` before the nth
/// transient restart (n = number of crashes already recorded this window).
const BACKOFF_BASE_SECS: u64 = 1;
/// Cap on a single backoff delay so a high crash count can't schedule an
/// absurd wait.
const BACKOFF_MAX_SECS: u64 = 60;

// ── stop reason ──────────────────────────────────────────────────────────────

/// Why a session was intentionally stopped (`alive == false`, but not a crash
/// the supervisor should recover from). Lets the GUI distinguish a benign
/// user-requested stop from an alarm-worthy crash-loop-guard trip.
///
/// `StaleId` is defined for wire completeness and future use; the daemon does
/// **not** set it today — the stale-id path clears the id and auto-respawns
/// fresh, so the session is never left intentionally stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    User,
    CrashLoopGuard,
    StaleId,
}

// ── broadcast event ─────────────────────────────────────────────────────────

/// Output unit broadcast by a session's reader thread.
#[derive(Debug, Clone)]
pub enum SessionEvent {
    Delta(TurnDelta),
    State(SessionState),
    Exited {
        exit_code: Option<i32>,
    },
    /// The session has been permanently stopped and will not auto-restart.
    /// Complements `Exited` (which fires on every exit) — this fires only when
    /// the supervisor has decided it is done trying. Clients should show a
    /// health indicator and offer recovery actions.
    PermanentlyDown {
        reason: StopReason,
    },
    /// The session's background tasks changed: the full list (REPLACE).
    Tasks(Arc<TasksSnapshot>),
    /// The text of one background task changed (preview, summaries, prompt).
    /// Carried only by a `LocalOnly` frame.
    TaskDetail(Arc<TaskDetailMsg>),
}

// ── pending-message queue ─────────────────────────────────────────────────────

/// A user message waiting in the pending queue, preserving image paths so they
/// survive the queued-until-idle path without being dropped.
#[derive(Clone, Debug)]
struct PendingMessage {
    text: String,
    /// Absolute file paths; daemon reads + base64-encodes at drain time.
    images: Vec<String>,
    /// The user's, or the daemon's (combinable; see `inject`).
    origin: PendingOrigin,
}

// ── shared, reader-thread-visible session state ───────────────────────────────

/// State shared between the manager (under its Mutex), the detached reader
/// thread and a running model-switch task. Cloneable `Arc` handles only — no
/// back-reference to the manager.
///
/// Lock order, wherever more than one is held:
/// `model_io` → `state` → `model` → `pending`.
/// The task runtime's `hub` lock (in `tasks`) may be held while the
/// `transcript` lock is taken, never the reverse.
/// `stdin`, `note_prefix`, `transcript`, `waiters` and the `login` cell are leaf
/// locks: they may be taken while holding the others, but nothing else is ever
/// acquired while one of them is held.
///
/// Nothing slow runs under `state` or `model`: those are read by `info()` and
/// `list()` under the manager lock, so a blocking write to a stalled CLI's
/// stdin (a large image frame into a full pipe) or a disk write under either
/// would wedge the manager for every session. A user frame is written after
/// `state` is released, with `writing` set so a restart or crash recovery
/// (`take_carry`) waits for the write's outcome instead of missing the
/// message; `begin_switch` does its store and ledger writes under `model_io`
/// alone, which `apply_switch` also takes before it touches the same records.
#[derive(Clone)]
struct Shared {
    transcript: Arc<Mutex<SessionTranscript>>,
    /// Child stdin for writing user-message frames (manager + reader drain).
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    /// Queued user messages awaiting an idle turn.
    pending: Arc<Mutex<VecDeque<PendingMessage>>>,
    /// Single source of truth for the live turn state.
    state: Arc<Mutex<SessionState>>,
    /// Set by the reader on stdout EOF (child exited / stream closed).
    exited: Arc<AtomicBool>,
    event_tx: broadcast::Sender<SessionEvent>,
    /// The model this session runs and any switch in progress.
    model: Arc<Mutex<ModelRuntime>>,
    /// Control requests awaiting their `control_response`, by request id. The
    /// reader resolves them; it never waits on one itself.
    waiters: Arc<Mutex<HashMap<String, oneshot::Sender<ControlReply>>>>,
    /// A queued message was taken off `pending` and its stdin write has not
    /// finished. Set under `state`, cleared by the writer once the message is
    /// either written or back on `pending`.
    writing: Arc<AtomicBool>,
    /// Orders a switch request's store/ledger writes against `apply_switch`'s
    /// (see the lock-order note above). Holds no data.
    model_io: Arc<Mutex<()>>,
    /// Who this session is, for notes, the store and activity lines.
    ctx: Arc<SessionCtx>,
    /// One line for the agent's eyes, put in front of the next user message
    /// written (`<nostromo-note>…</nostromo-note>`). Nothing sets it yet: the
    /// agent-request slice fills it.
    note_prefix: Arc<Mutex<Option<String>>>,
    /// Runtime the reader thread spawns switch tasks on.
    runtime: tokio::runtime::Handle,
    /// The session's background tasks: registry, publication, previews.
    tasks: Arc<TaskRuntime>,
    /// The message of a turn that failed to authenticate, held while the session
    /// waits for a Claude sign-in (a leaf lock; see `login.rs`).
    login: Arc<login::LoginLink>,
}

/// Lock `m`, taking the data even if a panicking holder poisoned it. For the
/// switch machinery's own cleanup, which must still run after such a panic.
fn lock_recover<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The attached clients that are local peers: the ones task previews are for.
fn local_client_count(attached: &HashSet<String>, network: &HashSet<String>) -> usize {
    attached.iter().filter(|c| !network.contains(*c)).count()
}

impl Shared {
    fn broadcast(&self, ev: SessionEvent) {
        let _ = self.event_tx.send(ev);
    }

    fn set_state(&self, s: SessionState) {
        *lock_recover(&self.state) = s;
        self.broadcast(SessionEvent::State(s));
    }
}

// ── restricted sessions ───────────────────────────────────────────────────────

/// What an unattended session that reads third-party text may do.
///
/// A session with restrictions runs WITHOUT `--dangerously-skip-permissions`:
/// `--permission-mode dontAsk` denies anything not pre-approved, and the
/// allow-list is the control. Three layers, so no single flag is trusted:
///
/// 1. `--tools` removes every built-in tool not in [`Self::builtin_tools`] (no
///    Bash, Write, Edit, Agent, WebFetch ...),
/// 2. `--allowedTools` pre-approves only [`Self::allowed_tools`]; the rest is
///    denied rather than prompted,
/// 3. `--strict-mcp-config` loads only the daemon's own MCP bridge, and the
///    daemon's MCP dispatch separately limits this tag to its own tool list
///    (see `mcp::tools`), whatever the client asks for.
///
/// The session also runs in its own process group, which `stop` kills whole.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionRestrictions {
    /// Built-in tools left available (`--tools`); empty means none.
    pub builtin_tools: Vec<String>,
    /// Tools pre-approved (`--allowedTools`), MCP tools as `mcp__<server>__<tool>`.
    pub allowed_tools: Vec<String>,
    /// Hard spend cap for the session (`--max-budget-usd`).
    pub max_budget_usd: Option<f64>,
    /// The model the session runs on (`--model`); `None` is the CLI default.
    /// A restricted session never takes a focus's recorded model.
    pub model: Option<String>,
}

// ── managed session ───────────────────────────────────────────────────────────

struct ManagedSession {
    tag: String,
    agent_name: String,
    view_name: String,
    cwd: Option<PathBuf>,
    remote_control: bool,
    /// Resolved `claude` session id (persisted in the id store).
    session_id: Option<String>,
    child: Child,
    /// Set the moment this manager reaps `child` (`try_reap`). A reaped child's
    /// pid is free to be given to a stranger, so nothing may be signalled by
    /// that pid afterwards; `stop_target` checks this before it asks the OS.
    reaped: bool,
    /// Whether the child's pid is still an unreaped child of ours. Always
    /// [`child_unreaped`]; a field so tests can simulate a reused pid.
    unreaped_probe: fn(u32) -> bool,
    shared: Shared,
    /// How to respawn on restart. `None` → a real `claude` session (rebuild
    /// args with `--resume`). `Some((program, args))` → replay this exact
    /// program/args verbatim (used by tests to inject a stub child so restart
    /// never touches the real `claude` binary or the network).
    respawn_fixed: Option<(PathBuf, Vec<String>)>,
    /// Set true immediately before an intentional kill so the supervisor does
    /// not treat the resulting EOF as a crash to recover from.
    intentional_stop: Arc<AtomicBool>,
    /// Set by the stderr drain when the child emits "No conversation found",
    /// signalling a stale persisted session id. `reap_and_recover` checks this
    /// before the crash-loop guard and spawns fresh rather than retrying --resume.
    stale_session_id: Arc<AtomicBool>,
    attached_clients: HashSet<String>,
    /// Per-client forwarder abort handles.
    forwarders: HashMap<String, tokio::task::AbortHandle>,
    _reader_task: tokio::task::JoinHandle<()>,
    /// Sliding window of recent crash timestamps. On each detected crash we
    /// push `Instant::now()`, then evict entries older than RESTART_WINDOW_SECS
    /// from the front. `crash_times.len()` is the live crash count; when it
    /// reaches MAX_RESTARTS the crash-loop guard trips. Replaces the old
    /// fixed-window `restart_count` + `restart_window_start`.
    crash_times: VecDeque<Instant>,
    /// When set, `reap_and_recover` must not restart this session until
    /// `Instant::now() >= restart_at` — the exponential-backoff deadline for a
    /// transient (non-zero-exit) crash. `None` means "no pending backoff".
    restart_at: Option<Instant>,
    /// Last observed child exit code, captured via `child.try_wait()` in
    /// `reap_and_recover`. `None` = not yet reaped, killed by signal, or clean
    /// unknown. Surfaced through `SessionEvent::Exited { exit_code }`.
    last_exit_code: Option<i32>,
    /// Why this session is intentionally stopped, if it is. Set by `stop()`
    /// (User), the crash-loop guard in `reap_and_recover` (CrashLoopGuard), or
    /// `kill_all_on_shutdown` (left None — daemon teardown). Cleared (reset to
    /// None) whenever a new `ManagedSession` is spawned by `restart()`.
    pub(crate) stop_reason: Option<StopReason>,
    /// Guards the one-shot `SessionSummaryUpdate` emission per session lifetime.
    /// Set to `true` once the summary has been derived and broadcast to all
    /// connected clients. Resets on restart (new `ManagedSession`).
    summary_sent: Arc<AtomicBool>,
    /// The child leads its own process group (every session, see
    /// `SESSIONS_LEAD_OWN_GROUP`), so a kill takes its children and subagents
    /// with it.
    own_process_group: bool,
    /// The daemon's record of its CLIs; this child is forgotten once killed.
    ledger: Arc<ChildLedger>,
    /// The approval broker's generation number for this process, when the
    /// session is approval-capable and a broker is configured.
    approval_generation: Option<u64>,
}

impl ManagedSession {
    fn alive(&self) -> bool {
        !self.shared.exited.load(Ordering::SeqCst)
    }

    /// Can a held message of this session still be resent? Not once it is
    /// stopped (by the user or the crash-loop guard) or while its process is down
    /// (a respawn takes the hold along, see `take_carry`).
    fn waits_for_login(&self) -> bool {
        self.alive() && self.stop_reason.is_none()
    }

    /// Non-blocking reap of the child. The one place this manager waits for it:
    /// a `Some` records that the pid is no longer ours (`reaped`).
    fn try_reap(&mut self) -> Option<std::process::ExitStatus> {
        match self.child.try_wait() {
            Ok(Some(status)) => {
                self.reaped = true;
                Some(status)
            }
            _ => None,
        }
    }

    /// Kill the child, and its whole process group when it leads one.
    fn kill(&mut self) {
        self.signal_kill();
        self.ledger.forget(self.child.id());
    }

    /// SIGKILL the child and its group, leaving the ledger as it is.
    ///
    /// The group is signalled only while the child is still unreaped, running
    /// or exited and not yet waited for (`stop_target`'s rule): the group id is the child's pid, and once the
    /// child has been reaped (`reap_and_recover` does so for a crashed CLI)
    /// that pid is free to be given to a stranger who leads a group of its
    /// own. A reaped child gets `Child::kill`, which sends nothing for a
    /// child that has already been waited for.
    fn signal_kill(&mut self) {
        #[cfg(unix)]
        if let Some(Target::Group(g)) = self.stop_target() {
            // SAFETY: killpg is a plain syscall; the child is unreaped, so its
            // pid, and with it the group id, cannot have been reused.
            unsafe {
                libc::killpg(g as libc::pid_t, libc::SIGKILL);
            }
        }
        let _ = self.child.kill();
    }

    /// What a graceful stop aims at: the child's group when it leads one, else
    /// the child. `None` once the child has been reaped: its pid may since have
    /// been given to something else, and a signal to it would hit a stranger.
    ///
    /// A child this manager has reaped is never probed: once its pid is free,
    /// another child of the daemon may hold it, and a probe that only asks
    /// "is this pid one of my unreaped children?" would say yes for that
    /// stranger. Only an unreaped child is then checked, without reaping: an
    /// exited CLI nobody has waited for yet still holds its pid, so its group
    /// (the subagents and servers it left) is still ours to signal, and asking
    /// must not be what frees the pid.
    fn stop_target(&mut self) -> Option<Target> {
        if self.reaped || !(self.unreaped_probe)(self.child.id()) {
            return None;
        }
        Some(if self.own_process_group {
            Target::Group(self.child.id())
        } else {
            Target::Pid(self.child.id())
        })
    }

    fn state(&self) -> SessionState {
        *lock_recover(&self.shared.state)
    }

    fn info(&self) -> SessionInfo {
        SessionInfo {
            tag: self.tag.clone(),
            agent_name: self.agent_name.clone(),
            view_name: self.view_name.clone(),
            session_id: self.session_id.clone(),
            alive: self.alive(),
            remote_control: self.remote_control,
            state: self.state(),
            stop_reason: self.stop_reason,
            // Known only to the manager (it holds the bridge registry).
            mcp_bridge_connected: None,
        }
    }
}

// ── SessionManager ────────────────────────────────────────────────────────────

/// Shared daemon-side registry of running stream-json sessions.
///
/// All public methods take `&mut self` — callers hold the wrapping Mutex.
pub struct SessionManager {
    sessions: HashMap<String, ManagedSession>,
    client_senders: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>>,
    /// Path to the daemon-owned `tag -> session_id` store.
    store_path: PathBuf,
    /// Every session id this daemon has spawned for each tag (beside the
    /// store): what a Mother job's claimed session is checked against.
    session_history: SessionHistory,
    /// Who queued each Mother job, when the daemon wires one in. Fed the
    /// focus registry here so a focus's current name and `closed` follow it.
    origin_book: Option<OriginBook>,
    /// Every CLI this daemon has spawned, on disk beside the store, so the next
    /// start can reap what this one could not.
    ledger: Arc<ChildLedger>,
    /// Mac-pushed focus registry; served to all clients and broadcast on change.
    focus_registry: Vec<FocusMeta>,
    /// Live MCP bridge connections per tag; `None` until the daemon wires the
    /// MCP server in (tests, or a daemon without one).
    bridges: Option<Arc<crate::mcp::BridgeRegistry>>,
    /// Tags this daemon created itself, via `nostromo.create_focus`, that no
    /// client has acknowledged yet (W7 — D8b).
    ///
    /// A tag enters here at `add_or_update_focus` and leaves the first time a
    /// `FocusRegistryPush` names it; from then on the ordinary
    /// two-consecutive-push rule governs it exactly like a Mac-created focus.
    /// The exemption covers the window between creating a focus and the
    /// client's first acknowledging push (~200ms of debounce on the Mac), and
    /// a client that never pushes the tag at all — an older build, or a
    /// non-Mac client. Without it, a naive "in the old list, not in the new
    /// one" diff would evict an agent-created focus the moment anything was
    /// pushed.
    ///
    /// **It must expire.** It used to be permanent, on the stated grounds that
    /// "the Mac's `focuses.json` has never heard of these, so every push omits
    /// them" — which was not the mechanism. The Mac hears about a created
    /// focus immediately (`AppStore`'s `.focusCreated` adds it to `FocusStore`,
    /// which persists it and triggers a push); what it could not do was push
    /// the tag *back* faithfully, because `Focus.sessionTag` re-derived a tag
    /// from a value that already was one. A permanent exemption meant a
    /// daemon-created tag could never appear in `departed`, and `departed` is
    /// the only path that deletes a PR pin — so an agent-created focus's pin
    /// outlived it, and `nostromo.create_focus`'s deterministic
    /// `(agent, title)` tag handed it straight to the next focus of the same
    /// name. That is the PRD's "a removed focus's pin never resurfaces"
    /// criterion failing for the one class of focus where tag reuse is
    /// guaranteed.
    daemon_created_tags: HashSet<String>,
    /// Tags one push claimed were gone, awaiting a second push that agrees
    /// (W7 — D8a).
    ///
    /// `set_focus_registry` runs on every reconnect, and a reconnecting client
    /// can push a partial list before it has finished loading. Evicting on a
    /// single push would make a routine reconnect destroy a focus's pin.
    /// Departure therefore requires two consecutive pushes to agree.
    pending_departures: HashSet<String>,
    /// How many non-empty focus registry pushes this daemon has processed
    /// *since it last had a picture of the registry worth vouching for*
    /// (W7 — D8 backstop). Saturates; only "at least two" is ever asked.
    ///
    /// Gates [`SessionManager::reconcilable_focus_tags`]. An empty push does
    /// not merely fail to count — it resets this to zero; see that method's
    /// doc for why.
    non_empty_pushes_seen: u8,
    /// Per-focus pane-tree registry. Set by the daemon via
    /// [`SessionManager::configure_mcp_bridge`]; `None` in tests / non-daemon use.
    /// A fresh (non-resume) spawn initialises the focus's tree to a single REPL
    /// leaf so the agent's first turn assembles from a known baseline.
    pane_registry: Option<Arc<Mutex<PaneRegistry>>>,
    /// Daemon MCP socket path injected as `NOSTROMO_MCP_SOCKET` into sessions.
    mcp_socket: Option<PathBuf>,
    /// `--mcp-config` file path registering the `nostromo-mcp-bridge` stdio server.
    mcp_config: Option<PathBuf>,
    /// Supplies current pane content for attach replay (D8). Set by the
    /// daemon via [`SessionManager::configure_pane_content_provider`]; `None`
    /// in tests / non-daemon use.
    pane_content_provider: Option<Arc<dyn PaneContentProvider>>,
    /// The tracker's attach-replay hook; `None` until the daemon wires it.
    tracker_frame_provider: Option<Arc<dyn TrackerFrameProvider>>,
    /// Supplies the current Perri queue + current-PR snapshot for attach
    /// replay (f1). Set by the daemon via
    /// [`SessionManager::configure_perri_state_provider`]; `None` in tests /
    /// non-daemon use.
    perri_state_provider: Option<Arc<dyn PerriStateProvider>>,
    /// Built-in agents this daemon runs; reported in the `welcome` frame.
    enabled_agents: crate::agents::EnabledAgents,
    /// Shared decision-modal registry. Set by the daemon via
    /// [`SessionManager::configure_decisions`]; `None` in tests / non-daemon
    /// use. When a session goes permanently down (explicit stop or the
    /// crash-loop guard tripping), its tag's pending decision requests are
    /// cancelled here (D3/W6) — a decision nobody can answer must not block
    /// its caller forever.
    decisions: Option<Arc<Mutex<DecisionRegistry>>>,
    /// Reverse index: `claude` session id -> focus tag. Maintained at
    /// [`SessionManager::spawn_session`] and [`SessionManager::restart`] as
    /// each `effective_id` is resolved; seedable from the on-disk id store
    /// via [`SessionManager::seed_reverse_index`] for sessions spawned by a
    /// daemon process that predates this index (activity-path wedge D7).
    session_reverse: HashMap<String, String>,
    /// Bounded, attributed ambient-activity streams (activity-path wedge).
    /// Lives here — not threaded separately through `Server`/`McpSharedState`
    /// — because attribution needs exactly the state this type already owns
    /// (the live `sessions` map and the `session_reverse` index).
    activity_store: crate::activity::store::ActivityStore,
    /// Focus tags / Mother jobs that carry Teri/Fred-derived content, which a
    /// network (TCP) peer must neither read nor drive. See
    /// [`SensitiveTags`]; persisted beside the session id store.
    sensitive: SensitiveTags,
    /// Clients that are network (TCP) peers. They are attached like any
    /// other, but they do not count as a reason to poll task previews: the
    /// previews never reach them.
    network_clients: HashSet<String>,
    /// Per focus tag: the nonce of the focus `create_focus_core` last created
    /// under it. In memory only (a restart forgets it).
    focus_nonces: HashMap<String, String>,
    /// Per focus tag: the tool allow-list and cost cap its session runs under
    /// (see [`SessionRestrictions`]). Looked up on EVERY spawn of the tag, so a
    /// restart, a crash recovery or a client-driven respawn is restricted too.
    restrictions: HashMap<String, SessionRestrictions>,
    /// Model state shared by every session: files, catalogue, broadcasts.
    model_hub: Arc<ModelHub>,
    /// The `nostromo-guard` binary every spawned session's PreToolUse hook
    /// runs (see [`build_claude_args_with`]). `nostromd` sets it from
    /// [`crate::approvals::guard::resolve_guard_path`]; a path that doesn't
    /// exist fails closed (every tool call is blocked).
    guard_path: PathBuf,
    /// The approval broker: hears every permission request of an
    /// approval-capable session and always answers it. `None` in tests and
    /// non-daemon use; such a session's requests are denied at once by its
    /// reader instead.
    approvals: Option<ApprovalBroker>,
    /// Test hook ([`SessionManager::omit_guard_hook_for_test`]): spawn sessions
    /// without the guard's `--settings` element, to prove the broker holds
    /// nothing for them.
    omit_guard_hook: bool,
    /// Tells clients which sessions wait for a Claude sign-in and watches the
    /// credential; `None` in tests and non-daemon use, where a session still
    /// holds a failed message but nothing is published and nothing resends it.
    login: Option<Arc<LoginCoordinator>>,
    /// Where `claude` was last found (`login_snapshot`); see `claude_bin`.
    claude_bin_cache: Mutex<Option<(Option<PathBuf>, Instant)>>,
    /// How new sessions read and control their background tasks.
    task_io: TaskIoConfig,
    /// Told when a session ends (terminal follow ends with it).
    session_end_hook: Option<SessionEndHook>,
}

impl SessionManager {
    pub fn new() -> Self {
        let mut mgr = Self::with_store_path(default_store_path());
        mgr.guard_path = crate::approvals::guard::resolve_guard_path();
        mgr
    }

    pub fn with_store_path(store_path: PathBuf) -> Self {
        let stored = load_id_store(&store_path);
        let sensitive = SensitiveTags::persisted_for_sessions(
            registry_path_beside(&store_path),
            !stored.is_empty(),
        );
        if sensitive.is_degraded() {
            // The registry may have lost registrations (a failed write before
            // this start, or it is missing while sessions exist), so every
            // stored session is treated as sensitive: each is registered now,
            // before any client can connect.
            for tag in stored.keys() {
                sensitive.note_resumed(tag);
            }
            sensitive.settle_lost_history();
        }
        let model_hub = Arc::new(ModelHub::new(ModelPaths::beside(&store_path)));
        Self {
            model_hub,
            sessions: HashMap::new(),
            client_senders: Arc::new(Mutex::new(HashMap::new())),
            ledger: Arc::new(ChildLedger::new(ledger_path_beside(&store_path))),
            session_history: SessionHistory::open(SessionHistory::path_beside(&store_path)),
            origin_book: None,
            store_path,
            focus_registry: Vec::new(),
            bridges: None,
            network_clients: HashSet::new(),
            daemon_created_tags: HashSet::new(),
            pending_departures: HashSet::new(),
            non_empty_pushes_seen: 0,
            pane_registry: None,
            mcp_socket: None,
            mcp_config: None,
            pane_content_provider: None,
            tracker_frame_provider: None,
            perri_state_provider: None,
            enabled_agents: crate::agents::EnabledAgents::all(),
            decisions: None,
            session_reverse: HashMap::new(),
            activity_store: crate::activity::store::ActivityStore::new(),
            sensitive,
            focus_nonces: HashMap::new(),
            // The picking session's tag is boxed in from the start, not from the
            // moment the picks host spawns it: whoever starts a session under
            // that tag (a client, a respawn) gets the same allow-list.
            restrictions: HashMap::from([
                (
                    crate::data::work::picks::PICKS_TAG.to_owned(),
                    crate::data::work::picks::picks_restrictions(),
                ),
                // Huey's curating session likewise; each run re-registers it
                // with its mode's model and cap.
                (
                    crate::huey::curate::HUEY_RUN_TAG.to_owned(),
                    crate::huey::curate::default_huey_run_restrictions(),
                ),
            ]),
            // Tests: `NOSTROMO_GUARD_BIN`, else a path that fails closed. Never
            // a binary found beside the test executable.
            guard_path: std::env::var_os(crate::approvals::guard::GUARD_BIN_ENV)
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(crate::approvals::guard::GUARD_SENTINEL_PATH)),
            approvals: None,
            omit_guard_hook: false,
            login: None,
            claude_bin_cache: Mutex::new(None),
            task_io: TaskIoConfig::default(),
            session_end_hook: None,
        }
    }

    /// Give sessions spawned from now on an approval broker to ask.
    pub fn configure_approvals(&mut self, broker: ApprovalBroker) {
        self.approvals = Some(broker);
    }

    /// The approval broker, if one is configured.
    pub fn approvals(&self) -> Option<&ApprovalBroker> {
        self.approvals.as_ref()
    }

    /// Spawn sessions from now on **without** the guard hook in their arguments.
    /// For the ordering-rule test only: such a session must never have a request
    /// held for a human.
    #[doc(hidden)]
    pub fn omit_guard_hook_for_test(&mut self) {
        self.omit_guard_hook = true;
    }

    /// The guard binary sessions spawned from now on run as their PreToolUse hook.
    pub fn guard_path(&self) -> &Path {
        &self.guard_path
    }

    /// Set the guard binary (`nostromd`, at startup).
    pub fn set_guard_path(&mut self, path: PathBuf) {
        self.guard_path = path;
    }

    /// True iff `args` (a session's `claude` argv) carries this manager's guard
    /// hook: the element after `--settings` equals
    /// [`crate::approvals::guard::hook_settings_json`] for [`Self::guard_path`].
    /// The approval broker only holds requests from such sessions.
    pub fn session_has_guard(&self, args: &[String]) -> bool {
        let expected = crate::approvals::guard::hook_settings_json(&self.guard_path);
        args.windows(2)
            .any(|w| w[0] == "--settings" && w[1] == expected)
    }

    /// The registry of sensitive tags/jobs (a shared handle: clones see the
    /// same registrations).
    pub fn sensitive_tags(&self) -> SensitiveTags {
        self.sensitive.clone()
    }

    /// Wire the daemon-hosted MCP bridge: the shared pane registry plus the
    /// socket + config paths injected into every freshly spawned session so the
    /// child `claude` can reach the layout/introspection tool surface.
    pub fn configure_mcp_bridge(
        &mut self,
        pane_registry: Arc<Mutex<PaneRegistry>>,
        mcp_socket: PathBuf,
        mcp_config: PathBuf,
    ) {
        self.pane_registry = Some(pane_registry);
        self.mcp_socket = Some(mcp_socket);
        self.mcp_config = Some(mcp_config);
    }

    /// Access the shared pane registry (if wired up). Used by the IPC server
    /// to replay layout state to newly connected clients without threading
    /// the Arc through every accept-loop call site.
    pub fn pane_registry(&self) -> Option<Arc<Mutex<PaneRegistry>>> {
        self.pane_registry.clone()
    }

    /// Wire the registry of live MCP bridge connections, so session lists and
    /// attaches can say whether a session's `mcp__nostromo__*` tools are online.
    pub fn configure_bridge_registry(&mut self, bridges: Arc<crate::mcp::BridgeRegistry>) {
        self.bridges = Some(bridges);
    }

    /// `Some(connected)` once a bridge has identified as `tag`; `None` when
    /// none ever has (or no registry is wired).
    fn bridge_connected(&self, tag: &str) -> Option<bool> {
        self.bridges.as_ref().and_then(|b| b.connected(tag))
    }

    /// Wire the [`PaneContentProvider`] the daemon exposes over its
    /// `McpSharedState`, so `server.rs` can replay live pane content to a
    /// newly (re)connected client (D8).
    pub fn configure_pane_content_provider(&mut self, provider: Arc<dyn PaneContentProvider>) {
        self.pane_content_provider = Some(provider);
    }

    /// Wire the [`TrackerFrameProvider`] so `server.rs` can replay each bound
    /// focus's tracker frames to a newly (re)connected client.
    pub fn configure_tracker_frame_provider(&mut self, provider: Arc<dyn TrackerFrameProvider>) {
        self.tracker_frame_provider = Some(provider);
    }

    /// Access the tracker frame provider (if wired up).
    pub fn tracker_frame_provider(&self) -> Option<Arc<dyn TrackerFrameProvider>> {
        self.tracker_frame_provider.clone()
    }

    /// Wire the shared decision-modal registry so a session going
    /// permanently down cancels its tag's pending decisions (D3/W6).
    pub fn configure_decisions(&mut self, registry: Arc<Mutex<DecisionRegistry>>) {
        self.decisions = Some(registry);
    }

    /// Access the pane-content provider (if wired up).
    pub fn pane_content_provider(&self) -> Option<Arc<dyn PaneContentProvider>> {
        self.pane_content_provider.clone()
    }

    /// Set which built-in agents this daemon runs (reported in `welcome`).
    pub fn configure_enabled_agents(&mut self, e: crate::agents::EnabledAgents) {
        self.enabled_agents = e;
    }

    /// The built-in agents this daemon runs.
    pub fn enabled_agents(&self) -> crate::agents::EnabledAgents {
        self.enabled_agents
    }

    /// Wire the [`PerriStateProvider`] the daemon exposes over its live Perri
    /// watch channels, so `server.rs` can replay the current queue/current-PR
    /// snapshot to a newly (re)connected client (f1).
    pub fn configure_perri_state_provider(&mut self, provider: Arc<dyn PerriStateProvider>) {
        self.perri_state_provider = Some(provider);
    }

    /// Access the Perri-state provider (if wired up).
    pub fn perri_state_provider(&self) -> Option<Arc<dyn PerriStateProvider>> {
        self.perri_state_provider.clone()
    }

    pub fn client_sender_registry(
        &self,
    ) -> Arc<Mutex<HashMap<String, mpsc::UnboundedSender<ServerMsg>>>> {
        Arc::clone(&self.client_senders)
    }

    // ── session-id reverse index (activity-path wedge) ────────────────────────

    /// Look up the focus tag that owns a `claude` session id, via the
    /// in-memory reverse index maintained by [`SessionManager::spawn_session`]
    /// and [`SessionManager::restart`]. Returns `None` for an id the daemon
    /// has never resolved a tag for — the unattributed path (attribution
    /// policy itself lives in `activity::store`, not here).
    pub fn tag_for_session_id(&self, session_id: &str) -> Option<String> {
        self.session_reverse.get(session_id).cloned()
    }

    /// Populate the reverse index from the on-disk `tag -> session_id` store.
    /// Covers sessions spawned by a daemon process that predates this index
    /// (e.g. across a daemon upgrade) — their reverse mapping only ever lived
    /// in memory, so a fresh process must reseed it from what's persisted.
    pub fn seed_reverse_index(&mut self) {
        for (tag, sid) in load_id_store(&self.store_path) {
            self.session_reverse.insert(sid, tag);
        }
    }

    // ── ambient activity (activity-path wedge) ────────────────────────────────

    /// Does the daemon know `tag` as a focus — either a session has been
    /// spawned under it, or it's present in the Mac-pushed focus registry?
    /// Used to resolve `ActivityEvent::focus_tag` before falling back to the
    /// session-id reverse index (D2).
    fn knows_focus(&self, tag: &str) -> bool {
        self.sessions.contains_key(tag) || self.focus_registry.iter().any(|f| f.tag == tag)
    }

    /// Resolve attribution for one raw activity event, in the order the PRD
    /// specifies: `focus_tag` (if it names a focus the daemon knows), then
    /// the `session_id` reverse index, then unattributed — never dropped,
    /// never assigned to an arbitrary focus.
    fn resolve_attribution(
        &self,
        event: &crate::agent_bus::ActivityEvent,
    ) -> crate::activity::store::Attribution {
        use crate::activity::store::Attribution;

        let from_focus_tag = event
            .focus_tag
            .as_ref()
            .filter(|tag| self.knows_focus(tag))
            .cloned();
        let from_session_id = event
            .session_id
            .as_ref()
            .and_then(|sid| self.tag_for_session_id(sid));
        // The two normally agree. When they do not, a sensitive owner wins:
        // what a network peer may be shown is decided by this tag, and a
        // hook-supplied `focus_tag` must not be able to move a Teri/Fred
        // session's events onto an ordinary focus.
        let tag = match from_session_id {
            Some(sid_tag) if self.sensitive.tag_is_sensitive(&sid_tag) => Some(sid_tag),
            sid_tag => from_focus_tag.or(sid_tag),
        };

        match (tag, &event.agent_id) {
            (Some(tag), Some(agent_id)) => Attribution::Subagent {
                tag,
                agent_id: agent_id.clone(),
            },
            (Some(tag), None) => Attribution::Focus { tag },
            (None, _) => Attribution::Unattributed,
        }
    }

    /// Resolve attribution and ingest one raw activity event (from the
    /// `activity.jsonl` tailer) into the bounded activity store, returning
    /// the finalized (attributed, `seq`-assigned, scrubbed) event for
    /// broadcast.
    pub fn ingest_activity_event(
        &mut self,
        event: crate::agent_bus::ActivityEvent,
    ) -> crate::agent_bus::ActivityEvent {
        let attribution = self.resolve_attribution(&event);
        let attributed_tag = match &attribution {
            crate::activity::store::Attribution::Focus { tag }
            | crate::activity::store::Attribution::Subagent { tag, .. } => Some(tag.clone()),
            crate::activity::store::Attribution::Unattributed => None,
        };
        let mut finalized = self.activity_store.ingest(event, attribution);
        // The attributed focus is authoritative: a hook-supplied `focus_tag`
        // may be absent or wrong (attribution can come from the session id),
        // and what a network peer may see is decided by this tag.
        if attributed_tag.is_some() {
            finalized.focus_tag = attributed_tag;
        }
        finalized
    }

    /// [`Self::ingest_activity_event`], additionally reporting whether this
    /// event is the one that flipped ingestion health from "never saw an
    /// event" to "ingesting". The daemon broadcasts a fresh `ActivityHealth`
    /// on exactly that transition: health is otherwise only sent in a
    /// client's attach-time replay, so a long-lived GUI connection kept
    /// showing "install the hook" long after the hook was installed and
    /// events were flowing (live QA, 2026-10-06).
    pub fn ingest_activity_event_reporting(
        &mut self,
        event: crate::agent_bus::ActivityEvent,
    ) -> (crate::agent_bus::ActivityEvent, bool) {
        let was_ingesting = self.activity_store.health().ingesting;
        let finalized = self.ingest_activity_event(event);
        let became_ingesting = !was_ingesting && self.activity_store.health().ingesting;
        (finalized, became_ingesting)
    }

    /// Every activity stream (main + subagent) known for `tag`.
    pub fn activity_streams_for_focus(
        &self,
        tag: &str,
    ) -> Vec<crate::activity::store::ActivityStreamSnapshot> {
        self.activity_store.streams_for_focus(tag)
    }

    /// Every focus tag the daemon currently knows of — sessions plus the
    /// Mac-pushed registry — for attach-replay fan-out.
    pub fn known_focus_tags(&self) -> Vec<String> {
        let mut tags: Vec<String> = self.sessions.keys().cloned().collect();
        for f in &self.focus_registry {
            if !tags.contains(&f.tag) {
                tags.push(f.tag.clone());
            }
        }
        tags
    }

    /// Ambient-activity ingestion health verdict (store-local only — see
    /// [`crate::activity::store::ActivityStore::health`]).
    pub fn activity_health(&self) -> crate::activity::store::ActivityHealth {
        self.activity_store.health()
    }

    // ── spawn ───────────────────────────────────────────────────────────────

    /// Spawn (or resume) a focus's persistent session. Idempotent: if the tag
    /// already has a live child this is a no-op returning the known session id.
    pub fn spawn_session(
        &mut self,
        tag: String,
        agent_name: String,
        view_name: String,
        cwd: Option<PathBuf>,
        session_id: Option<String>,
        remote_control: bool,
    ) -> Result<Option<String>> {
        // A Fred/Teri session has mail/calendar/todo tools and reads their
        // data: whatever tag it runs under is sensitive. Registered before the
        // child exists, so nothing it produces can precede the registration.
        // A session spawned while a work item is being sent holds that item's
        // content likewise (see `peer::within_work_send`).
        // A restricted session (the picks session) reads work-item data with no
        // agent name to say so, so it is sensitive by its restriction.
        // A Huey session holds the digest (personal notes and idea titles) and
        // is sensitive under any tag.
        if is_teri_or_fred_agent(&agent_name)
            || is_huey_agent(&agent_name)
            || in_work_send()
            || self.restrictions.contains_key(&tag)
        {
            self.sensitive.mark_tag(&tag);
        }

        if let Some(existing) = self.sessions.get(&tag) {
            if existing.alive() {
                return Ok(existing.session_id.clone());
            }
        }

        // Resolve the session id: explicit arg › persisted store › fresh uuid.
        let store = load_id_store(&self.store_path);
        let resolved = session_id.or_else(|| store.get(&tag).cloned());
        let (effective_id, resume) = match resolved {
            Some(id) => (id, true),
            None => (Uuid::new_v4().to_string(), false),
        };
        if resume {
            self.sensitive.note_resumed(&tag);
        }
        self.session_reverse
            .insert(effective_id.clone(), tag.clone());

        // Note the id in the history Mother jobs' claimed sessions are checked
        // against *before* the child exists: a `mother add` it runs at once
        // must already find it (the child is handed this id in its
        // environment, so there is no later moment that is early enough).
        //
        // A spawn that then fails (no `claude` binary, `resolve_claude()?` or
        // the spawn itself) leaves an id here that never ran. That is
        // harmless: the history only vouches that a claim's session belongs to
        // this tag. A minted id was never handed to anyone, so nothing can
        // quote it; an explicit or stored id was already this focus's own, and
        // a retry reuses it. Entries age out after 90 days.
        self.session_history.record(&tag, &effective_id);

        let program = resolve_claude()?;
        let mut args = build_claude_args_with(
            &agent_name,
            &view_name,
            remote_control,
            &effective_id,
            resume,
            self.restrictions.get(&tag),
            &if self.omit_guard_hook {
                "{}".to_owned()
            } else {
                crate::approvals::guard::hook_settings_json(&self.guard_path)
            },
        );
        // The focus's recorded model, read at every spawn (restart and crash
        // recovery come through here too). No record: no flag, as before.
        // A start that resumes nothing is a new focus (or one that never ran):
        // resolve its model by precedence and record it. A resumed focus keeps
        // what it has, whatever the defaults say now.
        let (model, spawn_note) = if let Some(r) = self.restrictions.get(&tag) {
            // A restricted session runs on the model its restrictions name, or
            // the CLI default: never a recorded focus model.
            (
                r.model.as_ref().map(|m| ModelTarget {
                    model: m.clone(),
                    effort: None,
                }),
                None,
            )
        } else {
            let declared = if resume {
                None
            } else {
                self.record_new_focus_model(&tag, &agent_name, None)
            };
            match declared {
                Some(target) => (Some(target), None),
                None => self.spawn_model(&tag, &agent_name),
            }
        };
        args.extend(model_args(model.as_ref()));

        let managed = self.spawn_managed(
            tag.clone(),
            agent_name,
            view_name,
            cwd,
            remote_control,
            effective_id.clone(),
            resume,
            program,
            args,
            None,
        )?;

        if let Some(text) = spawn_note {
            emit_note(&managed.shared, NoteKind::ModelUnavailable, text);
        }
        self.sessions.insert(tag.clone(), managed);

        // A fresh (non-resume) spawn starts from a known baseline: a single REPL
        // pane the agent grows on its first turn. A resume keeps the persisted
        // tree (loaded from the pane store) so a reconnecting client sees the
        // already-assembled workspace.
        if !resume {
            if let Some(reg) = &self.pane_registry {
                // A focus with a bound tracker board keeps its tracker pane
                // across the fresh session (contract §6).
                let has_tracker = self
                    .tracker_frame_provider
                    .as_ref()
                    .is_some_and(|p| p.has_bound_board(&tag));
                reg.lock()
                    .unwrap()
                    .init_focus_with_tracker(&tag, has_tracker);
            }
        }

        // Persist the (possibly freshly generated) id for the tag.
        save_id(&self.store_path, &tag, Some(&effective_id));
        // The id is a credential: Mother jobs claiming a session are verified
        // against it, and it is exported as `MOTHER_ORIGIN_SESSION`. It is
        // never logged.
        info!(tag, resume, "session spawned");
        Ok(Some(effective_id))
    }

    /// Spawn an arbitrary program as a session child. Factored out so tests can
    /// inject a stub program in place of `claude`.
    #[allow(clippy::too_many_arguments)]
    fn spawn_managed(
        &self,
        tag: String,
        agent_name: String,
        view_name: String,
        cwd: Option<PathBuf>,
        remote_control: bool,
        session_id: String,
        resume: bool,
        program: PathBuf,
        args: Vec<String>,
        respawn_fixed: Option<(PathBuf, Vec<String>)>,
    ) -> Result<ManagedSession> {
        // Pre-populate the transcript from stored scrollback when resuming,
        // with the session's notes put back where they were made.
        let paths = &self.model_hub.paths;
        let mut transcript = if resume {
            let mut t = load_scrollback(&session_id, SCROLLBACK_TURNS);
            t.merge_ledger_notes(&notes::load(&paths.notes_dir, &session_id));
            t
        } else {
            SessionTranscript::new()
        };
        // From here on the lines are the running CLI's own: calls and results
        // without a timestamp may take the time the daemon received them. The
        // scrollback above was a replay and never invents times.
        transcript.set_live(true);
        let restricted = self.restrictions.contains_key(&tag);
        let runtime = ModelRuntime {
            recorded: if restricted {
                None
            } else {
                model_store::focus_record(&paths.focus_models, &tag)
            },
            ..ModelRuntime::default()
        };

        let mut cmd = Command::new(&program);
        cmd.args(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()); // piped for crash diagnostics (was null)

        // A session leads its own process group, so `stop` and shutdown reach
        // its children and subagents (background servers) too, not just the
        // child. Restricted sessions always do.
        let own_process_group = SESSIONS_LEAD_OWN_GROUP || self.restrictions.contains_key(&tag);
        #[cfg(unix)]
        if own_process_group {
            use std::os::unix::process::CommandExt as _;
            cmd.process_group(0);
        }

        // MCP bridge wiring for real (non-stubbed) `claude` sessions. The child
        // registers the `nostromo-mcp-bridge` stdio server (--mcp-config) and
        // inherits the identity env the bridge forwards in its Hello frame, so
        // the agent can call the layout/introspection tools against the daemon.
        // The focus tag is the identity key (NOSTROMO_PTY_ID) and the view id.
        if respawn_fixed.is_none() {
            if let (Some(socket), Some(config)) = (&self.mcp_socket, &self.mcp_config) {
                cmd.env("NOSTROMO_MCP_SOCKET", socket);
                cmd.env("NOSTROMO_PTY_ID", &tag);
                cmd.env("NOSTROMO_VIEW_ID", &tag);
                // Attribution (activity-path wedge): lets the
                // `nostromo-activity-hook` producer stamp every hook payload
                // with the owning focus tag directly, with no session-id
                // reverse lookup needed on the fast path.
                cmd.env("NOSTROMO_FOCUS_TAG", &tag);
                // The session id this daemon spawned with: a `mother add` in
                // the session's shell records it as `origin.session` with no
                // flags, and the daemon can verify the claim against its
                // per-focus session history.
                cmd.env("MOTHER_ORIGIN_SESSION", &session_id);
                cmd.arg("--mcp-config").arg(config);
            }
        }
        // Child working directory. When the focus carries no project dir, default
        // to the operator's $HOME — NOT the daemon's own cwd, which under launchd
        // is `/` (filesystem root). Running an agent at `/` has no git context, so
        // `gh` can't infer owner/repo and repo-aware commands (Perri's, etc.) fail
        // in ways they never do when launched from a real dir. $HOME matches what a
        // terminal-launched agent would typically see.
        let dir = cwd
            .clone()
            .or_else(|| std::env::var_os("HOME").map(PathBuf::from))
            .or_else(|| std::env::current_dir().ok());
        let task_dir = dir.clone().unwrap_or_default();
        if let Some(dir) = dir {
            cmd.current_dir(dir);
        }
        augment_path(&mut cmd);

        cmd.env(MARKER_ENV, self.ledger.marker());
        let mut child = cmd
            .spawn()
            .map_err(|e| anyhow!("failed to spawn {}: {e}", program.display()))?;
        self.ledger.record(child.id(), own_process_group, &program);

        let stdin = child.stdin.take();
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow!("child has no stdout"))?;
        let stderr = child.stderr.take();

        let (event_tx, _) = broadcast::channel::<SessionEvent>(512);
        let transcript = Arc::new(Mutex::new(transcript));
        let tasks = TaskRuntime::new(
            Arc::clone(&transcript),
            Some(session_id.clone()),
            task_dir.clone(),
            &self.task_io,
        );
        let shared = Shared {
            transcript,
            stdin: Arc::new(Mutex::new(stdin)),
            pending: Arc::new(Mutex::new(VecDeque::new())),
            state: Arc::new(Mutex::new(SessionState::Idle)),
            exited: Arc::new(AtomicBool::new(false)),
            event_tx,
            model: Arc::new(Mutex::new(runtime)),
            waiters: Arc::new(Mutex::new(HashMap::new())),
            writing: Arc::new(AtomicBool::new(false)),
            model_io: Arc::new(Mutex::new(())),
            ctx: Arc::new(SessionCtx {
                tag: tag.clone(),
                agent_name: agent_name.clone(),
                session_id: session_id.clone(),
                restricted,
                hub: Arc::clone(&self.model_hub),
            }),
            note_prefix: Arc::new(Mutex::new(None)),
            runtime: tokio::runtime::Handle::current(),
            tasks,
            login: login::LoginLink::new(self.login.clone()),
        };
        // Ends vanished tasks and flushes coalesced task snapshots; stops
        // when the CLI has exited.
        tokio::spawn(drive_timer(
            Arc::clone(&shared.tasks),
            shared.event_tx.clone(),
            Arc::clone(&shared.exited),
        ));

        // Stderr drain thread: read and log stderr lines so crash output is
        // visible in the nostromd log rather than silently discarded.
        // Also detects the "No conversation found" permanent error and sets
        // `stale_session_id` so `reap_and_recover` can clear the id and
        // restart fresh rather than looping on the same stale id.
        let stale_session_id = Arc::new(AtomicBool::new(false));
        let stale_for_stderr = Arc::clone(&stale_session_id);
        let tag_for_stderr = tag.clone();
        if let Some(stderr_pipe) = stderr {
            tokio::task::spawn_blocking(move || {
                use std::io::BufRead as _;
                let reader = std::io::BufReader::new(stderr_pipe);
                for line in reader.lines().map_while(Result::ok) {
                    let line = line.trim().to_owned();
                    if line.is_empty() {
                        continue;
                    }
                    if line.contains("No conversation found") {
                        stale_for_stderr.store(true, Ordering::SeqCst);
                        warn!(tag = %tag_for_stderr, "stale session id detected — will clear and restart fresh");
                    } else {
                        warn!(tag = %tag_for_stderr, "[stderr] {line}");
                    }
                }
            });
        }

        // An approval-capable session (unrestricted, not remote-control; the
        // same test as the `--permission-prompt-tool` flag) gets a broker to
        // answer its permission requests.
        let guarded = self.session_has_guard(&args);
        let approval_generation = self
            .approvals
            .as_ref()
            .filter(|_| !restricted && !remote_control)
            .map(|broker| {
                let info = ApprovalSessionInfo {
                    tag: tag.clone(),
                    agent: agent_name.clone(),
                    session_id: Some(session_id.clone()),
                    cwd: Some(task_dir.clone()),
                    // The ordering rule: a request is held for a human only when the
                    // session carries the guard hook (see `ApprovalBroker`).
                    guarded,
                };
                let sink = Arc::new(StdinSink {
                    stdin: Arc::clone(&shared.stdin),
                    exited: Arc::clone(&shared.exited),
                });
                broker.register_session(info, sink)
            });
        let approvals = self
            .approvals
            .clone()
            .zip(approval_generation)
            .map(|(broker, generation)| ApprovalLink { broker, generation });

        // Reader thread: parse stdout → transcript → broadcast deltas; drain
        // the pending queue on turn completion; signal exit on EOF.
        let reader_shared = shared.clone();
        let tag_for_reader = tag.clone();
        let reader_task = tokio::task::spawn_blocking(move || {
            run_reader(tag_for_reader, stdout, reader_shared, approvals)
        });

        Ok(ManagedSession {
            tag,
            agent_name,
            view_name,
            cwd,
            remote_control,
            session_id: Some(session_id),
            child,
            reaped: false,
            unreaped_probe: child_unreaped,
            shared,
            respawn_fixed,
            intentional_stop: Arc::new(AtomicBool::new(false)),
            stale_session_id,
            attached_clients: HashSet::new(),
            forwarders: HashMap::new(),
            _reader_task: reader_task,
            crash_times: VecDeque::new(),
            restart_at: None,
            last_exit_code: None,
            stop_reason: None,
            summary_sent: Arc::new(AtomicBool::new(false)),
            own_process_group,
            ledger: Arc::clone(&self.ledger),
            approval_generation,
        })
    }

    // ── send ──────────────────────────────────────────────────────────────────

    /// Enqueue a user message. Writes immediately to stdin if the session is
    /// idle, otherwise queues it to drain after the current turn completes.
    pub fn send_user_message(&mut self, tag: &str, text: &str, images: &[String]) -> Result<()> {
        // Text sent during a work-item send is that item's content: the
        // session it lands in is sensitive before the text is written.
        if in_work_send() {
            self.sensitive.mark_tag(tag);
        }
        let session = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
        if !session.alive() {
            anyhow::bail!("session {tag} is not alive");
        }
        // Decide under the state lock, then release it BEFORE touching stdin
        // (a write to a stalled CLI must not hold `state`, see `Shared`). The
        // message is queued, not written, while a turn runs or a model switch
        // is being applied; queueing happens under the same lock so a turn end
        // draining the queue can't miss it.
        let message = PendingMessage::user(text, images);
        let should_write = {
            let mut state = lock_recover(&session.shared.state);
            let applying = lock_recover(&session.shared.model).applying.is_some();
            // Paused for a sign-in: whatever the state, the message waits behind
            // the held one, up to the cap (the refusal carries no content).
            let paused = session.shared.login.paused();
            if paused && lock_recover(&session.shared.pending).len() >= LOGIN_QUEUE_CAP {
                anyhow::bail!("waiting_for_sign_in: queue full");
            }
            if *state == SessionState::Idle && !applying && !paused {
                // Optimistically mark mid-turn so a follow-up send queues rather
                // than racing a second message onto stdin before the echo lands.
                *state = SessionState::MidTurn;
                true
            } else {
                lock_recover(&session.shared.pending).push_back(message.clone());
                false
            }
        };
        if !should_write {
            session.shared.login.notify();
        }

        if should_write {
            // After a crash left a permission request of this focus pending, its
            // agent hears about it once, ahead of what it was sent. Only a message
            // written now carries it (a queued one can still be dropped by an
            // interrupt), and it is forgotten only once the write has succeeded.
            let note = self
                .approvals
                .as_ref()
                .and_then(|b| b.peek_restart_note(tag));
            let outgoing = match &note {
                Some(note) => PendingMessage {
                    text: format!("{note}\n\n{}", message.text),
                    ..message.clone()
                },
                None => message.clone(),
            };
            if let Err(e) = write_user_message(&session.shared, &outgoing) {
                // The optimistic MidTurn would otherwise wedge the session.
                *lock_recover(&session.shared.state) = SessionState::Idle;
                return Err(e);
            }
            if note.is_some() {
                if let Some(broker) = &self.approvals {
                    broker.discard_restart_note(tag);
                }
            }
            session
                .shared
                .broadcast(SessionEvent::State(SessionState::MidTurn));
        }
        Ok(())
    }

    // ── interrupt ─────────────────────────────────────────────────────────────

    /// Interrupt the turn `tag` is running (the Stop button) without killing the
    /// session. Writes the stream-json `interrupt` control request to the
    /// child's stdin; the CLI acknowledges immediately, ends the turn with an
    /// error result, and stays alive for the next message (verified against a
    /// real `claude`: `control_response success` at +0.0s, then
    /// `result error_during_execution`, process still running).
    ///
    /// Stop means stop: messages queued behind the running turn are dropped, so
    /// the end of the interrupted turn goes to idle instead of `drain_or_idle`
    /// immediately starting the next queued message. The transcript is told, so
    /// the result that ends this turn renders as "Interrupted", not a failure.
    ///
    /// A session that waits for a sign-in is Stop's too: the held message and the
    /// queue behind it are discarded, so nothing is sent after the sign-in
    /// ([`InterruptOutcome::DiscardedHold`], unless a turn was running too).
    ///
    /// A no-op ([`InterruptOutcome::NotRunning`]) when the session is idle.
    pub fn interrupt(&mut self, tag: &str) -> Result<InterruptOutcome> {
        let session = self
            .sessions
            .get(tag)
            .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
        if !session.alive() {
            anyhow::bail!("session {tag} is not alive");
        }
        // A message `step` took off the queue may still be on its way to
        // stdin. The interrupt goes behind it (it ends that message's turn:
        // Stop applies to the newest turn) rather than ahead, where the
        // message would then start a turn nobody can stop. `step` pops the
        // message and sets `writing` under `state`, so `writing` is only
        // trusted when read under `state`; and the queue is cleared under
        // that same hold, so a writer that pops after it finds nothing. The
        // wait is bounded like `take_carry`'s.
        let deadline = std::time::Instant::now() + WRITE_WAIT_LIMIT;
        let (running, discarded) = loop {
            let state = lock_recover(&session.shared.state);
            if session.shared.writing.load(Ordering::SeqCst) && std::time::Instant::now() < deadline
            {
                drop(state);
                std::thread::sleep(Duration::from_millis(1));
                continue;
            }
            let running = matches!(
                *state,
                SessionState::MidTurn | SessionState::AwaitingPermission
            );
            let discarded = session.shared.login.discard_for_stop();
            if running || discarded {
                lock_recover(&session.shared.pending).clear();
            }
            break (running, discarded);
        };
        if discarded {
            info!(tag, "held message discarded: stopped by the user");
            session.shared.login.notify();
        }
        if !running {
            return Ok(if discarded {
                InterruptOutcome::DiscardedHold
            } else {
                InterruptOutcome::NotRunning
            });
        }

        lock_recover(&session.shared.transcript).mark_interrupt_requested();
        let request_id = format!("interrupt-{}", chrono::Utc::now().timestamp_millis());
        write_control_request(
            &session.shared.stdin,
            &request_id,
            serde_json::json!({ "subtype": "interrupt" }),
        )?;
        Ok(InterruptOutcome::Requested)
    }

    // ── attach / detach ─────────────────────────────────────────────────────

    /// Attach `client_id` to `tag`: send a `SessionTurns` snapshot + current
    /// `SessionState`, then forward live events. Multiple clients may attach.
    pub fn attach(&mut self, tag: &str, client_id: &str) -> Result<()> {
        let (turns, state, event_rx, tasks) = {
            let session = self
                .sessions
                .get_mut(tag)
                .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
            session.attached_clients.insert(client_id.to_string());
            session.shared.tasks.set_clients(local_client_count(
                &session.attached_clients,
                &self.network_clients,
            ));
            ensure_poller(&session.shared);
            // Cap what a freshly-attaching client receives to the last
            // SCROLLBACK_TURNS turns — mirrors the cap already applied when
            // loading scrollback at spawn time (`load_scrollback`). Without
            // this, a session that's been alive and busy for a long time
            // (without crashing/respawning — the only other place the cap
            // gets re-applied) sends its entire accumulated in-memory
            // history to any client that attaches later. A GUI client
            // rendering that as one flat turn list can peg Auto Layout
            // trying to lay out thousands of historical turns at once. The
            // live transcript is itself now bounded (RETAINED_TURNS /
            // RETAINED_BYTES), so this only clones the tail actually served
            // rather than the whole retained history.
            let turns = session
                .shared
                .transcript
                .lock()
                .unwrap()
                .recent_turns(SCROLLBACK_TURNS);
            let state = session.state();
            let rx = session.shared.event_tx.subscribe();
            (turns, state, rx, Arc::clone(&session.shared.tasks))
        };

        self.send_to_client(
            client_id,
            ServerMsg::SessionTurns {
                tag: tag.to_string(),
                turns,
            },
        );
        self.send_to_client(
            client_id,
            ServerMsg::SessionState {
                tag: tag.to_string(),
                state,
            },
        );
        if let Some(connected) = self.bridge_connected(tag) {
            self.send_to_client(
                client_id,
                ServerMsg::SessionBridge {
                    tag: tag.to_string(),
                    connected,
                },
            );
        }

        // The tasks as they are now, then the live events (subscribed above,
        // so nothing between is lost; a snapshot replaces the previous one).
        let (snapshot, details) = tasks.current();
        self.send_to_client(client_id, tasks_msg(tag, &snapshot));
        for detail in details {
            self.send_to_client(client_id, detail_msg(tag, &detail));
        }

        // Forwarder task: SessionEvent → targeted ServerMsg.
        let senders = Arc::clone(&self.client_senders);
        let tag_s = tag.to_string();
        let client_s = client_id.to_string();
        let task = tokio::spawn(forward_session_events(
            event_rx,
            move |msg| match senders.lock().unwrap().get(&client_s) {
                Some(tx) => {
                    let _ = tx.send(msg);
                    true
                }
                None => false,
            },
            tag_s,
            tasks,
        ));
        if let Some(session) = self.sessions.get_mut(tag) {
            session
                .forwarders
                .insert(client_id.to_string(), task.abort_handle());
        }
        info!(tag, client_id, "session attach");
        Ok(())
    }

    /// [`Self::attach`] for a network (TCP) peer: the same frames, but the
    /// client does not keep the task preview poller running.
    pub fn attach_network(&mut self, tag: &str, client_id: &str) -> Result<()> {
        self.network_clients.insert(client_id.to_string());
        self.attach(tag, client_id)
    }

    /// Detach `client_id` from `tag` (the child keeps running).
    pub fn detach(&mut self, tag: &str, client_id: &str) {
        if let Some(session) = self.sessions.get_mut(tag) {
            session.attached_clients.remove(client_id);
            session.shared.tasks.set_clients(local_client_count(
                &session.attached_clients,
                &self.network_clients,
            ));
            if let Some(h) = session.forwarders.remove(client_id) {
                h.abort();
            }
        }
    }

    // ── lifecycle control ─────────────────────────────────────────────────────

    /// Stop the child but keep the persisted session id (resumable).
    ///
    /// Sets `stop_reason = User` and broadcasts `PermanentlyDown { reason: User }`
    /// so attached clients can clear any crash-loop indicator (this was a benign
    /// user-requested stop, not an alarm).
    pub fn stop(&mut self, tag: &str) {
        // A switch still waiting for the turn this stop cuts short takes
        // effect when the session next starts. Its store write is made on the
        // hub's IO thread, not here (this runs under the manager lock and the
        // write is durable); the respawn that follows reads the switch from
        // the hub's "not yet written" entry (see `spawn_model`).
        let waiting = self
            .sessions
            .get(tag)
            .and_then(|s| lock_recover(&s.shared.model).waiting.take());
        if let Some((target, actor)) = waiting {
            let agent = self.agent_of(tag);
            let session_id = self.sessions.get(tag).and_then(|s| s.session_id.clone());
            let current = self.model_hub.stored_target(tag).or_else(|| {
                model_store::focus_record(&self.model_hub.paths.focus_models, tag)
                    .map(|r| r.target())
            });
            let ctx = SessionCtx::stopped(
                tag,
                agent.as_deref(),
                session_id.as_deref(),
                &self.model_hub,
            );
            let _ = self.switch_not_running(&ctx, current, target, actor);
        }
        let mut ended_tasks = None;
        if let Some(session) = self.sessions.get_mut(tag) {
            // Before the kill: a request still pending ends `cancelled`, and
            // nothing is written to a process that is about to die.
            if let (Some(broker), Some(generation)) = (&self.approvals, session.approval_generation)
            {
                broker.on_session_gone(tag, generation, "stopped");
            }
            session.intentional_stop.store(true, Ordering::SeqCst);
            session.stop_reason = Some(StopReason::User);
            // A stopped session waits for no sign-in: its held message is dropped.
            session.shared.login.clear();
            session.kill();
            session.shared.exited.store(true, Ordering::SeqCst);
            // The forwarders are aborted below, before the reader reaches
            // EOF: the tasks end with the process, and the clients hear it
            // here, straight on their own channels.
            session.shared.tasks.end_session(&session.shared.event_tx);
            ended_tasks = Some((
                session.shared.tasks.current().0,
                session.attached_clients.iter().cloned().collect::<Vec<_>>(),
            ));
            session.shared.broadcast(SessionEvent::PermanentlyDown {
                reason: StopReason::User,
            });
            for (_, h) in session.forwarders.drain() {
                h.abort();
            }
            debug!(tag, "session stopped");
        }
        if let Some((snapshot, clients)) = ended_tasks {
            for client in clients {
                self.send_to_client(&client, tasks_msg(tag, &snapshot));
            }
        }
        // The session is going down (permanently, or about to be respawned by
        // `restart`/`new_session`, both of which call this first) — either
        // way, nobody can answer a decision addressed to this tag right now.
        // A `restart` that lands moments later gets a *fresh* decision if the
        // agent asks again; it never inherits the cancelled one.
        if let Some(reg) = &self.decisions {
            reg.lock().unwrap().cancel_tag(tag);
        }
        // A stopped session is no longer waiting for a sign-in.
        self.login_changed();
        // Nothing follows a terminal for a session that went down.
        self.session_ended(tag);
    }

    /// Stop then respawn with `--resume <session_id>`, preserving the set of
    /// attached clients (mirroring survives a restart).
    ///
    /// Explicitly resets the crash-loop guard: the new `ManagedSession` is built
    /// by `spawn_managed` which starts with `crash_times = VecDeque::new()`,
    /// `restart_at = None`, and `stop_reason = None` — so a user-initiated
    /// Restart of a guard-tripped session always retries cleanly from a fresh
    /// slate. This intent is preserved whether the crash-loop guard uses the
    /// current fixed-window fields or future sliding-window fields.
    pub fn restart(&mut self, tag: &str) -> Result<()> {
        let (agent, view, cwd, sid, rc, fixed, attached) = {
            let s = self
                .sessions
                .get(tag)
                .ok_or_else(|| anyhow!("unknown session tag: {tag}"))?;
            (
                s.agent_name.clone(),
                s.view_name.clone(),
                s.cwd.clone(),
                s.session_id.clone(),
                s.remote_control,
                s.respawn_fixed.clone(),
                s.attached_clients.iter().cloned().collect::<Vec<_>>(),
            )
        };
        // Kill first: a write to a stalled CLI's stdin that is still in
        // flight then fails at once, so `take_carry` can see its outcome
        // instead of waiting on a process that will never read.
        if let Some(session) = self.sessions.get_mut(tag) {
            // Before the kill, as in `stop`: nothing is written to a dying process.
            if let (Some(broker), Some(generation)) = (&self.approvals, session.approval_generation)
            {
                broker.on_session_gone(tag, generation, "restarted");
            }
            session.intentional_stop.store(true, Ordering::SeqCst);
            session.kill();
        }
        let carry = self.take_carry(tag);
        self.stop(tag);
        let old = self.sessions.remove(tag);

        if let Err(e) = self.respawn(tag, agent, view, cwd, sid, rc, fixed) {
            // No new process: the carry (queued messages, a waiting switch, a
            // message held for a sign-in) goes back on the old, downed session,
            // which the supervisor then retries like any crash, instead of
            // being lost with it.
            if let Some(old) = old {
                self.keep_downed(tag, old, carry);
            }
            return Err(e);
        }

        // Re-attach previously attached clients so the GUI re-syncs after a
        // transparent restart.
        for client_id in attached {
            let _ = self.attach(tag, &client_id);
        }
        // Messages queued (and a model switch waiting) on the old process go
        // to the new one, switch first.
        self.resume_carry(tag, carry);
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn respawn(
        &mut self,
        tag: &str,
        agent: String,
        view: String,
        cwd: Option<PathBuf>,
        sid: Option<String>,
        rc: bool,
        fixed: Option<(PathBuf, Vec<String>)>,
    ) -> Result<()> {
        match fixed {
            // Real claude session: resolve the binary and resume.
            None => {
                self.spawn_session(tag.to_string(), agent, view, cwd, sid, rc)?;
            }
            // Test stub / fixed program: replay it verbatim.
            Some((program, args)) => {
                let effective_id = sid.unwrap_or_else(|| Uuid::new_v4().to_string());
                self.session_reverse
                    .insert(effective_id.clone(), tag.to_string());
                let managed = self.spawn_managed(
                    tag.to_string(),
                    agent,
                    view,
                    cwd,
                    rc,
                    effective_id,
                    true,
                    program.clone(),
                    args.clone(),
                    Some((program, args)),
                )?;
                self.sessions.insert(tag.to_string(), managed);
            }
        }
        Ok(())
    }

    /// A restart found no process to start: put the stopped session back as a
    /// crashed one, carrying what it held, so `reap_and_recover` tries again
    /// (a held message counts as work to recover).
    fn keep_downed(&mut self, tag: &str, mut old: ManagedSession, carry: model_switch::Carry) {
        old.intentional_stop.store(false, Ordering::SeqCst);
        old.stop_reason = None;
        if let Some(hold) = carry.login {
            old.shared.login.restore(hold);
        }
        lock_recover(&old.shared.pending).extend(carry.messages);
        lock_recover(&old.shared.model).waiting = carry.waiting;
        self.sessions.insert(tag.to_string(), old);
        self.login_changed();
    }

    /// Drop the persisted session id and stop the child; the next spawn starts
    /// a fresh conversation.
    pub fn new_session(&mut self, tag: &str) {
        self.stop(tag);
        self.sessions.remove(tag);
        save_id(&self.store_path, tag, None);
        self.login_changed();
        debug!(tag, "session id cleared — next spawn is fresh");
    }

    /// Periodic supervisor pass (driven by the daemon): detect crashed children
    /// and auto-restart those still wanted (attached or with queued messages),
    /// subject to the crash-loop guard.
    ///
    /// Each crashed session goes through three phases per tick:
    ///
    /// 1. **Backoff check**: if we already scheduled a backoff deadline for this
    ///    crash, skip this tick (still waiting) or clear it (deadline elapsed).
    /// 2. **First-sighting bookkeeping** (only on the initial crash detection,
    ///    not repeated while backing off): capture the exit code, re-broadcast
    ///    `Exited` with the real code, mark the turn errored, record the crash
    ///    in the sliding window.
    /// 3. **Decision**: guard check, then exit-code-aware restart or backoff
    ///    scheduling.
    pub fn reap_and_recover(&mut self) {
        let crashed: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, s)| {
                s.shared.exited.load(Ordering::SeqCst)
                    && !s.intentional_stop.load(Ordering::SeqCst)
                    // A switch being applied is finishing (its control
                    // requests fail as soon as the process is gone): let it
                    // record its failure first, so the queue it leaves behind
                    // is what the respawn inherits.
                    && lock_recover(&s.shared.model).applying.is_none()
            })
            .map(|(tag, _)| tag.clone())
            .collect();

        for tag in crashed {
            // ── phase 1: backoff check ────────────────────────────────────────
            //
            // A session can sit crashed across multiple 2s supervisor ticks
            // while its backoff deadline counts down. Use restart_at as the
            // "already-bookekept, waiting" sentinel: Some(future) → skip;
            // Some(past) → deadline elapsed, clear it and proceed to restart;
            // None → first sighting, run bookkeeping.
            let backoff_served;
            {
                let s = self.sessions.get_mut(&tag).unwrap();
                match s.restart_at {
                    Some(deadline) if Instant::now() < deadline => {
                        continue; // still backing off; do nothing this tick
                    }
                    Some(_) => {
                        // Deadline reached — clear and fall through to restart.
                        // Bookkeeping was already done when we scheduled this.
                        s.restart_at = None;
                        backoff_served = true;
                    }
                    None => {
                        backoff_served = false;
                    }
                }
            }

            // ── phase 2: first-sighting bookkeeping ───────────────────────────
            if !backoff_served {
                let s = self.sessions.get_mut(&tag).unwrap();

                // Capture the real exit code (non-blocking; child has already
                // closed stdout before the reader sets exited).
                let code = s.try_reap().and_then(|status| status.code());
                s.last_exit_code = code;
                // Reaped: nothing is left of this CLI to sweep (its pid is free
                // for reuse), so the ledger drops it now instead of carrying it
                // through the backoff, and a guard-tripped session never leaves
                // it behind.
                if s.reaped {
                    s.ledger.forget(s.child.id());
                }

                // Re-broadcast Exited with the real exit code so clients see it.
                // The reader's initial broadcast used None (it can't see the code).
                s.shared.broadcast(SessionEvent::Exited { exit_code: code });

                // Mark the in-flight turn errored and broadcast the delta.
                let delta = s
                    .shared
                    .transcript
                    .lock()
                    .unwrap()
                    .mark_current_errored("session process exited unexpectedly");
                if let Some(d) = delta {
                    s.shared.broadcast(SessionEvent::Delta(d));
                }
                s.shared.set_state(SessionState::Crashed);

                // Sliding-window bookkeeping: push this crash, evict stale entries.
                let now = Instant::now();
                s.crash_times.push_back(now);
                while s
                    .crash_times
                    .front()
                    .map(|t| t.elapsed().as_secs() >= RESTART_WINDOW_SECS)
                    .unwrap_or(false)
                {
                    s.crash_times.pop_front();
                }
            }

            // ── phase 3: decision ─────────────────────────────────────────────
            let wants_recovery;
            let guard_tripped;
            let exit_code;
            let is_stale;
            let crash_times_snapshot;
            {
                let s = self.sessions.get_mut(&tag).unwrap();
                let has_pending = !lock_recover(&s.shared.pending).is_empty();
                // A switch still waiting (its apply never started, or the
                // session died first) is work the respawn must pick up.
                let has_waiting_switch = lock_recover(&s.shared.model).waiting.is_some();
                // A held message (a sign-in is awaited) is work the respawn inherits.
                let has_hold = s.shared.login.paused();
                wants_recovery =
                    !s.attached_clients.is_empty() || has_pending || has_waiting_switch || has_hold;
                let crash_count = s.crash_times.len() as u32;
                guard_tripped = crash_count >= MAX_RESTARTS;
                exit_code = s.last_exit_code;
                crash_times_snapshot = s.crash_times.clone();
                // NOTE: tiny race — the stderr drain sets this flag in a separate
                // thread. It almost always fires before reap_and_recover ticks (the
                // process exits within milliseconds of writing to stderr), but is
                // not guaranteed. The worst case is one extra retry before the flag
                // is seen; the crash-loop guard still trips eventually.
                is_stale = s.stale_session_id.load(Ordering::SeqCst);
            }

            if wants_recovery && is_stale {
                // Permanent configuration error: the persisted session id is no
                // longer valid. Clear it and spawn a fresh conversation. Bypass
                // the crash-loop guard and backoff — this is not a misbehaving
                // process, it's a stale pointer we can deterministically fix in
                // one step.
                warn!(
                    tag,
                    "clearing stale session id and restarting with fresh session"
                );
                let (agent, view, cwd, rc, attached) = {
                    let s = self.sessions.get(&tag).unwrap();
                    (
                        s.agent_name.clone(),
                        s.view_name.clone(),
                        s.cwd.clone(),
                        s.remote_control,
                        s.attached_clients.iter().cloned().collect::<Vec<_>>(),
                    )
                };
                let carry = self.take_carry(&tag);
                self.stop(&tag);
                self.sessions.remove(&tag);
                save_id(&self.store_path, &tag, None);
                match self.spawn_session(tag.to_string(), agent, view, cwd, None, rc) {
                    Ok(_) => {
                        for client_id in attached {
                            let _ = self.attach(&tag, &client_id);
                        }
                        self.resume_carry(&tag, carry);
                    }
                    Err(e) => warn!(tag, "fresh restart after stale id clear failed: {e:#}"),
                }
            } else if wants_recovery && guard_tripped {
                warn!(tag, "crash-loop guard tripped; leaving session crashed");
                // Prevent repeated recovery attempts: treat as intentional.
                // Set stop_reason = CrashLoopGuard and broadcast PermanentlyDown
                // so attached clients can show the alarm indicator.
                if let Some(s) = self.sessions.get_mut(&tag) {
                    s.intentional_stop.store(true, Ordering::SeqCst);
                    s.stop_reason = Some(StopReason::CrashLoopGuard);
                    // Given up on: it waits for no sign-in, and its held message is dropped.
                    s.shared.login.clear();
                    s.shared.broadcast(SessionEvent::PermanentlyDown {
                        reason: StopReason::CrashLoopGuard,
                    });
                }
                self.login_changed();
                // The session will not auto-restart — cancel any decision
                // pending for this tag rather than leaving its caller blocked
                // on a session that is never coming back on its own.
                if let Some(reg) = &self.decisions {
                    reg.lock().unwrap().cancel_tag(&tag);
                }
                self.session_ended(&tag);
            } else if wants_recovery {
                // Exit-code-aware restart policy:
                //   exit 0 or signal (None) → restart immediately (clean shutdown).
                //   non-zero exit → transient error; apply exponential backoff.
                //   backoff already served → restart now regardless of code.
                let restart_now = exit_code == Some(0) || exit_code.is_none() || backoff_served;
                if restart_now {
                    warn!(
                        tag,
                        restart = crash_times_snapshot.len(),
                        exit_code = ?exit_code,
                        "auto-restarting crashed session"
                    );
                    if let Err(e) = self.restart(&tag) {
                        warn!(tag, "auto-restart failed: {e:#}");
                    } else if let Some(s) = self.sessions.get_mut(&tag) {
                        // Carry the crash window into the new session so the
                        // guard accumulates across restarts (the old fixed-window
                        // bug: restart() builds a fresh ManagedSession and resets
                        // the counter; this re-instates it).
                        s.crash_times = crash_times_snapshot;
                    }
                } else {
                    // Non-zero exit and no backoff already served: schedule one.
                    let crash_count = crash_times_snapshot.len() as u32;
                    let delay = backoff_delay(crash_count);
                    if let Some(s) = self.sessions.get_mut(&tag) {
                        s.restart_at = Some(Instant::now() + delay);
                        warn!(
                            tag,
                            exit_code = ?exit_code,
                            delay_secs = delay.as_secs(),
                            "crash exit; backing off before restart"
                        );
                    }
                }
            }
            // else: nobody wants recovery — leave it crashed (no-op).
        }
    }

    // ── list ──────────────────────────────────────────────────────────────────

    /// Change how sessions started from now on read and control their tasks
    /// (a test hook: the daemon uses the defaults).
    pub fn set_task_io(&mut self, config: TaskIoConfig) {
        self.task_io = config;
    }

    /// Stop one of `tag`'s background tasks. The returned future owns what it
    /// needs, so it can be awaited without the manager's lock. Nothing is sent
    /// to the CLI for a session or task that is not there or has ended.
    pub fn task_stop(
        &self,
        tag: &str,
        task_id: &str,
    ) -> impl std::future::Future<Output = StopReport> + Send + 'static {
        let shared = self.sessions.get(tag).map(|s| s.shared.clone());
        let task_id = task_id.to_owned();
        async move {
            match shared {
                Some(shared) => stop_task(&shared, &task_id).await,
                None => StopReport::not_running("the session is not running"),
            }
        }
    }

    /// Read a range of one of `tag`'s tasks' output (see
    /// `ClientMsg::SessionTaskOutput`). Owns what it needs, like
    /// [`Self::task_stop`].
    pub fn task_output(
        &self,
        tag: &str,
        task_id: &str,
        offset: Option<u64>,
        max_bytes: u32,
    ) -> impl std::future::Future<Output = OutputReply> + Send + 'static {
        let shared = self.sessions.get(tag).map(|s| s.shared.clone());
        let task_id = task_id.to_owned();
        async move {
            match shared {
                Some(shared) => read_output(&shared, &task_id, offset, max_bytes).await,
                None => OutputReply::without_text(
                    crate::ipc::protocol::TaskOutputOutcome::Error,
                    "the session is not running",
                ),
            }
        }
    }

    pub fn list(&self) -> Vec<SessionInfo> {
        self.sessions
            .values()
            .map(|s| {
                let mut info = s.info();
                info.mcp_bridge_connected = self.bridge_connected(&info.tag);
                info
            })
            .collect()
    }

    /// Replace the focus registry with the Mac-pushed snapshot. Returns the new
    /// registry so the caller can broadcast it, and the tags that have now
    /// *departed* so the caller can evict their per-focus state (W7 — D8).
    ///
    /// A tag is reported departed only when it is absent from two consecutive
    /// pushes and was not created by this daemon. Both guards exist because
    /// this runs on every reconnect, where an empty or partial push is normal
    /// and eviction is irreversible — see `pending_departures` and
    /// `daemon_created_tags`.
    pub fn set_focus_registry(&mut self, focuses: Vec<FocusMeta>) -> (Vec<FocusMeta>, Vec<String>) {
        // An empty push carries no information about what still exists — it is
        // what a client sends before it has loaded anything. Take it as the
        // registry (unchanged from pre-W7 behaviour) but never as evidence that
        // every focus was deleted.
        //
        // It does erase the evidence the backstop needs, though: this branch
        // drops both the registry and `pending_departures`, so the daemon
        // knows no more than it did at startup and `non_empty_pushes_seen`
        // must reset to match — see `reconcilable_focus_tags` for what goes
        // wrong if it doesn't.
        if focuses.is_empty() {
            self.focus_registry = focuses;
            self.pending_departures.clear();
            self.non_empty_pushes_seen = 0;
            self.note_origin_registry(true);
            return (self.focus_registry.clone(), Vec::new());
        }

        self.non_empty_pushes_seen = self.non_empty_pushes_seen.saturating_add(1);

        let new_tags: HashSet<String> = focuses.iter().map(|f| f.tag.clone()).collect();

        // A daemon-created tag that this push *names* has been acknowledged:
        // the client demonstrably knows about it, so its exemption has done
        // its job and expires here. From the next push on it is an ordinary
        // focus, and — the point — it can finally reach `departed`, which is
        // the only path that deletes its PR pin.
        self.daemon_created_tags
            .retain(|tag| !new_tags.contains(tag));

        let known: HashSet<String> = self
            .focus_registry
            .iter()
            .map(|f| f.tag.clone())
            .chain(self.pending_departures.iter().cloned())
            .collect();

        let missing: HashSet<String> = known
            .difference(&new_tags)
            .filter(|t| !self.daemon_created_tags.contains(*t))
            .cloned()
            .collect();

        // Missing for the second consecutive push → genuinely gone.
        let mut departed: Vec<String> = missing
            .intersection(&self.pending_departures)
            .cloned()
            .collect();
        departed.sort();

        self.pending_departures = missing
            .iter()
            .filter(|t| !departed.contains(t))
            .cloned()
            .collect();
        // A closed focus's nonce is of no use to anyone: the next focus under
        // the tag brings its own.
        for tag in &departed {
            self.focus_nonces.remove(tag);
        }
        self.focus_registry = focuses;
        self.note_origin_registry(true);
        (self.focus_registry.clone(), departed)
    }

    /// Whether `tag` was created by this daemon rather than pushed by the Mac.
    pub fn is_daemon_created(&self, tag: &str) -> bool {
        self.daemon_created_tags.contains(tag)
    }

    /// Every focus tag that currently exists, or `None` if no client has
    /// pushed a registry yet (W7 — D8).
    ///
    /// The union of the pushed registry and the daemon-created tags still
    /// carrying their (temporary) eviction exemption — not just the registry:
    /// `set_focus_registry` replaces the registry wholesale with the client's
    /// view, so between `nostromo.create_focus` and the client's first
    /// acknowledging push, reading the registry alone would report an
    /// agent-created focus as non-existent.
    ///
    /// It is the *unexpired* exemptions specifically, for the same reason the
    /// exemption expires at all: a tag the client has acknowledged now lives
    /// or dies by the registry. Chaining the whole set unconditionally would
    /// report a departed daemon-created focus as live forever — and since
    /// [`reconcilable_focus_tags`] is this set plus `pending_departures`, it
    /// would inherit the same permanent membership, so `retain_pins` could
    /// never collect that focus's pin.
    ///
    /// `None` rather than an empty set is the point: "nobody has told us which
    /// focuses exist" and "no focus exists" must not be the same value, or
    /// every caller has to remember to special-case the difference.
    ///
    /// See [`reconcilable_focus_tags`] for the sibling question this one is
    /// deliberately *not* answering: whether a tag's pin may be deleted.
    ///
    /// [`reconcilable_focus_tags`]: SessionManager::reconcilable_focus_tags
    pub fn live_focus_tags(&self) -> Option<HashSet<String>> {
        let tags: HashSet<String> = self
            .focus_registry
            .iter()
            .map(|f| f.tag.clone())
            .chain(self.daemon_created_tags.iter().cloned())
            .collect();
        if tags.is_empty() {
            None
        } else {
            Some(tags)
        }
    }

    /// The set of tags every pin on disk may be reconciled against — the
    /// backstop half of D8 — or `None` when this daemon cannot yet vouch for a
    /// complete picture of what exists.
    ///
    /// [`live_focus_tags`] answers "what is live right now" and is the right
    /// question for *serving* a pin. This answers the strictly harder question
    /// "what may I **delete** a pin for", and it is deliberately more
    /// conservative on both counts that D8a is conservative about, because
    /// deletion is irreversible and a pin is an operator's review in progress:
    ///
    /// - **`pending_departures` count as live.** A tag one push claimed was
    ///   gone has not departed until a second push agrees. Reconciling against
    ///   `live_focus_tags` alone would delete its pin a whole push before the
    ///   primary eviction path is willing to, which is D8a's guarantee
    ///   inverted.
    /// - **`None` until two non-empty pushes have landed.** A reconnecting
    ///   client can push a partial list before it has finished loading. A
    ///   partial push is not distinguishable from a complete one in isolation,
    ///   and on the first push there is no previous registry to notice the
    ///   omission against — so a real focus omitted from a partial first push
    ///   would have its pin collected. From the second push on, an omitted tag
    ///   is in `pending_departures` and protected by the bullet above.
    /// - **An empty push resets that count to zero.** It is tempting to read
    ///   the empty case as merely "no information", but `set_focus_registry`
    ///   *acts* on it: the registry becomes empty and `pending_departures` is
    ///   cleared, so every previously-known tag is now in neither. Were the
    ///   count left standing, an outstanding daemon-created tag would be the
    ///   only thing `live_focus_tags` still reported, this would answer `Some`
    ///   with that tag alone, and `retain_pins` would delete every other
    ///   focus's pin — on a push whose entire contract is that it evicts
    ///   nothing. Resetting puts the backstop back where it was at startup,
    ///   which is the only honest description of what the daemon now knows.
    ///
    /// Two consecutive pushes agreeing is exactly the evidence standard D8a
    /// already demands before deleting anything, which is the point: the
    /// backstop must not be able to destroy something the primary path would
    /// have spared.
    ///
    /// [`live_focus_tags`]: SessionManager::live_focus_tags
    pub fn reconcilable_focus_tags(&self) -> Option<HashSet<String>> {
        if self.non_empty_pushes_seen < 2 {
            return None;
        }
        let mut tags = self.live_focus_tags()?;
        tags.extend(self.pending_departures.iter().cloned());
        Some(tags)
    }

    /// A focus that runs the Fred/Teri agent is sensitive even when no session
    /// of it is live yet (its persisted layout and panes are replayed to a
    /// connecting client before the session respawns).
    ///
    /// Called for registries pushed by a *local* peer only: the registration is
    /// permanent and persisted, so a network peer must not be able to grow it.
    pub fn mark_teri_fred_focuses(&self, focuses: &[FocusMeta]) {
        for focus in focuses
            .iter()
            .filter(|f| is_teri_or_fred_agent(&f.agent_name) || is_huey_agent(&f.agent_name))
        {
            self.sensitive.mark_tag(&focus.tag);
        }
    }

    /// Current focus registry snapshot.
    pub fn focus_registry(&self) -> Vec<FocusMeta> {
        self.focus_registry.clone()
    }

    /// The history of session ids this daemon has spawned for each focus tag.
    pub fn session_history(&self) -> SessionHistory {
        self.session_history.clone()
    }

    /// Use `history` instead of the one beside the session store.
    pub fn configure_session_history(&mut self, history: SessionHistory) {
        self.session_history = history;
    }

    /// Hand the daemon's origin book the focus registry from now on (and now),
    /// and the registry of sensitive tags, which it asks when the poll decides
    /// a job's origin.
    pub fn configure_origin_book(&mut self, book: OriginBook) {
        book.note_registry_update(&self.focus_registry);
        let tags = self.sensitive.clone();
        book.set_sensitivity(move |tag| tags.tag_is_sensitive(tag));
        self.origin_book = Some(book);
    }

    /// The origin book, when the daemon wired one in.
    pub fn origin_book(&self) -> Option<OriginBook> {
        self.origin_book.clone()
    }

    /// Who `tag` is for the purpose of stamping a Mother job it queues: its
    /// registry name now and the Claude session it is running. `None` for a
    /// tag the daemon does not know as a focus (nothing is stamped for it).
    pub fn origin_caller(&self, tag: &str) -> Option<OriginCaller> {
        if tag.is_empty() || !self.knows_focus(tag) {
            return None;
        }
        let meta = self.focus_registry.iter().find(|f| f.tag == tag);
        let agent = meta.map_or("", |f| f.agent_name.as_str());
        Some(OriginCaller {
            tag: tag.to_owned(),
            name: meta.map(|f| f.display_name.clone()),
            session: self.current_session_id(tag),
            sensitive: self.sensitive.focus_is_sensitive(tag, agent),
        })
    }

    /// Tell the origin book the registry changed; `pushed` when the Mac pushed
    /// it (the only evidence a missing tag is closed).
    fn note_origin_registry(&self, pushed: bool) {
        if let Some(book) = &self.origin_book {
            if pushed {
                // A tag one push lacked is not closed until a second push
                // agrees (the departure debounce), nor is a daemon-created one
                // the Mac has not acknowledged.
                let retained = self
                    .pending_departures
                    .iter()
                    .chain(self.daemon_created_tags.iter())
                    .cloned()
                    .collect();
                book.note_registry_push_retaining(&self.focus_registry, retained);
            } else {
                book.note_registry_update(&self.focus_registry);
            }
        }
    }

    /// Whether `tag` currently has a live (non-exited) session child.
    /// The working directory `tag`'s session was spawned in, if it has one.
    ///
    /// This is the root every file read for that focus is resolved against
    /// (W2 — curated-agent-views): a focus's session cwd is the only
    /// definition of "the repo" the daemon has, and confining reads to it is
    /// what makes `path_escapes_root` enforceable.
    pub fn cwd_for(&self, tag: &str) -> Option<PathBuf> {
        self.sessions.get(tag).and_then(|s| s.cwd.clone())
    }

    /// The Claude session id `tag` is running (or will `--resume`): the live
    /// session's id, else the daemon's persisted `tag -> session_id` record.
    /// `None` for a tag the daemon has never spawned.
    pub fn current_session_id(&self, tag: &str) -> Option<String> {
        self.sessions
            .get(tag)
            .and_then(|s| s.session_id.clone())
            .or_else(|| load_id_store(&self.store_path).remove(tag))
    }

    pub fn has_live_session(&self, tag: &str) -> bool {
        self.sessions.get(tag).map(|s| s.alive()).unwrap_or(false)
    }

    /// Run every future session of `tag` under `restrictions` (a restart or a
    /// crash recovery included). Not undone for the life of the process: the
    /// tag is reserved for restricted use.
    pub fn restrict_tag(&mut self, tag: &str, restrictions: SessionRestrictions) {
        self.restrictions.insert(tag.to_owned(), restrictions);
    }

    /// The restrictions `tag`'s sessions run under, if any.
    pub fn restrictions_for(&self, tag: &str) -> Option<&SessionRestrictions> {
        self.restrictions.get(tag)
    }

    /// `tag` is in the pushed focus registry.
    pub fn is_registered(&self, tag: &str) -> bool {
        self.focus_registry.iter().any(|f| f.tag == tag)
    }

    /// Has the Mac reported a registry this daemon can vouch for? True after
    /// two non-empty pushes: the evidence standard `set_focus_registry` and
    /// `reconcilable_focus_tags` already use before they delete anything.
    ///
    /// A restarted daemon starts with an empty registry and no sessions, so
    /// until this is true "not registered" means "not heard of yet", not
    /// "closed". An empty push puts it back to false: it is
    /// indistinguishable from a client that has not loaded yet (D8a), so it
    /// is treated as no information rather than as "the user closed every
    /// focus". The cost is that markers of focuses closed that way linger
    /// (harmlessly, and a stopped session still reads as dead) until two
    /// later non-empty pushes.
    pub fn registry_known(&self) -> bool {
        self.non_empty_pushes_seen >= 2
    }

    /// May a focus under `tag` still exist? Everything may while the registry
    /// is unknown; afterwards only a registered tag, or one a single push
    /// claimed was gone (it has not departed until a second push agrees).
    pub fn focus_may_exist(&self, tag: &str) -> bool {
        !self.registry_known() || self.is_registered(tag) || self.pending_departures.contains(tag)
    }

    /// Does this process hold a session entry (live or exited) for `tag`?
    pub fn has_session_entry(&self, tag: &str) -> bool {
        self.sessions.contains_key(tag)
    }

    /// Record `nonce` as the identity of the focus now running under `tag`.
    pub fn set_focus_nonce(&mut self, tag: &str, nonce: String) {
        self.focus_nonces.insert(tag.to_owned(), nonce);
    }

    /// The nonce of the focus last created under `tag` by this process.
    pub fn focus_nonce(&self, tag: &str) -> Option<&str> {
        self.focus_nonces.get(tag).map(String::as_str)
    }

    /// Insert or replace a single focus in the registry (by `tag`), returning the
    /// updated registry so the caller can broadcast it. Used by the
    /// `create_focus` MCP tool, which adds an agent-spawned focus to the
    /// daemon-owned registry.
    pub fn add_or_update_focus(&mut self, meta: FocusMeta) -> Vec<FocusMeta> {
        self.mark_teri_fred_focuses(std::slice::from_ref(&meta));
        if in_work_send() {
            self.sensitive.mark_tag(&meta.tag);
        }
        // This is the only way a focus enters the registry other than a Mac
        // push, so it is where a daemon-created tag earns its eviction
        // exemption (W7 — D8b).
        self.daemon_created_tags.insert(meta.tag.clone());
        self.pending_departures.remove(&meta.tag);
        if let Some(existing) = self.focus_registry.iter_mut().find(|f| f.tag == meta.tag) {
            *existing = meta;
        } else {
            self.focus_registry.push(meta);
        }
        self.note_origin_registry(false);
        self.focus_registry.clone()
    }

    // ── shutdown ────────────────────────────────────────────────────────────

    /// Before shutdown kills the children: deny every pending permission request
    /// `restart` (the deny is written before this returns), then wait up to
    /// `timeout` for each affected session to print the result of the call it
    /// denied, or to exit, so the agent hears why instead of seeing a dead pipe.
    pub fn prepare_shutdown(&self, timeout: Duration) {
        let Some(broker) = self.approvals.clone() else {
            return;
        };
        let deadline = Instant::now() + timeout;
        // The denies are written on a helper thread: a write waits for the
        // session's stdin lock, and another thread may hold it in a long write to a
        // CLI that stopped reading. Shutdown must not wait on that.
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(broker.deny_all_for_shutdown());
        });
        let Ok(mut waiting) = rx.recv_timeout(timeout) else {
            warn!("shutdown: the pending permission requests could not all be denied in time");
            return;
        };
        while !waiting.is_empty() && Instant::now() < deadline {
            waiting.retain(|(tag, tool_use_id)| {
                self.sessions.get(tag).is_some_and(|s| {
                    s.alive() && !lock_recover(&s.shared.transcript).has_tool_result(tool_use_id)
                })
            });
            if !waiting.is_empty() {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }

    /// Stop all children. Called on SIGTERM. Each CLI (and its process group)
    /// gets SIGTERM first, so it can stop its own background tasks and flush its
    /// transcript, and whatever is still there after [`SHUTDOWN_GRACE`] (shared
    /// by all sessions, which stop in parallel) gets SIGKILL.
    ///
    /// Idempotent: a second call finds no sessions and does nothing. If the
    /// daemon dies before this finishes, the ledger is left for the next start
    /// to sweep.
    pub fn kill_all_on_shutdown(&mut self) {
        self.kill_all_on_shutdown_with_grace(SHUTDOWN_GRACE);
    }

    /// [`Self::kill_all_on_shutdown`] with an explicit grace.
    pub fn kill_all_on_shutdown_with_grace(&mut self, grace: Duration) {
        if self.sessions.is_empty() {
            // Nothing running; tidy up what `stop` left in the ledger.
            self.ledger.clear();
            return;
        }
        let mut targets = Vec::new();
        for (tag, session) in &mut self.sessions {
            session.intentional_stop.store(true, Ordering::SeqCst);
            for (_, h) in session.forwarders.drain() {
                h.abort();
            }
            // A session whose CLI already exited and was reaped is not signalled.
            let target = session.stop_target();
            targets.push((tag.clone(), target));
            info!(tag = %tag, "stopping session on shutdown");
        }
        let live: Vec<Target> = targets.iter().filter_map(|(_, t)| *t).collect();
        let stragglers = orphans::terminate(&live, grace, || {
            // Reap exited CLIs so a zombie does not look like a live group member.
            for session in self.sessions.values_mut() {
                session.try_reap();
            }
        });
        if !stragglers.is_empty() {
            warn!(
                count = stragglers.len(),
                "shutdown: sessions still running after the grace were killed"
            );
        }
        for (tag, target) in &targets {
            // Only what outlived the grace is killed; a group that is gone may
            // by now be a recycled id. The ledger is left alone until the end.
            if let (Some(t), Some(session)) = (target, self.sessions.get_mut(tag)) {
                if stragglers.contains(t) {
                    session.signal_kill();
                }
            }
            info!(tag = %tag, "session stopped on shutdown");
        }
        self.sessions.clear();
        // The record goes only when nothing it names is left (a process that
        // survived SIGKILL, or whose zombie nobody reaped, stays swept-for).
        if live.iter().all(|t| !t.exists()) {
            self.ledger.clear();
        } else {
            warn!("shutdown: some session processes are still present; the child ledger is kept for the next start");
        }
    }

    /// Detach all of a disconnecting client's sessions (children keep running).
    pub fn on_client_disconnect(&mut self, client_id: &str) {
        for session in self.sessions.values_mut() {
            session.attached_clients.remove(client_id);
            session.shared.tasks.set_clients(local_client_count(
                &session.attached_clients,
                &self.network_clients,
            ));
            if let Some(h) = session.forwarders.remove(client_id) {
                h.abort();
            }
        }
        self.network_clients.remove(client_id);
        self.client_senders.lock().unwrap().remove(client_id);

        // Drop any rendered-shape reports this connection contributed (W1 —
        // render-state-visibility) — a closed window's report must not
        // outlive the connection that sent it.
        if let Some(reg) = &self.pane_registry {
            reg.lock()
                .unwrap()
                .prune_rendered_shapes_for_conn(client_id);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    fn send_to_client(&self, client_id: &str, msg: ServerMsg) {
        let senders = self.client_senders.lock().unwrap();
        if let Some(tx) = senders.get(client_id) {
            let _ = tx.send(msg);
        }
    }

    /// Broadcast a message to every currently connected client.
    fn send_to_all_clients(&self, msg: ServerMsg) {
        let senders = self.client_senders.lock().unwrap();
        for tx in senders.values() {
            let _ = tx.send(msg.clone());
        }
    }

    /// Scan all sessions for pending summary emissions.  Called from the
    /// supervisor tick immediately after `reap_and_recover`.  For each session
    /// whose `summary_sent` flag is still false, derives a summary from the
    /// transcript's first user prompt and broadcasts it to all clients.  The
    /// flag is set to `true` before the broadcast so a second tick is a no-op
    /// even if the send fails.
    pub fn emit_pending_summaries(&self) {
        for (tag, session) in &self.sessions {
            if session.summary_sent.load(Ordering::SeqCst) {
                continue;
            }
            let first = session
                .shared
                .transcript
                .lock()
                .unwrap()
                .first_user_input()
                .map(str::to_owned);
            let Some(first) = first else {
                continue;
            };
            if let Some(summary) = derive_summary(&first) {
                session.summary_sent.store(true, Ordering::SeqCst);
                self.send_to_all_clients(ServerMsg::SessionSummaryUpdate {
                    tag: tag.clone(),
                    summary,
                });
            }
        }
    }

    #[cfg(test)]
    fn session_state(&self, tag: &str) -> Option<SessionState> {
        self.sessions.get(tag).map(|s| s.state())
    }
}

impl Default for SessionManager {
    fn default() -> Self {
        Self::new()
    }
}

// ── reader loop ───────────────────────────────────────────────────────────────

/// Blocking stdout reader: parse each line into the transcript, broadcast
/// deltas, drive turn state, drain the pending queue, and signal EOF. Control
/// responses are handed to whoever waits for them, and model reports are
/// recorded; the reader itself never waits on anything but stdout.
fn run_reader(
    tag: String,
    stdout: std::process::ChildStdout,
    shared: Shared,
    approvals: Option<ApprovalLink>,
) {
    let reader = BufReader::new(stdout);
    // Follows the turn now running, to tell at its end whether it failed to
    // authenticate and whether sending its message again repeats anything.
    let mut auth = TurnAuthTracker::new();
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                debug!(tag = %tag, "session reader error: {e}");
                break;
            }
        };
        if line.trim().is_empty() {
            continue;
        }
        let parsed = parse_line(&line);
        auth.feed(classify_line(&line), parsed.as_ref());
        let Some(parsed) = parsed else {
            continue;
        };

        match &parsed {
            ParsedLine::ControlResponse {
                request_id,
                ok,
                error,
                error_code,
                body,
            } => {
                let waiter = lock_recover(&shared.waiters).remove(request_id);
                if let Some(tx) = waiter {
                    let _ = tx.send(ControlReply {
                        ok: *ok,
                        error: error.clone(),
                        error_code: error_code.clone(),
                        body: body.clone(),
                    });
                }
                continue;
            }
            ParsedLine::ControlRequest {
                request_id,
                subtype,
                request,
            } => {
                route_control_request(
                    &tag,
                    &shared,
                    approvals.as_ref(),
                    request_id,
                    subtype,
                    request,
                );
                continue;
            }
            ParsedLine::UnreadableControlRequest {
                request_id,
                subtype,
                tool_name,
            } => {
                route_unreadable_control_request(
                    &tag,
                    &shared,
                    approvals.as_ref(),
                    request_id.as_ref(),
                    subtype.as_deref(),
                    tool_name.as_deref(),
                );
                continue;
            }
            ParsedLine::ControlCancel { request_id } => {
                if let Some(link) = &approvals {
                    let cancel = Incoming::Cancel {
                        tag: tag.clone(),
                        cli_request_id: request_id.clone(),
                    };
                    if link.broker.submit(cancel).is_err() {
                        // The broker's worker is gone: do it inline.
                        link.broker.on_cancel(&tag, request_id);
                    }
                }
                continue;
            }
            ParsedLine::Model { model, .. }
            | ParsedLine::Blocks {
                model: Some(model), ..
            } => on_model_report(&shared, model),
            ParsedLine::ModelFallback { content, .. } => {
                lock_recover(&shared.model).fallback = content.clone();
            }
            ParsedLine::Task(event) => {
                shared.tasks.on_event(&shared.event_tx, event);
                ensure_poller(&shared);
                ensure_probe(&shared);
            }
            _ => {}
        }

        let deltas = lock_recover(&shared.transcript).ingest_parsed(parsed);
        for delta in deltas {
            match &delta {
                TurnDelta::TurnStarted { .. } => {
                    auth.begin_turn();
                    login::on_turn_started(&shared);
                    shared.set_state(SessionState::MidTurn);
                }
                // A phantom dropped as the real prompt arrives is no turn
                // end: that prompt's turn is live, and advancing would write
                // the next queued message into it or start a switch mid-turn.
                TurnDelta::TurnErrored {
                    discarded: true, ..
                } => {}
                TurnDelta::TurnCompleted { .. } | TurnDelta::TurnErrored { .. } => {
                    shared.broadcast(SessionEvent::Delta(delta.clone()));
                    // A turn that failed to authenticate makes a hold, and `step`
                    // does not drain the queue while one exists.
                    login::on_turn_end(&shared, &tag, auth.finish());
                    advance(&shared);
                    continue;
                }
                _ => {}
            }
            shared.broadcast(SessionEvent::Delta(delta));
        }
    }

    // stdout closed → child exited / stream ended. The reader can't see the
    // child's exit code (it owns only stdout); reap_and_recover captures the
    // real code via child.try_wait() and re-broadcasts Exited with it.
    // `exited` is set before the waiters are dropped, so a control request
    // registered after this point sees it (see `control::control`).
    shared.exited.store(true, Ordering::SeqCst);
    // The tasks end with the process, and clients hear it before anything is
    // torn down.
    shared.tasks.end_session(&shared.event_tx);
    lock_recover(&shared.waiters).clear();
    if let Some(link) = &approvals {
        // Requests still pending ended with the process: nothing to write to.
        link.broker.on_session_gone(&tag, link.generation, "exited");
    }
    shared.broadcast(SessionEvent::Exited { exit_code: None });
    publish_model_state(&shared);
    tracing::warn!(tag = %tag, "session reader EOF — child stdout closed (crash or clean exit)");
}

/// The approval broker and the generation of the process a reader reads.
struct ApprovalLink {
    broker: ApprovalBroker,
    generation: u64,
}

/// A session's stdin as the approval broker answers through it.
struct StdinSink {
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    exited: Arc<AtomicBool>,
}

impl SessionSink for StdinSink {
    fn live(&self) -> bool {
        !self.exited.load(Ordering::SeqCst)
    }

    fn respond(&self, cli_request_id: &str, response: &serde_json::Value) -> std::io::Result<()> {
        if !self.live() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::BrokenPipe,
                "session has exited",
            ));
        }
        write_control_response(&self.stdin, cli_request_id, response).map_err(std::io::Error::other)
    }
}

/// A `control_request` from the CLI. A permission prompt (`can_use_tool`) goes to
/// the broker by channel, never waiting on it; if the broker cannot take it, the
/// reader denies it itself, because the CLI must never be left waiting. Any other
/// subtype gets an error answer: our flags give the CLI no other host-bound request,
/// and one that arrived anyway (an elicitation, something newer) must not be left
/// waiting either.
fn route_control_request(
    tag: &str,
    shared: &Shared,
    link: Option<&ApprovalLink>,
    request_id: &str,
    subtype: &str,
    request: &serde_json::Value,
) {
    let id = serde_json::Value::String(request_id.to_owned());
    if subtype != "can_use_tool" {
        warn!(
            tag,
            subtype, "control_request of an unsupported subtype: answering it with an error"
        );
        answer_unsupported(tag, shared, &id);
        return;
    }
    let incoming = || Incoming::Request {
        tag: tag.to_owned(),
        generation: link.map_or(0, |l| l.generation),
        cli_request_id: request_id.to_owned(),
        value: request.clone(),
    };
    let deny = || deny_unless_exited(shared, &id, APPROVAL_UNAVAILABLE_MESSAGE);
    if let Some(link) = link {
        if link.broker.submit(incoming()).is_ok() {
            return;
        }
        warn!(
            tag,
            "no approval broker to take a permission request: denying it"
        );
        link.broker
            .record_unqueued_denial(tag, link.generation, request, deny);
        return;
    }
    warn!(
        tag,
        "no approval broker to take a permission request: denying it"
    );
    if let Err(e) = deny() {
        warn!(tag, "could not write the deny: {e}");
    }
}

/// A `control_request` the reader could not read in full (see
/// [`ParsedLine::UnreadableControlRequest`]). Dropping it would leave the CLI waiting
/// for ever (it has no timeout), so it is answered from what the scan recovered:
///
/// - a subtype other than `can_use_tool`: an error answer, like any unsupported request;
/// - otherwise (`can_use_tool`, or a subtype that could not be made out: most likely
///   a permission prompt) with the request id: a deny, and a `request` + `outcome`
///   entry in the audit log;
/// - no request id: nothing can be answered under, so there is a content-free error
///   in the daemon log and one `request_unparseable` audit entry.
///
/// The line itself is never kept or logged: it can be megabytes and hold anything.
fn route_unreadable_control_request(
    tag: &str,
    shared: &Shared,
    link: Option<&ApprovalLink>,
    request_id: Option<&serde_json::Value>,
    subtype: Option<&str>,
    tool_name: Option<&str>,
) {
    let Some(id) = request_id else {
        error!(
            tag,
            "a control request from the CLI could not be read and has no id to answer under"
        );
        if let Some(link) = link {
            link.broker.record_unparseable(tag, link.generation);
        }
        return;
    };
    if subtype.is_some_and(|s| s != "can_use_tool") {
        warn!(
            tag,
            "unreadable control_request of an unsupported subtype: answering it with an error"
        );
        answer_unsupported(tag, shared, id);
        return;
    }
    warn!(tag, "a permission request could not be read: denying it");
    let deny = || deny_unless_exited(shared, id, INVALID_REQUEST_MESSAGE);
    match link {
        Some(link) => link
            .broker
            .record_unreadable_denial(tag, link.generation, tool_name, deny),
        None => {
            if let Err(e) = deny() {
                warn!(tag, "could not write the deny: {e}");
            }
        }
    }
}

/// The error answer to a request the host does not handle.
fn answer_unsupported(tag: &str, shared: &Shared, request_id: &serde_json::Value) {
    if shared.exited.load(Ordering::SeqCst) {
        return;
    }
    if let Err(e) = write_control_error(&shared.stdin, request_id, UNSUPPORTED_REQUEST_ERROR) {
        warn!(tag, "could not write the error answer: {e}");
    }
}

/// Write a deny to a session that has not exited. This is the reader's own write
/// (the broker did not take the request, or could not read it).
///
/// It cannot deadlock the reader. The write is one small line (a few hundred bytes,
/// under `PIPE_BUF`), made while the CLI is waiting for exactly this answer, so the
/// CLI is reading its stdin; the CLI reads stdin whether or not we read its stdout,
/// so the pipe drains. The only thing ahead of it on the pipe or on the stdin lock
/// (a leaf lock) is another of our own frames, which the CLI is draining the same
/// way, and the broker's worker and watchdog write through this same path anyway.
fn deny_unless_exited(
    shared: &Shared,
    request_id: &serde_json::Value,
    message: &str,
) -> std::io::Result<()> {
    if shared.exited.load(Ordering::SeqCst) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::BrokenPipe,
            "session has exited",
        ));
    }
    write_control_response_to(&shared.stdin, request_id, &deny_response(message))
        .map_err(std::io::Error::other)
}

/// After a turn ends or a switch has been applied: apply a switch waiting for
/// the turn first, else send the next queued message (staying mid-turn), else
/// go idle. While a switch is being applied nothing is sent: the switch task
/// calls [`finish_apply`] when it is done.
fn advance(shared: &Shared) {
    step(shared, false);
}

/// A switch task is done: leave `Applying` and carry on as after a turn, in
/// one critical section, so a message sent meanwhile can't overtake the queue.
fn finish_apply(shared: &Shared) {
    step(shared, true);
}

fn step(shared: &Shared, finished_apply: bool) {
    enum Next {
        Apply(ModelTarget, Actor),
        Write(PendingMessage),
        Idle,
    }
    // Tolerant of a poisoned lock: this is the cleanup that ends `Applying`,
    // and it must still run after a switch task panicked holding one.
    let next = {
        let mut state = lock_recover(&shared.state);
        let mut rt = lock_recover(&shared.model);
        if finished_apply {
            rt.applying = None;
        }
        let exited = shared.exited.load(Ordering::SeqCst);
        if rt.applying.is_some() {
            *state = SessionState::Idle;
            Next::Idle
        } else if let Some((target, actor)) = rt.waiting.take_if(|_| !exited) {
            rt.applying = Some(target.clone());
            *state = SessionState::Idle;
            Next::Apply(target, actor)
        } else {
            // A switch still waiting once the process has exited stays put:
            // the respawn inherits it (`take_carry`) rather than failing it.
            drop(rt);
            // The next message is only taken while the process is up. It is
            // written after `state` is released (a stalled CLI must not wedge
            // every reader of `state`), so `writing` marks it in flight:
            // `take_carry` (restart and crash recovery) waits for the write's
            // outcome, which keeps a message either written here or still
            // queued for the respawned session, never dropped between the two.
            // Nor while the session waits for a sign-in: the queue stays behind
            // the held message (a switch may still apply).
            let msg = if exited || shared.login.paused() {
                None
            } else {
                lock_recover(&shared.pending).pop_front()
            };
            match msg {
                Some(msg) => {
                    shared.writing.store(true, Ordering::SeqCst);
                    *state = SessionState::MidTurn;
                    Next::Write(msg)
                }
                None => {
                    *state = SessionState::Idle;
                    Next::Idle
                }
            }
        }
    };
    match next {
        Next::Apply(target, actor) => {
            shared.broadcast(SessionEvent::State(SessionState::Idle));
            spawn_apply(shared, target, actor, None);
        }
        Next::Write(msg) => {
            let in_flight = WriteInFlight {
                shared,
                msg: Some(msg),
            };
            let wrote = in_flight.write().is_ok();
            in_flight.finish(wrote);
        }
        Next::Idle => shared.broadcast(SessionEvent::State(SessionState::Idle)),
    }
    if finished_apply {
        publish_model_state(shared);
    }
}

/// How long to wait for an in-flight write of a queued message before
/// moving on without it (see `take_carry` and `interrupt`). The write has no
/// reason to outlast the limit: it is only a pipe write, and a CLI too stalled
/// to read it has bigger problems; the limit only keeps that from wedging the
/// caller.
const WRITE_WAIT_LIMIT: Duration = Duration::from_secs(5);

/// A queued message `step` took off `pending` and is writing to stdin, with
/// `shared.writing` set. However the write ends, even by a panic, `writing`
/// is cleared and an undelivered message goes back to the front of the queue
/// (the session idle), so `take_carry` never waits on a write that is over.
struct WriteInFlight<'a> {
    shared: &'a Shared,
    msg: Option<PendingMessage>,
}

impl WriteInFlight<'_> {
    fn write(&self) -> Result<()> {
        match &self.msg {
            Some(msg) => write_user_message(self.shared, msg),
            None => Ok(()),
        }
    }

    fn finish(mut self, wrote: bool) {
        self.settle(wrote);
    }

    fn settle(&mut self, wrote: bool) {
        let Some(msg) = self.msg.take() else { return };
        {
            let mut state = lock_recover(&self.shared.state);
            if !wrote {
                lock_recover(&self.shared.pending).push_front(msg);
                *state = SessionState::Idle;
            }
            self.shared.writing.store(false, Ordering::SeqCst);
        }
        self.shared.broadcast(SessionEvent::State(if wrote {
            SessionState::MidTurn
        } else {
            SessionState::Idle
        }));
    }
}

impl Drop for WriteInFlight<'_> {
    /// Reached with the message still held only when the write panicked.
    fn drop(&mut self) {
        self.settle(false);
    }
}

// ── image encoding helpers ────────────────────────────────────────────────────

struct EncodedImage {
    media_type: String,
    base64_data: String,
}

fn media_type_for(path: &str) -> &'static str {
    match std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

/// Encode each readable image; return the ones that could not be read as
/// `(path, error)` so the caller can say so instead of silently sending a
/// message with the image missing (the agent would otherwise go hunting for it).
fn encode_images(paths: &[String]) -> (Vec<EncodedImage>, Vec<(String, String)>) {
    use base64::{engine::general_purpose::STANDARD, Engine as _};
    let mut ok = Vec::new();
    let mut failed = Vec::new();
    for p in paths {
        match std::fs::read(p) {
            Ok(bytes) => ok.push(EncodedImage {
                media_type: media_type_for(p).to_string(),
                base64_data: STANDARD.encode(bytes),
            }),
            Err(e) => {
                tracing::warn!(path = %p, "unreadable image: {e}");
                failed.push((p.clone(), e.to_string()));
            }
        }
    }
    (ok, failed)
}

/// Text appended to a message when attachments could not be read.
fn unreadable_images_note(failed: &[(String, String)]) -> String {
    let list = failed
        .iter()
        .map(|(p, e)| format!("{p} ({e})"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "\n\n[Nostromo could not read the attached image file(s): {list}. \
         The image was NOT delivered; do not search the filesystem for it — \
         ask the user to re-attach it.]"
    )
}

/// What [`SessionManager::interrupt`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InterruptOutcome {
    /// A turn was running; the interrupt was sent to the child.
    Requested,
    /// The session was idle: nothing to interrupt.
    NotRunning,
    /// The session was waiting for a sign-in: Stop discarded the held message
    /// and the queue behind it, so nothing is sent after the sign-in.
    DiscardedHold,
}

/// Write one stream-json `control_request` frame (`request` is the body, e.g.
/// `{"subtype":"interrupt"}`) to the child's stdin.
fn write_control_request(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    request_id: &str,
    request: serde_json::Value,
) -> Result<()> {
    write_frame(
        stdin,
        &serde_json::json!({
            "type": "control_request",
            "request_id": request_id,
            "request": request,
        }),
    )
}

/// Write the answer to a request the CLI made of us (`request_id` is the CLI's),
/// `response` being the body (e.g. a permission deny). Callers only write to a
/// session that has not exited.
fn write_control_response(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    request_id: &str,
    response: &serde_json::Value,
) -> Result<()> {
    write_control_response_to(
        stdin,
        &serde_json::Value::String(request_id.to_owned()),
        response,
    )
}

/// [`write_control_response`] for a request id of any JSON value: the CLI's id is
/// answered as it arrived, a number staying a number.
fn write_control_response_to(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    request_id: &serde_json::Value,
    response: &serde_json::Value,
) -> Result<()> {
    write_frame(
        stdin,
        &serde_json::json!({
            "type": "control_response",
            "response": {
                "subtype": "success",
                "request_id": request_id,
                "response": response,
            },
        }),
    )
}

/// Write the error answer (`subtype: "error"`) to a request the CLI made of us.
fn write_control_error(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    request_id: &serde_json::Value,
    error: &str,
) -> Result<()> {
    write_frame(
        stdin,
        &serde_json::json!({
            "type": "control_response",
            "response": {
                "subtype": "error",
                "request_id": request_id,
                "error": error,
            },
        }),
    )
}

/// Write one JSON frame as a line to the child's stdin (a leaf lock).
fn write_frame(stdin: &Arc<Mutex<Option<ChildStdin>>>, frame: &serde_json::Value) -> Result<()> {
    let mut line = serde_json::to_string(frame)?;
    line.push('\n');
    let mut guard = lock_recover(stdin);
    let stdin = guard
        .as_mut()
        .ok_or_else(|| anyhow!("session stdin is closed"))?;
    stdin.write_all(line.as_bytes())?;
    stdin.flush()?;
    Ok(())
}

/// Write a queued or direct user message, with the pending agent note (if
/// any) in front of it. The exact frame is remembered (see `login::write_recorded`)
/// so a turn that fails to authenticate can hold it.
fn write_user_message(shared: &Shared, msg: &PendingMessage) -> Result<()> {
    let prefix = lock_recover(&shared.note_prefix).take();
    match prefix {
        Some(note) => {
            let text = format!(
                "{NOSTROMO_NOTE_OPEN}{note}{NOSTROMO_NOTE_CLOSE}{}",
                msg.text
            );
            let result = login::write_recorded(
                shared,
                &PendingMessage {
                    text,
                    images: msg.images.clone(),
                    origin: msg.origin.clone(),
                },
            );
            if result.is_err() {
                // Not delivered: the note goes with the next message instead.
                *lock_recover(&shared.note_prefix) = Some(note);
            }
            result
        }
        None => login::write_recorded(shared, msg),
    }
}

/// Write one stream-json user-message frame to the child's stdin.
/// When `images` is non-empty, emits array content (text block + image blocks);
/// when empty, emits a plain string — byte-identical to the pre-image wire format.
fn write_user_frame(
    stdin: &Arc<Mutex<Option<ChildStdin>>>,
    text: &str,
    images: &[String],
) -> Result<()> {
    let (encoded, failed) = encode_images(images);
    let note = if failed.is_empty() {
        String::new()
    } else {
        unreadable_images_note(&failed)
    };
    let text = format!("{text}{note}");
    let text = text.as_str();
    let content = if encoded.is_empty() {
        serde_json::json!(text)
    } else {
        let mut blocks = vec![serde_json::json!({ "type": "text", "text": text })];
        for img in &encoded {
            blocks.push(serde_json::json!({
                "type": "image",
                "source": {
                    "type": "base64",
                    "media_type": img.media_type,
                    "data": img.base64_data,
                }
            }));
        }
        serde_json::json!(blocks)
    };
    let frame = serde_json::json!({
        "type": "user",
        "message": { "role": "user", "content": content }
    });
    let mut line = serde_json::to_string(&frame)?;
    line.push('\n');

    let mut guard = lock_recover(stdin);
    let stdin = guard
        .as_mut()
        .ok_or_else(|| anyhow!("session stdin closed"))?;
    stdin.write_all(line.as_bytes())?;
    stdin.flush()?;
    Ok(())
}

// ── claude resolution + arg construction ──────────────────────────────────────

/// Exponential backoff for the nth transient restart. `crash_count` is the
/// number of crashes recorded in the current sliding window *including* the one
/// just observed (so the first transient restart waits BACKOFF_BASE_SECS).
/// Capped at BACKOFF_MAX_SECS.
fn backoff_delay(crash_count: u32) -> Duration {
    let exp = crash_count.saturating_sub(1).min(16); // guard against shift overflow
    let secs = BACKOFF_BASE_SECS
        .saturating_mul(1u64 << exp)
        .min(BACKOFF_MAX_SECS);
    Duration::from_secs(secs)
}

/// Build the `claude` argument vector for a persistent stream-json session. An
/// empty `agent_name` starts the session with no `--agent`.
///
/// `guard_settings` is the production-shell guard's inline `--settings` JSON
/// ([`crate::approvals::guard::hook_settings_json`]); see
/// [`build_claude_args_with`].
pub fn build_claude_args(
    agent_name: &str,
    view_name: &str,
    remote_control: bool,
    session_id: &str,
    resume: bool,
    guard_settings: &str,
) -> Vec<String> {
    build_claude_args_with(
        agent_name,
        view_name,
        remote_control,
        session_id,
        resume,
        None,
        guard_settings,
    )
}

/// [`build_claude_args`], optionally under [`SessionRestrictions`].
///
/// Unrestricted sessions keep `--dangerously-skip-permissions` (see below).
/// A restricted one drops it for `--permission-mode dontAsk` plus the
/// allow-list flags: the allow-list is then the only thing it may use.
///
/// **Both** kinds get `["--settings", guard_settings]` right after their
/// permission flag: the production-shell guard's PreToolUse hook. A hook
/// passed inline runs under bypass and under `dontAsk` alike, before any
/// permission decision, and its `"disableAllHooks":false` wins over a user
/// setting an agent could write mid-session. Neither the bypass nor the
/// allow-list may be the thing that lets an agent type into a production shell.
///
/// An unrestricted session that is not `--remote-control` is **approval-capable**:
/// it also gets `--permission-prompt-tool stdio`, right after the guard
/// `--settings`, so the CLI sends its permission prompts to the daemon instead of
/// denying them silently. A restricted or remote-control session's arguments are
/// unchanged.
pub fn build_claude_args_with(
    agent_name: &str,
    view_name: &str,
    remote_control: bool,
    session_id: &str,
    resume: bool,
    restrictions: Option<&SessionRestrictions>,
    guard_settings: &str,
) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();
    match restrictions {
        None => {
            // Full permission bypass for daemon-hosted sessions. A headless
            // stream-json session has no way to answer an interactive permission
            // prompt, so the softer `--settings {defaultMode:bypassPermissions}`
            // would dead-end on prompts it still raises (notably compound `a && b`
            // commands). `--dangerously-skip-permissions` skips the checks outright
            // — matching sessions.toml and the in-process TUI views — so agents
            // like Perri can run their gh/compound commands. Scoped to this child
            // process; never touches the operator's global ~/.claude/settings.json.
            args.push("--dangerously-skip-permissions".into());
            // The bypass skips permission checks, not hooks: the guard still
            // vets every tool call.
            args.extend(["--settings".into(), guard_settings.into()]);
            // An approval-capable session (no restrictions, not remote-control)
            // sends its permission prompts to us: the user's own ask rules would
            // otherwise end in a silent, unexplained denial. Whoever answers,
            // answers over stdin (see `crate::approvals::broker`).
            if !remote_control {
                args.extend(["--permission-prompt-tool".into(), "stdio".into()]);
            }
        }
        Some(r) => {
            // No bypass: nothing outside the allow-list can run, and nothing
            // prompts (a headless session could not answer anyway).
            args.extend(["--permission-mode".into(), "dontAsk".into()]);
            // The allow-list decides what may run; the guard still vets each
            // allowed call (an allowed Bash could otherwise reach a prod shell).
            // `--setting-sources project` below doesn't drop it: inline
            // `--settings` always loads.
            args.extend(["--settings".into(), guard_settings.into()]);
            args.extend(["--tools".into(), r.builtin_tools.join(",")]);
            args.extend(["--allowedTools".into(), r.allowed_tools.join(",")]);
            args.push("--strict-mcp-config".into());
            // An unattended run must not execute the operator's code: only the
            // (empty) project's settings load, so no user hooks, CLAUDE.md,
            // plugins, user agents or skills; and no slash commands or skills.
            args.extend(["--setting-sources".into(), "project".into()]);
            args.push("--disable-slash-commands".into());
            if let Some(budget) = r.max_budget_usd {
                args.extend(["--max-budget-usd".into(), format!("{budget}")]);
            }
        }
    }
    args.extend(
        [
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            // Re-emit stdin-origin user messages on stdout (tagged isReplay) so the
            // daemon renders every user message off the output stream.
            "--replay-user-messages",
        ]
        .map(String::from),
    );
    // No name, no `--agent`: a restricted session carries its instructions in its
    // prompt, because a plugin agent's own `tools:` list overrides `--tools` and
    // leaves the session without the tools it needs.
    if is_huey_agent(agent_name) {
        // Huey ships with the repo: its persona is appended to the system prompt
        // (no user-level agent file exists to name with `--agent`).
        args.extend(["--append-system-prompt".into(), crate::huey::PERSONA.into()]);
    } else if !agent_name.is_empty() {
        args.extend(["--agent".into(), agent_name.into()]);
    }
    args.extend(["-n".into(), view_name.into()]);
    if remote_control {
        args.push("--remote-control".into());
        args.push(view_name.into());
    }
    if resume {
        args.push("--resume".into());
        args.push(session_id.into());
    } else {
        args.push("--session-id".into());
        args.push(session_id.into());
    }
    args
}

/// Resolve the `claude` binary: `$NOSTROMO_CLAUDE_BIN`, then common install
/// locations (port of the Swift `findClaude`), then `which`.
pub fn resolve_claude() -> Result<PathBuf> {
    if let Ok(p) = std::env::var(CLAUDE_BIN_ENV) {
        if !p.is_empty() {
            return Ok(PathBuf::from(p));
        }
    }
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let candidates = [
        PathBuf::from("/usr/local/bin/claude"),
        PathBuf::from("/opt/homebrew/bin/claude"),
        home.join(".npm/bin/claude"),
        home.join(".nvm/versions/node/current/bin/claude"),
        home.join(".nvm/versions/node/lts/bin/claude"),
        home.join(".local/bin/claude"),
    ];
    for c in candidates {
        if is_executable(&c) {
            return Ok(c);
        }
    }
    // Last resort: `which claude`.
    if let Ok(out) = Command::new("which").arg("claude").output() {
        if out.status.success() {
            let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !p.is_empty() {
                return Ok(PathBuf::from(p));
            }
        }
    }
    Err(anyhow!(
        "cannot find the `claude` binary (set {CLAUDE_BIN_ENV} or install Claude Code)"
    ))
}

fn is_executable(p: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        p.is_file()
    }
}

/// Augment PATH so `claude` can find its node/helpers (mirror of the Swift env
/// augmentation).
fn augment_path(cmd: &mut Command) {
    let home = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"));
    let extra = [
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/opt/homebrew/bin"),
        home.join(".npm/bin"),
        home.join(".nvm/versions/node/current/bin"),
    ];
    let mut path = std::env::var("PATH").unwrap_or_default();
    for e in extra {
        path.push(':');
        path.push_str(&e.to_string_lossy());
    }
    cmd.env("PATH", path);
}

// ── summary derivation ────────────────────────────────────────────────────────

/// Derive a short display summary from the first user turn's raw text.
///
/// - Collapses newlines and runs of whitespace to a single space.
/// - Returns `None` for empty / whitespace-only input.
/// - Truncates to 40 chars (by `char` count) with a `…` suffix if longer.
fn derive_summary(raw: &str) -> Option<String> {
    // Collapse all whitespace (including newlines) to single spaces, then trim.
    let collapsed: String = raw
        .chars()
        .map(|c| if c.is_whitespace() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    if collapsed.is_empty() {
        return None;
    }

    // Truncate by Unicode scalar count (chars()), not bytes.
    const MAX_CHARS: usize = 40;
    if collapsed.chars().count() > MAX_CHARS {
        let truncated: String = collapsed.chars().take(MAX_CHARS).collect();
        Some(format!("{truncated}\u{2026}")) // U+2026 HORIZONTAL ELLIPSIS
    } else {
        Some(collapsed)
    }
}

// ── session-id store ────────────────────────────────────────────────────────

/// Daemon-owned `tag -> session_id` store path.
///
/// `~/.nostromo/daemon-sessions.json`. Kept separate from the Swift one-shot
/// fallback's `gui-sessions.json`; the Swift thin-client milestone reconciles
/// the two so a feature-flag flip doesn't fork the conversation.
pub fn default_store_path() -> PathBuf {
    dirs_next::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".nostromo")
        .join("daemon-sessions.json")
}

pub(crate) fn load_id_store(path: &std::path::Path) -> HashMap<String, String> {
    std::fs::read(path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// Serializes the read-modify-write of the id store so concurrent session
/// spawns can't clobber each other's entries (the store maps focus tag →
/// claude session_id, used to `--resume` a conversation).
static SAVE_ID_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn save_id(path: &std::path::Path, tag: &str, sid: Option<&str>) {
    // Hold the lock across the whole read-modify-write so two simultaneous
    // spawns serialize instead of racing (one reads stale, the other
    // overwrites and drops the first's entry). Recover from a poisoned lock
    // rather than panicking the daemon.
    let _guard = SAVE_ID_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut map = load_id_store(path);
    match sid {
        Some(s) => {
            map.insert(tag.to_string(), s.to_string());
        }
        None => {
            map.remove(tag);
        }
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(bytes) = serde_json::to_vec_pretty(&map) {
        // Atomic replace: write a sibling temp file, then rename over the
        // store. A crash mid-write leaves the temp file behind, never a
        // truncated/zero-byte store — so a resumable session_id is never
        // silently lost (which would make the next spawn start a fresh
        // conversation with no error). rename(2) within one dir is atomic.
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, &bytes).is_ok() && std::fs::rename(&tmp, path).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn tmp_store() -> PathBuf {
        let mut p = std::env::temp_dir();
        let unique = format!("nostromo-test-{}.json", Uuid::new_v4());
        p.push(unique);
        p
    }

    // ── derive_summary ────────────────────────────────────────────────────────

    #[test]
    fn derive_summary_short_passthrough() {
        assert_eq!(
            derive_summary("Build the auth flow"),
            Some("Build the auth flow".into())
        );
    }

    #[test]
    fn derive_summary_exactly_40_chars_not_truncated() {
        // 40 chars — should pass through unchanged
        let input = "a".repeat(40);
        assert_eq!(derive_summary(&input), Some(input));
    }

    #[test]
    fn derive_summary_41_chars_gets_ellipsis() {
        let input = "a".repeat(41);
        let result = derive_summary(&input).unwrap();
        assert!(
            result.ends_with('\u{2026}'),
            "should end with ellipsis: {result:?}"
        );
        // The truncated part is 40 chars + 1 ellipsis codepoint
        assert_eq!(result.chars().count(), 41);
    }

    #[test]
    fn derive_summary_collapses_newlines() {
        assert_eq!(
            derive_summary("Fix the bug\nin the login\r\nmodule"),
            Some("Fix the bug in the login module".into())
        );
    }

    #[test]
    fn derive_summary_collapses_extra_spaces() {
        assert_eq!(
            derive_summary("  lots   of   spaces  "),
            Some("lots of spaces".into())
        );
    }

    #[test]
    fn derive_summary_empty_returns_none() {
        assert_eq!(derive_summary(""), None);
    }

    #[test]
    fn derive_summary_whitespace_only_returns_none() {
        assert_eq!(derive_summary("   \n\t\r\n   "), None);
    }

    #[test]
    fn derive_summary_empty_str_returns_none() {
        assert_eq!(derive_summary(""), None);
    }

    #[test]
    fn summary_survives_transcript_trimming() {
        use super::super::stream_json::RETAINED_TURNS;

        // Regression guard for RC3: the session summary must not silently
        // change or disappear once old turns get trimmed away by
        // SessionTranscript's retention bound.
        let mut t = SessionTranscript::new();
        let total = RETAINED_TURNS + 50;
        for i in 0..total {
            let text = if i == 0 {
                "first request".to_string()
            } else {
                format!("turn {i}")
            };
            let _ = t.ingest_line(&format!(
                r#"{{"type":"user","message":{{"role":"user","content":"{text}"}},"isReplay":true}}"#
            ));
            let _ = t.ingest_line(
                r#"{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}"#,
            );
        }

        let first_input = t
            .first_user_input()
            .expect("first_user_input must survive trimming past RETAINED_TURNS");
        assert_eq!(
            derive_summary(first_input),
            Some("first request".to_string()),
            "the session summary must not silently change or disappear once old turns are trimmed"
        );
    }

    // ── arg construction ──────────────────────────────────────────────────────

    /// The guard `--settings` JSON for an arbitrary guard path.
    fn guard() -> String {
        crate::approvals::guard::hook_settings_json(Path::new("/opt/x/nostromo-guard"))
    }

    #[test]
    fn args_fresh_session_uses_session_id_flag() {
        let args = build_claude_args("fred", "Fred", false, "sid-1", false, &guard());
        assert!(args.windows(2).any(|w| w == ["--session-id", "sid-1"]));
        assert!(!args.iter().any(|a| a == "--resume"));
        assert!(!args.iter().any(|a| a == "--remote-control"));
        // permission bypass + stream-json + replay always present.
        assert!(args.iter().any(|a| a == "--dangerously-skip-permissions"));
        assert!(args
            .windows(2)
            .any(|w| w == ["--input-format", "stream-json"]));
        assert!(args
            .windows(2)
            .any(|w| w == ["--output-format", "stream-json"]));
        assert!(args.iter().any(|a| a == "--replay-user-messages"));
        assert!(args.windows(2).any(|w| w == ["--agent", "fred"]));
        assert!(args.windows(2).any(|w| w == ["-n", "Fred"]));
    }

    #[test]
    fn args_resume_uses_resume_flag() {
        let args = build_claude_args("teri", "Teri", false, "sid-2", true, &guard());
        assert!(args.windows(2).any(|w| w == ["--resume", "sid-2"]));
        assert!(!args.iter().any(|a| a == "--session-id"));
    }

    // ── restricted sessions ─────────────────────────────────────────────────

    fn restricted() -> SessionRestrictions {
        SessionRestrictions {
            builtin_tools: vec!["ToolSearch".into()],
            allowed_tools: vec![
                "mcp__nostromo__teri_list_work_items".into(),
                "ToolSearch".into(),
            ],
            max_budget_usd: Some(2.0),
            model: None,
        }
    }

    #[test]
    fn the_picks_tag_is_restricted_from_the_start() {
        let mgr = SessionManager::with_store_path(tmp_store());
        assert_eq!(
            mgr.restrictions_for(crate::data::work::picks::PICKS_TAG),
            Some(&crate::data::work::picks::picks_restrictions())
        );
        assert_eq!(mgr.restrictions_for("fred"), None);
    }

    #[test]
    fn restricted_args_carry_the_allow_list_and_no_permission_bypass() {
        let args = build_claude_args_with(
            "teri:teri",
            "Teri picks",
            false,
            "sid",
            false,
            Some(&restricted()),
            &guard(),
        );
        assert!(
            !args.iter().any(|a| a == "--dangerously-skip-permissions"),
            "{args:?}"
        );
        for pair in [
            ["--permission-mode", "dontAsk"],
            ["--tools", "ToolSearch"],
            [
                "--allowedTools",
                "mcp__nostromo__teri_list_work_items,ToolSearch",
            ],
            ["--max-budget-usd", "2"],
        ] {
            assert!(args.windows(2).any(|w| w == pair), "{pair:?} in {args:?}");
        }
        assert!(args.iter().any(|a| a == "--strict-mcp-config"));
        // A named agent is still passed to a restricted session ...
        assert!(args.windows(2).any(|w| w == ["--agent", "teri:teri"]));
        // ... which never loads user settings, hooks, plugins or slash commands.
        assert!(
            args.windows(2)
                .any(|w| w == ["--setting-sources", "project"]),
            "{args:?}"
        );
        assert!(
            args.iter().any(|a| a == "--disable-slash-commands"),
            "{args:?}"
        );
        // The unrestricted vector is unchanged.
        assert_eq!(
            build_claude_args_with("a", "v", false, "sid", false, None, &guard()),
            build_claude_args("a", "v", false, "sid", false, &guard())
        );
    }

    #[test]
    fn a_restricted_session_with_no_agent_name_gets_no_agent_flag() {
        let args = build_claude_args_with(
            "",
            "Teri picks",
            false,
            "sid",
            false,
            Some(&restricted()),
            &guard(),
        );
        assert!(!args.iter().any(|a| a == "--agent"), "{args:?}");
        assert!(!args.iter().any(|a| a.contains("teri:teri")), "{args:?}");
        assert!(
            args.windows(2)
                .any(|w| w == ["--setting-sources", "project"]),
            "{args:?}"
        );
        assert!(
            args.iter().any(|a| a == "--disable-slash-commands"),
            "{args:?}"
        );
        // An unrestricted session with no agent name has no agent flag either, and gains nothing else.
        let plain = build_claude_args_with("", "v", false, "sid", false, None, &guard());
        assert!(
            !plain.iter().any(|a| a == "--agent"
                || a == "--setting-sources"
                || a == "--disable-slash-commands"),
            "{plain:?}"
        );
    }

    #[tokio::test]
    async fn stopping_a_restricted_session_kills_its_children_too() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.restrict_tag("boxed", restricted());
        let pid_file = std::env::temp_dir().join(format!("nostromo-pg-{}", Uuid::new_v4()));
        // The stub starts a long-lived grandchild and waits on it.
        spawn_stub(
            &mut mgr,
            "boxed",
            &format!("sleep 300 & echo $! > {}; wait", pid_file.display()),
        );
        let grandchild = loop {
            if let Some(pid) = std::fs::read_to_string(&pid_file)
                .ok()
                .and_then(|t| t.trim().parse::<i32>().ok())
            {
                break pid;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        };
        // SAFETY: signal 0 only probes for existence.
        let alive = |pid: i32| unsafe { libc::kill(pid, 0) == 0 };
        assert!(alive(grandchild));

        mgr.stop("boxed");

        // Killed by the group signal; a reaped-by-init process disappears shortly after.
        while alive(grandchild) {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let _ = std::fs::remove_file(&pid_file);
    }

    #[test]
    fn args_remote_control_adds_flag() {
        let args = build_claude_args("perri", "Perri", true, "sid-3", false, &guard());
        assert!(args.windows(2).any(|w| w == ["--remote-control", "Perri"]));
    }

    // ── id store ────────────────────────────────────────────────────────────

    #[test]
    fn id_store_round_trips_and_clears() {
        let path = tmp_store();
        save_id(&path, "fred", Some("sid-xyz"));
        assert_eq!(
            load_id_store(&path).get("fred").map(String::as_str),
            Some("sid-xyz")
        );
        save_id(&path, "teri", Some("sid-teri"));
        assert_eq!(load_id_store(&path).len(), 2);
        save_id(&path, "fred", None);
        assert!(!load_id_store(&path).contains_key("fred"));
        assert_eq!(
            load_id_store(&path).get("teri").map(String::as_str),
            Some("sid-teri")
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn id_store_survives_concurrent_writes() {
        // Regression: concurrent spawns must not clobber each other's entries
        // (the read-modify-write is serialized) and the store is never left
        // truncated (atomic temp+rename). Hammer N threads each writing a
        // distinct tag at the same path; all entries must survive.
        let path = tmp_store();
        let n = 24;
        let handles: Vec<_> = (0..n)
            .map(|i| {
                let p = path.clone();
                std::thread::spawn(move || {
                    save_id(&p, &format!("focus-{i}"), Some(&format!("sid-{i}")));
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        let map = load_id_store(&path);
        assert_eq!(map.len(), n, "every concurrent write must be preserved");
        for i in 0..n {
            assert_eq!(
                map.get(&format!("focus-{i}")).map(String::as_str),
                Some(format!("sid-{i}").as_str())
            );
        }
        // No stray temp file left behind.
        assert!(
            !path.with_extension("json.tmp").exists(),
            "temp file must be renamed away"
        );
        let _ = std::fs::remove_file(&path);
    }

    /// The tests that point `CLAUDE_BIN_ENV` somewhere take this: the
    /// variable is process-wide, and one test removing it while another is
    /// about to spawn made that spawn start the real `claude`.
    static CLAUDE_BIN_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn resolve_claude_honours_env_override() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var(CLAUDE_BIN_ENV, "/custom/path/to/claude");
        let p = resolve_claude().unwrap();
        assert_eq!(p, PathBuf::from("/custom/path/to/claude"));
        std::env::remove_var(CLAUDE_BIN_ENV);
    }

    // ── session-id reverse index (activity-path wedge) ────────────────────────
    //
    // `CLAUDE_BIN_ENV` is pointed at `/bin/sh` so `spawn_session` performs a
    // real spawn (exercising the real `effective_id` resolution path) without
    // touching the real `claude` binary. `/bin/sh` chokes on the claude-style
    // flags and exits almost immediately — irrelevant here, since these tests
    // only assert on the reverse index, which is populated synchronously by
    // `spawn_session`/`restart` before the child's behavior matters at all.

    #[tokio::test]
    async fn after_spawn_session_tag_for_session_id_resolves() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var(CLAUDE_BIN_ENV, "/bin/sh");
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let effective_id = mgr
            .spawn_session(
                "cody-1".into(),
                "cody".into(),
                "Cody".into(),
                None,
                None,
                false,
            )
            .unwrap()
            .expect("a fresh session id is always resolved");
        assert_eq!(
            mgr.tag_for_session_id(&effective_id),
            Some("cody-1".to_string())
        );
        std::env::remove_var(CLAUDE_BIN_ENV);
    }

    #[tokio::test]
    async fn after_restart_tag_for_session_id_still_resolves() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var(CLAUDE_BIN_ENV, "/bin/sh");
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let effective_id = mgr
            .spawn_session(
                "cody-2".into(),
                "cody".into(),
                "Cody".into(),
                None,
                None,
                false,
            )
            .unwrap()
            .expect("a fresh session id is always resolved");

        mgr.restart("cody-2").unwrap();

        assert_eq!(
            mgr.tag_for_session_id(&effective_id),
            Some("cody-2".to_string()),
            "restart must keep the reverse index resolvable for the (possibly reused) session id"
        );
        std::env::remove_var(CLAUDE_BIN_ENV);
    }

    /// A stand-in `claude` that writes the identity variables it was started
    /// with to `out` and exits.
    fn env_probe_claude(dir: &Path, out: &Path) {
        use std::os::unix::fs::PermissionsExt;
        let script = dir.join("claude-probe");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\nprintf '%s|%s|%s' \"$NOSTROMO_FOCUS_TAG\" \"$MOTHER_ORIGIN_SESSION\" \"$NOSTROMO_PTY_ID\" > '{}'\n",
                out.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var(CLAUDE_BIN_ENV, &script);
    }

    /// Wait (condition, not clock) until the probe has written its line. A
    /// stub that never writes fails the test after 30 s instead of hanging it.
    fn probe_output(out: &Path) -> String {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        loop {
            if let Ok(text) = std::fs::read_to_string(out) {
                if !text.is_empty() {
                    return text;
                }
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the stub claude never wrote {} within 30 s",
                out.display()
            );
            std::thread::yield_now();
        }
    }

    /// Puts `CLAUDE_BIN_ENV` back (unset) when a test ends, passed or not.
    struct ClaudeBinGuard;

    impl Drop for ClaudeBinGuard {
        fn drop(&mut self) {
            std::env::remove_var(CLAUDE_BIN_ENV);
        }
    }

    #[tokio::test]
    async fn a_session_with_the_mcp_bridge_gets_the_session_id_it_was_spawned_with() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("env.out");
        env_probe_claude(dir.path(), &out);
        let mut mgr = SessionManager::with_store_path(dir.path().join("daemon-sessions.json"));
        mgr.configure_mcp_bridge(
            Arc::new(Mutex::new(PaneRegistry::with_store_path(
                dir.path().join("panes.json"),
            ))),
            dir.path().join("mcp.sock"),
            dir.path().join("mcp.json"),
        );
        let sid = mgr
            .spawn_session(
                "cody-env".into(),
                "cody".into(),
                "Cody".into(),
                None,
                Some("sid-for-the-env-test".into()),
                false,
            )
            .unwrap()
            .expect("the session id it spawned with");
        assert_eq!(sid, "sid-for-the-env-test");

        let seen = probe_output(&out);
        std::env::remove_var(CLAUDE_BIN_ENV);
        assert_eq!(seen, "cody-env|sid-for-the-env-test|cody-env");
    }

    #[tokio::test]
    async fn a_fresh_session_gets_the_id_the_daemon_minted_and_spawn_session_returns_it() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _restore = ClaudeBinGuard;
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("env.out");
        env_probe_claude(dir.path(), &out);
        let mut mgr = SessionManager::with_store_path(dir.path().join("daemon-sessions.json"));
        mgr.configure_mcp_bridge(
            Arc::new(Mutex::new(PaneRegistry::with_store_path(
                dir.path().join("panes.json"),
            ))),
            dir.path().join("mcp.sock"),
            dir.path().join("mcp.json"),
        );

        // No id given and none stored: the daemon mints one.
        let sid = mgr
            .spawn_session(
                "cody-fresh".into(),
                "cody".into(),
                "Cody".into(),
                None,
                None,
                false,
            )
            .unwrap()
            .expect("the minted session id");

        assert_eq!(sid.len(), 36, "a freshly minted uuid: {sid}");
        assert_eq!(
            probe_output(&out),
            format!("cody-fresh|{sid}|cody-fresh"),
            "the session is told exactly the id spawn_session returned"
        );
        assert!(
            mgr.session_history().contains("cody-fresh", &sid),
            "and the history vouches for it"
        );
    }

    #[tokio::test]
    async fn a_resumed_session_gets_the_id_from_the_daemons_store_and_spawn_session_returns_it() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let _restore = ClaudeBinGuard;
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("env.out");
        env_probe_claude(dir.path(), &out);
        let store = dir.path().join("daemon-sessions.json");
        let mut mgr = SessionManager::with_store_path(store.clone());
        mgr.configure_mcp_bridge(
            Arc::new(Mutex::new(PaneRegistry::with_store_path(
                dir.path().join("panes.json"),
            ))),
            dir.path().join("mcp.sock"),
            dir.path().join("mcp.json"),
        );
        // The focus ran before: its session id is in the daemon's store.
        save_id(&store, "cody-resume", Some("sid-from-the-store"));

        let sid = mgr
            .spawn_session(
                "cody-resume".into(),
                "cody".into(),
                "Cody".into(),
                None,
                None,
                false,
            )
            .unwrap()
            .expect("the stored session id");

        assert_eq!(sid, "sid-from-the-store", "a resume returns the stored id");
        assert_eq!(
            probe_output(&out),
            "cody-resume|sid-from-the-store|cody-resume",
            "the resumed session is told the id it resumes"
        );
        assert!(mgr
            .session_history()
            .contains("cody-resume", "sid-from-the-store"));
    }

    #[tokio::test]
    async fn a_session_without_the_mcp_bridge_gets_no_origin_session() {
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("env.out");
        env_probe_claude(dir.path(), &out);
        let mut mgr = SessionManager::with_store_path(dir.path().join("daemon-sessions.json"));
        mgr.spawn_session(
            "cody-nobridge".into(),
            "cody".into(),
            "Cody".into(),
            None,
            Some("sid-nobridge".into()),
            false,
        )
        .unwrap();

        let seen = probe_output(&out);
        std::env::remove_var(CLAUDE_BIN_ENV);
        assert_eq!(
            seen, "||",
            "identity variables are set only with the bridge"
        );
    }

    #[tokio::test]
    async fn every_spawned_session_id_is_kept_in_the_tags_history_beside_the_store() {
        use std::os::unix::fs::PermissionsExt;
        let _env = CLAUDE_BIN_ENV_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        std::env::set_var(CLAUDE_BIN_ENV, "/bin/sh");
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = SessionManager::with_store_path(dir.path().join("daemon-sessions.json"));
        let first = mgr
            .spawn_session(
                "cody-h".into(),
                "cody".into(),
                "Cody".into(),
                None,
                None,
                false,
            )
            .unwrap()
            .expect("a fresh session id");
        mgr.stop("cody-h");
        let second = mgr
            .spawn_session(
                "cody-h".into(),
                "cody".into(),
                "Cody".into(),
                None,
                Some("an-explicit-second-session".into()),
                false,
            )
            .unwrap()
            .expect("the explicit session id");
        std::env::remove_var(CLAUDE_BIN_ENV);

        let history = mgr.session_history();
        assert!(history.contains("cody-h", &first) && history.contains("cody-h", &second));
        assert!(
            !history.contains("another-focus", &first),
            "a session belongs to its own tag"
        );
        let file = dir.path().join("focus-session-history.json");
        assert_eq!(
            std::fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let reopened = SessionHistory::open(file);
        assert!(reopened.contains("cody-h", &first) && reopened.contains("cody-h", &second));
    }

    #[test]
    fn origin_caller_knows_only_a_registered_or_running_focus() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert_eq!(mgr.origin_caller("claudia-1"), None);
        assert_eq!(mgr.origin_caller(""), None);
        let mut meta = focus("claudia-1");
        meta.display_name = "Claudia: Mother v2".into();
        mgr.add_or_update_focus(meta);
        save_id(&mgr.store_path.clone(), "claudia-1", Some("sid-claudia"));
        let caller = mgr.origin_caller("claudia-1").expect("a registered focus");
        assert_eq!(caller.name.as_deref(), Some("Claudia: Mother v2"));
        assert_eq!(caller.session.as_deref(), Some("sid-claudia"));
        assert_eq!(mgr.origin_caller("claudia-2"), None);
    }

    #[test]
    fn seed_reverse_index_populates_from_on_disk_store() {
        let path = tmp_store();
        save_id(&path, "fred", Some("sid-fred"));
        save_id(&path, "teri", Some("sid-teri"));

        let mut mgr = SessionManager::with_store_path(path.clone());
        assert_eq!(
            mgr.tag_for_session_id("sid-fred"),
            None,
            "the reverse index must not be populated before seeding"
        );

        mgr.seed_reverse_index();

        assert_eq!(mgr.tag_for_session_id("sid-fred"), Some("fred".to_string()));
        assert_eq!(mgr.tag_for_session_id("sid-teri"), Some("teri".to_string()));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn tag_for_session_id_returns_none_for_unknown_id() {
        let mgr = SessionManager::with_store_path(tmp_store());
        assert_eq!(mgr.tag_for_session_id("no-such-session-id"), None);
    }

    // ── activity attribution resolution (activity-path wedge D2) ──────────────

    fn raw_activity_event(
        focus_tag: Option<&str>,
        session_id: Option<&str>,
    ) -> crate::agent_bus::ActivityEvent {
        crate::agent_bus::ActivityEvent {
            ts: chrono::Utc::now(),
            agent: "claude".into(),
            kind: "tool_use".into(),
            summary: "reading a file".into(),
            focus_tag: focus_tag.map(str::to_string),
            session_id: session_id.map(str::to_string),
            agent_id: None,
            agent_type: None,
            parent_agent_id: None,
            tool_name: None,
            tool_use_id: None,
            cwd: None,
            seq: None,
        }
    }

    // ── W7 — D8: which focuses have departed ─────────────────────────────────
    //
    // Eviction is irreversible and this runs on every reconnect, so these
    // guard the two ways a naive diff destroys live state.

    fn focus(tag: &str) -> FocusMeta {
        FocusMeta {
            initial_model: None,
            initial_effort: None,
            tag: tag.into(),
            display_name: tag.into(),
            agent_name: tag.into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: None,
            label: None,
            project_path: None,
            select_for_client: None,
        }
    }

    #[test]
    fn a_tag_absent_from_two_consecutive_pushes_is_reported_departed() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            departed.is_empty(),
            "one push is not enough to conclude a focus is gone"
        );

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert_eq!(departed, vec!["cody".to_string()]);
    }

    #[test]
    fn a_tag_that_comes_back_before_the_second_push_is_never_departed() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);

        // A partial push — the shape a reconnecting client sends before it has
        // finished loading.
        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(departed.is_empty());

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        assert!(
            departed.is_empty(),
            "a focus that reappears must not be evicted"
        );

        // ...and the pending departure is genuinely cleared, not merely
        // deferred: a later push that still has it must stay silent.
        let (_, departed) = mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        assert!(departed.is_empty());
    }

    /// D8a. `set_focus_registry` runs on every reconnect, and an empty push is
    /// what a client sends before it has loaded anything — never a claim that
    /// every focus was deleted.
    #[test]
    fn an_empty_push_evicts_nothing() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);

        let (_, departed) = mgr.set_focus_registry(vec![]);
        assert!(departed.is_empty(), "an empty push must evict nothing");

        // And it must not have armed a departure that the next push confirms.
        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            departed.is_empty(),
            "an empty push must not arm a departure either"
        );
    }

    /// D8b, first half. A focus the Mac has never carried is absent from every
    /// push for the boring reason that the Mac has never heard of it, not
    /// because it was removed. Reading that absence as a removal would delete a
    /// live agent-created focus's state moments after `create_focus` made it.
    #[test]
    fn a_daemon_created_focus_the_mac_has_never_pushed_is_never_evicted() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.add_or_update_focus(focus("cody-core-1234"));

        for _ in 0..3 {
            let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
            assert!(
                departed.is_empty(),
                "a focus the Mac has never acknowledged cannot be evicted by its \
                 silence — that silence is all the Mac has ever said about it"
            );
        }
        assert!(mgr.is_daemon_created("cody-core-1234"));
    }

    /// D8b, second half — and the bug. The exemption's job is to cover the
    /// window between `create_focus` and the Mac's first acknowledging push.
    /// Once the Mac *has* pushed the tag, its silence afterwards means what it
    /// means for every other focus, and the ordinary two-push rule governs it.
    ///
    /// A permanent exemption is not a safe conservative default here: an
    /// agent-created tag is derived deterministically from `(agent, title)`, so
    /// it is the tag most certain to be reused, and a focus that can never
    /// depart can never have its PR pin evicted.
    #[test]
    fn a_daemon_created_focus_the_mac_has_acknowledged_departs_like_any_other() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.add_or_update_focus(focus("cody-core-1234"));

        // The Mac has learned of it (it received `FocusCreated`) and now
        // carries it.
        let (_, departed) = mgr.set_focus_registry(vec![focus("perri"), focus("cody-core-1234")]);
        assert!(
            departed.is_empty(),
            "a push that carries a focus says nothing about it departing"
        );

        // Closed on the Mac. One push is still not enough — that is what a
        // reconnect looks like, and eviction is irreversible.
        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            departed.is_empty(),
            "one omitting push is indistinguishable from a partial push during a \
             reconnect, whoever created the focus"
        );

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert_eq!(
            departed,
            vec!["cody-core-1234".to_string()],
            "once the Mac has acknowledged an agent-created focus, two consecutive \
             pushes omitting it are a removal; while they are not, the focus's PR \
             pin outlives it and the next create_focus under the same derived tag \
             inherits it"
        );

        assert!(
            !mgr.live_focus_tags()
                .expect("a registry has been pushed")
                .contains("cody-core-1234"),
            "a departed focus must stop counting as live, or the retain_pins \
             backstop is handed a live set that still vouches for its pin"
        );
    }

    /// The reconnect guard (D8a) applies to a now-unexempt agent-created focus
    /// exactly as it does to a Mac-created one: an empty push carries no
    /// information about what still exists, and must neither evict nor arm.
    #[test]
    fn an_empty_push_never_evicts_an_acknowledged_daemon_created_focus() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.add_or_update_focus(focus("cody-core-1234"));
        mgr.set_focus_registry(vec![focus("perri"), focus("cody-core-1234")]);

        let (_, departed) = mgr.set_focus_registry(vec![]);
        assert!(
            departed.is_empty(),
            "an empty push is what a client sends before it has loaded anything, \
             never a claim that every focus was deleted"
        );

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            departed.is_empty(),
            "and it must not have armed a departure for the next push to confirm"
        );
    }

    /// The same D8a guarantee, asked of the *backstop* rather than the
    /// departure loop. `retain_pins` deletes every pin outside the set it is
    /// handed, so the daemon must only answer this question while it can
    /// vouch for a complete picture of what exists.
    ///
    /// An empty push throws that picture away — it replaces the registry with
    /// nothing and clears the pending departures — so afterwards the only tag
    /// the daemon can still name is an unacknowledged daemon-created one.
    /// Reconciling against *that* hands the backstop a one-tag "live" set and
    /// deletes every Mac-created focus's pin, which is the reconnect hazard
    /// the two-push rule exists to prevent.
    #[test]
    fn an_empty_push_leaves_nothing_reconcilable_even_after_two_agreeing_pushes() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        assert!(
            mgr.reconcilable_focus_tags().is_some(),
            "two agreeing non-empty pushes are the evidence standard the \
             backstop is allowed to act on"
        );

        // An agent creates a focus; the client has not acknowledged it yet, so
        // its eviction exemption is still live.
        mgr.add_or_update_focus(focus("cody-core-1234"));

        // The client reconnects and pushes before it has loaded anything.
        mgr.set_focus_registry(vec![]);

        assert_eq!(
            mgr.reconcilable_focus_tags(),
            None,
            "an empty push discards every record of which tags exist, so the \
             daemon can no longer vouch for a complete picture; answering \
             otherwise reconciles every pin on disk against the daemon-created \
             tag alone"
        );
    }

    /// ...and the withdrawal is temporary, not a one-way latch: an empty push
    /// puts the daemon back where it was before any client had spoken, so it
    /// re-earns the right to reconcile the same way it earned it the first
    /// time — one push is a partial push until a second agrees.
    #[test]
    fn the_backstop_re_arms_once_the_client_has_pushed_twice_again() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_registry(vec![]);

        mgr.set_focus_registry(vec![focus("perri")]);
        assert_eq!(
            mgr.reconcilable_focus_tags(),
            None,
            "the first push after a reconnect may be a partial one, and there \
             is no previous registry left to notice the omission against"
        );

        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        let tags = mgr
            .reconcilable_focus_tags()
            .expect("two agreeing pushes restore the daemon's picture");
        assert!(tags.contains("perri"));
        assert!(
            tags.contains("cody"),
            "and the restored picture is the client's, not a stale fragment"
        );
    }

    /// The backstop must not be able to destroy something the primary path
    /// would have spared. A tag omitted by a single push is a *pending*
    /// departure, not a departure: the eviction hook reports nothing and
    /// spares its pin until a second push agrees. Reconciling against
    /// `live_focus_tags` alone would hand `retain_pins` a set that no longer
    /// names it, and the backstop would delete that focus's in-progress
    /// review a full push early — D8a's guarantee inverted.
    #[test]
    fn a_focus_pending_departure_is_still_reconcilable_as_live() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            departed.is_empty(),
            "one omitting push is not enough for the primary path to evict"
        );

        let tags = mgr
            .reconcilable_focus_tags()
            .expect("two agreeing non-empty pushes have landed");
        assert!(
            tags.contains("cody"),
            "a tag the primary path is still sparing must count as live for the \
             backstop too, or retain_pins collects its pin a push before the \
             eviction hook would have"
        );
        assert!(tags.contains("perri"));
    }

    #[test]
    fn live_focus_tags_unions_daemon_creations_over_the_pushed_registry() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert_eq!(
            mgr.live_focus_tags(),
            None,
            "before any push the daemon does not know which focuses exist, \
             which is not the same as knowing none do"
        );

        mgr.add_or_update_focus(focus("cody-core-1234"));
        mgr.set_focus_registry(vec![focus("perri")]);

        let live = mgr.live_focus_tags().expect("a pushed registry is known");
        assert!(live.contains("perri"));
        assert!(
            live.contains("cody-core-1234"),
            "set_focus_registry replaces the registry with the Mac's view, so a \
             daemon-created focus must be unioned back in or it reads as gone"
        );
    }

    // ── restart safety: when may the daemon vouch for the registry? ──────────
    //
    // After a daemon restart the registry is empty and no session exists, so
    // "this tag is not registered" means nothing until the Mac has reported
    // twice. These guard the dedupe / prune decisions built on that.

    #[test]
    fn the_registry_is_not_known_until_two_non_empty_pushes_have_landed() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert!(
            !mgr.registry_known(),
            "a fresh daemon has been told nothing"
        );

        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            !mgr.registry_known(),
            "one push may be a partial push from a client still loading"
        );

        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            mgr.registry_known(),
            "two non-empty pushes are enough evidence"
        );
    }

    #[test]
    fn an_empty_push_makes_the_registry_unknown_again_until_two_more_arrive() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri")]);
        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(mgr.registry_known());

        // An empty push is indistinguishable from a client that has not loaded
        // yet: it is "no information", not "no focuses".
        mgr.set_focus_registry(vec![]);
        assert!(!mgr.registry_known());

        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            !mgr.registry_known(),
            "the evidence standard starts over after an empty push"
        );
        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(mgr.registry_known());
    }

    #[test]
    fn any_focus_may_exist_while_the_registry_is_unknown() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert!(mgr.focus_may_exist("never-heard-of-it"));

        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(
            mgr.focus_may_exist("never-heard-of-it"),
            "one push still cannot vouch for what is absent"
        );
    }

    #[test]
    fn once_the_registry_is_known_only_registered_or_pending_departure_tags_may_exist() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        assert!(mgr.registry_known());

        assert!(mgr.focus_may_exist("perri"));
        assert!(mgr.focus_may_exist("cody"));
        assert!(
            !mgr.focus_may_exist("stranger"),
            "a known registry that lacks the tag is a statement that it is gone"
        );

        // A tag omitted by one push is spared until a second push agrees.
        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(mgr.registry_known());
        assert!(
            mgr.focus_may_exist("cody"),
            "a pending departure may still exist"
        );

        // ...and once the second omission lands it is gone.
        mgr.set_focus_registry(vec![focus("perri")]);
        assert!(!mgr.focus_may_exist("cody"));
        assert!(mgr.focus_may_exist("perri"));
    }

    #[test]
    fn a_departed_tag_loses_its_nonce_while_a_still_pushed_tag_keeps_it() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![focus("perri"), focus("cody")]);
        mgr.set_focus_nonce("perri", "nonce-perri".into());
        mgr.set_focus_nonce("cody", "nonce-cody".into());

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert!(departed.is_empty());
        assert_eq!(
            mgr.focus_nonce("cody"),
            Some("nonce-cody"),
            "a pending departure has not departed; its nonce stays"
        );

        let (_, departed) = mgr.set_focus_registry(vec![focus("perri")]);
        assert_eq!(departed, vec!["cody".to_string()]);
        assert_eq!(
            mgr.focus_nonce("cody"),
            None,
            "a departed focus's nonce must not outlive it, or a later focus \
             reusing the tag would match a stale marker"
        );
        assert_eq!(mgr.focus_nonce("perri"), Some("nonce-perri"));
    }

    #[test]
    fn an_event_with_a_focus_tag_the_daemon_knows_is_attributed_to_that_focus() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.set_focus_registry(vec![FocusMeta {
            initial_model: None,
            initial_effort: None,
            tag: "fred".into(),
            display_name: "Fred".into(),
            agent_name: "fred".into(),
            project_name: None,
            org: None,
            is_built_in: true,
            session_summary: None,
            label: None,
            project_path: None,
            select_for_client: None,
        }]);

        let finalized = mgr.ingest_activity_event(raw_activity_event(Some("fred"), None));
        assert_eq!(finalized.focus_tag.as_deref(), Some("fred"));
        assert_eq!(
            finalized.seq,
            Some(0),
            "an attributed event must be seq-assigned"
        );
        assert_eq!(mgr.activity_streams_for_focus("fred").len(), 1);
    }

    #[test]
    fn an_unknown_focus_tag_falls_back_to_the_session_id_reverse_index() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.session_reverse.insert("sess-1".into(), "cody-1".into());

        // "cody-1" is not in the registry/sessions map, but the session id
        // resolves via the reverse index — the fallback must still find it.
        let finalized =
            mgr.ingest_activity_event(raw_activity_event(Some("cody-1"), Some("sess-1")));
        assert_eq!(
            mgr.activity_streams_for_focus("cody-1").len(),
            1,
            "{finalized:?}"
        );
    }

    #[test]
    fn an_event_with_no_resolvable_focus_or_session_is_unattributed_not_dropped() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.ingest_activity_event(raw_activity_event(None, None));
        // Never silently dropped, and never assigned to an arbitrary focus.
        assert!(mgr.activity_streams_for_focus("mother").is_empty());
        assert!(mgr.activity_health().ingesting);
    }

    #[test]
    fn the_first_ingested_event_reports_that_ingestion_just_began() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert!(!mgr.activity_health().ingesting);

        let (_, became) =
            mgr.ingest_activity_event_reporting(raw_activity_event(Some("fred"), None));

        assert!(
            became,
            "the event that flips health from quiet to ingesting must say so"
        );
        assert!(mgr.activity_health().ingesting);
    }

    #[test]
    fn later_events_do_not_report_a_transition_again() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        mgr.ingest_activity_event_reporting(raw_activity_event(Some("fred"), None));

        let (_, became) =
            mgr.ingest_activity_event_reporting(raw_activity_event(Some("fred"), None));

        assert!(
            !became,
            "only the first event is a transition; the rest must not re-broadcast health"
        );
    }

    // ── manager mechanics with a stub child ───────────────────────────────────
    //
    // These tests drive the reader → transcript → broadcast → exit path with a
    // stub `sh -c` program emitting canned stream-json, so they exercise the
    // real process/pipe/thread machinery without `claude` or the network.

    /// Spawn a stub session that prints `script` to stdout then exits. The
    /// fixed program (`/bin/sh -c <script>`) is also recorded as the respawn
    /// spec so an auto-restart re-runs the stub rather than the real `claude`.
    fn spawn_stub(mgr: &mut SessionManager, tag: &str, script: &str) {
        let program = PathBuf::from("/bin/sh");
        let args = vec!["-c".to_string(), script.to_string()];
        let managed = mgr
            .spawn_managed(
                tag.to_string(),
                "agent".into(),
                "View".into(),
                None,
                false,
                "stub-sid".into(),
                false,
                program.clone(),
                args.clone(),
                Some((program, args)),
            )
            .expect("spawn stub");
        mgr.sessions.insert(tag.to_string(), managed);
    }

    async fn collect_events(
        rx: &mut broadcast::Receiver<SessionEvent>,
        max: usize,
    ) -> Vec<SessionEvent> {
        let mut out = vec![];
        for _ in 0..max {
            match tokio::time::timeout(Duration::from_secs(5), rx.recv()).await {
                Ok(Ok(ev)) => {
                    let done = matches!(ev, SessionEvent::Exited { .. });
                    out.push(ev);
                    if done {
                        break;
                    }
                }
                _ => break,
            }
        }
        out
    }

    #[tokio::test]
    async fn stub_session_streams_turn_then_exits() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // One turn: replayed user message + assistant text + result, then EOF.
        let script = r#"printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"},"isReplay":true}' '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'"#;
        let mut rx = {
            spawn_stub(&mut mgr, "fred", script);
            mgr.sessions
                .get("fred")
                .unwrap()
                .shared
                .event_tx
                .subscribe()
        };

        let events = collect_events(&mut rx, 20).await;

        // Must see a TurnStarted, a BlockAppended(text), a TurnCompleted, and Exited.
        let has_started = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Delta(TurnDelta::TurnStarted { .. })));
        let has_completed = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Delta(TurnDelta::TurnCompleted { .. })));
        let has_exit = events
            .iter()
            .any(|e| matches!(e, SessionEvent::Exited { .. }));
        assert!(has_started, "expected TurnStarted: {events:?}");
        assert!(has_completed, "expected TurnCompleted: {events:?}");
        assert!(has_exit, "expected Exited: {events:?}");

        // The transcript holds one completed turn.
        let turns = mgr
            .sessions
            .get("fred")
            .unwrap()
            .shared
            .transcript
            .lock()
            .unwrap()
            .snapshot();
        assert_eq!(turns.len(), 1);
        assert!(turns[0].is_complete);
        assert_eq!(turns[0].user_input, "hi");
    }

    #[tokio::test]
    async fn a_spawned_session_stamps_calls_with_receive_time_but_keeps_line_times() {
        // The CLI's live `assistant` lines carry no timestamp; its `user`
        // lines do. (A resumed session's scrollback is a replay and never
        // gets invented times; that is covered on `transcript_from_jsonl`,
        // since the scrollback location is not injectable here.)
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let script = r#"printf '%s\n' '{"type":"user","message":{"role":"user","content":"ls"},"isReplay":true}' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_live","name":"Bash","input":{"command":"ls"}}]}}' '{"type":"user","message":{"content":[{"type":"tool_result","content":"a","is_error":false,"tool_use_id":"toolu_live"}]},"timestamp":"2026-06-01T10:00:05.000Z"}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'"#;
        let before = chrono::Utc::now();
        let mut rx = {
            spawn_stub(&mut mgr, "fred", script);
            mgr.sessions
                .get("fred")
                .unwrap()
                .shared
                .event_tx
                .subscribe()
        };
        collect_events(&mut rx, 20).await;
        let after = chrono::Utc::now();

        let transcript = mgr
            .sessions
            .get("fred")
            .unwrap()
            .shared
            .transcript
            .lock()
            .unwrap();
        assert!(
            transcript.is_live(),
            "a spawned session's transcript is live"
        );
        let blocks = &transcript.snapshot()[0].blocks;
        let (call_ts, result_ts) = match (&blocks[0], &blocks[1]) {
            (
                crate::ipc::stream_json::TurnBlock::ToolCall {
                    ts: c,
                    tool_use_id: Some(id),
                    ..
                },
                crate::ipc::stream_json::TurnBlock::ToolResult { ts: r, .. },
            ) if id == "toolu_live" => (*c, *r),
            other => panic!("expected call then result, got {other:?}"),
        };
        let call_ts = call_ts.expect("a live call with no line timestamp is stamped");
        assert!(
            before <= call_ts && call_ts <= after,
            "{call_ts} not within {before}..{after}"
        );
        assert_eq!(
            result_ts,
            Some(
                chrono::DateTime::parse_from_rfc3339("2026-06-01T10:00:05.000Z")
                    .unwrap()
                    .with_timezone(&chrono::Utc)
            )
        );
    }

    // ── interrupt (the Stop button) ───────────────────────────────────────────

    /// A stub child that appends everything it reads on stdin to `out`, so a
    /// test can see exactly which frames the manager wrote.
    fn recording_stub(out: &std::path::Path) -> String {
        format!("cat >> '{}'", out.display())
    }

    #[tokio::test]
    async fn interrupt_writes_the_control_request_and_drops_queued_messages() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        spawn_stub(&mut mgr, "perri", &recording_stub(&out));

        mgr.send_user_message("perri", "first", &[]).unwrap(); // goes to the child; session is now mid-turn
        mgr.send_user_message("perri", "queued behind it", &[])
            .unwrap(); // queued
        assert_eq!(
            mgr.sessions["perri"].shared.pending.lock().unwrap().len(),
            1
        );

        let outcome = mgr.interrupt("perri").unwrap();

        assert_eq!(outcome, InterruptOutcome::Requested);
        assert!(
            mgr.sessions["perri"]
                .shared
                .pending
                .lock()
                .unwrap()
                .is_empty(),
            "Stop means stop: a queued message must not start the moment the turn ends"
        );
        tokio::time::sleep(Duration::from_millis(400)).await;
        let written = std::fs::read_to_string(&out).unwrap();
        let frame: serde_json::Value = written
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .find(|v| v["type"] == "control_request")
            .expect("a control_request frame must have been written to the child's stdin");
        assert_eq!(frame["request"]["subtype"], "interrupt");
        assert!(frame["request_id"]
            .as_str()
            .unwrap()
            .starts_with("interrupt-"));
        assert!(
            !written.contains("queued behind it"),
            "the queued message must never reach the child"
        );
        // The stub never exits on its own; stop it so its reader thread ends
        // and the runtime can shut down.
        mgr.stop("perri");
    }

    #[tokio::test]
    async fn interrupt_on_an_idle_session_is_a_no_op_that_writes_nothing() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        spawn_stub(&mut mgr, "perri", &recording_stub(&out));

        let outcome = mgr.interrupt("perri").unwrap();

        assert_eq!(outcome, InterruptOutcome::NotRunning);
        tokio::time::sleep(Duration::from_millis(300)).await;
        let written = std::fs::read_to_string(&out).unwrap_or_default();
        assert!(
            !written.contains("control_request"),
            "nothing to interrupt, nothing to send: {written:?}"
        );
        mgr.stop("perri");
    }

    #[test]
    fn interrupting_an_unknown_session_is_an_error() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        assert!(mgr.interrupt("nobody").is_err());
    }

    #[tokio::test]
    async fn attach_delivers_snapshot_then_state() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let script = r#"printf '%s\n' '{"type":"user","message":{"role":"user","content":"q"},"isReplay":true}' '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}'; sleep 1"#;
        spawn_stub(&mut mgr, "teri", script);

        // Register a client sender, then attach.
        let (tx, mut crx) = mpsc::unbounded_channel::<ServerMsg>();
        mgr.client_senders.lock().unwrap().insert("c1".into(), tx);

        // Give the reader a moment to process the first turn.
        tokio::time::sleep(Duration::from_millis(300)).await;
        mgr.attach("teri", "c1").unwrap();

        // First two targeted messages must be SessionTurns then SessionState.
        let m1 = tokio::time::timeout(Duration::from_secs(2), crx.recv())
            .await
            .unwrap()
            .unwrap();
        let m2 = tokio::time::timeout(Duration::from_secs(2), crx.recv())
            .await
            .unwrap()
            .unwrap();
        assert!(
            matches!(m1, ServerMsg::SessionTurns { .. }),
            "first msg {m1:?}"
        );
        assert!(
            matches!(m2, ServerMsg::SessionState { .. }),
            "second msg {m2:?}"
        );
    }

    #[tokio::test]
    async fn attach_truncates_snapshot_to_scrollback_cap() {
        // A session that's accumulated more live turns than SCROLLBACK_TURNS
        // (simulating a long-lived, busy session that never crashed/respawned,
        // so load_scrollback's own cap never re-applied) must still only ever
        // send the last SCROLLBACK_TURNS turns to a freshly attaching client.
        let mut mgr = SessionManager::with_store_path(tmp_store());
        let mut script = String::new();
        for i in 0..(SCROLLBACK_TURNS + 10) {
            script.push_str(&format!(
                r#"printf '%s\n' '{{"type":"user","message":{{"role":"user","content":"q{i}"}},"isReplay":true}}' '{{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"total_cost_usd":0.0}}';"#
            ));
        }
        script.push_str(" sleep 1");
        spawn_stub(&mut mgr, "teri", &script);

        let (tx, mut crx) = mpsc::unbounded_channel::<ServerMsg>();
        mgr.client_senders.lock().unwrap().insert("c1".into(), tx);

        // Give the reader time to process every synthetic turn.
        tokio::time::sleep(Duration::from_millis(800)).await;
        mgr.attach("teri", "c1").unwrap();

        let m1 = tokio::time::timeout(Duration::from_secs(2), crx.recv())
            .await
            .unwrap()
            .unwrap();
        match m1 {
            ServerMsg::SessionTurns { turns, .. } => {
                assert_eq!(
                    turns.len(),
                    SCROLLBACK_TURNS,
                    "attach must cap the snapshot even though the live transcript has more"
                );
                // Must keep the MOST RECENT turns, not the oldest.
                let last = turns.last().unwrap();
                assert!(
                    last.user_input
                        .contains(&(SCROLLBACK_TURNS + 9).to_string()),
                    "expected the newest turn to survive truncation, got {:?}",
                    last.user_input
                );
            }
            other => panic!("expected SessionTurns, got {other:?}"),
        }
    }

    // ── backoff and crash-loop guard tests ───────────────────────────────────

    #[test]
    fn backoff_delay_is_exponential_and_capped() {
        assert_eq!(backoff_delay(1), Duration::from_secs(1));
        assert_eq!(backoff_delay(2), Duration::from_secs(2));
        assert_eq!(backoff_delay(3), Duration::from_secs(4));
        // Large count saturates at BACKOFF_MAX_SECS.
        assert_eq!(backoff_delay(50), Duration::from_secs(BACKOFF_MAX_SECS));
    }

    #[tokio::test]
    async fn nonzero_exit_schedules_backoff_before_restart() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // exit 1 → non-zero exit → should schedule backoff, not restart immediately.
        spawn_stub(&mut mgr, "crashy1", "exit 1");
        mgr.sessions
            .get_mut("crashy1")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // First reap: should record the crash and schedule backoff.
        mgr.reap_and_recover();

        let s = mgr.sessions.get("crashy1").expect("session still tracked");
        // Backoff must be scheduled (restart_at is Some).
        assert!(
            s.restart_at.is_some(),
            "non-zero exit should schedule a backoff deadline"
        );
        // Exactly one crash in the sliding window.
        assert_eq!(
            s.crash_times.len(),
            1,
            "one crash should be recorded in sliding window"
        );
        // Child was NOT restarted yet (exited flag still true — no new child spawned).
        assert!(
            s.shared.exited.load(Ordering::SeqCst),
            "session should remain crashed (not restarted) during backoff"
        );
    }

    #[tokio::test]
    async fn zero_exit_restarts_immediately() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // exit 0 → clean shutdown → should restart immediately, no backoff.
        spawn_stub(&mut mgr, "clean", "exit 0");
        mgr.sessions
            .get_mut("clean")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // First reap: should restart immediately (no backoff for clean exit).
        mgr.reap_and_recover();

        let s = mgr.sessions.get("clean").expect("session still tracked");
        // No backoff should be scheduled.
        assert!(
            s.restart_at.is_none(),
            "clean exit should not schedule backoff"
        );
        // Crash window carries one entry (from the first crash, preserved across restart).
        assert_eq!(
            s.crash_times.len(),
            1,
            "crash window should survive restart with one entry"
        );
    }

    #[tokio::test]
    async fn exit_code_is_captured_and_broadcast() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "exitcode", "exit 1");
        let mut rx = mgr
            .sessions
            .get("exitcode")
            .unwrap()
            .shared
            .event_tx
            .subscribe();
        mgr.sessions
            .get_mut("exitcode")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        mgr.reap_and_recover();

        // The re-broadcast from reap_and_recover should carry exit_code: Some(1).
        // Drain events (timeout generously) looking for it.
        let mut found = false;
        for _ in 0..20 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::Exited { exit_code: Some(1) })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }

        // Fallback: check the field directly (deterministic once try_wait has reaped).
        let s = mgr.sessions.get("exitcode").expect("session still tracked");
        let field_code = s.last_exit_code;

        assert!(
            found || field_code == Some(1),
            "exit code 1 should be captured (broadcast found={found}, field={field_code:?})"
        );
    }

    #[tokio::test]
    async fn sliding_window_guard_trips_and_survives_restart() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // "true" exits with code 0 → immediate restart, no backoff wait → fast test.
        spawn_stub(&mut mgr, "crashy", "true");
        mgr.sessions
            .get_mut("crashy")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        // Let the child exit.
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Drive reap/sleep cycles: MAX_RESTARTS crashes trip the guard.
        // Each cycle: crash detected → restart (code 0) → new child exits quickly.
        for _ in 0..(MAX_RESTARTS + 2) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        let s = mgr.sessions.get("crashy").expect("session still tracked");
        // Guard must have tripped: intentional_stop is set.
        assert!(
            s.intentional_stop.load(Ordering::SeqCst),
            "guard should mark the session to stop retrying"
        );
        // Crash window must have reached MAX_RESTARTS — proving the window
        // survived across restarts (the bug we're fixing).
        assert_eq!(
            s.crash_times.len() as u32,
            MAX_RESTARTS,
            "sliding window should accumulate MAX_RESTARTS crashes across restarts"
        );
    }

    #[tokio::test]
    async fn second_send_queues_while_mid_turn() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // Long-lived stub that ignores stdin; stays Idle until we send.
        spawn_stub(&mut mgr, "q", "sleep 5");

        // First send (idle → writes, optimistically MidTurn).
        mgr.send_user_message("q", "first", &[]).unwrap();
        assert_eq!(mgr.session_state("q"), Some(SessionState::MidTurn));

        // Second send while mid-turn → queued, not written.
        mgr.send_user_message("q", "second", &[]).unwrap();
        let pending = mgr
            .sessions
            .get("q")
            .unwrap()
            .shared
            .pending
            .lock()
            .unwrap();
        assert_eq!(pending.len(), 1, "second message must queue while mid-turn");
        assert_eq!(pending.front().map(|m| m.text.as_str()), Some("second"));
    }

    #[tokio::test]
    async fn send_to_dead_session_errors() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "d", "true"); // exits immediately
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(mgr.send_user_message("d", "hi", &[]).is_err());
        assert!(mgr.send_user_message("missing", "hi", &[]).is_err());
    }

    #[tokio::test]
    async fn stop_marks_session_not_alive() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "longlived", "sleep 30");
        assert!(mgr.sessions.get("longlived").unwrap().alive());
        mgr.stop("longlived");
        assert!(!mgr.sessions.get("longlived").unwrap().alive());
        assert_eq!(mgr.session_state("longlived"), Some(SessionState::Idle));
    }

    // ── StopReason / PermanentlyDown ─────────────────────────────────────────

    #[tokio::test]
    async fn stop_sets_stop_reason_and_broadcasts_permanently_down() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "target", "sleep 30");
        let mut rx = mgr
            .sessions
            .get("target")
            .unwrap()
            .shared
            .event_tx
            .subscribe();

        mgr.stop("target");

        assert_eq!(
            mgr.sessions.get("target").unwrap().stop_reason,
            Some(StopReason::User),
            "stop() must set stop_reason to StopReason::User"
        );

        // Drain events looking for PermanentlyDown { reason: User }.
        let mut found = false;
        for _ in 0..20 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::PermanentlyDown {
                    reason: StopReason::User,
                })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
        assert!(
            found,
            "stop() must broadcast SessionEvent::PermanentlyDown {{ reason: User }}"
        );
    }

    #[tokio::test]
    async fn guard_trip_sets_stop_reason_and_broadcasts_permanently_down() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        spawn_stub(&mut mgr, "crashy2", "true");
        mgr.sessions
            .get_mut("crashy2")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        // Let the initial child exit.
        tokio::time::sleep(Duration::from_millis(200)).await;

        // Run MAX_RESTARTS - 1 reap cycles to accumulate (MAX_RESTARTS - 1) crashes
        // with restarts (exit 0 → immediate restart). Each restart creates a new
        // ManagedSession with a new event_tx — so we must subscribe AFTER the last
        // restart and BEFORE the trip to capture the PermanentlyDown broadcast.
        for _ in 0..(MAX_RESTARTS - 1) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        // Subscribe to the CURRENT session's event_tx. The guard will trip on the
        // very next reap (one more crash reaches MAX_RESTARTS), broadcasting on this
        // channel.
        let mut rx = mgr
            .sessions
            .get("crashy2")
            .unwrap()
            .shared
            .event_tx
            .subscribe();

        // One more reap → guard trips → broadcasts PermanentlyDown on rx.
        mgr.reap_and_recover();
        tokio::time::sleep(Duration::from_millis(150)).await;

        // Assert durable state: stop_reason == CrashLoopGuard.
        let s = mgr.sessions.get("crashy2").expect("session still tracked");
        assert_eq!(
            s.stop_reason,
            Some(StopReason::CrashLoopGuard),
            "crash-loop guard trip must set stop_reason to CrashLoopGuard"
        );

        // Drain rx for PermanentlyDown { reason: CrashLoopGuard }.
        let mut found = false;
        for _ in 0..40 {
            match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
                Ok(Ok(SessionEvent::PermanentlyDown {
                    reason: StopReason::CrashLoopGuard,
                })) => {
                    found = true;
                    break;
                }
                Ok(Ok(_)) => continue,
                _ => break,
            }
        }
        assert!(
            found,
            "guard trip must broadcast SessionEvent::PermanentlyDown {{ reason: CrashLoopGuard }}"
        );
    }

    #[tokio::test]
    async fn restart_clears_stop_reason_and_crash_window() {
        let mut mgr = SessionManager::with_store_path(tmp_store());
        // Exits at once until `ok` exists, then stays up: the restarted session must still be
        // running when it is checked, which an instantly-exiting stub cannot promise.
        let ok = tmp_store().with_extension("ok");
        let script = format!("[ -e '{}' ] && exec sleep 30; exit 0", ok.display());
        spawn_stub(&mut mgr, "crashy3", &script);
        mgr.sessions
            .get_mut("crashy3")
            .unwrap()
            .attached_clients
            .insert("c1".into());

        tokio::time::sleep(Duration::from_millis(200)).await;

        // Trip the guard.
        for _ in 0..(MAX_RESTARTS + 2) {
            mgr.reap_and_recover();
            tokio::time::sleep(Duration::from_millis(150)).await;
        }

        assert_eq!(
            mgr.sessions.get("crashy3").unwrap().stop_reason,
            Some(StopReason::CrashLoopGuard),
            "guard must have tripped before restart"
        );

        // User-initiated restart — should build a fresh ManagedSession.
        std::fs::write(&ok, b"").unwrap();
        mgr.restart("crashy3").unwrap();

        let s = mgr
            .sessions
            .get("crashy3")
            .expect("session present after restart");
        assert_eq!(
            s.stop_reason, None,
            "restarted session must have stop_reason == None"
        );
        assert!(
            s.crash_times.is_empty(),
            "restarted session must have an empty crash window"
        );
        assert!(s.alive(), "restarted session must be alive");
        mgr.kill_all_on_shutdown();
        let _ = std::fs::remove_file(&ok);
    }

    // ── a switch task that dies must not take the session's queue with it ─────

    /// Kills the stub children on drop, even when an assertion fails first (the test runtime
    /// waits for the blocking reader threads, which only end when their child does).
    struct Reap(SessionManager);

    impl Drop for Reap {
        fn drop(&mut self) {
            self.0.kill_all_on_shutdown();
        }
    }

    /// Poll until `f` yields (30 s at most): events, not sleeps, decide when a test proceeds.
    async fn eventually<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(v) = f() {
                return v;
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// A stub session (its stdin recorded in `out`) with a switch "being applied" and one user
    /// message queued behind it.
    fn stub_applying_a_switch(dir: &tempfile::TempDir) -> (Reap, Shared, PathBuf) {
        let mut mgr = SessionManager::with_store_path(dir.path().join("sessions.json"));
        let out = dir.path().join("stdin.log");
        spawn_stub(&mut mgr, "t", &recording_stub(&out));
        let shared = mgr.sessions["t"].shared.clone();
        shared.model.lock().unwrap().applying = Some(ModelTarget {
            model: "opus".into(),
            effort: None,
        });
        mgr.send_user_message("t", "queued while applying", &[])
            .unwrap();
        assert_eq!(
            shared.pending.lock().unwrap().len(),
            1,
            "queued, not written: a switch is being applied"
        );
        assert!(!std::fs::read_to_string(&out)
            .unwrap_or_default()
            .contains("queued while applying"));
        (Reap(mgr), shared, out)
    }

    fn applied() -> ModelRequestOutcome {
        ModelRequestOutcome {
            status: crate::ipc::protocol::ModelRequestStatus::Applied,
            code: None,
            message: None,
            warning: None,
        }
    }

    /// The queued message reaches the stub's stdin, once, and the session is out of `Applying`.
    async fn assert_session_released(shared: &Shared, out: &std::path::Path) {
        eventually("the session to leave Applying", || {
            shared
                .model
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .applying
                .is_none()
                .then_some(())
        })
        .await;
        let written = eventually("the queued message to be written", || {
            let text = std::fs::read_to_string(out).unwrap_or_default();
            text.contains("queued while applying").then_some(text)
        })
        .await;
        assert_eq!(
            written.matches("queued while applying").count(),
            1,
            "exactly once: {written:?}"
        );
        assert!(shared.pending.lock().unwrap().is_empty());
    }

    // [seam: model_switch::spawn_apply_task]
    #[tokio::test]
    async fn a_switch_task_that_finishes_answers_its_requester_and_releases_the_queue() {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared, out) = stub_applying_a_switch(&dir);
        let (tx, rx) = oneshot::channel();

        model_switch::spawn_apply_task(&shared, Some(tx), async { applied() });

        let outcome = tokio::time::timeout(Duration::from_secs(30), rx)
            .await
            .expect("answered")
            .expect("not dropped");
        assert_eq!(outcome, applied());
        assert_session_released(&shared, &out).await;
    }

    // [seam: model_switch::spawn_apply_task]
    #[tokio::test]
    async fn a_switch_task_that_panics_still_leaves_applying_fails_its_requester_and_releases_the_queue(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared, out) = stub_applying_a_switch(&dir);
        let (tx, rx) = oneshot::channel();

        model_switch::spawn_apply_task(&shared, Some(tx), async {
            if true {
                panic!("the switch task blew up");
            }
            applied()
        });

        let outcome = tokio::time::timeout(Duration::from_secs(30), rx)
            .await
            .expect("the requester is answered, not left waiting")
            .expect("the answer is a result, not a dropped channel");
        assert_eq!(
            outcome.status,
            crate::ipc::protocol::ModelRequestStatus::Failed
        );
        assert_session_released(&shared, &out).await;
    }

    // [seam: model_switch::spawn_apply_task]
    #[tokio::test]
    async fn a_switch_task_that_panics_with_nobody_waiting_still_releases_the_session() {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared, out) = stub_applying_a_switch(&dir);

        model_switch::spawn_apply_task(&shared, None, async {
            if true {
                panic!("the switch task blew up");
            }
            applied()
        });

        assert_session_released(&shared, &out).await;
    }

    // [seam: model_switch::spawn_apply_task]
    #[tokio::test]
    async fn a_switch_task_that_panics_on_a_poisoned_runtime_lock_still_leaves_applying() {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared, out) = stub_applying_a_switch(&dir);
        // Something else panicked while holding the session's model lock earlier.
        let model = Arc::clone(&shared.model);
        let _ = std::thread::spawn(move || {
            let _held = model.lock().unwrap();
            panic!("poison the model lock");
        })
        .join();
        assert!(
            shared.model.is_poisoned(),
            "precondition: the lock is poisoned"
        );
        let (tx, rx) = oneshot::channel();

        model_switch::spawn_apply_task(&shared, Some(tx), async {
            if true {
                panic!("the switch task blew up");
            }
            applied()
        });

        let outcome = tokio::time::timeout(Duration::from_secs(30), rx)
            .await
            .expect("the requester is answered")
            .expect("not dropped");
        assert_eq!(
            outcome.status,
            crate::ipc::protocol::ModelRequestStatus::Failed
        );
        assert_session_released(&shared, &out).await;
    }

    // ── a panic elsewhere must not take a session's reader or queue down with it ──

    /// Poison `lock`: a thread panics while holding it.
    fn poison<T: Send + 'static>(lock: &Arc<Mutex<T>>) {
        let lock = Arc::clone(lock);
        let _ = std::thread::spawn(move || {
            let _held = lock.lock().unwrap();
            panic!("poison the lock");
        })
        .join();
    }

    /// A stub session whose stdin is recorded in `out` (when given), reaped when the guard drops.
    fn stub_session(dir: &tempfile::TempDir, tag: &str, script: &str) -> (Reap, Shared) {
        let mut mgr = SessionManager::with_store_path(dir.path().join("sessions.json"));
        spawn_stub(&mut mgr, tag, script);
        let shared = mgr.sessions[tag].shared.clone();
        (Reap(mgr), shared)
    }

    // [seam: model_switch::on_model_report]
    #[tokio::test]
    async fn a_model_report_is_still_recorded_after_a_panic_poisoned_the_runtime_lock() {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared) = stub_session(&dir, "t", "cat > /dev/null");
        poison(&shared.model);
        assert!(
            shared.model.is_poisoned(),
            "precondition: the lock is poisoned"
        );

        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            model_switch::on_model_report(&shared, "claude-opus-5-5")
        }));

        assert!(
            outcome.is_ok(),
            "the report must not panic on a poisoned lock"
        );
        assert_eq!(
            lock_recover(&shared.model).reported.as_deref(),
            Some("claude-opus-5-5")
        );
    }

    #[tokio::test]
    async fn a_session_whose_runtime_lock_was_poisoned_still_notices_its_child_exiting() {
        let dir = tempfile::tempdir().unwrap();
        let gate = dir.path().join("gate");
        // The child reports a model once the gate opens, then exits.
        let script = format!(
            r#"while [ ! -e '{}' ]; do sleep 0.05; done; printf '%s\n' '{{"type":"system","subtype":"init","session_id":"stub-sid","model":"claude-opus-5-5"}}'"#,
            gate.display()
        );
        let (_reap, shared) = stub_session(&dir, "t", &script);
        poison(&shared.model);

        std::fs::write(&gate, "").unwrap();

        eventually(
            "the reader to see its child exit (it panicked on the model report instead)",
            || shared.exited.load(Ordering::SeqCst).then_some(()),
        )
        .await;
        assert_eq!(
            lock_recover(&shared.model).reported.as_deref(),
            Some("claude-opus-5-5"),
            "the report was still taken"
        );
    }

    #[tokio::test]
    async fn a_session_whose_transcript_lock_was_poisoned_still_notices_its_child_exiting() {
        let dir = tempfile::tempdir().unwrap();
        let gate = dir.path().join("gate");
        // The child says one thing (a line the transcript takes in) once the gate opens, then exits.
        let script = format!(
            r#"while [ ! -e '{}' ]; do sleep 0.05; done; printf '%s\n' '{{"type":"user","isReplay":true,"message":{{"role":"user","content":"hi"}}}}'"#,
            gate.display()
        );
        let (_reap, shared) = stub_session(&dir, "t", &script);
        poison(&shared.transcript);
        assert!(
            shared.transcript.is_poisoned(),
            "precondition: the lock is poisoned"
        );

        std::fs::write(&gate, "").unwrap();

        eventually(
            "the reader to see its child exit (it panicked on the transcript lock instead)",
            || shared.exited.load(Ordering::SeqCst).then_some(()),
        )
        .await;
    }

    /// The frames a recording stub has read from stdin so far, as JSON.
    fn frames_read(out: &std::path::Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(out)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    #[tokio::test]
    async fn a_message_is_still_written_with_its_note_after_a_panic_poisoned_the_note_lock() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        let (_reap, shared) = stub_session(&dir, "t", &recording_stub(&out));
        *shared.note_prefix.lock().unwrap() = Some("the note".into());
        poison(&shared.note_prefix);
        assert!(
            shared.note_prefix.is_poisoned(),
            "precondition: the lock is poisoned"
        );
        let msg = PendingMessage::user("hello", &[]);

        let written = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            write_user_message(&shared, &msg)
        }))
        .expect("a poisoned note lock must not make the write panic");

        assert!(written.is_ok(), "{written:?}");
        let frames = eventually("the child to read the frame", || {
            let frames = frames_read(&out);
            (!frames.is_empty()).then_some(frames)
        })
        .await;
        assert_eq!(
            frames[0]["message"]["content"].as_str(),
            Some(format!("{NOSTROMO_NOTE_OPEN}the note{NOSTROMO_NOTE_CLOSE}hello").as_str()),
            "the note a panicking holder left is still delivered with the message"
        );
    }

    #[tokio::test]
    async fn frames_are_still_written_to_a_child_after_a_panic_poisoned_the_stdin_lock() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        let (_reap, shared) = stub_session(&dir, "t", &recording_stub(&out));
        poison(&shared.stdin);
        assert!(
            shared.stdin.is_poisoned(),
            "precondition: the lock is poisoned"
        );
        let msg = PendingMessage::user("hello", &[]);

        let (message, control) = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            (
                write_user_message(&shared, &msg),
                write_control_request(
                    &shared.stdin,
                    "r1",
                    serde_json::json!({ "subtype": "interrupt" }),
                ),
            )
        }))
        .expect("a poisoned stdin lock must not make a write panic");

        assert!(
            message.is_ok() && control.is_ok(),
            "{message:?} {control:?}"
        );
        let frames = eventually("the child to read both frames", || {
            let frames = frames_read(&out);
            (frames.len() >= 2).then_some(frames)
        })
        .await;
        assert_eq!(frames[0]["message"]["content"].as_str(), Some("hello"));
        assert_eq!(frames[1]["request"]["subtype"].as_str(), Some("interrupt"));
    }

    #[tokio::test]
    async fn asking_for_the_model_a_focus_already_has_does_not_panic_after_a_runtime_lock_was_poisoned(
    ) {
        for which in ["model", "state", "pending"] {
            let dir = tempfile::tempdir().unwrap();
            let (mut reap, shared) = stub_session(&dir, "t", "cat > /dev/null");
            let hub = reap.0.model_hub();
            model_store::update_focus_record(&hub.paths.focus_models, "t", |_| {
                Some(crate::model::store::FocusModelRecord {
                    model: "opus".into(),
                    ..Default::default()
                })
            })
            .unwrap();
            match which {
                "model" => poison(&shared.model),
                "state" => poison(&shared.state),
                _ => poison(&shared.pending),
            }
            let request = SwitchRequest {
                model: Some("opus".into()),
                effort: None,
                actor: Actor::User,
                set_as_agent_default: false,
                request_id: None,
            };

            let ticket = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                reap.0.request_switch("t", request)
            }))
            .unwrap_or_else(|_| panic!("a poisoned {which} lock made request_switch panic"));

            assert_eq!(
                ticket.immediate().map(|o| o.status),
                Some(crate::ipc::protocol::ModelRequestStatus::Unchanged),
                "{which}"
            );
        }
    }

    // [seam: step]
    #[tokio::test]
    async fn a_queued_message_whose_write_panics_is_not_lost_and_the_session_is_not_left_writing() {
        let dir = tempfile::tempdir().unwrap();
        let (_reap, shared) = stub_session(&dir, "t", "cat > /dev/null");
        lock_recover(&shared.pending).push_back(PendingMessage::user("M1", &[]));
        // Start writing M1 the way `step` does: off the queue, the write marked in flight, mid-turn.
        // (Nothing in the write path panics by itself any more now that it survives poisoned locks, so
        // the panic is made by hand while the write is in flight.)
        let msg = {
            let mut state = lock_recover(&shared.state);
            let msg = lock_recover(&shared.pending)
                .pop_front()
                .expect("M1 is queued");
            shared.writing.store(true, Ordering::SeqCst);
            *state = SessionState::MidTurn;
            msg
        };

        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let _in_flight = WriteInFlight {
                shared: &shared,
                msg: Some(msg),
            };
            if true {
                panic!("the write blew up");
            }
        }));

        assert!(outcome.is_err(), "precondition: the write panicked");
        assert!(
            !shared.writing.load(Ordering::SeqCst),
            "`writing` stays set after a panic: a restart then waits five seconds under the manager lock for a write that is long over"
        );
        let pending = lock_recover(&shared.pending);
        assert_eq!(
            pending.front().map(|m| m.text.as_str()),
            Some("M1"),
            "the message was not delivered, so it is still queued"
        );
        drop(pending);
        assert_eq!(
            *lock_recover(&shared.state),
            SessionState::Idle,
            "and nothing is running that would ever end"
        );
    }

    // [seam: SessionManager::interrupt]
    #[tokio::test]
    async fn a_stop_pressed_while_a_queued_message_is_being_written_comes_after_that_message_on_stdin(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        let mut mgr = SessionManager::with_store_path(dir.path().join("sessions.json"));
        spawn_stub(&mut mgr, "perri", &recording_stub(&out));
        let shared = mgr.sessions["perri"].shared.clone();
        mgr.send_user_message("perri", "first", &[]).unwrap(); // written at once: a turn is running
        mgr.send_user_message("perri", "M1", &[]).unwrap(); // queued behind it
        assert_eq!(lock_recover(&shared.pending).len(), 1);
        let reap = Reap(mgr);

        // Park the writer: `write_user_message` takes this lock before it touches stdin.
        let parked = shared.note_prefix.lock().unwrap();
        // The turn ends: the reader's next step takes M1 off the queue and starts writing it.
        let advancing = {
            let shared = shared.clone();
            std::thread::spawn(move || advance(&shared))
        };
        let started = Instant::now();
        while !shared.writing.load(Ordering::SeqCst) {
            assert!(
                started.elapsed() < Duration::from_secs(30),
                "the writer never took M1"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            lock_recover(&shared.pending).is_empty(),
            "M1 is off the queue and not yet on stdin"
        );
        // Stop is pressed now.
        let stopping = std::thread::spawn(move || {
            let mut reap = reap;
            let outcome = reap.0.interrupt("perri");
            (reap, outcome)
        });
        // Give an interrupt that does not wait for the writer the chance to get its frame out first.
        // Nothing depends on how long this takes: a correct one is simply still waiting.
        let patience = Instant::now() + Duration::from_millis(500);
        while !stopping.is_finished() && Instant::now() < patience {
            std::thread::sleep(Duration::from_millis(1));
        }
        drop(parked);

        advancing.join().unwrap();
        let (_reap, outcome) = stopping.join().unwrap();

        assert_eq!(outcome.unwrap(), InterruptOutcome::Requested);
        let frames = eventually("the child to have read every frame", || {
            let text = std::fs::read_to_string(&out).unwrap_or_default();
            (text.lines().count() >= 3).then_some(text)
        })
        .await;
        let labels: Vec<String> = frames
            .lines()
            .map(|l| {
                let v: serde_json::Value = serde_json::from_str(l).unwrap();
                match v["type"].as_str().unwrap() {
                    "user" => v["message"]["content"].as_str().unwrap().to_owned(),
                    other => format!("{other}:{}", v["request"]["subtype"].as_str().unwrap_or("")),
                }
            })
            .collect();
        assert_eq!(
            labels,
            ["first", "M1", "control_request:interrupt"],
            "the interrupt reaches the child after M1, so it applies to M1's turn; M1 never starts a turn the user tried to stop"
        );
        assert!(
            lock_recover(&shared.pending).is_empty(),
            "Stop leaves nothing queued"
        );
    }

    // [seam: SessionManager::interrupt]
    #[tokio::test]
    async fn an_interrupt_cannot_slip_between_the_writer_popping_a_message_and_the_message_reaching_stdin(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("stdin.log");
        let mut mgr = SessionManager::with_store_path(dir.path().join("sessions.json"));
        spawn_stub(&mut mgr, "perri", &recording_stub(&out));
        let shared = mgr.sessions["perri"].shared.clone();
        mgr.send_user_message("perri", "first", &[]).unwrap(); // written at once: a turn is running
        mgr.send_user_message("perri", "M1", &[]).unwrap(); // queued behind it
        assert_eq!(lock_recover(&shared.pending).len(), 1);
        let reap = Reap(mgr);

        // Hold the session's state, as the writer does while it takes its message: whatever looks at the
        // session now sees it as it was before M1 was taken.
        // (In a block of its own: the guard must be gone before the first await.)
        let (stopping, msg) = {
            let mut state = lock_recover(&shared.state);
            let stopping = std::thread::spawn(move || {
                let mut reap = reap;
                let outcome = reap.0.interrupt("perri");
                (reap, outcome)
            });
            // Give the interrupt the chance to look at the session before the writer has done anything.
            // Nothing depends on how long this takes: it cannot finish while `state` is held.
            let patience = Instant::now() + Duration::from_millis(500);
            while !stopping.is_finished() && Instant::now() < patience {
                std::thread::sleep(Duration::from_millis(1));
            }
            assert!(
                !stopping.is_finished(),
                "precondition: the interrupt is waiting for the session's state"
            );

            // The writer, still holding `state`, takes M1 off the queue and marks the write in flight (`step`).
            let msg = lock_recover(&shared.pending)
                .pop_front()
                .expect("M1 is queued");
            shared.writing.store(true, Ordering::SeqCst);
            *state = SessionState::MidTurn;
            drop(state);
            (stopping, msg)
        };

        // M1 is off the queue and on its way to stdin, but not there yet. A correct interrupt sees the write
        // in flight and waits for it; one that does not finishes now, with its frame ahead of M1's.
        let patience = Instant::now() + Duration::from_millis(500);
        while !stopping.is_finished() && Instant::now() < patience {
            std::thread::sleep(Duration::from_millis(1));
        }
        let in_flight = WriteInFlight {
            shared: &shared,
            msg: Some(msg),
        };
        in_flight.write().unwrap();
        in_flight.finish(true);
        let (_reap, outcome) = stopping.join().unwrap();

        assert_eq!(outcome.unwrap(), InterruptOutcome::Requested);
        let frames = eventually("the child to have read every frame", || {
            let frames = frames_read(&out);
            (frames.len() >= 3).then_some(frames)
        })
        .await;
        let labels: Vec<String> = frames
            .iter()
            .map(|v| match v["type"].as_str().unwrap() {
                "user" => v["message"]["content"].as_str().unwrap().to_owned(),
                other => format!("{other}:{}", v["request"]["subtype"].as_str().unwrap_or("")),
            })
            .collect();
        assert_eq!(
            labels,
            ["first", "M1", "control_request:interrupt"],
            "the interrupt reaches the child after M1, which it was pressed against, never before it"
        );
        assert!(
            lock_recover(&shared.pending).is_empty(),
            "Stop leaves nothing queued"
        );
    }
    // ── background tasks, end to end through a stub session ───────────────────
    //
    // The stub prints canned `system` task events (see `tasks-events.jsonl` for the
    // shapes). Nothing here asserts a duration: tests proceed on published
    // frames and poll for them with a generous cap. Where a test waits for
    // something NOT to happen it waits a couple of poll intervals, which is the
    // only way to observe absence.

    use super::task_runtime::PREVIEW_INTERVAL;
    use crate::ipc::task_output::OutputFileValidator;
    use crate::ipc::tasks::parse_task_event;

    /// A `system` event line from the stub CLI (session id `stub-sid`).
    fn task_line(subtype: &str, body: serde_json::Value) -> String {
        let mut line =
            serde_json::json!({"type": "system", "subtype": subtype, "session_id": "stub-sid"});
        line.as_object_mut()
            .unwrap()
            .extend(body.as_object().unwrap().clone());
        line.to_string()
    }

    /// Shell that prints each line to stdout.
    fn print_lines(lines: &[String]) -> String {
        lines
            .iter()
            .map(|l| format!("printf '%s\\n' '{}';", l.replace('\'', "'\\''")))
            .collect::<Vec<_>>()
            .join(" ")
    }

    /// Prints `lines`, then answers `get_task_output` control requests with the
    /// JSON in `reply` (or an error while `fail` exists), logging every frame it
    /// reads to `log`.
    fn answering_stub(
        gate: Option<&std::path::Path>,
        lines: &[String],
        reply: &std::path::Path,
        fail: &std::path::Path,
        log: &std::path::Path,
    ) -> String {
        let wait = gate
            .map(|g| format!("while [ ! -e '{}' ]; do sleep 0.05; done;", g.display()))
            .unwrap_or_default();
        let body = r##"
while IFS= read -r line; do
  printf '%s\n' "$line" >> '@LOG@'
  case "$line" in
    *'"subtype":"get_task_output"'*)
      rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p')
      if [ -e '@FAIL@' ]; then
        printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"$rid\",\"error\":\"No task found with ID\"}}"
      else
        body=$(cat '@REPLY@')
        printf '%s\n' "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":$body}}"
      fi ;;
  esac
done
"##
        .replace("@LOG@", &log.display().to_string())
        .replace("@FAIL@", &fail.display().to_string())
        .replace("@REPLY@", &reply.display().to_string());
        format!("{wait} {} {body}", print_lines(lines))
    }

    fn output_reply(output: &str) -> String {
        serde_json::json!({"output": output, "total_bytes": output.len(), "truncated": false})
            .to_string()
    }

    async fn next_client_frame(crx: &mut mpsc::UnboundedReceiver<ServerMsg>) -> ServerMsg {
        tokio::time::timeout(Duration::from_secs(20), crx.recv())
            .await
            .expect("a frame within 20 s")
            .expect("the client channel is open")
    }

    fn frame_kind(msg: &ServerMsg) -> &'static str {
        match msg {
            ServerMsg::SessionTurns { .. } => "turns",
            ServerMsg::SessionState { .. } => "state",
            ServerMsg::SessionTasks { .. } => "tasks",
            ServerMsg::SessionTaskDetail { .. } => "detail",
            ServerMsg::SessionExited { .. } => "exited",
            _ => "other",
        }
    }

    /// A client sender registered on the manager.
    fn client(mgr: &SessionManager, id: &str) -> mpsc::UnboundedReceiver<ServerMsg> {
        let (tx, rx) = mpsc::unbounded_channel::<ServerMsg>();
        mgr.client_senders.lock().unwrap().insert(id.into(), tx);
        rx
    }

    #[tokio::test]
    async fn attach_sends_the_task_list_then_one_detail_per_task_that_has_text_after_the_state() {
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        let lines = vec![
            task_line(
                "task_started",
                serde_json::json!({"task_id": "b7k2m9x1a", "description": "Run the build", "task_type": "local_bash", "is_backgrounded": true}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "agt5r1w3d", "description": "Survey the config", "task_type": "local_agent", "subagent_type": "Explore", "prompt": "Read the config"}),
            ),
            task_line(
                "task_progress",
                serde_json::json!({"task_id": "agt5r1w3d", "summary": "Reading the files"}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "done1", "description": "Quick job", "task_type": "local_bash"}),
            ),
            task_line(
                "task_notification",
                serde_json::json!({"task_id": "done1", "status": "completed", "summary": "Quick job finished"}),
            ),
        ];
        spawn_stub(
            &mut reap.0,
            "cody-1",
            &format!("{} cat >/dev/null", print_lines(&lines)),
        );
        let shared = reap.0.sessions["cody-1"].shared.clone();
        eventually("the registry to hold all three tasks", || {
            let (snapshot, details) = shared.tasks.current();
            (snapshot.tasks.len() == 3
                && snapshot.tasks[2].status == crate::ipc::protocol::TaskStatus::Completed
                && details.len() == 2)
                .then_some(())
        })
        .await;
        let mut first = client(&reap.0, "c1");
        let mut second = client(&reap.0, "c2");

        reap.0.attach("cody-1", "c1").unwrap();
        let mut got_first = vec![];
        for _ in 0..5 {
            got_first.push(next_client_frame(&mut first).await);
        }
        reap.0.attach("cody-1", "c2").unwrap();
        let mut got_second = vec![];
        for _ in 0..5 {
            got_second.push(next_client_frame(&mut second).await);
        }

        let kinds: Vec<&str> = got_first.iter().map(frame_kind).collect();
        assert_eq!(
            kinds,
            ["turns", "state", "tasks", "detail", "detail"],
            "{got_first:?}"
        );
        let ServerMsg::SessionTasks {
            tag,
            session_id,
            tasks,
            ..
        } = &got_first[2]
        else {
            unreachable!()
        };
        assert_eq!(
            (tag.as_str(), session_id.as_deref()),
            ("cody-1", Some("stub-sid"))
        );
        let ids: Vec<&str> = tasks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["b7k2m9x1a", "agt5r1w3d", "done1"]);
        let statuses: Vec<_> = tasks.iter().map(|t| t.status).collect();
        assert_eq!(
            statuses,
            [
                crate::ipc::protocol::TaskStatus::Running,
                crate::ipc::protocol::TaskStatus::Running,
                crate::ipc::protocol::TaskStatus::Completed
            ],
            "the session is alive: its running tasks are running"
        );
        let ServerMsg::SessionTaskDetail {
            task_id,
            prompt,
            progress_summary,
            ..
        } = &got_first[3]
        else {
            unreachable!()
        };
        assert_eq!(task_id, "agt5r1w3d");
        assert_eq!(
            (prompt.as_deref(), progress_summary.as_deref()),
            (Some("Read the config"), Some("Reading the files"))
        );
        let ServerMsg::SessionTaskDetail {
            task_id,
            completion_summary,
            ..
        } = &got_first[4]
        else {
            unreachable!()
        };
        assert_eq!(
            (task_id.as_str(), completion_summary.as_deref()),
            ("done1", Some("Quick job finished"))
        );
        assert!(first.try_recv().is_err(), "nothing else was sent");
        for (a, b) in got_first.iter().zip(&got_second) {
            assert_eq!(
                serde_json::to_string(a).unwrap(),
                serde_json::to_string(b).unwrap(),
                "a second client sees the same frames"
            );
        }
    }

    #[tokio::test]
    async fn attaching_to_a_session_with_no_tasks_still_sends_an_empty_task_list_after_the_state() {
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(&mut reap.0, "cody-1", "cat >/dev/null");
        let mut crx = client(&reap.0, "c1");

        reap.0.attach("cody-1", "c1").unwrap();

        assert_eq!(frame_kind(&next_client_frame(&mut crx).await), "turns");
        assert_eq!(frame_kind(&next_client_frame(&mut crx).await), "state");
        let ServerMsg::SessionTasks { tasks, .. } = next_client_frame(&mut crx).await else {
            panic!("a task list")
        };
        assert!(tasks.is_empty());
    }

    #[tokio::test]
    async fn when_the_cli_exits_every_unfinished_task_is_reported_stopped_before_the_exit_frame() {
        use crate::ipc::protocol::{TaskEndReason, TaskStatus};
        let dir = tempfile::tempdir().unwrap();
        let gate = dir.path().join("gate");
        let lines = vec![
            task_line(
                "task_started",
                serde_json::json!({"task_id": "shell1", "description": "Run it", "task_type": "local_bash", "is_backgrounded": true}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "agent1", "description": "Survey", "task_type": "local_agent"}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "pend1", "description": "Queued", "task_type": "local_workflow"}),
            ),
            task_line(
                "task_updated",
                serde_json::json!({"task_id": "pend1", "patch": {"status": "pending"}}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "paus1", "description": "Paused", "task_type": "local_workflow"}),
            ),
            task_line(
                "task_updated",
                serde_json::json!({"task_id": "paus1", "patch": {"status": "paused"}}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "done1", "description": "Finished", "task_type": "local_bash"}),
            ),
            task_line(
                "task_notification",
                serde_json::json!({"task_id": "done1", "status": "completed"}),
            ),
        ];
        // The stub prints its events once the gate opens, then exits: EOF.
        let script = format!(
            "while [ ! -e '{}' ]; do sleep 0.05; done; {}",
            gate.display(),
            print_lines(&lines)
        );
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(&mut reap.0, "cody-1", &script);
        let mut crx = client(&reap.0, "c1");
        reap.0.attach("cody-1", "c1").unwrap();
        for _ in 0..3 {
            next_client_frame(&mut crx).await; // turns, state, the empty list
        }

        std::fs::write(&gate, "").unwrap();
        let mut frames = vec![];
        loop {
            let frame = next_client_frame(&mut crx).await;
            let done = matches!(frame, ServerMsg::SessionExited { .. });
            frames.push(frame);
            if done {
                break;
            }
        }

        let exited_at = frames.len() - 1;
        let last_tasks_at = frames
            .iter()
            .rposition(|f| matches!(f, ServerMsg::SessionTasks { .. }))
            .expect("a task list was sent");
        assert!(
            last_tasks_at < exited_at,
            "the final task list must reach the client before SessionExited: {:?}",
            frames.iter().map(frame_kind).collect::<Vec<_>>()
        );
        let ServerMsg::SessionTasks { tasks, .. } = &frames[last_tasks_at] else {
            unreachable!()
        };
        assert_eq!(tasks.len(), 5);
        for t in tasks {
            if t.id == "done1" {
                assert_eq!((t.status, t.end_reason), (TaskStatus::Completed, None));
            } else {
                assert_eq!(
                    (t.status, t.end_reason),
                    (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded)),
                    "{} must end with the session",
                    t.id
                );
            }
        }
    }

    // ── the preview poller ───────────────────────────────────────────────────

    /// A stub session whose task runtime reads output files under a temp root, with its
    /// timer running, and a receiver on its event channel.
    struct PreviewRig {
        reap: Reap,
        shared: Shared,
        rx: broadcast::Receiver<SessionEvent>,
        /// `<root>/-work-repo/stub-sid/tasks`: where the CLI would write.
        tasks_dir: PathBuf,
        _dir: tempfile::TempDir,
    }

    fn preview_rig(tag: &str, script: &str) -> PreviewRig {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("claude-501");
        let tasks_dir = root.join("-work-repo").join("stub-sid").join("tasks");
        std::fs::create_dir_all(&tasks_dir).unwrap();
        let mut reap = Reap(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        ));
        spawn_stub(&mut reap.0, tag, script);
        let managed = reap.0.sessions.get_mut(tag).unwrap();
        let runtime = TaskRuntime::with_validator(
            Arc::clone(&managed.shared.transcript),
            Some("stub-sid".into()),
            PathBuf::from("/work/repo"),
            OutputFileValidator::new(&root),
        );
        // The reader thread keeps the runtime it was built with; everything this rig
        // feeds and reads goes through the injected one.
        managed.shared.tasks = Arc::clone(&runtime);
        let shared = managed.shared.clone();
        tokio::spawn(drive_timer(
            runtime,
            shared.event_tx.clone(),
            Arc::clone(&shared.exited),
        ));
        let rx = shared.event_tx.subscribe();
        PreviewRig {
            reap,
            shared,
            rx,
            tasks_dir,
            _dir: dir,
        }
    }

    impl PreviewRig {
        fn feed(&self, subtype: &str, body: serde_json::Value) {
            let mut obj = serde_json::json!({"session_id": "stub-sid"});
            obj.as_object_mut()
                .unwrap()
                .extend(body.as_object().unwrap().clone());
            let event = parse_task_event(subtype, obj.as_object().unwrap()).expect("a task event");
            self.shared.tasks.on_event(&self.shared.event_tx, &event);
        }

        /// What the reader does for a task line.
        fn feed_as_reader(&self, subtype: &str, body: serde_json::Value) {
            self.feed(subtype, body);
            ensure_poller(&self.shared);
        }

        fn start_shell(&self, id: &str) {
            self.feed_as_reader(
                "task_started",
                serde_json::json!({"task_id": id, "description": "Run it", "task_type": "local_bash", "is_backgrounded": true}),
            );
        }

        fn write_output(&self, id: &str, bytes: &[u8]) {
            std::fs::write(self.tasks_dir.join(format!("{id}.output")), bytes).unwrap();
        }

        fn append_output(&self, id: &str, bytes: &[u8]) {
            use std::io::Write as _;
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.tasks_dir.join(format!("{id}.output")))
                .unwrap();
            f.write_all(bytes).unwrap();
        }

        fn published_preview(&self, id: &str) -> Option<String> {
            self.shared
                .tasks
                .current()
                .1
                .into_iter()
                .find(|d| d.task_id == id)
                .and_then(|d| d.preview.clone())
        }

        /// The next `SessionTaskDetail` carrying a preview, if one is published within `within`.
        async fn next_preview(&mut self, within: Duration) -> Option<(String, String)> {
            let deadline = Instant::now() + within;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match tokio::time::timeout(left, self.rx.recv()).await {
                    Ok(Ok(SessionEvent::TaskDetail(d))) if d.preview.is_some() => {
                        return Some((d.task_id.clone(), d.preview.clone().unwrap()));
                    }
                    Ok(Ok(_)) | Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                    _ => return None,
                }
            }
        }

        /// Wait until a detail frame for `id` carries the preview `expected`. A detail frame
        /// is the whole detail, so one for another change (a summary, say) may come first.
        async fn expect_preview(&mut self, id: &str, expected: &str) {
            let deadline = Instant::now() + Duration::from_secs(30);
            let mut seen = vec![];
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match self.next_preview(left).await {
                    Some((task, preview)) if task == id && preview == expected => return,
                    Some(other) => seen.push(other),
                    None => panic!(
                        "no preview {expected:?} for {id} within 30 s; previews seen: {seen:?}"
                    ),
                }
            }
        }

        /// Wait two poll intervals and a bit: no preview may be published meanwhile.
        async fn expect_no_preview(&mut self, why: &str) {
            let got = self
                .next_preview(PREVIEW_INTERVAL * 2 + Duration::from_millis(500))
                .await;
            assert_eq!(got, None, "{why}");
        }
    }

    /// Stays alive until killed. NOT `exec cat >/dev/null`: that would close the
    /// stdout pipe, which the reader takes for the CLI having exited.
    const STAY_ALIVE: &str = "cat >/dev/null";

    #[tokio::test]
    async fn a_running_shell_tasks_preview_follows_the_last_line_of_its_output_file() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"compiling a\ncompiling b\n");
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");

        rig.expect_preview("b7k2m9x1a", "compiling b").await;

        // A progress bar and colour: the preview is the cleaned final state.
        rig.append_output(
            "b7k2m9x1a",
            b"\x1b[32mlinking\x1b[0m 10%\rlinking 100%\n\n   \n",
        );
        rig.expect_preview("b7k2m9x1a", "linking 100%").await;
        let preview = rig.published_preview("b7k2m9x1a").unwrap();
        assert!(!preview.contains('\u{1b}') && preview.chars().count() <= 200);

        // Output that adds no new visible line changes nothing: nothing is published.
        rig.append_output("b7k2m9x1a", b"\n   \n\t\n");
        rig.expect_no_preview("an unchanged last line must not be re-published")
            .await;
        assert_eq!(
            rig.published_preview("b7k2m9x1a").as_deref(),
            Some("linking 100%")
        );
    }

    #[tokio::test]
    async fn a_very_long_output_line_previews_as_at_most_200_characters() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output(
            "b7k2m9x1a",
            format!("short\n{}\n", "y".repeat(5_000)).as_bytes(),
        );
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");

        let (_, preview) = rig
            .next_preview(Duration::from_secs(30))
            .await
            .expect("a preview");

        assert_eq!(preview.chars().count(), 200);
        assert!(preview.ends_with('\u{2026}'));
    }

    #[tokio::test]
    async fn a_monitor_task_is_previewed_too_and_an_agent_is_not() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("mon1", b"event: deploy started\n");
        rig.write_output("agt1", b"this is an agent transcript\n");
        rig.shared.tasks.set_clients(1);
        rig.feed("task_started", serde_json::json!({"task_id": "agt1", "description": "Survey", "task_type": "local_agent"}));
        rig.feed_as_reader("task_started", serde_json::json!({"task_id": "mon1", "description": "Watch", "task_type": "monitor_mcp"}));

        rig.expect_preview("mon1", "event: deploy started").await;
        rig.expect_no_preview("an agent has no output preview")
            .await;
        assert_eq!(rig.published_preview("agt1"), None);
    }

    #[tokio::test]
    async fn with_no_client_attached_nothing_is_read_and_nothing_is_published() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"hidden until someone looks\n");

        rig.start_shell("b7k2m9x1a"); // clients: 0
        rig.expect_no_preview("no client is attached: the poller must not run")
            .await;
        assert_eq!(rig.published_preview("b7k2m9x1a"), None);

        // Someone attaches: the poller starts.
        rig.shared.tasks.set_clients(1);
        ensure_poller(&rig.shared);
        rig.expect_preview("b7k2m9x1a", "hidden until someone looks")
            .await;
    }

    #[tokio::test]
    async fn polling_stops_when_the_last_client_leaves_and_resumes_when_one_returns() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"one\n");
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");
        rig.expect_preview("b7k2m9x1a", "one").await;

        rig.shared.tasks.set_clients(0);
        // Let an in-flight cycle finish, then change the output.
        tokio::time::sleep(PREVIEW_INTERVAL + Duration::from_millis(500)).await;
        while rig.rx.try_recv().is_ok() {}
        rig.append_output("b7k2m9x1a", b"two\n");
        rig.expect_no_preview("nobody is watching").await;

        rig.shared.tasks.set_clients(1);
        ensure_poller(&rig.shared);
        rig.expect_preview("b7k2m9x1a", "two").await;
    }

    #[tokio::test]
    async fn after_a_task_ends_one_final_read_happens_and_then_polling_stops() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"line 1\n");
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");
        rig.expect_preview("b7k2m9x1a", "line 1").await;

        // The last output lands, then the task ends: the final read picks it up.
        rig.append_output("b7k2m9x1a", b"final line\n");
        rig.feed(
            "task_notification",
            serde_json::json!({"task_id": "b7k2m9x1a", "status": "completed", "summary": "done"}),
        );
        rig.expect_preview("b7k2m9x1a", "final line").await;

        rig.append_output("b7k2m9x1a", b"written after the end\n");
        rig.expect_no_preview("an ended task is not polled any more")
            .await;
        assert_eq!(
            rig.published_preview("b7k2m9x1a").as_deref(),
            Some("final line")
        );
    }

    #[tokio::test]
    async fn a_task_that_ended_before_it_was_ever_polled_still_gets_its_one_read() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("quick1", b"output of a quick job\nall good\n");
        rig.shared.tasks.set_clients(1);
        rig.feed("task_started", serde_json::json!({"task_id": "quick1", "description": "Quick", "task_type": "local_bash"}));
        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "quick1", "status": "completed"}),
        );

        rig.expect_preview("quick1", "all good").await;
        rig.expect_no_preview("one read, then done").await;
    }

    #[tokio::test]
    async fn a_file_the_validator_refuses_is_never_read_and_the_preview_comes_from_the_cli() {
        // A symlink named like the output file: refused (O_NOFOLLOW), so no file
        // preview; the poller falls back to the CLI, which here never answers.
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        let secret = rig.tasks_dir.join("secret.txt");
        std::fs::write(&secret, "SECRET-OUTPUT-1\n").unwrap();
        std::os::unix::fs::symlink(&secret, rig.tasks_dir.join("b7k2m9x1a.output")).unwrap();
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");

        rig.expect_no_preview("a symlinked output file must not be followed")
            .await;
        assert_eq!(rig.published_preview("b7k2m9x1a"), None);
    }

    // ── the CLI-tail fallback (`get_task_output`) ────────────────────────────

    fn control_log(log: &std::path::Path) -> Vec<serde_json::Value> {
        std::fs::read_to_string(log)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
            .filter(|v| v["request"]["subtype"] == "get_task_output")
            .collect()
    }

    #[tokio::test]
    async fn without_a_file_the_preview_comes_from_get_task_output_and_an_error_keeps_the_last_one()
    {
        let dir = tempfile::tempdir().unwrap();
        let (reply, fail, log) = (
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(
            &reply,
            output_reply("alpha\nbeta \u{1b}[31mred\u{1b}[0m\n\n"),
        )
        .unwrap();
        let script = answering_stub(None, &[], &reply, &fail, &log);
        let mut rig = preview_rig("cody-1", &script);
        rig.shared.tasks.set_clients(1);
        // An agent is running too: it is never asked about.
        rig.feed("task_started", serde_json::json!({"task_id": "agt1", "description": "Survey", "task_type": "local_agent"}));
        rig.start_shell("b7k2m9x1a");

        // The reply body's `output`, sanitised, last non-empty line.
        rig.expect_preview("b7k2m9x1a", "beta red").await;
        let requests = control_log(&log);
        assert!(!requests.is_empty());
        assert!(
            requests
                .iter()
                .all(|r| r["request"]["task_id"] == "b7k2m9x1a"),
            "only the shell task is read: {requests:?}"
        );
        assert!(requests.iter().all(|r| r["type"] == "control_request"));

        // New output, new preview.
        std::fs::write(&reply, output_reply("gamma\n")).unwrap();
        rig.expect_preview("b7k2m9x1a", "gamma").await;

        // The CLI starts refusing: the preview stays as it was and nothing is published.
        let before = control_log(&log).len();
        std::fs::write(&fail, "").unwrap();
        eventually("a read to be attempted and refused", || {
            (control_log(&log).len() > before).then_some(())
        })
        .await;
        assert_eq!(
            rig.next_preview(PREVIEW_INTERVAL + Duration::from_millis(500))
                .await,
            None
        );
        assert_eq!(
            rig.published_preview("b7k2m9x1a").as_deref(),
            Some("gamma"),
            "the last preview is kept on an error"
        );
        assert!(control_log(&log)
            .iter()
            .all(|r| r["request"]["task_id"] != "agt1"));
    }

    #[tokio::test]
    async fn an_output_reply_with_nothing_visible_publishes_no_preview() {
        let dir = tempfile::tempdir().unwrap();
        let (reply, fail, log) = (
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(&reply, output_reply("\n   \n")).unwrap();
        let script = answering_stub(None, &[], &reply, &fail, &log);
        let mut rig = preview_rig("cody-1", &script);
        rig.shared.tasks.set_clients(1);
        rig.start_shell("b7k2m9x1a");

        eventually("a read to be attempted", || {
            (!control_log(&log).is_empty()).then_some(())
        })
        .await;

        assert_eq!(
            rig.next_preview(PREVIEW_INTERVAL + Duration::from_millis(500))
                .await,
            None
        );
        assert_eq!(rig.published_preview("b7k2m9x1a"), None);
    }

    // ── through the real wiring: the reader, attach and the forwarder ───────

    #[tokio::test]
    async fn a_client_attached_before_a_task_starts_gets_its_preview_from_the_cli() {
        let dir = tempfile::tempdir().unwrap();
        let (gate, reply, fail, log) = (
            dir.path().join("gate"),
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(
            &reply,
            output_reply("step 1\nstep 2 \u{1b}[1mdone\u{1b}[0m\n"),
        )
        .unwrap();
        let lines = vec![task_line(
            "task_started",
            serde_json::json!({"task_id": "e2e-shell", "description": "Run it", "task_type": "local_bash", "is_backgrounded": true}),
        )];
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(
            &mut reap.0,
            "cody-1",
            &answering_stub(Some(&gate), &lines, &reply, &fail, &log),
        );
        let mut crx = client(&reap.0, "c1");
        reap.0.attach("cody-1", "c1").unwrap();
        for _ in 0..3 {
            next_client_frame(&mut crx).await;
        }

        std::fs::write(&gate, "").unwrap();
        let mut seen = vec![];
        let preview = loop {
            let frame = next_client_frame(&mut crx).await;
            seen.push(frame_kind(&frame));
            if let ServerMsg::SessionTaskDetail {
                task_id,
                preview: Some(p),
                ..
            } = frame
            {
                assert_eq!(task_id, "e2e-shell");
                break p;
            }
        };

        assert_eq!(preview, "step 2 done");
        assert_eq!(
            seen.first(),
            Some(&"tasks"),
            "the client learns of the task before its preview: {seen:?}"
        );
    }

    #[tokio::test]
    async fn a_client_that_attaches_to_a_session_with_a_running_task_gets_its_preview() {
        // The task started while nobody was looking; attaching must start the preview.
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"building\nlinking\n");
        rig.start_shell("b7k2m9x1a"); // no client yet: the poller does not start
        let mut crx = client(&rig.reap.0, "c1");

        rig.reap.0.attach("cody-1", "c1").unwrap();

        let mut seen = vec![];
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(20), crx.recv())
                .await
                .unwrap_or_else(|_| {
                    panic!("no preview reached the attached client; frames: {seen:?}")
                })
                .expect("open");
            seen.push(frame_kind(&frame));
            if let ServerMsg::SessionTaskDetail {
                preview: Some(p), ..
            } = frame
            {
                assert_eq!(p, "linking");
                break;
            }
        }
    }

    // ── the final snapshot on stop ───────────────────────────────────────────

    /// Wait (bounded) until the session's reader has seen EOF and said so.
    async fn wait_for_reader_eof(rx: &mut broadcast::Receiver<SessionEvent>) {
        loop {
            match tokio::time::timeout(Duration::from_secs(20), rx.recv()).await {
                Ok(Ok(SessionEvent::Exited { .. })) => return,
                Ok(Ok(_)) | Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
                other => panic!("the reader never reached EOF: {other:?}"),
            }
        }
    }

    /// Frames already queued for a client.
    fn queued(crx: &mut mpsc::UnboundedReceiver<ServerMsg>) -> Vec<ServerMsg> {
        let mut out = vec![];
        while let Ok(frame) = crx.try_recv() {
            out.push(frame);
        }
        out
    }

    /// Two running tasks (a shell and an agent) and one that finished.
    fn running_and_finished_task_lines() -> Vec<String> {
        vec![
            task_line(
                "task_started",
                serde_json::json!({"task_id": "shell1", "description": "Run it", "task_type": "local_bash", "is_backgrounded": true}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "agent1", "description": "Survey", "task_type": "local_agent"}),
            ),
            task_line(
                "task_started",
                serde_json::json!({"task_id": "done1", "description": "Finished", "task_type": "local_bash"}),
            ),
            task_line(
                "task_notification",
                serde_json::json!({"task_id": "done1", "status": "completed"}),
            ),
        ]
    }

    fn assert_running_tasks_ended_with_the_session(tasks: &[crate::ipc::protocol::TaskMeta]) {
        use crate::ipc::protocol::{TaskEndReason, TaskStatus};
        let ids: Vec<&str> = tasks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["shell1", "agent1", "done1"]);
        for t in tasks {
            if t.id == "done1" {
                assert_eq!(
                    (t.status, t.end_reason),
                    (TaskStatus::Completed, None),
                    "a finished task stays as it ended"
                );
            } else {
                assert_eq!(
                    (t.status, t.end_reason),
                    (TaskStatus::Stopped, Some(TaskEndReason::SessionEnded)),
                    "{} was running when the session was stopped",
                    t.id
                );
            }
        }
    }

    #[tokio::test]
    async fn stopping_a_session_tells_its_attached_client_that_every_running_task_ended_with_the_session(
    ) {
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(
            &mut reap.0,
            "cody-1",
            &format!(
                "{} cat >/dev/null",
                print_lines(&running_and_finished_task_lines())
            ),
        );
        let shared = reap.0.sessions["cody-1"].shared.clone();
        eventually(
            "the registry to hold the three tasks, the last one finished",
            || {
                let tasks = shared.tasks.current().0.tasks.clone();
                (tasks.len() == 3 && tasks[2].status == crate::ipc::protocol::TaskStatus::Completed)
                    .then_some(())
            },
        )
        .await;
        let mut crx = client(&reap.0, "c1");
        reap.0.attach("cody-1", "c1").unwrap();
        queued(&mut crx); // the attach replay
        let mut events = shared.event_tx.subscribe();

        reap.0.stop("cody-1");

        let final_list = loop {
            if let ServerMsg::SessionTasks { tag, tasks, .. } = next_client_frame(&mut crx).await {
                assert_eq!(tag, "cody-1");
                break tasks;
            }
        };
        assert_running_tasks_ended_with_the_session(&final_list);

        // The child's stdout then closes and the reader reports the exit: the client must not
        // be told anything that contradicts what it was just told.
        wait_for_reader_eof(&mut events).await;
        for frame in queued(&mut crx) {
            if let ServerMsg::SessionTasks { tasks, .. } = frame {
                assert_eq!(
                    tasks, final_list,
                    "a later task list must not differ from the final one"
                );
            }
        }
    }

    #[tokio::test]
    async fn restarting_a_session_first_tells_its_attached_client_its_running_tasks_ended() {
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("ran-once");
        // The tasks are only reported by the first process; the restarted one reports none.
        let script = format!(
            "if [ ! -e '{m}' ]; then : > '{m}'; {} fi; cat >/dev/null",
            print_lines(&running_and_finished_task_lines()),
            m = marker.display()
        );
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(&mut reap.0, "cody-1", &script);
        let shared = reap.0.sessions["cody-1"].shared.clone();
        eventually(
            "the registry to hold the three tasks, the last one finished",
            || {
                let tasks = shared.tasks.current().0.tasks.clone();
                (tasks.len() == 3 && tasks[2].status == crate::ipc::protocol::TaskStatus::Completed)
                    .then_some(())
            },
        )
        .await;
        let mut crx = client(&reap.0, "c1");
        reap.0.attach("cody-1", "c1").unwrap();
        queued(&mut crx);

        reap.0.restart("cody-1").unwrap();

        let mut lists = vec![];
        while lists.last().is_none_or(|l: &Vec<_>| !l.is_empty()) {
            if let ServerMsg::SessionTasks { tasks, .. } = next_client_frame(&mut crx).await {
                lists.push(tasks);
            }
        }
        assert!(
            lists.len() >= 2,
            "the old session's last list, then the new session's: {lists:?}"
        );
        assert_running_tasks_ended_with_the_session(&lists[0]);
        assert!(
            lists.last().unwrap().is_empty(),
            "the restarted session starts with no tasks"
        );
    }

    // ── network clients do not keep the preview poller running ───────────────

    #[tokio::test]
    async fn a_network_client_alone_does_not_start_task_previews_and_a_local_client_does() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"first\n");
        rig.start_shell("b7k2m9x1a");
        let mut net = client(&rig.reap.0, "net1");

        rig.reap.0.attach_network("cody-1", "net1").unwrap();

        // It is attached like any other client: it is told the tasks.
        let kinds: Vec<&str> = queued(&mut net).iter().map(frame_kind).collect();
        assert!(kinds.contains(&"tasks"), "{kinds:?}");
        rig.expect_no_preview("only a network client is attached: nothing is read for it")
            .await;
        assert_eq!(rig.published_preview("b7k2m9x1a"), None);

        // A local client attaches: the poller starts.
        let _local = client(&rig.reap.0, "loc1");
        rig.reap.0.attach("cody-1", "loc1").unwrap();
        rig.expect_preview("b7k2m9x1a", "first").await;
    }

    #[tokio::test]
    async fn the_last_local_client_detaching_stops_task_previews_even_though_a_network_client_remains(
    ) {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"one\n");
        let _net = client(&rig.reap.0, "net1");
        let _local = client(&rig.reap.0, "loc1");
        rig.reap.0.attach_network("cody-1", "net1").unwrap();
        rig.reap.0.attach("cody-1", "loc1").unwrap();
        rig.start_shell("b7k2m9x1a");
        rig.expect_preview("b7k2m9x1a", "one").await;

        rig.reap.0.detach("cody-1", "loc1");
        tokio::time::sleep(PREVIEW_INTERVAL + Duration::from_millis(500)).await; // an in-flight cycle ends
        while rig.rx.try_recv().is_ok() {}
        rig.append_output("b7k2m9x1a", b"two\n");

        rig.expect_no_preview("only the network client is left: nobody is looking")
            .await;
        let _again = client(&rig.reap.0, "loc2");
        rig.reap.0.attach("cody-1", "loc2").unwrap();
        rig.expect_preview("b7k2m9x1a", "two").await;
    }

    #[tokio::test]
    async fn a_local_client_disconnecting_stops_task_previews_even_though_a_network_client_remains()
    {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"one\n");
        let _net = client(&rig.reap.0, "net1");
        let _local = client(&rig.reap.0, "loc1");
        rig.reap.0.attach_network("cody-1", "net1").unwrap();
        rig.reap.0.attach("cody-1", "loc1").unwrap();
        rig.start_shell("b7k2m9x1a");
        rig.expect_preview("b7k2m9x1a", "one").await;

        rig.reap.0.on_client_disconnect("loc1");
        tokio::time::sleep(PREVIEW_INTERVAL + Duration::from_millis(500)).await;
        while rig.rx.try_recv().is_ok() {}
        rig.append_output("b7k2m9x1a", b"two\n");

        rig.expect_no_preview("only the network client is left: nobody is looking")
            .await;
    }

    #[tokio::test]
    async fn a_network_client_leaving_does_not_stop_task_previews_for_the_local_client() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("b7k2m9x1a", b"one\n");
        let _net = client(&rig.reap.0, "net1");
        let _local = client(&rig.reap.0, "loc1");
        rig.reap.0.attach_network("cody-1", "net1").unwrap();
        rig.reap.0.attach("cody-1", "loc1").unwrap();
        rig.start_shell("b7k2m9x1a");
        rig.expect_preview("b7k2m9x1a", "one").await;

        rig.reap.0.on_client_disconnect("net1");
        rig.append_output("b7k2m9x1a", b"two\n");

        rig.expect_preview("b7k2m9x1a", "two").await;
    }

    #[tokio::test]
    async fn a_restart_keeps_a_network_client_a_network_client() {
        let dir = tempfile::tempdir().unwrap();
        let (gate, reply, fail, log) = (
            dir.path().join("gate"),
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(&reply, output_reply("from the CLI\n")).unwrap();
        let lines = vec![task_line(
            "task_started",
            serde_json::json!({"task_id": "shell1", "description": "Run it", "task_type": "local_bash", "is_backgrounded": true}),
        )];
        let mut reap = Reap(SessionManager::with_store_path(tmp_store()));
        spawn_stub(
            &mut reap.0,
            "cody-1",
            &answering_stub(Some(&gate), &lines, &reply, &fail, &log),
        );
        let _net = client(&reap.0, "net1");
        reap.0.attach_network("cody-1", "net1").unwrap();

        reap.0.restart("cody-1").unwrap();
        std::fs::write(&gate, "").unwrap(); // the restarted CLI now reports its task
        let shared = reap.0.sessions["cody-1"].shared.clone();
        eventually("the task to be registered", || {
            (shared.tasks.current().0.tasks.len() == 1).then_some(())
        })
        .await;

        // The task has no output file, so any poll would ask the CLI: it is never asked.
        tokio::time::sleep(PREVIEW_INTERVAL * 2 + Duration::from_millis(500)).await;
        assert!(
            control_log(&log).is_empty(),
            "a network client attached again by the restart started the poller: {:?}",
            control_log(&log)
        );

        let _local = client(&reap.0, "loc1");
        reap.0.attach("cody-1", "loc1").unwrap();
        eventually(
            "the CLI to be asked once a local client is attached",
            || (!control_log(&log).is_empty()).then_some(()),
        )
        .await;
    }

    // ── housekeeping tasks are not polled ────────────────────────────────────

    #[tokio::test]
    async fn an_ambient_or_skip_transcript_task_is_neither_read_from_a_file_nor_asked_of_the_cli() {
        let dir = tempfile::tempdir().unwrap();
        let (reply, fail, log) = (
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(&reply, output_reply("from the CLI\n")).unwrap();
        let mut rig = preview_rig("cody-1", &answering_stub(None, &[], &reply, &fail, &log));
        for id in ["hk-ambient", "hk-skip", "hk-ended", "live-file"] {
            rig.write_output(id, format!("{id} line\n").as_bytes());
        }
        rig.shared.tasks.set_clients(1);
        let hk = |id: &str, task_type: &str, flag: &str| {
            let mut body = serde_json::json!({"task_id": id, "description": "watcher", "task_type": task_type});
            body[flag] = serde_json::json!(true);
            rig.feed("task_started", body);
        };
        hk("hk-ambient", "local_bash", "ambient"); // has a file
        hk("hk-skip", "monitor_mcp", "skip_transcript"); // has a file
        hk("hk-nofile", "local_bash", "ambient"); // would be asked of the CLI
        hk("hk-ended", "local_bash", "ambient");
        rig.feed(
            "task_notification",
            serde_json::json!({"task_id": "hk-ended", "status": "completed"}),
        ); // owed a final read, were it activity
           // Ordinary tasks, as controls: one with a file, one only the CLI can tell about.
        rig.start_shell("live-file");
        rig.start_shell("live-nofile");

        rig.expect_preview("live-file", "live-file line").await;
        rig.expect_preview("live-nofile", "from the CLI").await;
        rig.expect_no_preview("housekeeping tasks are not read")
            .await;

        for id in ["hk-ambient", "hk-skip", "hk-nofile", "hk-ended"] {
            assert_eq!(
                rig.published_preview(id),
                None,
                "{id} is housekeeping and must not be previewed"
            );
        }
        let asked = control_log(&log);
        assert!(!asked.is_empty());
        assert!(
            asked
                .iter()
                .all(|r| r["request"]["task_id"] == "live-nofile"),
            "the CLI was asked about something else: {asked:?}"
        );
    }

    // ── the CLI fallback backs off ───────────────────────────────────────────

    #[tokio::test]
    async fn a_cli_that_refuses_get_task_output_is_not_asked_again_and_file_previews_carry_on() {
        let dir = tempfile::tempdir().unwrap();
        let (reply, fail, log) = (
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(&reply, output_reply("never used\n")).unwrap();
        std::fs::write(&fail, "").unwrap(); // every get_task_output is refused
        let mut rig = preview_rig("cody-1", &answering_stub(None, &[], &reply, &fail, &log));
        rig.write_output("with-file", b"one\n");
        rig.shared.tasks.set_clients(1);
        rig.start_shell("no-file");
        rig.start_shell("with-file");

        rig.expect_preview("with-file", "one").await;
        eventually("the CLI to be asked once and refuse", || {
            (!control_log(&log).is_empty()).then_some(())
        })
        .await;
        // Several poll cycles later the file-backed task is still being followed...
        rig.append_output("with-file", b"two\n");
        rig.expect_preview("with-file", "two").await;
        rig.append_output("with-file", b"three\n");
        rig.expect_preview("with-file", "three").await;

        // ...and the refusing CLI was left alone in all of them.
        assert_eq!(
            control_log(&log).len(),
            1,
            "the CLI was asked again straight after refusing: {:?}",
            control_log(&log)
        );
        assert_eq!(rig.published_preview("no-file"), None);
    }

    // ── learning the output root is bounded ──────────────────────────────────

    #[tokio::test]
    async fn an_output_path_that_is_not_this_sessions_does_not_make_its_directory_readable() {
        let dir = tempfile::tempdir().unwrap();
        let (reply, fail, log) = (
            dir.path().join("reply"),
            dir.path().join("fail"),
            dir.path().join("log"),
        );
        std::fs::write(&reply, output_reply("")).unwrap();
        std::fs::write(&fail, "").unwrap(); // the CLI fallback fails at once
        let mut rig = preview_rig("cody-1", &answering_stub(None, &[], &reply, &fail, &log));
        // Under a directory the validator was not told about, in another session's folder.
        let foreign = rig
            ._dir
            .path()
            .join("elsewhere")
            .join("-work-repo")
            .join("other-sid")
            .join("tasks");
        std::fs::create_dir_all(&foreign).unwrap();
        std::fs::write(foreign.join("shell1.output"), "SECRET-OUTPUT-FOREIGN\n").unwrap();
        rig.shared.tasks.set_clients(1);
        rig.feed("task_started", serde_json::json!({"task_id": "shell1", "description": "Run it", "task_type": "local_bash"}));

        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "shell1", "status": "completed", "output_file": foreign.join("shell1.output")}),
        );

        eventually("the final read to be attempted", || {
            (!control_log(&log).is_empty()).then_some(())
        })
        .await;
        rig.expect_no_preview("a file in another session's folder must not be read")
            .await;
        assert_eq!(rig.published_preview("shell1"), None);
    }

    #[tokio::test]
    async fn an_output_path_in_this_sessions_own_tasks_folder_teaches_where_the_files_are() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        // The CLI's real root is somewhere the daemon was not told about: only
        // `/tmp/claude-<uid>` can be learned, so use a folder of our own in it.
        let cwd_dir = format!(
            "-work-repo-{}-{}",
            std::process::id(),
            rig._dir.path().file_name().unwrap().to_string_lossy()
        );
        let learned_cwd = PathBuf::from(format!(
            "/tmp/claude-{}",
            crate::ipc::task_output::current_uid()
        ))
        .join(cwd_dir);
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(learned_cwd.clone());
        let learned = learned_cwd.join("stub-sid").join("tasks");
        std::fs::create_dir_all(&learned).unwrap();
        std::fs::write(learned.join("shell1.output"), "from the learned root\n").unwrap();
        rig.shared.tasks.set_clients(1);
        rig.feed("task_started", serde_json::json!({"task_id": "shell1", "description": "Run it", "task_type": "local_bash"}));

        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "shell1", "status": "completed", "output_file": learned.join("shell1.output")}),
        );

        rig.expect_preview("shell1", "from the learned root").await;
    }

    // ── the poller's bookkeeping follows the registry ────────────────────────

    #[tokio::test]
    async fn a_task_that_runs_again_is_followed_while_it_runs_and_read_once_more_when_it_ends() {
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("t1", b"run one\n");
        rig.shared.tasks.set_clients(1);
        let run = |n: u32| serde_json::json!({"task_id": "t1", "run_id": format!("run-{n:03}"), "description": "Run it", "task_type": "local_bash", "is_backgrounded": true});
        rig.feed_as_reader("task_started", run(1));
        rig.expect_preview("t1", "run one").await;
        rig.append_output("t1", b"run one final\n");
        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "t1", "run_id": "run-001", "status": "completed"}),
        );
        rig.expect_preview("t1", "run one final").await;

        // The same task starts a second run.
        rig.write_output("t1", b"run two\n");
        rig.feed_as_reader("task_started", run(2));
        rig.expect_preview("t1", "run two").await;

        // Nobody is polling while the run's last output lands and it ends...
        rig.shared.tasks.set_clients(0);
        tokio::time::sleep(PREVIEW_INTERVAL + Duration::from_millis(500)).await;
        while rig.rx.try_recv().is_ok() {}
        rig.append_output("t1", b"run two final\n");
        rig.feed(
            "task_notification",
            serde_json::json!({"task_id": "t1", "run_id": "run-002", "status": "completed"}),
        );
        // ...so only the final read of an ended task can pick it up.
        rig.shared.tasks.set_clients(1);
        ensure_poller(&rig.shared);

        rig.expect_preview("t1", "run two final").await;
    }

    #[tokio::test]
    async fn a_task_the_registry_forgot_and_that_comes_back_ended_gets_its_final_read() {
        use crate::ipc::tasks::RETAINED_ENDED_TASKS;
        let mut rig = preview_rig("cody-1", STAY_ALIVE);
        rig.write_output("old1", b"first life\n");
        rig.shared.tasks.set_clients(1);
        rig.feed("task_started", serde_json::json!({"task_id": "old1", "description": "Run it", "task_type": "local_bash"}));
        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "old1", "status": "completed"}),
        );
        rig.expect_preview("old1", "first life").await;

        // Later tasks end, and the registry keeps only the most recent ones: old1 is dropped.
        for i in 0..=RETAINED_ENDED_TASKS {
            let id = format!("agent{i:02}");
            rig.feed("task_started", serde_json::json!({"task_id": id, "description": "Survey", "task_type": "local_agent"}));
            rig.feed_as_reader(
                "task_notification",
                serde_json::json!({"task_id": id, "status": "completed"}),
            );
        }
        let (snapshot, _) = rig.shared.tasks.current();
        assert!(
            snapshot.tasks.iter().all(|t| t.id != "old1"),
            "old1 should have been dropped by retention"
        );

        // The id comes back and ends before anything polls (no await in between), with new
        // output: a new task, and it is read once.
        rig.write_output("old1", b"second life\n");
        rig.feed("task_started", serde_json::json!({"task_id": "old1", "description": "Run it", "task_type": "local_bash"}));
        rig.feed_as_reader(
            "task_notification",
            serde_json::json!({"task_id": "old1", "status": "completed"}),
        );

        rig.expect_preview("old1", "second life").await;
    }
}

#[cfg(test)]
mod image_encoding_tests {
    use super::*;

    #[test]
    fn unreadable_image_is_reported_not_silently_dropped() {
        let (ok, failed) = encode_images(&["/definitely/not/here.png".to_string()]);
        assert!(ok.is_empty());
        assert_eq!(failed.len(), 1);
        let note = unreadable_images_note(&failed);
        assert!(note.contains("/definitely/not/here.png"));
        assert!(note.contains("NOT delivered"));
    }

    #[test]
    fn readable_image_is_encoded() {
        let dir = std::env::temp_dir().join(format!("imgenc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("a.png");
        std::fs::write(&f, [1u8, 2, 3]).unwrap();
        let (ok, failed) = encode_images(&[f.to_string_lossy().to_string()]);
        assert_eq!(ok.len(), 1);
        assert!(failed.is_empty());
        assert_eq!(ok[0].media_type, "image/png");
    }
}

/// A session or focus a work send creates or feeds holds work-item content from
/// its first instant, so the manager registers it as sensitive while the
/// server's work-send scope is open, before doing anything else (a service may
/// broadcast about the new focus long before `send` returns).
#[cfg(test)]
mod work_send_scope_tests {
    use super::*;
    use crate::ipc::peer::within_work_send;

    fn focus(tag: &str) -> FocusMeta {
        FocusMeta {
            initial_model: None,
            initial_effort: None,
            tag: tag.into(),
            display_name: "Cody on SECRET".into(),
            agent_name: "cody".into(),
            project_name: None,
            org: None,
            is_built_in: false,
            session_summary: Some("SECRET".into()),
            label: Some("SECRET".into()),
            project_path: None,
            select_for_client: None,
        }
    }

    /// Kills any stub children on drop, even when an assertion fails first:
    /// the test runtime waits for the blocking reader threads, which only end
    /// when their child does.
    struct Reaped(SessionManager);

    impl std::ops::Deref for Reaped {
        type Target = SessionManager;
        fn deref(&self) -> &SessionManager {
            &self.0
        }
    }

    impl std::ops::DerefMut for Reaped {
        fn deref_mut(&mut self) -> &mut SessionManager {
            &mut self.0
        }
    }

    impl Drop for Reaped {
        fn drop(&mut self) {
            self.0.kill_all_on_shutdown();
        }
    }

    fn manager(dir: &tempfile::TempDir) -> Reaped {
        Reaped(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        ))
    }

    /// A session that stays alive and swallows its stdin.
    fn spawn_idle(mgr: &mut SessionManager, tag: &str) {
        let program = PathBuf::from("/bin/sh");
        let args = vec!["-c".to_string(), "cat > /dev/null".to_string()];
        let managed = mgr
            .spawn_managed(
                tag.into(),
                "cody".into(),
                "View".into(),
                None,
                false,
                format!("sid-{tag}"),
                false,
                program.clone(),
                args.clone(),
                Some((program, args)),
            )
            .expect("spawn idle stub");
        mgr.sessions.insert(tag.to_string(), managed);
    }

    #[tokio::test]
    async fn a_focus_added_inside_a_work_send_is_sensitive_at_once_and_one_added_outside_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let tags = mgr.sensitive_tags();

        mgr.add_or_update_focus(focus("cody-ordinary"));
        assert!(!tags.tag_is_sensitive("cody-ordinary"));

        within_work_send(async {
            mgr.add_or_update_focus(focus("cody-derived"));
            assert!(
                tags.tag_is_sensitive("cody-derived"),
                "the tag must be registered by the time add_or_update_focus returns"
            );
        })
        .await;

        assert!(
            tags.tag_is_sensitive("cody-derived"),
            "registration is permanent"
        );
        assert!(!tags.tag_is_sensitive("cody-ordinary"));
        mgr.add_or_update_focus(focus("cody-after"));
        assert!(
            !tags.tag_is_sensitive("cody-after"),
            "the scope ended with the work send"
        );
    }

    #[tokio::test]
    async fn a_message_sent_inside_a_work_send_marks_the_session_sensitive_but_one_sent_outside_does_not(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let tags = mgr.sensitive_tags();
        spawn_idle(&mut mgr, "cody-plain");
        spawn_idle(&mut mgr, "cody-seeded");

        mgr.send_user_message("cody-plain", "hello", &[])
            .expect("send outside the scope");
        assert!(!tags.tag_is_sensitive("cody-plain"));

        within_work_send(async {
            mgr.send_user_message("cody-seeded", "WORK-CONTEXT", &[])
                .expect("send inside the scope");
        })
        .await;
        assert!(tags.tag_is_sensitive("cody-seeded"));
        assert!(!tags.tag_is_sensitive("cody-plain"));
    }

    #[tokio::test]
    async fn a_huey_agent_session_is_sensitive_under_any_tag() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let tags = mgr.sensitive_tags();
        spawn_idle(&mut mgr, "scratch-a");
        spawn_idle(&mut mgr, "scratch-b");

        // Registration comes before the "already alive" early return.
        mgr.spawn_session(
            "scratch-a".into(),
            "Huey".into(),
            "V".into(),
            None,
            None,
            false,
        )
        .expect("existing session");
        mgr.spawn_session(
            "scratch-b".into(),
            "huey:huey".into(),
            "V".into(),
            None,
            None,
            false,
        )
        .expect("existing session");
        assert!(tags.tag_is_sensitive("scratch-a"));
        assert!(tags.tag_is_sensitive("scratch-b"));
    }

    #[tokio::test]
    async fn a_focus_running_the_huey_agent_is_marked_sensitive_under_any_tag() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let tags = mgr.sensitive_tags();

        let mut huey = focus("scratch-huey");
        huey.agent_name = "Huey".into();
        mgr.mark_teri_fred_focuses(&[huey]);
        assert!(tags.tag_is_sensitive("scratch-huey"));

        let mut other = focus("scratch-other");
        other.agent_name = "huey:huey".into();
        mgr.add_or_update_focus(other);
        assert!(tags.tag_is_sensitive("scratch-other"));

        mgr.add_or_update_focus(focus("scratch-cody"));
        assert!(!tags.tag_is_sensitive("scratch-cody"));
    }

    #[tokio::test]
    async fn a_send_inside_a_work_send_registers_the_tag_even_when_the_send_itself_fails() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let tags = mgr.sensitive_tags();

        within_work_send(async {
            let outcome = mgr.send_user_message("cody-not-running", "WORK-CONTEXT", &[]);
            assert!(outcome.is_err(), "there is no such session");
        })
        .await;

        assert!(
            tags.tag_is_sensitive("cody-not-running"),
            "registration comes before anything that can fail, so no frame can slip out first"
        );
    }
}

/// Shutdown and process-group behaviour of session children: a daemon that stops (or a user who
/// stops one session) leaves nothing of the CLI running, background children included.
///
/// Every stub is a `/bin/sh -c <script>` child of the test; a guard stops whatever is left even
/// when an assertion fails first. Scratch files live in a temp dir.
#[cfg(test)]
#[cfg(unix)]
mod orphan_tests {
    use super::*;
    use crate::ipc::orphans::read_ledger_file;
    use std::ops::{Deref, DerefMut};
    use std::os::unix::fs::PermissionsExt as _;

    const DEADLINE: Duration = Duration::from_secs(10);

    /// Stops every stub on drop (the test runtime waits for the reader threads, which only end
    /// when their child does).
    struct Mgr(SessionManager);

    impl Deref for Mgr {
        type Target = SessionManager;
        fn deref(&self) -> &SessionManager {
            &self.0
        }
    }

    impl DerefMut for Mgr {
        fn deref_mut(&mut self) -> &mut SessionManager {
            &mut self.0
        }
    }

    impl Drop for Mgr {
        fn drop(&mut self) {
            self.0
                .kill_all_on_shutdown_with_grace(Duration::from_millis(200));
        }
    }

    fn manager(dir: &tempfile::TempDir) -> Mgr {
        Mgr(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        ))
    }

    fn ledger_file(dir: &tempfile::TempDir) -> PathBuf {
        ledger_path_beside(&dir.path().join("sessions.json"))
    }

    /// Start `script` as the session's CLI (`/bin/sh -c <script>`).
    fn start(mgr: &mut SessionManager, tag: &str, script: &str) -> u32 {
        let program = PathBuf::from("/bin/sh");
        let args = vec!["-c".to_string(), script.to_string()];
        let managed = mgr
            .spawn_managed(
                tag.to_string(),
                "agent".into(),
                "View".into(),
                None,
                false,
                format!("sid-{tag}"),
                false,
                program.clone(),
                args.clone(),
                Some((program, args)),
            )
            .expect("spawn stub");
        let pid = managed.child.id();
        mgr.sessions.insert(tag.to_string(), managed);
        pid
    }

    fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
        let deadline = Instant::now() + DEADLINE;
        while !f() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn read_pid(file: &Path) -> Option<u32> {
        std::fs::read_to_string(file).ok()?.trim().parse().ok()
    }

    /// The process state letters, or `None` when there is no such process.
    fn state_of(pid: u32) -> Option<String> {
        let out = std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
        (out.status.success() && !text.is_empty()).then_some(text)
    }

    /// Gone, or a zombie waiting for init (as good as gone).
    fn is_gone(pid: u32) -> bool {
        state_of(pid).is_none_or(|s| s.starts_with('Z'))
    }

    fn pgid_of(pid: u32) -> i32 {
        // SAFETY: plain syscall.
        unsafe { libc::getpgid(pid as libc::pid_t) }
    }

    /// A CLI that starts a background child, one that ignores SIGTERM, and waits. On SIGTERM it
    /// writes `term` and exits, the way a CLI that stops its own tasks would.
    fn cli_with_children(dir: &Path) -> (String, PathBuf, PathBuf, PathBuf, PathBuf) {
        let term = dir.join("cli.term");
        let bg = dir.join("bg.pid");
        let stubborn = dir.join("stubborn.pid");
        let ready = dir.join("cli.ready");
        let script = format!(
            "trap 'echo got-term > {term}; exit 0' TERM\n\
             sleep 300 &\n\
             echo $! > {bg}\n\
             ( trap '' TERM; exec sleep 300 ) &\n\
             echo $! > {stubborn}\n\
             echo ready > {ready}\n\
             while :; do wait; done\n",
            term = term.display(),
            bg = bg.display(),
            stubborn = stubborn.display(),
            ready = ready.display(),
        );
        (script, term, bg, stubborn, ready)
    }

    /// A CLI that ignores SIGTERM and says when it is up.
    fn stubborn_cli(ready: &Path) -> String {
        format!(
            "trap '' TERM\necho ready > {}\nwhile :; do sleep 1; done\n",
            ready.display()
        )
    }

    // ── RO-1: shutdown leaves nothing behind ──────────────────────────────────

    #[tokio::test]
    async fn shutdown_asks_the_cli_to_stop_and_leaves_none_of_its_background_children_running() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let (script, term, bg, stubborn, ready) = cli_with_children(dir.path());
        let cli = start(&mut mgr, "t", &script);
        wait_until("the CLI to be up", || ready.exists());
        let (bg, stubborn) = (read_pid(&bg).unwrap(), read_pid(&stubborn).unwrap());
        assert!(
            !is_gone(bg) && !is_gone(stubborn) && !is_gone(cli),
            "setup: all three are running"
        );
        let grace = Duration::from_secs(1);

        let started = Instant::now();
        mgr.kill_all_on_shutdown_with_grace(grace);
        let took = started.elapsed();

        assert!(
            term.exists(),
            "the CLI was sent SIGTERM and got to run its own handler"
        );
        wait_until("the CLI to be gone", || is_gone(cli));
        wait_until("the background child to be gone", || is_gone(bg));
        wait_until("the SIGTERM-ignoring child to be gone", || {
            is_gone(stubborn)
        });
        assert!(
            took < grace + Duration::from_millis(1500),
            "shutdown took {took:?} with a {grace:?} grace"
        );
    }

    #[tokio::test]
    async fn a_cli_that_stops_when_asked_is_not_made_to_wait_out_the_grace() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let term = dir.path().join("term");
        let ready = dir.path().join("ready");
        let script = format!(
            "trap 'echo got-term > {}; exit 0' TERM\necho ready > {}\nwhile :; do wait; sleep 1; done\n",
            term.display(),
            ready.display()
        );
        let cli = start(&mut mgr, "t", &script);
        wait_until("the CLI to be up", || ready.exists());

        let started = Instant::now();
        mgr.kill_all_on_shutdown_with_grace(Duration::from_secs(10));
        let took = started.elapsed();

        assert!(
            took < Duration::from_secs(5),
            "a cooperative CLI should be done in about a second, took {took:?}"
        );
        assert!(term.exists(), "stopped by SIGTERM, not by a kill");
        wait_until("the CLI to be gone", || is_gone(cli));
    }

    // ── RO-4: shutdown is bounded, shared, idempotent and tidy ────────────────

    #[tokio::test]
    async fn shutdown_is_bounded_by_the_grace_even_when_the_cli_ignores_sigterm_and_clears_the_ledger(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let ready = dir.path().join("ready");
        let cli = start(&mut mgr, "t", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());
        assert!(
            ledger_file(&dir).exists(),
            "setup: the ledger is there while the session runs"
        );
        let grace = Duration::from_secs(1);

        let started = Instant::now();
        mgr.kill_all_on_shutdown_with_grace(grace);
        let took = started.elapsed();

        assert!(
            took < grace + Duration::from_millis(1500),
            "shutdown took {took:?} with a {grace:?} grace"
        );
        assert!(
            took >= Duration::from_millis(900),
            "SIGTERM was given its grace first, took {took:?}"
        );
        wait_until("the CLI to be gone", || is_gone(cli));
        assert!(
            !ledger_file(&dir).exists(),
            "a completed shutdown leaves no ledger"
        );
    }

    #[tokio::test]
    async fn several_sessions_share_one_grace_instead_of_each_getting_their_own() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let mut pids = Vec::new();
        for n in 0..3 {
            let ready = dir.path().join(format!("ready-{n}"));
            pids.push(start(&mut mgr, &format!("t{n}"), &stubborn_cli(&ready)));
            wait_until("the CLI to be up", || ready.exists());
        }
        let grace = Duration::from_secs(1);

        let started = Instant::now();
        mgr.kill_all_on_shutdown_with_grace(grace);
        let took = started.elapsed();

        assert!(
            took < grace + Duration::from_millis(1500),
            "three sessions took {took:?} with a {grace:?} grace"
        );
        for pid in pids {
            wait_until("the CLI to be gone", || is_gone(pid));
        }
    }

    #[tokio::test]
    async fn a_second_shutdown_does_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let ready = dir.path().join("ready");
        start(&mut mgr, "t", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());
        mgr.kill_all_on_shutdown_with_grace(Duration::from_millis(300));

        let started = Instant::now();
        mgr.kill_all_on_shutdown_with_grace(Duration::from_secs(5));
        mgr.kill_all_on_shutdown();

        assert!(
            started.elapsed() < Duration::from_millis(500),
            "nothing is left to wait for"
        );
        assert!(!ledger_file(&dir).exists());
    }

    #[tokio::test]
    async fn shutdown_with_no_sessions_is_harmless() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);

        mgr.kill_all_on_shutdown_with_grace(Duration::from_secs(5));
        mgr.kill_all_on_shutdown();
    }

    #[tokio::test]
    async fn a_session_whose_cli_already_exited_does_not_trouble_shutdown() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let cli = start(&mut mgr, "gone", "exit 0");
        wait_until("the CLI to have exited", || is_gone(cli));
        let ready = dir.path().join("ready");
        let other = start(&mut mgr, "up", &stubborn_cli(&ready));
        wait_until("the other CLI to be up", || ready.exists());

        mgr.kill_all_on_shutdown_with_grace(Duration::from_millis(500));

        wait_until("the running CLI to be gone", || is_gone(other));
        assert!(!ledger_file(&dir).exists());
    }

    #[tokio::test]
    async fn shutdown_after_the_only_session_was_stopped_leaves_no_session_in_the_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let ready = dir.path().join("ready");
        start(&mut mgr, "t", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());
        mgr.stop("t");

        mgr.kill_all_on_shutdown_with_grace(Duration::from_millis(300));

        let leftover = read_ledger_file(&ledger_file(&dir))
            .map(|f| f.children.len())
            .unwrap_or(0);
        assert_eq!(leftover, 0, "nothing the daemon started is still recorded");
    }

    // ── RO-4: what is on disk while sessions run ──────────────────────────────

    #[tokio::test]
    async fn while_a_session_runs_its_pid_and_group_are_on_disk_in_a_file_only_the_user_can_read() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        assert!(
            !ledger_file(&dir).exists(),
            "nothing is recorded before a session exists"
        );
        let ready = dir.path().join("ready");
        let cli = start(&mut mgr, "t", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());

        // The state a daemon killed at this instant would leave for the next start.
        let path = ledger_file(&dir);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let file = read_ledger_file(&path).expect("a readable ledger");
        assert_eq!(file.daemon_pid, std::process::id());
        let rec = file
            .children
            .iter()
            .find(|c| c.pid == cli)
            .expect("the running session is recorded");
        assert_eq!(rec.pgid, cli, "recorded with the group it leads");
        assert!(rec.own_group);
        assert_eq!(file.children.len(), 1);

        mgr.kill_all_on_shutdown_with_grace(Duration::from_millis(300));
        assert!(!path.exists(), "gone after a clean shutdown");
    }

    #[tokio::test]
    async fn what_the_manager_records_is_something_the_next_daemons_sweep_accepts() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let ready = dir.path().join("ready");
        let cli = start(&mut mgr, "t", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());
        // Sweep a copy, so the manager's own file is untouched.
        let copy = dir.path().join("copy").join("child-processes.json");
        std::fs::create_dir_all(copy.parent().unwrap()).unwrap();
        std::fs::copy(ledger_file(&dir), &copy).unwrap();

        let report = crate::ipc::orphans::sweep(&copy, Duration::from_millis(300));

        assert_eq!(
            report.terminated,
            vec![cli],
            "the record verifies against the live process"
        );
        assert_eq!(report.dropped, 0);
        wait_until("the CLI to be gone", || is_gone(cli));
    }

    // ── RO-3: every session leads its own group; stop reaches the whole group ──

    #[tokio::test]
    async fn every_session_leads_its_own_process_group_not_the_daemons() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let ready = dir.path().join("ready");
        let cli = start(&mut mgr, "plain", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());

        assert_eq!(
            pgid_of(cli),
            cli as i32,
            "the child leads a group named after itself"
        );
        // SAFETY: plain syscall.
        let ours = unsafe { libc::getpgrp() };
        assert_ne!(
            pgid_of(cli),
            ours,
            "and it is not the group the daemon (or test runner) is in"
        );
    }

    #[tokio::test]
    async fn a_restricted_session_leads_its_own_process_group_too() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        mgr.restrict_tag(
            "boxed",
            SessionRestrictions {
                builtin_tools: vec!["ToolSearch".into()],
                allowed_tools: vec!["ToolSearch".into()],
                max_budget_usd: Some(1.0),
                model: None,
            },
        );
        let ready = dir.path().join("ready");
        let cli = start(&mut mgr, "boxed", &stubborn_cli(&ready));
        wait_until("the CLI to be up", || ready.exists());

        assert_eq!(pgid_of(cli), cli as i32);
        // SAFETY: plain syscall.
        assert_ne!(pgid_of(cli), unsafe { libc::getpgrp() });
    }

    #[tokio::test]
    async fn stopping_one_plain_session_ends_its_background_child_and_leaves_the_other_session_running(
    ) {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let ready = dir.path().join("ready");
        let script = format!(
            "sleep 300 &\necho $! > {}\necho ready > {}\nwait\n",
            bg_file.display(),
            ready.display()
        );
        let cli = start(&mut mgr, "stopped", &script);
        let other_ready = dir.path().join("other-ready");
        let other = start(&mut mgr, "kept", &stubborn_cli(&other_ready));
        wait_until("both CLIs to be up", || {
            ready.exists() && other_ready.exists()
        });
        let bg = read_pid(&bg_file).unwrap();
        assert!(!is_gone(bg));

        mgr.stop("stopped");

        wait_until("the stopped CLI to be gone", || is_gone(cli));
        wait_until("its background child to be gone", || is_gone(bg));
        assert!(!is_gone(other), "the other session is not affected");
        let listed: Vec<u32> = read_ledger_file(&ledger_file(&dir))
            .map(|f| f.children.iter().map(|c| c.pid).collect())
            .unwrap_or_default();
        assert!(
            !listed.contains(&cli),
            "a stopped session is no longer in the ledger: {listed:?}"
        );
        assert!(
            listed.contains(&other),
            "the running one still is: {listed:?}"
        );
    }

    // ── a reaped CLI's pid is no longer ours to signal; its ledger entry goes ──

    /// Every pid listed (one per line) in `file`.
    fn read_pids(file: &Path) -> Vec<u32> {
        std::fs::read_to_string(file)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| l.trim().parse().ok())
            .collect()
    }

    /// SIGKILLs every pid listed in a file when dropped, so a failing assertion cannot leave
    /// a `sleep 300` behind.
    struct KillListed(PathBuf);

    impl Drop for KillListed {
        fn drop(&mut self) {
            for pid in read_pids(&self.0) {
                // SAFETY: plain syscall; the pids are this test's own background sleeps.
                unsafe {
                    libc::kill(pid as libc::pid_t, libc::SIGKILL);
                }
            }
        }
    }

    /// A CLI that leaves a background `sleep` in its group (not holding the CLI's stdio, so
    /// the CLI's exit is noticed) and then exits with `code`.
    fn cli_that_exits_leaving_a_sleeper(bg_file: &Path, code: i32) -> String {
        format!(
            "sleep 300 </dev/null >/dev/null 2>&1 &\necho $! >> {}\nexit {code}\n",
            bg_file.display()
        )
    }

    /// Wait until the CLI has exited and the manager has noticed.
    fn wait_for_exit_noticed(mgr: &SessionManager, tag: &str, cli: u32) {
        wait_until("the CLI to have exited", || is_gone(cli));
        wait_until("the manager to notice the exit", || {
            mgr.sessions
                .get(tag)
                .is_some_and(|s| s.shared.exited.load(Ordering::SeqCst))
        });
    }

    fn listed_in_ledger(dir: &tempfile::TempDir) -> Vec<u32> {
        read_ledger_file(&ledger_file(dir))
            .map(|f| f.children.iter().map(|c| c.pid).collect())
            .unwrap_or_default()
    }

    /// Crash a session whose CLI left a background child, and let the supervisor reap it (a
    /// client is attached and the exit is non-zero, so it waits out a backoff). Returns the
    /// CLI pid and the background child's.
    fn crash_and_reap_leaving_a_sleeper(mgr: &mut Mgr, bg_file: &Path) -> (u32, u32) {
        let cli = start(mgr, "t", &cli_that_exits_leaving_a_sleeper(bg_file, 1));
        mgr.sessions
            .get_mut("t")
            .unwrap()
            .attached_clients
            .insert("c1".into());
        wait_until("the background child to be started", || {
            read_pid(bg_file).is_some()
        });
        let bg = read_pid(bg_file).unwrap();
        wait_for_exit_noticed(mgr, "t", cli);

        mgr.reap_and_recover();

        let s = mgr
            .sessions
            .get_mut("t")
            .expect("still tracked, in backoff");
        assert!(
            s.restart_at.is_some(),
            "setup: the crashed session is waiting out a backoff"
        );
        assert!(
            matches!(s.child.try_wait(), Ok(Some(_))),
            "setup: the CLI has been reaped"
        );
        assert!(
            !is_gone(bg),
            "setup: the CLI's background child outlives it"
        );
        (cli, bg)
    }

    #[tokio::test]
    async fn stopping_a_session_whose_cli_was_already_reaped_signals_nothing_in_its_old_group() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let (_cli, bg) = crash_and_reap_leaving_a_sleeper(&mut mgr, &bg_file);

        mgr.stop("t");

        // A kill is delivered at once, but give a wrongly-sent one time to show.
        std::thread::sleep(Duration::from_millis(300));
        assert!(
            !is_gone(bg),
            "the old pid is free to be reused, so nothing in its group may be signalled"
        );
    }

    #[tokio::test]
    async fn stopping_a_session_whose_cli_exited_but_was_not_reaped_still_kills_its_group() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let cli = start(
            &mut mgr,
            "t",
            &cli_that_exits_leaving_a_sleeper(&bg_file, 1),
        );
        wait_until("the background child to be started", || {
            read_pid(&bg_file).is_some()
        });
        let bg = read_pid(&bg_file).unwrap();
        // The reader has seen the CLI's exit; nothing has waited for it, so it is a zombie.
        wait_until("the manager to notice the exit", || {
            mgr.sessions
                .get("t")
                .is_some_and(|s| s.shared.exited.load(Ordering::SeqCst))
        });
        assert!(
            child_unreaped(cli),
            "setup: the exited CLI has not been reaped"
        );
        assert!(
            !is_gone(bg),
            "setup: the CLI's background child outlives it"
        );

        mgr.stop("t");

        wait_until(
            "the background child to be killed with the CLI's group",
            || is_gone(bg),
        );
    }

    #[tokio::test]
    async fn restarting_a_session_whose_cli_was_already_reaped_signals_nothing_in_its_old_group() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let (_cli, bg) = crash_and_reap_leaving_a_sleeper(&mut mgr, &bg_file);

        mgr.restart("t").expect("restart");

        std::thread::sleep(Duration::from_millis(300));
        assert!(
            !is_gone(bg),
            "the old pid is free to be reused, so nothing in its group may be signalled"
        );
    }

    // A reaped child's pid can be handed to another child of the daemon. `waitid`
    // then succeeds for that stranger, so the OS-level probe alone would call the
    // pid "ours and unreaped". These tests make the probe say exactly that
    // (`|_| true`): a session this manager has reaped must still signal nothing.

    #[tokio::test]
    async fn stopping_a_reaped_session_signals_nothing_even_if_its_pid_looks_live_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let (_cli, bg) = crash_and_reap_leaving_a_sleeper(&mut mgr, &bg_file);
        mgr.sessions.get_mut("t").unwrap().unreaped_probe = |_| true;

        mgr.stop("t");

        std::thread::sleep(Duration::from_millis(300));
        assert!(
            !is_gone(bg),
            "a reaped pid may now belong to a stranger, so nothing in its group may be signalled"
        );
    }

    #[tokio::test]
    async fn restarting_a_reaped_session_signals_nothing_even_if_its_pid_looks_live_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let (_cli, bg) = crash_and_reap_leaving_a_sleeper(&mut mgr, &bg_file);
        mgr.sessions.get_mut("t").unwrap().unreaped_probe = |_| true;

        mgr.restart("t").expect("restart");

        std::thread::sleep(Duration::from_millis(300));
        assert!(
            !is_gone(bg),
            "a reaped pid may now belong to a stranger, so nothing in its group may be signalled"
        );
    }

    #[tokio::test]
    async fn a_reaped_session_has_no_stop_target_even_if_its_pid_looks_live_again() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let _cleanup = KillListed(bg_file.clone());
        let (_cli, _bg) = crash_and_reap_leaving_a_sleeper(&mut mgr, &bg_file);
        let s = mgr.sessions.get_mut("t").unwrap();
        s.unreaped_probe = |_| true;

        assert!(s.stop_target().is_none());
    }

    #[tokio::test]
    async fn stopping_a_live_session_ends_its_background_child() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let ready = dir.path().join("ready");
        let _cleanup = KillListed(bg_file.clone());
        let script = format!(
            "sleep 300 &\necho $! >> {}\necho ready > {}\nwait\n",
            bg_file.display(),
            ready.display()
        );
        let cli = start(&mut mgr, "t", &script);
        wait_until("the CLI to be up", || ready.exists());
        let bg = read_pids(&bg_file)[0];
        assert!(!is_gone(bg));

        mgr.stop("t");

        wait_until("the CLI to be gone", || is_gone(cli));
        wait_until("the CLI's background child to be gone", || is_gone(bg));
    }

    #[tokio::test]
    async fn restarting_a_live_session_ends_its_background_child() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let bg_file = dir.path().join("bg.pid");
        let ready = dir.path().join("ready");
        let _cleanup = KillListed(bg_file.clone());
        let script = format!(
            "sleep 300 &\necho $! >> {}\necho ready > {}\nwait\n",
            bg_file.display(),
            ready.display()
        );
        let cli = start(&mut mgr, "t", &script);
        wait_until("the CLI to be up", || ready.exists());
        let bg = read_pids(&bg_file)[0];
        assert!(!is_gone(bg));

        mgr.restart("t").expect("restart");

        wait_until("the old CLI to be gone", || is_gone(cli));
        wait_until("the old CLI's background child to be gone", || is_gone(bg));
    }

    #[tokio::test]
    async fn a_crashed_cli_that_the_supervisor_has_reaped_is_no_longer_in_the_ledger() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let cli = start(&mut mgr, "t", "exit 1");
        mgr.sessions
            .get_mut("t")
            .unwrap()
            .attached_clients
            .insert("c1".into());
        wait_for_exit_noticed(&mgr, "t", cli);
        assert!(
            listed_in_ledger(&dir).contains(&cli),
            "setup: the unreaped CLI is still recorded"
        );

        mgr.reap_and_recover();

        assert!(
            mgr.sessions.get("t").unwrap().restart_at.is_some(),
            "setup: waiting out a backoff, not respawned"
        );
        let listed = listed_in_ledger(&dir);
        assert!(
            !listed.contains(&cli),
            "a reaped pid is free for reuse and must not stay listed: {listed:?}"
        );
    }

    #[tokio::test]
    async fn a_cli_replaced_after_a_clean_exit_leaves_the_ledger_without_the_old_pid() {
        let dir = tempfile::tempdir().unwrap();
        let mut mgr = manager(&dir);
        let cli = start(&mut mgr, "t", "exit 0");
        mgr.sessions
            .get_mut("t")
            .unwrap()
            .attached_clients
            .insert("c1".into());
        wait_for_exit_noticed(&mgr, "t", cli);

        mgr.reap_and_recover();

        let listed = listed_in_ledger(&dir);
        assert!(
            !listed.contains(&cli),
            "the replaced CLI's pid must not stay listed: {listed:?}"
        );
    }
}
// ── H6-10: Huey's persona is appended to the system prompt ───────────────────

#[cfg(test)]
mod huey_persona_args_tests {
    use super::*;
    use std::path::Path;

    fn guard() -> String {
        crate::approvals::guard::hook_settings_json(Path::new("/opt/x/nostromo-guard"))
    }

    fn value_after<'a>(args: &'a [String], flag: &str) -> Vec<&'a str> {
        args.windows(2)
            .filter(|w| w[0] == flag)
            .map(|w| w[1].as_str())
            .collect()
    }

    fn assert_huey_args(args: &[String]) {
        assert_eq!(
            value_after(args, "--append-system-prompt"),
            vec![crate::huey::PERSONA],
            "the persona follows --append-system-prompt exactly: {args:?}"
        );
        assert!(
            !args.iter().any(|a| a == "--agent"),
            "no user-level agent file exists for Huey, so there is no --agent: {args:?}"
        );
        assert!(
            args.windows(2).any(|w| w == ["-n", "Huey"]),
            "the view name is still passed: {args:?}"
        );
    }

    #[test]
    fn h6_10_a_huey_session_gets_its_persona_and_no_agent_flag() {
        assert_huey_args(&build_claude_args(
            "huey",
            "Huey",
            false,
            "sid",
            false,
            &guard(),
        ));
    }

    #[test]
    fn h6_10_a_resumed_huey_session_gets_it_too() {
        let args = build_claude_args("huey", "Huey", false, "sid", true, &guard());
        assert_huey_args(&args);
        assert!(
            args.windows(2).any(|w| w == ["--resume", "sid"]),
            "{args:?}"
        );
    }

    #[test]
    fn h6_10_a_remote_control_huey_session_gets_it_too() {
        assert_huey_args(&build_claude_args(
            "huey",
            "Huey",
            true,
            "sid",
            false,
            &guard(),
        ));
    }

    #[test]
    fn h6_10_build_claude_args_with_agrees_for_huey() {
        let plain = build_claude_args("huey", "Huey", false, "sid", false, &guard());
        let with = build_claude_args_with("huey", "Huey", false, "sid", false, None, &guard());
        assert_eq!(plain, with);
        assert_huey_args(&with);
    }

    #[test]
    fn h6_10_huey_is_recognised_by_agent_name_case_and_qualifier() {
        for name in ["Huey", "HUEY", " huey ", "huey:huey"] {
            let args = build_claude_args_with(name, "Huey", false, "sid", false, None, &guard());
            assert_huey_args(&args);
        }
    }

    #[test]
    fn h6_10_other_agents_keep_agent_and_get_no_persona() {
        for name in ["fred", "teri", "cody", "perri", "mother"] {
            let args = build_claude_args(name, "View", false, "sid", false, &guard());
            assert!(
                args.windows(2).any(|w| w == ["--agent", name]),
                "{name}: {args:?}"
            );
            assert!(
                !args.iter().any(|a| a == "--append-system-prompt"),
                "{name} must not get Huey's persona: {args:?}"
            );
        }
    }

    #[test]
    fn h6_10_the_persona_tells_huey_how_to_work() {
        let persona = crate::huey::PERSONA;
        assert!(
            persona.contains("huey.get_report"),
            "reads the report with the tool"
        );
        assert!(
            persona.contains("huey.get_state"),
            "finds the interests file with the tool"
        );
        assert!(persona.to_lowercase().contains("interests"));
        assert!(
            persona.to_lowercase().contains("untrusted"),
            "report and news text is third-party data"
        );
        assert!(
            persona.contains("ordinary session"),
            "it says Huey's focus is an ordinary session"
        );
        assert!(
            persona.to_lowercase().contains("project files"),
            "and that it may read project files when asked"
        );
    }
}
