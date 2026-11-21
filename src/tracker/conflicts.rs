//! Concurrent-edit conflicts (PRD 41, 42): three writers (agents, the pane,
//! anything editing the file) change one board, and a write that overwrites
//! another author's change the writer couldn't have seen keeps that change as
//! a *losing value* instead of dropping it silently.
//!
//! Pure: the log, the changes and the clock come in, conflicts come out.
//!
//! **The rule.** A write by author W that changes field F of item I (or
//! removes I) conflicts when F's latest change (or, for a removal, any change
//! to I) was made by a different author L, and either
//!
//! - (a) L's change is at most [`WINDOW_SECS`] before W's, or
//! - (b) W could not have seen it:
//!   - pane or agent: L's change has `seq` after what W had read
//!     (`base_version` for the pane, the session's read cursor for an agent;
//!     an agent that never read has seen nothing, cursor 0), or the log no
//!     longer reaches back to what W had read and F has no visible history
//!     (the value that was there fell off the log: its author is unknown, so
//!     it is attributed `file (unknown editor)`);
//!   - file: the save sets F back to a value F once had (a stale editor copy;
//!     a value that left through an item's removal counts, not only one an
//!     edit replaced),
//!     or drops an item L added or changed, at any age.
//!
//! `Source` writes never conflict and a `Source` change is never the losing
//! side: a bound item follows its source by design. Two changes by one author
//! never conflict. The write is honoured either way; the overwritten value is
//! kept (at most [`MAX_PER_FIELD`] per item field and [`MAX_PER_BOARD`] per
//! board, the oldest dropped, and counted per item so the pane and the agent
//! can say something older was lost) until the user resolves it or the daemon
//! restarts. Each kept value has a stable id ([`Conflict::id`]): it is how the
//! user names the one they settle, since positions shift.

use std::collections::{HashMap, VecDeque};

use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};

use super::diff::field_value;
use super::model::{bounded, Author, Board, Change, ChangeKind};

/// Two changes this close (or closer) conflict whoever saw what.
pub const WINDOW_SECS: i64 = 10;
/// Losing values kept per (item, field).
pub const MAX_PER_FIELD: usize = 5;
/// Losing values kept per board.
pub const MAX_PER_BOARD: usize = 50;
/// The `field` of a conflict over a removed item.
pub const REMOVED: &str = "removed";

/// One overwritten value, kept.
#[derive(Debug, Clone, PartialEq)]
pub struct Conflict {
    /// Stable for the life of the conflict: `<epoch>.<version>.<n>` (the
    /// board's random epoch, the version it became visible at, and a
    /// per-board counter). Opaque to clients. Empty until recorded. The epoch
    /// keeps an id from a previous run (state lost, versions restarted) from
    /// ever naming a new conflict.
    pub id: String,
    pub item_id: String,
    /// The field, or [`REMOVED`].
    pub field: String,
    /// The value that lost, in full. For [`REMOVED`] the item's exact markdown.
    pub losing: Value,
    pub losing_author: Author,
    pub winning_author: Author,
    /// When the winning write happened.
    pub at: DateTime<Utc>,
    /// [`REMOVED`] only: the removed item's text and section.
    pub title: Option<String>,
    pub section: Option<String>,
    /// [`REMOVED`] only: the items that sat just before and after it in its
    /// section, to put it back in place.
    pub prev: Option<String>,
    pub next: Option<String>,
    /// The board version at which this conflict became visible (the seq of
    /// its log entry); 0 until recorded. A pane that saw version `v` has seen
    /// the conflicts with `version <= v`, and no others.
    pub version: u64,
    /// A guess: the writer's view fell off the log, so the daemon could not
    /// tell whether the value was anyone else's and kept it to be safe. The
    /// board cap drops guesses before real conflicts.
    pub guess: bool,
}

/// A board's live conflicts, oldest first.
#[derive(Debug, Clone, PartialEq)]
pub struct Conflicts {
    list: Vec<Conflict>,
    /// Losing values dropped by a cap since the board was loaded.
    dropped: u32,
    /// The same, per item, until the user settles what is left of its
    /// conflicts: the pane and the agent are told something older was lost.
    dropped_by_item: HashMap<String, u32>,
    /// Numbers the ids of this board's conflicts.
    counter: u64,
    /// Random per board (and per run: conflicts are not persisted); part of
    /// every id.
    epoch: String,
}

impl Default for Conflicts {
    fn default() -> Self {
        Conflicts {
            list: Vec::new(),
            dropped: 0,
            dropped_by_item: HashMap::new(),
            counter: 0,
            epoch: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(),
        }
    }
}

impl Conflicts {
    /// Adds `conflict`, dropping the oldest of its (item, field) beyond
    /// [`MAX_PER_FIELD`] and the oldest of the board beyond [`MAX_PER_BOARD`],
    /// a guess before any real conflict (a stale view changing many items
    /// must not push the one real losing value off the board). Returns what a
    /// cap dropped.
    pub fn push(&mut self, conflict: Conflict) -> Vec<Conflict> {
        let mut dropped = Vec::new();
        self.list.push(conflict);
        let last = self.list.last().expect("just pushed");
        let (id, field) = (last.item_id.clone(), last.field.clone());
        let same: Vec<usize> = self
            .list
            .iter()
            .enumerate()
            .filter(|(_, c)| c.item_id == id && c.field == field)
            .map(|(i, _)| i)
            .collect();
        if same.len() > MAX_PER_FIELD {
            dropped.push(self.list.remove(Self::oldest_to_drop(&self.list, &same)));
        }
        if self.list.len() > MAX_PER_BOARD {
            let all: Vec<usize> = (0..self.list.len()).collect();
            dropped.push(self.list.remove(Self::oldest_to_drop(&self.list, &all)));
        }
        for gone in &dropped {
            self.count_dropped(&gone.item_id);
        }
        dropped
    }

    /// Of the candidate positions (oldest first): the oldest guess, else the
    /// oldest.
    fn oldest_to_drop(list: &[Conflict], candidates: &[usize]) -> usize {
        candidates
            .iter()
            .copied()
            .find(|&i| list[i].guess)
            .unwrap_or(candidates[0])
    }

    fn count_dropped(&mut self, item_id: &str) {
        self.dropped = self.dropped.saturating_add(1);
        let n = self.dropped_by_item.entry(item_id.to_string()).or_default();
        *n = n.saturating_add(1);
    }

    /// The user acknowledges `count` dropped losing values of `item_id` (what
    /// they were shown): that many are forgotten, never more, so a loss
    /// recorded since stays counted.
    pub fn ack_dropped(&mut self, item_id: &str, count: u32) {
        if let Some(n) = self.dropped_by_item.get_mut(item_id) {
            *n = n.saturating_sub(count);
            if *n == 0 {
                self.dropped_by_item.remove(item_id);
            }
        }
    }

    /// This board's epoch for this run (new on every daemon run): the pane
    /// sends the one it saw as `base_epoch`, so a `base_version` from another
    /// run (after a restart, or the state was lost or rolled back) is judged
    /// as having seen nothing of this log.
    pub fn epoch(&self) -> &str {
        &self.epoch
    }

    /// The conflict with this stable id.
    pub fn get(&self, id: &str) -> Option<&Conflict> {
        (!id.is_empty())
            .then(|| self.list.iter().find(|c| c.id == id))
            .flatten()
    }

    /// All conflicts, oldest first.
    pub fn all(&self) -> &[Conflict] {
        &self.list
    }

    /// The losing values of `field` of `item_id`, oldest first.
    pub fn of_field(&self, item_id: &str, field: &str) -> Vec<&Conflict> {
        self.list
            .iter()
            .filter(|c| c.item_id == item_id && c.field == field)
            .collect()
    }

    /// Settles the removal conflicts of `item_id` whose kept markdown is
    /// `block` (the user put exactly those bytes back).
    pub fn clear_removed_matching(&mut self, item_id: &str, block: &str) {
        self.list.retain(|c| {
            !(c.item_id == item_id
                && c.field == REMOVED
                && c.losing.as_str().map(str::trim_end) == Some(block.trim_end()))
        });
    }

    /// Settles the conflict with this id (one losing value) and nothing else:
    /// the others of its field, and any recorded since the user looked, stay.
    /// When an item has none left, its dropped count is forgotten too.
    pub fn clear(&mut self, id: &str) {
        let Some(pos) = self.list.iter().position(|c| c.id == id) else {
            return;
        };
        let gone = self.list.remove(pos);
        if !self.list.iter().any(|c| c.item_id == gone.item_id) {
            self.dropped_by_item.remove(&gone.item_id);
        }
    }

    /// Stamps the conflicts recorded without a version with `version` and
    /// gives each its id.
    pub fn stamp_unversioned(&mut self, version: u64) {
        for c in self.list.iter_mut().filter(|c| c.version == 0) {
            c.version = version;
            c.id = format!("{}.{version}.{}", self.epoch, self.counter);
            self.counter += 1;
        }
    }

    /// How many losing values of `item_id` a cap has dropped, until the user
    /// settles what is kept of it.
    pub fn dropped_for(&self, item_id: &str) -> u32 {
        self.dropped_by_item.get(item_id).copied().unwrap_or(0)
    }

    /// [`Self::dropped_for`] for every item with a count.
    pub fn dropped_by_item(&self) -> &HashMap<String, u32> {
        &self.dropped_by_item
    }

    /// How many losing values a cap has dropped.
    pub fn dropped(&self) -> u32 {
        self.dropped
    }

    pub fn is_empty(&self) -> bool {
        self.list.is_empty()
    }
}

/// What a write knew when it was made.
#[derive(Debug, Clone, Copy)]
pub struct Detect<'a> {
    pub writer: &'a Author,
    /// Pane: the `base_version` of the edit. Agent: the session's read
    /// cursor, `Some(0)` when it never read (it has seen nothing). `None`:
    /// no notion of reading (a file save), only rule (a) applies.
    pub seen_through: Option<u64>,
    /// Changes at or before `seen_through` the writer was told only were
    /// hidden (withheld text): it has not seen them.
    pub unseen: &'a [u64],
    /// The pane connection making the write (daemon-assigned); `None` for any
    /// other author.
    pub client: Option<&'a str>,
    /// The log no longer reaches back to `seen_through` (see
    /// [`super::changelog::ChangeLog::history_gap`]): a field with no logged
    /// history may have been changed by something that fell off the log.
    pub history_gap: bool,
    /// `(item, field)` pairs the writer is settling by putting a losing value
    /// back: a change to one of them that `seen_through` covers is the
    /// decision's own premise, not a competing edit. Anything after
    /// `seen_through` still conflicts.
    pub resolving: &'a [(String, String)],
    pub now: DateTime<Utc>,
}

/// The conflicts `changes` (a write by `d.writer`, diffed from `old`) make
/// with what `prior` (the log before this write) says. `source_of` gives a
/// removed item's exact markdown.
pub fn detect(
    prior: &VecDeque<Change>,
    changes: &[Change],
    old: &Board,
    source_of: &dyn Fn(&str) -> Option<String>,
    d: &Detect<'_>,
) -> Vec<Conflict> {
    if matches!(d.writer, Author::Source { .. }) {
        return Vec::new();
    }
    let mut out = Vec::new();
    for change in changes {
        let Some(id) = change.item_id.as_deref() else {
            continue;
        };
        match change.kind {
            ChangeKind::Changed => {
                for (field, (_, new)) in &change.fields {
                    let last = latest(prior, id, Some(field));
                    let mut guess = false;
                    let losing_author = match last {
                        Some(last) => {
                            let settled = d.seen_through.is_some_and(|seen| last.seq <= seen)
                                && !d.unseen.contains(&last.seq)
                                && d.resolving.iter().any(|(i, f)| i == id && f == field);
                            if settled || !conflicts(last, d, || reverts(prior, id, field, new)) {
                                continue;
                            }
                            last.by.clone()
                        }
                        // Nothing logged: with the history gone, the value
                        // may be someone else's; keep it.
                        None if gap_overwrite(d) => {
                            guess = true;
                            Author::File
                        }
                        None => continue,
                    };
                    let losing = old
                        .item(id)
                        .map(|item| field_value(item, field))
                        .unwrap_or_else(|| change.fields[field].0.clone());
                    out.push(Conflict {
                        id: String::new(),
                        item_id: id.to_string(),
                        field: field.clone(),
                        losing,
                        losing_author,
                        winning_author: d.writer.clone(),
                        at: d.now,
                        title: None,
                        section: None,
                        prev: None,
                        next: None,
                        version: 0,
                        guess,
                    });
                }
            }
            ChangeKind::Removed => {
                // The item carries every field's latest value, so any other
                // author's unseen (or recent) change to it is overwritten. A
                // file that drops an item someone else touched is the
                // stale-copy signature at any age.
                let found = prior.iter().rev().find(|c| {
                    c.item_id.as_deref() == Some(id)
                        && matches!(c.kind, ChangeKind::Changed | ChangeKind::Added)
                        && conflicts(c, d, || true)
                });
                // Only an item the log saw born has a whole known history; any
                // other has values from before the log (or before a gap in it)
                // that no entry attributes, even when the writer's own edits
                // since then are logged.
                let born_in_log = prior
                    .iter()
                    .any(|c| c.item_id.as_deref() == Some(id) && c.kind == ChangeKind::Added);
                let guess = found.is_none();
                let losing_author = match found {
                    Some(last) => last.by.clone(),
                    None if !born_in_log && gap_overwrite(d) => Author::File,
                    None => continue,
                };
                let Some(source) = source_of(id) else {
                    continue;
                };
                let item = old.item(id);
                let (prev, next) = neighbours(old, id);
                out.push(Conflict {
                    id: String::new(),
                    item_id: id.to_string(),
                    field: REMOVED.to_string(),
                    losing: json!(source),
                    losing_author,
                    winning_author: d.writer.clone(),
                    at: d.now,
                    title: item.map(|i| i.text.clone()),
                    section: item.map(|i| i.section.clone()),
                    prev,
                    next,
                    version: 0,
                    guess,
                });
            }
            _ => {}
        }
    }
    out
}

/// The ids just before and after `id` in its section of `board`.
fn neighbours(board: &Board, id: &str) -> (Option<String>, Option<String>) {
    let Some(pos) = board.items.iter().position(|i| i.id == id) else {
        return (None, None);
    };
    let section = &board.items[pos].section;
    let same = |i: &&super::model::Item| &i.section == section;
    let prev = pos
        .checked_sub(1)
        .and_then(|p| board.items.get(p))
        .filter(same)
        .map(|i| i.id.clone());
    let next = board.items.get(pos + 1).filter(same).map(|i| i.id.clone());
    (prev, next)
}

/// The log entry an agent reads for `conflict`: attributed to the winner.
/// `dropped` is how many older losing values of the item a cap has dropped;
/// the entry says so when it is not 0.
pub fn change_for(conflict: &Conflict, kept: &Value, dropped: u32) -> Change {
    let change = Change::new(
        &conflict.winning_author,
        Some(&conflict.item_id),
        ChangeKind::Conflict,
        conflict.at,
    )
    .with_field("field", json!(conflict.field), Value::Null)
    .with_field("value", conflict.losing.clone(), kept.clone())
    .with_field(
        "lost_by",
        json!(conflict.losing_author.label()),
        Value::Null,
    );
    if dropped == 0 {
        return change;
    }
    change.with_field("dropped_conflicts", json!(dropped), Value::Null)
}

/// The log entry that tells an agent a cap dropped older losing values of
/// `item_id` (`dropped` in all, until the user settles it): attributed to the
/// write that pushed them off. It carries no value of its own.
pub fn change_for_dropped(item_id: &str, by: &Conflict, dropped: u32) -> Change {
    Change::new(
        &by.winning_author,
        Some(item_id),
        ChangeKind::Conflict,
        by.at,
    )
    .with_field("dropped_conflicts", json!(dropped), Value::Null)
}

/// Does `last` (the latest other-author change to what `d.writer` is writing)
/// conflict with the write? `stale_file` is rule (b) for a file save.
fn conflicts(last: &Change, d: &Detect<'_>, stale_file: impl FnOnce() -> bool) -> bool {
    let same_writer = &last.by == d.writer && last.client.as_deref() == d.client;
    if same_writer || matches!(last.by, Author::Source { .. }) {
        return false;
    }
    if d.now - last.at <= Duration::seconds(WINDOW_SECS) {
        return true;
    }
    match d.writer {
        Author::File => stale_file(),
        _ => d
            .seen_through
            .is_some_and(|seen| last.seq > seen || d.unseen.contains(&last.seq)),
    }
}

/// A pane or agent write whose reading position fell off the log: what it
/// overwrites with no logged history is not known to be its own.
fn gap_overwrite(d: &Detect<'_>) -> bool {
    d.history_gap && matches!(d.writer, Author::Pane | Author::Agent { .. })
}

/// The latest change to `field` of item `id` (any field when `None`), made
/// by an add or an edit. Earlier conflict entries are not changes.
fn latest<'a>(prior: &'a VecDeque<Change>, id: &str, field: Option<&str>) -> Option<&'a Change> {
    prior.iter().rev().find(|c| {
        c.item_id.as_deref() == Some(id)
            && match c.kind {
                ChangeKind::Changed | ChangeKind::Added => {
                    field.is_none_or(|f| c.fields.contains_key(f))
                }
                _ => false,
            }
    })
}

/// Did `field` of item `id` hold `value` before one of the logged changes?
/// Then a save setting it back is what a stale copy does. A value leaves a
/// field by an edit (the old value of a `Changed`) or with the item, by a
/// removal (a `Removed` carries the values the item held). A move or a
/// restore changes no value another way: a restore is an edit. (Compared in
/// the logged form: values are bounded when logged.)
fn reverts(prior: &VecDeque<Change>, id: &str, field: &str, value: &Value) -> bool {
    let value = bounded(value.clone());
    prior.iter().any(|c| {
        c.item_id.as_deref() == Some(id)
            && matches!(c.kind, ChangeKind::Changed | ChangeKind::Removed)
            && c.fields.get(field).is_some_and(|(old, _)| *old == value)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::model::Item;
    use chrono::TimeZone;

    fn at(secs: i64) -> DateTime<Utc> {
        Utc.timestamp_opt(1_760_000_000 + secs, 0).unwrap()
    }

    fn agent(name: &str) -> Author {
        Author::Agent {
            focus: "f".into(),
            session_id: format!("s-{name}"),
            name: name.into(),
        }
    }

    fn status_change(by: &Author, id: &str, old: &str, new: &str, secs: i64, seq: u64) -> Change {
        let mut c = Change::new(by, Some(id), ChangeKind::Changed, at(secs)).with_field(
            "status",
            json!(old),
            json!(new),
        );
        c.seq = seq;
        c
    }

    fn board() -> Board {
        let mut b = Board::default();
        let mut item = Item::new("a", "now", "Deploy");
        item.status = crate::tracker::Status::Done;
        b.items.push(item);
        b
    }

    fn run(
        prior: Vec<Change>,
        write: Change,
        writer: &Author,
        seen: Option<u64>,
        secs: i64,
    ) -> Vec<Conflict> {
        detect(
            &prior.into_iter().collect(),
            &[write],
            &board(),
            &|_| Some("- [x] Deploy\n".to_string()),
            &Detect {
                writer,
                seen_through: seen,
                unseen: &[],
                client: None,
                history_gap: false,
                resolving: &[],
                now: at(secs),
            },
        )
    }

    #[test]
    fn rule_a_a_change_within_ten_seconds_conflicts_even_when_seen() {
        let (pane, ag) = (Author::Pane, agent("claudia"));
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 1)];
        let write = status_change(&ag, "a", "done", "in-progress", 10, 0);
        let got = run(prior.clone(), write, &ag, Some(1), 10);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].losing, json!("done"));
        assert_eq!(got[0].losing_author, pane);
        assert_eq!(got[0].winning_author, ag);
        let late = status_change(&ag, "a", "done", "in-progress", 11, 0);
        assert!(run(prior, late, &ag, Some(1), 11).is_empty());
    }

    #[test]
    fn rule_b_pane_a_change_after_the_base_version_conflicts_at_any_age() {
        let (ag, pane) = (agent("claudia"), Author::Pane);
        let prior = vec![status_change(&ag, "a", "todo", "in-progress", 0, 5)];
        let write = status_change(&pane, "a", "in-progress", "done", 300, 0);
        assert_eq!(
            run(prior.clone(), write.clone(), &pane, Some(4), 300).len(),
            1
        );
        assert!(run(prior, write, &pane, Some(5), 300).is_empty());
    }

    #[test]
    fn rule_b_agent_a_change_after_its_cursor_conflicts_at_any_age() {
        let (pane, ag) = (Author::Pane, agent("claudia"));
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 3)];
        let write = status_change(&ag, "a", "done", "in-progress", 300, 0);
        assert_eq!(
            run(prior.clone(), write.clone(), &ag, Some(2), 300).len(),
            1
        );
        assert!(run(prior.clone(), write.clone(), &ag, Some(3), 300).is_empty());
        // Never read (the daemon passes cursor 0): it has seen nothing.
        assert_eq!(
            run(prior.clone(), write.clone(), &ag, Some(0), 300).len(),
            1
        );
        // No notion of reading: only the ten-second rule applies.
        assert!(run(prior, write, &ag, None, 300).is_empty());
    }

    #[test]
    fn rule_b_file_a_save_that_reverts_a_value_conflicts_at_any_age() {
        let (pane, file) = (Author::Pane, Author::File);
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 3)];
        let revert = status_change(&file, "a", "done", "todo", 300, 0);
        assert_eq!(run(prior.clone(), revert, &file, None, 300).len(), 1);
        // A fresh value is a deliberate edit, not a stale copy.
        let fresh = status_change(&file, "a", "done", "blocked", 300, 0);
        assert!(run(prior, fresh, &file, None, 300).is_empty());
    }

    /// A `Removed` change as the diff logs it: every field's value at removal.
    fn removal_with(by: &Author, id: &str, note: Value, secs: i64, seq: u64) -> Change {
        let mut c = Change::new(by, Some(id), ChangeKind::Removed, at(secs))
            .with_field("text", json!("Deploy"), Value::Null)
            .with_field("note", note, Value::Null);
        c.seq = seq;
        c
    }

    fn note_change(by: &Author, id: &str, old: Value, new: Value, secs: i64, seq: u64) -> Change {
        let mut c =
            Change::new(by, Some(id), ChangeKind::Changed, at(secs)).with_field("note", old, new);
        c.seq = seq;
        c
    }

    /// The lost edit: the note was "moved", the item was removed and brought
    /// back without it, the user typed "user-note", and a stale save sets
    /// the note back to "moved".
    fn removal_history() -> Vec<Change> {
        let (pane, ag, file) = (Author::Pane, agent("claudia"), Author::File);
        let mut added = Change::new(&file, Some("a"), ChangeKind::Added, at(2));
        added.seq = 3;
        vec![
            note_change(&pane, "a", Value::Null, json!("moved"), 0, 1),
            removal_with(&ag, "a", json!("moved"), 1, 2),
            added,
            note_change(&pane, "a", Value::Null, json!("user-note"), 4, 4),
        ]
    }

    #[test]
    fn rule_b_file_a_save_that_restores_a_value_a_removal_took_off_conflicts() {
        let file = Author::File;
        let revert = note_change(&file, "a", json!("user-note"), json!("moved"), 300, 0);
        let got = run(removal_history(), revert, &file, None, 300);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].field, "note");
        // A value the item never held is a deliberate edit.
        let fresh = note_change(&file, "a", json!("user-note"), json!("fresh"), 300, 0);
        assert!(run(removal_history(), fresh, &file, None, 300).is_empty());
    }

    #[test]
    fn a_removal_of_another_item_does_not_make_a_value_a_revert() {
        let file = Author::File;
        let mut prior = removal_history();
        prior[1].item_id = Some("other".into());
        let revert = note_change(&file, "a", json!("user-note"), json!("moved"), 300, 0);
        assert!(run(prior, revert, &file, None, 300).is_empty());
    }

    #[test]
    fn a_value_cut_to_the_logged_bound_is_still_recognised_after_a_removal() {
        let file = Author::File;
        let long = "x".repeat(crate::tracker::model::MAX_LOGGED_CHARS + 50);
        let (pane, ag) = (Author::Pane, agent("claudia"));
        let prior = vec![
            removal_with(&ag, "a", json!(long), 1, 1),
            note_change(&pane, "a", Value::Null, json!("user-note"), 4, 2),
        ];
        let revert = note_change(&file, "a", json!("user-note"), json!(long), 300, 0);
        assert_eq!(run(prior.clone(), revert, &file, None, 300).len(), 1);
        let different = "z".repeat(crate::tracker::model::MAX_LOGGED_CHARS + 50);
        let prior = vec![
            removal_with(&ag, "a", json!(long), 1, 1),
            note_change(&pane, "a", Value::Null, json!("user-note"), 4, 2),
        ];
        let fresh = note_change(&file, "a", json!("user-note"), json!(different), 300, 0);
        assert!(run(prior, fresh, &file, None, 300).is_empty());
    }

    #[test]
    fn reverts_compares_an_unbounded_value_in_its_logged_form() {
        let ag = agent("claudia");
        let long = "x".repeat(crate::tracker::model::MAX_LOGGED_CHARS + 50);
        let prior: VecDeque<Change> = vec![removal_with(&ag, "a", json!(long), 1, 1)].into();
        assert!(reverts(&prior, "a", "note", &json!(long)));
        assert!(!reverts(&prior, "a", "note", &json!("other")));
        let edit: VecDeque<Change> =
            vec![note_change(&ag, "a", json!(long), json!("n"), 1, 1)].into();
        assert!(reverts(&edit, "a", "note", &json!(long)));
    }

    #[test]
    fn a_restore_text_value_and_a_moved_item_leave_values_the_log_still_knows() {
        // A restore (`restore_text`) is an ordinary Changed: its old value
        // is what a stale save reverts to. A move changes no field value.
        let (pane, file) = (Author::Pane, Author::File);
        let mut moved = Change::new(&pane, Some("a"), ChangeKind::Moved, at(5)).with_field(
            "section",
            json!("now"),
            json!("later"),
        );
        moved.seq = 3;
        let mut restore = Change::new(&pane, Some("a"), ChangeKind::Changed, at(4)).with_field(
            "text",
            json!("Long original"),
            json!("Short"),
        );
        restore.seq = 2;
        let prior = vec![
            note_change(&pane, "a", Value::Null, json!("n1"), 0, 1),
            restore,
            moved,
            note_change(&pane, "a", json!("n1"), json!("n2"), 6, 4),
        ];
        let back = Change::new(&file, Some("a"), ChangeKind::Changed, at(300)).with_field(
            "text",
            json!("Short"),
            json!("Long original"),
        );
        let mut p2 = prior.clone();
        p2.push({
            let mut c = Change::new(&pane, Some("a"), ChangeKind::Changed, at(7)).with_field(
                "text",
                json!("x"),
                json!("Short"),
            );
            c.seq = 5;
            c
        });
        assert_eq!(run(p2, back, &file, None, 300).len(), 1);
        // A moved item's old section is not a field value anyone reverts to.
        let sec = Change::new(&file, Some("a"), ChangeKind::Changed, at(300)).with_field(
            "note",
            json!("n2"),
            json!("later"),
        );
        assert!(run(prior, sec, &file, None, 300).is_empty());
    }

    #[test]
    fn a_source_change_never_conflicts_on_either_side() {
        let (src, pane) = (
            Author::Source {
                name: "pr.ci".into(),
            },
            Author::Pane,
        );
        let prior = vec![status_change(&src, "a", "todo", "done", 0, 1)];
        let write = status_change(&pane, "a", "done", "todo", 1, 0);
        assert!(run(prior, write, &pane, Some(0), 1).is_empty());
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 1)];
        let write = status_change(&src, "a", "done", "todo", 1, 0);
        assert!(run(prior, write, &src, None, 1).is_empty());
    }

    #[test]
    fn one_author_never_conflicts_with_itself() {
        let pane = Author::Pane;
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 1)];
        let write = status_change(&pane, "a", "done", "todo", 1, 0);
        assert!(run(prior, write, &pane, Some(0), 1).is_empty());
    }

    #[test]
    fn removing_an_item_someone_just_edited_keeps_its_markdown() {
        let (pane, ag) = (Author::Pane, agent("claudia"));
        let prior = vec![status_change(&pane, "a", "todo", "done", 0, 1)];
        let mut removed = Change::new(&ag, Some("a"), ChangeKind::Removed, at(3));
        removed = removed.with_field("text", json!("Deploy"), Value::Null);
        let got = run(prior, removed, &ag, Some(1), 3);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].field, REMOVED);
        assert_eq!(got[0].losing, json!("- [x] Deploy\n"));
        assert_eq!(got[0].title.as_deref(), Some("Deploy"));
    }

    /// `writer` removes item `a` with the log not reaching back to what it read.
    fn remove_across_a_gap(prior: Vec<Change>, writer: &Author) -> Vec<Conflict> {
        let removed = removal_with(writer, "a", Value::Null, 100, 0);
        detect(
            &prior.into_iter().collect(),
            &[removed],
            &board(),
            &|_| Some("- [x] Deploy\n".to_string()),
            &Detect {
                writer,
                seen_through: Some(0),
                unseen: &[],
                client: None,
                history_gap: true,
                resolving: &[],
                now: at(100),
            },
        )
    }

    #[test]
    fn removing_an_item_across_a_gap_keeps_it_unless_the_log_saw_it_born() {
        let pane = Author::Pane;
        // The writer's own edit since the log restarted says nothing of the
        // values the item held before.
        let own_edit = vec![status_change(&pane, "a", "todo", "done", 50, 1)];
        let got = remove_across_a_gap(own_edit, &pane);
        assert_eq!(got.len(), 1);
        assert!(got[0].guess);
        // An item the log saw added has no values from before the log.
        let mut added = Change::new(&pane, Some("a"), ChangeKind::Added, at(40));
        added.seq = 1;
        assert!(remove_across_a_gap(vec![added], &pane).is_empty());
    }

    #[test]
    fn the_caps_drop_the_oldest_and_count_it() {
        let mut conflicts = Conflicts::default();
        let make = |item: &str, field: &str, n: usize| Conflict {
            id: String::new(),
            item_id: item.into(),
            field: field.into(),
            losing: json!(n),
            losing_author: Author::Pane,
            winning_author: Author::File,
            at: at(n as i64),
            title: None,
            section: None,
            prev: None,
            next: None,
            version: 0,
            guess: false,
        };
        for n in 0..(MAX_PER_FIELD + 2) {
            conflicts.push(make("a", "status", n));
        }
        let kept = conflicts.of_field("a", "status");
        assert_eq!(kept.len(), MAX_PER_FIELD);
        assert_eq!(kept[0].losing, json!(2));
        assert_eq!(conflicts.dropped(), 2);
        let mut conflicts = Conflicts::default();
        for n in 0..(MAX_PER_BOARD + 3) {
            conflicts.push(make(&format!("i{n}"), "status", n));
        }
        assert_eq!(conflicts.all().len(), MAX_PER_BOARD);
        assert_eq!(conflicts.all()[0].item_id, "i3");
        assert_eq!(conflicts.dropped(), 3);
    }
}
