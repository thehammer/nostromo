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
/// * Every other control character except `\n` and `\t` is dropped.
pub fn sanitize(input: &[u8]) -> String {
    let nuls = input.iter().filter(|&&b| b == 0).count();
    if !input.is_empty() && nuls * 100 > input.len() * BINARY_NUL_SHARE_PERCENT {
        return format!("[binary output: {} bytes]", input.len());
    }
    let text = String::from_utf8_lossy(input);
    let without_escapes = strip_escapes(&text);
    collapse_carriage_returns(&without_escapes)
}

/// Remove escape sequences and every control character except `\n`, `\t`
/// and `\r` (the last is resolved line by line afterwards).
fn strip_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => skip_escape(&mut chars),
            '\u{9b}' => skip_csi_body(&mut chars),
            '\u{9d}' => skip_string_body(&mut chars),
            '\n' | '\t' | '\r' => out.push(c),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    out
}

/// After an `ESC`: consume the rest of the sequence.
fn skip_escape(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    match chars.peek().copied() {
        Some('[') => {
            chars.next();
            skip_csi_body(chars);
        }
        // OSC, DCS, SOS, PM, APC: strings that run to a terminator.
        Some(']') | Some('P') | Some('X') | Some('^') | Some('_') => {
            chars.next();
            skip_string_body(chars);
        }
        // nF sequences: intermediates 0x20-0x2F, then one final 0x30-0x7E.
        Some(c) if ('\u{20}'..='\u{2f}').contains(&c) => {
            while chars.next_if(|c| ('\u{20}'..='\u{2f}').contains(c)).is_some() {}
            chars.next_if(|c| ('\u{30}'..='\u{7e}').contains(c));
        }
        // Fe/Fp/Fs: a single final character.
        Some(c) if ('\u{30}'..='\u{7e}').contains(&c) => {
            chars.next();
        }
        // A lone ESC before anything else (a newline, end of input, a
        // non-ASCII character): drop the ESC alone.
        _ => {}
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
/// BEL and ST are consumed; a newline is left for the caller.
fn skip_string_body(chars: &mut std::iter::Peekable<std::str::Chars<'_>>) {
    while let Some(&c) = chars.peek() {
        match c {
            '\u{07}' | '\u{9c}' => {
                chars.next();
                return;
            }
            '\u{1b}' => {
                chars.next();
                // ST is `ESC \`; any other ESC begins a new sequence, which
                // the caller handles, so stop without eating it.
                if chars.peek() == Some(&'\\') {
                    chars.next();
                } else {
                    // Re-handle the ESC we consumed: it ended this string.
                    skip_escape(chars);
                }
                return;
            }
            '\n' => return,
            _ => {
                chars.next();
            }
        }
    }
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
}

impl OutputFileValidator {
    /// A validator for the given tmp root (tests pass a temp directory).
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            roots: vec![root.into()],
            uid: current_uid(),
        }
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
        let (dir, name) = self.check_shape(path, task_id)?;
        open_nofollow(&dir.join(name)).map_err(OutputFileError::Unreadable).and_then(|file| {
            let meta = file.metadata().map_err(OutputFileError::Unreadable)?;
            if !meta.file_type().is_file() {
                return Err(OutputFileError::Rejected("not a regular file"));
            }
            if !self.owned_by_us(&meta) {
                return Err(OutputFileError::Rejected("not owned by the daemon's user"));
            }
            Ok(file)
        })
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

fn default_tmp_root() -> PathBuf {
    let base = if cfg!(target_os = "macos") { "/private/tmp" } else { "/tmp" };
    PathBuf::from(base).join(format!("claude-{}", current_uid()))
}

#[cfg(unix)]
fn current_uid() -> u32 {
    // SAFETY: geteuid has no preconditions and cannot fail.
    unsafe { libc::geteuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    0
}

#[cfg(unix)]
fn open_nofollow(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    // O_NONBLOCK: opening a FIFO that slipped in must not block the daemon.
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
}

#[cfg(not(unix))]
fn open_nofollow(path: &Path) -> std::io::Result<File> {
    File::open(path)
}
