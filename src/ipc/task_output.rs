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
            '\u{9d}' => {
                if skip_string_body(&mut chars) {
                    skip_escape(&mut chars);
                }
            }
            '\n' | '\t' | '\r' => out.push(c),
            c if c.is_control() => {}
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
}
