//! Daemon-owned terminal panes (local login shells now, remote shells later).
//!
//! [`TerminalManager`] owns every terminal's PTY ([`session`]), its leaf in the
//! focus pane tree, its persistence ([`store`]) and its audit trail
//! ([`audit`]). Who may touch a terminal is decided by [`access`]: every
//! method that writes input, resizes, attaches (reads output), closes or
//! restarts takes an [`OperatorCap`], which only a verified operator-app
//! connection can mint. The one cap-less way in is
//! [`TerminalManager::open_local_for_agent`], which can only start a shell.
//!
//! Output goes only to attached operator connections, through each
//! connection's terminal stream ([`OperatorConn::stream`]); never on the
//! broadcast channel. Metadata (`TerminalState`, `TerminalClosed`) is
//! broadcast under `Topic::Terminal`. See `docs/terminal.md`.

pub mod access;
pub mod agent_api;
pub mod audit;
pub mod ecs;
mod fanout;
pub mod follow;
pub mod launcher;
pub mod redact;
pub mod remote_request;
pub mod session;
pub mod store;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, mpsc};
use tracing::warn;
use uuid::Uuid;

pub use access::OperatorCap;
pub use agent_api::TerminalAgentApi;
use audit::{AuditEvent, AuditLog, RefusalChannel};
use ecs::watch::RemoteWatch;
use ecs::EcsPaths;
use fanout::Fanout;
use launcher::{ConnectFailure, Placement, RemoteLauncher, UnavailableLauncher};
use remote_request::{Decision, RemoteRequests};
use session::{InputError, SignalOps, TerminalSession};
use store::{TerminalRecord, TerminalStore};

use crate::ipc::pane_registry::{PaneError, PaneRegistry, SplitPosition};
use crate::ipc::peer::SensitiveTags;
use crate::ipc::protocol::{
    ClientMsg, PaneContentWire, PaneTree, ServerMsg, TerminalClosedInfo, TerminalInfo,
    TerminalKind, TerminalRequester, TerminalStatus, TerminalTarget,
};

/// Frames for one connection's terminal stream, queued together (a replay
/// is one batch, so it is never half-queued).
pub type StreamBatch = Vec<ServerMsg>;

/// Batches a connection's terminal stream holds before it counts as lagging.
pub const STREAM_CAPACITY: usize = 256;

/// Test hook: told how long after a `terminal_input` reached the manager the
/// next `terminal_output` was queued to the attached connections.
pub type LatencyProbe = Arc<dyn Fn(Duration) + Send + Sync>;

/// Where a new terminal leaf goes when the request does not say.
pub const DEFAULT_RELATIVE_TO: &str = "repl";
pub const DEFAULT_POSITION: &str = "split_below";
/// Every terminal leaf's pane id starts with this.
pub const PANE_PREFIX: &str = "terminal-";
const LOCAL_LABEL: &str = "Terminal";
/// At most this many `refused` audit lines per channel per [`REFUSAL_WINDOW`]:
/// it bounds how fast a flood of refused frames can rotate real entries away
/// (a same-user process could delete the file anyway), and a network flood
/// cannot use up the budget of local refusals.
pub const MAX_REFUSALS_PER_WINDOW: u32 = 120;
pub const REFUSAL_WINDOW: Duration = Duration::from_secs(60);

/// Terminals one focus may have at once (live or ended). Each costs four
/// threads, a 4 MiB replay ring and a 10,000-row screen model.
pub const MAX_TERMINALS_PER_FOCUS: usize = 8;
/// Terminals the daemon may have at once, across all focuses.
pub const MAX_TERMINALS: usize = 32;
/// Terminals agents may have opened, in one focus (live or ended). Lower than
/// [`MAX_TERMINALS_PER_FOCUS`] so an agent in a loop cannot fill a focus: the
/// rest is the user's.
pub const MAX_AGENT_TERMINALS_PER_FOCUS: usize = 2;
/// Terminals agents may have opened across the daemon. Lower than
/// [`MAX_TERMINALS`], so a few agents cannot fill the daemon either.
pub const MAX_AGENT_TERMINALS: usize = 6;
/// `requested_by.kind` of a terminal an agent's focus opened.
const AGENT_REQUESTER: &str = "focus";

/// A verified operator-app connection, as the terminal manager knows it.
pub struct OperatorConn {
    /// The connection's bounded terminal stream (replay and output).
    pub stream: mpsc::Sender<StreamBatch>,
    /// What the client said it can do (`Subscribe.capabilities`).
    pub capabilities: Vec<String>,
    /// The connection's targeted channel: frames meant for this connection
    /// alone (a remote shell's confirm request and outcome).
    pub targeted: mpsc::UnboundedSender<ServerMsg>,
}

/// The capability an operator connection declares when it can show a
/// remote shell's confirm sheet.
pub const REMOTE_SHELL_CONFIRM: &str = "remote_shell_confirm";

/// The capability an operator connection declares when it can show who
/// follows a terminal and stop it: only such a connection may invite.
pub const TERMINAL_FOLLOW_UI: &str = "terminal_follow_ui";

/// Why a terminal request failed. Nothing changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalError {
    UnknownTerminal,
    /// `terminal_restart` on a terminal that is not `ended`.
    NotEnded,
    /// `terminal_restart` on a remote shell: the connection is the pane, and
    /// a new one needs a new request and a new confirm.
    RemoteNotRestartable,
    /// Input to a terminal whose process has ended.
    NotRunning,
    /// The process is not reading its input and its queue is full.
    InputBusy,
    /// One `terminal_input` frame carried more than
    /// [`session::MAX_INPUT_FRAME_BYTES`] bytes.
    InputTooLarge,
    /// [`MAX_TERMINALS_PER_FOCUS`] or [`MAX_TERMINALS`] terminals exist already.
    TooManyTerminals,
    /// An agent has opened [`MAX_AGENT_TERMINALS_PER_FOCUS`] terminals in this
    /// focus, or agents [`MAX_AGENT_TERMINALS`] in the daemon: the user can
    /// still open more, and closes the agents' to free their quota.
    AgentQuotaReached,
    /// The audit trail cannot be written, so no terminal is opened.
    AuditUnavailable,
    /// The daemon is stopping.
    ShuttingDown,
    InvalidWorkingDirectory,
    InvalidSize,
    /// The bytes were not valid base64.
    InvalidBytes,
    Pane(PaneError),
    /// The process could not be started.
    OpenFailed,
}

impl TerminalError {
    pub fn code(self) -> &'static str {
        match self {
            TerminalError::UnknownTerminal => "unknown_terminal",
            TerminalError::NotEnded => "terminal_not_ended",
            TerminalError::RemoteNotRestartable => "terminal_control_forbidden",
            TerminalError::NotRunning => "terminal_not_running",
            TerminalError::InputBusy => "terminal_input_busy",
            TerminalError::InputTooLarge => "terminal_input_too_large",
            TerminalError::TooManyTerminals => "terminal_limit_reached",
            TerminalError::AgentQuotaReached => "terminal_agent_quota_reached",
            TerminalError::AuditUnavailable => "terminal_audit_unavailable",
            TerminalError::ShuttingDown => "daemon_shutting_down",
            TerminalError::InvalidWorkingDirectory => "invalid_working_directory",
            TerminalError::InvalidSize => "invalid_size",
            TerminalError::InvalidBytes => "invalid_bytes",
            TerminalError::Pane(e) => e.code(),
            TerminalError::OpenFailed => "terminal_open_failed",
        }
    }
}

/// What [`TerminalManager::new`] is built from.
pub struct TerminalConfig {
    pub audit: AuditLog,
    pub store: TerminalStore,
    pub pane_registry: Option<Arc<Mutex<PaneRegistry>>>,
}

impl TerminalConfig {
    /// No audit file, no store, no pane registry.
    pub fn in_memory() -> Self {
        Self {
            audit: AuditLog::disabled(),
            store: TerminalStore::in_memory(),
            pane_registry: None,
        }
    }
}

/// A `terminal_open_local` request.
#[derive(Debug, Clone, Default)]
pub struct OpenLocal {
    pub tag: String,
    pub relative_to: Option<String>,
    pub position: Option<String>,
    pub cwd: Option<String>,
    pub client_request_id: Option<String>,
}

/// A remote shell the manager is to give a pane: who asked, where the pane
/// goes and what the terminal is called. The process is started by the
/// launcher and handed over with this.
pub(crate) struct OpenRemote {
    pub tag: String,
    pub placement: Placement,
    pub requested_by: TerminalRequester,
    pub target: TerminalTarget,
    pub label: String,
    /// `Connecting` for a shell whose session has not begun (the launcher
    /// promotes it with [`TerminalManager::promote_remote`]), else `Running`.
    pub status: TerminalStatus,
    /// What is watched in its output; `None` for a shell that is not.
    pub watch: Option<Arc<RemoteWatch>>,
}

/// What `open_with` starts.
enum Launch {
    Local,
    Remote {
        session: Arc<TerminalSession>,
        target: TerminalTarget,
        label: String,
        status: TerminalStatus,
        watch: Option<Arc<RemoteWatch>>,
    },
}

struct Terminal {
    info: TerminalInfo,
    /// `None` for an ended terminal a previous daemon left.
    session: Option<Arc<TerminalSession>>,
    fanout: Arc<Fanout>,
    /// An ECS terminal's output watch.
    remote: Option<Arc<RemoteWatch>>,
}

pub struct TerminalManager {
    me: Weak<Mutex<TerminalManager>>,
    terminals: BTreeMap<String, Terminal>,
    operator_conns: HashMap<String, OperatorConn>,
    /// Terminals the previous daemon left whose panes are gone (remote
    /// shells), reported in every `TerminalList`.
    closed_at_start: Vec<TerminalClosedInfo>,
    panes: Option<Arc<Mutex<PaneRegistry>>>,
    broadcast: Option<broadcast::Sender<ServerMsg>>,
    audit: AuditLog,
    sensitive: SensitiveTags,
    store: TerminalStore,
    probe: Arc<Mutex<Option<LatencyProbe>>>,
    /// How sessions signal their children (replaced only by tests).
    signals: SignalOps,
    shutting_down: bool,
    refusal_budgets: Mutex<HashMap<RefusalChannel, RefusalBudget>>,
    /// The at-most-one remote shell request waiting for the user.
    remote_requests: RemoteRequests,
    /// Opens the remote shell once the user has clicked Connect.
    remote_launcher: Arc<dyn RemoteLauncher>,
    /// Where the remote-shell vocabulary's files are (read per request).
    ecs_paths: EcsPaths,
    /// Agent follow, once the IPC server has wired it.
    follow: Option<Arc<follow::FollowManager>>,
}

impl Terminal {
    /// A terminal still connecting is going away: tell the launcher waiting
    /// on it, which would otherwise wait out its timeout.
    fn fail_connecting(&self, reason_code: &str, message: &str) {
        if self.info.status != TerminalStatus::Connecting {
            return;
        }
        if let Some(watch) = &self.remote {
            watch.fail(ConnectFailure {
                reason_code: reason_code.into(),
                message: message.into(),
                remedy: None,
                detail: None,
            });
        }
    }
}

/// One channel's `refused` lines in the current window.
struct RefusalBudget {
    started: Instant,
    written: u32,
    suppressed: u32,
}

impl TerminalManager {
    pub fn new(cfg: TerminalConfig) -> Arc<Mutex<TerminalManager>> {
        Arc::new_cyclic(|me| {
            Mutex::new(TerminalManager {
                me: me.clone(),
                terminals: BTreeMap::new(),
                operator_conns: HashMap::new(),
                closed_at_start: Vec::new(),
                panes: cfg.pane_registry,
                broadcast: None,
                audit: cfg.audit,
                sensitive: SensitiveTags::in_memory(),
                store: cfg.store,
                probe: Arc::new(Mutex::new(None)),
                signals: SignalOps::real(),
                shutting_down: false,
                refusal_budgets: Mutex::new(HashMap::new()),
                remote_requests: RemoteRequests::default(),
                remote_launcher: Arc::new(UnavailableLauncher),
                ecs_paths: EcsPaths::from_config(&crate::config::TerminalConfig::default()),
                follow: None,
            })
        })
    }

    /// A manager with no audit file, no store and no pane registry.
    pub fn in_memory() -> Arc<Mutex<TerminalManager>> {
        Self::new(TerminalConfig::in_memory())
    }

    /// The channel `FocusLayout`, `PaneContent`, `TerminalState` and
    /// `TerminalClosed` go out on (the IPC server's broadcast).
    pub fn configure_broadcast(&mut self, tx: broadcast::Sender<ServerMsg>) {
        self.broadcast = Some(tx);
    }

    /// Which focus tags are sensitive: they appear in the audit trail in
    /// their opaque form, never by name.
    pub fn set_sensitive_tags(&mut self, sensitive: SensitiveTags) {
        self.sensitive = sensitive;
    }

    /// Test hook; see [`LatencyProbe`].
    pub fn set_latency_probe(&mut self, probe: Option<LatencyProbe>) {
        *self.probe.lock().unwrap_or_else(|e| e.into_inner()) = probe;
    }

    pub fn audit(&self) -> &AuditLog {
        &self.audit
    }

    pub(crate) fn sensitive_tags(&self) -> SensitiveTags {
        self.sensitive.clone()
    }

    /// Agent follow for these terminals, if wired ([`follow::FollowManager::install`]).
    pub fn follow(&self) -> Option<Arc<follow::FollowManager>> {
        self.follow.clone()
    }

    pub(crate) fn set_follow(&mut self, follow: Arc<follow::FollowManager>) {
        self.follow = Some(follow);
    }

    /// Settle what a previous daemon left (see [`store::reconcile`]). Call
    /// once, at daemon start, before anything connects.
    pub fn reconcile(&mut self) {
        let records = self.store.load();
        let mut panes = self.lock_panes();
        let reconciled = store::reconcile(records, panes.as_deref_mut());
        drop(panes);
        for info in &reconciled.ended {
            self.record(AuditEvent::DaemonStopped {
                terminal_id: info.terminal_id.clone(),
                pane_id: info.pane_id.clone(),
                tag: self.audit_tag(&info.tag),
                kind: info.kind,
            });
        }
        for closed in &reconciled.closed {
            self.record(AuditEvent::Closed {
                terminal_id: closed.terminal_id.clone(),
                pane_id: closed.pane_id.clone(),
                tag: self.audit_tag(&closed.tag),
                kind: closed.kind,
                reason: closed.reason.clone(),
                exit_code: None,
            });
        }
        for info in reconciled.ended {
            let fanout = Fanout::idle(&info.terminal_id, Arc::clone(&self.probe));
            self.terminals.insert(
                info.terminal_id.clone(),
                Terminal {
                    info,
                    session: None,
                    fanout,
                    remote: None,
                },
            );
        }
        self.closed_at_start = reconciled.closed;
        self.persist();
    }

    // ── reads ─────────────────────────────────────────────────────────────────

    pub fn list(&self) -> Vec<TerminalInfo> {
        self.terminals
            .values()
            .map(|t| self.described(&t.info))
            .collect()
    }

    pub fn info(&self, terminal_id: &str) -> Option<TerminalInfo> {
        self.terminals
            .get(terminal_id)
            .map(|t| self.described(&t.info))
    }

    /// `info` with who follows the terminal now.
    fn described(&self, info: &TerminalInfo) -> TerminalInfo {
        TerminalInfo {
            follower: self
                .follow
                .as_ref()
                .and_then(|f| f.current_follower(&info.terminal_id)),
            ..info.clone()
        }
    }

    /// What following `terminal_id` needs: its metadata and its live session
    /// (`None` for an unknown terminal, or one a previous daemon left).
    pub(crate) fn follow_target(
        &self,
        terminal_id: &str,
    ) -> Option<(TerminalInfo, Arc<TerminalSession>)> {
        let t = self.terminals.get(terminal_id)?;
        Some((t.info.clone(), Arc::clone(t.session.as_ref()?)))
    }

    /// Broadcast `terminal_id`'s current metadata (its follower changed).
    pub(crate) fn send_state(&self, terminal_id: &str) {
        if let Some(info) = self.info(terminal_id) {
            self.send(ServerMsg::TerminalState { terminal: info });
        }
    }

    /// Is any verified operator-app connection registered?
    pub fn has_operator_conns(&self) -> bool {
        !self.operator_conns.is_empty()
    }

    /// Is a verified operator-app connection that declared
    /// [`TERMINAL_FOLLOW_UI`] (it can show who follows and stop it) still
    /// connected? Nothing may start following without one.
    pub fn follow_ui_connected(&self) -> bool {
        self.operator_conns.values().any(|c| {
            !c.targeted.is_closed() && c.capabilities.iter().any(|cap| cap == TERMINAL_FOLLOW_UI)
        })
    }

    /// The `TerminalList` a newly connected local client is sent.
    pub fn terminal_list_msg(&self) -> ServerMsg {
        ServerMsg::TerminalList {
            terminals: self.list(),
            closed: self.closed_at_start.clone(),
        }
    }

    /// Is `conn_key` attached to `terminal_id`?
    pub fn is_attached(&self, conn_key: &str, terminal_id: &str) -> bool {
        self.terminals
            .get(terminal_id)
            .is_some_and(|t| t.fanout.is_attached(conn_key))
    }

    // ── operator connections ─────────────────────────────────────────────────

    pub fn register_conn(&mut self, _cap: &OperatorCap, conn_key: &str, conn: OperatorConn) {
        self.operator_conns.insert(conn_key.to_string(), conn);
    }

    pub fn set_capabilities(&mut self, _cap: &OperatorCap, conn_key: &str, caps: Vec<String>) {
        if let Some(conn) = self.operator_conns.get_mut(conn_key) {
            conn.capabilities = caps;
        }
        self.end_remote_request_if_unanswerable();
    }

    /// Did the operator connection `conn_key` declare `capability`?
    pub fn conn_has_capability(&self, conn_key: &str, capability: &str) -> bool {
        self.operator_conns
            .get(conn_key)
            .is_some_and(|c| c.capabilities.iter().any(|have| have == capability))
    }

    /// The connection is gone: detach it everywhere and forget it.
    pub fn unregister_conn(&mut self, _cap: &OperatorCap, conn_key: &str) {
        for t in self.terminals.values() {
            t.fanout.detach(conn_key);
        }
        self.operator_conns.remove(conn_key);
        self.end_remote_request_if_unanswerable();
    }

    // ── opening ──────────────────────────────────────────────────────────────

    /// The operator app opens a local shell.
    pub fn open_local(
        &mut self,
        _cap: &OperatorCap,
        req: OpenLocal,
    ) -> Result<TerminalInfo, TerminalError> {
        let requester = TerminalRequester {
            kind: "user".into(),
            tag: None,
        };
        self.open(req, requester)
    }

    /// An agent's focus opens a local shell in its own focus (1b's facade).
    /// The only cap-less mutating entry point: it can only start a shell; the
    /// agent never gets its input, output or close.
    pub fn open_local_for_agent(
        &mut self,
        tag: &str,
        cwd: Option<PathBuf>,
    ) -> Result<TerminalInfo, TerminalError> {
        let req = OpenLocal {
            tag: tag.to_string(),
            cwd: cwd.map(|p| p.display().to_string()),
            ..OpenLocal::default()
        };
        let requester = TerminalRequester {
            kind: AGENT_REQUESTER.into(),
            tag: Some(tag.to_string()),
        };
        self.open(req, requester)
    }

    fn open(
        &mut self,
        req: OpenLocal,
        requested_by: TerminalRequester,
    ) -> Result<TerminalInfo, TerminalError> {
        self.open_with(req, requested_by, Launch::Local)
    }

    /// A remote shell's process, already started by a [`launcher::RemoteLauncher`],
    /// gets its pane and its place in the registry. The caller must have
    /// shown the user a confirm sheet and been told to connect: this is not
    /// reachable from an agent. On any error the session is killed.
    pub(crate) fn open_remote(
        &mut self,
        req: OpenRemote,
        session: Arc<TerminalSession>,
    ) -> Result<TerminalInfo, TerminalError> {
        let open = OpenLocal {
            tag: req.tag,
            relative_to: req.placement.relative_to,
            position: req.placement.position,
            cwd: None,
            client_request_id: None,
        };
        let launch = Launch::Remote {
            session: Arc::clone(&session),
            target: req.target,
            label: req.label,
            status: req.status,
            watch: req.watch,
        };
        let result = self.open_with(open, req.requested_by, launch);
        if result.is_err() {
            session.kill();
        }
        result
    }

    /// Would a remote shell for `tag` at `placement` be opened right now? The
    /// launcher asks before it starts anything: a process that is then refused
    /// a pane would be a production session started for nothing. (`open_with`
    /// checks again: this is a courtesy, not a reservation.)
    pub(crate) fn check_can_open_remote(
        &self,
        tag: &str,
        placement: &Placement,
    ) -> Result<(), TerminalError> {
        self.check_can_open(tag)?;
        SplitPosition::parse(placement.position.as_deref().unwrap_or(DEFAULT_POSITION))
            .map_err(TerminalError::Pane)?;
        let relative_to = placement
            .relative_to
            .as_deref()
            .unwrap_or(DEFAULT_RELATIVE_TO);
        let panes = self
            .lock_panes()
            .map(|panes| panes.pane_ids(tag))
            .unwrap_or_default();
        // A focus with no tree yet gets the default one, which has the repl.
        if !panes.is_empty() && !panes.iter().any(|p| p == relative_to) {
            return Err(TerminalError::Pane(PaneError::UnknownPane));
        }
        Ok(())
    }

    fn open_with(
        &mut self,
        req: OpenLocal,
        requested_by: TerminalRequester,
        launch: Launch,
    ) -> Result<TerminalInfo, TerminalError> {
        self.check_can_open(&req.tag)?;
        // The agent quota is for shells an agent starts on its own; a remote
        // shell exists only because the user clicked Connect.
        if requested_by.kind == AGENT_REQUESTER && matches!(launch, Launch::Local) {
            let by_agents = || {
                self.terminals.values().filter(|t| {
                    t.info.requested_by.kind == AGENT_REQUESTER
                        && t.info.kind == TerminalKind::Local
                })
            };
            if by_agents().count() >= MAX_AGENT_TERMINALS
                || by_agents().filter(|t| t.info.tag == req.tag).count()
                    >= MAX_AGENT_TERMINALS_PER_FOCUS
            {
                return Err(TerminalError::AgentQuotaReached);
            }
        }
        let cwd = match launch {
            Launch::Local => Some(resolve_cwd(req.cwd.as_deref())?),
            Launch::Remote { .. } => None,
        };
        let position = SplitPosition::parse(req.position.as_deref().unwrap_or(DEFAULT_POSITION))
            .map_err(TerminalError::Pane)?;
        let relative_to = req.relative_to.as_deref().unwrap_or(DEFAULT_RELATIVE_TO);
        let pane_id = self.new_pane_id(&req.tag);
        let (cols, rows) = (store::DEFAULT_COLS, store::DEFAULT_ROWS);

        // Place the leaf first: a bad `relative_to` must not start a process.
        let tree = match self.lock_panes() {
            Some(mut panes) => Some(
                panes
                    .insert_registered_terminal_leaf(&req.tag, relative_to, position, &pane_id)
                    .map_err(TerminalError::Pane)?,
            ),
            None => None,
        };
        let (session, kind, label, target, status, remote) = match launch {
            Launch::Local => {
                let cwd = cwd
                    .as_deref()
                    .expect("a local shell has a working directory");
                match TerminalSession::spawn_local(cwd, cols, rows, self.signals.clone()) {
                    Ok(s) => (
                        s,
                        TerminalKind::Local,
                        LOCAL_LABEL.to_string(),
                        None,
                        TerminalStatus::Running,
                        None,
                    ),
                    Err(e) => {
                        warn!(tag = %req.tag, "terminal spawn failed: {e:#}");
                        self.remove_leaf(&req.tag, &pane_id);
                        return Err(TerminalError::OpenFailed);
                    }
                }
            }
            Launch::Remote {
                session,
                target,
                label,
                status,
                watch,
            } => (
                session,
                TerminalKind::Ecs,
                label,
                Some(target),
                status,
                watch,
            ),
        };

        let user_opened = requested_by.kind == "user";
        let info = TerminalInfo {
            terminal_id: Uuid::new_v4().to_string(),
            tag: req.tag.clone(),
            pane_id: pane_id.clone(),
            kind,
            label,
            cwd: cwd.map(|c| c.display().to_string()),
            target,
            status,
            exit_code: None,
            ended_reason: None,
            cols,
            rows,
            requested_by,
            opened_by_request: req.client_request_id,
            follower: None,
        };
        self.insert_live(info.clone(), session, remote);
        self.persist();
        self.record(AuditEvent::Opened {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: self.audit_tag(&info.tag),
            kind: info.kind,
            requested_by: info.requested_by.kind.clone(),
            cwd: info.cwd.clone(),
        });
        if let Some(tree) = tree {
            // A user-opened pane takes keyboard focus; an agent-opened one does not.
            let focused = user_opened.then(|| pane_id.clone());
            self.send(ServerMsg::FocusLayout {
                tag: info.tag.clone(),
                tree,
                focused_pane: focused,
            });
        }
        self.send_pane_content(&info);
        self.send(ServerMsg::TerminalState {
            terminal: self.described(&info),
        });
        Ok(info)
    }

    /// The checks every new terminal passes before anything is started.
    fn check_can_open(&self, tag: &str) -> Result<(), TerminalError> {
        if self.shutting_down {
            return Err(TerminalError::ShuttingDown);
        }
        // Nothing starts that cannot be audited.
        if let Err(e) = self.audit.check() {
            warn!("terminal not opened, audit log unavailable: {e}");
            return Err(TerminalError::AuditUnavailable);
        }
        if self.terminals.len() >= MAX_TERMINALS
            || self
                .terminals
                .values()
                .filter(|t| t.info.tag == tag)
                .count()
                >= MAX_TERMINALS_PER_FOCUS
        {
            return Err(TerminalError::TooManyTerminals);
        }
        Ok(())
    }

    /// Track a freshly spawned session: fan-out, and the exit hook.
    fn insert_live(
        &mut self,
        info: TerminalInfo,
        session: Arc<TerminalSession>,
        remote: Option<Arc<RemoteWatch>>,
    ) {
        let terminal_id = info.terminal_id.clone();
        let fanout = Fanout::start(&terminal_id, &session, Arc::clone(&self.probe));
        let me = self.me.clone();
        let id = terminal_id.clone();
        session.on_exit(Box::new(move |code| {
            if let Some(mgr) = me.upgrade() {
                mgr.lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .handle_exit(&id, code);
            }
        }));
        self.terminals.insert(
            terminal_id,
            Terminal {
                info,
                session: Some(session),
                fanout,
                remote,
            },
        );
    }

    /// The shared pane registry, if this manager has one (tolerates poison).
    fn lock_panes(&self) -> Option<MutexGuard<'_, PaneRegistry>> {
        self.panes
            .as_ref()
            .map(|p| p.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn new_pane_id(&self, tag: &str) -> String {
        let taken = self
            .lock_panes()
            .map(|panes| panes.pane_ids(tag))
            .unwrap_or_default();
        loop {
            let hex = Uuid::new_v4().simple().to_string();
            let id = format!("{PANE_PREFIX}{}", &hex[..8]);
            let in_use =
                taken.contains(&id) || self.terminals.values().any(|t| t.info.pane_id == id);
            if !in_use {
                return id;
            }
        }
    }

    // ── operator verbs ───────────────────────────────────────────────────────

    /// Queue a replay of `terminal_id` to `conn_key`, then stream its output.
    pub fn attach(
        &mut self,
        _cap: &OperatorCap,
        conn_key: &str,
        terminal_id: &str,
    ) -> Result<(), TerminalError> {
        let t = self
            .terminals
            .get(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
        let Some(conn) = self.operator_conns.get(conn_key) else {
            // Only a registered operator connection has a stream to attach.
            return Err(TerminalError::UnknownTerminal);
        };
        let stream = conn.stream.clone();
        match &t.session {
            Some(session) => session.with_replay(|replay, size| {
                t.fanout.attach(conn_key, stream, replay, size);
            }),
            None => t
                .fanout
                .attach(conn_key, stream, Vec::new(), (t.info.cols, t.info.rows)),
        }
        Ok(())
    }

    /// Stop streaming `terminal_id` to `conn_key`. Touches only that
    /// connection's own attachment, so it needs no cap.
    pub fn detach(&mut self, conn_key: &str, terminal_id: &str) {
        if let Some(t) = self.terminals.get(terminal_id) {
            t.fanout.detach(conn_key);
        }
    }

    pub fn input(
        &mut self,
        _cap: &OperatorCap,
        terminal_id: &str,
        bytes: &[u8],
    ) -> Result<(), TerminalError> {
        let t = self
            .terminals
            .get(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
        let session = t
            .session
            .as_ref()
            .filter(|s| t.info.status == TerminalStatus::Running && !s.is_exited())
            .ok_or(TerminalError::NotRunning)?;
        t.fanout.input_received();
        session.write(bytes).map_err(|e| match e {
            InputError::TooLarge => TerminalError::InputTooLarge,
            InputError::Busy => TerminalError::InputBusy,
            InputError::Gone => TerminalError::NotRunning,
        })
    }

    pub fn resize(
        &mut self,
        _cap: &OperatorCap,
        terminal_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), TerminalError> {
        if cols == 0 || rows == 0 || cols > session::MAX_COLS || rows > session::MAX_ROWS {
            return Err(TerminalError::InvalidSize);
        }
        let t = self
            .terminals
            .get_mut(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
        if (t.info.cols, t.info.rows) == (cols, rows) {
            return Ok(());
        }
        if let Some(session) = &t.session {
            if !session.is_exited() {
                session.resize(cols, rows).map_err(|e| {
                    warn!("terminal resize failed: {e:#}");
                    TerminalError::NotRunning
                })?;
            }
        }
        t.info.cols = cols;
        t.info.rows = rows;
        let info = t.info.clone();
        self.send(ServerMsg::TerminalState {
            terminal: self.described(&info),
        });
        Ok(())
    }

    /// Kill the process (if it runs) and remove the pane.
    pub fn close(&mut self, _cap: &OperatorCap, terminal_id: &str) -> Result<(), TerminalError> {
        let t = self
            .terminals
            .remove(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
        if let Some(session) = &t.session {
            session.kill();
        }
        t.fanout.close();
        t.fail_connecting("user_closed", "The shell was closed before it connected.");
        self.finish_closed(t.info, "user_closed", None);
        Ok(())
    }

    /// The focus `tag` is gone (the app pushed a registry without it): end its
    /// shells and drop their records and leaves, audited `focus_removed`. One
    /// of the manager's own removal paths, reached only by the daemon, never by
    /// a connection or an agent.
    pub(crate) fn close_focus(&mut self, tag: &str) {
        let ids: Vec<String> = self
            .terminals
            .iter()
            .filter(|(_, t)| t.info.tag == tag)
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let Some(t) = self.terminals.remove(&id) else {
                continue;
            };
            if let Some(session) = &t.session {
                session.kill();
            }
            t.fanout.close();
            t.fail_connecting("focus_removed", "The pane's focus was removed.");
            self.finish_closed(t.info, "focus_removed", None);
        }
    }

    /// A fresh shell in an `ended` local terminal's pane, under a new id.
    pub fn restart(
        &mut self,
        _cap: &OperatorCap,
        terminal_id: &str,
    ) -> Result<TerminalInfo, TerminalError> {
        if self.shutting_down {
            return Err(TerminalError::ShuttingDown);
        }
        let old = self
            .terminals
            .get(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
        if old.info.kind == TerminalKind::Ecs {
            return Err(TerminalError::RemoteNotRestartable);
        }
        if old.info.status != TerminalStatus::Ended || old.info.kind != TerminalKind::Local {
            return Err(TerminalError::NotEnded);
        }
        let cwd = old
            .info
            .cwd
            .as_deref()
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
            .unwrap_or_else(home_dir);
        let (cols, rows) = (old.info.cols, old.info.rows);
        let session = TerminalSession::spawn_local(&cwd, cols, rows, self.signals.clone())
            .map_err(|e| {
                warn!("terminal restart failed: {e:#}");
                TerminalError::OpenFailed
            })?;
        let old = self.terminals.remove(terminal_id).expect("checked above");
        if let Some(follow) = &self.follow {
            follow.terminal_closed(terminal_id, true);
        }
        if let Some(old_session) = &old.session {
            // Already exited: this signals nothing, it ends the old reader.
            old_session.kill();
        }
        old.fanout.close();
        let info = TerminalInfo {
            terminal_id: Uuid::new_v4().to_string(),
            cwd: Some(cwd.display().to_string()),
            status: TerminalStatus::Running,
            exit_code: None,
            ended_reason: None,
            opened_by_request: None,
            follower: None,
            ..old.info
        };
        self.insert_live(info.clone(), session, None);
        self.persist();
        self.record(AuditEvent::Restarted {
            terminal_id: info.terminal_id.clone(),
            previous_terminal_id: terminal_id.to_string(),
            pane_id: info.pane_id.clone(),
            tag: self.audit_tag(&info.tag),
            kind: info.kind,
        });
        self.send_pane_content(&info);
        self.send(ServerMsg::TerminalState {
            terminal: self.described(&info),
        });
        Ok(info)
    }

    // ── remote shells ────────────────────────────────────────────────────────

    /// Replace the launcher that opens a remote shell after Connect (the
    /// default [`UnavailableLauncher`] fails every connect).
    pub fn set_remote_launcher(&mut self, launcher: Arc<dyn RemoteLauncher>) {
        self.remote_launcher = launcher;
    }

    /// Where the remote-shell vocabulary is read from.
    pub fn set_ecs_paths(&mut self, paths: EcsPaths) {
        self.ecs_paths = paths;
    }

    pub fn ecs_paths(&self) -> &EcsPaths {
        &self.ecs_paths
    }

    pub(crate) fn remote_launcher(&self) -> Arc<dyn RemoteLauncher> {
        Arc::clone(&self.remote_launcher)
    }

    /// Replace the clock the remote request cooldown and ceiling read.
    pub fn set_remote_clock(&mut self, clock: remote_request::Clock) {
        self.remote_requests.set_clock(clock);
    }

    pub(crate) fn remote_requests_mut(&mut self) -> &mut RemoteRequests {
        &mut self.remote_requests
    }

    /// The user's answer to the pending remote shell request, from the verified
    /// operator connection `conn_key`. `false` when that connection declared no
    /// `remote_shell_confirm`, or `request_id` is not the pending one
    /// (answered, timed out or never existed): a late answer changes nothing.
    pub fn remote_answer(
        &mut self,
        cap: &OperatorCap,
        conn_key: &str,
        request_id: &str,
        decision: Decision,
        invite_follow: bool,
    ) -> bool {
        // Only a connection that can show the sheet answers it: a verified app
        // without the capability was never asked.
        let can_answer = self
            .operator_conns
            .get(conn_key)
            .is_some_and(|c| c.capabilities.iter().any(|cap| cap == REMOTE_SHELL_CONFIRM));
        can_answer
            && self
                .remote_requests
                .answer(cap, request_id, decision, invite_follow)
    }

    /// The targeted channels of the operator connections that declared
    /// [`REMOTE_SHELL_CONFIRM`]: the only ones a confirm request goes to. A
    /// verified app without the capability does not count, and neither does
    /// anything that is not an operator connection.
    /// A pending request nobody can answer (the last connection that could
    /// show its sheet went away) ends now rather than at its timeout.
    fn end_remote_request_if_unanswerable(&mut self) {
        if self.remote_confirm_conns().is_empty() {
            self.remote_requests.operator_gone();
        }
    }

    /// Is a verified app that can show the confirm sheet still connected?
    pub(crate) fn operator_connected(&self) -> bool {
        self.remote_confirm_conns().iter().any(|c| !c.is_closed())
    }

    pub(crate) fn remote_confirm_conns(&self) -> Vec<mpsc::UnboundedSender<ServerMsg>> {
        self.operator_conns
            .values()
            .filter(|c| c.capabilities.iter().any(|cap| cap == REMOTE_SHELL_CONFIRM))
            .map(|c| c.targeted.clone())
            .collect()
    }

    // ── audit ────────────────────────────────────────────────────────────────

    /// Record a refused terminal request (no cap: refusals come from anyone).
    /// `terminal_id` is whatever the peer sent, so it is kept only when it is
    /// shaped like an id; and past [`MAX_REFUSALS_PER_WINDOW`] lines in a
    /// window the rest are counted, not written.
    pub fn audit_refused(
        &self,
        channel: RefusalChannel,
        op: &str,
        code: Option<&str>,
        terminal_id: Option<&str>,
        peer_pid: Option<i32>,
        peer_exe: Option<String>,
    ) {
        self.audit_refused_as(
            channel,
            op,
            code,
            terminal_id,
            None,
            None,
            peer_pid,
            peer_exe,
        );
    }

    /// [`Self::audit_refused`] for a refusal on the MCP socket: it names the
    /// calling `focus` (its Hello `pty_id`, shown as the audit trail shows any
    /// focus) and the `tool` or frame that was refused.
    pub fn audit_refused_mcp(
        &self,
        op: &str,
        code: Option<&str>,
        terminal_id: Option<&str>,
        focus: Option<&str>,
        tool: Option<&str>,
    ) {
        self.audit_refused_as(
            RefusalChannel::Mcp,
            op,
            code,
            terminal_id,
            focus,
            tool,
            None,
            None,
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn audit_refused_as(
        &self,
        channel: RefusalChannel,
        op: &str,
        code: Option<&str>,
        terminal_id: Option<&str>,
        focus: Option<&str>,
        tool: Option<&str>,
        peer_pid: Option<i32>,
        peer_exe: Option<String>,
    ) {
        if !self.take_refusal_budget(channel) {
            return;
        }
        self.record(AuditEvent::Refused {
            channel,
            op: op.to_string(),
            code: code.map(str::to_string),
            terminal_id: terminal_id
                .filter(|id| is_id_shaped(id))
                .map(str::to_string),
            focus: focus.map(|f| self.audit_tag(f)),
            peer_pid,
            peer_exe,
            tool: tool.map(str::to_string),
        });
    }

    /// Does `tag` have any terminal, live or ended?
    pub(crate) fn has_terminals(&self, tag: &str) -> bool {
        self.terminals.values().any(|t| t.info.tag == tag)
    }

    /// Whether `pane_id` in `tag` is a registered terminal leaf.
    pub fn is_terminal_leaf(&self, tag: &str, pane_id: &str) -> bool {
        self.lock_panes()
            .is_some_and(|panes| panes.is_terminal_leaf(tag, pane_id))
    }

    /// May one more `refused` line for `channel` be written in its window?
    /// The cap and the count it kept out are themselves audited.
    fn take_refusal_budget(&self, channel: RefusalChannel) -> bool {
        let mut budgets = self
            .refusal_budgets
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let budget = budgets.entry(channel).or_insert_with(|| RefusalBudget {
            started: Instant::now(),
            written: 0,
            suppressed: 0,
        });
        if budget.started.elapsed() >= REFUSAL_WINDOW {
            if budget.suppressed > 0 {
                self.record(AuditEvent::RefusalsSuppressed {
                    channel,
                    count: budget.suppressed,
                });
            }
            *budget = RefusalBudget {
                started: Instant::now(),
                written: 0,
                suppressed: 0,
            };
        }
        if budget.written < MAX_REFUSALS_PER_WINDOW {
            budget.written += 1;
            return true;
        }
        if budget.suppressed == 0 {
            warn!(
                ?channel,
                "terminal refusals over the audit cap; counting the rest"
            );
            self.record(AuditEvent::RefusalLimitReached { channel });
        }
        budget.suppressed += 1;
        false
    }

    /// `tag` as the audit trail names it: the opaque stand-in for a
    /// sensitive focus (as `audit_focus_tag` does for the other audits).
    pub(crate) fn audit_tag(&self, tag: &str) -> String {
        if self.sensitive.tag_is_sensitive(tag) {
            self.sensitive.opaque_tag(tag)
        } else {
            tag.to_owned()
        }
    }

    pub(crate) fn record(&self, event: AuditEvent) {
        if let Err(e) = self.audit.append(&event) {
            warn!("terminal audit append failed: {e}");
        }
    }

    // ── lifecycle ────────────────────────────────────────────────────────────

    /// The process behind `terminal_id` exited (waiter thread).
    fn handle_exit(&mut self, terminal_id: &str, code: Option<i32>) {
        if self.shutting_down {
            return;
        }
        // Closed (or restarted) already: nothing left to do.
        let Some(t) = self.terminals.get_mut(terminal_id) else {
            return;
        };
        t.fanout.close();
        // The connection is the pane: an ECS terminal never lingers `ended`.
        if t.info.kind == TerminalKind::Ecs {
            let t = self.terminals.remove(terminal_id).expect("present");
            self.finish_remote_exit(t, code);
            return;
        }
        if code == Some(0) {
            let t = self.terminals.remove(terminal_id).expect("present");
            self.finish_closed(t.info, "exited", code);
            return;
        }
        t.info.status = TerminalStatus::Ended;
        t.info.exit_code = code;
        let info = t.info.clone();
        let info = self.described(&info);
        self.persist();
        self.record(AuditEvent::Ended {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: self.audit_tag(&info.tag),
            kind: info.kind,
            exit_code: code,
        });
        self.send(ServerMsg::TerminalState { terminal: info });
    }

    /// An ECS terminal's process exited (it is already out of the registry).
    /// Before its session began that is a connect failure, and the launcher
    /// waiting on it is told why; after, the pane closes with the reason the
    /// output gives (`remote_exit`, `sso_expired`, `network`, `unknown`).
    /// Nothing reconnects.
    fn finish_remote_exit(&mut self, t: Terminal, code: Option<i32>) {
        let Some(watch) = t.remote else {
            self.finish_closed(t.info, "exited", code);
            return;
        };
        if t.info.status == TerminalStatus::Connecting {
            let failure = if watch.connected() {
                // The session began and ended before the launcher saw it begin.
                ConnectFailure {
                    reason_code: watch.take_close_reason().into(),
                    message: "The session ended as soon as it began.".into(),
                    remedy: None,
                    detail: None,
                }
            } else {
                watch.take_connect_failure()
            };
            let reason = failure.reason_code.clone();
            watch.fail(failure);
            self.finish_closed(t.info, &reason, code);
        } else {
            let reason = watch.take_close_reason();
            self.finish_closed(t.info, reason, code);
        }
    }

    /// The remote shell's session has begun: `connecting` becomes `running`
    /// and clients are told. `None` when the terminal is no longer connecting
    /// (it exited or was closed first; the launcher is told so separately).
    pub(crate) fn promote_remote(&mut self, terminal_id: &str) -> Option<TerminalInfo> {
        let t = self.terminals.get_mut(terminal_id)?;
        if t.info.status != TerminalStatus::Connecting {
            return None;
        }
        t.info.status = TerminalStatus::Running;
        let info = t.info.clone();
        self.send(ServerMsg::TerminalState {
            terminal: info.clone(),
        });
        Some(info)
    }

    /// Give up on a remote shell that has not connected (timeout, or the
    /// requester went away): kill it, remove its pane and record. `false` when
    /// it is gone already or is no longer connecting.
    pub(crate) fn abort_connecting(&mut self, terminal_id: &str, reason: &str) -> bool {
        let connecting = self
            .terminals
            .get(terminal_id)
            .is_some_and(|t| t.info.status == TerminalStatus::Connecting);
        if !connecting {
            return false;
        }
        let t = self.terminals.remove(terminal_id).expect("checked above");
        if let Some(session) = &t.session {
            session.kill();
        }
        t.fanout.close();
        self.finish_closed(t.info, reason, None);
        true
    }

    /// A terminal left the registry: remove its leaf, persist, audit, tell clients.
    fn finish_closed(&mut self, info: TerminalInfo, reason: &str, exit_code: Option<i32>) {
        if let Some(follow) = &self.follow {
            follow.terminal_closed(&info.terminal_id, false);
        }
        let tree = self.remove_leaf(&info.tag, &info.pane_id);
        self.persist();
        self.record(AuditEvent::Closed {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: self.audit_tag(&info.tag),
            kind: info.kind,
            reason: reason.to_string(),
            exit_code,
        });
        if let Some(tree) = tree {
            self.send(ServerMsg::FocusLayout {
                tag: info.tag.clone(),
                tree,
                focused_pane: None,
            });
        }
        self.send(ServerMsg::TerminalClosed(TerminalClosedInfo {
            terminal_id: info.terminal_id,
            tag: info.tag,
            pane_id: info.pane_id,
            label: info.label,
            kind: info.kind,
            reason: reason.to_string(),
            exit_code,
            target: info.target,
        }));
    }

    /// Unregister and remove a terminal leaf; the new tree if it changed.
    fn remove_leaf(&self, tag: &str, pane_id: &str) -> Option<PaneTree> {
        let mut panes = self.lock_panes()?;
        panes.unregister_terminal_leaf(tag, pane_id);
        panes.remove_terminal_leaf(tag, pane_id)
    }

    /// Daemon shutdown: end every shell and keep the records, so the next
    /// daemon reports them `ended / daemon_stopped`.
    pub fn shutdown(&mut self) {
        self.shutting_down = true;
        self.persist();
        let budgets = std::mem::take(
            &mut *self
                .refusal_budgets
                .lock()
                .unwrap_or_else(|e| e.into_inner()),
        );
        for (channel, budget) in budgets {
            if budget.suppressed > 0 {
                self.record(AuditEvent::RefusalsSuppressed {
                    channel,
                    count: budget.suppressed,
                });
            }
        }
        for t in self.terminals.values() {
            if let Some(session) = &t.session {
                session.kill();
            }
            t.fanout.close();
            t.fail_connecting("daemon_stopping", "The daemon is stopping.");
        }
    }

    fn persist(&self) {
        let records: Vec<TerminalRecord> = self
            .terminals
            .values()
            .map(|t| TerminalRecord {
                terminal_id: t.info.terminal_id.clone(),
                tag: t.info.tag.clone(),
                pane_id: t.info.pane_id.clone(),
                kind: t.info.kind,
                cwd: t.info.cwd.clone(),
                label: t.info.label.clone(),
                target: t.info.target.clone(),
                requested_by: t.info.requested_by.clone(),
            })
            .collect();
        self.store.save(&records);
    }

    fn send(&self, msg: ServerMsg) {
        if let Some(tx) = &self.broadcast {
            let _ = tx.send(msg);
        }
    }

    fn send_pane_content(&self, info: &TerminalInfo) {
        self.send(ServerMsg::PaneContent {
            tag: info.tag.clone(),
            pane_id: info.pane_id.clone(),
            content: PaneContentWire::Terminal {
                terminal_id: info.terminal_id.clone(),
                label: info.label.clone(),
                environment: info.target.as_ref().map(|t| t.environment.clone()),
            },
            freshness: None,
            address: None,
        });
    }
}

/// The verb a terminal client frame asks for (`open`, `attach`, …), or `None`
/// for any other frame. Used for refusals and their audit lines.
pub fn op_of(msg: &ClientMsg) -> Option<&'static str> {
    Some(match msg {
        ClientMsg::TerminalOpenLocal { .. } => "open",
        ClientMsg::TerminalAttach { .. } => "attach",
        ClientMsg::TerminalDetach { .. } => "detach",
        ClientMsg::TerminalInput { .. } => "input",
        ClientMsg::TerminalResize { .. } => "resize",
        ClientMsg::TerminalClose { .. } => "close",
        ClientMsg::TerminalRestart { .. } => "restart",
        ClientMsg::TerminalRefusalReport { .. } => "refusal_report",
        ClientMsg::TerminalFollowInvite { .. } => "follow_invite",
        ClientMsg::TerminalFollowStop { .. } => "follow_stop",
        ClientMsg::TerminalFollowResume { .. } => "follow_resume",
        ClientMsg::TerminalSendSelection { .. } => "send_selection",
        // The remote-shell verbs are all "control" to the audit trail.
        ClientMsg::RemoteShellTargetsRequest
        | ClientMsg::RemoteShellOpen { .. }
        | ClientMsg::RemoteShellAnswer { .. } => "control",
        _ => return None,
    })
}

/// The terminal a terminal client frame names, if any.
pub fn terminal_id_of(msg: &ClientMsg) -> Option<&str> {
    match msg {
        ClientMsg::TerminalAttach { terminal_id }
        | ClientMsg::TerminalDetach { terminal_id }
        | ClientMsg::TerminalInput { terminal_id, .. }
        | ClientMsg::TerminalResize { terminal_id, .. }
        | ClientMsg::TerminalClose { terminal_id }
        | ClientMsg::TerminalRestart { terminal_id }
        | ClientMsg::TerminalFollowInvite { terminal_id, .. }
        | ClientMsg::TerminalFollowStop { terminal_id }
        | ClientMsg::TerminalFollowResume { terminal_id }
        | ClientMsg::TerminalSendSelection { terminal_id, .. } => Some(terminal_id),
        ClientMsg::TerminalRefusalReport { terminal_id, .. } => terminal_id.as_deref(),
        _ => None,
    }
}

/// The refusal code for an operator-only `op` from anyone else.
pub fn forbidden_code(op: &str) -> &'static str {
    match op {
        "input" => "terminal_input_forbidden",
        "attach" => "terminal_read_forbidden",
        "close" => "terminal_close_forbidden",
        _ => "terminal_control_forbidden",
    }
}

/// A terminal id as the daemon mints them (a UUID): short, hex and dashes.
fn is_id_shaped(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
}

fn home_dir() -> PathBuf {
    dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/"))
}

/// The requested working directory (absolute, an existing directory), or
/// `$HOME` when none was given.
fn resolve_cwd(cwd: Option<&str>) -> Result<PathBuf, TerminalError> {
    match cwd {
        None => Ok(home_dir()),
        Some(c) => {
            let p = Path::new(c);
            if p.is_absolute() && p.is_dir() {
                Ok(p.to_path_buf())
            } else {
                Err(TerminalError::InvalidWorkingDirectory)
            }
        }
    }
}
