//! Perri-scoped MCP tool handlers.
//!
//! ## Tools
//! - `perri.list_pr_queue()` — items from `perri_queue_rx`
//! - `perri.get_current_pr()` — snapshot from `perri_pr_rx`
//! - `perri.get_state()` — composite `{ queue, current_pr, stale }`
//!
//! `selected_index` is intentionally not a field of `get_state()` — see the
//! doc comment on [`get_state`]. It's exposed through the dedicated
//! `perri.get_selected_index` / `perri.set_selected_index` tools in
//! [`super::perri_mutators`] instead.

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
/// `selected_index` is deliberately not included here: this handler is
/// synchronous, and on the TUI host reading the selected index means an
/// async round trip through `PerriView` — adding the key here would make the
/// response shape differ by host, which is worse for callers than not having
/// it. Use `perri.get_selected_index` instead.
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
