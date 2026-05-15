//! Integration tests for Phase 4 `nostromo.notify` MCP tool.
//!
//! Each test:
//! 1. Constructs an `McpSharedState` with a real `mpsc` channel.
//! 2. Spawns an `McpServer` on a temp-dir socket.
//! 3. Spawns a "fake event loop" task that drains `AppEvent::McpCommand` values
//!    and replies with stubbed results.
//! 4. Calls `nostromo.notify` through a real MCP client connection.
//! 5. Asserts the fake loop received the expected command fields and the tool
//!    returned `{ "ok": true }`.

use std::sync::Arc;

use nostromo::{
    event::AppEvent,
    mcp::{McpServer, McpSharedState},
    mcp::command::NotifyLevel,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

// ── helpers ───────────────────────────────────────────────────────────────────

async fn make_state_with_channel() -> (Arc<McpSharedState>, mpsc::UnboundedReceiver<AppEvent>) {
    let (tx, rx) = mpsc::unbounded_channel::<AppEvent>();
    let state = Arc::new(McpSharedState::for_test(tx));
    (state, rx)
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

async fn mcp_connect(
    socket_path: &std::path::Path,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    // Hello
    write_frame(&mut write_half, &json!({"type":"hello","pty_id":""})).await;

    // Initialize
    write_frame(&mut write_half, &json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "0.1"}}
    })).await;
    let _init_resp = read_frame(&mut reader).await;

    (reader, write_half)
}

async fn call_tool(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: u64,
    name: &str,
    args: Value,
) -> Value {
    write_frame(writer, &json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": { "name": name, "arguments": args }
    })).await;
    let resp = read_frame(reader).await;
    let text = resp["result"]["content"][0]["text"].as_str().unwrap_or("{}");
    serde_json::from_str(text).unwrap_or_else(|_| json!({"raw": text}))
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// `nostromo.notify` with `level: "info"` dispatches `McpCommand::Notify` with
/// `NotifyLevel::Info` and the correct message; tool returns `{ "ok": true }`.
#[tokio::test]
async fn notify_dispatches_command_and_returns_ok() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_notify_info.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::Notify { message, level, reply, .. } = *cmd {
                assert_eq!(message, "hello world");
                assert_eq!(level, NotifyLevel::Info);
                let _ = reply.send(Ok(()));
                return true;
            }
        }
        false
    });

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;
    let result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.notify",
        json!({ "message": "hello world", "level": "info" }),
    ).await;

    assert!(fake_loop.await.unwrap(), "fake loop should have seen Notify with Info level");
    assert_eq!(result["ok"], true, "tool should return ok=true");
}

/// `nostromo.notify` with `level: "warn"` dispatches `McpCommand::Notify` with
/// `NotifyLevel::Warn`; tool returns `{ "ok": true }`.
#[tokio::test]
async fn notify_with_warn_level() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_notify_warn.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::Notify { message, level, reply, .. } = *cmd {
                assert_eq!(message, "disk usage above 90%");
                assert_eq!(level, NotifyLevel::Warn);
                let _ = reply.send(Ok(()));
                return true;
            }
        }
        false
    });

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;
    let result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.notify",
        json!({ "message": "disk usage above 90%", "level": "warn" }),
    ).await;

    assert!(fake_loop.await.unwrap(), "fake loop should have seen Notify with Warn level");
    assert_eq!(result["ok"], true, "tool should return ok=true");
}

/// `nostromo.notify` with `level: "error"` dispatches `McpCommand::Notify` with
/// `NotifyLevel::Error`; tool returns `{ "ok": true }`.
#[tokio::test]
async fn notify_with_error_level() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_notify_error.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::Notify { message, level, reply, .. } = *cmd {
                assert_eq!(message, "build failed");
                assert_eq!(level, NotifyLevel::Error);
                let _ = reply.send(Ok(()));
                return true;
            }
        }
        false
    });

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;
    let result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.notify",
        json!({ "message": "build failed", "level": "error" }),
    ).await;

    assert!(fake_loop.await.unwrap(), "fake loop should have seen Notify with Error level");
    assert_eq!(result["ok"], true, "tool should return ok=true");
}
