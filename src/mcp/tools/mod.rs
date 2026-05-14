//! MCP tool registry.
//!
//! Phase 1 registers exactly one tool: `nostromo.get_self`.
//! Subsequent phases will add tools here.

pub mod get_self;

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

// ── tool descriptor ─────────────────────────────────────────────────────────

/// JSON Schema descriptor for a tool, as required by the MCP `tools/list`
/// response.
pub fn tool_descriptors() -> Vec<Value> {
    vec![json!({
        "name": "nostromo.get_self",
        "description": "Returns identity information about the calling Nostromo PTY session: which view and pane set the agent is running inside.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    })]
}

// ── tool dispatch ────────────────────────────────────────────────────────────

/// Dispatch a `tools/call` request.
///
/// Returns the MCP `content` array on success, or a tool-level error value
/// that will be wrapped in `{"error": true, "content": [...]}`.
pub async fn dispatch(
    name: &str,
    _arguments: Option<&Value>,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> ToolResult {
    match name {
        "nostromo.get_self" => {
            let result = get_self::handle(state, pty_id).await;
            ToolResult::Ok(vec![json!({"type": "text", "text": result.to_string()})])
        }
        other => ToolResult::UnknownTool(other.to_string()),
    }
}

/// Result of a tool dispatch.
pub enum ToolResult {
    /// Successful tool call; content array to embed in the MCP response.
    Ok(Vec<Value>),
    /// Tool name not recognised.
    UnknownTool(String),
}
