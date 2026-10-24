//! The daemon's tracker state: boards by canonical path, which focus is bound
//! to which board, per-session read cursors, the change log, banner state and
//! the last-good copy of every board (contract §3).
//!
//! Everything a board's file needs goes through here, behind one `Mutex`:
//! `open` creates or adopts a file, `apply` is the read-modify-write path
//! (re-read the file, ingest any external edit as `File`, apply the ops on top,
//! write atomically), `read` serves deltas through the session's cursor, and
//! `ingest_file_change` is what the watcher calls. Every operation that changes
//! what a client sees marks the board dirty; [`TrackerRegistry::flush`] sends
//! the dirty boards' frames.
//!
//! State is persisted to `<state_root>/trackers/state.json` (bindings, change
//! logs, cursors) and `<state_root>/trackers/last-good/<fnv64-of-path>.md`
//! (the last cleanly parsed bytes of each board, for recreate). The clock, the
//! state root, the home directory and the file system are injected.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{DateTime, FixedOffset, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::broadcast;

use super::changelog::{ChangeLog, Cursors, Since};
use super::clock::{Clock, SystemClock};
use super::diff::diff;
use super::format::{parse, template, Malformed, ParsedBoard};
use super::model::{fnv1a64, slug, Author, Board, Counts, Kind, Stamp, Status};
use super::ops::{apply_to_file, Op, OpError, WriteError};
use super::paths::{
    default_path, find_repo_root, is_valid_topic, probe_committable, resolve_board_path, RepoRoot,
};
use super::render::{compact_full, delta_entries};
use super::view::{self, Banner, Committable, TrackerBoardView, ViewFacts};
use super::watch::{
    spawn_dir_watcher, write_atomic, BoardFs, FileSignature, RealBoardFs, WatchHost,
};
use crate::ipc::pane_registry::TrackerFrameProvider;
use crate::ipc::protocol::ServerMsg;

/// What `open` is asked for.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct OpenArgs {
    pub topic: Option<String>,
    pub title: Option<String>,
    /// Section titles for a new board; empty means the template's.
    pub sections: Vec<String>,
    /// Explicit board path (absolute, or relative to the repo root).
    pub path: Option<String>,
    /// Re-add the pane after the user closed it.
    pub show: bool,
    /// The focus's working directory: the repo root is found from it.
    pub cwd: PathBuf,
}

/// What `open` did.
#[derive(Debug, Clone, PartialEq)]
pub struct OpenOutcome {
    pub path: PathBuf,
    pub created: bool,
    pub recreated: bool,
    pub version: u64,
    pub counts: Counts,
    /// The board sits where a commit would pick it up.
    pub committable: bool,
    /// The user closed the pane and `show` was not passed.
    pub hidden_by_user: bool,
    /// The compact full render, on this session's first open of the board.
    pub board: Option<String>,
}

/// What a successful write did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WriteOutcome {
    pub version: u64,
    /// Changes by the user (pane or file) this session hasn't read yet.
    pub user_changes: u32,
}

/// What `read` returns.
#[derive(Debug, Clone, PartialEq)]
pub enum ReadOutcome {
    /// The session had no usable cursor: the whole board.
    Full { version: u64, board: String },
    /// Changes since the session's cursor (its own excluded), as delta entries.
    Delta { version: u64, changes: Vec<Value> },
}

/// A focus's tracker in two numbers for a network peer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrackerSummary {
    pub has_tracker: bool,
    pub counts: Counts,
}

/// Why a tracker call failed. [`TrackerError::code`] is the stable error code
/// of the tool response.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TrackerError {
    #[error("this focus has no tracker open")]
    NoTracker,
    #[error("op {index}: unknown item {id}")]
    UnknownItem { index: usize, id: String },
    #[error("op {index}: invalid status {value:?}")]
    InvalidStatus { index: usize, value: String },
    #[error("invalid arguments: {reason}")]
    InvalidArgs {
        index: Option<usize>,
        reason: String,
    },
    #[error("the board file is unreadable at line {line}: {reason}")]
    BoardUnreadable { line: usize, reason: String },
    #[error("the board file is missing")]
    BoardMissing,
    #[error("board too large: {bytes} bytes, {items} items")]
    BoardTooLarge { bytes: usize, items: usize },
    #[error("path not allowed")]
    PathNotAllowed,
    /// An agent tried to mark a command item done, or to change the command
    /// of one that is done ("Ran it" is the user's, and is about that text).
    #[error("only the user can mark command {id} done or change it once done")]
    NotPermitted { id: String },
    #[error("i/o error: {0}")]
    Io(String),
}

impl TrackerError {
    pub fn code(&self) -> &'static str {
        match self {
            TrackerError::NoTracker => "no_tracker",
            TrackerError::UnknownItem { .. } => "unknown_item",
            TrackerError::InvalidStatus { .. } => "invalid_status",
            TrackerError::InvalidArgs { .. } => "invalid_args",
            TrackerError::BoardUnreadable { .. } => "board_unreadable",
            TrackerError::BoardMissing => "board_missing",
            TrackerError::BoardTooLarge { .. } => "board_too_large",
            TrackerError::PathNotAllowed => "path_not_allowed",
            TrackerError::NotPermitted { .. } => "not_permitted",
            TrackerError::Io(_) => "io_error",
        }
    }
}

impl From<Malformed> for TrackerError {
    fn from(m: Malformed) -> Self {
        TrackerError::BoardUnreadable {
            line: m.line,
            reason: m.reason.code().to_string(),
        }
    }
}

impl From<WriteError> for TrackerError {
    fn from(err: WriteError) -> Self {
        match err {
            WriteError::Malformed(m) => m.into(),
            WriteError::Op(op) => op.into(),
        }
    }
}

impl From<OpError> for TrackerError {
    fn from(err: OpError) -> Self {
        match err {
            OpError::UnknownItem { index, id } => TrackerError::UnknownItem { index, id },
            OpError::InvalidStatus { index, value } => TrackerError::InvalidStatus { index, value },
            OpError::InvalidArgs { index, reason } => TrackerError::InvalidArgs {
                index: Some(index),
                reason,
            },
            OpError::BoardTooLarge { bytes, items } => TrackerError::BoardTooLarge { bytes, items },
        }
    }
}

/// What the daemon knows about a calling focus when the session manager
/// can't say (tests: a focus with no spawned `claude`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CallerFacts {
    pub cwd: Option<PathBuf>,
    pub session_id: Option<String>,
}

/// Everything injected into a registry.
pub struct RegistryParts {
    /// `~/.nostromo` in production; `None` keeps state in memory only.
    pub state_root: Option<PathBuf>,
    /// The home directory whose `.claude/wip/` boards may also live in.
    pub home: Option<PathBuf>,
    pub clock: Arc<dyn Clock>,
    pub fs: Arc<dyn BoardFs>,
    /// The offset the file's `HH:MM` times are written in; `None` = local time.
    pub utc_offset: Option<FixedOffset>,
}

impl RegistryParts {
    /// The daemon's: the real clock, file system and local time zone.
    pub fn production(state_root: PathBuf, home: Option<PathBuf>) -> RegistryParts {
        RegistryParts {
            state_root: Some(state_root),
            home,
            clock: Arc::new(SystemClock),
            fs: Arc::new(RealBoardFs),
            utc_offset: None,
        }
    }

    /// For tests: real files under temp roots, the given clock, UTC times.
    pub fn hermetic(state_root: PathBuf, home: PathBuf, clock: Arc<dyn Clock>) -> RegistryParts {
        RegistryParts {
            state_root: Some(state_root),
            home: Some(home),
            clock,
            fs: Arc::new(RealBoardFs),
            utc_offset: Some(FixedOffset::east_opt(0).expect("zero offset")),
        }
    }
}

/// One board's in-memory state.
struct BoardEntry {
    topic: String,
    /// The root the board was allowed under; every write checks the path
    /// against it again.
    root: RepoRoot,
    /// The last cleanly parsed board (what the pane shows under a banner).
    parsed: Option<ParsedBoard>,
    /// The bytes `parsed` came from.
    last_ingested: Option<Vec<u8>>,
    /// The bytes of the daemon's own latest write.
    own_bytes: Option<Vec<u8>>,
    log: ChangeLog,
    banner: Option<Banner>,
    last_good_at: Option<DateTime<Utc>>,
    committable: Option<Committable>,
}

impl BoardEntry {
    fn new(topic: &str, root: RepoRoot) -> BoardEntry {
        BoardEntry {
            topic: topic.to_string(),
            root,
            parsed: None,
            last_ingested: None,
            own_bytes: None,
            log: ChangeLog::new(),
            banner: None,
            last_good_at: None,
            committable: None,
        }
    }
}

#[derive(Default)]
struct Inner {
    boards: HashMap<PathBuf, BoardEntry>,
    bindings: HashMap<String, PathBuf>,
    cursors: Cursors,
    hidden: HashSet<String>,
    callers: HashMap<String, CallerFacts>,
    dirty: BTreeSet<PathBuf>,
}

/// The tracker state of the whole daemon.
pub struct TrackerRegistry {
    inner: Mutex<Inner>,
    state_root: Option<PathBuf>,
    home: Option<PathBuf>,
    clock: Arc<dyn Clock>,
    fs: Arc<dyn BoardFs>,
    utc_offset: Option<FixedOffset>,
    /// Serialises `flush` so two snapshots of one board can't cross.
    flush_lock: Mutex<()>,
    watch: Mutex<Option<WatchHost>>,
}

impl Default for TrackerRegistry {
    /// No persistence, the real clock and file system: the registry of every
    /// daemon backend that doesn't exercise the tracker.
    fn default() -> Self {
        TrackerRegistry::new(RegistryParts {
            state_root: None,
            home: None,
            clock: Arc::new(SystemClock),
            fs: Arc::new(RealBoardFs),
            utc_offset: None,
        })
    }
}

#[derive(Serialize, Deserialize, Default)]
struct PersistedState {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    bindings: BTreeMap<String, String>,
    #[serde(default)]
    boards: BTreeMap<String, PersistedBoard>,
    #[serde(default)]
    cursors: Cursors,
    /// Focuses whose tracker pane the user closed; absent in older state
    /// (then nothing is hidden).
    #[serde(default)]
    hidden: BTreeSet<String>,
}

#[derive(Serialize, Deserialize)]
struct PersistedBoard {
    topic: String,
    /// The root the board was allowed under; absent in state written before
    /// it was recorded (then it is derived from the board's path).
    #[serde(default)]
    root: Option<String>,
    #[serde(default)]
    git: bool,
    log: ChangeLog,
    #[serde(default)]
    last_good_at: Option<DateTime<Utc>>,
    #[serde(default)]
    committable: Option<Committable>,
}

impl TrackerRegistry {
    /// Builds the registry, loads persisted state and re-reads every board
    /// (an edit made while the daemon was down is ingested as `File`).
    pub fn new(parts: RegistryParts) -> TrackerRegistry {
        let registry = TrackerRegistry {
            inner: Mutex::new(Inner::default()),
            state_root: parts.state_root,
            home: parts.home,
            clock: parts.clock,
            fs: parts.fs,
            utc_offset: parts.utc_offset,
            flush_lock: Mutex::new(()),
            watch: Mutex::new(None),
        };
        registry.load();
        registry
    }

    // ── public API ───────────────────────────────────────────────────────────

    /// Opens (creates, adopts or recreates) the board for `tag`, and binds it.
    /// Idempotent: opening a board that is already bound changes no bytes.
    pub fn open(
        &self,
        tag: &str,
        session: &str,
        args: &OpenArgs,
    ) -> Result<OpenOutcome, TrackerError> {
        let (root, topic, path) = self.resolve_open(args)?;
        let committable = probe_committable(&root.dir, &path);

        let mut inner = self.lock();
        let known = inner.boards.contains_key(&path);
        let mut entry = inner
            .boards
            .remove(&path)
            .unwrap_or_else(|| BoardEntry::new(&topic, root.clone()));
        entry.root = root;
        let opened = self.open_board(&mut entry, &path, args, &topic, known);
        let (created, recreated) = match opened {
            Ok(flags) => flags,
            Err(err) => {
                // A board we never could read isn't kept; a known one stays.
                if known {
                    inner.boards.insert(path.clone(), entry);
                    inner.dirty.insert(path);
                    self.persist(&inner);
                }
                return Err(err);
            }
        };
        entry.committable = committable.clone();
        let key = key_of(&path);
        let version = entry.log.seq;
        let counts = entry
            .parsed
            .as_ref()
            .map(|p| p.board.counts())
            .unwrap_or_default();
        let board = (inner.cursors.get(session, &key).is_none())
            .then(|| entry.parsed.as_ref().map(|p| compact_full(&p.board)))
            .flatten();
        inner.boards.insert(path.clone(), entry);
        inner.cursors.set(session, &key, version);
        inner.bindings.insert(tag.to_string(), path.clone());
        let hidden_by_user = inner.hidden.contains(tag) && !args.show;
        if args.show {
            inner.hidden.remove(tag);
        }
        inner.dirty.insert(path.clone());
        self.persist(&inner);
        drop(inner);
        self.ensure_watch(&path);
        Ok(OpenOutcome {
            path,
            created,
            recreated,
            version,
            counts,
            committable: committable.is_some(),
            hidden_by_user,
            board,
        })
    }

    /// Applies `ops` atomically to the board bound to `tag`, attributed to
    /// `author`: re-reads the file first, ingesting any external edit, then
    /// writes the result. `session` is the writer's session (the cursor the
    /// returned `user_changes` is counted from).
    pub fn apply(
        &self,
        tag: &str,
        session: &str,
        ops: &[Op],
        author: &Author,
    ) -> Result<WriteOutcome, TrackerError> {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let path = inner
            .bindings
            .get(tag)
            .cloned()
            .ok_or(TrackerError::NoTracker)?;
        let entry = inner.boards.get_mut(&path).ok_or(TrackerError::NoTracker)?;
        let result = self.write_ops(entry, &path, ops, author);
        let cursor = inner.cursors.get(session, &key_of(&path));
        let user_changes = user_changes_of(entry, cursor, session);
        let version = entry.log.seq;
        // Even a refused write may have ingested an external edit.
        inner.dirty.insert(path);
        self.persist(inner);
        result.map(|()| WriteOutcome {
            version,
            user_changes,
        })
    }

    /// The changes `session` hasn't seen (or the whole board on its first
    /// read), and advances its cursor.
    pub fn read(&self, tag: &str, session: &str) -> Result<ReadOutcome, TrackerError> {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let path = inner
            .bindings
            .get(tag)
            .cloned()
            .ok_or(TrackerError::NoTracker)?;
        let key = key_of(&path);
        let entry = inner.boards.get_mut(&path).ok_or(TrackerError::NoTracker)?;
        self.recheck_path(entry, &path)?;
        // Serve what the file says now, even if the watcher hasn't fired.
        let ingested = self.ingest_from_disk(entry, &path);
        let version = entry.log.seq;
        let board = entry.parsed.as_ref().map(|p| &p.board);
        let outcome = match (
            board,
            entry
                .log
                .since(inner.cursors.get(session, &key), Some(session)),
        ) {
            (Some(board), Since::Full | Since::TooOld { .. }) => ReadOutcome::Full {
                version,
                board: compact_full(board),
            },
            (_, Since::Changes(changes)) => ReadOutcome::Delta {
                version,
                changes: delta_entries(&changes),
            },
            (None, _) => ReadOutcome::Delta {
                version,
                changes: Vec::new(),
            },
        };
        inner.cursors.set(session, &key, version);
        if ingested {
            inner.dirty.insert(path);
        }
        self.persist(inner);
        Ok(outcome)
    }

    /// Re-reads `path` after a file signal. `true` when what a client sees
    /// changed (an external edit, a banner appearing or clearing). The
    /// daemon's own writes read back as the bytes it wrote and change nothing.
    pub fn ingest_file_change(&self, path: &Path) -> bool {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let Some(key) = self.board_key(inner, path) else {
            return false;
        };
        let Some(entry) = inner.boards.get_mut(&key) else {
            return false;
        };
        if let Some(dir) = key.parent() {
            self.fs.remove_stale_temps(dir);
        }
        let changed = self.ingest_from_disk(entry, &key);
        if changed {
            inner.dirty.insert(key);
            self.persist(inner);
        }
        changed
    }

    /// Changes by the user (pane or file) after `session`'s cursor on the
    /// board bound to `tag`, its own writes excluded. 0 when it has no cursor.
    pub fn user_changes(&self, tag: &str, session: &str) -> u32 {
        let inner = self.lock();
        let Some(path) = inner.bindings.get(tag) else {
            return 0;
        };
        match inner.boards.get(path) {
            Some(entry) => {
                user_changes_of(entry, inner.cursors.get(session, &key_of(path)), session)
            }
            None => 0,
        }
    }

    /// What the pane shows for `tag`; `None` when no board is bound.
    pub fn board_view(&self, tag: &str) -> Option<TrackerBoardView> {
        let inner = self.lock();
        let path = inner.bindings.get(tag)?;
        let entry = inner.boards.get(path)?;
        let parsed = entry.parsed.as_ref()?;
        Some(view::build(
            parsed,
            &ViewFacts {
                path: path.display().to_string(),
                topic: entry.topic.clone(),
                version: entry.log.seq,
                file_mtime: self
                    .fs
                    .signature(path)
                    .and_then(|s| s.modified)
                    .map(DateTime::<Utc>::from),
                banner: entry.banner.clone(),
                committable: entry.committable.clone(),
                hidden_by_user: inner.hidden.contains(tag),
            },
        ))
    }

    /// Whether `tag` has a tracker and its per-status counts.
    pub fn summary(&self, tag: &str) -> TrackerSummary {
        let inner = self.lock();
        let counts = inner
            .bindings
            .get(tag)
            .and_then(|path| inner.boards.get(path))
            .and_then(|entry| entry.parsed.as_ref())
            .map(|parsed| parsed.board.counts());
        TrackerSummary {
            has_tracker: counts.is_some(),
            counts: counts.unwrap_or_default(),
        }
    }

    /// The tags bound to the board at `path`, sorted.
    pub fn bound_tags_for(&self, path: &Path) -> Vec<String> {
        let inner = self.lock();
        let Some(key) = self.board_key(&inner, path) else {
            return Vec::new();
        };
        let mut tags: Vec<String> = inner
            .bindings
            .iter()
            .filter(|(_, p)| **p == key)
            .map(|(tag, _)| tag.clone())
            .collect();
        tags.sort();
        tags
    }

    /// The board path `tag` is bound to.
    pub fn bound_path(&self, tag: &str) -> Option<PathBuf> {
        self.lock().bindings.get(tag).cloned()
    }

    /// The user closed (or re-opened) the pane of `tag` (T0c).
    pub fn set_pane_hidden_by_user(&self, tag: &str, hidden: bool) {
        let mut inner = self.lock();
        let changed = if hidden {
            inner.hidden.insert(tag.to_string())
        } else {
            inner.hidden.remove(tag)
        };
        if changed {
            if let Some(path) = inner.bindings.get(tag).cloned() {
                inner.dirty.insert(path);
            }
            self.persist(&inner);
        }
    }

    pub fn pane_hidden_by_user(&self, tag: &str) -> bool {
        self.lock().hidden.contains(tag)
    }

    /// The pane of `tag` left its layout (the user closed it, or an agent's
    /// layout call dropped it): the binding stays, writes go on, and `open`
    /// won't re-add the pane without `show`. No-op without a bound board.
    pub fn mark_pane_closed(&self, tag: &str) {
        if self.lock().bindings.contains_key(tag) {
            self.set_pane_hidden_by_user(tag, true);
        }
    }

    /// Makes the registry follow `panes`: whenever a layout mutation removes
    /// the tracker leaf from a focus, that focus's pane counts as closed by
    /// the user; when one puts it back, it doesn't. Views of the change are
    /// flushed to `tx`. One hook on the pane registry, so no layout tool needs
    /// to know about the tracker.
    pub fn follow_panes(
        self: &Arc<Self>,
        panes: &std::sync::Mutex<crate::ipc::pane_registry::PaneRegistry>,
        tx: broadcast::Sender<ServerMsg>,
    ) {
        let registry = Arc::clone(self);
        let hook: crate::ipc::pane_registry::PaneSetHook = Arc::new(move |tag, removed, added| {
            if added.iter().any(|p| p == super::placement::TRACKER_PANE_ID) {
                registry.set_pane_hidden_by_user(tag, false);
            }
            if removed
                .iter()
                .any(|p| p == super::placement::TRACKER_PANE_ID)
            {
                registry.mark_pane_closed(tag);
            }
            registry.flush(&tx);
        });
        panes
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .set_pane_set_hook(hook);
    }

    /// The topic of the board bound to `tag`, when there is one.
    pub fn bound_topic(&self, tag: &str) -> Option<String> {
        let inner = self.lock();
        let path = inner.bindings.get(tag)?;
        inner.boards.get(path).map(|entry| entry.topic.clone())
    }

    /// Whether `tag` has a bound board (a fresh session re-attaches the pane).
    pub fn has_bound_board(&self, tag: &str) -> bool {
        self.lock().bindings.contains_key(tag)
    }

    /// Test seam: what the registry should believe about `tag`'s focus when
    /// the session manager has no spawned session for it.
    pub fn set_caller_facts(&self, tag: &str, facts: CallerFacts) {
        self.lock().callers.insert(tag.to_string(), facts);
    }

    pub fn caller_facts(&self, tag: &str) -> Option<CallerFacts> {
        self.lock().callers.get(tag).cloned()
    }

    /// The frames that bring `tag`'s clients up to date: its board and summary.
    pub fn frames_for_tag(&self, tag: &str) -> Vec<ServerMsg> {
        let summary = self.summary(tag);
        vec![
            ServerMsg::TrackerBoard {
                tag: tag.to_string(),
                board: self.board_view(tag),
            },
            ServerMsg::TrackerSummary {
                tag: tag.to_string(),
                has_tracker: summary.has_tracker,
                counts: summary.counts,
            },
        ]
    }

    /// The frames for every tag bound to the board at `path`.
    pub fn frames_for(&self, path: &Path) -> Vec<ServerMsg> {
        self.bound_tags_for(path)
            .iter()
            .flat_map(|tag| self.frames_for_tag(tag))
            .collect()
    }

    /// Sends the frames of every board whose view changed since the last
    /// flush. Call after any operation that may have changed a board.
    pub fn flush(&self, tx: &broadcast::Sender<ServerMsg>) {
        let _serialised = self.flush_lock.lock().unwrap_or_else(|e| e.into_inner());
        let dirty = std::mem::take(&mut self.lock().dirty);
        for path in dirty {
            for frame in self.frames_for(&path) {
                let _ = tx.send(frame);
            }
        }
    }

    /// Starts the file watchers: one task per board directory, now and for
    /// every board opened later. Needs a tokio runtime.
    pub fn start_watching(self: &Arc<Self>, tx: broadcast::Sender<ServerMsg>) {
        *self.watch.lock().unwrap_or_else(|e| e.into_inner()) = Some(WatchHost {
            registry: Arc::downgrade(self),
            tx,
            dirs: HashSet::new(),
        });
        let paths: Vec<PathBuf> = self.lock().boards.keys().cloned().collect();
        for path in paths {
            self.ensure_watch(&path);
        }
    }

    /// The boards (canonical paths) that live directly in `dir`.
    pub fn boards_in_dir(&self, dir: &Path) -> Vec<PathBuf> {
        self.lock()
            .boards
            .keys()
            .filter(|p| p.parent() == Some(dir))
            .cloned()
            .collect()
    }

    /// The file's current signature, `None` when it doesn't exist.
    pub fn board_signature(&self, path: &Path) -> Option<FileSignature> {
        self.fs.signature(path)
    }

    pub fn is_board(&self, path: &Path) -> bool {
        self.lock().boards.contains_key(path)
    }

    // ── open ─────────────────────────────────────────────────────────────────

    /// The repo root, topic and canonical board path an `open` names.
    fn resolve_open(&self, args: &OpenArgs) -> Result<(RepoRoot, String, PathBuf), TrackerError> {
        let invalid = |reason: &str| TrackerError::InvalidArgs {
            index: None,
            reason: reason.to_string(),
        };
        if let Some(topic) = &args.topic {
            if !is_valid_topic(topic) {
                return Err(invalid("topic must match ^[a-z0-9][a-z0-9-]{0,47}$"));
            }
        }
        let found = find_repo_root(&args.cwd);
        let root = RepoRoot {
            dir: std::fs::canonicalize(&found.dir)
                .map_err(|e| TrackerError::Io(e.kind().to_string()))?,
            git: found.git,
        };
        let requested = match (&args.path, &args.topic) {
            (Some(path), _) => PathBuf::from(path),
            (None, Some(topic)) => default_path(&root.dir, topic),
            (None, None) => return Err(invalid("open needs a topic or a path")),
        };
        let path = resolve_board_path(&root, self.home.as_deref(), &requested)
            .map_err(|_| TrackerError::PathNotAllowed)?;
        let topic = args
            .topic
            .clone()
            .or_else(|| topic_from_path(&path))
            .unwrap_or_else(|| "board".to_string());
        Ok((root, topic, path))
    }

    /// Brings `entry` in line with the file at `path`, creating, adopting or
    /// recreating it. Returns `(created, recreated)`.
    fn open_board(
        &self,
        entry: &mut BoardEntry,
        path: &Path,
        args: &OpenArgs,
        topic: &str,
        known: bool,
    ) -> Result<(bool, bool), TrackerError> {
        if let Some(dir) = path.parent() {
            self.fs.remove_stale_temps(dir);
        }
        match self.fs.read(path) {
            Ok(bytes) => {
                if known {
                    self.ingest_bytes(entry, bytes.clone());
                } else {
                    let parsed = parse(&bytes)?;
                    self.adopt(entry, path, bytes.clone(), parsed);
                }
                if let Some(err) = banner_failure(&entry.banner) {
                    return Err(err);
                }
                // Adopting a hand-written board adds id markers to its task
                // lines and changes nothing else.
                self.write_ops(entry, path, &[], &Author::File)?;
                Ok((false, false))
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                let (bytes, recreated) = match &entry.last_ingested {
                    Some(good) if entry.parsed.is_some() => (good.clone(), true),
                    _ => {
                        let title = args.title.as_deref().unwrap_or(topic);
                        let sections: Vec<&str> =
                            args.sections.iter().map(String::as_str).collect();
                        (template(title, &sections).into_bytes(), false)
                    }
                };
                let parsed = parse(&bytes)?;
                if let Some(dir) = path.parent() {
                    self.fs.create_dir_all(dir).map_err(io_err)?;
                }
                self.fs.write_atomic(path, &bytes).map_err(io_err)?;
                self.adopt(entry, path, bytes.clone(), parsed);
                entry.own_bytes = Some(bytes);
                entry.banner = None;
                Ok((!recreated, recreated))
            }
            Err(e) => Err(io_err(e)),
        }
    }

    /// Makes `bytes` (parsed as `parsed`) the board's baseline without logging
    /// a change: a first adoption has nothing to diff against.
    fn adopt(&self, entry: &mut BoardEntry, path: &Path, bytes: Vec<u8>, parsed: ParsedBoard) {
        entry.parsed = Some(parsed);
        entry.last_ingested = Some(bytes.clone());
        entry.banner = None;
        entry.last_good_at = Some(self.clock.now());
        self.store_last_good(path, &bytes);
    }

    // ── write / ingest ───────────────────────────────────────────────────────

    /// The read-modify-write of one board (an empty `ops` only assigns id
    /// markers to human task lines).
    fn write_ops(
        &self,
        entry: &mut BoardEntry,
        path: &Path,
        ops: &[Op],
        author: &Author,
    ) -> Result<(), TrackerError> {
        // The board may have been moved or swapped for a symlink since it was
        // opened: the path is checked again before anything is written.
        self.recheck_path(entry, path)?;
        let mut attempts = 0;
        let (applied, now) = loop {
            let bytes = self.current_bytes(entry, path)?;
            let now = self.clock.now();
            let stamp = Stamp::new(now, self.offset_at(now));
            let applied = apply_to_file(&bytes, ops, author, stamp)?;
            if matches!(author, Author::Agent { .. }) {
                if let Some(old) = entry.parsed.as_ref().map(|p| &p.board) {
                    refuse_agent_ran_it(old, &applied.board)?;
                }
            }
            if applied.bytes == bytes {
                break (applied, now);
            }
            // The user may have saved while the ops were applied; replacing
            // the file now would lose that save. Look again: on a change, the
            // next pass ingests the edit and applies the ops on top of it.
            self.fs.before_commit(path);
            if self.fs.read(path).ok().as_deref() == Some(bytes.as_slice()) {
                self.fs.write_atomic(path, &applied.bytes).map_err(io_err)?;
                self.store_last_good(path, &applied.bytes);
                break (applied, now);
            }
            attempts += 1;
            if attempts >= 2 {
                return Err(TrackerError::Io(CONCURRENT_EDIT.to_string()));
            }
        };
        entry.own_bytes = Some(applied.bytes.clone());
        entry.last_ingested = Some(applied.bytes);
        entry.parsed = Some(applied.parsed);
        entry.banner = None;
        entry.last_good_at = Some(now);
        entry.log.append(applied.changes);
        Ok(())
    }

    /// The board's path still resolves to itself under the policy it was
    /// opened with: no symlink swapped in, nothing moved out of the root.
    fn recheck_path(&self, entry: &BoardEntry, path: &Path) -> Result<(), TrackerError> {
        match resolve_board_path(&entry.root, self.home.as_deref(), path) {
            Ok(resolved) if resolved == path => Ok(()),
            _ => Err(TrackerError::PathNotAllowed),
        }
    }

    /// The file's bytes now, with any external edit ingested first. Fails when
    /// the file is gone or doesn't parse (the banner is set either way).
    fn current_bytes(&self, entry: &mut BoardEntry, path: &Path) -> Result<Vec<u8>, TrackerError> {
        let bytes = match self.fs.read(path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.mark_missing(entry);
                return Err(TrackerError::BoardMissing);
            }
            Err(e) => return Err(io_err(e)),
        };
        self.ingest_bytes(entry, bytes.clone());
        match banner_failure(&entry.banner) {
            Some(err) => Err(err),
            None => Ok(bytes),
        }
    }

    /// Reads the file and ingests what it says. `true` if a client would see
    /// a difference.
    fn ingest_from_disk(&self, entry: &mut BoardEntry, path: &Path) -> bool {
        match self.fs.read(path) {
            Ok(bytes) => self.ingest_bytes(entry, bytes),
            Err(e) if e.kind() == io::ErrorKind::NotFound => self.mark_missing(entry),
            // A transient read failure says nothing about the board.
            Err(_) => false,
        }
    }

    fn mark_missing(&self, entry: &mut BoardEntry) -> bool {
        let banner = Banner::Missing {
            last_seen: entry.last_good_at,
        };
        replace_banner(entry, banner)
    }

    /// Ingests the file's bytes: nothing if they are ours, a banner if they
    /// don't parse, otherwise the field-level diff against the last ingested
    /// board attributed to `File`.
    fn ingest_bytes(&self, entry: &mut BoardEntry, bytes: Vec<u8>) -> bool {
        let ours = entry.own_bytes.as_deref() == Some(bytes.as_slice())
            || entry.last_ingested.as_deref() == Some(bytes.as_slice());
        if ours {
            // The file is the board we already hold; a banner (missing, or an
            // unreadable edit since reverted) no longer applies.
            return entry.banner.take().is_some();
        }
        match parse(&bytes) {
            Err(m) => {
                let banner = Banner::Unreadable {
                    line: m.line,
                    reason: m.reason.code().to_string(),
                    last_good_at: entry.last_good_at,
                };
                replace_banner(entry, banner)
            }
            Ok(parsed) => {
                let now = self.clock.now();
                if let Some(old) = &entry.parsed {
                    let changes = diff(&old.board, &parsed.board, &Author::File, now);
                    entry.log.append(changes);
                }
                entry.parsed = Some(parsed);
                entry.last_ingested = Some(bytes);
                entry.own_bytes = None;
                entry.banner = None;
                entry.last_good_at = Some(now);
                true
            }
        }
    }

    // ── persistence ──────────────────────────────────────────────────────────

    fn trackers_dir(&self) -> Option<PathBuf> {
        self.state_root.as_ref().map(|root| root.join("trackers"))
    }

    fn last_good_file(&self, path: &Path) -> Option<PathBuf> {
        let name = format!("{:016x}.md", fnv1a64(path.as_os_str().as_encoded_bytes()));
        Some(self.trackers_dir()?.join("last-good").join(name))
    }

    fn store_last_good(&self, path: &Path, bytes: &[u8]) {
        let Some(file) = self.last_good_file(path) else {
            return;
        };
        if let Err(e) = file
            .parent()
            .map_or(Ok(()), std::fs::create_dir_all)
            .and_then(|()| write_atomic(&file, bytes))
        {
            tracing::warn!("tracker: could not store last-good copy: {e}");
        }
    }

    fn persist(&self, inner: &Inner) {
        let Some(dir) = self.trackers_dir() else {
            return;
        };
        let state = PersistedState {
            version: 1,
            bindings: inner
                .bindings
                .iter()
                .map(|(tag, path)| (tag.clone(), key_of(path)))
                .collect(),
            boards: inner
                .boards
                .iter()
                .map(|(path, entry)| {
                    (
                        key_of(path),
                        PersistedBoard {
                            topic: entry.topic.clone(),
                            root: Some(key_of(&entry.root.dir)),
                            git: entry.root.git,
                            log: entry.log.clone(),
                            last_good_at: entry.last_good_at,
                            committable: entry.committable.clone(),
                        },
                    )
                })
                .collect(),
            cursors: inner.cursors.clone(),
            hidden: inner.hidden.iter().cloned().collect(),
        };
        let result = serde_json::to_vec(&state)
            .map_err(io::Error::other)
            .and_then(|bytes| {
                std::fs::create_dir_all(&dir)?;
                write_atomic(&dir.join("state.json"), &bytes)
            });
        if let Err(e) = result {
            tracing::warn!("tracker: could not persist state: {e}");
        }
    }

    /// Loads persisted state and re-reads every board.
    fn load(&self) {
        let Some(dir) = self.trackers_dir() else {
            return;
        };
        let Ok(bytes) = std::fs::read(dir.join("state.json")) else {
            return;
        };
        let state: PersistedState = match serde_json::from_slice(&bytes) {
            Ok(state) => state,
            Err(e) => {
                tracing::warn!("tracker: ignoring unreadable state.json: {e}");
                return;
            }
        };
        let mut inner = self.lock();
        for (key, persisted) in state.boards {
            let path = PathBuf::from(&key);
            let root = match persisted.root {
                Some(dir) => RepoRoot {
                    dir: PathBuf::from(dir),
                    git: persisted.git,
                },
                None => find_repo_root(path.parent().unwrap_or(&path)),
            };
            let mut entry = BoardEntry::new(&persisted.topic, root);
            entry.log = persisted.log;
            entry.last_good_at = persisted.last_good_at;
            entry.committable = persisted.committable;
            // The last-good copy is the baseline the file is diffed against.
            if let Some(good) = self
                .last_good_file(&path)
                .and_then(|f| std::fs::read(f).ok())
            {
                if let Ok(parsed) = parse(&good) {
                    entry.parsed = Some(parsed);
                    entry.last_ingested = Some(good);
                }
            }
            self.ingest_from_disk(&mut entry, &path);
            inner.boards.insert(path, entry);
        }
        for (tag, key) in state.bindings {
            let path = PathBuf::from(key);
            if inner.boards.contains_key(&path) {
                inner.bindings.insert(tag, path);
            }
        }
        inner.cursors = state.cursors;
        inner.hidden = state.hidden.into_iter().collect();
        let paths: Vec<PathBuf> = inner.boards.keys().cloned().collect();
        inner.dirty.extend(paths);
        self.persist(&inner);
    }

    // ── small helpers ────────────────────────────────────────────────────────

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The registry's key for `path`: itself, or its canonical form.
    fn board_key(&self, inner: &Inner, path: &Path) -> Option<PathBuf> {
        if inner.boards.contains_key(path) {
            return Some(path.to_path_buf());
        }
        let canonical = std::fs::canonicalize(path.parent()?)
            .ok()?
            .join(path.file_name()?);
        inner.boards.contains_key(&canonical).then_some(canonical)
    }

    fn offset_at(&self, now: DateTime<Utc>) -> FixedOffset {
        self.utc_offset
            .unwrap_or_else(|| *now.with_timezone(&chrono::Local).offset())
    }

    fn ensure_watch(&self, path: &Path) {
        let Some(dir) = path.parent() else {
            return;
        };
        let mut guard = self.watch.lock().unwrap_or_else(|e| e.into_inner());
        let Some(host) = guard.as_mut() else {
            return;
        };
        if tokio::runtime::Handle::try_current().is_err() || !host.dirs.insert(dir.to_path_buf()) {
            return;
        }
        spawn_dir_watcher(host.registry.clone(), host.tx.clone(), dir.to_path_buf());
    }
}

impl TrackerFrameProvider for TrackerRegistry {
    fn tracker_frames(&self) -> Vec<ServerMsg> {
        let mut tags: Vec<String> = self.lock().bindings.keys().cloned().collect();
        tags.sort();
        tags.iter()
            .flat_map(|tag| self.frames_for_tag(tag))
            .collect()
    }

    fn has_bound_board(&self, tag: &str) -> bool {
        TrackerRegistry::has_bound_board(self, tag)
    }
}

fn key_of(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn io_err(e: io::Error) -> TrackerError {
    TrackerError::Io(e.kind().to_string())
}

/// The `reason` of the `io_error` a write ends with when the file kept
/// changing under it; the agent may simply retry.
pub const CONCURRENT_EDIT: &str = "concurrent_edit";

/// The error a board under `banner` refuses writes with; `None` without one.
fn banner_failure(banner: &Option<Banner>) -> Option<TrackerError> {
    match banner {
        Some(Banner::Unreadable { line, reason, .. }) => Some(TrackerError::BoardUnreadable {
            line: *line,
            reason: reason.clone(),
        }),
        Some(Banner::Missing { .. }) => Some(TrackerError::BoardMissing),
        None => None,
    }
}

/// Sets `banner`; `true` if it differs from the current one.
fn replace_banner(entry: &mut BoardEntry, banner: Banner) -> bool {
    if entry.banner.as_ref() == Some(&banner) {
        return false;
    }
    entry.banner = Some(banner);
    true
}

/// Changes by the user (pane or file) after `cursor`, the session's own
/// excluded; 0 without a cursor.
fn user_changes_of(entry: &BoardEntry, cursor: Option<u64>, session: &str) -> u32 {
    if cursor.is_none() {
        return 0;
    }
    match entry.log.since(cursor, Some(session)) {
        Since::Changes(changes) => changes
            .iter()
            .filter(|c| matches!(c.by, Author::Pane | Author::File))
            .count() as u32,
        Since::TooOld { count } => count.min(u64::from(u32::MAX)) as u32,
        Since::Full => 0,
    }
}

/// "Ran it" is the user's, and it is about one command text: an agent op that
/// leaves a command item `done` is refused unless the item was already done
/// with that same command. (To change a command the user ran, an agent first
/// reopens the item.)
fn refuse_agent_ran_it(old: &Board, new: &Board) -> Result<(), TrackerError> {
    for item in new
        .items
        .iter()
        .filter(|i| i.kind == Kind::Command && i.status == Status::Done)
    {
        let unchanged = old.item(&item.id).is_some_and(|o| {
            o.kind == Kind::Command && o.status == Status::Done && o.command == item.command
        });
        if !unchanged {
            return Err(TrackerError::NotPermitted {
                id: item.id.clone(),
            });
        }
    }
    Ok(())
}

/// A topic for a board at an explicit path: its directory's name when that is
/// a valid topic (the `index.md` layout), else the file stem slugged.
fn topic_from_path(path: &Path) -> Option<String> {
    let dir_name = path.parent()?.file_name()?.to_str()?;
    if is_valid_topic(dir_name) {
        return Some(dir_name.to_string());
    }
    let stem = slug(path.file_stem()?.to_str()?);
    let stem: String = stem.chars().take(48).collect();
    is_valid_topic(&stem).then_some(stem)
}
