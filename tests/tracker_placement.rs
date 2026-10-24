//! Where `nostromo.tracker` puts its pane, and when it stays out of the way
//! (slice T0c). Tool-level: everything goes through the public MCP entry point
//! (`dispatch("nostromo.tracker", ...)`) and what the daemon broadcasts, plus
//! the pane registry's public API to play the user (close the pane, a window
//! reporting what it rendered) or an agent's layout tools.
//!
//! Spec: `.claude/plans/agent-tracker-pane-design-contract.md` §6 and §12 and
//! the PRD placement criteria.
//!
//! Hermetic (contract §12): `FakeClock`, temp dirs for the repo / state root /
//! home, a `git init` repo whose `core.excludesFile` is a temp file. No wall
//! clock, no real `~/.nostromo`, no running app.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{PaneTree, ServerMsg, SplitDirection};
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::{dispatch, tool_descriptors, ToolResult};
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use nostromo::tracker::{CallerFacts, FakeClock, RegistryParts, TrackerRegistry};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

const TAG_A: &str = "cody-a";
const TAG_B: &str = "cody-b";

struct Fx {
    _tmp: TempDir,
    repo: PathBuf,
    registry: Arc<TrackerRegistry>,
    panes: Arc<Mutex<PaneRegistry>>,
    state: McpSharedState,
    rx: Mutex<broadcast::Receiver<ServerMsg>>,
}

fn git(repo: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .expect("git is installed");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

fn now() -> chrono::DateTime<chrono::Utc> {
    chrono::DateTime::from_timestamp(1_760_540_000, 0).expect("a valid timestamp")
}

fn leaf(id: &str) -> PaneTree {
    PaneTree::Leaf { pane_id: id.to_string() }
}

/// The curated-Perri shape: a `detail` tab region above the REPL, holding
/// `queue` and two other tabs.
fn detail_layout() -> PaneTree {
    PaneTree::Split {
        direction: SplitDirection::Vertical,
        children: vec![
            PaneTree::Tabs {
                children: vec![leaf("queue"), leaf("detail.0"), leaf("detail.1")],
                labels: vec!["Queue".into(), "a.rs".into(), "b.rs".into()],
                active: 1,
                region: Some("detail".into()),
            },
            leaf("repl"),
        ],
        ratios: vec![0.6, 0.4],
    }
}

fn split_with_tracker() -> PaneTree {
    PaneTree::Split {
        direction: SplitDirection::Horizontal,
        children: vec![leaf("repl"), leaf("tracker")],
        ratios: vec![0.66, 0.34],
    }
}

impl Fx {
    fn new() -> Fx {
        Fx::with_panes(|_| PaneRegistry::in_memory())
    }

    /// A fixture whose pane registry is `panes(dir)`, `dir` being the fixture's temp directory.
    fn with_panes(panes: impl FnOnce(&Path) -> PaneRegistry) -> Fx {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        let state_root = base.join("state");
        for dir in [&repo, &home, &state_root] {
            std::fs::create_dir_all(dir).unwrap();
        }
        git(&repo, &["init", "-q"]);
        let excludes = base.join("global-excludes");
        std::fs::write(&excludes, "").unwrap();
        git(&repo, &["config", "core.excludesFile", excludes.to_str().unwrap()]);

        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let parts = RegistryParts::hermetic(state_root, home, clock);
        let registry = Arc::new(TrackerRegistry::new(parts));
        let panes = Arc::new(Mutex::new(panes(&base)));
        let (tx, rx) = broadcast::channel::<ServerMsg>(8192);
        let state = McpSharedState::for_daemon(DaemonMcpBackend {
            pane_registry: Arc::clone(&panes),
            session_mgr: Arc::new(Mutex::new(SessionManager::with_store_path(
                base.join("sessions.json"),
            ))),
            broadcast_tx: tx.clone(),
            perri: PerriDaemonState::default(),
            decisions: Arc::new(Mutex::new(nostromo::ipc::decisions::DecisionRegistry::default())),
            tickets: Default::default(),
            tracker: Arc::clone(&registry),
        });
        // As nostromd does after building the backend.
        registry.follow_panes(&panes, tx);
        Fx { _tmp: tmp, repo, registry, panes, state, rx: Mutex::new(rx) }
    }

    fn seat(&self, tag: &str, session: &str) {
        self.registry.set_caller_facts(
            tag,
            CallerFacts { cwd: Some(self.repo.clone()), session_id: Some(session.to_string()) },
        );
    }

    async fn call(&self, tag: &str, args: Value) -> Value {
        match dispatch("nostromo.tracker", Some(&args), &self.state, Some(tag)).await {
            ToolResult::Ok(content) => {
                let text = content[0]["text"].as_str().expect("text content");
                serde_json::from_str(text).unwrap_or_else(|e| panic!("tool text is JSON ({e}): {text}"))
            }
            ToolResult::UnknownTool(n) => panic!("unknown tool {n}"),
            ToolResult::Forbidden(n) => panic!("forbidden tool {n}"),
        }
    }

    async fn ok(&self, tag: &str, args: Value) -> Value {
        let res = self.call(tag, args.clone()).await;
        assert_eq!(res["ok"], json!(true), "{args:?} -> {res}");
        res
    }

    async fn open(&self, tag: &str, topic: &str) -> Value {
        self.ok(tag, json!({"op": "open", "topic": topic})).await
    }

    fn drain(&self) -> Vec<ServerMsg> {
        let mut rx = self.rx.lock().unwrap();
        let mut out = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(m) => out.push(m),
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(_) => return out,
            }
        }
    }

    /// The focus has `tree` as its layout before anything else happens.
    fn set_tree(&self, tag: &str, tree: &PaneTree) {
        let mut panes = self.panes.lock().unwrap();
        panes.get_or_init(tag);
        panes.set_layout(tag, &json!({ "tree": tree })).expect("set_layout");
    }

    fn tree(&self, tag: &str) -> PaneTree {
        self.panes.lock().unwrap().get(tag).cloned().expect("the focus has a tree")
    }

    fn report_rendered(&self, tag: &str, ids: &[&str]) {
        self.panes.lock().unwrap().record_rendered_shape(
            "conn-1",
            "window-1",
            tag,
            ids.iter().map(|s| s.to_string()).collect(),
            now(),
        );
    }

    fn board(&self, topic: &str) -> Vec<u8> {
        std::fs::read(self.repo.join(".claude").join("wip").join(topic).join("index.md"))
            .expect("board file")
    }
}

/// `(tree, focused_pane)` of every `FocusLayout` for `tag`.
fn layouts(frames: &[ServerMsg], tag: &str) -> Vec<(PaneTree, Option<String>)> {
    frames
        .iter()
        .filter_map(|m| match m {
            ServerMsg::FocusLayout { tag: t, tree, focused_pane } if t == tag => {
                Some((tree.clone(), focused_pane.clone()))
            }
            _ => None,
        })
        .collect()
}

fn any_focus_layout(frames: &[ServerMsg]) -> bool {
    frames.iter().any(|m| matches!(m, ServerMsg::FocusLayout { .. }))
}

fn ids(tree: &PaneTree) -> Vec<String> {
    tree.pane_ids()
}

fn has_tracker(tree: &PaneTree) -> bool {
    ids(tree).iter().any(|i| i == "tracker")
}

/// Every label a `tracker` tab carries anywhere in `tree`.
fn tracker_tab_labels(tree: &PaneTree) -> Vec<String> {
    match tree {
        PaneTree::Leaf { .. } => vec![],
        PaneTree::Split { children, .. } => children.iter().flat_map(tracker_tab_labels).collect(),
        PaneTree::Tabs { children, labels, .. } => {
            let mut out: Vec<String> = children
                .iter()
                .zip(labels)
                .filter(|(c, _)| matches!(c, PaneTree::Leaf { pane_id } if pane_id == "tracker"))
                .map(|(_, l)| l.clone())
                .collect();
            out.extend(children.iter().flat_map(tracker_tab_labels));
            out
        }
    }
}

/// Every tracker tab in `tree` is captioned with the literal `Tracker`.
fn assert_label_is_literal(tree: &PaneTree) {
    for label in tracker_tab_labels(tree) {
        assert_eq!(label, "Tracker", "{tree:?}");
    }
}

fn tabs(tree: &PaneTree) -> (Vec<String>, Vec<String>, usize) {
    fn find(t: &PaneTree) -> Option<(Vec<String>, Vec<String>, usize)> {
        match t {
            PaneTree::Tabs { children, labels, active, .. } => Some((
                children.iter().flat_map(|c| c.pane_ids()).collect(),
                labels.clone(),
                *active,
            )),
            PaneTree::Split { children, .. } => children.iter().find_map(find),
            PaneTree::Leaf { .. } => None,
        }
    }
    find(tree).unwrap_or_else(|| panic!("no tabs node in {tree:?}"))
}

// ---------------------------------------------------------------------------
// (a) Only-repl focus: the first open splits the transcript
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_first_open_in_a_repl_only_focus_sends_one_layout_with_the_transcript_on_the_left() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.drain();

    fx.open(TAG_A, "triage").await;

    let frames = fx.drain();
    let sent = layouts(&frames, TAG_A);
    assert_eq!(sent.len(), 1, "exactly one FocusLayout: {frames:?}");
    let (tree, focused) = &sent[0];
    assert_eq!(*focused, None, "the tracker never takes focus");

    let PaneTree::Split { direction, children, ratios } = tree else {
        panic!("a split: {tree:?}")
    };
    assert_eq!(*direction, SplitDirection::Horizontal);
    assert_eq!(children, &vec![leaf("repl"), leaf("tracker")], "transcript left, tracker right");
    assert!(ratios[0] >= 0.62, "the transcript keeps at least 62%: {ratios:?}");
    assert!((ratios[0] + ratios[1] - 1.0).abs() < 1e-4, "{ratios:?}");
    assert_eq!(&fx.tree(TAG_A), tree, "the registry holds what was sent");
}

#[test]
fn the_tool_takes_no_position_from_the_agent() {
    let descriptors = tool_descriptors();
    let tracker = descriptors
        .iter()
        .find(|d| d["name"] == json!("nostromo.tracker"))
        .expect("nostromo.tracker is listed");
    let props = tracker["inputSchema"]["properties"].as_object().expect("properties");
    for key in props.keys() {
        let k = key.to_lowercase();
        for banned in ["position", "placement", "split", "region", "ratio"] {
            assert!(!k.contains(banned), "the schema offers a placement knob {key:?}");
        }
    }
}

// ---------------------------------------------------------------------------
// (b) A focus with a detail region: a tab, labelled Tracker
// ---------------------------------------------------------------------------

#[tokio::test]
async fn with_a_detail_region_the_tracker_is_a_tab_after_queue_labelled_tracker_whatever_the_board_is_called() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.set_tree(TAG_A, &detail_layout());
    fx.drain();

    fx.ok(
        TAG_A,
        json!({"op": "open", "topic": "secret-topic", "title": "SECRET-TRACKER-1"}),
    )
    .await;
    fx.ok(TAG_A, json!({"op": "upsert", "id": "a-1", "section": "now", "text": "SECRET-TRACKER-2"}))
        .await;

    let frames = fx.drain();
    let sent = layouts(&frames, TAG_A);
    assert_eq!(sent.len(), 1, "{frames:?}");
    let (tree, focused) = &sent[0];
    assert_eq!(*focused, None);

    let (order, labels, active) = tabs(tree);
    assert_eq!(order, ["queue", "tracker", "detail.0", "detail.1"], "right after queue");
    assert_eq!(labels, ["Queue", "Tracker", "a.rs", "b.rs"], "other tabs unchanged, literal label");
    assert_eq!(active, 1, "the tracker tab is frontmost on creation");
    // The rest of the layout is as the agent left it.
    let PaneTree::Split { direction, children, ratios } = tree else { panic!("{tree:?}") };
    assert_eq!(*direction, SplitDirection::Vertical);
    assert_eq!(ratios, &vec![0.6, 0.4]);
    assert_eq!(children[1], leaf("repl"));

    for sentinel in ["SECRET-TRACKER-1", "SECRET-TRACKER-2", "secret-topic"] {
        for (t, _) in &sent {
            assert!(
                !serde_json::to_string(t).unwrap().contains(sentinel),
                "{sentinel} leaked into a layout"
            );
        }
        assert!(
            !serde_json::to_string(&fx.tree(TAG_A)).unwrap().contains(sentinel),
            "{sentinel} leaked into the stored tree"
        );
    }
    assert_label_is_literal(tree);
}

// ---------------------------------------------------------------------------
// (c) Only the first creation changes geometry
// ---------------------------------------------------------------------------

#[tokio::test]
async fn after_the_first_open_thirty_mixed_calls_send_no_layout_and_leave_the_tree_alone() {
    for initial in [PaneTree::repl_leaf(), detail_layout()] {
        let fx = Fx::new();
        fx.seat(TAG_A, "sess-a");
        fx.set_tree(TAG_A, &initial);
        fx.open(TAG_A, "triage").await;
        let before = fx.tree(TAG_A);
        assert!(has_tracker(&before));
        fx.drain();

        let mut calls = 0;
        for i in 0..6 {
            let id = format!("item-{i}");
            fx.ok(TAG_A, json!({"op": "upsert", "id": id, "section": "now", "text": format!("Thing {i}")}))
                .await;
            calls += 1;
        }
        for i in 0..4 {
            fx.ok(TAG_A, json!({"op": "status", "id": format!("item-{i}"), "status": "in-progress"}))
                .await;
            calls += 1;
        }
        for i in 0..3 {
            fx.ok(TAG_A, json!({"op": "move", "id": format!("item-{i}"), "section": "next"}))
                .await;
            calls += 1;
        }
        fx.ok(TAG_A, json!({"op": "remove", "id": "item-5"})).await;
        calls += 1;
        for i in 0..5 {
            fx.ok(TAG_A, json!({"op": "log", "text": format!("note {i}")})).await;
            calls += 1;
        }
        for _ in 0..4 {
            let r = fx.call(TAG_A, json!({"op": "read"})).await;
            assert!(r.get("error").is_none() && r["version"].is_u64(), "{r}");
            calls += 1;
        }
        for _ in 0..3 {
            fx.open(TAG_A, "triage").await;
            calls += 1;
        }
        for i in 0..3 {
            fx.ok(
                TAG_A,
                json!({"ops": [
                    {"op": "upsert", "id": format!("b-{i}"), "section": "next", "text": "batched"},
                    {"op": "status", "id": format!("b-{i}"), "status": "done"},
                    {"op": "log", "text": "batch"},
                ]}),
            )
            .await;
            calls += 1;
        }
        fx.ok(TAG_A, json!({"op": "open", "topic": "triage", "show": true})).await;
        calls += 1;
        assert_eq!(calls, 30);

        let frames = fx.drain();
        assert!(
            !any_focus_layout(&frames),
            "no layout frame after the first open: {:?}",
            layouts(&frames, TAG_A)
        );
        assert_eq!(fx.tree(TAG_A), before, "the tree is identical");
    }
}

// ---------------------------------------------------------------------------
// (d) `visible`
// ---------------------------------------------------------------------------

#[tokio::test]
async fn visible_means_the_leaf_is_in_the_tree_and_a_window_reported_rendering_it() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");

    let opened = fx.open(TAG_A, "triage").await;
    assert_eq!(opened["visible"], json!(false), "no window has reported: {opened}");
    let w = fx.ok(TAG_A, json!({"op": "log", "text": "x"})).await;
    assert_eq!(w["visible"], json!(false), "{w}");

    fx.report_rendered(TAG_A, &["repl", "tracker"]);
    let w = fx.ok(TAG_A, json!({"op": "log", "text": "y"})).await;
    assert_eq!(w["visible"], json!(true), "{w}");
    assert_eq!(fx.open(TAG_A, "triage").await["visible"], json!(true));

    // A newer report from that window that lacks the tracker.
    fx.report_rendered(TAG_A, &["repl"]);
    let w = fx.ok(TAG_A, json!({"op": "log", "text": "z"})).await;
    assert_eq!(w["visible"], json!(false), "{w}");

    // Reported again, then the leaf leaves the tree.
    fx.report_rendered(TAG_A, &["repl", "tracker"]);
    assert_eq!(fx.ok(TAG_A, json!({"op": "log", "text": "w"})).await["visible"], json!(true));
    fx.panes.lock().unwrap().close_tab(TAG_A, "tracker").unwrap();
    let w = fx.ok(TAG_A, json!({"op": "log", "text": "v"})).await;
    assert_eq!(w["visible"], json!(false), "the leaf is gone from the tree: {w}");
}

#[tokio::test]
async fn open_says_why_the_pane_is_not_visible_when_the_layout_has_no_place_for_it() {
    // A layout from an older daemon's store: no `repl` leaf, no detail region.
    let fx = Fx::with_panes(|dir| {
        let store = dir.join("panes.json");
        let tree = json!({"kind": "leaf", "pane_id": "notes"});
        std::fs::write(&store, json!({"version": 3, "trees": {TAG_A: tree}, "bindings": {}}).to_string()).unwrap();
        PaneRegistry::with_store_path(store)
    });
    fx.seat(TAG_A, "sess-a");
    assert_eq!(ids(&fx.tree(TAG_A)), vec!["notes"], "setup: nothing to put the tracker beside");

    let opened = fx.open(TAG_A, "triage").await;

    assert_eq!(opened["visible"], json!(false), "{opened}");
    assert_eq!(opened["reason"], json!("no_room_in_layout"), "the agent is told why: {opened}");
    assert!(!any_focus_layout(&fx.drain()), "nothing was placed, so nothing was announced");
    assert_eq!(ids(&fx.tree(TAG_A)), vec!["notes"], "the layout is untouched");

    // A normal open carries no reason.
    fx.seat(TAG_B, "sess-b");
    assert!(fx.open(TAG_B, "other").await.get("reason").is_none());
}

#[tokio::test]
async fn visible_is_per_focus() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "triage").await;
    fx.open(TAG_B, "other").await;
    fx.report_rendered(TAG_A, &["repl", "tracker"]);

    assert_eq!(fx.ok(TAG_A, json!({"op": "log", "text": "x"})).await["visible"], json!(true));
    assert_eq!(fx.ok(TAG_B, json!({"op": "log", "text": "x"})).await["visible"], json!(false));
}

// ---------------------------------------------------------------------------
// (e) The pane leaves its layout: the binding stays, the pane stays gone
// ---------------------------------------------------------------------------

type Closer = fn(&Fx, &str);

fn close_like_clicking_x(fx: &Fx, tag: &str) {
    fx.panes.lock().unwrap().close_tab(tag, "tracker").expect("close_tab");
}

/// An agent's layout call (apply_layout / set_pane_layout) with a tree that
/// has no tracker leaf.
fn layout_without_tracker(fx: &Fx, tag: &str) {
    let tree = if ids(&fx.tree(tag)).iter().any(|i| i == "queue") {
        PaneTree::Split {
            direction: SplitDirection::Vertical,
            children: vec![
                PaneTree::Tabs {
                    children: vec![leaf("queue"), leaf("detail.0"), leaf("detail.1")],
                    labels: vec!["Queue".into(), "a.rs".into(), "b.rs".into()],
                    active: 1,
                    region: Some("detail".into()),
                },
                leaf("repl"),
            ],
            ratios: vec![0.6, 0.4],
        }
    } else {
        PaneTree::repl_leaf()
    };
    fx.panes
        .lock()
        .unwrap()
        .set_layout(tag, &json!({ "tree": tree }))
        .expect("set_layout");
}

fn reset_panes(fx: &Fx, tag: &str) {
    fx.panes.lock().unwrap().reset(tag).expect("reset");
}

async fn pane_leaves_then_stays_gone(initial: PaneTree, closer: Closer) {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.set_tree(TAG_A, &initial);
    fx.ok(TAG_A, json!({"op": "open", "topic": "triage", "title": "SECRET-TRACKER-3"}))
        .await;
    fx.ok(TAG_A, json!({"op": "upsert", "id": "a-1", "section": "now", "text": "keep me"}))
        .await;
    assert!(has_tracker(&fx.tree(TAG_A)));
    fx.report_rendered(TAG_A, &["repl", "tracker"]);
    fx.drain();

    // The layout call itself never touches the board file, and the binding stays.
    let file_before = fx.board("triage");
    closer(&fx, TAG_A);
    assert_eq!(fx.board("triage"), file_before, "the board file is byte-identical");
    assert!(fx.registry.has_bound_board(TAG_A), "the binding stays");
    let tree = fx.tree(TAG_A);
    assert!(!has_tracker(&tree), "{tree:?}");
    fx.drain();

    // Writes still succeed, report visible:false, and never bring the pane back.
    let w = fx.ok(TAG_A, json!({"op": "upsert", "id": "a-2", "section": "now", "text": "still works"})).await;
    assert_eq!(w["visible"], json!(false), "{w}");
    let w = fx.ok(TAG_A, json!({"op": "log", "text": "after close"})).await;
    assert_eq!(w["visible"], json!(false), "{w}");
    let w = fx.ok(TAG_A, json!({"ops": [{"op": "status", "id": "a-1", "status": "done"}]})).await;
    assert_eq!(w["visible"], json!(false), "{w}");
    let r = fx.call(TAG_A, json!({"op": "read"})).await;
    assert!(r.get("error").is_none() && r["version"].is_u64(), "{r}");
    assert!(
        String::from_utf8(fx.board("triage")).unwrap().contains("still works"),
        "the write reached the file"
    );
    assert!(!any_focus_layout(&fx.drain()), "writes never send a layout");
    assert_eq!(fx.tree(TAG_A), tree, "and never re-add the pane");

    // `open` without `show` says why, and does not re-add it.
    let res = fx.open(TAG_A, "triage").await;
    assert_eq!(res["hidden_by_user"], json!(true), "{res}");
    assert_eq!(res["visible"], json!(false), "{res}");
    assert!(!any_focus_layout(&fx.drain()), "no layout for a hidden open");
    assert_eq!(fx.tree(TAG_A), tree);

    // `show: true` brings it back: one layout, no focus taken.
    let res = fx.ok(TAG_A, json!({"op": "open", "topic": "triage", "show": true})).await;
    assert!(res.get("hidden_by_user").is_none(), "{res}");
    let frames = fx.drain();
    let sent = layouts(&frames, TAG_A);
    assert_eq!(sent.len(), 1, "exactly one FocusLayout: {frames:?}");
    assert_eq!(sent[0].1, None, "focused_pane is None");
    assert!(has_tracker(&sent[0].0), "{:?}", sent[0].0);
    assert_label_is_literal(&sent[0].0);
    assert!(!serde_json::to_string(&sent[0].0).unwrap().contains("SECRET-TRACKER-3"));
    assert_eq!(fx.tree(TAG_A), sent[0].0);

    // Afterwards it is no longer hidden.
    let res = fx.open(TAG_A, "triage").await;
    assert!(res.get("hidden_by_user").is_none(), "{res}");
    assert!(!any_focus_layout(&fx.drain()), "already there: no layout");
    assert!(!fx.registry.pane_hidden_by_user(TAG_A));
}

#[tokio::test]
async fn closing_the_split_tracker_keeps_the_board_and_only_show_brings_it_back() {
    pane_leaves_then_stays_gone(PaneTree::repl_leaf(), close_like_clicking_x).await;
}

#[tokio::test]
async fn closing_the_detail_tab_tracker_keeps_the_board_and_only_show_brings_it_back() {
    pane_leaves_then_stays_gone(detail_layout(), close_like_clicking_x).await;
}

#[tokio::test]
async fn a_layout_call_that_drops_the_split_tracker_hides_it_the_same_way() {
    pane_leaves_then_stays_gone(PaneTree::repl_leaf(), layout_without_tracker).await;
}

#[tokio::test]
async fn a_layout_call_that_drops_the_detail_tab_tracker_hides_it_the_same_way() {
    pane_leaves_then_stays_gone(detail_layout(), layout_without_tracker).await;
}

#[tokio::test]
async fn resetting_the_panes_of_a_focus_with_a_split_tracker_hides_it_the_same_way() {
    pane_leaves_then_stays_gone(PaneTree::repl_leaf(), reset_panes).await;
}

#[tokio::test]
async fn resetting_the_panes_of_a_focus_with_a_detail_tab_tracker_hides_it_the_same_way() {
    pane_leaves_then_stays_gone(detail_layout(), reset_panes).await;
}

#[tokio::test]
async fn a_layout_call_that_adds_the_tracker_leaf_back_clears_the_hidden_state() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.open(TAG_A, "triage").await;
    close_like_clicking_x(&fx, TAG_A);
    assert_eq!(fx.open(TAG_A, "triage").await["hidden_by_user"], json!(true));

    fx.set_tree(TAG_A, &split_with_tracker());
    fx.drain();
    let res = fx.open(TAG_A, "triage").await;
    assert!(res.get("hidden_by_user").is_none(), "{res}");
    assert!(!any_focus_layout(&fx.drain()), "the pane was already back");
}

// ---------------------------------------------------------------------------
// (f) A focus with no tracker is unaffected
// ---------------------------------------------------------------------------

#[tokio::test]
async fn a_focus_with_no_bound_board_is_never_hidden_by_its_tree_changing() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "triage").await;

    // TAG_B has no board: its tree changes, including a tracker-named leaf
    // coming and going.
    fx.set_tree(TAG_B, &split_with_tracker());
    fx.set_tree(TAG_B, &PaneTree::repl_leaf());
    fx.set_tree(TAG_B, &detail_layout());
    fx.panes.lock().unwrap().reset(TAG_B).unwrap();
    assert!(!fx.registry.pane_hidden_by_user(TAG_B));
    assert!(!fx.registry.has_bound_board(TAG_B));

    // So its first open places the pane normally.
    fx.drain();
    let res = fx.open(TAG_B, "other").await;
    assert!(res.get("hidden_by_user").is_none(), "{res}");
    assert_eq!(layouts(&fx.drain(), TAG_B).len(), 1);
    assert!(has_tracker(&fx.tree(TAG_B)));

    // And TAG_A, bound, is untouched by all of that.
    assert!(has_tracker(&fx.tree(TAG_A)));
    assert!(!fx.registry.pane_hidden_by_user(TAG_A));
}

#[tokio::test]
async fn closing_one_focus_tracker_hides_only_that_focus() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.seat(TAG_B, "sess-b");
    fx.open(TAG_A, "triage").await;
    fx.open(TAG_B, "other").await;

    close_like_clicking_x(&fx, TAG_A);

    assert_eq!(fx.open(TAG_A, "triage").await["hidden_by_user"], json!(true));
    assert!(fx.open(TAG_B, "other").await.get("hidden_by_user").is_none());
    assert!(has_tracker(&fx.tree(TAG_B)));
}

// ---------------------------------------------------------------------------
// (g) The label, in every tree produced
// ---------------------------------------------------------------------------

#[tokio::test]
async fn the_tracker_tab_is_captioned_tracker_in_every_layout_the_daemon_sends() {
    let fx = Fx::new();
    fx.seat(TAG_A, "sess-a");
    fx.set_tree(TAG_A, &detail_layout());
    fx.ok(TAG_A, json!({"op": "open", "topic": "secret-tracker-4"})).await;
    close_like_clicking_x(&fx, TAG_A);
    fx.drain();
    fx.ok(TAG_A, json!({"op": "open", "topic": "secret-tracker-4", "show": true})).await;

    let frames = fx.drain();
    let sent = layouts(&frames, TAG_A);
    assert_eq!(sent.len(), 1);
    assert_eq!(tracker_tab_labels(&sent[0].0), ["Tracker"]);
    let json = serde_json::to_string(&frames.iter().filter_map(|m| match m {
        ServerMsg::FocusLayout { tree, .. } => Some(tree.clone()),
        _ => None,
    }).collect::<Vec<_>>()).unwrap();
    assert!(!json.contains("secret-tracker-4"), "{json}");
}
