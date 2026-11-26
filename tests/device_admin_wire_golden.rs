//! The golden frames of device administration, in both directions (daemon <-> the Mac app).
//!
//! `tests/fixtures/device-admin/*.json` is the exact bytes serde produces for the messages built below:
//! the `client-*` files are what the Mac app must SEND (`ClientMsg`), the `frame-*` files what it must
//! DECODE (`ServerMsg`). The Swift tests read the same files (`DeviceWireFixtureTests`), so they are never
//! edited by hand: after an intended change to the wire shape, regenerate them with
//!
//!   UPDATE_GOLDEN=1 cargo test --test device_admin_wire_golden
//!
//! and review the diff (the Swift side must still send and decode them).
//!
//! `operator_presence` has no fixture: the daemon has no such verb yet (W13 adds it and its fixture).

use std::path::PathBuf;

use chrono::{DateTime, TimeZone, Utc};
use nostromo::ipc::devices::{
    DeviceKind, DeviceSummary, Egress, PairOutcomeKind, RevokedBy, SatelliteAdmin,
};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg};

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/device-admin")
}

fn at(day: u32, h: u32, m: u32) -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 11, day, h, m, 0).unwrap()
}

fn summary(id: &str, name: &str, kind: DeviceKind) -> DeviceSummary {
    DeviceSummary {
        id: id.into(),
        name: name.into(),
        kind,
        paired_at: at(20, 10, 0),
        last_seen_at: None,
        connected: false,
        revoked_at: None,
        revoked_by: None,
        admin: None,
        egress: None,
    }
}

fn error(request_id: &str, reason: &str) -> ServerMsg {
    ServerMsg::DeviceAdminError {
        request_id: request_id.into(),
        reason: reason.into(),
    }
}

fn outcome(kind: PairOutcomeKind) -> ServerMsg {
    ServerMsg::DevicePairOutcome {
        pairing_id: "p1".into(),
        outcome: kind,
        name: None,
        kind: None,
        replaced: false,
    }
}

/// What the Mac app sends, by file name.
fn client_fixtures() -> Vec<(&'static str, ClientMsg)> {
    vec![
        (
            "client-device-pair-start.json",
            ClientMsg::DevicePairStart {
                request_id: "r1".into(),
                name_hint: None,
                satellite: None,
                admin: None,
                egress: None,
                origin: None,
            },
        ),
        (
            "client-device-pair-cancel.json",
            ClientMsg::DevicePairCancel {
                request_id: "r2".into(),
                pairing_id: "p1".into(),
                origin: None,
            },
        ),
        (
            "client-device-list.json",
            ClientMsg::DeviceList {
                request_id: "r3".into(),
            },
        ),
        (
            "client-device-revoke.json",
            ClientMsg::DeviceRevoke {
                request_id: "r4".into(),
                device: "dev_1".into(),
            },
        ),
    ]
}

/// What the Mac app decodes, by file name.
fn server_fixtures() -> Vec<(&'static str, ServerMsg)> {
    let mut connected = summary("dev_1", "Ada's iPad", DeviceKind::Ipad);
    connected.last_seen_at = Some(at(25, 9, 30));
    connected.connected = true;
    let never = summary("dev_2", "Ada's iPhone", DeviceKind::Iphone);
    let mut revoked = summary("dev_3", "Old iPhone", DeviceKind::Iphone);
    revoked.last_seen_at = Some(at(21, 8, 0));
    revoked.revoked_at = Some(at(22, 8, 0));
    revoked.revoked_by = Some(RevokedBy::Operator);
    let mut replaced = summary("dev_4", "Ada's iPhone", DeviceKind::Iphone);
    replaced.revoked_at = Some(at(23, 8, 0));
    replaced.revoked_by = Some(RevokedBy::Replaced);
    let mut satellite = summary("host_1", "sendai", DeviceKind::Satellite);
    satellite.connected = true;
    satellite.admin = Some(SatelliteAdmin::RevokeOnly);
    satellite.egress = Some(Egress::Work);

    let paired = ServerMsg::DevicePairOutcome {
        pairing_id: "p1".into(),
        outcome: PairOutcomeKind::Paired,
        name: Some("Ada's iPhone".into()),
        kind: Some(DeviceKind::Iphone),
        replaced: true,
    };

    vec![
        (
            "frame-device-pairing.json",
            ServerMsg::DevicePairing {
                request_id: "r1".into(),
                pairing_id: "p1".into(),
                code: "123456".into(),
                server_url: "nostromo://pair?v=1&host=kobe&port=7777&code=123456".into(),
                expires_at: at(25, 12, 5),
            },
        ),
        ("frame-device-pair-outcome-paired.json", paired),
        (
            "frame-device-pair-outcome-expired.json",
            outcome(PairOutcomeKind::Expired),
        ),
        (
            "frame-device-pair-outcome-cancelled.json",
            outcome(PairOutcomeKind::Cancelled),
        ),
        (
            "frame-device-pair-outcome-locked-out.json",
            outcome(PairOutcomeKind::LockedOut),
        ),
        (
            "frame-device-pair-outcome-connection-lost.json",
            outcome(PairOutcomeKind::ConnectionLost),
        ),
        (
            "frame-device-pair-outcome-failed.json",
            outcome(PairOutcomeKind::Failed),
        ),
        (
            "frame-devices.json",
            ServerMsg::Devices {
                devices: vec![connected, never, revoked, replaced],
                hosts: vec![satellite],
            },
        ),
        (
            "frame-device-revoked.json",
            ServerMsg::DeviceRevoked {
                request_id: "r4".into(),
                device_id: "dev_1".into(),
                was_connected: true,
            },
        ),
        (
            "frame-device-admin-error-server-unreachable.json",
            error("r1", "server_unreachable"),
        ),
        (
            "frame-device-admin-error-not-permitted.json",
            error("r1", "not_permitted_on_this_mac"),
        ),
        (
            "frame-device-admin-error-too-many-pairings.json",
            error("r1", "too_many_pairings"),
        ),
        (
            "frame-device-admin-error-devices-unavailable.json",
            error("r1", "devices_unavailable"),
        ),
        (
            "frame-device-admin-error-unknown-device.json",
            error("r4", "unknown_device"),
        ),
        (
            "frame-device-admin-level-full.json",
            ServerMsg::DeviceAdminLevel {
                level: SatelliteAdmin::Full,
                pair_from: vec![],
            },
        ),
        (
            "frame-device-admin-level-revoke-only.json",
            ServerMsg::DeviceAdminLevel {
                level: SatelliteAdmin::RevokeOnly,
                pair_from: vec!["sendai".into()],
            },
        ),
        (
            "frame-device-admin-level-read-only.json",
            ServerMsg::DeviceAdminLevel {
                level: SatelliteAdmin::ReadOnly,
                pair_from: vec![],
            },
        ),
        (
            "frame-device-admin-level-off.json",
            ServerMsg::DeviceAdminLevel {
                level: SatelliteAdmin::Off,
                pair_from: vec![],
            },
        ),
    ]
}

/// Pretty JSON with a trailing newline: the committed form.
fn rendered<T: serde::Serialize>(msg: &T) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

fn updating() -> bool {
    std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1")
}

fn read(name: &str) -> String {
    std::fs::read_to_string(dir().join(name)).unwrap_or_else(|e| {
        panic!("{name} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test device_admin_wire_golden")
    })
}

fn check<T: serde::Serialize>(name: &str, msg: &T) {
    let want = rendered(msg);
    if updating() {
        std::fs::create_dir_all(dir()).unwrap();
        std::fs::write(dir().join(name), &want).unwrap_or_else(|e| panic!("write {name}: {e}"));
        return;
    }
    let have = read(name);
    assert!(
        have == want,
        "{name} no longer matches what the daemon serialises. If the wire change is intended, \
         regenerate with UPDATE_GOLDEN=1 cargo test --test device_admin_wire_golden and check the \
         Swift fixture tests still pass.\n--- committed:\n{have}\n--- produced:\n{want}"
    );
}

#[test]
fn every_client_verb_matches_its_committed_golden_file_byte_for_byte() {
    for (name, msg) in client_fixtures() {
        check(name, &msg);
    }
}

#[test]
fn every_daemon_frame_matches_its_committed_golden_file_byte_for_byte() {
    for (name, msg) in server_fixtures() {
        check(name, &msg);
    }
}

#[test]
fn the_golden_client_verbs_decode_as_the_daemons_own_messages_and_reencode_identically() {
    for (name, _) in client_fixtures() {
        let text = read(name);
        let msg: ClientMsg = serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("{name} must decode as a ClientMsg: {e}"));
        assert_eq!(rendered(&msg), text, "{name}: decode then encode");
    }
}

#[test]
fn the_golden_daemon_frames_decode_back_and_reencode_identically() {
    for (name, _) in server_fixtures() {
        let text = read(name);
        let msg: ServerMsg = serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("{name} must decode as a ServerMsg: {e}"));
        assert_eq!(rendered(&msg), text, "{name}: decode then encode");
    }
}

#[test]
fn no_golden_file_carries_a_credential() {
    for (name, _) in client_fixtures()
        .into_iter()
        .map(|(n, _)| (n, ()))
        .chain(server_fixtures().into_iter().map(|(n, _)| (n, ())))
    {
        let text = read(name).to_lowercase();
        assert!(
            !text.contains("token") && !text.contains("secret"),
            "{name} mentions a credential"
        );
    }
}

#[test]
fn the_fixture_directory_holds_exactly_the_files_built_here() {
    let mut want: Vec<String> = client_fixtures()
        .into_iter()
        .map(|(n, _)| n.to_string())
        .chain(server_fixtures().into_iter().map(|(n, _)| n.to_string()))
        .collect();
    want.sort();
    let mut have: Vec<String> = std::fs::read_dir(dir())
        .expect("fixture directory")
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    have.sort();
    assert_eq!(have, want, "a stale or unlisted fixture");
}
