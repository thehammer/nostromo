//! T0g sensitive-text guard: behavioural tests, corpus gates, and binary contract.
//!
//! Layers, in order:
//!   1. Per-class tables: what each class must and must not flag.
//!   2. Corpus gates: zero misses on `positives.txt`, <= 1% false alarms on `benign.txt`.
//!   3. Range correctness (byte ranges on char boundaries, covering the item).
//!   4. No-echo: findings never carry or print the matched text.
//!   5. The `sensitive-text-scan` binary: `line_no<TAB>class` lines only.
//!   6. Linear behaviour, hostile input, and an ignored release-mode timing bench.
//!
//! Every value in the tests and fixtures is synthetic.
//!
//! Timing bench (not run by default):
//!   cargo test --release --test sensitive_text_corpus -- --ignored

use std::collections::{BTreeMap, HashSet};
use std::io::Write as _;
use std::process::{Command, ExitStatus, Stdio};
use std::time::Instant;

use nostromo::sensitive_text::{first_class, scan, Class, Finding, GuardConfig};

const POSITIVES_RAW: &str = include_str!("fixtures/sensitive_text/positives.txt");

/// `positives.txt` with the U+00A6 mask removed. Secret-shaped values are
/// stored masked so GitHub push protection does not mistake the invented
/// tokens for real ones.
static POSITIVES: std::sync::LazyLock<String> =
    std::sync::LazyLock::new(|| POSITIVES_RAW.replace('\u{a6}', ""));
const BENIGN: &str = include_str!("fixtures/sensitive_text/benign.txt");

const ALL_CLASSES: [Class; 7] = [
    Class::Ssn,
    Class::Card,
    Class::Dob,
    Class::Mrn,
    Class::Phone,
    Class::PersonalEmail,
    Class::Secret,
];

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn cfg() -> GuardConfig {
    GuardConfig::default()
}

fn findings(text: &str) -> Vec<Finding> {
    scan(text, &cfg())
}

fn classes_of(text: &str) -> Vec<Class> {
    findings(text).iter().map(|f| f.class).collect()
}

fn has_class(text: &str, class: Class) -> bool {
    findings(text).iter().any(|f| f.class == class)
}

/// Deterministic alphanumeric filler of exactly `n` chars (letters and digits, mixed case).
fn alnum(n: usize) -> String {
    const POOL: &str = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789";
    POOL.chars().cycle().take(n).collect()
}

/// Structural invariants every scan result must satisfy. Never prints the text.
fn assert_well_formed(text: &str, found: &[Finding]) {
    let mut prev_start = 0;
    for f in found {
        assert!(
            f.range.start <= f.range.end,
            "inverted range {:?} ({}) in text of {} bytes",
            f.range,
            f.class,
            text.len()
        );
        assert!(
            f.range.end <= text.len(),
            "range {:?} ({}) exceeds text of {} bytes",
            f.range,
            f.class,
            text.len()
        );
        assert!(
            text.is_char_boundary(f.range.start) && text.is_char_boundary(f.range.end),
            "range {:?} ({}) is not on char boundaries",
            f.range,
            f.class
        );
        assert!(
            f.range.start >= prev_start,
            "findings not sorted by start: {} after {}",
            f.range.start,
            prev_start
        );
        prev_start = f.range.start;
    }
}

fn assert_flags<S: AsRef<str>>(class: Class, cases: &[S]) {
    let missed: Vec<&str> = cases
        .iter()
        .map(|s| s.as_ref())
        .filter(|t| !has_class(t, class))
        .collect();
    assert!(
        missed.is_empty(),
        "expected a {class} finding for each of: {missed:?}"
    );
}

fn assert_not_flags<S: AsRef<str>>(class: Class, cases: &[S]) {
    let wrongly: Vec<&str> = cases
        .iter()
        .map(|s| s.as_ref())
        .filter(|t| has_class(t, class))
        .collect();
    assert!(
        wrongly.is_empty(),
        "expected NO {class} finding for any of: {wrongly:?}"
    );
}

fn assert_clean<S: AsRef<str>>(cases: &[S]) {
    let wrongly: Vec<(&str, Vec<Class>)> = cases
        .iter()
        .map(|s| s.as_ref())
        .map(|t| (t, classes_of(t)))
        .filter(|(_, c)| !c.is_empty())
        .collect();
    assert!(wrongly.is_empty(), "expected no findings, got: {wrongly:?}");
}

/// `(1-based line number, tag, text)` for each live line of `positives.txt`.
fn positives() -> Vec<(usize, &'static str, &'static str)> {
    POSITIVES
        .lines()
        .enumerate()
        .filter_map(|(i, line)| {
            if line.trim().is_empty() || line.starts_with('#') {
                return None;
            }
            let (tag, text) = line
                .split_once('\t')
                .unwrap_or_else(|| panic!("positives.txt line {} has no TAB separator", i + 1));
            Some((i + 1, tag, text))
        })
        .collect()
}

/// `(1-based line number, text)` for each non-blank line of `benign.txt`.
/// Lines starting with `#` are markdown headings here and ARE scanned.
fn benign_lines() -> Vec<(usize, &'static str)> {
    BENIGN
        .lines()
        .enumerate()
        .filter(|(_, l)| !l.trim().is_empty())
        .map(|(i, l)| (i + 1, l))
        .collect()
}

// ---------------------------------------------------------------------------
// Class API
// ---------------------------------------------------------------------------

#[test]
fn class_names_are_snake_case_and_round_trip() {
    let expected = [
        (Class::Ssn, "ssn"),
        (Class::Card, "card"),
        (Class::Dob, "dob"),
        (Class::Mrn, "mrn"),
        (Class::Phone, "phone"),
        (Class::PersonalEmail, "personal_email"),
        (Class::Secret, "secret"),
    ];
    for (class, name) in expected {
        assert_eq!(class.as_str(), name);
        assert_eq!(class.to_string(), name);
        assert_eq!(Class::from_str_name(name), Some(class));
    }
    for bad in ["", "bogus", "phone_number", "ssn ", "personal email"] {
        assert_eq!(Class::from_str_name(bad), None, "{bad:?} must not parse");
    }
    let unique: HashSet<Class> = ALL_CLASSES.iter().copied().collect();
    assert_eq!(unique.len(), ALL_CLASSES.len(), "Class must be Hash + Eq");
}

#[test]
fn default_config_trusts_the_two_work_domains() {
    let domains = GuardConfig::default().work_email_domains;
    for want in ["carefeed.com", "users.noreply.github.com"] {
        assert!(
            domains.iter().any(|d| d.eq_ignore_ascii_case(want)),
            "default work_email_domains must include {want}: {domains:?}"
        );
    }
}

// ---------------------------------------------------------------------------
// Per-class tables
// ---------------------------------------------------------------------------

#[test]
fn ssn_formatted_values_are_flagged() {
    assert_flags(
        Class::Ssn,
        &[
            "219-09-9999",
            "SSN 219-09-9999",
            "- [ ] Call back resident, SSN on the form was 219-09-9999, see PORTAL-1F2",
            "ssn:219-09-9999",
            "ssn=219-09-9999",
            "SSN\t219-09-9999",
            "(219-09-9999)",
            "\"219-09-9999\"",
            "value 219-09-9999.",
            "value 219-09-9999, next",
            "123-45-6789",
            "001-01-0001",
            "665-12-3456",
            "899-99-9999",
        ],
    );
    assert_eq!(classes_of("SSN 219-09-9999"), vec![Class::Ssn]);
}

#[test]
fn ssn_invalid_areas_groups_and_serials_are_not_flagged() {
    assert_not_flags(
        Class::Ssn,
        &[
            "000-12-3456", // area 000
            "666-12-3456", // area 666
            "900-12-3456", // 9xx areas
            "987-65-4321",
            "999-99-9999",
            "219-00-9999", // group 00
            "219-09-0000", // serial 0000
        ],
    );
}

#[test]
fn ssn_is_never_inside_a_longer_digit_or_alnum_run() {
    assert_not_flags(
        Class::Ssn,
        &[
            "1219-09-9999",
            "219-09-99991",
            "a219-09-9999",
            "deadbeef219-09-9999",
            "219-09-9999a",
            "x219-09-9999y",
        ],
    );
}

#[test]
fn ssn_does_not_fire_inside_version_strings() {
    assert_not_flags(
        Class::Ssn,
        &[
            "1.2.3-45-6789",
            "build 1.2.3-45-6789 failed",
            "v1.2.3-45-6789",
            "v2.14.0-45-g6bd7bca",
        ],
    );
}

#[test]
fn card_luhn_valid_numbers_are_flagged_in_all_common_formats() {
    assert_flags(
        Class::Card,
        &[
            "4111111111111111",
            "4111 1111 1111 1111",
            "4111-1111-1111-1111",
            "5555-5555-5555-4444",
            "5555555555554444",
            "378282246310005",   // 15-digit Amex
            "3782 822463 10005", // Amex 4-6-5
            "4222222222222",     // 13-digit Visa
            "6011111111111117",
            "30569309025904", // 14-digit Diners
            "card 4111111111111111 on file",
            "- [ ] Resident pasted card 4111 1111 1111 1111 into the billing note, PAYMENTS-9Z",
            "Card number: 4000056655665556, expiry omitted",
            "(5200 8282 8282 8210)",
        ],
    );
    assert_eq!(
        classes_of("card 4111 1111 1111 1111 on file"),
        vec![Class::Card]
    );
}

#[test]
fn card_lookalikes_are_not_flagged() {
    assert_not_flags(
        Class::Card,
        &[
            "4111111111111112",    // Luhn-invalid
            "4111 1111 1111 1112", // Luhn-invalid, spaced
            "1234567890123456",    // Luhn-invalid
            "1234 5678 9012 3456",
            "0000000000000000", // Luhn-valid but all one digit
            "1111111111111111",
            "0000 0000 0000 0000",
            "100000000008",         // Luhn-valid but only 12 digits
            "10000000000000000008", // Luhn-valid but 20 digits
            "1760611331000",        // epoch millis
            "1760611331000000",     // epoch micros
        ],
    );
}

#[test]
fn card_is_not_flagged_inside_uuids_shas_or_tracker_ids() {
    assert_not_flags(
        Class::Card,
        &[
            // Card-shaped groups embedded in a UUID.
            "9a3c5e71-4111-1111-1111-111111111111",
            // 40-hex SHA wrapped around a Luhn-valid 16-digit run.
            "a1b2c3d44111111111111111e5f6a7b8c9d0e1f2",
            "commit a1b2c3d44111111111111111e5f6a7b8c9d0e1f2 on main",
        ],
    );
    assert_clean(&[
        "PORTAL-1F2",
        "PAYMENTS-9Z",
        "CORE-1234",
        "3f2b8c1e-9a47-4d6b-b0e5-7c21a8f4d903",
        "d174668eb5c9a0f13e7d24a698c1f0b74a2e6d83",
    ]);
}

#[test]
fn dob_requires_a_label_near_a_date_in_a_known_format() {
    assert_flags(
        Class::Dob,
        &[
            "DOB 03/14/1941",
            "dob 1/9/1942",
            "Dob: 03/14/1941",
            "D.O.B: 1938-07-02",
            "D.O.B. 05/22/1940",
            "date of birth: Mar 5, 1944",
            "Date Of Birth: March 22, 1939",
            "DATE OF BIRTH 1949-04-18",
            "birth date 1947-11-30",
            "Birth Date: 12/25/1943",
            "born on 1/2/1950",
            "born 1946-03-09",
            "born on Jan 17, 1948, per the daughter",
            "DOB (per family): 03/14/1941",
            "- [ ] Resident record shows DOB 03/14/1941, confirm with the family, PORTAL-1F2",
        ],
    );
    assert_eq!(classes_of("DOB 03/14/1941"), vec![Class::Dob]);
}

#[test]
fn dob_never_fires_on_plain_dates_or_distant_or_partial_labels() {
    let far_label = format!("DOB {} 03/14/1941", "x".repeat(60));
    let cases = [
        "released 03/14/2024",
        "deploy on Mar 5, 2026",
        "due 2026-10-15",
        "merged 1/2/1950",
        "date: 03/14/1941",
        "2026-10-15T10:42:11Z",
        "DOB column is masked in the export",
        "Mask the DOB field, see PORTAL-1F2",
        "The new tracker was born from PRD 33",
        "Adobe Sign webhook retries since 2026-10-15",
        "Reborn flag rolled out 2026-10-15",
        "Unborn rows skipped on 2026-10-15",
        far_label.as_str(),
    ];
    assert_not_flags(Class::Dob, &cases);
}

#[test]
fn mrn_forms_are_flagged() {
    assert_flags(
        Class::Mrn,
        &[
            "MRN 00482913",
            "MRN: A123456",
            "mrn: 7731902",
            "mrn A9981734",
            "medical record number 7731902",
            "Medical Record Number: 7731902",
            "medical record # 55-2231",
            "Medical record # 3320145 mentioned during the call",
            "- [ ] Resident chart reference MRN 00482913 pasted into the ticket",
        ],
    );
    assert_eq!(classes_of("MRN 00482913"), vec![Class::Mrn]);
}

#[test]
fn mrn_label_without_a_value_is_not_flagged() {
    assert_not_flags(
        Class::Mrn,
        &[
            "MRN",
            "Add MRN to the guard class list",
            "the mrn column is masked",
            "medical record sync is slow",
            "medical record import for facility 8812",
        ],
    );
}

#[test]
fn phone_nanp_formats_with_separators_are_flagged() {
    assert_flags(
        Class::Phone,
        &[
            "(312) 555-0142",
            "312-555-0142",
            "312.555.0142",
            "312 555 0142",
            "+1 312 555 0142",
            "+1-312-555-0175",
            "+1 (630) 555-0109",
            "1-847-555-0123",
            "+13125550142",
            "+19175550166 appears in the webhook body",
            "call 312-555-0142.",
            "- [ ] Call back resident at (312) 555-0142 before Friday, see PORTAL-1F2",
        ],
    );
    assert_eq!(classes_of("call 312-555-0142 today"), vec![Class::Phone]);
}

#[test]
fn phone_lookalikes_and_bare_ten_digit_runs_are_not_flagged() {
    assert_not_flags(
        Class::Phone,
        &[
            "3125550142", // bare 10 digits needs +1
            "batch 3125550142",
            "312-5550-142", // order id, wrong grouping
            "ORD-312-555-014",
            "123456789",
            "1234567890",
            "2026-10-15",
            "10.0.3.17",
            "172.16.0.4",
            "192.168.10.25",
            "1760611331000",
            "$1,234.56",
            "port 8080",
            "v2.14.0",
            "8.3.12",
            "99.95%",
        ],
    );
}

#[test]
fn personal_email_flags_non_work_domains() {
    assert_flags(
        Class::PersonalEmail,
        &[
            "dorothy.hale@gmail.com",
            "r.kowalski@yahoo.com",
            "marcus.lee@outlook.com",
            "janet_ortiz@hotmail.com",
            "s.patel@icloud.com",
            "linda@smithfamily.net",
            "alex.brandt@brightmail.io",
            "bob.nguyen@yahoo.co.uk",
            "nina.vasquez+tester@gmail.com",
            "MARY.JONES@GMAIL.COM",
            "Mail from pat.obrien@gmail.com bounced on the weekly send",
            "- [ ] Resident's daughter wrote from dorothy.hale@gmail.com about the invoice",
        ],
    );
    assert_eq!(
        classes_of("write jo.hale@gmail.com today"),
        vec![Class::PersonalEmail]
    );
}

#[test]
fn work_emails_are_benign_with_default_config() {
    assert_clean(&[
        "hammer@carefeed.com",
        "HAMMER@CAREFEED.COM",
        "Hammer@CareFeed.com",
        "dependabot@users.noreply.github.com",
        "123456+user@users.noreply.github.com",
        "98765+claude-helper@Users.NoReply.GitHub.com",
        "Ping hammer@carefeed.com about the access review",
        "ops@carefeed.com and support@carefeed.com",
    ]);
}

#[test]
fn personal_email_next_to_a_work_email_flags_only_the_personal_one() {
    let text = "ping hammer@carefeed.com and dorothy.hale@gmail.com";
    let found = findings(text);
    assert_eq!(found.len(), 1, "exactly one finding expected: {found:?}");
    assert_eq!(found[0].class, Class::PersonalEmail);
    let slice = &text[found[0].range.clone()];
    assert!(
        slice.contains("dorothy.hale@gmail.com"),
        "range must cover the personal email"
    );
    assert!(
        !slice.contains("carefeed"),
        "range must not swallow the work email"
    );
}

#[test]
fn custom_work_domains_replace_the_default_list() {
    let custom = GuardConfig {
        work_email_domains: vec!["example.org".to_string()],
    };
    for benign in [
        "a@example.org",
        "a@EXAMPLE.ORG",
        "A@Example.Org",
        "mail a@example.org now",
    ] {
        assert!(
            scan(benign, &custom).is_empty(),
            "{benign:?} is a work address under the custom config"
        );
    }
    // Same address is personal under the default config.
    assert!(has_class("a@example.org", Class::PersonalEmail));
    // The custom list replaces the defaults, so carefeed.com is no longer trusted.
    assert!(scan("hammer@carefeed.com", &custom)
        .iter()
        .any(|f| f.class == Class::PersonalEmail));
}

#[test]
fn email_lookalikes_are_not_flagged() {
    assert_clean(&[
        "eslint@8.57.0",
        "lodash@4.17.21",
        "@carefeed/ui",
        "ReferralController@show",
    ]);
}

#[test]
fn secret_shapes_are_flagged() {
    let cases = [
        "AKIAIOSFODNN7EXAMPLE".to_string(),
        "ASIAIOSFODNN7EXAMPLE".to_string(),
        "AKIAABCDEFGHIJKLMNOP".to_string(),
        format!("aws_secret_access_key = {}", alnum(40)),
        format!("AWS_SECRET_ACCESS_KEY={}", alnum(40)),
        format!("ghp_{}", alnum(36)),
        format!("gho_{}", alnum(36)),
        format!("ghs_{}", alnum(36)),
        format!("ghu_{}", alnum(36)),
        format!("github_pat_{}_{}", alnum(22), alnum(59)),
        format!("xoxb-123456789012-123456789012-{}", alnum(24)),
        format!("xoxp-123456789012-123456789012-123456789012-{}", alnum(32)),
        format!("xoxa-2-123456789012-123456789012-{}", alnum(24)),
        format!("xoxr-123456789012-123456789012-{}", alnum(24)),
        format!("sk-ant-api03-{}", alnum(60)),
        format!("sk-ant-admin01-{}-{}", alnum(26), alnum(26)),
        format!("sk-{}", alnum(48)),
        format!("sk_live_{}", alnum(24)),
        format!("rk_live_{}", alnum(24)),
        format!("eyJ{}.eyJ{}.{}", alnum(30), alnum(40), alnum(43)),
        "-----BEGIN RSA PRIVATE KEY-----".to_string(),
        "-----BEGIN PRIVATE KEY-----".to_string(),
        "-----BEGIN EC PRIVATE KEY-----".to_string(),
        "-----BEGIN OPENSSH PRIVATE KEY-----".to_string(),
        format!("Authorization: Bearer {}", alnum(30)),
        format!("Bearer {}", alnum(20)),
        "postgres://user:pass@host/db".to_string(),
        "postgres://svc_portal:Sup3rS3cret@dbhost:5432/portal".to_string(),
        "mysql://root:toor1234@dbhost:3306/portal".to_string(),
        "password=hunter2hunter2".to_string(),
        "PASSWORD=hunter2hunter2".to_string(),
        "password: correcthorsebattery".to_string(),
        "api_key: abcd1234efgh".to_string(),
        "API_KEY=abcd1234efgh5678".to_string(),
        format!("- [ ] Revoke ghp_{} from the build config", alnum(36)),
        format!(
            "- [ ] Someone committed {} to the repo",
            "-----BEGIN RSA PRIVATE KEY-----"
        ),
    ];
    assert_flags(Class::Secret, &cases);
}

#[test]
fn secret_lookalikes_are_not_flagged() {
    assert_clean(&[
        "token=abc",
        "password rotation",
        "Schedule password rotation for the service accounts",
        "token budget",
        "Trim the token budget for the planner prompt",
        "secret manager",
        "Move the credentials into the secret manager",
        "sk-short",
        "sk-ant",
        "AKIA1234",
        "ghp_short",
        "xoxb-short",
        "Bearer token",
        "Bearer abc",
        "Rotate AWS_SECRET_ACCESS_KEY in SSM after the audit",
        "postgres://localhost:5432/portal",
        "redis://localhost:6379/0",
        // `sk-` in the middle of a word is not a key prefix.
        "risk-assessment-checklist-template-for-the-q4-audit",
        "fix/task-runner-worker-queue-priority-handling",
    ]);
}

// ---------------------------------------------------------------------------
// Corpus gates
// ---------------------------------------------------------------------------

#[test]
fn corpus_has_enough_lines_and_every_class() {
    let pos = positives();
    let benign = benign_lines();
    assert!(pos.len() >= 40, "positives corpus too small: {}", pos.len());
    assert!(
        benign.len() >= 200,
        "benign corpus too small: {}",
        benign.len()
    );

    let mut bad_tags = Vec::new();
    let mut seen: HashSet<Class> = HashSet::new();
    for (line_no, tag, _) in &pos {
        match Class::from_str_name(tag) {
            Some(c) => {
                seen.insert(c);
            }
            None => bad_tags.push(*line_no),
        }
    }
    assert!(
        bad_tags.is_empty(),
        "positives lines with an unknown class tag: {bad_tags:?}"
    );
    for class in ALL_CLASSES {
        assert!(
            seen.contains(&class),
            "positives corpus has no {class} line"
        );
    }
}

#[test]
fn positives_corpus_has_no_misses() {
    let mut failures: Vec<String> = Vec::new();
    let mut total = 0usize;
    for (line_no, tag, text) in positives() {
        total += 1;
        let Some(expected) = Class::from_str_name(tag) else {
            failures.push(format!("line {line_no}: unknown tag"));
            continue;
        };
        let found = findings(text);
        assert_well_formed(text, &found);
        if !found.iter().any(|f| f.class == expected) {
            failures.push(format!("line {line_no}: expected {expected}"));
        }
    }
    assert!(total >= 40, "positives corpus too small: {total}");
    assert!(
        failures.is_empty(),
        "missed {} of {total} positives (positives.txt line: expected class): {failures:?}",
        failures.len()
    );
}

#[test]
fn positives_are_still_caught_amid_multibyte_text() {
    let mut failures: Vec<String> = Vec::new();
    for (line_no, tag, text) in positives() {
        let Some(expected) = Class::from_str_name(tag) else {
            continue;
        };
        let wrapped = format!("héllo ✓ — {text} — é");
        let found = findings(&wrapped);
        assert_well_formed(&wrapped, &found);
        if !found.iter().any(|f| f.class == expected) {
            failures.push(format!("line {line_no}: expected {expected}"));
        }
    }
    assert!(
        failures.is_empty(),
        "missed in multibyte context: {failures:?}"
    );
}

#[test]
fn benign_corpus_false_alarm_rate_is_at_most_one_percent() {
    let lines = benign_lines();
    let allowed = lines.len() / 100;
    let mut flagged: Vec<(usize, Vec<&'static str>)> = Vec::new();
    for &(line_no, text) in &lines {
        let found = findings(text);
        assert_well_formed(text, &found);
        if !found.is_empty() {
            flagged.push((line_no, found.iter().map(|f| f.class.as_str()).collect()));
        }
    }
    assert!(
        flagged.len() <= allowed,
        "{} of {} benign lines flagged, at most {allowed} allowed (benign.txt line, classes): {flagged:?}",
        flagged.len(),
        lines.len()
    );
}

#[test]
fn first_class_agrees_with_scan() {
    let c = cfg();
    assert_eq!(
        first_class("- [ ] plain benign line for facility 8812", &c),
        None
    );
    assert_eq!(first_class("", &c), None);
    assert_eq!(
        first_class("- [ ] SSN 219-09-9999 on form", &c),
        Some(Class::Ssn)
    );
    assert!(first_class("call (312) 555-0142 then SSN 219-09-9999", &c).is_some());

    for (line_no, _, text) in positives() {
        let found = scan(text, &c);
        assert_eq!(
            first_class(text, &c),
            found.first().map(|f| f.class),
            "first_class disagrees with scan on positives.txt line {line_no}"
        );
    }
    for (line_no, text) in benign_lines() {
        assert_eq!(
            first_class(text, &c).is_some(),
            !scan(text, &c).is_empty(),
            "first_class disagrees with scan on benign.txt line {line_no}"
        );
    }
}

// ---------------------------------------------------------------------------
// Range correctness
// ---------------------------------------------------------------------------

#[test]
fn ranges_are_on_char_boundaries_and_cover_the_item() {
    let ghp = format!("ghp_{}", alnum(36));
    let akia = "AKIAIOSFODNN7EXAMPLE";
    let cases = [
        (
            Class::Ssn,
            "SSN 219-09-9999".to_string(),
            "219-09-9999".to_string(),
        ),
        (
            Class::Card,
            "card 4111 1111 1111 1111 on file".to_string(),
            "4111 1111 1111 1111".to_string(),
        ),
        (
            Class::Card,
            "amex 378282246310005 on file".to_string(),
            "378282246310005".to_string(),
        ),
        (
            Class::Dob,
            "DOB 03/14/1941".to_string(),
            "03/14/1941".to_string(),
        ),
        (
            Class::Dob,
            "date of birth: Mar 5, 1944".to_string(),
            "Mar 5, 1944".to_string(),
        ),
        (
            Class::Mrn,
            "MRN 00482913".to_string(),
            "00482913".to_string(),
        ),
        (
            Class::Phone,
            "call (312) 555-0142 now".to_string(),
            "312) 555-0142".to_string(),
        ),
        (
            Class::Phone,
            "call +13125550142 now".to_string(),
            "13125550142".to_string(),
        ),
        (
            Class::PersonalEmail,
            "write jo.hale@gmail.com today".to_string(),
            "jo.hale@gmail.com".to_string(),
        ),
        (
            Class::Secret,
            format!("key {akia} leaked"),
            akia.to_string(),
        ),
        (Class::Secret, format!("token {ghp} leaked"), ghp.clone()),
        (
            Class::Secret,
            "password=hunter2hunter2 in log".to_string(),
            "hunter2hunter2".to_string(),
        ),
        (
            Class::Secret,
            "pasted -----BEGIN RSA PRIVATE KEY----- here".to_string(),
            "-----BEGIN RSA PRIVATE KEY-----".to_string(),
        ),
    ];
    for (class, sentence, item) in cases {
        let text = format!("héllo ✓ — {sentence} — fin é");
        let found = findings(&text);
        assert_well_formed(&text, &found);
        let item_start = text.find(&item).expect("item present in sentence");
        let item_end = item_start + item.len();
        let covering = found
            .iter()
            .find(|f| f.class == class && f.range.start <= item_start && f.range.end >= item_end);
        let covering = covering.unwrap_or_else(|| {
            panic!(
                "no {class} finding covers the item at {item_start}..{item_end}; findings: {found:?}"
            )
        });
        assert!(
            covering.range.len() <= item.len() + 48,
            "{class} range {:?} is far wider than the {}-byte item",
            covering.range,
            item.len()
        );
        // Slicing by the range must not panic.
        let _ = &text[covering.range.clone()];
    }
}

#[test]
fn ssn_after_multibyte_text_has_an_exact_usable_range() {
    let text = "héllo ✓ SSN 219-09-9999";
    let found = findings(text);
    assert_eq!(found.len(), 1, "{found:?}");
    let f = &found[0];
    assert_eq!(f.class, Class::Ssn);
    assert!(text.is_char_boundary(f.range.start) && text.is_char_boundary(f.range.end));
    assert!(text[f.range.clone()].contains("219-09-9999"));
}

// ---------------------------------------------------------------------------
// No-echo
// ---------------------------------------------------------------------------

/// Any `window`-char substring of `input` that also appears in `haystack`.
fn shared_window(input: &str, haystack: &str, window: usize) -> Option<(usize, usize)> {
    let chars: Vec<(usize, char)> = input.char_indices().collect();
    if chars.len() < window {
        return None;
    }
    for i in 0..=(chars.len() - window) {
        let start = chars[i].0;
        let end = chars.get(i + window).map_or(input.len(), |c| c.0);
        if haystack.contains(&input[start..end]) {
            return Some((start, end));
        }
    }
    None
}

#[test]
fn findings_do_not_carry_or_print_matched_text() {
    let input = "zq-SENTINEL-9X7 note 219-09-9999 end";
    let found = findings(input);
    assert!(
        found.iter().any(|f| f.class == Class::Ssn),
        "sentinel input must produce an ssn finding"
    );

    let mut printed = String::new();
    for f in &found {
        // Exhaustive destructure: adding a field (such as matched text) breaks this test.
        let Finding { class: _, range: _ } = f;
        assert_eq!(&f.clone(), f);
        printed.push_str(&format!("{f:?}|{:?}|{}", f.class, f.class));
    }
    printed.push_str(&format!("{found:?}"));
    for class in ALL_CLASSES {
        printed.push_str(&format!("{class:?}|{class}|"));
    }
    for forbidden in ["219", "9999", "SENTINEL", "9X7", "zq-"] {
        assert!(!printed.contains(forbidden), "output leaked {forbidden:?}");
    }
    assert!(
        shared_window(input, &printed, 4).is_none(),
        "output shares a 4+ char substring with the input"
    );
}

#[test]
fn no_echo_holds_for_every_class() {
    let ghp = format!("ghp_{}", alnum(36));
    let cases: [(String, &[&str]); 7] = [
        ("zqa 4111 1111 1111 1111 zqb".to_string(), &["4111", "1111"]),
        ("zqa DOB 03/14/1941 zqb".to_string(), &["03/14", "1941"]),
        ("zqa MRN 00482913 zqb".to_string(), &["00482913", "4829"]),
        ("zqa (312) 555-0142 zqb".to_string(), &["555", "0142"]),
        (
            "zqa zqvx.unique@gmail.com zqb".to_string(),
            &["zqvx", "unique", "gmail"],
        ),
        (format!("zqa {ghp} zqb"), &["ghp_", "AbCd", "0123456789"]),
        ("zqa password=hunter2hunter2 zqb".to_string(), &["hunter2"]),
    ];
    for (text, forbidden) in &cases {
        let found = findings(text);
        assert!(!found.is_empty(), "case must produce a finding");
        let printed = format!("{found:?}");
        for f in &found {
            let shown = format!("{f:?} {} {:?}", f.class, f.class);
            for bad in forbidden.iter() {
                assert!(!shown.contains(bad), "finding output leaked {bad:?}");
            }
        }
        for bad in forbidden.iter() {
            assert!(!printed.contains(bad), "finding list output leaked {bad:?}");
        }
    }
}

// ---------------------------------------------------------------------------
// The sensitive-text-scan binary
// ---------------------------------------------------------------------------

struct ScanRun {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

fn run_scan(input: &[u8]) -> ScanRun {
    let mut child = Command::new(env!("CARGO_BIN_EXE_sensitive-text-scan"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn sensitive-text-scan");
    let mut stdin = child.stdin.take().expect("stdin pipe");
    let data = input.to_vec();
    let writer = std::thread::spawn(move || {
        // The child may exit before draining stdin; a broken pipe is not a test failure here.
        let _ = stdin.write_all(&data);
    });
    let out = child
        .wait_with_output()
        .expect("wait for sensitive-text-scan");
    writer.join().expect("stdin writer thread");
    ScanRun {
        status: out.status,
        stdout: out.stdout,
        stderr: out.stderr,
    }
}

/// The binary exited normally: not killed by a signal and not a Rust panic (101).
fn assert_no_crash(run: &ScanRun) {
    let code = run.status.code();
    assert!(
        code.is_some() && code != Some(101),
        "binary crashed: status {:?}",
        run.status
    );
}

/// Parse stdout as `line_no<TAB>class` rows, validating the shape.
fn parse_report(stdout: &[u8]) -> Vec<(usize, String)> {
    let text = String::from_utf8(stdout.to_vec()).expect("stdout must be UTF-8");
    if !text.is_empty() {
        assert!(text.ends_with('\n'), "stdout must end with a newline");
    }
    text.lines()
        .map(|row| {
            let (n, class) = row
                .split_once('\t')
                .unwrap_or_else(|| panic!("stdout row is not 'line<TAB>class': {row:?}"));
            assert!(
                Class::from_str_name(class).is_some(),
                "stdout row has an unknown class: {row:?}"
            );
            (n.parse::<usize>().expect("line number"), class.to_string())
        })
        .collect()
}

#[test]
fn scan_binary_prints_line_number_and_class_only() {
    let input = "- [ ] PORTAL-1F2 retry failed queue jobs on facility 8812\n\
                 - [ ] Tag release v2.14.0 on 2026-10-15\n\
                 - [ ] SSN 219-09-9999 on form\n";
    let run = run_scan(input.as_bytes());
    assert_no_crash(&run);
    assert_eq!(String::from_utf8_lossy(&run.stdout), "3\tssn\n");
    let stderr = String::from_utf8_lossy(&run.stderr);
    for leaked in ["219", "9999", "SSN 2"] {
        assert!(!stderr.contains(leaked), "stderr echoed input text");
    }
}

#[test]
fn scan_binary_prints_nothing_and_exits_zero_for_benign_input() {
    let input =
        "- [ ] PORTAL-1F2 retry failed queue jobs on facility 8812 (see gh run view 9912)\n\
                 - [x] PAYMENTS-9Z fix double-charge, merged in PR #4821\n\
                 - [ ] Ping hammer@carefeed.com about 2026-10-15T10:42:11Z\n\
                 ## Done\n\
                 \n\
                 - [ ] Tag v2.14.0 and run php artisan migrate --step=3\n";
    let run = run_scan(input.as_bytes());
    assert!(
        run.status.success(),
        "benign input must exit 0: {:?}",
        run.status
    );
    assert!(run.stdout.is_empty(), "benign input must print nothing");
}

#[test]
fn scan_binary_handles_empty_stdin() {
    let run = run_scan(b"");
    assert!(
        run.status.success(),
        "empty input must exit 0: {:?}",
        run.status
    );
    assert!(run.stdout.is_empty());
}

#[test]
fn scan_binary_reports_several_findings_on_one_line() {
    let input = "- [ ] benign first line\n\
                 - [ ] SSN 219-09-9999, card 4111 1111 1111 1111, call (312) 555-0142, mail dorothy.hale@gmail.com\n\
                 - [ ] benign last line\n";
    let run = run_scan(input.as_bytes());
    assert_no_crash(&run);
    let rows = parse_report(&run.stdout);

    let mut got = rows.clone();
    got.sort();
    let mut want: Vec<(usize, String)> = ["ssn", "card", "phone", "personal_email"]
        .iter()
        .map(|c| (2usize, c.to_string()))
        .collect();
    want.sort();
    assert_eq!(got, want, "expected one row per finding, all on line 2");

    let stdout = String::from_utf8_lossy(&run.stdout);
    for leaked in ["219", "4111", "555", "0142", "gmail", "dorothy"] {
        assert!(!stdout.contains(leaked), "stdout echoed input text");
    }
}

#[test]
fn scan_binary_numbers_lines_from_one_and_counts_blank_lines() {
    let input = "- [ ] benign one\n\
                 \n\
                 - [ ] call (312) 555-0142 back\n\
                 - [ ] benign four\n\
                 - [ ] MRN 00482913 on the form\n\
                 \n\
                 \n\
                 - [ ] key AKIAIOSFODNN7EXAMPLE leaked\n";
    let run = run_scan(input.as_bytes());
    assert_no_crash(&run);
    assert_eq!(
        String::from_utf8_lossy(&run.stdout),
        "3\tphone\n5\tmrn\n8\tsecret\n"
    );
}

#[test]
fn scan_binary_handles_missing_trailing_newline_and_crlf() {
    let run = run_scan(b"benign\nSSN 219-09-9999");
    assert_no_crash(&run);
    assert_eq!(String::from_utf8_lossy(&run.stdout), "2\tssn\n");

    let run = run_scan(b"benign\r\nSSN 219-09-9999\r\nbenign\r\n");
    assert_no_crash(&run);
    assert_eq!(String::from_utf8_lossy(&run.stdout), "2\tssn\n");
}

#[test]
fn scan_binary_survives_non_utf8_input() {
    // Benign-only: no findings, exit 0.
    let run = run_scan(b"first line ok\n\xff\xfe\xfd garbled bytes\nlast line ok\n");
    assert!(
        run.status.success(),
        "non-UTF-8 benign input must exit 0: {:?}",
        run.status
    );
    assert!(run.stdout.is_empty());

    // A garbled line must not stop the scan: the SSN on line 3 is still reported.
    let run =
        run_scan(b"first line ok\n\xff\xfe\xfd garbled bytes\n- [ ] SSN 219-09-9999 on form\n");
    assert_no_crash(&run);
    let rows = parse_report(&run.stdout);
    assert!(
        rows.contains(&(3, "ssn".to_string())),
        "a later line must still be scanned after a non-UTF-8 line: {rows:?}"
    );
}

#[test]
fn scan_binary_agrees_with_the_library_on_the_positives_corpus() {
    let mut input = String::new();
    let mut expected: Vec<(usize, String)> = Vec::new();
    for (i, (_, tag, text)) in positives().iter().enumerate() {
        input.push_str(text);
        input.push('\n');
        expected.push((i + 1, (*tag).to_string()));
    }
    let run = run_scan(input.as_bytes());
    assert_no_crash(&run);
    let rows = parse_report(&run.stdout);
    for want in &expected {
        assert!(
            rows.contains(want),
            "binary missed positives row {} ({})",
            want.0,
            want.1
        );
    }
    let max_line = expected.len();
    assert!(
        rows.iter().all(|(n, _)| (1..=max_line).contains(n)),
        "row outside input range"
    );
}

// ---------------------------------------------------------------------------
// Linear behaviour
// ---------------------------------------------------------------------------

fn mixed_unit() -> String {
    [
        "- [ ] plain benign line for facility 8812",
        "- [ ] Call back resident, SSN on the form was 219-09-9999, see PORTAL-1F2",
        "- [ ] card 4111 1111 1111 1111 pasted",
        "- [ ] DOB 03/14/1941 pasted",
        "- [ ] MRN 00482913 pasted",
        "- [ ] call (312) 555-0142",
        "- [ ] mail dorothy.hale@gmail.com",
        "- [ ] key AKIAIOSFODNN7EXAMPLE",
        "- [ ] hammer@carefeed.com and PR #4821, v2.14.0, 2026-10-15T10:42:11Z",
        "- [ ] plain benign closing line",
    ]
    .join("\n")
}

fn board_of(copies: usize) -> String {
    vec![mixed_unit(); copies].join("\n")
}

fn class_counts(text: &str) -> BTreeMap<&'static str, usize> {
    let mut counts = BTreeMap::new();
    for f in findings(text) {
        *counts.entry(f.class.as_str()).or_insert(0usize) += 1;
    }
    counts
}

#[test]
fn finding_counts_scale_exactly_with_input_size() {
    let one = class_counts(&board_of(1));
    assert_eq!(
        one.len(),
        ALL_CLASSES.len(),
        "each class once in the unit: {one:?}"
    );
    assert!(
        one.values().all(|&c| c == 1),
        "each class exactly once: {one:?}"
    );

    let small = class_counts(&board_of(50));
    let big = class_counts(&board_of(500));
    assert_eq!(small.len(), big.len());
    for (class, &count) in &small {
        assert_eq!(count, 50, "{class} count for 50 copies");
        assert_eq!(
            big[class],
            count * 10,
            "{class} must scale 10x for 10x input"
        );
    }
    assert_eq!(
        findings(&board_of(500)).len(),
        10 * findings(&board_of(50)).len()
    );
}

// ---------------------------------------------------------------------------
// Hostile and robustness
// ---------------------------------------------------------------------------

fn scan_checked(text: &str) -> Vec<Finding> {
    let found = findings(text);
    assert_well_formed(text, &found);
    found
}

#[test]
fn degenerate_inputs_produce_no_findings() {
    for text in ["", " ", "   \n\t\r\n  ", "\n\n\n", "\u{feff}", "é", "✓✓✓"] {
        assert!(scan_checked(text).is_empty(), "{text:?} must be clean");
    }
    assert!(scan_checked(&"\n".repeat(10_000)).is_empty());
    assert!(scan_checked(&" ".repeat(100_000)).is_empty());
}

#[test]
fn very_long_digit_runs_are_not_findings() {
    assert!(scan_checked(&"9".repeat(100_000)).is_empty());
    assert!(scan_checked(&"1234567890".repeat(10_000)).is_empty());
    assert!(scan_checked(&"0".repeat(100_000)).is_empty());
}

#[test]
fn pathological_repeated_prefixes_neither_panic_nor_hang() {
    let cases = [
        ("a@", "a@".repeat(50_000)),
        ("a@a.", "a@a.".repeat(30_000)),
        ("AKIA", "AKIA".repeat(50_000)),
        ("ASIA", "ASIA".repeat(50_000)),
        ("eyJ.", "eyJ.".repeat(50_000)),
        ("eyJ", "eyJ".repeat(50_000)),
        ("-----BEGIN ", "-----BEGIN ".repeat(20_000)),
        ("BEGIN PRIVATE", "-----BEGIN PRIVATE ".repeat(20_000)),
        ("Bearer ", "Bearer ".repeat(30_000)),
        ("sk-", "sk-".repeat(50_000)),
        ("sk_live_", "sk_live_".repeat(20_000)),
        ("ghp_", "ghp_".repeat(50_000)),
        ("github_pat_", "github_pat_".repeat(20_000)),
        ("xoxb-", "xoxb-".repeat(30_000)),
        ("password=", "password=".repeat(20_000)),
        ("api_key:", "api_key: ".repeat(20_000)),
        ("postgres://", "postgres://".repeat(20_000)),
        ("DOB ", "DOB ".repeat(50_000)),
        ("born ", "born ".repeat(50_000)),
        ("MRN ", "MRN ".repeat(50_000)),
        ("medical record # ", "medical record # ".repeat(20_000)),
        ("+1 ", "+1 ".repeat(50_000)),
        ("(", "(".repeat(100_000)),
        ("4111 ", "4111 ".repeat(30_000)),
        ("1-", "1-".repeat(50_000)),
        ("219-09-", "219-09-".repeat(30_000)),
        ("1/", "1/".repeat(50_000)),
        ("Mar 5, ", "Mar 5, ".repeat(30_000)),
        ("dot digits", "1.".repeat(50_000)),
        ("multibyte", "é✓".repeat(60_000)),
    ];
    for (_name, text) in &cases {
        scan_checked(text);
    }
}

#[test]
fn a_quarter_megabyte_of_benign_lines_is_handled() {
    let mut board = String::new();
    while board.len() < 256 * 1024 {
        for (_, line) in benign_lines() {
            board.push_str(line);
            board.push('\n');
        }
    }
    let found = scan_checked(&board);
    // Sanity: the false alarm rate on the repeated board matches the per-line gate.
    let lines = board.lines().count();
    assert!(
        found.len() <= lines / 100,
        "{} findings over {lines} benign lines",
        found.len()
    );

    // One enormous line (no newlines) must also be fine.
    let single_line = board.replace('\n', " ");
    scan_checked(&single_line);
}

// ---------------------------------------------------------------------------
// Timing bench (opt-in)
// ---------------------------------------------------------------------------

/// Run with: `cargo test --release --test sensitive_text_corpus -- --ignored`
///
/// A ~256 KiB board built from the benign corpus must scan in under 50 ms in release mode.
/// Ignored by default because debug builds and loaded CI machines are not representative.
#[test]
#[ignore = "timing bench: cargo test --release --test sensitive_text_corpus -- --ignored"]
fn scan_256kib_under_50ms_release() {
    let mut board = String::new();
    while board.len() < 256 * 1024 {
        for (_, line) in benign_lines() {
            board.push_str(line);
            board.push('\n');
        }
    }
    let c = cfg();
    // Warm up once, then take the best of three to damp scheduler noise.
    let _ = scan(&board, &c);
    let best = (0..3)
        .map(|_| {
            let start = Instant::now();
            let found = scan(&board, &c);
            let elapsed = start.elapsed();
            std::hint::black_box(found);
            elapsed
        })
        .min()
        .expect("three runs");
    assert!(
        best.as_millis() < 50,
        "scanning {} bytes took {best:?}, budget is 50 ms",
        board.len()
    );
}
