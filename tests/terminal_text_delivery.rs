//! Adversarial behaviour tests for `deliver` end to end (review fix-ups T3F-3,
//! T3F-5 and T3F-6): terminal bytes in, agent text out, with redaction and
//! truncation in the real order.
//!
//! What each section guards:
//!
//! * truncation never exposes a secret, whichever way the cap cuts the text
//!   (a cut token must not leave a stub such as `ghp_BCDF`);
//! * only whole lines are delivered, so a secret split across `feed` calls is
//!   redacted once its line commits;
//! * a private-key block collapses to one marker line, even across deliveries,
//!   and an unterminated one cannot swallow the stream forever;
//! * redaction time grows linearly with input, including on hostile text;
//! * a deterministic fuzz plants secrets in byte soup and splits the feed at
//!   every byte offset.
//!
//! Secrets are built at runtime from fragments. Every secret body is made of
//! upper-case consonants only, so "is any secret left in the text?" is one
//! linear scan: a run of five of them cannot come from anything else the
//! pipeline writes (markers are lower case, the fixtures use lower-case
//! filler).
//!
//! The assembler never keeps a line wider than `MAX_LINE_COLUMNS` characters,
//! so a single delivered line is at most 16 KiB and only reaches the byte cap
//! with 4-byte characters. The clip tests therefore pad lines with emoji.

use std::time::{Duration, Instant};

use nostromo::terminal::follow::{
    deliver, Decision, Delivery, DeliveryPolicy, LineAssembler, PauseReason, MAX_LINE_COLUMNS,
};
use nostromo::terminal::redact::{RedactionKind, Redactor, MAX_UNTERMINATED_KEY_BYTES};

const CAP_BYTES: usize = DeliveryPolicy::CAP_BYTES;
const CONSONANTS: &str = "BCDFGHJKLMNPQRSTVWXZ";
const MIXED: &str = "AbCdEfGhJkLmNpQrStUvWxYz23456789";
const UPPER_DIGITS: &str = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

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

    fn below(&mut self, n: usize) -> usize {
        (self.step() % n as u64) as usize
    }
}

fn gen(seed: u64, alphabet: &str, n: usize) -> String {
    let chars: Vec<char> = alphabet.chars().collect();
    let mut rng = Rng::new(seed);
    (0..n).map(|_| chars[rng.below(chars.len())]).collect()
}

/// One delivered result, unpacked. A withheld delivery fails the test: none of
/// these inputs may make redaction fail.
#[derive(Debug)]
struct Out {
    text: String,
    lines_total: usize,
    omitted: usize,
    redactions: Vec<RedactionKind>,
}

struct Rig {
    assembler: LineAssembler,
    redactor: Redactor,
    policy: DeliveryPolicy,
}

impl Rig {
    fn new() -> Self {
        Self {
            assembler: LineAssembler::new(),
            redactor: Redactor::new(),
            policy: DeliveryPolicy::new(),
        }
    }

    fn feed(&mut self, bytes: &[u8]) {
        self.assembler.feed(bytes);
    }

    fn feed_lines<S: AsRef<str>>(&mut self, lines: &[S]) {
        for line in lines {
            self.assembler.feed(line.as_ref().as_bytes());
            self.assembler.feed(b"\n");
        }
    }

    fn deliver(&mut self) -> Out {
        match deliver(&mut self.assembler, &mut self.redactor, &mut self.policy) {
            Delivery::Text {
                text,
                lines_total,
                omitted,
                redactions,
            } => Out {
                text,
                lines_total,
                omitted,
                redactions,
            },
            Delivery::Withheld => panic!("delivery was withheld: redaction failed"),
        }
    }
}

/// A fresh rig, `lines` fed, one delivery.
fn deliver_lines<S: AsRef<str>>(lines: &[S]) -> Out {
    let mut rig = Rig::new();
    rig.feed_lines(lines);
    rig.deliver()
}

/// A secret to plant: the text to place, the body characters that must not
/// survive, and a prefix that must not survive either.
struct Planted {
    name: &'static str,
    text: String,
    prefix: Option<&'static str>,
}

const PLANTED_KINDS: usize = 8;

fn planted(kind: usize, seed: u64) -> Planted {
    let body = |n: usize, salt: u64| gen(seed.wrapping_mul(31).wrapping_add(salt), CONSONANTS, n);
    let j = |n: usize, salt: u64| format!("J{}", body(n, salt));
    match kind {
        0 => Planted {
            name: "github token",
            text: ["gh", "p_"].concat() + &body(36, 1),
            prefix: Some("ghp_"),
        },
        1 => Planted {
            name: "aws access key id",
            text: ["AK", "IA"].concat() + &body(16, 2),
            prefix: Some("AKIA"),
        },
        2 => Planted {
            name: "sk- key",
            text: ["sk", "-"].concat() + &body(40, 3),
            prefix: Some("sk-"),
        },
        3 => Planted {
            name: "jwt",
            text: format!("ey{}.ey{}.{}", j(12, 4), j(20, 5), body(30, 6)),
            prefix: Some("eyJ"),
        },
        4 => Planted {
            name: "password assignment",
            text: format!("DB_PASSWORD={}", body(12, 7)),
            prefix: None,
        },
        5 => Planted {
            name: "url password with @",
            text: format!(
                "postgres://app:{}@{}@db.internal/main",
                body(6, 8),
                body(6, 9)
            ),
            prefix: None,
        },
        6 => Planted {
            name: "bare bearer",
            text: format!("Bearer {}", body(24, 10)),
            prefix: None,
        },
        _ => Planted {
            name: "basic authorization",
            text: format!("Authorization: Basic {}==", body(20, 11)),
            prefix: None,
        },
    }
}

/// A leftover of a planted secret in `text`: a run of five upper-case
/// consonants (every secret body is made of them), or a surviving prefix.
fn leaked(text: &str, planted: Option<&Planted>) -> Option<String> {
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
    let prefix = planted?.prefix?;
    text.contains(prefix)
        .then(|| format!("secret prefix {prefix:?}"))
}

fn assert_clean(text: &str, planted: Option<&Planted>, context: &str) {
    if let Some(found) = leaked(text, planted) {
        let shown: String = text.chars().take(300).collect();
        panic!("{context}: {found} in the delivered text (first 300 chars: {shown:?})");
    }
    assert!(
        text.len() <= CAP_BYTES,
        "{context}: {} bytes delivered, cap is {CAP_BYTES}",
        text.len()
    );
    assert!(!text.contains('\x1b'), "{context}: ESC byte delivered");
}

fn marker_lines(text: &str) -> usize {
    text.split('\n')
        .filter(|l| *l == "[redacted: private-key]")
        .count()
}

// ───────────────────────────── T3F-3: caps never expose a secret ─────────────

/// A line of whole `tokens` separated by single spaces, at most `columns`
/// characters wide. Whole tokens only: a half token at the end would be a
/// stub no pattern could be asked to redact.
fn dense_line(kind: usize, seed: u64, columns: usize) -> String {
    let mut line = String::new();
    let mut j = 0;
    loop {
        let token = planted(kind, seed * 1000 + j).text;
        if line.chars().count() + token.chars().count() + 1 > columns {
            return line;
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(&token);
        j += 1;
    }
}

/// `emoji` four-byte characters, then dense tokens up to the column limit.
fn emoji_then_tokens(emoji: usize, kind: usize, seed: u64) -> String {
    let lead = "\u{1F600}".repeat(emoji);
    format!(
        "{lead}{}",
        dense_line(kind, seed, MAX_LINE_COLUMNS - emoji - 1)
    )
}

#[test]
fn a_byte_cap_clip_never_leaves_part_of_a_dense_run_of_secrets_readable() {
    // Two lines that each exceed their share of the byte budget, so each is
    // clipped. The emoji lead moves the clip points into the token zone; the
    // sweep covers the head clip (about a third of the cap) and the tail clip
    // (the rest of it) at many alignments.
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 0);
        for emoji in (440..=2740).step_by(40) {
            let first = emoji_then_tokens(emoji, kind, 1);
            let second = emoji_then_tokens(emoji, kind, 2);
            let out = deliver_lines(&[first, second]);
            let context = format!("{} / two lines / {emoji} emoji", who.name);
            assert_clean(&out.text, Some(&who), &context);
            assert!(!out.redactions.is_empty(), "{context}: nothing redacted");
        }
    }
}

#[test]
fn a_secret_straddling_the_head_clip_leaves_no_stub() {
    // One secret placed after the emoji so a clip of the first line lands
    // 0..40 bytes into it: with redaction after truncation this leaves
    // `ghp_BCDF`-style stubs, with redaction first it leaves a marker.
    let filler: Vec<String> = (0..4).map(|_| "y".repeat(MAX_LINE_COLUMNS)).collect();
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 7);
        for emoji in (1336..=1362).step_by(2) {
            for pad in 0..4 {
                let first = format!(
                    "{}{} {} end",
                    "\u{1F600}".repeat(emoji),
                    "x".repeat(pad),
                    who.text
                );
                let mut lines = vec![first];
                lines.extend(filler.iter().cloned());
                let out = deliver_lines(&lines);
                let context = format!("{} / head clip / {emoji} emoji + {pad}", who.name);
                assert_clean(&out.text, Some(&who), &context);
            }
        }
    }
}

#[test]
fn a_secret_straddling_the_tail_clip_leaves_no_stub() {
    let filler: Vec<String> = (0..4).map(|_| "y".repeat(MAX_LINE_COLUMNS)).collect();
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 8);
        for emoji in (2696..=2728).step_by(2) {
            for pad in 0..4 {
                let last = format!(
                    "{}{} {} end",
                    "\u{1F600}".repeat(emoji),
                    "x".repeat(pad),
                    who.text
                );
                let mut lines = filler.clone();
                lines.push(last);
                let out = deliver_lines(&lines);
                let context = format!("{} / tail clip / {emoji} emoji + {pad}", who.name);
                assert_clean(&out.text, Some(&who), &context);
            }
        }
    }
}

#[test]
fn many_lines_with_a_secret_on_every_line_deliver_none_of_them() {
    // 300 lines (over the line cap and, at about 150 bytes each, over the byte
    // cap): the head, the marker and the tail must all be clean.
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 0);
        let lines: Vec<String> = (0..300)
            .map(|i| {
                format!(
                    "line {i:03} {} {}",
                    "p".repeat(100),
                    planted(kind, 50 + i as u64).text
                )
            })
            .collect();
        let out = deliver_lines(&lines);
        assert_clean(&out.text, Some(&who), who.name);
        assert_eq!(out.lines_total, 300, "{}", who.name);
        assert!(out.omitted > 0, "{}: nothing was cut", who.name);
        let marker = format!("[\u{2026} {} lines omitted \u{2026}]", out.omitted);
        assert!(
            out.text.split('\n').any(|l| l == marker),
            "{}: no omitted-lines marker for {} in {:?}",
            who.name,
            out.omitted,
            out.text.lines().take(3).collect::<Vec<_>>()
        );
        let kept = out.text.split('\n').count() - 1;
        assert_eq!(
            kept,
            300 - out.omitted,
            "{}: omitted count is off",
            who.name
        );
    }
}

#[test]
fn a_secret_on_the_first_and_last_lines_of_the_head_and_tail_is_redacted() {
    // 1000 plain lines with the secret on the lines at the head/tail edges
    // (49, 50, 899, 900 and the very last line).
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 3);
        let mut lines: Vec<String> = (0..1000).map(|i| format!("line {i}")).collect();
        for at in [0usize, 49, 50, 899, 900, 999] {
            lines[at] = format!("line {at} {}", who.text);
        }
        let out = deliver_lines(&lines);
        assert_clean(&out.text, Some(&who), who.name);
        assert!(
            out.text.contains("line 0 "),
            "{}: first line lost",
            who.name
        );
        assert!(
            out.text.contains("line 999 "),
            "{}: last line lost",
            who.name
        );
        assert!(out.text.contains("[redacted: "), "{}", who.name);
    }
}

// ───────────────────────────── caps behave ───────────────────────────────────

#[test]
fn a_thousand_lines_keep_the_first_fifty_and_last_hundred_around_a_marker() {
    let lines: Vec<String> = (0..1000).map(|i| format!("line {i}")).collect();
    let out = deliver_lines(&lines);
    assert_eq!(out.lines_total, 1000);
    assert_eq!(out.omitted, 850);
    let shown: Vec<&str> = out.text.split('\n').collect();
    assert_eq!(shown.len(), 151);
    assert_eq!(shown[0], "line 0");
    assert_eq!(shown[49], "line 49");
    assert_eq!(shown[50], "[\u{2026} 850 lines omitted \u{2026}]");
    assert_eq!(shown[51], "line 900");
    assert_eq!(shown[150], "line 999");
}

#[test]
fn exactly_the_line_cap_passes_through_and_one_more_line_is_cut() {
    let lines: Vec<String> = (0..DeliveryPolicy::CAP_LINES)
        .map(|i| format!("line {i}"))
        .collect();
    let out = deliver_lines(&lines);
    assert_eq!(out.omitted, 0);
    assert_eq!(out.text, lines.join("\n"));

    let mut more = lines;
    more.push("one more".into());
    let out = deliver_lines(&more);
    assert_eq!(out.lines_total, DeliveryPolicy::CAP_LINES + 1);
    assert_eq!(
        out.omitted,
        DeliveryPolicy::CAP_LINES + 1 - DeliveryPolicy::HEAD - DeliveryPolicy::TAIL
    );
    assert!(out.text.len() <= CAP_BYTES);
}

#[test]
fn exactly_the_byte_cap_passes_through_and_one_more_byte_is_cut() {
    // Four lines joined by three newlines: 3 * 4096 + 4093 + 3 = 16384.
    let exact = ["a", "b", "c", "d"].map(|c| c.repeat(MAX_LINE_COLUMNS));
    let mut lines = exact.to_vec();
    lines[3] = "d".repeat(MAX_LINE_COLUMNS - 3);
    let out = deliver_lines(&lines);
    assert_eq!(out.text.len(), CAP_BYTES);
    assert_eq!(out.omitted, 0, "text of exactly the cap must pass through");

    lines[3] = "d".repeat(MAX_LINE_COLUMNS - 2);
    let out = deliver_lines(&lines);
    assert!(out.text.len() <= CAP_BYTES, "{} bytes", out.text.len());
}

#[test]
fn long_lines_stay_under_the_byte_cap_whatever_the_mix() {
    let mut rng = Rng::new(99);
    for round in 0..40 {
        let count = 1 + rng.below(60);
        let lines: Vec<String> = (0..count)
            .map(|i| {
                let width = 1 + rng.below(MAX_LINE_COLUMNS);
                let ch = ["x", "\u{e9}", "\u{4f60}", "\u{1F600}"][rng.below(4)];
                format!("{i}:{}", ch.repeat(width))
            })
            .collect();
        let out = deliver_lines(&lines);
        assert!(
            out.text.len() <= CAP_BYTES,
            "round {round}: {} bytes for {count} lines",
            out.text.len()
        );
        assert_eq!(out.lines_total, count);
        assert!(out.omitted < count.max(1));
    }
}

#[test]
fn nothing_to_deliver_is_an_empty_text() {
    let mut rig = Rig::new();
    let out = rig.deliver();
    assert_eq!(out.text, "");
    assert_eq!(out.lines_total, 0);
    assert_eq!(out.omitted, 0);
    assert!(out.redactions.is_empty());
}

// ───────────────────────────── policy reporting ──────────────────────────────

fn numbered(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("line {i}")).collect()
}

#[test]
fn three_capped_deliveries_in_a_row_pause_following() {
    let mut rig = Rig::new();
    for _ in 0..3 {
        rig.feed_lines(&numbered(300));
        assert!(rig.deliver().omitted > 0);
    }
    let decision = rig.policy.on_tick(Instant::now(), None, false);
    assert_eq!(
        decision,
        Decision::Pause {
            reason: PauseReason::TooMuchOutput
        }
    );
}

#[test]
fn an_uncapped_delivery_in_between_prevents_the_pause() {
    let mut rig = Rig::new();
    for lines in [numbered(300), numbered(300), numbered(3), numbered(300)] {
        rig.feed_lines(&lines);
        rig.deliver();
    }
    let decision = rig.policy.on_tick(Instant::now(), None, false);
    assert!(
        !matches!(decision, Decision::Pause { .. }),
        "paused after capped, capped, uncapped, capped: {decision:?}"
    );
}

// ───────────────────────────── whole lines only ──────────────────────────────

#[test]
fn bytes_without_a_trailing_newline_are_held_back_until_the_line_commits() {
    let mut rig = Rig::new();
    rig.feed(b"line one\nwork in progress");
    let first = rig.deliver();
    assert_eq!(first.text, "line one");
    assert_eq!(
        rig.assembler.current_partial(),
        Some("work in progress"),
        "the live cursor row must stay in the assembler"
    );
    rig.feed(b" and more\n");
    assert_eq!(rig.deliver().text, "work in progress and more");
}

#[test]
fn a_lone_unfinished_secret_line_delivers_nothing_at_all() {
    let mut rig = Rig::new();
    rig.feed(b"DB_PASSWORD=BCDFGHJKLMNP");
    let out = rig.deliver();
    assert_eq!(out.text, "");
    assert_eq!(out.lines_total, 0);
    rig.feed(b"\n");
    let out = rig.deliver();
    assert_clean(&out.text, None, "committed line");
    assert_eq!(out.text, "DB_PASSWORD=[redacted: secret-assignment]");
}

#[test]
fn a_secret_split_across_two_feeds_is_redacted_when_its_line_commits() {
    for kind in 0..PLANTED_KINDS {
        let who = planted(kind, 21);
        let line = format!("ordinary words {} trailing words", who.text);
        let bytes = line.as_bytes();
        for split in 0..=bytes.len() {
            let mut rig = Rig::new();
            rig.feed(&bytes[..split]);
            let early = rig.deliver();
            rig.feed(&bytes[split..]);
            rig.feed(b"\n");
            let late = rig.deliver();
            let context = format!("{} split at {split}", who.name);
            assert_eq!(early.text, "", "{context}: a live row was delivered");
            assert_clean(&late.text, Some(&who), &context);
            // Not asserted: the words after the secret. A Basic header's
            // credentials run to the end of the line, which over-redacts.
            assert!(
                late.text.starts_with("ordinary words "),
                "{context}: context lost: {:?}",
                late.text
            );
            assert!(late.text.contains("[redacted: "), "{context}");
        }
    }
}

// ───────────────────────────── private keys ──────────────────────────────────

fn key_lines(label: &str, seed: u64, body_lines: usize) -> (Vec<String>, Vec<String>) {
    let body: Vec<String> = (0..body_lines)
        .map(|i| gen(seed + i as u64, MIXED, 64))
        .collect();
    let mut lines = vec![format!("-----BEGIN {label}-----")];
    lines.extend(body.iter().cloned());
    lines.push(format!("-----END {label}-----"));
    (lines, body)
}

#[test]
fn a_private_key_inside_one_delivery_becomes_a_single_marker_line() {
    let (key, body) = key_lines("RSA PRIVATE KEY", 1000, 6);
    let mut lines = vec!["before".to_string()];
    lines.extend(key);
    lines.push("after".to_string());
    let out = deliver_lines(&lines);
    assert_eq!(out.text, "before\n[redacted: private-key]\nafter");
    assert_eq!(out.lines_total, 3);
    assert_eq!(out.redactions, [RedactionKind::PrivateKey]);
    for line in body {
        assert!(!out.text.contains(&line[..16]));
    }
}

#[test]
fn a_private_key_spanning_two_deliveries_stays_collapsed_in_both() {
    let (key, body) = key_lines("OPENSSH PRIVATE KEY", 2000, 8);
    let (first_half, second_half) = key.split_at(5);

    let mut rig = Rig::new();
    rig.feed_lines(&["before the key".to_string()]);
    rig.feed_lines(first_half);
    let first = rig.deliver();
    assert_eq!(first.text, "before the key\n[redacted: private-key]");

    rig.feed_lines(second_half);
    rig.feed_lines(&["after the key".to_string()]);
    let second = rig.deliver();
    assert!(
        marker_lines(&second.text) <= 1,
        "the continued block is more than one line: {:?}",
        second.text
    );
    assert_eq!(second.text.split('\n').next_back(), Some("after the key"));

    for line in &body {
        for text in [&first.text, &second.text] {
            assert!(!text.contains(&line[..16]), "key body readable");
        }
    }
    // The key's END is behind us: ordinary text is no longer swallowed.
    rig.feed_lines(&["ordinary again".to_string()]);
    assert_eq!(rig.deliver().text, "ordinary again");
}

#[test]
fn a_key_split_mid_body_across_many_deliveries_never_leaks_a_body_line() {
    let (key, body) = key_lines("EC PRIVATE KEY", 3000, 30);
    let mut rig = Rig::new();
    let mut texts = Vec::new();
    for chunk in key.chunks(4) {
        rig.feed_lines(chunk);
        texts.push(rig.deliver().text);
    }
    rig.feed_lines(&["done".to_string()]);
    texts.push(rig.deliver().text);
    let all = texts.join("\n");
    for line in &body {
        assert!(!all.contains(&line[..16]), "key body readable");
    }
    assert!(all.ends_with("done"));
}

#[test]
fn an_unterminated_private_key_header_does_not_swallow_output_forever() {
    const BODY_LINE: usize = 64;
    // Enough body that the unterminated block has to outrun its bound.
    let body_lines = MAX_UNTERMINATED_KEY_BYTES * 5 / 4 / (BODY_LINE + 1);
    let body: Vec<String> = (0..body_lines)
        .map(|i| gen(5000 + i as u64, MIXED, BODY_LINE))
        .collect();

    let mut rig = Rig::new();
    let mut texts = Vec::new();
    rig.feed_lines(&["ordinary text before the key".to_string()]);
    rig.feed_lines(&["-----BEGIN RSA PRIVATE KEY-----".to_string()]);
    texts.push(rig.deliver().text);
    for chunk in body.chunks(50) {
        rig.feed_lines(chunk);
        texts.push(rig.deliver().text);
    }
    let resumed: Vec<String> = (0..3).map(|i| format!("resumed output line {i}")).collect();
    rig.feed_lines(&resumed);
    texts.push(rig.deliver().text);

    let all = texts.join("\n");
    assert!(all.contains("ordinary text before the key"));
    for line in &resumed {
        assert!(
            all.contains(line.as_str()),
            "output never resumed: {line:?} missing"
        );
    }
    assert!(all.contains("[redacted: private-key"), "no marker shown");
    // Body within the bound is never shown (past the bound the block is no
    // longer treated as a key, by design).
    let protected = MAX_UNTERMINATED_KEY_BYTES * 6 / 10 / (BODY_LINE + 1);
    for line in &body[..protected] {
        assert!(!all.contains(&line[..16]), "key body readable");
    }
}

#[test]
fn a_key_longer_than_a_few_kib_but_under_the_bound_is_fully_swallowed() {
    let (key, body) = key_lines("RSA PRIVATE KEY", 6000, 200);
    let mut lines = vec!["before".to_string()];
    lines.extend(key);
    lines.push("after".to_string());
    let out = deliver_lines(&lines);
    assert_eq!(out.text, "before\n[redacted: private-key]\nafter");
    for line in body {
        assert!(!out.text.contains(&line[..16]));
    }
}

// ───────────────────────────── T3F-5b: performance ───────────────────────────

fn time(f: impl FnOnce()) -> Duration {
    let start = Instant::now();
    f();
    start.elapsed()
}

fn aws_key_lines(n: usize) -> String {
    let mut text = String::with_capacity(n * 64);
    for i in 0..n {
        let id = ["AK", "IA"].concat() + &gen(i as u64, UPPER_DIGITS, 16);
        text.push_str(&format!("{i:06} build log entry key={id} done\n"));
    }
    text
}

#[test]
fn redacting_100k_aws_key_lines_is_fast_and_scales_linearly() {
    let small = aws_key_lines(10_000);
    let large = aws_key_lines(100_000);

    let mut small_kinds = 0;
    let t_small = time(|| {
        let (out, kinds) = Redactor::new().redact(&small);
        assert!(!out.contains("AKIA"), "a key survived");
        small_kinds = kinds.len();
    });
    let mut large_kinds = 0;
    let t_large = time(|| {
        let (out, kinds) = Redactor::new().redact(&large);
        assert!(!out.contains("AKIA"), "a key survived");
        large_kinds = kinds.len();
    });
    eprintln!("redact 10k lines: {t_small:?}, 100k lines: {t_large:?}");
    assert_eq!(small_kinds, 10_000);
    assert_eq!(large_kinds, 100_000);
    // Debug build: generous. A quadratic redactor needs minutes here.
    assert!(
        t_large < Duration::from_secs(30),
        "100k lines took {t_large:?}"
    );
    let floor = t_small.max(Duration::from_millis(20)).as_secs_f64();
    let ratio = t_large.as_secs_f64() / floor;
    assert!(
        ratio < 30.0,
        "10x the input took {ratio:.1}x the time ({t_small:?} -> {t_large:?})"
    );
}

/// Patterns that make a regex-based redactor retry or rescan: each repeated to
/// fill a 4096-column line.
const HOSTILE_PATTERNS: &[&str] = &[
    "ask-",
    "xglpat-",
    "xsk-ant-",
    "xxoxb-",
    "xnpm_",
    "xwhsec_",
    "AKIA",
    "ghp_",
    "eyJabcde.",
    "dob ",
    "password: ",
    "token=",
    "Authorization: ",
    "Bearer ",
    "https://u:",
    "-----BEGIN ",
    "curl ",
    "mysql -p ",
    "pass ",
    "123-45-6789-",
];

fn filled(pattern: &str, columns: usize) -> String {
    pattern.repeat(columns / pattern.len() + 1)[..columns].to_string()
}

fn deliver_time(lines: &[String]) -> Duration {
    time(|| {
        let out = deliver_lines(lines);
        assert!(out.text.len() <= CAP_BYTES);
    })
}

#[test]
fn hostile_lines_cost_about_the_same_as_ordinary_lines_of_the_same_size() {
    // 128 lines of 4096 columns is 512 KiB, which the assembler can hold. A
    // redactor that retries from every position of such a line does thousands
    // of times the work per byte.
    let rows = 128;
    let benign: Vec<String> = (0..rows)
        .map(|i| {
            filled(
                &format!("ordinary output line {i} with nothing to hide "),
                4096,
            )
        })
        .collect();
    let baseline = deliver_time(&benign).max(Duration::from_millis(100));
    let mut slow = Vec::new();
    for pattern in HOSTILE_PATTERNS {
        let hostile: Vec<String> = (0..rows).map(|_| filled(pattern, 4096)).collect();
        let took = deliver_time(&hostile);
        eprintln!("hostile {pattern:?}: {took:?} (baseline {baseline:?})");
        if took > baseline * 20 {
            slow.push(format!("{pattern:?}: {took:?} vs ordinary {baseline:?}"));
        }
    }
    assert!(
        slow.is_empty(),
        "hostile text is disproportionately slow to redact:\n{}",
        slow.join("\n")
    );
}

#[test]
fn a_single_huge_hostile_line_does_not_make_redaction_quadratic() {
    // Redactor::redact takes any text; do not rely on the assembler's width cap.
    let columns = 32 * 1024;
    let benign = filled("ordinary output with nothing to hide ", columns);
    let baseline = time(|| {
        Redactor::new().redact(&benign);
    })
    .max(Duration::from_millis(50));
    let mut slow = Vec::new();
    for pattern in HOSTILE_PATTERNS {
        let hostile = filled(pattern, columns);
        let took = time(|| {
            Redactor::new().redact(&hostile);
        });
        eprintln!("huge hostile {pattern:?}: {took:?} (baseline {baseline:?})");
        if took > baseline * 20 {
            slow.push(format!("{pattern:?}: {took:?} vs ordinary {baseline:?}"));
        }
    }
    assert!(
        slow.is_empty(),
        "a 32 KiB line of one repeated shape is disproportionately slow:\n{}",
        slow.join("\n")
    );
}

// ───────────────────────────── T3F-5c: fuzz ──────────────────────────────────

const ESCAPES: &[&str] = &[
    "\x1b[31m",
    "\x1b[0m",
    "\x1b[2K",
    "\x1b[K",
    "\x1b[1K",
    "\x1b[3C",
    "\x1b[2D",
    "\x1b[5G",
    "\x1b[2P",
    "\x1b]0;title\x07",
    "\x1b]8;;http://example.com\x1b\\",
    "\x1bP1$r\x1b\\",
    "\x1b(B",
    "\x1b[?25l",
    "\x1b[;5H",
    "\x1b[99999999999999999999C",
    "\x1b[",
    "\x1b",
    "\x1b]0;never ends",
    "\x1bM",
];

/// One line of byte soup: printable text (no upper-case letters, so no secret
/// body run can form by chance), control bytes, escape sequences (never
/// cursor-up or down, which would let soup overwrite the planted row), invalid
/// UTF-8 and valid multi-byte text. Never `\n`, and never the byte 0xC2 (which
/// could form a C1 escape introducer).
fn soup_line(rng: &mut Rng) -> Vec<u8> {
    let target = 5 + rng.below(60);
    let mut out = Vec::new();
    while out.len() < target {
        match rng.below(10) {
            0..=4 | 9 => {
                let b = 0x20 + rng.below(0x5f) as u8;
                // No `-`, so soup cannot spell the `sk-` prefix by chance.
                out.push(if b == b'-' {
                    b'+'
                } else {
                    b.to_ascii_lowercase()
                });
            }
            5 => {
                const CONTROL: &[u8] = &[
                    0x00, 0x01, 0x07, 0x08, 0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x1a, 0x1c, 0x1f, 0x7f,
                ];
                out.push(CONTROL[rng.below(CONTROL.len())]);
            }
            6 => out.extend_from_slice(ESCAPES[rng.below(ESCAPES.len())].as_bytes()),
            7 => {
                const INVALID: &[u8] = &[0x80, 0x9b, 0xbf, 0xc0, 0xc1, 0xe2, 0xf0, 0xf5, 0xff];
                out.push(INVALID[rng.below(INVALID.len())]);
            }
            _ => {
                let text = ["\u{e9}", "\u{4f60}", "\u{1F600}", "\u{200d}"][rng.below(4)];
                out.extend_from_slice(text.as_bytes());
            }
        }
    }
    out
}

fn soup(rng: &mut Rng) -> Vec<u8> {
    let mut out = Vec::new();
    for _ in 0..1 + rng.below(4) {
        out.extend(soup_line(rng));
        out.push(b'\n');
    }
    out
}

struct FuzzCase {
    prefix: Vec<u8>,
    planted_line: Vec<u8>,
    suffix: Vec<u8>,
    who: Planted,
}

fn fuzz_case(seed: u64) -> FuzzCase {
    let mut rng = Rng::new(seed);
    let who = planted((seed as usize) % PLANTED_KINDS, seed);
    let mut planted_line = who.text.clone().into_bytes();
    planted_line.push(b'\n');
    FuzzCase {
        prefix: soup(&mut rng),
        planted_line,
        suffix: soup(&mut rng),
        who,
    }
}

fn check_texts(texts: &[Out], case: &FuzzCase, context: &str) {
    let mut combined = String::new();
    for out in texts {
        assert_clean(&out.text, Some(&case.who), context);
        combined.push_str(&out.text);
        combined.push('\n');
    }
    assert!(
        combined.contains("[redacted: "),
        "{context}: the planted {} was neither delivered redacted nor swallowed by a marker",
        case.who.name
    );
}

#[test]
fn fuzz_planted_secrets_never_survive_a_two_chunk_split_at_any_offset() {
    let mut iterations = 0;
    for seed in 0..56u64 {
        let case = fuzz_case(seed);
        for split in 0..=case.planted_line.len() {
            let mut first = case.prefix.clone();
            first.extend_from_slice(&case.planted_line[..split]);
            let mut second = case.planted_line[split..].to_vec();
            second.extend_from_slice(&case.suffix);
            let context = format!("seed {seed} ({}) split {split}", case.who.name);

            // Delivering between the chunks, as the live driver does.
            let mut rig = Rig::new();
            rig.feed(&first);
            let a = rig.deliver();
            rig.feed(&second);
            let b = rig.deliver();
            check_texts(&[a, b], &case, &context);

            // Both chunks, one delivery.
            let mut rig = Rig::new();
            rig.feed(&first);
            rig.feed(&second);
            check_texts(&[rig.deliver()], &case, &context);
            iterations += 1;
        }
    }
    assert!(iterations >= 300, "only {iterations} iterations ran");
}

#[test]
fn fuzz_planted_secrets_never_survive_one_byte_at_a_time_feeding() {
    for seed in 100..124u64 {
        let case = fuzz_case(seed);
        let mut input = case.prefix.clone();
        input.extend_from_slice(&case.planted_line);
        input.extend_from_slice(&case.suffix);
        let context = format!("seed {seed} ({}) bytewise", case.who.name);

        let mut rig = Rig::new();
        let mut texts = Vec::new();
        for byte in &input {
            rig.feed(std::slice::from_ref(byte));
            texts.push(rig.deliver());
        }
        check_texts(&texts, &case, &context);
    }
}

#[test]
fn fuzz_pure_soup_never_panics_leaks_escapes_or_exceeds_the_cap() {
    for seed in 1000..1060u64 {
        let mut rng = Rng::new(seed);
        let mut rig = Rig::new();
        let mut total = 0;
        for _ in 0..40 {
            let chunk = soup(&mut rng);
            total += chunk.len();
            rig.feed(&chunk);
            let out = rig.deliver();
            assert_clean(&out.text, None, &format!("seed {seed}"));
        }
        assert!(total > 0);
    }
}
