//! Zero lost edits (PRD 42, slice T3a): four writers (two agents, two pane
//! windows, and anything saving the file) interleave on one board, and no
//! value any of them wrote is silently lost.
//!
//! A seeded generator produces 400 interleavings of 10-30 steps (a quarter of
//! them, "hot" ones, run 40-80 steps hammering one item's note so a field's cap
//! of five conflicts is reached): agent ops (some with a stale read cursor,
//! some from a session that has never read or opened the board, as a restarted
//! or resumed agent is), pane ops from either of two windows (each with its own
//! view of the board, stale until it looks again), file saves from the current
//! bytes or from a stale copy taken 1-40 steps earlier, saves injected between
//! the daemon's read and its commit, and fake-clock advances. After each
//! interleaving an *oracle* checks every value any writer wrote. For each write
//! E (who, item, field, value) at least one of these holds:
//!
//! 1. E's value is in the final file;
//! 2. E's value is a losing value of a live conflict (or the item's bytes at
//!    removal, kept by a `removed` conflict, hold it);
//! 3. E was superseded knowingly: a later write to the same field (or a
//!    removal of the item) by the same writer (one agent session, one pane
//!    window), or by a writer whose base (pane view version, agent read
//!    cursor, the copy a file save was made from) included E;
//! 4. a cap dropped it and the pane told the user so (`dropped_conflicts` on
//!    the item), the one loss the product accepts and says out loud.
//!
//! The writes are derived from what the file actually says before and after
//! each step, so the oracle shares nothing with the daemon's conflict rule.
//! Also asserted: bytes outside the changed items are identical after every
//! agent or pane write; every conflict has an id that is unique and never
//! changes what it names; whenever a cap drops a value the view says so, and
//! says so until the item's conflicts are settled.
//!
//! A stale file save is a verbatim old copy (what an editor's old buffer
//! does); a deliberate file edit is made from the current bytes. (A value
//! typed over an agent's in a stale buffer, with nothing else different, is
//! indistinguishable from typing it over a fresh one, so it is not generated.)
//!
//! The pane's `resolve_conflict` is what a real pane sends: the `conflict_id`
//! of a conflict **its own last view showed** (either side), never worked out
//! from the daemon's state, so a conflict a cap dropped or the other window
//! settled meanwhile is asked for anyway and must be refused. A refused batch
//! must leave the file, the version and the conflicts untouched. A conflict
//! the pane settled with "keep current" is excused (it saw it); any other
//! conflict that disappears is a lost edit. `clear_badge` (alone and after a
//! write in the same batch), a restructure and its undo, and an agent
//! re-opening the board are generated too.
//!
//! Also generated: a state-loss restart in the middle of a run (a new registry
//! over the same files with `state.json` gone: versions and counters start
//! over, every window's view and every conflict id it holds is from before);
//! the oracle keeps what it knows of the values still in the file at the
//! restart, and right after it a window with the old view overwrites one of
//! them: the new log knows nothing of that value, so it must be kept (the view
//! carries the board's epoch, as the Mac's does, and the window sends it back);
//! a batch that settles one conflict twice, or puts back two losing values of
//! one field, which must be refused; any `resolve_conflict` naming an id the
//! board no longer keeps, which must be refused; and in two runs, a
//! stale window (its view older than the log reaches) that changes 50 items at
//! once next to one real conflict: the real one must outlive the guesses the
//! stale view makes.
//!
//! Failing interleavings print their seed and every step (a panic in one is
//! reported with its seed too). `TRACKER_FUZZ_SEED` reruns one seed;
//! `TRACKER_FUZZ_COUNT` runs more (from `TRACKER_FUZZ_START`, default 0, so
//! separate runs cover different seeds). Hermetic: `FakeClock`, temp dirs, no network.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::Duration as ChronoDuration;
use nostromo::ipc::protocol::{ConflictKeep, TrackerPaneOp};
use nostromo::tracker::view::ViewNode;
use nostromo::tracker::watch::{BoardFs, FileSignature, RealBoardFs};
use nostromo::tracker::{
    apply_to_file, parse, Author, Clock, FakeClock, Op, OpenArgs, ReadOutcome, RegistryParts,
    Stamp, TrackerRegistry, Upsert,
};
use serde_json::Value;
use tempfile::TempDir;

const TAG: [&str; 2] = ["cody-a", "cody-b"];
const SESS: [&str; 2] = ["sess-a", "sess-b"];
/// The two pane windows' connection ids (the daemon assigns them in life).
const WINDOW: [&str; 2] = ["win-a", "win-b"];
const INTERLEAVINGS: u64 = 400;
/// Items a stale window changes at once.
const BULK: usize = 50;
const SEED_BASE: u64 = 0x7a11_0000;
const FIELDS: [&str; 4] = ["text", "status", "owner", "note"];
const STATUSES: [&str; 5] = ["todo", "in-progress", "blocked", "needs-you", "done"];

// ---------------------------------------------------------------------------
// A deterministic generator
// ---------------------------------------------------------------------------

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n.max(1) as u64) as usize
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }

    /// A random element. Callers never pick from an empty list (a step with
    /// no item to act on does nothing instead).
    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        assert!(!items.is_empty(), "pick from an empty list");
        &items[self.below(items.len())]
    }
}

// ---------------------------------------------------------------------------
// The file system seam: a save between the daemon's read and its commit
// ---------------------------------------------------------------------------

type Hook = Box<dyn FnOnce(&Path) + Send>;

struct HookFs {
    hook: Mutex<Option<Hook>>,
}

impl BoardFs for HookFs {
    fn read(&self, path: &Path) -> std::io::Result<Vec<u8>> {
        RealBoardFs.read(path)
    }
    fn write_atomic(&self, path: &Path, bytes: &[u8]) -> std::io::Result<()> {
        RealBoardFs.write_atomic(path, bytes)
    }
    fn signature(&self, path: &Path) -> Option<FileSignature> {
        RealBoardFs.signature(path)
    }
    fn create_dir_all(&self, dir: &Path) -> std::io::Result<()> {
        RealBoardFs.create_dir_all(dir)
    }
    fn before_commit(&self, path: &Path) {
        let hook = self.hook.lock().unwrap().take();
        if let Some(hook) = hook {
            hook(path);
        }
    }
    fn remove_stale_temps(&self, dir: &Path) {
        RealBoardFs.remove_stale_temps(dir)
    }
}

// ---------------------------------------------------------------------------
// What the file says, and who wrote what
// ---------------------------------------------------------------------------

type Fields = BTreeMap<&'static str, Option<String>>;
type Items = BTreeMap<String, Fields>;

fn items_of(bytes: &[u8]) -> Items {
    let parsed = parse(bytes).expect("the board file parses");
    parsed
        .board
        .items
        .iter()
        .map(|i| {
            let mut f = Fields::new();
            f.insert("text", Some(i.text.clone()));
            f.insert("status", Some(i.status.wire().to_string()));
            f.insert("owner", i.owner.clone());
            f.insert("note", i.note.clone());
            (i.id.clone(), f)
        })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Who {
    /// An agent's session: (agent, which session of it).
    Agent(usize, u32),
    /// A pane window.
    Pane(usize),
    File,
}

#[derive(Debug, Clone)]
struct Write {
    who: Who,
    item: String,
    /// A field, or `removed`.
    field: &'static str,
    value: Option<String>,
    /// The version the writer had seen.
    base: u64,
    /// The version once the write was in.
    applied: u64,
    step: usize,
    /// The writer's base is from this run of the daemon: an agent that opened
    /// or read the board since the restart, a window that looked since. Only
    /// such a writer has seen a value written before the restart.
    fresh: bool,
    /// Written before a state-loss restart (still in the file at the restart,
    /// which the new log knows nothing about).
    pre_restart: bool,
}

/// The writes `who` made, from what the file said before and after.
fn writes_between(
    before: &Items,
    after: &Items,
    who: Who,
    base: u64,
    applied: u64,
    step: usize,
) -> Vec<Write> {
    let mut out = Vec::new();
    let mut push = |item: &str, field: &'static str, value: Option<String>| {
        out.push(Write {
            who,
            item: item.to_string(),
            field,
            value,
            base,
            applied,
            step,
            fresh: true,
            pre_restart: false,
        });
    };
    for (id, fields) in after {
        match before.get(id) {
            None => {
                for field in FIELDS {
                    let value = &fields[field];
                    let default = match field {
                        "status" => value.as_deref() == Some("todo"),
                        "owner" | "note" => value.is_none(),
                        _ => false,
                    };
                    if !default {
                        push(id, field, value.clone());
                    }
                }
            }
            Some(old) => {
                for field in FIELDS {
                    if old[field] != fields[field] {
                        push(id, field, fields[field].clone());
                    }
                }
            }
        }
    }
    for id in before.keys().filter(|id| !after.contains_key(*id)) {
        push(id, "removed", None);
    }
    out
}

fn value_of(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string)
}

// ---------------------------------------------------------------------------
// One interleaving
// ---------------------------------------------------------------------------

/// One conflict as a pane window's view showed it: all a real pane has.
#[derive(Debug, Clone)]
struct Shown {
    item: String,
    /// A field, or `removed`.
    field: String,
    conflict_id: String,
    /// The losing value as the view shows it (empty for no value); `None` for
    /// a removed item.
    losing: Option<String>,
    /// A removed item's markdown.
    source: Option<String>,
}

impl Shown {
    /// The oracle's value for what the view shows as `losing` (the view shows
    /// an absent owner or note as an empty string).
    fn value(&self) -> Option<String> {
        match (self.field.as_str(), self.losing.as_deref()) {
            ("owner" | "note", Some("")) => None,
            (_, losing) => losing.map(str::to_string),
        }
    }
}

/// What one pane window last showed its user.
#[derive(Debug, Clone, Default)]
struct PaneView {
    version: u64,
    /// The board's epoch the view carried (a real pane sends it back).
    epoch: String,
    shown: Vec<Shown>,
}

struct World {
    _tmp: TempDir,
    path: PathBuf,
    clock: Arc<FakeClock>,
    reg: Arc<TrackerRegistry>,
    fs: Arc<HookFs>,
    rng: Rng,
    steps: Vec<String>,
    writes: Vec<Write>,
    /// The file's bytes and version after every step (stale file copies come from here).
    history: Vec<(u64, Vec<u8>)>,
    /// Each agent's current session, and which one it is (0: the first).
    session: [String; 2],
    generation: [u32; 2],
    /// What each agent's session has read through (`None`: it never read or opened).
    cursor: [Option<u64>; 2],
    /// What each pane window last showed.
    views: [PaneView; 2],
    /// Items the pane removed, by id: the exact markdown and where it sat.
    removed: Vec<(String, String, String)>,
    counter: usize,
    /// Conflicts a pane window settled by keeping the current value, having seen them.
    excused: Vec<Shown>,
    /// Removed items put back under a new id (their own was taken again): the
    /// removed id and the markdown that came back, byte for byte, under the
    /// new one. What those items held is kept, not lost.
    restored_elsewhere: Vec<(String, String)>,
    /// What a restructure replaced, to undo: (id, text, note).
    restructured: Vec<(String, String, Option<String>)>,
    open_args: OpenArgs,
    /// Injected saves, recorded when they run.
    injected: Arc<Mutex<Vec<Write>>>,
    failures: Vec<String>,
    /// A "hot" run hammers this item's note.
    hot: Option<String>,
    /// Items the view said a cap dropped something of, and the ones it said it
    /// of after the last step.
    marked: BTreeSet<String>,
    marked_now: BTreeSet<String>,
    dropped_seen: u32,
    /// Every conflict's (item, field, losing value) by id after the last step.
    named: BTreeMap<String, (String, String, String)>,
    /// Every id any conflict ever had, and what it named: an id is never
    /// reused, across a restart either.
    ever_named: BTreeMap<String, (String, String, String)>,
    state_dir: PathBuf,
    home_dir: PathBuf,
    /// The step at which the state is lost and the daemon restarts, if any.
    restart_at: Option<usize>,
    /// A window whose view is from before the restart: the oracle counts it as
    /// having seen nothing, though the daemon is sent its stale version.
    view_stale: [bool; 2],
    /// The run starts with a log that no longer reaches window 1's view.
    gap_run: bool,
    /// Conflict ids a pane batch settled this step.
    settled_now: Vec<String>,
    /// Items whose `removed` conflict a cap dropped: the item is not on the
    /// board, so the pane has no `dropped_conflicts` to show for it. The
    /// cap's one silent loss; accepted here, and listed in the PR.
    cap_dropped_removed: BTreeSet<String>,
    /// The items on the board after the last step.
    prev_items: BTreeSet<String>,
    /// The cap's drop count at the last step.
    cap_drops: u32,
    /// The conflicts after the last step: (id, item, field, guess, version).
    prev_list: Vec<(String, String, String, bool, u64)>,
}

fn agent(i: usize, session: &str) -> Author {
    Author::Agent {
        focus: TAG[i].into(),
        session_id: session.into(),
        name: TAG[i].into(),
    }
}

fn without_items(text: &str, ids: &[String]) -> String {
    let mut text = text.to_string();
    for id in ids {
        if let Some(span) = parse(text.as_bytes()).ok().and_then(|p| p.item_span(id)) {
            text.replace_range(span, "");
        }
    }
    text
}

impl World {
    fn new(seed: u64) -> World {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let (repo, home, state) = (base.join("repo"), base.join("home"), base.join("state"));
        let (state_dir, home_dir) = (state.clone(), home.clone());
        for dir in [&repo, &home] {
            std::fs::create_dir_all(dir).unwrap();
        }
        let clock = Arc::new(FakeClock::at_secs(1_760_540_000));
        let fs = Arc::new(HookFs {
            hook: Mutex::new(None),
        });
        let mut parts = RegistryParts::hermetic(state, home, clock.clone());
        parts.fs = fs.clone();
        let reg = Arc::new(TrackerRegistry::new(parts));
        let args = OpenArgs {
            topic: Some("fuzz".into()),
            cwd: repo,
            ..Default::default()
        };
        let path = reg.open(TAG[0], SESS[0], &args).unwrap().path;
        let args_kept = args.clone();
        reg.open(TAG[1], SESS[1], &args).unwrap();
        let seed_ops: Vec<Op> = (0..6)
            .map(|n| {
                Op::Upsert(Upsert {
                    id: Some(format!("item-{n}")),
                    section: Some(if n % 2 == 0 { "now" } else { "next" }.into()),
                    text: Some(format!("Seed item {n}")),
                    ..Default::default()
                })
            })
            .collect();
        reg.apply(TAG[0], SESS[0], &seed_ops, &agent(0, SESS[0]))
            .unwrap();
        let mut rng = Rng(seed);
        let hot = rng.chance(25).then(|| "item-1".to_string());
        let mut world = World {
            _tmp: tmp,
            path,
            clock,
            reg,
            fs,
            rng,
            steps: Vec::new(),
            writes: Vec::new(),
            history: Vec::new(),
            session: [SESS[0].to_string(), SESS[1].to_string()],
            generation: [0, 0],
            cursor: [None, None],
            views: [PaneView::default(), PaneView::default()],
            removed: Vec::new(),
            counter: 0,
            excused: Vec::new(),
            restored_elsewhere: Vec::new(),
            restructured: Vec::new(),
            open_args: args_kept,
            injected: Arc::new(Mutex::new(Vec::new())),
            failures: Vec::new(),
            hot,
            marked: BTreeSet::new(),
            marked_now: BTreeSet::new(),
            dropped_seen: 0,
            named: BTreeMap::new(),
            ever_named: BTreeMap::new(),
            state_dir: state_dir.clone(),
            home_dir: home_dir.clone(),
            restart_at: None,
            view_stale: [false; 2],
            gap_run: (seed - SEED_BASE).is_multiple_of(200),
            settled_now: Vec::new(),
            prev_list: Vec::new(),
            cap_dropped_removed: BTreeSet::new(),
            cap_drops: 0,
            prev_items: BTreeSet::new(),
        };
        for i in 0..2 {
            world.read(i);
            world.look(i);
        }
        if world.gap_run {
            world.roll_the_log_past_window_one();
        } else if world.rng.chance(20) {
            world.restart_at = Some(3 + world.rng.below(8));
        }
        world.steps.clear();
        world.snapshot();
        world
    }

    /// Window 1 keeps the view it has; 50 items are added and the log then
    /// rolls over (more than its 1,000 entries), so nothing logged says what
    /// those items held. Agents and window 0 read and look again.
    fn roll_the_log_past_window_one(&mut self) {
        let mut text = String::from_utf8(self.bytes()).unwrap();
        if !text.ends_with('\n') {
            text.push('\n');
        }
        let mut ops: Vec<Op> = Vec::new();
        for n in 0..BULK {
            ops.push(Op::Upsert(Upsert {
                id: Some(format!("bulk-{n}")),
                section: Some("next".into()),
                text: Some(format!("Bulk item {n}")),
                ..Default::default()
            }));
        }
        let bytes = apply_to_file(text.as_bytes(), &ops, &Author::File, self.stamp())
            .expect("the bulk items are added")
            .bytes;
        std::fs::write(&self.path, bytes).unwrap();
        self.reg.ingest_file_change(&self.path);
        for n in 0..1_010 {
            let ops = [Op::Upsert(Upsert {
                id: Some("item-5".into()),
                owner: Some(format!("roll-{n}")),
                ..Default::default()
            })];
            let bytes = apply_to_file(&self.bytes(), &ops, &Author::File, self.stamp())
                .expect("a scratch save")
                .bytes;
            std::fs::write(&self.path, bytes).unwrap();
            self.reg.ingest_file_change(&self.path);
        }
        for i in 0..2 {
            self.read(i);
        }
        self.look(0);
    }

    /// The daemon restarts with its state lost: a new registry over the same
    /// files, no `state.json`. Versions and counters start over; the windows
    /// keep the views they have and the agents are handed the board again.
    fn restart(&mut self) {
        let _ = std::fs::remove_dir_all(&self.state_dir);
        let mut parts = RegistryParts::hermetic(
            self.state_dir.clone(),
            self.home_dir.clone(),
            self.clock.clone(),
        );
        parts.fs = self.fs.clone();
        self.reg = Arc::new(TrackerRegistry::new(parts));
        for i in 0..2 {
            self.reg
                .open(TAG[i], &self.session[i], &self.open_args)
                .expect("re-open after the restart");
            self.cursor[i] = Some(self.version());
        }
        // What the daemon kept in memory is gone, and so are the conflicts it
        // held (and the premises that rested on them). What the oracle
        // remembers of the values still in the file is not: those are the old
        // values a stale window may now overwrite, and the new daemon's log
        // knows nothing about them.
        let in_file = items_of(&self.bytes());
        self.writes.retain(|e| {
            e.field != "removed" && in_file.get(&e.item).is_some_and(|f| f[e.field] == e.value)
        });
        for e in &mut self.writes {
            e.pre_restart = true;
        }
        self.excused.clear();
        self.restored_elsewhere.clear();
        self.history.clear();
        self.snapshot();
        self.marked.clear();
        self.marked_now.clear();
        self.dropped_seen = 0;
        self.named.clear();
        self.prev_list.clear();
        self.cap_dropped_removed.clear();
        self.cap_drops = 0;
        self.view_stale = [true; 2];
        self.steps
            .push("*** the daemon restarts with its state lost ***".to_string());
    }

    /// Right after a restart, a window still showing the old run's view
    /// overwrites a value somebody else wrote before it: the new log has no
    /// entry for that value (its field is "unlogged"), and the view's version
    /// is meaningless to the new log. The oracle counts the window to have seen
    /// nothing, so the value must be kept as a conflict. (Random steps hit this
    /// only now and then: this one makes every restart run do it.)
    fn stale_window_overwrites_an_old_value(&mut self, step: usize) {
        let Some((item, field)) = self
            .writes
            .iter()
            .filter(|e| e.pre_restart && !matches!(e.who, Who::Pane(_)))
            .find(|e| e.field == "note" || e.field == "status")
            .map(|e| (e.item.clone(), e.field))
        else {
            return;
        };
        let current = items_of(&self.bytes());
        let current = current[&item][field].clone().unwrap_or_default();
        let op = if field == "note" {
            TrackerPaneOp::Edit {
                id: item.clone(),
                title: None,
                text: None,
                body: Some(self.unique("probe-note-")),
            }
        } else {
            TrackerPaneOp::Status {
                id: item.clone(),
                status: if current == "blocked" {
                    "needs-you"
                } else {
                    "blocked"
                }
                .into(),
            }
        };
        let w = self.rng.below(2);
        let (before, base, epoch) = (
            self.bytes(),
            self.views[w].version,
            self.views[w].epoch.clone(),
        );
        let ops = vec![op];
        let r = self
            .reg
            .apply_pane_ops_in(TAG[0], WINDOW[w], base, Some(&epoch), &ops);
        self.steps.push(format!(
            "window {w} (old view v{base}) overwrites a value from before the restart: {ops:?} -> {}",
            r.is_ok()
        ));
        self.settle(Who::Pane(w), 0, &before, &[item], false, step);
    }

    fn version(&self) -> u64 {
        self.reg.board_view(TAG[0]).expect("a board").version
    }

    fn bytes(&self) -> Vec<u8> {
        std::fs::read(&self.path).unwrap()
    }

    fn snapshot(&mut self) {
        let entry = (self.version(), self.bytes());
        self.history.push(entry);
    }

    fn unique(&mut self, prefix: &str) -> String {
        self.counter += 1;
        format!("{prefix}{}", self.counter)
    }

    fn item_ids(&self) -> Vec<String> {
        items_of(&self.bytes()).into_keys().collect()
    }

    fn stale(&mut self) -> usize {
        let back = 1 + self.rng.below(40);
        self.history
            .len()
            .saturating_sub(back + 1)
            .min(self.history.len() - 1)
    }

    fn stamp(&self) -> Stamp {
        Stamp::utc(self.clock.now())
    }

    fn read(&mut self, i: usize) {
        let version = match self.reg.read(TAG[i], &self.session[i]).expect("read") {
            ReadOutcome::Full { version, .. } | ReadOutcome::Delta { version, .. } => version,
        };
        self.cursor[i] = Some(version);
        self.steps.push(format!(
            "agent {i} (session {}) reads (cursor {version})",
            self.generation[i]
        ));
    }

    /// The agent's session is replaced by one that has neither opened nor read
    /// the board (a restarted or resumed agent).
    fn new_session(&mut self, i: usize) {
        self.generation[i] += 1;
        self.session[i] = format!("{}-g{}", SESS[i], self.generation[i]);
        self.cursor[i] = None;
        self.steps.push(format!(
            "agent {i} starts session {} (has not read)",
            self.generation[i]
        ));
    }

    /// Pane window `w` shows its user the board now: all it will go on until
    /// it looks again.
    fn look(&mut self, w: usize) {
        let view = self.reg.board_view(TAG[0]).expect("a board");
        let mut shown = Vec::new();
        for node in &view.nodes {
            if let ViewNode::Item(item) = node {
                for c in &item.conflicts {
                    shown.push(Shown {
                        item: item.id.clone(),
                        field: c.field.clone(),
                        conflict_id: c.conflict_id.clone(),
                        losing: Some(c.losing.clone()),
                        source: None,
                    });
                }
            }
        }
        for r in &view.removed_conflicts {
            shown.push(Shown {
                item: r.item_id.clone(),
                field: "removed".to_string(),
                conflict_id: r.conflict_id.clone(),
                losing: None,
                source: Some(r.source.clone()),
            });
        }
        self.steps.push(format!(
            "window {w} looks (view v{}, {} conflicts shown)",
            view.version,
            shown.len()
        ));
        self.views[w] = PaneView {
            version: view.version,
            epoch: view.epoch.clone(),
            shown,
        };
        self.view_stale[w] = false;
    }

    /// Arms a save to happen between the daemon's read and its commit.
    fn maybe_inject(&mut self) -> bool {
        if !self.rng.chance(15) {
            return false;
        }
        let ids = self.item_ids();
        if ids.is_empty() {
            return false;
        }
        let id = self.rng.pick(&ids).clone();
        let owner = self.unique("inj-owner-");
        let (injected, base, stamp) = (self.injected.clone(), self.version(), self.stamp());
        self.steps.push(format!(
            "  (a file save of owner of {id} is injected mid-write)"
        ));
        *self.fs.hook.lock().unwrap() = Some(Box::new(move |path: &Path| {
            let before = std::fs::read(path).unwrap();
            let ops = [Op::Upsert(Upsert {
                id: Some(id),
                owner: Some(owner),
                ..Default::default()
            })];
            if let Ok(applied) = apply_to_file(&before, &ops, &Author::File, stamp) {
                std::fs::write(path, &applied.bytes).unwrap();
                injected.lock().unwrap().extend(writes_between(
                    &items_of(&before),
                    &items_of(&applied.bytes),
                    Who::File,
                    base,
                    0,
                    0,
                ));
            }
        }));
        true
    }

    /// Records what changed between `before` and the file now as `who`'s
    /// writes, and the injected ones; checks the bytes outside `touched`.
    fn settle(
        &mut self,
        who: Who,
        base: u64,
        before: &[u8],
        touched: &[String],
        injected: bool,
        step: usize,
    ) {
        let applied = self.version();
        let after = self.bytes();
        let mut mid = std::mem::take(&mut *self.injected.lock().unwrap());
        let mut between = before.to_vec();
        for w in &mut mid {
            w.applied = applied;
            w.step = step;
        }
        if !mid.is_empty() {
            between = self.injected_bytes(&mid, before);
        }
        // Whether the writer's base is from this run (see `Write::fresh`).
        let fresh = match who {
            // Every agent was handed the board at the restart. (A session that
            // starts later and never reads has seen nothing, and the daemon
            // has no log of what the file held at the restart to tell it: a
            // known gap, not generated as a loss here; see the PR.)
            Who::Agent(..) => true,
            Who::Pane(w) => !self.view_stale[w],
            Who::File => true,
        };
        self.writes.extend(mid);
        let mut ids: Vec<String> = touched.to_vec();
        let new_writes = writes_between(
            &items_of(&between),
            &items_of(&after),
            who,
            base,
            applied,
            step,
        );
        ids.extend(new_writes.iter().map(|w| w.item.clone()));
        self.writes
            .extend(new_writes.into_iter().map(|w| Write { fresh, ..w }));
        if !injected {
            let (b, a) = (
                String::from_utf8(before.to_vec()).unwrap(),
                String::from_utf8(after).unwrap(),
            );
            if without_items(&b, &ids) != without_items(&a, &ids) {
                self.failures.push(format!(
                    "step {step}: bytes outside the changed items {ids:?} changed"
                ));
            }
        }
    }

    /// The file as the injected save left it. The save is the only change
    /// the hook made, so re-deriving it from the log of writes is enough:
    /// the bytes the daemon then built on are `before` plus those writes.
    fn injected_bytes(&self, _mid: &[Write], before: &[u8]) -> Vec<u8> {
        // The injected save's field values are applied to `before` to give
        // the board the daemon's own write then stood on.
        let mut ops = Vec::new();
        for w in _mid {
            if w.field == "owner" {
                ops.push(Op::Upsert(Upsert {
                    id: Some(w.item.clone()),
                    owner: Some(w.value.clone().unwrap_or_default()),
                    ..Default::default()
                }));
            }
        }
        match apply_to_file(before, &ops, &Author::File, self.stamp()) {
            Ok(applied) => applied.bytes,
            Err(_) => before.to_vec(),
        }
    }

    /// An agent opens the board again: it reads nothing, so its cursor (what
    /// it has seen) does not move; a session that never opened it is handed
    /// the board, which counts as a read.
    fn reopen(&mut self, i: usize) {
        self.reg
            .open(TAG[i], &self.session[i], &self.open_args)
            .expect("re-open");
        if self.cursor[i].is_none() {
            self.cursor[i] = Some(self.version());
        }
        self.steps.push(format!(
            "agent {i} (session {}) opens the board (cursor {:?})",
            self.generation[i], self.cursor[i]
        ));
    }

    fn agent_step(&mut self, step: usize) {
        let i = self.rng.below(2);
        if self.rng.chance(12) {
            self.new_session(i);
        }
        if self.rng.chance(10) {
            self.reopen(i);
            return;
        }
        let ids = self.item_ids();
        if ids.is_empty() {
            self.steps.push(format!(
                "agent {i} has nothing to act on (the board has no items)"
            ));
            return;
        }
        let mut touched = Vec::new();
        let hot = self.hot.clone().filter(|h| ids.contains(h));
        let op = match (&hot, self.rng.chance(60)) {
            (Some(id), true) => {
                touched.push(id.clone());
                let note = self.unique("hot-note-");
                Op::Upsert(Upsert {
                    id: Some(id.clone()),
                    note: Some(note),
                    ..Default::default()
                })
            }
            _ => match self.rng.below(7) {
                0 => {
                    let id = self.rng.pick(&ids).clone();
                    touched.push(id.clone());
                    let s = *self.rng.pick(&STATUSES);
                    Op::Status {
                        id,
                        status: if s == "done" { "blocked" } else { s }.into(),
                    }
                }
                1 | 2 => {
                    let id = self.rng.pick(&ids).clone();
                    touched.push(id.clone());
                    let owner = self.unique("owner-");
                    Op::Upsert(Upsert {
                        id: Some(id),
                        owner: Some(owner),
                        ..Default::default()
                    })
                }
                3 => {
                    let id = self.rng.pick(&ids).clone();
                    touched.push(id.clone());
                    let note = self.unique("note-");
                    Op::Upsert(Upsert {
                        id: Some(id),
                        note: Some(note),
                        ..Default::default()
                    })
                }
                4 => {
                    let id = self.rng.pick(&ids).clone();
                    touched.push(id.clone());
                    let text = self.unique("Agent text ");
                    Op::Upsert(Upsert {
                        id: Some(id),
                        text: Some(text),
                        ..Default::default()
                    })
                }
                5 => {
                    let id = self.rng.pick(&ids).clone();
                    touched.push(id.clone());
                    if self.rng.chance(50) {
                        Op::Remove { id }
                    } else {
                        Op::Move {
                            id,
                            section: if self.rng.chance(50) { "now" } else { "next" }.into(),
                            before: None,
                            after: None,
                        }
                    }
                }
                _ => {
                    let id = format!("agent-new-{}", self.counter + 1);
                    touched.push(id.clone());
                    let text = self.unique("Added by agent ");
                    Op::Upsert(Upsert {
                        id: Some(id),
                        section: Some("now".into()),
                        text: Some(text),
                        ..Default::default()
                    })
                }
            },
        };
        let injected = self.maybe_inject();
        let before = self.bytes();
        let base = self.cursor[i].unwrap_or(0);
        let session = self.session[i].clone();
        let result = self.reg.apply(
            TAG[i],
            &session,
            std::slice::from_ref(&op),
            &agent(i, &session),
        );
        self.steps.push(format!(
            "agent {i} (session {}, cursor {:?}) {op:?} -> {}",
            self.generation[i],
            self.cursor[i],
            match &result {
                Ok(o) => format!("ok v{}", o.version),
                Err(e) => format!("{e}"),
            }
        ));
        *self.fs.hook.lock().unwrap() = None;
        self.settle(
            Who::Agent(i, self.generation[i]),
            base,
            &before,
            &touched,
            injected,
            step,
        );
    }

    fn conflict_ids_now(&self) -> Vec<String> {
        self.reg
            .conflicts(TAG[0])
            .into_iter()
            .map(|c| c.id)
            .collect()
    }

    fn pane_step(&mut self, step: usize) {
        let w = self.rng.below(2);
        // Half the time the window looks before it acts; otherwise it acts on
        // whatever it last showed, however old.
        if self.rng.chance(50) {
            self.look(w);
        }
        let ids = self.item_ids();
        if ids.is_empty() {
            self.steps.push(format!(
                "window {w} has nothing to act on (the board has no items)"
            ));
            return;
        }
        let mut touched = Vec::new();
        let base = self.views[w].version;
        // What the oracle counts the window to have seen: nothing, when its
        // view is from before a restart.
        let seen = if self.view_stale[w] { 0 } else { base };
        // A batch that must be refused.
        let mut must_refuse = false;
        // What a conflict settled by this batch was, to excuse it afterwards.
        let mut settles: Option<(Shown, ConflictKeep)> = None;
        let hot = self.hot.clone().filter(|h| ids.contains(h));
        // With conflicts on the window's view the pane often settles one (the
        // rest of the time it does what it does).
        let arm = if matches!((&hot, self.rng.chance(50)), (Some(_), true)) {
            12
        } else if !self.views[w].shown.is_empty() && self.rng.chance(35) {
            7
        } else {
            self.rng.below(12)
        };
        let ops: Vec<TrackerPaneOp> = match arm {
            12 => {
                let id = hot.clone().expect("a hot item");
                touched.push(id.clone());
                vec![TrackerPaneOp::Edit {
                    id,
                    title: None,
                    text: None,
                    body: Some(self.unique("hot-pane-note-")),
                }]
            }
            0 => {
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                vec![TrackerPaneOp::Status {
                    id,
                    status: self.rng.pick(&STATUSES).to_string(),
                }]
            }
            1 | 2 => {
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                let (title, body) = if self.rng.chance(50) {
                    (Some(self.unique("Pane title ")), None)
                } else {
                    let body = if self.rng.chance(20) {
                        String::new()
                    } else {
                        self.unique("pane-note-")
                    };
                    (None, Some(body))
                };
                vec![TrackerPaneOp::Edit {
                    id,
                    title,
                    text: None,
                    body,
                }]
            }
            3 => vec![TrackerPaneOp::Add {
                section: if self.rng.chance(50) { "now" } else { "next" }.into(),
                title: self.unique("Pane added "),
                body: None,
                before: None,
                after: None,
            }],
            4 => {
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                vec![TrackerPaneOp::Move {
                    id,
                    section: if self.rng.chance(50) { "now" } else { "next" }.into(),
                    before: None,
                    after: None,
                }]
            }
            5 => {
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                // What the pane held of it, to restore later.
                let view = self.reg.board_view(TAG[0]).unwrap();
                for node in view.nodes {
                    if let ViewNode::Item(item) = node {
                        if item.id == id {
                            self.removed.push((id.clone(), item.section, item.source));
                        }
                    }
                }
                vec![TrackerPaneOp::Remove { id }]
            }
            6 => match self.removed.pop() {
                Some((id, section, source)) => {
                    touched.push(id);
                    vec![TrackerPaneOp::Restore {
                        source,
                        section,
                        before: None,
                        after: None,
                    }]
                }
                None => vec![TrackerPaneOp::Status {
                    id: self.rng.pick(&ids).clone(),
                    status: "in-progress".into(),
                }],
            },
            7 | 8 => {
                // Settle a conflict this window's view shows, by the id the
                // view gave it: whatever has happened to it since.
                let shown = self.views[w].shown.clone();
                if shown.is_empty() {
                    vec![TrackerPaneOp::Status {
                        id: self.rng.pick(&ids).clone(),
                        status: "needs-you".into(),
                    }]
                } else {
                    let c = self.rng.pick(&shown).clone();
                    let keep = if self.rng.chance(50) {
                        ConflictKeep::Current
                    } else {
                        ConflictKeep::Losing
                    };
                    touched.push(c.item.clone());
                    let resolve = |c: &Shown, keep| TrackerPaneOp::ResolveConflict {
                        id: c.item.clone(),
                        field: c.field.clone(),
                        keep,
                        conflict_id: Some(c.conflict_id.clone()),
                        index: None,
                    };
                    let twin = shown.iter().find(|s| {
                        s.item == c.item && s.field == c.field && s.conflict_id != c.conflict_id
                    });
                    match (self.rng.chance(20), twin) {
                        // The same conflict twice in one batch.
                        (true, _) if self.rng.chance(50) => {
                            must_refuse = true;
                            vec![resolve(&c, keep), resolve(&c, keep)]
                        }
                        // Two losing values of one field in one batch.
                        (true, Some(other)) if c.field != "removed" => {
                            must_refuse = true;
                            vec![
                                resolve(&c, ConflictKeep::Losing),
                                resolve(other, ConflictKeep::Losing),
                            ]
                        }
                        _ => {
                            settles = Some((c.clone(), keep));
                            vec![resolve(&c, keep)]
                        }
                    }
                }
            }
            9 => {
                // A write, then clearing the badge: refused as a whole when
                // the item changed after the base.
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                let mut batch = Vec::new();
                if self.rng.chance(70) {
                    batch.push(TrackerPaneOp::Status {
                        id: id.clone(),
                        status: self.rng.pick(&STATUSES).to_string(),
                    });
                }
                batch.push(TrackerPaneOp::ClearBadge { id });
                batch
            }
            10 => {
                // A restructure: a short title, the rest into the note.
                let id = self.rng.pick(&ids).clone();
                touched.push(id.clone());
                let view = self.reg.board_view(TAG[0]).unwrap();
                for node in view.nodes {
                    if let ViewNode::Item(item) = node {
                        if item.id == id {
                            self.restructured.push((id.clone(), item.text, item.note));
                        }
                    }
                }
                let title = self.unique("Short ");
                vec![TrackerPaneOp::Edit {
                    id,
                    title: Some(title),
                    text: None,
                    body: Some(self.unique("moved-text-")),
                }]
            }
            _ => match self.restructured.pop() {
                // The undo: the text back whole, then the note.
                Some((id, text, note)) => {
                    touched.push(id.clone());
                    vec![
                        TrackerPaneOp::RestoreText {
                            id: id.clone(),
                            text,
                        },
                        TrackerPaneOp::Edit {
                            id,
                            title: None,
                            text: None,
                            body: Some(note.unwrap_or_default()),
                        },
                    ]
                }
                None => vec![TrackerPaneOp::Status {
                    id: self.rng.pick(&ids).clone(),
                    status: "done".into(),
                }],
            },
        };
        let injected = self.maybe_inject();
        let before = self.bytes();
        let version_before = self.version();
        let conflicts_before = self.conflict_ids_now();
        let epoch = self.views[w].epoch.clone();
        let result = self
            .reg
            .apply_pane_ops_in(TAG[0], WINDOW[w], base, Some(&epoch), &ops);
        let unknown_id = ops.iter().any(|op| match op {
            TrackerPaneOp::ResolveConflict {
                conflict_id: Some(id),
                ..
            } => !conflicts_before.contains(id),
            _ => false,
        });
        if result.is_ok() && (must_refuse || unknown_id) {
            self.failures.push(format!(
                "step {step}: a batch settling {} was applied",
                if must_refuse {
                    "a conflict twice or two losing values of a field"
                } else {
                    "a conflict the board no longer keeps"
                }
            ));
        }
        if result.is_ok() {
            for op in &ops {
                if let TrackerPaneOp::ResolveConflict {
                    conflict_id: Some(id),
                    ..
                } = op
                {
                    self.settled_now.push(id.clone());
                }
            }
        }
        if let Ok(done) = &result {
            touched.extend(done.created.clone());
            if let Some((conflict, ConflictKeep::Current)) = &settles {
                self.excused.push(conflict.clone());
            }
            // A removed item whose id was taken again comes back under a new
            // one, with exactly the markdown it had.
            if let Some((c, ConflictKeep::Losing)) = &settles {
                let source = c.source.clone().unwrap_or_default();
                if let Some(new_id) = done.created.iter().find(|id| **id != c.item) {
                    let marker_old = format!("<!-- #{} ", c.item);
                    let want = source.replacen(&marker_old, &format!("<!-- #{new_id} "), 1);
                    if !String::from_utf8_lossy(&self.bytes()).contains(&want) {
                        self.failures.push(format!(
                            "step {step}: {} was put back under {new_id} but not byte for byte",
                            c.item
                        ));
                    }
                    self.restored_elsewhere.push((c.item.clone(), source));
                }
            }
        }
        self.steps.push(format!(
            "window {w} (base {base}) {ops:?} -> {}",
            match &result {
                Ok(o) => format!("ok v{}", o.version),
                Err(e) => format!("{} {:?}", e.code, e.reason),
            }
        ));
        *self.fs.hook.lock().unwrap() = None;
        // A refused batch writes nothing, bumps nothing and settles nothing.
        if result.is_err() && !injected {
            if self.bytes() != before {
                self.failures.push(format!(
                    "step {step}: a refused pane batch changed the file"
                ));
            }
            if self.version() != version_before {
                self.failures.push(format!(
                    "step {step}: a refused pane batch moved the version"
                ));
            }
            if self.conflict_ids_now() != conflicts_before {
                self.failures.push(format!(
                    "step {step}: a refused pane batch changed the conflicts kept"
                ));
            }
        }
        self.settle(Who::Pane(w), seen, &before, &touched, injected, step);
        // The window's view follows the broadcast of its own edit, most times.
        if self.rng.chance(60) {
            self.look(w);
        }
    }

    fn file_step(&mut self, step: usize) {
        let before = self.bytes();
        let (new_bytes, base, what) = if self.rng.chance(50) {
            let s = self.stale();
            let (version, bytes) = self.history[s].clone();
            (
                bytes,
                version,
                format!("a stale copy from version {version}"),
            )
        } else {
            let ids = self.item_ids();
            if ids.is_empty() {
                self.steps.push("file save: no items to change".to_string());
                return;
            }
            let mut ops = Vec::new();
            for _ in 0..1 + self.rng.below(2) {
                let id = self.rng.pick(&ids).clone();
                let value = self.unique("file-");
                ops.push(match self.rng.below(4) {
                    0 => Op::Upsert(Upsert {
                        id: Some(id),
                        owner: Some(value),
                        ..Default::default()
                    }),
                    1 => Op::Upsert(Upsert {
                        id: Some(id),
                        note: Some(value),
                        ..Default::default()
                    }),
                    2 => Op::Status {
                        id,
                        status: self.rng.pick(&STATUSES).to_string(),
                    },
                    _ => Op::Upsert(Upsert {
                        id: Some(id),
                        text: Some(format!("File text {value}")),
                        ..Default::default()
                    }),
                });
            }
            let stamp = self.stamp();
            let bytes = apply_to_file(&before, &ops, &Author::File, stamp)
                .map(|a| a.bytes)
                .unwrap_or_else(|_| before.clone());
            (
                bytes,
                self.version(),
                format!("the current bytes, edited: {ops:?}"),
            )
        };
        if new_bytes == before {
            self.steps.push("file save: nothing changed".into());
            return;
        }
        std::fs::write(&self.path, &new_bytes).unwrap();
        self.reg.ingest_file_change(&self.path);
        self.steps.push(format!("file saves {what}"));
        let applied = self.version();
        let writes = writes_between(
            &items_of(&before),
            &items_of(&new_bytes),
            Who::File,
            base,
            applied,
            step,
        );
        self.writes.extend(writes);
    }

    /// After every step: conflict ids are unique and never change what they
    /// name; a cap that dropped a value is said so by the view, until the
    /// item's conflicts are settled.
    fn audit(&mut self, step: usize) {
        let conflicts = self.reg.conflicts(TAG[0]);
        let mut now = BTreeMap::new();
        for c in &conflicts {
            let named = (
                c.item_id.clone(),
                c.field.clone(),
                format!("{:?}", c.losing),
            );
            if c.id.is_empty() {
                self.failures
                    .push(format!("step {step}: a conflict has no id: {c:?}"));
            }
            if now.insert(c.id.clone(), named.clone()).is_some() {
                self.failures
                    .push(format!("step {step}: conflict id {} is used twice", c.id));
            }
            if let Some(before) = self.ever_named.get(&c.id) {
                if *before != named {
                    self.failures.push(format!(
                        "step {step}: conflict id {} named {before:?}, now {named:?}",
                        c.id
                    ));
                }
            }
        }
        for (id, named) in &now {
            self.ever_named.insert(id.clone(), named.clone());
        }
        self.named = now;
        self.audit_real_before_guess(step, &conflicts);

        let view = self.reg.board_view(TAG[0]).expect("a board");
        let mut marked = BTreeSet::new();
        let mut with_conflicts = BTreeSet::new();
        for node in &view.nodes {
            if let ViewNode::Item(item) = node {
                if item.dropped_conflicts > 0 {
                    marked.insert(item.id.clone());
                }
                if !item.conflicts.is_empty() {
                    with_conflicts.insert(item.id.clone());
                }
            }
        }
        let dropped = self.reg.conflicts_dropped(TAG[0]);
        if dropped > self.dropped_seen && marked.is_empty() {
            self.failures.push(format!(
                "step {step}: a cap dropped a losing value ({dropped} so far) and no item says so"
            ));
        }
        self.dropped_seen = dropped;
        for id in &self.marked_now {
            let item_there = view
                .nodes
                .iter()
                .any(|n| matches!(n, ViewNode::Item(i) if &i.id == id));
            if item_there && with_conflicts.contains(id) && !marked.contains(id) {
                self.failures.push(format!(
                    "step {step}: {id} had its dropped marker cleared while it still has conflicts"
                ));
            }
        }
        self.marked.extend(marked.iter().cloned());
        self.marked_now = marked;
    }

    /// A real conflict is never dropped by the board cap while an older guess
    /// (a value kept only because a stale view couldn't be checked) is still
    /// kept: the guesses go first.
    fn audit_real_before_guess(&mut self, step: usize, now: &[nostromo::tracker::Conflict]) {
        let version = self.version();
        let ids: BTreeSet<&str> = now.iter().map(|c| c.id.as_str()).collect();
        let settled = std::mem::take(&mut self.settled_now);
        let guess_kept = now.iter().any(|c| c.guess);
        let drops = self.reg.conflicts_dropped(TAG[0]);
        let cap_dropped = drops > self.cap_drops;
        self.cap_drops = drops;
        // A step that both removed an item and made a cap drop may have
        // dropped that item's kept markdown (the conflict was made and
        // dropped in the one write).
        let items: BTreeSet<String> = self.item_ids().into_iter().collect();
        if cap_dropped {
            self.cap_dropped_removed
                .extend(self.prev_items.difference(&items).cloned());
        }
        self.prev_items = items;
        for (id, item, field, guess, born) in &self.prev_list {
            let gone = !ids.contains(id.as_str()) && !settled.contains(id);
            let in_group = self
                .prev_list
                .iter()
                .filter(|(_, i, f, _, _)| i == item && f == field)
                .count();
            if gone && cap_dropped && field == "removed" {
                self.cap_dropped_removed.insert(item.clone());
            }
            if gone && !guess && field != "removed" && in_group < 5 && guess_kept && *born < version
            {
                self.failures.push(format!(
                    "step {step}: real conflict {id} ({item}.{field}) was dropped while a guess is still kept"
                ));
            }
        }
        self.prev_list = now
            .iter()
            .map(|c| {
                (
                    c.id.clone(),
                    c.item_id.clone(),
                    c.field.clone(),
                    c.guess,
                    c.version,
                )
            })
            .collect();
    }

    /// Plants one real conflict, then a stale window (window 1, whose view the
    /// log no longer reaches) changes all the bulk items at once.
    fn bulk_step(&mut self, step: usize) {
        // The real one: agent 1 writes a note, window 0 (which saw only up to
        // before that) overwrites it.
        let agent_note = self.unique("real-agent-note-");
        let before = self.bytes();
        let session = self.session[1].clone();
        let op = Op::Upsert(Upsert {
            id: Some("item-2".into()),
            note: Some(agent_note),
            ..Default::default()
        });
        let base = self.cursor[1].unwrap_or(0);
        let r = self.reg.apply(
            TAG[1],
            &session,
            std::slice::from_ref(&op),
            &agent(1, &session),
        );
        self.steps.push(format!("agent 1 {op:?} -> {}", r.is_ok()));
        self.settle(
            Who::Agent(1, self.generation[1]),
            base,
            &before,
            &["item-2".into()],
            false,
            step,
        );
        let ops = vec![TrackerPaneOp::Edit {
            id: "item-2".into(),
            title: None,
            text: None,
            body: Some(self.unique("real-pane-note-")),
        }];
        let (before, base) = (self.bytes(), self.views[0].version);
        let epoch = self.views[0].epoch.clone();
        let r = self
            .reg
            .apply_pane_ops_in(TAG[0], WINDOW[0], base, Some(&epoch), &ops);
        self.steps
            .push(format!("window 0 (base {base}) {ops:?} -> {}", r.is_ok()));
        self.settle(Who::Pane(0), base, &before, &["item-2".into()], false, step);
        // From here on the real conflict is watched.
        let kept = self.reg.conflicts(TAG[0]);
        self.audit_real_before_guess(step, &kept);
        // The stale window changes every bulk item.
        let ops: Vec<TrackerPaneOp> = (0..BULK)
            .map(|n| TrackerPaneOp::Status {
                id: format!("bulk-{n}"),
                status: "blocked".into(),
            })
            .collect();
        let (before, base) = (self.bytes(), self.views[1].version);
        let ids: Vec<String> = (0..BULK).map(|n| format!("bulk-{n}")).collect();
        let epoch = self.views[1].epoch.clone();
        let r = self
            .reg
            .apply_pane_ops_in(TAG[0], WINDOW[1], base, Some(&epoch), &ops);
        self.steps.push(format!(
            "window 1 (stale base {base}) changes {BULK} items -> {}",
            r.is_ok()
        ));
        if let Err(e) = &r {
            self.failures
                .push(format!("step {step}: the bulk change was refused: {e:?}"));
        }
        self.settle(Who::Pane(1), base, &before, &ids, false, step);
    }

    fn run(&mut self) {
        let count = if self.hot.is_some() {
            40 + self.rng.below(41)
        } else {
            10 + self.rng.below(21)
        };
        for step in 1..=count {
            let secs = if self.hot.is_some() {
                self.rng.below(9)
            } else {
                self.rng.below(21)
            } as i64;
            self.clock.advance(ChronoDuration::seconds(secs));
            self.steps.push(format!("[{step}] +{secs}s"));
            if self.restart_at == Some(step) {
                self.restart();
                self.stale_window_overwrites_an_old_value(step);
            }
            if self.gap_run && step == 1 {
                self.bulk_step(step);
            }
            match self.rng.below(20) {
                0..=6 => self.agent_step(step),
                7..=12 => self.pane_step(step),
                13..=16 => self.file_step(step),
                17 => {
                    let w = self.rng.below(2);
                    self.look(w);
                }
                _ => {
                    let i = self.rng.below(2);
                    self.read(i);
                }
            }
            self.snapshot();
            self.audit(step);
        }
    }

    // -----------------------------------------------------------------------
    // The oracle
    // -----------------------------------------------------------------------

    fn check(&mut self) -> Vec<String> {
        let mut failures = std::mem::take(&mut self.failures);
        let final_items = items_of(&self.bytes());
        let conflicts = self.reg.conflicts(TAG[0]);
        // The items' bytes a `removed` conflict kept, parsed.
        let mut sources: Vec<(String, String)> = conflicts
            .iter()
            .filter(|c| c.field == "removed")
            .filter_map(|c| Some((c.item_id.clone(), c.losing.as_str()?.to_string())))
            .collect();
        sources.extend(self.restored_elsewhere.iter().cloned());
        sources.extend(
            self.excused
                .iter()
                .filter_map(|c| Some((c.item.clone(), c.source.clone()?))),
        );
        let kept: Vec<(String, Items)> = sources
            .iter()
            .map(|(id, source)| {
                let wrapped = format!("## Kept\n{source}");
                (id.clone(), items_of(wrapped.as_bytes()))
            })
            .collect();
        for (index, e) in self.writes.iter().enumerate() {
            if e.field == "removed" {
                continue;
            }
            let in_file = final_items
                .get(&e.item)
                .is_some_and(|f| f[e.field] == e.value);
            let lost_to_conflict = conflicts.iter().any(|c| {
                c.item_id == e.item && c.field == e.field && value_of(&c.losing) == e.value
            }) || self
                .excused
                .iter()
                .any(|c| c.item == e.item && c.field == e.field && c.value() == e.value)
                || kept.iter().any(|(id, items)| {
                    *id == e.item && items.values().any(|f| f[e.field] == e.value)
                });
            let superseded = self.writes[index + 1..].iter().any(|w| {
                w.item == e.item
                    && (w.field == e.field || w.field == "removed")
                    && (w.who == e.who
                        // A value from before a restart was seen only by a
                        // writer whose base is from after it; any other
                        // base is a version of another log.
                        || if e.pre_restart {
                            w.fresh
                        } else {
                            w.base >= e.applied
                        })
            });
            // A cap dropped it, and the view said so: the accepted loss.
            let said_dropped =
                self.marked.contains(&e.item) || self.cap_dropped_removed.contains(&e.item);
            if !(in_file || lost_to_conflict || superseded || said_dropped) {
                failures.push(format!(
                    "LOST: {:?} wrote {}={:?} on {} at step {} (base {}, applied v{}); not in the file, no conflict holds it, not superseded",
                    e.who, e.field, e.value, e.item, e.step, e.base, e.applied
                ));
            }
        }
        failures
    }
}

fn one(seed: u64) -> Result<(), String> {
    let mut world = World::new(seed);
    world.run();
    let failures = world.check();
    if failures.is_empty() {
        return Ok(());
    }
    let kept: Vec<String> = world
        .reg
        .conflicts(TAG[0])
        .iter()
        .map(|c| {
            format!(
                "{} {}.{} lost {:?} (by {}, to {})",
                c.id,
                c.item_id,
                c.field,
                c.losing,
                c.losing_author.label(),
                c.winning_author.label()
            )
        })
        .collect();
    Err(format!(
        "seed {seed:#x} ({} steps)\n{}\n--- conflicts kept at the end\n{}\n--- failures\n{}",
        world.steps.len(),
        world.steps.join("\n"),
        kept.join("\n"),
        failures.join("\n")
    ))
}

/// The interleaving the long fuzz run found: a note a removal took off the
/// board, set back by a stale save over a newer note, was silently lost.
#[test]
fn a_stale_save_restoring_a_value_a_removal_took_off_loses_no_edit() {
    one(0x7a11_0a5a).unwrap_or_else(|e| panic!("{e}"));
}

/// Another interleaving of the same family: a removal's value coming back
/// through a stale save.
#[test]
fn a_stale_save_after_a_removal_loses_no_edit_seed_7a110c9a() {
    one(0x7a11_0c9a).unwrap_or_else(|e| panic!("{e}"));
}

/// The three interleavings Perri's review of #490 found (they fail on main
/// too): a stale window floods the board past its cap, and keeping the losing
/// value cleared an item's dropped marker while it still had conflicts.
#[test]
fn a_flooded_board_keeps_the_dropped_marker_seed_7a1228e0() {
    one(0x7a12_28e0).unwrap_or_else(|e| panic!("{e}"));
}

#[test]
fn a_flooded_board_keeps_the_dropped_marker_seed_7a126120() {
    one(0x7a12_6120).unwrap_or_else(|e| panic!("{e}"));
}

#[test]
fn a_flooded_board_keeps_the_dropped_marker_seed_7a1145aa() {
    one(0x7a11_45aa).unwrap_or_else(|e| panic!("{e}"));
}

#[test]
fn four_hundred_interleavings_lose_no_edit() {
    let seeds: Vec<u64> = match std::env::var("TRACKER_FUZZ_SEED") {
        Ok(s) => vec![u64::from_str_radix(s.trim_start_matches("0x"), 16)
            .or_else(|_| s.parse())
            .expect("TRACKER_FUZZ_SEED is a number")],
        Err(_) => {
            // `TRACKER_FUZZ_COUNT` runs more interleavings (to hunt, not to gate).
            let count = std::env::var("TRACKER_FUZZ_COUNT")
                .ok()
                .and_then(|c| c.parse().ok())
                .unwrap_or(INTERLEAVINGS);
            let start = std::env::var("TRACKER_FUZZ_START")
                .ok()
                .and_then(|c| c.parse().ok())
                .unwrap_or(0);
            (start..start + count).map(|n| SEED_BASE + n).collect()
        }
    };
    // A panic inside an interleaving (a bug in the fixture, or in the daemon)
    // is a failure of that seed, reported with it, not an abort of the run.
    let failed: Vec<(u64, String)> = seeds
        .iter()
        .filter_map(|s| {
            let seed = *s;
            match std::panic::catch_unwind(|| one(seed)) {
                Ok(result) => result.err().map(|e| (seed, e)),
                Err(payload) => {
                    let why = payload
                        .downcast_ref::<String>()
                        .cloned()
                        .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                        .unwrap_or_else(|| "a panic".to_string());
                    Some((seed, format!("seed {seed:#x} panicked: {why}")))
                }
            }
        })
        .collect();
    if let Some((_, first)) = failed.first() {
        let list: Vec<String> = failed.iter().map(|(s, _)| format!("{s:#x}")).collect();
        panic!(
            "{} of {} interleavings lost an edit (seeds {}); the first:\n{first}",
            failed.len(),
            seeds.len(),
            list.join(", ")
        );
    }
}
