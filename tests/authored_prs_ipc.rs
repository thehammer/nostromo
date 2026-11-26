//! The author's PR list over the daemon's sockets: what the Welcome says, who
//! may say what is being looked at, and who is sent the list.
//!
//! * `Welcome.features` carries `authored_prs_v1` only when the feature is on.
//! * Only the verified operator app may send `authored_prs_demand` and
//!   `authored_prs_refresh`; a plain local client is ignored and a TCP peer is
//!   refused. A closed connection withdraws its own demand.
//! * `authored_prs` frames go to a client that names the topic, never to one
//!   that subscribed to everything (`topics: []`), and never to a TCP peer;
//!   the latest one is replayed on subscribe.
//!
//! The daemon here has no GitHub token, so the engine behind the demand board
//! makes no request: only who-is-looking is under test.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{TimeZone, Utc};
use nostromo::data::authored_prs::snapshot::*;
use nostromo::data::authored_prs::{AuthoredPrsSource, Demand, DemandBoard, Deps, TokioClock};
use nostromo::data::relay_client::RelayStatus;
use nostromo::ipc::{
    codec::{read_frame, write_frame},
    decisions::DecisionRegistry,
    peer_verify::testing::FakePeerVerifier,
    protocol::{ClientMsg, ServerMsg, Topic, PROTOCOL_VERSION},
    server::Server,
    SessionManager,
};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{TcpStream, UnixStream};

struct Env {
    server: Server,
    socket_path: PathBuf,
    tcp_port: u16,
    board: Option<Arc<DemandBoard>>,
    _engine: Option<tokio::task::JoinHandle<()>>,
    _jobs_tx: tokio::sync::watch::Sender<Vec<nostromo::mother::MotherJob>>,
    _tmp: TempDir,
}

async fn env(feature_on: bool) -> Env {
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let (mut board, mut engine) = (None, None);
    let (jobs_tx, jobs_rx) = tokio::sync::watch::channel(Vec::new());
    if feature_on {
        let handle = AuthoredPrsSource::spawn(Deps {
            state_root: None,
            exclude_orgs: Default::default(),
            api_base: "http://127.0.0.1:1".into(),
            github: None,
            token_resolver: None,
            relay_status: Arc::new(RelayStatus::new()),
            relay_configured: false,
            relay_rx: None,
            jobs_rx,
            focuses: Arc::new(Vec::new),
            projects_root: tmp.path().join("projects"),
            clock: Arc::new(TokioClock::new(Utc::now())),
        });
        session_mgr
            .lock()
            .unwrap()
            .configure_authored_prs(Arc::clone(&handle.demand));
        board = Some(handle.demand);
        engine = Some(handle.task);
    }
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
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let tcp_port = tcp.local_addr().unwrap().port();
    server.bind_tcp(tcp, session_mgr, tmp.path().join("perri-state"), decisions);
    Env {
        server,
        socket_path,
        tcp_port,
        board,
        _engine: engine,
        _jobs_tx: jobs_tx,
        _tmp: tmp,
    }
}

async fn send<S: AsyncWrite + Unpin>(s: &mut S, msg: &ClientMsg) {
    write_frame(s, &serde_json::to_vec(msg).unwrap())
        .await
        .expect("write");
}

async fn recv<S: AsyncRead + Unpin>(s: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(s))
        .await
        .expect("timed out waiting for a frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Ping and read to the Pong; everything that arrived before it.
async fn sync<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> Vec<ServerMsg> {
    send(s, &ClientMsg::Ping).await;
    let mut frames = Vec::new();
    loop {
        match recv(s).await {
            ServerMsg::Pong => return frames,
            other => frames.push(other),
        }
    }
}

fn hello(kind: Option<&str>) -> ClientMsg {
    ClientMsg::Hello {
        capabilities: Vec::new(),
        client_id: "authored-prs-it".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: kind.map(str::to_owned),
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
    }
}

/// Hello, Welcome, Subscribe, synced: the Welcome's features and every frame
/// that arrived before the Pong.
async fn connect_unix(
    env: &Env,
    kind: Option<&str>,
    topics: Vec<Topic>,
) -> (UnixStream, Vec<String>, Vec<ServerMsg>) {
    let mut s = UnixStream::connect(&env.socket_path)
        .await
        .expect("unix connect");
    send(&mut s, &hello(kind)).await;
    let features = match recv(&mut s).await {
        ServerMsg::Welcome { features, .. } => features,
        other => panic!("expected a Welcome, got {other:?}"),
    };
    send(&mut s, &subscribe(topics)).await;
    let frames = sync(&mut s).await;
    (s, features, frames)
}

async fn connect_tcp(env: &Env, topics: Vec<Topic>) -> (TcpStream, Vec<String>, Vec<ServerMsg>) {
    let mut s = TcpStream::connect(("127.0.0.1", env.tcp_port))
        .await
        .expect("tcp connect");
    send(&mut s, &hello(None)).await;
    let features = match recv(&mut s).await {
        ServerMsg::Welcome { features, .. } => features,
        other => panic!("expected a Welcome, got {other:?}"),
    };
    send(&mut s, &subscribe(topics)).await;
    let frames = sync(&mut s).await;
    (s, features, frames)
}

fn snapshot() -> AuthoredPrsSnapshot {
    let usage = UsageCounts::default();
    AuthoredPrsSnapshot {
        generated_at: Utc.with_ymd_and_hms(2026, 11, 14, 12, 0, 0).unwrap(),
        token: TokenState::Connected,
        relay: RelayInfo {
            state: RelayState::NotConfigured,
            since: None,
            org: "Carefeed".into(),
        },
        poll: PollInfo {
            state: PollState::Ok,
            checked_at: None,
            interval_secs: 60,
            resumes_at: None,
            retry_at: None,
        },
        refresh_blocked: None,
        hidden_orgs: vec![],
        total_open: 0,
        shown: 0,
        prs: vec![],
        usage: UsageView {
            window_secs: 3600,
            window: usage,
            since_start: usage,
        },
    }
}

fn is_authored(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::AuthoredPrs { .. })
}

async fn until(what: &str, mut cond: impl FnMut() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !cond() {
        assert!(
            std::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

// ── the Welcome ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn welcome_lists_authored_prs_v1_only_when_the_feature_is_enabled() {
    let on = env(true).await;
    let (_s, features, _) = connect_unix(&on, None, vec![]).await;
    assert!(
        features.contains(&"authored_prs_v1".to_string()),
        "{features:?}"
    );
    let (_t, features, _) = connect_tcp(&on, vec![]).await;
    assert!(
        features.contains(&"authored_prs_v1".to_string()),
        "{features:?}"
    );

    let off = env(false).await;
    let (_s, features, _) = connect_unix(&off, None, vec![]).await;
    assert!(
        !features.iter().any(|f| f.contains("authored_prs")),
        "{features:?}"
    );
    // The other capabilities are still advertised.
    assert!(
        features.contains(&"slash_commands_v1".to_string()),
        "{features:?}"
    );
}

// ── who may say what is being looked at ───────────────────────────────────────

#[tokio::test]
async fn the_operator_app_sets_the_demand_and_closing_its_connection_withdraws_it() {
    let env = env(true).await;
    let board = env.board.clone().unwrap();
    assert_eq!(board.current(), Demand::Idle, "nobody has said anything");

    let (mut app, _, _) = connect_unix(&env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
    send(
        &mut app,
        &ClientMsg::AuthoredPrsDemand {
            level: "visible".into(),
        },
    )
    .await;
    let frames = sync(&mut app).await;
    assert!(
        !frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })),
        "accepted: {frames:?}"
    );
    assert_eq!(board.current(), Demand::Visible);
    send(
        &mut app,
        &ClientMsg::AuthoredPrsDemand {
            level: "hidden".into(),
        },
    )
    .await;
    sync(&mut app).await;
    assert_eq!(board.current(), Demand::Hidden);
    send(&mut app, &ClientMsg::AuthoredPrsRefresh {}).await;
    let frames = sync(&mut app).await;
    assert!(
        !frames.iter().any(|m| matches!(m, ServerMsg::Error { .. })),
        "accepted: {frames:?}"
    );

    drop(app);
    until("the closed connection's demand to go", || {
        board.current() == Demand::Idle
    })
    .await;
}

#[tokio::test]
async fn two_operator_connections_take_the_higher_demand_and_each_withdraws_its_own() {
    let env = env(true).await;
    let board = env.board.clone().unwrap();
    let (mut a, _, _) = connect_unix(&env, Some("mac_app"), vec![]).await;
    let (mut b, _, _) = connect_unix(&env, Some("mac_app"), vec![]).await;
    send(
        &mut a,
        &ClientMsg::AuthoredPrsDemand {
            level: "hidden".into(),
        },
    )
    .await;
    sync(&mut a).await;
    send(
        &mut b,
        &ClientMsg::AuthoredPrsDemand {
            level: "visible".into(),
        },
    )
    .await;
    sync(&mut b).await;
    assert_eq!(board.current(), Demand::Visible);
    drop(b);
    until("b's demand to go", || board.current() == Demand::Hidden).await;
    drop(a);
    until("a's demand to go", || board.current() == Demand::Idle).await;
}

#[tokio::test]
async fn a_local_client_that_is_not_the_operator_app_cannot_set_the_demand() {
    let env = env(true).await;
    let board = env.board.clone().unwrap();
    // Not claiming to be the app.
    let (mut plain, _, _) = connect_unix(&env, None, vec![]).await;
    send(
        &mut plain,
        &ClientMsg::AuthoredPrsDemand {
            level: "visible".into(),
        },
    )
    .await;
    sync(&mut plain).await;
    assert_eq!(board.current(), Demand::Idle);
    // Claiming to be the app is not enough on its own (here the verifier says
    // yes, so use a claim of another kind).
    let (mut other, _, _) = connect_unix(&env, Some("cli"), vec![]).await;
    send(
        &mut other,
        &ClientMsg::AuthoredPrsDemand {
            level: "visible".into(),
        },
    )
    .await;
    sync(&mut other).await;
    assert_eq!(board.current(), Demand::Idle);
}

#[tokio::test]
async fn a_tcp_peer_cannot_set_the_demand_or_ask_for_a_refresh_and_is_refused() {
    let env = env(true).await;
    let board = env.board.clone().unwrap();
    let (mut tcp, _, _) = connect_tcp(&env, vec![]).await;
    send(
        &mut tcp,
        &ClientMsg::AuthoredPrsDemand {
            level: "visible".into(),
        },
    )
    .await;
    let first = sync(&mut tcp).await;
    send(&mut tcp, &ClientMsg::AuthoredPrsRefresh {}).await;
    let second = sync(&mut tcp).await;
    assert_eq!(board.current(), Demand::Idle, "the demand did not move");
    for (what, frames) in [("demand", first), ("refresh", second)] {
        assert!(
            frames.iter().any(|m| matches!(m, ServerMsg::Error { message } if message.contains("requires_secure_connection"))),
            "the {what} was refused with an error: {frames:?}"
        );
    }
}

// ── who is sent the list ──────────────────────────────────────────────────────

#[tokio::test]
async fn the_list_goes_only_to_a_client_that_names_the_topic_and_never_to_a_tcp_peer() {
    let env = env(true).await;
    let (mut names_it, _, _) = connect_unix(&env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
    let (mut everything, _, _) = connect_unix(&env, Some("mac_app"), vec![]).await;
    let (mut other_topic, _, _) = connect_unix(&env, None, vec![Topic::Perri]).await;
    let (mut tcp_names_it, _, _) = connect_tcp(&env, vec![Topic::AuthoredPrs]).await;
    let (mut tcp_everything, _, _) = connect_tcp(&env, vec![]).await;

    env.server.broadcast(ServerMsg::AuthoredPrs {
        snapshot: snapshot(),
    });

    let got = sync(&mut names_it).await;
    assert_eq!(got.iter().filter(|m| is_authored(m)).count(), 1, "{got:?}");
    for (who, frames) in [
        (
            "a subscribe-to-everything client",
            sync(&mut everything).await,
        ),
        ("a client of another topic", sync(&mut other_topic).await),
        ("a TCP peer naming the topic", sync(&mut tcp_names_it).await),
        (
            "a TCP peer subscribing to everything",
            sync(&mut tcp_everything).await,
        ),
    ] {
        assert!(
            !frames.iter().any(is_authored),
            "{who} was sent the list: {frames:?}"
        );
    }
}

#[tokio::test]
async fn the_latest_list_is_replayed_to_a_client_that_subscribes_later_and_names_the_topic() {
    let env = env(true).await;
    let (mut early, _, _) = connect_unix(&env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
    let mut first = snapshot();
    first.total_open = 1;
    let mut latest = snapshot();
    latest.total_open = 2;
    env.server
        .broadcast(ServerMsg::AuthoredPrs { snapshot: first });
    env.server
        .broadcast(ServerMsg::AuthoredPrs { snapshot: latest });
    let seen = sync(&mut early).await;
    assert_eq!(seen.iter().filter(|m| is_authored(m)).count(), 2);

    // The retained copy is updated by the server's own task; give it a moment.
    let mut replayed = None;
    for _ in 0..50 {
        let (_late, _, frames) =
            connect_unix(&env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
        if let Some(ServerMsg::AuthoredPrs { snapshot }) = frames.into_iter().find(is_authored) {
            replayed = Some(snapshot);
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let replayed = replayed.expect("the latest list is replayed on subscribe");
    assert_eq!(replayed.total_open, 2, "only the latest, not the first");

    // A subscribe-to-everything client is not replayed it, and nor is TCP.
    let (_all, _, frames) = connect_unix(&env, Some("mac_app"), vec![]).await;
    assert!(!frames.iter().any(is_authored), "{frames:?}");
    let (_tcp, _, frames) = connect_tcp(&env, vec![Topic::AuthoredPrs]).await;
    assert!(!frames.iter().any(is_authored), "{frames:?}");
}

// ── only the operator app is sent the list ────────────────────────────────────

/// Wait until the server has kept a copy of the latest list to replay.
async fn until_a_list_is_retained(env: &Env) {
    for _ in 0..100 {
        let (_probe, _, frames) =
            connect_unix(env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
        if frames.iter().any(is_authored) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the server never kept a copy of the list to replay");
}

/// Everything that reaches `s` over a short while, then a Pong behind it.
async fn quiet_then_sync<S: AsyncRead + AsyncWrite + Unpin>(s: &mut S) -> Vec<ServerMsg> {
    tokio::time::sleep(Duration::from_millis(60)).await;
    sync(s).await
}

#[tokio::test]
async fn a_local_client_that_is_not_the_operator_app_is_never_sent_the_list_even_when_it_names_the_topic(
) {
    let env = env(true).await;
    let (mut app, _, _) = connect_unix(&env, Some("mac_app"), vec![Topic::AuthoredPrs]).await;
    env.server.broadcast(ServerMsg::AuthoredPrs {
        snapshot: snapshot(),
    });
    assert_eq!(
        sync(&mut app)
            .await
            .iter()
            .filter(|m| is_authored(m))
            .count(),
        1,
        "control: the operator app is sent it"
    );
    until_a_list_is_retained(&env).await;

    // A client with no kind, one that says it is the CLI, and one that
    // claims to be something else: none of them may be sent the list.
    for kind in [None, Some("cli"), Some("some-agent-script")] {
        let who = format!("a `{kind:?}` client");

        // Naming the topic on subscribe: no replay of the retained list.
        let (mut client, _, frames) = connect_unix(&env, kind, vec![Topic::AuthoredPrs]).await;
        assert!(
            !frames.iter().any(is_authored),
            "{who} was replayed the list: {frames:?}"
        );

        // A live broadcast does not reach it either.
        env.server.broadcast(ServerMsg::AuthoredPrs {
            snapshot: snapshot(),
        });
        let frames = quiet_then_sync(&mut client).await;
        assert!(
            !frames.iter().any(is_authored),
            "{who} was sent a live list: {frames:?}"
        );

        // Subscribing again and naming it (with another topic beside it) is
        // no different: no replay, and no live frame.
        send(
            &mut client,
            &subscribe(vec![Topic::Perri, Topic::AuthoredPrs]),
        )
        .await;
        let frames = sync(&mut client).await;
        assert!(
            !frames.iter().any(is_authored),
            "{who} was replayed the list on a re-subscribe: {frames:?}"
        );
        env.server.broadcast(ServerMsg::AuthoredPrs {
            snapshot: snapshot(),
        });
        let frames = quiet_then_sync(&mut client).await;
        assert!(
            !frames.iter().any(is_authored),
            "{who} was sent a live list after a re-subscribe: {frames:?}"
        );
    }

    // And the operator app still is, live.
    let frames = quiet_then_sync(&mut app).await;
    assert!(
        frames.iter().filter(|m| is_authored(m)).count() >= 1,
        "the operator app kept receiving the list: {frames:?}"
    );
}

#[tokio::test]
async fn the_operator_app_that_subscribes_first_and_names_the_topic_later_is_sent_the_list() {
    let env = env(true).await;
    let (mut app, _, _) = connect_unix(&env, Some("mac_app"), vec![Topic::Perri]).await;
    env.server.broadcast(ServerMsg::AuthoredPrs {
        snapshot: snapshot(),
    });
    assert!(
        !quiet_then_sync(&mut app).await.iter().any(is_authored),
        "not named yet: not sent"
    );
    until_a_list_is_retained(&env).await;

    send(&mut app, &subscribe(vec![Topic::Perri, Topic::AuthoredPrs])).await;
    let frames = sync(&mut app).await;
    assert_eq!(
        frames.iter().filter(|m| is_authored(m)).count(),
        1,
        "the retained list is replayed to the topic it just added: {frames:?}"
    );
    env.server.broadcast(ServerMsg::AuthoredPrs {
        snapshot: snapshot(),
    });
    let frames = quiet_then_sync(&mut app).await;
    assert_eq!(frames.iter().filter(|m| is_authored(m)).count(), 1);
}
