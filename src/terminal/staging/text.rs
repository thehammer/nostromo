//! What a staged command, its note and the agent's name may say.
//!
//! The command is *display text*: the user clicks it into the prompt and presses
//! Enter, so it is held to what a person can read and judge at a glance: one
//! printable line, no secrets, and nothing that starts a production shell.

use crate::data::work::is_invisible;
use crate::terminal::redact::Redactor;

use super::{MAX_AGENT_NAME_CHARS, MAX_COMMAND_CHARS, MAX_NOTE_CHARS};

/// The longest run of consecutive spaces a command may hold. More would let a
/// command push its real tail out of the drawer's visible lines.
const MAX_SPACE_RUN: usize = 4;

/// Why a command or a note was refused. Nothing was stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StagingTextCode {
    /// Empty, more than one line, a control or invisible character, or
    /// whitespace that hides text (see [`hides_behind_whitespace`]).
    InvalidText,
    EntryTooLong,
    NoteTooLong,
    /// The redactor would redact something in it.
    LooksLikeSecret,
    /// It starts an ECS exec session, an SSM session or the like.
    RemoteShellCommand,
    /// Shell history expansion (`!!`, `^a^b`, `r`, `fc`, `history`) in a
    /// terminal that is not a plain local shell at a prompt: what runs may
    /// differ from what the user reads.
    HistoryExpansion,
    /// It would type into another terminal (tmux `send-keys`, screen `stuff`).
    TypesIntoAnotherTerminal,
}

impl StagingTextCode {
    /// The code the agent is told.
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidText => "invalid_text",
            Self::EntryTooLong => "entry_too_long",
            Self::NoteTooLong => "note_too_long",
            Self::LooksLikeSecret => "looks_like_secret",
            Self::RemoteShellCommand => "remote_shell_command",
            Self::HistoryExpansion => "history_expansion",
            Self::TypesIntoAnotherTerminal => "types_into_another_terminal",
        }
    }

    /// What the agent should do about it.
    pub fn detail(self) -> &'static str {
        match self {
            Self::InvalidText => {
                "a command is one non-empty line of printable text: no line break, tab, control or invisible character, no leading or trailing space, no space but U+0020, and no more than 4 spaces in a row"
            }
            Self::EntryTooLong => "a command is at most 1000 characters",
            Self::NoteTooLong => "a note is at most 120 characters",
            Self::LooksLikeSecret => "it contains something that looks like a secret or personal data; do not stage it",
            Self::RemoteShellCommand => "ask with nostromo.request_remote_shell instead",
            Self::HistoryExpansion => {
                "history expansion runs something other than what the user reads; spell the command out"
            }
            Self::TypesIntoAnotherTerminal => "staging never types into another pane",
        }
    }
}

/// May `text` be staged as a command? The first failing rule wins.
pub fn validate_command(text: &str) -> Result<(), StagingTextCode> {
    validate_command_in(text, false)
}

/// [`validate_command`], and when `no_history_expansion` also refuse text that
/// uses shell history expansion (set for a terminal that is not a plain local
/// shell: remote, or a local one with a program in the foreground).
pub fn validate_command_in(text: &str, no_history_expansion: bool) -> Result<(), StagingTextCode> {
    use StagingTextCode as Code;
    if text.trim().is_empty() {
        return Err(Code::InvalidText);
    }
    // The tracker's rule first: staging is a strict superset of it.
    if crate::tracker::format::validate_command_text(text).is_err() {
        return Err(Code::InvalidText);
    }
    if text.chars().any(|c| c.is_control() || is_invisible(c)) || imitates_nostromo_markup(text) {
        return Err(Code::InvalidText);
    }
    if text.chars().count() > MAX_COMMAND_CHARS {
        return Err(Code::EntryTooLong);
    }
    if hides_behind_whitespace(text) {
        return Err(Code::InvalidText);
    }
    if looks_like_secret(text) {
        return Err(Code::LooksLikeSecret);
    }
    if crate::approvals::guard::remote_shell_marker(text).is_some() {
        return Err(Code::RemoteShellCommand);
    }
    if types_into_another_terminal(text) {
        return Err(Code::TypesIntoAnotherTerminal);
    }
    if no_history_expansion && uses_history_expansion(text) {
        return Err(Code::HistoryExpansion);
    }
    Ok(())
}

/// Expansions that are empty at run time, so a shell sees right through them: `rm${IFS}-rf` is `rm -rf`
/// (IFS is whitespace), `r$()m` and `r$@m` are `rm`. Longest first.
const EMPTY_EXPANSIONS: [&str; 5] = ["${IFS}", "$IFS", "$()", "$@", "$*"];

/// Length in chars of the empty expansion starting at `chars[0]` (a `$`), if there is one: the fixed forms above,
/// a positional parameter (`$0`-`$9`, `${0}`-`${9}`: the common `rm$IFS$9-rf`) and `${IFS` with a modifier
/// (`${IFS%?}`, `${IFS:0:1}`, `${IFS#?}`), which run to the closing brace.
fn empty_expansion_len(chars: &[char]) -> Option<usize> {
    if let Some(e) = EMPTY_EXPANSIONS
        .iter()
        .find(|e| chars.iter().copied().take(e.len()).eq(e.chars()))
    {
        return Some(e.chars().count());
    }
    if chars.get(1).is_some_and(|c| c.is_ascii_digit()) {
        return Some(2);
    }
    if chars.get(1) == Some(&'{')
        && chars.get(2).is_some_and(|c| c.is_ascii_digit())
        && chars.get(3) == Some(&'}')
    {
        return Some(4);
    }
    if chars.len() > 5 && chars[1..5] == ['{', 'I', 'F', 'S'] {
        // Only modifiers that keep a (whitespace) character or nothing: `%` and `#` with a literal pattern, and
        // `:N` / `:N:M`. `:+`, `:-`, `=`, `/` and anything holding `$`, a backtick or `(` are NOT swallowed: their
        // operand can run a command, so it stays visible to the rules.
        let close = chars[5..].iter().position(|&c| c == '}')?;
        let body = &chars[5..5 + close];
        let literal = |b: &[char]| {
            !b.iter()
                .any(|c| matches!(c, '$' | '`' | '(' | ')' | '{' | '\\' | '\'' | '"'))
        };
        let offset = body.first() == Some(&':')
            && body[1..].iter().all(|c| c.is_ascii_digit() || *c == ':')
            && body.len() > 1;
        let strip = matches!(body.first(), Some('%' | '#')) && literal(&body[1..]);
        return (offset || strip).then_some(6 + close);
    }
    None
}

/// The text as a shell would see its words, for the hazard rules (the Mac app's `StagingHazards.normalised`
/// does the same, and the shared fixture `tests/fixtures/terminal_staging/hazards.json` pins both for the normalised text and the
/// rule verdicts, and its `destructive` names for [`super::destructive`]; only `escape_quoted` is exercised by the Swift test alone): `/* ... */`
/// comments become a space (SQL treats one as whitespace), quotes and backslashes are dropped (`r''m`,
/// `\rm`, `"rm"` become `rm`; the `$` of an ANSI-C `$'...'` quote goes too), an empty expansion (`$IFS`,
/// `${IFS}`, `$@`, `$*`, `$()`, `$0`-`$9`, `${IFS%?}`) becomes a space, backticks, parentheses and braces become `;` (a subshell, a
/// command substitution and a group each start a new command), and runs of whitespace collapse. Quotes are
/// not otherwise parsed: asking or refusing is the cheap side, so a hazard inside a quoted string matches too.
pub fn normalise_for_hazards(text: &str) -> String {
    normalise_with(text, " ")
}

/// [`normalise_for_hazards`] with the empty expansions removed instead of turned into a space: inside a word
/// (`r$@m`) the shell glues the two halves together, between words (`rm${IFS}-rf`) they are separate.
/// Hazard rules look at both forms.
pub fn normalise_for_hazards_joined(text: &str) -> String {
    normalise_with(text, "")
}

/// Both forms, the one with empty expansions as a space first.
fn hazard_views(text: &str) -> [String; 2] {
    [
        normalise_for_hazards(text),
        normalise_for_hazards_joined(text),
    ]
}

fn normalise_with(text: &str, empty: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        i += 1;
        if let Some(len) = (c == '$')
            .then(|| empty_expansion_len(&chars[i - 1..]))
            .flatten()
        {
            i += len - 1;
            if !(empty == " " && out.ends_with(' ')) {
                out.push_str(empty);
            }
            continue;
        }
        match c {
            '/' if chars.get(i) == Some(&'*') => {
                i += 1;
                let mut prev = '\0';
                while i < chars.len() {
                    let n = chars[i];
                    i += 1;
                    if prev == '*' && n == '/' {
                        break;
                    }
                    prev = n;
                }
                out.push(' ');
            }
            '$' if chars.get(i) == Some(&'\'') => {}
            '\'' | '"' | '\\' => {}
            '`' | '(' | ')' | '{' | '}' => out.push(';'),
            c if c.is_whitespace() => {
                if !out.ends_with(' ') {
                    out.push(' ');
                }
            }
            c => out.push(c),
        }
    }
    out
}

/// Words of the normalised text, split at whitespace and at command separators.
fn hazard_words(normalised: &str) -> Vec<&str> {
    normalised
        .split(|c: char| c.is_whitespace() || matches!(c, ';' | '|' | '&'))
        .filter(|w| !w.is_empty())
        .collect()
}

/// tmux verbs that type, paste or pipe into a pane.
const TMUX_INPUT_VERBS: [&str; 6] = [
    "send-keys",
    "paste-buffer",
    "pipe-pane",
    "send-prefix",
    "respawn-pane",
    "respawn-window",
];

/// Other terminal multiplexers' and terminals' verbs that type into a pane: `(program word, verb word)`.
const OTHER_INPUT_VERBS: [(&str, &str); 5] = [
    ("kitty", "send-text"),
    ("kitten", "send-text"),
    ("wezterm", "send-text"),
    ("zellij", "write-chars"),
    ("zellij", "write"),
];

/// tmux accepts any unique prefix of a command name, so a word of at least three letters that begins a tmux
/// input verb counts (`send-k`, `paste-b`), after any `tmux` word. Also GNU screen's `-X stuff`, the other
/// terminals' send-text verbs, and `osascript` with `do script` / `write text`. Everything on the normalised
/// text and on the text as written; a hit on either refuses.
fn types_into_another_terminal(text: &str) -> bool {
    if crate::approvals::guard::tmux_input_marker(text) {
        return true;
    }
    static SCREEN: std::sync::OnceLock<regex::Regex> = std::sync::OnceLock::new();
    let screen = SCREEN.get_or_init(|| regex::Regex::new(r"(?is)screen.*-X.*stuff").unwrap());
    if screen.is_match(text) {
        return true;
    }
    hazard_views(text).iter().any(|normalised| {
        if screen.is_match(normalised) {
            return true;
        }
        let lower = normalised.to_lowercase();
        if crate::approvals::guard::tmux_input_marker(&lower) {
            return true;
        }
        let words = hazard_words(&lower);
        if let Some(first_tmux) = words
            .iter()
            .position(|w| w.rsplit('/').next() == Some("tmux"))
        {
            if words[first_tmux + 1..]
                .iter()
                .any(|w| w.len() >= 3 && TMUX_INPUT_VERBS.iter().any(|verb| verb.starts_with(w)))
            {
                return true;
            }
        }
        if OTHER_INPUT_VERBS.iter().any(|(program, verb)| {
            words
                .iter()
                .position(|w| w.rsplit('/').next() == Some(*program))
                .is_some_and(|at| words[at + 1..].iter().any(|w| w == verb))
        }) {
            return true;
        }
        lower.contains("osascript") && (lower.contains("do script") || lower.contains("write text"))
    })
}

/// Words before a command that still leave the next word in command position.
const COMMAND_PREFIX_WORDS: [&str; 21] = [
    "then",
    "do",
    "else",
    "elif",
    "if",
    "while",
    "until",
    "!",
    "-",
    "command",
    "builtin",
    "eval",
    "exec",
    "time",
    "sudo",
    "noglob",
    "nocorrect",
    "nohup",
    "nice",
    "env",
    "coproc",
];

/// Does `word` leave the next word in command position? A [`COMMAND_PREFIX_WORDS`] entry, a prefix
/// assignment (`X=1 r` runs the builtin), an option or a number (`nice -n 5 r`, `sudo -E r`). Only read for
/// words before the segment's command, so `ls -r` still stops at `ls`.
fn is_command_prefix(word: &str) -> bool {
    COMMAND_PREFIX_WORDS.contains(&word)
        || word.starts_with('-')
        || word.bytes().all(|b| b.is_ascii_digit())
        || word.split_once('=').is_some_and(|(name, _)| {
            !name.is_empty()
                && !name.starts_with(|c: char| c.is_ascii_digit())
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

/// Would a shell expand history in `text`? Quotes are not parsed: asking or
/// refusing is the cheap side. A `!` followed by anything but a space, `=` or
/// `(`; text starting with `^`; `fc` or `history` as a word anywhere (after
/// [`normalise_for_hazards`]: `\fc`, `'fc'`, `$(fc -s)` all count); or `r` in
/// command position: first in a segment (split on `;`, `&`, `&&`, `|`, `||`,
/// a subshell, a substitution, a group or a backtick), or after `then`,
/// `do`, `else`, `elif`, `if`, `while`, `until`, `!`, `command`, `builtin`, `eval`, `exec`, `time`, `sudo`,
/// `noglob`, `nocorrect`, `nohup`, `nice`, `env` or `coproc`, a `-` (zsh's modifier), an option, a number or a
/// prefix assignment (`X=1 r`, `nice -n 5 r`); empty expansions (`$IFS`, `$@`, `$()`) are seen through.
pub fn uses_history_expansion(text: &str) -> bool {
    let chars: Vec<char> = text.chars().collect();
    if chars.iter().enumerate().any(|(i, c)| {
        *c == '!'
            && chars
                .get(i + 1)
                .is_some_and(|n| !matches!(n, ' ' | '=' | '('))
    }) {
        return true;
    }
    if text.starts_with('^') {
        return true;
    }
    hazard_views(text).iter().any(|normalised| {
        hazard_words(normalised)
            .iter()
            .any(|w| matches!(*w, "fc" | "history"))
            || normalised.split([';', '|', '&']).any(|segment| {
                segment.split_whitespace().find(|w| !is_command_prefix(w)) == Some("r")
            })
    })
}

/// The note as it is kept: `Ok(None)` when nothing is left of it (so a note of
/// `""` clears one).
pub fn clean_note(text: &str) -> Result<Option<String>, StagingTextCode> {
    if text.chars().count() > MAX_NOTE_CHARS {
        return Err(StagingTextCode::NoteTooLong);
    }
    let mut cleaned = String::with_capacity(text.len());
    let mut pending_space = false;
    for c in text.chars() {
        if c.is_whitespace() || matches!(c, '\u{2028}' | '\u{2029}') {
            pending_space = !cleaned.is_empty();
        } else if !is_invisible(c) {
            if pending_space {
                cleaned.push(' ');
                pending_space = false;
            }
            cleaned.push(c);
        }
    }
    if cleaned.is_empty() {
        return Ok(None);
    }
    if imitates_nostromo_markup(&cleaned) {
        return Err(StagingTextCode::InvalidText);
    }
    if looks_like_secret(&cleaned) {
        return Err(StagingTextCode::LooksLikeSecret);
    }
    Ok(Some(cleaned))
}

/// Can whitespace in `text` hide part of it? Leading or trailing whitespace
/// (a leading space also keeps a command out of shell history), any space
/// separator but U+0020 (U+00A0, U+2003, U+3000, …: all of them, Unicode
/// category Zs, are White_Space), or a run of more than [`MAX_SPACE_RUN`]
/// spaces, which pushes what follows out of the drawer's visible lines.
fn hides_behind_whitespace(text: &str) -> bool {
    if text.trim() != text {
        return true;
    }
    let mut run = 0;
    for c in text.chars() {
        if c == ' ' {
            run += 1;
            if run > MAX_SPACE_RUN {
                return true;
            }
        } else if c.is_whitespace() {
            return true;
        } else {
            run = 0;
        }
    }
    false
}

/// Does `text` open or close one of Nostromo's own elements
/// (`<nostromo-terminal-output`, `</nostromo-note>`, …)? Text that does is
/// trying to look like the system speaking, wherever it ends up echoed.
fn imitates_nostromo_markup(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("<nostromo-") || lower.contains("</nostromo-")
}

/// Would the terminal redactor redact anything in `text`? (It also matches
/// SSN- and date-of-birth-shaped values: personal data is not staged either.)
pub fn looks_like_secret(text: &str) -> bool {
    !Redactor::new().redact(text).1.is_empty()
}

/// The agent's name as the drawer may show it: one line, nothing invisible,
/// at most [`MAX_AGENT_NAME_CHARS`] scalars. Never empty: the tag stands in,
/// cleaned the same way, and `agent` if that too is empty.
pub fn sanitize_agent_name(name: Option<&str>, tag: &str) -> String {
    name.map(one_clean_line)
        .filter(|n| !n.is_empty())
        .or_else(|| Some(one_clean_line(tag)).filter(|n| !n.is_empty()))
        .unwrap_or_else(|| "agent".to_string())
}

fn one_clean_line(text: &str) -> String {
    let mut out = String::new();
    let mut pending_space = false;
    for c in text.chars() {
        if c.is_whitespace() {
            pending_space = !out.is_empty();
        } else if !is_invisible(c) {
            if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.push(c);
        }
    }
    if out.chars().count() > MAX_AGENT_NAME_CHARS {
        out = out.chars().take(MAX_AGENT_NAME_CHARS - 1).collect();
        out = out.trim_end().to_string();
        out.push('…');
    }
    out
}
