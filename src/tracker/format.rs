//! The board file format v1 (contract §2): parse bytes into a [`Board`] that
//! remembers every node's byte span, and splice a changed board back into the
//! original bytes so that only changed items' lines (and markers appended to
//! human lines) differ.

use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::OnceLock;

use chrono::DateTime;
use regex::Regex;
use thiserror::Error;

use super::model::{
    generate_id, is_valid_id, slug, Board, Env, Item, Kind, Link, LogLine, Section, Stamp, Status,
};

/// Why a file is not a readable board.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MalformedReason {
    InvalidUtf8,
    DuplicateId,
    GarbledMarker,
}

impl MalformedReason {
    pub fn code(self) -> &'static str {
        match self {
            MalformedReason::InvalidUtf8 => "invalid_utf8",
            MalformedReason::DuplicateId => "duplicate_id",
            MalformedReason::GarbledMarker => "garbled_marker",
        }
    }
}

/// The file can't be read as a board. `line` is 1-based.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("line {line}: {}", reason.code())]
pub struct Malformed {
    pub line: usize,
    pub reason: MalformedReason,
}

/// What a byte range of the file is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SegmentKind {
    /// The `# ` title line.
    Title,
    /// A `## ` heading; index into `Board::sections`.
    Section(usize),
    /// The `## Log` heading.
    LogHeading,
    /// A task line plus its indented block; index into `Board::items`.
    Item(usize),
    /// A Log line; index into `Board::log`.
    LogLine(usize),
    /// Free prose (starts and ends with a non-blank line); index into
    /// `Board::prose`.
    Prose(usize),
    /// A run of blank lines (belongs to the node before it).
    Blank,
}

/// A contiguous byte range of the file. Segments tile the file in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Segment {
    pub kind: SegmentKind,
    pub span: Range<usize>,
}

/// Per-item facts about its bytes (parallel to `Board::items`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemSpan {
    /// The task line plus its indented block.
    pub span: Range<usize>,
    /// The task line's content, without its line ending.
    pub task_line: Range<usize>,
    /// Whether the task line already carries a marker.
    pub has_marker: bool,
}

/// A parsed board and the bytes it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedBoard {
    pub board: Board,
    pub source: String,
    pub segments: Vec<Segment>,
    pub item_spans: Vec<ItemSpan>,
}

impl ParsedBoard {
    /// The exact source text of a segment.
    pub fn text(&self, span: &Range<usize>) -> &str {
        &self.source[span.clone()]
    }

    /// The byte span of an item (task line + indented block) by id.
    pub fn item_span(&self, id: &str) -> Option<Range<usize>> {
        let idx = self.board.items.iter().position(|i| i.id == id)?;
        Some(self.item_spans[idx].span.clone())
    }
}

/// Parses a board file.
pub fn parse(bytes: &[u8]) -> Result<ParsedBoard, Malformed> {
    let source = std::str::from_utf8(bytes).map_err(|e| Malformed {
        line: line_of(&bytes[..e.valid_up_to()]),
        reason: MalformedReason::InvalidUtf8,
    })?;
    Parser::new(source).run()
}

/// Writes `target` back over `parsed`'s bytes. Items equal to their parsed
/// version keep their bytes; changed, added and moved items are regenerated;
/// removed items' bytes are dropped; Log lines beyond the parsed log are
/// appended. With `assign_markers`, every human task line (no marker) gets
/// ` <!-- #<id> <secs> -->` appended and nothing else on it changes.
/// `target.sections` must be `parsed.board.sections`.
pub fn splice(parsed: &ParsedBoard, target: &Board, at: Stamp, assign_markers: bool) -> Vec<u8> {
    Splicer::new(parsed, target, at, assign_markers).run()
}

/// The lines a regenerated item is written as (task line, command fence,
/// note, `Links:`), joined with `eol`, ending with `eol`.
pub fn serialise_item(item: &Item, at: Stamp, eol: &str) -> String {
    let updated = item.updated_at.unwrap_or(at.now);
    let mut tail = vec![item.status.word().to_string()];
    tail.extend(item.owner.clone());
    tail.extend(item.env.map(|e| e.token().to_string()));
    tail.push(at.hhmm(updated));
    let check = if item.status == Status::Done { 'x' } else { ' ' };
    let mut out = format!(
        "- [{check}] {} — {} {}{eol}",
        item.text,
        tail.join(" · "),
        marker(item, updated.timestamp())
    );
    let mut push_indented = |line: &str| {
        if !line.is_empty() {
            out.push_str("  ");
            out.push_str(line);
        }
        out.push_str(eol);
    };
    if let Some(command) = &item.command {
        let fence = "`".repeat(longest_run(command, '`').max(2) + 1);
        push_indented(&format!("{fence}sh"));
        command.split('\n').for_each(&mut push_indented);
        push_indented(&fence);
    }
    if let Some(note) = &item.note {
        note.split('\n').for_each(&mut push_indented);
    }
    if !item.links.is_empty() {
        let tokens: Vec<String> = item.links.iter().map(Link::to_token).collect();
        push_indented(&format!("{LINKS_PREFIX}{}", tokens.join(" · ")));
    }
    out
}

/// The default sections of a new board.
pub const DEFAULT_SECTIONS: [&str; 7] = [
    "Now",
    "Next",
    "Waiting on you",
    "Done",
    "Findings",
    "Loose ends",
    "Log",
];

/// A new board's text. Empty `sections` means [`DEFAULT_SECTIONS`].
pub fn template(title: &str, sections: &[&str]) -> String {
    let sections = if sections.is_empty() { &DEFAULT_SECTIONS[..] } else { sections };
    let mut out = format!("# {}\n", title.trim());
    for section in sections {
        out.push_str(&format!("\n## {}\n", section.trim()));
    }
    out
}

/// Why a staged command's text is refused (`invalid_command_text`).
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CommandTextError {
    #[error("carriage return at byte {at}")]
    CarriageReturn { at: usize },
    #[error("escape sequence at byte {at}")]
    Escape { at: usize },
    #[error("control character U+{codepoint:04X} at byte {at}")]
    ControlChar { at: usize, codepoint: u32 },
    #[error("invisible or bidi character U+{codepoint:04X} at byte {at}")]
    InvisibleChar { at: usize, codepoint: u32 },
}

/// Accepts printable text with `\n` and `\t`; refuses `\r`, ESC sequences,
/// other C0/C1 controls (and DEL), zero-width and bidi-override characters
/// (contract §7 list).
pub fn validate_command_text(text: &str) -> Result<(), CommandTextError> {
    for (at, ch) in text.char_indices() {
        let codepoint = ch as u32;
        match ch {
            '\n' | '\t' => {}
            '\r' => return Err(CommandTextError::CarriageReturn { at }),
            '\u{1b}' | '\u{9b}' | '\u{9d}' => return Err(CommandTextError::Escape { at }),
            c if c.is_control() => return Err(CommandTextError::ControlChar { at, codepoint }),
            c if is_invisible(c) => return Err(CommandTextError::InvisibleChar { at, codepoint }),
            _ => {}
        }
    }
    Ok(())
}

/// Zero-width and bidi-control characters (contract §7): U+200B-U+200F,
/// U+202A-U+202E, U+2066-U+2069, U+FEFF.
pub fn is_invisible(ch: char) -> bool {
    matches!(ch, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
}

// ── Parsing ───────────────────────────────────────────────────────────────────

pub(crate) const LINKS_PREFIX: &str = "Links: ";
const TAIL_SEP: &str = " — ";
const TOKEN_SEP: &str = " · ";
const MARKER_START: &str = "<!-- #";
pub(crate) const MAX_OWNER_CHARS: usize = 32;

/// 1-based line number of the byte just past `prefix`.
fn line_of(prefix: &[u8]) -> usize {
    prefix.iter().filter(|b| **b == b'\n').count() + 1
}

/// One line of the source: `start..content_end` is its text, `content_end..end`
/// its line ending (`\n`, `\r\n`, or nothing on a last line without one).
#[derive(Debug, Clone, Copy)]
struct Line {
    start: usize,
    content_end: usize,
    end: usize,
}

fn split_lines(source: &str) -> Vec<Line> {
    let bytes = source.as_bytes();
    let mut lines = Vec::new();
    let mut start = 0;
    while start < bytes.len() {
        let (content_end, end) = match bytes[start..].iter().position(|b| *b == b'\n') {
            Some(nl) => {
                let nl = start + nl;
                let content_end = if nl > start && bytes[nl - 1] == b'\r' { nl - 1 } else { nl };
                (content_end, nl + 1)
            }
            None => (bytes.len(), bytes.len()),
        };
        lines.push(Line {
            start,
            content_end,
            end,
        });
        start = end;
    }
    lines
}

/// An open fenced code block: its fence character and length.
#[derive(Debug, Clone, Copy)]
struct Fence {
    ch: char,
    len: usize,
}

impl Fence {
    /// A fence opening line (up to 3 spaces of indentation).
    fn open(line: &str) -> Option<Fence> {
        let trimmed = line.trim_start_matches(' ');
        if line.len() - trimmed.len() > 3 {
            return None;
        }
        let ch = trimmed.chars().next().filter(|c| *c == '`' || *c == '~')?;
        let len = trimmed.chars().take_while(|c| *c == ch).count();
        (len >= 3).then_some(Fence { ch, len })
    }

    fn closes(&self, line: &str) -> bool {
        let trimmed = line.trim();
        trimmed.chars().take_while(|c| *c == self.ch).count() >= self.len
            && trimmed.chars().all(|c| c == self.ch)
    }
}

fn longest_run(text: &str, ch: char) -> usize {
    let mut best = 0;
    let mut run = 0;
    for c in text.chars() {
        run = if c == ch { run + 1 } else { 0 };
        best = best.max(run);
    }
    best
}

fn marker(item: &Item, secs: i64) -> String {
    let mut flags = String::new();
    if item.kind == Kind::Command {
        flags.push_str(" cmd");
    }
    if let Some(bind) = &item.bind {
        flags.push_str(&format!(" bind:{bind}"));
    }
    format!("<!-- #{} {secs}{flags} -->", item.id)
}

/// A parsed `<!-- #id secs flags -->`.
struct Marker {
    id: String,
    secs: i64,
    cmd: bool,
    bind: Option<String>,
}

fn parse_marker(text: &str) -> Option<Marker> {
    let inner = text.strip_prefix(MARKER_START)?.strip_suffix(" -->")?;
    let mut parts = inner.split(' ');
    let id = parts.next().filter(|id| is_valid_id(id))?;
    let secs_text = parts.next().filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))?;
    let secs: i64 = secs_text.parse().ok()?;
    DateTime::from_timestamp(secs, 0)?;
    let mut marker = Marker {
        id: id.to_string(),
        secs,
        cmd: false,
        bind: None,
    };
    for flag in parts {
        match flag {
            "cmd" if !marker.cmd => marker.cmd = true,
            _ => {
                let bind = flag.strip_prefix("bind:")?;
                let (source, key) = bind.split_once('/')?;
                if source.is_empty() || key.is_empty() || marker.bind.is_some() {
                    return None;
                }
                marker.bind = Some(bind.to_string());
            }
        }
    }
    Some(marker)
}

/// A column-0 line that starts like a marker (`<!-- #` then a non-space, so
/// a commented-out heading `<!-- # Old title -->` is just an HTML comment)
/// but doesn't parse as one: an editor split or mangled an item's marker.
fn is_garbled_marker_line(line: &str) -> bool {
    line.strip_prefix(MARKER_START)
        .is_some_and(|rest| rest.starts_with(|c: char| !c.is_whitespace()))
        && parse_marker(line.trim_end()).is_none()
}

fn is_time_token(token: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(?:[A-Z][a-z]{2} \d{1,2} )?\d{1,2}:\d{2}$").unwrap())
        .is_match(token)
}

/// What a recognised visible tail says.
#[derive(Default)]
struct Tail {
    status: Option<Status>,
    owner: Option<String>,
    env: Option<Env>,
}

/// Parses the segment after the last ` — `; `None` unless every token is
/// recognised (contract §2).
fn parse_tail(tail: &str) -> Option<Tail> {
    let mut out = Tail::default();
    let mut time_seen = false;
    for token in tail.split(TOKEN_SEP) {
        let token = token.trim();
        if token.is_empty() {
            return None;
        }
        if let Some(status) = Status::from_word(token) {
            if out.status.replace(status).is_some() {
                return None;
            }
        } else if let Some(env) = Env::from_token(token) {
            if out.env.replace(env).is_some() {
                return None;
            }
        } else if is_time_token(token) {
            if std::mem::replace(&mut time_seen, true) {
                return None;
            }
        } else if token.chars().count() <= MAX_OWNER_CHARS && out.owner.is_none() {
            out.owner = Some(token.to_string());
        } else {
            return None;
        }
    }
    Some(out)
}

/// `true` when `token` would read back as something other than an owner.
pub(crate) fn is_reserved_tail_token(token: &str) -> bool {
    Status::from_word(token).is_some() || Env::from_token(token).is_some() || is_time_token(token)
}

fn log_line_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^- (\d{1,2}:\d{2}) (.*\S.*)$").unwrap())
}

fn task_prefix(line: &str) -> Option<bool> {
    match line.get(..6)? {
        "- [ ] " => Some(false),
        "- [x] " | "- [X] " => Some(true),
        _ => None,
    }
}

/// Which section the parser is in.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Context {
    BeforeSections,
    Section(usize),
    Log,
}

struct Parser<'a> {
    source: &'a str,
    lines: Vec<Line>,
    board: Board,
    segments: Vec<Segment>,
    item_spans: Vec<ItemSpan>,
    /// Marker id of each item (`None` for a human line).
    marker_ids: Vec<Option<String>>,
    /// First line index of the current run of prose/blank lines.
    loose_from: Option<usize>,
}

impl<'a> Parser<'a> {
    fn new(source: &'a str) -> Parser<'a> {
        Parser {
            source,
            lines: split_lines(source),
            board: Board {
                byte_len: source.len(),
                ..Board::default()
            },
            segments: Vec::new(),
            item_spans: Vec::new(),
            marker_ids: Vec::new(),
            loose_from: None,
        }
    }

    fn content(&self, i: usize) -> &'a str {
        let line = self.lines[i];
        &self.source[line.start..line.content_end]
    }

    fn is_blank(&self, i: usize) -> bool {
        self.content(i).trim().is_empty()
    }

    fn run(mut self) -> Result<ParsedBoard, Malformed> {
        let mut context = Context::BeforeSections;
        let mut fence: Option<Fence> = None;
        let mut section_ids: HashSet<String> = HashSet::new();
        let mut i = 0;
        while i < self.lines.len() {
            let line = self.content(i);
            if let Some(open) = fence {
                if open.closes(line) {
                    fence = None;
                }
                self.loose(i);
                i += 1;
                continue;
            }
            if is_garbled_marker_line(line) {
                return Err(Malformed {
                    line: i + 1,
                    reason: MalformedReason::GarbledMarker,
                });
            }
            if let Some(open) = Fence::open(line) {
                fence = Some(open);
                self.loose(i);
            } else if let Some(title) = line.strip_prefix("# ").filter(|_| self.board.title.is_none()) {
                self.board.title = Some(title.trim().to_string());
                self.node(SegmentKind::Title, i, i);
            } else if let Some(heading) = line.strip_prefix("## ") {
                context = self.heading(i, heading.trim(), &mut section_ids);
            } else if let (Some(checked), Context::Section(section)) = (task_prefix(line), context) {
                let last = self.continuation_end(i);
                self.item(i, last, checked, section)?;
                i = last;
            } else if let Some(caps) = log_line_re().captures(line).filter(|_| context == Context::Log) {
                let index = self.board.log.len();
                self.board.log.push(LogLine {
                    time: caps[1].to_string(),
                    text: caps[2].trim_end().to_string(),
                });
                self.node(SegmentKind::LogLine(index), i, i);
            } else {
                self.loose(i);
            }
            i += 1;
        }
        self.flush_loose(self.lines.len());
        self.assign_ids()?;
        Ok(ParsedBoard {
            board: self.board,
            source: self.source.to_string(),
            segments: self.segments,
            item_spans: self.item_spans,
        })
    }

    /// Emits the `## ` heading on line `i` (the Log heading or a new
    /// section) and returns the context that follows it.
    fn heading(&mut self, i: usize, title: &str, section_ids: &mut HashSet<String>) -> Context {
        if title.eq_ignore_ascii_case("log") {
            self.node(SegmentKind::LogHeading, i, i);
            return Context::Log;
        }
        let index = self.board.sections.len();
        self.board.sections.push(Section {
            id: unique_section_id(title, section_ids),
            title: title.to_string(),
        });
        self.node(SegmentKind::Section(index), i, i);
        Context::Section(index)
    }

    /// The last line of the item starting at `first`: indented lines (and
    /// blank lines between them) up to the next column-0 line.
    fn continuation_end(&self, first: usize) -> usize {
        let mut last = first;
        for j in first + 1..self.lines.len() {
            if self.is_blank(j) {
                continue;
            }
            if !self.content(j).starts_with([' ', '\t']) {
                break;
            }
            last = j;
        }
        last
    }

    fn loose(&mut self, i: usize) {
        self.loose_from.get_or_insert(i);
    }

    /// Emits the pending prose/blank run ending before line `until`: leading
    /// blank lines, the prose (first to last non-blank line), trailing blanks.
    fn flush_loose(&mut self, until: usize) {
        let Some(from) = self.loose_from.take() else {
            return;
        };
        let first = (from..until).find(|&j| !self.is_blank(j));
        let Some(first) = first else {
            self.push_segment(SegmentKind::Blank, from, until - 1);
            return;
        };
        let last = (from..until).rev().find(|&j| !self.is_blank(j)).unwrap_or(first);
        if first > from {
            self.push_segment(SegmentKind::Blank, from, first - 1);
        }
        let index = self.board.prose.len();
        let span = self.lines[first].start..self.lines[last].end;
        self.board.prose.push(self.source[span].to_string());
        self.push_segment(SegmentKind::Prose(index), first, last);
        if last + 1 < until {
            self.push_segment(SegmentKind::Blank, last + 1, until - 1);
        }
    }

    /// Emits a node spanning lines `first..=last`.
    fn node(&mut self, kind: SegmentKind, first: usize, last: usize) {
        self.flush_loose(first);
        self.push_segment(kind, first, last);
    }

    fn push_segment(&mut self, kind: SegmentKind, first: usize, last: usize) {
        let span = self.lines[first].start..self.lines[last].end;
        self.segments.push(Segment { kind, span });
    }

    fn item(&mut self, first: usize, last: usize, checked: bool, section: usize) -> Result<(), Malformed> {
        let (text, tail, marker) = split_task_line(&self.content(first)[6..], first + 1)?;
        let status = match (checked, tail.status) {
            (true, _) => Status::Done,
            (false, Some(status)) if status != Status::Done => status,
            (false, _) => Status::Todo,
        };
        let mut item = Item::new("", &self.board.sections[section].id, text);
        item.status = status;
        item.owner = tail.owner;
        item.env = tail.env;
        let block: Vec<&str> = (first + 1..=last).map(|j| strip_indent(self.content(j))).collect();
        let is_cmd = marker.as_ref().is_some_and(|m| m.cmd);
        read_block(&mut item, &block, is_cmd);
        if let Some(m) = &marker {
            item.kind = if m.cmd { Kind::Command } else { Kind::Item };
            item.bind = m.bind.clone();
            item.updated_at = DateTime::from_timestamp(m.secs, 0);
        }
        self.node(SegmentKind::Item(self.board.items.len()), first, last);
        let line = self.lines[first];
        self.item_spans.push(ItemSpan {
            span: line.start..self.lines[last].end,
            task_line: line.start..line.content_end,
            has_marker: marker.is_some(),
        });
        self.marker_ids.push(marker.map(|m| m.id));
        self.board.items.push(item);
        Ok(())
    }

    /// Marker ids must be unique; human lines get generated ids.
    fn assign_ids(&mut self) -> Result<(), Malformed> {
        let mut taken = HashSet::new();
        for (index, id) in self.marker_ids.iter().enumerate() {
            if let Some(id) = id {
                if !taken.insert(id.clone()) {
                    return Err(Malformed {
                        line: line_of(&self.source.as_bytes()[..self.item_spans[index].span.start]),
                        reason: MalformedReason::DuplicateId,
                    });
                }
                self.board.items[index].id = id.clone();
            }
        }
        for (index, id) in self.marker_ids.iter().enumerate() {
            if id.is_none() {
                let generated = generate_id(&self.board.items[index].text, &taken);
                taken.insert(generated.clone());
                self.board.items[index].id = generated;
            }
        }
        Ok(())
    }
}

/// Splits a task line (after its checkbox) into text, recognised visible
/// tail and trailing marker. `line` is the 1-based line number for errors.
fn split_task_line(task: &str, line: usize) -> Result<(&str, Tail, Option<Marker>), Malformed> {
    let (body, marker) = match task.rfind(MARKER_START) {
        Some(pos) => {
            let marker = parse_marker(task[pos..].trim_end()).ok_or(Malformed {
                line,
                reason: MalformedReason::GarbledMarker,
            })?;
            (task[..pos].trim(), Some(marker))
        }
        None => (task.trim(), None),
    };
    let (text, tail) = match body.rfind(TAIL_SEP) {
        Some(pos) => match parse_tail(&body[pos + TAIL_SEP.len()..]) {
            Some(tail) => (body[..pos].trim_end(), tail),
            None => (body, Tail::default()),
        },
        None => (body, Tail::default()),
    };
    Ok((text, tail, marker))
}

fn unique_section_id(title: &str, taken: &mut HashSet<String>) -> String {
    let mut base = slug(title);
    if base.is_empty() {
        base = "section".to_string();
    }
    let mut id = base.clone();
    let mut n = 2;
    while !taken.insert(id.clone()) {
        id = format!("{base}-{n}");
        n += 1;
    }
    id
}

/// Removes an item block line's indentation (two spaces, or one tab/space).
fn strip_indent(line: &str) -> &str {
    if line.trim().is_empty() {
        return "";
    }
    line.strip_prefix("  ")
        .or_else(|| line.strip_prefix('\t'))
        .or_else(|| line.strip_prefix(' '))
        .unwrap_or(line)
}

/// Reads an item's indented block: a leading fence (command items), `Links:`
/// lines, and the rest as the note.
fn read_block(item: &mut Item, block: &[&str], is_cmd: bool) {
    let mut rest = block;
    if is_cmd {
        if let Some(fence) = block.first().and_then(|l| Fence::open(l)) {
            let close = block[1..].iter().position(|l| fence.closes(l)).map(|p| p + 1);
            let end = close.unwrap_or(block.len());
            item.command = Some(block[1..end].join("\n"));
            rest = &block[(end + 1).min(block.len())..];
        }
    }
    let mut note: Vec<&str> = Vec::new();
    let mut fence: Option<Fence> = None;
    for line in rest {
        if let Some(open) = fence {
            if open.closes(line) {
                fence = None;
            }
            note.push(line);
        } else if let Some(links) = line.strip_prefix(LINKS_PREFIX) {
            item.links.extend(
                links
                    .split(TOKEN_SEP)
                    .filter(|t| !t.trim().is_empty())
                    .map(Link::parse_token),
            );
        } else {
            fence = Fence::open(line);
            note.push(line);
        }
    }
    while note.last().is_some_and(|l| l.is_empty()) {
        note.pop();
    }
    let start = note.iter().position(|l| !l.is_empty()).unwrap_or(note.len());
    if start < note.len() {
        item.note = Some(note[start..].join("\n"));
    }
}

// ── Splicing ──────────────────────────────────────────────────────────────────

/// Output under construction. Keeps lines whole: anything pushed after a
/// line with no ending (the original's last line) starts on a new line.
struct Out<'a> {
    buf: String,
    eol: &'a str,
}

impl Out<'_> {
    fn push(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        if !self.buf.is_empty() && !self.buf.ends_with('\n') {
            self.buf.push_str(self.eol);
        }
        self.buf.push_str(text);
    }
}

struct Splicer<'a> {
    parsed: &'a ParsedBoard,
    target: &'a Board,
    at: Stamp,
    assign_markers: bool,
    /// The file's line ending (from its first line), for new lines.
    eol: &'static str,
    /// Original item index by id.
    original: HashMap<&'a str, usize>,
    /// Target items by id.
    targets: HashMap<&'a str, &'a Item>,
    /// Ids that keep their place (per-section LCS of original and target order).
    anchored: HashSet<&'a str>,
    /// Target items to write just before an anchored item.
    before: HashMap<&'a str, Vec<&'a Item>>,
    /// Target items to write after a section's last original item (or its
    /// last non-blank segment), keyed by the segment index to write after.
    after_segment: HashMap<usize, Vec<&'a Item>>,
}

impl<'a> Splicer<'a> {
    fn new(parsed: &'a ParsedBoard, target: &'a Board, at: Stamp, assign_markers: bool) -> Splicer<'a> {
        let source = &parsed.source;
        let eol = match source.find('\n') {
            Some(nl) if nl > 0 && source.as_bytes()[nl - 1] == b'\r' => "\r\n",
            _ => "\n",
        };
        let original: HashMap<&str, usize> = parsed
            .board
            .items
            .iter()
            .enumerate()
            .map(|(i, item)| (item.id.as_str(), i))
            .collect();
        let mut splicer = Splicer {
            parsed,
            target,
            at,
            assign_markers,
            eol,
            original,
            targets: target.items.iter().map(|i| (i.id.as_str(), i)).collect(),
            anchored: HashSet::new(),
            before: HashMap::new(),
            after_segment: HashMap::new(),
        };
        splicer.plan();
        splicer
    }

    /// Decides, per section, which items stay put and where the others go.
    fn plan(&mut self) {
        let tails = self.section_tail_segments();
        let sections = &self.parsed.board.sections;
        for (section_index, section) in sections.iter().enumerate() {
            let target_ids = ids_in_section(&self.target.items, &section.id);
            let original_ids = ids_in_section(&self.parsed.board.items, &section.id);
            let keep = lcs(&original_ids, &target_ids);
            let mut pending: Vec<&'a Item> = Vec::new();
            for id in target_ids {
                let item = self.targets[id];
                if keep.contains(id) {
                    self.anchored.insert(id);
                    self.before.insert(id, std::mem::take(&mut pending));
                } else {
                    pending.push(item);
                }
            }
            if !pending.is_empty() {
                self.after_segment
                    .entry(tails[section_index])
                    .or_default()
                    .extend(pending);
            }
        }
        // Items whose section is unknown (should not happen) go to the end
        // of the first section rather than vanish.
        let orphans: Vec<&'a Item> = self
            .target
            .items
            .iter()
            .filter(|i| self.parsed.board.section(&i.section).is_none())
            .collect();
        if let (false, Some(tail)) = (orphans.is_empty(), tails.first()) {
            self.after_segment.entry(*tail).or_default().extend(orphans);
        }
    }

    /// Per section: the segment new items are written after (its last item,
    /// else its last non-blank segment).
    fn section_tail_segments(&self) -> Vec<usize> {
        let mut tails = vec![0; self.parsed.board.sections.len()];
        let mut has_item = vec![false; tails.len()];
        let mut current: Option<usize> = None;
        for (index, segment) in self.parsed.segments.iter().enumerate() {
            match segment.kind {
                SegmentKind::Section(s) => {
                    current = Some(s);
                    tails[s] = index;
                }
                SegmentKind::LogHeading => current = None,
                SegmentKind::Item(_) => {
                    if let Some(s) = current {
                        tails[s] = index;
                        has_item[s] = true;
                    }
                }
                SegmentKind::Prose(_) | SegmentKind::Title | SegmentKind::LogLine(_) => {
                    if let Some(s) = current.filter(|s| !has_item[*s]) {
                        tails[s] = index;
                    }
                }
                SegmentKind::Blank => {}
            }
        }
        tails
    }

    /// Where new Log lines go: after the last Log line, else after the Log
    /// section's last non-blank segment; `None` when there is no Log section.
    fn log_tail_segment(&self) -> Option<usize> {
        let segments = &self.parsed.segments;
        if let Some(last) = segments.iter().rposition(|s| matches!(s.kind, SegmentKind::LogLine(_))) {
            return Some(last);
        }
        let heading = segments.iter().position(|s| s.kind == SegmentKind::LogHeading)?;
        let mut tail = heading;
        for (index, segment) in segments.iter().enumerate().skip(heading + 1) {
            match segment.kind {
                SegmentKind::Prose(_) => tail = index,
                SegmentKind::Blank => {}
                _ => break,
            }
        }
        Some(tail)
    }

    fn run(self) -> Vec<u8> {
        let source = &self.parsed.source;
        let mut out = Out {
            buf: String::with_capacity(source.len() + 256),
            eol: self.eol,
        };
        let new_log = self.new_log_lines();
        let log_tail = self.log_tail_segment();
        for (index, segment) in self.parsed.segments.iter().enumerate() {
            match segment.kind {
                SegmentKind::Item(i) => {
                    let id = self.parsed.board.items[i].id.as_str();
                    if self.anchored.contains(id) {
                        for item in self.before.get(id).into_iter().flatten() {
                            self.write_item(&mut out, item);
                        }
                        self.write_item(&mut out, self.targets[id]);
                    }
                }
                _ => out.push(self.parsed.text(&segment.span)),
            }
            for item in self.after_segment.get(&index).into_iter().flatten() {
                self.write_item(&mut out, item);
            }
            if log_tail == Some(index) {
                out.push(&new_log);
            }
        }
        if log_tail.is_none() && !new_log.is_empty() {
            if !out.buf.is_empty() && !out.buf.ends_with(&format!("{0}{0}", self.eol)) {
                out.push(self.eol);
            }
            out.push(&format!("## Log{}{new_log}", self.eol));
        }
        if !source.is_empty() && !source.ends_with('\n') {
            let trimmed = out.buf.strip_suffix(self.eol).map(str::len);
            if let Some(len) = trimmed {
                out.buf.truncate(len);
            }
        }
        out.buf.into_bytes()
    }

    fn new_log_lines(&self) -> String {
        let known = self.parsed.board.log.len().min(self.target.log.len());
        self.target.log[known..]
            .iter()
            .map(|l| format!("- {} {}{}", l.time, l.text, self.eol))
            .collect()
    }

    /// Writes one target item: its original bytes when unchanged (plus a
    /// marker on a human line), else a regenerated block.
    fn write_item(&self, out: &mut Out, item: &Item) {
        let source = &self.parsed.source;
        let Some(&index) = self.original.get(item.id.as_str()) else {
            out.push(&serialise_item(item, self.at, self.eol));
            return;
        };
        let spans = &self.parsed.item_spans[index];
        if self.parsed.board.items[index] != *item {
            let task_end = spans.task_line.end;
            let eol = if source[task_end..].starts_with("\r\n") { "\r\n" } else { self.eol };
            out.push(&serialise_item(item, self.at, eol));
            return;
        }
        if spans.has_marker || !self.assign_markers {
            out.push(&source[spans.span.clone()]);
            return;
        }
        let task_end = spans.task_line.end;
        out.push(&format!(
            "{} {}{}",
            &source[spans.span.start..task_end],
            marker(item, self.at.now.timestamp()),
            &source[task_end..spans.span.end]
        ));
    }
}

/// The ids of `items` in `section`, in order.
fn ids_in_section<'a>(items: &'a [Item], section: &str) -> Vec<&'a str> {
    items
        .iter()
        .filter(|i| i.section == section)
        .map(|i| i.id.as_str())
        .collect()
}

/// Members of a longest common subsequence of `a` and `b`, whose elements
/// are each unique (item ids). With unique elements the LCS is the longest
/// increasing run of `b`-positions taken in `a` order: O(n log n) time and
/// O(n) space, so a huge hand-made file can't blow up memory.
pub(crate) fn lcs<'a>(a: &[&'a str], b: &[&'a str]) -> HashSet<&'a str> {
    let pos_in_b: HashMap<&str, usize> = b.iter().enumerate().map(|(i, id)| (*id, i)).collect();
    let seq: Vec<(&'a str, usize)> = a
        .iter()
        .filter_map(|id| pos_in_b.get(id).map(|p| (*id, *p)))
        .collect();
    // tails[k]: index into `seq` of the smallest tail of an increasing run of
    // length k + 1; prev[i]: the element before seq[i] in its best run.
    let mut tails: Vec<usize> = Vec::new();
    let mut prev: Vec<Option<usize>> = vec![None; seq.len()];
    for (i, &(_, p)) in seq.iter().enumerate() {
        let k = tails.partition_point(|&t| seq[t].1 < p);
        prev[i] = k.checked_sub(1).map(|k| tails[k]);
        if k == tails.len() {
            tails.push(i);
        } else {
            tails[k] = i;
        }
    }
    let mut keep = HashSet::new();
    let mut cursor = tails.last().copied();
    while let Some(i) = cursor {
        keep.insert(seq[i].0);
        cursor = prev[i];
    }
    keep
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::model::Stamp;

    fn stamp() -> Stamp {
        Stamp::utc(DateTime::from_timestamp(1_760_550_000, 0).unwrap())
    }

    #[test]
    fn a_commented_out_heading_is_prose_but_a_mangled_marker_line_is_garbled() {
        let ok = "## Now\n<!-- # Old title -->\n- [ ] a <!-- #a 1 -->\n";
        assert!(parse(ok.as_bytes()).is_ok());
        let bad = "## Now\n- [ ] a\n<!-- #a nope -->\n";
        let err = parse(bad.as_bytes()).unwrap_err();
        assert_eq!((err.line, err.reason), (3, MalformedReason::GarbledMarker));
    }

    #[test]
    fn text_with_an_em_dash_and_a_command_with_backticks_round_trip() {
        let mut item = Item::new("x", "now", "Deploy — then verify");
        item.kind = Kind::Command;
        item.command = Some("echo ```\nls".to_string());
        item.updated_at = Some(stamp().now);
        let text = format!("## Now\n{}", serialise_item(&item, stamp(), "\n"));
        let parsed = parse(text.as_bytes()).unwrap();
        assert_eq!(parsed.board.items, vec![item]);
    }

    #[test]
    fn lcs_keeps_the_longest_common_order() {
        let keep = lcs(&["a", "b", "c", "d", "e"], &["b", "a", "c", "e", "x", "d"]);
        assert_eq!(keep.len(), 3);
        assert!(keep.contains("c"));
        assert!(lcs(&[], &["a"]).is_empty());
    }
}
