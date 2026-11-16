//! The opt-in index of conversations started outside Nostromo: `claude` typed
//! into a terminal (a tmux pane), found under `~/.claude/projects`.
//!
//! Only when the user turned "Include conversations started outside Nostromo"
//! on. What counts (verified against CLI 2.1.325, see the PR): a top-level
//! `*.jsonl` whose records say `entrypoint: "cli"`. `claude -p`, stream-json
//! and Agent SDK runs, and so every Mother job, say `sdk-cli`; a subagent's
//! thread is in a subfolder or marked `isSidechain`. A working directory under
//! `~/.mother` is refused too, whatever the entrypoint.
//!
//! Bounds: at most the first 512 KiB and the last 256 KiB of a file are read,
//! only for a file that is new or changed (path, size, mtime); a file that is
//! not a terminal conversation is remembered (in memory) so it is not read
//! again. The index is written 0600 and holds the history's allowed fields only.
//!
//! Nothing here is logged (counts only), sent to a network or non-operator
//! peer, or reachable by an MCP tool.

use super::backfill::fill_with_head;
use super::first_prompt::{FirstPrompt, Reason};
use super::store::{ConversationEntry, MAX_VISIBLE};
use super::transcript;
use crate::mother::origin::{load_json_checked, write_private};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// Only files modified this recently are looked at.
pub const MAX_AGE_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// The index keeps this many (the history's visible cap).
pub const MAX_INDEXED: usize = MAX_VISIBLE;
/// The `entrypoint` of a conversation a person typed into `claude`.
pub const TERMINAL_ENTRYPOINT: &str = "cli";

/// The index file beside the conversation history.
pub fn path_beside(store_path: &Path) -> PathBuf {
    store_path.with_file_name("outside-conversations.json")
}

/// One indexed conversation. The history's allowed fields, nothing else.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Indexed {
    pub sid: String,
    /// The `agentName` Claude recorded, if any.
    #[serde(default)]
    pub agent: Option<String>,
    pub title: String,
    #[serde(default)]
    pub project_path: Option<String>,
    #[serde(default)]
    pub main_checkout: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub pr_numbers: Vec<u32>,
    #[serde(default)]
    pub first_prompt: FirstPrompt,
    #[serde(default)]
    pub sensitive: bool,
    pub last_active_ms: i64,
    pub transcript_path: PathBuf,
    /// The file as it was when read (the cache key with its path).
    pub size: u64,
    pub mtime_ms: i64,
}

impl Indexed {
    /// As a history entry owned by no focus: how the list and a resume see it.
    pub fn to_entry(&self, agent: &str) -> ConversationEntry {
        let mut e = ConversationEntry::new(&self.sid, "", agent, &self.title, self.last_active_ms);
        e.make_visible();
        e.project_path = self.project_path.clone();
        e.main_checkout = self.main_checkout.clone();
        e.branch = self.branch.clone();
        e.model = self.model.clone();
        e.pr_numbers = self.pr_numbers.clone();
        e.first_prompt = self.first_prompt.clone();
        e.sensitive = self.sensitive;
        e.transcript_path = Some(self.transcript_path.clone());
        e
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct FileData {
    #[serde(default)]
    entries: Vec<Indexed>,
}

struct State {
    path: Option<PathBuf>,
    entries: Vec<Indexed>,
    /// A scan finished since the switch was turned on (or the file was loaded).
    ready: bool,
    running: bool,
    /// Files read and found not to be terminal conversations (memory only).
    rejected: HashMap<PathBuf, (u64, i64)>,
}

/// The index; cheap to clone, clones share it.
#[derive(Clone)]
pub struct OutsideIndex {
    inner: Arc<Mutex<State>>,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// What a scan needs from the daemon.
pub struct ScanEnv<'a> {
    pub projects_dir: &'a Path,
    /// Session ids the history already holds (never indexed twice).
    pub known: &'a HashSet<String>,
    pub first_prompts_enabled: bool,
    /// Is a conversation of this agent sensitive? (Fails closed when the
    /// registry is unreadable.)
    pub is_sensitive: &'a dyn Fn(Option<&str>) -> bool,
    pub now_ms: i64,
}

impl OutsideIndex {
    /// The index stored at `path`, loaded now (an unreadable file is ignored).
    pub fn open(path: PathBuf) -> Self {
        let (data, ok): (FileData, bool) = load_json_checked(&path);
        let had = ok && path.exists();
        Self::from_parts(Some(path), data.entries, had)
    }

    /// An index never written to disk.
    pub fn in_memory() -> Self {
        Self::from_parts(None, Vec::new(), false)
    }

    fn from_parts(path: Option<PathBuf>, entries: Vec<Indexed>, ready: bool) -> Self {
        Self {
            inner: Arc::new(Mutex::new(State {
                path,
                entries,
                ready,
                running: false,
                rejected: HashMap::new(),
            })),
        }
    }

    /// Has a scan finished (or a saved index been loaded)?
    pub fn ready(&self) -> bool {
        lock(&self.inner).ready
    }

    /// The indexed conversations, newest first.
    pub fn entries(&self) -> Vec<Indexed> {
        lock(&self.inner).entries.clone()
    }

    pub fn get(&self, sid: &str) -> Option<Indexed> {
        lock(&self.inner)
            .entries
            .iter()
            .find(|e| e.sid == sid)
            .cloned()
    }

    pub fn len(&self) -> usize {
        lock(&self.inner).entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Claim the right to run a scan; false while one runs.
    pub fn try_begin(&self) -> bool {
        let mut s = lock(&self.inner);
        if s.running {
            return false;
        }
        s.running = true;
        true
    }

    /// Scan now (blocking: run on its own thread, never under a lock) and
    /// store the result. The caller holds the claim from [`Self::try_begin`].
    pub fn scan_and_store(&self, env: &ScanEnv<'_>) {
        let (previous, rejected) = {
            let s = lock(&self.inner);
            (s.entries.clone(), s.rejected.clone())
        };
        let (entries, rejected) = scan(env, previous, rejected);
        let mut s = lock(&self.inner);
        s.entries = entries;
        s.rejected = rejected;
        s.ready = true;
        s.running = false;
        if let Some(path) = &s.path {
            if write_private(path, &FileData { entries: s.entries.clone() }).is_err() {
                tracing::warn!("outside conversation index could not be written");
            }
        }
    }

    /// The switch went off: forget everything and delete the file now.
    pub fn clear(&self) {
        let mut s = lock(&self.inner);
        s.entries.clear();
        s.rejected.clear();
        s.ready = false;
        if let Some(path) = &s.path {
            let _ = std::fs::remove_file(path);
        }
    }

    /// First prompts went off: drop every stored text (and rewrite the file).
    pub fn withhold_first_prompts(&self) {
        let mut s = lock(&self.inner);
        for e in &mut s.entries {
            if matches!(e.first_prompt, FirstPrompt::Text(_)) {
                e.first_prompt = FirstPrompt::Withheld(Reason::Off);
            }
        }
        if let Some(path) = &s.path {
            if path.exists() {
                let _ = write_private(path, &FileData { entries: s.entries.clone() });
            }
        }
    }
}

/// One candidate transcript.
struct Candidate {
    path: PathBuf,
    sid: String,
    size: u64,
    mtime_ms: i64,
}

fn valid_sid(stem: &str) -> bool {
    !stem.is_empty()
        && stem.len() <= 64
        && stem
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Top-level `*.jsonl` files under `projects_dir/*/` modified in the window,
/// newest first. Subfolders (subagent threads) and symlinks are never entered.
fn candidates(env: &ScanEnv<'_>) -> Vec<Candidate> {
    let mut out = Vec::new();
    let Ok(dirs) = std::fs::read_dir(env.projects_dir) else {
        return out;
    };
    for dir in dirs.flatten() {
        if !dir.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let Ok(files) = std::fs::read_dir(dir.path()) else {
            continue;
        };
        for f in files.flatten() {
            let path = f.path();
            let Some(sid) = path
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_suffix(".jsonl"))
                .filter(|s| valid_sid(s))
                .map(str::to_owned)
            else {
                continue;
            };
            if env.known.contains(&sid) || !f.file_type().is_ok_and(|t| t.is_file()) {
                continue;
            }
            let Ok(meta) = f.metadata() else { continue };
            let mtime_ms = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_millis() as i64);
            if meta.len() == 0 || env.now_ms - mtime_ms > MAX_AGE_MS {
                continue;
            }
            out.push(Candidate {
                path,
                sid,
                size: meta.len(),
                mtime_ms,
            });
        }
    }
    out.sort_by_key(|c| std::cmp::Reverse(c.mtime_ms));
    out
}

type Rejected = HashMap<PathBuf, (u64, i64)>;

fn scan(
    env: &ScanEnv<'_>,
    previous: Vec<Indexed>,
    rejected: Rejected,
) -> (Vec<Indexed>, Rejected) {
    let cache: HashMap<PathBuf, Indexed> = previous
        .into_iter()
        .map(|e| (e.transcript_path.clone(), e))
        .collect();
    let mut found: Vec<Indexed> = Vec::new();
    let mut now_rejected = Rejected::new();
    for c in candidates(env) {
        if found.len() >= MAX_INDEXED {
            break;
        }
        let key = (c.size, c.mtime_ms);
        if let Some(e) = cache.get(&c.path).filter(|e| (e.size, e.mtime_ms) == key) {
            found.push(e.clone());
            continue;
        }
        if rejected.get(&c.path) == Some(&key) {
            now_rejected.insert(c.path, key);
            continue;
        }
        match index_file(env, &c) {
            Some(e) => found.push(e),
            None => {
                now_rejected.insert(c.path, key);
            }
        }
    }
    found.sort_by_key(|e| std::cmp::Reverse(e.last_active_ms));
    (found, now_rejected)
}

/// Is this a conversation a person typed into `claude` in a terminal? The
/// discriminators, each tested on its own.
fn is_terminal_conversation(head: &transcript::Facts) -> bool {
    head.entrypoint.as_deref() == Some(TERMINAL_ENTRYPOINT)
        && !head.sidechain
        && !head.cwd.as_deref().is_some_and(is_mother_cwd)
}

/// A working directory inside Mother's own tree (`~/.mother/...`).
fn is_mother_cwd(cwd: &str) -> bool {
    Path::new(cwd)
        .components()
        .any(|c| c.as_os_str() == ".mother")
}

fn index_file(env: &ScanEnv<'_>, c: &Candidate) -> Option<Indexed> {
    let head_bytes = transcript::read_head(&c.path).ok()?;
    let head = transcript::scan(&head_bytes);
    if !is_terminal_conversation(&head) {
        return None;
    }
    let agent = head.agent_name.clone();
    let sensitive = (env.is_sensitive)(agent.as_deref());
    let title = agent.clone().unwrap_or_else(|| "claude".to_owned());
    let mut e = ConversationEntry::new(&c.sid, "", agent.as_deref().unwrap_or(""), &title, env.now_ms);
    e.sensitive = sensitive;
    e.last_active_ms = c.mtime_ms;
    e.transcript_path = Some(c.path.clone());
    fill_with_head(&mut e, &c.path, head, env.first_prompts_enabled);
    if sensitive {
        e.branch = None;
        if matches!(e.first_prompt, FirstPrompt::Text(_)) {
            e.first_prompt = FirstPrompt::Withheld(Reason::SensitiveConversation);
        }
    }
    Some(Indexed {
        sid: e.sid,
        agent,
        title: e.title,
        project_path: e.project_path,
        main_checkout: e.main_checkout,
        branch: e.branch,
        model: e.model,
        pr_numbers: e.pr_numbers,
        first_prompt: e.first_prompt,
        sensitive,
        last_active_ms: e.last_active_ms,
        transcript_path: c.path.clone(),
        size: c.size,
        mtime_ms: c.mtime_ms,
    })
}

/// Test seam: overrides `~/.claude/agents`.
pub const AGENTS_DIR_ENV: &str = "NOSTROMO_CLAUDE_AGENTS_DIR";

/// Does `~/.claude/agents/<name>.md` exist? (Names are plain words only.)
pub fn agent_exists(name: &str) -> bool {
    let dir = std::env::var_os(AGENTS_DIR_ENV)
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| dirs_next::home_dir().map(|h| h.join(".claude").join("agents")));
    dir.is_some_and(|d| agent_exists_in(&d, name))
}

/// [`agent_exists`] for an explicit agents folder.
pub fn agent_exists_in(agents_dir: &Path, name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        && agents_dir.join(format!("{name}.md")).is_file()
}
