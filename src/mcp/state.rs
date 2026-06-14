//! Shared state threaded through the MCP server and tool handlers.
//!
//! `McpSharedState` is cheaply cloneable (`Arc`-backed) and safe to pass
//! across task boundaries.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

use tokio::sync::{broadcast, mpsc, watch, RwLock};

use crate::{
    data::{
        fred_calendar::CalendarSnapshot,
        fred_mailbox::MailboxSnapshot,
        perri_pr::PrSnapshot,
        perri_queue::PrQueueSnapshot,
        rate_limits::{BudgetPosture, RateLimits},
        teri_todos::TeriTodosSnapshot,
    },
    event::AppEvent,
    ipc::{pane_registry::PaneRegistry, protocol::ServerMsg, SessionManager},
    mother::{MotherJob, MotherStatus},
};

// ── identity types ─────────────────────────────────────────────────────────────

/// Identity record for a PTY spawned by Nostromo.
///
/// Registered in `McpSharedState::ptys` when a PTY is spawned and removed on
/// `Drop` (or when the view tears down).
#[derive(Debug, Clone)]
pub struct PtyIdentity {
    /// The view that owns this PTY (e.g. `"perri"`, `"fred"`).
    pub view_id: &'static str,
    /// UUID assigned to this specific PTY invocation.
    pub session_id: String,
    /// When the PTY was spawned.
    pub spawned_at: SystemTime,
}

/// Static metadata about a registered view.
#[derive(Debug, Clone)]
pub struct ViewMeta {
    /// Stable lowercase identifier (e.g. `"perri"`).
    pub id: &'static str,
    /// Human-readable title shown in the TUI tab bar.
    pub title: String,
    /// Logical pane ids within this view.
    pub pane_ids: Vec<&'static str>,
}

// ── daemon backend ─────────────────────────────────────────────────────────────

/// Backend for an MCP server hosted **inside `nostromd`** (rather than the TUI).
///
/// The TUI routes pane mutations through `event_tx` → `AppEvent::McpCommand` →
/// its own event loop. That path cannot reach the macOS app, which is a separate
/// process talking to the daemon over IPC. So when the MCP server runs in the
/// daemon, pane tools instead mutate the daemon-owned [`PaneRegistry`] directly
/// (under its mutex) and fan the result out to every connected client as a
/// `ServerMsg` broadcast. `create_focus` additionally spawns a daemon session.
///
/// Cheap to clone — every field is `Arc`/`Sender`-backed.
#[derive(Clone)]
pub struct DaemonMcpBackend {
    /// Per-focus pane-tree registry (the single source of truth for structure).
    pub pane_registry: Arc<Mutex<PaneRegistry>>,
    /// Daemon session manager — `create_focus` spawns sessions through it.
    pub session_mgr: Arc<Mutex<SessionManager>>,
    /// IPC broadcast channel — pane mutations fan out to all clients here.
    pub broadcast_tx: broadcast::Sender<ServerMsg>,
}

// ── shared state ───────────────────────────────────────────────────────────────

/// Cheap-clone shared state passed to all MCP tool handlers.
///
/// Backed by `Arc`s so cloning is O(1).
#[derive(Clone)]
pub struct McpSharedState {
    /// For future mutating tools: post an `AppEvent::McpCommand(...)`.
    pub event_tx: mpsc::UnboundedSender<AppEvent>,

    /// Set when this MCP server is hosted by `nostromd` rather than the TUI.
    /// Pane/focus tools branch on this: `Some` → mutate the daemon registry and
    /// broadcast; `None` → the legacy TUI `event_tx` path.
    pub daemon: Option<DaemonMcpBackend>,

    /// Metadata about every registered view.  Populated once at startup.
    pub views_meta: Arc<RwLock<Vec<ViewMeta>>>,

    /// Live PTY registry: `nostromo_pty_id` → `PtyIdentity`.
    ///
    /// Keys are the `NOSTROMO_PTY_ID` env var values injected at spawn time.
    pub ptys: Arc<RwLock<HashMap<String, PtyIdentity>>>,

    // ── per-view data receivers (Phase 2) ─────────────────────────────────────
    /// Live Perri PR queue snapshot.
    pub perri_queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,

    /// Live Perri current-PR snapshot.
    pub perri_pr_rx: watch::Receiver<Option<PrSnapshot>>,

    /// Live Fred mailbox snapshot.
    pub fred_mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,

    /// Live Fred calendar snapshot.
    pub fred_calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,

    /// Live Teri todos snapshot.
    pub teri_todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>,

    // ── event-mirrored receivers (Phase 2) ────────────────────────────────────
    // These wrap AppEvent-driven data (Mother jobs/status, rate limits, posture)
    // in watch channels so MCP tool handlers can read them without going through
    // the event loop.
    /// Mirror of the most recent `AppEvent::MotherJobs`.
    pub mother_jobs_rx: watch::Receiver<Vec<MotherJob>>,

    /// Mirror of the most recent `AppEvent::MotherStatusline`.
    pub mother_status_rx: watch::Receiver<Option<MotherStatus>>,

    /// Mirror of the most recent `AppEvent::RateLimitsChanged`.
    pub rate_limits_rx: watch::Receiver<Option<RateLimits>>,

    /// Mirror of the most recent `AppEvent::PostureChanged`.
    pub budget_posture_rx: watch::Receiver<Option<BudgetPosture>>,
}

impl McpSharedState {
    /// Construct with all required watch receivers.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        event_tx: mpsc::UnboundedSender<AppEvent>,
        perri_queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
        perri_pr_rx: watch::Receiver<Option<PrSnapshot>>,
        fred_mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
        fred_calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,
        teri_todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>,
        mother_jobs_rx: watch::Receiver<Vec<MotherJob>>,
        mother_status_rx: watch::Receiver<Option<MotherStatus>>,
        rate_limits_rx: watch::Receiver<Option<RateLimits>>,
        budget_posture_rx: watch::Receiver<Option<BudgetPosture>>,
    ) -> Self {
        Self {
            event_tx,
            daemon: None,
            views_meta: Arc::new(RwLock::new(Vec::new())),
            ptys: Arc::new(RwLock::new(HashMap::new())),
            perri_queue_rx,
            perri_pr_rx,
            fred_mailbox_rx,
            fred_calendar_rx,
            teri_todos_rx,
            mother_jobs_rx,
            mother_status_rx,
            rate_limits_rx,
            budget_posture_rx,
        }
    }

    /// Register a spawned PTY.
    pub async fn register_pty(&self, nostromo_pty_id: String, identity: PtyIdentity) {
        self.ptys.write().await.insert(nostromo_pty_id, identity);
    }

    /// Deregister a PTY (called on PTY drop).
    pub async fn deregister_pty(&self, nostromo_pty_id: &str) {
        self.ptys.write().await.remove(nostromo_pty_id);
    }

    /// Construct a minimal `McpSharedState` suitable for unit/integration tests.
    ///
    /// All watch channels are initialised with empty/`None` values.  Tests can
    /// override individual receivers via `watch::channel(...)` before constructing
    /// the state through `Self::new`.
    ///
    /// This is intentionally not `#[cfg(test)]` — integration tests in the
    /// `tests/` directory are compiled as separate crates and need access to it
    /// without `--cfg test` in scope.
    pub fn for_test(event_tx: mpsc::UnboundedSender<AppEvent>) -> Self {
        let (_, perri_queue_rx) = watch::channel(None);
        let (_, perri_pr_rx) = watch::channel(None);
        let (_, fred_mailbox_rx) = watch::channel(None);
        let (_, fred_calendar_rx) = watch::channel(None);
        let (_, teri_todos_rx) = watch::channel(None);
        let (_, mother_jobs_rx) = watch::channel(vec![]);
        let (_, mother_status_rx) = watch::channel(None);
        let (_, rate_limits_rx) = watch::channel(None);
        let (_, budget_posture_rx) = watch::channel(None);
        Self::new(
            event_tx,
            perri_queue_rx,
            perri_pr_rx,
            fred_mailbox_rx,
            fred_calendar_rx,
            teri_todos_rx,
            mother_jobs_rx,
            mother_status_rx,
            rate_limits_rx,
            budget_posture_rx,
        )
    }

    /// Construct an `McpSharedState` for an MCP server hosted inside `nostromd`.
    ///
    /// TUI-only watch channels are initialised empty (the daemon doesn't serve
    /// the TUI's introspection reads through this path). The `event_tx` is wired
    /// to a channel whose receiver is dropped immediately, so any accidental call
    /// to a legacy TUI-only mutator returns `event_loop_closed` *fast* instead of
    /// blocking for the 5 s command timeout. Pane/focus tools branch on
    /// `self.daemon` and never touch `event_tx`.
    pub fn for_daemon(daemon: DaemonMcpBackend) -> Self {
        let (event_tx, _dropped_rx) = mpsc::unbounded_channel();
        let mut state = Self::for_test(event_tx);
        state.daemon = Some(daemon);
        state
    }
}
