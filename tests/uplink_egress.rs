//! W10 egress contract: what may leave a satellite host, and what a satellite
//! relays to a personal peer.
//!
//! * W10-2  `work` egress: only fixed-vocabulary metadata leaves the host. Every
//!   free-text field of every allowed frame carries a planted marker; none may
//!   survive `redact_for_uplink_metadata`, and the result must satisfy
//!   `is_uplink_metadata_shape`.
//! * W10-8  `personal` egress: the ordinary network-peer policy (`outbound` for
//!   `PeerTrust::Tcp`) still applies, `redact_for_network` is idempotent and
//!   keeps `host`.
//! * W10-16 Mother's real HC-09 shape (the vendored golden frame) goes through
//!   the metadata redaction without losing its metadata or leaking its text.
//! * W10-18 the redaction match stays exhaustive: a new `ServerMsg` variant
//!   cannot be added without a decision about whether it may leave a work host.
//!
//! Frames are built from JSON (the wire form) so the tests do not depend on
//! how the Rust types are laid out.

#![recursion_limit = "512"]

use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::teri_todos::TeriTodosSnapshot;
use nostromo::data::work::{PicksSnapshot, SourceState, SourceStatus, WorkResult, WorkSource};
use nostromo::ipc::peer::{
    classify_server_msg, is_uplink_metadata_shape, may_receive, outbound, redact_for_network,
    redact_for_uplink_metadata as redact_with_tags, PeerTrust, SensitiveTags, ServerClass,
};
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::uplink_redact::pseudonymous_tag;
use regex::Regex;
use serde_json::{json, Value};

const KEY: [u8; 32] = [7u8; 32];
const HOST: &str = "kobe";
const PROTOCOL_SRC: &str = include_str!("../src/ipc/protocol.rs");
const REDACT_SRC: &str = include_str!("../src/ipc/uplink_redact.rs");

/// The redaction with an empty sensitive-tag list: nothing is sensitive.
fn redact_for_uplink_metadata(msg: ServerMsg, key: &[u8; 32]) -> Option<ServerMsg> {
    redact_with_tags(msg, key, &SensitiveTags::in_memory())
}

fn mk(field: &str) -> String {
    format!("SECRET-MARKER-{field}")
}

fn frame(v: Value) -> ServerMsg {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("decode {v}: {e}"))
}

fn json_of(m: &ServerMsg) -> String {
    serde_json::to_string(m).unwrap()
}

/// Every `secret-marker-<field>` still present in `json` (case-insensitive).
fn leaked(json: &str) -> Vec<String> {
    Regex::new(r"(?i)secret-marker-[a-z0-9_]+")
        .unwrap()
        .find_iter(json)
        .map(|m| m.as_str().to_string())
        .collect()
}

fn is_hex8(s: &str) -> bool {
    Regex::new(r"^[0-9a-f]{8}$").unwrap().is_match(s)
}

/// Every string value under a key named `key`, at any depth.
fn values_under_key<'a>(v: &'a Value, key: &str, out: &mut Vec<&'a str>) {
    match v {
        Value::Object(o) => {
            for (k, child) in o {
                if k == key {
                    if let Some(s) = child.as_str() {
                        out.push(s);
                    }
                }
                values_under_key(child, key, out);
            }
        }
        Value::Array(a) => a.iter().for_each(|c| values_under_key(c, key, out)),
        _ => {}
    }
}

// ── frames carrying a marker in every text field ─────────────────────────────

fn focus_meta(tag: &str) -> Value {
    json!({
        "tag": mk(tag),
        "display_name": mk("display_name"),
        "agent_name": mk("agent_name"),
        "project_name": mk("project_name"),
        "org": mk("org"),
        "is_built_in": false,
        "session_summary": mk("session_summary"),
        "label": mk("label"),
        "project_path": mk("project_path"),
        "select_for_client": mk("select_for_client"),
        "initial_model": mk("initial_model"),
        "initial_effort": mk("initial_effort"),
        "no_codebase": true
    })
}

fn session_info() -> Value {
    json!({
        "tag": mk("session_tag"),
        "agent_name": mk("session_agent_name"),
        "view_name": mk("view_name"),
        "session_id": mk("session_id"),
        "alive": true,
        "remote_control": false,
        "state": "mid_turn",
        "mcp_bridge_connected": true,
        "agent_turns": 4,
        "agent_messages": 5,
        "agent_problems": 1,
        "activity_epoch": mk("activity_epoch")
    })
}

fn marker_job() -> Value {
    let phase = json!({
        "agent": mk("phase_agent"), "request_type": mk("phase_request_type"),
        "state": mk("phase_state"), "started_at": null, "finished_at": null, "findings": 3
    });
    json!({
        "id": mk("job_id"),
        "state": mk("state"),
        "repo": mk("repo"),
        "isolation": mk("isolation"),
        "title": mk("title"),
        "created_at": "2026-10-18T11:00:00Z",
        "started_at": "2026-10-18T11:01:40Z",
        "finished_at": null,
        "plan_path": mk("plan_path"),
        "question": mk("question"),
        "paused_reason": mk("paused_reason"),
        "adherence_notes": mk("adherence_notes"),
        "adherence_status": mk("adherence_status"),
        "current_tier": mk("current_tier"),
        "current_activity": mk("current_activity"),
        "kind": mk("kind"),
        "phases": [phase.clone()],
        "cycles": [{"cycle": 1, "phases": [phase]}],
        "origin": {"label": mk("origin_label")},
        "nostromo": {"origin": {
            "kind": "focus", "focus_tag": mk("origin_focus_tag"),
            "name_snapshot": mk("name_snapshot"), "focus_name": mk("origin_focus_name"),
            "session_prefix": mk("session_prefix")
        }},
        "failure_reason": mk("failure_reason"),
        "actual_cost_usd": 1.5,
        "activity": mk("activity"),
        "pr_url": format!("https://example.com/{}", mk("pr_url")),
        "crew_opt_in": true,
        "gates": {
            "mode": mk("gates_mode"), "posture": mk("gates_posture"), "status": mk("gates_status"),
            "attempt": 1, "max_attempts": 3, "head_sha": mk("head_sha"),
            "started_at": "2026-10-18T11:01:42.000Z", "finished_at": "2026-10-18T11:06:40.000Z",
            "results": [
                {"name": mk("gate_name"), "result": mk("gate_result"), "blocking": true,
                 "duration_s": 1, "exit_code": 1, "unavailable_reason": mk("unavailable_reason")}
            ],
            "not_run": [mk("not_run")]
        },
        "review_wave": {
            "mode": mk("wave_mode"), "cycle": 1, "cycle_cap": 2, "status": mk("wave_status"),
            "budget_usd": 3.0, "spent_usd": 1.0,
            "lenses": [{
                "reviewer": mk("lens_reviewer"), "lens": mk("lens_name"), "state": mk("lens_state"),
                "skip_reason": mk("lens_skip_reason"),
                "findings": {"blocking": 2, "advisory": 3}, "cost_usd": 0.5, "examined_files": 4
            }],
            "adherence": {"state": mk("adherence_state"), "verdict": mk("adherence_verdict")},
            "coverage_gaps": 1,
            "claims": {"verified": 1, "refuted": 2, "unverified": 3}
        },
        "decision": {
            "id": mk("decision_id"), "kind": mk("decision_kind"),
            "options": [{"id": mk("option_id"), "label": mk("option_label"),
                         "consequence": mk("option_consequence"), "takes_text": true}],
            "opened_at": "2026-10-18T11:08:20.000Z", "resolved_at": null,
            "resolution": {"option": mk("resolution_option"), "source": mk("resolution_source"),
                           "at": "2026-10-18T11:09:00.000Z"}
        },
        "attention": [{"reason": mk("attention_reason"), "since": "2026-10-18T11:10:00.000Z", "acked": null}],
        "attention_reasons": [{"reason": mk("attention_reasons_reason"), "since": "2026-10-18T11:10:00.000Z", "acked": false}],
        "last_answer": {"source": mk("answer_source"), "session": mk("answer_session"),
                        "agent": mk("answer_agent"), "option": mk("answer_option"),
                        "at": "2026-10-18T11:11:00.000Z"},
        "progress": {
            "v": 1, "pct": 80, "label": mk("progress_label"), "stage": mk("progress_stage"),
            "signals": {"stage": mk("signals_stage"), "gates": {"passed": 4, "failed": 1, "total": 5},
                        "elapsed_active_s": 120, "cost": 2.5},
            "eta": {"lo_s": 10, "hi_s": 20, "label": mk("eta_label"), "basis": mk("eta_basis")},
            "paused": true,
            "moved_back": {"reason": mk("moved_back_reason"), "at": "2026-10-18T11:12:00.000Z"},
            "flags": [{"reason": mk("flag_reason"), "since": "2026-10-18T11:12:30.000Z"}],
            "updated_at": "2026-10-18T11:13:21.000Z"
        },
        "criteria_source": mk("criteria_source")
    })
}

fn work_send_job() -> Value {
    let mut j = marker_job();
    j["id"] = json!("a1b2c3d4");
    j["title"] = json!(mk("work_send_title"));
    j["origin"] = json!({"label": "teri-send"});
    j
}

/// Every frame a work satellite may publish, each with a marker in every text
/// field (and `host` set). The `&str` is the variant's wire name.
fn allowed_frames() -> Vec<(&'static str, ServerMsg)> {
    vec![
        (
            "mother_jobs",
            frame(json!({"type": "mother_jobs", "host": HOST,
                         "jobs": [marker_job(), work_send_job()]})),
        ),
        (
            "mother_statusline",
            frame(
                json!({"type": "mother_statusline", "running": 1, "queued": 2, "failed": 3,
                         "awaiting": 4, "host": HOST}),
            ),
        ),
        (
            "perri_state",
            frame(
                json!({"type": "perri_state", "tag": mk("perri_tag"), "host": HOST,
                "jira_site": mk("jira_site"),
                "queue": [{"repo": mk("pr_repo"), "number": 42, "title": mk("pr_title"),
                           "author": mk("pr_author"), "bucket": mk("pr_bucket"),
                           "new_activity": true, "url": format!("https://example.com/{}", mk("pr_url")),
                           "head_sha": mk("pr_head_sha"), "is_bot": true,
                           "tickets": [mk("pr_ticket")]}],
                "current": null}),
            ),
        ),
        (
            "session_state",
            frame(
                json!({"type": "session_state", "tag": mk("state_tag"), "state": "idle", "host": HOST}),
            ),
        ),
        (
            "session_bridge",
            frame(
                json!({"type": "session_bridge", "tag": mk("bridge_tag"), "connected": true, "host": HOST}),
            ),
        ),
        (
            "session_list_resp",
            frame(json!({"type": "session_list_resp", "sessions": [session_info()], "host": HOST})),
        ),
        (
            "focus_list_resp",
            frame(
                json!({"type": "focus_list_resp", "focuses": [focus_meta("list_tag")], "host": HOST}),
            ),
        ),
        (
            "focus_registry_updated",
            frame(
                json!({"type": "focus_registry_updated", "focuses": [focus_meta("reg_tag")], "host": HOST}),
            ),
        ),
        (
            "focus_created",
            frame(
                json!({"type": "focus_created", "meta": focus_meta("created_tag"), "host": HOST}),
            ),
        ),
        (
            "approval_pending",
            frame(
                json!({"type": "approval_pending", "tag": mk("approval_tag"), "count": 3, "host": HOST}),
            ),
        ),
        (
            "decision_request",
            // `request_id` is an identifier, not text: the redaction keeps a
            // well-formed one, so it carries no marker.
            frame(
                json!({"type": "decision_request", "tag": mk("decision_tag"), "request_id": "req-1",
                "prompt": mk("prompt"), "detail": mk("detail"), "context_pane_id": mk("context_pane_id"),
                "choices": [
                    {"id": mk("choice_id_a"), "label": mk("choice_label_a"), "detail": mk("choice_detail_a"), "is_default": true},
                    {"id": mk("choice_id_b"), "label": mk("choice_label_b"), "detail": mk("choice_detail_b")}
                ], "host": HOST}),
            ),
        ),
        (
            "decision_resolved",
            frame(
                json!({"type": "decision_resolved", "tag": mk("resolved_tag"), "request_id": "req-1",
                "resolution": "answered", "choice_id": mk("resolved_choice_id"), "host": HOST}),
            ),
        ),
        (
            "tracker_summary",
            frame(
                json!({"type": "tracker_summary", "tag": mk("tracker_tag"), "has_tracker": true,
                "counts": {"todo": 1, "in_progress": 2, "blocked": 3, "needs_you": 4, "done": 5},
                "host": HOST}),
            ),
        ),
    ]
}

#[test]
fn work_egress_every_allowed_frame_loses_all_free_text() {
    for (name, input) in allowed_frames() {
        let before = json_of(&input);
        // A statusline is four counts and a host: it has no text to plant.
        assert!(
            name == "mother_statusline" || !leaked(&before).is_empty(),
            "{name}: the fixture frame must carry markers (decoder dropped them all?)"
        );
        let out = redact_for_uplink_metadata(input, &KEY)
            .unwrap_or_else(|| panic!("{name}: an allowed frame must be published"));
        let after = json_of(&out);
        assert!(
            leaked(&after).is_empty(),
            "{name}: free text leaked: {:?}\n{after}",
            leaked(&after)
        );
        assert!(
            is_uplink_metadata_shape(&out),
            "{name}: output fails the shape check\n{after}"
        );
    }
}

#[test]
fn work_egress_marker_planted_in_each_job_field_is_gone_per_field() {
    // The per-field variant of the test above, for the richest frame, so a
    // failure names the field. The job fields are listed explicitly: a marker
    // the decoder itself dropped would otherwise make this vacuous.
    let input = allowed_frames().remove(0).1;
    let before = json_of(&input);
    for field in [
        "title",
        "repo",
        "isolation",
        "plan_path",
        "question",
        "adherence_notes",
        "adherence_status",
        "current_tier",
        "current_activity",
        "kind",
        "phase_agent",
        "phase_request_type",
        "phase_state",
        "origin_label",
        "origin_focus_tag",
        "name_snapshot",
        "origin_focus_name",
        "session_prefix",
        "failure_reason",
        "pr_url",
        "gates_mode",
        "gates_posture",
        "head_sha",
        "gate_name",
        "unavailable_reason",
        "not_run",
        "wave_mode",
        "lens_reviewer",
        "lens_name",
        "lens_skip_reason",
        "adherence_state",
        "adherence_verdict",
        "decision_id",
        "option_id",
        "option_label",
        "option_consequence",
        "resolution_option",
        "resolution_source",
        "answer_source",
        "answer_session",
        "answer_agent",
        "answer_option",
        "progress_label",
        "eta_label",
        "moved_back_reason",
        "criteria_source",
    ] {
        let needle = format!("secret-marker-{field}\"");
        assert!(
            before.to_lowercase().contains(&needle),
            "fixture sanity: the decoded job lost its `{field}` marker before redaction"
        );
    }
    let after = json_of(&redact_for_uplink_metadata(input, &KEY).unwrap()).to_lowercase();
    for field in [
        "title",
        "repo",
        "plan_path",
        "question",
        "head_sha",
        "gate_name",
        "option_label",
        "option_consequence",
        "progress_label",
        "eta_label",
        "pr_url",
        "failure_reason",
    ] {
        assert!(
            !after.contains(&format!("secret-marker-{field}")),
            "{field} leaked: {after}"
        );
    }
}

#[test]
fn work_egress_vocabulary_fields_fall_back_to_other_for_unknown_words() {
    let out = redact_for_uplink_metadata(allowed_frames().remove(0).1, &KEY).unwrap();
    let v: Value = serde_json::to_value(&out).unwrap();
    let job = &v["jobs"][0];
    assert_eq!(job["state"], "other");
    assert_eq!(job["paused_reason"], "other");
    assert_eq!(job["activity"], "other");
    assert_eq!(job["gates"]["results"][0]["result"], "other");
    assert_eq!(job["decision"]["kind"], "other");
    assert_eq!(job["progress"]["stage"], "other");
    assert_eq!(job["progress"]["eta"]["basis"], "other");
    // Counts are numbers, not text, and survive.
    assert_eq!(job["progress"]["pct"], 80);
    assert_eq!(
        job["review_wave"]["lenses"][0]["findings"],
        json!({"blocking": 2, "advisory": 3})
    );
}

#[test]
fn work_egress_tags_are_opaque_job_ids_are_short_hex_and_host_is_carried() {
    let tag_re = Regex::new(r"^f-[0-9a-f]{8}$").unwrap();
    for (name, input) in allowed_frames() {
        let out = redact_for_uplink_metadata(input, &KEY).unwrap();
        let v = serde_json::to_value(&out).unwrap();

        let mut tags = vec![];
        values_under_key(&v, "tag", &mut tags);
        for t in &tags {
            assert!(tag_re.is_match(t), "{name}: tag {t:?} is not f-<8 hex>");
        }
        if matches!(
            name,
            "perri_state"
                | "session_state"
                | "session_bridge"
                | "session_list_resp"
                | "focus_list_resp"
                | "focus_registry_updated"
                | "focus_created"
                | "approval_pending"
                | "decision_request"
                | "decision_resolved"
                | "tracker_summary"
        ) {
            assert!(
                !tags.is_empty(),
                "{name}: expected at least one tag in the output"
            );
        }

        if let Some(jobs) = v.get("jobs").and_then(Value::as_array) {
            for j in jobs {
                let id = j["id"].as_str().unwrap();
                assert!(is_hex8(id), "{name}: job id {id:?} is not 8 lower-hex");
            }
        }

        assert_eq!(
            v["host"], HOST,
            "{name}: host must be carried through unchanged"
        );
    }
}

#[test]
fn work_egress_tags_are_stable_per_key_and_differ_between_keys() {
    let f = || {
        allowed_frames()
            .into_iter()
            .find(|(n, _)| *n == "session_state")
            .unwrap()
            .1
    };
    let a = serde_json::to_value(redact_for_uplink_metadata(f(), &KEY).unwrap()).unwrap();
    let b = serde_json::to_value(redact_for_uplink_metadata(f(), &KEY).unwrap()).unwrap();
    let c = serde_json::to_value(redact_for_uplink_metadata(f(), &[9u8; 32]).unwrap()).unwrap();
    assert_eq!(a["tag"], b["tag"], "same host key, same tag");
    assert_ne!(
        a["tag"], c["tag"],
        "a different host key must not give the same pseudonym"
    );
}

#[test]
fn work_egress_frames_without_a_host_keep_none() {
    let out = redact_for_uplink_metadata(
        frame(json!({"type": "approval_pending", "tag": "x", "count": 1})),
        &KEY,
    )
    .unwrap();
    assert!(serde_json::to_value(&out).unwrap().get("host").is_none());
}

#[test]
fn work_egress_decision_choices_keep_only_their_number() {
    let out = redact_for_uplink_metadata(
        allowed_frames()
            .into_iter()
            .find(|(n, _)| *n == "decision_request")
            .unwrap()
            .1,
        &KEY,
    )
    .unwrap();
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(
        v["choices"].as_array().unwrap().len(),
        2,
        "the number of choices is metadata"
    );
    assert_eq!(v["request_id"], "req-1");
    assert_eq!(v["prompt"], "");
}

#[test]
fn work_egress_drops_jobs_queued_from_a_work_item() {
    let out = redact_for_uplink_metadata(allowed_frames().remove(0).1, &KEY).unwrap();
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(
        v["jobs"].as_array().unwrap().len(),
        1,
        "the teri-send job is not published"
    );
}

#[test]
fn work_egress_refuses_a_decision_with_a_request_id_that_could_carry_text() {
    let m = frame(
        json!({"type": "decision_request", "tag": "t", "request_id": "has spaces and text",
        "prompt": "p", "choices": []}),
    );
    assert!(redact_for_uplink_metadata(m, &KEY).is_none());
    let m = frame(
        json!({"type": "decision_resolved", "tag": "t", "request_id": "",
        "resolution": "answered"}),
    );
    assert!(redact_for_uplink_metadata(m, &KEY).is_none());
}

// ── frames that never leave a work host ──────────────────────────────────────

fn source_status() -> SourceStatus {
    SourceStatus {
        source: WorkSource::Jira,
        state: SourceState::Fresh,
        updated_at: None,
        reason: None,
        retry_at: None,
        count: 0,
        group_errors: vec![],
        complete: false,
    }
}

fn pair_and_admin_frames() -> Vec<(&'static str, ServerMsg)> {
    let device = json!({"id": mk("dev"), "name": mk("dev_name"), "kind": "satellite",
        "paired_at": "2026-10-18T11:00:00Z"});
    vec![
        (
            "pair_offer",
            frame(json!({"type": "pair_offer", "server_id": "s", "challenge": "c"})),
        ),
        (
            "paired",
            frame(
                json!({"type": "paired", "device_id": "d", "token": "t", "name": "n", "server_id": "s"}),
            ),
        ),
        (
            "pair_refused",
            frame(json!({"type": "pair_refused", "reason": "expired"})),
        ),
        (
            "unauthorized",
            frame(json!({"type": "unauthorized", "reason": "r"})),
        ),
        ("device_unpaired", frame(json!({"type": "device_unpaired"}))),
        (
            "device_pairing",
            frame(
                json!({"type": "device_pairing", "request_id": "r", "pairing_id": "p",
            "code": "123456", "server_url": "ws://x", "expires_at": "2026-10-18T11:00:00Z"}),
            ),
        ),
        (
            "device_pair_outcome",
            frame(json!({"type": "device_pair_outcome", "pairing_id": "p", "outcome": "paired"})),
        ),
        (
            "devices",
            frame(json!({"type": "devices", "devices": [device.clone()], "hosts": [device]})),
        ),
        (
            "device_revoked",
            frame(
                json!({"type": "device_revoked", "request_id": "r", "device_id": "d", "was_connected": true}),
            ),
        ),
        (
            "device_admin_error",
            frame(json!({"type": "device_admin_error", "request_id": "r", "reason": "no"})),
        ),
        (
            "hosts",
            frame(
                json!({"type": "hosts", "hosts": [{"name": "kobe", "egress": "work",
            "connected_since": "2026-10-18T11:00:00Z", "last_seen": "2026-10-18T11:00:00Z"}]}),
            ),
        ),
        (
            "host_unavailable",
            frame(json!({"type": "host_unavailable", "host": "kobe", "reason": "busy"})),
        ),
        (
            "device_admin_level",
            frame(json!({"type": "device_admin_level", "level": "full", "pair_from": ["kobe"]})),
        ),
    ]
}

fn dropped_frames() -> Vec<(&'static str, ServerMsg)> {
    let mut v = pair_and_admin_frames();
    v.extend([
        (
            "welcome",
            frame(json!({"type": "welcome", "protocol_version": 1, "daemon_pid": 1})),
        ),
        ("pong", frame(json!({"type": "pong"}))),
        (
            "error",
            frame(json!({"type": "error", "message": mk("error")})),
        ),
        (
            "activity",
            frame(
                json!({"type": "activity", "ts": "2026-10-18T11:00:00Z", "agent": "cody",
            "kind": "tool", "summary": mk("activity_summary"), "focus_tag": mk("activity_tag"),
            "cwd": mk("cwd"), "host": HOST}),
            ),
        ),
        (
            "mother_await_detected",
            frame(json!({"type": "mother_await_detected", "id": "a1b2c3d4",
            "state": "awaiting", "title": mk("await_title"), "question": mk("await_question")})),
        ),
        (
            "mother_peek",
            frame(
                json!({"type": "mother_peek", "job_id": "a1b2c3d4", "todos": [],
            "tool_trail": [], "last_text": mk("peek_text")}),
            ),
        ),
        (
            "session_summary_update",
            frame(json!({"type": "session_summary_update", "tag": "t",
            "summary": mk("summary")})),
        ),
        (
            "session_exited",
            frame(json!({"type": "session_exited", "tag": "t", "exit_code": 0})),
        ),
        (
            "notification",
            frame(json!({"type": "notification", "tag": "t", "level": "info",
            "message": mk("notification")})),
        ),
        (
            "pane_action_result",
            frame(
                json!({"type": "pane_action_result", "tag": "t", "pane_id": "p",
            "action_id": "a", "ok": true, "message": mk("pane_message")}),
            ),
        ),
        (
            "withheld",
            frame(json!({"type": "withheld", "topics": ["fred"], "reason": "not_shared"})),
        ),
        (
            "activity_health",
            frame(json!({"type": "activity_health", "ingesting": true,
            "hook_installed": true})),
        ),
        (
            "model_catalog",
            frame(json!({"type": "model_catalog", "families": [], "stale": false})),
        ),
        (
            "teri_state",
            ServerMsg::TeriState {
                todos: TeriTodosSnapshot::default(),
            },
        ),
        (
            "fred_state",
            ServerMsg::FredState {
                mailbox: MailboxSnapshot::default(),
                calendar: CalendarSnapshot::default(),
            },
        ),
        (
            "work_source_status",
            ServerMsg::WorkSourceStatus {
                status: source_status(),
            },
        ),
        (
            "work_snapshot",
            ServerMsg::WorkSnapshot {
                source: WorkSource::Todos,
                group: None,
                items: vec![],
            },
        ),
        (
            "teri_picks",
            ServerMsg::TeriPicks {
                picks: PicksSnapshot::default(),
            },
        ),
        (
            "work_detail",
            ServerMsg::WorkDetail {
                request_id: "r".into(),
                result: WorkResult::err("x", "y"),
            },
        ),
    ]);
    v
}

#[test]
fn work_egress_withholds_everything_that_is_not_fixed_vocabulary_metadata() {
    for (name, msg) in dropped_frames() {
        assert!(
            redact_for_uplink_metadata(msg.clone(), &KEY).is_none(),
            "{name}: must never leave a work host"
        );
        assert!(
            !is_uplink_metadata_shape(&msg),
            "{name}: is not a metadata shape"
        );
    }
}

#[test]
fn work_egress_pairing_and_admin_frames_are_not_published_even_by_a_satellite() {
    // The thirteen frames named by the plan: the ten W9 pairing/device frames
    // plus Hosts, HostUnavailable and DeviceAdminLevel.
    let names: Vec<&str> = pair_and_admin_frames().iter().map(|(n, _)| *n).collect();
    assert_eq!(names.len(), 13);
    for (name, msg) in pair_and_admin_frames() {
        assert!(redact_for_uplink_metadata(msg, &KEY).is_none(), "{name}");
    }
}

#[test]
fn metadata_shape_rejects_frames_that_still_carry_text() {
    // The primary runs the shape check on what a work satellite *sent*: raw
    // frames must not pass it.
    for (name, input) in allowed_frames() {
        if matches!(
            name,
            "mother_statusline"
                | "session_state"
                | "session_bridge"
                | "tracker_summary"
                | "approval_pending"
                | "decision_resolved"
        ) {
            // Pure tag-and-number frames: a raw tag is the only thing to reject.
            let raw_tag_rejected = !is_uplink_metadata_shape(&input);
            if name == "mother_statusline" {
                assert!(!raw_tag_rejected, "a statusline has no text to carry");
            } else {
                assert!(
                    raw_tag_rejected,
                    "{name}: a raw (non f-) tag must fail the shape check"
                );
            }
            continue;
        }
        assert!(
            !is_uplink_metadata_shape(&input),
            "{name}: raw frame must fail the shape check"
        );
    }
}

/// Set every string under `key`, at any depth, to `bad`; returns how many.
fn overwrite_key(v: &mut Value, key: &str, bad: &str) -> usize {
    let mut n = 0;
    match v {
        Value::Object(map) => {
            for (k, child) in map.iter_mut() {
                if k == key && child.is_string() {
                    *child = json!(bad);
                    n += 1;
                } else {
                    n += overwrite_key(child, key, bad);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                n += overwrite_key(item, key, bad);
            }
        }
        _ => {}
    }
    n
}

#[test]
fn metadata_shape_accepts_what_redaction_makes_and_rejects_any_other_tag_ref_or_request_id_format()
{
    // Controls first: every redacted frame passes, so a rejection below is
    // down to the one field we spoiled and nothing else.
    let mut exercised = std::collections::BTreeMap::<&str, usize>::new();
    for (name, input) in allowed_frames() {
        let redacted = redact_for_uplink_metadata(input, &KEY).expect(name);
        assert!(is_uplink_metadata_shape(&redacted), "{name}: control");
        let base = serde_json::to_value(&redacted).unwrap();

        // Tags: `f-` plus exactly eight lower-case hex.
        for bad in [
            "",
            "f-",
            "f-abc",
            "f-0123456",
            "f-012345678",
            "f-ABCDEF12",
            "f-zzzzzzzz",
            "x-01234567",
            "01234567",
            "cody-core-1",
        ] {
            let mut v = base.clone();
            let n = overwrite_key(&mut v, "tag", bad);
            if n == 0 {
                continue;
            }
            *exercised.entry("tag").or_default() += 1;
            let spoiled: ServerMsg = serde_json::from_value(v).unwrap();
            assert!(
                !is_uplink_metadata_shape(&spoiled),
                "{name}: tag {bad:?} must fail the shape check"
            );
        }

        // Request ids: short and plain, never free text.
        for bad in ["", "has space", "semi;colon", &"a".repeat(65)] {
            let mut v = base.clone();
            if overwrite_key(&mut v, "request_id", bad) == 0 {
                continue;
            }
            *exercised.entry("request_id").or_default() += 1;
            let spoiled: ServerMsg = serde_json::from_value(v).unwrap();
            assert!(
                !is_uplink_metadata_shape(&spoiled),
                "{name}: request_id {bad:?} must fail the shape check"
            );
        }

        // Job refs: exactly eight lower-case hex.
        if name == "mother_jobs" {
            for bad in [
                "",
                "abc",
                "abcdef123",
                "ABCDEF12",
                "zzzzzzzz",
                "job-1234",
                "my-secret-job",
            ] {
                let mut v = base.clone();
                let jobs = v["jobs"].as_array_mut().expect("jobs");
                assert!(!jobs.is_empty(), "the control frame lists a job");
                jobs[0]["id"] = json!(bad);
                *exercised.entry("job_ref").or_default() += 1;
                let spoiled: ServerMsg = serde_json::from_value(v).unwrap();
                assert!(
                    !is_uplink_metadata_shape(&spoiled),
                    "mother_jobs: job ref {bad:?} must fail the shape check"
                );
            }
        }
    }
    for kind in ["tag", "request_id", "job_ref"] {
        assert!(
            exercised.get(kind).copied().unwrap_or(0) > 0,
            "no frame exercised the {kind} check"
        );
    }
}

#[test]
fn work_egress_caps_tracker_counts_so_an_honest_frame_passes_the_shape_check() {
    let huge = frame(json!({"type": "tracker_summary", "tag": "claudia-ABCD1234",
        "has_tracker": true, "host": HOST,
        "counts": {"todo": 5_000_000, "in_progress": 200_000, "blocked": 100_001,
                   "needs_you": 100_000, "done": 3}}));
    let out = redact_for_uplink_metadata(huge, &KEY).expect("tracker_summary is published");
    assert!(
        is_uplink_metadata_shape(&out),
        "an honest frame must pass: {}",
        json_of(&out)
    );
    let v = serde_json::to_value(&out).unwrap();
    assert_eq!(v["counts"]["todo"], 100_000);
    assert_eq!(v["counts"]["done"], 3);
}

// ── W10-18: the redaction match is exhaustive ────────────────────────────────

fn server_msg_variants() -> Vec<String> {
    let start = PROTOCOL_SRC
        .find("pub enum ServerMsg {")
        .expect("ServerMsg enum in protocol.rs");
    let body = &PROTOCOL_SRC[start..];
    let mut names = vec![];
    for line in body.lines().skip(1) {
        if line == "}" {
            break;
        }
        let Some(rest) = line.strip_prefix("    ") else {
            continue;
        };
        if rest.starts_with(' ') || !rest.starts_with(|c: char| c.is_ascii_uppercase()) {
            continue;
        }
        let name: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        names.push(name);
    }
    names
}

fn redact_fn_body() -> &'static str {
    let from = REDACT_SRC
        .find("pub fn redact_for_uplink_metadata")
        .expect("redact_for_uplink_metadata in uplink_redact.rs");
    let to = REDACT_SRC
        .find("pub fn is_uplink_metadata_shape")
        .expect("is_uplink_metadata_shape in uplink_redact.rs");
    assert!(from < to);
    &REDACT_SRC[from..to]
}

#[test]
fn every_server_msg_variant_is_named_in_the_uplink_redaction_match() {
    let variants = server_msg_variants();
    assert_eq!(
        variants.len(),
        109,
        "ServerMsg gained or lost a variant: decide whether it may leave a work host, \
         add it to redact_for_uplink_metadata, then update this count"
    );
    let body = redact_fn_body();
    for name in &variants {
        let needle = format!("ServerMsg::{name}");
        let named = body.match_indices(&needle).any(|(i, _)| {
            !body[i + needle.len()..]
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        });
        assert!(
            named,
            "ServerMsg::{name} is not named in redact_for_uplink_metadata"
        );
    }
}

#[test]
fn the_uplink_redaction_match_has_no_wildcard_arm() {
    let body = redact_fn_body();
    assert!(
        !body.contains(" _ =>"),
        "a wildcard arm would let a new frame leave a work host by default"
    );
    assert!(!body.contains("\n_ =>"));
}

// ── W10-16: Mother's real shape ──────────────────────────────────────────────

const GOLDEN: &str = include_str!("fixtures/mother-contract/ipc_mother_jobs.golden.json");

/// The fixture's free-text string values (the ones a work satellite must not
/// publish).
fn golden_free_text(jobs: &[Value]) -> Vec<String> {
    fn push(out: &mut Vec<String>, v: &Value) {
        if let Some(s) = v.as_str() {
            if !s.is_empty() {
                out.push(s.to_string());
            }
        }
    }
    let mut out = vec![];
    for j in jobs {
        for k in [
            "title",
            "repo",
            "isolation",
            "plan_path",
            "question",
            "pr_url",
            "adherence_notes",
        ] {
            push(&mut out, &j[k]);
        }
        push(&mut out, &j["gates"]["head_sha"]);
        for g in j["gates"]["results"].as_array().into_iter().flatten() {
            push(&mut out, &g["name"]);
        }
        for l in j["review_wave"]["lenses"].as_array().into_iter().flatten() {
            push(&mut out, &l["reviewer"]);
            push(&mut out, &l["lens"]);
            push(&mut out, &l["skip_reason"]);
        }
        push(&mut out, &j["decision"]["id"]);
        for o in j["decision"]["options"].as_array().into_iter().flatten() {
            push(&mut out, &o["id"]);
            push(&mut out, &o["label"]);
            push(&mut out, &o["consequence"]);
        }
        push(&mut out, &j["progress"]["label"]);
        push(&mut out, &j["progress"]["eta"]["label"]);
        push(&mut out, &j["id"]);
    }
    out
}

#[test]
fn mothers_real_job_shape_publishes_metadata_and_no_text() {
    let golden: Value = serde_json::from_str(GOLDEN).unwrap();
    let in_jobs = golden["jobs"].as_array().unwrap().clone();
    assert_eq!(in_jobs.len(), 3, "fixture sanity");

    let msg: ServerMsg =
        serde_json::from_str(GOLDEN).expect("the golden frame decodes as a ServerMsg");
    let out = redact_for_uplink_metadata(msg, &KEY).expect("MotherJobs is published");
    assert!(is_uplink_metadata_shape(&out), "{}", json_of(&out));
    let out_json = json_of(&out);
    let out_v: Value = serde_json::from_str(&out_json).unwrap();
    let jobs = out_v["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 3);

    // No free text from the fixture survives anywhere.
    for text in golden_free_text(&in_jobs) {
        assert!(
            !out_json.contains(&text),
            "fixture text {text:?} leaked:\n{out_json}"
        );
    }

    // Metadata survives, job by job, against the fixture's own values.
    for (i, (inp, out)) in in_jobs.iter().zip(jobs).enumerate() {
        assert!(is_hex8(out["id"].as_str().unwrap()), "job {i} id");
        assert_eq!(out["state"], inp["state"], "job {i} state");
        assert_eq!(out["activity"], inp["activity"], "job {i} activity");
        assert_eq!(
            out["paused_reason"], inp["paused_reason"],
            "job {i} paused_reason"
        );
        assert_eq!(out["crew_opt_in"], true);

        // progress: pct / stage / eta bounds and basis / signals.
        assert_eq!(
            out["progress"]["pct"], inp["progress"]["pct"],
            "job {i} pct"
        );
        assert_eq!(
            out["progress"]["stage"], inp["progress"]["stage"],
            "job {i} stage"
        );
        assert_eq!(
            out["progress"]["paused"], inp["progress"]["paused"],
            "job {i} paused"
        );
        assert_eq!(
            out["progress"]["eta"]["lo_s"], inp["progress"]["eta"]["lo_s"],
            "job {i} eta.lo_s"
        );
        assert_eq!(
            out["progress"]["eta"]["hi_s"], inp["progress"]["eta"]["hi_s"],
            "job {i} eta.hi_s"
        );
        assert_eq!(
            out["progress"]["eta"]["basis"], inp["progress"]["eta"]["basis"],
            "job {i} eta.basis"
        );
        assert_eq!(
            out["progress"]["signals"]["gates"], inp["progress"]["signals"]["gates"],
            "job {i} signals.gates"
        );
        assert_eq!(
            out["progress"]["signals"]["elapsed_active_s"],
            inp["progress"]["signals"]["elapsed_active_s"],
            "job {i} elapsed"
        );

        // gates: the count and each result word, not the names.
        let in_results: Vec<&Value> = inp["gates"]["results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|g| &g["result"])
            .collect();
        let out_results: Vec<&Value> = out["gates"]["results"]
            .as_array()
            .unwrap()
            .iter()
            .map(|g| &g["result"])
            .collect();
        assert_eq!(out_results, in_results, "job {i} gate results");
        assert_eq!(
            out["gates"]["status"], inp["gates"]["status"],
            "job {i} gates.status"
        );
        assert_eq!(
            out["gates"]["attempt"], inp["gates"]["attempt"],
            "job {i} attempt"
        );
        assert_eq!(
            out["gates"]["max_attempts"], inp["gates"]["max_attempts"],
            "job {i} max_attempts"
        );

        // attention_reasons keep reason and acked.
        let in_att = inp["attention_reasons"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let out_att = out["attention_reasons"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        assert_eq!(
            out_att.len(),
            in_att.len(),
            "job {i} attention_reasons count"
        );
        for (a, b) in in_att.iter().zip(&out_att) {
            assert_eq!(b["reason"], a["reason"]);
            assert_eq!(b["acked"], a["acked"]);
        }
    }

    // The wave job: lens counts and states.
    let wave = &jobs[1]["review_wave"];
    let in_wave = &in_jobs[1]["review_wave"];
    assert_eq!(wave["cycle"], in_wave["cycle"]);
    assert_eq!(wave["cycle_cap"], in_wave["cycle_cap"]);
    let in_l = in_wave["lenses"].as_array().unwrap();
    let out_l = wave["lenses"].as_array().unwrap();
    assert_eq!(out_l.len(), 4);
    for (a, b) in in_l.iter().zip(out_l) {
        assert_eq!(b["state"], a["state"]);
        assert_eq!(b["findings"], a["findings"]);
    }

    // The hold job: the decision survives as its kind only.
    let decision = &jobs[2]["decision"];
    assert_eq!(decision["kind"], "gate_hold");
    assert!(
        decision["options"].as_array().is_none_or(|o| o.is_empty()),
        "option text must go"
    );
}

// ── W10-8: personal egress is the ordinary network-peer policy ───────────────

#[test]
fn personal_egress_a_network_peer_gets_the_ordinary_policy() {
    let tags = SensitiveTags::in_memory();
    let mut samples = dropped_frames();
    samples.extend(allowed_frames());
    for (name, msg) in samples {
        let class_is_withheld = matches!(
            classify_server_msg(&msg),
            ServerClass::Sensitive
                | ServerClass::Admin
                | ServerClass::SatelliteControl
                | ServerClass::LocalOnly
        );
        let allowed = may_receive(PeerTrust::Tcp, &msg, &tags);
        let out = outbound(PeerTrust::Tcp, msg.clone(), &tags);
        assert_eq!(
            out.is_some(),
            allowed,
            "{name}: outbound and may_receive disagree"
        );
        if class_is_withheld {
            assert!(out.is_none(), "{name}: Teri/Fred/work, admin, satellite-control and local-only frames are withheld from Tcp");
        }
        if matches!(classify_server_msg(&msg), ServerClass::Open) {
            assert!(out.is_some(), "{name}: an Open frame passes");
        }
    }
}

#[test]
fn personal_egress_teri_fred_and_work_frames_are_withheld_from_a_network_peer() {
    let tags = SensitiveTags::in_memory();
    for name in [
        "teri_state",
        "fred_state",
        "work_source_status",
        "work_snapshot",
        "teri_picks",
        "work_detail",
    ] {
        let (_, msg) = dropped_frames()
            .into_iter()
            .find(|(n, _)| *n == name)
            .unwrap();
        assert!(
            outbound(PeerTrust::Tcp, msg.clone(), &tags).is_none(),
            "{name} to Tcp"
        );
        assert!(
            outbound(PeerTrust::Paired, msg.clone(), &tags).is_none(),
            "{name} to Paired"
        );
        assert!(
            outbound(PeerTrust::LocalOther, msg, &tags).is_some(),
            "{name} to a local peer"
        );
    }
}

#[test]
fn personal_egress_hosts_and_host_unavailable_are_open_to_a_network_peer() {
    let tags = SensitiveTags::in_memory();
    for name in ["hosts", "host_unavailable"] {
        let (_, msg) = pair_and_admin_frames()
            .into_iter()
            .find(|(n, _)| *n == name)
            .unwrap();
        assert!(outbound(PeerTrust::Tcp, msg, &tags).is_some(), "{name}");
    }
}

fn idempotence_frames() -> Vec<(&'static str, ServerMsg)> {
    let focus = |tag: &str, agent: &str| {
        json!({"tag": tag, "display_name": "A Private Title", "agent_name": agent, "is_built_in": false,
               "project_path": "/Users/x/work/repo", "label": "JIRA-123", "session_summary": "seeded context"})
    };
    let sensitive_job = json!({
        "id": "job-sens-1", "state": "running", "title": "t", "repo": "r",
        "failure_reason": "boom",
        "nostromo": {"origin": {"kind": "focus", "focus_tag": "work-secret-1",
                                "name_snapshot": "Private", "focus_name": "Private",
                                "session_prefix": "abcdef12"}}
    });
    let plain_job = json!({
        "id": "job-plain-1", "state": "running", "title": "t", "repo": "r",
        "nostromo": {"origin": {"kind": "focus", "focus_tag": "cody-core-1",
                                "name_snapshot": "Core", "focus_name": "Core"}}
    });
    vec![
        (
            "focus_list_resp",
            frame(json!({"type": "focus_list_resp", "host": HOST,
            "focuses": [focus("work-secret-1", "cody"), focus("cody-core-1", "cody"), focus("fred", "fred")]})),
        ),
        (
            "focus_registry_updated",
            frame(json!({"type": "focus_registry_updated", "host": HOST,
            "focuses": [focus("work-secret-1", "cody")]})),
        ),
        (
            "focus_created",
            frame(json!({"type": "focus_created", "host": HOST,
            "meta": focus("work-secret-1", "cody")})),
        ),
        (
            "session_list_resp",
            frame(json!({"type": "session_list_resp", "host": HOST,
            "sessions": [
                {"tag": "work-secret-1", "agent_name": "cody", "view_name": "v", "alive": true,
                 "remote_control": false, "state": "idle"},
                {"tag": "cody-core-1", "agent_name": "cody", "view_name": "v", "alive": true,
                 "remote_control": false, "state": "idle"}]})),
        ),
        (
            "mother_jobs",
            frame(json!({"type": "mother_jobs", "host": HOST,
            "jobs": [sensitive_job, plain_job]})),
        ),
        (
            "session_model_state",
            frame(json!({"type": "session_model_state", "tag": "cody-core-1",
            "running": true, "posture": "budget", "last_request": null})),
        ),
        (
            "model_defaults",
            frame(json!({"type": "model_defaults", "defaults": {},
            "declared": {"cody": "opus", "teri": "sonnet"}})),
        ),
    ]
}

fn tags_with_a_sensitive_focus() -> SensitiveTags {
    let tags = SensitiveTags::in_memory();
    tags.mark_tag("work-secret-1");
    tags.mark_job("job-sens-1");
    tags
}

#[test]
fn personal_egress_redaction_for_the_network_is_idempotent() {
    let tags = tags_with_a_sensitive_focus();
    for (name, msg) in idempotence_frames() {
        let once = redact_for_network(msg, &tags);
        let twice = redact_for_network(once.clone(), &tags);
        assert_eq!(
            serde_json::to_value(&twice).unwrap(),
            serde_json::to_value(&once).unwrap(),
            "{name}: redacting twice must equal redacting once"
        );
    }
}

#[test]
fn personal_egress_redaction_actually_changes_the_frames_it_is_given() {
    // Guards the idempotence test against being vacuous.
    let tags = tags_with_a_sensitive_focus();
    for (name, msg) in idempotence_frames() {
        if matches!(name, "session_model_state") {
            continue;
        }
        let before = serde_json::to_value(&msg).unwrap();
        let after = serde_json::to_value(redact_for_network(msg, &tags)).unwrap();
        assert_ne!(
            before, after,
            "{name}: expected redaction to change something"
        );
    }
    let out = json_of(&redact_for_network(idempotence_frames().remove(0).1, &tags));
    assert!(
        !out.contains("work-secret-1"),
        "a sensitive tag is replaced: {out}"
    );
    assert!(
        !out.contains("JIRA-123") && !out.contains("/Users/x/work/repo"),
        "{out}"
    );
}

#[test]
fn personal_egress_redaction_preserves_host() {
    let tags = tags_with_a_sensitive_focus();
    for (name, msg) in idempotence_frames() {
        if matches!(name, "session_model_state" | "model_defaults") {
            continue;
        }
        let out = serde_json::to_value(redact_for_network(msg, &tags)).unwrap();
        assert_eq!(out["host"], HOST, "{name}");
    }
}

// ── a sensitive focus never leaves a work host ───────────────────────────────

/// Tags the network redaction treats as sensitive: Huey's built-in tag, and a
/// registered work-derived one. Also a sensitive Mother job.
fn sensitive_tags() -> SensitiveTags {
    let tags = SensitiveTags::in_memory();
    tags.mark_tag("work-secret-1");
    tags.mark_job("job-sens-1");
    tags
}

/// One frame per focus-scoped published variant, for `tag`.
fn focus_scoped_frames(tag: &str) -> Vec<(&'static str, ServerMsg)> {
    vec![
        (
            "perri_state",
            frame(json!({"type": "perri_state", "tag": tag, "host": HOST,
                         "queue": [], "current": null})),
        ),
        (
            "session_state",
            frame(json!({"type": "session_state", "tag": tag, "state": "idle", "host": HOST})),
        ),
        (
            "session_bridge",
            frame(json!({"type": "session_bridge", "tag": tag, "connected": true, "host": HOST})),
        ),
        (
            "approval_pending",
            frame(json!({"type": "approval_pending", "tag": tag, "count": 1, "host": HOST})),
        ),
        (
            "decision_request",
            frame(
                json!({"type": "decision_request", "tag": tag, "request_id": "req-1",
                         "prompt": "p", "choices": [], "host": HOST}),
            ),
        ),
        (
            "decision_resolved",
            frame(
                json!({"type": "decision_resolved", "tag": tag, "request_id": "req-1",
                         "resolution": "answered", "host": HOST}),
            ),
        ),
        (
            "tracker_summary",
            frame(
                json!({"type": "tracker_summary", "tag": tag, "has_tracker": true,
                         "counts": {"todo": 1, "in_progress": 0, "blocked": 0,
                                    "needs_you": 0, "done": 0}, "host": HOST}),
            ),
        ),
        (
            "focus_created",
            frame(json!({"type": "focus_created", "host": HOST,
                         "meta": {"tag": tag, "display_name": "d", "agent_name": "cody",
                                  "is_built_in": false}})),
        ),
    ]
}

#[test]
fn work_egress_withholds_every_focus_scoped_frame_for_a_sensitive_tag() {
    let tags = sensitive_tags();
    for tag in ["huey", "work-secret-1"] {
        let frames = focus_scoped_frames(tag);
        assert_eq!(frames.len(), 8, "every focus-scoped published variant");
        for (name, msg) in frames {
            assert!(
                redact_with_tags(msg, &KEY, &tags).is_none(),
                "{name} for the sensitive tag {tag} must never leave a work host"
            );
        }
    }
}

#[test]
fn work_egress_still_publishes_focus_scoped_frames_for_an_ordinary_tag() {
    // The control for the test above: the filter is by tag, not blanket.
    let tags = sensitive_tags();
    for (name, msg) in focus_scoped_frames("cody-ABCD1234") {
        let out = redact_with_tags(msg, &KEY, &tags)
            .unwrap_or_else(|| panic!("{name}: an ordinary focus is published"));
        assert!(is_uplink_metadata_shape(&out), "{name}");
    }
}

#[test]
fn work_egress_a_sensitive_agent_is_dropped_from_the_focus_and_session_lists() {
    let tags = sensitive_tags();
    let ordinary = |agent: &str, tag: &str| json!({"tag": tag, "display_name": "d", "agent_name": agent, "is_built_in": false});
    let focuses = json!([
        ordinary("cody", "cody-ABCD1234"),
        ordinary("cody", "work-secret-1"),
        ordinary("huey", "other-tag"),
        ordinary("cody", "huey"),
    ]);
    let session = |agent: &str, tag: &str| {
        json!({"tag": tag, "agent_name": agent, "view_name": "v", "alive": true,
               "remote_control": false, "state": "idle", "mcp_bridge_connected": false})
    };
    let sessions = json!([
        session("cody", "cody-ABCD1234"),
        session("cody", "work-secret-1"),
        session("huey", "other-tag"),
        session("cody", "huey"),
    ]);
    let kept = pseudonymous_tag(&KEY, "cody-ABCD1234");
    let only_the_ordinary = |msg: ServerMsg, key: &str, field: &str| {
        let out = serde_json::to_value(redact_with_tags(msg, &KEY, &tags).unwrap()).unwrap();
        let items = out[key].as_array().unwrap();
        assert_eq!(items.len(), 1, "{field}: only the ordinary entry stays");
        assert_eq!(items[0]["tag"], kept.as_str(), "{field}");
    };
    only_the_ordinary(
        frame(json!({"type": "focus_list_resp", "focuses": focuses, "host": HOST})),
        "focuses",
        "focus_list_resp",
    );
    only_the_ordinary(
        frame(json!({"type": "focus_registry_updated", "focuses": focuses, "host": HOST})),
        "focuses",
        "focus_registry_updated",
    );
    only_the_ordinary(
        frame(json!({"type": "session_list_resp", "sessions": sessions, "host": HOST})),
        "sessions",
        "session_list_resp",
    );
}

#[test]
fn work_egress_a_sensitive_job_is_dropped_from_the_job_list() {
    let tags = sensitive_tags();
    let mut sensitive = marker_job();
    sensitive["id"] = json!("job-sens-1");
    let mut ordinary = marker_job();
    ordinary["id"] = json!("job-ordinary-a1b2c3d4");
    let msg = frame(json!({"type": "mother_jobs", "host": HOST, "jobs": [sensitive, ordinary]}));
    let out = serde_json::to_value(redact_with_tags(msg, &KEY, &tags).unwrap()).unwrap();
    let jobs = out["jobs"].as_array().unwrap();
    assert_eq!(jobs.len(), 1, "the sensitive job is not published");
    assert_eq!(jobs[0]["id"], "a1b2c3d4");
}

// ── the arms that publish are exactly the allowed ones ──────────────────────

/// The thirteen frames a `work` satellite may publish.
const PUBLISHED: [&str; 13] = [
    "MotherJobs",
    "MotherStatusline",
    "PerriState",
    "SessionState",
    "SessionBridge",
    "SessionListResp",
    "FocusListResp",
    "FocusRegistryUpdated",
    "FocusCreated",
    "ApprovalPending",
    "DecisionRequest",
    "DecisionResolved",
    "TrackerSummary",
];

const NONE_MARKER: &str = "// Everything else stays on the host";

/// The `ServerMsg::<Name>` variant names in `text`, sorted and de-duplicated.
fn variants_named_in(text: &str) -> Vec<String> {
    let mut names: Vec<String> = text
        .match_indices("ServerMsg::")
        .map(|(i, m)| {
            text[i + m.len()..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect()
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

#[test]
fn the_uplink_arms_that_publish_are_exactly_the_thirteen_allowed_types() {
    let body = redact_fn_body();
    let at = body
        .find(NONE_MARKER)
        .expect("the closing `None` arm is introduced by its comment");
    let (publishing, withheld) = body.split_at(at);

    // Everything before the marker is a published (or guarded) arm and names
    // only allowed types; every allowed type is there.
    let mut allowed: Vec<String> = PUBLISHED.iter().map(|s| s.to_string()).collect();
    allowed.sort();
    assert_eq!(
        variants_named_in(publishing),
        allowed,
        "the arms before the closing `None` arm must name exactly the 13 allowed types"
    );

    // The closing arm withholds every other variant, and only them.
    let mut everything_else: Vec<String> = server_msg_variants()
        .into_iter()
        .filter(|v| !PUBLISHED.contains(&v.as_str()))
        .collect();
    everything_else.sort();
    assert_eq!(
        variants_named_in(withheld),
        everything_else,
        "every ServerMsg variant outside the 13 must be in the closing `None` arm"
    );
    assert!(
        withheld.contains("=> None,"),
        "the closing arm must return None"
    );
    assert!(
        !withheld.contains("Some("),
        "the closing arm must not publish anything"
    );
}

#[test]
fn work_egress_withholds_daemon_reconnected_and_the_turn_origin_frame() {
    let tags = sensitive_tags();
    let frames = [
        ("daemon_reconnected", ServerMsg::DaemonReconnected),
        (
            "session_turn_origin",
            frame(
                json!({"type": "session_turn_origin", "tag": "cody-ABCD1234",
                         "turn_id": "t0", "origin": {"type": "terminal_follow_notice", "items": []}}),
            ),
        ),
        (
            "terminal_refused",
            frame(json!({"type": "terminal_refused", "op": "input",
                         "terminal_id": "t1", "code": "x"})),
        ),
    ];
    for (name, msg) in frames {
        assert!(redact_with_tags(msg, &KEY, &tags).is_none(), "{name}");
    }
}

// ── counts are capped ────────────────────────────────────────────────────────

#[test]
fn work_egress_caps_the_approval_count_and_the_statusline_counts() {
    let out = redact_for_uplink_metadata(
        frame(
            json!({"type": "approval_pending", "tag": "cody-1", "count": 4_000_000_000u64,
                     "host": HOST}),
        ),
        &KEY,
    )
    .unwrap();
    assert_eq!(serde_json::to_value(&out).unwrap()["count"], 100_000);
    assert!(is_uplink_metadata_shape(&out));

    let out = redact_for_uplink_metadata(
        frame(
            json!({"type": "mother_statusline", "running": 9_000_000, "queued": 9_000_001,
                     "failed": 9_000_002, "awaiting": 9_000_003, "host": HOST}),
        ),
        &KEY,
    )
    .unwrap();
    let v = serde_json::to_value(&out).unwrap();
    for field in ["running", "queued", "failed", "awaiting"] {
        assert_eq!(v[field], 100_000, "{field}");
    }
    assert_eq!(v["host"], HOST);
    assert!(is_uplink_metadata_shape(&out));
}

#[test]
fn work_egress_caps_every_free_number_in_a_job_and_the_shape_check_rejects_an_uncapped_one() {
    // (pointer, huge value): each is a number a hostile host could use as a
    // side channel, so each is capped and the primary rejects an uncapped one.
    let numbers = [
        ("/gates/attempt", json!(4_000_000_000u64)),
        ("/gates/max_attempts", json!(4_000_000_000u64)),
        ("/review_wave/cycle", json!(4_000_000_000u64)),
        ("/review_wave/cycle_cap", json!(4_000_000_000u64)),
        ("/review_wave/coverage_gaps", json!(4_000_000_000u64)),
        ("/progress/v", json!(4_000_000_000u64)),
        ("/progress/signals/gates/passed", json!(4_000_000_000u64)),
        ("/progress/signals/gates/failed", json!(4_000_000_000u64)),
        ("/progress/signals/gates/total", json!(4_000_000_000u64)),
        (
            "/progress/signals/elapsed_active_s",
            json!(9_000_000_000_000u64),
        ),
        ("/progress/eta/lo_s", json!(9_000_000_000_000u64)),
        ("/progress/eta/hi_s", json!(9_000_000_000_000u64)),
    ];
    for (pointer, huge) in numbers {
        let mut job = marker_job();
        *job.pointer_mut(pointer).expect(pointer) = huge.clone();
        let out = redact_for_uplink_metadata(
            frame(json!({"type": "mother_jobs", "host": HOST, "jobs": [job]})),
            &KEY,
        )
        .unwrap();
        let v = serde_json::to_value(&out).unwrap();
        let got = v.pointer(&format!("/jobs/0{pointer}")).expect(pointer);
        assert_eq!(got, &json!(100_000), "{pointer} is capped");
        assert!(
            is_uplink_metadata_shape(&out),
            "{pointer}: capped output passes"
        );

        // The same frame with that number put back is not a metadata shape.
        let mut tampered = v.clone();
        *tampered.pointer_mut(&format!("/jobs/0{pointer}")).unwrap() = huge;
        assert!(
            !is_uplink_metadata_shape(&frame(tampered)),
            "{pointer}: an uncapped number is rejected"
        );
    }
}
