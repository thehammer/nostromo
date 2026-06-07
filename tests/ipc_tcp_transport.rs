//! Integration tests for the TCP IPC transport.
//!
//! Validates that `Server::bind_tcp` wires up the same `handle_client` loop
//! used by the Unix socket path, so iOS clients connecting over TCP complete
//! the identical `Hello` → `Welcome` → `Subscribe` → `SessionList` →
//! `SessionListResp` handshake.

use std::sync::{Arc, Mutex};

use nostromo::ipc::{
    codec::{read_frame, write_frame},
    protocol::{ClientMsg, ServerMsg, Topic, PROTOCOL_VERSION},
    server::Server,
    PtyManager, SessionManager,
};
use tempfile::TempDir;
use tokio::net::TcpStream;

// ── helpers ───────────────────────────────────────────────────────────────────

/// Bind a `Server` on a temp Unix socket and attach a TCP listener on an
/// ephemeral port.  Returns `(Server, bound_tcp_port, _tmp_dir)`.
async fn spawn_server() -> (Server, u16, TempDir) {
    let tmp = TempDir::new().expect("tempdir");
    let socket_path = tmp.path().join("test.sock");

    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let session_mgr = Arc::new(Mutex::new(SessionManager::new()));

    let server = Server::bind(&socket_path, Arc::clone(&pty_mgr), Arc::clone(&session_mgr))
        .expect("bind unix socket");

    // Bind on an ephemeral port so tests don't collide.
    let tcp_listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind tcp listener");
    let port = tcp_listener
        .local_addr()
        .expect("local addr")
        .port();

    server.bind_tcp(tcp_listener, Arc::clone(&pty_mgr), Arc::clone(&session_mgr));

    (server, port, tmp)
}

/// Run the Hello/Welcome/Subscribe handshake over a `TcpStream`.
/// Returns the stream after the handshake is complete.
async fn do_handshake(mut stream: &mut TcpStream) {
    // → Hello
    let hello = ClientMsg::Hello {
        client_id: "test-ios-client".to_string(),
        protocol_version: PROTOCOL_VERSION,
    };
    write_frame(&mut stream, &serde_json::to_vec(&hello).unwrap())
        .await
        .unwrap();

    // ← Welcome
    let welcome_bytes = read_frame(&mut stream).await.unwrap();
    let welcome: ServerMsg = serde_json::from_slice(&welcome_bytes).unwrap();
    match welcome {
        ServerMsg::Welcome { protocol_version, .. } => {
            assert_eq!(protocol_version, PROTOCOL_VERSION);
        }
        other => panic!("expected Welcome, got {other:?}"),
    }

    // → Subscribe (no topics — we only care about targeted responses)
    let sub = ClientMsg::Subscribe { topics: vec![] };
    write_frame(&mut stream, &serde_json::to_vec(&sub).unwrap())
        .await
        .unwrap();
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn tcp_handshake_completes() {
    let (_server, port, _tmp) = spawn_server().await;

    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("TCP connect");

    do_handshake(&mut stream).await;
    // If we reach here the three-way handshake succeeded.
}

#[tokio::test]
async fn tcp_session_list_returns_empty_resp() {
    let (_server, port, _tmp) = spawn_server().await;

    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("TCP connect");

    do_handshake(&mut stream).await;

    // → SessionList
    let list_req = ClientMsg::SessionList;
    write_frame(&mut stream, &serde_json::to_vec(&list_req).unwrap())
        .await
        .unwrap();

    // ← SessionListResp  (daemon has no sessions, so the list is empty)
    let resp_bytes = read_frame(&mut stream).await.unwrap();
    let resp: ServerMsg = serde_json::from_slice(&resp_bytes).unwrap();

    match resp {
        ServerMsg::SessionListResp { sessions } => {
            assert!(
                sessions.is_empty(),
                "expected 0 sessions from a fresh daemon, got {sessions:?}"
            );
        }
        other => panic!("expected SessionListResp, got {other:?}"),
    }
}

#[tokio::test]
async fn tcp_and_unix_share_broadcast() {
    // Verify that a broadcast sent via server.broadcast() reaches a TCP client.
    let (server, port, _tmp) = spawn_server().await;

    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("TCP connect");

    // Subscribe to Activity topic so the broadcast passes the topic filter.
    let hello = ClientMsg::Hello {
        client_id: "broadcast-test".to_string(),
        protocol_version: PROTOCOL_VERSION,
    };
    write_frame(&mut stream, &serde_json::to_vec(&hello).unwrap())
        .await
        .unwrap();
    let _welcome_bytes = read_frame(&mut stream).await.unwrap(); // discard Welcome

    let sub = ClientMsg::Subscribe {
        topics: vec![Topic::Activity],
    };
    write_frame(&mut stream, &serde_json::to_vec(&sub).unwrap())
        .await
        .unwrap();

    // Give the server a moment to register the subscriber.
    tokio::time::sleep(tokio::time::Duration::from_millis(20)).await;

    // Broadcast a Pong (matches any topic filter since it's not an Activity/Mother msg).
    server.broadcast(ServerMsg::Pong);

    // The TCP client should receive it.
    let recv_bytes = read_frame(&mut stream).await.unwrap();
    let recv: ServerMsg = serde_json::from_slice(&recv_bytes).unwrap();
    assert!(
        matches!(recv, ServerMsg::Pong),
        "expected Pong broadcast, got {recv:?}"
    );
}

#[tokio::test]
async fn tcp_rejects_old_protocol_version() {
    let (_server, port, _tmp) = spawn_server().await;

    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("TCP connect");

    // Send Hello with an ancient protocol version (0).
    let hello = ClientMsg::Hello {
        client_id: "old-client".to_string(),
        protocol_version: 0,
    };
    write_frame(&mut stream, &serde_json::to_vec(&hello).unwrap())
        .await
        .unwrap();

    // Daemon sends an Error then closes.
    let err_bytes = read_frame(&mut stream).await.unwrap();
    let err: ServerMsg = serde_json::from_slice(&err_bytes).unwrap();
    assert!(
        matches!(err, ServerMsg::Error { .. }),
        "expected Error for old protocol, got {err:?}"
    );
}
