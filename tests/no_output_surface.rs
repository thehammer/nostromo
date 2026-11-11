//! Adding a tool? Classify what it can tell an agent about a terminal's output.
//! A tool that returns output, or anything derived from it, to a staging-only
//! follower cannot ship.
//!
//! Every tool the MCP server lists is classified in [`OUTPUT_CLASSIFICATION`]:
//!
//! * [`OutputReach::Never`]: the tool cannot return a terminal's output, or
//!   anything derived from it, to anyone.
//! * [`OutputReach::FullFollowerOnly`]: the tool returns redacted output only to
//!   a FULL follower of the terminal and refuses a staging-only one.
//!
//! There is no third class, on purpose: `reach_allowed` matches on the enum
//! exhaustively, so adding one fails to compile until someone decides what a
//! staging-only follower may get from it.
//!
//! The behavioural half (a staging-only follower of a terminal that prints
//! canaries the whole time never sees one, through any call) lives in
//! `src/terminal/staging/tests/s3.rs`. The shell-write half of the surface is
//! `tests/no_shell_surface.rs`.

use std::collections::BTreeSet;

use nostromo::mcp::tools::tool_descriptors;
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OutputReach {
    /// Cannot return a terminal's output, or anything derived from it, to anyone.
    Never,
    /// Returns redacted output to a full follower only; refuses a staging-only one.
    FullFollowerOnly,
}

use OutputReach::{FullFollowerOnly, Never};

const OUTPUT_CLASSIFICATION: &[(&str, OutputReach, &str)] = &[
    ("nostromo.get_self", Never, "the caller's own identity and focus metadata"),
    ("nostromo.list_views", Never, "view names"),
    (
        "nostromo.get_view_state",
        Never,
        "Perri/Fred/Mother/Teri state and render_state (pane ids only); no terminal session is read",
    ),
    ("nostromo.get_worktree_info", Never, "git worktree facts of the daemon's directory"),
    ("nostromo.get_rate_limits", Never, "Claude rate-limit figures"),
    ("nostromo.get_budget_posture", Never, "budget figures"),
    ("perri.list_pr_queue", Never, "the PR queue"),
    ("perri.get_current_pr", Never, "the PR under review"),
    ("perri.get_state", Never, "Perri's state"),
    ("fred.list_unread_emails", Never, "mail"),
    ("fred.list_calendar_events", Never, "the calendar"),
    ("fred.get_state", Never, "Fred's state"),
    ("mother.list_jobs", Never, "Mother's job list"),
    ("mother.get_job", Never, "one Mother job's metadata"),
    (
        "mother.tail_log",
        Never,
        "a Mother job's own log (an unattended job's, from the mother CLI), never a terminal pane's",
    ),
    (
        "mother.peek",
        Never,
        "a Mother job's own transcript (from the mother CLI), never a terminal pane's",
    ),
    ("mother.get_status", Never, "Mother's job counts"),
    ("huey.get_state", Never, "Huey's state"),
    ("huey.get_report", Never, "a Huey report document"),
    ("huey.get_context", Never, "Huey's context"),
    ("huey.list_reports", Never, "Huey report names"),
    ("huey.get_item", Never, "a Huey report item"),
    ("huey.show", Never, "puts a Huey report in a pane; returns the placement"),
    ("huey.regenerate", Never, "queues a report"),
    ("huey.record_verdict", Never, "records a verdict"),
    ("huey.trial_summary", Never, "trial figures"),
    ("huey.check_project", Never, "checks a project against a report"),
    ("huey.publish_report", Never, "publishes a report document"),
    ("teri.list_todos", Never, "todos"),
    ("teri.list_work_items", Never, "work items"),
    ("teri.get_work_item", Never, "a work item"),
    ("teri.get_picks", Never, "picks"),
    ("teri.publish_picks", Never, "publishes picks"),
    (
        "nostromo.set_pane_content",
        Never,
        "writes agent content into a non-terminal pane (a terminal target is refused); returns an ack",
    ),
    ("nostromo.set_pane_layout", Never, "changes a pane tree; returns an ack"),
    ("nostromo.create_pane", Never, "creates a pane; returns its id"),
    ("nostromo.reset_panes", Never, "resets a pane tree"),
    (
        "nostromo.apply_layout",
        Never,
        "binds sources to non-terminal panes (a terminal target is refused); returns the placement",
    ),
    (
        "nostromo.refresh_pane_content",
        Never,
        "re-fetches a bound source of a non-terminal pane (a terminal target is refused)",
    ),
    (
        "nostromo.show",
        Never,
        "shows a PR, file or ticket; never lands in or closes a terminal pane",
    ),
    ("nostromo.create_focus", Never, "creates a focus and starts an agent session"),
    (
        "nostromo.open_terminal",
        Never,
        "returns the new terminal's id and pane id only",
    ),
    (
        "nostromo.list_remote_shell_targets",
        Never,
        "the remote shell vocabulary from configuration files",
    ),
    (
        "nostromo.request_remote_shell",
        Never,
        "returns the new terminal's id and pane id, or a refusal code; on a failed connect, one code \
         from a fixed list and its fixed remedy, never any text the connect printed",
    ),
    (
        "nostromo.list_terminals",
        Never,
        "terminal metadata: id, label, kind, status, followed_by_you, follow_mode",
    ),
    (
        "nostromo.request_follow",
        Never,
        "returns an outcome code; output reaches a full follower as deliveries, never in this result",
    ),
    (
        "nostromo.read_terminal_screen",
        FullFollowerOnly,
        "the redacted screen, to a full follower only; a staging-only follower gets terminal_read_forbidden",
    ),
    (
        "nostromo.terminal_staging",
        Never,
        "the follower's own display list (what agents staged, insert counts); the foreground program is never rendered",
    ),
    ("perri.load_pr", Never, "loads a PR"),
    ("perri.clear_current_pr", Never, "clears the current PR"),
    ("perri.set_selected_index", Never, "sets a selection"),
    ("perri.get_selected_index", Never, "reads a selection"),
    ("mother.enqueue_job", Never, "queues an unattended job"),
    ("mother.cancel_job", Never, "cancels a job"),
    ("mother.archive_job", Never, "archives a job"),
    ("mother.resume_job", Never, "resumes a job"),
    ("mother.retry_job", Never, "retries a job"),
    ("nostromo.ask_decision", Never, "returns the user's chosen answer"),
    ("nostromo.get_render_state", Never, "pane ids each window rendered"),
    ("nostromo.get_daemon_diagnostics", Never, "latency figures"),
    ("nostromo.tracker", Never, "the agent tracker's board"),
];

/// May a tool of this class ship? An exhaustive match: a third class does not
/// compile until it is decided here.
fn reach_allowed(reach: OutputReach) -> bool {
    match reach {
        OutputReach::Never => true,
        OutputReach::FullFollowerOnly => true,
    }
}

fn names(descriptors: &[Value]) -> Vec<String> {
    descriptors
        .iter()
        .filter_map(|d| d["name"].as_str().map(str::to_string))
        .collect()
}

/// What is wrong with `table` as the classification of the tools `listed`
/// (empty when nothing is).
fn classification_problems(listed: &[String], table: &[(&str, OutputReach, &str)]) -> Vec<String> {
    let mut problems = Vec::new();
    for name in listed {
        if !table.iter().any(|(n, _, _)| n == name) {
            problems.push(format!(
                "{name} is listed but not classified in OUTPUT_CLASSIFICATION"
            ));
        }
    }
    let mut seen = BTreeSet::new();
    for (name, reach, reason) in table {
        if !listed.iter().any(|n| n == name) {
            problems.push(format!("{name} is classified but no such tool is listed"));
        }
        if !seen.insert(*name) {
            problems.push(format!("{name} is classified twice"));
        }
        if !reach_allowed(*reach) {
            problems.push(format!("{name}: {reach:?} cannot ship"));
        }
        if reason.trim().is_empty() {
            problems.push(format!("{name}: a classification needs a reason"));
        }
    }
    problems
}

#[test]
fn every_listed_tool_is_classified_once_by_what_it_can_tell_an_agent_about_terminal_output() {
    let listed = names(&tool_descriptors());
    assert!(
        listed.len() >= 60,
        "the server lists {} tools",
        listed.len()
    );
    let problems = classification_problems(&listed, OUTPUT_CLASSIFICATION);
    assert!(problems.is_empty(), "{problems:#?}");
}

#[test]
fn only_the_screen_read_returns_output_and_only_to_a_full_follower() {
    let full_only: Vec<&str> = OUTPUT_CLASSIFICATION
        .iter()
        .filter(|(_, reach, _)| *reach == FullFollowerOnly)
        .map(|(name, _, _)| *name)
        .collect();
    assert_eq!(full_only, ["nostromo.read_terminal_screen"]);
}

#[test]
fn a_tool_missing_from_the_table_fails_the_check() {
    let mut listed = names(&tool_descriptors());
    listed.push("nostromo.terminal_y".to_string());
    let problems = classification_problems(&listed, OUTPUT_CLASSIFICATION);
    assert_eq!(problems.len(), 1, "{problems:?}");
    assert!(
        problems[0].contains("nostromo.terminal_y") && problems[0].contains("not classified"),
        "{problems:?}"
    );
    // The synthetic descriptor, built as the server builds one, is caught the same way.
    let synthetic = vec![json!({
        "name": "nostromo.terminal_y",
        "description": "made up",
        "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    })];
    let problems = classification_problems(&names(&synthetic), &[]);
    assert_eq!(problems.len(), 1, "{problems:?}");
}

#[test]
fn a_stale_or_duplicated_entry_fails_the_check() {
    let listed = vec!["nostromo.read_terminal_screen".to_string()];
    let stale = classification_problems(
        &listed,
        &[
            ("nostromo.read_terminal_screen", FullFollowerOnly, "reads"),
            ("nostromo.gone", Never, "no such tool"),
        ],
    );
    assert_eq!(stale.len(), 1, "{stale:?}");
    assert!(stale[0].contains("nostromo.gone"), "{stale:?}");

    let twice = classification_problems(
        &listed,
        &[
            ("nostromo.read_terminal_screen", FullFollowerOnly, "reads"),
            ("nostromo.read_terminal_screen", Never, "again"),
        ],
    );
    assert_eq!(twice.len(), 1, "{twice:?}");
    assert!(twice[0].contains("twice"), "{twice:?}");

    let no_reason = classification_problems(
        &listed,
        &[("nostromo.read_terminal_screen", FullFollowerOnly, " ")],
    );
    assert_eq!(no_reason.len(), 1, "{no_reason:?}");
}

#[test]
fn the_screen_read_descriptor_says_a_staging_only_follower_is_refused() {
    let descriptor = tool_descriptors()
        .into_iter()
        .find(|d| d["name"] == "nostromo.read_terminal_screen")
        .expect("the screen read is listed");
    let description = descriptor["description"].as_str().unwrap();
    assert!(
        description.contains("terminal_read_forbidden") && description.contains("staging only"),
        "{description}"
    );
}
