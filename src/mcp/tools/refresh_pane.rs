//! MCP tool handler for `nostromo.refresh_pane_content` (daemon-hosted, content-only).
//!
//! `nostromo.refresh_pane_content({ view_id?, pane_id, source, placeholder? })`
//! refreshes a single pane's content from a registered server-side data
//! source — the same closed fetcher registry [`apply_layout`](super::apply_layout)
//! uses — **without** touching pane geometry. It never mutates the
//! `PaneRegistry` and never broadcasts `ServerMsg::FocusLayout`; it emits
//! exactly two `ServerMsg::PaneContent` broadcasts (a transient `Loading`,
//! then the fetched content or an `Error`) and returns only once both have
//! been sent.
//!
//! This is the fix for the failure mode `apply_layout` doesn't cover: an
//! agent that has already assembled its workspace still needs to refresh a
//! single pane's content many times per session (e.g. Perri re-pushing her
//! PR queue after each review). Before this tool existed, that meant
//! hand-constructing a `set_pane_content` payload every time — which is
//! exactly how Perri once nested a `pr_list` payload inside a `json_snapshot`
//! envelope and rendered her queue pane as inert garbage. Reusing
//! `apply_layout`'s `fetch()` dispatch point directly means the two tools
//! can never disagree about what a source produces, and the caller never
//! constructs the `items`/`kind` pairing by hand at all.

use serde_json::{json, Value};

use crate::ipc::protocol::{PaneContentWire, ServerMsg};
use crate::mcp::state::McpSharedState;
use crate::mcp::tools::apply_layout::{fetch, source_is_known, target_tag};

/// Handle `nostromo.refresh_pane_content`.
pub async fn refresh_pane_content(
    state: &McpSharedState,
    args: &Value,
    pty_id: Option<&str>,
) -> Value {
    // ── validate everything that can fail before any broadcast ──────────────
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "refresh_pane_content requires the daemon-hosted MCP server" });
    };

    let pane_id = match args.get("pane_id").and_then(|v| v.as_str()) {
        Some(s) => s.to_string(),
        None => return json!({ "error": "invalid_args", "detail": "missing pane_id" }),
    };

    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    // Missing and unknown are the same failure mode here — an absent source
    // is trivially "not in the known registry" — so both fall through to the
    // single `unknown_source` check rather than a separate missing-field error.
    let source = args.get("source").and_then(|v| v.as_str()).unwrap_or("");
    if !source_is_known(source) {
        return json!({ "error": "unknown_source" });
    }
    let source = source.to_string();

    let placeholder = args
        .get("placeholder")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // ── loading, then fetch + content/error — in that order, deterministically ──
    // broadcast_tx.send is synchronous and ordered, and fetch() below has no
    // .await between the two sends, so there is no interleaving window: every
    // subscriber always sees Loading strictly before the real content.
    let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
        tag: tag.clone(),
        pane_id: pane_id.clone(),
        content: PaneContentWire::Loading,
    });

    match fetch(&source, state, placeholder.as_deref()) {
        Ok(content) => {
            let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
            });
            json!({ "ok": true })
        }
        Err(e) => {
            // Push an Error content so the pane never sticks on Loading.
            let message = format!("refresh_pane_content: {source} fetch failed ({})", e.code());
            let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
                tag,
                pane_id,
                content: PaneContentWire::Error { message },
            });
            json!({ "error": e.code() })
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::SessionManager;
    use crate::mcp::DaemonMcpBackend;
    use std::sync::{Arc, Mutex};
    use tokio::sync::{broadcast, watch};

    fn make_state() -> (McpSharedState, broadcast::Receiver<ServerMsg>) {
        let tmp = tempfile::TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        std::mem::forget(tmp);
        let (broadcast_tx, rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: crate::mcp::PerriDaemonState::default(),
        };
        (McpSharedState::for_daemon(backend), rx)
    }

    fn seeded_queue_state(state: McpSharedState) -> McpSharedState {
        let queue_items = serde_json::json!([
            { "repo": "acme/web", "number": 42, "title": "Add widget", "author": "alice",
              "bucket": "requested", "ci_state": "success", "url": "https://example.com/42" }
        ]);
        let (_qtx, queue_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_queue::PrQueueSnapshot>(
                serde_json::json!({ "generated_at": null, "items": queue_items, "stale": false, "error": null }),
            )
            .unwrap(),
        ));
        let mut state = state;
        state.perri_queue_rx = queue_rx;
        state
    }

    fn seeded_pr_state(state: McpSharedState) -> McpSharedState {
        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": "",
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": 3, "head_sha": "abc123", "diff_too_large": false
            }))
            .unwrap(),
        ));
        let mut state = state;
        state.perri_pr_rx = pr_rx;
        state
    }

    #[tokio::test]
    async fn happy_path_pr_list_broadcasts_loading_then_pr_list_no_focus_layout() {
        let (state, mut bcast) = make_state();
        let state = seeded_queue_state(state);

        let args =
            json!({ "view_id": "perri", "pane_id": "queue", "source": "perri.list_pr_queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        // First broadcast is Loading.
        match bcast.recv().await.expect("loading broadcast") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(matches!(content, PaneContentWire::Loading));
            }
            other => panic!("expected PaneContent(Loading), got {other:?}"),
        }

        // Second broadcast is the real content — PrList, never JsonSnapshot.
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(matches!(content, PaneContentWire::PrList { .. }));
            }
            other => panic!("expected PaneContent(PrList), got {other:?}"),
        }

        // No FocusLayout — content-only, ever.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err()
        );

        // No registry mutation — the view was never created.
        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(!reg.contains("perri"));
        }
    }

    #[tokio::test]
    async fn happy_path_text_matches_apply_layout_rendering() {
        let (state, mut bcast) = make_state();
        let state = seeded_pr_state(state);

        let args =
            json!({ "view_id": "perri", "pane_id": "diff", "source": "perri.get_current_pr" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.expect("loading broadcast"); // Loading
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent { content, .. } => match content {
                PaneContentWire::Text { text } => {
                    assert!(text.contains("Add widget"));
                    assert!(text.contains("acme/web#42"));
                }
                other => panic!("expected Text content, got {other:?}"),
            },
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn placeholder_empty_state_returns_ok_not_fetch_failed() {
        let (state, mut bcast) = make_state();
        // perri_pr_rx left at its default (None) — no PR loaded.

        let args = json!({
            "view_id": "perri", "pane_id": "diff", "source": "perri.get_current_pr",
            "placeholder": "No PR loaded."
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.expect("loading broadcast");
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent { content, .. } => match content {
                PaneContentWire::Text { text } => assert_eq!(text, "No PR loaded."),
                other => panic!("expected Text placeholder, got {other:?}"),
            },
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn unknown_source_returns_stable_error_and_broadcasts_nothing() {
        let (state, mut bcast) = make_state();

        let args =
            json!({ "view_id": "perri", "pane_id": "queue", "source": "nonexistent.fetcher" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unknown_source");

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "an unknown source must not broadcast anything, not even Loading"
        );
    }

    #[tokio::test]
    async fn missing_source_is_also_unknown_source() {
        let (state, _bcast) = make_state();
        let args = json!({ "view_id": "perri", "pane_id": "queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unknown_source");
    }

    #[tokio::test]
    async fn cross_tool_agreement_same_source_registry_as_apply_layout() {
        // The two tools must literally agree, because they call the same
        // source_is_known / fetch — this is the drift guard.
        assert!(source_is_known("perri.list_pr_queue"));
        assert!(source_is_known("perri.get_current_pr"));
        assert!(!source_is_known("nonexistent.fetcher"));
    }

    #[tokio::test]
    async fn missing_pane_id_returns_invalid_args() {
        let (state, _bcast) = make_state();
        let args = json!({ "view_id": "perri", "source": "perri.list_pr_queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "invalid_args");
    }

    #[tokio::test]
    async fn unidentified_caller_returns_stable_error() {
        let (state, _bcast) = make_state();
        let args = json!({ "pane_id": "queue", "source": "perri.list_pr_queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unidentified_caller");
    }

    #[tokio::test]
    async fn no_daemon_backend_returns_not_supported() {
        let (event_tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let state = McpSharedState::for_test(event_tx);
        let args =
            json!({ "view_id": "perri", "pane_id": "queue", "source": "perri.list_pr_queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "not_supported");
    }
}
