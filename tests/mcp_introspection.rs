//! Integration tests for the 12 MCP Phase 2 introspection tools.
//!
//! Tests call tool handler functions directly — no Unix socket or full server
//! needed.  Fixtures are loaded from `tests/fixtures/` at compile time.
//!
//! Strategy:
//! - Construct `McpSharedState` with watch channels pre-seeded from fixture data.
//! - Call handler functions directly and assert on the returned JSON.
//! - Keep tests focused on observable behaviour, not internal wiring.

use nostromo::{
    data::{
        fred_calendar::{CalendarEvent, CalendarSnapshot},
        fred_mailbox::MailboxSnapshot,
        perri_pr::PrSnapshot,
        perri_queue::PrQueueSnapshot,
        rate_limits::{BudgetPosture, RateLimits},
        teri_todos::{TeriTodo, TeriTodosSnapshot},
    },
    mcp::{
        state::{McpSharedState, ViewMeta},
        tools,
        tools::{fred, get_view_state, list_views, mother, nostromo_meta, perri, teri},
    },
    mother::{MotherJob, MotherStatus},
};
use tokio::sync::{mpsc, watch};

// ── fixture data ──────────────────────────────────────────────────────────────

const PERRI_QUEUE_JSON: &str = include_str!("fixtures/mcp_perri_queue.json");

const FRED_MAILBOX_JSON: &str = include_str!("fixtures/mcp_fred_mailbox.json");

// ── state builders ────────────────────────────────────────────────────────────

/// Minimal state with all channels holding `None` / empty values.
fn empty_state() -> McpSharedState {
    seeded_state(None, None, None, None, None, vec![], None, None, None)
}

/// Build a `McpSharedState` with all channels pre-seeded from the supplied
/// values.  Any `Option` left as `None` is passed through as-is.
#[allow(clippy::too_many_arguments)]
fn seeded_state(
    perri_queue: Option<PrQueueSnapshot>,
    perri_pr: Option<PrSnapshot>,
    mailbox: Option<MailboxSnapshot>,
    calendar: Option<CalendarSnapshot>,
    teri_todos: Option<TeriTodosSnapshot>,
    mother_jobs: Vec<MotherJob>,
    mother_status: Option<MotherStatus>,
    rate_limits: Option<RateLimits>,
    budget_posture: Option<BudgetPosture>,
) -> McpSharedState {
    let (tx, _rx) = mpsc::unbounded_channel();
    let (_, perri_queue_rx) = watch::channel(perri_queue);
    let (_, perri_pr_rx) = watch::channel(perri_pr);
    let (_, mailbox_rx) = watch::channel(mailbox);
    let (_, calendar_rx) = watch::channel(calendar);
    let (_, teri_todos_rx) = watch::channel(teri_todos);
    let (_, mother_jobs_rx) = watch::channel(mother_jobs);
    let (_, mother_status_rx) = watch::channel(mother_status);
    let (_, rate_limits_rx) = watch::channel(rate_limits);
    let (_, budget_posture_rx) = watch::channel(budget_posture);
    McpSharedState::new(
        tx,
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

/// Deserialise the Perri queue fixture.
fn perri_queue_fixture() -> PrQueueSnapshot {
    serde_json::from_str(PERRI_QUEUE_JSON).expect("mcp_perri_queue.json should parse")
}

/// Deserialise the Fred mailbox fixture.
fn fred_mailbox_fixture() -> MailboxSnapshot {
    serde_json::from_str(FRED_MAILBOX_JSON).expect("mcp_fred_mailbox.json should parse")
}

/// Push all seven standard views into `state.views_meta`.
async fn seed_views(state: &McpSharedState) {
    let mut meta = state.views_meta.write().await;
    meta.push(ViewMeta {
        id: "fred",
        title: "Fred".to_string(),
        pane_ids: vec!["mailbox", "calendar", "repl"],
    });
    meta.push(ViewMeta {
        id: "perri",
        title: "Perri".to_string(),
        pane_ids: vec!["pr_queue", "diff", "repl"],
    });
    meta.push(ViewMeta {
        id: "claudia",
        title: "Claudia".to_string(),
        pane_ids: vec!["chat"],
    });
    meta.push(ViewMeta {
        id: "cody",
        title: "Cody".to_string(),
        pane_ids: vec!["editor", "repl"],
    });
    meta.push(ViewMeta {
        id: "kennedy",
        title: "Kennedy".to_string(),
        pane_ids: vec!["shell"],
    });
    meta.push(ViewMeta {
        id: "teri",
        title: "Teri".to_string(),
        pane_ids: vec!["todos", "repl"],
    });
    meta.push(ViewMeta {
        id: "mother",
        title: "Mother".to_string(),
        pane_ids: vec!["jobs", "log", "repl"],
    });
}

/// Build three `MotherJob` values covering running / queued / awaiting states.
fn sample_mother_jobs() -> Vec<MotherJob> {
    vec![
        MotherJob {
            id: "job-running-1".to_string(),
            state: "running".to_string(),
            repo: "acme/web-app".to_string(),
            isolation: "worktree".to_string(),
            title: "feat: add auth".to_string(),
            created_at: None,
            started_at: None,
            finished_at: None,
            plan_path: None,
            question: None,
            paused_reason: None,
            adherence_notes: None,
            adherence_status: None,
            current_tier: None,
            current_activity: None,
            kind: None,
            phases: vec![],
            cycles: vec![],
        },
        MotherJob {
            id: "job-queued-2".to_string(),
            state: "queued".to_string(),
            repo: "acme/api".to_string(),
            isolation: "worktree".to_string(),
            title: "fix: null pointer".to_string(),
            created_at: None,
            started_at: None,
            finished_at: None,
            plan_path: None,
            question: None,
            paused_reason: None,
            adherence_notes: None,
            adherence_status: None,
            current_tier: None,
            current_activity: None,
            kind: None,
            phases: vec![],
            cycles: vec![],
        },
        MotherJob {
            id: "job-awaiting-3".to_string(),
            state: "awaiting".to_string(),
            repo: "acme/mobile".to_string(),
            isolation: "worktree".to_string(),
            title: "chore: bump deps".to_string(),
            created_at: None,
            started_at: None,
            finished_at: None,
            plan_path: None,
            question: Some("Proceed with breaking change?".to_string()),
            paused_reason: Some("user".to_string()),
            adherence_notes: None,
            adherence_status: None,
            current_tier: None,
            current_activity: None,
            kind: None,
            phases: vec![],
            cycles: vec![],
        },
    ]
}

// ── list_views tests ──────────────────────────────────────────────────────────

#[tokio::test]
async fn list_views_returns_seven_views() {
    let state = empty_state();
    seed_views(&state).await;

    let result = list_views::handle(&state).await;
    let views = result
        .as_array()
        .expect("list_views should return an array");

    assert_eq!(views.len(), 7, "expected exactly 7 registered views");

    for view in views {
        assert!(view.get("id").is_some(), "each view must have an id");
        assert!(view.get("title").is_some(), "each view must have a title");
        assert!(
            view.get("pane_ids").is_some(),
            "each view must have pane_ids"
        );
    }
}

#[tokio::test]
async fn list_views_perri_summary_has_pr_count() {
    let queue = perri_queue_fixture(); // 3 items
    let state = seeded_state(
        Some(queue),
        None,
        None,
        None,
        None,
        vec![],
        None,
        None,
        None,
    );
    seed_views(&state).await;

    let result = list_views::handle(&state).await;
    let views = result.as_array().unwrap();
    let perri = views
        .iter()
        .find(|v| v["id"] == "perri")
        .expect("perri view should be present");

    assert_eq!(
        perri["summary"]["open_pr_count"], 3,
        "perri summary should report 3 open PRs from fixture"
    );
}

#[tokio::test]
async fn list_views_fred_summary_has_unread_count() {
    let mailbox = fred_mailbox_fixture(); // unread_count: 2
    let state = seeded_state(
        None,
        None,
        Some(mailbox),
        None,
        None,
        vec![],
        None,
        None,
        None,
    );
    seed_views(&state).await;

    let result = list_views::handle(&state).await;
    let views = result.as_array().unwrap();
    let fred = views
        .iter()
        .find(|v| v["id"] == "fred")
        .expect("fred view should be present");

    assert_eq!(
        fred["summary"]["unread_email_count"], 2,
        "fred summary should reflect 2 unread emails from fixture"
    );
}

#[tokio::test]
async fn list_views_mother_summary_has_job_counts() {
    let jobs = sample_mother_jobs(); // 1 running, 1 queued, 1 awaiting
    let state = seeded_state(None, None, None, None, None, jobs, None, None, None);
    seed_views(&state).await;

    let result = list_views::handle(&state).await;
    let views = result.as_array().unwrap();
    let mother = views
        .iter()
        .find(|v| v["id"] == "mother")
        .expect("mother view should be present");

    assert_eq!(mother["summary"]["running_jobs"], 1);
    assert_eq!(mother["summary"]["queued_jobs"], 1);
    assert_eq!(mother["summary"]["awaiting_jobs"], 1);
}

// ── perri tool tests ──────────────────────────────────────────────────────────

#[tokio::test]
async fn perri_list_pr_queue_returns_items() {
    let queue = perri_queue_fixture();
    let state = seeded_state(
        Some(queue),
        None,
        None,
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let result = perri::list_pr_queue(&state);
    let items = result
        .as_array()
        .expect("list_pr_queue should return an array");
    assert_eq!(items.len(), 3, "should return all 3 items from fixture");
}

#[tokio::test]
async fn perri_list_pr_queue_fields_match() {
    let queue = perri_queue_fixture();
    let state = seeded_state(
        Some(queue),
        None,
        None,
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let result = perri::list_pr_queue(&state);
    let items = result.as_array().unwrap();

    // Check the first item matches fixture data exactly.
    let first = &items[0];
    assert_eq!(first["repo"], "acme/web-app");
    assert_eq!(first["number"], 42);
    assert_eq!(first["title"], "feat: add auth");
    assert_eq!(first["author"], "alice");
    assert_eq!(first["bucket"], "requested");
    assert_eq!(first["new_activity"], false);
    assert_eq!(first["url"], "https://github.com/acme/web-app/pull/42");
}

#[tokio::test]
async fn perri_get_current_pr_returns_null_when_none() {
    let state = empty_state();
    let result = perri::get_current_pr(&state);
    assert!(
        result.is_null(),
        "get_current_pr should return null when channel holds None"
    );
}

#[tokio::test]
async fn perri_get_current_pr_returns_snapshot() {
    let snap = PrSnapshot {
        pr_number: Some(42),
        repo: "acme/web-app".to_string(),
        title: "feat: add auth".to_string(),
        author: "alice".to_string(),
        url: "https://github.com/acme/web-app/pull/42".to_string(),
        diff: "--- a/src/main.rs\n+++ b/src/main.rs".to_string(),
        stale: false,
        error: None,
        ci_checks: vec![],
        additions: 0,
        deletions: 0,
        changed_files: 0,
    };
    let state = seeded_state(None, Some(snap), None, None, None, vec![], None, None, None);

    let result = perri::get_current_pr(&state);
    assert!(
        !result.is_null(),
        "get_current_pr should not be null when snapshot is set"
    );
    assert_eq!(result["pr_number"], 42);
    assert_eq!(result["repo"], "acme/web-app");
    assert_eq!(result["author"], "alice");
}

#[tokio::test]
async fn perri_get_state_composite() {
    let queue = perri_queue_fixture();
    let pr_snap = PrSnapshot {
        pr_number: Some(7),
        repo: "acme/api".to_string(),
        title: "fix: null pointer".to_string(),
        author: "bob".to_string(),
        url: "https://github.com/acme/api/pull/7".to_string(),
        diff: String::new(),
        stale: false,
        error: None,
        ci_checks: vec![],
        additions: 0,
        deletions: 0,
        changed_files: 0,
    };
    let state = seeded_state(
        Some(queue),
        Some(pr_snap),
        None,
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let result = perri::get_state(&state);
    let queue_arr = result["queue"]
        .as_array()
        .expect("queue should be an array");
    assert_eq!(queue_arr.len(), 3);

    assert!(!result["current_pr"].is_null(), "current_pr should be set");
    assert_eq!(result["current_pr"]["pr_number"], 7);

    assert_eq!(result["stale"], false);
}

#[tokio::test]
async fn perri_list_pr_queue_empty_when_no_snapshot() {
    // for_test state — all channels hold None.
    let state = empty_state();
    let result = perri::list_pr_queue(&state);
    let items = result
        .as_array()
        .expect("should return an array even with no snapshot");
    assert!(items.is_empty(), "empty channel should yield []");
}

// ── fred tool tests ───────────────────────────────────────────────────────────

#[tokio::test]
async fn fred_list_unread_emails_filters_read() {
    let mailbox = fred_mailbox_fixture(); // 2 unread, 1 read
    let state = seeded_state(
        None,
        None,
        Some(mailbox),
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let result = fred::list_unread_emails(&state);
    let items = result.as_array().expect("should return array");
    assert_eq!(items.len(), 2, "should return only the 2 unread items");

    // Verify each returned item is unread.
    for item in items {
        assert_eq!(
            item["is_read"], false,
            "list_unread_emails must not return read items"
        );
    }
}

#[tokio::test]
async fn fred_list_calendar_events_no_date_returns_all() {
    let calendar = CalendarSnapshot {
        events: vec![
            CalendarEvent {
                start: Some("2026-05-14T09:00:00Z".parse().unwrap()),
                end: Some("2026-05-14T10:00:00Z".parse().unwrap()),
                title: "Morning standup".to_string(),
                status: "accepted".to_string(),
                is_now: false,
            },
            CalendarEvent {
                start: Some("2026-05-14T14:00:00Z".parse().unwrap()),
                end: Some("2026-05-14T15:00:00Z".parse().unwrap()),
                title: "Planning session".to_string(),
                status: "accepted".to_string(),
                is_now: false,
            },
        ],
        next: None,
        sweater: "sage".to_string(),
        stale: false,
        error: None,
    };
    let state = seeded_state(
        None,
        None,
        None,
        Some(calendar),
        None,
        vec![],
        None,
        None,
        None,
    );

    let input = fred::CalendarEventsInput { date: None };
    let result = fred::list_calendar_events(&state, &input);
    let events = result.as_array().expect("should return array");
    assert_eq!(events.len(), 2, "no date filter should return all 2 events");
}

#[tokio::test]
async fn fred_list_calendar_events_with_date_filters() {
    let calendar = CalendarSnapshot {
        events: vec![
            CalendarEvent {
                start: Some("2026-05-14T09:00:00Z".parse().unwrap()),
                end: Some("2026-05-14T10:00:00Z".parse().unwrap()),
                title: "Today's standup".to_string(),
                status: "accepted".to_string(),
                is_now: false,
            },
            CalendarEvent {
                start: Some("2026-05-15T14:00:00Z".parse().unwrap()),
                end: Some("2026-05-15T15:00:00Z".parse().unwrap()),
                title: "Tomorrow's planning".to_string(),
                status: "accepted".to_string(),
                is_now: false,
            },
        ],
        next: None,
        sweater: "amber".to_string(),
        stale: false,
        error: None,
    };
    let state = seeded_state(
        None,
        None,
        None,
        Some(calendar),
        None,
        vec![],
        None,
        None,
        None,
    );

    // Filter to 2026-05-14 — only the first event should match.
    let input = fred::CalendarEventsInput {
        date: Some("2026-05-14".to_string()),
    };
    let result = fred::list_calendar_events(&state, &input);
    let events = result.as_array().expect("should return array");
    assert_eq!(
        events.len(),
        1,
        "date filter should keep only events on that date"
    );
    assert_eq!(events[0]["title"], "Today's standup");
}

#[tokio::test]
async fn fred_get_state_fields() {
    let mailbox = fred_mailbox_fixture(); // unread_count: 2, 3 items total
    let calendar = CalendarSnapshot {
        events: vec![CalendarEvent {
            start: Some("2026-05-14T09:00:00Z".parse().unwrap()),
            end: None,
            title: "Standup".to_string(),
            status: "accepted".to_string(),
            is_now: true,
        }],
        next: None,
        sweater: "sage".to_string(),
        stale: false,
        error: None,
    };
    let state = seeded_state(
        None,
        None,
        Some(mailbox),
        Some(calendar),
        None,
        vec![],
        None,
        None,
        None,
    );

    let result = fred::get_state(&state);

    assert_eq!(result["unread_count"], 2);
    assert_eq!(result["today_event_count"], 1);
    assert!(result["mailbox"].is_array(), "mailbox should be an array");
    assert!(result["calendar"].is_array(), "calendar should be an array");

    let mailbox_arr = result["mailbox"].as_array().unwrap();
    assert_eq!(
        mailbox_arr.len(),
        3,
        "mailbox should include all 3 items (read + unread)"
    );

    let cal_arr = result["calendar"].as_array().unwrap();
    assert_eq!(cal_arr.len(), 1);
}

// ── mother tool tests ─────────────────────────────────────────────────────────

#[tokio::test]
async fn mother_list_jobs_no_filter() {
    let jobs = sample_mother_jobs(); // 3 jobs
    let state = seeded_state(None, None, None, None, None, jobs, None, None, None);

    let input = mother::ListJobsInput {
        include_archived: false,
        status: None,
    };
    let result = mother::list_jobs(&state, &input).await;
    let arr = result.as_array().expect("should return array");
    assert_eq!(arr.len(), 3, "no filter should return all 3 jobs");
}

#[tokio::test]
async fn mother_list_jobs_filter_by_status() {
    let jobs = sample_mother_jobs(); // 1 running, 1 queued, 1 awaiting
    let state = seeded_state(None, None, None, None, None, jobs, None, None, None);

    let input = mother::ListJobsInput {
        include_archived: false,
        status: Some("running".to_string()),
    };
    let result = mother::list_jobs(&state, &input).await;
    let arr = result.as_array().expect("should return array");
    assert_eq!(
        arr.len(),
        1,
        "status filter should keep only the running job"
    );
    assert_eq!(arr[0]["state"], "running");
    assert_eq!(arr[0]["id"], "job-running-1");
}

#[tokio::test]
async fn mother_get_job_returns_job() {
    let jobs = sample_mother_jobs();
    let state = seeded_state(None, None, None, None, None, jobs, None, None, None);

    let input = mother::GetJobInput {
        id: "job-awaiting-3".to_string(),
    };
    let result = mother::get_job(&state, &input);

    assert!(!result.is_null(), "get_job should find the job by id");
    assert_eq!(result["id"], "job-awaiting-3");
    assert_eq!(result["state"], "awaiting");
}

#[tokio::test]
async fn mother_get_job_returns_null_when_not_found() {
    let state = empty_state();

    let input = mother::GetJobInput {
        id: "no-such-job".to_string(),
    };
    let result = mother::get_job(&state, &input);
    assert!(
        result.is_null(),
        "get_job should return null for an unknown id"
    );
}

#[tokio::test]
async fn mother_get_status_returns_counts() {
    let status = MotherStatus {
        running: 2,
        queued: 3,
        failed: 1,
        awaiting: 1,
    };
    let state = seeded_state(
        None,
        None,
        None,
        None,
        None,
        vec![],
        Some(status),
        None,
        None,
    );

    let result = mother::get_status(&state);
    assert_eq!(result["running"], 2);
    assert_eq!(result["queued"], 3);
    assert_eq!(result["failed"], 1);
    assert_eq!(result["awaiting"], 1);
}

// ── teri tool tests ───────────────────────────────────────────────────────────

#[tokio::test]
async fn teri_list_todos_returns_items() {
    let snapshot = TeriTodosSnapshot {
        generated_at: None,
        items: vec![
            TeriTodo {
                id: 1,
                title: "Write Phase 2 tests".to_string(),
                status: "in_progress".to_string(),
                priority: 1,
                due_date: Some("2026-05-14".to_string()),
                jira_key: Some("CORE-123".to_string()),
            },
            TeriTodo {
                id: 2,
                title: "Review PR queue".to_string(),
                status: "open".to_string(),
                priority: 2,
                due_date: None,
                jira_key: None,
            },
        ],
        stale: false,
        error: None,
    };
    let state = seeded_state(
        None,
        None,
        None,
        None,
        Some(snapshot),
        vec![],
        None,
        None,
        None,
    );

    let result = teri::list_todos(&state);
    let items = result["items"]
        .as_array()
        .expect("items should be an array");
    assert_eq!(items.len(), 2);

    // Spot-check field shapes.
    assert_eq!(items[0]["id"], 1);
    assert_eq!(items[0]["title"], "Write Phase 2 tests");
    assert_eq!(items[0]["status"], "in_progress");
    assert_eq!(items[0]["priority"], 1);
    assert_eq!(items[0]["jira_key"], "CORE-123");

    assert_eq!(items[1]["id"], 2);
    assert!(items[1]["jira_key"].is_null());
}

// ── nostromo_meta tool tests ──────────────────────────────────────────────────

#[tokio::test]
async fn nostromo_get_rate_limits_returns_snapshot() {
    let rl = RateLimits {
        pct_5h: 42,
        reset_5h: 1715200000,
        pct_7d: 17,
        reset_7d: 1715800000,
    };
    let state = seeded_state(None, None, None, None, None, vec![], None, Some(rl), None);

    let result = nostromo_meta::get_rate_limits(&state);
    assert_eq!(result["pct_5h"], 42);
    assert_eq!(result["reset_5h"], 1715200000_i64);
    assert_eq!(result["pct_7d"], 17);
    assert_eq!(result["reset_7d"], 1715800000_i64);
}

#[tokio::test]
async fn nostromo_get_budget_posture_returns_posture() {
    let state = seeded_state(
        None,
        None,
        None,
        None,
        None,
        vec![],
        None,
        None,
        Some(BudgetPosture::Elevated),
    );

    let result = nostromo_meta::get_budget_posture(&state);
    // BudgetPosture serialises with #[serde(rename_all="lowercase")].
    assert_eq!(result, "elevated");
}

#[tokio::test]
async fn nostromo_get_worktree_info_in_git_repo() {
    // Run against the nostromo repo directory itself (this test runs from within it).
    let result = nostromo_meta::get_worktree_info(None).await;

    // Must not be an error response.
    assert!(
        result.get("error").is_none(),
        "get_worktree_info should not error in a git repo; got: {result}"
    );

    // Required keys must be present.
    assert!(result.get("cwd").is_some(), "response must include cwd");
    assert!(
        result.get("branch").is_some(),
        "response must include branch"
    );
    assert!(
        result.get("is_worktree").is_some(),
        "response must include is_worktree"
    );
    assert!(
        result.get("parent_repo").is_some(),
        "response must include parent_repo"
    );

    // branch must be a non-empty string.
    let branch = result["branch"]
        .as_str()
        .expect("branch should be a string");
    assert!(!branch.is_empty(), "branch should not be empty");

    // is_worktree must be a bool.
    assert!(
        result["is_worktree"].is_boolean(),
        "is_worktree should be a boolean"
    );
}

// ── get_view_state dispatch tests ─────────────────────────────────────────────

#[tokio::test]
async fn get_view_state_dispatches_perri() {
    let queue = perri_queue_fixture();
    let state = seeded_state(
        Some(queue),
        None,
        None,
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let input = get_view_state::GetViewStateInput {
        view_id: "perri".to_string(),
    };
    let result = get_view_state::handle(&state, &input).await;

    // get_view_state("perri") returns perri::get_state — must have queue, current_pr, stale.
    assert!(
        result.get("queue").is_some(),
        "perri state must include queue"
    );
    assert!(
        result.get("current_pr").is_some(),
        "perri state must include current_pr"
    );
    assert!(
        result.get("stale").is_some(),
        "perri state must include stale"
    );
}

#[tokio::test]
async fn get_view_state_dispatches_fred() {
    let mailbox = fred_mailbox_fixture();
    let state = seeded_state(
        None,
        None,
        Some(mailbox),
        None,
        None,
        vec![],
        None,
        None,
        None,
    );

    let input = get_view_state::GetViewStateInput {
        view_id: "fred".to_string(),
    };
    let result = get_view_state::handle(&state, &input).await;

    // get_view_state("fred") returns fred::get_state.
    assert!(result.get("unread_count").is_some());
    assert!(result.get("today_event_count").is_some());
    assert!(result.get("mailbox").is_some());
    assert!(result.get("calendar").is_some());
}

// ── error path tests ──────────────────────────────────────────────────────────

#[tokio::test]
async fn get_view_state_unknown_view_returns_error() {
    let state = empty_state();
    let input = get_view_state::GetViewStateInput {
        view_id: "no-such-view".to_string(),
    };
    let result = get_view_state::handle(&state, &input).await;
    assert_eq!(result["error"], "unknown_view");
}

#[tokio::test]
async fn fred_list_calendar_events_bad_date_returns_error() {
    let state = empty_state();
    let input = fred::CalendarEventsInput {
        date: Some("not-a-date".to_string()),
    };
    let result = fred::list_calendar_events(&state, &input);
    assert_eq!(result["error"], "bad_date");
}

#[tokio::test]
async fn dispatch_unknown_tool_returns_unknown_tool() {
    let state = empty_state();
    let result = tools::dispatch("completely.unknown.tool", None, &state, None).await;

    match result {
        tools::ToolResult::UnknownTool(name) => {
            assert_eq!(name, "completely.unknown.tool");
        }
        tools::ToolResult::Ok(_) => panic!("expected UnknownTool, got Ok"),
    }
}
