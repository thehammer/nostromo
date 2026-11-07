//! Origins of user-role messages the CLI wrote itself: a message from another
//! Claude session, a loaded skill, a conversation summary. None of them is
//! something the user typed, so none is drawn as the user's bubble.
//!
//! These parsers read SHAPE only. Shape is never enough to trust a text (a user
//! can type or paste any of them): the transcript applies them only to a
//! prompt the host did not send (`host_sent`), and the session manager takes
//! the origin back from a turn the daemon wrote (`disown_injected_origin`).
//!
//! Capture (Claude Code session JSONL, 2026-11): a peer message is a user
//! entry with `isMeta: true`, `origin: {kind: "peer", …}`, `promptSource:
//! "system"` whose text is `Another Claude session sent a message:\n
//! <cross-session-message from=".." from-name=".." from-mode="..">\nBODY\n
//! </cross-session-message>\n\n<advisory>`. The body is verbatim (not
//! escaped). Host-written prompts carry `promptSource: "sdk"`.

use super::{PeerMessageItem, TurnOrigin};
use crate::data::work::untrusted::{one_line, sanitize_block};

pub const PEER_OPEN: &str = "<cross-session-message ";
const PEER_CLOSE: &str = "</cross-session-message>";
const PEER_PREAMBLE: &str = "Another Claude session sent a message:";
/// Peer messages one turn's origin keeps; the rest are counted in `omitted`.
pub const MAX_PEER_ITEMS: usize = 8;
/// Bytes of a peer body or an injected text the origin keeps.
pub const INJECTED_BODY_BYTES: usize = 8 * 1024;
const PEER_NAME_CHARS: usize = 64;
const PEER_MODE_CHARS: usize = 16;
const PEER_SOCKET_CHARS: usize = 256;
const SKILL_NAME_CHARS: usize = 64;
const SKILL_PREFIX: &str = "Base directory for this skill:";
const SUMMARY_PREFIX: &str = "This session is being continued from a previous conversation";

/// A peer-message origin of exactly one item, or `None` when `text` is not a
/// well-formed message: the preamble (optional), then `<cross-session-message
/// …>`, a body, and a closing tag. The body ends at the FIRST closing tag;
/// whatever follows it (a body that quotes the tag, the CLI's advisory) is
/// dropped, never read as another message.
pub fn parse_peer_origin(text: &str) -> Option<TurnOrigin> {
    let mut rest = text.trim_start();
    if let Some(after) = rest.strip_prefix(PEER_PREAMBLE) {
        rest = after.trim_start();
    }
    let rest = rest.strip_prefix(PEER_OPEN)?;
    let head_end = element_head_end(rest)?;
    let attrs = parse_attributes(&rest[..head_end])?;
    let attr = |key: &str, max: usize| {
        attrs
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| one_line(v, max))
            .filter(|v| !v.is_empty())
    };
    let from_socket = attr("from", PEER_SOCKET_CHARS);
    let from_name = attr("from-name", PEER_NAME_CHARS);
    if from_socket.is_none() && from_name.is_none() {
        return None;
    }
    let after = &rest[head_end + 1..];
    let body = &after[..after.find(PEER_CLOSE)?];
    let body = body.strip_prefix('\n').unwrap_or(body);
    let body = body.strip_suffix('\n').unwrap_or(body);
    let (body, truncated) = cap_bytes(&sanitize_block(body), INJECTED_BODY_BYTES);
    Some(TurnOrigin::PeerMessage {
        items: vec![PeerMessageItem {
            from_name,
            from_mode: attr("from-mode", PEER_MODE_CHARS),
            from_socket,
            body,
            truncated,
        }],
        omitted: 0,
    })
}

/// The origin of a user-role text the CLI injected, by shape: a peer message,
/// a loaded skill or a conversation summary (`compact_summary`: the line said
/// so itself). Text of any other shape is not read here; the daemon marks it
/// `other` only when it knows the daemon did not write it.
pub fn parse_injected_origin(text: &str, compact_summary: bool) -> Option<TurnOrigin> {
    if let Some(origin) = parse_peer_origin(text) {
        return Some(origin);
    }
    let trimmed = text.trim_start();
    if let Some(rest) = trimmed.strip_prefix(SKILL_PREFIX) {
        let (first, body) = rest.split_once('\n').unwrap_or((rest, ""));
        let name = first
            .trim()
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .map(|n| one_line(n, SKILL_NAME_CHARS))
            .filter(|n| !n.is_empty())?;
        return Some(injected("skill", name, body));
    }
    if compact_summary || trimmed.starts_with(SUMMARY_PREFIX) {
        return Some(injected(
            "summary",
            "Conversation summary".to_owned(),
            trimmed,
        ));
    }
    None
}

/// The generic origin for injected text of no known shape.
pub fn other_injected_origin(text: &str) -> TurnOrigin {
    injected("other", "Injected context".to_owned(), text)
}

fn injected(kind: &str, title: String, body: &str) -> TurnOrigin {
    let (text, truncated) = cap_bytes(
        &sanitize_block(body.trim_matches('\n')),
        INJECTED_BODY_BYTES,
    );
    TurnOrigin::InjectedContext {
        kind: kind.to_owned(),
        title,
        text,
        truncated,
    }
}

/// The one-line stand-in for an injected turn's `user_input` (never the raw
/// text: the origin carries the capped, sanitised body).
pub fn injected_line(origin: &TurnOrigin) -> String {
    match origin {
        TurnOrigin::PeerMessage { items, omitted } => {
            let total = items.len() + *omitted as usize;
            let name = items
                .first()
                .and_then(|i| i.from_name.as_deref())
                .unwrap_or("another session");
            if total == 1 {
                format!("Message from {name}")
            } else {
                format!("{total} messages from {name}")
            }
        }
        TurnOrigin::InjectedContext { kind, title, .. } if kind == "skill" => {
            format!("Skill loaded: {title}")
        }
        TurnOrigin::InjectedContext { title, .. } => title.clone(),
        _ => String::new(),
    }
}

/// Index of the `>` that ends an element head, ignoring any inside a quoted
/// value.
fn element_head_end(s: &str) -> Option<usize> {
    let mut quoted = false;
    for (i, c) in s.char_indices() {
        match c {
            '"' => quoted = !quoted,
            '>' if !quoted => return Some(i),
            _ => {}
        }
    }
    None
}

/// `name="value"` pairs of an element head, values unescaped; `None` when
/// anything in it is not one.
fn parse_attributes(mut s: &str) -> Option<Vec<(String, String)>> {
    let mut out = Vec::new();
    loop {
        s = s.trim_start();
        if s.is_empty() {
            return Some(out);
        }
        let eq = s.find('=')?;
        let name = &s[..eq];
        if name.is_empty()
            || !name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return None;
        }
        let value = s[eq + 1..].strip_prefix('"')?;
        let end = value.find('"')?;
        out.push((name.to_owned(), unescape(&value[..end])));
        s = &value[end + 1..];
    }
}

fn unescape(v: &str) -> String {
    v.replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
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
