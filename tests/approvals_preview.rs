#![allow(dead_code, unused_imports)]
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
use nostromo::approvals::rules::CandidateKind;
use nostromo::approvals::wire::{
    AnswerRefusal, ApprovalDecision, ApprovalOption, ApprovalRequestWire, DecisionKind,
    QuestionAnswer, RefusalChannel, SessionRuleWire,
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
        candidate_id: None,
        rule_text: None,
    }
}

fn deny(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::Deny,
        note: note.map(str::to_owned),
        answers: None,
        candidate_id: None,
        rule_text: None,
    }
}

fn deny_and_stop(note: Option<&str>) -> ApprovalDecision {
    ApprovalDecision {
        kind: DecisionKind::DenyAndStop,
        note: note.map(str::to_owned),
        answers: None,
        candidate_id: None,
        rule_text: None,
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

// ── AP7 tests ─────────────────────────────────────────────────────────────────

use nostromo::approvals::preview::{EntryKind, Meta, PreviewFs, RealFs};
use nostromo::approvals::wire::{ApprovalPreviewWire, PreviewFlag, PreviewState};

/// The real file system, made slow.
struct Slow(Duration);

impl PreviewFs for Slow {
    fn symlink_metadata(&self, path: &Path) -> std::io::Result<Meta> {
        std::thread::sleep(self.0);
        RealFs.symlink_metadata(path)
    }
    fn read_dir(
        &self,
        path: &Path,
    ) -> std::io::Result<Box<dyn Iterator<Item = std::io::Result<std::ffi::OsString>>>> {
        std::thread::sleep(self.0);
        RealFs.read_dir(path)
    }
    fn is_network(&self, path: &Path) -> bool {
        RealFs.is_network(path)
    }
}

fn is_preview(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ApprovalPreview { .. })
}

fn files(dir: &Path, n: usize, prefix: &str) {
    std::fs::create_dir_all(dir).unwrap();
    for i in 0..n {
        std::fs::write(dir.join(format!("{prefix}{i:03}")), b"hello").unwrap();
    }
}

fn preview_entries(rig: &Rig) -> Vec<Entry> {
    rig.audit()
        .into_iter()
        .filter(|e| matches!(e.event, Event::Preview { .. }))
        .collect()
}

/// A session's working folder exists before the fake starts, so prepare it first.
fn prepare(rig: &Rig, f: impl FnOnce(&Path)) {
    let work = rig.tmp.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    f(&work);
}

#[test]
fn a_held_rm_carries_a_complete_preview_and_one_audit_entry() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 3, "a"));
        let mut app = rig.app(true).await;
        let (fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:compound").await;
        let p = wire.preview.clone().expect("a preview on the card");
        assert_eq!(p.state, PreviewState::Complete);
        assert_eq!(p.targets.len(), 1);
        let t = &p.targets[0];
        assert_eq!(
            t.path.as_deref(),
            Some(fake.work.join("build").to_str().unwrap())
        );
        assert!(t.relative);
        assert_eq!((t.files, t.dirs, t.bytes), (Some(3), Some(0), Some(15)));
        assert_eq!(
            wire.options,
            vec![
                ApprovalOption::AllowOnce,
                ApprovalOption::Deny,
                ApprovalOption::DenyAndStop,
                ApprovalOption::DenyWithNote
            ]
        );
        wait_until("the preview audit entry", || {
            (!preview_entries(&rig).is_empty()).then_some(())
        })
        .await;
        settle().await;
        let entries = preview_entries(&rig);
        assert_eq!(entries.len(), 1);
        assert_eq!(
            entries[0].request_id.as_deref(),
            Some(wire.request_id.as_str())
        );
        assert!(!rig
            .audit()
            .iter()
            .any(|e| matches!(&e.event, Event::Outcome { .. })));
        fake.assert_never_allowed();
    });
}

#[test]
fn a_command_without_rm_has_no_preview() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (_fake, wire) = rig
            .held(&mut app, "cody-1", "FIXTURE:ask_user_question")
            .await;
        assert!(wire.preview.is_none());
        assert!(preview_entries(&rig).is_empty());
    });
}

#[test]
fn an_unresolvable_operand_is_shown_as_such() {
    run(GUARDED, |mut rig| async move {
        let mut app = rig.app(true).await;
        let (_fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:preview_cant").await;
        let p = wire.preview.unwrap();
        assert_eq!(p.targets[0].cant_resolve.as_deref(), Some("x"));
        assert_eq!(p.targets[0].why.as_deref(), Some("after a cd"));
    });
}

#[test]
fn the_card_is_sent_without_waiting_for_the_walk_and_the_counts_follow() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 3, "a"));
        rig.broker
            .set_preview_fs_for_test(Arc::new(Slow(Duration::from_millis(100))));
        let mut app = rig.app(true).await;
        let started = Instant::now();
        let (_fake, wire) = rig
            .held(&mut app, "cody-1", "FIXTURE:preview_rm_build")
            .await;
        let counting = wire.preview.clone().unwrap();
        assert_eq!(counting.state, PreviewState::Counting);
        assert_eq!(counting.targets.len(), 1);
        assert_eq!(counting.targets[0].files, None);
        assert!(
            started.elapsed() < Duration::from_millis(900),
            "the card must not wait for the counts"
        );
        let ServerMsg::ApprovalPreview {
            tag,
            request_id,
            preview,
        } = app.next("the counts", is_preview).await
        else {
            unreachable!()
        };
        assert_eq!(
            (tag.as_str(), request_id.as_str()),
            ("cody-1", wire.request_id.as_str())
        );
        assert_eq!(preview.state, PreviewState::Complete);
        assert_eq!(preview.targets[0].files, Some(3));
        // late joiners get the counts in their snapshot
        let held = rig.broker.snapshot();
        assert_eq!(
            held[0].preview.as_ref().unwrap().state,
            PreviewState::Complete
        );
        assert_eq!(preview_entries(&rig).len(), 1);
    });
}

#[test]
fn no_preview_frame_follows_a_request_that_ended() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 3, "a"));
        rig.broker
            .set_preview_fs_for_test(Arc::new(Slow(Duration::from_millis(100))));
        let mut app = rig.app(true).await;
        let (fake, wire) = rig
            .held(&mut app, "cody-1", "FIXTURE:preview_rm_build")
            .await;
        assert_eq!(wire.preview.unwrap().state, PreviewState::Counting);
        app.deny(&wire.request_id, "w").await;
        fake.wait_responses(1).await;
        app.next_resolved().await;
        std::thread::sleep(Duration::from_millis(900)); // the walk ends
        let s = rig.sentinel();
        app.through(&s).await;
        assert!(!app.saw(is_preview));
        assert!(preview_entries(&rig).is_empty());
    });
}

#[test]
fn a_hung_file_system_never_stalls_the_next_request() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 1, "a"));
        rig.broker
            .set_preview_fs_for_test(Arc::new(Slow(Duration::from_millis(1500))));
        let mut app = rig.app(true).await;
        let (_f1, first) = rig
            .held(&mut app, "cody-1", "FIXTURE:preview_rm_build")
            .await;
        assert_eq!(first.preview.unwrap().state, PreviewState::Counting);
        let started = Instant::now();
        let (_f2, second) = rig
            .held(&mut app, "cody-2", "FIXTURE:preview_rm_build")
            .await;
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "the broker's worker must not wait on the file system: {:?}",
            started.elapsed()
        );
        // The helpers were busy: the second one says so instead of waiting.
        let state = second.preview.unwrap();
        assert!(matches!(
            state.state,
            PreviewState::Counting | PreviewState::Complete
        ));
        std::thread::sleep(Duration::from_secs(5)); // let the stuck helpers end
    });
}

#[test]
fn a_preview_over_the_cap_lists_the_first_targets_and_counts_the_rest() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(w, 70, "f"));
        let mut app = rig.app(true).await;
        let (_fake, wire) = rig.held(&mut app, "cody-1", "FIXTURE:preview_glob").await;
        let p = wire.preview.unwrap();
        assert_eq!(p.targets.len(), 64);
        assert_eq!(p.more, 6);
        assert!(p.targets[0].path.as_deref().unwrap().ends_with("/f000"));
    });
}

#[test]
fn a_lan_peer_never_receives_a_preview_in_any_frame() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 2, "a"));
        rig.broker
            .set_preview_fs_for_test(Arc::new(Slow(Duration::from_millis(100))));
        let mut app = rig.app(true).await;
        let mut tcp_all = rig.tcp(ALL_TOPICS.to_vec()).await;
        let mut tcp_empty = rig.tcp(vec![]).await;
        let (fake, wire) = rig
            .held(&mut app, "cody-1", "FIXTURE:preview_rm_build")
            .await;
        app.next("the counts", is_preview).await; // positive control
        let canary = fake.work.join("build").to_string_lossy().into_owned();
        app.deny(&wire.request_id, "w").await;
        app.next_resolved().await;
        let s = rig.sentinel();
        app.through(&s).await;
        for (who, c) in [("every topic", &mut tcp_all), ("topics []", &mut tcp_empty)] {
            c.through(&s).await;
            assert!(!c.saw(is_preview), "{who}");
            assert!(!c.saw(is_request), "{who}");
            for raw in &c.raw {
                let text = String::from_utf8_lossy(raw);
                assert!(!text.contains(&canary), "{who}: {text}");
                assert!(!text.contains("approval_preview"), "{who}: {text}");
            }
        }
    });
}

#[test]
fn a_preview_never_changes_the_options_offered() {
    run(GUARDED, |mut rig| async move {
        prepare(&rig, |w| files(&w.join("build"), 1, "a"));
        let mut app = rig.app(true).await;
        let (_f, with) = rig
            .held(&mut app, "cody-1", "FIXTURE:preview_rm_build")
            .await;
        let (_g, without) = rig
            .held(&mut app, "cody-2", "FIXTURE:ask_user_question")
            .await;
        assert!(with.preview.is_some() && without.preview.is_none());
        let base: Vec<_> = without
            .options
            .iter()
            .filter(|o| **o != ApprovalOption::AnswerQuestions)
            .cloned()
            .collect();
        assert_eq!(with.options, base);
    });
}
