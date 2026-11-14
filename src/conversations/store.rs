//! The conversation history file and its in-memory handle.

use super::first_prompt::{self, FirstPrompt, Reason};
use super::now_ms;
use crate::mother::origin::{load_json_checked, write_private};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// Entries not active for this long are dropped on write (90 days).
pub const MAX_AGE_MS: i64 = 90 * 24 * 60 * 60 * 1000;
/// Most visible entries kept; the oldest last-active go first.
pub const MAX_VISIBLE: usize = 500;
/// A soft-removed entry (undo window) older than this is purged on write.
pub const REMOVED_GRACE_MS: i64 = 10 * 60 * 1000;
/// An entry that never had a turn (spawned, never typed into) is dropped after this.
const HIDDEN_MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// Most PR numbers kept per entry (newest kept).
const MAX_PRS: usize = 8;

/// One conversation, keyed by Claude session id.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConversationEntry {
    pub sid: String,
    /// The focus tag that owns the conversation now.
    pub tag: String,
    pub agent: String,
    pub title: String,
    #[serde(default)]
    pub label: Option<String>,
    /// The working directory it was spawned with.
    #[serde(default)]
    pub project_path: Option<String>,
    /// Set when `project_path` is a linked git worktree (plan 2 uses it).
    #[serde(default)]
    pub main_checkout: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub pr_numbers: Vec<u32>,
    #[serde(default)]
    pub first_prompt: FirstPrompt,
    /// Sticky: once true, never false.
    #[serde(default)]
    pub sensitive: bool,
    pub created_ms: i64,
    pub last_active_ms: i64,
    /// Visible only once the user has typed into it.
    #[serde(default)]
    pub has_turn: bool,
    #[serde(default)]
    pub transcript_path: Option<PathBuf>,
    /// How far into the transcript the last tail read got (a byte offset).
    #[serde(default)]
    pub tail_offset: u64,
    #[serde(default)]
    pub resumed_from_tag: Option<String>,
    #[serde(default)]
    pub removed_at_ms: Option<i64>,
    /// Plan 2's rename; unused here.
    #[serde(default)]
    pub user_title: Option<String>,
}

impl ConversationEntry {
    /// A hidden entry with nothing known but who owns it.
    pub fn new(sid: &str, tag: &str, agent: &str, title: &str, now: i64) -> Self {
        Self {
            sid: sid.to_owned(),
            tag: tag.to_owned(),
            agent: agent.to_owned(),
            title: title.to_owned(),
            label: None,
            project_path: None,
            main_checkout: None,
            branch: None,
            model: None,
            effort: None,
            pr_numbers: Vec::new(),
            first_prompt: FirstPrompt::None,
            sensitive: false,
            created_ms: now,
            last_active_ms: now,
            has_turn: false,
            transcript_path: None,
            tail_offset: 0,
            resumed_from_tag: None,
            removed_at_ms: None,
            user_title: None,
        }
    }

    /// Show the entry in the list (it has had a conversation).
    pub fn make_visible(&mut self) {
        self.has_turn = true;
    }

    fn visible(&self) -> bool {
        self.has_turn && self.removed_at_ms.is_none()
    }

    /// Sticky sensitivity: the branch and any stored prompt text go.
    fn mark_sensitive(&mut self) {
        self.sensitive = true;
        self.branch = None;
        if matches!(self.first_prompt, FirstPrompt::Text(_)) {
            self.first_prompt = FirstPrompt::Withheld(Reason::SensitiveConversation);
        }
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct FileData {
    #[serde(default)]
    backfilled: bool,
    #[serde(default = "yes")]
    first_prompts_enabled: bool,
    #[serde(default)]
    entries: Vec<ConversationEntry>,
}

fn yes() -> bool {
    true
}

impl Default for FileData {
    fn default() -> Self {
        Self {
            backfilled: false,
            first_prompts_enabled: true,
            entries: Vec::new(),
        }
    }
}

/// A spawn to note (`SessionManager::spawn_session`).
pub struct SpawnNote<'a> {
    pub tag: &'a str,
    pub sid: &'a str,
    pub agent: &'a str,
    pub cwd: Option<&'a Path>,
    pub title: &'a str,
    pub label: Option<&'a str>,
    pub model: Option<(&'a str, Option<&'a str>)>,
}

/// What a turn or a send refreshes about an entry.
#[derive(Default)]
pub struct MetaUpdate {
    pub title: Option<String>,
    pub label: Option<String>,
    pub model: Option<(String, Option<String>)>,
    pub sensitive: bool,
}

/// A cached look at a transcript file (never a read on the list path).
#[derive(Debug, Clone, Copy)]
pub struct FileVerdict {
    pub size: u64,
    pub mtime_ms: i64,
    pub unreadable: bool,
}

/// What `snapshot` returns.
pub struct Snapshot {
    pub entries: Vec<ConversationEntry>,
    pub first_prompts_enabled: bool,
    pub degraded_kept: Option<u32>,
    pub revision: u64,
    pub removed_pending: usize,
}

struct State {
    path: Option<PathBuf>,
    data: FileData,
    degraded: Option<u32>,
    revision: u64,
    verdicts: HashMap<String, FileVerdict>,
    /// Entries a background locate already failed for this run.
    not_found: HashSet<String>,
}

/// The conversation history; cheap to clone, clones share it.
#[derive(Clone)]
pub struct ConversationHistory {
    inner: Arc<Mutex<State>>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl ConversationHistory {
    /// `conversation-history.json` beside the session id store.
    pub fn path_beside(store_path: &Path) -> PathBuf {
        store_path.with_file_name("conversation-history.json")
    }

    /// The history at `path`. An unreadable file is kept as a `.bak` (by
    /// `load_json_checked`), the history starts empty and degraded, and
    /// nothing is written this run.
    pub fn open(path: PathBuf) -> Self {
        let existed = path.exists();
        let (data, ok): (FileData, bool) = load_json_checked(&path);
        let degraded = (existed && !ok).then(|| kept_in_backup(&path));
        Self::from_parts(Some(path), data, degraded)
    }

    /// A history that is never written to disk.
    pub fn in_memory() -> Self {
        Self::from_parts(None, FileData::default(), None)
    }

    fn from_parts(path: Option<PathBuf>, data: FileData, degraded: Option<u32>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(State {
                path,
                data,
                degraded,
                revision: 0,
                verdicts: HashMap::new(),
                not_found: HashSet::new(),
            })),
        }
    }

    /// Has the one-time backfill from the session-id history run?
    pub fn backfilled(&self) -> bool {
        lock(&self.inner).data.backfilled
    }

    /// Does the history file exist (or is it degraded)? A first start has none.
    pub fn file_exists(&self) -> bool {
        let s = lock(&self.inner);
        s.degraded.is_some() || s.path.as_ref().is_some_and(|p| p.exists())
    }

    pub fn revision(&self) -> u64 {
        lock(&self.inner).revision
    }

    pub fn first_prompts_enabled(&self) -> bool {
        lock(&self.inner).data.first_prompts_enabled
    }

    /// A spawn: creates the entry hidden, or refreshes `tag`/`project_path`.
    pub fn note_spawn(&self, n: SpawnNote<'_>, now: i64) {
        let mut s = lock(&self.inner);
        let cwd = n.cwd.map(|p| p.to_string_lossy().into_owned());
        if let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == n.sid) {
            e.tag = n.tag.to_owned();
            e.agent = n.agent.to_owned();
            if cwd.is_some() {
                e.main_checkout = cwd.as_deref().and_then(main_checkout_of);
                e.project_path = cwd;
            }
        } else {
            let main_checkout = cwd.as_deref().and_then(main_checkout_of);
            let mut entry = ConversationEntry::new(n.sid, n.tag, n.agent, n.title, now);
            entry.label = n.label.map(str::to_owned);
            entry.project_path = cwd;
            entry.main_checkout = main_checkout;
            entry.model = n.model.map(|(m, _)| m.to_owned());
            entry.effort = n.model.and_then(|(_, e)| e.map(str::to_owned));
            s.data.entries.push(entry);
        }
        s.persist(now);
    }

    /// A user message was sent into `sid`: the first one makes the entry
    /// visible and derives the first prompt; later ones only bump the time.
    pub fn note_user_send(&self, sid: &str, text: &str, has_images: bool, sensitive: bool, now: i64) {
        let mut s = lock(&self.inner);
        let enabled = s.data.first_prompts_enabled;
        let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) else {
            return;
        };
        if sensitive && !e.sensitive {
            e.mark_sensitive();
        }
        e.last_active_ms = now;
        if !e.has_turn {
            e.has_turn = true;
            e.first_prompt = first_prompt::derive(text, has_images, e.sensitive, enabled);
        }
        s.persist(now);
    }

    /// A turn completed in `sid`.
    pub fn turn_completed(&self, sid: &str, now: i64) {
        let mut s = lock(&self.inner);
        if let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) {
            e.last_active_ms = now;
            s.persist(now);
        }
    }

    /// Refresh title, label, model and sensitivity from the live focus.
    pub fn refresh_meta(&self, sid: &str, m: MetaUpdate, now: i64) {
        let mut s = lock(&self.inner);
        let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) else {
            return;
        };
        let before = e.clone();
        if let Some(t) = m.title.filter(|t| !t.is_empty()) {
            e.title = t;
        }
        if m.label.is_some() {
            e.label = m.label;
        }
        if let Some((model, effort)) = m.model {
            e.model = Some(model);
            e.effort = effort;
        }
        if m.sensitive && !e.sensitive {
            e.mark_sensitive();
        }
        if *e != before {
            s.persist(now);
        }
    }

    /// Record what a bounded tail read of the transcript found.
    pub fn apply_tail(
        &self,
        sid: &str,
        path: &Path,
        new_offset: u64,
        branch: Option<String>,
        prs: &[u32],
        now: i64,
    ) {
        let mut s = lock(&self.inner);
        let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) else {
            return;
        };
        e.transcript_path = Some(path.to_path_buf());
        e.tail_offset = new_offset;
        if !e.sensitive {
            if let Some(b) = branch {
                e.branch = Some(b);
            }
            for p in prs {
                if !e.pr_numbers.contains(p) {
                    e.pr_numbers.push(*p);
                }
            }
            let excess = e.pr_numbers.len().saturating_sub(MAX_PRS);
            e.pr_numbers.drain(..excess);
        }
        s.persist(now);
    }

    /// Cache where the transcript was found.
    pub fn set_transcript_path(&self, sid: &str, path: &Path) {
        let mut s = lock(&self.inner);
        if let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) {
            e.transcript_path = Some(path.to_path_buf());
            s.not_found.remove(sid);
            s.persist(now_ms());
        }
    }

    pub fn note_not_found(&self, sid: &str) {
        let mut s = lock(&self.inner);
        s.not_found.insert(sid.to_owned());
        s.revision += 1;
    }

    pub fn was_not_found(&self, sid: &str) -> bool {
        lock(&self.inner).not_found.contains(sid)
    }

    pub fn verdict(&self, sid: &str) -> Option<FileVerdict> {
        lock(&self.inner).verdicts.get(sid).copied()
    }

    pub fn set_verdict(&self, sid: &str, v: FileVerdict) {
        let mut s = lock(&self.inner);
        s.verdicts.insert(sid.to_owned(), v);
        s.revision += 1;
    }

    pub fn get(&self, sid: &str) -> Option<ConversationEntry> {
        lock(&self.inner).data.entries.iter().find(|e| e.sid == sid).cloned()
    }

    /// Every entry the user can see (typed into, not removed), plus the flags.
    pub fn snapshot(&self) -> Snapshot {
        let s = lock(&self.inner);
        Snapshot {
            entries: s.data.entries.iter().filter(|e| e.visible()).cloned().collect(),
            first_prompts_enabled: s.data.first_prompts_enabled,
            degraded_kept: s.degraded,
            revision: s.revision,
            removed_pending: s.data.entries.iter().filter(|e| e.removed_at_ms.is_some()).count(),
        }
    }

    /// Soft-remove (undoable for the sheet's lifetime). False if unknown.
    pub fn remove(&self, sid: &str, now: i64) -> bool {
        self.mutate_one(sid, now, |e| e.removed_at_ms = Some(now))
    }

    /// Undo a soft removal.
    pub fn restore(&self, sid: &str, now: i64) -> bool {
        self.mutate_one(sid, now, |e| e.removed_at_ms = None)
    }

    /// Delete soft-removed entries now (the sheet closed).
    pub fn purge_removed(&self, now: i64) {
        let mut s = lock(&self.inner);
        let before = s.data.entries.len();
        s.data.entries.retain(|e| e.removed_at_ms.is_none());
        if s.data.entries.len() != before {
            s.persist(now);
        }
    }

    /// Turn first prompts on or off. Off purges every stored text at once.
    pub fn set_first_prompts_enabled(&self, enabled: bool, now: i64) {
        let mut s = lock(&self.inner);
        s.data.first_prompts_enabled = enabled;
        if !enabled {
            for e in &mut s.data.entries {
                if matches!(e.first_prompt, FirstPrompt::Text(_)) {
                    e.first_prompt = FirstPrompt::Withheld(Reason::Off);
                }
            }
        }
        s.persist(now);
    }

    /// Hand the conversation to `new_tag` (a resume). Returns the old tag.
    pub fn move_to_tag(&self, sid: &str, new_tag: &str, now: i64) -> Option<String> {
        let mut s = lock(&self.inner);
        let e = s.data.entries.iter_mut().find(|e| e.sid == sid)?;
        let old = std::mem::replace(&mut e.tag, new_tag.to_owned());
        e.resumed_from_tag = Some(old.clone());
        s.persist(now);
        Some(old)
    }

    /// Undo [`Self::move_to_tag`] (the resume could not open the conversation).
    pub fn restore_tag(&self, sid: &str, old_tag: &str, now: i64) {
        self.mutate_one(sid, now, |e| {
            e.tag = old_tag.to_owned();
            e.resumed_from_tag = None;
        });
    }

    /// Add entries found by the one-time backfill (existing sids are kept),
    /// and mark the file backfilled.
    pub fn finish_backfill(&self, found: Vec<ConversationEntry>, now: i64) {
        let mut s = lock(&self.inner);
        for e in found {
            if !s.data.entries.iter().any(|x| x.sid == e.sid) {
                s.data.entries.push(e);
            }
        }
        s.data.backfilled = true;
        s.persist(now);
    }

    /// Counts only, for "Copy daemon diagnostics".
    pub fn counts(&self) -> (usize, usize, bool) {
        let s = lock(&self.inner);
        (
            s.data.entries.iter().filter(|e| e.visible()).count(),
            s.data.entries.iter().filter(|e| e.removed_at_ms.is_some()).count(),
            s.degraded.is_some(),
        )
    }

    fn mutate_one(&self, sid: &str, now: i64, f: impl FnOnce(&mut ConversationEntry)) -> bool {
        let mut s = lock(&self.inner);
        let Some(e) = s.data.entries.iter_mut().find(|e| e.sid == sid) else {
            return false;
        };
        f(e);
        s.persist(now);
        true
    }
}

impl State {
    /// Apply retention, bump the revision and write the file (unless degraded).
    fn persist(&mut self, now: i64) {
        self.revision += 1;
        prune(&mut self.data.entries, now);
        if self.degraded.is_some() {
            return;
        }
        if let Some(path) = &self.path {
            if write_private(path, &self.data).is_err() {
                tracing::warn!("conversation history could not be written");
            }
        }
    }
}

fn prune(entries: &mut Vec<ConversationEntry>, now: i64) {
    entries.retain(|e| {
        if now - e.last_active_ms > MAX_AGE_MS {
            return false;
        }
        if !e.has_turn && now - e.last_active_ms > HIDDEN_MAX_AGE_MS {
            return false;
        }
        e.removed_at_ms.is_none_or(|at| now - at <= REMOVED_GRACE_MS)
    });
    let mut visible: Vec<(i64, usize)> = entries
        .iter()
        .enumerate()
        .filter(|(_, e)| e.visible())
        .map(|(i, e)| (e.last_active_ms, i))
        .collect();
    if visible.len() > MAX_VISIBLE {
        // Oldest last-active first.
        visible.sort();
        let drop: HashSet<usize> = visible[..visible.len() - MAX_VISIBLE]
            .iter()
            .map(|(_, i)| *i)
            .collect();
        let mut i = 0;
        entries.retain(|_| {
            let keep = !drop.contains(&i);
            i += 1;
            keep
        });
    }
}

/// How many entries the `.bak` beside an unreadable file holds (0 if none or unreadable).
fn kept_in_backup(path: &Path) -> u32 {
    let Some(name) = path.file_name() else {
        return 0;
    };
    let bak = path.with_file_name(format!("{}.bak", name.to_string_lossy()));
    std::fs::read(bak)
        .ok()
        .and_then(|b| serde_json::from_slice::<FileData>(&b).ok())
        .map_or(0, |d| d.entries.len() as u32)
}

/// When `cwd` is a linked git worktree (`.git` is a file reading
/// `gitdir: <main>/.git/worktrees/<name>`), the main checkout.
pub fn main_checkout_of(cwd: &str) -> Option<String> {
    let text = std::fs::read_to_string(Path::new(cwd).join(".git")).ok()?;
    let gitdir = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
    let main_git = Path::new(gitdir).parent()?.parent()?;
    (main_git.file_name()? == ".git").then(|| main_git.parent().map(|p| p.to_string_lossy().into_owned()))?
}
