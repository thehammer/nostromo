//! Terminal pane 1a: the daemon-owned terminal core, over real sockets.
//!
//! These tests pin the contract of the terminal verbs on the IPC server:
//!
//! * only the verified Mac app (the injected `FakePeerVerifier` says the peer is
//!   the app **and** its `Hello` claims `client_kind: "mac_app"`) may open,
//!   attach to, type into, resize, close or restart a terminal. Any other local
//!   peer, including one that merely claims to be the app, gets a targeted
//!   `terminal_refused`, changes nothing and is audited;
//! * over TCP every terminal client frame is refused with
//!   `requires_secure_connection` (and audited), and no terminal server frame
//!   ever reaches a TCP peer;
//! * terminal bytes (`terminal_replay`, `terminal_output`) go only to the app
//!   connections attached to that terminal, never on the general broadcast;
//!   metadata (`terminal_state`, `terminal_closed`) is broadcast under
//!   `Topic::Terminal`;
//! * the shell runs as a login shell in the requested directory with the
//!   terminal environment, exits are reported with their real code, and a
//!   re-attach replays what happened;
//! * the audit trail never contains keystrokes or output.
//!
//! Shells are driven through the wire only. A shell's prompt format is never
//! assumed: every interaction types a command that ends in a unique marker and
//! waits for the marker to appear in the output (the marker is produced with
//! `printf 'DONE-%s\n' <n>`, so the echoed command line never contains it).
//!
//! Synchronisation: after a request the helpers `Ping` and read to the `Pong`
//! (the main loop answers it only after earlier targeted replies were written);
//! "nothing arrived" is proven by a control frame broadcast afterwards (the
//! broadcast channel is ordered) or by a short quiet window.
//!
//! Hermetic: the socket, audit log, terminal store and every shell's working
//! directory live in temp dirs; the only network is loopback.

use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::{PaneRegistry, SplitPosition};
use nostromo::ipc::peer_verify::testing::{app_info, script_info, FakePeerVerifier};
use nostromo::ipc::peer_verify::PeerInfo;
use nostromo::ipc::protocol::{
    ClientMsg, PaneContentWire, PaneTree, ServerMsg, TerminalClosedInfo, TerminalInfo,
    TerminalKind, TerminalRequester, TerminalStatus, TerminalTarget, Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::SessionManager;
use nostromo::terminal::audit::AuditLog;
use nostromo::terminal::store::{TerminalRecord, TerminalStore};
use nostromo::terminal::{TerminalConfig, TerminalManager};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};
use tokio::sync::mpsc;

const TAG: &str = "term-it";
const WAIT: Duration = Duration::from_secs(15);

// ── process environment ──────────────────────────────────────────────────────

/// Variables a shell opened by the daemon must NOT inherit.
const LEAKY_VARS: &[&str] = &[
    "NOSTROMO_PTY_ID",
    "NOSTROMO_VIEW_ID",
    "NOSTROMO_FOCUS_TAG",
    "NOSTROMO_SESSION_ID",
    "NOSTROMO_MCP_SOCKET",
    "NOSTROMO_PTY",
    "NOSTROMO_GUARD_BIN",
    "NOSTROMO_APPROVALS_DIR",
    "CLAUDECODE",
];

/// Once per test process, before any daemon or shell starts: put every
/// variable a terminal must scrub into the daemon's own environment (so a
/// leak would show), mark one ordinary variable that must pass through, and ask
/// for `/bin/sh` as the login shell for speed and determinism where the
/// daemon honours `$SHELL`. Nothing here touches the real `~/.nostromo`.
fn isolate_process_env() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let scratch = std::env::temp_dir().join(format!("terminal-core-it-{}", std::process::id()));
        for var in LEAKY_VARS {
            std::env::set_var(var, format!("leaked-{var}"));
        }
        std::env::set_var("NOSTROMO_APPROVALS_DIR", scratch.join("approvals"));
        std::env::set_var("NOSTROMO_MCP_SOCKET", scratch.join("mcp.sock"));
        std::env::set_var("NOSTROMO_GUARD_BIN", scratch.join("no-such-guard"));
        std::env::set_var("NOSTROMO_TERMINAL_IT_PASSTHROUGH", "ok42");
        std::env::set_var("SHELL", "/bin/sh");
    });
}

// ── small utilities ──────────────────────────────────────────────────────────

fn find_sub(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

fn count_sub(hay: &[u8], needle: &[u8]) -> usize {
    if needle.is_empty() || hay.len() < needle.len() {
        return 0;
    }
    hay.windows(needle.len()).filter(|w| *w == needle).count()
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// A temp directory and its canonical path (macOS: `/var` is `/private/var`).
fn canonical_tmp() -> (TempDir, PathBuf) {
    let dir = TempDir::new().expect("tempdir");
    let canonical = std::fs::canonicalize(dir.path()).expect("canonicalize");
    (dir, canonical)
}

/// `terminal-` plus 8 lowercase hex digits.
fn is_terminal_pane_id(id: &str) -> bool {
    id.len() == "terminal-".len() + 8
        && id.starts_with("terminal-")
        && id["terminal-".len()..]
            .chars()
            .all(|c| matches!(c, '0'..='9' | 'a'..='f'))
}

fn terminal_leaves_of(tree: &PaneTree) -> Vec<String> {
    tree.pane_ids()
        .into_iter()
        .filter(|p| p.starts_with("terminal-"))
        .collect()
}

fn is_terminal_server_frame(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::TerminalList { .. }
            | ServerMsg::TerminalState { .. }
            | ServerMsg::TerminalClosed(_)
            | ServerMsg::TerminalReplay { .. }
            | ServerMsg::TerminalOutput { .. }
            | ServerMsg::TerminalRefused { .. }
    )
}

fn is_terminal_bytes_frame(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::TerminalReplay { .. } | ServerMsg::TerminalOutput { .. }
    )
}

fn msg_type(m: &ServerMsg) -> String {
    serde_json::to_value(m)
        .ok()
        .and_then(|v| v["type"].as_str().map(str::to_string))
        .unwrap_or_else(|| "?".into())
}

async fn eventually(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// Every parsable line of a JSONL file (a half-written last line is skipped).
fn read_jsonl(path: &Path) -> Vec<Value> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// `terminal_open_local` -> `open`, `terminal_refusal_report` -> `refusal_report`.
fn normalize_op(op: &str) -> String {
    let op = op.strip_prefix("terminal_").unwrap_or(op);
    op.strip_suffix("_local").unwrap_or(op).to_string()
}

/// Who an audit `opened` line says asked: a string or a `{kind}` object.
fn requester_kind(line: &Value) -> Option<String> {
    match &line["requested_by"] {
        Value::String(s) => Some(s.clone()),
        Value::Object(o) => o.get("kind").and_then(Value::as_str).map(str::to_string),
        _ => None,
    }
}

// ── the wire client ──────────────────────────────────────────────────────────

/// One connection. A background task reads frames so a timed-out wait never
/// cancels a half-read frame; everything read is kept in `log`, and the bytes a
/// terminal sent (replay, then output) are kept per terminal in `view`.
struct Client<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> {
    writer: tokio::io::WriteHalf<S>,
    rx: mpsc::UnboundedReceiver<Result<ServerMsg, String>>,
    reader: tokio::task::JoinHandle<()>,
    log: Vec<ServerMsg>,
    view: HashMap<String, Vec<u8>>,
    nonce: Option<String>,
    closed: bool,
    /// While set, the background reader takes no more frames off the socket.
    read_gate: Arc<AtomicBool>,
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> Drop for Client<S> {
    fn drop(&mut self) {
        // Dropping the reader task drops the read half; with the write half
        // gone too the socket closes, which is how a client "disconnects".
        self.reader.abort();
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> Client<S> {
    fn new(stream: S) -> Self {
        let (mut read_half, writer) = tokio::io::split(stream);
        let (tx, rx) = mpsc::unbounded_channel();
        let read_gate = Arc::new(AtomicBool::new(false));
        let gate = Arc::clone(&read_gate);
        let reader = tokio::spawn(async move {
            loop {
                while gate.load(Ordering::SeqCst) {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                let Ok(bytes) = read_frame(&mut read_half).await else {
                    break;
                };
                let parsed = serde_json::from_slice::<ServerMsg>(&bytes).map_err(|e| {
                    format!(
                        "{e}: {}",
                        String::from_utf8_lossy(&bytes[..bytes.len().min(300)])
                    )
                });
                if tx.send(parsed).is_err() {
                    break;
                }
            }
        });
        Self {
            writer,
            rx,
            reader,
            log: Vec::new(),
            view: HashMap::new(),
            nonce: None,
            closed: false,
            read_gate,
        }
    }

    /// Stop taking frames off the socket (at most one more is read), so what
    /// the daemon writes piles up in the socket buffers and its own queues.
    fn stop_reading(&self) {
        self.read_gate.store(true, Ordering::SeqCst);
    }

    fn resume_reading(&self) {
        self.read_gate.store(false, Ordering::SeqCst);
    }

    /// Hello (with `claim` as `client_kind`) -> Welcome -> Subscribe -> synced.
    async fn handshake(stream: S, claim: Option<&str>, topics: Vec<Topic>, caps: &[&str]) -> Self {
        let mut c = Self::new(stream);
        c.send(&ClientMsg::Hello {
            client_id: "terminal-core-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: claim.map(str::to_string),
        })
        .await;
        let (_, welcome) = c
            .wait_since(0, "a Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await;
        if let ServerMsg::Welcome { operator_nonce, .. } = welcome {
            c.nonce = operator_nonce;
        }
        c.send(&ClientMsg::Subscribe {
            topics,
            renders_decisions: false,
            renders_approvals: false,
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            // Echo the Welcome's nonce, as the app does: only then are a
            // verified app's terminal verbs honoured.
            operator_nonce: c.nonce.clone(),
        })
        .await;
        c.sync().await;
        c
    }

    async fn send(&mut self, msg: &ClientMsg) {
        write_frame(&mut self.writer, &serde_json::to_vec(msg).unwrap())
            .await
            .expect("write frame");
    }

    fn ingest(&mut self, msg: ServerMsg) {
        match &msg {
            ServerMsg::TerminalReplay {
                terminal_id, bytes, ..
            } => {
                // A replay resets the view of that terminal.
                self.view.insert(
                    terminal_id.clone(),
                    B64.decode(bytes).expect("replay is base64"),
                );
            }
            ServerMsg::TerminalOutput { terminal_id, bytes } => {
                self.view
                    .entry(terminal_id.clone())
                    .or_default()
                    .extend(B64.decode(bytes).expect("output is base64"));
            }
            _ => {}
        }
        self.log.push(msg);
    }

    /// Read one frame within `within`; false on timeout or a closed connection.
    async fn pump(&mut self, within: Duration) -> bool {
        match tokio::time::timeout(within, self.rx.recv()).await {
            Ok(Some(Ok(msg))) => {
                self.ingest(msg);
                true
            }
            Ok(Some(Err(e))) => panic!("undecodable server frame: {e}"),
            Ok(None) => {
                self.closed = true;
                false
            }
            Err(_) => false,
        }
    }

    fn mark(&self) -> usize {
        self.log.len()
    }

    fn summary(&self) -> String {
        let mut parts: Vec<(String, usize)> = Vec::new();
        for m in &self.log {
            let t = msg_type(m);
            match parts.last_mut() {
                Some((last, n)) if *last == t => *n += 1,
                _ => parts.push((t, 1)),
            }
        }
        parts
            .iter()
            .map(|(t, n)| {
                if *n > 1 {
                    format!("{t} x{n}")
                } else {
                    t.clone()
                }
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// The first frame at or after log index `from` that `pred` accepts,
    /// waiting for it if it has not arrived.
    async fn wait_since(
        &mut self,
        from: usize,
        what: &str,
        pred: impl Fn(&ServerMsg) -> bool,
    ) -> (usize, ServerMsg) {
        let deadline = Instant::now() + WAIT;
        let mut i = from;
        loop {
            while i < self.log.len() {
                if pred(&self.log[i]) {
                    return (i, self.log[i].clone());
                }
                i += 1;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.pump(left).await {
                panic!(
                    "timed out waiting for {what} (connection closed: {}); frames seen: [{}]",
                    self.closed,
                    self.summary()
                );
            }
        }
    }

    /// Ping and read to the Pong; the cursor of nothing else moves.
    async fn sync(&mut self) {
        let from = self.mark();
        self.send(&ClientMsg::Ping).await;
        self.wait_since(from, "a Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
    }

    /// Keep reading for `d` (collecting frames).
    async fn settle(&mut self, d: Duration) {
        let end = Instant::now() + d;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            if !self.pump(left).await && self.closed {
                return;
            }
        }
    }

    async fn settle_ms(&mut self, ms: u64) {
        self.settle(Duration::from_millis(ms)).await;
    }

    fn view(&self, terminal_id: &str) -> &[u8] {
        self.view.get(terminal_id).map(Vec::as_slice).unwrap_or(&[])
    }

    /// Wait up to `timeout` until `view[from..]` contains `needle`.
    async fn wait_view_from(
        &mut self,
        terminal_id: &str,
        from: usize,
        needle: &str,
        timeout: Duration,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            let v = self.view(terminal_id);
            if v.len() >= from && find_sub(&v[from..], needle.as_bytes()).is_some() {
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() || !self.pump(left).await {
                let v = self.view(terminal_id);
                return v.len() >= from && find_sub(&v[from..], needle.as_bytes()).is_some();
            }
        }
    }

    async fn wait_view(&mut self, terminal_id: &str, needle: &str) {
        if !self.wait_view_from(terminal_id, 0, needle, WAIT).await {
            let tail = lossy(self.view(terminal_id));
            let tail: String = tail
                .chars()
                .rev()
                .take(400)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            panic!(
                "timed out waiting for {needle:?} in terminal output; frames: [{}]; output tail: {tail:?}",
                self.summary()
            );
        }
    }
}

type Unix = Client<UnixStream>;
type Tcp = Client<TcpStream>;

// ── terminal helpers on a connection ─────────────────────────────────────────

static MARKERS: AtomicUsize = AtomicUsize::new(1);

fn next_marker() -> String {
    format!("{:06}", MARKERS.fetch_add(1, Ordering::SeqCst))
}

fn b64(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

fn open_msg(tag: &str, cwd: Option<&Path>, request_id: &str) -> ClientMsg {
    ClientMsg::TerminalOpenLocal {
        tag: tag.into(),
        relative_to: None,
        position: None,
        cwd: cwd.map(|p| p.to_string_lossy().into_owned()),
        client_request_id: request_id.into(),
    }
}

impl Unix {
    async fn input(&mut self, terminal_id: &str, bytes: &[u8]) {
        self.send(&ClientMsg::TerminalInput {
            terminal_id: terminal_id.into(),
            bytes: b64(bytes),
            auto_reply: false,
        })
        .await;
    }

    /// Type `line` and press Return.
    async fn type_line(&mut self, terminal_id: &str, line: &str) {
        self.input(terminal_id, format!("{line}\r").as_bytes())
            .await;
    }

    /// `terminal_open_local` and the `terminal_state` that answers it.
    async fn open(&mut self, tag: &str, cwd: Option<&Path>, request_id: &str) -> TerminalInfo {
        let from = self.mark();
        self.send(&open_msg(tag, cwd, request_id)).await;
        let (_, state) = self
            .wait_since(from, "the terminal_state for the open", |m| {
                matches!(m, ServerMsg::TerminalState { terminal }
                    if terminal.opened_by_request.as_deref() == Some(request_id))
            })
            .await;
        match state {
            ServerMsg::TerminalState { terminal } => terminal,
            _ => unreachable!(),
        }
    }

    /// Attach and wait for the replay; returns its `(cols, rows)`.
    async fn attach(&mut self, terminal_id: &str) -> (u16, u16) {
        let from = self.mark();
        self.send(&ClientMsg::TerminalAttach {
            terminal_id: terminal_id.into(),
        })
        .await;
        let (_, replay) = self
            .wait_since(from, "the terminal_replay for the attach", |m| {
                matches!(m, ServerMsg::TerminalReplay { terminal_id: id, .. } if id == terminal_id)
            })
            .await;
        match replay {
            ServerMsg::TerminalReplay { cols, rows, .. } => (cols, rows),
            _ => unreachable!(),
        }
    }

    /// Type a harmless command until the shell has answered one: the shell may
    /// still be starting (rc files), so retry rather than assume.
    async fn shell_ready(&mut self, terminal_id: &str) {
        for _ in 0..6 {
            let n = next_marker();
            self.type_line(terminal_id, &format!("printf 'RDY-%s\\n' {n}"))
                .await;
            if self
                .wait_view_from(terminal_id, 0, &format!("RDY-{n}"), Duration::from_secs(5))
                .await
            {
                return;
            }
        }
        panic!(
            "the shell never answered; frames: [{}]; output: {:?}",
            self.summary(),
            lossy(self.view(terminal_id))
        );
    }

    /// Run `cmd` in the shell and return the output from the moment it was
    /// typed up to its end marker.
    async fn run(&mut self, terminal_id: &str, cmd: &str) -> String {
        let n = next_marker();
        let start = self.view(terminal_id).len();
        self.type_line(terminal_id, &format!("{cmd}; printf 'DONE-%s\\n' {n}"))
            .await;
        self.wait_view(terminal_id, &format!("DONE-{n}")).await;
        lossy(&self.view(terminal_id)[start..])
    }

    /// Open a terminal in `cwd`, attach, and wait until its shell answers.
    async fn open_ready(&mut self, cwd: &Path) -> TerminalInfo {
        let info = self
            .open(TAG, Some(cwd), &format!("req-{}", next_marker()))
            .await;
        self.attach(&info.terminal_id).await;
        self.shell_ready(&info.terminal_id).await;
        info
    }
}

// ── the daemon under test ────────────────────────────────────────────────────

/// The fake verifier that makes the n-th Unix connection `peers[n]`.
fn peer_verifier(peers: &[Peer]) -> FakePeerVerifier {
    let script: Vec<Option<PeerInfo>> = peers
        .iter()
        .map(|p| {
            Some(match p {
                Peer::App => app_info(),
                Peer::Script => script_info(),
            })
        })
        .collect();
    FakePeerVerifier::scripted(script, Some(script_info()))
}

/// Who the fake verifier says the n-th Unix connection is, in connect order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Peer {
    /// The genuine, pinned Mac app (still needs the `mac_app` claim).
    App,
    /// An ordinary local process (an agent's script).
    Script,
}

struct Daemon {
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    terminals: Arc<Mutex<TerminalManager>>,
    panes: Arc<Mutex<PaneRegistry>>,
    audit_path: PathBuf,
    store_path: PathBuf,
    _tmp: TempDir,
}

impl Drop for Daemon {
    /// No test may leave a shell behind (the tokio runtime waits for the
    /// blocking reader threads, which only end when the child dies).
    fn drop(&mut self) {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .shutdown();
    }
}

impl Daemon {
    /// A daemon with a real audit file and terminal store in a temp dir, and a
    /// pane registry. `peers` is who each Unix connection will be, in order.
    async fn start(peers: &[Peer]) -> Daemon {
        isolate_process_env();
        let tmp = TempDir::new().expect("tempdir");
        let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
        let audit_path = tmp.path().join("audit").join("terminal.jsonl");
        let store_path = tmp.path().join("daemon-terminals.json");
        let terminals = TerminalManager::new(TerminalConfig {
            audit: AuditLog::open(&audit_path).expect("open the audit log"),
            store: TerminalStore::at(&store_path),
            pane_registry: Some(Arc::clone(&panes)),
        });
        Self::serve(peers, tmp, terminals, panes, audit_path, store_path).await
    }

    /// Bind a server around an existing manager (a "restarted" daemon).
    async fn serve(
        peers: &[Peer],
        tmp: TempDir,
        terminals: Arc<Mutex<TerminalManager>>,
        panes: Arc<Mutex<PaneRegistry>>,
        audit_path: PathBuf,
        store_path: PathBuf,
    ) -> Daemon {
        Self::serve_with(
            peer_verifier(peers),
            tmp,
            terminals,
            panes,
            audit_path,
            store_path,
        )
        .await
    }

    /// [`Daemon::start`] with a verifier of the test's own.
    async fn start_with(verifier: FakePeerVerifier) -> Daemon {
        isolate_process_env();
        let tmp = TempDir::new().expect("tempdir");
        let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
        let audit_path = tmp.path().join("audit").join("terminal.jsonl");
        let store_path = tmp.path().join("daemon-terminals.json");
        let terminals = TerminalManager::new(TerminalConfig {
            audit: AuditLog::open(&audit_path).expect("open the audit log"),
            store: TerminalStore::at(&store_path),
            pane_registry: Some(Arc::clone(&panes)),
        });
        Self::serve_with(verifier, tmp, terminals, panes, audit_path, store_path).await
    }

    async fn serve_with(
        verifier: FakePeerVerifier,
        tmp: TempDir,
        terminals: Arc<Mutex<TerminalManager>>,
        panes: Arc<Mutex<PaneRegistry>>,
        audit_path: PathBuf,
        store_path: PathBuf,
    ) -> Daemon {
        isolate_process_env();
        let socket_path = tmp.path().join("test.sock");
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
        let verifier = Arc::new(verifier);

        let server = Server::bind(
            &socket_path,
            Arc::clone(&session_mgr),
            tmp.path().join("perri-state"),
            Arc::clone(&decisions),
            verifier,
            false,
            Arc::clone(&terminals),
        )
        .expect("bind unix socket");
        let tcp_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind tcp listener");
        let tcp_port = tcp_listener.local_addr().expect("local addr").port();
        server.bind_tcp(
            tcp_listener,
            Arc::clone(&session_mgr),
            tmp.path().join("perri-state"),
            Arc::clone(&decisions),
        );

        Daemon {
            server,
            socket_path,
            tcp_port,
            terminals,
            panes,
            audit_path,
            store_path,
            _tmp: tmp,
        }
    }

    /// A Unix connection that claims `claim` as its `client_kind`.
    async fn unix(&self, topics: Vec<Topic>, claim: Option<&str>, caps: &[&str]) -> Unix {
        let stream = UnixStream::connect(&self.socket_path)
            .await
            .expect("unix connect");
        Client::handshake(stream, claim, topics, caps).await
    }

    /// The operator app: the verifier must have said "app" for this connection.
    async fn app(&self, topics: Vec<Topic>) -> Unix {
        let c = self.unix(topics, Some("mac_app"), &["terminal_ui"]).await;
        assert!(
            c.nonce.is_some(),
            "the verified app's Welcome must carry an operator_nonce (is the Peer list right?)"
        );
        c
    }

    /// A local process that does not claim to be the app.
    async fn script(&self, topics: Vec<Topic>) -> Unix {
        let c = self.unix(topics, None, &[]).await;
        assert!(c.nonce.is_none(), "a non-operator gets no operator_nonce");
        c
    }

    /// A local process that claims to be the app (the verifier decides).
    async fn claiming_app(&self, topics: Vec<Topic>) -> Unix {
        let c = self.unix(topics, Some("mac_app"), &["terminal_ui"]).await;
        assert!(
            c.nonce.is_none(),
            "a claim without a verified bundle must not make an operator"
        );
        c
    }

    /// A TCP connection (it claims `mac_app`; the claim never lifts a network peer).
    async fn tcp(&self, topics: Vec<Topic>) -> Tcp {
        let stream = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        Client::handshake(stream, Some("mac_app"), topics, &[]).await
    }

    fn list(&self) -> Vec<TerminalInfo> {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .list()
    }

    fn info(&self, terminal_id: &str) -> Option<TerminalInfo> {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .info(terminal_id)
    }

    fn tree(&self, tag: &str) -> Option<PaneTree> {
        self.panes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(tag)
            .cloned()
    }

    fn registered_leaves(&self, tag: &str) -> Vec<String> {
        self.panes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .terminal_leaves(tag)
    }

    fn audit(&self) -> Vec<Value> {
        read_jsonl(&self.audit_path)
    }

    /// The first audit line `pred` accepts, waiting for it.
    async fn wait_audit(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(line) = self.audit().into_iter().find(|l| pred(l)) {
                return line;
            }
            assert!(
                Instant::now() < deadline,
                "timed out waiting for an audit line: {what}; audit so far: {:#?}",
                self.audit()
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// Every audit-directory file's text, live and rotated.
    fn all_audit_text(&self) -> String {
        let dir = self.audit_path.parent().unwrap();
        let mut text = String::new();
        for entry in std::fs::read_dir(dir).expect("audit dir").flatten() {
            text.push_str(&std::fs::read_to_string(entry.path()).unwrap_or_default());
        }
        text
    }

    /// Broadcast a control frame every connection receives and wait for it on
    /// `c`: anything earlier on the (ordered) broadcast channel that was going to
    /// be delivered to `c` has been by then.
    async fn flush_broadcast_to<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
        &self,
        c: &mut Client<S>,
    ) {
        let from = c.mark();
        self.server.broadcast(ServerMsg::Pong);
        c.wait_since(from, "the control broadcast", |m| {
            matches!(m, ServerMsg::Pong)
        })
        .await;
    }
}

// ── 1. opening a terminal ────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn an_app_connection_opens_a_terminal_leaf_with_a_login_shell_in_the_requested_cwd() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_cwd_guard, cwd) = canonical_tmp();

    let from = app.mark();
    app.send(&open_msg(TAG, Some(&cwd), "req-open-1")).await;

    // A layout carrying the new leaf: below the REPL by default.
    let (i_layout, layout) = app
        .wait_since(from, "a FocusLayout carrying the new terminal leaf", |m| {
            matches!(m, ServerMsg::FocusLayout { tag, tree, .. }
                if tag == TAG && tree.pane_ids().iter().any(|p| is_terminal_pane_id(p)))
        })
        .await;
    let ServerMsg::FocusLayout {
        tree, focused_pane, ..
    } = layout
    else {
        unreachable!()
    };
    let pane_id = terminal_leaves_of(&tree).remove(0);
    assert_eq!(
        tree.pane_ids(),
        ["repl".to_string(), pane_id.clone()],
        "a new terminal splits below the REPL leaf by default"
    );
    assert_eq!(
        focused_pane.as_deref(),
        Some(pane_id.as_str()),
        "a terminal the user opened takes keyboard focus"
    );

    // The placeholder content iOS shows, with no environment for a local shell.
    let (i_content, content) = app
        .wait_since(from, "the pane_content placeholder for the leaf", |m| {
            matches!(m, ServerMsg::PaneContent { tag, pane_id: p, content: PaneContentWire::Terminal { .. }, .. }
                if tag == TAG && *p == pane_id)
        })
        .await;
    let wire = serde_json::to_value(&content).unwrap();
    let ServerMsg::PaneContent {
        content:
            PaneContentWire::Terminal {
                terminal_id: content_id,
                label,
                environment,
            },
        ..
    } = content
    else {
        unreachable!()
    };
    assert!(!label.is_empty(), "the placeholder carries a label");
    assert_eq!(environment, None, "a local terminal has no environment");
    assert_eq!(wire["content"]["kind"], "terminal");
    assert!(
        wire["content"].get("environment").is_none(),
        "a local terminal's PaneContent has no environment key"
    );

    // Then the state: running, answering the request, asked for by the user.
    let (i_state, state) = app
        .wait_since(from, "terminal_state answering the open", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.opened_by_request.as_deref() == Some("req-open-1"))
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert!(
        i_layout < i_content && i_content < i_state,
        "order: layout, content, state"
    );
    assert_eq!(terminal.status, TerminalStatus::Running);
    assert_eq!(terminal.kind, TerminalKind::Local);
    assert_eq!(terminal.tag, TAG);
    assert_eq!(terminal.pane_id, pane_id);
    assert_eq!(terminal.terminal_id, content_id);
    assert_eq!(terminal.requested_by.kind, "user");
    assert_eq!(terminal.exit_code, None);
    assert!(
        uuid::Uuid::parse_str(&terminal.terminal_id).is_ok(),
        "terminal ids are UUIDs: {}",
        terminal.terminal_id
    );
    assert!(is_terminal_pane_id(&terminal.pane_id));

    // The daemon agrees, and registered the leaf.
    assert_eq!(d.info(&terminal.terminal_id), Some(terminal.clone()));
    assert_eq!(d.registered_leaves(TAG), vec![pane_id.clone()]);

    // The shell really runs in the requested directory.
    app.attach(&terminal.terminal_id).await;
    app.shell_ready(&terminal.terminal_id).await;
    let out = app
        .run(&terminal.terminal_id, "printf 'CWD-IS:%s\\n' \"$(pwd -P)\"")
        .await;
    assert!(
        out.contains(&format!("CWD-IS:{}", cwd.display())),
        "the shell must start in {}; output was {out:?}",
        cwd.display()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn opening_places_the_leaf_relative_to_the_pane_and_side_the_request_names() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();

    let a = app.open(TAG, Some(&cwd), "place-a").await;
    assert_eq!(
        d.tree(TAG).unwrap().pane_ids(),
        ["repl".to_string(), a.pane_id.clone()]
    );

    // split_left of repl puts the new leaf before it.
    app.send(&ClientMsg::TerminalOpenLocal {
        tag: TAG.into(),
        relative_to: Some("repl".into()),
        position: Some("split_left".into()),
        cwd: Some(cwd.to_string_lossy().into_owned()),
        client_request_id: "place-b".into(),
    })
    .await;
    let (_, b) = app
        .wait_since(0, "terminal_state for place-b", |m| {
            matches!(m, ServerMsg::TerminalState { terminal } if terminal.opened_by_request.as_deref() == Some("place-b"))
        })
        .await;
    let ServerMsg::TerminalState { terminal: b } = b else {
        unreachable!()
    };
    assert_eq!(
        d.tree(TAG).unwrap().pane_ids(),
        [b.pane_id.clone(), "repl".to_string(), a.pane_id.clone()]
    );

    // split_right of the first terminal puts the new leaf after it.
    app.send(&ClientMsg::TerminalOpenLocal {
        tag: TAG.into(),
        relative_to: Some(a.pane_id.clone()),
        position: Some("split_right".into()),
        cwd: Some(cwd.to_string_lossy().into_owned()),
        client_request_id: "place-c".into(),
    })
    .await;
    let (_, c) = app
        .wait_since(0, "terminal_state for place-c", |m| {
            matches!(m, ServerMsg::TerminalState { terminal } if terminal.opened_by_request.as_deref() == Some("place-c"))
        })
        .await;
    let ServerMsg::TerminalState { terminal: c } = c else {
        unreachable!()
    };
    assert_eq!(
        d.tree(TAG).unwrap().pane_ids(),
        [
            b.pane_id.clone(),
            "repl".to_string(),
            a.pane_id.clone(),
            c.pane_id.clone()
        ]
    );
    let mut ids: BTreeSet<String> = [&a, &b, &c].iter().map(|t| t.pane_id.clone()).collect();
    assert_eq!(ids.len(), 3, "every terminal gets its own pane id");
    ids.extend([&a, &b, &c].iter().map(|t| t.terminal_id.clone()));
    assert_eq!(ids.len(), 6, "and its own terminal id");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_open_that_cannot_proceed_is_refused_and_creates_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();

    let bad_requests = [
        // A working directory that does not exist.
        ClientMsg::TerminalOpenLocal {
            tag: TAG.into(),
            relative_to: None,
            position: None,
            cwd: Some(cwd.join("no-such-dir").to_string_lossy().into_owned()),
            client_request_id: "bad-cwd".into(),
        },
        // A pane to split that does not exist.
        ClientMsg::TerminalOpenLocal {
            tag: TAG.into(),
            relative_to: Some("no-such-pane".into()),
            position: None,
            cwd: Some(cwd.to_string_lossy().into_owned()),
            client_request_id: "bad-pane".into(),
        },
    ];
    for request in bad_requests {
        let from = app.mark();
        app.send(&request).await;
        let (_, refused) = app
            .wait_since(
                from,
                "a terminal_refused for the open",
                |m| matches!(m, ServerMsg::TerminalRefused { op, .. } if op == "open"),
            )
            .await;
        let ServerMsg::TerminalRefused { code, .. } = refused else {
            unreachable!()
        };
        assert!(!code.is_empty(), "a refusal names its reason");
        app.settle_ms(300).await;
        assert!(
            !app.log[from..]
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalState { .. })),
            "a failed open must not announce a terminal: [{}]",
            app.summary()
        );
        assert!(d.list().is_empty(), "a failed open creates no terminal");
        assert!(
            d.tree(TAG)
                .map(|t| terminal_leaves_of(&t))
                .unwrap_or_default()
                .is_empty(),
            "a failed open leaves no leaf behind"
        );
        assert!(d.registered_leaves(TAG).is_empty());
    }

    // The daemon is not wedged: a good open still works.
    let info = app.open_ready(&cwd).await;
    assert_eq!(info.status, TerminalStatus::Running);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_agent_opened_terminal_is_recorded_as_the_focus_and_does_not_take_keyboard_focus() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();

    let from = app.mark();
    let info = d
        .terminals
        .lock()
        .unwrap()
        .open_local_for_agent(TAG, Some(cwd.clone()))
        .expect("an agent may open a shell in its own focus");
    assert_eq!(info.requested_by.kind, "focus");
    assert_eq!(info.tag, TAG);
    assert_eq!(info.status, TerminalStatus::Running);

    let (_, layout) = app
        .wait_since(from, "the layout carrying the agent's terminal", |m| {
            matches!(m, ServerMsg::FocusLayout { tag, tree, .. }
                if tag == TAG && tree.pane_ids().contains(&info.pane_id))
        })
        .await;
    let ServerMsg::FocusLayout { focused_pane, .. } = layout else {
        unreachable!()
    };
    assert_eq!(
        focused_pane, None,
        "an agent-opened pane does not take keyboard focus"
    );
    let (_, state) = app
        .wait_since(from, "terminal_state for the agent's terminal", |m| {
            matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == info.terminal_id)
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert_eq!(terminal.requested_by.kind, "focus");
    assert_eq!(terminal.opened_by_request, None);

    let line = d
        .wait_audit("opened by the focus", |l| {
            l["event"] == "opened" && l["terminal_id"] == info.terminal_id.as_str()
        })
        .await;
    assert_eq!(requester_kind(&line).as_deref(), Some("focus"));
}

// ── 2. exit, ended, restart ──────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn exit_0_removes_the_leaf_and_reports_the_terminal_closed_as_exited() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let from = app.mark();
    app.type_line(&info.terminal_id, "exit").await;

    let (_, closed) = app
        .wait_since(
            from,
            "terminal_closed for the exit",
            |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == info.terminal_id),
        )
        .await;
    let ServerMsg::TerminalClosed(closed) = closed else {
        unreachable!()
    };
    assert_eq!(closed.reason, "exited");
    assert_eq!(closed.exit_code, Some(0));
    assert_eq!(closed.pane_id, info.pane_id);
    assert_eq!(closed.tag, TAG);
    assert_eq!(closed.kind, TerminalKind::Local);

    let (_, layout) = app
        .wait_since(from, "a FocusLayout without the leaf", |m| {
            matches!(m, ServerMsg::FocusLayout { tag, tree, .. }
                if tag == TAG && !tree.pane_ids().contains(&info.pane_id))
        })
        .await;
    let ServerMsg::FocusLayout { tree, .. } = layout else {
        unreachable!()
    };
    assert_eq!(
        tree,
        PaneTree::repl_leaf(),
        "the split collapses back to the REPL"
    );

    eventually("the terminal to be forgotten", || {
        d.info(&info.terminal_id).is_none()
    })
    .await;
    assert!(d.list().is_empty());
    assert!(d.registered_leaves(TAG).is_empty());
    assert_eq!(d.tree(TAG), Some(PaneTree::repl_leaf()));

    let line = d
        .wait_audit("closed(exited)", |l| {
            l["event"] == "closed" && l["terminal_id"] == info.terminal_id.as_str()
        })
        .await;
    assert_eq!(line["reason"], "exited");
    assert_eq!(line["exit_code"], 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failing_exit_keeps_the_leaf_as_ended_and_restart_gives_a_fresh_shell_in_the_same_pane() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let from = app.mark();
    app.type_line(&info.terminal_id, "exit 3").await;
    let (_, state) = app
        .wait_since(from, "terminal_state ended", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == info.terminal_id && terminal.status == TerminalStatus::Ended)
        })
        .await;
    let ServerMsg::TerminalState { terminal: ended } = state else {
        unreachable!()
    };
    assert_eq!(ended.exit_code, Some(3));
    assert_eq!(ended.pane_id, info.pane_id);

    // The pane stays; nothing says it closed.
    app.settle_ms(300).await;
    assert!(
        !app.log[from..]
            .iter()
            .any(|m| matches!(m, ServerMsg::TerminalClosed(_))),
        "a failing exit must not close the pane: [{}]",
        app.summary()
    );
    assert!(d.tree(TAG).unwrap().pane_ids().contains(&info.pane_id));
    assert_eq!(d.registered_leaves(TAG), vec![info.pane_id.clone()]);
    assert_eq!(
        d.info(&info.terminal_id).map(|t| (t.status, t.exit_code)),
        Some((TerminalStatus::Ended, Some(3)))
    );
    let ended_line = d
        .wait_audit("ended(3)", |l| {
            l["event"] == "ended" && l["terminal_id"] == info.terminal_id.as_str()
        })
        .await;
    assert_eq!(ended_line["exit_code"], 3);

    // Restart: same pane, a new terminal id, running, and a working shell.
    let from = app.mark();
    app.send(&ClientMsg::TerminalRestart {
        terminal_id: info.terminal_id.clone(),
    })
    .await;
    let (_, state) = app
        .wait_since(from, "terminal_state running for the restart", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.pane_id == info.pane_id
                    && terminal.status == TerminalStatus::Running
                    && terminal.terminal_id != info.terminal_id)
        })
        .await;
    let ServerMsg::TerminalState { terminal: fresh } = state else {
        unreachable!()
    };
    assert_eq!(fresh.tag, TAG);
    assert_eq!(fresh.exit_code, None);
    assert_ne!(fresh.terminal_id, info.terminal_id);

    eventually("the old terminal id to be gone", || {
        d.info(&info.terminal_id).is_none()
    })
    .await;
    let live = d.list();
    assert_eq!(live.len(), 1, "one terminal in the pane: {live:?}");
    assert_eq!(live[0].terminal_id, fresh.terminal_id);
    assert_eq!(
        d.tree(TAG).unwrap().pane_ids(),
        ["repl".to_string(), info.pane_id.clone()]
    );

    app.attach(&fresh.terminal_id).await;
    app.shell_ready(&fresh.terminal_id).await;
    let out = app.run(&fresh.terminal_id, "echo FRESH-$((6*7))").await;
    assert!(
        out.contains("FRESH-42"),
        "the restarted shell works: {out:?}"
    );

    d.wait_audit("restarted", |l| {
        l["event"] == "restarted" && l["pane_id"] == info.pane_id.as_str()
    })
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restart_of_a_running_terminal_changes_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let from = app.mark();
    app.send(&ClientMsg::TerminalRestart {
        terminal_id: info.terminal_id.clone(),
    })
    .await;
    app.sync().await;
    app.settle_ms(300).await;

    assert!(
        !app.log[from..].iter().any(|m| matches!(
            m,
            ServerMsg::TerminalState { .. } | ServerMsg::TerminalClosed(_)
        )),
        "restarting a running terminal must not change it: [{}]",
        app.summary()
    );
    let live = d.list();
    assert_eq!(live.len(), 1);
    assert_eq!(live[0].terminal_id, info.terminal_id);
    assert_eq!(live[0].status, TerminalStatus::Running);
    let out = app.run(&info.terminal_id, "echo STILL-$((1+1))").await;
    assert!(out.contains("STILL-2"), "{out:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn closing_a_terminal_kills_its_shell_removes_the_leaf_and_reports_user_closed() {
    let d = Daemon::start(&[Peer::App, Peer::Script]).await;
    let mut app = d.app(vec![]).await;
    let mut watcher = d.script(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let from = app.mark();
    let watcher_from = watcher.mark();
    app.send(&ClientMsg::TerminalClose {
        terminal_id: info.terminal_id.clone(),
    })
    .await;
    for (name, who, start) in [
        ("the app", &mut app, from),
        ("a local watcher", &mut watcher, watcher_from),
    ] {
        let (_, closed) = who
            .wait_since(
                start,
                &format!("terminal_closed for {name}"),
                |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == info.terminal_id),
            )
            .await;
        let ServerMsg::TerminalClosed(closed) = closed else {
            unreachable!()
        };
        assert_eq!(closed.reason, "user_closed", "{name}");
        assert_eq!(closed.pane_id, info.pane_id, "{name}");
        who.wait_since(
            start,
            &format!("a layout without the leaf for {name}"),
            |m| {
                matches!(m, ServerMsg::FocusLayout { tag, tree, .. }
                if tag == TAG && !tree.pane_ids().contains(&info.pane_id))
            },
        )
        .await;
    }
    eventually("the terminal to be forgotten", || d.list().is_empty()).await;
    assert!(d.registered_leaves(TAG).is_empty());
    assert_eq!(d.tree(TAG), Some(PaneTree::repl_leaf()));
    let line = d
        .wait_audit("closed(user_closed)", |l| {
            l["event"] == "closed" && l["terminal_id"] == info.terminal_id.as_str()
        })
        .await;
    assert_eq!(line["reason"], "user_closed");
}

// ── 3. several attachers, input exactly once ─────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn two_app_connections_attached_to_one_terminal_see_the_same_output_and_input_lands_once() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut a = d.app(vec![]).await;
    let mut b = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = a.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();

    // b learns of the terminal from the metadata broadcast, then attaches.
    b.wait_since(
        0,
        "terminal_state for the new terminal on b",
        |m| matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == tid),
    )
    .await;
    b.attach(&tid).await;

    // Raw, no echo: the only copy of a byte on the output is the one cat writes.
    a.type_line(&tid, "stty raw -echo; printf 'CAT-%s\\n' go; cat")
        .await;
    a.wait_view(&tid, "CAT-go\n").await;
    b.wait_view(&tid, "CAT-go\n").await;
    a.settle_ms(300).await;
    b.settle_ms(300).await;
    let (oa, ob) = (a.view(&tid).len(), b.view(&tid).len());

    a.input(&tid, b"QQ1").await;
    assert!(
        a.wait_view_from(&tid, oa, "QQ1", WAIT).await,
        "a sees its own input echoed"
    );
    assert!(
        b.wait_view_from(&tid, ob, "QQ1", WAIT).await,
        "b sees a's input echoed"
    );
    b.input(&tid, b"QQ2").await;
    assert!(
        a.wait_view_from(&tid, oa, "QQ2", WAIT).await,
        "a sees b's input echoed"
    );
    assert!(
        b.wait_view_from(&tid, ob, "QQ2", WAIT).await,
        "b sees its own input echoed"
    );
    a.settle_ms(400).await;
    b.settle_ms(400).await;

    assert_eq!(
        lossy(&a.view(&tid)[oa..]),
        "QQ1QQ2",
        "each send reaches the process exactly once, in order"
    );
    assert_eq!(
        a.view(&tid)[oa..],
        b.view(&tid)[ob..],
        "both attachers receive the same output"
    );

    // One attacher going away disturbs neither the terminal nor the other.
    drop(a);
    b.input(&tid, b"QQ3").await;
    assert!(b.wait_view_from(&tid, ob, "QQ3", WAIT).await);
    b.settle_ms(300).await;
    assert_eq!(count_sub(b.view(&tid), b"QQ3"), 1);
    assert_eq!(
        d.info(&tid).map(|t| t.status),
        Some(TerminalStatus::Running)
    );
}

// ── 4. structural refusal for anyone but the app ─────────────────────────────

/// The attacks a non-operator local peer can make on `terminal_id`, with the
/// refusal each must get: (op, frame, code, terminal_id the refusal names).
fn attacks(terminal_id: &str) -> Vec<(&'static str, ClientMsg, &'static str, Option<String>)> {
    let id = || Some(terminal_id.to_string());
    vec![
        (
            "input",
            ClientMsg::TerminalInput {
                terminal_id: terminal_id.into(),
                bytes: b64(b"echo FORBIDDEN-INPUT\r"),
                auto_reply: false,
            },
            "terminal_input_forbidden",
            id(),
        ),
        (
            "resize",
            ClientMsg::TerminalResize {
                terminal_id: terminal_id.into(),
                cols: 40,
                rows: 10,
            },
            "terminal_control_forbidden",
            id(),
        ),
        (
            "close",
            ClientMsg::TerminalClose {
                terminal_id: terminal_id.into(),
            },
            "terminal_close_forbidden",
            id(),
        ),
        (
            "restart",
            ClientMsg::TerminalRestart {
                terminal_id: terminal_id.into(),
            },
            "terminal_control_forbidden",
            id(),
        ),
        (
            "attach",
            ClientMsg::TerminalAttach {
                terminal_id: terminal_id.into(),
            },
            "terminal_read_forbidden",
            id(),
        ),
        (
            "open",
            open_msg(TAG, None, "forbidden-open"),
            "terminal_control_forbidden",
            None,
        ),
    ]
}

/// The app owns a running terminal; `intruder` (a local connection that is
/// not the operator app) attacks it. Nothing may change, nothing may leak to
/// the intruder, and every attempt is refused and audited with the intruder's
/// pid.
async fn assert_structurally_refused(d: &Daemon, mut app: Unix, mut intruder: Unix, peer_pid: i32) {
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    let size_before = (info.cols, info.rows);

    // Everything the app's open broadcast has reached the intruder by now.
    d.flush_broadcast_to(&mut intruder).await;
    let start = intruder.mark();
    for (op, frame, code, names_terminal) in attacks(&tid) {
        let from = intruder.mark();
        intruder.send(&frame).await;
        intruder.sync().await;
        let (_, refused) = intruder
            .wait_since(
                from,
                &format!("a terminal_refused for {op}"),
                |m| matches!(m, ServerMsg::TerminalRefused { op: o, .. } if o == op),
            )
            .await;
        let ServerMsg::TerminalRefused {
            terminal_id,
            code: got_code,
            ..
        } = refused
        else {
            unreachable!()
        };
        assert_eq!(got_code, code, "refusal code for {op}");
        assert_eq!(
            terminal_id, names_terminal,
            "terminal named by the {op} refusal"
        );
    }

    // Output keeps flowing to the app while the intruder watches.
    let out = app.run(&tid, "printf 'TICK-%s\\n' 1").await;
    assert!(out.contains("TICK-1"));
    intruder.settle_ms(400).await;

    let seen = &intruder.log[start..];
    let refused_count = seen
        .iter()
        .filter(|m| matches!(m, ServerMsg::TerminalRefused { .. }))
        .count();
    assert_eq!(
        refused_count,
        6,
        "one refusal per attempt: [{}]",
        intruder.summary()
    );
    assert!(
        !seen.iter().any(is_terminal_bytes_frame),
        "no terminal bytes may reach a non-operator: [{}]",
        intruder.summary()
    );
    assert!(
        !seen.iter().any(|m| matches!(
            m,
            ServerMsg::TerminalState { .. }
                | ServerMsg::TerminalClosed(_)
                | ServerMsg::TerminalList { .. }
        )),
        "nothing about the terminal changed, so nothing is announced: [{}]",
        intruder.summary()
    );
    assert!(
        !seen
            .iter()
            .any(|m| matches!(m, ServerMsg::FocusLayout { .. })),
        "the pane tree did not change: [{}]",
        intruder.summary()
    );

    // The terminal is exactly as it was.
    let after = d.info(&tid).expect("the terminal still exists");
    assert_eq!(after.status, TerminalStatus::Running);
    assert_eq!(after.terminal_id, tid);
    assert_eq!(
        (after.cols, after.rows),
        size_before,
        "the size is unchanged"
    );
    assert_eq!(d.list().len(), 1, "the refused open created nothing");
    assert!(
        find_sub(app.view(&tid), b"FORBIDDEN-INPUT").is_none(),
        "the intruder's keystrokes must never reach the shell"
    );

    // Every refusal is in the audit trail with the channel, op, code and peer.
    for (op, _, code, names_terminal) in attacks(&tid) {
        let line = d
            .wait_audit(&format!("refused {op}"), |l| {
                l["event"] == "refused" && l["channel"] == "ipc" && l["op"] == op
            })
            .await;
        assert_eq!(line["code"], code, "audited code for {op}");
        assert_eq!(line["peer_pid"], peer_pid, "audited peer pid for {op}");
        if let Some(id) = names_terminal {
            assert_eq!(
                line["terminal_id"],
                id.as_str(),
                "audited terminal for {op}"
            );
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_ordinary_local_process_cannot_touch_a_terminal_and_is_audited() {
    let d = Daemon::start(&[Peer::App, Peer::Script]).await;
    let app = d.app(vec![]).await;
    let script = d.script(vec![]).await;
    assert_structurally_refused(&d, app, script, script_info().pid).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_process_claiming_to_be_the_app_but_failing_verification_is_refused_the_same_way() {
    let d = Daemon::start(&[Peer::App, Peer::Script]).await;
    let app = d.app(vec![]).await;
    let forged = d.claiming_app(vec![]).await;
    assert_structurally_refused(&d, app, forged, script_info().pid).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_verified_app_bundle_that_does_not_claim_to_be_the_app_is_not_the_operator() {
    // Both halves are required: the verifier says "app" for the second
    // connection too, but its Hello does not claim `mac_app`.
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let app = d.app(vec![]).await;
    let unclaimed = d.script(vec![]).await;
    assert_structurally_refused(&d, app, unclaimed, app_info().pid).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn only_the_operator_apps_refusal_report_is_audited() {
    let d = Daemon::start(&[Peer::App, Peer::Script]).await;
    let mut app = d.app(vec![]).await;
    let mut script = d.script(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let report = ClientMsg::TerminalRefusalReport {
        terminal_id: Some(info.terminal_id.clone()),
        op: "input".into(),
        channel: "app_control".into(),
    };

    // A non-operator's report is ignored: no reply, no audit line.
    let from = script.mark();
    script.send(&report).await;
    script.sync().await;
    script.settle_ms(300).await;
    assert!(
        !script.log[from..].iter().any(|m| matches!(
            m,
            ServerMsg::TerminalRefused { .. } | ServerMsg::Error { .. }
        )),
        "an ignored report gets no reply: [{}]",
        script.summary()
    );
    assert!(
        !d.audit().iter().any(|l| l["channel"] == "app_control"),
        "a non-operator must not be able to write app_control lines: {:#?}",
        d.audit()
    );

    // The operator app's report is audited as refused, with its channel.
    app.send(&report).await;
    let line = d
        .wait_audit("the app's refusal report", |l| {
            l["event"] == "refused" && l["channel"] == "app_control" && l["op"] == "input"
        })
        .await;
    assert_eq!(line["terminal_id"], info.terminal_id.as_str());
}

#[tokio::test(flavor = "multi_thread")]
async fn requests_naming_an_unknown_terminal_are_refused_and_change_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let ghost = "00000000-0000-4000-8000-000000000000";

    for (op, frame) in [
        (
            "input",
            ClientMsg::TerminalInput {
                terminal_id: ghost.into(),
                bytes: b64(b"x"),
                auto_reply: false,
            },
        ),
        (
            "attach",
            ClientMsg::TerminalAttach {
                terminal_id: ghost.into(),
            },
        ),
        (
            "resize",
            ClientMsg::TerminalResize {
                terminal_id: ghost.into(),
                cols: 90,
                rows: 30,
            },
        ),
        (
            "close",
            ClientMsg::TerminalClose {
                terminal_id: ghost.into(),
            },
        ),
        (
            "restart",
            ClientMsg::TerminalRestart {
                terminal_id: ghost.into(),
            },
        ),
    ] {
        let from = app.mark();
        app.send(&frame).await;
        let (_, refused) = app
            .wait_since(
                from,
                &format!("a terminal_refused for {op} on an unknown id"),
                |m| matches!(m, ServerMsg::TerminalRefused { op: o, .. } if o == op),
            )
            .await;
        let ServerMsg::TerminalRefused { terminal_id, .. } = refused else {
            unreachable!()
        };
        assert_eq!(terminal_id.as_deref(), Some(ghost));
    }
    assert_eq!(d.list().len(), 1);
    assert_eq!(
        d.info(&info.terminal_id).map(|t| t.status),
        Some(TerminalStatus::Running)
    );
}

// ── 5. FND-1: TCP and topics ─────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn every_terminal_frame_over_tcp_is_refused_with_no_effect_and_audited() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    let mut tcp = d.tcp(vec![]).await;

    let frames: Vec<(&str, ClientMsg)> = vec![
        ("open", open_msg(TAG, None, "tcp-open")),
        (
            "attach",
            ClientMsg::TerminalAttach {
                terminal_id: tid.clone(),
            },
        ),
        (
            "detach",
            ClientMsg::TerminalDetach {
                terminal_id: tid.clone(),
            },
        ),
        (
            "input",
            ClientMsg::TerminalInput {
                terminal_id: tid.clone(),
                bytes: b64(b"echo TCP-FORBIDDEN\r"),
                auto_reply: false,
            },
        ),
        (
            "resize",
            ClientMsg::TerminalResize {
                terminal_id: tid.clone(),
                cols: 33,
                rows: 9,
            },
        ),
        (
            "close",
            ClientMsg::TerminalClose {
                terminal_id: tid.clone(),
            },
        ),
        (
            "restart",
            ClientMsg::TerminalRestart {
                terminal_id: tid.clone(),
            },
        ),
        (
            "refusal_report",
            ClientMsg::TerminalRefusalReport {
                terminal_id: Some(tid.clone()),
                op: "input".into(),
                channel: "app_control".into(),
            },
        ),
    ];
    let start = tcp.mark();
    for (name, frame) in &frames {
        let from = tcp.mark();
        tcp.send(frame).await;
        tcp.sync().await;
        let refused = tcp.log[from..].iter().any(|m| {
            matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
        });
        assert!(
            refused,
            "{name}: expected an error starting with `requires_secure_connection`, got [{}]",
            tcp.summary()
        );
    }

    // No side effect.
    let out = app.run(&tid, "printf 'AFTER-TCP-%s\\n' 1").await;
    assert!(out.contains("AFTER-TCP-1"));
    assert!(
        find_sub(app.view(&tid), b"TCP-FORBIDDEN").is_none(),
        "tcp input must not reach the shell"
    );
    let live = d.list();
    assert_eq!(live.len(), 1, "a tcp open must not create a terminal");
    assert_eq!(live[0].terminal_id, tid);
    assert_eq!(live[0].status, TerminalStatus::Running);
    assert_eq!(
        (live[0].cols, live[0].rows),
        (info.cols, info.rows),
        "a tcp resize changes nothing"
    );
    assert!(
        !tcp.log[start..].iter().any(is_terminal_server_frame),
        "a tcp peer receives no terminal frame, not even a refusal: [{}]",
        tcp.summary()
    );

    // Every one is audited as refused over tcp, naming its op.
    let want: BTreeSet<String> = frames.iter().map(|(n, _)| n.to_string()).collect();
    let deadline = Instant::now() + WAIT;
    loop {
        let got: BTreeSet<String> = d
            .audit()
            .iter()
            .filter(|l| l["event"] == "refused" && l["channel"] == "tcp")
            .filter_map(|l| l["op"].as_str().map(normalize_op))
            .collect();
        if want.is_subset(&got) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "audit must hold a refused/tcp line for each of {want:?}; got ops {got:?}"
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_tcp_client_subscribed_to_everything_never_receives_a_terminal_frame() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut tcp_all = d.tcp(vec![]).await;
    let mut tcp_terminal = d.tcp(vec![Topic::Terminal]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();

    // Every kind of terminal event happens while the tcp clients are subscribed:
    // an open, output, an ended shell, a restart, a close.
    let t1 = app.open_ready(&cwd).await;
    let t2 = app.open(TAG, Some(&cwd), "stays-open").await;
    app.run(&t1.terminal_id, "printf 'FLOW-%s\\n' 1").await;
    app.type_line(&t1.terminal_id, "exit 3").await;
    app.wait_since(0, "t1 ended", |m| {
        matches!(m, ServerMsg::TerminalState { terminal }
            if terminal.terminal_id == t1.terminal_id && terminal.status == TerminalStatus::Ended)
    })
    .await;
    let from = app.mark();
    app.send(&ClientMsg::TerminalRestart {
        terminal_id: t1.terminal_id.clone(),
    })
    .await;
    let (_, restarted) = app
        .wait_since(from, "t1 restarted", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.pane_id == t1.pane_id && terminal.status == TerminalStatus::Running
                    && terminal.terminal_id != t1.terminal_id)
        })
        .await;
    let ServerMsg::TerminalState {
        terminal: restarted,
    } = restarted
    else {
        unreachable!()
    };
    app.send(&ClientMsg::TerminalClose {
        terminal_id: restarted.terminal_id.clone(),
    })
    .await;
    app.wait_since(
        from,
        "the restarted terminal closed",
        |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == restarted.terminal_id),
    )
    .await;

    // A client that connects now, while t2 exists, gets no terminal_list either.
    let mut tcp_late = d.tcp(vec![]).await;
    // Positive control: a local app connecting now does get one, naming t2.
    let app_late = d.app(vec![]).await;
    let late_list = app_late.log.iter().find_map(|m| match m {
        ServerMsg::TerminalList { terminals, .. } => Some(terminals.clone()),
        _ => None,
    });
    assert!(
        late_list.is_some_and(|l| l.iter().any(|t| t.terminal_id == t2.terminal_id)),
        "control: a local connection is sent the terminal list"
    );

    for c in [&mut tcp_all, &mut tcp_terminal, &mut tcp_late] {
        d.flush_broadcast_to(c).await;
        assert!(
            !c.log.iter().any(is_terminal_server_frame),
            "a tcp peer must never receive a terminal frame: [{}]",
            c.summary()
        );
    }

    // Controls: the app saw every kind of frame the tcp clients must not.
    for (what, seen) in [
        (
            "terminal_output",
            app.log
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalOutput { .. })),
        ),
        (
            "terminal_replay",
            app.log
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalReplay { .. })),
        ),
        (
            "terminal_state",
            app.log
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalState { .. })),
        ),
        (
            "terminal_closed",
            app.log
                .iter()
                .any(|m| matches!(m, ServerMsg::TerminalClosed(_))),
        ),
    ] {
        assert!(seen, "control: the app should have received {what}");
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_local_non_operator_sees_terminal_metadata_by_topic_but_never_terminal_bytes() {
    let d = Daemon::start(&[Peer::Script, Peer::Script, Peer::Script, Peer::App]).await;
    let mut everything = d.script(vec![]).await;
    let mut terminal_topic = d.script(vec![Topic::Terminal]).await;
    let mut other_topic = d.script(vec![Topic::Activity]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();

    let info = app.open_ready(&cwd).await;
    app.run(&info.terminal_id, "printf 'SECRET-%s\\n' 1").await;
    app.type_line(&info.terminal_id, "exit").await;
    app.wait_since(
        0,
        "the terminal to close",
        |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == info.terminal_id),
    )
    .await;

    for c in [&mut everything, &mut terminal_topic, &mut other_topic] {
        d.flush_broadcast_to(c).await;
        assert!(
            !c.log.iter().any(is_terminal_bytes_frame),
            "terminal bytes must never reach a non-operator: [{}]",
            c.summary()
        );
    }
    for (who, c) in [
        ("topics: []", &everything),
        ("topics: [terminal]", &terminal_topic),
    ] {
        assert!(
            c.log.iter().any(|m| matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == info.terminal_id && terminal.status == TerminalStatus::Running)),
            "{who} must receive terminal_state"
        );
        assert!(
            c.log.iter().any(|m| matches!(m, ServerMsg::TerminalClosed(closed) if closed.terminal_id == info.terminal_id)),
            "{who} must receive terminal_closed"
        );
    }
    assert!(
        !other_topic.log.iter().any(|m| matches!(
            m,
            ServerMsg::TerminalState { .. } | ServerMsg::TerminalClosed(_)
        )),
        "terminal metadata is delivered under Topic::Terminal only: [{}]",
        other_topic.summary()
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn every_local_connection_is_sent_the_terminal_list_after_the_layout_replay() {
    let d = Daemon::start(&[Peer::App, Peer::App, Peer::Script, Peer::Script]).await;
    let mut first = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let running = first.open_ready(&cwd).await;
    let failed = first.open_ready(&cwd).await;
    first.type_line(&failed.terminal_id, "exit 3").await;
    first
        .wait_since(0, "the second terminal to end", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.terminal_id == failed.terminal_id && terminal.status == TerminalStatus::Ended)
        })
        .await;

    let relaunched = d.app(vec![]).await;
    let script_all = d.script(vec![]).await;
    let script_narrow = d.script(vec![Topic::Activity]).await;
    for (who, c) in [
        ("a relaunched app", &relaunched),
        ("a local script (topics: [])", &script_all),
        ("a local script (topics: [activity])", &script_narrow),
    ] {
        let (list_at, list) = c
            .log
            .iter()
            .enumerate()
            .find_map(|(i, m)| match m {
                ServerMsg::TerminalList { terminals, closed } => {
                    Some((i, (terminals.clone(), closed.clone())))
                }
                _ => None,
            })
            .unwrap_or_else(|| panic!("{who} was sent no terminal_list: [{}]", c.summary()));
        let (terminals, closed) = list;
        assert!(
            closed.is_empty(),
            "{who}: nothing closed while the daemon ran"
        );
        let by_id: HashMap<_, _> = terminals
            .iter()
            .map(|t| (t.terminal_id.clone(), t))
            .collect();
        assert_eq!(by_id.len(), 2, "{who}: {terminals:?}");
        assert_eq!(
            by_id[&running.terminal_id].status,
            TerminalStatus::Running,
            "{who}"
        );
        assert_eq!(
            by_id[&failed.terminal_id].status,
            TerminalStatus::Ended,
            "{who}"
        );
        assert_eq!(by_id[&failed.terminal_id].exit_code, Some(3), "{who}");
        // After any layout replay.
        if let Some(layout_at) = c
            .log
            .iter()
            .rposition(|m| matches!(m, ServerMsg::FocusLayout { .. }))
        {
            assert!(
                layout_at < list_at,
                "{who}: the terminal_list follows the layout replay"
            );
        }
    }
}

// ── 6. re-attach, relaunch, replay depth ─────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn a_detached_connection_gets_no_output_and_a_re_attach_replays_what_it_missed() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut a = d.app(vec![]).await;
    let mut b = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = a.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    a.run(&tid, "printf 'EARLIER-%s\\n' 77").await;

    a.send(&ClientMsg::TerminalDetach {
        terminal_id: tid.clone(),
    })
    .await;
    a.sync().await;

    b.wait_since(
        0,
        "the terminal on b",
        |m| matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == tid),
    )
    .await;
    b.attach(&tid).await;
    let quiet_from = a.mark();
    let out = b.run(&tid, "printf 'AFTER-%s\\n' 88").await;
    assert!(out.contains("AFTER-88"));
    a.settle_ms(400).await;
    assert!(
        !a.log[quiet_from..].iter().any(is_terminal_bytes_frame),
        "a detached connection must receive no output: [{}]",
        a.summary()
    );

    let (cols, rows) = a.attach(&tid).await;
    assert_eq!(
        (cols, rows),
        (info.cols, info.rows),
        "the replay carries the terminal's size"
    );
    let replay = lossy(a.view(&tid));
    assert!(
        replay.contains("EARLIER-77"),
        "the replay holds earlier output: {replay:?}"
    );
    assert!(
        replay.contains("AFTER-88"),
        "and what happened while detached: {replay:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_terminal_survives_the_app_disconnecting_and_a_new_connection_replays_it() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut first = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = first.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    first.run(&tid, "printf 'BEFORE-QUIT-%s\\n' 5").await;

    drop(first); // the app quits
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(
        d.info(&tid).map(|t| t.status),
        Some(TerminalStatus::Running)
    );

    let mut relaunched = d.app(vec![]).await;
    let listed = relaunched.log.iter().any(|m| {
        matches!(m, ServerMsg::TerminalList { terminals, .. }
        if terminals.iter().any(|t| t.terminal_id == tid && t.status == TerminalStatus::Running))
    });
    assert!(
        listed,
        "the relaunched app is told the terminal is still running"
    );
    relaunched.attach(&tid).await;
    let replay = lossy(relaunched.view(&tid));
    assert!(replay.contains("BEFORE-QUIT-5"), "{replay:?}");
    let out = relaunched.run(&tid, "echo AGAIN-$((20+1))").await;
    assert!(
        out.contains("AGAIN-21"),
        "the same shell is still there: {out:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_replay_retains_at_least_ten_thousand_lines() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut a = d.app(vec![]).await;
    let mut b = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = a.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();

    let n = next_marker();
    a.type_line(&tid, &format!("seq 1 10500; printf 'LASTLINE-%s\\n' {n}"))
        .await;
    assert!(
        a.wait_view_from(&tid, 0, &format!("LASTLINE-{n}"), Duration::from_secs(30))
            .await,
        "the output never finished"
    );

    // A fresh attach: the replay (which may continue in output frames).
    b.wait_since(
        0,
        "the terminal on b",
        |m| matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == tid),
    )
    .await;
    b.attach(&tid).await;
    assert!(
        b.wait_view_from(&tid, 0, &format!("LASTLINE-{n}"), Duration::from_secs(30))
            .await,
        "the replay must reach the end of the output"
    );
    let numbers: BTreeSet<u32> = lossy(b.view(&tid))
        .split('\n')
        .filter_map(|l| l.trim_end_matches('\r').trim().parse::<u32>().ok())
        .collect();
    let missing: Vec<u32> = (501..=10_500)
        .filter(|i| !numbers.contains(i))
        .take(5)
        .collect();
    assert!(
        missing.is_empty(),
        "the replay must hold the last 10,000 lines (501..=10500); first missing: {missing:?}"
    );
}

// ── resize ───────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn an_operator_resize_reaches_the_shell_is_announced_and_shows_in_later_replays() {
    let d = Daemon::start(&[Peer::App, Peer::App]).await;
    let mut a = d.app(vec![]).await;
    let mut b = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = a.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    assert_ne!((info.cols, info.rows), (100, 30));

    let from = a.mark();
    a.send(&ClientMsg::TerminalResize {
        terminal_id: tid.clone(),
        cols: 100,
        rows: 30,
    })
    .await;
    a.wait_since(from, "terminal_state with the new size", |m| {
        matches!(m, ServerMsg::TerminalState { terminal }
            if terminal.terminal_id == tid && (terminal.cols, terminal.rows) == (100, 30))
    })
    .await;
    eventually("the manager to report the new size", || {
        d.info(&tid).map(|t| (t.cols, t.rows)) == Some((100, 30))
    })
    .await;

    let out = a.run(&tid, "stty size").await;
    assert!(
        out.contains("30 100"),
        "the shell must see 30 rows x 100 cols: {out:?}"
    );

    b.wait_since(
        0,
        "the terminal on b",
        |m| matches!(m, ServerMsg::TerminalState { terminal } if terminal.terminal_id == tid),
    )
    .await;
    assert_eq!(
        b.attach(&tid).await,
        (100, 30),
        "a later replay carries the new size"
    );
}

// ── environment ──────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn the_shell_gets_the_terminal_environment_and_none_of_the_agent_identity() {
    isolate_process_env();
    // Guard against a vacuous pass: the daemon's own environment really has them.
    for var in LEAKY_VARS {
        assert!(
            std::env::var(var).is_ok(),
            "{var} must be set in the daemon's environment"
        );
    }
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;

    let env = app.run(&info.terminal_id, "env").await;
    let has = |name: &str, value: &str| {
        env.lines().any(|line| {
            let line = line.trim_end_matches('\r');
            let key = format!("{name}=");
            line.rfind(&key).is_some_and(|at| {
                let before_ok = line[..at]
                    .chars()
                    .last()
                    .is_none_or(|c| !(c.is_ascii_alphanumeric() || c == '_'));
                before_ok && &line[at + key.len()..] == value
            })
        })
    };
    assert!(has("TERM", "xterm-256color"), "TERM; env was:\n{env}");
    assert!(has("COLORTERM", "truecolor"), "COLORTERM; env was:\n{env}");
    assert!(
        has("TERM_PROGRAM", "Nostromo"),
        "TERM_PROGRAM; env was:\n{env}"
    );
    assert!(
        has("NOSTROMO_TERMINAL_IT_PASSTHROUGH", "ok42"),
        "the daemon's ordinary environment passes through; env was:\n{env}"
    );
    for var in LEAKY_VARS {
        assert!(
            !env.contains(&format!("{var}=")),
            "{var} must not reach the shell; env was:\n{env}"
        );
    }
}

// ── audit ────────────────────────────────────────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn the_audit_trail_records_open_and_close_but_never_keystrokes_or_output() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();

    // Input CANARY-IN-7f3a (typed, echoed); output CANARY-OUT-7f3a (printed).
    app.type_line(&tid, "echo CANARY-IN-7f3a; printf 'CANARY-OUT-%s\\n' 7f3a")
        .await;
    app.wait_view(&tid, "CANARY-OUT-7f3a").await;
    assert!(
        find_sub(app.view(&tid), b"CANARY-IN-7f3a").is_some(),
        "control: the canary input reached the shell"
    );

    let from = app.mark();
    app.send(&ClientMsg::TerminalClose {
        terminal_id: tid.clone(),
    })
    .await;
    app.wait_since(
        from,
        "terminal_closed",
        |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == tid),
    )
    .await;

    let opened = d
        .wait_audit("opened", |l| {
            l["event"] == "opened" && l["terminal_id"] == tid.as_str()
        })
        .await;
    assert_eq!(requester_kind(&opened).as_deref(), Some("user"));
    let closed = d
        .wait_audit("closed", |l| {
            l["event"] == "closed" && l["terminal_id"] == tid.as_str()
        })
        .await;
    assert_eq!(closed["reason"], "user_closed");
    for line in [&opened, &closed] {
        let ts = line["ts"].as_str().expect("every line has a ts");
        assert!(
            chrono::DateTime::parse_from_rfc3339(ts).is_ok(),
            "ts is RFC 3339: {ts}"
        );
        assert!(
            ts.ends_with('Z') || ts.ends_with("+00:00"),
            "ts is UTC: {ts}"
        );
    }

    let audit_text = d.all_audit_text();
    for canary in ["CANARY-IN", "CANARY-OUT", "7f3a"] {
        assert!(
            !audit_text.contains(canary),
            "the audit trail must never hold terminal input or output ({canary}):\n{audit_text}"
        );
    }
    let store_text = std::fs::read_to_string(&d.store_path).unwrap_or_default();
    for canary in ["CANARY-IN", "CANARY-OUT", "7f3a"] {
        assert!(
            !store_text.contains(canary),
            "nor may the terminal store ({canary})"
        );
    }
}

// ── persistence and restart reconciliation ───────────────────────────────────

#[tokio::test(flavor = "multi_thread")]
async fn the_store_holds_a_record_for_each_live_terminal_until_it_closes() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let store = TerminalStore::at(&d.store_path);

    eventually("the store to hold the new terminal", || {
        store
            .load()
            .iter()
            .any(|r| r.terminal_id == info.terminal_id)
    })
    .await;
    let rec = store
        .load()
        .into_iter()
        .find(|r| r.terminal_id == info.terminal_id)
        .unwrap();
    assert_eq!(rec.tag, TAG);
    assert_eq!(rec.pane_id, info.pane_id);
    assert_eq!(rec.kind, TerminalKind::Local);
    assert_eq!(rec.requested_by.kind, "user");

    app.send(&ClientMsg::TerminalClose {
        terminal_id: info.terminal_id.clone(),
    })
    .await;
    eventually("the closed terminal to leave the store", || {
        !store
            .load()
            .iter()
            .any(|r| r.terminal_id == info.terminal_id)
    })
    .await;
}

fn ecs_record(terminal_id: &str, pane_id: &str) -> TerminalRecord {
    TerminalRecord {
        terminal_id: terminal_id.into(),
        tag: TAG.into(),
        pane_id: pane_id.into(),
        kind: TerminalKind::Ecs,
        cwd: None,
        label: "admin-portal scheduler".into(),
        target: Some(TerminalTarget {
            project: "admin-portal".into(),
            environment: "production".into(),
            service: "scheduler".into(),
            shell_type: "shell".into(),
        }),
        requested_by: TerminalRequester {
            kind: "user".into(),
            tag: None,
        },
    }
}

/// A daemon that ran a local terminal (and, in its store, a remote one), was
/// stopped, and was started again on the same store. Returns the new daemon
/// and what the first one had.
struct Restarted {
    daemon: Daemon,
    local: TerminalInfo,
    ecs_pane_id: String,
    /// The local terminal's working directory, kept for a restart.
    _cwd_guard: TempDir,
}

async fn restarted_daemon(peers: &[Peer]) -> Restarted {
    // First life: the app opens a local terminal; the daemon stops.
    let first = Daemon::start(&[Peer::App]).await;
    let mut app = first.app(vec![]).await;
    let (cwd_guard, cwd) = canonical_tmp();
    let local = app.open_ready(&cwd).await;
    first.terminals.lock().unwrap().shutdown();
    let store = TerminalStore::at(&first.store_path);
    assert!(
        store
            .load()
            .iter()
            .any(|r| r.terminal_id == local.terminal_id),
        "a daemon stop keeps the local terminal's record so the next start can report it"
    );

    // A remote terminal the first daemon also had (nothing creates one yet).
    let ecs_pane_id = "terminal-0ec50001".to_string();
    let mut records = store.load();
    records.push(ecs_record("ecs-terminal-1", &ecs_pane_id));
    store.save(&records);

    // Second life: the pane registry came back from its own persistence (the
    // leaves are in the trees); the terminal manager reconciles from the store.
    let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    {
        let mut p = panes.lock().unwrap();
        p.get_or_init(TAG);
        p.insert_terminal_leaf(TAG, "repl", SplitPosition::Below, &local.pane_id)
            .expect("restore the local leaf");
        p.insert_terminal_leaf(TAG, "repl", SplitPosition::Right, &ecs_pane_id)
            .expect("restore the remote leaf");
    }
    let tmp = TempDir::new().expect("tempdir");
    let terminals = TerminalManager::new(TerminalConfig {
        audit: AuditLog::open(&tmp.path().join("audit").join("terminal.jsonl")).expect("audit"),
        store: TerminalStore::at(&first.store_path),
        pane_registry: Some(Arc::clone(&panes)),
    });
    terminals.lock().unwrap().reconcile();
    let audit_path = tmp.path().join("audit").join("terminal.jsonl");
    let store_path = first.store_path.clone();
    let daemon = Daemon::serve(peers, tmp, terminals, panes, audit_path, store_path).await;
    Restarted {
        daemon,
        local,
        ecs_pane_id,
        _cwd_guard: cwd_guard,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn after_a_daemon_restart_a_local_terminal_is_ended_and_a_remote_one_is_reported_closed() {
    let r = restarted_daemon(&[Peer::App]).await;
    let d = &r.daemon;

    // The manager's view: the local terminal is ended by the stop, in place.
    let listed = d.list();
    assert_eq!(
        listed.len(),
        1,
        "only the local terminal is left: {listed:?}"
    );
    let ended = &listed[0];
    assert_eq!(ended.terminal_id, r.local.terminal_id);
    assert_eq!(ended.status, TerminalStatus::Ended);
    assert_eq!(ended.ended_reason.as_deref(), Some("daemon_stopped"));
    assert_eq!(ended.pane_id, r.local.pane_id);
    assert_eq!(d.registered_leaves(TAG), vec![r.local.pane_id.clone()]);
    let ids = d.tree(TAG).unwrap().pane_ids();
    assert!(
        ids.contains(&r.local.pane_id),
        "the local leaf stays: {ids:?}"
    );
    assert!(
        !ids.contains(&r.ecs_pane_id),
        "the remote leaf is gone: {ids:?}"
    );

    // What a connecting client is told.
    let app = d.app(vec![]).await;
    let (terminals, closed): (Vec<TerminalInfo>, Vec<TerminalClosedInfo>) = app
        .log
        .iter()
        .find_map(|m| match m {
            ServerMsg::TerminalList { terminals, closed } => {
                Some((terminals.clone(), closed.clone()))
            }
            _ => None,
        })
        .expect("a terminal_list on connect");
    assert_eq!(terminals.len(), 1);
    assert_eq!(terminals[0].terminal_id, r.local.terminal_id);
    assert_eq!(terminals[0].status, TerminalStatus::Ended);
    assert_eq!(terminals[0].ended_reason.as_deref(), Some("daemon_stopped"));
    assert_eq!(
        closed.len(),
        1,
        "the remote terminal is reported closed: {closed:?}"
    );
    assert_eq!(closed[0].terminal_id, "ecs-terminal-1");
    assert_eq!(closed[0].reason, "daemon_stopped");
    assert_eq!(closed[0].kind, TerminalKind::Ecs);
    assert_eq!(closed[0].pane_id, r.ecs_pane_id);
    assert_eq!(
        closed[0].target.as_ref().map(|t| t.environment.as_str()),
        Some("production")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_terminal_ended_by_a_daemon_stop_can_be_restarted_in_its_pane() {
    let r = restarted_daemon(&[Peer::App]).await;
    let mut app = r.daemon.app(vec![]).await;

    let from = app.mark();
    app.send(&ClientMsg::TerminalRestart {
        terminal_id: r.local.terminal_id.clone(),
    })
    .await;
    let (_, state) = app
        .wait_since(from, "the restarted terminal running", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.pane_id == r.local.pane_id && terminal.status == TerminalStatus::Running)
        })
        .await;
    let ServerMsg::TerminalState { terminal } = state else {
        unreachable!()
    };
    assert_ne!(terminal.terminal_id, r.local.terminal_id);
    app.attach(&terminal.terminal_id).await;
    app.shell_ready(&terminal.terminal_id).await;
    let out = app
        .run(&terminal.terminal_id, "echo REVIVED-$((40+2))")
        .await;
    assert!(out.contains("REVIVED-42"), "{out:?}");
}

// ── latency (run explicitly) ─────────────────────────────────────────────────

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[idx]
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "latency: run explicitly; numbers go in the PR body"]
async fn typing_a_byte_comes_back_as_output_in_under_five_milliseconds_at_p95() {
    let d = Daemon::start(&[Peer::App]).await;
    let mut app = d.app(vec![]).await;
    let (_g, cwd) = canonical_tmp();
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();

    let samples = Arc::new(Mutex::new(Vec::<Duration>::new()));
    {
        let sink = Arc::clone(&samples);
        d.terminals
            .lock()
            .unwrap()
            .set_latency_probe(Some(Arc::new(move |took| sink.lock().unwrap().push(took))));
    }

    app.type_line(&tid, "stty raw -echo; printf 'RAW-%s\\n' go; cat")
        .await;
    app.wait_view(&tid, "RAW-go\n").await;
    app.settle_ms(300).await;

    let mut round_trips = Vec::new();
    for i in 0..500u32 {
        let byte = b'a' + (i % 26) as u8;
        let before = app.view(&tid).len();
        let sent = Instant::now();
        app.input(&tid, &[byte]).await;
        loop {
            if app.view(&tid).len() > before {
                break;
            }
            assert!(
                app.pump(Duration::from_secs(5)).await,
                "round trip {i} never came back"
            );
        }
        round_trips.push(sent.elapsed());
        assert_eq!(
            app.view(&tid)[before],
            byte,
            "round trip {i} echoed the wrong byte"
        );
        // Let the coalescer go quiet so every sample is a leading-edge flush.
        tokio::time::sleep(Duration::from_millis(12)).await;
    }
    d.terminals.lock().unwrap().set_latency_probe(None);

    let mut probe = samples.lock().unwrap().clone();
    probe.sort();
    round_trips.sort();
    assert!(
        probe.len() >= 400,
        "the probe saw only {} of 500 inputs",
        probe.len()
    );
    let (p50, p95, max) = (
        percentile(&probe, 0.50),
        percentile(&probe, 0.95),
        *probe.last().unwrap(),
    );
    eprintln!(
        "terminal latency, input received -> output enqueued (n={}): p50={p50:?} p95={p95:?} max={max:?}",
        probe.len()
    );
    eprintln!(
        "terminal latency, client round trip over the unix socket (n={}): p50={:?} p95={:?} max={:?}",
        round_trips.len(),
        percentile(&round_trips, 0.50),
        percentile(&round_trips, 0.95),
        round_trips.last().unwrap()
    );
    assert!(
        p95 < Duration::from_millis(5),
        "p95 {p95:?} must be under 5ms"
    );
}

// ── review hardening (Cody): the nonce gate, a stuck shell, absurd sizes ─────

/// A process can write `Hello` + `Subscribe` + terminal verbs and then `exec`
/// the genuine app, so the verification at `Hello` passes for bytes the app
/// never wrote. Those bytes cannot hold the Welcome's nonce: until a
/// `Subscribe` echoes it, the verified app's terminal verbs are refused.
#[tokio::test(flavor = "multi_thread")]
async fn frames_written_before_the_nonce_was_seen_are_refused_until_a_subscribe_echoes_it() {
    let d = Daemon::start(&[Peer::App]).await;
    let (_dir, cwd) = canonical_tmp();
    let stream = UnixStream::connect(&d.socket_path)
        .await
        .expect("unix connect");
    let mut c: Unix = Client::new(stream);
    // All buffered before the Welcome is read: no nonce anywhere.
    c.send(&ClientMsg::Hello {
        client_id: "pre-exec".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: Some("mac_app".into()),
    })
    .await;
    c.send(&ClientMsg::Subscribe {
        topics: vec![],
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec!["terminal_ui".into()],
        operator_nonce: None,
    })
    .await;
    c.send(&open_msg(TAG, Some(&cwd), "buffered")).await;
    let (_, refused) = c
        .wait_since(0, "the refusal of the buffered open", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    match refused {
        ServerMsg::TerminalRefused { op, code, .. } => {
            assert_eq!(normalize_op(&op), "open");
            assert_eq!(code, "terminal_control_forbidden");
        }
        _ => unreachable!(),
    }
    assert!(d.list().is_empty(), "the buffered open must start nothing");

    let nonce = c
        .log
        .iter()
        .find_map(|m| match m {
            ServerMsg::Welcome { operator_nonce, .. } => operator_nonce.clone(),
            _ => None,
        })
        .expect("the verified app's Welcome carries a nonce");

    // A wrong nonce does not enable anything either.
    let resubscribe = |nonce: Option<String>| ClientMsg::Subscribe {
        topics: vec![],
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec!["terminal_ui".into()],
        operator_nonce: nonce,
    };
    c.send(&resubscribe(Some("0".repeat(64)))).await;
    let from = c.mark();
    c.send(&open_msg(TAG, Some(&cwd), "wrong-nonce")).await;
    c.wait_since(from, "the refusal after a wrong nonce", |m| {
        matches!(m, ServerMsg::TerminalRefused { .. })
    })
    .await;
    assert!(d.list().is_empty());

    // The app's own Subscribe, echoing the nonce, enables the verbs.
    c.send(&resubscribe(Some(nonce))).await;
    let info = c.open(TAG, Some(&cwd), "after-nonce").await;
    assert_eq!(info.status, TerminalStatus::Running);
    assert_eq!(d.list().len(), 1);
}

/// A shell that is not reading its input (here: `sleep`) must not stall the
/// daemon when a large paste arrives: input is queued, a full queue is
/// refused `terminal_input_busy`, and other connections are served meanwhile.
#[tokio::test(flavor = "multi_thread")]
async fn a_paste_into_a_shell_that_is_not_reading_never_blocks_the_daemon() {
    let d = Daemon::start(&[Peer::App, Peer::Script]).await;
    let (_dir, cwd) = canonical_tmp();
    let mut app = d.app(vec![]).await;
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();
    // Wait until the shell is really running `sleep` (not still reading its
    // input), or the paste could be eaten by the line editor instead of
    // filling the queue. `-icanon` makes the tty hold back (rather than
    // discard) input it has no room for, so the daemon's writer blocks and the
    // queue fills however fast or slow the machine is. The marker is touched
    // by the command itself.
    let running = cwd.join("shell-is-busy");
    app.type_line(
        &tid,
        &format!("stty -icanon; touch '{}'; sleep 30", running.display()),
    )
    .await;
    let deadline = Instant::now() + WAIT;
    while !running.exists() {
        assert!(
            Instant::now() < deadline,
            "timed out waiting for the shell to start its command"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let from = app.mark();
    let chunk = vec![b'x'; 4096];
    for _ in 0..400 {
        app.input(&tid, &chunk).await;
    }
    app.wait_since(
        from,
        "a terminal_input_busy refusal",
        |m| matches!(m, ServerMsg::TerminalRefused { code, .. } if code == "terminal_input_busy"),
    )
    .await;

    // Another connection's handshake (which reads the terminal list) completes.
    let started = Instant::now();
    let mut other = d.script(vec![]).await;
    other
        .wait_since(0, "the terminal list", |m| {
            matches!(m, ServerMsg::TerminalList { .. })
        })
        .await;
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "a stuck shell held up another connection for {:?}",
        started.elapsed()
    );

    let from = app.mark();
    app.send(&ClientMsg::TerminalClose {
        terminal_id: tid.clone(),
    })
    .await;
    app.wait_since(
        from,
        "the close",
        |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == tid),
    )
    .await;
}

/// The screen model allocates rows x cols cells: a size far beyond any real
/// window is refused and the terminal keeps its size.
#[tokio::test(flavor = "multi_thread")]
async fn an_absurd_resize_is_refused_and_changes_nothing() {
    let d = Daemon::start(&[Peer::App]).await;
    let (_dir, cwd) = canonical_tmp();
    let mut app = d.app(vec![]).await;
    let info = app.open(TAG, Some(&cwd), "req-big").await;
    let from = app.mark();
    app.send(&ClientMsg::TerminalResize {
        terminal_id: info.terminal_id.clone(),
        cols: u16::MAX,
        rows: u16::MAX,
    })
    .await;
    let (_, refused) = app
        .wait_since(from, "the resize refusal", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    match refused {
        ServerMsg::TerminalRefused { op, code, .. } => {
            assert_eq!(op, "resize");
            assert_eq!(code, "invalid_size");
        }
        _ => unreachable!(),
    }
    let now = d.info(&info.terminal_id).expect("still there");
    assert_eq!((now.cols, now.rows), (info.cols, info.rows));
}

/// Once a fresh look at the peer stops seeing the verified app (another
/// process took over the socket), the connection loses terminal access for
/// good: the verb that noticed is refused, and so is every later one,
/// keystrokes included.
#[tokio::test(flavor = "multi_thread")]
async fn a_failed_re_check_of_the_peer_revokes_terminal_access_for_good() {
    // Re-inspections: activation (Subscribe) and the open see the app; the
    // attach sees someone else.
    let verifier =
        peer_verifier(&[Peer::App]).with_reinspect(vec![Some(app_info()), Some(app_info()), None]);
    let d = Daemon::start_with(verifier).await;
    let (_dir, cwd) = canonical_tmp();
    let mut app = d.app(vec![]).await;
    let info = app.open(TAG, Some(&cwd), "req-revoke").await;
    let tid = info.terminal_id.clone();

    let from = app.mark();
    app.send(&ClientMsg::TerminalAttach {
        terminal_id: tid.clone(),
    })
    .await;
    let (_, refused) = app
        .wait_since(from, "the attach refusal", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    assert!(
        matches!(&refused, ServerMsg::TerminalRefused { code, .. } if code == "terminal_read_forbidden"),
        "{refused:?}"
    );

    // Within the re-check interval, input is not re-inspected, yet it is
    // refused: the cap is gone.
    let from = app.mark();
    app.input(&tid, b"echo SHOULD-NOT-RUN\r").await;
    let (_, refused) = app
        .wait_since(from, "the input refusal", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    assert!(
        matches!(&refused, ServerMsg::TerminalRefused { code, .. } if code == "terminal_input_forbidden"),
        "{refused:?}"
    );
    app.sync().await;
    assert!(
        !app.log.iter().any(is_terminal_bytes_frame),
        "no terminal bytes after the failed re-check"
    );
}

/// One `terminal_input` frame over the size limit is refused whole, with a
/// code that says nothing about what was typed; none of it reaches the shell
/// and the terminal keeps working.
#[tokio::test(flavor = "multi_thread")]
async fn an_oversized_terminal_input_frame_is_refused_without_echoing_it_and_nothing_reaches_the_shell(
) {
    let d = Daemon::start(&[Peer::App]).await;
    let (_dir, cwd) = canonical_tmp();
    let mut app = d.app(vec![]).await;
    let info = app.open_ready(&cwd).await;
    let tid = info.terminal_id.clone();

    // Just over 256 KiB of something recognisable.
    let secret: Vec<u8> = b"SECRET-INPUT-"
        .iter()
        .copied()
        .cycle()
        .take(256 * 1024 + 1)
        .collect();
    let from = app.mark();
    app.input(&tid, &secret).await;
    let (_, refused) = app
        .wait_since(from, "the oversized input refusal", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    match &refused {
        ServerMsg::TerminalRefused {
            op,
            terminal_id,
            code,
        } => {
            assert_eq!(op, "input");
            assert_eq!(terminal_id.as_deref(), Some(tid.as_str()));
            assert_eq!(code, "terminal_input_too_large");
        }
        _ => unreachable!(),
    }
    let shown = serde_json::to_string(&refused).unwrap();
    assert!(
        !shown.contains("SECRET-INPUT") && !shown.contains(&b64(b"SECRET-INPUT-")[..12]),
        "the refusal must not carry the input: {shown}"
    );

    // Still usable, and the shell never saw a byte of the refused frame.
    let out = app.run(&tid, "echo STILL-WORKING-$((40+2))").await;
    assert!(out.contains("STILL-WORKING-42"), "{out:?}");
    assert!(
        !lossy(app.view(&tid)).contains("SECRET-INPUT"),
        "no byte of a refused frame may reach the shell"
    );
}

/// The cap is revoked by a failed 5 s re-check while output is piled up for
/// the connection (the app stopped reading, so the daemon's queues for it are
/// full). Nothing more is written to that connection afterwards: not a byte of
/// what was queued.
#[tokio::test(flavor = "multi_thread")]
async fn after_the_cap_is_revoked_not_one_more_terminal_byte_is_written_to_the_connection() {
    // Re-inspections: the Subscribe's activation, the open and the attach see
    // the app; the first input after the 5 s interval sees someone else.
    let verifier = peer_verifier(&[Peer::App]).with_reinspect(vec![
        Some(app_info()),
        Some(app_info()),
        Some(app_info()),
        None,
    ]);
    let d = Daemon::start_with(verifier).await;
    let (_dir, cwd) = canonical_tmp();
    let mut app = d.app(vec![]).await;
    let info = app.open(TAG, Some(&cwd), "req-flood").await;
    let tid = info.terminal_id.clone();
    app.attach(&tid).await;
    app.shell_ready(&tid).await;

    // A flood of output, then the app stops reading: the daemon's writes to it
    // back up until its own per-connection queue for the terminal is full.
    app.type_line(&tid, "yes 0123456789abcdef0123456789abcdef")
        .await;
    assert!(
        app.wait_view_from(&tid, 0, "0123456789abcdef", WAIT).await,
        "the flood never started"
    );
    let from = app.mark();
    app.stop_reading();
    // Past the re-check interval (5 s); the daemon is blocked writing to us.
    tokio::time::sleep(Duration::from_millis(5600)).await;
    app.input(&tid, b"x").await;
    app.resume_reading();

    let (revoked_at, refused) = app
        .wait_since(from, "the refusal after the failed re-check", |m| {
            matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    assert!(
        matches!(&refused, ServerMsg::TerminalRefused { code, .. } if code == "terminal_input_forbidden"),
        "{refused:?}"
    );

    // The ordering marker: a Pong is answered after everything the connection
    // was going to be sent, then give any straggler a moment to show up.
    app.sync().await;
    app.settle_ms(500).await;
    let stray = app.log[revoked_at + 1..]
        .iter()
        .filter(|m| is_terminal_bytes_frame(m))
        .count();
    assert_eq!(
        stray, 0,
        "{stray} terminal byte frames were written after the cap was revoked"
    );
}
