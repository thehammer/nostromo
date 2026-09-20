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
/// Returns `{ queue: [...], current_pr: {...}|null, stale: bool, current_pin:
/// {repo, number}|null }`.
///
/// `selected_index` is deliberately not included here: this handler is
/// synchronous, and on the TUI host reading the selected index means an
/// async round trip through `PerriView` — adding the key here would make the
/// response shape differ by host, which is worse for callers than not having
/// it. Use `perri.get_selected_index` instead.
///
/// `current_pin` (W5 — current-pr-collision) is this same daemon-wide pin,
/// via the same [`crate::mcp::tools::apply_layout::pin_for_request`]
/// accessor `nostromo.show`'s error decoration uses — already what an agent
/// reaches for here, so it costs nothing to make the answer complete without
/// needing to know to ask separately. Always a present key, explicit `null`
/// rather than omitted, when nothing is pinned. `tag` is accepted but
/// unused today for the same forward-compatibility reason `pin_for_request`
/// itself ignores it (see its doc comment).
pub fn get_state(state: &McpSharedState, tag: Option<&str>) -> Value {
    let queue = list_pr_queue(state);
    let current_pr = get_current_pr(state);
    let stale = state
        .perri_queue_rx
        .borrow()
        .as_ref()
        .map(|s| s.stale)
        .unwrap_or(false);
    let current_pin =
        crate::mcp::tools::apply_layout::pin_for_request(state, tag).map(|p| p.wire());
    json!({
        "queue": queue,
        "current_pr": current_pr,
        "stale": stale,
        "current_pin": current_pin,
        // selected_index omitted until Phase 3 (view-state plumbing)
    })
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// W5 (current-pr-collision): `get_state` grows a `tag` parameter (unused by
// today's implementation — plumbing for a later per-focus-isolation change)
// and a `current_pin` key, present-and-explicit-null when nothing is pinned
// so a caller can tell "checked, nothing pinned" from "this daemon predates
// the field" (a future regression to omitting the key entirely is caught by
// asserting `.get("current_pin").is_some()` in addition to the value).

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::watch;

    /// A minimal `McpSharedState` for `perri.rs`'s handlers — these only ever
    /// read `perri_pr_rx`/`perri_queue_rx`, so `McpSharedState::for_test`
    /// (no daemon backend, no pane registry) is enough; no need for the
    /// heavier `make_state()` other tool modules build for the full
    /// pane-registry machinery.
    fn state_with_pr(snap: Option<crate::data::perri_pr::PrSnapshot>) -> McpSharedState {
        let (event_tx, _dropped_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut state = McpSharedState::for_test(event_tx);
        let (_tx, rx) = watch::channel(snap);
        state.perri_pr_rx = rx;
        state
    }

    fn full_pr_snapshot() -> crate::data::perri_pr::PrSnapshot {
        serde_json::from_value(json!({
            "pr_number": 42, "repo": "acme/web", "title": "Add widget",
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": null, "head_sha": "abc123"
        }))
        .unwrap()
    }

    #[test]
    fn get_state_current_pin_reflects_a_fully_loaded_pr() {
        let state = state_with_pr(Some(full_pr_snapshot()));
        let out = get_state(&state, Some("perri"));
        assert_eq!(out["current_pin"], json!({ "repo": "acme/web", "number": 42 }));
    }

    #[test]
    fn get_state_current_pin_is_explicit_null_with_no_snapshot_at_all() {
        let state = state_with_pr(None);
        let out = get_state(&state, Some("perri"));
        assert!(
            out.get("current_pin").is_some(),
            "current_pin must be a present key, not omitted, when nothing is pinned"
        );
        assert_eq!(out["current_pin"], Value::Null);
    }

    #[test]
    fn get_state_current_pin_is_explicit_null_when_the_snapshot_describes_no_pr_under_review() {
        let snap: crate::data::perri_pr::PrSnapshot = serde_json::from_value(json!({
            "pr_number": null, "repo": "acme/web", "title": "",
            "author": "", "url": "", "diff": "",
            "stale": false, "error": null
        }))
        .unwrap();
        let state = state_with_pr(Some(snap));
        let out = get_state(&state, Some("perri"));
        assert!(out.get("current_pin").is_some());
        assert_eq!(out["current_pin"], Value::Null);
    }
}
