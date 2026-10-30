//! `nostromo.terminal_staging` as an agent sees it: the listed schema, the
//! closed set of keys per op, argument and caller validation (before anything
//! else is looked at), and the instructions line.
//!
//! The behaviour behind it (who may call, every error in its order, lifecycle,
//! frames, the zero-bytes proofs) is pinned against real terminals in
//! `src/terminal/staging/tests.rs`; the surface classification is
//! `tests/no_shell_surface.rs`.

use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::SessionManager;
use nostromo::mcp::instructions::{nostromo_instructions, MAX_INSTRUCTIONS_CHARS};
use nostromo::mcp::tools::{dispatch, tool_descriptors, ToolResult};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const TOOL: &str = "nostromo.terminal_staging";
const TAG: &str = "cody-a";

fn state(dir: &TempDir) -> McpSharedState {
    let panes = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    panes.lock().unwrap().get_or_init(TAG);
    let (broadcast_tx, _rx) = broadcast::channel(16);
    McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: panes,
        session_mgr: Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        ))),
        broadcast_tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(Default::default())),
        tickets: Default::default(),
        tracker: Default::default(),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    })
}

async fn call(state: &McpSharedState, tag: Option<&str>, args: Value) -> Value {
    match dispatch(TOOL, Some(&args), state, tag).await {
        ToolResult::Ok(content) => {
            let text = content[0]["text"].as_str().expect("a text block");
            serde_json::from_str(text).expect("the block is JSON")
        }
        other => panic!("the tool did not answer with content: {}", variant(&other)),
    }
}

fn variant(result: &ToolResult) -> &'static str {
    match result {
        ToolResult::Ok(_) => "Ok",
        ToolResult::UnknownTool(_) => "UnknownTool",
        ToolResult::Forbidden(_) => "Forbidden",
        ToolResult::TerminalForbidden { .. } => "TerminalForbidden",
    }
}

fn descriptor() -> Value {
    tool_descriptors()
        .into_iter()
        .find(|d| d["name"] == TOOL)
        .expect("the staging tool is listed")
}

#[test]
fn the_listed_schema_is_closed_and_has_exactly_the_documented_properties() {
    let tool = descriptor();
    let schema = &tool["inputSchema"];
    assert_eq!(schema["additionalProperties"], json!(false));
    assert_eq!(schema["required"], json!(["op", "terminal_id"]));
    let mut props: Vec<&str> = schema["properties"]
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    props.sort_unstable();
    assert_eq!(
        props,
        [
            "command",
            "entry_id",
            "note",
            "op",
            "position",
            "terminal_id"
        ]
    );
    assert_eq!(
        schema["properties"]["op"]["enum"],
        json!(["list", "stage", "replace", "remove", "clear"])
    );
    assert_eq!(schema["properties"]["command"]["maxLength"], 1000);
    assert_eq!(schema["properties"]["note"]["maxLength"], 120);
    assert_eq!(schema["properties"]["position"]["type"], "integer");
    assert_eq!(schema["properties"]["position"]["minimum"], 1);
    assert_eq!(schema["properties"]["position"]["maximum"], 12);
    for name in ["op", "terminal_id", "command", "note", "entry_id"] {
        assert_eq!(schema["properties"][name]["type"], "string", "{name}");
    }
    let description = tool["description"].as_str().unwrap();
    assert!(
        description.starts_with(
            "Edits a display list only. Nothing here types, pastes or runs; the user clicks an entry to place it at the prompt and presses Enter themselves."
        ),
        "{description}"
    );
    // Every error the agent can meet is named.
    for code in [
        "invalid_args",
        "unknown_argument",
        "unknown_view",
        "not_following",
        "terminal_not_running",
        "no_operator",
        "staging_disabled",
        "rate_limited",
        "invalid_text",
        "entry_too_long",
        "note_too_long",
        "looks_like_secret",
        "remote_shell_command",
        "invalid_position",
        "unknown_entry",
        "list_full",
    ] {
        assert!(description.contains(code), "the description misses {code}");
    }
}

#[tokio::test]
async fn a_key_not_allowed_for_the_op_is_unknown_argument_for_every_op() {
    let dir = TempDir::new().unwrap();
    let state = state(&dir);
    let all = ["command", "note", "position", "entry_id"];
    let allowed = |op: &str| -> &[&str] {
        match op {
            "stage" => &["command", "note", "position"],
            "replace" => &["entry_id", "command", "note"],
            "remove" => &["entry_id"],
            _ => &[],
        }
    };
    for op in ["list", "stage", "replace", "remove", "clear"] {
        for key in all.iter().filter(|k| !allowed(op).contains(k)) {
            let mut args = json!({ "op": op, "terminal_id": "t" });
            args[*key] = json!("x");
            // Valid values for the allowed keys, so only the stranger is wrong.
            for ok in allowed(op) {
                args[*ok] = match *ok {
                    "position" => json!(1),
                    _ => json!("x"),
                };
            }
            let out = call(&state, Some(TAG), args).await;
            assert_eq!(
                out,
                json!({ "error": "unknown_argument", "detail": key }),
                "{op} with {key}"
            );
        }
        // And a key that no op has.
        let out = call(
            &state,
            Some(TAG),
            json!({ "op": op, "terminal_id": "t", "keys": "ls\n" }),
        )
        .await;
        assert_eq!(
            out,
            json!({ "error": "unknown_argument", "detail": "keys" })
        );
    }
}

#[tokio::test]
async fn a_missing_required_key_or_a_wrong_type_is_invalid_args_naming_it() {
    let dir = TempDir::new().unwrap();
    let state = state(&dir);
    for (args, needle) in [
        (json!({}), "op"),
        (json!({ "op": "list" }), "terminal_id"),
        (json!({ "op": "list", "terminal_id": "" }), "terminal_id"),
        (json!({ "op": "list", "terminal_id": 7 }), "terminal_id"),
        (json!({ "op": "paste", "terminal_id": "t" }), "op"),
        (json!({ "op": "insert", "terminal_id": "t" }), "op"),
        (json!({ "op": 3, "terminal_id": "t" }), "op"),
        (json!({ "op": "stage", "terminal_id": "t" }), "command"),
        (
            json!({ "op": "stage", "terminal_id": "t", "command": 5 }),
            "command",
        ),
        (
            json!({ "op": "stage", "terminal_id": "t", "command": "ls", "note": 5 }),
            "note",
        ),
        (
            json!({ "op": "stage", "terminal_id": "t", "command": "ls", "position": "1" }),
            "position",
        ),
        (
            json!({ "op": "stage", "terminal_id": "t", "command": "ls", "position": 1.5 }),
            "position",
        ),
        (
            json!({ "op": "replace", "terminal_id": "t", "command": "ls" }),
            "entry_id",
        ),
        (
            json!({ "op": "replace", "terminal_id": "t", "entry_id": "s-1" }),
            "command",
        ),
        (json!({ "op": "remove", "terminal_id": "t" }), "entry_id"),
    ] {
        let out = call(&state, Some(TAG), args.clone()).await;
        assert_eq!(out["error"], "invalid_args", "{args}");
        assert!(
            out["detail"].as_str().unwrap().contains(needle),
            "{args}: {out}"
        );
    }
    // Arguments that are not an object at all.
    match dispatch(TOOL, Some(&json!("ls")), &state, Some(TAG)).await {
        ToolResult::Ok(content) => {
            assert!(content[0]["text"]
                .as_str()
                .unwrap()
                .contains("invalid_args"));
        }
        other => panic!("{}", variant(&other)),
    }
}

#[tokio::test]
async fn arguments_are_checked_before_the_caller_and_the_caller_before_the_terminal() {
    let dir = TempDir::new().unwrap();
    let state = state(&dir);
    // An unknown key is refused whoever asks.
    let out = call(
        &state,
        None,
        json!({ "op": "list", "terminal_id": "t", "command": "ls" }),
    )
    .await;
    assert_eq!(out["error"], "unknown_argument");
    // No identity, or a focus the daemon does not know.
    for tag in [None, Some(""), Some("no-such-focus")] {
        let out = call(&state, tag, json!({ "op": "list", "terminal_id": "t" })).await;
        assert_eq!(out, json!({ "error": "unknown_view" }), "{tag:?}");
    }
    // A known focus asking about a terminal it does not follow, or that does
    // not exist, is told the same thing.
    for op in [
        json!({ "op": "list", "terminal_id": "no-such-terminal" }),
        json!({ "op": "stage", "terminal_id": "no-such-terminal", "command": "ls" }),
        json!({ "op": "clear", "terminal_id": "no-such-terminal" }),
        json!({ "op": "remove", "terminal_id": "no-such-terminal", "entry_id": "s-00000001" }),
    ] {
        let out = call(&state, Some(TAG), op).await;
        assert_eq!(out["error"], "not_following", "{out}");
        assert!(out.get("ok").is_none());
    }
}

#[tokio::test]
async fn the_tool_is_listed_for_an_agent() {
    let dir = TempDir::new().unwrap();
    let state = state(&dir);
    let listed = nostromo::mcp::tools::tool_descriptors_for(&state, Some(TAG)).await;
    assert!(listed.iter().any(|d| d["name"] == TOOL));
}

#[test]
fn the_instructions_carry_the_staging_line_within_their_limits() {
    let text = nostromo_instructions(Some("topic"));
    assert!(
        text.contains(
            "- nostromo.terminal_staging: for a terminal you follow, stage up to 12 single-line commands the user can click to place at its prompt. Only the user presses Enter. One command per entry, plainly; no secrets; never disguise what a command does. A notice says when an entry was inserted, not that it ran."
        ),
        "{text}"
    );
    assert!(text.lines().count() <= 25, "{} lines", text.lines().count());
    assert!(text.chars().count() <= MAX_INSTRUCTIONS_CHARS);
}

#[test]
fn the_docs_document_the_tool_and_every_error() {
    let tools =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/docs/mcp/tools.md")).unwrap();
    let section = tools
        .split("nostromo.terminal_staging")
        .nth(1)
        .expect("docs/mcp/tools.md documents the staging tool");
    for code in [
        "invalid_args",
        "unknown_argument",
        "unknown_view",
        "not_following",
        "terminal_not_running",
        "no_operator",
        "staging_disabled",
        "rate_limited",
        "invalid_text",
        "entry_too_long",
        "note_too_long",
        "looks_like_secret",
        "remote_shell_command",
        "invalid_position",
        "unknown_entry",
        "list_full",
    ] {
        assert!(section.contains(code), "docs/mcp/tools.md misses {code}");
    }
    let terminal_doc =
        std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/docs/terminal.md")).unwrap();
    assert!(terminal_doc.contains("Command staging (S1)"));
}
