//! Integration tests for `nostromo.get_render_state` and the `render_state`
//! section it adds to `nostromo.get_view_state` (W1 — render-state-visibility).
//!
//! Exercises the full pipeline end-to-end: a raw `ClientMsg::RenderedShape`
//! frame on the daemon's real IPC socket, stored in the real `PaneRegistry`,
//! read back through the real MCP tool dispatch — including the
//! connection-drop pruning that keeps a closed window's report from
//! outliving it.
//!
//! Mirrors `tests/mcp_decision.rs`'s combined-harness pattern: both wire
//! protocols stood up at once, sharing one `Arc<Mutex<PaneRegistry>>` and one
//! `SessionManager`, because the report is written on the raw IPC socket
//! (`server.rs::handle_client_msg`) and read back through the MCP socket
//! (`nostromo.get_render_state`).

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::{PaneRegistry, SplitPosition};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

// ── harness ───────────────────────────────────────────────────────────────────

struct Harness {
    _dir: TempDir,
    _raw_server: Server,
    _mcp_server: McpServer,
    raw_socket_path: std::path::PathBuf,
    mcp_socket_path: std::path::PathBuf,
    pane_registry: Arc<Mutex<PaneRegistry>>,
}

async fn make_harness() -> Harness {
    let dir = TempDir::new().unwrap();
    let raw_socket_path = dir.path().join("nostromod.sock");
    let mcp_socket_path = dir.path().join("mcp-render-state.sock");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    // Wire the pane registry into the session manager so the raw IPC
    // server's `RenderedShape` handler — and its disconnect-cleanup pruning —
    // can reach it via `session_mgr.pane_registry()`, mirroring `nostromd.rs`'s
    // real startup wiring.
    session_mgr.lock().unwrap().configure_mcp_bridge(
        Arc::clone(&pane_registry),
        dir.path().join("mcp.sock"),
        dir.path().join("mcp-config.json"),
    );

    let raw_server = Server::bind(
        &raw_socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        dir.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .expect("raw server should bind");

    let backend = DaemonMcpBackend {
        pane_registry: Arc::clone(&pane_registry),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: raw_server.tx.clone(),
        perri: nostromo::mcp::PerriDaemonState::default(),
        decisions,
        tickets: Default::default(),
    };
    let mcp_server = McpServer::bind(mcp_socket_path.clone(), McpSharedState::for_daemon(backend))
        .await
        .expect("mcp server should bind");

    Harness {
        _dir: dir,
        _raw_server: raw_server,
        _mcp_server: mcp_server,
        raw_socket_path,
        mcp_socket_path,
        pane_registry,
    }
}

/// Register `tag`'s tree directly against the shared registry — bypassing the
/// MCP tool surface entirely, since it's the resulting *shape* (not how it
/// got built) that these tests care about.
fn seed_tree(pane_registry: &Arc<Mutex<PaneRegistry>>, tag: &str, extra_panes: &[&str]) {
    let mut reg = pane_registry.lock().unwrap();
    reg.init_focus(tag);
    for pane_id in extra_panes {
        reg.create_pane(tag, pane_id, SplitPosition::Right, "repl")
            .unwrap();
    }
}

// ── raw IPC helpers (mirrors tests/mcp_decision.rs) ───────────────────────────

async fn raw_send(stream: &mut UnixStream, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    nostromo::ipc::codec::write_frame(stream, &bytes).await.unwrap();
}

async fn raw_recv(stream: &mut UnixStream) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), nostromo::ipc::codec::read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

async fn raw_handshake(stream: &mut UnixStream, client_id: &str) {
    raw_send(
        stream,
        &ClientMsg::Hello { client_id: client_id.into(), protocol_version: 4 },
    )
    .await;
    assert!(matches!(raw_recv(stream).await, ServerMsg::Welcome { .. }));
    raw_send(
        stream,
        &ClientMsg::Subscribe { topics: vec![Topic::Layout], renders_decisions: false },
    )
    .await;
    // Give the server a moment to finish registering this connection before
    // the test starts sending further frames on it — the same real-sleep
    // synchronization tests/mcp_decision.rs uses for this exact race.
    tokio::time::sleep(Duration::from_millis(50)).await;
}

// ── MCP helpers (mirrors tests/mcp_daemon_panes.rs) ───────────────────────────

async fn write_mcp_frame<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

async fn read_mcp_frame<R: tokio::io::AsyncRead + Unpin>(r: &mut BufReader<R>) -> Value {
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).expect("response should be valid JSON")
}

async fn connect_mcp(
    socket_path: &std::path::Path,
    tag: &str,
) -> (BufReader<tokio::net::unix::OwnedReadHalf>, tokio::net::unix::OwnedWriteHalf) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_mcp_frame(&mut write_half, &json!({"type":"hello","pty_id": tag})).await;
    write_mcp_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}
        }),
    )
    .await;
    let _ = read_mcp_frame(&mut reader).await; // consume initialize response
    (reader, write_half)
}

async fn call_tool<W: AsyncWriteExt + Unpin, R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    id: i64,
    name: &str,
    args: Value,
) -> Value {
    write_mcp_frame(
        writer,
        &json!({
            "jsonrpc":"2.0","id": id,"method":"tools/call",
            "params":{"name": name, "arguments": args}
        }),
    )
    .await;
    let resp = read_mcp_frame(reader).await;
    assert!(
        resp.get("error").is_none(),
        "tool {name} returned a JSON-RPC error: {resp}"
    );
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    serde_json::from_str(text).expect("tool content should be JSON")
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn no_window_has_reported_returns_null_not_true() {
    let harness = make_harness().await;
    seed_tree(&harness.pane_registry, "perri", &["queue"]);

    let (mut reader, mut writer) = connect_mcp(&harness.mcp_socket_path, "perri").await;
    let result = call_tool(&mut reader, &mut writer, 2, "nostromo.get_render_state", json!({})).await;

    assert_eq!(result["windows"], json!([]));
    assert_eq!(
        result["agrees_everywhere"],
        Value::Null,
        "absence of a report must never read as agreement"
    );
    assert_eq!(result["windows_reporting"], 0);
}

#[tokio::test]
async fn two_windows_report_one_agreeing_one_missing_a_region() {
    let harness = make_harness().await;
    seed_tree(&harness.pane_registry, "perri", &["queue", "detail.0", "detail.1"]);

    let mut window0 = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut window0, "macos-window-0").await;
    let mut window2 = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut window2, "macos-window-2").await;

    raw_send(
        &mut window0,
        &ClientMsg::RenderedShape {
            tag: "perri".into(),
            window_id: "0".into(),
            pane_ids: vec!["repl".into(), "queue".into(), "detail.0".into(), "detail.1".into()],
            rendered_at: chrono::Utc::now(),
        },
    )
    .await;
    raw_send(
        &mut window2,
        &ClientMsg::RenderedShape {
            tag: "perri".into(),
            window_id: "2".into(),
            pane_ids: vec!["repl".into(), "queue".into()],
            rendered_at: chrono::Utc::now(),
        },
    )
    .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    let (mut reader, mut writer) = connect_mcp(&harness.mcp_socket_path, "perri").await;
    let result = call_tool(&mut reader, &mut writer, 2, "nostromo.get_render_state", json!({})).await;

    assert_eq!(result["windows_reporting"], 2);
    assert_eq!(result["agrees_everywhere"], false);

    let windows = result["windows"].as_array().unwrap();
    let w0 = windows.iter().find(|w| w["window_id"] == "0").unwrap();
    assert_eq!(w0["agrees"], true);
    assert_eq!(w0["missing"], json!([]));
    assert_eq!(w0["extra"], json!([]));

    let w2 = windows.iter().find(|w| w["window_id"] == "2").unwrap();
    assert_eq!(w2["agrees"], false);
    assert_eq!(w2["missing"], json!(["detail.0", "detail.1"]));
    assert_eq!(w2["extra"], json!([]));

    // Dropping window 2's connection must prune exactly its report.
    drop(window2);
    tokio::time::sleep(Duration::from_millis(200)).await;

    let result = call_tool(&mut reader, &mut writer, 3, "nostromo.get_render_state", json!({})).await;
    assert_eq!(result["windows_reporting"], 1);
    assert_eq!(
        result["agrees_everywhere"], true,
        "only the still-agreeing window's report remains after the divergent window's connection dropped"
    );
    let windows = result["windows"].as_array().unwrap();
    assert_eq!(windows.len(), 1);
    assert_eq!(windows[0]["window_id"], "0");
}

#[tokio::test]
async fn render_state_appears_in_get_view_state() {
    let harness = make_harness().await;
    seed_tree(&harness.pane_registry, "perri", &["queue"]);

    let mut window0 = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut window0, "macos-window-0").await;
    raw_send(
        &mut window0,
        &ClientMsg::RenderedShape {
            tag: "perri".into(),
            window_id: "0".into(),
            pane_ids: vec!["repl".into(), "queue".into()],
            rendered_at: chrono::Utc::now(),
        },
    )
    .await;
    tokio::time::sleep(Duration::from_millis(100)).await;

    let (mut reader, mut writer) = connect_mcp(&harness.mcp_socket_path, "perri").await;
    let result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.get_view_state",
        json!({"view_id": "perri"}),
    )
    .await;

    assert!(
        result["render_state"].is_object(),
        "get_view_state must carry a render_state section: {result}"
    );
    assert_eq!(result["render_state"]["tag"], "perri");
    assert_eq!(result["render_state"]["windows_reporting"], 1);
    assert_eq!(result["render_state"]["agrees_everywhere"], true);
}
