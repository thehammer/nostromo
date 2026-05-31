//! MCP tool handler for `nostromo.switch_active_view`.

use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::event::AppEvent;
use crate::mcp::{command::McpCommand, state::McpSharedState};

const COMMAND_TIMEOUT_SECS: u64 = 5;

/// Handle `nostromo.switch_active_view({ view_id })`.
pub async fn switch_active_view(state: &McpSharedState, args: &Value) -> Value {
    let view_id = match args.get("view_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing view_id" }),
    };

    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SwitchActiveView { view_id, reply: tx };
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
