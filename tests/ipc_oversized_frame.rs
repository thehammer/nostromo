//! An oversized broadcast frame must not kill client connections.
//!
//! `write_frame` refuses a body over `MAX_FRAME_LEN`. A broadcast that big
//! (e.g. a `TeriState` carrying huge todo bodies) used to make the server end
//! the connection of every subscribed client, and the Mac app reconnected into
//! the same retained frame forever. The contract: the oversized frame is
//! dropped (with a log), the connection stays up and later frames still flow,
//! and a client that connects while that frame is retained still gets a normal
//! welcome and a working connection.
//!
//! The oversized frame is built on purpose WITHOUT `TeriTodosSnapshot::for_wire`
//! so this guards the server itself, independent of the producers' bounding.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::data::fred_calendar::CalendarSnapshot;
use nostromo::data::fred_mailbox::MailboxSnapshot;
use nostromo::data::teri_todos::{TeriTodo, TeriTodosSnapshot};
use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{ClientMsg, ServerMsg, Topic, MAX_FRAME_LEN, PROTOCOL_VERSION};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use tempfile::TempDir;
use tokio::net::UnixStream;

struct Daemon {
    socket_path: std::path::PathBuf,
    server: Server,
    _tmp: TempDir,
}

fn spawn() -> Daemon {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");
    let registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(tmp.path().join("panes.json"))));
    let session_mgr =
        Arc::new(Mutex::new(SessionManager::with_store_path(tmp.path().join("sessions.json"))));
    session_mgr.lock().unwrap().configure_mcp_bridge(
        registry,
        tmp.path().join("mcp.sock"),
        tmp.path().join("mcp-config.json"),
    );
    let pty_mgr = Arc::new(Mutex::new(PtyManager::new()));
    let decisions = Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default()));
    let server = Server::bind(
        &socket_path,
        pty_mgr,
        session_mgr,
        tmp.path().join("perri-state"),
        decisions,
    )
    .unwrap();
    Daemon { socket_path, server, _tmp: tmp }
}

async fn send(s: &mut UnixStream, msg: &ClientMsg) {
    write_frame(s, &serde_json::to_vec(msg).unwrap()).await.unwrap();
}

/// Next frame, or a description of why the connection is no longer usable.
async fn try_recv(s: &mut UnixStream) -> Result<ServerMsg, String> {
    match tokio::time::timeout(Duration::from_secs(5), read_frame(s)).await {
        Err(_) => Err("timed out after 5s waiting for a server frame (connection hung?)".into()),
        Ok(Err(e)) => Err(format!("the connection was closed by the server: {e}")),
        Ok(Ok(bytes)) => Ok(serde_json::from_slice(&bytes).unwrap()),
    }
}

/// Ping and read to the Pong; returns every frame before it.
async fn sync(s: &mut UnixStream) -> Result<Vec<ServerMsg>, String> {
    send(s, &ClientMsg::Ping).await;
    let mut frames = Vec::new();
    loop {
        match try_recv(s).await? {
            ServerMsg::Pong => return Ok(frames),
            other => frames.push(other),
        }
    }
}

/// Connect, subscribe to `topics`; returns the stream and whatever was
/// replayed before the first Pong.
async fn connect(d: &Daemon, topics: Vec<Topic>) -> (UnixStream, Vec<ServerMsg>) {
    let mut s = UnixStream::connect(&d.socket_path).await.unwrap();
    send(&mut s, &ClientMsg::Hello { client_id: "oversized-frame-it".into(), protocol_version: PROTOCOL_VERSION })
        .await;
    match try_recv(&mut s).await {
        Ok(ServerMsg::Welcome { .. }) => {}
        other => panic!("expected Welcome, got {other:?}"),
    }
    send(&mut s, &ClientMsg::Subscribe { topics, renders_decisions: false }).await;
    let replay = sync(&mut s).await.unwrap_or_else(|e| panic!("subscribe sync failed: {e}"));
    (s, replay)
}

fn todo_titled(id: i64, title: String) -> TeriTodo {
    TeriTodo {
        id,
        title,
        status: "open".into(),
        priority: 2,
        due_date: None,
        jira_key: None,
        body: None,
    }
}

fn teri_state(title: String) -> ServerMsg {
    ServerMsg::TeriState {
        todos: TeriTodosSnapshot {
            generated_at: Some(chrono::Utc::now()),
            items: vec![todo_titled(1, title)],
            ..Default::default()
        },
    }
}

/// A `TeriState` whose JSON is over `MAX_FRAME_LEN`.
fn oversized_teri_state() -> ServerMsg {
    let msg = teri_state("x".repeat(5 * 1024 * 1024));
    assert!(serde_json::to_vec(&msg).unwrap().len() > MAX_FRAME_LEN, "fixture must be oversized");
    msg
}

fn title_of(msg: &ServerMsg) -> Option<String> {
    match msg {
        ServerMsg::TeriState { todos } => todos.items.first().map(|t| t.title.clone()),
        _ => None,
    }
}

#[tokio::test]
async fn an_oversized_broadcast_is_dropped_and_the_subscribed_connection_stays_up() {
    let d = spawn();
    let (mut client, _) = connect(&d, vec![Topic::Teri]).await;

    d.server.tx.send(oversized_teri_state()).unwrap();
    d.server.tx.send(teri_state("small after the big one".into())).unwrap();

    // The very next TeriState on the SAME connection is the small one.
    let got = loop {
        match try_recv(&mut client).await {
            Ok(msg) if matches!(msg, ServerMsg::TeriState { .. }) => break msg,
            Ok(_) => continue,
            Err(why) => panic!("the client must survive an oversized frame, but {why}"),
        }
    };
    assert_eq!(title_of(&got).as_deref(), Some("small after the big one"));

    // And the connection still answers requests.
    sync(&mut client).await.unwrap_or_else(|why| panic!("Ping/Pong after the oversized frame failed: {why}"));
}

#[tokio::test]
async fn a_client_connecting_while_an_oversized_frame_is_retained_still_gets_a_working_connection() {
    let d = spawn();

    // The oversized TeriState goes into the retained cache; a FredState after it
    // marks when the cache has caught up (it is the later retained write).
    d.server.tx.send(oversized_teri_state()).unwrap();
    d.server
        .tx
        .send(ServerMsg::FredState { mailbox: MailboxSnapshot::default(), calendar: CalendarSnapshot::default() })
        .unwrap();

    // Connect afresh until the retained Fred frame is replayed (bounded retry).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let (mut client, replay) = connect(&d, vec![Topic::Teri, Topic::Fred]).await;
        if replay.iter().any(|m| matches!(m, ServerMsg::FredState { .. })) {
            // Welcome arrived and the replay did not hang (connect would have
            // panicked); the connection is usable.
            sync(&mut client)
                .await
                .unwrap_or_else(|why| panic!("Ping/Pong after the retained replay failed: {why}"));
            return;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "the retained cache never caught up (no FredState replayed)"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
