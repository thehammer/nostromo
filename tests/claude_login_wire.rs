//! The Claude sign-in wire (CL1), end to end: a real `Server` on a temp Unix socket and an
//! ephemeral TCP port, a real `SessionManager` running the hermetic fake `claude` in its
//! auth mode (`tests/support/fake_claude_perm.py`, `FAKE_CLAUDE_AUTH_FILE`), a
//! `LoginCoordinator` over a fake credential watch, and `Peers` standing in for "what process
//! is behind this socket".
//!
//! What this pins, from outside the daemon:
//! - `Welcome.features` names `claude_login_v1` and the protocol version is unchanged;
//! - a local peer is replayed the current `claude_login_state` after Subscribe, and sent each
//!   change, whatever topics it follows;
//! - a TCP peer never receives it, subscribed to everything or not;
//! - `claude_login_action` is applied only from the verified Mac app with its connection's
//!   nonce; anyone else gets `not_operator_app` and nothing is written;
//! - Retry resends the held message once, Discard drops it;
//! - a send to a paused session whose queue is full is refused over the wire.
//!
//! Time is paused tokio time and never advances. Every wait polls in real time and yields.
//! Environment variables are process-wide, so every test takes `ENV_LOCK`.

use std::collections::VecDeque;
use std::future::Future;
use std::os::fd::BorrowedFd;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::approvals::guard;
use nostromo::ipc::claude_login::{
    CredentialStamp, CredentialWatch, LoginCoordinator, LOGIN_QUEUE_CAP,
};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::peer_verify::testing::{app_info, script_info};
use nostromo::ipc::peer_verify::{CodeIdentity, PeerInfo, PeerVerifier, UnverifiedReason};
use nostromo::ipc::protocol::{
    ClaudeLoginActionKind, ClaudeLoginPhase, ClaudeLoginSession, ClientMsg, ServerMsg, Topic,
    PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::session_manager::{SessionManager, CLAUDE_BIN_ENV};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::mpsc;

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);

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

struct QuietWatch;

impl CredentialWatch for QuietWatch {
    fn stamp(&self) -> CredentialStamp {
        CredentialStamp::Stamp("wire-stamp-0".into())
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

struct Rig {
    // Declared first so the fake CLIs are killed before their directory goes.
    _kill: KillOnDrop,
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    mgr: Arc<Mutex<SessionManager>>,
    peers: Arc<Peers>,
    tmp: TempDir,
    auth_file: PathBuf,
    spawns: usize,
    sentinels: usize,
}

struct Fake {
    dir: PathBuf,
}

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn run<Fut: Future<Output = ()>>(body: impl FnOnce(Rig) -> Fut) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    rt.block_on(async move {
        let rig = Rig::new().await;
        body(rig).await;
    });
}

impl Rig {
    async fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::set_var(
            nostromo::approvals::APPROVALS_DIR_ENV,
            tmp.path().join("approvals"),
        );
        std::env::set_var(guard::GUARD_BIN_ENV, env!("CARGO_BIN_EXE_nostromo-guard"));
        let auth_file = tmp.path().join("auth-state");
        std::fs::write(&auth_file, "ok").unwrap();

        let mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("daemon-sessions.json"),
        )));
        // Attached before `Server::bind`, which wires the coordinator's broadcast to its channel.
        let coordinator = LoginCoordinator::new(Arc::new(QuietWatch));
        coordinator.attach(&mgr);

        let peers = Arc::new(Peers::default());
        let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
        let socket_path = tmp.path().join("test.sock");
        let server = Server::bind(
            &socket_path,
            Arc::clone(&mgr),
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
            Arc::clone(&mgr),
            tmp.path().join("perri-state"),
            decisions,
        );
        Self {
            _kill: KillOnDrop(Arc::clone(&mgr)),
            server,
            socket_path,
            tcp_port,
            mgr,
            peers,
            tmp,
            auth_file,
            spawns: 0,
            sentinels: 0,
        }
    }

    fn set_login(&self, value: &str) {
        std::fs::write(&self.auth_file, value).unwrap();
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
                "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' FAKE_CLAUDE_AUTH_FILE='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
                dir.display(),
                self.auth_file.display()
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
        self.mgr
            .lock()
            .unwrap()
            .spawn_session(
                tag.into(),
                "cody".into(),
                format!("view-{tag}"),
                Some(work),
                None,
                false,
            )
            .expect("the session starts");
        Fake { dir }
    }

    fn say(&self, tag: &str, text: &str) {
        self.mgr
            .lock()
            .unwrap()
            .send_user_message(tag, text, &[])
            .expect("the message is accepted");
    }

    /// What the daemon would tell a client right now.
    fn picture(&self) -> (bool, Vec<ClaudeLoginSession>) {
        state_of(&self.mgr.lock().unwrap().login_snapshot()).expect("a claude_login_state")
    }

    /// Fail one turn of `tag` on an expired login and wait for the hold.
    async fn hold(&mut self, tag: &str, text: &str) -> (Fake, ClaudeLoginSession) {
        let fake = self.spawn(tag);
        self.set_login("expired");
        self.say(tag, text);
        let entry = wait_until("a hold", || {
            self.picture()
                .1
                .into_iter()
                .find(|s| s.tag == tag && s.hold_id.is_some())
        })
        .await;
        (fake, entry)
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

    // ── connections ──

    /// The verified Mac app, following `topics`.
    async fn app(&self, topics: Vec<Topic>) -> Conn {
        self.open_unix(app_info(), Some("mac_app"), subscribe(topics))
            .await
    }

    /// An agent's own process on the daemon's socket. It claims to be the Mac app; the process
    /// behind it is not the app.
    async fn agent(&self, topics: Vec<Topic>) -> Conn {
        self.open_unix(script_info(), Some("mac_app"), subscribe(topics))
            .await
    }

    /// A LAN peer.
    async fn tcp(&self, topics: Vec<Topic>) -> Conn {
        let s = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        let (r, w) = s.into_split();
        Conn::start(r, w).handshake(None, subscribe(topics)).await
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

impl Fake {
    /// The text of every user message the daemon wrote to the fake's stdin.
    fn user_texts(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.join("stdin.jsonl"))
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|f| f["type"] == "user")
            .map(|f| {
                f["message"]["content"]
                    .as_str()
                    .unwrap_or_default()
                    .to_owned()
            })
            .collect()
    }
}

fn subscribe(topics: Vec<Topic>) -> Value {
    serde_json::to_value(ClientMsg::Subscribe {
        topics,
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec![],
    })
    .unwrap()
}

/// Real-time polling that never parks the (paused) runtime.
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

/// Give spawned tasks, sockets and the blocking pool a moment of real time.
async fn settle() {
    for _ in 0..60 {
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
            reader,
        }
    }

    /// Hello, Welcome, Subscribe, then a Ping/Pong so the subscription is registered.
    async fn handshake(mut self, client_kind: Option<&str>, subscribe: Value) -> Self {
        self.send(&ClientMsg::Hello {
            client_id: "claude-login-wire-it".into(),
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

    /// The next frame (from where the last `next`/`sync` stopped) that `pred` accepts.
    async fn next(&mut self, what: &str, pred: impl Fn(&ServerMsg) -> bool) -> ServerMsg {
        let start = Instant::now();
        loop {
            self.pump();
            if let Some(i) = (self.cursor..self.seen.len()).find(|&i| pred(&self.seen[i])) {
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

    /// Ping, wait for the Pong; the frames that came before it (from the cursor), Pong excluded.
    async fn sync(&mut self) -> Vec<ServerMsg> {
        let start = self.cursor;
        self.send(&ClientMsg::Ping).await;
        self.next("the Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
        self.seen[start..self.cursor - 1].to_vec()
    }

    /// Wait until some frame received so far, or yet to come, satisfies `pred`.
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

    /// The most recent claude_login_state this connection has received.
    fn last_state(&mut self) -> Option<(bool, Vec<ClaudeLoginSession>)> {
        self.all().iter().rev().find_map(state_of)
    }

    /// How many `Error` frames starting with `prefix` this connection has received.
    fn errors_starting(&mut self, prefix: &str) -> usize {
        self.all()
            .iter()
            .filter(|m| matches!(m, ServerMsg::Error { message } if message.starts_with(prefix)))
            .count()
    }

    async fn wait_errors_starting(&mut self, prefix: &str, n: usize) {
        let start = Instant::now();
        while self.errors_starting(prefix) < n {
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "timed out (real time) waiting for {n} {prefix:?} error(s); got {:#?}",
                self.seen
            );
            std::thread::sleep(Duration::from_millis(2));
            tokio::task::yield_now().await;
        }
    }

    /// The raw JSON of every claude_login_state frame received.
    fn raw_state_frames(&mut self) -> Vec<String> {
        self.pump();
        self.raw
            .iter()
            .map(|b| String::from_utf8_lossy(b).into_owned())
            .filter(|s| s.contains("claude_login_state"))
            .collect()
    }

    async fn action(
        &mut self,
        action: ClaudeLoginActionKind,
        tag: &str,
        hold_id: Option<&str>,
        nonce: Option<&str>,
    ) {
        self.send(&ClientMsg::ClaudeLoginAction {
            action,
            tag: tag.into(),
            hold_id: hold_id.map(str::to_owned),
            operator_nonce: nonce.map(str::to_owned),
        })
        .await;
    }

    /// An action carrying this connection's own nonce (the app's valid one).
    async fn action_with_own_nonce(
        &mut self,
        action: ClaudeLoginActionKind,
        tag: &str,
        hold_id: Option<&str>,
    ) {
        let nonce = self.nonce.clone();
        self.action(action, tag, hold_id, nonce.as_deref()).await;
    }
}

fn state_of(m: &ServerMsg) -> Option<(bool, Vec<ClaudeLoginSession>)> {
    match m {
        ServerMsg::ClaudeLoginState {
            needs_login,
            sessions,
            ..
        } => Some((*needs_login, sessions.clone())),
        _ => None,
    }
}

fn is_login_state(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::ClaudeLoginState { .. })
}

fn is_login_state_needing_login(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::ClaudeLoginState {
            needs_login: true,
            ..
        }
    )
}

// ═════════════════════════════════════════════════════════════════════════════
// version and features
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn protocol_version_is_unchanged_at_4() {
    assert_eq!(
        PROTOCOL_VERSION, 4,
        "the sign-in frames are additive: an old Mac keeps working"
    );
}

#[test]
fn welcome_announces_claude_login_v1_to_local_peers() {
    run(|rig| async move {
        let app = rig.app(vec![]).await;
        let agent = rig.agent(vec![]).await;
        for (who, conn) in [("app", &app), ("agent", &agent)] {
            assert!(
                conn.features.iter().any(|f| f == "claude_login_v1"),
                "{who}: {:?}",
                conn.features
            );
        }
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// who is told what
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_local_subscriber_is_replayed_a_state_saying_nothing_is_waiting_whatever_its_topics() {
    run(|rig| async move {
        let mut with_none = rig.app(vec![]).await;
        let mut with_layout = rig.agent(vec![Topic::Layout]).await;
        for (who, conn) in [
            ("no topics", &mut with_none),
            ("layout only", &mut with_layout),
        ] {
            conn.wait_seen("the replayed state", is_login_state).await;
            let (needs_login, sessions) = conn.last_state().unwrap();
            assert!(!needs_login, "{who}");
            assert!(sessions.is_empty(), "{who}");
        }
    });
}

#[test]
fn a_local_subscriber_is_replayed_the_current_picture_when_a_session_waits() {
    run(|mut rig| async move {
        let (_fake, entry) = rig.hold("cody-1", "WIRE-HELD-REPLAY hello").await;
        rig.say("cody-1", "WIRE-QUEUED-REPLAY");

        let mut app = rig.app(vec![]).await;
        app.wait_seen("a state that needs a login", is_login_state_needing_login)
            .await;
        let (needs_login, sessions) = app.last_state().unwrap();
        assert!(needs_login);
        assert_eq!(sessions.len(), 1);
        let got = &sessions[0];
        assert_eq!(got.tag, "cody-1");
        assert_eq!(got.hold_id, entry.hold_id);
        assert_eq!(got.phase, ClaudeLoginPhase::Waiting);
        assert_eq!(got.queued, 1);
    });
}

#[test]
fn a_change_is_broadcast_to_every_local_subscriber_whatever_its_topics_with_no_content() {
    run(|mut rig| async move {
        let mut app = rig.app(vec![]).await;
        let mut agent = rig.agent(vec![Topic::Layout]).await;

        let (_fake, entry) = rig.hold("cody-1", "WIRE-HELD-LIVE hello").await;

        for (who, conn) in [("app", &mut app), ("agent", &mut agent)] {
            conn.wait_seen("a state that needs a login", is_login_state_needing_login)
                .await;
            let (_, sessions) = conn.last_state().unwrap();
            assert_eq!(sessions.len(), 1, "{who}");
            assert_eq!(sessions[0].hold_id, entry.hold_id, "{who}");
            for frame in conn.raw_state_frames() {
                assert!(
                    !frame.contains("WIRE-HELD-LIVE"),
                    "{who}: the message text is on the wire: {frame}"
                );
                assert!(
                    !frame.contains("OAuth"),
                    "{who}: the error text is on the wire: {frame}"
                );
            }
        }
    });
}

#[test]
fn a_tcp_peer_subscribed_to_everything_never_receives_the_login_state() {
    run(|mut rig| async move {
        let (_fake, _entry) = rig.hold("cody-1", "WIRE-HELD-TCP hello").await;
        let mut app = rig.app(vec![]).await;
        app.wait_seen("the replayed state", is_login_state_needing_login)
            .await;

        // Connects while a session waits: no replay.
        let mut tcp = rig.tcp(ALL_TOPICS.to_vec()).await;
        assert!(
            !tcp.connect_frames.iter().any(is_login_state),
            "{:?}",
            tcp.connect_frames
        );

        // Then the picture changes: the app is told, the TCP peer is not.
        rig.say("cody-1", "WIRE-QUEUED-TCP");
        app.wait_seen("the changed state", |m| {
            matches!(m, ServerMsg::ClaudeLoginState { sessions, .. } if sessions.iter().any(|s| s.queued == 1))
        })
        .await;
        let sentinel = rig.sentinel();
        tcp.through(&sentinel).await;
        assert!(!tcp.saw(is_login_state), "{:#?}", tcp.all());
        assert!(tcp.raw_state_frames().is_empty());
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// who may act
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn only_the_verified_app_with_its_nonce_may_resend_or_discard_anyone_else_gets_not_operator_app() {
    run(|mut rig| async move {
        let (fake, entry) = rig.hold("cody-1", "WIRE-HELD-REFUSE hello").await;
        let id = entry.hold_id.clone().unwrap();
        rig.say("cody-1", "WIRE-QUEUED-REFUSE");
        // The login works again: an action that wrongly got through would visibly write.
        rig.set_login("ok");

        let mut app = rig.app(vec![]).await;
        let mut agent = rig.agent(vec![]).await;
        let app_nonce = app.nonce.clone().expect("the app has a nonce");
        assert!(agent.nonce.is_none());

        // A process that is not the app: no nonce, and even the app's own nonce.
        for action in [ClaudeLoginActionKind::Retry, ClaudeLoginActionKind::Discard] {
            agent.action(action, "cody-1", Some(&id), None).await;
            agent
                .action(action, "cody-1", Some(&id), Some(&app_nonce))
                .await;
        }
        agent.wait_errors_starting("not_operator_app", 4).await;

        // The app, with a missing, a wrong and an empty nonce.
        for action in [ClaudeLoginActionKind::Retry, ClaudeLoginActionKind::Discard] {
            app.action(action, "cody-1", Some(&id), None).await;
            app.action(action, "cody-1", Some(&id), Some("not-the-nonce"))
                .await;
            app.action(action, "cody-1", Some(&id), Some("")).await;
        }
        app.wait_errors_starting("not_operator_app", 6).await;

        // A LAN peer (its reply, if any, is not pinned).
        let mut tcp = rig.tcp(ALL_TOPICS.to_vec()).await;
        tcp.action(ClaudeLoginActionKind::Retry, "cody-1", Some(&id), None)
            .await;
        tcp.action(ClaudeLoginActionKind::Discard, "cody-1", Some(&id), None)
            .await;

        // Nothing was written, resent or dropped.
        settle().await;
        assert_eq!(fake.user_texts(), vec!["WIRE-HELD-REFUSE hello"]);
        let (needs_login, sessions) = rig.picture();
        assert!(needs_login);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].hold_id.as_deref(), Some(id.as_str()));
        assert_eq!(sessions[0].queued, 1);
    });
}

#[test]
fn a_refusal_carries_no_content() {
    run(|mut rig| async move {
        let (_fake, entry) = rig.hold("cody-1", "WIRE-HELD-NOCONTENT hello").await;
        let mut agent = rig.agent(vec![]).await;
        agent
            .action(
                ClaudeLoginActionKind::Retry,
                "cody-1",
                entry.hold_id.as_deref(),
                None,
            )
            .await;
        agent.wait_errors_starting("not_operator_app", 1).await;
        for m in agent.all() {
            if let ServerMsg::Error { message } = m {
                assert!(
                    !message.contains("WIRE-HELD-NOCONTENT") && !message.contains("OAuth"),
                    "{message}"
                );
            }
        }
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// what the app can do
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn retry_from_the_app_resends_the_held_message_once_even_when_pressed_twice() {
    run(|mut rig| async move {
        let (fake, entry) = rig.hold("cody-1", "WIRE-HELD-RETRY hello").await;
        let id = entry.hold_id.clone().unwrap();
        let mut app = rig.app(vec![]).await;
        app.wait_seen("the replayed state", is_login_state_needing_login)
            .await;
        rig.set_login("ok");

        // Pressed twice, back to back.
        app.action_with_own_nonce(ClaudeLoginActionKind::Retry, "cody-1", Some(&id))
            .await;
        app.action_with_own_nonce(ClaudeLoginActionKind::Retry, "cody-1", Some(&id))
            .await;

        wait_until("the held message to be written again", || {
            (fake.user_texts().len() >= 2).then_some(())
        })
        .await;
        wait_until("the hold to clear", || (!rig.picture().0).then_some(())).await;
        app.wait_seen("a state saying nothing waits", |m| {
            matches!(m, ServerMsg::ClaudeLoginState { needs_login: false, sessions, .. } if sessions.is_empty())
        })
        .await;

        // A late third press naming the same, now gone, hold.
        app.action_with_own_nonce(ClaudeLoginActionKind::Retry, "cody-1", Some(&id))
            .await;
        app.sync().await;
        settle().await;
        assert_eq!(
            fake.user_texts(),
            vec!["WIRE-HELD-RETRY hello"; 2],
            "written once more, not more"
        );
        assert_eq!(
            app.errors_starting("not_operator_app"),
            0,
            "the app's own presses are never refused"
        );
    });
}

#[test]
fn discard_from_the_app_drops_the_hold_and_the_queue_goes_on() {
    run(|mut rig| async move {
        let (fake, entry) = rig.hold("cody-1", "WIRE-HELD-DISCARD hello").await;
        let id = entry.hold_id.clone().unwrap();
        rig.say("cody-1", "WIRE-QUEUED-DISCARD");
        let mut app = rig.app(vec![]).await;
        app.wait_seen("the replayed state", is_login_state_needing_login)
            .await;
        rig.set_login("ok");

        app.action_with_own_nonce(ClaudeLoginActionKind::Discard, "cody-1", Some(&id))
            .await;

        wait_until("the queued message to be written", || {
            (fake.user_texts().len() >= 2).then_some(())
        })
        .await;
        wait_until("the hold to clear", || (!rig.picture().0).then_some(())).await;
        settle().await;
        assert_eq!(
            fake.user_texts(),
            vec!["WIRE-HELD-DISCARD hello", "WIRE-QUEUED-DISCARD"],
            "the held message is gone; the queued one is sent"
        );
        app.wait_seen("a state saying nothing waits", |m| {
            matches!(
                m,
                ServerMsg::ClaudeLoginState {
                    needs_login: false,
                    ..
                }
            )
        })
        .await;
    });
}

#[test]
fn an_action_naming_an_old_hold_changes_nothing() {
    run(|mut rig| async move {
        let (fake, entry) = rig.hold("cody-1", "WIRE-HELD-OLD hello").await;
        let mut app = rig.app(vec![]).await;
        app.wait_seen("the replayed state", is_login_state_needing_login)
            .await;
        rig.set_login("ok");

        app.action_with_own_nonce(
            ClaudeLoginActionKind::Retry,
            "cody-1",
            Some("00000000-0000-4000-8000-00000000dead"),
        )
        .await;
        app.action_with_own_nonce(
            ClaudeLoginActionKind::Discard,
            "cody-1",
            Some("00000000-0000-4000-8000-00000000dead"),
        )
        .await;
        app.sync().await;
        settle().await;
        assert_eq!(fake.user_texts().len(), 1);
        assert_eq!(rig.picture().1[0].hold_id, entry.hold_id);
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// a full paused queue
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_session_send_to_a_waiting_session_with_a_full_queue_is_refused_over_the_wire() {
    run(|mut rig| async move {
        let (fake, _entry) = rig.hold("cody-1", "WIRE-HELD-FULL hello").await;
        let mut app = rig.app(vec![]).await;

        for i in 1..=LOGIN_QUEUE_CAP {
            app.send(&ClientMsg::SessionSend {
                tag: "cody-1".into(),
                text: format!("WIRE-QUEUED-FULL-{i}"),
                images: vec![],
            })
            .await;
        }
        app.sync().await;
        wait_until("the queue to fill", || {
            (rig.picture().1[0].queued as usize == LOGIN_QUEUE_CAP).then_some(())
        })
        .await;
        assert_eq!(app.errors_starting("waiting_for_sign_in"), 0, "twenty fit");

        app.send(&ClientMsg::SessionSend {
            tag: "cody-1".into(),
            text: "WIRE-OVERFLOW".into(),
            images: vec![],
        })
        .await;
        app.wait_seen("the queue-full refusal", |m| {
            matches!(m, ServerMsg::Error { message } if message.contains("waiting_for_sign_in: queue full"))
        })
        .await;
        for m in app.all() {
            if let ServerMsg::Error { message } = m {
                assert!(
                    !message.contains("WIRE-OVERFLOW"),
                    "the refusal carries no message text: {message}"
                );
            }
        }
        settle().await;
        assert_eq!(fake.user_texts().len(), 1, "nothing was written");
        assert_eq!(rig.picture().1[0].queued as usize, LOGIN_QUEUE_CAP);
    });
}
