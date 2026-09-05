//! `nostromo.get_view_state` tool handler.
//!
//! Returns the full snapshot for a named view, dispatching to the per-view
//! getter modules.  Returns `{"error":"unknown_view"}` for unrecognised ids.

use serde_json::{json, Value};

use crate::mcp::{
    state::McpSharedState,
    tools::{fred, mother, perri, teri},
};

/// Input for `nostromo.get_view_state`.
#[derive(serde::Deserialize)]
pub struct GetViewStateInput {
    pub view_id: String,
}

/// Handle `nostromo.get_view_state({ view_id })`.
///
/// `view_id` here names a *view kind* (`"perri"`, `"fred"`, ...), which is not
/// the same thing as the focus tag the daemon's addressing rule resolves —
/// several focuses can be running the `perri` view. So `pty_id` is threaded in
/// separately and is what Perri's state resolves its PR under review against
/// (W7 — D3); a caller Nostromo can't place gets `current_pr: null` rather
/// than whichever focus happened to pick up a PR most recently.
pub async fn handle(
    state: &McpSharedState,
    input: &GetViewStateInput,
    pty_id: Option<&str>,
) -> Value {
    match input.view_id.as_str() {
        "perri" => perri::get_state(state, pty_id.filter(|s| !s.is_empty())),
        "fred" => fred::get_state(state),
        "mother" => mother::get_status(state),
        "teri" => teri::list_todos(state),
        "claudia" | "cody" | "kennedy" => json!({}),
        other => json!({ "error": "unknown_view", "view_id": other }),
    }
}
