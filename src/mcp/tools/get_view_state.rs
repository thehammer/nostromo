//! `nostromo.get_view_state` tool handler.
//!
//! Returns the full snapshot for a named view, dispatching to the per-view
//! getter modules.  Returns `{"error":"unknown_view"}` for unrecognised ids.

use serde_json::{json, Value};

use crate::mcp::{
    state::McpSharedState,
    tools::{fred, mother, perri, render_state, teri},
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
///
/// Every response gets a `render_state` section merged in (W1 —
/// render-state-visibility, D7): reusing this already-reached-for tool is
/// what makes the expected-vs-rendered comparison discoverable without an
/// agent having to know a second tool name exists. `render_state::compute`
/// is keyed on `view_id` alone, so this holds even for the `unknown_view` /
/// `{}` branches below — a view this handler doesn't recognise can still
/// have panes and a render report against it.
pub async fn handle(
    state: &McpSharedState,
    input: &GetViewStateInput,
    pty_id: Option<&str>,
) -> Value {
    let mut result = match input.view_id.as_str() {
        "perri" => perri::get_state(state, pty_id.filter(|s| !s.is_empty())),
        "fred" => fred::get_state(state),
        "mother" => mother::get_status(state),
        "teri" => teri::list_todos(state),
        "claudia" | "cody" | "kennedy" => json!({}),
        other => json!({ "error": "unknown_view", "view_id": other }),
    };
    if let Value::Object(ref mut map) = result {
        map.insert("render_state".to_string(), render_state::compute(state, &input.view_id));
    }
    result
}
