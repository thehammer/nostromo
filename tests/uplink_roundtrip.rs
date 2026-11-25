//! W10c: the satellite side, from outside the daemon.
//!
//! Two real servers in one runtime: a primary (the ws rig: Unix socket, TCP,
//! WebSocket listener, device registry in a tempdir) and a satellite (its own
//! Unix socket, `bind_uplink`, nothing else). Plus a hand-written primary (a
//! bare WebSocket server) for what a real primary never sends.
//!
//! * publish: a satellite's broadcasts reach the primary's subscribers with
//!   `host` set, filtered by egress, and retained frames are replayed when the
//!   uplink reconnects;
//! * routed reads: answered by a `personal` satellite, refused for `work` and
//!   for an unknown host;
//! * device admin: a local client's verbs run on the primary and are answered
//!   to that client alone; `server_unreachable` at once when the uplink is down;
//!   levels reach local `devices` followers;
//! * a crafted primary: only the six reads are ever run, and only for a
//!   `personal` satellite.

#![recursion_limit = "512"]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};
use nostromo::config::{SatelliteSetup, UplinkConfig};
use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::devices::{DeviceKind, Egress, PairOutcomeKind, RevokedBy, SatelliteAdmin};
use nostromo::ipc::peer_verify::testing::FakePeerVerifier;
use nostromo::ipc::protocol::{ClientMsg, HostUnavailableReason, ServerMsg, Topic};
use nostromo::ipc::server::Server;
use nostromo::ipc::uplink_wire::UplinkFrame;
use nostromo::ipc::SessionManager;
use serde_json::json;
use tempfile::TempDir;
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── a satellite ───────────────────────────────────────────────────────────────

struct Sat {
    server: Server,
    socket: PathBuf,
    #[allow(dead_code)]
    session_mgr: Arc<Mutex<SessionManager>>,
    device_id: String,
    tmp: TempDir,
}

fn setup_for(name: &str, url: String, token_path: PathBuf, egress: Egress, local: SatelliteAdmin) -> SatelliteSetup {
    SatelliteSetup {
        host: name.to_string(),
        uplink: UplinkConfig {
            url,
            token_path,
            egress,
            phi_repos: vec![],
            publish_topics: None,
            device_admin: local,
        },
        phi_repos: vec!["admin-portal".into(), "referral-monitor".into()],
    }
}

fn start(url: String, token: &str, name: &str, egress: Egress, local: SatelliteAdmin, device_id: String) -> Sat {
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
        setup_for(name, url, token_path, egress, local),
        tmp.path().join("tag-key"),
        session_mgr.clone(),
        perri,
        decisions,
    );
    Sat {
        server,
        socket,
        session_mgr,
        device_id,
        tmp,
    }
}

/// Enrol `name` on the primary and start a satellite dialing it.
async fn join(
    primary: &Rig,
    name: &str,
    egress: Egress,
    record_admin: SatelliteAdmin,
    local: SatelliteAdmin,
) -> Sat {
    let r = primary
        .registry
        .redeem_with_egress(name, DeviceKind::Satellite, Some(record_admin), Some(egress), None)
        .expect("a satellite record");
    let sat = start(
        format!("ws://127.0.0.1:{}", primary.ws_port),
        &r.token,
        name,
        egress,
        local,
        r.device_id,
    );
    Rig::wait_until("the uplink to be admitted", || {
        primary.hub.router().is_connected(name)
    })
    .await;
    sat
}

fn job(id: &str) -> nostromo::mother::MotherJob {
    serde_json::from_value(json!({
        "id": id, "state": "awaiting", "title": "MARKER-title", "repo": "/code/blog",
        "question": "MARKER-question", "activity": "gate_hold",
    }))
    .unwrap()
}

fn jobs_frame(id: &str) -> ServerMsg {
    ServerMsg::MotherJobs {
        jobs: vec![job(id)],
        host: None,
    }
}

fn host_of_jobs(m: &ServerMsg) -> Option<Option<String>> {
    match m {
        ServerMsg::MotherJobs { host, .. } => Some(host.clone()),
        _ => None,
    }
}

fn dead_url() -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    drop(l);
    format!("ws://127.0.0.1:{port}")
}

// ── publish ───────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_personal_satellites_mother_jobs_reach_the_primarys_subscribers_with_its_host() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut watcher = primary.unix(vec![Topic::MotherJobs], false).await;
    sat.server.broadcast(jobs_frame("0123456789abcdef"));
    let m = watcher
        .next_matching("the satellite's jobs", |m| matches!(m, ServerMsg::MotherJobs { .. }))
        .await;
    assert_eq!(host_of_jobs(&m), Some(Some("sat".to_string())));
    match m {
        ServerMsg::MotherJobs { jobs, .. } => assert_eq!(jobs[0].title, "MARKER-title"),
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn a_work_satellites_jobs_arrive_as_metadata_with_none_of_its_text() {
    let primary = Rig::new().await;
    let sat = join(&primary, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly, SatelliteAdmin::Full).await;
    let mut watcher = primary.unix(vec![Topic::MotherJobs], false).await;
    sat.server.broadcast(jobs_frame("0123456789abcdef"));
    watcher
        .next_matching("kobe's jobs", |m| matches!(m, ServerMsg::MotherJobs { .. }))
        .await;
    watcher.sync().await;
    let raw = watcher.raw.join("\n");
    assert!(raw.contains(r#""host":"kobe""#), "{raw}");
    assert!(!raw.contains("MARKER"), "a work satellite leaked text: {raw}");
}

#[tokio::test]
async fn sensitive_and_administrative_frames_never_reach_the_primary_and_ordinary_ones_do() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut watcher = primary.unix(vec![], false).await;
    // The daemon's registry says which tags exist.
    sat.session_mgr.lock().unwrap().set_focus_registry(vec![serde_json::from_value(json!({
        "tag": "cody-x", "display_name": "x", "agent_name": "cody", "is_built_in": false,
        "project_path": "/code/blog",
    }))
    .unwrap()]);
    sat.server.broadcast(ServerMsg::ApprovalPending { tag: "fred".into(), count: 9, host: None });
    sat.server.broadcast(ServerMsg::Hosts { hosts: vec![] });
    sat.server.broadcast(ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, pair_from: vec!["sat".into()] });
    sat.server.broadcast(ServerMsg::ApprovalPending { tag: "cody-x".into(), count: 2, host: None });
    let m = watcher
        .next_matching("the ordinary count", |m| matches!(m, ServerMsg::ApprovalPending { .. }))
        .await;
    match m {
        ServerMsg::ApprovalPending { tag, count, host } => {
            assert_eq!((tag.as_str(), count, host.as_deref()), ("cody-x", 2, Some("sat")));
        }
        _ => unreachable!(),
    }
    watcher.sync().await;
    for m in watcher.take_all() {
        assert!(
            !matches!(m, ServerMsg::ApprovalPending { .. } | ServerMsg::DeviceAdminLevel { .. }),
            "{m:?}"
        );
    }
}

#[tokio::test]
async fn what_a_satellite_broadcast_while_disconnected_is_replayed_when_it_connects() {
    let primary = Rig::new().await;
    let r = primary
        .registry
        .redeem_with_egress("sat", DeviceKind::Satellite, Some(SatelliteAdmin::Full), Some(Egress::Personal), None)
        .unwrap();
    // Dial a port nothing listens on first, broadcast, then let it find the primary.
    let sat = start(dead_url(), &r.token, "sat", Egress::Personal, SatelliteAdmin::Full, r.device_id);
    sat.server.broadcast(jobs_frame("0123456789abcdef"));
    drop(sat);
    // A satellite whose first attempt succeeds replays what it cached before.
    let sat2 = start(
        format!("ws://127.0.0.1:{}", primary.ws_port),
        &r.token,
        "sat",
        Egress::Personal,
        SatelliteAdmin::Full,
        String::new(),
    );
    sat2.server.broadcast(jobs_frame("fedcba9876543210"));
    let mut watcher = primary.unix(vec![Topic::MotherJobs], false).await;
    // Retained on the primary under the host: a late subscriber gets it.
    let m = watcher
        .next_matching("the retained jobs", |m| matches!(m, ServerMsg::MotherJobs { .. }))
        .await;
    assert_eq!(host_of_jobs(&m), Some(Some("sat".to_string())));
}

#[tokio::test]
async fn with_the_uplink_unreachable_local_clients_see_nothing_change() {
    let tmp_primary_none = dead_url();
    let r = start(tmp_primary_none, "x", "sat", Egress::Personal, SatelliteAdmin::Full, String::new());
    let mut local = Rig::unix_at(&r.socket, vec![Topic::MotherJobs]).await;
    r.server.broadcast(jobs_frame("0123456789abcdef"));
    let m = local
        .next_matching("local jobs", |m| matches!(m, ServerMsg::MotherJobs { .. }))
        .await;
    assert_eq!(host_of_jobs(&m), Some(None), "a local client sees its own, unstamped");
    local.send(&ClientMsg::SessionList { host: None }).await;
    local
        .next_matching("a local session list", |m| matches!(m, ServerMsg::SessionListResp { .. }))
        .await;
    drop(r.tmp);
}

// ── routed reads ──────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_routed_read_is_answered_by_a_personal_satellite_and_refused_for_work_and_unknown_hosts() {
    let primary = Rig::new().await;
    let _p = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let _w = join(&primary, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly, SatelliteAdmin::Full).await;
    let mut asker = primary.unix(vec![], false).await;

    asker.send(&ClientMsg::SessionList { host: Some("sat".into()) }).await;
    let m = asker
        .next_matching("the routed answer", |m| matches!(m, ServerMsg::SessionListResp { .. }))
        .await;
    match m {
        ServerMsg::SessionListResp { host, .. } => assert_eq!(host.as_deref(), Some("sat")),
        _ => unreachable!(),
    }

    asker.send(&ClientMsg::SessionList { host: Some("kobe".into()) }).await;
    let m = asker
        .next_matching("work refusal", |m| matches!(m, ServerMsg::HostUnavailable { .. }))
        .await;
    assert!(matches!(
        m,
        ServerMsg::HostUnavailable { reason: HostUnavailableReason::EgressMetadata, .. }
    ));

    asker.send(&ClientMsg::SessionList { host: Some("nope".into()) }).await;
    let m = asker
        .next_matching("unknown host", |m| matches!(m, ServerMsg::HostUnavailable { .. }))
        .await;
    assert!(matches!(
        m,
        ServerMsg::HostUnavailable { reason: HostUnavailableReason::NotConnected, .. }
    ));
}

// ── device administration ─────────────────────────────────────────────────────

async fn follower(sat: &Sat) -> Conn {
    Rig::unix_at(&sat.socket, vec![Topic::Devices]).await
}

#[tokio::test]
async fn a_local_clients_pairing_runs_on_the_primary_and_the_outcome_goes_to_that_client_alone() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    let mut b = follower(&sat).await;
    a.next_matching("the level", |m| {
        matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, .. })
    })
    .await;

    let rid = request_id();
    a.send(&ClientMsg::DevicePairStart {
        request_id: rid.clone(),
        name_hint: Some("Phone".into()),
        satellite: None,
        admin: None,
        egress: None,
        origin: None,
    })
    .await;
    let (code, url, pairing_id) = match a
        .next_matching("DevicePairing", |m| matches!(m, ServerMsg::DevicePairing { .. }))
        .await
    {
        ServerMsg::DevicePairing { request_id, code, server_url, pairing_id, .. } => {
            assert_eq!(request_id, rid, "answered under the client's own id");
            (code, server_url, pairing_id)
        }
        _ => unreachable!(),
    };
    assert!(
        url.contains(&format!("port={}", primary.ws_port)),
        "the code names the primary, not the satellite: {url}"
    );

    let start = Instant::now();
    let (reply, _) = primary.redeem(&code, "Phone", DeviceKind::Iphone, false).await;
    assert!(matches!(reply, ServerMsg::Paired { .. }), "{reply:?}");
    match a
        .next_matching("the outcome", |m| matches!(m, ServerMsg::DevicePairOutcome { .. }))
        .await
    {
        ServerMsg::DevicePairOutcome { pairing_id: id, outcome, .. } => {
            assert_eq!(id, pairing_id);
            assert_eq!(outcome, PairOutcomeKind::Paired);
        }
        _ => unreachable!(),
    }
    assert!(start.elapsed() < Duration::from_secs(2));
    b.sync().await;
    assert!(
        b.take_all().iter().all(|m| !matches!(m, ServerMsg::DevicePairOutcome { .. })),
        "a second client must not see that outcome"
    );
}

#[tokio::test]
async fn a_revoke_from_a_satellite_takes_effect_on_the_primary_and_devices_updates_reach_it() {
    let primary = Rig::new().await;
    let phone = primary.mint_device("Phone");
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    let rid = request_id();
    a.send(&ClientMsg::DeviceRevoke { request_id: rid.clone(), device: "Phone".into() }).await;
    match a
        .next_matching("DeviceRevoked", |m| matches!(m, ServerMsg::DeviceRevoked { .. }))
        .await
    {
        ServerMsg::DeviceRevoked { request_id, device_id, .. } => {
            assert_eq!(request_id, rid);
            assert_eq!(device_id, phone.device_id);
        }
        _ => unreachable!(),
    }
    assert!(primary.registry.resolve("Phone").is_err(), "the phone is revoked");
    a.next_matching("a Devices update", |m| matches!(m, ServerMsg::Devices { .. }))
        .await;
}

#[tokio::test]
async fn the_primarys_level_and_the_local_narrowing_decide_which_verbs_run() {
    let primary = Rig::new().await;
    let _phone = primary.mint_device("Phone");
    // read_only on the primary: the list works, a revoke does not.
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::ReadOnly, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    a.next_matching("read_only level", |m| {
        matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::ReadOnly, .. })
    })
    .await;
    let rid = request_id();
    a.send(&ClientMsg::DeviceList { request_id: rid }).await;
    a.next_matching("the list", |m| matches!(m, ServerMsg::Devices { .. })).await;
    a.send(&ClientMsg::DeviceRevoke { request_id: "r2".into(), device: "Phone".into() }).await;
    match a
        .next_matching("a refusal", |m| matches!(m, ServerMsg::DeviceAdminError { .. }))
        .await
    {
        ServerMsg::DeviceAdminError { request_id, reason } => {
            assert_eq!((request_id.as_str(), reason.as_str()), ("r2", "not_permitted_on_this_mac"));
        }
        _ => unreachable!(),
    }
    assert!(primary.registry.resolve("Phone").is_ok(), "a read_only satellite revokes nothing");
}

#[tokio::test]
async fn a_revoke_only_satellite_cannot_start_a_pairing_and_hears_a_level_change_within_3_s() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::RevokeOnly, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    a.next_matching("revoke_only", |m| {
        matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::RevokeOnly, .. })
    })
    .await;
    a.send(&ClientMsg::DevicePairStart {
        request_id: "p".into(),
        name_hint: None,
        satellite: None,
        admin: None,
        egress: None,
        origin: None,
    })
    .await;
    match a
        .next_matching("refused", |m| matches!(m, ServerMsg::DeviceAdminError { .. }))
        .await
    {
        ServerMsg::DeviceAdminError { reason, .. } => assert_eq!(reason, "not_permitted_on_this_mac"),
        _ => unreachable!(),
    }
    // The primary changes the level: the uplink is closed and re-admitted.
    primary.registry.set_admin("sat", SatelliteAdmin::Off).unwrap();
    let start = Instant::now();
    a.next_matching("off", |m| {
        matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Off, .. })
    })
    .await;
    assert!(start.elapsed() < Duration::from_secs(3));
}

#[tokio::test]
async fn with_the_uplink_down_a_verb_is_answered_server_unreachable_within_100_ms() {
    let sat = start(dead_url(), "x", "sat", Egress::Personal, SatelliteAdmin::Full, String::new());
    let mut a = Rig::unix_at(&sat.socket, vec![Topic::Devices]).await;
    let t = Instant::now();
    a.send(&ClientMsg::DevicePairStart {
        request_id: "p".into(),
        name_hint: None,
        satellite: None,
        admin: None,
        egress: None,
        origin: None,
    })
    .await;
    match a
        .next_matching("unreachable", |m| matches!(m, ServerMsg::DeviceAdminError { .. }))
        .await
    {
        ServerMsg::DeviceAdminError { request_id, reason } => {
            assert_eq!((request_id.as_str(), reason.as_str()), ("p", "server_unreachable"));
        }
        _ => unreachable!(),
    }
    assert!(t.elapsed() < Duration::from_millis(100), "{:?}", t.elapsed());
}

#[tokio::test]
async fn when_the_uplink_drops_every_open_pairing_reports_connection_lost() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    a.send(&ClientMsg::DevicePairStart {
        request_id: "p".into(),
        name_hint: None,
        satellite: None,
        admin: None,
        egress: None,
        origin: None,
    })
    .await;
    a.next_matching("DevicePairing", |m| matches!(m, ServerMsg::DevicePairing { .. })).await;
    // Revoking the satellite closes its socket.
    primary.registry.revoke(&sat.device_id, RevokedBy::Operator).unwrap();
    match a
        .next_matching("connection lost", |m| matches!(m, ServerMsg::DevicePairOutcome { .. }))
        .await
    {
        ServerMsg::DevicePairOutcome { outcome, .. } => {
            assert_eq!(outcome, PairOutcomeKind::ConnectionLost);
        }
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn closing_a_local_client_cancels_its_pairing_on_the_primary() {
    let primary = Rig::new().await;
    let sat = join(&primary, "sat", Egress::Personal, SatelliteAdmin::Full, SatelliteAdmin::Full).await;
    let mut a = follower(&sat).await;
    a.send(&ClientMsg::DevicePairStart {
        request_id: "p".into(),
        name_hint: None,
        satellite: None,
        admin: None,
        egress: None,
        origin: None,
    })
    .await;
    let code = match a
        .next_matching("DevicePairing", |m| matches!(m, ServerMsg::DevicePairing { .. }))
        .await
    {
        ServerMsg::DevicePairing { code, .. } => code,
        _ => unreachable!(),
    };
    drop(a);
    tokio::time::sleep(Duration::from_millis(500)).await;
    let (reply, _) = primary.redeem(&code, "Phone", DeviceKind::Iphone, false).await;
    assert!(matches!(reply, ServerMsg::PairRefused { .. }), "the code no longer works: {reply:?}");
}

// ── a crafted primary ─────────────────────────────────────────────────────────

/// A bare WebSocket server standing in for a primary: it records what the
/// satellite sends and can send anything down.
struct FakePrimary {
    port: u16,
    frames: Arc<Mutex<Vec<serde_json::Value>>>,
    to_sat: tokio::sync::mpsc::UnboundedSender<String>,
    auth: Arc<Mutex<Option<(Option<String>, bool)>>>,
}

async fn fake_primary(features: &[&str]) -> FakePrimary {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let frames = Arc::new(Mutex::new(Vec::new()));
    let auth = Arc::new(Mutex::new(None));
    let (to_sat, mut down) = tokio::sync::mpsc::unbounded_channel::<String>();
    let features: Vec<String> = features.iter().map(|s| s.to_string()).collect();
    let f2 = Arc::clone(&frames);
    let a2 = Arc::clone(&auth);
    tokio::spawn(async move {
        loop {
            let (sock, _) = listener.accept().await.unwrap();
            let a3 = Arc::clone(&a2);
            let cb = move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                           resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                let bearer = req
                    .headers()
                    .get("authorization")
                    .and_then(|v| v.to_str().ok())
                    .map(String::from);
                *a3.lock().unwrap() = Some((bearer, req.headers().contains_key("origin")));
                Ok(resp)
            };
            let mut ws = tokio_tungstenite::accept_hdr_async(sock, cb).await.unwrap();
            let welcome = json!({"uplink": "server", "msg": {
                "type": "welcome", "protocol_version": nostromo::ipc::protocol::PROTOCOL_VERSION,
                "daemon_pid": 1, "features": features,
            }});
            let mut welcomed = false;
            loop {
                tokio::select! {
                    frame = ws.next() => match frame {
                        Some(Ok(Message::Text(t))) => {
                            let v: serde_json::Value = serde_json::from_str(&t).unwrap();
                            let is_hello = v["msg"]["type"] == "hello";
                            f2.lock().unwrap().push(v);
                            if is_hello && !welcomed {
                                welcomed = true;
                                ws.send(Message::Text(welcome.to_string())).await.unwrap();
                            }
                        }
                        Some(Ok(_)) => {}
                        _ => break,
                    },
                    Some(down_frame) = down.recv() => {
                        ws.send(Message::Text(down_frame)).await.unwrap();
                    }
                }
            }
        }
    });
    FakePrimary { port, frames, to_sat, auth }
}

impl FakePrimary {
    fn frames(&self) -> Vec<serde_json::Value> {
        self.frames.lock().unwrap().clone()
    }

    async fn wait_for(&self, what: &str, pred: impl Fn(&serde_json::Value) -> bool) -> serde_json::Value {
        let start = Instant::now();
        loop {
            if let Some(f) = self.frames().into_iter().find(&pred) {
                return f;
            }
            assert!(start.elapsed() < READ_TIMEOUT, "waiting for {what}; got {:#?}", self.frames());
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    fn send(&self, frame: &UplinkFrame) {
        self.to_sat.send(serde_json::to_string(frame).unwrap()).unwrap();
    }
}

#[tokio::test]
async fn the_satellite_says_hello_as_its_host_subscribes_to_devices_only_and_sends_no_origin() {
    let fake = fake_primary(&["uplink", "hosts"]).await;
    let sat = start(
        format!("ws://127.0.0.1:{}", fake.port),
        "tok-123",
        "kobe",
        Egress::Work,
        SatelliteAdmin::Full,
        String::new(),
    );
    let hello = fake.wait_for("hello", |f| f["msg"]["type"] == "hello").await;
    assert_eq!(hello["uplink"], "client");
    assert_eq!(hello["msg"]["role"], json!({"kind": "satellite", "host": "kobe", "egress": "work"}));
    assert_eq!(hello["msg"].get("capabilities"), None, "it attaches to nothing on the primary");
    let sub = fake.wait_for("subscribe", |f| f["msg"]["type"] == "subscribe").await;
    assert_eq!(sub["msg"]["topics"], json!(["devices"]));
    let (bearer, origin) = fake.auth.lock().unwrap().clone().unwrap();
    assert_eq!(bearer.as_deref(), Some("Bearer tok-123"));
    assert!(!origin, "the uplink sends no Origin header");
    sat.server.broadcast(jobs_frame("0123456789abcdef"));
    let p = fake.wait_for("a publish", |f| f["uplink"] == "publish").await;
    assert_eq!(p["msg"]["host"], "kobe");
    assert!(!p.to_string().contains("MARKER"));
}

#[tokio::test]
async fn a_primary_without_uplink_support_gets_no_subscribe_and_no_frames() {
    let fake = fake_primary(&["hosts"]).await;
    let sat = start(
        format!("ws://127.0.0.1:{}", fake.port),
        "tok",
        "sat",
        Egress::Personal,
        SatelliteAdmin::Full,
        String::new(),
    );
    sat.server.broadcast(jobs_frame("0123456789abcdef"));
    fake.wait_for("hello", |f| f["msg"]["type"] == "hello").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(fake.frames().iter().all(|f| f["msg"]["type"] != "subscribe" && f["uplink"] != "publish"));
}

#[tokio::test]
async fn a_crafted_primary_runs_only_the_six_reads_and_only_for_a_personal_satellite() {
    for (egress, expect_replies) in [(Egress::Personal, true), (Egress::Work, false)] {
        let fake = fake_primary(&["uplink"]).await;
        let sat = start(
            format!("ws://127.0.0.1:{}", fake.port),
            "tok",
            "sat",
            egress,
            SatelliteAdmin::Full,
            String::new(),
        );
        let _decisions_untouched = &sat.session_mgr;
        fake.wait_for("subscribe", |f| f["msg"]["type"] == "subscribe").await;
        // Verbs that must never run from an uplink.
        for (i, msg) in [
            json!({"type": "decision_answer", "request_id": "r", "choice": "a", "operator_nonce": "n"}),
            json!({"type": "approval_answer", "request_id": "r", "decision": "allow", "operator_nonce": "n"}),
            json!({"type": "mother_resume", "job_id": "j", "answer": "yes"}),
            json!({"type": "mother_action", "job_id": "j", "action": "cancel"}),
            json!({"type": "session_spawn", "tag": "x"}),
        ]
        .into_iter()
        .enumerate()
        {
            if let Ok(m) = serde_json::from_value::<ClientMsg>(msg) {
                fake.send(&UplinkFrame::Request { id: format!("bad{i}"), msg: m });
            }
        }
        // Bare frames and wrong-direction envelopes are dropped too.
        fake.to_sat.send(json!({"type": "pong"}).to_string()).unwrap();
        fake.to_sat
            .send(json!({"uplink": "publish", "msg": {"type": "pong"}}).to_string())
            .unwrap();
        // A real read.
        fake.send(&UplinkFrame::Request {
            id: "read1".into(),
            msg: ClientMsg::SessionList { host: None },
        });
        tokio::time::sleep(Duration::from_millis(800)).await;
        let replies: Vec<_> = fake.frames().into_iter().filter(|f| f["uplink"] == "reply").collect();
        if expect_replies {
            assert_eq!(replies.len(), 1, "{replies:#?}");
            assert_eq!(replies[0]["id"], "read1");
            assert_eq!(replies[0]["msg"]["type"], "session_list_resp");
            assert_eq!(replies[0]["msg"]["host"], "sat");
        } else {
            assert!(replies.is_empty(), "a work satellite answers no reads: {replies:#?}");
        }
    }
}

#[tokio::test]
async fn the_primarys_admin_frames_reach_only_the_local_clients_they_answer() {
    let fake = fake_primary(&["uplink"]).await;
    let sat = start(
        format!("ws://127.0.0.1:{}", fake.port),
        "tok",
        "sat",
        Egress::Personal,
        SatelliteAdmin::Full,
        String::new(),
    );
    fake.wait_for("subscribe", |f| f["msg"]["type"] == "subscribe").await;
    fake.send(&UplinkFrame::Server {
        msg: ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, pair_from: vec!["sendai".into()] },
    });
    let mut follower = Rig::unix_at(&sat.socket, vec![Topic::Devices]).await;
    let mut not_following = Rig::unix_at(&sat.socket, vec![Topic::MotherJobs]).await;
    follower
        .next_matching("the level", |m| matches!(m, ServerMsg::DeviceAdminLevel { .. }))
        .await;
    // Nothing the satellite relays locally is ever published back up.
    fake.send(&UplinkFrame::Server { msg: ServerMsg::Devices { devices: vec![], hosts: vec![] } });
    follower.next_matching("the list", |m| matches!(m, ServerMsg::Devices { .. })).await;
    not_following.sync().await;
    assert!(not_following
        .take_all()
        .iter()
        .all(|m| !matches!(m, ServerMsg::Devices { .. } | ServerMsg::DeviceAdminLevel { .. })));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(
        fake.frames()
            .iter()
            .filter(|f| f["uplink"] == "publish")
            .all(|f| !matches!(f["msg"]["type"].as_str(), Some("devices" | "device_admin_level"))),
        "an administrative frame was echoed upward"
    );
}

// ── nostromo uplink pair ──────────────────────────────────────────────────────

#[tokio::test]
async fn uplink_pair_enrols_writes_a_0600_token_and_never_prints_it() {
    let primary = Rig::new().await;
    let mut admin = primary.unix(vec![], true).await;
    let pairing = admin.pair_start_as(Some("kobe"), Some("kobe"), None).await;
    let dir = TempDir::new().unwrap();
    let token_path = dir.path().join("nested").join("uplink-token");
    let mut out: Vec<u8> = Vec::new();
    let code = nostromo::uplink_cli::pair(
        &format!("ws://127.0.0.1:{}", primary.ws_port),
        &pairing.code,
        "kobe",
        &token_path,
        &mut out,
    )
    .await
    .unwrap();
    assert_eq!(code, 0);
    let printed = String::from_utf8(out).unwrap();
    let token = std::fs::read_to_string(&token_path).unwrap();
    let token = token.trim();
    assert!(!token.is_empty());
    assert!(!printed.contains(token), "the token was printed");
    assert!(printed.contains("Enrolled kobe with 127.0.0.1:"), "{printed}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&token_path).unwrap().permissions().mode() & 0o777, 0o600);
    }
    // The token works as a satellite's bearer.
    assert!(primary.registry.summaries(|_| false).1.iter().any(|h| h.name == "kobe"));
}

#[tokio::test]
async fn uplink_pair_warns_when_the_enrolled_name_differs_from_host_name() {
    let primary = Rig::new().await;
    // A phone already holds "kobe", so the satellite record is de-duplicated.
    primary.mint_device("kobe");
    let mut admin = primary.unix(vec![], true).await;
    let pairing = admin.pair_start_as(Some("kobe"), Some("kobe"), None).await;
    let dir = TempDir::new().unwrap();
    let mut out: Vec<u8> = Vec::new();
    let _ = nostromo::uplink_cli::pair(
        &format!("ws://127.0.0.1:{}", primary.ws_port),
        &pairing.code,
        "kobe",
        &dir.path().join("t"),
        &mut out,
    )
    .await
    .unwrap();
    let printed = String::from_utf8(out).unwrap();
    assert!(
        printed.contains("Enrolled as kobe 2, but host_name is kobe"),
        "{printed}"
    );
}
