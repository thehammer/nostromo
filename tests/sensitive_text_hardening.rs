//! Sensitive-text guard hardening (PR #260 review fix-ups): behavioural tests.
//!
//! Sections:
//!   B1. Non-ASCII digits never panic and are detected (any Unicode decimal digit).
//!   S2. Invisible characters inside a value do not defeat detection; fullwidth
//!       letters and punctuation are normalised; whitespace is not "invisible".
//!   S3. A joiner next to a value is fine when the neighbour is a plain word
//!       (or `/` plus a number); look-alike identifiers stay clean.
//!   S4. A URL password is only a placeholder when the WHOLE value has a
//!       placeholder shape; userinfo without a password is not an email.
//!   N.  Nits: prefix anchoring, new secret shapes, card issuer ranges, oversize
//!       input, and the `sensitive-text-scan` binary surviving odd input.
//!
//! Every value is synthetic. Secret-shaped values are built at runtime from
//! pieces so no whole key sits in the source (GitHub push protection). Tests
//! print labels, never generated input.

use std::cell::Cell;
use std::io::Write as _;
use std::panic::{self, AssertUnwindSafe};
use std::process::{Command, Stdio};
use std::sync::Once;
use std::time::{Duration, Instant};

use nostromo::data::work::is_invisible;
use nostromo::sensitive_text::{first_class, scan, Class, Finding, GuardConfig, MAX_SCAN_BYTES};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// Bytes a finding may extend past the item on each side ("not wildly wider").
const SLACK: usize = 16;

/// Surrounding context for every item: bare, and wrapped in multibyte text.
const CONTEXTS: [(&str, &str); 2] = [("", ""), ("héllo ✓ — … — é ", " — é ✓")];

/// Zero-width, bidi, tag, soft-hyphen and BOM characters.
const INVISIBLES: [char; 5] = ['\u{200B}', '\u{202E}', '\u{E0041}', '\u{00AD}', '\u{FEFF}'];

/// `(name, code point of the script's zero)` for each Unicode decimal-digit block used.
const DIGIT_SCRIPTS: [(&str, u32); 7] = [
    ("fullwidth", 0xFF10),
    ("arabic-indic", 0x0660),
    ("extended arabic-indic", 0x06F0),
    ("devanagari", 0x0966),
    ("bengali", 0x09E6),
    ("thai", 0x0E50),
    ("mathematical", 0x1D7CE),
];

thread_local! {
    static SCANNING_QUIETLY: Cell<bool> = const { Cell::new(false) };
}
static QUIET_HOOK: Once = Once::new();

/// `scan` run under `catch_unwind`. A panic inside `scan` would print its own
/// message (which can quote the input), so a hook silences it for this thread
/// only, and the test fails with a fixed message that never includes the input.
fn scan_guarded(text: &str) -> Vec<Finding> {
    QUIET_HOOK.call_once(|| {
        let previous = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            if !SCANNING_QUIETLY.with(Cell::get) {
                previous(info);
            }
        }));
    });
    let cfg = GuardConfig::default();
    SCANNING_QUIETLY.with(|q| q.set(true));
    let result = panic::catch_unwind(AssertUnwindSafe(|| scan(text, &cfg)));
    SCANNING_QUIETLY.with(|q| q.set(false));
    result.unwrap_or_else(|_| panic!("scan panicked (input withheld)"))
}

fn findings(text: &str) -> Vec<Finding> {
    scan_guarded(text)
}

fn classes_of(text: &str) -> Vec<Class> {
    findings(text).iter().map(|f| f.class).collect()
}

fn has_class(text: &str, class: Class) -> bool {
    findings(text).iter().any(|f| f.class == class)
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

/// Structural invariants every scan result must satisfy. Never prints the text.
fn assert_well_formed(text: &str, found: &[Finding]) {
    let mut prev_start = 0;
    for f in found {
        assert!(
            f.range.start <= f.range.end,
            "inverted range {:?} ({})",
            f.range,
            f.class
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
            "range {:?} ({}) is not on char boundaries of the original text",
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

/// Deterministic mixed-case alphanumeric filler of exactly `n` chars.
fn alnum(n: usize) -> String {
    const POOL: &str = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789";
    POOL.chars().cycle().take(n).collect()
}

/// Deterministic uppercase-and-digit filler of exactly `n` chars.
fn up_alnum(n: usize) -> String {
    const POOL: &str = "QWERTYUIOPASDFGHJKLZXCVBNM0123456789";
    POOL.chars().cycle().take(n).collect()
}

/// ASCII digits in `s` rewritten into the decimal-digit block starting at `zero`.
fn map_digits(s: &str, zero: u32) -> String {
    s.chars()
        .map(|c| {
            if c.is_ascii_digit() {
                char::from_u32(zero + (c as u32 - '0' as u32)).expect("digit code point")
            } else {
                c
            }
        })
        .collect()
}

/// Digits cycle through ASCII, Arabic-Indic, fullwidth, Devanagari and
/// mathematical forms, one script per digit: a mixed-script run.
fn mixed_digits(s: &str) -> String {
    const ZEROS: [u32; 5] = [0x30, 0x0660, 0xFF10, 0x0966, 0x1D7CE];
    let mut i = 0;
    s.chars()
        .map(|c| {
            if c.is_ascii_digit() {
                let zero = ZEROS[i % ZEROS.len()];
                i += 1;
                char::from_u32(zero + (c as u32 - '0' as u32)).expect("digit code point")
            } else {
                c
            }
        })
        .collect()
}

/// ASCII `!..~` rewritten to the fullwidth forms (U+FF01..U+FF5E). Spaces stay.
fn fullwidth(s: &str) -> String {
    s.chars()
        .map(|c| {
            if ('!'..='~').contains(&c) {
                char::from_u32(c as u32 + 0xFEE0).expect("fullwidth code point")
            } else {
                c
            }
        })
        .collect()
}

/// Detected with the right class, ranges on original char boundaries covering
/// the item (`prefix` and `suffix` are context, not part of the item).
fn check_detected(class: Class, prefix: &str, item: &str, suffix: &str) -> Result<(), String> {
    let text = format!("{prefix}{item}{suffix}");
    let found = findings(&text);
    assert_well_formed(&text, &found);
    let (item_start, item_end) = (prefix.len(), prefix.len() + item.len());
    let Some(f) = found
        .iter()
        .find(|f| f.class == class && f.range.start < item_end && f.range.end > item_start)
    else {
        return Err(format!(
            "no {class} finding over the item (classes found: {:?})",
            found.iter().map(|f| f.class).collect::<Vec<_>>()
        ));
    };
    if f.range.start > item_start || f.range.end < item_end {
        return Err(format!(
            "range {:?} does not cover the item {item_start}..{item_end}",
            f.range
        ));
    }
    if f.range.start + SLACK < item_start || f.range.end > item_end + SLACK {
        return Err(format!(
            "range {:?} is wildly wider than the item {item_start}..{item_end}",
            f.range
        ));
    }
    Ok(())
}

/// `(label, class, prefix, item)`: the item must be detected in every context.
type Case = (String, Class, String, String);

fn case(name: impl Into<String>, class: Class, prefix: &str, item: impl Into<String>) -> Case {
    (name.into(), class, prefix.to_string(), item.into())
}

fn run_cases(cases: &[Case]) {
    let mut failures = Vec::new();
    let mut total = 0;
    for (name, class, prefix, item) in cases {
        for (i, (pre, suf)) in CONTEXTS.iter().enumerate() {
            total += 1;
            let full_prefix = format!("{pre}{prefix}");
            if let Err(e) = check_detected(*class, &full_prefix, item, suf) {
                failures.push(format!("{name} [context {i}]: {e}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {total} cases failed: {failures:#?}",
        failures.len()
    );
}

/// Luhn check over an ASCII digit string.
fn luhn_valid(digits: &str) -> bool {
    let sum: u32 = digits
        .bytes()
        .rev()
        .enumerate()
        .map(|(i, b)| {
            let d = u32::from(b - b'0');
            if i % 2 == 1 {
                let d2 = d * 2;
                if d2 > 9 {
                    d2 - 9
                } else {
                    d2
                }
            } else {
                d
            }
        })
        .sum();
    sum.is_multiple_of(10)
}

/// A Luhn-valid 16-digit number starting with `first`, padded with varied digits.
fn card_starting_with(first: &str) -> String {
    let mut body = String::from(first);
    let mut i = 0u8;
    while body.len() < 15 {
        body.push(char::from(b'0' + (i * 7 + 3) % 10));
        i += 1;
    }
    (0..10)
        .map(|c| format!("{body}{c}"))
        .find(|candidate| luhn_valid(candidate))
        .expect("some check digit makes the number Luhn-valid")
}

/// `1234567812345678` -> `1234 5678 1234 5678`.
fn spaced_by_four(digits: &str) -> String {
    digits
        .as_bytes()
        .chunks(4)
        .map(|c| std::str::from_utf8(c).expect("ascii"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Tiny deterministic PRNG (xorshift64) so the fuzz tests need no dependency.
struct Xorshift(u64);

impl Xorshift {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

// ---------------------------------------------------------------------------
// B1. Non-ASCII digits
// ---------------------------------------------------------------------------

#[test]
fn the_exact_fullwidth_ssn_that_panicked_is_detected_without_panicking() {
    let item = format!(
        "{}-{}-{}",
        "\u{FF12}\u{FF11}\u{FF19}",
        "\u{FF10}\u{FF19}",
        "\u{FF19}".repeat(4)
    );
    check_detected(Class::Ssn, "ssn ", &item, "").expect("fullwidth ssn repro");
}

#[test]
fn the_digit_blocks_used_here_are_ten_decimal_digits_each() {
    // Guards the test helpers themselves: every block must be 10 chars of \p{Nd}.
    for (name, zero) in DIGIT_SCRIPTS {
        for d in 0..10 {
            let c = char::from_u32(zero + d).expect("code point");
            assert!(c.is_numeric(), "{name} digit {d} is not numeric");
            assert!(!c.is_ascii(), "{name} digit {d} is ASCII");
        }
    }
}

#[test]
fn ssn_in_any_unicode_digit_script_is_detected() {
    let mut cases = Vec::new();
    for (script, zero) in DIGIT_SCRIPTS {
        cases.push(case(
            format!("ssn {script}"),
            Class::Ssn,
            "ssn ",
            map_digits("219-09-9999", zero),
        ));
    }
    cases.push(case(
        "ssn fullwidth digits and fullwidth hyphens",
        Class::Ssn,
        "ssn ",
        "２１９\u{FF0D}０９\u{FF0D}９９９９",
    ));
    cases.push(case(
        "ssn mixed scripts",
        Class::Ssn,
        "ssn ",
        mixed_digits("219-09-9999"),
    ));
    cases.push(case(
        "ssn mixed scripts, bare",
        Class::Ssn,
        "",
        mixed_digits("123-45-6789"),
    ));
    run_cases(&cases);
}

#[test]
fn card_in_any_unicode_digit_script_is_detected() {
    let mut cases = Vec::new();
    for (script, zero) in DIGIT_SCRIPTS {
        cases.push(case(
            format!("card spaced {script}"),
            Class::Card,
            "card ",
            map_digits("4111 1111 1111 1111", zero),
        ));
        cases.push(case(
            format!("card plain {script}"),
            Class::Card,
            "card ",
            map_digits("4111111111111111", zero),
        ));
    }
    cases.push(case(
        "card mixed scripts spaced",
        Class::Card,
        "card ",
        mixed_digits("4111 1111 1111 1111"),
    ));
    cases.push(case(
        "card mixed scripts plain",
        Class::Card,
        "card ",
        mixed_digits("5555555555554444"),
    ));
    run_cases(&cases);
}

#[test]
fn phone_in_any_unicode_digit_script_is_detected() {
    let mut cases = Vec::new();
    for (script, zero) in DIGIT_SCRIPTS {
        cases.push(case(
            format!("phone dashed {script}"),
            Class::Phone,
            "call ",
            map_digits("312-555-0142", zero),
        ));
        cases.push(case(
            format!("phone parens {script}"),
            Class::Phone,
            "call ",
            map_digits("(312) 555-0142", zero),
        ));
    }
    cases.push(case(
        "phone fullwidth parens text",
        Class::Phone,
        "call ",
        "(３１２) ５５５-０１４２",
    ));
    cases.push(case(
        "phone mixed scripts",
        Class::Phone,
        "call ",
        mixed_digits("312-555-0142"),
    ));
    run_cases(&cases);
}

#[test]
fn dob_in_any_unicode_digit_script_is_detected() {
    let mut cases = Vec::new();
    for (script, zero) in DIGIT_SCRIPTS {
        cases.push(case(
            format!("dob slashes {script}"),
            Class::Dob,
            "DOB ",
            map_digits("03/14/1941", zero),
        ));
        cases.push(case(
            format!("dob iso {script}"),
            Class::Dob,
            "DOB ",
            map_digits("1941-03-14", zero),
        ));
    }
    cases.push(case(
        "dob devanagari from the review",
        Class::Dob,
        "DOB ",
        "०३/१४/१९४१",
    ));
    cases.push(case(
        "dob fullwidth iso from the review",
        Class::Dob,
        "DOB ",
        "１９４１-０３-１４",
    ));
    cases.push(case(
        "dob mixed scripts",
        Class::Dob,
        "DOB ",
        mixed_digits("03/14/1941"),
    ));
    run_cases(&cases);
}

#[test]
fn mrn_in_any_unicode_digit_script_is_detected() {
    let mut cases = Vec::new();
    for (script, zero) in DIGIT_SCRIPTS {
        cases.push(case(
            format!("mrn {script}"),
            Class::Mrn,
            "see ",
            format!("MRN {}", map_digits("000482913", zero)),
        ));
    }
    cases.push(case(
        "mrn fullwidth from the review",
        Class::Mrn,
        "see ",
        "MRN ０００４８２９１３",
    ));
    cases.push(case(
        "mrn mixed scripts",
        Class::Mrn,
        "see ",
        format!("MRN {}", mixed_digits("000482913")),
    ));
    run_cases(&cases);
}

#[test]
fn non_ascii_digits_in_benign_positions_stay_clean_and_never_panic() {
    // Same shapes as the positives, but not valid: no panic, no finding.
    let cases = [
        map_digits("000-12-3456", 0xFF10),                 // area 000
        map_digits("4111 1111 1111 1112", 0x0660),         // Luhn-invalid
        map_digits("1.2.3-45-6789", 0x0966),               // version string
        map_digits("released 03/14/2024", 0xFF10),         // date with no label
        map_digits("1760611331000", 0x06F0),               // epoch millis
        format!("a{}", map_digits("219-09-9999", 0xFF10)), // glued to a letter
    ];
    assert_clean(&cases);
}

// ---------------------------------------------------------------------------
// B1. Fuzz: never panic, always well formed, formatting never carries text
// ---------------------------------------------------------------------------

fn fuzz_pool() -> Vec<String> {
    let mut pool: Vec<String> = Vec::new();
    // ASCII digits and letters.
    for d in '0'..='9' {
        pool.push(d.to_string());
    }
    for l in [
        "a", "e", "f", "x", "k", "p", "A", "K", "I", "S", "N", "D", "O", "B",
    ] {
        pool.push(l.to_string());
    }
    // Punctuation and whitespace.
    for p in [
        "-", "_", ".", ":", "/", "@", "=", "+", "(", ")", " ", "\n", " ", "-", "-", "\t",
    ] {
        pool.push(p.to_string());
    }
    // Label and secret-prefix words.
    for w in [
        "SSN",
        "DOB",
        "MRN",
        "born",
        "password",
        "token",
        "Bearer",
        "AKIA",
        "ghp_",
        "sk-",
        "http://u:p@h",
        "-----BEGIN RSA PRIVATE KEY-----",
        "xoxb-",
        "Basic",
        "card",
    ] {
        pool.push(w.to_string());
    }
    // Every digit of every non-ASCII decimal-digit block.
    for (_, zero) in DIGIT_SCRIPTS {
        for d in 0..10 {
            pool.push(char::from_u32(zero + d).expect("digit").to_string());
        }
    }
    // Whole value shapes, rendered in every digit script and mixed, so random
    // strings regularly contain a complete value (a lone digit never would).
    for template in [
        "219-09-9999",
        "4111 1111 1111 1111",
        "4111111111111111",
        "(312) 555-0142",
        "312-555-0142",
        "03/14/1941",
        "1941-03-14",
        "MRN 00482913",
        "DOB 03/14/1941",
    ] {
        for (_, zero) in DIGIT_SCRIPTS {
            pool.push(map_digits(template, zero));
        }
        pool.push(mixed_digits(template));
        pool.push(fullwidth(template));
    }
    pool.push(format!("AKIA{}", up_alnum(16)));
    pool.push(fullwidth(&format!("AKIA{}", up_alnum(16))));
    pool.push(format!("ghp_{}", alnum(36)));
    pool.push("password=hunter2hunter2".to_string());
    pool.push("postgres://u:pass1234@host/db".to_string());
    pool.push("jo.hale@gmail.com".to_string());
    // Fullwidth letters and punctuation.
    for f in [
        "Ａ", "Ｋ", "Ｉ", "ｇ", "ｈ", "ｐ", "＿", "＠", "＝", "－", "．", "ｓ", "ｘ", "：", "／",
    ] {
        pool.push(f.to_string());
    }
    // Zero-width, bidi, tag, soft hyphen, BOM, joiners.
    for i in [
        "\u{200B}",
        "\u{202E}",
        "\u{E0041}",
        "\u{00AD}",
        "\u{FEFF}",
        "\u{200D}",
        "\u{2060}",
    ] {
        pool.push(i.to_string());
    }
    // Combining marks.
    for c in ["\u{0301}", "\u{0308}", "\u{20D7}", "\u{0327}"] {
        pool.push(c.to_string());
    }
    // Emoji, 4-byte characters, other multibyte text and dashes.
    for e in ["😀", "✓", "🇺🇸", "𝄞", "𠀀", "𝟏", "é", "—", "…", "–", "−"] {
        pool.push(e.to_string());
    }
    pool
}

#[test]
fn fuzz_scan_never_panics_and_findings_are_well_formed_and_carry_no_text() {
    let pool = fuzz_pool();
    let mut rng = Xorshift(0x9E37_79B9_7F4A_7C15);
    for iteration in 0..2000 {
        let len = rng.below(200);
        let mut text = String::new();
        for _ in 0..len {
            text.push_str(&pool[rng.below(pool.len())]);
        }
        // Panics inside scan_guarded fail with a fixed message, never the input.
        let found = scan_guarded(&text);
        assert_well_formed(&text, &found);
        for f in &found {
            let shown = format!("{f:?} {f}");
            assert!(
                shown
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || " {}:,._".contains(c)),
                "iteration {iteration}: a formatted finding holds characters beyond a class name and numbers"
            );
        }
    }
}

#[test]
fn fuzz_items_are_found_with_correct_ranges_amid_multibyte_noise() {
    // Noise has no letters or digits, so it can never glue to an item.
    let noise_pool = [
        "😀", "✓", "—", "…", "𝄞", " ", "  ", "\n", "𠀀", "🇺🇸", "–", "·",
    ];
    let items: Vec<(Class, &str, String)> = vec![
        (Class::Ssn, "", mixed_digits("219-09-9999")),
        (Class::Card, "", mixed_digits("4111 1111 1111 1111")),
        (Class::Phone, "", map_digits("(312) 555-0142", 0x0966)),
        (Class::Dob, "DOB ", map_digits("03/14/1941", 0x0660)),
        (
            Class::Mrn,
            "",
            format!("MRN {}", map_digits("00482913", 0xFF10)),
        ),
        (Class::Secret, "", format!("AKIA\u{200B}{}", up_alnum(16))),
    ];
    let mut rng = Xorshift(0xD1B5_4A32_D192_ED03);
    let mut failures = Vec::new();
    for i in 0..300 {
        let (class, label, item) = &items[i % items.len()];
        let mut prefix = String::new();
        for _ in 0..rng.below(6) {
            prefix.push_str(noise_pool[rng.below(noise_pool.len())]);
        }
        prefix.push_str(label);
        let mut suffix = String::new();
        for _ in 0..rng.below(6) {
            suffix.push_str(noise_pool[rng.below(noise_pool.len())]);
        }
        if let Err(e) = check_detected(*class, &prefix, item, &suffix) {
            failures.push(format!("iteration {i} ({class}): {e}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of 300 failed: {failures:#?}",
        failures.len()
    );
}

// ---------------------------------------------------------------------------
// S2. Invisible characters, fullwidth letters, odd separators
// ---------------------------------------------------------------------------

#[test]
fn the_invisible_characters_under_test_are_invisible_to_the_shared_predicate() {
    for zw in INVISIBLES {
        assert!(is_invisible(zw), "U+{:04X} must be invisible", zw as u32);
    }
}

#[test]
fn invisible_character_inside_a_phi_value_does_not_defeat_detection() {
    let mut cases = Vec::new();
    for zw in INVISIBLES {
        let u = zw as u32;
        cases.push(case(
            format!("ssn zw between groups U+{u:04X}"),
            Class::Ssn,
            "ssn ",
            format!("219-{zw}09-9999"),
        ));
        cases.push(case(
            format!("ssn zw before hyphen U+{u:04X}"),
            Class::Ssn,
            "ssn ",
            format!("219{zw}-09-9999"),
        ));
        cases.push(case(
            format!("ssn zw inside a group U+{u:04X}"),
            Class::Ssn,
            "ssn ",
            format!("2{zw}19-09-9999"),
        ));
        cases.push(case(
            format!("card zw after first group U+{u:04X}"),
            Class::Card,
            "card ",
            format!("4111{zw}1111 1111 1111"),
        ));
        cases.push(case(
            format!("card zw inside a digit run U+{u:04X}"),
            Class::Card,
            "card ",
            format!("41{zw}11111111111111"),
        ));
        cases.push(case(
            format!("phone zw before hyphen U+{u:04X}"),
            Class::Phone,
            "call ",
            format!("312-555{zw}-0142"),
        ));
        cases.push(case(
            format!("dob zw inside the label U+{u:04X}"),
            Class::Dob,
            &format!("D{zw}OB "),
            "03/14/1941",
        ));
        cases.push(case(
            format!("dob zw inside the date U+{u:04X}"),
            Class::Dob,
            "DOB ",
            format!("03/{zw}14/1941"),
        ));
        cases.push(case(
            format!("mrn zw inside the label U+{u:04X}"),
            Class::Mrn,
            "see ",
            format!("M{zw}RN 00482913"),
        ));
        cases.push(case(
            format!("email zw before the at sign U+{u:04X}"),
            Class::PersonalEmail,
            "mail ",
            format!("jo.hale{zw}@gmail.com"),
        ));
        cases.push(case(
            format!("email zw inside the domain U+{u:04X}"),
            Class::PersonalEmail,
            "mail ",
            format!("jo.hale@gmail{zw}.com"),
        ));
    }
    run_cases(&cases);
}

#[test]
fn invisible_character_inside_a_secret_does_not_defeat_detection() {
    let mut cases = Vec::new();
    for zw in INVISIBLES {
        let u = zw as u32;
        cases.push(case(
            format!("aws key id U+{u:04X}"),
            Class::Secret,
            "key ",
            format!("AKIA{zw}{}", up_alnum(16)),
        ));
        cases.push(case(
            format!("github token U+{u:04X}"),
            Class::Secret,
            "token ",
            format!("ghp{zw}_{}", alnum(36)),
        ));
        cases.push(case(
            format!("password assignment U+{u:04X}"),
            Class::Secret,
            "log ",
            format!("pass{zw}word=hunter2hunter2"),
        ));
        cases.push(case(
            format!("pem header U+{u:04X}"),
            Class::Secret,
            "",
            format!("-----BEGIN RSA PRIV{zw}ATE KEY-----"),
        ));
        cases.push(case(
            format!("url credentials U+{u:04X}"),
            Class::Secret,
            "",
            format!("postgres://u:pa{zw}ss1234@host"),
        ));
    }
    run_cases(&cases);
}

#[test]
fn invisible_character_used_as_a_separator_still_lets_the_value_stand_alone() {
    let mut cases = Vec::new();
    for zw in INVISIBLES {
        let u = zw as u32;
        cases.push(case(
            format!("ssn after zw separator U+{u:04X}"),
            Class::Ssn,
            &format!("SSN{zw}"),
            "219-09-9999",
        ));
        cases.push(case(
            format!("phone after zw separator U+{u:04X}"),
            Class::Phone,
            &format!("call{zw}"),
            "312-555-0142",
        ));
    }
    run_cases(&cases);
}

#[test]
fn invisible_characters_do_not_make_a_non_card_into_a_card() {
    let mut cases: Vec<String> = Vec::new();
    for zw in INVISIBLES {
        cases.push(format!("1234{zw}5678"));
        cases.push(format!("4111{zw}1111 1111 1112")); // Luhn-invalid
        cases.push(format!("1760611331{zw}000")); // epoch millis
        cases.push(format!("0000{zw}0000 0000 0000")); // one repeated digit
    }
    assert_not_flags(Class::Card, &cases);
}

#[test]
fn whitespace_is_not_dropped_as_invisible() {
    // A newline or tab between a label and a value is a separator, not nothing.
    assert_flags(
        Class::Ssn,
        &["SSN\n219-09-9999", "SSN\t219-09-9999", "SSN 219-09-9999"],
    );
    // `1234\n5678` stays two runs: dropping the newline would make a Luhn-valid card.
    assert_not_flags(
        Class::Card,
        &[
            "4111111\n111111111",
            "4111111\t111111111",
            "4111111\r\n111111111",
        ],
    );
    assert_flags(Class::Card, &["4111111111111111", "card\n4111111111111111"]);
}

#[test]
fn fullwidth_letters_and_punctuation_are_normalised() {
    let aws = fullwidth(&format!("AKIA{}", up_alnum(16)));
    let ghp = fullwidth(&format!("ghp_{}", alnum(36)));
    let password = format!("{}\u{FF1D}hunter2hunter2", fullwidth("password"));
    let email = format!("jo.hale{}gmail{}com", '\u{FF20}', '\u{FF0E}');
    let cases = vec![
        case("fullwidth aws key id", Class::Secret, "key ", aws),
        case("fullwidth github token", Class::Secret, "token ", ghp),
        case(
            "fullwidth password assignment",
            Class::Secret,
            "log ",
            password,
        ),
        case(
            "fullwidth at and dot in an email",
            Class::PersonalEmail,
            "mail ",
            email,
        ),
        case(
            "fullwidth email, all fullwidth",
            Class::PersonalEmail,
            "mail ",
            fullwidth("jo.hale@gmail.com"),
        ),
    ];
    run_cases(&cases);
}

#[test]
fn en_dash_and_minus_sign_separate_ssn_groups_like_a_hyphen() {
    let cases = vec![
        case(
            "ssn en dash",
            Class::Ssn,
            "ssn ",
            "219\u{2013}09\u{2013}9999",
        ),
        case(
            "ssn minus sign",
            Class::Ssn,
            "ssn ",
            "219\u{2212}09\u{2212}9999",
        ),
        case(
            "ssn fullwidth hyphen",
            Class::Ssn,
            "ssn ",
            "219\u{FF0D}09\u{FF0D}9999",
        ),
    ];
    run_cases(&cases);
}

// ---------------------------------------------------------------------------
// S3. standalone(): joiners next to a value
// ---------------------------------------------------------------------------

#[test]
fn a_plain_word_joined_to_a_value_does_not_hide_it() {
    let cases = vec![
        case("ssn after dash word", Class::Ssn, "SSN-", "219-09-9999"),
        case(
            "ssn after underscore word",
            Class::Ssn,
            "SSN_",
            "219-09-9999",
        ),
        case("ssn after slash word", Class::Ssn, "id/", "219-09-9999"),
        case(
            "phone after dash word",
            Class::Phone,
            "tel-",
            "312-555-0142",
        ),
        case(
            "phone after slash word",
            Class::Phone,
            "contact/",
            "312-555-0142",
        ),
        case(
            "card after dash word",
            Class::Card,
            "card-",
            "4111111111111111",
        ),
    ];
    run_cases(&cases);
    assert_flags(
        Class::Ssn,
        &["ssn 219-09-9999.Then more", "ssn 219-09-9999.Then"],
    );
    // The dot word after the value must not drag the range over it.
    let text = "ssn 219-09-9999.Then more";
    let f = findings(text)
        .into_iter()
        .find(|f| f.class == Class::Ssn)
        .expect("ssn finding");
    assert!(f.range.end <= text.find('.').expect("dot") + SLACK);
}

#[test]
fn two_numbers_joined_by_a_slash_are_each_a_value() {
    let text = "219-09-9999/219-09-9998";
    assert!(has_class(text, Class::Ssn), "slash-joined ssn pair");
    check_detected(Class::Ssn, "", "219-09-9999", "/219-09-9998").expect("first ssn of the pair");
}

#[test]
fn joiner_lookalikes_stay_clean() {
    assert_clean(&joiner_lookalikes());
}

fn joiner_lookalikes() -> Vec<&'static str> {
    vec![
        "3f2b8c1e-9a47-4d6b-b0e5-7c21a8f4d903",
        "1.2.3-45-6789",
        "v1.2.3-45-6789",
        "a1-219-09-9999",
        "x2_219-09-9999",
        "1219-09-9999",
        "219-09-9999a",
        "a219-09-9999",
        "9a3c5e71-4111-1111-1111-111111111111",
        "1760611331000/1760611331001",
        "https://sentry.example.org/organizations/carefeed/issues/PORTAL-1F2/events/3f2b8c1e9a474d6bb0e57c21a8f4d903/",
        "https://carefeed.atlassian.net/browse/CORE-1234",
    ]
}

#[test]
fn a_hex_looking_or_single_letter_word_joined_to_an_ssn_still_hides_it() {
    // The relaxation is for plain words only: not one letter, not a hex-looking word.
    assert_not_flags(
        Class::Ssn,
        &[
            "a-219-09-9999",
            "x-219-09-9999",
            "dead-219-09-9999",
            "face_219-09-9999",
        ],
    );
}

#[test]
fn joiner_lookalike_lines_are_in_the_benign_corpus() {
    // The corpus gate only measures lines that are in benign.txt.
    const BENIGN: &str = include_str!("fixtures/sensitive_text/benign.txt");
    let heading = BENIGN
        .lines()
        .position(|l| l.trim() == "## Joiner look-alikes")
        .expect("benign.txt has a '## Joiner look-alikes' heading");
    let after_heading: Vec<&str> = BENIGN.lines().skip(heading + 1).collect();
    let missing: Vec<&str> = joiner_lookalikes()
        .into_iter()
        .filter(|l| !after_heading.contains(l))
        .collect();
    assert!(
        missing.is_empty(),
        "benign.txt lacks these look-alike lines under the heading: {missing:?}"
    );
}

#[test]
fn joiner_positives_are_in_the_positives_corpus() {
    const POSITIVES: &str = include_str!("fixtures/sensitive_text/positives.txt");
    for want in [
        "ssn\tSSN-219-09-9999",
        "phone\ttel-312-555-0142",
        "card\tcard-4111111111111111",
    ] {
        assert!(
            POSITIVES.lines().any(|l| l == want),
            "positives.txt lacks the joiner positive for class {}",
            want.split('\t').next().unwrap_or("?")
        );
    }
}

// ---------------------------------------------------------------------------
// S4. URL password placeholders
// ---------------------------------------------------------------------------

#[test]
fn a_url_password_that_merely_starts_like_a_placeholder_is_still_a_secret() {
    assert_flags(
        Class::Secret,
        &[
            "postgres://u:$ecret99@h/db",
            "postgres://u:%40ecret99@h/db",
            "postgres://u:*ecret99@h/db",
            "postgres://u:{ecret99@h/db",
            "postgres://u:<ecret99@h/db",
            "postgres://u:$ecret@h/db",
            "postgres://u:<>@h/db",
        ],
    );
}

#[test]
fn a_url_password_with_a_whole_placeholder_shape_is_not_a_secret() {
    assert_not_flags(
        Class::Secret,
        &[
            "postgres://u:${DB_PASSWORD}@h/db",
            "postgres://u:${pass}@h/db",
            "postgres://u:$DB_PASSWORD@h/db",
            "postgres://u:<password>@h/db",
            "postgres://u:<your-db-password>@h/db",
            "postgres://u:%s@h/db",
            "postgres://u:{{DB_PASS}}@h/db",
            "postgres://u:********@h/db",
        ],
    );
}

#[test]
fn url_credentials_are_a_secret_and_not_also_a_personal_email() {
    let text = "mongodb+srv://u:Pa55word@c.mongodb.net/db";
    assert!(
        has_class(text, Class::Secret),
        "url credentials are a secret"
    );
    assert!(
        !has_class(text, Class::PersonalEmail),
        "the user:password@host part of a URL is not an email address"
    );
    assert!(
        classes_of(text).iter().all(|c| *c == Class::Secret),
        "only secret findings expected"
    );
}

#[test]
fn url_userinfo_without_a_password_is_not_a_personal_email() {
    assert_not_flags(
        Class::PersonalEmail,
        &[
            "ssh://deploy@host.example.com/x",
            "ssh://deploy@host.example.com",
        ],
    );
}

#[test]
fn a_real_address_next_to_a_url_with_userinfo_is_still_flagged_on_its_own() {
    let text = "ssh://deploy@host.example.com/x and jo.hale@gmail.com";
    let emails: Vec<Finding> = findings(text)
        .into_iter()
        .filter(|f| f.class == Class::PersonalEmail)
        .collect();
    assert_eq!(emails.len(), 1, "exactly the real address: {emails:?}");
    let real = text.find("jo.hale").expect("address");
    assert!(
        emails[0].range.start >= real.saturating_sub(SLACK) && emails[0].range.start <= real,
        "the finding must sit on the real address, not the ssh url: {:?}",
        emails[0].range
    );
    assert!(emails[0].range.end >= text.len());
}

// ---------------------------------------------------------------------------
// Nits: prefix anchoring
// ---------------------------------------------------------------------------

#[test]
fn secret_prefixes_are_found_after_underscores_lowercase_letters_and_in_any_case() {
    assert_flags(
        Class::Secret,
        &[
            format!("key_AKIA{}", up_alnum(16)),
            format!("xAKIA{}", up_alnum(16)),
            format!("akia{}", up_alnum(16).to_ascii_lowercase()),
            format!("token_ghp_{}", alnum(36)),
            format!("GHP_{}", alnum(36)),
            "-----begin private key-----".to_string(),
            "-----BEGIN rsa private key-----".to_string(),
        ],
    );
}

#[test]
fn ordinary_words_that_contain_asia_are_not_aws_keys() {
    assert_clean(&["EurasiaOperationsBoard", "WesternAsiaRegionPlanning"]);
}

// ---------------------------------------------------------------------------
// Nits: new secret shapes
// ---------------------------------------------------------------------------

#[test]
fn more_vendor_token_shapes_are_secrets() {
    let slack_app = format!("{}-1-A012345-{}-{}", "xapp", "1234567890123", alnum(30));
    let google = format!("{}{}_-", "AIza", alnum(33));
    let basic = format!("Authorization: Basic {}==", alnum(22));
    assert_flags(
        Class::Secret,
        &[
            format!("{}-1-{}", "xoxe", alnum(40)),
            format!("{}.{}-1-{}", "xoxe", "xoxp", alnum(40)),
            slack_app,
            google,
            format!("{}_live_{}", "sk", alnum(24)),
            format!("{}_test_{}", "sk", alnum(24)),
            format!("{}_live_{}", "pk", alnum(24)),
            format!("{}_{}", "npm", alnum(36)),
            basic,
        ],
    );
}

#[test]
fn words_that_merely_resemble_token_prefixes_are_clean() {
    assert_clean(&[
        "relaxapp-deploy-pipeline-config",
        "disk_live_metrics_dashboard_widget",
        "Authorization: Basic authentication",
        "npm_config_cache_directory_path_value_x",
        "xapp-deploy-pipeline-config",
    ]);
}

// ---------------------------------------------------------------------------
// Nits: plausible card issuers
// ---------------------------------------------------------------------------

#[test]
fn luhn_valid_numbers_from_unissued_ranges_are_not_cards() {
    let mut cases = Vec::new();
    for first in [
        "0", "1", "7", "8", "9", "2000", "2100", "2220", "2721", "2800",
    ] {
        let plain = card_starting_with(first);
        assert!(luhn_valid(&plain) && plain.len() == 16, "helper bug");
        cases.push(spaced_by_four(&plain));
        cases.push(plain);
    }
    assert_not_flags(Class::Card, &cases);
}

#[test]
fn luhn_valid_numbers_at_the_edges_of_the_mastercard_2_series_are_cards() {
    let mut cases = Vec::new();
    for first in ["2221", "2720", "2500"] {
        let plain = card_starting_with(first);
        cases.push(spaced_by_four(&plain));
        cases.push(plain);
    }
    assert_flags(Class::Card, &cases);
}

// ---------------------------------------------------------------------------
// Nits: oversize input
// ---------------------------------------------------------------------------

#[test]
fn oversize_class_has_a_stable_name_that_round_trips() {
    assert_eq!(Class::Oversize.as_str(), "oversize");
    assert_eq!(Class::Oversize.to_string(), "oversize");
    assert_eq!(Class::from_str_name("oversize"), Some(Class::Oversize));
}

#[test]
fn text_over_the_limit_yields_one_oversize_finding_covering_it_and_returns_fast() {
    let mut text = "1 ".repeat(MAX_SCAN_BYTES / 2);
    text.push('1');
    assert_eq!(text.len(), MAX_SCAN_BYTES + 1);
    let started = Instant::now();
    let found = scan_guarded(&text);
    let elapsed = started.elapsed();
    assert_eq!(
        found,
        vec![Finding {
            class: Class::Oversize,
            range: 0..text.len()
        }]
    );
    assert!(
        elapsed < Duration::from_secs(1),
        "oversize text must be refused without scanning it, took {elapsed:?}"
    );
}

#[test]
fn oversize_text_is_refused_even_when_it_holds_a_value() {
    let mut text = String::from("SSN 219-09-9999 ");
    text.push_str(&" ".repeat(MAX_SCAN_BYTES));
    let found = scan_guarded(&text);
    assert_eq!(
        found,
        vec![Finding {
            class: Class::Oversize,
            range: 0..text.len()
        }]
    );
}

#[test]
fn oversize_range_ends_on_a_char_boundary_for_multibyte_text() {
    let text = "é".repeat(MAX_SCAN_BYTES / 2 + 1);
    assert!(text.len() > MAX_SCAN_BYTES);
    let found = scan_guarded(&text);
    assert_eq!(
        found,
        vec![Finding {
            class: Class::Oversize,
            range: 0..text.len()
        }]
    );
    assert_well_formed(&text, &found);
}

#[test]
fn first_class_of_oversize_text_is_oversize() {
    let text = " ".repeat(MAX_SCAN_BYTES + 1);
    assert_eq!(
        first_class(&text, &GuardConfig::default()),
        Some(Class::Oversize)
    );
}

#[test]
fn text_of_exactly_the_limit_is_scanned_normally() {
    let spaces = " ".repeat(MAX_SCAN_BYTES);
    assert_eq!(spaces.len(), MAX_SCAN_BYTES);
    assert!(scan_guarded(&spaces).is_empty(), "blank text at the limit");

    let head = "SSN 219-09-9999";
    let text = format!("{head}{}", " ".repeat(MAX_SCAN_BYTES - head.len()));
    assert_eq!(text.len(), MAX_SCAN_BYTES);
    let found = scan_guarded(&text);
    assert_eq!(
        found.iter().map(|f| f.class).collect::<Vec<_>>(),
        vec![Class::Ssn],
        "a value in text at exactly the limit is found, and the text is not oversize"
    );
}

// ---------------------------------------------------------------------------
// The scan binary survives non-ASCII digits
// ---------------------------------------------------------------------------

#[test]
fn scan_binary_survives_a_fullwidth_ssn_line_and_keeps_reporting_later_lines() {
    let input = format!(
        "ssn {}\n- [ ] PORTAL-1F2 retry failed queue jobs on facility 8812\nSSN 219-09-9999\n",
        map_digits("219-09-9999", 0xFF10)
    );
    let mut child = Command::new(env!("CARGO_BIN_EXE_sensitive-text-scan"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn sensitive-text-scan");
    let mut stdin = child.stdin.take().expect("stdin pipe");
    let data = input.into_bytes();
    let writer = std::thread::spawn(move || {
        let _ = stdin.write_all(&data);
    });
    let out = child.wait_with_output().expect("wait for the binary");
    writer.join().expect("stdin writer thread");

    assert_eq!(
        out.status.code(),
        Some(0),
        "the binary must exit 0, not panic (101): {:?}",
        out.status
    );
    assert_eq!(String::from_utf8_lossy(&out.stdout), "1\tssn\n3\tssn\n");
    assert!(
        out.stderr.is_empty(),
        "stderr must be empty, it was {} bytes",
        out.stderr.len()
    );
}

// ---------------------------------------------------------------------------
// Review round 2: mixed hidden characters, combining marks, URL userinfo
// ---------------------------------------------------------------------------

#[test]
fn hidden_characters_both_inside_a_value_and_as_its_separator_are_still_detected() {
    let zw = '\u{200B}';
    assert_flags(
        Class::Ssn,
        &[
            format!("SSN{zw}219-{zw}09-9999"),
            format!("SSN{zw}2{zw}19-09-9999"),
            format!("ssn:{zw}219{zw}-09-9999"),
        ],
    );
    assert_flags(Class::Dob, &[format!("D{zw}OB{zw}03/{zw}14/1941")]);
    assert_flags(Class::Phone, &[format!("call{zw}312-{zw}555-0142")]);
    assert_flags(Class::Card, &[format!("card{zw}4111{zw}1111 1111 1111")]);
}

#[test]
fn combining_marks_stacked_on_digits_and_letters_do_not_defeat_detection() {
    let mark = '\u{0301}';
    assert_flags(
        Class::Ssn,
        &[
            format!("SSN 2{mark}19-09-9999"),
            format!("SSN 219-0{mark}9-9999{mark}"),
        ],
    );
    assert_flags(Class::Secret, &[format!("A{mark}KIA{}", up_alnum(16))]);
    assert_flags(Class::Phone, &[format!("call 312-555-014{mark}2")]);
    let text = format!("SSN 2{mark}19-09-9999");
    let found = findings(&text);
    assert_well_formed(&text, &found);
}

#[test]
fn a_bare_url_prefix_does_not_exempt_an_address() {
    assert_flags(
        Class::PersonalEmail,
        &[
            "://dorothy.hale@gmail.com",
            "see ://dorothy.hale@gmail.com",
            "1x://dorothy.hale@gmail.com",
        ],
    );
    assert_not_flags(
        Class::PersonalEmail,
        &[
            "ssh://deploy@host.example.com/x",
            "https://deploy@host.example.com",
            "ssh://deploy@host.example.com:22",
        ],
    );
}
