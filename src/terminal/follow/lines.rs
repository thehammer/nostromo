//! [`LineAssembler`]: a streaming byte-to-lines state machine.
//!
//! The assembler turns raw terminal output into the lines a human would have
//! read: escape sequences are removed, `\r` redraws collapse to their final
//! state and a handful of cursor movements are honoured inside a line. It
//! never looks at the whole stream at once, so a sequence (or a UTF-8
//! character) split across two [`LineAssembler::feed`] calls is handled the
//! same as one that arrives whole.
//!
//! ## Model
//!
//! Rows that have not yet been handed out by [`LineAssembler::take_committed`]
//! are kept in a small buffer; the last row is the live line. A cursor sits on
//! one of those rows. `\n` moves the cursor down a row (appending a new live
//! row when it is on the last one) and resets the column to 0, as if every
//! `\n` were `\r\n`.
//!
//! ## Limits (a deliberate approximation)
//!
//! * `CSI n A` / `CSI n B` move between rows that are still buffered, which is
//!   enough for `docker pull` / `npm` style multi-line progress. Rows already
//!   handed out by `take_committed` cannot be rewritten: cursor-up clamps to
//!   the oldest buffered row. Callers should therefore take lines when output
//!   settles, not after every chunk.
//! * Rows at or below the cursor row are held back by `take_committed`, since
//!   a program that moved the cursor up may still rewrite them.
//! * Columns are `char`s. Double-width (CJK, emoji) and combining characters
//!   are counted as one column although a terminal shows two (or zero), so
//!   cursor movement and `\r` redraws over them land a column off. The gap is
//!   bounded: it only misplaces overwrites inside one line (never across
//!   lines), a line never exceeds [`MAX_LINE_COLUMNS`] chars, and redaction
//!   runs on the text this engine produces, so a misplaced column can change
//!   what a line shows but never lets a secret past the redactor.
//! * Memory is bounded: a row stores only its non-blank cells (padding from
//!   cursor movement stays implicit), at most [`MAX_BUFFERED_ROWS`] rows and
//!   [`MAX_BUFFERED_CELLS`] columns are buffered between
//!   [`LineAssembler::take_committed`] calls, and beyond that the oldest rows
//!   are dropped and reported as one `[… N lines dropped …]` line.
//! * Characters that render as nothing (zero-width space, joiners, word
//!   joiner, soft hyphen, BOM) and bidi / tag controls are dropped, so a
//!   secret cannot be split by them past the redactor.
//! * Only `A B C D G K P` (CSI) are interpreted. Every other sequence
//!   (`H`, `J`, `L`, scroll regions, mode switches, …) is stripped and has no
//!   effect.

use std::collections::VecDeque;
use std::sync::OnceLock;

use crate::terminal::redact::private_key_open_after;

/// Longest line, in columns (chars), that [`LineAssembler`] keeps. A longer
/// line is cut and its last column is replaced by `…`.
pub const MAX_LINE_COLUMNS: usize = 4096;

/// Most rows buffered between [`LineAssembler::take_committed`] calls. Past it
/// (or past [`MAX_BUFFERED_CELLS`]) the oldest rows are dropped.
pub const MAX_BUFFERED_ROWS: usize = 8192;

/// Most columns, summed over every buffered row (blank padding counts), kept
/// between [`LineAssembler::take_committed`] calls.
pub const MAX_BUFFERED_CELLS: usize = 512 * 1024;

/// Synthetic line returned after the dropped-lines marker when the dropped rows
/// ended inside a private-key block, so a redactor treats what follows as key
/// material until the block's `END` line.
pub const DROPPED_KEY_HEADER: &str = "-----BEGIN PRIVATE KEY-----";

/// Cap on remembered CSI parameter bytes; anything longer is not a cursor
/// movement we understand and the sequence is just skipped.
const MAX_CSI_PARAM_LEN: usize = 32;

/// Streaming escape-stripping line assembler. See the [module docs](self).
#[derive(Debug)]
pub struct LineAssembler {
    /// Buffered rows; never empty. The last row is the live line.
    rows: VecDeque<Row>,
    /// Cursor row index into `rows`.
    cursor_row: usize,
    /// Cursor column on the cursor row.
    col: usize,
    parser: Parser,
    utf8: Utf8Decoder,
    suspended: bool,
    /// Text of the cursor row with trailing spaces trimmed, rendered on the
    /// first [`current_partial`](Self::current_partial) after the row last
    /// changed (so feeding never pays for it); `None` inside when empty.
    partial: OnceLock<Option<String>>,
    /// Sum of the widths of `rows`.
    cells_total: usize,
    /// Rows dropped by the caps since the last `take_committed`.
    dropped_rows: usize,
    /// The dropped rows ended inside a private-key block (its `BEGIN` was
    /// dropped, its body may still be buffered).
    dropped_in_key: bool,
    #[cfg(test)]
    renders: std::sync::atomic::AtomicUsize,
}

/// One buffered row. Only non-blank cells are stored (sorted by column);
/// every other column up to the last one is an implicit space, so cursor
/// movement can never allocate.
#[derive(Debug, Default, Clone)]
struct Row {
    cells: Vec<(u16, char)>,
    /// Characters were dropped because the row hit [`MAX_LINE_COLUMNS`].
    clipped: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum State {
    Ground,
    /// After `ESC`.
    Escape,
    /// After `ESC` plus intermediate bytes (`ESC ( B` and friends).
    EscapeIntermediate,
    Csi,
    /// OSC / DCS / APC / PM / SOS body, up to BEL or ST.
    Str {
        saw_escape: bool,
    },
}

#[derive(Debug)]
struct Parser {
    state: State,
    params: String,
    /// The CSI had an intermediate byte or a private-use marker, so it is
    /// never one of the cursor movements we handle.
    csi_ignored: bool,
}

impl Parser {
    fn new() -> Self {
        Self {
            state: State::Ground,
            params: String::new(),
            csi_ignored: false,
        }
    }
}

impl Default for LineAssembler {
    fn default() -> Self {
        Self::new()
    }
}

impl LineAssembler {
    /// An empty, running assembler.
    pub fn new() -> Self {
        let mut rows = VecDeque::new();
        rows.push_back(Row::default());
        Self {
            rows,
            cursor_row: 0,
            col: 0,
            parser: Parser::new(),
            utf8: Utf8Decoder::default(),
            suspended: false,
            partial: OnceLock::new(),
            cells_total: 0,
            dropped_rows: 0,
            dropped_in_key: false,
            #[cfg(test)]
            renders: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// Consume the next chunk of terminal output. Chunk boundaries may fall
    /// anywhere. Bytes are discarded while [suspended](Self::suspend).
    pub fn feed(&mut self, bytes: &[u8]) {
        if self.suspended {
            return;
        }
        if bytes.is_empty() {
            return;
        }
        self.partial = OnceLock::new();
        for &b in bytes {
            let mut decoded = [None, None];
            self.utf8.push(b, &mut decoded);
            for c in decoded.into_iter().flatten() {
                self.handle_char(c);
            }
        }
    }

    /// Remove and return the finished lines, oldest first, with trailing
    /// spaces trimmed. Rows at or below the cursor row stay buffered (see the
    /// [module docs](self)); the live line is never returned.
    ///
    /// **These lines are raw: not redacted, not capped. Never send them to an
    /// agent.** They are the input of [`deliver`](super::deliver), which takes
    /// them itself and is the only path to agent text.
    ///
    /// If the buffer caps dropped rows since the last call, the first line is
    /// `[… N lines dropped …]`, followed by [`DROPPED_KEY_HEADER`] when the
    /// dropped rows opened a private-key block that is still open.
    pub fn take_committed(&mut self) -> Vec<String> {
        let take = self.cursor_row.min(self.rows.len() - 1);
        let mut lines = Vec::with_capacity(take + 1);
        if self.dropped_rows > 0 {
            lines.push(format!("[… {} lines dropped …]", self.dropped_rows));
            self.dropped_rows = 0;
            if self.dropped_in_key {
                // The `BEGIN` line went with the dropped rows but its body is
                // still here: put a header back so the redactor swallows it.
                lines.push(DROPPED_KEY_HEADER.to_owned());
                self.dropped_in_key = false;
            }
        }
        for row in self.rows.drain(..take) {
            self.cells_total = self.cells_total.saturating_sub(row.width());
            lines.push(row.text());
        }
        self.cursor_row -= take;
        lines
    }

    /// The text on the cursor's row, trailing spaces trimmed; `None` when
    /// the row is empty. This is the "prompt line" while a shell waits.
    /// Rendered on demand, not on every `feed`.
    ///
    /// **Raw, like [`take_committed`](Self::take_committed): not redacted, and
    /// the live row may hold a half-typed secret. Never send it to an agent.**
    pub fn current_partial(&self) -> Option<&str> {
        self.partial
            .get_or_init(|| {
                #[cfg(test)]
                self.renders
                    .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                let text = self.rows[self.cursor_row].text();
                (!text.is_empty()).then_some(text)
            })
            .as_deref()
    }

    /// Rows currently buffered (committed-but-untaken, plus the live row).
    pub fn buffered_rows(&self) -> usize {
        self.rows.len()
    }

    /// Columns currently buffered, summed over [`buffered_rows`](Self::buffered_rows).
    pub fn buffered_cells(&self) -> usize {
        self.cells_total
    }

    /// Stop interpreting input (an alternate-screen program is running).
    /// Rows already assembled are kept; the escape and UTF-8 parsers reset.
    pub fn suspend(&mut self) {
        self.suspended = true;
        self.reset_parsers();
    }

    /// Start interpreting input again. The cursor returns to the live line.
    pub fn resume(&mut self) {
        self.suspended = false;
        self.reset_parsers();
        self.cursor_row = self.rows.len() - 1;
        self.partial = OnceLock::new();
    }

    /// Whether input is currently being discarded.
    pub fn is_suspended(&self) -> bool {
        self.suspended
    }

    fn reset_parsers(&mut self) {
        self.parser = Parser::new();
        self.utf8 = Utf8Decoder::default();
    }

    fn handle_char(&mut self, c: char) {
        match self.parser.state {
            State::Ground => self.ground(c),
            State::Escape => self.escape(c),
            State::EscapeIntermediate => match c {
                '\u{20}'..='\u{2f}' => {}
                '\u{30}'..='\u{7e}' => self.parser.state = State::Ground,
                _ => self.reground(c),
            },
            State::Csi => self.csi(c),
            State::Str { saw_escape } => self.string_body(c, saw_escape),
        }
    }

    fn ground(&mut self, c: char) {
        match c {
            '\u{1b}' => self.parser.state = State::Escape,
            '\n' => self.line_feed(),
            '\r' => self.col = 0,
            '\u{08}' => self.col = self.col.saturating_sub(1),
            '\t' => self.col = ((self.col / 8 + 1) * 8).min(MAX_LINE_COLUMNS),
            // C1 introducers, for 8-bit-style streams that were UTF-8 decoded.
            '\u{9b}' => self.start_csi(),
            '\u{90}' | '\u{98}' | '\u{9d}' | '\u{9e}' | '\u{9f}' => {
                self.parser.state = State::Str { saw_escape: false }
            }
            c if c.is_control() || is_spoofing(c) || is_filler(c) => {}
            c => self.put(c),
        }
    }

    fn escape(&mut self, c: char) {
        match c {
            '[' => self.start_csi(),
            // OSC, DCS, SOS, PM, APC.
            ']' | 'P' | 'X' | '^' | '_' => self.parser.state = State::Str { saw_escape: false },
            '\u{1b}' => {}
            '\u{20}'..='\u{2f}' => self.parser.state = State::EscapeIntermediate,
            // Fe / Fp / Fs: one final character.
            '\u{30}'..='\u{7e}' => self.parser.state = State::Ground,
            _ => self.reground(c),
        }
    }

    /// Abandon the current sequence and handle `c` as ordinary input.
    fn reground(&mut self, c: char) {
        self.parser.state = State::Ground;
        self.ground(c);
    }

    fn start_csi(&mut self) {
        self.parser.state = State::Csi;
        self.parser.params.clear();
        self.parser.csi_ignored = false;
    }

    fn csi(&mut self, c: char) {
        match c {
            '\u{30}'..='\u{3f}' => {
                if matches!(c, '<' | '=' | '>' | '?')
                    || self.parser.params.len() >= MAX_CSI_PARAM_LEN
                {
                    self.parser.csi_ignored = true;
                } else {
                    self.parser.params.push(c);
                }
            }
            '\u{20}'..='\u{2f}' => self.parser.csi_ignored = true,
            '\u{40}'..='\u{7e}' => {
                self.parser.state = State::Ground;
                if !self.parser.csi_ignored {
                    let params = std::mem::take(&mut self.parser.params);
                    self.dispatch_csi(c, &params);
                }
            }
            '\u{1b}' => self.parser.state = State::Escape,
            // DEL is ignored inside a sequence.
            '\u{7f}' => {}
            // Anything else (a control character or a non-ASCII one) cancels
            // the sequence and takes effect.
            c => self.reground(c),
        }
    }

    fn string_body(&mut self, c: char, saw_escape: bool) {
        match c {
            '\u{07}' | '\u{9c}' => self.parser.state = State::Ground,
            '\\' if saw_escape => self.parser.state = State::Ground,
            '\u{1b}' => self.parser.state = State::Str { saw_escape: true },
            // A real string never holds a newline; stop a stray opener from
            // swallowing the rest of the stream.
            '\n' => self.reground(c),
            _ if saw_escape => {
                // ESC that was not ST: it starts a fresh escape sequence.
                self.parser.state = State::Escape;
                self.escape(c);
            }
            _ => {}
        }
    }

    fn dispatch_csi(&mut self, final_byte: char, params: &str) {
        let n = first_param(params);
        let count = n.unwrap_or(1).max(1);
        match final_byte {
            'A' => self.cursor_row = self.cursor_row.saturating_sub(count),
            'B' => self.cursor_row = (self.cursor_row + count).min(self.rows.len() - 1),
            'C' => self.col = (self.col + count).min(MAX_LINE_COLUMNS),
            'D' => self.col = self.col.saturating_sub(count),
            'G' => self.col = (count - 1).min(MAX_LINE_COLUMNS),
            'K' => self.erase_in_line(n.unwrap_or(0)),
            'P' => {
                let col = self.col;
                self.edit_row(|row| row.delete(col, count));
            }
            _ => {}
        }
    }

    fn erase_in_line(&mut self, mode: usize) {
        let col = self.col;
        self.edit_row(|row| match mode {
            0 => row.cells.retain(|&(c, _)| usize::from(c) < col),
            1 => row.cells.retain(|&(c, _)| usize::from(c) > col),
            2 => row.cells.clear(),
            _ => {}
        });
    }

    fn line_feed(&mut self) {
        self.col = 0;
        if self.cursor_row + 1 == self.rows.len() {
            self.rows.push_back(Row::default());
        }
        self.cursor_row += 1;
        self.enforce_caps();
    }

    fn put(&mut self, c: char) {
        let col = self.col;
        self.edit_row(|row| {
            if col >= MAX_LINE_COLUMNS {
                row.clipped = true;
                row.set(MAX_LINE_COLUMNS - 1, '…');
                return;
            }
            // Keep the clip marker visible if the last column was rewritten.
            let c = if row.clipped && col == MAX_LINE_COLUMNS - 1 {
                '…'
            } else {
                c
            };
            row.set(col, c);
        });
        if col < MAX_LINE_COLUMNS {
            self.col += 1;
        }
        self.enforce_caps();
    }

    /// Run `f` on the cursor row, keeping `cells_total` in step.
    fn edit_row(&mut self, f: impl FnOnce(&mut Row)) {
        let row = &mut self.rows[self.cursor_row];
        let before = row.width();
        f(row);
        let after = row.width();
        self.cells_total = (self.cells_total + after).saturating_sub(before);
    }

    /// Drop the oldest rows while more than [`MAX_BUFFERED_ROWS`] rows or
    /// [`MAX_BUFFERED_CELLS`] columns are buffered.
    fn enforce_caps(&mut self) {
        while (self.rows.len() > MAX_BUFFERED_ROWS || self.cells_total > MAX_BUFFERED_CELLS)
            && self.rows.len() > 1
        {
            if let Some(row) = self.rows.pop_front() {
                if row.may_hold_key_marker() {
                    self.dropped_in_key = private_key_open_after(&row.text(), self.dropped_in_key);
                }
                self.cells_total = self.cells_total.saturating_sub(row.width());
                self.dropped_rows += 1;
                self.cursor_row = self.cursor_row.saturating_sub(1);
            }
        }
    }
}

impl Row {
    /// Whether the row may hold a key marker (`-----BEGIN …`, `-----END …`):
    /// it has at least five cells that are a dash or not ASCII (a dash
    /// look-alike, or an invisible character spliced into the dashes). Checked
    /// on stored cells so a row of padding costs nothing.
    fn may_hold_key_marker(&self) -> bool {
        self.cells
            .iter()
            .filter(|&&(_, c)| c == '-' || !c.is_ascii())
            .nth(4)
            .is_some()
    }

    /// Columns from 0 through the last non-blank cell.
    fn width(&self) -> usize {
        self.cells.last().map_or(0, |&(c, _)| usize::from(c) + 1)
    }

    /// Write `c` at `col` (`col < MAX_LINE_COLUMNS`). A space is a blank, so it
    /// is never stored.
    fn set(&mut self, col: usize, c: char) {
        let col = col as u16;
        match self.cells.binary_search_by_key(&col, |&(c, _)| c) {
            Ok(i) if c == ' ' => {
                self.cells.remove(i);
            }
            Ok(i) => self.cells[i].1 = c,
            Err(_) if c == ' ' => {}
            Err(i) => self.cells.insert(i, (col, c)),
        }
    }

    /// Delete `count` cells at `col`, shifting the rest left.
    fn delete(&mut self, col: usize, count: usize) {
        if col >= self.width() {
            return;
        }
        let end = col.saturating_add(count);
        self.cells
            .retain(|&(c, _)| !(col..end).contains(&usize::from(c)));
        for (c, _) in self
            .cells
            .iter_mut()
            .filter(|(c, _)| usize::from(*c) >= col)
        {
            *c -= count.min(usize::from(*c)) as u16;
        }
    }

    fn text(&self) -> String {
        let mut text = String::with_capacity(self.width());
        let mut next = 0;
        for &(col, c) in &self.cells {
            text.extend(std::iter::repeat_n(' ', usize::from(col) - next));
            text.push(c);
            next = usize::from(col) + 1;
        }
        text
    }
}

/// First numeric CSI parameter, if present (`CSI ;5 C` has none).
fn first_param(params: &str) -> Option<usize> {
    params
        .split(';')
        .next()
        .filter(|p| !p.is_empty())
        .map(|p| p.parse().unwrap_or(usize::MAX / 2))
}

/// Characters that can hide or reorder text for a reader: bidirectional
/// controls and the Unicode tag block (used to smuggle invisible ASCII).
fn is_spoofing(c: char) -> bool {
    matches!(c,
        '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}'
        | '\u{e0000}'..='\u{e007f}')
}

/// Characters that render as nothing and so can sit inside a token or a number
/// without changing how it looks (`ghp_<ZWSP>…`, `219-<ZWSP>09-9999`): soft
/// hyphen, combining grapheme joiner, zero-width space / non-joiner / joiner,
/// the word joiner and invisible operators, and the byte-order mark. They are
/// dropped before the text is stored, so the redactor sees the line as a
/// reader does.
fn is_filler(c: char) -> bool {
    matches!(c,
        '\u{ad}' | '\u{34f}' | '\u{200b}'..='\u{200d}' | '\u{2060}'..='\u{2064}' | '\u{feff}')
}

/// Incremental UTF-8 decoder: split sequences are reassembled across calls
/// and each malformed run yields one U+FFFD.
#[derive(Debug, Default)]
struct Utf8Decoder {
    buf: [u8; 4],
    len: usize,
    need: usize,
}

impl Utf8Decoder {
    /// Feed one byte; up to two characters can come out (a U+FFFD for an
    /// interrupted sequence, then the character the byte itself starts).
    fn push(&mut self, b: u8, out: &mut [Option<char>; 2]) {
        if self.len > 0 {
            if (0x80..=0xbf).contains(&b) {
                self.buf[self.len] = b;
                self.len += 1;
                if self.len == self.need {
                    out[0] = Some(
                        std::str::from_utf8(&self.buf[..self.len])
                            .ok()
                            .and_then(|s| s.chars().next())
                            .unwrap_or('\u{fffd}'),
                    );
                    self.len = 0;
                }
                return;
            }
            // Interrupted: the partial sequence is one replacement char.
            self.len = 0;
            out[0] = Some('\u{fffd}');
            let mut rest = [None, None];
            self.push(b, &mut rest);
            out[1] = rest[0];
            return;
        }
        match b {
            0x00..=0x7f => out[0] = Some(b as char),
            0xc2..=0xdf => self.begin(b, 2),
            0xe0..=0xef => self.begin(b, 3),
            0xf0..=0xf4 => self.begin(b, 4),
            _ => out[0] = Some('\u{fffd}'),
        }
    }

    fn begin(&mut self, b: u8, need: usize) {
        self.buf[0] = b;
        self.len = 1;
        self.need = need;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::Ordering;

    use super::*;

    #[test]
    fn feeding_never_renders_the_partial_line() {
        let mut a = LineAssembler::new();
        for _ in 0..10_000 {
            a.feed(b"x");
        }
        assert_eq!(a.renders.load(Ordering::Relaxed), 0);
        assert_eq!(
            a.current_partial().map(|p| p.chars().count()),
            Some(MAX_LINE_COLUMNS)
        );
        // Read again without feeding: cached, not rendered a second time.
        let _ = a.current_partial();
        assert_eq!(a.renders.load(Ordering::Relaxed), 1);
        a.feed(b"y");
        let _ = a.current_partial();
        assert_eq!(a.renders.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn cursor_movement_stores_nothing() {
        let mut a = LineAssembler::new();
        a.feed(b"\x1b[4000C\x1b[4000D\x1b[2K");
        assert_eq!(a.rows[0].cells.len(), 0);
        a.feed(b"a\x1b[4000Cb");
        assert_eq!(a.rows[0].cells.len(), 2, "two cells, however far apart");
        assert_eq!(a.buffered_cells(), 4002);
    }

    #[test]
    fn delete_shifts_later_cells_left_across_gaps() {
        let mut a = LineAssembler::new();
        a.feed(b"ab\x1b[5Ccd\r\x1b[2P\n");
        assert_eq!(a.take_committed(), vec![format!("{}cd", " ".repeat(5))]);
    }

    #[test]
    fn dropped_rows_are_reported_once_and_content_free() {
        let mut a = LineAssembler::new();
        let rows = MAX_BUFFERED_ROWS + 10;
        for _ in 0..rows {
            a.feed(b"secret-looking text\n");
        }
        assert!(a.buffered_rows() <= MAX_BUFFERED_ROWS);
        let lines = a.take_committed();
        assert_eq!(
            lines[0],
            format!("[… {} lines dropped …]", rows + 1 - MAX_BUFFERED_ROWS)
        );
        assert_eq!(a.take_committed().len(), 0);
    }

    #[test]
    fn a_dropped_key_header_is_put_back_for_the_redactor() {
        let mut a = LineAssembler::new();
        a.feed(b"-----BEGIN RSA PRIVATE KEY-----\n");
        for i in 0..MAX_BUFFERED_ROWS + 5 {
            a.feed(format!("BODY{i}\n").as_bytes());
        }
        let lines = a.take_committed();
        assert!(lines[0].starts_with("[… "), "{:?}", lines[0]);
        assert_eq!(lines[1], DROPPED_KEY_HEADER);
        assert!(lines[2].starts_with("BODY"));
        // Only once.
        a.feed(b"x\n");
        assert!(!a.take_committed().iter().any(|l| l == DROPPED_KEY_HEADER));
    }

    #[test]
    fn a_dropped_closed_key_leaves_no_header_behind() {
        let mut a = LineAssembler::new();
        a.feed(b"-----BEGIN RSA PRIVATE KEY-----\nBODY\n-----END RSA PRIVATE KEY-----\n");
        for i in 0..MAX_BUFFERED_ROWS + 5 {
            a.feed(format!("line{i}\n").as_bytes());
        }
        assert!(!a.take_committed().iter().any(|l| l == DROPPED_KEY_HEADER));
    }
}
