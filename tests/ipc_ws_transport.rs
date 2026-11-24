//! Integration tests for the WebSocket transport (W9).
//!
//! Mirrors `tests/ipc_tcp_transport.rs`: a real `Server` on a tempdir Unix socket
//! plus the WebSocket listener on port 0, the device registry in the tempdir, and
//! clients that connect with `tokio_tungstenite::connect_async`. What these pin,
//! from outside the daemon:
//!
//! * a socket that presents a valid device token is served like any other client
//!   (`Hello`, `Welcome`, `Subscribe`, broadcasts) and is a `Paired` peer: never
//!   sent Teri, Fred or work frames, told once that they are `not_shared`;
//! * an unknown or revoked token completes the upgrade, hears `Unauthorized`, and
//!   is closed with 4001 (so a device can tell "refused" from "unreachable");
//! * a socket with no token may say `Hello`, check codes and send one `Pair`, and
//!   nothing else;
//! * an oversize text frame closes with 1009 and a binary frame with 1003;
//! * a device never closes the merge gate (B11).
//!
//! The pairing lifecycle itself is in `tests/device_pairing.rs`; what a `Paired`
//! peer may see and do is pinned further in `tests/ipc_peer_gating.rs`.

use std::path::PathBuf;
use std::time::Duration;

use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::data::work::{
    PicksSnapshot, SendOutcome, SourceState, SourceStatus, WorkDetail, WorkItem, WorkResult,
    WorkSource,
};
use nostromo::ipc::peer::is_refusal;
use nostromo::ipc::protocol::{
    ClientMsg, ServerMsg, Topic, FEATURE_MERGED_TURNS, MAX_FRAME_LEN, PROTOCOL_VERSION,
};
use nostromo::ipc::session_manager::{merge, CLAUDE_BIN_ENV};
use nostromo::ipc::stream_json::TurnDelta;
use serde_json::{json, Value};

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── payloads ──────────────────────────────────────────────────────────────────

fn fred_state() -> ServerMsg {
    ServerMsg::FredState {
        mailbox: MailboxSnapshot {
            unread_count: 7,
            ..Default::default()
        },
        calendar: CalendarSnapshot::default(),
    }
}

fn teri_state() -> ServerMsg {
    ServerMsg::TeriState {
        todos: TeriTodosSnapshot {
            items: vec![TeriTodo {
                id: 1,
                title: "secret-todo".into(),
                status: "open".into(),
                priority: 2,
                due_date: None,
                jira_key: None,
                body: None,
            }],
            ..Default::default()
        },
    }
}

fn work_item(id: &str) -> WorkItem {
    serde_json::from_value(json!({
        "id": id,
        "source": "repo_docs",
        "kind": "plan",
        "title": format!("title of {id}"),
    }))
    .expect("a work item")
}

/// Every frame that carries Teri, Fred or work data, including targeted-reply
/// kinds a buggy daemon might broadcast.
fn sensitive_frames() -> Vec<ServerMsg> {
    vec![
        fred_state(),
        teri_state(),
        ServerMsg::WorkSourceStatus {
            status: SourceStatus {
                source: WorkSource::Jira,
                state: SourceState::Fresh,
                updated_at: None,
                reason: None,
                retry_at: None,
                count: 1,
                group_errors: vec![],
                complete: false,
            },
        },
        ServerMsg::WorkSnapshot {
            source: WorkSource::RepoDocs,
            group: Some("repo-a".into()),
            items: vec![work_item("doc:repo-a:plans/x.md")],
        },
        ServerMsg::TeriPicks {
            picks: PicksSnapshot::default(),
        },
        ServerMsg::WorkDetail {
            request_id: "stray".into(),
            result: WorkResult::Ok(WorkDetail {
                item_id: "jira:X".into(),
                title: "leaked".into(),
                fields: vec![],
                markdown: String::new(),
                files: vec![],
                links: vec![],
            }),
        },
        ServerMsg::WorkSendResult {
            request_id: "stray".into(),
            result: WorkResult::Ok(SendOutcome {
                kind: "created".into(),
                focus_tag: Some("fake-focus".into()),
                job_id: None,
            }),
        },
    ]
}

fn is_sensitive(msg: &ServerMsg) -> bool {
    matches!(
        msg,
        ServerMsg::FredState { .. }
            | ServerMsg::TeriState { .. }
            | ServerMsg::WorkSourceStatus { .. }
            | ServerMsg::WorkSnapshot { .. }
            | ServerMsg::TeriPicks { .. }
            | ServerMsg::WorkDetail { .. }
            | ServerMsg::WorkSendPreview { .. }
            | ServerMsg::WorkSendResult { .. }
    )
}

fn focus_registry_updated() -> ServerMsg {
    ServerMsg::FocusRegistryUpdated {
        focuses: vec![],
        host: None,
    }
}

/// The one `Withheld` a device is told about after subscribing.
fn withheld_notices(frames: &[ServerMsg]) -> Vec<(Vec<Topic>, String)> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::Withheld { topics, reason } => Some((topics.clone(), reason.clone())),
            _ => None,
        })
        .collect()
}

fn assert_told_once_not_shared(frames: &[ServerMsg]) {
    assert_eq!(
        withheld_notices(frames),
        vec![(
            vec![Topic::Fred, Topic::Teri, Topic::Work],
            "not_shared".to_string()
        )],
        "{frames:?}"
    );
}

// ── (a) a valid token is served like any client ───────────────────────────────

#[tokio::test]
async fn a_valid_token_gets_a_welcome_and_receives_broadcasts() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = rig.device_raw(&dev.token).await;

    // The Hello claims to be the Mac app: over this transport the claim lifts nobody.
    ws.send(&Conn::hello(&[], true)).await;
    let welcome = ws
        .next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    match welcome {
        ServerMsg::Welcome {
            protocol_version,
            features,
            operator_nonce,
            ..
        } => {
            assert_eq!(protocol_version, PROTOCOL_VERSION);
            for feature in ["ws", "pair", "devices"] {
                assert!(
                    features.iter().any(|f| f == feature),
                    "{feature} missing from {features:?}"
                );
            }
            assert!(
                operator_nonce.is_none(),
                "a device is never issued an operator nonce"
            );
        }
        _ => unreachable!(),
    }

    ws.send(&Conn::subscribe(vec![Topic::Focuses])).await;
    ws.sync().await;
    rig.server.broadcast(focus_registry_updated());
    ws.next_matching("the broadcast", |m| {
        matches!(m, ServerMsg::FocusRegistryUpdated { .. })
    })
    .await;

    // The same connection answers requests like any other.
    ws.send(&ClientMsg::SessionList).await;
    ws.next_matching("SessionListResp", |m| {
        matches!(m, ServerMsg::SessionListResp { .. })
    })
    .await;
}

#[tokio::test]
async fn the_welcome_names_ws_pair_and_devices_on_every_transport() {
    let rig = Rig::new().await;
    let unix = rig.unix(vec![], false).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;
    let dev = rig.mint_device("iPhone");
    let paired = rig.device(&dev.token, &[], vec![]).await;
    let mut pairing = rig.pairing_socket().await;
    pairing.send(&Conn::hello(&[], false)).await;
    pairing.welcome = Some(
        pairing
            .next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
            .await,
    );

    for (what, conn) in [
        ("unix", &unix),
        ("tcp", &tcp),
        ("a paired device", &paired),
        ("a pairing socket", &pairing),
    ] {
        let features = conn.features();
        for feature in ["ws", "pair", "devices"] {
            assert!(
                features.iter().any(|f| f == feature),
                "{what}: {feature} missing from {features:?}"
            );
        }
        match conn.welcome.as_ref().unwrap() {
            ServerMsg::Welcome {
                protocol_version, ..
            } => assert_eq!(*protocol_version, 4, "{what}"),
            _ => unreachable!(),
        }
    }
}

#[tokio::test]
async fn an_old_protocol_version_is_told_so_and_closed_on_a_paired_and_a_pairing_socket() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let old_hello = ClientMsg::Hello {
        capabilities: Vec::new(),
        client_id: "old-client".into(),
        protocol_version: 0,
        client_kind: None,
        role: None,
    };
    for (what, mut ws) in [
        ("a paired socket", rig.device_raw(&dev.token).await),
        ("a pairing socket", rig.pairing_socket().await),
    ] {
        ws.send(&old_hello).await;
        let err = ws
            .next_matching("an Error", |m| matches!(m, ServerMsg::Error { .. }))
            .await;
        assert!(
            matches!(&err, ServerMsg::Error { message } if message.contains("protocol version")),
            "{what}: {err:?}"
        );
        ws.expect_close().await;
    }
}

// ── (b) bad, unknown and revoked tokens ───────────────────────────────────────

#[tokio::test]
async fn an_unknown_token_completes_the_upgrade_hears_unauthorized_and_is_closed_4001() {
    let rig = Rig::new().await;
    // `device_raw` panics unless the upgrade completes: an HTTP 401 would fail it.
    let mut ws = rig.device_raw("not-a-token-this-server-ever-issued").await;

    assert_eq!(ws.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    let frames = ws.take_all();
    assert!(
        matches!(frames.as_slice(), [ServerMsg::Unauthorized { reason }] if reason == "unknown"),
        "exactly one Unauthorized(unknown), no Welcome or anything else: {frames:?}"
    );
}

#[tokio::test]
async fn a_revoked_token_hears_unauthorized_revoked_and_is_closed_4001() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("Old phone");
    let mut admin = rig.unix(vec![], false).await;
    assert!(matches!(
        admin.revoke(&dev.name).await,
        ServerMsg::DeviceRevoked {
            was_connected: false,
            ..
        }
    ));

    let mut ws = rig.device_raw(&dev.token).await;
    assert_eq!(ws.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    let frames = ws.take_all();
    assert!(
        matches!(frames.as_slice(), [ServerMsg::Unauthorized { reason }] if reason == "revoked"),
        "{frames:?}"
    );
}

#[tokio::test]
async fn a_token_in_the_query_string_is_not_a_credential() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = Conn::try_ws(rig.ws_port, None, &format!("/?token={}", dev.token))
        .await
        .expect("the upgrade completes");

    // It is a pairing socket: it may say hello, but a subscribe is "not paired".
    ws.send(&Conn::hello(&[], false)).await;
    ws.next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    ws.send(&Conn::subscribe(vec![])).await;
    let refused = ws
        .next_matching("Unauthorized", |m| {
            matches!(m, ServerMsg::Unauthorized { .. })
        })
        .await;
    assert!(matches!(refused, ServerMsg::Unauthorized { reason } if reason == "not_paired"));
    assert_eq!(ws.expect_close().await, Some(CLOSE_UNAUTHORIZED));
}

// ── (c) frames that are not clean text frames ─────────────────────────────────

#[tokio::test]
async fn an_oversize_text_frame_closes_a_paired_and_a_pairing_socket_with_1009() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    // Over the limit, but under what the library would refuse by itself.
    let big = "x".repeat(MAX_FRAME_LEN + 1024);

    let mut paired = rig.device(&dev.token, &[], vec![]).await;
    paired.try_send_text(big.clone()).await;
    assert_eq!(paired.expect_close().await, Some(1009), "paired");

    let mut pairing = rig.pairing_socket().await;
    pairing.try_send_text(big).await;
    assert_eq!(pairing.expect_close().await, Some(1009), "pairing");
}

#[tokio::test]
async fn a_text_frame_exactly_at_the_limit_is_not_refused() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut paired = rig.device(&dev.token, &[], vec![]).await;

    // Not a message the daemon can read, but a frame it must carry.
    assert!(paired.try_send_text("x".repeat(MAX_FRAME_LEN)).await);
    paired.sync().await;
    assert_eq!(paired.closed, None, "the socket is still open");
}

#[tokio::test]
async fn a_binary_frame_closes_a_paired_and_a_pairing_socket_with_1003() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");

    let mut paired = rig.device(&dev.token, &[], vec![]).await;
    paired.send_binary(vec![0, 1, 2, 3]).await;
    assert_eq!(paired.expect_close().await, Some(1003), "paired");

    let mut pairing = rig.pairing_socket().await;
    pairing.send_binary(vec![0, 1, 2, 3]).await;
    assert_eq!(pairing.expect_close().await, Some(1003), "pairing");
}

// ── (d) a paired device is never sent Teri, Fred or work data ─────────────────

#[tokio::test]
async fn a_paired_device_subscribed_to_everything_never_receives_teri_fred_or_work_frames() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = rig.device(&dev.token, &[], vec![]).await;

    for msg in sensitive_frames() {
        rig.server.broadcast(msg);
    }
    // The control comes after the sensitive frames on the same ordered channel:
    // once it arrives, anything that was going to be delivered already has been.
    rig.server.broadcast(focus_registry_updated());
    ws.next_matching("the control broadcast", |m| {
        matches!(m, ServerMsg::FocusRegistryUpdated { .. })
    })
    .await;

    let seen = ws.take_all();
    let leaked: Vec<_> = seen.iter().filter(|m| is_sensitive(m)).collect();
    assert!(
        leaked.is_empty(),
        "sensitive frames reached a device: {leaked:?}"
    );
    assert_told_once_not_shared(&seen);
}

#[tokio::test]
async fn naming_the_fred_teri_and_work_topics_still_delivers_nothing_sensitive() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = rig
        .device(&dev.token, &[], vec![Topic::Fred, Topic::Teri, Topic::Work])
        .await;

    for msg in sensitive_frames() {
        rig.server.broadcast(msg);
    }
    rig.server.broadcast(ServerMsg::Pong);
    ws.next_matching("the control", |m| matches!(m, ServerMsg::Pong))
        .await;

    let seen = ws.take_all();
    assert!(seen.iter().all(|m| !is_sensitive(m)), "{seen:?}");
    assert_told_once_not_shared(&seen);
}

#[tokio::test]
async fn a_paired_device_is_told_once_what_is_not_shared() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = rig.device(&dev.token, &[], vec![]).await;
    assert_told_once_not_shared(&ws.take_all());

    ws.sync().await;
    assert!(
        withheld_notices(&ws.take_all()).is_empty(),
        "the notice is not repeated"
    );
}

// ── (e) what a paired device is replayed, and what it is sent live ────────────
//
// The retained cache holds only Teri, Fred, work and two local-only frames
// (`retain_key`), and a paired device may receive none of them. The replay it is
// owed is therefore exactly the `Withheld` notice. Mother jobs and approval counts
// are not retained: a device is sent them live, and those frames reach it.

fn retained_frames() -> Vec<ServerMsg> {
    let mut frames = sensitive_frames();
    // Retained, and for the operator's eyes only (focus tags, held counts).
    frames.push(
        serde_json::from_value(json!({
            "type": "mother_notice_state", "enabled": true, "focuses": []
        }))
        .expect("a MotherNoticeState"),
    );
    frames
}

#[tokio::test]
async fn a_paired_device_that_connects_late_is_replayed_nothing_it_may_not_have_and_one_notice() {
    let rig = Rig::new().await;
    for msg in retained_frames() {
        rig.server.broadcast(msg);
    }
    // Control: a local client that subscribes after the fact is replayed the
    // retained frames, so the cache did take them (retention is asynchronous).
    let mut replayed = false;
    for _ in 0..50 {
        let local = rig.unix(vec![], false).await;
        if local
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::FredState { .. }))
        {
            replayed = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(replayed, "control: the retained cache was never filled");

    let dev = rig.mint_device("iPhone");
    let mut ws = rig.device(&dev.token, &[], vec![]).await;
    let replay = ws.take_all();
    assert!(
        replay.iter().all(|m| !is_sensitive(m)),
        "a device was replayed Teri, Fred or work data: {replay:?}"
    );
    assert!(
        !replay
            .iter()
            .any(|m| matches!(m, ServerMsg::MotherNoticeState { .. })),
        "a device was replayed a local-only frame: {replay:?}"
    );
    assert_told_once_not_shared(&replay);

    // Adding topics later replays retained frames for them: still none of these.
    ws.send(&Conn::subscribe(vec![
        Topic::Fred,
        Topic::Teri,
        Topic::Work,
    ]))
    .await;
    ws.sync().await;
    assert!(
        ws.take_all().iter().all(|m| !is_sensitive(m)),
        "a re-subscribe replayed Teri, Fred or work data"
    );
}

fn mother_job(id: &str) -> nostromo::mother::MotherJob {
    serde_json::from_value(json!({
        "id": id,
        "state": "awaiting",
        "title": "an ordinary job",
        "activity": "gate_hold",
    }))
    .expect("a MotherJob")
}

#[tokio::test]
async fn a_paired_device_receives_mother_jobs_and_approval_counts_for_ordinary_focuses_live() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let mut ws = rig.device(&dev.token, &[], vec![]).await;

    rig.server.broadcast(ServerMsg::MotherJobs {
        jobs: vec![mother_job("job-ws-1")],
        host: None,
    });
    // A count for a sensitive focus is withheld; the ordinary one is not.
    rig.server.broadcast(ServerMsg::ApprovalPending {
        tag: "fred".into(),
        count: 9,
        host: None,
    });
    rig.server.broadcast(ServerMsg::ApprovalPending {
        tag: "cody-x".into(),
        count: 2,
        host: None,
    });

    ws.next_matching(
        "the job list",
        |m| matches!(m, ServerMsg::MotherJobs { jobs, .. } if jobs.iter().any(|j| j.id == "job-ws-1")),
    )
    .await;
    ws.next_matching(
        "the approval count",
        |m| matches!(m, ServerMsg::ApprovalPending { tag, count: 2, .. } if tag == "cody-x"),
    )
    .await;
    // The broadcast channel is ordered: the withheld count was queued before the
    // one that arrived, so had it been delivered it would be here already.
    assert!(
        !ws.inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::ApprovalPending { tag, .. } if tag == "fred")),
        "{:?}",
        ws.inbox
    );
}

// ── a socket with no token ────────────────────────────────────────────────────

#[tokio::test]
async fn a_socket_with_no_token_may_say_hello_and_check_a_code() {
    let rig = Rig::new().await;
    let mut sock = rig.pairing_socket().await;

    sock.send(&Conn::hello(&[], true)).await;
    let welcome = sock
        .next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
    match welcome {
        ServerMsg::Welcome {
            features,
            operator_nonce,
            ..
        } => {
            assert!(features.iter().any(|f| f == "pair"), "{features:?}");
            assert!(operator_nonce.is_none());
        }
        _ => unreachable!(),
    }

    // No code is open: a refusal, and the socket stays up for another try.
    let reply = sock.pair_check("123456", None).await;
    assert!(matches!(
        reply,
        ServerMsg::PairRefused {
            reason: nostromo::ipc::devices::PairRefusedReason::Invalid
        }
    ));
    sock.pair_check("123457", None).await;
    assert_eq!(sock.closed, None);
}

#[tokio::test]
async fn a_socket_with_no_token_that_sends_anything_else_is_unauthorized_not_paired_and_closed() {
    let rig = Rig::new().await;
    let attempts: Vec<(&str, String)> = vec![
        ("a ping", json_of(&ClientMsg::Ping)),
        ("a subscribe", json_of(&Conn::subscribe(vec![]))),
        ("a session list", json_of(&ClientMsg::SessionList)),
        (
            "a session send",
            json_of(&ClientMsg::SessionSend {
                tag: "cody-x".into(),
                text: "hello".into(),
                images: vec![],
                client_ref: None,
            }),
        ),
        (
            "a device list",
            json_of(&ClientMsg::DeviceList {
                request_id: "r".into(),
            }),
        ),
        ("an unpair", json_of(&ClientMsg::DeviceUnpairSelf)),
        (
            "a pairing start",
            json_of(&ClientMsg::DevicePairStart {
                request_id: "r".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
            }),
        ),
        ("garbage", "this is not json".to_string()),
    ];
    for (what, text) in attempts {
        let mut sock = rig.pairing_socket().await;
        sock.send_text(text).await;
        assert_eq!(
            sock.expect_close().await,
            Some(CLOSE_UNAUTHORIZED),
            "{what}"
        );
        let frames = sock.take_all();
        assert!(
            matches!(frames.as_slice(), [ServerMsg::Unauthorized { reason }] if reason == "not_paired"),
            "{what}: {frames:?}"
        );
    }
}

fn json_of(msg: &ClientMsg) -> String {
    serde_json::to_string(msg).unwrap()
}

#[tokio::test]
async fn a_pairing_socket_is_closed_after_its_one_pair_whatever_the_answer() {
    let rig = Rig::new().await;
    let mut sock = rig.pairing_socket().await;
    sock.send(&ClientMsg::Pair {
        code: "123456".into(),
        name: "iPhone".into(),
        kind: nostromo::ipc::devices::DeviceKind::Iphone,
        replace: false,
    })
    .await;
    let reply = sock
        .next_matching("the reply", |m| matches!(m, ServerMsg::PairRefused { .. }))
        .await;
    assert!(matches!(
        reply,
        ServerMsg::PairRefused {
            reason: nostromo::ipc::devices::PairRefusedReason::Invalid
        }
    ));
    sock.expect_close().await;
    assert!(sock.take_all().is_empty(), "nothing follows the reply");
}

#[tokio::test]
async fn at_most_twenty_unauthenticated_upgrades_a_minute_per_address_and_a_device_is_not_counted()
{
    // The slot caps are not under test here: leave room for twenty sockets.
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated_per_ip: 64,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;
    let dev = rig.mint_device("iPhone");

    let mut open = Vec::new();
    for _ in 0..20 {
        open.push(
            Conn::try_ws(rig.ws_port, None, "/")
                .await
                .expect("within the limit"),
        );
    }
    match Conn::try_ws(rig.ws_port, None, "/").await {
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            assert_eq!(resp.status().as_u16(), 429);
        }
        Err(other) => panic!("expected HTTP 429, got {other:?}"),
        Ok(_) => panic!("the twenty-first upgrade was admitted"),
    }
    // A valid token is never throttled by strangers' attempts.
    let mut device = rig.device(&dev.token, &[], vec![]).await;
    device.sync().await;
}

// ── the legacy TCP transport and the device verbs ─────────────────────────────

#[tokio::test]
async fn a_legacy_tcp_peer_is_refused_every_pairing_and_device_verb() {
    let rig = Rig::new().await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![], false).await;

    let verbs = vec![
        ("device_unpair_self", ClientMsg::DeviceUnpairSelf),
        (
            "device_list",
            ClientMsg::DeviceList {
                request_id: "r".into(),
            },
        ),
        (
            "device_revoke",
            ClientMsg::DeviceRevoke {
                request_id: "r".into(),
                device: "anyone".into(),
            },
        ),
        (
            "device_pair_start",
            ClientMsg::DevicePairStart {
                request_id: "r".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
            },
        ),
        (
            "pair_check",
            ClientMsg::PairCheck {
                code: "123456".into(),
                proof: None,
            },
        ),
    ];
    for (what, verb) in verbs {
        tcp.send(&verb).await;
        let refusal = tcp.next_matching(what, is_refusal).await;
        assert!(
            matches!(&refusal, ServerMsg::Error { message } if message.contains("requires_secure_connection")),
            "{what}: {refusal:?}"
        );
    }
    tcp.sync().await;
    assert!(
        !tcp.inbox.iter().any(|m| matches!(
            m,
            ServerMsg::Devices { .. } | ServerMsg::DevicePairing { .. } | ServerMsg::Paired { .. }
        )),
        "{:?}",
        tcp.inbox
    );
}

#[tokio::test]
async fn a_local_client_cannot_pair_a_device_or_check_a_code() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;

    // Pairing verbs are for a token-less WebSocket only: sent on the Unix socket
    // they do nothing (no reply, no code used up, no device).
    let mut local = rig.unix(vec![], false).await;
    local
        .send(&ClientMsg::Pair {
            code: pairing.code.clone(),
            name: "Sneaky".into(),
            kind: nostromo::ipc::devices::DeviceKind::Iphone,
            replace: false,
        })
        .await;
    local
        .send(&ClientMsg::PairCheck {
            code: pairing.code.clone(),
            proof: None,
        })
        .await;
    local.sync().await;
    assert!(
        !local.inbox.iter().any(|m| matches!(
            m,
            ServerMsg::Paired { .. } | ServerMsg::PairOffer { .. } | ServerMsg::PairRefused { .. }
        )),
        "{:?}",
        local.inbox
    );
    let (devices, hosts) = rig.registry.summaries(|_| false);
    assert!(devices.is_empty() && hosts.is_empty(), "{devices:?}");

    let mut sock = rig.pairing_socket().await;
    assert!(
        matches!(
            sock.pair_check(&pairing.code, None).await,
            ServerMsg::PairOffer { .. }
        ),
        "the code is still live"
    );
}

#[tokio::test]
async fn device_list_frames_are_never_delivered_to_a_paired_device_or_a_tcp_peer() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    let other = rig.mint_device("iPad");
    // Naming the topic changes nothing for a network peer.
    let mut named = rig.device(&dev.token, &[], vec![Topic::Devices]).await;
    let mut everything = rig.device(&dev.token, &[], vec![]).await;
    let mut tcp = rig.tcp_raw().await;
    tcp.handshake(&[], vec![Topic::Devices], false).await;
    // Control: a local client that names the topic is told.
    let mut admin = rig.unix(vec![Topic::Devices], false).await;

    // A device connecting and one being revoked each broadcast the device list.
    let _other_ws = rig.device(&other.token, &[], vec![]).await;
    assert!(matches!(
        admin.revoke(&other.name).await,
        ServerMsg::DeviceRevoked { .. }
    ));
    admin
        .next_matching("a Devices broadcast", |m| {
            matches!(m, ServerMsg::Devices { .. })
        })
        .await;

    rig.server.broadcast(ServerMsg::Pong);
    for (what, conn) in [
        ("a device naming the topic", &mut named),
        ("a device subscribed to everything", &mut everything),
        ("a tcp peer", &mut tcp),
    ] {
        conn.next_matching("the control", |m| matches!(m, ServerMsg::Pong))
            .await;
        let seen = conn.take_all();
        assert!(
            !seen.iter().any(|m| matches!(
                m,
                ServerMsg::Devices { .. }
                    | ServerMsg::DevicePairing { .. }
                    | ServerMsg::DevicePairOutcome { .. }
                    | ServerMsg::DeviceRevoked { .. }
                    | ServerMsg::DeviceAdminError { .. }
            )),
            "{what} was sent device administration: {seen:?}"
        );
    }
}

// ── (p) B11: a device never closes the merge gate ─────────────────────────────

const FAKE_CLI: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/support/fake_claude_perm.py"
);

/// A busy session of the hermetic fake `claude` (`HOLD:<path>` keeps a turn open
/// until the file exists; every stdin frame is logged), under `cody-1`.
fn start_fake_session(rig: &Rig) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let fake_dir = rig.tmp.path().join("fake");
    std::fs::create_dir_all(&fake_dir).unwrap();
    let wrapper = fake_dir.join("claude");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nFAKE_CLAUDE_LOG_DIR='{}' exec python3 -I '{FAKE_CLI}' \"$@\"\n",
            fake_dir.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::env::set_var(CLAUDE_BIN_ENV, &wrapper);
    let work = rig.tmp.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    rig.session_mgr
        .lock()
        .unwrap()
        .spawn_session(
            "cody-1".into(),
            "cody".into(),
            "View".into(),
            Some(work),
            None,
            false,
        )
        .expect("the session starts");
    fake_dir
}

/// Everything the fake CLI read on stdin as user frames' contents.
fn user_contents(fake_dir: &std::path::Path) -> Vec<Value> {
    std::fs::read_to_string(fake_dir.join("stdin.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|f| f["type"] == "user")
        .map(|f| f["message"]["content"].clone())
        .collect()
}

fn send_to_session(text: &str) -> ClientMsg {
    ClientMsg::SessionSend {
        tag: "cody-1".into(),
        text: text.into(),
        images: Vec::new(),
        client_ref: None,
    }
}

/// A local client that declared `merged_turns_v1` and a WebSocket device that
/// declared `device_caps` are both attached to a busy session; two typed messages
/// queued behind the turn still reach the CLI as one merged frame.
async fn queued_messages_merge_with_a_device_attached(device_caps: &[&str]) {
    let rig = Rig::with_sessions().await;
    let fake_dir = start_fake_session(&rig);

    let mut local = rig.unix_with(vec![], false, &[FEATURE_MERGED_TURNS]).await;
    local
        .send(&ClientMsg::SessionAttach {
            tag: "cody-1".into(),
        })
        .await;
    local.sync().await;

    let dev = rig.mint_device("Kitchen iPad");
    let mut device = rig.device(&dev.token, device_caps, vec![]).await;
    device
        .send(&ClientMsg::SessionAttach {
            tag: "cody-1".into(),
        })
        .await;
    device.sync().await;

    let hold = rig.tmp.path().join("hold");
    local
        .send(&send_to_session(&format!("first HOLD:{}", hold.display())))
        .await;
    Rig::wait_until("the first frame", || user_contents(&fake_dir).len() == 1).await;
    local
        .send(&send_to_session("oh and backfill the rows"))
        .await;
    local
        .send(&send_to_session("use the new column name"))
        .await;
    local.sync().await;
    std::fs::write(&hold, "").unwrap();

    Rig::wait_until("the merged frame", || user_contents(&fake_dir).len() >= 2).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    let frames = user_contents(&fake_dir);
    assert_eq!(
        frames.len(),
        2,
        "one frame for both queued messages (the device did not close the gate): {frames:#?}"
    );
    let parsed = merge::parse(frames[1].as_str().unwrap()).expect("a merged frame");
    assert_eq!(
        parsed.parts,
        ["oh and backfill the rows", "use the new column name"]
    );

    // The device watches the merged turn as one started turn of two parts.
    let started = device
        .next_matching("the merged turn", |m| {
            matches!(
                m,
                ServerMsg::SessionTurnDelta {
                    delta: TurnDelta::TurnStarted { turn },
                    ..
                } if !turn.user_parts.is_empty()
            )
        })
        .await;
    match started {
        ServerMsg::SessionTurnDelta {
            delta: TurnDelta::TurnStarted { turn },
            ..
        } => assert_eq!(
            turn.user_parts,
            ["oh and backfill the rows", "use the new column name"]
        ),
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn a_device_that_declared_merged_turns_does_not_stop_queued_messages_merging() {
    queued_messages_merge_with_a_device_attached(&[FEATURE_MERGED_TURNS]).await;
}

#[tokio::test]
async fn a_device_that_declared_nothing_does_not_stop_queued_messages_merging() {
    queued_messages_merge_with_a_device_attached(&[]).await;
}

// ── pre-auth resource limits ──────────────────────────────────────────────────

fn short_limits() -> nostromo::ipc::ws::WsLimits {
    nostromo::ipc::ws::WsLimits {
        handshake_timeout: Duration::from_millis(300),
        ..Default::default()
    }
}

/// True once the peer has closed `stream` (EOF or a reset) within `within`.
async fn closed_within(stream: &mut tokio::net::TcpStream, within: Duration) -> bool {
    use tokio::io::AsyncReadExt;
    let mut buf = [0u8; 64];
    match tokio::time::timeout(within, stream.read(&mut buf)).await {
        Err(_) => false,
        Ok(Ok(0)) | Ok(Err(_)) => true,
        Ok(Ok(_)) => false,
    }
}

#[tokio::test]
async fn a_socket_that_sends_nothing_is_closed_after_the_handshake_timeout() {
    let rig = Rig::with_limits(short_limits()).await;
    let mut idle = tokio::net::TcpStream::connect(("127.0.0.1", rig.ws_port))
        .await
        .unwrap();
    assert!(
        closed_within(&mut idle, Duration::from_secs(3)).await,
        "an idle connection was left open"
    );
}

#[tokio::test]
async fn a_socket_that_trickles_a_request_is_closed_after_the_handshake_timeout() {
    use tokio::io::AsyncWriteExt;
    let rig = Rig::with_limits(short_limits()).await;
    let mut slow = tokio::net::TcpStream::connect(("127.0.0.1", rig.ws_port))
        .await
        .unwrap();
    slow.write_all(b"GET / HTTP/1.1\r\nHost: x\r\n")
        .await
        .unwrap();
    assert!(
        closed_within(&mut slow, Duration::from_secs(3)).await,
        "a half-sent request was left open"
    );
}

#[tokio::test]
async fn a_timed_out_handshake_releases_its_slot() {
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated: 1,
        ..short_limits()
    };
    let rig = Rig::with_limits(limits).await;
    let mut idle = tokio::net::TcpStream::connect(("127.0.0.1", rig.ws_port))
        .await
        .unwrap();
    assert!(closed_within(&mut idle, Duration::from_secs(3)).await);
    // The only slot is free again.
    Conn::try_ws(rig.ws_port, None, "/")
        .await
        .expect("the slot was released");
}

#[tokio::test]
async fn the_unauthenticated_cap_refuses_the_next_connection_until_a_slot_is_freed() {
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated: 3,
        max_unauthenticated_per_ip: 3,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;

    let mut open = Vec::new();
    for _ in 0..3 {
        open.push(
            Conn::try_ws(rig.ws_port, None, "/")
                .await
                .expect("within the cap"),
        );
    }
    assert!(
        Conn::try_ws(rig.ws_port, None, "/").await.is_err(),
        "the fourth unauthenticated connection was admitted"
    );
    // Once a slot is free, the next is admitted.
    drop(open.pop());
    let mut admitted = false;
    for _ in 0..50 {
        if Conn::try_ws(rig.ws_port, None, "/").await.is_ok() {
            admitted = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(admitted, "a released slot was not reusable");
    drop(open);
}

#[tokio::test]
async fn the_global_cap_alone_refuses_the_next_connection() {
    // The per-address cap is higher, so only the global one can refuse.
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated: 2,
        max_unauthenticated_per_ip: 10,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;
    let _a = Conn::try_ws(rig.ws_port, None, "/").await.unwrap();
    let _b = Conn::try_ws(rig.ws_port, None, "/").await.unwrap();
    assert!(
        Conn::try_ws(rig.ws_port, None, "/").await.is_err(),
        "the global cap did not refuse"
    );
}

#[tokio::test]
async fn an_authenticated_device_releases_its_unauthenticated_slot() {
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated: 1,
        max_unauthenticated_per_ip: 1,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;
    let dev = rig.mint_device("iPhone");
    let mut device = rig.device(&dev.token, &[], vec![]).await;
    device.sync().await;
    // The device is still connected, yet the only slot is free for a stranger.
    let mut admitted = false;
    for _ in 0..50 {
        if Conn::try_ws(rig.ws_port, None, "/").await.is_ok() {
            admitted = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(admitted, "the device kept its unauthenticated slot");
    device.sync().await;
}

#[tokio::test]
async fn the_per_address_cap_applies_before_the_global_one() {
    let limits = nostromo::ipc::ws::WsLimits {
        max_unauthenticated: 10,
        max_unauthenticated_per_ip: 2,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;
    let _a = Conn::try_ws(rig.ws_port, None, "/").await.unwrap();
    let _b = Conn::try_ws(rig.ws_port, None, "/").await.unwrap();
    assert!(Conn::try_ws(rig.ws_port, None, "/").await.is_err());
}

#[tokio::test]
async fn a_device_may_hold_only_so_many_sockets() {
    let limits = nostromo::ipc::ws::WsLimits {
        max_sockets_per_device: 2,
        ..Default::default()
    };
    let rig = Rig::with_limits(limits).await;
    let dev = rig.mint_device("iPhone");
    let mut one = rig.device(&dev.token, &[], vec![]).await;
    let mut two = rig.device(&dev.token, &[], vec![]).await;
    one.sync().await;
    two.sync().await;
    let mut three = rig.device_raw(&dev.token).await;
    assert_eq!(three.expect_close().await, Some(1008), "the third socket");
    // The first two are untouched.
    one.sync().await;
    two.sync().await;
}

#[tokio::test]
async fn an_upgrade_carrying_an_origin_header_is_refused_even_with_a_valid_token() {
    let rig = Rig::new().await;
    let dev = rig.mint_device("iPhone");
    for token in [None, Some(dev.token.as_str())] {
        match Conn::try_ws_with_header(rig.ws_port, token, ("Origin", "https://evil.example")).await
        {
            Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
                assert_eq!(resp.status().as_u16(), 403, "token: {token:?}");
            }
            Err(other) => panic!("expected HTTP 403, got {other:?}"),
            Ok(_) => panic!("a browser-origin upgrade was admitted (token: {token:?})"),
        }
    }
}

#[tokio::test]
async fn a_pairing_socket_refuses_a_message_over_a_few_kib() {
    let rig = Rig::new().await;
    let mut sock = rig.pairing_socket().await;
    sock.try_send_text("x".repeat(nostromo::ipc::ws::PAIRING_MAX_MESSAGE + 1))
        .await;
    assert_eq!(sock.expect_close().await, Some(1009));

    // A real pairing frame is nowhere near the cap.
    let mut sock = rig.pairing_socket().await;
    sock.send(&Conn::hello(&[], true)).await;
    sock.next_matching("the Welcome", |m| matches!(m, ServerMsg::Welcome { .. }))
        .await;
}
