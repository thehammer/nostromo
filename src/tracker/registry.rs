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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{DateTime, FixedOffset, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use thiserror::Error;
use tokio::sync::broadcast;

use super::bindings::{with_source_line, Binding, Desired, FILE_WRITE_INTERVAL};
use super::changelog::{ChangeLog, Cursors, Since};
use super::clock::{Clock, SystemClock};
use super::diff::diff;
use super::format::{parse, template, Malformed, ParsedBoard};
use super::model::{fnv1a64, slug, Author, Board, Counts, Kind, Link, Stamp, Status};
use super::ops::{apply_to_file, LinkInput, Op, OpError, Upsert, WriteError};
use super::paths::{
    default_path, find_repo_root, is_valid_topic, probe_committable, resolve_board_path, RepoRoot,
};
use super::render::{compact_full, delta_entries};
use super::view::{self, Banner, BoundView, Committable, TrackerBoardView, ViewFacts};
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
    /// Items bound to a live source, by item id (T6).
    live: HashMap<String, LiveItem>,
}

/// One bound item's live state. The board in memory shows what the source
/// says at once; the file line follows at most once per
/// [`FILE_WRITE_INTERVAL`], and only when the displayed status changed.
struct LiveItem {
    binding: Binding,
    /// When the item became live: the staleness clock before the source's
    /// first report.
    since: DateTime<Utc>,
    /// When the source last reported on this item.
    as_of: Option<DateTime<Utc>>,
    /// The last source state applied.
    state: Option<String>,
    /// The status the file line has.
    file_status: Status,
    /// What the source shows that the file may not yet; reapplied on top of
    /// every re-read of the file.
    overlay: Option<Overlay>,
    last_write: Option<DateTime<Utc>>,
    /// The last published staleness.
    badly_stale: bool,
}

#[derive(Clone)]
struct Overlay {
    /// The status the source set at its last state change; `None` leaves the
    /// file's status.
    status: Option<Status>,
    note_line: String,
    link: Option<Link>,
}

/// A bound item on some board, for the feeds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LiveRef {
    pub path: PathBuf,
    pub item_id: String,
    pub binding: Binding,
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
            live: HashMap::new(),
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
    /// Seconds of source silence after which a live item is badly stale.
    badly_stale_secs: AtomicU64,
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
            badly_stale_secs: AtomicU64::new(super::bindings::badly_stale_after().as_secs()),
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
                bound: self.bound_views(entry),
            },
        ))
    }

    /// Link `index` of item `item_id` of the board bound to `tag`, with the
    /// item's live binding (it names the repo of a bare `PR #n`). The daemon's
    /// own copy: a client never says what a link is.
    pub fn link_of(
        &self,
        tag: &str,
        item_id: &str,
        index: usize,
    ) -> Option<(Link, Option<Binding>)> {
        let inner = self.lock();
        let entry = inner.boards.get(inner.bindings.get(tag)?)?;
        let item = entry
            .parsed
            .as_ref()?
            .board
            .items
            .iter()
            .find(|i| i.id == item_id)?;
        let binding = entry.live.get(item_id).map(|live| live.binding.clone());
        Some((item.links.get(index)?.clone(), binding))
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
        self.sync_live(entry);
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
        self.write_ops_logged(entry, path, ops, author, true)
    }

    /// [`Self::write_ops`]; `log: false` writes without appending the
    /// changes (a live item's state change was logged when it happened, and
    /// the file only catches up).
    fn write_ops_logged(
        &self,
        entry: &mut BoardEntry,
        path: &Path,
        ops: &[Op],
        author: &Author,
        log: bool,
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
        if log {
            entry.log.append(applied.changes);
        }
        self.sync_live(entry);
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
            Ok(mut parsed) => {
                let now = self.clock.now();
                // What the live sources show on top of the file is not an
                // edit: put it on the new board before diffing.
                sync_live_items(&mut entry.live, &mut parsed, now);
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
            self.sync_live(&mut entry);
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

    // ── live items (T6) ──────────────────────────────────────────────────────

    /// How long a source may be silent before its items are badly stale.
    pub fn set_badly_stale_after(&self, after: std::time::Duration) {
        self.badly_stale_secs
            .store(after.as_secs(), Ordering::Relaxed);
    }

    /// Every item bound to a live source, on every board.
    pub fn live_bindings(&self) -> Vec<LiveRef> {
        let inner = self.lock();
        let mut out: Vec<LiveRef> = inner
            .boards
            .iter()
            .flat_map(|(path, entry)| {
                entry.live.iter().map(|(id, live)| LiveRef {
                    path: path.clone(),
                    item_id: id.clone(),
                    binding: live.binding.clone(),
                })
            })
            .collect();
        out.sort_by(|a, b| (&a.path, &a.item_id).cmp(&(&b.path, &b.item_id)));
        out
    }

    /// A source reports `desired` for the item `item_id` of the board at
    /// `path`, as of `observed_at`.
    ///
    /// The in-memory board takes the new values at once; the pane is told.
    /// A change of the source *state* is logged as a change attributed
    /// `source <name>`, so it reaches the agent's next delta, and is the only
    /// thing that sets the item's status (an agent's own status on a bound
    /// item stands until the next state change). A different note under the
    /// same state (a count) updates the view and nothing else. The file
    /// follows through [`Self::tick_live`]'s throttle. `true` when the view
    /// changed.
    pub fn apply_source(
        &self,
        path: &Path,
        item_id: &str,
        desired: &Desired,
        observed_at: DateTime<Utc>,
    ) -> bool {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let Some(entry) = inner.boards.get_mut(path) else {
            return false;
        };
        let now = self.clock.now();
        let after = self.badly_stale_after();
        let changed = apply_to_live_item(entry, item_id, desired, observed_at, now, after);
        if changed.logged {
            self.persist(inner);
        }
        if changed.view {
            inner.dirty.insert(path.to_path_buf());
        }
        // The first change of a quiet item reaches the file at once.
        let wrote = match inner.boards.get_mut(path) {
            Some(entry) => self.write_due_live_items(entry, path, now),
            None => false,
        };
        if wrote {
            inner.dirty.insert(path.to_path_buf());
        }
        changed.view || wrote
    }

    /// The periodic pass over live items: writes the file lines the throttle
    /// held back (each item at most once per [`FILE_WRITE_INTERVAL`]) and
    /// re-checks staleness. `true` when a view changed; call [`Self::flush`].
    pub fn tick_live(&self) -> bool {
        let mut guard = self.lock();
        let inner = &mut *guard;
        let now = self.clock.now();
        let after = self.badly_stale_after();
        let mut dirty = Vec::new();
        for (path, entry) in inner.boards.iter_mut() {
            let mut changed = false;
            for live in entry.live.values_mut() {
                changed |= refresh_staleness(live, now, after);
            }
            changed |= self.write_due_live_items(entry, path, now);
            if changed {
                dirty.push(path.clone());
            }
        }
        let any = !dirty.is_empty();
        inner.dirty.extend(dirty);
        any
    }

    fn badly_stale_after(&self) -> chrono::Duration {
        chrono::Duration::seconds(self.badly_stale_secs.load(Ordering::Relaxed) as i64)
    }

    /// Writes, for every live item of `entry` whose displayed status differs
    /// from the file's and whose last file write is at least
    /// [`FILE_WRITE_INTERVAL`] ago, that item's line. `true` if a file was
    /// written. A failed write waits out the interval before trying again.
    fn write_due_live_items(
        &self,
        entry: &mut BoardEntry,
        path: &Path,
        now: DateTime<Utc>,
    ) -> bool {
        let interval = chrono::Duration::from_std(FILE_WRITE_INTERVAL).unwrap_or_default();
        let due: Vec<String> = entry
            .live
            .iter()
            .filter(|(_, live)| {
                live.overlay
                    .as_ref()
                    .and_then(|o| o.status)
                    .is_some_and(|status| status != live.file_status)
                    && live.last_write.is_none_or(|at| now - at >= interval)
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut wrote = false;
        for id in due {
            let Some(item) = entry
                .parsed
                .as_ref()
                .and_then(|p| p.board.items.iter().find(|i| i.id == id))
            else {
                continue;
            };
            let author = Author::Source {
                name: entry.live[&id].binding.source_name().to_string(),
            };
            let op = Op::Upsert(Upsert {
                id: Some(id.clone()),
                status: Some(item.status.wire().to_string()),
                note: Some(item.note.clone().unwrap_or_default()),
                links: Some(
                    item.links
                        .iter()
                        .map(|l| LinkInput::Full {
                            text: l.text.clone(),
                            url: l.url.clone(),
                        })
                        .collect(),
                ),
                ..Upsert::default()
            });
            let result = self.write_ops_logged(entry, path, &[op], &author, false);
            if let Some(live) = entry.live.get_mut(&id) {
                live.last_write = Some(now);
            }
            match result {
                Ok(()) => wrote = true,
                Err(e) => tracing::warn!("tracker: live item {id} not written: {e}"),
            }
        }
        wrote
    }

    /// Brings `entry.live` in line with its board's `bind` markers and puts
    /// the sources' overlays on top of the file's values.
    fn sync_live(&self, entry: &mut BoardEntry) {
        let now = self.clock.now();
        if let Some(parsed) = entry.parsed.as_mut() {
            sync_live_items(&mut entry.live, parsed, now);
        }
    }

    fn bound_views(&self, entry: &BoardEntry) -> HashMap<String, BoundView> {
        let now = self.clock.now();
        let after = self.badly_stale_after();
        entry
            .live
            .iter()
            .map(|(id, live)| {
                (
                    id.clone(),
                    BoundView {
                        source: live.binding.source_name().to_string(),
                        as_of: live.as_of,
                        badly_stale: is_badly_stale(live, now, after),
                    },
                )
            })
            .collect()
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

/// What an application of a source report changed.
struct LiveChange {
    /// What the pane shows differs.
    view: bool,
    /// A change was appended to the board's log.
    logged: bool,
}

fn is_badly_stale(live: &LiveItem, now: DateTime<Utc>, after: chrono::Duration) -> bool {
    now - live.as_of.unwrap_or(live.since) > after
}

/// Re-evaluates staleness; `true` when it flipped.
fn refresh_staleness(live: &mut LiveItem, now: DateTime<Utc>, after: chrono::Duration) -> bool {
    let stale = is_badly_stale(live, now, after);
    std::mem::replace(&mut live.badly_stale, stale) != stale
}

/// Applies one source report to the in-memory board (see
/// [`TrackerRegistry::apply_source`]).
fn apply_to_live_item(
    entry: &mut BoardEntry,
    item_id: &str,
    desired: &Desired,
    observed_at: DateTime<Utc>,
    now: DateTime<Utc>,
    after: chrono::Duration,
) -> LiveChange {
    let mut out = LiveChange {
        view: false,
        logged: false,
    };
    let (Some(parsed), Some(live)) = (entry.parsed.as_mut(), entry.live.get_mut(item_id)) else {
        return out;
    };
    let Some(pos) = parsed.board.items.iter().position(|i| i.id == item_id) else {
        return out;
    };
    if live.as_of.is_none_or(|at| observed_at > at) {
        live.as_of = Some(observed_at);
    }
    out.view |= refresh_staleness(live, now, after);

    let state_changed = live.state.as_deref() != Some(desired.state.as_str());
    let item = &parsed.board.items[pos];
    let new_status = match (state_changed, desired.status) {
        (true, Some(status)) => status,
        _ => item.status,
    };
    let new_note = with_source_line(
        item.note.as_deref(),
        live.binding.note_prefix(),
        &desired.note_line,
    );
    let mut new_links = item.links.clone();
    if let Some(link) = desired.link.as_ref().filter(|_| state_changed) {
        if !new_links.contains(link) {
            new_links.push(link.clone());
        }
    }
    let differs = new_status != item.status
        || item.note.as_deref() != Some(new_note.as_str())
        || new_links != item.links;
    if !differs {
        live.state = Some(desired.state.clone());
        return out;
    }

    // With no status pending for the file, the board's status is the file's.
    if live.overlay.as_ref().is_none_or(|o| o.status.is_none()) {
        live.file_status = item.status;
    }
    let before = state_changed.then(|| parsed.board.clone());
    let previous = live.overlay.take();
    live.overlay = Some(Overlay {
        status: if state_changed {
            desired.status
        } else {
            previous.as_ref().and_then(|o| o.status)
        },
        note_line: desired.note_line.clone(),
        link: if state_changed {
            desired.link.clone()
        } else {
            previous.and_then(|o| o.link)
        },
    });
    let item = &mut parsed.board.items[pos];
    item.status = new_status;
    item.note = Some(new_note);
    item.links = new_links;
    live.state = Some(desired.state.clone());
    out.view = true;
    if let Some(before) = before {
        parsed.board.items[pos].updated_at = Some(now);
        let author = Author::Source {
            name: live.binding.source_name().to_string(),
        };
        let changes = diff(&before, &parsed.board, &author, now);
        out.logged = !changes.is_empty();
        entry.log.append(changes);
    }
    out
}

/// Makes `live` follow the `bind` markers of `parsed` and lays each live
/// item's overlay over the file's values. A status the file has since
/// changed (the user or an agent wrote it) ends the overlay: the writer wins
/// until the source's next state change.
fn sync_live_items(
    live: &mut HashMap<String, LiveItem>,
    parsed: &mut ParsedBoard,
    now: DateTime<Utc>,
) {
    let mut seen: HashSet<String> = HashSet::new();
    for item in parsed.board.items.iter_mut() {
        let Some(binding) = item.bind.as_deref().and_then(|k| Binding::parse(k).ok()) else {
            continue;
        };
        seen.insert(item.id.clone());
        let slot = live
            .entry(item.id.clone())
            .or_insert_with(|| LiveItem::new(binding.clone(), item.status, now));
        if slot.binding != binding {
            *slot = LiveItem::new(binding, item.status, now);
        }
        match slot.overlay.clone() {
            Some(ov)
                if ov.status.is_none()
                    || ov.status.is_some() && item.status == slot.file_status =>
            {
                if let Some(status) = ov.status {
                    item.status = status;
                } else {
                    slot.file_status = item.status;
                }
                item.note = Some(with_source_line(
                    item.note.as_deref(),
                    slot.binding.note_prefix(),
                    &ov.note_line,
                ));
                if let Some(link) = ov.link {
                    if !item.links.contains(&link) {
                        item.links.push(link);
                    }
                }
            }
            _ => {
                slot.overlay = None;
                slot.file_status = item.status;
            }
        }
    }
    live.retain(|id, _| seen.contains(id));
}

impl LiveItem {
    fn new(binding: Binding, status: Status, now: DateTime<Utc>) -> LiveItem {
        LiveItem {
            binding,
            since: now,
            as_of: None,
            state: None,
            file_status: status,
            overlay: None,
            last_write: None,
            badly_stale: false,
        }
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
