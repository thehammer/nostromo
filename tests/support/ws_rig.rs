//! A real daemon front end for the WebSocket transport and device pairing tests
//! (`#[path]` include, like the other `tests/support` files).
//!
//! `Rig` binds what `nostromd` binds: a Unix socket, the legacy TCP listener and
//! the WebSocket listener, all on a tempdir or port 0, with the device registry
//! in the tempdir (never `~/.nostromo/devices.json`). `Conn` is one client
//! connection over either transport. It keeps every frame it reads, so a test
//! can assert on what arrived, what did not, and what the raw JSON held.
//!
//! The helpers know the wire contract only: JSON frames, close codes, the
//! pairing proof formula. They do not reach into the daemon's modules for
//! anything but the types that make up that contract.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use futures::{SinkExt, StreamExt};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::device_hub::DeviceHub;
use nostromo::ipc::devices::{DeviceKind, DeviceRegistry, DeviceSummary, SatelliteAdmin};
use nostromo::ipc::peer_verify::{testing::FakePeerVerifier, MAC_APP_CLIENT_KIND};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic, PROTOCOL_VERSION};
use nostromo::ipc::server::Server;
use nostromo::ipc::SessionManager;
use sha2::{Digest, Sha256};
use tempfile::TempDir;
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

/// How long any single read waits before the test gives up.
pub const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// The close code the daemon uses for "this server refuses you".
pub const CLOSE_UNAUTHORIZED: u16 = 4001;

// ── process-wide environment ──────────────────────────────────────────────────

/// Tests that change process environment variables (a session needs `HOME`, the
/// fake CLI and the guard binary) take the write side; every other rig takes the
/// read side, so they run alongside each other but never alongside that one.
static ENV: RwLock<()> = RwLock::const_new(());

enum EnvGuard {
    Shared(#[allow(dead_code)] RwLockReadGuard<'static, ()>),
    Exclusive(#[allow(dead_code)] RwLockWriteGuard<'static, ()>),
}

// ── captured log output ───────────────────────────────────────────────────────

static LOGS: OnceLock<Arc<Mutex<Vec<u8>>>> = OnceLock::new();

#[derive(Clone)]
struct Sink(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for Sink {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Sink {
    type Writer = Sink;

    fn make_writer(&'a self) -> Sink {
        self.clone()
    }
}

/// Send every `tracing` event of this process (every level, no timestamps) to a
/// buffer a test can read with [`captured_logs`]. Once per process.
pub fn install_log_capture() {
    LOGS.get_or_init(|| {
        let buf = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::fmt()
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .without_time()
            .with_writer(Sink(Arc::clone(&buf)))
            .finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
        buf
    });
}

/// Everything logged so far in this process (all tests in the binary share it).
pub fn captured_logs() -> String {
    let buf = LOGS.get().expect("install_log_capture ran");
    let bytes = buf.lock().unwrap();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// True when `needle` appears in `haystack` as a whole run of digits, so a six
/// digit pairing code is not found inside a longer number.
pub fn contains_digit_run(haystack: &str, needle: &str) -> bool {
    let bytes = haystack.as_bytes();
    let mut from = 0;
    while let Some(at) = haystack[from..].find(needle) {
        let start = from + at;
        let end = start + needle.len();
        let before = start == 0 || !bytes[start - 1].is_ascii_digit();
        let after = end == bytes.len() || !bytes[end].is_ascii_digit();
        if before && after {
            return true;
        }
        from = start + 1;
    }
    false
}

// ── the contract's own arithmetic, written independently of the daemon ────────

/// base64url (no padding) of SHA-256(`token`): what the registry may store.
pub fn token_hash(token: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(token.as_bytes()))
}

/// HMAC-SHA256, RFC 2104.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    const BLOCK: usize = 64;
    let mut k = [0u8; BLOCK];
    if key.len() > BLOCK {
        k[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        k[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    inner.update(k.map(|b| b ^ 0x36));
    inner.update(msg);
    let inner = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(k.map(|b| b ^ 0x5c));
    outer.update(inner);
    outer.finalize().into()
}

/// The re-pair proof a phone computes (D6): base64url of
/// HMAC-SHA256(key = SHA-256(token), msg = challenge || code), `code` being the
/// six digits.
pub fn proof_for(token: &str, challenge: &str, code: &str) -> String {
    let key = Sha256::digest(token.as_bytes());
    let mut msg = Vec::new();
    msg.extend_from_slice(challenge.as_bytes());
    msg.extend_from_slice(code.as_bytes());
    URL_SAFE_NO_PAD.encode(hmac_sha256(&key, &msg))
}

/// A six-digit code that is not `real`.
pub fn wrong_code(real: &str) -> String {
    if real == "000000" { "000001" } else { "000000" }.to_string()
}

// ── the rig ───────────────────────────────────────────────────────────────────

pub struct Rig {
    pub server: Server,
    pub socket_path: PathBuf,
    pub tcp_port: u16,
    pub ws_port: u16,
    pub hub: Arc<DeviceHub>,
    pub registry: Arc<DeviceRegistry>,
    pub registry_path: PathBuf,
    pub session_mgr: Arc<Mutex<SessionManager>>,
    pub tmp: TempDir,
    _env: EnvGuard,
}

impl Drop for Rig {
    fn drop(&mut self) {
        self.session_mgr
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

impl Rig {
    /// The usual rig: pairing codes live five minutes.
    pub async fn new() -> Self {
        Self::build(Duration::from_secs(300), false).await
    }

    /// A rig whose pairing codes expire after `ttl`.
    pub async fn with_ttl(ttl: Duration) -> Self {
        Self::build(ttl, false).await
    }

    /// A rig with explicit WebSocket connection limits.
    pub async fn with_limits(limits: nostromo::ipc::ws::WsLimits) -> Self {
        Self::build_with(Duration::from_secs(300), false, limits).await
    }

    /// A rig that can run sessions: it owns the process environment for the
    /// test (`HOME`, the approvals directory, the guard binary).
    pub async fn with_sessions() -> Self {
        Self::build(Duration::from_secs(300), true).await
    }

    async fn build(ttl: Duration, sessions: bool) -> Self {
        Self::build_with(ttl, sessions, nostromo::ipc::ws::WsLimits::default()).await
    }

    async fn build_with(
        ttl: Duration,
        sessions: bool,
        limits: nostromo::ipc::ws::WsLimits,
    ) -> Self {
        install_log_capture();
        let env = if sessions {
            EnvGuard::Exclusive(ENV.write().await)
        } else {
            EnvGuard::Shared(ENV.read().await)
        };
        let tmp = TempDir::new().expect("tempdir");
        if sessions {
            let home = tmp.path().join("home");
            std::fs::create_dir_all(&home).unwrap();
            std::env::set_var("HOME", &home);
            std::env::set_var(
                nostromo::approvals::APPROVALS_DIR_ENV,
                tmp.path().join("approvals"),
            );
            std::env::set_var(
                nostromo::approvals::guard::GUARD_BIN_ENV,
                env!("CARGO_BIN_EXE_nostromo-guard"),
            );
        }
        let socket_path = tmp.path().join("test.sock");
        let perri = tmp.path().join("perri-state");
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("session-ids.json"),
        )));
        let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
        // Every Unix connection can be the Mac app, if its Hello claims it.
        let server = Server::bind(
            &socket_path,
            Arc::clone(&session_mgr),
            perri.clone(),
            Arc::clone(&decisions),
            Arc::new(FakePeerVerifier::always_app()),
            false,
            nostromo::terminal::TerminalManager::in_memory(),
        )
        .expect("bind the unix socket");

        let tcp = TcpListener::bind("127.0.0.1:0").await.expect("bind tcp");
        let tcp_port = tcp.local_addr().unwrap().port();
        server.bind_tcp(
            tcp,
            Arc::clone(&session_mgr),
            perri.clone(),
            Arc::clone(&decisions),
        );

        let ws = TcpListener::bind("127.0.0.1:0").await.expect("bind ws");
        let ws_port = ws.local_addr().unwrap().port();
        let registry_path = tmp.path().join("devices.json");
        let registry = Arc::new(DeviceRegistry::load(&registry_path).expect("a new registry"));
        let hub = DeviceHub::new(Arc::clone(&registry), ttl, "127.0.0.1".into(), ws_port);
        server.bind_ws_with_limits(
            ws,
            Arc::clone(&hub),
            Arc::clone(&session_mgr),
            perri,
            decisions,
            limits,
        );

        Rig {
            server,
            socket_path,
            tcp_port,
            ws_port,
            hub,
            registry,
            registry_path,
            session_mgr,
            tmp,
            _env: env,
        }
    }

    /// Mint a phone's credential straight in the registry (set-up for tests
    /// that are about the transport, not about pairing).
    pub fn mint_device(&self, name: &str) -> Minted {
        let r = self
            .registry
            .redeem(name, DeviceKind::Iphone, None, None)
            .expect("redeem");
        Minted {
            device_id: r.device_id,
            token: r.token,
            name: r.name,
        }
    }

    /// A Unix connection that has done Hello, Welcome, Subscribe and a sync.
    /// `as_app` makes its Hello claim to be the Mac app (the fake verifier then
    /// agrees); otherwise it is an ordinary local process, like the CLI.
    pub async fn unix(&self, topics: Vec<Topic>, as_app: bool) -> Conn {
        self.unix_with(topics, as_app, &[]).await
    }

    pub async fn unix_with(&self, topics: Vec<Topic>, as_app: bool, caps: &[&str]) -> Conn {
        let stream = UnixStream::connect(&self.socket_path)
            .await
            .expect("unix connect");
        let mut conn = Conn::new(Io::Unix(stream));
        conn.handshake(caps, topics, as_app).await;
        conn
    }

    /// A Unix connection to some other daemon's socket (a satellite's), after
    /// Hello, Welcome, Subscribe and a sync.
    pub async fn unix_at(path: &std::path::Path, topics: Vec<Topic>) -> Conn {
        let stream = UnixStream::connect(path).await.expect("unix connect");
        let mut conn = Conn::new(Io::Unix(stream));
        conn.handshake(&[], topics, false).await;
        conn
    }

    /// A raw Unix connection with no handshake yet.
    pub async fn unix_raw(&self) -> Conn {
        let stream = UnixStream::connect(&self.socket_path)
            .await
            .expect("unix connect");
        Conn::new(Io::Unix(stream))
    }

    pub async fn tcp_raw(&self) -> Conn {
        let stream = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        Conn::new(Io::Tcp(stream))
    }

    /// A WebSocket with no token (a pairing socket).
    pub async fn pairing_socket(&self) -> Conn {
        Conn::ws(self.ws_port, None).await
    }

    /// A WebSocket carrying `token`, Hello and Subscribe done.
    pub async fn device(&self, token: &str, caps: &[&str], topics: Vec<Topic>) -> Conn {
        let mut conn = Conn::ws(self.ws_port, Some(token)).await;
        conn.handshake(caps, topics, false).await;
        conn
    }

    /// A WebSocket carrying `token`, nothing sent yet.
    pub async fn device_raw(&self, token: &str) -> Conn {
        Conn::ws(self.ws_port, Some(token)).await
    }

    /// Redeem `code` on a fresh pairing socket: the one reply, and what follows
    /// it (the close code, if the socket was closed).
    pub async fn redeem(
        &self,
        code: &str,
        name: &str,
        kind: DeviceKind,
        replace: bool,
    ) -> (ServerMsg, Option<u16>) {
        let mut sock = self.pairing_socket().await;
        sock.send(&ClientMsg::Pair {
            code: code.to_string(),
            name: name.to_string(),
            kind,
            replace,
        })
        .await;
        let reply = sock
            .next_matching("the reply to Pair", |m| {
                matches!(m, ServerMsg::Paired { .. } | ServerMsg::PairRefused { .. })
            })
            .await;
        let close = sock.expect_close().await;
        (reply, close)
    }

    /// Pair a new phone through the admin client: a code, then `Pair`.
    pub async fn pair_phone(&self, admin: &mut Conn, name: &str) -> Minted {
        let pairing = admin.pair_start(None).await;
        let (reply, _) = self
            .redeem(&pairing.code, name, DeviceKind::Iphone, false)
            .await;
        match reply {
            ServerMsg::Paired {
                device_id,
                token,
                name,
                ..
            } => Minted {
                device_id,
                token: token.0,
                name,
            },
            other => panic!("expected Paired, got {other:?}"),
        }
    }

    /// Poll `cond` every 20 ms until it holds (or fail after `READ_TIMEOUT`).
    pub async fn wait_until(what: &str, mut cond: impl FnMut() -> bool) {
        let start = Instant::now();
        while !cond() {
            assert!(
                start.elapsed() < READ_TIMEOUT,
                "timed out waiting for {what}"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

/// A device the rig minted or paired: id, plaintext token, final name.
#[derive(Debug, Clone)]
pub struct Minted {
    pub device_id: String,
    pub token: String,
    pub name: String,
}

/// An open pairing, as the admin client was told about it.
#[derive(Debug, Clone)]
pub struct Pairing {
    pub pairing_id: String,
    pub code: String,
    pub server_url: String,
    pub request_id: String,
}

// ── one connection ────────────────────────────────────────────────────────────

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

pub enum Io {
    Unix(UnixStream),
    Tcp(TcpStream),
    Ws(Box<WsStream>),
}

/// What one read from the socket produced.
enum Incoming {
    Text(String),
    Closed(Option<u16>),
}

static REQUEST_IDS: AtomicU64 = AtomicU64::new(1);

pub fn request_id() -> String {
    format!("req-{}", REQUEST_IDS.fetch_add(1, Ordering::SeqCst))
}

pub struct Conn {
    io: Io,
    /// Frames read and not yet taken by the test, in arrival order.
    pub inbox: Vec<ServerMsg>,
    /// Every frame read, as the raw JSON text the daemon sent.
    pub raw: Vec<String>,
    /// Set once the socket is closed: the close code, if the peer sent one.
    pub closed: Option<Option<u16>>,
    /// The `Welcome` of a completed handshake.
    pub welcome: Option<ServerMsg>,
}

impl Conn {
    fn new(io: Io) -> Self {
        Conn {
            io,
            inbox: Vec::new(),
            raw: Vec::new(),
            closed: None,
            welcome: None,
        }
    }

    /// Connect a WebSocket, with an `Authorization: Bearer` header if `token` is given.
    #[allow(clippy::result_large_err)] // tungstenite's own error type
    pub async fn try_ws(
        port: u16,
        token: Option<&str>,
        path: &str,
    ) -> Result<Conn, tokio_tungstenite::tungstenite::Error> {
        let mut req = format!("ws://127.0.0.1:{port}{path}")
            .into_client_request()
            .expect("a request");
        if let Some(token) = token {
            req.headers_mut().insert(
                "Authorization",
                HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
            );
        }
        let (ws, _resp) = tokio_tungstenite::connect_async(req).await?;
        Ok(Conn::new(Io::Ws(Box::new(ws))))
    }

    /// Like [`Conn::try_ws`] with an extra request header.
    #[allow(clippy::result_large_err)] // tungstenite's own error type
    pub async fn try_ws_with_header(
        port: u16,
        token: Option<&str>,
        header: (&'static str, &str),
    ) -> Result<Conn, tokio_tungstenite::tungstenite::Error> {
        let mut req = format!("ws://127.0.0.1:{port}/")
            .into_client_request()
            .expect("a request");
        if let Some(token) = token {
            req.headers_mut().insert(
                "Authorization",
                HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
            );
        }
        req.headers_mut()
            .insert(header.0, HeaderValue::from_str(header.1).unwrap());
        let (ws, _resp) = tokio_tungstenite::connect_async(req).await?;
        Ok(Conn::new(Io::Ws(Box::new(ws))))
    }

    pub async fn ws(port: u16, token: Option<&str>) -> Conn {
        Self::try_ws(port, token, "/")
            .await
            .expect("the WebSocket upgrade completes")
    }

    // ── writing ───────────────────────────────────────────────────────────────

    pub async fn send(&mut self, msg: &ClientMsg) {
        self.send_text(serde_json::to_string(msg).unwrap()).await;
    }

    pub async fn send_text(&mut self, text: String) {
        match &mut self.io {
            Io::Unix(s) => write_frame(s, text.as_bytes()).await.expect("write frame"),
            Io::Tcp(s) => write_frame(s, text.as_bytes()).await.expect("write frame"),
            Io::Ws(ws) => ws
                .send(Message::Text(text))
                .await
                .expect("send a text frame"),
        }
    }

    /// A text frame the peer may refuse and close on, so a failed send is not
    /// an error here.
    pub async fn try_send_text(&mut self, text: String) -> bool {
        match &mut self.io {
            Io::Ws(ws) => ws.send(Message::Text(text)).await.is_ok(),
            _ => panic!("only a WebSocket carries a raw text frame"),
        }
    }

    pub async fn send_binary(&mut self, bytes: Vec<u8>) {
        match &mut self.io {
            Io::Ws(ws) => ws.send(Message::Binary(bytes)).await.expect("send binary"),
            _ => panic!("only a WebSocket carries a binary frame"),
        }
    }

    // ── reading ───────────────────────────────────────────────────────────────

    async fn read_incoming(&mut self) -> Incoming {
        match &mut self.io {
            Io::Unix(s) => match read_frame(s).await {
                Ok(bytes) => Incoming::Text(String::from_utf8(bytes).expect("utf8 frame")),
                Err(_) => Incoming::Closed(None),
            },
            Io::Tcp(s) => match read_frame(s).await {
                Ok(bytes) => Incoming::Text(String::from_utf8(bytes).expect("utf8 frame")),
                Err(_) => Incoming::Closed(None),
            },
            Io::Ws(ws) => loop {
                match ws.next().await {
                    Some(Ok(Message::Text(t))) => return Incoming::Text(t),
                    Some(Ok(Message::Close(frame))) => {
                        return Incoming::Closed(
                            frame.map(|CloseFrame { code, .. }| u16::from(code)),
                        )
                    }
                    Some(Ok(Message::Binary(_))) => panic!("the daemon sent a binary frame"),
                    Some(Ok(_)) => continue, // ping, pong
                    Some(Err(_)) | None => return Incoming::Closed(None),
                }
            },
        }
    }

    /// Read one more frame into the inbox (or note the close).
    async fn pull(&mut self, what: &str) {
        let incoming = tokio::time::timeout(READ_TIMEOUT, self.read_incoming())
            .await
            .unwrap_or_else(|_| {
                panic!(
                    "timed out waiting for {what}; unread so far: {:#?}",
                    self.inbox
                )
            });
        match incoming {
            Incoming::Text(text) => {
                let msg: ServerMsg = serde_json::from_str(&text)
                    .unwrap_or_else(|e| panic!("an undecodable frame ({e}): {text}"));
                self.raw.push(text);
                self.inbox.push(msg);
            }
            Incoming::Closed(code) => self.closed = Some(code),
        }
    }

    /// The first unread frame `pred` accepts (earlier ones stay in the inbox).
    pub async fn next_matching(
        &mut self,
        what: &str,
        pred: impl Fn(&ServerMsg) -> bool,
    ) -> ServerMsg {
        loop {
            if let Some(i) = self.inbox.iter().position(&pred) {
                return self.inbox.remove(i);
            }
            if let Some(code) = self.closed {
                panic!(
                    "closed ({code:?}) while waiting for {what}; unread: {:#?}",
                    self.inbox
                );
            }
            self.pull(what).await;
        }
    }

    /// Take everything unread.
    pub fn take_all(&mut self) -> Vec<ServerMsg> {
        std::mem::take(&mut self.inbox)
    }

    /// Ping, then wait for the Pong: afterwards the inbox holds everything the
    /// daemon sent that this connection was going to receive before it.
    pub async fn sync(&mut self) {
        self.send(&ClientMsg::Ping).await;
        self.next_matching("the Pong", |m| matches!(m, ServerMsg::Pong))
            .await;
    }

    /// Read until the socket is closed; the close code if the peer sent one.
    /// Frames that arrive first stay in the inbox.
    pub async fn expect_close(&mut self) -> Option<u16> {
        while self.closed.is_none() {
            self.pull("the connection to close").await;
        }
        self.closed.unwrap()
    }

    /// [`expect_close`](Self::expect_close), failing if it takes longer than `within`.
    pub async fn expect_close_within(&mut self, within: Duration) -> Option<u16> {
        tokio::time::timeout(within, self.expect_close())
            .await
            .unwrap_or_else(|_| panic!("not closed within {within:?}; unread: {:#?}", self.inbox))
    }

    // ── handshake ─────────────────────────────────────────────────────────────

    pub fn hello(caps: &[&str], as_app: bool) -> ClientMsg {
        ClientMsg::Hello {
            capabilities: caps.iter().map(|c| c.to_string()).collect(),
            client_id: "ws-rig".into(),
            protocol_version: PROTOCOL_VERSION,
            // Claimed over every transport: the claim never lifts a network peer.
            client_kind: as_app.then(|| MAC_APP_CLIENT_KIND.to_string()),
            role: None,
        }
    }

    pub fn subscribe(topics: Vec<Topic>) -> ClientMsg {
        ClientMsg::Subscribe {
            topics,
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
            resume: Default::default(),
            seq_epoch: None,
        }
    }

    /// Hello, Welcome, Subscribe, sync. The Welcome is kept in `welcome`; the
    /// attach-time replay is left in the inbox.
    pub async fn handshake(&mut self, caps: &[&str], topics: Vec<Topic>, as_app: bool) {
        self.send(&Self::hello(caps, as_app)).await;
        let welcome = self
            .next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await;
        self.welcome = Some(welcome);
        self.send(&Self::subscribe(topics)).await;
        self.sync().await;
    }

    /// The `features` of the Welcome.
    pub fn features(&self) -> Vec<String> {
        match &self.welcome {
            Some(ServerMsg::Welcome { features, .. }) => features.clone(),
            other => panic!("no Welcome yet: {other:?}"),
        }
    }

    // ── device side of pairing ────────────────────────────────────────────────

    /// `PairCheck`, and the one reply.
    pub async fn pair_check(&mut self, code: &str, proof: Option<&str>) -> ServerMsg {
        self.send(&ClientMsg::PairCheck {
            code: code.to_string(),
            proof: proof.map(str::to_string),
        })
        .await;
        self.next_matching("the reply to PairCheck", |m| {
            matches!(
                m,
                ServerMsg::PairOffer { .. } | ServerMsg::PairRefused { .. }
            )
        })
        .await
    }

    /// A `PairCheck` that must be answered with an offer; its challenge.
    pub async fn challenge_for(&mut self, code: &str) -> String {
        match self.pair_check(code, None).await {
            ServerMsg::PairOffer { challenge, .. } => challenge,
            other => panic!("expected a PairOffer, got {other:?}"),
        }
    }

    // ── admin side of pairing ─────────────────────────────────────────────────

    pub async fn pair_start(&mut self, name_hint: Option<&str>) -> Pairing {
        self.pair_start_as(name_hint, None, None).await
    }

    pub async fn pair_start_as(
        &mut self,
        name_hint: Option<&str>,
        satellite: Option<&str>,
        admin: Option<SatelliteAdmin>,
    ) -> Pairing {
        let rid = request_id();
        self.send(&ClientMsg::DevicePairStart {
            request_id: rid.clone(),
            name_hint: name_hint.map(str::to_string),
            satellite: satellite.map(str::to_string),
            admin,
            egress: None,
            origin: None,
        })
        .await;
        let reply = self
            .next_matching(
                "DevicePairing",
                |m| matches!(m, ServerMsg::DevicePairing { request_id, .. } if *request_id == rid),
            )
            .await;
        match reply {
            ServerMsg::DevicePairing {
                pairing_id,
                code,
                server_url,
                ..
            } => Pairing {
                pairing_id,
                code,
                server_url,
                request_id: rid,
            },
            _ => unreachable!(),
        }
    }

    /// The outcome of `pairing`, within `within`.
    pub async fn outcome_of(&mut self, pairing: &Pairing, within: Duration) -> ServerMsg {
        let id = pairing.pairing_id.clone();
        tokio::time::timeout(
            within,
            self.next_matching("a pairing outcome", move |m| {
                matches!(m, ServerMsg::DevicePairOutcome { pairing_id, .. } if *pairing_id == id)
            }),
        )
        .await
        .unwrap_or_else(|_| panic!("no outcome for {} within {within:?}", pairing.pairing_id))
    }

    /// `DeviceList`: phones and iPads, then satellite Macs.
    pub async fn device_list(&mut self) -> (Vec<DeviceSummary>, Vec<DeviceSummary>) {
        // A `Devices` broadcast already waiting is older than this answer.
        self.inbox
            .retain(|m| !matches!(m, ServerMsg::Devices { .. }));
        self.send(&ClientMsg::DeviceList {
            request_id: request_id(),
        })
        .await;
        match self
            .next_matching("Devices", |m| matches!(m, ServerMsg::Devices { .. }))
            .await
        {
            ServerMsg::Devices { devices, hosts } => (devices, hosts),
            _ => unreachable!(),
        }
    }

    /// `DeviceRevoke`: the `DeviceRevoked` or `DeviceAdminError` that answers it.
    pub async fn revoke(&mut self, device: &str) -> ServerMsg {
        let rid = request_id();
        self.send(&ClientMsg::DeviceRevoke {
            request_id: rid.clone(),
            device: device.to_string(),
        })
        .await;
        self.next_matching("the answer to DeviceRevoke", move |m| {
            matches!(
                m,
                ServerMsg::DeviceRevoked { request_id, .. }
                    | ServerMsg::DeviceAdminError { request_id, .. } if *request_id == rid
            )
        })
        .await
    }
}

/// The summary named `name` (active or revoked: the first match).
pub fn named<'a>(list: &'a [DeviceSummary], name: &str) -> &'a DeviceSummary {
    list.iter()
        .find(|d| d.name == name)
        .unwrap_or_else(|| panic!("no device named {name:?} in {list:#?}"))
}
