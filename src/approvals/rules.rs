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
//! - Shells, interpreters, remote and production-shell commands, tmux, AWS and
//!   anything that points at a protected location never get a candidate.
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
pub const EXACT_SUMMARY: &str = "Allows exactly this command again";

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
    /// The trimmed command, byte for byte.
    Exact(String),
    /// `head` (command word and flags) followed by one or more paths under `prefix`
    /// (`~/Library/Caches/`, always ending in `/`).
    PathPrefix { head: Vec<String>, prefix: String },
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

    /// An exact rule for `command` (tests: a hand-built rule the broker never derived).
    #[doc(hidden)]
    pub fn exact_for_test(command: &str, agent_id: Option<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            rule_text: format!("Bash({command})"),
            summary: EXACT_SUMMARY.to_owned(),
            kind: CandidateKind::Exact,
            spec: Spec::Exact(command.to_owned()),
            agent_id,
            session_id: None,
            created_at_ms: 0,
            uses: 0,
            granted_by_request_id: "test".into(),
            granted_by_window: "test".into(),
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
];

/// Words (lower-cased) that must not appear inside any word of the command.
const NEVER_SUBSTRINGS: &[&str] = &[
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
];

/// Locations under the home directory, likewise.
const PROTECTED_HOME: &[&str] = &[
    ".ssh",
    ".aws",
    ".kube",
    ".gnupg",
    ".config/gh",
    ".claude",
    ".nostromo",
    "library/keychains",
];

/// The file utilities a path-prefix rule may be offered for.
const PREFIX_COMMANDS: &[&str] = &[
    "rm", "rmdir", "mkdir", "touch", "ls", "du", "stat", "file", "cat", "head", "tail", "wc",
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
    let overrides = (reason.kind == ReasonKind::AskRule)
        .then(|| reason.rule.as_ref().map(|r| r.rule.clone()))
        .flatten();
    let mut out = vec![Candidate {
        id: uuid::Uuid::new_v4().to_string(),
        rule_text: format!("Bash({})", plain.command),
        summary: EXACT_SUMMARY.to_owned(),
        kind: CandidateKind::Exact,
        overrides: overrides.clone(),
        spec: Spec::Exact(plain.command.clone()),
    }];
    if let Some((head, prefix)) = prefix_of(&plain, home) {
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
            spec: Spec::PathPrefix { head, prefix },
        });
    }
    // Belt and braces: a candidate must cover the request it came from.
    out.retain(|c| spec_matches(&c.spec, &plain, home));
    out
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
        Spec::Exact(_) => true,
        Spec::PathPrefix { head, prefix } => plain.words[head.len()..]
            .iter()
            .all(|p| resolved_inside(p, prefix, home)),
    }
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
    if req.suppress_always_allow_rule == Some(true) || req.requires_user_interaction == Some(true) {
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
    if first.contains('/') && !first.starts_with('/') {
        return None;
    }
    let basename = first
        .rsplit('/')
        .next()
        .unwrap_or(first)
        .to_ascii_lowercase();
    if basename.is_empty()
        || NEVER_COMMANDS.contains(&basename.as_str())
        || basename.starts_with("ecs_")
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
        Spec::Exact(command) => plain.command == *command,
        Spec::PathPrefix { head, prefix } => {
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
                tail.push(cur.file_name()?.to_owned());
                if !cur.pop() {
                    return None;
                }
            }
        }
    }
}

/// R5: after resolving symlinks, `word` is still inside `prefix` and not in a protected place.
fn resolved_inside(word: &str, prefix: &str, home: &Path) -> bool {
    let path = expand(word.trim_end_matches('/'), home);
    let dir = expand(prefix.trim_end_matches('/'), home);
    let (Some(real_path), Some(real_dir)) = (canonical_lenient(&path), canonical_lenient(&dir))
    else {
        return false;
    };
    let real_home = canonical_lenient(home).unwrap_or_else(|| home.to_path_buf());
    real_path != real_dir
        && real_path.starts_with(&real_dir)
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
    false
}

// ── prefix derivation ─────────────────────────────────────────────────────────

/// `(head, prefix)` for a command a path-prefix rule can cover, else `None`.
fn prefix_of(plain: &Plain, home: &Path) -> Option<(Vec<String>, String)> {
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
    // The deepest directory that contains every path's parent: as component lists.
    let mut common: Option<Vec<String>> = None;
    for p in paths {
        let (root, parts) = split_root(p);
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
    // `common[0]` is the root marker (`/` or `~`); at least two components below it.
    if common.len() < 3 {
        return None;
    }
    let prefix = if common[0] == "~" {
        format!("~/{}/", common[1..].join("/"))
    } else {
        format!("/{}/", common[1..].join("/"))
    };
    let dir = expand(prefix.trim_end_matches('/'), home);
    if path_is_protected(&dir, home) {
        return None;
    }
    Some((head, prefix))
}

fn is_flag(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-') && word[1..].bytes().all(|b| b.is_ascii_alphabetic())
}

/// `("~", components)` for a `~/…` word, `("/", components)` for an absolute one.
fn split_root(word: &str) -> (&'static str, Vec<String>) {
    let (root, rest) = match word.strip_prefix("~/") {
        Some(rest) => ("~", rest),
        None => ("/", word.trim_start_matches('/')),
    };
    let parts = rest
        .trim_end_matches('/')
        .split('/')
        .filter(|c| !c.is_empty())
        .map(str::to_owned)
        .collect();
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

    #[test]
    fn a_relative_path_never_gets_a_prefix() {
        assert_eq!(texts_of("rm build"), ["Bash(rm build)"]);
        assert_eq!(texts_of("git push"), ["Bash(git push)"]);
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
        let c = candidates(&req, &reason, &home(), None);
        SessionRule::from_candidate(&c[idx], None, 0, "r", "w")
    }

    fn hit(rule: &SessionRule, command: &str) -> bool {
        let req = cmd(command);
        let kind = req.reason(None, &NoSettings).kind;
        matches(rule, &req, kind, &home(), None)
    }

    #[test]
    fn an_exact_rule_matches_only_the_same_command() {
        let r = rule_for("git push", 0);
        assert!(hit(&r, "git push"));
        assert!(hit(&r, " git push "));
        assert!(!hit(&r, "git push -f"));
        assert!(!hit(&r, "git  push"));
        assert!(!hit(&r, "git push && curl x"));
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
            },
            ..SessionRule::exact_for_test("x", None)
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

    #[test]
    fn the_rule_cap_is_32() {
        assert_eq!(MAX_RULES_PER_SESSION, 32);
    }
}
