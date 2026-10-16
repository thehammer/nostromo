//! The production-shell guard (design contract §5).
//!
//! Agents may not open a remote ECS/SSM shell, nor type into a tmux pane that
//! runs one. [`evaluate`] decides from the PreToolUse hook payload and a
//! [`PaneProbe`] alone: no config file, env switch, permission mode or rule
//! list can turn a block into an allow.

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{mpsc, OnceLock};
use std::time::Duration;

use regex::Regex;
use serde::Deserialize;
use serde_json::Value;

use super::shell::{self, ShellParse, SimpleCommand, Word};

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

    fn tmux(socket: &TmuxSocket, args: &[&str]) -> Command {
        let mut cmd = Command::new(tmux_program());
        match socket {
            TmuxSocket::Default => {}
            TmuxSocket::Name(n) => {
                cmd.arg("-L").arg(n);
            }
            TmuxSocket::Path(p) => {
                cmd.arg("-S").arg(p);
            }
        }
        cmd.args(args);
        cmd
    }

    /// Run a tmux query. `Ok(None)` when tmux is missing, no server answers or
    /// the target doesn't exist.
    fn query(socket: &TmuxSocket, args: &[&str]) -> Result<Option<String>, ProbeError> {
        let mut cmd = Self::tmux(socket, args);
        let label = format!("tmux {}", args.first().copied().unwrap_or_default());
        let out = match run_with_timeout(&mut cmd, &label) {
            Err(ProbeError::Failed { message, .. }) if message.contains("No such file") => return Ok(None),
            r => r?,
        };
        if out.status.success() {
            return Ok(Some(String::from_utf8_lossy(&out.stdout).into_owned()));
        }
        let stderr = String::from_utf8_lossy(&out.stderr);
        let absent = ["no server running", "error connecting", "No such file or directory", "can't find", "no current"];
        if absent.iter().any(|m| stderr.contains(m)) {
            return Ok(None);
        }
        Err(ProbeError::Failed { command: label, message: stderr.trim().to_owned() })
    }

    fn processes(&self) -> Result<&ProcessTable, ProbeError> {
        self.processes
            .get_or_init(|| {
                let mut cmd = Command::new("/bin/ps");
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
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/opt/local/bin/tmux", "/run/current-system/sw/bin/tmux"]
        .into_iter()
        .find(|p| Path::new(p).is_file())
        .unwrap_or("tmux")
}

/// tmux's socket directory: `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`.
fn tmux_socket_dir() -> PathBuf {
    let base = std::env::var_os("TMUX_TMPDIR").filter(|d| !d.is_empty()).unwrap_or_else(|| "/tmp".into());
    // SAFETY: getuid(2) has no preconditions and cannot fail.
    PathBuf::from(base).join(format!("tmux-{}", unsafe { libc::getuid() }))
}

fn parse_pane_line(line: &str) -> Option<PaneInfo> {
    let (pid, title) = line.split_once(' ')?;
    Some(PaneInfo { pid: pid.trim().parse().ok()?, title: title.to_owned() })
}

impl PaneProbe for SystemPaneProbe {
    fn pane(&self, socket: &TmuxSocket, target: &str) -> Result<Option<PaneInfo>, ProbeError> {
        let out = Self::query(socket, &["display-message", "-p", "-t", target, PANE_FORMAT])?;
        Ok(out.and_then(|o| o.lines().next().and_then(parse_pane_line)))
    }

    fn all_panes(&self, socket: &TmuxSocket) -> Result<Vec<PaneInfo>, ProbeError> {
        let out = Self::query(socket, &["list-panes", "-a", "-F", PANE_FORMAT])?;
        Ok(out.map(|o| o.lines().filter_map(parse_pane_line).collect()).unwrap_or_default())
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

    fn servers(&self, extra_dirs: &[PathBuf]) -> Result<Vec<TmuxSocket>, ProbeError> {
        use std::os::unix::fs::FileTypeExt;
        let mut out = vec![TmuxSocket::Default];
        for dir in std::iter::once(tmux_socket_dir()).chain(extra_dirs.iter().cloned()) {
            let entries = match std::fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(ProbeError::Failed { command: format!("listing {}", dir.display()), message: e.to_string() }),
            };
            for entry in entries.flatten() {
                if entry.file_type().is_ok_and(|t| t.is_socket()) {
                    out.push(TmuxSocket::Path(entry.path().to_string_lossy().into_owned()));
                }
            }
        }
        Ok(out)
    }
}

/// Run `cmd` (stdin closed, output captured), killing it after [`PROBE_TIMEOUT`].
fn run_with_timeout(cmd: &mut Command, label: &str) -> Result<Output, ProbeError> {
    let failed = |e: std::io::Error| ProbeError::Failed { command: label.to_owned(), message: e.to_string() };
    let child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(failed)?;
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

/// Rule 1: ECS shell tools by name, MCP tools included (`mcp__x__ecs_connect`).
fn tool_name_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        let run_task = if BLOCK_RUN_TASK { "|ecs_run_task" } else { "" };
        Regex::new(&format!("(?i)(^|__)(ecs_connect|ecs_shell|ecs_open_tmux_pane{run_task})$")).unwrap()
    })
}

/// Rule 2: command text that opens a remote shell.
fn command_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        // Global options may sit between the service and the operation
        // (`aws ecs --profile p execute-command`).
        let opts = r"\s+(?:-\S+\s+(?:[^-\s]\S*\s+)?)*";
        let run_task = if BLOCK_RUN_TASK { format!(r"|\becs_run_task\b|\becs{opts}run-task\b") } else { String::new() };
        Regex::new(&format!(
            r"(?i)\becs_connect\b|\becs_shell\b|\becs_open_tmux_pane\b|\becs{opts}execute-command\b|\bssm{opts}start-session\b|\bsession-manager-plugin\b{run_task}"
        ))
        .unwrap()
    })
}

/// A pane title set by `ecs_open_tmux_pane` (`${env}:${project}:${service}`).
fn remote_title_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)^(production|prod|demo|canada|can|ca|staging|stg|stage):").unwrap())
}

/// A process in a pane's subtree that is a remote shell.
fn remote_process_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"session-manager-plugin|\becs\s+execute-command\b|\bssm\s+start-session\b|\becs_connect\b").unwrap()
    })
}

/// `tmux` as a word in the normalized text (counts possible invocations). Any
/// case: macOS file systems are case-insensitive, so `TMUX` runs tmux too.
fn tmux_word_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\btmux\b").unwrap())
}

/// An assignment that points tmux at another server (`TMUX=…`, `TMUX_TMPDIR=…`).
fn tmux_env_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\b(TMUX|TMUX_TMPDIR)=(\S*)").unwrap())
}

/// What a tmux command can do to a pane.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TmuxKind {
    /// Puts no input into a pane.
    Safe,
    /// Puts input into the pane named by `-t` (the current pane without one).
    Pane,
    /// Puts input somewhere the guard can't tell: a buffer pasted later, or
    /// tmux commands it runs (`if-shell`, `bind-key`, `source-file`, …).
    Indirect,
}

/// Every tmux command: (name, alias, kind). tmux runs an exact name or alias,
/// else the command that a prefix names.
const TMUX_COMMANDS: &[(&str, &str, TmuxKind)] = {
    use TmuxKind::{Indirect as I, Pane as P, Safe as S};
    &[
        ("attach-session", "attach", S), ("bind-key", "bind", I), ("break-pane", "breakp", S),
        ("capture-pane", "capturep", S), ("choose-buffer", "", I), ("choose-client", "", I),
        ("choose-tree", "", I), ("clear-history", "clearhist", S), ("clear-prompt-history", "clearphist", S),
        ("clock-mode", "", S), ("command-prompt", "", I), ("confirm-before", "confirm", I),
        ("copy-mode", "", S), ("customize-mode", "", S), ("delete-buffer", "deleteb", S),
        ("detach-client", "detach", S), ("display-menu", "menu", I), ("display-message", "display", S),
        ("display-panes", "displayp", I), ("display-popup", "popup", I), ("find-window", "findw", S),
        ("has-session", "has", S), ("if-shell", "if", I), ("join-pane", "joinp", S),
        ("kill-pane", "killp", S), ("kill-server", "", S), ("kill-session", "", S),
        ("kill-window", "killw", S), ("last-pane", "lastp", S), ("last-window", "last", S),
        ("link-window", "linkw", S), ("list-buffers", "lsb", S), ("list-clients", "lsc", S),
        ("list-commands", "lscm", S), ("list-keys", "lsk", S), ("list-panes", "lsp", S),
        ("list-sessions", "ls", S), ("list-windows", "lsw", S), ("load-buffer", "loadb", I),
        ("lock-client", "lockc", S), ("lock-server", "lock", S), ("lock-session", "locks", S),
        ("move-pane", "movep", S), ("move-window", "movew", S), ("new-session", "new", S),
        ("new-window", "neww", S), ("next-layout", "nextl", S), ("next-window", "next", S),
        ("paste-buffer", "pasteb", P), ("pipe-pane", "pipep", P), ("previous-layout", "prevl", S),
        ("previous-window", "prev", S), ("refresh-client", "refresh", S), ("rename-session", "rename", S),
        ("rename-window", "renamew", S), ("resize-pane", "resizep", S), ("resize-window", "resizew", S),
        ("respawn-pane", "respawnp", S), ("respawn-window", "respawnw", S), ("rotate-window", "rotatew", S),
        ("run-shell", "run", I), ("save-buffer", "saveb", S), ("select-layout", "selectl", S),
        ("select-pane", "selectp", S), ("select-window", "selectw", S), ("send-keys", "send", P),
        ("send-prefix", "", P), ("server-access", "", S), ("set-buffer", "setb", I),
        ("set-environment", "setenv", S), ("set-hook", "", I), ("set-option", "set", S),
        ("set-window-option", "setw", S), ("show-buffer", "showb", S), ("show-environment", "showenv", S),
        ("show-hooks", "", S), ("show-messages", "showmsgs", S), ("show-options", "show", S),
        ("show-prompt-history", "showphist", S), ("show-window-options", "showw", S),
        ("source-file", "source", I), ("split-window", "splitw", S), ("start-server", "start", S),
        ("suspend-client", "suspendc", S), ("swap-pane", "swapp", S), ("swap-window", "swapw", S),
        ("switch-client", "switchc", S), ("unbind-key", "unbind", S), ("unlink-window", "unlinkw", S),
        ("wait-for", "wait", S),
    ]
};

/// What tmux command `name` is. An exact name or alias is that command; any
/// other prefix is the most dangerous command it could name (tmux would run
/// an unambiguous one and reject the rest, so erring high only over-blocks).
fn tmux_kind(name: &str) -> TmuxKind {
    let name = name.to_ascii_lowercase();
    if name.is_empty() || name.starts_with('-') {
        return TmuxKind::Safe;
    }
    if let Some(&(_, _, kind)) = TMUX_COMMANDS.iter().find(|(n, a, _)| *n == name || *a == name) {
        return kind;
    }
    let named = || TMUX_COMMANDS.iter().filter(|(n, _, _)| n.starts_with(name.as_str())).map(|(_, _, k)| *k);
    if named().any(|k| k == TmuxKind::Indirect) {
        TmuxKind::Indirect
    } else if named().any(|k| k == TmuxKind::Pane) {
        TmuxKind::Pane
    } else {
        TmuxKind::Safe
    }
}

/// Some word after a `tmux` in `text` could be a tmux input command. Used
/// when tmux appears where the tokenizer can't follow it (an interpreter's
/// string, an unparsed command).
fn mentions_tmux_input(text: &str) -> bool {
    tmux_word_re().find_iter(text).any(|m| {
        text[m.end()..]
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
            .any(|w| tmux_kind(w) != TmuxKind::Safe)
    })
}

/// Decide whether this tool call may run.
///
/// 1. The tool name ([`RULE_TOOL_NAME`]).
/// 2. Every `command` / `cmd` / `script` string, with quotes and backslashes
///    deleted (so `bash -c`, `eval`, here-doc bodies and `e"c"s_connect` are
///    all one searchable text), and word by word as the shell would see it
///    ([`RULE_COMMAND`]). Running the output of `ecs_build_command` counts.
/// 3. tmux input commands: the target pane is probed; a target that can't be
///    told blocks if any pane on that server (every server, when the server
///    can't be told either) is remote ([`RULE_TMUX_INPUT`]).
///
/// Fast path: only rule 3 does I/O, and only for text that mentions `tmux`;
/// anything else is decided in memory. `Err` only when a probe fails where
/// the answer matters.
pub fn evaluate(payload: &HookPayload, probe: &dyn PaneProbe) -> Result<GuardVerdict, GuardError> {
    if tool_name_re().is_match(&payload.tool_name) {
        return Ok(block(RULE_TOOL_NAME, format!("tool {}", payload.tool_name)));
    }
    for raw in command_strings(&payload.tool_input) {
        let normalized: String = raw.chars().filter(|c| !matches!(c, '\'' | '"' | '\\')).collect();
        if let Some(m) = command_re().find(&normalized) {
            return Ok(block(RULE_COMMAND, format!("command matches `{}`", m.as_str())));
        }
        let parsed = shell::parse(raw);
        // Each command's words after quote removal (resolves `$'\x65…'`).
        let words = parsed.commands.iter().map(|c| c.texts().join(" ")).collect::<Vec<_>>().join("\n");
        if let Some(m) = command_re().find(&words) {
            return Ok(block(RULE_COMMAND, format!("command matches `{}`", m.as_str())));
        }
        if let Some(op) = parsed.commands.iter().find_map(|c| aws_remote_shell(&c.texts())) {
            return Ok(block(RULE_COMMAND, format!("command runs `{op}`")));
        }
        let lower = format!("{normalized}\n{words}").to_lowercase();
        if runs_built_command(&lower) {
            return Ok(block(RULE_COMMAND, "command runs the output of `ecs_build_command`".to_owned()));
        }
        if !lower.contains("tmux") {
            continue;
        }
        if let Some(verdict) = tmux_rule(&normalized, &parsed, probe)? {
            return Ok(verdict);
        }
    }
    Ok(GuardVerdict::Allow)
}

fn block(rule_id: &'static str, detail: String) -> GuardVerdict {
    GuardVerdict::Block { rule_id, detail }
}

/// Every top-level string field named `command`, `cmd` or `script`.
fn command_strings(input: &Value) -> Vec<&str> {
    let Some(obj) = input.as_object() else { return Vec::new() };
    ["command", "cmd", "script"].iter().filter_map(|k| obj.get(*k).and_then(Value::as_str)).collect()
}

/// `aws … ecs … execute-command` (and `ssm … start-session`, `ecs … run-task`)
/// in one command's words, whatever global options sit between them.
fn aws_remote_shell(words: &[&str]) -> Option<String> {
    let lower: Vec<String> = words.iter().map(|w| w.to_ascii_lowercase()).collect();
    let mut ops = vec![("ecs", "execute-command"), ("ssm", "start-session")];
    if BLOCK_RUN_TASK {
        ops.push(("ecs", "run-task"));
    }
    ops.into_iter().find_map(|(service, op)| {
        let at = lower.iter().position(|w| w == service)?;
        lower[at + 1..].iter().any(|w| w == op).then(|| format!("{service} {op}"))
    })
}

/// Commands that only show their input; piping the built command into one is fine.
const VIEWERS: &[&str] = &["pbcopy", "cat", "less", "more", "head", "tail", "grep", "wc"];

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
        let after = lower[at + name.len()..].replace("||", ";").replace("|&", "|");
        // Every later pipe stage must be a viewer (a pipe into nothing visible,
        // as at a line end, counts as running it).
        after.contains(">(")
            || after.split('|').skip(1).any(|stage| {
                stage.split_whitespace().next().is_none_or(|first| !VIEWERS.contains(&shell::basename(first)))
            })
    })
}

/// Where to look for remote panes when the target can't be told.
type Scope = Option<TmuxSocket>;

/// One `tmux` invocation's input commands.
struct TmuxCall {
    /// `None`: the server can't be told (`-L "$S"`, a `TMUX=` assignment, …).
    socket: Scope,
    /// `Some(target)` per input command with a literal `-t`; `None` when it can't be told.
    targets: Vec<Option<String>>,
}

/// Rule 3: tmux input aimed at a remote pane. `None` when nothing is remote.
fn tmux_rule(normalized: &str, parsed: &ShellParse, probe: &dyn PaneProbe) -> Result<Option<GuardVerdict>, GuardError> {
    let env_moved = tmux_env_re().is_match(normalized);
    let calls: Vec<TmuxCall> = parsed.commands.iter().filter_map(|c| tmux_call(c, env_moved)).collect();
    // Scopes to check whole; `None` is every server.
    let mut cant_tell: Vec<Scope> = Vec::new();
    // A `tmux` the tokenizer didn't see as a command (an interpreter's string,
    // a script being written, a parse failure) may be aimed anywhere.
    let opaque = parsed.unparsed || tmux_word_re().find_iter(normalized).count() > calls.len();
    if opaque && mentions_tmux_input(&normalized.to_lowercase()) {
        cant_tell.push(None);
    }
    for call in &calls {
        for target in &call.targets {
            // Without a literal target and a known server there is nothing to probe.
            let (Some(target), Some(socket)) = (target, &call.socket) else {
                cant_tell.push(call.socket.clone());
                continue;
            };
            match probe.pane(socket, target) {
                Ok(Some(pane)) => match is_remote(&pane, probe) {
                    Ok(true) => {
                        return Ok(Some(block(RULE_TMUX_INPUT, format!("tmux input to remote pane {target} ({})", pane.title))))
                    }
                    Ok(false) => {}
                    Err(_) => cant_tell.push(Some(socket.clone())),
                },
                Ok(None) | Err(_) => cant_tell.push(Some(socket.clone())),
            }
        }
    }
    any_remote_pane(&cant_tell, &socket_dirs(normalized), probe)
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
                _ => Path::new(value.split(',').next()?).parent().map(Path::to_path_buf),
            }
        })
        .collect()
}

/// Block if any pane in any of `scopes` is remote (the target can't be told).
fn any_remote_pane(scopes: &[Scope], extra_dirs: &[PathBuf], probe: &dyn PaneProbe) -> Result<Option<GuardVerdict>, GuardError> {
    let mut sockets: Vec<TmuxSocket> = scopes.iter().flatten().cloned().collect();
    if scopes.iter().any(Option::is_none) {
        sockets.extend(probe.servers(extra_dirs)?);
    }
    let mut checked: Vec<&TmuxSocket> = Vec::new();
    for socket in &sockets {
        if checked.contains(&socket) {
            continue;
        }
        checked.push(socket);
        for pane in probe.all_panes(socket)? {
            if is_remote(&pane, probe)? {
                return Ok(Some(block(
                    RULE_TMUX_INPUT,
                    format!("tmux input with an unknown target while a remote pane is open ({})", pane.title),
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
    Ok(probe.subtree_args(pane.pid)?.iter().any(|a| remote_process_re().is_match(a)))
}

/// The tmux invocation in `cmd`, if any word of it is `tmux` (any case).
/// `env_moved`: the text reassigns `TMUX` / `TMUX_TMPDIR`, so the default
/// and `-L` servers can't be told.
fn tmux_call(cmd: &SimpleCommand, env_moved: bool) -> Option<TmuxCall> {
    let at = cmd.words.iter().position(|w| shell::basename(&w.text).eq_ignore_ascii_case("tmux"))?;
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
                'S' => socket = Some(TmuxSocket::Path(value)),
                _ => {}
            }
        }
    }
    let mut targets = Vec::new();
    for sub in split_tmux_commands(&words[i..]) {
        let Some((name, args)) = sub.split_first() else { continue };
        let kind = if name.dynamic { TmuxKind::Indirect } else { tmux_kind(&name.text) };
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
        targets.push(if kind == TmuxKind::Indirect { None } else { target.flatten() });
    }
    Some(TmuxCall { socket, targets })
}

/// In the short-option cluster `opt` (`-lt`), the first option in
/// `with_arg`, its value (the rest of the cluster, else the next word, which
/// `next` then skips) and whether that value holds an unexpanded variable.
fn option_value(opt: &Word, with_arg: &str, words: &[Word], next: &mut usize) -> Option<(char, String, bool)> {
    let cluster = &opt.text[1..];
    let (k, c) = cluster.char_indices().find(|(_, c)| with_arg.contains(*c))?;
    let rest = &cluster[k + c.len_utf8()..];
    if !rest.is_empty() {
        return Some((c, rest.to_owned(), opt.dynamic));
    }
    let value = words.get(*next);
    *next += 1;
    Some((c, value.map(|w| w.text.clone()).unwrap_or_default(), value.is_some_and(|w| w.dynamic)))
}

/// Split tmux's arguments into commands at `;` (a word `;` or a trailing `;`).
fn split_tmux_commands(words: &[Word]) -> Vec<Vec<Word>> {
    let mut out = vec![Vec::new()];
    for w in words {
        if w.text == ";" {
            out.push(Vec::new());
        } else if let Some(stripped) = w.text.strip_suffix(';').filter(|s| !s.ends_with('\\')) {
            out.last_mut().unwrap().push(Word { text: stripped.to_owned(), ..w.clone() });
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
    let command = format!("{quoted} pre-tool-use || {{ echo \"{FAIL_CLOSED_MESSAGE}\" >&2; exit 2; }}");
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
    let beside = |exe: PathBuf| exe.parent().map(|d| d.join("nostromo-guard")).filter(|p| p.is_file());
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
