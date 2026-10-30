//! Adding a tool? Classify it here. A tool that can write to a shell cannot ship.
//!
//! Every tool the MCP server lists is classified in [`SHELL_WRITE_CLASSIFICATION`]
//! (and must be `Never`). A tool whose input schema carries a property that names
//! a terminal, a shell, or a command is listed in
//! [`DOCUMENTED_PROPERTY_EXCEPTIONS`] with the reason it is harmless: the table
//! can only be widened deliberately, and a stale entry fails the test.
//!
//! The behavioural half of the proof (no staging path puts a byte into a shell)
//! lives in `src/terminal/staging/tests.rs`. Tracker T4 extends this file; it
//! does not replace it.

use nostromo::mcp::tools::tool_descriptors;
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ShellWrite {
    /// The tool cannot cause a byte to be written to a shell.
    Never,
    /// Reserved: a tool of this class cannot ship.
    #[allow(dead_code)]
    Can,
}

use ShellWrite::Never;

const SHELL_WRITE_CLASSIFICATION: &[(&str, ShellWrite, &str)] = &[
    ("nostromo.get_self", Never, "reads the caller's own identity"),
    ("nostromo.list_views", Never, "lists views"),
    ("nostromo.get_view_state", Never, "reads a view's state"),
    ("nostromo.get_worktree_info", Never, "reads git worktree facts"),
    ("nostromo.get_rate_limits", Never, "reads rate limits"),
    ("nostromo.get_budget_posture", Never, "reads budget posture"),
    ("perri.list_pr_queue", Never, "reads the PR queue"),
    ("perri.get_current_pr", Never, "reads the current PR"),
    ("perri.get_state", Never, "reads Perri's state"),
    ("fred.list_unread_emails", Never, "reads mail"),
    ("fred.list_calendar_events", Never, "reads the calendar"),
    ("fred.get_state", Never, "reads Fred's state"),
    ("mother.list_jobs", Never, "reads Mother's job list"),
    ("mother.get_job", Never, "reads one Mother job"),
    ("mother.tail_log", Never, "reads a job's log"),
    ("mother.peek", Never, "reads a job's transcript"),
    ("mother.get_status", Never, "reads Mother's status"),
    ("huey.get_state", Never, "reads Huey's state"),
    ("huey.get_report", Never, "reads a Huey report"),
    ("huey.get_context", Never, "reads Huey's context"),
    ("huey.list_reports", Never, "lists Huey reports"),
    ("huey.get_item", Never, "reads a Huey item"),
    ("huey.show", Never, "shows a Huey report in a pane"),
    ("huey.regenerate", Never, "queues a Huey report"),
    ("huey.record_verdict", Never, "records a verdict"),
    ("huey.trial_summary", Never, "reads trial figures"),
    ("huey.check_project", Never, "checks a project against a report"),
    ("huey.publish_report", Never, "publishes a report document"),
    ("teri.list_todos", Never, "reads todos"),
    ("teri.list_work_items", Never, "reads work items"),
    ("teri.get_work_item", Never, "reads a work item"),
    ("teri.get_picks", Never, "reads picks"),
    ("teri.publish_picks", Never, "publishes picks"),
    ("nostromo.set_pane_content", Never, "sets pane content (display)"),
    ("nostromo.set_pane_layout", Never, "sets a pane layout"),
    ("nostromo.create_pane", Never, "creates a pane"),
    ("nostromo.reset_panes", Never, "resets panes"),
    ("nostromo.apply_layout", Never, "applies a layout"),
    ("nostromo.refresh_pane_content", Never, "refreshes pane content"),
    ("nostromo.show", Never, "shows a PR, file or ticket in a pane (display)"),
    ("nostromo.create_focus", Never, "creates a focus and starts an agent session"),
    ("nostromo.open_terminal", Never, "opens a shell; takes no command, argument or input"),
    ("nostromo.list_remote_shell_targets", Never, "reads the remote shell vocabulary"),
    ("nostromo.request_remote_shell", Never, "asks the user; the user connects and types"),
    ("nostromo.list_terminals", Never, "lists terminal metadata"),
    ("nostromo.request_follow", Never, "asks the user; follow is read-only"),
    ("nostromo.read_terminal_screen", Never, "reads a redacted screen"),
    (
        "nostromo.terminal_staging",
        Never,
        "cannot write to a shell: edits a display list; insertion requires a human click in the app",
    ),
    ("perri.load_pr", Never, "loads a PR"),
    ("perri.clear_current_pr", Never, "clears the current PR"),
    ("perri.set_selected_index", Never, "sets a selection"),
    ("perri.get_selected_index", Never, "reads a selection"),
    ("mother.enqueue_job", Never, "queues an unattended job; no shell of the user's"),
    ("mother.cancel_job", Never, "cancels a job"),
    ("mother.archive_job", Never, "archives a job"),
    ("mother.resume_job", Never, "resumes a job"),
    ("mother.retry_job", Never, "retries a job"),
    ("nostromo.ask_decision", Never, "asks the user a question"),
    ("nostromo.get_render_state", Never, "reads render state"),
    ("nostromo.get_daemon_diagnostics", Never, "reads latency figures"),
    ("nostromo.tracker", Never, "edits a board file; a command item is text the user copies"),
];

/// Property names that suggest a path to a shell.
const SUSPECT_PROPERTIES: &[&str] = &[
    "pty",
    "pty_id_target",
    "terminal",
    "terminal_id",
    "tmux",
    "tmux_target",
    "shell",
    "stdin",
    "input_bytes",
    "keys",
    "send_keys",
    "paste_target",
    "command",
];

/// `(tool, property, reason)`: a suspect property that is harmless on that tool.
const DOCUMENTED_PROPERTY_EXCEPTIONS: &[(&str, &str, &str)] = &[
    (
        "nostromo.request_follow",
        "terminal_id",
        "names the terminal to ask the user to let the agent follow; follow is read-only",
    ),
    (
        "nostromo.read_terminal_screen",
        "terminal_id",
        "names the followed terminal whose redacted screen is read; nothing is written",
    ),
    (
        "nostromo.terminal_staging",
        "terminal_id",
        "names the followed terminal whose display list it edits; no byte reaches that terminal",
    ),
    (
        "nostromo.terminal_staging",
        "command",
        "display text only: single-line, printable, ≤ 1,000 chars; the app inserts it only on a human click and never adds a line break",
    ),
    (
        "nostromo.tracker",
        "command",
        "text of a tracker 'command' item stored on the board; nothing writes it to a shell (tracker T4 adds its own proof)",
    ),
];

/// `op` values that read as acting on a shell.
const SUSPECT_OP_VALUES: &[&str] = &["run", "exec", "execute", "send", "paste", "insert"];

/// `(tool, op value, reason)`: a suspect `op` value that is harmless.
const DOCUMENTED_OP_EXCEPTIONS: &[(&str, &str, &str)] = &[];

fn names(descriptors: &[Value]) -> Vec<String> {
    descriptors
        .iter()
        .filter_map(|d| d["name"].as_str().map(str::to_string))
        .collect()
}

/// Every property name in the schema, at any depth.
fn property_names(schema: &Value, out: &mut Vec<String>) {
    match schema {
        Value::Object(map) => {
            for (key, value) in map {
                if key == "properties" {
                    if let Value::Object(props) = value {
                        for (name, sub) in props {
                            out.push(name.clone());
                            property_names(sub, out);
                        }
                        continue;
                    }
                }
                property_names(value, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|v| property_names(v, out)),
        _ => {}
    }
}

/// Every `enum` value of a property called `op`, at any depth.
fn op_values(schema: &Value, out: &mut Vec<String>) {
    match schema {
        Value::Object(map) => {
            for (key, value) in map {
                if key == "properties" {
                    if let Value::Object(props) = value {
                        for (name, sub) in props {
                            if name == "op" {
                                if let Some(values) = sub["enum"].as_array() {
                                    out.extend(
                                        values
                                            .iter()
                                            .filter_map(|v| v.as_str().map(str::to_string)),
                                    );
                                }
                            }
                            op_values(sub, out);
                        }
                        continue;
                    }
                }
                op_values(value, out);
            }
        }
        Value::Array(items) => items.iter().for_each(|v| op_values(v, out)),
        _ => {}
    }
}

/// What is wrong with `descriptors` (empty when nothing is).
fn violations(
    descriptors: &[Value],
    exceptions: &[(&str, &str, &str)],
    op_exceptions: &[(&str, &str, &str)],
) -> Vec<String> {
    let mut found = Vec::new();
    for descriptor in descriptors {
        let tool = descriptor["name"].as_str().unwrap_or("<unnamed>");
        let mut props = Vec::new();
        property_names(&descriptor["inputSchema"], &mut props);
        props.sort();
        props.dedup();
        for prop in props {
            if SUSPECT_PROPERTIES.contains(&prop.as_str())
                && !exceptions.iter().any(|(t, p, _)| *t == tool && *p == prop)
            {
                found.push(format!(
                    "{tool}: property `{prop}` is not a documented exception"
                ));
            }
        }
        let mut ops = Vec::new();
        op_values(&descriptor["inputSchema"], &mut ops);
        for op in ops {
            if SUSPECT_OP_VALUES.contains(&op.as_str())
                && !op_exceptions.iter().any(|(t, o, _)| *t == tool && *o == op)
            {
                found.push(format!(
                    "{tool}: `op` value `{op}` is not a documented exception"
                ));
            }
        }
    }
    found
}

#[test]
fn every_tool_is_classified_and_none_can_write_to_a_shell() {
    let listed = names(&tool_descriptors());
    let unclassified: Vec<&String> = listed
        .iter()
        .filter(|name| {
            !SHELL_WRITE_CLASSIFICATION
                .iter()
                .any(|(n, _, _)| n == *name)
        })
        .collect();
    assert!(
        unclassified.is_empty(),
        "listed but not classified in SHELL_WRITE_CLASSIFICATION: {unclassified:?}"
    );
    for (name, class, reason) in SHELL_WRITE_CLASSIFICATION {
        assert!(
            listed.iter().any(|n| n == name),
            "{name} is classified but no such tool is listed"
        );
        assert_eq!(*class, Never, "{name} can write to a shell: it cannot ship");
        assert!(
            !reason.is_empty(),
            "{name}: a classification needs a reason"
        );
    }
    let mut seen = std::collections::BTreeSet::new();
    for (name, _, _) in SHELL_WRITE_CLASSIFICATION {
        assert!(seen.insert(*name), "{name} is classified twice");
    }
}

#[test]
fn the_staging_tool_is_classified_with_its_documented_reason() {
    let entry = SHELL_WRITE_CLASSIFICATION
        .iter()
        .find(|(n, _, _)| *n == "nostromo.terminal_staging")
        .expect("the staging tool is classified");
    assert_eq!(
        entry.2,
        "cannot write to a shell: edits a display list; insertion requires a human click in the app"
    );
}

#[test]
fn no_tool_carries_a_shell_shaped_property_beyond_the_documented_exceptions() {
    let found = violations(
        &tool_descriptors(),
        DOCUMENTED_PROPERTY_EXCEPTIONS,
        DOCUMENTED_OP_EXCEPTIONS,
    );
    assert!(found.is_empty(), "{found:#?}");
}

#[test]
fn every_documented_exception_names_a_real_tool_and_property() {
    let descriptors = tool_descriptors();
    for (tool, prop, reason) in DOCUMENTED_PROPERTY_EXCEPTIONS {
        assert!(
            !reason.is_empty(),
            "{tool}.{prop}: an exception needs a reason"
        );
        let descriptor = descriptors
            .iter()
            .find(|d| d["name"] == *tool)
            .unwrap_or_else(|| panic!("stale exception: no tool `{tool}`"));
        let mut props = Vec::new();
        property_names(&descriptor["inputSchema"], &mut props);
        assert!(
            props.iter().any(|p| p == prop),
            "stale exception: `{tool}` has no property `{prop}`"
        );
    }
    for (tool, op, reason) in DOCUMENTED_OP_EXCEPTIONS {
        assert!(
            !reason.is_empty(),
            "{tool}.{op}: an exception needs a reason"
        );
        let descriptor = descriptors
            .iter()
            .find(|d| d["name"] == *tool)
            .unwrap_or_else(|| panic!("stale exception: no tool `{tool}`"));
        let mut ops = Vec::new();
        op_values(&descriptor["inputSchema"], &mut ops);
        assert!(
            ops.iter().any(|o| o == op),
            "stale exception: `{tool}` has no op `{op}`"
        );
    }
}

#[test]
fn the_staging_op_enum_is_exactly_the_five_display_list_ops() {
    let descriptor = tool_descriptors()
        .into_iter()
        .find(|d| d["name"] == "nostromo.terminal_staging")
        .expect("the staging tool is listed");
    let ops: Vec<&str> = descriptor["inputSchema"]["properties"]["op"]["enum"]
        .as_array()
        .expect("op enum")
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(ops, ["list", "stage", "replace", "remove", "clear"]);
}

#[test]
fn the_check_is_per_tool_and_property_not_global() {
    let synthetic = vec![json!({
        "name": "nostromo.terminal_x",
        "description": "made up",
        "inputSchema": {
            "type": "object",
            "properties": { "command": { "type": "string" } },
            "additionalProperties": false
        }
    })];
    let found = violations(
        &synthetic,
        DOCUMENTED_PROPERTY_EXCEPTIONS,
        DOCUMENTED_OP_EXCEPTIONS,
    );
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("nostromo.terminal_x") && found[0].contains("command"));
}

#[test]
fn a_nested_suspect_property_and_a_suspect_op_value_are_both_caught() {
    let synthetic = vec![json!({
        "name": "nostromo.other",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ops": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "op": { "enum": ["list", "paste"] },
                            "stdin": { "type": "string" }
                        }
                    }
                }
            }
        }
    })];
    let found = violations(&synthetic, &[], &[]);
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found.iter().any(|f| f.contains("stdin")));
    assert!(found.iter().any(|f| f.contains("paste")));
}
