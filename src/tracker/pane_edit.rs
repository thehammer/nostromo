//! The pane's way into the board (`ClientMsg::TrackerEdit`, T3a): the user's
//! edits, applied through the same read-modify-write as an agent's, attributed
//! `pane (you)`.
//!
//! A child of `registry`: it uses the registry's private write path.

use std::collections::HashSet;

use serde_json::{json, Value};

use super::{conflicts, BoardEntry, TrackerError, TrackerRegistry, WriteCtx};
use crate::ipc::protocol::{ConflictKeep, TrackerPaneOp, MAX_TRACKER_EDIT_OPS};
use crate::tracker::bindings::with_source_line;
use crate::tracker::conflicts::Conflict;
use crate::tracker::model::{generate_id, Author, Board};
use crate::tracker::ops::{parse_restorable, LinkInput, Op, PaneStep, Restore, Upsert};
use crate::tracker::sensitive::has_finding;

/// What a successful pane edit did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneEditOutcome {
    /// The board version after the edit.
    pub version: u64,
    /// The ids `add` generated, in op order.
    pub created: Vec<String>,
}

/// Why a pane edit changed nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneEditError {
    pub code: String,
    pub reason: Option<String>,
    /// The failing op's position.
    pub index: Option<usize>,
}

impl PaneEditError {
    fn invalid(reason: &str) -> PaneEditError {
        PaneEditError {
            code: "invalid_args".to_string(),
            reason: Some(reason.to_string()),
            index: None,
        }
    }

    /// `err` with the index of the pane op that made step `step`.
    fn from_tracker(err: TrackerError, origin: &[usize]) -> PaneEditError {
        let op = |index: usize| origin.get(index).copied().unwrap_or(index);
        let (index, reason) = match &err {
            TrackerError::UnknownItem { index, id } => (Some(op(*index)), Some(id.clone())),
            TrackerError::InvalidStatus { index, value } => (Some(op(*index)), Some(value.clone())),
            TrackerError::InvalidArgs { index, reason } => (index.map(op), Some(reason.clone())),
            TrackerError::Io(why) => (None, Some(why.clone())),
            other => (None, Some(other.to_string())),
        };
        PaneEditError {
            code: err.code().to_string(),
            reason,
            index,
        }
    }
}

/// What a pane op does besides writing the file.
#[allow(clippy::enum_variant_names)]
enum Effect {
    ClearBadge(String),
    ClearRemoved { id: String, block: String },
    ClearConflicts { id: String, field: String },
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

        let known: Vec<Conflict> = entry.conflicts.all().to_vec();
        // Settling a conflict is a decision, not a competing edit.
        let resolving = ops.iter().any(|op| {
            matches!(
                op,
                TrackerPaneOp::ResolveConflict {
                    keep: ConflictKeep::Losing,
                    ..
                }
            )
        });
        let ctx = WriteCtx {
            log: true,
            seen: Some(base_version),
            detect: !resolving,
        };
        let mut origin: Vec<usize> = Vec::new();
        let mut created: Vec<String> = Vec::new();
        let mut effects: Vec<Effect> = Vec::new();
        let result = self.write_steps(
            entry,
            &path,
            &mut |board, live| {
                let plan = plan_ops(ops, board, &known, &|id, body| {
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

fn apply_effects(entry: &mut BoardEntry, effects: Vec<Effect>) {
    for effect in effects {
        match effect {
            Effect::ClearBadge(id) => {
                let item = entry
                    .parsed
                    .as_ref()
                    .and_then(|p| p.board.item(&id))
                    .cloned();
                if let Some(item) = item {
                    entry.approvals.approve(&item);
                }
            }
            Effect::ClearConflicts { id, field } => entry.conflicts.clear_field(&id, &field),
            Effect::ClearRemoved { id, block } => {
                entry.conflicts.clear_removed_matching(&id, &block)
            }
        }
    }
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

fn plan_ops(
    ops: &[TrackerPaneOp],
    board: &Board,
    known: &[Conflict],
    bound_body: &dyn Fn(&str, &str) -> Option<String>,
) -> Result<Plan, TrackerError> {
    let mut plan = Plan {
        steps: Vec::new(),
        origin: Vec::new(),
        created: Vec::new(),
        effects: Vec::new(),
    };
    let mut taken: HashSet<String> = board.items.iter().map(|i| i.id.clone()).collect();
    let invalid = |index: usize, reason: &str| TrackerError::InvalidArgs {
        index: Some(index),
        reason: reason.to_string(),
    };
    for (index, op) in ops.iter().enumerate() {
        let push = |plan: &mut Plan, step: PaneStep| {
            plan.steps.push(step);
            plan.origin.push(index);
        };
        match op {
            TrackerPaneOp::Status { id, status } => push(
                &mut plan,
                PaneStep::Op(Op::Status {
                    id: id.clone(),
                    status: status.clone(),
                }),
            ),
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
                // An id is made from the title; a title with sensitive text
                // must not leak into the id agents read.
                let seed = if has_finding(title) { "item" } else { title };
                let id = generate_id(seed, &taken);
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
                plan.effects.push(Effect::ClearBadge(id.clone()));
            }
            TrackerPaneOp::ResolveConflict {
                id,
                field,
                keep,
                index: pick,
            } => {
                let list: Vec<&Conflict> = known
                    .iter()
                    .filter(|c| &c.item_id == id && &c.field == field)
                    .collect();
                let chosen = match pick {
                    Some(i) => list.get(*i as usize),
                    None => list.last(),
                };
                let Some(chosen) = chosen else {
                    return Err(invalid(index, "no such conflict"));
                };
                if *keep == ConflictKeep::Losing {
                    for step in losing_steps(chosen, board).map_err(|e| invalid(index, &e))? {
                        push(&mut plan, step);
                    }
                }
                plan.effects.push(Effect::ClearConflicts {
                    id: id.clone(),
                    field: field.clone(),
                });
            }
        }
    }
    Ok(plan)
}

/// The steps that put a conflict's losing value back.
fn losing_steps(c: &Conflict, board: &Board) -> Result<Vec<PaneStep>, String> {
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
        Ok(vec![PaneStep::Op(Op::Upsert(u))])
    };
    match c.field.as_str() {
        conflicts::REMOVED => {
            let source = c.losing.as_str().ok_or("the removed item's text is gone")?;
            let (item, block) = parse_restorable(source)?;
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
            Ok(vec![PaneStep::Restore(Restore {
                item,
                block,
                section,
                before,
                after,
            })])
        }
        "status" => Ok(vec![PaneStep::Op(Op::Status {
            id: c.item_id.clone(),
            status: text(&c.losing),
        })]),
        "text" => upsert(&|u| u.text = Some(text(&c.losing))),
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
