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

// ── W7 — D8/D10: a removed focus's pin is gone from disk ─────────────────────

fn focus_meta(tag: &str) -> nostromo::ipc::protocol::FocusMeta {
    nostromo::ipc::protocol::FocusMeta {
        tag: tag.into(),
        display_name: tag.into(),
        agent_name: tag.into(),
        project_name: None,
        org: None,
        is_built_in: false,
        session_summary: None,
    }
}

/// Stand up a server and return `(socket_path, perri_state_dir, tmp, server)`.
/// The server and tempdir are returned so the caller keeps them alive.
async fn serve() -> (std::path::PathBuf, std::path::PathBuf, TempDir, Server) {
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
    (socket_path, perri_state_dir, tmp, server)
}

fn pin_of(state_dir: &std::path::Path, tag: &str) -> std::path::PathBuf {
    nostromo::data::perri_current_pr::pin_path(state_dir, tag).unwrap()
}

/// The daemon's only signal that a focus was removed is the next
/// `FocusRegistryPush` carrying a shorter list — the Mac detaches rather than
/// stopping the session, so nothing else ever says so. When that removal is
/// confirmed, the focus's pin must be gone from disk and no other focus's pin
/// may move.
#[tokio::test]
async fn a_removed_focus_loses_its_pin_and_no_other_focus_is_touched() {
    let (socket_path, state_dir, _tmp, _server) = serve().await;
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri"), focus_meta("cody")],
        },
    )
    .await;

    for (tag, number) in [("perri", 4526u64), ("cody", 42)] {
        send(
            &mut stream,
            &ClientMsg::PerriAction {
                action: "load_pr".into(),
                pr_number: Some(number),
                repo: Some("acme/anvil".into()),
                tag: Some(tag.into()),
            },
        )
        .await;
    }
    assert!(
        wait_until(|| pin_of(&state_dir, "perri").exists() && pin_of(&state_dir, "cody").exists())
            .await,
        "both focuses must have a pin before the removal"
    );

    // Two consecutive pushes without "cody" — one is a partial push, which
    // must not evict (D8a).
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri")],
        },
    )
    .await;
    assert!(
        !wait_until(|| !pin_of(&state_dir, "cody").exists()).await,
        "a single push must not evict — that is what a reconnect looks like"
    );

    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri")],
        },
    )
    .await;
    assert!(
        wait_until(|| !pin_of(&state_dir, "cody").exists()).await,
        "a focus absent from two consecutive pushes must lose its pin"
    );
    assert!(
        pin_of(&state_dir, "perri").exists(),
        "removing one focus must not disturb another focus's pin"
    );
}

/// D10, and the case the plan flags as the one that actually breaks.
/// `nostromo.create_focus` derives its tag deterministically from
/// `(agent, title)`, so close-and-recreate yields the *same* tag. The pin must
/// be genuinely deleted, not tombstoned, or the new focus inherits the dead
/// one's PR.
#[tokio::test]
async fn a_focus_recreated_under_a_reused_tag_inherits_no_pin() {
    let (socket_path, state_dir, _tmp, _server) = serve().await;
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    let reused = "cody-core-1234";
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri"), focus_meta(reused)],
        },
    )
    .await;
    send(
        &mut stream,
        &ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(4526),
            repo: Some("Carefeed/admin-portal".into()),
            tag: Some(reused.into()),
        },
    )
    .await;
    assert!(wait_until(|| pin_of(&state_dir, reused).exists()).await);

    // Closed, and confirmed closed.
    for _ in 0..2 {
        send(
            &mut stream,
            &ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("perri")],
            },
        )
        .await;
    }
    assert!(wait_until(|| !pin_of(&state_dir, reused).exists()).await);

    // Recreated under the very same tag.
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri"), focus_meta(reused)],
        },
    )
    .await;

    // Give the daemon the same window the eviction got, so this asserts
    // "no pin appeared" rather than "we looked too early".
    assert!(
        !wait_until(|| pin_of(&state_dir, reused).exists()).await,
        "a recreated focus reusing a dead focus's tag must start with no PR under review"
    );
}
