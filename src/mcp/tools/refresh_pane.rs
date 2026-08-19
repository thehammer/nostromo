//! MCP tool handler for `nostromo.refresh_pane_content` (daemon-hosted, content-only).
//!
//! `nostromo.refresh_pane_content({ view_id?, pane_id, source, placeholder? })`
//! refreshes a single pane's content from a registered server-side data
//! source — the same closed fetcher registry [`apply_layout`](super::apply_layout)
//! uses — **without** touching pane geometry. It never mutates the
//! `PaneRegistry` and never broadcasts `ServerMsg::FocusLayout`; it binds the
//! pane to `source` (D4), then broadcasts a transient `Loading` only on first
//! paint (D5), followed by the fetched content or an `Error`, and returns
//! only once the terminal broadcast has been sent.
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

use crate::ipc::protocol::PaneContentWire;
use crate::mcp::pane_sources::{
    broadcast_loading_if_first_paint, broadcast_pane_content, broadcast_pane_content_with_address,
};
use crate::mcp::state::McpSharedState;
use crate::mcp::tools::apply_layout::{
    address, fetch_async, freshness, source_is_known, target_tag, FetchArgs,
};

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

    // W2: `params` is the source's own argument object — which file, which
    // anchor. Validated by the fetcher, not here: this tool deliberately knows
    // nothing about any individual source's parameter shape, which is what
    // lets a later wedge add a source without touching this file.
    let params = args.get("params").cloned().filter(|v| !v.is_null());

    // D4: an explicit refresh binds this pane to `source`, same as
    // apply_layout — the pane is now considered live and will keep getting
    // automatic updates. D1's guard makes this a silent no-op for a pane
    // that isn't (yet) in `tag`'s tree, which is exactly the case the
    // never-registered-tag tests below exercise.
    daemon
        .pane_registry
        .lock()
        .unwrap()
        .bind_source_with_params(&tag, &pane_id, &source, params.clone());

    // ── loading (first paint only), then fetch + content/error, in that order,
    // deterministically — every call here is synchronous with no `.await`
    // between them, so there is no interleaving window: a subscriber that
    // sees Loading always sees it strictly before the real content.
    let sent_loading = broadcast_loading_if_first_paint(daemon, &tag, &pane_id);

    let fetch_args = FetchArgs {
        tag: Some(&tag),
        placeholder: placeholder.as_deref(),
        params: params.as_ref(),
    };
    match fetch_async(&source, state, fetch_args).await {
        Ok(content) => {
            let fr = freshness(&source, state);
            broadcast_pane_content_with_address(
                daemon,
                &tag,
                &pane_id,
                content,
                Some(fr),
                address(&source, params.as_ref()),
            );
            json!({ "ok": true })
        }
        Err(e) => {
            // A *refusal* (W2 — a line past EOF, a path that doesn't exist, an
            // unresolvable revision) must leave whatever the operator was
            // already reading exactly where it was: the agent made the
            // mistake, not the pane. The one exception is a pane this call
            // itself just put into `Loading` — there is nothing to preserve
            // there, and leaving it spinning forever would be worse than an
            // error. Every other failure stays loud, as before.
            if !e.leaves_content_intact() || sent_loading {
                let message =
                    format!("refresh_pane_content: {source} fetch failed ({})", e.code());
                broadcast_pane_content(
                    daemon,
                    &tag,
                    &pane_id,
                    PaneContentWire::Error { message },
                    None,
                );
            }
            json!({ "error": e.code() })
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::protocol::ServerMsg;
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
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
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
                ..
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
                ..
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
    async fn refresh_after_a_prior_paint_skips_loading_and_goes_straight_to_content() {
        // `apply_layout` paints "queue" once as part of assembling the
        // "perri-standard" layout (its own PaneContent broadcast marks the
        // pane painted — the same D5 rule this file's happy-path test above
        // relies on for a *never-registered* pane). Once a pane has been
        // painted at least once, a second `refresh_pane_content` call for
        // that same pane must NOT re-send the transient Loading indicator —
        // only the fresh content.
        let (state, _bcast) = make_state();
        let state = seeded_queue_state(state);

        let result = crate::mcp::tools::apply_layout::apply_layout(
            &state,
            &json!({ "name": "perri-standard" }),
            Some("perri"),
        )
        .await;
        assert_eq!(result["ok"], true);

        // Subscribe fresh so apply_layout's own FocusLayout/PaneContent
        // broadcasts are never in this receiver's backlog at all — this test
        // only cares what `refresh_pane_content` itself broadcasts next.
        let daemon = state.daemon.as_ref().unwrap();
        let mut bcast = daemon.broadcast_tx.subscribe();

        let args =
            json!({ "view_id": "perri", "pane_id": "queue", "source": "perri.list_pr_queue" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        match bcast.recv().await.expect("a broadcast for this refresh") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(
                    !matches!(content, PaneContentWire::Loading),
                    "an already-painted pane must not see Loading on a subsequent refresh"
                );
                assert!(matches!(content, PaneContentWire::PrList { .. }));
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        // Exactly one broadcast for this refresh — no Loading-then-content pair.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "a painted pane's refresh must be a single content push, not two"
        );
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

    // ── perri.get_pr_diff (W2 — curated-agent-views) ──────────────────────────

    const SAMPLE_UNIFIED_DIFF: &str = "diff --git a/src/main.rs b/src/main.rs\nindex abc123..def456 100644\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,3 @@\n fn main() {\n-    old();\n+    new();\n }\n";

    fn seeded_pr_diff_state(
        state: McpSharedState,
        diff: &str,
        diff_too_large: bool,
        changed_files: u64,
    ) -> McpSharedState {
        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": diff,
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": changed_files, "head_sha": "abc123",
                "diff_too_large": diff_too_large
            }))
            .unwrap(),
        ));
        let mut state = state;
        state.perri_pr_rx = pr_rx;
        state
    }

    #[tokio::test]
    async fn pr_diff_source_broadcasts_loading_then_parsed_diff_with_no_focus_layout() {
        let (state, mut bcast) = make_state();
        let state = seeded_pr_diff_state(state, SAMPLE_UNIFIED_DIFF, false, 1);

        let args =
            json!({ "view_id": "perri", "pane_id": "diff", "source": "perri.get_pr_diff" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        match bcast.recv().await.expect("loading broadcast") {
            ServerMsg::PaneContent { content, .. } => {
                assert!(matches!(content, PaneContentWire::Loading));
            }
            other => panic!("expected PaneContent(Loading), got {other:?}"),
        }

        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "diff");
                match content {
                    PaneContentWire::Diff {
                        repo,
                        number,
                        files,
                        too_large,
                        changed_files,
                    } => {
                        assert_eq!(repo, "acme/web");
                        assert_eq!(number, Some(42));
                        assert!(!too_large);
                        assert_eq!(changed_files, 1);
                        assert_eq!(files.len(), 1, "the sample diff touches exactly one file");
                        assert_eq!(files[0].path, "src/main.rs");
                    }
                    other => panic!("expected Diff content, got {other:?}"),
                }
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        // No FocusLayout — content-only, ever.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn pr_diff_source_too_large_broadcasts_empty_files_with_changed_files_count() {
        let (state, mut bcast) = make_state();
        let state = seeded_pr_diff_state(state, "", true, 137);

        let args =
            json!({ "view_id": "perri", "pane_id": "diff", "source": "perri.get_pr_diff" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.expect("loading broadcast");
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent { content, .. } => match content {
                PaneContentWire::Diff {
                    files,
                    too_large,
                    changed_files,
                    ..
                } => {
                    assert!(too_large, "a diff_too_large snapshot must broadcast too_large: true");
                    assert!(files.is_empty(), "a too_large diff must carry no files");
                    assert_eq!(changed_files, 137);
                }
                other => panic!("expected Diff content, got {other:?}"),
            },
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn pr_diff_source_with_no_pr_loaded_broadcasts_placeholder_text_not_diff() {
        let (state, mut bcast) = make_state();
        // perri_pr_rx left at its default (None) — no PR loaded.

        let args =
            json!({ "view_id": "perri", "pane_id": "diff", "source": "perri.get_pr_diff" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.expect("loading broadcast");
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent { content, .. } => match content {
                PaneContentWire::Text { text } => assert!(text.contains("No PR loaded")),
                other => panic!("expected Text placeholder, not Diff, got {other:?}"),
            },
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    // ── nostromo.get_file (W2 — curated-agent-views) ──────────────────────────

    #[tokio::test]
    async fn get_file_source_with_no_params_returns_invalid_params() {
        let (state, _bcast) = make_state();
        let args = json!({ "view_id": "cody", "pane_id": "file", "source": "nostromo.get_file" });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "invalid_params");
    }

    #[tokio::test]
    async fn get_file_source_with_nonexistent_path_returns_unknown_path() {
        let (state, _bcast) = make_state();
        let args = json!({
            "view_id": "cody", "pane_id": "file", "source": "nostromo.get_file",
            "params": { "path": "does/not/exist.rs", "revision": "working" }
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unknown_path");
    }

    #[tokio::test]
    async fn refusal_on_an_already_painted_pane_produces_no_further_broadcast() {
        // "A bad show never destroys what Hammer was reading" (W2): once a
        // pane has been painted, a refusing nostromo.get_file call must leave
        // it exactly as it was — no Error frame, no anything at all.
        let (state, mut bcast) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            daemon
                .pane_registry
                .lock()
                .unwrap()
                .mark_painted("cody", "file");
        }

        let args = json!({
            "view_id": "cody", "pane_id": "file", "source": "nostromo.get_file",
            "params": { "path": "does/not/exist.rs", "revision": "working" }
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unknown_path");

        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "a refusal on an already-painted pane must not broadcast anything at all"
        );
    }

    #[tokio::test]
    async fn refusal_on_a_never_painted_pane_broadcasts_an_error_so_it_never_sticks_on_loading() {
        let (state, mut bcast) = make_state();

        let args = json!({
            "view_id": "cody", "pane_id": "file", "source": "nostromo.get_file",
            "params": { "path": "does/not/exist.rs", "revision": "working" }
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["error"], "unknown_path");

        // First broadcast: Loading (first paint).
        match bcast.recv().await.expect("loading broadcast") {
            ServerMsg::PaneContent { content, .. } => {
                assert!(matches!(content, PaneContentWire::Loading));
            }
            other => panic!("expected PaneContent(Loading), got {other:?}"),
        }

        // Second broadcast: an Error — a refusal must not leave a
        // never-painted pane stuck spinning on Loading forever.
        match bcast.recv().await.expect("error broadcast") {
            ServerMsg::PaneContent { content, .. } => {
                assert!(matches!(content, PaneContentWire::Error { .. }));
            }
            other => panic!("expected PaneContent(Error), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn refresh_pane_content_with_params_records_them_on_the_binding() {
        let (state, _bcast) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("cody");
            reg.create_pane(
                "cody",
                "file",
                crate::ipc::pane_registry::SplitPosition::Right,
                "repl",
            )
            .unwrap();
        }

        let params = json!({ "path": "does/not/exist.rs", "revision": "working" });
        let args = json!({
            "view_id": "cody", "pane_id": "file", "source": "nostromo.get_file",
            "params": params.clone()
        });
        let _ = refresh_pane_content(&state, &args, None).await;

        let daemon = state.daemon.as_ref().unwrap();
        let reg = daemon.pane_registry.lock().unwrap();
        let binding = reg
            .binding_for("cody", "file")
            .expect("refresh_pane_content must record the binding even though the fetch refused");
        assert_eq!(binding.source, "nostromo.get_file");
        assert_eq!(binding.params, Some(params));
    }

    // ── perri.get_pr_conversation (W3 — curated-agent-views) ──────────────────

    fn seeded_conversation_state(state: McpSharedState) -> McpSharedState {
        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": "",
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": 3, "head_sha": "abc123", "diff_too_large": false,
                "body": "See below:\n\n```rust\nfn f() {}\n```\n",
                "threads": [{
                    "id": "inline-1",
                    "kind": "inline",
                    "path": "src/main.rs",
                    "line": 10,
                    "resolved": false,
                    "comments": [{
                        "id": "c1",
                        "author": "bob",
                        "created_at": "2024-01-01T00:00:00Z",
                        "body": "a plain comment"
                    }]
                }],
                "conversation_error": null
            }))
            .unwrap(),
        ));
        let mut state = state;
        state.perri_pr_rx = pr_rx;
        state
    }

    #[tokio::test]
    async fn pr_conversation_source_broadcasts_loading_then_parsed_conversation_with_no_focus_layout()
    {
        let (state, mut bcast) = make_state();
        let state = seeded_conversation_state(state);

        let args = json!({
            "view_id": "perri", "pane_id": "conversation", "source": "perri.get_pr_conversation"
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        match bcast.recv().await.expect("loading broadcast") {
            ServerMsg::PaneContent { content, .. } => {
                assert!(matches!(content, PaneContentWire::Loading));
            }
            other => panic!("expected PaneContent(Loading), got {other:?}"),
        }

        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "conversation");
                match content {
                    PaneContentWire::PrConversation {
                        repo,
                        number,
                        title,
                        author,
                        body,
                        threads,
                        conversation_error,
                        ..
                    } => {
                        assert_eq!(repo, "acme/web");
                        assert_eq!(number, Some(42));
                        assert_eq!(title, "Add widget");
                        assert_eq!(author, "alice");
                        assert!(
                            body.iter().any(|b| matches!(
                                b,
                                crate::ipc::protocol::MdBlock::CodeBlock { .. }
                            )),
                            "the PR description's fenced code block must be present as a parsed \
                             CodeBlock, got: {body:?}"
                        );
                        assert!(conversation_error.is_none());
                        assert_eq!(threads.len(), 1);
                        assert_eq!(threads[0].comments.len(), 1);
                        assert_eq!(threads[0].comments[0].id, "c1");
                    }
                    other => panic!("expected PrConversation content, got {other:?}"),
                }
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        // No FocusLayout — content-only, ever.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn pr_conversation_source_with_no_pr_loaded_broadcasts_placeholder_text_not_conversation() {
        let (state, mut bcast) = make_state();
        // perri_pr_rx left at its default (None) — no PR loaded.

        let args = json!({
            "view_id": "perri", "pane_id": "conversation", "source": "perri.get_pr_conversation"
        });
        let result = refresh_pane_content(&state, &args, None).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.expect("loading broadcast");
        match bcast.recv().await.expect("content broadcast") {
            ServerMsg::PaneContent { content, .. } => match content {
                PaneContentWire::Text { text } => assert!(text.contains("No PR loaded")),
                other => panic!("expected Text placeholder, not PrConversation, got {other:?}"),
            },
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn pr_conversation_source_refuses_an_unknown_comment_id_and_leaves_a_painted_pane_untouched()
    {
        let (state, mut bcast) = make_state();
        let state = seeded_conversation_state(state);

        // Paint the pane once first (a real comment id — succeeds).
        let good_args = json!({
            "view_id": "perri", "pane_id": "conversation", "source": "perri.get_pr_conversation"
        });
        let result = refresh_pane_content(&state, &good_args, None).await;
        assert_eq!(result["ok"], true);
        let _ = bcast.recv().await.expect("loading broadcast");
        let _ = bcast.recv().await.expect("content broadcast");

        // Now refuse: an anchor naming a comment id absent from the conversation.
        let bad_args = json!({
            "view_id": "perri", "pane_id": "conversation", "source": "perri.get_pr_conversation",
            "params": { "anchor": { "kind": "comment", "id": "does-not-exist" } }
        });
        let result = refresh_pane_content(&state, &bad_args, None).await;
        assert_eq!(result["error"], "unknown_comment_id");

        // Per the refusal-preserves-content convention: a refusal on an
        // already-painted pane must produce no further broadcast at all.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "a refusal on an already-painted pane must not broadcast anything at all"
        );
    }
}
