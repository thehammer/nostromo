//! Tracker state across a daemon restart (slice T0b, contract §3 "Persistence
//! and restart", PRD 23 and 24 daemon halves).
//!
//! A "restart" here is dropping one `TrackerRegistry` and building a new one
//! from the same state root. Hermetic: a `FakeClock`, temp dirs for the repo,
//! state root and home, no git repo, no real `~/.nostromo`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use nostromo::ipc::pane_registry::TrackerFrameProvider;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::tracker::view::{Banner, ViewNode};
use nostromo::tracker::{
    Author, FakeClock, Op, OpenArgs, ReadOutcome, RegistryParts, TrackerRegistry, Upsert,
};
use serde_json::{json, Value};
use tempfile::TempDir;

const TAG_A: &str = "cody-a";
const TAG_B: &str = "cody-b";
const SESS_A: &str = "sess-a";
const SESS_B: &str = "sess-b";
const FILE_LABEL: &str = "file (unknown editor)";

struct Rig {
    _tmp: TempDir,
    repo: PathBuf,
    state_root: PathBuf,
    home: PathBuf,
    clock: Arc<FakeClock>,
}

fn agent_a() -> Author {
    Author::Agent {
        focus: TAG_A.into(),
        session_id: SESS_A.into(),
        name: TAG_A.into(),
    }
}

fn upsert(id: &str, section: &str, text: &str) -> Op {
    Op::Upsert(Upsert {
        id: Some(id.into()),
        section: Some(section.into()),
        text: Some(text.into()),
        ..Default::default()
    })
}

fn status(id: &str, status: &str) -> Op {
    Op::Status {
        id: id.into(),
        status: status.into(),
    }
}

impl Rig {
    fn new() -> Rig {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        let state_root = base.join("state");
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        Rig {
            _tmp: tmp,
            repo,
            state_root,
            home,
            clock: Arc::new(FakeClock::at_secs(1_760_540_000)),
        }
    }

    /// A registry over this rig's state root: the daemon "starting".
    fn start(&self) -> TrackerRegistry {
        TrackerRegistry::new(RegistryParts::hermetic(
            self.state_root.clone(),
            self.home.clone(),
            self.clock.clone(),
        ))
    }

    fn open_args(&self) -> OpenArgs {
        OpenArgs {
            topic: Some("persist".into()),
            cwd: self.repo.clone(),
            ..Default::default()
        }
    }

    /// Two focuses on one board; the first session writes a few items.
    fn seeded(&self, reg: &TrackerRegistry) -> PathBuf {
        let path = reg.open(TAG_A, SESS_A, &self.open_args()).expect("open a").path;
        reg.open(TAG_B, SESS_B, &self.open_args()).expect("open b");
        reg.apply(
            TAG_A,
            SESS_A,
            &[
                upsert("alpha", "now", "Alpha task"),
                upsert("beta", "now", "Beta task"),
                upsert("gamma", "next", "Gamma task"),
            ],
            &agent_a(),
        )
        .expect("seed");
        path
    }
}

fn text_of(path: &Path) -> String {
    String::from_utf8(std::fs::read(path).unwrap()).unwrap()
}

fn changes_of(outcome: ReadOutcome) -> Vec<Value> {
    match outcome {
        ReadOutcome::Delta { changes, .. } => changes,
        ReadOutcome::Full { .. } => panic!("expected a delta, got the whole board"),
    }
}

// ---------------------------------------------------------------------------
// Bindings, cursors, versions
// ---------------------------------------------------------------------------

#[test]
fn bindings_survive_a_restart() {
    let rig = Rig::new();
    let path = {
        let reg = rig.start();
        rig.seeded(&reg)
    };

    let reg = rig.start();

    assert_eq!(reg.bound_path(TAG_A), Some(path.clone()));
    assert_eq!(reg.bound_path(TAG_B), Some(path.clone()));
    assert_eq!(reg.bound_tags_for(&path), vec![TAG_A.to_string(), TAG_B.to_string()]);
    let summary = reg.summary(TAG_B);
    assert!(summary.has_tracker);
    assert_eq!(summary.counts.todo, 3);
    assert!(reg.board_view(TAG_A).is_some(), "the board is back, parsed from the file");
}

#[test]
fn a_session_that_resumes_after_a_restart_gets_only_what_changed_since_its_cursor() {
    let rig = Rig::new();
    {
        let reg = rig.start();
        rig.seeded(&reg);
        // B reads everything so far: its cursor is at the current version.
        let _ = reg.read(TAG_B, SESS_B).unwrap();
        // Then A changes something B has not seen.
        reg.apply(TAG_A, SESS_A, &[status("alpha", "done")], &agent_a()).unwrap();
    }

    let reg = rig.start();
    let outcome = reg.read(TAG_B, SESS_B).expect("read after the restart");

    let changes = changes_of(outcome);
    assert_eq!(changes.len(), 1, "a resumed session gets a delta, not the board: {changes:?}");
    assert_eq!(changes[0]["id"], json!("alpha"));
    assert_eq!(changes[0]["status"][1], json!("done"));
    assert!(changes[0]["by"].as_str().is_some_and(|b| b.starts_with("agent ")), "{changes:?}");
    // And the cursor advanced: nothing more to read.
    assert!(changes_of(reg.read(TAG_B, SESS_B).unwrap()).is_empty());
}

#[test]
fn a_different_session_id_after_a_restart_gets_the_whole_board() {
    let rig = Rig::new();
    {
        let reg = rig.start();
        rig.seeded(&reg);
        let _ = reg.read(TAG_B, SESS_B).unwrap();
    }

    let reg = rig.start();
    // The focus is the same; the Claude session is a different one (a fresh spawn).
    let outcome = reg.read(TAG_B, "sess-b-fresh").expect("read after the restart");

    match outcome {
        ReadOutcome::Full { board, .. } => {
            for needle in ["alpha", "Alpha task", "Beta task", "Gamma task"] {
                assert!(board.contains(needle), "{needle} in {board}");
            }
        }
        ReadOutcome::Delta { changes, .. } => {
            panic!("a session with no cursor must get the whole board, got a delta: {changes:?}")
        }
    }
    // The original session still resumes by delta.
    assert!(changes_of(reg.read(TAG_B, SESS_B).unwrap()).is_empty());
}

#[test]
fn the_version_continues_after_a_restart() {
    let rig = Rig::new();
    let version = {
        let reg = rig.start();
        rig.seeded(&reg);
        reg.apply(TAG_A, SESS_A, &[status("beta", "blocked")], &agent_a())
            .unwrap()
            .version
    };

    let reg = rig.start();
    let view_version = reg.board_view(TAG_A).unwrap().version;
    let next = reg
        .apply(TAG_A, SESS_A, &[status("beta", "done")], &agent_a())
        .unwrap()
        .version;

    assert_eq!(view_version, version, "the reloaded board shows the persisted version");
    assert_eq!(next, version + 1, "the next change is the next version, not version 1 again");
}

// ---------------------------------------------------------------------------
// The file is re-read on load
// ---------------------------------------------------------------------------

#[test]
fn an_edit_made_while_the_daemon_was_down_is_ingested_as_a_file_change() {
    let rig = Rig::new();
    let path = {
        let reg = rig.start();
        let path = rig.seeded(&reg);
        let _ = reg.read(TAG_B, SESS_B).unwrap();
        path
    };
    // The daemon is down; the user ticks alpha and rewrites gamma in an editor.
    let edited = text_of(&path)
        .replace("- [ ] Alpha task", "- [x] Alpha task")
        .replace("Gamma task", "Gamma task, rewritten while the daemon was down");
    std::fs::write(&path, edited).unwrap();

    let reg = rig.start();

    let view = reg.board_view(TAG_B).unwrap();
    let texts: Vec<String> = view
        .nodes
        .iter()
        .filter_map(|n| match n {
            ViewNode::Item(i) => Some(format!("{} {:?} {:?}", i.id, i.status, i.text_spans)),
            _ => None,
        })
        .collect();
    assert!(texts.iter().any(|t| t.starts_with("alpha Done")), "{texts:?}");
    assert!(texts.iter().any(|t| t.contains("rewritten while the daemon was down")), "{texts:?}");
    assert_eq!(reg.user_changes(TAG_B, SESS_B), 2, "two user changes since B's cursor");

    let changes = changes_of(reg.read(TAG_B, SESS_B).unwrap());
    assert_eq!(changes.len(), 2, "{changes:?}");
    for c in &changes {
        assert_eq!(c["by"], json!(FILE_LABEL), "{c}");
    }
    let ids: Vec<&Value> = changes.iter().map(|c| &c["id"]).collect();
    assert!(ids.contains(&&json!("alpha")) && ids.contains(&&json!("gamma")), "{changes:?}");
}

// ---------------------------------------------------------------------------
// Attach replay (PRD 23 daemon half)
// ---------------------------------------------------------------------------

#[test]
fn the_attach_replay_of_a_restarted_registry_carries_the_board_and_summary_of_every_bound_tag() {
    let rig = Rig::new();
    let path = {
        let reg = rig.start();
        let path = rig.seeded(&reg);
        reg.apply(TAG_A, SESS_A, &[status("alpha", "needs-you")], &agent_a()).unwrap();
        path
    };
    // An edit made while the daemon was down must be in the replayed board.
    std::fs::write(&path, text_of(&path).replace("Beta task", "Beta task (edited offline)")).unwrap();

    let reg = rig.start();
    let frames = reg.tracker_frames();

    for tag in [TAG_A, TAG_B] {
        let board = frames
            .iter()
            .find_map(|m| match m {
                ServerMsg::TrackerBoard { tag: t, board } if t == tag => Some(board),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no tracker_board for {tag}: {frames:?}"))
            .as_ref()
            .unwrap_or_else(|| panic!("the tracker_board for {tag} carries a board"));
        assert_eq!(board.path, path.display().to_string());
        assert!(format!("{:?}", board.nodes).contains("edited offline"), "{tag}: the replay is the file as it is now");
        assert_eq!(board.banner, None);

        let (has_tracker, counts) = frames
            .iter()
            .find_map(|m| match m {
                ServerMsg::TrackerSummary { tag: t, has_tracker, counts } if t == tag => Some((*has_tracker, *counts)),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no tracker_summary for {tag}: {frames:?}"));
        assert!(has_tracker);
        assert_eq!((counts.needs_you, counts.todo), (1, 2), "{tag}");
    }
}

#[test]
fn a_registry_with_no_bound_boards_has_nothing_to_replay() {
    let rig = Rig::new();
    let reg = rig.start();
    assert!(reg.tracker_frames().is_empty());
}

// ---------------------------------------------------------------------------
// Last-good recreate after a reload
// ---------------------------------------------------------------------------

#[test]
fn a_board_deleted_while_the_daemon_was_down_shows_missing_and_open_recreates_it_from_last_good() {
    let rig = Rig::new();
    let (path, last_good) = {
        let reg = rig.start();
        let path = rig.seeded(&reg);
        let bytes = std::fs::read(&path).unwrap();
        (path, bytes)
    };
    std::fs::remove_file(&path).unwrap();

    let reg = rig.start();

    let view = reg.board_view(TAG_A).expect("the last good board is still shown");
    assert!(matches!(view.banner, Some(Banner::Missing { .. })), "{:?}", view.banner);
    assert!(format!("{:?}", view.nodes).contains("Alpha task"));
    let err = reg
        .apply(TAG_A, SESS_A, &[status("alpha", "done")], &agent_a())
        .expect_err("the file is gone");
    assert_eq!(err.code(), "board_missing");
    assert!(!path.exists());

    let opened = reg.open(TAG_A, SESS_A, &rig.open_args()).expect("open recreates");
    assert!(opened.recreated, "{opened:?}");
    assert!(!opened.created, "{opened:?}");
    assert_eq!(std::fs::read(&path).unwrap(), last_good);
    assert_eq!(reg.board_view(TAG_A).unwrap().banner, None);
}

// ---------------------------------------------------------------------------
// A corrupt state file
// ---------------------------------------------------------------------------

#[test]
fn a_corrupt_state_file_is_ignored_and_the_registry_starts_empty_and_works() {
    let valid = {
        let rig = Rig::new();
        let reg = rig.start();
        rig.seeded(&reg);
        std::fs::read(rig.state_root.join("trackers/state.json")).expect("state.json is written")
    };
    let truncated = valid[..valid.len() / 2].to_vec();
    let cases: Vec<(&str, Vec<u8>)> = vec![
        ("garbage", b"\x00\xff not json at all {{{".to_vec()),
        ("empty", Vec::new()),
        ("wrong shape", b"[1, 2, 3]".to_vec()),
        ("wrong field types", br#"{"bindings": 5, "boards": "x", "cursors": []}"#.to_vec()),
        ("truncated", truncated),
    ];
    for (name, bytes) in cases {
        let rig = Rig::new();
        let dir = rig.state_root.join("trackers");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("state.json"), &bytes).unwrap();

        let reg = rig.start();

        assert_eq!(reg.bound_path(TAG_A), None, "{name}");
        assert!(reg.tracker_frames().is_empty(), "{name}");
        assert!(!reg.summary(TAG_A).has_tracker, "{name}");
        // It still works, and what it writes is loadable.
        let path = rig.seeded(&reg);
        drop(reg);
        let reg = rig.start();
        assert_eq!(reg.bound_path(TAG_A), Some(path), "{name}: state written after the corrupt file is valid");
        assert!(reg.summary(TAG_A).has_tracker, "{name}");
    }
}

#[test]
fn state_pointing_at_a_board_that_can_no_longer_be_read_does_not_stop_the_daemon() {
    let rig = Rig::new();
    let path = {
        let reg = rig.start();
        rig.seeded(&reg)
    };
    // The board was replaced by a broken file while the daemon was down.
    std::fs::write(&path, b"# Broken\n\n## Now\n- [ ] One <!-- #dup-1 1760540000 -->\n- [ ] Two <!-- #dup-1 1760540001 -->\n").unwrap();

    let reg = rig.start();

    let view = reg.board_view(TAG_A).expect("the last good board is shown");
    assert!(matches!(view.banner, Some(Banner::Unreadable { line: 5, .. })), "{:?}", view.banner);
    assert!(format!("{:?}", view.nodes).contains("Alpha task"));
    assert_eq!(reg.tracker_frames().len(), 4, "replay still sends both tags' frames");
}

// ---------------------------------------------------------------------------
// Closed-by-user flag (T0c follow-up)
// ---------------------------------------------------------------------------

#[test]
fn a_user_closed_tracker_stays_closed_across_a_restart() {
    let rig = Rig::new();
    {
        let reg = rig.start();
        rig.seeded(&reg);
        reg.set_pane_hidden_by_user(TAG_A, true);
    }

    let reg = rig.start();

    assert!(reg.pane_hidden_by_user(TAG_A));
    assert!(!reg.pane_hidden_by_user(TAG_B), "the flag is per focus");
    let out = reg.open(TAG_A, SESS_A, &rig.open_args()).expect("open");
    assert!(out.hidden_by_user);
}

#[test]
fn show_clears_the_closed_flag_and_the_clear_persists() {
    let rig = Rig::new();
    {
        let reg = rig.start();
        rig.seeded(&reg);
        reg.set_pane_hidden_by_user(TAG_A, true);
    }
    {
        let reg = rig.start();
        let args = OpenArgs {
            show: true,
            ..rig.open_args()
        };
        let out = reg.open(TAG_A, SESS_A, &args).expect("open show");
        assert!(!out.hidden_by_user);
        assert!(!reg.pane_hidden_by_user(TAG_A));
    }

    let reg = rig.start();

    assert!(!reg.pane_hidden_by_user(TAG_A));
}

#[test]
fn state_written_before_the_closed_flag_existed_loads_as_not_hidden() {
    let rig = Rig::new();
    {
        let reg = rig.start();
        rig.seeded(&reg);
        reg.set_pane_hidden_by_user(TAG_A, true);
    }
    let state = rig.state_root.join("trackers").join("state.json");
    let mut doc: Value = serde_json::from_slice(&std::fs::read(&state).unwrap()).unwrap();
    assert_eq!(doc["hidden"], json!([TAG_A]), "the flag is written");
    doc.as_object_mut().unwrap().remove("hidden");
    doc["some_future_field"] = json!({"x": 1});
    std::fs::write(&state, serde_json::to_vec(&doc).unwrap()).unwrap();

    let reg = rig.start();

    assert!(!reg.pane_hidden_by_user(TAG_A));
    assert!(reg.bound_path(TAG_A).is_some(), "the rest of the state still loads");
}
