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
