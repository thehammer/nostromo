//! A permission request as the CLI sends it (`control_request` with
//! `subtype: "can_use_tool"`, design contract §1), typed, classified and
//! sanitized, plus the "Why" line (§6.3).
//!
//! Only `tool_name`, `input` and `tool_use_id` are required: every other field
//! comes from the CLI's schema and may be missing in any version. The full
//! request object is also kept by the broker exactly as received (the audit
//! log's `cli_request`), so nothing parsed here can lose information.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::display::invisible_token;
use super::shell;
use crate::data::work::is_invisible;

/// What kind of tool the request is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolKind {
    Bash,
    Edit,
    Write,
    NotebookEdit,
    Mcp,
    Other,
}

impl ToolKind {
    /// Classify a tool by its name.
    pub fn of(tool_name: &str) -> Self {
        match tool_name {
            "Bash" => Self::Bash,
            "Edit" => Self::Edit,
            "Write" => Self::Write,
            "NotebookEdit" => Self::NotebookEdit,
            n if mcp_split(n).is_some() => Self::Mcp,
            _ => Self::Other,
        }
    }
}

/// An MCP tool's server and tool name (`mcp__<server>__<tool>`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct McpTool {
    pub server: String,
    pub tool: String,
}

/// `mcp__<server>__<tool>` as `(server, tool)`. The server is what is between the
/// first two `__`; the tool is the rest (it may contain `__`).
fn mcp_split(name: &str) -> Option<McpTool> {
    let rest = name.strip_prefix("mcp__")?;
    let (server, tool) = rest.split_once("__")?;
    (!server.is_empty() && !tool.is_empty()).then(|| McpTool {
        server: server.into(),
        tool: tool.into(),
    })
}

/// The ask rule the CLI says matched, when it names one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MatchedAskRule {
    #[serde(default)]
    pub source: String,
    #[serde(default)]
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule_content: Option<String>,
}

impl MatchedAskRule {
    /// The rule in Claude's own text form: `Bash(rm:*)` or `Bash`.
    pub fn rule_text(&self) -> String {
        match &self.rule_content {
            Some(c) if !c.is_empty() => format!("{}({c})", self.tool_name),
            _ => self.tool_name.clone(),
        }
    }
}

/// A parsed `can_use_tool` request. Text fields the CLI wrote
/// (`description`, `decision_reason`) are already sanitized: ANSI/CSI/OSC
/// sequences removed and invisible characters shown as tokens.
#[derive(Debug, Clone, PartialEq)]
pub struct PermissionRequest {
    pub tool_name: String,
    pub input: Value,
    pub tool_use_id: String,
    pub tool_kind: ToolKind,
    pub mcp: Option<McpTool>,
    pub display_name: Option<String>,
    pub title: Option<String>,
    pub description: Option<String>,
    pub decision_reason_type: Option<String>,
    pub decision_reason: Option<String>,
    pub matched_ask_rule: Option<MatchedAskRule>,
    pub agent_id: Option<String>,
    pub mcp_server: Option<String>,
    pub permission_suggestions: Option<Value>,
    pub blocked_path: Option<String>,
    pub classifier_approvable: Option<bool>,
    pub suppress_always_allow_rule: Option<bool>,
    pub default_to_no: Option<bool>,
    pub requires_user_interaction: Option<bool>,
}

/// A request that could not be read.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum RequestError {
    #[error("the request is not a JSON object")]
    NotAnObject,
    #[error("the request has no `{0}` string")]
    Missing(&'static str),
}

impl PermissionRequest {
    /// Parse the `request` object of a `can_use_tool` control request.
    pub fn from_cli(value: &Value) -> Result<Self, RequestError> {
        let obj = value.as_object().ok_or(RequestError::NotAnObject)?;
        let required = |k: &'static str| {
            obj.get(k)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .ok_or(RequestError::Missing(k))
        };
        let tool_name = required("tool_name")?;
        let tool_use_id = required("tool_use_id")?;
        let input = obj
            .get("input")
            .cloned()
            .ok_or(RequestError::Missing("input"))?;
        let text = |k: &str| obj.get(k).and_then(Value::as_str).map(str::to_owned);
        let clean = |k: &str| obj.get(k).and_then(Value::as_str).map(sanitize_text);
        let flag = |k: &str| obj.get(k).and_then(Value::as_bool);
        Ok(Self {
            tool_kind: ToolKind::of(&tool_name),
            mcp: mcp_split(&tool_name),
            display_name: text("display_name"),
            title: clean("title"),
            description: clean("description"),
            decision_reason_type: text("decision_reason_type"),
            decision_reason: clean("decision_reason"),
            matched_ask_rule: obj
                .get("matched_ask_rule")
                .and_then(|v| serde_json::from_value(v.clone()).ok()),
            agent_id: text("agent_id"),
            mcp_server: text("mcp_server"),
            permission_suggestions: obj.get("permission_suggestions").cloned(),
            blocked_path: text("blocked_path"),
            classifier_approvable: flag("classifier_approvable"),
            suppress_always_allow_rule: flag("suppress_always_allow_rule"),
            default_to_no: flag("default_to_no"),
            requires_user_interaction: flag("requires_user_interaction"),
            tool_name,
            tool_use_id,
            input,
        })
    }

    /// The reason line (§6.3). `cwd` is where the session runs (project settings
    /// are read from there); `settings` supplies the ask rules.
    pub fn reason(&self, cwd: Option<&Path>, settings: &dyn SettingsSource) -> Reason {
        if let Some(m) = &self.matched_ask_rule {
            let rule = m.rule_text();
            return Reason::ask_rule(Some(FoundRule {
                rule,
                source_path: m.source.clone(),
                found_by: "cli".into(),
            }));
        }
        if self.decision_reason_type.as_deref() == Some("rule") {
            let found = settings
                .ask_rules(cwd)
                .into_iter()
                .find(|r| r.matches(&self.tool_name, &self.input))
                .map(|r| FoundRule {
                    rule: r.rule,
                    source_path: r.source_path,
                    found_by: "nostromo".into(),
                });
            return Reason::ask_rule(found);
        }
        if let Some(text) = self
            .decision_reason
            .as_deref()
            .filter(|t| !t.trim().is_empty())
        {
            let kind = if self.decision_reason_type.as_deref() == Some("safetyCheck") {
                ReasonKind::SafetyCheck
            } else {
                ReasonKind::Other
            };
            return Reason::plain(kind, text);
        }
        if self.writes_settings_file() {
            return Reason::plain(ReasonKind::SettingsWrite, "Changes a Claude settings file");
        }
        Reason::plain(ReasonKind::Other, "Claude Code asked for approval")
    }

    /// Does the request write a Claude settings file?
    fn writes_settings_file(&self) -> bool {
        if !matches!(
            self.tool_kind,
            ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit
        ) {
            return false;
        }
        let path = ["file_path", "notebook_path"]
            .iter()
            .find_map(|k| self.input.get(*k).and_then(Value::as_str))
            .or(self.blocked_path.as_deref());
        path.is_some_and(|p| {
            let p = Path::new(p);
            let in_claude_dir = p
                .parent()
                .and_then(Path::file_name)
                .is_some_and(|d| d == ".claude");
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or_default();
            in_claude_dir && matches!(name, "settings.json" | "settings.local.json")
        })
    }
}

/// Why Claude Code asked.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Reason {
    pub kind: ReasonKind,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rule: Option<FoundRule>,
}

impl Reason {
    fn plain(kind: ReasonKind, text: &str) -> Self {
        Self {
            kind,
            text: text.to_owned(),
            rule: None,
        }
    }

    fn ask_rule(rule: Option<FoundRule>) -> Self {
        let text = match &rule {
            Some(r) => format!("your rule `{}` in `{}`", r.rule, r.source_path),
            None => "One of your Claude ask rules matched".to_owned(),
        };
        Self {
            kind: ReasonKind::AskRule,
            text,
            rule,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasonKind {
    AskRule,
    SafetyCheck,
    SettingsWrite,
    Other,
}

/// The ask rule behind a request, and who found it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FoundRule {
    pub rule: String,
    pub source_path: String,
    /// `"nostromo"` when we matched it against the settings files, `"cli"`
    /// when the CLI named it.
    pub found_by: String,
}

// ── ask rules ─────────────────────────────────────────────────────────────────

/// One `permissions.ask` entry and the file it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskRule {
    /// Claude's rule text: `Bash(rm:*)`, `Edit`, `mcp__slack`.
    pub rule: String,
    /// The settings file, `~`-abbreviated for the home directory.
    pub source_path: String,
}

impl AskRule {
    /// Does this rule cover the call? A rule is `Tool` or `Tool(content)`:
    /// - **Bash**: `content` is an exact command or a prefix (`rm:*`, `rm *`); it matches
    ///   when any simple command in the input (nested ones included) has those words first.
    /// - **mcp__server** covers every tool of that server.
    /// - Other tools: `content` is a `*` wildcard over the file path.
    pub fn matches(&self, tool_name: &str, input: &Value) -> bool {
        let (tool, content) = match self.rule.split_once('(') {
            Some((t, rest)) => (t, Some(rest.strip_suffix(')').unwrap_or(rest))),
            None => (self.rule.as_str(), None),
        };
        if tool != tool_name {
            // `mcp__server` covers `mcp__server__tool`.
            let covers = content.is_none()
                && tool.starts_with("mcp__")
                && tool_name
                    .strip_prefix(tool)
                    .is_some_and(|rest| rest.starts_with("__"));
            return covers;
        }
        let Some(content) = content else { return true };
        if tool_name == "Bash" {
            let Some(command) = input.get("command").and_then(Value::as_str) else {
                return false;
            };
            return bash_rule_matches(content, command);
        }
        let path = ["file_path", "notebook_path", "path"]
            .iter()
            .find_map(|k| input.get(*k).and_then(Value::as_str));
        path.is_some_and(|p| wildcard(content, p))
    }
}

fn bash_rule_matches(content: &str, command: &str) -> bool {
    let (prefix, exact) = match content
        .strip_suffix(":*")
        .or_else(|| content.strip_suffix(" *"))
    {
        Some(p) => (p, false),
        None => (content, true),
    };
    // A `*` anywhere else (`Bash(*)`, `Bash(ls*)`) is a wildcard over the command text.
    if prefix.contains('*') {
        let shell = shell::parse(command);
        let any_command = shell
            .commands
            .iter()
            .any(|c| wildcard(content, &c.texts().join(" ")));
        return any_command || wildcard(content, command.trim());
    }
    let rule_words: Vec<&str> = prefix.split_whitespace().collect();
    if rule_words.is_empty() {
        return !exact;
    }
    shell::parse(command).commands.iter().any(|c| {
        let words = c.texts();
        if exact {
            words == rule_words
        } else {
            words.len() >= rule_words.len() && words[..rule_words.len()] == rule_words[..]
        }
    })
}

/// `*` matches any run of characters, everything else matches itself.
fn wildcard(pattern: &str, text: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    let (first, rest) = parts.split_first().expect("split yields one part");
    let Some(mut at) = text.strip_prefix(first).map(|t| text.len() - t.len()) else {
        return false;
    };
    let Some((last, middle)) = rest.split_last() else {
        return text == *first;
    };
    for part in middle {
        match text[at..].find(part) {
            Some(i) => at += i + part.len(),
            None => return false,
        }
    }
    text.len() - at >= last.len() && text.ends_with(last)
}

/// Where the ask rules come from.
pub trait SettingsSource: Send + Sync {
    /// Every `permissions.ask` rule visible to a session running in `cwd`, in
    /// the order Claude reads the files.
    fn ask_rules(&self, cwd: Option<&Path>) -> Vec<AskRule>;
}

/// The three files, read-only: `~/.claude/settings.json`,
/// `<cwd>/.claude/settings.json` and `<cwd>/.claude/settings.local.json`.
#[derive(Debug, Clone)]
pub struct FileSettings {
    home: Option<PathBuf>,
}

impl FileSettings {
    pub fn new() -> Self {
        Self {
            home: dirs_next::home_dir(),
        }
    }
}

impl Default for FileSettings {
    fn default() -> Self {
        Self::new()
    }
}

impl SettingsSource for FileSettings {
    fn ask_rules(&self, cwd: Option<&Path>) -> Vec<AskRule> {
        let mut files: Vec<(PathBuf, String)> = Vec::new();
        if let Some(home) = &self.home {
            files.push((
                home.join(".claude/settings.json"),
                "~/.claude/settings.json".into(),
            ));
        }
        if let Some(cwd) = cwd {
            for name in [".claude/settings.json", ".claude/settings.local.json"] {
                let path = cwd.join(name);
                let shown = path.display().to_string();
                files.push((path, shown));
            }
        }
        files
            .into_iter()
            .flat_map(|(path, shown)| {
                let rules = read_settings_file(&path)
                    .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                    .and_then(|v| v.pointer("/permissions/ask").cloned())
                    .and_then(|v| v.as_array().cloned())
                    .unwrap_or_default();
                rules
                    .into_iter()
                    .filter_map(|r| r.as_str().map(str::to_owned))
                    .map(move |rule| AskRule {
                        rule,
                        source_path: shown.clone(),
                    })
            })
            .collect()
    }
}

/// Largest settings file read.
const MAX_SETTINGS_BYTES: u64 = 1 << 20;

/// A settings file's text, if it is a regular file of at most
/// [`MAX_SETTINGS_BYTES`]. It is opened without blocking and checked on the open
/// descriptor, so a FIFO or device planted at the path can't hang the broker.
fn read_settings_file(path: &Path) -> Option<String> {
    use std::io::Read;
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    if !file.metadata().ok()?.is_file() {
        return None;
    }
    let mut text = String::new();
    // One byte past the limit tells "exactly the limit" from "too big": a file that is
    // cut short could still parse and contribute rules, so it is ignored whole.
    file.take(MAX_SETTINGS_BYTES + 1)
        .read_to_string(&mut text)
        .ok()?;
    (text.len() as u64 <= MAX_SETTINGS_BYTES).then_some(text)
}

// ── text sanitizing ───────────────────────────────────────────────────────────

/// `text` without ANSI escape sequences, with every other invisible character
/// shown as its token (`⟨U+202E RLO⟩`). Newlines stay.
///
/// Only a **complete** sequence is removed: CSI (`ESC [ … final`), OSC and the
/// other string sequences (`ESC ] … BEL`/`ST`), `ESC` + intermediates + final,
/// and the 8-bit CSI/OSC introducers. An `ESC` that does not start one (the text
/// ends first, the next character is not part of a sequence, a string has no
/// terminator) is shown as `⟨U+001B⟩` and what follows stays visible, so a
/// broken sequence can never swallow the text after it. Nothing is dropped silently.
pub fn sanitize_text(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let end = match c {
            '\u{1b}' => escape_end(&chars, i + 1),
            '\u{9b}' => csi_end(&chars, i + 1),
            '\u{9d}' => string_end(&chars, i + 1),
            _ => None,
        };
        match end {
            Some(end) => i = end,
            None => {
                if c == '\n' {
                    out.push('\n');
                } else if is_invisible(c) {
                    out.push_str(&invisible_token(c));
                } else {
                    out.push(c);
                }
                i += 1;
            }
        }
    }
    out
}

/// Where the sequence that follows an `ESC` (at `chars[at - 1]`) ends, if it is complete.
fn escape_end(chars: &[char], at: usize) -> Option<usize> {
    match chars.get(at)? {
        '[' => csi_end(chars, at + 1),
        // OSC, DCS, SOS, PM, APC: strings up to BEL or ST.
        ']' | 'P' | 'X' | '^' | '_' => string_end(chars, at + 1),
        // `ESC` intermediates final (`ESC ( B`).
        c if ('\u{20}'..='\u{2f}').contains(c) => {
            let mut j = at;
            while chars
                .get(j)
                .is_some_and(|c| ('\u{20}'..='\u{2f}').contains(c))
            {
                j += 1;
            }
            chars
                .get(j)
                .filter(|c| ('\u{30}'..='\u{7e}').contains(*c))
                .map(|_| j + 1)
        }
        // `ESC` final (`ESC c`, `ESC =`).
        c if ('\u{30}'..='\u{7e}').contains(c) => Some(at + 1),
        _ => None,
    }
}

/// The end of a CSI body starting at `at`: parameter bytes, intermediates, one final byte.
fn csi_end(chars: &[char], at: usize) -> Option<usize> {
    let mut j = at;
    while let Some(c) = chars.get(j) {
        match c {
            '\u{20}'..='\u{3f}' => j += 1,
            '\u{40}'..='\u{7e}' => return Some(j + 1),
            _ => return None,
        }
    }
    None
}

/// The end of a string sequence body starting at `at`: after BEL, `ST` or `ESC \`.
fn string_end(chars: &[char], at: usize) -> Option<usize> {
    let mut j = at;
    while let Some(c) = chars.get(j) {
        match c {
            '\u{7}' | '\u{9c}' => return Some(j + 1),
            '\u{1b}' if chars.get(j + 1) == Some(&'\\') => return Some(j + 2),
            _ => j += 1,
        }
    }
    None
}
