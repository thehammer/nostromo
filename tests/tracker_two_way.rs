//! The two-way tracker, daemon side (slice T3a): the pane's `tracker_edit`
//! verb, conflicts between the three writers, and sensitive text the user
//! brings in. PRD 36, 38, 41, 43 (daemon halves).
//!
//! Hermetic: a `FakeClock`, temp dirs for the repo, state root and home, no
//! git repo, no real `~/.nostromo`, no spawned `claude`. A "restart" is
//! dropping one registry and building another over the same state root.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::Duration as ChronoDuration;
use nostromo::ipc::pane_registry::PaneRegistry;
use nostromo::ipc::protocol::{ConflictKeep, ServerMsg, TrackerPaneOp};
use nostromo::ipc::SessionManager;
use nostromo::mcp::tools::tracker_edit::tracker_edit;
use nostromo::mcp::{DaemonMcpBackend, McpSharedState, PerriDaemonState};
use nostromo::tracker::view::{ViewItem, ViewNode};
use nostromo::tracker::{
    parse, Author, Desired, FakeClock, Op, OpenArgs, PaneEditError, PaneEditOutcome, ReadOutcome,
    RegistryParts, Status, TrackerError, TrackerRegistry, Upsert, WITHHELD,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const TAG_A: &str = "cody-a";
const TAG_B: &str = "cody-b";
const SESS_A: &str = "sess-a";
const SESS_B: &str = "sess-b";
const PANE: &str = "pane (you)";
// A synthetic SSN from the guard's own positives.
const SSN: &str = "219-09-9999";

struct Rig {
    _tmp: TempDir,
    base: PathBuf,
    state_root: PathBuf,
    home: PathBuf,
    clock: Arc<FakeClock>,
    reg: Arc<TrackerRegistry>,
    path: PathBuf,
}

fn agent(tag: &str, session: &str) -> Author {
    Author::Agent {
        focus: tag.into(),
        session_id: session.into(),
        name: tag.into(),
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

fn status_op(id: &str, status: &str) -> Op {
    Op::Status {
        id: id.into(),
        status: status.into(),
    }
}

fn pane_status(id: &str, status: &str) -> TrackerPaneOp {
    TrackerPaneOp::Status {
        id: id.into(),
        status: status.into(),
    }
}

fn pane_edit_body(id: &str, body: &str) -> TrackerPaneOp {
    TrackerPaneOp::Edit {
        id: id.into(),
        title: None,
        text: None,
        body: Some(body.into()),
    }
}

impl Rig {
    fn new() -> Rig {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let (repo, home, state_root) = (base.join("repo"), base.join("home"), base.join("state"));
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let reg = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            state_root.clone(),
            home.clone(),
            clock.clone(),
        )));
        let args = OpenArgs {
            topic: Some("two-way".into()),
            cwd: repo.clone(),
            ..Default::default()
        };
        let path = reg.open(TAG_A, SESS_A, &args).expect("open a").path;
        reg.open(TAG_B, SESS_B, &args).expect("open b");
        reg.apply(
            TAG_A,
            SESS_A,
            &[
                upsert("alpha", "now", "Alpha task"),
                upsert("beta", "now", "Beta task"),
                upsert("gamma", "next", "Gamma task"),
            ],
            &agent(TAG_A, SESS_A),
        )
        .expect("seed");
        // Both agents have read everything so far.
        reg.read(TAG_A, SESS_A).unwrap();
        reg.read(TAG_B, SESS_B).unwrap();
        Rig {
            _tmp: tmp,
            base,
            state_root,
            home,
            clock,
            reg,
            path,
        }
    }

    /// A new registry over this rig's state root: the daemon restarting.
    fn restart(&mut self) {
        self.reg = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            self.state_root.clone(),
            self.home.clone(),
            self.clock.clone(),
        )));
    }

    fn version(&self) -> u64 {
        self.reg.board_view(TAG_A).expect("a board").version
    }

    fn pane(&self, ops: Vec<TrackerPaneOp>) -> Result<PaneEditOutcome, PaneEditError> {
        self.reg.apply_pane_ops(TAG_A, self.version(), &ops)
    }

    fn pane_at(
        &self,
        base: u64,
        ops: Vec<TrackerPaneOp>,
    ) -> Result<PaneEditOutcome, PaneEditError> {
        self.reg.apply_pane_ops(TAG_A, base, &ops)
    }

    fn agent_a(&self, ops: &[Op]) -> Result<nostromo::tracker::WriteOutcome, TrackerError> {
        self.reg.apply(TAG_A, SESS_A, ops, &agent(TAG_A, SESS_A))
    }

    fn agent_b(&self, ops: &[Op]) -> Result<nostromo::tracker::WriteOutcome, TrackerError> {
        self.reg.apply(TAG_B, SESS_B, ops, &agent(TAG_B, SESS_B))
    }

    fn text(&self) -> String {
        String::from_utf8(std::fs::read(&self.path).unwrap()).unwrap()
    }

    /// The user saves `text` in an editor.
    fn save(&self, text: &str) {
        std::fs::write(&self.path, text).unwrap();
        self.reg.ingest_file_change(&self.path);
    }

    /// Agent B opens the board again (a fresh `open` of a board it has read).
    fn reopen_b(&self) {
        let args = OpenArgs {
            topic: Some("two-way".into()),
            cwd: self.base.join("repo"),
            ..Default::default()
        };
        self.reg.open(TAG_B, SESS_B, &args).expect("re-open b");
    }

    /// The (losing value, who lost it) of each of `id`'s conflicts on `field`.
    fn losers(&self, id: &str, field: &str) -> Vec<String> {
        self.item(id)
            .conflicts
            .into_iter()
            .filter(|c| c.field == field)
            .map(|c| c.losing)
            .collect()
    }

    /// A status conflict on `alpha`: agent A's `in-progress` lost to the
    /// pane's `done` two seconds later. Returns the version the pane saw.
    fn first_status_conflict(&self) -> u64 {
        self.tick(100);
        self.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
        self.tick(2);
        self.pane(vec![pane_status("alpha", "done")]).unwrap();
        assert_eq!(self.losers("alpha", "status"), vec!["in-progress"]);
        self.version()
    }

    fn tick(&self, secs: i64) {
        self.clock.advance(ChronoDuration::seconds(secs));
    }

    fn item(&self, id: &str) -> ViewItem {
        self.reg
            .board_view(TAG_A)
            .unwrap()
            .nodes
            .into_iter()
            .find_map(|n| match n {
                ViewNode::Item(i) if i.id == id => Some(i),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no item {id}"))
    }

    fn has_item(&self, id: &str) -> bool {
        self.reg
            .board_view(TAG_A)
            .unwrap()
            .nodes
            .iter()
            .any(|n| matches!(n, ViewNode::Item(i) if i.id == id))
    }

    fn delta(&self, tag: &str, session: &str) -> Vec<Value> {
        match self.reg.read(tag, session).expect("read") {
            ReadOutcome::Delta { changes, .. } => changes,
            ReadOutcome::Full { .. } => panic!("expected a delta"),
        }
    }
}

/// `text` without the bytes of item `id`.
fn without_item(text: &str, id: &str) -> String {
    let parsed = parse(text.as_bytes()).unwrap();
    match parsed.item_span(id) {
        Some(span) => format!("{}{}", &text[..span.start], &text[span.end..]),
        None => text.to_string(),
    }
}

fn conflict_entries(delta: &[Value]) -> Vec<&Value> {
    delta
        .iter()
        .filter(|e| e.get("conflict").is_some())
        .collect()
}

// ---------------------------------------------------------------------------
// The verb's ops (PRD 36, daemon half; T3A-2, T3A-3)
// ---------------------------------------------------------------------------

#[test]
fn every_pane_op_lands_in_the_file_changing_only_that_items_bytes() {
    let rig = Rig::new();
    let before = rig.text();

    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    let after = rig.text();
    assert_ne!(before, after);
    assert_eq!(
        without_item(&before, "alpha"),
        without_item(&after, "alpha")
    );
    assert_eq!(rig.item("alpha").status, Status::Done);

    let before = rig.text();
    rig.pane(vec![TrackerPaneOp::Edit {
        id: "beta".into(),
        title: Some("Beta, renamed".into()),
        text: None,
        body: Some("some details".into()),
    }])
    .unwrap();
    let after = rig.text();
    assert_eq!(without_item(&before, "beta"), without_item(&after, "beta"));
    let beta = rig.item("beta");
    assert_eq!(beta.text, "Beta, renamed");
    assert_eq!(beta.note.as_deref(), Some("some details"));

    let before = rig.text();
    rig.pane(vec![TrackerPaneOp::Move {
        id: "gamma".into(),
        section: "now".into(),
        before: Some("alpha".into()),
        after: None,
    }])
    .unwrap();
    let after = rig.text();
    assert_eq!(
        without_item(&before, "gamma"),
        without_item(&after, "gamma")
    );
    assert_eq!(rig.item("gamma").section, "now");

    let before = rig.text();
    rig.pane(vec![TrackerPaneOp::Remove { id: "beta".into() }])
        .unwrap();
    assert_eq!(rig.text(), without_item(&before, "beta"));
    assert!(!rig.has_item("beta"));
}

#[test]
fn a_pane_op_is_attributed_to_the_pane_and_the_board_is_flushed() {
    let rig = Rig::new();
    let (tx, mut rx) = broadcast::channel::<ServerMsg>(64);
    rig.reg.flush(&tx);
    while rx.try_recv().is_ok() {}
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.reg.flush(&tx);
    let mut saw_board = false;
    while let Ok(msg) = rx.try_recv() {
        saw_board |= matches!(msg, ServerMsg::TrackerBoard { board: Some(_), .. });
    }
    assert!(saw_board, "the edit marks the board for the next flush");
    let delta = rig.delta(TAG_B, SESS_B);
    assert_eq!(delta.len(), 1, "{delta:?}");
    assert_eq!(delta[0]["by"], PANE);
    assert_eq!(delta[0]["id"], "alpha");
    assert_eq!(delta[0]["status"], json!(["todo", "done"]));
}

#[test]
fn add_reports_its_id_and_places_the_item_by_its_neighbour() {
    let rig = Rig::new();
    let added = rig
        .pane(vec![
            TrackerPaneOp::Add {
                section: "now".into(),
                title: "Placed before beta".into(),
                body: None,
                before: Some("beta".into()),
                after: None,
            },
            TrackerPaneOp::Add {
                section: "now".into(),
                title: "Placed after alpha".into(),
                body: Some("why".into()),
                before: None,
                after: Some("alpha".into()),
            },
        ])
        .unwrap();
    assert_eq!(added.created.len(), 2);
    assert_ne!(added.created[0], added.created[1]);
    let order: Vec<String> = rig
        .reg
        .board_view(TAG_A)
        .unwrap()
        .nodes
        .into_iter()
        .filter_map(|n| match n {
            ViewNode::Item(i) if i.section == "now" => Some(i.id),
            _ => None,
        })
        .collect();
    assert_eq!(
        order,
        vec![
            "alpha".to_string(),
            added.created[1].clone(),
            added.created[0].clone(),
            "beta".to_string()
        ]
    );
    assert_eq!(rig.item(&added.created[1]).status, Status::Todo);
    assert_eq!(rig.item(&added.created[1]).note.as_deref(), Some("why"));
}

#[test]
fn remove_then_restore_is_byte_identical_for_every_item_of_a_rich_board() {
    let rig = Rig::new();
    let board = std::fs::read("tests/fixtures/tracker/board-60.md").unwrap();
    std::fs::write(&rig.path, &board).unwrap();
    rig.reg.ingest_file_change(&rig.path);
    let ids: Vec<(String, String)> = rig
        .reg
        .board_view(TAG_A)
        .unwrap()
        .nodes
        .into_iter()
        .filter_map(|n| match n {
            ViewNode::Item(i) => Some((i.id, i.section)),
            _ => None,
        })
        .collect();
    assert!(ids.len() > 10);
    for (id, section) in ids {
        let view = rig.reg.board_view(TAG_A).unwrap();
        let siblings: Vec<&ViewItem> = view
            .nodes
            .iter()
            .filter_map(|n| match n {
                ViewNode::Item(i) if i.section == section => Some(i),
                _ => None,
            })
            .collect();
        let pos = siblings.iter().position(|i| i.id == id).unwrap();
        let source = siblings[pos].source.clone();
        let after = pos.checked_sub(1).map(|p| siblings[p].id.clone());
        let next = siblings.get(pos + 1).map(|i| i.id.clone());
        let original = rig.text();

        rig.pane(vec![TrackerPaneOp::Remove { id: id.clone() }])
            .unwrap();
        assert_ne!(rig.text(), original);
        let (before, after) = if after.is_some() {
            (None, after)
        } else {
            (next, None)
        };
        rig.pane(vec![TrackerPaneOp::Restore {
            source,
            section: section.clone(),
            before,
            after,
        }])
        .unwrap();
        assert_eq!(rig.text(), original, "remove then restore of {id}");
    }
}

#[test]
fn restore_returns_a_hand_formatted_item_exactly_as_it_was() {
    let rig = Rig::new();
    // The tail's time (09:00) is not the marker's (14:53): a regenerated item would
    // say 14:53, so only the original bytes make the file come back unchanged.
    let hand =
        "- [ ] Hand edited   item — todo · 09:00 <!-- #hand-1 1760540000 -->\n  my own  note\n";
    rig.save(&rig.text().replace("## Next\n", &format!("## Next\n{hand}")));
    assert!(rig.has_item("hand-1"));
    let original = rig.text();
    let source = rig.item("hand-1").source;
    rig.pane(vec![TrackerPaneOp::Remove {
        id: "hand-1".into(),
    }])
    .unwrap();
    assert!(!rig.text().contains("Hand edited"));
    rig.pane(vec![TrackerPaneOp::Restore {
        source,
        section: "next".into(),
        before: Some("gamma".into()),
        after: None,
    }])
    .unwrap();
    assert_eq!(rig.text(), original);
}

#[test]
fn restore_refuses_an_existing_id_two_items_or_too_much() {
    let rig = Rig::new();
    let alpha = rig.item("alpha").source;
    let two = format!("{}{}", rig.item("alpha").source, rig.item("beta").source);
    let before = rig.text();
    for (source, why) in [
        (alpha, "an id that exists"),
        (two, "two items"),
        ("not an item\n".to_string(), "no item"),
        (
            format!(
                "- [ ] big — todo · 10:00 <!-- #big-1 1760540000 -->\n  {}\n",
                "x".repeat(9_100)
            ),
            "oversize",
        ),
    ] {
        let err = rig
            .pane(vec![TrackerPaneOp::Restore {
                source,
                section: "now".into(),
                before: None,
                after: None,
            }])
            .expect_err(why);
        assert_eq!(err.code, "invalid_args", "{why}");
        assert_eq!(err.index, Some(0), "{why}");
    }
    assert_eq!(rig.text(), before);
}

#[test]
fn a_title_over_80_characters_or_with_a_newline_is_invalid_and_changes_nothing() {
    let rig = Rig::new();
    let (before, version) = (rig.text(), rig.version());
    for title in [
        "x".repeat(81),
        "two\nlines".to_string(),
        "bidi \u{202E} title".to_string(),
    ] {
        let err = rig
            .pane(vec![TrackerPaneOp::Edit {
                id: "alpha".into(),
                title: Some(title),
                text: None,
                body: None,
            }])
            .expect_err("a bad title");
        assert_eq!(err.code, "invalid_args");
    }
    let err = rig
        .pane(vec![TrackerPaneOp::Edit {
            id: "alpha".into(),
            title: None,
            text: None,
            body: None,
        }])
        .expect_err("an empty edit");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(rig.text(), before);
    assert_eq!(rig.version(), version);
}

#[test]
fn a_failing_op_refuses_the_whole_batch_and_names_its_index() {
    let rig = Rig::new();
    let before = rig.text();
    let err = rig
        .pane(vec![
            pane_status("alpha", "done"),
            pane_status("nope", "done"),
        ])
        .expect_err("unknown item");
    assert_eq!((err.code.as_str(), err.index), ("unknown_item", Some(1)));
    assert_eq!(rig.text(), before);
}

#[test]
fn restructuring_a_legacy_item_and_undoing_it_gives_back_its_text_and_note() {
    let rig = Rig::new();
    let long = format!(
        "Legacy title. {}",
        "and the rest of a long sentence ".repeat(6)
    );
    rig.agent_a(&[Op::Upsert(Upsert {
        id: Some("legacy".into()),
        section: Some("now".into()),
        text: Some(long.trim().to_string()),
        note: Some("old note".into()),
        ..Default::default()
    })])
    .unwrap();
    let original = rig.text();
    let old = rig.item("legacy");
    rig.pane(vec![TrackerPaneOp::Edit {
        id: "legacy".into(),
        title: Some("Legacy title.".into()),
        text: None,
        body: Some("the rest\n\nold note".into()),
    }])
    .unwrap();
    assert_eq!(rig.item("legacy").text, "Legacy title.");
    rig.pane(vec![TrackerPaneOp::Edit {
        id: "legacy".into(),
        title: None,
        text: Some(old.text.clone()),
        body: Some(old.note.clone().unwrap_or_default()),
    }])
    .unwrap();
    let back = rig.item("legacy");
    assert_eq!((back.text, back.note), (old.text, old.note));
    // Every other byte of the file is as it was (the item's own timestamp aside).
    assert_eq!(
        without_item(&rig.text(), "legacy"),
        without_item(&original, "legacy")
    );
}

#[test]
fn an_edit_of_a_bound_items_body_keeps_the_source_owned_first_line() {
    let rig = Rig::new();
    rig.agent_a(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        bind: Some("mother.job/JOB-9".into()),
        ..Default::default()
    })])
    .unwrap();
    let desired = Desired {
        state: "running".into(),
        status: Some(Status::InProgress),
        note_line: "Mother job JOB-9 running".into(),
        link: None,
    };
    assert!(rig
        .reg
        .apply_source(&rig.path, "alpha", &desired, rig.clock_now()));
    rig.pane(vec![pane_edit_body("alpha", "my own note")])
        .unwrap();
    let note = rig.item("alpha").note.expect("a note");
    assert_eq!(note, "Mother job JOB-9 running\nmy own note");
    // Clearing the body leaves the source line.
    rig.pane(vec![pane_edit_body("alpha", "")]).unwrap();
    assert_eq!(
        rig.item("alpha").note.as_deref(),
        Some("Mother job JOB-9 running")
    );
}

impl Rig {
    fn clock_now(&self) -> chrono::DateTime<chrono::Utc> {
        use nostromo::tracker::Clock;
        self.clock.now()
    }
}

#[test]
fn the_pane_may_tick_a_command_item_done_and_an_agent_may_not() {
    let rig = Rig::new();
    rig.agent_a(&[Op::Upsert(Upsert {
        id: Some("run-it".into()),
        section: Some("now".into()),
        text: Some("Run the migration".into()),
        command: Some("php artisan migrate".into()),
        ..Default::default()
    })])
    .unwrap();
    let err = rig
        .agent_a(&[status_op("run-it", "done")])
        .expect_err("an agent");
    assert_eq!(err.code(), "not_permitted");
    rig.pane(vec![pane_status("run-it", "done")]).unwrap();
    assert_eq!(rig.item("run-it").status, Status::Done);
    assert_eq!(
        rig.item("run-it").command.as_deref(),
        Some("php artisan migrate")
    );
    // An edit never changes the command.
    rig.pane(vec![TrackerPaneOp::Edit {
        id: "run-it".into(),
        title: Some("Run the migration (renamed)".into()),
        text: None,
        body: None,
    }])
    .unwrap();
    assert_eq!(
        rig.item("run-it").command.as_deref(),
        Some("php artisan migrate")
    );
}

#[test]
fn more_than_fifty_ops_or_none_is_invalid() {
    let rig = Rig::new();
    let many: Vec<TrackerPaneOp> = (0..51).map(|_| pane_status("alpha", "done")).collect();
    assert_eq!(rig.pane(many).expect_err("51").code, "invalid_args");
    assert_eq!(rig.pane(vec![]).expect_err("none").code, "invalid_args");
    let unbound = rig
        .reg
        .apply_pane_ops("no-such-tag", 0, &[pane_status("a", "done")]);
    assert_eq!(unbound.expect_err("unbound").code, "no_tracker");
}

// ---------------------------------------------------------------------------
// The handler: flush, and no agent turn (T3A-8)
// ---------------------------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[allow(clippy::await_holding_lock)] // the held session lock is the point of the test
async fn the_handler_flushes_the_board_and_never_takes_the_session_lock() {
    let rig = Rig::new();
    let session_mgr = Arc::new(Mutex::new(SessionManager::with_store_path(
        rig.base.join("sessions.json"),
    )));
    let (tx, mut rx) = broadcast::channel::<ServerMsg>(64);
    let state = McpSharedState::for_daemon(DaemonMcpBackend {
        pane_registry: Arc::new(Mutex::new(PaneRegistry::in_memory())),
        session_mgr: Arc::clone(&session_mgr),
        broadcast_tx: tx,
        perri: PerriDaemonState::default(),
        decisions: Arc::new(Mutex::new(
            nostromo::ipc::decisions::DecisionRegistry::default(),
        )),
        tickets: Default::default(),
        tracker: Arc::clone(&rig.reg),
        terminals: nostromo::terminal::TerminalAgentApi::in_memory(),
    });
    // The session manager is locked for the whole call: a handler that
    // touched a session would deadlock and time out.
    let held = session_mgr.lock().unwrap();
    let version = rig.version();
    let handler_state = state.clone();
    let task = tokio::spawn(async move {
        tracker_edit(
            &handler_state,
            TAG_A,
            "req-1",
            version,
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::Add {
                    section: "now".into(),
                    title: "Made in the pane".into(),
                    body: None,
                    before: None,
                    after: None,
                },
            ],
        )
        .await
    });
    let reply = tokio::time::timeout(Duration::from_secs(10), task)
        .await
        .expect("the handler never waits for a session")
        .expect("the handler task ran");
    drop(held);
    match reply {
        ServerMsg::TrackerEditResult {
            ok,
            request_id,
            created,
            version,
            error,
            ..
        } => {
            assert!(ok, "{error:?}");
            assert_eq!(request_id, "req-1");
            assert_eq!(created.len(), 1);
            assert_eq!(version, rig.version());
        }
        other => panic!("{other:?}"),
    }
    let mut boards = 0;
    while let Ok(msg) = rx.try_recv() {
        if let ServerMsg::TrackerBoard {
            board: Some(view), ..
        } = msg
        {
            boards += 1;
            assert_eq!(view.version, rig.version());
        }
    }
    // One frame per focus bound to the board (two here).
    assert_eq!(boards, 2, "the board frames are broadcast within the call");
    // A refused edit answers `ok: false` and still changes nothing.
    let refused = tracker_edit(&state, TAG_A, "req-2", 0, vec![pane_status("nope", "done")]).await;
    assert!(matches!(
        refused,
        ServerMsg::TrackerEditResult { ok: false, error: Some(e), .. } if e.code == "unknown_item" && e.index == Some(0)
    ));
}

// ---------------------------------------------------------------------------
// PRD 38: the agent hears about user edits
// ---------------------------------------------------------------------------

#[test]
fn three_pane_edits_and_a_file_save_are_four_user_changes_for_the_agent() {
    let rig = Rig::new();
    rig.tick(60);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.pane(vec![pane_edit_body("beta", "n1")]).unwrap();
    rig.pane(vec![TrackerPaneOp::Remove { id: "gamma".into() }])
        .unwrap();
    rig.tick(60);
    let text = rig.text().replace("Alpha task", "Alpha task!");
    rig.save(&text);
    let out = rig.agent_a(&[status_op("beta", "blocked")]).unwrap();
    assert_eq!(out.user_changes, 4);
}

// ---------------------------------------------------------------------------
// Conflicts (PRD 41, 42)
// ---------------------------------------------------------------------------

#[test]
fn agent_then_pane_within_ten_seconds_keeps_the_agents_value_as_the_loser() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
    rig.tick(3);
    // The pane saw the agent's write (fresh base): only the 10 s rule applies.
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    assert_eq!(rig.item("alpha").status, Status::Done);
    let conflicts = rig.item("alpha").conflicts;
    assert_eq!(conflicts.len(), 1, "{conflicts:?}");
    assert_eq!(conflicts[0].field, "status");
    assert_eq!(conflicts[0].losing, "in-progress");
    assert_eq!(conflicts[0].losing_by, "agent cody-a");
    assert_eq!(conflicts[0].winning_by, PANE);
    assert_eq!(conflicts[0].index, 0);
    let delta = rig.delta(TAG_A, SESS_A);
    let entries = conflict_entries(&delta);
    assert_eq!(entries.len(), 1, "{delta:?}");
    assert_eq!(
        entries[0],
        &json!({"by": PANE, "id": "alpha", "conflict": {
            "field": "status", "kept": "done", "lost": "in-progress", "lost_by": "agent cody-a"}})
    );
}

#[test]
fn pane_then_agent_within_ten_seconds_keeps_the_panes_value_as_the_loser() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(3);
    rig.agent_b(&[status_op("alpha", "blocked")]).unwrap();
    assert_eq!(rig.item("alpha").status, Status::Blocked);
    let c = &rig.item("alpha").conflicts;
    assert_eq!(
        (c[0].losing.as_str(), c[0].losing_by.as_str()),
        ("done", PANE)
    );
    let delta = rig.delta(TAG_B, SESS_B);
    assert_eq!(conflict_entries(&delta).len(), 1, "{delta:?}");
}

#[test]
fn agent_then_a_stale_file_save_within_ten_seconds_keeps_the_agents_value() {
    let rig = Rig::new();
    rig.tick(100);
    let stale = rig.text();
    rig.agent_a(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        owner: Some("claudia".into()),
        ..Default::default()
    })])
    .unwrap();
    rig.tick(4);
    rig.save(&stale);
    assert_eq!(rig.item("alpha").owner, None);
    let c = rig.item("alpha").conflicts;
    assert_eq!(c.len(), 1, "{c:?}");
    assert_eq!(
        (c[0].field.as_str(), c[0].losing.as_str()),
        ("owner", "claudia")
    );
    assert_eq!(c[0].losing_by, "agent cody-a");
    assert_eq!(c[0].winning_by, "file (unknown editor)");
    let delta = rig.delta(TAG_A, SESS_A);
    assert_eq!(conflict_entries(&delta).len(), 1, "{delta:?}");
}

#[test]
fn at_eleven_seconds_with_fresh_bases_there_is_no_conflict() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
    rig.tick(11);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(11);
    rig.reg.read(TAG_B, SESS_B).unwrap();
    rig.agent_b(&[status_op("alpha", "blocked")]).unwrap();
    rig.tick(11);
    // A fresh edit in an editor: a value the field never had.
    rig.save(&rig.text().replace("— blocked", "— needs you"));
    assert!(rig.item("alpha").conflicts.is_empty());
    assert!(conflict_entries(&rig.delta(TAG_A, SESS_A)).is_empty());
}

#[test]
fn at_eleven_seconds_a_stale_pane_base_conflicts() {
    let rig = Rig::new();
    rig.tick(100);
    let stale_base = rig.version();
    rig.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
    rig.tick(11);
    rig.pane_at(stale_base, vec![pane_status("alpha", "done")])
        .unwrap();
    let c = rig.item("alpha").conflicts;
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].losing, "in-progress");
}

#[test]
fn at_eleven_seconds_a_stale_agent_cursor_conflicts() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(11);
    // Agent B never read the pane's tick.
    rig.agent_b(&[status_op("alpha", "in-progress")]).unwrap();
    let c = rig.item("alpha").conflicts;
    assert_eq!(c.len(), 1, "{c:?}");
    assert_eq!(
        (c[0].losing.as_str(), c[0].losing_by.as_str()),
        ("done", PANE)
    );
}

#[test]
fn at_eleven_seconds_a_file_that_reverts_a_value_conflicts() {
    let rig = Rig::new();
    rig.tick(100);
    let stale = rig.text();
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(11);
    rig.save(&stale);
    let c = rig.item("alpha").conflicts;
    assert_eq!(c.len(), 1, "{c:?}");
    assert_eq!(c[0].losing, "done");
    assert_eq!(rig.item("alpha").status, Status::Todo);
}

#[test]
fn a_source_change_followed_by_a_pane_status_is_no_conflict() {
    let rig = Rig::new();
    rig.agent_a(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        bind: Some("mother.job/JOB-9".into()),
        ..Default::default()
    })])
    .unwrap();
    rig.reg.read(TAG_A, SESS_A).unwrap();
    let stale_base = rig.version();
    rig.tick(100);
    let desired = Desired {
        state: "running".into(),
        status: Some(Status::InProgress),
        note_line: "Mother job JOB-9 running".into(),
        link: None,
    };
    rig.reg
        .apply_source(&rig.path, "alpha", &desired, rig.clock_now());
    rig.tick(1);
    rig.pane_at(stale_base, vec![pane_status("alpha", "done")])
        .unwrap();
    assert!(rig.item("alpha").conflicts.is_empty());
}

#[test]
fn removing_an_item_the_pane_just_edited_is_restorable_byte_for_byte() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_edit_body("alpha", "details the pane typed")])
        .unwrap();
    let before_removal = rig.text();
    rig.tick(3);
    rig.agent_b(&[Op::Remove { id: "alpha".into() }]).unwrap();
    assert!(!rig.has_item("alpha"));
    let view = rig.reg.board_view(TAG_A).unwrap();
    assert_eq!(view.removed_conflicts.len(), 1);
    let removed = &view.removed_conflicts[0];
    assert_eq!(removed.item_id, "alpha");
    assert_eq!(removed.title, "Alpha task");
    assert_eq!(removed.losing_by, PANE);
    assert_eq!(removed.winning_by, "agent cody-b");
    let delta = rig.delta(TAG_A, SESS_A);
    assert_eq!(conflict_entries(&delta).len(), 1, "{delta:?}");
    rig.pane(vec![TrackerPaneOp::ResolveConflict {
        id: "alpha".into(),
        field: "removed".into(),
        keep: ConflictKeep::Losing,
        index: None,
    }])
    .unwrap();
    assert_eq!(rig.text(), before_removal);
    assert!(rig
        .reg
        .board_view(TAG_A)
        .unwrap()
        .removed_conflicts
        .is_empty());
}

#[test]
fn resolving_a_field_conflict_keeps_either_side_and_clears_it() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
    rig.tick(2);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    let resolve = |keep| TrackerPaneOp::ResolveConflict {
        id: "alpha".into(),
        field: "status".into(),
        keep,
        index: Some(0),
    };
    rig.pane(vec![resolve(ConflictKeep::Losing)]).unwrap();
    assert_eq!(rig.item("alpha").status, Status::InProgress);
    assert!(
        rig.item("alpha").conflicts.is_empty(),
        "settled, and the settling is no new conflict"
    );
    let err = rig
        .pane(vec![resolve(ConflictKeep::Current)])
        .expect_err("settled");
    assert_eq!(err.code, "invalid_args");
}

#[test]
fn conflicts_are_lost_when_the_daemon_restarts() {
    let mut rig = Rig::new();
    rig.tick(100);
    rig.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    assert_eq!(rig.item("alpha").conflicts.len(), 1);
    rig.restart();
    assert!(rig.item("alpha").conflicts.is_empty());
}

// ---------------------------------------------------------------------------
// PRD 43: sensitive text the user types
// ---------------------------------------------------------------------------

fn full_board(rig: &Rig, tag: &str, session: &str) -> String {
    // A session that never read gets the whole board.
    let _ = (tag, session);
    let other = "fresh-session";
    match rig.reg.read(TAG_A, other).expect("read") {
        ReadOutcome::Full { board, .. } => board,
        ReadOutcome::Delta { .. } => panic!("a fresh session reads the whole board"),
    }
}

#[test]
fn pane_text_with_a_finding_is_written_badged_and_withheld_from_agents() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_edit_body(
        "alpha",
        &format!("resident SSN {SSN}"),
    )])
    .unwrap();
    assert!(rig.text().contains(SSN), "the user's file keeps their text");
    let item = rig.item("alpha");
    assert_eq!(
        item.sensitive.as_ref().unwrap().classes,
        vec!["ssn".to_string()]
    );
    assert!(
        item.note.as_deref().unwrap().contains(SSN),
        "the pane shows the user's own text"
    );

    let delta = rig.delta(TAG_B, SESS_B);
    let shown = serde_json::to_string(&delta).unwrap();
    assert!(!shown.contains(SSN), "{shown}");
    assert!(shown.contains(WITHHELD), "{shown}");
    assert_eq!(
        delta[0]["id"], "alpha",
        "the id and the fact of the change still show"
    );
    let full = full_board(&rig, TAG_A, "x");
    assert!(!full.contains(SSN), "{full}");
    assert!(full.contains(WITHHELD), "{full}");
    assert!(full.contains("alpha"), "{full}");
}

#[test]
fn a_file_save_with_a_finding_is_badged_and_withheld_too() {
    let rig = Rig::new();
    rig.save(
        &rig.text()
            .replace("Beta task", &format!("Beta task for {SSN}")),
    );
    assert!(rig.item("beta").sensitive.is_some());
    let shown = serde_json::to_string(&rig.delta(TAG_B, SESS_B)).unwrap();
    assert!(!shown.contains(SSN), "{shown}");
    assert!(!full_board(&rig, TAG_A, "x").contains(SSN));
}

#[test]
fn a_conflict_entry_never_carries_withheld_text() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    rig.tick(2);
    rig.agent_b(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        note: Some("agent note".into()),
        ..Default::default()
    })])
    .unwrap();
    let shown = serde_json::to_string(&rig.delta(TAG_A, SESS_A)).unwrap();
    assert!(shown.contains("conflict"), "{shown}");
    assert!(!shown.contains(SSN), "{shown}");
    assert!(shown.contains(WITHHELD), "{shown}");
}

#[test]
fn clearing_the_badge_shows_the_current_value_but_never_an_old_one() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    rig.pane(vec![pane_edit_body("alpha", "SSN removed")])
        .unwrap();
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN} again"))])
        .unwrap();
    rig.pane(vec![TrackerPaneOp::ClearBadge { id: "alpha".into() }])
        .unwrap();
    assert!(rig.item("alpha").sensitive.is_none());
    let full = full_board(&rig, TAG_A, "x");
    assert!(
        full.contains(&format!("SSN {SSN} again")),
        "the current value shows: {full}"
    );
    // The old value (the first one) stays withheld in the log.
    let shown = serde_json::to_string(&rig.delta(TAG_B, SESS_B)).unwrap();
    assert!(!shown.contains(&format!("SSN {SSN}\"")), "{shown}");
    assert!(shown.contains(WITHHELD), "{shown}");
}

#[test]
fn the_badge_survives_a_restart_and_clearing_survives_it_too() {
    let mut rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    rig.pane(vec![pane_edit_body(
        "beta",
        &format!("SSN {SSN} (cleared)"),
    )])
    .unwrap();
    rig.pane(vec![TrackerPaneOp::ClearBadge { id: "beta".into() }])
        .unwrap();
    rig.restart();
    assert!(rig.item("alpha").sensitive.is_some());
    assert!(rig.item("beta").sensitive.is_none());
    assert!(!full_board(&rig, TAG_A, "x").contains("SSN 219-09-9999\n"));
}

#[test]
fn a_badge_survives_a_board_edited_while_the_daemon_was_down() {
    let mut rig = Rig::new();
    let text = rig.text().replace("Gamma task", &format!("Gamma {SSN}"));
    // Edited with no daemon running: nothing ingested it.
    std::fs::write(&rig.path, text).unwrap();
    rig.restart();
    assert!(rig.item("gamma").sensitive.is_some());
    assert!(!full_board(&rig, TAG_A, "x").contains(SSN));
}

#[test]
fn clearing_a_badge_is_refused_when_the_item_changed_after_what_the_user_saw() {
    let rig = Rig::new();
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    let seen = rig.version();
    rig.tick(100);
    rig.agent_b(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        owner: Some("someone".into()),
        ..Default::default()
    })])
    .unwrap();
    let err = rig
        .pane_at(seen, vec![TrackerPaneOp::ClearBadge { id: "alpha".into() }])
        .expect_err("changed since seen");
    assert_eq!(err.code, "invalid_args");
    assert!(
        rig.item("alpha").sensitive.is_some(),
        "nothing was approved"
    );
    rig.pane(vec![TrackerPaneOp::ClearBadge { id: "alpha".into() }])
        .unwrap();
    assert!(rig.item("alpha").sensitive.is_none());
}

#[test]
fn editing_an_item_after_clearing_badges_a_new_finding() {
    let rig = Rig::new();
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    rig.pane(vec![TrackerPaneOp::ClearBadge { id: "alpha".into() }])
        .unwrap();
    assert!(rig.item("alpha").sensitive.is_none());
    rig.pane(vec![pane_edit_body("alpha", "SSN 412-67-8901")])
        .unwrap();
    assert!(rig.item("alpha").sensitive.is_some());
}

#[test]
fn an_added_item_with_a_finding_in_its_title_gets_a_neutral_id() {
    let rig = Rig::new();
    let out = rig
        .pane(vec![TrackerPaneOp::Add {
            section: "now".into(),
            title: format!("Call about {SSN}"),
            body: None,
            before: None,
            after: None,
        }])
        .unwrap();
    assert!(!out.created[0].contains("219"), "{}", out.created[0]);
    assert!(rig.item(&out.created[0]).sensitive.is_some());
}

// ---------------------------------------------------------------------------
// Lost-edit regressions (Perri's probes P1-P6, T3a review)
// ---------------------------------------------------------------------------

/// P1: re-opening the board reads nothing, so it must not mark the changes
/// made before it as seen.
#[test]
fn an_agent_reopening_the_board_has_not_seen_the_users_edit() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(60);
    rig.reopen_b();
    rig.tick(60);
    rig.agent_b(&[status_op("alpha", "in-progress")]).unwrap();
    assert_eq!(
        rig.losers("alpha", "status"),
        vec!["done"],
        "the user's `done` is kept: B never read it"
    );
}

/// P1, the other half: the first open does hand over the board, so it counts
/// as a read.
#[test]
fn the_first_open_of_a_board_counts_as_a_read() {
    let rig = Rig::new();
    let args = OpenArgs {
        topic: Some("two-way".into()),
        cwd: rig.base.join("repo"),
        ..Default::default()
    };
    rig.tick(100);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    rig.tick(60);
    let opened = rig.reg.open("cody-c", "sess-c", &args).unwrap();
    assert!(opened.board.is_some());
    rig.tick(60);
    rig.reg
        .apply(
            "cody-c",
            "sess-c",
            &[status_op("alpha", "in-progress")],
            &agent("cody-c", "sess-c"),
        )
        .unwrap();
    assert!(rig.losers("alpha", "status").is_empty());
}

/// P2: settling one conflict settles that one.
#[test]
fn resolving_one_conflict_leaves_the_one_the_user_never_saw() {
    for pick in [None, Some(0)] {
        let rig = Rig::new();
        let seen = rig.first_status_conflict();
        // A second conflict, after what the pane showed: A (having read) sets
        // `blocked`, B overwrites it two seconds later.
        rig.tick(100);
        rig.reg.read(TAG_A, SESS_A).unwrap();
        rig.agent_a(&[status_op("alpha", "blocked")]).unwrap();
        rig.tick(2);
        rig.agent_b(&[status_op("alpha", "needs-you")]).unwrap();
        assert_eq!(rig.losers("alpha", "status").len(), 2);
        rig.pane_at(
            seen,
            vec![TrackerPaneOp::ResolveConflict {
                id: "alpha".into(),
                field: "status".into(),
                keep: ConflictKeep::Current,
                index: pick,
            }],
        )
        .unwrap();
        assert_eq!(
            rig.losers("alpha", "status"),
            vec!["blocked"],
            "pick {pick:?}: only the settled conflict went"
        );
    }
}

/// P2, keeping the losing value: the other losing values stay too.
#[test]
fn keeping_a_losing_value_settles_only_that_conflict() {
    let rig = Rig::new();
    rig.first_status_conflict();
    rig.tick(100);
    // A second status conflict the pane has also seen.
    rig.reg.read(TAG_A, SESS_A).unwrap();
    rig.agent_a(&[status_op("alpha", "blocked")]).unwrap();
    rig.tick(2);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    assert_eq!(
        rig.losers("alpha", "status"),
        vec!["in-progress", "blocked"]
    );
    rig.pane(vec![TrackerPaneOp::ResolveConflict {
        id: "alpha".into(),
        field: "status".into(),
        keep: ConflictKeep::Losing,
        index: Some(0),
    }])
    .unwrap();
    assert_eq!(rig.item("alpha").status, Status::InProgress);
    assert_eq!(rig.losers("alpha", "status"), vec!["blocked"]);
}

/// P3: putting a losing value back from a stale view is still a write over
/// whatever came after that view.
#[test]
fn keep_losing_from_a_stale_view_conflicts_with_a_newer_value() {
    let rig = Rig::new();
    let seen = rig.first_status_conflict();
    rig.tick(100);
    rig.reg.read(TAG_B, SESS_B).unwrap();
    rig.agent_b(&[status_op("alpha", "needs-you")]).unwrap();
    assert_eq!(rig.losers("alpha", "status"), vec!["in-progress"]);
    rig.pane_at(
        seen,
        vec![TrackerPaneOp::ResolveConflict {
            id: "alpha".into(),
            field: "status".into(),
            keep: ConflictKeep::Losing,
            index: Some(0),
        }],
    )
    .unwrap();
    assert!(
        rig.losers("alpha", "status")
            .contains(&"needs-you".to_string()),
        "B's newer value is kept: {:?}",
        rig.losers("alpha", "status")
    );
}

/// P3, mixed batch: the other ops of a batch that settles a conflict are
/// checked like any pane edit.
#[test]
fn a_batch_that_settles_a_conflict_still_detects_conflicts_for_its_other_ops() {
    let rig = Rig::new();
    let seen = rig.first_status_conflict();
    rig.tick(100);
    rig.reg.read(TAG_B, SESS_B).unwrap();
    rig.agent_b(&[status_op("beta", "in-progress")]).unwrap();
    rig.pane_at(
        seen,
        vec![
            TrackerPaneOp::ResolveConflict {
                id: "alpha".into(),
                field: "status".into(),
                keep: ConflictKeep::Losing,
                index: Some(0),
            },
            pane_status("beta", "done"),
        ],
    )
    .unwrap();
    assert_eq!(rig.item("beta").status, Status::Done);
    assert_eq!(rig.losers("beta", "status"), vec!["in-progress"]);
    assert!(
        rig.losers("alpha", "status").is_empty(),
        "the settled field is no new conflict"
    );
}

/// P6: a refused batch writes nothing.
#[test]
fn a_refused_clear_badge_writes_nothing_of_its_batch() {
    let rig = Rig::new();
    let seen = rig.version();
    rig.tick(100);
    rig.agent_b(&[Op::Upsert(Upsert {
        id: Some("alpha".into()),
        owner: Some("someone".into()),
        ..Default::default()
    })])
    .unwrap();
    let (text, version) = (rig.text(), rig.version());
    let err = rig
        .pane_at(
            seen,
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::ClearBadge { id: "alpha".into() },
            ],
        )
        .expect_err("alpha changed since the base");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(err.index, Some(1));
    assert_eq!(rig.text(), text, "the file is byte-identical");
    assert_eq!(rig.version(), version, "and the version did not move");
}

/// P6 as a property: whatever refuses a batch, the file stays as it was.
#[test]
fn any_refused_batch_leaves_the_file_byte_identical() {
    let seen_then_changed = |rig: &Rig| {
        let seen = rig.version();
        rig.tick(100);
        rig.agent_b(&[status_op("beta", "blocked")]).unwrap();
        seen
    };
    let batches: Vec<(&str, Vec<TrackerPaneOp>)> = vec![
        (
            "unknown item after a good op",
            vec![pane_status("alpha", "done"), pane_status("nope", "done")],
        ),
        (
            "bad status after a good op",
            vec![
                pane_status("alpha", "done"),
                pane_status("beta", "sideways"),
            ],
        ),
        (
            "clear_badge of an unknown item",
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::ClearBadge { id: "nope".into() },
            ],
        ),
        (
            "clear_badge of an item changed since the base",
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::ClearBadge { id: "beta".into() },
            ],
        ),
        (
            "a conflict that isn't there",
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::ResolveConflict {
                    id: "alpha".into(),
                    field: "status".into(),
                    keep: ConflictKeep::Current,
                    index: None,
                },
            ],
        ),
        (
            "a restore that isn't one item",
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::Restore {
                    source: "not an item".into(),
                    section: "now".into(),
                    before: None,
                    after: None,
                },
            ],
        ),
        (
            "an empty edit",
            vec![
                pane_status("alpha", "done"),
                TrackerPaneOp::Edit {
                    id: "beta".into(),
                    title: None,
                    text: None,
                    body: None,
                },
            ],
        ),
    ];
    for (why, ops) in batches {
        let rig = Rig::new();
        let seen = seen_then_changed(&rig);
        let (text, version) = (rig.text(), rig.version());
        let result = rig.pane_at(seen, ops);
        assert!(result.is_err(), "{why}: expected a refusal");
        assert_eq!(rig.text(), text, "{why}: the file changed");
        assert_eq!(rig.version(), version, "{why}: the version moved");
    }
}

/// Another pane window's change after the base blocks a clear_badge too.
#[test]
fn clear_badge_is_refused_after_another_pane_window_changed_the_item() {
    let rig = Rig::new();
    rig.pane(vec![pane_edit_body("alpha", &format!("SSN {SSN}"))])
        .unwrap();
    let seen = rig.version();
    // A second window (same author kind) edits the item after our base.
    rig.tick(100);
    rig.pane(vec![pane_edit_body(
        "alpha",
        &format!("SSN {SSN} and more"),
    )])
    .unwrap();
    let err = rig
        .pane_at(seen, vec![TrackerPaneOp::ClearBadge { id: "alpha".into() }])
        .expect_err("changed since seen");
    assert_eq!(err.code, "invalid_args");
    assert!(rig.item("alpha").sensitive.is_some());
}

/// P4: a secret straddling the 200-character cut of the change log.
#[test]
fn a_secret_straddling_the_log_cut_is_withheld() {
    let rig = Rig::new();
    rig.tick(100);
    let key = "AKIAIOSFODNN7EXAMPLE";
    rig.pane(vec![pane_edit_body(
        "alpha",
        &format!("{}{key}", "x".repeat(193)),
    )])
    .unwrap();
    let shown = serde_json::to_string(&rig.delta(TAG_B, SESS_B)).unwrap();
    assert!(!shown.contains("AKIA"), "{shown}");
    assert!(shown.contains(WITHHELD), "{shown}");
}

/// P5: an id generated for an item a file save adds.
#[test]
fn a_file_added_item_with_a_finding_gets_a_neutral_id() {
    let rig = Rig::new();
    rig.save(&rig.text().replace(
        "- [ ] Beta task",
        "- [ ] 4111111111111111 card on file\n- [ ] Beta task",
    ));
    let shown = serde_json::to_string(&rig.delta(TAG_B, SESS_B)).unwrap();
    assert!(!shown.contains("4111"), "{shown}");
    let board = rig.reg.board_view(TAG_A).unwrap();
    let ids: Vec<String> = board
        .nodes
        .iter()
        .filter_map(|n| match n {
            ViewNode::Item(i) => Some(i.id.clone()),
            _ => None,
        })
        .collect();
    assert!(ids.iter().all(|id| !id.contains("4111")), "{ids:?}");
    assert!(ids.iter().any(|id| id.starts_with("item-")), "{ids:?}");
}

/// T3b's Undo: text that came from the file can be longer than an edit takes.
#[test]
fn undoing_a_restructure_restores_a_text_over_five_hundred_characters() {
    let rig = Rig::new();
    let original = format!("Legacy title. {}", "and a long file line ".repeat(48));
    assert!(original.chars().count() > 900);
    rig.save(&rig.text().replace(
        "- [ ] Beta task",
        &format!("- [ ] {}\n- [ ] Beta task", original.trim()),
    ));
    let long_id = rig
        .reg
        .board_view(TAG_A)
        .unwrap()
        .nodes
        .iter()
        .find_map(|n| match n {
            ViewNode::Item(i) if i.text.starts_with("Legacy title.") => Some(i.id.clone()),
            _ => None,
        })
        .expect("the long item");
    let before = rig.item(&long_id).text;
    rig.pane(vec![TrackerPaneOp::Edit {
        id: long_id.clone(),
        title: Some("Legacy title.".into()),
        text: None,
        body: Some("the rest".into()),
    }])
    .unwrap();
    // The capped edit can't undo it...
    assert!(rig
        .pane(vec![TrackerPaneOp::Edit {
            id: long_id.clone(),
            title: None,
            text: Some(before.clone()),
            body: None,
        }])
        .is_err());
    // ...the restore can, whole.
    rig.pane(vec![TrackerPaneOp::RestoreText {
        id: long_id.clone(),
        text: before.clone(),
    }])
    .unwrap();
    assert_eq!(rig.item(&long_id).text, before);
}
