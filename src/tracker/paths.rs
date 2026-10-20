//! Where a board lives and what it may be: topic rules, the default path, the
//! path policy, the repo root, and the `committable` probe (contract §2, PRD
//! criteria 3 and 35).
//!
//! The only subprocess this module can start is `git`, with a closed set of
//! read-only subcommands ([`GitCommand`]); nothing here can stage, commit or
//! push.

use std::ffi::OsString;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use regex::Regex;

use super::view::Committable;

/// `true` for `^[a-z0-9][a-z0-9-]{0,47}$`.
pub fn is_valid_topic(topic: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-z0-9][a-z0-9-]{0,47}$").unwrap())
        .is_match(topic)
}

/// Where a focus's boards may live: the nearest ancestor of its working
/// directory that holds `.git`, or the working directory itself when none does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoRoot {
    pub dir: PathBuf,
    /// A `.git` was found. Without one the root is only the working directory
    /// and boards are confined to `<dir>/.claude/wip/` (see [`resolve_board_path`]).
    pub git: bool,
}

/// The nearest ancestor of `cwd` (itself included) that contains `.git`, else
/// `cwd`. Walks the file system; runs no git command.
pub fn find_repo_root(cwd: &Path) -> RepoRoot {
    match cwd.ancestors().find(|dir| dir.join(".git").exists()) {
        Some(dir) => RepoRoot {
            dir: dir.to_path_buf(),
            git: true,
        },
        None => RepoRoot {
            dir: cwd.to_path_buf(),
            git: false,
        },
    }
}

/// `<repo_root>/.claude/wip/<topic>/index.md`.
pub fn default_path(repo_root: &Path, topic: &str) -> PathBuf {
    repo_root
        .join(".claude")
        .join("wip")
        .join(topic)
        .join("index.md")
}

/// The path is not an allowed board location: not a `.md` file, not under the
/// repo root or `~/.claude/wip/`, an instruction file the agent tooling reads
/// (see [`resolve_board_path`]), or it escapes through `..` or a symlink.
/// Says nothing about which rule it broke.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PathNotAllowed;

/// File names that carry instructions to an agent, at any depth.
const INSTRUCTION_FILES: [&str; 5] = [
    "CLAUDE.md",
    "CLAUDE.local.md",
    "AGENTS.md",
    "GEMINI.md",
    "SKILL.md",
];
/// Directories under a `.claude` directory that agents load instructions from.
const INSTRUCTION_DIRS: [&str; 7] = [
    "commands",
    "agents",
    "skills",
    "hooks",
    "plugins",
    "rules",
    "output-styles",
];

/// Resolves `requested` (absolute, or relative to the repo root) to the path a
/// board may live at: a `.md` file whose parent directory, with symlinks
/// resolved, is under the repo root or `~/.claude/wip/`. Directories that don't
/// exist yet are allowed (they are created on open) as long as no `..` appears
/// in the part that doesn't exist. Creates nothing.
///
/// The tool rewrites a board it opens and appends to it on every change, so a
/// board must never be a file an agent loads as instructions, or the daemon
/// would plant them without the Edit tool's permission prompt. Refused, for
/// explicit paths and adoptions alike: `CLAUDE.md`, `CLAUDE.local.md`,
/// `AGENTS.md`, `GEMINI.md` and `SKILL.md` at any depth (any case); anything
/// under `.claude/commands`, `agents`, `skills`, `hooks`, `plugins`, `rules` or
/// `output-styles`; anything under `.github`;
/// any file whose name starts with `.`. The rules look at the path with
/// symlinks resolved, relative to the root it was allowed under.
///
/// Without a `.git` the root is only the working directory, so only
/// `<dir>/.claude/wip/` is allowed there, and a root that is the home
/// directory itself allows nothing but `~/.claude/wip/`.
pub fn resolve_board_path(
    root: &RepoRoot,
    home: Option<&Path>,
    requested: &Path,
) -> Result<PathBuf, PathNotAllowed> {
    let absolute = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        root.dir.join(requested)
    };
    let is_md = absolute
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("md"));
    if !is_md || absolute.file_name().is_none() {
        return Err(PathNotAllowed);
    }
    let canonical = canonicalize_lenient(&absolute).ok_or(PathNotAllowed)?;
    // The extension is checked again on the resolved path: `x.md -> .git/hooks/pre-commit` is not a board.
    if !canonical.extension().is_some_and(|e| e.eq_ignore_ascii_case("md")) {
        return Err(PathNotAllowed);
    }
    let allowed_under = |allowed: Option<PathBuf>| {
        allowed
            .and_then(|dir| canonicalize_lenient(&dir))
            .and_then(|dir| canonical.strip_prefix(dir).ok().map(Path::to_path_buf))
            .is_some_and(|relative| !is_instruction_path(&relative))
    };
    let root_dir = canonicalize_lenient(&root.dir);
    let home_is_root = match (&root_dir, home.and_then(canonicalize_lenient)) {
        (Some(root_dir), Some(home)) => *root_dir == home,
        _ => false,
    };
    let repo_allowed = if home_is_root {
        None
    } else if root.git {
        root_dir
    } else {
        // `root_dir` is already canonical; joining keeps a symlinked
        // `.claude/wip` from widening the allowance.
        root_dir.map(|dir| dir.join(".claude").join("wip"))
    };
    let home_wip = home.map(|h| h.join(".claude").join("wip"));
    if allowed_under(repo_allowed) || allowed_under(home_wip) {
        Ok(canonical)
    } else {
        Err(PathNotAllowed)
    }
}

/// Whether `relative` (below the root a board was allowed under) names a file
/// an agent loads as instructions.
fn is_instruction_path(relative: &Path) -> bool {
    let names: Vec<String> = relative
        .components()
        .filter_map(|c| match c {
            Component::Normal(name) => Some(name.to_string_lossy().to_ascii_lowercase()),
            _ => None,
        })
        .collect();
    let Some(file) = names.last() else {
        return true;
    };
    // Any dot-component is refused (`.git`, `.cursor`, `.windsurf`, `.clinerules`, `.roo`, `.github`,
    // `.claude/agent-memory`, ...) except a `.claude` directly followed by `wip` and a file below it.
    // An allow rule is the closed one: new agent tools keep inventing instruction directories.
    let dot_ok = |i: usize, n: &str| {
        n == ".claude" && names.get(i + 1).map(String::as_str) == Some("wip") && i + 2 < names.len()
    };
    if names.iter().enumerate().any(|(i, n)| n.starts_with('.') && !dot_ok(i, n)) {
        return true;
    }
    file.starts_with('.')
        || INSTRUCTION_FILES.iter().any(|f| f.eq_ignore_ascii_case(file))
        || names.iter().any(|n| n == ".github")
        || names
            .windows(2)
            .any(|w| w[0] == ".claude" && INSTRUCTION_DIRS.contains(&w[1].as_str()))
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

/// How long the whole probe may take. A slow or hung git (a stalled network
/// file system, a lock) must not hold up a tool call: the probe gives up and
/// the board simply shows no commit warning.
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);

/// Runs `command` to completion, or kills it at `deadline`. `None` when it
/// can't start or runs out of time.
fn output_before(mut command: Command, deadline: Instant) -> Option<Output> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

fn run_git(repo: &Path, command: &GitCommand, deadline: Instant) -> Option<GitRun> {
    // The repo's own config is not trusted: no filesystem monitor (a command
    // the config names), and no repository or work tree from the environment.
    let mut git = Command::new("git");
    git.arg("--no-optional-locks")
        .args(["-c", "core.fsmonitor=false"])
        .arg("-C")
        .arg(repo)
        .args(command.args())
        .env("GIT_TERMINAL_PROMPT", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE");
    let output = output_before(git, deadline)?;
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
    let deadline = Instant::now() + PROBE_TIMEOUT;
    let tracked = run_git(
        repo_root,
        &GitCommand::LsFilesErrorUnmatch(relative.clone()),
        deadline,
    )?
    .success;
    let ignored = run_git(repo_root, &GitCommand::CheckIgnore(relative), deadline)?.success;
    if !tracked && ignored {
        return None;
    }
    let remote = run_git(repo_root, &GitCommand::RemoteGetUrlOrigin, deadline)
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
    fn only_dot_claude_wip_may_hold_a_dot_component() {
        for denied in [
            ".claude/agent-memory/x.md",
            ".claude/loop.md",
            ".claude/projects/p/memory/m.md",
            ".claude/wip.md",
            ".claude/wip",
            ".cursor/rules/x.md",
            ".windsurf/rules/x.md",
            ".clinerules/x.md",
            ".roo/rules/x.md",
            ".git/hooks/x.md",
            "docs/.hidden/x.md",
            "a/.claude/commands/x.md",
        ] {
            assert!(is_instruction_path(Path::new(denied)), "{denied} must be refused");
        }
        for allowed in [".claude/wip/topic/index.md", "docs/board.md", "a/.claude/wip/t/index.md"] {
            assert!(!is_instruction_path(Path::new(allowed)), "{allowed} must be allowed");
        }
    }

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

    #[cfg(unix)]
    #[test]
    fn a_command_past_its_deadline_is_killed_and_a_quick_one_returns_its_output() {
        let started = Instant::now();
        let mut slow = Command::new("sleep");
        slow.arg("5");
        assert!(output_before(slow, Instant::now() + Duration::from_millis(100)).is_none());
        assert!(started.elapsed() < Duration::from_secs(3), "the deadline was not enforced");

        let mut quick = Command::new("echo");
        quick.arg("hello");
        let out = output_before(quick, Instant::now() + Duration::from_secs(10)).expect("output");
        assert_eq!(String::from_utf8_lossy(&out.stdout), "hello\n");
    }
}
