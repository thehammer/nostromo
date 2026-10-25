//! Secret redaction for text delivered to an agent (PRD criterion 42).
//!
//! [`Redactor::redact`] replaces text that has the shape of a credential with
//! a visible `[redacted: <kind>]` marker and reports what it replaced, so the
//! reader (human or model) can tell something was removed.
//!
//! The patterns are deliberately narrow: ordinary output (hashes, UUIDs,
//! `ls`, logs, an `env` dump without secret-named variables) must come
//! through untouched. There is **no** generic high-entropy rule and **no**
//! "any environment value" rule. This is separate from
//! `activity::redact`, whose broader rules would redact every sha256 in a
//! query result; the token shapes below are duplicated from there on purpose.
//!
//! Redaction covers credentials, not PHI.

use std::fmt;
use std::ops::Range;
use std::sync::LazyLock;

use regex::Regex;

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
    /// Provider token shapes: GitHub, Slack, Stripe, `sk-…`, JWT.
    ApiToken,
    /// Value of a `PASSWORD=` / `API_KEY=` / `…_SECRET=` style assignment.
    SecretAssignment,
    /// Password inside `scheme://user:password@host`.
    UrlPassword,
    /// A PEM private-key block.
    PrivateKey,
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

/// One matcher: every match replaces the capture group `value` (or the whole
/// match when the pattern has none) with the kind's marker.
struct Rule {
    kind: RedactionKind,
    re: Regex,
}

/// Rules in priority order: when matches overlap, the earlier rule wins, so
/// `GITHUB_TOKEN=ghp_…` reports `api-token` (name kept) and
/// `AWS_SECRET_ACCESS_KEY=…` reports `aws-secret-key`, not
/// `secret-assignment`.
static RULES: LazyLock<Vec<Rule>> = LazyLock::new(|| {
    let rule = |kind, pattern: &str| Rule {
        kind,
        re: Regex::new(pattern).expect("redaction pattern"),
    };
    // A value after `=` or `:`: quoted (no newline inside) or a bare word.
    const VALUE: &str = r#""[^"\n]*"|'[^'\n]*'|\S+"#;
    vec![
        // `scheme://user:password@host`: only the password is replaced.
        rule(
            RedactionKind::UrlPassword,
            r"[A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]*:(?P<value>[^\s@/]+)@",
        ),
        rule(
            RedactionKind::AwsSecretKey,
            &format!(
                r#"(?i)\baws_(?:secret_access_key|session_token)\b(?:[ \t]*[=:][ \t]*|[ \t]+)(?P<value>{VALUE})"#
            ),
        ),
        rule(
            RedactionKind::BearerToken,
            r"(?i)\bbearer\s+(?P<value>[A-Za-z0-9._~+/=\-]{8,})",
        ),
        // Token shapes. Duplicated from `activity::redact`, which has the
        // same shapes under looser length rules.
        rule(
            RedactionKind::ApiToken,
            r"\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bxox[abposr]-[A-Za-z0-9\-]{10,}|\bsk_(?:live|test)_[A-Za-z0-9]{8,}|\bsk-[A-Za-z0-9_\-]{20,}|\beyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*",
        ),
        rule(
            RedactionKind::AwsAccessKey,
            r"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b",
        ),
        // Name kept, value replaced. Horizontal whitespace only around the
        // separator, so a bare `TOKEN:` at the end of a line never eats the
        // next line.
        rule(
            RedactionKind::SecretAssignment,
            &format!(
                r#"(?i)\b[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY|CLIENT_SECRET|_KEY|DSN)[ \t]*[=:][ \t]*(?P<value>{VALUE})"#
            ),
        ),
    ]
});

static PRIVATE_KEY_BEGIN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"-----BEGIN [A-Z ]*PRIVATE KEY-----").expect("begin pattern"));
static PRIVATE_KEY_END: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"-----END [A-Z ]*PRIVATE KEY-----").expect("end pattern"));

/// Redacts secrets from successive pieces of one terminal's text.
///
/// Stateful only for PEM private keys: a block whose `BEGIN` has no `END` in
/// the same call is redacted to the end of the text and the following calls
/// keep redacting until an `END` arrives.
#[derive(Debug, Default)]
pub struct Redactor {
    inside_private_key: bool,
}

impl Redactor {
    /// A redactor that is not inside a private-key block.
    pub fn new() -> Self {
        Self::default()
    }

    /// Whether the previous call ended inside a private-key block.
    pub fn inside_private_key(&self) -> bool {
        self.inside_private_key
    }

    /// Replace secrets in `text`; return the new text and one
    /// [`RedactionKind`] per replacement, in order of appearance.
    ///
    /// Only the secret itself is replaced for `aws-secret-key`,
    /// `bearer-token`, `secret-assignment` and `url-password`, so names and
    /// context stay readable (`DB_PASSWORD=[redacted: secret-assignment]`).
    /// A private-key block (or the part of one in this call) becomes a single
    /// `[redacted: private-key]`; a call that continues a block from the
    /// previous call reports it again, so every delivery shows what it hides.
    pub fn redact(&mut self, text: &str) -> (String, Vec<RedactionKind>) {
        let mut out = String::with_capacity(text.len());
        let mut kinds = Vec::new();
        let mut rest = text;
        if self.inside_private_key && rest.is_empty() {
            return (out, kinds);
        }
        loop {
            if self.inside_private_key {
                // Swallow up to and including the END line.
                out.push_str(&RedactionKind::PrivateKey.marker());
                kinds.push(RedactionKind::PrivateKey);
                match PRIVATE_KEY_END.find(rest) {
                    Some(end) => {
                        self.inside_private_key = false;
                        rest = &rest[end.end()..];
                    }
                    None => return (out, kinds),
                }
            }
            match PRIVATE_KEY_BEGIN.find(rest) {
                Some(begin) => {
                    redact_plain(&rest[..begin.start()], &mut out, &mut kinds);
                    // The block's own marker is pushed at the top of the loop.
                    self.inside_private_key = true;
                    rest = &rest[begin.end()..];
                }
                None => {
                    redact_plain(rest, &mut out, &mut kinds);
                    return (out, kinds);
                }
            }
        }
    }
}

/// Apply the pattern rules (everything except private keys) to `text`.
fn redact_plain(text: &str, out: &mut String, kinds: &mut Vec<RedactionKind>) {
    let mut spans: Vec<(Range<usize>, RedactionKind)> = Vec::new();
    for rule in RULES.iter() {
        for caps in rule.re.captures_iter(text) {
            let m = caps.name("value").or_else(|| caps.get(0)).expect("match");
            let span = m.range();
            if spans.iter().all(|(taken, _)| !overlaps(taken, &span)) {
                spans.push((span, rule.kind));
            }
        }
    }
    spans.sort_by_key(|(span, _)| span.start);

    let mut cursor = 0;
    for (span, kind) in spans {
        out.push_str(&text[cursor..span.start]);
        out.push_str(&kind.marker());
        kinds.push(kind);
        cursor = span.end;
    }
    out.push_str(&text[cursor..]);
}

fn overlaps(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}
