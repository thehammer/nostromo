//! Teri and Fred native surfaces, over a real daemon socket.
//!
//! When the Mac app pushes its focus registry, the daemon gives the built-in
//! `teri` focus a `teri_surface` pane and the built-in `fred` focus a
//! `fred_hud` pane beside the REPL, and tells subscribed clients with one
//! `FocusLayout` each. The native pane cannot be dropped by an agent's
//! `apply_layout`; an agent-built layout is wrapped rather than discarded.
//!
//! "Nothing new was sent" is proven with a control frame: a `Pong` requested
//! after the second push is produced by the connection's main loop, so any
//! layout frame the push was going to cause has already been written.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use nostromo::ipc::codec::{read_frame, write_frame};
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{
    ClientMsg, FocusMeta, PaneTree, ServerMsg, Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::tools::apply_layout::apply_layout;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::json;
use tempfile::TempDir;
use tokio::net::UnixStream;

struct Daemon {
    socket_path: std::path::PathBuf,
    registry: Arc<Mutex<PaneRegistry>>,
    state: McpSharedState,
    _server: Server,
    _tmp: TempDir,
}

fn spawn() -> Daemon {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");
    let registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(tmp.path().join("panes.json"))));
    let session_mgr =
        Arc::new(Mutex::new(SessionManager::with_store_path(tmp.path().join("sessions.json"))));
    session_mgr.lock().unwrap().configure_mcp_bridge(
        Arc::clone(&registry),
        tmp.path().join("mcp.sock"),
        tmp.path().join("mcp-config.json"),
    );
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
    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::clone(&registry),
        session_mgr,
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions,
        tickets: Default::default(),
    });
    Daemon { socket_path, registry, state, _server: server, _tmp: tmp }
}

async fn send(s: &mut UnixStream, msg: &ClientMsg) {
    write_frame(s, &serde_json::to_vec(msg).unwrap()).await.unwrap();
}

async fn recv(s: &mut UnixStream) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(s))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}

async fn connect(d: &Daemon) -> UnixStream {
    let mut s = UnixStream::connect(&d.socket_path).await.unwrap();
    send(&mut s, &ClientMsg::Hello { client_id: "native-surfaces-it".into(), protocol_version: PROTOCOL_VERSION })
        .await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }));
    send(&mut s, &ClientMsg::Subscribe { topics: vec![Topic::Layout, Topic::Focuses], renders_decisions: false }).await;
    sync(&mut s).await;
    s
}

/// Ping and read to the Pong; returns every frame before it.
async fn sync(s: &mut UnixStream) -> Vec<ServerMsg> {
    send(s, &ClientMsg::Ping).await;
    let mut frames = Vec::new();
    loop {
        match recv(s).await {
            ServerMsg::Pong => return frames,
            other => frames.push(other),
        }
    }
}

/// Push `focuses` and read every broadcast frame up to the resulting
/// `FocusRegistryUpdated`. The daemon broadcasts any seeded `FocusLayout`
/// *before* that frame, so the returned frames are exactly the layouts this
/// push caused (and nothing later can sneak in ahead of the control frame).
async fn push_and_settle(s: &mut UnixStream, focuses: Vec<FocusMeta>) -> Vec<ServerMsg> {
    push(s, focuses).await;
    let mut frames = Vec::new();
    loop {
        let m = recv(s).await;
        let done = matches!(m, ServerMsg::FocusRegistryUpdated { .. });
        frames.push(m);
        if done {
            return frames;
        }
    }
}

fn meta(tag: &str, agent: &str) -> FocusMeta {
    FocusMeta {
        tag: tag.into(),
        display_name: tag.into(),
        agent_name: agent.into(),
        project_name: None,
        org: None,
        is_built_in: true,
        session_summary: None,
        label: None,
        project_path: None,
        select_for_client: None,
    }
}

async fn push(s: &mut UnixStream, focuses: Vec<FocusMeta>) {
    send(s, &ClientMsg::FocusRegistryPush { focuses }).await;
}

fn layouts_for<'a>(frames: &'a [ServerMsg], tag: &str) -> Vec<&'a PaneTree> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::FocusLayout { tag: t, tree, .. } if t == tag => Some(tree),
            _ => None,
        })
        .collect()
}

fn ids(tree: &PaneTree) -> Vec<String> {
    tree.pane_ids()
}

fn registry_ids(d: &Daemon, tag: &str) -> Vec<String> {
    d.registry.lock().unwrap().pane_ids(tag)
}

#[tokio::test]
async fn pushing_the_registry_gives_teri_and_fred_their_native_panes_beside_the_repl() {
    let d = spawn();
    let mut client = connect(&d).await;

    let frames = push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;

    let teri = layouts_for(&frames, "teri");
    let fred = layouts_for(&frames, "fred");
    assert_eq!(teri.len(), 1, "exactly one FocusLayout for teri: {frames:?}");
    assert_eq!(fred.len(), 1, "exactly one FocusLayout for fred: {frames:?}");
    assert_eq!(ids(teri[0]), vec!["teri_surface", "repl"]);
    assert_eq!(ids(fred[0]), vec!["fred_hud", "repl"]);
    assert_eq!(registry_ids(&d, "teri"), vec!["teri_surface", "repl"]);
    assert_eq!(registry_ids(&d, "fred"), vec!["fred_hud", "repl"]);
}

#[tokio::test]
async fn a_second_push_sends_no_new_layout() {
    let d = spawn();
    let mut client = connect(&d).await;
    let first = push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;
    assert!(!layouts_for(&first, "teri").is_empty());

    let second = push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;

    assert!(
        !second.iter().any(|m| matches!(m, ServerMsg::FocusLayout { .. })),
        "an already-seeded focus is not re-announced: {second:?}"
    );
}

#[tokio::test]
async fn an_agent_cannot_apply_a_layout_that_drops_the_native_pane() {
    let d = spawn();
    let mut client = connect(&d).await;
    push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;

    for (tag, native) in [("teri", "teri_surface"), ("fred", "fred_hud")] {
        let before = registry_ids(&d, tag);
        let result = apply_layout(
            &d.state,
            &json!({ "tree": {
                "direction": "vertical",
                "children": [
                    {"pane": "scratch"},
                    {"pane": "repl"}
                ],
                "ratios": [0.5, 0.5]
            }}),
            Some(tag),
        )
        .await;
        assert_eq!(result["error"], "native_pane_required", "{tag}: {result}");
        assert_eq!(registry_ids(&d, tag), before, "{tag}: layout unchanged");
        assert!(before.iter().any(|p| p == native));
    }

    // Nothing was announced for the refused layouts.
    let control = push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;
    assert!(!control.iter().any(|m| matches!(m, ServerMsg::FocusLayout { .. })), "{control:?}");
}

#[tokio::test]
async fn an_agent_can_apply_a_layout_that_keeps_the_native_pane() {
    let d = spawn();
    let mut client = connect(&d).await;
    push_and_settle(&mut client, vec![meta("teri", "teri")]).await;

    let result = apply_layout(
        &d.state,
        &json!({ "tree": {
            "direction": "vertical",
            "children": [
                {"pane": "teri_surface"},
                {"pane": "repl"}
            ],
            "ratios": [0.7, 0.3]
        }}),
        Some("teri"),
    )
    .await;
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(registry_ids(&d, "teri"), vec!["teri_surface", "repl"]);
}

#[tokio::test]
async fn an_agent_built_layout_is_wrapped_when_the_focus_registry_is_pushed() {
    let d = spawn();
    let mut client = connect(&d).await;
    // An agent built the layout before the Mac app announced the focus.
    {
        let mut reg = d.registry.lock().unwrap();
        reg.get_or_init("teri");
        reg.create_pane("teri", "notes", nostromo::ipc::pane_registry::SplitPosition::Right, "repl").unwrap();
    }
    let before = registry_ids(&d, "teri");

    let frames = push_and_settle(&mut client, vec![meta("teri", "teri")]).await;

    let layouts = layouts_for(&frames, "teri");
    assert_eq!(layouts.len(), 1, "{frames:?}");
    let after = ids(layouts[0]);
    assert_eq!(after.first().map(String::as_str), Some("teri_surface"));
    for id in &before {
        assert!(after.contains(id), "{id} survives the wrap: {after:?}");
    }
    assert_eq!(registry_ids(&d, "teri"), after);
}

#[tokio::test]
async fn other_focuses_are_not_given_native_panes() {
    let d = spawn();
    let mut client = connect(&d).await;
    let frames = push_and_settle(&mut client, vec![meta("cody-x", "cody"), meta("my-mail", "fred")]).await;

    assert!(layouts_for(&frames, "cody-x").is_empty(), "{frames:?}");
    assert!(layouts_for(&frames, "my-mail").is_empty(), "{frames:?}");
}
