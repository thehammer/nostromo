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
//! context checks look at a bounded neighbourhood).

use std::fmt;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;

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

/// All findings in `text`, ordered by start offset.
pub fn scan(text: &str, cfg: &GuardConfig) -> Vec<Finding> {
    let mut out = Vec::new();
    scan_ssn(text, &mut out);
    scan_card(text, &mut out);
    scan_dob(text, &mut out);
    scan_mrn(text, &mut out);
    scan_phone(text, &mut out);
    scan_email(text, cfg, &mut out);
    scan_secret(text, &mut out);
    out.sort_by(|a, b| {
        a.range
            .start
            .cmp(&b.range.start)
            .then(a.range.end.cmp(&b.range.end))
    });
    out
}

/// Class of the earliest finding, if any.
pub fn first_class(text: &str, cfg: &GuardConfig) -> Option<Class> {
    scan(text, cfg).first().map(|f| f.class)
}

// ---------------------------------------------------------------------------
// Context helpers
// ---------------------------------------------------------------------------

fn prev_char(text: &str, idx: usize) -> Option<char> {
    text[..idx].chars().next_back()
}

fn next_char(text: &str, idx: usize) -> Option<char> {
    text[idx..].chars().next()
}

/// A joiner that, between two alphanumerics, makes one identifier
/// (`1.2.3`, `a-b`, `x_y`, `path/to`).
fn is_joiner(c: char) -> bool {
    matches!(c, '-' | '.' | '_' | '/')
}

/// True when `text[start..end]` stands alone: not glued to a neighbouring
/// alphanumeric run and not one segment of a dotted/hyphenated/slashed
/// identifier (UUID, SHA slug, version, URL path id).
fn standalone(text: &str, start: usize, end: usize) -> bool {
    if let Some(p) = prev_char(text, start) {
        if p.is_alphanumeric() {
            return false;
        }
        if is_joiner(p) && prev_char(text, start - p.len_utf8()).is_some_and(char::is_alphanumeric)
        {
            return false;
        }
    }
    if let Some(n) = next_char(text, end) {
        if n.is_alphanumeric() {
            return false;
        }
        if is_joiner(n) && next_char(text, end + n.len_utf8()).is_some_and(char::is_alphanumeric) {
            return false;
        }
    }
    true
}

fn push(out: &mut Vec<Finding>, class: Class, range: Range<usize>) {
    out.push(Finding { class, range });
}

// ---------------------------------------------------------------------------
// SSN
// ---------------------------------------------------------------------------

static SSN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d{3}-\d{2}-\d{4}").expect("ssn regex"));

fn scan_ssn(text: &str, out: &mut Vec<Finding>) {
    for m in SSN_RE.find_iter(text) {
        let s = m.as_str();
        let area = &s[0..3];
        let group = &s[4..6];
        let serial = &s[7..11];
        let invalid = area == "000"
            || area == "666"
            || area.starts_with('9')
            || group == "00"
            || serial == "0000";
        if invalid || !standalone(text, m.start(), m.end()) {
            continue;
        }
        push(out, Class::Ssn, m.range());
    }
}

// ---------------------------------------------------------------------------
// Payment card
// ---------------------------------------------------------------------------

/// Runs of digit groups joined by single spaces or dashes.
static CARD_RUN_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\d+(?:[ -]\d+)*").expect("card regex"));

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
            digits += groups[j].1 - groups[j].0;
            if digits > 19 {
                break;
            }
            let (ws, we) = (groups[i].0, groups[j].1);
            if digits >= 13 && is_card_window(&run[ws..we], &groups[i..=j]) {
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
    plausible_issuer(&digits) && !digits.iter().all(|d| *d == digits[0]) && luhn_ok(&digits)
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
    let (last, head) = lens.split_last().expect("non-empty");
    head.iter().all(|l| *l == 4) && (1..=4).contains(last)
}

/// First digit of the major networks (Amex/Diners/JCB 3, Visa 4, Mastercard
/// 5 and 2221-2720, Discover/UnionPay 6). Cuts timestamp and id look-alikes.
fn plausible_issuer(digits: &[u8]) -> bool {
    match digits[0] {
        3..=6 => true,
        2 => {
            let p = u32::from(digits[0]) * 1000
                + u32::from(digits[1]) * 100
                + u32::from(digits[2]) * 10
                + u32::from(digits[3]);
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
    Regex::new(r"(?i)\b(?:d\.o\.b|dob|date\s+of\s+birth|birth\s*date|born)\b").expect("dob label")
});

static DATE_RE: LazyLock<Regex> = LazyLock::new(|| {
    let month = r"(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?";
    let pattern = format!(
        r"(?i)\b(?:(?:0?[1-9]|1[0-2])/(?:0?[1-9]|[12]\d|3[01])/(?:\d{{4}}|\d{{2}})|(?:19|20)\d{{2}}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])|{month}\s+\d{{1,2}}(?:st|nd|rd|th)?,?\s+\d{{4}}|\d{{1,2}}\s+{month}\s+\d{{4}})\b"
    );
    Regex::new(&pattern).expect("date regex")
});

/// How many characters after a label a birth date may start.
const DOB_WINDOW_CHARS: usize = 30;
/// Extra bytes read past the window so a date that starts inside it can end.
const DOB_TAIL_BYTES: usize = 24;

fn scan_dob(text: &str, out: &mut Vec<Finding>) {
    for label in DOB_LABEL_RE.find_iter(text) {
        let after = &text[label.end()..];
        let window_len = after
            .char_indices()
            .nth(DOB_WINDOW_CHARS)
            .map_or(after.len(), |(i, _)| i);
        let mut end = (window_len + DOB_TAIL_BYTES).min(after.len());
        while !after.is_char_boundary(end) {
            end += 1;
        }
        if let Some(d) = DATE_RE.find(&after[..end]) {
            if d.start() <= window_len {
                let start = label.end() + d.start();
                push(out, Class::Dob, start..label.end() + d.end());
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Medical record number
// ---------------------------------------------------------------------------

static MRN_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b(?:mrn|medical\s+record(?:\s+(?:number|num|no\.?|#))?)\b[\s:#=.-]*([a-z0-9][a-z0-9-]{3,})",
    )
    .expect("mrn regex")
});

fn scan_mrn(text: &str, out: &mut Vec<Finding>) {
    for caps in MRN_RE.captures_iter(text) {
        let id = caps.get(1).expect("mrn id group");
        // A real id has a digit; this drops "MRN lookup" and "medical record sync".
        if id.as_str().bytes().any(|b| b.is_ascii_digit()) {
            let whole = caps.get(0).expect("mrn match");
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
    let area = r"[2-9]\d{2}";
    let line = r"\d{4}";
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
    for caps in EMAIL_RE.captures_iter(text) {
        let local = &caps[1];
        let domain = caps[2].to_ascii_lowercase();
        let tld = domain.rsplit('.').next().unwrap_or("");
        let alpha_tld = tld.len() >= 2 && tld.bytes().all(|b| b.is_ascii_alphabetic());
        // `git@github.com:org/repo.git` is an SSH remote, not a person.
        if !alpha_tld || ASSET_EXTENSIONS.contains(&tld) || local == "git" {
            continue;
        }
        if is_work_domain(&domain, cfg) {
            continue;
        }
        push(
            out,
            Class::PersonalEmail,
            caps.get(0).expect("email match").range(),
        );
    }
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

/// Patterns whose shape alone is conclusive.
static SECRET_SHAPES: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    [
        // AWS access key id.
        r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
        // AWS secret access key assignment.
        r#"(?i)\baws_?secret_?access_?key["']?\s*[=:]\s*["']?[A-Za-z0-9/+=]{16,}"#,
        // GitHub tokens.
        r"\bgh[pousr]_[A-Za-z0-9]{20,}",
        r"\bgithub_pat_[A-Za-z0-9_]{20,}",
        // Slack tokens.
        r"\bxox[abpr]-[A-Za-z0-9-]{10,}",
        // Anthropic keys.
        r"\bsk-ant-[A-Za-z0-9_-]{8,}",
        // Stripe live keys.
        r"\b[sr]k_live_[A-Za-z0-9]{10,}",
        // JWT: header.payload.signature, header and payload both start `eyJ`.
        r"\beyJ[A-Za-z0-9_-]{4,}\.eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*",
        // PEM private-key header.
        r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?:-----)?",
    ]
    .iter()
    .map(|p| Regex::new(p).expect("secret shape regex"))
    .collect()
});

/// `sk-` followed by a long token; judged for randomness in code.
static SK_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bsk-([A-Za-z0-9_-]{20,})").expect("sk regex"));

static BEARER_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)\bBearer\s+([A-Za-z0-9._~+/=-]{20,})").expect("bearer regex")
});

/// `scheme://user:password@host`. The password may not start like a
/// placeholder (`${PASS}`, `<password>`, `%s`).
static URL_CREDS_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:([^\s/@$<{%*][^\s/@]*)@[^\s/]+")
        .expect("url creds regex")
});

/// `password=...`, `"api_key": "..."`, `client_secret: ...` with a value of at
/// least 8 non-space characters.
static ASSIGNMENT_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)(?:password|passwd|pwd|secret|token|api_?key)["']?\s*[=:]\s*["']?(\S{8,})"#)
        .expect("assignment regex")
});

fn scan_secret(text: &str, out: &mut Vec<Finding>) {
    for re in SECRET_SHAPES.iter() {
        for m in re.find_iter(text) {
            push(out, Class::Secret, m.range());
        }
    }
    for caps in SK_RE.captures_iter(text) {
        let whole = caps.get(0).expect("sk match");
        let glued = prev_char(text, whole.start()).is_some_and(is_joiner);
        // `sk-` mid-slug (`my-sk-...`) or an all-lowercase slug is not a key.
        if !glued && looks_random(&caps[1]) {
            push(out, Class::Secret, whole.range());
        }
    }
    for caps in BEARER_RE.captures_iter(text) {
        if looks_random(&caps[1]) {
            push(
                out,
                Class::Secret,
                caps.get(0).expect("bearer match").range(),
            );
        }
    }
    for caps in URL_CREDS_RE.captures_iter(text) {
        push(
            out,
            Class::Secret,
            caps.get(0).expect("url creds match").range(),
        );
    }
    for caps in ASSIGNMENT_RE.captures_iter(text) {
        if assignment_value_is_secret(&caps[1]) {
            push(
                out,
                Class::Secret,
                caps.get(0).expect("assignment match").range(),
            );
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
