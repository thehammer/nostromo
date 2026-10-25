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
//! * Columns are `char`s. Double-width (CJK) and combining characters are
//!   counted as one column, so redraws over them can be off.
//! * Only `A B C D G K P` (CSI) are interpreted. Every other sequence
//!   (`H`, `J`, `L`, scroll regions, mode switches, …) is stripped and has no
//!   effect.

use std::collections::VecDeque;

/// Longest line, in columns (chars), that [`LineAssembler`] keeps. A longer
/// line is cut and its last column is replaced by `…`.
pub const MAX_LINE_COLUMNS: usize = 4096;

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
    /// Text of the cursor row with trailing spaces trimmed, refreshed at the
    /// end of every `feed`; `None` when empty.
    partial: Option<String>,
}

#[derive(Debug, Default, Clone)]
struct Row {
    cells: Vec<char>,
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
            partial: None,
        }
    }

    /// Consume the next chunk of terminal output. Chunk boundaries may fall
    /// anywhere. Bytes are discarded while [suspended](Self::suspend).
    pub fn feed(&mut self, bytes: &[u8]) {
        if self.suspended {
            return;
        }
        for &b in bytes {
            let mut decoded = [None, None];
            self.utf8.push(b, &mut decoded);
            for c in decoded.into_iter().flatten() {
                self.handle_char(c);
            }
        }
        self.refresh_partial();
    }

    /// Remove and return the finished lines, oldest first, with trailing
    /// spaces trimmed. Rows at or below the cursor row stay buffered (see the
    /// [module docs](self)); the live line is never returned.
    pub fn take_committed(&mut self) -> Vec<String> {
        let take = self.cursor_row.min(self.rows.len() - 1);
        let lines = self.rows.drain(..take).map(|row| row.text()).collect();
        self.cursor_row -= take;
        lines
    }

    /// The text on the cursor's row, trailing spaces trimmed; `None` when
    /// the row is empty. This is the "prompt line" while a shell waits.
    pub fn current_partial(&self) -> Option<&str> {
        self.partial.as_deref()
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
        self.refresh_partial();
    }

    /// Whether input is currently being discarded.
    pub fn is_suspended(&self) -> bool {
        self.suspended
    }

    fn reset_parsers(&mut self) {
        self.parser = Parser::new();
        self.utf8 = Utf8Decoder::default();
    }

    fn refresh_partial(&mut self) {
        let text = self.rows[self.cursor_row].text();
        self.partial = (!text.is_empty()).then_some(text);
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
            c if c.is_control() || is_spoofing(c) => {}
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
                let cells = &mut self.rows[self.cursor_row].cells;
                if col < cells.len() {
                    cells.drain(col..(col + count).min(cells.len()));
                }
            }
            _ => {}
        }
    }

    fn erase_in_line(&mut self, mode: usize) {
        let col = self.col;
        let row = &mut self.rows[self.cursor_row];
        match mode {
            0 => row.cells.truncate(col),
            1 => {
                let end = (col + 1).min(row.cells.len());
                row.cells[..end].fill(' ');
            }
            2 => row.cells.clear(),
            _ => {}
        }
    }

    fn line_feed(&mut self) {
        self.col = 0;
        if self.cursor_row + 1 == self.rows.len() {
            self.rows.push_back(Row::default());
        }
        self.cursor_row += 1;
    }

    fn put(&mut self, c: char) {
        let col = self.col;
        let row = &mut self.rows[self.cursor_row];
        if col >= MAX_LINE_COLUMNS {
            row.clipped = true;
            row.cells.resize(MAX_LINE_COLUMNS, ' ');
            row.cells[MAX_LINE_COLUMNS - 1] = '…';
            return;
        }
        if col > row.cells.len() {
            row.cells.resize(col, ' ');
        }
        if col == row.cells.len() {
            row.cells.push(c);
        } else {
            row.cells[col] = c;
        }
        if row.clipped && col == MAX_LINE_COLUMNS - 1 {
            // Keep the clip marker visible if the last column was rewritten.
            row.cells[col] = '…';
        }
        self.col += 1;
    }
}

impl Row {
    fn text(&self) -> String {
        let text: String = self.cells.iter().collect();
        text.trim_end_matches(' ').to_owned()
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
