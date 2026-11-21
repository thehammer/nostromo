//! The pane's way into the board (`ClientMsg::TrackerEdit`, T3a): the user's
//! edits, applied through the same read-modify-write as an agent's, attributed
//! `pane (you)`.
//!
//! A child of `registry`: it uses the registry's private write path.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Value};

use super::{conflicts, BoardEntry, TrackerError, TrackerRegistry, WriteCtx};
use crate::ipc::protocol::{ConflictKeep, TrackerPaneOp, MAX_TRACKER_EDIT_OPS};
use crate::tracker::bindings::with_source_line;
use crate::tracker::changelog::ChangeLog;
use crate::tracker::conflicts::Conflict;
use crate::tracker::model::{generate_id, Author, Board, ChangeKind, Item, Kind};
use crate::tracker::ops::{
    parse_restorable, LinkInput, Op, PaneStep, Restore, Upsert, MAX_NOTE_CHARS,
};

/// The pane connection [`TrackerRegistry::apply_pane_ops`] writes as: one
/// window, for callers that have no connection of their own.
pub const DEFAULT_CLIENT: &str = "pane";

/// What a successful pane edit did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneEditOutcome {
    /// The board version after the edit.
    pub version: u64,
    /// The ids `add` generated, in op order. A removed item put back under a
    /// new id (its old id was taken again) is listed here too, at its op.
    pub created: Vec<String>,
}

/// Why a pane edit changed nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneEditError {
    pub code: String,
    pub reason: Option<String>,
    /// The failing op's position.
    pub index: Option<usize>,
    /// The view the edit was made from is out of date: look again and retry.
    /// `code` stays `invalid_args` for an older client.
    pub stale: bool,
}

impl PaneEditError {
    fn invalid(reason: &str) -> PaneEditError {
        PaneEditError {
            code: "invalid_args".to_string(),
            reason: Some(reason.to_string()),
            index: None,
            stale: false,
        }
    }

    /// `err` with the index of the pane op that made step `step`.
    fn from_tracker(err: TrackerError, origin: &[usize]) -> PaneEditError {
        let op = |index: usize| origin.get(index).copied().unwrap_or(index);
        let (index, reason) = match &err {
            TrackerError::UnknownItem { index, id } => (Some(op(*index)), Some(id.clone())),
            TrackerError::InvalidStatus { index, value } => (Some(op(*index)), Some(value.clone())),
            TrackerError::InvalidArgs { index, reason } | TrackerError::Stale { index, reason } => {
                (index.map(op), Some(reason.clone()))
            }
            TrackerError::Io(why) => (None, Some(why.clone())),
            other => (None, Some(other.to_string())),
        };
        PaneEditError {
            code: err.code().to_string(),
            reason,
            index,
            stale: matches!(err, TrackerError::Stale { .. }),
        }
    }
}

/// What a pane op does besides writing the file.
#[allow(clippy::enum_variant_names)]
enum Effect {
    /// Approves the item as it was when planned: the content the user saw
    /// badged, never what a later op of the same batch makes of it.
    ClearBadge(Box<Item>),
    ClearRemoved {
        id: String,
        block: String,
    },
    /// Settles the conflict with this stable id.
    ClearConflict(String),
    /// Forgets this many dropped losing values of the item (what the user was
    /// shown).
    AckDropped {
        id: String,
        count: u32,
    },
}

impl TrackerRegistry {
    /// Applies the user's `ops` to the board bound to `tag`, all or none,
    /// attributed to `pane (you)`. `base_version` is the board version the
    /// edit was made against: a field someone else changed after it is a
    /// conflict (the later value is written, the earlier one is kept).
    pub fn apply_pane_ops(
        &self,
        tag: &str,
        base_version: u64,
        ops: &[TrackerPaneOp],
    ) -> Result<PaneEditOutcome, PaneEditError> {
        self.apply_pane_ops_as(tag, DEFAULT_CLIENT, base_version, ops)
    }

    /// [`Self::apply_pane_ops`] for the pane connection `client` (assigned by
    /// the daemon, never by the app). Every window is `pane (you)` to an agent,
    /// but a change by one window is news to another: it conflicts with a
    /// write the other made after its view.
    pub fn apply_pane_ops_as(
        &self,
        tag: &str,
        client: &str,
        base_version: u64,
        ops: &[TrackerPaneOp],
    ) -> Result<PaneEditOutcome, PaneEditError> {
        self.apply_pane_ops_in(tag, client, base_version, None, ops)
    }

    /// [`Self::apply_pane_ops_as`] for a view of the board's run `base_epoch`
    /// (the view's `epoch`): when it is not this board's current one, the
    /// `base_version` counts another log (the daemon's state was lost or rolled
    /// back) and the edit has seen nothing of this one. `None` (an older pane)
    /// trusts `base_version`.
    pub fn apply_pane_ops_in(
        &self,
        tag: &str,
        client: &str,
        base_version: u64,
        base_epoch: Option<&str>,
        ops: &[TrackerPaneOp],
    ) -> Result<PaneEditOutcome, PaneEditError> {
        if ops.is_empty() || ops.len() > MAX_TRACKER_EDIT_OPS {
            return Err(PaneEditError::invalid(&format!(
                "a tracker edit holds 1 to {MAX_TRACKER_EDIT_OPS} ops, got {}",
                ops.len()
            )));
        }
        let mut guard = self.lock();
        let inner = &mut *guard;
        let no_tracker = |e: TrackerError| PaneEditError::from_tracker(e, &[]);
        let path = inner
            .bindings
            .get(tag)
            .cloned()
            .ok_or_else(|| no_tracker(TrackerError::NoTracker))?;
        let entry = inner
            .boards
            .get_mut(&path)
            .ok_or_else(|| no_tracker(TrackerError::NoTracker))?;

        // The conflicts a batch names, as they are now: the ids are stable, so
        // a conflict settled elsewhere or dropped by a cap is simply not here.
        let kept: Vec<Conflict> = entry.conflicts.all().to_vec();
        // The recorded originals of the long texts a `restore_text` names.
        let originals: HashMap<String, String> = ops
            .iter()
            .filter_map(|op| match op {
                TrackerPaneOp::RestoreText { id, .. } => entry
                    .long_texts
                    .get(id)
                    .map(|text| (id.clone(), text.clone())),
                _ => None,
            })
            .collect();
        // Putting a losing value back settles that field's decision; every
        // other op of the batch is still checked against what changed since
        // the user's view.
        let resolving: Vec<(String, String)> = ops
            .iter()
            .filter_map(|op| match op {
                TrackerPaneOp::ResolveConflict {
                    id,
                    field,
                    keep: ConflictKeep::Losing,
                    ..
                } => Some((id.clone(), field.clone())),
                _ => None,
            })
            .collect();
        // Settled before the batch's own conflicts are recorded (see
        // `WriteCtx::settling`).
        let settling: Vec<String> = ops
            .iter()
            .filter_map(|op| match op {
                TrackerPaneOp::ResolveConflict { conflict_id, .. } => conflict_id.clone(),
                _ => None,
            })
            .collect();
        let dropped = entry.conflicts.dropped_by_item().clone();
        let foreign_base = base_epoch.is_some_and(|e| e != entry.conflicts.epoch());
        let ctx = WriteCtx {
            log: true,
            seen: Some(base_version),
            unseen: &[],
            foreign_base,
            client: Some(client),
            detect: true,
            resolving: &resolving,
            settling: &settling,
        };
        let mut origin: Vec<usize> = Vec::new();
        let mut created: Vec<String> = Vec::new();
        let mut effects: Vec<Effect> = Vec::new();
        let result = self.write_steps(
            entry,
            &path,
            &mut |board, live, log| {
                let inputs = PlanInputs {
                    kept: &kept,
                    dropped: &dropped,
                    originals: &originals,
                    log,
                    // A view of another run saw none of this log: every check
                    // that asks "changed since you saw it" must refuse.
                    base_version: if foreign_base { u64::MAX } else { base_version },
                };
                let plan = plan_ops(ops, board, &inputs, &|id, body| {
                    bound_body(live, board, id, body)
                })?;
                origin = plan.origin;
                created = plan.created;
                effects = plan.effects;
                Ok(plan.steps)
            },
            &Author::Pane,
            ctx,
        );
        // Even a refused edit may have ingested an external save.
        let outcome = match result {
            Ok(()) => {
                apply_effects(entry, effects);
                Ok(PaneEditOutcome {
                    version: entry.log.seq,
                    created,
                })
            }
            Err(err) => Err(PaneEditError::from_tracker(err, &origin)),
        };
        inner.dirty.insert(path);
        self.persist(inner);
        outcome
    }
}

/// Runs the effects of a batch that was written. Every refusal was decided
/// while planning, before anything was written, so this cannot fail.
fn apply_effects(entry: &mut BoardEntry, effects: Vec<Effect>) {
    for effect in effects {
        match effect {
            Effect::ClearBadge(item) => entry.approvals.approve(&item),
            Effect::ClearConflict(id) => {
                if let Some(item) = entry.conflicts.clear(&id) {
                    entry.conflicts.forget_drops_of_settled(&[item]);
                }
            }
            Effect::AckDropped { id, count } => entry.conflicts.ack_dropped(&id, count),
            Effect::ClearRemoved { id, block } => {
                entry.conflicts.clear_removed_matching(&id, &block)
            }
        }
    }
}

/// A status change (a tick, or an undo/redo of one) on a command: refuses
/// when the item's kind or command changed after the edit's base version, or
/// when the history doesn't reach back to say. The person saw a plain item (or
/// another command), not this one; an agent may have just made it a command,
/// and a stale undo must not tick it. A command that has not changed since the
/// person's view is ticked as before.
fn check_status_not_on_new_command(
    board: &Board,
    log: &ChangeLog,
    id: &str,
    base_version: u64,
    index: usize,
) -> Result<(), TrackerError> {
    if !board.item(id).is_some_and(|i| i.kind == Kind::Command) {
        return Ok(());
    }
    let changed = log.entries.iter().any(|c| {
        c.seq > base_version
            && c.item_id.as_deref() == Some(id)
            && matches!(c.kind, ChangeKind::Changed | ChangeKind::Added)
            && (c.fields.contains_key("kind") || c.fields.contains_key("command"))
    });
    if changed || log.history_gap(base_version) {
        return Err(TrackerError::Stale {
            index: Some(index),
            reason: "that item became a command (or its command changed) since you saw it; look again before changing its status"
                .to_string(),
        });
    }
    Ok(())
}

/// The user approves what they saw: refuses when anyone changed the item
/// after the edit's base version (another pane window included: the writer's
/// kind says nothing about whose view it was), or when the history doesn't
/// reach back to the base version to show what changed.
fn check_badge_clearable(
    log: &ChangeLog,
    id: &str,
    base_version: u64,
    index: usize,
) -> Result<(), TrackerError> {
    let changed = log.entries.iter().any(|c| {
        c.seq > base_version
            && c.item_id.as_deref() == Some(id)
            && matches!(c.kind, ChangeKind::Changed | ChangeKind::Added)
    });
    if changed || log.history_gap(base_version) {
        return Err(TrackerError::Stale {
            index: Some(index),
            reason: "the item changed since you saw it; look again before clearing".to_string(),
        });
    }
    Ok(())
}

/// The user acknowledges drops they have seen: refuses when a cap dropped
/// another of the item's losing values after the edit's base version, or when
/// the history doesn't reach back to show.
fn check_drops_seen(
    log: &ChangeLog,
    id: &str,
    base_version: u64,
    index: usize,
) -> Result<(), TrackerError> {
    let newer = log.entries.iter().any(|c| {
        c.seq > base_version && c.item_id.as_deref() == Some(id) && c.kind == ChangeKind::Conflict
    });
    if newer || log.history_gap(base_version) {
        return Err(TrackerError::Stale {
            index: Some(index),
            reason: "more were dropped since you saw it; look again before acknowledging"
                .to_string(),
        });
    }
    Ok(())
}

struct Plan {
    steps: Vec<PaneStep>,
    /// The pane op each step came from.
    origin: Vec<usize>,
    created: Vec<String>,
    effects: Vec<Effect>,
}

/// `body` of a bound item with its source-owned first line kept; `None` when
/// the item isn't bound.
fn bound_body(
    live: &std::collections::HashMap<String, super::LiveItem>,
    board: &Board,
    id: &str,
    body: &str,
) -> Option<String> {
    let live = live.get(id)?;
    let prefix = live.binding.note_prefix();
    let line = live
        .overlay
        .as_ref()
        .map(|o| o.note_line.clone())
        .or_else(|| {
            let note = board.item(id)?.note.as_deref()?;
            let first = note.lines().next()?;
            first.starts_with(prefix).then(|| first.to_string())
        })?;
    let note = (!body.trim().is_empty()).then_some(body);
    Some(with_source_line(note, prefix, &line))
}

/// What planning a batch reads besides the board.
struct PlanInputs<'a> {
    /// The conflicts the board holds now.
    kept: &'a [Conflict],
    /// The losing values a cap has dropped, per item.
    dropped: &'a HashMap<String, u32>,
    /// The recorded original text of an item whose text was over the note cap.
    originals: &'a HashMap<String, String>,
    log: &'a ChangeLog,
    base_version: u64,
}

fn plan_ops(
    ops: &[TrackerPaneOp],
    board: &Board,
    inputs: &PlanInputs<'_>,
    bound_body: &dyn Fn(&str, &str) -> Option<String>,
) -> Result<Plan, TrackerError> {
    let (log, base_version) = (inputs.log, inputs.base_version);
    let mut plan = Plan {
        steps: Vec::new(),
        origin: Vec::new(),
        created: Vec::new(),
        effects: Vec::new(),
    };
    let mut taken: HashSet<String> = board.items.iter().map(|i| i.id.clone()).collect();
    // What the batch settles so far: a conflict twice, or two losing values
    // for one field, would write one and silently lose the other.
    let mut settled: HashSet<&str> = HashSet::new();
    let mut put_back: HashSet<(&str, &str)> = HashSet::new();
    let invalid = |index: usize, reason: &str| TrackerError::InvalidArgs {
        index: Some(index),
        reason: reason.to_string(),
    };
    let stale = |index: usize, reason: &str| TrackerError::Stale {
        index: Some(index),
        reason: reason.to_string(),
    };
    for (index, op) in ops.iter().enumerate() {
        let push = |plan: &mut Plan, step: PaneStep| {
            plan.steps.push(step);
            plan.origin.push(index);
        };
        match op {
            TrackerPaneOp::Status { id, status } => {
                check_status_not_on_new_command(board, log, id, base_version, index)?;
                push(
                    &mut plan,
                    PaneStep::Op(Op::Status {
                        id: id.clone(),
                        status: status.clone(),
                    }),
                )
            }
            TrackerPaneOp::Edit {
                id,
                title,
                text,
                body,
            } => {
                if title.is_none() && text.is_none() && body.is_none() {
                    return Err(invalid(index, "edit needs a title, text or body"));
                }
                let body = body
                    .as_ref()
                    .map(|b| bound_body(id, b).unwrap_or_else(|| b.clone()));
                push(
                    &mut plan,
                    PaneStep::Op(Op::Upsert(Upsert {
                        id: Some(id.clone()),
                        title: title.clone(),
                        text: text.clone(),
                        body,
                        ..Upsert::default()
                    })),
                );
            }
            TrackerPaneOp::Add {
                section,
                title,
                body,
                before,
                after,
            } => {
                // `generate_id` keeps sensitive text out of the id.
                let id = generate_id(title, &taken);
                taken.insert(id.clone());
                plan.created.push(id.clone());
                push(
                    &mut plan,
                    PaneStep::Op(Op::Upsert(Upsert {
                        id: Some(id.clone()),
                        section: Some(section.clone()),
                        title: Some(title.clone()),
                        body: body.clone(),
                        ..Upsert::default()
                    })),
                );
                if before.is_some() || after.is_some() {
                    push(
                        &mut plan,
                        PaneStep::Op(Op::Move {
                            id,
                            section: section.clone(),
                            before: before.clone(),
                            after: after.clone(),
                        }),
                    );
                }
            }
            TrackerPaneOp::Move {
                id,
                section,
                before,
                after,
            } => push(
                &mut plan,
                PaneStep::Op(Op::Move {
                    id: id.clone(),
                    section: section.clone(),
                    before: before.clone(),
                    after: after.clone(),
                }),
            ),
            TrackerPaneOp::Remove { id } => {
                push(&mut plan, PaneStep::Op(Op::Remove { id: id.clone() }))
            }
            TrackerPaneOp::RestoreText { id, text } => {
                // Past a note's cap this is only for putting back what the
                // item had; anything else is an edit and takes the edit's caps.
                let original = inputs.originals.get(id).is_some_and(|o| o == text);
                if text.chars().count() > MAX_NOTE_CHARS && !original {
                    return Err(invalid(
                        index,
                        &format!(
                            "restore_text over {MAX_NOTE_CHARS} characters can only put back the item's recorded original"
                        ),
                    ));
                }
                push(
                    &mut plan,
                    PaneStep::SetText {
                        id: id.clone(),
                        text: text.clone(),
                    },
                )
            }
            TrackerPaneOp::Restore {
                source,
                section,
                before,
                after,
            } => {
                let (item, block) = parse_restorable(source).map_err(|e| invalid(index, &e))?;
                // Putting back the very bytes a removal kept settles that
                // conflict; other bytes leave it for the user to settle.
                plan.effects.push(Effect::ClearRemoved {
                    id: item.id.clone(),
                    block: block.clone(),
                });
                push(
                    &mut plan,
                    PaneStep::Restore(Restore {
                        item,
                        block,
                        section: section.clone(),
                        before: before.clone(),
                        after: after.clone(),
                    }),
                );
            }
            TrackerPaneOp::ClearBadge { id } => {
                if board.item(id).is_none() {
                    return Err(TrackerError::UnknownItem {
                        index,
                        id: id.clone(),
                    });
                }
                check_badge_clearable(log, id, base_version, index)?;
                if let Some(item) = board.item(id) {
                    plan.effects
                        .push(Effect::ClearBadge(Box::new(item.clone())));
                }
            }
            TrackerPaneOp::AckDropped { id } => {
                if board.item(id).is_none() {
                    return Err(TrackerError::UnknownItem {
                        index,
                        id: id.clone(),
                    });
                }
                let count = inputs.dropped.get(id).copied().unwrap_or(0);
                if count == 0 {
                    return Err(stale(
                        index,
                        "nothing was dropped for that item (cleared elsewhere); look again",
                    ));
                }
                check_drops_seen(log, id, base_version, index)?;
                plan.effects.push(Effect::AckDropped {
                    id: id.clone(),
                    count,
                });
            }
            TrackerPaneOp::ResolveConflict {
                id,
                field,
                keep,
                conflict_id,
                ..
            } => {
                let Some(conflict_id) = conflict_id.as_deref() else {
                    return Err(invalid(
                        index,
                        "resolve_conflict needs the conflict_id from the board view; a position no longer names a conflict",
                    ));
                };
                // The conflict the user was shown, or nothing is written: it
                // may be settled already, in another window, or dropped.
                let chosen = inputs
                    .kept
                    .iter()
                    .find(|c| c.id == conflict_id && &c.item_id == id && &c.field == field);
                let Some(chosen) = chosen else {
                    return Err(stale(
                        index,
                        "that conflict is no longer kept (settled elsewhere or dropped); look again",
                    ));
                };
                if !settled.insert(conflict_id) {
                    return Err(invalid(
                        index,
                        "the batch settles that conflict twice; settle each conflict once",
                    ));
                }
                if *keep == ConflictKeep::Losing
                    && field != conflicts::REMOVED
                    && !put_back.insert((id.as_str(), field.as_str()))
                {
                    return Err(invalid(
                        index,
                        "the batch puts back two losing values of the same field; only one can be written, so keep one and settle the rest as current",
                    ));
                }
                if *keep == ConflictKeep::Losing {
                    let (steps, new_id) =
                        losing_steps(chosen, board, &mut taken).map_err(|e| invalid(index, &e))?;
                    plan.created.extend(new_id);
                    for step in steps {
                        push(&mut plan, step);
                    }
                }
                plan.effects.push(Effect::ClearConflict(chosen.id.clone()));
            }
        }
    }
    Ok(plan)
}

/// The steps that put a conflict's losing value back, and the new id of a
/// removed item that came back under one (its old id was taken again since:
/// an agent re-added it; the text is kept, so nothing is lost, but two items
/// can't share an id). `taken` holds the ids of the board and the batch.
fn losing_steps(
    c: &Conflict,
    board: &Board,
    taken: &mut HashSet<String>,
) -> Result<(Vec<PaneStep>, Option<String>), String> {
    let mut new_id = None;
    let text = |v: &Value| match v {
        Value::String(s) => s.clone(),
        _ => String::new(),
    };
    let upsert = |f: &dyn Fn(&mut Upsert)| {
        let mut u = Upsert {
            id: Some(c.item_id.clone()),
            ..Upsert::default()
        };
        f(&mut u);
        Ok((vec![PaneStep::Op(Op::Upsert(u))], None))
    };
    match c.field.as_str() {
        conflicts::REMOVED => {
            let source = c.losing.as_str().ok_or("the removed item's text is gone")?;
            let (mut item, mut block) = parse_restorable(source)?;
            if taken.contains(&item.id) {
                let fresh = generate_id(&item.text, taken);
                let marker = format!("<!-- #{} ", item.id);
                if !block.contains(&marker) {
                    return Err("the removed item can't be put back under a new id".to_string());
                }
                block = block.replacen(&marker, &format!("<!-- #{fresh} "), 1);
                (item, block) = parse_restorable(&block)?;
                if item.id != fresh {
                    return Err("the removed item can't be put back under a new id".to_string());
                }
                new_id = Some(fresh);
            }
            taken.insert(item.id.clone());
            let section = c
                .section
                .clone()
                .ok_or("the removed item's section is gone")?;
            // Back where it was, if its neighbours still are there.
            let here = |id: &Option<String>| {
                id.clone()
                    .filter(|id| board.item(id).is_some_and(|i| i.section == section))
            };
            let (after, before) = match here(&c.prev) {
                Some(prev) => (Some(prev), None),
                None => (None, here(&c.next)),
            };
            Ok((
                vec![PaneStep::Restore(Restore {
                    item,
                    block,
                    section,
                    before,
                    after,
                })],
                new_id,
            ))
        }
        "status" => Ok((
            vec![PaneStep::Op(Op::Status {
                id: c.item_id.clone(),
                status: text(&c.losing),
            })],
            None,
        )),
        "text" => Ok((
            vec![PaneStep::SetText {
                id: c.item_id.clone(),
                text: text(&c.losing),
            }],
            None,
        )),
        "note" => upsert(&|u| u.note = Some(text(&c.losing))),
        "owner" => upsert(&|u| u.owner = Some(text(&c.losing))),
        "env" => upsert(&|u| u.env = Some(text(&c.losing))),
        "links" => {
            let links: Vec<crate::tracker::model::Link> =
                serde_json::from_value(if c.losing.is_null() {
                    json!([])
                } else {
                    c.losing.clone()
                })
                .map_err(|e| format!("links can't be restored: {e}"))?;
            upsert(&|u| {
                u.links = Some(
                    links
                        .iter()
                        .map(|l| LinkInput::Full {
                            text: l.text.clone(),
                            url: l.url.clone(),
                        })
                        .collect(),
                )
            })
        }
        other => Err(format!("{other} can't be restored from the pane")),
    }
}
