//! The mother / set_pane / perri mutating tools need `nostromd`: against an
//! `McpSharedState` that is not daemon-hosted they answer
//! `{"error": "not_supported", "detail": "requires nostromd"}`.
//!
//! Each test builds a non-daemon state, serves it on a temp-dir socket, calls
//! the tool through a real MCP client connection with arguments that pass
//! validation, and asserts the reply.

use std::sync::Arc;

use nostromo::mcp::{McpServer, McpSharedState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

// ── helpers ───────────────────────────────────────────────────────────────────

fn make_state() -> Arc<McpSharedState> {
    Arc::new(McpSharedState::for_test())
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

/// Complete MCP initialize handshake and return a connected (reader, writer) pair.
async fn mcp_connect(
    socket_path: &std::path::Path,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    mcp_connect_as(socket_path, "").await
}

/// Complete the MCP handshake as a named caller — the `Hello` frame's
/// `pty_id`, which in the daemon *is* the focus tag. `mcp_connect` is just
/// this with `pty_id: ""` (an unidentified caller), kept so existing call
/// sites don't need touching.
async fn mcp_connect_as(
    socket_path: &std::path::Path,
    pty_id: &str,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    // Hello
    write_frame(&mut write_half, &json!({"type":"hello","pty_id":pty_id})).await;

    // Initialize
    write_frame(&mut write_half, &json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "0.1"}}
    })).await;
    let _init_resp = read_frame(&mut reader).await;

    (reader, write_half)
}

/// `tools/list`, parsed to the plain `result.tools` array.
#[allow(dead_code)]
async fn list_tools(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: u64,
) -> Value {
    write_frame(
        writer,
        &json!({ "jsonrpc": "2.0", "id": id, "method": "tools/list" }),
    )
    .await;
    let resp = read_frame(reader).await;
    resp["result"]["tools"].clone()
}

/// Call a tool and parse the text content of the first content item.
async fn call_tool(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    id: u64,
    name: &str,
    args: Value,
) -> Value {
    write_frame(
        writer,
        &json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": { "name": name, "arguments": args }
        }),
    )
    .await;
    let resp = read_frame(reader).await;
    let text = resp["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or("{}");
    serde_json::from_str(text).unwrap_or_else(|_| json!({"raw": text}))
}

// ── tests ─────────────────────────────────────────────────────────────────────

async fn assert_not_supported(tool: &str, args: Value) {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_not_supported.sock");
    let state = make_state();
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;
    let result = call_tool(&mut reader, &mut writer, 2, tool, args).await;

    assert_eq!(
        result,
        json!({ "error": "not_supported", "detail": "requires nostromd" }),
        "{tool}"
    );
}

#[tokio::test]
async fn mother_enqueue_job_is_not_supported_without_nostromd() {
    let dir = TempDir::new().unwrap();
    let plan_path = dir.path().join("plan.md");
    std::fs::write(&plan_path, b"# Test plan").unwrap();
    assert_not_supported(
        "mother.enqueue_job",
        json!({ "plan_path": plan_path.to_str().unwrap(), "repo": "acme/web", "branch": "feat/x" }),
    )
    .await;
}

#[tokio::test]
async fn mother_cancel_job_is_not_supported_without_nostromd() {
    assert_not_supported("mother.cancel_job", json!({ "id": "abc-123" })).await;
}

#[tokio::test]
async fn mother_archive_job_is_not_supported_without_nostromd() {
    assert_not_supported("mother.archive_job", json!({ "id": "abc-123" })).await;
}

#[tokio::test]
async fn mother_retry_job_is_not_supported_without_nostromd() {
    assert_not_supported("mother.retry_job", json!({ "id": "retry-job-xyz" })).await;
}

#[tokio::test]
async fn mother_resume_job_is_not_supported_without_nostromd() {
    assert_not_supported(
        "mother.resume_job",
        json!({ "id": "def-456", "answer": "yes, proceed with the migration" }),
    )
    .await;
}

#[tokio::test]
async fn set_pane_content_is_not_supported_without_nostromd() {
    assert_not_supported(
        "nostromo.set_pane_content",
        json!({
            "view_id": "perri",
            "pane_id": "diff",
            "content": { "type": "text", "text": "diff --git a/foo b/foo" }
        }),
    )
    .await;
}

#[tokio::test]
async fn set_pane_layout_is_not_supported_without_nostromd() {
    assert_not_supported(
        "nostromo.set_pane_layout",
        json!({ "view_id": "perri", "ratios": { "top_row": 0.6, "queue": 0.35 } }),
    )
    .await;
}

#[tokio::test]
async fn perri_load_pr_is_not_supported_without_nostromd() {
    assert_not_supported(
        "perri.load_pr",
        json!({ "number": 42, "repo": "thehammer/nostromo", "highlights": "check the auth flow" }),
    )
    .await;
}

#[tokio::test]
async fn perri_clear_current_pr_is_not_supported_without_nostromd() {
    assert_not_supported("perri.clear_current_pr", json!({})).await;
}

#[tokio::test]
async fn perri_set_selected_index_is_not_supported_without_nostromd() {
    assert_not_supported("perri.set_selected_index", json!({ "index": 3 })).await;
}

#[tokio::test]
async fn perri_get_selected_index_is_not_supported_without_nostromd() {
    assert_not_supported("perri.get_selected_index", json!({})).await;
}
