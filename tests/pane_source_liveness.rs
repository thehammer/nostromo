//! Integration tests for automatic pane-source liveness over the real IPC
//! transport, mirroring the raw-socket harness pattern in
//! `tests/mcp_daemon_panes.rs`.
//!
//! These exercise two observable guarantees from the outside:
//!
//! 1. A client that (re)connects *after* bindings already exist is never left
//!    with empty panes — it gets both the structural `FocusLayout` and each
//!    bound pane's live `PaneContent` replayed on attach.
//! 2. A `PaneRegistry` reloaded from disk (simulating a daemon restart) can
//!    produce content for its bindings with no tool call made in the fresh
//!    process at all.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::pane_registry::{PaneRegistry, SplitPosition};
use nostromo::ipc::protocol::{ClientMsg, PaneContentWire, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::pane_sources::{bound_pane_contents, McpPaneContentProvider};
use nostromo::mcp::tools::apply_layout::apply_layout;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::json;
use tempfile::TempDir;
use tokio::net::UnixStream;

// ── helpers ───────────────────────────────────────────────────────────────────

async fn send(stream: &mut UnixStream, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    write_frame(stream, &bytes).await.unwrap();
}

async fn recv(stream: &mut UnixStream) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

async fn handshake(stream: &mut UnixStream, topics: Vec<Topic>) {
    send(
        stream,
        &ClientMsg::Hello {
            client_id: "pane-source-liveness-it".into(),
            protocol_version: 3,
        },
    )
    .await;
    assert!(matches!(recv(stream).await, ServerMsg::Welcome { .. }));
    send(stream, &ClientMsg::Subscribe { topics, renders_decisions: false }).await;
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn reconnecting_client_gets_layout_and_live_pane_content_replayed() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        tmp.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_mcp_bridge(
            Arc::clone(&pane_registry),
            tmp.path().join("mcp.sock"),
            tmp.path().join("mcp-config.json"),
        );
    }
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let decisions = Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .unwrap();

    let backend = DaemonMcpBackend {
        pane_registry: Arc::clone(&pane_registry),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions,
        tickets: Default::default(),
    };
    let state = McpSharedState::for_daemon(backend);

    // Wire the PaneContentProvider the same way `nostromd.rs` does — without
    // it, `server.rs`'s attach-replay path (D8) has nothing to draw live pane
    // content from, and this test would only ever observe the FocusLayout
    // replay.
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_pane_content_provider(Arc::new(McpPaneContentProvider(state.clone())));
    }

    // Assemble the "perri" focus in-process — this exercises the very same
    // PaneRegistry + broadcast_tx the raw IPC server replays from, so no
    // separate MCP socket round trip is needed to set up this assertion.
    let result = apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
    assert_eq!(result["ok"], true);

    // A second client connects *after* the layout + bindings already exist.
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Layout]).await;

    let mut saw_layout = false;
    let mut saw_queue_content = false;
    let mut saw_diff_content = false;
    for _ in 0..8 {
        if saw_layout && saw_queue_content && saw_diff_content {
            break;
        }
        let msg = match tokio::time::timeout(Duration::from_millis(500), recv(&mut stream)).await
        {
            Ok(m) => m,
            Err(_) => break,
        };
        match msg {
            ServerMsg::FocusLayout { tag, .. } if tag == "perri" => saw_layout = true,
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } if tag == "perri" => match pane_id.as_str() {
                "queue" => {
                    saw_queue_content = true;
                    assert!(matches!(content, PaneContentWire::PrList { .. }));
                }
                "diff" => {
                    saw_diff_content = true;
                    assert!(matches!(content, PaneContentWire::Text { .. }));
                }
                other => panic!("unexpected pane_id in replay: {other}"),
            },
            _ => {}
        }
    }

    assert!(
        saw_layout,
        "a (re)connecting client must get the current FocusLayout replayed"
    );
    assert!(
        saw_queue_content,
        "a (re)connecting client must get the queue pane's live content replayed"
    );
    assert!(
        saw_diff_content,
        "a (re)connecting client must get the diff pane's live content replayed"
    );

    drop(server);
}

/// Regression test: a pane bound to `nostromo.get_file` must not deadlock a
/// (re)connecting client's attach-replay.
///
/// `server.rs`'s connect handler used to hold `session_mgr`'s lock for the
/// entire `bound_pane_contents()` call. `SOURCE_FILE`'s fetch path
/// (`file_request_context` -> `file_root`) locks that exact same
/// `Arc<Mutex<SessionManager>>` again to resolve the focus's cwd —
/// `std::sync::Mutex` is not reentrant, so every reconnect (and every
/// daemon-restart replay) hung forever the moment any pane was bound to this
/// source. The existing `reconnecting_client_...` test above never exercised
/// this because `perri-standard`'s panes bind to sources that don't touch
/// `session_mgr` at fetch time — the bug needed a `get_file`-bound pane
/// specifically, which this test adds. Every `recv()` here is wrapped in a
/// short timeout so a deadlock shows up as a clean assertion failure instead
/// of a hung test process.
#[tokio::test]
async fn a_pane_bound_to_get_file_does_not_deadlock_a_reconnecting_client() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        tmp.path().join("panes.json"),
    )));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_mcp_bridge(
            Arc::clone(&pane_registry),
            tmp.path().join("mcp.sock"),
            tmp.path().join("mcp-config.json"),
        );
    }
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let decisions = Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    )
    .unwrap();

    let backend = DaemonMcpBackend {
        pane_registry: Arc::clone(&pane_registry),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions,
        tickets: Default::default(),
    };
    let state = McpSharedState::for_daemon(backend);

    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_pane_content_provider(Arc::new(McpPaneContentProvider(state.clone())));
    }

    let result = apply_layout(&state, &json!({ "name": "perri-standard" }), Some("perri")).await;
    assert_eq!(result["ok"], true);

    // Bind the diff pane to a real file this test process can read.
    // `file_root()` falls back to the test process's own cwd when no live
    // session exists for the tag (as here), and its containment check is
    // lexical against that root — so the path must resolve *inside* it, not
    // just be readable. A file already tracked in this repo (present in
    // every checkout, unlike a path under the OS tmpdir) satisfies that.
    let refresh_result = nostromo::mcp::tools::refresh_pane::refresh_pane_content(
        &state,
        &json!({
            "pane_id": "diff",
            "source": "nostromo.get_file",
            "params": { "path": "Cargo.toml" },
        }),
        Some("perri"),
    )
    .await;
    assert_eq!(refresh_result["ok"], true, "binding the diff pane to get_file must succeed: {refresh_result:?}");

    // A client connecting after that binding exists is exactly the path that
    // used to deadlock: attach-replay calls bound_pane_contents() while
    // holding session_mgr's lock, which get_file's fetch path re-locks.
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Layout]).await;

    let mut saw_layout = false;
    let mut saw_code_content = false;
    for _ in 0..8 {
        if saw_layout && saw_code_content {
            break;
        }
        let msg = match tokio::time::timeout(Duration::from_millis(500), recv(&mut stream)).await
        {
            Ok(m) => m,
            Err(_) => break, // a deadlocked server never writes another frame
        };
        match msg {
            ServerMsg::FocusLayout { tag, .. } if tag == "perri" => saw_layout = true,
            ServerMsg::PaneContent { tag, pane_id, content, .. }
                if tag == "perri" && pane_id == "diff" =>
            {
                assert!(matches!(content, PaneContentWire::Code { .. }));
                saw_code_content = true;
            }
            _ => {}
        }
    }

    assert!(
        saw_layout,
        "a client connecting after a get_file binding must still get FocusLayout replayed \
         (a deadlocked connect handler would never send anything at all)"
    );
    assert!(
        saw_code_content,
        "a client connecting after a get_file binding must get that pane's live content \
         replayed, not hang forever inside bound_pane_contents()"
    );

    drop(server);
}

#[tokio::test]
async fn fresh_registry_after_simulated_restart_has_bound_pane_content_ready_with_no_tool_call() {
    let tmp = TempDir::new().unwrap();
    let store_path = tmp.path().join("panes.json");

    {
        let mut reg = PaneRegistry::with_store_path(store_path.clone());
        reg.init_focus("perri");
        reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
            .unwrap();
        reg.bind_source("perri", "queue", "perri.list_pr_queue");
        // `reg` drops here, flushing the tree + binding to disk.
    }

    // Simulate a daemon restart: a brand-new `PaneRegistry`, loaded from the
    // same on-disk store, in a state built with no tool call made in this
    // process at all — the only inputs are what's already on disk.
    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(store_path)));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let (broadcast_tx, _rx) = tokio::sync::broadcast::channel(64);
    let backend = DaemonMcpBackend {
        pane_registry,
        session_mgr,
        broadcast_tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
        tickets: Default::default(),
    };
    let state = McpSharedState::for_daemon(backend);

    let contents = bound_pane_contents(&state);
    assert_eq!(
        contents.len(),
        1,
        "exactly one PaneContent for the one reloaded binding"
    );
    match &contents[0] {
        ServerMsg::PaneContent {
            tag,
            pane_id,
            content,
            ..
        } => {
            assert_eq!(tag, "perri");
            assert_eq!(pane_id, "queue");
            assert!(matches!(content, PaneContentWire::PrList { .. }));
        }
        other => panic!("expected PaneContent, got {other:?}"),
    }
}
