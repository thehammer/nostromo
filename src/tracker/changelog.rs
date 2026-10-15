//! Per-board versioned change log and per-session read cursors (contract §3).

use std::collections::{HashMap, HashSet, VecDeque};

use serde::{Deserialize, Serialize};

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
    /// oldest beyond [`MAX_ENTRIES`]) and returns the new version.
    pub fn append(&mut self, changes: Vec<Change>) -> u64 {
        for mut change in changes {
            self.seq += 1;
            change.seq = self.seq;
            self.entries.push_back(change);
        }
        while self.entries.len() > MAX_ENTRIES {
            self.entries.pop_front();
        }
        self.seq
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
        let oldest_kept = self.entries.front().map_or(self.seq + 1, |c| c.seq);
        if cursor + 1 < oldest_kept {
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
