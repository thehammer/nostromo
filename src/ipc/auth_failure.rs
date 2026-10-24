//! Spotting a turn that failed because Claude could not authenticate.
//!
//! A session whose login expired answers every message with one synthetic
//! assistant line and an error result (CLI 2.1.301):
//!
//! ```text
//! {"type":"assistant","error":"authentication_failed","isApiErrorMessage":true,
//!  "message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence",
//!   "usage":{"input_tokens":0,"output_tokens":0},
//!   "content":[{"type":"text","text":"Failed to authenticate: …"}]}, …}
//! ```
//!
//! The live `result` line of such a turn was never captured, so the matcher is
//! tolerant: any one of three signals counts ([`AuthSignal`]). It sits beside
//! the parser, not inside the wire types: [`classify_line`] looks at each raw
//! stdout line, and [`TurnAuthTracker`] follows one turn to its end and says
//! whether it was an auth failure and whether sending its message again is safe.
//!
//! **Nothing here keeps or logs the matched text.** Only the signal's short id
//! (`s1`/`s2`/`s3`) may be logged.

use serde_json::Value;

use super::stream_json::{ParsedLine, TurnBlock};

/// A line longer than this is never a match (and is never JSON-parsed here): an
/// auth failure is a short line, and a huge one is some other output that
/// quotes the words.
const MAX_LINE_BYTES: usize = 64 * 1024;

/// Only this many characters of a text are matched against [`AUTH_PATTERNS`]: the
/// CLI's own message is short, and prose that merely quotes it has it later.
const MATCH_WINDOW_CHARS: usize = 512;

/// A line must contain one of these (ASCII case-insensitively) before it is
/// JSON-parsed. The first five are the spec's; the last two keep the two
/// [`AUTH_PATTERNS`] that none of them would otherwise catch reachable.
const NEEDLES: [&str; 7] = [
    "authenticat",
    "oauth",
    "/login",
    "api key",
    "401",
    "be refreshed",
    "not logged in",
];

/// What the CLI says when it cannot authenticate. Matched case-insensitively
/// against the first [`MATCH_WINDOW_CHARS`] characters of a text. (The pattern
/// `401` together with `unauthorized` or `authentication` is [`has_401_auth`].)
pub const AUTH_PATTERNS: &[&str] = &[
    "failed to authenticate",
    "oauth session expired",
    "oauth token has expired",
    "oauth token revoked",
    "could not be refreshed",
    "invalid api key",
    "run /login",
    "authentication_error",
    "not logged in",
];

/// Counts the lines [`classify_line`] parsed as JSON, so a test can prove an
/// oversize line is not parsed at all.
#[cfg(test)]
pub static JSON_PARSES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// How an auth failure was recognised.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthSignal {
    /// S1: an `assistant` line whose top-level `error` is `authentication_failed`.
    ErrorField,
    /// S2: a synthetic assistant line whose text matches [`AUTH_PATTERNS`].
    SyntheticText,
    /// S3: an error `result` whose text matches [`AUTH_PATTERNS`].
    ResultText,
}

impl AuthSignal {
    /// The stable short id for logs: `s1`, `s2` or `s3`.
    pub fn id(self) -> &'static str {
        match self {
            AuthSignal::ErrorField => "s1",
            AuthSignal::SyntheticText => "s2",
            AuthSignal::ResultText => "s3",
        }
    }
}

/// Does this raw stdout line say Claude could not authenticate? `None` for any
/// other line, for a line longer than 64 KiB and for a line that does not pass
/// the cheap byte prefilter, none of which is JSON-parsed.
pub fn classify_line(line: &str) -> Option<AuthSignal> {
    if line.len() > MAX_LINE_BYTES || !passes_prefilter(line.as_bytes()) {
        return None;
    }
    #[cfg(test)]
    JSON_PARSES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let value: Value = serde_json::from_str(line).ok()?;
    match value.get("type")?.as_str()? {
        "assistant" => assistant_signal(&value),
        "result" => result_signal(&value),
        _ => None,
    }
}

/// What one turn amounted to, if it was an auth failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TurnAuthOutcome {
    /// The first signal the turn showed.
    pub signal: AuthSignal,
    /// The turn produced no real model output, so sending its message again
    /// repeats nothing. (That the daemon wrote the message is a separate
    /// condition, which the session checks.)
    pub resendable: bool,
}

/// Follows one turn: fed every raw line's signal and its parse, it says at the
/// turn's end whether it was an auth failure and whether it did any real work.
#[derive(Debug, Default)]
pub struct TurnAuthTracker {
    signal: Option<AuthSignal>,
    real_output: bool,
}

impl TurnAuthTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// A new turn starts: forget the last one.
    pub fn begin_turn(&mut self) {
        *self = Self::default();
    }

    /// One raw line of the current turn: what [`classify_line`] said of it and
    /// what `parse_line` made of it. "Real output" is any tool call, or any
    /// non-empty blocks from a line that was not itself an auth signal.
    pub fn feed(&mut self, signal: Option<AuthSignal>, parsed: Option<&ParsedLine>) {
        if self.signal.is_none() {
            self.signal = signal;
        }
        if let Some(ParsedLine::Blocks { blocks, .. }) = parsed {
            let tool_call = blocks.iter().any(|b| matches!(b, TurnBlock::ToolCall { .. }));
            if tool_call || (signal.is_none() && !blocks.is_empty()) {
                self.real_output = true;
            }
        }
    }

    /// The turn ended. `Some` when it showed an auth signal. Resets the tracker.
    pub fn finish(&mut self) -> Option<TurnAuthOutcome> {
        let done = std::mem::take(self);
        done.signal.map(|signal| TurnAuthOutcome { signal, resendable: !done.real_output })
    }
}

// ── matching ───────────────────────────────────────────────────────────────────

fn passes_prefilter(line: &[u8]) -> bool {
    NEEDLES.iter().any(|needle| contains_ignore_ascii_case(line, needle.as_bytes()))
}

fn contains_ignore_ascii_case(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle))
}

fn assistant_signal(value: &Value) -> Option<AuthSignal> {
    if value.get("error").and_then(Value::as_str) == Some("authentication_failed") {
        return Some(AuthSignal::ErrorField);
    }
    let message = value.get("message")?;
    if message.get("model").and_then(Value::as_str) != Some("<synthetic>") {
        return None;
    }
    let matched = match message.get("content")? {
        Value::String(text) => matches_auth_text(text),
        Value::Array(blocks) => blocks.iter().any(|block| {
            block.get("type").and_then(Value::as_str) == Some("text")
                && block.get("text").and_then(Value::as_str).is_some_and(matches_auth_text)
        }),
        _ => false,
    };
    matched.then_some(AuthSignal::SyntheticText)
}

fn result_signal(value: &Value) -> Option<AuthSignal> {
    if value.get("is_error").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let text = value.get("result").and_then(Value::as_str)?;
    matches_auth_text(text).then_some(AuthSignal::ResultText)
}

/// Does the start of `text` say Claude cannot authenticate?
fn matches_auth_text(text: &str) -> bool {
    let head: String = text.chars().take(MATCH_WINDOW_CHARS).collect::<String>().to_lowercase();
    AUTH_PATTERNS.iter().any(|pattern| head.contains(pattern)) || has_401_auth(&head)
}

/// `401` together with `unauthorized` or `authentication`: an HTTP 401 error.
fn has_401_auth(head: &str) -> bool {
    head.contains("401") && (head.contains("unauthorized") || head.contains("authentication"))
}

#[cfg(test)]
mod tests;
