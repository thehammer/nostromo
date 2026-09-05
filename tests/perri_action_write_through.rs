//! Socket-level coverage that `ClientMsg::PerriAction` ("load_pr"/"clear")
//! writes through the same `current-pr.json` / `current-pr.dirty` /
//! `queue.dirty` file contract the daemon's native Perri sources watch,
//! instead of shelling out to a nonexistent `perri` binary. Mirrors the raw
//! socket harness pattern in `tests/activity.rs`.
//!
//! The write happens inside a `tokio::spawn` in
//! `handle_client_msg`'s `ClientMsg::PerriAction` arm — it is not
//! synchronous with the client's send — so these tests poll with a bounded
//! timeout rather than asserting immediately after `send`.

use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use std::sync::{Arc, Mutex};
use tempfile::TempDir;
use tokio::net::UnixStream;

// ── helpers (mirrors tests/activity.rs) ──────────────────────────────────────

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
            client_id: "perri-action-it".into(),
            protocol_version: 4,
        },
    )
    .await;
    assert!(matches!(recv(stream).await, ServerMsg::Welcome { .. }));
    send(
        stream,
        &ClientMsg::Subscribe {
            topics,
            renders_decisions: false,
        },
    )
    .await;
}

/// Poll `predicate` up to ~5s (50ms steps) — bridges the gap between the
/// client's send and the server's `tokio::spawn`-backed write.
async fn wait_until(mut predicate: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if predicate() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    predicate()
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// A `PerriAction { action: "load_pr", .. }` sent over the socket must land
/// as a `current-pr.json` pointer in the daemon's `perri_state_dir` — the
/// same file contract `perri.load_pr`/`perri.clear_current_pr` MCP tools and
/// the TUI's `PerriView` write through. Today's code shells out to a
/// nonexistent `perri` binary instead, so `current-pr.json` never appears
/// and this test times out.
#[tokio::test]
async fn perri_action_load_pr_writes_a_current_pr_pointer_via_the_socket() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");
    let perri_state_dir = tmp.path().join("perri-state");

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let decisions = Arc::new(Mutex::new(
        nostromo::ipc::decisions::DecisionRegistry::default(),
    ));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        perri_state_dir.clone(),
        Arc::clone(&decisions),
    )
    .unwrap();

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri]).await;

    send(
        &mut stream,
        &ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(7),
            repo: Some("acme/anvil".into()),
            tag: None,
        },
    )
    .await;

    let pointer_path = nostromo::data::perri_current_pr::pin_path(
        &perri_state_dir,
        nostromo::data::perri_current_pr::BUILTIN_PERRI_TAG,
    )
    .unwrap();
    let appeared = wait_until(|| pointer_path.exists()).await;
    assert!(
        appeared,
        "current-pr.json did not appear at {} within the timeout — \
         load_pr did not write through the file contract",
        pointer_path.display()
    );

    let content = std::fs::read_to_string(&pointer_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&content).unwrap();
    assert_eq!(parsed["number"], 7);
    assert_eq!(parsed["repo"], "acme/anvil");

    drop(server);
}

/// A `PerriAction { action: "clear", .. }` sent over the socket after a
/// successful `load_pr` must remove `current-pr.json` and touch
/// `queue.dirty`. Today's code shells out to a nonexistent `perri` binary
/// for both actions, so neither ever happens and this test times out
/// waiting for `current-pr.json` to appear in the first place.
#[tokio::test]
async fn perri_action_clear_removes_the_pointer_via_the_socket() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");
    let perri_state_dir = tmp.path().join("perri-state");

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let decisions = Arc::new(Mutex::new(
        nostromo::ipc::decisions::DecisionRegistry::default(),
    ));

    let server = Server::bind(
        &socket_path,
        Arc::clone(&pty_mgr),
        Arc::clone(&session_mgr),
        perri_state_dir.clone(),
        Arc::clone(&decisions),
    )
    .unwrap();

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri]).await;

    let pointer_path = nostromo::data::perri_current_pr::pin_path(
        &perri_state_dir,
        nostromo::data::perri_current_pr::BUILTIN_PERRI_TAG,
    )
    .unwrap();
    let queue_dirty_path = perri_state_dir.join("queue.dirty");

    send(
        &mut stream,
        &ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(7),
            repo: Some("acme/anvil".into()),
            tag: None,
        },
    )
    .await;
    assert!(
        wait_until(|| pointer_path.exists()).await,
        "current-pr.json did not appear within the timeout after load_pr"
    );

    send(
        &mut stream,
        &ClientMsg::PerriAction {
            action: "clear".into(),
            pr_number: None,
            repo: None,
            tag: None,
        },
    )
    .await;

    let cleared = wait_until(|| !pointer_path.exists() && queue_dirty_path.exists()).await;
    assert!(
        cleared,
        "clear did not remove current-pr.json and touch queue.dirty within the timeout \
         (pointer exists: {}, queue.dirty exists: {})",
        pointer_path.exists(),
        queue_dirty_path.exists()
    );

    drop(server);
}
