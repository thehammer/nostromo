//! Repo docs work source: every open bug, feature, idea, todo and wip folder
//! filed with `doc-mgr` under `~/Code/<repo>/.claude/`.
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

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::{ErrorKind, Read};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use chrono::{DateTime, NaiveDate, Utc};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::{watch, Notify};
use tracing::{debug, warn};

use super::hub::SourceUpdate;
use super::model::{
    GroupError, Link, Priority, SourceState, SourceStatus, WorkDetail, WorkError, WorkItem,
    WorkSource,
};

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

/// The directory whose children are the repos: `$NOSTROMO_CODE_ROOT`, else `~/Code`.
pub fn code_root() -> PathBuf {
    if let Some(root) = std::env::var_os("NOSTROMO_CODE_ROOT").filter(|v| !v.is_empty()) {
        return PathBuf::from(root);
    }
    dirs_next::home_dir().unwrap_or_default().join("Code")
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
    let (tx, rx) = watch::channel((status(SourceState::Loading, None, 0, Vec::new()), Vec::new()));
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

    let spawned = std::thread::Builder::new()
        .name("repo-docs".into())
        .spawn(move || run(Scanner::new(root), &tx, msg_tx, &msg_rx));
    if let Err(e) = spawned {
        warn!(error = %e, "could not start the repo docs watcher thread");
    }
    rx
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

/// Scans the doc-mgr layout under one root and remembers what it parsed.
pub struct Scanner {
    root: PathBuf,
    repos: BTreeMap<String, RepoState>,
    root_issue: Option<RootIssue>,
}

#[derive(PartialEq, Eq)]
enum RootIssue {
    Missing,
    Unreadable(String),
}

struct RepoState {
    /// `<root>/<repo>/.claude`, as reached through the root.
    claude_dir: PathBuf,
    /// The same directory with symlinks resolved: what FSEvents reports.
    claude_real: PathBuf,
    items: Vec<WorkItem>,
    /// Why this repo's docs could not be read (the last good `items` are kept).
    error: Option<String>,
    cache: HashMap<PathBuf, CachedItem>,
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
        let root = fs::canonicalize(&root).unwrap_or(root);
        Self { root, repos: BTreeMap::new(), root_issue: None }
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
                let mut names: Vec<String> =
                    entries.flatten().filter_map(|e| e.file_name().into_string().ok()).collect();
                names.sort();
                let mut old = std::mem::take(&mut self.repos);
                for name in names {
                    let previous = old.remove(&name);
                    let state = self.scan_repo(&name, previous.as_ref());
                    changed |= !same_repo(previous.as_ref(), state.as_ref());
                    if let Some(state) = state {
                        self.repos.insert(name, state);
                    }
                }
                changed |= !old.is_empty();
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
        if let Some(state) = state {
            self.repos.insert(repo.to_string(), state);
        }
        changed
    }

    /// Whether `name` is currently a repo with docs to read.
    fn has_repo(&self, name: &str) -> bool {
        self.repos.contains_key(name)
    }

    /// `(repo, .claude dir)` of every repo, for the watcher.
    fn watch_targets(&self) -> Vec<(String, PathBuf)> {
        self.repos.iter().map(|(name, r)| (name.clone(), r.claude_dir.clone())).collect()
    }

    /// The repo owning an event path (the path may use resolved symlinks).
    fn repo_for_event(&self, path: &Path) -> Option<String> {
        if let Ok(rel) = path.strip_prefix(&self.root) {
            let mut parts = rel.components();
            let name = parts.next()?.as_os_str().to_str()?.to_string();
            return match parts.next() {
                None => Some(name),   // a child of the root appeared or went away
                Some(c) if c.as_os_str() == ".claude" => match parts.next() {
                    None => Some(name),
                    Some(top) if is_watched_top(top.as_os_str()) => Some(name),
                    Some(_) => None,
                },
                Some(_) => None,
            };
        }
        // A symlinked repo reports its target's path.
        self.repos.iter().find_map(|(name, r)| {
            let rel = path.strip_prefix(&r.claude_real).ok()?;
            match rel.components().next() {
                None => Some(name.clone()),
                Some(top) if is_watched_top(top.as_os_str()) => Some(name.clone()),
                Some(_) => None,
            }
        })
    }

    /// Read one repo's docs, reusing `previous`'s parse of unchanged files.
    /// `None`: not a repo (or no longer one).
    fn scan_repo(&self, name: &str, previous: Option<&RepoState>) -> Option<RepoState> {
        if name.starts_with('.') {
            return None;
        }
        let dir = self.root.join(name);
        if !fs::metadata(&dir).ok()?.is_dir() {
            return None;
        }
        // A git worktree's `.git` is a file: its docs duplicate the main repo's.
        if fs::symlink_metadata(dir.join(".git")).is_ok_and(|m| m.is_file()) {
            return None;
        }
        let claude_dir = dir.join(".claude");
        // Not provably a repo (absent, or the parent cannot be searched): not one.
        fs::symlink_metadata(&claude_dir).ok()?;
        let claude_real = fs::canonicalize(&claude_dir).unwrap_or_else(|_| claude_dir.clone());

        let mut state = RepoState {
            claude_dir: claude_dir.clone(),
            claude_real,
            items: Vec::new(),
            error: None,
            cache: HashMap::new(),
        };
        match fs::metadata(&claude_dir) {
            Ok(m) if !m.is_dir() => return None,
            Ok(_) => {}
            Err(e) => return Some(failed(state, previous, claude_problem(&e))),
        }
        if let Err(e) = fs::read_dir(&claude_dir) {
            return Some(failed(state, previous, claude_problem(&e)));
        }

        let no_cache = HashMap::new();
        let old_cache = previous.map_or(&no_cache, |p| &p.cache);
        // One unreadable folder flags the repo but the readable ones still show.
        state.error = read_docs(name, &claude_dir, old_cache, &mut state);
        state.items.sort_by(|a, b| a.id.cmp(&b.id));
        Some(state)
    }

    fn update(&self) -> SourceUpdate {
        let groups: Vec<(Option<String>, Vec<WorkItem>)> =
            self.repos.iter().map(|(name, r)| (Some(name.clone()), r.items.clone())).collect();
        let count: usize = self.repos.values().map(|r| r.items.len()).sum();
        let group_errors: Vec<GroupError> = self
            .repos
            .iter()
            .filter_map(|(name, r)| {
                r.error.as_ref().map(|reason| GroupError { group: name.clone(), reason: reason.clone() })
            })
            .collect();

        let (state, reason) = match &self.root_issue {
            Some(RootIssue::Missing) => (
                SourceState::NotConfigured,
                Some(format!("Code folder {} not found", self.root.display())),
            ),
            Some(RootIssue::Unreadable(why)) => {
                (SourceState::Error, Some(format!("Couldn't read {}: {why}", self.root.display())))
            }
            None if !self.repos.is_empty() && group_errors.len() == self.repos.len() => {
                (SourceState::Error, Some("Couldn't read any repo's .claude folder".to_string()))
            }
            None if count == 0 => (SourceState::Empty, None),
            None => (SourceState::Fresh, None),
        };
        (status(state, reason, count, group_errors), groups)
    }
}

/// Read every doc folder under `claude_dir` into `state`; returns the first
/// folder error, if any.
fn read_docs(
    repo: &str,
    claude_dir: &Path,
    old_cache: &HashMap<PathBuf, CachedItem>,
    state: &mut RepoState,
) -> Option<String> {
    let mut first_error: Option<String> = None;
    let mut keep = |path: PathBuf, read: Option<(Stamp, WorkItem)>| {
        if let Some((stamp, item)) = read {
            state.items.push(item.clone());
            state.cache.insert(path, CachedItem { stamp, item });
        }
    };
    for (rel, kind) in DOC_DIRS {
        match list_dir(&claude_dir.join(rel)) {
            Ok(files) => {
                for path in files {
                    let read = read_file_item(repo, kind, rel, &path, old_cache);
                    keep(path, read);
                }
            }
            Err(e) => {
                first_error.get_or_insert_with(|| format!("Can't read .claude/{rel}: {}", describe(&e)));
            }
        }
    }
    match list_wip(&claude_dir.join(WIP_DIR)) {
        Ok(topics) => {
            for topic in topics {
                let read = read_wip_item(repo, &topic, old_cache);
                keep(topic, read);
            }
        }
        Err(e) => {
            first_error.get_or_insert_with(|| format!("Can't read .claude/{WIP_DIR}: {}", describe(&e)));
        }
    }
    first_error
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
) -> SourceStatus {
    SourceStatus {
        source: WorkSource::RepoDocs,
        state,
        updated_at: (state != SourceState::Loading).then(Utc::now),
        reason,
        retry_at: None,
        count,
        group_errors,
    }
}

fn is_watched_top(component: &std::ffi::OsStr) -> bool {
    component.to_str().is_some_and(|c| WATCHED_TOPS.contains(&c))
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

/// `*.md` files (not hidden) directly in `dir`. A missing directory is empty.
fn list_dir(dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    list_children(dir, |name, path| {
        has_md_extension(name) && fs::metadata(path).is_ok_and(|m| m.is_file())
    })
}

/// Topic directories (not hidden) directly in `wip/`. A missing directory is empty.
fn list_wip(dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    list_children(dir, |_, path| fs::metadata(path).is_ok_and(|m| m.is_dir()))
}

/// The non-hidden children of `dir` that `keep` accepts (given name and path).
/// A missing directory, or a file where a directory should be, has no children.
fn list_children(dir: &Path, keep: impl Fn(&str, &Path) -> bool) -> std::io::Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == ErrorKind::NotFound || is_not_a_directory(&e) => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut children = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let path = entry.path();
        if !name.starts_with('.') && keep(name, &path) {
            children.push(path);
        }
    }
    Ok(children)
}

fn is_not_a_directory(e: &std::io::Error) -> bool {
    // `ErrorKind::NotADirectory` is too new for the oldest toolchain in use.
    e.raw_os_error() == Some(20)
}

fn has_md_extension(name: &str) -> bool {
    Path::new(name).extension().is_some_and(|e| e.eq_ignore_ascii_case("md"))
}

/// The item for one doc file, from the cache when its stamp is unchanged.
fn read_file_item(
    repo: &str,
    kind: &str,
    rel_dir: &str,
    path: &Path,
    cache: &HashMap<PathBuf, CachedItem>,
) -> Option<(Stamp, WorkItem)> {
    let meta = fs::metadata(path).ok()?;
    let stamp = Stamp { mtime: meta.modified().ok(), size: meta.len(), dir_mtime: None };
    if let Some(hit) = cache.get(path).filter(|c| c.stamp == stamp) {
        return Some((stamp, hit.item.clone()));
    }
    let text = read_text(path, MAX_READ)?;
    let file_name = path.file_name()?.to_str()?;
    let rel = format!("{rel_dir}/{file_name}");
    Some((stamp, build_item(repo, kind, &rel, path, &text, &meta, file_name)))
}

/// The item for one wip folder (its `index.md` is the body; it may have none).
fn read_wip_item(
    repo: &str,
    dir: &Path,
    cache: &HashMap<PathBuf, CachedItem>,
) -> Option<(Stamp, WorkItem)> {
    let dir_meta = fs::metadata(dir).ok()?;
    let index = dir.join("index.md");
    let index_meta = fs::metadata(&index).ok().filter(|m| m.is_file());
    let stamp = Stamp {
        mtime: index_meta.as_ref().and_then(|m| m.modified().ok()),
        size: index_meta.as_ref().map_or(0, |m| m.len()),
        dir_mtime: dir_meta.modified().ok(),
    };
    if let Some(hit) = cache.get(dir).filter(|c| c.stamp == stamp) {
        return Some((stamp, hit.item.clone()));
    }
    let topic = dir.file_name()?.to_str()?;
    let text = if index_meta.is_some() { read_text(&index, MAX_READ).unwrap_or_default() } else { String::new() };
    let meta = index_meta.as_ref().unwrap_or(&dir_meta);
    let rel = format!("{WIP_DIR}/{topic}");
    Some((stamp, build_item(repo, "wip", &rel, dir, &text, meta, topic)))
}

fn read_text(path: &Path, limit: u64) -> Option<String> {
    let mut bytes = Vec::new();
    fs::File::open(path).ok()?.take(limit).read_to_end(&mut bytes).ok()?;
    Some(String::from_utf8_lossy(&bytes).into_owned())
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
    let title = parsed.title.unwrap_or_else(|| {
        if kind == "wip" {
            name.to_string()
        } else {
            humanize_slug(name)
        }
    });

    let mut metrics = BTreeMap::new();
    let filed = prefix_date(name).or(parsed.front_date).map(noon_utc).or_else(|| {
        let inferred = meta.created().or_else(|_| meta.modified()).ok().map(DateTime::<Utc>::from);
        if inferred.is_some() {
            metrics.insert("date_inferred".to_string(), 1);
        }
        inferred
    });

    WorkItem {
        id: format!("doc:{repo}:{rel}"),
        source: WorkSource::RepoDocs,
        kind: kind.to_string(),
        search_text: search_text(&title, text),
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
        parsed.severity = front_value(front, "severity").map(|v| truncate_chars(&v, MAX_LABEL_CHARS));
        parsed.priority = front_value(front, "priority").map(|v| priority_from(&v));
        parsed.front_date = front_value(front, "date")
            .or_else(|| front_value(front, "filed"))
            .and_then(|v| parse_date_prefix(&v));
    }

    let mut in_fence = false;
    for line in body.lines() {
        if line.trim_start().starts_with("```") || line.trim_start().starts_with("~~~") {
            in_fence = !in_fence;
            continue;
        }
        if parsed.title.is_none() && !in_fence {
            if let Some(heading) = line.strip_prefix("# ") {
                let heading = heading.trim();
                if !heading.is_empty() {
                    parsed.title = Some(heading.to_string());
                }
            }
        }
        if parsed.severity.is_none() {
            parsed.severity = body_value(line, "**Severity:**").map(|v| truncate_chars(v, MAX_LABEL_CHARS));
        }
        if parsed.priority.is_none() {
            parsed.priority = body_value(line, "**Priority:**").map(priority_from);
        }
    }
    parsed
}

/// `(front matter, rest)`: front matter is a `---` fenced block at the very top.
fn split_front_matter(text: &str) -> (Option<&str>, &str) {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let Some(rest) = text.strip_prefix("---") else { return (None, text) };
    let Some(rest) = rest.strip_prefix('\n').or_else(|| rest.strip_prefix("\r\n")) else {
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
    let first = value.split_whitespace().next().unwrap_or("").trim_end_matches([',', ';', ':', '.', ')']);
    let mut chars = first.chars();
    if let (Some('P' | 'p'), Some(d), None) = (chars.next(), chars.next(), chars.next()) {
        if let Some(rank) = d.to_digit(10).filter(|r| (1..=5).contains(r)) {
            return Priority { label: format!("P{rank}"), rank: rank as u8 };
        }
    }
    Priority { label: truncate_chars(value.trim(), MAX_LABEL_CHARS), rank: OTHER_PRIORITY_RANK }
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
    date.and_hms_opt(12, 0, 0).expect("12:00:00 is a valid time").and_utc()
}

/// `2026-10-01-login-fails-badly.md` -> "Login fails badly".
fn humanize_slug(file_name: &str) -> String {
    let stem = Path::new(file_name).file_stem().and_then(|s| s.to_str()).unwrap_or(file_name);
    let without_date = if prefix_date(stem).is_some() { stem[10..].trim_start_matches(['-', '_']) } else { stem };
    let spaced: String = without_date.chars().map(|c| if matches!(c, '-' | '_') { ' ' } else { c }).collect();
    let words = spaced.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut chars = words.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => stem.to_string(),
    }
}

/// Title plus the whole text, cut to [`SEARCH_TEXT_CAP`] bytes on a character boundary.
fn search_text(title: &str, text: &str) -> String {
    let mut out = String::with_capacity((title.len() + text.len() + 1).min(SEARCH_TEXT_CAP));
    out.push_str(title);
    out.push('\n');
    out.push_str(text);
    if out.len() > SEARCH_TEXT_CAP {
        let mut cut = SEARCH_TEXT_CAP;
        while !out.is_char_boundary(cut) {
            cut -= 1;
        }
        out.truncate(cut);
    }
    out
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

        let mut full_rescan = false;
        match msg_rx.recv_timeout(wake.saturating_duration_since(now)) {
            Ok(Msg::Fs(paths)) => {
                let now = Instant::now();
                for repo in paths.iter().filter_map(|p| scanner.repo_for_event(p)) {
                    pending
                        .entry(repo)
                        .and_modify(|p| p.last = now)
                        .or_insert(Pending { first: now, last: now });
                }
            }
            Ok(Msg::Refresh) => full_rescan = true,
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }

        let now = Instant::now();
        if now >= next_safety {
            full_rescan = true;
        }
        let mut changed = false;
        if full_rescan {
            pending.clear();
            rechecks.clear();
            next_safety = now + SAFETY_RESCAN;
            scanner.rescan_all();
            changed = true;   // a manual refresh is answered even when nothing changed
        } else {
            let mut due: Vec<String> =
                pending.iter().filter(|(_, p)| p.due() <= now).map(|(name, _)| name.clone()).collect();
            due.extend(rechecks.iter().filter(|(_, (_, at))| *at <= now).map(|(name, _)| name.clone()));
            due.sort();
            due.dedup();
            for repo in due {
                pending.remove(&repo);
                let attempts = rechecks.remove(&repo).map_or(0, |(n, _)| n);
                changed |= scanner.refresh_repo(&repo);
                // A new directory may get its `.claude/` after we looked.
                if !scanner.has_repo(&repo) && scanner.root.join(&repo).is_dir() && !repo.starts_with('.') {
                    if let Some(delay) = NEW_REPO_RECHECKS.get(attempts) {
                        rechecks.insert(repo, (attempts + 1, Instant::now() + *delay));
                    }
                }
            }
        }
        if changed {
            watcher.sync(&scanner.watch_targets());
            if tx.send(scanner.update()).is_err() {
                return;
            }
        }
    }
}

/// The `notify` watchers: the root (non-recursive, for new repos) and each
/// repo's `.claude/` (recursive).
struct RepoWatcher {
    watcher: Option<RecommendedWatcher>,
    watched: HashSet<PathBuf>,
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
        let mut watcher = match watcher {
            Ok(w) => Some(w),
            Err(e) => {
                warn!(error = %e, "repo docs: no file watcher; relying on the 5-minute rescan");
                None
            }
        };
        if let Some(w) = watcher.as_mut() {
            if let Err(e) = w.watch(root, RecursiveMode::NonRecursive) {
                warn!(error = %e, root = %root.display(), "repo docs: cannot watch the code root");
            }
        }
        Self { watcher, watched: HashSet::new() }
    }

    /// Watch exactly the repos' `.claude/` directories (retrying ones that failed before).
    fn sync(&mut self, targets: &[(String, PathBuf)]) {
        let Some(watcher) = self.watcher.as_mut() else { return };
        let wanted: HashSet<&PathBuf> = targets.iter().map(|(_, dir)| dir).collect();
        let gone: Vec<PathBuf> = self.watched.iter().filter(|d| !wanted.contains(d)).cloned().collect();
        for dir in gone {
            let _ = watcher.unwatch(&dir);
            self.watched.remove(&dir);
        }
        for (_, dir) in targets {
            if self.watched.contains(dir) {
                continue;
            }
            match watcher.watch(dir, RecursiveMode::Recursive) {
                Ok(()) => {
                    self.watched.insert(dir.clone());
                }
                Err(e) => debug!(error = %e, dir = %dir.display(), "repo docs: cannot watch"),
            }
        }
    }
}

// ── detail ────────────────────────────────────────────────────────────────────

fn unknown_item() -> WorkError {
    WorkError::new("unknown_item", "That doc no longer exists")
}

fn detail_blocking(root: &Path, item_id: &str) -> Result<WorkDetail, WorkError> {
    let root = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let rest = item_id.strip_prefix("doc:").ok_or_else(unknown_item)?;
    let (repo, rel) = rest.split_once(':').ok_or_else(unknown_item)?;
    if repo.is_empty() || repo.starts_with('.') || repo.contains(['/', '\\', '\0']) || rel.contains(['\\', '\0']) {
        return Err(unknown_item());
    }
    let parts: Vec<&str> = rel.split('/').collect();
    if parts.iter().any(|p| p.is_empty() || *p == "." || *p == "..") {
        return Err(unknown_item());
    }
    let (kind, is_wip) = kind_of_rel(&parts).ok_or_else(unknown_item)?;

    let claude = root.join(repo).join(".claude");
    let path = claude.join(rel);
    // Whatever the id says, never read outside the repo's `.claude/`.
    let real_claude = fs::canonicalize(&claude).map_err(|_| unknown_item())?;
    let real_path = fs::canonicalize(&path).map_err(|_| unknown_item())?;
    if !real_path.starts_with(&real_claude) {
        return Err(unknown_item());
    }

    let name = parts[parts.len() - 1];
    let meta = fs::metadata(&path).map_err(|_| unknown_item())?;
    let (text, index_meta) = if is_wip {
        if !meta.is_dir() {
            return Err(unknown_item());
        }
        let index = path.join("index.md");
        match fs::metadata(&index) {
            Ok(m) if m.is_file() => (read_detail_text(&index).unwrap_or_default(), Some(m)),
            _ => (String::new(), None),
        }
    } else {
        if !meta.is_file() {
            return Err(unknown_item());
        }
        (read_detail_text(&path).ok_or_else(unknown_item)?, None)
    };
    let item = build_item(repo, kind, rel, &path, &text, index_meta.as_ref().unwrap_or(&meta), name);

    let fields = detail_fields(&item, kind, repo, rel);

    let files = if is_wip { wip_files(&path) } else { Vec::new() };
    let link = url::Url::from_file_path(&path).ok().map(|u| Link {
        label: if is_wip { "Open folder".to_string() } else { "Open file".to_string() },
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
            value.push_str(" (from the file's date)");
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
    DOC_DIRS.iter().find(|(d, _)| *d == dir).map(|(_, kind)| (*kind, false))
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
fn read_detail_text(path: &Path) -> Option<String> {
    let mut text = read_text(path, MAX_DETAIL + 1)?;
    if text.len() as u64 > MAX_DETAIL {
        let mut cut = MAX_DETAIL as usize;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        text.truncate(cut);
        text.push_str("\n\n… (truncated: the file is longer than 1 MiB)\n");
    }
    Some(text)
}

/// Absolute paths of a wip folder's other files (not `index.md`, not hidden), sorted.
fn wip_files(dir: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else { return Vec::new() };
    let mut files: Vec<String> = entries
        .flatten()
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            !name.starts_with('.') && name != "index.md" && fs::metadata(e.path()).is_ok_and(|m| m.is_file())
        })
        .map(|e| e.path().to_string_lossy().into_owned())
        .collect();
    files.sort();
    files.truncate(MAX_WIP_FILES);
    files
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
        assert_eq!(parse("# T\n**Severity:** high\n").severity.as_deref(), Some("high"));
        assert_eq!(parse("# T\n**severity:**   Medium  \n").severity.as_deref(), Some("Medium"));
        assert_eq!(parse("# T\nNothing about it here\n").severity, None);
        assert_eq!(parse("# T\n**Severity:**\n").severity, None, "an empty value states nothing");
    }

    #[test]
    fn front_matter_wins_over_the_body_for_severity() {
        assert_eq!(parse("---\nSeverity: \"high\"\n---\n**Severity:** low\n").severity.as_deref(), Some("high"));
    }

    #[test]
    fn priority_maps_p1_to_p5_and_keeps_other_words() {
        assert_eq!(priority_from("P2"), Priority { label: "P2".into(), rank: 2 });
        assert_eq!(priority_from("p4 (nice to have)"), Priority { label: "P4".into(), rank: 4 });
        assert_eq!(priority_from("urgent"), Priority { label: "urgent".into(), rank: 9 });
        assert_eq!(priority_from("P7"), Priority { label: "P7".into(), rank: 9 });
        assert_eq!(parse("# T\n**Priority:** P1\n").priority, Some(Priority { label: "P1".into(), rank: 1 }));
    }

    #[test]
    fn dates_come_from_the_name_prefix_only_when_it_is_a_whole_date() {
        assert_eq!(prefix_date("2026-10-01-slug.md"), NaiveDate::from_ymd_opt(2026, 10, 1));
        assert_eq!(prefix_date("2026-10-01.md"), NaiveDate::from_ymd_opt(2026, 10, 1));
        assert_eq!(prefix_date("2026-10-011-slug.md"), None);
        assert_eq!(prefix_date("slug.md"), None);
        assert_eq!(prefix_date("é2026-10-01-x.md"), None);
    }

    #[test]
    fn slugs_are_humanised_without_their_date() {
        assert_eq!(humanize_slug("2026-10-01-login-fails_badly.md"), "Login fails badly");
        assert_eq!(humanize_slug("callimachus-notes.md"), "Callimachus notes");
        assert_eq!(humanize_slug("2026-10-01.md"), "2026-10-01");
    }

    #[test]
    fn search_text_is_capped_on_a_character_boundary() {
        let body = "é".repeat(SEARCH_TEXT_CAP);
        let text = search_text("Title", &body);
        assert!(text.len() <= SEARCH_TEXT_CAP);
        assert!(text.starts_with("Title\n"));
    }

    #[test]
    fn unterminated_front_matter_is_not_front_matter() {
        let (front, body) = split_front_matter("---\nseverity: high\n# Title\n");
        assert_eq!(front, None);
        assert!(body.starts_with("---"));
    }
}
