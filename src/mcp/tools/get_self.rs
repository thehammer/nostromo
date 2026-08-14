//! `nostromo.get_self` tool handler.
//!
//! Returns identity information about the Nostromo PTY session that is calling
//! the tool.  The caller is identified via the `pty_id` extracted from the
//! per-connection `Hello` frame (see `src/mcp/server.rs`).

use serde_json::{json, Value};

use crate::ipc::pane_registry::REPL_PANE_ID;
use crate::mcp::state::McpSharedState;

/// JSON response for a successfully identified caller.
///
/// Daemon-hosted path:
/// ```json
/// {
///   "view_id": "perri",
///   "view_title": "Perri",
///   "agent_name": "perri",
///   "pty_id": "perri",
///   "session_id": "perri",
///   "pane_ids": ["queue", "diff", "repl"],
///   "layout_applied": true,
///   "nostromo_version": "0.1.0"
/// }
/// ```
/// Before any layout has been assembled for the tag, `pane_ids` collapses to
/// `["repl"]` and `layout_applied` is `false` — that combination signals "no
/// layout yet", not "the pane/tool is unavailable".
pub async fn handle(state: &McpSharedState, pty_id: Option<&str>) -> Value {
    let Some(pty_id) = pty_id else {
        return json!({ "error": "unidentified_caller", "reason": "no pty_id in Hello frame" });
    };

    // ── daemon-hosted path ──────────────────────────────────────────────────
    // In the daemon, the Hello `pty_id` *is* the focus tag. Identity comes from
    // the session/focus registry and live pane membership from the pane registry
    // (always at least `["repl"]`).
    if let Some(daemon) = &state.daemon {
        let tag = pty_id;
        let (pane_ids, layout_applied) = {
            let reg = daemon.pane_registry.lock().unwrap();
            let ids = reg.pane_ids(tag);
            if ids.is_empty() {
                (vec![REPL_PANE_ID.to_string()], false)
            } else {
                let applied = ids.iter().any(|id| id != REPL_PANE_ID);
                (ids, applied)
            }
        };
        let (view_title, agent_name) = {
            let mgr = daemon.session_mgr.lock().unwrap();
            mgr.focus_registry()
                .into_iter()
                .find(|f| f.tag == tag)
                .map(|f| (f.display_name, Some(f.agent_name)))
                .unwrap_or_else(|| (tag.to_string(), None))
        };
        return json!({
            "view_id": tag,
            "view_title": view_title,
            "agent_name": agent_name,
            "pty_id": tag,
            "session_id": tag,
            "pane_ids": pane_ids,
            "layout_applied": layout_applied,
            "nostromo_version": env!("CARGO_PKG_VERSION"),
        });
    }

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

    // ── daemon-hosted `layout_applied` ──────────────────────────────────────
    //
    // The daemon-hosted path collapses "no layout applied yet" and "the
    // layout genuinely has only a repl pane" into the same `pane_ids: ["repl"]`
    // shape, leaving the caller unable to tell the two apart. `layout_applied`
    // must disambiguate: false when the tag has no pane-registry entry (or
    // only the implicit repl) because no layout was ever applied, true once a
    // real (multi-pane) layout has been applied for that tag.

    /// Build a daemon-hosted `McpSharedState` backed by a real `PaneRegistry`
    /// and `SessionManager`, mirroring `apply_layout::tests::make_state`.
    fn make_daemon_state() -> McpSharedState {
        use crate::ipc::pane_registry::PaneRegistry;
        use crate::ipc::SessionManager;
        use crate::mcp::DaemonMcpBackend;
        use std::sync::{Arc, Mutex};
        use tokio::sync::broadcast;

        let tmp = tempfile::TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        // Leak the tempdir so it outlives the test.
        std::mem::forget(tmp);
        let (broadcast_tx, _rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: crate::mcp::PerriDaemonState::default(),
        };
        McpSharedState::for_daemon(backend)
    }

    #[tokio::test]
    async fn layout_applied_is_false_before_a_layout_is_applied_and_true_after() {
        let state = make_daemon_state();

        // Fresh tag: never registered/initialised in the PaneRegistry, so no
        // layout has ever been applied for it. The caller must be told that,
        // not shown a bare `["repl"]` that looks indistinguishable from a
        // deliberate repl-only layout.
        let before = handle(&state, Some("perri")).await;
        assert_eq!(before["layout_applied"], false);

        // Apply the compiled-in multi-pane "perri-standard" layout for the
        // same tag.
        let apply_result = crate::mcp::tools::apply_layout::apply_layout(
            &state,
            &json!({ "name": "perri-standard" }),
            Some("perri"),
        )
        .await;
        assert_eq!(apply_result["ok"], true);

        let after = handle(&state, Some("perri")).await;
        assert_eq!(after["layout_applied"], true);
    }
}
