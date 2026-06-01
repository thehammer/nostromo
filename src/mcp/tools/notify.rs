//! MCP tool handler: `nostromo.notify`.
//!
//! Posts a transient toast to the status bar.  The toast auto-expires after 5 s.
//!
//! Input schema:
//! ```json
//! {
//!   "message": "string (required)",
//!   "level":   "info | warn | error (optional, default info)",
//!   "view_id": "string (optional, for attribution only)"
//! }
//! ```

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::{
    event::AppEvent,
    mcp::{
        command::{McpCommand, McpReply, NotifyLevel},
        state::McpSharedState,
    },
};

// ── input ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct NotifyInput {
    pub message: String,
    #[serde(default)]
    pub level: NotifyLevel,
    pub view_id: Option<String>,
}

// ── handler ───────────────────────────────────────────────────────────────────

pub async fn handle(state: &McpSharedState, args: &Value) -> Value {
    let input: NotifyInput = match serde_json::from_value(args.clone()) {
        Ok(v) => v,
        Err(e) => return json!({ "error": "invalid_args", "detail": e.to_string() }),
    };

    let (reply_tx, reply_rx) = oneshot::channel::<McpReply<()>>();

    let cmd = McpCommand::Notify {
        message: input.message,
        level: input.level,
        source_view: input.view_id,
        reply: reply_tx,
    };

    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_gone" });
    }

    match tokio::time::timeout(std::time::Duration::from_secs(5), reply_rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "reply_channel_dropped" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}
