//! Only the verified Nostromo Mac app may answer an agent's decision (AP1).
//!
//! The daemon socket is mode 0600, so every local process runs as the user,
//! including an agent's own Bash. These tests pin, over real sockets, who can
//! answer a `nostromo_ask_decision` and who counts as someone able to:
//!
//! * a Unix peer is the operator app only when the process behind it is the
//!   Nostromo bundle (the injected `PeerVerifier`) **and** its `Hello` claimed
//!   `client_kind: "mac_app"`. The claim alone grants nothing;
//! * anyone else's `DecisionAnswer` gets a targeted `not_operator_app` error
//!   and changes nothing (the decision stays pending, the asking call keeps
//!   waiting, nobody is told it resolved);
//! * a TCP peer's answer is still refused with `requires_secure_connection`;
//! * only an operator-app subscriber counts as an operator for
//!   `nostromo_ask_decision`; a plain local subscriber or a TCP one still
//!   receives broadcasts but does not;
//! * identifying a peer never delays another connection's handshake.
//!
//! Every connection here comes from the test binary, so who it "is" is decided
//! by `FakePeerVerifier` (scripted in accept order). Synchronisation: after
//! `Subscribe` (and after any attack) the helpers `Ping` and read to the
//! `Pong`; the main loop answers it only after the subscription is registered
//! and earlier targeted replies have been written.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::ipc::{
    codec::{read_frame, write_frame},
    decisions::{DecisionOutcome, DecisionRegistry},
    pane_registry::PaneRegistry,
    peer_verify::{
        testing::{app_info, script_info, FakePeerVerifier},
        PeerInfo, PeerVerifier, QA_BUNDLE_ID,
    },
    protocol::{ClientMsg, DecisionChoice, DecisionResolution, ServerMsg, Topic, PROTOCOL_VERSION},
    server::Server,
    PtyManager, SessionManager,
};
use nostromo::mcp::tools::ask_decision;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};
use tokio::sync::oneshot;

// ── harness ───────────────────────────────────────────────────────────────────

struct Env {
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    session_mgr: Arc<Mutex<SessionManager>>,
    decisions: Arc<Mutex<DecisionRegistry>>,
    _tmp: TempDir,
}

/// An in-process daemon on a temp Unix socket plus an ephemeral TCP port, with
/// `verifier` standing in for the lookup of the process behind each Unix
/// connection.
async fn env_with(verifier: Arc<dyn PeerVerifier>, qa_mode: bool) -> Env {
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(tmp.path().join("sessions.json"))));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
        verifier,
        qa_mode,
    )
    .expect("bind unix socket");
    decisions.lock().unwrap().configure_broadcast(server.tx.clone());

    let tcp_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("bind tcp listener");
    let tcp_port = tcp_listener.local_addr().unwrap().port();
    server.bind_tcp(
        tcp_listener,
        pty_mgr,
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    );

    Env { server, socket_path, tcp_port, session_mgr, decisions, _tmp: tmp }
}

async fn env(verifier: FakePeerVerifier) -> Env {
    env_with(Arc::new(verifier), false).await
}

fn mcp_state(env: &Env) -> McpSharedState {
    McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
        session_mgr: Arc::clone(&env.session_mgr),
        broadcast_tx: env.server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions: Arc::clone(&env.decisions),
        tickets: Default::default(),
    })
}

async fn send<S: AsyncWrite + Unpin>(stream: &mut S, msg: &ClientMsg) {
    write_frame(stream, &serde_json::to_vec(msg).unwrap()).await.expect("write frame");
}

async fn recv<S: AsyncRead + Unpin>(stream: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Read frames until `done` accepts one; returns every frame read, the
/// accepting frame last.
async fn recv_until<S: AsyncRead + Unpin>(stream: &mut S, mut done: impl FnMut(&ServerMsg) -> bool) -> Vec<ServerMsg> {
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

/// Ping and read to the Pong; returns what arrived before it.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Vec<ServerMsg> {
    send(stream, &ClientMsg::Ping).await;
    let mut frames = recv_until(stream, |m| matches!(m, ServerMsg::Pong)).await;
    frames.pop();
    frames
}

fn hello(client_kind: Option<&str>) -> ClientMsg {
    ClientMsg::Hello {
        client_id: "operator-app-it".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: client_kind.map(str::to_string),
    }
}

/// Hello (with `client_kind`) -> Welcome -> Subscribe -> synced.
async fn connect_unix(env: &Env, client_kind: Option<&str>, topics: Vec<Topic>, renders_decisions: bool) -> UnixStream {
    let mut s = UnixStream::connect(&env.socket_path).await.expect("unix connect");
    send(&mut s, &hello(client_kind)).await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }), "a Hello must always be welcomed");
    send(&mut s, &ClientMsg::Subscribe { topics, renders_decisions }).await;
    sync(&mut s).await;
    s
}

/// A connection that subscribes to decisions the way the Mac app does.
async fn connect_unix_decisions(env: &Env, client_kind: Option<&str>) -> UnixStream {
    connect_unix(env, client_kind, vec![Topic::Decision], false).await
}

async fn connect_tcp(env: &Env, topics: Vec<Topic>, renders_decisions: bool) -> TcpStream {
    let mut s = TcpStream::connect(("127.0.0.1", env.tcp_port)).await.expect("tcp connect");
    send(&mut s, &hello(None)).await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }));
    send(&mut s, &ClientMsg::Subscribe { topics, renders_decisions }).await;
    sync(&mut s).await;
    s
}

fn choices() -> Vec<DecisionChoice> {
    ["yes", "no"]
        .iter()
        .map(|id| DecisionChoice { id: (*id).into(), label: (*id).into(), detail: None, is_default: false })
        .collect()
}

/// Pose a decision for `tag` straight on the registry and broadcast it, as the
/// ask tool does. Returns its id and the receiver the asker would wait on.
fn pose(env: &Env, tag: &str) -> (String, oneshot::Receiver<DecisionOutcome>) {
    let (id, rx, broadcast) = env.decisions.lock().unwrap().submit(tag.into(), "Proceed?".into(), None, choices(), None);
    if let Some(msg) = broadcast {
        let _ = env.server.tx.send(msg);
    }
    (id, rx)
}

fn ask_args(tag: &str) -> Value {
    json!({
        "prompt": "Proceed?",
        "choices": [{"id": "yes", "label": "Yes"}, {"id": "no", "label": "No"}],
        "view_id": tag,
        "timeout_secs": 20,
    })
}

/// An agent on focus `tag` calls `nostromo_ask_decision`; the call is genuinely
/// waiting on the daemon.
fn spawn_ask(env: &Env, tag: &str) -> tokio::task::JoinHandle<Value> {
    let state = mcp_state(env);
    let args = ask_args(tag);
    tokio::spawn(async move { ask_decision::handle(&state, &args, None).await })
}

async fn recv_decision_request<S: AsyncRead + Unpin>(stream: &mut S) -> String {
    let frames = recv_until(stream, |m| matches!(m, ServerMsg::DecisionRequest { .. })).await;
    match frames.last() {
        Some(ServerMsg::DecisionRequest { request_id, .. }) => request_id.clone(),
        other => panic!("expected a DecisionRequest, got {other:?}"),
    }
}

fn is_not_operator_app(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::Error { message } if message.starts_with("not_operator_app"))
}

fn is_resolved(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::DecisionResolved { .. })
}

/// A `DecisionAnswer` from `stream`, and everything the daemon says back
/// before the following Pong.
async fn answer<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S, request_id: &str, choice: Option<&str>) -> Vec<ServerMsg> {
    send(stream, &ClientMsg::DecisionAnswer { request_id: request_id.into(), choice_id: choice.map(str::to_string) }).await;
    sync(stream).await
}

fn still_pending(env: &Env, tag: &str, request_id: &str) -> bool {
    env.decisions.lock().unwrap().active_request_id(tag).as_deref() == Some(request_id)
}

// ── A: an agent's own script cannot answer, whatever it claims ────────────────

#[tokio::test]
async fn an_agents_script_claiming_to_be_the_mac_app_cannot_answer_its_own_decision() {
    // Accepted in order: the genuine app, then an agent's script.
    let env = env(FakePeerVerifier::scripted(vec![Some(app_info()), Some(script_info())], None)).await;
    let mut app = connect_unix_decisions(&env, Some("mac_app")).await;
    let mut script = connect_unix_decisions(&env, Some("mac_app")).await;

    let mut ask = spawn_ask(&env, "cody-x");
    let request_id = recv_decision_request(&mut app).await;
    assert_eq!(recv_decision_request(&mut script).await, request_id, "the script is shown the request too");

    // The script answers (and then tries a dismissal): both refused, targeted.
    for choice in [Some("yes"), None] {
        let frames = answer(&mut script, &request_id, choice).await;
        assert!(
            frames.iter().any(is_not_operator_app),
            "the script must get a `not_operator_app` error, got {frames:?}"
        );
        assert!(!frames.iter().any(is_resolved), "a refused answer must not resolve anything: {frames:?}");
    }

    // Nothing changed: the asking call is still waiting, the request is still
    // the tag's active one, and the app was never told it resolved.
    assert!(
        tokio::time::timeout(Duration::from_millis(200), &mut ask).await.is_err(),
        "the asking agent must keep waiting after a refused answer"
    );
    assert!(still_pending(&env, "cody-x", &request_id), "the request must still be active");
    let app_frames = sync(&mut app).await;
    assert!(!app_frames.iter().any(is_resolved), "no DecisionResolved for a refused attempt: {app_frames:?}");
    let script_frames = sync(&mut script).await;
    assert!(!script_frames.iter().any(is_resolved), "{script_frames:?}");

    // The verified app answers normally and the agent gets THAT choice.
    send(&mut app, &ClientMsg::DecisionAnswer { request_id: request_id.clone(), choice_id: Some("no".into()) }).await;
    let result = tokio::time::timeout(Duration::from_secs(5), ask).await.expect("the app's answer reaches the agent").unwrap();
    assert_eq!(result, json!({"ok": true, "choice_id": "no"}));

    let frames = recv_until(&mut app, is_resolved).await;
    match frames.last() {
        Some(ServerMsg::DecisionResolved { request_id: id, resolution, choice_id, .. }) => {
            assert_eq!(id, &request_id);
            assert_eq!(*resolution, DecisionResolution::Answered);
            assert_eq!(choice_id.as_deref(), Some("no"));
        }
        other => panic!("expected DecisionResolved, got {other:?}"),
    }
}

#[tokio::test]
async fn an_agents_script_cannot_answer_a_decision_on_a_sensitive_focus_either() {
    let env = env(FakePeerVerifier::scripted(vec![Some(script_info())], None)).await;
    let mut script = connect_unix_decisions(&env, Some("mac_app")).await;
    let (request_id, mut rx) = pose(&env, "fred");
    recv_decision_request(&mut script).await;

    let frames = answer(&mut script, &request_id, Some("yes")).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(still_pending(&env, "fred", &request_id));
    assert!(rx.try_recv().is_err(), "the asker must not have been answered");
}

// ── B: the verified bundle without the claim is not enough ───────────────────

#[tokio::test]
async fn a_genuine_app_whose_hello_has_no_client_kind_connects_but_cannot_answer() {
    let env = env(FakePeerVerifier::always_app()).await;
    // `connect_unix` asserts the Welcome: an older client must still connect.
    let mut old_app = connect_unix_decisions(&env, None).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut old_app).await;

    let frames = answer(&mut old_app, &request_id, Some("yes")).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(!frames.iter().any(is_resolved), "{frames:?}");
    assert!(still_pending(&env, "cody-x", &request_id));
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
async fn a_genuine_app_claiming_mac_app_can_answer() {
    let env = env(FakePeerVerifier::always_app()).await;
    let mut app = connect_unix_decisions(&env, Some("mac_app")).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut app).await;

    let frames = answer(&mut app, &request_id, Some("yes")).await;

    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("yes".into())));
}

#[tokio::test]
async fn an_unresolvable_peer_that_claims_mac_app_cannot_answer() {
    // The verifier could not tell who is on the other end.
    let env = env(FakePeerVerifier::scripted(vec![], None)).await;
    let mut peer = connect_unix_decisions(&env, Some("mac_app")).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut peer).await;

    let frames = answer(&mut peer, &request_id, Some("yes")).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(rx.try_recv().is_err());
}

// ── C: over TCP the existing refusal stands ──────────────────────────────────

#[tokio::test]
async fn a_tcp_clients_decision_answer_is_still_refused_as_requiring_a_secure_connection() {
    let env = env(FakePeerVerifier::always_app()).await;
    let mut tcp = connect_tcp(&env, vec![Topic::Decision], true).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut tcp).await;

    let frames = answer(&mut tcp, &request_id, Some("yes")).await;

    assert!(
        frames.iter().any(|m| matches!(m, ServerMsg::Error { message } if message.contains("requires_secure_connection"))),
        "a TCP answer keeps the existing `requires_secure_connection` refusal: {frames:?}"
    );
    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { message } if message.starts_with("not_operator_app"))));
    assert!(still_pending(&env, "cody-x", &request_id));
    assert!(rx.try_recv().is_err());
}

// ── D: who counts as an operator for ask_decision ────────────────────────────

/// `ask_decision` for `tag`, expected to fail fast.
async fn ask_returns_promptly(env: &Env, tag: &str) -> Value {
    let state = mcp_state(env);
    let args = ask_args(tag);
    tokio::time::timeout(Duration::from_millis(1500), ask_decision::handle(&state, &args, None))
        .await
        .expect("with no operator the ask must fail fast, not block toward its timeout")
}

#[tokio::test]
async fn ask_decision_reports_no_operator_when_only_a_plain_local_subscriber_and_a_tcp_one_are_connected() {
    for tag in ["cody-x", "teri"] {
        // Two local subscribers that claim to be the app (one by topic, one by
        // `renders_decisions`) but are scripts, and a TCP one that renders.
        let env = env(FakePeerVerifier::scripted(vec![Some(script_info()), Some(script_info())], None)).await;
        let _script_by_topic = connect_unix_decisions(&env, Some("mac_app")).await;
        let _script_by_flag = connect_unix(&env, Some("mac_app"), vec![], true).await;
        let _tcp = connect_tcp(&env, vec![Topic::Decision], true).await;

        let result = ask_returns_promptly(&env, tag).await;

        assert_eq!(result, json!({"error": "no_operator"}), "tag {tag}: nobody who could answer is connected");
        assert!(env.decisions.lock().unwrap().active_request_id(tag).is_none(), "nothing may have been submitted");
    }
}

#[tokio::test]
async fn ask_decision_reports_no_operator_for_a_genuine_app_that_does_not_claim_to_be_one() {
    let env = env(FakePeerVerifier::always_app()).await;
    let _old_app = connect_unix_decisions(&env, None).await;

    assert_eq!(ask_returns_promptly(&env, "cody-x").await, json!({"error": "no_operator"}));
}

#[tokio::test]
async fn ask_decision_proceeds_and_is_answered_once_the_verified_app_is_connected() {
    for tag in ["cody-x", "teri"] {
        // Accepted in order: a script, then the genuine app. A TCP renderer is
        // there too and must not matter.
        let env = env(FakePeerVerifier::scripted(vec![Some(script_info()), Some(app_info())], None)).await;
        let _script = connect_unix_decisions(&env, Some("mac_app")).await;
        let _tcp = connect_tcp(&env, vec![Topic::Decision], true).await;
        let mut app = connect_unix(&env, Some("mac_app"), vec![], true).await;

        let ask = spawn_ask(&env, tag);
        let request_id = recv_decision_request(&mut app).await;
        send(&mut app, &ClientMsg::DecisionAnswer { request_id, choice_id: Some("yes".into()) }).await;

        let result = tokio::time::timeout(Duration::from_secs(5), ask).await.expect("the app answers it").unwrap();
        assert_eq!(result, json!({"ok": true, "choice_id": "yes"}), "tag {tag}");
    }
}

// ── E: delivery is unchanged ─────────────────────────────────────────────────

#[tokio::test]
async fn a_plain_local_subscriber_still_receives_the_decision_request() {
    let env = env(FakePeerVerifier::always_script()).await;
    let mut script = connect_unix_decisions(&env, Some("mac_app")).await;
    let mut wildcard = connect_unix(&env, None, vec![], false).await;

    let (request_id, _rx) = pose(&env, "cody-x");

    assert_eq!(recv_decision_request(&mut script).await, request_id);
    assert_eq!(recv_decision_request(&mut wildcard).await, request_id);
}

// ── F: looking a peer up never delays anyone else ────────────────────────────

#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn a_slow_peer_lookup_on_one_connection_does_not_delay_another_connections_handshake() {
    let slow = Duration::from_millis(1500);
    let env = env(FakePeerVerifier::always_app().with_delay_on_first_inspect(slow)).await;

    // Connection 1: its lookup is the slow one. Give it time to start.
    let mut first = UnixStream::connect(&env.socket_path).await.expect("connect 1");
    send(&mut first, &hello(Some("mac_app"))).await;
    tokio::time::sleep(Duration::from_millis(150)).await;

    // Connection 2 must be welcomed long before connection 1's lookup is done.
    let started = Instant::now();
    let mut second = UnixStream::connect(&env.socket_path).await.expect("connect 2");
    send(&mut second, &hello(Some("mac_app"))).await;
    assert!(matches!(recv(&mut second).await, ServerMsg::Welcome { .. }));
    let took = started.elapsed();
    assert!(took < Duration::from_millis(500), "connection 2 waited {took:?} behind connection 1's lookup");

    // The slow one is still served once its lookup finishes.
    assert!(matches!(recv(&mut first).await, ServerMsg::Welcome { .. }));
}

// ── G: the QA instance is accepted only by a QA-mode daemon ──────────────────

fn qa_info() -> PeerInfo {
    PeerInfo {
        pid: 4444,
        exe: PathBuf::from("/Applications/Nostromo QA.app/Contents/MacOS/Nostromo"),
        bundle_id: Some(QA_BUNDLE_ID.to_string()),
    }
}

#[tokio::test]
async fn a_qa_mode_daemon_lets_the_qa_app_answer() {
    let env = env_with(Arc::new(FakePeerVerifier::scripted(vec![Some(qa_info())], None)), true).await;
    let mut qa_app = connect_unix_decisions(&env, Some("mac_app")).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut qa_app).await;

    let frames = answer(&mut qa_app, &request_id, Some("yes")).await;

    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("yes".into())));
}

#[tokio::test]
async fn a_regular_daemon_does_not_let_the_qa_app_answer() {
    let env = env_with(Arc::new(FakePeerVerifier::scripted(vec![Some(qa_info())], None)), false).await;
    let mut qa_app = connect_unix_decisions(&env, Some("mac_app")).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut qa_app).await;

    let frames = answer(&mut qa_app, &request_id, Some("yes")).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(still_pending(&env, "cody-x", &request_id));
    assert!(rx.try_recv().is_err());
}
