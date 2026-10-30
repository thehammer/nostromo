//! What a staged command, its note and the agent's name may say.
//!
//! The command is *display text*: the user clicks it into the prompt and presses
//! Enter, so it is held to what a person can read and judge at a glance: one
//! printable line, no secrets, and nothing that starts a production shell.

use crate::data::work::is_invisible;
use crate::terminal::redact::Redactor;

use super::{MAX_AGENT_NAME_CHARS, MAX_COMMAND_CHARS, MAX_NOTE_CHARS};

/// Why a command or a note was refused. Nothing was stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StagingTextCode {
    /// Empty, more than one line, or a control or invisible character.
    InvalidText,
    EntryTooLong,
    NoteTooLong,
    /// The redactor would redact something in it.
    LooksLikeSecret,
    /// It starts an ECS exec session, an SSM session or the like.
    RemoteShellCommand,
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
        }
    }

    /// What the agent should do about it.
    pub fn detail(self) -> &'static str {
        match self {
            Self::InvalidText => {
                "a command is one non-empty line of printable text: no line break, tab, control or invisible character"
            }
            Self::EntryTooLong => "a command is at most 1000 characters",
            Self::NoteTooLong => "a note is at most 120 characters",
            Self::LooksLikeSecret => "it contains something that looks like a secret or personal data; do not stage it",
            Self::RemoteShellCommand => "ask with nostromo.request_remote_shell instead",
        }
    }
}

/// May `text` be staged as a command? The first failing rule wins.
pub fn validate_command(text: &str) -> Result<(), StagingTextCode> {
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
    if looks_like_secret(text) {
        return Err(Code::LooksLikeSecret);
    }
    if crate::approvals::guard::remote_shell_marker(text).is_some() {
        return Err(Code::RemoteShellCommand);
    }
    Ok(())
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
