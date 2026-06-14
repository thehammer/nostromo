//! Integration test for the daemon-hosted MCP pane-layout tools.
//!
//! Mirrors `mcp_get_self.rs` but drives the **daemon** backend: it spins up an
//! `McpServer` whose `McpSharedState` carries a `DaemonMcpBackend`, connects a
//! raw `UnixStream`, and exercises `get_self` / `create_pane` / `reset_panes`
//! end-to-end — the raw-socket smoke test the acceptance criteria call for.

use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

// ── helpers ───────────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    broadcast_tx: broadcast::Sender<ServerMsg>,
    _dir: TempDir,
}

fn make_daemon_state() -> Harness {
    let dir = TempDir::new().unwrap();
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
        broadcast_tx: broadcast_tx.clone(),
    };
    Harness {
        state: McpSharedState::for_daemon(backend),
        broadcast_tx,
        _dir: dir,
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
) -> (BufReader<tokio::net::unix::OwnedReadHalf>, tokio::net::unix::OwnedWriteHalf) {
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

/// Issue a `tools/call` and return the parsed tool result object.
async fn call_tool<W: AsyncWriteExt + Unpin, R: tokio::io::AsyncRead + Unpin>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    id: i64,
    name: &str,
    args: Value,
) -> Value {
    write_frame(
        writer,
        &json!({
            "jsonrpc":"2.0","id": id,"method":"tools/call",
            "params":{"name": name, "arguments": args}
        }),
    )
    .await;
    let resp = read_frame(reader).await;
    assert!(
        resp.get("error").is_none(),
        "tool {name} returned a JSON-RPC error: {resp}"
    );
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    serde_json::from_str(text).expect("tool content should be JSON")
}

fn pane_ids(self_info: &Value) -> Vec<String> {
    self_info["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn daemon_get_self_starts_as_single_repl() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-daemon.sock");
    let harness = make_daemon_state();
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "mother").await;
    let info = call_tool(&mut reader, &mut writer, 2, "nostromo.get_self", json!({})).await;

    assert_eq!(info["view_id"], "mother");
    assert_eq!(pane_ids(&info), vec!["repl"]);
}

#[tokio::test]
async fn daemon_create_pane_then_reset_round_trip() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-daemon.sock");
    let harness = make_daemon_state();
    // Subscribe to broadcasts BEFORE binding so we observe FocusLayout fan-out.
    let mut bcast = harness.broadcast_tx.subscribe();
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "mother").await;

    // create_pane: split repl to the right with a "jobs" pane.
    let res = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.create_pane",
        json!({"pane_id":"jobs","position":"split_right","relative_to":"repl"}),
    )
    .await;
    assert_eq!(res["ok"], true);
    assert!(res["tree"].is_object());

    // The new pane is observable in get_self.
    let info = call_tool(&mut reader, &mut writer, 3, "nostromo.get_self", json!({})).await;
    assert_eq!(pane_ids(&info), vec!["repl", "jobs"]);

    // A FocusLayout was broadcast for the focus.
    let msg = bcast.recv().await.expect("a layout broadcast");
    match msg {
        ServerMsg::FocusLayout { tag, tree, .. } => {
            assert_eq!(tag, "mother");
            assert_eq!(tree.pane_ids(), vec!["repl", "jobs"]);
        }
        other => panic!("expected FocusLayout, got {other:?}"),
    }

    // reset_panes returns to a single repl.
    let res = call_tool(&mut reader, &mut writer, 4, "nostromo.reset_panes", json!({})).await;
    assert_eq!(res["ok"], true);
    let info = call_tool(&mut reader, &mut writer, 5, "nostromo.get_self", json!({})).await;
    assert_eq!(pane_ids(&info), vec!["repl"]);
}

#[tokio::test]
async fn daemon_create_pane_invalid_inputs_return_stable_errors() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-daemon.sock");
    let harness = make_daemon_state();
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "mother").await;

    // Unknown relative_to → unknown_pane, and the focus is not wedged.
    let res = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.create_pane",
        json!({"pane_id":"jobs","position":"split_right","relative_to":"does_not_exist"}),
    )
    .await;
    assert_eq!(res["error"], "unknown_pane");

    // Invalid position → invalid_position.
    let res = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.create_pane",
        json!({"pane_id":"jobs","position":"sideways","relative_to":"repl"}),
    )
    .await;
    assert_eq!(res["error"], "invalid_position");

    // The focus still works after the errors.
    let info = call_tool(&mut reader, &mut writer, 4, "nostromo.get_self", json!({})).await;
    assert_eq!(pane_ids(&info), vec!["repl"]);
}
