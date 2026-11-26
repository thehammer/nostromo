//! W12 wire contract, from outside the daemon and without a socket: what a
//! `Subscribe` with and without `resume` looks like, what a `Gap` looks like,
//! and which frames and topics are numbered at all.
//!
//! Behaviour over a real connection (numbering, replay, gaps, queues) is in
//! `tests/seq_resume.rs`; the heartbeat is in `tests/ws_heartbeat.rs`.

use std::collections::BTreeMap;

use nostromo::ipc::protocol::{ClientMsg, GapReason, ServerMsg, Topic};
use nostromo::ipc::stream_json::Turn;
use serde_json::{json, Value};

fn subscribe(resume: BTreeMap<Topic, u64>) -> ClientMsg {
    ClientMsg::Subscribe {
        topics: vec![Topic::MotherJobs],
        renders_decisions: false,
        renders_approvals: false,
        capabilities: vec![],
        operator_nonce: None,
        resume,
        seq_epoch: None,
    }
}

fn resume_of(frame: &str) -> BTreeMap<Topic, u64> {
    match serde_json::from_str::<ClientMsg>(frame).expect("the Subscribe decodes") {
        ClientMsg::Subscribe { resume, .. } => resume,
        other => panic!("expected a Subscribe, got {other:?}"),
    }
}

// ── Subscribe.resume ──────────────────────────────────────────────────────────

#[test]
fn a_subscribe_without_resume_serializes_exactly_as_it_did_before_the_field_existed() {
    let json = serde_json::to_string(&subscribe(BTreeMap::new())).unwrap();
    assert_eq!(
        json,
        r#"{"type":"subscribe","topics":["mother_jobs"],"renders_decisions":false,"renders_approvals":false}"#,
        "an empty resume must not add a key: older daemons and the golden fixtures see the old bytes"
    );
    assert!(!json.contains("resume"));
}

#[test]
fn a_subscribe_with_resume_names_each_topic_and_its_last_number() {
    let json = serde_json::to_value(subscribe(BTreeMap::from([
        (Topic::MotherJobs, 5),
        (Topic::Teri, 0),
    ])))
    .unwrap();
    assert_eq!(json["resume"], json!({"mother_jobs": 5, "teri": 0}));

    // And it reads back as the same map.
    let back = resume_of(&json.to_string());
    assert_eq!(
        back,
        BTreeMap::from([(Topic::MotherJobs, 5), (Topic::Teri, 0)])
    );
}

#[test]
fn a_subscribe_from_a_client_that_never_heard_of_resume_decodes_to_no_resume() {
    let old = r#"{"type":"subscribe","topics":["mother_jobs"],"renders_decisions":false}"#;
    assert!(resume_of(old).is_empty());
}

#[test]
fn a_resume_entry_that_is_not_a_topic_or_not_a_number_is_dropped_and_the_frame_still_decodes() {
    // An unknown topic (a newer client's), and every shape of "not an unsigned
    // integer", next to three entries that are fine.
    let frame = json!({
        "type": "subscribe",
        "topics": [],
        "resume": {
            "mother_jobs": 5,
            "perri": 0,
            "activity": u64::MAX,
            "holograms": 9,
            "unknown": 3,
            "fred": "7",
            "teri": -1,
            "work": 2.5,
            "layout": null,
            "focuses": true,
            "decision": [1],
            "model": {"a": 1},
        }
    })
    .to_string();
    assert_eq!(
        resume_of(&frame),
        BTreeMap::from([
            (Topic::Activity, u64::MAX),
            (Topic::MotherJobs, 5),
            (Topic::Perri, 0),
        ]),
        "only the well-formed entries for known topics survive"
    );
}

// ── Gap ───────────────────────────────────────────────────────────────────────

#[test]
fn a_gap_round_trips_with_each_of_its_three_reasons() {
    for (reason, name) in [
        (GapReason::ReplayWindowExceeded, "replay_window_exceeded"),
        (GapReason::ClientSlow, "client_slow"),
        (GapReason::UplinkReconnect, "uplink_reconnect"),
    ] {
        let frame = ServerMsg::Gap {
            topic: Topic::MotherJobs,
            host: None,
            from: 11,
            to: 1050,
            reason,
        };
        let wire = serde_json::to_value(&frame).unwrap();
        assert_eq!(
            wire,
            json!({"type": "gap", "topic": "mother_jobs", "from": 11, "to": 1050, "reason": name}),
            "a Gap with no host has no host key"
        );
        let back: ServerMsg = serde_json::from_value(wire.clone()).unwrap();
        assert_eq!(serde_json::to_value(&back).unwrap(), wire);
        match back {
            ServerMsg::Gap {
                topic,
                host,
                from,
                to,
                reason: got,
            } => {
                assert_eq!(
                    (topic, host, from, to, got),
                    (Topic::MotherJobs, None, 11, 1050, reason)
                );
            }
            other => panic!("expected a Gap, got {other:?}"),
        }
    }
}

#[test]
fn a_gap_names_the_host_it_is_about_when_there_is_one() {
    let frame: ServerMsg = serde_json::from_str(
        r#"{"type":"gap","topic":"perri","host":"kobe","from":3,"to":9,"reason":"uplink_reconnect"}"#,
    )
    .unwrap();
    match frame {
        ServerMsg::Gap {
            topic,
            host,
            from,
            to,
            reason,
        } => assert_eq!(
            (topic, host.as_deref(), from, to, reason),
            (Topic::Perri, Some("kobe"), 3, 9, GapReason::UplinkReconnect)
        ),
        other => panic!("expected a Gap, got {other:?}"),
    }
}

// ── what is numbered at all ───────────────────────────────────────────────────

#[test]
fn the_local_only_topics_and_the_unknown_topic_have_no_numbers_and_every_other_topic_does() {
    for topic in [
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
    ] {
        assert!(topic.is_sequenced(), "{topic:?} is numbered");
    }
    for topic in [
        Topic::Terminal,
        Topic::AuthoredPrs,
        Topic::Devices,
        Topic::Unknown,
    ] {
        assert!(!topic.is_sequenced(), "{topic:?} has no number and no ring");
    }
}

fn approval_request() -> ServerMsg {
    serde_json::from_value(json!({
        "type": "approval_request",
        "tag": "t",
        "request": {
            "request_id": "r-min",
            "tag": "t",
            "tool_use_id": "toolu_2",
            "agent": { "name": "cody" },
            "tool_name": "Bash",
            "display_name": "Bash",
            "tool_kind": "bash",
            "input": { "command": "ls" },
            "display": { "lines": [], "invisible_count": 0, "non_ascii_count": 0, "unparsed": false },
            "reason": { "kind": "other", "text": "Claude Code asked for approval" },
            "flags": {
                "default_to_no": false,
                "suppress_always_allow_rule": false,
                "requires_user_interaction": false,
                "classifier_approvable": false
            },
            "options": ["allow_once", "deny"],
            "session_rule_candidates": [],
            "created_at_ms": 1,
            "deadline_at_ms": 2
        }
    }))
    .expect("an approval request")
}

#[test]
fn frames_that_belong_to_no_topic_are_not_numbered() {
    let turn = |user_parts: Vec<String>| Turn {
        id: "t0".into(),
        user_input: "one\n\ntwo".into(),
        timestamp: None,
        blocks: vec![],
        is_complete: false,
        user_parts,
        origin: None,
    };
    let unnumbered = [
        ServerMsg::Pong,
        ServerMsg::Error {
            message: "x".into(),
        },
        ServerMsg::Hosts { hosts: vec![] },
        ServerMsg::Devices {
            devices: vec![],
            hosts: vec![],
        },
        // The approval frames (the command-bearing ones never reach a ring).
        approval_request(),
        // Session frames, including a merged turn: they ride the connection's
        // own channel, not a topic.
        ServerMsg::SessionTurns {
            tag: "t".into(),
            turns: vec![turn(vec!["one".into(), "two".into()])],
        },
        // A Gap is about a number, so it has none.
        ServerMsg::Gap {
            topic: Topic::Perri,
            host: None,
            from: 1,
            to: 2,
            reason: GapReason::ClientSlow,
        },
    ];
    for frame in unnumbered {
        assert_eq!(
            frame.topic(),
            None,
            "{} must not be numbered",
            serde_json::to_value(&frame).unwrap()["type"]
        );
    }
}

#[test]
fn a_satellite_frame_is_numbered_in_the_topic_it_belongs_to_whatever_its_host() {
    let jobs = |host: Option<&str>| ServerMsg::MotherJobs {
        jobs: vec![],
        host: host.map(str::to_string),
    };
    let wire: Value = serde_json::to_value(jobs(Some("kobe"))).unwrap();
    assert_eq!(wire["host"], "kobe");
    assert_eq!(jobs(None).topic(), Some(Topic::MotherJobs));
    assert_eq!(jobs(Some("kobe")).topic(), Some(Topic::MotherJobs));
    assert_eq!(jobs(Some("sendai")).topic(), Some(Topic::MotherJobs));
}
