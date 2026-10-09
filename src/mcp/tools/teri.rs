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
    pub const NOT_CONFIGURED: &str = "not_configured";

    /// Derive the state of a loaded snapshot. A failure is never reported as
    /// `empty`/`fresh`: `error` set without `stale` is `error`, with `stale`
    /// is `stale` (the error is the reason). `not_configured` (the source has
    /// nothing set up — not a failure) outranks `empty`.
    pub fn derive(
        not_configured: bool,
        stale: bool,
        error: Option<&str>,
        empty: bool,
    ) -> &'static str {
        if not_configured {
            NOT_CONFIGURED
        } else if stale {
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

/// Why a user without a Teri database is told nothing is wrong. Deliberately
/// carries no filesystem path.
const NOT_CONFIGURED_REASON: &str = "Teri has no database yet";

/// `(state, active todo count)` read straight from the snapshot.
pub(crate) fn summary(state: &McpSharedState) -> (&'static str, usize) {
    match state.teri_todos_rx.borrow().as_ref() {
        None => (source_state::LOADING, 0),
        Some(snap) => (
            source_state::derive(
                snap.not_configured,
                snap.stale,
                snap.error.as_deref(),
                snap.items.is_empty(),
            ),
            snap.items.len(),
        ),
    }
}

/// Handle `teri.list_todos()`.
///
/// Returns the `TeriTodosSnapshot` fields plus `state`
/// (`loading|not_configured|error|stale|empty|fresh`), `updated_at` and, when
/// there is something to explain, `reason`.
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
            json!(source_state::derive(
                snap.not_configured,
                snap.stale,
                snap.error.as_deref(),
                snap.items.is_empty()
            )),
        );
        obj.insert("updated_at".into(), json!(snap.generated_at));
        if snap.not_configured {
            obj.insert("reason".into(), json!(NOT_CONFIGURED_REASON));
        } else if let Some(reason) = &snap.error {
            obj.insert("reason".into(), json!(reason));
        }
    }
    out
}

// NOTE (Redd): these tests target the NEW `source_state::derive` signature
// `derive(not_configured, stale, error, empty)` and the new
// `source_state::NOT_CONFIGURED` const. Until Cody adds them this block does
// not compile, which fails the whole lib test target: expected for the red
// phase.
#[cfg(test)]
mod tests {
    use super::source_state::{self, derive};

    #[test]
    fn not_configured_is_its_own_state() {
        assert_eq!(source_state::NOT_CONFIGURED, "not_configured");
        assert_eq!(derive(true, false, None, true), source_state::NOT_CONFIGURED);
    }

    #[test]
    fn not_configured_wins_over_empty_and_over_everything_else() {
        assert_eq!(derive(true, false, None, true), "not_configured");
        assert_eq!(derive(true, false, None, false), "not_configured");
        assert_eq!(derive(true, true, Some("x"), true), "not_configured");
    }

    #[test]
    fn without_not_configured_the_existing_precedence_is_unchanged() {
        // stale > error > empty > fresh
        assert_eq!(derive(false, true, Some("x"), true), "stale");
        assert_eq!(derive(false, true, None, false), "stale");
        assert_eq!(derive(false, false, Some("x"), true), "error");
        assert_eq!(derive(false, false, Some("x"), false), "error");
        assert_eq!(derive(false, false, None, true), "empty");
        assert_eq!(derive(false, false, None, false), "fresh");
    }
}
