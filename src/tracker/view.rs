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

/// Facts the registry passes in (the engine has no I/O).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ViewFacts {
    pub path: String,
    /// Title fallback when the file has no `# ` line.
    pub topic: String,
    pub version: u64,
    /// The board's updated time when it has no items.
    pub file_mtime: Option<DateTime<Utc>>,
    pub banner: Option<Banner>,
    pub committable: Option<Committable>,
    pub hidden_by_user: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewItem {
    pub id: String,
    pub section: String,
    pub text_spans: Vec<MdSpan>,
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
    /// `<source>/<key>` of a live binding (T6).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bound: Option<String>,
    pub source: String,
}

/// One node of the board in file order. Joining every node's `source`
/// reproduces the file byte for byte (blank lines belong to the node before
/// them).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
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
            SegmentKind::Item(i) => ViewNode::Item(view_item(&board.items[i], source)),
            SegmentKind::LogLine(i) => ViewNode::LogLine {
                time: board.log[i].time.clone(),
                text: board.log[i].text.clone(),
                source,
            },
        };
        nodes.push(node);
    }
    TrackerBoardView {
        title: board.title.clone().unwrap_or_else(|| facts.topic.clone()),
        path: facts.path.clone(),
        version: facts.version,
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
    }
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

fn view_item(item: &Item, source: String) -> ViewItem {
    ViewItem {
        id: item.id.clone(),
        section: item.section.clone(),
        text_spans: inline_spans(&item.text),
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
        bound: item.bind.clone(),
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
