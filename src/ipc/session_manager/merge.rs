//! Merging the typed messages waiting in a busy session's queue into one turn
//! (`docs/message-queue.md`, "Merging").
//!
//! Batches form only in `step`, at delivery: `pending` keeps individual
//! messages (ids, chips, take-back). [`plan_batches`] is the one function that
//! decides grouping, so the queue view's prediction (`merge_group`) and the
//! delivery cannot disagree.
//!
//! A batch is written as ONE user frame: a header line saying how many
//! messages follow, then each message verbatim between markers carrying a
//! per-batch random boundary a message cannot forge ([`build_envelope`]).
//! [`parse`] reads such text back, strictly, and is only ever used together
//! with the batch ledger (never on its own) to decide how a turn is shown.

use std::collections::VecDeque;
use std::ops::Range;

use super::inject::PendingOrigin;
use super::queue::EntryKind;
use super::{local_command, PendingMessage, Shared};
use crate::model::batches::{self, BatchRecord};

/// Most messages in one batch (equal to the sign-in queue cap).
pub(super) const MERGE_MAX_MESSAGES: usize = 20;
/// Most bytes of message text (the parts only) in one batch.
pub(super) const MERGE_MAX_TEXT_BYTES: usize = 256 * 1024;
/// Most images in one batch.
pub(super) const MERGE_MAX_IMAGES: usize = 20;

/// The open of the header line.
const HEADER_OPEN: &str = "<nostromo-batch ";
const HEADER_CLOSE: &str = "</nostromo-batch>";
/// What the unreadable-image note starts and ends with (see
/// `unreadable_images_note`); the only text allowed between sections.
const UNREADABLE_START: &str = "[Nostromo could not read the attached image file(s):";
const UNREADABLE_END: &str = "ask the user to re-attach it.]";

/// The parts of a merged frame, kept on the batch's `PendingMessage` (its
/// `text` is the envelope).
#[derive(Debug, Clone)]
pub(super) struct Batch {
    pub(super) boundary: String,
    /// The original messages, in order, as they were queued.
    pub(super) parts: Vec<PendingMessage>,
}

impl Batch {
    /// What a taken-back held batch returns: every text, a blank line apart.
    pub(super) fn joined_text(&self) -> String {
        self.parts
            .iter()
            .map(|p| p.original_text())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    pub(super) fn all_images(&self) -> Vec<String> {
        self.parts.iter().flat_map(|p| p.images.clone()).collect()
    }
}

/// May `m` be part of a batch? Typed by a person, not a slash command.
fn mergeable(m: &PendingMessage) -> bool {
    // An entry with a delivered hook never merges (the hook must run for its
    // own delivery): only app entries carry them in production.
    matches!(m.kind, EntryKind::Typed { .. })
        && m.on_delivered.is_none()
        && m.batch.is_none()
        && local_command::split_typed_command(&m.text).is_none()
}

/// Group the queue into the runs `step` will write: a partition of
/// `0..pending.len()`. A run of one is written as today. With
/// `merge_allowed == false` every message is its own run.
pub(super) fn plan_batches(
    pending: &VecDeque<PendingMessage>,
    merge_allowed: bool,
) -> Vec<Range<usize>> {
    let mut out = Vec::new();
    let mut start = 0;
    let (mut bytes, mut images) = (0usize, 0usize);
    for (i, m) in pending.iter().enumerate() {
        let joins = merge_allowed && i > start && {
            mergeable(m)
                && mergeable(&pending[start])
                && i - start < MERGE_MAX_MESSAGES
                && bytes + m.text.len() <= MERGE_MAX_TEXT_BYTES
                && images + m.images.len() <= MERGE_MAX_IMAGES
        };
        if joins {
            bytes += m.text.len();
            images += m.images.len();
        } else {
            if i > start {
                out.push(start..i);
            }
            start = i;
            bytes = m.text.len();
            images = m.images.len();
        }
    }
    if start < pending.len() {
        out.push(start..pending.len());
    }
    out
}

/// The `merge_group` of each queued entry (aligned with `pending`): the same
/// number for entries in one run of two or more, `None` otherwise.
pub(super) fn merge_groups(
    pending: &VecDeque<PendingMessage>,
    merge_allowed: bool,
) -> Vec<Option<u32>> {
    let mut groups = vec![None; pending.len()];
    let mut next = 1u32;
    for run in plan_batches(pending, merge_allowed) {
        if run.len() >= 2 {
            for g in &mut groups[run] {
                *g = Some(next);
            }
            next += 1;
        }
    }
    groups
}

/// Take the next frame's worth off the front of `pending`: one message, or a
/// merged run of typed ones (see [`plan_batches`]). The caller holds the locks
/// `step` does.
pub(super) fn take_front(
    pending: &mut VecDeque<PendingMessage>,
    merge_allowed: bool,
) -> Option<PendingMessage> {
    let run = plan_batches(pending, merge_allowed).into_iter().next()?;
    if run.len() < 2 {
        return pending.pop_front();
    }
    let parts: Vec<PendingMessage> = pending.drain(run).collect();
    Some(PendingMessage::batch_of(parts))
}

impl PendingMessage {
    /// One frame for `parts` (two or more typed messages): its id and kind are
    /// the first part's, its text the envelope, its images all the parts'.
    fn batch_of(parts: Vec<PendingMessage>) -> Self {
        let texts: Vec<&str> = parts.iter().map(|p| p.text.as_str()).collect();
        let boundary = fresh_boundary(&texts);
        let text = build_envelope(&boundary, &texts);
        let images = parts.iter().flat_map(|p| p.images.clone()).collect();
        Self {
            id: parts[0].id.clone(),
            kind: parts[0].kind.clone(),
            original_text: None,
            text,
            images,
            origin: PendingOrigin::User,
            on_delivered: None,
            batch: Some(Box::new(Batch { boundary, parts })),
        }
    }
}

/// Append the batch's ledger line. Logs the error class only.
pub(super) fn record_batch(shared: &Shared, batch: &Batch) {
    let record = BatchRecord {
        boundary: batch.boundary.clone(),
        count: batch.parts.len() as u32,
        ts: chrono::Utc::now(),
    };
    let hub = &shared.ctx.hub;
    if let Err(e) = batches::append(&hub.paths.batches_dir, &shared.ctx.session_id, &record) {
        let class = e
            .downcast_ref::<std::io::Error>()
            .map(|io| format!("{:?}", io.kind()))
            .unwrap_or_else(|| "other".to_owned());
        tracing::warn!(tag = %shared.ctx.tag, error_class = %class, "batch ledger append failed");
    }
}

/// A fresh boundary that occurs in none of `texts`.
pub(super) fn fresh_boundary(texts: &[&str]) -> String {
    loop {
        let b = uuid::Uuid::new_v4().simple().to_string();
        if !texts.iter().any(|t| t.contains(&b)) {
            return b;
        }
    }
}

fn header(boundary: &str, n: usize) -> String {
    format!(
        "{HEADER_OPEN}count=\"{n}\" boundary=\"{boundary}\">The user sent these {n} messages \
         while you were working: separate messages, in the order sent, each verbatim between its \
         own markers.{HEADER_CLOSE}"
    )
}

fn section(boundary: &str, k: usize, text: &str) -> String {
    format!("<<<MESSAGE-{boundary}-{k}>>>\n{text}\n<<<END-MESSAGE-{boundary}-{k}>>>")
}

/// The merged frame's text for `texts` (at least two) under `boundary`.
pub(crate) fn build_envelope(boundary: &str, texts: &[&str]) -> String {
    let sections = texts
        .iter()
        .enumerate()
        .map(|(i, t)| section(boundary, i + 1, t))
        .collect::<Vec<_>>()
        .join("\n\n");
    format!("{}\n\n{sections}", header(boundary, texts.len()))
}

/// Where each section starts in `text` (a frame built for `boundary`, possibly
/// with a `<nostromo-note>` block in front): section 1 starts at 0 (the note
/// and header go with it); section k >= 2 at its blank line before the marker.
/// The boundary occurs in no message, so each marker occurs exactly once.
pub(super) fn segment_starts(text: &str, boundary: &str, count: usize) -> Option<Vec<usize>> {
    let mut starts = vec![0];
    for k in 2..=count {
        let marker = format!("\n\n<<<MESSAGE-{boundary}-{k}>>>\n");
        starts.push(text.find(&marker)?);
    }
    Some(starts)
}

/// A merged frame read back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    pub boundary: String,
    pub parts: Vec<String>,
}

/// Read `text` as a merged frame, strictly: any deviation is `None`. Accepts
/// the plain-string form and the array form joined with newlines and trimmed.
pub fn parse(text: &str) -> Option<Parsed> {
    let text = text.trim();
    let rest = text.strip_prefix(HEADER_OPEN)?;
    let rest = rest.strip_prefix("count=\"")?;
    let (count, rest) = rest.split_once('"')?;
    if count.is_empty() || count.starts_with('0') || !count.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let count: usize = count.parse().ok()?;
    if !(2..=MERGE_MAX_MESSAGES).contains(&count) {
        return None;
    }
    let rest = rest.strip_prefix(" boundary=\"")?;
    let (boundary, _) = rest.split_once('"')?;
    if boundary.len() != 32 || !boundary.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let expected = header(boundary, count);
    let mut rest = text.strip_prefix(expected.as_str())?.trim_start();
    let mut parts = Vec::with_capacity(count);
    for k in 1..=count {
        let open = format!("<<<MESSAGE-{boundary}-{k}>>>\n");
        let close = format!("\n<<<END-MESSAGE-{boundary}-{k}>>>");
        rest = rest.strip_prefix(open.as_str())?;
        let end = rest.find(&close)?;
        let body = &rest[..end];
        // The boundary appears nowhere inside a section: a marker in the body
        // (of this batch or any other) means this is not our frame.
        if body.contains(boundary) {
            return None;
        }
        parts.push(body.to_owned());
        rest = &rest[end + close.len()..];
        let gap_end = rest.find("<<<MESSAGE-").unwrap_or(rest.len());
        let (gap, after) = rest.split_at(gap_end);
        let gap = gap.trim();
        if !gap.is_empty() && !(gap.starts_with(UNREADABLE_START) && gap.ends_with(UNREADABLE_END))
        {
            return None;
        }
        if k < count {
            if after.is_empty() {
                return None;
            }
            rest = after;
        } else if !after.is_empty() {
            return None;
        } else {
            rest = after;
        }
    }
    if !rest.trim().is_empty() {
        return None;
    }
    Some(Parsed {
        boundary: boundary.to_owned(),
        parts,
    })
}

#[cfg(test)]
#[path = "merge_tests.rs"]
mod merge_tests;
