//! The exact-text display breakdown of a permission request (design contract
//! §4.3), used by the audit log now and by the approval card later.
//!
//! The rule that matters is the round-trip invariant (T-INV-2): the display
//! never elides, rewrites or reorders anything. Putting every `invisible`
//! segment back as its code point and joining the lines gives the original
//! text byte for byte ([`ApprovalDisplay::reassemble`]). The Mac re-checks
//! that and refuses to enable Allow when it fails.
//!
//! **Beyond the contract's field list:** a line has `cont`. A Bash command is
//! cut after every top-level separator so that each command starts its own
//! numbered line; those cuts are not newlines in the original, so the
//! continuation line says so and the join leaves the `\n` out.

use std::ops::Range;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::request::ToolKind;
use super::shell::{self, SepKind};
use crate::data::work::is_invisible;

/// Largest `old × new` line count the diff computes exactly; a bigger edit is
/// shown as "all old lines removed, all new lines added" (still lossless).
const MAX_DIFF_CELLS: usize = 4_000_000;

/// The largest Bash command that is broken down for display. A bigger one is not
/// shown at all: its display is the single line [`COMMAND_TOO_LARGE_LINE`]. (No
/// human reads a command this long, and the broker's one worker thread builds
/// the display of every request.) It is not the command: it does not reassemble
/// to it, so nothing can mistake it for the command that would run. (32 KiB: the
/// shell tokenizer also stops at a step budget; see [`super::shell::work_limit`].)
pub const MAX_DISPLAY_COMMAND_BYTES: usize = 32 * 1024;

/// What is shown instead of a Bash command over [`MAX_DISPLAY_COMMAND_BYTES`].
pub const COMMAND_TOO_LARGE_LINE: &str = "(command too large to display)";

/// What a request looks like on the card: numbered lines of typed segments.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalDisplay {
    pub lines: Vec<DisplayLine>,
    /// Bash only: simple commands, counting those inside `$( )`, backticks,
    /// subshells and `-c` payloads. Pipe parts count separately.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command_count: Option<u32>,
    pub invisible_count: u32,
    pub non_ascii_count: u32,
    /// Bash only: the tokenizer could not read the whole command.
    pub unparsed: bool,
}

/// One numbered line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplayLine {
    /// 1-based, in order.
    pub number: u32,
    pub kind: LineKind,
    /// This line continues the previous one after a separator cut: they were
    /// one line in the original, with no `\n` between them.
    #[serde(default, skip_serializing_if = "is_false")]
    pub cont: bool,
    pub segments: Vec<Segment>,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineKind {
    Command,
    HeredocBody,
    HeredocEnd,
    FileHeader,
    DiffAdd,
    DiffDel,
    DiffCtx,
    Json,
}

/// A run of text of one kind.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Segment {
    /// What to show. For `invisible` it is the token (`⟨U+202E RLO⟩`); for
    /// `non_ascii` it is the character itself.
    pub text: String,
    pub kind: SegmentKind,
    /// The code point of an `invisible` or `non_ascii` segment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cp: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SegmentKind {
    Plain,
    Separator,
    Invisible,
    NonAscii,
}

impl ApprovalDisplay {
    /// The display of `input` for a tool of `kind`.
    pub fn build(kind: ToolKind, input: &Value) -> Self {
        let mut b = Builder::default();
        match kind {
            ToolKind::Bash if has_strings(input, &["command"]) => b.bash(str_of(input, "command")),
            ToolKind::Edit if has_strings(input, &["file_path", "old_string", "new_string"]) => {
                b.header(&input["file_path"]);
                b.diff(str_of(input, "old_string"), str_of(input, "new_string"));
                b.extras(input, &["file_path", "old_string", "new_string"]);
            }
            ToolKind::Write if has_strings(input, &["file_path", "content"]) => {
                b.header(&input["file_path"]);
                b.all_added(str_of(input, "content"));
                b.extras(input, &["file_path", "content"]);
            }
            ToolKind::NotebookEdit if has_strings(input, &["notebook_path"]) => {
                b.header(&input["notebook_path"]);
                if let Some(src) = input.get("new_source").and_then(Value::as_str) {
                    b.all_added(src);
                }
                b.extras(input, &["notebook_path", "new_source"]);
            }
            _ => b.json(input),
        }
        b.finish()
    }

    /// The text this display stands for: its lines with every `invisible`
    /// segment put back as its code point and `\n` between lines (not at a
    /// `cont` cut). `file_header` and `diff_del` lines are left out, and so are
    /// the `json` lines that follow a file header (the tool's other fields), so
    /// a Bash command, a Write's content, an Edit's new text and a pretty-printed
    /// JSON input each come back exactly.
    pub fn reassemble(&self) -> String {
        let has_header = self.lines.iter().any(|l| l.kind == LineKind::FileHeader);
        self.join(|k| {
            !matches!(k, LineKind::FileHeader | LineKind::DiffDel)
                && !(has_header && k == LineKind::Json)
        })
    }

    /// An Edit's old text: the `diff_ctx` and `diff_del` lines, joined.
    pub fn reassemble_old(&self) -> String {
        self.join(|k| matches!(k, LineKind::DiffCtx | LineKind::DiffDel))
    }

    /// The path in the `file_header` line, as it was in the input.
    pub fn header_text(&self) -> Option<String> {
        let line = self.lines.iter().find(|l| l.kind == LineKind::FileHeader)?;
        Some(line.segments.iter().map(original_text).collect())
    }

    /// The readable text of the display: invisible characters as their tokens,
    /// lines joined as in [`Self::reassemble`] (all lines, headers included).
    pub fn shown_text(&self) -> String {
        let mut out = String::new();
        for (i, line) in self.lines.iter().enumerate() {
            if i > 0 && !line.cont {
                out.push('\n');
            }
            for s in &line.segments {
                out.push_str(&s.text);
            }
        }
        out
    }

    fn join(&self, keep: impl Fn(LineKind) -> bool) -> String {
        let mut out = String::new();
        let mut first = true;
        for line in self.lines.iter().filter(|l| keep(l.kind)) {
            if !first && !line.cont {
                out.push('\n');
            }
            first = false;
            for s in &line.segments {
                out.push_str(&original_text(s));
            }
        }
        out
    }
}

/// One segment as it was in the original text.
fn original_text(s: &Segment) -> String {
    match (s.kind, s.cp.and_then(char::from_u32)) {
        (SegmentKind::Invisible, Some(c)) => c.to_string(),
        _ => s.text.clone(),
    }
}

fn str_of<'a>(input: &'a Value, key: &str) -> &'a str {
    input.get(key).and_then(Value::as_str).unwrap_or_default()
}

fn has_strings(input: &Value, keys: &[&str]) -> bool {
    keys.iter()
        .all(|k| input.get(*k).is_some_and(Value::is_string))
}

// ── building ──────────────────────────────────────────────────────────────────

#[derive(Default)]
struct Builder {
    lines: Vec<DisplayLine>,
    command_count: Option<u32>,
    invisible: u32,
    non_ascii: u32,
    unparsed: bool,
}

impl Builder {
    fn finish(self) -> ApprovalDisplay {
        ApprovalDisplay {
            lines: self.lines,
            command_count: self.command_count,
            invisible_count: self.invisible,
            non_ascii_count: self.non_ascii,
            unparsed: self.unparsed,
        }
    }

    fn push_line(&mut self, kind: LineKind, cont: bool, segments: Vec<Segment>) {
        let number = self.lines.len() as u32 + 1;
        self.lines.push(DisplayLine {
            number,
            kind,
            cont,
            segments,
        });
    }

    /// `text` as segments: plain runs, invisible characters, non-ASCII characters.
    fn segments(&mut self, text: &str, out: &mut Vec<Segment>) {
        let mut plain = String::new();
        let flush = |plain: &mut String, out: &mut Vec<Segment>| {
            if !plain.is_empty() {
                out.push(Segment {
                    text: std::mem::take(plain),
                    kind: SegmentKind::Plain,
                    cp: None,
                });
            }
        };
        for c in text.chars() {
            if is_invisible(c) {
                flush(&mut plain, out);
                self.invisible += 1;
                out.push(Segment {
                    text: invisible_token(c),
                    kind: SegmentKind::Invisible,
                    cp: Some(c as u32),
                });
            } else if !c.is_ascii() {
                flush(&mut plain, out);
                self.non_ascii += 1;
                out.push(Segment {
                    text: c.to_string(),
                    kind: SegmentKind::NonAscii,
                    cp: Some(c as u32),
                });
            } else {
                plain.push(c);
            }
        }
        flush(&mut plain, out);
    }

    fn text_line(&mut self, kind: LineKind, text: &str) {
        let mut segs = Vec::new();
        self.segments(text, &mut segs);
        self.push_line(kind, false, segs);
    }

    fn header(&mut self, path: &Value) {
        self.text_line(LineKind::FileHeader, path.as_str().unwrap_or_default());
    }

    fn json(&mut self, value: &Value) {
        let pretty = serde_json::to_string_pretty(value).unwrap_or_default();
        for line in pretty.split('\n') {
            self.text_line(LineKind::Json, line);
        }
    }

    /// The tool's fields other than `known`, as `json` lines, so none is hidden.
    fn extras(&mut self, input: &Value, known: &[&str]) {
        let Some(map) = input.as_object() else { return };
        let rest: serde_json::Map<String, Value> = map
            .iter()
            .filter(|(k, _)| !known.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        if !rest.is_empty() {
            self.json(&Value::Object(rest));
        }
    }

    fn all_added(&mut self, text: &str) {
        for line in text.split('\n') {
            self.text_line(LineKind::DiffAdd, line);
        }
    }

    fn diff(&mut self, old: &str, new: &str) {
        let old: Vec<&str> = old.split('\n').collect();
        let new: Vec<&str> = new.split('\n').collect();
        for (kind, text) in line_diff(&old, &new) {
            self.text_line(kind, text);
        }
    }

    fn bash(&mut self, cmd: &str) {
        if cmd.len() > MAX_DISPLAY_COMMAND_BYTES {
            self.unparsed = true;
            self.push_line(
                LineKind::Command,
                false,
                vec![Segment {
                    text: COMMAND_TOO_LARGE_LINE.to_owned(),
                    kind: SegmentKind::Plain,
                    cp: None,
                }],
            );
            return;
        }
        let parsed = shell::parse(cmd);
        self.command_count = Some(parsed.commands.len() as u32);
        self.unparsed = parsed.unparsed;
        // In order of position, so each line's separators and here-document are
        // found by moving forward, not by looking through all of them per line.
        let mut seps: Vec<Range<usize>> = parsed
            .separators
            .iter()
            .filter(|s| s.kind != SepKind::Newline)
            .map(|s| s.span.clone())
            .collect();
        seps.sort_by_key(|s| s.start);
        let mut heredocs: Vec<&Range<usize>> =
            parsed.heredocs.iter().map(|hd| &hd.body_span).collect();
        heredocs.sort_by_key(|span| span.start);
        let (mut next_sep, mut first_open_heredoc) = (0, 0);
        let mut ls = 0;
        loop {
            let le = cmd[ls..].find('\n').map_or(cmd.len(), |n| ls + n);
            // Here-documents wholly before this line stay behind.
            while heredocs
                .get(first_open_heredoc)
                .is_some_and(|span| span.end < ls)
            {
                first_open_heredoc += 1;
            }
            let kind = heredocs[first_open_heredoc..]
                .iter()
                .take_while(|span| span.start <= ls)
                .find_map(|span| {
                    if ls < span.end {
                        Some(LineKind::HeredocBody)
                    } else if ls == span.end {
                        Some(LineKind::HeredocEnd)
                    } else {
                        None
                    }
                })
                .unwrap_or(LineKind::Command);
            if kind == LineKind::Command {
                // Separators that start before this line are of an earlier one (or span a newline).
                while seps.get(next_sep).is_some_and(|s| s.start < ls) {
                    next_sep += 1;
                }
                let end = next_sep + seps[next_sep..].iter().take_while(|s| s.start < le).count();
                self.command_line(cmd, ls..le, &seps[next_sep..end]);
                next_sep = end;
            } else {
                self.text_line(kind, &cmd[ls..le]);
            }
            if le >= cmd.len() {
                break;
            }
            ls = le + 1;
        }
    }

    /// One original line, cut after each separator that has more text after it.
    /// `seps` are the separators that start on the line, in order.
    fn command_line(&mut self, cmd: &str, line: Range<usize>, seps: &[Range<usize>]) {
        let mut segs = Vec::new();
        let mut cont = false;
        let mut at = line.start;
        for sep in seps.iter().filter(|s| s.end <= line.end) {
            if sep.start < at {
                continue;
            }
            self.segments(&cmd[at..sep.start], &mut segs);
            segs.push(Segment {
                text: cmd[sep.clone()].to_owned(),
                kind: SegmentKind::Separator,
                cp: None,
            });
            at = sep.end;
            if at < line.end {
                self.push_line(LineKind::Command, cont, std::mem::take(&mut segs));
                cont = true;
            }
        }
        self.segments(&cmd[at..line.end], &mut segs);
        self.push_line(LineKind::Command, cont, segs);
    }
}

/// The token an invisible character is shown as: `⟨tab⟩`, `⟨CR⟩`, `⟨U+202E RLO⟩`.
pub fn invisible_token(c: char) -> String {
    match c {
        '\t' => "\u{27E8}tab\u{27E9}".to_owned(),
        '\r' => "\u{27E8}CR\u{27E9}".to_owned(),
        _ => match invisible_name(c) {
            Some(name) => format!("\u{27E8}U+{:04X} {name}\u{27E9}", c as u32),
            None => format!("\u{27E8}U+{:04X}\u{27E9}", c as u32),
        },
    }
}

fn invisible_name(c: char) -> Option<&'static str> {
    Some(match c {
        '\u{202A}' => "LRE",
        '\u{202B}' => "RLE",
        '\u{202C}' => "PDF",
        '\u{202D}' => "LRO",
        '\u{202E}' => "RLO",
        '\u{2066}' => "LRI",
        '\u{2067}' => "RLI",
        '\u{2068}' => "FSI",
        '\u{2069}' => "PDI",
        '\u{200B}' => "ZWSP",
        '\u{200C}' => "ZWNJ",
        '\u{200D}' => "ZWJ",
        '\u{2060}' => "WJ",
        '\u{FEFF}' => "BOM",
        '\u{00AD}' => "SHY",
        '\u{061C}' => "ALM",
        '\u{200E}' => "LRM",
        '\u{200F}' => "RLM",
        _ => return None,
    })
}

/// A line diff by longest common subsequence: `(kind, line)` in display order,
/// deletions before additions inside a changed stretch.
fn line_diff<'a>(old: &[&'a str], new: &[&'a str]) -> Vec<(LineKind, &'a str)> {
    let (n, m) = (old.len(), new.len());
    if n.saturating_mul(m) > MAX_DIFF_CELLS {
        return old
            .iter()
            .map(|l| (LineKind::DiffDel, *l))
            .chain(new.iter().map(|l| (LineKind::DiffAdd, *l)))
            .collect();
    }
    // lcs[i][j]: length of the LCS of old[i..] and new[j..].
    let mut lcs = vec![0u32; (n + 1) * (m + 1)];
    let at = |i: usize, j: usize| i * (m + 1) + j;
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[at(i, j)] = if old[i] == new[j] {
                lcs[at(i + 1, j + 1)] + 1
            } else {
                lcs[at(i + 1, j)].max(lcs[at(i, j + 1)])
            };
        }
    }
    let mut out = Vec::with_capacity(n + m);
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if old[i] == new[j] {
            out.push((LineKind::DiffCtx, old[i]));
            i += 1;
            j += 1;
        } else if lcs[at(i + 1, j)] >= lcs[at(i, j + 1)] {
            out.push((LineKind::DiffDel, old[i]));
            i += 1;
        } else {
            out.push((LineKind::DiffAdd, new[j]));
            j += 1;
        }
    }
    out.extend(old[i..].iter().map(|l| (LineKind::DiffDel, *l)));
    out.extend(new[j..].iter().map(|l| (LineKind::DiffAdd, *l)));
    out
}
