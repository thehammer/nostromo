//! The approval wire, end to end (AP0b): a real `Server` on a temp Unix socket and an
//! ephemeral TCP port, a real `SessionManager` running the hermetic fake `claude`
//! (`tests/support/fake_claude_perm.py`), the real `ApprovalBroker` over a temp audit
//! directory, and `Peers` standing in for "what process is behind this socket".
//!
//! Order of the file (contract section 10):
//!   1. a Unix "app" (the verified Mac app, `renders_approvals: true`): the positive controls;
//!   2. a Unix "agent" (`LocalOther`: an agent's own Bash, even one that claims `mac_app`);
//!   3. raw TCP (a LAN peer).
//!
//! What this pins, from outside the daemon:
//! - a request is held for a human only when the guard let it through, the session carries
//!   the guard hook, and a verified app that renders approvals is connected;
//! - only the verified app answers (with its connection's nonce); first answer wins;
//! - what the CLI is told for each ending, byte for byte;
//! - which frames reach whom: a TCP peer learns at most a count, and never for a sensitive focus;
//! - every refusal leaves a `refusal` entry in the audit log.
//!
//! Time is paused tokio time and never advances unless a test calls `tokio::time::advance`.
//! Every wait polls in real time and yields, so the paused clock cannot run ahead on its own
//! while a socket or a child process is slow. Environment variables are process-wide, so every
//! test takes `ENV_LOCK`.

use std::collections::VecDeque;
use std::future::Future;
use std::os::fd::BorrowedFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use nostromo::approvals::audit::{AuditFilter, Entry, Event};
use nostromo::approvals::broker::{
    ApprovalBroker, BrokerParts, APPROVAL_TIMEOUT, APPROVAL_UNAVAILABLE_MESSAGE, NO_APP_MESSAGE,
    PRESENTER_GRACE, TIMED_OUT_MESSAGE,
};
use nostromo::approvals::guard::{
    self, hook_settings_json, PaneInfo, PaneProbe, ProbeError, TmuxSocket, GUARD_MESSAGE,
};
use nostromo::approvals::request::{AskRule, SettingsSource};
use nostromo::approvals::wire::{
    AnswerRefusal, ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind,
    QuestionAnswer, RefusalChannel,
};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::peer_verify::testing::{app_info, script_info};
use nostromo::ipc::peer_verify::{CodeIdentity, PeerInfo, PeerVerifier, UnverifiedReason};
use nostromo::ipc::protocol::{
    ClientMsg, PermissionDecision, ServerMsg, SessionAction, Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::session_manager::{SessionManager, CLAUDE_BIN_ENV};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::mpsc;

// ── fixtures ──────────────────────────────────────────────────────────────────

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/approvals")
}

fn fixture(name: &str) -> Value {
    let path = fixtures_dir().join(format!("{name}.json"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&text).unwrap()
}

/// Every topic a client can name.
const ALL_TOPICS: [Topic; 12] = [
    Topic::Activity,
    Topic::MotherJobs,
    Topic::MotherStatusline,
    Topic::Focuses,
    Topic::MotherPeek,
    Topic::Perri,
    Topic::Fred,
    Topic::Teri,
    Topic::Work,
    Topic::Layout,
    Topic::Decision,
    Topic::Model,
];

// ── test doubles ──────────────────────────────────────────────────────────────

/// Who is behind each Unix connection, in accept order: the test queues the identity right
/// before it connects. A connection with nothing queued is unidentifiable (never the app).
#[derive(Default)]
struct Peers {
    next: Mutex<VecDeque<PeerInfo>>,
}

impl Peers {
    fn queue(&self, info: PeerInfo) {
        self.next.lock().unwrap().push_back(info);
    }
}

impl PeerVerifier for Peers {
    fn inspect(&self, _fd: BorrowedFd<'_>, verify_code: bool) -> Option<PeerInfo> {
        let mut info = self.next.lock().unwrap().pop_front()?;
        if !verify_code {
            info.code = CodeIdentity::Unverified {
                reason: UnverifiedReason::NotChecked,
            };
        }
        Some(info)
    }

    /// The answer-time look at the peer: the very process accepted at `Hello`.
    fn reinspect(&self, _fd: BorrowedFd<'_>, accepted: &PeerInfo) -> Option<PeerInfo> {
        Some(accepted.clone())
    }
}

/// tmux as the guard sees it: pane `%9` runs a production shell.
struct ProdPane;

impl PaneProbe for ProdPane {
    fn pane(&self, _socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        Ok((target == "%9").then(|| PaneInfo {
            pid: 4242,
            title: "production:portal:web".into(),
        }))
    }

    fn all_panes(&self, _socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        Ok(Vec::new())
    }

    fn subtree_args(&self, _pid: u32) -> Result<Vec<String>, ProbeError> {
        Ok(Vec::new())
    }

    fn servers(&self, _extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        Ok(vec![TmuxSocket::Default])
    }
}

struct NoRules;

impl SettingsSource for NoRules {
    fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
        Vec::new()
    }
}

// ── the world ─────────────────────────────────────────────────────────────────

struct KillOnDrop(Arc<Mutex<SessionManager>>);

impl Drop for KillOnDrop {
    fn drop(&mut self) {
        self.0
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

#[derive(Clone, Copy)]
struct Opts {
    /// Sessions carry the guard hook in their arguments (the production case).
    guard_hook: bool,
}

const GUARDED: Opts = Opts { guard_hook: true };

struct Rig {
    // Declared first so the fake CLIs are killed before their directory goes.
    _kill: KillOnDrop,
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    session_mgr: Arc<Mutex<SessionManager>>,
    broker: ApprovalBroker,
    peers: Arc<Peers>,
    tmp: TempDir,
    spawns: usize,
    sentinels: usize,
}

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Run `body` in a fresh world on a paused-clock runtime. Serialized: the environment is process-wide.
fn run<Fut: Future<Output = ()>>(opts: Opts, body: impl FnOnce(Rig) -> Fut) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    rt.block_on(async move {
        let rig = Rig::new(opts).await;
        body(rig).await;
    });
}

impl Rig {
    async fn new(opts: Opts) -> Self {
        let tmp = TempDir::new().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let approvals_dir = tmp.path().join("approvals");
        std::env::set_var("HOME", &home);
        std::env::set_var(nostromo::approvals::APPROVALS_DIR_ENV, &approvals_dir);
        std::env::set_var(guard::GUARD_BIN_ENV, env!("CARGO_BIN_EXE_nostromo-guard"));

        let broker = ApprovalBroker::new(
            nostromo::approvals::audit::AuditLog::open(&approvals_dir).unwrap(),
            BrokerParts {
                probe: Arc::new(|| Box::new(ProdPane)),
                settings: Arc::new(NoRules),
                ..BrokerParts::system()
            },
        );
        let mut mgr = SessionManager::with_store_path(tmp.path().join("daemon-sessions.json"));
        mgr.configure_approvals(broker.clone());
        if !opts.guard_hook {
            mgr.omit_guard_hook_for_test();
        }
        let session_mgr = Arc::new(Mutex::new(mgr));
        let peers = Arc::new(Peers::default());
        let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
        let socket_path = tmp.path().join("test.sock");
        let server = Server::bind(
            &socket_path,
            Arc::clone(&session_mgr),
            tmp.path().join("perri-state"),
            Arc::clone(&decisions),
            peers.clone(),
            false,
            nostromo::terminal::TerminalManager::in_memory(),
        )
        .expect("bind the unix socket");
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind tcp");
        let tcp_port = listener.local_addr().unwrap().port();
        server.bind_tcp(
            listener,
            Arc::clone(&session_mgr),
            tmp.path().join("perri-state"),
            decisions,
        );
        Self {
            _kill: KillOnDrop(Arc::clone(&session_mgr)),
            server,
            socket_path,
            tcp_port,
            session_mgr,
            broker,
            peers,
            tmp,
            spawns: 0,
            sentinels: 0,
        }
    }

    /// Start a session of the fake CLI under `tag`.
    fn spawn(&mut self, tag: &str) -> Fake {
        self.spawns += 1;
        let dir = self.tmp.path().join(format!("fake-{}", self.spawns));
        std::fs::create_dir_all(&dir).unwrap();
        let wrapper = dir.join("claude");
        std::fs::write(
            &wrapper,
            format!(
                "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
                dir.display()
            ),
        )
        .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
        let work = self.tmp.path().join("work");
        std::fs::create_dir_all(&work).unwrap();
        self.session_mgr
            .lock()
            .unwrap()
            .spawn_session(
                tag.into(),
                "cody".into(),
                format!("view-{tag}"),
                Some(work.clone()),
                None,
                false,
            )
            .expect("the session starts");
        Fake { dir, work }
    }

    fn say(&self, tag: &str, text: &str) {
        self.session_mgr
            .lock()
            .unwrap()
            .send_user_message(tag, text, &[])
            .expect("the message is accepted");
    }

    /// Spawn `tag`, say `cue`, and wait for the request to be shown to `app`.
    async fn held(&mut self, app: &mut Conn, tag: &str, cue: &str) -> (Fake, ApprovalRequestWire) {
        let fake = self.spawn(tag);
        self.say(tag, cue);
        let wire = app.next_request().await;
        (fake, wire)
    }

    /// Broadcast a frame nobody cares about. The broadcast channel is ordered, so a client that has
    /// received it has received every broadcast sent before it.
    fn sentinel(&mut self) -> String {
        self.sentinels += 1;
        let message = format!("sentinel-{}", self.sentinels);
        let _ = self.server.tx.send(ServerMsg::Error {
            message: message.clone(),
        });
        message
    }

    fn audit(&self) -> Vec<Entry> {
        self.broker
            .audit()
            .read(everything(), &AuditFilter::default())
            .unwrap()
    }

    fn refusals(&self) -> Vec<Entry> {
        self.audit()
            .into_iter()
            .filter(|e| matches!(e.event, Event::Refusal { .. }))
            .collect()
    }

    fn outcomes(&self) -> Vec<Entry> {
        self.audit()
            .into_iter()
            .filter(|e| matches!(e.event, Event::Outcome { .. }))
            .collect()
    }

    async fn wait_refusals(&self, n: usize) -> Vec<Entry> {
        wait_until(&format!("{n} refusal entries"), || {
            let r = self.refusals();
            (r.len() >= n).then_some(r)
        })
        .await
    }

    async fn wait_outcome(&self, tool_use_id: &str) -> Entry {
        wait_until(&format!("an outcome for {tool_use_id}"), || {
            self.outcomes()
                .into_iter()
                .find(|e| e.tool_use_id.as_deref() == Some(tool_use_id))
        })
        .await
    }

    // ── connections ──

    /// The verified Mac app. `renders`: whether it subscribes with `renders_approvals`.
    async fn app(&self, renders: bool) -> Conn {
        self.open_unix(
            app_info(),
            Some("mac_app"),
            serde_json::to_value(ClientMsg::Subscribe {
                topics: vec![Topic::Decision],
                renders_decisions: false,
                renders_approvals: renders,
                capabilities: vec![],
                operator_nonce: None,
            })
            .unwrap(),
        )
        .await
    }

    /// The verified Mac app, subscribing with a hand-written frame.
    async fn app_subscribing(&self, subscribe: Value) -> Conn {
        self.open_unix(app_info(), Some("mac_app"), subscribe).await
    }

    /// An agent's own process on the daemon's socket. It claims to be the Mac app and claims to
    /// render approvals; the process behind it is not the app.
    async fn agent(&self, topics: Vec<Topic>) -> Conn {
        self.open_unix(
            script_info(),
            Some("mac_app"),
            serde_json::to_value(ClientMsg::Subscribe {
                topics,
                renders_decisions: false,
                renders_approvals: true,
                capabilities: vec![],
                operator_nonce: None,
            })
            .unwrap(),
        )
        .await
    }

    /// A LAN peer, which claims to render approvals too.
    async fn tcp(&self, topics: Vec<Topic>) -> Conn {
        let s = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        let (r, w) = s.into_split();
        Conn::start(r, w)
            .handshake(
                None,
                serde_json::to_value(ClientMsg::Subscribe {
                    topics,
                    renders_decisions: false,
                    renders_approvals: true,
                    capabilities: vec![],
                    operator_nonce: None,
                })
                .unwrap(),
            )
            .await
    }

    async fn open_unix(&self, info: PeerInfo, client_kind: Option<&str>, subscribe: Value) -> Conn {
        self.peers.queue(info);
        let s = UnixStream::connect(&self.socket_path)
            .await
            .expect("unix connect");
        let (r, w) = s.into_split();
        Conn::start(r, w).handshake(client_kind, subscribe).await
    }
}

fn everything() -> std::ops::Range<DateTime<Utc>> {
    Utc::now() - ChronoDuration::days(2)..Utc::now() + ChronoDuration::days(2)
}

/// Real-time polling that never parks the (paused) runtime, so the clock stays where the test put it.
async fn wait_until<R>(what: &str, mut ready: impl FnMut() -> Option<R>) -> R {
    let start = Instant::now();
    loop {
        if let Some(v) = ready() {
            return v;
        }
        assert!(
            start.elapsed() < Duration::from_secs(30),
            "timed out (real time) waiting for {what}"
        );
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

/// Give spawned tasks, sockets and the blocking pool a moment of real time, without parking the runtime.
async fn settle() {
    for _ in 0..40 {
        std::thread::sleep(Duration::from_millis(2));
        tokio::task::yield_now().await;
    }
}

// ── a client connection ───────────────────────────────────────────────────────

/// One connection, read by a task of its own: frames are collected as they arrive and examined
/// by polling, so a wait never parks the paused runtime.
struct Conn {
    tx: Box<dyn AsyncWrite + Unpin + Send>,
    rx: mpsc::UnboundedReceiver<Vec<u8>>,
    raw: Vec<Vec<u8>>,
    seen: Vec<ServerMsg>,
    cursor: usize,
    nonce: Option<String>,
    features: Vec<String>,
    connect_frames: Vec<ServerMsg>,
    /// How many frames of each kind `nth` has handed out.
    taken: std::collections::HashMap<&'static str, usize>,
    reader: tokio::task::JoinHandle<()>,
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

impl Conn {
    fn start<R, W>(mut r: R, w: W) -> Self
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (tx, rx) = mpsc::unbounded_channel();
        let reader = tokio::spawn(async move {
            while let Ok(bytes) = read_frame(&mut r).await {
                if tx.send(bytes).is_err() {
                    break;
                }
            }
        });
        Self {
            tx: Box::new(w),
            rx,
            raw: Vec::new(),
            seen: Vec::new(),
            cursor: 0,
            nonce: None,
            features: Vec::new(),
            connect_frames: Vec::new(),
            taken: std::collections::HashMap::new(),
            reader,
        }
    }

    /// Hello, Welcome, Subscribe, then a Ping/Pong so the subscription is registered.
    async fn handshake(mut self, client_kind: Option<&str>, subscribe: Value) -> Self {
        self.send(&ClientMsg::Hello {
            client_id: "approvals-wire-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: client_kind.map(str::to_owned),
        })
        .await;
        match self
            .next("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await
        {
            ServerMsg::Welcome {
                operator_nonce,
                features,
                ..
            } => {
                self.nonce = operator_nonce;
                self.features = features;
            }
            _ => unreachable!(),
        }
        self.send_raw(&serde_json::to_vec(&subscribe).unwrap())
            .await;
        self.connect_frames = self.sync().await;
        self
    }

    async fn send(&mut self, msg: &ClientMsg) {
        self.send_raw(&serde_json::to_vec(msg).unwrap()).await;
    }

    async fn send_raw(&mut self, bytes: &[u8]) {
        write_frame(&mut self.tx, bytes)
            .await
            .expect("write a frame");
    }

    /// Move whatever has arrived into `seen`.
    fn pump(&mut self) {
        while let Ok(bytes) = self.rx.try_recv() {
            let msg: ServerMsg = serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                panic!(
                    "undecodable frame ({e}): {}",
                    String::from_utf8_lossy(&bytes)
                )
            });
            self.raw.push(bytes);
            self.seen.push(msg);
        }
    }

    fn find_from_cursor(&mut self, pred: &impl Fn(&ServerMsg) -> bool) -> Option<usize> {
        self.pump();
        (self.cursor..self.seen.len()).find(|&i| pred(&self.seen[i]))
    }

    /// The next frame (from where the last `next`/`sync` stopped) that `pred` accepts.
    async fn next(&mut self, what: &str, pred: impl Fn(&ServerMsg) -> bool) -> ServerMsg {
        let start = Instant::now();
        loop {
            if let Some(i) = self.find_from_cursor(&pred) {
                self.cursor = i + 1;
                return self.seen[i].clone();
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out (real time) waiting for {what}; got {:#?}",
                self.seen
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    /// The next frame of a kind that has not been handed out yet, wherever it falls among the
    /// other frames (frames of different kinds can arrive in either order).
    async fn nth(&mut self, kind: &'static str, pred: fn(&ServerMsg) -> bool) -> ServerMsg {
        let n = self.taken.get(kind).copied().unwrap_or(0);
        let start = Instant::now();
        loop {
            self.pump();
            if let Some(m) = self.seen.iter().filter(|m| pred(m)).nth(n) {
                let m = m.clone();
                self.taken.insert(kind, n + 1);
                return m;
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out (real time) waiting for {kind} #{}; got {:#?}",
                n + 1,
                self.seen
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    async fn next_request(&mut self) -> ApprovalRequestWire {
        match self.nth("approval_request", is_request).await {
            ServerMsg::ApprovalRequest { tag, request } => {
                assert_eq!(
                    tag, request.tag,
                    "the frame and the request name the same focus"
                );
                request
            }
            _ => unreachable!(),
        }
    }

    async fn next_resolved(&mut self) -> (String, String, Option<String>) {
        match self.nth("approval_resolved", is_resolved).await {
            ServerMsg::ApprovalResolved {
                request_id,
                outcome,
                by_window,
                ..
            } => (request_id, outcome, by_window),
            _ => unreachable!(),
        }
    }

    async fn next_refused(&mut self) -> (String, AnswerRefusal, Option<String>) {
        match self.nth("approval_answer_refused", is_answer_refused).await {
            ServerMsg::ApprovalAnswerRefused {
                request_id,
                code,
                outcome,
            } => (request_id, code, outcome),
            _ => unreachable!(),
        }
    }

    /// Ping, wait for the Pong; the frames that came before it (from the cursor), Pong excluded.
    async fn sync(&mut self) -> Vec<ServerMsg> {
        let start = self.cursor;
        self.send(&ClientMsg::Ping).await;
        self.next("the Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
        self.seen[start..self.cursor - 1].to_vec()
    }

    /// Wait until some frame received so far, or yet to come, satisfies `pred`; does not move the
    /// cursor (for frames that may have been passed over by a later `next`).
    async fn wait_seen(&mut self, what: &str, pred: impl Fn(&ServerMsg) -> bool) {
        let start = Instant::now();
        loop {
            if self.all().iter().any(&pred) {
                return;
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out (real time) waiting for {what}; got {:#?}",
                self.seen
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    async fn wait_pending(&mut self, tag: &str, count: u32) {
        let want = tag.to_owned();
        self.wait_seen(&format!("pending {count} for {tag}"), move |m| {
            matches!(m, ServerMsg::ApprovalPending { tag, count: c } if *tag == want && *c == count)
        })
        .await;
    }

    /// The `approval_request` frame for `request_id`, as it was received (JSON).
    fn request_frame(&mut self, request_id: &str) -> Value {
        self.pump();
        self.raw
            .iter()
            .filter_map(|b| serde_json::from_slice::<Value>(b).ok())
            .find(|v| v["type"] == "approval_request" && v["request"]["request_id"] == request_id)
            .expect("an approval_request frame")
    }

    /// Wait until the broadcast `sentinel` has arrived (everything sent before it has too).
    async fn through(&mut self, sentinel: &str) {
        let want = sentinel.to_owned();
        self.next(
            "the sentinel",
            move |m| matches!(m, ServerMsg::Error { message } if *message == want),
        )
        .await;
    }

    /// Everything this connection has received so far.
    fn all(&mut self) -> &[ServerMsg] {
        self.pump();
        &self.seen
    }

    fn saw(&mut self, pred: impl Fn(&ServerMsg) -> bool) -> bool {
        self.all().iter().any(pred)
    }

    fn snapshot_on_connect(&self) -> Option<Vec<ApprovalRequestWire>> {
        self.connect_frames.iter().find_map(|m| match m {
            ServerMsg::ApprovalsSnapshot { requests } => Some(requests.clone()),
            _ => None,
        })
    }

    /// The `approval_answer` this connection sends (echoing its own nonce).
    async fn answer(&mut self, request_id: &str, decision: ApprovalDecision, window: &str) {
        let msg = approval_answer(request_id, decision, window, self.nonce.as_deref());
        self.send(&msg).await;
    }

    async fn allow(&mut self, request_id: &str, window: &str) {
        self.answer(request_id, allow_once(), window).await;
    }

    async fn deny(&mut self, request_id: &str, window: &str) {
        self.answer(request_id, deny(None), window).await;
    }
}

fn approval_answer(
    request_id: &str,
    decision: ApprovalDecision,
    window: &str,
    nonce: Option<&str>,
) -> ClientMsg {
    ClientMsg::ApprovalAnswer {
        request_id: request_id.into(),
        decision,
        window_id: window.into(),
        operator_nonce: nonce.map(str::to_owned),
    }
}

fn allow_once() -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AllowOnce,
        note: None,
        answers: None,
    }
}

fn deny(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::Deny,
        note: note.map(str::to_owned),
        answers: None,
    }
}

fn deny_and_stop(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::DenyAndStop,
        note: note.map(str::to_owned),
        answers: None,
    }
}

// ── predicates over frames ────────────────────────────────────────────────────

fn is_request(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalRequest { .. })
}

fn is_snapshot(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalsSnapshot { .. })
}

fn is_resolved(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalResolved { .. })
}

fn is_guard_blocked(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalGuardBlocked { .. })
}

fn is_answer_refused(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalAnswerRefused { .. })
}

fn is_pending(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalPending { .. })
}

fn is_secure_connection_refusal(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
}

/// Frames that carry (or can carry) what an agent asked to run: never for a TCP peer.
fn carries_content(m: &ServerMsg) -> bool {
    is_request(m)
        || is_snapshot(m)
        || is_resolved(m)
        || is_guard_blocked(m)
        || is_answer_refused(m)
        || matches!(m, ServerMsg::SessionPermissionRequest { .. })
}

fn pending_counts(frames: &[ServerMsg], tag: &str) -> Vec<u32> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::ApprovalPending { tag: t, count } if t == tag => Some(*count),
            _ => None,
        })
        .collect()
}

// ── what the fake CLI saw ─────────────────────────────────────────────────────

struct Fake {
    dir: PathBuf,
    work: PathBuf,
}

impl Fake {
    fn read_lines(&self, file: &str) -> Vec<Value> {
        std::fs::read_to_string(self.dir.join(file))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{file}: {e}: {l}")))
            .collect()
    }

    /// Every answer the fake received, as `{request_id, tool_use_id, response: <frame>}`.
    fn responses(&self) -> Vec<Value> {
        self.read_lines("responses.jsonl")
    }

    /// Every line the daemon wrote to the fake's stdin.
    fn stdin(&self) -> Vec<Value> {
        self.read_lines("stdin.jsonl")
    }

    fn raw_stdin(&self) -> String {
        std::fs::read_to_string(self.dir.join("stdin.jsonl")).unwrap_or_default()
    }

    async fn wait_responses(&self, n: usize) -> Vec<Value> {
        wait_until(&format!("{n} answer(s) to reach the fake"), || {
            let r = self.responses();
            (r.len() >= n).then_some(r)
        })
        .await
    }

    /// The only thing the daemon ever wrote to the CLI is the user's own message(s).
    #[track_caller]
    fn assert_no_control_responses(&self) {
        let stdin = self.stdin();
        assert!(
            stdin.iter().all(|f| f["type"] == "user"),
            "nothing but user messages may have been written to the CLI: {stdin:?}"
        );
        assert!(self.responses().is_empty(), "{:?}", self.responses());
    }

    /// T-AP0b-3: nothing the daemon wrote to the CLI is an allow.
    #[track_caller]
    fn assert_never_allowed(&self) {
        let raw = self.raw_stdin();
        assert!(
            !raw.contains("\"behavior\":\"allow\"") && !raw.contains("\"behavior\": \"allow\""),
            "{raw}"
        );
        for line in self.responses() {
            let body = &line["response"]["response"]["response"];
            assert_ne!(body["behavior"], "allow", "{line}");
            assert!(body.get("updatedInput").is_none(), "{line}");
        }
    }
}

/// The frame the CLI receives to be told no, with `message`.
fn deny_frame(cli_request_id: &str, message: &str) -> Value {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": cli_request_id,
            "response": { "behavior": "deny", "message": message }
        }
    })
}

fn cli_request_id(line: &Value) -> &str {
    line["request_id"]
        .as_str()
        .expect("the fake records which request an answer was for")
}

fn entry_peer(e: &Entry) -> Value {
    match &e.event {
        Event::Refusal { peer, .. } => peer.clone().expect("a refusal names the peer"),
        other => panic!("not a refusal: {other:?}"),
    }
}

fn refusal_code(e: &Entry) -> &str {
    match &e.event {
        Event::Refusal { refusal_code, .. } => refusal_code,
        other => panic!("not a refusal: {other:?}"),
    }
}

fn outcome_name(e: &Entry) -> &str {
    match &e.event {
        Event::Outcome { outcome, .. } => outcome,
        other => panic!("not an outcome: {other:?}"),
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// 1. The verified Mac app (renders_approvals: true): the positive controls
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn protocol_version_is_unchanged_at_4() {
    assert_eq!(
        PROTOCOL_VERSION, 4,
        "approvals are additive: an old Mac keeps working"
    );
}

#[test]
fn welcome_announces_approvals_v1_to_every_kind_of_peer_and_a_nonce_only_to_the_app() {
    run(GUARDED, |rig| async move {
        let app = rig.app(true).await;
        let agent = rig.agent(vec![]).await;
        let tcp = rig.tcp(vec![]).await;

        for (who, conn) in [("app", &app), ("agent", &agent), ("tcp", &tcp)] {
            assert!(
                conn.features.iter().any(|f| f == "approvals_v1"),
                "{who}: {:?}",
                conn.features
            );
        }
        assert!(
            app.nonce.is_some(),
            "the verified app's Welcome carries the nonce its answers must echo"
        );
        assert!(agent.nonce.is_none() && tcp.nonce.is_none());
    });
}

#[test]
fn a_request_from_a_guarded_session_is_held_and_shown_to_the_app_with_a_pending_count() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        assert_eq!(
            app.snapshot_on_connect(),
            Some(vec![]),
            "a new presenter is sent a snapshot: nothing held yet"
        );

        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        assert_eq!(wire.tag, "cody-1");
        assert_eq!(wire.tool_use_id, "toolu_simple_rm_0");
        assert_eq!(wire.tool_name, "Bash");
        assert_eq!(
            wire.input,
            fixture("simple_rm")["requests"][0]["request"]["input"]
        );
        assert_eq!(wire.cwd.as_deref(), Some(fake.work.to_str().unwrap()));
        assert_eq!(wire.deadline_at_ms - wire.created_at_ms, 15 * 60 * 1000);
        app.wait_pending("cody-1", 1).await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot(), vec![wire], "the broker holds it");
    });
}

#[test]
fn a_presenter_that_connects_later_is_sent_the_held_requests_in_its_snapshot() {
    run(GUARDED, |mut rig| async move {
        let mut first = rig.app(true).await;
        let (_fake, wire) = rig.held(&mut first, "cody-1", "FIXTURE:simple_rm").await;

        let second = rig.app(true).await;

        assert_eq!(second.snapshot_on_connect(), Some(vec![wire]));
    });
}

#[test]
fn a_connection_that_resubscribes_with_renders_approvals_becomes_a_presenter() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(false).await;
        // Not rendering yet: the request is denied at once.
        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        fake.wait_responses(1).await;
        assert!(!app.saw(is_request));

        app.send(&ClientMsg::Subscribe {
            topics: vec![Topic::Decision],
            renders_decisions: false,
            renders_approvals: true,
            capabilities: vec![],
            operator_nonce: None,
        })
        .await;
        let snapshot = app.next("the snapshot", is_snapshot).await;
        assert!(
            matches!(snapshot, ServerMsg::ApprovalsSnapshot { ref requests } if requests.is_empty())
        );
        rig.say("cody-1", "FIXTURE:cancel");

        let wire = app.next_request().await;
        assert_eq!(wire.tool_use_id, "toolu_cancel_0");
        assert!(rig.broker.has_approval_presenter());
    });
}

#[test]
fn the_agent_is_told_exactly_what_the_human_decided() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let fake = rig.spawn("cody-1");
        let input = fixture("simple_rm")["requests"][0]["request"]["input"].clone();
        // (decision, window, the body the CLI must receive, the outcome the log must record)
        let long_note = "n".repeat(600);
        let cases: Vec<(ApprovalDecision, &str, Value, &str)> = vec![
            (
                allow_once(),
                "win-allow",
                json!({ "behavior": "allow", "updatedInput": input }),
                "allowed_once",
            ),
            (
                deny(None),
                "win-deny",
                json!({ "behavior": "deny", "message": "The user denied this in Nostromo." }),
                "denied",
            ),
            (
                deny(Some("use /tmp/y instead")),
                "win-note",
                json!({ "behavior": "deny", "message": "The user denied this in Nostromo.\n\nUser's note: use /tmp/y instead" }),
                "denied",
            ),
            (
                deny(Some("a\u{200B}b\u{202E}c\nd")),
                "win-clean",
                json!({ "behavior": "deny", "message": "The user denied this in Nostromo.\n\nUser's note: abc d" }),
                "denied",
            ),
            (
                deny(Some(&long_note)),
                "win-long",
                json!({ "behavior": "deny", "message": format!("The user denied this in Nostromo.\n\nUser's note: {}", "n".repeat(500)) }),
                "denied",
            ),
            (
                deny_and_stop(None),
                "win-stop",
                json!({ "behavior": "deny", "message": "The user denied this in Nostromo.", "interrupt": true }),
                "denied_and_stopped",
            ),
            (
                deny_and_stop(Some("stop it")),
                "win-stop-note",
                json!({ "behavior": "deny", "message": "The user denied this in Nostromo.\n\nUser's note: stop it", "interrupt": true }),
                "denied_and_stopped",
            ),
        ];

        for (i, (decision, window, body, outcome)) in cases.into_iter().enumerate() {
            rig.say("cody-1", "FIXTURE:simple_rm");
            let wire = app.next_request().await;

            app.answer(&wire.request_id, decision, window).await;

            let responses = fake.wait_responses(i + 1).await;
            let line = &responses[i];
            assert_eq!(
                line["response"],
                json!({
                    "type": "control_response",
                    "response": { "subtype": "success", "request_id": cli_request_id(line), "response": body }
                }),
                "{window}: the frame the CLI receives, in the control_response wrapper"
            );
            assert_eq!(
                app.next_resolved().await,
                (
                    wire.request_id.clone(),
                    outcome.to_owned(),
                    Some(window.to_owned())
                )
            );
            let logged = wait_until("the outcome entry", || {
                rig.outcomes()
                    .into_iter()
                    .find(|e| e.request_id.as_deref() == Some(wire.request_id.as_str()))
            })
            .await;
            let Event::Outcome {
                outcome: name,
                by_window,
                latency_ms,
                ..
            } = &logged.event
            else {
                unreachable!()
            };
            assert_eq!(
                (name.as_str(), by_window.as_deref()),
                (outcome, Some(window))
            );
            assert!(
                latency_ms.is_some(),
                "{window}: the log records how long the human took"
            );
        }
    });
}

#[test]
fn allow_once_sends_back_the_input_exactly_as_the_cli_sent_it_even_when_it_is_odd() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let fake = rig.spawn("cody-1");
        let mut expected = Vec::new();
        for name in ["bidi", "cyrillic", "zero_width", "all_fields", "edit"] {
            expected.push(fixture(name)["requests"][0]["request"]["input"].clone());
            rig.say("cody-1", &format!("FIXTURE:{name}"));
            let wire = app.next_request().await;
            app.allow(&wire.request_id, "w").await;
            fake.wait_responses(expected.len()).await;
        }

        let responses = fake.responses();
        for (line, input) in responses.iter().zip(&expected) {
            assert_eq!(
                line["response"]["response"]["response"],
                json!({ "behavior": "allow", "updatedInput": input }),
                "the input goes back unchanged"
            );
        }
    });
}

/// T-AP0b-2: what the card is shown is the CLI's input, as a JSON value, for every fixture.
#[test]
fn the_held_requests_input_equals_the_clis_input_for_every_fixture() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let fake = rig.spawn("cody-1");
        let mut names: Vec<String> = std::fs::read_dir(fixtures_dir())
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "json"))
            .map(|p| p.file_stem().unwrap().to_string_lossy().into_owned())
            // Not a held can_use_tool request: a request with no tool_use_id and a string input
            // (unreadable), another control_request subtype, and the guard's fixtures (denied).
            .filter(|n| n != "malformed" && n != "non_can_use_tool" && !n.starts_with("guard_"))
            .collect();
        names.sort();
        assert!(names.len() >= 20, "the fixture set is found: {names:?}");

        let mut answered = 0;
        for name in &names {
            let requests: Vec<Value> = fixture(name)["requests"]
                .as_array()
                .unwrap()
                .iter()
                .map(|r| r["request"].clone())
                .collect();
            for r in &requests {
                assert_eq!(
                    r["subtype"], "can_use_tool",
                    "{name} is a can_use_tool fixture"
                );
            }
            rig.say("cody-1", &format!("FIXTURE:{name}"));
            for _ in &requests {
                let wire = app.next_request().await;
                let sent = requests
                    .iter()
                    .find(|r| r["tool_use_id"] == wire.tool_use_id.as_str())
                    .unwrap_or_else(|| {
                        panic!(
                            "{name}: a request for an unknown tool use {}",
                            wire.tool_use_id
                        )
                    });
                assert_eq!(
                    wire.input, sent["input"],
                    "{name}: the card must show exactly what the CLI asked for (tool use {})",
                    wire.tool_use_id
                );
                // And as it went over the wire, not only in memory.
                let on_wire = app.request_frame(&wire.request_id);
                assert_eq!(on_wire["request"]["input"], sent["input"], "{name}");
                app.deny(&wire.request_id, "w").await;
                answered += 1;
            }
            fake.wait_responses(answered).await;
        }
        fake.assert_never_allowed();
    });
}

#[test]
fn two_windows_answer_one_request_and_only_the_first_reaches_the_agent() {
    run(GUARDED, |mut rig| async move {
        let mut a = rig.app(true).await;
        let mut b = rig.app(true).await;
        let (fake, wire) = rig.held(&mut a, "cody-1", "FIXTURE:simple_rm").await;
        assert_eq!(
            b.next_request().await.request_id,
            wire.request_id,
            "both windows are shown it"
        );
        let before = tokio::time::Instant::now();

        a.allow(&wire.request_id, "win-a").await;
        fake.wait_responses(1).await;
        b.deny(&wire.request_id, "win-b").await;

        let (id, code, outcome) = b.next_refused().await;
        assert_eq!(
            (id.as_str(), code, outcome.as_deref()),
            (
                wire.request_id.as_str(),
                AnswerRefusal::AlreadyResolved,
                Some("allowed_once")
            )
        );
        for window in [&mut a, &mut b] {
            assert_eq!(
                window.next_resolved().await,
                (
                    wire.request_id.clone(),
                    "allowed_once".to_owned(),
                    Some("win-a".to_owned())
                ),
                "every window is told, and who answered"
            );
        }
        settle().await;
        let responses = fake.responses();
        assert_eq!(
            responses.len(),
            1,
            "the CLI receives exactly one response: {responses:?}"
        );
        assert_eq!(
            responses[0]["response"]["response"]["response"]["behavior"],
            "allow"
        );
        assert_eq!(
            tokio::time::Instant::now(),
            before,
            "no clock advance was needed"
        );
        assert!(!a.saw(is_answer_refused), "the winner is not refused");
    });
}

#[test]
fn two_windows_answering_at_the_same_moment_still_produce_exactly_one_response() {
    run(GUARDED, |mut rig| async move {
        let mut a = rig.app(true).await;
        let mut b = rig.app(true).await;
        let (fake, wire) = rig.held(&mut a, "cody-1", "FIXTURE:simple_rm").await;
        b.next_request().await;

        a.allow(&wire.request_id, "win-a").await;
        b.deny(&wire.request_id, "win-b").await;

        let (_, outcome_a, by_a) = a.next_resolved().await;
        let (_, outcome_b, by_b) = b.next_resolved().await;
        assert_eq!(
            (&outcome_a, &by_a),
            (&outcome_b, &by_b),
            "both windows hear the same verdict"
        );
        fake.wait_responses(1).await;
        settle().await;
        let responses = fake.responses();
        assert_eq!(responses.len(), 1, "{responses:?}");
        let behavior = responses[0]["response"]["response"]["response"]["behavior"].clone();
        let (winner, loser) = if by_a.as_deref() == Some("win-a") {
            (&mut a, &mut b)
        } else {
            (&mut b, &mut a)
        };
        assert_eq!(
            behavior,
            if outcome_a == "allowed_once" {
                "allow"
            } else {
                "deny"
            }
        );
        let (_, code, told) = loser.next_refused().await;
        assert_eq!(
            (code, told.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some(outcome_a.as_str()))
        );
        assert!(!winner.saw(is_answer_refused));
    });
}

#[test]
fn an_unanswered_request_is_denied_at_fifteen_minutes_not_at_fourteen_fifty_nine() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        settle().await;

        tokio::time::advance(Duration::from_secs(14 * 60 + 59)).await;
        settle().await;
        fake.assert_no_control_responses();
        assert!(!app.saw(is_resolved), "nothing at 14:59");

        tokio::time::advance(Duration::from_secs(1)).await;
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), TIMED_OUT_MESSAGE)
        );
        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "timed_out".to_owned(), None)
        );
        let outcome = rig.wait_outcome("toolu_simple_rm_0").await;
        assert_eq!(outcome_name(&outcome), "timed_out");

        // A late answer is told what happened, and changes nothing.
        app.allow(&wire.request_id, "late").await;
        let (id, code, told) = app.next_refused().await;
        assert_eq!(
            (id.as_str(), code, told.as_deref()),
            (
                wire.request_id.as_str(),
                AnswerRefusal::AlreadyResolved,
                Some("timed_out")
            )
        );
        settle().await;
        assert_eq!(
            fake.responses().len(),
            1,
            "the late allow produced no second response"
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn when_the_app_disconnects_its_pending_request_is_denied_no_app_after_the_grace_and_not_before() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, _wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        settle().await;

        drop(app);
        wait_until("the daemon to notice the app is gone", || {
            (!rig.broker.has_approval_presenter()).then_some(())
        })
        .await;
        settle().await;
        tokio::time::advance(Duration::from_millis(2900)).await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(
            rig.broker.snapshot().len(),
            1,
            "still pending inside the 3 s grace"
        );

        tokio::time::advance(Duration::from_millis(200)).await;
        let responses = fake.wait_responses(1).await;

        assert!(PRESENTER_GRACE < Duration::from_secs(5));
        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), NO_APP_MESSAGE)
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "no_app"
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn an_app_that_reconnects_within_three_seconds_keeps_the_request_pending_and_gets_it_in_its_snapshot(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        settle().await;
        drop(app);
        wait_until("the daemon to notice the app is gone", || {
            (!rig.broker.has_approval_presenter()).then_some(())
        })
        .await;
        settle().await;
        tokio::time::advance(Duration::from_secs(2)).await;
        settle().await;

        let mut again = rig.app(true).await;

        assert_eq!(
            again.snapshot_on_connect(),
            Some(vec![wire.clone()]),
            "the snapshot redelivers the pending request"
        );
        tokio::time::advance(Duration::from_secs(10)).await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1, "the reconnect kept it");
        again.allow(&wire.request_id, "win-2").await;
        let responses = fake.wait_responses(1).await;
        assert_eq!(
            responses[0]["response"]["response"]["response"]["behavior"],
            "allow"
        );
    });
}

#[test]
fn with_no_app_connected_a_new_request_is_denied_no_app_at_once_whatever_else_is_connected() {
    run(GUARDED, |mut rig| async move {
        // Everything but the app: an agent that claims to be it, and a LAN peer.
        let mut agent = rig.agent(vec![]).await;
        let mut tcp = rig.tcp(vec![]).await;
        let before = tokio::time::Instant::now();

        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), NO_APP_MESSAGE)
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "no_app"
        );
        assert_eq!(
            tokio::time::Instant::now(),
            before,
            "denied at once: no clock advance"
        );
        assert!(rig.broker.snapshot().is_empty());
        let s = rig.sentinel();
        agent.through(&s).await;
        tcp.through(&s).await;
        assert!(!agent.saw(carries_content) && !tcp.saw(carries_content));
        fake.assert_never_allowed();
    });
}

#[test]
fn an_app_that_does_not_render_approvals_is_told_approval_unavailable_at_once_and_nothing_is_held()
{
    // The real Mac app today: verified, connected, `renders_approvals: false`.
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(false).await;
        let before = tokio::time::Instant::now();

        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), APPROVAL_UNAVAILABLE_MESSAGE)
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "approval_unavailable"
        );
        assert_eq!(tokio::time::Instant::now(), before, "no clock advance");
        assert!(rig.broker.snapshot().is_empty(), "nothing held");
        let s = rig.sentinel();
        app.through(&s).await;
        assert!(
            !app.saw(is_request) && !app.saw(is_pending) && !app.saw(is_snapshot),
            "{:?}",
            app.all()
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn a_verified_app_that_omits_the_renders_approvals_key_is_never_a_presenter() {
    // An old Mac: its Subscribe has no `renders_approvals` at all.
    run(GUARDED, |mut rig| async move {
        let mut old_mac = rig
            .app_subscribing(json!({ "type": "subscribe", "topics": ["decision"] }))
            .await;
        assert!(!rig.broker.has_approval_presenter());
        assert_eq!(
            old_mac.snapshot_on_connect(),
            None,
            "no snapshot for a connection that never claimed to render approvals"
        );

        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), APPROVAL_UNAVAILABLE_MESSAGE)
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "approval_unavailable"
        );
        let s = rig.sentinel();
        old_mac.through(&s).await;
        assert!(
            !old_mac.saw(is_request),
            "an old Mac is never shown a card it cannot answer"
        );
    });
}

#[test]
fn stopping_a_session_with_a_held_request_cancels_it_and_nothing_more_is_written_to_the_cli() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        app.wait_pending("cody-1", 1).await;

        app.send(&ClientMsg::SessionControl {
            tag: "cody-1".into(),
            action: SessionAction::Stop,
        })
        .await;

        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "cancelled".to_owned(), None)
        );
        app.wait_pending("cody-1", 0).await;
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "cancelled"
        );
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(
            fake.stdin().len(),
            1,
            "the user's message is the only thing the CLI was ever sent"
        );
        assert!(rig.broker.snapshot().is_empty());
    });
}

#[test]
fn a_new_session_clear_context_with_a_held_request_cancels_it_and_nothing_more_is_written_to_the_cli(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        app.send(&ClientMsg::SessionControl {
            tag: "cody-1".into(),
            action: SessionAction::NewSession,
        })
        .await;

        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "cancelled".to_owned(), None)
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "cancelled"
        );
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(fake.stdin().len(), 1);
        // The cards are gone: a late answer is told so.
        app.allow(&wire.request_id, "late").await;
        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("cancelled"))
        );
    });
}

#[test]
fn a_held_request_the_cli_withdraws_is_resolved_withdrawn_and_nothing_is_written_for_it() {
    // Interrupting the agent makes the CLI withdraw its pending request (spike F6): the card must go.
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        app.wait_pending("cody-1", 1).await;

        app.send(&ClientMsg::SessionInterrupt {
            tag: "cody-1".into(),
        })
        .await;

        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "withdrawn".to_owned(), None)
        );
        app.wait_pending("cody-1", 0).await;
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "withdrawn"
        );
        settle().await;
        assert!(
            fake.responses().is_empty(),
            "nothing is answered for a request the CLI no longer waits on"
        );
        fake.assert_never_allowed();
        assert!(rig.broker.snapshot().is_empty());
    });
}

#[test]
fn approvals_hold_only_with_guard_hook() {
    // The ordering rule: a session started without the guard hook is never asked about, even
    // with a presenter connected. Its request ends `no_app` and no card is shown.
    run(Opts { guard_hook: false }, |mut rig| async move {
        let mut app = rig.app(true).await;
        assert!(rig.broker.has_approval_presenter());

        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1).await;

        let argv: Vec<String> =
            serde_json::from_str(&std::fs::read_to_string(fake.dir.join("argv.json")).unwrap())
                .unwrap();
        let expected_hook = hook_settings_json(rig.session_mgr.lock().unwrap().guard_path());
        assert!(
            !argv.contains(&expected_hook),
            "the session really started without the hook: {argv:?}"
        );
        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), APPROVAL_UNAVAILABLE_MESSAGE),
            "an app is connected, so the agent is not told it is closed"
        );
        assert_eq!(
            outcome_name(&rig.wait_outcome("toolu_simple_rm_0").await),
            "no_app"
        );
        assert!(rig.broker.snapshot().is_empty());
        let s = rig.sentinel();
        app.through(&s).await;
        assert!(
            !app.saw(is_request),
            "nothing was broadcast as an approval_request"
        );
        assert!(
            !app.saw(is_pending),
            "no count for a request that was never held"
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn a_guard_blocked_request_is_denied_and_the_app_gets_a_summary_of_the_tool_and_first_word_only() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        // Both are blocked by the guard before anyone could be asked.
        for (tag, cue, tool_use_id, summary, command_tail) in [
            (
                "cody-ecs",
                "FIXTURE:guard_ecs_connect",
                "toolu_guard_ecs_connect_0",
                "Bash ecs_connect",
                "production portal web",
            ),
            (
                "cody-tmux",
                "FIXTURE:guard_send_keys",
                "toolu_guard_send_keys_0",
                "Bash tmux",
                "send-keys",
            ),
        ] {
            let fake = rig.spawn(tag);
            rig.say(tag, cue);

            let responses = fake.wait_responses(1).await;

            assert_eq!(
                responses[0]["response"],
                deny_frame(cli_request_id(&responses[0]), GUARD_MESSAGE),
                "{tag}"
            );
            let ServerMsg::ApprovalGuardBlocked {
                tag: t,
                tool_use_id: tu,
                entry_id,
                at_ms,
                summary: s,
            } = app.nth("approval_guard_blocked", is_guard_blocked).await
            else {
                unreachable!()
            };
            assert_eq!((t.as_str(), tu.as_str()), (tag, tool_use_id));
            assert_eq!(
                s, summary,
                "the tool name and the first command word, never more"
            );
            assert!(!s.contains(command_tail));
            assert!(at_ms > 0);
            let outcome = rig.wait_outcome(tool_use_id).await;
            assert_eq!(outcome_name(&outcome), "guard_blocked");
            assert_eq!(
                outcome.id, entry_id,
                "the frame points at the audit entry that records the full command"
            );
            fake.assert_never_allowed();
        }
        let s = rig.sentinel();
        app.through(&s).await;
        assert!(
            !app.saw(is_request),
            "a blocked request is never offered to the human"
        );
    });
}

#[test]
fn refusal_reports_from_the_app_are_written_to_the_audit_log_with_their_channel_and_control() {
    run(GUARDED, |rig| async move {
        let mut app = rig.app(true).await;

        for (channel, control, request_id) in [
            (RefusalChannel::AppControl, "allow_once", Some("req-1")),
            (RefusalChannel::Accessibility, "deny", None),
            (RefusalChannel::Unknown, "deny_and_stop", Some("req-3")),
        ] {
            app.send(&ClientMsg::ApprovalRefusalReport {
                request_id: request_id.map(str::to_owned),
                control: control.into(),
                channel,
            })
            .await;
        }

        let refusals = rig.wait_refusals(3).await;
        // "code | channel | control | request id" for each entry, in a fixed order.
        let mut seen: Vec<String> = refusals
            .iter()
            .map(|e| {
                let Event::Refusal {
                    refusal_code,
                    channel,
                    control,
                    ..
                } = &e.event
                else {
                    unreachable!()
                };
                format!(
                    "{refusal_code} | {channel:?} | {control:?} | {:?}",
                    e.request_id
                )
            })
            .collect();
        seen.sort();
        let mut expected = vec![
            r#"synthetic_input_refused | Some("app_control") | Some("allow_once") | Some("req-1")"#
                .to_owned(),
            r#"synthetic_input_refused | Some("accessibility") | Some("deny") | None"#.to_owned(),
            r#"synthetic_input_refused | Some("unknown") | Some("deny_and_stop") | Some("req-3")"#
                .to_owned(),
        ];
        expected.sort();
        assert_eq!(seen, expected);
        for e in &refusals {
            assert_eq!(entry_peer(e)["trust"], "operator_app");
        }
    });
}

#[test]
fn session_answer_permission_is_superseded_for_the_app_and_does_nothing() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        app.send(&ClientMsg::SessionAnswerPermission {
            tag: "cody-1".into(),
            request_id: wire.request_id.clone(),
            decision: PermissionDecision::Allow,
        })
        .await;

        let err = app
            .next("the superseded error", |m| {
                matches!(m, ServerMsg::Error { .. })
            })
            .await;
        assert!(
            matches!(err, ServerMsg::Error { ref message } if message == "session_answer_permission is superseded by approval_answer"),
            "{err:?}"
        );
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(
            rig.broker.snapshot().len(),
            1,
            "no side effect: the request is still pending"
        );
        assert!(!app.saw(is_resolved));
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// 2. A Unix "agent" (LocalOther): an agent's own process on the daemon's socket
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_local_process_that_is_not_the_app_is_never_shown_a_request_though_it_claims_to_render_approvals(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        // Claims `mac_app` and `renders_approvals`; the process behind it is a script.
        let mut every_topic = rig.agent(vec![]).await;
        let mut decisions = rig.agent(vec![Topic::Decision]).await;
        let mut layout = rig.agent(vec![Topic::Layout]).await;
        assert_eq!(
            every_topic.nonce, None,
            "only the verified app is issued a nonce"
        );

        let (_fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        app.deny(&wire.request_id, "w").await;
        app.next_resolved().await;
        app.wait_pending("cody-1", 0).await;
        let s = rig.sentinel();

        for (who, c) in [
            ("topics []", &mut every_topic),
            ("topics [decision]", &mut decisions),
            ("topics [layout]", &mut layout),
        ] {
            c.through(&s).await;
            assert!(
                !c.saw(carries_content),
                "{who}: a non-app local process never gets a frame that carries a command: {:?}",
                c.all()
            );
            assert_eq!(c.snapshot_on_connect(), None, "{who}: and no snapshot");
        }
        // The count, though, goes to anyone who follows decisions, an everything-subscriber included.
        assert_eq!(pending_counts(every_topic.all(), "cody-1"), [1, 0]);
        assert_eq!(pending_counts(decisions.all(), "cody-1"), [1, 0]);
        assert!(
            pending_counts(layout.all(), "cody-1").is_empty(),
            "a subscriber that does not follow decisions gets no count"
        );
    });
}

#[test]
fn only_operator_app_answers_a_local_process_that_is_not_the_app_is_refused_not_operator_app() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![Topic::Decision]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        let app_nonce = app.nonce.clone().expect("the app has a nonce");

        // No nonce, and then even the app's own nonce (say it was read out of the app's memory).
        agent
            .send(&approval_answer(
                &wire.request_id,
                allow_once(),
                "evil",
                None,
            ))
            .await;
        agent
            .send(&approval_answer(
                &wire.request_id,
                allow_once(),
                "evil",
                Some(&app_nonce),
            ))
            .await;

        for _ in 0..2 {
            let (id, code, outcome) = agent.next_refused().await;
            assert_eq!(
                (id.as_str(), code, outcome),
                (
                    wire.request_id.as_str(),
                    AnswerRefusal::NotOperatorApp,
                    None
                )
            );
        }
        let refusals = rig.wait_refusals(2).await;
        for e in &refusals {
            assert_eq!(refusal_code(e), "not_operator_app");
            assert_eq!(e.request_id.as_deref(), Some(wire.request_id.as_str()));
            let peer = entry_peer(e);
            assert_eq!(peer["trust"], "local_other");
            assert_eq!(
                peer["pid"], 4343,
                "the log names the process that tried: {peer}"
            );
            assert_eq!(peer["exe"], "/usr/bin/python3");
        }
        // Nothing changed.
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1, "the request stays pending");
        app.sync().await;
        assert!(!app.saw(is_resolved));
        // The app then answers, and that answer is the one the CLI gets.
        app.allow(&wire.request_id, "win-1").await;
        let responses = fake.wait_responses(1).await;
        assert_eq!(responses.len(), 1);
        assert_eq!(
            responses[0]["response"]["response"]["response"]["behavior"],
            "allow"
        );
    });
}

#[test]
fn only_operator_app_answers_even_the_app_is_refused_with_no_nonce_or_the_wrong_one() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        app.send(&approval_answer(&wire.request_id, allow_once(), "w", None))
            .await;
        app.send(&approval_answer(
            &wire.request_id,
            allow_once(),
            "w",
            Some("not-the-nonce"),
        ))
        .await;
        app.send(&approval_answer(
            &wire.request_id,
            allow_once(),
            "w",
            Some(""),
        ))
        .await;

        for _ in 0..3 {
            let (_, code, outcome) = app.next_refused().await;
            assert_eq!((code, outcome), (AnswerRefusal::NotOperatorApp, None));
        }
        let refusals = rig.wait_refusals(3).await;
        assert!(refusals
            .iter()
            .all(|e| refusal_code(e) == "not_operator_app"
                && entry_peer(e)["trust"] == "operator_app"));
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
        assert!(!app.saw(is_resolved));

        app.deny(&wire.request_id, "w").await;
        fake.wait_responses(1).await;
    });
}

#[test]
fn an_answer_for_an_unknown_request_is_refused_unknown_request_and_logged() {
    run(GUARDED, |rig| async move {
        let mut app = rig.app(true).await;

        app.allow("no-such-request", "w").await;

        let (id, code, outcome) = app.next_refused().await;
        assert_eq!(
            (id.as_str(), code, outcome),
            ("no-such-request", AnswerRefusal::UnknownRequest, None)
        );
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusal_code(&refusals[0]), "unknown_request");
        assert_eq!(refusals[0].request_id.as_deref(), Some("no-such-request"));
        assert_eq!(entry_peer(&refusals[0])["trust"], "operator_app");
    });
}

#[test]
fn a_late_answer_is_refused_already_resolved_and_logged() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        app.deny(&wire.request_id, "w1").await;
        fake.wait_responses(1).await;
        app.next_resolved().await;

        app.allow(&wire.request_id, "w2").await;

        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("denied"))
        );
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusal_code(&refusals[0]), "already_resolved");
        settle().await;
        assert_eq!(fake.responses().len(), 1);
        fake.assert_never_allowed();
    });
}

/// T-AP0b-3: no allow is ever produced except `allow_once` from an operator-app connection.
#[test]
fn no_allow_is_ever_produced_except_allow_once_from_the_operator_app() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![Topic::Decision]).await;
        let mut tcp = rig.tcp(vec![]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        let app_nonce = app.nonce.clone().unwrap();

        // 1. a LocalOther allow, 2. a TCP allow, 3. the app's allow with a wrong nonce,
        // 4. an allow for an unknown id from the app itself.
        agent
            .send(&approval_answer(
                &wire.request_id,
                allow_once(),
                "w",
                Some(&app_nonce),
            ))
            .await;
        tcp.send(&approval_answer(
            &wire.request_id,
            allow_once(),
            "w",
            Some(&app_nonce),
        ))
        .await;
        app.send(&approval_answer(
            &wire.request_id,
            allow_once(),
            "w",
            Some("wrong"),
        ))
        .await;
        app.allow("not-a-real-id", "w").await;
        assert_eq!(agent.next_refused().await.1, AnswerRefusal::NotOperatorApp);
        tcp.next("a refusal", is_secure_connection_refusal).await;
        assert_eq!(app.next_refused().await.1, AnswerRefusal::NotOperatorApp);
        let (id, code, _) = app.next_refused().await;
        assert_eq!(
            (id.as_str(), code),
            ("not-a-real-id", AnswerRefusal::UnknownRequest)
        );
        settle().await;
        assert!(
            fake.responses().is_empty(),
            "no refused allow reached the CLI"
        );
        assert_eq!(
            rig.broker.snapshot().len(),
            1,
            "and the request is still pending"
        );

        // 5. The real answer is a deny; 6. an allow that comes after it is late.
        app.deny(&wire.request_id, "w").await;
        fake.wait_responses(1).await;
        app.next_resolved().await;
        app.allow(&wire.request_id, "w").await;
        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("denied"))
        );
        settle().await;

        assert_eq!(fake.responses().len(), 1);
        fake.assert_never_allowed();
        assert_eq!(
            rig.wait_refusals(5).await.len(),
            5,
            "every one of the five refusals was logged"
        );
    });
}

#[test]
fn a_refusal_report_from_a_local_process_that_is_not_the_app_is_dropped() {
    run(GUARDED, |rig| async move {
        let mut agent = rig.agent(vec![]).await;
        let mut app = rig.app(true).await;

        agent
            .send(&ClientMsg::ApprovalRefusalReport {
                request_id: Some("forged".into()),
                control: "allow_once".into(),
                channel: RefusalChannel::AppControl,
            })
            .await;
        agent.sync().await;
        // The app's own report, sent after: once it is logged, the forged one has had its chance.
        app.send(&ClientMsg::ApprovalRefusalReport {
            request_id: Some("real".into()),
            control: "deny".into(),
            channel: RefusalChannel::Accessibility,
        })
        .await;
        let refusals = rig.wait_refusals(1).await;
        settle().await;

        let all = rig.refusals();
        assert_eq!(all.len(), 1, "only the app's report is written: {all:?}");
        assert_eq!(refusals[0].request_id.as_deref(), Some("real"));
        assert_eq!(entry_peer(&refusals[0])["trust"], "operator_app");
    });
}

#[test]
fn session_answer_permission_from_a_local_process_that_is_not_the_app_is_superseded_and_does_nothing(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        agent
            .send(&ClientMsg::SessionAnswerPermission {
                tag: "cody-1".into(),
                request_id: wire.request_id.clone(),
                decision: PermissionDecision::Allow,
            })
            .await;

        let err = agent
            .next("an error", |m| matches!(m, ServerMsg::Error { .. }))
            .await;
        assert!(
            matches!(err, ServerMsg::Error { ref message } if message == "session_answer_permission is superseded by approval_answer"),
            "{err:?}"
        );
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
    });
}

#[test]
fn a_guard_block_is_never_shown_to_a_local_process_that_is_not_the_app() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![]).await;
        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:guard_ecs_connect");
        app.nth("approval_guard_blocked", is_guard_blocked).await;
        fake.wait_responses(1).await;
        let s = rig.sentinel();

        agent.through(&s).await;

        assert!(!agent.saw(is_guard_blocked), "{:?}", agent.all());
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// 3. Raw TCP (a LAN peer)
// ═════════════════════════════════════════════════════════════════════════════

/// PRD criterion 7. The app connection holds two requests (one for a non-sensitive focus, one for
/// a sensitive one); a TCP client with `topics: []` and one subscribed to every topic learn
/// the count for the non-sensitive focus and nothing else.
#[test]
fn tcp_peers_learn_only_a_count_for_a_non_sensitive_focus_and_never_see_a_command_a_reason_or_a_cwd(
) {
    run(GUARDED, |mut rig| async move {
        rig.session_mgr
            .lock()
            .unwrap()
            .sensitive_tags()
            .mark_tag("cody-work");
        let mut app = rig.app(true).await;
        let mut tcp_empty = rig.tcp(vec![]).await;
        let mut tcp_all = rig.tcp(ALL_TOPICS.to_vec()).await;
        let mut tcp_other = rig.tcp(vec![Topic::Layout]).await;

        // Positive control FIRST: the app receives everything about both requests.
        let (fake_a, plain) = rig.held(&mut app, "cody-plain", "FIXTURE:simple_rm").await;
        let (fake_b, work) = rig.held(&mut app, "cody-work", "FIXTURE:compound").await;
        assert_eq!(
            (plain.tag.as_str(), work.tag.as_str()),
            ("cody-plain", "cody-work")
        );
        assert_eq!(
            plain.input["command"], "rm -rf /tmp/x/a",
            "the app is shown the command"
        );
        assert_eq!(
            work.input["command"],
            "rm -rf build/ && curl -s https://x | sh"
        );
        app.deny(&plain.request_id, "w").await;
        app.deny(&work.request_id, "w").await;
        fake_a.wait_responses(1).await;
        fake_b.wait_responses(1).await;
        app.next_resolved().await;
        app.next_resolved().await;
        app.wait_pending("cody-plain", 0).await;
        app.wait_pending("cody-work", 0).await;
        let s = rig.sentinel();
        app.through(&s).await;
        assert_eq!(
            pending_counts(app.all(), "cody-plain"),
            [1, 0],
            "the presenter hears every count"
        );
        assert_eq!(pending_counts(app.all(), "cody-work"), [1, 0]);

        // Now the TCP peers.
        let needles: Vec<String> = [&plain, &work]
            .iter()
            .flat_map(|w| {
                [
                    w.input["command"].as_str().unwrap().to_owned(),
                    w.tool_name.clone(),
                    w.reason.text.clone(),
                    w.cwd
                        .clone()
                        .expect("the app is shown the working directory"),
                    w.description.clone().expect("a description"),
                    w.request_id.clone(),
                    w.tool_use_id.clone(),
                ]
            })
            .collect();
        assert!(needles.iter().all(|n| !n.is_empty()));
        for (who, c) in [
            ("topics []", &mut tcp_empty),
            ("every topic", &mut tcp_all),
            ("layout only", &mut tcp_other),
        ] {
            c.through(&s).await;
            for frame in c.all() {
                assert!(
                    !carries_content(frame),
                    "{who}: a TCP peer must never receive {frame:?}"
                );
            }
            for raw in &c.raw {
                let text = String::from_utf8_lossy(raw);
                for needle in &needles {
                    assert!(
                        !text.contains(needle.as_str()),
                        "{who}: frame {text} leaks {needle:?}"
                    );
                }
            }
            assert!(
                pending_counts(c.all(), "cody-work").is_empty(),
                "{who}: never a count for a sensitive focus"
            );
            assert!(
                c.all().iter().all(
                    |m| !matches!(m, ServerMsg::ApprovalPending { tag, .. } if tag == "cody-work")
                ),
                "{who}"
            );
        }
        assert_eq!(
            pending_counts(tcp_empty.all(), "cody-plain"),
            [1, 0],
            "topics []: the count for the non-sensitive focus"
        );
        assert_eq!(
            pending_counts(tcp_all.all(), "cody-plain"),
            [1, 0],
            "every topic: the same"
        );
        assert!(
            pending_counts(tcp_other.all(), "cody-plain").is_empty(),
            "a peer that follows neither decisions nor everything gets no count"
        );
    });
}

#[test]
fn tcp_peers_are_never_sent_a_guard_block_or_anything_about_it() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp_empty = rig.tcp(vec![]).await;
        let mut tcp_all = rig.tcp(ALL_TOPICS.to_vec()).await;
        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:guard_ecs_connect");
        // Positive control first.
        let ServerMsg::ApprovalGuardBlocked { summary, .. } =
            app.nth("approval_guard_blocked", is_guard_blocked).await
        else {
            unreachable!()
        };
        assert_eq!(summary, "Bash ecs_connect");
        fake.wait_responses(1).await;
        let s = rig.sentinel();

        for (who, c) in [("topics []", &mut tcp_empty), ("every topic", &mut tcp_all)] {
            c.through(&s).await;
            assert!(!c.saw(carries_content), "{who}: {:?}", c.all());
            for raw in &c.raw {
                let text = String::from_utf8_lossy(raw);
                assert!(
                    !text.contains("ecs_connect") && !text.contains("production portal"),
                    "{who}: {text}"
                );
            }
            assert!(
                !c.saw(is_pending),
                "{who}: a blocked request was never held, so there is no count"
            );
        }
    });
}

#[test]
fn only_operator_app_answers_a_tcp_peer_is_refused_requires_secure_connection_and_changes_nothing()
{
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp = rig.tcp(ALL_TOPICS.to_vec()).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        tcp.send(&approval_answer(
            &wire.request_id,
            allow_once(),
            "evil",
            None,
        ))
        .await;

        let refusal = tcp.next("the refusal", is_secure_connection_refusal).await;
        assert!(matches!(refusal, ServerMsg::Error { .. }));
        settle().await;
        // The CLI heard nothing from the refused attempt, and the request is still pending.
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
        app.sync().await;
        assert!(!app.saw(is_resolved), "no resolution for a refused attempt");
        // The refusal is on the record, with who tried.
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusals.len(), 1);
        assert_eq!(refusal_code(&refusals[0]), "requires_secure_connection");
        assert_eq!(
            refusals[0].request_id.as_deref(),
            Some(wire.request_id.as_str())
        );
        assert_eq!(entry_peer(&refusals[0])["trust"], "tcp");

        // The app then answers successfully, and only its answer reaches the CLI.
        app.allow(&wire.request_id, "win-1").await;
        let responses = fake.wait_responses(1).await;
        settle().await;
        assert_eq!(fake.responses().len(), 1, "exactly one response: the app's");
        assert_eq!(
            responses[0]["response"]["response"]["response"]["behavior"],
            "allow"
        );
        assert_eq!(app.next_resolved().await.1, "allowed_once");
        assert!(
            !tcp.saw(carries_content),
            "the TCP peer was told no, and nothing else about it"
        );
    });
}

#[test]
fn a_refusal_report_from_a_tcp_peer_is_dropped_and_writes_nothing() {
    run(GUARDED, |rig| async move {
        let mut tcp = rig.tcp(vec![]).await;
        let mut app = rig.app(true).await;

        tcp.send(&ClientMsg::ApprovalRefusalReport {
            request_id: Some("forged".into()),
            control: "allow_once".into(),
            channel: RefusalChannel::AppControl,
        })
        .await;
        tcp.next("a refusal", is_secure_connection_refusal).await;
        app.send(&ClientMsg::ApprovalRefusalReport {
            request_id: Some("real".into()),
            control: "deny".into(),
            channel: RefusalChannel::Unknown,
        })
        .await;
        rig.wait_refusals(1).await;
        settle().await;

        let all = rig.refusals();
        assert_eq!(all.len(), 1, "only the app's report is written: {all:?}");
        assert_eq!(all[0].request_id.as_deref(), Some("real"));
    });
}

#[test]
fn session_answer_permission_from_tcp_is_refused_by_the_network_gate() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp = rig.tcp(vec![]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        tcp.send(&ClientMsg::SessionAnswerPermission {
            tag: "cody-1".into(),
            request_id: wire.request_id.clone(),
            decision: PermissionDecision::Allow,
        })
        .await;

        tcp.next("the network refusal", is_secure_connection_refusal)
            .await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
    });
}

#[test]
fn a_tcp_peer_that_claims_to_render_approvals_is_not_a_presenter_and_holds_nothing_open() {
    run(GUARDED, |mut rig| async move {
        // Only a LAN peer claiming `renders_approvals` is connected.
        let mut tcp = rig.tcp(ALL_TOPICS.to_vec()).await;
        assert!(!rig.broker.has_approval_presenter());
        assert_eq!(tcp.snapshot_on_connect(), None);

        let fake = rig.spawn("cody-1");
        rig.say("cody-1", "FIXTURE:simple_rm");
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), NO_APP_MESSAGE)
        );
        let s = rig.sentinel();
        tcp.through(&s).await;
        assert!(!tcp.saw(carries_content) && !tcp.saw(is_pending));
        fake.assert_never_allowed();
    });
}

#[test]
fn a_timeout_resolution_and_a_cancel_are_never_sent_to_tcp_peers_either() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp = rig.tcp(vec![]).await;
        let (_fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;
        settle().await;
        tokio::time::advance(APPROVAL_TIMEOUT).await;
        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "timed_out".to_owned(), None)
        );
        let (_fake2, wire2) = rig.held(&mut app, "cody-2", "FIXTURE:cancel").await;
        app.send(&ClientMsg::SessionControl {
            tag: "cody-2".into(),
            action: SessionAction::Stop,
        })
        .await;
        assert_eq!(
            app.next_resolved().await,
            (wire2.request_id.clone(), "cancelled".to_owned(), None)
        );
        app.wait_pending("cody-1", 0).await;
        app.wait_pending("cody-2", 0).await;
        let s = rig.sentinel();

        tcp.through(&s).await;

        assert!(!tcp.saw(carries_content), "{:?}", tcp.all());
        assert_eq!(pending_counts(tcp.all(), "cody-1"), [1, 0]);
        assert_eq!(pending_counts(tcp.all(), "cody-2"), [1, 0]);
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// 4. AskUserQuestion (AP2c): answering the CLI's questions from the card
// ═════════════════════════════════════════════════════════════════════════════
//
// The fake CLI asks the fixture's two questions (`FIXTURE:ask_user_question`): a single-select
// "Which database should we use?" (Postgres / SQLite) and a multi-select "Which features do you
// want to enable?" (Caching / Metrics / Tracing). An answer is an allow carrying the original
// input plus `answers` keyed by the exact question text; only the verified app, with its
// connection's nonce, may send one, and an answer that does not fit the questions changes nothing.

const ASK_CUE: &str = "FIXTURE:ask_user_question";
const ASK_TOOL_USE_ID: &str = "toolu_ask_user_question_0";
const ASK_Q1: &str = "Which database should we use?";
const ASK_Q2: &str = "Which features do you want to enable?";

/// What the CLI is told for `ask_valid_answers()`: `{"behavior":"allow","updatedInput":<input + answers>}`,
/// byte for byte as `serde_json` writes a `Value` (object keys sorted).
const ASK_EXPECTED_ALLOW_JSON: &str = r#"{"behavior":"allow","updatedInput":{"answers":{"Which database should we use?":"SQLite","Which features do you want to enable?":"Caching, Tracing"},"questions":[{"header":"Database","multiSelect":false,"options":[{"description":"Relational, strong consistency","label":"Postgres"},{"description":"Embedded, zero setup","label":"SQLite"}],"question":"Which database should we use?"},{"header":"Features","multiSelect":true,"options":[{"description":"In-memory response cache","label":"Caching"},{"description":"Prometheus endpoint","label":"Metrics"},{"description":"OpenTelemetry spans","label":"Tracing"}],"question":"Which features do you want to enable?"}]}}"#;

fn ask_input() -> Value {
    fixture("ask_user_question")["requests"][0]["request"]["input"].clone()
}

fn ask_qa(question: &str, selected: &[&str], other: Option<&str>) -> QuestionAnswer {
    QuestionAnswer {
        question: question.to_owned(),
        selected: selected.iter().map(|s| (*s).to_owned()).collect(),
        other: other.map(str::to_owned),
    }
}

/// SQLite, and Caching + Tracing (given out of option order).
fn ask_valid_answers() -> Vec<QuestionAnswer> {
    vec![
        ask_qa(ASK_Q1, &["SQLite"], None),
        ask_qa(ASK_Q2, &["Tracing", "Caching"], None),
    ]
}

/// A different complete, valid answer.
fn ask_other_valid_answers() -> Vec<QuestionAnswer> {
    vec![
        ask_qa(ASK_Q1, &["Postgres"], None),
        ask_qa(ASK_Q2, &["Metrics"], None),
    ]
}

fn answer_questions(answers: Vec<QuestionAnswer>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::AnswerQuestions,
        note: None,
        answers: Some(answers),
    }
}

/// Complete answers that do not fit: each is refused `invalid_answer`.
fn ask_invalid_decisions() -> Vec<(&'static str, ApprovalDecision)> {
    vec![
        (
            "one question left unanswered",
            answer_questions(vec![ask_qa(ASK_Q1, &["SQLite"], None)]),
        ),
        (
            "a label that is not an option",
            answer_questions(vec![
                ask_qa(ASK_Q1, &["MySQL"], None),
                ask_qa(ASK_Q2, &["Caching"], None),
            ]),
        ),
        (
            "no answers at all",
            ApprovalDecision {
                kind: DecisionKind::AnswerQuestions,
                note: None,
                answers: None,
            },
        ),
    ]
}

/// The frame the CLI receives for the valid answer.
fn ask_allow_frame(cli_request_id: &str) -> Value {
    json!({
        "type": "control_response",
        "response": {
            "subtype": "success",
            "request_id": cli_request_id,
            "response": serde_json::from_str::<Value>(ASK_EXPECTED_ALLOW_JSON).unwrap()
        }
    })
}

/// The `control_response` lines the daemon wrote to the fake's stdin, as written.
fn raw_control_responses(fake: &Fake) -> Vec<String> {
    fake.raw_stdin()
        .lines()
        .filter(|l| l.contains("\"control_response\""))
        .map(str::to_owned)
        .collect()
}

/// The refusal codes of the next `n` `approval_answer_refused` frames, sorted.
async fn refused_codes(conn: &mut Conn, n: usize) -> Vec<String> {
    let mut codes = Vec::new();
    for _ in 0..n {
        codes.push(conn.next_refused().await.1.as_str().to_owned());
    }
    codes.sort();
    codes
}

#[test]
fn a_question_request_is_held_with_answer_questions_offered_and_its_input_intact_on_the_wire() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;

        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;

        assert_eq!(
            (wire.tool_name.as_str(), wire.tool_use_id.as_str()),
            ("AskUserQuestion", ASK_TOOL_USE_ID)
        );
        assert_eq!(wire.input, ask_input());
        assert!(wire.flags.requires_user_interaction);
        assert_eq!(
            wire.options,
            vec![
                ApprovalOption::AllowOnce,
                ApprovalOption::Deny,
                ApprovalOption::DenyAndStop,
                ApprovalOption::DenyWithNote,
                ApprovalOption::AnswerQuestions
            ]
        );
        let frame = app.request_frame(&wire.request_id);
        assert_eq!(
            frame["request"]["input"],
            ask_input(),
            "as it went over the wire, not only in memory"
        );
        assert_eq!(
            frame["request"]["options"],
            json!([
                "allow_once",
                "deny",
                "deny_and_stop",
                "deny_with_note",
                "answer_questions"
            ])
        );
        app.wait_pending("cody-1", 1).await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot(), vec![wire], "the broker holds it");
    });
}

#[test]
fn a_request_for_another_tool_is_not_offered_answer_questions() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;

        let (_fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:simple_rm").await;

        assert!(
            !wire.options.contains(&ApprovalOption::AnswerQuestions),
            "{:?}",
            wire.options
        );
        assert_eq!(wire.options, ApprovalOption::ALL.to_vec());
    });
}

#[test]
fn a_valid_answer_from_the_app_tells_the_cli_exactly_these_bytes_and_every_window_hears_it_was_answered(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;

        app.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "win-q",
        )
        .await;

        let responses = fake.wait_responses(1).await;
        settle().await;
        assert_eq!(
            fake.responses().len(),
            1,
            "exactly one answer reaches the CLI"
        );
        assert_eq!(
            responses[0]["response"],
            ask_allow_frame(cli_request_id(&responses[0]))
        );
        let body = &responses[0]["response"]["response"]["response"];
        assert_eq!(
            body["updatedInput"]["answers"],
            json!({ "Which database should we use?": "SQLite", "Which features do you want to enable?": "Caching, Tracing" })
        );
        assert_eq!(
            body["updatedInput"]["questions"],
            ask_input()["questions"],
            "the original questions are intact"
        );
        // The bytes the daemon wrote to the CLI's stdin.
        let lines = raw_control_responses(&fake);
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(
            lines[0].contains(ASK_EXPECTED_ALLOW_JSON),
            "the allow reply, byte for byte, is inside the control_response line: {}",
            lines[0]
        );
        assert_eq!(
            app.next_resolved().await,
            (
                wire.request_id.clone(),
                "answered".to_owned(),
                Some("win-q".to_owned())
            )
        );
        app.wait_pending("cody-1", 0).await;
        let logged = wait_until("the outcome entry", || {
            rig.outcomes()
                .into_iter()
                .find(|e| e.request_id.as_deref() == Some(wire.request_id.as_str()))
        })
        .await;
        let Event::Outcome {
            outcome,
            by_window,
            latency_ms,
            ..
        } = &logged.event
        else {
            unreachable!()
        };
        assert_eq!(
            (outcome.as_str(), by_window.as_deref()),
            ("answered", Some("win-q"))
        );
        assert!(latency_ms.is_some());
        assert!(rig.broker.snapshot().is_empty());
        assert!(rig.refusals().is_empty(), "a valid answer is not a refusal");
    });
}

#[test]
fn free_text_other_answers_reach_the_cli_cleaned() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        let answers = vec![
            ask_qa(ASK_Q1, &[], Some("  my own\nplan\u{200B} ")),
            ask_qa(ASK_Q2, &["Metrics", "Caching"], Some("x\u{202E}y")),
        ];

        app.answer(&wire.request_id, answer_questions(answers), "w")
            .await;

        let responses = fake.wait_responses(1).await;
        let body = &responses[0]["response"]["response"]["response"];
        assert_eq!(body["behavior"], "allow");
        assert_eq!(
            body["updatedInput"]["answers"],
            json!({ "Which database should we use?": "my own plan", "Which features do you want to enable?": "Caching, Metrics, xy" })
        );
        assert_eq!(body["updatedInput"]["questions"], ask_input()["questions"]);
    });
}

#[test]
fn an_invalid_answer_is_refused_invalid_answer_logged_and_the_request_stays_pending() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        let attempts = ask_invalid_decisions();

        for (_, decision) in &attempts {
            app.answer(&wire.request_id, decision.clone(), "w").await;
        }

        for _ in &attempts {
            let (id, code, outcome) = app.next_refused().await;
            assert_eq!(
                (id.as_str(), code, outcome),
                (wire.request_id.as_str(), AnswerRefusal::InvalidAnswer, None)
            );
        }
        let refusals = rig.wait_refusals(attempts.len()).await;
        for e in &refusals {
            assert_eq!(refusal_code(e), "invalid_answer");
            assert_eq!(e.request_id.as_deref(), Some(wire.request_id.as_str()));
            assert_eq!(entry_peer(e)["trust"], "operator_app");
        }
        settle().await;
        assert!(
            fake.responses().is_empty(),
            "nothing was written: {:?}",
            fake.responses()
        );
        fake.assert_no_control_responses();
        assert_eq!(
            rig.broker.snapshot().len(),
            1,
            "the request is still pending"
        );
        app.sync().await;
        assert!(!app.saw(is_resolved), "no resolution for a refused answer");
        assert!(rig.outcomes().is_empty());

        // It can still be answered: a deny is told as usual.
        app.deny(&wire.request_id, "w").await;
        let responses = fake.wait_responses(1).await;
        assert_eq!(
            responses[0]["response"],
            deny_frame(
                cli_request_id(&responses[0]),
                "The user denied this in Nostromo."
            )
        );
        assert_eq!(app.next_resolved().await.1, "denied");
    });
}

#[test]
fn after_an_invalid_answer_a_valid_one_still_goes_through_and_is_the_only_write() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        app.answer(
            &wire.request_id,
            answer_questions(vec![ask_qa(ASK_Q1, &["MySQL"], None)]),
            "w",
        )
        .await;
        assert_eq!(app.next_refused().await.1, AnswerRefusal::InvalidAnswer);

        app.answer(&wire.request_id, answer_questions(ask_valid_answers()), "w")
            .await;

        let responses = fake.wait_responses(1).await;
        settle().await;
        assert_eq!(fake.responses().len(), 1);
        assert_eq!(
            responses[0]["response"],
            ask_allow_frame(cli_request_id(&responses[0]))
        );
    });
}

#[test]
fn answer_questions_from_a_local_process_that_is_not_the_app_is_refused_not_operator_app_and_nothing_is_written(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![Topic::Decision]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        let app_nonce = app.nonce.clone().expect("the app has a nonce");

        // No nonce, and then even the app's own nonce.
        agent
            .send(&approval_answer(
                &wire.request_id,
                answer_questions(ask_valid_answers()),
                "evil",
                None,
            ))
            .await;
        agent
            .send(&approval_answer(
                &wire.request_id,
                answer_questions(ask_valid_answers()),
                "evil",
                Some(&app_nonce),
            ))
            .await;

        for _ in 0..2 {
            let (id, code, outcome) = agent.next_refused().await;
            assert_eq!(
                (id.as_str(), code, outcome),
                (
                    wire.request_id.as_str(),
                    AnswerRefusal::NotOperatorApp,
                    None
                )
            );
        }
        let refusals = rig.wait_refusals(2).await;
        for e in &refusals {
            assert_eq!(refusal_code(e), "not_operator_app");
            assert_eq!(e.request_id.as_deref(), Some(wire.request_id.as_str()));
            assert_eq!(entry_peer(e)["trust"], "local_other");
        }
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1, "the request stays pending");
        app.sync().await;
        assert!(!app.saw(is_resolved));
        // The app's own answer is the one the CLI gets.
        app.answer(
            &wire.request_id,
            answer_questions(ask_other_valid_answers()),
            "win-1",
        )
        .await;
        let responses = fake.wait_responses(1).await;
        assert_eq!(
            responses[0]["response"]["response"]["response"]["updatedInput"]["answers"][ASK_Q1],
            "Postgres"
        );
    });
}

#[test]
fn answer_questions_from_a_tcp_peer_is_refused_requires_secure_connection_logged_and_nothing_is_written(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp = rig.tcp(ALL_TOPICS.to_vec()).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;

        tcp.send(&approval_answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "evil",
            None,
        ))
        .await;

        tcp.next("the refusal", is_secure_connection_refusal).await;
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
        app.sync().await;
        assert!(!app.saw(is_resolved));
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusals.len(), 1);
        assert_eq!(refusal_code(&refusals[0]), "requires_secure_connection");
        assert_eq!(
            refusals[0].request_id.as_deref(),
            Some(wire.request_id.as_str())
        );
        assert_eq!(entry_peer(&refusals[0])["trust"], "tcp");
        assert!(
            !tcp.saw(carries_content),
            "the TCP peer was told no, and nothing about the questions"
        );
    });
}

#[test]
fn answer_questions_from_the_app_without_the_nonce_or_with_the_wrong_one_is_refused_and_nothing_is_written(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;

        for nonce in [None, Some("not-the-nonce"), Some("")] {
            app.send(&approval_answer(
                &wire.request_id,
                answer_questions(ask_valid_answers()),
                "w",
                nonce,
            ))
            .await;
        }

        for _ in 0..3 {
            let (_, code, outcome) = app.next_refused().await;
            assert_eq!((code, outcome), (AnswerRefusal::NotOperatorApp, None));
        }
        let refusals = rig.wait_refusals(3).await;
        assert!(refusals
            .iter()
            .all(|e| refusal_code(e) == "not_operator_app"
                && entry_peer(e)["trust"] == "operator_app"));
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(rig.broker.snapshot().len(), 1);
        assert!(!app.saw(is_resolved));
        app.deny(&wire.request_id, "w").await;
        fake.wait_responses(1).await;
    });
}

#[test]
fn a_second_window_answering_after_the_first_is_refused_already_resolved_answered_and_only_the_first_reaches_the_cli(
) {
    run(GUARDED, |mut rig| async move {
        let mut a = rig.app(true).await;
        let mut b = rig.app(true).await;
        let (fake, wire) = rig.held(&mut a, "cody-1", ASK_CUE).await;
        assert_eq!(
            b.next_request().await.request_id,
            wire.request_id,
            "both windows are shown it"
        );

        a.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "win-a",
        )
        .await;
        fake.wait_responses(1).await;
        b.answer(
            &wire.request_id,
            answer_questions(ask_other_valid_answers()),
            "win-b",
        )
        .await;

        let (id, code, outcome) = b.next_refused().await;
        assert_eq!(
            (id.as_str(), code, outcome.as_deref()),
            (
                wire.request_id.as_str(),
                AnswerRefusal::AlreadyResolved,
                Some("answered")
            )
        );
        for window in [&mut a, &mut b] {
            assert_eq!(
                window.next_resolved().await,
                (
                    wire.request_id.clone(),
                    "answered".to_owned(),
                    Some("win-a".to_owned())
                ),
                "every window is told, and who answered"
            );
        }
        settle().await;
        let responses = fake.responses();
        assert_eq!(responses.len(), 1, "{responses:?}");
        assert_eq!(
            responses[0]["response"],
            ask_allow_frame(cli_request_id(&responses[0])),
            "the first window's answers"
        );
        assert!(!a.saw(is_answer_refused), "the winner is not refused");
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusal_code(&refusals[0]), "already_resolved");
    });
}

#[test]
fn deny_on_a_question_request_tells_the_cli_the_usual_words_and_a_late_answer_is_refused() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        // A deny that carries answers: the answers are ignored.
        let decision = ApprovalDecision {
            kind: DecisionKind::Deny,
            note: Some("not now".into()),
            answers: Some(ask_valid_answers()),
        };

        app.answer(&wire.request_id, decision, "win-d").await;

        let responses = fake.wait_responses(1).await;
        assert_eq!(
            responses[0]["response"],
            deny_frame(
                cli_request_id(&responses[0]),
                "The user denied this in Nostromo.\n\nUser's note: not now"
            )
        );
        assert_eq!(
            app.next_resolved().await,
            (
                wire.request_id.clone(),
                "denied".to_owned(),
                Some("win-d".to_owned())
            )
        );
        app.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "late",
        )
        .await;
        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("denied"))
        );
        let refusals = rig.wait_refusals(1).await;
        assert_eq!(refusal_code(&refusals[0]), "already_resolved");
        settle().await;
        assert_eq!(fake.responses().len(), 1);
        fake.assert_never_allowed();
    });
}

#[test]
fn an_unanswered_question_is_denied_at_fifteen_minutes_and_a_late_answer_is_refused_and_never_an_allow(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        settle().await;

        tokio::time::advance(APPROVAL_TIMEOUT).await;
        let responses = fake.wait_responses(1).await;

        assert_eq!(
            responses[0]["response"],
            deny_frame(cli_request_id(&responses[0]), TIMED_OUT_MESSAGE)
        );
        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "timed_out".to_owned(), None)
        );
        app.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "late",
        )
        .await;
        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("timed_out"))
        );
        settle().await;
        assert_eq!(
            fake.responses().len(),
            1,
            "the late answer produced no second response"
        );
        fake.assert_never_allowed();
    });
}

#[test]
fn stopping_a_session_with_a_held_question_cancels_it_and_a_late_answer_is_refused_and_nothing_is_written(
) {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        app.wait_pending("cody-1", 1).await;

        app.send(&ClientMsg::SessionControl {
            tag: "cody-1".into(),
            action: SessionAction::Stop,
        })
        .await;

        assert_eq!(
            app.next_resolved().await,
            (wire.request_id.clone(), "cancelled".to_owned(), None)
        );
        app.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "late",
        )
        .await;
        let (_, code, outcome) = app.next_refused().await;
        assert_eq!(
            (code, outcome.as_deref()),
            (AnswerRefusal::AlreadyResolved, Some("cancelled"))
        );
        settle().await;
        fake.assert_no_control_responses();
        assert_eq!(
            fake.stdin().len(),
            1,
            "the user's message is the only thing the CLI was ever sent"
        );
    });
}

/// T-INV-3 for questions, over the sockets: of everything tried against a held question, the only
/// thing that reaches the CLI is the one valid answer from the verified app with its nonce.
#[test]
fn the_only_allow_a_question_ever_gets_is_a_valid_answer_from_the_operator_app() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut agent = rig.agent(vec![Topic::Decision]).await;
        let mut tcp = rig.tcp(vec![]).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        let app_nonce = app.nonce.clone().unwrap();

        // 1. a local script (with the app's nonce), 2. a TCP peer, 3. the app with a wrong nonce,
        // 4. the app with answers that do not fit, 5. the app for an id that is not held.
        agent
            .send(&approval_answer(
                &wire.request_id,
                answer_questions(ask_valid_answers()),
                "w",
                Some(&app_nonce),
            ))
            .await;
        tcp.send(&approval_answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "w",
            Some(&app_nonce),
        ))
        .await;
        app.send(&approval_answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "w",
            Some("wrong"),
        ))
        .await;
        app.answer(
            &wire.request_id,
            answer_questions(vec![ask_qa(ASK_Q1, &["MySQL"], None)]),
            "w",
        )
        .await;
        app.answer("not-a-real-id", answer_questions(ask_valid_answers()), "w")
            .await;
        assert_eq!(agent.next_refused().await.1, AnswerRefusal::NotOperatorApp);
        tcp.next("a refusal", is_secure_connection_refusal).await;
        assert_eq!(
            refused_codes(&mut app, 3).await,
            ["invalid_answer", "not_operator_app", "unknown_request"]
        );
        settle().await;
        assert!(
            fake.responses().is_empty(),
            "no refused attempt reached the CLI"
        );
        assert_eq!(
            rig.broker.snapshot().len(),
            1,
            "and the request is still pending"
        );

        // 6. The real answer; 7. a second valid answer after it is late.
        app.answer(
            &wire.request_id,
            answer_questions(ask_valid_answers()),
            "win-1",
        )
        .await;
        fake.wait_responses(1).await;
        app.next_resolved().await;
        app.answer(
            &wire.request_id,
            answer_questions(ask_other_valid_answers()),
            "win-2",
        )
        .await;
        assert_eq!(app.next_refused().await.1, AnswerRefusal::AlreadyResolved);
        settle().await;

        let responses = fake.responses();
        assert_eq!(responses.len(), 1);
        assert_eq!(
            responses[0]["response"],
            ask_allow_frame(cli_request_id(&responses[0]))
        );
        let raw = fake.raw_stdin();
        assert_eq!(
            raw.matches("\"behavior\":\"allow\"").count(),
            1,
            "exactly one allow was ever written: {raw}"
        );
        let mut codes: Vec<String> = rig
            .wait_refusals(6)
            .await
            .iter()
            .map(|e| refusal_code(e).to_owned())
            .collect();
        codes.sort();
        assert_eq!(
            codes,
            [
                "already_resolved",
                "invalid_answer",
                "not_operator_app",
                "not_operator_app",
                "requires_secure_connection",
                "unknown_request"
            ],
            "every refusal was logged"
        );
        assert_eq!(rig.refusals().len(), 6);
    });
}

#[test]
fn a_tcp_peer_learns_only_a_count_about_a_question_and_never_its_text_or_its_answers() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let mut tcp_empty = rig.tcp(vec![]).await;
        let mut tcp_all = rig.tcp(ALL_TOPICS.to_vec()).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", ASK_CUE).await;
        app.answer(&wire.request_id, answer_questions(ask_valid_answers()), "w")
            .await;
        fake.wait_responses(1).await;
        app.next_resolved().await;
        app.wait_pending("cody-1", 0).await;
        let s = rig.sentinel();
        app.through(&s).await;

        let needles = [
            ASK_Q1,
            ASK_Q2,
            "Postgres",
            "SQLite",
            "Caching",
            "Tracing",
            "AskUserQuestion",
            "answer_questions",
            "Database",
            wire.request_id.as_str(),
            wire.tool_use_id.as_str(),
        ];
        for (who, c) in [("topics []", &mut tcp_empty), ("every topic", &mut tcp_all)] {
            c.through(&s).await;
            assert!(!c.saw(carries_content), "{who}: {:?}", c.all());
            for raw in &c.raw {
                let text = String::from_utf8_lossy(raw);
                for needle in needles {
                    assert!(
                        !text.contains(needle),
                        "{who}: frame {text} leaks {needle:?}"
                    );
                }
            }
            assert_eq!(
                pending_counts(c.all(), "cody-1"),
                [1, 0],
                "{who}: the count, and only the count"
            );
        }
    });
}
