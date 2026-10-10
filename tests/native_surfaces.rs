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
    ClientMsg, FocusMeta, PaneTree, ServerMsg, SessionAction, Topic, PROTOCOL_VERSION,
};
use nostromo::ipc::{PtyManager, Server, SessionManager};
use nostromo::mcp::tools::apply_layout::apply_layout;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use serde_json::json;
use tempfile::TempDir;
use tokio::net::UnixStream;

struct Daemon {
    socket_path: std::path::PathBuf,
    tcp_port: u16,
    registry: Arc<Mutex<PaneRegistry>>,
    state: McpSharedState,
    _server: Server,
    _tmp: TempDir,
}

fn spawn() -> Daemon {
    spawn_with_store(None)
}

/// A daemon whose pane store was written by an older daemon: `store` is the
/// V3 envelope's `trees` object, as JSON.
fn spawn_with_store(store: Option<serde_json::Value>) -> Daemon {
    let tmp = TempDir::new().unwrap();
    let socket_path = tmp.path().join("nostromd.sock");
    if let Some(trees) = store {
        let envelope = json!({ "version": 3, "trees": trees, "bindings": {} });
        std::fs::write(tmp.path().join("panes.json"), envelope.to_string()).unwrap();
    }
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
    // A network listener beside the Unix socket, for the leak test.
    let tcp_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    tcp_listener.set_nonblocking(true).unwrap();
    let tcp_port = tcp_listener.local_addr().unwrap().port();
    server.bind_tcp(
        tokio::net::TcpListener::from_std(tcp_listener).unwrap(),
        pty_mgr,
        Arc::clone(&session_mgr),
        tmp.path().join("perri-state"),
        Arc::clone(&decisions),
    );
    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::clone(&registry),
        session_mgr,
        broadcast_tx: server.tx.clone(),
        perri: PerriDaemonState::default(),
        decisions,
        tickets: Default::default(),
    });
    Daemon { socket_path, tcp_port, registry, state, _server: server, _tmp: tmp }
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
    // An agent built the layout (persisted by an older daemon) before the Mac
    // app announced the focus.
    let d = spawn_with_store(Some(json!({
        "teri": { "kind": "split", "direction": "horizontal",
                  "children": [ {"kind": "leaf", "pane_id": "repl"},
                                {"kind": "leaf", "pane_id": "notes"} ],
                  "ratios": [0.5, 0.5] }
    })));
    let mut client = connect(&d).await;
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

#[tokio::test]
async fn an_agent_cannot_apply_a_layout_that_buries_the_native_pane_in_tabs() {
    let d = spawn();
    let mut client = connect(&d).await;
    push_and_settle(&mut client, vec![meta("teri", "teri"), meta("fred", "fred")]).await;

    for (tag, native) in [("teri", "teri_surface"), ("fred", "fred_hud")] {
        let before = d.registry.lock().unwrap().get(tag).cloned();
        let result = apply_layout(
            &d.state,
            &json!({ "tree": {
                "direction": "vertical",
                "children": [
                    {"tabs": [
                        {"pane": native, "label": "Native"},
                        {"pane": "scratch", "label": "Scratch"}
                    ], "active": "scratch"},
                    {"pane": "repl"}
                ],
                "ratios": [0.6, 0.4]
            }}),
            Some(tag),
        )
        .await;
        assert_eq!(result["error"], "native_pane_required", "{tag}: {result}");
        assert_eq!(d.registry.lock().unwrap().get(tag).cloned(), before, "{tag}: layout unchanged");
    }
}

// ── a fresh spawn keeps the native pane ──────────────────────────────────────
//
// `SessionSpawn` (id nil) used to reset the focus to a bare REPL, silently
// discarding `teri_surface` / `fred_hud` the Mac app was about to host.

/// Spawns run `/bin/sh` in place of `claude` (the child's behaviour is
/// irrelevant; only the layout matters). Set once and never removed, so
/// concurrent tests in this binary cannot race on it.
fn use_stub_claude() {
    std::env::set_var(nostromo::ipc::session_manager::CLAUDE_BIN_ENV, "/bin/sh");
}

async fn spawn_fresh(s: &mut UnixStream, tag: &str) {
    send(
        s,
        &ClientMsg::SessionSpawn {
            tag: tag.into(),
            agent_name: tag.into(),
            view_name: tag.into(),
            cwd: None,
            session_id: None,
            remote_control: false,
        },
    )
    .await;
}

/// Everything the daemon says up to and including `SessionSpawned` for `tag`,
/// plus whatever broadcast frames land by the time two control round trips
/// complete (the broadcast and the targeted reply travel on different channels).
async fn spawn_and_collect(s: &mut UnixStream, tag: &str) -> Vec<ServerMsg> {
    spawn_fresh(s, tag).await;
    let mut frames = Vec::new();
    loop {
        let m = recv(s).await;
        let done = matches!(&m, ServerMsg::SessionSpawned { tag: t, .. } if t == tag);
        let failed = matches!(&m, ServerMsg::Error { .. });
        frames.push(m);
        assert!(!failed, "spawn failed: {frames:?}");
        if done {
            break;
        }
    }
    frames.extend(sync(s).await);
    tokio::time::sleep(Duration::from_millis(50)).await;
    frames.extend(sync(s).await);
    frames
}

/// What a client connecting right now is told about `tag`'s layout.
async fn replayed_layout(d: &Daemon, tag: &str) -> Option<PaneTree> {
    let mut s = UnixStream::connect(&d.socket_path).await.unwrap();
    send(&mut s, &ClientMsg::Hello { client_id: "replay-probe".into(), protocol_version: PROTOCOL_VERSION }).await;
    assert!(matches!(recv(&mut s).await, ServerMsg::Welcome { .. }));
    send(&mut s, &ClientMsg::Subscribe { topics: vec![Topic::Layout], renders_decisions: false }).await;
    let frames = sync(&mut s).await;
    layouts_for(&frames, tag).last().map(|t| (*t).clone())
}

const NATIVE: [(&str, &str); 2] = [("teri", "teri_surface"), ("fred", "fred_hud")];

#[tokio::test]
async fn a_fresh_spawn_keeps_the_native_pane_for_a_client_that_connects_afterwards() {
    use_stub_claude();
    for (tag, native) in NATIVE {
        let d = spawn();
        let mut client = connect(&d).await;

        spawn_and_collect(&mut client, tag).await;

        let replayed = replayed_layout(&d, tag).await.unwrap_or_else(|| panic!("{tag}: no layout replayed"));
        assert_eq!(ids(&replayed), vec![native, "repl"], "{tag}: replay shows the native pane");
        assert_eq!(registry_ids(&d, tag), vec![native, "repl"], "{tag}: registry agrees");
    }
}

#[tokio::test]
async fn a_fresh_spawn_announces_the_native_layout_to_connected_clients() {
    use_stub_claude();
    for (tag, native) in NATIVE {
        let d = spawn();
        let mut client = connect(&d).await;

        let frames = spawn_and_collect(&mut client, tag).await;

        let layouts = layouts_for(&frames, tag);
        assert!(!layouts.is_empty(), "{tag}: spawn broadcasts a FocusLayout: {frames:?}");
        assert_eq!(ids(layouts.last().unwrap()), vec![native, "repl"], "{tag}");
    }
}

#[tokio::test]
async fn spawning_after_new_session_keeps_the_native_pane_and_announces_it_again() {
    use_stub_claude();
    for (tag, native) in NATIVE {
        let d = spawn();
        let mut client = connect(&d).await;
        spawn_and_collect(&mut client, tag).await;

        // "New session": drop the session id and stop the child, then spawn
        // fresh (id nil), as the Mac app does.
        send(&mut client, &ClientMsg::SessionControl { tag: tag.into(), action: SessionAction::NewSession }).await;
        sync(&mut client).await;
        let frames = spawn_and_collect(&mut client, tag).await;

        let layouts = layouts_for(&frames, tag);
        assert!(!layouts.is_empty(), "{tag}: the second fresh spawn is announced too: {frames:?}");
        assert_eq!(ids(layouts.last().unwrap()), vec![native, "repl"], "{tag}");
        let replayed = replayed_layout(&d, tag).await.unwrap_or_else(|| panic!("{tag}: no layout replayed"));
        assert_eq!(ids(&replayed), vec![native, "repl"], "{tag}: replay after new_session + spawn");
    }
}

#[tokio::test]
async fn a_fresh_spawn_of_an_ordinary_focus_is_a_bare_repl_and_gets_no_native_pane() {
    use_stub_claude();
    let d = spawn();
    let mut client = connect(&d).await;

    for tag in ["teri-x", "cody-x"] {
        spawn_and_collect(&mut client, tag).await;
        assert_eq!(registry_ids(&d, tag), vec!["repl"], "{tag}");
    }
}

// ── a network peer never sees the native layout ──────────────────────────────

#[tokio::test]
async fn a_fresh_spawn_of_teri_or_fred_does_not_announce_its_layout_to_a_network_peer() {
    use_stub_claude();
    let d = spawn();
    let mut client = connect(&d).await;

    // A TCP peer subscribed to layouts.
    let mut tcp = tokio::net::TcpStream::connect(("127.0.0.1", d.tcp_port)).await.unwrap();
    write_frame(
        &mut tcp,
        &serde_json::to_vec(&ClientMsg::Hello {
            client_id: "native-surfaces-tcp".into(),
            protocol_version: PROTOCOL_VERSION,
        })
        .unwrap(),
    )
    .await
    .unwrap();
    assert!(matches!(recv_any(&mut tcp).await, ServerMsg::Welcome { .. }));
    write_frame(
        &mut tcp,
        &serde_json::to_vec(&ClientMsg::Subscribe { topics: vec![Topic::Layout, Topic::Focuses], renders_decisions: false })
            .unwrap(),
    )
    .await
    .unwrap();

    for (tag, _) in NATIVE {
        let frames = spawn_and_collect(&mut client, tag).await;
        assert!(!layouts_for(&frames, tag).is_empty(), "control: the local client is told: {frames:?}");
    }

    // Ping, then read to the Pong: everything the peer was going to be sent is before it.
    write_frame(&mut tcp, &serde_json::to_vec(&ClientMsg::Ping).unwrap()).await.unwrap();
    loop {
        match recv_any(&mut tcp).await {
            ServerMsg::Pong => break,
            ServerMsg::FocusLayout { tag, .. } => panic!("the {tag} layout reached a network peer"),
            _ => {}
        }
    }
}

async fn recv_any<S: tokio::io::AsyncRead + Unpin>(s: &mut S) -> ServerMsg {
    let bytes = tokio::time::timeout(Duration::from_secs(5), read_frame(s))
        .await
        .expect("timed out waiting for a server frame")
        .expect("read frame");
    serde_json::from_slice(&bytes).unwrap()
}
