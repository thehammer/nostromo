//! The two-way tracker, daemon side: regressions found after T3a (follow-up).
//!
//! Each test names a way the user's or an agent's text could be lost, or a
//! user's decision applied to the wrong thing, and pins the behaviour that
//! prevents it:
//!
//! - a conflict id from before the daemon lost its state never settles a new
//!   conflict (ids carry a per-board epoch);
//! - a reading position beyond the log (a rolled-back state) is not trusted;
//! - history-gap guesses never push a real losing value off the board;
//! - one batch cannot settle the same conflict twice, or put two losing values
//!   of one field back;
//! - an item whose only conflict a cap dropped says so to the pane and to the
//!   agent, and the pane can acknowledge it (`ack_dropped`);
//! - settling the oldest conflict of a full field while overflowing it is not
//!   a loss.
//!
//! Hermetic, like `tracker_two_way.rs`: a `FakeClock`, temp dirs, no git, no
//! real `~/.nostromo`. A "restart" is dropping one registry and building
//! another over the same state root.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;

use chrono::Duration as ChronoDuration;
use nostromo::ipc::protocol::{ConflictKeep, TrackerPaneOp};
use nostromo::tracker::view::{ViewItem, ViewNode};
use nostromo::tracker::{
    Author, FakeClock, Op, OpenArgs, PaneEditError, ReadOutcome, RegistryParts, Status,
    TrackerError, TrackerRegistry, Upsert,
};
use serde_json::{json, Value};
use tempfile::TempDir;

const TAG_A: &str = "cody-a";
const TAG_B: &str = "cody-b";
const SESS_A: &str = "sess-a";
const SESS_B: &str = "sess-b";
const PANE: &str = "pane (you)";

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

fn note_op(id: &str, note: &str) -> Op {
    Op::Upsert(Upsert {
        id: Some(id.into()),
        note: Some(note.into()),
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

fn resolve_op(id: &str, field: &str, keep: ConflictKeep, conflict_id: &str) -> TrackerPaneOp {
    TrackerPaneOp::ResolveConflict {
        id: id.into(),
        field: field.into(),
        keep,
        conflict_id: Some(conflict_id.into()),
        index: None,
    }
}

fn ack_op(id: &str) -> TrackerPaneOp {
    TrackerPaneOp::AckDropped { id: id.into() }
}

fn reason_of(err: &PaneEditError) -> String {
    err.reason.clone().unwrap_or_default().to_lowercase()
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
            cwd: repo,
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

    fn open_args(&self) -> OpenArgs {
        OpenArgs {
            topic: Some("two-way".into()),
            cwd: self.base.join("repo"),
            ..Default::default()
        }
    }

    fn state_file(&self) -> PathBuf {
        self.state_root.join("trackers").join("state.json")
    }

    /// A new registry over this rig's state root: the daemon restarting.
    fn restart(&mut self) {
        self.reg = Arc::new(TrackerRegistry::new(RegistryParts::hermetic(
            self.state_root.clone(),
            self.home.clone(),
            self.clock.clone(),
        )));
    }

    /// The daemon restarting with its state file gone (a wiped state dir, a
    /// restored backup): the board file is still there, but versions, counters
    /// and conflicts start over. Both agents open the board again.
    fn restart_losing_state(&mut self) {
        std::fs::remove_file(self.state_file()).expect("state.json exists");
        self.restart();
        let args = self.open_args();
        self.reg.open(TAG_A, SESS_A, &args).expect("re-open a");
        self.reg.open(TAG_B, SESS_B, &args).expect("re-open b");
    }

    /// The persisted state rolled back: the log keeps only what was written
    /// through `keep` (its version goes back to `keep`); cursors, bindings and
    /// the board file stay as they are. Takes effect at the next `restart`.
    fn roll_log_back_to(&self, keep: u64) {
        let file = self.state_file();
        let mut state: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        for board in state["boards"].as_object_mut().unwrap().values_mut() {
            let log = &mut board["log"];
            if let Some(entries) = log["entries"].as_array_mut() {
                entries.retain(|e| e["seq"].as_u64().is_some_and(|seq| seq <= keep));
            }
            log["seq"] = json!(keep);
        }
        std::fs::write(&file, serde_json::to_vec(&state).unwrap()).unwrap();
    }

    fn version(&self) -> u64 {
        self.reg.board_view(TAG_A).expect("a board").version
    }

    fn pane(
        &self,
        ops: Vec<TrackerPaneOp>,
    ) -> Result<nostromo::tracker::PaneEditOutcome, PaneEditError> {
        self.reg.apply_pane_ops(TAG_A, self.version(), &ops)
    }

    fn pane_at(
        &self,
        base: u64,
        ops: Vec<TrackerPaneOp>,
    ) -> Result<nostromo::tracker::PaneEditOutcome, PaneEditError> {
        self.reg.apply_pane_ops(TAG_A, base, &ops)
    }

    /// An edit from a view of board run `epoch` at version `base`.
    fn pane_in(
        &self,
        base: u64,
        epoch: &str,
        ops: Vec<TrackerPaneOp>,
    ) -> Result<nostromo::tracker::PaneEditOutcome, PaneEditError> {
        self.reg
            .apply_pane_ops_in(TAG_A, "pane", base, Some(epoch), &ops)
    }

    fn epoch(&self) -> String {
        self.reg.board_view(TAG_A).expect("a board").epoch
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

    fn delta(&self, tag: &str, session: &str) -> Vec<Value> {
        match self.reg.read(tag, session).expect("read") {
            ReadOutcome::Delta { changes, .. } => changes,
            ReadOutcome::Full { .. } => panic!("expected a delta"),
        }
    }

    /// The stable id the pane's view shows for `id`'s conflict on `field`
    /// whose losing value is `losing`.
    fn conflict_id(&self, id: &str, field: &str, losing: &str) -> String {
        self.item(id)
            .conflicts
            .into_iter()
            .find(|c| c.field == field && c.losing == losing)
            .unwrap_or_else(|| panic!("no conflict on {id}.{field} losing {losing:?}"))
            .conflict_id
    }

    /// The ids of `id`'s conflicts in the view, oldest first.
    fn conflict_ids(&self, id: &str) -> Vec<String> {
        self.item(id)
            .conflicts
            .into_iter()
            .map(|c| c.conflict_id)
            .collect()
    }

    /// The losing values of `id`'s conflicts on `field`.
    fn losers(&self, id: &str, field: &str) -> Vec<String> {
        self.item(id)
            .conflicts
            .into_iter()
            .filter(|c| c.field == field)
            .map(|c| c.losing)
            .collect()
    }

    /// A status conflict on `alpha`: agent A's `in-progress` lost to the
    /// pane's `done` two seconds later. Returns the version the pane saw (that
    /// of the conflict's own log entry).
    fn first_status_conflict(&self) -> u64 {
        self.tick(100);
        self.agent_a(&[status_op("alpha", "in-progress")]).unwrap();
        self.tick(2);
        self.pane(vec![pane_status("alpha", "done")]).unwrap();
        assert_eq!(self.losers("alpha", "status"), vec!["in-progress"]);
        self.version()
    }

    /// What a refused edit must leave alone.
    fn snapshot(&self) -> (String, u64) {
        (self.text(), self.version())
    }
}

/// Conflicts on `alpha`'s note losing `a<from>` .. `a<to>`: each round agent B
/// (having read everything) writes `a<k>` and the pane, two seconds later and
/// with a fresh view, overwrites it with `p<k>`.
fn lose_notes(rig: &Rig, from: usize, to: usize) {
    for k in from..=to {
        rig.tick(30);
        rig.reg.read(TAG_B, SESS_B).unwrap();
        rig.agent_b(&[note_op("alpha", &format!("a{k}"))]).unwrap();
        rig.tick(2);
        rig.pane(vec![pane_edit_body("alpha", &format!("p{k}"))])
            .unwrap();
    }
}

/// `n` more items (`bulk-0` ..), read by both agents.
fn add_bulk(rig: &Rig, n: usize) {
    let ops: Vec<Op> = (0..n)
        .map(|i| upsert(&format!("bulk-{i}"), "now", &format!("Bulk task {i}")))
        .collect();
    rig.agent_a(&ops).unwrap();
    rig.reg.read(TAG_A, SESS_A).unwrap();
    rig.reg.read(TAG_B, SESS_B).unwrap();
}

/// A thousand and five other changes push the log past what a writer last saw.
fn churn(rig: &Rig) {
    for k in 0..1_005 {
        let status = if k % 2 == 0 { "in-progress" } else { "blocked" };
        rig.agent_a(&[status_op("beta", status)]).unwrap();
    }
}

/// A pane whose view is `stale_base` (older than the log reaches) ticks the
/// status of `bulk-<i>` for each `i`, in batches: every one is an overwrite of
/// a value whose history fell off the log, so each is kept as a guess.
fn flood_with_guesses(rig: &Rig, stale_base: u64, range: std::ops::Range<usize>) {
    let all: Vec<usize> = range.collect();
    for chunk in all.chunks(25) {
        let ops: Vec<TrackerPaneOp> = chunk
            .iter()
            .map(|i| pane_status(&format!("bulk-{i}"), "done"))
            .collect();
        rig.pane_at(stale_base, ops).unwrap();
    }
}

/// `alpha` has one conflict (its status), the oldest of the board; fifty more
/// conflicts on other items arrive after it and the board's cap of fifty drops
/// alpha's. Nothing of alpha's is left but the count.
fn drop_alphas_only_conflict_with_the_board_cap(rig: &Rig) {
    add_bulk(rig, 50);
    rig.first_status_conflict();
    for i in 0..50 {
        rig.tick(100);
        let id = format!("bulk-{i}");
        rig.agent_b(&[status_op(&id, "in-progress")]).unwrap();
        rig.tick(2);
        rig.pane(vec![pane_status(&id, "done")]).unwrap();
    }
}

/// The `dropped_conflicts` counts an agent's delta reports for item `id`.
fn dropped_notices_for(delta: &[Value], id: &str) -> Vec<u64> {
    delta
        .iter()
        .filter(|e| e["id"] == id)
        .filter_map(|e| e["conflict"]["dropped_conflicts"].as_u64())
        .collect()
}

/// The delta's conflict entries that carry a value (not a bare notice).
fn value_conflict_entries(delta: &[Value]) -> Vec<&Value> {
    delta
        .iter()
        .filter(|e| e["conflict"].get("field").is_some())
        .collect()
}

fn serialized_has_dropped_marker(item: &ViewItem) -> bool {
    serde_json::to_value(item)
        .unwrap()
        .get("dropped_conflicts")
        .is_some()
}

// ---------------------------------------------------------------------------
// R12a: a conflict id from before the state was lost settles nothing now
// ---------------------------------------------------------------------------

/// The daemon lost its state file: versions and the conflict counter start
/// over, so a new conflict can come out with the number an old one had. The id
/// the user's old view holds must not settle it.
#[test]
fn a_conflict_id_from_before_the_state_was_lost_never_settles_a_new_conflict() {
    for keep in [ConflictKeep::Losing, ConflictKeep::Current] {
        let mut rig = Rig::new();
        let old_version = rig.first_status_conflict();
        let old_id = rig.conflict_id("alpha", "status", "in-progress");

        rig.restart_losing_state();
        // The same history shape as before, so that a numbering scheme that
        // only counts (version, n) would hand out the very same number.
        let mut n = 0;
        while rig.version() + 3 < old_version {
            rig.agent_a(&[upsert(&format!("filler-{n}"), "now", "Filler")])
                .unwrap();
            n += 1;
        }
        assert_eq!(rig.version() + 3, old_version, "the histories line up");
        rig.tick(100);
        rig.agent_a(&[status_op("alpha", "blocked")]).unwrap();
        rig.tick(2);
        rig.pane(vec![pane_status("alpha", "todo")]).unwrap();
        assert_eq!(rig.losers("alpha", "status"), vec!["blocked"]);
        let new_id = rig.conflict_id("alpha", "status", "blocked");
        assert_ne!(
            old_id, new_id,
            "{keep:?}: ids do not repeat across a state loss"
        );

        // The id the old view holds, and the plain `<version>.<n>` it would
        // have been numbered before epochs.
        for stale in [old_id.clone(), format!("{old_version}.0")] {
            let before = rig.snapshot();
            let err = rig
                .pane(vec![resolve_op("alpha", "status", keep, &stale)])
                .expect_err("an id from before the state was lost");
            assert_eq!(err.code, "invalid_args", "{keep:?} {stale}");
            assert_eq!(err.index, Some(0));
            assert!(
                reason_of(&err).contains("no longer kept"),
                "{:?}",
                err.reason
            );
            assert_eq!(rig.snapshot(), before, "{keep:?} {stale}: nothing written");
            assert_eq!(rig.losers("alpha", "status"), vec!["blocked"]);
            assert_eq!(rig.conflict_id("alpha", "status", "blocked"), new_id);
            assert_eq!(rig.item("alpha").status, Status::Todo);
        }

        // The new conflict's own id still settles it.
        rig.pane(vec![resolve_op("alpha", "status", keep, &new_id)])
            .unwrap();
        assert!(rig.item("alpha").conflicts.is_empty());
    }
}

/// An id in the old `<version>.<n>` form (a stale client, a log line) names
/// nothing, even when a conflict has that very version and number.
#[test]
fn an_old_format_conflict_id_is_refused_and_touches_nothing() {
    for keep in [ConflictKeep::Losing, ConflictKeep::Current] {
        let rig = Rig::new();
        let version = rig.first_status_conflict();
        let real = rig.conflict_id("alpha", "status", "in-progress");
        let before = rig.snapshot();
        for old_format in [format!("{version}.0"), "6.0".to_string()] {
            assert_ne!(real, old_format, "ids are not the bare version and counter");
            let err = rig
                .pane(vec![resolve_op("alpha", "status", keep, &old_format)])
                .expect_err("an old-format id");
            assert_eq!(err.code, "invalid_args", "{keep:?} {old_format}");
            assert_eq!(err.index, Some(0));
            assert_eq!(rig.snapshot(), before, "{keep:?} {old_format}");
            assert_eq!(rig.conflict_ids("alpha"), vec![real.clone()]);
        }
    }
}

/// Two boards with the same history do not number their conflicts alike: the
/// epoch is per board and not guessable from the history.
#[test]
fn two_fresh_registries_with_the_same_history_give_their_conflicts_different_ids() {
    let (a, b) = (Rig::new(), Rig::new());
    a.first_status_conflict();
    b.first_status_conflict();
    assert_ne!(
        a.conflict_id("alpha", "status", "in-progress"),
        b.conflict_id("alpha", "status", "in-progress")
    );
}

// ---------------------------------------------------------------------------
// R11: a reading position beyond the log is not trusted
// ---------------------------------------------------------------------------

/// A pane whose `base_version` is ahead of everything the log holds (the state
/// was rolled back under it) has not seen what the log shows: the agent's value
/// it overwrites is kept.
#[test]
fn a_pane_base_version_beyond_the_log_still_keeps_what_it_overwrites() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_b(&[status_op("alpha", "in-progress")]).unwrap();
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();
    rig.tick(100);
    let beyond = rig.version() + 50;
    rig.pane_at(
        beyond,
        vec![
            pane_status("alpha", "done"),
            pane_edit_body("alpha", "the user's note"),
        ],
    )
    .unwrap();
    assert_eq!(rig.item("alpha").status, Status::Done);
    assert_eq!(rig.item("alpha").note.as_deref(), Some("the user's note"));
    assert_eq!(rig.losers("alpha", "status"), vec!["in-progress"]);
    assert_eq!(rig.losers("alpha", "note"), vec!["the agent's note"]);
    let c = &rig.item("alpha").conflicts[0];
    assert_eq!(
        (c.losing_by.as_str(), c.winning_by.as_str()),
        ("agent cody-b", PANE)
    );
}

/// An agent's read cursor ahead of the log (the persisted state was rolled
/// back, the cursor was not) says nothing about what the agent has seen: the
/// user's value it overwrites is kept.
#[test]
fn an_agent_cursor_beyond_a_rolled_back_log_still_keeps_what_it_overwrites() {
    let mut rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![pane_status("alpha", "done")]).unwrap();
    let kept_through = rig.version();
    rig.tick(100);
    rig.agent_a(&[status_op("beta", "in-progress")]).unwrap();
    // Agent B reads through the newer version, then the log goes back.
    rig.reg.read(TAG_B, SESS_B).unwrap();
    rig.roll_log_back_to(kept_through);
    rig.restart();
    assert_eq!(rig.version(), kept_through, "the log really went back");

    rig.tick(100);
    rig.agent_b(&[status_op("alpha", "in-progress")]).unwrap();
    assert_eq!(rig.item("alpha").status, Status::InProgress);
    assert_eq!(rig.losers("alpha", "status"), vec!["done"]);
    assert_eq!(rig.item("alpha").conflicts[0].losing_by, PANE);
}

// ---------------------------------------------------------------------------
// R6: guesses are what the board's cap drops, never a real losing value
// ---------------------------------------------------------------------------

/// A stale pane view (older than the log reaches) changing sixty items makes
/// sixty guesses; the one real conflict, older than all of them, stays.
#[test]
fn a_real_conflict_survives_a_flood_of_history_gap_guesses() {
    let rig = Rig::new();
    add_bulk(&rig, 60);
    let stale_base = rig.version();
    rig.first_status_conflict();
    let real_id = rig.conflict_id("alpha", "status", "in-progress");
    churn(&rig);
    rig.tick(100);

    flood_with_guesses(&rig, stale_base, 0..60);

    let all = rig.reg.conflicts(TAG_A);
    assert_eq!(all.len(), 50, "the board holds fifty");
    assert_eq!(
        all.iter()
            .filter(|c| c.item_id.starts_with("bulk-"))
            .count(),
        49,
        "the guesses were recorded (and the cap took the surplus of them)"
    );
    assert!(
        all.iter()
            .any(|c| c.item_id == "alpha" && c.field == "status" && c.id == real_id),
        "the real conflict is still on the board"
    );
    let alpha = rig.item("alpha");
    assert_eq!(alpha.conflicts.len(), 1);
    assert_eq!(alpha.conflicts[0].conflict_id, real_id);
    assert_eq!(alpha.conflicts[0].losing, "in-progress");
    assert_eq!(alpha.dropped_conflicts, 0, "nothing real was dropped");
    assert!(!serialized_has_dropped_marker(&alpha));

    // And the user can still settle it from the view they have.
    rig.pane(vec![resolve_op(
        "alpha",
        "status",
        ConflictKeep::Losing,
        &real_id,
    )])
    .unwrap();
    assert_eq!(rig.item("alpha").status, Status::InProgress);
}

/// Control: at the cap with guesses only, the oldest guess is the one dropped.
#[test]
fn at_the_board_cap_with_only_guesses_the_oldest_guess_is_dropped() {
    let rig = Rig::new();
    add_bulk(&rig, 60);
    let stale_base = rig.version();
    churn(&rig);
    rig.tick(100);

    flood_with_guesses(&rig, stale_base, 0..55);

    let all = rig.reg.conflicts(TAG_A);
    assert_eq!(all.len(), 50);
    let items: BTreeSet<String> = all.iter().map(|c| c.item_id.clone()).collect();
    let expected: BTreeSet<String> = (5..55).map(|i| format!("bulk-{i}")).collect();
    assert_eq!(items, expected, "the five oldest guesses went");
}

// ---------------------------------------------------------------------------
// R3, R4: one batch cannot settle a conflict twice, or write two values of one field
// ---------------------------------------------------------------------------

#[test]
fn a_batch_settling_the_same_conflict_twice_is_refused_as_a_whole() {
    for (first, second) in [
        (ConflictKeep::Current, ConflictKeep::Current),
        (ConflictKeep::Losing, ConflictKeep::Losing),
        (ConflictKeep::Current, ConflictKeep::Losing),
        (ConflictKeep::Losing, ConflictKeep::Current),
    ] {
        let rig = Rig::new();
        lose_notes(&rig, 1, 2);
        let a1 = rig.conflict_id("alpha", "note", "a1");
        let (before, ids) = (rig.snapshot(), rig.conflict_ids("alpha"));

        let err = rig
            .pane(vec![
                resolve_op("alpha", "note", first, &a1),
                resolve_op("alpha", "note", second, &a1),
            ])
            .expect_err("the same conflict twice");
        assert_eq!(err.code, "invalid_args", "{first:?} {second:?}");
        assert_eq!(err.index, Some(1), "the second op is the one refused");
        let reason = reason_of(&err);
        assert!(
            ["twice", "duplicate", "more than once"]
                .iter()
                .any(|w| reason.contains(w)),
            "{reason}"
        );
        assert_eq!(
            rig.snapshot(),
            before,
            "{first:?} {second:?}: nothing written"
        );
        assert_eq!(
            rig.conflict_ids("alpha"),
            ids,
            "both conflicts are still kept"
        );
        assert_eq!(rig.item("alpha").note.as_deref(), Some("p2"));
    }
}

#[test]
fn a_batch_keeping_two_losing_values_of_one_field_is_refused_and_writes_nothing() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 2);
    let a1 = rig.conflict_id("alpha", "note", "a1");
    let a2 = rig.conflict_id("alpha", "note", "a2");
    let (before, ids) = (rig.snapshot(), rig.conflict_ids("alpha"));

    for ops in [
        vec![
            resolve_op("alpha", "note", ConflictKeep::Losing, &a1),
            resolve_op("alpha", "note", ConflictKeep::Losing, &a2),
        ],
        vec![
            resolve_op("alpha", "note", ConflictKeep::Losing, &a2),
            resolve_op("alpha", "note", ConflictKeep::Losing, &a1),
        ],
    ] {
        let err = rig.pane(ops).expect_err("two values for one field");
        assert_eq!(err.code, "invalid_args");
        assert_eq!(rig.snapshot(), before, "nothing written");
        assert_eq!(
            rig.conflict_ids("alpha"),
            ids,
            "both conflicts are still kept"
        );
        assert_eq!(rig.losers("alpha", "note"), vec!["a1", "a2"]);
        assert_eq!(rig.item("alpha").note.as_deref(), Some("p2"));
    }
}

/// Keeping the current value of any number of one field's conflicts, with one
/// losing value, is one decision and stays allowed.
#[test]
fn a_batch_may_keep_current_for_several_conflicts_of_a_field_and_one_losing_value() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 3);
    let ids = rig.conflict_ids("alpha");
    rig.pane(vec![
        resolve_op("alpha", "note", ConflictKeep::Current, &ids[0]),
        resolve_op("alpha", "note", ConflictKeep::Current, &ids[1]),
        resolve_op("alpha", "note", ConflictKeep::Losing, &ids[2]),
    ])
    .unwrap();
    assert_eq!(rig.item("alpha").note.as_deref(), Some("a3"));
    assert!(rig.item("alpha").conflicts.is_empty(), "all three settled");
}

/// One losing value for each of two different fields of an item is two
/// decisions.
#[test]
fn a_batch_may_keep_a_losing_value_for_each_of_two_fields_of_one_item() {
    let rig = Rig::new();
    rig.first_status_conflict();
    lose_notes(&rig, 1, 1);
    let status = rig.conflict_id("alpha", "status", "in-progress");
    let note = rig.conflict_id("alpha", "note", "a1");
    rig.pane(vec![
        resolve_op("alpha", "status", ConflictKeep::Losing, &status),
        resolve_op("alpha", "note", ConflictKeep::Losing, &note),
    ])
    .unwrap();
    assert_eq!(rig.item("alpha").status, Status::InProgress);
    assert_eq!(rig.item("alpha").note.as_deref(), Some("a1"));
    assert!(rig.item("alpha").conflicts.is_empty());
}

/// Two items removed over the user's edits can be put back in one batch.
#[test]
fn a_batch_may_restore_two_removed_items() {
    let rig = Rig::new();
    rig.tick(100);
    rig.pane(vec![
        pane_edit_body("alpha", "alpha details"),
        pane_edit_body("beta", "beta details"),
    ])
    .unwrap();
    rig.tick(3);
    rig.agent_b(&[Op::Remove { id: "alpha".into() }]).unwrap();
    rig.agent_b(&[Op::Remove { id: "beta".into() }]).unwrap();
    let removed = rig.reg.board_view(TAG_A).unwrap().removed_conflicts;
    assert_eq!(removed.len(), 2, "{removed:?}");
    let ops: Vec<TrackerPaneOp> = removed
        .iter()
        .map(|r| resolve_op(&r.item_id, "removed", ConflictKeep::Losing, &r.conflict_id))
        .collect();

    rig.pane(ops).unwrap();
    assert_eq!(rig.item("alpha").note.as_deref(), Some("alpha details"));
    assert_eq!(rig.item("beta").note.as_deref(), Some("beta details"));
    assert!(rig
        .reg
        .board_view(TAG_A)
        .unwrap()
        .removed_conflicts
        .is_empty());
}

// ---------------------------------------------------------------------------
// R5: an item whose only conflict a cap dropped says so; the pane can ack it
// ---------------------------------------------------------------------------

/// The board's cap drops `alpha`'s only conflict because fifty others arrived
/// on other items. The pane shows alpha with a dropped count, and the agent's
/// next read tells about alpha, not only about the item just recorded.
#[test]
fn when_the_board_cap_drops_an_items_only_conflict_the_pane_and_the_agent_are_told() {
    let rig = Rig::new();
    drop_alphas_only_conflict_with_the_board_cap(&rig);

    assert_eq!(rig.reg.conflicts(TAG_A).len(), 50);
    assert!(rig
        .reg
        .conflicts(TAG_A)
        .iter()
        .all(|c| c.item_id != "alpha"));
    let alpha = rig.item("alpha");
    assert!(alpha.conflicts.is_empty(), "nothing left to show of it");
    assert_eq!(alpha.dropped_conflicts, 1);
    assert!(serialized_has_dropped_marker(&alpha));

    let delta = rig.delta(TAG_A, SESS_A);
    assert!(
        dropped_notices_for(&delta, "alpha").contains(&1),
        "the agent's delta tells about alpha's lost conflict: {delta:?}"
    );
}

/// The user acknowledges the loss: the count goes, and nothing else changes.
#[test]
fn ack_dropped_clears_the_count_of_an_item_whose_conflict_a_cap_dropped() {
    let rig = Rig::new();
    drop_alphas_only_conflict_with_the_board_cap(&rig);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);
    let text = rig.text();
    let kept = rig.reg.conflicts(TAG_A).len();

    rig.pane(vec![ack_op("alpha")]).unwrap();

    assert_eq!(rig.item("alpha").dropped_conflicts, 0);
    assert!(!serialized_has_dropped_marker(&rig.item("alpha")));
    assert_eq!(rig.text(), text, "an acknowledgement is not an edit");
    assert_eq!(rig.reg.conflicts(TAG_A).len(), kept);
    assert_eq!(rig.item("bulk-49").conflicts.len(), 1);
}

/// The count also clears while some of the item's conflicts are still kept.
#[test]
fn ack_dropped_clears_the_count_while_the_items_other_conflicts_stay() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);
    let ids = rig.conflict_ids("alpha");

    rig.pane(vec![ack_op("alpha")]).unwrap();

    assert_eq!(rig.item("alpha").dropped_conflicts, 0);
    assert_eq!(
        rig.conflict_ids("alpha"),
        ids,
        "the kept ones are untouched"
    );
}

#[test]
fn ack_dropped_is_refused_for_an_unknown_item_or_one_with_nothing_dropped() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);
    let before = rig.snapshot();

    let err = rig.pane(vec![ack_op("nope")]).expect_err("unknown item");
    assert!(
        ["unknown_item", "invalid_args"].contains(&err.code.as_str()),
        "{err:?}"
    );
    assert_eq!(err.index, Some(0));
    assert_eq!(rig.snapshot(), before);

    let err = rig
        .pane(vec![ack_op("beta")])
        .expect_err("nothing was dropped for beta");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(err.index, Some(0));
    assert!(reason_of(&err).contains("look again"), "{:?}", err.reason);
    assert_eq!(rig.snapshot(), before);
    assert_eq!(
        rig.item("alpha").dropped_conflicts,
        1,
        "alpha's is untouched"
    );
}

/// The user cannot hide a loss they have not seen: more were dropped after
/// the view the acknowledgement was made from.
#[test]
fn ack_dropped_is_refused_when_more_were_dropped_after_the_users_view() {
    // The view predates the first drop.
    let rig = Rig::new();
    lose_notes(&rig, 1, 5);
    let seen = rig.version();
    lose_notes(&rig, 6, 6);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);
    let before = rig.snapshot();
    let err = rig
        .pane_at(seen, vec![ack_op("alpha")])
        .expect_err("a drop after the view");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(err.index, Some(0));
    assert_eq!(rig.snapshot(), before);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);

    // The view showed a count of one; since then another was dropped.
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    let seen = rig.version();
    lose_notes(&rig, 7, 7);
    assert_eq!(rig.item("alpha").dropped_conflicts, 2);
    let before = rig.snapshot();
    let err = rig
        .pane_at(seen, vec![ack_op("alpha")])
        .expect_err("a second drop after the view");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(rig.snapshot(), before);
    assert_eq!(rig.item("alpha").dropped_conflicts, 2, "still both");
    // From a view that shows the current count it is accepted.
    rig.pane(vec![ack_op("alpha")]).unwrap();
    assert_eq!(rig.item("alpha").dropped_conflicts, 0);
}

/// After an acknowledgement, the next drop is counted from nothing, in the
/// pane's view and in what the agent reads.
#[test]
fn after_an_ack_a_later_drop_counts_from_zero_again() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    rig.pane(vec![ack_op("alpha")]).unwrap();
    assert_eq!(rig.item("alpha").dropped_conflicts, 0);

    lose_notes(&rig, 7, 7);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1, "not 2");
    let delta = rig.delta(TAG_A, SESS_A);
    let entries = value_conflict_entries(&delta);
    assert_eq!(entries.len(), 7, "{delta:?}");
    assert_eq!(entries[5]["conflict"]["dropped_conflicts"], 1);
    assert_eq!(
        entries[6]["conflict"]["dropped_conflicts"], 1,
        "the seventh drop is the first since the acknowledgement"
    );
}

/// An acknowledgement is part of a batch: all of it or none of it.
#[test]
fn a_batch_with_a_failing_ack_writes_nothing() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    let before = rig.snapshot();

    let err = rig
        .pane(vec![
            pane_status("beta", "done"),
            ack_op("alpha"),
            ack_op("beta"),
        ])
        .expect_err("beta has nothing dropped");
    assert_eq!(err.code, "invalid_args");
    assert_eq!(err.index, Some(2));
    assert_eq!(rig.snapshot(), before, "beta's tick was not written");
    assert_eq!(rig.item("beta").status, Status::Todo);
    assert_eq!(
        rig.item("alpha").dropped_conflicts,
        1,
        "alpha's ack did not apply"
    );

    let err = rig
        .pane(vec![ack_op("alpha"), pane_status("nope", "done")])
        .expect_err("an unknown item after a good ack");
    assert_eq!((err.code.as_str(), err.index), ("unknown_item", Some(1)));
    assert_eq!(rig.snapshot(), before);
    assert_eq!(
        rig.item("alpha").dropped_conflicts,
        1,
        "alpha's ack did not apply"
    );
}

// ---------------------------------------------------------------------------
// R13: settling the oldest of a full field while overflowing it is not a loss
// ---------------------------------------------------------------------------

/// `alpha`'s note holds five conflicts. In one batch the user settles the
/// oldest and edits the note over agent B's newer value (a sixth conflict, one
/// over the field's cap). The oldest was settled, not lost: nothing is dropped.
#[test]
fn settling_the_oldest_of_a_full_field_while_overflowing_it_loses_nothing() {
    for keep in [ConflictKeep::Losing, ConflictKeep::Current] {
        let rig = Rig::new();
        lose_notes(&rig, 1, 5);
        assert_eq!(rig.item("alpha").conflicts.len(), 5);
        let a1 = rig.conflict_id("alpha", "note", "a1");
        let seen = rig.version();
        // A newer note from agent B, which the user's view lacks.
        rig.tick(30);
        rig.reg.read(TAG_B, SESS_B).unwrap();
        rig.agent_b(&[note_op("alpha", "a6")]).unwrap();

        rig.pane_at(
            seen,
            vec![
                resolve_op("alpha", "note", keep, &a1),
                pane_edit_body("alpha", "p6"),
            ],
        )
        .unwrap();

        assert_eq!(
            rig.losers("alpha", "note"),
            vec!["a2", "a3", "a4", "a5", "a6"],
            "{keep:?}: a1 was settled, a6 is kept"
        );
        assert_eq!(rig.item("alpha").dropped_conflicts, 0, "{keep:?}");
        assert!(!serialized_has_dropped_marker(&rig.item("alpha")));
        assert_eq!(rig.item("alpha").note.as_deref(), Some("p6"));
        let delta = rig.delta(TAG_A, SESS_A);
        assert!(
            delta
                .iter()
                .all(|e| e["conflict"].get("dropped_conflicts").is_none()),
            "{keep:?}: the agent is not told of a loss that did not happen: {delta:?}"
        );

        // Settling every one that is left ends with a clean item.
        for id in rig.conflict_ids("alpha") {
            rig.pane(vec![resolve_op(
                "alpha",
                "note",
                ConflictKeep::Current,
                &id,
            )])
            .unwrap();
            assert_eq!(rig.item("alpha").dropped_conflicts, 0, "{keep:?}");
        }
        assert!(rig.item("alpha").conflicts.is_empty());
        assert!(rig
            .reg
            .conflicts(TAG_A)
            .iter()
            .all(|c| c.item_id != "alpha"));
        assert!(!serialized_has_dropped_marker(&rig.item("alpha")));
        assert_eq!(rig.item("alpha").note.as_deref(), Some("p6"));
    }
}

/// With a real earlier drop on the item (a1), the same batch adds nothing to
/// the count: it stays 1, and the agent's entry for the new conflict says 1.
#[test]
fn settling_the_oldest_of_a_full_field_while_overflowing_adds_nothing_to_an_earlier_drop() {
    for keep in [ConflictKeep::Losing, ConflictKeep::Current] {
        let rig = Rig::new();
        lose_notes(&rig, 1, 6);
        assert_eq!(
            rig.losers("alpha", "note"),
            vec!["a2", "a3", "a4", "a5", "a6"]
        );
        assert_eq!(rig.item("alpha").dropped_conflicts, 1);
        let a2 = rig.conflict_id("alpha", "note", "a2");
        let seen = rig.version();
        rig.tick(30);
        rig.reg.read(TAG_B, SESS_B).unwrap();
        rig.agent_b(&[note_op("alpha", "a7")]).unwrap();

        rig.pane_at(
            seen,
            vec![
                resolve_op("alpha", "note", keep, &a2),
                pane_edit_body("alpha", "p7"),
            ],
        )
        .unwrap();

        assert_eq!(
            rig.losers("alpha", "note"),
            vec!["a3", "a4", "a5", "a6", "a7"],
            "{keep:?}"
        );
        assert_eq!(
            rig.item("alpha").dropped_conflicts,
            1,
            "{keep:?}: only a1 was lost"
        );
        let delta = rig.delta(TAG_A, SESS_A);
        let entries = value_conflict_entries(&delta);
        assert_eq!(entries.len(), 7, "{delta:?}");
        assert_eq!(entries[5]["conflict"]["dropped_conflicts"], 1);
        assert_eq!(
            entries[6]["conflict"]["dropped_conflicts"], 1,
            "{keep:?}: a2 was settled, not dropped"
        );
    }
}

// ---------------------------------------------------------------------------
// R11 (M1): the overwritten value is kept when its field has no entry in the
// log the pane's position is compared with
// ---------------------------------------------------------------------------

/// The daemon lost its state after agent B set alpha's note. The pane's view
/// is from before that note, at a version beyond the new, empty log: it cannot
/// have seen the note, so its overwrite is a conflict and the note is kept.
#[test]
fn a_lost_state_keeps_the_agents_note_a_stale_pane_overwrites() {
    let mut rig = Rig::new();
    rig.tick(100);
    // Some history, so the pane's view is at a version well past a fresh log.
    for k in 0..10 {
        rig.agent_a(&[upsert(&format!("filler-{k}"), "now", "Filler")])
            .unwrap();
    }
    let pane_view = rig.version();
    rig.tick(100);
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();

    rig.restart_losing_state();
    assert!(rig.version() < pane_view, "the new log is behind the view");
    rig.tick(100);
    rig.pane_at(pane_view, vec![pane_edit_body("alpha", "the user's note")])
        .unwrap();

    assert_eq!(rig.item("alpha").note.as_deref(), Some("the user's note"));
    assert_eq!(
        rig.losers("alpha", "note"),
        vec!["the agent's note"],
        "the agent's note is kept, not silently lost"
    );
}

/// The agent's note rolled off the log (the state was rolled back) but is
/// still in the file; a pane whose position is beyond the log overwrites it.
#[test]
fn a_rolled_back_state_keeps_the_agents_note_a_stale_pane_overwrites() {
    let mut rig = Rig::new();
    rig.tick(100);
    let kept_through = rig.version();
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();
    for k in 0..4 {
        rig.agent_a(&[upsert(&format!("filler-{k}"), "now", "Filler")])
            .unwrap();
    }
    let pane_view = rig.version();
    rig.roll_log_back_to(kept_through);
    rig.restart();
    assert_eq!(rig.version(), kept_through, "the log really went back");
    assert!(pane_view > kept_through);

    rig.tick(100);
    rig.pane_at(pane_view, vec![pane_edit_body("alpha", "the user's note")])
        .unwrap();

    assert_eq!(rig.item("alpha").note.as_deref(), Some("the user's note"));
    assert_eq!(rig.losers("alpha", "note"), vec!["the agent's note"]);
}

// ---------------------------------------------------------------------------
// R11 (residual): a base version from another run of the board
// ---------------------------------------------------------------------------

/// After a state loss the new log grows past the pane's stale base. An agent
/// change of the new run, at a version at or below that base, would count as
/// seen. The view's epoch says the base is of another run: nothing was seen.
#[test]
fn a_base_version_from_another_run_of_the_board_has_seen_nothing() {
    let mut rig = Rig::new();
    rig.tick(100);
    for k in 0..6 {
        rig.agent_a(&[upsert(&format!("filler-{k}"), "now", "Filler")])
            .unwrap();
    }
    let (old_view, old_epoch) = (rig.version(), rig.epoch());
    assert!(!old_epoch.is_empty(), "the view carries the board's epoch");

    rig.restart_losing_state();
    assert_ne!(rig.epoch(), old_epoch, "a new run has its own epoch");
    rig.tick(100);
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();
    let note_version = rig.version();
    // The new run's log grows past the pane's stale base.
    let mut k = 0;
    while rig.version() <= old_view + 2 {
        rig.agent_a(&[upsert(&format!("later-{k}"), "now", "Later")])
            .unwrap();
        k += 1;
    }
    assert!(
        note_version <= old_view,
        "the note sits at or below the base"
    );
    rig.tick(100);

    rig.pane_in(
        old_view,
        &old_epoch,
        vec![pane_edit_body("alpha", "the user's note")],
    )
    .unwrap();

    assert_eq!(rig.item("alpha").note.as_deref(), Some("the user's note"));
    assert_eq!(rig.losers("alpha", "note"), vec!["the agent's note"]);
}

/// A value from before a state loss is in the new log nowhere. A pane edit
/// from the old view overwrites it after the new log has grown past the old
/// base version: the base is of another run, so the value is kept all the same.
#[test]
fn a_value_from_before_a_state_loss_is_kept_when_the_new_log_grew_past_the_old_base() {
    let mut rig = Rig::new();
    rig.tick(100);
    rig.agent_b(&[note_op("alpha", "the note before the loss")])
        .unwrap();
    let (old_view, old_epoch) = (rig.version(), rig.epoch());

    rig.restart_losing_state();
    rig.tick(100);
    let mut k = 0;
    while rig.version() <= old_view + 2 {
        rig.agent_a(&[upsert(&format!("later-{k}"), "now", "Later")])
            .unwrap();
        k += 1;
    }
    assert!(rig.version() > old_view, "the new log grew past the base");
    rig.tick(100);

    rig.pane_in(
        old_view,
        &old_epoch,
        vec![pane_edit_body("alpha", "the user's note")],
    )
    .unwrap();

    assert_eq!(rig.item("alpha").note.as_deref(), Some("the user's note"));
    assert_eq!(
        rig.losers("alpha", "note"),
        vec!["the note before the loss"]
    );
}

/// A view of the current run is trusted as before: an agent change at or below
/// its base was seen, and overwriting it is no conflict.
#[test]
fn a_base_version_of_the_current_run_is_trusted() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();
    rig.tick(100);
    rig.pane_in(
        rig.version(),
        &rig.epoch(),
        vec![pane_edit_body("alpha", "the user's note")],
    )
    .unwrap();
    assert!(rig.losers("alpha", "note").is_empty());
}

/// A pane that sends no epoch (an older one) is judged by its base version as
/// before.
#[test]
fn an_edit_without_a_base_epoch_trusts_its_base_version() {
    let rig = Rig::new();
    rig.tick(100);
    rig.agent_b(&[note_op("alpha", "the agent's note")])
        .unwrap();
    rig.tick(100);
    rig.pane(vec![pane_edit_body("alpha", "the user's note")])
        .unwrap();
    assert!(rig.losers("alpha", "note").is_empty());
}

/// An approval or an acknowledgement from a view of another run can't be
/// shown what changed since: refused as stale.
#[test]
fn an_acknowledgement_from_a_view_of_another_run_is_refused_as_stale() {
    let rig = Rig::new();
    lose_notes(&rig, 1, 6);
    let before = rig.snapshot();
    let err = rig
        .pane_in(rig.version(), "another-run", vec![ack_op("alpha")])
        .expect_err("a view of another run");
    assert!(err.stale, "{err:?}");
    assert_eq!(rig.snapshot(), before);
    assert_eq!(rig.item("alpha").dropped_conflicts, 1);
}

// ---------------------------------------------------------------------------
// "Look again" has a result code of its own: `stale`
// ---------------------------------------------------------------------------

#[test]
fn every_look_again_refusal_is_marked_stale_and_keeps_invalid_args() {
    // An id from before the state was lost (a conflict that no longer exists).
    let mut rig = Rig::new();
    rig.first_status_conflict();
    let old_id = rig.conflict_id("alpha", "status", "in-progress");
    rig.restart_losing_state();
    let err = rig
        .pane(vec![resolve_op(
            "alpha",
            "status",
            ConflictKeep::Current,
            &old_id,
        )])
        .expect_err("an old-run conflict id");
    assert_eq!((err.code.as_str(), err.stale), ("invalid_args", true));

    // A conflict id that never existed.
    let rig = Rig::new();
    rig.first_status_conflict();
    let err = rig
        .pane(vec![resolve_op(
            "alpha",
            "status",
            ConflictKeep::Losing,
            "nope.1.0",
        )])
        .expect_err("an unknown conflict id");
    assert_eq!((err.code.as_str(), err.stale), ("invalid_args", true));

    // Nothing to acknowledge.
    let rig = Rig::new();
    let err = rig
        .pane(vec![ack_op("beta")])
        .expect_err("nothing was dropped");
    assert_eq!((err.code.as_str(), err.stale), ("invalid_args", true));

    // More dropped since the view.
    let rig = Rig::new();
    lose_notes(&rig, 1, 5);
    let seen = rig.version();
    lose_notes(&rig, 6, 6);
    let err = rig
        .pane_at(seen, vec![ack_op("alpha")])
        .expect_err("more dropped since the view");
    assert_eq!((err.code.as_str(), err.stale), ("invalid_args", true));
}

/// A refusal that look-again would not fix is not stale.
#[test]
fn a_refusal_that_looking_again_would_not_fix_is_not_stale() {
    let rig = Rig::new();
    rig.first_status_conflict();
    let err = rig
        .pane(vec![TrackerPaneOp::ResolveConflict {
            id: "alpha".into(),
            field: "status".into(),
            keep: ConflictKeep::Current,
            conflict_id: None,
            index: Some(0),
        }])
        .expect_err("a position names nothing");
    assert_eq!((err.code.as_str(), err.stale), ("invalid_args", false));
    let err = rig
        .pane(vec![pane_status("nope", "done")])
        .expect_err("unknown item");
    assert!(!err.stale);
}
