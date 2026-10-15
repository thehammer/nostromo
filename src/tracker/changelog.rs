//! Per-board versioned change log and per-session read cursors (contract §3).

use std::collections::{HashMap, HashSet, VecDeque};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use super::model::Change;

/// Changes kept per board.
pub const MAX_ENTRIES: usize = 1_000;
/// Sessions whose cursors are kept.
pub const MAX_CURSOR_SESSIONS: usize = 200;

/// A board's change log. `seq` is the board's version: the seq of the last
/// appended change.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct ChangeLog {
    pub seq: u64,
    pub entries: VecDeque<Change>,
}

/// Why [`ChangeLog::try_append`] refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum ChangeLogError {
    /// `seq` (say, a corrupt persisted one) has no room for the new changes.
    #[error("change log seq {seq} has no room for {count} more changes")]
    SeqOverflow { seq: u64, count: usize },
}

/// What a reader with a cursor gets.
#[derive(Debug, Clone, PartialEq)]
pub enum Since {
    /// No cursor (or one ahead of the log): the reader gets the whole board.
    Full,
    /// Changes after the cursor, excluding the reader's own.
    Changes(Vec<Change>),
    /// The cursor predates the retained entries; `count` changes happened
    /// since it ("read the tracker").
    TooOld { count: u64 },
}

impl ChangeLog {
    pub fn new() -> ChangeLog {
        ChangeLog::default()
    }

    /// Assigns consecutive seqs to `changes`, appends them (dropping the
    /// oldest beyond [`MAX_ENTRIES`]) and returns the new version. A `seq`
    /// that can't take them all (corrupt or exhausted) restarts the log: the
    /// retained entries are dropped and numbering starts from 1, so readers
    /// whose cursor is ahead of the new `seq` get the whole board
    /// ([`Since::Full`]). Use [`ChangeLog::try_append`] to refuse instead.
    pub fn append(&mut self, changes: Vec<Change>) -> u64 {
        if self.try_append_in_place(&changes).is_err() {
            *self = ChangeLog::new();
        }
        for change in changes {
            self.push(change);
        }
        self.seq
    }

    /// As [`ChangeLog::append`], but a `seq` with no room for all of
    /// `changes` is [`ChangeLogError::SeqOverflow`] and the log is unchanged.
    pub fn try_append(&mut self, changes: Vec<Change>) -> Result<u64, ChangeLogError> {
        self.try_append_in_place(&changes)?;
        for change in changes {
            self.push(change);
        }
        Ok(self.seq)
    }

    fn try_append_in_place(&self, changes: &[Change]) -> Result<(), ChangeLogError> {
        u64::try_from(changes.len())
            .ok()
            .and_then(|n| self.seq.checked_add(n))
            .map(|_| ())
            .ok_or(ChangeLogError::SeqOverflow {
                seq: self.seq,
                count: changes.len(),
            })
    }

    fn push(&mut self, mut change: Change) {
        self.seq += 1;
        change.seq = self.seq;
        self.entries.push_back(change);
        if self.entries.len() > MAX_ENTRIES {
            self.entries.pop_front();
        }
    }

    /// Changes after `cursor`. `exclude_session` drops changes authored by
    /// that agent session (no self-echo).
    pub fn since(&self, cursor: Option<u64>, exclude_session: Option<&str>) -> Since {
        let Some(cursor) = cursor else {
            return Since::Full;
        };
        if cursor > self.seq {
            // Ahead of the log (it was reset): the reader's copy can't be trusted.
            return Since::Full;
        }
        if cursor == self.seq {
            return Since::Changes(Vec::new());
        }
        let oldest_kept = self
            .entries
            .front()
            .map_or(self.seq.saturating_add(1), |c| c.seq);
        if cursor.saturating_add(1) < oldest_kept {
            return Since::TooOld {
                count: self.seq - cursor,
            };
        }
        let changes = self
            .entries
            .iter()
            .filter(|c| c.seq > cursor)
            .filter(|c| exclude_session.is_none() || c.by.session_id() != exclude_session)
            .cloned()
            .collect();
        Since::Changes(changes)
    }
}

/// Read cursors keyed by `(session_id, board_key)`, LRU-capped at
/// [`MAX_CURSOR_SESSIONS`] sessions (the least recently `set` session's
/// cursors are dropped).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Cursors {
    entries: Vec<CursorEntry>,
    tick: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct CursorEntry {
    session_id: String,
    board_key: String,
    seq: u64,
    used: u64,
}

impl Cursors {
    pub fn new() -> Cursors {
        Cursors::default()
    }

    pub fn get(&self, session_id: &str, board_key: &str) -> Option<u64> {
        self.entries
            .iter()
            .find(|e| e.session_id == session_id && e.board_key == board_key)
            .map(|e| e.seq)
    }

    pub fn set(&mut self, session_id: &str, board_key: &str, seq: u64) {
        self.tick += 1;
        let used = self.tick;
        match self
            .entries
            .iter_mut()
            .find(|e| e.session_id == session_id && e.board_key == board_key)
        {
            Some(entry) => {
                entry.seq = seq;
                entry.used = used;
            }
            None => self.entries.push(CursorEntry {
                session_id: session_id.to_string(),
                board_key: board_key.to_string(),
                seq,
                used,
            }),
        }
        while self.session_count() > MAX_CURSOR_SESSIONS {
            self.evict_least_recent_session();
        }
    }

    pub fn remove(&mut self, session_id: &str, board_key: &str) {
        self.entries
            .retain(|e| !(e.session_id == session_id && e.board_key == board_key));
    }

    /// Number of distinct sessions with a cursor.
    pub fn session_count(&self) -> usize {
        self.entries
            .iter()
            .map(|e| e.session_id.as_str())
            .collect::<HashSet<_>>()
            .len()
    }

    /// Drops every cursor of the session whose latest `set` is oldest.
    fn evict_least_recent_session(&mut self) {
        let mut last_used: HashMap<&str, u64> = HashMap::new();
        for e in &self.entries {
            let slot = last_used.entry(e.session_id.as_str()).or_default();
            *slot = (*slot).max(e.used);
        }
        let Some(victim) = last_used
            .into_iter()
            .min_by_key(|(_, used)| *used)
            .map(|(session, _)| session.to_string())
        else {
            return;
        };
        self.entries.retain(|e| e.session_id != victim);
    }
}
