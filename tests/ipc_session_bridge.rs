//! Behavioural tests for the "tools offline" health signal.
//!
//! A session whose `nostromo-mcp-bridge` lost its connection to the daemon keeps
//! running but cannot call any `mcp__nostromo__*` tool. The daemon tells the app:
//!
//!   * `session_bridge {tag, connected}` is broadcast when a tag's last live
//!     bridge is lost (`connected:false`) and when a bridge comes back for a tag
//!     that had lost them all (`connected:true`). The first bridge a tag ever has
//!     is NOT announced (the app holds no "offline" to clear and learns the state
//!     on attach), nor are the transitions in between, nor an unidentified caller;
//!   * `session_list_resp` entries carry `mcp_bridge_connected` once a bridge has
//!     ever identified as that tag, and omit it otherwise (wire additivity);
//!   * attaching to a session replays the current `session_bridge` when known;
//!   * `session_bridge` follows the same per-focus gating as `session_state`: a
//!     network peer never gets it for a sensitive tag.
//!
//! The first group pins the wire shape, the second the broadcast rules against
//! the shared MCP state, and the third drives the real MCP socket, the real IPC
//! server and a fake `claude` end to end. No real daemon, no real `claude`.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use nostromo::ipc::peer_verify::{testing::FakePeerVerifier, MAC_APP_CLIENT_KIND};
use nostromo::ipc::{
    codec::{read_frame, write_frame},
    decisions::DecisionRegistry,
    pane_registry::PaneRegistry,
    protocol::{ClientMsg, ServerMsg, SessionInfo, Topic, PROTOCOL_VERSION},
    server::Server,
    session_manager::CLAUDE_BIN_ENV,
    stream_json::SessionState,
    SessionManager,
};
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpStream, UnixStream};
use tokio::sync::broadcast;

// ── wire shape ────────────────────────────────────────────────────────────────

fn session_info(bridge: Option<bool>) -> SessionInfo {
    SessionInfo {
        tag: "cody-core-1".into(),
        agent_name: "cody".into(),
        view_name: "Cody".into(),
        session_id: Some("sid-1".into()),
        alive: true,
        remote_control: false,
        state: SessionState::Idle,
        stop_reason: None,
        mcp_bridge_connected: bridge,
    }
}

#[test]
fn session_bridge_has_the_exact_snake_case_wire_shape() {
    let down = serde_json::to_value(ServerMsg::SessionBridge {
        tag: "cody-core-1".into(),
        connected: false,
    })
    .unwrap();
    assert_eq!(
        down,
        json!({"type": "session_bridge", "tag": "cody-core-1", "connected": false})
    );

    let up = serde_json::to_value(ServerMsg::SessionBridge {
        tag: "cody-core-1".into(),
        connected: true,
    })
    .unwrap();
    assert_eq!(
        up,
        json!({"type": "session_bridge", "tag": "cody-core-1", "connected": true})
    );
}

#[test]
fn session_bridge_decodes_from_the_wire_form() {
    for connected in [true, false] {
        let frame = json!({"type": "session_bridge", "tag": "perri", "connected": connected});
        let msg: ServerMsg = serde_json::from_value(frame).expect("decode session_bridge");
        match msg {
            ServerMsg::SessionBridge { tag, connected: c } => {
                assert_eq!(tag, "perri");
                assert_eq!(c, connected);
            }
            other => panic!("expected SessionBridge, got {other:?}"),
        }
    }
}

#[test]
fn session_info_without_a_known_bridge_omits_the_key_on_the_wire() {
    let wire = serde_json::to_value(session_info(None)).unwrap();
    assert!(
        wire.get("mcp_bridge_connected").is_none(),
        "an unknown bridge must be absent, not null, so older peers see no change: {wire}"
    );
}

#[test]
fn session_info_reports_a_known_bridge_on_the_wire() {
    for connected in [true, false] {
        let wire = serde_json::to_value(session_info(Some(connected))).unwrap();
        assert_eq!(wire["mcp_bridge_connected"], json!(connected));
    }
}

#[test]
fn session_info_from_an_older_daemon_without_the_key_decodes_as_unknown() {
    let mut wire = serde_json::to_value(session_info(Some(true))).unwrap();
    wire.as_object_mut().unwrap().remove("mcp_bridge_connected");
    let info: SessionInfo = serde_json::from_value(wire).expect("decode without the key");
    assert_eq!(info.mcp_bridge_connected, None);
}

#[test]
fn session_info_round_trips_every_bridge_state() {
    for bridge in [None, Some(true), Some(false)] {
        let wire = serde_json::to_string(&session_info(bridge)).unwrap();
        let back: SessionInfo = serde_json::from_str(&wire).unwrap();
        assert_eq!(back.mcp_bridge_connected, bridge);
        assert_eq!(back.tag, "cody-core-1");
    }
}

// ── broadcast rules on the shared MCP state ───────────────────────────────────

struct DaemonState {
    state: McpSharedState,
    rx: broadcast::Receiver<ServerMsg>,
    _dir: TempDir,
}

fn daemon_state() -> DaemonState {
    let dir = TempDir::new().unwrap();
    let (broadcast_tx, rx) = broadcast::channel::<ServerMsg>(64);
    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        ))),
        session_mgr: Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        ))),
        broadcast_tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(DecisionRegistry::default())),
        tickets: Default::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    });
    DaemonState {
        state,
        rx,
        _dir: dir,
    }
}

/// Everything broadcast so far, as `(tag, connected)` for bridge frames. Any
/// other frame fails the test: nothing here should broadcast anything else.
fn drain_bridge_frames(rx: &mut broadcast::Receiver<ServerMsg>) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    loop {
        match rx.try_recv() {
            Ok(ServerMsg::SessionBridge { tag, connected }) => out.push((tag, connected)),
            Ok(other) => panic!("unexpected broadcast {other:?}"),
            Err(broadcast::error::TryRecvError::Empty) => return out,
            Err(e) => panic!("broadcast receiver failed: {e:?}"),
        }
    }
}

fn frame(tag: &str, connected: bool) -> (String, bool) {
    (tag.to_string(), connected)
}

#[test]
fn the_first_bridge_for_a_pty_announces_nothing() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    assert!(
        drain_bridge_frames(&mut d.rx).is_empty(),
        "the app has no offline state to clear for a pty's first bridge"
    );
    assert_eq!(d.state.bridges.connected("cody-a"), Some(true));
}

#[test]
fn a_second_concurrent_bridge_for_the_same_pty_announces_nothing() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_opened("cody-a");
    assert!(drain_bridge_frames(&mut d.rx).is_empty());
    assert_eq!(d.state.bridges.live("cody-a"), 2);
}

#[test]
fn closing_a_bridge_that_is_not_the_last_announces_nothing() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_opened("cody-a");
    drain_bridge_frames(&mut d.rx);

    d.state.bridge_closed("cody-a");
    assert!(
        drain_bridge_frames(&mut d.rx).is_empty(),
        "one bridge is still live: the tools are not offline"
    );
}

#[test]
fn the_last_bridge_closing_announces_tools_offline() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_opened("cody-a");
    d.state.bridge_closed("cody-a");
    drain_bridge_frames(&mut d.rx);

    d.state.bridge_closed("cody-a");
    assert_eq!(drain_bridge_frames(&mut d.rx), vec![frame("cody-a", false)]);
}

#[test]
fn a_lone_bridge_closing_announces_tools_offline() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_closed("cody-a");
    assert_eq!(drain_bridge_frames(&mut d.rx), vec![frame("cody-a", false)]);
}

#[test]
fn a_bridge_that_reconnects_after_loss_announces_online_again() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_closed("cody-a");
    d.state.bridge_opened("cody-a");
    assert_eq!(
        drain_bridge_frames(&mut d.rx),
        vec![frame("cody-a", false), frame("cody-a", true)],
        "loss is announced, the first-ever open is not, the return is"
    );
}

#[test]
fn a_second_bridge_alongside_a_reconnected_one_announces_nothing() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_closed("cody-a");
    d.state.bridge_opened("cody-a");
    drain_bridge_frames(&mut d.rx);

    d.state.bridge_opened("cody-a");
    assert!(drain_bridge_frames(&mut d.rx).is_empty());
}

#[test]
fn every_loss_and_return_cycle_is_announced() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    for _ in 0..3 {
        d.state.bridge_closed("cody-a");
        d.state.bridge_opened("cody-a");
    }
    assert_eq!(
        drain_bridge_frames(&mut d.rx),
        vec![
            frame("cody-a", false),
            frame("cody-a", true),
            frame("cody-a", false),
            frame("cody-a", true),
            frame("cody-a", false),
            frame("cody-a", true),
        ]
    );
}

#[test]
fn bridges_of_different_ptys_are_announced_independently() {
    let mut d = daemon_state();
    d.state.bridge_opened("cody-a");
    d.state.bridge_opened("cody-b");
    d.state.bridge_closed("cody-a");
    assert_eq!(
        drain_bridge_frames(&mut d.rx),
        vec![frame("cody-a", false)],
        "b's first bridge is not announced and a's loss does not involve b"
    );

    // a's return is announced; b, still connected, is untouched by it.
    d.state.bridge_opened("cody-a");
    assert_eq!(drain_bridge_frames(&mut d.rx), vec![frame("cody-a", true)]);

    // b losing its bridge and a staying up: only b is announced.
    d.state.bridge_closed("cody-b");
    assert_eq!(drain_bridge_frames(&mut d.rx), vec![frame("cody-b", false)]);
}

#[test]
fn an_unidentified_caller_never_announces_anything() {
    let mut d = daemon_state();
    d.state.bridge_opened("");
    d.state.bridge_closed("");
    assert!(drain_bridge_frames(&mut d.rx).is_empty());
}

#[test]
fn closing_a_bridge_that_never_opened_announces_nothing() {
    let mut d = daemon_state();
    d.state.bridge_closed("cody-never");
    assert!(drain_bridge_frames(&mut d.rx).is_empty());
}

#[test]
fn without_a_daemon_backend_opening_and_closing_bridges_is_a_quiet_no_op() {
    // The in-process (TUI) server has nobody to tell. It must not panic, and
    // its own bookkeeping still works.
    let state = McpSharedState::for_test();
    state.bridge_opened("cody-a");
    assert_eq!(state.bridges.connected("cody-a"), Some(true));
    state.bridge_closed("cody-a");
    assert_eq!(state.bridges.connected("cody-a"), Some(false));
}

// ── end to end: real MCP socket + real IPC server + fake claude ───────────────

/// A `claude` stand-in that accepts stdin and stays alive. Enough for the
/// daemon to host a session; nothing here depends on what it prints.
const FAKE_CLAUDE_SCRIPT: &str = r#"#!/bin/sh
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"duration_ms":5,"total_cost_usd":0.01}'
while IFS= read -r line; do
  :
done
"#;

static FAKE_CLAUDE_DIR: OnceLock<PathBuf> = OnceLock::new();

/// Point `NOSTROMO_CLAUDE_BIN` at the fake, once per test process.
fn install_fake_claude() {
    FAKE_CLAUDE_DIR.get_or_init(|| {
        use std::os::unix::fs::PermissionsExt;
        let dir =
            std::env::temp_dir().join(format!("nostromo-bridge-claude-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("fake claude dir");
        let script = dir.join("claude");
        std::fs::write(&script, FAKE_CLAUDE_SCRIPT).expect("write fake claude");
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755))
            .expect("chmod fake claude");
        std::env::set_var(CLAUDE_BIN_ENV, &script);
        dir
    });
}

struct Harness {
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    session_mgr: Arc<Mutex<SessionManager>>,
    mcp_socket: PathBuf,
    state: McpSharedState,
    _mcp: McpServer,
    _tmp: TempDir,
}

impl Drop for Harness {
    /// Kill any fake-claude children: the test runtime waits for the blocking
    /// stdout-reader threads, which only end when the child dies.
    fn drop(&mut self) {
        self.session_mgr
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .kill_all_on_shutdown();
    }
}

/// An IPC server (Unix + TCP) and an MCP server that share one session manager
/// and one broadcast channel, wired the way `nostromd` wires them.
async fn spawn_harness() -> Harness {
    install_fake_claude();
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
        Arc::new(FakePeerVerifier::always_app()),
        false,
        nostromo::terminal::TerminalManager::in_memory(),
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

    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions: Arc::clone(&decisions),
        tickets: Default::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    });
    session_mgr
        .lock()
        .unwrap()
        .configure_bridge_registry(Arc::clone(&state.bridges));
    let mcp_socket = tmp.path().join("mcp.sock");
    let mcp = McpServer::bind(mcp_socket.clone(), state.clone())
        .await
        .expect("bind mcp socket");

    Harness {
        server,
        socket_path,
        tcp_port,
        session_mgr,
        mcp_socket,
        state,
        _mcp: mcp,
        _tmp: tmp,
    }
}

impl Harness {
    async fn unix(&self) -> UnixStream {
        let mut s = UnixStream::connect(&self.socket_path)
            .await
            .expect("unix connect");
        handshake(&mut s).await;
        s
    }

    async fn tcp(&self) -> TcpStream {
        let mut s = TcpStream::connect(("127.0.0.1", self.tcp_port))
            .await
            .expect("tcp connect");
        handshake(&mut s).await;
        s
    }

    fn broadcast(&self, msg: ServerMsg) {
        self.server.broadcast(msg);
    }

    /// Connect a bridge the way `nostromo-mcp-bridge` does: Hello with its pty
    /// id, then `initialize`; returns once the daemon has answered, which means
    /// the Hello was processed. Dropping the returned value hangs up.
    async fn connect_bridge(&self, pty_id: Option<&str>) -> BridgeConn {
        let stream = UnixStream::connect(&self.mcp_socket).await.unwrap();
        let (read_half, mut write_half) = stream.into_split();
        let mut reader = BufReader::new(read_half);
        let hello = match pty_id {
            Some(id) => json!({"type": "hello", "pty_id": id}),
            None => json!({"type": "hello"}),
        };
        write_line(&mut write_half, &hello).await;
        write_line(
            &mut write_half,
            &json!({
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                           "clientInfo": {"name": "t", "version": "0"}}
            }),
        )
        .await;
        let mut line = String::new();
        tokio::time::timeout(Duration::from_secs(5), reader.read_line(&mut line))
            .await
            .expect("timed out waiting for the initialize response")
            .unwrap();
        assert!(line.contains("\"result\""), "initialize failed: {line}");
        BridgeConn {
            _reader: reader,
            _writer: write_half,
        }
    }

    async fn list(&self, unix: &mut UnixStream) -> Vec<SessionInfo> {
        send(unix, &ClientMsg::SessionList).await;
        let frames = recv_until(unix, |m| matches!(m, ServerMsg::SessionListResp { .. })).await;
        match frames.into_iter().last() {
            Some(ServerMsg::SessionListResp { sessions }) => sessions,
            other => panic!("expected session_list_resp, got {other:?}"),
        }
    }
}

/// Poll until the daemon's registry reports `expected` for `tag`, bounded. A
/// bridge's first open is not broadcast, so this is how a test knows the daemon
/// has registered (or lost) it.
async fn wait_for_bridge_state(h: &Harness, tag: &str, expected: Option<bool>) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while h.state.bridges.connected(tag) != expected {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for bridge state {expected:?} for `{tag}`, have {:?}",
            h.state.bridges.connected(tag)
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Poll until `tag` has exactly `live` live bridge connections, bounded.
async fn wait_for_live_bridges(h: &Harness, tag: &str, live: u64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while h.state.bridges.live(tag) != live {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {live} live bridges for `{tag}`, have {}",
            h.state.bridges.live(tag)
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

struct BridgeConn {
    _reader: BufReader<tokio::net::unix::OwnedReadHalf>,
    _writer: tokio::net::unix::OwnedWriteHalf,
}

async fn write_line<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

async fn send<S: AsyncWrite + Unpin>(stream: &mut S, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    write_frame(stream, &bytes).await.expect("write frame");
}

async fn recv<S: AsyncRead + Unpin>(stream: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Read frames until `done` accepts one; every frame read, the accepting one last.
async fn recv_until<S: AsyncRead + Unpin>(
    stream: &mut S,
    mut done: impl FnMut(&ServerMsg) -> bool,
) -> Vec<ServerMsg> {
    let mut frames = Vec::new();
    loop {
        let msg = recv(stream).await;
        let stop = done(&msg);
        frames.push(msg);
        if stop {
            return frames;
        }
    }
}

/// Ping and read until Pong; returns everything before the Pong.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Vec<ServerMsg> {
    send(stream, &ClientMsg::Ping).await;
    let mut frames = recv_until(stream, |m| matches!(m, ServerMsg::Pong)).await;
    frames.pop();
    frames
}

/// Hello -> Welcome -> Subscribe to everything, then sync so the subscription
/// is registered before the caller does anything.
async fn handshake<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) {
    send(
        stream,
        &ClientMsg::Hello {
            client_id: "session-bridge-it".into(),
            protocol_version: PROTOCOL_VERSION,
            client_kind: Some(MAC_APP_CLIENT_KIND.into()),
        },
    )
    .await;
    match recv(stream).await {
        ServerMsg::Welcome { .. } => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    send(
        stream,
        &ClientMsg::Subscribe {
            topics: Vec::<Topic>::new(),
            renders_decisions: false,
            renders_approvals: false,
            capabilities: vec![],
            operator_nonce: None,
        },
    )
    .await;
    sync(stream).await;
}

async fn spawn_session(unix: &mut UnixStream, tag: &str) {
    send(
        unix,
        &ClientMsg::SessionSpawn {
            tag: tag.into(),
            agent_name: "cody".into(),
            view_name: format!("v-{tag}"),
            cwd: None,
            session_id: Some(format!("sid-{tag}")),
            remote_control: false,
        },
    )
    .await;
    let frames = recv_until(unix, |m| {
        matches!(
            m,
            ServerMsg::SessionSpawned { .. } | ServerMsg::Error { .. }
        )
    })
    .await;
    assert!(
        matches!(frames.last(), Some(ServerMsg::SessionSpawned { .. })),
        "spawning `{tag}` failed: {frames:?}"
    );
}

fn is_bridge(m: &ServerMsg, tag: &str, connected: bool) -> bool {
    matches!(m, ServerMsg::SessionBridge { tag: t, connected: c } if t == tag && *c == connected)
}

fn bridge_frames_for<'a>(frames: &'a [ServerMsg], tag: &str) -> Vec<&'a ServerMsg> {
    frames
        .iter()
        .filter(|m| matches!(m, ServerMsg::SessionBridge { tag: t, .. } if t == tag))
        .collect()
}

fn bridge_of(sessions: &[SessionInfo], tag: &str) -> Option<bool> {
    sessions
        .iter()
        .find(|s| s.tag == tag)
        .unwrap_or_else(|| panic!("session {tag} not listed: {sessions:?}"))
        .mcp_bridge_connected
}

#[tokio::test]
async fn an_app_hears_when_a_sessions_bridge_is_lost() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;

    let bridge = h.connect_bridge(Some("cody-e2e")).await;
    wait_for_bridge_state(&h, "cody-e2e", Some(true)).await;

    drop(bridge);
    let seen = recv_until(&mut app, |m| is_bridge(m, "cody-e2e", false)).await;
    assert!(is_bridge(seen.last().unwrap(), "cody-e2e", false));
    assert_eq!(
        bridge_frames_for(&seen, "cody-e2e").len(),
        1,
        "the first connect is not announced; only the loss is: {seen:?}"
    );
}

#[tokio::test]
async fn a_sessions_first_bridge_connecting_is_not_announced_to_the_app() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;

    let _bridge = h.connect_bridge(Some("cody-e2e")).await;
    wait_for_bridge_state(&h, "cody-e2e", Some(true)).await;

    h.broadcast(ServerMsg::Pong);
    let seen = recv_until(&mut app, |m| matches!(m, ServerMsg::Pong)).await;
    assert!(bridge_frames_for(&seen, "cody-e2e").is_empty(), "{seen:?}");
}

#[tokio::test]
async fn a_bridge_reconnecting_tells_the_app_the_tools_are_back() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;

    let first = h.connect_bridge(Some("cody-e2e")).await;
    wait_for_bridge_state(&h, "cody-e2e", Some(true)).await;
    drop(first);
    recv_until(&mut app, |m| is_bridge(m, "cody-e2e", false)).await;

    let _second = h.connect_bridge(Some("cody-e2e")).await;
    let seen = recv_until(&mut app, |m| is_bridge(m, "cody-e2e", true)).await;
    assert!(is_bridge(seen.last().unwrap(), "cody-e2e", true));
}

#[tokio::test]
async fn a_bridge_is_only_lost_when_its_last_connection_goes() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;

    let first = h.connect_bridge(Some("cody-e2e")).await;
    let second = h.connect_bridge(Some("cody-e2e")).await;
    wait_for_live_bridges(&h, "cody-e2e", 2).await;

    drop(first);
    // Wait until the daemon has processed the hang-up, then use an ordered
    // control frame: nothing for this tag may have been announced before it.
    wait_for_live_bridges(&h, "cody-e2e", 1).await;
    h.broadcast(ServerMsg::Pong);
    let seen = recv_until(&mut app, |m| matches!(m, ServerMsg::Pong)).await;
    assert!(
        bridge_frames_for(&seen, "cody-e2e").is_empty(),
        "one connection is still live: {seen:?}"
    );
    assert_eq!(h.state.bridges.connected("cody-e2e"), Some(true));

    drop(second);
    recv_until(&mut app, |m| is_bridge(m, "cody-e2e", false)).await;
}

#[tokio::test]
async fn a_connection_that_never_identifies_is_never_announced() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;

    let anonymous = h.connect_bridge(None).await;
    drop(anonymous);
    // Control: a real bridge that is then lost; everything the app sees up to
    // and past that loss is what the anonymous connection (wrongly) caused.
    let real = h.connect_bridge(Some("cody-real")).await;
    wait_for_bridge_state(&h, "cody-real", Some(true)).await;
    drop(real);
    recv_until(&mut app, |m| is_bridge(m, "cody-real", false)).await;
    h.broadcast(ServerMsg::Pong);
    let rest = recv_until(&mut app, |m| matches!(m, ServerMsg::Pong)).await;
    assert!(
        rest.iter()
            .all(|m| !matches!(m, ServerMsg::SessionBridge { .. })),
        "only the identified bridge may be announced: {rest:?}"
    );
}

#[tokio::test]
async fn the_session_list_says_which_sessions_have_lost_their_tools() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;
    spawn_session(&mut app, "cody-has-bridge").await;
    spawn_session(&mut app, "cody-no-bridge").await;

    // Nothing has identified as either tag yet: unknown, not "offline".
    let sessions = h.list(&mut app).await;
    assert_eq!(bridge_of(&sessions, "cody-has-bridge"), None);
    assert_eq!(bridge_of(&sessions, "cody-no-bridge"), None);

    let bridge = h.connect_bridge(Some("cody-has-bridge")).await;
    wait_for_bridge_state(&h, "cody-has-bridge", Some(true)).await;
    let sessions = h.list(&mut app).await;
    assert_eq!(bridge_of(&sessions, "cody-has-bridge"), Some(true));
    assert_eq!(
        bridge_of(&sessions, "cody-no-bridge"),
        None,
        "a session that never had a bridge must never read as offline"
    );

    drop(bridge);
    recv_until(&mut app, |m| is_bridge(m, "cody-has-bridge", false)).await;
    let sessions = h.list(&mut app).await;
    assert_eq!(bridge_of(&sessions, "cody-has-bridge"), Some(false));
    assert_eq!(bridge_of(&sessions, "cody-no-bridge"), None);
}

#[tokio::test]
async fn the_list_wire_omits_the_key_for_a_session_that_never_had_a_bridge() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;
    spawn_session(&mut app, "cody-no-bridge").await;

    send(&mut app, &ClientMsg::SessionList).await;
    let frames = recv_until(&mut app, |m| matches!(m, ServerMsg::SessionListResp { .. })).await;
    let wire = serde_json::to_value(frames.last().unwrap()).unwrap();
    let entry = wire["sessions"]
        .as_array()
        .and_then(|a| a.iter().find(|s| s["tag"] == "cody-no-bridge"))
        .unwrap_or_else(|| panic!("session not listed: {wire}"));
    assert!(entry.get("mcp_bridge_connected").is_none(), "{entry}");
}

#[tokio::test]
async fn attaching_replays_the_current_bridge_state_only_when_it_is_known() {
    let h = spawn_harness().await;
    let mut app = h.unix().await;
    spawn_session(&mut app, "cody-known").await;
    spawn_session(&mut app, "cody-unknown").await;

    let bridge = h.connect_bridge(Some("cody-known")).await;
    wait_for_bridge_state(&h, "cody-known", Some(true)).await;
    drop(bridge);
    recv_until(&mut app, |m| is_bridge(m, "cody-known", false)).await;

    // A client that arrives after the transition has missed the broadcast.
    let mut late = h.unix().await;
    send(
        &mut late,
        &ClientMsg::SessionAttach {
            tag: "cody-known".into(),
        },
    )
    .await;
    let mut frames = sync(&mut late).await;
    frames.retain(|m| matches!(m, ServerMsg::SessionBridge { .. }));
    assert_eq!(frames.len(), 1, "{frames:?}");
    assert!(is_bridge(&frames[0], "cody-known", false));

    send(
        &mut late,
        &ClientMsg::SessionAttach {
            tag: "cody-unknown".into(),
        },
    )
    .await;
    let frames = sync(&mut late).await;
    assert!(
        bridge_frames_for(&frames, "cody-unknown").is_empty(),
        "no bridge ever identified as this tag: {frames:?}"
    );
}

// ── gating: same rules as `session_state` ─────────────────────────────────────

fn bridge_msg(tag: &str) -> ServerMsg {
    ServerMsg::SessionBridge {
        tag: tag.into(),
        connected: false,
    }
}

#[tokio::test]
async fn a_tcp_peer_never_receives_session_bridge_for_a_sensitive_tag() {
    let h = spawn_harness().await;
    let mut unix = h.unix().await;
    let mut tcp = h.tcp().await;

    for tag in ["fred", "teri", "cody-x"] {
        h.broadcast(bridge_msg(tag));
    }
    // Control frame: the broadcast channel is ordered, so once it arrives any
    // earlier frame that was going to be delivered has been.
    h.broadcast(ServerMsg::Pong);

    let mut local = recv_until(&mut unix, |m| matches!(m, ServerMsg::Pong)).await;
    local.retain(|m| matches!(m, ServerMsg::SessionBridge { .. }));
    let local_tags: Vec<String> = local
        .iter()
        .filter_map(|m| match m {
            ServerMsg::SessionBridge { tag, .. } => Some(tag.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        local_tags,
        vec!["fred", "teri", "cody-x"],
        "the local app gets every bridge frame"
    );

    let mut remote = recv_until(&mut tcp, |m| matches!(m, ServerMsg::Pong)).await;
    remote.retain(|m| matches!(m, ServerMsg::SessionBridge { .. }));
    let remote_tags: Vec<String> = remote
        .iter()
        .filter_map(|m| match m {
            ServerMsg::SessionBridge { tag, .. } => Some(tag.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        remote_tags,
        vec!["cody-x"],
        "a network peer gets an ordinary tag's bridge frame, never a sensitive one's"
    );
}
