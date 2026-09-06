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
///
/// Thin wrapper over [`serve_with_session_mgr`] that drops the shared
/// `SessionManager` handle: every test in this file except the D8b one below
/// reaches a focus the way the Mac does (`FocusRegistryPush`) and never needs
/// it directly.
async fn serve() -> (std::path::PathBuf, std::path::PathBuf, TempDir, Server) {
    let (socket_path, perri_state_dir, tmp, server, _session_mgr) = serve_with_session_mgr().await;
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

/// D10 for a **Mac-created** focus: every phase here arrives as a
/// `FocusRegistryPush`, so this is the path a focus from the Mac's
/// `focuses.json` takes. A tag can be reused on that path too (the operator
/// names a focus the same thing twice), and when it is, the pin must be
/// genuinely deleted rather than tombstoned or the new focus inherits the dead
/// one's PR.
///
/// It does **not** cover `nostromo.create_focus`, whose focuses enter through
/// `SessionManager::add_or_update_focus` and carry an eviction exemption this
/// path never touches — that is
/// [`a_daemon_created_focus_recreated_under_a_reused_tag_inherits_no_pin`]
/// below, and it is the case where tag reuse is guaranteed rather than merely
/// possible.
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

// ── W7 — D8b: the focus whose tag reuse is *guaranteed* ──────────────────────

/// Same as [`serve`], but also hands back the shared `SessionManager` the
/// server holds, so a test can register a focus the way an agent does rather
/// than the way the Mac does.
///
/// `nostromo.create_focus` does not push a registry — it calls
/// `SessionManager::add_or_update_focus` on this very `Arc` and broadcasts
/// `FocusCreated` (`src/mcp/tools/create_focus.rs`). Reaching the same state
/// through `FocusRegistryPush` would be a different code path with a
/// different eviction story, which is exactly the confusion this file exists
/// to pin down.
async fn serve_with_session_mgr() -> (
    std::path::PathBuf,
    std::path::PathBuf,
    TempDir,
    Server,
    Arc<Mutex<SessionManager>>,
) {
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
    (socket_path, perri_state_dir, tmp, server, session_mgr)
}

/// D10, for the class of focus where tag reuse is not a hazard but a
/// certainty: the agent-created one.
///
/// `nostromo.create_focus` derives its tag deterministically from
/// `(agent, title)`, so closing "cody / core-1234" and asking for it again
/// returns the identical tag. Such a focus enters the registry through
/// `add_or_update_focus`, never through a Mac push — and it is removed the
/// only way the daemon ever learns of a removal, by dropping out of the
/// pushes. Once the Mac has acknowledged the focus by pushing it, its removal
/// must be honoured on the ordinary two-push rule and its pin deleted, or the
/// next `create_focus` for the same title hands the new focus the dead one's
/// PR.
#[tokio::test]
async fn a_daemon_created_focus_recreated_under_a_reused_tag_inherits_no_pin() {
    let (socket_path, state_dir, _tmp, _server, session_mgr) = serve_with_session_mgr().await;
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    let reused = "cody-core-1234";

    // Born the way an agent-created focus is actually born.
    session_mgr
        .lock()
        .unwrap()
        .add_or_update_focus(focus_meta(reused));

    // It picks up a PR to review.
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
    assert!(
        wait_until(|| pin_of(&state_dir, reused).exists()).await,
        "the daemon-created focus must have a pin before there is anything to evict"
    );

    // The Mac learns of it (it received `FocusCreated`) and starts carrying it
    // in its pushes. From here on it is an ordinary focus.
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri"), focus_meta(reused)],
        },
    )
    .await;

    // Closed, and confirmed closed by a second push.
    for _ in 0..2 {
        send(
            &mut stream,
            &ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("perri")],
            },
        )
        .await;
    }

    assert!(
        wait_until(|| !pin_of(&state_dir, reused).exists()).await,
        "an agent-created focus the Mac has since dropped must lose its pin like any \
         other; while it keeps one, the next create_focus for the same title reuses \
         the tag and inherits a dead focus's PR"
    );
    // Recreated under the very same deterministic tag, the same way.
    session_mgr
        .lock()
        .unwrap()
        .add_or_update_focus(focus_meta(reused));

    assert!(
        !wait_until(|| pin_of(&state_dir, reused).exists()).await,
        "a recreated focus reusing a dead focus's tag must start with no PR under review"
    );
}

// ── W7 — D8a: the empty push, and the backstop that must respect it ──────────

/// An empty push is what a client sends before it has loaded anything — the
/// D8a reconnect guarantee is that it evicts nothing. That guarantee has to
/// hold for the `retain_pins` backstop as well as for the departure loop,
/// and the case that separates the two is an agent-created focus outstanding
/// at the moment the Mac reconnects.
///
/// After an empty push the daemon's registry is empty, so the only tag it can
/// still name is the unacknowledged daemon-created one. If the backstop is
/// willing to reconcile against that, it is handed a "live" set of exactly one
/// tag and deletes every Mac-created focus's pin — the reconnect hazard the
/// whole two-push rule exists to prevent, arriving through the back door.
#[tokio::test]
async fn an_empty_push_leaves_every_pin_on_disk_while_a_daemon_created_focus_is_outstanding() {
    let (socket_path, state_dir, _tmp, _server, session_mgr) = serve_with_session_mgr().await;
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    let agent_tag = "cody-core-1234";

    // Two ordinary, agreeing pushes: the daemon now has a complete picture and
    // the backstop is armed.
    for _ in 0..2 {
        send(
            &mut stream,
            &ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("perri"), focus_meta("cody")],
            },
        )
        .await;
    }

    // Both Mac-created focuses pick up a PR to review.
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
        "both Mac-created focuses must have a pin before there is anything to lose"
    );

    // An agent calls `nostromo.create_focus`. The Mac has not pushed this tag
    // back yet, so it is still carrying its eviction exemption.
    session_mgr
        .lock()
        .unwrap()
        .add_or_update_focus(focus_meta(agent_tag));
    send(
        &mut stream,
        &ClientMsg::PerriAction {
            action: "load_pr".into(),
            pr_number: Some(7),
            repo: Some("Carefeed/admin-portal".into()),
            tag: Some(agent_tag.into()),
        },
    )
    .await;
    assert!(
        wait_until(|| pin_of(&state_dir, agent_tag).exists()).await,
        "the agent-created focus must have a pin too"
    );

    // The Mac reconnects and pushes before it has loaded anything.
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush { focuses: vec![] },
    )
    .await;

    // Give the daemon the same window a real eviction gets, so this asserts
    // "nothing was deleted" rather than "we looked too early".
    let tags = ["perri", "cody", agent_tag];
    assert!(
        !wait_until(|| tags.iter().any(|t| !pin_of(&state_dir, t).exists())).await,
        "an empty push must evict nothing: pins on disk after it were \
         perri={}, cody={}, {agent_tag}={}",
        pin_of(&state_dir, "perri").exists(),
        pin_of(&state_dir, "cody").exists(),
        pin_of(&state_dir, agent_tag).exists()
    );
    for tag in tags {
        assert!(
            pin_of(&state_dir, tag).exists(),
            "{tag}'s pin must survive an empty push — the operator's review is \
             still in progress and the client has said nothing about it"
        );
    }
}

// ── W7 — f4a: the backstop, isolated from the departure loop ─────────────────

/// A pin the departure loop can never reach: the focus went away while this
/// daemon was not running, so no push it will ever see mentions that tag. The
/// tag is never in the registry, therefore never in `pending_departures`,
/// therefore never in `departed` — the only mechanism that can collect it is
/// the `retain_pins` backstop.
///
/// That backstop was once documented but dead (it was wired up for real only in
/// `5afd21d`), and nothing failed while it was missing. This test is what makes
/// its removal loud: it must go red if the daemon stops reconciling the pins on
/// disk against the focuses it believes exist.
///
/// The sweep is asserted only after **two agreeing non-empty pushes**, because
/// that is the evidence standard D8a demands: a reconnecting client's first
/// push may be partial, and collecting on the strength of it would delete a
/// live focus's review.
#[tokio::test]
async fn a_pin_left_behind_while_the_daemon_was_down_is_swept_once_two_pushes_agree() {
    let (socket_path, state_dir, _tmp, _server) = serve().await;
    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    // A pin for a focus this daemon has never heard of — written straight to
    // disk, the way a previous daemon run left it behind.
    let ghost = "cody-core-9999";
    nostromo::data::perri_current_pr::write_pointer(
        &state_dir,
        ghost,
        4526,
        "Carefeed/admin-portal",
        None,
    )
    .unwrap();
    // A pin for a focus that *is* live, to prove the sweep is targeted rather
    // than a wipe.
    nostromo::data::perri_current_pr::write_pointer(&state_dir, "perri", 42, "acme/anvil", None)
        .unwrap();
    assert!(
        pin_of(&state_dir, ghost).exists() && pin_of(&state_dir, "perri").exists(),
        "both pins must be on disk before there is anything to reconcile"
    );

    // Two agreeing, non-empty pushes. Neither names the ghost — nothing ever
    // will — so `departed` is empty on both of them.
    for _ in 0..2 {
        send(
            &mut stream,
            &ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("perri"), focus_meta("cody")],
            },
        )
        .await;
    }

    assert!(
        wait_until(|| !pin_of(&state_dir, ghost).exists()).await,
        "a pin for a focus that no longer exists must be swept once the daemon can \
         vouch for a complete picture; no push will ever name this tag, so while it \
         survives the next create_focus that reuses the tag inherits a dead focus's PR"
    );
    assert!(
        pin_of(&state_dir, "perri").exists(),
        "reconciling away a dead focus's pin must not disturb a live focus's review"
    );
}

// ── W7 — f4b: the departure loop, isolated from the backstop ─────────────────

/// A confirmed departure must discard the focus's **pane tree and bindings**,
/// not merely its pin.
///
/// Why this asserts the pane registry and not the pin — read before "improving"
/// it: a pin assertion here would prove nothing about the departure loop,
/// because the backstop would satisfy it on its own. For a tag to reach
/// `departed` at all, three non-empty pushes must have landed (one to register
/// it, one to put it in `pending_departures`, one to confirm), so
/// `reconcilable_focus_tags` is necessarily `Some` by then; and a departed tag
/// is in neither `live_focus_tags` nor `pending_departures`, so `retain_pins`
/// deletes that very pin on the very same message even if the departure loop
/// never runs. An empty push is no escape either — it both resets the
/// non-empty-push count and clears `pending_departures`, so it can never
/// produce a departure. In every state this protocol can reach, the backstop
/// subsumes the departure loop *for pins*.
///
/// Discarding the pane tree and its source bindings is the one effect only the
/// departure loop has, so it is the only observable that isolates it. Turning
/// this back into a pin assertion would silently restore that masking, which is
/// what let a whole eviction path sit dead and green before.
#[tokio::test]
async fn a_departed_focus_loses_its_pane_tree_and_bindings() {
    use nostromo::ipc::pane_registry::{PaneRegistry, SplitPosition, REPL_PANE_ID};

    let (socket_path, _state_dir, tmp, _server, session_mgr) = serve_with_session_mgr().await;

    // The daemon-hosted MCP bridge is what gives the daemon a pane registry;
    // without it a departure has no tree to discard.
    let panes = Arc::new(Mutex::new(PaneRegistry::in_memory()));
    session_mgr.lock().unwrap().configure_mcp_bridge(
        Arc::clone(&panes),
        tmp.path().join("mcp.sock"),
        tmp.path().join("mcp.json"),
    );

    let departing = "cody-core-1234";

    // Both focuses have assembled a workspace: a second pane bound to a source
    // the broadcasters keep fetching for.
    {
        let mut reg = panes.lock().unwrap();
        for tag in [departing, "perri"] {
            reg.init_focus(tag);
            reg.create_pane(tag, "diff", SplitPosition::Right, REPL_PANE_ID)
                .unwrap();
            reg.bind_source(tag, "diff", "perri.get_pr_diff");
        }
    }

    let mut stream = UnixStream::connect(&socket_path).await.unwrap();
    handshake(&mut stream, vec![Topic::Perri, Topic::Focuses]).await;

    // Registered…
    send(
        &mut stream,
        &ClientMsg::FocusRegistryPush {
            focuses: vec![focus_meta("perri"), focus_meta(departing)],
        },
    )
    .await;

    // …then absent from two consecutive pushes, which is the only way the
    // daemon ever learns a focus is gone.
    for _ in 0..2 {
        send(
            &mut stream,
            &ClientMsg::FocusRegistryPush {
                focuses: vec![focus_meta("perri")],
            },
        )
        .await;
    }

    assert!(
        wait_until(|| !panes.lock().unwrap().contains(departing)).await,
        "a focus absent from two consecutive pushes must lose its pane tree — \
         create_focus derives tags deterministically, so a surviving tree is handed \
         straight to the next focus of the same name"
    );
    let leftover: Vec<String> = panes
        .lock()
        .unwrap()
        .all_bindings()
        .into_iter()
        .filter(|(tag, _, _)| tag == departing)
        .map(|(_, pane_id, _)| pane_id)
        .collect();
    assert!(
        leftover.is_empty(),
        "a removed focus must leave no source binding the broadcasters keep fetching \
         for, but {departing} still holds bindings for panes {leftover:?}"
    );
    assert!(
        panes.lock().unwrap().contains("perri"),
        "removing one focus must not disturb another focus's workspace"
    );
}
