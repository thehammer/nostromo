//! Device pairing, end to end (W9): the lifecycle of a pairing code and of the
//! credential it buys, driven the way the product drives it.
//!
//! An admin client (a local Unix connection: the CLI, or the Mac app) starts a
//! pairing and is told how it ends. A device (a token-less WebSocket) checks the
//! code and redeems it for a bearer token. A device with a token connects, is
//! revoked, removes itself, or is replaced when the same phone pairs again.
//!
//! Everything is hermetic: loopback sockets on port 0, a tempdir registry, and a
//! short code lifetime where expiry is the point. Nothing here reads the daemon's
//! tables; the registry file and the captured log are read only to prove what must
//! never be in them.

use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nostromo::device_cli;
use nostromo::ipc::devices::{
    DeviceKind, PairOutcomeKind, PairRefusedReason, RevokedBy, SatelliteAdmin, TokenCheck,
};
use nostromo::ipc::peer::is_refusal;
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic};
use nostromo::ipc::DaemonClient;
use serde_json::Value;

#[path = "support/ws_rig.rs"]
mod rig;
use rig::*;

// ── helpers ───────────────────────────────────────────────────────────────────

fn assert_refused(reply: &ServerMsg, expected: PairRefusedReason) {
    match reply {
        ServerMsg::PairRefused { reason } => assert_eq!(*reason, expected, "{reply:?}"),
        other => panic!("expected PairRefused({expected:?}), got {other:?}"),
    }
}

struct PairedReply {
    device_id: String,
    token: String,
    name: String,
    server_id: String,
    replaced: bool,
}

fn paired(reply: ServerMsg) -> PairedReply {
    match reply {
        ServerMsg::Paired {
            device_id,
            token,
            name,
            server_id,
            replaced,
        } => PairedReply {
            device_id,
            token: token.0,
            name,
            server_id,
            replaced,
        },
        other => panic!("expected Paired, got {other:?}"),
    }
}

fn outcome_kind(msg: &ServerMsg) -> PairOutcomeKind {
    match msg {
        ServerMsg::DevicePairOutcome { outcome, .. } => *outcome,
        other => panic!("expected an outcome, got {other:?}"),
    }
}

/// Poll a pairing socket with `PairCheck` until the code is refused (the daemon
/// notices a dropped connection asynchronously); the reason it was refused for.
async fn refused_eventually(rig: &Rig, code: &str) -> PairRefusedReason {
    let mut sock = rig.pairing_socket().await;
    let start = Instant::now();
    loop {
        if let ServerMsg::PairRefused { reason } = sock.pair_check(code, None).await {
            return reason;
        }
        assert!(
            start.elapsed() < READ_TIMEOUT,
            "the code {code} is still live"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// The text of every object key anywhere in `v`.
fn keys_of(v: &Value, out: &mut Vec<String>) {
    match v {
        Value::Object(map) => {
            for (k, v) in map {
                out.push(k.clone());
                keys_of(v, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|i| keys_of(i, out)),
        _ => {}
    }
}

fn registry_file(rig: &Rig) -> String {
    std::fs::read_to_string(&rig.registry_path).expect("the registry file")
}

#[test]
fn the_test_hmac_matches_rfc_4231_test_case_1() {
    // The proofs below are computed by this file's own HMAC: pin it to the standard.
    let mac = hmac_sha256(&[0x0b; 20], b"Hi There");
    let hex: String = mac.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        hex,
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    );
}

// ── (f) the whole flow ────────────────────────────────────────────────────────

#[tokio::test]
async fn a_device_checks_a_code_then_pairs_and_the_admin_hears_within_two_seconds() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(Some("Kitchen iPad")).await;

    assert_eq!(pairing.code.len(), 6);
    assert!(pairing.code.chars().all(|c| c.is_ascii_digit()));
    assert_eq!(
        pairing.server_url,
        format!(
            "nostromo://pair?v=1&host=127.0.0.1&port={}&code={}",
            rig.ws_port, pairing.code
        )
    );

    let mut sock = rig.pairing_socket().await;
    match sock.pair_check(&pairing.code, None).await {
        ServerMsg::PairOffer {
            name_hint,
            server_id,
            challenge,
            knows_device,
        } => {
            assert_eq!(name_hint.as_deref(), Some("Kitchen iPad"));
            assert_eq!(server_id, rig.registry.server_id());
            assert!(!challenge.is_empty());
            assert_eq!(knows_device, None, "no proof was sent");
        }
        other => panic!("expected an offer, got {other:?}"),
    }
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPad".into(),
        kind: DeviceKind::Iphone,
        replace: false,
    })
    .await;
    let reply = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    assert_eq!(reply.name, "iPad");
    assert!(!reply.replaced);
    assert_eq!(reply.server_id, rig.registry.server_id());
    assert!(reply.token.len() >= 32, "an unguessable token");

    let outcome = admin.outcome_of(&pairing, Duration::from_secs(2)).await;
    match outcome {
        ServerMsg::DevicePairOutcome {
            outcome,
            name,
            kind,
            replaced,
            ..
        } => {
            assert_eq!(outcome, PairOutcomeKind::Paired);
            assert_eq!(name.as_deref(), Some("iPad"));
            assert_eq!(kind, Some(DeviceKind::Iphone));
            assert!(!replaced);
        }
        _ => unreachable!(),
    }

    // The token is a working credential, and the code is spent.
    let mut device = rig.device(&reply.token, &[], vec![]).await;
    device.sync().await;
    let (devices, hosts) = admin.device_list().await;
    assert!(hosts.is_empty());
    let listed = named(&devices, "iPad");
    assert_eq!(listed.id, reply.device_id);
    assert!(listed.connected, "{listed:?}");
    assert_eq!(listed.kind, DeviceKind::Iphone);
    let (again, _) = rig
        .redeem(&pairing.code, "iPad", DeviceKind::Iphone, false)
        .await;
    assert_refused(&again, PairRefusedReason::Invalid);

    // The registry holds a hash of the token, never the token or the code.
    let file = registry_file(&rig);
    assert!(!file.contains(&reply.token), "{file}");
    assert!(file.contains(&token_hash(&reply.token)), "{file}");
    assert!(!contains_digit_run(&file, &pairing.code), "{file}");
}

#[tokio::test]
async fn the_mac_app_can_start_a_pairing_just_as_the_cli_can() {
    let rig = Rig::new().await;
    let mut app = rig.unix(vec![], true).await;
    let pairing = app.pair_start(None).await;
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    paired(reply);
    assert_eq!(
        outcome_kind(&app.outcome_of(&pairing, Duration::from_secs(2)).await),
        PairOutcomeKind::Paired
    );
}

// ── (g) names ─────────────────────────────────────────────────────────────────

#[tokio::test]
async fn a_second_device_under_the_same_name_is_numbered_and_a_revoked_name_is_free_again() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;

    let first = rig.pair_phone(&mut admin, "iPad").await;
    assert_eq!(first.name, "iPad");
    let pairing = admin.pair_start(None).await;
    let (reply, _) = rig
        .redeem(&pairing.code, "iPad", DeviceKind::Ipad, false)
        .await;
    assert_eq!(paired(reply).name, "iPad 2");
    match admin.outcome_of(&pairing, Duration::from_secs(2)).await {
        ServerMsg::DevicePairOutcome { name, .. } => {
            assert_eq!(
                name.as_deref(),
                Some("iPad 2"),
                "the outcome has the final name"
            )
        }
        _ => unreachable!(),
    }

    // Revoked names do not block reuse.
    assert!(matches!(
        admin.revoke("iPad").await,
        ServerMsg::DeviceRevoked { .. }
    ));
    let third = rig.pair_phone(&mut admin, "iPad").await;
    assert_eq!(third.name, "iPad");
}

#[tokio::test]
async fn a_device_name_with_control_characters_or_great_length_is_cleaned_before_it_is_stored() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let hostile = format!("Evil\u{1b}[31m phone\u{202e}{}", "x".repeat(200));
    let phone = rig.pair_phone(&mut admin, &hostile).await;

    assert!(
        !phone
            .name
            .chars()
            .any(|c| c.is_control() || c == '\u{202e}'),
        "{:?}",
        phone.name
    );
    assert!(phone.name.chars().count() <= 64, "{:?}", phone.name);
    assert!(phone.name.starts_with("Evil"), "{:?}", phone.name);
    let (devices, _) = admin.device_list().await;
    assert_eq!(
        devices[0].name, phone.name,
        "what is listed is what was stored"
    );
}

// ── (h) expiry ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn an_expired_code_tells_its_issuer_and_a_later_attempt_hears_expired() {
    let rig = Rig::with_ttl(Duration::from_millis(600)).await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;

    // Pushed to the issuer on time, not on the next attempt.
    let outcome = admin.outcome_of(&pairing, Duration::from_secs(5)).await;
    assert_eq!(outcome_kind(&outcome), PairOutcomeKind::Expired);

    let mut sock = rig.pairing_socket().await;
    assert_refused(
        &sock.pair_check(&pairing.code, None).await,
        PairRefusedReason::Expired,
    );
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Expired);
    assert!(
        rig.registry.summaries(|_| false).0.is_empty(),
        "an expired code bought nothing"
    );
}

// ── (i) cancel, and losing the admin connection ───────────────────────────────

#[tokio::test]
async fn a_cancelled_code_is_reported_to_its_issuer_and_afterwards_invalid() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;

    admin
        .send(&ClientMsg::DevicePairCancel {
            request_id: request_id(),
            pairing_id: pairing.pairing_id.clone(),
        })
        .await;
    let outcome = admin.outcome_of(&pairing, Duration::from_secs(2)).await;
    assert_eq!(outcome_kind(&outcome), PairOutcomeKind::Cancelled);

    let mut sock = rig.pairing_socket().await;
    assert_refused(
        &sock.pair_check(&pairing.code, None).await,
        PairRefusedReason::Invalid,
    );
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
}

#[tokio::test]
async fn a_pairing_does_not_outlive_the_connection_that_shows_its_code() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;
    // Live while its window (or command) is.
    let mut sock = rig.pairing_socket().await;
    assert!(matches!(
        sock.pair_check(&pairing.code, None).await,
        ServerMsg::PairOffer { .. }
    ));

    drop(admin);
    assert_eq!(
        refused_eventually(&rig, &pairing.code).await,
        PairRefusedReason::Invalid,
        "no tombstone: a lost issuer reads as an unknown code"
    );
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
}

// ── (j) lockout ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn five_wrong_codes_lock_the_pairing_out_and_the_right_code_is_then_invalid() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;
    let wrong = wrong_code(&pairing.code);

    let mut sock = rig.pairing_socket().await;
    for attempt in 1..=5 {
        assert_refused(
            &sock.pair_check(&wrong, None).await,
            PairRefusedReason::Invalid,
        );
        if attempt < 5 {
            admin.sync().await;
            assert!(
                !admin
                    .inbox
                    .iter()
                    .any(|m| matches!(m, ServerMsg::DevicePairOutcome { .. })),
                "the pairing survives {attempt} wrong attempts: {:?}",
                admin.inbox
            );
        }
    }
    let outcome = admin.outcome_of(&pairing, Duration::from_secs(2)).await;
    assert_eq!(outcome_kind(&outcome), PairOutcomeKind::LockedOut);

    assert_refused(
        &sock.pair_check(&pairing.code, None).await,
        PairRefusedReason::Invalid,
    );
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
}

#[tokio::test]
async fn a_wrong_code_counts_against_every_open_pairing_so_two_codes_lock_out_together() {
    let rig = Rig::new().await;
    let mut sendai = rig.unix(vec![], false).await;
    let mut terminal = rig.unix(vec![], false).await;
    let first = sendai.pair_start(None).await;
    let second = terminal.pair_start(None).await;
    // A guess that is neither code.
    let wrong = ["000000", "000001", "000002"]
        .into_iter()
        .find(|c| *c != first.code && *c != second.code)
        .unwrap();

    let mut sock = rig.pairing_socket().await;
    for _ in 0..5 {
        sock.pair_check(wrong, None).await;
    }
    assert_eq!(
        outcome_kind(&sendai.outcome_of(&first, Duration::from_secs(2)).await),
        PairOutcomeKind::LockedOut
    );
    assert_eq!(
        outcome_kind(&terminal.outcome_of(&second, Duration::from_secs(2)).await),
        PairOutcomeKind::LockedOut
    );
}

// ── (k) revoke ────────────────────────────────────────────────────────────────

#[tokio::test]
async fn revoking_a_connected_device_closes_it_with_4001_in_under_a_second_and_leaves_others_open()
{
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let alice = rig.pair_phone(&mut admin, "Alice iPhone").await;
    let bob = rig.pair_phone(&mut admin, "Bob iPad").await;
    let mut alice_ws = rig.device(&alice.token, &[], vec![]).await;
    let mut bob_ws = rig.device(&bob.token, &[], vec![]).await;

    let started = Instant::now();
    let reply = admin.revoke(&alice.name).await;
    match reply {
        ServerMsg::DeviceRevoked {
            device_id,
            was_connected,
            ..
        } => {
            assert_eq!(device_id, alice.device_id);
            assert!(was_connected, "she was connected");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(
        alice_ws.expect_close_within(Duration::from_secs(1)).await,
        Some(CLOSE_UNAUTHORIZED)
    );
    assert!(started.elapsed() < Duration::from_secs(1));
    assert!(
        alice_ws
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::Unauthorized { reason } if reason == "revoked")),
        "{:?}",
        alice_ws.inbox
    );

    // Bob is untouched, and Alice's token is dead on reconnect.
    bob_ws.sync().await;
    assert_eq!(bob_ws.closed, None);
    let mut retry = rig.device_raw(&alice.token).await;
    assert_eq!(retry.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    assert!(matches!(
        retry.take_all().as_slice(),
        [ServerMsg::Unauthorized { reason }] if reason == "revoked"
    ));
    let mut bob_again = rig.device(&bob.token, &[], vec![]).await;
    bob_again.sync().await;

    // A device that is not connected is revoked all the same, and says so.
    drop(bob_ws);
    drop(bob_again);
    let mut connected = true;
    for _ in 0..100 {
        let (devices, _) = admin.device_list().await;
        connected = named(&devices, &bob.name).connected;
        if !connected {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!connected, "the daemon noticed Bob's sockets close");
    assert!(matches!(
        admin.revoke(&bob.device_id).await,
        ServerMsg::DeviceRevoked {
            was_connected: false,
            ..
        }
    ));
    let (devices, _) = admin.device_list().await;
    for who in [&alice, &bob] {
        let d = named(&devices, &who.name);
        assert!(d.revoked_at.is_some(), "{d:?}");
        assert_eq!(d.revoked_by, Some(RevokedBy::Operator), "{d:?}");
    }

    match admin.revoke("nobody by this name").await {
        ServerMsg::DeviceAdminError { reason, .. } => assert_eq!(reason, "unknown_device"),
        other => panic!("{other:?}"),
    }
}

// ── (l) only the owner may cancel ─────────────────────────────────────────────

#[tokio::test]
async fn another_connection_cannot_cancel_a_pairing_and_it_stays_open() {
    let rig = Rig::new().await;
    let mut owner = rig.unix(vec![], false).await;
    let mut other = rig.unix(vec![], false).await;
    let pairing = owner.pair_start(None).await;

    let rid = request_id();
    other
        .send(&ClientMsg::DevicePairCancel {
            request_id: rid.clone(),
            pairing_id: pairing.pairing_id.clone(),
        })
        .await;
    let refused = other
        .next_matching("an admin error", |m| {
            matches!(m, ServerMsg::DeviceAdminError { .. })
        })
        .await;
    match refused {
        ServerMsg::DeviceAdminError { request_id, reason } => {
            assert_eq!(request_id, rid);
            assert_eq!(reason, "unknown_pairing");
        }
        _ => unreachable!(),
    }

    // Still open: it can be checked, redeemed, and its owner (not the intruder) hears.
    let mut sock = rig.pairing_socket().await;
    assert!(matches!(
        sock.pair_check(&pairing.code, None).await,
        ServerMsg::PairOffer { .. }
    ));
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    paired(reply);
    assert_eq!(
        outcome_kind(&owner.outcome_of(&pairing, Duration::from_secs(2)).await),
        PairOutcomeKind::Paired,
        "the owner was not told it was cancelled"
    );
    other.sync().await;
    assert!(
        !other
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::DevicePairOutcome { .. })),
        "{:?}",
        other.inbox
    );
}

// ── (m) a device removes itself ───────────────────────────────────────────────

#[tokio::test]
async fn a_device_that_unpairs_itself_is_told_closed_and_recorded_as_removed_by_the_device() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let phone = rig.pair_phone(&mut admin, "iPhone").await;
    let other = rig.pair_phone(&mut admin, "iPad").await;
    let mut ws = rig.device(&phone.token, &[], vec![]).await;
    let mut other_ws = rig.device(&other.token, &[], vec![]).await;

    ws.send(&ClientMsg::DeviceUnpairSelf).await;
    ws.next_matching("DeviceUnpaired", |m| matches!(m, ServerMsg::DeviceUnpaired))
        .await;
    assert_eq!(
        ws.expect_close_within(Duration::from_secs(1)).await,
        Some(CLOSE_UNAUTHORIZED)
    );

    let (devices, _) = admin.device_list().await;
    let removed = named(&devices, "iPhone");
    assert!(removed.revoked_at.is_some(), "{removed:?}");
    assert_eq!(removed.revoked_by, Some(RevokedBy::Device));
    assert!(named(&devices, "iPad").revoked_at.is_none());

    let mut retry = rig.device_raw(&phone.token).await;
    assert_eq!(retry.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    other_ws.sync().await;
    assert_eq!(other_ws.closed, None, "only its own record was removed");
}

// ── (n) a device cannot administer devices ────────────────────────────────────

#[tokio::test]
async fn the_device_admin_verbs_are_refused_on_a_device_socket_and_change_nothing() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let phone = rig.pair_phone(&mut admin, "iPhone").await;
    let victim = rig.pair_phone(&mut admin, "iPad").await;
    let mut ws = rig.device(&phone.token, &[], vec![]).await;
    let mut victim_ws = rig.device(&victim.token, &[], vec![]).await;

    let verbs = vec![
        (
            "device_pair_start",
            ClientMsg::DevicePairStart {
                request_id: "r1".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
            },
        ),
        (
            "device_pair_cancel",
            ClientMsg::DevicePairCancel {
                request_id: "r2".into(),
                pairing_id: "pair_nothing".into(),
            },
        ),
        (
            "device_list",
            ClientMsg::DeviceList {
                request_id: "r3".into(),
            },
        ),
        (
            "device_revoke",
            ClientMsg::DeviceRevoke {
                request_id: "r4".into(),
                device: victim.name.clone(),
            },
        ),
        (
            "device_set_admin",
            ClientMsg::DeviceSetAdmin {
                request_id: "r5".into(),
                host: "Tokyo".into(),
                admin: SatelliteAdmin::Full,
            },
        ),
        // The device side of pairing belongs to a token-less socket.
        (
            "pair_check",
            ClientMsg::PairCheck {
                code: "123456".into(),
                proof: None,
            },
        ),
        (
            "pair",
            ClientMsg::Pair {
                code: "123456".into(),
                name: "Copy".into(),
                kind: DeviceKind::Iphone,
                replace: false,
            },
        ),
    ];
    for (what, verb) in verbs {
        ws.send(&verb).await;
        let refusal = ws.next_matching(what, is_refusal).await;
        assert!(
            matches!(&refusal, ServerMsg::Error { message } if message.contains("requires_secure_connection")),
            "{what}: {refusal:?}"
        );
    }
    ws.sync().await;
    assert_eq!(ws.closed, None, "the refusals did not close the socket");
    assert!(
        !ws.inbox.iter().any(|m| matches!(
            m,
            ServerMsg::Devices { .. }
                | ServerMsg::DevicePairing { .. }
                | ServerMsg::DeviceRevoked { .. }
                | ServerMsg::DeviceAdminError { .. }
                | ServerMsg::PairOffer { .. }
                | ServerMsg::Paired { .. }
        )),
        "{:?}",
        ws.inbox
    );

    // The victim was not revoked, and no device was added.
    victim_ws.sync().await;
    assert_eq!(victim_ws.closed, None);
    assert_eq!(
        rig.registry.validate(&victim.token),
        TokenCheck::Active {
            id: victim.device_id.clone()
        }
    );
    let (devices, hosts) = admin.device_list().await;
    assert_eq!(devices.len(), 2, "{devices:?}");
    assert!(hosts.is_empty());
}

// ── the device list is live ───────────────────────────────────────────────────

#[tokio::test]
async fn the_device_list_is_broadcast_when_a_device_connects_and_when_it_goes() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![Topic::Devices], false).await;
    let phone = rig.mint_device("iPhone");

    let ws = rig.device(&phone.token, &[], vec![]).await;
    let shows = |connected: bool| {
        move |m: &ServerMsg| {
            matches!(m, ServerMsg::Devices { devices, .. }
                if devices.iter().any(|d| d.name == "iPhone" && d.connected == connected))
        }
    };
    admin.next_matching("iPhone connected", shows(true)).await;
    drop(ws);
    admin
        .next_matching("iPhone not connected", shows(false))
        .await;
}

// ── (o) a token is never logged ───────────────────────────────────────────────

#[tokio::test]
async fn a_device_token_never_appears_in_the_log_the_registry_or_any_admin_frame() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![Topic::Devices], false).await;
    let pairing = admin.pair_start(Some("Phone")).await;
    let mut sock = rig.pairing_socket().await;
    sock.pair_check(&pairing.code, None).await;
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "Phone".into(),
        kind: DeviceKind::Iphone,
        replace: false,
    })
    .await;
    let phone = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    admin.outcome_of(&pairing, Duration::from_secs(2)).await;

    // Use the token, then lose it: connect, revoke, and be refused with it.
    let mut ws = rig.device(&phone.token, &[], vec![]).await;
    ws.sync().await;
    admin.revoke(&phone.device_id).await;
    ws.expect_close().await;
    let mut refused = rig.device_raw(&phone.token).await;
    refused.expect_close().await;
    let mut stranger = rig.device_raw("a-bearer-token-nobody-issued-7731").await;
    stranger.expect_close().await;
    admin.sync().await;

    let logs = captured_logs();
    assert!(
        logs.contains("device paired"),
        "control: the daemon logged the pairing, and this test can read its log"
    );
    let secrets = [
        ("the token", phone.token.clone()),
        ("the token's hash", token_hash(&phone.token)),
        (
            "a rejected bearer token",
            "a-bearer-token-nobody-issued-7731".into(),
        ),
    ];
    for (what, secret) in &secrets {
        assert!(!logs.contains(secret.as_str()), "{what} is in the log");
        assert!(
            !registry_file(&rig).contains(secret.as_str()) || *what == "the token's hash",
            "{what} is in the registry"
        );
        for raw in &admin.raw {
            assert!(
                !raw.contains(secret.as_str()),
                "{what} is in an admin frame: {raw}"
            );
        }
    }
    assert!(
        !contains_digit_run(&logs, &pairing.code),
        "the pairing code is in the log"
    );
}

// ── D6: pairing again from a phone that is already paired ────────────────────

/// One phone, paired and connected, and an admin client that watches the list.
async fn paired_and_connected(rig: &Rig, name: &str) -> (Conn, Minted, Conn) {
    let mut admin = rig.unix(vec![Topic::Devices], false).await;
    let phone = rig.pair_phone(&mut admin, name).await;
    let ws = rig.device(&phone.token, &[], vec![]).await;
    (admin, phone, ws)
}

/// Open a code, learn its challenge on a fresh pairing socket.
async fn open_code(admin: &mut Conn, rig: &Rig) -> (Pairing, Conn, String) {
    let pairing = admin.pair_start(None).await;
    let mut sock = rig.pairing_socket().await;
    let challenge = sock.challenge_for(&pairing.code).await;
    (pairing, sock, challenge)
}

fn knows_device_of(reply: &ServerMsg) -> Option<bool> {
    match reply {
        ServerMsg::PairOffer { knows_device, .. } => *knows_device,
        other => panic!("expected an offer, got {other:?}"),
    }
}

#[tokio::test]
async fn the_same_phone_pairing_again_replaces_its_old_record_and_keeps_its_name() {
    let rig = Rig::new().await;
    let (mut admin, old, mut old_ws) = paired_and_connected(&rig, "iPhone").await;
    let (pairing, mut sock, challenge) = open_code(&mut admin, &rig).await;

    let proof = proof_for(&old.token, &challenge, &pairing.code);
    let checked = sock.pair_check(&pairing.code, Some(&proof)).await;
    assert_eq!(knows_device_of(&checked), Some(true));
    match &checked {
        ServerMsg::PairOffer {
            challenge: again, ..
        } => {
            assert_eq!(*again, challenge, "a code keeps its challenge")
        }
        _ => unreachable!(),
    }

    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPhone".into(),
        kind: DeviceKind::Iphone,
        replace: true,
    })
    .await;
    let new = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    assert_eq!(new.name, "iPhone", "the old name is free: no suffix");
    assert!(new.replaced);
    assert_ne!(new.device_id, old.device_id);

    // The old record's live socket is closed with 4001, promptly.
    assert_eq!(
        old_ws.expect_close_within(Duration::from_secs(1)).await,
        Some(CLOSE_UNAUTHORIZED)
    );
    // The issuer is told it replaced one.
    match admin.outcome_of(&pairing, Duration::from_secs(2)).await {
        ServerMsg::DevicePairOutcome {
            outcome,
            name,
            replaced,
            ..
        } => {
            assert_eq!(outcome, PairOutcomeKind::Paired);
            assert_eq!(name.as_deref(), Some("iPhone"));
            assert!(replaced);
        }
        _ => unreachable!(),
    }
    // A Devices broadcast shows both: the old one revoked as replaced.
    let both = admin
        .next_matching("a Devices frame with both records", |m| {
            matches!(m, ServerMsg::Devices { devices, .. }
                if devices.len() == 2
                    && devices.iter().any(|d| d.id == old.device_id && d.revoked_by == Some(RevokedBy::Replaced))
                    && devices.iter().any(|d| d.id == new.device_id && d.revoked_at.is_none()))
        })
        .await;
    drop(both);

    // The old credential is dead; the new one works.
    let mut old_retry = rig.device_raw(&old.token).await;
    assert_eq!(old_retry.expect_close().await, Some(CLOSE_UNAUTHORIZED));
    let mut fresh = rig.device(&new.token, &[], vec![]).await;
    fresh.sync().await;

    // What the phone sent was never its token or its hash, and the proof is not logged.
    let logs = captured_logs();
    assert!(!logs.contains(&proof), "the proof is in the log");
    assert!(!logs.contains(&old.token) && !logs.contains(&token_hash(&old.token)));
}

#[tokio::test]
async fn a_proof_from_a_credential_the_server_does_not_hold_replaces_nothing() {
    let rig = Rig::new().await;
    let (mut admin, old, mut old_ws) = paired_and_connected(&rig, "iPhone").await;

    // Unknown, revoked and satellite credentials all read the same: not known.
    let revoked = rig.pair_phone(&mut admin, "Lost phone").await;
    admin.revoke(&revoked.device_id).await;
    let satellite_pairing = admin
        .pair_start_as(None, Some("Tokyo"), Some(SatelliteAdmin::Full))
        .await;
    let (reply, _) = rig
        .redeem(
            &satellite_pairing.code,
            "ignored",
            DeviceKind::Satellite,
            false,
        )
        .await;
    let satellite = paired(reply);

    for (what, token) in [
        (
            "an unknown credential",
            "never-issued-by-this-server".to_string(),
        ),
        ("a revoked credential", revoked.token.clone()),
        ("a satellite credential", satellite.token.clone()),
    ] {
        let (pairing, mut sock, challenge) = open_code(&mut admin, &rig).await;
        let proof = proof_for(&token, &challenge, &pairing.code);
        let checked = sock.pair_check(&pairing.code, Some(&proof)).await;
        assert_eq!(knows_device_of(&checked), Some(false), "{what}");
        sock.send(&ClientMsg::Pair {
            code: pairing.code.clone(),
            name: "iPhone".into(),
            kind: DeviceKind::Iphone,
            replace: true,
        })
        .await;
        let reply = paired(
            sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
                .await,
        );
        assert!(!reply.replaced, "{what}");
        assert!(
            reply.name.starts_with("iPhone "),
            "{what}: a plain pairing is numbered: {}",
            reply.name
        );
    }
    // Nothing was revoked: the original phone is still on its socket.
    old_ws.sync().await;
    assert_eq!(old_ws.closed, None);
    assert_eq!(
        rig.registry.validate(&old.token),
        TokenCheck::Active {
            id: old.device_id.clone()
        }
    );
}

#[tokio::test]
async fn a_code_answers_one_proof_and_a_proof_made_for_another_code_fails() {
    let rig = Rig::new().await;
    let (mut admin, old, mut old_ws) = paired_and_connected(&rig, "iPhone").await;

    // At most one `knows_device` per code: the second proof, even the right one, is not answered.
    let (pairing, mut sock, challenge) = open_code(&mut admin, &rig).await;
    let wrong = proof_for("some-other-token", &challenge, &pairing.code);
    assert_eq!(
        knows_device_of(&sock.pair_check(&pairing.code, Some(&wrong)).await),
        Some(false)
    );
    let right = proof_for(&old.token, &challenge, &pairing.code);
    assert_eq!(
        knows_device_of(&sock.pair_check(&pairing.code, Some(&right)).await),
        None,
        "the oracle answers once per code"
    );
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPhone".into(),
        kind: DeviceKind::Iphone,
        replace: true,
    })
    .await;
    let reply = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    assert!(!reply.replaced, "the answered proof was the wrong one");

    // A challenge belongs to one code: a proof captured for one fails on another.
    let (first, mut first_sock, first_challenge) = open_code(&mut admin, &rig).await;
    let (second, mut second_sock, second_challenge) = open_code(&mut admin, &rig).await;
    assert_ne!(first_challenge, second_challenge, "a challenge per code");
    let captured = proof_for(&old.token, &first_challenge, &first.code);
    assert_eq!(
        knows_device_of(&second_sock.pair_check(&second.code, Some(&captured)).await),
        Some(false),
        "a proof replayed on another code"
    );
    drop(first_sock.pair_check(&first.code, None).await);

    old_ws.sync().await;
    assert_eq!(old_ws.closed, None, "nothing was replaced");
}

#[tokio::test]
async fn a_raw_token_or_a_token_hash_is_not_a_proof() {
    let rig = Rig::new().await;
    let (mut admin, old, _old_ws) = paired_and_connected(&rig, "iPhone").await;
    for (what, claimed) in [
        ("the raw token", old.token.clone()),
        ("the token's hash", token_hash(&old.token)),
    ] {
        let (pairing, mut sock, _challenge) = open_code(&mut admin, &rig).await;
        assert_eq!(
            knows_device_of(&sock.pair_check(&pairing.code, Some(&claimed)).await),
            Some(false),
            "{what} was accepted as a proof"
        );
    }
}

#[tokio::test]
async fn pairing_again_without_a_proof_or_without_asking_to_replace_leaves_the_old_phone_active() {
    let rig = Rig::new().await;
    let (mut admin, old, mut old_ws) = paired_and_connected(&rig, "iPhone").await;

    // The phone lost its token: no proof, replace asked for. A fresh pairing.
    let (pairing, mut sock, _challenge) = open_code(&mut admin, &rig).await;
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPhone".into(),
        kind: DeviceKind::Iphone,
        replace: true,
    })
    .await;
    let lost = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    assert_eq!(lost.name, "iPhone 2");
    assert!(!lost.replaced);

    // The proof matched but the phone did not ask to replace.
    let (pairing, mut sock, challenge) = open_code(&mut admin, &rig).await;
    let proof = proof_for(&old.token, &challenge, &pairing.code);
    assert_eq!(
        knows_device_of(&sock.pair_check(&pairing.code, Some(&proof)).await),
        Some(true)
    );
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPhone".into(),
        kind: DeviceKind::Iphone,
        replace: false,
    })
    .await;
    let kept = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    assert_eq!(kept.name, "iPhone 3");
    assert!(!kept.replaced);

    old_ws.sync().await;
    assert_eq!(
        old_ws.closed, None,
        "the old phone stays active until revoked"
    );
    let (devices, _) = admin.device_list().await;
    assert!(
        devices.iter().all(|d| d.revoked_at.is_none()),
        "{devices:?}"
    );
}

// ── (t) D4: checking a code first ─────────────────────────────────────────────

#[tokio::test]
async fn checking_a_code_any_number_of_times_uses_nothing_up() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;

    let mut sock = rig.pairing_socket().await;
    let first = sock.challenge_for(&pairing.code).await;
    let second = sock.challenge_for(&pairing.code).await;
    assert_eq!(first, second, "a code keeps one challenge");
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    paired(reply);
    assert_eq!(
        outcome_kind(&admin.outcome_of(&pairing, Duration::from_secs(2)).await),
        PairOutcomeKind::Paired
    );
}

#[tokio::test]
async fn four_wrong_checks_and_one_wrong_pair_lock_the_code_out() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;
    let wrong = wrong_code(&pairing.code);

    let mut sock = rig.pairing_socket().await;
    for _ in 0..4 {
        sock.pair_check(&wrong, None).await;
    }
    admin.sync().await;
    assert!(
        !admin
            .inbox
            .iter()
            .any(|m| matches!(m, ServerMsg::DevicePairOutcome { .. })),
        "four wrong checks do not lock it: {:?}",
        admin.inbox
    );
    let (reply, _) = rig
        .redeem(&wrong, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
    assert_eq!(
        outcome_kind(&admin.outcome_of(&pairing, Duration::from_secs(2)).await),
        PairOutcomeKind::LockedOut
    );
    assert_refused(
        &sock.pair_check(&pairing.code, None).await,
        PairRefusedReason::Invalid,
    );
}

#[tokio::test]
async fn a_code_checked_and_then_expired_is_refused_as_expired_at_pair() {
    let rig = Rig::with_ttl(Duration::from_millis(1500)).await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;
    let mut sock = rig.pairing_socket().await;
    assert!(matches!(
        sock.pair_check(&pairing.code, None).await,
        ServerMsg::PairOffer { .. }
    ));

    let outcome = admin.outcome_of(&pairing, Duration::from_secs(10)).await;
    assert_eq!(outcome_kind(&outcome), PairOutcomeKind::Expired);
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Expired);
}

#[tokio::test]
async fn a_code_checked_and_then_cancelled_is_refused_as_invalid_at_pair() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let pairing = admin.pair_start(None).await;
    let mut sock = rig.pairing_socket().await;
    assert!(matches!(
        sock.pair_check(&pairing.code, None).await,
        ServerMsg::PairOffer { .. }
    ));

    admin
        .send(&ClientMsg::DevicePairCancel {
            request_id: request_id(),
            pairing_id: pairing.pairing_id.clone(),
        })
        .await;
    assert_eq!(
        outcome_kind(&admin.outcome_of(&pairing, Duration::from_secs(2)).await),
        PairOutcomeKind::Cancelled
    );
    let (reply, _) = rig
        .redeem(&pairing.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
}

// ── satellite Macs (Q1) ───────────────────────────────────────────────────────

#[tokio::test]
async fn a_satellite_is_named_for_its_host_listed_apart_and_defaults_to_revoke_only() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;

    // Unset means revoke_only; an explicit level is kept.
    let tokyo = admin.pair_start_as(None, Some("Tokyo"), None).await;
    let (reply, _) = rig
        .redeem(
            &tokyo.code,
            "whatever the Mac calls itself",
            DeviceKind::Satellite,
            false,
        )
        .await;
    assert_eq!(paired(reply).name, "Tokyo", "named for its host");
    let kobe = admin
        .pair_start_as(None, Some("Kobe"), Some(SatelliteAdmin::ReadOnly))
        .await;
    let (reply, _) = rig
        .redeem(&kobe.code, "x", DeviceKind::Satellite, false)
        .await;
    paired(reply);

    let (devices, hosts) = admin.device_list().await;
    assert!(
        devices.is_empty(),
        "satellites are not in the phone list: {devices:?}"
    );
    assert_eq!(
        named(&hosts, "Tokyo").admin,
        Some(SatelliteAdmin::RevokeOnly)
    );
    assert_eq!(named(&hosts, "Kobe").admin, Some(SatelliteAdmin::ReadOnly));
    assert_eq!(named(&hosts, "Tokyo").kind, DeviceKind::Satellite);

    // The level is changed on the primary.
    admin
        .send(&ClientMsg::DeviceSetAdmin {
            request_id: request_id(),
            host: "Tokyo".into(),
            admin: SatelliteAdmin::Full,
        })
        .await;
    let updated = admin
        .next_matching("Devices", |m| matches!(m, ServerMsg::Devices { .. }))
        .await;
    match updated {
        ServerMsg::Devices { hosts, .. } => {
            assert_eq!(named(&hosts, "Tokyo").admin, Some(SatelliteAdmin::Full))
        }
        _ => unreachable!(),
    }
    // Only a satellite has a level.
    let phone = rig.pair_phone(&mut admin, "iPhone").await;
    for host in ["iPhone", "nobody", phone.device_id.as_str()] {
        let rid = request_id();
        admin
            .send(&ClientMsg::DeviceSetAdmin {
                request_id: rid.clone(),
                host: host.into(),
                admin: SatelliteAdmin::Off,
            })
            .await;
        let error = admin
            .next_matching("an admin error", |m| {
                matches!(m, ServerMsg::DeviceAdminError { request_id, .. } if *request_id == rid)
            })
            .await;
        assert!(
            matches!(error, ServerMsg::DeviceAdminError { reason, .. } if reason == "unknown_device"),
            "{host}"
        );
    }
}

#[tokio::test]
async fn a_phone_cannot_redeem_a_satellite_code_nor_a_satellite_a_phone_code() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let satellite_code = admin.pair_start_as(None, Some("Tokyo"), None).await;
    let (reply, _) = rig
        .redeem(&satellite_code.code, "iPhone", DeviceKind::Iphone, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);

    let phone_code = admin.pair_start(None).await;
    let (reply, _) = rig
        .redeem(&phone_code.code, "Tokyo", DeviceKind::Satellite, false)
        .await;
    assert_refused(&reply, PairRefusedReason::Invalid);
}

// ── (u) nothing about mail or scope is on the wire ────────────────────────────

#[tokio::test]
async fn no_pairing_or_device_frame_has_a_sensitive_mail_or_scope_field_and_each_round_trips() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![Topic::Devices], false).await;
    let pairing = admin.pair_start(Some("iPhone")).await;
    let mut sock = rig.pairing_socket().await;
    sock.pair_check(&pairing.code, None).await;
    sock.pair_check(&wrong_code(&pairing.code), None).await;
    sock.send(&ClientMsg::Pair {
        code: pairing.code.clone(),
        name: "iPhone".into(),
        kind: DeviceKind::Iphone,
        replace: false,
    })
    .await;
    let phone = paired(
        sock.next_matching("Paired", |m| matches!(m, ServerMsg::Paired { .. }))
            .await,
    );
    admin.outcome_of(&pairing, Duration::from_secs(2)).await;
    let mut ws = rig.device(&phone.token, &[], vec![]).await;
    ws.sync().await;
    admin.device_list().await;
    admin.revoke(&phone.device_id).await;
    admin.revoke("nobody").await;
    let mut revoked = rig.device_raw(&phone.token).await;
    revoked.expect_close().await;
    let mut early = rig.pairing_socket().await;
    early
        .send(&ClientMsg::Pair {
            code: "123456".into(),
            name: "x".into(),
            kind: DeviceKind::Iphone,
            replace: false,
        })
        .await;
    early.expect_close().await;

    let mut frames: Vec<&String> = Vec::new();
    for conn in [&admin, &sock, &ws, &revoked, &early] {
        frames.extend(conn.raw.iter());
    }
    assert!(!frames.is_empty());
    let mut seen_types = std::collections::BTreeSet::new();
    let device_types = [
        "device_pairing",
        "device_pair_outcome",
        "devices",
        "device_revoked",
        "device_admin_error",
        "device_unpaired",
        "pair_offer",
        "paired",
        "pair_refused",
        "unauthorized",
    ];
    for raw in frames {
        let value: Value = serde_json::from_str(raw).unwrap();
        if !device_types.contains(&value["type"].as_str().unwrap_or_default()) {
            continue;
        }
        let mut keys = Vec::new();
        keys_of(&value, &mut keys);
        for key in &keys {
            let k = key.to_lowercase();
            for banned in [
                "sensitive",
                "mail",
                "calendar",
                "todo",
                "scope",
                "token_hash",
            ] {
                assert!(!k.contains(banned), "a `{key}` field in {raw}");
            }
            // The token is in `paired` and nowhere else.
            if k == "token" {
                assert_eq!(value["type"], "paired", "{raw}");
            }
        }
        // Each frame decodes and encodes to what was sent.
        let typed: ServerMsg = serde_json::from_str(raw).unwrap();
        assert_eq!(serde_json::to_value(&typed).unwrap(), value, "{raw}");
        seen_types.insert(value["type"].as_str().unwrap().to_string());
    }
    for expected in [
        "device_pairing",
        "device_pair_outcome",
        "devices",
        "device_revoked",
        "device_admin_error",
        "pair_offer",
        "pair_refused",
        "paired",
        "unauthorized",
    ] {
        assert!(
            seen_types.contains(expected),
            "no {expected} frame: {seen_types:?}"
        );
    }

    // What a device may send has no field for a token, a hash or a scope.
    for (msg, allowed) in [
        (
            serde_json::to_value(ClientMsg::PairCheck {
                code: "123456".into(),
                proof: Some("p".into()),
            })
            .unwrap(),
            vec!["type", "code", "proof"],
        ),
        (
            serde_json::to_value(ClientMsg::Pair {
                code: "123456".into(),
                name: "n".into(),
                kind: DeviceKind::Iphone,
                replace: true,
            })
            .unwrap(),
            vec!["type", "code", "name", "kind", "replace"],
        ),
    ] {
        let mut keys = Vec::new();
        keys_of(&msg, &mut keys);
        keys.sort();
        let mut allowed: Vec<String> = allowed.into_iter().map(String::from).collect();
        allowed.sort();
        assert_eq!(keys, allowed);
    }
}

// ── `nostromo device ...`, end to end ─────────────────────────────────────────

/// A `Write` the test can read while the command is still running.
#[derive(Clone, Default)]
struct Shared(Arc<Mutex<Vec<u8>>>);

impl Write for Shared {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Shared {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

/// Start `device pair` as the CLI does, over the daemon's Unix socket. Returns
/// the running command, what it has printed, and the code it showed.
async fn run_device_pair(
    rig: &Rig,
    satellite: Option<(&str, SatelliteAdmin)>,
    cancel: tokio::sync::oneshot::Receiver<()>,
) -> (tokio::task::JoinHandle<i32>, Shared, String) {
    let client = DaemonClient::connect(&rig.socket_path)
        .await
        .expect("connect to the daemon");
    let out = Shared::default();
    let printed = out.clone();
    let (host, admin) = match satellite {
        Some((host, admin)) => (Some(host.to_string()), Some(admin)),
        None => (None, None),
    };
    let named = host.is_none().then(|| "Kitchen iPad".to_string());
    let command = tokio::spawn(async move {
        let mut out = out;
        device_cli::pair(&client, named, host, admin, None, &mut out, async {
            let _ = cancel.await;
        })
        .await
        .expect("device pair ran")
    });
    // The code, as the operator reads it: `Code:   123 456`.
    let start = Instant::now();
    let code = loop {
        let text = printed.text();
        if let Some(line) = text.lines().find(|l| l.starts_with("Code:")) {
            break line
                .trim_start_matches("Code:")
                .chars()
                .filter(|c| c.is_ascii_digit())
                .collect::<String>();
        }
        assert!(start.elapsed() < READ_TIMEOUT, "no code printed: {text:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    (command, printed, code)
}

fn without_mail_line(text: &str) -> String {
    text.replace(device_cli::MAIL_LINE, "")
}

#[tokio::test]
async fn device_pair_stays_running_until_the_device_pairs_then_prints_the_name_and_exits_zero() {
    let rig = Rig::new().await;
    let (_keep_cancel, cancel) = tokio::sync::oneshot::channel();
    let (command, printed, code) = run_device_pair(&rig, None, cancel).await;
    assert_eq!(code.len(), 6);

    // It has printed the server, the code, a QR and Ada's one line about mail.
    let shown = printed.text();
    assert!(
        shown.contains(&format!("Server: 127.0.0.1:{}", rig.ws_port)),
        "{shown}"
    );
    assert!(
        shown.contains('█') || shown.contains('▀') || shown.contains('▄'),
        "a QR code"
    );
    assert_eq!(
        shown.matches(device_cli::MAIL_LINE).count(),
        1,
        "Ada's line, once: {shown}"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!command.is_finished(), "it stays running until the outcome");

    let (reply, _) = rig.redeem(&code, "iPad", DeviceKind::Iphone, false).await;
    let device = paired(reply);
    let exit = tokio::time::timeout(Duration::from_secs(5), command)
        .await
        .expect("it exits once the device pairs")
        .unwrap();
    assert_eq!(exit, device_cli::EXIT_OK);

    let text = printed.text();
    assert!(text.contains("Paired: iPad."), "{text}");
    for banned in ["mail", "calendar", "todo"] {
        assert!(
            !without_mail_line(&text).to_lowercase().contains(banned),
            "mail wording other than Ada's line ({banned}): {text}"
        );
    }
    assert!(!text.contains(&device.token) && !text.contains(&token_hash(&device.token)));
}

#[tokio::test]
async fn device_pair_exits_one_when_the_code_locks_out_or_expires_and_130_when_interrupted() {
    // Locked out.
    let rig = Rig::new().await;
    let (_keep, cancel) = tokio::sync::oneshot::channel();
    let (command, printed, code) = run_device_pair(&rig, None, cancel).await;
    let mut sock = rig.pairing_socket().await;
    for _ in 0..5 {
        sock.pair_check(&wrong_code(&code), None).await;
    }
    let exit = tokio::time::timeout(Duration::from_secs(5), command)
        .await
        .expect("it exits when locked out")
        .unwrap();
    assert_eq!(exit, device_cli::EXIT_FAILED);
    assert!(
        printed.text().contains(device_cli::LOCKED_OUT_LINE),
        "{}",
        printed.text()
    );

    // Interrupted: the code stops working.
    let rig = Rig::new().await;
    let (stop, cancel) = tokio::sync::oneshot::channel();
    let (command, printed, code) = run_device_pair(&rig, None, cancel).await;
    stop.send(()).unwrap();
    let exit = tokio::time::timeout(Duration::from_secs(5), command)
        .await
        .expect("it exits when interrupted")
        .unwrap();
    assert_eq!(exit, device_cli::EXIT_CANCELLED);
    assert!(
        printed.text().contains(device_cli::CANCELLED_LINE),
        "{}",
        printed.text()
    );
    assert_eq!(
        refused_eventually(&rig, &code).await,
        PairRefusedReason::Invalid,
        "Ctrl-C invalidates the code"
    );

    // Expired.
    let rig = Rig::with_ttl(Duration::from_millis(800)).await;
    let (_keep, cancel) = tokio::sync::oneshot::channel();
    let (command, printed, _code) = run_device_pair(&rig, None, cancel).await;
    let exit = tokio::time::timeout(Duration::from_secs(10), command)
        .await
        .expect("it exits when the code expires")
        .unwrap();
    assert_eq!(exit, device_cli::EXIT_FAILED);
    assert!(
        printed.text().contains(device_cli::EXPIRED_LINE),
        "{}",
        printed.text()
    );
}

#[tokio::test]
async fn device_pair_for_a_satellite_prints_no_mail_line_and_the_host_is_listed_with_its_level() {
    let rig = Rig::new().await;
    let (_keep, cancel) = tokio::sync::oneshot::channel();
    let (command, printed, code) =
        run_device_pair(&rig, Some(("Tokyo", SatelliteAdmin::Full)), cancel).await;
    let (reply, _) = rig
        .redeem(&code, "ignored", DeviceKind::Satellite, false)
        .await;
    paired(reply);
    let exit = tokio::time::timeout(Duration::from_secs(5), command)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(exit, device_cli::EXIT_OK);
    let text = printed.text();
    assert!(text.contains("Paired: Tokyo."), "{text}");
    assert!(!text.contains(device_cli::MAIL_LINE), "{text}");

    let client = DaemonClient::connect(&rig.socket_path).await.unwrap();
    let mut listed = Shared::default();
    device_cli::list(&client, true, &mut listed).await.unwrap();
    let listed = listed.text();
    assert!(listed.contains("Tokyo"), "{listed}");
    assert!(listed.contains("full"), "the admin level: {listed}");
}

#[tokio::test]
async fn device_list_and_device_revoke_print_what_happened_and_never_a_token() {
    let rig = Rig::new().await;
    let mut admin = rig.unix(vec![], false).await;
    let phone = rig.pair_phone(&mut admin, "iPhone").await;
    let mut ws = rig.device(&phone.token, &[], vec![]).await;
    ws.sync().await;
    let client = DaemonClient::connect(&rig.socket_path).await.unwrap();

    let mut out = Shared::default();
    assert_eq!(
        device_cli::list(&client, false, &mut out).await.unwrap(),
        device_cli::EXIT_OK
    );
    let listed = out.text();
    assert!(
        listed.contains("iPhone") && listed.contains("Connected now"),
        "{listed}"
    );

    let mut out = Shared::default();
    assert_eq!(
        device_cli::revoke(&client, "iPhone", &mut out)
            .await
            .unwrap(),
        device_cli::EXIT_OK
    );
    assert!(
        out.text()
            .contains("Revoked iPhone. Disconnected just now."),
        "{}",
        out.text()
    );
    assert_eq!(
        ws.expect_close_within(Duration::from_secs(1)).await,
        Some(CLOSE_UNAUTHORIZED)
    );

    let mut out = Shared::default();
    device_cli::list(&client, false, &mut out).await.unwrap();
    let listed = out.text();
    assert!(listed.contains("Revoked"), "{listed}");
    for text in [listed, out.text()] {
        assert!(!text.contains(&phone.token) && !text.contains(&token_hash(&phone.token)));
    }

    // An unknown device is an error the operator can read, not a success.
    let mut out = Shared::default();
    let err = device_cli::revoke(&client, "nobody", &mut out)
        .await
        .expect_err("revoking nobody fails");
    assert!(format!("{err:#}").contains("No such device"), "{err:#}");
}
