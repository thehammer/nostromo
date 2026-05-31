//! MCP tool handlers for Perri-specific mutations.
//!
//! ## Tools
//! - `perri.load_pr({ number, repo, highlights? })`
//! - `perri.clear_current_pr()`
//! - `perri.set_selected_index({ index })`

use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::event::AppEvent;
use crate::mcp::{command::McpCommand, state::McpSharedState};

const COMMAND_TIMEOUT_SECS: u64 = 5;

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `perri.load_pr({ number, repo, highlights? })`.
pub async fn load_pr(state: &McpSharedState, args: &Value) -> Value {
    let number = match args.get("number").and_then(|v| v.as_u64()) {
        Some(n) => n,
        None => return json!({ "error": "invalid_args", "detail": "missing or invalid number" }),
    };
    let repo = match args.get("repo").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing repo" }),
    };
    let highlights = args
        .get("highlights")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriLoadPr {
        number,
        repo,
        highlights,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.clear_current_pr()`.
pub async fn clear_current_pr(state: &McpSharedState) -> Value {
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriClearCurrentPr { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.set_selected_index({ index })`.
pub async fn set_selected_index(state: &McpSharedState, args: &Value) -> Value {
    let index = match args.get("index").and_then(|v| v.as_u64()) {
        Some(n) => n as usize,
        None => return json!({ "error": "invalid_args", "detail": "missing or invalid index" }),
    };
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPerriSelectedIndex { index, reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.get_selected_index()`.
pub async fn get_selected_index(state: &McpSharedState) -> Value {
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::GetPerriSelectedIndex { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(idx))) => json!({ "index": idx }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}
