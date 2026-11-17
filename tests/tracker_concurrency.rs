//! Zero lost edits (PRD 42, slice T3a): three writers (two agents, the pane,
//! and anything saving the file) interleave on one board, and no value any of
//! them wrote is silently lost.
//!
//! A seeded generator produces 400 interleavings of 10-30 steps: agent ops
//! (some with a stale read cursor), pane ops (some with a stale base
//! version), file saves from the current bytes or from a stale copy taken 1-40
//! steps earlier, saves injected between the daemon's read and its commit,
//! and fake-clock advances of 0-20 s. After each interleaving an *oracle*
//! checks every value any writer wrote. For each write E (who, item, field,
//! value) at least one of these holds:
//!
//! 1. E's value is in the final file;
//! 2. E's value is a losing value of a live conflict (or the item's bytes at
//!    removal, kept by a `removed` conflict, hold it);
//! 3. E was superseded knowingly: a later write to the same field (or a
//!    removal of the item) by the same author, or by an author whose base
//!    (pane `base_version`, agent read cursor, the copy a file save was made
//!    from) included E.
//!
//! The writes are derived from what the file actually says before and after
//! each step, so the oracle shares nothing with the daemon's conflict rule.
//! Also asserted: bytes outside the changed items are identical after every
//! agent or pane write, and no conflict cap dropped a losing value.
//!
//! A stale file save is a verbatim old copy (what an editor's old buffer
//! does); a deliberate file edit is made from the current bytes. (A value
//! typed over an agent's in a stale buffer, with nothing else different, is
//! indistinguishable from typing it over a fresh one, so it is not generated.)
//!
//! The pane's `resolve_conflict` (either side, a stale or a fresh view),
//! `clear_badge` (alone and after a write in the same batch), a restructure
//! and its undo, and an agent re-opening the board are generated too. A
//! conflict the pane settled with "keep current" is excused (it saw it); any
//! other conflict that disappears is a lost edit. A refused pane batch must
//! leave the file byte-identical.
//!
//! Failing interleavings print their seed and every step. `TRACKER_FUZZ_SEED`
//! reruns one seed. Hermetic: `FakeClock`, temp dirs, no network.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use chrono::Duration as ChronoDuration;
use nostromo::ipc::protocol::{ConflictKeep, TrackerPaneOp};
use nostromo::tracker::watch::{BoardFs, FileSignature, RealBoardFs};
use nostromo::tracker::Conflict;
use nostromo::tracker::{
    apply_to_file, parse, Author, Clock, FakeClock, Op, OpenArgs, ReadOutcome, RegistryParts,
    Stamp, TrackerRegistry, Upsert,
};
use serde_json::Value;
use tempfile::TempDir;

const TAG: [&str; 2] = ["cody-a", "cody-b"];
const SESS: [&str; 2] = ["sess-a", "sess-b"];
const INTERLEAVINGS: u64 = 400;
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

    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
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
    Agent(usize),
    Pane,
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

struct World {
    _tmp: TempDir,
    path: PathBuf,
    clock: Arc<FakeClock>,
    reg: Arc<TrackerRegistry>,
    fs: Arc<HookFs>,
    rng: Rng,
    steps: Vec<String>,
    writes: Vec<Write>,
    /// The file's bytes and version after every step (stale copies come from here).
    history: Vec<(u64, Vec<u8>)>,
    /// What each agent has read through.
    cursor: [u64; 2],
    /// Items the pane removed, by id: the exact markdown and where it sat.
    removed: Vec<(String, String, String)>,
    counter: usize,
    /// Conflicts the pane settled by keeping the current value, having seen them.
    excused: Vec<Conflict>,
    /// What a restructure replaced, to undo: (id, text, note).
    restructured: Vec<(String, String, Option<String>)>,
    open_args: OpenArgs,
    /// Injected saves, recorded when they run.
    injected: Arc<Mutex<Vec<Write>>>,
    failures: Vec<String>,
}

fn agent(i: usize) -> Author {
    Author::Agent {
        focus: TAG[i].into(),
        session_id: SESS[i].into(),
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
        reg.apply(TAG[0], SESS[0], &seed_ops, &agent(0)).unwrap();
        let mut world = World {
            _tmp: tmp,
            path,
            clock,
            reg,
            fs,
            rng: Rng(seed),
            steps: Vec::new(),
            writes: Vec::new(),
            history: Vec::new(),
            cursor: [0, 0],
            removed: Vec::new(),
            counter: 0,
            excused: Vec::new(),
            restructured: Vec::new(),
            open_args: args_kept,
            injected: Arc::new(Mutex::new(Vec::new())),
            failures: Vec::new(),
        };
        for i in 0..2 {
            world.read(i);
        }
        world.steps.clear();
        world.snapshot();
        world
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
        let version = match self.reg.read(TAG[i], SESS[i]).expect("read") {
            ReadOutcome::Full { version, .. } | ReadOutcome::Delta { version, .. } => version,
        };
        self.cursor[i] = version;
        self.steps
            .push(format!("agent {i} reads (cursor {version})"));
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
        self.writes.extend(new_writes);
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
    /// it has seen) does not move.
    fn reopen(&mut self, i: usize) {
        self.reg
            .open(TAG[i], SESS[i], &self.open_args)
            .expect("re-open");
        self.steps.push(format!(
            "agent {i} re-opens (cursor stays {})",
            self.cursor[i]
        ));
    }

    fn agent_step(&mut self, step: usize) {
        let i = self.rng.below(2);
        if self.rng.chance(10) {
            self.reopen(i);
            return;
        }
        let ids = self.item_ids();
        let mut touched = Vec::new();
        let op = match self.rng.below(7) {
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
        };
        let injected = self.maybe_inject();
        let before = self.bytes();
        let base = self.cursor[i];
        let result = self
            .reg
            .apply(TAG[i], SESS[i], std::slice::from_ref(&op), &agent(i));
        self.steps.push(format!(
            "agent {i} (cursor {base}) {op:?} -> {}",
            match &result {
                Ok(o) => format!("ok v{}", o.version),
                Err(e) => format!("{e}"),
            }
        ));
        *self.fs.hook.lock().unwrap() = None;
        self.settle(Who::Agent(i), base, &before, &touched, injected, step);
    }

    fn pane_step(&mut self, step: usize) {
        let ids = self.item_ids();
        let mut touched = Vec::new();
        let base = if self.rng.chance(30) {
            let s = self.stale();
            self.history[s].0
        } else {
            self.version()
        };
        // What a conflict settled by this batch was, to excuse it afterwards.
        let mut settles: Option<(Conflict, ConflictKeep)> = None;
        // With conflicts on the board the pane often settles one (the rest of
        // the time it does what it does).
        let arm = if self.reg.conflicts_dropped(TAG[0]) == 0
            && !self.reg.conflicts(TAG[0]).is_empty()
            && self.rng.chance(35)
        {
            7
        } else {
            self.rng.below(12)
        };
        let ops: Vec<TrackerPaneOp> = match arm {
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
                    if let nostromo::tracker::view::ViewNode::Item(item) = node {
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
                // Settle a conflict the view at `base` could show.
                let visible: Vec<Conflict> = self
                    .reg
                    .conflicts(TAG[0])
                    .into_iter()
                    .filter(|c| c.version <= base)
                    .collect();
                if visible.is_empty() {
                    vec![TrackerPaneOp::Status {
                        id: self.rng.pick(&ids).clone(),
                        status: "needs-you".into(),
                    }]
                } else {
                    let c = self.rng.pick(&visible).clone();
                    let same: Vec<&Conflict> = visible
                        .iter()
                        .filter(|o| o.item_id == c.item_id && o.field == c.field)
                        .collect();
                    // The pane's index is the ordinal in what it saw; no
                    // index means the newest it saw.
                    let (index, chosen) = if self.rng.chance(50) {
                        let n = same.iter().position(|o| **o == c).unwrap();
                        (Some(n as u32), c.clone())
                    } else {
                        (None, (*same.last().unwrap()).clone())
                    };
                    let keep = if self.rng.chance(50) {
                        ConflictKeep::Current
                    } else {
                        ConflictKeep::Losing
                    };
                    touched.push(chosen.item_id.clone());
                    settles = Some((chosen.clone(), keep));
                    vec![TrackerPaneOp::ResolveConflict {
                        id: chosen.item_id,
                        field: chosen.field,
                        keep,
                        index,
                    }]
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
                    if let nostromo::tracker::view::ViewNode::Item(item) = node {
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
        let result = self.reg.apply_pane_ops(TAG[0], base, &ops);
        if let Ok(done) = &result {
            touched.extend(done.created.clone());
            if let Some((conflict, ConflictKeep::Current)) = settles {
                self.excused.push(conflict);
            }
        }
        self.steps.push(format!(
            "pane (base {base}) {ops:?} -> {}",
            match &result {
                Ok(o) => format!("ok v{}", o.version),
                Err(e) => format!("{} {:?}", e.code, e.reason),
            }
        ));
        *self.fs.hook.lock().unwrap() = None;
        // A refused batch writes nothing and bumps nothing.
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
        }
        self.settle(Who::Pane, base, &before, &touched, injected, step);
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

    fn run(&mut self) {
        let count = 10 + self.rng.below(21);
        for step in 1..=count {
            let secs = self.rng.below(21) as i64;
            self.clock.advance(ChronoDuration::seconds(secs));
            self.steps.push(format!("[{step}] +{secs}s"));
            match self.rng.below(20) {
                0..=6 => self.agent_step(step),
                7..=12 => self.pane_step(step),
                13..=16 => self.file_step(step),
                _ => {
                    let i = self.rng.below(2);
                    self.read(i);
                }
            }
            self.snapshot();
        }
    }

    // -----------------------------------------------------------------------
    // The oracle
    // -----------------------------------------------------------------------

    fn check(&mut self) -> Vec<String> {
        let mut failures = std::mem::take(&mut self.failures);
        let final_items = items_of(&self.bytes());
        let conflicts = self.reg.conflicts(TAG[0]);
        if self.reg.conflicts_dropped(TAG[0]) != 0 {
            failures.push("a conflict cap dropped a losing value".into());
        }
        // The items' bytes a `removed` conflict kept, parsed.
        let kept: Vec<(String, Items)> = conflicts
            .iter()
            .chain(self.excused.iter())
            .filter(|c| c.field == "removed")
            .filter_map(|c| {
                let source = c.losing.as_str()?;
                let wrapped = format!("## Kept\n{source}");
                Some((c.item_id.clone(), items_of(wrapped.as_bytes())))
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
            }) || self.excused.iter().any(|c| {
                c.item_id == e.item && c.field == e.field && value_of(&c.losing) == e.value
            }) || kept
                .iter()
                .any(|(id, items)| *id == e.item && items.values().any(|f| f[e.field] == e.value));
            let superseded = self.writes[index + 1..].iter().any(|w| {
                w.item == e.item
                    && (w.field == e.field || w.field == "removed")
                    && (w.who == e.who || w.base >= e.applied)
            });
            if !(in_file || lost_to_conflict || superseded) {
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
    Err(format!(
        "seed {seed:#x} ({} steps)\n{}\n--- failures\n{}",
        world.steps.len(),
        world.steps.join("\n"),
        failures.join("\n")
    ))
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
            (0..count).map(|n| SEED_BASE + n).collect()
        }
    };
    let failed: Vec<(u64, String)> = seeds
        .iter()
        .filter_map(|s| one(*s).err().map(|e| (*s, e)))
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
