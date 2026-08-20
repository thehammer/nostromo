//! Integration tests for `nostromo.get_daemon_diagnostics` and the
//! dispatch-timing wrapper in `tools::dispatch`.
//!
//! Tests call through `tools::dispatch` (the public dispatch entry point,
//! same as the MCP server uses) rather than the tool handler directly, since
//! the behaviour under test — every successful dispatch gets timed exactly
//! once, unknown tools create no stats entry — lives in the wrapper, not in
//! `daemon_diagnostics::handle` itself.

use nostromo::mcp::{state::McpSharedState, tools};
use serde_json::Value;
use tokio::sync::mpsc;

/// Build a minimal `McpSharedState` for dispatch tests.
fn test_state() -> McpSharedState {
    let (tx, _rx) = mpsc::unbounded_channel();
    McpSharedState::for_test(tx)
}

/// Dispatch a tool call and return the decoded JSON body (unwraps the
/// `{"type":"text","text":"<json>"}` content wrapper `dispatch` produces).
async fn dispatch_json(name: &str, state: &McpSharedState) -> Value {
    match tools::dispatch(name, None, state, None).await {
        tools::ToolResult::Ok(content) => {
            let text = content[0]["text"].as_str().expect("text content");
            serde_json::from_str(text).expect("valid JSON body")
        }
        tools::ToolResult::UnknownTool(n) => panic!("unexpected UnknownTool({n})"),
        tools::ToolResult::Forbidden(n) => panic!("unexpected Forbidden({n})"),
    }
}

#[tokio::test]
async fn diagnostics_reports_calls_for_dispatched_tools() {
    let state = test_state();

    dispatch_json("nostromo.list_views", &state).await;
    dispatch_json("nostromo.list_views", &state).await;

    let diag = dispatch_json("nostromo.get_daemon_diagnostics", &state).await;
    let tools_arr = diag["tools"].as_array().expect("tools array");
    let row = tools_arr
        .iter()
        .find(|r| r["name"] == "nostromo.list_views")
        .expect("nostromo.list_views row present");
    assert_eq!(row["calls"], 2);
}

#[tokio::test]
async fn unknown_tool_creates_no_stats_entry() {
    let state = test_state();

    let result = tools::dispatch("completely.unknown.tool", None, &state, None).await;
    match result {
        tools::ToolResult::UnknownTool(name) => assert_eq!(name, "completely.unknown.tool"),
        tools::ToolResult::Ok(_) => panic!("expected UnknownTool"),
        tools::ToolResult::Forbidden(_) => panic!("expected UnknownTool, got Forbidden"),
    }

    let diag = dispatch_json("nostromo.get_daemon_diagnostics", &state).await;
    assert!(
        diag["tools"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| r["name"] != "completely.unknown.tool"),
        "unknown tool must not create a stats row"
    );
    // distinct_tools reflects only nostromo.get_daemon_diagnostics's own
    // (pre-recording) snapshot state — the unknown tool must not have bumped it.
    assert_eq!(diag["distinct_tools"], 0);
}

#[tokio::test]
async fn descriptor_is_registered_and_dispatchable() {
    let descriptors = tools::tool_descriptors();
    assert!(
        descriptors
            .iter()
            .any(|d| d["name"] == "nostromo.get_daemon_diagnostics"),
        "nostromo.get_daemon_diagnostics must be listed in tool_descriptors()"
    );

    let state = test_state();
    match tools::dispatch("nostromo.get_daemon_diagnostics", None, &state, None).await {
        tools::ToolResult::Ok(_) => {}
        tools::ToolResult::UnknownTool(_) | tools::ToolResult::Forbidden(_) => {
            panic!("nostromo.get_daemon_diagnostics must be dispatchable")
        }
    }
}

#[tokio::test]
async fn diagnostics_reports_uptime_and_sample_window() {
    let state = test_state();
    let diag = dispatch_json("nostromo.get_daemon_diagnostics", &state).await;

    assert!(diag["uptime_secs"].as_u64().is_some());
    assert_eq!(diag["sample_window"], 256);
}
