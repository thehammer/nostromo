//! Repo docs work source: every open bug, feature, idea, todo and wip folder
//! filed with `doc-mgr` under `<code root>/<repo>/.claude/` (code root defaults to `~/Code`).
//!
//! Layout read (the doc-mgr layout; legacy `bug-reports/`, `feature-requests/`
//! and `TODO.md` are out of scope):
//!
//! ```text
//! bugs/open/*.md       -> bug        ideas/*.md        -> idea
//! features/backlog/*.md -> feature   todos/open/*.md   -> todo
//! wip/<topic>/         -> wip (index.md is the body; the folder is the item)
//! ```
//!
//! Two layers:
//! - [`Scanner`]: pure scan + parse with a per-file cache keyed by (mtime,
//!   size), so a rescan stats every file but only re-reads what changed.
//! - the watcher thread behind [`spawn`] / [`spawn_at`]: FSEvents (via
//!   `notify`) on each repo's `.claude/` and, non-recursively, on the root;
//!   events are debounced per repo and rescan only that repo. A 5-minute
//!   safety rescan (stat only) and a manual refresh rescan everything. There
//!   is no polling besides that.
//!
//! Git worktrees (a child whose `.git` is a file) are skipped: they carry a
//! copy of the repo's tracked docs and would list every doc twice.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{self, ErrorKind, Read};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, NaiveDate, Utc};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::{watch, Notify};
use tracing::warn;

use super::hub::SourceUpdate;
use super::model::{
    GroupError, Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem,
    WorkSource,
};
use super::untrusted::{one_line, MAX_LINE_CHARS};

/// A burst of events in one repo is rescanned once, this long after the last.
const DEBOUNCE: Duration = Duration::from_millis(500);
/// ...but never later than this after the first event of the burst.
const MAX_DEBOUNCE: Duration = Duration::from_secs(2);
/// Everything is re-checked (stat only) this often, catching what events missed.
const SAFETY_RESCAN: Duration = Duration::from_secs(5 * 60);
/// The watcher thread wakes at least this often to notice that nobody listens.
const IDLE_WAKE: Duration = Duration::from_secs(30);
/// A new directory in the root may get its `.claude/` a moment later (a clone
/// in progress): look again after these delays.
const NEW_REPO_RECHECKS: [Duration; 4] = [
    Duration::from_secs(2),
    Duration::from_secs(5),
    Duration::from_secs(15),
    Duration::from_secs(60),
];

/// `search_text` cap per item (design contract §3).
const SEARCH_TEXT_CAP: usize = 64 * 1024;
/// A doc is never read past this many bytes.
const MAX_READ: u64 = 4 * 1024 * 1024;
/// The detail pane shows at most this much of a doc.
const MAX_DETAIL: u64 = 1024 * 1024;
/// Severity and priority labels are cut to this many characters.
const MAX_LABEL_CHARS: usize = 120;
/// A wip folder's file list is cut to this many entries.
const MAX_WIP_FILES: usize = 500;

/// Shown (with the list) while the file watcher cannot keep it live.
const LIVE_UPDATES_UNAVAILABLE: &str = "Live updates unavailable, rescanning every 5 min";

/// Metric on an item whose search text holds only the start of its doc.
const TRUNCATED_METRIC: &str = "truncated";

/// Rank for a priority that is not `P1`..`P5`.
const OTHER_PRIORITY_RANK: u8 = 9;

/// `(directory under .claude, item kind)` for the single-file doc types.
const DOC_DIRS: [(&str, &str); 4] = [
    ("bugs/open", "bug"),
    ("features/backlog", "feature"),
    ("ideas", "idea"),
    ("todos/open", "todo"),
];
const WIP_DIR: &str = "wip";

/// First path component (under `.claude`) of everything that can change an item.
const WATCHED_TOPS: [&str; 5] = ["bugs", "features", "ideas", "todos", "wip"];

/// The directory whose children are the repos: `$NOSTROMO_CODE_ROOT`, else
/// `code_root` from `config.toml`, else `~/Code`.
pub fn code_root() -> PathBuf {
    crate::config::Config::load(None)
        .unwrap_or_default()
        .code_root_dir()
}

/// Start the source on [`code_root`]. `refresh` is poked by a manual refresh
/// that passed the hub's 15 s debounce; the source then rescans everything.
pub fn spawn(refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    spawn_at(code_root(), refresh)
}

/// Start the source on `root`. Needs a tokio runtime (it bridges `refresh`).
/// The first value is a `loading` status; the scan result follows. The watcher
/// thread ends once the returned receiver (and its clones) are dropped.
pub fn spawn_at(root: PathBuf, refresh: Arc<Notify>) -> watch::Receiver<SourceUpdate> {
    spawn_with_fs(root, refresh, Arc::new(RealFs))
}

/// [`spawn_at`] reading through `io` (tests make reads fail on purpose).
pub fn spawn_with_fs(
    root: PathBuf,
    refresh: Arc<Notify>,
    io: Arc<dyn DocFs>,
) -> watch::Receiver<SourceUpdate> {
    let (tx, rx) = watch::channel((
        status(SourceState::Loading, None, 0, Vec::new(), false),
        Vec::new(),
    ));
    let tx = Arc::new(tx);
    let (msg_tx, msg_rx) = mpsc::channel();

    let bridge_tx = msg_tx.clone();
    let bridge_watch = Arc::clone(&tx);
    tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = refresh.notified() => {
                    if bridge_tx.send(Msg::Refresh).is_err() { break; }
                }
                _ = bridge_watch.closed() => break,
            }
        }
    });

    let thread_tx = Arc::clone(&tx);
    let spawned = std::thread::Builder::new()
        .name("repo-docs".into())
        .spawn(move || {
            let outcome = catch_unwind(AssertUnwindSafe(|| {
                run(Scanner::with_fs(root, io), &thread_tx, msg_tx, &msg_rx)
            }));
            if outcome.is_err() {
                warn!("repo docs: the watcher thread panicked");
                thread_tx.send_replace(error_update(
                    "The repo docs scanner crashed; restart Nostromo to read them again",
                ));
            }
        });
    if let Err(e) = spawned {
        warn!(error = %e, "could not start the repo docs watcher thread");
        tx.send_replace(error_update(&format!(
            "Couldn't start the repo docs scanner: {e}"
        )));
    }
    rx
}

/// The update for a source that cannot run at all: an error and no items.
fn error_update(reason: &str) -> SourceUpdate {
    (
        status(
            SourceState::Error,
            Some(reason.to_string()),
            0,
            Vec::new(),
            false,
        ),
        Vec::new(),
    )
}

/// Detail for a `doc:<repo>:<path>` item id under [`code_root`].
pub async fn detail(item_id: &str) -> Result<WorkDetail, WorkError> {
    detail_at(&code_root(), item_id).await
}

/// Detail for `item_id` under `root`: the file read fresh, markdown as written.
pub async fn detail_at(root: &Path, item_id: &str) -> Result<WorkDetail, WorkError> {
    let (root, item_id) = (root.to_path_buf(), item_id.to_string());
    tokio::task::spawn_blocking(move || detail_blocking(&root, &item_id))
        .await
        .unwrap_or_else(|_| Err(WorkError::new("internal", "reading the doc failed")))
}

// ── scanner ───────────────────────────────────────────────────────────────────

/// The reads a scan can lose a file to. Real I/O everywhere; tests swap in one
/// that fails on chosen paths so the failure paths do not depend on file modes
/// (which a root user ignores).
pub trait DocFs: Send + Sync {
    fn metadata(&self, path: &Path) -> io::Result<fs::Metadata> {
        fs::metadata(path)
    }
    fn symlink_metadata(&self, path: &Path) -> io::Result<fs::Metadata> {
        fs::symlink_metadata(path)
    }
    /// At most `limit` bytes of `path`, lossily decoded.
    fn read_text(&self, path: &Path, limit: u64) -> io::Result<String> {
        let mut bytes = Vec::new();
        fs::File::open(path)?.take(limit).read_to_end(&mut bytes)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }
}

/// The plain file system.
pub struct RealFs;

impl DocFs for RealFs {}

/// Scans the doc-mgr layout under one root and remembers what it parsed.
pub struct Scanner {
    root: PathBuf,
    io: Arc<dyn DocFs>,
    repos: BTreeMap<String, RepoState>,
    /// Plain directories in the root that have no `.claude/` (yet): watched so
    /// that one created later is noticed.
    idle_dirs: BTreeSet<String>,
    root_issue: Option<RootIssue>,
    /// Entries of the code root whose names are not UTF-8: they cannot be repos.
    root_skipped: usize,
    /// Set while the file watcher cannot keep the list live.
    live_updates_unavailable: bool,
}

#[derive(PartialEq, Eq)]
enum RootIssue {
    Missing,
    Unreadable(String),
}

struct RepoState {
    /// `<root>/<repo>`, as reached through the root.
    repo_dir: PathBuf,
    /// The repo directory with symlinks resolved: what FSEvents reports.
    repo_real: PathBuf,
    /// `<root>/<repo>/.claude`, as reached through the root.
    claude_dir: PathBuf,
    /// The same directory with symlinks resolved: what FSEvents reports.
    claude_real: PathBuf,
    /// Whether `.claude` is a readable directory inside the repo: only then is it watched.
    watch_claude: bool,
    items: Vec<WorkItem>,
    /// Why this repo's docs could not (all) be read; the readable ones still show.
    error: Option<String>,
    cache: HashMap<PathBuf, CachedItem>,
}

impl RepoState {
    fn new(repo_dir: PathBuf) -> Self {
        let claude_dir = repo_dir.join(".claude");
        Self {
            repo_real: repo_dir.clone(),
            claude_real: claude_dir.clone(),
            repo_dir,
            claude_dir,
            watch_claude: false,
            items: Vec::new(),
            error: None,
            cache: HashMap::new(),
        }
    }

    /// Take one read result, counting what could not be read.
    fn absorb(&mut self, path: PathBuf, read: Outcome, tally: &mut Tally) {
        match read {
            Outcome::Gone => {}
            Outcome::Unreadable => tally.skipped += 1,
            Outcome::Partial(item) => {
                tally.skipped += 1;
                self.items.push(item); // not cached: the next scan tries again
            }
            Outcome::Item(stamp, item) => {
                self.items.push(item.clone());
                self.cache.insert(path, CachedItem { stamp, item });
            }
        }
    }
}

/// What reading one doc came to.
enum Outcome {
    /// Not there any more (or not a doc): nothing to report.
    Gone,
    /// There, but it could not be read: counted and reported.
    Unreadable,
    Item(Stamp, WorkItem),
    /// Listed without its body, which could not be read.
    Partial(WorkItem),
}

/// What one repo's scan could not read.
#[derive(Default)]
struct Tally {
    first_folder_error: Option<String>,
    skipped: usize,
}

impl Tally {
    fn folder_error(&mut self, reason: String) {
        self.first_folder_error.get_or_insert(reason);
    }

    fn into_error(self) -> Option<String> {
        let skipped = (self.skipped > 0).then(|| {
            format!(
                "skipped {} unreadable file{}",
                self.skipped,
                if self.skipped == 1 { "" } else { "s" }
            )
        });
        match (self.first_folder_error, skipped) {
            (Some(folder), Some(skipped)) => Some(format!("{folder}; {skipped}")),
            (folder, skipped) => folder.or(skipped),
        }
    }
}

#[derive(Clone)]
struct CachedItem {
    stamp: Stamp,
    item: WorkItem,
}

/// What must be unchanged for a cached parse to be reused.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Stamp {
    mtime: Option<SystemTime>,
    size: u64,
    /// A wip folder also changes when files come and go.
    dir_mtime: Option<SystemTime>,
}

impl Scanner {
    pub fn new(root: PathBuf) -> Self {
        Self::with_fs(root, Arc::new(RealFs))
    }

    pub fn with_fs(root: PathBuf, io: Arc<dyn DocFs>) -> Self {
        let root = fs::canonicalize(&root).unwrap_or(root);
        Self {
            root,
            io,
            repos: BTreeMap::new(),
            idle_dirs: BTreeSet::new(),
            root_issue: None,
            root_skipped: 0,
            live_updates_unavailable: false,
        }
    }

    /// Scan every repo under the root (new repos appear, gone ones vanish).
    pub fn scan_all(&mut self) -> SourceUpdate {
        self.rescan_all();
        self.update()
    }

    /// Re-evaluate one repo (gone, new or changed) and return the whole update.
    pub fn rescan_repo(&mut self, repo: &str) -> SourceUpdate {
        self.refresh_repo(repo);
        self.update()
    }

    /// [`Scanner::scan_all`] without building the update; true when anything changed.
    fn rescan_all(&mut self) -> bool {
        let mut changed = false;
        match fs::read_dir(&self.root) {
            Ok(entries) => {
                changed |= self.root_issue.take().is_some();
                let mut names: Vec<String> = Vec::new();
                let mut skipped = 0;
                for entry in entries {
                    let Ok(entry) = entry else {
                        skipped += 1; // an entry the read itself failed on
                        continue;
                    };
                    match entry.file_name().into_string() {
                        Ok(name) => names.push(name),
                        // A folder whose name is not UTF-8 cannot be a usable repo name; a plain file is no repo anyway.
                        Err(_) if entry.path().is_dir() => skipped += 1,
                        Err(_) => {}
                    }
                }
                changed |= std::mem::replace(&mut self.root_skipped, skipped) != skipped;
                names.sort();
                let mut old = std::mem::take(&mut self.repos);
                for name in names {
                    let previous = old.remove(&name);
                    let state = self.scan_repo(&name, previous.as_ref());
                    changed |= !same_repo(previous.as_ref(), state.as_ref());
                    self.track_idle(&name, state.is_none());
                    if let Some(state) = state {
                        self.repos.insert(name, state);
                    }
                }
                changed |= !old.is_empty();
                self.idle_dirs
                    .retain(|name| self.repos.contains_key(name) || self.root.join(name).is_dir());
            }
            Err(e) => {
                let issue = if e.kind() == ErrorKind::NotFound {
                    // Nothing to show: the folder is gone.
                    changed |= !self.repos.is_empty();
                    self.repos.clear();
                    RootIssue::Missing
                } else {
                    // Keep what we had: the next scan may succeed.
                    RootIssue::Unreadable(describe(&e))
                };
                // A skip count from an earlier read says nothing about a root we cannot read now.
                changed |= std::mem::take(&mut self.root_skipped) != 0;
                changed |= self.root_issue.as_ref() != Some(&issue);
                self.root_issue = Some(issue);
            }
        }
        changed
    }

    /// [`Scanner::rescan_repo`] without building the update; true when the repo changed.
    fn refresh_repo(&mut self, repo: &str) -> bool {
        let previous = self.repos.remove(repo);
        let state = self.scan_repo(repo, previous.as_ref());
        let changed = !same_repo(previous.as_ref(), state.as_ref());
        self.track_idle(repo, state.is_none());
        if let Some(state) = state {
            self.repos.insert(repo.to_string(), state);
        }
        changed
    }

    /// Remember `name` as a doc-less directory (or forget it).
    fn track_idle(&mut self, name: &str, not_a_repo: bool) {
        if not_a_repo && !name.starts_with('.') && self.root.join(name).is_dir() {
            self.idle_dirs.insert(name.to_string());
        } else {
            self.idle_dirs.remove(name);
        }
    }

    /// Whether `name` is currently a repo with docs to read.
    fn has_repo(&self, name: &str) -> bool {
        self.repos.contains_key(name)
    }

    /// What the watcher must watch: each repo directory and each doc-less
    /// directory (non-recursive, so a `.claude/` created later is noticed) and, when it is a readable
    /// directory inside the repo, `.claude/` (recursive). Never anything outside the repo.
    fn watch_targets(&self) -> Vec<WatchTarget> {
        let mut targets = Vec::new();
        for state in self.repos.values() {
            targets.push(WatchTarget {
                dir: state.repo_dir.clone(),
                recursive: false,
            });
            if state.watch_claude {
                targets.push(WatchTarget {
                    dir: state.claude_dir.clone(),
                    recursive: true,
                });
            }
        }
        targets.extend(self.idle_dirs.iter().map(|name| WatchTarget {
            dir: self.root.join(name),
            recursive: false,
        }));
        targets
    }

    /// Record whether the watcher keeps the list live; true when that changed.
    fn set_live_updates(&mut self, live: bool) -> bool {
        let unavailable = !live;
        let changed = self.live_updates_unavailable != unavailable;
        self.live_updates_unavailable = unavailable;
        changed
    }

    /// The repo owning an event path (the path may use resolved symlinks).
    fn repo_for_event(&self, path: &Path) -> Option<String> {
        if let Ok(rel) = path.strip_prefix(&self.root) {
            return Self::repo_in_event_path(rel, None);
        }
        // A symlinked repo reports its target's path.
        self.repos.iter().find_map(|(name, r)| {
            if let Ok(rel) = path.strip_prefix(&r.repo_real) {
                return Self::repo_in_event_path(rel, Some(name));
            }
            None
        })
    }

    /// `rel` is relative to the code root (`name` unknown) or to a repo (`name` given).
    fn repo_in_event_path(rel: &Path, name: Option<&String>) -> Option<String> {
        let mut parts = rel.components();
        let name = match name {
            Some(name) => name.clone(),
            None => parts.next()?.as_os_str().to_str()?.to_string(),
        };
        match parts.next() {
            None => Some(name), // the repo directory itself (or a root child) appeared or went away
            Some(c) if c.as_os_str() == ".claude" => match parts.next() {
                None => Some(name),
                Some(top) if is_watched_top(top.as_os_str()) => Some(name),
                Some(_) => None,
            },
            Some(_) => None,
        }
    }

    /// Read one repo's docs, reusing `previous`'s parse of unchanged files.
    /// `None`: not a repo (or no longer one).
    fn scan_repo(&self, name: &str, previous: Option<&RepoState>) -> Option<RepoState> {
        if name.starts_with('.') {
            return None;
        }
        let dir = self.root.join(name);
        let mut state = RepoState::new(dir.clone());
        match self.io.metadata(&dir) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => return None,
            Err(e) if e.kind() == ErrorKind::NotFound => return None, // not a repo, or a dangling link
            Err(e) => {
                return Some(failed(
                    state,
                    previous,
                    format!("Can't open the repo folder: {}", describe(&e)),
                ))
            }
        }
        // A git worktree's `.git` is a file: its docs duplicate the main repo's.
        if self
            .io
            .symlink_metadata(&dir.join(".git"))
            .is_ok_and(|m| m.is_file())
        {
            return None;
        }
        match self.io.symlink_metadata(&state.claude_dir) {
            Ok(_) => {}
            Err(e) if e.kind() == ErrorKind::NotFound => return None, // no `.claude`: not a repo with docs
            Err(e) => {
                return Some(failed(
                    state,
                    previous,
                    format!("Can't search the repo folder: {}", describe(&e)),
                ))
            }
        }
        state.repo_real = match fs::canonicalize(&dir) {
            Ok(real) => real,
            Err(e) => {
                return Some(failed(
                    state,
                    previous,
                    format!("Can't resolve the repo folder: {}", describe(&e)),
                ))
            }
        };
        if let Ok(real) = fs::canonicalize(&state.claude_dir) {
            // A cloned repo must not be able to point `.claude` at the rest of the disk.
            if real == state.repo_real || !real.starts_with(&state.repo_real) {
                state.items.clear();
                state.error =
                    Some("Skipped: .claude is a symlink that leaves the repo".to_string());
                return Some(state);
            }
            state.claude_real = real;
        }

        match self.io.metadata(&state.claude_dir) {
            Ok(m) if !m.is_dir() => return None,
            Ok(_) => {}
            Err(e) => return Some(failed(state, previous, claude_problem(&e))),
        }
        if let Err(e) = fs::read_dir(&state.claude_dir) {
            return Some(failed(state, previous, claude_problem(&e)));
        }
        state.watch_claude = true;

        let no_cache = HashMap::new();
        let old_cache = previous.map_or(&no_cache, |p| &p.cache);
        // One unreadable folder or file flags the repo but the readable ones still show.
        state.error = self.read_docs(name, old_cache, &mut state);
        state.items.sort_by(|a, b| a.id.cmp(&b.id));
        Some(state)
    }

    /// Read every doc folder of `state`'s `.claude/` into `state`; returns why
    /// anything was left out, if it was.
    fn read_docs(
        &self,
        repo: &str,
        old_cache: &HashMap<PathBuf, CachedItem>,
        state: &mut RepoState,
    ) -> Option<String> {
        let (claude_dir, base) = (state.claude_dir.clone(), state.claude_real.clone());
        let io = self.io.as_ref();
        let mut tally = Tally::default();
        for (rel, kind) in DOC_DIRS {
            match list_dir(&claude_dir.join(rel), &base) {
                Ok(listing) => {
                    tally.skipped += listing.skipped;
                    for path in listing.paths {
                        let read = read_file_item(io, repo, kind, rel, &path, old_cache);
                        state.absorb(path, read, &mut tally);
                    }
                }
                Err(e) => tally.folder_error(format!("Can't read .claude/{rel}: {}", describe(&e))),
            }
        }
        match list_wip(&claude_dir.join(WIP_DIR), &base) {
            Ok(listing) => {
                tally.skipped += listing.skipped;
                for topic in listing.paths {
                    let read = read_wip_item(io, repo, &topic, &base, old_cache);
                    state.absorb(topic, read, &mut tally);
                }
            }
            Err(e) => tally.folder_error(format!("Can't read .claude/{WIP_DIR}: {}", describe(&e))),
        }
        tally.into_error()
    }

    fn update(&self) -> SourceUpdate {
        let groups = self
            .repos
            .iter()
            .map(|(name, r)| (Some(name.clone()), r.items.clone()))
            .collect();
        (self.status_now(), groups)
    }

    /// Bring `current` up to date after only `repos` changed: no other repo's
    /// items are copied.
    fn patch(&self, current: &mut SourceUpdate, repos: &[String]) {
        current.0 = self.status_now();
        for repo in repos {
            current
                .1
                .retain(|(group, _)| group.as_deref() != Some(repo.as_str()));
            if let Some(state) = self.repos.get(repo) {
                current.1.push((Some(repo.clone()), state.items.clone()));
            }
        }
        current.1.sort_by(|a, b| a.0.cmp(&b.0));
    }

    fn status_now(&self) -> SourceStatus {
        let count: usize = self.repos.values().map(|r| r.items.len()).sum();
        let group_errors: Vec<GroupError> = self
            .repos
            .iter()
            .filter_map(|(name, r)| {
                r.error.as_ref().map(|reason| GroupError {
                    group: name.clone(),
                    reason: reason.clone(),
                })
            })
            .collect();

        let (state, reason) = match &self.root_issue {
            Some(RootIssue::Missing) => (
                SourceState::NotConfigured,
                Some(format!("Code folder {} not found", self.root.display())),
            ),
            Some(RootIssue::Unreadable(why)) => (
                SourceState::Error,
                Some(format!("Couldn't read {}: {why}", self.root.display())),
            ),
            // Error only when nothing could be shown: readable items keep the list fresh, with the partial-scan note.
            None if count == 0
                && !self.repos.is_empty()
                && group_errors.len() == self.repos.len() =>
            {
                (
                    SourceState::Error,
                    Some("Couldn't read any repo's .claude folder".to_string()),
                )
            }
            None => {
                // Readable, but never plain "fresh" while anything was left out or the list is not live.
                let mut notes = Vec::new();
                if !group_errors.is_empty() {
                    notes.push(format!(
                        "Partial scan: {} of {} repos could not be fully read",
                        group_errors.len(),
                        self.repos.len()
                    ));
                }
                match self.root_skipped {
                    0 => {}
                    1 => notes.push(
                        "1 folder in the code root has a non-UTF-8 name and was skipped"
                            .to_string(),
                    ),
                    n => notes.push(format!(
                        "{n} folders in the code root have non-UTF-8 names and were skipped"
                    )),
                }
                if self.live_updates_unavailable {
                    notes.push(LIVE_UPDATES_UNAVAILABLE.to_string());
                }
                let state = if count == 0 {
                    SourceState::Empty
                } else {
                    SourceState::Fresh
                };
                (state, (!notes.is_empty()).then(|| notes.join("; ")))
            }
        };
        // Whole list: nothing unreadable, skipped or cut off, and the root itself was read.
        let complete = matches!(state, SourceState::Fresh | SourceState::Empty)
            && group_errors.is_empty()
            && self.root_skipped == 0
            && self.root_issue.is_none();
        status(state, reason, count, group_errors, complete)
    }
}

/// A repo whose `.claude/` could not be read at all: keep the last good items, flag the error.
fn failed(mut state: RepoState, previous: Option<&RepoState>, reason: String) -> RepoState {
    if let Some(prev) = previous {
        state.items = prev.items.clone();
        state.cache = prev.cache.clone();
    }
    state.error = Some(reason);
    state
}

/// Whether a repo's published content (items, error) is unchanged.
fn same_repo(a: Option<&RepoState>, b: Option<&RepoState>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.items == b.items && a.error == b.error,
        _ => false,
    }
}

fn status(
    state: SourceState,
    reason: Option<String>,
    count: usize,
    group_errors: Vec<GroupError>,
    complete: bool,
) -> SourceStatus {
    SourceStatus {
        source: WorkSource::RepoDocs,
        state,
        updated_at: (state != SourceState::Loading).then(Utc::now),
        reason,
        retry_at: None,
        count,
        group_errors,
        complete,
    }
}

fn is_watched_top(component: &std::ffi::OsStr) -> bool {
    component
        .to_str()
        .is_some_and(|c| WATCHED_TOPS.contains(&c))
}

/// Plain-English reason for an unreadable `.claude`.
fn claude_problem(e: &std::io::Error) -> String {
    if e.kind() == ErrorKind::NotFound {
        "Can't read .claude: it is a broken symlink".to_string()
    } else {
        format!("Can't read .claude: {}", describe(e))
    }
}

fn describe(e: &std::io::Error) -> String {
    if e.kind() == ErrorKind::PermissionDenied {
        "permission denied".to_string()
    } else {
        e.to_string()
    }
}

/// What a directory listing found: the entries to read and how many it could not look at.
struct Listing {
    paths: Vec<PathBuf>,
    skipped: usize,
}

/// What a listing does with one child.
enum Verdict {
    Keep,
    Ignore,
    /// Looks like a doc but cannot be examined: counted as skipped.
    Unreadable,
}

/// `*.md` files (not hidden) directly in `dir`. A missing directory is empty.
/// A symlinked file must resolve inside `base` (the repo's real `.claude/`):
/// a cloned repo must not be able to put another file's text in the list.
fn list_dir(dir: &Path, base: &Path) -> io::Result<Listing> {
    if !dir_stays_inside(dir, base) {
        return Ok(Listing {
            paths: Vec::new(),
            skipped: 0,
        });
    }
    list_children(dir, |name, path| {
        if !has_md_extension(name) {
            return Verdict::Ignore;
        }
        match fs::metadata(path) {
            Ok(m) if m.is_file() && stays_inside(path, base) => Verdict::Keep,
            Ok(_) => Verdict::Ignore,
            Err(e) if e.kind() == ErrorKind::NotFound => Verdict::Ignore, // a dangling link
            Err(_) => Verdict::Unreadable,
        }
    })
}

/// Topic directories (not hidden) directly in `wip/`. A missing directory is empty.
fn list_wip(dir: &Path, base: &Path) -> io::Result<Listing> {
    if !dir_stays_inside(dir, base) {
        return Ok(Listing {
            paths: Vec::new(),
            skipped: 0,
        });
    }
    list_children(dir, |_, path| match fs::metadata(path) {
        Ok(m) if m.is_dir() && stays_inside(path, base) => Verdict::Keep,
        Ok(_) => Verdict::Ignore,
        Err(e) if e.kind() == ErrorKind::NotFound => Verdict::Ignore,
        Err(_) => Verdict::Unreadable,
    })
}

/// Whether a doc directory (which may itself be a symlink, or sit under one)
/// resolves inside `base`. One that does not exist has nothing to leave.
fn dir_stays_inside(dir: &Path, base: &Path) -> bool {
    fs::canonicalize(dir)
        .ok()
        .is_none_or(|real| real.starts_with(base))
}

/// A plain entry is inside by construction; a symlink must resolve under `base`.
fn stays_inside(path: &Path, base: &Path) -> bool {
    !fs::symlink_metadata(path).is_ok_and(|m| m.is_symlink())
        || fs::canonicalize(path).is_ok_and(|real| real.starts_with(base))
}

/// The non-hidden children of `dir` that `judge` keeps (given name and path).
/// A missing directory, or a file where a directory should be, has no children.
/// Entries the directory read itself fails on count as skipped.
fn list_children(dir: &Path, judge: impl Fn(&str, &Path) -> Verdict) -> io::Result<Listing> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound || is_not_a_directory(&e) => {
            return Ok(Listing {
                paths: Vec::new(),
                skipped: 0,
            })
        }
        Err(e) => return Err(e),
    };
    let mut listing = Listing {
        paths: Vec::new(),
        skipped: 0,
    };
    for entry in entries {
        let Ok(entry) = entry else {
            listing.skipped += 1;
            continue;
        };
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            // Not UTF-8: it cannot be an item id. Hidden names are never docs, so those stay silent,
            // and neither does a plain file that is not a `.md` (it was never a doc).
            let bytes = name.as_encoded_bytes();
            let could_be_doc =
                bytes.len() > 3 && bytes[bytes.len() - 3..].eq_ignore_ascii_case(b".md");
            if !bytes.starts_with(b".") && (could_be_doc || entry.path().is_dir()) {
                listing.skipped += 1;
            }
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        match judge(name, &path) {
            Verdict::Keep => listing.paths.push(path),
            Verdict::Ignore => {}
            Verdict::Unreadable => listing.skipped += 1,
        }
    }
    Ok(listing)
}

fn is_not_a_directory(e: &io::Error) -> bool {
    // `ErrorKind::NotADirectory` is too new for the oldest toolchain in use.
    e.raw_os_error() == Some(20)
}

fn has_md_extension(name: &str) -> bool {
    Path::new(name)
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("md"))
}

/// A file that cannot be reached: gone for good, or there but unreadable.
fn lost(e: &io::Error) -> Outcome {
    if e.kind() == ErrorKind::NotFound {
        Outcome::Gone
    } else {
        Outcome::Unreadable
    }
}

/// The item for one doc file, from the cache when its stamp is unchanged.
fn read_file_item(
    io: &dyn DocFs,
    repo: &str,
    kind: &str,
    rel_dir: &str,
    path: &Path,
    cache: &HashMap<PathBuf, CachedItem>,
) -> Outcome {
    let meta = match io.metadata(path) {
        Ok(meta) => meta,
        Err(e) => return lost(&e),
    };
    let stamp = Stamp {
        mtime: meta.modified().ok(),
        size: meta.len(),
        dir_mtime: None,
    };
    if let Some(hit) = cache.get(path).filter(|c| c.stamp == stamp) {
        return Outcome::Item(stamp, hit.item.clone());
    }
    let text = match io.read_text(path, MAX_READ) {
        Ok(text) => text,
        Err(e) => return lost(&e),
    };
    let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
        return Outcome::Gone;
    };
    let rel = format!("{rel_dir}/{file_name}");
    Outcome::Item(
        stamp,
        build_item(repo, kind, &rel, path, &text, &meta, file_name),
    )
}

/// The item for one wip folder (its `index.md` is the body; it may have none).
/// An `index.md` that exists but cannot be read leaves the folder listed
/// without a body and counted as skipped.
fn read_wip_item(
    io: &dyn DocFs,
    repo: &str,
    dir: &Path,
    base: &Path,
    cache: &HashMap<PathBuf, CachedItem>,
) -> Outcome {
    let dir_meta = match io.metadata(dir) {
        Ok(meta) => meta,
        Err(e) => return lost(&e),
    };
    let index = dir.join("index.md");
    let mut unreadable = false;
    let index_meta = match io.metadata(&index) {
        Ok(m) if m.is_file() && stays_inside(&index, base) => Some(m),
        Ok(_) => None,
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(_) => {
            unreadable = true;
            None
        }
    };
    let stamp = Stamp {
        mtime: index_meta.as_ref().and_then(|m| m.modified().ok()),
        size: index_meta.as_ref().map_or(0, |m| m.len()),
        dir_mtime: dir_meta.modified().ok(),
    };
    if let Some(hit) = cache.get(dir).filter(|c| c.stamp == stamp && !unreadable) {
        return Outcome::Item(stamp, hit.item.clone());
    }
    let Some(topic) = dir.file_name().and_then(|n| n.to_str()) else {
        return Outcome::Gone;
    };
    let mut text = String::new();
    if index_meta.is_some() {
        match io.read_text(&index, MAX_READ) {
            Ok(read) => text = read,
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(_) => unreadable = true,
        }
    }
    let meta = index_meta.as_ref().unwrap_or(&dir_meta);
    let rel = format!("{WIP_DIR}/{topic}");
    let item = build_item(repo, "wip", &rel, dir, &text, meta, topic);
    if unreadable {
        Outcome::Partial(item)
    } else {
        Outcome::Item(stamp, item)
    }
}

// ── parsing (pure) ────────────────────────────────────────────────────────────

/// What a doc's text says about itself.
#[derive(Debug, Default, PartialEq, Eq)]
struct Parsed {
    title: Option<String>,
    severity: Option<String>,
    priority: Option<Priority>,
    front_date: Option<NaiveDate>,
}

fn build_item(
    repo: &str,
    kind: &str,
    rel: &str,
    path: &Path,
    text: &str,
    meta: &fs::Metadata,
    name: &str,
) -> WorkItem {
    let parsed = parse(text);
    // A heading (or a folder name) is whatever the repo's author wrote: one line, capped.
    let title = one_line(
        &parsed.title.unwrap_or_else(|| {
            if kind == "wip" {
                name.to_string()
            } else {
                humanize_slug(name)
            }
        }),
        MAX_LINE_CHARS,
    );

    let mut metrics = BTreeMap::new();
    let filed = prefix_date(name)
        .or(parsed.front_date)
        .map(noon_utc)
        .or_else(|| {
            let inferred = meta
                .created()
                .or_else(|_| meta.modified())
                .ok()
                .map(DateTime::<Utc>::from);
            if inferred.is_some() {
                metrics.insert("date_inferred".to_string(), 1);
            }
            inferred
        });

    let (search_text, cut) = search_text(&title, text);
    if cut || meta.len() > MAX_READ {
        metrics.insert(TRUNCATED_METRIC.to_string(), 1);
    }

    WorkItem {
        id: format!("doc:{repo}:{rel}"),
        source: WorkSource::RepoDocs,
        kind: kind.to_string(),
        search_text,
        title,
        repo: Some(repo.to_string()),
        project: None,
        status: None,
        status_category: None,
        priority: parsed.priority,
        severity: parsed.severity,
        environment: None,
        created_at: filed,
        updated_at: meta.modified().ok().map(DateTime::<Utc>::from),
        due: None,
        url: None,
        path: Some(path.to_string_lossy().into_owned()),
        metrics,
        linked: Vec::new(),
        sent: Vec::new(),
    }
}

/// Title, severity, priority and date as the doc states them (never inferred).
fn parse(text: &str) -> Parsed {
    let (front, body) = split_front_matter(text);
    let mut parsed = Parsed::default();
    if let Some(front) = front {
        parsed.severity =
            front_value(front, "severity").map(|v| truncate_chars(&v, MAX_LABEL_CHARS));
        parsed.priority = front_value(front, "priority").map(|v| priority_from(&v));
        parsed.front_date = front_value(front, "date")
            .or_else(|| front_value(front, "filed"))
            .and_then(|v| parse_date_prefix(&v));
    }

    // The open code fence, if any: its character and length. Only a line of the same
    // character, at least as long and with nothing after it, closes it.
    let mut fence: Option<(char, usize)> = None;
    for line in body.lines() {
        if let Some((ch, run, bare)) = fence_marker(line) {
            match fence {
                None => fence = Some((ch, run)),
                Some((c, len)) if ch == c && run >= len && bare => fence = None,
                Some(_) => {}
            }
            continue;
        }
        let in_fence = fence.is_some();
        if parsed.title.is_none() && !in_fence {
            if let Some(heading) = line.strip_prefix("# ") {
                let heading = heading.trim();
                if !heading.is_empty() {
                    parsed.title = Some(heading.to_string());
                }
            }
        }
        if in_fence {
            continue;
        }
        if parsed.severity.is_none() {
            parsed.severity =
                body_value(line, "**Severity:**").map(|v| truncate_chars(v, MAX_LABEL_CHARS));
        }
        if parsed.priority.is_none() {
            parsed.priority = body_value(line, "**Priority:**").map(priority_from);
        }
    }
    parsed
}

/// `(fence character, run length, nothing after the run)` for a line that starts a
/// code fence (three or more backticks or tildes, after optional indentation).
fn fence_marker(line: &str) -> Option<(char, usize, bool)> {
    let line = line.trim_start();
    let c = line.chars().next().filter(|c| matches!(c, '`' | '~'))?;
    let run = line.chars().take_while(|&x| x == c).count();
    (run >= 3).then(|| (c, run, line[run..].trim().is_empty()))
}

/// `(front matter, rest)`: front matter is a `---` fenced block at the very top.
fn split_front_matter(text: &str) -> (Option<&str>, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let Some(rest) = text.strip_prefix("---") else {
        return (None, text);
    };
    let Some(rest) = rest
        .strip_prefix('\n')
        .or_else(|| rest.strip_prefix("\r\n"))
    else {
        return (None, text);
    };
    let mut offset = 0;
    for line in rest.split_inclusive('\n') {
        if matches!(line.trim_end(), "---" | "...") {
            return (Some(&rest[..offset]), &rest[offset + line.len()..]);
        }
        offset += line.len();
    }
    (None, text)
}

/// `key: value` from front matter (key case-insensitive, quotes stripped).
fn front_value(front: &str, key: &str) -> Option<String> {
    front.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        if !k.trim().eq_ignore_ascii_case(key) {
            return None;
        }
        let v = v.trim().trim_matches(|c| c == '"' || c == '\'').trim();
        (!v.is_empty()).then(|| v.to_string())
    })
}

/// The value of a body line `<label> <value>` (label case-insensitive, at column 0).
fn body_value<'a>(line: &'a str, label: &str) -> Option<&'a str> {
    let head = line.get(..label.len())?;
    if !head.eq_ignore_ascii_case(label) {
        return None;
    }
    let value = line[label.len()..].trim();
    (!value.is_empty()).then_some(value)
}

/// `P1`..`P5` (first word) -> rank; anything else keeps its words at rank 9.
fn priority_from(value: &str) -> Priority {
    let first = value
        .split_whitespace()
        .next()
        .unwrap_or("")
        .trim_end_matches([',', ';', ':', '.', ')']);
    let mut chars = first.chars();
    if let (Some('P' | 'p'), Some(d), None) = (chars.next(), chars.next(), chars.next()) {
        if let Some(rank) = d.to_digit(10).filter(|r| (1..=5).contains(r)) {
            return Priority {
                label: format!("P{rank}"),
                rank: rank as u8,
            };
        }
    }
    Priority {
        label: truncate_chars(value.trim(), MAX_LABEL_CHARS),
        rank: OTHER_PRIORITY_RANK,
    }
}

fn truncate_chars(s: &str, max: usize) -> String {
    s.chars().take(max).collect()
}

fn parse_date_prefix(value: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(value.get(..10)?, "%Y-%m-%d").ok()
}

/// The `YYYY-MM-DD` a file or folder name starts with (`2026-10-01-slug.md`).
fn prefix_date(name: &str) -> Option<NaiveDate> {
    let date = parse_date_prefix(name)?;
    match name[10..].chars().next() {
        None | Some('-' | '_' | '.') => Some(date),
        Some(_) => None,
    }
}

/// Noon UTC: the same calendar day in every time zone a person works in.
fn noon_utc(date: NaiveDate) -> DateTime<Utc> {
    date.and_hms_opt(12, 0, 0)
        .expect("12:00:00 is a valid time")
        .and_utc()
}

/// `2026-10-01-login-fails-badly.md` -> "Login fails badly".
fn humanize_slug(file_name: &str) -> String {
    let stem = Path::new(file_name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(file_name);
    let without_date = if prefix_date(stem).is_some() {
        stem[10..].trim_start_matches(['-', '_'])
    } else {
        stem
    };
    let spaced: String = without_date
        .chars()
        .map(|c| if matches!(c, '-' | '_') { ' ' } else { c })
        .collect();
    let words = spaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => stem.to_string(),
    }
}

/// Title plus the whole text, cut to [`SEARCH_TEXT_CAP`] bytes on a character
/// boundary; true when it was cut.
fn search_text(title: &str, text: &str) -> (String, bool) {
    let mut out = String::with_capacity((title.len() + text.len() + 1).min(SEARCH_TEXT_CAP));
    out.push_str(title);
    out.push('\n');
    out.push_str(text);
    let cut = out.len() > SEARCH_TEXT_CAP;
    if cut {
        let mut at = SEARCH_TEXT_CAP;
        while !out.is_char_boundary(at) {
            at -= 1;
        }
        out.truncate(at);
    }
    (out, cut)
}

// ── watcher thread ────────────────────────────────────────────────────────────

enum Msg {
    /// Paths a file-system event touched.
    Fs(Vec<PathBuf>),
    /// A manual refresh: rescan everything.
    Refresh,
}

/// Debounce bookkeeping for one repo with pending events.
struct Pending {
    first: Instant,
    last: Instant,
}

impl Pending {
    fn due(&self) -> Instant {
        (self.last + DEBOUNCE).min(self.first + MAX_DEBOUNCE)
    }
}

fn run(
    mut scanner: Scanner,
    tx: &watch::Sender<SourceUpdate>,
    msg_tx: mpsc::Sender<Msg>,
    msg_rx: &mpsc::Receiver<Msg>,
) {
    let mut watcher = RepoWatcher::new(msg_tx, &scanner.root);
    let mut pending: HashMap<String, Pending> = HashMap::new();
    // Directories that appeared without a `.claude/` yet: (attempts so far, next look).
    let mut rechecks: HashMap<String, (usize, Instant)> = HashMap::new();
    let mut next_safety = Instant::now() + SAFETY_RESCAN;

    scanner.rescan_all();
    watcher.sync(&scanner.watch_targets());
    scanner.set_live_updates(watcher.is_live());
    if tx.send(scanner.update()).is_err() {
        return;
    }

    loop {
        if tx.is_closed() {
            return;
        }
        let now = Instant::now();
        let wake = pending
            .values()
            .map(Pending::due)
            .chain(rechecks.values().map(|(_, at)| *at))
            .chain([next_safety, now + IDLE_WAKE])
            .min()
            .unwrap_or(next_safety);

        let mut manual_refresh = false;
        match msg_rx.recv_timeout(wake.saturating_duration_since(now)) {
            Ok(Msg::Fs(paths)) => {
                let now = Instant::now();
                for repo in paths.iter().filter_map(|p| scanner.repo_for_event(p)) {
                    pending
                        .entry(repo)
                        .and_modify(|p| p.last = now)
                        .or_insert(Pending {
                            first: now,
                            last: now,
                        });
                }
            }
            Ok(Msg::Refresh) => manual_refresh = true,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }

        let now = Instant::now();
        let full_rescan = manual_refresh || now >= next_safety;
        // `None`: nothing changed. `Some(repos)`: only these repos changed.
        let mut changed_repos: Option<Vec<String>> = None;
        let mut everything_changed = false;
        let mut due_was_empty = true;
        if full_rescan {
            pending.clear();
            rechecks.clear();
            next_safety = now + SAFETY_RESCAN;
            // A manual refresh is answered even when nothing changed.
            everything_changed = scanner.rescan_all() || manual_refresh;
        } else {
            let mut due: Vec<String> = pending
                .iter()
                .filter(|(_, p)| p.due() <= now)
                .map(|(name, _)| name.clone())
                .collect();
            due.extend(
                rechecks
                    .iter()
                    .filter(|(_, (_, at))| *at <= now)
                    .map(|(name, _)| name.clone()),
            );
            due.sort();
            due.dedup();
            due_was_empty = due.is_empty();
            let mut changed = Vec::new();
            for repo in due {
                pending.remove(&repo);
                let attempts = rechecks.remove(&repo).map_or(0, |(n, _)| n);
                if scanner.refresh_repo(&repo) {
                    changed.push(repo.clone());
                }
                // A new directory may get its `.claude/` after we looked.
                if !scanner.has_repo(&repo)
                    && scanner.root.join(&repo).is_dir()
                    && !repo.starts_with('.')
                {
                    if let Some(delay) = NEW_REPO_RECHECKS.get(attempts) {
                        rechecks.insert(repo, (attempts + 1, Instant::now() + *delay));
                    }
                }
            }
            if !changed.is_empty() {
                changed_repos = Some(changed);
            }
        }
        if full_rescan || !due_was_empty {
            watcher.sync(&scanner.watch_targets());
        }
        // The note about live updates rides on the status: publish it whenever it flips,
        // even when no doc changed (a watch can fail, or recover, on its own).
        everything_changed |= scanner.set_live_updates(watcher.is_live());
        if everything_changed || changed_repos.is_some() {
            if everything_changed {
                tx.send_replace(scanner.update());
            } else if let Some(repos) = changed_repos {
                // Only the repos that changed are copied.
                tx.send_modify(|current| scanner.patch(current, &repos));
            }
        }
    }
}

/// One directory for the `notify` watcher to follow.
struct WatchTarget {
    dir: PathBuf,
    recursive: bool,
}

/// The `notify` watchers: the root (non-recursive, for new repos), each repo
/// directory (non-recursive, for a `.claude/` created later) and each repo's
/// `.claude/` (recursive).
struct RepoWatcher {
    watcher: Option<RecommendedWatcher>,
    watched: HashSet<PathBuf>,
    /// Directories `notify` refused: retried on each sync, warned about once.
    failed: HashSet<PathBuf>,
    root: PathBuf,
    root_watched: bool,
    /// Whether a failure to watch the root was already warned about.
    root_warned: bool,
}

impl RepoWatcher {
    fn new(msg_tx: mpsc::Sender<Msg>, root: &Path) -> Self {
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(event) = res else { return };
            if matches!(event.kind, EventKind::Access(_)) || event.paths.is_empty() {
                return;
            }
            let _ = msg_tx.send(Msg::Fs(event.paths));
        });
        let watcher = match watcher {
            Ok(w) => Some(w),
            Err(e) => {
                warn!(error = %e, "repo docs: no file watcher; relying on the 5-minute rescan");
                None
            }
        };
        let mut this = Self {
            watcher,
            watched: HashSet::new(),
            failed: HashSet::new(),
            root: root.to_path_buf(),
            root_watched: false,
            root_warned: false,
        };
        this.watch_root();
        this
    }

    /// Watch the code root unless it already is. A failure (the folder may not
    /// exist yet) is retried on every [`RepoWatcher::sync`].
    fn watch_root(&mut self) {
        if self.root_watched {
            return;
        }
        let Some(watcher) = self.watcher.as_mut() else {
            return;
        };
        match watcher.watch(&self.root, RecursiveMode::NonRecursive) {
            Ok(()) => self.root_watched = true,
            Err(e) => {
                if !std::mem::replace(&mut self.root_warned, true) {
                    warn!(error = %e, root = %self.root.display(), "repo docs: cannot watch the code root; will retry");
                }
            }
        }
    }

    /// Whether every directory that should be watched is: when false the list
    /// only changes on the 5-minute rescan.
    fn is_live(&self) -> bool {
        self.watcher.is_some() && self.root_watched && self.failed.is_empty()
    }

    /// Watch exactly the targets (retrying ones that failed before, and the root).
    fn sync(&mut self, targets: &[WatchTarget]) {
        self.watch_root();
        let Some(watcher) = self.watcher.as_mut() else {
            return;
        };
        let wanted: HashSet<&PathBuf> = targets.iter().map(|t| &t.dir).collect();
        let gone: Vec<PathBuf> = self
            .watched
            .iter()
            .filter(|d| !wanted.contains(d))
            .cloned()
            .collect();
        for dir in gone {
            let _ = watcher.unwatch(&dir);
            self.watched.remove(&dir);
        }
        self.failed.retain(|d| wanted.contains(d));
        for target in targets {
            if self.watched.contains(&target.dir) {
                continue;
            }
            let mode = if target.recursive {
                RecursiveMode::Recursive
            } else {
                RecursiveMode::NonRecursive
            };
            match watcher.watch(&target.dir, mode) {
                Ok(()) => {
                    self.failed.remove(&target.dir);
                    self.watched.insert(target.dir.clone());
                }
                Err(e) => {
                    if self.failed.insert(target.dir.clone()) {
                        warn!(error = %e, dir = %target.dir.display(), "repo docs: cannot watch; relying on the 5-minute rescan");
                    }
                }
            }
        }
    }
}

// ── detail ────────────────────────────────────────────────────────────────────

fn unknown_item() -> WorkError {
    WorkError::new("unknown_item", "That doc no longer exists")
}

/// Split `<repo>:<rel>` where `rel` is a doc or wip path under `.claude/`. A
/// repo name may hold `:` (it cannot hold `/`), and so may a file name: the
/// split is the first `:` that is followed by one of the doc directories.
fn split_item_id(rest: &str) -> Option<(&str, &str)> {
    let starts_doc_path = |tail: &str| {
        DOC_DIRS
            .iter()
            .map(|(dir, _)| *dir)
            .chain([WIP_DIR])
            .any(|dir| {
                tail.strip_prefix(dir)
                    .is_some_and(|after| after.starts_with('/'))
            })
    };
    rest.match_indices(':')
        .map(|(at, _)| (&rest[..at], &rest[at + 1..]))
        .find(|(_, tail)| starts_doc_path(tail))
}

fn detail_blocking(root: &Path, item_id: &str) -> Result<WorkDetail, WorkError> {
    let root = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let rest = item_id.strip_prefix("doc:").ok_or_else(unknown_item)?;
    let (repo, rel) = split_item_id(rest).ok_or_else(unknown_item)?;
    if repo.is_empty()
        || repo.starts_with('.')
        || repo.contains(['/', '\\', '\0'])
        || rel.contains(['\\', '\0'])
    {
        return Err(unknown_item());
    }
    let parts: Vec<&str> = rel.split('/').collect();
    if parts
        .iter()
        .any(|p| p.is_empty() || *p == "." || *p == "..")
    {
        return Err(unknown_item());
    }
    let (kind, is_wip) = kind_of_rel(&parts).ok_or_else(unknown_item)?;

    let repo_dir = root.join(repo);
    let claude = repo_dir.join(".claude");
    let path = claude.join(rel);
    // Whatever the id says, never read outside the repo's own `.claude/`, and
    // `.claude/` itself must be inside the repo (a cloned repo can symlink it anywhere).
    let real_repo = fs::canonicalize(&repo_dir).map_err(|_| unknown_item())?;
    let real_claude = fs::canonicalize(&claude).map_err(|_| unknown_item())?;
    if real_claude == real_repo || !real_claude.starts_with(&real_repo) {
        return Err(unknown_item());
    }
    let real_path = fs::canonicalize(&path).map_err(|_| unknown_item())?;
    if !real_path.starts_with(&real_claude) {
        return Err(unknown_item());
    }

    let name = parts[parts.len() - 1];
    let meta = fs::metadata(&path).map_err(|_| unknown_item())?;
    let mut notes = Vec::new();
    let (text, index_meta) = if is_wip {
        if !meta.is_dir() {
            return Err(unknown_item());
        }
        let index = path.join("index.md");
        match fs::metadata(&index) {
            Ok(m) if m.is_file() && stays_inside(&index, &real_claude) => {
                match read_detail_text(&index) {
                    Ok(text) => (text, Some(m)),
                    Err(e) => {
                        notes.push(format!("index.md could not be read: {}", describe(&e)));
                        (String::new(), Some(m))
                    }
                }
            }
            Err(e) if e.kind() != ErrorKind::NotFound => {
                notes.push(format!("index.md could not be read: {}", describe(&e)));
                (String::new(), None)
            }
            _ => (String::new(), None),
        }
    } else {
        if !meta.is_file() {
            return Err(unknown_item());
        }
        (
            read_detail_text(&path).map_err(|e| {
                if e.kind() == ErrorKind::NotFound {
                    unknown_item()
                } else {
                    WorkError::new(
                        "unreadable",
                        format!("Couldn't read that doc: {}", describe(&e)),
                    )
                }
            })?,
            None,
        )
    };
    let item = build_item(
        repo,
        kind,
        rel,
        &path,
        &text,
        index_meta.as_ref().unwrap_or(&meta),
        name,
    );

    let mut fields = detail_fields(&item, kind, repo, rel);
    let files = if is_wip {
        let listed = wip_files(&path, &real_claude);
        if listed.total > listed.files.len() {
            notes.push(format!(
                "showing the first {} of {} files",
                listed.files.len(),
                listed.total
            ));
        }
        if listed.unreadable > 0 {
            notes.push(format!("{} entries could not be listed", listed.unreadable));
        }
        listed.files
    } else {
        Vec::new()
    };
    fields.extend(notes.into_iter().map(|note| ("Note".to_string(), note)));
    let link = url::Url::from_file_path(&path).ok().map(|u| Link {
        label: if is_wip {
            "Open folder".to_string()
        } else {
            "Open file".to_string()
        },
        url: u.to_string(),
    });
    Ok(WorkDetail {
        item_id: item_id.to_string(),
        title: item.title,
        fields,
        markdown: text,
        files,
        links: link.into_iter().collect(),
    })
}

/// The label/value rows above a doc's body.
fn detail_fields(item: &WorkItem, kind: &str, repo: &str, rel: &str) -> Vec<(String, String)> {
    let mut fields = vec![
        ("Type".to_string(), kind_label(kind).to_string()),
        ("Repo".to_string(), repo.to_string()),
    ];
    if let Some(filed) = item.created_at {
        let mut value = filed.format("%Y-%m-%d").to_string();
        if item.metrics.contains_key("date_inferred") {
            value.push_str(" (approximate: from the file's date)");
        }
        fields.push(("Filed".to_string(), value));
    }
    if let Some(severity) = &item.severity {
        fields.push(("Severity".to_string(), severity.clone()));
    }
    if let Some(priority) = &item.priority {
        fields.push(("Priority".to_string(), priority.label.clone()));
    }
    fields.push(("Path".to_string(), format!(".claude/{rel}")));
    if item.metrics.contains_key(TRUNCATED_METRIC) {
        fields.push((
            "Search".to_string(),
            format!(
                "truncated: only the first {} KiB of this doc is searchable",
                SEARCH_TEXT_CAP / 1024
            ),
        ));
    }
    fields
}

/// `(kind, is_wip)` for a relative path under `.claude/` that is a doc or a wip folder.
fn kind_of_rel(parts: &[&str]) -> Option<(&'static str, bool)> {
    if let ["wip", _topic] = parts {
        return Some(("wip", true));
    }
    let (file, dir) = parts.split_last()?;
    if !has_md_extension(file) || file.starts_with('.') {
        return None;
    }
    let dir = dir.join("/");
    DOC_DIRS
        .iter()
        .find(|(d, _)| *d == dir)
        .map(|(_, kind)| (*kind, false))
}

fn kind_label(kind: &str) -> &'static str {
    match kind {
        "bug" => "Bug",
        "feature" => "Feature",
        "idea" => "Idea",
        "todo" => "Todo",
        _ => "WIP",
    }
}

/// The file's text, cut to [`MAX_DETAIL`] (with a note) when larger.
fn read_detail_text(path: &Path) -> io::Result<String> {
    let mut text = RealFs.read_text(path, MAX_DETAIL + 1)?;
    if text.len() as u64 > MAX_DETAIL {
        let mut cut = MAX_DETAIL as usize;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
        text.push_str("\n\n… (truncated: the file is longer than 1 MiB)\n");
    }
    Ok(text)
}

/// What a wip folder's listing found.
struct WipFiles {
    /// Absolute paths of the other files (not `index.md`, not hidden), sorted, at most [`MAX_WIP_FILES`].
    files: Vec<String>,
    /// How many there were before the cut.
    total: usize,
    /// Entries (or the folder) that could not be listed.
    unreadable: usize,
}

fn wip_files(dir: &Path, base: &Path) -> WipFiles {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => {
            return WipFiles {
                files: Vec::new(),
                total: 0,
                unreadable: 1,
            }
        }
    };
    let mut unreadable = 0;
    let mut files = Vec::new();
    for entry in entries {
        let Ok(entry) = entry else {
            unreadable += 1;
            continue;
        };
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') || name == "index.md" {
            continue;
        }
        let path = entry.path();
        if fs::metadata(&path).is_ok_and(|m| m.is_file()) && stays_inside(&path, base) {
            files.push(path.to_string_lossy().into_owned());
        }
    }
    files.sort();
    let total = files.len();
    files.truncate(MAX_WIP_FILES);
    WipFiles {
        files,
        total,
        unreadable,
    }
}

// ── unit tests (pure parts) ───────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_is_the_first_heading_after_front_matter() {
        let parsed = parse("---\nseverity: low\n---\n\nintro\n# The Title\n# Another\n");
        assert_eq!(parsed.title.as_deref(), Some("The Title"));
        assert_eq!(parsed.severity.as_deref(), Some("low"));
    }

    #[test]
    fn a_heading_inside_a_code_fence_is_not_the_title() {
        let parsed = parse("```bash\n# a comment\n```\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
    }

    #[test]
    fn severity_comes_from_a_bold_body_line_case_insensitively() {
        assert_eq!(
            parse("# T\n**Severity:** high\n").severity.as_deref(),
            Some("high")
        );
        assert_eq!(
            parse("# T\n**severity:**   Medium  \n").severity.as_deref(),
            Some("Medium")
        );
        assert_eq!(parse("# T\nNothing about it here\n").severity, None);
        assert_eq!(
            parse("# T\n**Severity:**\n").severity,
            None,
            "an empty value states nothing"
        );
    }

    #[test]
    fn front_matter_wins_over_the_body_for_severity() {
        assert_eq!(
            parse("---\nSeverity: \"high\"\n---\n**Severity:** low\n")
                .severity
                .as_deref(),
            Some("high")
        );
    }

    #[test]
    fn priority_maps_p1_to_p5_and_keeps_other_words() {
        assert_eq!(
            priority_from("P2"),
            Priority {
                label: "P2".into(),
                rank: 2
            }
        );
        assert_eq!(
            priority_from("p4 (nice to have)"),
            Priority {
                label: "P4".into(),
                rank: 4
            }
        );
        assert_eq!(
            priority_from("urgent"),
            Priority {
                label: "urgent".into(),
                rank: 9
            }
        );
        assert_eq!(
            priority_from("P7"),
            Priority {
                label: "P7".into(),
                rank: 9
            }
        );
        assert_eq!(
            parse("# T\n**Priority:** P1\n").priority,
            Some(Priority {
                label: "P1".into(),
                rank: 1
            })
        );
    }

    #[test]
    fn dates_come_from_the_name_prefix_only_when_it_is_a_whole_date() {
        assert_eq!(
            prefix_date("2026-10-01-slug.md"),
            NaiveDate::from_ymd_opt(2026, 10, 1)
        );
        assert_eq!(
            prefix_date("2026-10-01.md"),
            NaiveDate::from_ymd_opt(2026, 10, 1)
        );
        assert_eq!(prefix_date("2026-10-011-slug.md"), None);
        assert_eq!(prefix_date("slug.md"), None);
        assert_eq!(prefix_date("é2026-10-01-x.md"), None);
    }

    #[test]
    fn slugs_are_humanised_without_their_date() {
        assert_eq!(
            humanize_slug("2026-10-01-login-fails_badly.md"),
            "Login fails badly"
        );
        assert_eq!(humanize_slug("callimachus-notes.md"), "Callimachus notes");
        assert_eq!(humanize_slug("2026-10-01.md"), "2026-10-01");
    }

    #[test]
    fn search_text_is_capped_on_a_character_boundary() {
        let body = "é".repeat(SEARCH_TEXT_CAP);
        let (text, cut) = search_text("Title", &body);
        assert!(cut);
        assert!(text.len() <= SEARCH_TEXT_CAP);
        assert!(text.starts_with("Title\n"));
    }

    #[test]
    fn unterminated_front_matter_is_not_front_matter() {
        let (front, body) = split_front_matter("---\nseverity: high\n# Title\n");
        assert_eq!(front, None);
        assert!(body.starts_with("---"));
    }

    // ── fences: the closing line must match the opening one ──────────────────

    #[test]
    fn a_tilde_line_inside_a_backtick_block_does_not_close_it() {
        let parsed = parse("```\n~~~\n# not the title\n```\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
    }

    #[test]
    fn a_backtick_line_inside_a_tilde_block_does_not_close_it() {
        let parsed = parse("~~~\n```\n# not the title\n~~~\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
    }

    #[test]
    fn a_shorter_fence_does_not_close_a_longer_one() {
        let parsed = parse("````\n```\n# not the title\n````\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
    }

    #[test]
    fn a_longer_closing_fence_closes_a_shorter_one() {
        let parsed = parse("```\ncode\n`````\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
        let parsed = parse("~~~\ncode\n~~~~~~\n# Real title\n");
        assert_eq!(parsed.title.as_deref(), Some("Real title"));
    }

    #[test]
    fn a_heading_right_after_the_proper_close_is_the_title() {
        let parsed = parse("```rust\n```\n# Right after\n");
        assert_eq!(parsed.title.as_deref(), Some("Right after"));
    }

    #[test]
    fn severity_and_priority_lines_stay_ignored_until_the_matching_fence_closes() {
        let text = "```\n~~~\n**Severity:** high\n**Priority:** P1\n```\n# T\n**Severity:** low\n";
        let parsed = parse(text);
        assert_eq!(parsed.title.as_deref(), Some("T"));
        assert_eq!(
            parsed.severity.as_deref(),
            Some("low"),
            "only the line after the real close counts"
        );
        assert_eq!(parsed.priority, None);
    }

    // ── the live-updates note ────────────────────────────────────────────────

    #[test]
    fn the_live_updates_note_follows_the_watcher_and_never_makes_the_list_incomplete() {
        let tmp = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(tmp.path()).unwrap();
        fs::create_dir_all(root.join("alpha/.claude/ideas")).unwrap();
        fs::write(root.join("alpha/.claude/ideas/one.md"), "# One\n").unwrap();
        let mut scanner = Scanner::new(root);
        let (status, _) = scanner.scan_all();
        assert_eq!(
            (status.state, status.reason.as_deref(), status.complete),
            (SourceState::Fresh, None, true)
        );

        assert!(
            scanner.set_live_updates(false),
            "the watcher failing is a change to publish, though no doc changed"
        );
        let (status, _) = scanner.update();
        assert_eq!(status.state, SourceState::Fresh);
        assert_eq!(status.reason.as_deref(), Some(LIVE_UPDATES_UNAVAILABLE));
        assert_eq!(status.count, 1);
        assert!(
            status.complete,
            "the list was scanned whole; only its freshness is in doubt: {status:?}"
        );

        assert!(
            !scanner.set_live_updates(false),
            "saying the same thing again is no change"
        );

        assert!(
            scanner.set_live_updates(true),
            "the watcher coming back is a change too"
        );
        let (status, _) = scanner.update();
        assert_eq!((status.reason, status.complete), (None, true));
    }
}
