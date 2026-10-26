//! T8: the production-shell guard and the remote-shell request tools agree.
//!
//! Agents are blocked from opening a remote shell themselves (the `ecs_*` shell
//! functions, `aws ecs execute-command`, tmux panes running them) by the
//! approvals guard (`nostromo::approvals::guard::evaluate`), and offered one
//! sanctioned path instead: ask the user through
//! `nostromo.request_remote_shell`. These tests pin that the two layers fit
//! together:
//!
//! * the guard must never block either new tool, by name or by input (or the
//!   sanctioned path would be shut by the rule it exists to route around);
//! * the guard must still block every way an agent could open a shell itself,
//!   so that the request path is the only one open;
//! * no terminal or remote-shell tool offers a field an agent could put a
//!   command in, and the guard's own command scan would catch one if it did.
//!
//! The guard's tool-name rule is private (`tool_name_re`), so its pattern is
//! copied below as a literal and also exercised through `evaluate`.
//!
//! Slice 3d re-asserts the same for the three follow tools
//! (`nostromo.list_terminals`, `nostromo.request_follow`,
//! `nostromo.read_terminal_screen`): the guard must allow them by name and by
//! input, none offers a field a command could go in, and the terminal-attempt
//! classifier must not take any registered name for a terminal write, read or
//! close.

use std::path::PathBuf;

use nostromo::approvals::guard::{
    evaluate, GuardVerdict, HookPayload, PaneInfo, PaneProbe, ProbeError, TmuxSocket, RULE_COMMAND,
    RULE_TOOL_NAME,
};
use nostromo::mcp::tools::terminal::classify_terminal_attempt;
use nostromo::mcp::tools::tool_descriptors;
use regex::Regex;
use serde_json::{json, Value};

const REQUEST: &str = "nostromo.request_remote_shell";
const LIST: &str = "nostromo.list_remote_shell_targets";
/// What the tools are called inside an agent (dots become underscores in the
/// agent's tool namespace: `mcp__<server>__<tool>`).
const REQUEST_AS_SEEN_BY_THE_AGENT: &str = "mcp__nostromo__nostromo_request_remote_shell";
const LIST_AS_SEEN_BY_THE_AGENT: &str = "mcp__nostromo__nostromo_list_remote_shell_targets";

/// The three follow tools (3d), as registered, and as an agent sees them.
const LIST_TERMINALS: &str = "nostromo.list_terminals";
const REQUEST_FOLLOW: &str = "nostromo.request_follow";
const READ_SCREEN: &str = "nostromo.read_terminal_screen";
const FOLLOW_TOOLS: [(&str, &str); 3] = [
    (LIST_TERMINALS, "mcp__nostromo__nostromo_list_terminals"),
    (REQUEST_FOLLOW, "mcp__nostromo__nostromo_request_follow"),
    (READ_SCREEN, "mcp__nostromo__nostromo_read_terminal_screen"),
];

/// A copy of the guard's tool-name pattern (`approvals/guard.rs`, `tool_name_re`,
/// with the run-task alternative included). If the guard's pattern changes,
/// change this too; the `evaluate` assertions below are the real check.
const GUARD_TOOL_NAME_PATTERN: &str = "(?i)(ecs_connect|ecs_shell|ecs_open_tmux_pane|ecs_run_task)";

/// No tmux, no ps: every payload here is decided without looking at a pane,
/// and a probe call would mean the guard went somewhere it should not.
struct NoWorld;

impl PaneProbe for NoWorld {
    fn pane(&self, _: &TmuxSocket, _: &str) -> Result<Option<PaneInfo>, ProbeError> {
        panic!("the guard probed a pane");
    }
    fn all_panes(&self, _: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        panic!("the guard listed panes");
    }
    fn subtree_args(&self, _: u32) -> Result<Vec<String>, ProbeError> {
        panic!("the guard read a process tree");
    }
    fn servers(&self, _: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        panic!("the guard looked for tmux servers");
    }
}

fn pre_tool_use(tool: &str, tool_input: Value) -> HookPayload {
    serde_json::from_value(json!({
        "session_id": "s-1",
        "tool_use_id": "toolu_1",
        "hook_event_name": "PreToolUse",
        "permission_mode": "bypassPermissions",
        "cwd": "/tmp",
        "tool_name": tool,
        "tool_input": tool_input,
    }))
    .expect("a hook payload")
}

fn verdict(payload: &HookPayload) -> GuardVerdict {
    evaluate(payload, &NoWorld).expect("the guard decides without probing")
}

fn blocked_by(payload: &HookPayload) -> Option<&'static str> {
    match verdict(payload) {
        GuardVerdict::Block { rule_id, .. } => Some(rule_id),
        GuardVerdict::Allow => None,
    }
}

fn valid_request_input() -> Value {
    json!({
        "project": "admin-portal",
        "environment": "production",
        "service": "scheduler",
        "shell_type": "shell",
        "reason": "check aws ecs execute-command logs",
    })
}

// ── the request path is open ─────────────────────────────────────────────────

#[test]
fn the_guards_tool_name_rule_does_not_match_either_remote_shell_tool() {
    let rule = Regex::new(GUARD_TOOL_NAME_PATTERN).unwrap();

    for name in [
        REQUEST,
        LIST,
        REQUEST_AS_SEEN_BY_THE_AGENT,
        LIST_AS_SEEN_BY_THE_AGENT,
    ] {
        assert!(!rule.is_match(name), "{name} would be blocked by name");
        let payload = pre_tool_use(name, json!({}));
        assert_eq!(blocked_by(&payload), None, "{name}: the guard blocked it");
    }
}

#[test]
fn the_guard_allows_the_request_tool_with_a_valid_request_whatever_the_reason_says() {
    let valid = pre_tool_use(REQUEST_AS_SEEN_BY_THE_AGENT, valid_request_input());
    assert_eq!(verdict(&valid), GuardVerdict::Allow);

    // A reason is data: mentioning the thing the guard looks for is not
    // running it.
    for reason in [
        "check aws ecs execute-command logs",
        "ecs_connect is blocked for me, so I am asking you",
        "aws ssm start-session --target i-123 is what I would have run",
        "ecs_shell ap production scheduler",
        "session-manager-plugin",
    ] {
        let mut input = valid_request_input();
        input["reason"] = json!(reason);
        let payload = pre_tool_use(REQUEST_AS_SEEN_BY_THE_AGENT, input.clone());
        assert_eq!(
            verdict(&payload),
            GuardVerdict::Allow,
            "reason {reason:?} must be treated as data"
        );
        let dotted = pre_tool_use(REQUEST, input);
        assert_eq!(verdict(&dotted), GuardVerdict::Allow, "{reason:?}");
    }
}

#[test]
fn the_guard_allows_the_list_tool() {
    for name in [LIST, LIST_AS_SEEN_BY_THE_AGENT] {
        assert_eq!(
            verdict(&pre_tool_use(name, json!({}))),
            GuardVerdict::Allow,
            "{name}"
        );
    }
}

// ── every other way in is shut ───────────────────────────────────────────────

#[test]
fn the_guard_still_blocks_the_ways_an_agent_could_open_a_shell_itself() {
    // The ECS shell tools, by name (in any namespace).
    for tool in [
        "ecs_connect",
        "ecs_shell",
        "ecs_open_tmux_pane",
        "mcp__nostromo__ecs_shell",
        "mcp__carefeed__ecs_connect",
    ] {
        assert_eq!(
            blocked_by(&pre_tool_use(tool, json!({}))),
            Some(RULE_TOOL_NAME),
            "{tool}"
        );
    }

    // The raw commands, from a shell tool.
    for command in [
        "aws ecs execute-command --cluster c --task t --interactive --command bash",
        "aws ssm start-session --target i-0123456789",
        "ecs_connect ap production scheduler",
        "ecs_shell ap prod sched",
    ] {
        assert_eq!(
            blocked_by(&pre_tool_use("Bash", json!({ "command": command }))),
            Some(RULE_COMMAND),
            "{command}"
        );
    }
}

#[test]
fn a_command_smuggled_into_the_request_tools_input_is_caught_by_the_guard_too() {
    // The MCP tool refuses any key beyond its five (`unknown_argument`); the
    // guard, which sees the call first, reads `command`, `cmd` and `script`
    // wherever they appear. Two independent layers.
    for key in ["command", "cmd", "script"] {
        let mut input = valid_request_input();
        input[key] = json!("aws ecs execute-command --cluster c --task t --command bash");
        assert_eq!(
            blocked_by(&pre_tool_use(REQUEST_AS_SEEN_BY_THE_AGENT, input)),
            Some(RULE_COMMAND),
            "{key}"
        );
    }
}

#[test]
fn together_the_two_layers_leave_only_the_request_path_open() {
    let open: Vec<&str> = [
        (
            "Bash",
            json!({"command": "aws ecs execute-command --cluster c --task t --command bash"}),
        ),
        ("mcp__nostromo__ecs_shell", json!({})),
        (REQUEST_AS_SEEN_BY_THE_AGENT, valid_request_input()),
        (LIST_AS_SEEN_BY_THE_AGENT, json!({})),
    ]
    .iter()
    .filter(|(tool, input)| blocked_by(&pre_tool_use(tool, input.clone())).is_none())
    .map(|(tool, _)| *tool)
    .collect();

    assert_eq!(
        open,
        vec![REQUEST_AS_SEEN_BY_THE_AGENT, LIST_AS_SEEN_BY_THE_AGENT]
    );
}

// ── the tool surface itself ──────────────────────────────────────────────────

fn terminal_or_shell_tools() -> Vec<Value> {
    tool_descriptors()
        .into_iter()
        .filter(|t| {
            let name = t["name"].as_str().unwrap_or_default().to_ascii_lowercase();
            name.contains("terminal") || name.contains("shell")
        })
        .collect()
}

#[test]
fn both_remote_shell_tools_are_registered() {
    let names: Vec<String> = tool_descriptors()
        .iter()
        .filter_map(|t| t["name"].as_str().map(str::to_string))
        .collect();

    assert!(names.iter().any(|n| n == REQUEST), "{names:?}");
    assert!(names.iter().any(|n| n == LIST), "{names:?}");
    let found: Vec<String> = terminal_or_shell_tools()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    assert!(found.contains(&REQUEST.to_string()) && found.contains(&LIST.to_string()));
}

#[test]
fn no_terminal_or_shell_tool_has_a_field_a_command_could_go_in() {
    let tools = terminal_or_shell_tools();
    assert!(
        tools.len() >= 3,
        "open_terminal and the two remote tools at least"
    );

    for tool in &tools {
        let name = tool["name"].as_str().unwrap();
        let schema = &tool["inputSchema"];
        assert_eq!(
            schema["additionalProperties"],
            json!(false),
            "{name}: the schema must refuse extra keys"
        );
        let properties = schema["properties"].as_object().expect("properties");
        for forbidden in [
            "command", "cmd", "script", "args", "argv", "input", "keys", "text", "env",
        ] {
            assert!(
                !properties.contains_key(forbidden),
                "{name} offers a `{forbidden}` field"
            );
        }
    }
}

#[test]
fn the_request_tool_takes_exactly_four_required_words_and_an_optional_reason() {
    let tool = tool_descriptors()
        .into_iter()
        .find(|t| t["name"] == REQUEST)
        .expect("the request tool");
    let schema = &tool["inputSchema"];

    let mut properties: Vec<&str> = schema["properties"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    properties.sort_unstable();
    assert_eq!(
        properties,
        ["environment", "project", "reason", "service", "shell_type"]
    );
    let mut required: Vec<&str> = schema["required"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    required.sort_unstable();
    assert_eq!(
        required,
        ["environment", "project", "service", "shell_type"]
    );
    for (name, property) in schema["properties"].as_object().unwrap() {
        assert_eq!(property["type"], "string", "{name}");
    }
}

#[test]
fn the_list_tool_takes_no_arguments() {
    let tool = tool_descriptors()
        .into_iter()
        .find(|t| t["name"] == LIST)
        .expect("the list tool");

    assert_eq!(tool["inputSchema"]["properties"], json!({}));
    assert_eq!(tool["inputSchema"]["additionalProperties"], json!(false));
}

#[test]
fn neither_remote_shell_tool_looks_like_a_way_to_write_read_or_close_a_terminal() {
    for name in [
        REQUEST,
        LIST,
        REQUEST_AS_SEEN_BY_THE_AGENT,
        LIST_AS_SEEN_BY_THE_AGENT,
    ] {
        assert!(
            classify_terminal_attempt(name).is_none(),
            "{name} is classified as a terminal input/read/close attempt"
        );
    }
}

// ── the follow tools (3d) ────────────────────────────────────────────────────

/// Plausible calls of each follow tool, valid and benign.
fn follow_tool_input(registered: &str) -> Value {
    match registered {
        LIST_TERMINALS => json!({}),
        REQUEST_FOLLOW => json!({
            "terminal_id": "terminal-1a2b3c4d",
            "reason": "check why the nightly job did not run",
        }),
        READ_SCREEN => json!({ "terminal_id": "terminal-1a2b3c4d" }),
        other => panic!("not a follow tool: {other}"),
    }
}

#[test]
fn the_guards_tool_name_rule_does_not_match_any_follow_tool() {
    let rule = Regex::new(GUARD_TOOL_NAME_PATTERN).unwrap();

    for (registered, seen) in FOLLOW_TOOLS {
        for name in [registered, seen] {
            assert!(!rule.is_match(name), "{name} would be blocked by name");
            assert_eq!(
                blocked_by(&pre_tool_use(name, json!({}))),
                None,
                "{name}: the guard blocked it with an empty input"
            );
            assert_eq!(
                verdict(&pre_tool_use(name, follow_tool_input(registered))),
                GuardVerdict::Allow,
                "{name}: the guard blocked it with a benign input"
            );
        }
    }
}

#[test]
fn the_guard_treats_a_follow_requests_reason_as_data() {
    for reason in [
        "check aws ecs execute-command logs",
        "ecs_connect is blocked for me, so I am asking you",
        "aws ssm start-session --target i-123 is what I would have run",
        "session-manager-plugin",
    ] {
        for name in [REQUEST_FOLLOW, FOLLOW_TOOLS[1].1] {
            let payload = pre_tool_use(
                name,
                json!({ "terminal_id": "terminal-1a2b3c4d", "reason": reason }),
            );
            assert_eq!(verdict(&payload), GuardVerdict::Allow, "{name}: {reason:?}");
        }
    }
}

#[test]
fn a_command_smuggled_into_a_follow_tools_input_is_caught_by_the_guard_too() {
    // The MCP tools refuse any key beyond their own (`unknown_argument`); the
    // guard, which sees the call first, reads `command`, `cmd` and `script`
    // wherever they appear. Two independent layers.
    for (registered, seen) in FOLLOW_TOOLS {
        for key in ["command", "cmd", "script"] {
            let mut input = follow_tool_input(registered);
            input[key] = json!("aws ecs execute-command --cluster c --task t --command bash");
            assert_eq!(
                blocked_by(&pre_tool_use(seen, input)),
                Some(RULE_COMMAND),
                "{seen} with `{key}`"
            );
        }
    }
}

#[test]
fn no_follow_tool_has_a_field_a_command_could_go_in() {
    let tools = tool_descriptors();
    for (registered, _) in FOLLOW_TOOLS {
        let tool = tools
            .iter()
            .find(|t| t["name"] == registered)
            .unwrap_or_else(|| panic!("{registered} is not registered"));
        let schema = &tool["inputSchema"];
        assert_eq!(
            schema["additionalProperties"],
            json!(false),
            "{registered}: the schema must refuse extra keys"
        );
        let properties = schema["properties"].as_object().expect("properties");
        for forbidden in [
            "command", "cmd", "script", "args", "argv", "input", "keys", "text", "env", "data",
            "view_id",
        ] {
            assert!(
                !properties.contains_key(forbidden),
                "{registered} offers a `{forbidden}` field"
            );
        }
    }
}

#[test]
fn no_follow_tool_looks_like_a_way_to_write_read_or_close_a_terminal() {
    for (registered, _) in FOLLOW_TOOLS {
        assert_eq!(
            classify_terminal_attempt(registered),
            None,
            "{registered} is classified as a terminal input/read/close attempt"
        );
    }
}

#[test]
fn no_registered_tool_is_classified_as_a_terminal_attempt() {
    let tools = tool_descriptors();
    assert!(!tools.is_empty());
    for tool in &tools {
        let name = tool["name"].as_str().expect("tool name");
        assert_eq!(classify_terminal_attempt(name), None, "{name}");
    }
    for (registered, _) in FOLLOW_TOOLS {
        assert!(
            tools.iter().any(|t| t["name"] == registered),
            "{registered} must be registered"
        );
    }
}

#[test]
fn together_the_two_layers_still_leave_only_the_sanctioned_paths_open() {
    let open: Vec<&str> = [
        (
            "Bash",
            json!({"command": "aws ecs execute-command --cluster c --task t --command bash"}),
        ),
        ("mcp__nostromo__ecs_shell", json!({})),
        (REQUEST_AS_SEEN_BY_THE_AGENT, valid_request_input()),
        (FOLLOW_TOOLS[0].1, json!({})),
        (FOLLOW_TOOLS[1].1, follow_tool_input(REQUEST_FOLLOW)),
        (FOLLOW_TOOLS[2].1, follow_tool_input(READ_SCREEN)),
    ]
    .iter()
    .filter(|(tool, input)| blocked_by(&pre_tool_use(tool, input.clone())).is_none())
    .map(|(tool, _)| *tool)
    .collect();

    assert_eq!(
        open,
        vec![
            REQUEST_AS_SEEN_BY_THE_AGENT,
            FOLLOW_TOOLS[0].1,
            FOLLOW_TOOLS[1].1,
            FOLLOW_TOOLS[2].1
        ]
    );
}
