//! MC1-5 baseline: a `MotherJobs` IPC frame for jobs WITHOUT any headless-crew
//! data must stay byte-identical to what the daemon sent before the crew keys
//! existed. The golden below was captured from the pre-MC1 code.
//!
//! Format: `serde_json::to_string_pretty` of `ServerMsg::MotherJobs { jobs }`
//! (pretty, so a diff in review shows exactly which key moved), no trailing
//! newline. `UPDATE_GOLDEN=1` rewrites the file instead of comparing; only do
//! that deliberately, since the point of the file is that it does not change.

use std::path::PathBuf;

use nostromo::ipc::protocol::ServerMsg;
use nostromo::mother::decode::parse_jobs;
use serde_json::json;

fn fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Jobs with several states, plus ones carrying `origin`, `phases`, `cycles`
/// and an adherence block so the frame exercises every pre-crew optional key.
fn extra_plain_jobs() -> serde_json::Value {
    json!([
        {
            "id": "plain-origin-1",
            "title": "queued from a work item",
            "repo": "nostromo",
            "isolation": "worktree",
            "state": "running",
            "created_at": "2026-05-09T10:00:00Z",
            "started_at": "2026-05-09T10:00:03Z",
            "finished_at": null,
            "plan_path": "/tmp/plan.md",
            "current_tier": "tier_2",
            "current_activity": "editing src/lib.rs",
            "kind": null,
            "origin": {"label": "teri-send"},
            "phases": [
                {"agent": "cody", "request_type": "implement", "state": "running",
                 "started_at": "2026-05-09T10:00:04Z", "finished_at": null, "findings": null},
                {"agent": "perri", "request_type": "review", "state": "done",
                 "started_at": "2026-05-09T10:30:00Z", "finished_at": "2026-05-09T10:40:00Z", "findings": 3}
            ]
        },
        {
            "id": "plain-pipeline-1",
            "title": "pipeline job",
            "repo": "nostromo",
            "isolation": "worktree",
            "state": "awaiting",
            "created_at": "2026-05-09T11:00:00Z",
            "paused_reason": "adherence_blocked",
            "adherence_status": "blocked_for_human",
            "adherence_notes": "check the migration",
            "question": "Proceed with the migration?",
            "kind": "pipeline",
            "cycles": [
                {"cycle": 1, "phases": [
                    {"agent": "archie", "request_type": "plan", "state": "done",
                     "started_at": "2026-05-09T11:00:05Z", "finished_at": "2026-05-09T11:05:00Z", "findings": null}
                ]}
            ]
        },
        {
            "id": "plain-failed-1",
            "title": "failed job",
            "repo": "other",
            "isolation": "none",
            "state": "failed",
            "created_at": "2026-05-09T12:00:00Z",
            "started_at": "2026-05-09T12:00:01Z",
            "finished_at": "2026-05-09T12:30:00Z"
        },
        {
            "id": "plain-done-1",
            "title": "finished job",
            "repo": "other",
            "isolation": "worktree",
            "state": "succeeded",
            "created_at": "2026-05-09T13:00:00Z",
            "started_at": "2026-05-09T13:00:01Z",
            "finished_at": "2026-05-09T13:10:00Z",
            "pr_url": null
        }
    ])
}

fn plain_frame() -> String {
    let list = std::fs::read(fixtures_dir().join("mother_list.json")).expect("read mother_list.json");
    let (mut jobs, skipped) = parse_jobs(&list).expect("mother_list.json parses");
    assert_eq!(skipped, 0, "mother_list.json must decode fully");
    let extra = serde_json::to_vec(&extra_plain_jobs()).unwrap();
    let (extra_jobs, skipped) = parse_jobs(&extra).expect("extra jobs parse");
    assert_eq!(skipped, 0, "extra plain jobs must decode fully");
    jobs.extend(extra_jobs);

    let states: std::collections::BTreeSet<&str> = jobs.iter().map(|j| j.state.as_str()).collect();
    assert!(states.len() >= 5, "golden must cover several states, got {states:?}");
    assert!(
        jobs.iter().any(|j| j.origin.is_some() && !j.phases.is_empty()),
        "golden must include a job with origin and phases"
    );

    serde_json::to_string_pretty(&ServerMsg::MotherJobs { jobs }).expect("serialize frame")
}

#[test]
fn mother_jobs_frame_without_crew_data_matches_the_pre_crew_golden() {
    let path = fixtures_dir().join("mother-contract/ipc_mother_jobs_plain.golden.json");
    let frame = plain_frame();

    if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
        std::fs::write(&path, &frame).expect("write golden");
        return;
    }

    let golden = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("read {}: {e} (UPDATE_GOLDEN=1 to create)", path.display()));
    assert_eq!(
        frame, golden,
        "a MotherJobs frame for jobs with no crew data changed on the wire"
    );
}
