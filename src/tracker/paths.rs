//! Where a board lives and what it may be: topic rules, the default path, the
//! path policy, the repo root, and the `committable` probe (contract §2, PRD
//! criteria 3 and 35).
//!
//! The only subprocess this module can start is `git`, with a closed set of
//! read-only subcommands ([`GitCommand`]); nothing here can stage, commit or
//! push.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

use regex::Regex;

use super::view::Committable;

/// `true` for `^[a-z0-9][a-z0-9-]{0,47}$`.
pub fn is_valid_topic(topic: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-z0-9][a-z0-9-]{0,47}$").unwrap())
        .is_match(topic)
}

/// The nearest ancestor of `cwd` (itself included) that contains `.git`, else
/// `cwd`. Walks the file system; runs no git command.
pub fn repo_root(cwd: &Path) -> PathBuf {
    cwd.ancestors()
        .find(|dir| dir.join(".git").exists())
        .unwrap_or(cwd)
        .to_path_buf()
}

/// `<repo_root>/.claude/wip/<topic>/index.md`.
pub fn default_path(repo_root: &Path, topic: &str) -> PathBuf {
    repo_root
        .join(".claude")
        .join("wip")
        .join(topic)
        .join("index.md")
}

/// The path is not under the repo root or `~/.claude/wip/`, is not a `.md`
/// file, or escapes them through `..` or a symlink.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PathNotAllowed;

/// Resolves `requested` (absolute, or relative to `repo_root`) to the path a
/// board may live at: a `.md` file whose parent directory, with symlinks
/// resolved, is under `repo_root` or `home_wip`. Directories that don't exist
/// yet are allowed (they are created on open) as long as no `..` appears in the
/// part that doesn't exist. Creates nothing.
pub fn resolve_board_path(
    repo_root: &Path,
    home_wip: Option<&Path>,
    requested: &Path,
) -> Result<PathBuf, PathNotAllowed> {
    let absolute = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        repo_root.join(requested)
    };
    let is_md = absolute
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("md"));
    if !is_md || absolute.file_name().is_none() {
        return Err(PathNotAllowed);
    }
    let canonical = canonicalize_lenient(&absolute).ok_or(PathNotAllowed)?;
    let under = |root: &Path| {
        canonicalize_lenient(root).is_some_and(|root| canonical.starts_with(root))
    };
    if under(repo_root) || home_wip.is_some_and(under) {
        Ok(canonical)
    } else {
        Err(PathNotAllowed)
    }
}

/// Canonicalises the longest existing prefix of `path` and appends the rest.
/// `None` when the rest holds `..` or anything but plain names, or when a
/// dangling symlink is in the way (writing through it would land elsewhere).
fn canonicalize_lenient(path: &Path) -> Option<PathBuf> {
    let mut tail: Vec<OsString> = Vec::new();
    let mut current = path.to_path_buf();
    loop {
        if let Ok(mut canonical) = std::fs::canonicalize(&current) {
            canonical.extend(tail.iter().rev());
            return Some(canonical);
        }
        if std::fs::symlink_metadata(&current).is_ok() {
            return None;
        }
        match current.components().next_back()? {
            Component::Normal(name) => {
                tail.push(name.to_os_string());
                current.pop();
            }
            _ => return None,
        }
    }
}

// ── committable probe ────────────────────────────────────────────────────────

/// The read-only git invocations the probe may run. The closed set is the
/// guarantee: there is no way to ask for `add`, `commit`, `push` or `stage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GitCommand {
    /// `check-ignore -q -- <path>`: exit 0 when ignored.
    CheckIgnore(PathBuf),
    /// `ls-files --error-unmatch -- <path>`: exit 0 when tracked.
    LsFilesErrorUnmatch(PathBuf),
    /// `remote get-url origin`.
    RemoteGetUrlOrigin,
}

impl GitCommand {
    /// The argument vector after `git -C <repo>`.
    pub fn args(&self) -> Vec<OsString> {
        let strs = |parts: &[&str]| -> Vec<OsString> { parts.iter().map(OsString::from).collect() };
        match self {
            GitCommand::CheckIgnore(path) => {
                let mut args = strs(&["check-ignore", "-q", "--"]);
                args.push(path.as_os_str().to_owned());
                args
            }
            GitCommand::LsFilesErrorUnmatch(path) => {
                let mut args = strs(&["ls-files", "--error-unmatch", "--"]);
                args.push(path.as_os_str().to_owned());
                args
            }
            GitCommand::RemoteGetUrlOrigin => strs(&["remote", "get-url", "origin"]),
        }
    }
}

/// What git said: the exit status and stdout, or that it could not run.
struct GitRun {
    success: bool,
    stdout: String,
}

fn run_git(repo: &Path, command: &GitCommand) -> Option<GitRun> {
    // The repo's own config is not trusted: no filesystem monitor (a command
    // the config names), and no repository or work tree from the environment.
    let output = Command::new("git")
        .arg("--no-optional-locks")
        .args(["-c", "core.fsmonitor=false"])
        .arg("-C")
        .arg(repo)
        .args(command.args())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    // 128 is "not a repository" or another failure; only 0 and 1 are answers.
    match output.status.code() {
        Some(0) => Some(GitRun {
            success: true,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        }),
        Some(1) => Some(GitRun {
            success: false,
            stdout: String::new(),
        }),
        _ => None,
    }
}

/// Would a commit pick this board up: it is tracked, or it is not ignored?
/// `None` when the board is outside a git repo (or git can't answer), so no
/// warning is shown. `remote` is `host/owner/repo` only.
pub fn probe_committable(repo_root: &Path, board: &Path) -> Option<Committable> {
    if !repo_root.join(".git").exists() {
        return None;
    }
    let relative = board.strip_prefix(repo_root).ok()?.to_path_buf();
    let tracked = run_git(repo_root, &GitCommand::LsFilesErrorUnmatch(relative.clone()))?.success;
    let ignored = run_git(repo_root, &GitCommand::CheckIgnore(relative))?.success;
    if !tracked && ignored {
        return None;
    }
    let remote = run_git(repo_root, &GitCommand::RemoteGetUrlOrigin)
        .filter(|run| run.success)
        .and_then(|run| display_remote(run.stdout.trim()));
    Some(Committable { remote })
}

/// `host/owner/repo` of a remote URL, credentials and `.git` dropped; `None`
/// when it doesn't look like one.
pub fn display_remote(url: &str) -> Option<String> {
    // scp-like: git@github.com:owner/repo.git
    let (host, path) = match url.split_once("://") {
        Some((_, rest)) => rest.split_once('/')?,
        None => url.split_once(':')?,
    };
    let host = host.rsplit('@').next()?;
    let host = host.split(':').next()?;
    let path = path
        .split(['?', '#'])
        .next()?
        .trim_matches('/')
        .trim_end_matches(".git");
    let mut parts = path.split('/').filter(|p| !p.is_empty());
    let (owner, repo) = (parts.next()?, parts.next()?);
    let clean = |s: &str| !s.is_empty() && !s.contains(char::is_whitespace);
    (clean(host) && clean(owner) && clean(repo)).then(|| format!("{host}/{owner}/{repo}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn remote_is_shown_as_host_owner_repo_without_credentials() {
        for (url, want) in [
            ("git@github.com:thehammer/nostromo.git", "github.com/thehammer/nostromo"),
            ("https://github.com/o/r.git", "github.com/o/r"),
            ("https://user:ghp_SECRET@github.com/o/r", "github.com/o/r"),
            ("ssh://git@host.example:2222/o/r.git", "host.example/o/r"),
        ] {
            assert_eq!(display_remote(url).as_deref(), Some(want), "{url}");
        }
        assert_eq!(display_remote("not a url"), None);
    }

    #[test]
    fn topics_follow_the_contract_pattern() {
        assert!(is_valid_topic("sentry-triage"));
        assert!(is_valid_topic("0"));
        assert!(!is_valid_topic("-x"));
        assert!(!is_valid_topic("Upper"));
        assert!(!is_valid_topic("../x"));
        assert!(!is_valid_topic(&"a".repeat(49)));
    }

    #[test]
    fn only_read_only_git_subcommands_can_be_built() {
        let p = PathBuf::from("a/b.md");
        for command in [
            GitCommand::CheckIgnore(p.clone()),
            GitCommand::LsFilesErrorUnmatch(p),
            GitCommand::RemoteGetUrlOrigin,
        ] {
            let args = command.args();
            let first = args[0].to_str().unwrap();
            assert!(["check-ignore", "ls-files", "remote"].contains(&first), "{first}");
            for banned in ["add", "commit", "push", "stage", "reset", "checkout", "rm"] {
                assert!(!args.iter().any(|a| a == banned), "{banned} in {args:?}");
            }
        }
    }
}
