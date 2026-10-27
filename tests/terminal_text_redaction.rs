//! Adversarial behaviour tests for `nostromo::terminal::redact::Redactor`
//! (review fix-ups T3F-1 and T3F-2).
//!
//! The question every test asks: can a secret get through? Each positive case
//! builds its secret AT RUNTIME from fragments (so no secret-shaped literal sits
//! in the repo), runs it through a fresh `Redactor`, and requires that
//!
//! * the secret value is gone (no whole value and no 12-character window of it
//!   in the text that is left once the `[redacted: <kind>]` markers are removed),
//! * a marker is present, and
//! * the surrounding key name / punctuation survives where that is sensible.
//!
//! Negative cases (ordinary terminal output that merely mentions credentials)
//! must come back byte for byte.
//!
//! Sections: B1 credential-named values, B2 URL passwords, B3 shape coverage,
//! T3F-2 the superset of the tracker guard's corpus, and overlap ordering.
//!
//! Where a rule's intended behaviour is not pinned down by the spec the test
//! says so in a comment instead of encoding a guess.

use nostromo::sensitive_text::{scan, Class, GuardConfig};
use nostromo::terminal::redact::{RedactionKind, Redactor};

#[path = "support/redaction_shapes.rs"]
mod shapes;

// ───────────────────────────── helpers ───────────────────────────────────────

fn redact(text: &str) -> (String, Vec<RedactionKind>) {
    Redactor::new().redact(text)
}

/// `text` with every `[redacted: ...]` marker removed, so a check that "the
/// secret is gone" cannot be fooled by (or trip over) the marker's own letters.
fn strip_markers(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("[redacted: ") {
        out.push_str(&rest[..at]);
        rest = match rest[at..].find(']') {
            Some(end) => &rest[at + end + 1..],
            None => "",
        };
    }
    out.push_str(rest);
    out
}

/// A piece of `secret` that is still readable in `haystack`: the whole value,
/// or (for values of 12+ characters) any 12-character window of it.
fn leaked_fragment(haystack: &str, secret: &str) -> Option<String> {
    const WINDOW: usize = 12;
    if haystack.contains(secret) {
        return Some(secret.to_string());
    }
    let chars: Vec<char> = secret.chars().collect();
    if chars.len() < WINDOW {
        return None;
    }
    chars
        .windows(WINDOW)
        .map(|w| w.iter().collect::<String>())
        .find(|w| haystack.contains(w.as_str()))
}

/// Deterministic xorshift64* generator for fixture bodies.
struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Self {
        Self(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    fn step(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

const UPPER_DIGITS: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const MIXED: &str = "AbCdEfGhJkLmNpQrStUvWxYz23456789";
const LOWER_DIGITS: &str = "abcdefghjkmnpqrstuvwxyz23456789";
const DIGITS: &str = "0123456789";

/// `n` characters drawn from `alphabet`, fixed by `seed`.
fn gen(seed: u64, alphabet: &str, n: usize) -> String {
    let chars: Vec<char> = alphabet.chars().collect();
    let mut rng = Rng::new(seed);
    (0..n)
        .map(|_| chars[(rng.step() % chars.len() as u64) as usize])
        .collect()
}

/// A prefix assembled from fragments so no secret-shaped literal is in source.
fn prefixed(parts: &[&str], body: &str) -> String {
    format!("{}{}", parts.concat(), body)
}

struct Case {
    name: String,
    input: String,
    /// Values that must not be readable afterwards.
    secrets: Vec<String>,
    /// Text that must still be present (names, punctuation, neighbours).
    keep: Vec<String>,
    /// A kind that must be among the reported redactions, when pinned.
    kind: Option<RedactionKind>,
}

fn case(name: &str, input: &str, secrets: &[&str], keep: &[&str]) -> Case {
    Case {
        name: name.to_string(),
        input: input.to_string(),
        secrets: secrets.iter().map(|s| s.to_string()).collect(),
        keep: keep.iter().map(|s| s.to_string()).collect(),
        kind: None,
    }
}

impl Case {
    fn of_kind(mut self, kind: RedactionKind) -> Self {
        self.kind = Some(kind);
        self
    }
}

/// Failures of one case, empty when it holds.
fn check(c: &Case) -> Vec<String> {
    let (out, kinds) = redact(&c.input);
    let left = strip_markers(&out);
    let mut failures = Vec::new();
    let show = format!("[{}] input {:?} -> output {:?}", c.name, c.input, out);
    if kinds.is_empty() {
        failures.push(format!("{show}: no redaction reported"));
    }
    if !out.contains("[redacted: ") {
        failures.push(format!("{show}: no marker in the output"));
    }
    for secret in &c.secrets {
        if let Some(fragment) = leaked_fragment(&left, secret) {
            failures.push(format!("{show}: secret fragment {fragment:?} is readable"));
        }
    }
    for keep in &c.keep {
        if !out.contains(keep.as_str()) {
            failures.push(format!("{show}: lost {keep:?}"));
        }
    }
    if let Some(kind) = c.kind {
        if !kinds.contains(&kind) {
            failures.push(format!("{show}: expected kind {kind} in {kinds:?}"));
        }
    }
    failures
}

fn assert_all_redacted(cases: &[Case]) {
    let failures: Vec<String> = cases.iter().flat_map(check).collect();
    assert!(
        failures.is_empty(),
        "{} of {} cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

fn assert_all_untouched(inputs: &[&str]) {
    let failures: Vec<String> = inputs
        .iter()
        .filter_map(|input| {
            let (out, kinds) = redact(input);
            (out != *input || !kinds.is_empty())
                .then(|| format!("input {input:?} -> {out:?} ({kinds:?})"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "ordinary text was altered:\n{}",
        failures.join("\n")
    );
}

// ───────────────────────────── B1: credential-named values ───────────────────

#[test]
fn credential_values_are_redacted_in_json_yaml_shell_and_flag_syntax() {
    let cases = [
        case(
            "json double-quoted",
            r#"{"password": "hunter2hunter2"}"#,
            &["hunter2hunter2"],
            &[r#""password""#],
        ),
        case(
            "json compact",
            r#"{"api_key":"abcdef123456"}"#,
            &["abcdef123456"],
            &[r#""api_key""#],
        ),
        case(
            "json escaped quotes",
            r#"{\"password\":\"abc123\"}"#,
            &["abc123"],
            &["password"],
        ),
        case(
            "json value inside a bigger object keeps its neighbours",
            r#"{"user":"bob","password":"hunter2hunter2","role":"admin"}"#,
            &["hunter2hunter2"],
            &[r#""user":"bob""#, r#""role":"admin""#],
        ),
        case(
            "double quotes",
            r#"password="dq-s3cr3t-value""#,
            &["dq-s3cr3t-value"],
            &["password="],
        ),
        case(
            "single quotes",
            "password='sq-s3cr3t-value'",
            &["sq-s3cr3t-value"],
            &["password="],
        ),
        case(
            "backticks",
            "password=`bt-s3cr3t-value`",
            &["bt-s3cr3t-value"],
            &["password="],
        ),
        case(
            "yaml unquoted value runs to the end of the line",
            "password: correct horse battery",
            &["correct", "horse", "battery"],
            &["password:"],
        ),
        case(
            "yaml nested key",
            "db:\n  password: correct horse battery\n  host: db1",
            &["correct", "horse", "battery"],
            &["  password:", "  host: db1"],
        ),
        case(
            "shell export",
            r#"export DB_PASS="s3cr3t""#,
            &["s3cr3t"],
            &["export DB_PASS="],
        ),
        case(
            "flag with a space",
            "mysqldump --password hunter2 appdb",
            &["hunter2"],
            &["--password", "appdb"],
        ),
        case(
            "flag with an equals sign",
            "tool --password=hunter2 --verbose",
            &["hunter2"],
            &["--password=", "--verbose"],
        ),
        case(
            "token flag",
            "tool --token abc123 run",
            &["abc123"],
            &["--token", "run"],
        ),
        case(
            "curl -u user:password",
            "curl -u admin:Zq9xW7vB https://example.com/api",
            &["Zq9xW7vB"],
            &["curl -u admin:", "https://example.com/api"],
        ),
        case(
            "mysql -pPASSWORD",
            "mysql -u root -pHunt3rTwo appdb",
            &["Hunt3rTwo"],
            &["mysql -u root", "appdb"],
        ),
        case(
            "sshpass -p PASSWORD",
            "sshpass -p Hunt3rTwo ssh deploy@host",
            &["Hunt3rTwo"],
            &["ssh deploy@host"],
        ),
        case(
            "two credentials on one line",
            "PASSWORD=Alpha7Alpha TOKEN=Bravo8Bravo run",
            &["Alpha7Alpha", "Bravo8Bravo"],
            &["PASSWORD=", "TOKEN=", "run"],
        ),
        case(
            "credential nested after another assignment",
            "FOO=bar,password=hunter2",
            &["hunter2"],
            &["FOO=bar,password="],
        ),
        case(
            "credential in a url query string",
            "url=https://x?a=1&token=abc123",
            &["abc123"],
            &["url=https://x?a=1&token="],
        ),
    ];
    assert_all_redacted(&cases);
}

#[test]
fn every_credential_name_form_redacts_its_value() {
    // The spec's name forms. `pwd` is lower case on purpose: only the shell's
    // upper-case `PWD` working-directory variable is exempt (see the negatives).
    let names = [
        "DB_PASS",
        "PASS",
        "PASSWD",
        "DB_PWD",
        "pwd",
        "SECRET",
        "TOKEN",
        "API_KEY",
        "APIKEY",
        "ACCESS_KEY",
        "PRIVATE_KEY",
        "CLIENT_SECRET",
        "AUTH",
        "CREDENTIALS",
        "SECRET_KEY_BASE",
        "MYAPP_DB_PASSWORD",
    ];
    let value = "Vq7zk2mPd";
    let mut cases: Vec<Case> = names
        .iter()
        .map(|name| {
            case(
                name,
                &format!("{name}={value}"),
                &[value],
                &[&format!("{name}=")],
            )
        })
        .collect();
    cases.push(case(
        "x-api-key header (keyword inside a longer identifier)",
        &format!("x-api-key: {value}"),
        &[value],
        &["x-api-key:"],
    ));
    cases.push(case(
        "x-api-key with the spec's literal value",
        "x-api-key: value",
        &["value"],
        &["x-api-key:"],
    ));
    assert_all_redacted(&cases);
}

#[test]
fn an_unterminated_quote_redacts_to_the_end_of_the_line_and_not_the_next_line() {
    for (input, secrets) in [
        ("PASSWORD=\"abc def\nnext line stays", &["abc", "def"][..]),
        ("PASSWORD='abc def\nnext line stays", &["abc", "def"][..]),
        ("password: \"abc def\nnext line stays", &["abc", "def"][..]),
        (
            "{\"password\": \"abc def\nnext line stays",
            &["abc", "def"][..],
        ),
    ] {
        let (out, kinds) = redact(input);
        let lines: Vec<&str> = out.split('\n').collect();
        assert_eq!(
            lines.len(),
            2,
            "line structure changed for {input:?}: {out:?}"
        );
        assert_eq!(
            lines[1], "next line stays",
            "the redaction ran past the end of the line for {input:?}"
        );
        assert!(!kinds.is_empty(), "nothing redacted for {input:?}");
        for secret in secrets {
            assert!(
                !strip_markers(lines[0]).contains(secret),
                "{secret:?} readable after {input:?}: {out:?}"
            );
        }
    }
}

#[test]
fn ordinary_text_that_mentions_credentials_without_a_value_is_untouched() {
    // Not pinned by the spec: `Enter password: ` with trailing blanks and a
    // prompt followed by a newline. Both carry no value, so they are expected to
    // stay as they are.
    assert_all_untouched(&[
        "Enter password:",
        "Enter password: ",
        "Enter password:\nhello",
        "[sudo] password for hammer:",
        "Reset password email sent",
        "PWD=/home/u",
        "OLDPWD=/",
        "SSH_AUTH_SOCK=/tmp/agent.sock",
        "GIT_AUTHOR_NAME=Ada",
        "TOKENIZER=whitespace",
        "MONKEY=banana",
        "KEYBOARD=us",
        "mkdir -p /tmp/x",
        "ssh -p 22 host",
        "docker run -u 1000:1000 img",
        "git push -u origin main",
        "ls -la",
        "commit 3f786850e387550fdab836ed7e6dc881de23001b",
        "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
        "id=550e8400-e29b-41d4-a716-446655440000",
        "https://example.com:8080/img@2x.png",
        "https://host:4873/@scope/pkg",
        "postgres://user@host/db",
        "ssh://git@github.com/org/repo.git",
    ]);
}

#[test]
fn a_public_key_block_is_untouched() {
    let body_a = gen(1, MIXED, 64);
    let body_b = gen(2, MIXED, 64);
    let block =
        format!("-----BEGIN PUBLIC KEY-----\n{body_a}\n{body_b}\n-----END PUBLIC KEY-----\nafter");
    let (out, kinds) = redact(&block);
    assert_eq!(out, block);
    assert!(kinds.is_empty(), "{kinds:?}");
}

// ───────────────────────────── B2: URL passwords ─────────────────────────────

#[test]
fn a_url_password_is_replaced_whatever_it_contains_and_only_the_password() {
    // (input, what must remain once the password and its marker are gone)
    let cases = [
        ("postgres://u:p@ss@host/db", "postgres://u:@host/db"),
        ("postgres://u:pa/ss@host/db", "postgres://u:@host/db"),
        (
            "mongodb+srv://u:p@ss@cluster0.example.net/db",
            "mongodb+srv://u:@cluster0.example.net/db",
        ),
        ("redis://:pa/ss@host:6379/0", "redis://:@host:6379/0"),
        ("amqp://guest:g/u@est@host//", "amqp://guest:@host//"),
        (
            "https://user:pass@example.com/path",
            "https://user:@example.com/path",
        ),
        (
            "smtp://user@example.com:pass@mail.example.net",
            "smtp://user@example.com:@mail.example.net",
        ),
        (
            "see postgres://u:p@ss@host/db for details",
            "see postgres://u:@host/db for details",
        ),
    ];
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|(input, expected_rest)| {
            let (out, kinds) = redact(input);
            let rest = strip_markers(&out);
            (rest != *expected_rest || kinds != [RedactionKind::UrlPassword])
                .then(|| format!("input {input:?} -> {out:?} ({kinds:?}), left {rest:?}"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "URL passwords mishandled:\n{}",
        failures.join("\n")
    );
}

// ───────────────────────────── B3: shape coverage ────────────────────────────

fn token_cases() -> Vec<Case> {
    let mut cases = Vec::new();
    let mut add = |name: &str, token: String, body: String, prefix: &str| {
        cases.push(
            Case {
                name: name.to_string(),
                input: format!("fetching with {token} now"),
                secrets: vec![token, body],
                keep: vec!["fetching with ".to_string(), " now".to_string()],
                kind: Some(RedactionKind::ApiToken),
            }
            .with_absent_prefix(prefix),
        );
    };

    let body = |seed: u64, alphabet: &str, n: usize| gen(seed, alphabet, n);
    let b = body(11, MIXED, 20);
    add("gitlab glpat-", prefixed(&["glp", "at-"], &b), b, "glpat-");
    let b = body(12, MIXED, 36);
    add("npm_ (36 chars)", prefixed(&["np", "m_"], &b), b, "npm_");
    let b = body(13, MIXED, 35);
    add(
        "google AIza (35 chars)",
        prefixed(&["AI", "za"], &b),
        b,
        "AIza",
    );
    let b = format!(
        "1-{}-{}-{}",
        body(14, UPPER_DIGITS, 11),
        body(15, DIGITS, 13),
        body(16, LOWER_DIGITS, 32)
    );
    add("slack xapp-", prefixed(&["xa", "pp-"], &b), b, "xapp-");
    for (i, letter) in ["b", "p"].iter().enumerate() {
        let b = format!(
            "{}-{}-{}",
            body(20 + i as u64, DIGITS, 12),
            body(30 + i as u64, DIGITS, 13),
            body(40 + i as u64, MIXED, 24)
        );
        let prefix = format!("xox{letter}-");
        add(
            &format!("slack {prefix}"),
            prefixed(&["xo", "x", *letter, "-"], &b),
            b,
            &prefix,
        );
    }
    let b = format!("api03-{}", body(50, MIXED, 40));
    add(
        "anthropic sk-ant-",
        prefixed(&["sk-", "ant-"], &b),
        b,
        "sk-ant-",
    );
    let b = body(51, MIXED, 48);
    add("openai sk-", prefixed(&["sk", "-"], &b), b, "sk-");
    let b = body(52, MIXED, 40);
    add(
        "openai sk-proj-",
        prefixed(&["sk-", "proj-"], &b),
        b,
        "sk-proj-",
    );
    for (i, letter) in ["p", "o", "u", "s", "r"].iter().enumerate() {
        let b = body(60 + i as u64, MIXED, 36);
        let prefix = format!("gh{letter}_");
        add(
            &format!("github {prefix}"),
            prefixed(&["gh", *letter, "_"], &b),
            b,
            &prefix,
        );
    }
    let b = format!("11{}_{}", body(70, UPPER_DIGITS, 20), body(71, MIXED, 50));
    add(
        "github fine-grained github_pat_",
        prefixed(&["github", "_pat_"], &b),
        b,
        "github_pat_",
    );
    cases
}

impl Case {
    /// Also require that the token's prefix is not left behind (a stub).
    fn with_absent_prefix(mut self, prefix: &str) -> Self {
        self.secrets.push(prefix.to_string());
        self
    }
}

#[test]
fn provider_token_shapes_are_redacted_as_api_tokens() {
    assert_all_redacted(&token_cases());
}

#[test]
fn aws_access_key_ids_are_redacted_including_glued_and_lower_case() {
    let mut cases = Vec::new();
    for (i, prefix) in ["AKIA", "ASIA", "AGPA", "AIDA", "AROA"].iter().enumerate() {
        let id = format!("{prefix}{}", gen(100 + i as u64, UPPER_DIGITS, 16));
        cases.push(
            case(
                &format!("{prefix} id"),
                &format!("aws id {id} end"),
                &[&id],
                &["aws id ", " end"],
            )
            .of_kind(RedactionKind::AwsAccessKey),
        );
        cases.push(
            case(
                &format!("{prefix} id glued after an underscore"),
                &format!("key_{id}"),
                &[&id],
                &["key_"],
            )
            .of_kind(RedactionKind::AwsAccessKey),
        );
        let lower = format!(
            "{}{}",
            prefix.to_ascii_lowercase(),
            gen(110 + i as u64, LOWER_DIGITS, 16)
        );
        cases.push(
            case(
                &format!("{prefix} id in lower case"),
                &format!("id={lower}"),
                &[&lower],
                &["id="],
            )
            .of_kind(RedactionKind::AwsAccessKey),
        );
    }
    assert_all_redacted(&cases);
}

#[test]
fn aws_secret_access_keys_and_session_tokens_are_redacted_by_context() {
    let secret = format!(
        "{}/{}+{}",
        gen(120, MIXED, 18),
        gen(121, MIXED, 10),
        gen(122, MIXED, 10)
    );
    let session = gen(123, MIXED, 120);
    let cases = [
        case(
            "ini style with spaces",
            &format!("aws_secret_access_key = {secret}"),
            &[&secret],
            &["aws_secret_access_key = "],
        ),
        case(
            "env style",
            &format!("AWS_SECRET_ACCESS_KEY={secret}"),
            &[&secret],
            &["AWS_SECRET_ACCESS_KEY="],
        ),
        case(
            "json quoted",
            &format!(r#"{{"aws_secret_access_key": "{secret}"}}"#),
            &[&secret],
            &[r#""aws_secret_access_key""#],
        ),
        case(
            "json quoted upper case, compact",
            &format!(r#"{{"AWS_SECRET_ACCESS_KEY":"{secret}"}}"#),
            &[&secret],
            &[r#""AWS_SECRET_ACCESS_KEY""#],
        ),
        case(
            "session token env",
            &format!("AWS_SESSION_TOKEN={session}"),
            &[&session],
            &["AWS_SESSION_TOKEN="],
        ),
        case(
            "session token ini",
            &format!("aws_session_token: {session}"),
            &[&session],
            &["aws_session_token:"],
        ),
        case(
            "session token json quoted",
            &format!(r#"{{"aws_session_token": "{session}"}}"#),
            &[&session],
            &[r#""aws_session_token""#],
        ),
    ];
    assert_all_redacted(&cases);
}

#[test]
fn authorization_headers_lose_their_credentials_and_keep_the_scheme() {
    let basic = "dXNlcjpGYWtlUGFzczEyMw==";
    let bearer = gen(130, MIXED, 28);
    let opaque = gen(131, MIXED, 30);
    let cases = [
        case(
            "basic",
            &format!("Authorization: Basic {basic}"),
            &[basic],
            &["Authorization: Basic "],
        )
        .of_kind(RedactionKind::BasicAuth),
        case(
            "basic lower case header and scheme",
            &format!("authorization: basic {basic}"),
            &[basic],
            &["authorization: basic "],
        ),
        case(
            "basic inside a curl -H argument keeps the closing quote",
            &format!("curl -H \"Authorization: Basic {basic}\" https://example.com/x"),
            &[basic],
            &[
                "curl -H \"Authorization: Basic ",
                "\" https://example.com/x",
            ],
        ),
        case(
            "bearer",
            &format!("Authorization: Bearer {bearer}"),
            &[&bearer],
            &["Authorization: Bearer "],
        )
        .of_kind(RedactionKind::BearerToken),
        case(
            "bare bearer",
            &format!("sent Bearer {bearer} to the api"),
            &[&bearer],
            &["sent Bearer ", " to the api"],
        )
        .of_kind(RedactionKind::BearerToken),
        case(
            "bearer in json",
            &format!(r#"{{"Authorization": "Bearer {bearer}"}}"#),
            &[&bearer],
            &["Bearer"],
        ),
        case(
            "other scheme: Negotiate",
            &format!("Authorization: Negotiate {opaque}"),
            &[&opaque],
            &["Authorization: Negotiate"],
        ),
        case(
            "other scheme: Token",
            &format!("Authorization: Token {opaque}"),
            &[&opaque],
            &["Authorization: Token"],
        ),
        case(
            "other scheme: ApiKey",
            &format!("Authorization: ApiKey {opaque}"),
            &[&opaque],
            &["Authorization: ApiKey"],
        ),
    ];
    assert_all_redacted(&cases);
}

#[test]
fn a_digest_authorization_header_with_quoted_parameters_loses_its_response_hash() {
    // The spec says "Authorization: Digest ...-ish scheme with credentials".
    // The module docs call the Digest response hash a deliberate gap, so this
    // case is a doubt for Cody rather than a settled requirement: a Digest
    // header carries a response hash that authenticates the request.
    let response = gen(140, "0123456789abcdef", 32);
    let input = format!(
        "Authorization: Digest username=\"admin\", realm=\"api\", nonce=\"abc\", uri=\"/x\", response=\"{response}\""
    );
    let (out, kinds) = redact(&input);
    assert!(!kinds.is_empty(), "nothing redacted in {input:?}");
    assert!(
        !strip_markers(&out).contains(&response),
        "digest response hash readable: {out:?}"
    );
}

#[test]
fn jwts_are_redacted() {
    let header = prefixed(&["ey", "JhbGciOiJIUzI1NiJ9"], "");
    let payload = prefixed(&["ey", "JzdWIiOiI"], &gen(150, UPPER_DIGITS, 24));
    let signature = gen(151, MIXED, 43);
    let jwt = format!("{header}.{payload}.{signature}");
    let cases = [
        case(
            "bare jwt",
            &format!("token is {jwt} ok"),
            &[&jwt, &payload, &signature, "eyJ"],
            &["token is ", " ok"],
        ),
        case(
            "jwt in a cookie-like pair",
            &format!("session={jwt}; path=/"),
            &[&jwt, &payload, &signature, "eyJ"],
            &["; path=/"],
        ),
    ];
    assert_all_redacted(&cases);
}

fn pem_block(label: &str, seed: u64) -> (String, Vec<String>) {
    let body: Vec<String> = (0..4).map(|i| gen(seed + i, MIXED, 64)).collect();
    let mut text = format!("-----BEGIN {label}-----\n");
    for line in &body {
        text.push_str(line);
        text.push('\n');
    }
    text.push_str(&format!("-----END {label}-----"));
    (text, body)
}

#[test]
fn every_private_key_flavour_collapses_to_one_marker_line() {
    let labels = [
        "RSA PRIVATE KEY",
        "EC PRIVATE KEY",
        "OPENSSH PRIVATE KEY",
        "ENCRYPTED PRIVATE KEY",
        "PRIVATE KEY",
        "DSA PRIVATE KEY",
        "PGP PRIVATE KEY BLOCK",
    ];
    for (i, label) in labels.iter().enumerate() {
        let (block, body) = pem_block(label, 200 + i as u64 * 10);
        let input = format!("ordinary line before\n{block}\nordinary line after");
        let (out, kinds) = redact(&input);
        let lines: Vec<&str> = out.split('\n').collect();
        assert_eq!(
            lines,
            vec![
                "ordinary line before",
                "[redacted: private-key]",
                "ordinary line after"
            ],
            "{label}: {out:?}"
        );
        assert_eq!(kinds, [RedactionKind::PrivateKey], "{label}");
        for line in body {
            assert!(!out.contains(&line[..16]), "{label}: key body readable");
        }
    }
}

#[test]
fn pgp_armor_headers_inside_a_private_key_block_do_not_leak() {
    let body = gen(300, MIXED, 64);
    let input = format!(
        "-----BEGIN PGP PRIVATE KEY BLOCK-----\nVersion: GnuPG v2\n\n{body}\n=AbCd\n-----END PGP PRIVATE KEY BLOCK-----\ndone"
    );
    let (out, _) = redact(&input);
    assert_eq!(out, "[redacted: private-key]\ndone");
}

#[test]
fn ssn_shaped_numbers_are_redacted_with_or_without_a_label() {
    let cases = [
        case(
            "bare",
            "value 219-09-9999 end",
            &["219-09-9999"],
            &["value ", " end"],
        )
        .of_kind(RedactionKind::Ssn),
        case(
            "with label",
            "SSN: 219-09-9999",
            &["219-09-9999"],
            &["SSN: "],
        )
        .of_kind(RedactionKind::Ssn),
        case("assignment", "ssn=412-67-8901", &["412-67-8901"], &["ssn="])
            .of_kind(RedactionKind::Ssn),
        case(
            "end of a sentence",
            "Her number is 531-22-4410.",
            &["531-22-4410"],
            &["Her number is ", "."],
        )
        .of_kind(RedactionKind::Ssn),
    ];
    assert_all_redacted(&cases);
}

#[test]
fn numbers_that_cannot_be_ssns_are_left_alone() {
    // Areas 000, 666 and 9xx are never issued; a dashed number with a fourth
    // group is something else (an account or part number). The spec names
    // these; group 00 and serial 0000 are not mentioned and not tested.
    assert_all_untouched(&[
        "000-12-3456",
        "666-12-3456",
        "900-12-3456",
        "987-65-4321",
        "123-45-6789-12",
        "part no 123-45-6789-12 shipped",
    ]);
}

#[test]
fn labelled_birth_dates_are_redacted_and_unlabelled_dates_are_not() {
    let cases = [
        case(
            "DOB with slashes",
            "DOB: 03/14/1980",
            &["03/14/1980"],
            &["DOB: "],
        )
        .of_kind(RedactionKind::DateOfBirth),
        case(
            "date of birth with an iso date",
            "date of birth 1980-03-14",
            &["1980-03-14"],
            &["date of birth "],
        )
        .of_kind(RedactionKind::DateOfBirth),
        case(
            "born with a month name",
            "born March 14, 1980",
            &["March 14, 1980", "1980"],
            &["born "],
        )
        .of_kind(RedactionKind::DateOfBirth),
        case(
            "inside a sentence",
            "Resident was born on 1/2/1950 and moved in last spring",
            &["1/2/1950"],
            &["Resident was born on ", " and moved in last spring"],
        )
        .of_kind(RedactionKind::DateOfBirth),
    ];
    assert_all_redacted(&cases);
    assert_all_untouched(&[
        "Meeting on 03/14/1980",
        "released 1980-03-14",
        "Deployed on March 14, 1980 at noon",
    ]);
}

// ───────────────────────────── T3F-2: superset of the guard's corpus ─────────

const POSITIVES_RAW: &str = include_str!("fixtures/sensitive_text/positives.txt");

/// `(class, text)` for every corpus line, with the U+00A6 mask removed.
fn guard_positives() -> Vec<(String, String)> {
    POSITIVES_RAW
        .replace('\u{a6}', "")
        .lines()
        .filter(|l| !l.trim().is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_once('\t'))
        .map(|(class, text)| (class.to_string(), text.to_string()))
        .collect()
}

#[test]
fn every_secret_ssn_and_dob_line_of_the_guards_corpus_is_changed_by_the_redactor() {
    let lines: Vec<(String, String)> = guard_positives()
        .into_iter()
        .filter(|(class, _)| matches!(class.as_str(), "secret" | "ssn" | "dob"))
        .collect();
    assert!(
        lines.len() >= 50,
        "corpus loader found only {} secret/ssn/dob lines",
        lines.len()
    );
    let missed: Vec<String> = lines
        .iter()
        .filter_map(|(class, text)| {
            let (out, kinds) = Redactor::new().redact(text);
            (kinds.is_empty() || out == *text).then(|| format!("[{class}] {text}"))
        })
        .collect();
    assert!(
        missed.is_empty(),
        "the redactor left {} guard-positive lines unchanged:\n{}",
        missed.len(),
        missed.join("\n")
    );
}

#[test]
fn the_guard_still_flags_the_corpus_lines_the_redactor_is_held_to() {
    // Proves the superset check above is not satisfied by weakening the guard.
    let config = GuardConfig::default();
    let missed: Vec<String> = guard_positives()
        .into_iter()
        .filter_map(|(class, text)| {
            let wanted = match class.as_str() {
                "secret" => Class::Secret,
                "ssn" => Class::Ssn,
                "dob" => Class::Dob,
                _ => return None,
            };
            (!scan(&text, &config).iter().any(|f| f.class == wanted))
                .then(|| format!("[{class}] {text}"))
        })
        .collect();
    assert!(
        missed.is_empty(),
        "sensitive_text::scan no longer flags:\n{}",
        missed.join("\n")
    );
}

// ───────────────────────────── invisible and look-alike evasion ──────────────
//
// The Redactor is called here on RAW text, with no assembler in front of it: it
// must be robust on its own (defence in depth). It matches on a normalised view
// (hidden characters dropped or read as a space, NFKC, dash fold, digit fold,
// combining marks removed), keeps the ORIGINAL text around what it redacts, and
// replaces the whole original span, hidden characters inside it included.

const ZWSP: char = '\u{200b}';
const ZWNJ: char = '\u{200c}';
const ZWJ: char = '\u{200d}';
const WORD_JOINER: char = '\u{2060}';
const SOFT_HYPHEN: char = '\u{ad}';
const BOM: char = '\u{feff}';

/// Hidden characters the Redactor must see through.
const HIDDEN: [char; 6] = [ZWSP, ZWNJ, ZWJ, WORD_JOINER, SOFT_HYPHEN, BOM];

fn is_hidden(c: char) -> bool {
    matches!(c,
        '\u{ad}' | '\u{34f}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}'
        | '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{2069}' | '\u{feff}'
        | '\u{e0000}'..='\u{e007f}')
}

/// The test's own view of what a reader would see: hidden characters gone,
/// fullwidth and Arabic-Indic forms and the dash look-alikes folded to ASCII.
/// Used only to look for leaks, never to build the expected output.
fn fold(text: &str) -> String {
    text.chars()
        .filter(|c| !is_hidden(*c))
        .map(|c| match c {
            '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap_or(c),
            '\u{3000}' => ' ',
            '\u{2010}'..='\u{2015}' | '\u{2212}' | '\u{fe58}' | '\u{fe63}' => '-',
            '\u{660}'..='\u{669}' => char::from_u32('0' as u32 + (c as u32 - 0x660)).unwrap_or(c),
            '\u{6f0}'..='\u{6f9}' => char::from_u32('0' as u32 + (c as u32 - 0x6f0)).unwrap_or(c),
            _ => c,
        })
        .collect()
}

/// ASCII letters and digits of `text` as their fullwidth forms.
fn wide(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                char::from_u32(c as u32 + 0xfee0).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

/// `text` with `hidden` inserted before byte offset `at` (ASCII text only).
fn splice(text: &str, at: usize, hidden: char) -> String {
    format!("{}{hidden}{}", &text[..at], &text[at..])
}

/// A case plus the folded-view leak check: a secret must not be readable in the
/// output even after hidden characters are removed and look-alikes folded.
fn check_folded(c: &Case) -> Vec<String> {
    let mut failures = check(c);
    let (out, _) = redact(&c.input);
    let left = fold(&strip_markers(&out));
    for secret in &c.secrets {
        if let Some(fragment) = leaked_fragment(&left, &fold(secret)) {
            failures.push(format!(
                "[{}] input {:?} -> output {:?}: secret fragment {fragment:?} is readable once hidden characters are removed",
                c.name, c.input, out
            ));
        }
    }
    failures
}

fn assert_all_redacted_folded(cases: &[Case]) {
    let failures: Vec<String> = cases.iter().flat_map(check_folded).collect();
    assert!(
        failures.is_empty(),
        "{} of {} cases failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n")
    );
}

#[test]
fn a_token_with_a_hidden_character_inside_is_replaced_whole_and_nothing_hidden_is_left() {
    let (token, body) = ghp_token();
    for hidden in HIDDEN {
        for at in [2, 4, 20] {
            let evaded = splice(&token, at, hidden);
            let (out, kinds) = redact(&format!("see {evaded} now"));
            assert_eq!(
                out, "see [redacted: api-token] now",
                "hidden U+{:04X} at {at}",
                hidden as u32
            );
            assert_eq!(kinds, [RedactionKind::ApiToken]);
            assert!(!out.contains(&body[..12]) && !out.contains(hidden));
        }
    }
}

#[test]
fn a_token_assignment_with_a_hidden_character_in_the_token_keeps_the_name() {
    let (token, body) = ghp_token();
    let (out, kinds) = redact(&format!("GITHUB_TOKEN={}", splice(&token, 10, ZWSP)));
    assert_eq!(out, "GITHUB_TOKEN=[redacted: api-token]");
    assert_eq!(kinds, [RedactionKind::ApiToken]);
    assert!(!out.contains(&body[..12]));
}

fn ssn_text() -> String {
    ["219", "09", "9999"].join("-")
}

#[test]
fn an_ssn_written_with_hidden_or_look_alike_characters_is_redacted() {
    let ssn = ssn_text();
    let tail = "09-9999";
    let arabic = |s: &str| -> String {
        s.chars()
            .map(|c| match c.to_digit(10) {
                Some(d) => char::from_u32(0x660 + d).unwrap_or(c),
                None => c,
            })
            .collect()
    };
    let with_combining = format!("2\u{301}{}", &ssn[1..]);
    let variants: Vec<(&str, String)> = vec![
        ("zwsp after the first group's dash", splice(&ssn, 4, ZWSP)),
        ("zwsp inside the first group", splice(&ssn, 1, ZWSP)),
        ("zwsp before the dash", splice(&ssn, 3, ZWSP)),
        (
            "soft hyphen inside the last group",
            splice(&ssn, 8, SOFT_HYPHEN),
        ),
        ("bom inside the middle group", splice(&ssn, 5, BOM)),
        ("zero width joiner", splice(&ssn, 4, ZWJ)),
        ("word joiner", splice(&ssn, 4, WORD_JOINER)),
        ("fullwidth digits", wide(&ssn)),
        (
            "fullwidth digits and fullwidth hyphens",
            wide(&ssn).replace('-', "\u{ff0d}"),
        ),
        ("arabic-indic digits", arabic(&ssn)),
        ("en dashes", ssn.replace('-', "\u{2013}")),
        ("em dashes", ssn.replace('-', "\u{2014}")),
        ("minus signs", ssn.replace('-', "\u{2212}")),
        ("unicode hyphens", ssn.replace('-', "\u{2010}")),
        ("non-breaking hyphens", ssn.replace('-', "\u{2011}")),
        (
            "mixed dash look-alikes",
            ssn.replacen('-', "\u{2013}", 1)
                .replacen('-', "\u{2212}", 1),
        ),
        ("a combining mark on a digit", with_combining),
        (
            "en dash and a hidden character",
            splice(&ssn, 4, ZWSP).replace('-', "\u{2013}"),
        ),
    ];
    let cases: Vec<Case> = variants
        .iter()
        .map(|(name, evaded)| {
            case(
                name,
                &format!("SSN {evaded} on file"),
                &[&ssn, tail, evaded],
                &["SSN ", " on file"],
            )
            .of_kind(RedactionKind::Ssn)
        })
        .collect();
    assert_all_redacted_folded(&cases);
}

#[test]
fn an_ssn_whose_label_is_glued_to_it_by_a_hidden_character_is_redacted() {
    // A hidden run may stand in for a space: `SSN<hidden>219-09-9999`.
    let ssn = ssn_text();
    let cases: Vec<Case> = HIDDEN
        .iter()
        .flat_map(|hidden| {
            [
                case(
                    "label, hidden, ssn",
                    &format!("SSN{hidden}{ssn} on file"),
                    &[&ssn, "09-9999"],
                    &["SSN", " on file"],
                ),
                case(
                    "label, colon, hidden, ssn",
                    &format!("SSN:{hidden}{ssn} on file"),
                    &[&ssn, "09-9999"],
                    &["SSN:", " on file"],
                ),
            ]
        })
        .map(|c| c.of_kind(RedactionKind::Ssn))
        .collect();
    assert_all_redacted_folded(&cases);
}

#[test]
fn a_credential_name_split_or_spelled_in_fullwidth_still_redacts_its_value() {
    let value = gen(510, MIXED, 14);
    let wide_value = wide(&value);
    let cases = [
        case(
            "zwsp inside the name",
            &format!("pass\u{200b}word={value}"),
            &[&value],
            &["pass\u{200b}word="],
        ),
        case(
            "zwsp inside an upper-case name",
            &format!("PASS\u{200b}WORD={value}"),
            &[&value],
            &["PASS\u{200b}WORD="],
        ),
        case(
            "soft hyphen inside the name, yaml style",
            &format!("pass\u{ad}word: {value}"),
            &[&value],
            &["pass\u{ad}word: "],
        ),
        case(
            "bom inside a prefixed name",
            &format!("DB_PASS\u{feff}WORD={value}"),
            &[&value],
            &["DB_PASS\u{feff}WORD="],
        ),
        case(
            "hidden character after the name",
            &format!("password\u{200b}={value}"),
            &[&value],
            &["password"],
        ),
        case(
            "hidden character inside the value",
            &format!("password={}\u{200b}{}", &value[..7], &value[7..]),
            &[&value],
            &["password="],
        ),
        case(
            "fullwidth name",
            &format!("ｐａｓｓｗｏｒｄ={value}"),
            &[&value],
            &["ｐａｓｓｗｏｒｄ="],
        ),
        case(
            "fullwidth upper-case name",
            &format!("ＤＢ_ＰＡＳＳＷＯＲＤ={value}"),
            &[&value],
            &["ＤＢ_ＰＡＳＳＷＯＲＤ="],
        ),
        case(
            "fullwidth name and fullwidth equals sign",
            &format!("ｐａｓｓｗｏｒｄ＝{value}"),
            &[&value],
            &["ｐａｓｓｗｏｒｄ"],
        ),
        case(
            "fullwidth name and fullwidth colon",
            &format!("ｐａｓｓｗｏｒｄ：{value}"),
            &[&value],
            &["ｐａｓｓｗｏｒｄ"],
        ),
        case(
            "ascii name and fullwidth equals sign",
            &format!("password＝{value}"),
            &[&value],
            &["password"],
        ),
        case(
            "ascii name and fullwidth colon",
            &format!("password：{value}"),
            &[&value],
            &["password"],
        ),
        case(
            "fullwidth value",
            &format!("password={wide_value}"),
            &[&wide_value, &value],
            &["password="],
        ),
        case(
            "fullwidth token name",
            &format!("ＧＩＴＨＵＢ_ＴＯＫＥＮ={value}"),
            &[&value],
            &["ＧＩＴＨＵＢ_ＴＯＫＥＮ"],
        ),
    ];
    assert_all_redacted_folded(&cases);
}

#[test]
fn aws_keys_bearer_values_and_url_passwords_with_hidden_characters_are_redacted() {
    let id = format!("AKIA{}", gen(540, UPPER_DIGITS, 16));
    let bearer = gen(541, MIXED, 24);
    let pw = gen(542, MIXED, 14);
    let aws_secret = gen(543, MIXED, 40);
    let cases = [
        case(
            "zwsp after the aws key prefix",
            &format!("key {} used", splice(&id, 4, ZWSP)),
            &[&id, &id[4..]],
            &["key ", " used"],
        )
        .of_kind(RedactionKind::AwsAccessKey),
        case(
            "soft hyphen inside the aws key prefix",
            &format!("key {} used", splice(&id, 2, SOFT_HYPHEN)),
            &[&id, &id[4..]],
            &["key ", " used"],
        )
        .of_kind(RedactionKind::AwsAccessKey),
        case(
            "bom inside the aws key body",
            &format!("key {} used", splice(&id, 12, BOM)),
            &[&id, &id[4..]],
            &["key ", " used"],
        )
        .of_kind(RedactionKind::AwsAccessKey),
        case(
            "hidden character inside an aws secret value",
            &format!("aws_secret_access_key={}", splice(&aws_secret, 20, ZWSP)),
            &[&aws_secret],
            &["aws_secret_access_key="],
        )
        .of_kind(RedactionKind::AwsSecretKey),
        case(
            "zwsp inside a bearer value",
            &format!("sent Bearer {} ok", splice(&bearer, 10, ZWSP)),
            &[&bearer, &bearer[10..]],
            &["sent Bearer ", " ok"],
        )
        .of_kind(RedactionKind::BearerToken),
        case(
            "soft hyphen inside the word bearer",
            &format!("sent Bear\u{ad}er {bearer} ok"),
            &[&bearer],
            &["sent ", " ok"],
        ),
        case(
            "hidden character standing in for the space after bearer",
            &format!("sent Bearer\u{200b}{bearer} ok"),
            &[&bearer],
            &["sent Bearer", " ok"],
        ),
        case(
            "zwsp inside a url password",
            &format!("postgres://app:{}@db.internal/main", splice(&pw, 6, ZWSP)),
            &[&pw, &pw[6..]],
            &["postgres://app:", "@db.internal/main"],
        )
        .of_kind(RedactionKind::UrlPassword),
        case(
            "soft hyphen inside a url password",
            &format!(
                "postgres://app:{}@db.internal/main",
                splice(&pw, 3, SOFT_HYPHEN)
            ),
            &[&pw, &pw[3..]],
            &["postgres://app:", "@db.internal/main"],
        )
        .of_kind(RedactionKind::UrlPassword),
        case(
            "bom at the start of a url password",
            &format!("postgres://app:\u{feff}{pw}@db.internal/main"),
            &[&pw],
            &["postgres://app:", "@db.internal/main"],
        )
        .of_kind(RedactionKind::UrlPassword),
    ];
    assert_all_redacted_folded(&cases);
}

#[test]
fn basic_authorization_with_hidden_characters_is_redacted() {
    let basic = format!("{}==", gen(550, MIXED, 20));
    let cases = [
        case(
            "zwsp inside the credentials",
            &format!("Authorization: Basic {}", splice(&basic, 9, ZWSP)),
            &[&basic, &basic[9..]],
            &["Authorization: Basic "],
        )
        .of_kind(RedactionKind::BasicAuth),
        case(
            "soft hyphen inside the header name",
            &format!("Auth\u{ad}orization: Basic {basic}"),
            &[&basic],
            &["Auth\u{ad}orization: "],
        ),
        case(
            "zwsp inside the scheme word",
            &format!("Authorization: Ba\u{200b}sic {basic}"),
            &[&basic],
            &["Authorization: "],
        ),
        case(
            "hidden character standing in for the space after the colon",
            &format!("Authorization:\u{200b}Basic {basic}"),
            &[&basic],
            &["Authorization:"],
        ),
        case(
            "hidden character standing in for the space before the credentials",
            &format!("Authorization: Basic\u{200b}{basic}"),
            &[&basic],
            &["Authorization: "],
        ),
    ];
    assert_all_redacted_folded(&cases);
}

#[test]
fn a_birth_date_with_hidden_or_look_alike_characters_is_redacted() {
    let date = format!("{:02}/{}/{}", 3, 14, 1941);
    let iso = format!("{}-{:02}-{:02}", 1941, 3, 14);
    let cases = [
        case(
            "zwsp between the label and the colon",
            &format!("Resident DOB\u{200b}: {date} on file"),
            &[&date, "14/1941"],
            &["Resident ", " on file"],
        ),
        case(
            "zwsp inside the label",
            &format!("Resident D\u{200b}OB: {date} on file"),
            &[&date, "14/1941"],
            &["Resident ", " on file"],
        ),
        case(
            "soft hyphen inside date of birth",
            &format!("Resident date of bi\u{ad}rth: {date} on file"),
            &[&date, "14/1941"],
            &["Resident ", " on file"],
        ),
        case(
            "zwsp inside the date",
            &format!("Resident DOB: {} on file", splice(&date, 3, ZWSP)),
            &[&date, "14/1941"],
            &["Resident DOB: ", " on file"],
        ),
        case(
            "bom inside the year",
            &format!("Resident DOB: {} on file", splice(&date, 8, BOM)),
            &[&date, "14/1941", "1941"],
            &["Resident DOB: ", " on file"],
        ),
        case(
            "fullwidth label",
            &format!("Resident ＤＯＢ: {date} on file"),
            &[&date, "14/1941"],
            &["Resident ", " on file"],
        ),
        case(
            "fullwidth digits",
            &format!("Resident DOB: {} on file", wide(&date)),
            &[&date, &wide(&date)],
            &["Resident DOB: ", " on file"],
        ),
        case(
            "en dashes in an iso date",
            &format!("Resident DOB: {} on file", iso.replace('-', "\u{2013}")),
            &[&iso, "03-14"],
            &["Resident DOB: ", " on file"],
        ),
        case(
            "label glued to the date by a hidden character",
            &format!("Resident born\u{200b}{date} on file"),
            &[&date, "14/1941"],
            &["Resident ", " on file"],
        ),
    ];
    let cases: Vec<Case> = cases
        .into_iter()
        .map(|c| c.of_kind(RedactionKind::DateOfBirth))
        .collect();
    assert_all_redacted_folded(&cases);
}

#[test]
fn ordinary_text_with_hidden_fullwidth_and_dash_characters_comes_back_byte_for_byte() {
    let hash = gen(560, "0123456789abcdef", 64);
    let spliced_hash = splice(&hash, 30, ZWSP);
    let inputs: Vec<String> = [
        "Ｒｅｐｏｒｔ ＡＢＣ is ready",
        "range a–b and 2024–2025 — done, minus − sign, hyphen ‐ too",
        "zero\u{200b}width\u{200b}space in prose and a\u{200d}b\u{200c}c\u{2060}d",
        "soft\u{ad}hyphen and \u{feff}BOM at the start",
        "caf\u{e9} cafe\u{301} \u{65e5}\u{672c}\u{8a9e} \u{1F600} naïve",
        "ＴＯＫＥＮＩＺＥＲ=fast",
        "Ｐａｓｓｗｏｒｄ policy: use a long phrase",
        "call 555–1212 or ５５５-１２１２ before noon",
        "Ｖ２ release ０１２ shipped",
        "ref ０００-１２-３４５６ is not an ssn",
        "pass\u{200b}ing grade and by\u{ad}pass road",
        "\u{200b}\u{feff}",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain([
        format!("sha256:{spliced_hash} layer"),
        format!("id {}-{}", splice("123e4567", 3, ZWSP), "e89b-12d3"),
    ])
    .collect();
    let refs: Vec<&str> = inputs.iter().map(String::as_str).collect();
    assert_all_untouched(&refs);
}

#[test]
fn text_around_a_redaction_is_never_rewritten_to_ascii() {
    let (token, _) = ghp_token();
    let value = gen(570, MIXED, 14);
    let (out, kinds) = redact(&format!("ＡＢＣ a–b password={value} ｅｎｄ"));
    assert_eq!(
        out,
        "ＡＢＣ a–b password=[redacted: secret-assignment] ｅｎｄ"
    );
    assert_eq!(kinds, [RedactionKind::SecretAssignment]);

    let (out, kinds) = redact(&format!("ＡＢＣ {} a–b\u{200b}c", splice(&token, 9, ZWSP)));
    assert_eq!(out, "ＡＢＣ [redacted: api-token] a–b\u{200b}c");
    assert_eq!(kinds, [RedactionKind::ApiToken]);
}

#[test]
fn two_evaded_secrets_on_one_line_are_both_redacted_in_order() {
    let (token, body) = ghp_token();
    let ssn = ssn_text();
    let (out, kinds) = redact(&format!(
        "{} then SSN {}",
        splice(&token, 7, ZWSP),
        ssn.replace('-', "\u{2013}")
    ));
    assert_eq!(out, "[redacted: api-token] then SSN [redacted: ssn]");
    assert_eq!(kinds, [RedactionKind::ApiToken, RedactionKind::Ssn]);
    assert!(!out.contains(&body[..12]));
}

// ───────────────────────────── curl credentials ──────────────────────────────

#[test]
fn curl_credentials_are_redacted_whatever_the_flag_spelling() {
    let pw = gen(580, MIXED, 12);
    let a = gen(581, MIXED, 8);
    let b = gen(582, MIXED, 8);
    let spaced = format!("{a} {b}");
    let url = " https://example.com/x";
    let cases = [
        // Existing behaviour stays.
        case(
            "plain -u",
            &format!("curl -u admin:{pw}{url}"),
            &[&pw],
            &["curl -u admin:", url],
        ),
        case(
            "--user with a space",
            &format!("curl --user ops:{pw}{url}"),
            &[&pw],
            &["curl --user ops:", url],
        ),
        case(
            "--user with an equals sign",
            &format!("curl --user=ops:{pw}{url}"),
            &[&pw],
            &["curl --user=ops:", url],
        ),
        case(
            "--proxy-user",
            &format!("curl --proxy-user ops:{pw}{url}"),
            &[&pw],
            &["curl --proxy-user ops:", url],
        ),
        // Flags combined in front of the u.
        case(
            "-su",
            &format!("curl -su admin:{pw}{url}"),
            &[&pw],
            &["curl -su admin:", url],
        ),
        case(
            "-sSu",
            &format!("curl -sSu admin:{pw}{url}"),
            &[&pw],
            &["curl -sSu admin:", url],
        ),
        case(
            "-fsSLu",
            &format!("curl -fsSLu admin:{pw}{url}"),
            &[&pw],
            &["curl -fsSLu admin:", url],
        ),
        case(
            "-su after another flag",
            &format!("curl -k -su admin:{pw}{url}"),
            &[&pw],
            &["curl -k -su admin:", url],
        ),
        case(
            "-su with the credentials after other options",
            &format!("curl -X POST -sSu admin:{pw} -d x=1{url}"),
            &[&pw],
            &["curl -X POST -sSu admin:", " -d x=1", url],
        ),
        // Credentials attached to the flag.
        case(
            "attached -uadmin:pw",
            &format!("curl -uadmin:{pw}{url}"),
            &[&pw],
            &["curl -uadmin:", url],
        ),
        case(
            "attached after combined flags",
            &format!("curl -suadmin:{pw}{url}"),
            &[&pw],
            &["curl -suadmin:", url],
        ),
        // Quoted values containing a space.
        case(
            "single-quoted value with a space",
            &format!("curl -u 'admin:{spaced}'{url}"),
            &[&a, &b, &spaced],
            &["curl -u ", url],
        ),
        case(
            "double-quoted value with a space",
            &format!("curl -u \"admin:{spaced}\"{url}"),
            &[&a, &b, &spaced],
            &["curl -u ", url],
        ),
        case(
            "combined flags and a quoted value with a space",
            &format!("curl -su 'admin:{spaced}'{url}"),
            &[&a, &b, &spaced],
            &["curl -su ", url],
        ),
        case(
            "--user with a quoted value with a space",
            &format!("curl --user 'ops:{spaced}'{url}"),
            &[&a, &b, &spaced],
            &["curl --user ", url],
        ),
        case(
            "--proxy-user with a quoted value with a space",
            &format!("curl --proxy-user 'ops:{spaced}'{url}"),
            &[&a, &b, &spaced],
            &["curl --proxy-user ", url],
        ),
        case(
            "quoted value, a secret-looking word after the closing quote survives",
            &format!("curl -u 'admin:{spaced}' --max-time 5{url}"),
            &[&a, &b],
            &["curl -u ", " --max-time 5", url],
        ),
        // An unterminated quote swallows the rest of the line.
        case(
            "unterminated single quote",
            &format!("curl -u 'admin:{spaced}{url}"),
            &[&a, &b],
            &["curl -u "],
        ),
        case(
            "unterminated double quote",
            &format!("curl -su \"admin:{spaced}{url}"),
            &[&a, &b],
            &["curl -su "],
        ),
        // -U is the proxy user.
        case(
            "-U proxy user",
            &format!("curl -U proxy:{pw}{url}"),
            &[&pw],
            &["curl -U proxy:", url],
        ),
        case(
            "-sU proxy user",
            &format!("curl -sU proxy:{pw}{url}"),
            &[&pw],
            &["curl -sU proxy:", url],
        ),
    ];
    assert_all_redacted(&cases);
}

#[test]
fn a_curl_quoted_credential_is_redacted_as_one_secret_and_the_url_after_it_survives() {
    let a = gen(590, MIXED, 8);
    let b = gen(591, MIXED, 8);
    let (out, kinds) = redact(&format!("curl -u 'admin:{a} {b}' https://example.com/x"));
    assert!(out.ends_with(" https://example.com/x"), "{out:?}");
    assert_eq!(kinds, [RedactionKind::SecretAssignment], "{out:?}");
    assert!(!out.contains(&a) && !out.contains(&b), "{out:?}");
}

#[test]
fn curl_without_a_credential_is_left_alone() {
    assert_all_untouched(&[
        "curl --upload-file x.txt https://h",
        "curl -sS https://example.com",
        "curl -o out -L https://h",
        "curl -u admin https://example.com/x",
        "curl -su admin https://example.com/x",
        "curl -fsSL https://example.com/install.sh | sh",
        "curl -sSL -o out.tar.gz https://example.com/a/b.tar.gz",
        "curl -X POST -d x=1 https://example.com/u",
    ]);
}

// ───────────────────────────── corpus: normalised variants ───────────────────
//
// The guard flags text after normalising it, so a secret the guard would flag
// must not slip past the Redactor because it was dressed up in hidden or
// look-alike characters. Variants are derived at runtime from the guard's own
// positives; for each variant the guard still flags (same class), the
// Redactor must change the line.

/// A family of perturbations, for the "every family bites" check.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Debug)]
enum Family {
    ZwspInWord,
    SoftHyphenInWord,
    BomInWord,
    ZwspInDigits,
    FullwidthDigits,
    FullwidthLettersInWord,
    FullwidthEverything,
    EnDash,
    EmDash,
    MinusSign,
    UnicodeHyphen,
}

fn after_first_char(word: &str, hidden: char) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => format!("{first}{hidden}{}", chars.as_str()),
        None => String::new(),
    }
}

/// Replace one space-separated word of `line`.
fn with_word(line: &str, index: usize, f: impl Fn(&str) -> String) -> String {
    line.split(' ')
        .enumerate()
        .map(|(i, w)| if i == index { f(w) } else { w.to_string() })
        .collect::<Vec<_>>()
        .join(" ")
}

fn wide_letters(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_alphabetic() {
                char::from_u32(c as u32 + 0xfee0).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

fn wide_digits(text: &str) -> String {
    text.chars()
        .map(|c| {
            if c.is_ascii_digit() {
                char::from_u32(c as u32 + 0xfee0).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

/// `line` with a hidden character after the first digit of every digit run of
/// two or more digits, one variant per run.
fn digit_run_variants(line: &str, hidden: char) -> Vec<String> {
    let chars: Vec<char> = line.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let start = i;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
            if i - start >= 2 {
                let mut v: String = chars[..=start].iter().collect();
                v.push(hidden);
                v.extend(&chars[start + 1..]);
                out.push(v);
            }
        } else {
            i += 1;
        }
    }
    out
}

fn variants_of(line: &str) -> Vec<(Family, String)> {
    let mut out = Vec::new();
    let words = line.split(' ').count();
    for index in 0..words {
        for (family, hidden) in [
            (Family::ZwspInWord, ZWSP),
            (Family::SoftHyphenInWord, SOFT_HYPHEN),
            (Family::BomInWord, BOM),
        ] {
            out.push((
                family,
                with_word(line, index, |w| after_first_char(w, hidden)),
            ));
        }
        out.push((
            Family::FullwidthLettersInWord,
            with_word(line, index, wide_letters),
        ));
    }
    for v in digit_run_variants(line, ZWSP) {
        out.push((Family::ZwspInDigits, v));
    }
    out.push((Family::FullwidthDigits, wide_digits(line)));
    out.push((
        Family::FullwidthEverything,
        wide_letters(&wide_digits(line)),
    ));
    out.push((Family::EnDash, line.replace('-', "\u{2013}")));
    out.push((Family::EmDash, line.replace('-', "\u{2014}")));
    out.push((Family::MinusSign, line.replace('-', "\u{2212}")));
    out.push((Family::UnicodeHyphen, line.replace('-', "\u{2010}")));
    out
}

#[test]
fn every_normalised_variant_of_a_guard_positive_that_the_guard_still_flags_is_changed_by_the_redactor(
) {
    let config = GuardConfig::default();
    let mut generated = 0usize;
    let mut flagged = 0usize;
    let mut per_family: std::collections::BTreeMap<Family, usize> = Default::default();
    let mut not_pure_evasions = Vec::new();
    let mut missed = Vec::new();

    for (class, text) in guard_positives() {
        let wanted = match class.as_str() {
            "secret" => Class::Secret,
            "ssn" => Class::Ssn,
            "dob" => Class::Dob,
            _ => continue,
        };
        for (family, variant) in variants_of(&text) {
            if variant == text {
                continue;
            }
            generated += 1;
            // A variant is only an evasion if a reader sees the same text.
            if fold(&variant) != fold(&text) {
                not_pure_evasions.push(format!("{family:?}: {variant:?}"));
            }
            if !scan(&variant, &config).iter().any(|f| f.class == wanted) {
                continue;
            }
            flagged += 1;
            *per_family.entry(family).or_default() += 1;
            let (out, kinds) = Redactor::new().redact(&variant);
            if kinds.is_empty() || out == variant {
                missed.push(format!("[{class}] {family:?}: {variant:?}"));
            }
        }
    }

    assert!(
        not_pure_evasions.is_empty(),
        "the variant generator changed more than hiding or look-alike characters:\n{}",
        not_pure_evasions.join("\n")
    );
    assert!(
        generated >= 2000,
        "only {generated} variants were generated; the corpus loader or the generator is broken"
    );
    // The test must bite: most variants stay flagged by the guard, and every
    // family of perturbation keeps a healthy share of them.
    assert!(
        flagged >= generated / 3,
        "the guard flags only {flagged} of {generated} variants, so the test checks too little"
    );
    for family in [
        Family::ZwspInWord,
        Family::SoftHyphenInWord,
        Family::BomInWord,
        Family::ZwspInDigits,
        Family::FullwidthDigits,
        Family::FullwidthLettersInWord,
        Family::FullwidthEverything,
        Family::EnDash,
        Family::EmDash,
        Family::MinusSign,
        Family::UnicodeHyphen,
    ] {
        let n = per_family.get(&family).copied().unwrap_or(0);
        assert!(
            n >= 20,
            "only {n} guard-flagged variants for {family:?} ({per_family:?})"
        );
    }
    assert!(
        missed.is_empty(),
        "the redactor left {} of {flagged} guard-flagged variants unchanged:\n{}",
        missed.len(),
        missed
            .iter()
            .take(60)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}

// ───────────────────────────── order and overlap ─────────────────────────────

fn ghp_token() -> (String, String) {
    let body = gen(400, MIXED, 36);
    (prefixed(&["gh", "p_"], &body), body)
}

#[test]
fn a_token_named_assignment_reports_an_api_token_and_keeps_the_name() {
    let (token, body) = ghp_token();
    let (out, kinds) = redact(&format!("GITHUB_TOKEN={token}"));
    assert_eq!(out, "GITHUB_TOKEN=[redacted: api-token]");
    assert_eq!(kinds, [RedactionKind::ApiToken]);
    assert!(!out.contains(&body));
}

#[test]
fn a_token_inside_quotes_leaves_the_quotes_and_a_token_marker() {
    let (token, body) = ghp_token();
    let (out, kinds) = redact(&format!("PASSWORD=\"{token}\""));
    assert!(
        out.starts_with("PASSWORD=\"[redacted: ") && out.ends_with("]\""),
        "quotes not kept around the marker: {out:?}"
    );
    assert!(!out.contains(&body) && !out.contains("ghp_"), "{out:?}");
    assert!(!kinds.is_empty());
}

#[test]
fn an_assignment_value_that_partly_overlaps_a_token_does_not_leave_its_head_readable() {
    let (token, body) = ghp_token();
    let (out, kinds) = redact(&format!("PASSWORD=x:{token}"));
    let left = strip_markers(&out);
    assert!(!kinds.is_empty());
    assert!(
        !left.contains("x:"),
        "the head of the value is readable: {out:?}"
    );
    assert!(!out.contains(&body) && !out.contains("ghp_"), "{out:?}");
    assert!(left.starts_with("PASSWORD="), "{out:?}");
}

#[test]
fn a_secret_assignment_wrapping_an_aws_key_leaves_neither_part() {
    let id = format!("AKIA{}", gen(410, UPPER_DIGITS, 16));
    let (out, kinds) = redact(&format!("DB_PASSWORD=pre-{id}-post"));
    let left = strip_markers(&out);
    assert!(!kinds.is_empty());
    assert!(!left.contains(&id[4..]), "{out:?}");
    assert!(!left.contains("pre-") && !left.contains("-post"), "{out:?}");
}

// ───────────────────────────── review round: blanks, markers, flags ──────────

#[test]
fn a_blank_that_is_not_a_plain_space_still_separates_a_value() {
    let value = gen(520, UPPER_DIGITS, 24);
    for blank in [
        '\u{1680}', '\u{2028}', '\u{000b}', '\u{000c}', '\u{a0}', '\u{3000}',
    ] {
        let (out, kinds) = redact(&format!("sent Bearer{blank}{value} ok"));
        assert!(
            !out.contains(&value[..12]),
            "U+{:04X}: {out:?}",
            blank as u32
        );
        assert!(!kinds.is_empty());
        let key = prefixed(&["-----BEGIN", &blank.to_string(), "PRIVATE KEY-----"], "");
        let (out, _) = redact(&format!("{key}\n{value}\n"));
        assert!(
            !out.contains(&value[..12]),
            "key, U+{:04X}: {out:?}",
            blank as u32
        );
    }
}

#[test]
fn curl_flag_clusters_with_p_and_b_still_find_the_user_flag() {
    let pw = gen(521, UPPER_DIGITS, 16);
    for flags in ["-pu", "-Bu", "-sBpu"] {
        let (out, kinds) = redact(&format!("curl {flags} admin:{pw} https://h/x"));
        assert!(!out.contains(&pw), "{flags}: {out:?}");
        assert_eq!(kinds, [RedactionKind::SecretAssignment], "{flags}");
        assert!(out.ends_with(" https://h/x"), "{out:?}");
    }
}

#[test]
fn a_flood_of_private_key_markers_is_redacted_in_linear_time() {
    let block = "-----BEGIN PRIVATE KEY----- -----END PRIVATE KEY----- ";
    let started = std::time::Instant::now();
    for text in [block.repeat(4000), format!("\u{e9}{}", block.repeat(4000))] {
        let (out, kinds) = redact(&text);
        assert!(
            !out.contains("PRIVATE KEY-----"),
            "a marker was left readable"
        );
        assert!(kinds.len() >= 4000);
    }
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "took {:?}",
        started.elapsed()
    );
}

// ───────────────────────────── hidden separators and curl quoting ────────────
//
// The same shapes `terminal_text_delivery.rs` pushes through the assembler and
// `deliver` are run here straight through `Redactor::redact`: the delivery path
// must be at least as strong as the raw one, and the raw one must hold on its
// own. See `tests/support/redaction_shapes.rs` for the shapes.

fn shape_failures(shapes: &[shapes::Shape]) -> Vec<String> {
    shapes
        .iter()
        .filter_map(|s| {
            let (out, kinds) = redact(&s.line);
            shapes::verdict(s, &out, kinds.len())
                .map(|why| format!("[{}] input {:?}: {why}", s.name, s.line))
        })
        .collect()
}

fn assert_shapes_redacted(shapes: &[shapes::Shape]) {
    let failures = shape_failures(shapes);
    assert!(
        failures.is_empty(),
        "{} of {} shapes leaked:\n{}",
        failures.len(),
        shapes.len(),
        failures.join("\n")
    );
}

#[test]
fn a_hidden_character_standing_in_for_a_blank_never_hides_a_credential() {
    let all: Vec<shapes::Shape> = shapes::separators()
        .iter()
        .flat_map(|(label, f)| shapes::filler_as_separator_shapes(label, f))
        .collect();
    assert!(all.len() >= 200, "only {} shapes", all.len());
    assert_shapes_redacted(&all);
}

#[test]
fn curl_credentials_are_redacted_in_every_quoting_the_shell_allows() {
    let all = shapes::curl_quote_shapes();
    assert!(all.len() >= 15);
    assert_shapes_redacted(&all);
}

#[test]
fn curl_credentials_in_every_quoting_are_redacted_behind_a_hidden_separator_too() {
    let all: Vec<shapes::Shape> = shapes::separators()
        .iter()
        .flat_map(|(label, f)| {
            shapes::curl_quote_shapes()
                .iter()
                .map(|s| shapes::with_filler_before_the_flag(s, label, f))
                .collect::<Vec<_>>()
        })
        .collect();
    assert_shapes_redacted(&all);
}

#[test]
fn well_formed_curl_quoting_redacts_the_password_and_keeps_the_url_after_it() {
    let pw = ["Hun", "ter2", "Xyz9"].concat();
    for (line, kept) in [
        (
            format!("curl -u \"admin\":{pw} https://h/x"),
            "curl -u \"admin\":",
        ),
        (
            format!("curl -u 'admin':{pw} https://h/x"),
            "curl -u 'admin':",
        ),
        (
            format!("curl -u \"admin\":\"{pw}\" https://h/x"),
            "curl -u \"admin\":",
        ),
        (format!("curl -u 'admin:{pw}' https://h/x"), "curl -u "),
    ] {
        let (out, kinds) = redact(&line);
        assert!(out.starts_with(kept), "{line:?} -> {out:?}");
        assert!(out.ends_with(" https://h/x"), "{line:?} -> {out:?}");
        assert!(!out.contains(&pw[3..]), "{line:?} -> {out:?}");
        assert_eq!(kinds.len(), 1, "{line:?} -> {out:?}");
    }
}

#[test]
fn curl_without_a_password_is_left_alone_even_with_a_hidden_separator() {
    let mut lines: Vec<String> = shapes::curl_without_password_lines()
        .iter()
        .map(|l| l.to_string())
        .collect();
    for (_, f) in shapes::separators() {
        lines.extend(shapes::ordinary_filler_lines(&f));
    }
    let failures: Vec<String> = lines
        .iter()
        .filter_map(|line| {
            let (out, kinds) = redact(line);
            (out != *line || !kinds.is_empty())
                .then(|| format!("input {line:?} -> {out:?} ({kinds:?})"))
        })
        .collect();
    assert!(
        failures.is_empty(),
        "ordinary text was altered:\n{}",
        failures.join("\n")
    );
}

// ───────────────────── two filler roles on one line ──────────────────────────
//
// A hidden character can stand for a blank AND another can sit inside the
// secret on the same line (`curl<ZWSP>-u admin:QWKZ<ZWSP>XBNM`). Reading every
// run as a space misses the secret's tail; reading none as a space misses the
// flag. Both roles together must still redact the whole secret.

#[test]
fn a_hidden_separator_and_a_hidden_character_inside_the_secret_on_one_line_are_both_handled() {
    let all: Vec<shapes::Shape> = shapes::separators()
        .iter()
        .flat_map(|(_, f)| shapes::two_filler_role_examples(f))
        .collect();
    assert!(all.len() >= 50, "only {} shapes", all.len());
    assert_shapes_redacted(&all);
}

#[test]
fn every_credential_shape_survives_a_separator_filler_plus_a_different_filler_inside_the_secret() {
    // Every separator x every in-secret filler x every slot x every place in
    // the secret, for each credential template; a deterministic sample of the
    // whole product so the run stays short.
    let mut all = Vec::new();
    for (sep_label, sep) in shapes::separators() {
        for (in_label, inner) in shapes::secret_fillers() {
            all.extend(shapes::separator_and_secret_filler_shapes(
                &sep_label, &sep, &in_label, &inner,
            ));
        }
    }
    let total = all.len();
    let sampled = shapes::sample(all, 6);
    assert!(total >= 10_000, "only {total} shapes in the product");
    assert!(sampled.len() >= 1_000, "only {} sampled", sampled.len());
    assert_shapes_redacted(&sampled);
}

#[test]
fn a_separator_filler_plus_an_in_secret_filler_sweep_covers_the_same_filler_in_both_roles() {
    // The pairs on the diagonal (the same hidden character in both roles) are
    // the likeliest to be mistaken for one run: all of them, no sampling.
    let mut all = Vec::new();
    for (label, f) in shapes::secret_fillers() {
        all.extend(shapes::separator_and_secret_filler_shapes(
            &label, &f, &label, &f,
        ));
    }
    assert!(all.len() >= 1_000, "only {} shapes", all.len());
    assert_shapes_redacted(&all);
}

#[test]
fn ordinary_lines_with_a_hidden_separator_and_a_hidden_character_inside_a_word_come_back_untouched()
{
    let mut failures = Vec::new();
    for (_, sep) in shapes::separators() {
        for (_, inner) in shapes::secret_fillers() {
            for line in shapes::ordinary_two_role_filler_lines(&sep, &inner) {
                let (out, kinds) = redact(&line);
                if out != line || !kinds.is_empty() {
                    failures.push(format!("input {line:?} -> {out:?} ({kinds:?})"));
                }
            }
        }
    }
    assert!(
        failures.is_empty(),
        "ordinary text was altered:\n{}",
        failures.join("\n")
    );
}

#[test]
fn a_credential_past_many_hidden_runs_on_its_line_is_redacted_whole() {
    let all: Vec<shapes::Shape> = shapes::secret_fillers()
        .iter()
        .flat_map(|(_, f)| shapes::credential_after_many_hidden_runs(f))
        .collect();
    assert_shapes_redacted(&all);
}

#[test]
fn a_hidden_separator_and_a_hidden_secret_character_both_past_many_hidden_runs_are_redacted_whole()
{
    let all: Vec<shapes::Shape> = shapes::secret_fillers()
        .iter()
        .flat_map(|(_, f)| shapes::separator_after_many_hidden_runs(f))
        .collect();
    assert_shapes_redacted(&all);
}

// ───────────────────── curl: escaped blanks in a password ────────────────────

#[test]
fn a_backslash_escaped_blank_in_a_bare_curl_password_does_not_end_the_password() {
    let all = shapes::curl_escaped_blank_shapes();
    assert!(all.len() >= 10);
    assert_shapes_redacted(&all);
}

#[test]
fn a_curl_password_ending_in_an_even_run_of_backslashes_ends_there_and_the_url_stays_readable() {
    for s in shapes::curl_even_backslash_shapes() {
        let (out, kinds) = redact(&s.line);
        assert_eq!(
            shapes::verdict(&s, &out, kinds.len()),
            None,
            "[{}] {:?}",
            s.name,
            s.line
        );
        assert!(
            out.ends_with(shapes::KEPT_AFTER_EVEN_BACKSLASHES),
            "[{}] the text after the password was swallowed: {:?} -> {out:?}",
            s.name,
            s.line
        );
    }
}

// ───────────────────── curl: metacharacters inside quotes ────────────────────

#[test]
fn a_quoted_or_escaped_ampersand_semicolon_or_pipe_before_u_does_not_hide_the_curl_credential() {
    let all = shapes::curl_metacharacter_shapes();
    assert!(all.len() >= 12);
    assert_shapes_redacted(&all);
}

#[test]
fn a_quoted_metacharacter_before_the_flag_keeps_the_url_after_the_credential_readable() {
    let pw = ["Hun", "ter2", "Xyz9"].concat();
    for line in [
        format!("curl 'https://h/?a=1&b=2' -u admin:{pw} https://h/x"),
        format!("curl -H 'X: a;b' -u admin:{pw} https://h/x"),
        format!("curl -H \"X: a|b\" --user admin:{pw} https://h/x"),
    ] {
        let (out, kinds) = redact(&line);
        assert!(out.ends_with(" https://h/x"), "{line:?} -> {out:?}");
        assert!(!out.contains(&pw[3..]), "{line:?} -> {out:?}");
        assert_eq!(kinds.len(), 1, "{line:?} -> {out:?}");
    }
}

#[test]
fn after_a_real_command_break_another_commands_u_flag_is_not_curls() {
    for line in shapes::after_a_real_break_lines() {
        let (out, kinds) = redact(&line);
        assert_eq!(out, line);
        assert!(kinds.is_empty(), "{line:?} reported {kinds:?}");
    }
}

// ───────────────────── pathological input stays fast ─────────────────────────

/// About a megabyte of `unit` repeated.
fn about_a_megabyte(unit: &str) -> String {
    unit.repeat((1 << 20) / unit.len())
}

/// How the "stays fast" guards decide.
///
/// A wall-clock bound on a megabyte flaked on loaded runners and laptops (the
/// same shape took 0.2 s on an idle machine and over a second on a busy one),
/// and what these tests exist to catch is quadratic growth, not a slow machine.
/// So each guard times the text and four times the text, in CPU time (wall time
/// charges a test for its neighbours' work), in the same process a moment apart,
/// and asserts that the larger costs at most `MAX_GROWTH` times as much as the
/// smaller: linear is 4x, quadratic is 16x, so the limit sits well clear of both.
/// Each size is timed several times and the fastest run counts, so a load spike
/// that hits one run does not decide the outcome. `SMALL_FLOOR` stops a tiny,
/// noisy measurement from making the limit meaninglessly tight, and
/// `HANG_CEILING` is the one absolute bound: far above anything linear, far below
/// a quadratic scan of a megabyte (which took tens of seconds).
///
/// Both sizes are at least a megabyte on purpose. The redactor reads a group of
/// rows through several views only while the group fits a budget and redacts the
/// rest whole, so the cost jumps where the budget ends. Comparing sizes on
/// opposite sides of it would measure that step, not the growth.
const MAX_GROWTH: u32 = 9;
const SMALL_FLOOR: std::time::Duration = std::time::Duration::from_millis(50);
const HANG_CEILING: std::time::Duration = std::time::Duration::from_secs(10);

/// Held while a text is timed: the timed tests of this file never overlap each
/// other. (Other tests of the file can still run beside them, which is why the
/// decision is a ratio taken from the fastest of several runs, not a bound.)
static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// CPU time this thread has used. Wall time on a busy machine charges a test
/// for its neighbours' work; this does not, which is what makes a ratio of two
/// timings taken a moment apart stable under load.
fn thread_cpu_time() -> std::time::Duration {
    let mut now = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `now` is a valid, writable timespec for the whole call.
    let status = unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut now) };
    assert_eq!(status, 0, "the thread CPU clock is unavailable");
    std::time::Duration::new(now.tv_sec as u64, now.tv_nsec as u32)
}

/// The fewest CPU seconds of `runs` redactions of `text` (it runs on this thread).
fn fastest_of(runs: usize, text: &str) -> std::time::Duration {
    (0..runs)
        .map(|_| {
            let started = thread_cpu_time();
            let _ = Redactor::new().redact(text);
            thread_cpu_time() - started
        })
        .min()
        .expect("at least one run")
}

fn assert_fast(name: &str, text: &str) {
    assert_scaling(name, text, &text.repeat(4));
}

/// `small_text` and `text` are the same shape at one size and about four times it.
fn assert_scaling(name: &str, small_text: &str, text: &str) {
    let _alone = ONE_AT_A_TIME
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let small = fastest_of(3, small_text);
    let big = fastest_of(2, text);
    let limit = small.max(SMALL_FLOOR) * MAX_GROWTH;
    eprintln!(
        "{name}: {} bytes in {big:?}, {} bytes in {small:?} (limit {limit:?})",
        text.len(),
        small_text.len()
    );
    assert!(
        big < HANG_CEILING,
        "{name}: {} bytes took {big:?}",
        text.len()
    );
    assert!(
        big <= limit,
        "{name}: {} bytes took {big:?} but {} bytes took {small:?}: more than {MAX_GROWTH}x for 4x the text is super-linear",
        text.len(),
        small_text.len()
    );
}

#[test]
fn a_megabyte_of_ordinary_text_is_redacted_in_under_a_second() {
    // The yardstick for the pathological shapes below: the same size of text
    // with nothing to hide (the timings are printed with `--nocapture`).
    assert_fast(
        "ordinary text",
        &about_a_megabyte("ordinary output with nothing to hide "),
    );
}

#[test]
fn a_megabyte_of_curl_commands_cut_by_semicolons_is_redacted_in_under_a_second() {
    assert_fast("curl;", &about_a_megabyte("curl;"));
}

#[test]
fn a_megabyte_of_repeated_u_flags_without_a_password_is_redacted_in_under_a_second() {
    assert_fast("curl -u a -u a ", &about_a_megabyte("curl -u a -u a "));
    assert_fast("curl -u a ", &about_a_megabyte("curl -u a "));
}

#[test]
fn a_megabyte_of_unbalanced_quotes_after_curl_is_redacted_in_under_a_second() {
    assert_fast("curl '", &about_a_megabyte("curl 'curl 'curl '"));
    assert_fast("curl \"", &about_a_megabyte("curl \"curl \"curl \""));
}

#[test]
fn a_megabyte_of_curl_and_trailing_backslashes_is_redacted_in_under_a_second() {
    assert_fast("curl \\", &about_a_megabyte("curl \\"));
    assert_fast("curl \\<newline>", &about_a_megabyte("curl \\\n"));
    assert_fast("curl -u \\<newline>", &about_a_megabyte("curl -u \\\n"));
    assert_fast(
        "curl -u a:b\\<newline>",
        &about_a_megabyte("curl -u a:b\\\n"),
    );
}

#[test]
fn a_megabyte_of_curl_with_hidden_characters_is_redacted_in_under_a_second() {
    assert_fast("curl<ZWSP>;", &about_a_megabyte("curl\u{200b};"));
    assert_fast(
        "curl<ZWSP>-u a:b<ZWSP>",
        &about_a_megabyte("curl\u{200b}-u a:b\u{200b}"),
    );
}

#[test]
fn a_credential_at_the_end_of_a_megabyte_of_pathological_curl_text_is_still_redacted() {
    let pw = ["Hun", "ter2", "Xyz9"].concat();
    for unit in [
        "curl;",
        "curl -u a -u a ",
        "curl \\\n",
        "curl -u 'a:b'\\\n",
        "curl -u \"a:b\\\n",
    ] {
        // The same shape at two sizes, each ending in the same credential line,
        // so they differ only in length.
        let with_credential = |bytes: usize| {
            format!(
                "{}\ncurl -u admin:{pw} https://h/x",
                unit.repeat(bytes / unit.len())
            )
        };
        let text = with_credential(4 << 20);
        assert_scaling(unit, &with_credential(1 << 20), &text);
        let (out, kinds) = redact(&text);
        assert!(!out.contains(&pw[3..]), "{unit:?}: the password survived");
        assert!(!kinds.is_empty(), "{unit:?}: nothing redacted");
    }
}

// ───────────────────── curl over several rows ────────────────────────────────

#[test]
fn a_curl_flag_on_the_row_after_a_trailing_backslash_is_redacted_in_one_text() {
    let all = shapes::curl_continuation_shapes();
    assert!(all.len() >= 8);
    assert_shapes_redacted(&all);
    let all = shapes::curl_value_on_next_row_shapes();
    assert_shapes_redacted(&all);
}

/// Each row through one `Redactor` in its own call, as separate deliveries are.
/// `newline_after_rows` writes the row break at the end of each call but the
/// last.
fn redact_rows_in_turn(rows: &[&str], newline_after_rows: bool) -> (Vec<String>, usize) {
    let mut redactor = Redactor::new();
    let mut outs = Vec::new();
    let mut redactions = 0;
    for (i, row) in rows.iter().enumerate() {
        let text = if newline_after_rows && i + 1 < rows.len() {
            format!("{row}\n")
        } else {
            row.to_string()
        };
        let (out, kinds) = redactor.redact(&text);
        redactions += kinds.len();
        outs.push(out);
    }
    (outs, redactions)
}

#[test]
fn a_curl_flag_in_the_next_delivery_after_a_row_ending_in_a_backslash_is_redacted() {
    let mut failures = Vec::new();
    for s in shapes::curl_continuation_shapes() {
        let rows: Vec<&str> = s.line.split('\n').collect();
        for newline_after_rows in [false, true] {
            let (outs, redactions) = redact_rows_in_turn(&rows, newline_after_rows);
            if let Some(why) = shapes::verdict(&s, &outs.join("\n"), redactions) {
                failures.push(format!(
                    "[{}] rows {rows:?} (newline kept: {newline_after_rows}): {why}",
                    s.name
                ));
            }
        }
    }
    assert!(failures.is_empty(), "leaked:\n{}", failures.join("\n"));
}

#[test]
fn a_curl_flag_opening_the_next_delivery_is_redacted_and_the_url_after_it_stays_readable() {
    let pw = ["Hun", "ter2", "Xyz9"].concat();
    let mut redactor = Redactor::new();
    let (first, k1) = redactor.redact("curl -s https://h/x \\");
    let (second, k2) = redactor.redact(&format!("  -u admin:{pw} https://h/y"));
    assert!(first.contains("curl -s https://h/x"), "{first:?}");
    assert!(k1.is_empty(), "{first:?}");
    assert!(!second.contains(&pw[3..]), "{second:?}");
    assert!(second.ends_with(" https://h/y"), "{second:?}");
    assert_eq!(k2.len(), 1, "{second:?}");
}

#[test]
fn the_value_of_a_curl_flag_on_the_next_deliverys_first_row_is_redacted() {
    // `-u \` ends one delivery and the credential opens the next.
    let mut failures = Vec::new();
    for s in shapes::curl_value_on_next_row_shapes() {
        let rows: Vec<&str> = s.line.split('\n').collect();
        let (outs, redactions) = redact_rows_in_turn(&rows, false);
        if let Some(why) = shapes::verdict(&s, &outs.join("\n"), redactions) {
            failures.push(format!("[{}] rows {rows:?}: {why}", s.name));
        }
    }
    assert!(failures.is_empty(), "leaked:\n{}", failures.join("\n"));
}

#[test]
fn a_continuation_that_has_completed_leaves_later_text_alone() {
    let cases: [&[&str]; 4] = [
        &["curl \\", "-s https://h/x", "ls -u foo:bar"],
        &[
            "curl -s \\",
            "  -H 'X: 1' \\",
            "  https://h/x",
            "ls -u foo:bar",
        ],
        &["curl \\\n-s https://h/x", "ls -u foo:bar"],
        &["echo hi", "ls -u foo:bar"],
    ];
    for rows in cases {
        for newline_after_rows in [false, true] {
            let (outs, redactions) = redact_rows_in_turn(rows, newline_after_rows);
            let last = outs.last().unwrap();
            assert_eq!(last, "ls -u foo:bar", "rows {rows:?}");
            assert_eq!(redactions, 0, "rows {rows:?} -> {outs:?}");
        }
    }
}

#[test]
fn a_row_ending_in_a_backslash_that_is_not_curl_carries_nothing_to_the_next_delivery() {
    for first in ["echo hi \\", "ls -l \\", "echo hi \\\n"] {
        let mut redactor = Redactor::new();
        let (out, kinds) = redactor.redact(first);
        assert_eq!(out, first);
        assert!(kinds.is_empty());
        for next in ["ls -u foo:bar", "-u foo:bar", "sort -u a:b"] {
            let (out, kinds) = redactor.redact(next);
            assert_eq!(out, next, "after {first:?}");
            assert!(
                kinds.is_empty(),
                "after {first:?}: {next:?} reported {kinds:?}"
            );
        }
    }
}

#[test]
fn a_completed_continuation_still_redacts_its_own_credential_and_then_forgets_it() {
    let pw = ["Hun", "ter2", "Xyz9"].concat();
    let mut redactor = Redactor::new();
    let (first, _) = redactor.redact("curl -s \\");
    let (second, k2) = redactor.redact(&format!("-u admin:{pw} https://h/x"));
    let (third, k3) = redactor.redact("ls -u foo:bar");
    assert_eq!(first, "curl -s \\");
    assert!(!second.contains(&pw[3..]), "{second:?}");
    assert_eq!(k2.len(), 1);
    assert_eq!(third, "ls -u foo:bar");
    assert!(k3.is_empty(), "{third:?} reported {k3:?}");
}

// ───────────── review round 3: many runs, two readings across rows, quoting ──────

/// Each shape as one text, then row by row through one `Redactor` (as separate
/// deliveries are, with and without the row break kept at the end of a call).
fn assert_rows_redacted_every_way(all: &[shapes::Shape]) {
    assert_shapes_redacted(all);
    let mut failures = Vec::new();
    for s in all {
        let rows: Vec<&str> = s.line.split('\n').collect();
        for newline_after_rows in [false, true] {
            let (outs, redactions) = redact_rows_in_turn(&rows, newline_after_rows);
            if let Some(why) = shapes::verdict(s, &outs.join("\n"), redactions) {
                failures.push(format!(
                    "[{}] rows {rows:?} (newline kept: {newline_after_rows}): {why}",
                    s.name
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "leaked across deliveries:\n{}",
        failures.join("\n")
    );
}

#[test]
fn a_credential_among_more_than_eight_hidden_runs_is_redacted_whole_before_or_after_the_padding() {
    let all = shapes::credential_among_many_hidden_runs_shapes();
    assert!(all.len() >= 10, "only {} shapes", all.len());
    assert_shapes_redacted(&all);
}

#[test]
fn a_continued_curl_with_hidden_runs_on_both_rows_is_redacted_in_every_reading() {
    let all = shapes::continued_curl_with_hidden_runs_on_both_rows();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn a_dollar_quoted_string_with_an_escaped_quote_before_u_does_not_hide_the_curl_credential() {
    let all = shapes::dollar_quote_shapes();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn a_curl_password_continued_onto_the_next_row_is_redacted_whole_quoted_or_not() {
    let all = shapes::credential_continued_onto_the_next_row_shapes();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn several_continuations_in_a_row_before_the_curl_value_are_followed() {
    let all = shapes::repeated_continuations_before_the_value_shapes();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn an_unterminated_double_quoted_curl_password_continued_by_a_backslash_is_redacted_whole() {
    let all = shapes::unterminated_double_quote_continuation_shapes();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn a_curl_row_ending_in_the_clip_mark_continues_into_the_next_row() {
    let all = shapes::rows_ending_in_the_clip_mark_shapes();
    assert_rows_redacted_every_way(&all);
}

#[test]
fn a_flag_after_thousands_of_continued_rows_is_still_redacted_in_the_next_call() {
    let s = shapes::credential_after_a_long_continued_curl();
    for trailing_newline in [true, false] {
        let mut redactor = Redactor::new();
        let _ = redactor.redact(&shapes::long_continued_curl_text(trailing_newline));
        let (out, kinds) = redactor.redact(&s.line);
        assert_eq!(
            shapes::verdict(&s, &out, kinds.len()),
            None,
            "(trailing newline: {trailing_newline}) {:?}",
            s.line
        );
    }
}

/// `text` comes back as it is, nothing redacted, as one text and row by row.
fn assert_comes_back_untouched_every_way(name: &str, text: &str) {
    let (out, kinds) = redact(text);
    assert_eq!(out, text, "[{name}]");
    assert!(kinds.is_empty(), "[{name}] reported {kinds:?}");
    let rows: Vec<&str> = text.split('\n').collect();
    for newline_after_rows in [false, true] {
        let (outs, redactions) = redact_rows_in_turn(&rows, newline_after_rows);
        for (i, (row, out)) in rows.iter().zip(&outs).enumerate() {
            let expected = if newline_after_rows && i + 1 < rows.len() {
                format!("{row}\n")
            } else {
                row.to_string()
            };
            assert_eq!(
                out, &expected,
                "[{name}] row {i} (newline kept: {newline_after_rows})"
            );
        }
        assert_eq!(
            redactions, 0,
            "[{name}] (newline kept: {newline_after_rows})"
        );
    }
}

#[test]
fn text_after_curl_with_an_unmatched_apostrophe_and_other_commands_u_flags_comes_back_untouched() {
    for (name, text) in shapes::curl_lookalike_negative_texts() {
        assert_comes_back_untouched_every_way(name, &text);
    }
}

#[test]
fn an_unmatched_double_quote_after_curl_is_an_ordinary_character_and_later_commands_are_untouched()
{
    assert_comes_back_untouched_every_way(
        "curl with an unmatched double quote",
        &shapes::unmatched_quote_negative_text(),
    );
}

#[test]
fn a_megabyte_of_quoted_curl_credentials_with_a_trailing_backslash_is_redacted_in_under_a_second() {
    assert_fast(
        "curl -u 'a:b'\\<newline>",
        &about_a_megabyte("curl -u 'a:b'\\\n"),
    );
    assert_fast(
        "curl -u \"a:b\\<newline>",
        &about_a_megabyte("curl -u \"a:b\\\n"),
    );
}

// ───────────── review round 4: the combination budget is per row group ───────────
//
// A hostile program (or just a long log) can put hundreds of kilobytes of text
// in front of a credential in one call. The credential's hidden runs are read in
// every combination whatever else the call carries, and a group too big for
// that, or too many of them, fails closed.

/// The old budget stopped reading combinations once `text.len() << 1` passed
/// `1 << 20`; every text below is a clear margin above that.
const OLD_BUDGET: usize = 1 << 20;

fn assert_text_is_over_the_old_budget(text: &str) {
    assert!(
        (text.len() << 1) > OLD_BUDGET * 2,
        "only {} bytes: not clearly over the old budget",
        text.len()
    );
}

/// Fails with every one of `failures` (one per line) if there are any.
fn assert_no_failures(what: &str, failures: Vec<String>) {
    assert!(
        failures.is_empty(),
        "{what}: {} failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn credentials_with_several_hidden_runs_are_redacted_when_nothing_surrounds_them() {
    // The control for the tests below: the same rows with no padding.
    let all = shapes::credentials_with_several_hidden_runs();
    assert!(all.len() >= 20, "only {} shapes", all.len());
    assert_shapes_redacted(&all);
}

/// Every placement of the credential rows around padding of `kind`, as ONE call:
/// the headline repro alone, then all the credential rows at once.
fn assert_padded_text_redacted_in_one_call(kind: shapes::Padding) {
    let rows = shapes::padding_rows(kind, shapes::PADDING_BYTES);
    let credentials = shapes::credentials_with_several_hidden_runs();
    let mut failures = Vec::new();
    for place in shapes::Place::ALL {
        for group in [&credentials[..1], &credentials[..]] {
            let p = shapes::padded(group, kind, &rows, place);
            assert_text_is_over_the_old_budget(&p.shape.line);
            let (out, kinds) = redact(&p.shape.line);
            if let Some(why) = p.verdict(&out, kinds.len()) {
                failures.push(format!("[{}] {why}", p.shape.name));
            }
        }
    }
    assert_no_failures("one call", failures);
}

#[test]
fn a_credential_with_several_hidden_runs_is_redacted_before_and_after_a_megabyte_of_plain_lines() {
    assert_padded_text_redacted_in_one_call(shapes::Padding::Plain);
}

#[test]
fn a_credential_with_several_hidden_runs_is_redacted_before_and_after_a_megabyte_of_lines_with_hidden_characters(
) {
    assert_padded_text_redacted_in_one_call(shapes::Padding::Hidden);
}

#[test]
fn a_credential_with_several_hidden_runs_is_redacted_before_and_after_a_megabyte_of_emoji() {
    assert_padded_text_redacted_in_one_call(shapes::Padding::Emoji);
}

/// Each call's text: its rows, every one with its newline (lines are whole).
fn call_text(rows: &[String]) -> String {
    let mut text = rows.join("\n");
    text.push('\n');
    text
}

/// The rounds one after another through ONE `Redactor`, each a call. The outputs
/// are joined; the count is every redaction reported.
fn redact_in_calls(rounds: &[Vec<String>]) -> (String, usize) {
    let mut redactor = Redactor::new();
    let mut out = String::new();
    let mut redactions = 0;
    for round in rounds {
        let (text, kinds) = redactor.redact(&call_text(round));
        out.push_str(&text);
        redactions += kinds.len();
    }
    (out, redactions)
}

/// The text of `kind` padding cut into calls of `round_bytes`, with the
/// credential rows in a call of their own (`apart`) or riding along.
fn assert_padded_calls_redacted(kind: shapes::Padding, round_bytes: usize, apart: bool) {
    let rows = shapes::padding_rows(kind, shapes::PADDING_BYTES);
    let credentials = shapes::credentials_with_several_hidden_runs();
    let mut failures = Vec::new();
    for place in shapes::Place::ALL {
        let p = shapes::padded(&credentials, kind, &rows, place);
        let rounds = p.rounds(round_bytes, apart);
        assert!(rounds.len() >= 2, "only {} calls", rounds.len());
        if !apart {
            for round in &rounds {
                assert!(call_text(round).len() > 600_000, "a call is too small");
            }
        }
        let (out, redactions) = redact_in_calls(&rounds);
        if let Some(why) = p.verdict(&out, redactions) {
            failures.push(format!(
                "[{}] {} calls (credentials apart: {apart}): {why}",
                p.shape.name,
                rounds.len()
            ));
        }
    }
    assert_no_failures("split feeds", failures);
}

#[test]
fn a_credential_in_a_later_call_than_the_padding_is_redacted_whatever_the_padding_is_made_of() {
    // Calls of about 200 KB, the credential rows in a call of their own.
    for kind in [
        shapes::Padding::Plain,
        shapes::Padding::Hidden,
        shapes::Padding::Emoji,
    ] {
        assert_padded_calls_redacted(kind, 200_000, true);
    }
}

#[test]
fn a_credential_in_the_same_call_as_more_than_half_a_megabyte_of_padding_is_redacted_when_the_padding_came_in_several_calls(
) {
    // Calls of 640 KB, each over the old threshold on its own; the credential
    // rows ride along in the first and/or last one.
    for kind in [
        shapes::Padding::Plain,
        shapes::Padding::Hidden,
        shapes::Padding::Emoji,
    ] {
        assert_padded_calls_redacted(kind, 640_000, false);
    }
}

/// Row one of a continued command, row two, and how they are put into calls:
/// `before` is padding in front of row one, `after` is padding behind row two.
fn assert_continued_command_redacted_around_padding(kind: shapes::Padding) {
    let rows = shapes::padding_rows(kind, shapes::PADDING_BYTES);
    let mut all = shapes::continued_curl_with_several_hidden_runs_shapes();
    all.extend(shapes::continued_curl_with_hidden_runs_on_both_rows());
    let mut failures = Vec::new();
    for s in &all {
        let (first, second) = s.line.split_once('\n').expect("two rows");
        let first = first.to_string();
        let second = second.to_string();
        let padding_then = |tail: &str| {
            let mut rows = rows.clone();
            rows.push(tail.to_string());
            rows
        };
        let then_padding = |head: &str| {
            let mut out = vec![head.to_string()];
            out.extend(rows.iter().cloned());
            out
        };
        let cases: Vec<(&str, Vec<Vec<String>>)> = vec![
            (
                "padding and row one, then row two",
                vec![padding_then(&first), vec![second.clone()]],
            ),
            (
                "row one, then row two and padding",
                vec![vec![first.clone()], then_padding(&second)],
            ),
            (
                "padding and row one, then row two and padding",
                vec![padding_then(&first), then_padding(&second)],
            ),
        ];
        for (what, rounds) in cases {
            let (out, redactions) = redact_in_calls(&rounds);
            if let Some(why) = shapes::verdict(s, &out, redactions) {
                failures.push(format!("[{}] {what}: {why}", s.name));
            }
        }
    }
    assert_no_failures("continued command", failures);
}

#[test]
fn a_continued_curl_across_two_calls_is_redacted_next_to_a_megabyte_of_plain_lines() {
    assert_continued_command_redacted_around_padding(shapes::Padding::Plain);
}

#[test]
fn a_continued_curl_across_two_calls_is_redacted_next_to_a_megabyte_of_lines_with_hidden_characters(
) {
    assert_continued_command_redacted_around_padding(shapes::Padding::Hidden);
}

// ───────────── too much to read in every combination: fail closed ────────────────

#[test]
fn a_credential_in_the_middle_of_one_line_over_a_megabyte_is_redacted() {
    let all = shapes::one_huge_line_with_a_credential_in_the_middle(shapes::PADDING_BYTES);
    let mut failures = Vec::new();
    for s in &all {
        assert_text_is_over_the_old_budget(&s.line);
        assert!(!s.line.contains('\n'), "[{}] is more than one row", s.name);
        let (out, kinds) = redact(&s.line);
        if let Some(why) = shapes::verdict(s, &out, kinds.len()) {
            failures.push(format!("[{}] {why}", s.name));
        }
    }
    assert_no_failures("one huge line", failures);
}

#[test]
fn a_flood_of_keyword_lines_with_hidden_runs_is_redacted_on_every_line_and_stays_fast() {
    let all = shapes::flood_of_keyword_lines((1 << 20) + 4096);
    let text = all
        .iter()
        .map(|s| s.line.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    assert_text_is_over_the_old_budget(&text);
    assert_fast(&format!("flood of {} keyword lines", all.len()), &text);
    let (out, kinds) = redact(&text);
    let out_lines: Vec<&str> = out.split('\n').collect();
    assert_eq!(out_lines.len(), all.len(), "the rows were merged or split");
    let failures: Vec<String> = all
        .iter()
        .zip(&out_lines)
        .filter_map(|(s, line)| {
            shapes::verdict(s, line, kinds.len()).map(|why| format!("[{}] {why}", s.name))
        })
        .take(10)
        .collect();
    assert_no_failures("flood of keyword lines", failures);
}

#[test]
fn a_megabyte_of_lines_with_hidden_runs_and_no_credential_keyword_comes_back_untouched() {
    let mut texts = vec![
        (
            "rows of hidden-character padding",
            shapes::padding_rows(shapes::Padding::Hidden, shapes::PADDING_BYTES).join("\n"),
        ),
        (
            "rows with many hidden runs each",
            shapes::benign_rows_with_hidden_runs(shapes::PADDING_BYTES).join("\n"),
        ),
        (
            "one huge line of hidden runs",
            shapes::benign_huge_line(shapes::PADDING_BYTES),
        ),
    ];
    texts.push((
        "hidden-character rows, emoji rows and plain rows together",
        [
            shapes::Padding::Hidden,
            shapes::Padding::Emoji,
            shapes::Padding::Plain,
        ]
        .into_iter()
        .flat_map(|kind| shapes::padding_rows(kind, shapes::PADDING_BYTES / 3))
        .collect::<Vec<_>>()
        .join("\n"),
    ));
    for (name, text) in &texts {
        assert_text_is_over_the_old_budget(text);
        let (out, kinds) = redact(text);
        assert!(
            out == *text,
            "[{name}] came back changed ({} bytes in, {} out)",
            text.len(),
            out.len()
        );
        assert!(kinds.is_empty(), "[{name}] reported {kinds:?}");
    }
}

#[test]
fn a_megabyte_of_password_assignments_with_a_hidden_character_is_redacted_in_under_a_second() {
    assert_fast(
        "password=<ZWSP>a ",
        &about_a_megabyte("password=\u{200b}a "),
    );
}

#[test]
fn a_megabyte_of_curl_u_lines_with_a_hidden_character_is_redacted_in_under_a_second() {
    assert_fast(
        "curl -u a:b<ZWSP><newline>",
        &about_a_megabyte("curl -u a:b\u{200b}\n"),
    );
}

// ───────────── review round 5: shapes the first version of the round 4 fix missed ─
//
// A review found that a first version of the fix leaked in each of these. They
// are kept as permanent regressions: rows of one curl command joined by an open
// quote, anchored token shapes in a line with no credential word, credential
// names only a hidden-run reading sees, and personal data behind thousands of
// rows with hidden runs. z is U+200B.

fn rows_of(s: &shapes::Shape) -> Vec<String> {
    s.line.split('\n').map(str::to_string).collect()
}

#[test]
fn a_curl_command_continued_by_an_open_quote_hides_nothing_with_hidden_runs_in_any_row_or_role() {
    let all = shapes::continued_curl_joined_by_an_open_quote_shapes();
    assert_eq!(all.len(), 6);
    for s in &all {
        // The repro's shape: hidden runs, an open quote closing on a later row,
        // no backslash anywhere.
        assert!(s.line.contains('\u{200b}'), "[{}] no hidden run", s.name);
        assert!(s.line.contains('\''), "[{}] no quote", s.name);
        assert!(!s.line.contains('\\'), "[{}] has a backslash", s.name);
        assert!(rows_of(s).len() >= 2, "[{}] is one row", s.name);
    }
    assert_shapes_redacted(&all);
}

/// Each open-quote command with `kind` padding (over the old budget) before it,
/// after it, and on both sides, as one call. (A command that an open quote
/// carries from one call to the next is a known gap, see the module docs of
/// `redact.rs`: only a trailing backslash is carried.)
fn assert_open_quote_curl_redacted_around_padding(kind: shapes::Padding) {
    let padding = shapes::padding_rows(kind, shapes::PADDING_BYTES);
    let placements = [
        ("command, then padding", false, true),
        ("padding, then command", true, false),
        ("padding on both sides of the command", true, true),
    ];
    let mut failures = Vec::new();
    for s in &shapes::continued_curl_joined_by_an_open_quote_shapes() {
        let command = rows_of(s);
        for (what, padding_before, padding_after) in placements {
            let label = format!("[{}] {what} ({})", s.name, kind.label());
            let mut all = Vec::new();
            if padding_before {
                all.extend(padding.iter().cloned());
            }
            all.extend(command.iter().cloned());
            if padding_after {
                all.extend(padding.iter().cloned());
            }
            let text = call_text(&all);
            assert_text_is_over_the_old_budget(&text);
            let (out, kinds) = redact(&text);
            if let Some(why) = shapes::verdict(s, &out, kinds.len()) {
                failures.push(format!("{label}: {why}"));
            }
        }
    }
    assert_no_failures("open-quote curl around padding", failures);
}

#[test]
fn a_curl_command_continued_by_an_open_quote_is_redacted_before_and_after_a_megabyte_of_plain_lines(
) {
    assert_open_quote_curl_redacted_around_padding(shapes::Padding::Plain);
}

#[test]
fn a_curl_command_continued_by_an_open_quote_is_redacted_before_and_after_a_megabyte_of_lines_with_hidden_runs(
) {
    assert_open_quote_curl_redacted_around_padding(shapes::Padding::Hidden);
}

#[test]
fn an_anchored_token_with_hidden_runs_before_and_inside_it_is_redacted_whole_without_a_credential_word(
) {
    let all = shapes::anchored_tokens_with_a_hidden_run_before_and_inside();
    assert_eq!(all.len(), 4);
    for s in &all {
        // No credential word on the line: only the token's own shape can find it.
        let reader = shapes::without_filler(&s.line).to_lowercase();
        for word in ["token", "key", "secret", "password", "auth", "bearer"] {
            assert!(!reader.contains(word), "[{}] has {word:?}", s.name);
        }
    }
    assert_rows_redacted_every_way(&all);
}

/// `group` (one row each) before, after and on both sides of `kind` padding,
/// as ONE call.
fn assert_group_redacted_around_padding(group: &[shapes::Shape], kind: shapes::Padding) {
    let rows = shapes::padding_rows(kind, shapes::PADDING_BYTES);
    let mut failures = Vec::new();
    for place in shapes::Place::ALL {
        let p = shapes::padded(group, kind, &rows, place);
        assert_text_is_over_the_old_budget(&p.shape.line);
        let (out, kinds) = redact(&p.shape.line);
        if let Some(why) = p.verdict(&out, kinds.len()) {
            failures.push(format!("[{}] {why}", p.shape.name));
        }
    }
    assert_no_failures("one call", failures);
}

#[test]
fn an_anchored_token_with_hidden_runs_is_redacted_before_and_after_a_megabyte_of_plain_lines() {
    assert_group_redacted_around_padding(
        &shapes::anchored_tokens_with_a_hidden_run_before_and_inside(),
        shapes::Padding::Plain,
    );
}

#[test]
fn an_anchored_token_with_hidden_runs_is_redacted_before_and_after_a_megabyte_of_lines_with_hidden_runs(
) {
    assert_group_redacted_around_padding(
        &shapes::anchored_tokens_with_a_hidden_run_before_and_inside(),
        shapes::Padding::Hidden,
    );
}

#[test]
fn a_credential_name_that_only_a_hidden_run_reading_sees_still_redacts_its_value() {
    // --auth, --dsn and --credential, each with a hidden run inside the name.
    let all = shapes::credential_names_split_by_a_hidden_run();
    assert_eq!(all.len(), 3);
    assert_rows_redacted_every_way(&all);
}

#[test]
fn other_credential_names_split_by_a_hidden_run_still_redact_their_values() {
    // Beyond the review's list: --password, API_KEY=, --token and --secret.
    let all = shapes::more_credential_names_split_by_a_hidden_run();
    assert_rows_redacted_every_way(&all);
}

/// Every one of `shapes` fails the test when its text (one call) leaks.
fn assert_texts_redacted(all: &[shapes::Shape]) {
    let mut failures = Vec::new();
    for s in all {
        for trailing_newline in [true, false] {
            let text = if trailing_newline {
                format!("{}\n", s.line)
            } else {
                s.line.clone()
            };
            let (out, kinds) = redact(&text);
            if let Some(why) = shapes::verdict(s, &out, kinds.len()) {
                failures.push(format!(
                    "[{}] (trailing newline: {trailing_newline}): {why}",
                    s.name
                ));
            }
        }
    }
    assert_no_failures("personal data behind many rows", failures);
}

#[test]
fn an_ssn_with_hidden_runs_is_redacted_behind_hundreds_or_thousands_of_rows_with_two_hidden_runs_each(
) {
    let all: Vec<shapes::Shape> = [400, 600, 3000, 8000]
        .into_iter()
        .map(shapes::ssn_behind_rows_with_two_hidden_runs)
        .collect();
    assert_texts_redacted(&all);
}

#[test]
fn a_labelled_birth_date_with_hidden_runs_is_redacted_behind_thousands_of_rows_with_two_hidden_runs_each(
) {
    let all: Vec<shapes::Shape> = [1500, 8000]
        .into_iter()
        .map(shapes::birth_date_behind_rows_with_two_hidden_runs)
        .collect();
    assert_texts_redacted(&all);
}

#[test]
fn an_ssn_with_hidden_runs_at_the_end_of_one_line_of_hundreds_of_thousands_of_hidden_runs_is_redacted(
) {
    let s = shapes::ssn_at_the_end_of_one_line_of_hidden_runs(70_000);
    assert!(s.line.len() > 500_000 && !s.line.contains('\n'));
    assert_texts_redacted(&[s]);
}

#[test]
fn lines_with_emoji_presentation_selectors_come_back_untouched_however_many_there_are() {
    for (name, lines) in shapes::benign_lines_that_must_not_be_redacted() {
        let text = format!("{}\n", lines.join("\n"));
        assert_comes_back_untouched_every_way(name, &text);
    }
}

#[test]
fn a_flood_of_twenty_thousand_dated_lines_with_hidden_runs_is_redacted_without_a_panic_in_under_a_second(
) {
    // Redacting some of these lines is allowed; panicking or being slow is not.
    let text = format!(
        "{}\n",
        shapes::dated_lines_with_two_hidden_runs(20_000).join("\n")
    );
    assert_fast("20000 dated lines with two hidden runs each", &text);
}
