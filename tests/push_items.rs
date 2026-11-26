//! W13-30: what is waiting on the operator, derived from the snapshots the
//! primary sees.
//!
//! `tests/fixtures/push-items/mother_jobs.json` is the golden table: Mother jobs
//! on a host and the items they make. The same table is the contract of Kit's
//! `MotherNeedsYouProducer` (MC4), so one change updates both. Alongside it:
//! the derivation reads NO free-text field (every one is a marker here and none
//! survives into the derived items), only `bucket == "requested"` reviews are
//! items, and `MotherJob.paused_at` decodes leniently and stays off the wire when
//! absent.

use chrono::{DateTime, Duration, SecondsFormat, TimeZone, Utc};
use nostromo::data::perri_queue::PrQueueItem;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mother::MotherJob;
use nostromo::push::items::{
    decision_item, job_ref, mother_items, review_items, DecisionFacts, Detail, ItemKey,
    MotherReason, Waiting,
};
use nostromo::push::wire::{AgentClass, Presence, PushKind};
use serde_json::{json, Value};

// ── the golden table ─────────────────────────────────────────────────────────

fn fixture() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/push-items/mother_jobs.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("the golden table")).expect("json")
}

fn reason_name(r: MotherReason) -> &'static str {
    match r {
        MotherReason::Asked => "asked",
        MotherReason::BlockedAfterReview => "blocked_after_review",
        MotherReason::HeldAfterFailure => "held_after_failure",
        MotherReason::SpendCap => "spend_cap",
        MotherReason::PipelineBlocked => "pipeline_blocked",
        MotherReason::NeedsYou => "needs_you",
    }
}

fn rfc3339(t: DateTime<Utc>) -> String {
    t.to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// An item as the golden table writes it.
fn project(w: &Waiting) -> Value {
    match (&w.key, &w.detail) {
        (
            ItemKey::Mother { job_id, .. },
            Detail::Mother {
                job_ref,
                reason,
                repo,
                owner,
            },
        ) => json!({
            "item": "mother",
            "job_id": job_id,
            "job_ref": job_ref,
            "reason": reason_name(*reason),
            "repo": repo,
            "owner": owner,
            "start": w.start.map(rfc3339),
        }),
        (
            ItemKey::Attention {
                job_id,
                reason,
                since,
                ..
            },
            Detail::Attention,
        ) => json!({"item": "attention", "job_id": job_id, "reason": reason, "since": since}),
        other => panic!("not a Mother item: {other:?}"),
    }
}

fn jobs_of(case: &Value) -> Vec<MotherJob> {
    // Decoded the way the daemon decodes `mother list --format json`.
    let bytes = serde_json::to_vec(&case["jobs"]).unwrap();
    nostromo::mother::decode::parse_jobs(&bytes)
        .unwrap_or_else(|e| panic!("{}: {e:#}", case["name"]))
        .0
}

fn items_of(name: &str) -> Vec<Waiting> {
    let fx = fixture();
    let host = fx["host"].as_str().unwrap();
    let case = fx["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == name)
        .unwrap_or_else(|| panic!("no case {name}"));
    mother_items(host, &jobs_of(case))
}

#[test]
fn every_case_in_the_golden_table_derives_exactly_its_expected_items() {
    let fx = fixture();
    let host = fx["host"].as_str().unwrap();
    let cases = fx["cases"].as_array().unwrap();
    assert!(cases.len() >= 25, "the table shrank: {} cases", cases.len());
    let mut names = std::collections::BTreeSet::new();
    let mut wrong: Vec<String> = Vec::new();
    for case in cases {
        let name = case["name"].as_str().unwrap();
        assert!(names.insert(name), "duplicate case {name}");
        let jobs = jobs_of(case);
        assert_eq!(
            jobs.len(),
            case["jobs"].as_array().unwrap().len(),
            "{name}: a job in the table did not decode"
        );
        let items = mother_items(host, &jobs);
        let got = Value::Array(items.iter().map(project).collect());
        if got != case["expect"] {
            wrong.push(format!(
                "{name}: expected {} but derived {got}",
                case["expect"]
            ));
        }
        for w in &items {
            assert_eq!(w.host, host, "{name}");
        }
    }
    // Every case is checked before the test fails, so one report names them all.
    assert!(
        wrong.is_empty(),
        "derived items differ from the table:\n{}",
        wrong.join("\n")
    );
}

#[test]
fn a_progress_stalled_that_is_acked_and_raised_again_with_a_new_since_is_a_new_key() {
    let first = items_of("progress_stalled_first");
    let acked = items_of("progress_stalled_acked");
    let again = items_of("progress_stalled_reraised");
    assert_eq!(first.len(), 1);
    assert!(acked.is_empty(), "an acked reason leaves the waiting set");
    assert_eq!(again.len(), 1);
    assert_ne!(first[0].key, again[0].key, "a new `since` is a new item");
    // Same job, same reason: only `since` differs.
    match (&first[0].key, &again[0].key) {
        (
            ItemKey::Attention {
                job_id: a,
                reason: ra,
                since: sa,
                ..
            },
            ItemKey::Attention {
                job_id: b,
                reason: rb,
                since: sb,
                ..
            },
        ) => {
            assert_eq!((a, ra), (b, rb));
            assert_ne!(sa, sb);
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn the_same_snapshot_derives_the_same_keys_every_time() {
    for name in [
        "awaiting_user_question",
        "gates_incomplete_unacked",
        "several_jobs_keep_their_order_and_an_awaiting_job_with_attention_makes_both",
    ] {
        let a: Vec<ItemKey> = items_of(name).into_iter().map(|w| w.key).collect();
        let b: Vec<ItemKey> = items_of(name).into_iter().map(|w| w.key).collect();
        assert_eq!(a, b, "{name}");
        assert!(!a.is_empty());
    }
}

#[test]
fn an_awaiting_job_and_its_attention_reason_are_two_different_items() {
    let items =
        items_of("several_jobs_keep_their_order_and_an_awaiting_job_with_attention_makes_both");
    assert_eq!(items.len(), 3);
    assert!(!items[0].is_count_only());
    assert!(items[1].is_count_only());
    assert_ne!(items[0].key, items[1].key);
    // The per-kind switch of an attention item is the Mother one.
    assert_eq!(items[1].kind(), PushKind::Mother);
}

#[test]
fn a_job_ref_is_the_eight_lowercase_hex_suffix_or_nothing() {
    assert_eq!(
        job_ref("20261126T090000Z-3f9a1c2e").as_deref(),
        Some("3f9a1c2e")
    );
    for bad in [
        "20261126T090000Z-3F9A1C2E",
        "20261126T090000Z-3f9a1c2",
        "20261126T090000Z-3f9a1c2ee",
        "20261126T090000Z-zzzzzzzz",
        "20261126T090000Z-",
        "",
    ] {
        assert_eq!(job_ref(bad), None, "{bad:?}");
    }
}

// ── no free-text field is read ───────────────────────────────────────────────

/// A job in `state` whose every free-text field holds a marker.
fn marked(id: &str, state: &str, extra: Value) -> MotherJob {
    let mut v = json!({
        "id": id,
        "state": state,
        "title": "MARKER-title",
        "repo": "MARKER-repo",
        "isolation": "MARKER-isolation",
        "plan_path": "/MARKER-plan.md",
        "question": "MARKER-question",
        "adherence_notes": "MARKER-notes",
        "adherence_status": "MARKER-adherence-status",
        "current_tier": "MARKER-tier",
        "current_activity": "MARKER-current-activity",
        "failure_reason": "MARKER-failure",
        "kind": "MARKER-kind",
        "origin": {"label": "MARKER-label", "focus": "MARKER-focus", "focus_name": "MARKER-focus-name", "session": "MARKER-session"},
        "last_answer": {"source": "MARKER-source", "session": "MARKER-session", "agent": "MARKER-agent", "option": "MARKER-option", "at": "MARKER-at"},
        "gates": {"MARKER-gate": "MARKER-gate-state"},
        "progress": {"MARKER-progress": "MARKER-p"},
    });
    for (k, val) in extra.as_object().unwrap() {
        v[k] = val.clone();
    }
    serde_json::from_value(v).expect("a marked job")
}

fn assert_no_marker(what: &str, text: &str) {
    assert!(
        !text.to_ascii_lowercase().contains("marker"),
        "{what}: free text reached the derived items: {text}"
    );
}

#[test]
fn the_derivation_reads_no_free_text_field_of_a_mother_job() {
    let decision = json!({
        "id": "MARKER-decision-id", "kind": "MARKER-decision-kind", "opened_at": "2026-11-26T09:00:00Z",
        "options": [{"id": "MARKER-opt", "label": "MARKER-option-label", "consequence": "MARKER-consequence", "takes_text": true}],
    });
    let attention = json!([
        {"reason": "progress_stalled", "since": "2026-11-26T08:00:00Z", "acked": false},
        {"reason": "burn_ahead", "since": "2026-11-26T08:05:00Z", "acked": false},
        {"reason": "gates_incomplete", "since": "2026-11-26T08:10:00Z", "acked": false},
    ]);
    let jobs = vec![
        marked(
            "20261126T090000Z-3f9a1c2e",
            "awaiting",
            json!({"paused_reason": "user", "paused_at": "2026-11-26T09:58:00Z", "pr_url": "https://github.com/thehammer/bishop/pull/9"}),
        ),
        marked(
            "20261126T090000Z-3f9a1c2f",
            "awaiting",
            json!({"paused_reason": "adherence_blocked", "activity": "gate_hold"}),
        ),
        marked(
            "20261126T090000Z-3f9a1c30",
            "running",
            json!({"decision": decision, "attention_reasons": attention}),
        ),
        marked(
            "20261126T090000Z-3f9a1c31",
            "awaiting",
            json!({"paused_reason": "MARKER-future-reason", "activity": "MARKER-future-activity"}),
        ),
        marked(
            "20261126T090000Z-3f9a1c32",
            "awaiting",
            json!({"paused_reason": "user", "origin": {"label": "teri-send", "focus_name": "MARKER-focus-name"}}),
        ),
        marked(
            "20261126T090000Z-3f9a1c33",
            "awaiting",
            json!({"paused_reason": "quota_5h"}),
        ),
    ];
    let items = mother_items("kobe", &jobs);
    assert!(
        items.len() >= 7,
        "the derivation produced {} items",
        items.len()
    );
    assert_no_marker("Debug of the items", &format!("{items:?}"));
    for w in &items {
        assert_no_marker("key", &format!("{:?}", w.key));
        assert_no_marker("detail", &format!("{:?}", w.detail));
    }
}

#[test]
fn the_derivation_ignores_what_a_job_says_in_text_and_looks_only_at_its_state() {
    // Two jobs identical except for every free-text field: the same items.
    let plain: MotherJob = serde_json::from_value(json!({
        "id": "20261126T090000Z-3f9a1c2e", "state": "awaiting", "paused_reason": "user",
        "paused_at": "2026-11-26T09:58:00Z",
    }))
    .unwrap();
    let marked = marked(
        "20261126T090000Z-3f9a1c2e",
        "awaiting",
        json!({"paused_reason": "user", "paused_at": "2026-11-26T09:58:00Z"}),
    );
    let a = mother_items("kobe", &[plain]);
    let b = mother_items("kobe", &[marked]);
    assert_eq!(a, b);
}

#[test]
fn a_review_derivation_reads_no_free_text_field() {
    let queue: Vec<PrQueueItem> = (1..=4)
        .map(|n| PrQueueItem {
            repo: "Carefeed/admin-portal".into(),
            number: n,
            title: "MARKER-pr-title".into(),
            author: "MARKER-author".into(),
            bucket: "requested".into(),
            url: "https://github.com/MARKER-owner/MARKER-repo/pull/1".into(),
            head_sha: "MARKER-sha".into(),
            tickets: vec!["MARKER-ticket".into()],
            changed_lines: Some(n * 20),
            ..Default::default()
        })
        .collect();
    let items = review_items("kobe", &queue);
    assert_eq!(items.len(), 4);
    assert_no_marker("reviews", &format!("{items:?}"));
}

// ── reviews ──────────────────────────────────────────────────────────────────

fn pr(repo: &str, number: u64, bucket: &str, changed_lines: Option<u64>) -> PrQueueItem {
    PrQueueItem {
        repo: repo.into(),
        number,
        bucket: bucket.into(),
        changed_lines,
        ..Default::default()
    }
}

#[test]
fn only_a_pr_in_the_requested_bucket_is_a_review_item() {
    let queue = vec![
        pr("Carefeed/admin-portal", 1, "requested", None),
        pr("Carefeed/admin-portal", 2, "needs_review", None),
        pr("Carefeed/admin-portal", 3, "changes_req", None),
        pr("Carefeed/admin-portal", 4, "dependabot", None),
        pr("Carefeed/admin-portal", 5, "", None),
        pr("Carefeed/admin-portal", 6, "requested", None),
    ];
    let items = review_items("kobe", &queue);
    let numbers: Vec<u64> = items
        .iter()
        .map(|w| match &w.key {
            ItemKey::Review { number, .. } => *number,
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(numbers, vec![1, 6]);
}

#[test]
fn a_review_carries_its_changed_lines_number_repo_and_owner() {
    let queue = vec![
        pr("Carefeed/admin-portal", 4821, "requested", Some(49)),
        pr("thehammer/bishop", 212, "requested", None),
        pr("bare-name", 7, "requested", Some(400)),
        pr("/leading-slash", 8, "requested", Some(401)),
    ];
    let items = review_items("kobe", &queue);
    let details: Vec<(u64, Option<u64>, String, Option<String>)> = items
        .iter()
        .map(|w| match &w.detail {
            Detail::Review {
                number,
                changed_lines,
                repo,
                owner,
            } => (*number, *changed_lines, repo.clone(), owner.clone()),
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(
        details,
        vec![
            (
                4821,
                Some(49),
                "admin-portal".into(),
                Some("Carefeed".into())
            ),
            (212, None, "bishop".into(), Some("thehammer".into())),
            // A name with no owner has an unknown owner (a work owner for the rule).
            (7, Some(400), "bare-name".into(), None),
            (8, Some(401), "leading-slash".into(), None),
        ]
    );
    // The key names the host and the full repository, so two repositories'
    // PR #4821 are two items.
    assert_eq!(
        items[0].key,
        ItemKey::Review {
            host: "kobe".into(),
            repo: "Carefeed/admin-portal".into(),
            number: 4821
        }
    );
    assert_eq!(items[0].kind(), PushKind::Review);
    assert!(!items[0].is_count_only());
}

#[test]
fn the_same_pr_number_in_two_repositories_is_two_items() {
    let queue = vec![
        pr("Carefeed/admin-portal", 7, "requested", None),
        pr("Carefeed/referral-monitor", 7, "requested", None),
    ];
    let items = review_items("kobe", &queue);
    assert_eq!(items.len(), 2);
    assert_ne!(items[0].key, items[1].key);
}

// ── decisions ────────────────────────────────────────────────────────────────

#[test]
fn a_decision_item_carries_its_closed_facts_and_starts_when_it_was_raised() {
    let raised = Utc.with_ymd_and_hms(2026, 11, 26, 9, 0, 0).unwrap();
    let deadline = raised + Duration::minutes(5);
    let facts = DecisionFacts {
        request_id: "req-1".into(),
        choices: 3,
        deadline: Some(deadline),
        agent: Some(AgentClass::Claudia),
        presence: Some(Presence::Away),
        repo: Some("bishop".into()),
        owner: Some("thehammer".into()),
    };
    let w = decision_item("kobe", &facts, raised);
    assert_eq!(
        w.key,
        ItemKey::Decision {
            host: "kobe".into(),
            request_id: "req-1".into()
        }
    );
    assert_eq!(w.start, Some(raised));
    assert_eq!(w.kind(), PushKind::Decision);
    assert_eq!(
        w.detail,
        Detail::Decision {
            agent: AgentClass::Claudia,
            choices: 3,
            deadline: Some(deadline),
            presence: Some(Presence::Away),
            repo: Some("bishop".into()),
            owner: Some("thehammer".into()),
        }
    );
    // An agent the originating daemon did not classify is "A session".
    let unclassified = decision_item(
        "kobe",
        &DecisionFacts {
            agent: None,
            ..facts
        },
        raised,
    );
    assert!(matches!(
        unclassified.detail,
        Detail::Decision {
            agent: AgentClass::Other,
            ..
        }
    ));
}

// ── MotherJob.paused_at ──────────────────────────────────────────────────────

fn job_with(paused_at: Value) -> MotherJob {
    let mut v = json!({"id": "20261126T090000Z-3f9a1c2e", "state": "awaiting"});
    v["paused_at"] = paused_at;
    serde_json::from_value(v).expect("a malformed paused_at never costs the job")
}

#[test]
fn paused_at_decodes_a_timestamp_and_reads_anything_else_as_none() {
    let want = Utc.with_ymd_and_hms(2026, 11, 26, 9, 58, 0).unwrap();
    assert_eq!(
        job_with(json!("2026-11-26T09:58:00Z")).paused_at,
        Some(want)
    );
    assert_eq!(
        job_with(json!("2026-11-26T03:58:00-06:00")).paused_at,
        Some(want)
    );
    for bad in [
        json!(null),
        json!("yesterday"),
        json!(""),
        json!(12345),
        json!(true),
        json!({"at": "2026-11-26T09:58:00Z"}),
        json!(["2026-11-26T09:58:00Z"]),
    ] {
        let job = job_with(bad.clone());
        assert_eq!(job.paused_at, None, "{bad}");
        assert_eq!(job.state, "awaiting", "{bad}: the job survives");
    }
    // Absent altogether is none too.
    let job: MotherJob =
        serde_json::from_value(json!({"id": "20261126T090000Z-3f9a1c2e", "state": "awaiting"}))
            .unwrap();
    assert_eq!(job.paused_at, None);
}

#[test]
fn paused_at_is_off_the_wire_when_none_and_on_it_when_set() {
    let none: MotherJob =
        serde_json::from_value(json!({"id": "20261126T090000Z-3f9a1c2e", "state": "awaiting"}))
            .unwrap();
    let v = serde_json::to_value(&none).unwrap();
    assert!(v.get("paused_at").is_none(), "{v}");

    let set = job_with(json!("2026-11-26T09:58:00Z"));
    let v = serde_json::to_value(&set).unwrap();
    assert!(v.get("paused_at").is_some(), "{v}");
    let back: MotherJob = serde_json::from_value(v).unwrap();
    assert_eq!(back.paused_at, set.paused_at);
}

#[test]
fn the_existing_mother_contract_frames_still_decode_and_reencode_without_inventing_paused_at() {
    // `paused_at` is read leniently and written only when Mother sent it: a frame that
    // had it keeps it (the vendored hold fixture does), and no frame gains it.
    for name in [
        "ipc_mother_jobs.golden.json",
        "ipc_mother_jobs_plain.golden.json",
    ] {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/mother-contract")
            .join(name);
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
        let msg: ServerMsg = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        let original: Value = serde_json::from_str(&text).unwrap();
        let had: Vec<bool> = original["jobs"]
            .as_array()
            .unwrap()
            .iter()
            .map(|j| j.get("paused_at").is_some_and(|v| !v.is_null()))
            .collect();
        match &msg {
            ServerMsg::MotherJobs { jobs, .. } => {
                assert!(!jobs.is_empty(), "{name}");
                let has: Vec<bool> = jobs.iter().map(|j| j.paused_at.is_some()).collect();
                assert_eq!(
                    has, had,
                    "{name}: paused_at must decode exactly where it was sent"
                );
            }
            other => panic!("{name}: {other:?}"),
        }
        let again = serde_json::to_string_pretty(&msg).unwrap();
        assert_eq!(
            again.matches("paused_at").count(),
            text.matches("paused_at").count(),
            "{name}: a key appeared in, or vanished from, an old frame"
        );
    }
}

#[test]
fn a_job_list_from_mother_that_has_paused_at_keeps_it_through_the_tolerant_decoder() {
    let text = json!([
        {"id": "20261126T090000Z-3f9a1c2e", "state": "awaiting", "paused_at": "2026-11-26T09:58:00Z"},
        {"id": "20261126T090000Z-3f9a1c2f", "state": "awaiting", "paused_at": "not a time"},
    ])
    .to_string();
    let (jobs, skipped) = nostromo::mother::decode::parse_jobs(text.as_bytes()).unwrap();
    assert_eq!(skipped, 0);
    assert_eq!(jobs.len(), 2);
    assert_eq!(
        jobs[0].paused_at,
        Some(Utc.with_ymd_and_hms(2026, 11, 26, 9, 58, 0).unwrap())
    );
    assert_eq!(jobs[1].paused_at, None);
}
