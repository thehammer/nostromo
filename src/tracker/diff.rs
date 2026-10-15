//! Board × Board → attributed field-level changes, and the three-way merge
//! used when an external edit lands under one of our writes (contract §3.2).

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use super::format::lcs;
use super::model::{Author, Board, Change, ChangeKind, Item, Kind, Status};

/// The changes that turn `old` into `new`: sections added/renamed/removed,
/// items removed, then per item in `new` order added / moved (section change
/// or reorder) / changed (one change listing every changed field,
/// `updated_at` excluded), then Log lines appended.
pub fn diff(old: &Board, new: &Board, author: &Author, now: DateTime<Utc>) -> Vec<Change> {
    let mut out = Vec::new();
    let renamed = section_changes(old, new, author, now, &mut out);
    let old_items: HashMap<&str, &Item> = old.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let new_ids: HashSet<&str> = new.items.iter().map(|i| i.id.as_str()).collect();

    for item in old.items.iter().filter(|i| !new_ids.contains(i.id.as_str())) {
        out.push(
            Change::new(author, Some(&item.id), ChangeKind::Removed, now)
                .with_field("section", json!(item.section), Value::Null)
                .with_field("text", json!(item.text), Value::Null),
        );
    }

    let reordered = reordered_items(old, new, &renamed);
    for item in &new.items {
        let Some(prev) = old_items.get(item.id.as_str()) else {
            out.push(added(item, author, now));
            continue;
        };
        let prev_section = renamed.get(prev.section.as_str()).copied().unwrap_or(&prev.section);
        if prev_section != item.section || reordered.contains(item.id.as_str()) {
            out.push(
                Change::new(author, Some(&item.id), ChangeKind::Moved, now).with_field(
                    "section",
                    json!(prev.section),
                    json!(item.section),
                ),
            );
        }
        let fields = changed_fields(prev, item);
        if !fields.is_empty() {
            let mut change = Change::new(author, Some(&item.id), ChangeKind::Changed, now);
            for (name, old_value, new_value) in fields {
                change = change.with_field(name, old_value, new_value);
            }
            out.push(change);
        }
    }

    for line in appended_log(old, new) {
        out.push(
            Change::new(author, None, ChangeKind::Log, now).with_field(
                "text",
                Value::Null,
                json!(format!("{} {}", line.time, line.text)),
            ),
        );
    }
    out
}

/// The item fields a diff and a merge compare (everything but id, section
/// and `updated_at`), as JSON values.
fn field_values(item: &Item) -> [(&'static str, Value); 9] {
    [
        ("text", json!(item.text)),
        ("status", json!(item.status)),
        ("owner", json!(item.owner)),
        ("note", json!(item.note)),
        ("links", json!(item.links)),
        ("kind", json!(item.kind)),
        ("command", json!(item.command)),
        ("env", json!(item.env)),
        ("bind", json!(item.bind)),
    ]
}

fn changed_fields(old: &Item, new: &Item) -> Vec<(&'static str, Value, Value)> {
    field_values(old)
        .into_iter()
        .zip(field_values(new))
        .filter(|((_, a), (_, b))| a != b)
        .map(|((name, a), (_, b))| (name, a, b))
        .collect()
}

/// An `Added` change carrying the new item's section, text and every
/// non-default field.
fn added(item: &Item, author: &Author, now: DateTime<Utc>) -> Change {
    let mut change = Change::new(author, Some(&item.id), ChangeKind::Added, now)
        .with_field("section", Value::Null, json!(item.section));
    let blank = Item {
        status: Status::Todo,
        kind: Kind::Item,
        ..Item::new(&item.id, &item.section, "")
    };
    for (name, _, value) in changed_fields(&blank, item) {
        change = change.with_field(name, Value::Null, value);
    }
    change
}

/// Records section changes; returns old id → new id for renamed sections.
/// Sections are matched by id; unmatched old and new sections are paired in
/// order as renames, the rest are removals or additions.
fn section_changes<'a>(
    old: &'a Board,
    new: &'a Board,
    author: &Author,
    now: DateTime<Utc>,
    out: &mut Vec<Change>,
) -> HashMap<&'a str, &'a str> {
    let new_ids: HashSet<&str> = new.sections.iter().map(|s| s.id.as_str()).collect();
    let old_ids: HashSet<&str> = old.sections.iter().map(|s| s.id.as_str()).collect();
    let mut gone = old.sections.iter().filter(|s| !new_ids.contains(s.id.as_str()));
    let mut fresh = new.sections.iter().filter(|s| !old_ids.contains(s.id.as_str()));
    let mut renamed = HashMap::new();
    let section = |id_old: Value, id_new: Value, t_old: Value, t_new: Value| {
        Change::new(author, None, ChangeKind::Section, now)
            .with_field("id", id_old, id_new)
            .with_field("title", t_old, t_new)
    };
    loop {
        match (gone.next(), fresh.next()) {
            (Some(o), Some(n)) => {
                renamed.insert(o.id.as_str(), n.id.as_str());
                out.push(section(json!(o.id), json!(n.id), json!(o.title), json!(n.title)));
            }
            (Some(o), None) => out.push(section(json!(o.id), Value::Null, json!(o.title), Value::Null)),
            (None, Some(n)) => out.push(section(Value::Null, json!(n.id), Value::Null, json!(n.title))),
            (None, None) => break,
        }
    }
    for n in &new.sections {
        if let Some(o) = old.sections.iter().find(|o| o.id == n.id && o.title != n.title) {
            out.push(section(json!(o.id), json!(n.id), json!(o.title), json!(n.title)));
        }
    }
    renamed
}

/// Items that stayed in their (possibly renamed) section but whose order
/// relative to the section's other surviving items changed.
fn reordered_items<'a>(old: &'a Board, new: &'a Board, renamed: &HashMap<&str, &str>) -> HashSet<&'a str> {
    let new_section: HashMap<&str, &str> =
        new.items.iter().map(|i| (i.id.as_str(), i.section.as_str())).collect();
    let mut out = HashSet::new();
    for section in &new.sections {
        let stayed = |item: &&Item| {
            let old_section = renamed.get(item.section.as_str()).copied().unwrap_or(&item.section);
            old_section == section.id && new_section.get(item.id.as_str()) == Some(&section.id.as_str())
        };
        let before: Vec<&str> = old.items.iter().filter(stayed).map(|i| i.id.as_str()).collect();
        let before_set: HashSet<&str> = before.iter().copied().collect();
        let after: Vec<&str> = new
            .items
            .iter()
            .filter(|i| i.section == section.id && before_set.contains(i.id.as_str()))
            .map(|i| i.id.as_str())
            .collect();
        let keep = lcs(&before, &after);
        out.extend(after.into_iter().filter(|id| !keep.contains(id)));
    }
    out
}

/// Log lines in `new` that `old` doesn't have: the suffix when `old` is a
/// prefix, else every line not matched one-for-one in `old`.
fn appended_log<'a>(old: &Board, new: &'a Board) -> Vec<&'a super::model::LogLine> {
    if new.log.starts_with(&old.log) {
        return new.log[old.log.len()..].iter().collect();
    }
    let mut remaining: Vec<&super::model::LogLine> = old.log.iter().collect();
    new.log
        .iter()
        .filter(|line| match remaining.iter().position(|o| o == line) {
            Some(pos) => {
                remaining.remove(pos);
                false
            }
            None => true,
        })
        .collect()
}

/// Field-level three-way merge. `base` is what both sides started from,
/// `ours` is base plus our ops, `theirs` is the file as it is now. Changes to
/// different items or different fields of one item all survive; where both
/// sides changed the same field, ours wins (it is applied on top of the
/// ingested edit, contract §3.1). A modification beats a deletion. Sections,
/// title and prose come from `theirs`; Log lines we appended follow theirs.
pub fn merge_external(base: &Board, ours: &Board, theirs: &Board) -> Board {
    let base_items: HashMap<&str, &Item> = base.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let our_items: HashMap<&str, &Item> = ours.items.iter().map(|i| (i.id.as_str(), i)).collect();
    let their_ids: HashSet<&str> = theirs.items.iter().map(|i| i.id.as_str()).collect();
    let section_ok = |id: &str| theirs.section(id).is_some();

    // Theirs, with our field changes on top.
    let mut items: Vec<Item> = Vec::new();
    for their in &theirs.items {
        let id = their.id.as_str();
        match (base_items.get(id), our_items.get(id)) {
            (Some(b), Some(o)) => items.push(merge_item(b, o, their, section_ok)),
            (Some(b), None) if *b != their => items.push(their.clone()),
            (Some(_), None) => {}
            (None, Some(o)) => items.push(merge_item(their, o, their, section_ok)),
            (None, None) => items.push(their.clone()),
        }
    }

    // Our additions, items we moved, and items we edited that theirs deleted:
    // placed after their predecessor in our order.
    let base_order: Vec<&str> = base.items.iter().map(|i| i.id.as_str()).collect();
    let our_order: Vec<&str> = ours.items.iter().map(|i| i.id.as_str()).collect();
    let kept = lcs(&base_order, &our_order);
    for (pos, our) in ours.items.iter().enumerate() {
        let id = our.id.as_str();
        let base_item = base_items.get(id);
        let resurrected = !their_ids.contains(id) && base_item.is_some_and(|b| *b != our);
        let added = base_item.is_none() && !their_ids.contains(id);
        let moved = base_item.is_some_and(|b| b.section != our.section) || !kept.contains(id);
        if !(added || resurrected || (moved && their_ids.contains(id))) {
            continue;
        }
        let item = match items.iter().position(|i| i.id == id) {
            Some(existing) => items.remove(existing),
            None => {
                let mut item = our.clone();
                if !section_ok(&item.section) {
                    item.section = theirs.sections.first().map(|s| s.id.clone()).unwrap_or_default();
                }
                item
            }
        };
        let predecessor = ours.items[..pos]
            .iter()
            .rev()
            .filter(|p| p.section == item.section)
            .find_map(|p| items.iter().position(|i| i.id == p.id));
        let at = match predecessor {
            Some(p) => p + 1,
            None => items
                .iter()
                .position(|i| i.section == item.section)
                .unwrap_or(items.len()),
        };
        items.insert(at, item);
    }

    let mut log = theirs.log.clone();
    if ours.log.starts_with(&base.log) {
        log.extend(ours.log[base.log.len()..].iter().cloned());
    }
    Board {
        items,
        log,
        ..theirs.clone()
    }
}

/// One item merged field by field: ours where ours changed it, else theirs.
fn merge_item(base: &Item, ours: &Item, theirs: &Item, section_ok: impl Fn(&str) -> bool) -> Item {
    let mut merged = theirs.clone();
    macro_rules! take_ours_if_changed {
        ($($field:ident),*) => {$(
            if ours.$field != base.$field {
                merged.$field = ours.$field.clone();
            }
        )*};
    }
    take_ours_if_changed!(text, status, owner, note, links, kind, command, env, bind);
    if ours.section != base.section && section_ok(&ours.section) {
        merged.section = ours.section.clone();
    }
    if ours != base {
        merged.updated_at = ours.updated_at.max(theirs.updated_at);
    }
    merged
}
