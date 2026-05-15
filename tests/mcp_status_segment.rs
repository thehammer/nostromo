//! Integration tests for Phase 4 `nostromo.register_status_segment` and
//! `nostromo.clear_status_segment` MCP tools.
//!
//! Each test:
//! 1. Constructs an `McpSharedState` with a real `mpsc` channel.
//! 2. Spawns an `McpServer` on a temp-dir socket.
//! 3. Spawns a "fake event loop" task that drains `AppEvent::McpCommand` values
//!    and replies with stubbed results.
//! 4. Calls the tool through a real MCP client connection.
//! 5. Asserts the fake loop received the expected command fields and the tool
//!    returned `{ "ok": true }`.

use std::sync::Arc;

use nostromo::{
    event::AppEvent,
    mcp::{McpServer, McpSharedState},
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

/// `nostromo.register_status_segment` dispatches `McpCommand::RegisterStatusSegment`
/// with the correct `view_id`, `segment_id`, `text`, and `color` fields;
/// tool returns `{ "ok": true }`.
#[tokio::test]
async fn register_segment_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_reg_seg.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::RegisterStatusSegment {
                view_id,
                segment_id,
                text,
                color,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(segment_id, "pending_review");
                assert_eq!(text, "3 PRs");
                assert_eq!(color.as_deref(), Some("amber"));
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
        "nostromo.register_status_segment",
        json!({
            "view_id": "perri",
            "segment_id": "pending_review",
            "text": "3 PRs",
            "color": "amber"
        }),
    ).await;

    assert!(
        fake_loop.await.unwrap(),
        "fake loop should have seen RegisterStatusSegment"
    );
    assert_eq!(result["ok"], true, "tool should return ok=true");
}

/// `nostromo.clear_status_segment` dispatches `McpCommand::ClearStatusSegment`
/// with the correct `view_id` and `segment_id`; tool returns `{ "ok": true }`.
#[tokio::test]
async fn clear_segment_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_clear_seg.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::ClearStatusSegment {
                view_id,
                segment_id,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(segment_id, "pending_review");
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
        "nostromo.clear_status_segment",
        json!({
            "view_id": "perri",
            "segment_id": "pending_review"
        }),
    ).await;

    assert!(
        fake_loop.await.unwrap(),
        "fake loop should have seen ClearStatusSegment"
    );
    assert_eq!(result["ok"], true, "tool should return ok=true");
}

/// Register then clear a segment via the MCP wire — simulates the full
/// lifecycle.  Both tools must return `{ "ok": true }`.
///
/// This test does NOT inspect `AppState` directly; it drives the protocol
/// through the fake event loop just as the real app would.
#[tokio::test]
async fn register_then_clear_segment() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_lifecycle_seg.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone()).await.unwrap();

    // Fake event loop: handles two commands in sequence.
    let fake_loop = tokio::spawn(async move {
        // First command: RegisterStatusSegment
        let first_ok = if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::RegisterStatusSegment {
                view_id,
                segment_id,
                reply,
                ..
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(segment_id, "build_status");
                let _ = reply.send(Ok(()));
                true
            } else {
                false
            }
        } else {
            false
        };

        // Second command: ClearStatusSegment
        let second_ok = if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::ClearStatusSegment {
                view_id,
                segment_id,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(segment_id, "build_status");
                let _ = reply.send(Ok(()));
                true
            } else {
                false
            }
        } else {
            false
        };

        (first_ok, second_ok)
    });

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;

    let register_result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.register_status_segment",
        json!({
            "view_id": "perri",
            "segment_id": "build_status",
            "text": "passing",
            "color": "sage"
        }),
    ).await;

    let clear_result = call_tool(
        &mut reader,
        &mut writer,
        3,
        "nostromo.clear_status_segment",
        json!({
            "view_id": "perri",
            "segment_id": "build_status"
        }),
    ).await;

    let (first_ok, second_ok) = fake_loop.await.unwrap();
    assert!(first_ok, "fake loop should have seen RegisterStatusSegment");
    assert!(second_ok, "fake loop should have seen ClearStatusSegment");
    assert_eq!(register_result["ok"], true, "register tool should return ok=true");
    assert_eq!(clear_result["ok"], true, "clear tool should return ok=true");
}
