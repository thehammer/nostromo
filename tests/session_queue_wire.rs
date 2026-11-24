//! The message queue wire (S1, `session_queue_v1`), end to end: a real `Server` on a temp Unix
//! socket and an ephemeral TCP port, a real `SessionManager` running the hermetic fake `claude`
//! (`tests/support/fake_claude_perm.py`: the `HOLD:<path>` cue keeps a turn open until the file
//! exists, and every stdin frame is logged), and `Peers` standing in for "what process is behind
//! this socket".
//!
//! What this pins, from outside the daemon:
//! - `Welcome.features` names `session_queue_v1`;
//! - a connection that sends `session_queue_watch` gets the current snapshot at once and one
//!   per change; a connection that never watches receives no `session_queue*` frame;
//! - take-back and remove answer `taken_back` (text and images) / `removed`, the fake never
//!   receives the message, a repeat is `not_found`, an app entry is `not_allowed` and still
//!   delivered (its hook runs once);
//! - only the verified Mac app with its nonce may take back or remove: another local process,
//!   a TCP peer, no nonce and a stale nonce change nothing; a TCP peer may not watch;
//! - Stop hands the dropped typed messages back to the operator connection that pressed it and
//!   watches the tag, held first; nobody else gets texts;
//! - a restart carries the queue (same ids) and the watch survives; a user stop tells the
//!   watchers `session_stopped` with the typed ids lost;
//! - a message held for a sign-in is take-back-able, and returns the text as typed;
//! - no message text or image path reaches a log line.
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
use nostromo::ipc::claude_login::{CredentialStamp, CredentialWatch, LoginCoordinator};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::peer_verify::testing::{app_info, script_info};
use nostromo::ipc::peer_verify::{CodeIdentity, PeerInfo, PeerVerifier, UnverifiedReason};
use nostromo::ipc::protocol::{
    ClaudeLoginPhase, ClaudeLoginSession, ClientMsg, HeldEntryWire, QueueChangeReason,
    QueueChangeWire, QueueEntryWire, QueueResultCode, ServerMsg, SessionAction, Topic,
    PROTOCOL_VERSION,
};
use nostromo::ipc::server::Server;
use nostromo::ipc::session_manager::{AppLabel, SessionManager, CLAUDE_BIN_ENV};
use serde_json::Value;
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::mpsc;

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);

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
    _server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    mgr: Arc<Mutex<SessionManager>>,
    peers: Arc<Peers>,
    tmp: TempDir,
    auth_file: PathBuf,
    spawns: usize,
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
            _server: server,
            socket_path,
            tcp_port,
            mgr,
            peers,
            tmp,
            auth_file,
            spawns: 0,
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

    /// The sessions the daemon says are waiting for a sign-in.
    fn login_sessions(&self) -> Vec<ClaudeLoginSession> {
        match self.mgr.lock().unwrap().login_snapshot() {
            ServerMsg::ClaudeLoginState { sessions, .. } => sessions,
            other => panic!("not a claude_login_state: {other:?}"),
        }
    }

    /// Fail one turn of `tag` on an expired login and wait for the hold.
    async fn hold(&mut self, tag: &str, text: &str) -> (Fake, ClaudeLoginSession) {
        let fake = self.spawn(tag);
        self.set_login("expired");
        self.say(tag, text);
        let entry = wait_until("a hold", || {
            self.login_sessions()
                .into_iter()
                .find(|s| s.tag == tag && s.hold_id.is_some())
        })
        .await;
        (fake, entry)
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
        operator_nonce: None,
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
            capabilities: Vec::new(),
            client_id: "claude-login-wire-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: client_kind.map(str::to_owned),
            role: None,
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

    /// Everything this connection has received so far.
    fn all(&mut self) -> &[ServerMsg] {
        self.pump();
        &self.seen
    }
}

// ── log capture (every event, every field) ────────────────────────────────────

mod logs {
    use std::fmt::Write as _;
    use std::sync::{Mutex, Once};

    use tracing_subscriber::layer::{Context, SubscriberExt};

    static LOGS: Mutex<Vec<String>> = Mutex::new(Vec::new());

    struct Capture;

    struct Fields(String);

    impl tracing::field::Visit for Fields {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            let _ = write!(self.0, "{}={:?} ", field.name(), value);
        }
    }

    impl<S: tracing::Subscriber> tracing_subscriber::Layer<S> for Capture {
        fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
            let mut fields = Fields(String::new());
            event.record(&mut fields);
            LOGS.lock().unwrap_or_else(|e| e.into_inner()).push(format!(
                "{} {}",
                event.metadata().target(),
                fields.0
            ));
        }
    }

    pub fn install() {
        static INSTALL: Once = Once::new();
        INSTALL.call_once(|| {
            let _ = tracing::subscriber::set_global_default(
                tracing_subscriber::registry().with(Capture),
            );
        });
    }

    pub fn clear() {
        LOGS.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    pub fn all() -> Vec<String> {
        LOGS.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

// ── helpers for the queue frames ──────────────────────────────────────────────

/// One `session_queue` frame, unpacked.
#[derive(Debug, Clone)]
struct Snap {
    rev: u64,
    entries: Vec<QueueEntryWire>,
    held: Option<HeldEntryWire>,
    change: Option<QueueChangeWire>,
}

impl Snap {
    fn texts(&self) -> Vec<&str> {
        self.entries.iter().map(|e| e.text.as_str()).collect()
    }

    fn ids(&self) -> Vec<String> {
        self.entries.iter().map(|e| e.id.clone()).collect()
    }
}

fn is_queue_frame(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::SessionQueue { .. }
            | ServerMsg::SessionQueueResult { .. }
            | ServerMsg::SessionQueueReturned { .. }
    )
}

fn snap_of(m: &ServerMsg) -> Option<Snap> {
    match m {
        ServerMsg::SessionQueue {
            rev,
            entries,
            held,
            change,
            ..
        } => Some(Snap {
            rev: *rev,
            entries: entries.clone(),
            held: held.clone(),
            change: change.clone(),
        }),
        _ => None,
    }
}

impl Conn {
    async fn attach(&mut self, tag: &str) {
        self.send(&ClientMsg::SessionAttach { tag: tag.into(), host: None })
            .await;
        self.sync().await;
    }

    async fn watch(&mut self, tag: &str) -> Snap {
        self.send(&ClientMsg::SessionQueueWatch { tag: tag.into() })
            .await;
        self.next_snap().await
    }

    /// The next queue snapshot this connection receives.
    async fn next_snap(&mut self) -> Snap {
        let m = self
            .next("a session_queue snapshot", |m| {
                matches!(m, ServerMsg::SessionQueue { .. })
            })
            .await;
        snap_of(&m).unwrap()
    }

    /// Snapshots until one satisfies `pred` (all that came meanwhile, last one the match).
    async fn snaps_until(&mut self, what: &str, pred: impl Fn(&Snap) -> bool) -> Vec<Snap> {
        let mut out = Vec::new();
        loop {
            let _ = what;
            let s = self.next_snap().await;
            let done = pred(&s);
            out.push(s);
            if done {
                return out;
            }
        }
    }

    async fn say(&mut self, tag: &str, text: &str, images: &[&str], client_ref: Option<&str>) {
        self.send(&ClientMsg::SessionSend {
            tag: tag.into(),
            text: text.into(),
            images: images.iter().map(|s| (*s).to_owned()).collect(),
            client_ref: client_ref.map(str::to_owned),
        })
        .await;
    }

    async fn verb(
        &mut self,
        take_back: bool,
        tag: &str,
        id: &str,
        request_id: &str,
        nonce: Option<&str>,
    ) {
        let (tag, id, request_id) = (tag.to_owned(), id.to_owned(), request_id.to_owned());
        let operator_nonce = nonce.map(str::to_owned);
        let msg = if take_back {
            ClientMsg::SessionQueueTakeBack {
                tag,
                id,
                request_id,
                operator_nonce,
            }
        } else {
            ClientMsg::SessionQueueRemove {
                tag,
                id,
                request_id,
                operator_nonce,
            }
        };
        self.send(&msg).await;
    }

    /// Take back with this connection's own nonce, and wait for the answer.
    async fn take_back(
        &mut self,
        tag: &str,
        id: &str,
    ) -> (QueueResultCode, Option<String>, Vec<String>) {
        let nonce = self.nonce.clone();
        self.verb(true, tag, id, "req-tb", nonce.as_deref()).await;
        self.result("req-tb").await
    }

    async fn remove(&mut self, tag: &str, id: &str) -> QueueResultCode {
        let nonce = self.nonce.clone();
        self.verb(false, tag, id, "req-rm", nonce.as_deref()).await;
        self.result("req-rm").await.0
    }

    async fn result(&mut self, request_id: &str) -> (QueueResultCode, Option<String>, Vec<String>) {
        let want = request_id.to_owned();
        match self
            .next("a session_queue_result", move |m| {
                matches!(m, ServerMsg::SessionQueueResult { request_id, .. } if *request_id == want)
            })
            .await
        {
            ServerMsg::SessionQueueResult {
                code, text, images, ..
            } => (code, text, images),
            _ => unreachable!(),
        }
    }

    fn queue_frames(&mut self) -> usize {
        self.all().iter().filter(|m| is_queue_frame(m)).count()
    }
}

impl Rig {
    /// A session whose turn is held open by the fake until the returned file exists.
    async fn busy(&mut self, tag: &str) -> (Fake, PathBuf) {
        let fake = self.spawn(tag);
        let hold = self.tmp.path().join(format!("hold-{tag}"));
        self.say(tag, &format!("prime HOLD:{}", hold.display()));
        wait_until("the fake to read the prime message", || {
            (!fake.user_texts().is_empty()).then_some(())
        })
        .await;
        (fake, hold)
    }

    fn queue_typed(&self, tag: &str, text: &str, images: &[&str]) -> String {
        let images: Vec<String> = images.iter().map(|s| (*s).to_owned()).collect();
        self.mgr
            .lock()
            .unwrap()
            .send_typed_message(tag, text, &images, None)
            .expect("the message is accepted")
    }
}

fn release(hold: &std::path::Path) {
    std::fs::write(hold, "").unwrap();
}

// ═════════════════════════════════════════════════════════════════════════════
// features, watch and the view
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn welcome_announces_session_queue_v1_to_local_peers() {
    run(|rig| async move {
        let app = rig.app(vec![]).await;
        assert!(
            app.features.iter().any(|f| f == "session_queue_v1"),
            "{:?}",
            app.features
        );
    });
}

#[test]
fn a_watcher_gets_the_snapshot_at_once_and_each_change_and_a_bystander_gets_no_queue_frame() {
    run(|mut rig| async move {
        let (fake, hold) = rig.busy("cody-w1").await;
        let mut app = rig.app(vec![]).await;
        let mut bystander = rig.app(vec![]).await;
        bystander.attach("cody-w1").await;

        let first = app.watch("cody-w1").await;
        assert!(first.entries.is_empty() && first.held.is_none());

        app.say("cody-w1", "one", &[], Some("c-1")).await;
        let queued = app.next_snap().await;
        assert_eq!(queued.texts(), ["one"]);
        assert_eq!(queued.entries[0].client_ref.as_deref(), Some("c-1"));
        assert!(queued.entries[0].can_take_back);
        assert_eq!(
            queued.change.as_ref().unwrap().reason,
            QueueChangeReason::Queued
        );
        assert!(queued.rev > first.rev);

        let image = rig.tmp.path().join("a.png");
        std::fs::write(&image, b"not really a png").unwrap();
        app.say(
            "cody-w1",
            "/compact keep going",
            &[image.to_str().unwrap()],
            None,
        )
        .await;
        app.snaps_until("two entries", |s| s.entries.len() == 2)
            .await;
        rig.mgr
            .lock()
            .unwrap()
            .send_app_message("cody-w1", "from the app", &[], AppLabel::WorkItem)
            .unwrap();
        let both = app
            .snaps_until("three entries", |s| s.entries.len() == 3)
            .await;
        let last = both.last().unwrap();
        assert_eq!(last.texts(), ["one", "/compact keep going", "from the app"]);
        assert!(last.entries[1].command && last.entries[1].image_count == 1);
        assert_eq!(last.entries[2].app_label.as_deref(), Some("work_item"));
        assert!(!last.entries[2].can_take_back);

        release(&hold);
        let drained = app
            .snaps_until("an empty queue", |s| s.entries.is_empty())
            .await;
        assert_eq!(
            drained.last().unwrap().change.as_ref().unwrap().reason,
            QueueChangeReason::Delivered
        );
        wait_until("all four messages", || {
            (fake.user_texts().len() == 4).then_some(())
        })
        .await;
        // (The message with an image is a content array, so `user_texts` shows it as "".)
        assert_eq!(&fake.user_texts()[1..], ["one", "", "from the app"]);

        // The bystander attached, never watched, and heard nothing about the queue.
        bystander.sync().await;
        assert_eq!(bystander.queue_frames(), 0);
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// take back and remove
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn take_back_returns_the_text_and_images_remove_returns_nothing_and_neither_is_ever_delivered() {
    run(|mut rig| async move {
        let (fake, hold) = rig.busy("cody-t1").await;
        let mut app = rig.app(vec![]).await;
        let mut watcher = rig.app(vec![]).await;
        app.watch("cody-t1").await;
        watcher.watch("cody-t1").await;
        let a = rig.queue_typed("cody-t1", "take me back", &["/tmp/p.png", "/tmp/q.png"]);
        let b = rig.queue_typed("cody-t1", "remove me", &[]);
        let c = rig.queue_typed("cody-t1", "keep me", &[]);
        watcher
            .snaps_until("three queued", |s| s.entries.len() == 3)
            .await;

        let (code, text, images) = app.take_back("cody-t1", &a).await;
        assert_eq!(code, QueueResultCode::TakenBack);
        assert_eq!(text.as_deref(), Some("take me back"));
        assert_eq!(images, ["/tmp/p.png", "/tmp/q.png"]);
        let after = watcher
            .snaps_until("a without a", |s| !s.ids().contains(&a))
            .await;
        assert_eq!(
            after.last().unwrap().change.as_ref().unwrap().reason,
            QueueChangeReason::TakenBack
        );

        assert_eq!(app.remove("cody-t1", &b).await, QueueResultCode::Removed);
        watcher
            .snaps_until("b gone", |s| !s.ids().contains(&b))
            .await;

        // A repeat of either answers not_found.
        assert_eq!(
            app.take_back("cody-t1", &a).await.0,
            QueueResultCode::NotFound
        );
        assert_eq!(app.remove("cody-t1", &b).await, QueueResultCode::NotFound);

        release(&hold);
        wait_until("the one that stayed", || {
            (fake.user_texts().len() == 2).then_some(())
        })
        .await;
        settle().await;
        assert_eq!(fake.user_texts()[1], "keep me");
        assert_eq!(fake.user_texts().len(), 2, "neither was ever written");
        // Delivered now: a take-back of it says so.
        assert_eq!(
            app.take_back("cody-t1", &c).await.0,
            QueueResultCode::AlreadyDelivered
        );
    });
}

#[test]
fn an_app_entry_is_not_allowed_to_be_taken_back_or_removed_and_is_delivered_with_its_hook_once() {
    run(|mut rig| async move {
        let (fake, hold) = rig.busy("cody-a1").await;
        let mut app = rig.app(vec![]).await;
        app.watch("cody-a1").await;
        let told = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hook = Arc::clone(&told);
        rig.mgr
            .lock()
            .unwrap()
            .send_app_message_then(
                "cody-a1",
                "Tell notify",
                AppLabel::MotherOverview,
                move || {
                    hook.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                },
            )
            .unwrap();
        let snap = app
            .snaps_until("the app entry", |s| s.entries.len() == 1)
            .await;
        let id = snap.last().unwrap().entries[0].id.clone();
        assert_eq!(
            snap.last().unwrap().entries[0].app_label.as_deref(),
            Some("mother_overview")
        );

        assert_eq!(
            app.take_back("cody-a1", &id).await.0,
            QueueResultCode::NotAllowed
        );
        assert_eq!(
            app.remove("cody-a1", &id).await,
            QueueResultCode::NotAllowed
        );
        assert_eq!(told.load(std::sync::atomic::Ordering::SeqCst), 0);

        release(&hold);
        wait_until("the Tell notify", || {
            (fake.user_texts().len() == 2).then_some(())
        })
        .await;
        assert_eq!(fake.user_texts()[1], "Tell notify");
        wait_until("the hook", || {
            (told.load(std::sync::atomic::Ordering::SeqCst) == 1).then_some(())
        })
        .await;
        settle().await;
        assert_eq!(told.load(std::sync::atomic::Ordering::SeqCst), 1, "once");
    });
}

#[test]
fn a_fred_seed_to_a_busy_session_is_an_app_entry_that_cannot_be_taken_back_and_stop_does_not_return_it(
) {
    run(|mut rig| async move {
        let (fake, _hold) = rig.busy("fred").await;
        let mut app = rig.app(vec![]).await;
        app.watch("fred").await;

        app.send(&ClientMsg::FredSeed {
            request_id: "seed-1".into(),
            text: "SEED-TEXT-FOR-FRED".into(),
        })
        .await;
        let snaps = app
            .snaps_until("the seed queued", |s| s.entries.len() == 1)
            .await;
        let entry = snaps.last().unwrap().entries[0].clone();
        assert_eq!(entry.app_label.as_deref(), Some("work_item"));
        assert!(!entry.can_take_back, "a Fred seed is app-composed");

        assert_eq!(
            app.take_back("fred", &entry.id).await.0,
            QueueResultCode::NotAllowed
        );
        assert_eq!(
            app.remove("fred", &entry.id).await,
            QueueResultCode::NotAllowed
        );

        app.send(&ClientMsg::SessionInterrupt { tag: "fred".into() })
            .await;
        settle().await;
        app.sync().await;
        let returned: Vec<_> = app
            .all()
            .iter()
            .filter_map(|m| match m {
                ServerMsg::SessionQueueReturned { entries, .. } => Some(entries.clone()),
                _ => None,
            })
            .flatten()
            .collect();
        assert!(
            returned.iter().all(|e| !e.text.contains("SEED-TEXT")),
            "Stop must not hand a Fred seed back to the composer: {returned:?}"
        );
        assert!(fake.user_texts().iter().all(|t| !t.contains("SEED-TEXT")));
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// who may do what
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn only_the_verified_app_with_its_nonce_may_take_back_or_remove_anyone_else_changes_nothing() {
    run(|mut rig| async move {
        let (fake, hold) = rig.busy("cody-g1").await;
        let mut app = rig.app(vec![]).await;
        let mut agent = rig.agent(vec![]).await;
        let mut tcp = rig.tcp(vec![]).await;
        app.watch("cody-g1").await;
        let id = rig.queue_typed("cody-g1", "SECRET-QUEUED-TEXT", &["/tmp/secret.png"]);
        app.snaps_until("queued", |s| s.entries.len() == 1).await;

        // Another local process that claims to be the app; the app without or with a stale nonce.
        for (who, nonce) in [
            ("agent", Some("anything")),
            ("no nonce", None),
            ("stale nonce", Some("stale-nonce")),
        ] {
            let conn = if who == "agent" { &mut agent } else { &mut app };
            for take_back in [true, false] {
                conn.verb(take_back, "cody-g1", &id, "req-x", nonce).await;
                let (code, text, images) = conn.result("req-x").await;
                assert_eq!(code, QueueResultCode::NotAllowed, "{who}");
                assert!(text.is_none() && images.is_empty(), "{who}");
            }
        }
        // A LAN peer is refused at the door, with no content.
        tcp.verb(true, "cody-g1", &id, "req-x", Some("x")).await;
        tcp.next("the network refusal", |m| {
            matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
        })
        .await;
        tcp.verb(false, "cody-g1", &id, "req-y", None).await;
        tcp.next("the network refusal", |m| {
            matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
        })
        .await;
        // ... and may not watch.
        tcp.attach("cody-g1").await;
        tcp.send(&ClientMsg::SessionQueueWatch {
            tag: "cody-g1".into(),
        })
        .await;
        tcp.next("the network refusal", |m| {
            matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
        })
        .await;
        rig.mgr
            .lock()
            .unwrap()
            .send_typed_message("cody-g1", "later", &[], None)
            .unwrap();
        tcp.sync().await;
        assert_eq!(
            tcp.queue_frames(),
            0,
            "a LAN peer gets no queue frame, ever"
        );
        assert_eq!(agent.queue_frames(), 2, "only its own two refusals");

        // Nothing changed: the entry is still queued, and the app can take it back.
        let (code, text, _) = app.take_back("cody-g1", &id).await;
        assert_eq!(code, QueueResultCode::TakenBack);
        assert_eq!(text.as_deref(), Some("SECRET-QUEUED-TEXT"));
        release(&hold);
        wait_until("the other message", || {
            (fake.user_texts().len() == 2).then_some(())
        })
        .await;
        assert!(!fake.user_texts().iter().any(|t| t.contains("SECRET")));
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// Stop
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn stop_hands_the_dropped_typed_messages_to_the_operator_that_pressed_it_and_watches_nobody_else() {
    run(|mut rig| async move {
        let (fake, _hold) = rig.busy("cody-s1").await;
        let mut presser = rig.app(vec![]).await;
        let mut watcher = rig.app(vec![]).await;
        presser.watch("cody-s1").await;
        watcher.watch("cody-s1").await;
        let a = rig.queue_typed("cody-s1", "first words", &["/tmp/i.png"]);
        let b = rig.queue_typed("cody-s1", "second words", &[]);
        rig.mgr
            .lock()
            .unwrap()
            .send_app_message("cody-s1", "app words", &[], AppLabel::WorkItem)
            .unwrap();
        watcher
            .snaps_until("three queued", |s| s.entries.len() == 3)
            .await;

        presser
            .send(&ClientMsg::SessionInterrupt {
                tag: "cody-s1".into(),
            })
            .await;

        match presser
            .next("session_queue_returned", |m| {
                matches!(m, ServerMsg::SessionQueueReturned { .. })
            })
            .await
        {
            ServerMsg::SessionQueueReturned {
                reason, entries, ..
            } => {
                assert_eq!(reason, "stopped");
                let got: Vec<(String, String, Vec<String>)> = entries
                    .into_iter()
                    .map(|e| (e.id, e.text, e.images))
                    .collect();
                assert_eq!(
                    got,
                    [
                        (
                            a.clone(),
                            "first words".to_string(),
                            vec!["/tmp/i.png".to_string()]
                        ),
                        (b.clone(), "second words".to_string(), vec![]),
                    ],
                    "typed only, in order"
                );
            }
            _ => unreachable!(),
        }
        let stopped = watcher
            .snaps_until("the stopped snapshot", |s| s.entries.is_empty())
            .await;
        let change = stopped.last().unwrap().change.clone().unwrap();
        assert_eq!(change.reason, QueueChangeReason::Stopped);
        assert_eq!(change.ids.len(), 3, "typed and app ids");
        watcher.sync().await;
        assert!(
            !watcher
                .all()
                .iter()
                .any(|m| matches!(m, ServerMsg::SessionQueueReturned { .. })),
            "a watcher that did not press Stop gets no text"
        );
        settle().await;
        assert!(fake.user_texts().iter().all(|t| !t.contains("words")));
    });
}

#[test]
fn stop_from_a_non_watching_or_non_operator_connection_returns_no_texts() {
    run(|mut rig| async move {
        for (tag, who) in [
            ("cody-s2", "operator that does not watch"),
            ("cody-s3", "local process"),
        ] {
            let (_fake, _hold) = rig.busy(tag).await;
            let mut watcher = rig.app(vec![]).await;
            let mut presser = if who == "local process" {
                rig.agent(vec![]).await
            } else {
                rig.app(vec![]).await
            };
            watcher.watch(tag).await;
            if who == "local process" {
                // It watches too; it is just not the operator.
                presser.watch(tag).await;
            } else {
                presser.attach(tag).await;
            }
            rig.queue_typed(tag, "private words", &[]);
            watcher
                .snaps_until("queued", |s| s.entries.len() == 1)
                .await;

            presser
                .send(&ClientMsg::SessionInterrupt { tag: tag.into() })
                .await;

            watcher
                .snaps_until("stopped", |s| s.entries.is_empty())
                .await;
            presser.sync().await;
            assert!(
                !presser
                    .all()
                    .iter()
                    .any(|m| matches!(m, ServerMsg::SessionQueueReturned { .. })),
                "{who} gets no texts"
            );
        }
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// restart and stop of the session
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_restart_carries_the_queue_in_order_and_the_watch_survives_it() {
    run(|mut rig| async move {
        let (fake, _hold) = rig.busy("cody-r1").await;
        let mut app = rig.app(vec![]).await;
        app.watch("cody-r1").await;
        let ids: Vec<String> = ["one", "two", "three"]
            .iter()
            .map(|t| rig.queue_typed("cody-r1", t, &[]))
            .collect();
        app.snaps_until("three queued", |s| s.entries.len() == 3)
            .await;

        app.send(&ClientMsg::SessionControl {
            tag: "cody-r1".into(),
            action: SessionAction::Restart,
        })
        .await;

        // No second watch was sent; the new process still delivers them in order.
        let frames = app
            .snaps_until("everything delivered", |s| {
                s.entries.is_empty()
                    && s.change
                        .as_ref()
                        .is_some_and(|c| c.reason == QueueChangeReason::Delivered)
            })
            .await;
        let delivered: Vec<String> = frames
            .iter()
            .filter(|s| {
                s.change
                    .as_ref()
                    .is_some_and(|c| c.reason == QueueChangeReason::Delivered)
            })
            .flat_map(|s| s.change.as_ref().unwrap().ids.clone())
            .collect();
        assert_eq!(delivered, ids, "the same ids, in order");
        wait_until("the new process to read them", || {
            (fake.user_texts().len() == 4).then_some(())
        })
        .await;
        assert_eq!(&fake.user_texts()[1..], ["one", "two", "three"]);
    });
}

#[test]
fn a_user_stop_tells_the_watchers_session_stopped_with_the_typed_ids_lost() {
    run(|mut rig| async move {
        let (fake, _hold) = rig.busy("cody-u1").await;
        let mut app = rig.app(vec![]).await;
        app.watch("cody-u1").await;
        let a = rig.queue_typed("cody-u1", "gone one", &[]);
        let b = rig.queue_typed("cody-u1", "gone two", &[]);
        app.snaps_until("two queued", |s| s.entries.len() == 2)
            .await;

        app.send(&ClientMsg::SessionControl {
            tag: "cody-u1".into(),
            action: SessionAction::Stop,
        })
        .await;

        let frames = app
            .snaps_until("session_stopped", |s| {
                s.change
                    .as_ref()
                    .is_some_and(|c| c.reason == QueueChangeReason::SessionStopped)
            })
            .await;
        let last = frames.last().unwrap();
        assert_eq!(last.change.as_ref().unwrap().ids, [a, b]);
        assert!(last.entries.is_empty() && last.held.is_none());
        settle().await;
        assert!(fake.user_texts().iter().all(|t| !t.contains("gone")));
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// the sign-in hold
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_held_message_is_in_the_view_without_text_and_take_back_returns_it_as_typed() {
    run(|mut rig| async move {
        let (fake, entry) = rig.hold("cody-h1", "HELD-AS-TYPED").await;
        let mut app = rig.app(vec![]).await;
        let first = app.watch("cody-h1").await;
        let held = first.held.expect("the held message is in the view");
        assert_eq!(Some(held.hold_id.clone()), entry.hold_id);
        assert!(held.can_take_back);
        let raw = serde_json::to_string(&first.entries).unwrap();
        assert!(
            !raw.contains("HELD-AS-TYPED"),
            "the view carries no text for it"
        );

        // Queued behind the hold: visible, and take-back-able.
        let behind = rig.queue_typed("cody-h1", "BEHIND-THE-HOLD", &[]);
        let snap = app.snaps_until("behind", |s| s.entries.len() == 1).await;
        assert_eq!(snap.last().unwrap().texts(), ["BEHIND-THE-HOLD"]);

        let (code, text, _) = app.take_back("cody-h1", &held.id).await;
        assert_eq!(code, QueueResultCode::TakenBack);
        assert_eq!(text.as_deref(), Some("HELD-AS-TYPED"));
        let gone = app.snaps_until("no held", |s| s.held.is_none()).await;
        assert_eq!(gone.last().unwrap().texts(), ["BEHIND-THE-HOLD"]);
        let (phase, hold_id) = {
            let mgr = rig.mgr.lock().unwrap();
            match mgr.login_snapshot() {
                ServerMsg::ClaudeLoginState { sessions, .. } => {
                    let s = sessions.into_iter().find(|s| s.tag == "cody-h1").unwrap();
                    (s.phase, s.hold_id)
                }
                other => panic!("{other:?}"),
            }
        };
        assert_eq!(phase, ClaudeLoginPhase::PausedNoHold);
        assert!(hold_id.is_none());

        assert_eq!(
            app.take_back("cody-h1", &behind).await.0,
            QueueResultCode::TakenBack
        );
        settle().await;
        assert_eq!(
            fake.user_texts().len(),
            1,
            "only the one write the hold was made of; nothing for the take-back"
        );
    });
}

// ═════════════════════════════════════════════════════════════════════════════
// logging
// ═════════════════════════════════════════════════════════════════════════════

#[test]
fn a_canary_pushed_through_queue_take_back_remove_refusal_and_stop_never_reaches_a_log() {
    logs::install();
    logs::clear();
    run(|mut rig| async move {
        let (_fake, _hold) = rig.busy("cody-l1").await;
        let mut app = rig.app(vec![]).await;
        let mut agent = rig.agent(vec![]).await;
        let mut tcp = rig.tcp(vec![]).await;
        app.watch("cody-l1").await;
        let canary = "CANARY-7f3a91c2";
        let image = "/tmp/CANARY-image-7f3a91c2.png";

        app.say("cody-l1", canary, &[image], Some("ref-canary-ok"))
            .await;
        let snap = app.snaps_until("queued", |s| s.entries.len() == 1).await;
        let id = snap.last().unwrap().entries[0].id.clone();
        assert_eq!(
            app.take_back("cody-l1", &id).await.0,
            QueueResultCode::TakenBack
        );

        app.say("cody-l1", canary, &[image], None).await;
        let snap = app
            .snaps_until("queued again", |s| s.entries.len() == 1)
            .await;
        let id = snap.last().unwrap().entries[0].id.clone();
        agent.verb(true, "cody-l1", &id, "req-l", Some("n")).await;
        agent.result("req-l").await;
        tcp.verb(true, "cody-l1", &id, "req-l", Some("n")).await;
        tcp.next("the network refusal", |m| {
            matches!(m, ServerMsg::Error { .. })
        })
        .await;
        assert_eq!(app.remove("cody-l1", &id).await, QueueResultCode::Removed);

        app.say("cody-l1", canary, &[image], None).await;
        app.snaps_until("queued a third time", |s| s.entries.len() == 1)
            .await;
        app.send(&ClientMsg::SessionInterrupt {
            tag: "cody-l1".into(),
        })
        .await;
        app.next("returned", |m| {
            matches!(m, ServerMsg::SessionQueueReturned { .. })
        })
        .await;

        settle().await;
        let lines = logs::all();
        assert!(!lines.is_empty(), "the capture works");
        for line in &lines {
            assert!(
                !line.contains("CANARY"),
                "text or a path reached a log: {line}"
            );
        }
        assert!(
            lines
                .iter()
                .any(|l| l.contains("session queue verb refused") && l.contains("not_allowed")),
            "a refusal logs a code"
        );
    });
}
