//! Secret redaction for text delivered to an agent (PRD criterion 42).
//!
//! [`Redactor::redact`] replaces text that has the shape of a credential with
//! a visible `[redacted: <kind>]` marker and reports what it replaced, so the
//! reader (human or model) can tell something was removed.
//!
//! The patterns are deliberately narrow about *values*: ordinary output
//! (hashes, UUIDs, `ls`, logs, an `env` dump without secret-named variables)
//! must come through untouched. There is **no** generic high-entropy rule and
//! **no** "any environment value" rule. This is separate from
//! `activity::redact`, whose broader rules would redact every sha256 in a
//! query result.
//!
//! ## Where the shapes come from
//!
//! The token shapes are **duplicated on purpose** from `crate::sensitive_text`
//! (the tracker guard) and from `activity::redact`: the guard only reports
//! findings and applies randomness and placeholder judgements that a redactor
//! must not (a redactor fails closed, so `password=hunter2` is replaced even
//! though the guard ignores a value that short). Sharing the constants would
//! have meant changing `sensitive_text`, whose behaviour and tests are fixed.
//! The engine's rule set is instead pinned to be a superset of the guard's:
//! `tests/terminal_text_engine.rs` runs the guard's own positive corpus
//! through the redactor and requires every secret, SSN and date-of-birth line
//! to change.
//!
//! ## What it covers
//!
//! * credential-named assignments in any common syntax: `NAME=value`,
//!   `export NAME="v"`, YAML `name: v`, JSON `"name": "v"` (also escaped),
//!   `--password hunter2`, `--password=hunter2`, an unterminated quote
//!   (redacted to the end of the line);
//! * `scheme://user:password@host` where the password may hold `@` or `/`;
//! * `Authorization:` headers (Basic, Digest and any other scheme), `Bearer`
//!   values;
//! * provider tokens (GitHub, GitLab, npm, Google, Slack, Stripe, Anthropic,
//!   OpenAI, JWT), AWS key ids, and AWS secret keys / session tokens by
//!   context;
//! * credentials given to well-known CLIs (`curl -u user:pass`, `mysql
//!   -pSECRET`, `sshpass -p`, `redis-cli -a`, `docker login -p`, ...);
//! * PEM and PGP private-key blocks;
//! * SSN-shaped numbers and date-of-birth-labelled dates (the PHI shapes the
//!   tracker guard also detects).
//!
//! ## What it deliberately does not cover
//!
//! A secret with no recognisable shape and no credential-looking name (a bare
//! 40-char string in the middle of prose, a cookie, `htpasswd -b`), `-p <value>`
//! for tools where `-p` is not known to mean "password", and PHI that is not an SSN or a labelled date of birth (names,
//! MRNs, addresses). Hashes and UUIDs are never touched.
//!
//! ## Look-alikes and invisible characters
//!
//! Matching runs on a normalised view (see the `View` type): invisible
//! characters (zero-width, soft hyphen, BOM, bidi, ...) are dropped or read as
//! a space, fullwidth forms and any Unicode digit fold to ASCII, and the en
//! dash, em dash and minus sign fold to `-`, exactly what the tracker guard's
//! normaliser does, so nothing the guard sees through can hide a secret here.
//! Redactions are mapped back onto the original text, so a hidden character
//! inside a secret goes with it and the text around it is never rewritten.
//!
//! On the delivery path the line assembler **keeps** the invisible filler in
//! the lines it commits (it can stand in for a space: `curl<ZWSP>-u user:pw`,
//! `--password<ZWSP>value`, `Bearer<ZWSP>token`), so the redactor reads the
//! same text on both paths and decides, per view, whether the filler was a
//! separator or part of a word. [`deliver`](crate::terminal::follow::deliver)
//! strips the filler from the text it hands out, after redaction.
//!
//! Homoglyphs are **not** folded: a Cyrillic `а` in `pаssword` or `ghр_` stays
//! a different character from the Latin one, so such a name or token is not
//! recognised. The tracker guard has the same gap; NFKC (fullwidth forms) and
//! the dash and digit folds above are all the normalisation there is.
//!
//! A text with several hidden characters in different roles (one inside a
//! keyword, one standing for the separator) is read under four fixed
//! assumptions, not every combination.
//!
//! ## Contract: whole lines
//!
//! Every rule except private-key blocks is judged inside **one call**: a
//! secret split across two [`Redactor::redact`] calls (`GITHUB_TOKEN=ghp_AAAA`
//! then `AAAA...`) survives. Callers must feed whole lines, which is what
//! [`deliver`](crate::terminal::follow::deliver) does: it only ever sees
//! committed lines, never the live cursor row.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

use crate::data::work::is_invisible;

/// Most bytes a private-key block may swallow without showing an `END` line
/// before the redactor gives up on it and resumes normal redaction. A real key
/// is a few KiB; a `BEGIN` with no `END` in this much text is not one.
pub const MAX_UNTERMINATED_KEY_BYTES: usize = 64 * 1024;

/// What kind of secret was replaced. The marker text is `[redacted: <kind>]`
/// with the kind spelled as [`as_str`](RedactionKind::as_str).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum RedactionKind {
    /// AWS access key id (`AKIA…`, `ASIA…`, …).
    AwsAccessKey,
    /// Value of `aws_secret_access_key` / `aws_session_token`.
    AwsSecretKey,
    /// Value after `Bearer`.
    BearerToken,
    /// Provider token shapes: GitHub, GitLab, npm, Google, Slack, Stripe,
    /// `sk-…`, JWT.
    ApiToken,
    /// Value of a `PASSWORD=` / `API_KEY=` / `…_SECRET=` style assignment, a
    /// `--password` flag, or a credential given to a known CLI.
    SecretAssignment,
    /// Password inside `scheme://user:password@host`.
    UrlPassword,
    /// A PEM / PGP private-key block.
    PrivateKey,
    /// Credentials of an `Authorization: Basic …` header.
    BasicAuth,
    /// A US social-security-number-shaped value.
    Ssn,
    /// A date labelled as a birth date.
    DateOfBirth,
}

impl RedactionKind {
    /// The kind as written inside the marker.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AwsAccessKey => "aws-access-key",
            Self::AwsSecretKey => "aws-secret-key",
            Self::BearerToken => "bearer-token",
            Self::ApiToken => "api-token",
            Self::SecretAssignment => "secret-assignment",
            Self::UrlPassword => "url-password",
            Self::PrivateKey => "private-key",
            Self::BasicAuth => "basic-auth",
            Self::Ssn => "ssn",
            Self::DateOfBirth => "dob",
        }
    }

    fn marker(self) -> String {
        format!("[redacted: {}]", self.as_str())
    }
}

impl fmt::Display for RedactionKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A span of text a rule wants replaced.
struct Hit {
    range: Range<usize>,
    kind: RedactionKind,
}

/// One rule: appends its hits for `text`.
type Scanner = fn(&str, &mut Vec<Hit>);

/// Rules in priority order: when matches overlap, the earlier rule wins, so
/// `GITHUB_TOKEN=ghp_…` reports `api-token` (name kept) and
/// `AWS_SECRET_ACCESS_KEY=…` reports `aws-secret-key`, not
/// `secret-assignment`. The credential-name rule is last because it is the
/// broadest.
const SCANNERS: &[Scanner] = &[
    scan_url_password,
    scan_aws_secret,
    scan_bearer,
    scan_tokens,
    scan_aws_access_key,
    scan_authorization,
    scan_cli_credentials,
    scan_ssn,
    scan_dob,
    scan_assignments,
];

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("redaction pattern")
}

// ───────────────────────────── value grammar ─────────────────────────────────

/// A value after `=`, `:` or a flag: quoted (double with escapes, JSON-escaped
/// `\"…\"`, single, backtick; a bare tail glued to the closing quote belongs to
/// the value), an UNTERMINATED quote (to the end of the line), or a bare word.
const VALUE: &str = r#""(?:[^"\\\n]|\\.)*"[A-Za-z0-9_.\-+/=@%~]*|\\"[^"\n]*"[A-Za-z0-9_.\-+/=@%~]*|'[^'\n]*'[A-Za-z0-9_.\-+/=@%~]*|`[^`\n]*`[A-Za-z0-9_.\-+/=@%~]*|\\?["'`][^\n]*|\S+"#;

/// A command-line value: quoted or one bare word.
const ARG: &str = r#""[^"\n]*"|'[^'\n]*'|\S+"#;

static VALUE_AT_START: LazyLock<Regex> = LazyLock::new(|| re(&format!("^(?:{VALUE})")));

// ───────────────────────────── normalised views ──────────────────────────────

// The patterns are ASCII-only and run on *views* of the text, the same
// normalisation `crate::sensitive_text` applies so that nothing the guard
// sees through can hide from the redactor: invisible characters (zero-width,
// soft hyphen, BOM, bidi, tag, ...) are dropped, compatibility forms
// (fullwidth letters, digits and punctuation) are NFKC-folded, any Unicode
// decimal digit becomes an ASCII digit, dashes and the minus sign become `-`,
// and combining marks are removed. Spans found in a view are mapped back to
// the original text, so the text around a redaction is never rewritten.
//
// A hidden run can be part of a value (`219-<ZWSP>09-9999`) or stand in for a
// space (`SSN<ZWSP>219-09-9999`), so a text with hidden characters is also
// scanned with those runs read as spaces (see [`Hidden`]).
//
// Duplicated from the guard on purpose, like the token shapes (see the module
// docs): the guard's normaliser is private and its module is fixed.

/// How a view treats hidden runs.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Hidden {
    /// Every hidden character is removed.
    Dropped,
    /// Every hidden run is one space.
    EverySpaced,
    /// Runs between two non-blank, non-joiner characters are one space.
    AmbiguousSpaced,
    /// Only ambiguous runs next to a word (a letter on one side, a non-letter
    /// on the other) are one space (`SSN<ZWSP>2<ZWSP>19`).
    AtWords,
}

/// A hidden character: invisible and not layout whitespace.
fn is_hidden(c: char) -> bool {
    is_invisible(c) && !c.is_whitespace()
}

/// Whitespace the patterns' `[ \t]` and `\s` do not all see as a blank: the
/// vertical tab, form feed, and every non-ASCII space or line separator.
fn is_odd_blank(c: char) -> bool {
    c.is_whitespace() && !matches!(c, ' ' | '\t' | '\n' | '\r')
}

/// ASCII text with no hidden character or odd blank: its own view.
fn is_plain(text: &str) -> bool {
    text.is_ascii() && !text.chars().any(|c| is_hidden(c) || is_odd_blank(c))
}

/// One character of folded text and the original bytes it came from. A hidden
/// character is kept (as a space) so the views can decide what it was.
struct Piece {
    c: char,
    origin: (usize, usize),
    hidden: bool,
}

fn fold(text: &str) -> Vec<Piece> {
    let mut pieces = Vec::with_capacity(text.len());
    for (i, c) in text.char_indices() {
        let origin = (i, i + c.len_utf8());
        let mut piece = |c: char, hidden: bool| pieces.push(Piece { c, origin, hidden });
        if is_hidden(c) {
            piece(' ', true);
        } else if is_odd_blank(c) {
            piece(' ', false);
        } else if c.is_ascii() {
            piece(c, false);
        } else {
            for n in std::iter::once(c).nfkc() {
                if is_hidden(n) {
                    piece(' ', true);
                } else if is_odd_blank(n) {
                    piece(' ', false);
                } else if !is_combining_mark(n) {
                    piece(fold_char(n), false);
                }
            }
        }
    }
    pieces
}

/// What NFKC leaves behind: Unicode decimal digits and the dash forms.
fn fold_char(c: char) -> char {
    if c.is_ascii() {
        return c;
    }
    match c {
        '\u{2010}'..='\u{2015}' | '\u{2212}' | '\u{FE58}' | '\u{FE63}' => '-',
        _ => decimal_digit_value(c).map_or(c, |d| char::from(b'0' + d)),
    }
}

static DECIMAL_DIGIT: LazyLock<Regex> = LazyLock::new(|| re(r"^\p{Nd}$"));

fn is_decimal_digit(c: char) -> bool {
    c.is_numeric() && DECIMAL_DIGIT.is_match(c.encode_utf8(&mut [0; 4]))
}

/// Value 0-9 of a non-ASCII decimal digit: Unicode lays these out in
/// contiguous blocks of ten from zero, so it is the distance from the start of
/// the run of digit characters, modulo ten.
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

/// A hidden run between these two visible characters could be a space or part
/// of a value. Beside blanks or a joiner (`-._/`) it is not a space
/// (`219-<ZWSP>09`), and between two letters it is part of a word
/// (`pass<ZWSP>word`).
fn is_ambiguous(before: char, after: char) -> bool {
    let plain = |c: char| c.is_whitespace() || matches!(c, '-' | '.' | '_' | '/');
    !plain(before)
        && !plain(after)
        && !(before.is_ascii_alphabetic() && after.is_ascii_alphabetic())
}

/// Where each character of a view came from.
struct Origins {
    /// Byte offset in the view of each character.
    starts: Vec<usize>,
    /// Byte range in the original of each character.
    ranges: Vec<(usize, usize)>,
}

/// A normalised copy of a text. `origins` is `None` for the identity view of
/// plain ASCII text.
struct View<'a> {
    text: Cow<'a, str>,
    origins: Option<Origins>,
}

impl<'a> View<'a> {
    /// The views to scan `text` on: itself when it is plain, else the dropped
    /// view plus the distinct space-reading views its hidden runs call for.
    fn all(text: &'a str) -> Vec<View<'a>> {
        if is_plain(text) {
            return vec![View {
                text: Cow::Borrowed(text),
                origins: None,
            }];
        }
        let pieces = fold(text);
        let any_hidden = pieces.iter().any(|p| p.hidden);
        let modes: &[Hidden] = if !any_hidden {
            &[Hidden::Dropped]
        } else {
            &[
                Hidden::Dropped,
                Hidden::EverySpaced,
                Hidden::AmbiguousSpaced,
                Hidden::AtWords,
            ]
        };
        let mut views: Vec<View<'a>> = Vec::with_capacity(modes.len());
        for &mode in modes {
            let view = View::from_pieces(&pieces, mode);
            if !views.iter().any(|v| v.text == view.text) {
                views.push(view);
            }
        }
        views
    }

    fn build(text: &str, mode: Hidden) -> View<'static> {
        View::from_pieces(&fold(text), mode)
    }

    fn from_pieces(pieces: &[Piece], mode: Hidden) -> View<'static> {
        let mut text = String::with_capacity(pieces.len());
        let mut starts = Vec::with_capacity(pieces.len());
        let mut ranges = Vec::with_capacity(pieces.len());
        let mut push = |c: char, range: (usize, usize)| {
            starts.push(text.len());
            ranges.push(range);
            text.push(c);
        };
        let mut i = 0;
        while let Some(piece) = pieces.get(i) {
            if !piece.hidden {
                push(piece.c, piece.origin);
                i += 1;
                continue;
            }
            let mut j = i;
            while pieces.get(j).is_some_and(|p| p.hidden) {
                j += 1;
            }
            let run = (
                piece.origin.0,
                pieces.get(j - 1).map_or(piece.origin.1, |p| p.origin.1),
            );
            let before = i.checked_sub(1).and_then(|k| pieces.get(k));
            let after = pieces.get(j);
            let space = match mode {
                Hidden::Dropped => false,
                Hidden::EverySpaced => true,
                Hidden::AmbiguousSpaced | Hidden::AtWords => match (before, after) {
                    (Some(b), Some(a)) if is_ambiguous(b.c, a.c) => {
                        mode == Hidden::AmbiguousSpaced
                            || b.c.is_ascii_alphabetic() != a.c.is_ascii_alphabetic()
                    }
                    _ => false,
                },
            };
            if space {
                push(' ', run);
            }
            i = j;
        }
        View {
            text: Cow::Owned(text),
            origins: Some(Origins { starts, ranges }),
        }
    }

    /// The range of the original text covering `range` of the view.
    fn to_original(&self, range: Range<usize>) -> Option<Range<usize>> {
        let Some(origins) = &self.origins else {
            return Some(range);
        };
        let first = origins
            .starts
            .partition_point(|&s| s <= range.start)
            .checked_sub(1)?;
        let last = origins
            .starts
            .partition_point(|&s| s < range.end)
            .checked_sub(1)?;
        let start = origins.ranges.get(first)?.0;
        let end = origins.ranges.get(last)?.1;
        (start < end).then_some(start..end)
    }
}

// ───────────────────────────── helpers ───────────────────────────────────────

fn prev_char(text: &str, idx: usize) -> Option<char> {
    text.get(..idx)?.chars().next_back()
}

fn next_char(text: &str, idx: usize) -> Option<char> {
    text.get(idx..)?.chars().next()
}

/// What may not sit just before a token for it to count. A token glued to a
/// longer run of its own character class is part of something else; one glued
/// to an underscore or to a different class (`key_AKIA...`) still counts.
///
/// The anchor is part of the pattern (a leading character that is consumed),
/// not a check after the match: a failed check would force a retry one
/// character later, which is quadratic on `ask-ask-ask-…`.
#[derive(Clone, Copy)]
enum Anchor {
    Open,
    NotAlnum,
    NotUpperDigit,
    NotLowerDigit,
}

impl Anchor {
    /// `pattern` with this anchor in front; the token is the `t` group.
    fn compile(self, pattern: &str) -> Regex {
        let guard = match self {
            Anchor::Open => return re(&format!("(?P<t>{pattern})")),
            Anchor::NotAlnum => "[^A-Za-z0-9]",
            Anchor::NotUpperDigit => "[^A-Z0-9]",
            Anchor::NotLowerDigit => "[^a-z0-9]",
        };
        re(&format!("(?:^|{guard})(?P<t>{pattern})"))
    }
}

/// Hits of an [`Anchor::compile`]d pattern (and, when `end_boundary`, not
/// followed by an alphanumeric). Every match is final: nothing is retried.
fn scan_shape(
    pattern: &Regex,
    end_boundary: bool,
    kind: RedactionKind,
    text: &str,
    hits: &mut Vec<Hit>,
) {
    for caps in pattern.captures_iter(text) {
        let Some(token) = caps.name("t") else {
            continue;
        };
        let glued_after =
            end_boundary && next_char(text, token.end()).is_some_and(|c| c.is_ascii_alphanumeric());
        if !glued_after {
            hits.push(Hit {
                range: token.range(),
                kind,
            });
        }
    }
}

/// Hits of `pattern`'s `value` group, as `kind`.
fn scan_value_group(pattern: &Regex, kind: RedactionKind, text: &str, hits: &mut Vec<Hit>) {
    for caps in pattern.captures_iter(text) {
        if let Some(value) = caps.name("value") {
            hits.push(Hit {
                range: value.range(),
                kind,
            });
        }
    }
}

// ───────────────────────────── URL passwords ─────────────────────────────────

/// `scheme://user:password@host`. The user stops at the first `:`; the
/// password runs to the LAST `@` of the run (it may hold `@` and `/`), so
/// `postgres://u:p@ss@host/db` and `postgres://u:pa/ss@host/db` are covered.
/// The run stops at whitespace and quote characters.
static URL_PASSWORD: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?i)[a-z][a-z0-9+.\-]*://[^\s:/"'`<>]*:(?P<value>[^\s"'`<>]+)@"#));

fn scan_url_password(text: &str, hits: &mut Vec<Hit>) {
    for caps in URL_PASSWORD.captures_iter(text) {
        let Some(value) = caps.name("value") else {
            continue;
        };
        // `https://host:8080/path/img@2x.png` is a port and a path, not a
        // password: up to five digits and then a slash.
        let bytes = value.as_str().as_bytes();
        let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
        if (1..=5).contains(&digits) && bytes.get(digits) == Some(&b'/') {
            continue;
        }
        hits.push(Hit {
            range: value.range(),
            kind: RedactionKind::UrlPassword,
        });
    }
}

// ───────────────────────────── AWS ───────────────────────────────────────────

static AWS_SECRET: LazyLock<Regex> = LazyLock::new(|| {
    re(&format!(
        r#"(?i)\baws_?(?:secret_?(?:access_?)?key|session_?token|security_?token)\b["'`]?(?:[ \t]*[=:][ \t]*|[ \t]+)(?P<value>{VALUE})"#
    ))
});

fn scan_aws_secret(text: &str, hits: &mut Vec<Hit>) {
    scan_value_group(&AWS_SECRET, RedactionKind::AwsSecretKey, text, hits);
}

static AWS_KEY_ID_UPPER: LazyLock<Regex> = LazyLock::new(|| {
    Anchor::NotUpperDigit.compile(r"(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}")
});
static AWS_KEY_ID_LOWER: LazyLock<Regex> = LazyLock::new(|| {
    Anchor::NotLowerDigit.compile(r"(?:akia|asia|agpa|aida|aroa|anpa|anva|aipa)[a-z0-9]{16}")
});

fn scan_aws_access_key(text: &str, hits: &mut Vec<Hit>) {
    let kind = RedactionKind::AwsAccessKey;
    scan_shape(&AWS_KEY_ID_UPPER, true, kind, text, hits);
    scan_shape(&AWS_KEY_ID_LOWER, true, kind, text, hits);
}

// ───────────────────────────── tokens ────────────────────────────────────────

static BEARER: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?i)\bbearer[ \t]+(?P<value>[A-Za-z0-9._~+/=\-]{8,})"));

fn scan_bearer(text: &str, hits: &mut Vec<Hit>) {
    scan_value_group(&BEARER, RedactionKind::BearerToken, text, hits);
}

/// Provider token shapes, each compiled with the anchor it needs.
static TOKEN_SHAPES: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        (r"(?i)gh[pousr]_[A-Za-z0-9]{20,}", Anchor::Open),
        (r"(?i)github_pat_[A-Za-z0-9_]{20,}", Anchor::Open),
        (r"(?i)glpat-[A-Za-z0-9_\-]{20,}", Anchor::NotAlnum),
        (r"(?i)xox[abeprs]-[A-Za-z0-9\-]{10,}", Anchor::NotAlnum),
        (r"(?i)xapp-[A-Za-z0-9\-]{10,}", Anchor::NotAlnum),
        (
            r"(?i)(?:[sr]k_(?:live|test)|pk_live|whsec)_[A-Za-z0-9]{8,}",
            Anchor::NotAlnum,
        ),
        (r"(?i)npm_[A-Za-z0-9]{30,}", Anchor::NotAlnum),
        (r"AIza[A-Za-z0-9_\-]{35}", Anchor::NotAlnum),
        (r"sk-ant-[A-Za-z0-9_\-]{8,}", Anchor::NotAlnum),
        (r"sk-[A-Za-z0-9_\-]{20,}", Anchor::NotAlnum),
        (
            r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*",
            Anchor::NotAlnum,
        ),
    ]
    .into_iter()
    .map(|(pattern, anchor)| anchor.compile(pattern))
    .collect()
});

fn scan_tokens(text: &str, hits: &mut Vec<Hit>) {
    for pattern in TOKEN_SHAPES.iter() {
        scan_shape(pattern, false, RedactionKind::ApiToken, text, hits);
    }
}

// ───────────────────────────── Authorization header ──────────────────────────

static AUTHORIZATION: LazyLock<Regex> = LazyLock::new(|| {
    re(r#"(?i)\b(?:proxy-)?authorization\b["'`]?[ \t]*[:=][ \t]*(?P<quote>["'`])?"#)
});

/// Schemes whose credentials are one token.
const TOKEN_SCHEMES: &[&str] = &["basic", "bearer", "token"];

/// `Authorization: <scheme> <credentials>` (the credentials are replaced, the
/// scheme kept) or `Authorization: <opaque>`. Basic, Bearer and Token carry
/// one word. Any other scheme (Digest, OAuth, AWS4-HMAC-SHA256, ...) carries
/// parameters: they run to the end of the quote the header sits in, or to the
/// end of the line. `Bearer` values are also caught by their own rule, which
/// wins ties.
fn scan_authorization(text: &str, hits: &mut Vec<Hit>) {
    let mut pos = 0;
    while let Some(caps) = AUTHORIZATION.captures_at(text, pos) {
        let (Some(label), quote) = (caps.get(0), caps.name("quote")) else {
            break;
        };
        pos = label.end();
        let rest = &text[label.end()..];
        let token_len = rest
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`'))
            .unwrap_or(rest.len());
        if token_len == 0 {
            continue;
        }
        let scheme = &rest[..token_len];
        let after = &rest[token_len..];
        let blanks = after.len() - after.trim_start_matches([' ', '\t']).len();
        let credentials = &after[blanks..];
        let stops_here =
            credentials.is_empty() || credentials.starts_with(['\n', '\r', '"', '\'', '`']);
        let (start, len, kind) = if blanks > 0 && !stops_here {
            let kind = if scheme.eq_ignore_ascii_case("basic") {
                RedactionKind::BasicAuth
            } else {
                RedactionKind::SecretAssignment
            };
            let one_token = TOKEN_SCHEMES.iter().any(|s| scheme.eq_ignore_ascii_case(s));
            let len = if one_token {
                credentials
                    .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`'))
                    .unwrap_or(credentials.len())
            } else {
                // The header's own quote: the one opened after the separator
                // (`"Authorization":"Digest …"`) or the one in front of the
                // name (`curl -H "Authorization: Digest …"`).
                let enclosing = quote.and_then(|q| q.as_str().chars().next()).or_else(|| {
                    prev_char(text, label.start()).filter(|c| matches!(c, '"' | '\'' | '`'))
                });
                let line_end = credentials.find('\n').unwrap_or(credentials.len());
                let end = enclosing
                    .and_then(|q| find_closing_quote(&credentials[..line_end], q))
                    .unwrap_or(line_end);
                credentials[..end].trim_end_matches([' ', '\t', '\r']).len()
            };
            (label.end() + token_len + blanks, len, kind)
        } else {
            (label.end(), token_len, RedactionKind::SecretAssignment)
        };
        if len > 0 {
            hits.push(Hit {
                range: start..start + len,
                kind,
            });
            pos = pos.max(start + len);
        }
    }
}

/// Offset of the first `quote` in `text` that is not backslash-escaped.
fn find_closing_quote(text: &str, quote: char) -> Option<usize> {
    let mut escaped = false;
    for (i, c) in text.char_indices() {
        if escaped {
            escaped = false;
        } else if c == '\\' {
            escaped = true;
        } else if c == quote {
            return Some(i);
        }
    }
    None
}

// ───────────────────────────── credentials given to CLIs ─────────────────────

/// Passwords on the command line of tools where the flag is known to carry
/// one. `-p` alone is not enough (`mkdir -p`, `ssh -p 22`), so the tool name
/// has to be on the same command.
static CLI_CREDENTIALS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    let rest = r"[^\n|;&]*?";
    [
        // mysql -pSECRET (the password is attached; `-p` alone prompts)
        format!(
            r#"(?i)\b(?:mysql|mysqldump|mysqladmin|mysqlcheck|mysqlimport|mysqlshow|mariadb|mariadb-dump)\b{rest}[ \t](?-i:-p)(?P<value>[^\s\-]\S*)"#
        ),
        // sshpass -p SECRET / -pSECRET
        format!(r#"(?i)\bsshpass\b{rest}[ \t](?-i:-p)[ \t]*(?P<value>{ARG})"#),
        // redis-cli -a SECRET
        format!(r#"(?i)\bredis-cli\b{rest}[ \t](?-i:-a)[ \t]+(?P<value>{ARG})"#),
        // unzip -P SECRET
        format!(r#"(?i)\b(?:unzip|zip)\b{rest}[ \t](?-i:-P)[ \t]*(?P<value>{ARG})"#),
        // 7z -pSECRET
        format!(
            r#"(?i)\b(?:7z|7za|7zr|rar|unrar)\b{rest}[ \t](?-i:-p)(?P<value>[^\s\-]\S*)"#
        ),
        // docker login -u u -p SECRET
        format!(
            r#"(?i)\bdocker\b{rest}\blogin\b{rest}[ \t](?-i:-p)[ \t]+(?P<value>{ARG})"#
        ),
        // ldapsearch -w SECRET
        format!(
            r#"(?i)\bldap(?:search|modify|add|delete|compare|passwd)\b{rest}[ \t](?-i:-w)[ \t]*(?P<value>{ARG})"#
        ),
        // openssl ... -passin pass:SECRET
        format!(r#"(?-i:-pass(?:in|out)?)[ \t]+pass:(?P<value>{ARG})"#),
    ]
    .iter()
    .map(|pattern| re(pattern))
    .collect()
});

fn scan_cli_credentials(text: &str, hits: &mut Vec<Hit>) {
    scan_curl_users(text, hits);
    for pattern in CLI_CREDENTIALS.iter() {
        scan_value_group(pattern, RedactionKind::SecretAssignment, text, hits);
    }
}

// ───────────────────────────── curl -u ───────────────────────────────────────

/// The flags that carry a user: `-u`, `-U` (proxy), their long forms, and the
/// short ones behind a cluster of curl's no-argument short flags (`-su`).
static CURL_USER_FLAG: LazyLock<Regex> = LazyLock::new(|| {
    re(r"[ \t](?:(?-i:-[#0-46aBfgGhiIjJkLlMnNOpqRsSvVZ]*[uU])[ \t]*|--(?:proxy-)?user(?:[ \t]+|=))")
});

static CURL_WORD: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)\bcurl\b"));

/// `curl -u user:password`, in every quoting the shell allows: bare, the whole
/// credential quoted (it may hold spaces), a quoted user with a bare or quoted
/// password (`-u "admin":secret`), and quotes inside the value
/// (`-u 'admin:hun'\''ter2'`, `-u "admin:hun\"ter2"`). It fails closed: when a
/// quote is followed by more text glued to it, or a value holds a quote, the
/// credential runs to the end of the line. Every `-u` of one command counts.
fn scan_curl_users(text: &str, hits: &mut Vec<Hit>) {
    // The flags of a command are all found from its first `curl`; skipping the
    // later ones keeps `curl curl curl …` linear.
    let mut scanned_to = 0;
    for curl in CURL_WORD.find_iter(text) {
        if curl.start() < scanned_to {
            continue;
        }
        let line_end = text[curl.end()..]
            .find('\n')
            .map_or(text.len(), |n| curl.end() + n);
        let command_end = text[curl.end()..]
            .find(['\n', '|', ';', '&'])
            .map_or(text.len(), |n| curl.end() + n);
        scanned_to = command_end;
        let mut pos = curl.end();
        while pos <= command_end {
            let Some(flag) = CURL_USER_FLAG.find_at(&text[..command_end], pos) else {
                break;
            };
            pos = flag.end();
            if let Some(range) = curl_credential(text, flag.end(), line_end) {
                pos = pos.max(range.end);
                hits.push(Hit {
                    range,
                    kind: RedactionKind::SecretAssignment,
                });
            }
        }
    }
}

/// The password of the credential starting at `at` (just after the flag).
fn curl_credential(text: &str, at: usize, line_end: usize) -> Option<Range<usize>> {
    let rest = &text[at..line_end];
    let first = rest.chars().next()?;
    if matches!(first, '"' | '\'') {
        let body = at + 1;
        let Some(close) = closing_quote(&text[body..line_end], first) else {
            // Unterminated: from the first colon to the end of the line.
            let colon = text[body..line_end].find(':')?;
            return non_empty(body + colon + 1..line_end);
        };
        let (close, after) = (body + close, body + close + 1);
        if let Some(colon) = text[body..close].find(':') {
            let end = if is_continued(text, after) {
                line_end
            } else {
                close
            };
            return non_empty(body + colon + 1..end);
        }
        if text[after..].starts_with(':') {
            return curl_password(text, after + 1, line_end);
        }
        // `-u 'ad'min:secret`: the quote is glued to more of the credential.
        if is_continued(text, after) {
            let colon = text[after..line_end].find(':')?;
            return non_empty(after + colon + 1..line_end);
        }
        return None;
    }
    let stop = rest.find(|c: char| c == ':' || c.is_whitespace() || matches!(c, '"' | '\''))?;
    if rest[stop..].starts_with(':') {
        return curl_password(text, at + stop + 1, line_end);
    }
    if rest[stop..].starts_with(['"', '\'']) {
        // A quote inside the user part: from the first colon to the end of the line.
        let colon = rest[stop..]
            .find(':')
            .filter(|&n| stop + n < line_end - at)?;
        return non_empty(at + stop + colon + 1..line_end);
    }
    None
}

/// The password at `at`: a quoted string (quotes included), or one word. A
/// word that holds a quote, or a quoted string with more glued to it, runs to
/// the end of the line.
fn curl_password(text: &str, at: usize, line_end: usize) -> Option<Range<usize>> {
    let rest = &text[at..line_end];
    let first = rest.chars().next()?;
    if first.is_whitespace() {
        return None;
    }
    if matches!(first, '"' | '\'') {
        let end = match closing_quote(&rest[1..], first) {
            Some(close) => at + 1 + close + 1,
            None => line_end,
        };
        return non_empty(
            at..if is_continued(text, end) {
                line_end
            } else {
                end
            },
        );
    }
    let word = rest.find(char::is_whitespace).unwrap_or(rest.len());
    let end = if rest[..word].contains(['"', '\'']) {
        line_end
    } else {
        at + word
    };
    non_empty(at..end)
}

/// Offset of the quote closing `text`'s start. Backslash escapes a quote inside
/// double quotes only: single quotes have no escapes in a shell.
fn closing_quote(text: &str, quote: char) -> Option<usize> {
    if quote == '\'' {
        text.find(quote)
    } else {
        find_closing_quote(text, quote)
    }
}

/// Whether the character at `idx` is glued to the quote before it (not a
/// blank, the end of the text, or a command separator).
fn is_continued(text: &str, idx: usize) -> bool {
    next_char(text, idx).is_some_and(|c| !c.is_whitespace() && !matches!(c, ';' | '|' | '&' | ')'))
}

fn non_empty(range: Range<usize>) -> Option<Range<usize>> {
    (range.start < range.end).then_some(range)
}

// ───────────────────────────── PHI shapes ────────────────────────────────────

static SSN: LazyLock<Regex> = LazyLock::new(|| re(r"[0-9]{3}-[0-9]{2}-[0-9]{4}"));

fn scan_ssn(text: &str, hits: &mut Vec<Hit>) {
    for m in SSN.find_iter(text) {
        let s = m.as_str();
        let (area, group, serial) = (&s[..3], &s[4..6], &s[7..]);
        let invalid = area == "000"
            || area == "666"
            || area.starts_with('9')
            || group == "00"
            || serial == "0000";
        // Not one segment of a longer dashed number (`123-45-6789-12`), nor
        // glued to a word. The exception is the label itself: the line
        // assembler drops a filler that stood in for the space
        // (`SSN<ZWSP>219-09-9999` becomes `SSN219-09-9999`).
        let glued_before = (prev_char(text, m.start()).is_some_and(|c| c.is_ascii_alphanumeric())
            && !glued_to_ssn_label(text, m.start()))
            || (prev_char(text, m.start()) == Some('-')
                && prev_char(text, m.start() - 1).is_some_and(|c| c.is_ascii_digit()));
        let glued_after = next_char(text, m.end()).is_some_and(|c| c.is_ascii_alphanumeric())
            || (next_char(text, m.end()) == Some('-')
                && next_char(text, m.end() + 1).is_some_and(|c| c.is_ascii_digit()));
        if !invalid && !glued_before && !glued_after {
            hits.push(Hit {
                range: m.range(),
                kind: RedactionKind::Ssn,
            });
        }
    }
}

/// Whether the text just before `start` is the word `ssn` on its own.
fn glued_to_ssn_label(text: &str, start: usize) -> bool {
    let Some(label_start) = start.checked_sub(3) else {
        return false;
    };
    text.get(label_start..start)
        .is_some_and(|label| label.eq_ignore_ascii_case("ssn"))
        && !prev_char(text, label_start).is_some_and(|c| c.is_ascii_alphanumeric())
}

static DOB_LABEL: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?-u:\b)(?:d\.o\.b|dob|date[ \t]+of[ \t]+birth|birth[ \t]*date|born)(?-u:\b)")
});

static DATE: LazyLock<Regex> = LazyLock::new(|| {
    let month = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?";
    re(&format!(
        r"(?i)(?-u:\b)(?:(?:0?[1-9]|1[0-2])[/.-](?:0?[1-9]|[12][0-9]|3[01])[/.-](?:[0-9]{{4}}|[0-9]{{2}})|(?:19|20)[0-9]{{2}}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])|{month}[ \t]+[0-9]{{1,2}}(?:st|nd|rd|th)?,?[ \t]+[0-9]{{4}}|[0-9]{{1,2}}[ \t]+{month}[ \t]+[0-9]{{4}})(?-u:\b)"
    ))
});

/// How many characters after a label a birth date may start, and how many
/// extra bytes are read so a date that starts inside the window can end.
const DOB_WINDOW_CHARS: usize = 30;
const DOB_TAIL_BYTES: usize = 24;

fn scan_dob(text: &str, hits: &mut Vec<Hit>) {
    for label in DOB_LABEL.find_iter(text) {
        let after = &text[label.end()..];
        let line = &after[..after.find('\n').unwrap_or(after.len())];
        let window = line
            .char_indices()
            .nth(DOB_WINDOW_CHARS)
            .map_or(line.len(), |(i, _)| i);
        let mut end = (window + DOB_TAIL_BYTES).min(line.len());
        while !line.is_char_boundary(end) {
            end += 1;
        }
        if let Some(date) = DATE.find(&line[..end]) {
            if date.start() <= window {
                hits.push(Hit {
                    range: label.end() + date.start()..label.end() + date.end(),
                    kind: RedactionKind::DateOfBirth,
                });
            }
        }
    }
}

// ───────────────────────────── credential-named values ───────────────────────

/// Identifier-ish runs that contain a credential word. The run is the whole
/// name (`DB_PASSWORD`, `x-api-key`, `config.token`); [`is_secret_name`] makes
/// the final call.
static SECRET_NAME: LazyLock<Regex> = LazyLock::new(|| {
    re(
        r"(?i)[a-z0-9_.\-]*(?:pass|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|auth|credential|dsn|[_-]key)[a-z0-9_.\-]*",
    )
});

/// Credential words. Each must END a word of the name (end of name, or a
/// non-letter next): `TOKENIZER` and `GIT_AUTHOR_NAME` are not credentials but
/// `API_KEY_ID`, `token2` and `secrets` are. `pass` has extra rules below.
const NAME_WORDS: &[&str] = &[
    "password",
    "passwd",
    "passphrase",
    "pwd",
    "secret",
    "token",
    "apikey",
    "api_key",
    "api-key",
    "accesskey",
    "access_key",
    "access-key",
    "privatekey",
    "private_key",
    "private-key",
    "credential",
    "dsn",
    "auth",
    "_key",
    "-key",
];

/// Words that merely end in `pass`.
const NOT_PASS: &[&str] = &[
    "bypass",
    "compass",
    "overpass",
    "underpass",
    "surpass",
    "trespass",
    "encompass",
    "impass",
];

/// Name endings whose value is a place, not a secret.
const BENIGN_SUFFIXES: &[&str] = &[
    "_sock", "_socket", "_path", "_file", "_dir", "-file", "-path",
];

fn is_secret_name(name: &str) -> bool {
    let name = name.trim_start_matches(['-', '.']);
    // The shell's working directory variables.
    if name == "PWD" || name == "OLDPWD" {
        return false;
    }
    let lower = name.to_ascii_lowercase();
    if BENIGN_SUFFIXES.iter().any(|s| lower.ends_with(s)) {
        return false;
    }
    // `public_key` and friends are public by definition.
    let lower = lower
        .replace("public_key", "")
        .replace("public-key", "")
        .replace("publickey", "")
        .replace("pubkey", "");

    let ends_word = |end: usize| {
        let rest = &lower[end..];
        let rest = rest.strip_prefix('s').unwrap_or(rest);
        !rest.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
    };
    if NAME_WORDS
        .iter()
        .any(|w| lower.match_indices(w).any(|(i, _)| ends_word(i + w.len())))
    {
        return true;
    }
    lower.match_indices("pass").any(|(i, _)| {
        let end = i + 4;
        let rest = &lower[end..];
        let ends = rest.is_empty()
            || !rest
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric());
        ends && !NOT_PASS.iter().any(|w| lower[..end].ends_with(w))
    })
}

fn blanks_at(text: &str, idx: usize) -> usize {
    let rest = &text[idx..];
    rest.len() - rest.trim_start_matches([' ', '\t']).len()
}

/// The value range for a credential-named identifier at `name`, if it is
/// followed by a separator (or, for `--flags`, by a space and a value).
fn value_after_name(text: &str, name: Range<usize>) -> Option<Range<usize>> {
    let bytes = text.as_bytes();
    let mut i = name.end;
    // The closing quote of a quoted key, possibly backslash-escaped (`\"`).
    if bytes.get(i) == Some(&b'\\') && matches!(bytes.get(i + 1), Some(b'"' | b'\'' | b'`')) {
        i += 2;
    } else if matches!(bytes.get(i), Some(b'"' | b'\'' | b'`')) {
        i += 1;
    }
    let gap = blanks_at(text, i);
    i += gap;
    let rest = &text[i..];
    let sep = ["=>", ":=", "=="]
        .iter()
        .find(|s| rest.starts_with(**s))
        .map_or_else(|| usize::from(rest.starts_with(['=', ':'])), |s| s.len());
    let colon = sep == 1 && rest.starts_with(':');
    if sep == 0 {
        // `--password hunter2`: a flag takes the next word.
        let flag = text[name.clone()].starts_with("--");
        if !flag || gap == 0 || rest.starts_with('-') {
            return None;
        }
    } else {
        i += sep;
        i += blanks_at(text, i);
    }
    let value = VALUE_AT_START.find(&text[i..])?;
    let start = i + value.start();
    let mut end = i + value.end();
    let quoted = text[start..].starts_with(['"', '\'', '`', '\\']);
    if colon && !quoted {
        // `password: correct horse battery`: an unquoted YAML/log value runs
        // to the end of the line.
        let line_end = text[start..].find('\n').map_or(text.len(), |n| start + n);
        end = start + text[start..line_end].trim_end().len();
    }
    (start < end).then_some(start..end)
}

fn scan_assignments(text: &str, hits: &mut Vec<Hit>) {
    let mut pos = 0;
    while let Some(name) = SECRET_NAME.find_at(text, pos) {
        let value = is_secret_name(name.as_str())
            .then(|| value_after_name(text, name.range()))
            .flatten();
        match value {
            Some(range) => {
                pos = range.end;
                hits.push(Hit {
                    range,
                    kind: RedactionKind::SecretAssignment,
                });
            }
            // Only past the name: a rejected or valueless name must not hide a
            // credential assignment inside what follows it.
            None => pos = name.end(),
        }
        if pos > text.len() {
            break;
        }
    }
}

// ───────────────────────────── private keys ──────────────────────────────────

/// The key markers are matched on the view with invisible characters dropped,
/// where a hidden character that stood in for a space has vanished
/// (`BEGIN<ZWSP>PRIVATE`), so the spaces between the words are optional.
static PRIVATE_KEY_BEGIN: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?i)-----BEGIN ?[A-Z0-9 ]*PRIVATE ?KEY(?: ?BLOCK)?(?:-----)?"));
static PRIVATE_KEY_END: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?i)-----END ?[A-Z0-9 ]*PRIVATE ?KEY(?: ?BLOCK)?(?:-----)?"));
static KEY_HEADER_START: LazyLock<Regex> = LazyLock::new(|| re(r"-----BEGIN"));

/// A text prepared for finding private-key markers: the view with invisible
/// characters dropped and look-alikes folded, built once so a text full of
/// markers is scanned once, not once per marker.
struct KeyScan<'a> {
    text: &'a str,
    /// `None` when `text` is plain, which is its own view.
    view: Option<View<'static>>,
}

impl<'a> KeyScan<'a> {
    fn new(text: &'a str) -> Self {
        let view = (!is_plain(text)).then(|| View::build(text, Hidden::Dropped));
        Self { text, view }
    }

    /// The first match of `pattern` inside `text[from..to]` (`from` and `to`
    /// on character boundaries), as a range of `text`.
    fn find(&self, pattern: &Regex, from: usize, to: usize) -> Option<Range<usize>> {
        let Some(view) = &self.view else {
            let window = self.text.get(from..to)?;
            let m = pattern.find(window)?;
            return Some(from + m.start()..from + m.end());
        };
        let origins = view.origins.as_ref()?;
        // The view characters that come from `text[from..to]`.
        let first = origins.ranges.partition_point(|r| r.0 < from);
        let last = origins.ranges.partition_point(|r| r.1 <= to);
        let lo = origins
            .starts
            .get(first)
            .copied()
            .unwrap_or(view.text.len());
        let hi = origins.starts.get(last).copied().unwrap_or(view.text.len());
        let m = pattern.find(view.text.get(lo..hi)?)?;
        view.to_original(lo + m.start()..lo + m.end())
    }

    fn find_from(&self, pattern: &Regex, from: usize) -> Option<Range<usize>> {
        self.find(pattern, from, self.text.len())
    }
}

/// Marker for a private-key block that never showed an `END` line.
const UNTERMINATED_MARKER: &str = "[redacted: private-key (no END line; output resumes)]";

/// Redacts secrets from successive pieces of one terminal's text.
///
/// Stateful only for private-key blocks: a block whose `BEGIN` has no `END` in
/// the same call is redacted to the end of the text and the following calls
/// keep redacting until an `END` arrives, or until the block has swallowed
/// [`MAX_UNTERMINATED_KEY_BYTES`] without one (then output resumes).
#[derive(Debug, Default, Clone)]
pub struct Redactor {
    inside_private_key: bool,
    /// Bytes swallowed by the current private-key block so far.
    swallowed: usize,
}

impl Redactor {
    /// A redactor that is not inside a private-key block.
    pub fn new() -> Self {
        Self::default()
    }

    /// A redactor for a screen of `lines` that stands alone, so its top may be
    /// the middle of a private-key block whose `BEGIN` has scrolled off. Such a
    /// screen is recognisable by an `END` line with no `BEGIN` above it, or by
    /// `key_open`: the terminal's own stream was inside a block when the screen
    /// was drawn (a key taller than the screen, still printing). Either way
    /// the screen starts inside the block, so everything down to its `END`
    /// (or the whole screen) is redacted.
    pub(crate) fn for_screen(lines: &[String], key_open: bool) -> Self {
        let text = lines.join("\n");
        let scan = KeyScan::new(&text);
        let end_first = match (
            scan.find_from(&PRIVATE_KEY_END, 0),
            scan.find_from(&PRIVATE_KEY_BEGIN, 0),
        ) {
            (Some(end), Some(begin)) => end.start < begin.start,
            (Some(_), None) => true,
            (None, _) => false,
        };
        Self {
            inside_private_key: key_open || end_first,
            swallowed: 0,
        }
    }

    /// Whether the previous call ended inside a private-key block.
    pub fn inside_private_key(&self) -> bool {
        self.inside_private_key
    }

    /// Replace secrets in `text`; return the new text and one
    /// [`RedactionKind`] per replacement, in order of appearance.
    ///
    /// `text` must be WHOLE lines (see the [module docs](self)).
    ///
    /// Only the secret itself is replaced for `aws-secret-key`,
    /// `bearer-token`, `secret-assignment`, `url-password`, `basic-auth` and
    /// the PHI kinds, so names and context stay readable
    /// (`DB_PASSWORD=[redacted: secret-assignment]`). A private-key block (or
    /// the part of one in this call) becomes a single `[redacted: private-key]`;
    /// a call that continues a block from the previous call reports it again,
    /// so every delivery shows what it hides.
    pub fn redact(&mut self, text: &str) -> (String, Vec<RedactionKind>) {
        let mut out = String::with_capacity(text.len());
        let mut kinds = Vec::new();
        if self.inside_private_key && text.is_empty() {
            return (out, kinds);
        }
        let scan = KeyScan::new(text);
        // Everything before `pos` is done.
        let mut pos = 0;
        loop {
            if self.inside_private_key {
                out.push_str(&RedactionKind::PrivateKey.marker());
                kinds.push(RedactionKind::PrivateKey);
                match self.swallow_block(&scan, pos) {
                    Swallowed::All => return (out, kinds),
                    Swallowed::Through(end) => pos = end,
                    Swallowed::GaveUp(end) => {
                        out.push_str(UNTERMINATED_MARKER);
                        kinds.push(RedactionKind::PrivateKey);
                        pos = end;
                        if pos >= text.len() {
                            return (out, kinds);
                        }
                        out.push('\n');
                    }
                }
            }
            match scan.find_from(&PRIVATE_KEY_BEGIN, pos) {
                Some(begin) => {
                    redact_plain(&text[pos..begin.start], &mut out, &mut kinds);
                    // The block's own marker is pushed at the top of the loop.
                    self.inside_private_key = true;
                    self.swallowed = 0;
                    pos = begin.end;
                }
                None => {
                    redact_plain(&text[pos..], &mut out, &mut kinds);
                    return (out, kinds);
                }
            }
        }
    }

    /// Redact whole lines and return them as lines again. A private-key block
    /// that spans several lines collapses to one marker line.
    pub(crate) fn redact_lines(&mut self, lines: &[String]) -> (Vec<String>, Vec<RedactionKind>) {
        if lines.is_empty() {
            return (Vec::new(), Vec::new());
        }
        let (text, kinds) = self.redact(&lines.join("\n"));
        (text.split('\n').map(str::to_owned).collect(), kinds)
    }

    /// After a failed redaction of `lines`: keep failing closed. If the lost
    /// text may have opened a private-key block, stay inside one so the key
    /// body in the next delivery is swallowed too.
    pub(crate) fn assume_unredacted(&mut self, lines: &[String]) {
        if lines
            .iter()
            .any(|l| KeyScan::new(l).find_from(&KEY_HEADER_START, 0).is_some())
        {
            self.inside_private_key = true;
            self.swallowed = 0;
        }
    }

    /// Consume the inside of a private-key block that starts at `from` in
    /// the scanned text. Offsets in the result are offsets of that text.
    fn swallow_block(&mut self, scan: &KeyScan, from: usize) -> Swallowed {
        let text = scan.text;
        let rest_len = text.len() - from;
        let budget = MAX_UNTERMINATED_KEY_BYTES.saturating_sub(self.swallowed);
        let searchable = floor_boundary(text, from + budget.min(rest_len));
        if let Some(end) = scan.find(&PRIVATE_KEY_END, from, searchable) {
            self.inside_private_key = false;
            self.swallowed = 0;
            return Swallowed::Through(end.end);
        }
        if rest_len <= budget {
            self.swallowed += rest_len;
            return Swallowed::All;
        }
        // Past the bound: give up on the block at the end of the line that
        // crossed it and resume normal redaction after that line.
        self.inside_private_key = false;
        self.swallowed = 0;
        let end = text[searchable..]
            .find('\n')
            .map_or(text.len(), |n| searchable + n + 1);
        Swallowed::GaveUp(end)
    }
}

enum Swallowed {
    /// The whole text is inside the block; it stays open.
    All,
    /// The block's `END` ended at this offset; the block is closed.
    Through(usize),
    /// The block outran [`MAX_UNTERMINATED_KEY_BYTES`]; resume at this offset.
    GaveUp(usize),
}

fn floor_boundary(text: &str, mut idx: usize) -> usize {
    while !text.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

/// Whether a private-key block is still open after `text`, given whether one
/// was open before it. The assembler uses this on rows it has to drop, so a
/// dropped `BEGIN` still reaches the redactor (see `LineAssembler`).
pub(crate) fn private_key_open_after(text: &str, open: bool) -> bool {
    let scan = KeyScan::new(text);
    let mut pos = 0;
    if open {
        match scan.find_from(&PRIVATE_KEY_END, pos) {
            Some(end) => pos = end.end,
            None => return true,
        }
    }
    while let Some(begin) = scan.find_from(&PRIVATE_KEY_BEGIN, pos) {
        match scan.find_from(&PRIVATE_KEY_END, begin.end) {
            Some(end) => pos = end.end,
            None => return true,
        }
    }
    false
}

/// A span accepted for replacement.
struct Span {
    end: usize,
    kind: RedactionKind,
    /// Index of the rule that produced it (lower wins).
    priority: usize,
    /// Text around the span that stays readable around its marker: the whole
    /// URL for a URL password, else the span itself.
    context: Range<usize>,
}

/// Apply the pattern rules (everything except private keys) to `text`.
fn redact_plain(text: &str, out: &mut String, kinds: &mut Vec<RedactionKind>) {
    if text.is_empty() {
        return;
    }
    // Accepted spans never overlap, so keying by start also orders them by
    // end: an overlap test is one range lookup.
    let mut accepted: BTreeMap<usize, Span> = BTreeMap::new();
    let mut hits = Vec::new();
    let views = View::all(text);
    for (priority, scan) in SCANNERS.iter().enumerate() {
        for view in &views {
            hits.clear();
            scan(&view.text, &mut hits);
            for hit in hits.drain(..) {
                let Hit { range, kind } = hit;
                // A span the view cannot place in the original is dropped; the
                // other views and rules still cover the text.
                if let Some(range) = view.to_original(range) {
                    accept(&mut accepted, text, Hit { range, kind }, priority);
                }
            }
        }
    }

    let mut cursor = 0;
    for (start, span) in accepted {
        out.push_str(&text[cursor..start]);
        out.push_str(&span.kind.marker());
        kinds.push(span.kind);
        cursor = span.end;
    }
    out.push_str(&text[cursor..]);
}

/// Add `hit` unless accepted spans already account for all of its text.
///
/// A hit that only overlaps (it reaches beyond what is accepted) must not
/// leave the overhang readable when the overhang holds text: the spans merge
/// into one covering both, under the highest-priority kind. Not counted as
/// overhang: quotes and punctuation (`TOKEN="ghp_…"`: the token's marker stays
/// inside the quotes) and the rest of a URL whose password was replaced
/// (`DB_PASSWORD=postgres://u:pw@h/d` keeps the URL readable). Text beside the
/// URL still counts (`password: hunter2 https://u:p@h`).
fn accept(accepted: &mut BTreeMap<usize, Span>, text: &str, hit: Hit, priority: usize) {
    let Hit { range, kind } = hit;
    if range.is_empty() {
        return;
    }
    let context = if kind == RedactionKind::UrlPassword {
        url_context(text, &range)
    } else {
        range.clone()
    };
    // Ordered by start, last first: accepted spans are disjoint.
    let overlapped: Vec<usize> = accepted
        .range(..range.end)
        .rev()
        .take_while(|(_, span)| span.end > range.start)
        .map(|(&start, _)| start)
        .collect();
    let (Some(&first_start), Some(&last_start)) = (overlapped.last(), overlapped.first()) else {
        accepted.insert(
            range.start,
            Span {
                end: range.end,
                kind,
                priority,
                context,
            },
        );
        return;
    };

    // Walk the hit left to right over what the overlapped spans account for.
    let mut cursor = range.start;
    let mut has_text_overhang = false;
    for start in overlapped.iter().rev() {
        let covered = &accepted[start].context;
        has_text_overhang |= holds_text(text, cursor, covered.start.min(range.end));
        cursor = cursor.max(covered.end);
    }
    has_text_overhang |= holds_text(text, cursor, range.end);
    if !has_text_overhang {
        return;
    }

    let (kind, priority) = overlapped
        .iter()
        .map(|start| (accepted[start].kind, accepted[start].priority))
        .min_by_key(|&(_, p)| p)
        .unwrap_or((kind, priority));
    let end = accepted[&last_start].end.max(range.end);
    for start in &overlapped {
        accepted.remove(start);
    }
    let start = first_start.min(range.start);
    accepted.insert(
        start,
        Span {
            end,
            kind,
            priority,
            context: start..end,
        },
    );
}

/// Whether `text[from..to]` (empty when `from >= to`) has a letter or digit.
fn holds_text(text: &str, from: usize, to: usize) -> bool {
    text.get(from..to)
        .is_some_and(|piece| piece.chars().any(char::is_alphanumeric))
}

/// The whole URL around a password span: back over `scheme://user:` and
/// forward over the rest of the run.
fn url_context(text: &str, password: &Range<usize>) -> Range<usize> {
    let head = &text[..password.start];
    let scheme_start = head.rfind("://").map_or(password.start, |i| {
        head[..i]
            .char_indices()
            .rev()
            .find(|&(_, c)| !(c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-')))
            .map_or(0, |(j, c)| j + c.len_utf8())
    });
    let tail = &text[password.end..];
    let run = tail
        .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '`' | '<' | '>'))
        .unwrap_or(tail.len());
    scheme_start..password.end + run
}

// ───────────────────────────── truncation stubs ──────────────────────────────

/// Prefixes of the token shapes above. A token cut short by truncation can
/// leave one of these plus a few characters, too short for its pattern.
const STUB_PREFIXES: &[&str] = &[
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "github_pat_",
    "glpat-",
    "npm_",
    "AIza",
    "xapp-",
    "xoxa-",
    "xoxb-",
    "xoxe-",
    "xoxp-",
    "xoxr-",
    "xoxs-",
    "sk-",
    "sk_live_",
    "sk_test_",
    "rk_live_",
    "rk_test_",
    "pk_live_",
    "whsec_",
    "eyJ",
    "AKIA",
    "ASIA",
    "AGPA",
    "AIDA",
    "AROA",
    "ANPA",
    "ANVA",
    "AIPA",
];

pub(crate) fn is_token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '+' | '/' | '=' | '~')
}

/// Where a trailing partial secret starts in `kept`, text that was cut off in
/// the middle of a word: the start of the last token when it holds a known
/// token prefix, or of a `-----BEGIN …` header that has not reached
/// `PRIVATE KEY`. `None` when the text ends cleanly.
///
/// Truncation redacts first and cuts second, so this is only the second line
/// of defence: it catches a stub whose pattern needs more characters than the
/// cut left.
pub(crate) fn trailing_secret_stub(kept: &str) -> Option<usize> {
    let token_start = kept
        .char_indices()
        .rev()
        .take_while(|&(_, c)| is_token_char(c))
        .last()
        .map_or(kept.len(), |(i, _)| i);
    let token = &kept[token_start..];
    let prefix_at = STUB_PREFIXES
        .iter()
        .filter_map(|prefix| {
            token.match_indices(prefix).map(|(i, _)| i).find(|&i| {
                // At the start of the token or after a joiner, as the real
                // patterns allow (`key_ghp_…`); GitHub's need no anchor at all.
                i == 0
                    || prefix.starts_with("gh")
                    || !token.as_bytes()[i - 1].is_ascii_alphanumeric()
            })
        })
        .min()
        .map(|i| token_start + i);

    let header_at = kept.rfind("-----BEGIN").filter(|&i| {
        let tail = &kept[i..];
        !tail.contains('\n')
            && tail.len() < 96
            && !tail.to_ascii_uppercase().contains("PRIVATE KEY")
    });
    match (prefix_at, header_at) {
        (Some(a), Some(b)) => Some(a.min(b)),
        (a, b) => a.or(b),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_trailing_token_stub_is_found_at_its_start() {
        for (kept, keep) in [
            ("see ghp_AAAA", "see "),
            ("x key_ghp_AAAA", "x key_"),
            ("id AKIAFAKE", "id "),
            ("jwt eyJhbGciOi", "jwt "),
            ("k sk-abc", "k "),
            ("hdr -----BEGIN RSA PRIV", "hdr "),
        ] {
            let at = trailing_secret_stub(kept).unwrap_or_else(|| panic!("{kept}"));
            assert_eq!(&kept[..at], keep, "{kept}");
        }
    }

    #[test]
    fn text_that_ends_cleanly_has_no_stub() {
        for kept in [
            "",
            "plain words",
            "ls -la /tmp",
            "ghost",
            "-----BEGIN PUBLIC KEY-----",
        ] {
            let found = trailing_secret_stub(kept);
            // A complete public-key header is the only look-alike; it counts
            // as a stub only because it ends mid-header.
            if kept.starts_with("-----BEGIN") {
                assert!(found.is_some());
            } else {
                assert_eq!(found, None, "{kept}");
            }
        }
    }

    #[test]
    fn text_beside_a_url_is_not_hidden_by_the_url() {
        for input in [
            "password: hunter2 https://u:p@h/db",
            "token=hunter2,https://u:p@h/db",
        ] {
            let (out, _) = Redactor::new().redact(input);
            assert!(!out.contains("hunter2"), "{input} -> {out}");
        }
        let (out, _) = Redactor::new().redact("DB_PASSWORD=postgres://u:pw@h/d");
        assert_eq!(out, "DB_PASSWORD=postgres://u:[redacted: url-password]@h/d");
    }

    #[test]
    fn key_state_follows_dropped_text() {
        assert!(private_key_open_after(
            "x -----BEGIN RSA PRIVATE KEY-----",
            false
        ));
        assert!(!private_key_open_after(
            "-----END RSA PRIVATE KEY-----",
            true
        ));
        assert!(!private_key_open_after(
            "-----BEGIN PRIVATE KEY----- -----END PRIVATE KEY-----",
            false
        ));
        assert!(private_key_open_after("body", true));
        assert!(!private_key_open_after("body", false));
    }

    #[test]
    fn an_unterminated_key_gives_up_after_the_bound_and_resumes_at_a_line_end() {
        let mut r = Redactor::new();
        let body = format!("{}\n", "A".repeat(1023));
        let (out, _) = r.redact(&format!(
            "-----BEGIN RSA PRIVATE KEY-----\n{}",
            body.repeat(70)
        ));
        assert!(!r.inside_private_key(), "gave up after the bound");
        assert!(out.contains(UNTERMINATED_MARKER));
        let (out, _) = r.redact("ordinary line\n");
        assert_eq!(out, "ordinary line\n");
    }
}
