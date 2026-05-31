//! Perri-scoped MCP tool handlers.
//!
//! ## Tools
//! - `perri.list_pr_queue()` — items from `perri_queue_rx`
//! - `perri.get_current_pr()` — snapshot from `perri_pr_rx`
//! - `perri.get_state()` — composite `{ queue, current_pr, stale }`
//!
//! Note: `selected_index` is omitted in Phase 2 (view selection state is not
//! yet wired into `McpSharedState`; it will be added in Phase 3 alongside
//! other view-mutation surfaces).

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Handle `perri.list_pr_queue()`.
///
/// Returns the items array from the live `PrQueueSnapshot`, or `[]` when no
/// snapshot is available yet.  Fields match `PrQueueItem` field-for-field.
pub fn list_pr_queue(state: &McpSharedState) -> Value {
    state
        .perri_queue_rx
        .borrow()
        .as_ref()
        .map(|s| serde_json::to_value(&s.items).unwrap_or(Value::Array(vec![])))
        .unwrap_or(Value::Array(vec![]))
}

/// Handle `perri.get_current_pr()`.
///
/// Returns the current `PrSnapshot` as JSON, or `null` when no PR is loaded.
pub fn get_current_pr(state: &McpSharedState) -> Value {
    let borrow = state.perri_pr_rx.borrow();
    match borrow.as_ref() {
        Some(snap) => serde_json::to_value(snap).unwrap_or_else(
            |e| json!({ "error": "serialization_failed", "detail": e.to_string() }),
        ),
        None => Value::Null,
    }
}

/// Handle `perri.get_state()`.
///
/// Returns `{ queue: [...], current_pr: {...}|null, stale: bool }`.
///
/// Note: `selected_index` is intentionally omitted in Phase 2.
pub fn get_state(state: &McpSharedState) -> Value {
    let queue = list_pr_queue(state);
    let current_pr = get_current_pr(state);
    let stale = state
        .perri_queue_rx
        .borrow()
        .as_ref()
        .map(|s| s.stale)
        .unwrap_or(false);
    json!({
        "queue": queue,
        "current_pr": current_pr,
        "stale": stale,
        // selected_index omitted until Phase 3 (view-state plumbing)
    })
}
