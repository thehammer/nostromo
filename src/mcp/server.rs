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

use std::collections::VecDeque;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::mcp::{state::McpSharedState, tools};

// ── constants ─────────────────────────────────────────────────────────────────

const MCP_PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "nostromo";

/// Hard cap on one newline-delimited frame. A longer frame is discarded up to
/// its newline and answered with a JSON-RPC error; it never closes the
/// connection.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

/// JSON-RPC error code for a tool the operator's policy withdraws from this
/// caller (W5 — curated-agent-views). In the implementation-defined server
/// range (-32000..-32099), deliberately *not* -32601 "Method not found" —
/// distinguishing a withdrawn tool from a typo'd one is a stated acceptance
/// criterion.
pub const TOOL_FORBIDDEN_CODE: i64 = -32001;

/// JSON-RPC error code for a request to write to, read from or close a
/// terminal: a tool name shaped like one, or a raw terminal frame on this
/// socket. Distinct from -32601 (no such method) and -32001 (withdrawn by
/// policy): the MCP surface can open a terminal and nothing else, and an
/// attempt at more is refused and audited, never "unknown".
pub const TERMINAL_FORBIDDEN_CODE: i64 = -32002;

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
                info!("MCP: accepted connection");
                let state = state.clone();
                tokio::spawn(async move {
                    serve_connection(stream, state).await;
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

/// Why a connection ended. Logged (with the pty id, never frame contents) on
/// every close.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CloseReason {
    /// The peer closed its end.
    PeerEof,
    /// Writing a response failed because the peer is gone.
    PeerGone,
    /// Reading from the socket failed.
    ReadError,
}

impl CloseReason {
    fn code(self) -> &'static str {
        match self {
            Self::PeerEof => "peer_eof",
            Self::PeerGone => "peer_gone",
            Self::ReadError => "read_error",
        }
    }
}

/// One frame read off the socket.
enum Frame {
    /// A complete line, newline removed. May be anything: UTF-8 or not, JSON
    /// or not.
    Line(Vec<u8>),
    /// A line longer than [`MAX_FRAME_BYTES`]; it was discarded unread.
    TooLong,
}

/// Counts this connection as one of its pty's live bridges until dropped.
struct BridgeGuard {
    state: McpSharedState,
    pty_id: String,
}

impl BridgeGuard {
    fn open(state: &McpSharedState, pty_id: &str) -> Option<Self> {
        if pty_id.is_empty() {
            return None;
        }
        state.bridge_opened(pty_id);
        Some(Self {
            state: state.clone(),
            pty_id: pty_id.to_owned(),
        })
    }
}

impl Drop for BridgeGuard {
    fn drop(&mut self) {
        self.state.bridge_closed(&self.pty_id);
    }
}

/// Read the next newline-terminated frame, buffering at most
/// [`MAX_FRAME_BYTES`]: a longer frame is skipped to its newline and reported
/// as [`Frame::TooLong`]. `None` at end of stream. A final frame with no
/// newline is still a frame.
async fn read_frame<R: AsyncBufRead + Unpin>(reader: &mut R) -> std::io::Result<Option<Frame>> {
    let mut buf: Vec<u8> = Vec::new();
    let mut too_long = false;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(if too_long {
                Some(Frame::TooLong)
            } else if buf.is_empty() {
                None
            } else {
                Some(Frame::Line(buf))
            });
        }
        let newline = available.iter().position(|b| *b == b'\n');
        let chunk = newline.unwrap_or(available.len());
        if !too_long {
            if buf.len() + chunk > MAX_FRAME_BYTES {
                too_long = true;
                buf = Vec::new();
            } else {
                buf.extend_from_slice(&available[..chunk]);
            }
        }
        reader.consume(chunk + usize::from(newline.is_some()));
        if newline.is_some() {
            return Ok(Some(if too_long {
                Frame::TooLong
            } else {
                Frame::Line(buf)
            }));
        }
    }
}

async fn serve_connection(stream: UnixStream, state: McpSharedState) {
    let mut pty_id: Option<String> = None;
    let reason = run_connection(stream, &state, &mut pty_id).await;
    info!(
        pty_id = pty_id.as_deref().unwrap_or(""),
        reason = reason.code(),
        "MCP connection closed"
    );
}

async fn run_connection(
    stream: UnixStream,
    state: &McpSharedState,
    pty_id_out: &mut Option<String>,
) -> CloseReason {
    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half);

    // Step 1: read the Hello frame. One that is missing, over-long, not UTF-8
    // or not JSON leaves the caller unidentified; it does not end the
    // connection.
    let hello = match read_frame(&mut reader).await {
        Ok(Some(Frame::Line(bytes))) => {
            serde_json::from_slice::<Value>(&bytes).unwrap_or(json!({}))
        }
        Ok(Some(Frame::TooLong)) => json!({}),
        Ok(None) => return CloseReason::PeerEof,
        Err(e) => {
            warn!("MCP: read Hello failed: {e}");
            return CloseReason::ReadError;
        }
    };
    let pty_id: Option<String> = hello
        .get("pty_id")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    *pty_id_out = pty_id.clone();

    debug!(pty_id = ?pty_id, "MCP: received Hello");
    let _bridge = pty_id
        .as_deref()
        .and_then(|id| BridgeGuard::open(state, id));
    let state = state.clone();

    // Step 2: JSON-RPC 2.0 loop.
    //
    // The socket is read by a task of its own and the frames come through a
    // channel, so a tool call that waits for a person can still see the
    // agent hang up (or cancel) while it waits.
    let (line_tx, mut lines) = mpsc::channel::<std::io::Result<Frame>>(LINE_QUEUE);
    let _reader = AbortOnDrop(tokio::spawn(async move {
        loop {
            match read_frame(&mut reader).await {
                Ok(None) => break, // EOF
                Ok(Some(frame)) => {
                    if line_tx.send(Ok(frame)).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    let _ = line_tx.send(Err(e)).await;
                    break;
                }
            }
        }
    }));
    // Frames that arrived while a call was running: served next, in order.
    let mut queued: VecDeque<Frame> = VecDeque::new();
    loop {
        let frame = match queued.pop_front() {
            Some(queued) => queued,
            None => match lines.recv().await {
                Some(Ok(frame)) => frame,
                Some(Err(e)) => {
                    warn!("MCP: read failed: {e}");
                    return CloseReason::ReadError;
                }
                None => return CloseReason::PeerEof,
            },
        };
        let line = match frame {
            Frame::Line(line) => line,
            Frame::TooLong => {
                warn!("MCP: frame over {MAX_FRAME_BYTES} bytes discarded");
                let err = json_rpc_error(None, -32600, "Invalid Request: frame too large");
                if !reply(&mut write_half, &err).await {
                    return CloseReason::PeerGone;
                }
                continue;
            }
        };
        let trimmed = line.trim_ascii();
        if trimmed.is_empty() {
            continue;
        }

        let Ok(text) = std::str::from_utf8(trimmed) else {
            warn!("MCP: frame is not valid UTF-8");
            let err = json_rpc_error(None, -32700, "Parse error: frame is not valid UTF-8");
            if !reply(&mut write_half, &err).await {
                return CloseReason::PeerGone;
            }
            continue;
        };
        let req: Value = match serde_json::from_str(text) {
            Ok(v) => v,
            Err(e) => {
                warn!("MCP: invalid JSON frame: {e}");
                let err = json_rpc_error(None, -32700, "Parse error");
                if !reply(&mut write_half, &err).await {
                    return CloseReason::PeerGone;
                }
                continue;
            }
        };
        if !req.is_object() {
            let err = json_rpc_error(None, -32600, "Invalid Request");
            if !reply(&mut write_half, &err).await {
                return CloseReason::PeerGone;
            }
            continue;
        }

        let id = req.get("id").cloned();

        if let Some(frame) = tools::terminal::terminal_frame(&req) {
            if let Some(daemon) = &state.daemon {
                daemon.terminals.audit_refusal(
                    pty_id.as_deref(),
                    &frame.verb,
                    &frame.name,
                    &frame.op.forbidden_code(),
                );
            }
            let err = json_rpc_error(
                id,
                TERMINAL_FORBIDDEN_CODE,
                &format!("{}: {}", frame.op.forbidden_code(), frame.name),
            );
            if !reply(&mut write_half, &err).await {
                return CloseReason::PeerGone;
            }
            continue;
        }

        let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");

        let response = match method {
            "initialize" => Some(handle_initialize(id, &req, &state, pty_id.as_deref())),
            "notifications/initialized" => None, // notification; no response
            "ping" => id.map(|id| json!({ "jsonrpc": "2.0", "id": id, "result": {} })),
            "tools/list" => Some(handle_tools_list(id, &state, pty_id.as_deref()).await),
            "tools/call" => {
                let name = req.pointer("/params/name").and_then(Value::as_str);
                let request_id = id.clone();
                let call = handle_tools_call(id, &req, &state, pty_id.as_deref());
                if name.is_some_and(tools::cancels_on_disconnect) {
                    match run_until_cancelled(call, request_id.as_ref(), &mut lines, &mut queued)
                        .await
                    {
                        CallEnd::Response(response) => Some(response),
                        // Cancelled by the client: no response is owed.
                        CallEnd::Cancelled => None,
                        // The caller hung up: the call was dropped, and with
                        // it whatever it was waiting for.
                        CallEnd::HungUp(reason) => return reason,
                    }
                } else {
                    Some(call.await)
                }
            }
            other => {
                debug!("MCP: unknown method {other:?}");
                id.map(|id| json_rpc_error(Some(id), -32601, "Method not found"))
            }
        };

        if let Some(resp) = response {
            if !reply(&mut write_half, &resp).await {
                return CloseReason::PeerGone;
            }
        }
    }
}

/// Frames read ahead of the one being served.
const LINE_QUEUE: usize = 64;

/// Stops its task when dropped.
struct AbortOnDrop(JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// How a call that was watched for hang-up and cancellation ended.
enum CallEnd {
    Response(Value),
    /// The client sent `notifications/cancelled` for this call.
    Cancelled,
    /// The client closed its end, or reading from it failed.
    HungUp(CloseReason),
}

/// Run `call`, but drop it if the caller closes its end or cancels it first.
/// Nothing else reads the socket while a tool runs, so without this a call that
/// waits for a person (a remote shell request) would outlive the agent that
/// made it. Other frames that arrive meanwhile are queued for the loop.
async fn run_until_cancelled<F>(
    call: F,
    request_id: Option<&Value>,
    lines: &mut mpsc::Receiver<std::io::Result<Frame>>,
    queued: &mut VecDeque<Frame>,
) -> CallEnd
where
    F: std::future::Future<Output = Value>,
{
    tokio::pin!(call);
    loop {
        tokio::select! {
            response = &mut call => return CallEnd::Response(response),
            // Stop reading ahead once the queue is full: the channel's own
            // bound then holds the client back.
            read = lines.recv(), if queued.len() < LINE_QUEUE => match read {
                None => return CallEnd::HungUp(CloseReason::PeerEof),
                Some(Err(_)) => return CallEnd::HungUp(CloseReason::ReadError),
                Some(Ok(frame)) if cancels(&frame, request_id) => return CallEnd::Cancelled,
                Some(Ok(frame)) => queued.push_back(frame),
            },
        }
    }
}

/// Is `frame` `notifications/cancelled` for the request `request_id`?
fn cancels(frame: &Frame, request_id: Option<&Value>) -> bool {
    let (Some(request_id), Frame::Line(bytes)) = (request_id, frame) else {
        return false;
    };
    let Ok(frame) = serde_json::from_slice::<Value>(bytes.trim_ascii()) else {
        return false;
    };
    frame.get("method").and_then(Value::as_str) == Some("notifications/cancelled")
        && frame.pointer("/params/requestId") == Some(request_id)
}

// ── method handlers ───────────────────────────────────────────────────────────

fn handle_initialize(
    id: Option<Value>,
    req: &Value,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> Value {
    let client_version = req
        .pointer("/params/protocolVersion")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");

    debug!("MCP: initialize from client protocol {client_version}");

    let id = id.unwrap_or(json!(null));
    let mut response = json!({
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
    });
    if let Some(text) = initialize_instructions(state, pty_id) {
        response["result"]["instructions"] = json!(text);
    }
    response
}

/// The `instructions` for this connection: only for a session the daemon
/// spawned (its Hello `pty_id` is a focus tag the daemon knows), and never for
/// the picks session, which cannot call the tracker. Huey's curating session
/// gets [`crate::mcp::instructions::HUEY_RUN_NOTE`]. Everyone else gets today's
/// response unchanged.
fn initialize_instructions(state: &McpSharedState, pty_id: Option<&str>) -> Option<String> {
    // Huey's curating session gets a one-line note instead of the tracker
    // paragraph (it is never in the focus registry).
    if pty_id == Some(crate::huey::curate::HUEY_RUN_TAG) {
        return Some(crate::mcp::instructions::HUEY_RUN_NOTE.to_string());
    }
    let tag = pty_id.filter(|t| !t.is_empty() && *t != crate::data::work::picks::PICKS_TAG)?;
    let daemon = state.daemon.as_ref()?;
    let known = daemon
        .session_mgr
        .lock()
        .ok()?
        .focus_registry()
        .iter()
        .any(|f| f.tag == tag);
    if !known {
        return None;
    }
    let topic = daemon.tracker.bound_topic(tag);
    Some(crate::mcp::instructions::nostromo_instructions(
        topic.as_deref(),
    ))
}

/// `tools/list`, narrowed to what this caller may see (W5 —
/// curated-agent-views, B8/D7).
///
/// Takes `state` and `pty_id` — both already in scope at the call site — so the
/// operator's tool policy can be applied per caller. With no policy armed, the
/// shipped default, this is byte-for-byte the list it always returned.
async fn handle_tools_list(
    id: Option<Value>,
    state: &McpSharedState,
    pty_id: Option<&str>,
) -> Value {
    let id = id.unwrap_or(json!(null));
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "tools": tools::tool_descriptors_for(state, pty_id).await
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
        // A distinct JSON-RPC code from "Method not found", because the two
        // mean different things to the caller: the tool exists and works, but
        // the operator's policy withdraws it from this agent.
        tools::ToolResult::TerminalForbidden { op, name } => json_rpc_error(
            Some(id),
            TERMINAL_FORBIDDEN_CODE,
            &format!("{}: {name}", op.forbidden_code()),
        ),
        tools::ToolResult::Forbidden(n) => json_rpc_error(
            Some(id),
            TOOL_FORBIDDEN_CODE,
            &format!("Tool not available to this caller: {n}"),
        ),
    }
}

// ── framing helpers ───────────────────────────────────────────────────────────

/// Write a JSON value as a newline-terminated frame.
async fn write_frame<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    value: &Value,
) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    bytes.push(b'\n');
    writer.write_all(&bytes).await
}

/// Write one response. Returns false only when the peer is really gone
/// (`BrokenPipe`, `ConnectionReset`, `UnexpectedEof`); any other write error
/// is logged and the connection carries on.
async fn reply<W: AsyncWriteExt + Unpin>(writer: &mut W, value: &Value) -> bool {
    match write_frame(writer, value).await {
        Ok(()) => true,
        Err(e) if peer_is_gone(&e) => false,
        Err(e) => {
            warn!("MCP: response write failed, connection kept: {e}");
            true
        }
    }
}

fn peer_is_gone(e: &std::io::Error) -> bool {
    use std::io::ErrorKind::{BrokenPipe, ConnectionReset, UnexpectedEof};
    matches!(e.kind(), BrokenPipe | ConnectionReset | UnexpectedEof)
}

fn json_rpc_error(id: Option<Value>, code: i64, message: &str) -> Value {
    let id = id.unwrap_or(json!(null));
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}
