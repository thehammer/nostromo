//! The production-shell guard (design contract §5).
//!
//! Agents may not open a remote ECS/SSM shell, nor type into a tmux pane that
//! runs one. [`evaluate`] decides from the PreToolUse hook payload and a
//! [`PaneProbe`] alone: no config file, env switch, permission mode or rule
//! list can turn a block into an allow.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{mpsc, OnceLock};
use std::time::Duration;

use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use super::expand;
use super::inert;
use super::keys::{self, Buffers, Key};
use super::shell::{self, SimpleCommand, Word};
use super::tmux_bin;

/// What the agent is told when the guard blocks a call (verbatim, contract §5).
pub const GUARD_MESSAGE: &str = "Blocked by Nostromo's production-shell guard: agents may not open or type into production shells. Give the user the command to run themselves.";

/// What the agent is told when the guard itself could not run (fail closed).
pub const FAIL_CLOSED_MESSAGE: &str =
    "Blocked by Nostromo's production-shell guard: the guard could not run, so this call was blocked.";

/// Env var naming the guard binary (tests); first in [`resolve_guard_path`].
pub const GUARD_BIN_ENV: &str = "NOSTROMO_GUARD_BIN";

/// The guard path used when no binary can be found. It doesn't exist, so the
/// hook wrapper fails closed and every tool call is blocked.
pub const GUARD_SENTINEL_PATH: &str = "/nonexistent/nostromo-guard";

/// Block `ecs_run_task` / `aws ecs run-task` too (user question U-B, default yes).
pub const BLOCK_RUN_TASK: bool = true;

/// The PreToolUse hook payload (the fields the guard reads; others ignored).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct HookPayload {
    pub tool_name: String,
    /// A missing input is `{}`.
    #[serde(default = "empty_object")]
    pub tool_input: Value,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub tool_use_id: Option<String>,
    #[serde(default)]
    pub permission_mode: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub hook_event_name: Option<String>,
}

fn empty_object() -> Value {
    Value::Object(serde_json::Map::new())
}

/// The guard's decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardVerdict {
    Allow,
    Block {
        /// Which rule matched: one of the `RULE_*` constants.
        rule_id: &'static str,
        /// What matched, for the audit log.
        detail: String,
    },
}

/// Rule id: the tool name is an ECS shell tool.
pub const RULE_TOOL_NAME: &str = "tool_name";
/// Rule id: a command string opens a remote shell.
pub const RULE_COMMAND: &str = "command";
/// Rule id: tmux input aimed at (or possibly at) a remote pane.
pub const RULE_TMUX_INPUT: &str = "tmux_input";

/// The guard could not decide (a probe failed where the answer mattered).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GuardError {
    #[error("pane probe failed: {0}")]
    Probe(#[from] ProbeError),
}

/// Which tmux server a command talks to.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TmuxSocket {
    /// No `-L` / `-S`.
    Default,
    /// `-L <name>`.
    Name(String),
    /// `-S <path>`.
    Path(String),
}

/// One tmux pane, as the probe sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneInfo {
    pub pid: u32,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProbeError {
    #[error("`{0}` timed out")]
    Timeout(String),
    #[error("`{command}` failed: {message}")]
    Failed { command: String, message: String },
}

/// Looks at tmux panes and process trees.
pub trait PaneProbe {
    /// The pane `target` on `socket`. `Ok(None)` if no server answers or the
    /// target doesn't exist.
    fn pane(&self, socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError>;
    /// Every pane on `socket`. Empty if no server answers.
    fn all_panes(&self, socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError>;
    /// The argument strings of `pid` and all its descendants.
    fn subtree_args(&self, pid: u32) -> Result<Vec<String>, ProbeError>;
    /// Every tmux server that might be running: the default one and each
    /// socket in tmux's socket directory and in `extra_dirs`.
    fn servers(&self, extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError>;
    /// The line the cursor is on in pane `target` (the input typed so far, with
    /// the prompt), or `None` when it can't be read.
    fn pending_input(
        &self,
        _socket: &TmuxSocket,
        _target: &str,
    ) -> Result<Option<String>, ProbeError> {
        Ok(None)
    }
}

/// The real probe: runs `tmux` and `ps`, each with a [`PROBE_TIMEOUT`].
#[derive(Debug, Default)]
pub struct SystemPaneProbe {
    /// `ps` output, read once per probe (one hook call).
    processes: OnceLock<Result<ProcessTable, ProbeError>>,
}

/// `(pid, ppid, args)` for every process.
type ProcessTable = Vec<(u32, u32, String)>;

/// How long one `tmux` or `ps` run may take.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// The tmux format for one pane: `<pid> <title>`. (tmux prints a tab in a
/// format as `_`, so the separator is the first space; a pid has none.)
const PANE_FORMAT: &str = "#{pane_pid} #{pane_title}";

impl SystemPaneProbe {
    pub fn new() -> Self {
        Self::default()
    }

    /// A `tmux` call with a scrubbed environment: only `PATH`. Which server it
    /// talks to is never left to `TMUX` / `TMUX_TMPDIR` / `TMUX_PANE`; it is
    /// always an explicit `-S <path>`, worked out from the guard's own
    /// `TMUX` / `TMUX_TMPDIR` (the server the session's own `tmux` would use).
    fn tmux(socket: &TmuxSocket, args: &[&str]) -> Command {
        let mut cmd = Command::new(tmux_program());
        cmd.env_clear();
        if let Some(path) = std::env::var_os("PATH") {
            cmd.env("PATH", path);
        }
        let path = match socket {
            TmuxSocket::Default => default_socket(),
            TmuxSocket::Name(n) => tmux_socket_dir().join(n),
            TmuxSocket::Path(p) => PathBuf::from(p),
        };
        cmd.arg("-u").arg("-S").arg(path);
        cmd.args(args);
        cmd
    }

    /// Run a tmux query. `Ok(None)` when tmux is missing, no server answers or
    /// the target doesn't exist.
    fn query(socket: &TmuxSocket, args: &[&str]) -> Result<Option<String>, ProbeError> {
        let mut cmd = Self::tmux(socket, args);
        let label = format!("tmux {}", args.first().copied().unwrap_or_default());
        let out = match run_with_timeout(&mut cmd, &label) {
            Err(ProbeError::Failed { message, .. }) if message.contains("No such file") => {
                return Ok(None)
            }
            r => r?,
        };
        if out.status.success() {
            return Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()));
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        let absent = [
            "no server running",
            "error connecting",
            "No such file or directory",
            "can't find",
            "no current",
        ];
        if absent.iter().any(|m| stderr.contains(m)) {
            return Ok(None);
        }
        Err(ProbeError::Failed {
            command: label,
            message: stderr.trim().to_owned(),
        })
    }

    fn processes(&self) -> Result<&ProcessTable, ProbeError> {
        self.processes
            .get_or_init(|| {
                let mut cmd = Command::new("/bin/ps");
                cmd.env_clear();
                cmd.args(["-axo", "pid=,ppid=,args="]);
                let out = run_with_timeout(&mut cmd, "ps")?;
                if !out.status.success() {
                    return Err(ProbeError::Failed {
                        command: "ps".into(),
                        message: String::from_utf8_lossy(&out.stderr).trim().to_owned(),
                    });
                }
                Ok(String::from_utf8_lossy(&out.stdout)
                    .lines()
                    .filter_map(|line| {
                        let mut it = line.split_whitespace();
                        let pid = it.next()?.parse().ok()?;
                        let ppid = it.next()?.parse().ok()?;
                        Some((pid, ppid, it.collect::<Vec<_>>().join(" ")))
                    })
                    .collect())
            })
            .as_ref()
            .map_err(Clone::clone)
    }
}

/// tmux at a fixed install location, so a `tmux` an agent puts earlier on
/// `PATH` can't answer for it. Falls back to `PATH` only when none exists.
fn tmux_program() -> &'static str {
    tmux_bin::TMUX_INSTALL_PATHS
        .iter()
        .copied()
        .find(|p| Path::new(p).is_file())
        .unwrap_or("tmux")
}

/// tmux's socket directory: `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`.
fn tmux_socket_dir() -> PathBuf {
    let base = std::env::var_os("TMUX_TMPDIR")
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| "/tmp".into());
    // SAFETY: getuid(2) has no preconditions and cannot fail.
    PathBuf::from(base).join(format!("tmux-{}", unsafe { libc::getuid() }))
}

/// The socket a plain `tmux` uses: the one `TMUX` names (inside tmux), else `default`.
fn default_socket() -> PathBuf {
    std::env::var("TMUX")
        .ok()
        .and_then(|t| {
            t.split(',')
                .next()
                .filter(|p| !p.is_empty())
                .map(PathBuf::from)
        })
        .unwrap_or_else(|| tmux_socket_dir().join("default"))
}

fn parse_pane_line(line: &str) -> Option<PaneInfo> {
    let (pid, title) = line.split_once(' ')?;
    Some(PaneInfo {
        pid: pid.trim().parse().ok()?,
        title: title.to_owned(),
    })
}

impl PaneProbe for SystemPaneProbe {
    fn pane(&self, socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        let out = Self::query(
            socket,
            &["display-message", "-p", "-t", target, PANE_FORMAT],
        )?;
        Ok(out.and_then(|o| o.lines().next().and_then(parse_pane_line)))
    }

    fn all_panes(&self, socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        let out = Self::query(socket, &["list-panes", "-a", "-F", PANE_FORMAT])?;
        Ok(out
            .map(|o| o.lines().filter_map(parse_pane_line).collect())
            .unwrap_or_default())
    }

    fn subtree_args(&self, pid: u32) -> Result<Vec<String>, ProbeError> {
        let procs = self.processes()?;
        let mut found = Vec::new();
        let mut queue = vec![pid];
        let mut seen = std::collections::HashSet::new();
        while let Some(p) = queue.pop() {
            if !seen.insert(p) {
                continue;
            }
            for (child, parent, args) in procs {
                if *child == p {
                    found.push(args.clone());
                }
                if *parent == p && *child != p {
                    queue.push(*child);
                }
            }
        }
        Ok(found)
    }

    fn pending_input(
        &self,
        socket: &TmuxSocket,
        target: &str,
    ) -> Result<Option<String>, ProbeError> {
        // The last non-blank line of the pane: the prompt and what is typed after it.
        let out = Self::query(socket, &["capture-pane", "-p", "-J", "-t", target])?;
        Ok(out.and_then(|o| {
            o.lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .map(str::to_owned)
        }))
    }

    fn servers(&self, extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        use std::os::unix::fs::FileTypeExt;
        let mut out = vec![TmuxSocket::Default];
        for dir in std::iter::once(tmux_socket_dir()).chain(extra_dirs.iter().cloned()) {
            let entries = match std::fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => {
                    return Err(ProbeError::Failed {
                        command: format!("listing {}", dir.display()),
                        message: e.to_string(),
                    })
                }
            };
            for entry in entries.flatten() {
                if entry.file_type().is_ok_and(|t| t.is_socket()) {
                    out.push(TmuxSocket::Path(
                        entry.path().to_string_lossy().into_owned(),
                    ));
                }
            }
        }
        Ok(out)
    }
}

/// Run `cmd` (stdin closed, output captured), killing it after [`PROBE_TIMEOUT`].
fn run_with_timeout(cmd: &mut Command, label: &str) -> Result<Output, ProbeError> {
    let failed = |e: std::io::Error| ProbeError::Failed {
        command: label.to_owned(),
        message: e.to_string(),
    };
    let child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(failed)?;
    let pid = child.id();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    match rx.recv_timeout(PROBE_TIMEOUT) {
        Ok(out) => out.map_err(failed),
        Err(_) => {
            // The waiting thread hasn't reaped it, so the pid is still ours.
            // SAFETY: plain kill(2) on our own unreaped child.
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGKILL);
            }
            Err(ProbeError::Timeout(label.to_owned()))
        }
    }
}

// ── policy ────────────────────────────────────────────────────────────────────

/// Rule 1: the ECS shell tools by name, anywhere in the name (MCP tools
/// included: `mcp__x__ecs_connect`, `ecs_connect_session`).
fn tool_name_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        let run_task = if BLOCK_RUN_TASK { "|ecs_run_task" } else { "" };
        Regex::new(&format!(
            "(?i)(ecs_connect|ecs_shell|ecs_open_tmux_pane{run_task})"
        ))
        .unwrap()
    })
}

/// Rule 2: command text that opens a remote shell.
fn command_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Anything may sit between the service and the operation, line breaks
        // included (`aws ecs --profile p execute-command`, values with spaces,
        // continued lines).
        let opts = r"\b[\s\S]*?\b";
        let run_task_word = if BLOCK_RUN_TASK { "|ecs_run_task" } else { "" };
        let run_task = if BLOCK_RUN_TASK { format!(r"|\becs{opts}run-task\b") } else { String::new() };
        // A name right after a `$` is a variable (`echo $ECS_CONNECT`), not a command.
        // Nothing else is required before it: `git grep -Oecs_connect` and
        // `-nO"ecs_connect"` glue the marker to a flag.
        Regex::new(&format!(
            r"(?i)(?:^|[^$])(?:ecs_connect|ecs_shell|ecs_open_tmux_pane{run_task_word})\b|\becs{opts}execute-command\b|\bssm{opts}start-session\b|\bsession-manager-plugin\b{run_task}"
        ))
        .unwrap()
    })
}

/// The single words that open a remote shell (or its operation), for the
/// words an expansion could build: `ecs_${U}connect`, `execute-${U}command`.
fn word_markers() -> &'static [&'static str] {
    if BLOCK_RUN_TASK {
        &[
            "ecs_connect",
            "ecs_shell",
            "ecs_open_tmux_pane",
            "ecs_run_task",
            "session-manager-plugin",
            "execute-command",
            "start-session",
            "run-task",
        ]
    } else {
        &[
            "ecs_connect",
            "ecs_shell",
            "ecs_open_tmux_pane",
            "session-manager-plugin",
            "execute-command",
            "start-session",
        ]
    }
}

/// A pane title set by `ecs_open_tmux_pane` (`${env}:${project}:${service}`).
fn remote_title_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^(production|prod|demo|canada|can|ca|staging|stg|stage):").unwrap()
    })
}

/// A process in a pane's subtree that is a remote shell.
fn remote_process_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"session-manager-plugin|\becs\s+execute-command\b|\bssm\s+start-session\b|\becs_connect\b").unwrap()
    })
}

/// `tmux` anywhere in the normalized text (counts possible invocations;
/// `libtmux` too). Any case: macOS file systems are case-insensitive, so
/// `TMUX` runs tmux too.
fn tmux_mention_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)tmux").unwrap())
}

/// A tmux config file or directory (`~/.tmux.conf`, `~/.tmux/plugins`,
/// `~/.config/tmux/tmux.conf`) or socket directory (`/tmp/tmux-501/default`): a
/// path that holds `tmux`, not a tmux call. Only these path shapes, with a `/`
/// before them: a bare `tmux.conf` or `.tmux` could be a copy of the binary.
fn tmux_config_name_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)/\.tmux\.conf\b|/\.tmux/|/tmux/tmux\.conf\b|/tmux-\d+/").unwrap()
    })
}

/// A tmux command that types or pipes into a pane, named without the binary
/// (`os.system("t"+"mux send-keys …")`): full names and the long aliases, and
/// the alias `send` aimed at a pane with `-t`.
fn tmux_verb_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r"(?i)\b(?:send-keys|send-prefix|paste-buffer|pipe-pane|respawn-pane|respawn-window|pasteb|pipep|respawnp|respawnw)\b|\bsend\s+(?:-\S+\s+)*-t\b",
        )
        .unwrap()
    })
}

/// Text that may point tmux at another server than the hook's own, or at
/// another pane than its target: any mention of `TMUX` / `TMUX_TMPDIR` /
/// `TMUX_PANE` (assigned, unset, …) or `env -i` / `-u`.
fn tmux_env_moved_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\bTMUX(?:_TMPDIR|_PANE)?\b|\benv\s+(?:-\w*[iu]\b|--unset|--ignore-environment|-(?:\s|$))").unwrap()
    })
}

/// A literal assignment that points tmux at another server (`TMUX=…`, `TMUX_TMPDIR=…`).
fn tmux_env_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\b(TMUX|TMUX_TMPDIR)=(\S*)").unwrap())
}

/// What a tmux command can do to a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TmuxKind {
    /// Puts no input into a pane.
    Safe,
    /// `respawn-pane` / `respawn-window`: `-k` kills what runs in the pane (a
    /// production shell), without it tmux refuses a live pane.
    Respawn,
    /// Puts input into the pane named by `-t` (the current pane without one).
    Pane,
    /// Puts input somewhere the guard can't tell: a buffer pasted later, or
    /// tmux commands it runs (`if-shell`, `bind-key`, `source-file`, …).
    Indirect,
}

/// Every tmux command: (name, alias, kind). tmux runs an exact name or alias,
/// else the command that a prefix names.
const TMUX_COMMANDS: &[(&str, &str, TmuxKind)] = {
    use TmuxKind::{Indirect as I, Pane as P, Respawn as R, Safe as S};
    &[
        ("attach-session", "attach", S),
        ("bind-key", "bind", I),
        ("break-pane", "breakp", S),
        ("capture-pane", "capturep", S),
        ("choose-buffer", "", I),
        ("choose-client", "", I),
        ("choose-tree", "", I),
        ("clear-history", "clearhist", S),
        ("clear-prompt-history", "clearphist", S),
        ("clock-mode", "", S),
        ("command-prompt", "", I),
        ("confirm-before", "confirm", I),
        ("copy-mode", "", S),
        ("customize-mode", "", S),
        ("delete-buffer", "deleteb", S),
        ("detach-client", "detach", S),
        ("display-menu", "menu", I),
        ("display-message", "display", S),
        ("display-panes", "displayp", I),
        ("display-popup", "popup", I),
        ("find-window", "findw", S),
        ("has-session", "has", S),
        ("if-shell", "if", I),
        ("join-pane", "joinp", S),
        ("kill-pane", "killp", S),
        ("kill-server", "", S),
        ("kill-session", "", S),
        ("kill-window", "killw", S),
        ("last-pane", "lastp", S),
        ("last-window", "last", S),
        ("link-window", "linkw", S),
        ("list-buffers", "lsb", S),
        ("list-clients", "lsc", S),
        ("list-commands", "lscm", S),
        ("list-keys", "lsk", S),
        ("list-panes", "lsp", S),
        ("list-sessions", "ls", S),
        ("list-windows", "lsw", S),
        ("load-buffer", "loadb", I),
        ("lock-client", "lockc", S),
        ("lock-server", "lock", S),
        ("lock-session", "locks", S),
        ("move-pane", "movep", S),
        ("move-window", "movew", S),
        ("new-session", "new", S),
        ("new-window", "neww", S),
        ("next-layout", "nextl", S),
        ("next-window", "next", S),
        ("paste-buffer", "pasteb", P),
        ("pipe-pane", "pipep", P),
        ("previous-layout", "prevl", S),
        ("previous-window", "prev", S),
        ("refresh-client", "refresh", S),
        ("rename-session", "rename", S),
        ("rename-window", "renamew", S),
        ("resize-pane", "resizep", S),
        ("resize-window", "resizew", S),
        ("respawn-pane", "respawnp", R),
        ("respawn-window", "respawnw", R),
        ("rotate-window", "rotatew", S),
        ("run-shell", "run", I),
        ("save-buffer", "saveb", S),
        ("select-layout", "selectl", S),
        ("select-pane", "selectp", S),
        ("select-window", "selectw", S),
        ("send-keys", "send", P),
        ("send-prefix", "", P),
        ("server-access", "", S),
        ("set-buffer", "setb", I),
        ("set-environment", "setenv", S),
        ("set-hook", "", I),
        ("set-option", "set", S),
        ("set-window-option", "setw", S),
        ("show-buffer", "showb", S),
        ("show-environment", "showenv", S),
        ("show-hooks", "", S),
        ("show-messages", "showmsgs", S),
        ("show-options", "show", S),
        ("show-prompt-history", "showphist", S),
        ("show-window-options", "showw", S),
        ("source-file", "source", S),
        ("split-window", "splitw", S),
        ("start-server", "start", S),
        ("suspend-client", "suspendc", S),
        ("swap-pane", "swapp", S),
        ("swap-window", "swapw", S),
        ("switch-client", "switchc", S),
        ("unbind-key", "unbind", S),
        ("unlink-window", "unlinkw", S),
        ("wait-for", "wait", S),
    ]
};

/// What tmux command `name` is. An exact name or alias is that command; any
/// other prefix is the most dangerous command it could name (tmux would run
/// an unambiguous one and reject the rest, so erring high only over-blocks).
/// A name that is neither may be a user `command-alias`: it can't be told.
fn tmux_kind(name: &str) -> TmuxKind {
    let name = name.to_ascii_lowercase();
    if name.is_empty() || name.starts_with('-') {
        return TmuxKind::Safe;
    }
    if let Some(&(_, _, kind)) = TMUX_COMMANDS
        .iter()
        .find(|(n, a, _)| *n == name || *a == name)
    {
        return kind;
    }
    let named = || {
        TMUX_COMMANDS
            .iter()
            .filter(|(n, _, _)| n.starts_with(name.as_str()))
            .map(|(_, _, k)| *k)
    };
    if named().any(|k| k == TmuxKind::Indirect) {
        TmuxKind::Indirect
    } else if named().any(|k| k == TmuxKind::Pane) {
        TmuxKind::Pane
    } else if named().any(|k| k == TmuxKind::Respawn) {
        TmuxKind::Respawn
    } else if named().next().is_some() {
        TmuxKind::Safe
    } else {
        TmuxKind::Indirect
    }
}

/// Could the (lowercase) tmux command word `name` be `full` or its alias?
/// Any prefix counts: erring toward "yes" only means more text is scanned.
fn could_be(name: &str, full: &str, alias: &str) -> bool {
    !name.is_empty() && (name == alias || full.starts_with(name))
}

/// The tmux commands that change nothing a later `-t` target is resolved
/// from: they only read, or put input into a pane.
fn tmux_is_stateless(full: &str) -> bool {
    full.starts_with("list-")
        || full.starts_with("show-")
        || matches!(
            full,
            "capture-pane"
                | "display-message"
                | "has-session"
                | "save-buffer"
                | "delete-buffer"
                | "clear-history"
                | "send-keys"
                | "send-prefix"
                | "paste-buffer"
                | "pipe-pane"
                | "respawn-pane"
                | "respawn-window"
                | "wait-for"
                | "display-panes"
        )
}

/// Might tmux command `name` change which pane a session, window or pane
/// index target names (`select-pane`, `kill-pane`, `swap-pane`, `new-window`,
/// `rename-session`, `source-file`, …)? Everything that isn't known to only
/// read or type counts, and so does a name tmux doesn't define (a
/// `command-alias`) and a prefix any of whose commands might.
fn tmux_changes_state(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    if name.is_empty() || name.starts_with('-') {
        return false;
    }
    if let Some(&(full, _, _)) = TMUX_COMMANDS
        .iter()
        .find(|(n, a, _)| *n == name || *a == name)
    {
        return !tmux_is_stateless(full);
    }
    let mut named = TMUX_COMMANDS
        .iter()
        .filter(|(n, _, _)| n.starts_with(name.as_str()))
        .peekable();
    named.peek().is_none() || named.any(|(n, _, _)| !tmux_is_stateless(n))
}

/// A tmux pane id (`%12`): it names one pane for as long as it lives.
fn is_pane_id(target: &str) -> bool {
    target
        .strip_prefix('%')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

/// The tmux commands that type or pipe into a pane, which `tmux` need not
/// precede for the guard to treat `<word> send-keys …` as a tmux call.
const INPUT_COMMANDS: &[&str] = &[
    "send-keys",
    "send",
    "send-prefix",
    "paste-buffer",
    "pasteb",
    "pipe-pane",
    "pipep",
    "respawn-pane",
    "respawnp",
    "respawn-window",
    "respawnw",
];

/// Does `rest` (the words after some word) start, after tmux's global
/// options, with an input command? The name must be exact, or a prefix of at
/// least four characters of a full name (`pip` is pip, not `pipe-pane`).
fn starts_with_input_command(rest: &[Word]) -> bool {
    let mut i = 0;
    while i < rest.len() && rest[i].text.starts_with('-') && rest[i].text.len() > 1 {
        let w = &rest[i];
        i += 1;
        if w.text == "--" {
            break;
        }
        let _ = option_value(w, "LSfcT", rest, &mut i);
    }
    let Some(first) = rest.get(i).filter(|w| !w.dynamic) else {
        return false;
    };
    let name = first.text.to_ascii_lowercase();
    INPUT_COMMANDS.contains(&name.as_str())
        || (name.len() >= 4
            && INPUT_COMMANDS
                .iter()
                .any(|full| full.len() > 5 && full.starts_with(name.as_str())))
}

/// A `-t` target tmux resolves from where the client is (`{next}`, `{last}`,
/// `!`, `~`, `^`, `:+1`), which the guard's probe can't reproduce.
fn relative_target(target: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    target.contains(['{', '}', '!', '~', '^'])
        || RE
            .get_or_init(|| Regex::new(r"(^|[:.])[+-]\d*$").unwrap())
            .is_match(target)
}

/// Decide whether this tool call may run.
///
/// 1. The tool name ([`RULE_TOOL_NAME`]).
/// 2. Every `command` / `cmd` / `script` string, unless it only mentions a
///    marker as data ([`inert`]: `git commit -m "… ecs_connect …"`), with quotes and backslashes
///    deleted (so `bash -c`, `eval`, here-doc bodies and `e"c"s_connect` are
///    all one searchable text), with empty expansions deleted and brace
///    alternatives written out (`ecs_${U}connect`, `ecs_{connect,}`), and word
///    by word as the shell would see it ([`RULE_COMMAND`]). A command word
///    built from expansions (`$a$b`) is blocked too. Running the output
///    of `ecs_build_command` counts.
/// 3. The text tmux `send-keys` / `paste-buffer` would type, rebuilt from the
///    arguments (`ecs_c onnect Space ap`) across all calls of the string, and
///    with the pane's pending input line ([`RULE_COMMAND`]).
/// 4. tmux input commands, whatever the binary is called: the target pane is
///    probed; a target that can't be told blocks if any pane on that server
///    (every server, when the server can't be told either) is remote
///    ([`RULE_TMUX_INPUT`]). After a state-changing tmux command in the same
///    call (`select-pane`, `kill-pane`, …) only `%N` ids can be told.
///
/// Fast path: only rule 4 does I/O, and only for text that mentions tmux or
/// has a command that can be it; anything else is decided in memory. `Err`
/// only when a probe fails where the answer matters.
pub fn evaluate(payload: &HookPayload, probe: &dyn PaneProbe) -> Result<GuardVerdict, GuardError> {
    if tool_name_re().is_match(&payload.tool_name) {
        return Ok(block(RULE_TOOL_NAME, format!("tool {}", payload.tool_name)));
    }
    let cwd = payload
        .cwd
        .as_deref()
        .filter(|c| !c.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("/"));
    for raw in command_strings(&payload.tool_input) {
        if let Some(verdict) = evaluate_command(raw, &cwd, probe)? {
            return Ok(verdict);
        }
    }
    Ok(GuardVerdict::Allow)
}

/// What the rules before tmux's make of one command string: the text in each
/// form the rules read it in.
struct Analysis {
    parsed: shell::ShellParse,
    normalized: String,
    decoded: Vec<String>,
    texts: Vec<String>,
}

/// What [`Analysis::marker`] found.
enum Marker {
    /// The command only mentions a marker, as data.
    Inert,
    /// The command is, or may be, a production shell; why.
    Blocked(String),
    Clear,
}

/// The detail given when a brace expansion went past its cap.
const TOO_LARGE_DETAIL: &str = "brace expansion too large to scan";

impl Analysis {
    /// `Err` when a brace expansion is too large to scan.
    fn of(raw: &str) -> Result<Self, TooLarge> {
        // The shell deletes a backslash-newline before it reads anything (in double
        // quotes, here-docs and unquoted text), so `$\<newline>(cmd)` is `$(cmd)`:
        // every scan reads the text with them gone.
        let joined = join_continuations(raw);
        let parsed = parse_both(raw, &joined);
        let normalized = unquote(&joined);
        // Each command's words after quote removal (resolves `$'\x65…'`).
        let words = parsed
            .commands
            .iter()
            .map(|c| c.texts().join(" "))
            .collect::<Vec<_>>()
            .join("\n");
        // The same text decoded without any tokenizer (`$'\x65cs_connect'`, `aws ecs
        // $'execute\x2dcommand'`): a `$` before a quote dropped, `\xHH`, `\NNN`, `\uXXXX`
        // and `\UXXXXXXXX` written out, quotes and backslashes deleted. It does not depend
        // on where the tokenizer is in the text, so a parse that lost its place (a `#`
        // comment, a here-doc, a `case` arm, `${…}`) hides nothing from it.
        let decoded: Vec<String> = if joined == raw {
            vec![decode_text(&joined)]
        } else {
            vec![decode_text(&joined), decode_text(raw)]
        };
        let mut bases: Vec<&str> = vec![&normalized, &words];
        bases.extend(decoded.iter().map(String::as_str));
        let texts = scan_texts(&bases)?;
        Ok(Self {
            parsed,
            normalized,
            decoded,
            texts,
        })
    }

    /// Rule 2 (and the rule 3 words that need no tmux): is `raw` a production
    /// shell, whatever tmux does with it?
    fn marker(&self, raw: &str) -> Marker {
        let (parsed, normalized, decoded, texts) =
            (&self.parsed, &self.normalized, &self.decoded, &self.texts);
        // A command that only mentions a marker, as data, is not a remote shell.
        if inert::is_inert_mention(raw, parsed) {
            return Marker::Inert;
        }
        if let Some(m) = texts.iter().find_map(|t| marker_find(t)) {
            return Marker::Blocked(format!("command matches `{m}`"));
        }
        if let Some(op) = parsed
            .commands
            .iter()
            .find_map(|c| aws_remote_shell(&c.words))
        {
            return Marker::Blocked(format!("command runs `{op}`"));
        }
        if let Some(w) = parsed
            .commands
            .iter()
            .flat_map(|c| &c.words)
            .find(|w| expand::could_spell(&w.pattern, word_markers()))
        {
            return Marker::Blocked(format!(
                "word `{}` could expand to a production-shell command",
                snippet(&w.text)
            ));
        }
        let words = parsed
            .commands
            .iter()
            .map(|c| c.texts().join(" "))
            .collect::<Vec<_>>()
            .join("\n");
        let lower = format!("{normalized}\n{words}\n{}", decoded.join("\n")).to_lowercase();
        if runs_built_command(&lower)
            || texts[2..]
                .iter()
                .any(|t| runs_built_command(&t.to_lowercase()))
        {
            return Marker::Blocked("command runs the output of `ecs_build_command`".to_owned());
        }
        Marker::Clear
    }
}

/// Does `text` start an ECS exec session, an SSM session or the session-manager
/// plugin, spell `ecs_connect` and its kin, or run the output of
/// `ecs_build_command`? Why, if so. The pure part of [`evaluate`]'s rules
/// (no tmux, no I/O), for callers that must not let a command text become a
/// production shell.
pub(crate) fn remote_shell_marker(text: &str) -> Option<String> {
    match Analysis::of(text) {
        Err(TooLarge) => Some(TOO_LARGE_DETAIL.to_owned()),
        Ok(analysis) => match analysis.marker(text) {
            Marker::Blocked(detail) => Some(detail),
            Marker::Inert | Marker::Clear => None,
        },
    }
}

/// Rules 2 to 4 for one command string.
fn evaluate_command(
    raw: &str,
    cwd: &Path,
    probe: &dyn PaneProbe,
) -> Result<Option<GuardVerdict>, GuardError> {
    let Ok(analysis) = Analysis::of(raw) else {
        return Ok(Some(block(RULE_COMMAND, TOO_LARGE_DETAIL.to_owned())));
    };
    match analysis.marker(raw) {
        Marker::Inert => return Ok(None),
        Marker::Blocked(detail) => return Ok(Some(block(RULE_COMMAND, detail))),
        Marker::Clear => {}
    }
    let Analysis {
        parsed,
        normalized,
        texts,
        ..
    } = analysis;

    let env_moved = texts.iter().any(|t| tmux_env_moved_re().is_match(t));
    let mut cwd = cwd.to_path_buf();
    let mut calls: Vec<TmuxCall> = Vec::new();
    for c in &parsed.commands {
        track_cd(c, &mut cwd);
        if let Some(at) = find_tmux(c, &cwd) {
            calls.push(tmux_call(c, at, env_moved));
        } else if let Some(w) = shell::command_word_index(&c.words)
            .map(|i| &c.words[i])
            .filter(|w| built_from_expansions(w))
        {
            // `a=ecs_; b=connect; $a$b`: assigned values are not tracked, so a
            // command word built from expansions is not run blind.
            return Ok(Some(block(
                RULE_COMMAND,
                format!(
                    "command word `{}` is built from expansions the guard can't evaluate",
                    snippet(&w.text)
                ),
            )));
        }
    }
    // A tmux (or a tmux command) the tokenizer didn't see as a command (an
    // interpreter's string, a script being written, a parse failure) may be
    // aimed anywhere. Count in every form: `$'\x74mux'` is tmux only after
    // quote removal, `ecs_{x,}` only after brace expansion.
    let count = |re: &Regex| {
        texts
            .iter()
            // A tmux config file's name (`~/.tmux.conf`) is not another tmux.
            .map(|t| {
                re.find_iter(&tmux_config_name_re().replace_all(t, ""))
                    .count()
            })
            .max()
            .unwrap_or(0)
    };
    let named_calls: usize = calls.iter().map(|c| c.named).sum();
    let parsed_verbs = parsed
        .commands
        .iter()
        .flat_map(|c| &c.words)
        .filter(|w| INPUT_COMMANDS.contains(&w.text.to_ascii_lowercase().as_str()))
        .count();
    let opaque = parsed.unparsed
        || count(tmux_mention_re()) > named_calls
        || count(tmux_verb_re()) > parsed_verbs;
    if calls.is_empty() && !opaque {
        return Ok(None);
    }
    let typed = TypedText::of(&calls);
    if let Some(detail) = typed_marker(&typed) {
        return Ok(Some(block(RULE_COMMAND, detail)));
    }
    tmux_rule(&normalized, &calls, opaque, typed.keys.cant_tell(), probe)
}

/// A command word with an expansion in it and more than that (`$a$b`,
/// `${a}ect`): not a lone `$EDITOR` and not a path (`$HOME/bin/x`).
fn built_from_expansions(word: &Word) -> bool {
    word.dynamic && !word.pattern.contains('/') && word.pattern != shell::WILDCARD.to_string()
}

fn block(rule_id: &'static str, detail: String) -> GuardVerdict {
    GuardVerdict::Block { rule_id, detail }
}

/// `text` with each line continuation (a backslash that is not itself escaped,
/// then a newline) deleted, as the shell does.
fn join_continuations(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('\n') => {
                chars.next();
            }
            // An escaped backslash: the next one can't start a continuation.
            Some('\\') => {
                out.push_str("\\\\");
                chars.next();
            }
            _ => out.push('\\'),
        }
    }
    out
}

/// The commands of `raw`, read with its line continuations removed (`joined`)
/// and as written. They differ where a shell does not join (a `#` comment, a
/// quoted here-doc body: `echo # \<newline>$'\x65cs_connect'` runs the second
/// line), so the commands either reading finds count.
fn parse_both(raw: &str, joined: &str) -> shell::ShellParse {
    let mut parsed = shell::parse(joined);
    if joined != raw {
        let as_written = shell::parse(raw);
        let owned = |c: &shell::SimpleCommand| -> Vec<String> {
            c.texts().into_iter().map(str::to_owned).collect()
        };
        let mut seen: HashSet<Vec<String>> = parsed.commands.iter().map(owned).collect();
        for c in as_written.commands {
            if seen.insert(owned(&c)) {
                parsed.commands.push(c);
            }
        }
        parsed.unparsed |= as_written.unparsed;
        parsed.expanding_heredoc |= as_written.expanding_heredoc;
    }
    parsed
}

/// `text` as a shell would decode it before it reads a word, with no regard for
/// quoting or where a command starts: a `$` right before a quote is dropped
/// (`$'x'`, `$"x"`), `\xHH`, `\NNN` (octal), `\uXXXX` and `\UXXXXXXXX` are the
/// character they name, and quotes and the remaining backslashes are deleted
/// (`'ec''s_connect'`, `"ecs_"connect`, `''`). Only ever scanned in addition
/// to the text as written.
fn decode_text(text: &str) -> String {
    let c: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < c.len() {
        match c[i] {
            '$' if matches!(c.get(i + 1), Some('\'' | '"')) => i += 1,
            '\'' | '"' => i += 1,
            '\\' => {
                let (radix, max, skip) = match c.get(i + 1) {
                    Some('x') => (16, 2, 2),
                    Some('u') => (16, 4, 2),
                    Some('U') => (16, 8, 2),
                    Some('0'..='7') => (8, 3, 1),
                    // An escaped backslash or quote: both go.
                    Some('\\' | '\'' | '"') => {
                        i += 2;
                        continue;
                    }
                    _ => {
                        i += 1;
                        continue;
                    }
                };
                let digits: String = c[i + skip..]
                    .iter()
                    .take(max)
                    .take_while(|d| d.is_digit(radix))
                    .collect();
                match u32::from_str_radix(&digits, radix)
                    .ok()
                    .and_then(char::from_u32)
                {
                    Some(ch) if !digits.is_empty() => {
                        out.push(ch);
                        i += skip + digits.len();
                    }
                    _ => i += 1,
                }
            }
            ch => {
                out.push(ch);
                i += 1;
            }
        }
    }
    out
}

/// `text` with quotes and backslashes deleted.
fn unquote(text: &str) -> String {
    text.chars()
        .filter(|c| !matches!(c, '\'' | '"' | '\\'))
        .collect()
}

/// A matched snippet for a log line: at most 120 characters.
fn snippet(text: &str) -> String {
    let mut s: String = text
        .trim_matches(|c: char| !c.is_alphanumeric())
        .chars()
        .take(120)
        .collect();
    if text.chars().count() > 120 {
        s.push('…');
    }
    s
}

/// The first marker in `text`, as a snippet.
fn marker_find(text: &str) -> Option<String> {
    command_re().find(text).map(|m| snippet(m.as_str()))
}

/// A brace expansion went past a cap.
struct TooLarge;

/// `bases` themselves, then the texts a shell could build from them (empty
/// expansions deleted, brace alternatives written out). `Err` past the caps.
fn scan_texts(bases: &[&str]) -> Result<Vec<String>, TooLarge> {
    let mut out: Vec<String> = bases.iter().map(|b| (*b).to_owned()).collect();
    for base in bases {
        let expanded = expand::expanded_texts(base);
        if expanded.overflow {
            return Err(TooLarge);
        }
        out.extend(expanded.texts);
    }
    Ok(out)
}

/// The marker in typed or pending text (the pane's shell reads it as a command line).
fn marker_in_typed(text: &str) -> Option<String> {
    match scan_texts(&[&unquote(text), &decode_text(text)]) {
        Ok(texts) => texts.iter().find_map(|t| marker_find(t)),
        Err(TooLarge) => Some("brace expansion too large to scan".to_owned()),
    }
}

/// Every top-level string field named `command`, `cmd` or `script`.
fn command_strings(input: &Value) -> Vec<&str> {
    let Some(obj) = input.as_object() else {
        return Vec::new();
    };
    ["command", "cmd", "script"]
        .iter()
        .filter_map(|k| obj.get(*k).and_then(Value::as_str))
        .collect()
}

/// `aws … ecs … execute-command` (and `ssm … start-session`, `ecs … run-task`)
/// in one command's words, whatever global options sit between them. Also the
/// operation word after a word that could be the service (`aws $S execute-command`).
fn aws_remote_shell(words: &[Word]) -> Option<String> {
    let lower: Vec<String> = words.iter().map(|w| w.text.to_ascii_lowercase()).collect();
    let mut ops = vec![("ecs", "execute-command"), ("ssm", "start-session")];
    if BLOCK_RUN_TASK {
        ops.push(("ecs", "run-task"));
    }
    ops.into_iter().find_map(|(service, op)| {
        let service_before = |op_at: usize| {
            lower[..op_at].iter().zip(words).any(|(w, word)| {
                w == service
                    || (word.pattern.contains(shell::WILDCARD)
                        && expand::wild_match(&word.pattern, service))
            })
        };
        let found = lower
            .iter()
            .enumerate()
            .any(|(at, w)| w == op && service_before(at));
        found.then(|| format!("{service} {op}"))
    })
}

/// Commands that only show their input; piping the built command into one is fine.
const VIEWERS: &[&str] = &[
    "pbcopy", "cat", "less", "more", "head", "tail", "grep", "wc",
];

/// `lower` runs what `ecs_build_command` prints (the full `aws ecs
/// execute-command …` line): inside `$( )`, backticks or a process
/// substitution (so `eval`, `source <( )` and `bash -c "$( )"`), or piped
/// into anything but a viewer.
fn runs_built_command(lower: &str) -> bool {
    lower.match_indices("ecs_build_command").any(|(at, name)| {
        let before = &lower[..at];
        if ["$(", "`", "<(", ">("].iter().any(|s| before.contains(s)) {
            return true;
        }
        // `||` passes no output; `|&` is a pipe.
        let after = lower[at + name.len()..]
            .replace("||", ";")
            .replace("|&", "|");
        // Every later pipe stage must be a viewer (a pipe into nothing visible,
        // as at a line end, counts as running it).
        after.contains(">(")
            || after.split('|').skip(1).any(|stage| {
                stage
                    .split_whitespace()
                    .next()
                    .is_none_or(|first| !VIEWERS.contains(&shell::basename(first)))
            })
    })
}

/// Where to look for remote panes when the target can't be told.
type Scope = Option<TmuxSocket>;

/// One tmux command that can put input into a pane.
struct TmuxInput {
    /// `Some(target)` with a literal `-t`; `None` when it can't be told.
    target: Option<String>,
    /// For `send-keys`: the keys it types.
    keys: Vec<Key>,
}

/// One tmux command of a call that isn't known to be harmless.
struct Sub {
    /// Lowercase command name as written (it may be an alias or a prefix).
    name: String,
    args: Vec<Word>,
}

/// One `tmux` invocation (whatever the binary is called).
struct TmuxCall {
    /// `None`: the server can't be told (`-L "$S"`, a `TMUX=` assignment, …).
    socket: Scope,
    inputs: Vec<TmuxInput>,
    subs: Vec<Sub>,
    /// A command of this call may change which pane a session / window target
    /// names (`select-pane`, `kill-pane`, `new-window`, an unknown name, …).
    changes_state: bool,
    /// How many times the binary's word (once its empty expansions and brace
    /// alternatives are written out) says `tmux`: the text count already has them.
    named: usize,
}

/// What the commands of all calls type, as the pane's shell reads it: `send-keys`
/// keys and pasted buffers, in order.
struct TypedText {
    keys: keys::Typed,
    /// Every buffer's final text (`set-buffer`), which `paste-buffer` may type.
    buffers: Vec<String>,
}

impl TypedText {
    fn of(calls: &[TmuxCall]) -> Self {
        let mut buffers = Buffers::default();
        let mut typed: Vec<Key> = Vec::new();
        for sub in calls.iter().flat_map(|c| &c.subs) {
            let name = sub.name.as_str();
            if typed.len() > keys::MAX_TYPED {
                // Too much to follow (`send-keys -N` in many calls): the rest can't be told.
                typed.truncate(keys::MAX_TYPED);
                typed.push(Key::Unknown);
                break;
            }
            if could_be(name, "send-keys", "send") {
                typed.extend(keys::send_keys(&sub.args));
            }
            if could_be(name, "set-buffer", "setb") {
                buffers.set(&sub.args);
            }
            if could_be(name, "paste-buffer", "pasteb") {
                if let Some(text) = buffers.pasted(&sub.args) {
                    typed.extend(keys::keys_of_text(text));
                }
            }
        }
        Self {
            keys: keys::type_keys(&typed),
            buffers: buffers.contents().map(str::to_owned).collect(),
        }
    }
}

/// A marker in what the calls type, wherever the text goes (rule 3).
fn typed_marker(typed: &TypedText) -> Option<String> {
    let found = typed
        .keys
        .texts()
        .into_iter()
        .chain(typed.buffers.iter().map(String::as_str))
        .find_map(marker_in_typed);
    if let Some(m) = found {
        return Some(format!(
            "keys sent to tmux spell a production-shell command ({m})"
        ));
    }
    // Text typed along with a key that rearranges it in a way the line editor
    // doesn't apply (`connect M-b ecs_`): the line can't be told, so text that
    // could still be reordered into a marker is blocked.
    if typed.keys.cant_tell() && keys::could_spell_marker(&typed.keys.joined, word_markers()) {
        return Some(
            "keys sent to tmux mix text that could spell a production-shell command with a key the guard can't apply or read (`M-b`, `C-y`, `0x…`, `-H` …)"
                .to_owned(),
        );
    }
    // A Tab after the start of `ecs_connect` lets the shell finish the word.
    typed.keys.tab_words.iter().find_map(|w| {
        let w = w.to_ascii_lowercase();
        let starts = |m: &&str| {
            (m.starts_with("ecs_") || m.starts_with("session-")) && m.starts_with(w.as_str())
        };
        (w.len() >= 5 && word_markers().iter().any(starts)).then(|| {
            format!("a Tab after `{w}` lets the shell complete a production-shell command")
        })
    })
}

/// The marker that `typed` completes together with `pending` (the pane's
/// prompt line): one that neither part spells alone.
fn completes_marker(pending: &str, typed: &keys::Typed) -> Option<String> {
    typed.texts().into_iter().find_map(|text| {
        // A trailing space on the prompt line is trimmed by tmux: try it both ways.
        [pending.to_owned(), format!("{pending} ")]
            .iter()
            .find_map(|p| {
                let joined = marker_in_typed(&format!("{p}{text}"))?;
                (marker_in_typed(p).is_none() && marker_in_typed(text).is_none()).then_some(joined)
            })
    })
}

/// Why a tmux input can't be aimed, for the block's detail: completes "tmux
/// input aimed at …".
type Why = String;

/// Rule 4: tmux input aimed at a remote pane. `None` when nothing is remote.
/// `inexact`: the keys of the calls include one the line editor can't apply
/// next to typed text, or one the guard can't read as tmux does, so what the
/// pane's shell reads can't be told.
fn tmux_rule(
    normalized: &str,
    calls: &[TmuxCall],
    opaque: bool,
    inexact: bool,
    probe: &dyn PaneProbe,
) -> Result<Option<GuardVerdict>, GuardError> {
    // Scopes to check whole (`None` is every server), and why each is.
    let mut cant_tell: Vec<(Scope, Why)> = Vec::new();
    if opaque {
        cant_tell.push((
            None,
            "tmux called from text the guard can't read as a tmux command".to_owned(),
        ));
    }
    // One earlier command in the call can change what `-t prod` names (the
    // pane `select-pane` made active): only `%N` pane ids stay put.
    let state_changed = calls.iter().any(|c| c.changes_state);
    for call in calls {
        if inexact && call.inputs.iter().any(|i| !i.keys.is_empty()) {
            cant_tell.push((
                call.socket.clone(),
                "keys mixing typed text with an editing key the guard can't apply (`M-b`, `C-y`, `C-t`, …), or a key it can't read (`0x…`, `-H` …)".to_owned(),
            ));
        }
        for input in &call.inputs {
            // Without a literal target and a known server there is nothing to probe;
            // a relative target (`{next}`) is resolved from where the agent is.
            let (Some(target), Some(socket)) = (&input.target, &call.socket) else {
                cant_tell.push((call.socket.clone(), "a target or server the guard can't tell (no `-t`, a `$VAR`, or an unknown server)".to_owned()));
                continue;
            };
            if relative_target(target) {
                cant_tell.push((
                    Some(socket.clone()),
                    format!("`{target}`, a relative target tmux resolves from where the client is"),
                ));
                continue;
            }
            if state_changed && !is_pane_id(target) {
                cant_tell.push((
                    Some(socket.clone()),
                    format!("`{target}`, which another tmux command in the same call may have moved (only `%N` pane ids stay put)"),
                ));
                continue;
            }
            match probe.pane(socket, target) {
                Ok(Some(pane)) => match is_remote(&pane, probe) {
                    Ok(true) => {
                        return Ok(Some(block(
                            RULE_TMUX_INPUT,
                            format!("tmux input to remote pane {target} ({})", pane.title),
                        )))
                    }
                    Ok(false) => {
                        if let Some(detail) = completes_pending_input(input, socket, target, probe)
                        {
                            return Ok(Some(block(RULE_COMMAND, detail)));
                        }
                    }
                    Err(_) => cant_tell.push((
                        Some(socket.clone()),
                        format!("`{target}`, whose process tree could not be inspected"),
                    )),
                },
                Ok(None) => cant_tell.push((
                    Some(socket.clone()),
                    format!("`{target}`, which could not be resolved on this tmux server"),
                )),
                Err(_) => cant_tell.push((
                    Some(socket.clone()),
                    format!("`{target}`, which could not be looked up"),
                )),
            }
        }
    }
    any_remote_pane(&cant_tell, &socket_dirs(normalized), probe)
}

/// A `send-keys` into a local pane that finishes a marker the pane's prompt
/// line already holds (`ecs_` then, in another tool call, `connect`). Best
/// effort: a pane that can't be read counts as nothing pending.
fn completes_pending_input(
    input: &TmuxInput,
    socket: &TmuxSocket,
    target: &str,
    probe: &dyn PaneProbe,
) -> Option<String> {
    let typed = keys::type_keys(&input.keys);
    if !typed
        .texts()
        .iter()
        .any(|t| t.chars().any(|c| !c.is_whitespace()))
    {
        return None;
    }
    let pending = probe.pending_input(socket, target).ok().flatten()?;
    completes_marker(&pending, &typed).map(|m| {
        format!(
            "keys sent to {target} finish a production-shell command the pane already holds ({m})"
        )
    })
}

/// The tmux socket directories named by literal `TMUX_TMPDIR=` / `TMUX=`
/// assignments in the text, beyond the ones the probe already knows.
fn socket_dirs(normalized: &str) -> Vec<PathBuf> {
    // SAFETY: getuid(2) has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    tmux_env_re()
        .captures_iter(normalized)
        .filter_map(|c| {
            let value = c.get(2)?.as_str();
            if value.is_empty() || value.contains('$') {
                return None;
            }
            match &c[1] {
                "TMUX_TMPDIR" => Some(Path::new(value).join(format!("tmux-{uid}"))),
                _ => Path::new(value.split(',').next()?)
                    .parent()
                    .map(Path::to_path_buf),
            }
        })
        .collect()
}

/// Block if any pane in any of `scopes` is remote (the target can't be told).
fn any_remote_pane(
    scopes: &[(Scope, Why)],
    extra_dirs: &[PathBuf],
    probe: &dyn PaneProbe,
) -> Result<Option<GuardVerdict>, GuardError> {
    // Every server a scope names, and the first reason it is checked.
    let mut sockets: Vec<(TmuxSocket, &str)> = scopes
        .iter()
        .filter_map(|(s, why)| s.clone().map(|s| (s, why.as_str())))
        .collect();
    if let Some((_, why)) = scopes.iter().find(|(s, _)| s.is_none()) {
        sockets.extend(
            probe
                .servers(extra_dirs)?
                .into_iter()
                .map(|s| (s, why.as_str())),
        );
    }
    let mut checked: Vec<&TmuxSocket> = Vec::new();
    for (socket, why) in &sockets {
        if checked.contains(&socket) {
            continue;
        }
        checked.push(socket);
        for pane in probe.all_panes(socket)? {
            if is_remote(&pane, probe)? {
                return Ok(Some(block(
                    RULE_TMUX_INPUT,
                    format!(
                        "tmux input aimed at {why}, while a remote pane is open ({})",
                        pane.title
                    ),
                )));
            }
        }
    }
    Ok(None)
}

fn is_remote(pane: &PaneInfo, probe: &dyn PaneProbe) -> Result<bool, ProbeError> {
    if remote_title_re().is_match(&pane.title) {
        return Ok(true);
    }
    Ok(probe
        .subtree_args(pane.pid)?
        .iter()
        .any(|a| remote_process_re().is_match(a)))
}

/// Follow a literal `cd` / `pushd`, so a relative command word is looked up
/// where the shell would look.
fn track_cd(cmd: &SimpleCommand, cwd: &mut PathBuf) {
    let Some(at) = shell::command_word_index(&cmd.words) else {
        return;
    };
    if !matches!(shell::basename(&cmd.words[at].text), "cd" | "pushd") {
        return;
    }
    if let Some(arg) = cmd.words[at + 1..]
        .iter()
        .find(|a| !a.text.starts_with('-'))
        .filter(|a| !a.dynamic)
    {
        let p = Path::new(&arg.text);
        *cwd = if p.is_absolute() {
            p.to_path_buf()
        } else {
            cwd.join(p)
        };
    }
}

/// The index of the word that is tmux in `cmd`: the word `tmux` (any case,
/// any path); else a word that is the tmux binary under another name (a glob
/// or expansion that can be `tmux`, a path that resolves to the real one, a
/// brace expansion); else a word followed by an input command (`/tmp/t
/// send-keys …`), whatever the binary is called.
fn find_tmux(cmd: &SimpleCommand, cwd: &Path) -> Option<usize> {
    let words = &cmd.words;
    if let Some(at) = words
        .iter()
        .position(|w| shell::basename(&w.text).eq_ignore_ascii_case("tmux"))
    {
        return Some(at);
    }
    let command_at = shell::command_word_index(words);
    words.iter().enumerate().position(|(i, w)| {
        let command = command_at == Some(i);
        ((command || w.text.contains('/')) && tmux_bin::looks_like_tmux(w, cwd, command))
            || starts_with_input_command(&words[i + 1..])
    })
}

/// The tmux invocation in `cmd` whose binary is the word at `at`.
/// `env_moved`: the text reassigns `TMUX` / `TMUX_TMPDIR` / `TMUX_PANE`, so the
/// default and `-L` servers can't be told.
fn tmux_call(cmd: &SimpleCommand, at: usize, env_moved: bool) -> TmuxCall {
    let spelled = expand::strip_empty_expansions(&cmd.words[at].text);
    let named = expand::brace_alternatives(&spelled).map_or(0, |alts| {
        tmux_mention_re().find_iter(&alts.join(" ")).count()
    });
    let words = &cmd.words[at + 1..];
    let mut socket = (!env_moved).then_some(TmuxSocket::Default);
    let mut i = 0;
    // Global options: `-L name`, `-S path`, `-f file`, `-c cmd`, `-T features`, flags.
    while i < words.len() && words[i].text.starts_with('-') && words[i].text.len() > 1 {
        let w = &words[i];
        i += 1;
        if w.text == "--" {
            break;
        }
        if let Some((flag, value, dynamic)) = option_value(w, "LSfcT", words, &mut i) {
            match flag {
                'L' | 'S' if dynamic => socket = None,
                'L' if env_moved => socket = None,
                'L' => socket = Some(TmuxSocket::Name(value)),
                'S' if Path::new(&value) == default_socket() => socket = Some(TmuxSocket::Default),
                'S' => socket = Some(TmuxSocket::Path(value)),
                _ => {}
            }
        }
    }
    let mut inputs = Vec::new();
    let mut subs = Vec::new();
    let mut changes_state = false;
    for sub in split_tmux_commands(&words[i..]) {
        let Some((name, args)) = sub.split_first() else {
            continue;
        };
        changes_state |= name.dynamic || tmux_changes_state(&name.text);
        // A `command-alias` change can make any name (even `ls`) an input command.
        let sets_alias = args
            .iter()
            .any(|a| a.text.to_ascii_lowercase().contains("command-alias"));
        let mut kind = if name.dynamic || sets_alias {
            TmuxKind::Indirect
        } else {
            tmux_kind(&name.text)
        };
        if kind == TmuxKind::Respawn {
            kind = if respawn_kills(args) {
                TmuxKind::Pane
            } else {
                TmuxKind::Safe
            };
        }
        if kind == TmuxKind::Safe {
            continue;
        }
        let mut target: Option<Option<String>> = None;
        let mut j = 0;
        while j < args.len() && args[j].text.starts_with('-') && args[j].text.len() > 1 {
            let w = &args[j];
            j += 1;
            if w.text == "--" {
                break;
            }
            if let Some(('t', value, dynamic)) = option_value(w, "bcNnst", args, &mut j) {
                target = Some((!dynamic && !value.is_empty()).then_some(value));
            }
        }
        let lname = name.text.to_ascii_lowercase();
        let keys = if could_be(&lname, "send-keys", "send") {
            keys::send_keys(args)
        } else {
            Vec::new()
        };
        inputs.push(TmuxInput {
            target: if kind == TmuxKind::Indirect {
                None
            } else {
                target.flatten()
            },
            keys,
        });
        subs.push(Sub {
            name: lname,
            args: args.to_vec(),
        });
    }
    TmuxCall {
        socket,
        inputs,
        subs,
        changes_state,
        named,
    }
}

/// Does this `respawn-pane` / `respawn-window` carry `-k` (kill what runs in the pane)?
fn respawn_kills(args: &[Word]) -> bool {
    let mut j = 0;
    while j < args.len() && args[j].text.starts_with('-') && args[j].text.len() > 1 {
        let w = &args[j].text;
        j += 1;
        if w == "--" {
            break;
        }
        for (k, c) in w[1..].char_indices() {
            if c == 'k' {
                return true;
            }
            // `-c dir`, `-e env`, `-t target`: the rest of the word or the next one is its value.
            if "cet".contains(c) {
                if k + 2 == w.len() {
                    j += 1;
                }
                break;
            }
        }
    }
    false
}

/// In the short-option cluster `opt` (`-lt`), the first option in
/// `with_arg`, its value (the rest of the cluster, else the next word, which
/// `next` then skips) and whether that value holds an unexpanded variable.
fn option_value(
    opt: &Word,
    with_arg: &str,
    words: &[Word],
    next: &mut usize,
) -> Option<(char, String, bool)> {
    let cluster = &opt.text[1..];
    let (k, c) = cluster
        .char_indices()
        .find(|(_, c)| with_arg.contains(*c))?;
    let rest = &cluster[k + c.len_utf8()..];
    if !rest.is_empty() {
        return Some((c, rest.to_owned(), opt.dynamic));
    }
    let value = words.get(*next);
    *next += 1;
    Some((
        c,
        value.map(|w| w.text.clone()).unwrap_or_default(),
        value.is_some_and(|w| w.dynamic),
    ))
}

/// Split tmux's arguments into commands at `;` (a word `;` or a trailing `;`).
fn split_tmux_commands(words: &[Word]) -> Vec<Vec<Word>> {
    let mut out = vec![Vec::new()];
    for w in words {
        if w.text == ";" {
            out.push(Vec::new());
        } else if let Some(stripped) = w.text.strip_suffix(';').filter(|s| !s.ends_with('\\')) {
            out.last_mut().unwrap().push(Word {
                text: stripped.to_owned(),
                ..w.clone()
            });
            out.push(Vec::new());
        } else {
            out.last_mut().unwrap().push(w.clone());
        }
    }
    out
}

/// The hook's stdout on a block (contract §5).
pub fn deny_output_json() -> String {
    serde_json::json!({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": GUARD_MESSAGE,
        }
    })
    .to_string()
}

/// The inline `--settings` JSON that installs the guard as a PreToolUse hook
/// in a session (contract §5, exact bytes). The path is single-quote-escaped,
/// and a guard that can't run exits 2, which blocks the call (fail closed).
pub fn hook_settings_json(guard_path: &Path) -> String {
    let quoted = format!("'{}'", guard_path.to_string_lossy().replace('\'', r"'\''"));
    let command =
        format!("{quoted} pre-tool-use || {{ echo \"{FAIL_CLOSED_MESSAGE}\" >&2; exit 2; }}");
    let command = serde_json::to_string(&command).expect("a string serializes");
    format!(
        r#"{{"disableAllHooks":false,"hooks":{{"PreToolUse":[{{"matcher":"*","hooks":[{{"type":"command","command":{command},"timeout":30}}]}}]}}}}"#
    )
}

/// The guard binary: `NOSTROMO_GUARD_BIN`, else `nostromo-guard` beside the
/// canonicalized current exe, else beside the current exe as invoked, else
/// [`GUARD_SENTINEL_PATH`].
pub fn resolve_guard_path() -> PathBuf {
    if let Some(p) = std::env::var_os(GUARD_BIN_ENV).filter(|p| !p.is_empty()) {
        return PathBuf::from(p);
    }
    let beside = |exe: PathBuf| {
        exe.parent()
            .map(|d| d.join("nostromo-guard"))
            .filter(|p| p.is_file())
    };
    if let Ok(exe) = std::env::current_exe() {
        if let Some(p) = exe.canonicalize().ok().and_then(beside) {
            return p;
        }
        if let Some(p) = beside(exe) {
            return p;
        }
    }
    PathBuf::from(GUARD_SENTINEL_PATH)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One server (the default one) with a local pane `%0` and a remote pane `%1`.
    struct OneServer;

    impl PaneProbe for OneServer {
        fn pane(&self, socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
            Ok(
                (*socket == TmuxSocket::Default && target == "%0").then(|| PaneInfo {
                    pid: 1,
                    title: "zsh".into(),
                }),
            )
        }
        fn all_panes(&self, socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
            Ok(if *socket == TmuxSocket::Default {
                vec![
                    PaneInfo {
                        pid: 1,
                        title: "zsh".into(),
                    },
                    PaneInfo {
                        pid: 2,
                        title: "production:ap:portal".into(),
                    },
                ]
            } else {
                Vec::new()
            })
        }
        fn subtree_args(&self, _pid: u32) -> Result<Vec<String>, ProbeError> {
            Ok(Vec::new())
        }
        fn servers(&self, _extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
            Ok(vec![TmuxSocket::Default])
        }
    }

    fn verdict(command: &str) -> GuardVerdict {
        let payload = HookPayload {
            tool_name: "Bash".into(),
            tool_input: serde_json::json!({ "command": command }),
            session_id: None,
            tool_use_id: None,
            permission_mode: None,
            cwd: Some("/".into()),
            hook_event_name: None,
        };
        evaluate(&payload, &OneServer).expect("no probe error")
    }

    #[test]
    fn an_explicit_dash_s_naming_the_default_socket_is_the_default_server() {
        let default = default_socket();
        let command = format!(
            "tmux -S {} send-keys -t %0 'cargo test' Enter",
            default.display()
        );
        assert_eq!(verdict(&command), GuardVerdict::Allow, "{command}");
        // Another socket is another server: %0 does not exist there, and nothing there is remote.
        assert_eq!(
            verdict("tmux -S /tmp/other.sock send-keys -t %0 x"),
            GuardVerdict::Allow
        );
    }
}
