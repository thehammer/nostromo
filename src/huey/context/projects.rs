//! Project discovery under the code root, worktree dedupe and the in-flight
//! rule (A9).
//!
//! A project is a git repository; every worktree of it collapses into one
//! project, keyed by `git rev-parse --git-common-dir`. Git always runs with a
//! fixed argv (never through a shell), read-only, with a 5 s timeout.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use chrono::{DateTime, TimeZone, Utc};

/// How long any one git call may run.
pub const GIT_TIMEOUT: Duration = Duration::from_secs(5);
/// Most in-flight projects in one digest.
pub const MAX_IN_FLIGHT: usize = 8;
/// Directories under the code root that are never descended into.
const SKIP_DIRS: &[&str] = &["node_modules", "target", "vendor", "build", "dist"];

/// One git repository, all its worktrees under the code root collapsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Repo {
    /// Lower-cased name of the main worktree's directory.
    pub id: String,
    /// The main worktree's directory name as written.
    pub name: String,
    /// Where probes and the profile run: the main worktree when it is under
    /// the code root, else the first worktree that is. Never outside it.
    pub root: PathBuf,
    /// Every directory that resolved to this repository, main included (even
    /// when it is outside the code root; it is only compared, never probed), sorted.
    pub worktrees: Vec<PathBuf>,
}

impl Repo {
    /// Is `path` inside one of this repository's worktrees?
    pub fn contains(&self, path: &Path) -> bool {
        let path = canonical(path);
        self.worktrees.iter().any(|w| path.starts_with(w))
    }
}

/// One commit subject.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Commit {
    pub sha: String,
    pub at: DateTime<Utc>,
    pub subject: String,
}

/// What `git` returned: the exit code and stdout. `None` from [`git`] means it
/// could not run, or timed out.
pub(crate) struct GitOutput {
    pub code: i32,
    pub stdout: Vec<u8>,
}

/// Run `git -C <dir> <args>` with a fixed argv, no shell, no stdin, no pager,
/// no optional locks, no system config, and fsmonitor, signature display and
/// hooks off (so a repository's own config cannot make a read start a
/// program), killed after [`GIT_TIMEOUT`].
pub(crate) fn git(dir: &Path, args: &[&str]) -> Option<GitOutput> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "log.showSignature=false",
            "-c",
            "core.hooksPath=/dev/null",
            "--no-pager",
        ])
        .args(args)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        stdout.read_to_end(&mut buf).map(|_| buf)
    });
    let deadline = Instant::now() + GIT_TIMEOUT;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = reader.join();
                return None;
            }
        }
    };
    let stdout = reader.join().ok()?.ok()?;
    Some(GitOutput {
        code: status.code().unwrap_or(-1),
        stdout,
    })
}

fn git_ok(dir: &Path, args: &[&str]) -> Option<String> {
    let out = git(dir, args)?;
    (out.code == 0).then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// The main worktree of the repository `dir` belongs to, or `None` when `dir`
/// is not in a git repository.
fn main_worktree(dir: &Path) -> Option<PathBuf> {
    let out = git_ok(
        dir,
        &["rev-parse", "--path-format=absolute", "--git-common-dir"],
    )?;
    let common = PathBuf::from(out.trim());
    if common.file_name().is_some_and(|n| n == ".git") {
        common.parent().map(canonical)
    } else {
        // A bare repository: the common dir is the repository itself.
        Some(canonical(&common))
    }
}

fn is_candidate(dir: &Path) -> bool {
    dir.join(".git").exists()
}

/// A `.git` directory is the repository itself. A `.git` file (a linked
/// worktree) is trusted only when the git dir it names points back at it, so a
/// planted `gitdir:` cannot make a directory under the code root stand in for
/// a repository elsewhere.
fn is_genuine(dir: &Path) -> bool {
    let dot_git = dir.join(".git");
    let Ok(meta) = std::fs::symlink_metadata(&dot_git) else {
        return false;
    };
    if meta.is_dir() {
        return true;
    }
    if !meta.is_file() || meta.len() > 4096 {
        return false;
    }
    let Ok(text) = std::fs::read_to_string(&dot_git) else {
        return false;
    };
    let Some(target) = text.trim().strip_prefix("gitdir:") else {
        return false;
    };
    let gitdir = dir.join(target.trim());
    let Ok(back) = std::fs::read_to_string(gitdir.join("gitdir")) else {
        return false;
    };
    canonical(&dir.join(back.trim())) == canonical(&dot_git)
}

fn listable_children(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter(|e| {
            let name = e.file_name();
            let name = name.to_string_lossy();
            !name.starts_with('.') && !SKIP_DIRS.contains(&name.as_ref())
        })
        .map(|e| e.path())
        .collect();
    out.sort();
    out
}

/// Every repository under `code_root`: its children, and the children of any
/// child that is not itself a repository. Worktrees of one repository collapse
/// into one entry. Sorted by id.
pub fn discover(code_root: &Path) -> Vec<Repo> {
    let mut dirs = Vec::new();
    for child in listable_children(code_root) {
        if is_candidate(&child) {
            dirs.push(child);
        } else {
            dirs.extend(
                listable_children(&child)
                    .into_iter()
                    .filter(|d| is_candidate(d)),
            );
        }
    }
    let code_root_canonical = canonical(code_root);
    let mut by_main: BTreeMap<PathBuf, Vec<PathBuf>> = BTreeMap::new();
    for dir in dirs {
        if !is_genuine(&dir) {
            continue;
        }
        if let Some(main) = main_worktree(&dir) {
            by_main.entry(main).or_default().push(canonical(&dir));
        }
    }
    let mut repos: Vec<Repo> = by_main
        .into_iter()
        .filter_map(|(main, mut worktrees)| {
            let name = main.file_name()?.to_string_lossy().into_owned();
            // Probes run under the code root: in the main worktree when it is
            // there, else in the first candidate directory that is.
            let root = if main.starts_with(&code_root_canonical) {
                main.clone()
            } else {
                worktrees
                    .iter()
                    .filter(|w| w.starts_with(&code_root_canonical))
                    .min()?
                    .clone()
            };
            if !worktrees.contains(&main) {
                worktrees.push(main.clone());
            }
            worktrees.sort();
            worktrees.dedup();
            Some(Repo {
                id: super::collectors::safe_id(&name, 64),
                name,
                root,
                worktrees,
            })
        })
        .collect();
    repos.sort_by(|a, b| a.id.cmp(&b.id).then_with(|| a.root.cmp(&b.root)));
    // Two repositories with the same directory name: the later ones get `-2`, `-3`.
    let mut seen: BTreeMap<String, usize> = BTreeMap::new();
    for repo in &mut repos {
        let n = seen.entry(repo.id.clone()).or_insert(0);
        *n += 1;
        if *n > 1 {
            repo.id = format!("{}-{}", repo.id, n);
        }
    }
    repos
}

/// The newest commits on local branches (merges excluded), newest first, at
/// most `max`.
pub fn recent_commits(repo_root: &Path, max: usize) -> Vec<Commit> {
    let max_arg = format!("--max-count={max}");
    let Some(out) = git_ok(
        repo_root,
        &[
            "log",
            "--branches",
            "--no-merges",
            &max_arg,
            "--format=%H%x09%ct%x09%s",
        ],
    ) else {
        return Vec::new();
    };
    let mut commits: Vec<Commit> = out
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(3, '\t');
            let sha = parts.next()?;
            let at = parts.next()?.parse::<i64>().ok()?;
            let subject = parts.next().unwrap_or("");
            Some(Commit {
                sha: sha.chars().take(7).collect(),
                at: Utc.timestamp_opt(at, 0).single()?,
                subject: subject.to_string(),
            })
        })
        .collect();
    commits.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| a.sha.cmp(&b.sha)));
    commits
}

/// The full HEAD sha of `repo_root`, or `None` with no commits.
pub fn head_sha(repo_root: &Path) -> Option<String> {
    git_ok(repo_root, &["rev-parse", "--verify", "--quiet", "HEAD"])
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The in-flight projects among `activity` (project id → latest activity;
/// a project with no activity is absent): most recent first, ties by id, at
/// most [`MAX_IN_FLIGHT`].
pub fn select_in_flight(activity: &BTreeMap<String, DateTime<Utc>>) -> Vec<String> {
    let mut ranked: Vec<(&String, &DateTime<Utc>)> = activity.iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
    ranked
        .into_iter()
        .take(MAX_IN_FLIGHT)
        .map(|(id, _)| id.clone())
        .collect()
}
