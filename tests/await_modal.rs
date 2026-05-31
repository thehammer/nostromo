//! Render the await modal into a test backend and assert it contains the
//! expected content: job id, question text, and all four key hints.

use ratatui::{backend::TestBackend, Terminal};

use nostromo::{mother::MotherJob, views::await_modal::AwaitModal};

fn make_test_job() -> MotherJob {
    MotherJob {
        id: "test-job-abc123".to_string(),
        state: "awaiting".to_string(),
        repo: "admin-portal".to_string(),
        isolation: "worktree".to_string(),
        title: "Example awaiting job".to_string(),
        created_at: None,
        started_at: None,
        finished_at: None,
        plan_path: Some("/tmp/plan.md".to_string()),
        question: Some("Should we use option A or option B for the migration?".to_string()),
        paused_reason: Some("user".to_string()),
        adherence_status: None,
        current_tier: Some("tier_0".to_string()),
        current_activity: None,
    }
}

fn render_to_string(modal: &AwaitModal, width: u16, height: u16) -> String {
    let backend = TestBackend::new(width, height);
    let mut terminal = Terminal::new(backend).unwrap();
    terminal
        .draw(|f| {
            modal.render(f, f.area());
        })
        .unwrap();
    let buf = terminal.backend().buffer().clone();
    // Collect all cells into rows.
    (0..height)
        .map(|row| {
            (0..width)
                .map(|col| buf[(col, row)].symbol().to_string())
                .collect::<String>()
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn modal_contains_job_id() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("test-job-abc123"),
        "modal should show job id; got:\n{output}"
    );
}

#[test]
fn modal_contains_question() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("option A") || output.contains("Should we"),
        "modal should show question; got:\n{output}"
    );
}

#[test]
fn modal_contains_approve_hint() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("[a]") || output.contains("approve"),
        "modal should show approve hint; got:\n{output}"
    );
}

#[test]
fn modal_contains_deny_hint() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("[d]") || output.contains("deny"),
        "modal should show deny hint; got:\n{output}"
    );
}

#[test]
fn modal_contains_view_diff_hint() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("[v]") || output.contains("view diff"),
        "modal should show view diff hint; got:\n{output}"
    );
}

#[test]
fn modal_contains_dismiss_hint() {
    let modal = AwaitModal::new(make_test_job());
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("[esc]") || output.contains("esc") || output.contains("dismiss"),
        "modal should show dismiss hint; got:\n{output}"
    );
}

#[test]
fn modal_no_question_shows_fallback() {
    let mut job = make_test_job();
    job.question = None;
    let modal = AwaitModal::new(job);
    let output = render_to_string(&modal, 100, 30);
    assert!(
        output.contains("no question"),
        "modal should show fallback text; got:\n{output}"
    );
}
