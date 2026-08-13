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

use nostromo::data::perri_pr::PrSnapshot;
use nostromo::data::perri_queue::{PrQueueItem, PrQueueSnapshot};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::pane_registry::{PaneRegistry, SplitPosition};
use nostromo::ipc::perri_state::WatchPerriStateProvider;
use nostromo::ipc::protocol::{ClientMsg, PaneContentWire, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::pane_sources::{bound_pane_contents, McpPaneContentProvider};
use nostromo::mcp::tools::apply_layout::apply_layout;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::json;
use tempfile::TempDir;
use tokio::net::UnixStream;

/// A `PrQueueSnapshot` with exactly one real item — enough to distinguish
/// "the provider fetched something" from "nothing fetched yet".
fn seeded_queue_snapshot() -> PrQueueSnapshot {
    PrQueueSnapshot {
        generated_at: None,
        items: vec![PrQueueItem {
            repo: "acme/web".into(),
            number: 42,
            title: "feat: add auth".into(),
            author: "alice".into(),
            bucket: "requested".into(),
            new_activity: false,
            url: "https://github.com/acme/web/pull/42".into(),
            ci_state: Default::default(),
            head_sha: "abc123".into(),
            is_bot: false,
        }],
        stale: false,
        error: None,
    }
}

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
    send(stream, &ClientMsg::Subscribe { topics }).await;
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

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
    )
    .unwrap();

    let backend = DaemonMcpBackend {
        pane_registry: Arc::clone(&pane_registry),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
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

// ── Perri-state attach replay (f1) ──────────────────────────────────────────
//
// `ServerMsg::PerriState` (the PR queue + current-PR snapshot) is otherwise
// only pushed to already-connected clients when the underlying watch
// channels change, or once at daemon startup. A client that attaches after
// that point — every iOS app launch, since iOS subscribes with an empty
// topic list — would otherwise see nothing until the next queue/PR change,
// up to `pr_queue_poll_secs` (60s) later. These tests exercise the replay
// mirroring the existing `FocusLayout` replay above.

#[tokio::test]
async fn attaching_client_gets_perri_state_replayed() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));

    let (_queue_tx, queue_rx) = tokio::sync::watch::channel(Some(seeded_queue_snapshot()));
    let (_pr_tx, pr_rx) = tokio::sync::watch::channel(None::<PrSnapshot>);
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_perri_state_provider(Arc::new(WatchPerriStateProvider::new(
            queue_rx, pr_rx,
        )));
    }

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
    )
    .unwrap();

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri]).await;

    let mut seen_seeded_item = false;
    for _ in 0..8 {
        let msg = match tokio::time::timeout(Duration::from_millis(500), recv(&mut stream)).await
        {
            Ok(m) => m,
            Err(_) => break,
        };
        if let ServerMsg::PerriState { queue, .. } = msg {
            seen_seeded_item = queue
                .iter()
                .any(|item| item.repo == "acme/web" && item.number == 42);
            break;
        }
    }

    assert!(
        seen_seeded_item,
        "a client attaching after startup and subscribing to Perri must get the current \
         PerriState (with the already-fetched queue) replayed, not just future changes"
    );

    drop(server);
}

#[tokio::test]
async fn attaching_client_with_empty_topics_gets_layout_and_perri_replayed() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
        tmp.path().join("panes.json"),
    )));
    {
        pane_registry.lock().unwrap().init_focus("perri");
    }

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let (_queue_tx, queue_rx) = tokio::sync::watch::channel(Some(seeded_queue_snapshot()));
    let (_pr_tx, pr_rx) = tokio::sync::watch::channel(None::<PrSnapshot>);
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_mcp_bridge(
            Arc::clone(&pane_registry),
            tmp.path().join("mcp.sock"),
            tmp.path().join("mcp-config.json"),
        );
        mgr.configure_perri_state_provider(Arc::new(WatchPerriStateProvider::new(
            queue_rx, pr_rx,
        )));
    }
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
    )
    .unwrap();

    // iOS subscribes with an empty topic list — this is the f1b regression
    // case: an empty topic list must mean "subscribed to everything" for
    // replay purposes too, not just for live broadcast fan-out.
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![]).await;

    let mut messages: Vec<ServerMsg> = Vec::new();
    for _ in 0..8 {
        let msg = match tokio::time::timeout(Duration::from_millis(500), recv(&mut stream)).await
        {
            Ok(m) => m,
            Err(_) => break,
        };
        messages.push(msg);
    }

    let saw_layout = messages
        .iter()
        .any(|m| matches!(m, ServerMsg::FocusLayout { tag, .. } if tag == "perri"));
    let saw_perri = messages
        .iter()
        .any(|m| matches!(m, ServerMsg::PerriState { .. }));

    assert!(
        saw_layout,
        "an empty-topic-list attach must still get FocusLayout replayed"
    );
    assert!(
        saw_perri,
        "an empty-topic-list attach must also get PerriState replayed — an iOS client that \
         subscribes with no topics must not be starved of the Perri snapshot just because it \
         didn't ask for FocusLayout specifically"
    );

    drop(server);
}

#[tokio::test]
async fn attaching_client_gets_no_perri_frame_before_first_fetch() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));

    // Both watch channels are still at their initial `None` — neither the PR
    // queue nor the current-PR source has fetched anything yet.
    let (_queue_tx, queue_rx) = tokio::sync::watch::channel(None::<PrQueueSnapshot>);
    let (_pr_tx, pr_rx) = tokio::sync::watch::channel(None::<PrSnapshot>);
    {
        let mut mgr = session_mgr.lock().unwrap();
        mgr.configure_perri_state_provider(Arc::new(WatchPerriStateProvider::new(
            queue_rx, pr_rx,
        )));
    }

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
    )
    .unwrap();

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri]).await;

    let mut saw_perri_state = false;
    for _ in 0..4 {
        let msg = match tokio::time::timeout(Duration::from_millis(500), recv(&mut stream)).await
        {
            Ok(m) => m,
            Err(_) => continue,
        };
        if matches!(msg, ServerMsg::PerriState { .. }) {
            saw_perri_state = true;
            break;
        }
    }

    assert!(
        !saw_perri_state,
        "attaching before the Perri sources have ever fetched anything must not paint a \
         spurious empty PerriState over nothing — there is simply no state to replay yet"
    );

    drop(server);
}
