//! Integration test for the MCP `nostromo.get_self` tool.
//!
//! Spawns a real `McpServer` on a tempdir socket, connects a `UnixStream`
//! client, sends the Hello + initialize + tools/call sequence, and asserts the
//! responses match the registered identity.

use std::sync::Arc;
use std::time::SystemTime;

use nostromo::mcp::{McpServer, McpSharedState, PtyIdentity, ViewMeta};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

// ── helpers ───────────────────────────────────────────────────────────────────

/// Build a populated `McpSharedState` with one view + one PTY registered.
async fn make_state() -> Arc<McpSharedState> {
    let (tx, _rx) = mpsc::unbounded_channel();
    let state = Arc::new(McpSharedState::new(tx));

    state.views_meta.write().await.push(ViewMeta {
        id: "perri",
        title: "Perri".to_string(),
        pane_ids: vec!["pr_queue", "diff", "repl"],
    });

    state
        .register_pty(
            "test-pty-id".to_string(),
            PtyIdentity {
                view_id: "perri",
                session_id: "test-session-id".to_string(),
                spawned_at: SystemTime::now(),
            },
        )
        .await;

    state
}

/// Write one JSON-RPC frame (newline-terminated) to the writer.
async fn write_frame<W: AsyncWriteExt + Unpin>(w: &mut W, v: &Value) {
    let mut bytes = serde_json::to_vec(v).unwrap();
    bytes.push(b'\n');
    w.write_all(&bytes).await.unwrap();
}

/// Read one newline-terminated JSON frame from a `BufReader`.
async fn read_frame<R: tokio::io::AsyncRead + Unpin>(r: &mut BufReader<R>) -> Value {
    let mut line = String::new();
    r.read_line(&mut line).await.unwrap();
    serde_json::from_str(line.trim()).expect("response should be valid JSON")
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// A client with a registered `pty_id` gets back full `SelfInfo`.
#[tokio::test]
async fn get_self_known_pty_returns_identity() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp.sock");

    let state = make_state().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .expect("server should bind");

    // Connect and send Hello.
    let stream = UnixStream::connect(&socket_path).await.unwrap();
    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half);

    write_frame(&mut write_half, &json!({"type":"hello","pty_id":"test-pty-id"})).await;

    // MCP initialize.
    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "0.1"}
            }
        }),
    )
    .await;

    let init_resp = read_frame(&mut reader).await;
    assert_eq!(init_resp["result"]["serverInfo"]["name"], "nostromo");

    // tools/list — verify our tool is advertised.
    write_frame(
        &mut write_half,
        &json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}),
    )
    .await;

    let list_resp = read_frame(&mut reader).await;
    let tools = list_resp["result"]["tools"].as_array().unwrap();
    assert!(tools.iter().any(|t| t["name"] == "nostromo.get_self"));

    // tools/call — nostromo.get_self.
    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "nostromo.get_self", "arguments": {}}
        }),
    )
    .await;

    let call_resp = read_frame(&mut reader).await;
    assert!(call_resp.get("error").is_none(), "should not be a JSON-RPC error");

    let text = call_resp["result"]["content"][0]["text"].as_str().unwrap();
    let self_info: Value = serde_json::from_str(text).expect("content text should be JSON");

    assert_eq!(self_info["view_id"], "perri");
    assert_eq!(self_info["view_title"], "Perri");
    assert_eq!(self_info["pty_id"], "test-pty-id");
    assert_eq!(self_info["session_id"], "test-session-id");

    let pane_ids: Vec<&str> = self_info["pane_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(pane_ids, vec!["pr_queue", "diff", "repl"]);
}

/// A client with an unknown `pty_id` gets a structured `unidentified_caller` error.
#[tokio::test]
async fn get_self_unknown_pty_returns_structured_error() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_unknown.sock");

    let state = make_state().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .expect("server should bind");

    let stream = UnixStream::connect(&socket_path).await.unwrap();
    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half);

    // Hello with an unregistered pty_id.
    write_frame(
        &mut write_half,
        &json!({"type":"hello","pty_id":"no-such-pty"}),
    )
    .await;

    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}
        }),
    )
    .await;
    let _ = read_frame(&mut reader).await; // consume initialize response

    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":2,"method":"tools/call",
            "params":{"name":"nostromo.get_self","arguments":{}}
        }),
    )
    .await;

    let call_resp = read_frame(&mut reader).await;
    // Should NOT be a JSON-RPC protocol error — the tool returns a structured result.
    assert!(call_resp.get("error").is_none(), "should not be a JSON-RPC error; got: {call_resp}");

    let text = call_resp["result"]["content"][0]["text"].as_str().unwrap();
    let self_info: Value = serde_json::from_str(text).expect("content text should be JSON");
    assert_eq!(self_info["error"], "unidentified_caller");
}

/// A client that sends no Hello (empty pty_id) gets the same structured error.
#[tokio::test]
async fn get_self_no_hello_returns_structured_error() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_nohello.sock");

    let state = make_state().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .expect("server should bind");

    let stream = UnixStream::connect(&socket_path).await.unwrap();
    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half);

    // Send an empty Hello (no pty_id field).
    write_frame(&mut write_half, &json!({"type":"hello"})).await;

    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}
        }),
    )
    .await;
    let _ = read_frame(&mut reader).await;

    write_frame(
        &mut write_half,
        &json!({
            "jsonrpc":"2.0","id":2,"method":"tools/call",
            "params":{"name":"nostromo.get_self","arguments":{}}
        }),
    )
    .await;

    let call_resp = read_frame(&mut reader).await;
    let text = call_resp["result"]["content"][0]["text"].as_str().unwrap();
    let self_info: Value = serde_json::from_str(text).unwrap();
    assert_eq!(self_info["error"], "unidentified_caller");
}
