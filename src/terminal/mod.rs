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
pub mod audit;
mod fanout;
pub mod session;
pub mod store;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use tokio::sync::{broadcast, mpsc};
use tracing::warn;
use uuid::Uuid;

pub use access::OperatorCap;
use audit::{AuditEvent, AuditLog, RefusalChannel};
use fanout::Fanout;
use session::TerminalSession;
use store::{TerminalRecord, TerminalStore};

use crate::ipc::pane_registry::{PaneError, PaneRegistry, SplitPosition};
use crate::ipc::protocol::{
    ClientMsg, PaneContentWire, PaneTree, ServerMsg, TerminalClosedInfo, TerminalInfo,
    TerminalKind, TerminalRequester, TerminalStatus,
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
/// At most this many `refused` audit lines per [`REFUSAL_WINDOW`]: a peer
/// that floods refused frames must not rotate the real entries away.
pub const MAX_REFUSALS_PER_WINDOW: u32 = 120;
pub const REFUSAL_WINDOW: Duration = Duration::from_secs(60);

/// A verified operator-app connection, as the terminal manager knows it.
pub struct OperatorConn {
    /// The connection's targeted channel (replies, refusals).
    pub targeted: mpsc::UnboundedSender<ServerMsg>,
    /// The connection's bounded terminal stream (replay and output).
    pub stream: mpsc::Sender<StreamBatch>,
    /// What the client said it can do (`Subscribe.capabilities`).
    pub capabilities: Vec<String>,
}

/// Why a terminal request failed. Nothing changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalError {
    UnknownTerminal,
    /// `terminal_restart` on a terminal that is not `ended`, or a remote one.
    NotEnded,
    /// Input to a terminal whose process has ended.
    NotRunning,
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
            TerminalError::NotRunning => "terminal_not_running",
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

struct Terminal {
    info: TerminalInfo,
    /// `None` for an ended terminal a previous daemon left.
    session: Option<Arc<TerminalSession>>,
    fanout: Arc<Fanout>,
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
    store: TerminalStore,
    probe: Arc<Mutex<Option<LatencyProbe>>>,
    shutting_down: bool,
    /// `(window start, refusals audited in it, refusals dropped in it)`.
    refusals: Mutex<(Instant, u32, u32)>,
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
                store: cfg.store,
                probe: Arc::new(Mutex::new(None)),
                shutting_down: false,
                refusals: Mutex::new((Instant::now(), 0, 0)),
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

    /// Test hook; see [`LatencyProbe`].
    pub fn set_latency_probe(&mut self, probe: Option<LatencyProbe>) {
        *self.probe.lock().unwrap_or_else(|e| e.into_inner()) = probe;
    }

    pub fn audit(&self) -> &AuditLog {
        &self.audit
    }

    /// Settle what a previous daemon left (see [`store::reconcile`]). Call
    /// once, at daemon start, before anything connects.
    pub fn reconcile(&mut self) {
        let records = self.store.load();
        let reconciled = match &self.panes {
            Some(panes) => {
                let mut panes = panes.lock().unwrap_or_else(|e| e.into_inner());
                store::reconcile(records, Some(&mut panes))
            }
            None => store::reconcile(records, None),
        };
        for info in reconciled.ended {
            let fanout = Fanout::idle(&info.terminal_id, Arc::clone(&self.probe));
            self.terminals.insert(
                info.terminal_id.clone(),
                Terminal {
                    info,
                    session: None,
                    fanout,
                },
            );
        }
        self.closed_at_start = reconciled.closed;
        self.persist();
    }

    // ── reads ─────────────────────────────────────────────────────────────────

    pub fn list(&self) -> Vec<TerminalInfo> {
        self.terminals.values().map(|t| t.info.clone()).collect()
    }

    pub fn info(&self, terminal_id: &str) -> Option<TerminalInfo> {
        self.terminals.get(terminal_id).map(|t| t.info.clone())
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
    }

    /// The connection is gone: detach it everywhere and forget it.
    pub fn unregister_conn(&mut self, _cap: &OperatorCap, conn_key: &str) {
        for t in self.terminals.values() {
            t.fanout.detach(conn_key);
        }
        self.operator_conns.remove(conn_key);
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
            kind: "focus".into(),
            tag: Some(tag.to_string()),
        };
        self.open(req, requester)
    }

    fn open(
        &mut self,
        req: OpenLocal,
        requested_by: TerminalRequester,
    ) -> Result<TerminalInfo, TerminalError> {
        let cwd = resolve_cwd(req.cwd.as_deref())?;
        let position = SplitPosition::parse(req.position.as_deref().unwrap_or(DEFAULT_POSITION))
            .map_err(TerminalError::Pane)?;
        let relative_to = req.relative_to.as_deref().unwrap_or(DEFAULT_RELATIVE_TO);
        let pane_id = self.new_pane_id(&req.tag);
        let (cols, rows) = (store::DEFAULT_COLS, store::DEFAULT_ROWS);

        // Place the leaf first: a bad `relative_to` must not start a process.
        let tree = match &self.panes {
            Some(panes) => Some(
                panes
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert_terminal_leaf(&req.tag, relative_to, position, &pane_id)
                    .map_err(TerminalError::Pane)?,
            ),
            None => None,
        };
        let session = match TerminalSession::spawn_local(&cwd, cols, rows) {
            Ok(s) => s,
            Err(e) => {
                warn!(tag = %req.tag, "terminal spawn failed: {e:#}");
                self.remove_leaf(&req.tag, &pane_id);
                return Err(TerminalError::OpenFailed);
            }
        };
        if let Some(panes) = &self.panes {
            panes
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .register_terminal_leaf(&req.tag, &pane_id);
        }

        let user_opened = requested_by.kind == "user";
        let info = TerminalInfo {
            terminal_id: Uuid::new_v4().to_string(),
            tag: req.tag.clone(),
            pane_id: pane_id.clone(),
            kind: TerminalKind::Local,
            label: LOCAL_LABEL.into(),
            cwd: Some(cwd.display().to_string()),
            target: None,
            status: TerminalStatus::Running,
            exit_code: None,
            ended_reason: None,
            cols,
            rows,
            requested_by,
            opened_by_request: req.client_request_id,
        };
        self.insert_live(info.clone(), session);
        self.persist();
        self.record(AuditEvent::Opened {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: info.tag.clone(),
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
            terminal: info.clone(),
        });
        Ok(info)
    }

    /// Track a freshly spawned session: fan-out, and the exit hook.
    fn insert_live(&mut self, info: TerminalInfo, session: Arc<TerminalSession>) {
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
            },
        );
    }

    fn new_pane_id(&self, tag: &str) -> String {
        let taken = self
            .panes
            .as_ref()
            .map(|p| p.lock().unwrap_or_else(|e| e.into_inner()).pane_ids(tag))
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
        session.write(bytes).map_err(|e| {
            warn!("terminal write failed: {e}");
            TerminalError::NotRunning
        })
    }

    pub fn resize(
        &mut self,
        _cap: &OperatorCap,
        terminal_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), TerminalError> {
        if cols == 0 || rows == 0 {
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
        self.send(ServerMsg::TerminalState { terminal: info });
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
        self.finish_closed(t.info, "user_closed", None);
        Ok(())
    }

    /// A fresh shell in an `ended` local terminal's pane, under a new id.
    pub fn restart(
        &mut self,
        _cap: &OperatorCap,
        terminal_id: &str,
    ) -> Result<TerminalInfo, TerminalError> {
        let old = self
            .terminals
            .get(terminal_id)
            .ok_or(TerminalError::UnknownTerminal)?;
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
        let session = TerminalSession::spawn_local(&cwd, cols, rows).map_err(|e| {
            warn!("terminal restart failed: {e:#}");
            TerminalError::OpenFailed
        })?;
        let old = self.terminals.remove(terminal_id).expect("checked above");
        old.fanout.close();
        let info = TerminalInfo {
            terminal_id: Uuid::new_v4().to_string(),
            cwd: Some(cwd.display().to_string()),
            status: TerminalStatus::Running,
            exit_code: None,
            ended_reason: None,
            opened_by_request: None,
            ..old.info
        };
        self.insert_live(info.clone(), session);
        self.persist();
        self.record(AuditEvent::Restarted {
            terminal_id: info.terminal_id.clone(),
            previous_terminal_id: terminal_id.to_string(),
            pane_id: info.pane_id.clone(),
            tag: info.tag.clone(),
            kind: info.kind,
        });
        self.send_pane_content(&info);
        self.send(ServerMsg::TerminalState {
            terminal: info.clone(),
        });
        Ok(info)
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
        if !self.take_refusal_budget() {
            return;
        }
        self.record(AuditEvent::Refused {
            channel,
            op: op.to_string(),
            code: code.map(str::to_string),
            terminal_id: terminal_id.filter(|id| is_id_shaped(id)).map(str::to_string),
            focus: None,
            peer_pid,
            peer_exe,
            tool: None,
        });
    }

    /// May one more `refused` line be written in the current window?
    fn take_refusal_budget(&self) -> bool {
        let mut budget = self.refusals.lock().unwrap_or_else(|e| e.into_inner());
        let (start, written, dropped) = &mut *budget;
        if start.elapsed() >= REFUSAL_WINDOW {
            if *dropped > 0 {
                warn!(dropped = *dropped, "terminal refusals not audited (rate limit)");
            }
            (*start, *written, *dropped) = (Instant::now(), 0, 0);
        }
        if *written < MAX_REFUSALS_PER_WINDOW {
            *written += 1;
            true
        } else {
            *dropped += 1;
            false
        }
    }

    fn record(&self, event: AuditEvent) {
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
        let closes = match t.info.kind {
            TerminalKind::Local => code == Some(0),
            TerminalKind::Ecs => true,
        };
        if closes {
            let t = self.terminals.remove(terminal_id).expect("present");
            self.finish_closed(t.info, "exited", code);
            return;
        }
        t.info.status = TerminalStatus::Ended;
        t.info.exit_code = code;
        let info = t.info.clone();
        self.persist();
        self.record(AuditEvent::Ended {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: info.tag.clone(),
            kind: info.kind,
            exit_code: code,
        });
        self.send(ServerMsg::TerminalState { terminal: info });
    }

    /// A terminal left the registry: remove its leaf, persist, audit, tell clients.
    fn finish_closed(&mut self, info: TerminalInfo, reason: &str, exit_code: Option<i32>) {
        let tree = self.remove_leaf(&info.tag, &info.pane_id);
        self.persist();
        self.record(AuditEvent::Closed {
            terminal_id: info.terminal_id.clone(),
            pane_id: info.pane_id.clone(),
            tag: info.tag.clone(),
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
        let mut panes = self
            .panes
            .as_ref()?
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        panes.unregister_terminal_leaf(tag, pane_id);
        panes.remove_terminal_leaf(tag, pane_id)
    }

    /// Daemon shutdown: end every shell and keep the records, so the next
    /// daemon reports them `ended / daemon_stopped`.
    pub fn shutdown(&mut self) {
        self.shutting_down = true;
        self.persist();
        for t in self.terminals.values() {
            if let Some(session) = &t.session {
                session.kill();
            }
            t.fanout.close();
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
        | ClientMsg::TerminalRestart { terminal_id } => Some(terminal_id),
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
