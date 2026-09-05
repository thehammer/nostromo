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
use nostromo::ipc::protocol::ServerMsg;
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
async fn load_pr_without_highlights_settles_or_reports_pending_quickly() {
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
    // this test (there's no real native source running) — the 100ms settle
    // timeout configured in make_daemon_state() must still make this call
    // return promptly with `pending: true`, not hang for 5s.
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
    assert_eq!(res["pending"], true);
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
