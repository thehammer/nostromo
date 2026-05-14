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
pub async fn handle(state: &McpSharedState, input: &GetViewStateInput) -> Value {
    match input.view_id.as_str() {
        "perri" => perri::get_state(state),
        "fred" => fred::get_state(state),
        "mother" => mother::get_status(state),
        "teri" => teri::list_todos(state),
        "claudia" | "cody" | "kennedy" => json!({}),
        other => json!({ "error": "unknown_view", "view_id": other }),
    }
}
