//! MCP tool handler for `nostromo.apply_layout` (daemon-hosted).
//!
//! `nostromo.apply_layout({ name })` or `nostromo.apply_layout({ tree, panes })`
//! resolves a declarative [`LayoutSchema`](crate::mcp::layout_schema::LayoutSchema)
//! (named, with on-disk-override precedence, or inline), builds the pane tree
//! through the existing [`PaneRegistry`](crate::ipc::pane_registry::PaneRegistry),
//! runs each pane's data fetch **server-side, with no LLM involvement**, and
//! broadcasts the result in one round trip: a single `ServerMsg::FocusLayout`
//! followed by one `ServerMsg::PaneContent` per non-repl pane.
//!
//! This collapses the imperative `reset_panes` → `create_pane` (×N) →
//! `set_pane_layout` → per-pane `set_pane_content`/read-tool sequence — and all
//! the fetched data along the way — out of the calling agent's context into a
//! single structured tool call. It is purely additive: the imperative tools are
//! unchanged and still work.

use serde_json::{json, Value};

use crate::ipc::pane_registry::REPL_PANE_ID;
use crate::ipc::protocol::{PaneContentWire, PrListItem, ServerMsg};
use crate::mcp::layout_schema::{self, LayoutSchema};
use crate::mcp::state::McpSharedState;

/// Stable, machine-readable failure modes for `apply_layout` and the layout
/// schema it resolves. Mirrors `PaneError::code()`'s style: the tool layer
/// surfaces these as `{ "error": "<code>" }`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyLayoutError {
    /// A named layout has no on-disk override and no compiled-in default.
    UnknownLayout,
    /// A pane's `source` isn't in the closed fetcher registry.
    UnknownSource,
    /// A pane's `content_kind` isn't a recognised `PaneContentWire` variant.
    InvalidContentKind,
    /// The schema document itself is malformed (bad YAML/JSON, `repl` bound
    /// as a pane, missing required fields).
    InvalidSchema,
    /// A fetcher ran but failed to produce content.
    FetchFailed,
}

impl ApplyLayoutError {
    /// The stable snake_case code for the wire.
    pub fn code(self) -> &'static str {
        match self {
            ApplyLayoutError::UnknownLayout => "unknown_layout",
            ApplyLayoutError::UnknownSource => "unknown_source",
            ApplyLayoutError::InvalidContentKind => "invalid_content_kind",
            ApplyLayoutError::InvalidSchema => "invalid_schema",
            ApplyLayoutError::FetchFailed => "fetch_failed",
        }
    }
}

/// Default placeholder text for `perri.get_current_pr` when no PR is loaded.
/// Shared with `perri_mutators::clear_current_pr`'s daemon branch so the two
/// can't drift on what "cleared" looks like in the diff pane.
pub(crate) const NO_PR_LOADED_PLACEHOLDER: &str = "No PR loaded.";

/// The closed set of `source` names a `PaneSpec` may bind to. Adding a new
/// source is a deliberate code change: add a `match` arm in [`fetch`], list it
/// here, and ensure the corresponding receiver is wired into the daemon's
/// `McpSharedState`.
const KNOWN_SOURCES: &[&str] = &["perri.list_pr_queue", "perri.get_current_pr"];

/// True when `source` is in the closed fetcher registry.
pub(crate) fn source_is_known(source: &str) -> bool {
    KNOWN_SOURCES.contains(&source)
}

/// The `PaneContentWire` surface-name a known `source` actually produces, per
/// [`fetch`]. `layout_schema::validate` cross-checks a pane's declared
/// `content_kind` against this so a schema can't declare e.g.
/// `content_kind: text` for `source: perri.list_pr_queue` and have it pass
/// validation while `fetch` silently ignores the declaration and emits
/// `PrList` anyway — this is the single source of truth `fetch` itself
/// dispatches on, kept next to it so the two can't drift apart.
pub(crate) fn source_content_kind(source: &str) -> Option<&'static str> {
    match source {
        "perri.list_pr_queue" => Some("pr_list"),
        "perri.get_current_pr" => Some("text"),
        _ => None,
    }
}

/// Resolve the focus tag a layout tool targets: an explicit `view_id`, else the
/// caller's own focus (`pty_id` from the Hello frame). Mirrors
/// `create_pane.rs::target_tag`. `pub(crate)` — also used by
/// `refresh_pane::refresh_pane_content`.
pub(crate) fn target_tag<'a>(args: &'a Value, pty_id: Option<&'a str>) -> Option<&'a str> {
    args.get("view_id").and_then(|v| v.as_str()).or(pty_id)
}

/// Build a [`LayoutSchema`] from an inline `{ tree, panes }` payload.
fn schema_from_inline(args: &Value) -> Result<LayoutSchema, ApplyLayoutError> {
    let tree = args
        .get("tree")
        .cloned()
        .ok_or(ApplyLayoutError::InvalidSchema)?;
    let panes = args.get("panes").cloned().unwrap_or_else(|| json!({}));
    let value = json!({ "name": "inline", "tree": tree, "panes": panes });
    let schema: LayoutSchema =
        serde_json::from_value(value).map_err(|_| ApplyLayoutError::InvalidSchema)?;
    layout_schema::validate(&schema)?;
    Ok(schema)
}

/// Run a pane's bound `source` fetcher, purely server-side (no LLM turn).
///
/// `perri.get_current_pr` renders a plain-text snapshot summary — no agent
/// "highlights" — the agent may overwrite it afterward via `set_pane_content`.
///
/// `pub(crate)` — this is the single dispatch point both `apply_layout` and
/// `refresh_pane::refresh_pane_content` call, which is what guarantees the two
/// tools can never disagree about what a source produces.
pub(crate) fn fetch(
    source: &str,
    state: &McpSharedState,
    placeholder: Option<&str>,
) -> Result<PaneContentWire, ApplyLayoutError> {
    match source {
        "perri.list_pr_queue" => {
            let items_json = crate::mcp::tools::perri::list_pr_queue(state);
            let items: Vec<PrListItem> =
                serde_json::from_value(items_json).map_err(|_| ApplyLayoutError::FetchFailed)?;
            Ok(PaneContentWire::PrList { items })
        }
        "perri.get_current_pr" => {
            let snapshot = crate::mcp::tools::perri::get_current_pr(state);
            if snapshot.is_null() {
                let text = placeholder.unwrap_or("No PR loaded.").to_string();
                return Ok(PaneContentWire::Text { text });
            }
            match render_pr_summary(&snapshot) {
                Some(text) => Ok(PaneContentWire::Text { text }),
                None => Err(ApplyLayoutError::FetchFailed),
            }
        }
        _ => Err(ApplyLayoutError::UnknownSource),
    }
}

/// Render a `PrSnapshot` JSON value as a plain-text summary: title,
/// `owner/repo#number`, author, `+adds/-dels`, changed files.
fn render_pr_summary(snapshot: &Value) -> Option<String> {
    let repo = snapshot.get("repo")?.as_str()?;
    let title = snapshot.get("title")?.as_str()?;
    let author = snapshot.get("author")?.as_str()?;
    let number = snapshot.get("pr_number").and_then(|v| v.as_u64());
    let additions = snapshot
        .get("additions")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let deletions = snapshot
        .get("deletions")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);
    let changed_files = snapshot
        .get("changed_files")
        .and_then(|v| v.as_u64())
        .unwrap_or(0);

    let pr_ref = match number {
        Some(n) => format!("{repo}#{n}"),
        None => repo.to_string(),
    };

    Some(format!(
        "{title}\n{pr_ref} by {author}\n+{additions}/-{deletions} across {changed_files} file(s)"
    ))
}

/// Handle `nostromo.apply_layout`.
pub async fn apply_layout(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let Some(daemon) = &state.daemon else {
        return json!({ "error": "not_supported", "detail": "apply_layout requires the daemon-hosted MCP server" });
    };

    // ── resolve the schema (named, with override precedence, or inline) ────
    // `name` and `tree` are documented as mutually exclusive (docs/mcp/panes.md,
    // the tool_descriptors() entry) — enforce that rather than silently
    // preferring `name` and discarding a caller-supplied `tree`/`panes`.
    if args.get("name").is_some() && args.get("tree").is_some() {
        return json!({ "error": "invalid_args", "detail": "provide `name` or `tree`, not both" });
    }
    let schema = if let Some(name) = args.get("name").and_then(|v| v.as_str()) {
        match layout_schema::load(name) {
            Ok(s) => s,
            Err(e) => return json!({ "error": e.code() }),
        }
    } else if args.get("tree").is_some() {
        match schema_from_inline(args) {
            Ok(s) => s,
            Err(e) => return json!({ "error": e.code() }),
        }
    } else {
        return json!({ "error": "invalid_args", "detail": "provide `name` or `tree`" });
    };

    // ── resolve the target focus tag ────────────────────────────────────────
    let explicit_view = args.get("view_id").and_then(|v| v.as_str()).is_some();
    let Some(tag) = target_tag(args, pty_id) else {
        return json!({ "error": "unidentified_caller" });
    };
    let tag = tag.to_string();

    // ── build + validate the tree through the existing PaneRegistry path ────
    let tree = schema.tree.to_pane_tree();
    let set_result = {
        let mut reg = daemon.pane_registry.lock().unwrap();
        if !explicit_view {
            reg.get_or_init(&tag);
        }
        reg.set_layout(&tag, &json!({ "tree": tree }))
    };
    let tree = match set_result {
        Ok(t) => t,
        Err(e) => return json!({ "error": e.code() }),
    };

    // ── broadcast structure, then fetch + broadcast each pane's content ─────
    let _ = daemon.broadcast_tx.send(ServerMsg::FocusLayout {
        tag: tag.clone(),
        tree,
        focused_pane: None,
    });

    let mut warnings = Vec::new();
    for (pane_id, spec) in &schema.panes {
        if pane_id == REPL_PANE_ID {
            continue;
        }
        let Some(source) = &spec.source else {
            continue;
        };
        let content = match fetch(source, state, spec.placeholder.as_deref()) {
            Ok(c) => c,
            Err(e) => {
                warnings.push(json!({ "pane_id": pane_id, "error": e.code() }));
                PaneContentWire::Error {
                    message: format!("apply_layout: {} fetch failed ({})", source, e.code()),
                }
            }
        };
        let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
            tag: tag.clone(),
            pane_id: pane_id.clone(),
            content,
        });
    }

    if warnings.is_empty() {
        json!({ "ok": true })
    } else {
        json!({ "ok": true, "warnings": warnings })
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
        // Leak the tempdir so it outlives the test (its Drop would otherwise
        // remove the directory while the registry might still write to it).
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

    #[test]
    fn apply_layout_error_code_returns_stable_snake_case_strings() {
        assert_eq!(ApplyLayoutError::UnknownLayout.code(), "unknown_layout");
        assert_eq!(ApplyLayoutError::UnknownSource.code(), "unknown_source");
        assert_eq!(
            ApplyLayoutError::InvalidContentKind.code(),
            "invalid_content_kind"
        );
        assert_eq!(ApplyLayoutError::InvalidSchema.code(), "invalid_schema");
        assert_eq!(ApplyLayoutError::FetchFailed.code(), "fetch_failed");
    }

    #[tokio::test]
    async fn applying_perri_standard_broadcasts_layout_and_content() {
        let (state, mut bcast) = make_state();

        // Seed live PR-queue and current-PR data so the fetchers have
        // something real to render.
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

        let (_ptx, pr_rx) = watch::channel(Some(
            serde_json::from_value::<crate::data::perri_pr::PrSnapshot>(serde_json::json!({
                "pr_number": 42, "repo": "acme/web", "title": "Add widget",
                "author": "alice", "url": "https://example.com/42", "diff": "",
                "stale": false, "error": null, "additions": 10, "deletions": 2,
                "changed_files": 3, "head_sha": "abc123", "diff_too_large": false
            }))
            .unwrap(),
        ));
        state.perri_pr_rx = pr_rx;

        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("warnings").is_none());

        let msg = bcast.recv().await.expect("FocusLayout broadcast");
        match msg {
            ServerMsg::FocusLayout { tag, tree, .. } => {
                assert_eq!(tag, "perri");
                let ids = tree.pane_ids();
                assert_eq!(ids.len(), 3);
                assert!(ids.contains(&"queue".to_string()));
                assert!(ids.contains(&"diff".to_string()));
                assert!(ids.contains(&"repl".to_string()));
            }
            other => panic!("expected FocusLayout, got {other:?}"),
        }

        let mut saw_queue = false;
        let mut saw_diff = false;
        for _ in 0..2 {
            match bcast.recv().await.expect("a PaneContent broadcast") {
                ServerMsg::PaneContent {
                    pane_id, content, ..
                } => {
                    if pane_id == "queue" {
                        saw_queue = true;
                        assert!(matches!(content, PaneContentWire::PrList { .. }));
                    } else if pane_id == "diff" {
                        saw_diff = true;
                        match content {
                            PaneContentWire::Text { text } => {
                                assert!(text.contains("Add widget"));
                                assert!(text.contains("acme/web#42"));
                            }
                            other => panic!("expected Text content for diff, got {other:?}"),
                        }
                    } else {
                        panic!("unexpected pane_id: {pane_id}");
                    }
                }
                other => panic!("expected PaneContent, got {other:?}"),
            }
        }
        assert!(saw_queue && saw_diff);
    }

    #[tokio::test]
    async fn get_current_pr_renders_placeholder_when_no_pr_loaded() {
        let (state, mut bcast) = make_state();
        // perri_pr_rx defaults to None via for_test/for_daemon.

        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["ok"], true);

        let _ = bcast.recv().await.unwrap(); // FocusLayout
        let mut saw_placeholder = false;
        for _ in 0..2 {
            if let ServerMsg::PaneContent {
                pane_id, content, ..
            } = bcast.recv().await.unwrap()
            {
                if pane_id == "diff" {
                    if let PaneContentWire::Text { text } = content {
                        assert!(text.contains("No PR loaded"));
                        saw_placeholder = true;
                    }
                }
            }
        }
        assert!(saw_placeholder);
    }

    #[tokio::test]
    async fn inline_tree_mode_applies_without_a_named_layout() {
        let (state, mut bcast) = make_state();

        let args = json!({
            "tree": {
                "direction": "horizontal",
                "ratios": [0.5, 0.5],
                "children": [
                    { "pane": "notes" },
                    { "pane": "repl" }
                ]
            },
            "panes": {
                "notes": { "content_kind": "text" }
            }
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        let msg = bcast.recv().await.expect("FocusLayout broadcast");
        match msg {
            ServerMsg::FocusLayout { tag, tree, .. } => {
                assert_eq!(tag, "perri");
                assert_eq!(tree.pane_ids(), vec!["notes", "repl"]);
            }
            other => panic!("expected FocusLayout, got {other:?}"),
        }
        // "notes" has no `source`, so no PaneContent broadcast follows.
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn unknown_layout_name_returns_stable_error_code() {
        let (state, _bcast) = make_state();
        let result =
            apply_layout(&state, &json!({ "name": "does-not-exist" }), Some("perri")).await;
        assert_eq!(result["error"], "unknown_layout");
    }

    #[tokio::test]
    async fn inline_unknown_source_returns_stable_error_code_and_does_not_mutate_registry() {
        let (state, _bcast) = make_state();

        let args = json!({
            "tree": { "direction": "horizontal", "ratios": [0.5, 0.5],
                      "children": [ { "pane": "notes" }, { "pane": "repl" } ] },
            "panes": { "notes": { "source": "nonexistent.fetcher", "content_kind": "text" } }
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "unknown_source");

        // The registry must not have been mutated: no focus was registered.
        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(!reg.contains("perri"));
        }
    }

    #[tokio::test]
    async fn missing_name_and_tree_returns_invalid_args() {
        let (state, _bcast) = make_state();
        let result = apply_layout(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["error"], "invalid_args");
    }

    #[tokio::test]
    async fn both_name_and_tree_returns_invalid_args_and_does_not_mutate_registry() {
        // `name` and `tree` are documented as mutually exclusive — passing both
        // must be a loud caller error, not a silent "name wins, tree ignored".
        let (state, _bcast) = make_state();
        let args = json!({
            "name": "perri-standard",
            "tree": { "direction": "horizontal", "ratios": [0.5, 0.5],
                      "children": [ { "pane": "notes" }, { "pane": "repl" } ] },
        });

        let result = apply_layout(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "invalid_args");

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert!(!reg.contains("perri"));
        }
    }

    #[tokio::test]
    async fn no_daemon_backend_returns_not_supported() {
        let (event_tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let state = McpSharedState::for_test(event_tx);
        let result =
            apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }
}
