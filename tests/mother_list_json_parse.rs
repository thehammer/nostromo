//! Fixture-based tests for `MotherJob` JSON deserialisation.
//!
//! Uses `tests/fixtures/mother_list.json` which mirrors the real on-disk
//! shape emitted by `mother list --format json`.

use nostromo::mother::MotherJob;

fn load_fixture() -> Vec<MotherJob> {
    let json = include_str!("fixtures/mother_list.json");
    serde_json::from_str(json).expect("fixture should parse")
}

#[test]
fn parses_all_three_jobs() {
    let jobs = load_fixture();
    assert_eq!(jobs.len(), 3);
}

#[test]
fn running_job_fields() {
    let jobs = load_fixture();
    let job = jobs
        .iter()
        .find(|j| j.state == "running")
        .expect("running job missing");

    assert_eq!(job.id, "20260508T144457Z-6e3043a1");
    assert_eq!(job.repo, "nostromo");
    assert_eq!(job.isolation, "worktree");
    assert!(!job.is_awaiting());
    assert!(!job.is_failed());
    assert!(!job.is_succeeded());
    assert!(job.plan_path.is_some());
    assert!(job.created_at.is_some());
    assert!(job.started_at.is_some());
    assert!(job.finished_at.is_none());
}

#[test]
fn queued_job_fields() {
    let jobs = load_fixture();
    let job = jobs
        .iter()
        .find(|j| j.state == "queued")
        .expect("queued job missing");
    assert_eq!(job.id, "20260508T144522Z-63e0f6f4");
    assert!(job.started_at.is_none());
    assert!(job.question.is_none());
}

#[test]
fn awaiting_job_fields() {
    let jobs = load_fixture();
    let job = jobs
        .iter()
        .find(|j| j.state == "awaiting")
        .expect("awaiting job missing");

    assert!(job.is_awaiting());
    assert!(!job.is_failed());

    let q = job.question.as_deref().expect("question should be set");
    assert!(
        q.contains("transaction"),
        "question should mention 'transaction'"
    );

    assert_eq!(job.paused_reason.as_deref(), Some("user"));
}

#[test]
fn extra_fields_ignored() {
    // The fixture contains fields not in MotherJob (depends_on, repo_path, etc.).
    // serde should silently ignore them — if this test compiles and runs, it passed.
    let _jobs = load_fixture();
}

#[test]
fn all_jobs_have_plan_path() {
    for job in load_fixture() {
        assert!(job.plan_path.is_some(), "job {} missing plan_path", job.id);
    }
}
