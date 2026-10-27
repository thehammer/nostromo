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
//! A line can hold hidden runs in different roles (one standing for the
//! separator, one inside the secret: `curl<ZWSP>-u admin:QWKZ<ZWSP>XBNM`). The
//! text is read under four fixed assumptions (all runs dropped, all spaces, the
//! ambiguous ones spaces, the ones beside a word spaces). A group (a line, the
//! rows of a command continued with trailing backslashes, or the rows of a
//! `curl` command that an open quote carries on) with two or more hidden runs
//! that holds a credential word (a credential name, a token prefix, `Bearer`,
//! `curl`, ...) or personal data is also read **under every combination** of
//! "this run is a space / this run is nothing" for its first eight runs and,
//! for a line with more than eight, its last eight too (see `Reading`); one run
//! of a credential line is read as a space and as nothing by the fixed
//! readings. Runs in the middle of a line with more than sixteen are only read
//! under the fixed assumptions, and a line with more than eight never has its
//! first and its last run both read as a space. The combinations are paid for
//! per group out of a budget (`VIEW_BUDGET`; the groups with personal data have
//! a budget of their own), so padding before or after a line never takes them
//! away. A group whose readings do not fit what is left of its budget is **not
//! read with fewer views: it is redacted whole**, and nothing else of it is
//! read. A credential that ends right before a hidden run is extended to the
//! next real blank or the end of the line (`extend_over_hidden`): the run may
//! have been a character of the secret that the reading which found the
//! credential took for a space. The extra text is redacted too; leaking the
//! tail is worse.
//!
//! ## `curl` over several rows
//!
//! The end of a `curl` command is found with the shell's quoting in mind: a
//! `&`, `;` or `|` inside quotes does not end it (`curl 'https://h/?a=1&b=2'
//! -u user:pw`), a backslash escapes the next character, and a backslash at
//! the end of a row continues the command on the next one. The [`Redactor`]
//! remembers a call that ended inside such a command, so the continuation is
//! caught when it arrives in the next delivery. A `-u` password that ends in a
//! backslash goes on through the blank (or newline) it escapes
//! (`-u admin:QWKZXB\ NMVCFG`). The line assembler's clip mark `…` at the end
//! of a row counts like a trailing backslash (the cut-off rest may hold the
//! flag), a `$'…'` string has escapes, and a quote with no mate is an ordinary
//! character, so `curl: Couldn't connect` does not make the rows after it part
//! of a command.
//!
//! Known gaps: a fullwidth `；` folds to `;` and ends the command in the view
//! although the shell does not; an unquoted `curl $(a; b) -u ...` ends the
//! command at the `;` (the shell's command substitution is not parsed), so a
//! `-u` after it is not curl's here; a continuation inside the user part
//! (`-u admin\` newline `:pw`) or a newline inside a quoted password is not
//! followed; only the last 8 KiB of an open command's rows are carried to the
//! next delivery, so a flag further back than that is not seen there, and a
//! command that an open quote (not a trailing backslash) carries from one call
//! to the next is not carried at all. A snapshot scrolled so that `curl \` is
//! off-screen while its `-u admin:pw` row is on-screen cannot be caught either
//! (like a private-key block whose `BEGIN` has scrolled off): nothing on the
//! screen says the row belongs to a `curl` command.
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

    fn marker(self) -> &'static str {
        match self {
            Self::AwsAccessKey => "[redacted: aws-access-key]",
            Self::AwsSecretKey => "[redacted: aws-secret-key]",
            Self::BearerToken => "[redacted: bearer-token]",
            Self::ApiToken => "[redacted: api-token]",
            Self::SecretAssignment => "[redacted: secret-assignment]",
            Self::UrlPassword => "[redacted: url-password]",
            Self::PrivateKey => "[redacted: private-key]",
            Self::BasicAuth => "[redacted: basic-auth]",
            Self::Ssn => "[redacted: ssn]",
            Self::DateOfBirth => "[redacted: dob]",
        }
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
/// `text` is a view; `lower` is the dropped, lower-case text the view belongs
/// to (a superset test for literals: see [`Gate::passes`]).
type Scan = fn(&str, &Lowered, &mut Vec<Hit>);

/// What a text must hold for a rule to find anything in it.
enum Gate {
    /// One of these lower-case literals.
    Any(&'static [&'static str]),
    /// A dash and a digit (an SSN).
    DashAndDigit,
}

impl Gate {
    /// Whether the rule can find something in a text whose ASCII-lower-case
    /// form, hidden characters dropped, is `lower`. Any reading of the text
    /// (a hidden run as a space or as nothing) holds the literals of its
    /// dropped form, so a text that fails the gate needs no scan under any view.
    fn passes(&self, lower: &Lowered) -> bool {
        match self {
            Gate::Any(needles) => lower.holds_any(needles),
            Gate::DashAndDigit => self.passes_str(&lower.text),
        }
    }

    /// [`passes`](Gate::passes) for a short text.
    fn passes_str(&self, lower: &str) -> bool {
        match self {
            Gate::Any(needles) => holds_any(lower, needles),
            Gate::DashAndDigit => lower.contains('-') && lower.bytes().any(|b| b.is_ascii_digit()),
        }
    }
}

/// The rules for personal data: an SSN, a date of birth.
const PHI_GATES: [Gate; 2] = [Gate::DashAndDigit, Gate::Any(DOB_GATE)];

/// A text in ASCII lower case, ready for substring tests. A long one carries
/// the set of byte pairs it holds: a literal with a pair the text lacks is not
/// in it, which spares a search of a megabyte per literal.
struct Lowered {
    text: String,
    pairs: Option<Box<[u64; 1024]>>,
}

impl Lowered {
    /// Longer than this, a text gets its pair set.
    const FILTERED_FROM: usize = 4096;

    /// `text` in lower case: `text` is lowered in place.
    fn new(mut text: String) -> Lowered {
        text.make_ascii_lowercase();
        let pairs = (text.len() >= Self::FILTERED_FROM).then(|| {
            let mut set = Box::new([0u64; 1024]);
            let mut before = 0usize;
            for &byte in text.as_bytes() {
                let pair = (before << 8) | usize::from(byte);
                set[pair >> 6] |= 1 << (pair & 63);
                before = usize::from(byte);
            }
            set
        });
        Lowered { text, pairs }
    }

    fn holds_any(&self, needles: &[&str]) -> bool {
        needles.iter().any(|needle| {
            let possible = self.pairs.as_ref().is_none_or(|set| {
                needle.as_bytes().windows(2).all(|w| {
                    let pair = (usize::from(w[0]) << 8) | usize::from(w[1]);
                    set[pair >> 6] & (1 << (pair & 63)) != 0
                })
            });
            possible && self.text.contains(needle)
        })
    }
}

struct Scanner {
    gate: Gate,
    scan: Scan,
}

const URL_GATE: &[&str] = &["://"];
const AWS_SECRET_GATE: &[&str] = &["aws"];
const BEARER_GATE: &[&str] = &["bearer"];
/// The literals of [`TOKEN_SHAPES`] (a test keeps the two in step).
const TOKEN_GATE: &[&str] = &[
    "ghp_",
    "gho_",
    "ghu_",
    "ghs_",
    "ghr_",
    "github_pat_",
    "glpat-",
    "xox",
    "xapp-",
    "k_live_",
    "k_test_",
    "whsec_",
    "npm_",
    "aiza",
    "sk-",
    "eyj",
];
const AWS_KEY_GATE: &[&str] = &[
    "akia", "asia", "agpa", "aida", "aroa", "anpa", "anva", "aipa",
];
const AUTHORIZATION_GATE: &[&str] = &["authorization"];
/// The literals of [`CLI_CREDENTIALS`] and `curl` (a test keeps them in step).
const CLI_GATE: &[&str] = &[
    "curl",
    "mysql",
    "mariadb",
    "sshpass",
    "redis-cli",
    "zip",
    "7z",
    "rar",
    "docker",
    "ldap",
    "-pass",
];
const DOB_GATE: &[&str] = &["dob", "d.o.b", "birth", "born"];
/// The credential words of [`SECRET_NAME`].
const ASSIGNMENT_GATE: &[&str] = &[
    "pass",
    "pwd",
    "secret",
    "token",
    "key",
    "auth",
    "credential",
    "dsn",
];

/// Rules in priority order: when matches overlap, the earlier rule wins, so
/// `GITHUB_TOKEN=ghp_…` reports `api-token` (name kept) and
/// `AWS_SECRET_ACCESS_KEY=…` reports `aws-secret-key`, not
/// `secret-assignment`. The credential-name rule is last because it is the
/// broadest.
const SCANNERS: &[Scanner] = &[
    Scanner {
        gate: Gate::Any(URL_GATE),
        scan: scan_url_password,
    },
    Scanner {
        gate: Gate::Any(AWS_SECRET_GATE),
        scan: scan_aws_secret,
    },
    Scanner {
        gate: Gate::Any(BEARER_GATE),
        scan: scan_bearer,
    },
    Scanner {
        gate: Gate::Any(TOKEN_GATE),
        scan: scan_tokens,
    },
    Scanner {
        gate: Gate::Any(AWS_KEY_GATE),
        scan: scan_aws_access_key,
    },
    Scanner {
        gate: Gate::Any(AUTHORIZATION_GATE),
        scan: scan_authorization,
    },
    Scanner {
        gate: Gate::Any(CLI_GATE),
        scan: scan_cli_credentials,
    },
    Scanner {
        gate: Gate::DashAndDigit,
        scan: scan_ssn,
    },
    Scanner {
        gate: Gate::Any(DOB_GATE),
        scan: scan_dob,
    },
    Scanner {
        gate: Gate::Any(ASSIGNMENT_GATE),
        scan: scan_assignments,
    },
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
    /// Bit `n` of the mask decides the `n`th hidden run of each row group
    /// (see [`RowGroup`]): set is one space, clear is removed. The views of one
    /// group run through every mask up to the runs a group may read (see
    /// [`Reading`]).
    Mask(u32),
    /// Like [`Mask`](Hidden::Mask), counting the runs of each group from its
    /// end: for a group with more runs than a mask reaches.
    TailMask(u32),
}

/// Most hidden runs of one row group whose every combination is read (the
/// first ones and the last ones of a longer group).
const MAX_MASK_RUNS: usize = 8;

/// Most bytes of view text (each view also counts [`VIEW_OVERHEAD`]) one call
/// builds to read the row groups that hold a credential word and hidden runs,
/// all such groups together; the groups that hold personal data (see
/// [`PHI_GATES`]) have a budget of their own. A group that would take more
/// than what is left is not read: it is redacted whole (see [`Reading`]). A
/// megabyte of such lines is therefore read for its first few hundred KiB and
/// redacted after.
const VIEW_BUDGET: usize = 1 << 20;

/// What a view costs before its first byte, in bytes of text: a flood of short
/// lines must not get a view each for free.
const VIEW_OVERHEAD: usize = 64;

/// Tools whose command lines hold a password, rare enough as words that their
/// letters in a text are worth a careful reading (see
/// [`holds_credential_word`]).
const TOOL_WORDS: &[&str] = &["curl", "mysql", "mariadb", "sshpass", "redis-cli"];

/// Tools with names that are also the end of an ordinary word (`library`,
/// `gzip`): only at the start of a word.
const SHORT_TOOL_WORDS: &[&str] = &["unzip", "zip", "unrar", "rar", "7z", "docker", "ldap"];

/// A set of literals, found by the byte each starts with: a pass over a short
/// text, not a search per literal.
struct Needles {
    by_first: Vec<Vec<&'static str>>,
}

impl Needles {
    fn new(lists: &[&[&'static str]]) -> Needles {
        let mut by_first = vec![Vec::new(); 256];
        for needle in lists.iter().flat_map(|list| list.iter()) {
            if let Some(&first) = needle.as_bytes().first() {
                by_first[usize::from(first)].push(*needle);
            }
        }
        Needles { by_first }
    }

    /// The offsets in `text` where a needle starts.
    fn starts_in<'t>(&'t self, text: &'t str) -> impl Iterator<Item = usize> + 't {
        let bytes = text.as_bytes();
        (0..bytes.len()).filter(move |&at| {
            self.by_first[usize::from(bytes[at])]
                .iter()
                .any(|needle| bytes[at..].starts_with(needle.as_bytes()))
        })
    }
}

/// The credential literals that count wherever they are: credential names,
/// token and key id prefixes, `Bearer`, and the names of tools that are rare as
/// words.
static CREDENTIAL_NEEDLES: LazyLock<Needles> = LazyLock::new(|| {
    Needles::new(&[
        ASSIGNMENT_GATE,
        TOKEN_GATE,
        AWS_KEY_GATE,
        BEARER_GATE,
        TOOL_WORDS,
    ])
});

static SHORT_TOOL_NEEDLES: LazyLock<Needles> = LazyLock::new(|| Needles::new(&[SHORT_TOOL_WORDS]));

/// Whether a group, which reads `dropped` in ASCII lower case with its hidden
/// characters dropped (`spaced` is the same with each run a space, built only
/// when asked), holds a literal one of the rules that read credentials needs: a
/// credential name, a token prefix, a key id prefix, `Bearer`, or the name of a
/// tool whose command lines hold a password. A short tool name counts at the
/// start of a word (`library` is not `rar`); a hidden run may be the blank
/// before it (`xyz<ZWSP>rar`) or split the name, and then the name counts.
fn holds_credential_word(dropped: &str, spaced: impl FnOnce() -> String) -> bool {
    if CREDENTIAL_NEEDLES.starts_in(dropped).next().is_some() {
        return true;
    }
    if SHORT_TOOL_NEEDLES.starts_in(dropped).next().is_none() {
        return false;
    }
    let spaced = spaced();
    SHORT_TOOL_WORDS.iter().any(|word| {
        if !dropped.contains(word) {
            return false;
        }
        let mut seen = false;
        for (at, _) in spaced.match_indices(word) {
            seen = true;
            let glued =
                prev_char(&spaced, at).is_some_and(|c| c.is_ascii_alphanumeric() || c == '_');
            if !glued {
                return true;
            }
        }
        // Not in the spaced text at all: a hidden run splits it.
        !seen
    })
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

/// Printable ASCII, a tab or a carriage return: a byte the views read as it
/// is.
fn is_simple(b: u8) -> bool {
    matches!(b, 0x20..=0x7e | b'\t' | b'\r')
}

/// ASCII text with no hidden character or odd blank: its own view.
fn is_plain(text: &str) -> bool {
    // A newline is plain too (the other layout characters are not).
    text.bytes().all(|b| is_simple(b) || b == b'\n')
}

/// A stretch of the original text, folded. A hidden character is kept (as a
/// space) so the views can decide what it was.
enum Piece {
    /// Simple ASCII (see [`is_simple`]): one view character per byte. A
    /// stretch never holds a newline, so a row break is always a [`Char`].
    ///
    /// [`Char`]: Piece::Char
    Ascii(Range<usize>),
    /// One folded character and the original bytes it came from.
    Char {
        c: char,
        origin: (usize, usize),
        hidden: bool,
    },
}

impl Piece {
    fn is_hidden(&self) -> bool {
        matches!(self, Piece::Char { hidden: true, .. })
    }

    /// The original bytes of the piece.
    fn origin(&self) -> (usize, usize) {
        match self {
            Piece::Ascii(range) => (range.start, range.end),
            Piece::Char { origin, .. } => *origin,
        }
    }

    fn first_char(&self, text: &str) -> Option<char> {
        match self {
            Piece::Ascii(range) => text[range.clone()].chars().next(),
            Piece::Char { c, .. } => Some(*c),
        }
    }

    fn last_char(&self, text: &str) -> Option<char> {
        match self {
            Piece::Ascii(range) => text[range.clone()].chars().next_back(),
            Piece::Char { c, .. } => Some(*c),
        }
    }
}

fn fold(text: &str) -> Vec<Piece> {
    let bytes = text.as_bytes();
    let mut pieces = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        let mut end = at;
        while end < bytes.len() && is_simple(bytes[end]) {
            end += 1;
        }
        if end > at {
            pieces.push(Piece::Ascii(at..end));
            at = end;
            continue;
        }
        let Some(c) = text[at..].chars().next() else {
            break;
        };
        let origin = (at, at + c.len_utf8());
        at = origin.1;
        let mut piece = |c: char, hidden: bool| pieces.push(Piece::Char { c, origin, hidden });
        if is_hidden(c) {
            piece(' ', true);
        } else if is_odd_blank(c) {
            piece(' ', false);
        } else if c.is_ascii() || c == '…' {
            // The ellipsis stays one character: NFKC would spell it `...`, and
            // the clip mark the line assembler ends a cut row with must be
            // recognisable (see `command_end`).
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

/// The rows of one command: a row that ends in a backslash (or the assembler's
/// clip mark) continues on the next. A hidden run is numbered within its group,
/// so the rows of a continued command are read as one line.
#[derive(Default)]
struct RowGroup {
    /// The last visible character of the current row.
    last: Option<char>,
    /// Number of the current group.
    index: usize,
}

impl RowGroup {
    /// Take the next visible character; whether it starts a new group.
    fn see(&mut self, c: char) -> bool {
        if c != '\n' {
            if !c.is_whitespace() {
                self.last = Some(c);
            }
            return false;
        }
        let ends = !matches!(self.last.take(), Some('\\' | '…'));
        if ends {
            self.index += 1;
        }
        ends
    }

    /// Take the next visible piece of `text`; whether it starts a new group.
    fn see_piece(&mut self, text: &str, piece: &Piece) -> bool {
        match piece {
            Piece::Ascii(range) => {
                let row = text[range.clone()].trim_end_matches([' ', '\t', '\r']);
                if let Some(c) = row.chars().next_back() {
                    self.last = Some(c);
                }
                false
            }
            Piece::Char { c, .. } => self.see(*c),
        }
    }
}

/// How many hidden runs each row group holds (runs are separated by visible
/// characters), for every group of the text.
fn runs_per_group(text: &str, pieces: &[Piece]) -> Vec<u32> {
    let mut counts = vec![0u32];
    let mut group = RowGroup::default();
    let mut in_run = false;
    for piece in pieces {
        if piece.is_hidden() {
            if !in_run {
                if let Some(count) = counts.last_mut() {
                    *count += 1;
                }
            }
            in_run = true;
        } else {
            in_run = false;
            if group.see_piece(text, piece) {
                counts.push(0);
            }
        }
    }
    counts
}

/// One row group of a text (see [`RowGroup`]): its pieces, the newline that
/// ends it included, and how many hidden runs they hold.
struct Row {
    pieces: Range<usize>,
    runs: u32,
}

/// Every row group of `pieces`, in order.
fn row_groups(text: &str, pieces: &[Piece]) -> Vec<Row> {
    let mut rows = Vec::new();
    let mut group = RowGroup::default();
    let (mut start, mut runs, mut in_run) = (0, 0u32, false);
    for (i, piece) in pieces.iter().enumerate() {
        if piece.is_hidden() {
            if !in_run {
                runs += 1;
            }
            in_run = true;
            continue;
        }
        in_run = false;
        if group.see_piece(text, piece) {
            rows.push(Row {
                pieces: start..i + 1,
                runs,
            });
            start = i + 1;
            runs = 0;
        }
    }
    if start < pieces.len() {
        rows.push(Row {
            pieces: start..pieces.len(),
            runs,
        });
    }
    rows
}

/// Where a stretch of a view came from: view bytes `view..` read original bytes
/// `orig..end`. A `linear` stretch is one view byte per original byte; the
/// other is one character, however many bytes either side spells it with.
struct Origin {
    view: usize,
    orig: usize,
    end: usize,
    linear: bool,
}

/// A normalised copy of a text. `origins` is `None` for the identity view of
/// plain ASCII text, else the stretches of the view in order.
struct View<'a> {
    text: Cow<'a, str>,
    origins: Option<Vec<Origin>>,
}

impl<'a> View<'a> {
    /// The identity view of a plain text.
    fn identity(text: &'a str) -> View<'a> {
        View {
            text: Cow::Borrowed(text),
            origins: None,
        }
    }

    /// The views to read where a `curl` command ends: the dropped view, the
    /// space-reading views, and every combination of the first (and, for a
    /// text with more, the last) hidden runs of each row group that the budget
    /// allows. `None` when it allows fewer than the text holds: the caller
    /// must then assume the worst.
    fn for_command(text: &'a str) -> Option<Vec<View<'a>>> {
        if is_plain(text) {
            return Some(vec![View::identity(text)]);
        }
        let pieces = fold(text);
        let totals = runs_per_group(text, &pieces);
        let mut modes = vec![Hidden::Dropped];
        if pieces.iter().any(Piece::is_hidden) {
            modes.extend([
                Hidden::EverySpaced,
                Hidden::AmbiguousSpaced,
                Hidden::AtWords,
            ]);
            let most = totals.iter().copied().max().unwrap_or(0) as usize;
            let tails = most > MAX_MASK_RUNS;
            let wanted = most.min(MAX_MASK_RUNS);
            let views = if tails { 2 } else { 1 };
            let runs = (0..=wanted)
                .rev()
                .find(|&runs| text.len().saturating_mul(views << runs) <= VIEW_BUDGET)
                .unwrap_or(0);
            if runs < wanted {
                return None;
            }
            modes.extend((1..1u32 << runs).map(Hidden::Mask));
            if tails {
                modes.extend((1..1u32 << runs).map(Hidden::TailMask));
            }
        }
        let mut views: Vec<View<'a>> = Vec::with_capacity(modes.len());
        for mode in modes {
            let view = View::from_pieces(text, &pieces, mode, &totals, &[]);
            if !views.iter().any(|v| v.text == view.text) {
                views.push(view);
            }
        }
        Some(views)
    }

    fn build(text: &str, mode: Hidden) -> View<'static> {
        View::from_pieces(text, &fold(text), mode, &[], &[])
    }

    /// The view of `pieces` (of `text`) under `mode`, leaving out the piece
    /// ranges in `skip` (sorted, apart): they are redacted without being read.
    fn from_pieces(
        text: &str,
        pieces: &[Piece],
        mode: Hidden,
        totals: &[u32],
        skip: &[Range<usize>],
    ) -> View<'static> {
        let mut view = ViewBuilder {
            text: String::with_capacity(text.len()),
            origins: Vec::new(),
        };
        let mut skips = skip.iter().peekable();
        let mut i = 0;
        // Hidden runs seen in the current row group.
        let mut group = RowGroup::default();
        let mut group_run = 0u32;
        while let Some(piece) = pieces.get(i) {
            if let Some(range) = skips.next_if(|r| r.start <= i) {
                i = i.max(range.end);
                continue;
            }
            match piece {
                Piece::Ascii(range) => {
                    group.see_piece(text, piece);
                    view.push_ascii(&text[range.clone()], range.start);
                    i += 1;
                    continue;
                }
                Piece::Char {
                    c,
                    origin,
                    hidden: false,
                } => {
                    if group.see(*c) {
                        group_run = 0;
                    }
                    view.push_char(*c, *origin);
                    i += 1;
                    continue;
                }
                Piece::Char { .. } => {}
            }
            let mut j = i;
            while pieces.get(j).is_some_and(Piece::is_hidden) {
                j += 1;
            }
            let first = piece.origin().0;
            let last = pieces.get(j - 1).map_or(piece.origin().1, |p| p.origin().1);
            let before = i
                .checked_sub(1)
                .and_then(|k| pieces.get(k))
                .and_then(|p| p.last_char(text));
            let after = pieces.get(j).and_then(|p| p.first_char(text));
            let space = match mode {
                Hidden::Dropped => false,
                Hidden::EverySpaced => true,
                Hidden::Mask(bits) => bits.checked_shr(group_run).is_some_and(|b| b & 1 == 1),
                Hidden::TailMask(bits) => totals
                    .get(group.index)
                    .and_then(|total| total.checked_sub(group_run + 1))
                    .and_then(|from_end| bits.checked_shr(from_end))
                    .is_some_and(|b| b & 1 == 1),
                Hidden::AmbiguousSpaced | Hidden::AtWords => match (before, after) {
                    (Some(b), Some(a)) if is_ambiguous(b, a) => {
                        mode == Hidden::AmbiguousSpaced
                            || b.is_ascii_alphabetic() != a.is_ascii_alphabetic()
                    }
                    _ => false,
                },
            };
            if space {
                view.push_char(' ', (first, last));
            }
            group_run = group_run.saturating_add(1);
            i = j;
        }
        View {
            text: Cow::Owned(view.text),
            origins: Some(view.origins),
        }
    }

    /// The range of the original text covering `range` of the view.
    fn to_original(&self, range: Range<usize>) -> Option<Range<usize>> {
        let Some(origins) = &self.origins else {
            return Some(range);
        };
        let first = &origins[origins
            .partition_point(|o| o.view <= range.start)
            .checked_sub(1)?];
        let last = &origins[origins
            .partition_point(|o| o.view < range.end)
            .checked_sub(1)?];
        let start = if first.linear {
            first.orig + (range.start - first.view)
        } else {
            first.orig
        };
        let end = if last.linear {
            last.orig + (range.end - last.view)
        } else {
            last.end
        };
        (start < end).then_some(start..end)
    }

    /// The offset in the original text that the view byte `at` reads.
    fn source_offset(&self, at: usize) -> Option<usize> {
        let Some(origins) = &self.origins else {
            return Some(at);
        };
        let origin = &origins[origins.partition_point(|o| o.view <= at).checked_sub(1)?];
        Some(if origin.linear {
            origin.orig + (at - origin.view)
        } else {
            origin.orig
        })
    }

    /// The part of the view that reads the original bytes `from..to`, as a
    /// range of the view: the characters that lie wholly inside.
    fn view_span(&self, from: usize, to: usize) -> Range<usize> {
        let Some(origins) = &self.origins else {
            return from..to;
        };
        let len = self.text.len();
        // The first character that starts at `from` or later.
        let lo = origins.partition_point(|o| o.end <= from);
        let lo = match origins.get(lo) {
            Some(o) if o.linear => o.view + from.saturating_sub(o.orig),
            Some(o) if o.orig >= from => o.view,
            Some(_) => origins.get(lo + 1).map_or(len, |next| next.view),
            None => len,
        };
        // The first character that ends after `to`.
        let hi = origins.partition_point(|o| o.end <= to);
        let hi = match origins.get(hi) {
            Some(o) if o.linear => o.view + to.saturating_sub(o.orig),
            Some(o) => o.view,
            None => len,
        };
        lo..hi.max(lo)
    }
}

/// A view under construction.
struct ViewBuilder {
    text: String,
    origins: Vec<Origin>,
}

impl ViewBuilder {
    /// Simple ASCII from original byte `orig`, kept as it is.
    fn push_ascii(&mut self, ascii: &str, orig: usize) {
        let view = self.text.len();
        self.text.push_str(ascii);
        match self.origins.last_mut() {
            Some(last)
                if last.linear
                    && last.end == orig
                    && last.view + (last.end - last.orig) == view =>
            {
                last.end += ascii.len();
            }
            _ => self.origins.push(Origin {
                view,
                orig,
                end: orig + ascii.len(),
                linear: true,
            }),
        }
    }

    /// `c`, read from the original bytes `origin`.
    fn push_char(&mut self, c: char, origin: (usize, usize)) {
        if c.is_ascii() && origin.1 == origin.0 + 1 {
            // One byte for one byte, like the stretches.
            let mut buf = [0u8; 4];
            self.push_ascii(c.encode_utf8(&mut buf), origin.0);
            return;
        }
        self.origins.push(Origin {
            view: self.text.len(),
            orig: origin.0,
            end: origin.1,
            linear: false,
        });
        self.text.push(c);
    }
}

/// What the rules read in a text, and what is redacted without being read.
///
/// A hidden run can be a separator (`curl<ZWSP>-u`) or part of a word
/// (`QWKZ<ZWSP>XBNM`), and only the reader of the text knows which, so a text
/// with hidden characters is read under several readings: all runs dropped,
/// all spaces, the ambiguous ones spaces, the ones beside a word spaces. A
/// **group** (a line, the rows of a command continued with trailing
/// backslashes, and the rows of a `curl` command that an open quote carries on)
/// that holds a credential word and a hidden run is also read under **every
/// combination** of "this run is a space / is nothing" for its first eight runs
/// and, with more than eight, its last eight too: one run can be the separator
/// and another part of the secret on the same line.
///
/// The rest of the text is read as a whole, and the groups are read one at a
/// time, each paying for its own readings out of [`VIEW_BUDGET`] (groups with
/// personal data and two or more hidden runs: out of a budget of their own):
/// padding before or after a line does not take them away, and a line without
/// a credential word costs nothing extra.
///
/// A group whose readings do not fit the rest of its budget is **not read with
/// fewer views**: it is redacted whole and left out of the other views.
struct Reading<'a> {
    /// Views of the text outside the groups read one at a time.
    whole: Vec<View<'a>>,
    /// `whole` in ASCII lower case, hidden characters dropped (see [`Gate`]).
    lower: Lowered,
    /// The views of single groups.
    groups: Vec<GroupViews>,
    /// Ranges of the original text redacted whole, and as what.
    closed: Vec<(Range<usize>, RedactionKind)>,
}

/// The views of one group.
struct GroupViews {
    /// The group in ASCII lower case, hidden characters dropped.
    lower: Lowered,
    views: Vec<View<'static>>,
}

impl<'a> Reading<'a> {
    fn new(text: &'a str) -> Reading<'a> {
        if is_plain(text) {
            return Reading {
                whole: vec![View::identity(text)],
                lower: Lowered::new(text.to_owned()),
                groups: Vec::new(),
                closed: Vec::new(),
            };
        }
        let pieces = fold(text);
        let rows = row_groups(text, &pieces);
        let hidden_rows = rows.iter().filter(|row| row.runs > 0).count();
        let mut dropped = View::from_pieces(text, &pieces, Hidden::Dropped, &[], &[]);
        let mut lower = Lowered::new(dropped.text.to_string());
        let mut groups = Vec::new();
        let mut closed = Vec::new();
        // The pieces of the groups left out of the whole-text views, and how
        // many of the rows with hidden runs they hold.
        let mut skip = Vec::new();
        let mut hidden_rows_apart = 0;
        // A text with no credential word and no personal data shape has no
        // group to read one at a time.
        let credentials = hidden_rows > 0 && possibly_holds_credential_word(&lower);
        let personal = hidden_rows > 0 && PHI_GATES.iter().any(|g| g.passes(&lower));
        if credentials || personal {
            let mut budget = VIEW_BUDGET;
            let mut personal_budget = VIEW_BUDGET;
            let mut scratch = String::new();
            for group in command_groups(&rows, &pieces, &dropped, &lower.text) {
                let several: Vec<u32>;
                let runs: &[u32] = if group.len() == 1 {
                    std::slice::from_ref(&rows[group.start].runs)
                } else {
                    several = rows[group.clone()].iter().map(|row| row.runs).collect();
                    &several
                };
                let most = runs.iter().copied().max().unwrap_or(0);
                if most == 0 {
                    continue;
                }
                let span = rows[group.start].pieces.start..rows[group.end - 1].pieces.end;
                let slice = &pieces[span.clone()];
                scratch.clear();
                push_dropped(&mut scratch, text, slice);
                scratch.make_ascii_lowercase();
                let credential = holds_credential_word(&scratch, || {
                    let mut spaced = String::new();
                    push_spaced(&mut spaced, text, slice);
                    spaced.make_ascii_lowercase();
                    spaced
                });
                // Two runs are what a combination can tell apart from the
                // fixed readings (one run is a space or nothing).
                let personal = !credential
                    && most >= 2
                    && PHI_GATES.iter().any(|gate| gate.passes_str(&scratch));
                if !credential && !personal {
                    continue;
                }
                let each = scratch.len() + VIEW_OVERHEAD;
                let budget = if credential {
                    &mut budget
                } else {
                    &mut personal_budget
                };
                // A group with one run stays in the whole-text views, which
                // read it as a space and as nothing: it pays for those two.
                // A group with personal data stays there too, and pays for the
                // combinations only.
                let views = if credential && most == 1 {
                    (each * 2 <= *budget).then(|| {
                        *budget -= each * 2;
                        Vec::new()
                    })
                } else {
                    let readings = if credential {
                        Readings::All
                    } else {
                        Readings::Combinations
                    };
                    group_views(text, slice, runs, scratch.len(), readings, budget)
                };
                let apart = credential && most >= 2;
                match views {
                    Some(views) if !apart => {
                        if !views.is_empty() {
                            groups.push(GroupViews {
                                lower: Lowered::new(scratch.clone()),
                                views,
                            });
                        }
                        continue;
                    }
                    Some(views) => groups.push(GroupViews {
                        lower: Lowered::new(scratch.clone()),
                        views,
                    }),
                    None => {
                        let kind = if credential {
                            RedactionKind::SecretAssignment
                        } else if Gate::Any(DOB_GATE).passes_str(&scratch) {
                            RedactionKind::DateOfBirth
                        } else {
                            RedactionKind::Ssn
                        };
                        // The newline that ends the group stays a separator.
                        let ends_in_newline = matches!(
                            slice.last(),
                            Some(Piece::Char {
                                c: '\n',
                                hidden: false,
                                ..
                            })
                        );
                        let kept = span.start..span.end - usize::from(ends_in_newline);
                        if !kept.is_empty() {
                            let origin =
                                pieces[kept.start].origin().0..pieces[kept.end - 1].origin().1;
                            closed.push((origin, kind));
                            skip.push(kept);
                            hidden_rows_apart += runs.iter().filter(|&&n| n > 0).count();
                        }
                        continue;
                    }
                }
                // Read one at a time: left out of the whole-text views.
                let ends_in_newline = matches!(
                    slice.last(),
                    Some(Piece::Char {
                        c: '\n',
                        hidden: false,
                        ..
                    })
                );
                let kept = span.start..span.end - usize::from(ends_in_newline);
                if !kept.is_empty() {
                    skip.push(kept);
                    hidden_rows_apart += runs.iter().filter(|&&n| n > 0).count();
                }
            }
            if !skip.is_empty() {
                dropped = View::from_pieces(text, &pieces, Hidden::Dropped, &[], &skip);
                lower = Lowered::new(dropped.text.to_string());
            }
        }
        let mut whole = vec![dropped];
        // The other readings differ from the dropped one only at hidden runs,
        // and they hold no literal it does not hold.
        if hidden_rows > hidden_rows_apart && SCANNERS.iter().any(|s| s.gate.passes(&lower)) {
            for mode in FIXED_READINGS {
                let view = View::from_pieces(text, &pieces, mode, &[], &skip);
                if !whole.iter().any(|v| v.text == view.text) {
                    whole.push(view);
                }
            }
        }
        Reading {
            whole,
            lower,
            groups,
            closed,
        }
    }

    /// The views a rule with `gate` can find something on, each with the
    /// lower-case text it belongs to.
    fn views_for<'s>(
        &'s self,
        gate: &'s Gate,
    ) -> impl Iterator<Item = (&'s View<'a>, &'s Lowered)> + 's {
        let whole: &[View<'a>] = if gate.passes(&self.lower) {
            &self.whole
        } else {
            &[]
        };
        let lower = &self.lower;
        whole.iter().map(move |view| (view, lower)).chain(
            self.groups
                .iter()
                .filter(move |g| gate.passes(&g.lower))
                .flat_map(|g| g.views.iter().map(move |view| (view, &g.lower))),
        )
    }
}

/// The readings of hidden runs other than dropping them all.
const FIXED_READINGS: [Hidden; 3] = [
    Hidden::EverySpaced,
    Hidden::AmbiguousSpaced,
    Hidden::AtWords,
];

/// Whether a text (dropped, lower case) can hold something
/// [`holds_credential_word`] finds: a cheap test for a megabyte, which says
/// yes more often than the exact one.
fn possibly_holds_credential_word(lower: &Lowered) -> bool {
    lower.holds_any(ASSIGNMENT_GATE)
        || lower.holds_any(TOKEN_GATE)
        || lower.holds_any(AWS_KEY_GATE)
        || lower.holds_any(BEARER_GATE)
        || lower.holds_any(TOOL_WORDS)
        || lower.holds_any(SHORT_TOOL_WORDS)
}

/// The groups of `rows` (as ranges of row numbers): the rows of one `curl`
/// command (found on the dropped view, where an open quote carries the command
/// over a line break, as it does for the rule), and every other row alone.
/// `lower` is the dropped view in ASCII lower case. Every `curl` counts, even
/// one glued to the word before it (`xyz<ZWSP>curl`): a reading with the run as
/// a space makes it a command.
fn command_groups(
    rows: &[Row],
    pieces: &[Piece],
    dropped: &View,
    lower: &str,
) -> Vec<Range<usize>> {
    let mut links: Vec<(usize, usize)> = Vec::new();
    // Where each row starts in the original text.
    let starts: Vec<usize> = rows
        .iter()
        .map(|row| pieces[row.pieces.start].origin().0)
        .collect();
    let row_at = |offset: usize| starts.partition_point(|&s| s <= offset).saturating_sub(1);
    let mut scanned_to = 0;
    for (curl, _) in lower.match_indices("curl") {
        if curl < scanned_to {
            continue;
        }
        let end = command_end(&dropped.text, curl + "curl".len());
        scanned_to = end;
        // A command on one line needs no looking up.
        if !dropped.text[curl..end].contains('\n') {
            continue;
        }
        let first = dropped.source_offset(curl);
        let last = dropped.source_offset(end.saturating_sub(1).max(curl));
        if let (Some(first), Some(last)) = (first, last) {
            let (first, last) = (row_at(first), row_at(last));
            if last > first {
                links.push((first, last));
            }
        }
    }
    let mut groups = Vec::new();
    let (mut at, mut next) = (0, 0);
    while at < rows.len() {
        let mut end = at + 1;
        // A command that starts inside the group so far carries it on.
        while let Some(&(_, last)) = links.get(next).filter(|link| link.0 < end) {
            end = end.max(last + 1);
            next += 1;
        }
        groups.push(at..end);
        at = end;
    }
    groups
}

/// Append `pieces` of `text` to `out`, the hidden characters dropped.
fn push_dropped(out: &mut String, text: &str, pieces: &[Piece]) {
    for piece in pieces {
        match piece {
            Piece::Ascii(range) => out.push_str(&text[range.clone()]),
            Piece::Char {
                c, hidden: false, ..
            } => out.push(*c),
            Piece::Char { .. } => {}
        }
    }
}

/// Append `pieces` of `text` to `out`, each hidden run one space.
fn push_spaced(out: &mut String, text: &str, pieces: &[Piece]) {
    let mut in_run = false;
    for piece in pieces {
        match piece {
            Piece::Ascii(range) => out.push_str(&text[range.clone()]),
            Piece::Char {
                c, hidden: false, ..
            } => out.push(*c),
            Piece::Char { .. } if !in_run => out.push(' '),
            Piece::Char { .. } => {}
        }
        in_run = piece.is_hidden();
    }
}

/// Which readings of a group to build.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Readings {
    /// The fixed readings and every combination of runs.
    All,
    /// Every combination of runs: the whole text has the fixed readings.
    Combinations,
}

/// The readings of one group (`slice`; `totals` the hidden runs of each of its
/// rows, `len` bytes of text with them dropped). `None` when they would cost
/// more than `budget`, which they then leave alone.
fn group_views(
    text: &str,
    slice: &[Piece],
    totals: &[u32],
    len: usize,
    readings: Readings,
    budget: &mut usize,
) -> Option<Vec<View<'static>>> {
    let most = totals.iter().copied().max().unwrap_or(0) as usize;
    let tails = most > MAX_MASK_RUNS;
    let reach = most.min(MAX_MASK_RUNS);
    let full = (1u32 << reach) - 1;
    // Setting every run of a group of up to eight is the all-spaces reading.
    let heads = (1..=full).filter(move |&bits| tails || bits != full);
    let ends = (1..=full).filter(move |_| tails);
    let fixed: &[Hidden] = if readings == Readings::All {
        &[
            Hidden::Dropped,
            Hidden::EverySpaced,
            Hidden::AmbiguousSpaced,
            Hidden::AtWords,
        ]
    } else {
        &[]
    };
    // Counted before any is built: a flood of groups too dear to read must not
    // cost a list of modes each.
    let count =
        fixed.len() + full as usize - usize::from(!tails) + if tails { full as usize } else { 0 };
    let each = len + VIEW_OVERHEAD;
    if count.saturating_mul(each) > *budget {
        return None;
    }
    let modes = fixed
        .iter()
        .copied()
        .chain(heads.map(Hidden::Mask))
        .chain(ends.map(Hidden::TailMask));
    let mut seen = std::collections::HashSet::new();
    let mut views = Vec::new();
    for mode in modes {
        let view = View::from_pieces(text, slice, mode, totals, &[]);
        if seen.insert(view.text.to_string()) {
            views.push(view);
        }
    }
    *budget -= views.len() * each;
    Some(views)
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

/// Whether `lower` (a text in ASCII lower case) holds one of `needles`, the
/// literals a rule's pattern cannot match without. A plain substring search is
/// far cheaper than the pattern, so a scanner asks this first and skips its
/// regexes on a text that has none of them (a megabyte of output rarely does).
fn holds_any(lower: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| lower.contains(needle))
}

// ───────────────────────────── URL passwords ─────────────────────────────────

/// `scheme://user:password@host`. The user stops at the first `:`; the
/// password runs to the LAST `@` of the run (it may hold `@` and `/`), so
/// `postgres://u:p@ss@host/db` and `postgres://u:pa/ss@host/db` are covered.
/// The run stops at whitespace and quote characters.
static URL_PASSWORD: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?i)[a-z][a-z0-9+.\-]*://[^\s:/"'`<>]*:(?P<value>[^\s"'`<>]+)@"#));

fn scan_url_password(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
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

fn scan_aws_secret(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
    scan_value_group(&AWS_SECRET, RedactionKind::AwsSecretKey, text, hits);
}

static AWS_KEY_ID_UPPER: LazyLock<Regex> = LazyLock::new(|| {
    Anchor::NotUpperDigit.compile(r"(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}")
});
static AWS_KEY_ID_LOWER: LazyLock<Regex> = LazyLock::new(|| {
    Anchor::NotLowerDigit.compile(r"(?:akia|asia|agpa|aida|aroa|anpa|anva|aipa)[a-z0-9]{16}")
});

fn scan_aws_access_key(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
    let kind = RedactionKind::AwsAccessKey;
    scan_shape(&AWS_KEY_ID_UPPER, true, kind, text, hits);
    scan_shape(&AWS_KEY_ID_LOWER, true, kind, text, hits);
}

// ───────────────────────────── tokens ────────────────────────────────────────

static BEARER: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?i)\bbearer[ \t]+(?P<value>[A-Za-z0-9._~+/=\-]{8,})"));

fn scan_bearer(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
    scan_value_group(&BEARER, RedactionKind::BearerToken, text, hits);
}

/// Provider token shapes: the lower-case literals one of which a token holds
/// (see [`holds_any`]), and the pattern with the anchor it needs.
static TOKEN_SHAPES: LazyLock<Vec<(&'static [&'static str], Regex)>> = LazyLock::new(|| {
    let shapes: [(&[&str], &str, Anchor); 11] = [
        (
            &["ghp_", "gho_", "ghu_", "ghs_", "ghr_"],
            r"(?i)gh[pousr]_[A-Za-z0-9]{20,}",
            Anchor::Open,
        ),
        (
            &["github_pat_"],
            r"(?i)github_pat_[A-Za-z0-9_]{20,}",
            Anchor::Open,
        ),
        (
            &["glpat-"],
            r"(?i)glpat-[A-Za-z0-9_\-]{20,}",
            Anchor::NotAlnum,
        ),
        (
            &["xox"],
            r"(?i)xox[abeprs]-[A-Za-z0-9\-]{10,}",
            Anchor::NotAlnum,
        ),
        (&["xapp-"], r"(?i)xapp-[A-Za-z0-9\-]{10,}", Anchor::NotAlnum),
        (
            &["k_live_", "k_test_", "whsec_"],
            r"(?i)(?:[sr]k_(?:live|test)|pk_live|whsec)_[A-Za-z0-9]{8,}",
            Anchor::NotAlnum,
        ),
        (&["npm_"], r"(?i)npm_[A-Za-z0-9]{30,}", Anchor::NotAlnum),
        (&["aiza"], r"AIza[A-Za-z0-9_\-]{35}", Anchor::NotAlnum),
        (&["sk-ant-"], r"sk-ant-[A-Za-z0-9_\-]{8,}", Anchor::NotAlnum),
        (&["sk-"], r"sk-[A-Za-z0-9_\-]{20,}", Anchor::NotAlnum),
        (
            &["eyj"],
            r"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*",
            Anchor::NotAlnum,
        ),
    ];
    shapes
        .into_iter()
        .map(|(needles, pattern, anchor)| (needles, anchor.compile(pattern)))
        .collect()
});

fn scan_tokens(text: &str, lower: &Lowered, hits: &mut Vec<Hit>) {
    for (needles, pattern) in TOKEN_SHAPES.iter() {
        if !lower.holds_any(needles) {
            continue;
        }
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
fn scan_authorization(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
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
static CLI_CREDENTIALS: LazyLock<Vec<(&'static [&'static str], Regex)>> = LazyLock::new(|| {
    let rest = r"[^\n|;&]*?";
    // Each pattern with the lower-case literals one of which its command holds
    // (see [`holds_any`]).
    let rules: [(&[&str], String); 8] = [
        // mysql -pSECRET (the password is attached; `-p` alone prompts)
        (
            &["mysql", "mariadb"],
            format!(
                r#"(?i)\b(?:mysql|mysqldump|mysqladmin|mysqlcheck|mysqlimport|mysqlshow|mariadb|mariadb-dump)\b{rest}[ \t](?-i:-p)(?P<value>[^\s\-]\S*)"#
            ),
        ),
        // sshpass -p SECRET / -pSECRET
        (
            &["sshpass"],
            format!(r#"(?i)\bsshpass\b{rest}[ \t](?-i:-p)[ \t]*(?P<value>{ARG})"#),
        ),
        // redis-cli -a SECRET
        (
            &["redis-cli"],
            format!(r#"(?i)\bredis-cli\b{rest}[ \t](?-i:-a)[ \t]+(?P<value>{ARG})"#),
        ),
        // unzip -P SECRET
        (
            &["zip"],
            format!(r#"(?i)\b(?:unzip|zip)\b{rest}[ \t](?-i:-P)[ \t]*(?P<value>{ARG})"#),
        ),
        // 7z -pSECRET
        (
            &["7z", "rar"],
            format!(r#"(?i)\b(?:7z|7za|7zr|rar|unrar)\b{rest}[ \t](?-i:-p)(?P<value>[^\s\-]\S*)"#),
        ),
        // docker login -u u -p SECRET
        (
            &["docker"],
            format!(r#"(?i)\bdocker\b{rest}\blogin\b{rest}[ \t](?-i:-p)[ \t]+(?P<value>{ARG})"#),
        ),
        // ldapsearch -w SECRET
        (
            &["ldap"],
            format!(
                r#"(?i)\bldap(?:search|modify|add|delete|compare|passwd)\b{rest}[ \t](?-i:-w)[ \t]*(?P<value>{ARG})"#
            ),
        ),
        // openssl ... -passin pass:SECRET
        (
            &["-pass"],
            format!(r#"(?-i:-pass(?:in|out)?)[ \t]+pass:(?P<value>{ARG})"#),
        ),
    ];
    rules
        .into_iter()
        .map(|(needles, pattern)| (needles, re(&pattern)))
        .collect()
});

fn scan_cli_credentials(text: &str, lower: &Lowered, hits: &mut Vec<Hit>) {
    scan_curl_users(text, hits);
    for (needles, pattern) in CLI_CREDENTIALS.iter() {
        if lower.holds_any(needles) {
            scan_value_group(pattern, RedactionKind::SecretAssignment, text, hits);
        }
    }
}

// ───────────────────────────── curl -u ───────────────────────────────────────

/// Where the first flag that carries a user ends: `-u`, `-U` (proxy), their
/// long forms (`--user`, `--proxy-user`, with their blanks or `=`), and the
/// short ones behind a cluster of curl's no-argument short flags (`-su`). The
/// flag must start at `from` or later, after a blank: a newline counts as the
/// blank before a flag, it is the start of a line that continues the command
/// (`curl \` then `-u user:pw`). Found by hand, not with a regex: a megabyte
/// of `curl -u a -u a …` holds a flag every few bytes, and a regex search per
/// flag costs more than the rest of the scan.
fn user_flag_end(text: &str, from: usize) -> Option<usize> {
    let bytes = text.as_bytes();
    let blank = |b: u8| matches!(b, b' ' | b'\t' | b'\n');
    // curl's short flags that take no argument, which `-u` may follow.
    let no_argument = |b: u8| {
        matches!(
            b,
            b'#' | b'0'
                ..=b'4'
                    | b'6'
                    | b'a'
                    | b'B'
                    | b'f'
                    | b'g'
                    | b'G'
                    | b'h'
                    | b'i'
                    | b'I'
                    | b'j'
                    | b'J'
                    | b'k'
                    | b'L'
                    | b'l'
                    | b'M'
                    | b'n'
                    | b'N'
                    | b'O'
                    | b'p'
                    | b'q'
                    | b'R'
                    | b's'
                    | b'S'
                    | b'v'
                    | b'V'
                    | b'Z'
        )
    };
    let mut at = from + 1;
    while let Some(n) = bytes.get(at..)?.iter().position(|&b| b == b'-') {
        let dash = at + n;
        at = dash + 1;
        if !blank(bytes[dash - 1]) {
            continue;
        }
        let rest = &bytes[dash + 1..];
        if rest.first() == Some(&b'-') {
            let name = &rest[1..];
            let len = if name.starts_with(b"proxy-user") {
                10
            } else if name.starts_with(b"user") {
                4
            } else {
                continue;
            };
            let after = dash + 2 + len;
            match bytes.get(after) {
                Some(b'=') => return Some(after + 1),
                Some(&b) if b == b' ' || b == b'\t' => {
                    let blanks = bytes[after..]
                        .iter()
                        .take_while(|&&b| b == b' ' || b == b'\t')
                        .count();
                    return Some(after + blanks);
                }
                _ => continue,
            }
        }
        let flags = rest.iter().take_while(|&&b| no_argument(b)).count();
        if matches!(rest.get(flags), Some(b'u' | b'U')) {
            let after = dash + 1 + flags + 1;
            let blanks = bytes[after..]
                .iter()
                .take_while(|&&b| b == b' ' || b == b'\t')
                .count();
            return Some(after + blanks);
        }
    }
    None
}

/// The ranges of `curl` as a word (any case) in `text`. Found by hand, not
/// with a regex: on a megabyte of `curl;curl;…` a regex with word boundaries
/// costs more than everything else the scan does. ASCII word boundaries, so a
/// `curl` glued to a non-ASCII letter counts too, which only redacts more.
fn curl_words(text: &str) -> impl Iterator<Item = Range<usize>> + '_ {
    let bytes = text.as_bytes();
    let is_word = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let mut at = 0;
    std::iter::from_fn(move || {
        while at + 4 <= bytes.len() {
            let start = at;
            at += 1;
            if bytes[start].eq_ignore_ascii_case(&b'c')
                && bytes[start + 1..start + 4].eq_ignore_ascii_case(b"url")
                && !start.checked_sub(1).is_some_and(|i| is_word(bytes[i]))
                && !bytes.get(start + 4).copied().is_some_and(is_word)
            {
                at = start + 4;
                return Some(start..start + 4);
            }
        }
        None
    })
}

/// `curl -u user:password`, in every quoting the shell allows: bare, the whole
/// credential quoted (it may hold spaces), a quoted user with a bare or quoted
/// password (`-u "admin":secret`), and quotes inside the value
/// (`-u 'admin:hun'\''ter2'`, `-u "admin:hun\"ter2"`). It fails closed: when a
/// quote is followed by more text glued to it, or a value holds a quote, the
/// credential runs to the end of the line. Every `-u` of one command counts,
/// wherever the command's flags sit: after a quoted `&`, `;` or `|`, or on a
/// line that a trailing backslash continues.
fn scan_curl_users(text: &str, hits: &mut Vec<Hit>) {
    // The flags of a command are all found from its first `curl`; skipping the
    // later ones keeps `curl curl curl …` linear.
    let mut scanned_to = 0;
    // End of the line the last flag's value is on, found once for every flag up
    // to it: a long line of `curl;curl;…` is searched once, not once per
    // `curl`. The invariant: flags come in text order (`pos` only moves
    // forward, and a later `curl` starts past `scanned_to`), so a flag whose
    // value starts at or before `line_end` is on the line that search found.
    // `0` means "not searched yet" (a real line end is past the first `curl`);
    // searching again is always right, so a wrong guess costs time and never
    // skips a value.
    let mut line_end = 0;
    for curl in curl_words(text) {
        if curl.start < scanned_to {
            continue;
        }
        let command_end = command_end(text, curl.end);
        scanned_to = command_end;
        let mut pos = curl.end;
        while pos <= command_end {
            let Some(flag_end) = user_flag_end(&text[..command_end], pos) else {
                break;
            };
            pos = flag_end;
            // `-u \` + newline + `admin:pw`: the value is on the next line.
            let at = skip_continuation(text, flag_end);
            if at > line_end || line_end == 0 {
                line_end = text[at..].find('\n').map_or(text.len(), |n| at + n);
            }
            if let Some(range) = curl_credential(text, at, line_end) {
                pos = pos.max(range.end);
                hits.push(Hit {
                    range,
                    kind: RedactionKind::SecretAssignment,
                });
            }
        }
    }
}

/// Where the command whose arguments start at `from` ends: at an unquoted
/// newline, `|`, `;` or `&`. A backslash escapes the next character (so `\;` and
/// a backslash before a newline do not end it), a quote opens a string that
/// may hold any of them (`$'…'` has escapes too), and the clip mark `…` that
/// the line assembler puts at the end of a row it cut counts like a trailing
/// backslash: the rest of the command may be on the next row.
///
/// A quote with no closing mate is an ordinary character (an apostrophe in
/// `curl: Couldn't connect` must not swallow what follows); every other
/// quote is skipped to its mate, so one pass is linear.
fn command_end(text: &str, from: usize) -> usize {
    // By bytes: every character that matters here is ASCII but the clip mark
    // (see `CLIP_MARK`), and no byte of a longer character is ASCII.
    let bytes = text.as_bytes();
    // Once a kind of quote has no mate after some point, no later one has.
    let (mut single_closes, mut double_closes) = (true, true);
    let mut prev = 0u8;
    let mut idx = from;
    while let Some(&byte) = bytes.get(idx) {
        let at = idx;
        let clip_mark = byte == CLIP_MARK[0] && bytes[at..].starts_with(&CLIP_MARK);
        let width = if clip_mark { CLIP_MARK.len() } else { 1 };
        let next = at + width;
        idx = next;
        match byte {
            _ if byte == b'\\' || clip_mark => {
                // Blanks between the mark and the newline are tolerated (the
                // terminal may have padded the row).
                let blanks = bytes[next..]
                    .iter()
                    .take_while(|&&b| matches!(b, b' ' | b'\t' | b'\r'))
                    .count();
                if bytes.get(next + blanks) == Some(&b'\n') {
                    idx = next + blanks + 1;
                } else if byte == b'\\' {
                    idx = next + text[next..].chars().next().map_or(0, char::len_utf8);
                }
            }
            b'\'' | b'"' => {
                let ansi_c = byte == b'\'' && prev == b'$';
                let closes = if byte == b'\'' {
                    &mut single_closes
                } else {
                    &mut double_closes
                };
                if *closes || ansi_c {
                    let after = &text[next..];
                    let mate = if byte == b'\'' && !ansi_c {
                        after.find('\'')
                    } else {
                        find_closing_quote(after, char::from(byte))
                    };
                    match mate {
                        Some(n) => idx = next + n + 1,
                        None => *closes &= ansi_c,
                    }
                }
            }
            b'\n' | b'|' | b';' | b'&' => return at,
            _ => {}
        }
        prev = byte;
    }
    text.len()
}

/// The clip mark the line assembler puts at the end of a row it cut (UTF-8).
const CLIP_MARK: [u8; 3] = [0xE2, 0x80, 0xA6];

/// `at` past the backslash-newlines (or clip-mark newlines) and the blanks
/// around them that start there: a value can be on a row that several continuations lead to.
fn skip_continuation(text: &str, mut at: usize) -> usize {
    loop {
        // Nearly always there is none: a cheap look before the pattern search.
        if !matches!(text.as_bytes().get(at), Some(b'\\' | 0xE2)) {
            return at;
        }
        let Some(after) = text[at..].strip_prefix(['\\', '…']) else {
            return at;
        };
        let after = after.trim_start_matches([' ', '\t', '\r']);
        let Some(next) = after.strip_prefix('\n') else {
            return at;
        };
        at = text.len() - next.trim_start_matches([' ', '\t']).len();
    }
}

/// `end`, the end of a row, moved to the end of the next row for as long as
/// the row ends in a backslash: the shell joins them into one word.
fn through_continuation(text: &str, mut end: usize) -> usize {
    while ends_in_backslash(text[..end].trim_end_matches('\r')) && text[end..].starts_with('\n') {
        end = text[end + 1..]
            .find('\n')
            .map_or(text.len(), |n| end + 1 + n);
    }
    end
}

/// The password of the credential starting at `at` (just after the flag).
fn curl_credential(text: &str, at: usize, line_end: usize) -> Option<Range<usize>> {
    let rest = &text[at..line_end];
    // Where a credential that runs to the end of the line ends (found only
    // when needed: a chain of continued rows is long).
    let eol = || through_continuation(text, line_end);
    let first = rest.chars().next()?;
    if matches!(first, '"' | '\'') {
        let body = at + 1;
        let Some(close) = closing_quote(&text[body..line_end], first) else {
            // Unterminated: from the first colon to the end of the line.
            let colon = text[body..line_end].find(':')?;
            return non_empty(body + colon + 1..eol());
        };
        let (close, after) = (body + close, body + close + 1);
        if let Some(colon) = text[body..close].find(':') {
            let end = if is_continued(text, after) {
                eol()
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
            return non_empty(after + colon + 1..eol());
        }
        return None;
    }
    let stop = user_stop(rest)?;
    if rest[stop..].starts_with(':') {
        return curl_password(text, at + stop + 1, line_end);
    }
    if rest[stop..].starts_with(['"', '\'']) {
        // A quote inside the user part: from the first colon to the end of the line.
        let colon = rest[stop..]
            .find(':')
            .filter(|&n| stop + n < line_end - at)?;
        return non_empty(at + stop + colon + 1..eol());
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
    let eol = || through_continuation(text, line_end);
    if matches!(first, '"' | '\'') {
        let end = match closing_quote(&rest[1..], first) {
            Some(close) => at + 1 + close + 1,
            None => eol(),
        };
        return non_empty(at..if is_continued(text, end) { eol() } else { end });
    }
    let mut end = at + find_blank(rest).unwrap_or(rest.len());
    // A word that ends in a backslash goes on past the blank it escapes
    // (`pw\ tail`), or onto the next line when the backslash is the last
    // character of its row.
    while ends_in_backslash(&text[at..end]) {
        let after = &text[end..];
        let newline = after.starts_with('\n') || after.starts_with("\r\n");
        let skip = if after.starts_with("\r\n") {
            2
        } else if newline || after.starts_with([' ', '\t']) {
            1
        } else {
            break;
        };
        let from = end + skip;
        let tail = find_blank(&text[from..]).unwrap_or(text.len() - from);
        if newline && tail == 0 {
            break;
        }
        end = from + tail;
    }
    if text[at..end].bytes().any(|b| b == b'"' || b == b'\'') {
        end = text[end..].find('\n').map_or(text.len(), |n| end + n);
        end = through_continuation(text, end);
    }
    non_empty(at..end)
}

/// Offset of the first blank in `text`. By bytes: the views hold no whitespace
/// but the ASCII blanks.
fn find_blank(text: &str) -> Option<usize> {
    text.bytes()
        .position(|b| matches!(b, b' ' | b'\t' | b'\n' | b'\r'))
}

/// Offset in `rest` of the first `:`, quote or unescaped blank. A backslash
/// keeps the blank after it in the word (`ad\ min:pw`).
fn user_stop(rest: &str) -> Option<usize> {
    // By bytes: the views hold no whitespace but the ASCII blanks, and no byte
    // of a longer character is ASCII.
    let bytes = rest.as_bytes();
    let mut i = 0;
    while let Some(&b) = bytes.get(i) {
        if b == b'\\' && matches!(bytes.get(i + 1), Some(b' ' | b'\t')) {
            i += 2;
        } else if matches!(b, b':' | b' ' | b'\t' | b'\n' | b'\r' | b'"' | b'\'') {
            return Some(i);
        } else {
            i += 1;
        }
    }
    None
}

/// Whether `word` ends in a backslash that escapes what follows: an odd run.
fn ends_in_backslash(word: &str) -> bool {
    word.bytes().rev().take_while(|&b| b == b'\\').count() % 2 == 1
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

fn scan_ssn(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
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

fn scan_dob(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
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

fn scan_assignments(text: &str, _: &Lowered, hits: &mut Vec<Hit>) {
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
            if !window.contains("-----") {
                return None;
            }
            let m = pattern.find(window)?;
            return Some(from + m.start()..from + m.end());
        };
        let span = view.view_span(from, to);
        let window = view.text.get(span.clone())?;
        // Every marker starts with five dashes: skip the search without them.
        if !window.contains("-----") {
            return None;
        }
        let m = pattern.find(window)?;
        view.to_original(span.start + m.start()..span.start + m.end())
    }

    fn find_from(&self, pattern: &Regex, from: usize) -> Option<Range<usize>> {
        self.find(pattern, from, self.text.len())
    }
}

/// Marker for a private-key block that never showed an `END` line.
const UNTERMINATED_MARKER: &str = "[redacted: private-key (no END line; output resumes)]";

/// Redacts secrets from successive pieces of one terminal's text.
///
/// Stateful for private-key blocks: a block whose `BEGIN` has no `END` in
/// the same call is redacted to the end of the text and the following calls
/// keep redacting until an `END` arrives, or until the block has swallowed
/// [`MAX_UNTERMINATED_KEY_BYTES`] without one (then output resumes). Also for
/// one `curl` command written over several rows with trailing backslashes:
/// a call that ends inside one keeps its rows, and the next call reads them in
/// front of its own, so `curl \` then `-u user:pw` (or `-u \` then
/// `user:pw`) is caught across two deliveries too.
#[derive(Debug, Default, Clone)]
pub struct Redactor {
    inside_private_key: bool,
    /// Bytes swallowed by the current private-key block so far.
    swallowed: usize,
    /// The rows of the `curl` command the previous call ended inside.
    curl_rows: Option<CarriedRows>,
}

/// Raw rows of an open `curl` command. They can hold a secret, so they are
/// never printed.
#[derive(Default, Clone)]
struct CarriedRows(String);

impl fmt::Debug for CarriedRows {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "CarriedRows({} bytes)", self.0.len())
    }
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
            curl_rows: None,
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
        let stand_in = self.curl_stand_in();
        let result = self.redact_text(text, &stand_in);
        self.curl_rows = if self.inside_private_key {
            None
        } else {
            open_curl_rows(&stand_in, text).map(CarriedRows)
        };
        result
    }

    /// What goes in front of the next text: a `curl` and the rows of the
    /// command left open, or nothing.
    fn curl_stand_in(&self) -> String {
        self.curl_rows
            .as_ref()
            .map_or_else(String::new, |rows| format!("curl {}\n", rows.0))
    }

    fn redact_text(&mut self, text: &str, stand_in: &str) -> (String, Vec<RedactionKind>) {
        let mut stand_in = stand_in;
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
                stand_in = "";
                out.push_str(RedactionKind::PrivateKey.marker());
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
                    redact_plain(
                        &text[pos..begin.start],
                        std::mem::take(&mut stand_in),
                        &mut out,
                        &mut kinds,
                    );
                    // The block's own marker is pushed at the top of the loop.
                    self.inside_private_key = true;
                    self.swallowed = 0;
                    pos = begin.end;
                }
                None => {
                    redact_plain(
                        &text[pos..],
                        std::mem::take(&mut stand_in),
                        &mut out,
                        &mut kinds,
                    );
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
        // The lost text may have left a `curl` command open.
        self.curl_rows = open_curl_rows(&self.curl_stand_in(), &lines.join("\n")).map(CarriedRows);
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

/// Most bytes at the end of a text read to find out whether it ends inside a
/// `curl` command. A longer text is assumed to (over-redacting is safe).
const OPEN_CURL_WINDOW: usize = 64 * 1024;

/// Most bytes of an open command's rows carried to the next call.
const MAX_CARRIED_ROWS: usize = 8 * 1024;

/// Characters at the end of a row that may continue its command: a backslash
/// (the fullwidth and small forms fold to it) or the assembler's clip mark.
const BACKSLASHES: [char; 4] = ['\\', '\u{ff3c}', '\u{fe68}', '…'];

fn without_trailing_blanks(text: &str) -> &str {
    text.trim_end_matches(|c: char| c.is_whitespace() || is_hidden(c))
}

/// The rows of the `curl` command that `text` (which follows `stand_in`) ends
/// inside, when its last row ends in a backslash: from the first row of the
/// command, capped at [`MAX_CARRIED_ROWS`] bytes.
fn open_curl_rows(stand_in: &str, text: &str) -> Option<String> {
    // Cheap exit for the usual text.
    if !without_trailing_blanks(text).ends_with(BACKSLASHES) {
        return None;
    }
    let combined = if text.len() < OPEN_CURL_WINDOW {
        format!("{stand_in}{text}")
    } else {
        let from = ceil_boundary(text, text.len() - OPEN_CURL_WINDOW);
        format!("{CURL_STAND_IN}{}", &text[from..])
    };
    // More hidden runs than the budget reads in every combination: assume the
    // command is open (carrying its rows over costs a little, missing a flag
    // on the next row costs a secret).
    if let Some(views) = View::for_command(&combined) {
        if !views.iter().any(|view| open_curl_command(&view.text)) {
            return None;
        }
    }
    // Back to the first row of the command: the rows before the last one that
    // end in a backslash belong to it.
    let rows: Vec<&str> = combined.split('\n').collect();
    let mut first = rows.len() - 1;
    while first > 0 && without_trailing_blanks(rows[first - 1]).ends_with(BACKSLASHES) {
        first -= 1;
    }
    let joined = rows[first..].join("\n");
    // The stand-in ends the rows with one newline of its own.
    let joined = joined.trim_end_matches('\n').to_owned();
    let joined = match joined.strip_prefix(CURL_STAND_IN) {
        Some(rest) if first == 0 => rest,
        _ => &joined,
    };
    let from = ceil_boundary(joined, joined.len().saturating_sub(MAX_CARRIED_ROWS));
    // A cut that lands on a row break must not leave the stand-in ending at it.
    Some(joined[from..].trim_start_matches('\n').to_owned())
}

/// Whether the last `curl` command of `text` runs to its end, which ends in a
/// backslash.
fn open_curl_command(text: &str) -> bool {
    if !text.trim_end().ends_with(['\\', '…']) {
        return false;
    }
    let mut open = false;
    let mut scanned_to = 0;
    for curl in curl_words(text) {
        if curl.start < scanned_to {
            continue;
        }
        scanned_to = command_end(text, curl.end);
        open = scanned_to == text.len();
    }
    open
}

fn ceil_boundary(text: &str, mut idx: usize) -> usize {
    while !text.is_char_boundary(idx) {
        idx += 1;
    }
    idx
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
///
/// `stand_in` (empty for most texts) goes in front when the text continues a
/// `curl` command the previous call left open, so the scanners see one command.
/// Nothing found inside it is reported: that call already redacted it.
fn redact_plain(text: &str, stand_in: &str, out: &mut String, kinds: &mut Vec<RedactionKind>) {
    if text.is_empty() {
        return;
    }
    let combined;
    let (text, skip) = if stand_in.is_empty() {
        (text, 0)
    } else {
        combined = format!("{stand_in}{text}");
        (combined.as_str(), stand_in.len())
    };
    // Accepted spans never overlap, so keying by start also orders them by
    // end: an overlap test is one range lookup.
    let mut accepted: BTreeMap<usize, Span> = BTreeMap::new();
    // The end of the furthest accepted span.
    let mut furthest = 0;
    let mut hits = Vec::new();
    let reading = Reading::new(text);
    for (priority, scanner) in SCANNERS.iter().enumerate() {
        for (view, lower) in reading.views_for(&scanner.gate) {
            hits.clear();
            (scanner.scan)(&view.text, lower, &mut hits);
            for hit in hits.drain(..) {
                let Hit { range, kind } = hit;
                // A span the view cannot place in the original is dropped; the
                // other views and rules still cover the text.
                if let Some(range) = view.to_original(range) {
                    let range = extend_over_hidden(text, range, kind);
                    accept(
                        &mut accepted,
                        &mut furthest,
                        text,
                        Hit { range, kind },
                        priority,
                    );
                }
            }
        }
    }

    // Groups too dear to read are redacted whole, below every rule.
    for (range, kind) in reading.closed {
        let hit = Hit { range, kind };
        accept(&mut accepted, &mut furthest, text, hit, SCANNERS.len());
    }

    let mut cursor = skip;
    for (start, span) in accepted {
        if span.end <= skip {
            continue;
        }
        out.push_str(&text[cursor..start.max(skip)]);
        out.push_str(span.kind.marker());
        kinds.push(span.kind);
        cursor = span.end;
    }
    out.push_str(&text[cursor..]);
}

/// What starts the text in front of a row that continues a `curl` command.
const CURL_STAND_IN: &str = "curl ";

/// A credential that ends right before hidden text may go on past it: the run
/// was read as a blank in the view that found it, but it can be a character
/// of the secret (`-u admin:QWKZ<ZWSP>XBNM`, one more hidden run somewhere
/// else having made the other readings miss). Take everything up to the next
/// real blank, or the end of the line. Over-redacting is the safe error.
///
/// Only for the kinds that end at a word: a token has a shape that includes
/// its own tail, and a URL password ends at its `@`.
fn extend_over_hidden(text: &str, range: Range<usize>, kind: RedactionKind) -> Range<usize> {
    let ends_at_a_word = matches!(
        kind,
        RedactionKind::SecretAssignment
            | RedactionKind::BearerToken
            | RedactionKind::BasicAuth
            | RedactionKind::AwsSecretKey
    );
    if !ends_at_a_word || !next_char(text, range.end).is_some_and(is_hidden) {
        return range;
    }
    let end = text[range.end..]
        .find(char::is_whitespace)
        .map_or(text.len(), |n| range.end + n);
    range.start..end
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
fn accept(
    accepted: &mut BTreeMap<usize, Span>,
    furthest: &mut usize,
    text: &str,
    hit: Hit,
    priority: usize,
) {
    let Hit { range, kind } = hit;
    if range.is_empty() {
        return;
    }
    let context = if kind == RedactionKind::UrlPassword {
        url_context(text, &range)
    } else {
        range.clone()
    };
    // The common case, a hit beside the accepted spans, needs no list. One
    // past all of them (a text read front to back) needs no search either.
    let past_all = range.start >= *furthest;
    *furthest = (*furthest).max(range.end);
    if past_all
        || !accepted
            .range(..range.end)
            .next_back()
            .is_some_and(|(_, span)| span.end > range.start)
    {
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
    }
    // Ordered by start, last first: accepted spans are disjoint.
    let overlapped: Vec<usize> = accepted
        .range(..range.end)
        .rev()
        .take_while(|(_, span)| span.end > range.start)
        .map(|(&start, _)| start)
        .collect();
    let (Some(&first_start), Some(&last_start)) = (overlapped.last(), overlapped.first()) else {
        return; // Not reached: the check above found an overlapped span.
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
    *furthest = (*furthest).max(end);
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

    /// A literal a rule needs must hold a literal of its gate, or the gate
    /// would skip a text the rule can read.
    fn gate_covers(gate: &[&str], literal: &str) -> bool {
        gate.iter().any(|g| literal.contains(g))
    }

    #[test]
    fn every_scanner_gate_covers_the_literals_its_rules_need() {
        for (needles, _) in TOKEN_SHAPES.iter() {
            for needle in needles.iter() {
                assert!(gate_covers(TOKEN_GATE, needle), "token literal {needle:?}");
            }
        }
        for (needles, _) in CLI_CREDENTIALS.iter() {
            for needle in needles.iter() {
                assert!(gate_covers(CLI_GATE, needle), "cli literal {needle:?}");
            }
        }
        for word in NAME_WORDS {
            assert!(gate_covers(ASSIGNMENT_GATE, word), "name word {word:?}");
        }
        assert!(gate_covers(CLI_GATE, "curl"));
        assert!(gate_covers(DOB_GATE, "dob") && gate_covers(DOB_GATE, "birth"));
    }

    #[test]
    fn the_pair_filter_never_hides_a_literal_the_text_holds() {
        // Long enough to carry the pair set.
        let padding = "ordinary output with nothing to hide ".repeat(200);
        for needle in CLI_GATE.iter().chain(TOKEN_GATE).chain(ASSIGNMENT_GATE) {
            let with = Lowered::new(format!("{padding}x {} y{padding}", needle.to_uppercase()));
            assert!(with.pairs.is_some());
            assert!(with.holds_any(&[needle]), "{needle:?}");
        }
        let without = Lowered::new(padding);
        assert!(!without.holds_any(&["curl", "ghp_", "secret"]));
    }

    #[test]
    fn a_group_over_the_budget_is_redacted_whole_and_one_inside_it_is_read() {
        // Hidden runs enough that no combination fits next to the others.
        let z = '\u{200b}';
        let word = format!("curl{z}-u{z}a{z}:{z}pw{z}x{z}y{z}z{z}q{z}r");
        let big = format!("{}\n{word}", format!("{word}\n").repeat(5_000));
        let (out, kinds) = Redactor::new().redact(&big);
        assert!(!out.contains("pw"), "{out:?}");
        assert!(!kinds.is_empty());
        // A single such line, alone, is read inside the budget.
        let (out, _) = Redactor::new().redact(&word);
        assert!(!out.contains("pw"), "{out:?}");
    }

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
