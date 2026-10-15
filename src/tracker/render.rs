//! What agents read: the compact full board, delta entries, and the
//! quoted-data sanitiser every untrusted field passes (contract §4, §7).

use serde_json::{json, Map, Value};

use super::format::is_invisible;
use super::model::{Board, Change, ChangeKind};

/// Log lines in the compact full render.
const LOG_LINES: usize = 10;

/// Per-field cap for quoted data, in characters.
pub const QUOTE_CAP_CHARS: usize = 500;
/// Appended to a capped field.
pub const TRUNCATED: &str = "…[truncated]";

/// `# Title`, then per section `## Name` and one line per item
/// `- <id> [<status>[ @owner][ ENV]] <text>` with notes indented, links on one
/// line and commands fenced; then the last 10 Log lines. No markers, times or
/// prose. Every untrusted field is quoted.
pub fn compact_full(board: &Board) -> String {
    let mut out = String::new();
    if let Some(title) = &board.title {
        out.push_str(&format!("# {}\n", quote_untrusted(title)));
    }
    for section in &board.sections {
        out.push_str(&format!("## {}\n", quote_untrusted(&section.title)));
        for item in board.items.iter().filter(|i| i.section == section.id) {
            let mut tag = item.status.wire().to_string();
            if let Some(owner) = &item.owner {
                tag.push_str(&format!(" @{}", quote_untrusted(owner)));
            }
            if let Some(env) = item.env {
                tag.push_str(&format!(" {}", env.token()));
            }
            out.push_str(&format!(
                "- {} [{tag}] {}\n",
                item.id,
                quote_untrusted(&item.text)
            ));
            if let Some(command) = &item.command {
                out.push_str("  ```\n");
                push_quoted_lines(&mut out, command);
                out.push_str("  ```\n");
            }
            if let Some(note) = &item.note {
                push_quoted_lines(&mut out, note);
            }
            if !item.links.is_empty() {
                let links: Vec<String> = item
                    .links
                    .iter()
                    .map(|l| quote_untrusted(&l.text))
                    .collect();
                out.push_str(&format!("  Links: {}\n", links.join(" · ")));
            }
        }
    }
    if !board.log.is_empty() {
        out.push_str("## Log\n");
        let skip = board.log.len().saturating_sub(LOG_LINES);
        for line in &board.log[skip..] {
            out.push_str(&format!(
                "- {} {}\n",
                line.time,
                quote_untrusted(&line.text)
            ));
        }
    }
    out
}

/// One JSON object per change (contract §4 shapes), untrusted text quoted:
/// `{"by","id","status":["todo","done"]}` (changed: each field `[old,new]`),
/// `{"by","id","added":{"section","text",…}}`, `{"by","id","removed":"<text>"}`,
/// `{"by","id","moved":["now","next"]}`, `{"by","log":"10:42 …"}`,
/// `{"by","section_added":"T"}`, `{"by","section_renamed":["A","B"]}`,
/// `{"by","section_removed":"T"}`.
pub fn delta_entries(changes: &[Change]) -> Vec<Value> {
    changes.iter().map(delta_entry).collect()
}

fn delta_entry(change: &Change) -> Value {
    let mut entry = Map::new();
    entry.insert("by".to_string(), json!(change.by.label()));
    if let Some(id) = &change.item_id {
        entry.insert("id".to_string(), json!(id));
    }
    let field = |name: &str| change.fields.get(name);
    match change.kind {
        ChangeKind::Changed => {
            for (name, (old, new)) in &change.fields {
                entry.insert(name.clone(), json!([quote_value(old), quote_value(new)]));
            }
        }
        ChangeKind::Added => {
            let added: Map<String, Value> = change
                .fields
                .iter()
                .map(|(name, (_, new))| (name.clone(), quote_value(new)))
                .collect();
            entry.insert("added".to_string(), Value::Object(added));
        }
        ChangeKind::Removed => {
            let text = field("text").map_or(Value::Null, |(old, _)| quote_value(old));
            entry.insert("removed".to_string(), text);
        }
        ChangeKind::Moved => {
            let (old, new) = field("section").cloned().unwrap_or_default();
            entry.insert("moved".to_string(), json!([old, new]));
        }
        ChangeKind::Log => {
            let text = field("text").map_or(Value::Null, |(_, new)| quote_value(new));
            entry.insert("log".to_string(), text);
        }
        ChangeKind::Section => {
            let (old, new) = field("title").cloned().unwrap_or_default();
            let (old, new) = (quote_value(&old), quote_value(&new));
            match (old.is_null(), new.is_null()) {
                (true, _) => entry.insert("section_added".to_string(), new),
                (_, true) => entry.insert("section_removed".to_string(), old),
                _ => entry.insert("section_renamed".to_string(), json!([old, new])),
            };
        }
    }
    Value::Object(entry)
}

/// Quotes every string inside a JSON value (links are shown by their text).
fn quote_value(value: &Value) -> Value {
    match value {
        Value::String(s) => json!(quote_untrusted(s)),
        Value::Array(items) => Value::Array(items.iter().map(quote_value).collect()),
        Value::Object(map) => match map.get("text") {
            Some(Value::String(text)) if map.contains_key("kind") => json!(quote_untrusted(text)),
            _ => Value::Object(
                map.iter()
                    .map(|(k, v)| (k.clone(), quote_value(v)))
                    .collect(),
            ),
        },
        other => other.clone(),
    }
}

/// Makes untrusted text safe to show an agent: ANSI/OSC escape sequences and
/// control characters removed (`\n`/`\t` become spaces), zero-width and bidi
/// characters shown as `⟨U+202E⟩`, `<nostromo-note` / `</nostromo-note` (any
/// case) neutralised to `‹nostromo-note` / `‹/nostromo-note`, capped at 500
/// characters with `…[truncated]`.
pub fn quote_untrusted(text: &str) -> String {
    let visible = make_visible(&strip_escapes(text));
    cap(&neutralise_note_tags(&visible))
}

/// A multi-line field, indented two spaces, each line quoted, the field as a
/// whole capped at [`QUOTE_CAP_CHARS`].
fn push_quoted_lines(out: &mut String, field: &str) {
    let capped = cap(field);
    for line in capped.split('\n') {
        out.push_str(&format!("  {}\n", quote_untrusted(line)));
    }
}

/// The first [`QUOTE_CAP_CHARS`] characters, plus [`TRUNCATED`] if cut.
fn cap(text: &str) -> String {
    match text.char_indices().nth(QUOTE_CAP_CHARS) {
        Some((cut, _)) => format!("{}{TRUNCATED}", &text[..cut]),
        None => text.to_string(),
    }
}

/// Removes ESC/CSI/OSC sequences and control characters; `\n` and `\t`
/// become spaces.
fn strip_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\u{1b}' => match chars.next() {
                Some('[') => skip_csi(&mut chars),
                Some(']' | 'P' | 'X' | '^' | '_') => skip_string(&mut chars),
                _ => {}
            },
            '\u{9b}' => skip_csi(&mut chars),
            '\u{9d}' | '\u{90}' | '\u{98}' | '\u{9e}' | '\u{9f}' => skip_string(&mut chars),
            '\n' | '\t' => out.push(' '),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// Skips a CSI sequence's parameters up to and including its final byte.
fn skip_csi(chars: &mut std::iter::Peekable<std::str::Chars>) {
    for c in chars.by_ref() {
        if ('\u{40}'..='\u{7e}').contains(&c) {
            break;
        }
    }
}

/// Skips an OSC/DCS-style string up to BEL, ST (`ESC \\`) or U+009C.
fn skip_string(chars: &mut std::iter::Peekable<std::str::Chars>) {
    while let Some(c) = chars.next() {
        match c {
            '\u{07}' | '\u{9c}' => break,
            '\u{1b}' => {
                if chars.peek() == Some(&'\\') {
                    chars.next();
                }
                break;
            }
            _ => {}
        }
    }
}

fn make_visible(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if is_invisible(ch) {
            out.push_str(&format!("⟨U+{:04X}⟩", ch as u32));
        } else {
            out.push(ch);
        }
    }
    out
}

/// `<nostromo-note` → `‹nostromo-note`, `</nostromo-note` → `‹/nostromo-note`,
/// any case.
fn neutralise_note_tags(text: &str) -> String {
    const TAG: &str = "nostromo-note";
    let lower = text.to_ascii_lowercase();
    let mut out = String::with_capacity(text.len());
    let mut last = 0;
    for (pos, _) in lower.match_indices('<') {
        let rest = &lower[pos + 1..];
        if rest.starts_with(TAG) || rest.strip_prefix('/').is_some_and(|r| r.starts_with(TAG)) {
            out.push_str(&text[last..pos]);
            out.push('‹');
            last = pos + 1;
        }
    }
    out.push_str(&text[last..]);
    out
}
