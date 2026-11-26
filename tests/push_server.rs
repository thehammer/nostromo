//! W13-31, W13-35, W13-38: the push feature against a live in-process `Server`.
//!
//! * `OperatorPresence` is the verified Mac app's verb: accepted from it, a no-op
//!   from any other local peer, refused to every network peer; the daemon turns the
//!   app's reports into `operator_presence` on `DecisionRequest`, and re-broadcasts
//!   the open decisions when the combined state turns `away`;
//! * a `Paired` and a `Tcp` peer are sent a `DecisionRequest` WITHOUT
//!   `operator_presence`, `repo` or `repo_owner`; the local operator app (and any
//!   other local peer) is sent them;
//! * a `personal` satellite's `DecisionRequest` reaches the primary's engine WITH
//!   `operator_presence` (the engine sends such a decision at once); a `work`
//!   satellite's arrives as metadata (no prompt, labels or repository) but keeps
//!   the deadline, the agent class and the presence;
//! * the four push verbs are served to a paired phone over a real WebSocket and to
//!   nobody else; `Welcome.features` has `presence` on every daemon and `push`
//!   only on a primary that runs the engine.
//!
//! Three harnesses, copied from their neighbours: the WebSocket rig
//! (`tests/support/ws_rig.rs`), a satellite and its primary
//! (`tests/uplink_roundtrip.rs`), and a bare Unix + TCP daemon that exposes its
//! `DecisionRegistry` (`tests/ipc_operator_app.rs`).

#![allow(clippy::type_complexity, clippy::result_large_err)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use nostromo::config::{PushConfig, SatelliteSetup, UplinkConfig};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::decisions::{DecisionMeta, DecisionRegistry};
use nostromo::ipc::devices::{DeviceKind, Egress, SatelliteAdmin};
use nostromo::ipc::peer::is_refusal;
use nostromo::ipc::peer_verify::testing::FakePeerVerifier;
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, ServerMsg, Topic, PROTOCOL_VERSION};
use nostromo::ipc::server::Server;
use nostromo::ipc::SessionManager;
use nostromo::push::wire::{
    AgentClass, HostClass, Presence, PushCapabilities, PushEnvironment, PushKinds, PushPrefs,
    QuietHours,
};
use nostromo::push::{ConfigSource, PushEngine};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};
use tokio::sync::broadcast;
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── common ───────────────────────────────────────────────────────────────────

fn t0() -> DateTime<Utc> {
    Utc::now()
        .date_naive()
        .and_hms_opt(10, 0, 0)
        .unwrap()
        .and_utc()
}

fn secs(n: i64) -> chrono::Duration {
    chrono::Duration::seconds(n)
}

fn decision_frame(
    request_id: &str,
    host: Option<&str>,
    deadline: Option<DateTime<Utc>>,
    presence: Option<Presence>,
    repo: Option<(&str, &str)>,
) -> ServerMsg {
    ServerMsg::DecisionRequest {
        tag: "claudia".into(),
        request_id: request_id.into(),
        prompt: "MARKER-prompt".into(),
        detail: Some("MARKER-detail".into()),
        choices: (0..3)
            .map(|i| DecisionChoice {
                id: format!("c{i}"),
                label: "MARKER-choice-label".into(),
                detail: Some("MARKER-choice-detail".into()),
                is_default: i == 0,
            })
            .collect(),
        context_pane_id: None,
        host: host.map(str::to_string),
        deadline,
        agent_class: Some(AgentClass::Claudia),
        operator_presence: presence,
        repo: repo.map(|(r, _)| r.to_string()),
        repo_owner: repo.map(|(_, o)| o.to_string()),
    }
}

fn is_decision(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::DecisionRequest { .. })
}

/// The JSON object of the first `decision_request` frame the connection was sent.
fn raw_decision(conn: &Conn) -> Value {
    conn.raw
        .iter()
        .filter_map(|t| serde_json::from_str::<Value>(t).ok())
        .find(|v| v["type"] == "decision_request")
        .unwrap_or_else(|| panic!("no decision_request in {:#?}", conn.raw))
}

// ── W13-38: what each kind of peer is sent ───────────────────────────────────

#[tokio::test]
async fn a_paired_and_a_tcp_peer_are_sent_a_decision_without_presence_or_repository_and_local_peers_with_them(
) {
    let rig = Rig::new().await;
    let dev = rig.mint_device("Phone");
    let mut paired = rig.device(&dev.token, &[], vec![Topic::Decision]).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![Topic::Decision], false).await;
    let mut app = rig.unix(vec![Topic::Decision], true).await;
    let mut other = rig.unix(vec![Topic::Decision], false).await;

    let deadline = t0() + secs(600);
    rig.server.broadcast(decision_frame(
        "req-1",
        None,
        Some(deadline),
        Some(Presence::Away),
        Some(("bishop", "thehammer")),
    ));
    for conn in [&mut paired, &mut tcp, &mut app, &mut other] {
        conn.next_matching("the decision", is_decision).await;
        conn.sync().await;
    }

    for (what, conn) in [("a paired device", &paired), ("a tcp peer", &tcp)] {
        let v = raw_decision(conn);
        assert!(
            v.get("operator_presence").is_none(),
            "{what} was told whether the operator is at the Mac: {v}"
        );
        assert!(
            v.get("repo").is_none() && v.get("repo_owner").is_none(),
            "{what} was sent a repository: {v}"
        );
        assert_eq!(v["request_id"], "req-1", "{what}: still the decision");
    }
    for (what, conn) in [("the operator app", &app), ("another local peer", &other)] {
        let v = raw_decision(conn);
        assert_eq!(v["operator_presence"], "away", "{what}: {v}");
        assert_eq!(v["repo"], "bishop", "{what}: {v}");
        assert_eq!(v["repo_owner"], "thehammer", "{what}: {v}");
        assert_eq!(v["agent_class"], "claudia", "{what}: {v}");
        assert!(v.get("deadline").is_some(), "{what}: {v}");
    }
}

#[tokio::test]
async fn presence_is_stripped_from_every_decision_a_phone_is_sent_not_just_the_first() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("Phone");
    let mut paired = rig.device(&dev.token, &[], vec![Topic::Decision]).await;
    for (i, presence) in [Some(Presence::Active), Some(Presence::Away), None]
        .into_iter()
        .enumerate()
    {
        rig.server.broadcast(decision_frame(
            &format!("req-{i}"),
            Some("sat"),
            None,
            presence,
            Some(("bishop", "thehammer")),
        ));
    }
    paired.sync().await;
    let decisions: Vec<Value> = paired
        .raw
        .iter()
        .filter_map(|t| serde_json::from_str::<Value>(t).ok())
        .filter(|v| v["type"] == "decision_request")
        .collect();
    assert_eq!(decisions.len(), 3, "{:#?}", paired.raw);
    for v in decisions {
        assert!(
            v.get("operator_presence").is_none()
                && v.get("repo").is_none()
                && v.get("repo_owner").is_none(),
            "{v}"
        );
    }
}

// ── Welcome.features ─────────────────────────────────────────────────────────

fn engine_config(rig: &Rig) -> ConfigSource {
    let token = rig.tmp.path().join("relay-token");
    std::fs::write(&token, "fake-relay-token\n").unwrap();
    let cfg = PushConfig {
        // Nothing is ever sent in these tests; the address is never contacted.
        relay_url: Some("http://127.0.0.1:9".into()),
        relay_token_path: Some(token),
        state_dir: Some(rig.tmp.path().join("push")),
        ..Default::default()
    };
    Arc::new(move || cfg.clone())
}

#[tokio::test]
async fn the_welcome_names_presence_on_every_daemon_and_push_only_once_the_engine_runs() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("Phone");
    let unix = rig.unix(vec![], false).await;
    let app = rig.unix(vec![], true).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    let paired = rig.device(&dev.token, &[], vec![]).await;
    for (what, conn) in [
        ("unix", &unix),
        ("the app", &app),
        ("tcp", &tcp),
        ("a paired device", &paired),
    ] {
        let features = conn.features();
        assert!(
            features.iter().any(|f| f == "presence"),
            "{what}: {features:?}"
        );
        assert!(
            !features.iter().any(|f| f == "push"),
            "{what}: no engine yet: {features:?}"
        );
    }

    assert!(
        rig.server.start_push(engine_config(&rig), "tokyo".into()),
        "a primary with [push] starts it"
    );
    let paired = rig.device(&dev.token, &[], vec![]).await;
    let features = paired.features();
    assert!(features.iter().any(|f| f == "push"), "{features:?}");
    assert!(features.iter().any(|f| f == "presence"), "{features:?}");
    let unix = rig.unix(vec![], false).await;
    assert!(unix.features().iter().any(|f| f == "presence"));
}

#[tokio::test]
async fn the_engine_does_not_start_on_a_primary_without_a_relay_or_when_disabled() {
    let rig = Rig::new().await;
    for cfg in [
        PushConfig::default(),
        PushConfig {
            relay_url: Some("   ".into()),
            ..Default::default()
        },
        PushConfig {
            relay_url: Some("http://127.0.0.1:9".into()),
            enabled: false,
            state_dir: Some(rig.tmp.path().join("push")),
            ..Default::default()
        },
    ] {
        let source: ConfigSource = Arc::new(move || cfg.clone());
        assert!(!rig.server.start_push(source, "tokyo".into()));
    }
    let dev = rig.mint_device("Phone");
    let paired = rig.device(&dev.token, &[], vec![]).await;
    assert!(!paired.features().iter().any(|f| f == "push"));
}

// ── the four verbs over real transports ──────────────────────────────────────

fn register(token: &str) -> ClientMsg {
    ClientMsg::RegisterPush {
        apns_token: token.to_string(),
        environment: PushEnvironment::Sandbox,
        tz: "America/Chicago".into(),
        capabilities: PushCapabilities::default(),
    }
}

fn is_push_reply(m: &ServerMsg) -> bool {
    matches!(
        m,
        ServerMsg::PushStatus(_) | ServerMsg::PushWaiting { .. } | ServerMsg::PushSentLog { .. }
    )
}

#[tokio::test]
async fn a_paired_phone_registers_and_reads_its_own_state_over_the_websocket() {
    let rig = Rig::new().await;
    assert!(rig.server.start_push(engine_config(&rig), "tokyo".into()));
    let dev = rig.mint_device("Phone");
    let mut phone = rig.device(&dev.token, &[], vec![]).await;

    phone.send(&register(&"ab".repeat(32))).await;
    let status = phone
        .next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await;
    let ServerMsg::PushStatus(body) = status else {
        unreachable!()
    };
    assert_eq!(body.prefs.tz, "America/Chicago");
    assert_eq!(
        body.work_owners.first().map(String::as_str),
        Some("Carefeed")
    );
    assert!(body.host_classes.is_empty());

    phone.send(&ClientMsg::PushWaiting).await;
    match phone
        .next_matching("PushWaiting", |m| {
            matches!(m, ServerMsg::PushWaiting { .. })
        })
        .await
    {
        ServerMsg::PushWaiting { items, badge } => assert!(items.is_empty() && badge == 0),
        _ => unreachable!(),
    }
    phone.send(&ClientMsg::PushSentLog).await;
    match phone
        .next_matching("PushSentLog", |m| {
            matches!(m, ServerMsg::PushSentLog { .. })
        })
        .await
    {
        ServerMsg::PushSentLog { entries } => assert!(entries.is_empty()),
        _ => unreachable!(),
    }

    let prefs = PushPrefs {
        kinds: PushKinds {
            review: false,
            ..PushKinds::default()
        },
        quiet: QuietHours {
            start: "21:30".into(),
            ..QuietHours::default()
        },
        ..PushPrefs::default()
    };
    phone
        .send(&ClientMsg::SetPushPrefs {
            prefs: prefs.clone(),
        })
        .await;
    let ServerMsg::PushStatus(body) = phone
        .next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await
    else {
        unreachable!()
    };
    assert_eq!(body.prefs.kinds, prefs.kinds);
    assert_eq!(body.prefs.quiet.start, "21:30");

    // The record is the device's own, keyed by the id its token names.
    let file = rig.tmp.path().join("push/devices.json");
    let record: Value = serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
    let ids: Vec<&String> = record["devices"].as_object().unwrap().keys().collect();
    assert_eq!(ids, vec![&dev.device_id]);
}

#[tokio::test]
async fn no_other_peer_is_served_a_push_verb_and_none_can_register_a_device() {
    let rig = Rig::new().await;
    assert!(rig.server.start_push(engine_config(&rig), "tokyo".into()));
    let dev = rig.mint_device("Phone");
    let mut phone = rig.device(&dev.token, &[], vec![]).await;
    phone.send(&register(&"ab".repeat(32))).await;
    phone
        .next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await;

    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    let mut app = rig.unix(vec![], true).await;
    let mut other = rig.unix(vec![], false).await;
    for (what, conn) in [
        ("a tcp peer", &mut tcp),
        ("the operator app", &mut app),
        ("another local peer", &mut other),
    ] {
        for msg in [
            register(&"cd".repeat(32)),
            ClientMsg::PushWaiting,
            ClientMsg::PushSentLog,
            ClientMsg::SetPushPrefs {
                prefs: PushPrefs::default(),
            },
        ] {
            conn.send(&msg).await;
        }
        conn.sync().await;
        let frames = conn.take_all();
        assert!(
            !frames.iter().any(is_push_reply),
            "{what} was answered a push verb: {frames:#?}"
        );
        if what == "a tcp peer" {
            assert!(
                frames.iter().any(is_refusal),
                "{what} is refused, not ignored: {frames:#?}"
            );
        }
    }

    // And a paired phone that sends the Mac app's verb is refused too.
    phone
        .send(&ClientMsg::OperatorPresence {
            state: Presence::Away,
        })
        .await;
    phone.sync().await;
    assert!(phone.take_all().iter().any(is_refusal));

    // Only the paired phone's record exists.
    let file = rig.tmp.path().join("push/devices.json");
    let record: Value = serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
    assert_eq!(record["devices"].as_object().unwrap().len(), 1);
    assert!(record["devices"][&dev.device_id].is_object());
}

#[tokio::test]
async fn two_paired_phones_have_separate_records_and_cannot_touch_each_others() {
    let rig = Rig::new().await;
    assert!(rig.server.start_push(engine_config(&rig), "tokyo".into()));
    let a = rig.mint_device("Phone A");
    let b = rig.mint_device("Phone B");
    let mut pa = rig.device(&a.token, &[], vec![]).await;
    let mut pb = rig.device(&b.token, &[], vec![]).await;
    pa.send(&register(&"ab".repeat(32))).await;
    pb.send(&register(&"cd".repeat(32))).await;
    pa.next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await;
    pb.next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await;

    let prefs = PushPrefs {
        kinds: PushKinds {
            mother: false,
            ..PushKinds::default()
        },
        ..PushPrefs::default()
    };
    pa.send(&ClientMsg::SetPushPrefs { prefs }).await;
    let ServerMsg::PushStatus(body_a) = pa
        .next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await
    else {
        unreachable!()
    };
    assert!(!body_a.prefs.kinds.mother);

    // B's settings did not move: asked again through an idempotent registration.
    pb.send(&register(&"cd".repeat(32))).await;
    let ServerMsg::PushStatus(body_b) = pb
        .next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
        .await
    else {
        unreachable!()
    };
    assert!(body_b.prefs.kinds.mother);
    let record: Value = serde_json::from_str(
        &std::fs::read_to_string(rig.tmp.path().join("push/devices.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        record["devices"][&a.device_id]["apns_token"],
        "ab".repeat(32)
    );
    assert_eq!(
        record["devices"][&b.device_id]["apns_token"],
        "cd".repeat(32)
    );
}

// ── OperatorPresence at a live daemon (a bare Unix + TCP server) ─────────────

struct Env {
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    decisions: Arc<Mutex<DecisionRegistry>>,
    _tmp: TempDir,
}

async fn env() -> Env {
    let tmp = TempDir::new().unwrap();
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
    decisions
        .lock()
        .unwrap()
        .configure_broadcast(server.tx.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let tcp_port = listener.local_addr().unwrap().port();
    server.bind_tcp(
        listener,
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    );
    Env {
        server,
        socket_path,
        tcp_port,
        decisions,
        _tmp: tmp,
    }
}

async fn send<S: AsyncWrite + Unpin>(s: &mut S, msg: &ClientMsg) {
    write_frame(s, &serde_json::to_vec(msg).unwrap())
        .await
        .expect("write frame");
}

async fn recv<S: AsyncRead + Unpin>(s: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(s))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Ping, read to the Pong; what arrived before it.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> Vec<ServerMsg> {
    send(s, &ClientMsg::Ping).await;
    let mut frames = Vec::new();
    loop {
        let m = recv(s).await;
        if matches!(m, ServerMsg::Pong) {
            return frames;
        }
        frames.push(m);
    }
}

fn hello(kind: Option<&str>) -> ClientMsg {
    ClientMsg::Hello {
        capabilities: vec![],
        client_id: "push-it".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: kind.map(str::to_string),
        role: None,
    }
}

fn subscribe(topics: Vec<Topic>) -> ClientMsg {
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

async fn unix(env: &Env, kind: Option<&str>) -> UnixStream {
    let mut s = UnixStream::connect(&env.socket_path).await.unwrap();
    send(&mut s, &hello(kind)).await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }));
    send(&mut s, &subscribe(vec![Topic::Decision])).await;
    sync(&mut s).await;
    s
}

/// The verified operator app, subscribed to decisions (so it counts as an operator).
async fn operator(env: &Env) -> UnixStream {
    unix(env, Some("mac_app")).await
}

async fn tcp(env: &Env) -> TcpStream {
    let mut s = TcpStream::connect(("127.0.0.1", env.tcp_port))
        .await
        .unwrap();
    send(&mut s, &hello(None)).await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }));
    send(&mut s, &subscribe(vec![Topic::Decision])).await;
    sync(&mut s).await;
    s
}

fn combined(env: &Env) -> Option<Presence> {
    env.decisions.lock().unwrap().combined_presence()
}

type Pending = tokio::sync::oneshot::Receiver<nostromo::ipc::decisions::DecisionOutcome>;

/// What an agent's `ask_decision` does: register the request and broadcast it.
/// The receiver is the asking call waiting for its answer; keep it alive.
fn ask(env: &Env, tag: &str) -> (String, Pending) {
    let choices = vec![
        DecisionChoice {
            id: "a".into(),
            label: "yes".into(),
            detail: None,
            is_default: true,
        },
        DecisionChoice {
            id: "b".into(),
            label: "no".into(),
            detail: None,
            is_default: false,
        },
    ];
    let meta = DecisionMeta {
        deadline: Some(t0() + secs(600)),
        agent_class: Some(AgentClass::Claudia),
        repo: Some("bishop".into()),
        repo_owner: Some("thehammer".into()),
    };
    let (request_id, rx, broadcast_now) = env.decisions.lock().unwrap().submit_with(
        tag.into(),
        "Which?".into(),
        None,
        choices,
        None,
        meta,
    );
    if let Some(msg) = broadcast_now {
        env.server.broadcast(msg);
    }
    (request_id, rx)
}

fn presence_of(m: &ServerMsg) -> Option<Option<Presence>> {
    match m {
        ServerMsg::DecisionRequest {
            operator_presence, ..
        } => Some(*operator_presence),
        _ => None,
    }
}

async fn next_decision<S: AsyncRead + Unpin>(s: &mut S) -> ServerMsg {
    loop {
        let m = recv(s).await;
        if is_decision(&m) {
            return m;
        }
    }
}

#[tokio::test]
async fn the_verified_app_reports_presence_and_the_daemon_combines_it() {
    let env = env().await;
    let mut a = operator(&env).await;
    assert_eq!(combined(&env), None, "no report yet");

    send(
        &mut a,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    sync(&mut a).await;
    assert_eq!(combined(&env), Some(Presence::Away));
    send(
        &mut a,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    sync(&mut a).await;
    assert_eq!(combined(&env), Some(Presence::Active));

    // A second app that has not reported prevents `away`.
    send(
        &mut a,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    sync(&mut a).await;
    let mut b = operator(&env).await;
    assert_eq!(
        combined(&env),
        None,
        "one app away and one that has not said"
    );
    send(
        &mut b,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    sync(&mut b).await;
    assert_eq!(combined(&env), Some(Presence::Away), "every app away");
    send(
        &mut b,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    sync(&mut b).await;
    assert_eq!(combined(&env), Some(Presence::Active), "one app active");
}

#[tokio::test]
async fn presence_from_another_local_peer_or_a_network_peer_changes_nothing() {
    let env = env().await;
    let mut app = operator(&env).await;
    let mut other = unix(&env, None).await;
    let mut network = tcp(&env).await;

    for state in [Presence::Away, Presence::Active] {
        send(&mut other, &ClientMsg::OperatorPresence { state }).await;
        sync(&mut other).await;
        assert_eq!(combined(&env), None, "another local peer said {state:?}");

        send(&mut network, &ClientMsg::OperatorPresence { state }).await;
        let frames = sync(&mut network).await;
        assert!(
            frames.iter().any(is_refusal),
            "a network peer is refused: {frames:#?}"
        );
        assert_eq!(combined(&env), None, "a network peer said {state:?}");
    }
    // The app, which has not reported, is still what decides.
    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    sync(&mut app).await;
    assert_eq!(combined(&env), Some(Presence::Away));
    send(
        &mut other,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    sync(&mut other).await;
    assert_eq!(
        combined(&env),
        Some(Presence::Away),
        "an Active from a stranger does not undo it"
    );
}

#[tokio::test]
async fn a_decision_carries_the_presence_as_it_stands_when_it_is_raised() {
    let env = env().await;
    let mut app = operator(&env).await;
    let mut watcher = unix(&env, None).await;

    let _first = ask(&env, "claudia");
    assert_eq!(
        presence_of(&next_decision(&mut watcher).await),
        Some(None),
        "nobody has reported"
    );

    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    sync(&mut app).await;
    let _second = ask(&env, "perri");
    assert_eq!(
        presence_of(&next_decision(&mut watcher).await),
        Some(Some(Presence::Active))
    );
}

#[tokio::test]
async fn a_change_to_away_rebroadcasts_each_open_decision_once_with_the_new_presence() {
    let env = env().await;
    let mut app = operator(&env).await;
    let mut watcher = unix(&env, None).await;
    let (first, _pending) = ask(&env, "claudia");
    let _ = next_decision(&mut watcher).await;
    // The app itself is sent the decision too.
    let _ = next_decision(&mut app).await;

    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    let m = next_decision(&mut watcher).await;
    match &m {
        ServerMsg::DecisionRequest {
            request_id,
            operator_presence,
            deadline,
            agent_class,
            ..
        } => {
            assert_eq!(*request_id, first, "the same decision, not a new one");
            assert_eq!(*operator_presence, Some(Presence::Away));
            assert!(deadline.is_some());
            assert_eq!(*agent_class, Some(AgentClass::Claudia));
        }
        _ => unreachable!(),
    }
    assert_eq!(
        presence_of(&next_decision(&mut app).await),
        Some(Some(Presence::Away))
    );

    // Away again, and active: nothing is re-sent while it stays away or when it turns active.
    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    let frames_app = sync(&mut app).await;
    let frames = sync(&mut watcher).await;
    assert!(
        !frames.iter().any(is_decision) && !frames_app.iter().any(is_decision),
        "{frames:#?} / {frames_app:#?}"
    );

    // Away once more: a change to away re-broadcasts again.
    send(
        &mut app,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    let m = next_decision(&mut watcher).await;
    assert_eq!(presence_of(&m), Some(Some(Presence::Away)));
}

#[tokio::test]
async fn when_the_app_that_was_active_disconnects_the_remaining_away_app_rebroadcasts() {
    let env = env().await;
    let mut a = operator(&env).await;
    let mut b = operator(&env).await;
    let mut watcher = unix(&env, None).await;
    let _pending = ask(&env, "claudia");
    let _ = next_decision(&mut watcher).await;

    send(
        &mut a,
        &ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    )
    .await;
    sync(&mut a).await;
    send(
        &mut b,
        &ClientMsg::OperatorPresence {
            state: Presence::Active,
        },
    )
    .await;
    sync(&mut b).await;
    assert_eq!(combined(&env), Some(Presence::Active));
    let frames = sync(&mut watcher).await;
    assert!(!frames.iter().any(is_decision), "nothing yet: {frames:#?}");

    // B goes away (its window closes): only A, which is away, remains.
    drop(b);
    let m = next_decision(&mut watcher).await;
    assert_eq!(presence_of(&m), Some(Some(Presence::Away)));
    assert_eq!(combined(&env), Some(Presence::Away));
}

// ── satellites: what reaches the primary's engine ────────────────────────────

struct Sat {
    server: Server,
    socket: PathBuf,
    session_mgr: Arc<Mutex<SessionManager>>,
    _tmp: TempDir,
}

fn start_satellite(url: String, token: &str, name: &str, egress: Egress) -> Sat {
    let tmp = TempDir::new().unwrap();
    let socket = tmp.path().join("sat.sock");
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("ids.json"),
    )));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));
    let perri = tmp.path().join("perri");
    let server = Server::bind(
        &socket,
        Arc::clone(&session_mgr),
        perri.clone(),
        Arc::clone(&decisions),
        Arc::new(FakePeerVerifier::always_app()),
        false,
        nostromo::terminal::TerminalManager::in_memory(),
    )
    .expect("bind the satellite's socket");
    let token_path = tmp.path().join("uplink-token");
    nostromo::uplink_cli::write_token(&token_path, token).unwrap();
    server.bind_uplink(
        SatelliteSetup {
            host: name.to_string(),
            uplink: UplinkConfig {
                url,
                token_path,
                egress,
                phi_repos: vec![],
                publish_topics: None,
                device_admin: SatelliteAdmin::Full,
            },
            phi_repos: vec!["admin-portal".into(), "referral-monitor".into()],
        },
        tmp.path().join("tag-key"),
        Arc::clone(&session_mgr),
        perri,
        decisions,
    );
    Sat {
        server,
        socket,
        session_mgr,
        _tmp: tmp,
    }
}

async fn join(primary: &Rig, name: &str, egress: Egress) -> Sat {
    let r = primary
        .registry
        .redeem_with_egress(
            name,
            DeviceKind::Satellite,
            Some(if egress == Egress::Work {
                SatelliteAdmin::RevokeOnly
            } else {
                SatelliteAdmin::Full
            }),
            Some(egress),
            None,
        )
        .expect("a satellite record");
    let sat = start_satellite(
        format!("ws://127.0.0.1:{}", primary.ws_port),
        &r.token,
        name,
        egress,
    );
    Rig::wait_until("the uplink to be admitted", || {
        primary.hub.router().is_connected(name)
    })
    .await;
    sat
}

/// The next `DecisionRequest` the primary's broadcast channel (what its engine
/// reads) carries for `host`.
async fn next_decision_from(rx: &mut broadcast::Receiver<ServerMsg>, host: &str) -> ServerMsg {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Ok(m) => {
                    if let ServerMsg::DecisionRequest { host: Some(h), .. } = &m {
                        if h == host {
                            return m;
                        }
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {}
                Err(broadcast::error::RecvError::Closed) => panic!("the broadcast channel closed"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no DecisionRequest from {host} reached the primary"))
}

async fn engine_with_relay(hosts: &[(&str, HostClass)]) -> (MockServer, Arc<PushEngine>, TempDir) {
    let relay = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/push"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"apns_status": 200})))
        .mount(&relay)
        .await;
    let tmp = TempDir::new().unwrap();
    let token = tmp.path().join("relay-token");
    std::fs::write(&token, "fake-relay-token\n").unwrap();
    let mut cfg = PushConfig {
        relay_url: Some(relay.uri()),
        relay_token_path: Some(token),
        state_dir: Some(tmp.path().join("push")),
        ..Default::default()
    };
    for (h, c) in hosts {
        cfg.hosts.insert(h.to_string(), *c);
    }
    let source: ConfigSource = Arc::new(move || cfg.clone());
    let engine = PushEngine::new(source, "tokyo".into(), None).expect("an engine");
    (relay, engine, tmp)
}

#[tokio::test]
async fn a_personal_satellites_decision_reaches_the_primarys_engine_with_presence_and_is_sent_at_once(
) {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal).await;
    // The satellite's daemon vouches for the focus the decision belongs to (a
    // personal uplink never publishes a frame for a focus it does not know).
    sat.session_mgr
        .lock()
        .unwrap()
        .set_focus_registry(vec![serde_json::from_value(json!({
        "tag": "claudia", "display_name": "Claudia", "agent_name": "claudia", "is_built_in": true,
        "project_path": "/code/blog",
    }))
    .unwrap()]);
    let mut engine_rx = primary.server.tx.subscribe();
    let when = t0();
    sat.server.broadcast(decision_frame(
        "req-1",
        None,
        Some(when + secs(600)),
        Some(Presence::Away),
        Some(("bishop", "thehammer")),
    ));
    let frame = next_decision_from(&mut engine_rx, "sat").await;
    match &frame {
        ServerMsg::DecisionRequest {
            operator_presence,
            deadline,
            agent_class,
            repo,
            repo_owner,
            host,
            ..
        } => {
            assert_eq!(
                *operator_presence,
                Some(Presence::Away),
                "presence survives the uplink (W13-38)"
            );
            assert_eq!(*deadline, Some(when + secs(600)));
            assert_eq!(*agent_class, Some(AgentClass::Claudia));
            assert_eq!(
                repo.as_deref(),
                Some("bishop"),
                "so the primary can apply the personal-host rule"
            );
            assert_eq!(repo_owner.as_deref(), Some("thehammer"));
            assert_eq!(host.as_deref(), Some("sat"));
        }
        _ => unreachable!(),
    }

    // The engine, given what the primary's channel carried, sends it at once.
    let (relay, engine, _tmp) = engine_with_relay(&[("sat", HostClass::Personal)]).await;
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    // (UTC: 10:00 there is outside quiet hours; in Chicago it would be 04:00.)
    let registration = ClientMsg::RegisterPush {
        apns_token: "ab".repeat(32),
        environment: PushEnvironment::Sandbox,
        tz: "UTC".into(),
        capabilities: PushCapabilities::default(),
    };
    assert_eq!(
        engine.dispatch(
            &registration,
            nostromo::ipc::peer::PeerTrust::Paired,
            Some("dev-1"),
            &tx
        ),
        nostromo::push::Dispatched::Handled
    );
    let _ = rx.try_recv();
    engine.step_at(when).await;
    engine.ingest(frame, when);
    engine.step_at(when).await;
    let posts: Vec<Value> = relay
        .received_requests()
        .await
        .unwrap()
        .iter()
        .map(|r| serde_json::from_slice(&r.body).unwrap())
        .collect();
    assert_eq!(posts.len(), 1, "{posts:#?}");
    assert_eq!(posts[0]["title"], "Decision · sat · bishop");
    assert_eq!(
        posts[0]["body"],
        "Claudia is waiting on you · 3 choices · times out in 10 min"
    );
    assert_eq!(posts[0]["interruption_level"], "time-sensitive");
}

#[tokio::test]
async fn a_work_satellites_decision_arrives_as_metadata_that_still_carries_presence_deadline_and_agent(
) {
    let primary = Rig::new().await;
    let sat = join(&primary, "kobe", Egress::Work).await;
    let mut engine_rx = primary.server.tx.subscribe();
    let when = t0();
    sat.server.broadcast(decision_frame(
        "req-1",
        None,
        Some(when + secs(300)),
        Some(Presence::Away),
        Some(("MARKER-repo", "MARKER-owner")),
    ));
    let frame = next_decision_from(&mut engine_rx, "kobe").await;
    match &frame {
        ServerMsg::DecisionRequest {
            prompt,
            detail,
            choices,
            repo,
            repo_owner,
            operator_presence,
            deadline,
            agent_class,
            ..
        } => {
            assert_eq!(*operator_presence, Some(Presence::Away));
            assert_eq!(*deadline, Some(when + secs(300)));
            assert_eq!(*agent_class, Some(AgentClass::Claudia));
            assert_eq!(choices.len(), 3);
            assert!(prompt.is_empty() && detail.is_none());
            assert!(choices
                .iter()
                .all(|c| c.label.is_empty() && c.detail.is_none()));
            assert_eq!(
                (repo.as_deref(), repo_owner.as_deref()),
                (None, None),
                "work data stays on the host"
            );
        }
        _ => unreachable!(),
    }
    let text = serde_json::to_string(&frame).unwrap();
    assert!(!text.to_ascii_lowercase().contains("marker"), "{text}");
}

#[tokio::test]
async fn every_daemon_says_presence_and_a_satellite_never_runs_the_engine() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal).await;
    let conn = Rig::unix_at(&sat.socket, vec![]).await;
    let features = conn.features();
    assert!(features.iter().any(|f| f == "presence"), "{features:?}");
    assert!(!features.iter().any(|f| f == "push"), "{features:?}");
    // A satellite has no device registry, so `start_push` cannot start an engine there.
    let source: ConfigSource = Arc::new(|| PushConfig {
        relay_url: Some("http://127.0.0.1:9".into()),
        ..Default::default()
    });
    assert!(!sat.server.start_push(source, "sat".into()));
}
