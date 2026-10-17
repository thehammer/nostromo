//! Best-effort detector for PHI-shaped text and secrets in tracker text.
//!
//! Pure and reusable: [`scan`] returns where each match is and which
//! [`Class`] it belongs to, never the matched text itself, so nothing that
//! formats a [`Finding`] (logs, error responses, `Debug`) can echo a secret.
//!
//! This is a guard, not a compliance control. It misses names and free-text
//! clinical detail by design (see `docs/tracker-guard.md`). Its two measured
//! properties are the miss rate (`tests/fixtures/sensitive_text/positives.txt`)
//! and the false-alarm rate (`.../benign.txt`), asserted in
//! `tests/sensitive_text_corpus.rs`.
//!
//! Every pattern is anchored by code-level context checks (neighbouring
//! characters, Luhn, field validity) because the benign text this runs on is
//! full of look-alikes: Sentry ids, SHAs, UUIDs, order numbers, versions.
//! Matching is linear in the input (the `regex` crate guarantees it and the
//! context checks look at a bounded neighbourhood). Input over
//! [`MAX_SCAN_BYTES`] is not scanned: it yields one [`Class::Oversize`] finding.
//!
//! The patterns are ASCII-only and run on a *normalised view* of the text:
//! invisible characters (`data::work::is_invisible`: zero-width, bidi, tag
//! characters, soft hyphen) are dropped, and compatibility forms (fullwidth
//! letters and punctuation, any Unicode decimal digit, en dash and minus) are
//! folded to ASCII, and combining marks are removed. Finding offsets are
//! mapped back to the original text. A hidden character can sit INSIDE a value
//! (`219-<ZWSP>09-9999`) or stand in for a space (`SSN<ZWSP>219-09-9999`), so
//! when a hidden run could be either the text is scanned up to three times:
//! with hidden characters dropped, with those runs read as a space, and with
//! only those next to a word read as a space.
//!
//! Nothing here may panic on any input, and no panic message may carry text:
//! text is never sliced by assumed byte offsets (only `get`, regex offsets and
//! `char_indices`), and nothing unwraps or indexes into untrusted text.

use std::fmt;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

use crate::data::work::is_invisible;

/// What kind of sensitive text a [`Finding`] looks like.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Class {
    Ssn,
    Card,
    Dob,
    Mrn,
    Phone,
    PersonalEmail,
    Secret,
    /// The input is longer than [`MAX_SCAN_BYTES`]; it was not scanned.
    /// Callers treat it like any other finding (refuse or withhold).
    Oversize,
}

impl Class {
    /// Stable snake_case name used in tool responses and the scan binary.
    pub fn as_str(self) -> &'static str {
        match self {
            Class::Ssn => "ssn",
            Class::Card => "card",
            Class::Dob => "dob",
            Class::Mrn => "mrn",
            Class::Phone => "phone",
            Class::PersonalEmail => "personal_email",
            Class::Secret => "secret",
            Class::Oversize => "oversize",
        }
    }

    /// Inverse of [`Class::as_str`].
    pub fn from_str_name(name: &str) -> Option<Class> {
        Some(match name {
            "ssn" => Class::Ssn,
            "card" => Class::Card,
            "dob" => Class::Dob,
            "mrn" => Class::Mrn,
            "phone" => Class::Phone,
            "personal_email" => Class::PersonalEmail,
            "secret" => Class::Secret,
            "oversize" => Class::Oversize,
            _ => return None,
        })
    }
}

impl fmt::Display for Class {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One match: its class and byte range in the scanned text. Deliberately
/// carries no copy of the matched text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub class: Class,
    pub range: Range<usize>,
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} at bytes {}..{}",
            self.class, self.range.start, self.range.end
        )
    }
}

/// Guard settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardConfig {
    /// Email domains that are work addresses (and their subdomains), which
    /// are not reported as `personal_email`. Compared case-insensitively.
    pub work_email_domains: Vec<String>,
}

impl Default for GuardConfig {
    fn default() -> Self {
        Self {
            work_email_domains: vec![
                "carefeed.com".to_string(),
                "users.noreply.github.com".to_string(),
            ],
        }
    }
}

/// Longest text [`scan`] examines (1 MiB). Longer text yields a single
/// [`Class::Oversize`] finding covering the whole input.
pub const MAX_SCAN_BYTES: usize = 1 << 20;

/// All findings in `text`, ordered by start offset. Text over
/// [`MAX_SCAN_BYTES`] yields one [`Class::Oversize`] finding and is not
/// examined further (T0b caps agent fields well below this anyway).
#[must_use]
pub fn scan(text: &str, cfg: &GuardConfig) -> Vec<Finding> {
    if text.len() > MAX_SCAN_BYTES {
        return vec![Finding {
            class: Class::Oversize,
            range: 0..text.len(),
        }];
    }
    let mut out = if is_plain(text) {
        scan_plain(text, cfg)
    } else {
        scan_normalised(text, cfg)
    };
    out.sort_by(|a, b| {
        a.range
            .start
            .cmp(&b.range.start)
            .then(a.range.end.cmp(&b.range.end))
            .then((a.class as u8).cmp(&(b.class as u8)))
    });
    merge_overlapping(out)
}

/// Class of the earliest finding, if any.
#[must_use]
pub fn first_class(text: &str, cfg: &GuardConfig) -> Option<Class> {
    scan(text, cfg).first().map(|f| f.class)
}

/// Drops a finding that overlaps an earlier one of the same class (the two
/// views of a text with hidden characters, or two shapes matching one token).
/// Input is sorted by start; so is the output.
fn merge_overlapping(sorted: Vec<Finding>) -> Vec<Finding> {
    let mut reach: [usize; CLASS_COUNT] = [0; CLASS_COUNT];
    let mut seen: [bool; CLASS_COUNT] = [false; CLASS_COUNT];
    let mut out = Vec::with_capacity(sorted.len());
    for f in sorted {
        let i = f.class as usize;
        if seen[i] && f.range.start < reach[i] {
            reach[i] = reach[i].max(f.range.end);
            continue;
        }
        seen[i] = true;
        reach[i] = f.range.end;
        out.push(f);
    }
    out
}

/// Number of [`Class`] variants (they are fieldless, so `as usize` indexes).
const CLASS_COUNT: usize = 8;

/// The seven detectors over text that is already in normal form.
fn scan_plain(text: &str, cfg: &GuardConfig) -> Vec<Finding> {
    let mut out = Vec::new();
    scan_ssn(text, &mut out);
    scan_card(text, &mut out);
    scan_dob(text, &mut out);
    scan_mrn(text, &mut out);
    scan_phone(text, &mut out);
    scan_email(text, cfg, &mut out);
    scan_secret(text, &mut out);
    out
}

// ---------------------------------------------------------------------------
// Normalised view
// ---------------------------------------------------------------------------

/// A hidden character: invisible, and not whitespace (`\n`, `\t` and the Unicode
/// line separators are layout, not hiding).
fn is_hidden(c: char) -> bool {
    is_invisible(c) && !c.is_whitespace()
}

/// ASCII text with no hidden character: scanned as is.
fn is_plain(text: &str) -> bool {
    text.is_ascii() && !text.chars().any(is_hidden)
}

/// The text with compatibility forms folded to ASCII, plus where each of its
/// characters came from.
struct View {
    text: String,
    /// Byte offset in `text` of each character.
    starts: Vec<u32>,
    /// Byte range in the original text each character came from.
    origin: Vec<(u32, u32)>,
}

impl View {
    fn push(&mut self, c: char, origin: (u32, u32)) {
        // `scan` caps the input at MAX_SCAN_BYTES (1 MiB) before getting here, and
        // normalising expands one character into at most 18, so u32 holds it.
        self.starts
            .push(u32::try_from(self.text.len()).unwrap_or(u32::MAX));
        self.origin.push(origin);
        self.text.push(c);
    }

    /// The range in the original text covering the view range `r`.
    fn to_original(&self, r: &Range<usize>) -> Option<Range<usize>> {
        let first = self
            .starts
            .partition_point(|&s| (s as usize) <= r.start)
            .checked_sub(1)?;
        let last = self
            .starts
            .partition_point(|&s| (s as usize) < r.end)
            .checked_sub(1)?;
        let start = self.origin.get(first)?.0 as usize;
        let end = self.origin.get(last)?.1 as usize;
        (start < end).then_some(start..end)
    }
}

/// One character of the folded text. A hidden character is kept (as a space)
/// so the views can decide what it was.
struct Piece {
    c: char,
    origin: (u32, u32),
    hidden: bool,
}

/// NFKC and digit/dash folding per character, combining marks removed (a mark
/// stacked on a digit or letter must not break a value), hidden characters
/// flagged.
fn fold(text: &str) -> Vec<Piece> {
    let mut pieces = Vec::with_capacity(text.len());
    for (i, c) in text.char_indices() {
        let origin = (
            u32::try_from(i).unwrap_or(u32::MAX),
            u32::try_from(i + c.len_utf8()).unwrap_or(u32::MAX),
        );
        let mut piece = |c: char, hidden: bool| pieces.push(Piece { c, origin, hidden });
        if c.is_ascii() {
            if is_hidden(c) {
                piece(' ', true);
            } else {
                piece(c, false);
            }
            continue;
        }
        if is_hidden(c) {
            piece(' ', true);
            continue;
        }
        for n in std::iter::once(c).nfkc() {
            if is_hidden(n) {
                piece(' ', true);
            } else if !is_combining_mark(n) {
                piece(fold_char(n), false);
            }
        }
    }
    pieces
}

/// A hidden run between these two visible characters could be a space or part
/// of a value: both views are tried. Beside whitespace or a joiner (`-._/`) it
/// is not a space (`219-<ZWSP>09` is `219-09`), and between two letters it is
/// part of a word (`pass<ZWSP>word`).
fn is_ambiguous(before: char, after: char) -> bool {
    let plain = |c: char| c.is_whitespace() || is_joiner(c);
    !plain(before)
        && !plain(after)
        && !(before.is_ascii_alphabetic() && after.is_ascii_alphabetic())
}

/// Which ambiguous hidden runs a view turns into a space.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Spaced {
    /// None: every hidden character is removed.
    No,
    /// All of them.
    All,
    /// Every hidden run, ambiguous or not (the fail-closed fallback).
    Every,
    /// Only those next to a word: a letter on one side and a non-letter on the
    /// other (`SSN<ZWSP>2<ZWSP>19`: the label is cut off, the number is not).
    AtWords,
}

/// The view where hidden characters are removed, except the ambiguous runs
/// `spaced` selects, which become one space. Also says whether any run was
/// ambiguous, i.e. whether the spaced views differ.
fn build_view(pieces: &[Piece], spaced: Spaced) -> (View, bool) {
    let mut view = View {
        text: String::with_capacity(pieces.len()),
        starts: Vec::with_capacity(pieces.len()),
        origin: Vec::with_capacity(pieces.len()),
    };
    let mut any_ambiguous = false;
    let mut i = 0;
    while i < pieces.len() {
        let Some(piece) = pieces.get(i) else { break };
        if !piece.hidden {
            view.push(piece.c, piece.origin);
            i += 1;
            continue;
        }
        let mut j = i;
        while pieces.get(j).is_some_and(|p| p.hidden) {
            j += 1;
        }
        let before = i.checked_sub(1).and_then(|k| pieces.get(k));
        let after = pieces.get(j);
        if spaced == Spaced::Every {
            let end = pieces.get(j - 1).map_or(piece.origin.1, |p| p.origin.1);
            view.push(' ', (piece.origin.0, end));
        } else if let (Some(b), Some(a)) = (before, after) {
            if is_ambiguous(b.c, a.c) {
                any_ambiguous = true;
                let space = match spaced {
                    Spaced::No => false,
                    Spaced::All | Spaced::Every => true,
                    Spaced::AtWords => b.c.is_ascii_alphabetic() != a.c.is_ascii_alphabetic(),
                };
                if space {
                    let end = pieces.get(j - 1).map_or(piece.origin.1, |p| p.origin.1);
                    view.push(' ', (piece.origin.0, end));
                }
            }
        }
        i = j;
    }
    (view, any_ambiguous)
}

/// Folds what NFKC leaves behind: Unicode decimal digits (Arabic-Indic,
/// Devanagari, ...) become ASCII digits, and the dash and minus forms become `-`.
fn fold_char(c: char) -> char {
    if c.is_ascii() {
        return c;
    }
    match c {
        '\u{2010}'..='\u{2015}' | '\u{2212}' | '\u{FE58}' | '\u{FE63}' => '-',
        _ => decimal_digit_value(c).map_or(c, |d| char::from(b'0' + d)),
    }
}

static DECIMAL_DIGIT_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\p{Nd}$").expect("decimal digit regex"));

fn is_decimal_digit(c: char) -> bool {
    c.is_numeric() && DECIMAL_DIGIT_RE.is_match(c.encode_utf8(&mut [0; 4]))
}

/// Value 0-9 of a non-ASCII Unicode decimal digit. Unicode lays these out in
/// contiguous blocks of ten starting at zero, so the value is the distance from
/// the start of the run of digit characters, modulo ten.
fn decimal_digit_value(c: char) -> Option<u8> {
    if !is_decimal_digit(c) {
        return None;
    }
    let mut code = c as u32;
    let mut back = 0u32;
    // Blocks are ten digits; the longest unbroken run (mathematical digits) is 50.
    while back < 64 {
        let Some(prev) = code.checked_sub(1).and_then(char::from_u32) else {
            break;
        };
        if !is_decimal_digit(prev) {
            break;
        }
        code -= 1;
        back += 1;
    }
    u8::try_from(back % 10).ok()
}

fn scan_normalised(text: &str, cfg: &GuardConfig) -> Vec<Finding> {
    let pieces = fold(text);
    let (dropped, any_ambiguous) = build_view(&pieces, Spaced::No);
    let mut out = map_back(&dropped, scan_plain(&dropped.text, cfg));
    if pieces.iter().any(|p| p.hidden) {
        // Fail closed: also read every hidden run as a space (a letter-letter run
        // can be a separator too: `MRN<ZWSP>A9981734`).
        let (spaced, _) = build_view(&pieces, Spaced::Every);
        out.extend(map_back(&spaced, scan_plain(&spaced.text, cfg)));
    }
    if any_ambiguous {
        for mode in [Spaced::All, Spaced::AtWords] {
            let (spaced, _) = build_view(&pieces, mode);
            out.extend(map_back(&spaced, scan_plain(&spaced.text, cfg)));
        }
    }
    out
}

fn map_back(view: &View, found: Vec<Finding>) -> Vec<Finding> {
    found
        .into_iter()
        .filter_map(|f| {
            view.to_original(&f.range).map(|range| Finding {
                class: f.class,
                range,
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Context helpers
// ---------------------------------------------------------------------------

fn prev_char(text: &str, idx: usize) -> Option<char> {
    text.get(..idx)?.chars().next_back()
}

fn next_char(text: &str, idx: usize) -> Option<char> {
    text.get(idx..)?.chars().next()
}

/// A joiner that, between two alphanumerics, makes one identifier
/// (`1.2.3`, `a-b`, `x_y`, `path/to`).
fn is_joiner(c: char) -> bool {
    matches!(c, '-' | '.' | '_' | '/')
}

/// How far across a joiner to look at the neighbouring run (bounds the work).
const RUN_LOOKAROUND: usize = 64;

/// True when `text[start..end]` stands alone: not glued to a neighbouring
/// alphanumeric run and not one segment of a dotted/hyphenated/slashed
/// identifier (UUID, SHA slug, version, URL path id). A label in front of a
/// joiner (`SSN-219-09-9999`, `id/219-09-9999`) does not make an identifier.
fn standalone(text: &str, start: usize, end: usize) -> bool {
    if let Some(p) = prev_char(text, start) {
        if p.is_ascii_alphanumeric() {
            return false;
        }
        if is_joiner(p) {
            let run: Vec<char> = text
                .get(..start - p.len_utf8())
                .map(|head| {
                    head.chars()
                        .rev()
                        .take_while(|c| c.is_ascii_alphanumeric())
                        .take(RUN_LOOKAROUND)
                        .collect()
                })
                .unwrap_or_default();
            if !run.is_empty() && !is_label_run(p, &run) {
                return false;
            }
        }
    }
    if let Some(n) = next_char(text, end) {
        if n.is_ascii_alphanumeric() {
            return false;
        }
        if is_joiner(n) {
            let run: Vec<char> = text
                .get(end + n.len_utf8()..)
                .map(|tail| {
                    tail.chars()
                        .take_while(|c| c.is_ascii_alphanumeric())
                        .take(RUN_LOOKAROUND)
                        .collect()
                })
                .unwrap_or_default();
            if !run.is_empty() && !is_label_run(n, &run) {
                return false;
            }
        }
    }
    true
}

/// Whether the alphanumeric run next to a joiner is a prefix or suffix label
/// rather than part of an identifier: letters only, two or more, and not a
/// word spelled with hex digits alone (`dead`, `face`, `a`). Only ASCII counts
/// as glue: CJK and other scripts are written without spaces. A run of digits
/// counts across a `/` only (`219-09-9999/219-09-9998`).
fn is_label_run(joiner: char, run: &[char]) -> bool {
    if joiner == '/' && run.iter().all(char::is_ascii_digit) {
        return true;
    }
    run.len() >= 2
        && run.iter().all(char::is_ascii_alphabetic)
        && run.iter().any(|c| !c.is_ascii_hexdigit())
}

fn push(out: &mut Vec<Finding>, class: Class, range: Range<usize>) {
    out.push(Finding { class, range });
}

// ---------------------------------------------------------------------------
// SSN
// ---------------------------------------------------------------------------

static SSN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"([0-9]{3})-([0-9]{2})-([0-9]{4})").expect("ssn regex"));

fn scan_ssn(text: &str, out: &mut Vec<Finding>) {
    for caps in SSN_RE.captures_iter(text) {
        let (Some(whole), Some(area), Some(group), Some(serial)) =
            (caps.get(0), caps.get(1), caps.get(2), caps.get(3))
        else {
            continue;
        };
        let (area, group, serial) = (area.as_str(), group.as_str(), serial.as_str());
        let invalid = area == "000"
            || area == "666"
            || area.starts_with('9')
            || group == "00"
            || serial == "0000";
        if invalid || !standalone(text, whole.start(), whole.end()) {
            continue;
        }
        push(out, Class::Ssn, whole.range());
    }
}

// ---------------------------------------------------------------------------
// Payment card
// ---------------------------------------------------------------------------

/// Runs of digit groups joined by single spaces or dashes.
static CARD_RUN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[0-9]+(?:[ -][0-9]+)*").expect("card regex"));

fn scan_card(text: &str, out: &mut Vec<Finding>) {
    for run in CARD_RUN_RE.find_iter(text) {
        if run.len() < 13 {
            continue;
        }
        scan_card_run(text, run.start(), run.as_str(), out);
    }
}

/// Finds Luhn-valid card windows made of whole digit groups inside one run
/// (so `PR 4821 4111 1111 1111 1111` still finds the card).
fn scan_card_run(text: &str, base: usize, run: &str, out: &mut Vec<Finding>) {
    // Groups as (start, end) byte offsets within `run`.
    let mut groups: Vec<(usize, usize)> = Vec::new();
    let mut start = None;
    for (i, b) in run.bytes().enumerate() {
        match (b.is_ascii_digit(), start) {
            (true, None) => start = Some(i),
            (false, Some(s)) => {
                groups.push((s, i));
                start = None;
            }
            _ => {}
        }
    }
    if let Some(s) = start {
        groups.push((s, run.len()));
    }

    let mut i = 0;
    while i < groups.len() {
        let mut digits = 0;
        let mut matched = None;
        for j in i..groups.len() {
            let (ws, we) = (groups[i].0, groups[j].1);
            digits += groups[j].1 - groups[j].0;
            if digits > 19 {
                break;
            }
            let Some(window) = run.get(ws..we) else {
                break;
            };
            if digits >= 13 && is_card_window(window, &groups[i..=j]) {
                let (abs_s, abs_e) = (base + ws, base + we);
                if standalone(text, abs_s, abs_e) {
                    matched = Some((j, abs_s, abs_e));
                    break;
                }
            }
        }
        match matched {
            Some((j, s, e)) => {
                push(out, Class::Card, s..e);
                i = j + 1;
            }
            None => i += 1,
        }
    }
}

fn is_card_window(window: &str, groups: &[(usize, usize)]) -> bool {
    // One separator character throughout.
    let mut sep = None;
    for b in window.bytes().filter(|b| !b.is_ascii_digit()) {
        if *sep.get_or_insert(b) != b {
            return false;
        }
    }
    let lens: Vec<usize> = groups.iter().map(|(s, e)| e - s).collect();
    if !card_layout_ok(&lens) {
        return false;
    }
    let digits: Vec<u8> = window
        .bytes()
        .filter(u8::is_ascii_digit)
        .map(|b| b - b'0')
        .collect();
    let all_same = digits.windows(2).all(|w| w[0] == w[1]);
    plausible_issuer(&digits) && !all_same && luhn_ok(&digits)
}

/// Single run, 4-4-4-4(-3) style groups with a short tail, or the 4-6-5 /
/// 4-6-4 layout of Amex and Diners.
fn card_layout_ok(lens: &[usize]) -> bool {
    if lens.len() == 1 {
        return true;
    }
    if lens == [4, 6, 5] || lens == [4, 6, 4] {
        return true;
    }
    let Some((last, head)) = lens.split_last() else {
        return false;
    };
    head.iter().all(|l| *l == 4) && (1..=4).contains(last)
}

/// First digit of the major networks (Amex/Diners/JCB 3, Visa 4, Mastercard
/// 5 and 2221-2720, Discover/UnionPay 6). Cuts timestamp and id look-alikes.
fn plausible_issuer(digits: &[u8]) -> bool {
    match digits {
        [3..=6, ..] => true,
        [2, b, c, d, ..] => {
            let p = 2000 + u32::from(*b) * 100 + u32::from(*c) * 10 + u32::from(*d);
            (2221..=2720).contains(&p)
        }
        _ => false,
    }
}

fn luhn_ok(digits: &[u8]) -> bool {
    let mut sum = 0u32;
    for (i, d) in digits.iter().rev().enumerate() {
        let mut v = u32::from(*d);
        if i % 2 == 1 {
            v *= 2;
            if v > 9 {
                v -= 9;
            }
        }
        sum += v;
    }
    sum.is_multiple_of(10)
}

// ---------------------------------------------------------------------------
// Date of birth
// ---------------------------------------------------------------------------

static DOB_LABEL_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?-u:\b)(?:d\.o\.b|dob|date\s+of\s+birth|birth\s*date|born)(?-u:\b)")
        .expect("dob label")
});

static DATE_RE: LazyLock<Regex> = LazyLock::new(|| {
    let month = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?";
    let pattern = format!(
        r"(?i)(?-u:\b)(?:(?:0?[1-9]|1[0-2])[/.-](?:0?[1-9]|[12][0-9]|3[01])[/.-](?:[0-9]{{4}}|[0-9]{{2}})|(?:19|20)[0-9]{{2}}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])|{month}\s+[0-9]{{1,2}}(?:st|nd|rd|th)?,?\s+[0-9]{{4}}|[0-9]{{1,2}}\s+{month}\s+[0-9]{{4}})(?-u:\b)"
    );
    Regex::new(&pattern).expect("date regex")
});

/// How many characters after a label a birth date may start.
const DOB_WINDOW_CHARS: usize = 30;
/// Extra bytes read past the window so a date that starts inside it can end.
const DOB_TAIL_BYTES: usize = 24;

fn scan_dob(text: &str, out: &mut Vec<Finding>) {
    for label in DOB_LABEL_RE.find_iter(text) {
        let Some(after) = text.get(label.end()..) else {
            continue;
        };
        let window_len = after
            .char_indices()
            .nth(DOB_WINDOW_CHARS)
            .map_or(after.len(), |(i, _)| i);
        let mut end = (window_len + DOB_TAIL_BYTES).min(after.len());
        while end < after.len() && !after.is_char_boundary(end) {
            end += 1;
        }
        let Some(candidate) = after.get(..end) else {
            continue;
        };
        if let Some(d) = DATE_RE.find(candidate) {
            if d.start() <= window_len {
                push(
                    out,
                    Class::Dob,
                    label.end() + d.start()..label.end() + d.end(),
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Medical record number
// ---------------------------------------------------------------------------

static MRN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)(?-u:\b)(?:mrn|medical\s+record(?:\s+(?:number|num|no\.?|#))?)(?-u:\b)[\s:#=.-]*([a-z0-9][a-z0-9-]{3,})",
    )
    .expect("mrn regex")
});

fn scan_mrn(text: &str, out: &mut Vec<Finding>) {
    for caps in MRN_RE.captures_iter(text) {
        let (Some(whole), Some(id)) = (caps.get(0), caps.get(1)) else {
            continue;
        };
        // A real id has a digit; this drops "MRN lookup" and "medical record sync".
        if id.as_str().bytes().any(|b| b.is_ascii_digit()) {
            push(out, Class::Mrn, whole.range());
        }
    }
}

// ---------------------------------------------------------------------------
// Phone (NANP)
// ---------------------------------------------------------------------------

/// Area and exchange codes start 2-9. A bare 10-digit run never matches:
/// either a separator is required or a `+1` prefix.
static PHONE_RE: LazyLock<Regex> = LazyLock::new(|| {
    let area = r"[2-9][0-9]{2}";
    let line = r"[0-9]{4}";
    let pattern = format!(
        r"\+1[ .-]?(?:\({area}\)[ .-]?|{area}[ .-]?){area}[ .-]?{line}|(?:1[ .-])?\({area}\)[ .-]?{area}[ .-]{line}|(?:1-)?{area}-{area}-{line}|(?:1\.)?{area}\.{area}\.{line}|(?:1 )?{area} {area} {line}"
    );
    Regex::new(&pattern).expect("phone regex")
});

fn scan_phone(text: &str, out: &mut Vec<Finding>) {
    for m in PHONE_RE.find_iter(text) {
        if standalone(text, m.start(), m.end()) {
            push(out, Class::Phone, m.range());
        }
    }
}

// ---------------------------------------------------------------------------
// Personal email
// ---------------------------------------------------------------------------

static EMAIL_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)").expect("email regex")
});

/// File extensions that appear after an `@` in asset names (`logo@2x.png`).
const ASSET_EXTENSIONS: [&str; 6] = ["png", "jpg", "jpeg", "gif", "svg", "webp"];

fn scan_email(text: &str, cfg: &GuardConfig, out: &mut Vec<Finding>) {
    let userinfo: Vec<Range<usize>> = URL_CREDS_RE.find_iter(text).map(|m| m.range()).collect();
    for caps in EMAIL_RE.captures_iter(text) {
        let (Some(whole), Some(local), Some(domain)) = (caps.get(0), caps.get(1), caps.get(2))
        else {
            continue;
        };
        let domain = domain.as_str().to_ascii_lowercase();
        let tld = domain.rsplit('.').next().unwrap_or("");
        let alpha_tld = tld.len() >= 2 && tld.bytes().all(|b| b.is_ascii_alphabetic());
        // `git@github.com:org/repo.git` is an SSH remote, not a person.
        if !alpha_tld || ASSET_EXTENSIONS.contains(&tld) || local.as_str() == "git" {
            continue;
        }
        // The `@` of `scheme://user:pass@host` or `scheme://user@host` is URL
        // userinfo, not an address.
        let in_url = userinfo
            .iter()
            .any(|r| r.start <= whole.start() && whole.start() < r.end)
            || is_url_user(text, whole.start(), whole.end());
        if in_url || is_work_domain(&domain, cfg) {
            continue;
        }
        push(out, Class::PersonalEmail, whole.range());
    }
}

/// `scheme://user@host`: a complete URL scheme right before the address and a
/// URL boundary right after it (so `://jo.hale@gmail.com` alone is still an
/// address).
fn is_url_user(text: &str, start: usize, end: usize) -> bool {
    let Some(scheme) = text
        .get(..start)
        .and_then(|head| head.strip_suffix("://"))
        .map(|before| {
            before
                .chars()
                .rev()
                .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'))
                .collect::<Vec<char>>()
        })
    else {
        return false;
    };
    scheme.last().is_some_and(char::is_ascii_alphabetic)
        && next_char(text, end)
            .is_none_or(|n| n.is_whitespace() || matches!(n, '/' | ':' | '?' | '#'))
}

fn is_work_domain(domain: &str, cfg: &GuardConfig) -> bool {
    cfg.work_email_domains.iter().any(|w| {
        let w = w.trim().trim_start_matches('.').to_ascii_lowercase();
        !w.is_empty() && (domain == w || domain.ends_with(&format!(".{w}")))
    })
}

// ---------------------------------------------------------------------------
// Secrets
// ---------------------------------------------------------------------------

/// What may not sit just before a token for it to count (the left edge). A
/// token glued to a longer run of its own character class is part of
/// something else; one glued to an underscore or to a different class
/// (`key_AKIA...`, `xAKIA...`) still counts.
#[derive(Clone, Copy)]
enum Anchor {
    /// No constraint: the prefix is distinctive enough alone.
    Open,
    /// Not preceded by an ASCII letter or digit.
    NotAlnum,
    /// Not preceded by an uppercase letter or digit.
    NotUpperDigit,
    /// Not preceded by a lowercase letter or digit.
    NotLowerDigit,
}

impl Anchor {
    fn holds(self, text: &str, start: usize) -> bool {
        let Some(p) = prev_char(text, start) else {
            return true;
        };
        match self {
            Anchor::Open => true,
            Anchor::NotAlnum => !p.is_ascii_alphanumeric(),
            Anchor::NotUpperDigit => !(p.is_ascii_uppercase() || p.is_ascii_digit()),
            Anchor::NotLowerDigit => !(p.is_ascii_lowercase() || p.is_ascii_digit()),
        }
    }
}

/// Extra test on capture group 1 of a shape.
#[derive(Clone, Copy)]
enum Body {
    Any,
    /// Has a digit (cuts slugs and words).
    HasDigit,
    /// Looks random: see [`looks_random`].
    Random,
}

impl Body {
    fn holds(self, body: &str) -> bool {
        match self {
            Body::Any => true,
            Body::HasDigit => body.bytes().any(|b| b.is_ascii_digit()),
            Body::Random => looks_random(body),
        }
    }
}

struct Shape {
    re: Regex,
    anchor: Anchor,
    body: Body,
}

/// Patterns whose shape alone is conclusive (plus the anchor and body test).
static SECRET_SHAPES: LazyLock<Vec<Shape>> = LazyLock::new(|| {
    let shapes: [(&str, Anchor, Body); 14] = [
        // AWS access key id.
        (
            r"(?:AKIA|ASIA)[A-Z0-9]{16}(?-u:\b)",
            Anchor::NotUpperDigit,
            Body::Any,
        ),
        (
            r"(?:akia|asia)[a-z0-9]{16}(?-u:\b)",
            Anchor::NotLowerDigit,
            Body::Any,
        ),
        // AWS secret access key assignment.
        (
            r#"(?i)aws_?secret_?access_?key["']?\s*[=:]\s*["']?[A-Za-z0-9/+=]{16,}"#,
            Anchor::Open,
            Body::Any,
        ),
        // GitHub tokens.
        (r"(?i)gh[pousr]_[A-Za-z0-9]{20,}", Anchor::Open, Body::Any),
        (r"(?i)github_pat_[A-Za-z0-9_]{20,}", Anchor::Open, Body::Any),
        // Slack tokens.
        (
            r"(?i)xox[abeprs]-[A-Za-z0-9-]{10,}",
            Anchor::NotAlnum,
            Body::Any,
        ),
        (
            r"(?i)xapp-([A-Za-z0-9-]{10,})",
            Anchor::NotAlnum,
            Body::HasDigit,
        ),
        // Anthropic keys.
        (r"sk-ant-[A-Za-z0-9_-]{8,}", Anchor::NotAlnum, Body::Any),
        // Stripe keys.
        (
            r"(?i)(?:[sr]k_(?:live|test)|pk_live)_[A-Za-z0-9]{10,}",
            Anchor::NotAlnum,
            Body::Any,
        ),
        // npm access token.
        (r"npm_[A-Za-z0-9]{36}(?-u:\b)", Anchor::NotAlnum, Body::Any),
        // Google API key.
        (r"AIza([A-Za-z0-9_-]{35})", Anchor::NotAlnum, Body::Random),
        // JWT: header.payload.signature, header and payload both start `eyJ`.
        (
            r"eyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*",
            Anchor::NotAlnum,
            Body::Any,
        ),
        // PEM private-key header.
        (
            r"(?i)-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?:-----)?",
            Anchor::Open,
            Body::Any,
        ),
        // `Authorization: Basic <base64 of user:password>`.
        (
            r"(?i)(?-u:\b)authorization\s*:\s*basic\s+([A-Za-z0-9+/]{12,}={0,2})",
            Anchor::Open,
            Body::Random,
        ),
    ];
    shapes
        .iter()
        .map(|(pattern, anchor, body)| Shape {
            re: Regex::new(pattern).expect("secret shape regex"),
            anchor: *anchor,
            body: *body,
        })
        .collect()
});

/// `sk-` followed by a long token; judged for randomness in code.
static SK_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?-u:\b)sk-([A-Za-z0-9_-]{20,})").expect("sk regex"));

static BEARER_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)(?-u:\b)Bearer\s+([A-Za-z0-9._~+/=-]{20,})").expect("bearer regex")
});

/// `scheme://user:password@host`; group 1 is the password. Placeholder
/// passwords are told apart in code ([`is_placeholder_password`]).
static URL_CREDS_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:([^\s/@]+)@[^\s/]+").expect("url creds regex")
});

/// `password=...`, `"api_key": "..."`, `client_secret: ...` with a value of at
/// least 8 non-space characters.
static ASSIGNMENT_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:password|passwd|pwd|secret|token|api_?key)["']?\s*[=:]\s*["']?(\S{8,})"#)
        .expect("assignment regex")
});

fn scan_secret(text: &str, out: &mut Vec<Finding>) {
    for shape in SECRET_SHAPES.iter() {
        for caps in shape.re.captures_iter(text) {
            let Some(whole) = caps.get(0) else { continue };
            let body_ok = caps.get(1).is_none_or(|b| shape.body.holds(b.as_str()));
            if body_ok && shape.anchor.holds(text, whole.start()) {
                push(out, Class::Secret, whole.range());
            }
        }
    }
    for caps in SK_RE.captures_iter(text) {
        let (Some(whole), Some(body)) = (caps.get(0), caps.get(1)) else {
            continue;
        };
        let glued = prev_char(text, whole.start()).is_some_and(is_joiner);
        // `sk-` mid-slug (`my-sk-...`) or an all-lowercase slug is not a key.
        if !glued && looks_random(body.as_str()) {
            push(out, Class::Secret, whole.range());
        }
    }
    for caps in BEARER_RE.captures_iter(text) {
        let (Some(whole), Some(body)) = (caps.get(0), caps.get(1)) else {
            continue;
        };
        if looks_random(body.as_str()) {
            push(out, Class::Secret, whole.range());
        }
    }
    for caps in URL_CREDS_RE.captures_iter(text) {
        let (Some(whole), Some(password)) = (caps.get(0), caps.get(1)) else {
            continue;
        };
        if !is_placeholder_password(password.as_str()) {
            push(out, Class::Secret, whole.range());
        }
    }
    for caps in ASSIGNMENT_RE.captures_iter(text) {
        let (Some(whole), Some(value)) = (caps.get(0), caps.get(1)) else {
            continue;
        };
        if assignment_value_is_secret(value.as_str()) {
            push(out, Class::Secret, whole.range());
        }
    }
}

/// A token worth treating as random: has a digit, or mixes upper and lower
/// case. Plain hyphenated lowercase words (slugs, prose) do not.
fn looks_random(token: &str) -> bool {
    token.bytes().any(|b| b.is_ascii_digit())
        || (token.bytes().any(|b| b.is_ascii_uppercase())
            && token.bytes().any(|b| b.is_ascii_lowercase()))
}

/// The whole password of a URL is a template or a redaction, not a value:
/// `${NAME}`, `$NAME` (NAME uppercase, digits and underscores), `<...>` with a
/// word inside, `%s`, `{{...}}`, or only `*`. A password that merely starts with
/// one of those characters (`$ecret99`, `%40ecret99`, `*ecret99`) is not.
fn is_placeholder_password(password: &str) -> bool {
    if let Some(inner) = password
        .strip_prefix("${")
        .and_then(|rest| rest.strip_suffix('}'))
    {
        return !inner.is_empty()
            && inner
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'));
    }
    if let Some(rest) = password.strip_prefix('$') {
        let name: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        let tail = rest.get(name.len()..).unwrap_or("");
        return name.starts_with(|c: char| c.is_ascii_uppercase() || c == '_')
            && name
                .chars()
                .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
            && tail.chars().all(|c| !c.is_alphanumeric());
    }
    if let Some(inner) = password
        .strip_prefix('<')
        .and_then(|rest| rest.strip_suffix('>'))
    {
        return has_word(inner);
    }
    if let Some(inner) = password
        .strip_prefix("{{")
        .and_then(|rest| rest.strip_suffix("}}"))
    {
        return !inner.is_empty() && !inner.contains(['{', '}']);
    }
    password == "%s" || (password.len() >= 3 && password.chars().all(|c| c == '*'))
}

/// Two or more letters in a row.
fn has_word(text: &str) -> bool {
    let mut run = 0;
    for c in text.chars() {
        if c.is_alphabetic() {
            run += 1;
            if run >= 2 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

/// Drops placeholders, redactions, paths and URLs from `password=...` values.
fn assignment_value_is_secret(value: &str) -> bool {
    let v = value.trim_matches(|c| matches!(c, '"' | '\'' | '`' | ',' | ';' | ')'));
    if v.len() < 8 {
        return false;
    }
    let first = v.chars().next().unwrap_or(' ');
    if matches!(first, '<' | '$' | '{' | '[' | '%' | '/' | '~' | '.' | '*') {
        return false;
    }
    if v.starts_with("http://") || v.starts_with("https://") {
        return false;
    }
    // `xxxxxxxx`, `********`, `........`: redaction, not a value.
    !v.chars().all(|c| c == first)
}
