//! MC1: `mother.get_job` / `mother.list_jobs` expose the headless-crew keys
//! (activity, gates, progress, ...) and never the opaque broker `crew` blob,
//! which holds repo gate commands and hints agents have no business reading.
//!
//! Tool handlers are called directly over a state seeded with a job feed, the
//! same way `tests/mcp_introspection.rs` does it.

use nostromo::{
    mcp::{state::McpSharedState, tools::mother},
    mother::MotherJob,
};
use serde_json::{json, Value};
use tokio::sync::watch;

fn state_with(jobs: Vec<MotherJob>) -> McpSharedState {
    let (_, perri_queue_rx) = watch::channel(None);
    let (_, perri_pr_rx) = watch::channel(nostromo::data::perri_pr::no_prs());
    let (_, mailbox_rx) = watch::channel(None);
    let (_, calendar_rx) = watch::channel(None);
    let (_, teri_todos_rx) = watch::channel(None);
    let (_, mother_jobs_rx) = watch::channel(jobs);
    let (_, mother_status_rx) = watch::channel(None);
    let (_, rate_limits_rx) = watch::channel(None);
    let (_, budget_posture_rx) = watch::channel(None);
    McpSharedState::new(
        perri_queue_rx,
        perri_pr_rx,
        mailbox_rx,
        calendar_rx,
        teri_todos_rx,
        mother_jobs_rx,
        mother_status_rx,
        rate_limits_rx,
        budget_posture_rx,
    )
}

fn job(v: Value) -> MotherJob {
    serde_json::from_value(v).expect("job decodes")
}

fn crew_job() -> MotherJob {
    job(json!({
        "id": "j-gates1",
        "state": "running",
        "title": "Add facility export endpoint",
        "activity": "gating",
        "pr_url": "https://github.com/Carefeed/admin-portal/pull/4321",
        "crew": {"mode": "enforce", "gate_commands": ["rm -rf SECRET-GATE-COMMAND"]},
        "gates": {"mode": "enforce", "status": "running", "attempt": 1, "max_attempts": 3,
                  "results": [{"name": "lint", "result": "passed", "blocking": true, "duration_s": 42, "exit_code": 0}],
                  "not_run": [], "override": null},
        "progress": {"v": 1, "pct": 55, "label": "Implementing", "stage": "implement",
                     "eta": {"lo_s": 300, "hi_s": 900, "label": "5-15 min", "basis": "fleet"},
                     "paused": false, "flags": []}
    }))
}

fn plain_job() -> MotherJob {
    job(json!({"id": "j-plain", "state": "queued", "title": "No crew here"}))
}

const NEW_KEYS: [&str; 11] = [
    "activity",
    "pr_url",
    "crew_opt_in",
    "gates",
    "review_wave",
    "decision",
    "attention",
    "attention_reasons",
    "last_answer",
    "progress",
    "criteria_source",
];

fn assert_crew_fields(j: &Value) {
    assert_eq!(j["id"], "j-gates1", "{j}");
    assert_eq!(j["activity"], "gating", "{j}");
    assert_eq!(j["crew_opt_in"], true, "{j}");
    assert_eq!(
        j["pr_url"], "https://github.com/Carefeed/admin-portal/pull/4321",
        "{j}"
    );
    assert_eq!(j["gates"]["attempt"], 1, "{j}");
    assert_eq!(j["gates"]["max_attempts"], 3, "{j}");
    assert_eq!(j["gates"]["results"][0]["name"], "lint", "{j}");
    assert_eq!(j["progress"]["pct"], 55, "{j}");
    assert_eq!(j["progress"]["eta"]["basis"], "fleet", "{j}");
    assert!(
        j.get("crew").is_none(),
        "the opaque crew blob must not reach agents: {j}"
    );
    let text = j.to_string();
    assert!(
        !text.contains("gate_commands") && !text.contains("SECRET-GATE-COMMAND"),
        "crew blob leaked: {text}"
    );
}

#[tokio::test]
async fn mother_get_job_returns_the_crew_fields_and_no_crew_blob() {
    let state = state_with(vec![plain_job(), crew_job()]);
    let result = mother::get_job(
        &state,
        &mother::GetJobInput {
            id: "j-gates1".into(),
        },
    );
    assert_crew_fields(&result);
}

#[tokio::test]
async fn mother_list_jobs_returns_the_crew_fields_and_no_crew_blob() {
    let state = state_with(vec![plain_job(), crew_job()]);
    let result = mother::list_jobs(
        &state,
        &mother::ListJobsInput {
            include_archived: false,
            status: None,
        },
    )
    .await;
    let arr = result.as_array().expect("array");
    assert_eq!(arr.len(), 2, "{result}");
    let crew = arr
        .iter()
        .find(|j| j["id"] == "j-gates1")
        .expect("crew job listed");
    assert_crew_fields(crew);
}

#[tokio::test]
async fn a_job_without_crew_data_shows_none_of_the_crew_keys_over_mcp() {
    let state = state_with(vec![plain_job(), crew_job()]);
    let got = mother::get_job(
        &state,
        &mother::GetJobInput {
            id: "j-plain".into(),
        },
    );
    assert_eq!(got["id"], "j-plain");
    for key in NEW_KEYS.iter().chain(["crew"].iter()) {
        assert!(
            got.get(*key).is_none(),
            "key `{key}` must be absent for a job without crew data: {got}"
        );
    }
}
