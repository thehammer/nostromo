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
//! * identifying a peer never delays another connection's handshake;
//! * (AP1b) even the operator app's answer is applied only when it echoes the
//!   `operator_nonce` its own connection's `Welcome` carried **and** a fresh
//!   look at the peer at answer time still sees the very process verified at
//!   `Hello` (same pid, same pidversion, still pinned). Any other connection's
//!   `Welcome` carries no nonce.
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
        CodeIdentity, PeerInfo, PeerVerifier, UnverifiedReason, QA_BUNDLE_ID,
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

/// Hello (with `client_kind`) -> Welcome -> Subscribe -> synced. Returns the
/// stream and the Welcome's `operator_nonce`.
async fn connect_unix_with_nonce(
    env: &Env,
    client_kind: Option<&str>,
    topics: Vec<Topic>,
    renders_decisions: bool,
) -> (UnixStream, Option<String>) {
    let mut s = UnixStream::connect(&env.socket_path).await.expect("unix connect");
    send(&mut s, &hello(client_kind)).await;
    let nonce = match recv(&mut s).await {
        ServerMsg::Welcome { operator_nonce, .. } => operator_nonce,
        other => panic!("a Hello must always be welcomed, got {other:?}"),
    };
    send(&mut s, &ClientMsg::Subscribe { topics, renders_decisions }).await;
    sync(&mut s).await;
    (s, nonce)
}

/// Hello (with `client_kind`) -> Welcome -> Subscribe -> synced.
async fn connect_unix(env: &Env, client_kind: Option<&str>, topics: Vec<Topic>, renders_decisions: bool) -> UnixStream {
    connect_unix_with_nonce(env, client_kind, topics, renders_decisions).await.0
}

/// A connection that subscribes to decisions the way the Mac app does.
async fn connect_unix_decisions(env: &Env, client_kind: Option<&str>) -> UnixStream {
    connect_unix(env, client_kind, vec![Topic::Decision], false).await
}

/// The verified operator app, subscribed to decisions, and the nonce its
/// Welcome carried (asserted present).
async fn connect_operator(env: &Env) -> (UnixStream, String) {
    let (s, nonce) = connect_unix_with_nonce(env, Some("mac_app"), vec![Topic::Decision], false).await;
    (s, nonce.expect("the verified operator app's Welcome must carry an operator_nonce"))
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

/// A `DecisionAnswer` from `stream` (echoing `nonce`), and everything the
/// daemon says back before the following Pong.
async fn answer<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    request_id: &str,
    choice: Option<&str>,
    nonce: Option<&str>,
) -> Vec<ServerMsg> {
    let msg = ClientMsg::DecisionAnswer {
        request_id: request_id.into(),
        choice_id: choice.map(str::to_string),
        operator_nonce: nonce.map(str::to_string),
    };
    send(stream, &msg).await;
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
    let (mut app, app_nonce) = connect_operator(&env).await;
    let mut script = connect_unix_decisions(&env, Some("mac_app")).await;

    let mut ask = spawn_ask(&env, "cody-x");
    let request_id = recv_decision_request(&mut app).await;
    assert_eq!(recv_decision_request(&mut script).await, request_id, "the script is shown the request too");

    // The script answers (and then tries a dismissal): both refused, targeted.
    for choice in [Some("yes"), None] {
        let frames = answer(&mut script, &request_id, choice, None).await;
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
    let msg = ClientMsg::DecisionAnswer {
        request_id: request_id.clone(),
        choice_id: Some("no".into()),
        operator_nonce: Some(app_nonce),
    };
    send(&mut app, &msg).await;
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

    let frames = answer(&mut script, &request_id, Some("yes"), None).await;

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

    let frames = answer(&mut old_app, &request_id, Some("yes"), None).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(!frames.iter().any(is_resolved), "{frames:?}");
    assert!(still_pending(&env, "cody-x", &request_id));
    assert!(rx.try_recv().is_err());
}

#[tokio::test]
async fn a_genuine_app_claiming_mac_app_can_answer() {
    let env = env(FakePeerVerifier::always_app()).await;
    let (mut app, nonce) = connect_operator(&env).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut app).await;

    let frames = answer(&mut app, &request_id, Some("yes"), Some(&nonce)).await;

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

    let frames = answer(&mut peer, &request_id, Some("yes"), None).await;

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

    let frames = answer(&mut tcp, &request_id, Some("yes"), None).await;

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
        let (mut app, nonce) = connect_unix_with_nonce(&env, Some("mac_app"), vec![], true).await;

        let ask = spawn_ask(&env, tag);
        let request_id = recv_decision_request(&mut app).await;
        send(&mut app, &ClientMsg::DecisionAnswer { request_id, choice_id: Some("yes".into()), operator_nonce: nonce }).await;

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
        pidversion: 1,
        exe: PathBuf::from("/Applications/Nostromo QA.app/Contents/MacOS/Nostromo"),
        path_bundle_id: Some(QA_BUNDLE_ID.to_string()),
        code: CodeIdentity::Pinned { identifier: QA_BUNDLE_ID.to_string() },
    }
}

#[tokio::test]
async fn a_qa_mode_daemon_lets_the_qa_app_answer() {
    let env = env_with(Arc::new(FakePeerVerifier::scripted(vec![Some(qa_info())], None)), true).await;
    let (mut qa_app, nonce) = connect_operator(&env).await;
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut qa_app).await;

    let frames = answer(&mut qa_app, &request_id, Some("yes"), Some(&nonce)).await;

    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    assert_eq!(rx.try_recv(), Ok(DecisionOutcome::Answered("yes".into())));
}

#[tokio::test]
async fn a_regular_daemon_does_not_let_the_qa_app_answer() {
    let env = env_with(Arc::new(FakePeerVerifier::scripted(vec![Some(qa_info())], None)), false).await;
    let (mut qa_app, nonce) = connect_unix_with_nonce(&env, Some("mac_app"), vec![Topic::Decision], false).await;
    assert_eq!(nonce, None, "a regular daemon does not treat the QA app as the operator, so issues it no nonce");
    let (request_id, mut rx) = pose(&env, "cody-x");
    recv_decision_request(&mut qa_app).await;

    let frames = answer(&mut qa_app, &request_id, Some("yes"), None).await;

    assert!(frames.iter().any(is_not_operator_app), "{frames:?}");
    assert!(still_pending(&env, "cody-x", &request_id));
    assert!(rx.try_recv().is_err());
}

// ── H: the operator nonce and the answer-time re-check (AP1b) ───────────────

/// An env whose verifier the test keeps a handle on (for `reinspect_count`).
async fn env_keeping(verifier: FakePeerVerifier) -> (Env, Arc<FakePeerVerifier>) {
    let verifier = Arc::new(verifier);
    let env = env_with(Arc::clone(&verifier) as Arc<dyn PeerVerifier>, false).await;
    (env, verifier)
}

fn is_hex_nonce(nonce: &str) -> bool {
    nonce.len() == 64 && nonce.chars().all(|c| c.is_ascii_hexdigit())
}

/// The scene for an attempted answer: the verified operator app (accepted
/// first) and a plain local observer subscribed to decisions, with a decision
/// posed on `cody-x` that both have been shown.
struct Scene {
    app: UnixStream,
    nonce: String,
    observer: UnixStream,
    request_id: String,
    rx: oneshot::Receiver<DecisionOutcome>,
}

async fn scene(env: &Env) -> Scene {
    let (mut app, nonce) = connect_operator(env).await;
    let mut observer = connect_unix_decisions(env, None).await;
    let (request_id, rx) = pose(env, "cody-x");
    assert_eq!(recv_decision_request(&mut app).await, request_id);
    assert_eq!(recv_decision_request(&mut observer).await, request_id);
    Scene { app, nonce, observer, request_id, rx }
}

/// The attempt was refused with the targeted error and changed nothing: the
/// decision is still the tag's active one, the asker has not been answered,
/// and no subscriber (the answerer or the observer) was told it resolved.
async fn assert_refused_and_untouched(env: &Env, scene: &mut Scene, frames: &[ServerMsg], what: &str) {
    assert!(
        frames.iter().any(is_not_operator_app),
        "{what}: expected the targeted `not_operator_app` error, got {frames:?}"
    );
    assert!(!frames.iter().any(is_resolved), "{what}: a refused answer must not resolve anything: {frames:?}");
    assert!(still_pending(env, "cody-x", &scene.request_id), "{what}: the decision must still be pending");
    assert!(
        matches!(scene.rx.try_recv(), Err(oneshot::error::TryRecvError::Empty)),
        "{what}: the asker must not have been answered"
    );
    let observed = sync(&mut scene.observer).await;
    assert!(!observed.iter().any(is_resolved), "{what}: no DecisionResolved to another subscriber: {observed:?}");
}

/// The operator app then answers properly (right nonce, same process) and the
/// asker gets that choice: the refusal left the decision answerable.
async fn assert_still_answerable(scene: &mut Scene) {
    let frames = answer(&mut scene.app, &scene.request_id, Some("no"), Some(&scene.nonce.clone())).await;
    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    assert_eq!(scene.rx.try_recv(), Ok(DecisionOutcome::Answered("no".into())));
}

#[tokio::test]
async fn the_operator_apps_welcome_carries_a_64_hex_digit_nonce_and_two_app_connections_get_different_ones() {
    let env = env(FakePeerVerifier::always_app()).await;
    let (_first, a) = connect_operator(&env).await;
    let (_second, b) = connect_operator(&env).await;

    assert!(is_hex_nonce(&a), "nonce must be 64 hex digits, got {a:?}");
    assert!(is_hex_nonce(&b), "nonce must be 64 hex digits, got {b:?}");
    assert_ne!(a, b, "each operator connection gets its own nonce");
}

#[tokio::test]
async fn no_welcome_but_the_verified_operator_apps_carries_a_nonce() {
    // Accepted in order: a script claiming mac_app, a script without a claim,
    // the genuine app without a claim (an old app), the genuine app claiming
    // something else.
    let env = env(FakePeerVerifier::scripted(
        vec![Some(script_info()), Some(script_info()), Some(app_info()), Some(app_info()), None],
        None,
    ))
    .await;
    for (who, kind) in [
        ("a script claiming mac_app", Some("mac_app")),
        ("a script without a claim", None),
        ("the genuine app without a claim", None),
        ("the genuine app claiming another client kind", Some("ios_app")),
        ("an unidentifiable peer claiming mac_app", Some("mac_app")),
    ] {
        let (_s, nonce) = connect_unix_with_nonce(&env, kind, vec![Topic::Decision], false).await;
        assert_eq!(nonce, None, "{who}: a non-operator Welcome must carry no operator_nonce");
    }

    let mut tcp = TcpStream::connect(("127.0.0.1", env.tcp_port)).await.expect("tcp connect");
    send(&mut tcp, &hello(Some("mac_app"))).await;
    match recv(&mut tcp).await {
        ServerMsg::Welcome { operator_nonce, .. } => {
            assert_eq!(operator_nonce, None, "a TCP peer, whatever it claims, gets no operator_nonce")
        }
        other => panic!("expected Welcome, got {other:?}"),
    }
}

#[tokio::test]
async fn the_operator_apps_answer_without_the_nonce_is_refused_and_changes_nothing() {
    let (env, verifier) = env_keeping(FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info()))).await;
    let mut scene = scene(&env).await;

    for choice in [Some("yes"), None] {
        let frames = answer(&mut scene.app, &scene.request_id.clone(), choice, None).await;
        assert_refused_and_untouched(&env, &mut scene, &frames, &format!("no nonce, choice {choice:?}")).await;
    }
    assert_eq!(verifier.reinspect_count(), 0, "a frame without the nonce must never cost a re-inspection");

    assert_still_answerable(&mut scene).await;
}

#[tokio::test]
async fn the_operator_apps_answer_with_a_wrong_nonce_is_refused_and_never_re_inspects() {
    let (env, verifier) = env_keeping(FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info()))).await;
    let mut scene = scene(&env).await;
    let right = scene.nonce.clone();
    let mut last_flipped = right.clone();
    let flipped = if last_flipped.ends_with('0') { '1' } else { '0' };
    last_flipped.pop();
    last_flipped.push(flipped);

    for (what, wrong) in [
        ("empty", String::new()),
        ("all zeros", "0".repeat(64)),
        ("last digit changed", last_flipped),
        ("truncated", right[..63].to_string()),
        ("extended", format!("{right}0")),
        ("upper-cased", right.to_ascii_uppercase()),
        ("padded", format!(" {right}")),
    ] {
        if wrong == right {
            continue; // an all-digit nonce upper-cases to itself
        }
        let frames = answer(&mut scene.app, &scene.request_id.clone(), Some("yes"), Some(&wrong)).await;
        assert_refused_and_untouched(&env, &mut scene, &frames, &format!("wrong nonce ({what})")).await;
    }
    assert_eq!(verifier.reinspect_count(), 0, "a wrong nonce must be refused before any re-inspection");

    assert_still_answerable(&mut scene).await;
    assert_eq!(verifier.reinspect_count(), 1, "the accepted answer is re-inspected exactly once");
}

#[tokio::test]
async fn the_operator_apps_answer_with_another_operator_connections_nonce_is_refused() {
    let (env, verifier) = env_keeping(FakePeerVerifier::scripted(vec![Some(app_info())], Some(app_info()))).await;
    let mut scene = scene(&env).await;
    // A second, equally genuine operator connection: its nonce is valid, but
    // not on the first connection.
    let (_other, other_nonce) = connect_operator(&env).await;
    assert_ne!(other_nonce, scene.nonce);

    let frames = answer(&mut scene.app, &scene.request_id.clone(), Some("yes"), Some(&other_nonce)).await;

    assert_refused_and_untouched(&env, &mut scene, &frames, "another connection's nonce").await;
    assert_eq!(verifier.reinspect_count(), 0);
    assert_still_answerable(&mut scene).await;
}

#[tokio::test]
async fn a_script_that_learned_the_operator_apps_nonce_still_cannot_answer() {
    let env = env(FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info()))).await;
    let mut scene = scene(&env).await;
    // (Connected after the decision was posed; its replay is read and dropped
    // by the connect helper's sync.)
    let mut script = connect_unix_decisions(&env, Some("mac_app")).await;

    let frames = answer(&mut script, &scene.request_id.clone(), Some("yes"), Some(&scene.nonce.clone())).await;

    assert_refused_and_untouched(&env, &mut scene, &frames, "a script echoing the app's nonce").await;
    let app_frames = sync(&mut scene.app).await;
    assert!(!app_frames.iter().any(is_resolved), "{app_frames:?}");
    assert_still_answerable(&mut scene).await;
}

/// The right nonce, but the answer-time re-inspection reports `now`: refused,
/// and the decision stays answerable for the real process.
async fn refused_when_the_answer_time_peer_is(now: Option<PeerInfo>, what: &str) {
    let (env, verifier) = env_keeping(
        FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info())).with_reinspect(vec![now]),
    )
    .await;
    let mut scene = scene(&env).await;

    let frames = answer(&mut scene.app, &scene.request_id.clone(), Some("yes"), Some(&scene.nonce.clone())).await;

    assert_refused_and_untouched(&env, &mut scene, &frames, what).await;
    assert_eq!(verifier.reinspect_count(), 1, "{what}: the right nonce must lead to exactly one re-inspection");

    // The scripted re-inspection is used up: the next one sees the accepted
    // process again, and its answer goes through.
    assert_still_answerable(&mut scene).await;
}

#[tokio::test]
async fn the_right_nonce_from_a_peer_that_has_since_execd_is_refused() {
    let now = PeerInfo { pidversion: app_info().pidversion + 1, ..app_info() };
    refused_when_the_answer_time_peer_is(Some(now), "same pid, new pidversion (exec)").await;
}

#[tokio::test]
async fn the_right_nonce_written_by_another_process_sharing_the_socket_is_refused() {
    let now = PeerInfo { pid: app_info().pid + 1, ..app_info() };
    refused_when_the_answer_time_peer_is(Some(now), "another pid, same image (an fd sharer)").await;
}

#[tokio::test]
async fn the_right_nonce_is_refused_when_the_peer_cannot_be_identified_at_answer_time() {
    refused_when_the_answer_time_peer_is(None, "re-inspection found nobody").await;
}

#[tokio::test]
async fn the_right_nonce_is_refused_when_the_peers_code_is_no_longer_pinned() {
    for reason in [UnverifiedReason::NoSuchCode, UnverifiedReason::RequirementFailed, UnverifiedReason::Debugged] {
        let now = PeerInfo { code: CodeIdentity::Unverified { reason }, ..app_info() };
        refused_when_the_answer_time_peer_is(Some(now), &format!("same process, now Unverified {{ {reason} }}")).await;
    }
}

#[tokio::test]
async fn the_right_nonce_is_refused_when_the_peer_is_now_pinned_under_another_identifier() {
    let now = PeerInfo { code: CodeIdentity::Pinned { identifier: QA_BUNDLE_ID.to_string() }, ..app_info() };
    refused_when_the_answer_time_peer_is(Some(now), "same process, pinned as another identifier").await;
}

#[tokio::test]
async fn the_right_nonce_from_the_same_verified_process_answers_exactly_once() {
    let (env, verifier) = env_keeping(FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info()))).await;
    let mut scene = scene(&env).await;
    let nonce = scene.nonce.clone();
    let request_id = scene.request_id.clone();

    let frames = answer(&mut scene.app, &request_id, Some("yes"), Some(&nonce)).await;
    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    assert_eq!(scene.rx.try_recv(), Ok(DecisionOutcome::Answered("yes".into())));
    assert!(!still_pending(&env, "cody-x", &request_id), "the decision is resolved");
    // The resolution is a broadcast: it may land after the answerer's Pong.
    if !frames.iter().any(is_resolved) {
        recv_until(&mut scene.app, is_resolved).await;
    }
    let observed = recv_until(&mut scene.observer, is_resolved).await;
    match observed.last().unwrap() {
        ServerMsg::DecisionResolved { request_id: id, resolution, choice_id, .. } => {
            assert_eq!(id, &request_id);
            assert_eq!(*resolution, DecisionResolution::Answered);
            assert_eq!(choice_id.as_deref(), Some("yes"));
        }
        other => panic!("{other:?}"),
    }

    // The identical answer again (a replay, or a double click): nothing more.
    let again = answer(&mut scene.app, &request_id, Some("yes"), Some(&nonce)).await;
    assert!(!again.iter().any(is_resolved), "no second resolution: {again:?}");
    assert_eq!(scene.rx.try_recv(), Err(oneshot::error::TryRecvError::Closed), "the asker was answered once");
    tokio::time::sleep(Duration::from_millis(200)).await; // room for a stray broadcast
    let observed = sync(&mut scene.observer).await;
    assert!(!observed.iter().any(is_resolved), "the observer is not told twice: {observed:?}");
    let app_frames = sync(&mut scene.app).await;
    assert!(!app_frames.iter().any(is_resolved), "{app_frames:?}");
    assert!(verifier.reinspect_count() >= 1);
}

#[tokio::test]
async fn the_nonce_and_the_answer_time_check_carry_the_operator_app_through_an_ask_decision_call() {
    // End to end: the agent's ask is answered by the app echoing its nonce,
    // after a refused nonce-less attempt from the same app.
    let (env, verifier) = env_keeping(FakePeerVerifier::always_app()).await;
    let (mut app, nonce) = connect_operator(&env).await;
    let mut ask = spawn_ask(&env, "cody-x");
    let request_id = recv_decision_request(&mut app).await;

    let refused = answer(&mut app, &request_id, Some("yes"), None).await;
    assert!(refused.iter().any(is_not_operator_app), "{refused:?}");
    assert!(
        tokio::time::timeout(Duration::from_millis(200), &mut ask).await.is_err(),
        "the asking agent keeps waiting after a refused answer"
    );

    let frames = answer(&mut app, &request_id, Some("no"), Some(&nonce)).await;
    assert!(!frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })), "{frames:?}");
    let result = tokio::time::timeout(Duration::from_secs(5), ask).await.expect("answered").unwrap();
    assert_eq!(result, json!({"ok": true, "choice_id": "no"}));
    assert_eq!(verifier.reinspect_count(), 1);
}

// ── I: what the daemon logs about it ─────────────────────────────────────────

#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl std::io::Write for LogBuf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogBuf {
    type Writer = LogBuf;
    fn make_writer(&'a self) -> LogBuf {
        self.clone()
    }
}

impl LogBuf {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }

    /// Captures every event on this thread. `#[tokio::test]` defaults to a
    /// current-thread runtime, so the server's tasks run here too.
    fn capture(&self) -> tracing::subscriber::DefaultGuard {
        // tracing-core treats a lone live dispatcher as the global one. While
        // this capture is the only one alive (say the other capturing test has
        // finished), a callsite first hit on another test's thread is judged by
        // that thread's absent subscriber and cached as "never", and this
        // capture silently misses it (CI's Build & Lint did, every run). A
        // second dispatcher kept alive for the whole binary keeps the registry
        // in its multi-dispatcher mode, where every live one is asked.
        static KEEP_MULTI_DISPATCH: std::sync::OnceLock<tracing::Dispatch> = std::sync::OnceLock::new();
        KEEP_MULTI_DISPATCH.get_or_init(|| tracing::Dispatch::new(tracing::subscriber::NoSubscriber::default()));
        let subscriber = tracing_subscriber::fmt()
            .with_writer(self.clone())
            .with_max_level(tracing::Level::TRACE)
            .with_ansi(false)
            .finish();
        tracing::subscriber::set_default(subscriber)
    }
}

#[tokio::test]
async fn a_refused_operator_answer_is_logged_with_why_and_the_nonce_is_never_logged() {
    let log = LogBuf::default();
    let _guard = log.capture();
    let env = env(FakePeerVerifier::scripted(vec![Some(app_info())], Some(script_info()))).await;
    let mut scene = scene(&env).await;
    let request_id = scene.request_id.clone();

    answer(&mut scene.app, &request_id, Some("yes"), None).await;
    answer(&mut scene.app, &request_id, Some("yes"), Some(&"0".repeat(64))).await;
    assert_still_answerable(&mut scene).await;

    let text = log.text();
    assert!(
        text.contains("DecisionAnswer without operator nonce: app older than daemon? reinstall app and daemon together"),
        "missing-nonce warning not logged:\n{text}"
    );
    assert!(text.contains("DecisionAnswer refused: wrong operator nonce"), "wrong-nonce warning not logged:\n{text}");
    assert!(text.contains("WARN"), "{text}");
    assert!(!text.contains(&scene.nonce), "the operator nonce must never appear in the logs:\n{text}");
}

#[tokio::test]
async fn a_genuine_app_without_a_claim_and_a_refused_mac_app_claim_are_each_warned_about() {
    let log = LogBuf::default();
    let _guard = log.capture();
    let env = env(FakePeerVerifier::scripted(vec![Some(app_info()), Some(script_info())], None)).await;
    let _old_app = connect_unix_decisions(&env, None).await;
    let _script = connect_unix_decisions(&env, Some("mac_app")).await;

    let text = log.text();
    assert!(
        text.contains("genuine bundle, no mac_app claim: old app? reinstall app and daemon together"),
        "old-app warning not logged:\n{text}"
    );
    assert!(
        text.contains("mac_app claim refused: RequirementFailed; run make mac-install (installs, signs and pins the app)"),
        "refused-claim warning not logged:\n{text}"
    );
}
