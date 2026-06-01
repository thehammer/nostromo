//! Nostromo in-process MCP server.
//!
//! ## Transport
//!
//! Binds a Unix domain socket.  Each accepted connection is served by an
//! independent task running a hand-rolled JSON-RPC 2.0 / MCP protocol loop
//! (newline-delimited frames).
//!
//! rmcp 1.7.0 was considered but requires `schemars ^1.1.0` (incompatible
//! with the project's existing `schemars 0.8` usage) and its transport
//! coupling made the Hello-frame identification approach awkward.  The
//! hand-rolled loop covers the four MCP messages needed by phase 1
//! (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`)
//! and is ~250 lines.  Phases 2–4 can extend it in place or migrate to a
//! proper SDK once the dependency conflict is resolved.
//!
//! ## Identification
//!
//! Before any MCP framing the client (the `nostromo-mcp-bridge` binary) sends
//! a one-line JSON `Hello` frame:
//!
//! ```json
//! {"type":"hello","pty_id":"<uuid>"}
//! ```
//!
//! The server reads this first line, extracts the `pty_id`, and uses it to
//! look up the caller in `McpSharedState::ptys` for every subsequent
//! `tools/call`.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::mcp::{state::McpSharedState, tools};

// ── constants ─────────────────────────────────────────────────────────────────

const MCP_PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "nostromo";

// ── server handle ─────────────────────────────────────────────────────────────

/// Handle to the running MCP server.  Drop to request shutdown.
pub struct McpServer {
    socket_path: PathBuf,
    _accept_task: JoinHandle<()>,
}

impl McpServer {
    /// Bind the MCP server to `path`.
    ///
    /// Removes any stale socket file, creates parent directories, then spawns
    /// the accept task.  Errors during bind are returned so callers can log a
    /// warning and continue without MCP.
    pub async fn bind(path: PathBuf, state: McpSharedState) -> Result<Self> {
        // Remove stale socket.
        let _ = tokio::fs::remove_file(&path).await;

        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .with_context(|| format!("create MCP socket directory {:?}", parent))?;
        }

        let listener =
            UnixListener::bind(&path).with_context(|| format!("bind MCP socket at {:?}", path))?;

        info!(socket = ?path, "MCP server listening");

        let accept_task = tokio::spawn(accept_loop(listener, state));

        Ok(Self {
            socket_path: path,
            _accept_task: accept_task,
        })
    }

    /// Path of the bound socket.
    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Graceful shutdown — removes the socket file and drops the accept task.
    pub async fn shutdown(self) {
        let _ = tokio::fs::remove_file(&self.socket_path).await;
        self._accept_task.abort();
    }
}

// ── accept loop ───────────────────────────────────────────────────────────────

async fn accept_loop(listener: UnixListener, state: McpSharedState) {
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                debug!("MCP: accepted connection");
                let state = state.clone();
                tokio::spawn(async move {
                    if let Err(e) = serve_connection(stream, state).await {
                        debug!("MCP connection closed: {e:#}");
                    }
                });
            }
            Err(e) => {
                warn!("MCP accept error: {e}");
                break;
            }
        }
    }
}

// ── connection handler ────────────────────────────────────────────────────────

async fn serve_connection(stream: UnixStream, state: McpSharedState) -> Result<()> {
    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half);

    // Step 1: read the Hello frame.
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .await
        .context("read Hello frame")?;

    let hello: Value = serde_json::from_str(line.trim()).unwrap_or(json!({}));
    let pty_id: Option<String> = hello
        .get("pty_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    debug!(pty_id = ?pty_id, "MCP: received Hello");

    // Step 2: JSON-RPC 2.0 loop.
    loop {
        line.clear();
        let n = reader
            .read_line(&mut line)
            .await
            .context("read JSON-RPC frame")?;
        if n == 0 {
            break; // EOF
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let req: Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(e) => {
                warn!("MCP: invalid JSON frame: {e}");
                let err = json_rpc_error(None, -32700, "Parse error");
                write_frame(&mut write_half, &err).await?;
                continue;
            }
        };

        let id = req.get("id").cloned();
        let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");

        let response = match method {
            "initialize" => Some(handle_initialize(id, &req)),
            "notifications/initialized" => None, // notification; no response
            "ping" => id.map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": {} })),
            "tools/list" => Some(handle_tools_list(id)),
            "tools/call" => Some(handle_tools_call(id, &req, &state, pty_id.as_deref()).await),
            other => {
                debug!("MCP: unknown method {other:?}");
                id.map(|id| json_rpc_error(Some(id), -32601, "Method not found"))
            }
        };

        if let Some(resp) = response {
            write_frame(&mut write_half, &resp).await?;
        }
    }

    Ok(())
}

// ── method handlers ───────────────────────────────────────────────────────────

fn handle_initialize(id: Option<Value>, req: &Value) -> Value {
    let client_version = req
        .pointer("/params/protocolVersion")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    debug!("MCP: initialize from client protocol {client_version}");

    let id = id.unwrap_or(json!(null));
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "protocolVersion": MCP_PROTOCOL_VERSION,
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": SERVER_NAME,
                "version": env!("CARGO_PKG_VERSION")
            }
        }
    })
}

fn handle_tools_list(id: Option<Value>) -> Value {
    let id = id.unwrap_or(json!(null));
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "tools": tools::tool_descriptors()
        }
    })
}

async fn handle_tools_call(
    id: Option<Value>,
    req: &Value,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> Value {
    let id = id.unwrap_or(json!(null));
    let name = req
        .pointer("/params/name")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let arguments = req.pointer("/params/arguments");

    debug!(tool = name, "MCP: tools/call");

    match tools::dispatch(name, arguments, state, pty_id).await {
        tools::ToolResult::Ok(content) => {
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": { "content": content }
            })
        }
        tools::ToolResult::UnknownTool(n) => {
            json_rpc_error(Some(id), -32601, &format!("Unknown tool: {n}"))
        }
    }
}

// ── framing helpers ───────────────────────────────────────────────────────────

/// Write a JSON value as a newline-terminated frame.
async fn write_frame<W: AsyncWriteExt + Unpin>(writer: &mut W, value: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(value).context("serialise JSON-RPC frame")?;
    bytes.push(b'\n');
    writer
        .write_all(&bytes)
        .await
        .context("write JSON-RPC frame")?;
    Ok(())
}

fn json_rpc_error(id: Option<Value>, code: i64, message: &str) -> Value {
    let id = id.unwrap_or(json!(null));
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}
