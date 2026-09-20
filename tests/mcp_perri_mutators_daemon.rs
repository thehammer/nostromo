//! End-to-end integration test for Perri's mutating MCP tools under the
//! **daemon-hosted** MCP server.
//!
//! Before this fix, `perri.load_pr`, `perri.clear_current_pr`,
//! `perri.set_selected_index` unconditionally posted an `AppEvent::McpCommand`
//! and waited on a oneshot reply — a path that only the standalone TUI's own
//! event loop ever drained. Under `nostromd` nothing consumes that channel,
//! so every call burned the full 5s command timeout and returned
//! `{"error":"event_loop_timeout"}`. `perri.get_selected_index` wasn't even
//! registered as a tool. This test drives all four over a real Unix socket
//! against a daemon-hosted `McpSharedState` and asserts none of that happens
//! anymore.
//!
//! Mirrors `tests/mcp_daemon_panes.rs`'s harness.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{PaneContentWire, ServerMsg};
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

// ── helpers ───────────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    _dir: TempDir,
    perri_state_dir: std::path::PathBuf,
}

fn make_daemon_state() -> Harness {
    let dir = TempDir::new().unwrap();
    let perri_state_dir = dir.path().join("perri-state");
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);

    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx,
        perri: PerriDaemonState {
            state_dir: Some(perri_state_dir.clone()),
            pr_refresh_tx: None,
            queue_refresh_tx: None,
            selected_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
            // Short settle timeout so a load_pr call with no matching
            // snapshot (the common case in this test — no real GitHub
            // fetch happens) resolves quickly instead of waiting 12s.
            settle_timeout: Duration::from_millis(100),
        },
        decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
        tickets: Default::default(),
    };
    Harness {
        state: McpSharedState::for_daemon(backend),
        _dir: dir,
        perri_state_dir,
    }
}

async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

async fn read_frame<R: tokio::io::AsyncRead + Unpin>(r: &mut BufReader<R>) -> Value {
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).expect("response should be valid JSON")
}

/// Connect, send Hello with `tag` as pty_id, and complete `initialize`.
async fn connect(
    socket_path: &std::path::Path,
    tag: &str,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_frame(&mut write_half, &json!({"type":"hello","pty_id": tag})).await;
    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}
        }),
    )
    .await;
    let _ = read_frame(&mut reader).await; // consume initialize response
    (reader, write_half)
}

/// Issue a `tools/call`, assert it resolved within `within` (proving it did
/// not fall into the 5s `event_loop_timeout` trap), and return the parsed
/// tool result object.
async fn call_tool_bounded<W: AsyncWriteExt + Unpin, R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    id: i64,
    name: &str,
    args: Value,
    within: Duration,
) -> Value {
    write_frame(
        writer,
        &json!({
            "jsonrpc":"2.0","id": id,"method":"tools/call",
            "params":{"name": name, "arguments": args}
        }),
    )
    .await;
    let resp = tokio::time::timeout(within, read_frame(reader))
        .await
        .unwrap_or_else(|_| panic!("{name} did not respond within {within:?}"));
    assert!(
        resp.get("error").is_none(),
        "tool {name} returned a JSON-RPC error: {resp}"
    );
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    let value: Value = serde_json::from_str(text).expect("tool content should be JSON");
    assert_ne!(
        value.get("error").and_then(|e| e.as_str()),
        Some("event_loop_timeout"),
        "{name} fell back to the TUI event-loop path and timed out: {value}"
    );
    assert_ne!(
        value.get("error").and_then(|e| e.as_str()),
        Some("event_loop_closed"),
        "{name} fell back to the TUI event-loop path and found it closed: {value}"
    );
    value
}

/// `nostromo.get_self`, parsed to the tool-content object.
async fn get_self<W: AsyncWriteExt + Unpin, R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    id: i64,
) -> Value {
    call_tool_bounded(
        reader,
        writer,
        id,
        "nostromo.get_self",
        json!({}),
        Duration::from_secs(1),
    )
    .await
}

/// The `detail.*` pane ids in a `nostromo.get_self` response — the tabbed
/// "detail" region's live tabs, per `views.yaml`'s `pane_prefix: detail`.
/// Empty means the region does not currently exist for this focus.
fn detail_pane_ids(self_info: &Value) -> Vec<String> {
    self_info["pane_ids"]
        .as_array()
        .expect("pane_ids must be an array")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .filter(|id| id.starts_with("detail."))
        .collect()
}

/// Every message currently sitting in `bcast`, without waiting. Safe to call
/// right after a `tools/call` response has been read: the handler behind
/// `nostromo.show`/`perri.load_pr` never awaits between a broadcast send and
/// returning its JSON result, so every message it sent is already in the
/// channel by the time the JSON-RPC response reaches this side of the socket.
fn drain_broadcasts(bcast: &mut broadcast::Receiver<ServerMsg>) -> Vec<ServerMsg> {
    let mut out = Vec::new();
    while let Ok(msg) = bcast.try_recv() {
        out.push(msg);
    }
    out
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn all_four_perri_mutators_never_hit_the_event_loop_timeout_path() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    // Seed the perri-standard layout so diff/queue panes exist for the
    // caller's own focus ("perri", from the Hello pty_id).
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-standard" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    // A generous bound well under the old 5s COMMAND_TIMEOUT_SECS trap —
    // if any of these regress to the TUI event-loop fallback, this fails
    // loudly instead of silently passing after a 5s stall.
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "perri.load_pr",
        json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let pointer_path = harness.perri_state_dir.join("current-pr.json");
    assert!(
        pointer_path.exists(),
        "perri.load_pr must write current-pr.json into the daemon's Perri state dir"
    );
    let pointer: Value =
        serde_json::from_str(&std::fs::read_to_string(&pointer_path).unwrap()).unwrap();
    assert_eq!(pointer["number"], 42);
    assert_eq!(pointer["repo"], "acme/web");

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.set_selected_index",
        json!({ "index": 0 }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        5,
        "perri.get_selected_index",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["index"], 0);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        6,
        "perri.clear_current_pr",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(
        !pointer_path.exists(),
        "perri.clear_current_pr must remove current-pr.json"
    );
}

#[tokio::test]
async fn load_pr_without_highlights_with_no_native_source_reports_not_retryable_quickly() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon2.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let _ = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-standard" }),
        Duration::from_secs(1),
    )
    .await;

    // No highlights, and nothing will ever publish a matching snapshot in
    // this test — `make_daemon_state()` (via `McpSharedState::for_test`)
    // wires `perri_pr_rx` from a `watch::channel` whose sender is dropped
    // immediately, standing in for "no real `PerriPrNativeSource` task is
    // running". That is `SnapshotWait::SourceGone`, not a settle-timeout —
    // the wait must resolve as soon as `rx.changed()` sees the sender gone,
    // well inside the 1500ms bound below (in fact well inside the 100ms
    // settle timeout `make_daemon_state()` configures, since a dropped
    // sender doesn't need to wait for it at all). Before `SnapshotWait`
    // existed this scenario and a genuine in-flight-but-slow fetch both
    // collapsed into `pending: true`; now they're distinguishable, and this
    // is the source-gone one — `pending: false, retryable: false`.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "perri.load_pr",
        json!({ "number": 7, "repo": "acme/anvil" }),
        Duration::from_millis(1500),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(res["pending"], false);
    assert_eq!(res["retryable"], false);
}

/// End-to-end: `perri.clear_current_pr` on a **curated** focus (a layout
/// where the only fixed pane is `queue` — the review's detail panes are
/// created on demand by `nostromo.show`, named `detail.0`/`detail.1`/…, not
/// the legacy `diff`) must still find and close the review tab it opened.
/// Before this fix, `clear_current_pr`'s daemon branch only ever pushed to
/// panes literally named `"diff"`/`"queue"`, so on this layout it was a
/// silent no-op: `ok: true`, nothing closed, no content pushed, no visible
/// error — exactly the bug this fix targets.
#[tokio::test]
async fn clear_current_pr_over_the_real_socket_closes_a_curated_pr_diff_tab() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon3.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true, "nostromo.show should open the pr_diff tab: {res}");

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.clear_current_pr",
        json!({}),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(
        res.get("warnings").is_none(),
        "a healthy clear on a layout it actually applied must never warn: {res}"
    );
    let closed = res["closed"]
        .as_array()
        .expect("`closed` must be present and an array");
    assert!(
        !closed.is_empty(),
        "the pr_diff tab nostromo.show just opened must have been closed: {res}"
    );
}

/// End-to-end: `perri.load_pr` on a **curated** focus that already has an
/// open `pr_diff` review tab (via `nostromo.show`) must not warn
/// `unknown_pane`. Before this fix, `load_pr`'s daemon branch only ever
/// pushed to a pane literally named `"diff"` — which doesn't exist on this
/// layout — producing a false `{"pane_id":"diff","skipped":"unknown_pane"}`
/// warning on every load even though the call otherwise succeeded (`ok:
/// true`) and correctly mutated `current-pr.json`.
#[tokio::test]
async fn load_pr_over_the_real_socket_on_a_curated_focus_with_an_open_pr_diff_tab_warns_nothing() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon4.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true, "nostromo.show should open the pr_diff tab: {res}");

    // Load the *same* PR the open tab is showing — a realistic flow (the
    // agent reviews the diff it already opened, then calls load_pr with the
    // highlights it wrote). Loading a *different* PR would make
    // `reset_for_pr_change` close the stale tab first (correct, unrelated
    // R8 behavior), which would leave this focus with no PR-content pane at
    // all and isn't what this test is checking. With the *same* PR, the
    // pr_diff tab survives and is the focus's only PR-content pane — never a
    // valid load_pr target (D2) — so the correct behavior is a successful,
    // silent no-op on pane pushes, not an unknown_pane warning.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.load_pr",
        json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(
        res.get("warnings").is_none(),
        "a curated focus's real pr_diff tab must never produce an unknown_pane warning \
         on load_pr: {res}"
    );
}

// ── GUI PR pickup: the detail region must survive a bare load_pr ───────────────
//
// The reported bug: the macOS GUI's "click a PR row" action calls only
// `perri.load_pr`, with no `nostromo.show` follow-up (unlike an interactive
// agent, which always issues `load_pr` then `show(pr_conversation)` +
// `show(pr_diff)`). On a curated focus, `load_pr`'s own `reset_for_pr_change`
// closes every tab whose review context just went stale — and when that
// empties the tabbed "detail" region, `view_tree::remove_tabs_region` removes
// the region from the tree outright (D5). With no `show` call to follow,
// nothing ever rebuilds it: the queue pane stays, the detail region is just
// gone, and clicking a PR row looks like it does nothing.

/// The core invariant this fix establishes, RED against current `main`: a
/// curated focus with a populated detail region must still have one — with
/// live tabs — after `perri.load_pr` for a *different* PR, even with no
/// `nostromo.show` call anywhere in sight.
///
/// Before the fix: `reset_for_pr_change` closes both tabs, the region empties,
/// and `remove_tabs_region` deletes it; nothing brings it back, so
/// `detail_pane_ids` is empty afterward and this test fails.
#[tokio::test]
async fn load_pr_on_a_curated_focus_rebuilds_the_detail_region_for_the_new_pr_with_no_show_follow_up(
) {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon5.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true, "nostromo.show should open the pr_conversation tab: {res}");

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true, "nostromo.show should open the pr_diff tab: {res}");

    let before = detail_pane_ids(&get_self(&mut reader, &mut writer, 5).await);
    assert_eq!(before.len(), 2, "sanity: the detail region has both tabs before load_pr: {before:?}");

    // A *different* PR, no `nostromo.show` anywhere in this test — exactly the
    // GUI's "click a PR row" path.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        6,
        "perri.load_pr",
        json!({ "number": 99, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let after = detail_pane_ids(&get_self(&mut reader, &mut writer, 7).await);
    assert!(
        !after.is_empty(),
        "the detail region must survive a bare load_pr for a new PR — instead it vanished \
         entirely (D5's remove-on-empty firing with nothing to rebuild it): {after:?}"
    );
    assert_eq!(
        after.len(),
        2,
        "load_pr must rebuild exactly the pr_conversation + pr_diff tabs, not more or fewer: {after:?}"
    );
}

/// Non-regression guard — this test passes against current `main` too. A
/// `perri-standard` focus has no `views.yaml` region system at all
/// (`view_tree::tabs_region(tree, "detail")` is `None` for its tree, since PR
/// content lives in the fixed `diff` leaf pane); this fix must not perturb it
/// in any way. Two different PRs, back to back, no `show` call — the pane
/// structure must be byte-identical before and after each load.
#[tokio::test]
async fn load_pr_on_perri_standard_leaves_the_pane_tree_untouched_across_prs() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon6.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-standard" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let mut before = get_self(&mut reader, &mut writer, 3).await["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    before.sort();
    assert!(
        !before.iter().any(|id| id.starts_with("detail.")),
        "perri-standard never has a detail region: {before:?}"
    );

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.load_pr",
        json!({ "number": 42, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let mut after_first = get_self(&mut reader, &mut writer, 5).await["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    after_first.sort();
    assert_eq!(before, after_first, "load_pr must not alter perri-standard's pane tree");

    // A different PR — the R8 close still runs (unrelated, existing
    // behavior), but there is no detail region to rebuild here regardless.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        6,
        "perri.load_pr",
        json!({ "number": 7, "repo": "acme/anvil", "highlights": "check auth again" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let mut after_second = get_self(&mut reader, &mut writer, 7).await["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    after_second.sort();
    assert_eq!(before, after_second, "load_pr must not alter perri-standard's pane tree");
}

/// Scope guard, not a red test — passes against both `main` and the fix. A
/// curated focus that never had a detail region (no `nostromo.show` call was
/// ever made) must not have one conjured into existence by `load_pr` alone;
/// that stays `nostromo.show`'s job. Only a load_pr that finds a *populated*
/// detail region already in place rebuilds it.
#[tokio::test]
async fn load_pr_does_not_conjure_a_detail_region_that_never_existed() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon7.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    // No `nostromo.show` call anywhere — perri-curated's starting tree is
    // just a bound `queue` and a `repl`.
    let before = detail_pane_ids(&get_self(&mut reader, &mut writer, 3).await);
    assert!(before.is_empty(), "sanity: no detail region before load_pr: {before:?}");

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "perri.load_pr",
        json!({ "number": 99, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let after = detail_pane_ids(&get_self(&mut reader, &mut writer, 5).await);
    assert!(
        after.is_empty(),
        "load_pr must never create a detail region out of nothing: {after:?}"
    );
}

/// Idempotence, RED against current `main`. A curated focus's detail region,
/// rebuilt by a bare `load_pr` (no `show` follow-up), must be *reused* by a
/// subsequent `nostromo.show` for the same new PR — not duplicated. The tab
/// count alone (`== 2`) can't distinguish "load_pr created them, show
/// re-anchored" from "show created them from scratch", because today
/// `load_pr` creates zero tabs and two `show` calls create exactly two either
/// way. The real signal is `nostromo.show`'s own `reused` field: `true` on
/// both calls only when a tab already existed for that PR's identity when
/// `show` ran — which is only possible once the fix's rebuild has landed.
#[tokio::test]
async fn load_pr_recreated_tabs_are_reused_not_duplicated_by_a_following_show() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon8.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    // A different PR, no `show` in between load_pr and the two `show` calls
    // below.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        5,
        "perri.load_pr",
        json!({ "number": 99, "repo": "acme/web", "highlights": "check auth" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        6,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/web", "number": 99 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(
        res["reused"], true,
        "load_pr must have already created this PR's pr_conversation tab, so `show` re-anchors \
         it instead of creating a new one: {res}"
    );

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        7,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 99 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);
    assert_eq!(
        res["reused"], true,
        "load_pr must have already created this PR's pr_diff tab, so `show` re-anchors it \
         instead of creating a new one: {res}"
    );

    let after = detail_pane_ids(&get_self(&mut reader, &mut writer, 8).await);
    assert_eq!(
        after.len(),
        2,
        "exactly two tabs — load_pr's rebuild plus two re-anchoring shows, never four: {after:?}"
    );
}

/// RED against current `main`. Rebuilding the detail region must never block
/// `load_pr` on fetching real content: it binds each new tab to its PR-backed
/// source and paints `Loading` immediately, leaving the actual snapshot to the
/// existing watch-driven broadcaster. This test configures no real native PR
/// source (see `make_daemon_state`'s 100ms `settle_timeout` — nothing will
/// ever publish a matching snapshot here), so if the rebuild instead waited on
/// a fetch, this would stall for the settle timeout at best and hang at
/// worst. `load_pr` is called with no `highlights` (the branch that would
/// otherwise wait on `wait_for_matching_snapshot`) and no `show` follow-up.
#[tokio::test]
async fn load_pr_paints_loading_for_the_recreated_tabs_without_waiting_on_a_fetch() {
    let harness = make_daemon_state();
    let socket_path = harness._dir.path().join("mcp-daemon9.sock");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");
    let mut bcast = harness.state.daemon.as_ref().unwrap().broadcast_tx.subscribe();

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;
    let bound = Duration::from_millis(1500);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        2,
        "nostromo.apply_layout",
        json!({ "name": "perri-curated" }),
        Duration::from_secs(1),
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        3,
        "nostromo.show",
        json!({ "type": "pr_conversation", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        4,
        "nostromo.show",
        json!({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    // Drop everything broadcast by setup so only load_pr's own messages are
    // inspected below.
    let _ = drain_broadcasts(&mut bcast);

    // No `highlights`, no `show` follow-up — a bound comfortably above the
    // 100ms settle_timeout but nowhere near a naive multi-second/minute wait.
    let res = call_tool_bounded(
        &mut reader,
        &mut writer,
        5,
        "perri.load_pr",
        json!({ "number": 99, "repo": "acme/web" }),
        bound,
    )
    .await;
    assert_eq!(res["ok"], true);

    let after = detail_pane_ids(&get_self(&mut reader, &mut writer, 6).await);
    assert!(
        !after.is_empty(),
        "the detail region must exist after a bare load_pr: {after:?}"
    );

    let messages = drain_broadcasts(&mut bcast);
    for pane_id in &after {
        let painted_loading = messages.iter().any(|m| {
            matches!(
                m,
                ServerMsg::PaneContent { pane_id: p, content: PaneContentWire::Loading, .. }
                if p == pane_id
            )
        });
        assert!(
            painted_loading,
            "expected {pane_id} to be painted Loading immediately as part of load_pr's \
             rebuild, not left waiting on a fetch: {messages:?}"
        );
    }
}
