//! Headless end-to-end harness for the daemon-hosted persistent session.
//!
//! Spawns a **real** `claude` stream-json child via `SessionManager`, connects a
//! test IPC client over the Unix socket, sends a user message with the new
//! `SessionSend`, and asserts that `SessionTurns` / `SessionTurnDelta` come back
//! with a turn that completes on the `result` event.
//!
//! This is the one test that exercises the full IPC → daemon → real `claude`
//! path. It is `#[ignore]`d so the default `cargo test` stays fast and offline
//! (no network, no token spend). Run it locally with:
//!
//! ```text
//! cargo test --test session_host_integration -- --ignored --nocapture
//! ```

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg};
use nostromo::ipc::session_manager::resolve_claude;
use nostromo::ipc::{PtyManager, Server, SessionManager};
use tokio::net::UnixStream;

async fn send(stream: &mut UnixStream, msg: &ClientMsg) {
    let bytes = serde_json::to_vec(msg).unwrap();
    write_frame(stream, &bytes).await.unwrap();
}

async fn recv(stream: &mut UnixStream) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(45), read_frame(stream))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "spawns a real `claude` child (network + token spend); run with --ignored"]
async fn session_round_trip_drives_real_claude() {
    // Skip cleanly if the binary isn't installed on this machine.
    if resolve_claude().is_err() {
        eprintln!("skipping: `claude` binary not found");
        return;
    }

    // Isolated socket + id store under a temp dir.
    let tmp = std::env::temp_dir().join(format!("nostromo-it-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let socket_path = tmp.join("nostromd.sock");
    let store_path = tmp.join("daemon-sessions.json");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(store_path)));
    let _server = Server::bind(&socket_path, pty_mgr, session_mgr, tmp.join("perri-state")).unwrap();

    // Give the listener a moment to bind.
    tokio::time::sleep(Duration::from_millis(100)).await;

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();

    // Handshake.
    send(
        &mut stream,
        &ClientMsg::Hello {
            client_id: "it-client".into(),
            protocol_version: 3,
        },
    )
    .await;
    assert!(matches!(recv(&mut stream).await, ServerMsg::Welcome { .. }));
    send(&mut stream, &ClientMsg::Subscribe { topics: vec![] }).await;

    // Spawn a fresh session (no remote control, fresh session id).
    send(
        &mut stream,
        &ClientMsg::SessionSpawn {
            tag: "it".into(),
            agent_name: "fred".into(),
            view_name: "ItFocus".into(),
            cwd: Some(tmp.clone()),
            session_id: None,
            remote_control: false,
        },
    )
    .await;
    match recv(&mut stream).await {
        ServerMsg::SessionSpawned { tag, session_id } => {
            assert_eq!(tag, "it");
            assert!(session_id.is_some(), "fresh session id assigned");
        }
        other => panic!("expected SessionSpawned, got {other:?}"),
    }

    // Attach: expect a SessionTurns snapshot then a SessionState.
    send(&mut stream, &ClientMsg::SessionAttach { tag: "it".into() }).await;
    assert!(matches!(
        recv(&mut stream).await,
        ServerMsg::SessionTurns { .. }
    ));
    assert!(matches!(
        recv(&mut stream).await,
        ServerMsg::SessionState { .. }
    ));

    // Send a user message; drive a real turn.
    send(
        &mut stream,
        &ClientMsg::SessionSend {
            tag: "it".into(),
            text: "Reply with exactly the word: pong".into(),
            images: vec![],
        },
    )
    .await;

    // Drain deltas until the turn completes on the result event.
    let mut saw_turn_started = false;
    let mut saw_turn_completed = false;
    for i in 0..200 {
        let msg = recv(&mut stream).await;
        eprintln!("[it] recv #{i}: {}", serde_json::to_string(&msg).unwrap());
        match msg {
            ServerMsg::SessionTurnDelta { tag, delta } => {
                assert_eq!(tag, "it");
                let json = serde_json::to_value(&delta).unwrap();
                match json.get("delta").and_then(|d| d.as_str()) {
                    Some("turn_started") => saw_turn_started = true,
                    Some("turn_completed") => {
                        saw_turn_completed = true;
                        break;
                    }
                    Some("turn_errored") => panic!("turn errored: {json}"),
                    _ => {}
                }
            }
            ServerMsg::SessionState { .. } => {}
            ServerMsg::SessionExited { exit_code, .. } => {
                panic!("session exited before completing a turn (code {exit_code:?})");
            }
            other => panic!("unexpected server message: {other:?}"),
        }
    }

    assert!(saw_turn_started, "expected a turn_started delta");
    assert!(
        saw_turn_completed,
        "expected the turn to complete on the result event"
    );

    // Tear the child down explicitly. std `Child` drop does NOT kill the
    // process, and the blocking stdout reader would otherwise keep the tokio
    // runtime from shutting down (it blocks until claude's stdout EOFs).
    send(
        &mut stream,
        &ClientMsg::SessionControl {
            tag: "it".into(),
            action: nostromo::ipc::protocol::SessionAction::Stop,
        },
    )
    .await;
    tokio::time::sleep(Duration::from_millis(500)).await;

    let _ = std::fs::remove_dir_all(&tmp);
}
