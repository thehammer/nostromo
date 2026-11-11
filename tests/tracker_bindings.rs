//! Live tracker items (slice T6, PRD 51-54): an item bound to a Mother job or a
//! PR's CI follows its source with no agent call.
//!
//! Hermetic: a `FakeClock` (nothing here reads the wall clock), temp dirs for
//! the repo, state root and home, no git repo, no real `~/.nostromo`. The
//! feeds are faked by calling `BindingHub::apply_mother` / `apply_ci` with
//! hand-built jobs and check runs; "time passes" by advancing the fake clock
//! and calling `BindingHub::tick`. File writes are counted through a
//! `BoardFs` wrapper that stamps each board write with the fake clock.

use std::cell::Cell;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration as StdDuration;

use chrono::{DateTime, Duration, Utc};
use nostromo::data::perri_pr::CiCheck;
use nostromo::data::perri_queue::CiState;
use nostromo::ipc::protocol::ServerMsg;
use nostromo::mother::MotherJob;
use nostromo::tracker::bindings::{CI_NOTE_PREFIX, MOTHER_NOTE_PREFIX};
use nostromo::tracker::view::{BoundView, ViewItem, ViewNode};
use nostromo::tracker::watch::{BoardFs, FileSignature, RealBoardFs};
use nostromo::tracker::{
    parse, Author, Binding, BindingHub, CiObservation, Clock, FakeClock, Op, OpenArgs, ReadOutcome,
    RegistryParts, Status, TrackerBoardView, TrackerError, TrackerRegistry, Upsert, WriteOutcome,
};
use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::sync::broadcast;

const WRITER: &str = "tag-w";
const WRITER_SESSION: &str = "sess-w";
const READER: &str = "tag-r";
const READER_SESSION: &str = "sess-r";
const OTHER: &str = "tag-x";
const OTHER_SESSION: &str = "sess-x";
const FILE_LABEL: &str = "file (unknown editor)";

const REPO: &str = "Carefeed/admin-portal";
const PR_URL: &str = "https://github.com/Carefeed/admin-portal/pull/253";

/// The usual board: one plain item and one item per source kind.
const STANDARD: [(&str, Option<&str>); 4] = [
    ("plain", None),
    ("job", Some("mother.job/JOB1")),
    ("ci", Some("pr.ci/Carefeed/admin-portal#253")),
    ("green", Some("pr.ci/Carefeed/admin-portal#254!green")),
];

/// One item per row of the mapping tables.
const MAPPING: [(&str, Option<&str>); 13] = [
    ("m-running", Some("mother.job/J-RUNNING")),
    ("m-running-pr", Some("mother.job/J-RUNNING-PR")),
    ("m-succeeded", Some("mother.job/J-SUCCEEDED")),
    ("m-failed", Some("mother.job/J-FAILED")),
    ("m-cancelled", Some("mother.job/J-CANCELLED")),
    ("m-awaiting", Some("mother.job/J-AWAITING")),
    ("m-merged", Some("mother.job/J-MERGED")),
    ("m-unknown", Some("mother.job/J-UNKNOWN")),
    ("ci-pending", Some("pr.ci/Carefeed/admin-portal#11")),
    ("ci-failing", Some("pr.ci/Carefeed/admin-portal#12")),
    ("ci-green", Some("pr.ci/Carefeed/admin-portal#13")),
    ("ci-done", Some("pr.ci/Carefeed/admin-portal#14!green")),
    ("plain", None),
];

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------

/// The real file system, plus a record of when each write happened (by the
/// fake clock).
struct CountingFs {
    inner: RealBoardFs,
    clock: Arc<FakeClock>,
    writes: Mutex<Vec<(PathBuf, DateTime<Utc>)>>,
}

impl CountingFs {
    fn reset(&self) {
        self.writes.lock().unwrap().clear();
    }

    /// When the board file(s) were written since the last reset.
    fn board_writes(&self) -> Vec<DateTime<Utc>> {
        self.writes
            .lock()
            .unwrap()
            .iter()
            .filter(|(path, _)| path.file_name().is_some_and(|n| n == "index.md"))
            .map(|(_, at)| *at)
            .collect()
    }
}

impl BoardFs for CountingFs {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        self.inner.read(path)
    }

    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        self.writes
            .lock()
            .unwrap()
            .push((path.to_path_buf(), self.clock.now()));
        self.inner.write_atomic(path, bytes)
    }

    fn signature(&self, path: &Path) -> Option<FileSignature> {
        self.inner.signature(path)
    }

    fn create_dir_all(&self, dir: &Path) -> io::Result<()> {
        self.inner.create_dir_all(dir)
    }
}

struct Rig {
    _tmp: TempDir,
    base: PathBuf,
    repo: PathBuf,
    home: PathBuf,
    path: PathBuf,
    clock: Arc<FakeClock>,
    fs: Arc<CountingFs>,
    reg: Arc<TrackerRegistry>,
    hub: BindingHub,
    probes: Cell<usize>,
}

fn writer() -> Author {
    Author::Agent {
        focus: WRITER.into(),
        session_id: WRITER_SESSION.into(),
        name: WRITER.into(),
    }
}

fn open_args(repo: &Path, topic: &str) -> OpenArgs {
    OpenArgs {
        topic: Some(topic.into()),
        cwd: repo.to_path_buf(),
        ..Default::default()
    }
}

fn seed_ops(items: &[(&str, Option<&str>)]) -> Vec<Op> {
    items
        .iter()
        .map(|&(id, bind)| {
            Op::Upsert(Upsert {
                id: Some(id.into()),
                section: Some("now".into()),
                text: Some(format!("Item {id}")),
                bind: bind.map(str::to_string),
                ..Default::default()
            })
        })
        .collect()
}

impl Rig {
    fn standard() -> Rig {
        Rig::with_items(&STANDARD)
    }

    /// A board `live` with the given `(id, bind)` items, bound to a writer
    /// focus and a reader focus (two Claude sessions on one board); the
    /// reader is caught up and the write counter is zero.
    fn with_items(items: &[(&str, Option<&str>)]) -> Rig {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let repo = base.join("repo");
        let home = base.join("home");
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let fs = Arc::new(CountingFs {
            inner: RealBoardFs,
            clock: clock.clone(),
            writes: Mutex::new(Vec::new()),
        });
        let mut parts = RegistryParts::hermetic(base.join("state"), home.clone(), clock.clone());
        let dyn_fs: Arc<dyn BoardFs> = fs.clone();
        parts.fs = dyn_fs;
        let reg = Arc::new(TrackerRegistry::new(parts));
        let args = open_args(&repo, "live");
        let mut path = None;
        for (tag, session) in [(WRITER, WRITER_SESSION), (READER, READER_SESSION)] {
            path = Some(reg.open(tag, session, &args).expect("open").path);
        }
        reg.apply(WRITER, WRITER_SESSION, &seed_ops(items), &writer())
            .expect("seed");
        let rig = Rig {
            _tmp: tmp,
            base,
            repo,
            home,
            path: path.unwrap(),
            clock,
            fs,
            hub: BindingHub::new(reg.clone()),
            reg,
            probes: Cell::new(0),
        };
        rig.reader_changes();
        rig.fs.reset();
        rig
    }

    fn now(&self) -> DateTime<Utc> {
        self.clock.now()
    }

    fn advance(&self, secs: i64) {
        self.clock.advance(Duration::seconds(secs));
    }

    // -- feeds --------------------------------------------------------------

    /// The Mother feed reports one job in `state`, observed now.
    fn mother(&self, job_id: &str, state: &str) -> bool {
        self.hub
            .apply_mother(&[job(job_id, state)], Some(self.now()))
    }

    /// The CI feed reports `checks` for a PR, observed now.
    fn ci(&self, repo: &str, number: u64, checks: &[CiCheck]) -> bool {
        self.hub.apply_ci(
            repo,
            number,
            &CiObservation::from_checks(checks),
            self.now(),
        )
    }

    // -- what a client sees -------------------------------------------------

    fn view(&self) -> TrackerBoardView {
        self.reg.board_view(READER).expect("a board view")
    }

    fn view_item(&self, id: &str) -> ViewItem {
        item(&self.view(), id)
            .cloned()
            .unwrap_or_else(|| panic!("no item {id} in the view"))
    }

    /// What an agent with no cursor reads: the compact full board.
    fn board_text(&self) -> String {
        let n = self.probes.get();
        self.probes.set(n + 1);
        match self.reg.read(READER, &format!("probe-{n}")).expect("read") {
            ReadOutcome::Full { board, .. } => board,
            other => panic!("a session with no cursor gets the whole board: {other:?}"),
        }
    }

    /// The lines of the item's note as an agent reads them.
    fn note_lines(&self, id: &str) -> Vec<String> {
        let text = self.board_text();
        let header = format!("- {id} [");
        let mut lines = text.lines().skip_while(|l| !l.starts_with(header.as_str()));
        assert!(lines.next().is_some(), "no item {id} in:\n{text}");
        lines
            .take_while(|l| l.starts_with("  "))
            .filter(|l| !l.starts_with("  Links: "))
            .map(|l| l.trim().to_string())
            .collect()
    }

    fn reader_changes(&self) -> Vec<Value> {
        match self.reg.read(READER, READER_SESSION).expect("read") {
            ReadOutcome::Delta { changes, .. } => changes,
            ReadOutcome::Full { .. } => panic!("the reader has a cursor: expected a delta"),
        }
    }

    // -- the file -----------------------------------------------------------

    fn file_text(&self) -> String {
        String::from_utf8(std::fs::read(&self.path).unwrap()).unwrap()
    }

    /// What the file itself says (no live overlay).
    fn file_status(&self, id: &str) -> Status {
        let parsed = parse(&std::fs::read(&self.path).unwrap()).expect("the board file parses");
        parsed
            .board
            .items
            .iter()
            .find(|i| i.id == id)
            .unwrap_or_else(|| panic!("no item {id} in the file"))
            .status
    }

    /// An editor changes an item's status word (and tick box) in the file and
    /// the watcher fires.
    fn external_status(&self, id: &str, from_word: &str, to_word: &str) {
        let before = self.file_text();
        let marker = format!("<!-- #{id} ");
        let after = before
            .split('\n')
            .map(|line| {
                if !line.contains(marker.as_str()) {
                    return line.to_string();
                }
                let line = line.replacen(&format!("— {from_word} ·"), &format!("— {to_word} ·"), 1);
                if to_word == "done" {
                    line.replacen("- [ ] ", "- [x] ", 1)
                } else {
                    line
                }
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert_ne!(before, after, "the test's edit must change the file");
        std::fs::write(&self.path, after).unwrap();
        self.reg.ingest_file_change(&self.path);
    }

    // -- binding ------------------------------------------------------------

    /// The agent upserts `bind` on item `id`.
    fn bind(&self, id: &str, bind: &str) -> Result<WriteOutcome, TrackerError> {
        self.reg.apply(
            WRITER,
            WRITER_SESSION,
            &[Op::Upsert(Upsert {
                id: Some(id.into()),
                bind: Some(bind.into()),
                ..Default::default()
            })],
            &writer(),
        )
    }

    fn live(&self) -> Vec<(String, Binding)> {
        self.reg
            .live_bindings()
            .into_iter()
            .map(|l| (l.item_id, l.binding))
            .collect()
    }

    /// A second board (topic `other`) in the same repo, bound to its own focus.
    fn open_other_board(&self, items: &[(&str, Option<&str>)]) {
        self.reg
            .open(OTHER, OTHER_SESSION, &open_args(&self.repo, "other"))
            .expect("open other");
        self.reg
            .apply(OTHER, OTHER_SESSION, &seed_ops(items), &writer())
            .expect("seed other");
    }

    /// The daemon restarting over the same state root.
    fn restart(&self) -> TrackerRegistry {
        TrackerRegistry::new(RegistryParts::hermetic(
            self.base.join("state"),
            self.home.clone(),
            self.clock.clone(),
        ))
    }
}

fn item<'a>(view: &'a TrackerBoardView, id: &str) -> Option<&'a ViewItem> {
    view.nodes.iter().find_map(|n| match n {
        ViewNode::Item(i) if i.id == id => Some(i),
        _ => None,
    })
}

/// A Mother job as the broker lists it.
fn job(id: &str, state: &str) -> MotherJob {
    job_with(id, state, json!({}))
}

fn job_with(id: &str, state: &str, extra: Value) -> MotherJob {
    let mut record = json!({"id": id, "state": state, "title": "Bound job fixture"});
    for (key, value) in extra.as_object().expect("extra fields are an object") {
        record[key.as_str()] = value.clone();
    }
    serde_json::from_value(record).expect("a MotherJob")
}

fn check(name: &str, state: CiState) -> CiCheck {
    CiCheck {
        name: name.into(),
        state,
        detail: None,
    }
}

/// `total` checks of which the first `passed` are green and the rest pending.
fn pending_checks(passed: usize, total: usize) -> Vec<CiCheck> {
    (0..total)
        .map(|i| {
            check(
                &format!("check-{i}"),
                if i < passed {
                    CiState::Success
                } else {
                    CiState::Pending
                },
            )
        })
        .collect()
}

fn green_checks() -> Vec<CiCheck> {
    vec![
        check("build", CiState::Success),
        check("lint", CiState::Success),
    ]
}

fn failing_checks() -> Vec<CiCheck> {
    vec![
        check("build", CiState::Success),
        check("lint", CiState::Failure),
        check("unit", CiState::Failure),
    ]
}

fn note_text(item: &ViewItem) -> String {
    format!("{:?}", item.note_blocks)
}

// ---------------------------------------------------------------------------
// Mapping: what a source says becomes what the item shows (PRD 51)
// ---------------------------------------------------------------------------

#[test]
fn mother_job_states_map_onto_item_statuses_and_notes() {
    let rig = Rig::with_items(&MAPPING);
    let jobs = vec![
        job("J-RUNNING", "running"),
        job_with("J-RUNNING-PR", "running", json!({"pr_url": PR_URL})),
        job("J-SUCCEEDED", "succeeded"),
        job_with(
            "J-FAILED",
            "failed",
            json!({"failure_reason": "gates did not pass: RAW-FREE-TEXT-9"}),
        ),
        job("J-CANCELLED", "cancelled"),
        job_with(
            "J-AWAITING",
            "awaiting",
            json!({"question": "Which branch should I use?\nmore detail"}),
        ),
        job("J-MERGED", "pr_merged"),
        job("J-UNKNOWN", "teleporting"),
    ];

    assert!(
        rig.hub.apply_mother(&jobs, Some(rig.now())),
        "the views changed"
    );

    for (id, expected) in [
        ("m-running", Status::InProgress),
        ("m-running-pr", Status::InProgress),
        ("m-succeeded", Status::Done),
        ("m-failed", Status::Blocked),
        ("m-cancelled", Status::Blocked),
        ("m-awaiting", Status::NeedsYou),
        ("m-merged", Status::Done),
        ("m-unknown", Status::InProgress),
    ] {
        assert_eq!(rig.view_item(id).status, expected, "{id}");
    }
    assert_eq!(
        rig.view_item("plain").status,
        Status::Todo,
        "an unbound item is not touched"
    );

    // A running job with a PR links to it, keeping the url.
    let linked = rig.view_item("m-running-pr");
    assert!(
        linked
            .links
            .iter()
            .any(|l| l.text == "PR #253" && l.url.as_deref() == Some(PR_URL)),
        "{:?}",
        linked.links
    );
    assert!(rig.view_item("m-running").links.is_empty());

    // The failure names its class, never Mother's own words.
    let failed = rig.note_lines("m-failed");
    assert_eq!(
        failed.first().map(String::as_str),
        Some("Mother job failed (gates)")
    );
    assert!(
        !failed.join("\n").contains("RAW-FREE-TEXT-9"),
        "Mother's free text stays out of the note: {failed:?}"
    );

    // A state Mother adds later is shown as it is, not a crash.
    let unknown = rig.note_lines("m-unknown");
    let first = unknown.first().expect("a source-owned note line");
    assert!(first.starts_with(MOTHER_NOTE_PREFIX), "{first}");
    assert!(first.contains("teleporting"), "{first}");

    // Every bound item's first note line is the source's.
    for id in [
        "m-running",
        "m-succeeded",
        "m-cancelled",
        "m-awaiting",
        "m-merged",
    ] {
        let lines = rig.note_lines(id);
        assert!(
            lines
                .first()
                .is_some_and(|l| l.starts_with(MOTHER_NOTE_PREFIX)),
            "{id}: {lines:?}"
        );
    }
}

#[test]
fn pr_ci_states_map_onto_item_statuses_and_notes() {
    let rig = Rig::with_items(&MAPPING);

    assert!(rig.ci(REPO, 11, &pending_checks(1, 5)));
    assert!(rig.ci(REPO, 12, &failing_checks()));
    assert!(rig.ci(REPO, 13, &green_checks()));
    assert!(rig.ci(REPO, 14, &green_checks()));

    assert_eq!(rig.view_item("ci-pending").status, Status::InProgress);
    let pending = rig.note_lines("ci-pending");
    let first = pending.first().expect("a source-owned note line");
    assert!(first.starts_with(CI_NOTE_PREFIX), "{first}");
    assert!(first.contains("1/5"), "{first}");

    assert_eq!(rig.view_item("ci-failing").status, Status::Blocked);
    let failing = rig.note_lines("ci-failing");
    let first = failing.first().expect("a source-owned note line");
    assert!(first.contains("lint"), "the first failing check: {first}");
    assert!(
        !first.contains("unit"),
        "only the first failing check: {first}"
    );

    // Green marks the item done only when it was bound with `!green`.
    assert_eq!(
        rig.view_item("ci-green").status,
        Status::Todo,
        "plain green leaves the status alone"
    );
    assert_eq!(
        rig.note_lines("ci-green").first().map(String::as_str),
        Some("CI green")
    );
    assert_eq!(rig.view_item("ci-done").status, Status::Done);
}

#[test]
fn the_source_owns_only_the_first_note_line_and_the_rest_of_the_note_is_kept() {
    let rig = Rig::standard();
    rig.reg
        .apply(
            WRITER,
            WRITER_SESSION,
            &[Op::Upsert(Upsert {
                id: Some("job".into()),
                note: Some("my own note".into()),
                ..Default::default()
            })],
            &writer(),
        )
        .expect("the agent writes a note");

    rig.mother("JOB1", "running");
    let running = rig.note_lines("job");
    assert_eq!(running.len(), 2, "{running:?}");
    assert!(running[0].starts_with(MOTHER_NOTE_PREFIX), "{running:?}");
    assert_eq!(running[1], "my own note");

    rig.advance(5);
    rig.mother("JOB1", "awaiting");
    let awaiting = rig.note_lines("job");
    assert_eq!(
        awaiting.len(),
        2,
        "the source line is replaced, not added to: {awaiting:?}"
    );
    assert_ne!(awaiting[0], running[0]);
    assert_eq!(awaiting[1], "my own note");

    rig.advance(61);
    rig.hub.tick();
    let file = rig.file_text();
    assert!(file.contains("my own note"), "{file}");
}

#[test]
fn the_pr_link_is_added_once_and_stays_as_the_job_moves_on() {
    let rig = Rig::standard();
    let with_pr = |state: &str| {
        rig.hub.apply_mother(
            &[job_with("JOB1", state, json!({"pr_url": PR_URL}))],
            Some(rig.now()),
        )
    };

    with_pr("running");
    rig.hub.tick();
    assert!(rig.file_text().contains(PR_URL), "the link is in the file");

    rig.advance(5);
    with_pr("succeeded");
    let links = rig.view_item("job").links;
    assert_eq!(
        links.iter().filter(|l| l.text == "PR #253").count(),
        1,
        "{links:?}"
    );
}

// ---------------------------------------------------------------------------
// Deltas: a state change reaches the agent once, attributed to the source (PRD 54)
// ---------------------------------------------------------------------------

#[test]
fn a_mother_state_change_reaches_the_next_delta_as_one_entry_attributed_to_the_source() {
    let rig = Rig::standard();

    rig.mother("JOB1", "running");
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source mother.job"));
    assert_eq!(changes[0]["id"], json!("job"));
    assert_eq!(changes[0]["status"], json!(["todo", "in-progress"]));

    rig.advance(5);
    rig.mother("JOB1", "succeeded");
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source mother.job"));
    assert_eq!(changes[0]["status"], json!(["in-progress", "done"]));

    // The same report again says nothing new.
    rig.advance(5);
    rig.mother("JOB1", "succeeded");
    assert!(rig.reader_changes().is_empty());

    // The file catching up later is not a second entry for the same change.
    rig.advance(120);
    rig.hub.tick();
    assert_eq!(rig.file_status("job"), Status::Done);
    assert!(rig.reader_changes().is_empty());
}

#[test]
fn a_ci_state_change_reaches_the_next_delta_as_one_entry_attributed_to_the_source() {
    let rig = Rig::standard();

    rig.ci(REPO, 253, &failing_checks());
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source pr.ci"));
    assert_eq!(changes[0]["id"], json!("ci"));
    assert_eq!(changes[0]["status"], json!(["todo", "blocked"]));

    rig.advance(5);
    rig.ci(REPO, 253, &pending_checks(0, 3));
    let changes = rig.reader_changes();
    assert_eq!(changes.len(), 1, "{changes:?}");
    assert_eq!(changes[0]["by"], json!("source pr.ci"));
    assert_eq!(changes[0]["status"], json!(["blocked", "in-progress"]));
}

#[test]
fn a_count_only_ci_change_updates_the_view_at_once_and_makes_no_delta_entry() {
    let rig = Rig::standard();

    rig.ci(REPO, 253, &pending_checks(1, 5));
    let first = rig.reader_changes();
    assert_eq!(first.len(), 1, "the state change is one entry: {first:?}");
    assert!(note_text(&rig.view_item("ci")).contains("1/5"));

    rig.advance(5);
    assert!(
        rig.ci(REPO, 253, &pending_checks(2, 5)),
        "the pane has something new to show"
    );
    assert!(
        note_text(&rig.view_item("ci")).contains("2/5"),
        "the view carries the new count at once"
    );
    assert_eq!(rig.view_item("ci").status, Status::InProgress);
    assert!(
        rig.reader_changes().is_empty(),
        "a count is not a change the agent needs"
    );
}

// ---------------------------------------------------------------------------
// The file is written at most once a minute per item, never for a count (PRD 53)
// ---------------------------------------------------------------------------

/// Ten simulated minutes in 5 s steps; `feed` reports the source's state for
/// the step and returns the status the item should show for it. The view must
/// follow every step at once.
fn ten_minutes(rig: &Rig, id: &str, mut feed: impl FnMut(&Rig, usize) -> Status) {
    rig.fs.reset();
    for step in 0..=120usize {
        if step > 0 {
            rig.advance(5);
        }
        let shown = feed(rig, step);
        rig.hub.tick();
        assert_eq!(
            rig.view_item(id).status,
            shown,
            "step {step}: the view follows the source at once"
        );
    }
}

fn assert_written_at_most_once_a_minute_and_caught_up(rig: &Rig, id: &str) {
    let writes = rig.fs.board_writes();
    for pair in writes.windows(2) {
        assert!(
            pair[1] - pair[0] >= Duration::seconds(60),
            "two board writes less than a minute apart: {writes:?}"
        );
    }
    assert!(
        writes.len() <= 11,
        "more than one write a minute for ten minutes: {writes:?}"
    );
    assert!(
        writes.len() >= 2,
        "the file does follow the source, throttled: {writes:?}"
    );

    // Once the interval has passed, the file says what the view says.
    rig.advance(61);
    rig.hub.tick();
    assert_eq!(rig.file_status(id), rig.view_item(id).status);
}

#[test]
fn a_mother_job_flipping_state_every_five_seconds_rewrites_the_file_at_most_once_a_minute() {
    let rig = Rig::standard();

    ten_minutes(&rig, "job", |rig, step| {
        if step % 2 == 0 {
            rig.mother("JOB1", "running");
            Status::InProgress
        } else {
            rig.mother("JOB1", "awaiting");
            Status::NeedsYou
        }
    });

    assert_written_at_most_once_a_minute_and_caught_up(&rig, "job");
}

#[test]
fn ci_alternating_states_and_counts_every_five_seconds_rewrites_the_file_at_most_once_a_minute() {
    let rig = Rig::standard();

    ten_minutes(&rig, "ci", |rig, step| match step % 4 {
        0 => {
            rig.ci(REPO, 253, &pending_checks((step / 4) % 4, 5));
            Status::InProgress
        }
        1 => {
            // Same state, a different count.
            rig.ci(REPO, 253, &pending_checks((step / 4) % 4 + 1, 5));
            Status::InProgress
        }
        2 => {
            rig.ci(
                REPO,
                253,
                &[
                    check("lint", CiState::Failure),
                    check("build", CiState::Success),
                ],
            );
            Status::Blocked
        }
        _ => {
            // Same state, a different failing check.
            rig.ci(
                REPO,
                253,
                &[
                    check("unit", CiState::Failure),
                    check("build", CiState::Success),
                ],
            );
            Status::Blocked
        }
    });

    assert_written_at_most_once_a_minute_and_caught_up(&rig, "ci");
}

#[test]
fn count_only_changes_never_write_the_file_and_never_reach_the_agent() {
    let rig = Rig::standard();

    ten_minutes(&rig, "ci", |rig, step| {
        let passed = step % 5;
        rig.ci(REPO, 253, &pending_checks(passed, 5));
        assert!(
            note_text(&rig.view_item("ci")).contains(&format!("{passed}/5")),
            "step {step}: the view shows the count at once"
        );
        Status::InProgress
    });

    assert_eq!(
        rig.fs.board_writes().len(),
        1,
        "only the one status change (todo to in progress) reaches the file"
    );
    assert_eq!(rig.file_status("ci"), Status::InProgress);
    assert_eq!(
        rig.reader_changes().len(),
        1,
        "the agent hears of the one state change, not of 120 counts"
    );
}

// ---------------------------------------------------------------------------
// Staleness (PRD 52)
// ---------------------------------------------------------------------------

#[test]
fn a_silent_source_leaves_the_item_badly_stale_with_its_last_value_until_a_new_observation() {
    let rig = Rig::standard();
    rig.reg.set_badly_stale_after(StdDuration::from_secs(300));
    assert!(rig.view_item("plain").bound.is_none());

    let t0 = rig.now();
    rig.mother("JOB1", "running");
    assert_eq!(
        rig.view_item("job").bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: Some(t0),
            badly_stale: false,
        })
    );

    // Silent, but not for long enough.
    rig.advance(299);
    rig.hub.tick();
    assert!(!rig.view_item("job").bound.unwrap().badly_stale);

    // Silent for too long: the value stays, and the view says as of when.
    rig.advance(2);
    assert!(rig.hub.tick(), "the staleness flip is a view change");
    let stale = rig.view_item("job");
    assert_eq!(
        stale.bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: Some(t0),
            badly_stale: true,
        })
    );
    assert_eq!(stale.status, Status::InProgress, "the last value is kept");

    // A feed republishing an old observation is not a new observation.
    rig.hub.apply_mother(&[job("JOB1", "running")], Some(t0));
    assert!(rig.view_item("job").bound.unwrap().badly_stale);

    // A new observation clears it.
    let t1 = rig.now();
    rig.mother("JOB1", "running");
    assert_eq!(
        rig.view_item("job").bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: Some(t1),
            badly_stale: false,
        })
    );
}

#[test]
fn an_item_whose_source_never_reports_becomes_badly_stale_without_an_as_of() {
    let rig = Rig::standard();
    rig.reg.set_badly_stale_after(StdDuration::from_secs(300));

    assert_eq!(
        rig.view_item("job").bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: None,
            badly_stale: false,
        })
    );
    assert!(
        !rig.hub.apply_mother(&[], None),
        "a feed that has never delivered applies nothing"
    );

    rig.advance(301);
    assert!(rig.hub.tick());
    let job = rig.view_item("job");
    assert_eq!(
        job.bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: None,
            badly_stale: true,
        })
    );
    assert_eq!(job.status, Status::Todo);
}

// ---------------------------------------------------------------------------
// Binding through the agent's upsert
// ---------------------------------------------------------------------------

#[test]
fn an_unknown_or_malformed_bind_is_invalid_args_and_changes_nothing() {
    let rig = Rig::with_items(&[("plain", None)]);
    let before = rig.file_text();

    for bad in [
        "sentry/PORTAL-1F2",
        "cloudwatch/x",
        "garbage",
        "mother.job/",
        "mother.job/has space",
        "pr.ci/o/r",
        "pr.ci/o/r#0",
        "pr.ci/owner/..#1",
        "pr.ci/owner/.#1",
        "pr.ci/./x#1",
    ] {
        let err = rig.bind("plain", bad).expect_err(bad);
        assert!(
            matches!(err, TrackerError::InvalidArgs { .. }),
            "{bad:?}: {err:?}"
        );
        assert_eq!(err.code(), "invalid_args");
        assert_eq!(rig.file_text(), before, "{bad:?} wrote something");
        assert!(rig.live().is_empty(), "{bad:?} bound something");
    }

    // A bad bind refuses the whole batch, including its good ops.
    let err = rig
        .reg
        .apply(
            WRITER,
            WRITER_SESSION,
            &[
                Op::Upsert(Upsert {
                    id: Some("fresh".into()),
                    section: Some("now".into()),
                    text: Some("Fresh".into()),
                    ..Default::default()
                }),
                Op::Upsert(Upsert {
                    id: Some("plain".into()),
                    bind: Some("sentry/PORTAL-1F2".into()),
                    ..Default::default()
                }),
            ],
            &writer(),
        )
        .expect_err("the batch is refused");
    assert!(matches!(err, TrackerError::InvalidArgs { .. }), "{err:?}");
    assert_eq!(rig.file_text(), before);
}

#[test]
fn a_valid_bind_is_written_into_the_marker_and_survives_a_restart() {
    let rig = Rig::with_items(&[("plain", None)]);

    rig.bind("plain", "mother.job/JOB-9")
        .expect("a Mother bind");
    assert!(
        rig.file_text().contains("bind:mother.job/JOB-9"),
        "{}",
        rig.file_text()
    );
    assert_eq!(
        rig.live(),
        vec![(
            "plain".to_string(),
            Binding::MotherJob {
                job_id: "JOB-9".into()
            }
        )]
    );

    // Rebinding replaces the source.
    rig.bind("plain", " pr.ci/Carefeed/admin-portal#254!green ")
        .expect("a PR CI bind");
    let file = rig.file_text();
    assert!(
        file.contains("bind:pr.ci/Carefeed/admin-portal#254!green"),
        "{file}"
    );
    assert!(!file.contains("bind:mother.job"), "{file}");
    let expected = vec![(
        "plain".to_string(),
        Binding::PrCi {
            repo: REPO.into(),
            number: 254,
            done_when_green: true,
        },
    )];
    assert_eq!(rig.live(), expected);
    assert_eq!(
        rig.view_item("plain").bound.map(|b| b.source),
        Some("pr.ci".to_string())
    );

    // The binding is in the file, so a restarted daemon still has it.
    let restarted = rig.restart();
    let live: Vec<(String, Binding)> = restarted
        .live_bindings()
        .into_iter()
        .map(|l| (l.item_id, l.binding))
        .collect();
    assert_eq!(live, expected);
}

#[test]
fn an_empty_bind_unbinds_the_item() {
    let rig = Rig::standard();
    rig.mother("JOB1", "running");

    rig.bind("job", "").expect("unbind");

    assert!(!rig.file_text().contains("bind:mother.job"));
    assert!(rig.live().iter().all(|(id, _)| id != "job"));
    assert!(rig.view_item("job").bound.is_none());

    // No longer live: the source's changes are not applied to it.
    rig.advance(5);
    assert!(!rig.mother("JOB1", "awaiting"));
    assert_ne!(rig.view_item("job").status, Status::NeedsYou);
}

#[test]
fn a_bind_a_human_wrote_with_an_unknown_source_is_ignored_not_live() {
    let rig = Rig::with_items(&[("plain", None)]);
    let before = rig.file_text();
    let marker = "<!-- #plain ";
    let after = before
        .split('\n')
        .map(|l| {
            if l.contains(marker) {
                l.replacen(" -->", " bind:sentry/PORTAL-1F2 -->", 1)
            } else {
                l.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert_ne!(before, after);
    std::fs::write(&rig.path, after).unwrap();
    rig.reg.ingest_file_change(&rig.path);

    assert!(rig.live().is_empty());
    assert!(rig.view_item("plain").bound.is_none());
    assert!(!rig
        .hub
        .apply_mother(&[job("PORTAL-1F2", "running")], Some(rig.now())));
}

// ---------------------------------------------------------------------------
// A person's edit wins until the source's next state change
// ---------------------------------------------------------------------------

/// A bound job item with a status in the file (`in progress`) that the view
/// has already moved past (`needs you`): the throttle is holding the file back.
fn rig_with_a_pending_file_write() -> Rig {
    let rig = Rig::standard();
    rig.mother("JOB1", "running");
    rig.hub.tick();
    assert_eq!(rig.file_status("job"), Status::InProgress);

    rig.advance(5);
    rig.mother("JOB1", "awaiting");
    assert_eq!(rig.view_item("job").status, Status::NeedsYou);
    assert_eq!(
        rig.file_status("job"),
        Status::InProgress,
        "the file waits out the minute"
    );
    rig
}

#[test]
fn an_edit_of_a_bound_items_status_in_the_file_is_not_reverted_until_the_source_changes_state() {
    let rig = rig_with_a_pending_file_write();

    rig.external_status("job", "in progress", "done");
    assert_eq!(rig.view_item("job").status, Status::Done);

    // The held-back write does not come and undo it.
    rig.advance(120);
    rig.hub.tick();
    assert_eq!(rig.file_status("job"), Status::Done);
    assert_eq!(rig.view_item("job").status, Status::Done);

    // The source repeating itself does not either.
    rig.mother("JOB1", "awaiting");
    assert_eq!(rig.view_item("job").status, Status::Done);

    // Its next state change does take over.
    rig.advance(5);
    rig.mother("JOB1", "running");
    assert_eq!(rig.view_item("job").status, Status::InProgress);
    let changes = rig.reader_changes();
    assert_eq!(
        changes.last().map(|c| &c["by"]),
        Some(&json!("source mother.job")),
        "{changes:?}"
    );

    rig.advance(61);
    rig.hub.tick();
    assert_eq!(rig.file_status("job"), Status::InProgress);
}

#[test]
fn an_edit_to_another_item_makes_no_file_change_for_a_bound_item_with_a_write_pending() {
    let rig = rig_with_a_pending_file_write();
    rig.reader_changes();

    rig.external_status("plain", "todo", "done");

    let changes = rig.reader_changes();
    assert!(!changes.is_empty(), "the edit is noticed");
    for change in &changes {
        assert_eq!(change["by"], json!(FILE_LABEL), "{change}");
        assert_eq!(
            change["id"],
            json!("plain"),
            "only the edited item: {change}"
        );
    }
    assert_eq!(
        rig.view_item("job").status,
        Status::NeedsYou,
        "the source's state is still shown"
    );

    // The held-back write still happens, and keeps the other edit.
    rig.advance(61);
    rig.hub.tick();
    assert_eq!(rig.file_status("job"), Status::NeedsYou);
    assert_eq!(rig.file_status("plain"), Status::Done);
}

// ---------------------------------------------------------------------------
// The feeds' way in: BindingHub
// ---------------------------------------------------------------------------

#[test]
fn a_mother_list_with_no_observation_time_applies_nothing() {
    let rig = Rig::standard();
    let before = rig.view_item("job");

    assert!(!rig.hub.apply_mother(&[job("JOB1", "running")], None));

    assert_eq!(rig.view_item("job"), before);
    assert_eq!(rig.view_item("job").status, Status::Todo);
    assert!(rig.reader_changes().is_empty());
}

#[test]
fn jobs_nobody_is_bound_to_and_unchanged_reports_change_no_view() {
    let rig = Rig::standard();

    assert!(!rig
        .hub
        .apply_mother(&[job("NOT-BOUND", "running")], Some(rig.now())));

    assert!(rig.mother("JOB1", "running"));
    rig.advance(5);
    assert!(
        !rig.mother("JOB1", "running"),
        "an identical report is no visible change"
    );
}

#[test]
fn bound_prs_lists_each_pr_once_across_boards() {
    let rig = Rig::standard();
    rig.open_other_board(&[
        ("again", Some("pr.ci/Carefeed/admin-portal#253!green")),
        ("elsewhere", Some("pr.ci/Carefeed/other#7")),
        ("a-job", Some("mother.job/JOB-A")),
    ]);

    let mut prs = rig.hub.bound_prs();
    prs.sort();
    assert_eq!(
        prs,
        vec![
            (REPO.to_string(), 253),
            (REPO.to_string(), 254),
            ("Carefeed/other".to_string(), 7),
        ]
    );
}

#[test]
fn a_ci_report_reaches_every_board_bound_to_that_pr_and_matches_the_repo_case_insensitively() {
    let rig = Rig::standard();
    rig.open_other_board(&[("again", Some("pr.ci/Carefeed/admin-portal#253"))]);

    assert!(rig.hub.apply_ci(
        "carefeed/ADMIN-PORTAL",
        253,
        &CiObservation::from_checks(&failing_checks()),
        rig.now()
    ));

    assert_eq!(rig.view_item("ci").status, Status::Blocked);
    let other = rig.reg.board_view(OTHER).expect("the other board's view");
    assert_eq!(
        item(&other, "again").expect("the item").status,
        Status::Blocked
    );
    assert_eq!(
        rig.view_item("green").status,
        Status::Todo,
        "another PR is not touched"
    );

    assert!(!rig.hub.apply_ci(
        REPO,
        999,
        &CiObservation::from_checks(&failing_checks()),
        rig.now()
    ));
}

#[test]
fn ci_observations_roll_up_failure_over_pending_over_success() {
    let mixed = vec![
        check("build", CiState::Success),
        check("lint", CiState::Failure),
        check("e2e", CiState::Pending),
        check("unit", CiState::Failure),
    ];
    let obs = CiObservation::from_checks(&mixed);
    assert_eq!(obs.state, CiState::Failure);
    assert_eq!(obs.failing.as_deref(), Some("lint"));
    assert_eq!(obs.passed, 1);
    assert_eq!(obs.total, 4);

    let obs = CiObservation::from_checks(&pending_checks(2, 5));
    assert_eq!(obs.state, CiState::Pending);
    assert_eq!((obs.passed, obs.total), (2, 5));
    assert_eq!(obs.failing, None);

    let obs = CiObservation::from_checks(&green_checks());
    assert_eq!(obs.state, CiState::Success);

    assert_eq!(CiObservation::from_checks(&[]).state, CiState::Unknown);
}

// ---------------------------------------------------------------------------
// The pane (PRD 51: no agent call, the pane updates)
// ---------------------------------------------------------------------------

#[test]
fn a_source_change_is_broadcast_to_the_pane_with_the_items_freshness() {
    let rig = Rig::standard();
    let (tx, mut rx) = broadcast::channel(64);
    rig.reg.flush(&tx);
    while rx.try_recv().is_ok() {}

    let observed = rig.now();
    assert!(rig.mother("JOB1", "running"));
    rig.reg.flush(&tx);

    let mut board = None;
    while let Ok(msg) = rx.try_recv() {
        match msg {
            ServerMsg::TrackerBoard {
                tag,
                board: Some(b),
            } if tag == READER => board = Some(b),
            _ => {}
        }
    }
    let board = board.expect("a tracker_board frame for the reader's focus");
    let job = item(&board, "job").expect("the item");
    assert_eq!(job.status, Status::InProgress);
    assert_eq!(
        job.bound,
        Some(BoundView {
            source: "mother.job".into(),
            as_of: Some(observed),
            badly_stale: false,
        })
    );
}

#[test]
fn the_default_staleness_threshold_is_five_minutes() {
    // No `set_badly_stale_after`: the registry's own default applies.
    let rig = Rig::standard();
    rig.mother("JOB1", "running");
    rig.advance(299);
    rig.hub.tick();
    assert!(!rig.view_item("job").bound.unwrap().badly_stale);
    rig.advance(2);
    rig.hub.tick();
    assert!(rig.view_item("job").bound.unwrap().badly_stale);
}
