//! Command staging: a short, in-memory list of single-line commands that the
//! agent *following* a local terminal offers the user.
//!
//! The list is display data. Nothing here (and no daemon path) writes a byte to
//! a terminal: the app shows the entries in a drawer, a human click places the
//! text at the prompt through the app's own `terminal_input`, and only the
//! user's Enter runs it. The app then reports the insertion
//! (`terminal_staging_inserted`, which carries no text) and the daemon counts
//! it and tells the follower, in words that never say the command ran.
//!
//! **Who.** A list is owned by the follower at the moment the list was created.
//! A call is allowed only while that same focus still follows the terminal (a
//! paused follow counts) and the list is `Active`. The user stopping the follow
//! (or the follower's session ending) freezes the list: the user can still
//! insert, remove or clear, no agent can change it, and its former follower is
//! told `not_following`. A new follow (invite, request, sheet or a move) starts
//! an empty list; closing, restarting or removing the terminal, or the last
//! operator app going, removes it.
//!
//! **Memory only.** Nothing staged is written to disk, to a log, to the audit
//! trail or to the activity feed. The audit trail gets counts (see
//! [`StagingAudit`]); `TerminalStore` records carry no staging field.
//!
//! **Lock order.** [`StagingStore`]'s lock is a *leaf*: while holding it, never
//! call `FollowManager::inject`, take the terminal manager's lock, the follow
//! manager's `state` lock, write to the audit log, or send to a connection.
//! Every change is computed under the lock and leaves its frames and audit
//! notes in an outbox; whoever made the change then has the terminal manager
//! flush it ([`crate::terminal::TerminalManager::flush_staging`]), which drains
//! the outbox under the manager's lock (so frames reach the app in revision
//! order) and sends and audits outside the staging lock. The follow manager
//! calls the store from under its `state` lock (the store never calls back) and
//! flushes after letting go.

pub mod limits;
pub mod text;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use chrono::{DateTime, SubsecRound, Utc};

use crate::ipc::protocol::{ServerMsg, StagedEntryWire};
use limits::StagingLimits;
pub use text::StagingTextCode;

/// Entries one list holds.
pub const MAX_ENTRIES: usize = 12;
/// Longest command, in Unicode scalars.
pub const MAX_COMMAND_CHARS: usize = 1_000;
/// Longest note, in Unicode scalars.
pub const MAX_NOTE_CHARS: usize = 120;
/// Longest agent name the drawer shows, in Unicode scalars.
pub const MAX_AGENT_NAME_CHARS: usize = 40;
pub use limits::{CHANGES_PER_HOUR, CHANGES_PER_MINUTE};

/// Whether an agent may still change a list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListState {
    Active,
    /// The follow ended: kept for the user, unchangeable by any agent.
    Frozen,
}

impl ListState {
    fn wire(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Frozen => "frozen",
        }
    }
}

/// One staged command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagedEntry {
    /// `s-` and eight lowercase hex digits; never reused.
    pub id: String,
    pub command: String,
    pub note: Option<String>,
    pub staged_at: DateTime<Utc>,
    pub changed_at: DateTime<Utc>,
    pub inserted_count: u32,
    pub last_inserted_at: Option<DateTime<Utc>>,
}

/// A terminal's staging list. Numbers are positions (1-based), never stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagingList {
    pub terminal_id: String,
    pub pane_id: String,
    /// The focus that followed the terminal when the list was created.
    pub owner_tag: String,
    /// The owner's name as the drawer shows it (sanitised).
    pub agent_name: String,
    pub state: ListState,
    pub revision: u64,
    pub entries: Vec<StagedEntry>,
}

impl StagingList {
    fn command_bytes(&self) -> usize {
        self.entries.iter().map(|e| e.command.len()).sum()
    }
}

/// Why a store call changed nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StagingError {
    /// No list for that terminal that the caller owns and may change.
    NotFollowing,
    /// Which text rule refused it, and which field (`command` or `note`).
    Text(StagingTextCode, &'static str),
    InvalidPosition,
    UnknownEntry,
    ListFull,
}

/// What the audit trail is told (counts only; never text). The terminal
/// manager turns each into an `AuditEvent` when it flushes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StagingAudit {
    Changed {
        terminal_id: String,
        owner_tag: String,
        op: &'static str,
        by: &'static str,
        entries: usize,
        bytes: usize,
    },
    Inserted {
        terminal_id: String,
        entry_number: Option<u8>,
        bytes: usize,
        confirmed: bool,
    },
}

/// What a flush hands the terminal manager.
#[derive(Default)]
pub(crate) struct Outbox {
    pub frames: Vec<ServerMsg>,
    pub audits: Vec<StagingAudit>,
}

/// What the app's insert report did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct InsertReport {
    /// The entry's number, when it still existed.
    pub entry_number: Option<u8>,
    /// The owner to tell (the list is `Active` and the entry existed).
    pub notify_owner: Option<String>,
}

#[derive(Default)]
struct State {
    lists: HashMap<String, StagingList>,
    limits: StagingLimits,
    /// Never reused, so a frame of an older list cannot look newer.
    next_revision: u64,
    /// Never reused, so a stale id from an older list names nothing.
    next_entry: u32,
    outbox: Outbox,
}

impl State {
    fn bump(&mut self) -> u64 {
        self.next_revision += 1;
        self.next_revision
    }

    /// `terminal_id`'s list changed: new revision, new frame.
    fn emit(&mut self, terminal_id: &str) {
        let revision = self.bump();
        if let Some(list) = self.lists.get_mut(terminal_id) {
            list.revision = revision;
            self.outbox.frames.push(frame_of(list));
        }
    }

    fn audit_changed(&mut self, terminal_id: &str, op: &'static str, by: &'static str) {
        if let Some(list) = self.lists.get(terminal_id) {
            let audit = StagingAudit::Changed {
                terminal_id: terminal_id.to_string(),
                owner_tag: list.owner_tag.clone(),
                op,
                by,
                entries: list.entries.len(),
                bytes: list.command_bytes(),
            };
            self.outbox.audits.push(audit);
        }
    }

    /// Drop `terminal_id`'s list and say so (`state: none`).
    fn remove_list(&mut self, terminal_id: &str, by: &'static str) {
        let Some(list) = self.lists.remove(terminal_id) else {
            return;
        };
        let revision = self.bump();
        self.outbox
            .frames
            .push(none_frame(terminal_id, &list.pane_id, revision));
        self.outbox.audits.push(StagingAudit::Changed {
            terminal_id: terminal_id.to_string(),
            owner_tag: list.owner_tag,
            op: "clear",
            by,
            entries: 0,
            bytes: 0,
        });
    }

    fn new_entry_id(&mut self) -> String {
        self.next_entry += 1;
        format!("s-{:08x}", self.next_entry)
    }

    /// The list `caller` may change on `terminal_id`.
    fn owned_by(
        &mut self,
        caller: &str,
        terminal_id: &str,
    ) -> Result<&mut StagingList, StagingError> {
        self.lists
            .get_mut(terminal_id)
            .filter(|l| l.state == ListState::Active && l.owner_tag == caller)
            .ok_or(StagingError::NotFollowing)
    }
}

/// Every terminal's staging list. See the [module docs](self).
pub struct StagingStore {
    state: Mutex<State>,
}

impl Default for StagingStore {
    fn default() -> Self {
        Self::new_inner()
    }
}

impl StagingStore {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::new_inner())
    }

    fn new_inner() -> Self {
        Self {
            state: Mutex::new(State::default()),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ── agent operations ──────────────────────────────────────────────────────

    /// Count one change by `tag` against its rate limit, or the seconds to wait.
    pub fn take_change(&self, tag: &str, now: Instant) -> Result<(), u64> {
        self.lock().limits.take(tag, now)
    }

    /// `terminal_id`'s list, for `caller`, who must own it and may change it.
    pub fn list(
        &self,
        caller: &str,
        terminal_id: &str,
        agent_name: &str,
    ) -> Result<StagingList, StagingError> {
        let mut state = self.lock();
        let list = state.owned_by(caller, terminal_id)?;
        list.agent_name = agent_name.to_string();
        Ok(list.clone())
    }

    /// Stage `command` (before the entry at `position`, else at the end).
    /// Returns the new entry's id, number and the list's length.
    pub fn stage(
        &self,
        caller: &str,
        terminal_id: &str,
        agent_name: &str,
        command: &str,
        note: Option<&str>,
        position: Option<usize>,
    ) -> Result<(String, usize, usize), StagingError> {
        let command_ok =
            text::validate_command(command).map_err(|c| StagingError::Text(c, "command"));
        let note = note
            .map(|n| text::clean_note(n).map_err(|c| StagingError::Text(c, "note")))
            .transpose();
        let mut state = self.lock();
        state.owned_by(caller, terminal_id)?;
        command_ok?;
        let note = note?.flatten();
        let count = state.owned_by(caller, terminal_id)?.entries.len();
        let at = match position {
            None => count,
            Some(p) if (1..=count + 1).contains(&p) => p - 1,
            Some(_) => return Err(StagingError::InvalidPosition),
        };
        if count >= MAX_ENTRIES {
            return Err(StagingError::ListFull);
        }
        let id = state.new_entry_id();
        let now = now_utc();
        let list = state.owned_by(caller, terminal_id)?;
        list.agent_name = agent_name.to_string();
        list.entries.insert(
            at,
            StagedEntry {
                id: id.clone(),
                command: command.to_string(),
                note,
                staged_at: now,
                changed_at: now,
                inserted_count: 0,
                last_inserted_at: None,
            },
        );
        let len = list.entries.len();
        state.emit(terminal_id);
        state.audit_changed(terminal_id, "stage", "agent");
        Ok((id, at + 1, len))
    }

    /// Replace an entry's command and/or note (`note: Some("")` clears it).
    /// A changed command resets the insert counts. Returns the entry's number.
    pub fn replace(
        &self,
        caller: &str,
        terminal_id: &str,
        agent_name: &str,
        entry_id: &str,
        command: Option<&str>,
        note: Option<&str>,
    ) -> Result<usize, StagingError> {
        let command_ok = command
            .map(|c| text::validate_command(c).map_err(|c| StagingError::Text(c, "command")))
            .transpose();
        let note = note
            .map(|n| text::clean_note(n).map_err(|c| StagingError::Text(c, "note")))
            .transpose();
        let mut state = self.lock();
        state.owned_by(caller, terminal_id)?;
        command_ok?;
        let note = note?;
        let list = state.owned_by(caller, terminal_id)?;
        let at = list
            .entries
            .iter()
            .position(|e| e.id == entry_id)
            .ok_or(StagingError::UnknownEntry)?;
        list.agent_name = agent_name.to_string();
        let entry = &mut list.entries[at];
        if let Some(command) = command {
            if entry.command != command {
                entry.inserted_count = 0;
                entry.last_inserted_at = None;
            }
            entry.command = command.to_string();
        }
        if let Some(note) = note {
            entry.note = note;
        }
        entry.changed_at = now_utc();
        state.emit(terminal_id);
        state.audit_changed(terminal_id, "replace", "agent");
        Ok(at + 1)
    }

    /// Remove an entry. Returns how many remain.
    pub fn remove(
        &self,
        caller: &str,
        terminal_id: &str,
        agent_name: &str,
        entry_id: &str,
    ) -> Result<usize, StagingError> {
        let mut state = self.lock();
        let list = state.owned_by(caller, terminal_id)?;
        let at = list
            .entries
            .iter()
            .position(|e| e.id == entry_id)
            .ok_or(StagingError::UnknownEntry)?;
        list.agent_name = agent_name.to_string();
        list.entries.remove(at);
        let len = list.entries.len();
        state.emit(terminal_id);
        state.audit_changed(terminal_id, "remove", "agent");
        Ok(len)
    }

    /// Remove every entry.
    pub fn clear(
        &self,
        caller: &str,
        terminal_id: &str,
        agent_name: &str,
    ) -> Result<(), StagingError> {
        let mut state = self.lock();
        let list = state.owned_by(caller, terminal_id)?;
        list.agent_name = agent_name.to_string();
        list.entries.clear();
        state.emit(terminal_id);
        state.audit_changed(terminal_id, "clear", "agent");
        Ok(())
    }

    // ── the user's operations (from the app) ──────────────────────────────────

    /// The app inserted an entry and says so. Counts it when the entry still
    /// exists; always audited (counts only).
    pub(crate) fn inserted(
        &self,
        terminal_id: &str,
        entry_id: &str,
        bytes: u32,
        confirmed: bool,
    ) -> InsertReport {
        let mut state = self.lock();
        let found = state.lists.get_mut(terminal_id).and_then(|list| {
            let at = list.entries.iter().position(|e| e.id == entry_id)?;
            let now = now_utc();
            let entry = &mut list.entries[at];
            entry.inserted_count = entry.inserted_count.saturating_add(1);
            entry.last_inserted_at = Some(now);
            let number = u8::try_from(at + 1).ok()?;
            let owner = (list.state == ListState::Active).then(|| list.owner_tag.clone());
            Some((number, owner))
        });
        if found.is_some() {
            state.emit(terminal_id);
        }
        state.outbox.audits.push(StagingAudit::Inserted {
            terminal_id: terminal_id.to_string(),
            entry_number: found.as_ref().map(|(n, _)| *n),
            bytes: bytes as usize,
            confirmed,
        });
        InsertReport {
            entry_number: found.as_ref().map(|(n, _)| *n),
            notify_owner: found.and_then(|(_, owner)| owner),
        }
    }

    /// The user removed an entry. `false` when there was no such entry.
    pub(crate) fn user_remove(&self, terminal_id: &str, entry_id: &str) -> bool {
        let mut state = self.lock();
        let Some(list) = state.lists.get_mut(terminal_id) else {
            return false;
        };
        let Some(at) = list.entries.iter().position(|e| e.id == entry_id) else {
            return false;
        };
        list.entries.remove(at);
        let emptied_frozen = list.state == ListState::Frozen && list.entries.is_empty();
        if emptied_frozen {
            state.remove_list(terminal_id, "user");
        } else {
            state.emit(terminal_id);
            state.audit_changed(terminal_id, "remove", "user");
        }
        true
    }

    /// The user cleared the list. A frozen list is removed; `false` when there
    /// was none.
    pub(crate) fn user_clear(&self, terminal_id: &str) -> bool {
        let mut state = self.lock();
        let Some(list) = state.lists.get_mut(terminal_id) else {
            return false;
        };
        if list.state == ListState::Frozen {
            state.remove_list(terminal_id, "user");
        } else {
            list.entries.clear();
            state.emit(terminal_id);
            state.audit_changed(terminal_id, "clear", "user");
        }
        true
    }

    // ── lifecycle ─────────────────────────────────────────────────────────────

    /// `owner` now follows `terminal_id`: whatever list there was is replaced
    /// by an empty one the new follower owns.
    pub(crate) fn follow_started(
        &self,
        terminal_id: &str,
        pane_id: &str,
        owner: &str,
        agent_name: &str,
    ) {
        let mut state = self.lock();
        let moved = state
            .lists
            .get(terminal_id)
            .is_some_and(|l| l.owner_tag != owner);
        state.lists.insert(
            terminal_id.to_string(),
            StagingList {
                terminal_id: terminal_id.to_string(),
                pane_id: pane_id.to_string(),
                owner_tag: owner.to_string(),
                agent_name: agent_name.to_string(),
                state: ListState::Active,
                revision: 0,
                entries: Vec::new(),
            },
        );
        state.emit(terminal_id);
        state.audit_changed(
            terminal_id,
            "clear",
            if moved {
                "follow_moved"
            } else {
                "follow_started"
            },
        );
    }

    /// The follow ended by the user (or the follower's session ended): the list
    /// is kept, frozen.
    pub(crate) fn follow_ended(&self, terminal_id: &str) {
        let mut state = self.lock();
        let Some(list) = state.lists.get_mut(terminal_id) else {
            return;
        };
        if list.state == ListState::Frozen {
            return;
        }
        list.state = ListState::Frozen;
        state.emit(terminal_id);
    }

    /// The terminal is gone (closed, restarted, its focus removed).
    pub(crate) fn terminal_gone(&self, terminal_id: &str) {
        self.drop_list(terminal_id, "terminal_closed");
    }

    /// Drop `terminal_id`'s list, whatever its state; `by` is what the audit
    /// trail says caused it.
    pub(crate) fn drop_list(&self, terminal_id: &str, by: &'static str) {
        self.lock().remove_list(terminal_id, by);
    }

    /// The last operator app is gone: no one is left to see a list.
    pub(crate) fn app_closed(&self) {
        let mut state = self.lock();
        let ids: Vec<String> = state.lists.keys().cloned().collect();
        for id in ids {
            state.remove_list(&id, "app_closed");
        }
    }

    // ── reads and the outbox ──────────────────────────────────────────────────

    /// Every list's frame as it stands (without changing anything): what a
    /// connection that just declared `terminal_staging_ui` is sent.
    pub(crate) fn frames_of_all(&self) -> Vec<ServerMsg> {
        let state = self.lock();
        let mut lists: Vec<&StagingList> = state.lists.values().collect();
        lists.sort_by(|a, b| a.terminal_id.cmp(&b.terminal_id));
        lists.into_iter().map(frame_of).collect()
    }

    /// Take what the changes so far left to send and audit.
    pub(crate) fn drain(&self) -> Outbox {
        std::mem::take(&mut self.lock().outbox)
    }

    /// The list as it stands, whoever owns it (tests, and the lock-order proof).
    pub fn peek(&self, terminal_id: &str) -> Option<StagingList> {
        self.lock().lists.get(terminal_id).cloned()
    }
}

fn now_utc() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(3)
}

fn wire_entries(list: &StagingList) -> Vec<StagedEntryWire> {
    list.entries
        .iter()
        .enumerate()
        .map(|(i, e)| StagedEntryWire {
            id: e.id.clone(),
            number: (i + 1) as u32,
            command: e.command.clone(),
            note: e.note.clone(),
            staged_at: e.staged_at,
            changed_at: e.changed_at,
            inserted_count: e.inserted_count,
            last_inserted_at: e.last_inserted_at,
        })
        .collect()
}

/// `list` as the frame the app is sent.
pub(crate) fn frame_of(list: &StagingList) -> ServerMsg {
    ServerMsg::TerminalStagingList {
        terminal_id: list.terminal_id.clone(),
        pane_id: list.pane_id.clone(),
        state: list.state.wire().to_string(),
        owner_tag: list.owner_tag.clone(),
        agent_name: list.agent_name.clone(),
        revision: list.revision,
        entries: wire_entries(list),
    }
}

/// "No list": the app closes the drawer.
pub(crate) fn none_frame(terminal_id: &str, pane_id: &str, revision: u64) -> ServerMsg {
    ServerMsg::TerminalStagingList {
        terminal_id: terminal_id.to_string(),
        pane_id: pane_id.to_string(),
        state: "none".to_string(),
        owner_tag: String::new(),
        agent_name: String::new(),
        revision,
        entries: Vec::new(),
    }
}
