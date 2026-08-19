//! MCP tool handlers for Perri-specific mutations.
//!
//! ## Tools
//! - `perri.load_pr({ number, repo, highlights? })`
//! - `perri.clear_current_pr()`
//! - `perri.set_selected_index({ index })`
//! - `perri.get_selected_index()`
//!
//! ## Two hosts
//!
//! Each handler branches on `state.daemon`:
//!
//! - **Daemon-hosted** (`nostromd`): `load_pr`/`clear_current_pr` write
//!   through [`crate::data::perri_current_pr`] — the same file contract
//!   `PerriView` (TUI) writes — signal the native sources' refresh channels,
//!   and push `ServerMsg::PaneContent` broadcasts for the caller's `diff`
//!   (and, for `clear_current_pr`, `queue`) pane via
//!   [`super::apply_layout::fetch`], so rendering can never disagree with
//!   `apply_layout`/`refresh_pane_content`. `set_selected_index`/
//!   `get_selected_index` read/write an agent-scoped
//!   `Arc<AtomicUsize>` on `DaemonMcpBackend::perri` — it moves no GUI
//!   highlight (see `PerriDaemonState` doc comment).
//! - **TUI-hosted**: unchanged from before this fix — posts an
//!   `AppEvent::McpCommand` and awaits a reply from `PerriView` via the app's
//!   own event loop.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde_json::{json, Value};
use tokio::sync::{oneshot, watch};

use crate::data::{perri_current_pr, perri_pr::PrSnapshot};
use crate::event::AppEvent;
use crate::ipc::protocol::{PaneContentWire, PaneFreshness};
use crate::mcp::pane_sources::{broadcast_loading_if_first_paint, broadcast_pane_content};
use crate::mcp::state::DaemonMcpBackend;
use crate::mcp::tools::apply_layout::{self, SOURCE_CURRENT_PR, SOURCE_PR_QUEUE};
use crate::mcp::{command::McpCommand, state::McpSharedState};

const COMMAND_TIMEOUT_SECS: u64 = 5;

// ── handlers ─────────────────────────────────────────────────────────────────

/// Handle `perri.load_pr({ number, repo, highlights? })`.
pub async fn load_pr(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    let number = match args.get("number").and_then(|v| v.as_u64()) {
        Some(n) if n > 0 => n,
        _ => return json!({ "error": "invalid_args", "detail": "missing or invalid number" }),
    };
    let repo = match args.get("repo").and_then(|v| v.as_str()) {
        Some(s) if !s.is_empty() => s.to_string(),
        _ => return json!({ "error": "invalid_args", "detail": "missing repo" }),
    };
    if let Err(e) = perri_current_pr::validate_repo_slug(&repo) {
        return json!({ "error": "invalid_args", "detail": e });
    }
    let highlights = args
        .get("highlights")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return load_pr_daemon(
            state,
            daemon,
            args,
            pty_id,
            number,
            &repo,
            highlights.as_deref(),
        )
        .await;
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriLoadPr {
        number,
        repo,
        highlights,
        reply: tx,
    };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.clear_current_pr()`.
pub async fn clear_current_pr(state: &McpSharedState, args: &Value, pty_id: Option<&str>) -> Value {
    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return clear_current_pr_daemon(state, daemon, args, pty_id).await;
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::PerriClearCurrentPr { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.set_selected_index({ index })`.
pub async fn set_selected_index(
    state: &McpSharedState,
    args: &Value,
    _pty_id: Option<&str>,
) -> Value {
    let index = match args.get("index").and_then(|v| v.as_u64()) {
        Some(n) => n as usize,
        None => return json!({ "error": "invalid_args", "detail": "missing or invalid index" }),
    };

    // ── daemon-hosted path ──────────────────────────────────────────────────
    // Clamp exactly as `PerriView::set_selected_pr_index` does: to `len - 1`,
    // or `0` when the queue is empty. This is an agent-scoped in-memory cell —
    // it moves no GUI highlight (see `PerriDaemonState` doc comment).
    if let Some(daemon) = &state.daemon {
        let len = state
            .perri_queue_rx
            .borrow()
            .as_ref()
            .map(|s| s.items.len())
            .unwrap_or(0);
        let clamped = if len == 0 { 0 } else { index.min(len - 1) };
        daemon.perri.selected_index.store(clamped, Ordering::SeqCst);
        return json!({ "ok": true });
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::SetPerriSelectedIndex { index, reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(()))) => json!({ "ok": true }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

/// Handle `perri.get_selected_index()`.
pub async fn get_selected_index(state: &McpSharedState, _pty_id: Option<&str>) -> Value {
    // ── daemon-hosted path ──────────────────────────────────────────────────
    if let Some(daemon) = &state.daemon {
        return json!({ "index": daemon.perri.selected_index.load(Ordering::SeqCst) });
    }

    // ── legacy TUI path ─────────────────────────────────────────────────────
    let (tx, rx) = oneshot::channel();
    let cmd = McpCommand::GetPerriSelectedIndex { reply: tx };
    if state
        .event_tx
        .send(AppEvent::McpCommand(Box::new(cmd)))
        .is_err()
    {
        return json!({ "error": "event_loop_closed" });
    }
    match tokio::time::timeout(std::time::Duration::from_secs(COMMAND_TIMEOUT_SECS), rx).await {
        Ok(Ok(Ok(idx))) => json!({ "index": idx }),
        Ok(Ok(Err(e))) => json!({ "error": e }),
        Ok(Err(_)) => json!({ "error": "event_loop_closed" }),
        Err(_) => json!({ "error": "event_loop_timeout" }),
    }
}

// ── daemon-hosted implementations ───────────────────────────────────────────

/// Daemon branch of `perri.load_pr`. See the module doc comment and plan
/// design decisions D1/D3/D4/D5 for the shape of this logic.
async fn load_pr_daemon(
    state: &McpSharedState,
    daemon: &DaemonMcpBackend,
    args: &Value,
    pty_id: Option<&str>,
    number: u64,
    repo: &str,
    highlights: Option<&str>,
) -> Value {
    let Some(state_dir) = daemon.perri.state_dir.clone() else {
        return json!({
            "error": "not_supported",
            "detail": "perri.load_pr requires the daemon's Perri state_dir to be configured",
        });
    };

    if let Err(e) = perri_current_pr::write_pointer(&state_dir, number, repo, highlights) {
        return json!({ "error": "io_error", "detail": e });
    }

    if let Some(tx) = &daemon.perri.pr_refresh_tx {
        let _ = tx.send(());
    }

    let tag = apply_layout::target_tag(args, pty_id).map(|s| s.to_string());
    let mut warnings = Vec::new();
    let mut pending = false;

    match highlights {
        Some(text) => {
            // D4: highlights are agent-authored final content — sever the
            // diff pane's live binding, or the broadcaster would clobber them
            // with the plain rendered summary within seconds.
            if let Some(t) = tag.as_deref() {
                daemon.pane_registry.lock().unwrap().unbind_source(t, "diff");
            }
            // D3: highlights are the pane's final content — no fetch, no wait.
            push_pane_content(
                daemon,
                tag.as_deref(),
                "diff",
                PaneContentWire::Text {
                    text: text.to_string(),
                },
                None,
                &mut warnings,
            );
        }
        None => {
            // D4: no highlights — diff renders straight from
            // perri.get_current_pr, so keep (or re-establish) that binding.
            if let Some(t) = tag.as_deref() {
                daemon
                    .pane_registry
                    .lock()
                    .unwrap()
                    .bind_source(t, "diff", SOURCE_CURRENT_PR);
            }
            push_pane_content(
                daemon,
                tag.as_deref(),
                "diff",
                PaneContentWire::Loading,
                None,
                &mut warnings,
            );

            let mut pr_rx = state.perri_pr_rx.clone();
            let matched =
                wait_for_matching_snapshot(&mut pr_rx, repo, number, daemon.perri.settle_timeout)
                    .await;

            if matched {
                match apply_layout::fetch(SOURCE_CURRENT_PR, state, apply_layout::FetchArgs::default()) {
                    Ok(content) => {
                        let fr = apply_layout::freshness(SOURCE_CURRENT_PR, state);
                        push_pane_content(
                            daemon,
                            tag.as_deref(),
                            "diff",
                            content,
                            Some(fr),
                            &mut warnings,
                        )
                    }
                    Err(e) => {
                        warnings.push(json!({ "pane_id": "diff", "error": e.code() }));
                        push_pane_content(
                            daemon,
                            tag.as_deref(),
                            "diff",
                            PaneContentWire::Error {
                                message: format!(
                                    "perri.load_pr: perri.get_current_pr fetch failed ({})",
                                    e.code()
                                ),
                            },
                            None,
                            &mut warnings,
                        );
                    }
                }
            } else {
                pending = true;
                push_pane_content(
                    daemon,
                    tag.as_deref(),
                    "diff",
                    PaneContentWire::Text {
                        text: format!("Fetching {repo}#{number}\u{2026} (still loading)"),
                    },
                    None,
                    &mut warnings,
                );
            }
        }
    }

    // D5: coherence win — if the loaded PR is in the current queue, move the
    // agent-scoped selected index to it. Leave it unchanged otherwise.
    if let Some(snap) = state.perri_queue_rx.borrow().as_ref() {
        if let Some(idx) = snap
            .items
            .iter()
            .position(|item| item.repo == repo && item.number == number)
        {
            daemon.perri.selected_index.store(idx, Ordering::SeqCst);
        }
    }

    let mut result = json!({ "ok": true });
    if pending {
        result["pending"] = json!(true);
        result["detail"] = json!(format!(
            "refetch for {repo}#{number} still in flight after {:?}",
            daemon.perri.settle_timeout
        ));
    }
    if !warnings.is_empty() {
        result["warnings"] = json!(warnings);
    }
    result
}

/// Daemon branch of `perri.clear_current_pr`.
async fn clear_current_pr_daemon(
    state: &McpSharedState,
    daemon: &DaemonMcpBackend,
    args: &Value,
    pty_id: Option<&str>,
) -> Value {
    let Some(state_dir) = daemon.perri.state_dir.clone() else {
        return json!({
            "error": "not_supported",
            "detail": "perri.clear_current_pr requires the daemon's Perri state_dir to be configured",
        });
    };

    if let Err(e) = perri_current_pr::clear_pointer(&state_dir) {
        return json!({ "error": "io_error", "detail": e });
    }
    if let Err(e) = perri_current_pr::touch_queue_dirty(&state_dir) {
        return json!({ "error": "io_error", "detail": e });
    }

    if let Some(tx) = &daemon.perri.pr_refresh_tx {
        let _ = tx.send(());
    }
    if let Some(tx) = &daemon.perri.queue_refresh_tx {
        let _ = tx.send(());
    }

    let tag = apply_layout::target_tag(args, pty_id).map(|s| s.to_string());
    let mut warnings = Vec::new();

    // D4: both panes bind (not unbind) to their live sources — the diff
    // placeholder is that source's own empty state (the same string
    // `fetch(SOURCE_CURRENT_PR, ..)` returns for a null snapshot), so diff
    // should go live again the instant a PR loads; the queue refetch is
    // exactly what apply_layout would have bound it to.
    if let Some(t) = tag.as_deref() {
        let mut reg = daemon.pane_registry.lock().unwrap();
        reg.bind_source(t, "diff", SOURCE_CURRENT_PR);
        reg.bind_source(t, "queue", SOURCE_PR_QUEUE);
    }

    push_pane_content(
        daemon,
        tag.as_deref(),
        "diff",
        PaneContentWire::Text {
            text: apply_layout::NO_PR_LOADED_PLACEHOLDER.to_string(),
        },
        None,
        &mut warnings,
    );

    push_pane_content(
        daemon,
        tag.as_deref(),
        "queue",
        PaneContentWire::Loading,
        None,
        &mut warnings,
    );
    match apply_layout::fetch(SOURCE_PR_QUEUE, state, apply_layout::FetchArgs::default()) {
        Ok(content) => {
            let fr = apply_layout::freshness(SOURCE_PR_QUEUE, state);
            push_pane_content(
                daemon,
                tag.as_deref(),
                "queue",
                content,
                Some(fr),
                &mut warnings,
            )
        }
        Err(e) => {
            warnings.push(json!({ "pane_id": "queue", "error": e.code() }));
            push_pane_content(
                daemon,
                tag.as_deref(),
                "queue",
                PaneContentWire::Error {
                    message: format!(
                        "perri.clear_current_pr: perri.list_pr_queue fetch failed ({})",
                        e.code()
                    ),
                },
                None,
                &mut warnings,
            );
        }
    }

    if warnings.is_empty() {
        json!({ "ok": true })
    } else {
        json!({ "ok": true, "warnings": warnings })
    }
}

// ── shared daemon helpers ───────────────────────────────────────────────────

/// Push `content` to `pane_id` within `tag`'s pane tree — but only when the
/// registry actually has that pane registered for `tag` (D7). A resolved tag
/// with no such pane, or no tag at all, degrades to a `warnings` entry
/// instead of failing the call or broadcasting to a pane that doesn't exist.
///
/// Delegates the actual send to the D5 choke point: a `Loading` push goes
/// through [`broadcast_loading_if_first_paint`] (so a pane that's already
/// showing content never sees a spinner), everything else goes through
/// [`broadcast_pane_content`] with the given `freshness`.
fn push_pane_content(
    daemon: &DaemonMcpBackend,
    tag: Option<&str>,
    pane_id: &str,
    content: PaneContentWire,
    freshness: Option<PaneFreshness>,
    warnings: &mut Vec<Value>,
) {
    let Some(tag) = tag else {
        if !warnings.iter().any(|w| w.get("pane_push").is_some()) {
            warnings.push(json!({ "pane_push": "unidentified_caller" }));
        }
        return;
    };

    let known = daemon
        .pane_registry
        .lock()
        .unwrap()
        .pane_ids(tag)
        .iter()
        .any(|p| p == pane_id);

    if known {
        if matches!(content, PaneContentWire::Loading) {
            broadcast_loading_if_first_paint(daemon, tag, pane_id);
        } else {
            broadcast_pane_content(daemon, tag, pane_id, content, freshness);
        }
    } else if !warnings
        .iter()
        .any(|w| w.get("pane_id").and_then(|v| v.as_str()) == Some(pane_id))
    {
        warnings.push(json!({ "pane_id": pane_id, "skipped": "unknown_pane" }));
    }
}

/// Poll `rx` (a clone of `McpSharedState::perri_pr_rx`) until it publishes a
/// snapshot whose `(repo, pr_number)` matches the request, or `timeout`
/// elapses. Checks the already-published value first, so a snapshot for the
/// right PR that's already sitting in the channel resolves immediately
/// without waiting for a change. A snapshot for the right PR that carries an
/// `error` still counts as a match — that's a real (if unhappy) answer, not
/// something to keep waiting past.
async fn wait_for_matching_snapshot(
    rx: &mut watch::Receiver<Option<PrSnapshot>>,
    repo: &str,
    number: u64,
    timeout: Duration,
) -> bool {
    fn matches(snap: &Option<PrSnapshot>, repo: &str, number: u64) -> bool {
        matches!(snap, Some(s) if s.repo == repo && s.pr_number == Some(number))
    }

    if matches(&rx.borrow(), repo, number) {
        return true;
    }

    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return false;
        }
        match tokio::time::timeout(remaining, rx.changed()).await {
            Ok(Ok(())) => {
                if matches(&rx.borrow(), repo, number) {
                    return true;
                }
            }
            Ok(Err(_)) => return false, // sender dropped
            Err(_) => return false,     // overall timeout elapsed
        }
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::data::perri_pr::PrSnapshot;
    use crate::data::perri_queue::PrQueueSnapshot;
    use crate::ipc::pane_registry::PaneRegistry;
    use crate::ipc::protocol::ServerMsg;
    use crate::ipc::SessionManager;
    use crate::mcp::{DaemonMcpBackend, PerriDaemonState};
    use std::sync::atomic::AtomicUsize;
    use std::sync::{Arc, Mutex};
    use tempfile::TempDir;
    use tokio::sync::broadcast;

    /// Build a daemon-hosted `McpSharedState` with `perri.state_dir` wired to
    /// a temp dir (so no test ever touches `~/.claude/state/perri`), plus a
    /// fresh broadcast receiver subscribed *after* the "perri" focus has been
    /// seeded with the standard queue/diff/repl layout so pane-existence
    /// checks (D7) pass by default.
    async fn make_daemon_state() -> (McpSharedState, TempDir, broadcast::Receiver<ServerMsg>) {
        let tmp = TempDir::new().unwrap();
        let perri_state_dir = tmp.path().join("perri-state");
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx) = broadcast::channel(64);

        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx: broadcast_tx.clone(),
            perri: PerriDaemonState {
                state_dir: Some(perri_state_dir),
                pr_refresh_tx: None,
                queue_refresh_tx: None,
                selected_index: Arc::new(AtomicUsize::new(0)),
                settle_timeout: Duration::from_millis(50),
            },
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
        };
        let state = McpSharedState::for_daemon(backend);

        // Seed the "perri" focus with the standard layout so diff/queue exist.
        let _ =
            apply_layout::apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri"))
                .await;

        let bcast = broadcast_tx.subscribe();
        (state, tmp, bcast)
    }

    fn seed_queue(state: &mut McpSharedState, items: Value) {
        let snapshot: PrQueueSnapshot = serde_json::from_value(json!({
            "generated_at": null, "items": items, "stale": false, "error": null
        }))
        .unwrap();
        let (_tx, rx) = watch::channel(Some(snapshot));
        state.perri_queue_rx = rx;
    }

    fn pr_snapshot(repo: &str, number: u64, title: &str) -> PrSnapshot {
        serde_json::from_value(json!({
            "pr_number": number, "repo": repo, "title": title,
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": null, "additions": 1, "deletions": 1,
            "changed_files": 1, "head_sha": "abc123", "diff_too_large": false
        }))
        .unwrap()
    }

    async fn recv_pane_content(
        bcast: &mut broadcast::Receiver<ServerMsg>,
    ) -> (String, PaneContentWire) {
        match tokio::time::timeout(Duration::from_millis(500), bcast.recv())
            .await
            .expect("a PaneContent broadcast within 500ms")
            .unwrap()
        {
            ServerMsg::PaneContent {
                pane_id, content, ..
            } => (pane_id, content),
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    // ── load_pr ──────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn load_pr_with_highlights_writes_pointer_and_pushes_text_once() {
        let (state, tmp, mut bcast) = make_daemon_state().await;

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        let content =
            std::fs::read_to_string(tmp.path().join("perri-state").join("current-pr.json"))
                .unwrap();
        let parsed: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(parsed["number"], 42);
        assert_eq!(parsed["repo"], "acme/web");
        assert!(tmp.path().join("perri-state/current-pr.dirty").exists());

        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, "check auth"),
            other => panic!("expected Text, got {other:?}"),
        }

        // Highlights are final content — no second broadcast follows.
        assert!(
            tokio::time::timeout(Duration::from_millis(100), bcast.recv())
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn load_pr_signals_pr_refresh_exactly_once() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        let (refresh_tx, mut refresh_rx) = tokio::sync::mpsc::unbounded_channel::<()>();
        if let Some(daemon) = &mut state.daemon {
            daemon.perri.pr_refresh_tx = Some(refresh_tx);
        }

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        assert!(refresh_rx.try_recv().is_ok(), "expected exactly one signal");
        assert!(
            refresh_rx.try_recv().is_err(),
            "expected exactly one signal, found a second"
        );
    }

    #[tokio::test]
    async fn load_pr_no_highlights_with_snapshot_already_published() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;

        let (_tx, pr_rx) = watch::channel(Some(pr_snapshot("acme/web", 42, "Add widget")));
        state.perri_pr_rx = pr_rx;

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to its final content.
        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => {
                assert!(text.contains("Add widget"));
                assert!(text.contains("acme/web#42"));
            }
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_no_highlights_snapshot_arrives_during_wait() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;

        let (tx, pr_rx) = watch::channel(None);
        state.perri_pr_rx = pr_rx;
        // Increase settle_timeout for this test so the delayed send lands
        // well inside the window.
        if let Some(daemon) = &mut state.daemon {
            daemon.perri.settle_timeout = Duration::from_secs(2);
        }

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(50)).await;
            let _ = tx.send(Some(pr_snapshot("acme/web", 42, "Add widget")));
        });

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert!(result.get("pending").is_none());

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert!(text.contains("Add widget")),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_no_highlights_times_out_leaves_pane_on_text_not_loading() {
        let (state, _tmp, mut bcast) = make_daemon_state().await;
        // perri_pr_rx stays at its default None — never matches.

        let args = json!({ "number": 99, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["pending"], true);

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to the "still loading" placeholder text.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert!(text.contains("acme/web#99")),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_rejects_invalid_args() {
        let (state, tmp, _bcast) = make_daemon_state().await;

        for args in [
            json!({ "repo": "acme/web" }),
            json!({ "number": 0, "repo": "acme/web" }),
            json!({ "number": 1 }),
            json!({ "number": 1, "repo": "org/repo;rm -rf /" }),
        ] {
            let result = load_pr(&state, &args, Some("perri")).await;
            assert_eq!(result["error"], "invalid_args", "args: {args}");
        }

        assert!(!tmp.path().join("perri-state/current-pr.json").exists());
    }

    #[tokio::test]
    async fn load_pr_no_state_dir_returns_not_supported() {
        let (event_tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let dir = TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx2) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
        };
        let mut state = McpSharedState::for_daemon(backend);
        state.event_tx = event_tx;

        let args = json!({ "number": 1, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }

    #[tokio::test]
    async fn load_pr_sets_selected_index_when_pr_is_in_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "acme/web", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "acme/web", "number": 42, "title": "b", "author": "y",
                  "bucket": "requested", "ci_state": "success", "url": "https://y" },
            ]),
        );

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(daemon.perri.selected_index.load(Ordering::SeqCst), 1);
        }
    }

    #[tokio::test]
    async fn load_pr_leaves_selected_index_unchanged_when_pr_not_in_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        if let Some(daemon) = &state.daemon {
            daemon.perri.selected_index.store(3, Ordering::SeqCst);
        }
        seed_queue(&mut state, json!([]));

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "notes" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(daemon.perri.selected_index.load(Ordering::SeqCst), 3);
        }
    }

    #[tokio::test]
    async fn load_pr_diff_text_matches_apply_layout_fetch_output() {
        let (mut state, _tmp, mut bcast) = make_daemon_state().await;
        let (_tx, pr_rx) = watch::channel(Some(pr_snapshot("acme/web", 42, "Add widget")));
        state.perri_pr_rx = pr_rx;

        let expected = match apply_layout::fetch("perri.get_current_pr", &state, apply_layout::FetchArgs::default()).unwrap() {
            PaneContentWire::Text { text } => text,
            other => panic!("expected Text, got {other:?}"),
        };

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        // make_daemon_state() already painted "diff" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here.
        let (_pane_id, content) = recv_pane_content(&mut bcast).await; // final
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, expected),
            other => panic!("expected Text, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn load_pr_unknown_pane_adds_warning_and_still_mutates_state() {
        let (state, tmp, _bcast) = make_daemon_state().await;
        // Register a focus with only a "repl" leaf — no "diff" pane.
        if let Some(daemon) = &state.daemon {
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.get_or_init("no-diff-here");
        }

        let args = json!({
            "number": 42, "repo": "acme/web", "highlights": "notes",
            "view_id": "no-diff-here"
        });
        let result = load_pr(&state, &args, None).await;
        assert_eq!(result["ok"], true);
        let warnings = result["warnings"].as_array().expect("warnings array");
        assert!(warnings
            .iter()
            .any(|w| w["pane_id"] == "diff" && w["skipped"] == "unknown_pane"));
        assert!(
            tmp.path().join("perri-state/current-pr.json").exists(),
            "state mutation must still happen even when the pane is missing"
        );
    }

    #[tokio::test]
    async fn load_pr_unidentified_caller_still_mutates_state_and_warns_once() {
        let (state, tmp, _bcast) = make_daemon_state().await;

        // No highlights + no matching snapshot means the diff pane is pushed
        // to twice (Loading, then the timed-out placeholder) — this proves
        // the "no resolvable tag" warning is deduplicated across pushes,
        // not appended once per attempted push.
        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, None).await;
        assert_eq!(result["ok"], true);
        assert_eq!(result["pending"], true);
        let warnings = result["warnings"].as_array().expect("warnings array");
        assert_eq!(
            warnings
                .iter()
                .filter(|w| w["pane_push"] == "unidentified_caller")
                .count(),
            1,
            "no resolvable tag must warn exactly once, not once per pane push"
        );
        assert!(
            tmp.path().join("perri-state/current-pr.json").exists(),
            "state mutation must still happen even with no resolvable tag"
        );
    }

    // ── load_pr / diff binding ────────────────────────────────────────────────

    #[tokio::test]
    async fn load_pr_with_highlights_severs_the_diff_pane_s_live_binding() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        // make_daemon_state() applies "perri-standard", which binds "diff" to
        // perri.get_current_pr — confirm the starting point before mutating.
        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                Some("perri.get_current_pr")
            );
        }

        let args = json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                None,
                "agent-authored highlights are final content — the diff pane must no \
                 longer be considered live, or the broadcaster would clobber them on \
                 the next queue/PR change"
            );
        }
    }

    #[tokio::test]
    async fn load_pr_without_highlights_keeps_diff_bound_to_its_live_source() {
        let (state, _tmp, _bcast) = make_daemon_state().await;

        let args = json!({ "number": 42, "repo": "acme/web" });
        let result = load_pr(&state, &args, Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            assert_eq!(
                daemon.pane_registry.lock().unwrap().source_for("perri", "diff"),
                Some("perri.get_current_pr"),
                "no-highlights load_pr must keep (or re-establish) the diff pane's \
                 live binding, since its rendered content came from that source"
            );
        }
    }

    // ── clear_current_pr ─────────────────────────────────────────────────────

    #[tokio::test]
    async fn clear_current_pr_removes_file_signals_and_pushes_content() {
        let (state, tmp, mut bcast) = make_daemon_state().await;
        let state_dir = tmp.path().join("perri-state");
        perri_current_pr::write_pointer(&state_dir, 1, "acme/web", None).unwrap();
        assert!(state_dir.join("current-pr.json").exists());

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);

        assert!(!state_dir.join("current-pr.json").exists());
        assert!(state_dir.join("current-pr.dirty").exists());
        assert!(state_dir.join("queue.dirty").exists());

        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "diff");
        match content {
            PaneContentWire::Text { text } => assert_eq!(text, "No PR loaded."),
            other => panic!("expected Text, got {other:?}"),
        }

        // make_daemon_state() already painted "queue" via the perri-standard
        // apply_layout call, so D5 suppresses the Loading push here — the
        // pane goes straight to the refetched list.
        let (pane_id, content) = recv_pane_content(&mut bcast).await;
        assert_eq!(pane_id, "queue");
        assert!(matches!(content, PaneContentWire::PrList { .. }));
    }

    #[tokio::test]
    async fn clear_current_pr_leaves_diff_and_queue_bound_to_their_live_sources() {
        let (state, _tmp, _bcast) = make_daemon_state().await;

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);

        if let Some(daemon) = &state.daemon {
            let reg = daemon.pane_registry.lock().unwrap();
            assert_eq!(
                reg.source_for("perri", "diff"),
                Some("perri.get_current_pr"),
                "clearing the current PR must leave diff ready to go live again \
                 the moment a PR is loaded"
            );
            assert_eq!(
                reg.source_for("perri", "queue"),
                Some("perri.list_pr_queue")
            );
        }
    }

    #[tokio::test]
    async fn clear_current_pr_noop_when_no_pointer_file_is_success() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["ok"], true);
    }

    #[tokio::test]
    async fn clear_current_pr_no_state_dir_returns_not_supported() {
        let dir = TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            dir.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            dir.path().join("sessions.json"),
        )));
        let (broadcast_tx, _rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(crate::ipc::decisions::DecisionRegistry::default())),
        };
        let state = McpSharedState::for_daemon(backend);

        let result = clear_current_pr(&state, &json!({}), Some("perri")).await;
        assert_eq!(result["error"], "not_supported");
    }

    // ── set_selected_index / get_selected_index ─────────────────────────────

    #[tokio::test]
    async fn set_selected_index_clamps_to_single_item_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "acme/web", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
            ]),
        );

        let result = set_selected_index(&state, &json!({ "index": 5 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 0);
    }

    #[tokio::test]
    async fn set_selected_index_clamps_to_zero_on_empty_queue() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(&mut state, json!([]));

        let result = set_selected_index(&state, &json!({ "index": 9 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 0);
    }

    #[tokio::test]
    async fn set_selected_index_round_trips_within_bounds() {
        let (mut state, _tmp, _bcast) = make_daemon_state().await;
        seed_queue(
            &mut state,
            json!([
                { "repo": "a/a", "number": 1, "title": "a", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "a/b", "number": 2, "title": "b", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
                { "repo": "a/c", "number": 3, "title": "c", "author": "x",
                  "bucket": "requested", "ci_state": "success", "url": "https://x" },
            ]),
        );

        let result = set_selected_index(&state, &json!({ "index": 2 }), None).await;
        assert_eq!(result["ok"], true);
        let result = get_selected_index(&state, None).await;
        assert_eq!(result["index"], 2);
    }

    #[tokio::test]
    async fn set_selected_index_missing_index_is_invalid_args() {
        let (state, _tmp, _bcast) = make_daemon_state().await;
        let result = set_selected_index(&state, &json!({}), None).await;
        assert_eq!(result["error"], "invalid_args");
    }
}
