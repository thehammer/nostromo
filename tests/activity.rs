//! Socket-level coverage for the ambient activity feed's daemon protocol,
//! mirroring the raw-socket harness pattern in `tests/pane_source_liveness.rs`.

use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use std::sync::{Arc, Mutex};
use tempfile::TempDir;
use tokio::net::UnixStream;

// ── helpers (mirrors tests/pane_source_liveness.rs) ──────────────────────────

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
            client_id: "activity-it".into(),
            protocol_version: 4,
        },
    )
    .await;
    assert!(matches!(recv(stream).await, ServerMsg::Welcome { .. }));
    send(stream, &ClientMsg::Subscribe { topics }).await;
}

// ── tests ─────────────────────────────────────────────────────────────────────

/// A client subscribed to `Topic::Activity` that sends
/// `ClientMsg::ActivitySnapshotRequest` must receive a
/// `ServerMsg::ActivitySnapshot` in response.
#[tokio::test]
async fn activity_snapshot_request_yields_an_activity_snapshot() {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");

    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        tmp.path().join("sessions.json"),
    )));
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

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Activity]).await;

    // The handshake's own attach-replay sends one ActivitySnapshot per known
    // focus (none here) followed by one ActivityHealth — drain those first so
    // the explicit request's reply isn't confused with the replay.
    let health = recv(&mut stream).await;
    assert!(matches!(health, ServerMsg::ActivityHealth { .. }), "{health:?}");

    send(
        &mut stream,
        &ClientMsg::ActivitySnapshotRequest { tag: "cody-1".into() },
    )
    .await;

    let msg = recv(&mut stream).await;
    match msg {
        ServerMsg::ActivitySnapshot { tag, .. } => assert_eq!(tag, "cody-1"),
        other => panic!("expected ActivitySnapshot, got {other:?}"),
    }

    drop(server);
}
