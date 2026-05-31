//! Integration tests for Phase 3 MCP mutation tools.
//!
//! Each test:
//! 1. Constructs an `McpSharedState` with a real `mpsc` channel.
//! 2. Spawns an `McpServer` on a temp-dir socket.
//! 3. Spawns a "fake event loop" task that drains `AppEvent::McpCommand` values
//!    and replies with stubbed results.
//! 4. Calls the mutating tool through a real MCP client connection.
//! 5. Asserts the fake loop received the expected command and the tool
//!    returned the expected reply.

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

/// Complete MCP initialize handshake and return a connected (reader, writer) pair.
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

/// `nostromo.switch_active_view` → SwitchActiveView command is dispatched;
/// fake loop replies Ok; tool returns `{ "ok": true }`.
#[tokio::test]
async fn switch_active_view_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_switch.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    // Fake event loop: drain one command and reply Ok.
    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::SwitchActiveView { view_id, reply } = *cmd {
                assert_eq!(view_id, "mother");
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
        "nostromo.switch_active_view",
        json!({ "view_id": "mother" }),
    )
    .await;

    assert!(
        fake_loop.await.unwrap(),
        "fake loop should have seen SwitchActiveView"
    );
    assert_eq!(result["ok"], true, "tool should return ok=true");
}

/// `nostromo.set_pane_focus` dispatches SetPaneFocus.
#[tokio::test]
async fn set_pane_focus_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_focus.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::SetPaneFocus {
                view_id,
                pane_id,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(pane_id, "diff");
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
        "nostromo.set_pane_focus",
        json!({ "view_id": "perri", "pane_id": "diff" }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `nostromo.set_pane_content` with text payload dispatches SetPaneContent.
#[tokio::test]
async fn set_pane_content_text_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_content.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::SetPaneContent {
                view_id,
                pane_id,
                content,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert_eq!(pane_id, "diff");
                if let nostromo::mcp::PaneContent::Text(t) = content {
                    assert_eq!(t, "diff --git a/foo b/foo");
                }
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
        "nostromo.set_pane_content",
        json!({
            "view_id": "perri",
            "pane_id": "diff",
            "content": { "type": "text", "text": "diff --git a/foo b/foo" }
        }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `nostromo.set_pane_layout` dispatches SetPaneLayout with the ratios object.
#[tokio::test]
async fn set_pane_layout_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_layout.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::SetPaneLayout {
                view_id,
                ratios,
                reply,
            } = *cmd
            {
                assert_eq!(view_id, "perri");
                assert!((ratios["top_row"].as_f64().unwrap() - 0.6).abs() < 0.001);
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
        "nostromo.set_pane_layout",
        json!({ "view_id": "perri", "ratios": { "top_row": 0.6, "queue": 0.35 } }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `perri.load_pr` dispatches PerriLoadPr with the correct fields.
#[tokio::test]
async fn perri_load_pr_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_load_pr.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::PerriLoadPr {
                number,
                repo,
                highlights,
                reply,
            } = *cmd
            {
                assert_eq!(number, 42);
                assert_eq!(repo, "thehammer/nostromo");
                assert_eq!(highlights.as_deref(), Some("check the auth flow"));
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
        "perri.load_pr",
        json!({ "number": 42, "repo": "thehammer/nostromo", "highlights": "check the auth flow" }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `perri.clear_current_pr` dispatches PerriClearCurrentPr.
#[tokio::test]
async fn perri_clear_current_pr_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_clear_pr.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::PerriClearCurrentPr { reply } = *cmd {
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
        "perri.clear_current_pr",
        json!({}),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `perri.set_selected_index` dispatches SetPerriSelectedIndex.
#[tokio::test]
async fn perri_set_selected_index_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_sel_idx.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::SetPerriSelectedIndex { index, reply } = *cmd {
                assert_eq!(index, 3);
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
        "perri.set_selected_index",
        json!({ "index": 3 }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `mother.enqueue_job` dispatches MotherEnqueue with the plan_path.
#[tokio::test]
async fn mother_enqueue_job_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_enqueue.sock");
    let plan_path = dir.path().join("plan.md");
    std::fs::write(&plan_path, b"# Test plan").unwrap();

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let plan_path_clone = plan_path.clone();
    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::MotherEnqueue { plan_path, reply } = *cmd {
                assert_eq!(plan_path, plan_path_clone);
                let _ = reply.send(Ok(nostromo::mcp::command::MotherJobLite {
                    id: "test-job-id".into(),
                    title: "Test plan".into(),
                    status: "queued".into(),
                }));
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
        "mother.enqueue_job",
        json!({ "plan_path": plan_path.to_str().unwrap() }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["id"], "test-job-id");
    assert_eq!(result["status"], "queued");
}

/// `mother.cancel_job` dispatches MotherCancel.
#[tokio::test]
async fn mother_cancel_job_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_cancel.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::MotherCancel { job_id, reply } = *cmd {
                assert_eq!(job_id, "abc-123");
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
        "mother.cancel_job",
        json!({ "id": "abc-123" }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// `mother.resume_job` dispatches MotherResume with the answer.
#[tokio::test]
async fn mother_resume_job_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_resume.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::MotherResume {
                job_id,
                answer,
                reply,
            } = *cmd
            {
                assert_eq!(job_id, "def-456");
                assert_eq!(answer, "yes, proceed with the migration");
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
        "mother.resume_job",
        json!({ "id": "def-456", "answer": "yes, proceed with the migration" }),
    )
    .await;

    assert!(fake_loop.await.unwrap());
    assert_eq!(result["ok"], true);
}

/// Tool returns stable error code when the event loop is closed.
#[tokio::test]
async fn switch_active_view_returns_error_on_closed_channel() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_closed.sock");

    // Drop the receiver immediately so the channel is closed.
    let (tx, rx) = mpsc::unbounded_channel::<AppEvent>();
    drop(rx);
    let state = Arc::new(McpSharedState::for_test(tx));
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let (mut reader, mut writer) = mcp_connect(&socket_path).await;
    let result = call_tool(
        &mut reader,
        &mut writer,
        2,
        "nostromo.switch_active_view",
        json!({ "view_id": "fred" }),
    )
    .await;

    assert!(result.get("error").is_some(), "should return error");
    // Could be event_loop_closed or event_loop_timeout — both are acceptable.
    let err = result["error"].as_str().unwrap();
    assert!(
        err == "event_loop_closed" || err == "event_loop_timeout",
        "unexpected error: {err}"
    );
}

/// `mother.retry_job` dispatches MotherRetry with the job id.
#[tokio::test]
async fn mother_retry_job_dispatches_command() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp_retry.sock");

    let (state, mut rx) = make_state_with_channel().await;
    let _server = McpServer::bind(socket_path.clone(), (*state).clone())
        .await
        .unwrap();

    let fake_loop = tokio::spawn(async move {
        if let Some(AppEvent::McpCommand(cmd)) = rx.recv().await {
            if let nostromo::mcp::McpCommand::MotherRetry { job_id, reply } = *cmd {
                assert_eq!(job_id, "retry-job-xyz");
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
        "mother.retry_job",
        json!({ "id": "retry-job-xyz" }),
    )
    .await;

    assert!(
        fake_loop.await.unwrap(),
        "fake loop should have seen MotherRetry"
    );
    assert_eq!(result["ok"], true);
}
