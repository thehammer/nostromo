//! Session rules (AP4): the narrow "Allow for this session" rules the daemon
//! derives itself, and the matcher that decides whether a later request is
//! covered by one the human created.
//!
//! The Claude CLI offers no suggestion for an ask-rule prompt and an allow rule
//! does not outrank an ask rule, so Nostromo matches the rule. That makes this
//! the second place the daemon ever answers `allow` without a click on that
//! request, so everything here errs toward "no rule" / "no match":
//!
//! - Only a **plain** Bash command ever gets a candidate: ASCII words from a
//!   small alphabet separated by single spaces ([`plain_words`]). No quote,
//!   `$`, redirection, glob, separator, tab or non-ASCII byte, so a compound
//!   command or a substitution cannot be mistaken for a plain one.
//! - A candidate is either **exact** (the command, byte for byte) or, for a
//!   short list of file utilities on absolute or `~/` paths, a **path prefix**.
//! - Only a short **allowlist** of command words ([`PREFIX_COMMANDS`], [`EXACT_COMMANDS`])
//!   ever gets a candidate; everything else (test and task runners, interpreters, exec
//!   wrappers, remote and production-shell commands, tmux, AWS) gets "Allow once" only. The
//!   denylists stay as defence in depth. Anything that points at a protected location never
//!   gets one either.
//!
//! The module is pure apart from [`matches`]' symlink check on a prefix match.
//! It never parses rule text: a [`SessionRule`] is built only from a
//! [`Candidate`] this module produced.

use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::request::{PermissionRequest, Reason, ReasonKind, ToolKind};
use super::shell;
use super::tmux_bin::looks_like_tmux;

/// The most rules one session may hold.
pub const MAX_RULES_PER_SESSION: usize = 32;
/// The longest plain command, in bytes.
const MAX_COMMAND_BYTES: usize = 300;
/// The summary of an exact rule.
pub const EXACT_SUMMARY: &str =
    "Allows exactly this command text again, in whatever directory the session is in";

/// What a candidate or rule covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateKind {
    Exact,
    PathPrefix,
}

impl CandidateKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Exact => "exact",
            Self::PathPrefix => "path_prefix",
        }
    }
}

/// What a rule matches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Spec {
    /// The trimmed command, byte for byte. `pinned` is where every absolute or `~/` operand
    /// resolved when the rule was offered (none of them may pass through a symlink, a
    /// symlinked home and the `/tmp` alias aside); a match requires each to resolve to
    /// exactly that again.
    Exact {
        command: String,
        pinned: Vec<PathBuf>,
    },
    /// `head` (command word and flags) followed by one or more paths under `prefix`
    /// (`~/Library/Caches/`, always ending in `/`). `resolved` is the prefix directory as the
    /// file system resolved it when the rule was offered; it must have resolved to itself
    /// (a symlinked home aside), and a match requires it to resolve to exactly that again.
    PathPrefix {
        head: Vec<String>,
        prefix: String,
        resolved: PathBuf,
    },
}

/// A rule the human may choose for one held request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    /// Fresh per request.
    pub id: String,
    /// The rule as shown: `Bash(rm -rf ~/Library/Caches/:*)`.
    pub rule_text: String,
    pub summary: String,
    pub kind: CandidateKind,
    /// The user's ask rule this overrides, when the request was raised by one.
    pub overrides: Option<String>,
    pub spec: Spec,
}

/// A rule the human created (memory only).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRule {
    pub id: String,
    pub rule_text: String,
    pub summary: String,
    pub kind: CandidateKind,
    pub spec: Spec,
    /// The sub-agent the rule is bound to; `None` is the session's own agent.
    pub agent_id: Option<String>,
    pub session_id: Option<String>,
    pub created_at_ms: u64,
    pub uses: u64,
    pub granted_by_request_id: String,
    pub granted_by_window: String,
}

impl SessionRule {
    /// The rule `candidate` describes, granted to `agent_id` by request `request_id`.
    pub fn from_candidate(
        candidate: &Candidate,
        agent_id: Option<String>,
        created_at_ms: u64,
        request_id: &str,
        window: &str,
    ) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            rule_text: candidate.rule_text.clone(),
            summary: candidate.summary.clone(),
            kind: candidate.kind,
            spec: candidate.spec.clone(),
            agent_id,
            session_id: None,
            created_at_ms,
            uses: 0,
            granted_by_request_id: request_id.to_owned(),
            granted_by_window: window.to_owned(),
        }
    }

    /// An exact rule for `command` (tests: a hand-built rule the broker never derived), its
    /// operands pinned as the file system under `home` resolves them now (none when they
    /// cannot be pinned, which can then never match).
    #[cfg(any(test, feature = "test-support"))]
    pub fn exact_for_test(command: &str, home: &Path, agent_id: Option<String>) -> Self {
        let words: Vec<String> = command.split(' ').map(str::to_owned).collect();
        let pinned = pin_operands(&words, home, None).unwrap_or_default();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            rule_text: format!("Bash({command})"),
            summary: EXACT_SUMMARY.to_owned(),
            kind: CandidateKind::Exact,
            spec: Spec::Exact {
                command: command.to_owned(),
                pinned,
            },
            agent_id,
            session_id: None,
            created_at_ms: 0,
            uses: 0,
            granted_by_request_id: "test".into(),
            granted_by_window: "test".into(),
        }
    }
}

impl Candidate {
    /// The resolved prefix directory of a path-prefix candidate (tests).
    #[cfg(test)]
    fn spec_resolved(&self) -> Option<PathBuf> {
        match &self.spec {
            Spec::PathPrefix { resolved, .. } => Some(resolved.clone()),
            Spec::Exact { .. } => None,
        }
    }
}

// ── what is never offered ─────────────────────────────────────────────────────

/// Command basenames that never get a rule (lower-case).
const NEVER_COMMANDS: &[&str] = &[
    "tmux",
    "aws",
    "ssh",
    "scp",
    "sftp",
    "mosh",
    "kubectl",
    "session-manager-plugin",
    "sudo",
    "su",
    "doas",
    "env",
    "xargs",
    "exec",
    "eval",
    "source",
    ".",
    "..",
    "command",
    "builtin",
    "nohup",
    "time",
    "timeout",
    "nice",
    "sh",
    "bash",
    "zsh",
    "fish",
    "dash",
    "ksh",
    "python",
    "python3",
    "node",
    "perl",
    "ruby",
    "osascript",
    "open",
    "nostromo-app",
    "nostromo",
    "nostromd",
    "nostromo-guard",
    "claude",
    "launchctl",
    "security",
    "defaults",
    "crontab",
    // Task runners, package managers and exec wrappers: the same text runs different
    // code depending on the project (or runs another command entirely).
    "make",
    "npm",
    "npx",
    "yarn",
    "pnpm",
    "cargo",
    "go",
    "pip",
    "pip3",
    "uv",
    "gradle",
    "mvn",
    "arch",
    "caffeinate",
    "stdbuf",
    "script",
    "watch",
    "find",
    // A rule for `git` is too broad to offer anything.
    "git",
];

/// Versioned interpreters (`python3.12`, `perl5.34`, `node18`): never a rule either.
const INTERPRETER_PREFIXES: &[&str] = &["python", "perl", "ruby", "node", "php"];

/// Words (lower-cased) that must not appear inside any word of the command.
const NEVER_SUBSTRINGS: &[&str] = &[
    "tmux",
    "ecs",
    "ssm",
    "execute-command",
    "start-session",
    "run-task",
    "session-manager",
    "send-keys",
    "send-prefix",
    "paste-buffer",
    "pipe-pane",
    "respawn-pane",
];

/// Absolute locations nothing under or at which gets a rule (compared lower-cased).
const PROTECTED_ABSOLUTE: &[&str] = &[
    "etc",
    "private/etc",
    "system",
    "usr",
    "bin",
    "sbin",
    "library",
    "applications",
    "var",
    "private/var",
    "dev",
    "opt/homebrew/bin",
    "opt/homebrew/sbin",
    "usr/local/bin",
    "usr/local/sbin",
];

/// Locations under the home directory, likewise.
const PROTECTED_HOME: &[&str] = &[
    ".ssh",
    ".aws",
    ".kube",
    ".gnupg",
    ".config",
    ".docker",
    ".npmrc",
    ".netrc",
    ".zshrc",
    ".zshenv",
    ".zlogout",
    ".bash_login",
    ".bash_logout",
    ".cshrc",
    ".tcshrc",
    ".login",
    ".inputrc",
    ".zlogin",
    ".zprofile",
    ".bash_profile",
    ".bashrc",
    ".profile",
    ".gitconfig",
    ".git-credentials",
    ".pypirc",
    ".cargo",
    ".local/bin",
    ".claude",
    ".nostromo",
    "library/keychains",
    "library/launchagents",
    "bin",
    ".vimrc",
    ".vim",
    ".tmux.conf",
    ".zsh_history",
    ".bash_history",
    ".history",
    "library/application support",
    "library/cookies",
    "library/preferences",
];

/// The file utilities a path-prefix rule may be offered for.
const PREFIX_COMMANDS: &[&str] = &[
    "rm", "rmdir", "mkdir", "touch", "ls", "du", "stat", "file", "cat", "head", "tail", "wc",
];

/// The only other command words an exact rule may be offered for: file and text
/// utilities and read-only inspection commands whose effect is the same wherever and
/// whenever they run. Everything else (task runners, test runners, interpreters, exec
/// wrappers, anything that loads project files) gets "Allow once" only. Not `ln` (it
/// creates the symlinks the prefix check depends on), `sed`, `awk`, `find`, `tar`, `zip`,
/// `curl` or `wget`.
const EXACT_COMMANDS: &[&str] = &[
    "cp", "mv", "diff", "cmp", "grep", "rg", "sort", "uniq", "cut", "tr", "basename", "dirname",
    "realpath", "readlink", "pwd", "which", "whoami", "id", "date", "uname", "sw_vers", "echo",
    "printf", "sleep", "shasum", "md5", "xxd", "od", "strings", "tree", "ps", "pgrep", "df",
];

/// Commands that change files: an exact rule for one is not offered when a path
/// argument is relative, because the rule ignores the directory it was granted in.
const RELATIVE_PATH_SENSITIVE: &[&str] = &[
    "rm", "rmdir", "mv", "cp", "touch", "mkdir", // change files
    "sort", "uniq", "tree", "xxd", // can write an output file
];

/// The flags each allowlisted command may carry in an exact or prefix rule: `(command,
/// short flag letters, letters that take a separate all-digits word)`. A command word not
/// listed here is never offered. Every `--` word (including a bare `--`) is refused for all
/// of them: long options run programs (`rg --hostname-bin`, `rg --pre`), read operand lists an
/// agent can rewrite (`sort --files0-from`) or write files, and getopt accepts abbreviations.
/// A short group is allowed only if every letter is in the set, so `-ion` is refused for `o`.
/// `ps` and `date` are special-cased in [`flags_allowed`].
const FLAG_TABLE: &[(&str, &str, &str)] = &[
    ("rm", "rRfvd", ""),
    ("rmdir", "pv", ""),
    ("mkdir", "pv", ""),
    ("touch", "c", ""),
    ("cp", "Rpvnfi", ""),
    ("mv", "fnvi", ""),
    ("ls", "lah1tr", ""),
    ("du", "sh", "d"),
    ("stat", "", ""),
    ("file", "bi", ""),
    ("cat", "nbs", ""),
    ("head", "", "n"),
    ("tail", "", "n"),
    ("wc", "lwc", ""),
    ("diff", "uqs", ""),
    ("cmp", "uqs", ""),
    ("grep", "inlcwvrFHhs", ""),
    ("rg", "inlcwvFHhs", ""),
    ("sort", "nrufb", ""),
    ("uniq", "cdui", ""),
    ("cut", "dfcbs", ""),
    ("tr", "dsc", ""),
    ("basename", "", ""),
    ("dirname", "", ""),
    ("realpath", "", ""),
    ("readlink", "", ""),
    ("pwd", "", ""),
    ("which", "a", ""),
    ("whoami", "", ""),
    ("id", "", ""),
    ("date", "", ""),
    ("uname", "a", ""),
    ("sw_vers", "", ""),
    ("echo", "n", ""),
    ("printf", "", ""),
    ("sleep", "", ""),
    ("shasum", "", ""),
    ("md5", "", ""),
    ("xxd", "", ""),
    ("od", "cxb", ""),
    ("strings", "a", ""),
    ("tree", "a", "L"),
    ("ps", "", ""),
    ("pgrep", "flxi", ""),
    ("df", "h", ""),
];

// ── candidates ────────────────────────────────────────────────────────────────

/// The rules the human may choose for `req`: empty unless the request is an
/// eligible plain Bash command (module docs). The guard has already let it through.
pub fn candidates(
    req: &PermissionRequest,
    reason: &Reason,
    home: &Path,
    cwd: Option<&Path>,
) -> Vec<Candidate> {
    let Some(plain) = eligible(req, reason.kind, home, cwd) else {
        return Vec::new();
    };
    // Every absolute operand must be where it says it is, now and (re-checked) at match time.
    let Some(pinned) = pin_operands(&plain.words, home, cwd) else {
        return Vec::new();
    };
    let overrides = (reason.kind == ReasonKind::AskRule)
        .then(|| reason.rule.as_ref().map(|r| r.rule.clone()))
        .flatten();
    let mut out = vec![Candidate {
        id: uuid::Uuid::new_v4().to_string(),
        rule_text: format!("Bash({})", plain.command),
        summary: EXACT_SUMMARY.to_owned(),
        kind: CandidateKind::Exact,
        overrides: overrides.clone(),
        spec: Spec::Exact {
            command: plain.command.clone(),
            pinned,
        },
    }];
    if let Some((head, prefix, resolved)) = prefix_of(&plain, home) {
        let head_text = head.join(" ");
        let flags = head[1..].join(" ");
        let summary = if flags.is_empty() {
            format!(
                "Allows `{}` on one or more paths inside `{prefix}`, with no flags",
                head[0]
            )
        } else {
            format!(
                "Allows `{head_text}` on one or more paths inside `{prefix}`, with no other flags"
            )
        };
        out.push(Candidate {
            id: uuid::Uuid::new_v4().to_string(),
            rule_text: format!("Bash({head_text} {prefix}:*)"),
            summary,
            kind: CandidateKind::PathPrefix,
            overrides,
            spec: Spec::PathPrefix {
                head,
                prefix,
                resolved,
            },
        });
    }
    // Belt and braces: a candidate must cover the request it came from.
    out.retain(|c| spec_matches(&c.spec, &plain, home));
    out
}

/// [`candidates`] on a helper thread: a file system that does not answer within `timeout`
/// (a hung mount under the home directory, `/Network`, `/Volumes`) means no candidates, so
/// the broker's single worker cannot stall on an agent-chosen path.
pub fn candidates_within(
    timeout: std::time::Duration,
    req: &PermissionRequest,
    reason: &Reason,
    home: &Path,
    cwd: Option<&Path>,
) -> Vec<Candidate> {
    let (req, reason, home, cwd) = (
        req.clone(),
        reason.clone(),
        home.to_path_buf(),
        cwd.map(Path::to_path_buf),
    );
    bounded(timeout, move || {
        candidates(&req, &reason, &home, cwd.as_deref())
    })
    .unwrap_or_default()
}

/// Does `rule` cover `req`? Besides the rule's own shape, the request must pass
/// every eligibility check again, and a prefix match must still land inside the
/// prefix once symlinks are resolved.
pub fn matches(
    rule: &SessionRule,
    req: &PermissionRequest,
    reason_kind: ReasonKind,
    home: &Path,
    cwd: Option<&Path>,
) -> bool {
    let Some(plain) = eligible(req, reason_kind, home, cwd) else {
        return false;
    };
    if !spec_matches(&rule.spec, &plain, home) {
        return false;
    }
    match &rule.spec {
        // The operands must still resolve to where they did when the rule was offered.
        Spec::Exact { pinned, .. } => {
            pin_operands(&plain.words, home, cwd).as_ref() == Some(pinned)
        }
        Spec::PathPrefix {
            head,
            prefix,
            resolved,
        } => {
            // The prefix directory must still be what it was when the human chose the
            // rule: a directory that has since become a symlink is a different place.
            let dir = expand(prefix.trim_end_matches('/'), home);
            if canonical_lenient(&dir).as_ref() != Some(resolved) {
                return false;
            }
            plain.words[head.len()..]
                .iter()
                .all(|p| resolved_inside(p, resolved, home))
        }
    }
}

/// [`matches`], but a file system that does not answer within `timeout` (a hung network
/// mount under `/Volumes`) counts as no match, so the broker's single worker cannot stall.
pub fn matches_within(
    timeout: std::time::Duration,
    rule: &SessionRule,
    req: &PermissionRequest,
    reason_kind: ReasonKind,
    home: &Path,
    cwd: Option<&Path>,
) -> bool {
    first_match_within(
        timeout,
        std::slice::from_ref(rule),
        req,
        reason_kind,
        home,
        cwd,
    )
    .is_some()
}

/// The first of `rules` that [`matches`], all checked on one helper thread under one overall
/// `timeout` (so 32 rules on a slow mount stall the worker once, not 32 times); `None` on
/// no match or on a timeout.
pub fn first_match_within(
    timeout: std::time::Duration,
    rules: &[SessionRule],
    req: &PermissionRequest,
    reason_kind: ReasonKind,
    home: &Path,
    cwd: Option<&Path>,
) -> Option<SessionRule> {
    let (rules, req, home, cwd) = (
        rules.to_vec(),
        req.clone(),
        home.to_path_buf(),
        cwd.map(Path::to_path_buf),
    );
    bounded(timeout, move || {
        rules
            .into_iter()
            .find(|r| matches(r, &req, reason_kind, &home, cwd.as_deref()))
    })
    .flatten()
}

/// How many timed-out helper threads may still be stuck in the file system at once. A thread
/// blocked in a syscall on a dead mount cannot be cancelled; it ends when the call returns.
/// Past this many, new work is refused (no match, no candidate) instead of piling up more.
const MAX_HELPERS: usize = 4;

static HELPERS_IN_FLIGHT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Counts one helper thread; dropping it (the thread ending, even by a panic) gives the slot back.
struct HelperSlot;

impl HelperSlot {
    fn take() -> Option<Self> {
        use std::sync::atomic::Ordering::SeqCst;
        let taken = HELPERS_IN_FLIGHT.fetch_add(1, SeqCst);
        if taken >= MAX_HELPERS {
            HELPERS_IN_FLIGHT.fetch_sub(1, SeqCst);
            return None;
        }
        Some(Self)
    }
}

impl Drop for HelperSlot {
    fn drop(&mut self) {
        HELPERS_IN_FLIGHT.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Run `f` on a helper thread; `None` if it has not finished within `timeout` or too many
/// earlier helpers are still stuck.
fn bounded<T: Send + 'static>(
    timeout: std::time::Duration,
    f: impl FnOnce() -> T + Send + 'static,
) -> Option<T> {
    let slot = HelperSlot::take()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("rule-match".into())
        .spawn(move || {
            let _slot = slot;
            let _ = tx.send(f());
        })
        .ok()?;
    rx.recv_timeout(timeout).ok()
}

/// A request that passed every eligibility check: its trimmed command and words.
struct Plain {
    command: String,
    words: Vec<String>,
}

fn eligible(
    req: &PermissionRequest,
    reason_kind: ReasonKind,
    home: &Path,
    cwd: Option<&Path>,
) -> Option<Plain> {
    if req.tool_name != "Bash" || req.tool_kind != ToolKind::Bash {
        return None;
    }
    let obj = req.input.as_object()?;
    if obj
        .keys()
        .any(|k| !matches!(k.as_str(), "command" | "description" | "timeout"))
    {
        return None;
    }
    // `default_to_no`: the CLI wants this one answered deliberately. `classifier_approvable:
    // false`: not even the auto-mode classifier may approve it. A safety check is read from
    // the raw field, because `Reason::kind` calls it `Other` when the text is empty (or an
    // ask rule matched first).
    if req.suppress_always_allow_rule == Some(true)
        || req.requires_user_interaction == Some(true)
        || req.default_to_no == Some(true)
        || req.classifier_approvable == Some(false)
        || req.decision_reason_type.as_deref() == Some("safetyCheck")
    {
        return None;
    }
    if matches!(
        reason_kind,
        ReasonKind::SafetyCheck | ReasonKind::SettingsWrite
    ) {
        return None;
    }
    let raw = obj.get("command")?.as_str()?;
    let command = raw.trim_matches(' ');
    let words = plain_words(command)?;
    let parsed = shell::parse(command);
    if parsed.commands.len() != 1
        || !parsed.separators.is_empty()
        || parsed.unparsed
        || !parsed.heredocs.is_empty()
    {
        return None;
    }
    let first = &words[0];
    if first.contains('=') || first.starts_with('-') || first.starts_with('~') {
        return None;
    }
    // A command word with a `/` names a file (relative to who knows where, or an
    // arbitrary absolute binary): never a rule.
    if first.contains('/') {
        return None;
    }
    // The Mac's file system ignores case, so `CP` runs `/bin/cp`: any command word that is not
    // exactly its lowercase allowlisted name is refused, and every later decision uses it.
    let basename = first.to_ascii_lowercase();
    if *first != basename {
        return None;
    }
    if basename.is_empty()
        || NEVER_COMMANDS.contains(&basename.as_str())
        || basename.starts_with("ecs_")
        || INTERPRETER_PREFIXES.iter().any(|p| basename.starts_with(p))
    {
        return None;
    }
    if !PREFIX_COMMANDS.contains(&basename.as_str()) && !EXACT_COMMANDS.contains(&basename.as_str())
    {
        return None;
    }
    // (`tree -L 2`: the depth is the flag's argument, not a path; [`flags_allowed`] checks it.)
    if RELATIVE_PATH_SENSITIVE.contains(&basename.as_str())
        && words[1..].iter().enumerate().any(|(i, w)| {
            let is_depth = basename == "tree" && i > 0 && words[i] == "-L";
            !w.starts_with('-') && !w.starts_with('/') && !w.starts_with("~/") && !is_depth
        })
    {
        return None;
    }
    // `uniq IN OUT` and `xxd IN OUT` write their second operand. A lone `-` and everything
    // after `--` is an operand too.
    if matches!(basename.as_str(), "uniq" | "xxd") && operand_count(&words[1..]) > 1 {
        return None;
    }
    if !flags_allowed(&basename, &words[1..]) {
        return None;
    }
    // `=cmd` expands to a path in zsh; a leading `%` is a job spec or a format.
    if words
        .iter()
        .any(|w| w.starts_with('=') || w.starts_with('%'))
    {
        return None;
    }
    let command_word = parsed.commands[0].words.first()?;
    if looks_like_tmux(command_word, cwd.unwrap_or_else(|| Path::new("/")), true) {
        return None;
    }
    let lowered = command.to_ascii_lowercase();
    if NEVER_SUBSTRINGS.iter().any(|s| lowered.contains(s)) {
        return None;
    }
    if super::guard::remote_shell_marker(command).is_some() {
        return None;
    }
    if words.iter().any(|w| word_is_protected(w, home, cwd)) {
        return None;
    }
    Some(Plain {
        command: command.to_owned(),
        words,
    })
}

/// Words that are operands rather than flags: not starting with `-`, a lone `-`, and
/// everything after `--`.
fn operand_count(args: &[String]) -> usize {
    let mut after_dashes = false;
    let mut n = 0;
    for w in args {
        if after_dashes || !w.starts_with('-') || w == "-" {
            n += 1;
        } else if w == "--" {
            after_dashes = true;
        }
    }
    n
}

/// Do the arguments of `command` stay inside [`FLAG_TABLE`]? Operands (words not starting
/// with `-`, and a lone `-`) are not judged here; the path checks do that.
fn flags_allowed(command: &str, args: &[String]) -> bool {
    // Only the two forms nobody can aim at a program or a file; `ps -o` and friends are out.
    if command == "ps" {
        return args == ["aux"] || args == ["-ef"];
    }
    // Any other operand is the positional form that sets the clock.
    if command == "date" {
        return args
            .iter()
            .all(|a| a == "-u" || (a.starts_with('+') && a.len() > 1));
    }
    let Some((_, short, numeric)) = FLAG_TABLE.iter().find(|(c, _, _)| *c == command) else {
        return false;
    };
    let mut rest = args.iter();
    while let Some(word) = rest.next() {
        if word.starts_with("--") {
            return false;
        }
        let Some(body) = word.strip_prefix('-').filter(|b| !b.is_empty()) else {
            continue;
        };
        if numeric.contains('n') && body.bytes().all(|b| b.is_ascii_digit()) {
            // `head -20`: the glued numeric form.
            continue;
        }
        if body.len() == 1 && numeric.contains(body) {
            // `head -n 5`: the number is the flag's argument, not a path.
            if !rest
                .next()
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            {
                return false;
            }
        } else if !body.chars().all(|c| short.contains(c)) {
            return false;
        }
    }
    true
}

/// Commands whose non-flag words are file operands they read, so a relative one is pinned
/// against the session's directory too (the others, `echo hi`, `which ls`, take words that are
/// not paths).
const READS_FILES: &[&str] = &[
    "ls", "du", "stat", "file", "cat", "head", "tail", "wc", "diff", "cmp", "grep", "rg", "sort",
    "uniq", "cut", "realpath", "readlink", "shasum", "md5", "xxd", "od", "strings", "tree",
];

/// A relative operand a rule may pin: `.` itself, or plain components (no `.`, `..`, `//`).
fn plain_relative(word: &str) -> bool {
    word == "."
        || (!word.starts_with('/')
            && !word.contains("//")
            && !word
                .trim_end_matches('/')
                .split('/')
                .any(|c| c.is_empty() || c == "." || c == ".."))
}

/// Does this command search a directory tree (so that, with no path, it searches the session's
/// directory)? `grep` only with `-r`; `rg`, `du` and `tree` always.
fn searches_recursively(command: &str, args: &[String]) -> bool {
    match command {
        "rg" | "du" | "tree" => true,
        "grep" => args
            .iter()
            .any(|a| a.starts_with('-') && !a.starts_with("--") && a.contains('r')),
        _ => false,
    }
}

/// Where each absolute or `~/` operand of `words[1..]` resolves (and, for commands that read
/// files, each relative operand, against `cwd`, the session's directory), in order; `None` if
/// one cannot be pinned. An operand is pinned only if the file system resolves it to itself (no
/// symlink in it or its parents, anywhere, including its last component), allowing the
/// symlinked home and the `/tmp` alias of `/private/tmp`; the resolved form must not be a
/// protected place nor under `/Volumes` or `/Network` (mounts that may hang). The exact rule
/// stores these and re-resolves them at match time, so a directory that later becomes a
/// symlink ends the rule's reach (`rm -rf fixtures/.ssh` after `fixtures` pointed at home).
/// A relative operand with an unknown `cwd` is refused, and so is a recursive search with no
/// path (it searches `cwd`, which is then pinned and checked like an operand).
fn pin_operands(words: &[String], home: &Path, cwd: Option<&Path>) -> Option<Vec<PathBuf>> {
    let name = words[0].to_ascii_lowercase();
    let name = name.as_str();
    // `cp a dir` and `mv a b c` write `dir/a`, a path the rule never pinned (and `dir/a` may be
    // a symlink by then): only a plain `cp SRC DST` / `mv SRC DST` whose destination is not
    // (and does not read as) an existing directory is pinned. A destination that exists with
    // several hard links is refused too: writing it would write the other names as well
    // (`~/.zshrc`), and the inode behind a path cannot be pinned by its name. (Hard links
    // for reads are not checked.)
    if matches!(name, "cp" | "mv") {
        let operands: Vec<&String> = words[1..].iter().filter(|w| !w.starts_with('-')).collect();
        let dest_is_dir = operands.last().is_some_and(|d| {
            d.ends_with('/') || expand(d, home).is_dir() || expand(d, home) == Path::new("/")
        });
        if operands.len() != 2 || dest_is_dir {
            return None;
        }
        let dest = expand(operands[1], home);
        if std::fs::symlink_metadata(&dest)
            .is_ok_and(|m| !m.file_type().is_dir() && std::os::unix::fs::MetadataExt::nlink(&m) > 1)
        {
            return None;
        }
    }
    let reads_files = READS_FILES.contains(&name);
    let real_home = canonical_lenient(home).unwrap_or_else(|| home.to_path_buf());
    let pin = |path: PathBuf| -> Option<PathBuf> {
        let real = canonical_lenient(&path)?;
        let mut expected = vec![path.clone()];
        if let Ok(rest) = path.strip_prefix(home) {
            expected.push(real_home.join(rest));
        }
        if let Ok(rest) = path.strip_prefix("/tmp") {
            expected.push(Path::new("/private/tmp").join(rest));
        }
        if !expected.contains(&real)
            || path_is_protected(&real, home)
            || path_is_protected(&real, &real_home)
            || first_component_is(&real, &["volumes", "network"])
            || first_component_is(&path, &["volumes", "network"])
        {
            return None;
        }
        Some(real)
    };
    let session_dir = || cwd.filter(|c| c.is_absolute());
    let mut pattern_pending = matches!(name, "grep" | "rg");
    let mut pinned = Vec::new();
    for word in &words[1..] {
        if word.starts_with('/') || word.starts_with("~/") {
            if !plain_path(word) {
                return None;
            }
            pinned.push(pin(expand(word.trim_end_matches('/'), home))?);
            pattern_pending = false;
        } else if reads_files && !word.starts_with('-') {
            // `grep`/`rg`: the first operand is the pattern, not a path.
            if pattern_pending {
                pattern_pending = false;
                continue;
            }
            if !plain_relative(word) {
                return None;
            }
            let dir = session_dir()?;
            let path = if word == "." {
                dir.to_path_buf()
            } else {
                dir.join(word.trim_end_matches('/'))
            };
            pinned.push(pin(path)?);
        }
    }
    // `grep -r PATTERN` and `rg PATTERN` name no path: the first operand is the pattern.
    let pattern_words = usize::from(matches!(name, "grep" | "rg"));
    let operands = words[1..]
        .iter()
        .filter(|w| !w.starts_with('-') && !w.bytes().all(|b| b.is_ascii_digit()))
        .count();
    if searches_recursively(name, &words[1..]) && operands <= pattern_words {
        pinned.push(pin(session_dir()?.to_path_buf())?);
    }
    Some(pinned)
}

fn first_component_is(path: &Path, names: &[&str]) -> bool {
    normalize(path)
        .and_then(|parts| parts.first().map(|p| p.to_ascii_lowercase()))
        .is_some_and(|first| names.contains(&first.as_str()))
}

/// The words of `command` when it is plain, else `None`: at most
/// [`MAX_COMMAND_BYTES`], ASCII, single-space separated, every other byte in
/// `[A-Za-z0-9_./~+=,:@%-]`.
fn plain_words(command: &str) -> Option<Vec<String>> {
    if command.is_empty() || command.len() > MAX_COMMAND_BYTES {
        return None;
    }
    let ok = command
        .bytes()
        .all(|b| b == b' ' || b.is_ascii_alphanumeric() || b"_./~+=,:@%-".contains(&b));
    if !ok || command.starts_with(' ') || command.ends_with(' ') || command.contains("  ") {
        return None;
    }
    Some(command.split(' ').map(str::to_owned).collect())
}

fn spec_matches(spec: &Spec, plain: &Plain, home: &Path) -> bool {
    match spec {
        Spec::Exact { command, .. } => plain.command == *command,
        Spec::PathPrefix { head, prefix, .. } => {
            let Some(paths) = plain.words.strip_prefix(head.as_slice()) else {
                return false;
            };
            !paths.is_empty()
                && paths
                    .iter()
                    .all(|p| plain_path(p) && lexically_inside(p, prefix, home))
        }
    }
}

// ── paths ─────────────────────────────────────────────────────────────────────

/// A path word a prefix rule may cover: absolute or `~/`, no `.`/`..`
/// component, no `//`, no leading `-`.
fn plain_path(word: &str) -> bool {
    (word.starts_with('/') || word.starts_with("~/"))
        && !word.starts_with('-')
        && !word.contains("//")
        && !word
            .trim_end_matches('/')
            .split('/')
            .any(|c| c == "." || c == "..")
}

/// `word` with a leading `~/` expanded; absolute words as they are.
fn expand(word: &str, home: &Path) -> PathBuf {
    match word.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None => PathBuf::from(word),
    }
}

/// Is `word` strictly inside directory `prefix`, comparing path components
/// without looking at the file system (case-sensitive)?
fn lexically_inside(word: &str, prefix: &str, home: &Path) -> bool {
    let path = expand(word.trim_end_matches('/'), home);
    let dir = expand(prefix.trim_end_matches('/'), home);
    path != dir && path.starts_with(&dir)
}

/// The nearest existing ancestor of `path`, canonicalized, with the rest appended.
fn canonical_lenient(path: &Path) -> Option<PathBuf> {
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    let mut cur = path.to_path_buf();
    loop {
        match std::fs::canonicalize(&cur) {
            Ok(real) => {
                let mut out = real;
                out.extend(tail.iter().rev());
                return Some(out);
            }
            Err(_) => {
                // Something is there but cannot be resolved (a dangling or looping
                // symlink): where it would lead is unknown, so do not guess.
                if std::fs::symlink_metadata(&cur).is_ok() {
                    return None;
                }
                tail.push(cur.file_name()?.to_owned());
                if !cur.pop() {
                    return None;
                }
            }
        }
    }
}

/// R5: after resolving symlinks, `word` is still strictly inside `resolved` (the prefix
/// directory as resolved) and not in a protected place.
fn resolved_inside(word: &str, resolved: &Path, home: &Path) -> bool {
    let path = expand(word.trim_end_matches('/'), home);
    let Some(real_path) = canonical_lenient(&path) else {
        return false;
    };
    let real_home = canonical_lenient(home).unwrap_or_else(|| home.to_path_buf());
    real_path != resolved
        && real_path.starts_with(resolved)
        && !path_is_protected(&real_path, &real_home)
        && !path_is_protected(&real_path, home)
}

/// The lexical components of `path` with `.` and `..` resolved; `None` if `..` climbs above the root.
fn normalize(path: &Path) -> Option<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for c in path.components() {
        match c {
            Component::RootDir | Component::Prefix(_) | Component::CurDir => {}
            Component::ParentDir => {
                out.pop()?;
            }
            Component::Normal(n) => out.push(n.to_string_lossy().into_owned()),
        }
    }
    Some(out)
}

/// Is the absolute `path` a protected location, or inside one?
fn path_is_protected(path: &Path, home: &Path) -> bool {
    let Some(parts) = normalize(path) else {
        return true;
    };
    let lower: Vec<String> = parts.iter().map(|p| p.to_ascii_lowercase()).collect();
    if lower.is_empty() || lower.iter().any(|p| p == ".git") {
        return true;
    }
    let under = |base: &[String]| lower.len() >= base.len() && lower[..base.len()] == *base;
    let home_parts: Vec<String> = normalize(home)
        .unwrap_or_default()
        .iter()
        .map(|p| p.to_ascii_lowercase())
        .collect();
    // The home directory itself and everything that contains it.
    if lower.len() <= home_parts.len() && home_parts[..lower.len()] == lower[..] {
        return true;
    }
    if under(&home_parts) {
        return PROTECTED_HOME.iter().any(|p| {
            let mut base = home_parts.clone();
            base.extend(p.split('/').map(str::to_owned));
            under(&base)
        });
    }
    PROTECTED_ABSOLUTE.iter().any(|p| {
        let base: Vec<String> = p.split('/').map(str::to_owned).collect();
        under(&base)
    })
}

/// Is `word` (or a piece of it split at `=`, `,` or `:`) a protected location, or
/// does it point inside one? Relative words are resolved against `cwd`.
fn word_is_protected(word: &str, home: &Path, cwd: Option<&Path>) -> bool {
    std::iter::once(word)
        .chain(word.split(['=', ',', ':']))
        .any(|piece| piece_is_protected(piece, home, cwd))
}

fn piece_is_protected(piece: &str, home: &Path, cwd: Option<&Path>) -> bool {
    if piece.is_empty() {
        return false;
    }
    // `~`, `~/`, `~user`, `~+`: only `~/<something>` is a path we can place.
    if piece.starts_with('~') && !piece.starts_with("~/") {
        return true;
    }
    if piece == "~/" || piece == "/" {
        return true;
    }
    if piece.split('/').any(|c| c.eq_ignore_ascii_case(".git")) {
        return true;
    }
    // APFS volume paths (`/.vol/<fsid>/<inode>`) name any file by number and bypass
    // every path check here.
    if piece.split('/').any(|c| c.eq_ignore_ascii_case(".vol")) {
        return true;
    }
    if piece.starts_with('/') || piece.starts_with("~/") {
        return path_is_protected(&expand(piece, home), home);
    }
    if piece.contains('/') || piece == ".." || piece == "." {
        // Relative: resolve against the session's directory, which we may not know.
        return match cwd {
            Some(cwd) => path_is_protected(&cwd.join(piece), home),
            None => piece.split('/').any(|c| c == ".."),
        };
    }
    // A bare relative name (`.ssh`) is checked like `.ssh/x`: against the session's
    // directory, or, when that is unknown, by its name.
    match cwd {
        Some(cwd) => path_is_protected(&cwd.join(piece), home),
        None => {
            let lower = piece.to_ascii_lowercase();
            PROTECTED_HOME
                .iter()
                .any(|p| !p.contains('/') && *p == lower)
        }
    }
}

// ── prefix derivation ─────────────────────────────────────────────────────────

/// `(head, prefix, resolved)` for a command a path-prefix rule can cover, else `None`.
/// `resolved` is the prefix directory as the file system resolves it now.
fn prefix_of(plain: &Plain, home: &Path) -> Option<(Vec<String>, String, PathBuf)> {
    let words = &plain.words;
    if !PREFIX_COMMANDS.contains(&words[0].as_str()) {
        return None;
    }
    let flags = words[1..].iter().take_while(|w| is_flag(w)).count();
    let head: Vec<String> = words[..1 + flags].to_vec();
    let paths = &words[1 + flags..];
    if paths.is_empty() || !paths.iter().all(|p| plain_path(p)) {
        return None;
    }
    // The deepest directory that contains every path's parent: as component lists. Paths
    // under the user's home are normalised to `~/...` first, so `/Users/me/Code/x` counts
    // exactly as deep as `~/Code/x`.
    let home_forms = home_forms(home);
    let mut common: Option<Vec<String>> = None;
    for p in paths {
        let (root, parts) = split_root(p, &home_forms);
        let mut parent = parts[..parts.len().checked_sub(1)?].to_vec();
        parent.insert(0, root.to_owned());
        common = Some(match common {
            None => parent,
            Some(c) => c
                .iter()
                .zip(&parent)
                .take_while(|(a, b)| a == b)
                .map(|(a, _)| a.clone())
                .collect(),
        });
    }
    let common = common?;
    // `common[0]` is the root marker (`/` or `~`).
    let prefix = if common[0] == "~" {
        format!("~/{}/", common[1..].join("/"))
    } else {
        format!("/{}/", common[1..].join("/"))
    };
    if !prefix_depth_ok(&prefix, &home_forms) {
        return None;
    }
    let dir = expand(prefix.trim_end_matches('/'), home);
    if path_is_protected(&dir, home) {
        return None;
    }
    // The prefix must be where it says it is: a symlink anywhere in it (or at it) would
    // let the rule cover a different place later, or already now. A symlinked home is
    // the one allowed indirection. Depth, broad roots and protected places are then
    // judged again on the resolved form.
    let resolved = resolve_prefix(&dir, home)?;
    let resolved_text = resolved.to_str()?;
    let real_home = canonical_lenient(home).unwrap_or_else(|| home.to_path_buf());
    if !prefix_depth_ok(resolved_text, &home_forms)
        || path_is_protected(&resolved, home)
        || path_is_protected(&resolved, &real_home)
    {
        return None;
    }
    Some((head, prefix, resolved))
}

/// Depth rule (R1) for a prefix as text (`~/a/b/` or `/a/b/c/`): at least two components
/// below the home directory; elsewhere at least three below `/`, and never inside a broad
/// root such as `/Volumes`, `/Users` (another user), `/opt` or `/private`.
fn prefix_depth_ok(prefix: &str, home_forms: &[Vec<String>]) -> bool {
    let (root, parts) = split_root(prefix, home_forms);
    if root == "~" {
        parts.len() >= 2
    } else {
        parts.len() >= 3 && !BROAD_ROOTS.contains(&parts[0].to_ascii_lowercase().as_str())
    }
}

/// `dir` as the file system resolves it, provided that is `dir` itself (or `dir` with a
/// symlinked home replaced by its real path); `None` for any other symlink.
fn resolve_prefix(dir: &Path, home: &Path) -> Option<PathBuf> {
    let real = canonical_lenient(dir)?;
    let expected = match dir.strip_prefix(home) {
        Ok(rest) => canonical_lenient(home)?.join(rest),
        Err(_) => dir.to_path_buf(),
    };
    (real == expected).then_some(real)
}

/// First components under which an absolute (non-home) prefix rule is never offered.
const BROAD_ROOTS: &[&str] = &[
    "volumes",
    "network",
    "users",
    "opt",
    "usr",
    "etc",
    "var",
    "private",
    "library",
    "system",
    "applications",
    "home",
    "mnt",
    "net",
    "cores",
];

/// The home directory as lower-cased components, as given and as the file system
/// resolves it (a symlinked home), without duplicates.
fn home_forms(home: &Path) -> Vec<Vec<String>> {
    let lower = |p: &Path| -> Option<Vec<String>> {
        normalize(p).map(|v| v.iter().map(|c| c.to_ascii_lowercase()).collect())
    };
    let mut out: Vec<Vec<String>> = Vec::new();
    for form in [Some(home.to_path_buf()), canonical_lenient(home)]
        .into_iter()
        .flatten()
    {
        if let Some(v) = lower(&form) {
            if !v.is_empty() && !out.contains(&v) {
                out.push(v);
            }
        }
    }
    out
}

fn is_flag(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-') && word[1..].bytes().all(|b| b.is_ascii_alphabetic())
}

/// `("~", components)` for a `~/…` word or an absolute word under the home directory
/// (matched case-insensitively against each of `home_forms`), `("/", components)` for
/// any other absolute word.
fn split_root(word: &str, home_forms: &[Vec<String>]) -> (&'static str, Vec<String>) {
    let (root, rest) = match word.strip_prefix("~/") {
        Some(rest) => ("~", rest),
        None => ("/", word.trim_start_matches('/')),
    };
    let mut parts: Vec<String> = rest
        .trim_end_matches('/')
        .split('/')
        .filter(|c| !c.is_empty())
        .map(str::to_owned)
        .collect();
    if root == "/" {
        for h in home_forms {
            let under = parts.len() > h.len()
                && parts[..h.len()]
                    .iter()
                    .map(|c| c.to_ascii_lowercase())
                    .eq(h.iter().cloned());
            if under {
                return ("~", parts.split_off(h.len()));
            }
        }
    }
    (root, parts)
}

/// `rule` as the audit log and the wire show its identity (no timing fields).
pub fn rule_identity(rule: &SessionRule) -> Value {
    serde_json::json!({
        "rule_id": rule.id,
        "rule_text": rule.rule_text,
        "kind": rule.kind.as_str(),
        "granted_at_ms": rule.created_at_ms,
        "granted_by_request_id": rule.granted_by_request_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approvals::request::{AskRule, SettingsSource};
    use serde_json::json;

    struct NoSettings;
    impl SettingsSource for NoSettings {
        fn ask_rules(&self, _cwd: Option<&Path>) -> Vec<AskRule> {
            Vec::new()
        }
    }

    fn home() -> PathBuf {
        PathBuf::from("/Users/tester")
    }

    fn request(input: Value, extra: Value) -> PermissionRequest {
        let mut v = json!({
            "subtype": "can_use_tool",
            "tool_name": "Bash",
            "input": input,
            "tool_use_id": "toolu_1",
            "decision_reason_type": "rule",
        });
        if let (Some(o), Some(e)) = (v.as_object_mut(), extra.as_object()) {
            for (k, val) in e {
                o.insert(k.clone(), val.clone());
            }
        }
        PermissionRequest::from_cli(&v).expect("parses")
    }

    fn cmd(command: &str) -> PermissionRequest {
        request(json!({ "command": command, "description": "d" }), json!({}))
    }

    fn texts(req: &PermissionRequest) -> Vec<String> {
        let reason = req.reason(None, &NoSettings);
        candidates(req, &reason, &home(), Some(Path::new("/work/proj")))
            .into_iter()
            .map(|c| c.rule_text)
            .collect()
    }

    fn texts_of(command: &str) -> Vec<String> {
        texts(&cmd(command))
    }

    #[test]
    fn a_cache_directory_gets_an_exact_rule_and_a_prefix_rule() {
        assert_eq!(
            texts_of("rm -rf ~/Library/Caches/foo"),
            [
                "Bash(rm -rf ~/Library/Caches/foo)",
                "Bash(rm -rf ~/Library/Caches/:*)"
            ]
        );
    }

    #[test]
    fn several_paths_use_their_deepest_common_parent() {
        assert_eq!(
            texts_of("rm -rf ~/Library/Caches/a ~/Library/Caches/b"),
            [
                "Bash(rm -rf ~/Library/Caches/a ~/Library/Caches/b)",
                "Bash(rm -rf ~/Library/Caches/:*)"
            ]
        );
        // Parents differ below Caches/: the prefix stops at Caches/.
        assert_eq!(
            texts_of("rm -rf ~/Library/Caches/x/a ~/Library/Caches/y/b")[1],
            "Bash(rm -rf ~/Library/Caches/:*)"
        );
    }

    #[test]
    fn shallow_or_protected_prefixes_get_exact_only() {
        for c in [
            "rm -rf ~/Code/x",
            "rm -rf /tmp/x",
            "rm -rf ~/Library/Caches/foo/../../.ssh/k",
            "rm -rf ~/.ssh/k",
            "rm -rf /etc/a/b",
            "rm -rf /usr/local/a",
            "rm -rf ~/code/proj/.git/hooks",
        ] {
            let t = texts_of(c);
            assert!(t.len() <= 1, "{c}: {t:?}");
            assert!(!t.iter().any(|r| r.ends_with(":*)")), "{c}: {t:?}");
        }
        assert!(texts_of("rm -rf ~/.ssh/k").is_empty());
        assert!(texts_of("rm -rf /etc/a/b").is_empty());
    }

    fn assert_exact_only(commands: &[&str]) {
        for c in commands {
            let t = texts_of(c);
            assert!(!t.iter().any(|r| r.ends_with(":*)")), "{c}: {t:?}");
        }
    }

    // Fails on the old depth check, which counted `/Users/tester/Code` as three components.
    #[test]
    fn the_absolute_form_of_a_home_path_is_no_deeper_than_its_tilde_form() {
        assert_exact_only(&[
            "rm -rf /Users/tester/Code/x",
            "rm -rf /Users/tester/Documents/x",
            "rm -rf /Users/tester/Desktop/x",
            "rm -rf /Users/tester/Downloads/x",
            "rm -rf /USERS/Tester/code/x",
            "rm -rf /Users/tester/Code/x /Users/tester/Code/y",
        ]);
        // The same depth as `~/Library/Caches/`: still offered.
        assert_eq!(
            texts_of("rm -rf /Users/tester/Library/Caches/foo"),
            [
                "Bash(rm -rf /Users/tester/Library/Caches/foo)",
                "Bash(rm -rf ~/Library/Caches/:*)"
            ]
        );
    }

    // Fails on the old code: `/Volumes/Backup/`, `/opt/homebrew/` and `/Users/other/..`
    // were all offered as prefixes.
    #[test]
    fn broad_absolute_roots_never_become_prefix_rules() {
        assert_exact_only(&[
            "rm -rf /Volumes/Backup/x",
            "rm -rf /Volumes/Backup/a/b/c",
            "rm -rf /opt/homebrew/x",
            "rm -rf /opt/homebrew/Cellar/a/b",
            "rm -rf /Users/otheruser/x",
            "rm -rf /Users/otheruser/Code/proj/x",
            "rm -rf /private/tmp/a/b/c",
            "rm -rf /tmp/x",
            "rm -rf /tmp/a/x",
        ]);
        // Three components below `/` outside a broad root is still fine.
        assert_eq!(
            texts_of("rm -rf /work/a/b/x"),
            ["Bash(rm -rf /work/a/b/x)", "Bash(rm -rf /work/a/b/:*)"]
        );
    }

    #[test]
    fn dot_dot_after_normalisation_never_gets_a_prefix() {
        assert_exact_only(&[
            "rm -rf /Users/tester/Library/Caches/../../Code/x",
            "rm -rf ~/Library/Caches/a/../../Code/x",
        ]);
    }

    #[test]
    fn a_symlinked_home_counts_its_resolved_form_as_home_too() {
        let tmp = tempfile::tempdir().unwrap();
        let real = tmp.path().canonicalize().unwrap().join("real");
        std::fs::create_dir_all(real.join("Code")).unwrap();
        let link = tmp.path().canonicalize().unwrap().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        for word in [link.join("Code/f"), real.join("Code/f")] {
            let command = format!("rm -rf {}", word.display());
            let req = cmd(&command);
            let reason = req.reason(None, &NoSettings);
            let c = candidates(&req, &reason, &link, None);
            assert!(
                !c.iter()
                    .any(|c| c.kind == CandidateKind::PathPrefix && c.rule_text.ends_with(":*)")),
                "{command}: {:?}",
                c.iter().map(|c| &c.rule_text).collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn task_runners_package_managers_and_exec_wrappers_get_no_rule() {
        for c in [
            "make test",
            "npm test",
            "npx foo",
            "yarn test",
            "pnpm test",
            "cargo test",
            "go test",
            "pip install x",
            "pip3 install x",
            "uv run x",
            "gradle build",
            "mvn test",
            "arch -x86_64 ls",
            "caffeinate ls",
            "stdbuf -o0 ls",
            "script out.txt",
            "watch ls",
            "xargs ls",
            "env ls",
            "nohup ls",
            "time ls",
            "find build -delete",
            "git push",
            "git status",
            "/bin/ls build",
            "/opt/x/tool build",
            "./gradlew build",
            "bin/tool x",
            "/Users/tester/bin/tool x",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn the_new_protected_home_locations_get_no_rule_at_all() {
        for c in [
            "cat ~/.config/gcloud/credentials.db",
            "cat ~/.docker/config.json",
            "cat ~/.npmrc",
            "cat ~/.netrc",
            "cat ~/.zshrc",
            "cat ~/.zprofile",
            "cat ~/.bashrc",
            "cat ~/.gitconfig",
            "ls ~/Library/LaunchAgents/a",
            "cat /Users/tester/.netrc",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn request_flags_and_a_raw_safety_check_block_every_candidate() {
        let base = || json!({ "command": "ls build" });
        let flagged = [
            ("default_to_no", json!({ "default_to_no": true })),
            (
                "not classifier approvable",
                json!({ "classifier_approvable": false }),
            ),
            // Empty text: `Reason::kind` calls this `Other`.
            (
                "safety check, no text",
                json!({ "decision_reason_type": "safetyCheck" }),
            ),
            (
                "safety check, blank text",
                json!({ "decision_reason_type": "safetyCheck", "decision_reason": "  " }),
            ),
            (
                "safety check behind an ask rule",
                json!({
                    "decision_reason_type": "safetyCheck",
                    "matched_ask_rule": { "source": "userSettings", "tool_name": "Bash", "rule_content": "ls:*" }
                }),
            ),
        ];
        for (name, extra) in flagged {
            let req = request(base(), extra);
            assert!(texts(&req).is_empty(), "{name}");
            // and a rule never matches it either
            let rule = rule_for("ls build", 0);
            let kind = req.reason(None, &NoSettings).kind;
            assert!(
                !matches(&rule, &req, kind, &home(), Some(Path::new("/work/proj"))),
                "{name}"
            );
        }
        // The same command without the flags is offered.
        assert_eq!(texts(&request(base(), json!({}))), ["Bash(ls build)"]);
        assert_eq!(
            texts(&request(
                base(),
                json!({ "default_to_no": false, "classifier_approvable": true })
            )),
            ["Bash(ls build)"]
        );
    }

    #[test]
    fn a_relative_path_never_gets_a_prefix() {
        assert_eq!(texts_of("ls build"), ["Bash(ls build)"]);
        assert_eq!(texts_of("git push"), Vec::<String>::new());
    }

    // S-a: the rule ignores the directory it was granted in, so a file-changing command
    // with a relative path argument gets no rule at all.
    #[test]
    fn a_file_changing_command_with_a_relative_path_gets_no_rule() {
        for c in [
            "rm build",
            "rm -rf build",
            "rm -rf /work/a/b/x build",
            "rmdir out",
            "mv a /work/b",
            "mv /work/a b",
            "cp a /work/b",
            "cp /work/a b",
            "touch x",
            "mkdir -p out",
            "mkdir out/sub",
            "chmod 755 /work/a",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
        // Absolute arguments are still fine, and so are relative ones to read-only commands.
        assert_eq!(texts_of("cp /work/a /work/b"), ["Bash(cp /work/a /work/b)"]);
        assert_eq!(texts_of("mv /work/a /work/b"), ["Bash(mv /work/a /work/b)"]);
        assert_eq!(texts_of("ls build"), ["Bash(ls build)"]);
    }

    // M2: exact candidates come from an allowlist of command words. Every one of these
    // used to be offered (the same text runs project code, or wraps another command).
    #[test]
    fn a_command_that_is_not_on_the_allowlist_gets_no_rule() {
        for c in [
            "pytest",
            "pytest tests",
            "jest",
            "vitest run",
            "eslint src",
            "prettier --check src",
            "tox",
            "swift test",
            "xcodebuild test",
            "docker compose up",
            "just build",
            "rake test",
            "bundle exec rspec",
            "composer install",
            "pre-commit run",
            "terraform plan",
            "brew bundle",
            "pod install",
            "deno run x",
            "bun run x",
            "tsx x",
            "lua x",
            "Rscript x",
            "java x",
            "awk -f x",
            "sed -n 1p x",
            "sqlite3 -init x",
            "psql -f x",
            "gh extension exec x",
            "xcrun ls",
            "taskpolicy ls",
            "flock x ls",
            "parallel ls",
            "gtimeout 5 ls",
            "genv ls",
            "rsync a b",
            "op run ls",
            "aws-vault exec x",
            "noglob tmux kill-server",
            "noglob ssh host",
            "nocorrect ssh host",
            "ln -s /work/a /work/b",
            "tar xf x",
            "zip x y",
            "curl x",
            "wget x",
            "chmod 755 /work/a",
            "git status",
            // Dropped in round 3: no flag/filter set that cannot run or read a rewritable file.
            "jq . /work/a",
            "lsof -i",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn an_allowlisted_command_still_gets_an_exact_rule() {
        for c in [
            "grep foo /work/a",
            "rg foo build",
            "diff /work/a /work/b",
            "echo hi",
            "date",
            "uname -a",
            "sleep 1",
            "ps aux",
            "pgrep foo",
            "df -h",
            "tree /work/build",
            "uniq /work/a",
            "xxd /work/a",
        ] {
            assert_eq!(texts_of(c), [format!("Bash({c})")], "{c:?}");
        }
    }

    #[test]
    fn an_allowlisted_command_that_runs_a_program_or_writes_a_file_gets_no_rule() {
        for c in [
            "rg --pre /work/x foo",
            "rg --pre=/work/x foo",
            "sort -o /work/a /work/b",
            "sort --output=/work/a /work/b",
            "sort --compress-program=/work/x /work/b",
            "tree -o /work/a",
            "uniq /work/a /work/b",
            "uniq /work/a -",
            "uniq -- /work/a /work/b",
            "sort -ro /work/a",
            "sort --outp=/work/a /work/b",
            "sort --out /work/a",
            "rg --pr x /work/a",
            "rg --exec x /work/a",
            "xxd /work/a /work/b",
            "sort a",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn tmux_anywhere_in_a_command_gets_no_rule() {
        for c in ["echo tmux", "ls /work/tmux/a", "grep foo /work/TMUX"] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn apfs_volume_paths_never_get_a_rule() {
        for c in [
            "cat /.vol/1/2",
            "ls /.vol/16777220/2",
            "rm -rf /.vol/1/2/Users/x/y/z",
            "ls /.VOL/1/2",
            "echo x=/.vol/1/2",
            "ls //.vol/1/2",
            "ls /./.vol/1/2",
            "ls /work/../.vol/1/2",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn words_starting_with_equals_or_percent_get_no_rule() {
        for c in [
            "ls =ls",
            "echo =tmux",
            "echo %1",
            "printf %s x",
            "ls /work/a =x",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn a_bare_relative_protected_name_is_checked_like_a_path_under_it() {
        let h = home();
        for (command, cwd) in [
            ("ls .ssh", Some(h.as_path())),
            ("ls .ssh/x", Some(h.as_path())),
            ("ls .aws", Some(h.as_path())),
            ("cat .zshrc", Some(h.as_path())),
            ("ls .ssh", None),
            ("ls .git", Some(Path::new("/work/proj"))),
        ] {
            let req = cmd(command);
            let reason = req.reason(None, &NoSettings);
            assert!(
                candidates(&req, &reason, &h, cwd).is_empty(),
                "{command} in {cwd:?}"
            );
        }
        // Not under a protected place: still offered.
        let req = cmd("ls src");
        let reason = req.reason(None, &NoSettings);
        assert_eq!(
            candidates(&req, &reason, &h, Some(&h.join("Code/p"))).len(),
            1
        );
    }

    #[test]
    fn nothing_that_is_not_plain_gets_a_rule() {
        for c in [
            "rm -rf ~",
            "rm -rf ~/",
            "rm -rf /tmp/x && curl x",
            "rm -rf \"/tmp/a b\"",
            "rm -rf $X",
            "rm -rf /tmp/*",
            "rm -rf /tmp/x > ~/.zshrc",
            "rm  -rf /a/b/c",
            "r\u{43c} -rf /a/b/c",
            "tmux send-keys -t %7 ls Enter",
            "t send-keys -t %7 ls Enter",
            "aws ecs describe-services",
            "ecs_build_command ap",
            "bash -c 'rm -rf /a/b'",
            "sudo rm -rf /a/b/c",
            "python3 /a/b/c.py",
            "ls\trm",
            "ls\nrm",
            "echo `id`",
            "FOO=bar ls",
            "./run.sh",
            "python3.12 /a/b/c.py",
            "/usr/bin/perl5.34 /a/b/c.pl",
            "~/bin/tool",
            "",
        ] {
            assert!(texts_of(c).is_empty(), "{c:?}: {:?}", texts_of(c));
        }
    }

    #[test]
    fn requests_that_are_not_plain_bash_get_no_rule() {
        let bg = request(
            json!({ "command": "ls /a/b", "run_in_background": true }),
            json!({}),
        );
        let sandbox = request(
            json!({ "command": "ls /a/b", "dangerouslyDisableSandbox": true }),
            json!({}),
        );
        let suppress = request(
            json!({ "command": "ls /a/b" }),
            json!({ "suppress_always_allow_rule": true }),
        );
        let interactive = request(
            json!({ "command": "ls /a/b" }),
            json!({ "requires_user_interaction": true }),
        );
        let safety = request(
            json!({ "command": "ls /a/b" }),
            json!({ "decision_reason_type": "safetyCheck", "decision_reason": "sensitive" }),
        );
        let edit = PermissionRequest::from_cli(&json!({
            "tool_name": "Edit", "input": {"file_path": "/a/b"}, "tool_use_id": "t"
        }))
        .unwrap();
        let mcp = PermissionRequest::from_cli(&json!({
            "tool_name": "mcp__s__t", "input": {"command": "ls"}, "tool_use_id": "t"
        }))
        .unwrap();
        for (name, req) in [
            ("background", bg),
            ("sandbox", sandbox),
            ("suppress", suppress),
            ("interactive", interactive),
            ("safety", safety),
            ("edit", edit),
            ("mcp", mcp),
        ] {
            assert!(texts(&req).is_empty(), "{name}");
        }
    }

    #[test]
    fn an_ask_rule_request_names_the_rule_it_overrides() {
        let req = request(
            json!({ "command": "rm -rf /tmp/x/a" }),
            json!({ "matched_ask_rule": { "source": "userSettings", "tool_name": "Bash", "rule_content": "rm:*" } }),
        );
        let reason = req.reason(None, &NoSettings);
        let c = candidates(&req, &reason, &home(), None);
        assert_eq!(c[0].overrides.as_deref(), Some("Bash(rm:*)"));
        // The rule is unknown (nothing in the settings): the card says so.
        let unknown = cmd("rm -rf /tmp/x/a");
        let reason = unknown.reason(None, &NoSettings);
        assert!(candidates(&unknown, &reason, &home(), None)
            .iter()
            .all(|c| c.overrides.is_none()));
    }

    fn rule_for(command: &str, idx: usize) -> SessionRule {
        let req = cmd(command);
        let reason = req.reason(None, &NoSettings);
        let c = candidates(&req, &reason, &home(), Some(Path::new("/work/proj")));
        SessionRule::from_candidate(&c[idx], None, 0, "r", "w")
    }

    fn hit(rule: &SessionRule, command: &str) -> bool {
        let req = cmd(command);
        let kind = req.reason(None, &NoSettings).kind;
        matches(rule, &req, kind, &home(), Some(Path::new("/work/proj")))
    }

    #[test]
    fn an_exact_rule_matches_only_the_same_command() {
        let r = rule_for("ls build", 0);
        assert!(hit(&r, "ls build"));
        assert!(hit(&r, " ls build "));
        assert!(!hit(&r, "ls build -f"));
        assert!(!hit(&r, "ls  build"));
        assert!(!hit(&r, "ls build && curl x"));
    }

    #[test]
    fn a_prefix_rule_matches_paths_below_the_prefix_only() {
        let r = rule_for("rm -rf ~/Library/Caches/foo", 1);
        assert!(hit(&r, "rm -rf ~/Library/Caches/bar"));
        assert!(hit(
            &r,
            "rm -rf ~/Library/Caches/bar/baz ~/Library/Caches/q/"
        ));
        assert!(hit(&r, "rm -rf /Users/tester/Library/Caches/bar"));
        for no in [
            "rm -rf ~/Library/Caches/",
            "rm -rf ~/Library/Caches",
            "rm -rf ~/Library/CachesX/a",
            "rm -rf ~/library/caches/a",
            "rm -rf ~/Library/Caches/a/../../b",
            "rm -rf ~/Library/Caches/./a",
            "rm -rf ~/Library/Caches//a",
            "rm -rf ~/Library/Caches/a ~/Documents/b",
            "rm -rf ~/Library/Caches/a -f",
            "rm -rf -f ~/Library/Caches/a",
            "rm -r ~/Library/Caches/a",
            "rm -rfv ~/Library/Caches/a",
            "rm ~/Library/Caches/a",
            "rm -rf",
            "rm -rf build",
            "/bin/rm -rf ~/Library/Caches/a",
            "rm -rf ~/Library/Caches/a && rm -rf ~",
        ] {
            assert!(!hit(&r, no), "{no}");
        }
    }

    #[test]
    fn a_symlink_out_of_the_prefix_does_not_match() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let caches = home.join("Library/Caches");
        std::fs::create_dir_all(&caches).unwrap();
        std::fs::create_dir_all(home.join("Documents")).unwrap();
        std::os::unix::fs::symlink(&home, caches.join("escape")).unwrap();
        std::os::unix::fs::symlink(home.join("Documents"), caches.join("docs")).unwrap();
        let rule = SessionRule {
            spec: Spec::PathPrefix {
                head: vec!["rm".into(), "-rf".into()],
                prefix: "~/Library/Caches/".into(),
                resolved: caches.clone(),
            },
            ..SessionRule::exact_for_test("x", Path::new("/Users/tester"), None)
        };
        let check = |c: &str| {
            let req = cmd(c);
            matches(&rule, &req, ReasonKind::AskRule, &home, None)
        };
        assert!(check("rm -rf ~/Library/Caches/fresh"));
        assert!(!check("rm -rf ~/Library/Caches/escape/x"));
        assert!(!check("rm -rf ~/Library/Caches/escape"));
        assert!(!check("rm -rf ~/Library/Caches/docs/x"));
    }

    /// `prefix` candidate (index 1) for `command`, with `home`, if one is offered.
    fn prefix_candidate(command: &str, home: &Path) -> Option<Candidate> {
        let req = cmd(command);
        let reason = req.reason(None, &NoSettings);
        candidates(&req, &reason, home, None)
            .into_iter()
            .find(|c| c.kind == CandidateKind::PathPrefix)
    }

    fn rule_from(c: &Candidate) -> SessionRule {
        SessionRule::from_candidate(c, None, 0, "r", "w")
    }

    fn matches_in(rule: &SessionRule, command: &str, home: &Path) -> bool {
        matches(rule, &cmd(command), ReasonKind::AskRule, home, None)
    }

    // M1, the model repro: the prefix directory itself becomes a symlink to home after the
    // rule was granted. The old matcher re-resolved the prefix and only checked the path
    // was inside wherever it now pointed, so `<prefix>/Documents` matched.
    #[test]
    fn a_prefix_directory_that_becomes_a_symlink_ends_the_rule() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("Users/me");
        std::fs::create_dir_all(home.join("Code/proj/build/out")).unwrap();
        std::fs::create_dir_all(home.join("Documents")).unwrap();
        let candidate = prefix_candidate("rm -rf ~/Code/proj/build/out", &home).expect("offered");
        let rule = rule_from(&candidate);
        assert!(matches_in(&rule, "rm -rf ~/Code/proj/build/out", &home));
        assert!(matches_in(
            &rule,
            "rm -rf ~/Code/proj/build/Documents",
            &home
        ));

        std::fs::rename(home.join("Code/proj/build"), root.join("old-build")).unwrap();
        std::os::unix::fs::symlink("../..", home.join("Code/proj/build")).unwrap();

        assert!(!matches_in(
            &rule,
            "rm -rf ~/Code/proj/build/Documents",
            &home
        ));
        assert!(!matches_in(&rule, "rm -rf ~/Code/proj/build/out", &home));
        // Swapped for a symlink to a harmless sibling: still not the same place.
        std::fs::remove_file(home.join("Code/proj/build")).unwrap();
        std::fs::create_dir_all(home.join("Code/proj/other/out")).unwrap();
        std::os::unix::fs::symlink(home.join("Code/proj/other"), home.join("Code/proj/build"))
            .unwrap();
        assert!(!matches_in(&rule, "rm -rf ~/Code/proj/build/out", &home));
    }

    // M1 at grant time: a symlink already inside the prefix path is refused outright.
    #[test]
    fn a_prefix_with_a_symlink_in_it_is_not_offered() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let home = root.join("Users/me");
        std::fs::create_dir_all(home.join("Documents/x")).unwrap();
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::create_dir_all(root.join("elsewhere/c")).unwrap();
        // /…/a/b -> home, at the prefix directory.
        std::os::unix::fs::symlink(&home, root.join("a/b")).unwrap();
        let command = format!("rm -rf {}/a/b/Documents/x", root.display());
        assert!(prefix_candidate(&command, &home).is_none(), "{command}");
        let command = format!("rm -rf {}/a/b/c", root.display());
        assert!(prefix_candidate(&command, &home).is_none(), "{command}");
        // A symlink at an intermediate component.
        std::os::unix::fs::symlink(root.join("elsewhere"), root.join("l")).unwrap();
        let command = format!("rm -rf {}/l/c/d", root.display());
        assert!(prefix_candidate(&command, &home).is_none(), "{command}");
        // A plain directory in the same place is fine.
        std::fs::create_dir_all(root.join("a/plain/q")).unwrap();
        let command = format!("rm -rf {}/a/plain/q/z", root.display());
        let c = prefix_candidate(&command, &home).expect("a real directory is offered");
        assert_eq!(c.spec_resolved(), Some(root.join("a/plain/q")));
    }

    // A symlinked home is the one allowed indirection, and the rule stays tied to it.
    #[test]
    fn a_symlinked_home_may_carry_a_prefix_but_only_while_it_points_there() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let real = root.join("real");
        let other = root.join("other");
        std::fs::create_dir_all(real.join("Library/Caches/foo")).unwrap();
        std::fs::create_dir_all(other.join("Library/Caches/foo")).unwrap();
        let link = root.join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let c = prefix_candidate("rm -rf ~/Library/Caches/foo/x", &link).expect("offered");
        assert_eq!(c.spec_resolved(), Some(real.join("Library/Caches/foo")));
        let rule = rule_from(&c);
        assert!(matches_in(&rule, "rm -rf ~/Library/Caches/foo/y", &link));
        std::fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&other, &link).unwrap();
        assert!(!matches_in(&rule, "rm -rf ~/Library/Caches/foo/y", &link));
    }

    // S-e: a dangling final symlink used to fall back to its parent and so match.
    #[test]
    fn a_dangling_symlink_does_not_match() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let caches = home.join("Library/Caches/foo");
        std::fs::create_dir_all(&caches).unwrap();
        let candidate = prefix_candidate("rm -rf ~/Library/Caches/foo/a", &home).expect("offered");
        let rule = rule_from(&candidate);
        std::os::unix::fs::symlink(home.join(".ssh/authorized_keys"), caches.join("dangling"))
            .unwrap();
        std::os::unix::fs::symlink("loop", caches.join("loop")).unwrap();
        assert!(matches_in(
            &rule,
            "rm -rf ~/Library/Caches/foo/fresh",
            &home
        ));
        assert!(!matches_in(
            &rule,
            "rm -rf ~/Library/Caches/foo/dangling",
            &home
        ));
        assert!(!matches_in(
            &rule,
            "rm -rf ~/Library/Caches/foo/loop",
            &home
        ));
    }

    // S-d: a file system that does not answer is no match, not a stall.
    #[test]
    fn a_match_that_takes_too_long_is_no_match() {
        use std::time::Duration;
        assert_eq!(bounded(Duration::from_millis(2000), || 7), Some(7));
        let slow = bounded(Duration::from_millis(50), || {
            std::thread::sleep(Duration::from_millis(1500));
            true
        });
        assert_eq!(slow, None);
        let rule = rule_for("ls build", 0);
        let req = cmd("ls build");
        assert!(matches_within(
            Duration::from_secs(5),
            &rule,
            &req,
            ReasonKind::AskRule,
            &home(),
            Some(Path::new("/work/proj"))
        ));
    }

    // Round 3: candidate derivation and the all-rules match share one bounded helper.
    #[test]
    fn candidates_within_and_first_match_within_agree_with_the_plain_functions() {
        use std::time::Duration;
        let req = cmd("ls build");
        let reason = req.reason(None, &NoSettings);
        let got: Vec<String> = candidates_within(
            Duration::from_secs(5),
            &req,
            &reason,
            &home(),
            Some(Path::new("/work/proj")),
        )
        .into_iter()
        .map(|c| c.rule_text)
        .collect();
        assert_eq!(got, ["Bash(ls build)"]);
        let rules = [rule_for("ls other", 0), rule_for("ls build", 0)];
        let hit = first_match_within(
            Duration::from_secs(5),
            &rules,
            &req,
            ReasonKind::AskRule,
            &home(),
            Some(Path::new("/work/proj")),
        );
        assert_eq!(hit.map(|r| r.rule_text), Some("Bash(ls build)".to_owned()));
        assert!(first_match_within(
            Duration::from_secs(5),
            &[],
            &req,
            ReasonKind::AskRule,
            &home(),
            None
        )
        .is_none());
    }

    #[test]
    fn cp_and_mv_into_a_directory_or_with_many_sources_get_no_rule() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().canonicalize().unwrap();
        let d = d.to_str().unwrap();
        for c in [
            format!("cp /work/a {d}"),
            format!("cp /work/a {d}/"),
            format!("mv /work/a {d}"),
            "cp /work/a /work/b /work/c".to_owned(),
            "mv /work/a /work/b /work/c".to_owned(),
            "cp /work/a /work/b/".to_owned(),
        ] {
            assert!(texts_of(&c).is_empty(), "{c}: {:?}", texts_of(&c));
        }
        assert_eq!(texts_of(&format!("cp /work/a {d}/new")).len(), 1);
    }

    #[test]
    fn more_shell_startup_files_are_protected() {
        for f in [
            ".zlogout",
            ".bash_login",
            ".bash_logout",
            ".cshrc",
            ".tcshrc",
            ".login",
            ".inputrc",
        ] {
            let c = format!("cp /Users/tester/proj/x /Users/tester/{f}");
            assert!(texts_of(&c).is_empty(), "{c}");
        }
    }

    #[test]
    fn network_and_volumes_operands_get_no_rule() {
        for c in [
            "ls /Network/x/y",
            "cat /Volumes/Backup/f",
            "rm -rf /Network/a/b/c",
        ] {
            assert!(texts_of(c).is_empty(), "{c}: {:?}", texts_of(c));
        }
    }

    fn texts_in(command: &str, home: &Path, cwd: Option<&Path>) -> Vec<String> {
        let req = cmd(command);
        let reason = req.reason(None, &NoSettings);
        candidates(&req, &reason, home, cwd)
            .into_iter()
            .map(|c| c.rule_text)
            .collect()
    }

    // M1: the file system ignores case, so `CP` runs cp; only the exact lowercase word counts.
    #[test]
    fn a_command_word_that_is_not_exactly_lowercase_gets_no_rule() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().canonicalize().unwrap();
        let d = d.to_str().unwrap();
        for c in [
            format!("CP /work/src {d}"),
            format!("Cp /work/src {d}"),
            format!("CP -p /work/src {d}"),
            "CP /work/a /work/b /work/c".to_owned(),
            "MV /work/a /work/b /work/c".to_owned(),
            "Rm /work/proj/x".to_owned(),
            "Rm -rf /work/proj/x".to_owned(),
            "LS /work/proj/x".to_owned(),
            "LS -l /work/proj/x".to_owned(),
            "CAT /work/proj/x".to_owned(),
            "Cat /work/proj/x".to_owned(),
            "ECHO hi".to_owned(),
        ] {
            assert!(texts_of(&c).is_empty(), "{c}: {:?}", texts_of(&c));
        }
        assert_eq!(texts_of("cp /work/a /work/b").len(), 1);
    }

    // M2: `cp -r` follows every symlink inside the directory on macOS; `diff -r` and `cmp -r`
    // read through them; `rg -r` is `--replace` and takes an argument.
    #[test]
    fn flags_that_follow_symlinks_inside_a_directory_get_no_rule() {
        for c in [
            "cp -r /work/a /work/b",
            "cp -pr /work/a /work/b",
            "diff -r /work/a /work/b",
            "diff -ur /work/a /work/b",
            "cmp -r /work/a /work/b",
            "rg -r x pat /work/a/b/c",
            "rg -rn x /work/a/b/c",
            "grep -R x /work/a/b/c",
            "grep -rR x /work/a/b/c",
            "ls -R /work/a/b/c",
            "tree -l /work/a/b/c",
            "du -L /work/a/b/c",
        ] {
            assert!(texts_of(c).is_empty(), "{c}: {:?}", texts_of(c));
        }
        // `cp -R` copies symlinks as links; `grep -r` does not follow inner links.
        assert_eq!(texts_of("cp -R /work/a /work/b").len(), 1);
        assert_eq!(texts_of("grep -r x /work/a/b/c").len(), 1);
    }

    // S1: a destination with several hard links writes into the other names too.
    #[test]
    fn a_cp_destination_with_several_hard_links_gets_no_rule_and_stops_matching() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().canonicalize().unwrap();
        let (src, dst, other) = (d.join("src"), d.join("dst"), d.join("other"));
        std::fs::write(&src, "x").unwrap();
        std::fs::write(&other, "y").unwrap();
        let command = format!("cp {} {}", src.display(), dst.display());
        // A destination that does not exist, or has one link, is fine.
        assert_eq!(texts_in(&command, &home(), None).len(), 1);
        let req = cmd(&command);
        let reason = req.reason(None, &NoSettings);
        let c = candidates(&req, &reason, &home(), None);
        let rule = rule_from(&c[0]);
        assert!(matches_in(&rule, &command, &home()));
        // Now it is a hard link to another file.
        std::fs::hard_link(&other, &dst).unwrap();
        assert!(!matches_in(&rule, &command, &home()));
        assert!(texts_in(&command, &home(), None).is_empty());
        let mv = format!("mv {} {}", src.display(), dst.display());
        assert!(texts_in(&mv, &home(), None).is_empty());
    }

    // S2: relative operands of read commands are pinned against the session's directory.
    #[test]
    fn relative_operands_of_read_commands_are_pinned_against_the_session_directory() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().canonicalize().unwrap();
        std::fs::write(d.join("notes"), "n").unwrap();
        // No directory known: no rule. Known: a rule.
        assert!(texts_in("cat notes", &home(), None).is_empty());
        assert!(texts_in("diff a b", &home(), None).is_empty());
        assert_eq!(texts_in("cat notes", &home(), Some(&d)).len(), 1);
        assert!(texts_in("cat ../notes", &home(), Some(&d)).is_empty());
        assert!(texts_in("cat a//b", &home(), Some(&d)).is_empty());
        // The rule stops matching once `notes` is a symlink (or the directory differs).
        let req = cmd("cat notes");
        let reason = req.reason(None, &NoSettings);
        let c = candidates(&req, &reason, &home(), Some(&d));
        let rule = rule_from(&c[0]);
        let m = |cwd: Option<&Path>| matches(&rule, &req, ReasonKind::AskRule, &home(), cwd);
        assert!(m(Some(&d)));
        assert!(!m(None));
        let elsewhere = tempfile::tempdir().unwrap();
        assert!(!m(Some(&elsewhere.path().canonicalize().unwrap())));
        std::fs::remove_file(d.join("notes")).unwrap();
        std::os::unix::fs::symlink("/etc/hosts", d.join("notes")).unwrap();
        assert!(!m(Some(&d)));
        assert!(texts_in("cat notes", &home(), Some(&d)).is_empty());
    }

    // S2: a recursive search with no path searches the session's directory.
    #[test]
    fn a_recursive_search_with_no_path_needs_a_safe_session_directory() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().canonicalize().unwrap();
        let fake_home = d.join("home");
        let proj = fake_home.join("proj");
        std::fs::create_dir_all(&proj).unwrap();
        for c in [
            "grep -r AKIA",
            "rg x",
            "rg -i x",
            "du",
            "du -sh",
            "tree",
            "tree -L 2",
        ] {
            assert!(texts_in(c, &fake_home, None).is_empty(), "{c}: unknown dir");
            assert!(
                texts_in(c, &fake_home, Some(&fake_home)).is_empty(),
                "{c}: home"
            );
            assert!(
                texts_in(c, &fake_home, Some(&fake_home.join(".ssh"))).is_empty(),
                "{c}: protected"
            );
            assert!(
                !texts_in(c, &fake_home, Some(&proj)).is_empty(),
                "{c}: a project directory is fine"
            );
        }
        // With a path operand the directory does not matter.
        assert!(!texts_in("rg x /work/a/b/c", &home(), None).is_empty());
        // `.` is the session directory.
        assert!(texts_in("grep -r AKIA .", &fake_home, Some(&fake_home)).is_empty());
    }

    // S3
    #[test]
    fn more_places_the_user_can_write_that_run_code_are_protected() {
        for f in [
            ".vimrc",
            ".vim/plugin/x.vim",
            ".tmux.conf",
            ".zsh_history",
            ".bash_history",
            ".history",
            "bin/tool",
            "bin",
            "Library/Application Support",
            "Library/Application Support/x/y",
            "Library/Cookies/Cookies.binarycookies",
            "Library/Preferences/x.plist",
        ] {
            let p = home().join(f);
            assert!(path_is_protected(&p, &home()), "{f}");
            let c = format!(
                "cp /Users/tester/proj/x /Users/tester/{}",
                f.replace(' ', "")
            );
            if !f.contains(' ') {
                assert!(texts_of(&c).is_empty(), "{c}");
            }
        }
        for f in [
            "opt/homebrew/bin",
            "opt/homebrew/bin/brew",
            "opt/homebrew/sbin/x",
            "usr/local/bin/x",
            "usr/local/sbin",
        ] {
            assert!(path_is_protected(&Path::new("/").join(f), &home()), "{f}");
            let c = format!("cp /Users/tester/proj/x /{f}");
            assert!(texts_of(&c).is_empty(), "{c}");
        }
        assert!(!path_is_protected(
            Path::new("/Users/tester/proj/bin2"),
            &home()
        ));
    }

    // Nits: a glued numeric `head -20` and `date -u` are fine; `date -s` and positional are not.
    #[test]
    fn head_dash_number_and_date_u_are_accepted() {
        assert_eq!(texts_of("head -20 /work/a/b/c").len(), 1);
        assert_eq!(texts_of("tail -5 /work/a/b/c").len(), 1);
        assert!(texts_of("head -2x /work/a/b/c").is_empty());
        assert!(texts_of("wc -20 /work/a/b/c").is_empty());
        assert_eq!(texts_of("date -u").len(), 1);
        assert_eq!(texts_of("date -u +%s").len(), 1);
        assert!(texts_of("date -s 2020").is_empty());
    }

    #[test]
    fn the_rule_cap_is_32() {
        assert_eq!(MAX_RULES_PER_SESSION, 32);
    }
}
