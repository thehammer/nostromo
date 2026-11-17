//! The list a Resume tab shows, with each entry's status computed cheaply.
//!
//! The list path makes at most one `metadata()` call on the transcript and one
//! on the project folder per entry. It never opens a transcript: files that
//! need a content check or a scan for a moved file are queued for a background
//! pass ([`run_background`]) whose results the next list shows.

use super::first_prompt::FirstPrompt;
use super::store::{ConversationEntry, ConversationHistory, FileVerdict, Snapshot};
use super::transcript;
use crate::ipc::protocol::{ConversationEntryWire, ConversationStatus};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

/// Transcript files opened for a content check (a test seam: the list path must not move it).
pub static CONTENT_CHECKS: AtomicUsize = AtomicUsize::new(0);

/// A transcript written to this recently, with no Nostromo session running it,
/// may be open in another Claude window.
pub const ACTIVE_ELSEWHERE_MS: i64 = 2 * 60 * 1000;

/// A transcript written this soon before Nostromo stopped its own session was
/// written by that session.
const OWN_WRITE_SLACK_MS: i64 = 2_000;

/// The list, and the work it queued for the background pass.
pub struct Listing {
    pub entries: Vec<ConversationEntryWire>,
    /// Entries whose file needs a first-bytes check.
    pub to_check: Vec<String>,
    /// Entries whose file was not found where expected: scan for it.
    pub to_locate: Vec<String>,
}

/// Build the wire list. `live` maps a session id to `(tag, open)` for the
/// sessions running now.
pub fn build(
    snap: &Snapshot,
    history: &ConversationHistory,
    live: &HashMap<String, (String, bool)>,
) -> Listing {
    let mut out = Listing {
        entries: Vec::with_capacity(snap.entries.len()),
        to_check: Vec::new(),
        to_locate: Vec::new(),
    };
    for e in &snap.entries {
        let (status, path) = status_of(e, history, live.get(&e.sid), &mut out);
        out.entries.push(to_wire(e, status, path));
    }
    out.entries
        .sort_by_key(|e| std::cmp::Reverse(e.last_active_ms));
    out
}

/// One entry's status now (the same cheap checks as the list).
pub fn status_now(
    e: &ConversationEntry,
    history: &ConversationHistory,
    live: Option<&(String, bool)>,
) -> ConversationStatus {
    let mut scratch = Listing {
        entries: Vec::new(),
        to_check: Vec::new(),
        to_locate: Vec::new(),
    };
    status_of(e, history, live, &mut scratch).0
}

fn status_of(
    e: &ConversationEntry,
    history: &ConversationHistory,
    live: Option<&(String, bool)>,
    q: &mut Listing,
) -> (ConversationStatus, Option<PathBuf>) {
    let path = e.transcript_path.clone().or_else(|| {
        e.project_path
            .as_deref()
            .and_then(|c| transcript::expected_path(&e.sid, c))
    });
    let meta = path.as_deref().and_then(|p| std::fs::metadata(p).ok());
    if let Some((tag, open)) = live {
        return (
            ConversationStatus::Running {
                tag: tag.clone(),
                open: *open,
            },
            meta.is_some().then_some(path).flatten(),
        );
    }
    let Some(meta) = meta else {
        if history.was_not_found(&e.sid) {
            return (ConversationStatus::UnavailableDeleted, None);
        }
        // Not located yet: believed present until a scan says otherwise.
        q.to_locate.push(e.sid.clone());
        return (ConversationStatus::Available, None);
    };
    let size = meta.len();
    let mtime_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_millis() as i64);
    if size == 0 {
        return (ConversationStatus::UnavailableUnreadable, path);
    }
    match history.verdict(&e.sid) {
        Some(v) if v.size == size && v.mtime_ms == mtime_ms => {
            if v.unreadable {
                return (ConversationStatus::UnavailableUnreadable, path);
            }
        }
        _ => q.to_check.push(e.sid.clone()),
    }
    // Written to a moment ago by something that is not a Nostromo session: it
    // may be open in another Claude window. A write at the moment Nostromo
    // stopped its own session of it (closing the focus) is not.
    let written_by_us = history
        .stopped_at(&e.sid)
        .is_some_and(|stopped| mtime_ms <= stopped + OWN_WRITE_SLACK_MS);
    let active_elsewhere =
        mtime_ms > 0 && super::now_ms() - mtime_ms < ACTIVE_ELSEWHERE_MS && !written_by_us;
    if let Some(pp) = &e.project_path {
        if !Path::new(pp).exists() {
            return (
                ConversationStatus::FolderGone {
                    worktree: e.main_checkout.is_some(),
                    active_elsewhere,
                },
                path,
            );
        }
    }
    if active_elsewhere {
        return (ConversationStatus::ActiveElsewhere, path);
    }
    (ConversationStatus::Available, path)
}

fn to_wire(
    e: &ConversationEntry,
    status: ConversationStatus,
    path: Option<PathBuf>,
) -> ConversationEntryWire {
    let title = e.user_title.clone().unwrap_or_else(|| e.title.clone());
    let mut w = ConversationEntryWire {
        id: e.sid.clone(),
        title,
        label: None,
        agent: e.agent.clone(),
        project_name: None,
        project_path: None,
        branch: None,
        model: None,
        effort: None,
        pr_numbers: Vec::new(),
        first_prompt: None,
        first_prompt_withheld: None,
        sensitive: e.sensitive,
        last_active_ms: e.last_active_ms,
        status,
        resumed_from_tag: None,
        transcript_path: None,
        main_checkout: None,
        no_codebase: e.no_codebase,
        origin: None,
    };
    // Where a gone worktree may resume is no conversation content: a sensitive
    // entry carries it too, or it could never be resumed.
    if matches!(
        w.status,
        ConversationStatus::FolderGone { worktree: true, .. }
    ) {
        w.main_checkout = e
            .main_checkout
            .clone()
            .filter(|m| Path::new(m).join(".git").exists());
    }
    if e.sensitive {
        // Title, agent, time and "Sensitive" only (and the main checkout above).
        return w;
    }
    w.label = e.label.clone();
    w.project_path = e.project_path.clone();
    w.project_name = if e.no_codebase {
        Some("No codebase".to_owned())
    } else {
        e.project_path
            .as_deref()
            .and_then(|p| Path::new(p).file_name())
            .map(|n| n.to_string_lossy().into_owned())
    };
    w.branch = e.branch.clone();
    w.model = e.model.clone();
    w.effort = e.effort.clone();
    w.pr_numbers = e.pr_numbers.clone();
    w.resumed_from_tag = e.resumed_from_tag.clone();
    w.transcript_path = path.map(|p| p.to_string_lossy().into_owned());
    match &e.first_prompt {
        FirstPrompt::None => {}
        FirstPrompt::Text(t) => w.first_prompt = Some(t.clone()),
        FirstPrompt::Withheld(r) => w.first_prompt_withheld = Some(r.word()),
    }
    w
}

/// Is the file at `path` a transcript? Reads at most its first 64 bytes: a
/// transcript starts with `{`.
pub fn check_unreadable(path: &Path) -> bool {
    CONTENT_CHECKS.fetch_add(1, Ordering::Relaxed);
    // A FIFO, a symlink or a device is no transcript, and never blocks this.
    let Ok(mut f) = transcript::open_regular(path) else {
        return true;
    };
    let mut head = [0u8; 64];
    match f.read(&mut head) {
        Ok(n) if n > 0 => head[0] != b'{',
        _ => true,
    }
}

/// The background pass a list queues: content checks and scans for moved
/// files. Blocking; run it on a blocking thread, never under a lock.
/// Returns whether anything changed.
pub fn run_background(
    history: &ConversationHistory,
    to_check: &[String],
    to_locate: &[String],
) -> bool {
    let mut changed = false;
    for sid in to_locate {
        match transcript::locate(sid) {
            Some(p) => history.set_transcript_path(sid, &p),
            None => history.note_not_found(sid),
        }
        changed = true;
    }
    for sid in to_check {
        let Some(path) = history.get(sid).and_then(|e| {
            e.transcript_path.or_else(|| {
                e.project_path
                    .as_deref()
                    .and_then(|c| transcript::expected_path(sid, c))
            })
        }) else {
            continue;
        };
        let Ok(meta) = std::fs::metadata(&path) else {
            continue;
        };
        let mtime_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis() as i64);
        // A file reached through a symlinked folder is never opened.
        let unreadable = !transcript::is_safe_transcript(&path) || check_unreadable(&path);
        history.set_verdict(
            sid,
            FileVerdict {
                size: meta.len(),
                mtime_ms,
                unreadable,
            },
        );
        changed = true;
    }
    changed
}
