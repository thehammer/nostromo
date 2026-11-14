//! Slash commands in a session's stream: what the CLI echoes for one, and
//! what a local command prints.
//!
//! # Classification (the rule the code and its tests cite)
//!
//! Decided by the CLI's own signals, never by a list of command names:
//!
//! * **LOCAL**: the CLI answered itself and ran no model turn. Any one of
//!   (a) live, an assistant line with a top-level `local_command_run` (or
//!   `local_command_source`); (b) live, a user line whose text starts with
//!   `<local-command-stdout>` or `<local-command-stderr>`, while a message the
//!   daemon wrote that starts with `/` is still unanswered; (c) stored, a
//!   `system` line with `subtype: "local_command"`, or such a user line, that
//!   follows a `<command-name>` user line. It becomes one record turn
//!   ([`TurnOrigin::LocalCommand`](super::TurnOrigin::LocalCommand)), never a
//!   bubble.
//! * **PROMPT-TYPE**: the CLI echoed the command as a
//!   `<command-message>`/`<command-name>` harness line (live: `isReplay: true`;
//!   stored: the harness line) and no local output follows it. It becomes the
//!   user's own turn, drawn as the normal bubble.
//! * **Anything else** with a leading slash came back as plain text: the CLI's
//!   verdict that it is a prompt. No change.
//!
//! See `docs/slash-commands.md`.

use crate::data::work::untrusted::{one_line, sanitize_block};

/// Bytes of a local command's output a record keeps (`/context` runs ~10 KB).
pub const LOCAL_COMMAND_OUTPUT_BYTES: usize = 16 * 1024;
const COMMAND_NAME_CHARS: usize = 64;
const COMMAND_ARGS_CHARS: usize = 512;

const STDOUT_OPEN: &str = "<local-command-stdout>";
const STDOUT_CLOSE: &str = "</local-command-stdout>";
const STDERR_OPEN: &str = "<local-command-stderr>";
const STDERR_CLOSE: &str = "</local-command-stderr>";

/// The stream and unwrapped body of a `<local-command-stdout|stderr>` text:
/// `None` unless `text` (leading whitespace aside) starts with one of the two
/// opening tags. Any other `<local-command-*>` kind (the caveat) is not output.
pub(super) fn split_local_output(text: &str) -> Option<(&'static str, &str)> {
    let trimmed = text.trim_start();
    let (stream, open, close) = if trimmed.starts_with(STDOUT_OPEN) {
        ("stdout", STDOUT_OPEN, STDOUT_CLOSE)
    } else if trimmed.starts_with(STDERR_OPEN) {
        ("stderr", STDERR_OPEN, STDERR_CLOSE)
    } else {
        return None;
    };
    let rest = &trimmed[open.len()..];
    let body = rest.find(close).map_or(rest, |end| &rest[..end]);
    Some((stream, body))
}

/// A local command's output as a record keeps it: sanitised, redacted, then
/// capped (and whether the cap cut it).
pub(super) fn record_output(body: &str) -> (String, bool) {
    let cleaned = sanitize_block(body.trim_matches('\n'));
    let (redacted, _) = crate::terminal::redact::Redactor::new().redact(&cleaned);
    cap_bytes(&redacted, LOCAL_COMMAND_OUTPUT_BYTES)
}

/// The name and arguments a harness line (`<command-name>`, `<command-message>`,
/// `<command-args>`, in whichever order) carries. `None` unless the text starts
/// with one of the three tags and names a command.
pub(super) fn parse_command_echo(text: &str) -> Option<(String, String)> {
    let trimmed = text.trim_start();
    if !(trimmed.starts_with("<command-name>")
        || trimmed.starts_with("<command-message>")
        || trimmed.starts_with("<command-args>"))
    {
        return None;
    }
    let name = tag_body(trimmed, "command-name")
        .map(|n| n.trim().trim_start_matches('/').to_owned())
        .filter(|n| !n.is_empty())
        .or_else(|| {
            tag_body(trimmed, "command-message")
                .map(|n| n.trim().trim_start_matches('/').to_owned())
                .filter(|n| !n.is_empty())
        })?;
    let args = tag_body(trimmed, "command-args").unwrap_or_default();
    Some((clean_name(&name)?, one_line(args, COMMAND_ARGS_CHARS)))
}

/// `/<name> <args>` of a message the daemon wrote: its command and arguments.
/// `None` unless the text (after the leading whitespace) is `/name` followed by
/// whitespace or the end.
pub(crate) fn split_typed_command(text: &str) -> Option<(String, String)> {
    let trimmed = text.trim();
    let rest = trimmed.strip_prefix('/')?;
    let (name, args) = rest
        .split_once(char::is_whitespace)
        .map_or((rest, ""), |(n, a)| (n, a.trim()));
    if name.is_empty() || name.contains('/') {
        return None;
    }
    Some((clean_name(name)?, one_line(args, COMMAND_ARGS_CHARS)))
}

/// The `user_input` of a command's turn: `/<command>`, then ` <args>` when
/// there are any.
pub(crate) fn command_line(command: &str, args: &str) -> String {
    if args.is_empty() {
        format!("/{command}")
    } else {
        format!("/{command} {args}")
    }
}

/// A command name kept on one line, at most [`COMMAND_NAME_CHARS`] long.
pub(super) fn clean_name(name: &str) -> Option<String> {
    let name = one_line(name, COMMAND_NAME_CHARS);
    (!name.is_empty()).then_some(name)
}

/// Arguments kept on one line.
pub(super) fn clean_args(args: &str) -> String {
    one_line(args, COMMAND_ARGS_CHARS)
}

fn tag_body<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)? + open.len();
    let end = text[start..].find(&close)? + start;
    Some(&text[start..end])
}

/// `s` cut to at most `max` bytes on a char boundary, and whether it was cut.
fn cap_bytes(s: &str, max: usize) -> (String, bool) {
    if s.len() <= max {
        return (s.to_owned(), false);
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    (s[..end].to_owned(), true)
}
