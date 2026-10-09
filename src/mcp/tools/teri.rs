//! Teri-scoped MCP tool handlers.
//!
//! ## Tools
//! - `teri.list_todos()` — active todos from `teri_todos_rx`

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// Source states shared by the Teri and Fred tools.
pub(crate) mod source_state {
    pub const LOADING: &str = "loading";
    pub const UNAUTHENTICATED: &str = "unauthenticated";
    pub const ERROR: &str = "error";
    pub const STALE: &str = "stale";
    pub const EMPTY: &str = "empty";
    pub const FRESH: &str = "fresh";

    /// Derive the state of a loaded snapshot. A failure is never reported as
    /// `empty`/`fresh`: `error` set without `stale` is `error`, with `stale`
    /// is `stale` (the error is the reason).
    pub fn derive(stale: bool, error: Option<&str>, empty: bool) -> &'static str {
        if stale {
            STALE
        } else if error.is_some() {
            ERROR
        } else if empty {
            EMPTY
        } else {
            FRESH
        }
    }
}

/// Handle `teri.list_todos()`.
///
/// Returns the `TeriTodosSnapshot` fields plus `state`
/// (`loading|error|stale|empty|fresh`), `updated_at` and, when the snapshot
/// carries one, `reason`.
pub fn list_todos(state: &McpSharedState) -> Value {
    let borrow = state.teri_todos_rx.borrow();
    let Some(snap) = borrow.as_ref() else {
        return json!({
            "state": source_state::LOADING,
            "updated_at": null,
            "generated_at": null,
            "items": [],
            "stale": false,
            "error": null,
        });
    };
    let mut out = serde_json::to_value(snap).unwrap_or_else(
        |e| json!({ "error": "serialization_failed", "detail": e.to_string() }),
    );
    if let Some(obj) = out.as_object_mut() {
        obj.insert(
            "state".into(),
            json!(source_state::derive(snap.stale, snap.error.as_deref(), snap.items.is_empty())),
        );
        obj.insert("updated_at".into(), json!(snap.generated_at));
        if let Some(reason) = &snap.error {
            obj.insert("reason".into(), json!(reason));
        }
    }
    out
}
