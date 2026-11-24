//! W10 trust and classification: what a satellite's uplink may send and
//! receive, and the wire shape of the additive satellite fields.
//!
//! * a `PeerTrust::Satellite` is a publisher: it receives device
//!   administration at `read_only` and above, its own level and refusals at
//!   every level, and nothing else;
//! * it may send only its handshake, topic selection, `Ping` and the device
//!   administration verbs;
//! * every addition to the wire is additive: a frame without the new fields
//!   serialises exactly as before and decodes from the old JSON.

#![recursion_limit = "512"]

use nostromo::ipc::devices::{Egress, SatelliteAdmin};
use nostromo::ipc::peer::{
    classify_server_msg, is_sensitive_server_msg, may_receive, outbound, satellite_allowed,
    PeerTrust, SensitiveClass, SensitiveTags, ServerClass, Transport,
};
use nostromo::ipc::protocol::{ClientMsg, HelloRole, HostUnavailableReason, ServerMsg};
use serde_json::{json, Value};

const LEVELS: [SatelliteAdmin; 4] = [
    SatelliteAdmin::Full,
    SatelliteAdmin::RevokeOnly,
    SatelliteAdmin::ReadOnly,
    SatelliteAdmin::Off,
];

fn server(v: Value) -> ServerMsg {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("decode {v}: {e}"))
}

fn client(v: Value) -> ClientMsg {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("decode {v}: {e}"))
}

fn admin_frames() -> Vec<(&'static str, ServerMsg)> {
    let device = json!({"id": "d", "name": "n", "kind": "satellite", "paired_at": "2026-10-18T11:00:00Z"});
    vec![
        ("device_pairing", server(json!({"type": "device_pairing", "request_id": "r", "pairing_id": "p",
            "code": "123456", "server_url": "ws://x", "expires_at": "2026-10-18T11:00:00Z"}))),
        ("device_pair_outcome", server(json!({"type": "device_pair_outcome", "pairing_id": "p", "outcome": "paired"}))),
        ("devices", server(json!({"type": "devices", "devices": [device.clone()], "hosts": [device]}))),
        ("device_revoked", server(json!({"type": "device_revoked", "request_id": "r", "device_id": "d", "was_connected": false}))),
    ]
}

fn control_frames() -> Vec<(&'static str, ServerMsg)> {
    vec![
        ("device_admin_level", server(json!({"type": "device_admin_level", "level": "revoke_only", "pair_from": ["kobe"]}))),
        ("device_admin_error", server(json!({"type": "device_admin_error", "request_id": "r", "reason": "not_permitted"}))),
    ]
}

fn everything_else() -> Vec<(&'static str, ServerMsg)> {
    vec![
        ("mother_jobs", server(json!({"type": "mother_jobs", "jobs": []}))),
        ("mother_statusline", server(json!({"type": "mother_statusline", "running": 0, "queued": 0, "failed": 0, "awaiting": 0}))),
        ("focus_list_resp", server(json!({"type": "focus_list_resp", "focuses": []}))),
        ("session_list_resp", server(json!({"type": "session_list_resp", "sessions": []}))),
        ("pong", server(json!({"type": "pong"}))),
        ("welcome", server(json!({"type": "welcome", "protocol_version": 4, "daemon_pid": 1}))),
        ("error", server(json!({"type": "error", "message": "boom"}))),
        ("activity_health", server(json!({"type": "activity_health", "ingesting": true, "hook_installed": true}))),
        ("withheld", server(json!({"type": "withheld", "topics": ["fred"], "reason": "not_shared"}))),
        ("session_turn_delta", server(json!({"type": "session_turn_delta", "tag": "t",
            "delta": {"delta": "block_appended", "turn_id": "1", "block": {"kind": "text", "text": "hi"}}}))),
        ("teri_state", ServerMsg::TeriState { todos: Default::default() }),
        ("hosts", server(json!({"type": "hosts", "hosts": []}))),
        ("host_unavailable", server(json!({"type": "host_unavailable", "host": "kobe", "reason": "busy"}))),
    ]
}

// ── what a satellite receives ────────────────────────────────────────────────

#[test]
fn device_admin_frames_reach_a_satellite_unless_it_is_off() {
    let tags = SensitiveTags::in_memory();
    for (name, msg) in admin_frames() {
        assert_eq!(classify_server_msg(&msg), ServerClass::Admin, "{name}");
        for admin in LEVELS {
            let expect = admin != SatelliteAdmin::Off;
            let trust = PeerTrust::Satellite { admin };
            assert_eq!(may_receive(trust, &msg, &tags), expect, "{name} may_receive at {admin:?}");
            assert_eq!(outbound(trust, msg.clone(), &tags).is_some(), expect, "{name} outbound at {admin:?}");
        }
    }
}

#[test]
fn device_admin_frames_never_reach_a_paired_or_tcp_peer_and_always_reach_local_peers() {
    let tags = SensitiveTags::in_memory();
    for (name, msg) in admin_frames().into_iter().chain(control_frames()) {
        for trust in [PeerTrust::Paired, PeerTrust::Tcp] {
            assert!(!may_receive(trust, &msg, &tags), "{name} to {trust:?}");
            assert!(outbound(trust, msg.clone(), &tags).is_none(), "{name} to {trust:?}");
        }
        for trust in [PeerTrust::LocalOther, PeerTrust::OperatorApp] {
            assert!(may_receive(trust, &msg, &tags), "{name} to {trust:?}");
            assert!(outbound(trust, msg.clone(), &tags).is_some(), "{name} to {trust:?}");
        }
    }
}

#[test]
fn a_satellite_always_learns_its_own_level_and_refusals_even_when_off() {
    let tags = SensitiveTags::in_memory();
    for (name, msg) in control_frames() {
        assert_eq!(classify_server_msg(&msg), ServerClass::SatelliteControl, "{name}");
        for admin in LEVELS {
            let trust = PeerTrust::Satellite { admin };
            assert!(may_receive(trust, &msg, &tags), "{name} at {admin:?}");
            assert!(outbound(trust, msg.clone(), &tags).is_some(), "{name} at {admin:?}");
        }
    }
}

#[test]
fn a_satellite_receives_nothing_else() {
    let tags = SensitiveTags::in_memory();
    for (name, msg) in everything_else() {
        for admin in LEVELS {
            let trust = PeerTrust::Satellite { admin };
            assert!(!may_receive(trust, &msg, &tags), "{name} at {admin:?} must be withheld");
            assert!(outbound(trust, msg.clone(), &tags).is_none(), "{name} at {admin:?} must be withheld");
        }
    }
}

#[test]
fn hosts_and_host_unavailable_are_open_and_the_control_frames_are_not_sensitive() {
    for name in ["hosts", "host_unavailable"] {
        let (_, msg) = everything_else().into_iter().find(|(n, _)| *n == name).unwrap();
        assert_eq!(classify_server_msg(&msg), ServerClass::Open, "{name}");
        assert_eq!(is_sensitive_server_msg(&msg), SensitiveClass::NotSensitive, "{name}");
    }
    for (name, msg) in control_frames().into_iter().chain(admin_frames()) {
        assert_eq!(is_sensitive_server_msg(&msg), SensitiveClass::NotSensitive, "{name}");
    }
}

// ── what a satellite may send ────────────────────────────────────────────────

#[test]
fn a_satellite_may_send_its_handshake_topics_ping_and_device_administration() {
    let allowed = [
        json!({"type": "hello", "client_id": "c", "protocol_version": 4}),
        json!({"type": "subscribe", "topics": ["devices"]}),
        json!({"type": "ping"}),
        json!({"type": "device_list", "request_id": "r"}),
        json!({"type": "device_revoke", "request_id": "r", "device": "d"}),
        json!({"type": "device_pair_start", "request_id": "r"}),
        json!({"type": "device_pair_cancel", "request_id": "r", "pairing_id": "p"}),
        json!({"type": "device_set_admin", "request_id": "r", "host": "kobe", "admin": "off"}),
    ];
    for v in allowed {
        let name = v["type"].as_str().unwrap().to_string();
        assert!(satellite_allowed(&client(v)), "{name}");
    }
}

#[test]
fn a_satellite_may_not_read_or_drive_anything_else() {
    let refused = [
        json!({"type": "session_attach", "tag": "t"}),
        json!({"type": "session_detach", "tag": "t"}),
        json!({"type": "activity_snapshot_request", "tag": "t"}),
        json!({"type": "session_model_get", "tag": "t"}),
        json!({"type": "session_list"}),
        json!({"type": "focus_list"}),
        json!({"type": "device_unpair_self"}),
        json!({"type": "mother_resume", "job_id": "j", "answer": "a"}),
        json!({"type": "decision_answer", "request_id": "r", "choice_id": "c"}),
        json!({"type": "session_send", "tag": "t", "text": "hi"}),
        json!({"type": "session_spawn", "tag": "t", "agent_name": "cody", "view_name": "v",
            "remote_control": false, "no_codebase": false}),
        json!({"type": "model_catalog_request"}),
    ];
    for v in refused {
        let name = v["type"].as_str().unwrap().to_string();
        assert!(!satellite_allowed(&client(v)), "{name}");
    }
}

// ── trust ────────────────────────────────────────────────────────────────────

#[test]
fn a_satellite_is_a_network_peer() {
    for admin in LEVELS {
        assert!(PeerTrust::Satellite { admin }.is_network(), "{admin:?}");
    }
}

#[test]
fn no_transport_alone_grants_satellite_trust() {
    for t in [Transport::Unix, Transport::Tcp, Transport::Ws] {
        assert!(
            !matches!(PeerTrust::from_transport(t), PeerTrust::Satellite { .. }),
            "{t:?}: satellite trust needs a satellite token and a matching Hello"
        );
    }
}

// ── wire: the additions are additive ─────────────────────────────────────────

#[test]
fn a_hello_without_a_role_serialises_exactly_as_it_did_before() {
    let hello = ClientMsg::Hello {
        client_id: "c".into(),
        protocol_version: 4,
        client_kind: None,
        capabilities: vec![],
        role: None,
    };
    assert_eq!(
        serde_json::to_string(&hello).unwrap(),
        r#"{"type":"hello","client_id":"c","protocol_version":4}"#
    );
}

#[test]
fn an_old_hello_decodes_with_no_role() {
    let m = client(json!({"type": "hello", "client_id": "c", "protocol_version": 4}));
    match m {
        ClientMsg::Hello { role, .. } => assert!(role.is_none()),
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_satellite_role_is_tagged_by_kind_and_round_trips() {
    let hello = ClientMsg::Hello {
        client_id: "c".into(),
        protocol_version: 4,
        client_kind: None,
        capabilities: vec![],
        role: Some(HelloRole::Satellite { host: "kobe".into(), egress: Egress::Work }),
    };
    let v = serde_json::to_value(&hello).unwrap();
    assert_eq!(v["role"], json!({"kind": "satellite", "host": "kobe", "egress": "work"}));
    match serde_json::from_value::<ClientMsg>(v).unwrap() {
        ClientMsg::Hello { role: Some(HelloRole::Satellite { host, egress }), .. } => {
            assert_eq!(host, "kobe");
            assert_eq!(egress, Egress::Work);
        }
        other => panic!("{other:?}"),
    }
    let personal = serde_json::to_value(HelloRole::Satellite { host: "h".into(), egress: Egress::Personal }).unwrap();
    assert_eq!(personal["egress"], "personal");
    assert_eq!(serde_json::to_value(HelloRole::Client).unwrap(), json!({"kind": "client"}));
}

fn host_free_frames() -> Vec<(&'static str, Value)> {
    vec![
        ("mother_jobs", json!({"type": "mother_jobs", "jobs": []})),
        ("approval_pending", json!({"type": "approval_pending", "tag": "t", "count": 1})),
        ("mother_statusline", json!({"type": "mother_statusline", "running": 1, "queued": 0, "failed": 0, "awaiting": 0})),
        ("activity", json!({"type": "activity", "ts": "2026-10-18T11:00:00Z", "agent": "cody", "kind": "tool", "summary": "s"})),
        ("perri_state", json!({"type": "perri_state", "tag": "t", "queue": [], "current": null})),
        ("session_state", json!({"type": "session_state", "tag": "t", "state": "idle"})),
        ("session_bridge", json!({"type": "session_bridge", "tag": "t", "connected": true})),
        ("session_list_resp", json!({"type": "session_list_resp", "sessions": []})),
        ("focus_list_resp", json!({"type": "focus_list_resp", "focuses": []})),
        ("focus_registry_updated", json!({"type": "focus_registry_updated", "focuses": []})),
        ("decision_resolved", json!({"type": "decision_resolved", "tag": "t", "request_id": "r", "resolution": "answered"})),
        ("tracker_summary", json!({"type": "tracker_summary", "tag": "t", "has_tracker": false,
            "counts": {"todo": 0, "in_progress": 0, "blocked": 0, "needs_you": 0, "done": 0}})),
    ]
}

#[test]
fn frames_without_a_host_serialise_with_no_host_key_and_decode_from_json_lacking_it() {
    for (name, old) in host_free_frames() {
        let decoded = server(old.clone());
        let again = serde_json::to_value(&decoded).unwrap();
        assert!(again.get("host").is_none(), "{name}: a daemon's own frame has no host key: {again}");
        assert_eq!(again["type"], old["type"], "{name}");
    }
    // The decision request carries more required keys; same rule.
    let dr = server(json!({"type": "decision_request", "tag": "t", "request_id": "r", "prompt": "p", "choices": []}));
    assert!(serde_json::to_value(&dr).unwrap().get("host").is_none());
}

#[test]
fn a_host_on_a_frame_is_kept_through_a_round_trip() {
    for (name, mut v) in host_free_frames() {
        v["host"] = json!("kobe");
        let again = serde_json::to_value(server(v)).unwrap();
        assert_eq!(again["host"], "kobe", "{name}");
    }
}

#[test]
fn an_unknown_host_unavailable_reason_decodes_as_generic_unavailable() {
    let m = server(json!({"type": "host_unavailable", "host": "kobe", "reason": "disk_on_fire"}));
    match m {
        ServerMsg::HostUnavailable { host, reason } => {
            assert_eq!(host, "kobe");
            assert_eq!(reason, HostUnavailableReason::Unavailable);
        }
        other => panic!("{other:?}"),
    }
    for (wire, want) in [
        ("not_connected", HostUnavailableReason::NotConnected),
        ("egress_metadata", HostUnavailableReason::EgressMetadata),
        ("busy", HostUnavailableReason::Busy),
    ] {
        match server(json!({"type": "host_unavailable", "host": "h", "reason": wire})) {
            ServerMsg::HostUnavailable { reason, .. } => assert_eq!(reason, want, "{wire}"),
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn hosts_host_unavailable_and_device_admin_level_round_trip() {
    let frames = [
        json!({"type": "hosts", "hosts": [
            {"name": "kobe", "egress": "work", "connected_since": "2026-10-18T11:00:00Z", "last_seen": "2026-10-18T11:05:00Z"},
            {"name": "sendai", "egress": "personal", "connected_since": "2026-10-18T10:00:00Z", "last_seen": "2026-10-18T11:06:00Z"}]}),
        json!({"type": "host_unavailable", "host": "kobe", "reason": "egress_metadata"}),
        json!({"type": "device_admin_level", "level": "read_only", "pair_from": ["kobe", "sendai"]}),
        json!({"type": "device_admin_level", "level": "off", "pair_from": []}),
    ];
    for v in frames {
        let decoded = server(v.clone());
        let again = serde_json::to_value(&decoded).unwrap();
        assert_eq!(again["type"], v["type"]);
        // Decoding what we wrote yields the same wire form.
        assert_eq!(serde_json::to_value(server(again.clone())).unwrap(), again);
    }
    match server(json!({"type": "device_admin_level", "level": "read_only", "pair_from": ["kobe"]})) {
        ServerMsg::DeviceAdminLevel { level, pair_from } => {
            assert_eq!(level, SatelliteAdmin::ReadOnly);
            assert_eq!(pair_from, vec!["kobe".to_string()]);
        }
        other => panic!("{other:?}"),
    }
    match server(json!({"type": "hosts", "hosts": [
        {"name": "kobe", "egress": "work", "connected_since": "2026-10-18T11:00:00Z", "last_seen": "2026-10-18T11:05:00Z"}]}))
    {
        ServerMsg::Hosts { hosts } => {
            assert_eq!(hosts.len(), 1);
            assert_eq!(hosts[0].name, "kobe");
            assert_eq!(hosts[0].egress, Egress::Work);
        }
        other => panic!("{other:?}"),
    }
}
