//! The five tools that only the removed Rust TUI could honour are gone from
//! the daemon-hosted MCP surface: `tools/list` does not advertise them and
//! `tools/call` answers them like any other name the server has never heard
//! of (JSON-RPC -32601 "Unknown tool: <name>").
//!
//! The network-driven-session variant lives in `tests/ipc_peer_gating.rs`
//! (`removed_tools_are_unknown_even_to_a_network_driven_session`), which owns
//! the rig that builds one.

use std::ffi::OsString;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::tool_descriptors;
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState, PerriDaemonState, TicketRegistryState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

const REMOVED_TOOLS: [&str; 5] = [
    "nostromo.notify",
    "nostromo.register_status_segment",
    "nostromo.clear_status_segment",
    "nostromo.switch_active_view",
    "nostromo.set_pane_focus",
];

// `tool_policy::load()` resolves `~/.nostromo` from `$HOME` on every call, and
// there is a real daemon's directory there: point `$HOME` at a tempdir for the
// whole test, serialised by a process-wide lock.
static HOME_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

struct HomeOverride {
    _lock: MutexGuard<'static, ()>,
    _dir: TempDir,
    previous: Option<OsString>,
}

impl HomeOverride {
    fn new() -> Self {
        let lock = HOME_LOCK
            .get_or_init(|| Mutex::new(()))
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let dir = TempDir::new().expect("tempdir for $HOME override");
        std::fs::create_dir_all(dir.path().join(".nostromo")).unwrap();
        let previous = std::env::var_os("HOME");
        std::env::set_var("HOME", dir.path());
        Self { _lock: lock, _dir: dir, previous }
    }
}

impl Drop for HomeOverride {
    fn drop(&mut self) {
        match self.previous.take() {
            Some(v) => std::env::set_var("HOME", v),
            None => std::env::remove_var("HOME"),
        }
    }
}

fn make_daemon_state(dir: &TempDir) -> McpSharedState {
    let pane_registry =
        Arc::new(Mutex::new(PaneRegistry::with_store_path(dir.path().join("panes.json"))));
    let session_mgr =
        Arc::new(Mutex::new(SessionManager::with_store_path(dir.path().join("sessions.json"))));
    let (broadcast_tx, _rx) = broadcast::channel::<ServerMsg>(64);
    McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
        tickets: TicketRegistryState::default(),
    })
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
    let _ = read_frame(&mut reader).await;
    (reader, write_half)
}

#[test]
fn the_static_tool_catalogue_has_none_of_the_removed_tools() {
    let descriptors = tool_descriptors();
    let names: Vec<&str> = descriptors.iter().filter_map(|t| t["name"].as_str()).collect();
    for removed in REMOVED_TOOLS {
        assert!(!names.contains(&removed), "{removed} must not be in the catalogue");
    }
}

#[tokio::test]
async fn a_daemon_hosted_tools_list_has_none_of_the_removed_tools() {
    let _home = HomeOverride::new();
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), make_daemon_state(&dir)).await.unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "cody-x").await;

    write_frame(&mut writer, &json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" })).await;
    let resp = read_frame(&mut reader).await;
    let tools = resp["result"]["tools"].as_array().expect("a tools array");
    let names: Vec<&str> = tools.iter().filter_map(|t| t["name"].as_str()).collect();
    assert!(names.contains(&"nostromo.get_self"), "control: the list is populated: {names:?}");
    for removed in REMOVED_TOOLS {
        assert!(!names.contains(&removed), "{removed} must not be listed");
    }
}

#[tokio::test]
async fn calling_a_removed_tool_is_an_unknown_tool_error() {
    let _home = HomeOverride::new();
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-daemon.sock");
    let _server = McpServer::bind(socket_path.clone(), make_daemon_state(&dir)).await.unwrap();
    let (mut reader, mut writer) = connect(&socket_path, "cody-x").await;

    for (i, removed) in REMOVED_TOOLS.iter().enumerate() {
        write_frame(
            &mut writer,
            &json!({
                "jsonrpc":"2.0","id": 10 + i as i64,"method":"tools/call",
                "params":{"name": removed, "arguments": {}}
            }),
        )
        .await;
        let resp = read_frame(&mut reader).await;
        assert_eq!(resp["error"]["code"], -32601, "{removed}: {resp}");
        assert_eq!(resp["error"]["message"], format!("Unknown tool: {removed}"), "{removed}: {resp}");
        assert!(resp.get("result").is_none(), "{removed} must not succeed: {resp}");
    }
}
