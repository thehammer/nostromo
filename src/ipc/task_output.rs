//! Reading and cleaning the output of a background task, for the activity
//! panel's one-line preview (BA0) and, later, the ranged output reads (BA1).
//!
//! Two halves:
//!
//! * [`sanitize`] / [`last_nonempty_line`]: turn raw output bytes into plain
//!   text a client can show without interpreting anything. Terminal escape
//!   sequences are removed, a progress bar's `\r` rewrites collapse to the
//!   final state, other control characters are dropped, and binary output is
//!   replaced by a notice. The result is never markdown and never contains
//!   `ESC` (0x1b).
//! * [`OutputFileValidator`]: the only way the daemon opens a task's output
//!   file. A client never supplies a path, and a path the CLI reports is
//!   still checked before it is opened: shape, location, symlinks, owner and
//!   file type.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use crate::data::work::is_invisible;

/// A preview is at most this many characters.
pub const PREVIEW_MAX_CHARS: usize = 200;

/// A preview reads at most this many bytes from the end of the output.
pub const TAIL_MAX_BYTES: usize = 8 * 1024;

/// A chunk with more than this share of NUL bytes is binary.
const BINARY_NUL_SHARE_PERCENT: usize = 10;

// ── sanitiser ───────────────────────────────────────────────────────────────

/// Clean raw task output for display.
///
/// * Invalid UTF-8 is replaced (lossy decode).
/// * A chunk of more than 10 % NUL bytes becomes `[binary output: N bytes]`.
/// * ANSI/VT escape sequences are removed: CSI (`ESC [ … final`), OSC and the
///   other string sequences (terminated by BEL, ST `ESC \`, or, as a safety so
///   a stray opener cannot swallow the rest of the output, a newline), and any
///   other `ESC`-introduced sequence. The 8-bit CSI/OSC introducers
///   (U+009B / U+009D) are handled the same way.
/// * Within a line, a lone `\r` is a carriage return: only the text after the
///   last one is kept (progress bars rewrite their line). `\r\n` is a plain
///   line ending. A line whose text after the last `\r` is empty keeps the
///   last non-empty segment instead, so a trailing `\r` never blanks a line.
/// * Every other control character except `\n` and `\t` is dropped, and so
///   is every invisible format character (`is_invisible`: bidi overrides and
///   isolates, zero-width and tag characters, variation selectors, …) that
///   could spoof or hide text.
pub fn sanitize(input: &[u8]) -> String {
    let nuls = input.iter().filter(|&&b| b == 0).count();
    if !input.is_empty() && nuls * 100 > input.len() * BINARY_NUL_SHARE_PERCENT {
        return format!("[binary output: {} bytes]", input.len());
    }
    let text = String::from_utf8_lossy(input);
    let without_escapes = strip_escapes(&text);
    collapse_carriage_returns(&without_escapes)
}

/// Remove escape sequences and every invisible character except `\n`, `\t`
/// and `\r` (the last is resolved line by line afterwards).
fn strip_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => skip_escape(&mut chars),
            '\u{9b}' => skip_csi_body(&mut chars),
            '\u{9d}' => {
                if skip_string_body(&mut chars) {
                    skip_escape(&mut chars);
                }
            }
            '\n' | '\t' | '\r' => out.push(c),
            c if is_invisible(c) => {}
            c => out.push(c),
        }
    }
    out
}

/// After an `ESC`: consume the rest of the sequence. Iterative: a string
/// sequence cut short by another `ESC` continues with that escape in the same
/// loop, so a hostile run of openers cannot recurse.
fn skip_escape(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    loop {
        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                skip_csi_body(chars);
                return;
            }
            // OSC, DCS, SOS, PM, APC: strings that run to a terminator.
            Some(']') | Some('P') | Some('X') | Some('^') | Some('_') => {
                chars.next();
                if !skip_string_body(chars) {
                    return;
                }
                // Another escape began where the string was cut short.
            }
            // nF sequences: intermediates 0x20-0x2F, then one final 0x30-0x7E.
            Some(c) if ('\u{20}'..='\u{2f}').contains(&c) => {
                while chars.next_if(|c| ('\u{20}'..='\u{2f}').contains(c)).is_some() {}
                chars.next_if(|c| ('\u{30}'..='\u{7e}').contains(c));
                return;
            }
            // Fe/Fp/Fs: a single final character.
            Some(c) if ('\u{30}'..='\u{7e}').contains(&c) => {
                chars.next();
                return;
            }
            // A lone ESC before anything else (a newline, end of input, a
            // non-ASCII character): drop the ESC alone.
            _ => return,
        }
    }
}

/// The body of a CSI sequence: parameters 0x30-0x3F, intermediates 0x20-0x2F,
/// one final 0x40-0x7E. A byte that fits none of them ends the sequence
/// without being consumed.
fn skip_csi_body(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    while chars.next_if(|c| ('\u{30}'..='\u{3f}').contains(c)).is_some() {}
    while chars.next_if(|c| ('\u{20}'..='\u{2f}').contains(c)).is_some() {}
    chars.next_if(|c| ('\u{40}'..='\u{7e}').contains(c));
}

/// The body of an OSC-style string: up to BEL, ST (`ESC \`) or a newline.
/// BEL and ST are consumed; a newline is left for the caller. Returns `true`
/// when an `ESC` that is not part of ST cut the string short: that `ESC` has
/// been consumed and the escape sequence after it is still to be skipped.
fn skip_string_body(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) -> bool {
    while let Some(&c) = chars.peek() {
        match c {
            '\u{07}' | '\u{9c}' => {
                chars.next();
                return false;
            }
            '\u{1b}' => {
                chars.next();
                if chars.peek() == Some(&'\\') {
                    chars.next();
                    return false;
                }
                return true;
            }
            '\n' => return false,
            _ => {
                chars.next();
            }
        }
    }
    false
}

/// Resolve `\r` line by line (see [`sanitize`]).
fn collapse_carriage_returns(text: &str) -> String {
    if !text.contains('\r') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut lines = text.split('\n').peekable();
    while let Some(line) = lines.next() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        let kept = line
            .rsplit('\r')
            .find(|segment| !segment.is_empty())
            .unwrap_or("");
        out.push_str(kept);
        if lines.peek().is_some() {
            out.push('\n');
        }
    }
    out
}

/// The last line of `text` that has anything but whitespace on it, trimmed,
/// at most [`PREVIEW_MAX_CHARS`] characters (a longer line ends in `…`).
/// `text` is expected to be sanitised already.
pub fn last_nonempty_line(text: &str) -> Option<String> {
    let line = text.lines().rev().map(str::trim).find(|l| !l.is_empty())?;
    Some(truncate_chars(line, PREVIEW_MAX_CHARS))
}

/// `s` cut to at most `max` characters; a cut string ends in `…`.
pub fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_owned();
    }
    let mut cut: String = s.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

// ── file validation and tail read ───────────────────────────────────────────

/// Why an output path was not opened.
#[derive(Debug)]
pub enum OutputFileError {
    /// The task id, the path's shape or its location is not acceptable.
    Rejected(&'static str),
    /// The path passed validation but could not be read (missing, a symlink,
    /// not a regular file, someone else's file, or an I/O error).
    Unreadable(std::io::Error),
}

impl std::fmt::Display for OutputFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OutputFileError::Rejected(why) => write!(f, "output path rejected: {why}"),
            OutputFileError::Unreadable(e) => write!(f, "output file unreadable: {e}"),
        }
    }
}

/// The tail of an output file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TailRead {
    /// At most the requested number of bytes, ending at the end of the file.
    /// Starts on a UTF-8 scalar boundary.
    pub bytes: Vec<u8>,
    pub total_bytes: u64,
}

/// A read of a range of an output file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RangeRead {
    /// The raw bytes of `[start, end)`.
    pub bytes: Vec<u8>,
    /// Where the range begins: the requested offset, moved forward past the
    /// rest of a UTF-8 scalar it fell inside.
    pub start: u64,
    /// Where it ends: on a line boundary, a UTF-8 scalar boundary and not
    /// inside an escape sequence (a line longer than the window ends where the
    /// window does, at the nearest safe place before it).
    pub end: u64,
    /// The size of the file after the read.
    pub total_bytes: u64,
}

/// `true` for an id the CLI could have issued: `^[A-Za-z0-9_-]{1,64}$`.
pub fn is_valid_task_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Decides which files the daemon may open as a task's output, and opens them.
///
/// A path is accepted only when **all** hold:
/// * the task id matches `^[A-Za-z0-9_-]{1,64}$`;
/// * the path is absolute, has no `..` component, and its file name is
///   `<task_id>.output`;
/// * the file's canonical directory lies under one of the allowed roots (the
///   CLI's tmp root, and any root learned from a path the CLI itself
///   reported);
/// * the file opens with `O_NOFOLLOW` (a symlink is refused), is a regular
///   file, and belongs to the daemon's user.
#[derive(Debug, Clone)]
pub struct OutputFileValidator {
    roots: Vec<PathBuf>,
    uid: u32,
    /// Counts every call to [`Self::open`], accepted or not (tests assert that
    /// a refused request opened nothing).
    opens: Arc<AtomicUsize>,
}

impl OutputFileValidator {
    /// A validator for the given tmp root (tests pass a temp directory).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            roots: vec![root.into()],
            uid: current_uid(),
            opens: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// Count this validator's `open` calls in `counter` (shared with whoever
    /// holds it).
    pub fn with_open_counter(mut self, counter: Arc<AtomicUsize>) -> Self {
        self.opens = counter;
        self
    }

    /// A validator for the CLI's tmp root of this user: `/private/tmp/claude-<uid>`
    /// (`/tmp/claude-<uid>` off macOS).
    pub fn for_current_user() -> Self {
        Self::new(default_tmp_root())
    }

    /// Also accept files under `root`.
    pub fn add_root(&mut self, root: impl Into<PathBuf>) {
        let root = root.into();
        if !self.roots.contains(&root) {
            self.roots.push(root);
        }
    }

    /// The roots files are accepted under.
    pub fn roots(&self) -> &[PathBuf] {
        &self.roots
    }

    /// Check `path` against the rules above and open it for reading.
    pub fn open(&self, path: &Path, task_id: &str) -> Result<File, OutputFileError> {
        self.opens.fetch_add(1, Ordering::SeqCst);
        let (dir, name) = self.check_shape(path, task_id)?;
        let file = open_nofollow(&dir.join(name)).map_err(OutputFileError::Unreadable)?;
        let meta = file.metadata().map_err(OutputFileError::Unreadable)?;
        if !meta.file_type().is_file() {
            return Err(OutputFileError::Rejected("not a regular file"));
        }
        if !self.owned_by_us(&meta) {
            return Err(OutputFileError::Rejected("not owned by the daemon's user"));
        }
        Ok(file)
    }

    /// Read the last `max_bytes` of the file at `path`.
    pub fn read_tail(
        &self,
        path: &Path,
        task_id: &str,
        max_bytes: usize,
    ) -> Result<TailRead, OutputFileError> {
        let mut file = self.open(path, task_id)?;
        let total = file.metadata().map_err(OutputFileError::Unreadable)?.len();
        let start = total.saturating_sub(max_bytes as u64);
        file.seek(SeekFrom::Start(start))
            .map_err(OutputFileError::Unreadable)?;
        let mut bytes = Vec::with_capacity((total - start) as usize);
        file.take(max_bytes as u64)
            .read_to_end(&mut bytes)
            .map_err(OutputFileError::Unreadable)?;
        if start > 0 {
            // The cut may fall inside a multi-byte character: start at the
            // first byte that is not a continuation byte.
            let skip = bytes.iter().take_while(|b| (**b & 0xC0) == 0x80).count();
            bytes.drain(..skip.min(3));
        }
        Ok(TailRead {
            bytes,
            total_bytes: total,
        })
    }

    /// Read up to `max_bytes` of the file at `path`, starting at `offset`
    /// (`None`: so that the read ends at the end of the file). The file may
    /// still be growing: see [`Self::read_range_of`].
    ///
    /// The range always starts on a UTF-8 scalar boundary and ends on one
    /// that is also outside any escape sequence, so consecutive ranges
    /// (`next offset = previous end`) can be sanitised separately and joined.
    /// When the window stops short of the end of the file the range also ends
    /// after a newline, unless the window holds no newline at all. A tail
    /// read (`None`) starts after the first newline of its window, so it does
    /// not open with half a line, unless the window holds no newline.
    ///
    /// Growth-safe: the file may grow while it is read. The range holds what
    /// was read, and `total_bytes` is the size afterwards. An `offset` past
    /// the end is an empty range at the end.
    pub fn read_range(
        &self,
        path: &Path,
        task_id: &str,
        offset: Option<u64>,
        max_bytes: usize,
    ) -> Result<RangeRead, OutputFileError> {
        self.read_range_of(path, task_id, offset, max_bytes, false)
    }

    /// [`Self::read_range`] for a file that will not grow any more
    /// (`finished`, the task has ended): what ends the file is taken whole,
    /// even half a scalar or an escape sequence that was never finished,
    /// where a file that may still grow holds those back until their end
    /// arrives.
    pub fn read_range_of(
        &self,
        path: &Path,
        task_id: &str,
        offset: Option<u64>,
        max_bytes: usize,
        finished: bool,
    ) -> Result<RangeRead, OutputFileError> {
        let mut file = self.open(path, task_id)?;
        let size = file.metadata().map_err(OutputFileError::Unreadable)?.len();
        let tail = offset.is_none();
        let mut start = match offset {
            Some(offset) => offset.min(size),
            None => size.saturating_sub(max_bytes as u64),
        };
        let mut bytes = Vec::with_capacity(max_bytes.min(size.saturating_sub(start) as usize));
        file.seek(SeekFrom::Start(start))
            .map_err(OutputFileError::Unreadable)?;
        (&mut file)
            .take(max_bytes as u64)
            .read_to_end(&mut bytes)
            .map_err(OutputFileError::Unreadable)?;
        let total_bytes = file
            .metadata()
            .map_err(OutputFileError::Unreadable)?
            .len()
            .max(start + bytes.len() as u64);

        let skip = leading_skip(&bytes, start, tail);
        bytes.drain(..skip);
        start += skip as u64;

        // End on a line, a scalar and outside an escape.
        let reached_eof = start + bytes.len() as u64 >= total_bytes;
        let keep = if reached_eof && finished {
            bytes.len()
        } else {
            safe_end(&bytes, reached_eof)
        };
        bytes.truncate(keep);
        Ok(RangeRead {
            end: start + bytes.len() as u64,
            bytes,
            start,
            total_bytes,
        })
    }

    /// The path's canonical directory and its file name, once the shape and
    /// location rules pass.
    fn check_shape<'a>(
        &self,
        path: &'a Path,
        task_id: &str,
    ) -> Result<(PathBuf, &'a std::ffi::OsStr), OutputFileError> {
        if !is_valid_task_id(task_id) {
            return Err(OutputFileError::Rejected("task id"));
        }
        if !path.is_absolute() {
            return Err(OutputFileError::Rejected("relative path"));
        }
        if path.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
            return Err(OutputFileError::Rejected("dot component"));
        }
        let name = path
            .file_name()
            .ok_or(OutputFileError::Rejected("no file name"))?;
        if name.to_str() != Some(&format!("{task_id}.output")) {
            return Err(OutputFileError::Rejected("file name"));
        }
        let dir = path
            .parent()
            .and_then(|p| std::fs::canonicalize(p).ok())
            .ok_or(OutputFileError::Rejected("directory"))?;
        let under_root = self.roots.iter().any(|root| {
            std::fs::canonicalize(root)
                .map(|root| dir.starts_with(root))
                .unwrap_or(false)
        });
        if !under_root {
            return Err(OutputFileError::Rejected("outside the tmp root"));
        }
        Ok((dir, name))
    }

    #[cfg(unix)]
    fn owned_by_us(&self, meta: &std::fs::Metadata) -> bool {
        use std::os::unix::fs::MetadataExt;
        meta.uid() == self.uid
    }

    #[cfg(not(unix))]
    fn owned_by_us(&self, _meta: &std::fs::Metadata) -> bool {
        let _ = self.uid;
        true
    }
}

/// How many leading bytes of a range read at `start` to drop: the rest of a
/// scalar the cut fell inside, and for a tail that began mid-file, the rest
/// of its first line (unless that would leave nothing: the last line is
/// longer than the window).
fn leading_skip(bytes: &[u8], start: u64, tail: bool) -> usize {
    if start == 0 {
        return 0;
    }
    let scalar_rest = bytes.iter().take(3).take_while(|b| (**b & 0xC0) == 0x80).count();
    if !tail {
        return scalar_rest;
    }
    bytes
        .iter()
        .position(|b| *b == b'\n')
        .filter(|i| i + 1 < bytes.len())
        .map_or(scalar_rest, |i| i + 1)
}

/// How far back from the end of a window an unfinished escape sequence is
/// looked for. An unterminated string sequence longer than this is output.
const ESCAPE_LOOKBACK: usize = 4096;

/// How many bytes of `window` to keep so the range ends in a safe place: on a
/// newline when the window stopped short of the end of the file (and holds
/// one), never inside a UTF-8 scalar, never inside an escape sequence.
fn safe_end(window: &[u8], reached_eof: bool) -> usize {
    let mut end = window.len();
    if !reached_eof {
        if let Some(newline) = window.iter().rposition(|b| *b == b'\n') {
            // A newline ends every escape sequence and scalar.
            return newline + 1;
        }
    }
    // Not after the first byte of a multi-byte scalar that is cut short.
    let mut back = 0;
    while back < 3 && back < end {
        let b = window[end - 1 - back];
        if (b & 0xC0) == 0x80 {
            back += 1;
            continue;
        }
        let needed = match b {
            0xC0..=0xDF => 2,
            0xE0..=0xEF => 3,
            0xF0..=0xF7 => 4,
            _ => 1,
        };
        if needed > back + 1 {
            end -= back + 1;
        }
        break;
    }
    if let Some(open) = unfinished_escape(&window[..end]) {
        // A window that is one escape sequence and nothing else keeps it
        // (unless it is the end of the file, which may yet grow) so a reader
        // always advances.
        if open > 0 || reached_eof {
            end = open;
        }
    }
    end
}

/// Where an escape sequence that has not ended by the end of `window` begins.
///
/// Sequences end at a newline, so only the last line can hold one. It is
/// scanned forward, the way the sanitiser reads it, so an introducer inside
/// a string sequence's text is not mistaken for the start of a sequence.
fn unfinished_escape(window: &[u8]) -> Option<usize> {
    let line_start = window.iter().rposition(|b| *b == b'\n').map_or(0, |p| p + 1);
    let mut at = line_start.max(window.len().saturating_sub(ESCAPE_LOOKBACK));
    while at < window.len() {
        let Some(body) = introducer_body(window, at) else {
            at += 1;
            continue;
        };
        match escape_end(window, at, body) {
            None => return Some(at),
            // `max`: always move on, whatever the sequence consumed.
            Some(end) => at = end.max(at + 1),
        }
    }
    None
}

/// Where the body of the escape sequence introduced at `at` begins: after an
/// `ESC`, or after the 8-bit introducers U+009B / U+009D (`C2 9B`, `C2 9D`).
fn introducer_body(window: &[u8], at: usize) -> Option<usize> {
    match window[at] {
        0x1b => Some(at + 1),
        0xc2 if matches!(window.get(at + 1), Some(0x9b | 0x9d)) => Some(at + 1),
        _ => None,
    }
}

/// Where the sequence introduced at `at` (body from `body`) ends: `Some(end)`
/// when the window holds all of it (`end` is where the next thing starts, which
/// may be the escape that cut a string short), `None` when it runs off the end.
fn escape_end(window: &[u8], at: usize, body: usize) -> Option<usize> {
    if window[at] != 0x1b {
        // An 8-bit introducer: `body` is its `9B` / `9D` byte.
        return if window[body] == 0x9b {
            csi_end(window, body + 1)
        } else {
            string_end(window, body + 1)
        };
    }
    match *window.get(body)? {
        b'[' => csi_end(window, body + 1),
        b']' | b'P' | b'X' | b'^' | b'_' => string_end(window, body + 1),
        // nF: intermediates 0x20-0x2F, then one final 0x30-0x7E.
        c if (0x20..=0x2f).contains(&c) => {
            let mut k = body;
            while window.get(k).is_some_and(|b| (0x20..=0x2f).contains(b)) {
                k += 1;
            }
            match window.get(k) {
                None => None,
                Some(b) if (0x30..=0x7e).contains(b) => Some(k + 1),
                Some(_) => Some(k),
            }
        }
        // Fe/Fp/Fs: a single final byte.
        c if (0x30..=0x7e).contains(&c) => Some(body + 1),
        // A lone ESC.
        _ => Some(body),
    }
}

fn csi_end(window: &[u8], from: usize) -> Option<usize> {
    let mut k = from;
    while window.get(k).is_some_and(|b| (0x30..=0x3f).contains(b)) {
        k += 1;
    }
    while window.get(k).is_some_and(|b| (0x20..=0x2f).contains(b)) {
        k += 1;
    }
    match window.get(k) {
        None => None,
        Some(b) if (0x40..=0x7e).contains(b) => Some(k + 1),
        Some(_) => Some(k),
    }
}

/// An OSC-style string ends at BEL, ST (`ESC \`, or U+009C) or a newline; any
/// other `ESC` cuts it short and starts a sequence of its own.
fn string_end(window: &[u8], from: usize) -> Option<usize> {
    let mut k = from;
    while k < window.len() {
        match window[k] {
            0x07 => return Some(k + 1),
            b'\n' => return Some(k),
            0xc2 if window.get(k + 1) == Some(&0x9c) => return Some(k + 2),
            0x1b => {
                return match window.get(k + 1) {
                    None => None,
                    Some(b'\\') => Some(k + 2),
                    Some(_) => Some(k),
                };
            }
            _ => k += 1,
        }
    }
    None
}

/// The root a CLI-reported output path implies: the path is
/// `<root>/<cwd>/<session>/tasks/<task_id>.output`, so four levels up.
/// `None` when the path is too shallow to have that shape.
pub fn root_of_output_path(path: &Path) -> Option<PathBuf> {
    if path.parent()?.file_name()?.to_str() != Some("tasks") {
        return None;
    }
    let root = path.ancestors().nth(4)?;
    (root.parent().is_some()).then(|| root.to_path_buf())
}

/// The parents under which the CLI keeps its `claude-<uid>` tmp root.
const TRUSTED_TMP_PARENTS: [&str; 2] = ["/tmp", "/private/tmp"];

/// The root a CLI-reported output path may teach the validator: what
/// [`root_of_output_path`] finds, provided it is `<tmp>/claude-<uid>` for the
/// given `uid` with `<tmp>` one of `/tmp` and `/private/tmp`. A path that
/// puts the CLI's files anywhere else (a project's `Documents` folder, say)
/// teaches nothing, so a hostile report cannot widen what the daemon reads.
pub fn learnable_root(path: &Path, uid: u32) -> Option<PathBuf> {
    if path.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
        return None;
    }
    let root = root_of_output_path(path)?;
    let name_ok = root.file_name().and_then(|n| n.to_str()) == Some(&format!("claude-{uid}"));
    let parent_ok = root
        .parent()
        .is_some_and(|parent| TRUSTED_TMP_PARENTS.iter().any(|t| parent == Path::new(t)));
    (name_ok && parent_ok).then_some(root)
}

fn default_tmp_root() -> PathBuf {
    let base = if cfg!(target_os = "macos") { "/private/tmp" } else { "/tmp" };
    PathBuf::from(base).join(format!("claude-{}", current_uid()))
}

#[cfg(unix)]
pub fn current_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

#[cfg(not(unix))]
pub fn current_uid() -> u32 {
    0
}

#[cfg(unix)]
fn open_nofollow(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    // O_NONBLOCK: opening a FIFO that slipped in must not block the daemon.
    // O_NOCTTY: opening a terminal device must not make it our controlling tty.
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY)
        .open(path)
}

#[cfg(not(unix))]
fn open_nofollow(path: &Path) -> std::io::Result<File> {
    File::open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── sanitiser ───────────────────────────────────────────────────────────

    #[test]
    fn colour_codes_are_removed_and_the_text_is_kept() {
        assert_eq!(sanitize(b"\x1b[31mred\x1b[0m and \x1b[1;4;38;5;208mbold\x1b[m"), "red and bold");
    }

    #[test]
    fn cursor_and_erase_sequences_are_removed() {
        assert_eq!(sanitize(b"a\x1b[2K\x1b[1Gb\x1b[?25lc\x1b[10;20Hd"), "abcd");
    }

    #[test]
    fn a_window_title_sequence_is_removed_whether_it_ends_in_bel_or_st() {
        assert_eq!(sanitize(b"x\x1b]0;my title\x07y"), "xy");
        assert_eq!(sanitize(b"x\x1b]0;my title\x1b\\y"), "xy");
        assert_eq!(sanitize(b"x\x1b]8;;https://example.invalid\x07link\x1b]8;;\x07y"), "xlinky");
    }

    #[test]
    fn an_unterminated_title_sequence_does_not_swallow_the_following_lines() {
        assert_eq!(sanitize(b"before\x1b]0;never ends\nnext line\n"), "before\nnext line\n");
    }

    #[test]
    fn other_escape_sequences_are_removed() {
        assert_eq!(sanitize(b"a\x1bcb"), "ab", "reset");
        assert_eq!(sanitize(b"a\x1b7b\x1b8c"), "abc", "save and restore cursor");
        assert_eq!(sanitize(b"a\x1b(Bb"), "ab", "charset selection");
        assert_eq!(sanitize(b"a\x1bPq#0;2;0;0;0\x1b\\b"), "ab", "device control string");
    }

    #[test]
    fn a_lone_escape_is_dropped_wherever_it_sits() {
        assert_eq!(sanitize(b"abc\x1b"), "abc");
        assert_eq!(sanitize(b"a\x1b\nb"), "a\nb");
        assert_eq!(sanitize("a\x1b\u{e9}b".as_bytes()), "a\u{e9}b");
        assert_eq!(sanitize(b"\x1b\x1b\x1b"), "");
    }

    #[test]
    fn a_carriage_return_inside_a_line_keeps_only_what_follows_it() {
        assert_eq!(sanitize(b"a\rb\n"), "b\n");
        assert_eq!(sanitize(b"10%\r50%\r100% done\nnext\n"), "100% done\nnext\n");
    }

    #[test]
    fn a_crlf_is_an_ordinary_line_ending() {
        assert_eq!(sanitize(b"one\r\ntwo\r\n"), "one\ntwo\n");
    }

    #[test]
    fn a_trailing_carriage_return_does_not_blank_the_line() {
        assert_eq!(sanitize(b"progress 90%\r"), "progress 90%");
    }

    #[test]
    fn tabs_and_newlines_survive() {
        assert_eq!(sanitize(b"a\tb\nc"), "a\tb\nc");
    }

    #[test]
    fn other_control_characters_and_delete_are_dropped() {
        assert_eq!(sanitize(b"a\x01\x02\x07\x08\x0b\x0c\x0e\x1f\x7fb"), "ab");
    }

    #[test]
    fn eight_bit_control_characters_are_dropped() {
        assert_eq!(sanitize("a\u{9b}31mb\u{85}c".as_bytes()), "a" .to_owned() + "b" + "c");
        assert_eq!(sanitize("a\u{9d}0;title\u{07}b".as_bytes()), "ab");
    }

    #[test]
    fn a_few_stray_nul_bytes_are_dropped_not_treated_as_binary() {
        let mut input = vec![b'x'; 50];
        input[10] = 0;
        assert_eq!(sanitize(&input), "x".repeat(49));
    }

    #[test]
    fn mostly_nul_output_is_replaced_by_a_notice_with_its_size() {
        assert_eq!(sanitize(&[0u8; 64]), "[binary output: 64 bytes]");
        let mut input = b"ab".to_vec();
        input.extend([0u8; 4]);
        assert_eq!(sanitize(&input), "[binary output: 6 bytes]");
    }

    #[test]
    fn ten_percent_nul_is_still_text_and_more_than_that_is_binary() {
        let mut at_limit = vec![b'x'; 100];
        at_limit[..10].fill(0);
        assert_eq!(sanitize(&at_limit), "x".repeat(90), "exactly 10% is not over the limit");

        let mut over = vec![b'x'; 100];
        over[..11].fill(0);
        assert_eq!(sanitize(&over), "[binary output: 100 bytes]");
    }

    #[test]
    fn empty_output_is_empty_text() {
        assert_eq!(sanitize(b""), "");
    }

    #[test]
    fn invalid_utf8_is_replaced_not_fatal() {
        assert_eq!(sanitize(&[b'a', 0xff, b'b']), "a\u{fffd}b");
        assert_eq!(sanitize(&[0x80, 0x80, b'z']), "\u{fffd}\u{fffd}z");
        // A character cut in half at the end.
        assert_eq!(sanitize(&[b'a', 0xe2, 0x82]), "a\u{fffd}");
    }

    #[test]
    fn plain_unicode_text_is_untouched() {
        assert_eq!(sanitize("caf\u{e9} \u{2713} \u{1f600}\n".as_bytes()), "caf\u{e9} \u{2713} \u{1f600}\n");
    }

    /// xorshift64*: deterministic, no external crate.
    struct Prng(u64);

    impl Prng {
        fn next(&mut self) -> u64 {
            self.0 ^= self.0 >> 12;
            self.0 ^= self.0 << 25;
            self.0 ^= self.0 >> 27;
            self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
        }

        fn below(&mut self, n: usize) -> usize {
            (self.next() % n as u64) as usize
        }
    }

    /// Bytes that stress the escape handling: openers, terminators, parameters
    /// and plain text, in random order, with some fully random bytes.
    fn hostile_bytes(rng: &mut Prng, len: usize) -> Vec<u8> {
        const PIECES: &[&[u8]] = &[
            b"\x1b", b"\x1b[", b"\x1b]", b"\x1bP", b"\x1b_", b"\x1b^", b"\x1bX", b"\x1b(", b"\x1b\\",
            b"\x07", b"\r", b"\r\n", b"\n", b"\t", b"[", b"]", b";", b"31", b"0", b"m", b"H", b"abc ", b" ",
            "\u{9b}".as_bytes(), "\u{9d}".as_bytes(), "\u{e9}".as_bytes(), b"\x00", b"\x7f",
        ];
        let mut out = Vec::with_capacity(len + 8);
        while out.len() < len {
            if rng.below(8) == 0 {
                out.push(rng.below(256) as u8);
            } else {
                out.extend_from_slice(PIECES[rng.below(PIECES.len())]);
            }
        }
        out
    }

    /// What every sanitised string must satisfy, whatever went in.
    fn assert_clean(out: &str) {
        for c in out.chars() {
            assert!(
                c == '\n' || c == '\t' || !c.is_control(),
                "control character {c:?} survived: {out:?}"
            );
        }
    }

    #[test]
    fn a_megabyte_of_random_escapes_leaves_no_escape_byte() {
        let mut rng = Prng(0x9E37_79B9_7F4A_7C15);
        let input = hostile_bytes(&mut rng, 1024 * 1024);
        assert!(input.len() >= 1024 * 1024);

        let out = sanitize(&input);

        assert!(!out.contains('\u{1b}'));
        assert_clean(&out);
    }

    #[test]
    fn many_small_random_inputs_never_leave_a_control_character() {
        let mut rng = Prng(42);
        for round in 0..5_000 {
            let len = rng.below(64);
            let input = hostile_bytes(&mut rng, len);
            let out = sanitize(&input);
            assert!(!out.contains('\u{1b}'), "round {round}: {input:?} -> {out:?}");
            assert_clean(&out);
        }
    }

    #[test]
    fn every_truncation_of_an_escape_sequence_leaves_no_escape_byte() {
        let full: &[u8] = b"text\x1b[38;5;208m\x1b]0;title\x07\x1b]8;;http://x.invalid\x1b\\\x1bPq\x1b\\end";
        for cut in 0..=full.len() {
            let out = sanitize(&full[..cut]);
            assert!(!out.contains('\u{1b}'), "cut {cut}: {out:?}");
            assert_clean(&out);
        }
    }

    #[test]
    fn random_bytes_around_an_escape_do_not_change_what_the_sanitiser_promises() {
        let mut rng = Prng(7);
        for _ in 0..2_000 {
            let mut input = hostile_bytes(&mut rng, 16);
            let at = rng.below(input.len());
            input.splice(at..at, b"\x1b[".iter().copied());
            assert_clean(&sanitize(&input));
        }
    }

    /// The work of the next test, run in a child process: a stack overflow
    /// aborts the whole process, which must not take the rest of the suite
    /// down with it. Not run on its own.
    #[test]
    #[ignore = "run by a_long_run_of_nested_string_openers_neither_overflows_the_stack_nor_leaks_an_escape"]
    fn nested_string_openers_child() {
        // The sanitiser runs on daemon threads with an ordinary 2 MiB stack,
        // over text a hostile task, description or prompt can shape freely.
        let handle = std::thread::Builder::new()
            .stack_size(2 * 1024 * 1024)
            .spawn(|| {
                let openers = "\u{1b}]".repeat(100_000);
                assert!(!sanitize(openers.as_bytes()).contains('\u{1b}'));
                let mixed = "\u{1b}]\u{1b}P\u{1b}_\u{1b}^".repeat(50_000);
                assert!(!sanitize(mixed.as_bytes()).contains('\u{1b}'));
            })
            .unwrap();
        handle.join().expect("sanitising must not panic");
    }

    #[test]
    fn a_long_run_of_nested_string_openers_neither_overflows_the_stack_nor_leaks_an_escape() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "ipc::task_output::tests::nested_string_openers_child", "--ignored", "--test-threads=1"])
            .output()
            .expect("run the test binary");
        assert!(
            output.status.success(),
            "sanitising 100k nested `ESC ]` openers crashed ({:?}):\n{}{}",
            output.status,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    // ── last_nonempty_line ──────────────────────────────────────────────────

    #[test]
    fn the_preview_is_the_last_line_with_anything_on_it() {
        assert_eq!(last_nonempty_line("first\nsecond\nthird\n"), Some("third".into()));
        assert_eq!(last_nonempty_line("first\nsecond"), Some("second".into()));
    }

    #[test]
    fn trailing_blank_and_whitespace_only_lines_are_skipped() {
        assert_eq!(last_nonempty_line("real\n\n   \n\t\n\n"), Some("real".into()));
    }

    #[test]
    fn the_preview_line_is_trimmed() {
        assert_eq!(last_nonempty_line("   padded line \t\n"), Some("padded line".into()));
    }

    #[test]
    fn all_blank_output_has_no_preview() {
        assert_eq!(last_nonempty_line(""), None);
        assert_eq!(last_nonempty_line("\n\n"), None);
        assert_eq!(last_nonempty_line("  \n\t \n   "), None);
    }

    #[test]
    fn a_line_of_exactly_200_characters_is_kept_whole() {
        let line = "a".repeat(200);
        assert_eq!(last_nonempty_line(&line), Some(line));
    }

    #[test]
    fn a_longer_line_is_cut_to_200_characters_ending_in_an_ellipsis() {
        for len in [201, 300, 5_000] {
            let preview = last_nonempty_line(&"b".repeat(len)).unwrap();
            assert_eq!(preview.chars().count(), 200, "len {len}");
            assert!(preview.ends_with('\u{2026}'), "len {len}");
            assert!(preview.starts_with("bbbb"));
        }
    }

    #[test]
    fn the_cut_counts_characters_not_bytes() {
        let preview = last_nonempty_line(&"\u{e9}".repeat(300)).unwrap();
        assert_eq!(preview.chars().count(), 200);
        assert!(preview.ends_with('\u{2026}'));
        let emoji = last_nonempty_line(&"\u{1f600}".repeat(250)).unwrap();
        assert_eq!(emoji.chars().count(), 200);
    }

    #[test]
    fn a_progress_bar_previews_as_its_final_state() {
        let raw = b"\x1b[32mDownloading\x1b[0m 10%\rDownloading 55%\rDownloading 100%\n\n";
        assert_eq!(last_nonempty_line(&sanitize(raw)), Some("Downloading 100%".into()));
    }

    // ── file validation ─────────────────────────────────────────────────────

    const ID: &str = "b7k2m9x1a";

    /// A temp tmp-root with the CLI's `<cwd>/<session>/tasks` layout.
    struct Rig {
        _dir: tempfile::TempDir,
        root: PathBuf,
        tasks: PathBuf,
    }

    fn rig() -> Rig {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("claude-501");
        let tasks = root.join("-repo").join("sess-1").join("tasks");
        std::fs::create_dir_all(&tasks).unwrap();
        Rig { _dir: dir, root, tasks }
    }

    impl Rig {
        fn validator(&self) -> OutputFileValidator {
            OutputFileValidator::new(&self.root)
        }

        fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
            let path = self.tasks.join(name);
            std::fs::write(&path, bytes).unwrap();
            path
        }

        /// A sibling directory outside the root.
        fn outside(&self) -> PathBuf {
            let dir = self.root.parent().unwrap().join("elsewhere");
            std::fs::create_dir_all(&dir).unwrap();
            dir
        }
    }

    fn rejected(v: &OutputFileValidator, path: &Path, id: &str) {
        assert!(v.open(path, id).is_err(), "{path:?} with id {id:?} must not open");
        assert!(v.read_tail(path, id, TAIL_MAX_BYTES).is_err(), "{path:?} with id {id:?} must not read");
    }

    #[test]
    fn a_regular_output_file_under_the_root_opens_and_reads() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"hello\nworld\n");

        let tail = rig.validator().read_tail(&path, ID, TAIL_MAX_BYTES).expect("reads");

        assert_eq!(tail.bytes, b"hello\nworld\n");
        assert_eq!(tail.total_bytes, 12);
    }

    #[test]
    fn the_file_may_sit_at_any_depth_under_the_root() {
        let rig = rig();
        let deep = rig.root.join("a").join("b").join("c").join("d");
        std::fs::create_dir_all(&deep).unwrap();
        let path = deep.join(format!("{ID}.output"));
        std::fs::write(&path, b"x").unwrap();

        assert!(rig.validator().open(&path, ID).is_ok());
    }

    #[test]
    fn ids_with_underscores_dashes_and_64_characters_are_accepted() {
        let rig = rig();
        let v = rig.validator();
        for id in ["a_b-C9", &"z".repeat(64), "A", "0"] {
            let path = rig.write(&format!("{id}.output"), b"x");
            assert!(v.open(&path, id).is_ok(), "{id}");
        }
    }

    #[test]
    fn the_task_id_pattern_is_enforced_even_when_the_file_is_there() {
        let rig = rig();
        let v = rig.validator();
        let long = "k".repeat(65);
        for id in ["", long.as_str(), "a.b", "a b", "caf\u{e9}", "a\nb", "..", "a;b"] {
            let path = rig.write(&format!("{id}.output").replace('\n', "_"), b"x");
            rejected(&v, &path, id);
        }
        // A separator in the id: the file really exists under that path.
        std::fs::create_dir_all(rig.tasks.join("a")).unwrap();
        let nested = rig.tasks.join("a").join("b.output");
        std::fs::write(&nested, b"x").unwrap();
        rejected(&v, &nested, "a/b");
        rejected(&v, &rig.tasks.join("a/b.output"), "a/b");
    }

    #[test]
    fn a_file_whose_name_is_not_the_task_id_dot_output_is_refused() {
        let rig = rig();
        let v = rig.validator();
        let other = rig.write("other.output", b"x");
        rejected(&v, &other, ID);
        let wrong_ext = rig.write(&format!("{ID}.txt"), b"x");
        rejected(&v, &wrong_ext, ID);
        let suffixed = rig.write(&format!("{ID}.output.bak"), b"x");
        rejected(&v, &suffixed, ID);
        let prefixed = rig.write(&format!("x{ID}.output"), b"x");
        rejected(&v, &prefixed, ID);
        let upper = rig.write(&format!("{}.output", ID.to_uppercase()), b"x");
        rejected(&v, &upper, ID);
    }

    #[test]
    fn a_path_with_a_parent_component_is_refused_even_if_it_resolves_inside_the_root() {
        let rig = rig();
        let v = rig.validator();
        rig.write(&format!("{ID}.output"), b"x");
        let sneaky = rig.tasks.join("..").join("tasks").join(format!("{ID}.output"));
        assert!(sneaky.exists(), "the path does resolve to a real file");
        rejected(&v, &sneaky, ID);

        let outside = rig.outside();
        std::fs::write(outside.join(format!("{ID}.output")), b"secret").unwrap();
        let escaping = rig.root.join("..").join("elsewhere").join(format!("{ID}.output"));
        rejected(&v, &escaping, ID);
    }

    #[test]
    fn a_relative_path_is_refused() {
        let rig = rig();
        rig.write(&format!("{ID}.output"), b"x");
        rejected(&rig.validator(), Path::new(&format!("tasks/{ID}.output")), ID);
        rejected(&rig.validator(), Path::new(&format!("{ID}.output")), ID);
    }

    #[test]
    fn a_file_outside_the_root_is_refused() {
        let rig = rig();
        let outside = rig.outside();
        let path = outside.join(format!("{ID}.output"));
        std::fs::write(&path, b"secret").unwrap();

        rejected(&rig.validator(), &path, ID);
    }

    #[test]
    fn a_directory_that_only_shares_the_roots_name_prefix_is_outside_it() {
        let rig = rig();
        let evil_root = PathBuf::from(format!("{}-evil", rig.root.display()));
        std::fs::create_dir_all(&evil_root).unwrap();
        let path = evil_root.join(format!("{ID}.output"));
        std::fs::write(&path, b"secret").unwrap();

        rejected(&rig.validator(), &path, ID);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_to_a_file_is_refused_even_when_the_target_is_inside_the_root() {
        let rig = rig();
        let real = rig.write("real.log", b"real contents");
        let link = rig.tasks.join(format!("{ID}.output"));
        std::os::unix::fs::symlink(&real, &link).unwrap();

        rejected(&rig.validator(), &link, ID);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_to_a_file_outside_the_root_is_refused() {
        let rig = rig();
        let target = rig.outside().join("passwd-like");
        std::fs::write(&target, b"secret").unwrap();
        let link = rig.tasks.join(format!("{ID}.output"));
        std::os::unix::fs::symlink(&target, &link).unwrap();

        rejected(&rig.validator(), &link, ID);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_directory_that_leads_outside_the_root_is_refused() {
        let rig = rig();
        let outside = rig.outside();
        std::fs::write(outside.join(format!("{ID}.output")), b"secret").unwrap();
        let link_dir = rig.root.join("link");
        std::os::unix::fs::symlink(&outside, &link_dir).unwrap();
        let through_link = link_dir.join(format!("{ID}.output"));
        assert!(through_link.exists(), "the file is reachable through the link");

        rejected(&rig.validator(), &through_link, ID);
    }

    #[test]
    fn a_directory_named_like_an_output_file_is_refused() {
        let rig = rig();
        let path = rig.tasks.join(format!("{ID}.output"));
        std::fs::create_dir(&path).unwrap();

        rejected(&rig.validator(), &path, ID);
    }

    #[cfg(unix)]
    #[test]
    fn a_named_pipe_is_refused_without_blocking() {
        let rig = rig();
        let path = rig.tasks.join(format!("{ID}.output"));
        let c_path = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path; mkfifo has no other preconditions.
        let made = unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) };
        assert_eq!(made, 0, "mkfifo: {}", std::io::Error::last_os_error());

        rejected(&rig.validator(), &path, ID);
    }

    #[test]
    fn a_missing_file_is_an_error_not_a_panic() {
        let rig = rig();
        rejected(&rig.validator(), &rig.tasks.join(format!("{ID}.output")), ID);
        rejected(&rig.validator(), &rig.root.join("no-such-dir").join(format!("{ID}.output")), ID);
    }

    #[test]
    fn an_added_root_is_accepted_and_others_stay_refused() {
        let rig = rig();
        let other_root = rig.outside();
        let path = other_root.join(format!("{ID}.output"));
        std::fs::write(&path, b"ok").unwrap();
        let mut v = rig.validator();
        rejected(&v, &path, ID);

        v.add_root(&other_root);

        assert!(v.open(&path, ID).is_ok());
        assert_eq!(v.roots().len(), 2);
        v.add_root(&other_root);
        assert_eq!(v.roots().len(), 2, "adding a root twice changes nothing");
        let stranger = rig.root.parent().unwrap().join("stranger");
        std::fs::create_dir_all(&stranger).unwrap();
        let stranger_path = stranger.join(format!("{ID}.output"));
        std::fs::write(&stranger_path, b"x").unwrap();
        rejected(&v, &stranger_path, ID);
    }

    // ── tail reads ──────────────────────────────────────────────────────────

    #[test]
    fn the_tail_window_is_eight_kibibytes() {
        assert_eq!(TAIL_MAX_BYTES, 8 * 1024);
    }

    #[test]
    fn a_small_file_is_returned_whole() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"short");
        let tail = rig.validator().read_tail(&path, ID, TAIL_MAX_BYTES).unwrap();
        assert_eq!((tail.bytes.as_slice(), tail.total_bytes), (&b"short"[..], 5));
    }

    #[test]
    fn an_empty_file_reads_as_empty() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"");
        let tail = rig.validator().read_tail(&path, ID, TAIL_MAX_BYTES).unwrap();
        assert!(tail.bytes.is_empty());
        assert_eq!(tail.total_bytes, 0);
    }

    #[test]
    fn a_file_of_exactly_the_window_is_returned_whole() {
        let rig = rig();
        let content = vec![b'q'; TAIL_MAX_BYTES];
        let path = rig.write(&format!("{ID}.output"), &content);
        let tail = rig.validator().read_tail(&path, ID, TAIL_MAX_BYTES).unwrap();
        assert_eq!(tail.bytes, content);
        assert_eq!(tail.total_bytes, TAIL_MAX_BYTES as u64);
    }

    #[test]
    fn a_big_file_yields_only_its_last_eight_kibibytes_and_the_true_total() {
        let rig = rig();
        let content: Vec<u8> = (0..20_000u32).map(|i| b'a' + (i % 26) as u8).collect();
        let path = rig.write(&format!("{ID}.output"), &content);

        let tail = rig.validator().read_tail(&path, ID, TAIL_MAX_BYTES).unwrap();

        assert_eq!(tail.total_bytes, 20_000);
        assert_eq!(tail.bytes.len(), TAIL_MAX_BYTES);
        assert_eq!(tail.bytes, content[20_000 - TAIL_MAX_BYTES..]);
    }

    #[test]
    fn a_smaller_requested_window_is_honoured() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"0123456789");
        let tail = rig.validator().read_tail(&path, ID, 4).unwrap();
        assert_eq!(tail.bytes, b"6789");
        assert_eq!(tail.total_bytes, 10);
    }

    #[test]
    fn the_tail_never_starts_in_the_middle_of_a_character() {
        let rig = rig();
        let content = "\u{e9}".repeat(5_000); // 10_000 bytes, two per character
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());

        // 8191 makes the cut land on a continuation byte.
        let tail = rig.validator().read_tail(&path, ID, 8191).unwrap();

        assert_eq!(tail.total_bytes, 10_000);
        let text = String::from_utf8(tail.bytes.clone()).expect("valid UTF-8 from the first byte");
        assert!(text.starts_with('\u{e9}'));
        assert!(tail.bytes.len() <= 8191);
        assert!(tail.bytes.len() >= 8191 - 3);
    }

    #[test]
    fn a_tail_cut_through_any_character_width_is_valid_utf8_and_a_suffix() {
        let rig = rig();
        let content = "a\u{e9}\u{20ac}\u{1f600}".repeat(30);
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());
        let v = rig.validator();
        for window in 1..=content.len() {
            let tail = v.read_tail(&path, ID, window).unwrap();
            assert!(tail.bytes.len() <= window, "window {window}");
            let text = std::str::from_utf8(&tail.bytes)
                .unwrap_or_else(|e| panic!("window {window}: {e}"));
            assert!(content.ends_with(text), "window {window}");
            assert!(tail.bytes.len() + 3 >= window.min(content.len()), "window {window} dropped too much");
        }
    }

    #[test]
    fn invisible_and_bidi_characters_are_removed_wherever_they_sit() {
        let table: &[(char, &str)] = &[
            ('\u{202E}', "right-to-left override"),
            ('\u{202A}', "LRE"),
            ('\u{202B}', "RLE"),
            ('\u{202C}', "PDF"),
            ('\u{202D}', "LRO"),
            ('\u{2066}', "LRI"),
            ('\u{2067}', "RLI"),
            ('\u{2068}', "FSI"),
            ('\u{2069}', "PDI"),
            ('\u{200B}', "zero width space"),
            ('\u{200C}', "ZWNJ"),
            ('\u{200D}', "ZWJ"),
            ('\u{200E}', "LRM"),
            ('\u{200F}', "RLM"),
            ('\u{2060}', "word joiner"),
            ('\u{FEFF}', "BOM"),
            ('\u{00AD}', "soft hyphen"),
            ('\u{061C}', "arabic letter mark"),
            ('\u{180E}', "mongolian vowel separator"),
            ('\u{FE0F}', "variation selector 16"),
            ('\u{E0041}', "tag latin capital a"),
            ('\u{E0100}', "variation selector supplement"),
            ('\u{2800}', "braille blank"),
            ('\u{3164}', "hangul filler"),
            ('\u{FFA0}', "halfwidth hangul filler"),
            ('\u{2028}', "line separator"),
            ('\u{2029}', "paragraph separator"),
        ];
        for (c, name) in table {
            assert_eq!(sanitize(format!("a{c}b").as_bytes()), "ab", "U+{:04X} {name} must be removed", *c as u32);
            assert_eq!(sanitize(format!("{c}{c}ab{c}").as_bytes()), "ab", "U+{:04X} {name} at the edges", *c as u32);
        }
    }

    #[test]
    fn a_reversed_filename_trick_shows_its_true_text() {
        assert_eq!(sanitize("report\u{202E}fdp.exe".as_bytes()), "reportfdp.exe");
    }

    #[test]
    fn ordinary_text_in_any_script_and_layout_whitespace_is_untouched() {
        let text = "plain text\n\tindented caf\u{e9} na\u{ef}ve \u{65e5}\u{672c}\u{8a9e} \u{4e2d}\u{6587} \u{1f600} \u{2764} done\n";
        assert_eq!(sanitize(text.as_bytes()), text);
    }

    #[test]
    fn escape_sequences_are_still_removed_next_to_invisible_characters() {
        assert_eq!(sanitize("a\u{202E}\x1b[31mb\x1b[0m\u{200B}\x1b]0;t\x07c".as_bytes()), "abc");
    }

    #[test]
    fn a_preview_line_built_from_hostile_output_is_clean() {
        let out = sanitize("building\n\u{202E}done \u{200B}ok\u{E0041}\n\n".as_bytes());
        assert_eq!(last_nonempty_line(&out).as_deref(), Some("done ok"));
    }

    // ── root_of_output_path ─────────────────────────────────────────────────

    #[test]
    fn the_root_is_four_levels_above_a_cli_output_path() {
        assert_eq!(
            root_of_output_path(Path::new("/private/tmp/claude-501/-Users-x-repo/sess-1/tasks/b7k2m9x1a.output")),
            Some(PathBuf::from("/private/tmp/claude-501"))
        );
        assert_eq!(
            root_of_output_path(Path::new("/t/claude-501/-repo/sess/tasks/b1.output")),
            Some(PathBuf::from("/t/claude-501"))
        );
    }

    #[test]
    fn a_path_whose_directory_is_not_tasks_has_no_root() {
        assert_eq!(root_of_output_path(Path::new("/t/claude-501/-repo/sess/out/b1.output")), None);
        assert_eq!(root_of_output_path(Path::new("/t/claude-501/-repo/sess/b1.output")), None);
    }

    #[test]
    fn a_path_too_shallow_to_have_the_shape_has_no_root_and_never_the_filesystem_root() {
        assert_eq!(root_of_output_path(Path::new("/tasks/b1.output")), None);
        assert_eq!(root_of_output_path(Path::new("/a/tasks/b1.output")), None);
        assert_eq!(root_of_output_path(Path::new("/a/b/tasks/b1.output")), None, "that would be `/`");
        assert_eq!(root_of_output_path(Path::new("tasks/b1.output")), None);
        assert_eq!(root_of_output_path(Path::new("b1.output")), None);
        assert_eq!(root_of_output_path(Path::new("")), None);
    }

    // ── learnable_root ──────────────────────────────────────────────────────

    #[test]
    fn a_cli_path_under_its_claude_uid_folder_in_tmp_teaches_that_folder() {
        assert_eq!(
            learnable_root(Path::new("/private/tmp/claude-502/-Users-h-repo/sess/tasks/b1.output"), 502),
            Some(PathBuf::from("/private/tmp/claude-502"))
        );
        assert_eq!(
            learnable_root(Path::new("/tmp/claude-502/-Users-h-repo/sess/tasks/b1.output"), 502),
            Some(PathBuf::from("/tmp/claude-502"))
        );
    }

    #[test]
    fn a_path_that_is_not_in_the_cli_tmp_root_for_this_user_teaches_nothing() {
        let cases: &[(&str, u32)] = &[
            ("/Users/h/Documents/x/sess/tasks/t1.output", 502),
            ("/Users/h/Documents/-work-repo/sess-1/tasks/t1.output", 502),
            ("/private/tmp/claude-501/-Users-h-repo/sess/tasks/b1.output", 502), // someone else's
            ("/tmp/claude-501/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/var/folders/ab/T/claude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/sub/claude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/private/tmp/sub/claude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/claude-502x/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/xclaude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/claude-/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/claude/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/claude-0502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/elsewhere/claude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/claude-502/-Users-h-repo/sess/tasks/b1.output", 502),
            ("/tmp/claude-502/-Users-h-repo/sess/out/b1.output", 502), // not a tasks folder
            ("tmp/claude-502/-Users-h-repo/sess/tasks/b1.output", 502), // relative
        ];
        for (path, uid) in cases {
            assert_eq!(learnable_root(Path::new(path), *uid), None, "{path} as uid {uid}");
        }
    }

    #[test]
    fn a_path_that_climbs_out_of_the_tmp_root_teaches_nothing() {
        let cases = [
            "/tmp/claude-502/../../Users/h/x/sess/tasks/b.output",
            "/tmp/claude-502/-repo/../sess/tasks/b.output",
            "/tmp/../Users/claude-502/-repo/sess/tasks/b.output",
            "/tmp/claude-502/-repo/sess/tasks/../tasks/b.output",
        ];
        for path in cases {
            assert_eq!(learnable_root(Path::new(path), 502), None, "{path}");
        }
    }

    #[test]
    fn the_real_default_root_for_this_user_is_learnable() {
        let uid = current_uid();
        let path = format!("/tmp/claude-{uid}/-work-repo/sess-1/tasks/t1.output");
        assert_eq!(learnable_root(Path::new(&path), uid), Some(PathBuf::from(format!("/tmp/claude-{uid}"))));
    }

    #[test]
    fn task_id_validity_follows_the_documented_pattern() {
        assert!(is_valid_task_id("b7k2m9x1a"));
        assert!(is_valid_task_id("A_b-9"));
        assert!(is_valid_task_id(&"x".repeat(64)));
        assert!(!is_valid_task_id(""));
        assert!(!is_valid_task_id(&"x".repeat(65)));
        assert!(!is_valid_task_id("a/b"));
        assert!(!is_valid_task_id("a.b"));
        assert!(!is_valid_task_id("a b"));
        assert!(!is_valid_task_id("\u{e9}"));
    }

    // ── ranged reads (BA1) ──────────────────────────────────────────────────

    const MIB: usize = 1024 * 1024;

    fn range(v: &OutputFileValidator, path: &Path, offset: Option<u64>, max: usize) -> RangeRead {
        v.read_range(path, ID, offset, max)
            .unwrap_or_else(|e| panic!("read_range(offset {offset:?}, max {max}) failed: {e:?}"))
    }

    /// Read a whole finished file the way a viewer does: from offset 0, each request starting
    /// where the previous range ended. Asserts the ranges are contiguous and always make progress.
    fn read_all(v: &OutputFileValidator, path: &Path, max: usize) -> Vec<RangeRead> {
        let mut out: Vec<RangeRead> = Vec::new();
        let mut offset = 0u64;
        for _ in 0..1_000_000 {
            let r = v
                .read_range_of(path, ID, Some(offset), max, true)
                .unwrap_or_else(|e| panic!("read_range_of(offset {offset}, max {max}) failed: {e:?}"));
            assert_eq!(r.start, offset, "a range must start where the previous one ended (max {max})");
            assert_eq!(r.end - r.start, r.bytes.len() as u64, "end - start is the number of bytes (max {max})");
            assert!(r.bytes.len() <= max, "{} bytes for a window of {max}", r.bytes.len());
            assert!(
                std::str::from_utf8(&r.bytes).is_ok(),
                "a range of valid UTF-8 text must be valid UTF-8 (max {max}, start {})",
                r.start
            );
            let done = r.end >= r.total_bytes;
            if !done {
                assert!(r.end > r.start, "no progress at offset {offset} of {} (max {max})", r.total_bytes);
            }
            offset = r.end;
            out.push(r);
            if done {
                return out;
            }
        }
        panic!("the reader never reached the end of the file (max {max})");
    }

    fn sanitised_join(ranges: &[RangeRead]) -> String {
        ranges.iter().map(|r| sanitize(&r.bytes)).collect()
    }

    /// A log of coloured, titled, hyperlinked and progress-barred lines, exactly `len` bytes long.
    fn escaped_log_of(len: usize) -> Vec<u8> {
        let mut out = Vec::with_capacity(len);
        let mut i = 0usize;
        while out.len() + 400 < len {
            let line = match i % 7 {
                0 => format!("\x1b[1;3{}mline {i}: caf\u{e9} \u{2713}\x1b[0m\n", i % 8),
                1 => format!("\x1b]0;title {i}\x07progress {i}%\r{}%\n", i + 1),
                2 => format!("\x1b]8;;http://example.test/{i}\x1b\\link {i}\x1b]8;;\x1b\\ \u{1f600}\n"),
                3 => format!("plain {i} {}\n", "x".repeat(i % 97)),
                4 => format!("\x1b[2K\x1b[1G{i}\u{9b}31m red\n"),
                5 => format!("\u{9d}0;t{i}\x07tab\there {i}\n"),
                _ => format!("\x1b[?25l{i}\n"),
            };
            out.extend_from_slice(line.as_bytes());
            i += 1;
        }
        out.resize(len, b'.');
        out
    }

    #[test]
    fn ranges_read_in_one_mebibyte_requests_from_offset_zero_reassemble_the_sanitised_whole_of_a_two_mebibyte_file() {
        let rig = rig();
        let content = escaped_log_of(2 * MIB);
        assert_eq!(content.len(), 2 * MIB);
        let path = rig.write(&format!("{ID}.output"), &content);

        let ranges = read_all(&rig.validator(), &path, MIB);

        assert!(ranges.len() >= 2, "a 2 MiB file does not fit one 1 MiB request: {} range(s)", ranges.len());
        assert_eq!(ranges[0].start, 0);
        for pair in ranges.windows(2) {
            assert_eq!(pair[0].end, pair[1].start, "contiguous [start, end) ranges");
        }
        assert_eq!(ranges.last().unwrap().end, (2 * MIB) as u64, "the last range ends at the end of the file");
        for r in &ranges {
            assert_eq!(r.total_bytes, (2 * MIB) as u64);
        }
        let text = sanitised_join(&ranges);
        assert!(!text.contains('\u{1b}'), "no escape byte survives");
        assert_eq!(text, sanitize(&content), "the ranges, sanitised one by one, join to the sanitised whole");
        let raw: Vec<u8> = ranges.iter().flat_map(|r| r.bytes.iter().copied()).collect();
        assert_eq!(raw, content, "the ranges tile the file exactly");
    }

    /// Things a window must never cut through, each followed and preceded by plain text.
    const HOSTILE_CONSTRUCTS: &[(&str, &str)] = &[
        ("a two-byte scalar", "\u{e9}"),
        ("a three-byte scalar", "\u{2713}"),
        ("a four-byte scalar", "\u{1f600}"),
        ("a colour CSI", "\x1b[1;31m"),
        ("a private-mode CSI", "\x1b[?25l"),
        ("an OSC ended by BEL", "\x1b]0;window title\x07"),
        ("an OSC ended by ST", "\x1b]8;;http://example.test/a\x1b\\"),
        ("a DCS ended by ST", "\x1bPq#0;2;0;0;0\x1b\\"),
        ("an 8-bit CSI", "\u{9b}31m"),
        ("an 8-bit OSC", "\u{9d}0;title\x07"),
        ("a charset selection", "\x1b(B"),
    ];

    #[test]
    fn a_window_of_any_size_never_ends_inside_a_scalar_or_an_escape_sequence() {
        for (what, construct) in HOSTILE_CONSTRUCTS {
            let whole = format!("aaaa{construct}bbbb");
            let rig = rig();
            let path = rig.write(&format!("{ID}.output"), whole.as_bytes());
            let expected = sanitize(whole.as_bytes());
            for max in 4..=whole.len() + 2 {
                let ranges = read_all(&rig.validator(), &path, max);
                // Every window that can hold the construct whole (and starts where a read does)
                // reproduces the sanitised file: nothing was cut through.
                if max >= construct.len() {
                    assert_eq!(
                        sanitised_join(&ranges),
                        expected,
                        "{what}: window {max} cut through it; ranges {:?}",
                        ranges.iter().map(|r| (r.start, r.end)).collect::<Vec<_>>()
                    );
                }
                for r in &ranges {
                    assert!(
                        !sanitize(&r.bytes).contains('\u{1b}'),
                        "{what}: window {max}: escape byte in sanitised text"
                    );
                }
            }
        }
    }

    #[test]
    fn a_window_never_ends_inside_a_string_sequence_that_holds_an_eight_bit_introducer() {
        // The U+009B inside the title is the last introducer in a window cut after it, but the
        // sequence that is unfinished is the OSC around it.
        let whole = "aaaa\x1b]0;ti\u{9b}tle\x07bbbb";
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), whole.as_bytes());
        let expected = sanitize(whole.as_bytes());
        assert_eq!(expected, "aaaabbbb", "control: the whole title is swallowed");
        // Every window that can hold the whole title sequence, wherever the cuts before it fall.
        for max in "\x1b]0;ti\u{9b}tle\x07".len()..=whole.len() + 2 {
            let ranges = read_all(&rig.validator(), &path, max);
            assert_eq!(
                sanitised_join(&ranges),
                expected,
                "window {max}; ranges {:?}",
                ranges.iter().map(|r| (r.start, r.end)).collect::<Vec<_>>()
            );
        }
    }

    #[test]
    fn a_line_longer_than_the_window_is_split_inside_the_window_and_still_reassembles() {
        let rig = rig();
        let long = "x".repeat(10 * 1024);
        let content = format!("{long}\ntail\n");
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());

        let first = range(&rig.validator(), &path, Some(0), 4096);

        assert_eq!((first.start, first.end), (0, 4096), "an ASCII line with no newline in the window ends where the window does");
        assert_eq!(first.bytes.len(), 4096);
        let ranges = read_all(&rig.validator(), &path, 4096);
        assert_eq!(ranges.iter().flat_map(|r| r.bytes.iter().copied()).collect::<Vec<_>>(), content.as_bytes());
        assert_eq!(sanitised_join(&ranges), content);
    }

    #[test]
    fn a_long_line_of_multi_byte_characters_is_cut_between_characters() {
        let rig = rig();
        let content = "\u{e9}".repeat(5_000);
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());

        let first = range(&rig.validator(), &path, Some(0), 4097);

        assert_eq!(first.end, 4096, "4097 would cut an e-acute in half");
        assert_eq!(sanitised_join(&read_all(&rig.validator(), &path, 4097)), content);
    }

    #[test]
    fn a_long_line_of_mixed_escapes_and_scalars_reassembles_for_every_nearby_window_size() {
        const PIECES: [&str; 9] = [
            "\x1b[1;31m", "\x1b]0;t\x07", "\u{e9}", "\u{2713}", "\u{1f600}", "\x1b]8;;u\x1b\\", "\u{9b}31m", "\u{9d}0;t\x07", "text ",
        ];
        let mut rng = Prng(7);
        let mut line = String::new();
        while line.len() < 64 * 1024 {
            line.push_str(PIECES[rng.below(PIECES.len())]);
        }
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), line.as_bytes());
        let expected = sanitize(line.as_bytes());

        for max in 4096..4136 {
            let ranges = read_all(&rig.validator(), &path, max);
            assert_eq!(sanitised_join(&ranges), expected, "window {max}");
        }
    }

    #[test]
    fn a_long_escaped_line_over_a_one_mebibyte_window_reassembles() {
        const PIECES: [&str; 8] = ["\x1b[1;31m", "\x1b]0;t\x07", "\u{e9}", "\u{2713}", "\u{1f600}", "\x1b]8;;u\x1b\\", "\x1b[0m", "word "];
        let mut rng = Prng(99);
        let mut line = String::new();
        while line.len() < MIB + MIB / 2 {
            line.push_str(PIECES[rng.below(PIECES.len())]);
        }
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), line.as_bytes());

        let ranges = read_all(&rig.validator(), &path, MIB);

        assert!(ranges.len() >= 2);
        assert_eq!(sanitised_join(&ranges), sanitize(line.as_bytes()));
    }

    #[test]
    fn random_escape_heavy_text_reassembles_whatever_the_window() {
        // Valid UTF-8 pieces only (lossy decoding of cut invalid bytes legitimately differs), no
        // `\r` (carriage returns collapse per line, and a line may be split), newline-free runs.
        const PIECES: &[&str] = &[
            "\x1b", "\x1b[", "\x1b]", "\x1bP", "\x1b_", "\x1b^", "\x1bX", "\x1b(", "\x1b\\", "\x07", "\t", "[", "]", ";", "31", "0",
            "m", "H", "abc ", " ", "\u{e9}", "\u{2713}", "\u{1f600}", "\x7f", "\x1b[0m", "\x1b]0;t\x07",
        ];
        let rig = rig();
        let mut rng = Prng(0xC0FFEE);
        for round in 0..30 {
            let mut text = String::new();
            let target = 8_000 + rng.below(8_000);
            while text.len() < target {
                text.push_str(PIECES[rng.below(PIECES.len())]);
                // A line break now and then so some windows have one and some do not.
                if rng.below(200) == 0 {
                    text.push('\n');
                }
            }
            let path = rig.write(&format!("{ID}.output"), text.as_bytes());
            let max = 4096 + rng.below(1024);
            let ranges = read_all(&rig.validator(), &path, max);
            assert_eq!(sanitised_join(&ranges), sanitize(text.as_bytes()), "round {round}, window {max}, text {text:?}");
        }
    }

    #[test]
    fn a_tail_read_holds_at_most_the_window_ends_at_the_end_and_starts_on_a_line() {
        let rig = rig();
        let content: String = (0..20_000).map(|i| format!("line {i:05}\n")).collect();
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());

        let r = range(&rig.validator(), &path, None, 4096);

        assert!(r.bytes.len() <= 4096, "{} bytes", r.bytes.len());
        assert_eq!(r.end, content.len() as u64, "a tail ends at the end of the file");
        assert_eq!(r.total_bytes, content.len() as u64);
        assert!(r.start > 0);
        assert_eq!(content.as_bytes()[r.start as usize - 1], b'\n', "a tail starts right after a newline");
        assert_eq!(r.bytes, content.as_bytes()[r.start as usize..], "the bytes are the file's, start to end");
        assert!(String::from_utf8(r.bytes).unwrap().starts_with("line "), "no half line at the top");
    }

    #[test]
    fn a_tail_of_a_file_smaller_than_the_window_is_the_whole_file() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"one\ntwo\nthree");

        let r = range(&rig.validator(), &path, None, 4096);

        assert_eq!((r.start, r.end, r.total_bytes), (0, 13, 13));
        assert_eq!(r.bytes, b"one\ntwo\nthree", "the last line needs no newline when it is the end of the file");
    }

    #[test]
    fn a_tail_of_a_file_with_no_newline_in_its_window_still_ends_at_the_end_and_starts_on_a_scalar() {
        let rig = rig();
        let content = "\u{e9}".repeat(5_000);
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());

        for max in [4096usize, 4097, 4099] {
            let r = range(&rig.validator(), &path, None, max);
            assert_eq!(r.end, content.len() as u64, "window {max}");
            assert!(r.bytes.len() <= max);
            assert!(!r.bytes.is_empty(), "window {max}: a window with no newline is still returned");
            assert_eq!(r.start % 2, 0, "window {max}: starts between two e-acutes");
            assert!(String::from_utf8(r.bytes).is_ok());
        }
    }

    #[test]
    fn a_tail_of_an_empty_file_is_empty() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"");
        let r = range(&rig.validator(), &path, None, 4096);
        assert_eq!((r.start, r.end, r.total_bytes, r.bytes.len()), (0, 0, 0, 0));
    }

    #[test]
    fn a_read_past_the_end_is_an_empty_range_at_the_end() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"0123456789");
        for offset in [10u64, 11, 4096, u64::MAX] {
            let r = range(&rig.validator(), &path, Some(offset), 4096);
            assert_eq!((r.start, r.end, r.total_bytes), (10, 10, 10), "offset {offset}");
            assert!(r.bytes.is_empty(), "offset {offset}");
        }
    }

    #[test]
    fn an_empty_file_reads_as_an_empty_range_from_any_offset() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"");
        for offset in [0u64, 1, 100] {
            let r = range(&rig.validator(), &path, Some(offset), 4096);
            assert_eq!((r.start, r.end, r.total_bytes, r.bytes.len()), (0, 0, 0, 0), "offset {offset}");
        }
    }

    #[test]
    fn an_offset_inside_a_scalar_starts_at_the_next_scalar() {
        let rig = rig();
        // a(0) e-acute(1,2) check(3,4,5) b(6) smiley(7..=10) c(11)
        let content = "a\u{e9}\u{2713}b\u{1f600}c";
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());
        let v = rig.validator();

        for (offset, start, text) in [
            (0u64, 0u64, content),
            (1, 1, "\u{e9}\u{2713}b\u{1f600}c"),
            (2, 3, "\u{2713}b\u{1f600}c"),
            (3, 3, "\u{2713}b\u{1f600}c"),
            (4, 6, "b\u{1f600}c"),
            (5, 6, "b\u{1f600}c"),
            (6, 6, "b\u{1f600}c"),
            (8, 11, "c"),
            (9, 11, "c"),
            (10, 11, "c"),
        ] {
            let r = range(&v, &path, Some(offset), 4096);
            assert_eq!(r.start, start, "offset {offset}");
            assert_eq!(String::from_utf8(r.bytes).unwrap(), text, "offset {offset}");
            assert_eq!(r.end, content.len() as u64);
        }
    }

    #[test]
    fn a_reader_that_starts_inside_a_scalar_with_the_smallest_window_still_reaches_the_end() {
        let rig = rig();
        let content = "\u{1f600}".repeat(10);
        let path = rig.write(&format!("{ID}.output"), content.as_bytes());
        let v = rig.validator();

        let first = range(&v, &path, Some(2), 4);
        assert_eq!(first.start, 4, "the rest of the first smiley is skipped");
        assert!(first.end >= first.start);

        let mut offset = first.end;
        let mut text = sanitize(&first.bytes);
        while offset < content.len() as u64 {
            let r = range(&v, &path, Some(offset), 4);
            assert!(r.end > offset, "stuck at {offset}");
            text.push_str(&sanitize(&r.bytes));
            offset = r.end;
        }
        assert_eq!(text, "\u{1f600}".repeat(9), "every smiley after the cut one, once");
    }

    #[test]
    fn the_next_request_after_growth_returns_exactly_the_appended_part() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"one\ntwo\n");
        let v = rig.validator();
        let first = range(&v, &path, Some(0), 4096);
        assert_eq!((first.end, first.total_bytes), (8, 8));

        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        std::io::Write::write_all(&mut file, b"three\nfour\n").unwrap();
        let second = range(&v, &path, Some(first.end), 4096);

        assert_eq!(second.bytes, b"three\nfour\n");
        assert_eq!((second.start, second.end, second.total_bytes), (8, 19, 19));
    }

    #[test]
    fn a_line_still_being_written_is_returned_as_far_as_it_goes_and_continued_by_the_next_request() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"done\nhalf");
        let v = rig.validator();
        let first = range(&v, &path, Some(0), 4096);
        assert_eq!(first.bytes, b"done\nhalf", "the end of the file needs no newline");

        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        std::io::Write::write_all(&mut file, b" a line\n").unwrap();
        let second = range(&v, &path, Some(first.end), 4096);

        assert_eq!(second.bytes, b" a line\n");
        assert_eq!(sanitized_text(&[&first, &second]), "done\nhalf a line\n");
    }

    fn sanitized_text(ranges: &[&RangeRead]) -> String {
        ranges.iter().map(|r| sanitize(&r.bytes)).collect()
    }

    #[test]
    fn a_scalar_cut_in_half_by_the_end_of_a_growing_file_is_left_for_the_next_request() {
        let rig = rig();
        let bytes = "ab\u{e9}c\n".as_bytes();
        let path = rig.write(&format!("{ID}.output"), &bytes[..3]);
        let v = rig.validator();

        let first = range(&v, &path, Some(0), 4096);
        assert_eq!((first.bytes.as_slice(), first.end), (&b"ab"[..], 2), "the half scalar is not returned");

        std::fs::write(&path, bytes).unwrap();
        let second = range(&v, &path, Some(first.end), 4096);

        assert_eq!(second.bytes, "\u{e9}c\n".as_bytes());
        assert_eq!(sanitized_text(&[&first, &second]), "ab\u{e9}c\n");
    }

    #[test]
    fn an_escape_sequence_cut_by_the_end_of_a_growing_file_is_left_for_the_next_request() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"ok\n\x1b[3");
        let v = rig.validator();

        let first = range(&v, &path, Some(0), 4096);
        assert_eq!((first.bytes.as_slice(), first.end), (&b"ok\n"[..], 3), "the unfinished escape is not returned");

        std::fs::write(&path, b"ok\n\x1b[31mred\n").unwrap();
        let second = range(&v, &path, Some(first.end), 4096);

        assert_eq!(sanitized_text(&[&first, &second]), "ok\nred\n", "the colour code was never shown as `1mred`");
    }

    #[test]
    fn a_range_that_is_only_the_start_of_an_escape_at_the_end_of_a_growing_file_is_not_consumed() {
        // The reader polls from where it stopped: the writer's escape sequence is cut by the end
        // of the file, and the range would be nothing but that fragment.
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"\x1b[3");
        let v = rig.validator();

        let first = range(&v, &path, Some(0), 4096);
        assert_eq!(first.end, 0, "nothing safe to return yet: the range stays empty ({:?})", first.bytes);

        std::fs::write(&path, b"\x1b[31mred\n").unwrap();
        let second = range(&v, &path, Some(first.end), 4096);
        assert_eq!(sanitized_text(&[&first, &second]), "red\n");
    }

    #[test]
    fn a_finished_file_is_taken_whole_even_when_it_ends_in_half_an_escape_or_half_a_scalar() {
        // A running task's file may still grow, so the end of it holds back what is unfinished;
        // an ended task's file never will, so nothing may be left behind unread.
        let rig = rig();
        let v = rig.validator();
        for tail in [&b"\x1b[3"[..], &b"\x1b]0;title"[..], &"\u{e9}".as_bytes()[..1]] {
            let mut content = b"done\n".to_vec();
            content.extend_from_slice(tail);
            let path = rig.write(&format!("{ID}.output"), &content);

            let running = range(&v, &path, Some(0), 4096);
            assert!(running.end < content.len() as u64, "a file that may grow keeps {tail:?} back");

            let ended = v.read_range_of(&path, ID, Some(0), 4096, true).unwrap();
            assert_eq!((ended.start, ended.end), (0, content.len() as u64), "an ended file ends at its end");
            assert_eq!(ended.total_bytes, content.len() as u64);
            assert!(!sanitize(&ended.bytes).contains('\u{1b}'));
        }
    }

    #[test]
    fn a_tail_whose_window_is_inside_one_long_last_line_still_returns_that_line() {
        let rig = rig();
        let mut content = vec![b'x'; 10 * 1024];
        content.push(b'\n');
        let path = rig.write(&format!("{ID}.output"), &content);

        let tail = range(&rig.validator(), &path, None, 4096);
        assert!(!tail.bytes.is_empty(), "the window is all one line: it is returned, not skipped");
        assert_eq!(tail.end, content.len() as u64);
        assert!(tail.bytes.len() <= 4096);
    }

    #[test]
    fn reading_while_another_thread_appends_never_loses_or_repeats_a_byte() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"");
        let v = rig.validator();
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let writer = {
            let (path, done) = (path.clone(), Arc::clone(&done));
            std::thread::spawn(move || {
                let mut file = std::fs::OpenOptions::new().append(true).open(path).unwrap();
                for i in 0..3_000 {
                    let line = format!("\x1b[3{}mline {i} caf\u{e9} \u{2713}\x1b[0m\n", i % 8);
                    std::io::Write::write_all(&mut file, line.as_bytes()).unwrap();
                    if i % 50 == 0 {
                        std::thread::yield_now();
                    }
                }
                done.store(true, Ordering::SeqCst);
            })
        };

        let mut offset = 0u64;
        let mut raw: Vec<u8> = Vec::new();
        let mut after_done = 0;
        loop {
            let finished = done.load(Ordering::SeqCst);
            let r = range(&v, &path, Some(offset), 4096);
            assert_eq!(r.start, offset);
            assert!(r.total_bytes >= r.end, "the reported size covers what was read: {} < {}", r.total_bytes, r.end);
            assert_eq!(r.end - r.start, r.bytes.len() as u64);
            offset = r.end;
            raw.extend_from_slice(&r.bytes);
            if finished && r.end >= r.total_bytes {
                after_done += 1;
                if after_done > 1 {
                    break;
                }
            }
        }
        writer.join().unwrap();

        assert_eq!(raw, std::fs::read(&path).unwrap(), "every appended byte arrived once, in order");
        assert!(String::from_utf8(raw).is_ok());
    }

    #[test]
    fn a_file_that_shrinks_between_requests_reads_as_an_empty_range_at_its_new_end() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"0123456789");
        let v = rig.validator();
        let first = range(&v, &path, Some(0), 4096);
        assert_eq!(first.end, 10);

        std::fs::write(&path, b"abc").unwrap();
        let second = range(&v, &path, Some(first.end), 4096);

        assert_eq!((second.start, second.end, second.total_bytes), (3, 3, 3));
    }

    // Every rejection below must come back as an error, with the file never read; the open counter
    // counts calls to `open` (a rejected path is still a call), so exactly one means "asked once,
    // refused, no second attempt".

    fn counted(rig: &Rig) -> (OutputFileValidator, Arc<AtomicUsize>) {
        let counter = Arc::new(AtomicUsize::new(0));
        (rig.validator().with_open_counter(Arc::clone(&counter)), counter)
    }

    #[test]
    fn a_ranged_read_of_a_file_outside_the_root_is_refused_and_its_content_never_returned() {
        let rig = rig();
        let outside = rig.outside().join(format!("{ID}.output"));
        std::fs::write(&outside, b"SECRET-OUTPUT-OUTSIDE\n").unwrap();
        let (v, opens) = counted(&rig);

        let result = v.read_range(&outside, ID, Some(0), 4096);

        assert!(result.is_err(), "{result:?}");
        assert_eq!(opens.load(Ordering::SeqCst), 1);
        assert!(!format!("{result:?}").contains("SECRET-OUTPUT"));
    }

    #[test]
    fn a_ranged_read_of_a_symlink_is_refused_even_into_the_root() {
        let rig = rig();
        let target = rig.write("real.txt", b"SECRET-OUTPUT-LINKED\n");
        let link = rig.tasks.join(format!("{ID}.output"));
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let (v, opens) = counted(&rig);

        assert!(v.read_range(&link, ID, Some(0), 4096).is_err());
        assert!(v.read_range(&link, ID, None, 4096).is_err());
        assert_eq!(opens.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_ranged_read_with_a_file_name_that_is_not_the_task_id_is_refused() {
        let rig = rig();
        let path = rig.write("other.output", b"SECRET-OUTPUT-NAME\n");
        let (v, opens) = counted(&rig);

        assert!(v.read_range(&path, ID, Some(0), 4096).is_err());
        assert_eq!(opens.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_ranged_read_for_an_invalid_task_id_is_refused_even_though_the_file_exists() {
        let rig = rig();
        for bad in ["a/b", "..", "a.b", "", &"x".repeat(65)] {
            let path = rig.write(&format!("{bad}.output").replace('/', "_"), b"SECRET-OUTPUT-ID\n");
            let (v, opens) = counted(&rig);
            assert!(v.read_range(&path, bad, Some(0), 4096).is_err(), "id {bad:?}");
            assert_eq!(opens.load(Ordering::SeqCst), 1, "id {bad:?}");
        }
    }

    #[test]
    fn a_ranged_read_of_a_directory_is_refused() {
        let rig = rig();
        let path = rig.tasks.join(format!("{ID}.output"));
        std::fs::create_dir(&path).unwrap();
        let (v, opens) = counted(&rig);

        assert!(v.read_range(&path, ID, Some(0), 4096).is_err());
        assert_eq!(opens.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_ranged_read_of_a_named_pipe_is_refused_without_blocking() {
        let rig = rig();
        let path = rig.tasks.join(format!("{ID}.output"));
        let c_path = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path; mkfifo has no other preconditions.
        assert_eq!(unsafe { libc::mkfifo(c_path.as_ptr(), 0o600) }, 0);
        let (v, opens) = counted(&rig);
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(v.read_range(&path, ID, Some(0), 4096).is_err());
        });

        // A hang guard, not a timing assertion: a blocked `open` never answers.
        let refused = rx.recv_timeout(std::time::Duration::from_secs(30)).expect("the read of a FIFO blocked");

        assert!(refused);
        assert_eq!(opens.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_ranged_read_of_a_missing_file_is_an_error_after_one_open() {
        let rig = rig();
        let (v, opens) = counted(&rig);
        assert!(v.read_range(&rig.tasks.join(format!("{ID}.output")), ID, Some(0), 4096).is_err());
        assert_eq!(opens.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn every_successful_ranged_read_opens_the_file_once() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"hello\n");
        let (v, opens) = counted(&rig);
        range(&v, &path, Some(0), 4096);
        range(&v, &path, None, 4096);
        assert_eq!(opens.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_validator_without_a_counter_reads_normally() {
        let rig = rig();
        let path = rig.write(&format!("{ID}.output"), b"hello\n");
        assert_eq!(range(&rig.validator(), &path, Some(0), 4096).bytes, b"hello\n");
    }

    // ── the largest frame a read can produce ─────────────────────────────────

    fn result_frame(text: String, bytes: u64) -> Vec<u8> {
        serde_json::to_vec(&crate::ipc::protocol::ServerMsg::SessionTaskOutputResult {
            request_id: "request-0000000000".into(),
            tag: "a-focus-tag".into(),
            task_id: ID.into(),
            outcome: crate::ipc::protocol::TaskOutputOutcome::Ok,
            text,
            start_offset: 0,
            end_offset: bytes,
            total_bytes: bytes,
            source: Some(crate::ipc::protocol::TaskOutputSource::File),
            message: None,
        })
        .unwrap()
    }

    #[test]
    fn the_result_frame_of_a_one_mebibyte_read_stays_under_the_frame_cap_whatever_the_bytes() {
        let rig = rig();
        let worst: [(&str, Vec<u8>); 7] = [
            ("invalid 0xFF bytes (each becomes U+FFFD)", vec![0xFF; MIB]),
            ("stray continuation bytes", vec![0x80; MIB]),
            ("double quotes (each is escaped)", vec![b'"'; MIB]),
            ("backslashes (each is escaped)", vec![b'\\'; MIB]),
            ("newlines (each is escaped)", vec![b'\n'; MIB]),
            ("four-byte scalars", "\u{1f600}".repeat(MIB / 4).into_bytes()),
            ("alternating invalid bytes and quotes", (0..MIB).map(|i| if i % 2 == 0 { 0xFF } else { b'"' }).collect()),
        ];
        for (what, content) in worst {
            let path = rig.write(&format!("{ID}.output"), &content);
            let r = range(&rig.validator(), &path, Some(0), MIB);
            let text = sanitize(&r.bytes);

            let frame = result_frame(text, r.total_bytes);

            assert!(
                frame.len() < crate::ipc::protocol::MAX_FRAME_LEN,
                "{what}: a frame of {} bytes does not fit the {} byte cap",
                frame.len(),
                crate::ipc::protocol::MAX_FRAME_LEN
            );
        }
    }
}
