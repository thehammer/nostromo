//! `TrackerBoardView`: what the pane shows (the `tracker_board` payload,
//! contract §5), built from a parsed board plus facts only the registry knows.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use std::collections::HashMap;

use crate::ipc::protocol::{MdBlock, MdSpan};
use crate::markdown_blocks::markdown_to_blocks;

use super::format::{ParsedBoard, SegmentKind};
use super::model::{fnv1a64, Env, Item, Kind, Link, Status};

/// The banner over a board that isn't current.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Banner {
    /// The file doesn't parse; the view shows the last good version.
    Unreadable {
        line: usize,
        reason: String,
        last_good_at: Option<DateTime<Utc>>,
    },
    /// The file is gone; the view shows the last good version.
    Missing { last_seen: Option<DateTime<Utc>> },
}

/// The board sits in a git repo that would commit it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Committable {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote: Option<String>,
}

/// A live item's source and how fresh it is (T6): the view's `bound`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BoundView {
    /// The source's name (`mother.job`, `pr.ci`).
    pub source: String,
    /// When the source last reported on this item; absent before the first
    /// report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<DateTime<Utc>>,
    /// The source has been silent past the badly-stale limit: the item keeps
    /// its last value, and the pane says "as of …".
    pub badly_stale: bool,
}

/// Facts the registry passes in (the engine has no I/O).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ViewFacts {
    pub path: String,
    /// Title fallback when the file has no `# ` line.
    pub topic: String,
    pub version: u64,
    pub epoch: String,
    /// The board's updated time when it has no items.
    pub file_mtime: Option<DateTime<Utc>>,
    pub banner: Option<Banner>,
    pub committable: Option<Committable>,
    pub hidden_by_user: bool,
    /// Live items by item id (T6).
    pub bound: HashMap<String, BoundView>,
    /// Overwritten values per item id, oldest first (T3a).
    pub conflicts: HashMap<String, Vec<ViewConflict>>,
    /// Items removed over someone's edit, newest last (T3a).
    pub removed_conflicts: Vec<ViewRemovedConflict>,
    /// Unapproved guard-finding classes per item id (T3a).
    pub sensitive: HashMap<String, Vec<String>>,
    /// Losing values a cap dropped, per item id, until its conflicts are settled.
    pub dropped: HashMap<String, u32>,
}

/// A value that lost to a later write by someone who couldn't have seen it.
/// The pane offers keeping either side. Never sent to a network peer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewConflict {
    /// The conflict's stable id: what `resolve_conflict.conflict_id` names.
    /// Positions shift when conflicts are settled or dropped; this does not.
    #[serde(default)]
    pub conflict_id: String,
    pub field: String,
    /// The losing value as text (JSON for a list), raw: it is the user's.
    pub losing: String,
    /// Who wrote it (`agent claudia`, `pane (you)`, `file (unknown editor)`).
    pub losing_by: String,
    pub winning_by: String,
    pub at: DateTime<Utc>,
    /// Position among this item field's losing values, oldest first, as of
    /// this view. Informational: `resolve_conflict` picks by `conflict_id`.
    pub index: u32,
}

/// An item removed over someone's recent edit. `source` restores it, byte for
/// byte (`restore`, or `resolve_conflict` with `keep: losing`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewRemovedConflict {
    /// The conflict's stable id (`resolve_conflict.conflict_id`).
    #[serde(default)]
    pub conflict_id: String,
    pub item_id: String,
    /// The removed item's text.
    pub title: String,
    pub losing_by: String,
    pub winning_by: String,
    pub at: DateTime<Utc>,
    pub source: String,
}

/// Why the pane badges an item: the classes of sensitive-looking text it
/// holds (names only, never the text).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewSensitive {
    pub classes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewItem {
    pub id: String,
    pub section: String,
    pub text_spans: Vec<MdSpan>,
    /// The task text as stored (raw markdown), for an editor to prefill.
    #[serde(default)]
    pub text: String,
    /// The note as stored (raw markdown).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    pub note_blocks: Vec<MdBlock>,
    pub links: Vec<Link>,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<Env>,
    /// Ran-it state of a command (T4; always false here).
    pub ran: bool,
    /// The live source this item follows and how fresh it is (T6).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bound: Option<BoundView>,
    /// Overwritten values the user hasn't settled.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub conflicts: Vec<ViewConflict>,
    /// Older overwritten values of this item a cap dropped: something was lost
    /// that the pane can't show. 0 (and absent) when nothing was.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub dropped_conflicts: u32,
    /// Sensitive-looking text the user hasn't cleared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitive: Option<ViewSensitive>,
    pub source: String,
}

/// One node of the board in file order. Joining every node's `source`
/// reproduces the file byte for byte (blank lines belong to the node before
/// them).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)] // one item per node on the wire; boxing would only add indirection
pub enum ViewNode {
    Title {
        text: String,
        source: String,
    },
    Section {
        id: String,
        title: String,
        source: String,
    },
    /// The `## Log` heading.
    LogHeading {
        title: String,
        source: String,
    },
    Prose {
        /// Hex FNV-1a of the source + `-` + ordinal among equal hashes.
        key: String,
        blocks: Vec<MdBlock>,
        source: String,
    },
    Item(ViewItem),
    LogLine {
        time: String,
        text: String,
        source: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewLogLine {
    pub time: String,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackerBoardView {
    pub title: String,
    pub path: String,
    pub version: u64,
    /// Which run of the board `version` counts in (random; changes when the
    /// daemon's state for the board is lost). The pane sends it back as
    /// `tracker_edit.base_epoch`. Additive: absent from an older daemon.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub epoch: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
    pub nodes: Vec<ViewNode>,
    /// Log lines in file order (oldest first).
    pub log: Vec<ViewLogLine>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub banner: Option<Banner>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub committable: Option<Committable>,
    pub hidden_by_user: bool,
    /// Items removed over someone's edit (T3a).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_conflicts: Vec<ViewRemovedConflict>,
    /// Set when the frame would not fit the wire limit and was slimmed (see
    /// [`fit_to_frame`]); absent otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trimmed: Option<ViewTrimmed>,
}

/// What [`fit_to_frame`] left out of an over-large view.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewTrimmed {
    /// Losing values and removed items' markdown replaced by a note saying how
    /// long they were (they are still kept, and settled by `resolve_conflict`).
    pub conflict_values: u32,
    /// The raw `text` and `note` of every item were left out: take them from
    /// `source`.
    pub raw_fields: bool,
    /// Items whose rendered spans and blocks were flattened to plain text.
    pub plain_items: u32,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

/// The most bytes a `tracker_board` frame is built to: under the wire limit
/// ([`crate::ipc::protocol::MAX_FRAME_LEN`], 4 MiB) with room for the envelope.
pub const FRAME_BUDGET: usize = 3_900_000;

/// Slims `view` until it encodes within [`FRAME_BUDGET`], leaving the most
/// useful parts for last: first the conflicts' long values (largest first),
/// then the rendered markup of the items (the raw `text`/`note` stay), then
/// the raw `text`/`note` (also in each item's `source`). Says what it left out in `view.trimmed`. A
/// view that already fits is untouched.
pub fn fit_to_frame(view: &mut TrackerBoardView) {
    let size = |v: &TrackerBoardView| serde_json::to_vec(v).map_or(0, |b| b.len());
    let mut over = size(view).saturating_sub(FRAME_BUDGET);
    if over == 0 {
        return;
    }
    let mut trimmed = ViewTrimmed::default();
    let note = |chars: usize| format!("[{chars} characters, too large to show here]");
    let cost = |s: &str| serde_json::to_string(s).map_or(0, |j| j.len());

    // 1. Conflict values, largest first.
    enum Slot {
        Losing(usize, usize),
        Removed(usize),
    }
    let mut slots: Vec<(usize, Slot)> = Vec::new();
    for (n, node) in view.nodes.iter().enumerate() {
        if let ViewNode::Item(item) = node {
            for (c, conflict) in item.conflicts.iter().enumerate() {
                slots.push((cost(&conflict.losing), Slot::Losing(n, c)));
            }
        }
    }
    for (r, removed) in view.removed_conflicts.iter().enumerate() {
        slots.push((cost(&removed.source), Slot::Removed(r)));
    }
    slots.sort_by_key(|slot| std::cmp::Reverse(slot.0));
    for (bytes, slot) in slots {
        if over == 0 {
            break;
        }
        let target = match slot {
            Slot::Losing(n, c) => match &mut view.nodes[n] {
                ViewNode::Item(item) => &mut item.conflicts[c].losing,
                _ => continue,
            },
            Slot::Removed(r) => &mut view.removed_conflicts[r].source,
        };
        let marker = note(target.chars().count());
        let saved = bytes.saturating_sub(cost(&marker));
        *target = marker;
        over = over.saturating_sub(saved);
        trimmed.conflict_values += 1;
    }

    // 2. Rendered markup, flattened to plain text (the raw text is kept).
    if over > 0 {
        for node in &mut view.nodes {
            if let ViewNode::Item(item) = node {
                if item.text_spans.len() > 1 || !item.note_blocks.is_empty() {
                    item.text_spans = vec![MdSpan::Text {
                        text: item.text.clone(),
                    }];
                    item.note_blocks = item
                        .note
                        .iter()
                        .map(|note| MdBlock::Paragraph {
                            spans: vec![MdSpan::Text { text: note.clone() }],
                        })
                        .collect();
                    trimmed.plain_items += 1;
                }
            }
        }
        view.trimmed = Some(trimmed.clone());
        over = size(view).saturating_sub(FRAME_BUDGET);
    }

    // 3. Raw text and note (each item's `source` still holds them).
    if over > 0 {
        for node in &mut view.nodes {
            if let ViewNode::Item(item) = node {
                item.text.clear();
                item.note = None;
            }
        }
        trimmed.raw_fields = true;
    }
    view.trimmed = Some(trimmed);
}

/// Builds the pane's view of a parsed board.
pub fn build(parsed: &ParsedBoard, facts: &ViewFacts) -> TrackerBoardView {
    let board = &parsed.board;
    let mut nodes: Vec<ViewNode> = Vec::new();
    let mut leading_blank = String::new();
    let mut prose_seen: HashMap<u64, usize> = HashMap::new();
    for segment in &parsed.segments {
        let text = parsed.text(&segment.span);
        let source = std::mem::take(&mut leading_blank) + text;
        let node = match segment.kind {
            SegmentKind::Blank => {
                match nodes.last_mut() {
                    Some(node) => node.source_mut().push_str(text),
                    None => leading_blank = source,
                }
                continue;
            }
            SegmentKind::Title => ViewNode::Title {
                text: board.title.clone().unwrap_or_default(),
                source,
            },
            SegmentKind::Section(i) => ViewNode::Section {
                id: board.sections[i].id.clone(),
                title: board.sections[i].title.clone(),
                source,
            },
            SegmentKind::LogHeading => ViewNode::LogHeading {
                title: text.trim_end().trim_start_matches("## ").trim().to_string(),
                source,
            },
            SegmentKind::Prose(i) => {
                let hash = fnv1a64(board.prose[i].as_bytes());
                let ordinal = prose_seen.entry(hash).or_default();
                let key = format!("{hash:016x}-{ordinal}");
                *ordinal += 1;
                ViewNode::Prose {
                    key,
                    blocks: markdown_to_blocks(&board.prose[i]),
                    source,
                }
            }
            SegmentKind::Item(i) => ViewNode::Item(view_item(&board.items[i], source, facts)),
            SegmentKind::LogLine(i) => ViewNode::LogLine {
                time: board.log[i].time.clone(),
                text: board.log[i].text.clone(),
                source,
            },
        };
        nodes.push(node);
    }
    let mut view = TrackerBoardView {
        title: board.title.clone().unwrap_or_else(|| facts.topic.clone()),
        path: facts.path.clone(),
        version: facts.version,
        epoch: facts.epoch.clone(),
        updated_at: board.updated_at().or(facts.file_mtime),
        nodes,
        log: board
            .log
            .iter()
            .map(|l| ViewLogLine {
                time: l.time.clone(),
                text: l.text.clone(),
            })
            .collect(),
        banner: facts.banner.clone(),
        committable: facts.committable.clone(),
        hidden_by_user: facts.hidden_by_user,
        removed_conflicts: facts.removed_conflicts.clone(),
        trimmed: None,
    };
    fit_to_frame(&mut view);
    view
}

impl ViewNode {
    /// The node's exact markdown from the file.
    pub fn source(&self) -> &str {
        match self {
            ViewNode::Title { source, .. }
            | ViewNode::Section { source, .. }
            | ViewNode::LogHeading { source, .. }
            | ViewNode::Prose { source, .. }
            | ViewNode::LogLine { source, .. }
            | ViewNode::Item(ViewItem { source, .. }) => source,
        }
    }

    fn source_mut(&mut self) -> &mut String {
        match self {
            ViewNode::Title { source, .. }
            | ViewNode::Section { source, .. }
            | ViewNode::LogHeading { source, .. }
            | ViewNode::Prose { source, .. }
            | ViewNode::LogLine { source, .. }
            | ViewNode::Item(ViewItem { source, .. }) => source,
        }
    }
}

fn view_item(item: &Item, source: String, facts: &ViewFacts) -> ViewItem {
    ViewItem {
        id: item.id.clone(),
        section: item.section.clone(),
        text_spans: inline_spans(&item.text),
        text: item.text.clone(),
        note: item.note.clone(),
        status: item.status,
        owner: item.owner.clone(),
        updated_at: item.updated_at,
        note_blocks: item
            .note
            .as_deref()
            .map(markdown_to_blocks)
            .unwrap_or_default(),
        links: item.links.clone(),
        kind: item.kind,
        command: item.command.clone(),
        env: item.env,
        ran: false,
        bound: facts.bound.get(&item.id).cloned(),
        conflicts: facts.conflicts.get(&item.id).cloned().unwrap_or_default(),
        dropped_conflicts: facts.dropped.get(&item.id).copied().unwrap_or(0),
        sensitive: facts.sensitive.get(&item.id).map(|classes| ViewSensitive {
            classes: classes.clone(),
        }),
        source,
    }
}

/// An item's text as inline spans: the spans of its single paragraph, or
/// the plain text when it parses as something else (`1. foo`, `# x`).
fn inline_spans(text: &str) -> Vec<MdSpan> {
    match markdown_to_blocks(text).as_slice() {
        [MdBlock::Paragraph { spans }] => spans.clone(),
        _ => vec![MdSpan::Text {
            text: text.to_string(),
        }],
    }
}
