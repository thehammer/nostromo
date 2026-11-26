//! The wire of the push feature (W13): what a phone sends, what the primary
//! answers, the presence verb the Mac app sends, and the gates around them.
//!
//! * additive: every frame a W9-W12 peer sends still decodes, and a frame that
//!   does not use a new field is byte-identical to what it was;
//! * `RegisterPush` without `capabilities` decodes with every flag false;
//! * `OperatorPresence` is exactly `{"type":"operator_presence","state":"active"|"away"}`;
//!   the golden files in `tests/fixtures/presence/` are what the Mac app's
//!   `ClientOperatorPresence` (macOS/Nostromo/Data/DeviceWire.swift) must write
//!   and, like `tests/fixtures/device-admin/`, are regenerated deliberately with
//!   `UPDATE_GOLDEN=1 cargo test --test push_wire`;
//! * none of the five new verbs is a network verb (`network_policy` refuses them)
//!   and none is a satellite's (`satellite_allowed`);
//! * `redact_for_uplink_metadata` keeps what the push engine needs from a work
//!   satellite's `DecisionRequest` and drops what a work host must not send.
//!
//! What a connection is actually sent and who may send what to a live server is in
//! `tests/push_server.rs`.

use std::path::PathBuf;

use chrono::{TimeZone, Utc};
use nostromo::ipc::peer::{network_policy, satellite_allowed, NetworkPolicy, SensitiveTags};
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, ServerMsg};
use nostromo::ipc::uplink_redact::{is_uplink_metadata_shape, redact_for_uplink_metadata};
use nostromo::push::wire::{
    AgentClass, HostClass, Presence, PushCapabilities, PushEnvironment, PushKind, PushOutcome,
    PushPrefs, PushSentEntry, PushStatusBody, PushWaitingItem,
};
use serde_json::{json, Value};

// ── RegisterPush and its capabilities (W13-37) ───────────────────────────────

fn register_push(json_text: &str) -> ClientMsg {
    serde_json::from_str(json_text).unwrap_or_else(|e| panic!("{json_text}: {e}"))
}

#[test]
fn a_register_push_without_capabilities_decodes_with_every_flag_false() {
    let msg = register_push(
        r#"{"type":"register_push","apns_token":"abab","environment":"sandbox","tz":"America/Chicago"}"#,
    );
    match msg {
        ClientMsg::RegisterPush {
            apns_token,
            environment,
            tz,
            capabilities,
        } => {
            assert_eq!(apns_token, "abab");
            assert_eq!(environment, PushEnvironment::Sandbox);
            assert_eq!(tz, "America/Chicago");
            assert_eq!(capabilities, PushCapabilities::default());
            assert!(!capabilities.nse_withdraw);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn capabilities_present_but_empty_or_with_flags_a_daemon_predates_read_as_false() {
    for caps in [r#"{}"#, r#"{"some_future_flag":true}"#, r#"null"#] {
        let text = format!(
            r#"{{"type":"register_push","apns_token":"abab","environment":"production","tz":"UTC","capabilities":{caps}}}"#
        );
        // `null` is not an object: only the absent and `{}` forms are the contract.
        if caps == "null" {
            continue;
        }
        match register_push(&text) {
            ClientMsg::RegisterPush { capabilities, .. } => {
                assert_eq!(capabilities, PushCapabilities::default(), "{caps}");
            }
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn a_flag_that_is_set_is_read_and_one_that_is_not_known_is_ignored() {
    let msg = register_push(
        r#"{"type":"register_push","apns_token":"abab","environment":"sandbox","tz":"UTC","capabilities":{"nse_withdraw":true,"nse":true}}"#,
    );
    match msg {
        ClientMsg::RegisterPush { capabilities, .. } => assert!(capabilities.nse_withdraw),
        other => panic!("{other:?}"),
    }
}

#[test]
fn register_push_round_trips_and_names_its_fields() {
    let msg = ClientMsg::RegisterPush {
        apns_token: "ab".repeat(32),
        environment: PushEnvironment::Production,
        tz: "UTC".into(),
        capabilities: PushCapabilities {
            nse_withdraw: false,
        },
    };
    let v = serde_json::to_value(&msg).unwrap();
    assert_eq!(v["type"], "register_push");
    assert_eq!(v["environment"], "production");
    assert_eq!(v["capabilities"], json!({"nse_withdraw": false}));
    let back: ClientMsg = serde_json::from_value(v).unwrap();
    assert_eq!(
        serde_json::to_value(&back).unwrap(),
        serde_json::to_value(&msg).unwrap()
    );
}

#[test]
fn the_other_push_verbs_have_their_wire_names() {
    assert_eq!(
        serde_json::to_value(ClientMsg::PushSentLog).unwrap(),
        json!({"type": "push_sent_log"})
    );
    assert_eq!(
        serde_json::to_value(ClientMsg::PushWaiting).unwrap(),
        json!({"type": "push_waiting"})
    );
    let set = serde_json::to_value(ClientMsg::SetPushPrefs {
        prefs: PushPrefs::default(),
    })
    .unwrap();
    assert_eq!(set["type"], "set_push_prefs");
    assert!(set["prefs"].is_object());
}

// ── settings and their defaults ──────────────────────────────────────────────

#[test]
fn settings_with_nothing_set_are_the_prds_defaults() {
    let prefs: PushPrefs = serde_json::from_str("{}").unwrap();
    assert!(
        prefs.kinds.mother && prefs.kinds.decision && prefs.kinds.review,
        "every kind on"
    );
    assert_eq!(prefs.quiet.start, "22:00");
    assert_eq!(prefs.quiet.end, "07:00");
    assert!(prefs.quiet.enabled);
    assert_eq!(prefs.evening_summary.as_deref(), Some("17:30"));
    assert_eq!(prefs.tz, "UTC");
    assert_eq!(prefs, PushPrefs::default());
}

#[test]
fn settings_decode_partially_and_an_explicit_null_turns_the_evening_summary_off() {
    let prefs: PushPrefs = serde_json::from_value(json!({
        "kinds": {"review": false},
        "quiet": {"start": "21:00"},
        "evening_summary": null,
        "tz": "Asia/Tokyo",
    }))
    .unwrap();
    assert!(prefs.kinds.mother && prefs.kinds.decision && !prefs.kinds.review);
    assert_eq!(prefs.quiet.start, "21:00");
    assert_eq!(prefs.quiet.end, "07:00");
    assert_eq!(prefs.evening_summary, None);
    assert_eq!(prefs.tz, "Asia/Tokyo");
}

// ── the frames a phone is sent ───────────────────────────────────────────────

#[test]
fn push_status_names_prefs_host_classes_and_work_owners_and_omits_what_is_unknown() {
    let status = ServerMsg::PushStatus(PushStatusBody {
        prefs: PushPrefs::default(),
        host_classes: [
            ("kobe".to_string(), HostClass::Work),
            ("sendai".to_string(), HostClass::Personal),
        ]
        .into(),
        work_owners: vec!["Carefeed".into()],
        last_ok_at: None,
        failing_since: None,
    });
    let v = serde_json::to_value(&status).unwrap();
    assert_eq!(v["type"], "push_status");
    assert_eq!(
        v["host_classes"],
        json!({"kobe": "work", "sendai": "personal"})
    );
    assert_eq!(v["work_owners"], json!(["Carefeed"]));
    assert!(
        v.get("last_ok_at").is_none() && v.get("failing_since").is_none(),
        "{v}"
    );
    assert!(v["prefs"]["kinds"].is_object() && v["prefs"]["quiet"].is_object());

    let failing = ServerMsg::PushStatus(PushStatusBody {
        prefs: PushPrefs::default(),
        host_classes: Default::default(),
        work_owners: vec!["Carefeed".into()],
        last_ok_at: Some(Utc.with_ymd_and_hms(2026, 11, 26, 9, 0, 0).unwrap()),
        failing_since: Some(Utc.with_ymd_and_hms(2026, 11, 26, 9, 30, 0).unwrap()),
    });
    let v = serde_json::to_value(&failing).unwrap();
    assert_eq!(v["last_ok_at"], "2026-11-26T09:00:00Z");
    assert_eq!(v["failing_since"], "2026-11-26T09:30:00Z");
    let back: ServerMsg = serde_json::from_value(v).unwrap();
    assert!(matches!(back, ServerMsg::PushStatus(_)));
}

#[test]
fn push_waiting_lists_items_with_a_ref_only_when_there_is_one() {
    let msg = ServerMsg::PushWaiting {
        items: vec![
            PushWaitingItem {
                item_ref: "0123456789abcdef".into(),
                kind: PushKind::Mother,
                host: "kobe".into(),
                ref_: Some("Job 3f9a1c2e".into()),
            },
            PushWaitingItem {
                item_ref: "fedcba9876543210".into(),
                kind: PushKind::Decision,
                host: "kobe".into(),
                ref_: None,
            },
        ],
        badge: 2,
    };
    let v = serde_json::to_value(&msg).unwrap();
    assert_eq!(v["type"], "push_waiting");
    assert_eq!(v["badge"], 2);
    assert_eq!(v["items"][0]["ref"], "Job 3f9a1c2e");
    assert_eq!(v["items"][0]["kind"], "mother");
    assert_eq!(v["items"][1]["kind"], "decision");
    assert!(
        v["items"][1].get("ref").is_none(),
        "a decision has no reference: {v}"
    );
}

#[test]
fn the_sent_log_names_exactly_the_seven_outcomes_and_never_a_device_reference() {
    let all = [
        (PushOutcome::DeliveredToApple, "delivered_to_apple"),
        (PushOutcome::RejectedByApple, "rejected_by_apple"),
        (PushOutcome::RelayUnreachable, "relay_unreachable"),
        (PushOutcome::HeldQuietHours, "held_quiet_hours"),
        (PushOutcome::Coalesced, "coalesced"),
        (PushOutcome::Withdrawn, "withdrawn"),
        (
            PushOutcome::SkippedResolvedInGrace,
            "skipped_resolved_in_grace",
        ),
    ];
    for (outcome, word) in all {
        assert_eq!(serde_json::to_value(outcome).unwrap(), json!(word));
        assert_eq!(
            serde_json::from_value::<PushOutcome>(json!(word)).unwrap(),
            outcome
        );
    }
    let entry = PushSentEntry {
        ts: Utc.with_ymd_and_hms(2026, 11, 26, 9, 0, 0).unwrap(),
        kind: "mother".into(),
        host: "kobe".into(),
        title: "Mother · kobe".into(),
        body: "Job 3f9a1c2e asked a question".into(),
        outcome: PushOutcome::DeliveredToApple,
    };
    let v = serde_json::to_value(ServerMsg::PushSentLog {
        entries: vec![entry],
    })
    .unwrap();
    assert_eq!(v["type"], "push_sent_log");
    let keys: std::collections::BTreeSet<&str> = v["entries"][0]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        ["body", "host", "kind", "outcome", "title", "ts"].into()
    );
}

#[test]
fn the_closed_enums_use_their_documented_words() {
    for (v, word) in [(Presence::Active, "active"), (Presence::Away, "away")] {
        assert_eq!(serde_json::to_value(v).unwrap(), json!(word));
    }
    for (v, word) in [
        (AgentClass::Mother, "mother"),
        (AgentClass::Perri, "perri"),
        (AgentClass::Fred, "fred"),
        (AgentClass::Teri, "teri"),
        (AgentClass::Claudia, "claudia"),
        (AgentClass::Other, "other"),
    ] {
        assert_eq!(serde_json::to_value(v).unwrap(), json!(word));
    }
    assert_eq!(
        serde_json::to_value(HostClass::Work).unwrap(),
        json!("work")
    );
    assert_eq!(
        serde_json::to_value(HostClass::Personal).unwrap(),
        json!("personal")
    );
    assert_eq!(
        HostClass::default(),
        HostClass::Work,
        "unclassified is work"
    );
    assert_eq!(
        serde_json::to_value(PushEnvironment::Sandbox).unwrap(),
        json!("sandbox")
    );
    assert_eq!(
        serde_json::to_value(PushEnvironment::Production).unwrap(),
        json!("production")
    );
    assert_eq!(PushKind::Mother.as_str(), "mother");
    assert_eq!(PushKind::Decision.as_str(), "decision");
    assert_eq!(PushKind::Review.as_str(), "review");
}

// ── DecisionRequest: additive ────────────────────────────────────────────────

/// A `DecisionRequest` frame as a W6-W12 daemon wrote it: none of the W13 fields.
fn old_decision_frame() -> Value {
    json!({
        "type": "decision_request",
        "tag": "claudia",
        "request_id": "req-1",
        "prompt": "Which branch?",
        "detail": "Two candidates.",
        "choices": [
            {"id": "a", "label": "main"},
            {"id": "b", "label": "develop", "detail": "the long-lived one", "is_default": true},
        ],
        "context_pane_id": "pane-1",
        "host": "kobe",
    })
}

#[test]
fn an_old_decision_request_still_decodes_and_encodes_byte_identically() {
    let old = old_decision_frame();
    let msg: ServerMsg = serde_json::from_value(old.clone()).expect("an old frame decodes");
    match &msg {
        ServerMsg::DecisionRequest {
            deadline,
            agent_class,
            operator_presence,
            repo,
            repo_owner,
            ..
        } => {
            assert_eq!(*deadline, None);
            assert_eq!(*agent_class, None);
            assert_eq!(*operator_presence, None);
            assert_eq!(*repo, None);
            assert_eq!(*repo_owner, None);
        }
        other => panic!("{other:?}"),
    }
    // Nothing new appears: not even a `null`.
    assert_eq!(serde_json::to_value(&msg).unwrap(), old);
    assert_eq!(
        serde_json::to_string(&msg).unwrap(),
        serde_json::to_string(&serde_json::from_value::<ServerMsg>(old).unwrap()).unwrap()
    );
}

#[test]
fn a_decision_request_with_the_new_facts_round_trips_with_exactly_those_keys() {
    let mut frame = old_decision_frame();
    let o = frame.as_object_mut().unwrap();
    o.insert("deadline".into(), json!("2026-11-26T10:05:00Z"));
    o.insert("agent_class".into(), json!("claudia"));
    o.insert("operator_presence".into(), json!("away"));
    o.insert("repo".into(), json!("bishop"));
    o.insert("repo_owner".into(), json!("thehammer"));
    let msg: ServerMsg = serde_json::from_value(frame.clone()).unwrap();
    match &msg {
        ServerMsg::DecisionRequest {
            deadline,
            agent_class,
            operator_presence,
            repo,
            repo_owner,
            ..
        } => {
            assert_eq!(
                *deadline,
                Some(Utc.with_ymd_and_hms(2026, 11, 26, 10, 5, 0).unwrap())
            );
            assert_eq!(*agent_class, Some(AgentClass::Claudia));
            assert_eq!(*operator_presence, Some(Presence::Away));
            assert_eq!(repo.as_deref(), Some("bishop"));
            assert_eq!(repo_owner.as_deref(), Some("thehammer"));
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(serde_json::to_value(&msg).unwrap(), frame);
}

// ── OperatorPresence golden files ────────────────────────────────────────────

fn presence_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/presence")
}

fn presence_fixtures() -> Vec<(&'static str, ClientMsg)> {
    vec![
        (
            "client-operator-presence-active.json",
            ClientMsg::OperatorPresence {
                state: Presence::Active,
            },
        ),
        (
            "client-operator-presence-away.json",
            ClientMsg::OperatorPresence {
                state: Presence::Away,
            },
        ),
    ]
}

fn rendered(msg: &ClientMsg) -> String {
    let mut text = serde_json::to_string_pretty(msg).expect("serialise");
    text.push('\n');
    text
}

#[test]
fn every_presence_verb_matches_its_committed_golden_file_byte_for_byte() {
    let updating = std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1");
    for (name, msg) in presence_fixtures() {
        let want = rendered(&msg);
        if updating {
            std::fs::create_dir_all(presence_dir()).unwrap();
            std::fs::write(presence_dir().join(name), &want).unwrap();
            continue;
        }
        let have = std::fs::read_to_string(presence_dir().join(name)).unwrap_or_else(|e| {
            panic!("{name} is missing ({e}); generate it with UPDATE_GOLDEN=1 cargo test --test push_wire")
        });
        assert!(
            have == want,
            "{name} no longer matches what the daemon serialises. If the wire change is intended, regenerate with \
             UPDATE_GOLDEN=1 cargo test --test push_wire and check the Mac app's ClientOperatorPresence still writes it.\n\
             --- committed:\n{have}\n--- produced:\n{want}"
        );
    }
}

#[test]
fn the_presence_golden_files_decode_and_reencode_identically_and_hold_only_type_and_state() {
    for (name, _) in presence_fixtures() {
        let text = std::fs::read_to_string(presence_dir().join(name)).unwrap();
        let msg: ClientMsg = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(rendered(&msg), text, "{name}: decode then encode");
        let v: Value = serde_json::from_str(&text).unwrap();
        let keys: std::collections::BTreeSet<&str> =
            v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["state", "type"].into(), "{name}");
        assert_eq!(v["type"], "operator_presence");
    }
}

#[test]
fn the_presence_verb_is_exactly_the_compact_json_the_mac_app_documents() {
    assert_eq!(
        serde_json::to_string(&ClientMsg::OperatorPresence {
            state: Presence::Active
        })
        .unwrap(),
        r#"{"type":"operator_presence","state":"active"}"#
    );
    assert_eq!(
        serde_json::to_string(&ClientMsg::OperatorPresence {
            state: Presence::Away
        })
        .unwrap(),
        r#"{"type":"operator_presence","state":"away"}"#
    );
}

#[test]
fn what_the_mac_app_encodes_decodes_whatever_its_key_order() {
    // Swift's JSONEncoder (sorted keys, as the app's own test pins) writes `state` first.
    for (text, want) in [
        (
            r#"{"state":"active","type":"operator_presence"}"#,
            Presence::Active,
        ),
        (
            r#"{"state":"away","type":"operator_presence"}"#,
            Presence::Away,
        ),
        (
            r#"{"type":"operator_presence","state":"away"}"#,
            Presence::Away,
        ),
    ] {
        match serde_json::from_str::<ClientMsg>(text).unwrap() {
            ClientMsg::OperatorPresence { state } => assert_eq!(state, want, "{text}"),
            other => panic!("{text}: {other:?}"),
        }
    }
    for bad in [
        r#"{"type":"operator_presence","state":"idle"}"#,
        r#"{"type":"operator_presence","state":"Away"}"#,
        r#"{"type":"operator_presence"}"#,
        r#"{"type":"operator_presence","state":true}"#,
    ] {
        assert!(
            serde_json::from_str::<ClientMsg>(bad).is_err(),
            "{bad} must not decode"
        );
    }
}

#[test]
fn the_presence_fixture_directory_holds_exactly_the_files_built_here() {
    let mut want: Vec<String> = presence_fixtures()
        .into_iter()
        .map(|(n, _)| n.to_string())
        .collect();
    want.sort();
    let mut have: Vec<String> = std::fs::read_dir(presence_dir())
        .expect("fixture directory")
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    have.sort();
    assert_eq!(have, want, "a stale or unlisted fixture");
}

// ── none of the new verbs is a network or satellite verb ─────────────────────

fn the_five_new_verbs() -> Vec<ClientMsg> {
    vec![
        ClientMsg::RegisterPush {
            apns_token: "ab".repeat(32),
            environment: PushEnvironment::Sandbox,
            tz: "UTC".into(),
            capabilities: Default::default(),
        },
        ClientMsg::SetPushPrefs {
            prefs: PushPrefs::default(),
        },
        ClientMsg::PushSentLog,
        ClientMsg::PushWaiting,
        ClientMsg::OperatorPresence {
            state: Presence::Away,
        },
    ]
}

#[test]
fn a_network_peer_is_refused_all_five_new_verbs() {
    for msg in the_five_new_verbs() {
        assert_eq!(network_policy(&msg), NetworkPolicy::Refused, "{msg:?}");
    }
}

#[test]
fn a_satellites_uplink_may_send_none_of_the_five_new_verbs() {
    for msg in the_five_new_verbs() {
        assert!(!satellite_allowed(&msg), "{msg:?}");
    }
}

#[test]
fn answering_and_resuming_stay_refused_to_a_network_peer() {
    // W13-29: a phone never answers, acks or resumes; nothing in this wedge changes that.
    use nostromo::ipc::protocol::MotherActionKind;
    let verbs = [
        ClientMsg::DecisionAnswer {
            request_id: "r".into(),
            choice_id: Some("a".into()),
            operator_nonce: None,
        },
        ClientMsg::MotherResume {
            job_id: "j".into(),
            answer: "yes".into(),
        },
        ClientMsg::MotherAction {
            job_id: "j".into(),
            action: MotherActionKind::Cancel,
        },
    ];
    for msg in verbs {
        assert_eq!(network_policy(&msg), NetworkPolicy::Refused, "{msg:?}");
        assert!(!satellite_allowed(&msg), "{msg:?}");
    }
}

// ── a work satellite's DecisionRequest (B9) ──────────────────────────────────

fn full_decision() -> ServerMsg {
    ServerMsg::DecisionRequest {
        tag: "claudia-MARKER-session".into(),
        request_id: "req-1".into(),
        prompt: "MARKER-prompt".into(),
        detail: Some("MARKER-detail".into()),
        choices: (0..3)
            .map(|i| DecisionChoice {
                id: format!("opt-{i}"),
                label: "MARKER-choice-label".into(),
                detail: Some("MARKER-choice-detail".into()),
                is_default: i == 0,
            })
            .collect(),
        context_pane_id: Some("MARKER-pane".into()),
        host: Some("kobe".into()),
        deadline: Some(Utc.with_ymd_and_hms(2026, 11, 26, 10, 5, 0).unwrap()),
        agent_class: Some(AgentClass::Claudia),
        operator_presence: Some(Presence::Away),
        repo: Some("MARKER-repo".into()),
        repo_owner: Some("MARKER-owner".into()),
    }
}

fn redacted(msg: ServerMsg) -> ServerMsg {
    redact_for_uplink_metadata(msg, &[7u8; 32], &SensitiveTags::in_memory())
        .expect("a metadata frame")
}

#[test]
fn the_work_metadata_arm_keeps_deadline_agent_class_and_presence_and_drops_everything_else() {
    let out = redacted(full_decision());
    match &out {
        ServerMsg::DecisionRequest {
            tag,
            request_id,
            prompt,
            detail,
            choices,
            context_pane_id,
            host,
            deadline,
            agent_class,
            operator_presence,
            repo,
            repo_owner,
        } => {
            assert_eq!(
                *deadline,
                Some(Utc.with_ymd_and_hms(2026, 11, 26, 10, 5, 0).unwrap())
            );
            assert_eq!(*agent_class, Some(AgentClass::Claudia));
            assert_eq!(*operator_presence, Some(Presence::Away));
            assert_eq!(request_id, "req-1");
            assert_eq!(host.as_deref(), Some("kobe"));
            assert_eq!(choices.len(), 3, "the count survives");
            // Everything a person or agent wrote is gone.
            assert!(prompt.is_empty() && detail.is_none() && context_pane_id.is_none());
            assert!(choices
                .iter()
                .all(|c| c.label.is_empty() && c.detail.is_none()));
            assert_eq!(*repo, None, "a work host's repository name is work data");
            assert_eq!(*repo_owner, None);
            assert!(tag.starts_with("f-") && !tag.contains("MARKER"), "{tag}");
        }
        other => panic!("{other:?}"),
    }
    let text = serde_json::to_string(&out).unwrap();
    assert!(!text.to_ascii_lowercase().contains("marker"), "{text}");
    assert!(
        is_uplink_metadata_shape(&out),
        "what the arm writes is what the primary accepts"
    );
}

#[test]
fn the_primary_rejects_a_work_decision_frame_that_carries_a_repository() {
    // A satellite that did not blank `repo` or `repo_owner` is not sending metadata.
    for (repo, owner) in [
        (Some("bishop"), None),
        (None, Some("thehammer")),
        (Some("bishop"), Some("thehammer")),
    ] {
        let mut frame = redacted(full_decision());
        if let ServerMsg::DecisionRequest {
            repo: r,
            repo_owner: o,
            ..
        } = &mut frame
        {
            *r = repo.map(str::to_string);
            *o = owner.map(str::to_string);
        }
        assert!(!is_uplink_metadata_shape(&frame), "{repo:?}/{owner:?}");
    }
    // The control: the same frame without them is fine, and with the push facts set.
    assert!(is_uplink_metadata_shape(&redacted(full_decision())));
}

#[test]
fn the_primary_rejects_a_work_decision_frame_with_text_in_it() {
    let mut frame = redacted(full_decision());
    if let ServerMsg::DecisionRequest { prompt, .. } = &mut frame {
        *prompt = "MARKER-prompt".into();
    }
    assert!(!is_uplink_metadata_shape(&frame));
}

#[test]
fn a_work_satellites_job_frame_keeps_when_the_job_paused() {
    // BUG if this fails: the plan has the metadata arm keep `paused_at` (a
    // timestamp), because the grace delay of a Kobe job counts from it.
    let jobs: Vec<nostromo::mother::MotherJob> = serde_json::from_value(json!([{
        "id": "20261126T100000Z-3f9a1c2e", "state": "awaiting", "paused_reason": "user",
        "paused_at": "2026-11-26T09:58:00Z", "title": "MARKER-title",
    }]))
    .unwrap();
    let out = redacted(ServerMsg::MotherJobs {
        jobs,
        host: Some("kobe".into()),
    });
    match &out {
        ServerMsg::MotherJobs { jobs, .. } => {
            assert_eq!(
                jobs[0].paused_at,
                Some(Utc.with_ymd_and_hms(2026, 11, 26, 9, 58, 0).unwrap()),
                "paused_at was dropped by the metadata arm"
            );
        }
        other => panic!("{other:?}"),
    }
    assert!(
        is_uplink_metadata_shape(&out),
        "and the primary still accepts the frame"
    );
}

#[test]
fn a_work_satellites_job_frame_keeps_the_reasons_the_push_engine_reads() {
    // `paused_reason` and `activity` keep `user`, `adherence_blocked`,
    // `operator_hold`, `cost_cap` and `pipeline_blocked`, and attention reasons
    // keep `progress_stalled`, `burn_ahead` and `gates_incomplete`; any quota
    // pause (`quota_*`) stays recognisable as the one fixed token `quota_limit`,
    // never with the rest of its text, so that it can be left out.
    let jobs: Vec<nostromo::mother::MotherJob> = serde_json::from_value(json!([
        {"id": "20261126T100000Z-0000aaa1", "state": "awaiting", "paused_reason": "user"},
        {"id": "20261126T100000Z-0000aaa2", "state": "awaiting", "paused_reason": "adherence_blocked"},
        {"id": "20261126T100000Z-0000aaa3", "state": "awaiting", "paused_reason": "operator_hold"},
        {"id": "20261126T100000Z-0000aaa4", "state": "awaiting", "paused_reason": "cost_cap"},
        {"id": "20261126T100000Z-0000aaa5", "state": "awaiting", "activity": "pipeline_blocked"},
        {"id": "20261126T100000Z-0000aaa6", "state": "awaiting", "paused_reason": "quota_5h"},
        {"id": "20261126T100000Z-0000aaa7", "state": "running", "attention_reasons": [
            {"reason": "progress_stalled", "since": "2026-11-26T09:00:00Z", "acked": false},
            {"reason": "burn_ahead", "since": "2026-11-26T09:00:00Z", "acked": false},
            {"reason": "gates_incomplete", "since": "2026-11-26T09:00:00Z", "acked": false}]},
        {"id": "20261126T100000Z-0000aaa8", "state": "awaiting", "paused_reason": "quota_MARKER-secret-text"},
    ]))
    .unwrap();
    let out = redacted(ServerMsg::MotherJobs {
        jobs,
        host: Some("kobe".into()),
    });
    let ServerMsg::MotherJobs { jobs, .. } = out else {
        panic!()
    };
    let reasons: Vec<Option<&str>> = jobs
        .iter()
        .take(4)
        .map(|j| j.paused_reason.as_deref())
        .collect();
    assert_eq!(
        reasons,
        vec![
            Some("user"),
            Some("adherence_blocked"),
            Some("operator_hold"),
            Some("cost_cap")
        ],
        "paused_reason"
    );
    assert_eq!(
        jobs[4].activity.as_deref(),
        Some("pipeline_blocked"),
        "activity"
    );
    for quota in [&jobs[5], &jobs[7]] {
        assert_eq!(
            quota.paused_reason.as_deref(),
            Some("quota_limit"),
            "any quota pause is sent as the one fixed token"
        );
    }
    let attention: Vec<&str> = jobs[6]
        .attention_reasons
        .iter()
        .map(|a| a.reason.as_str())
        .collect();
    assert_eq!(
        attention,
        vec!["progress_stalled", "burn_ahead", "gates_incomplete"],
        "attention reasons"
    );
}

#[test]
fn a_work_satellites_unfetched_queue_marker_survives_the_uplink() {
    // The primary must be able to tell "the satellite has not fetched its queue
    // yet" from "nothing is waiting", or a restart looks like every review leaving.
    for unfetched in [true, false] {
        let out = redacted(ServerMsg::PerriState {
            tag: "perri".into(),
            queue: vec![],
            current: None,
            jira_site: None,
            host: Some("kobe".into()),
            queue_unfetched: unfetched,
        });
        let ServerMsg::PerriState {
            queue_unfetched, ..
        } = &out
        else {
            panic!()
        };
        assert_eq!(*queue_unfetched, unfetched);
        assert!(nostromo::ipc::uplink_redact::is_uplink_metadata_shape(&out));
    }
}

#[test]
fn a_work_satellites_review_frame_keeps_the_changed_lines_number() {
    // The PerriState metadata arm keeps `number`, `bucket` and `changed_lines`,
    // so a Kobe review can say "small change".
    let queue = vec![nostromo::data::perri_queue::PrQueueItem {
        repo: "Carefeed/admin-portal".into(),
        number: 4821,
        title: "MARKER-title".into(),
        author: "MARKER-author".into(),
        bucket: "requested".into(),
        changed_lines: Some(10),
        ..Default::default()
    }];
    let out = redacted(ServerMsg::PerriState {
        tag: "perri".into(),
        queue,
        current: None,
        jira_site: None,
        host: Some("kobe".into()),
        queue_unfetched: false,
    });
    let ServerMsg::PerriState { queue, .. } = &out else {
        panic!()
    };
    assert_eq!(queue[0].number, 4821);
    assert_eq!(
        queue[0].changed_lines,
        Some(10),
        "changed_lines was dropped by the metadata arm"
    );
    assert!(queue[0].title.is_empty() && queue[0].author.is_empty());
    // The repository is pseudonymous (`r-` + 8 hex), so two PRs with one number
    // in two repositories stay two items, and the name itself never leaves.
    let repo = &queue[0].repo;
    assert!(
        repo.len() == 10
            && repo.starts_with("r-")
            && repo[2..].bytes().all(|b| b.is_ascii_hexdigit()),
        "repo {repo:?}"
    );
    assert!(!repo.contains("admin-portal") && !repo.contains("Carefeed"));
    assert!(is_uplink_metadata_shape(&out));
}

// ── W13-19: the engine never answers anything ────────────────────────────────

/// The only `ClientMsg` variants `src/push/` may name: the paired phone's four
/// verbs, which it matches (never builds) in `PushEngine::dispatch`.
const PUSH_ENGINE_CLIENT_VERBS: [&str; 4] =
    ["RegisterPush", "SetPushPrefs", "PushSentLog", "PushWaiting"];

/// What in `src` (a `src/push/` file) would let the engine answer something:
/// an answer type, or a `ClientMsg::` variant outside the four push verbs.
fn engine_answer_violations(file: &str, src: &str) -> Vec<String> {
    let code: String = src
        .lines()
        .map(|l| l.split("//").next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join("\n");
    let mut out = Vec::new();
    for word in ["DecisionAnswer", "ApprovalAnswer"] {
        if code.contains(word) {
            out.push(format!("{file} mentions {word}"));
        }
    }
    for part in code.split("ClientMsg::").skip(1) {
        let variant: String = part
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if !PUSH_ENGINE_CLIENT_VERBS.contains(&variant.as_str()) {
            out.push(format!("{file} names ClientMsg::{variant}"));
        }
    }
    out
}

const PUSH_SOURCES: [(&str, &str); 10] = [
    ("cli.rs", include_str!("../src/push/cli.rs")),
    ("devices.rs", include_str!("../src/push/devices.rs")),
    ("items.rs", include_str!("../src/push/items.rs")),
    ("mod.rs", include_str!("../src/push/mod.rs")),
    ("owner.rs", include_str!("../src/push/owner.rs")),
    ("publisher.rs", include_str!("../src/push/publisher.rs")),
    ("schedule.rs", include_str!("../src/push/schedule.rs")),
    ("sent_log.rs", include_str!("../src/push/sent_log.rs")),
    ("vocab.rs", include_str!("../src/push/vocab.rs")),
    ("wire.rs", include_str!("../src/push/wire.rs")),
];

#[test]
fn the_push_engine_source_builds_no_answer_and_sends_only_relay_requests() {
    // A file added to src/push/ must be added to the list above, or it escapes the scan.
    let mut on_disk: Vec<String> = std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/src/push"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    on_disk.sort();
    let listed: Vec<String> = PUSH_SOURCES.iter().map(|(n, _)| n.to_string()).collect();
    assert_eq!(on_disk, listed, "src/push/ changed: list the new file in PUSH_SOURCES");

    for (name, src) in PUSH_SOURCES {
        assert_eq!(engine_answer_violations(name, src), Vec::<String>::new());
    }
    // Not vacuous: the engine does send relay requests.
    assert!(PUSH_SOURCES.iter().any(|(_, s)| s.contains("RelayRequest")));
}

#[test]
fn the_answer_scan_bites_on_an_answer_a_foreign_verb_and_ignores_comments() {
    assert_eq!(
        engine_answer_violations("x.rs", "let m = ClientMsg::DecisionAnswer { request_id };").len(),
        2,
        "the type name and the foreign variant"
    );
    assert_eq!(
        engine_answer_violations("x.rs", "tx.send(ClientMsg::MotherAction { id });").len(),
        1
    );
    assert_eq!(
        engine_answer_violations("x.rs", "ClientMsg::ApprovalAnswer { .. }").len(),
        2
    );
    assert!(engine_answer_violations("x.rs", "ClientMsg::PushWaiting => {}").is_empty());
    assert!(engine_answer_violations("x.rs", "// never ClientMsg::DecisionAnswer").is_empty());
}
