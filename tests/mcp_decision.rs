//! Socket-level integration tests for the daemon-hosted `nostromo.ask_decision`
//! MCP tool (W6: daemon-driven decision modals).
//!
//! Mirrors `tests/mcp_daemon_panes.rs`'s harness (a real `McpServer` bound to a
//! temp-dir Unix socket, backed by a daemon-hosted `McpSharedState`), extended
//! with the `decisions: Arc<Mutex<DecisionRegistry>>` field `DaemonMcpBackend`
//! is expected to gain for this feature.
//!
//! `nostromo.ask_decision` blocks until answered/timed out, so a test can't
//! simply await the tool call and then answer on the same connection — that
//! would deadlock. Per the spec, tests instead reach into the shared
//! `DecisionRegistry` directly (it's an `Arc<Mutex<..>>` the test harness
//! constructs and owns alongside the daemon backend) from a concurrent task,
//! rather than standing up a second raw-IPC socket connection just to send a
//! `ClientMsg::DecisionAnswer`.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::decisions::DecisionRegistry;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{ClientMsg, DecisionChoice, DecisionResolution, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::{DaemonMcpBackend, McpServer, McpSharedState};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::broadcast;

// ── harness ───────────────────────────────────────────────────────────────────

struct Harness {
    state: McpSharedState,
    decisions: Arc<Mutex<DecisionRegistry>>,
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
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx,
        perri: nostromo::mcp::PerriDaemonState::default(),
        decisions: decisions.clone(),
        tickets: Default::default(),
    };
    Harness {
        state: McpSharedState::for_daemon(backend),
        decisions,
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

/// Connect, send Hello with `pty_id` as the caller's identity (so
/// `ask_decision` can resolve its own focus tag when `view_id` is omitted),
/// and complete `initialize`.
async fn connect(
    socket_path: &std::path::Path,
    pty_id: &str,
) -> (
    BufReader<tokio::net::unix::OwnedReadHalf>,
    tokio::net::unix::OwnedWriteHalf,
) {
    let stream = UnixStream::connect(socket_path).await.unwrap();
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    write_frame(&mut write_half, &json!({"type":"hello","pty_id": pty_id})).await;
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
async fn call_tool(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
    writer: &mut tokio::net::unix::OwnedWriteHalf,
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

fn two_choices() -> Value {
    json!([
        {"id": "approve", "label": "Approve"},
        {"id": "reject", "label": "Reject"},
    ])
}

/// Poll `active_request_id(tag)` until it's `Some`, so tests don't race the
/// spawned tool call's own registration into the registry. Bounded by a short
/// real sleep loop — this is a socket-level integration test, not a unit test.
async fn wait_for_active_request(decisions: &Arc<Mutex<DecisionRegistry>>, tag: &str) -> String {
    for _ in 0..50 {
        if let Some(id) = decisions.lock().unwrap().active_request_id(tag) {
            return id;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("no active decision request appeared for tag {tag} within the wait window");
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// A call with >= 2 choices, answered with a valid choice_id, returns
/// `{"ok": true, "choice_id": "<that id>"}`.
#[tokio::test]
async fn ask_decision_answered_with_a_valid_choice_returns_ok_and_the_chosen_choice_id() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let call = tokio::spawn(async move {
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        )
        .await
    });

    let request_id = wait_for_active_request(&harness.decisions, "perri").await;
    let outcome = harness
        .decisions
        .lock()
        .unwrap()
        .answer(&request_id, Some("approve".into()));
    // Sanity: the answer itself must have been accepted (not UnknownRequest).
    match outcome {
        nostromo::ipc::decisions::AnswerOutcome::Answered { .. } => {}
        _ => panic!("expected the direct registry answer to succeed"),
    }

    let result = call.await.unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(result["choice_id"], "approve");
}

/// A call answered with `choice_id: null` (dismissed) returns
/// `{"ok": true, "outcome": "dismissed"}`.
#[tokio::test]
async fn ask_decision_dismissed_returns_ok_with_dismissed_outcome() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let call = tokio::spawn(async move {
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        )
        .await
    });

    let request_id = wait_for_active_request(&harness.decisions, "perri").await;
    harness.decisions.lock().unwrap().answer(&request_id, None);

    let result = call.await.unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(result["outcome"], "dismissed");
}

/// A call with fewer than 2 choices returns `{"error": "invalid_args", ...}`
/// immediately — it must not block waiting for an answer that will never come.
#[tokio::test]
async fn ask_decision_with_fewer_than_two_choices_returns_invalid_args_without_blocking() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": [{"id": "approve", "label": "Approve"}] }),
        ),
    )
    .await
    .expect("a validation failure must return fast, not block");

    assert_eq!(result["error"], "invalid_args");
}

/// Two choices sharing the same `id` returns `{"error": "invalid_args", ...}`.
#[tokio::test]
async fn ask_decision_with_duplicate_choice_ids_returns_invalid_args() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({
                "prompt": "Ship it?",
                "choices": [
                    {"id": "approve", "label": "Approve"},
                    {"id": "approve", "label": "Also approve, somehow"},
                ]
            }),
        ),
    )
    .await
    .expect("a validation failure must return fast, not block");

    assert_eq!(result["error"], "invalid_args");
}

/// A call made while NO client is subscribed to `Topic::Decision` returns
/// `{"error": "no_operator"}` immediately — it must not wait anywhere near a
/// real timeout window before giving up.
#[tokio::test]
async fn ask_decision_with_no_operator_subscribed_returns_no_operator_without_blocking() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    // Deliberately do NOT add_operator — the registry has zero subscribers.
    let harness = make_daemon_state();
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        ),
    )
    .await
    .expect("no-operator must fail fast, nowhere near the default answer timeout");

    assert_eq!(result["error"], "no_operator");
}

/// A second `ask_decision` call for the same tag while the first is still
/// outstanding is queued, not answered immediately — and both are eventually
/// answered (PRD: "a second decision requested while a modal is open queues
/// rather than replacing or stacking, and both are eventually answered").
#[tokio::test]
async fn a_second_ask_decision_call_for_the_same_tag_queues_and_both_are_eventually_answered() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader_a, mut writer_a) = connect(&socket_path, "perri").await;
    let (mut reader_b, mut writer_b) = connect(&socket_path, "perri").await;

    let call_a = tokio::spawn(async move {
        call_tool(
            &mut reader_a,
            &mut writer_a,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "A?", "choices": two_choices() }),
        )
        .await
    });
    let a_id = wait_for_active_request(&harness.decisions, "perri").await;

    let call_b = tokio::spawn(async move {
        call_tool(
            &mut reader_b,
            &mut writer_b,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "B?", "choices": two_choices() }),
        )
        .await
    });

    // Give B a moment to register itself, then assert it queued rather than
    // replacing/stacking A's active slot.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        harness.decisions.lock().unwrap().queued_count("perri"),
        1,
        "B must queue behind A, not become active immediately"
    );
    assert_eq!(
        harness.decisions.lock().unwrap().active_request_id("perri"),
        Some(a_id.clone()),
        "A must remain the active request while B is queued"
    );

    // Answer A; B must be promoted to active.
    harness
        .decisions
        .lock()
        .unwrap()
        .answer(&a_id, Some("approve".into()));

    let b_id = wait_for_active_request(&harness.decisions, "perri").await;
    assert_ne!(b_id, a_id, "B's promoted request_id must differ from A's");

    harness
        .decisions
        .lock()
        .unwrap()
        .answer(&b_id, Some("reject".into()));

    let result_a = call_a.await.unwrap();
    let result_b = call_b.await.unwrap();
    assert_eq!(result_a["ok"], true);
    assert_eq!(result_a["choice_id"], "approve");
    assert_eq!(result_b["ok"], true);
    assert_eq!(result_b["choice_id"], "reject");
}

/// A timed-out call (short `timeout_secs`, never answered) returns
/// `{"error": "timeout"}`.
#[tokio::test]
async fn ask_decision_that_times_out_returns_a_timeout_error() {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("mcp-decision.sock");
    let harness = make_daemon_state();
    harness
        .decisions
        .lock()
        .unwrap()
        .add_operator("operator-conn");
    let _server = McpServer::bind(socket_path.clone(), harness.state.clone())
        .await
        .expect("server should bind");

    let (mut reader, mut writer) = connect(&socket_path, "perri").await;

    // Real (short) wait — this test exercises a live socket call, so tokio's
    // paused/advanced virtual clock (used in the unit tests) doesn't apply here.
    let result = tokio::time::timeout(
        Duration::from_secs(5),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices(), "timeout_secs": 1 }),
        ),
    )
    .await
    .expect("the tool call itself must return once its own timeout_secs elapses");

    assert_eq!(result["error"], "timeout");
}

// ── raw-IPC DecisionResolved propagation (multi-window decision-sheet fix) ──
//
// The tests above drive `nostromo.ask_decision` purely through the MCP layer
// (`McpServer`/`DaemonMcpBackend`), whose harness never touches a raw
// `ServerMsg` broadcast — `McpServer` only speaks newline-delimited JSON-RPC
// over its own socket. `ServerMsg::DecisionResolved` is broadcast over the
// OTHER wire protocol: the length-prefixed `nostromo::ipc::Server` frames
// that `MainLayout`/the GUI actually subscribe to. So these tests stand up
// that raw `Server` instead (mirroring `tests/activity.rs`'s harness), wire
// `DecisionRegistry::configure_broadcast` to it exactly as `nostromod.rs`
// does, and drive the registry directly — there is no MCP tool call in any
// of these tests.
//
// Note on naming: this file already defines module-level `write_frame`/
// `read_frame` helpers (above) for the MCP layer's own JSONL framing. Rather
// than import `nostromo::ipc::codec::{read_frame, write_frame}` under those
// same names (which Rust won't allow — a `use` can't shadow a local item of
// the same name in one scope), the raw-IPC helpers below are named
// `raw_send`/`raw_recv`/... and call the codec functions via their full path.

struct RawHarness {
    _dir: TempDir,
    server: Server,
    decisions: Arc<Mutex<DecisionRegistry>>,
    socket_path: std::path::PathBuf,
}

/// Stand up a raw `nostromo::ipc::Server` (NOT the MCP layer) with a fresh
/// `DecisionRegistry`, and wire the registry's broadcast sender to the
/// server's own `tx` — mirroring exactly what `src/bin/nostromd.rs` does
/// right after `Server::bind` (`decisions.lock().unwrap().configure_broadcast(broadcast_tx.clone())`).
fn make_raw_daemon_state() -> RawHarness {
    let dir = TempDir::new().unwrap();
    let socket_path = dir.path().join("nostromod.sock");
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        dir.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .expect("raw server should bind");
    decisions
        .lock()
        .unwrap()
        .configure_broadcast(server.tx.clone());

    RawHarness {
        _dir: dir,
        server,
        decisions,
        socket_path,
    }
}

/// Submit a request for `tag`/`prompt` with a standard two-choice set against
/// an arbitrary `(decisions, broadcast tx)` pair, broadcasting it exactly as
/// `ask_decision.rs` does — `submit()` then, if it became the tag's active
/// (broadcast-now) request, `tx.send(msg)` — and return the fresh
/// `request_id`. Factored out of `submit_and_broadcast` (below) so the
/// combined harness (raw IPC + MCP layer, added for the decision-operator-gate
/// tests) can reuse it without a `RawHarness`.
fn submit_and_broadcast_via(
    decisions: &Arc<Mutex<DecisionRegistry>>,
    tx: &broadcast::Sender<ServerMsg>,
    tag: &str,
    prompt: &str,
) -> String {
    let (request_id, _rx, broadcast_msg) = decisions.lock().unwrap().submit(
        tag.to_string(),
        prompt.to_string(),
        None,
        vec![
            DecisionChoice {
                id: "approve".into(),
                label: "Approve".into(),
                detail: None,
            },
            DecisionChoice {
                id: "reject".into(),
                label: "Reject".into(),
                detail: None,
            },
        ],
        None,
    );
    if let Some(msg) = broadcast_msg {
        let _ = tx.send(msg);
    }
    request_id
}

/// Submit a request for `tag`/`prompt` with a standard two-choice set,
/// broadcasting it exactly as `ask_decision.rs` does — `submit()` then, if it
/// became the tag's active (broadcast-now) request, `server.tx.send(msg)` —
/// and return the fresh `request_id`.
fn submit_and_broadcast(harness: &RawHarness, tag: &str, prompt: &str) -> String {
    submit_and_broadcast_via(&harness.decisions, &harness.server.tx, tag, prompt)
}

async fn raw_send(stream: &mut UnixStream, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    nostromo::ipc::codec::write_frame(stream, &bytes)
        .await
        .unwrap();
}

async fn raw_recv(stream: &mut UnixStream) -> ServerMsg {
    let bytes = tokio::time::timeout(
        Duration::from_secs(5),
        nostromo::ipc::codec::read_frame(stream),
    )
    .await
    .expect("timed out waiting for a server frame")
    .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

/// Assert that no frame arrives on `stream` within `within` — used to prove a
/// rejected second answer produces NO further wire traffic on any connection
/// (a spurious notice here would read to the agent as a second, contradictory
/// resolution nobody actually made).
async fn raw_recv_none_within(stream: &mut UnixStream, within: Duration) {
    if let Ok(frame_result) =
        tokio::time::timeout(within, nostromo::ipc::codec::read_frame(stream)).await
    {
        let bytes = frame_result.expect("read frame");
        let msg: ServerMsg = serde_json::from_slice(&bytes).unwrap();
        panic!("expected no frame to arrive, but got: {msg:?}");
    }
}

/// Connect, Hello/Welcome, then Subscribe to `topics` with an explicit
/// `renders_decisions` flag. Mirrors `tests/activity.rs`'s `handshake()`. A
/// short real sleep afterward gives the server a moment to finish registering
/// this connection's subscription (and, per the decision-operator-gate fix,
/// its operator status) before the test starts driving the registry directly
/// — the same kind of real-sleep synchronization this file already uses
/// elsewhere (`wait_for_active_request`) for socket-level races a unit test
/// wouldn't have.
async fn raw_handshake(
    stream: &mut UnixStream,
    client_id: &str,
    topics: Vec<Topic>,
    renders_decisions: bool,
) {
    raw_send(
        stream,
        &ClientMsg::Hello {
            client_id: client_id.into(),
            protocol_version: 4,
        },
    )
    .await;
    assert!(matches!(raw_recv(stream).await, ServerMsg::Welcome { .. }));
    raw_send(
        stream,
        &ClientMsg::Subscribe {
            topics,
            renders_decisions,
        },
    )
    .await;
    tokio::time::sleep(Duration::from_millis(50)).await;
}

/// A subscribed client sees the request, then — once answered directly on
/// the registry — the matching `DecisionResolved { resolution: Answered, .. }`
/// notice for that same request_id.
#[tokio::test]
async fn a_subscribed_client_receives_the_request_then_an_answered_resolved_notice_for_the_same_id()
{
    let harness = make_raw_daemon_state();
    let mut stream = UnixStream::connect(&harness.socket_path).await.unwrap();
    raw_handshake(
        &mut stream,
        "decision-it-answered",
        vec![Topic::Decision],
        false,
    )
    .await;

    let request_id = submit_and_broadcast(&harness, "mother", "Ship it?");

    match raw_recv(&mut stream).await {
        ServerMsg::DecisionRequest {
            request_id: wire_id,
            ..
        } => assert_eq!(wire_id, request_id),
        other => panic!("expected DecisionRequest, got {other:?}"),
    }

    harness
        .decisions
        .lock()
        .unwrap()
        .answer(&request_id, Some("approve".into()));

    match raw_recv(&mut stream).await {
        ServerMsg::DecisionResolved {
            request_id: wire_id,
            resolution,
            choice_id,
            ..
        } => {
            assert_eq!(wire_id, request_id);
            assert_eq!(resolution, DecisionResolution::Answered);
            assert_eq!(choice_id, Some("approve".into()));
        }
        other => panic!("expected DecisionResolved, got {other:?}"),
    }
}

/// Same shape, but resolved via `timeout_request()`.
#[tokio::test]
async fn a_subscribed_client_receives_the_request_then_a_timeout_resolved_notice_for_the_same_id() {
    let harness = make_raw_daemon_state();
    let mut stream = UnixStream::connect(&harness.socket_path).await.unwrap();
    raw_handshake(
        &mut stream,
        "decision-it-timeout",
        vec![Topic::Decision],
        false,
    )
    .await;

    let request_id = submit_and_broadcast(&harness, "mother", "Ship it?");
    match raw_recv(&mut stream).await {
        ServerMsg::DecisionRequest { .. } => {}
        other => panic!("expected DecisionRequest, got {other:?}"),
    }

    harness
        .decisions
        .lock()
        .unwrap()
        .timeout_request(&request_id);

    match raw_recv(&mut stream).await {
        ServerMsg::DecisionResolved {
            request_id: wire_id,
            resolution,
            choice_id,
            ..
        } => {
            assert_eq!(wire_id, request_id);
            assert_eq!(resolution, DecisionResolution::Timeout);
            assert_eq!(choice_id, None);
        }
        other => panic!("expected DecisionResolved, got {other:?}"),
    }
}

/// Same shape, but resolved via `cancel_tag()`.
#[tokio::test]
async fn a_subscribed_client_receives_the_request_then_a_cancelled_resolved_notice_for_the_same_id()
{
    let harness = make_raw_daemon_state();
    let mut stream = UnixStream::connect(&harness.socket_path).await.unwrap();
    raw_handshake(
        &mut stream,
        "decision-it-cancelled",
        vec![Topic::Decision],
        false,
    )
    .await;

    let request_id = submit_and_broadcast(&harness, "mother", "Ship it?");
    match raw_recv(&mut stream).await {
        ServerMsg::DecisionRequest { .. } => {}
        other => panic!("expected DecisionRequest, got {other:?}"),
    }

    harness.decisions.lock().unwrap().cancel_tag("mother");

    match raw_recv(&mut stream).await {
        ServerMsg::DecisionResolved {
            request_id: wire_id,
            resolution,
            ..
        } => {
            assert_eq!(wire_id, request_id);
            assert_eq!(resolution, DecisionResolution::Cancelled);
        }
        other => panic!("expected DecisionResolved, got {other:?}"),
    }
}

/// The scenario that matters most for this fix: TWO windows (two IPC
/// connections), both subscribed to `Topic::Decision`, both see the same
/// request and its single resolution — and a second, contradictory answer
/// (simulating the old bug: answering it twice from two different windows)
/// is rejected outright and produces NO further frame on EITHER connection.
#[tokio::test]
async fn both_of_two_subscribed_clients_receive_the_request_and_its_resolution_and_a_second_contradictory_answer_reaches_neither(
) {
    let harness = make_raw_daemon_state();
    let mut stream_a = UnixStream::connect(&harness.socket_path).await.unwrap();
    raw_handshake(
        &mut stream_a,
        "decision-it-multi-a",
        vec![Topic::Decision],
        false,
    )
    .await;
    let mut stream_b = UnixStream::connect(&harness.socket_path).await.unwrap();
    raw_handshake(
        &mut stream_b,
        "decision-it-multi-b",
        vec![Topic::Decision],
        false,
    )
    .await;

    let request_id = submit_and_broadcast(&harness, "mother", "Ship it?");

    for stream in [&mut stream_a, &mut stream_b] {
        match raw_recv(stream).await {
            ServerMsg::DecisionRequest {
                request_id: wire_id,
                ..
            } => assert_eq!(wire_id, request_id),
            other => panic!("expected DecisionRequest, got {other:?}"),
        }
    }

    let first = harness
        .decisions
        .lock()
        .unwrap()
        .answer(&request_id, Some("approve".into()));
    match first {
        nostromo::ipc::decisions::AnswerOutcome::Answered { .. } => {}
        other => panic!("the first, legitimate answer must succeed, got {other:?}"),
    }

    for stream in [&mut stream_a, &mut stream_b] {
        match raw_recv(stream).await {
            ServerMsg::DecisionResolved {
                request_id: wire_id,
                resolution,
                choice_id,
                ..
            } => {
                assert_eq!(wire_id, request_id);
                assert_eq!(resolution, DecisionResolution::Answered);
                assert_eq!(choice_id, Some("approve".into()));
            }
            other => panic!("expected DecisionResolved, got {other:?}"),
        }
    }

    // A second, contradictory answer arriving as if from the OTHER window
    // after the fact — this is the exact bug being fixed: today the daemon
    // guard swallows it, but nothing tells the other window's stale sheet to
    // close, and nothing here must broadcast a second/conflicting notice.
    let second = harness
        .decisions
        .lock()
        .unwrap()
        .answer(&request_id, Some("reject".into()));
    match second {
        nostromo::ipc::decisions::AnswerOutcome::AlreadyAnswered => {}
        other => panic!(
            "a second answer to an already-resolved request must be AlreadyAnswered, got {other:?}"
        ),
    }

    raw_recv_none_within(&mut stream_a, Duration::from_millis(200)).await;
    raw_recv_none_within(&mut stream_b, Duration::from_millis(200)).await;
}

// ── decision-operator-gate fix: the subscribe-time operator predicate ──────────
//
// Every test above establishes "operator present" either by calling
// `add_operator` directly on the registry (the `Harness`/MCP-only tests) or by
// subscribing to `Topic::Decision` explicitly (the raw-IPC propagation tests).
// Neither exercises the actual bug: `server.rs::handle_client` deciding
// whether a *given* `Subscribe` frame counts its sender as an operator at all.
//
// That predicate only runs inside the real `nostromo::ipc::Server`, and the
// thing it gates — `nostromo.ask_decision` returning `no_operator` — only
// lives in the MCP layer (`DaemonMcpBackend`). So these tests stand up BOTH
// wire protocols at once, sharing one `Arc<Mutex<DecisionRegistry>>` and one
// broadcast channel, so a test can drive a real `Hello`→`Welcome`→`Subscribe`
// handshake on the raw socket to establish (or withdraw) operator status,
// while driving `nostromo.ask_decision` through the real MCP socket to observe
// the effect.

struct CombinedHarness {
    _dir: TempDir,
    raw_server: Server,
    _mcp_server: McpServer,
    decisions: Arc<Mutex<DecisionRegistry>>,
    raw_socket_path: std::path::PathBuf,
    mcp_socket_path: std::path::PathBuf,
}

/// Stand up a raw `nostromo::ipc::Server` (real `Hello`/`Subscribe` frames,
/// real operator accounting in `handle_client`) and an `McpServer`/
/// `DaemonMcpBackend` (real `nostromo.ask_decision` calls), both wired to the
/// SAME `Arc<Mutex<DecisionRegistry>>` and the same broadcast channel —
/// mirroring `make_raw_daemon_state` for the raw side and `make_daemon_state`
/// for the MCP side, just sharing state between them instead of each getting
/// its own fresh registry.
async fn make_combined_harness() -> CombinedHarness {
    let dir = TempDir::new().unwrap();
    let raw_socket_path = dir.path().join("nostromod.sock");
    let mcp_socket_path = dir.path().join("mcp-decision.sock");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        dir.path().join("sessions.json"),
    )));
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        dir.path().join("panes.json"),
    )));
    let decisions = Arc::new(Mutex::new(DecisionRegistry::new()));

    let raw_server = Server::bind(
        &raw_socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        dir.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .expect("raw server should bind");
    decisions
        .lock()
        .unwrap()
        .configure_broadcast(raw_server.tx.clone());

    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx: raw_server.tx.clone(),
        perri: nostromo::mcp::PerriDaemonState::default(),
        decisions: decisions.clone(),
        tickets: Default::default(),
    };
    let mcp_server = McpServer::bind(mcp_socket_path.clone(), McpSharedState::for_daemon(backend))
        .await
        .expect("mcp server should bind");

    CombinedHarness {
        _dir: dir,
        raw_server,
        _mcp_server: mcp_server,
        decisions,
        raw_socket_path,
        mcp_socket_path,
    }
}

/// THE core regression test for the reported bug: a `topics: []` subscriber
/// with no `renders_decisions` flag — today's iOS behavior — must NOT count
/// as an operator, so `ask_decision` refuses immediately instead of blocking
/// toward the (300s default) answer timeout.
#[tokio::test]
async fn ask_decision_with_only_a_wildcard_subscriber_returns_no_operator_without_blocking() {
    let harness = make_combined_harness().await;

    let mut wildcard = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut wildcard, "ios-wildcard", vec![], false).await;

    let (mut reader, mut writer) = connect(&harness.mcp_socket_path, "perri").await;

    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        ),
    )
    .await
    .expect(
        "THE BUG: a topics: [] subscriber with no renders_decisions flag must not be \
         treated as an operator — ask_decision must refuse fast, not block toward the \
         300s timeout",
    );

    assert_eq!(
        result["error"], "no_operator",
        "a wildcard-only subscriber (today's iOS behavior) must not count as an operator"
    );
}

/// The flip side of the fix: narrowing who counts as an *operator* must not
/// narrow who *receives* broadcasts. A `topics: []` subscriber still gets
/// every `DecisionRequest`, exactly as before — delivery (`message_matches_topics`)
/// and operator-accounting are separate concerns, and this proves the split
/// didn't quietly couple them back together.
#[tokio::test]
async fn a_wildcard_subscriber_still_receives_a_decision_request_broadcast_from_a_real_operators_request(
) {
    let harness = make_combined_harness().await;

    let mut wildcard = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut wildcard, "ios-wildcard", vec![], false).await;

    let mut operator = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(
        &mut operator,
        "macos-operator",
        vec![Topic::Decision],
        false,
    )
    .await;

    let request_id = submit_and_broadcast_via(
        &harness.decisions,
        &harness.raw_server.tx,
        "mother",
        "Ship it?",
    );

    match raw_recv(&mut wildcard).await {
        ServerMsg::DecisionRequest {
            request_id: wire_id,
            ..
        } => assert_eq!(
            wire_id, request_id,
            "a topics: [] connection must still receive DecisionRequest broadcasts — \
             delivery must not be narrowed by the operator-accounting change"
        ),
        other => panic!("expected DecisionRequest on the wildcard connection, got {other:?}"),
    }
    match raw_recv(&mut operator).await {
        ServerMsg::DecisionRequest {
            request_id: wire_id,
            ..
        } => assert_eq!(wire_id, request_id),
        other => panic!("expected DecisionRequest on the operator connection, got {other:?}"),
    }
}

/// The "macOS keeps working with zero client changes" path: a connection that
/// subscribes with an explicit `topics: [Topic::Decision]` (no
/// `renders_decisions` flag at all) counts as an operator, so `ask_decision`
/// proceeds — and the full round trip (ask → receive the request over the raw
/// socket → answer over the raw socket → the MCP call resolves) works
/// end-to-end.
#[tokio::test]
async fn a_subscriber_with_explicit_decision_topic_counts_as_operator_and_ask_decision_is_answerable(
) {
    let harness = make_combined_harness().await;

    let mut operator = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(
        &mut operator,
        "macos-operator",
        vec![Topic::Decision],
        false,
    )
    .await;

    let (mut reader, mut writer) = connect(&harness.mcp_socket_path, "perri").await;
    let call = tokio::spawn(async move {
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        )
        .await
    });

    let request_id = match raw_recv(&mut operator).await {
        ServerMsg::DecisionRequest { request_id, .. } => request_id,
        other => panic!("expected DecisionRequest, got {other:?}"),
    };
    raw_send(
        &mut operator,
        &ClientMsg::DecisionAnswer {
            request_id,
            choice_id: Some("approve".into()),
        },
    )
    .await;

    let result = tokio::time::timeout(Duration::from_secs(5), call)
        .await
        .expect("ask_decision must not block once an explicit-topic operator is present")
        .unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(result["choice_id"], "approve");
}

/// The path a future job (W3) will put iOS on: a `topics: []` subscriber that
/// sets `renders_decisions: true` counts as an operator too, and is fully
/// answerable end-to-end — proving the new flag is a genuine, working
/// alternative to naming `Topic::Decision` explicitly, not just a value that
/// decodes.
#[tokio::test]
async fn a_wildcard_subscriber_with_renders_decisions_true_counts_as_operator_and_ask_decision_is_answerable(
) {
    let harness = make_combined_harness().await;

    let mut operator = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut operator, "future-ios-operator", vec![], true).await;

    let (mut reader, mut writer) = connect(&harness.mcp_socket_path, "perri").await;
    let call = tokio::spawn(async move {
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        )
        .await
    });

    let request_id = match raw_recv(&mut operator).await {
        ServerMsg::DecisionRequest { request_id, .. } => request_id,
        other => panic!("expected DecisionRequest, got {other:?}"),
    };
    raw_send(
        &mut operator,
        &ClientMsg::DecisionAnswer {
            request_id,
            choice_id: Some("approve".into()),
        },
    )
    .await;

    let result = tokio::time::timeout(Duration::from_secs(5), call)
        .await
        .expect("renders_decisions: true must count as an operator even with topics: []")
        .unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(result["choice_id"], "approve");
}

/// THE regression test that matters most: before this fix, `has_operator()`
/// was "is any client subscribed at all," so a lingering `topics: []`
/// connection alone kept it true forever — even after the one client that
/// could actually render a decision disconnected. Two connections here: a
/// wildcard-without-flag (never an operator) and an explicit
/// `topics: [Topic::Decision]` connection (the real operator). Disconnecting
/// ONLY the real operator must flip `ask_decision` back to `no_operator`,
/// even though the wildcard connection is still open.
#[tokio::test]
async fn disconnecting_the_only_real_operator_returns_no_operator_even_though_a_wildcard_client_is_still_connected(
) {
    let harness = make_combined_harness().await;

    // Kept alive (not dropped) for the whole test, deliberately — its
    // continued presence is the point: it must never be enough on its own.
    let mut wildcard = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(&mut wildcard, "ios-wildcard", vec![], false).await;

    let mut operator = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_handshake(
        &mut operator,
        "macos-operator",
        vec![Topic::Decision],
        false,
    )
    .await;

    // Sanity check on the setup, not the assertion under test: an operator
    // really is present right now.
    assert!(
        harness.decisions.lock().unwrap().has_operator(),
        "the explicit-topic connection must register as an operator before we test its withdrawal"
    );

    // Disconnect ONLY the real operator.
    drop(operator);

    // Poll for the server's disconnect cleanup (`remove_operator`) to land —
    // same real-sleep-loop precedent as `wait_for_active_request` above, for
    // a socket-level async race a unit test wouldn't have.
    let mut cleaned_up = false;
    for _ in 0..50 {
        if !harness.decisions.lock().unwrap().has_operator() {
            cleaned_up = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(
        cleaned_up,
        "operator cleanup did not land within the wait window"
    );

    let (mut reader, mut writer) = connect(&harness.mcp_socket_path, "perri").await;
    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        ),
    )
    .await
    .expect(
        "THE BUG: a lingering wildcard connection alone must not keep has_operator() true \
         forever after the real operator disconnects",
    );

    assert_eq!(result["error"], "no_operator");

    // Keep `wildcard` alive to this point — proves its liveness didn't matter.
    drop(wildcard);
}

/// The `Ping`-as-second-frame path (mirrors `server.rs::handle_client`'s
/// handling around the `Subscribe` read: a client that pings instead of
/// subscribing gets `topics: []` and, per this fix, `renders_decisions:
/// false` too) must not count as an operator either.
#[tokio::test]
async fn a_connection_whose_second_frame_is_ping_instead_of_subscribe_does_not_count_as_operator() {
    let harness = make_combined_harness().await;

    let mut stream = UnixStream::connect(&harness.raw_socket_path).await.unwrap();
    raw_send(
        &mut stream,
        &ClientMsg::Hello {
            client_id: "ping-only".into(),
            protocol_version: 4,
        },
    )
    .await;
    assert!(matches!(
        raw_recv(&mut stream).await,
        ServerMsg::Welcome { .. }
    ));
    raw_send(&mut stream, &ClientMsg::Ping).await;
    assert!(matches!(raw_recv(&mut stream).await, ServerMsg::Pong));
    // Same settle window `raw_handshake` uses, for the same reason: give the
    // server a moment to finish its post-Subscribe/Ping bookkeeping before
    // this test starts asserting on it.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let (mut reader, mut writer) = connect(&harness.mcp_socket_path, "perri").await;
    let result = tokio::time::timeout(
        Duration::from_millis(500),
        call_tool(
            &mut reader,
            &mut writer,
            2,
            "nostromo.ask_decision",
            json!({ "prompt": "Ship it?", "choices": two_choices() }),
        ),
    )
    .await
    .expect("a ping-only connection must not count as an operator, so this must fail fast");

    assert_eq!(result["error"], "no_operator");
}
