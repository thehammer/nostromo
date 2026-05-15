//! MCP tool handlers for status-bar segment management.
//!
//! Two tools:
//! - `nostromo.register_status_segment` — add/update a per-view segment.
//! - `nostromo.clear_status_segment`    — remove a per-view segment.
//!
//! Segments are displayed in the status bar when their view is the active tab.
//!
//! Input schema (register):
//! ```json
//! {
//!   "view_id":    "string (required)",
//!   "segment_id": "string (required)",
//!   "text":       "string (required)",
//!   "color":      "string (optional) — named: red|amber|sage|blue|muted, or #rrggbb"
//! }
//! ```
//!
//! Input schema (clear):
//! ```json
//! {
//!   "view_id":    "string (required)",
//!   "segment_id": "string (required)"
//! }
//! ```

use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::{
    event::AppEvent,
    mcp::{
        command::{McpCommand, McpReply},
        state::McpSharedState,
    },
};

// ── inputs ────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
pub struct RegisterSegmentInput {
    pub view_id: String,
    pub segment_id: String,
    pub text: String,
    pub color: Option<String>,
}

#[derive(Deserialize)]
pub struct ClearSegmentInput {
    pub view_id: String,
    pub segment_id: String,
}

// ── handlers ──────────────────────────────────────────────────────────────────

pub async fn register(state: &McpSharedState, args: &Value) -> Value {
    let input: RegisterSegmentInput = match serde_json::from_value(args.clone()) {
        Ok(v) => v,
        Err(e) => return json!({ "error": "invalid_args", "detail": e.to_string() }),
    };

    let (reply_tx, reply_rx) = oneshot::channel::<McpReply<()>>();

    let cmd = McpCommand::RegisterStatusSegment {
        view_id: input.view_id,
        segment_id: input.segment_id,
        text: input.text,
        color: input.color,
        reply: reply_tx,
    };

    if state.event_tx.send(AppEvent::McpCommand(Box::new(cmd))).is_err() {
        return json!({ "error": "event_loop_gone" });
    }

    match tokio::time::timeout(std::time::Duration::from_secs(5), reply_rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "reply_channel_dropped" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

pub async fn clear(state: &McpSharedState, args: &Value) -> Value {
    let input: ClearSegmentInput = match serde_json::from_value(args.clone()) {
        Ok(v) => v,
        Err(e) => return json!({ "error": "invalid_args", "detail": e.to_string() }),
    };

    let (reply_tx, reply_rx) = oneshot::channel::<McpReply<()>>();

    let cmd = McpCommand::ClearStatusSegment {
        view_id: input.view_id,
        segment_id: input.segment_id,
        reply: reply_tx,
    };

    if state.event_tx.send(AppEvent::McpCommand(Box::new(cmd))).is_err() {
        return json!({ "error": "event_loop_gone" });
    }

    match tokio::time::timeout(std::time::Duration::from_secs(5), reply_rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "reply_channel_dropped" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}
