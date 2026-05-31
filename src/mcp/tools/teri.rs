//! Teri-scoped MCP tool handlers.
//!
//! ## Tools
//! - `teri.list_todos()` — active todos from `teri_todos_rx`

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Handle `teri.list_todos()`.
///
/// Returns the `TeriTodosSnapshot` as JSON.  Fields match the snapshot type.
pub fn list_todos(state: &McpSharedState) -> Value {
    let borrow = state.teri_todos_rx.borrow();
    match borrow.as_ref() {
        Some(snap) => serde_json::to_value(snap).unwrap_or_else(
            |e| json!({ "error": "serialization_failed", "detail": e.to_string() }),
        ),
        None => json!({ "generated_at": null, "items": [], "stale": false, "error": null }),
    }
}
