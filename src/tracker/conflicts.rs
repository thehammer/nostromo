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
//!   - file: the save sets F back to a value F once had (a stale editor copy),
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
    /// Stable for the life of the conflict: `<version>.<n>` (the version it
    /// became visible at, and a per-board counter). Empty until recorded.
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
}

/// A board's live conflicts, oldest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Conflicts {
    list: Vec<Conflict>,
    /// Losing values dropped by a cap since the board was loaded.
    dropped: u32,
    /// The same, per item, until the user settles what is left of its
    /// conflicts: the pane and the agent are told something older was lost.
    dropped_by_item: HashMap<String, u32>,
    /// Numbers the ids of this board's conflicts.
    counter: u64,
}

impl Conflicts {
    /// Adds `conflict`, dropping the oldest of its (item, field) beyond
    /// [`MAX_PER_FIELD`] and the oldest of the board beyond [`MAX_PER_BOARD`].
    pub fn push(&mut self, conflict: Conflict) {
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
            let gone = self.list.remove(same[0]);
            self.count_dropped(gone.item_id);
        }
        if self.list.len() > MAX_PER_BOARD {
            let gone = self.list.remove(0);
            self.count_dropped(gone.item_id);
        }
    }

    fn count_dropped(&mut self, item_id: String) {
        self.dropped += 1;
        *self.dropped_by_item.entry(item_id).or_default() += 1;
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
            c.id = format!("{version}.{}", self.counter);
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
                    let losing_author = match last {
                        Some(last) => {
                            let settled = d.seen_through.is_some_and(|seen| last.seq <= seen)
                                && d.resolving.iter().any(|(i, f)| i == id && f == field);
                            if settled || !conflicts(last, d, || reverts(prior, id, field, new)) {
                                continue;
                            }
                            last.by.clone()
                        }
                        // Nothing logged: with the history gone, the value
                        // may be someone else's; keep it.
                        None if gap_overwrite(d) => Author::File,
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
                let touched = prior.iter().any(|c| {
                    c.item_id.as_deref() == Some(id)
                        && matches!(c.kind, ChangeKind::Changed | ChangeKind::Added)
                });
                let losing_author = match found {
                    Some(last) => last.by.clone(),
                    None if !touched && gap_overwrite(d) => Author::File,
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
        _ => d.seen_through.is_some_and(|seen| last.seq > seen),
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
/// Then a save setting it back is what a stale copy does. (Compared in the
/// logged form: values are bounded when logged.)
fn reverts(prior: &VecDeque<Change>, id: &str, field: &str, value: &Value) -> bool {
    let value = bounded(value.clone());
    prior.iter().any(|c| {
        c.item_id.as_deref() == Some(id)
            && c.kind == ChangeKind::Changed
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
