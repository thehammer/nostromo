//! A focus session's working copy (repo and branch), by reading files.
//!
//! The session's live directory comes from the tail of its Claude transcript
//! (`~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, every entry of
//! which carries `cwd`); the repo and branch come from `.git` files. **No git
//! process is ever run** (no hooks, no fsmonitor, no spawned process): this
//! module reads files and nothing else.
//!
//! Limits, stated plainly because the answer is only ever a hint labelled
//! `on_branch`: a session that works in another checkout with `git -C` or
//! absolute paths and never `cd`s there is not seen, and two focuses on one
//! checkout and branch are ambiguous.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use tokio::time::Instant;

use super::ownership::WorkingCopy;
use super::snapshot::safe_segment;

/// How much of a transcript's end is read.
pub const TAIL_BYTES: u64 = 64 * 1024;
/// A focus's working copy is looked at most this often.
pub const REFRESH_EVERY: Duration = Duration::from_secs(30);
/// At most this many focuses are looked at per round.
pub const MAX_FOCUSES: usize = 64;
const MAX_WALK: usize = 64;

/// Find `<projects_root>/*/<session_id>.jsonl`.
pub fn find_transcript(projects_root: &Path, session_id: &str) -> Option<PathBuf> {
    if session_id.is_empty()
        || !session_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return None;
    }
    let file = format!("{session_id}.jsonl");
    for entry in std::fs::read_dir(projects_root).ok()?.flatten() {
        let candidate = entry.path().join(&file);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// The last line of `transcript`'s final 64 KiB whose JSON has a string `cwd`
/// that is an absolute, existing directory.
pub fn last_cwd(transcript: &Path) -> Option<PathBuf> {
    let mut file = std::fs::File::open(transcript).ok()?;
    let len = file.metadata().ok()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut buf = Vec::with_capacity((len - start) as usize);
    file.take(TAIL_BYTES).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    let mut lines = text.lines();
    // A tail that starts mid-file begins inside a line: drop that fragment.
    if start > 0 {
        lines.next();
    }
    let mut found = None;
    for line in lines {
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        if let Some(cwd) = v.get("cwd").and_then(|c| c.as_str()) {
            let p = PathBuf::from(cwd);
            if p.is_absolute() && p.is_dir() {
                found = Some(p);
            }
        }
    }
    found
}

/// `owner/name` (lowercased) from a GitHub remote URL: `https://github.com/o/n(.git)`,
/// `git@github.com:o/n(.git)` or `ssh://git@github.com/o/n(.git)`. Anything else is `None`.
pub fn parse_remote_url(url: &str) -> Option<String> {
    let url = url.trim();
    let path = url
        .strip_prefix("https://github.com/")
        .or_else(|| url.strip_prefix("git@github.com:"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))?;
    let path = path.trim_end_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    let (owner, name) = path.split_once('/')?;
    if name.contains('/') || !safe_segment(owner) || !safe_segment(name) {
        return None;
    }
    Some(format!(
        "{}/{}",
        owner.to_ascii_lowercase(),
        name.to_ascii_lowercase()
    ))
}

/// The `url` of `[remote "origin"]` in a git config's text.
fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_origin = l.replace(' ', "").eq_ignore_ascii_case("[remote\"origin\"]");
        } else if in_origin {
            if let Some((k, v)) = l.split_once('=') {
                if k.trim().eq_ignore_ascii_case("url") {
                    return Some(v.trim().to_owned());
                }
            }
        }
    }
    None
}

/// Walk up from `cwd` to a `.git` directory or `.git` file and return
/// `(gitdir, common_dir)`.
fn find_git(cwd: &Path) -> Option<(PathBuf, PathBuf)> {
    let mut dir = cwd.to_path_buf();
    for _ in 0..MAX_WALK {
        let dotgit = dir.join(".git");
        if dotgit.is_dir() {
            return Some((dotgit.clone(), dotgit));
        }
        if dotgit.is_file() {
            let text = std::fs::read_to_string(&dotgit).ok()?;
            let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
            let gitdir = {
                let p = PathBuf::from(target);
                if p.is_absolute() {
                    p
                } else {
                    dir.join(p)
                }
            };
            let common = match std::fs::read_to_string(gitdir.join("commondir")) {
                Ok(c) => {
                    let p = PathBuf::from(c.trim());
                    if p.is_absolute() {
                        p
                    } else {
                        gitdir.join(p)
                    }
                }
                Err(_) => gitdir.clone(),
            };
            return Some((gitdir, common));
        }
        if !dir.pop() {
            return None;
        }
    }
    None
}

/// The repo and branch of the checkout containing `cwd`, from files only.
pub fn working_copy_at(cwd: &Path) -> WorkingCopy {
    let Some((gitdir, common)) = find_git(cwd) else {
        return WorkingCopy::default();
    };
    let branch = std::fs::read_to_string(gitdir.join("HEAD"))
        .ok()
        .and_then(|h| {
            h.trim()
                .strip_prefix("ref: refs/heads/")
                .map(|b| b.trim().to_owned())
        })
        .filter(|b| !b.is_empty());
    let repo = std::fs::read_to_string(common.join("config"))
        .ok()
        .and_then(|c| origin_url(&c))
        .and_then(|u| parse_remote_url(&u));
    WorkingCopy { repo, branch }
}

/// What the engine knows about one focus's session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRef {
    pub tag: String,
    pub session_id: Option<String>,
    pub spawn_cwd: Option<PathBuf>,
    pub project_path: Option<PathBuf>,
}

#[derive(Default)]
struct Cached {
    checked: Option<Instant>,
    copy: WorkingCopy,
    transcript: Option<(String, PathBuf)>,
    /// mtime and length of the transcript when `cwd` was last read.
    stamp: Option<(SystemTime, u64)>,
    cwd: Option<PathBuf>,
}

/// Per-tag cache of working copies, refreshed at most every [`REFRESH_EVERY`].
#[derive(Default)]
pub struct WorkingCopies {
    cache: HashMap<String, Cached>,
}

impl WorkingCopies {
    /// Refresh what is due and return every known tag's working copy. Tags no
    /// longer in `sessions` are forgotten.
    pub fn refresh(
        &mut self,
        now: Instant,
        projects_root: &Path,
        sessions: &[SessionRef],
    ) -> HashMap<String, WorkingCopy> {
        let live: std::collections::HashSet<&str> =
            sessions.iter().map(|s| s.tag.as_str()).collect();
        self.cache.retain(|t, _| live.contains(t.as_str()));
        for s in sessions.iter().take(MAX_FOCUSES) {
            let entry = self.cache.entry(s.tag.clone()).or_default();
            if entry
                .checked
                .is_some_and(|c| now.saturating_duration_since(c) < REFRESH_EVERY)
            {
                continue;
            }
            entry.checked = Some(now);
            entry.cwd = Self::live_cwd(entry, projects_root, s);
            entry.copy = entry
                .cwd
                .as_deref()
                .map(working_copy_at)
                .unwrap_or_default();
        }
        self.cache
            .iter()
            .map(|(t, c)| (t.clone(), c.copy.clone()))
            .collect()
    }

    fn live_cwd(entry: &mut Cached, projects_root: &Path, s: &SessionRef) -> Option<PathBuf> {
        if let Some(id) = s.session_id.as_deref() {
            let path = match &entry.transcript {
                Some((cached_id, p)) if cached_id == id && p.is_file() => Some(p.clone()),
                _ => find_transcript(projects_root, id),
            };
            if let Some(path) = path {
                entry.transcript = Some((id.to_owned(), path.clone()));
                let stamp = std::fs::metadata(&path)
                    .and_then(|m| m.modified().map(|t| (t, m.len())))
                    .ok();
                // Read the transcript only when it changed.
                if stamp.is_some() && stamp == entry.stamp && entry.cwd.is_some() {
                    return entry.cwd.clone();
                }
                entry.stamp = stamp;
                if let Some(cwd) = last_cwd(&path) {
                    return Some(cwd);
                }
            }
        }
        [s.spawn_cwd.as_ref(), s.project_path.as_ref()]
            .into_iter()
            .flatten()
            .find(|p| p.is_absolute() && p.is_dir())
            .cloned()
    }
}
