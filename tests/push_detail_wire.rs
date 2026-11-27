//! W16 fix round 1: the Notification Service Extension's EXACT frame sequence, against a
//! live in-process `Server` with the push engine running, over a real WebSocket.
//!
//! The daemon requires the second frame of every connection to be a `Subscribe` (or a
//! `Ping`); anything else ends the connection ("expected Subscribe"). The extension's first
//! cut sent `Hello` then `PushDetail`, so the daemon hung up on it and enrichment could
//! never work on a device. These tests pin the sequence the extension now sends
//! (`WebSocketPushDetailTransport`, `DeviceUnpairer`): `Hello`, `Subscribe` on ONE narrow
//! topic, then the verb. They send it in the order the Swift code does and read what a
//! phone reads, the raw frames included:
//!
//! * the reply to `PushDetail` arrives, with the text for an allowed personal-host item and
//!   without it (and without the line anywhere in the frame) for a work host, a PHI
//!   repository and a work owner;
//! * the only frames that come before the reply are the few the daemon sends everyone
//!   (the `Welcome` and the `Withheld` notice), so the extension's bounded read loop is
//!   not at risk of running out of frames before the answer;
//! * the same sequence without `Subscribe` gets no answer and a closed socket (the control
//!   that proves the `Subscribe` is what matters);
//! * `DeviceUnpairSelf`, the other verb the phone sends on a one-shot socket, is answered
//!   after the same `Subscribe` and not without it.
//!
//! The harness is `tests/support/ws_rig.rs`; the engine is started as `nostromd` starts it.

use std::sync::Arc;
use std::time::Duration;

use nostromo::config::PushConfig;
use nostromo::ipc::devices::RevokedBy;
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, ServerMsg, Topic};
use nostromo::push::wire::{
    HostClass, Presence, PushCapabilities, PushEnvironment, PushWaitingItem,
};
use nostromo::push::ConfigSource;
use serde_json::{json, Value};
use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

const PERSONAL: &str = "sendai";
const WORK: &str = "kobe";
const LINE: &str = "Ship the retry budget tonight?";
const MARKER: &str = "MARKER";

/// The topic the extension subscribes to. A paired phone is sent nothing on it, so the
/// attach-time replay and the live broadcasts that fill an "everything" subscription
/// (which can run past the extension's frame budget) are not sent to it.
const NARROW: Topic = Topic::Terminal;

/// A rig whose engine runs, with `sendai` personal and `kobe` work, a relay that accepts
/// every push, and a phone that has registered for pushes on its app connection.
struct Env {
    rig: Rig,
    _relay: MockServer,
    token: String,
    device_id: String,
    app: Conn,
    /// Every ref a decision of this test has already been given.
    known: Vec<String>,
}

impl Env {
    async fn new() -> Self {
        let rig = Rig::new().await;
        let relay = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/push"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"apns_status": 200})))
            .mount(&relay)
            .await;
        let relay_token = rig.tmp.path().join("relay-token");
        std::fs::write(&relay_token, "fake-relay-token\n").unwrap();
        let mut cfg = PushConfig {
            relay_url: Some(relay.uri()),
            relay_token_path: Some(relay_token),
            state_dir: Some(rig.tmp.path().join("push")),
            ..Default::default()
        };
        cfg.hosts.insert(PERSONAL.into(), HostClass::Personal);
        cfg.hosts.insert(WORK.into(), HostClass::Work);
        let source: ConfigSource = Arc::new(move || cfg.clone());
        assert!(rig.server.start_push(source, "tokyo".into()));

        let dev = rig.mint_device("Phone");
        let mut app = rig.device(&dev.token, &[], vec![]).await;
        app.send(&ClientMsg::RegisterPush {
            apns_token: "ab".repeat(32),
            environment: PushEnvironment::Sandbox,
            tz: "UTC".into(),
            capabilities: PushCapabilities::default(),
        })
        .await;
        app.next_matching("PushStatus", |m| matches!(m, ServerMsg::PushStatus(_)))
            .await;
        Env {
            rig,
            _relay: relay,
            token: dev.token,
            device_id: dev.device_id,
            app,
            known: Vec::new(),
        }
    }

    /// A decision that waits on `host`, in `owner/repo`, whose prompt is two lines (the
    /// second, and every other free-text field, holds the marker).
    async fn ask(&mut self, host: &str, repo: &str, owner: &str) -> String {
        let id = format!("req-{host}-{repo}-{owner}");
        self.rig.server.broadcast(ServerMsg::DecisionRequest {
            tag: "claudia-focus".into(),
            request_id: id,
            prompt: format!("{LINE}\n{MARKER}-second-line"),
            detail: Some(format!("{MARKER}-detail")),
            choices: (0..2)
                .map(|i| DecisionChoice {
                    id: format!("c{i}"),
                    label: format!("{MARKER}-label"),
                    detail: Some(format!("{MARKER}-choice-detail")),
                    is_default: i == 0,
                })
                .collect(),
            context_pane_id: Some(format!("{MARKER}-pane")),
            host: Some(host.into()),
            deadline: None,
            agent_class: None,
            operator_presence: Some(Presence::Active),
            repo: Some(repo.into()),
            repo_owner: Some(owner.into()),
        });
        // The engine ingests the broadcast on its own task: wait until the phone lists it.
        for _ in 0..200 {
            self.app.send(&ClientMsg::PushWaiting).await;
            let ServerMsg::PushWaiting { items, .. } = self
                .app
                .next_matching("PushWaiting", |m| {
                    matches!(m, ServerMsg::PushWaiting { .. })
                })
                .await
            else {
                unreachable!()
            };
            if let Some(found) = newest(&items, &self.known) {
                self.known.push(found.clone());
                return found;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the decision never reached the engine");
    }
}

/// The ref in `items` that is not in `known`.
fn newest(items: &[PushWaitingItem], known: &[String]) -> Option<String> {
    let mut fresh = items.iter().filter(|i| !known.contains(&i.item_ref));
    let only_one = fresh.next()?;
    // A decision per test: at most one ref the test has not seen.
    assert!(fresh.next().is_none(), "more than one new item: {items:?}");
    Some(only_one.item_ref.clone())
}

fn is_detail(m: &ServerMsg) -> bool {
    matches!(m, ServerMsg::PushDetail { .. })
}

/// The extension's sequence, in the order and with the frames it sends: `Hello`, the
/// `Welcome`, one narrow `Subscribe`, the verb. Nothing else.
async fn extension_sequence(env: &Env, verb: ClientMsg) -> Conn {
    let mut ext = env.rig.device_raw(&env.token).await;
    ext.send(&Conn::hello(&[], false)).await;
    ext.next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    ext.send(&Conn::subscribe(vec![NARROW])).await;
    ext.send(&verb).await;
    ext
}

/// The `type` of each frame the connection has read, in order.
fn types(conn: &Conn) -> Vec<String> {
    conn.raw
        .iter()
        .map(|t| {
            serde_json::from_str::<Value>(t).unwrap()["type"]
                .as_str()
                .unwrap_or_default()
                .to_string()
        })
        .collect()
}

/// The raw JSON of the `push_detail` frame the connection read.
fn raw_detail(conn: &Conn) -> Value {
    conn.raw
        .iter()
        .filter_map(|t| serde_json::from_str::<Value>(t).ok())
        .find(|v| v["type"] == "push_detail")
        .unwrap_or_else(|| panic!("no push_detail in {:#?}", conn.raw))
}

#[tokio::test]
async fn the_extensions_sequence_is_answered_with_the_line_for_a_personal_host_item() {
    let mut env = Env::new().await;
    let item_ref = env.ask(PERSONAL, "nostromo", "thehammer").await;

    let mut ext = extension_sequence(
        &env,
        ClientMsg::PushDetail {
            item_ref: item_ref.clone(),
        },
    )
    .await;
    let reply = ext.next_matching("the PushDetail reply", is_detail).await;

    let ServerMsg::PushDetail {
        item_ref: echoed,
        waiting,
        text,
        host,
    } = reply
    else {
        unreachable!()
    };
    assert_eq!(echoed, item_ref);
    assert!(waiting);
    assert_eq!(text.as_deref(), Some(LINE));
    assert_eq!(host.as_deref(), Some(PERSONAL));
    let frame = raw_detail(&ext).to_string();
    assert!(!frame.contains(MARKER), "only the line leaves: {frame}");

    // Everything the extension read before the answer is what the daemon sends every
    // subscriber, a handful of frames, so a bounded read loop reaches the reply.
    let before: Vec<String> = types(&ext)
        .into_iter()
        .take_while(|t| t != "push_detail")
        .collect();
    assert!(before.len() <= 3, "frames before the reply: {before:?}");
    for t in &before {
        assert!(
            ["welcome", "withheld"].contains(&t.as_str()),
            "an unexpected frame before the reply: {before:?}"
        );
    }
    assert_eq!(before.first().map(String::as_str), Some("welcome"));
}

#[tokio::test]
async fn the_extensions_sequence_is_answered_without_text_when_the_rule_withholds_it() {
    let mut env = Env::new().await;
    let cases = [
        ("a work host", WORK, "nostromo", "thehammer"),
        ("a PHI repository", PERSONAL, "admin-portal", "thehammer"),
        ("a work owner", PERSONAL, "nostromo", "Carefeed"),
    ];
    for (why, host, repo, owner) in cases {
        let item_ref = env.ask(host, repo, owner).await;
        let mut ext = extension_sequence(
            &env,
            ClientMsg::PushDetail {
                item_ref: item_ref.clone(),
            },
        )
        .await;
        let reply = ext.next_matching("the PushDetail reply", is_detail).await;
        let ServerMsg::PushDetail {
            item_ref: echoed,
            waiting,
            text,
            ..
        } = reply
        else {
            unreachable!()
        };
        assert_eq!(echoed, item_ref, "{why}");
        assert!(waiting, "{why}: the item still waits");
        assert_eq!(text, None, "{why}");
        let frame = raw_detail(&ext);
        assert!(frame.get("text").is_none(), "{why}: {frame}");
        let frame = frame.to_string();
        assert!(
            !frame.contains(MARKER) && !frame.contains(LINE),
            "{why}: {frame}"
        );
    }
}

#[tokio::test]
async fn without_a_subscribe_the_daemon_hangs_up_and_no_reply_comes() {
    let mut env = Env::new().await;
    let item_ref = env.ask(PERSONAL, "nostromo", "thehammer").await;

    // What the extension used to send.
    let mut ext = env.rig.device_raw(&env.token).await;
    ext.send(&Conn::hello(&[], false)).await;
    ext.next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    ext.send(&ClientMsg::PushDetail { item_ref }).await;

    ext.expect_close_within(Duration::from_secs(2)).await;
    assert!(
        !ext.inbox.iter().any(is_detail) && !types(&ext).iter().any(|t| t == "push_detail"),
        "no reply came: {:#?}",
        ext.raw
    );
}

#[tokio::test]
async fn a_phone_unpairs_itself_over_a_one_shot_socket_only_after_a_subscribe() {
    let env = Env::new().await;

    // Without a Subscribe: hung up on, still paired.
    let mut bare = env.rig.device_raw(&env.token).await;
    bare.send(&Conn::hello(&[], false)).await;
    bare.next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    bare.send(&ClientMsg::DeviceUnpairSelf).await;
    bare.expect_close_within(Duration::from_secs(2)).await;
    assert!(
        !bare
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::DeviceUnpaired)),
        "no DeviceUnpaired without a Subscribe: {:#?}",
        bare.raw
    );
    let mut admin = env.rig.unix(vec![], false).await;
    let (devices, _) = admin.device_list().await;
    assert!(
        devices
            .iter()
            .find(|d| d.id == env.device_id)
            .is_some_and(|d| d.revoked_at.is_none()),
        "still paired"
    );

    // With the Subscribe the phone sends: answered, and removed by the device.
    let mut ext = extension_sequence(&env, ClientMsg::DeviceUnpairSelf).await;
    ext.next_matching("DeviceUnpaired", |m| matches!(m, ServerMsg::DeviceUnpaired))
        .await;
    let (devices, _) = admin.device_list().await;
    let gone = devices.iter().find(|d| d.id == env.device_id).unwrap();
    assert!(gone.revoked_at.is_some(), "{gone:?}");
    assert_eq!(gone.revoked_by, Some(RevokedBy::Device));
}
