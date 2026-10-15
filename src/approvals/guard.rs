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
}

/// The real probe: runs `tmux` and `ps`, each with a [`PROBE_TIMEOUT`].
#[derive(Debug, Default)]
pub struct SystemPaneProbe {
    /// `ps` output, read once per probe (one hook call).
    processes: OnceLock<Result<Vec<(u32, u32, String)>, ProbeError>>,
}

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
        let mut cmd = Command::new("tmux");
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

    fn processes(&self) -> Result<&Vec<(u32, u32, String)>, ProbeError> {
        self.processes
            .get_or_init(|| {
                let mut cmd = Command::new("ps");
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
        let run_task = if BLOCK_RUN_TASK { r"|\becs_run_task\b|\becs\s+run-task\b" } else { "" };
        Regex::new(&format!(
            r"(?i)\becs_connect\b|\becs_shell\b|\becs_open_tmux_pane\b|\becs\s+execute-command\b|\bssm\s+start-session\b|\bsession-manager-plugin\b{run_task}"
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

/// `tmux` as a word in the normalized text (counts possible invocations).
fn tmux_word_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\btmux\b").unwrap())
}

/// tmux verbs that put input into a pane (or into a buffer to paste). Also
/// matches tmux's accepted prefixes (`send-k`, `paste`, `pipe`, `load`).
fn is_tmux_input_verb(name: &str) -> bool {
    ["send", "paste", "pipe", "load", "set-b"].iter().any(|v| name.starts_with(v)) || name == "setb"
}

/// The gate for the tmux rule: `tmux` plus an input verb anywhere in the text.
/// It must accept everything [`is_tmux_input_verb`] does (a cheap superset).
fn mentions_tmux_input(text: &str) -> bool {
    text.contains("tmux") && ["send", "paste", "pipe", "load", "setb", "set-b"].iter().any(|v| text.contains(v))
}

/// Decide whether this tool call may run.
///
/// 1. The tool name ([`RULE_TOOL_NAME`]).
/// 2. Every `command` / `cmd` / `script` string, with quotes and backslashes
///    deleted (so `bash -c`, `eval`, here-doc bodies and `e"c"s_connect` are
///    all one searchable text), and word by word as the shell would see it
///    ([`RULE_COMMAND`]).
/// 3. tmux input verbs: the target pane is probed; a target that can't be
///    told blocks if any pane on that server is remote ([`RULE_TMUX_INPUT`]).
///
/// Fast path: only rule 3 does I/O, and only for text that mentions `tmux`
/// and an input verb; anything else is decided in memory. `Err` only when a
/// probe fails where the answer matters.
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
        let text = format!("{normalized}\n{words}").to_lowercase();
        if !mentions_tmux_input(&text) {
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

/// One `tmux` invocation's input commands.
struct TmuxCall {
    /// `None`: the `-L`/`-S` value is an unexpanded variable.
    socket: Option<TmuxSocket>,
    /// `Some(target)` per input verb with a literal `-t`; `None` when it can't be told.
    targets: Vec<Option<String>>,
}

/// Rule 3: tmux input aimed at a remote pane. `None` when nothing is remote.
fn tmux_rule(normalized: &str, parsed: &ShellParse, probe: &dyn PaneProbe) -> Result<Option<GuardVerdict>, GuardError> {
    let calls: Vec<TmuxCall> = parsed.commands.iter().filter_map(tmux_call).collect();
    // Every `tmux` in the text must be one we understood; otherwise (an
    // interpreter's string, a script file being written, a parse failure)
    // the target can't be told.
    let mut cant_tell: Vec<TmuxSocket> = Vec::new();
    if parsed.unparsed || tmux_word_re().find_iter(normalized).count() > calls.len() || calls.iter().all(|c| c.targets.is_empty()) {
        cant_tell.push(TmuxSocket::Default);
        cant_tell.extend(calls.iter().filter_map(|c| c.socket.clone()));
    }
    for call in &calls {
        let socket = call.socket.clone().unwrap_or(TmuxSocket::Default);
        for target in &call.targets {
            // Without a literal target and a known socket there is nothing to probe.
            let (Some(target), Some(_)) = (target, &call.socket) else {
                cant_tell.push(socket.clone());
                continue;
            };
            match probe.pane(&socket, target) {
                Ok(Some(pane)) => match is_remote(&pane, probe) {
                    Ok(true) => {
                        return Ok(Some(block(RULE_TMUX_INPUT, format!("tmux input to remote pane {target} ({})", pane.title))))
                    }
                    Ok(false) => {}
                    Err(_) => cant_tell.push(socket.clone()),
                },
                Ok(None) | Err(_) => cant_tell.push(socket.clone()),
            }
        }
    }
    any_remote_pane(&cant_tell, probe)
}

/// Block if any pane on any of `sockets` is remote (the target can't be told).
fn any_remote_pane(sockets: &[TmuxSocket], probe: &dyn PaneProbe) -> Result<Option<GuardVerdict>, GuardError> {
    let mut checked: Vec<&TmuxSocket> = Vec::new();
    for socket in sockets {
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

/// The tmux invocation in `cmd`, if any word of it is `tmux`.
fn tmux_call(cmd: &SimpleCommand) -> Option<TmuxCall> {
    let at = cmd.words.iter().position(|w| shell::basename(&w.text) == "tmux")?;
    let words = &cmd.words[at + 1..];
    let mut socket = Some(TmuxSocket::Default);
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
                'L' => socket = Some(TmuxSocket::Name(value)),
                'S' => socket = Some(TmuxSocket::Path(value)),
                _ => {}
            }
        }
    }
    let mut targets = Vec::new();
    for sub in split_tmux_commands(&words[i..]) {
        let Some((name, args)) = sub.split_first() else { continue };
        if !is_tmux_input_verb(&name.text) {
            continue;
        }
        let buffer_only = name.text.starts_with("load") || name.text.starts_with("set");
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
        // A buffer verb has no pane target: whatever pastes it later can't be told.
        targets.push(if buffer_only { None } else { target.flatten() });
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
