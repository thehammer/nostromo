//! Automatic pane-source liveness: bindings recorded on `PaneRegistry`
//! (`(tag, pane_id) -> source`) are kept fresh in the background, without any
//! agent/tool-call involved.
//!
//! ## The choke point (D5)
//!
//! [`broadcast_pane_content`] is the *only* place a daemon-side
//! `ServerMsg::PaneContent` is sent. Every tool handler and this module's own
//! broadcaster route through it, which is what makes "mark the pane painted"
//! and "never re-send `Loading` over existing content" true everywhere at
//! once instead of four separate implementations that could drift.
//!
//! ## The broadcaster (D7) is reactive, not eagerly repainting
//!
//! [`run_pane_source_broadcaster`] only ever reacts to an actual change on
//! `perri_queue_rx`/`perri_pr_rx`, or to its own periodic staleness
//! re-evaluation of a pane it has *already* pushed content for at least once.
//! It deliberately does **not** walk every binding and push content for it at
//! startup — a pane that has never been pushed to has nothing to
//! re-evaluate, and unconditionally repainting every binding on spawn would
//! mean a pane bound to one source gets pushed as a side effect of an
//! unrelated source's very first change (there being no prior state yet to
//! dedup against). The daemon-restart repaint the PRD requires — "a
//! restarted daemon repaints every live pane immediately" — is instead the
//! caller's job: `nostromd.rs` calls [`bound_pane_contents`] once and
//! broadcasts the result *before* spawning this function, using the same
//! fetch/freshness dispatch so the two can never disagree about content. See
//! `docs/mcp/panes.md`.

use std::collections::HashMap;
use std::time::Duration;

use tokio::sync::watch;
use tracing::debug;

use crate::data::perri_pr::PrSnapshot;
use crate::data::perri_queue::PrQueueSnapshot;
use crate::ipc::pane_registry::PaneContentProvider;
use crate::ipc::protocol::{PaneAddress, PaneContentWire, PaneFreshness, ServerMsg};
use crate::mcp::state::{DaemonMcpBackend, McpSharedState};
use crate::mcp::tools::apply_layout::{self, SOURCE_CURRENT_PR, SOURCE_PR_QUEUE};

/// How long a source can go without producing good data before a pane
/// carrying its content is marked `badly_stale` (D6). Derived from the
/// existing cadence, not picked: a relay-driven refresh lands in ~3s and the
/// poller's floor is 60s (`Config::pr_queue_poll_secs`), so a single missed
/// cycle is routine and must stay silent. Five minutes is five consecutive
/// missed cycles — no longer explicable as transient.
///
/// A function rather than a `const` so it can honor `NOSTROMO_BADLY_STALE_SECS`
/// at runtime — a testing/manual-verification aid only (see the PRD's M5),
/// never a documented user setting.
pub(crate) fn badly_stale_after() -> Duration {
    std::env::var("NOSTROMO_BADLY_STALE_SECS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(300))
}

/// How often the broadcaster re-evaluates staleness for every pane it has
/// already pushed to, even when neither watch channel has changed — this is
/// what stops a source that has simply gone quiet from going undetected
/// forever.
const STALENESS_TICK: Duration = Duration::from_secs(30);

// ── the one choke point for every daemon-side PaneContent broadcast (D5) ────

/// Broadcast `content` for `(tag, pane_id)` and mark the pane painted. Every
/// daemon-side `PaneContent` send goes through this function.
pub(crate) fn broadcast_pane_content(
    daemon: &DaemonMcpBackend,
    tag: &str,
    pane_id: &str,
    content: PaneContentWire,
    freshness: Option<PaneFreshness>,
) {
    broadcast_pane_content_with_address(daemon, tag, pane_id, content, freshness, None);
}

/// [`broadcast_pane_content`] plus an optional [`PaneAddress`] (W1 —
/// curated-agent-views). Still the one choke point every daemon-side
/// `PaneContent` send goes through — `broadcast_pane_content` is a thin
/// `address: None` wrapper over this rather than a second implementation, so
/// "mark the pane painted" and "never re-send `Loading` over existing
/// content" can't drift between callers that do and don't address a pane.
pub(crate) fn broadcast_pane_content_with_address(
    daemon: &DaemonMcpBackend,
    tag: &str,
    pane_id: &str,
    content: PaneContentWire,
    freshness: Option<PaneFreshness>,
    address: Option<PaneAddress>,
) {
    let _ = daemon.broadcast_tx.send(ServerMsg::PaneContent {
        tag: tag.to_string(),
        pane_id: pane_id.to_string(),
        content,
        freshness,
        address,
    });
    daemon
        .pane_registry
        .lock()
        .unwrap()
        .mark_painted(tag, pane_id);
}

/// Broadcast `PaneContentWire::Loading` only if `(tag, pane_id)` has never
/// been painted. Returns whether it actually sent. First-paint only — a
/// spinner replacing content the operator is reading is wrong regardless of
/// who triggered it.
pub(crate) fn broadcast_loading_if_first_paint(
    daemon: &DaemonMcpBackend,
    tag: &str,
    pane_id: &str,
) -> bool {
    let already_painted = daemon
        .pane_registry
        .lock()
        .unwrap()
        .has_been_painted(tag, pane_id);
    if already_painted {
        return false;
    }
    broadcast_pane_content(daemon, tag, pane_id, PaneContentWire::Loading, None);
    true
}

// ── replay / restart repaint (D3, D8) ───────────────────────────────────────

/// One `ServerMsg::PaneContent` per live binding, with current content and
/// freshness — used for attach replay ([`crate::ipc::pane_registry::PaneContentProvider`])
/// and by `nostromd.rs` to repaint every bound pane once at daemon startup,
/// before [`run_pane_source_broadcaster`]'s own reactive loop begins.
///
/// Skips a binding whose fetch fails — there is no "last good content" to
/// fall back to in this stateless snapshot; the broadcaster's own on-change
/// path will pick it up once the source recovers.
pub fn bound_pane_contents(state: &McpSharedState) -> Vec<ServerMsg> {
    let Some(daemon) = &state.daemon else {
        return Vec::new();
    };
    let bindings = daemon.pane_registry.lock().unwrap().all_bindings();
    bindings
        .into_iter()
        .filter_map(|(tag, pane_id, source)| {
            let content = apply_layout::fetch(&source, state, None).ok()?;
            let fr = apply_layout::freshness(&source, state);
            Some(ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                freshness: Some(fr),
                address: None,
            })
        })
        .collect()
}

/// Repaint every live binding once, through the same D5 choke point as every
/// other daemon-side push (so painted-tracking stays correct — unlike
/// [`bound_pane_contents`], which builds point-to-point replay frames for a
/// single new connection rather than broadcasting). Called by `nostromd.rs`
/// once at startup, before spawning [`run_pane_source_broadcaster`], so a
/// restarted daemon brings every already-bound pane back to life immediately
/// (D3) rather than waiting for the next source change.
pub fn repaint_bound_panes(state: &McpSharedState) {
    let Some(daemon) = &state.daemon else {
        return;
    };
    let bindings = daemon.pane_registry.lock().unwrap().all_bindings();
    for (tag, pane_id, source) in bindings {
        let Ok(content) = apply_layout::fetch(&source, state, None) else {
            continue;
        };
        let fr = apply_layout::freshness(&source, state);
        broadcast_pane_content(daemon, &tag, &pane_id, content, Some(fr));
    }
}

/// [`PaneContentProvider`] implementation over a cloned `McpSharedState`,
/// registered on `SessionManager` so `server.rs` can replay live pane content
/// to a newly (re)connected client without `ipc` depending on `mcp`.
pub struct McpPaneContentProvider(pub McpSharedState);

impl PaneContentProvider for McpPaneContentProvider {
    fn bound_pane_contents(&self) -> Vec<ServerMsg> {
        bound_pane_contents(&self.0)
    }
}

// ── the broadcaster (D7) ─────────────────────────────────────────────────────

/// `(tag, pane_id) -> (content, freshness, address)` last actually broadcast
/// by this process, used both to dedup an unchanged push and to know which
/// panes the staleness ticker is allowed to re-evaluate (see the module doc
/// comment). `address` (W1 — curated-agent-views) is part of the dedup key
/// so an address-only change is a real change and gets broadcast — the
/// automatic broadcaster below always fetches with `address: None` (no known
/// source produces one yet), so this only matters once a future source
/// starts attaching one.
type LastSent = HashMap<(String, String), (PaneContentWire, PaneFreshness, Option<PaneAddress>)>;

/// Watches the PR-queue and current-PR watch channels and, on every change,
/// re-fetches and re-broadcasts content for every binding pointed at that
/// source — no tool call, no agent involved. Also runs a periodic staleness
/// re-evaluation over panes it has already pushed to, so a source that has
/// simply stopped firing (no watch change at all) can't go undetected forever.
pub async fn run_pane_source_broadcaster(
    state: McpSharedState,
    mut queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    mut pr_rx: watch::Receiver<Option<PrSnapshot>>,
) {
    let mut last_sent: LastSent = HashMap::new();

    let mut ticker = tokio::time::interval(STALENESS_TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

    loop {
        tokio::select! {
            result = queue_rx.changed() => {
                if result.is_err() { break; } // sender dropped — clean exit
                push_for_source(&state, SOURCE_PR_QUEUE, &mut last_sent);
            }
            result = pr_rx.changed() => {
                if result.is_err() { break; }
                push_for_source(&state, SOURCE_CURRENT_PR, &mut last_sent);
            }
            _ = ticker.tick() => {
                reevaluate_staleness(&state, &mut last_sent);
            }
        }
    }

    debug!("pane source broadcaster exiting — watch channels closed");
}

/// Re-fetch and re-broadcast content for every binding pointed at `source`,
/// skipping any pane whose `(content, freshness)` is unchanged since the last
/// push (the daemon-side half of "an idempotent push is invisible") and any
/// pane whose fetch fails (the automatic path never surfaces `Error`).
fn push_for_source(state: &McpSharedState, source: &str, last_sent: &mut LastSent) {
    let Some(daemon) = &state.daemon else {
        return;
    };
    let targets: Vec<(String, String)> = daemon
        .pane_registry
        .lock()
        .unwrap()
        .all_bindings()
        .into_iter()
        .filter(|(_, _, s)| s == source)
        .map(|(tag, pane_id, _)| (tag, pane_id))
        .collect();

    for (tag, pane_id) in targets {
        let Ok(content) = apply_layout::fetch(source, state, None) else {
            continue;
        };
        let fr = apply_layout::freshness(source, state);
        let key = (tag.clone(), pane_id.clone());
        if last_sent.get(&key) == Some(&(content.clone(), fr.clone(), None)) {
            continue;
        }
        last_sent.insert(key, (content.clone(), fr.clone(), None));
        broadcast_pane_content(daemon, &tag, &pane_id, content, Some(fr));
    }
}

/// Re-evaluate freshness for every pane already present in `last_sent`
/// (deliberately *not* every binding — a pane that has never been pushed to
/// has nothing to re-evaluate, see the module doc comment), pushing only when
/// the `badly_stale` verdict has flipped since the last push — this is what
/// stops a source that has gone quiet from staying silently stale forever,
/// without spamming a broadcast on every tick for an unchanged verdict.
fn reevaluate_staleness(state: &McpSharedState, last_sent: &mut LastSent) {
    let Some(daemon) = &state.daemon else {
        return;
    };
    let bindings = daemon.pane_registry.lock().unwrap().all_bindings();

    for (tag, pane_id, source) in bindings {
        let key = (tag.clone(), pane_id.clone());
        let Some((_, prev_fr, _)) = last_sent.get(&key) else {
            continue;
        };
        let fr = apply_layout::freshness(&source, state);
        if prev_fr.badly_stale == fr.badly_stale {
            continue;
        }
        let Ok(content) = apply_layout::fetch(&source, state, None) else {
            continue;
        };
        last_sent.insert(key, (content.clone(), fr.clone(), None));
        broadcast_pane_content(daemon, &tag, &pane_id, content, Some(fr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use chrono::{Duration as ChronoDuration, Utc};
    use serde_json::{json, Value};
    use tokio::sync::{broadcast, watch};

    use crate::data::perri_pr::PrSnapshot;
    use crate::data::perri_queue::PrQueueSnapshot;
    use crate::ipc::pane_registry::{PaneRegistry, SplitPosition, REPL_PANE_ID};
    use crate::ipc::protocol::{PaneContentWire, PaneFreshness, ServerMsg};
    use crate::ipc::SessionManager;
    use crate::mcp::{DaemonMcpBackend, McpSharedState};

    // ── test helpers ─────────────────────────────────────────────────────────

    /// Return type of [`make_state`] — named so clippy's `type_complexity`
    /// lint doesn't fire on the bare tuple.
    type MakeStateResult = (
        McpSharedState,
        broadcast::Receiver<ServerMsg>,
        watch::Sender<Option<PrQueueSnapshot>>,
        watch::Sender<Option<PrSnapshot>>,
    );

    /// Build a daemon-hosted `McpSharedState` with fresh, test-owned
    /// `perri_queue_rx`/`perri_pr_rx` watch channels (mirrors the
    /// `make_state()` pattern in `apply_layout.rs`/`refresh_pane.rs`'s tests,
    /// but also hands back the `Sender` halves so tests can push updates
    /// after the broadcaster is already running).
    fn make_state() -> MakeStateResult {
        let tmp = tempfile::TempDir::new().unwrap();
        let pane_registry = Arc::new(Mutex::new(PaneRegistry::with_store_path(
            tmp.path().join("panes.json"),
        )));
        let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
            tmp.path().join("sessions.json"),
        )));
        std::mem::forget(tmp);
        let (broadcast_tx, bcast_rx) = broadcast::channel(64);
        let backend = DaemonMcpBackend {
            pane_registry,
            session_mgr,
            broadcast_tx,
            perri: crate::mcp::PerriDaemonState::default(),
        };
        let mut state = McpSharedState::for_daemon(backend);

        let (queue_tx, queue_rx) = watch::channel(None::<PrQueueSnapshot>);
        let (pr_tx, pr_rx) = watch::channel(None::<PrSnapshot>);
        state.perri_queue_rx = queue_rx;
        state.perri_pr_rx = pr_rx;

        (state, bcast_rx, queue_tx, pr_tx)
    }

    /// Register (if needed) and bind a leaf pane split straight off "repl".
    fn bind_pane(state: &McpSharedState, tag: &str, pane_id: &str, source: &str) {
        let daemon = state.daemon.as_ref().unwrap();
        let mut reg = daemon.pane_registry.lock().unwrap();
        if !reg.contains(tag) {
            reg.init_focus(tag);
        }
        if reg.pane_ids(tag).iter().all(|p| p.as_str() != pane_id) {
            reg.create_pane(tag, pane_id, SplitPosition::Right, REPL_PANE_ID)
                .unwrap();
        }
        reg.bind_source(tag, pane_id, source);
    }

    fn queue_item(repo: &str, number: u64, title: &str) -> Value {
        json!({ "repo": repo, "number": number, "title": title, "author": "alice",
                "bucket": "requested", "ci_state": "success", "url": "https://example.com" })
    }

    fn queue_snapshot(
        items: Vec<Value>,
        stale: bool,
        generated_at: Option<chrono::DateTime<Utc>>,
    ) -> PrQueueSnapshot {
        serde_json::from_value(json!({
            "generated_at": generated_at,
            "items": items,
            "stale": stale,
            "error": null
        }))
        .unwrap()
    }

    fn pr_snapshot(repo: &str, number: u64, title: &str) -> PrSnapshot {
        serde_json::from_value(json!({
            "pr_number": number, "repo": repo, "title": title,
            "author": "alice", "url": "https://example.com", "diff": "",
            "stale": false, "error": null, "additions": 1, "deletions": 1,
            "changed_files": 1, "head_sha": "abc123", "diff_too_large": false
        }))
        .unwrap()
    }

    // ── broadcast_pane_content ───────────────────────────────────────────────

    #[test]
    fn broadcast_pane_content_sends_the_message_and_marks_the_pane_painted() {
        let (state, mut bcast, _qtx, _ptx) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
        }
        let daemon = state.daemon.as_ref().unwrap();
        assert!(!daemon
            .pane_registry
            .lock()
            .unwrap()
            .has_been_painted("perri", "queue"));

        broadcast_pane_content(
            daemon,
            "perri",
            "queue",
            PaneContentWire::Text { text: "hi".into() },
            None,
        );

        assert!(
            daemon
                .pane_registry
                .lock()
                .unwrap()
                .has_been_painted("perri", "queue"),
            "broadcast_pane_content must mark the pane painted"
        );

        match bcast.try_recv().expect("a broadcast should have been sent") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                freshness,
                address,
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(matches!(content, PaneContentWire::Text { text } if text == "hi"));
                assert!(freshness.is_none());
                assert!(address.is_none(), "broadcast_pane_content must default address to None");
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[test]
    fn broadcast_pane_content_attaches_the_given_freshness() {
        let (state, mut bcast, _qtx, _ptx) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
        }
        let daemon = state.daemon.as_ref().unwrap();

        let freshness = PaneFreshness {
            as_of: None,
            stale: true,
            badly_stale: true,
        };
        broadcast_pane_content(
            daemon,
            "perri",
            "queue",
            PaneContentWire::Text { text: "hi".into() },
            Some(freshness.clone()),
        );

        match bcast.try_recv().unwrap() {
            ServerMsg::PaneContent { freshness: f, .. } => {
                assert_eq!(f, Some(freshness));
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    // ── broadcast_pane_content_with_address (W1 — curated-agent-views) ───────

    #[test]
    fn broadcast_pane_content_with_address_attaches_the_given_address() {
        let (state, mut bcast, _qtx, _ptx) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("perri");
            reg.create_pane("perri", "ticket", SplitPosition::Right, "repl")
                .unwrap();
        }
        let daemon = state.daemon.as_ref().unwrap();

        let address = PaneAddress {
            anchor: None,
            emphasis: vec![],
            reason: Some("opened from the queue".into()),
        };
        broadcast_pane_content_with_address(
            daemon,
            "perri",
            "ticket",
            PaneContentWire::Text { text: "CORE-1234".into() },
            None,
            Some(address.clone()),
        );

        match bcast.try_recv().unwrap() {
            ServerMsg::PaneContent { address: a, .. } => assert_eq!(a, Some(address)),
            other => panic!("expected PaneContent, got {other:?}"),
        }
    }

    #[test]
    fn last_sent_dedup_tuple_treats_an_address_only_difference_as_a_real_change() {
        // Mirrors the daemon-side dedup key `push_for_source` compares against
        // (D5): `LastSent` stores `(content, freshness, address)`, so two
        // otherwise-identical entries differing only by address must NOT
        // compare equal — an address-only change is a real change and must
        // not be silently swallowed as a duplicate.
        let content = PaneContentWire::Text { text: "hi".into() };
        let freshness = PaneFreshness::default();

        let no_address: (PaneContentWire, PaneFreshness, Option<PaneAddress>) =
            (content.clone(), freshness.clone(), None);
        let with_address: (PaneContentWire, PaneFreshness, Option<PaneAddress>) = (
            content.clone(),
            freshness.clone(),
            Some(PaneAddress {
                anchor: None,
                emphasis: vec![],
                reason: Some("flagged".into()),
            }),
        );

        assert_ne!(
            no_address, with_address,
            "an address-only difference must make the dedup tuple unequal"
        );
        assert_eq!(
            no_address,
            (content, freshness, None),
            "sanity: identical tuples (including address) must still compare equal"
        );
    }

    // ── broadcast_loading_if_first_paint ─────────────────────────────────────

    #[tokio::test]
    async fn broadcast_loading_if_first_paint_sends_on_a_never_painted_pane() {
        let (state, mut bcast, _qtx, _ptx) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
        }
        let daemon = state.daemon.as_ref().unwrap();

        let sent = broadcast_loading_if_first_paint(daemon, "perri", "queue");
        assert!(sent, "a never-painted pane must get a Loading push");

        match bcast.recv().await.expect("a broadcast") {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                content,
                ..
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                assert!(matches!(content, PaneContentWire::Loading));
            }
            other => panic!("expected PaneContent(Loading), got {other:?}"),
        }
    }

    #[tokio::test]
    async fn broadcast_loading_if_first_paint_stays_quiet_on_an_already_painted_pane() {
        let (state, mut bcast, _qtx, _ptx) = make_state();
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            reg.init_focus("perri");
            reg.create_pane("perri", "queue", SplitPosition::Right, "repl")
                .unwrap();
            reg.mark_painted("perri", "queue");
        }
        let daemon = state.daemon.as_ref().unwrap();

        let sent = broadcast_loading_if_first_paint(daemon, "perri", "queue");
        assert!(!sent, "an already-painted pane must not get a Loading push");

        assert!(
            tokio::time::timeout(Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "no broadcast at all for an already-painted pane"
        );
    }

    // ── bound_pane_contents ───────────────────────────────────────────────────

    #[test]
    fn bound_pane_contents_returns_one_message_per_live_binding_and_skips_repl_and_unbound() {
        let (state, _bcast, _qtx, _ptx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");
        bind_pane(&state, "perri", "diff", "perri.get_current_pr");
        {
            let daemon = state.daemon.as_ref().unwrap();
            let mut reg = daemon.pane_registry.lock().unwrap();
            // "notes" exists in the tree but is never bound to a source.
            reg.create_pane("perri", "notes", SplitPosition::Below, "queue")
                .unwrap();
        }

        let msgs = bound_pane_contents(&state);
        assert_eq!(
            msgs.len(),
            2,
            "one PaneContent per live binding, none for unbound panes or repl"
        );

        let mut saw_queue = false;
        let mut saw_diff = false;
        for msg in msgs {
            match msg {
                ServerMsg::PaneContent {
                    tag,
                    pane_id,
                    content,
                    ..
                } => {
                    assert_eq!(tag, "perri");
                    match pane_id.as_str() {
                        "queue" => {
                            saw_queue = true;
                            assert!(matches!(content, PaneContentWire::PrList { .. }));
                        }
                        "diff" => {
                            saw_diff = true;
                            assert!(matches!(content, PaneContentWire::Text { .. }));
                        }
                        other => panic!("must not push content for {other}"),
                    }
                }
                other => panic!("expected PaneContent, got {other:?}"),
            }
        }
        assert!(saw_queue && saw_diff);
    }

    // ── run_pane_source_broadcaster: on-change pushes ────────────────────────

    #[tokio::test]
    async fn queue_channel_change_pushes_exactly_one_pane_content_to_the_bound_pane() {
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        queue_tx
            .send(Some(queue_snapshot(
                vec![queue_item("acme/web", 42, "Add widget")],
                false,
                None,
            )))
            .unwrap();

        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("a push within 200ms")
            .unwrap();
        match msg {
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

        handle.abort();
    }

    #[tokio::test]
    async fn pane_bound_to_current_pr_source_is_not_pushed_when_only_the_queue_changes() {
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");
        bind_pane(&state, "perri", "diff", "perri.get_current_pr");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        queue_tx
            .send(Some(queue_snapshot(
                vec![queue_item("acme/web", 42, "Add widget")],
                false,
                None,
            )))
            .unwrap();

        // The one push we get must be for "queue", never "diff".
        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("a push within 200ms")
            .unwrap();
        match msg {
            ServerMsg::PaneContent { pane_id, .. } => assert_eq!(pane_id, "queue"),
            other => panic!("expected PaneContent, got {other:?}"),
        }

        assert!(
            tokio::time::timeout(Duration::from_millis(100), bcast.recv())
                .await
                .is_err(),
            "a pane bound to a different source must not be pushed by this change"
        );

        handle.abort();
    }

    #[tokio::test]
    async fn two_tags_bound_to_the_queue_source_each_get_their_own_addressed_push() {
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");
        bind_pane(&state, "perri-a1b2c3d4", "queue", "perri.list_pr_queue");
        {
            let daemon = state.daemon.as_ref().unwrap();
            // A third tag exists but has no binding to this source at all.
            daemon
                .pane_registry
                .lock()
                .unwrap()
                .init_focus("no-queue-binding");
        }

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        queue_tx
            .send(Some(queue_snapshot(
                vec![queue_item("acme/web", 42, "Add widget")],
                false,
                None,
            )))
            .unwrap();

        let mut seen_tags = std::collections::HashSet::new();
        for _ in 0..2 {
            match tokio::time::timeout(Duration::from_millis(200), bcast.recv())
                .await
                .expect("a push within 200ms")
                .unwrap()
            {
                ServerMsg::PaneContent {
                    tag,
                    pane_id,
                    content,
                    ..
                } => {
                    assert_eq!(pane_id, "queue");
                    assert!(matches!(content, PaneContentWire::PrList { .. }));
                    seen_tags.insert(tag);
                }
                other => panic!("expected PaneContent, got {other:?}"),
            }
        }
        assert_eq!(
            seen_tags,
            ["perri".to_string(), "perri-a1b2c3d4".to_string()]
                .into_iter()
                .collect()
        );

        assert!(
            tokio::time::timeout(Duration::from_millis(100), bcast.recv())
                .await
                .is_err(),
            "no third push — in particular nothing addressed to the unbound tag"
        );

        handle.abort();
    }

    #[tokio::test]
    async fn identical_snapshot_sent_twice_produces_no_second_broadcast() {
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        let snapshot = queue_snapshot(vec![queue_item("acme/web", 42, "Add widget")], false, None);
        queue_tx.send(Some(snapshot.clone())).unwrap();
        let _ = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("first push")
            .unwrap();

        // Re-send the identical value. `watch::Sender::send` marks the
        // channel changed regardless of equality, so this exercises the
        // daemon-side content+freshness dedup, not tokio::watch's own
        // change-detection.
        queue_tx.send(Some(snapshot)).unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(300), bcast.recv())
                .await
                .is_err(),
            "an identical snapshot must not produce a second broadcast"
        );

        handle.abort();
    }

    // ── staleness ─────────────────────────────────────────────────────────────

    #[tokio::test]
    async fn stale_data_past_five_minutes_gets_flagged_badly_stale() {
        tokio::time::pause();
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        let stale_since = Utc::now() - ChronoDuration::minutes(6);
        queue_tx
            .send(Some(queue_snapshot(vec![], true, Some(stale_since))))
            .unwrap();

        // Give the ~30s staleness-check tick (STALENESS_TICK) at least one
        // chance to run, whether or not the badly-stale verdict is actually
        // produced by the on-change handler or by that periodic tick.
        tokio::time::advance(Duration::from_secs(31)).await;

        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("a push carrying the badly-stale verdict")
            .unwrap();
        match msg {
            ServerMsg::PaneContent {
                tag,
                pane_id,
                freshness,
                ..
            } => {
                assert_eq!(tag, "perri");
                assert_eq!(pane_id, "queue");
                let freshness = freshness.expect("freshness must be attached once data is known-stale");
                assert!(freshness.badly_stale);
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        // Advancing further with no state change: the verdict is unchanged,
        // so there must be no additional push (no spam).
        tokio::time::advance(Duration::from_secs(31)).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(50), bcast.recv())
                .await
                .is_err(),
            "an unchanged badly-stale verdict must not re-broadcast on every tick"
        );

        handle.abort();
    }

    #[tokio::test]
    async fn recovering_from_badly_stale_pushes_freshness_with_badly_stale_false() {
        tokio::time::pause();
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        let stale_since = Utc::now() - ChronoDuration::minutes(6);
        queue_tx
            .send(Some(queue_snapshot(vec![], true, Some(stale_since))))
            .unwrap();
        tokio::time::advance(Duration::from_secs(31)).await;

        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("the badly-stale push")
            .unwrap();
        match msg {
            ServerMsg::PaneContent { freshness, .. } => {
                assert!(freshness.expect("freshness attached").badly_stale);
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        // Recovery: a fresh snapshot arrives.
        queue_tx
            .send(Some(queue_snapshot(
                vec![queue_item("acme/web", 42, "Add widget")],
                false,
                Some(Utc::now()),
            )))
            .unwrap();

        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("a recovery push")
            .unwrap();
        match msg {
            ServerMsg::PaneContent {
                content, freshness, ..
            } => {
                assert!(matches!(content, PaneContentWire::PrList { .. }));
                let freshness = freshness.expect("freshness must still be attached");
                assert!(
                    !freshness.badly_stale,
                    "recovered data must clear the badly-stale flag"
                );
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        handle.abort();
    }

    #[tokio::test]
    async fn source_that_never_produced_good_data_is_badly_stale_immediately() {
        tokio::time::pause();
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        // stale: true, generated_at: None — the source has never produced
        // good data at all, unlike the "aged out" case above.
        queue_tx
            .send(Some(queue_snapshot(vec![], true, None)))
            .unwrap();
        tokio::time::advance(Duration::from_secs(31)).await;

        let msg = tokio::time::timeout(Duration::from_millis(200), bcast.recv())
            .await
            .expect("an immediate badly-stale push")
            .unwrap();
        match msg {
            ServerMsg::PaneContent { freshness, .. } => {
                let freshness = freshness.expect("freshness must be attached");
                assert!(
                    freshness.badly_stale,
                    "no as_of at all must read as badly stale right away, not after a delay"
                );
            }
            other => panic!("expected PaneContent, got {other:?}"),
        }

        handle.abort();
    }

    #[tokio::test]
    async fn transient_staleness_under_five_minutes_never_flags_badly_stale() {
        tokio::time::pause();
        let (state, mut bcast, queue_tx, _pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        // A transient failure only ~30s old — nowhere near the 5-minute
        // threshold — must stay quiet through one missed staleness-check cycle.
        let recent = Utc::now() - ChronoDuration::seconds(30);
        queue_tx
            .send(Some(queue_snapshot(vec![], true, Some(recent))))
            .unwrap();
        tokio::time::advance(Duration::from_secs(31)).await;

        let mut saw_any = false;
        while let Ok(Ok(msg)) =
            tokio::time::timeout(Duration::from_millis(50), bcast.recv()).await
        {
            saw_any = true;
            if let ServerMsg::PaneContent {
                freshness: Some(f), ..
            } = msg
            {
                assert!(
                    !f.badly_stale,
                    "a transient ~30s-old failure must not be flagged badly stale"
                );
            }
        }
        let _ = saw_any; // whether a content push happens at all isn't the point here.

        handle.abort();
    }

    #[tokio::test]
    async fn automatic_broadcaster_never_sends_loading_or_error_content() {
        tokio::time::pause();
        let (state, mut bcast, queue_tx, pr_tx) = make_state();
        bind_pane(&state, "perri", "queue", "perri.list_pr_queue");
        bind_pane(&state, "perri", "diff", "perri.get_current_pr");

        let handle = tokio::spawn(run_pane_source_broadcaster(
            state.clone(),
            state.perri_queue_rx.clone(),
            state.perri_pr_rx.clone(),
        ));

        queue_tx
            .send(Some(queue_snapshot(
                vec![queue_item("acme/web", 42, "Add widget")],
                false,
                Some(Utc::now()),
            )))
            .unwrap();
        pr_tx
            .send(Some(pr_snapshot("acme/web", 42, "Add widget")))
            .unwrap();
        tokio::time::advance(Duration::from_secs(31)).await;

        queue_tx
            .send(Some(queue_snapshot(
                vec![],
                true,
                Some(Utc::now() - ChronoDuration::minutes(10)),
            )))
            .unwrap();
        tokio::time::advance(Duration::from_secs(61)).await;

        let mut checked_any = false;
        while let Ok(Ok(msg)) =
            tokio::time::timeout(Duration::from_millis(50), bcast.recv()).await
        {
            if let ServerMsg::PaneContent { content, .. } = msg {
                checked_any = true;
                assert!(
                    matches!(
                        content,
                        PaneContentWire::PrList { .. } | PaneContentWire::Text { .. }
                    ),
                    "automatic broadcaster must never send Loading/Error, got {content:?}"
                );
            }
        }
        assert!(checked_any, "expected at least one push during this run");

        handle.abort();
    }
}
