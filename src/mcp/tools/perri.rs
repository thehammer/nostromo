//! Perri-scoped MCP tool handlers.
//!
//! ## Tools
//! - `perri.list_pr_queue()` — items from `perri_queue_rx`
//! - `perri.get_current_pr({ view_id? })` — the *calling focus's* PR snapshot
//! - `perri.get_state({ view_id? })` — composite
//!   `{ queue, current_pr, other_focuses, stale }`
//!
//! `list_pr_queue` takes no focus: the queue is fleet-wide and every focus
//! sees the same one (W7 — D9). Only "the PR under review" is per-focus.
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

/// Handle `perri.get_current_pr({ view_id? })`.
///
/// Returns the calling focus's `PrSnapshot` as JSON, or `null` when that
/// focus has no PR under review (W7 — D3). Never another focus's: before W7
/// there was one machine-wide answer, and a focus that had picked up nothing
/// still got whatever some other focus was reviewing.
pub fn get_current_pr(state: &McpSharedState, tag: Option<&str>) -> Value {
    match state.pr_for(tag) {
        Some(snap) => serde_json::to_value(&*snap).unwrap_or_else(
            |e| json!({ "error": "serialization_failed", "detail": e.to_string() }),
        ),
        None => Value::Null,
    }
}

/// Handle `perri.get_state({ view_id? })`.
///
/// Returns `{ queue: [...], current_pr: {...}|null, other_focuses: [...],
/// stale: bool }`.
///
/// - `current_pr` is **this focus's** PR under review.
/// - `other_focuses` is every *other* focus that has one, as
///   `{ tag, repo, number }`. Isolation would otherwise lose the one thing the
///   old global slot did well: always knowing what the machine as a whole was
///   reviewing. Sorted by tag so the answer is stable between calls.
/// - `queue` stays fleet-wide and identical for every focus (D9). One set of
///   open PRs exists; splitting it per focus would be a different product.
///
/// Both `current_pr` and `other_focuses` are **always present**, explicitly
/// empty (`null` / `[]`) rather than absent — an absent key reads as "this
/// daemon doesn't support it", which is a different and wrong answer.
///
/// `selected_index` is deliberately not included here: this handler is
/// synchronous, and on the TUI host reading the selected index means an
/// async round trip through `PerriView` — adding the key here would make the
/// response shape differ by host, which is worse for callers than not having
/// it. Use `perri.get_selected_index` instead.
pub fn get_state(state: &McpSharedState, tag: Option<&str>) -> Value {
    let queue = list_pr_queue(state);
    let current_pr = get_current_pr(state, tag);
    let other_focuses: Vec<Value> = state
        .all_prs()
        .into_iter()
        .filter(|(other, _)| Some(other.as_str()) != tag)
        .filter_map(|(other, snap)| {
            // A snapshot mid-fetch can carry a repo with no number yet, and
            // half a PR identity is not one to report to another focus.
            let number = snap.pr_number?;
            Some(json!({ "tag": other, "repo": snap.repo, "number": number }))
        })
        .collect();
    let stale = state
        .perri_queue_rx
        .borrow()
        .as_ref()
        .map(|s| s.stale)
        .unwrap_or(false);
    json!({
        "queue": queue,
        "current_pr": current_pr,
        "other_focuses": other_focuses,
        "stale": stale,
        // selected_index omitted until Phase 3 (view-state plumbing)
    })
}
