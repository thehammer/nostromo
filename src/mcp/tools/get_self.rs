//! `nostromo.get_self` tool handler.
//!
//! Returns identity information about the Nostromo PTY session that is calling
//! the tool.  The caller is identified via the `pty_id` extracted from the
//! per-connection `Hello` frame (see `src/mcp/server.rs`).

use serde_json::{json, Value};

use crate::mcp::state::McpSharedState;

/// JSON response for a successfully identified caller.
///
/// ```json
/// {
///   "view_id": "perri",
///   "view_title": "Perri",
///   "pty_id": "<uuid>",
///   "session_id": "<uuid>",
///   "pane_ids": ["pr_queue", "diff", "repl"],
///   "nostromo_version": "0.1.0"
/// }
/// ```
pub async fn handle(state: &McpSharedState, pty_id: Option<&str>) -> Value {
    let Some(pty_id) = pty_id else {
        return json!({ "error": "unidentified_caller", "reason": "no pty_id in Hello frame" });
    };

    let ptys = state.ptys.read().await;
    let Some(identity) = ptys.get(pty_id) else {
        return json!({
            "error": "unidentified_caller",
            "reason": "pty_id not found in registry"
        });
    };

    let view_id = identity.view_id;
    let session_id = identity.session_id.clone();
    drop(ptys);

    // Look up the matching ViewMeta.
    let views = state.views_meta.read().await;
    let (view_title, pane_ids): (String, Vec<&'static str>) = views
        .iter()
        .find(|v| v.id == view_id)
        .map(|v| (v.title.clone(), v.pane_ids.clone()))
        .unwrap_or_else(|| (view_id.to_string(), vec![]));
    drop(views);

    json!({
        "view_id": view_id,
        "view_title": view_title,
        "pty_id": pty_id,
        "session_id": session_id,
        "pane_ids": pane_ids,
        "nostromo_version": env!("CARGO_PKG_VERSION"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mcp::state::{PtyIdentity, ViewMeta};
    use tokio::sync::mpsc;

    async fn make_state() -> McpSharedState {
        let (tx, _rx) = mpsc::unbounded_channel();
        let state = McpSharedState::for_test(tx);

        // Register one view.
        state.views_meta.write().await.push(ViewMeta {
            id: "perri",
            title: "Perri".to_string(),
            pane_ids: vec!["pr_queue", "diff", "repl"],
        });

        // Register one PTY.
        state
            .register_pty(
                "test-pty-id".to_string(),
                PtyIdentity {
                    view_id: "perri",
                    session_id: "test-session-id".to_string(),
                    spawned_at: std::time::SystemTime::now(),
                },
            )
            .await;

        state
    }

    #[tokio::test]
    async fn returns_self_info_for_known_pty() {
        let state = make_state().await;
        let result = handle(&state, Some("test-pty-id")).await;

        assert_eq!(result["view_id"], "perri");
        assert_eq!(result["view_title"], "Perri");
        assert_eq!(result["pty_id"], "test-pty-id");
        assert_eq!(result["session_id"], "test-session-id");
        assert!(result["pane_ids"].is_array());
        let pane_ids: Vec<&str> = result["pane_ids"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert_eq!(pane_ids, vec!["pr_queue", "diff", "repl"]);
    }

    #[tokio::test]
    async fn returns_error_for_unknown_pty() {
        let state = make_state().await;
        let result = handle(&state, Some("unknown-pty-id")).await;
        assert_eq!(result["error"], "unidentified_caller");
    }

    #[tokio::test]
    async fn returns_error_when_no_pty_id() {
        let state = make_state().await;
        let result = handle(&state, None).await;
        assert_eq!(result["error"], "unidentified_caller");
    }
}
