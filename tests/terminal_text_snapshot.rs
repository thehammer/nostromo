//! Behaviour tests for `deliver_snapshot`: the public, redacted way to hand an
//! agent what a full-screen program shows.
//!
//! `screen_snapshot` returns raw screen text. `deliver_snapshot` is the path
//! that is safe to give to an agent: it takes the snapshot, splits it into
//! lines, redacts, then caps, and reports to the `DeliveryPolicy` exactly like
//! `deliver` does. A snapshot is self-contained: nothing one snapshot opens (a
//! private-key block cut off at the bottom of the screen) may swallow the next.
//!
//! Secrets are built at runtime from fragments, and every secret body is made
//! of upper-case consonants only, so "is any of it left?" is one linear scan
//! (see `terminal_text_delivery.rs`).

use std::time::Instant;

use nostromo::terminal::follow::{
    deliver_snapshot, screen_snapshot, Decision, Delivery, DeliveryPolicy,
};
use nostromo::terminal::redact::RedactionKind;

const CAP_BYTES: usize = DeliveryPolicy::CAP_BYTES;
const CONSONANTS: &str = "BCDFGHJKLMNPQRSTVWXZ";

// ───────────────────────────── helpers ───────────────────────────────────────

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

/// `n` upper-case consonants fixed by `seed`.
fn body(seed: u64, n: usize) -> String {
    let chars: Vec<char> = CONSONANTS.chars().collect();
    let mut rng = Rng::new(seed);
    (0..n)
        .map(|_| chars[(rng.step() % chars.len() as u64) as usize])
        .collect()
}

fn github_token(seed: u64) -> String {
    ["gh", "p_"].concat() + &body(seed, 36)
}

/// A screen of `rows` x `cols` after `bytes` were written to it.
fn parser_with(rows: u16, cols: u16, bytes: &[u8]) -> vt100::Parser {
    let mut parser = vt100::Parser::new(rows, cols, 0);
    parser.process(bytes);
    parser
}

/// `lines` as terminal output (CR LF between them, none after the last, so a
/// screen exactly as tall as `lines` does not scroll).
fn crlf(lines: &[String]) -> Vec<u8> {
    lines.join("\r\n").into_bytes()
}

/// One snapshot delivery from a screen holding `lines`, on a fresh policy.
fn snapshot_of(lines: &[String]) -> (Delivery, String) {
    let parser = parser_with((lines.len() as u16).max(24), 200, &crlf(lines));
    let raw = screen_snapshot(parser.screen());
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    (delivery, raw)
}

fn text_of(delivery: &Delivery) -> &str {
    delivery
        .text()
        .unwrap_or_else(|| panic!("the snapshot was withheld: {delivery:?}"))
}

/// A run of five consonants or a leftover token prefix.
fn leaked(text: &str) -> Option<String> {
    let mut run = String::new();
    for c in text.chars() {
        if CONSONANTS.contains(c) {
            run.push(c);
            if run.chars().count() >= 5 {
                return Some(format!("secret body fragment {run:?}"));
            }
        } else {
            run.clear();
        }
    }
    text.contains("ghp_")
        .then(|| "token prefix \"ghp_\"".to_string())
}

fn strings(lines: &[&str]) -> Vec<String> {
    lines.iter().map(|l| l.to_string()).collect()
}

fn tall_lines(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("line {i}")).collect()
}

fn is_paused(policy: &mut DeliveryPolicy) -> bool {
    matches!(
        policy.on_tick(Instant::now(), None, false),
        Decision::Pause { .. }
    )
}

// ───────────────────────────── secrets on the screen ─────────────────────────

#[test]
fn a_token_on_the_screen_never_reaches_the_agent() {
    let token = github_token(1);
    let lines = strings(&["$ env | grep GH", &format!("GREETING=hi {token} bye"), "$"]);
    let (delivery, raw) = snapshot_of(&lines);
    assert!(raw.contains(&token), "the raw snapshot does hold the token");
    let text = text_of(&delivery);
    assert_ne!(text, raw);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("[redacted: api-token]"), "{text:?}");
    assert!(text.contains("$ env | grep GH"), "{text:?}");
    let Delivery::Text { redactions, .. } = &delivery else {
        panic!("withheld");
    };
    assert_eq!(redactions, &[RedactionKind::ApiToken]);
}

#[test]
fn a_password_assignment_on_the_screen_keeps_its_name_and_loses_its_value() {
    let value = body(2, 14);
    let lines = strings(&[&format!("DB_PASSWORD={value}"), "ready"]);
    let (delivery, raw) = snapshot_of(&lines);
    let text = text_of(&delivery);
    assert_ne!(text, raw);
    assert_eq!(text, "DB_PASSWORD=[redacted: secret-assignment]\nready");
}

#[test]
fn an_ssn_on_the_screen_is_redacted() {
    let ssn = ["219", "09", "9999"].join("-");
    let lines = strings(&[&format!("Patient SSN {ssn} on file")]);
    let (delivery, raw) = snapshot_of(&lines);
    let text = text_of(&delivery);
    assert_ne!(text, raw);
    assert_eq!(text, "Patient SSN [redacted: ssn] on file");
}

#[test]
fn a_token_split_by_a_zero_width_space_on_the_screen_never_reaches_the_agent() {
    let token = github_token(3);
    let split = format!("{}\u{200b}{}", &token[..10], &token[10..]);
    let lines = strings(&[&format!("pasted: {split}")]);
    let (delivery, _) = snapshot_of(&lines);
    let text = text_of(&delivery);
    let view: String = text.chars().filter(|c| *c != '\u{200b}').collect();
    assert_eq!(leaked(&view), None, "{text:?}");
    assert!(text.contains("[redacted: "), "{text:?}");
}

#[test]
fn a_password_in_fullwidth_letters_on_the_screen_never_reaches_the_agent() {
    let value = body(4, 14);
    let lines = strings(&[&format!("ｐａｓｓｗｏｒｄ={value}")]);
    let (delivery, _) = snapshot_of(&lines);
    let text = text_of(&delivery);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("[redacted: "), "{text:?}");
}

#[test]
fn a_private_key_block_on_the_screen_collapses_to_one_marker() {
    let lines = strings(&[
        "$ cat key.pem",
        "-----BEGIN RSA PRIVATE KEY-----",
        &body(5, 60),
        &body(6, 60),
        &body(7, 60),
        "-----END RSA PRIVATE KEY-----",
        "$ echo done",
    ]);
    let (delivery, raw) = snapshot_of(&lines);
    let text = text_of(&delivery);
    assert_ne!(text, raw);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("[redacted: private-key]"), "{text:?}");
    assert!(text.starts_with("$ cat key.pem\n"), "{text:?}");
    assert!(text.ends_with("$ echo done"), "{text:?}");
}

#[test]
fn a_private_key_block_cut_off_at_the_bottom_of_the_screen_is_redacted_to_the_end() {
    let lines = strings(&[
        "$ cat key.pem",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        &body(8, 60),
        &body(9, 60),
    ]);
    let (delivery, _) = snapshot_of(&lines);
    let text = text_of(&delivery);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("[redacted: private-key"), "{text:?}");
    assert!(text.starts_with("$ cat key.pem\n"), "{text:?}");
}

#[test]
fn a_key_block_left_open_by_one_snapshot_does_not_swallow_the_next() {
    let open = strings(&["-----BEGIN RSA PRIVATE KEY-----", &body(10, 60)]);
    let first = parser_with(24, 80, &crlf(&open));
    let second = parser_with(24, 80, b"hello\r\nworld");
    let mut policy = DeliveryPolicy::new();
    let a = deliver_snapshot(first.screen(), &mut policy);
    assert!(text_of(&a).contains("[redacted: private-key"));
    let b = deliver_snapshot(second.screen(), &mut policy);
    assert_eq!(text_of(&b), "hello\nworld");
}

#[test]
fn a_screen_with_nothing_secret_is_delivered_exactly_as_the_snapshot() {
    let lines = strings(&["$ ls", "a.txt  b.txt", "", "$ vim notes.txt", "~", "~"]);
    let (delivery, raw) = snapshot_of(&lines);
    assert_eq!(text_of(&delivery), raw);
    let Delivery::Text {
        lines_total,
        omitted,
        redactions,
        ..
    } = delivery
    else {
        panic!("withheld");
    };
    assert_eq!(lines_total, 6);
    assert_eq!(omitted, 0);
    assert!(redactions.is_empty());
}

#[test]
fn an_alternate_screen_program_showing_a_secret_is_redacted_too() {
    let token = github_token(11);
    let mut bytes = b"\x1b[?1049h\x1b[H\x1b[2J".to_vec();
    bytes.extend_from_slice(format!("config.toml\r\n  api = \"{token}\"\r\n~\r\n").as_bytes());
    let parser = parser_with(24, 80, &bytes);
    assert!(parser.screen().alternate_screen());
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    let text = text_of(&delivery);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.starts_with("config.toml\n"), "{text:?}");
    assert!(text.contains("[redacted: "), "{text:?}");
}

// ───────────────────────────── caps ──────────────────────────────────────────

#[test]
fn a_tall_screen_is_capped_after_redaction_and_reports_what_it_omitted() {
    let lines = tall_lines(300);
    let (delivery, raw) = snapshot_of(&lines);
    assert!(delivery.is_capped());
    let Delivery::Text {
        text,
        lines_total,
        omitted,
        ..
    } = &delivery
    else {
        panic!("withheld");
    };
    assert_eq!(*lines_total, 300);
    assert_eq!(*omitted, 300 - DeliveryPolicy::HEAD - DeliveryPolicy::TAIL);
    assert!(text.len() < raw.len());
    assert!(text.starts_with("line 0\n"), "{text:?}");
    assert!(text.ends_with("line 299"), "{text:?}");
    assert!(
        text.contains(&format!("{omitted} lines omitted")),
        "{text:?}"
    );
}

#[test]
fn secrets_in_the_kept_head_and_tail_of_a_capped_screen_are_redacted_and_the_cut_middle_is_gone() {
    let mut lines = tall_lines(300);
    let head = github_token(12);
    let middle = github_token(13);
    let tail = github_token(14);
    lines[3] = format!("head {head}");
    lines[150] = format!("middle {middle}");
    lines[296] = format!("tail {tail}");
    let (delivery, _) = snapshot_of(&lines);
    assert!(delivery.is_capped());
    let text = text_of(&delivery);
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("head [redacted: api-token]"), "{text:?}");
    assert!(text.contains("tail [redacted: api-token]"), "{text:?}");
    assert!(!text.contains("middle"), "{text:?}");
}

#[test]
fn a_byte_capped_screen_of_dense_secrets_never_exposes_a_cut_token() {
    // 150 rows of whole tokens: few enough lines for the line cap, far more
    // bytes than the byte cap once the cap has to clip.
    let rows = 150usize;
    let lines: Vec<String> = (0..rows)
        .map(|r| {
            (0..6)
                .map(|t| github_token(1000 + (r * 10 + t) as u64))
                .collect::<Vec<_>>()
                .join(" ")
        })
        .collect();
    let parser = parser_with(rows as u16, 250, &crlf(&lines));
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    let text = text_of(&delivery);
    assert!(text.len() <= CAP_BYTES, "{} bytes", text.len());
    assert_eq!(leaked(text), None, "{text:?}");
    assert!(text.contains("[redacted: api-token]"));
}

// ───────────────────────────── blank screens ─────────────────────────────────

#[test]
fn a_blank_screen_delivers_empty_text() {
    let parser = parser_with(24, 80, b"");
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    assert_eq!(
        delivery,
        Delivery::Text {
            text: String::new(),
            lines_total: 0,
            omitted: 0,
            redactions: Vec::new(),
        }
    );
}

#[test]
fn a_screen_of_only_spaces_and_blank_rows_delivers_empty_text() {
    let parser = parser_with(24, 80, b"   \r\n\r\n      \r\n");
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    assert_eq!(delivery.text(), Some(""));
    assert!(!delivery.is_capped());
}

// ───────────────────────────── the policy is told ────────────────────────────

fn capped_screen() -> vt100::Parser {
    parser_with(300, 80, &crlf(&tall_lines(300)))
}

#[test]
fn three_capped_snapshots_in_a_row_pause_following() {
    let screen = capped_screen();
    let mut policy = DeliveryPolicy::new();
    for _ in 0..3 {
        assert!(deliver_snapshot(screen.screen(), &mut policy).is_capped());
    }
    assert!(is_paused(&mut policy));
}

#[test]
fn two_capped_snapshots_are_not_yet_a_flood() {
    let screen = capped_screen();
    let mut policy = DeliveryPolicy::new();
    for _ in 0..2 {
        deliver_snapshot(screen.screen(), &mut policy);
    }
    assert!(!is_paused(&mut policy));
}

#[test]
fn a_delivered_uncapped_snapshot_resets_the_capped_streak() {
    let screen = capped_screen();
    let small = parser_with(24, 80, b"hello");
    let mut policy = DeliveryPolicy::new();
    deliver_snapshot(screen.screen(), &mut policy);
    deliver_snapshot(screen.screen(), &mut policy);
    assert_eq!(
        deliver_snapshot(small.screen(), &mut policy).text(),
        Some("hello")
    );
    deliver_snapshot(screen.screen(), &mut policy);
    assert!(
        !is_paused(&mut policy),
        "an uncapped delivery in between must break the streak"
    );
}

#[test]
fn a_blank_snapshot_is_not_reported_to_the_policy() {
    let screen = capped_screen();
    let blank = parser_with(24, 80, b"");
    let mut policy = DeliveryPolicy::new();
    deliver_snapshot(screen.screen(), &mut policy);
    deliver_snapshot(screen.screen(), &mut policy);
    // Were the blank snapshot reported as an uncapped delivery, it would reset
    // the streak and the third capped one below would not pause.
    assert_eq!(
        deliver_snapshot(blank.screen(), &mut policy).text(),
        Some("")
    );
    deliver_snapshot(screen.screen(), &mut policy);
    assert!(is_paused(&mut policy));
}

// ───────────────────────────── wrapped rows ──────────────────────────────────

#[test]
fn a_secret_that_wraps_onto_the_next_screen_row_is_redacted_whole() {
    // 40 columns: the token runs over three rows, so the tail on the later
    // rows has no secret shape of its own.
    let token = github_token(91);
    let bearer = body(92, 100);
    let input = format!("GITHUB_TOKEN={token}\r\nAuthorization: Bearer {bearer}");
    let parser = parser_with(24, 40, input.as_bytes());
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    let text = text_of(&delivery);
    for secret in [&token[4..], &bearer[..]] {
        for window in secret.as_bytes().windows(12) {
            let window = std::str::from_utf8(window).unwrap();
            assert!(!text.contains(window), "{window} readable in {text:?}");
        }
    }
    assert!(text.contains("GITHUB_TOKEN="), "{text:?}");
}

#[test]
fn rows_that_were_not_wrapped_stay_separate_lines() {
    let parser = parser_with(24, 40, b"first\r\nsecond\r\n\r\nfourth");
    let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
    assert_eq!(text_of(&delivery), "first\nsecond\n\nfourth");
}
