//! W10, the primary's side of satellite mode, from outside the daemon.
//!
//! A real daemon front end (Unix socket, TCP listener, WebSocket listener, the
//! device registry in a tempdir) and a *crafted satellite*: a test client that
//! dials the WebSocket port with a satellite's bearer token and speaks the
//! uplink protocol by hand, one `UplinkFrame` envelope per text frame. Nothing
//! here asks a satellite implementation to behave; the point is what the
//! primary does with a satellite that does not.
//!
//! * admission: a satellite token plus a `Hello` naming its own host and egress
//!   is a satellite, and nothing else is (role refusals close 4001; a role
//!   claimed on the Unix or TCP socket is ignored); its level is told to it
//!   alone and a change of level closes the uplink (1012);
//! * what a satellite may send and receive: its handshake, `Ping` and the
//!   device-admin verbs judged per level; no routed read; only `Devices`;
//! * ingest: what a satellite publishes reaches the broadcast channel only as a
//!   host-carrying frame stamped with its own name and in the shape its egress
//!   allows, within the rate and size limits;
//! * routed reads: the six read verbs go to a `personal` satellite under an
//!   id it cannot choose, its answers go back to the requester alone, and
//!   nothing else is ever sent down.

#![recursion_limit = "512"]

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use futures::{SinkExt, StreamExt};
use nostromo::ipc::device_hub::{DeviceHub, Dispatched};
use nostromo::ipc::devices::{
    DeviceKind, DeviceRegistry, Egress, PairOutcomeKind, PairRefusedReason, RevokedBy,
    SatelliteAdmin, TokenCheck,
};
use nostromo::ipc::peer::{
    redact_for_network, redact_for_uplink_metadata, PeerTrust, SensitiveTags,
};
use nostromo::ipc::protocol::{
    ClientMsg, HelloRole, HostUnavailableReason, ServerMsg, Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::router::UplinkLimits;
use nostromo::ipc::ws::WsLimits;
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio::sync::{broadcast, mpsc};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── a crafted satellite ───────────────────────────────────────────────────────

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// A satellite's uplink socket, driven by hand. Every frame it reads is kept
/// as the raw JSON the primary sent (an envelope, or whatever else it wrote).
struct Sat {
    ws: WsStream,
    frames: Vec<Value>,
    closed: Option<Option<u16>>,
    minted: Minted,
    egress: Egress,
    /// The `DeviceAdminLevel` the admission was answered with.
    level: Option<(SatelliteAdmin, Vec<String>)>,
}

fn role(host: &str, egress: Egress) -> Value {
    json!({"kind": "satellite", "host": host, "egress": egress.as_str()})
}

fn kind_of(frame: &Value) -> &str {
    frame.get("uplink").and_then(Value::as_str).unwrap_or("")
}

fn decode_server(frame: &Value) -> ServerMsg {
    serde_json::from_value(frame["msg"].clone())
        .unwrap_or_else(|e| panic!("an undecodable server frame ({e}): {frame}"))
}

impl Sat {
    async fn dial(rig: &Rig, minted: &Minted, egress: Egress) -> Sat {
        let mut req = format!("ws://127.0.0.1:{}/", rig.ws_port)
            .into_client_request()
            .expect("a request");
        req.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {}", minted.token)).unwrap(),
        );
        let (ws, _) = tokio_tungstenite::connect_async(req)
            .await
            .expect("the WebSocket upgrade completes");
        Sat {
            ws,
            frames: Vec::new(),
            closed: None,
            minted: minted.clone(),
            egress,
            level: None,
        }
    }

    /// Dial, `Hello` as the record's own host and egress, `Subscribe` to
    /// everything, and wait for the `DeviceAdminLevel` that says it is in.
    async fn admit(rig: &Rig, minted: &Minted, egress: Egress) -> Sat {
        let mut s = Sat::dial(rig, minted, egress).await;
        s.hello(Some(role(&minted.name, egress))).await;
        s.next_server("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await;
        s.subscribe(&[]).await;
        match s
            .next_server("DeviceAdminLevel", |m| {
                matches!(m, ServerMsg::DeviceAdminLevel { .. })
            })
            .await
        {
            ServerMsg::DeviceAdminLevel { level, pair_from } => s.level = Some((level, pair_from)),
            _ => unreachable!(),
        }
        s
    }

    async fn reconnect(&self, rig: &Rig) -> Sat {
        Sat::admit(rig, &self.minted, self.egress).await
    }

    // ── writing ───────────────────────────────────────────────────────────────

    /// Send a text frame; false if the socket refused it (it may be closing).
    async fn send_text(&mut self, text: String) -> bool {
        self.ws.send(Message::Text(text)).await.is_ok()
    }

    async fn send_value(&mut self, v: Value) -> bool {
        self.send_text(v.to_string()).await
    }

    async fn hello(&mut self, role: Option<Value>) {
        let mut hello = json!({
            "type": "hello",
            "client_id": "crafted-satellite",
            "protocol_version": PROTOCOL_VERSION,
        });
        if let Some(r) = role {
            hello["role"] = r;
        }
        self.client_json(hello).await;
    }

    async fn subscribe(&mut self, topics: &[Topic]) {
        self.client(&Conn::subscribe(topics.to_vec())).await;
    }

    async fn client_json(&mut self, msg: Value) {
        assert!(
            self.send_value(json!({"uplink": "client", "msg": msg}))
                .await
        );
    }

    async fn client(&mut self, msg: &ClientMsg) {
        assert!(
            self.send_value(json!({"uplink": "client", "msg": msg}))
                .await
        );
    }

    async fn publish(&mut self, msg: &ServerMsg) -> bool {
        self.send_value(json!({"uplink": "publish", "msg": msg}))
            .await
    }

    async fn reply(&mut self, id: &str, msg: &ServerMsg) -> bool {
        self.send_value(json!({"uplink": "reply", "id": id, "msg": msg}))
            .await
    }

    async fn close(&mut self) {
        let _ = self.ws.close(None).await;
    }

    // ── reading ───────────────────────────────────────────────────────────────

    /// Read one more frame (or the close), waiting at most `within`.
    async fn pull(&mut self, within: Duration) {
        if self.closed.is_some() {
            return;
        }
        match tokio::time::timeout(within, self.ws.next()).await {
            Err(_) => {}
            Ok(Some(Ok(Message::Text(t)))) => {
                let v: Value = serde_json::from_str(&t)
                    .unwrap_or_else(|e| panic!("a non-JSON frame ({e}): {t}"));
                self.frames.push(v);
            }
            Ok(Some(Ok(Message::Close(frame)))) => {
                self.closed = Some(frame.map(|CloseFrame { code, .. }| u16::from(code)));
            }
            Ok(Some(Ok(_))) => {}
            Ok(Some(Err(_))) | Ok(None) => self.closed = Some(None),
        }
    }

    /// Read for `window`, keeping what arrives.
    async fn listen(&mut self, window: Duration) {
        let end = Instant::now() + window;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            if left.is_zero() || self.closed.is_some() {
                return;
            }
            self.pull(left).await;
        }
    }

    /// The first unread `server` frame `pred` accepts.
    async fn next_server(&mut self, what: &str, pred: impl Fn(&ServerMsg) -> bool) -> ServerMsg {
        let end = Instant::now() + READ_TIMEOUT;
        loop {
            let at = self
                .frames
                .iter()
                .position(|f| kind_of(f) == "server" && pred(&decode_server(f)));
            if let Some(i) = at {
                return decode_server(&self.frames.remove(i));
            }
            if let Some(code) = self.closed {
                panic!(
                    "closed ({code:?}) while waiting for {what}; unread: {:#?}",
                    self.frames
                );
            }
            let left = end.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "timed out waiting for {what}; unread: {:#?}",
                self.frames
            );
            self.pull(left).await;
        }
    }

    /// The first unread routed request: its id and its `msg`.
    async fn next_request(&mut self, what: &str) -> (String, Value) {
        let end = Instant::now() + READ_TIMEOUT;
        loop {
            if let Some(i) = self.frames.iter().position(|f| kind_of(f) == "request") {
                let f = self.frames.remove(i);
                return (
                    f["id"].as_str().expect("a request id").to_string(),
                    f["msg"].clone(),
                );
            }
            if let Some(code) = self.closed {
                panic!(
                    "closed ({code:?}) while waiting for {what}; unread: {:#?}",
                    self.frames
                );
            }
            let left = end.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "timed out waiting for {what}; unread: {:#?}",
                self.frames
            );
            self.pull(left).await;
        }
    }

    /// Every unread routed request, as (id, msg).
    fn requests(&self) -> Vec<(String, Value)> {
        self.frames
            .iter()
            .filter(|f| kind_of(f) == "request")
            .map(|f| (f["id"].as_str().unwrap_or("").to_string(), f["msg"].clone()))
            .collect()
    }

    /// Every unread `server` frame, decoded.
    fn server_msgs(&self) -> Vec<ServerMsg> {
        self.frames
            .iter()
            .filter(|f| kind_of(f) == "server")
            .map(decode_server)
            .collect()
    }

    async fn expect_close(&mut self) -> Option<u16> {
        let end = Instant::now() + READ_TIMEOUT;
        while self.closed.is_none() {
            let left = end.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero(),
                "not closed in time; unread: {:#?}",
                self.frames
            );
            self.pull(left).await;
        }
        self.closed.unwrap()
    }

    // ── asking ────────────────────────────────────────────────────────────────

    /// Send the verb `make` builds and wait for the frame that carries its
    /// `request_id`.
    async fn call(&mut self, make: impl FnOnce(String) -> ClientMsg) -> ServerMsg {
        let rid = request_id();
        let msg = make(rid.clone());
        self.client(&msg).await;
        self.next_server("the answer to a request", move |m| {
            serde_json::to_value(m)
                .ok()
                .and_then(|v| v.get("request_id").cloned())
                == Some(json!(rid))
        })
        .await
    }

    /// A round trip that always has an answer, at every level: a revoke of a
    /// device that does not exist. Everything this satellite sent before it
    /// has been handled when the answer is back.
    async fn sync(&mut self) {
        self.call(|rid| ClientMsg::DeviceRevoke {
            device: format!("no-such-device-{rid}"),
            request_id: rid,
        })
        .await;
    }

    async fn device_list(&mut self) -> ServerMsg {
        let rid = request_id();
        self.client(&ClientMsg::DeviceList {
            request_id: rid.clone(),
        })
        .await;
        self.next_server("Devices or a refusal", move |m| {
            matches!(m, ServerMsg::Devices { .. })
                || matches!(m, ServerMsg::DeviceAdminError { request_id, .. } if *request_id == rid)
        })
        .await
    }
}

// ── fixtures ──────────────────────────────────────────────────────────────────

fn dec(v: Value) -> ServerMsg {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("decode {v}: {e}"))
}

fn text_of(m: &ServerMsg) -> String {
    serde_json::to_string(m).unwrap()
}

fn type_of(m: &ServerMsg) -> String {
    serde_json::to_value(m).unwrap()["type"]
        .as_str()
        .unwrap()
        .to_string()
}

fn enrol(rig: &Rig, name: &str, egress: Egress, admin: SatelliteAdmin) -> Minted {
    let r = rig
        .registry
        .redeem_with_egress(name, DeviceKind::Satellite, Some(admin), Some(egress), None)
        .expect("a satellite record");
    Minted {
        device_id: r.device_id,
        token: r.token,
        name: r.name,
    }
}

async fn join(rig: &Rig, name: &str, egress: Egress, admin: SatelliteAdmin) -> Sat {
    let m = enrol(rig, name, egress, admin);
    Sat::admit(rig, &m, egress).await
}

fn all_topics() -> Vec<Topic> {
    vec![
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
        Topic::Terminal,
        Topic::Devices,
    ]
}

static FENCES: AtomicU64 = AtomicU64::new(1);

/// Broadcast a frame nobody else sends and wait until every watcher has it.
/// The broadcast channel is ordered: whatever was broadcast before it, and
/// was going to be delivered to a watcher, is in its inbox by then.
async fn fence(rig: &Rig, watchers: &mut [&mut Conn]) {
    let tag = format!("fence-{}", FENCES.fetch_add(1, Ordering::SeqCst));
    rig.server.broadcast(ServerMsg::Error {
        message: tag.clone(),
    });
    for w in watchers.iter_mut() {
        let tag = tag.clone();
        w.next_matching(
            "the fence",
            move |m| matches!(m, ServerMsg::Error { message } if *message == tag),
        )
        .await;
    }
}

fn mentions(msgs: &[ServerMsg], needle: &str) -> bool {
    msgs.iter()
        .any(|m| text_of(m).to_lowercase().contains(&needle.to_lowercase()))
}

fn jobs_frame(host: Option<&str>, ids: &[&str]) -> ServerMsg {
    let jobs: Vec<Value> = ids
        .iter()
        .map(|id| json!({"id": id, "state": "running", "title": "an ordinary job"}))
        .collect();
    let mut v = json!({"type": "mother_jobs", "jobs": jobs});
    if let Some(h) = host {
        v["host"] = json!(h);
    }
    dec(v)
}

/// (host, job ids) of every `MotherJobs` frame in `msgs`.
fn jobs_in(msgs: &[ServerMsg]) -> Vec<(Option<String>, Vec<String>)> {
    msgs.iter()
        .filter_map(|m| match m {
            ServerMsg::MotherJobs { jobs, host } => {
                Some((host.clone(), jobs.iter().map(|j| j.id.clone()).collect()))
            }
            _ => None,
        })
        .collect()
}

fn session_list_resp(host: Option<&str>) -> ServerMsg {
    let mut v = json!({"type": "session_list_resp", "sessions": []});
    if let Some(h) = host {
        v["host"] = json!(h);
    }
    dec(v)
}

fn turns(tag: &str) -> ServerMsg {
    dec(json!({"type": "session_turns", "tag": tag, "turns": []}))
}

fn delta(tag: &str) -> ServerMsg {
    dec(json!({"type": "session_turn_delta", "tag": tag,
        "delta": {"delta": "block_appended", "turn_id": "1", "block": {"kind": "text", "text": "hi"}}}))
}

fn is_not_permitted(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::DeviceAdminError { reason, .. } if reason == "not_permitted_on_this_mac")
}

fn is_unknown_device(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::DeviceAdminError { reason, .. } if reason == "unknown_device")
}

fn rate_limited(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::Error { message } if message == "rate_limited")
}

fn is_network_refusal(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::Error { message } if message.starts_with("requires_secure_connection"))
}

/// A Unix subscriber (every topic), a paired phone, a `personal` or `work`
/// `kobe` to publish through, and a `personal` `sendai` to watch.
struct Scene {
    rig: Rig,
    unix: Conn,
    phone: Conn,
    kobe: Sat,
    sendai: Sat,
}

async fn scene(kobe_egress: Egress) -> Scene {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut unix = rig.unix(all_topics(), false).await;
    let mut phone = rig.device(&phone_m.token, &[], vec![]).await;
    let kobe = join(&rig, "kobe", kobe_egress, SatelliteAdmin::RevokeOnly).await;
    let sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    fence(&rig, &mut [&mut unix, &mut phone]).await;
    unix.take_all();
    phone.take_all();
    Scene {
        rig,
        unix,
        phone,
        kobe,
        sendai,
    }
}

impl Scene {
    /// Everything `kobe` published has reached (or been kept from) the
    /// broadcast channel and the Unix and phone observers have caught up.
    async fn settle(&mut self) {
        self.kobe.sync().await;
        fence(&self.rig, &mut [&mut self.unix, &mut self.phone]).await;
    }
}

/// The retained frames a new Unix subscriber is replayed, once `ready` holds
/// (the retention task is asynchronous).
async fn replay_until(rig: &Rig, ready: impl Fn(&[ServerMsg]) -> bool) -> Vec<ServerMsg> {
    let start = Instant::now();
    loop {
        let mut c = rig.unix(vec![], false).await;
        let frames = c.take_all();
        if ready(&frames) {
            return frames;
        }
        assert!(
            start.elapsed() < READ_TIMEOUT,
            "the replay never held what was expected: {frames:#?}"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// Admission (F, W10-20)
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_satellite_naming_its_own_host_and_egress_is_told_its_level_and_who_it_may_pair_from() {
    let rig = Rig::new().await;
    enrol(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full);
    enrol(&rig, "tokyo", Egress::Personal, SatelliteAdmin::Full);
    enrol(&rig, "osaka", Egress::Personal, SatelliteAdmin::ReadOnly);
    let kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::ReadOnly).await;
    assert_eq!(
        kobe.level,
        Some((
            SatelliteAdmin::ReadOnly,
            vec!["sendai".to_string(), "tokyo".to_string()]
        )),
        "its level and the names of the `full` hosts"
    );
}

#[tokio::test]
async fn the_primary_announces_a_connected_satellite_to_its_subscribers_and_announces_it_gone() {
    let rig = Rig::new().await;
    let mut unix = rig.unix(vec![], false).await;
    let m = enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly);
    let mut kobe = Sat::admit(&rig, &m, Egress::Work).await;

    let hosts = unix
        .next_matching(
            "Hosts naming kobe",
            |m| matches!(m, ServerMsg::Hosts { hosts } if hosts.iter().any(|h| h.name == "kobe")),
        )
        .await;
    match hosts {
        ServerMsg::Hosts { hosts } => {
            let kobe = hosts.iter().find(|h| h.name == "kobe").unwrap();
            assert_eq!(kobe.egress, Egress::Work);
        }
        _ => unreachable!(),
    }
    unix.take_all();

    kobe.close().await;
    unix.next_matching(
        "Hosts without kobe",
        |m| matches!(m, ServerMsg::Hosts { hosts } if hosts.iter().all(|h| h.name != "kobe")),
    )
    .await;
}

/// The ways a satellite's `Hello` can fail to be the record's own.
fn wrong_roles() -> Vec<(&'static str, Option<Value>)> {
    vec![
        ("no role", None),
        ("another host", Some(role("sendai", Egress::Work))),
        ("another egress", Some(role("kobe", Egress::Personal))),
        ("the host in another case", Some(role("KOBE", Egress::Work))),
        ("a client role", Some(json!({"kind": "client"}))),
    ]
}

#[tokio::test]
async fn a_satellite_token_with_no_role_or_the_wrong_host_or_the_wrong_egress_is_closed_4001() {
    let rig = Rig::new().await;
    let m = enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    for (what, claimed) in wrong_roles() {
        let mut s = Sat::dial(&rig, &m, Egress::Work).await;
        s.hello(claimed).await;
        assert_eq!(s.expect_close().await, Some(CLOSE_UNAUTHORIZED), "{what}");
    }
    assert!(
        !rig.hub.router().is_connected("kobe"),
        "a refused role is never entered in the host table"
    );
}

#[tokio::test]
async fn a_satellite_token_with_no_role_or_the_wrong_host_or_the_wrong_egress_is_told_unauthorized_role(
) {
    let rig = Rig::new().await;
    let m = enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    for (what, claimed) in wrong_roles() {
        let mut s = Sat::dial(&rig, &m, Egress::Work).await;
        s.hello(claimed).await;
        let told = s
            .next_server("Unauthorized", |m| {
                matches!(m, ServerMsg::Unauthorized { .. })
            })
            .await;
        assert!(
            matches!(&told, ServerMsg::Unauthorized { reason } if reason == "role"),
            "{what}: {told:?}"
        );
    }
}

fn pretender_hello() -> ClientMsg {
    ClientMsg::Hello {
        capabilities: vec![],
        client_id: "pretender".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: None,
        role: Some(HelloRole::Satellite {
            host: "kobe".into(),
            egress: Egress::Work,
        }),
    }
}

#[tokio::test]
async fn a_phone_or_ipad_token_claiming_the_satellite_role_is_told_unauthorized_role() {
    let rig = Rig::new().await;
    enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    for kind in [DeviceKind::Iphone, DeviceKind::Ipad] {
        let r = rig
            .registry
            .redeem("a device", kind, None, None)
            .expect("a device");
        let mut conn = rig.device_raw(&r.token).await;
        conn.send(&pretender_hello()).await;
        let told = conn
            .next_matching("Unauthorized", |m| {
                matches!(m, ServerMsg::Unauthorized { .. })
            })
            .await;
        assert!(
            matches!(&told, ServerMsg::Unauthorized { reason } if reason == "role"),
            "{kind:?}: {told:?}"
        );
    }
    assert!(!rig.hub.router().is_connected("kobe"));
}

#[tokio::test]
async fn a_phone_or_ipad_token_claiming_the_satellite_role_is_closed_4001() {
    let rig = Rig::new().await;
    enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    for kind in [DeviceKind::Iphone, DeviceKind::Ipad] {
        let r = rig
            .registry
            .redeem("a device", kind, None, None)
            .expect("a device");
        let mut conn = rig.device_raw(&r.token).await;
        conn.send(&pretender_hello()).await;
        assert_eq!(
            conn.expect_close().await,
            Some(CLOSE_UNAUTHORIZED),
            "{kind:?}"
        );
    }
}

#[tokio::test]
async fn a_satellite_role_claimed_on_the_unix_socket_is_ignored() {
    let rig = Rig::new().await;
    enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    enrol(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full);
    let mut c = rig.unix_raw().await;
    c.send(&ClientMsg::Hello {
        capabilities: vec![],
        client_id: "claimer".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: None,
        role: Some(HelloRole::Satellite {
            host: "kobe".into(),
            egress: Egress::Work,
        }),
    })
    .await;
    c.next_matching("Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    c.send(&Conn::subscribe(vec![])).await;
    c.sync().await;

    // An ordinary local client: it is served a read a satellite is refused,
    // and sees the whole device list a satellite never does.
    c.send(&ClientMsg::SessionList { host: None }).await;
    c.next_matching("SessionListResp", |m| {
        matches!(m, ServerMsg::SessionListResp { .. })
    })
    .await;
    let (_, hosts) = c.device_list().await;
    let names: Vec<&str> = hosts.iter().map(|h| h.name.as_str()).collect();
    assert!(
        names.contains(&"kobe") && names.contains(&"sendai"),
        "{names:?}"
    );
    c.sync().await;
    assert!(
        !c.inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::DeviceAdminLevel { .. })),
        "it was never told a satellite level: {:?}",
        c.inbox
    );
    assert!(
        !rig.hub.router().is_connected("kobe"),
        "it is not in the host table"
    );
}

#[tokio::test]
async fn a_satellite_role_claimed_on_the_tcp_listener_is_ignored() {
    let rig = Rig::new().await;
    let phone = rig.mint_device("iPhone");
    enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    let mut c = rig.tcp_raw().await;
    c.send(&ClientMsg::Hello {
        capabilities: vec![],
        client_id: "claimer".into(),
        protocol_version: PROTOCOL_VERSION,
        client_kind: None,
        role: Some(HelloRole::Satellite {
            host: "kobe".into(),
            egress: Egress::Work,
        }),
    })
    .await;
    c.next_matching("Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    c.send(&Conn::subscribe(vec![])).await;
    c.sync().await;

    // The ordinary TCP rules: a read is served, device administration is not.
    c.send(&ClientMsg::SessionList { host: None }).await;
    c.next_matching("SessionListResp", |m| {
        matches!(m, ServerMsg::SessionListResp { .. })
    })
    .await;
    c.send(&ClientMsg::DeviceList {
        request_id: "tcp-list".into(),
    })
    .await;
    c.send(&ClientMsg::DeviceRevoke {
        request_id: "tcp-revoke".into(),
        device: phone.device_id.clone(),
    })
    .await;
    c.sync().await;
    let seen = c.take_all();
    assert!(
        seen.iter().filter(|m| is_network_refusal(m)).count() >= 2,
        "both device verbs get the network refusal: {seen:?}"
    );
    assert!(
        !seen.iter().any(|m| matches!(
            m,
            ServerMsg::Devices { .. }
                | ServerMsg::DeviceAdminLevel { .. }
                | ServerMsg::DeviceAdminError { .. }
                | ServerMsg::DeviceRevoked { .. }
        )),
        "{seen:?}"
    );
    assert!(
        matches!(
            rig.registry.validate(&phone.token),
            TokenCheck::Active { .. }
        ),
        "the phone was not revoked"
    );
}

#[tokio::test]
async fn a_satellite_enrolled_through_the_pairing_flow_with_no_level_is_revoke_only() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start_as(None, Some("kobe"), None).await;
    let (reply, _) = rig
        .redeem(
            &pairing.code,
            "whatever-the-mac-calls-itself",
            DeviceKind::Satellite,
            false,
        )
        .await;
    let m = match reply {
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
    };
    assert_eq!(m.name, "kobe", "a satellite is named for its host");
    let kobe = Sat::admit(&rig, &m, Egress::Work).await;
    assert_eq!(
        kobe.level.as_ref().map(|(l, _)| *l),
        Some(SatelliteAdmin::RevokeOnly)
    );
}

#[tokio::test]
async fn a_satellite_recorded_with_no_level_is_revoke_only_on_either_egress() {
    let rig = Rig::new().await;
    for (name, egress) in [("kobe", Egress::Work), ("sendai", Egress::Personal)] {
        let r = rig
            .registry
            .redeem_with_egress(name, DeviceKind::Satellite, None, Some(egress), None)
            .unwrap();
        let m = Minted {
            device_id: r.device_id,
            token: r.token,
            name: r.name,
        };
        let sat = Sat::admit(&rig, &m, egress).await;
        assert_eq!(
            sat.level.as_ref().map(|(l, _)| *l),
            Some(SatelliteAdmin::RevokeOnly),
            "{name}"
        );
    }
}

#[tokio::test]
async fn lowering_a_connected_satellites_level_closes_it_1012_and_it_is_readmitted_at_the_new_level(
) {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    assert_eq!(
        kobe.level.as_ref().map(|(l, _)| *l),
        Some(SatelliteAdmin::Full)
    );

    rig.hub.set_admin("kobe", SatelliteAdmin::ReadOnly).unwrap();
    assert_eq!(kobe.expect_close().await, Some(1012));

    let again = tokio::time::timeout(Duration::from_secs(3), kobe.reconnect(&rig))
        .await
        .expect("readmitted within 3 s");
    assert_eq!(
        again.level.as_ref().map(|(l, _)| *l),
        Some(SatelliteAdmin::ReadOnly)
    );
}

#[tokio::test]
async fn raising_a_connected_satellites_level_also_closes_it_1012() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Off).await;
    rig.hub.set_admin("kobe", SatelliteAdmin::Full).unwrap();
    assert_eq!(kobe.expect_close().await, Some(1012));
    let again = tokio::time::timeout(Duration::from_secs(3), kobe.reconnect(&rig))
        .await
        .expect("readmitted within 3 s");
    assert_eq!(
        again.level.as_ref().map(|(l, _)| *l),
        Some(SatelliteAdmin::Full)
    );
}

#[tokio::test]
async fn revoking_a_connected_satellite_closes_it_4001_and_it_cannot_come_back() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    rig.registry
        .revoke(&kobe.minted.device_id, RevokedBy::Operator)
        .unwrap();
    assert_eq!(kobe.expect_close().await, Some(CLOSE_UNAUTHORIZED));

    let mut again = Sat::dial(&rig, &kobe.minted, Egress::Work).await;
    let told = again
        .next_server_or_bare("Unauthorized", |m| {
            matches!(m, ServerMsg::Unauthorized { .. })
        })
        .await;
    assert!(matches!(told, ServerMsg::Unauthorized { .. }));
    assert_eq!(again.expect_close().await, Some(CLOSE_UNAUTHORIZED));
}

#[tokio::test]
async fn a_revoked_satellites_token_is_not_served_as_a_phone() {
    let rig = Rig::new().await;
    let m = enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    rig.registry
        .revoke(&m.device_id, RevokedBy::Operator)
        .unwrap();

    // The way a phone connects: a `Hello` with no role.
    let mut conn = rig.device_raw(&m.token).await;
    let _ = conn
        .try_send_text(serde_json::to_string(&Conn::hello(&[], false)).unwrap())
        .await;
    assert_eq!(conn.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    assert!(
        !conn
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::Welcome { .. })),
        "the revoked record was greeted: {:?}",
        conn.inbox
    );
    assert!(!rig.hub.router().is_connected("kobe"));
}

impl Sat {
    /// Like `next_server`, for a refusal the primary may write bare (before it
    /// knows the socket is an uplink) or in an envelope.
    async fn next_server_or_bare(
        &mut self,
        what: &str,
        pred: impl Fn(&ServerMsg) -> bool,
    ) -> ServerMsg {
        let end = Instant::now() + READ_TIMEOUT;
        loop {
            let found = self.frames.iter().position(|f| {
                let body = if kind_of(f) == "server" {
                    f["msg"].clone()
                } else {
                    f.clone()
                };
                serde_json::from_value::<ServerMsg>(body).is_ok_and(|m| pred(&m))
            });
            if let Some(i) = found {
                let f = self.frames.remove(i);
                let body = if kind_of(&f) == "server" {
                    f["msg"].clone()
                } else {
                    f
                };
                return serde_json::from_value(body).unwrap();
            }
            let left = end.saturating_duration_since(Instant::now());
            assert!(
                !left.is_zero() && self.closed.is_none(),
                "waiting for {what}; unread: {:#?}",
                self.frames
            );
            self.pull(left).await;
        }
    }
}

#[tokio::test]
async fn a_level_is_told_to_its_satellite_alone_and_a_change_in_the_full_hosts_reaches_the_others()
{
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut unix = rig.unix(vec![Topic::Devices], false).await;
    let mut phone = rig.device(&phone_m.token, &[], vec![Topic::Devices]).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full).await;
    assert_eq!(
        sendai.level,
        Some((
            SatelliteAdmin::Full,
            vec!["kobe".to_string(), "sendai".to_string()]
        ))
    );
    fence(&rig, &mut [&mut unix, &mut phone]).await;
    unix.take_all();
    phone.take_all();
    sendai.frames.clear();

    rig.hub.set_admin("kobe", SatelliteAdmin::ReadOnly).unwrap();
    assert_eq!(kobe.expect_close().await, Some(1012));

    // Sendai is told who the `full` hosts are now, without being dropped.
    let fresh = sendai
        .next_server("a fresh DeviceAdminLevel", |m| {
            matches!(m, ServerMsg::DeviceAdminLevel { .. })
        })
        .await;
    assert!(
        matches!(
            &fresh,
            ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, pair_from }
                if pair_from == &vec!["sendai".to_string()]
        ),
        "its own level, and the new list: {fresh:?}"
    );
    sendai.sync().await;
    assert!(sendai.closed.is_none(), "it stays connected");
    sendai.listen(Duration::from_millis(250)).await;
    assert!(
        !sendai.server_msgs().iter().any(|m| matches!(
            m,
            ServerMsg::DeviceAdminLevel { level, .. } if *level != SatelliteAdmin::Full
        )),
        "kobe's level was never delivered to sendai"
    );

    fence(&rig, &mut [&mut unix, &mut phone]).await;
    for (who, inbox) in [
        ("the Unix subscriber", &unix.inbox),
        ("the phone", &phone.inbox),
    ] {
        assert!(
            !inbox.iter().any(|m| matches!(
                m,
                ServerMsg::DeviceAdminLevel { level, .. } if *level == SatelliteAdmin::ReadOnly
            )),
            "{who} was sent a satellite's level: {inbox:?}"
        );
    }
    assert!(
        !phone
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::DeviceAdminLevel { .. })),
        "a phone is never sent a level: {:?}",
        phone.inbox
    );
}

#[tokio::test]
async fn a_local_client_that_follows_the_device_list_is_told_it_may_do_everything() {
    let rig = Rig::new().await;
    enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    let mut at_connect = rig.unix(vec![Topic::Devices], false).await;
    at_connect
        .next_matching("its level", |m| {
            matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, pair_from } if pair_from.is_empty())
        })
        .await;

    // One that starts with other topics and adds the device list later.
    let mut later = rig.unix(vec![Topic::MotherJobs], false).await;
    assert!(!later
        .inbox
        .iter()
        .any(|m| matches!(m, ServerMsg::DeviceAdminLevel { .. })));
    later.send(&Conn::subscribe(vec![Topic::Devices])).await;
    later
        .next_matching("its level", |m| {
            matches!(m, ServerMsg::DeviceAdminLevel { level: SatelliteAdmin::Full, pair_from } if pair_from.is_empty())
        })
        .await;
}

#[tokio::test]
async fn a_refusal_reaches_an_off_satellite_and_never_a_paired_phone() {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut phone = rig.device(&phone_m.token, &[], vec![Topic::Devices]).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Off).await;
    assert_eq!(
        kobe.level.as_ref().map(|(l, _)| *l),
        Some(SatelliteAdmin::Off)
    );

    let refusal = kobe
        .call(|rid| ClientMsg::DeviceRevoke {
            request_id: rid,
            device: "iPhone".into(),
        })
        .await;
    assert!(is_not_permitted(&refusal), "{refusal:?}");

    // The phone asks for the same thing: whatever it is told, it is not that.
    phone
        .send(&ClientMsg::DeviceRevoke {
            request_id: "phone-revoke".into(),
            device: "iPhone".into(),
        })
        .await;
    phone.sync().await;
    rig.hub.broadcast_devices();
    fence(&rig, &mut [&mut phone]).await;
    assert!(
        !phone.inbox.iter().any(|m| matches!(
            m,
            ServerMsg::DeviceAdminError { .. }
                | ServerMsg::DeviceAdminLevel { .. }
                | ServerMsg::Devices { .. }
        )),
        "{:?}",
        phone.inbox
    );
    assert!(matches!(
        rig.registry.validate(&phone_m.token),
        TokenCheck::Active { .. }
    ));
}

#[tokio::test]
async fn a_satellite_at_read_only_or_above_is_sent_the_device_list_and_an_off_one_is_not() {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut phone = rig.device(&phone_m.token, &[], vec![Topic::Devices]).await;
    let mut off = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Off).await;
    let mut read_only = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::ReadOnly).await;
    off.frames.clear();
    read_only.frames.clear();

    rig.hub.broadcast_devices();
    let devices = read_only
        .next_server("Devices", |m| matches!(m, ServerMsg::Devices { .. }))
        .await;
    match devices {
        ServerMsg::Devices { devices, hosts } => {
            assert!(
                devices.iter().any(|d| d.name == "iPhone"),
                "phones stay listed"
            );
            assert_eq!(hosts.len(), 1, "only its own record");
        }
        _ => unreachable!(),
    }
    fence(&rig, &mut [&mut phone]).await;
    off.listen(Duration::from_millis(250)).await;
    assert!(
        !off.server_msgs()
            .iter()
            .any(|m| matches!(m, ServerMsg::Devices { .. })),
        "an off satellite gets no device list: {:?}",
        off.frames
    );
    assert!(
        !phone
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::Devices { .. })),
        "a phone never does: {:?}",
        phone.inbox
    );
}

// ═════════════════════════════════════════════════════════════════════════════
// What a satellite may send and receive (B, C, D)
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_satellite_asking_to_read_is_refused_and_nothing_reaches_the_host_it_named() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full).await;
    sendai.frames.clear();
    kobe.frames.clear();

    let host = || Some("sendai".to_string());
    let reads = vec![
        ClientMsg::SessionAttach {
            tag: "cody-1".into(),
            host: host(),
        },
        ClientMsg::SessionAttach {
            tag: "cody-1".into(),
            host: None,
        },
        ClientMsg::SessionList { host: host() },
        ClientMsg::SessionList { host: None },
        ClientMsg::FocusList { host: host() },
        ClientMsg::FocusList { host: None },
        ClientMsg::SessionModelGet {
            tag: "cody-1".into(),
            host: host(),
        },
        ClientMsg::SessionModelGet {
            tag: "cody-1".into(),
            host: None,
        },
        ClientMsg::ActivitySnapshotRequest {
            tag: "cody-1".into(),
            host: host(),
        },
        ClientMsg::ActivitySnapshotRequest {
            tag: "cody-1".into(),
            host: None,
        },
        ClientMsg::SessionDetach {
            tag: "cody-1".into(),
            host: host(),
        },
        ClientMsg::SessionDetach {
            tag: "cody-1".into(),
            host: None,
        },
    ];
    let n = reads.len();
    for r in &reads {
        kobe.client(r).await;
    }
    kobe.sync().await;
    let seen = kobe.server_msgs();
    let refusals = seen.iter().filter(|m| is_network_refusal(m)).count();
    assert_eq!(refusals, n, "each read is refused: {seen:?}");
    assert!(
        seen.iter().all(|m| is_network_refusal(m)
            || matches!(
                m,
                ServerMsg::Devices { .. } | ServerMsg::DeviceAdminError { .. }
            )),
        "and nothing else is answered: {seen:?}"
    );
    sendai.listen(Duration::from_millis(250)).await;
    assert!(
        sendai.requests().is_empty(),
        "nothing was routed to sendai: {:?}",
        sendai.frames
    );
}

#[tokio::test]
async fn a_satellite_subscribed_to_everything_is_sent_nothing_but_the_device_list() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    kobe.subscribe(&[]).await;
    kobe.sync().await;
    kobe.frames.clear();

    rig.server.broadcast(ServerMsg::MotherJobs {
        jobs: vec![],
        host: None,
    });
    rig.server.broadcast(dec(
        json!({"type": "session_state", "tag": "cody-1", "state": "idle"}),
    ));
    rig.server.broadcast(ServerMsg::MotherStatusline(
        serde_json::from_value(json!({"running": 1, "queued": 0, "failed": 0, "awaiting": 0}))
            .unwrap(),
    ));
    rig.hub.broadcast_devices();
    kobe.next_server("Devices", |m| matches!(m, ServerMsg::Devices { .. }))
        .await;
    kobe.listen(Duration::from_millis(250)).await;
    let rest = kobe.server_msgs();
    assert!(
        rest.iter().all(|m| matches!(m, ServerMsg::Devices { .. })),
        "only device lists reach a satellite: {rest:?}"
    );

    // Naming every topic changes nothing.
    kobe.subscribe(&all_topics()).await;
    kobe.sync().await;
    kobe.frames.clear();
    rig.server.broadcast(ServerMsg::MotherJobs {
        jobs: vec![],
        host: None,
    });
    kobe.listen(Duration::from_millis(250)).await;
    assert!(
        kobe.server_msgs()
            .iter()
            .all(|m| matches!(m, ServerMsg::Devices { .. })),
        "{:?}",
        kobe.frames
    );
}

#[tokio::test]
async fn a_satellite_is_listed_only_its_own_record_and_the_phones() {
    let rig = Rig::new().await;
    rig.mint_device("iPhone");
    rig.mint_device("iPad");
    enrol(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full);
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    let listed = kobe.device_list().await;
    match listed {
        ServerMsg::Devices { devices, hosts } => {
            let phones: Vec<&str> = devices.iter().map(|d| d.name.as_str()).collect();
            assert!(
                phones.contains(&"iPhone") && phones.contains(&"iPad"),
                "{phones:?}"
            );
            assert_eq!(hosts.len(), 1, "{hosts:?}");
            assert_eq!(hosts[0].id, kobe.minted.device_id);
            assert_eq!(hosts[0].name, "kobe");
        }
        other => panic!("{other:?}"),
    }
    // The same cut applies to what is broadcast.
    kobe.frames.clear();
    rig.hub.broadcast_devices();
    match kobe
        .next_server("a broadcast Devices", |m| {
            matches!(m, ServerMsg::Devices { .. })
        })
        .await
    {
        ServerMsg::Devices { hosts, .. } => {
            assert!(
                hosts.iter().all(|h| h.id == kobe.minted.device_id),
                "{hosts:?}"
            );
        }
        _ => unreachable!(),
    }
}

/// What the per-level table (C) says, from the primary's side: every verb a
/// satellite may send, at one level.
async fn the_admin_table_at(level: SatelliteAdmin) {
    let rig = Rig::new().await;
    let phone = rig.mint_device("iPhone");
    let sendai_m = enrol(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full);
    let mut kobe = join(&rig, "kobe", Egress::Work, level).await;
    let kobe_id = kobe.minted.device_id.clone();
    let at_least_revoke = matches!(level, SatelliteAdmin::Full | SatelliteAdmin::RevokeOnly);

    // DeviceList: refused at off, otherwise run with the hosts cut to its own.
    match kobe.device_list().await {
        r if level == SatelliteAdmin::Off => {
            assert!(is_not_permitted(&r), "DeviceList at off: {r:?}")
        }
        ServerMsg::Devices { hosts, .. } => {
            assert_eq!(hosts.len(), 1, "DeviceList: {hosts:?}");
            assert_eq!(hosts[0].id, kobe_id);
        }
        other => panic!("DeviceList: {other:?}"),
    }

    // DeviceRevoke of any satellite record, itself included: never done, and
    // the record stays active. Below `revoke_only` the verb itself is refused;
    // from `revoke_only` up the answer is the one for a name that does not
    // exist (see `a_revoke_naming_a_satellite_is_answered_like_one_naming_nothing`).
    for (what, device) in [
        ("sendai by name", "sendai".to_string()),
        ("sendai by id", sendai_m.device_id.clone()),
        ("itself by name", "kobe".to_string()),
        ("itself by id", kobe_id.clone()),
    ] {
        let r = kobe
            .call(|rid| ClientMsg::DeviceRevoke {
                request_id: rid,
                device,
            })
            .await;
        if at_least_revoke {
            assert!(
                is_unknown_device(&r),
                "DeviceRevoke of {what} at {level:?}: {r:?}"
            );
        } else {
            assert!(
                is_not_permitted(&r),
                "DeviceRevoke of {what} at {level:?}: {r:?}"
            );
        }
    }
    assert!(matches!(
        rig.registry.validate(&sendai_m.token),
        TokenCheck::Active { .. }
    ));
    assert!(matches!(
        rig.registry.validate(&kobe.minted.token),
        TokenCheck::Active { .. }
    ));

    // DevicePairStart for a device code: only at full.
    let r = kobe
        .call(|rid| ClientMsg::DevicePairStart {
            request_id: rid,
            name_hint: None,
            satellite: None,
            admin: None,
            egress: None,
            origin: Some("client-a".into()),
        })
        .await;
    if level == SatelliteAdmin::Full {
        assert!(
            matches!(r, ServerMsg::DevicePairing { .. }),
            "DevicePairStart at full: {r:?}"
        );
    } else {
        assert!(is_not_permitted(&r), "DevicePairStart at {level:?}: {r:?}");
    }

    // An enrolment code: refused at every level, and no record appears.
    let before = rig.registry.summaries(|_| false);
    let r = kobe
        .call(|rid| ClientMsg::DevicePairStart {
            request_id: rid,
            name_hint: None,
            satellite: Some("rogue".into()),
            admin: Some(SatelliteAdmin::Full),
            egress: Some(Egress::Personal),
            origin: Some("client-a".into()),
        })
        .await;
    assert!(is_not_permitted(&r), "an enrolment at {level:?}: {r:?}");
    assert_eq!(
        rig.registry.summaries(|_| false),
        before,
        "no record appeared"
    );

    // DevicePairCancel: runs from revoke_only up (and finds nothing to cancel),
    // refused below.
    let r = kobe
        .call(|rid| ClientMsg::DevicePairCancel {
            request_id: rid,
            pairing_id: "no-such-pairing".into(),
            origin: None,
        })
        .await;
    if at_least_revoke {
        assert!(
            matches!(&r, ServerMsg::DeviceAdminError { reason, .. } if reason == "unknown_pairing"),
            "DevicePairCancel at {level:?}: {r:?}"
        );
    } else {
        assert!(is_not_permitted(&r), "DevicePairCancel at {level:?}: {r:?}");
    }

    // DeviceSetAdmin: refused at every level, and no level changes.
    for (host, admin) in [
        ("sendai", SatelliteAdmin::Off),
        ("kobe", SatelliteAdmin::Full),
    ] {
        let r = kobe
            .call(|rid| ClientMsg::DeviceSetAdmin {
                request_id: rid,
                host: host.into(),
                admin,
            })
            .await;
        assert!(
            is_not_permitted(&r),
            "DeviceSetAdmin {host} at {level:?}: {r:?}"
        );
    }
    assert_eq!(
        rig.registry
            .satellite_info(&sendai_m.device_id)
            .unwrap()
            .admin,
        SatelliteAdmin::Full
    );
    assert_eq!(rig.registry.satellite_info(&kobe_id).unwrap().admin, level);

    // DeviceUnpairSelf is a phone's verb: refused, the record stays.
    kobe.client(&ClientMsg::DeviceUnpairSelf).await;
    kobe.sync().await;
    assert!(
        !kobe
            .server_msgs()
            .iter()
            .any(|m| matches!(m, ServerMsg::DeviceUnpaired)),
        "{:?}",
        kobe.frames
    );
    assert!(kobe.closed.is_none());
    assert!(
        rig.registry.satellite_info(&kobe_id).is_some(),
        "still enrolled"
    );

    // DeviceRevoke of a phone: from revoke_only up.
    let r = kobe
        .call(|rid| ClientMsg::DeviceRevoke {
            request_id: rid,
            device: "iPhone".into(),
        })
        .await;
    if at_least_revoke {
        assert!(
            matches!(&r, ServerMsg::DeviceRevoked { device_id, .. } if *device_id == phone.device_id),
            "DeviceRevoke of a phone at {level:?}: {r:?}"
        );
        assert_eq!(rig.registry.validate(&phone.token), TokenCheck::Revoked);
    } else {
        assert!(
            is_not_permitted(&r),
            "DeviceRevoke of a phone at {level:?}: {r:?}"
        );
        assert!(matches!(
            rig.registry.validate(&phone.token),
            TokenCheck::Active { .. }
        ));
    }
}

#[tokio::test]
async fn a_full_satellite_gets_exactly_what_the_admin_table_gives_full() {
    the_admin_table_at(SatelliteAdmin::Full).await;
}

#[tokio::test]
async fn a_revoke_only_satellite_gets_exactly_what_the_admin_table_gives_revoke_only() {
    the_admin_table_at(SatelliteAdmin::RevokeOnly).await;
}

#[tokio::test]
async fn a_read_only_satellite_gets_exactly_what_the_admin_table_gives_read_only() {
    the_admin_table_at(SatelliteAdmin::ReadOnly).await;
}

#[tokio::test]
async fn an_off_satellite_gets_exactly_what_the_admin_table_gives_off() {
    the_admin_table_at(SatelliteAdmin::Off).await;
}

/// A `DeviceAdminError` with the request id taken out, for comparing answers.
fn without_request_id(m: &ServerMsg) -> Value {
    let mut v = serde_json::to_value(m).unwrap();
    v["request_id"] = json!("-");
    v
}

#[tokio::test]
async fn a_revoke_naming_a_satellite_is_answered_like_one_naming_nothing() {
    for level in [SatelliteAdmin::RevokeOnly, SatelliteAdmin::Full] {
        let rig = Rig::new().await;
        let sendai_m = enrol(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full);
        let mut kobe = join(&rig, "kobe", Egress::Work, level).await;
        let kobe_id = kobe.minted.device_id.clone();

        let mut answers = Vec::new();
        for (what, device) in [
            ("an enrolled satellite by name", "sendai".to_string()),
            (
                "an enrolled satellite by name in another case",
                "SendAI".to_string(),
            ),
            ("an enrolled satellite by id", sendai_m.device_id.clone()),
            ("itself by name", "kobe".to_string()),
            ("itself by id", kobe_id.clone()),
            ("a name nobody has", "osaka".to_string()),
            ("an id nobody has", "dev_000000".to_string()),
        ] {
            let r = kobe
                .call(|rid| ClientMsg::DeviceRevoke {
                    request_id: rid,
                    device,
                })
                .await;
            assert!(is_unknown_device(&r), "{what} at {level:?}: {r:?}");
            answers.push((what, without_request_id(&r)));
        }
        // Byte for byte the same answer, whichever the target.
        let (_, first) = &answers[0];
        for (what, a) in &answers {
            assert_eq!(a, first, "{what} at {level:?} is told apart from the rest");
        }
        // And nothing was revoked.
        assert!(matches!(
            rig.registry.validate(&sendai_m.token),
            TokenCheck::Active { .. }
        ));
        assert!(matches!(
            rig.registry.validate(&kobe.minted.token),
            TokenCheck::Active { .. }
        ));
    }
}

// ── pairing relay ─────────────────────────────────────────────────────────────

async fn relay_pairing(sat: &mut Sat, origin: &str) -> (String, String, String) {
    let origin = origin.to_string();
    match sat
        .call(|rid| ClientMsg::DevicePairStart {
            request_id: rid,
            name_hint: Some("Relayed iPhone".into()),
            satellite: None,
            admin: None,
            egress: None,
            origin: Some(origin),
        })
        .await
    {
        ServerMsg::DevicePairing {
            code,
            pairing_id,
            server_url,
            ..
        } => (code, pairing_id, server_url),
        other => panic!("expected DevicePairing, got {other:?}"),
    }
}

#[tokio::test]
async fn a_full_satellite_relays_a_pairing_for_the_primary_and_hears_it_paired() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    let (code, pairing_id, server_url) = relay_pairing(&mut kobe, "client-a").await;
    assert_eq!(
        server_url,
        format!(
            "nostromo://pair?v=1&host=127.0.0.1&port={}&code={code}",
            rig.ws_port
        ),
        "the code points at the primary"
    );

    let (reply, _) = rig
        .redeem(&code, "Kitchen iPhone", DeviceKind::Iphone, false)
        .await;
    assert!(matches!(reply, ServerMsg::Paired { .. }), "{reply:?}");
    let outcome = tokio::time::timeout(
        Duration::from_secs(2),
        kobe.next_server(
            "the outcome",
            |m| matches!(m, ServerMsg::DevicePairOutcome { pairing_id: p, .. } if *p == pairing_id),
        ),
    )
    .await
    .expect("the satellite hears the outcome within 2 s");
    assert!(
        matches!(
            outcome,
            ServerMsg::DevicePairOutcome {
                outcome: PairOutcomeKind::Paired,
                ..
            }
        ),
        "{outcome:?}"
    );
}

#[tokio::test]
async fn a_pairing_is_cancelled_only_by_the_local_client_that_started_it() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    let (code, pairing_id, _) = relay_pairing(&mut kobe, "client-a").await;

    // Another local client of the same satellite, and a cancel naming none.
    for other in [Some("client-b".to_string()), None] {
        let r = kobe
            .call(|rid| ClientMsg::DevicePairCancel {
                request_id: rid,
                pairing_id: pairing_id.clone(),
                origin: other.clone(),
            })
            .await;
        assert!(
            matches!(&r, ServerMsg::DeviceAdminError { reason, .. } if reason == "unknown_pairing"),
            "{other:?}: {r:?}"
        );
    }
    // The pairing is still open: the code still redeems.
    let (reply, _) = rig.redeem(&code, "Phone", DeviceKind::Iphone, false).await;
    assert!(matches!(reply, ServerMsg::Paired { .. }), "{reply:?}");
}

#[tokio::test]
async fn the_local_client_that_started_a_relayed_pairing_can_cancel_it() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    // A revoke_only satellite may not start a pairing; use a full one for it.
    let mut full = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full).await;
    let (code, pairing_id, _) = relay_pairing(&mut full, "client-a").await;
    // Another satellite cannot cancel it either: it does not own it.
    let r = kobe
        .call(|rid| ClientMsg::DevicePairCancel {
            request_id: rid,
            pairing_id: pairing_id.clone(),
            origin: Some("client-a".into()),
        })
        .await;
    assert!(
        matches!(&r, ServerMsg::DeviceAdminError { reason, .. } if reason == "unknown_pairing"),
        "{r:?}"
    );

    full.client(&ClientMsg::DevicePairCancel {
        request_id: request_id(),
        pairing_id: pairing_id.clone(),
        origin: Some("client-a".into()),
    })
    .await;
    let outcome = full
        .next_server(
            "the cancelled outcome",
            |m| matches!(m, ServerMsg::DevicePairOutcome { pairing_id: p, .. } if *p == pairing_id),
        )
        .await;
    assert!(
        matches!(
            outcome,
            ServerMsg::DevicePairOutcome {
                outcome: PairOutcomeKind::Cancelled,
                ..
            }
        ),
        "{outcome:?}"
    );
    let (reply, _) = rig.redeem(&code, "Phone", DeviceKind::Iphone, false).await;
    assert!(
        matches!(
            reply,
            ServerMsg::PairRefused {
                reason: PairRefusedReason::Invalid
            }
        ),
        "{reply:?}"
    );
}

#[tokio::test]
async fn a_satellite_that_drops_takes_its_open_pairings_with_it() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    let (code, _, _) = relay_pairing(&mut kobe, "client-a").await;
    kobe.close().await;
    Rig::wait_until("the uplink to end", || {
        !rig.hub.router().is_connected("kobe")
    })
    .await;
    let (reply, _) = rig.redeem(&code, "Phone", DeviceKind::Iphone, false).await;
    assert!(matches!(reply, ServerMsg::PairRefused { .. }), "{reply:?}");
}

// ── caps on the pairings a satellite relays ───────────────────────────────────

/// Limits whose client bucket is no obstacle, for tests about what a
/// satellite may ask for rather than how fast.
fn roomy_client_bucket() -> WsLimits {
    WsLimits {
        uplink: UplinkLimits {
            client_rate: 100_000.0,
            client_burst: 100_000.0,
            ..Default::default()
        },
        ..Default::default()
    }
}

/// Send one `DevicePairStart` per entry of `origins` without waiting between
/// them, then read every answer: the codes of the pairings opened and the
/// reasons of the refusals.
async fn start_pairings(sat: &mut Sat, origins: Vec<Option<String>>) -> (Vec<String>, Vec<String>) {
    let ids: Vec<String> = origins.iter().map(|_| request_id()).collect();
    for (rid, origin) in ids.iter().zip(&origins) {
        sat.client(&ClientMsg::DevicePairStart {
            request_id: rid.clone(),
            name_hint: None,
            satellite: None,
            admin: None,
            egress: None,
            origin: origin.clone(),
        })
        .await;
    }
    let (mut codes, mut refusals) = (Vec::new(), Vec::new());
    for rid in ids {
        let want = rid.clone();
        let answer = sat
            .next_server("the answer to a pairing start", move |m| {
                matches!(
                    m,
                    ServerMsg::DevicePairing { request_id, .. }
                        | ServerMsg::DeviceAdminError { request_id, .. } if *request_id == want
                )
            })
            .await;
        match answer {
            ServerMsg::DevicePairing { code, .. } => codes.push(code),
            ServerMsg::DeviceAdminError { reason, .. } => refusals.push(reason),
            _ => unreachable!(),
        }
    }
    (codes, refusals)
}

#[tokio::test]
async fn three_hundred_pairing_starts_from_one_local_client_open_four_and_the_rest_are_refused() {
    let rig = Rig::with_limits(roomy_client_bucket()).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;

    let (codes, refusals) =
        start_pairings(&mut kobe, vec![Some("client-a".to_string()); 300]).await;

    assert_eq!(codes.len(), 4, "pairings opened for one local client");
    assert_eq!(refusals.len(), 296);
    assert!(
        refusals.iter().all(|r| r == "too_many_pairings"),
        "{refusals:?}"
    );
    assert!(kobe.closed.is_none(), "the satellite is not closed for it");
    // Exactly the four are open: each redeems.
    for (i, code) in codes.iter().enumerate() {
        let (reply, _) = rig
            .redeem(code, &format!("Phone {i}"), DeviceKind::Iphone, false)
            .await;
        assert!(matches!(reply, ServerMsg::Paired { .. }), "{reply:?}");
    }
    // Their slots are free again.
    let (codes, refusals) = start_pairings(&mut kobe, vec![Some("client-a".to_string())]).await;
    assert_eq!((codes.len(), refusals.len()), (1, 0));
}

#[tokio::test]
async fn three_hundred_pairing_starts_across_many_local_clients_open_sixteen_in_all() {
    let rig = Rig::with_limits(roomy_client_bucket()).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    // Thirty clients, ten attempts each: no client is over its own four
    // until its fifth, but the connection as a whole holds sixteen.
    let origins: Vec<Option<String>> = (0..300)
        .map(|i| Some(format!("client-{}", i % 30)))
        .collect();

    let (codes, refusals) = start_pairings(&mut kobe, origins).await;

    assert_eq!(codes.len(), 16, "pairings opened through one connection");
    assert_eq!(refusals.len(), 284);
    assert!(
        refusals.iter().all(|r| r == "too_many_pairings"),
        "{refusals:?}"
    );
    // Another satellite's pairings are not counted against this one.
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::Full).await;
    let (codes, _) = start_pairings(&mut sendai, vec![Some("client-0".to_string())]).await;
    assert_eq!(codes.len(), 1);
}

// ── the downgrade race (D), at the hub ────────────────────────────────────────

struct HubFixture {
    _dir: tempfile::TempDir,
    registry: Arc<DeviceRegistry>,
    hub: Arc<DeviceHub>,
    phone: Minted,
    sat: Minted,
}

fn hub_fixture(level: SatelliteAdmin) -> HubFixture {
    let dir = tempfile::TempDir::new().unwrap();
    let registry = Arc::new(DeviceRegistry::load(dir.path().join("devices.json")).unwrap());
    let hub = DeviceHub::new(
        Arc::clone(&registry),
        Duration::from_secs(300),
        "127.0.0.1".into(),
        1,
    );
    let p = registry
        .redeem("iPhone", DeviceKind::Iphone, None, None)
        .unwrap();
    let s = registry
        .redeem_with_egress(
            "kobe",
            DeviceKind::Satellite,
            Some(level),
            Some(Egress::Work),
            None,
        )
        .unwrap();
    HubFixture {
        _dir: dir,
        registry,
        hub,
        phone: Minted {
            device_id: p.device_id,
            token: p.token,
            name: p.name,
        },
        sat: Minted {
            device_id: s.device_id,
            token: s.token,
            name: s.name,
        },
    }
}

fn revoke_phone(f: &HubFixture) -> ClientMsg {
    ClientMsg::DeviceRevoke {
        request_id: "r1".into(),
        device: f.phone.device_id.clone(),
    }
}

fn dispatch_reply(
    f: &HubFixture,
    msg: &ClientMsg,
    snapshot: SatelliteAdmin,
    device: Option<&str>,
) -> ServerMsg {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let handled = f.hub.dispatch(
        msg,
        PeerTrust::Satellite { admin: snapshot },
        device,
        "conn",
        &tx,
    );
    assert_eq!(handled, Dispatched::Handled);
    rx.try_recv().expect("the hub answered")
}

#[tokio::test]
async fn a_revoke_buffered_behind_a_downgrade_to_read_only_is_judged_at_read_only() {
    let f = hub_fixture(SatelliteAdmin::Full);
    f.registry
        .set_admin("kobe", SatelliteAdmin::ReadOnly)
        .unwrap();
    // The connection still holds its admission-time snapshot, `full`.
    let r = dispatch_reply(
        &f,
        &revoke_phone(&f),
        SatelliteAdmin::Full,
        Some(&f.sat.device_id),
    );
    assert!(is_not_permitted(&r), "{r:?}");
    assert!(matches!(
        f.registry.validate(&f.phone.token),
        TokenCheck::Active { .. }
    ));
}

#[tokio::test]
async fn a_pairing_buffered_behind_a_downgrade_to_revoke_only_is_refused_and_a_revoke_still_runs() {
    let f = hub_fixture(SatelliteAdmin::Full);
    f.registry
        .set_admin("kobe", SatelliteAdmin::RevokeOnly)
        .unwrap();
    let start = ClientMsg::DevicePairStart {
        request_id: "p1".into(),
        name_hint: None,
        satellite: None,
        admin: None,
        egress: None,
        origin: Some("client-a".into()),
    };
    let r = dispatch_reply(&f, &start, SatelliteAdmin::Full, Some(&f.sat.device_id));
    assert!(is_not_permitted(&r), "{r:?}");
    let r = dispatch_reply(
        &f,
        &revoke_phone(&f),
        SatelliteAdmin::Full,
        Some(&f.sat.device_id),
    );
    assert!(matches!(r, ServerMsg::DeviceRevoked { .. }), "{r:?}");
}

#[tokio::test]
async fn a_verb_from_a_satellite_whose_record_was_revoked_gets_nothing_done() {
    let f = hub_fixture(SatelliteAdmin::Full);
    f.registry
        .revoke(&f.sat.device_id, RevokedBy::Operator)
        .unwrap();
    let r = dispatch_reply(
        &f,
        &revoke_phone(&f),
        SatelliteAdmin::Full,
        Some(&f.sat.device_id),
    );
    assert!(is_not_permitted(&r), "{r:?}");
    assert!(matches!(
        f.registry.validate(&f.phone.token),
        TokenCheck::Active { .. }
    ));
}

#[tokio::test]
async fn a_satellite_verb_with_no_device_behind_it_is_treated_as_off() {
    let f = hub_fixture(SatelliteAdmin::Full);
    let r = dispatch_reply(&f, &revoke_phone(&f), SatelliteAdmin::Full, None);
    assert!(is_not_permitted(&r), "{r:?}");
    assert!(matches!(
        f.registry.validate(&f.phone.token),
        TokenCheck::Active { .. }
    ));
}

#[tokio::test]
async fn an_uplink_revoked_while_connected_is_told_inside_an_envelope() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::Full).await;
    kobe.frames.clear();
    rig.registry
        .revoke(&kobe.minted.device_id, RevokedBy::Operator)
        .unwrap();
    assert_eq!(kobe.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    let bare: Vec<&Value> = kobe
        .frames
        .iter()
        .filter(|f| !matches!(kind_of(f), "server" | "request"))
        .collect();
    assert!(
        bare.is_empty(),
        "every frame on an uplink is a `server` or `request` envelope: {bare:?}"
    );
}

#[tokio::test]
async fn an_uplink_refused_for_its_role_is_told_inside_an_envelope() {
    let rig = Rig::new().await;
    let m = enrol(&rig, "kobe", Egress::Work, SatelliteAdmin::Full);
    let mut s = Sat::dial(&rig, &m, Egress::Work).await;
    s.hello(None).await;
    s.expect_close().await;
    let bare: Vec<&Value> = s
        .frames
        .iter()
        .filter(|f| !matches!(kind_of(f), "server" | "request"))
        .collect();
    assert!(bare.is_empty(), "{bare:?}");
}

// ═════════════════════════════════════════════════════════════════════════════
// Ingest (A, W10-21)
// ═════════════════════════════════════════════════════════════════════════════

#[tokio::test]
async fn a_satellite_publishes_under_its_own_name_and_under_no_other() {
    let mut s = scene(Egress::Personal).await;
    for spoof in [
        jobs_frame(Some("sendai"), &["spoofs-sendai"]),
        jobs_frame(None, &["spoofs-the-primary"]),
        jobs_frame(Some("KOBE"), &["spoofs-by-case"]),
    ] {
        assert!(s.kobe.publish(&spoof).await);
    }
    assert!(
        s.kobe
            .publish(&jobs_frame(Some("kobe"), &["kobes-own"]))
            .await
    );
    s.settle().await;

    let own = vec![(Some("kobe".to_string()), vec!["kobes-own".to_string()])];
    assert_eq!(jobs_in(&s.unix.inbox), own, "the Unix subscriber");
    assert_eq!(jobs_in(&s.phone.inbox), own, "the phone");

    // Only the honest frame was retained, under kobe.
    let replay = replay_until(&s.rig, |f| !jobs_in(f).is_empty()).await;
    assert_eq!(
        jobs_in(&replay),
        own,
        "a new subscriber is replayed kobe's frame alone"
    );
}

#[tokio::test]
async fn two_satellites_each_keep_their_own_retained_snapshot() {
    let mut s = scene(Egress::Personal).await;
    s.kobe
        .publish(&jobs_frame(Some("kobe"), &["kobes-own"]))
        .await;
    s.sendai
        .publish(&jobs_frame(Some("sendai"), &["sendais-own"]))
        .await;
    s.sendai.sync().await;
    s.settle().await;
    let replay = replay_until(&s.rig, |f| jobs_in(f).len() >= 2).await;
    let mut jobs = jobs_in(&replay);
    jobs.sort();
    assert_eq!(
        jobs,
        vec![
            (Some("kobe".to_string()), vec!["kobes-own".to_string()]),
            (Some("sendai".to_string()), vec!["sendais-own".to_string()]),
        ],
        "a reconnecting client receives both"
    );

    // A newer frame from kobe replaces kobe's, not sendai's.
    s.kobe
        .publish(&jobs_frame(Some("kobe"), &["kobes-newer"]))
        .await;
    s.settle().await;
    let replay = replay_until(&s.rig, |f| {
        jobs_in(f)
            .iter()
            .any(|(_, ids)| ids == &["kobes-newer".to_string()])
    })
    .await;
    let mut jobs = jobs_in(&replay);
    jobs.sort();
    assert_eq!(
        jobs,
        vec![
            (Some("kobe".to_string()), vec!["kobes-newer".to_string()]),
            (Some("sendai".to_string()), vec!["sendais-own".to_string()]),
        ]
    );
}

fn forged_device() -> Value {
    json!({"id": "forged-id", "name": "forged-device", "kind": "satellite",
           "paired_at": "2026-11-24T00:00:00Z"})
}

/// Every frame that must never come from a satellite, each carrying `forged`.
fn never_from_a_satellite() -> Vec<(&'static str, ServerMsg)> {
    let at = "2026-11-24T00:00:00Z";
    vec![
        (
            "devices",
            dec(
                json!({"type": "devices", "devices": [forged_device()], "hosts": [forged_device()]}),
            ),
        ),
        (
            "device_admin_level",
            dec(json!({"type": "device_admin_level", "level": "full", "pair_from": ["kobe"]})),
        ),
        (
            "hosts",
            dec(
                json!({"type": "hosts", "hosts": [{"name": "forged-host", "egress": "personal", "connected_since": at, "last_seen": at}]}),
            ),
        ),
        (
            "host_unavailable",
            dec(json!({"type": "host_unavailable", "host": "forged-host", "reason": "busy"})),
        ),
        (
            "device_pairing",
            dec(
                json!({"type": "device_pairing", "request_id": "forged", "pairing_id": "forged", "code": "000000", "server_url": "forged", "expires_at": at}),
            ),
        ),
        (
            "device_pair_outcome",
            dec(
                json!({"type": "device_pair_outcome", "pairing_id": "forged", "outcome": "paired", "name": "forged"}),
            ),
        ),
        (
            "device_revoked",
            dec(
                json!({"type": "device_revoked", "request_id": "forged", "device_id": "forged", "was_connected": false}),
            ),
        ),
        (
            "device_admin_error",
            dec(json!({"type": "device_admin_error", "request_id": "forged", "reason": "forged"})),
        ),
        (
            "pair_offer",
            dec(json!({"type": "pair_offer", "server_id": "forged", "challenge": "forged"})),
        ),
        (
            "paired",
            dec(
                json!({"type": "paired", "device_id": "forged", "token": "forged", "name": "forged", "server_id": "forged"}),
            ),
        ),
        (
            "pair_refused",
            dec(json!({"type": "pair_refused", "reason": "expired"})),
        ),
        (
            "unauthorized",
            dec(json!({"type": "unauthorized", "reason": "forged"})),
        ),
        ("device_unpaired", dec(json!({"type": "device_unpaired"}))),
        (
            "welcome",
            dec(
                json!({"type": "welcome", "protocol_version": 4, "daemon_pid": 1, "features": ["forged"]}),
            ),
        ),
        ("pong", dec(json!({"type": "pong"}))),
        ("error", dec(json!({"type": "error", "message": "forged"}))),
        (
            "session_queue",
            dec(
                json!({"type": "session_queue", "tag": "cody-1", "daemon_epoch": "forged", "rev": 1, "entries": []}),
            ),
        ),
        (
            "session_queue_returned",
            dec(
                json!({"type": "session_queue_returned", "tag": "cody-1", "reason": "forged", "entries": []}),
            ),
        ),
        (
            "mother_peek",
            dec(
                json!({"type": "mother_peek", "job_id": "forged", "todos": [], "tool_trail": [], "last_text": "forged"}),
            ),
        ),
        (
            "mother_await_detected",
            dec(
                json!({"type": "mother_await_detected", "id": "forged", "state": "awaiting", "title": "forged"}),
            ),
        ),
    ]
}

/// The hosts whose frames a new subscriber is replayed.
fn replayed_hosts(frames: &[ServerMsg]) -> Vec<String> {
    let mut hosts: Vec<String> = frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::MotherJobs { host, .. } | ServerMsg::SessionState { host, .. } => {
                host.clone()
            }
            _ => None,
        })
        .collect();
    hosts.sort();
    hosts.dedup();
    hosts
}

fn session_state_frame(host: &str, tag: &str) -> ServerMsg {
    dec(json!({"type": "session_state", "tag": tag, "state": "idle", "host": host}))
}

#[tokio::test]
async fn what_a_satellite_published_is_not_replayed_once_it_is_revoked_or_gone() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut tokyo = join(&rig, "tokyo", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    for (sat, host) in [
        (&mut kobe, "kobe"),
        (&mut tokyo, "tokyo"),
        (&mut sendai, "sendai"),
    ] {
        assert!(sat.publish(&jobs_frame(Some(host), &["a-job"])).await);
        assert!(sat.publish(&session_state_frame(host, "cody-1")).await);
    }
    // Control: a new subscriber is replayed all three.
    let replay = replay_until(&rig, |f| replayed_hosts(f).len() == 3).await;
    assert_eq!(replayed_hosts(&replay), ["kobe", "sendai", "tokyo"]);

    // kobe is revoked by the operator, tokyo drops off.
    rig.registry
        .revoke(&kobe.minted.device_id, RevokedBy::Operator)
        .unwrap();
    assert_eq!(kobe.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    tokyo.close().await;

    let replay = replay_until(&rig, |f| replayed_hosts(f) == ["sendai"]).await;
    assert_eq!(
        jobs_in(&replay),
        vec![(Some("sendai".to_string()), vec!["a-job".to_string()])],
        "the host still connected keeps its snapshot"
    );
}

#[tokio::test]
async fn what_a_satellite_published_before_its_hello_is_forgotten_when_it_disconnects() {
    let rig = Rig::new().await;
    let minted = enrol(&rig, "kobe", Egress::Personal, SatelliteAdmin::RevokeOnly);
    // A socket publishes and drops without ever sending a
    // `Hello`: the handler never registers it, so only the socket's own
    // clean-up can forget what it published.
    let mut early = Sat::dial(&rig, &minted, Egress::Personal).await;
    assert!(
        early
            .publish(&jobs_frame(Some("kobe"), &["early-job"]))
            .await
    );
    replay_until(&rig, |f| !jobs_in(f).is_empty()).await;
    early.close().await;
    replay_until(&rig, |f| replayed_hosts(f).is_empty()).await;
}

#[tokio::test]
async fn a_replaced_uplink_ending_does_not_forget_the_newer_uplinks_frames() {
    let rig = Rig::new().await;
    let mut first = join(&rig, "kobe", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    assert!(
        first
            .publish(&jobs_frame(Some("kobe"), &["from-the-first"]))
            .await
    );
    replay_until(&rig, |f| !jobs_in(f).is_empty()).await;

    // The same host connects again. Its frame goes in before its `Hello`, so
    // it is already kept when the primary swaps it in for the first uplink
    // and the first uplink's clean-up runs.
    let mut second = Sat::dial(&rig, &first.minted, Egress::Personal).await;
    assert!(
        second
            .publish(&jobs_frame(Some("kobe"), &["from-the-second"]))
            .await
    );
    replay_until(&rig, |f| {
        jobs_in(f)
            .iter()
            .any(|(_, ids)| ids == &["from-the-second".to_string()])
    })
    .await;
    second.hello(Some(role("kobe", Egress::Personal))).await;
    second
        .next_server("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    second.subscribe(&[]).await;
    second
        .next_server("DeviceAdminLevel", |m| {
            matches!(m, ServerMsg::DeviceAdminLevel { .. })
        })
        .await;
    assert_eq!(first.expect_close().await, Some(1000));
    // Give the first uplink's clean-up time to run, then look more than once.
    for _ in 0..4 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let replay = replay_until(&rig, |f| !jobs_in(f).is_empty()).await;
        assert_eq!(
            jobs_in(&replay),
            vec![(
                Some("kobe".to_string()),
                vec!["from-the-second".to_string()]
            )],
            "the first uplink's end took the second's snapshot with it"
        );
    }
    assert!(rig.hub.router().is_connected("kobe"));
}

#[tokio::test]
async fn administrative_and_bookkeeping_frames_published_by_a_satellite_reach_nobody() {
    for egress in [Egress::Work, Egress::Personal] {
        let mut s = scene(egress).await;
        for (_, frame) in never_from_a_satellite() {
            assert!(s.kobe.publish(&frame).await);
        }
        s.settle().await;
        s.sendai.listen(Duration::from_millis(250)).await;

        let seen: Vec<(&str, Vec<ServerMsg>)> = vec![
            ("the Unix subscriber", s.unix.inbox.clone()),
            ("the phone", s.phone.inbox.clone()),
            ("the other satellite", s.sendai.server_msgs()),
        ];
        for (who, msgs) in &seen {
            assert!(
                !mentions(msgs, "forged"),
                "{egress:?}: {who} was shown a forged frame: {msgs:?}"
            );
            assert!(
                !msgs.iter().any(|m| matches!(
                    m,
                    ServerMsg::Welcome { .. }
                        | ServerMsg::Pong
                        | ServerMsg::DeviceAdminLevel { .. }
                        | ServerMsg::MotherPeek { .. }
                        | ServerMsg::MotherAwaitDetected(_)
                        | ServerMsg::SessionQueue { .. }
                )),
                "{egress:?}: {who}: {msgs:?}"
            );
        }
        assert!(
            s.sendai.requests().is_empty(),
            "nothing was routed to the other satellite"
        );
        let counted = s.rig.hub.router().drops.publish.load(Ordering::Relaxed);
        assert!(
            counted >= never_from_a_satellite().len() as u64,
            "{egress:?}: every refused frame is counted, got {counted}"
        );
    }
}

#[tokio::test]
async fn host_less_open_frames_published_by_a_satellite_are_dropped() {
    for egress in [Egress::Work, Egress::Personal] {
        let mut s = scene(egress).await;
        for frame in [
            dec(json!({"type": "withheld", "topics": ["fred"], "reason": "forged"})),
            dec(json!({"type": "daemon_reconnected"})),
            dec(json!({"type": "model_catalog", "families": [], "stale": true})),
        ] {
            assert!(s.kobe.publish(&frame).await);
        }
        s.settle().await;
        for (who, msgs) in [
            ("the Unix subscriber", &s.unix.inbox),
            ("the phone", &s.phone.inbox),
        ] {
            assert!(!mentions(msgs, "forged"), "{egress:?}: {who}: {msgs:?}");
            assert!(
                !msgs.iter().any(|m| matches!(
                    m,
                    ServerMsg::DaemonReconnected | ServerMsg::ModelCatalog { stale: true, .. }
                )),
                "{egress:?}: {who}: {msgs:?}"
            );
        }
    }
}

#[tokio::test]
async fn a_bare_frame_or_a_wrong_direction_envelope_from_a_satellite_is_dropped() {
    let mut s = scene(Egress::Personal).await;
    let honest = jobs_frame(Some("kobe"), &["would-be-admitted"]);
    // No envelope at all; a `server` envelope; a `request` envelope.
    assert!(
        s.kobe
            .send_value(serde_json::to_value(&honest).unwrap())
            .await
    );
    assert!(
        s.kobe
            .send_value(json!({"uplink": "server", "msg": honest}))
            .await
    );
    assert!(
        s.kobe
            .send_value(json!({"uplink": "request", "id": "x", "msg": {"type": "session_list"}}))
            .await
    );
    assert!(s.kobe.send_text("not json at all".into()).await);
    s.settle().await;
    assert!(jobs_in(&s.unix.inbox).is_empty(), "{:?}", s.unix.inbox);
    assert!(jobs_in(&s.phone.inbox).is_empty(), "{:?}", s.phone.inbox);
    assert!(s.kobe.closed.is_none(), "a few junk frames do not close it");
}

#[tokio::test]
async fn a_satellite_that_keeps_sending_wrong_direction_envelopes_is_closed_1008() {
    let rig = Rig::with_limits(WsLimits {
        uplink: UplinkLimits {
            sustain: Duration::from_millis(150),
            ..Default::default()
        },
        ..Default::default()
    })
    .await;
    let mut kobe = join(&rig, "kobe", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let junk = json!({"uplink": "server", "msg": {"type": "pong"}});
    for i in 0..1500 {
        if kobe.closed.is_some() || !kobe.send_value(junk.clone()).await {
            break;
        }
        if i % 25 == 0 {
            kobe.pull(Duration::from_millis(5)).await;
        }
    }
    assert_eq!(kobe.expect_close().await, Some(1008));
}

#[tokio::test]
async fn a_work_satellites_honest_metadata_frames_are_published_and_kept() {
    let mut s = scene(Egress::Work).await;
    let tags = SensitiveTags::in_memory();
    let key = [7u8; 32];
    let honest = [
        redact_for_uplink_metadata(
            dec(json!({"type": "mother_jobs", "host": "kobe", "jobs": [{
                "id": "a1b2c3d4", "state": "running", "title": "SECRET-MARKER-title",
                "repo": "SECRET-MARKER-repo", "plan_path": "SECRET-MARKER-plan",
                "question": "SECRET-MARKER-question"}]})),
            &key,
            &tags,
        )
        .expect("jobs are publishable"),
        redact_for_uplink_metadata(
            dec(json!({"type": "decision_request", "tag": "cody-secret", "request_id": "req-1",
                "prompt": "SECRET-MARKER-prompt", "host": "kobe",
                "choices": [{"id": "a", "label": "SECRET-MARKER-label"}]})),
            &key,
            &tags,
        )
        .expect("a decision request is publishable"),
        redact_for_uplink_metadata(
            dec(json!({"type": "session_state", "tag": "cody-secret", "state": "idle", "host": "kobe"})),
            &key,
            &tags,
        )
        .expect("a session state is publishable"),
    ];
    for frame in &honest {
        assert!(!text_of(frame).contains("SECRET-MARKER"), "{frame:?}");
        assert!(s.kobe.publish(frame).await);
    }
    s.settle().await;
    for frame in &honest {
        let kind = type_of(frame);
        let got: Vec<String> = s
            .unix
            .inbox
            .iter()
            .filter(|m| type_of(m) == kind)
            .map(text_of)
            .collect();
        assert_eq!(
            got,
            vec![text_of(frame)],
            "{kind} reached the Unix subscriber unchanged"
        );
    }
}

#[tokio::test]
async fn a_work_satellites_frame_carrying_free_text_is_dropped_whatever_the_field() {
    let mut s = scene(Egress::Work).await;
    let marker = "SECRET-MARKER";
    let job = |field: &str| {
        let mut j = json!({"id": "a1b2c3d4", "state": "running"});
        j[field] = json!(format!("{marker}-{field}"));
        dec(json!({"type": "mother_jobs", "host": "kobe", "jobs": [j]}))
    };
    let decision = |prompt: &str, label: &str| {
        dec(
            json!({"type": "decision_request", "tag": "f-0a1b2c3d", "request_id": "req-1",
            "prompt": prompt, "host": "kobe",
            "choices": [{"id": "c0", "label": label}]}),
        )
    };
    let planted = vec![
        job("title"),
        job("plan_path"),
        job("repo"),
        job("question"),
        job("kind"),
        job("current_activity"),
        decision(&format!("{marker}-prompt"), ""),
        decision("", &format!("{marker}-label")),
        dec(
            json!({"type": "session_state", "tag": format!("{marker}-raw-tag"), "state": "idle", "host": "kobe"}),
        ),
        dec(
            json!({"type": "perri_state", "tag": "f-0a1b2c3d", "host": "kobe", "queue": [
            {"repo": format!("{marker}-pr-repo"), "number": 1, "title": format!("{marker}-pr-title"),
             "author": "a", "bucket": "requested", "new_activity": false, "url": "", "head_sha": "",
             "is_bot": false, "tickets": []}], "current": null}),
        ),
        // A work satellite's activity is never published.
        dec(
            json!({"type": "activity", "ts": "2026-11-24T00:00:00Z", "agent": "cody",
            "kind": "tool_use", "summary": format!("{marker}-activity"), "host": "kobe"}),
        ),
        dec(
            json!({"type": "activity", "ts": "2026-11-24T00:00:00Z", "agent": "cody",
            "kind": "tool_use", "summary": "", "focus_tag": "f-0a1b2c3d", "host": "kobe"}),
        ),
    ];
    for frame in &planted {
        assert!(s.kobe.publish(frame).await);
    }
    s.settle().await;
    for (who, msgs) in [
        ("the Unix subscriber", &s.unix.inbox),
        ("the phone", &s.phone.inbox),
    ] {
        assert!(!mentions(msgs, marker), "{who}: {msgs:?}");
        assert!(
            !msgs.iter().any(|m| matches!(
                m,
                ServerMsg::MotherJobs { .. }
                    | ServerMsg::DecisionRequest { .. }
                    | ServerMsg::SessionState { .. }
                    | ServerMsg::PerriState { .. }
                    | ServerMsg::Activity(_)
            )),
            "{who} was shown a frame a work satellite may not publish: {msgs:?}"
        );
    }
}

#[tokio::test]
async fn a_personal_satellites_frames_pass_unchanged() {
    let mut s = scene(Egress::Personal).await;
    let frames = vec![
        dec(json!({"type": "mother_jobs", "host": "kobe", "jobs": [{
            "id": "job-1", "state": "running", "title": "Ship the thing", "repo": "acme/widgets"}]})),
        dec(json!({"type": "session_state", "tag": "cody-1", "state": "idle", "host": "kobe"})),
        dec(
            json!({"type": "activity", "ts": "2026-11-24T00:00:00Z", "agent": "cody",
            "kind": "tool_use", "summary": "ran the tests", "focus_tag": "cody-1", "host": "kobe"}),
        ),
    ];
    for frame in &frames {
        assert!(s.kobe.publish(frame).await);
    }
    s.settle().await;
    for frame in &frames {
        let kind = type_of(frame);
        let got: Vec<String> = s
            .unix
            .inbox
            .iter()
            .filter(|m| type_of(m) == kind)
            .map(text_of)
            .collect();
        assert_eq!(got, vec![text_of(frame)], "{kind}");
    }
}

#[tokio::test]
async fn a_personal_satellites_network_redacted_focus_list_naming_a_fred_focus_is_published() {
    let mut s = scene(Egress::Personal).await;
    // What an honest satellite sends: its own list, already trimmed for the network.
    let sent = redact_for_network(
        dec(
            json!({"type": "focus_list_resp", "host": "kobe", "focuses": [
                focus_meta("notes-1", "fred"),
                focus_meta("cody-open", "cody"),
            ]}),
        ),
        &SensitiveTags::in_memory(),
    );
    assert!(s.kobe.publish(&sent).await);
    s.settle().await;
    let got: Vec<String> = s
        .unix
        .inbox
        .iter()
        .filter(|m| matches!(m, ServerMsg::FocusListResp { .. }))
        .map(text_of)
        .collect();
    assert_eq!(got, vec![text_of(&sent)], "an honest frame is not dropped");
}

#[tokio::test]
async fn a_flood_of_publish_frames_is_cut_to_the_burst_and_the_primary_stays_responsive() {
    let mut s = scene(Egress::Personal).await;
    let start = Instant::now();
    for i in 0..1000 {
        let id = format!("job-{i}");
        if !s
            .kobe
            .publish(&jobs_frame(Some("kobe"), &[id.as_str()]))
            .await
        {
            break;
        }
    }
    s.settle().await;
    let elapsed = start.elapsed().as_secs_f64();
    // 200 burst, refilling at 50 a second while the flood lasted.
    let ceiling = 200 + (50.0 * elapsed).ceil() as usize + 10;
    for (who, msgs) in [
        ("the Unix subscriber", &s.unix.inbox),
        ("the phone", &s.phone.inbox),
    ] {
        let got = jobs_in(msgs).len();
        assert!(got >= 1, "{who} got none of them");
        assert!(
            got <= ceiling,
            "{who} received {got} of 1000 (ceiling {ceiling})"
        );
    }
    s.unix.sync().await;
    s.phone.sync().await;
    assert!(
        s.kobe.closed.is_none(),
        "a flood shorter than the sustain window is not closed"
    );
}

#[tokio::test]
async fn a_publish_frame_over_256_kib_is_dropped_and_the_connection_stays_open() {
    let mut s = scene(Egress::Personal).await;
    let big = |kib: usize, id: &str| {
        dec(json!({"type": "mother_jobs", "host": "kobe", "jobs": [{
            "id": id, "state": "running", "title": "x".repeat(kib * 1024)}]}))
    };
    assert!(s.kobe.publish(&big(200, "under-the-cap")).await);
    assert!(s.kobe.publish(&big(300, "over-the-cap")).await);
    assert!(s.kobe.publish(&jobs_frame(Some("kobe"), &["after"])).await);
    s.settle().await;
    let ids: Vec<String> = jobs_in(&s.unix.inbox)
        .into_iter()
        .flat_map(|(_, ids)| ids)
        .collect();
    assert_eq!(ids, vec!["under-the-cap".to_string(), "after".to_string()]);
    assert!(s.kobe.closed.is_none());
}

#[tokio::test]
async fn a_thousand_junk_envelopes_in_a_second_end_in_a_1008_close() {
    let rig = Rig::with_limits(WsLimits {
        uplink: UplinkLimits {
            sustain: Duration::from_millis(150),
            ..Default::default()
        },
        ..Default::default()
    })
    .await;
    let mut kobe = join(&rig, "kobe", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    for i in 0..1000 {
        if kobe.closed.is_some() || !kobe.send_text(format!("{{\"junk\": {i}}}")).await {
            break;
        }
        if i % 25 == 0 {
            kobe.pull(Duration::from_millis(1)).await;
            tokio::time::sleep(Duration::from_millis(24)).await;
        }
    }
    assert_eq!(kobe.expect_close().await, Some(1008));
}

#[tokio::test]
async fn replies_have_a_rate_limit_of_their_own_apart_from_publish_frames() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionList {
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the routed read").await;
    // Empty the publish bucket, then answer.
    for i in 0..1000 {
        if !sendai.send_text(format!("{{\"junk\": {i}}}")).await {
            break;
        }
    }
    assert!(sendai.reply(&id, &session_list_resp(Some("sendai"))).await);
    a.next_matching("the reply", |m| {
        matches!(m, ServerMsg::SessionListResp { .. })
    })
    .await;
}

/// A rig whose satellites may send `burst` `client` frames at once and then
/// `rate` a second, over-limit for `sustain` before the uplink is closed.
async fn rig_with_client_bucket(rate: f64, burst: f64, sustain: Duration) -> Rig {
    Rig::with_limits(WsLimits {
        uplink: UplinkLimits {
            client_rate: rate,
            client_burst: burst,
            sustain,
            ..Default::default()
        },
        ..Default::default()
    })
    .await
}

#[tokio::test]
async fn client_frames_over_the_burst_are_answered_rate_limited_and_not_run() {
    // Almost no refill, so the burst is all there is. The `Hello` and
    // `Subscribe` of the admission used two of it.
    let rig = rig_with_client_bucket(0.01, 10.0, Duration::from_secs(30)).await;
    let phones: Vec<Minted> = (0..25)
        .map(|i| rig.mint_device(&format!("phone-{i}")))
        .collect();
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;

    for p in &phones {
        kobe.client(&ClientMsg::DeviceRevoke {
            request_id: request_id(),
            device: p.device_id.clone(),
        })
        .await;
    }
    kobe.listen(Duration::from_millis(1000)).await;

    let msgs = kobe.server_msgs();
    let limited = msgs.iter().filter(|m| rate_limited(m)).count();
    let revoked_answers = msgs
        .iter()
        .filter(|m| matches!(m, ServerMsg::DeviceRevoked { .. }))
        .count();
    let revoked_in_registry = phones
        .iter()
        .filter(|p| rig.registry.validate(&p.token) == TokenCheck::Revoked)
        .count();
    assert!(
        (1..=10).contains(&revoked_in_registry),
        "{revoked_in_registry} of 25 were run; the burst is 10"
    );
    assert_eq!(revoked_answers, revoked_in_registry);
    assert_eq!(
        limited,
        25 - revoked_in_registry,
        "every frame that was not run was answered `rate_limited`"
    );
    assert!(
        kobe.frames
            .iter()
            .all(|f| matches!(kind_of(f), "server" | "request")),
        "the refusal is inside an envelope: {:?}",
        kobe.frames
    );
    assert!(
        kobe.closed.is_none(),
        "a short overrun is not closed: {:?}",
        kobe.closed
    );
}

#[tokio::test]
async fn a_satellite_that_stays_over_the_client_limit_for_the_sustain_window_is_closed_1008() {
    let rig = rig_with_client_bucket(5.0, 5.0, Duration::from_millis(300)).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    for _ in 0..400 {
        if kobe.closed.is_some()
            || !kobe
                .send_value(json!({"uplink": "client", "msg": {"type": "ping"}}))
                .await
        {
            break;
        }
        kobe.pull(Duration::from_millis(1)).await;
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(kobe.expect_close().await, Some(1008));
}

#[tokio::test]
async fn a_satellite_asking_at_an_honest_rate_is_never_limited() {
    let rig = rig_with_client_bucket(20.0, 5.0, Duration::from_millis(300)).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    // Ten a second for two seconds, each answered before the next.
    for _ in 0..20 {
        let r = kobe
            .call(|rid| ClientMsg::DeviceRevoke {
                device: format!("no-such-device-{rid}"),
                request_id: rid,
            })
            .await;
        assert!(is_unknown_device(&r), "{r:?}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    kobe.listen(Duration::from_millis(100)).await;
    assert!(
        !kobe.server_msgs().iter().any(rate_limited),
        "{:?}",
        kobe.frames
    );
    assert!(kobe.closed.is_none());
}

// ═════════════════════════════════════════════════════════════════════════════
// Routed reads and replies (A5, W10-5/6/7)
// ═════════════════════════════════════════════════════════════════════════════

/// Each single-answer read: the request that goes down, and the answer that
/// comes back.
fn single_answer_reads() -> Vec<(&'static str, ClientMsg, Value, ServerMsg)> {
    let host = || Some("sendai".to_string());
    vec![
        (
            "session_list",
            ClientMsg::SessionList { host: host() },
            json!({"type": "session_list"}),
            session_list_resp(Some("sendai")),
        ),
        (
            "focus_list",
            ClientMsg::FocusList { host: host() },
            json!({"type": "focus_list"}),
            dec(json!({"type": "focus_list_resp", "focuses": [], "host": "sendai"})),
        ),
        (
            "session_model_get",
            ClientMsg::SessionModelGet {
                tag: "cody-1".into(),
                host: host(),
            },
            json!({"type": "session_model_get", "tag": "cody-1"}),
            dec(json!({"type": "session_model_state", "tag": "cody-1", "running": false})),
        ),
        (
            "activity_snapshot_request",
            ClientMsg::ActivitySnapshotRequest {
                tag: "cody-1".into(),
                host: host(),
            },
            json!({"type": "activity_snapshot_request", "tag": "cody-1"}),
            dec(json!({"type": "activity_snapshot", "tag": "cody-1", "streams": []})),
        ),
    ]
}

#[tokio::test]
async fn each_single_answer_read_goes_to_the_satellite_and_its_answer_comes_back_to_the_asker_alone(
) {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    let mut b = rig.unix(vec![], false).await;

    for (name, ask, expect_request, answer) in single_answer_reads() {
        a.send(&ask).await;
        let (id, msg) = sendai.next_request(name).await;
        assert_eq!(msg, expect_request, "{name}: the request carries no host");
        assert!(sendai.reply(&id, &answer).await);
        let got = a
            .next_matching(name, |m| type_of(m) == type_of(&answer))
            .await;
        assert_eq!(text_of(&got), text_of(&answer), "{name}");
    }
    a.sync().await;
    b.sync().await;
    assert!(
        b.inbox.iter().all(|m| !matches!(
            m,
            ServerMsg::SessionListResp { .. }
                | ServerMsg::FocusListResp { .. }
                | ServerMsg::SessionModelState(_)
                | ServerMsg::ActivitySnapshot { .. }
        )),
        "another client was sent an answer meant for the asker: {:?}",
        b.inbox
    );
}

#[tokio::test]
async fn a_request_id_serves_one_answer_and_is_then_spent() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionList {
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the read").await;
    assert!(sendai.reply(&id, &session_list_resp(Some("sendai"))).await);
    assert!(sendai.reply(&id, &session_list_resp(Some("sendai"))).await);
    sendai.sync().await;
    a.sync().await;
    let answers = a
        .inbox
        .iter()
        .filter(|m| matches!(m, ServerMsg::SessionListResp { .. }))
        .count();
    assert_eq!(answers, 1);
}

#[tokio::test]
async fn a_read_naming_a_work_satellite_is_refused_as_metadata_only_and_nothing_is_sent_to_it() {
    let rig = Rig::new().await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionList {
        host: Some("kobe".into()),
    })
    .await;
    let told = a
        .next_matching("HostUnavailable", |m| {
            matches!(m, ServerMsg::HostUnavailable { .. })
        })
        .await;
    assert!(
        matches!(&told, ServerMsg::HostUnavailable { host, reason: HostUnavailableReason::EgressMetadata } if host == "kobe"),
        "{told:?}"
    );
    kobe.listen(Duration::from_millis(250)).await;
    assert!(kobe.requests().is_empty(), "{:?}", kobe.frames);
}

#[tokio::test]
async fn a_read_naming_an_unknown_or_disconnected_host_is_refused_as_not_connected() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    for host in ["nowhere", "SENDAI"] {
        a.send(&ClientMsg::SessionList {
            host: Some(host.into()),
        })
        .await;
        let told = a
            .next_matching("HostUnavailable", |m| {
                matches!(m, ServerMsg::HostUnavailable { .. })
            })
            .await;
        assert!(
            matches!(&told, ServerMsg::HostUnavailable { host: h, reason: HostUnavailableReason::NotConnected } if h == host),
            "{told:?}"
        );
    }
    sendai.close().await;
    Rig::wait_until("sendai to be gone", || {
        !rig.hub.router().is_connected("sendai")
    })
    .await;
    a.send(&ClientMsg::SessionList {
        host: Some("sendai".into()),
    })
    .await;
    let told = a
        .next_matching("HostUnavailable", |m| {
            matches!(m, ServerMsg::HostUnavailable { .. })
        })
        .await;
    assert!(
        matches!(
            &told,
            ServerMsg::HostUnavailable {
                reason: HostUnavailableReason::NotConnected,
                ..
            }
        ),
        "{told:?}"
    );
}

#[tokio::test]
async fn a_paired_phone_can_read_from_a_personal_satellite_and_gets_the_answer() {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut phone = rig.device(&phone_m.token, &[], vec![]).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    phone
        .send(&ClientMsg::SessionList {
            host: Some("sendai".into()),
        })
        .await;
    let (id, msg) = sendai.next_request("the phone's read").await;
    assert_eq!(msg, json!({"type": "session_list"}));
    assert!(sendai.reply(&id, &session_list_resp(Some("sendai"))).await);
    let got = phone
        .next_matching("the answer", |m| {
            matches!(m, ServerMsg::SessionListResp { .. })
        })
        .await;
    assert!(matches!(got, ServerMsg::SessionListResp { host: Some(h), .. } if h == "sendai"));
}

#[tokio::test]
async fn a_tcp_peer_can_read_from_a_personal_satellite_and_gets_the_answer() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    tcp.send(&ClientMsg::FocusList {
        host: Some("sendai".into()),
    })
    .await;
    let (id, msg) = sendai.next_request("the TCP peer's read").await;
    assert_eq!(msg, json!({"type": "focus_list"}));
    assert!(
        sendai
            .reply(
                &id,
                &dec(json!({"type": "focus_list_resp", "focuses": [], "host": "sendai"}))
            )
            .await
    );
    tcp.next_matching("the answer", |m| {
        matches!(m, ServerMsg::FocusListResp { .. })
    })
    .await;
}

#[tokio::test]
async fn a_network_peer_naming_a_sensitive_session_on_a_satellite_is_refused_before_it_is_routed() {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut phone = rig.device(&phone_m.token, &[], vec![]).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    for (who, conn) in [("the phone", &mut phone), ("the TCP peer", &mut tcp)] {
        conn.send(&ClientMsg::SessionAttach {
            tag: "fred".into(),
            host: Some("sendai".into()),
        })
        .await;
        conn.next_matching("the refusal", is_network_refusal).await;
        conn.sync().await;
        assert!(
            !conn
                .inbox
                .iter()
                .any(|m| matches!(m, ServerMsg::HostUnavailable { .. })),
            "{who}: {:?}",
            conn.inbox
        );
    }
    sendai.listen(Duration::from_millis(250)).await;
    assert!(sendai.requests().is_empty(), "{:?}", sendai.frames);
}

#[tokio::test]
async fn a_routed_attach_delivers_the_snapshot_and_live_deltas_to_the_requester_only() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    let mut b = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, msg) = sendai.next_request("the attach").await;
    assert_eq!(msg, json!({"type": "session_attach", "tag": "cody-1"}));

    assert!(sendai.reply(&id, &turns("cody-1")).await);
    a.next_matching("the snapshot", |m| {
        matches!(m, ServerMsg::SessionTurns { .. })
    })
    .await;
    assert!(sendai.reply(&id, &delta("cody-1")).await);
    assert!(sendai.reply(&id, &delta("cody-1")).await);
    a.next_matching("a live delta", |m| {
        matches!(m, ServerMsg::SessionTurnDelta { .. })
    })
    .await;
    a.next_matching("a second delta", |m| {
        matches!(m, ServerMsg::SessionTurnDelta { .. })
    })
    .await;
    assert!(
        a.raw
            .iter()
            .filter(|r| r.contains("session_turn"))
            .all(|r| !r.contains("\"host\"")),
        "the transcript frames carry no host: {:?}",
        a.raw
    );
    b.sync().await;
    assert!(
        !b.inbox.iter().any(|m| matches!(
            m,
            ServerMsg::SessionTurns { .. } | ServerMsg::SessionTurnDelta { .. }
        )),
        "another client was sent the transcript: {:?}",
        b.inbox
    );
}

#[tokio::test]
async fn a_refusal_for_a_routed_attach_reaches_the_requester_alone_and_ends_the_attach() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    let mut b = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the attach").await;
    assert!(
        sendai
            .reply(
                &id,
                &ServerMsg::Error {
                    message: "requires_secure_connection: no".into()
                }
            )
            .await
    );
    a.next_matching("the refusal", |m| matches!(m, ServerMsg::Error { .. }))
        .await;
    // The attach is over: a later delta on that id goes nowhere.
    assert!(sendai.reply(&id, &delta("cody-1")).await);
    sendai.sync().await;
    a.sync().await;
    b.sync().await;
    assert!(
        !a.inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::SessionTurnDelta { .. })),
        "{:?}",
        a.inbox
    );
    assert!(
        !b.inbox.iter().any(|m| matches!(m, ServerMsg::Error { .. })),
        "the refusal reached another client: {:?}",
        b.inbox
    );
}

#[tokio::test]
async fn a_requester_that_disconnects_has_its_attach_detached_on_the_satellite_with_the_same_id() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the attach").await;
    drop(a);
    let (detach_id, msg) = sendai.next_request("the detach").await;
    assert_eq!(detach_id, id, "the same id");
    assert_eq!(msg, json!({"type": "session_detach", "tag": "cody-1"}));
}

#[tokio::test]
async fn an_explicit_detach_naming_the_host_detaches_the_attach_with_the_same_id() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the attach").await;
    a.send(&ClientMsg::SessionDetach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (detach_id, msg) = sendai.next_request("the detach").await;
    assert_eq!(detach_id, id);
    assert_eq!(msg, json!({"type": "session_detach", "tag": "cody-1"}));
    // The id is spent: a late delta reaches nobody.
    assert!(sendai.reply(&id, &delta("cody-1")).await);
    sendai.sync().await;
    a.sync().await;
    assert!(
        !a.inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::SessionTurnDelta { .. })),
        "{:?}",
        a.inbox
    );
}

// ── replies that are not accepted ─────────────────────────────────────────────

#[tokio::test]
async fn replies_that_do_not_match_what_was_asked_reach_nobody_and_the_honest_one_still_does() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut tokyo = join(&rig, "tokyo", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut kobe = join(&rig, "kobe", Egress::Work, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    let mut b = rig.unix(vec![], false).await;
    // What a connection is replayed on arrival is not what is under test.
    a.take_all();
    b.take_all();

    a.send(&ClientMsg::SessionList {
        host: Some("sendai".into()),
    })
    .await;
    let (list_id, _) = sendai.next_request("the list").await;
    a.send(&ClientMsg::SessionModelGet {
        tag: "cody-a".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (model_id, _) = sendai.next_request("the model read").await;

    // An id nobody issued.
    assert!(
        sendai
            .reply("no-such-id", &session_list_resp(Some("sendai")))
            .await
    );
    // Another personal satellite, and a work one, answering sendai's id.
    assert!(
        tokyo
            .reply(&list_id, &session_list_resp(Some("tokyo")))
            .await
    );
    assert!(
        tokyo
            .reply(&list_id, &session_list_resp(Some("sendai")))
            .await
    );
    assert!(kobe.reply(&list_id, &session_list_resp(Some("kobe"))).await);
    // A variant outside what a session list may be answered with.
    for stray in [
        dec(json!({"type": "pong"})),
        dec(json!({"type": "devices", "devices": [], "hosts": []})),
        dec(json!({"type": "hosts", "hosts": []})),
        dec(json!({"type": "mother_jobs", "jobs": [], "host": "sendai"})),
    ] {
        assert!(sendai.reply(&list_id, &stray).await);
    }
    // A host field that is not the record's name, or none.
    assert!(
        sendai
            .reply(&list_id, &session_list_resp(Some("kobe")))
            .await
    );
    assert!(sendai.reply(&list_id, &session_list_resp(None)).await);
    // An answer about another focus than the one asked about.
    assert!(
        sendai
            .reply(
                &model_id,
                &dec(json!({"type": "session_model_state", "tag": "cody-other", "running": false}))
            )
            .await
    );

    for s in [&mut sendai, &mut tokyo, &mut kobe] {
        s.sync().await;
    }
    a.sync().await;
    b.sync().await;
    assert!(
        a.inbox.is_empty(),
        "nothing reached the asker: {:?}",
        a.inbox
    );
    assert!(
        b.inbox.is_empty(),
        "nothing reached anyone else: {:?}",
        b.inbox
    );

    // The ids are still live: the honest answers are delivered.
    assert!(
        sendai
            .reply(&list_id, &session_list_resp(Some("sendai")))
            .await
    );
    assert!(
        sendai
            .reply(
                &model_id,
                &dec(json!({"type": "session_model_state", "tag": "cody-a", "running": false}))
            )
            .await
    );
    a.next_matching(
        "the list",
        |m| matches!(m, ServerMsg::SessionListResp { host: Some(h), .. } if h == "sendai"),
    )
    .await;
    a.next_matching(
        "the model state",
        |m| matches!(m, ServerMsg::SessionModelState(s) if s.tag == "cody-a"),
    )
    .await;
}

#[tokio::test]
async fn an_attach_id_cannot_carry_anything_but_the_attach_family_back_to_its_requester() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.take_all();
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the attach").await;

    // Each is for sendai and about this focus where it names one, so the
    // only thing wrong with it is that an attach does not produce it.
    for stray in [
        json!({"type": "mother_jobs", "jobs": [], "host": "sendai"}),
        json!({"type": "session_list_resp", "sessions": [], "host": "sendai"}),
        json!({"type": "focus_list_resp", "focuses": [], "host": "sendai"}),
        json!({"type": "session_model_state", "tag": "cody-1", "running": false}),
        json!({"type": "perri_state", "tag": "cody-1", "host": "sendai", "queue": [], "current": null}),
        json!({"type": "approval_pending", "tag": "cody-1", "count": 1, "host": "sendai"}),
    ] {
        assert!(sendai.reply(&id, &dec(stray)).await);
    }
    sendai.sync().await;
    a.sync().await;
    assert!(
        a.inbox.is_empty(),
        "something other than an attach's answer reached the requester: {:?}",
        a.inbox
    );

    // The attach is still live for what it does produce.
    assert!(sendai.reply(&id, &turns("cody-1")).await);
    a.next_matching("the snapshot", |m| {
        matches!(m, ServerMsg::SessionTurns { .. })
    })
    .await;
}

// ── caps ──────────────────────────────────────────────────────────────────────

fn list_sendai() -> ClientMsg {
    ClientMsg::SessionList {
        host: Some("sendai".into()),
    }
}

fn busy(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::HostUnavailable { host, reason: HostUnavailableReason::Busy } if host == "sendai")
}

#[tokio::test]
async fn a_ninth_outstanding_read_from_one_requester_is_busy_and_never_sent() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    for _ in 0..9 {
        a.send(&list_sendai()).await;
    }
    a.sync().await;
    let busies = a.inbox.iter().filter(|m| busy(m)).count();
    assert_eq!(busies, 1, "exactly the ninth: {:?}", a.inbox);
    sendai.listen(Duration::from_millis(300)).await;
    assert_eq!(sendai.requests().len(), 8, "sendai saw eight requests");
}

#[tokio::test]
async fn a_requester_at_its_cap_does_not_stop_another_requester() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    let mut b = rig.unix(vec![], false).await;
    for _ in 0..8 {
        a.send(&list_sendai()).await;
    }
    a.sync().await;
    b.send(&list_sendai()).await;
    b.sync().await;
    assert!(!b.inbox.iter().any(busy), "{:?}", b.inbox);
    sendai.listen(Duration::from_millis(300)).await;
    assert_eq!(sendai.requests().len(), 9, "b's request went down");
}

#[tokio::test]
async fn the_thirty_third_outstanding_read_for_a_host_is_busy_and_sendai_sees_exactly_thirty_two() {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut requesters = Vec::new();
    for _ in 0..4 {
        let mut c = rig.unix(vec![], false).await;
        for _ in 0..8 {
            c.send(&list_sendai()).await;
        }
        c.sync().await;
        assert!(!c.inbox.iter().any(busy), "{:?}", c.inbox);
        requesters.push(c);
    }
    let mut fifth = rig.unix(vec![], false).await;
    fifth.send(&list_sendai()).await;
    fifth.sync().await;
    assert_eq!(
        fifth.inbox.iter().filter(|m| busy(m)).count(),
        1,
        "{:?}",
        fifth.inbox
    );
    sendai.listen(Duration::from_millis(400)).await;
    assert_eq!(sendai.requests().len(), 32);
}

#[tokio::test]
async fn a_satellite_flooding_deltas_on_one_attach_id_reaches_the_requester_only_up_to_the_reply_burst(
) {
    let rig = Rig::new().await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;
    let mut a = rig.unix(vec![], false).await;
    a.send(&ClientMsg::SessionAttach {
        tag: "cody-1".into(),
        host: Some("sendai".into()),
    })
    .await;
    let (id, _) = sendai.next_request("the attach").await;
    let start = Instant::now();
    let frame = delta("cody-1");
    for _ in 0..2000 {
        if !sendai.reply(&id, &frame).await {
            break;
        }
    }
    sendai.sync().await;
    a.sync().await;
    let elapsed = start.elapsed().as_secs_f64();
    let got = a
        .inbox
        .iter()
        .filter(|m| matches!(m, ServerMsg::SessionTurnDelta { .. }))
        .count();
    // 400 burst, refilling at 200 a second while the flood lasted.
    let ceiling = 400 + (200.0 * elapsed).ceil() as usize + 10;
    assert!(got >= 1, "some deltas are delivered");
    assert!(
        got <= ceiling,
        "{got} of 2000 deltas delivered (ceiling {ceiling})"
    );
}

// ── nothing but the six reads is ever sent down (B10, W10-6) ──────────────────

#[tokio::test]
async fn no_other_verb_is_ever_sent_down_to_a_satellite_as_a_request() {
    let rig = Rig::new().await;
    let phone_m = rig.mint_device("iPhone");
    let mut phone = rig.device(&phone_m.token, &[], vec![]).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    let mut sendai = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::RevokeOnly).await;

    // Sent over the network, where each of these is refused without effect: a
    // local peer's would run (and spawn sessions), which a hermetic test must
    // not do. None carries a `host`, so none is the router's.
    let verbs: Vec<ClientMsg> = vec![
        serde_json::from_value(json!({"type": "decision_answer", "request_id": "d1", "choice_id": null})).unwrap(),
        serde_json::from_value(json!({"type": "approval_answer", "request_id": "a1", "decision": {"kind": "allow_once"}, "window_id": "w"})).unwrap(),
        serde_json::from_value(json!({"type": "mother_resume", "job_id": "j1", "answer": "yes"})).unwrap(),
        serde_json::from_value(json!({"type": "mother_action", "job_id": "j1", "action": "cancel"})).unwrap(),
        serde_json::from_value(json!({"type": "perri_action", "action": "clear"})).unwrap(),
        serde_json::from_value(json!({"type": "session_send", "tag": "cody-1", "text": "hi"})).unwrap(),
        serde_json::from_value(json!({"type": "session_spawn", "tag": "cody-1", "agent_name": "cody",
            "view_name": "v", "cwd": null, "session_id": null, "remote_control": false})).unwrap(),
    ];
    for v in &verbs {
        phone.send(v).await;
        tcp.send(v).await;
    }
    phone.sync().await;
    tcp.sync().await;
    sendai.listen(Duration::from_millis(300)).await;
    assert!(sendai.requests().is_empty(), "{:?}", sendai.requests());
}

// ═════════════════════════════════════════════════════════════════════════════
// Unit level
// ═════════════════════════════════════════════════════════════════════════════

fn session_info(tag: &str, agent: &str) -> Value {
    json!({"tag": tag, "agent_name": agent, "view_name": "a view", "session_id": "s-1",
        "alive": true, "remote_control": false, "state": "idle", "mcp_bridge_connected": true,
        "agent_turns": 4, "agent_messages": 5, "agent_problems": 1, "activity_epoch": "e-1"})
}

fn focus_meta(tag: &str, agent: &str) -> Value {
    json!({"tag": tag, "display_name": "A Name", "agent_name": agent, "project_name": "acme",
        "org": "acme", "is_built_in": false, "session_summary": "the first message",
        "label": "ACME-1", "project_path": "/Users/x/acme", "select_for_client": null,
        "initial_model": null, "initial_effort": null, "no_codebase": null})
}

#[test]
fn redacting_for_the_network_twice_is_the_same_as_redacting_once() {
    let tags = SensitiveTags::in_memory();
    tags.mark_tag("cody-secret");
    let annotated_job = json!({"id": "job-1", "state": "running", "title": "t",
        "failure_reason": "a free-form reason",
        "nostromo": {"origin": {"kind": "focus", "focus_tag": "cody-secret",
            "name_snapshot": "A snapshot", "focus_name": "A name", "session_prefix": "abcd1234"},
            "notify": "wake"}});
    let frames = vec![
        (
            "session list",
            dec(
                json!({"type": "session_list_resp", "host": "sendai", "sessions": [
                    session_info("cody-secret", "cody"),
                    session_info("cody-open", "cody"),
                    session_info("fred", "fred"),
                ]}),
            ),
        ),
        (
            "focus list, sensitive by tag",
            dec(
                json!({"type": "focus_list_resp", "host": "sendai", "focuses": [
                    focus_meta("cody-secret", "cody"),
                    focus_meta("cody-open", "cody"),
                ]}),
            ),
        ),
        (
            "focus list, sensitive by agent",
            dec(
                json!({"type": "focus_list_resp", "host": "sendai", "focuses": [
                    focus_meta("notes-1", "fred"),
                    focus_meta("fred", "fred"),
                ]}),
            ),
        ),
        (
            "focus registry",
            dec(
                json!({"type": "focus_registry_updated", "host": "sendai", "focuses": [
                focus_meta("cody-secret", "cody"), focus_meta("cody-open", "cody")]}),
            ),
        ),
        (
            "focus created",
            dec(
                json!({"type": "focus_created", "host": "sendai", "meta": focus_meta("cody-secret", "cody")}),
            ),
        ),
        (
            "mother jobs",
            dec(json!({"type": "mother_jobs", "host": "sendai", "jobs": [annotated_job]})),
        ),
        ("session turns", turns("cody-open")),
        (
            "approval count",
            dec(
                json!({"type": "approval_pending", "tag": "cody-open", "count": 2, "host": "sendai"}),
            ),
        ),
        (
            "perri state",
            dec(
                json!({"type": "perri_state", "tag": "cody-open", "host": "sendai", "queue": [], "current": null}),
            ),
        ),
    ];
    for (what, frame) in frames {
        let once = redact_for_network(frame, &tags);
        let twice = redact_for_network(once.clone(), &tags);
        assert_eq!(
            text_of(&twice),
            text_of(&once),
            "{what}: a second pass changed the frame"
        );
    }
}

#[tokio::test]
async fn the_broadcast_channel_never_carries_a_satellites_level_or_a_refusal() {
    let rig = Rig::new().await;
    let mut raw = rig.server.tx.subscribe();
    let phone_m = rig.mint_device("iPhone");

    // Admission, a refused verb at `off`, a level change, a readmission.
    let mut kobe = join(&rig, "kobe", Egress::Personal, SatelliteAdmin::Full).await;
    let mut off = join(&rig, "sendai", Egress::Personal, SatelliteAdmin::Off).await;
    let refused = off
        .call(|rid| ClientMsg::DeviceRevoke {
            request_id: rid,
            device: "iPhone".into(),
        })
        .await;
    assert!(is_not_permitted(&refused));
    rig.hub.set_admin("kobe", SatelliteAdmin::ReadOnly).unwrap();
    kobe.expect_close().await;
    let mut kobe = kobe.reconnect(&rig).await;
    // A local client that follows the device list, and a phone's refused verb.
    let _local = rig.unix(vec![Topic::Devices], false).await;
    let mut phone = rig.device(&phone_m.token, &[], vec![]).await;
    phone
        .send(&ClientMsg::DeviceRevoke {
            request_id: "p".into(),
            device: "iPhone".into(),
        })
        .await;
    phone.sync().await;
    // A satellite that tries to publish them.
    kobe.publish(&dec(
        json!({"type": "device_admin_level", "level": "full", "pair_from": ["kobe"]}),
    ))
    .await;
    kobe.publish(&dec(
        json!({"type": "device_admin_error", "request_id": "x", "reason": "forged"}),
    ))
    .await;
    kobe.sync().await;
    off.sync().await;

    let mut seen = Vec::new();
    loop {
        match raw.try_recv() {
            Ok(m) => seen.push(m),
            Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
            Err(_) => break,
        }
    }
    assert!(
        seen.iter().any(|m| matches!(m, ServerMsg::Hosts { .. })),
        "the channel was watched while the satellites came and went"
    );
    let leaked: Vec<&ServerMsg> = seen
        .iter()
        .filter(|m| {
            matches!(
                m,
                ServerMsg::DeviceAdminLevel { .. } | ServerMsg::DeviceAdminError { .. }
            )
        })
        .collect();
    assert!(leaked.is_empty(), "{leaked:?}");
}
