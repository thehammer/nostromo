//! The harness shared by `remote_shell_request.rs` and
//! `remote_shell_request_timeout.rs`: a real daemon (IPC socket, TCP listener,
//! MCP socket, audit file, terminal manager, pane registry) in a temp dir, with
//! the fixture ECS vocabulary copied in and a `FakeLauncher` standing in for
//! the AWS connect. Peers are scripted with the fake verifier, so "the app" is
//! whichever Unix connection the test says it is.
//!
//! Nothing here reads the real `~/.claude`, `~/.nostromo` or `~/.mother`:
//! `$HOME` is pointed at a private directory, the vocabulary files are copies of
//! `tests/fixtures/ecs/`, and the audit log, store and sockets live in a temp
//! dir. The only process a test can start is the fake launcher's `/bin/cat`.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::peer_verify::testing::{app_info, script_info, FakePeerVerifier};
use nostromo::ipc::peer_verify::PeerInfo;
use nostromo::ipc::protocol::{
    ClientMsg, FocusMeta, PaneTree, RemoteRequester, ServerMsg, TerminalInfo, TerminalTarget,
    Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use nostromo::terminal::audit::AuditLog;
use nostromo::terminal::ecs::EcsPaths;
use nostromo::terminal::launcher::testing::FakeLauncher;
use nostromo::terminal::store::TerminalStore;
use nostromo::terminal::{TerminalAgentApi, TerminalConfig, TerminalManager};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpStream, UnixStream};
use tokio::sync::mpsc;

/// The focus the agent under test runs in, and a second one.
pub const TAG: &str = "cody-rs-it";
pub const TAG2: &str = "cody-rs-it-2";
/// The agent's name, as the focus registry knows it.
pub const AGENT: &str = "cody";
pub const WAIT: Duration = Duration::from_secs(15);
pub const REQUEST: &str = "nostromo.request_remote_shell";
pub const LIST: &str = "nostromo.list_remote_shell_targets";
/// What the capable app declares in `Subscribe.capabilities`.
pub const CONFIRM_CAP: &str = "remote_shell_confirm";

/// The audit events this slice adds.
pub const REMOTE_EVENTS: [&str; 5] = [
    "remote_requested",
    "confirm_outcome",
    "connect_started",
    "connected",
    "connect_failed",
];

// ── process environment ──────────────────────────────────────────────────────

fn home_path() -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("remote-shell-it-home-{}", std::process::id()))
}

/// Once per test process: a private `$HOME` so nothing reads or writes the real
/// `~/.nostromo`.
pub fn init_process_env() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let home = home_path();
        std::fs::create_dir_all(home.join(".nostromo")).expect("create the private $HOME");
        std::env::set_var("HOME", &home);
        std::env::set_var("NOSTROMO_CLAUDE_BIN", "/bin/sh");
    });
}

pub fn fixture_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ecs")
}

// ── a runaway guard ──────────────────────────────────────────────────────────

/// Ends the whole test process if a test is still running after `secs` real
/// seconds. For tests on a paused clock, where a wrong guess about the runtime
/// would otherwise hang the run rather than fail it.
pub struct Watchdog(Arc<AtomicBool>);

impl Watchdog {
    pub fn arm(secs: u64) -> Watchdog {
        let done = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&done);
        std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(secs);
            while Instant::now() < deadline {
                if flag.load(Ordering::SeqCst) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            if !flag.load(Ordering::SeqCst) {
                eprintln!("watchdog: a test ran for more than {secs} s of real time; ending the run");
                std::process::exit(101);
            }
        });
        Watchdog(done)
    }
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

// ── the MCP client ───────────────────────────────────────────────────────────

pub struct Mcp {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    next_id: i64,
    wait: Duration,
}

impl Mcp {
    /// Send `hello` as the identifying first frame, then `initialize`.
    pub async fn connect(socket: &Path, hello: Value, wait: Duration) -> Mcp {
        let stream = UnixStream::connect(socket).await.expect("mcp connect");
        let (r, w) = stream.into_split();
        let mut mcp = Mcp {
            reader: BufReader::new(r),
            writer: w,
            next_id: 100,
            wait,
        };
        mcp.send(&hello).await;
        let init = mcp
            .rpc(
                "initialize",
                json!({"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}),
            )
            .await;
        assert!(init.get("error").is_none(), "initialize failed: {init}");
        mcp
    }

    pub async fn send(&mut self, v: &Value) {
        let mut bytes = serde_json::to_vec(v).unwrap();
        bytes.push(b'\n');
        self.writer.write_all(&bytes).await.expect("mcp write");
    }

    pub async fn recv(&mut self) -> Value {
        let mut line = String::new();
        let n = tokio::time::timeout(self.wait, self.reader.read_line(&mut line))
            .await
            .expect("timed out waiting for an MCP response")
            .expect("mcp read");
        assert!(n > 0, "the MCP connection was closed");
        serde_json::from_str(line.trim()).expect("response should be JSON")
    }

    pub async fn rpc(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .await;
        let resp = self.recv().await;
        assert_eq!(resp["id"], json!(id), "response to a different request: {resp}");
        resp
    }

    /// Send any request without waiting for its answer; the request id.
    pub async fn start_rpc(&mut self, method: &str, params: Value) -> i64 {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .await;
        id
    }

    /// Send a notification (no id, no answer owed).
    pub async fn notify(&mut self, method: &str, params: Value) {
        self.send(&json!({"jsonrpc":"2.0","method":method,"params":params}))
            .await;
    }

    /// Tell the server the client no longer wants the answer to request `id`.
    pub async fn cancel(&mut self, id: i64) {
        self.notify("notifications/cancelled", json!({"requestId": id}))
            .await;
    }

    /// Send a `tools/call` without waiting for its answer; the request id.
    pub async fn start_call(&mut self, name: &str, args: Value) -> i64 {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":name,"arguments":args}}))
            .await;
        id
    }

    /// The whole JSON-RPC response to a call started with [`Mcp::start_call`].
    pub async fn finish_raw(&mut self, id: i64) -> Value {
        let resp = self.recv().await;
        assert_eq!(resp["id"], json!(id), "response to a different request: {resp}");
        resp
    }

    /// The tool's JSON result for a call started with [`Mcp::start_call`].
    pub async fn finish(&mut self, id: i64) -> Value {
        let resp = self.finish_raw(id).await;
        assert!(resp.get("error").is_none(), "a JSON-RPC error: {resp}");
        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("no text content in {resp}"));
        serde_json::from_str(text).expect("tool content should be JSON")
    }

    pub async fn call_raw(&mut self, name: &str, args: Value) -> Value {
        let id = self.start_call(name, args).await;
        self.finish_raw(id).await
    }

    /// `tools/call` that must not be a JSON-RPC error; the tool's JSON result.
    pub async fn call(&mut self, name: &str, args: Value) -> Value {
        let id = self.start_call(name, args).await;
        self.finish(id).await
    }

    pub async fn list_tools(&mut self) -> Vec<Value> {
        let resp = self.rpc("tools/list", json!({})).await;
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("no tools in {resp}"))
            .clone()
    }
}

// ── the IPC client (the app, or anything else) ───────────────────────────────

/// What the confirm sheet is told.
#[derive(Debug, Clone)]
pub struct Confirm {
    pub request_id: String,
    pub tag: Option<String>,
    pub target: TerminalTarget,
    pub requested_by: RemoteRequester,
    pub reason: Option<String>,
    pub expires_at: String,
}

/// How the sheet is told it ended.
#[derive(Debug, Clone)]
pub struct Resolved {
    pub request_id: String,
    pub outcome: String,
    pub reason: Option<String>,
    pub remedy: Option<String>,
}

pub fn as_confirm(m: &ServerMsg) -> Option<Confirm> {
    match m {
        ServerMsg::RemoteShellConfirmRequest {
            request_id,
            tag,
            target,
            requested_by,
            reason,
            expires_at,
        } => Some(Confirm {
            request_id: request_id.clone(),
            tag: tag.clone(),
            target: target.clone(),
            requested_by: requested_by.clone(),
            reason: reason.clone(),
            expires_at: expires_at.clone(),
        }),
        _ => None,
    }
}

pub fn as_resolved(m: &ServerMsg) -> Option<Resolved> {
    match m {
        ServerMsg::RemoteShellResolved {
            request_id,
            outcome,
            reason,
            remedy,
        } => Some(Resolved {
            request_id: request_id.clone(),
            outcome: outcome.clone(),
            reason: reason.clone(),
            remedy: remedy.clone(),
        }),
        _ => None,
    }
}

/// Any of the three remote-shell frames the daemon sends.
pub fn is_remote_frame(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::RemoteShellTargets { .. }
            | ServerMsg::RemoteShellConfirmRequest { .. }
            | ServerMsg::RemoteShellResolved { .. }
    )
}

pub fn msg_type(m: &ServerMsg) -> String {
    serde_json::to_value(m)
        .ok()
        .and_then(|v| v["type"].as_str().map(str::to_string))
        .unwrap_or_else(|| "?".into())
}

/// One connection. A background task reads frames so a timed-out wait never
/// cancels a half-read frame; everything read is kept in `log`.
pub struct Client<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> {
    writer: tokio::io::WriteHalf<S>,
    rx: mpsc::UnboundedReceiver<Result<ServerMsg, String>>,
    reader: tokio::task::JoinHandle<()>,
    pub log: Vec<ServerMsg>,
    pub nonce: Option<String>,
    pub closed: bool,
    wait: Duration,
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> Drop for Client<S> {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> Client<S> {
    fn new(stream: S, wait: Duration) -> Self {
        let (mut read_half, writer) = tokio::io::split(stream);
        let (tx, rx) = mpsc::unbounded_channel();
        let reader = tokio::spawn(async move {
            loop {
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
            nonce: None,
            closed: false,
            wait,
        }
    }

    /// Hello (with `claim` as `client_kind`) -> Welcome -> Subscribe -> synced.
    pub async fn handshake(
        stream: S,
        claim: Option<&str>,
        topics: Vec<Topic>,
        caps: &[&str],
        renders_decisions: bool,
        wait: Duration,
    ) -> Self {
        let mut c = Self::new(stream, wait);
        c.send(&ClientMsg::Hello {
            client_id: "remote-shell-it".into(),
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
            renders_decisions,
            renders_approvals: false,
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            // Echo the Welcome's nonce, as the app does.
            operator_nonce: c.nonce.clone(),
        })
        .await;
        c.sync().await;
        c
    }

    pub async fn send(&mut self, msg: &ClientMsg) {
        write_frame(&mut self.writer, &serde_json::to_vec(msg).unwrap())
            .await
            .expect("write frame");
    }

    /// Read one frame within `within`; false on timeout or a closed connection.
    pub async fn pump(&mut self, within: Duration) -> bool {
        match tokio::time::timeout(within, self.rx.recv()).await {
            Ok(Some(Ok(msg))) => {
                self.log.push(msg);
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

    pub fn mark(&self) -> usize {
        self.log.len()
    }

    pub fn summary(&self) -> String {
        self.log.iter().map(msg_type).collect::<Vec<_>>().join(", ")
    }

    /// The first frame at or after log index `from` that `pred` accepts,
    /// waiting for it if it has not arrived.
    pub async fn wait_since(
        &mut self,
        from: usize,
        what: &str,
        pred: impl Fn(&ServerMsg) -> bool,
    ) -> (usize, ServerMsg) {
        let deadline = Instant::now() + self.wait;
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

    /// Ping and read to the Pong. The daemon answers it after the targeted
    /// frames it queued for this connection earlier.
    pub async fn sync(&mut self) {
        let from = self.mark();
        self.send(&ClientMsg::Ping).await;
        self.wait_since(from, "a Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
    }

    /// Keep reading for `d` (collecting frames).
    pub async fn settle(&mut self, d: Duration) {
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

    // ── remote-shell helpers ─────────────────────────────────────────────────

    pub async fn wait_confirm(&mut self, from: usize) -> Confirm {
        let (_, m) = self
            .wait_since(from, "a remote_shell_confirm_request", |m| {
                matches!(m, ServerMsg::RemoteShellConfirmRequest { .. })
            })
            .await;
        as_confirm(&m).unwrap()
    }

    pub async fn wait_resolved(&mut self, from: usize, request_id: &str) -> Resolved {
        let (_, m) = self
            .wait_since(from, "a remote_shell_resolved", |m| {
                matches!(m, ServerMsg::RemoteShellResolved { request_id: id, .. } if id == request_id)
            })
            .await;
        as_resolved(&m).unwrap()
    }

    pub fn confirms_since(&self, from: usize) -> Vec<Confirm> {
        self.log[from..].iter().filter_map(as_confirm).collect()
    }

    pub fn resolved_since(&self, from: usize) -> Vec<Resolved> {
        self.log[from..].iter().filter_map(as_resolved).collect()
    }

    pub fn remote_frames_since(&self, from: usize) -> Vec<String> {
        self.log[from..]
            .iter()
            .filter(|m| is_remote_frame(m))
            .map(msg_type)
            .collect()
    }

    /// `terminal_refused` frames since `from`: `(op, terminal_id, code)`.
    pub fn refusals_since(&self, from: usize) -> Vec<(String, Option<String>, String)> {
        self.log[from..]
            .iter()
            .filter_map(|m| match m {
                ServerMsg::TerminalRefused {
                    op,
                    terminal_id,
                    code,
                } => Some((op.clone(), terminal_id.clone(), code.clone())),
                _ => None,
            })
            .collect()
    }

    /// `error` frames since `from`.
    pub fn errors_since(&self, from: usize) -> Vec<String> {
        self.log[from..]
            .iter()
            .filter_map(|m| match m {
                ServerMsg::Error { message } => Some(message.clone()),
                _ => None,
            })
            .collect()
    }

    /// Nothing remote-shell reached this connection since `from`: everything
    /// queued for it has been delivered (a Ping/Pong round trip), then a short
    /// quiet window.
    pub async fn assert_no_remote_frames(&mut self, from: usize, what: &str) {
        self.sync().await;
        self.settle(Duration::from_millis(120)).await;
        let seen = self.remote_frames_since(from);
        assert!(
            seen.is_empty(),
            "{what}: received {seen:?}; all frames: [{}]",
            self.summary()
        );
    }

    /// Subscribe again (as the app does to change what it declares), echoing
    /// the Welcome's nonce.
    pub async fn resubscribe(&mut self, topics: Vec<Topic>, caps: &[&str]) {
        let nonce = self.nonce.clone();
        self.send(&ClientMsg::Subscribe {
            topics,
            renders_decisions: false,
            renders_approvals: false,
            capabilities: caps.iter().map(|s| s.to_string()).collect(),
            operator_nonce: nonce,
        })
        .await;
    }

    pub async fn answer(&mut self, request_id: &str, decision: &str) {
        self.send(&ClientMsg::RemoteShellAnswer {
            request_id: request_id.into(),
            decision: decision.into(),
            invite_follow: false,
        })
        .await;
    }

    pub async fn answer_following(&mut self, request_id: &str, decision: &str) {
        self.send(&ClientMsg::RemoteShellAnswer {
            request_id: request_id.into(),
            decision: decision.into(),
            invite_follow: true,
        })
        .await;
    }

    /// `remote_shell_open` for canonical (or aliased) words in focus `tag`.
    pub async fn open_remote(&mut self, tag: &str, words: [&str; 4]) {
        let [project, environment, service, shell_type] = words;
        self.send(&ClientMsg::RemoteShellOpen {
            tag: tag.into(),
            project: project.into(),
            environment: environment.into(),
            service: service.into(),
            shell_type: shell_type.into(),
        })
        .await;
    }
}

pub type Unix = Client<UnixStream>;
pub type Tcp = Client<TcpStream>;

// ── the daemon under test ────────────────────────────────────────────────────

/// Who the fake verifier says the n-th Unix connection is, in connect order.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Peer {
    /// The genuine, pinned Mac app (still needs the `mac_app` claim).
    App,
    /// An ordinary local process.
    Script,
}

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

pub struct Options {
    pub peers: Vec<Peer>,
    /// Install the `FakeLauncher` (false: the daemon's default launcher stays).
    pub fake_launcher: bool,
    /// How long a client helper waits for something (real seconds, normally).
    pub wait: Duration,
}

impl Options {
    pub fn new(peers: &[Peer]) -> Options {
        Options {
            peers: peers.to_vec(),
            fake_launcher: true,
            wait: WAIT,
        }
    }
}

pub struct Daemon {
    pub server: Server,
    _mcp: McpServer,
    pub terminals: Arc<Mutex<TerminalManager>>,
    pub panes: Arc<Mutex<PaneRegistry>>,
    pub session_mgr: Arc<Mutex<SessionManager>>,
    pub launcher: Option<Arc<FakeLauncher>>,
    pub ipc_sock: PathBuf,
    pub mcp_sock: PathBuf,
    pub tcp_port: u16,
    pub audit_path: PathBuf,
    /// The copies of the fixture vocabulary this daemon reads.
    pub ecs_dir: PathBuf,
    pub wait: Duration,
    _tmp: TempDir,
}

impl Drop for Daemon {
    /// No test may leave a process behind.
    fn drop(&mut self) {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .shutdown();
    }
}

pub fn focus_meta(tag: &str) -> FocusMeta {
    FocusMeta {
        initial_model: None,
        initial_effort: None,
        tag: tag.to_string(),
        display_name: tag.to_string(),
        agent_name: AGENT.to_string(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
    }
}

impl Daemon {
    pub async fn start(peers: &[Peer]) -> Daemon {
        Self::start_with(Options::new(peers)).await
    }

    pub async fn start_with(opts: Options) -> Daemon {
        init_process_env();
        let tmp = TempDir::new().expect("tempdir");

        // The vocabulary: copies of the fixtures, so a test may edit them.
        let ecs_dir = tmp.path().join("ecs");
        std::fs::create_dir_all(&ecs_dir).unwrap();
        for name in ["config.json", "ecs-local.json", "ecs.sh"] {
            std::fs::copy(fixture_dir().join(name), ecs_dir.join(name)).expect("copy fixture");
        }

        let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
        let audit_path = tmp.path().join("audit").join("terminal.jsonl");
        let terminals = TerminalManager::new(TerminalConfig {
            audit: AuditLog::open(&audit_path).expect("open the audit log"),
            store: TerminalStore::in_memory(),
            pane_registry: Some(Arc::clone(&panes)),
        });
        let launcher = opts.fake_launcher.then(|| FakeLauncher::new(&terminals));
        {
            let mut m = terminals.lock().unwrap();
            m.set_ecs_paths(EcsPaths::new(
                ecs_dir.join("config.json"),
                ecs_dir.join("ecs-local.json"),
                ecs_dir.join("ecs.sh"),
            ));
            if let Some(l) = &launcher {
                m.set_remote_launcher(l.clone());
            }
        }

        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
        let ipc_sock = tmp.path().join("nostromod.sock");
        let server = Server::bind(
            &ipc_sock,
            Arc::clone(&session_mgr),
            tmp.path().join("perri-state"),
            Arc::clone(&decisions),
            Arc::new(peer_verifier(&opts.peers)),
            false,
            Arc::clone(&terminals),
        )
        .expect("bind the daemon socket");
        decisions
            .lock()
            .unwrap()
            .configure_broadcast(server.tx.clone());
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

        let backend = DaemonMcpBackend {
            pane_registry: Arc::clone(&panes),
            session_mgr: Arc::clone(&session_mgr),
            broadcast_tx: server.tx.clone(),
            perri: PerriDaemonState::default(),
            decisions,
            tickets: Default::default(),
            tracker: Default::default(),
            terminals: TerminalAgentApi::new(Arc::clone(&terminals)),
        };
        let mcp_sock = tmp.path().join("mcp.sock");
        let mcp = McpServer::bind(mcp_sock.clone(), McpSharedState::for_daemon(backend))
            .await
            .expect("bind the MCP socket");

        Daemon {
            server,
            _mcp: mcp,
            terminals,
            panes,
            session_mgr,
            launcher,
            ipc_sock,
            mcp_sock,
            tcp_port,
            audit_path,
            ecs_dir,
            wait: opts.wait,
            _tmp: tmp,
        }
    }

    pub fn launcher(&self) -> &Arc<FakeLauncher> {
        self.launcher.as_ref().expect("this daemon has the fake launcher")
    }

    /// A focus with a pane tree, known to the daemon as an agent named `cody`.
    pub fn init_focus(&self, tag: &str) {
        self.panes.lock().unwrap().get_or_init(tag);
        let mut mgr = self.session_mgr.lock().unwrap();
        let mut focuses = mgr.focus_registry();
        focuses.retain(|f| f.tag != tag);
        focuses.push(focus_meta(tag));
        mgr.set_focus_registry(focuses);
    }

    // ── connections ──────────────────────────────────────────────────────────

    pub async fn unix(
        &self,
        topics: Vec<Topic>,
        claim: Option<&str>,
        caps: &[&str],
        renders_decisions: bool,
    ) -> Unix {
        let stream = UnixStream::connect(&self.ipc_sock).await.expect("unix connect");
        Client::handshake(stream, claim, topics, caps, renders_decisions, self.wait).await
    }

    /// The verified app, with the sheet (`remote_shell_confirm`). The verifier
    /// must say "app" for this connection.
    pub async fn app(&self) -> Unix {
        let c = self
            .unix(
                vec![Topic::Terminal, Topic::Layout],
                Some("mac_app"),
                &["terminal_ui", CONFIRM_CAP],
                false,
            )
            .await;
        assert!(
            c.nonce.is_some(),
            "the verified app's Welcome must carry an operator_nonce (is the Peer list right?)"
        );
        c
    }

    /// The verified app of an older build: it cannot show the sheet.
    pub async fn app_without_sheet(&self) -> Unix {
        let c = self
            .unix(vec![], Some("mac_app"), &["terminal_ui"], false)
            .await;
        assert!(c.nonce.is_some(), "harness: the Peer list must say App here");
        c
    }

    /// An ordinary local process that declares the capability anyway.
    pub async fn script(&self, topics: Vec<Topic>, caps: &[&str]) -> Unix {
        let c = self.unix(topics, None, caps, false).await;
        assert!(c.nonce.is_none(), "a non-operator gets no operator_nonce");
        c
    }

    /// An ordinary local process that claims to be the app (the verifier says
    /// otherwise) and declares everything the app does.
    pub async fn claiming_app(&self) -> Unix {
        let c = self
            .unix(vec![], Some("mac_app"), &["terminal_ui", CONFIRM_CAP], true)
            .await;
        assert!(
            c.nonce.is_none(),
            "a claim without a verified bundle must not make an operator"
        );
        c
    }

    /// A TCP connection (it claims `mac_app`; the claim never lifts a network peer).
    pub async fn tcp(&self, topics: Vec<Topic>, renders_decisions: bool) -> Tcp {
        let stream = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        Client::handshake(
            stream,
            Some("mac_app"),
            topics,
            &[CONFIRM_CAP],
            renders_decisions,
            self.wait,
        )
        .await
    }

    /// An agent connection whose Hello names `tag` (none: an unidentified caller).
    pub async fn mcp(&self, tag: Option<&str>) -> Mcp {
        let hello = match tag {
            Some(t) => json!({"type":"hello","pty_id": t}),
            None => json!({"type":"hello"}),
        };
        Mcp::connect(&self.mcp_sock, hello, self.wait).await
    }

    // ── what the daemon holds ────────────────────────────────────────────────

    pub fn list(&self) -> Vec<TerminalInfo> {
        self.terminals.lock().unwrap_or_else(|e| e.into_inner()).list()
    }

    pub fn info(&self, terminal_id: &str) -> Option<TerminalInfo> {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .info(terminal_id)
    }

    pub fn tree(&self, tag: &str) -> Option<PaneTree> {
        self.panes.lock().unwrap().get(tag).cloned()
    }

    pub fn leaves(&self, tag: &str) -> Vec<String> {
        self.panes.lock().unwrap().terminal_leaves(tag)
    }

    pub fn pane_ids(&self, tag: &str) -> Vec<String> {
        self.panes.lock().unwrap().pane_ids(tag)
    }

    /// No terminal, no pane leaf in either focus, and (when there is a fake
    /// launcher) no connect call.
    pub fn assert_nothing_opened(&self, what: &str) {
        assert!(self.list().is_empty(), "{what}: a terminal exists: {:?}", self.list());
        for tag in [TAG, TAG2] {
            assert!(self.leaves(tag).is_empty(), "{what}: a terminal leaf exists in {tag}");
        }
        if let Some(l) = &self.launcher {
            assert_eq!(l.calls(), 0, "{what}: the launcher was called");
        }
    }

    // ── the ECS data this daemon reads ───────────────────────────────────────

    pub fn ecs_file(&self, name: &str) -> PathBuf {
        self.ecs_dir.join(name)
    }

    pub fn edit_ecs(&self, name: &str, f: impl FnOnce(String) -> String) {
        let path = self.ecs_file(name);
        let before = std::fs::read_to_string(&path).expect("read the vocabulary file");
        let after = f(before.clone());
        assert_ne!(before, after, "harness: the edit of {name} changed nothing");
        std::fs::write(&path, after).expect("write the vocabulary file");
    }

    pub fn remove_ecs(&self, name: &str) {
        std::fs::remove_file(self.ecs_file(name)).expect("remove the vocabulary file");
    }

    // ── the audit trail ──────────────────────────────────────────────────────

    pub fn audit(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.audit_path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    pub fn audit_text(&self) -> String {
        std::fs::read_to_string(&self.audit_path).unwrap_or_default()
    }

    /// The first audit line `pred` accepts (waits for it).
    pub async fn wait_audit(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + self.wait;
        loop {
            if let Some(line) = self.audit().into_iter().find(|l| pred(l)) {
                return line;
            }
            assert!(
                Instant::now() < deadline,
                "no audit line for {what}; audit so far: {:#?}",
                self.audit()
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// The remote-shell audit lines, in order.
    pub fn remote_audit(&self) -> Vec<Value> {
        self.audit()
            .into_iter()
            .filter(|l| REMOTE_EVENTS.contains(&l["event"].as_str().unwrap_or_default()))
            .collect()
    }

    /// Their event names, in order (`confirm_outcome` as `confirm_outcome:<outcome>`).
    pub fn remote_audit_names(&self) -> Vec<String> {
        self.remote_audit()
            .iter()
            .map(|l| {
                let event = l["event"].as_str().unwrap_or_default();
                match l["outcome"].as_str() {
                    Some(outcome) if event == "confirm_outcome" => format!("{event}:{outcome}"),
                    _ => event.to_string(),
                }
            })
            .collect()
    }

    pub fn refused_lines(&self, channel: &str) -> Vec<Value> {
        self.audit()
            .into_iter()
            .filter(|l| l["event"] == "refused" && l["channel"] == channel)
            .collect()
    }
}

// ── the usual scene ──────────────────────────────────────────────────────────

/// One daemon, the verified app with the sheet, and an agent connection in
/// focus [`TAG`].
pub struct Scene {
    pub d: Daemon,
    pub app: Unix,
    pub mcp: Mcp,
}

impl Scene {
    pub async fn start() -> Scene {
        Self::start_with(Options::new(&[Peer::App])).await
    }

    pub async fn start_with(opts: Options) -> Scene {
        let d = Daemon::start_with(opts).await;
        d.init_focus(TAG);
        let app = d.app().await;
        let mcp = d.mcp(Some(TAG)).await;
        Scene { d, app, mcp }
    }

    /// Start a request and wait for the sheet to be shown: the MCP call id and
    /// what the app was told.
    pub async fn ask(&mut self, args: Value) -> (i64, Confirm) {
        let from = self.app.mark();
        let call = self.mcp.start_call(REQUEST, args).await;
        let confirm = self.app.wait_confirm(from).await;
        (call, confirm)
    }
}

/// A valid request: admin-portal, production, scheduler, shell.
pub fn args() -> Value {
    json!({
        "project": "admin-portal",
        "environment": "production",
        "service": "scheduler",
        "shell_type": "shell",
        "reason": "Check why the nightly job did not run",
    })
}

/// [`args`] with `key` set (or added) to `value`.
pub fn args_with(key: &str, value: Value) -> Value {
    let mut a = args();
    a[key] = value;
    a
}

/// [`args`] without `key`.
pub fn args_without(key: &str) -> Value {
    let mut a = args();
    a.as_object_mut().unwrap().remove(key);
    a
}

/// The canonical target [`args`] names.
pub fn canonical_target() -> TerminalTarget {
    TerminalTarget {
        project: "admin-portal".into(),
        environment: "production".into(),
        service: "scheduler".into(),
        shell_type: "shell".into(),
    }
}
