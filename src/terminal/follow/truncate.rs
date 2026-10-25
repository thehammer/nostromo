//! Head-and-tail truncation of a delivery.
//!
//! Crate-private on purpose: truncation must only ever run on text that has
//! already been redacted (a cut can leave a stub of a secret that no pattern
//! recognises any more), so the only way out of this module is
//! [`deliver`](super::deliver), which redacts first.

use super::policy::DeliveryPolicy;
use crate::terminal::redact::{is_token_char, trailing_secret_stub};

/// Bytes kept back for the omitted-lines marker when the byte cap bites.
const MARKER_RESERVE: usize = 64;

/// A delivery's text after the line and byte caps.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Truncated {
    /// The text to deliver. At most [`DeliveryPolicy::CAP_BYTES`] bytes.
    pub text: String,
    /// How many lines went in.
    pub lines_total: usize,
    /// How many lines are missing from `text`; equals the `N` of the marker
    /// line, or 0 when there is no marker. A line that was kept but clipped
    /// to fit the byte cap counts as kept.
    pub omitted: usize,
}

/// Apply the delivery caps to `lines`.
///
/// Up to [`DeliveryPolicy::CAP_LINES`] lines and [`DeliveryPolicy::CAP_BYTES`]
/// bytes (lines joined by `\n`) pass through unchanged. Beyond either cap the
/// text keeps the first [`DeliveryPolicy::HEAD`] and last
/// [`DeliveryPolicy::TAIL`] lines around a marker line `[… N lines omitted …]`.
/// If that is still over the byte cap, fewer head and tail lines are kept
/// (a third of the budget for the head, the rest for the tail), and a line
/// that alone exceeds its share is clipped on a character boundary and ends
/// in `…`. The result never exceeds the byte cap.
pub(crate) fn truncate(lines: Vec<String>) -> Truncated {
    let lines_total = lines.len();
    if lines_total <= DeliveryPolicy::CAP_LINES && joined_len(&lines) <= DeliveryPolicy::CAP_BYTES {
        return Truncated {
            text: lines.join("\n"),
            lines_total,
            omitted: 0,
        };
    }

    let head = lines_total.min(DeliveryPolicy::HEAD);
    let tail = (lines_total - head).min(DeliveryPolicy::TAIL);
    let omitted = lines_total - head - tail;
    let candidate = assemble(&lines[..head], &lines[lines_total - tail..], omitted);
    if candidate.len() <= DeliveryPolicy::CAP_BYTES {
        return Truncated {
            text: candidate,
            lines_total,
            omitted,
        };
    }
    shrink_to_bytes(&lines, head, tail)
}

/// Byte-cap path: keep as many of the `head` first and `tail` last lines as
/// fit their share of the budget.
fn shrink_to_bytes(lines: &[String], head_max: usize, tail_max: usize) -> Truncated {
    let total = lines.len();
    if total == 1 {
        // Nothing to omit: the one line gets the whole cap.
        return Truncated {
            text: clip(&lines[0], DeliveryPolicy::CAP_BYTES),
            lines_total: 1,
            omitted: 0,
        };
    }
    let budget = DeliveryPolicy::CAP_BYTES - MARKER_RESERVE;
    let head_budget = budget / 3;
    let tail_budget = budget - head_budget;

    let mut head: Vec<String> = fit(lines[..head_max].iter(), head_budget);
    let tail_start = total - tail_max;
    let mut tail: Vec<String> = fit(lines[tail_start..].iter().rev(), tail_budget);
    tail.reverse();

    // Each side keeps at least one (possibly clipped) line, without overlap.
    if head.is_empty() {
        head.push(clip(&lines[0], head_budget));
    }
    if tail.is_empty() && total > head.len() {
        // The tail line keeps its start: the cut is at the end.
        tail.push(clip(&lines[total - 1], tail_budget));
    }
    if head.len() + tail.len() > total {
        tail.drain(..head.len() + tail.len() - total);
    }

    let omitted = total - head.len() - tail.len();
    Truncated {
        text: assemble(&head, &tail, omitted),
        lines_total: total,
        omitted,
    }
}

/// Lines from `iter`, in order, while they fit `budget` bytes (a `\n` is
/// charged per line).
fn fit<'a>(iter: impl Iterator<Item = &'a String>, budget: usize) -> Vec<String> {
    let mut used = 0;
    let mut kept = Vec::new();
    for line in iter {
        used += line.len() + 1;
        if used > budget {
            break;
        }
        kept.push(line.clone());
    }
    kept
}

/// `head`, the marker (if anything was omitted), then `tail`, joined by `\n`.
fn assemble(head: &[String], tail: &[String], omitted: usize) -> String {
    let marker = format!("[… {omitted} lines omitted …]");
    let mut parts: Vec<&str> = head.iter().map(String::as_str).collect();
    if omitted > 0 {
        parts.push(&marker);
    }
    parts.extend(tail.iter().map(String::as_str));
    parts.join("\n")
}

fn joined_len(lines: &[String]) -> usize {
    lines
        .iter()
        .map(|l| l.len() + 1)
        .sum::<usize>()
        .saturating_sub(1)
}

/// `line` cut to at most `max` bytes on a char boundary, ending in `…`.
///
/// Callers hand it redacted text only. Even so, a cut in the middle of a word
/// never leaves the start of a token behind: a trailing stub that begins like a
/// known secret (`…ghp_AAAA…`) is dropped with the rest of its token.
fn clip(line: &str, max: usize) -> String {
    if line.len() < max {
        return line.to_owned();
    }
    let mut end = max.saturating_sub('…'.len_utf8());
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    let mut kept = &line[..end];
    let mid_token = line[end..].chars().next().is_some_and(is_token_char);
    if mid_token {
        if let Some(stub) = trailing_secret_stub(kept) {
            kept = &kept[..stub];
        }
    }
    format!("{kept}…")
}

#[cfg(test)]
mod tests {
    use super::*;

    const OMIT_PREFIX: &str = "[\u{2026} ";
    const OMIT_SUFFIX: &str = " lines omitted \u{2026}]";

    fn marker(n: usize) -> String {
        format!("{OMIT_PREFIX}{n}{OMIT_SUFFIX}")
    }

    fn numbered(n: usize) -> Vec<String> {
        (0..n).map(|i| format!("line {i}")).collect()
    }

    fn marker_lines(text: &str) -> Vec<&str> {
        text.split('\n')
            .filter(|l| l.starts_with(OMIT_PREFIX) && l.ends_with(OMIT_SUFFIX))
            .collect()
    }

    /// Invariants that hold for every input.
    fn check_invariants(input: &[String], t: &Truncated) {
        assert!(t.text.len() <= 16 * 1024, "text is {} bytes", t.text.len());
        assert_eq!(t.lines_total, input.len());
        let markers = marker_lines(&t.text);
        if t.omitted > 0 {
            assert_eq!(
                markers,
                vec![marker(t.omitted).as_str()],
                "marker N must equal omitted"
            );
        } else {
            assert!(
                markers.is_empty(),
                "no marker when nothing was omitted: {markers:?}"
            );
        }
    }

    #[test]
    fn small_output_is_unchanged() {
        let input = numbered(3);
        let t = truncate(input.clone());
        assert_eq!(
            t,
            Truncated {
                text: input.join("\n"),
                lines_total: 3,
                omitted: 0
            }
        );
    }

    #[test]
    fn empty_output_is_empty() {
        let t = truncate(Vec::new());
        assert_eq!(
            t,
            Truncated {
                text: String::new(),
                lines_total: 0,
                omitted: 0
            }
        );
    }

    #[test]
    fn exactly_200_short_lines_are_unchanged() {
        let input = numbered(200);
        let t = truncate(input.clone());
        assert_eq!(t.text, input.join("\n"));
        assert_eq!(t.omitted, 0);
        assert_eq!(t.lines_total, 200);
    }

    #[test]
    fn line_201_triggers_head_and_tail_truncation() {
        let input = numbered(201);
        let t = truncate(input.clone());
        assert_eq!(t.lines_total, 201);
        assert_eq!(t.omitted, 51);
        let mut expected: Vec<String> = input[..50].to_vec();
        expected.push(marker(51));
        expected.extend_from_slice(&input[101..]);
        assert_eq!(t.text, expected.join("\n"));
    }

    #[test]
    fn a_thousand_lines_keep_50_head_and_100_tail_with_a_marker() {
        let input = numbered(1000);
        let t = truncate(input.clone());
        assert_eq!(t.lines_total, 1000);
        assert_eq!(t.omitted, 850);
        let mut expected: Vec<String> = input[..50].to_vec();
        expected.push("[\u{2026} 850 lines omitted \u{2026}]".to_string());
        expected.extend_from_slice(&input[900..]);
        assert_eq!(t.text, expected.join("\n"));
        assert_eq!(t.text.split('\n').count(), 151);
    }

    #[test]
    fn output_of_exactly_16_kib_within_200_lines_is_unchanged() {
        let mut input: Vec<String> = (0..15)
            .map(|i| format!("{i:02}{}", "x".repeat(1021)))
            .collect();
        input.push(format!("15{}", "x".repeat(1022)));
        let joined = input.join("\n");
        assert_eq!(joined.len(), 16 * 1024);
        let t = truncate(input);
        assert_eq!(t.text, joined);
        assert_eq!(t.omitted, 0);
    }

    #[test]
    fn output_one_byte_over_16_kib_is_cut_back_under_the_cap() {
        let mut input: Vec<String> = (0..15)
            .map(|i| format!("{i:02}{}", "x".repeat(1021)))
            .collect();
        input.push(format!("15{}", "x".repeat(1023)));
        assert_eq!(input.join("\n").len(), 16 * 1024 + 1);
        let t = truncate(input.clone());
        check_invariants(&input, &t);
        assert!(
            t.text.starts_with(&input[0]),
            "head preserved from the start"
        );
        assert!(
            t.text.ends_with(input.last().unwrap()),
            "tail preserved to the end"
        );
    }

    #[test]
    fn many_long_lines_shrink_head_and_tail_to_fit_the_byte_cap() {
        for width in [200usize, 2000] {
            let input: Vec<String> = (0..300)
                .map(|i| format!("{i:04}{}", "x".repeat(width - 4)))
                .collect();
            let t = truncate(input.clone());
            check_invariants(&input, &t);
            assert!(t.omitted >= 150, "width {width}: omitted {}", t.omitted);
            assert!(
                t.text.starts_with(&input[0]),
                "width {width}: head preserved"
            );
            assert!(
                t.text.ends_with(input.last().unwrap()),
                "width {width}: tail preserved"
            );
        }
    }

    #[test]
    fn a_single_huge_line_is_clipped_with_an_ellipsis_and_no_marker() {
        let input = vec!["x".repeat(100 * 1024)];
        let t = truncate(input.clone());
        check_invariants(&input, &t);
        assert_eq!(t.omitted, 0);
        assert_eq!(t.lines_total, 1);
        assert!(t.text.ends_with('\u{2026}'));
        assert!(t.text.starts_with("xxxxxxxx"));
        assert!(
            t.text.len() > 8 * 1024,
            "keeps most of the budget, not a token amount"
        );
    }

    #[test]
    fn clipping_a_huge_multibyte_line_lands_on_a_character_boundary() {
        for ch in ["\u{65e5}", "\u{1F600}", "\u{e9}"] {
            let input = vec![ch.repeat(100 * 1024 / ch.len())];
            let t = truncate(input.clone());
            check_invariants(&input, &t);
            assert_eq!(t.omitted, 0);
            assert!(t.text.ends_with('\u{2026}'));
            assert!(t.text.starts_with(ch));
        }
    }

    #[test]
    fn two_huge_lines_still_fit_the_cap_and_the_marker_matches_omitted() {
        let input = vec!["a".repeat(50 * 1024), "b".repeat(50 * 1024)];
        let t = truncate(input.clone());
        check_invariants(&input, &t);
        assert!(t.text.starts_with("aaaa"));
    }

    #[test]
    fn a_thousand_lines_of_moderate_width_respect_the_cap_and_report_omitted_honestly() {
        let input: Vec<String> = (0..1000)
            .map(|i| format!("{i:04} {}", "y".repeat(120)))
            .collect();
        let t = truncate(input.clone());
        check_invariants(&input, &t);
        assert!(t.omitted >= 850);
        assert!(t.text.starts_with(&input[0]));
        assert!(t.text.ends_with(input.last().unwrap()));
    }

    #[test]
    fn clip_drops_the_stub_of_a_token_it_cuts() {
        // Raw (unredacted) text on purpose: clip must not leave `ghp_AAAA`.
        let line = format!("{}ghp_{}", "x".repeat(100), "A".repeat(36));
        let max = 100 + "ghp_AAAA".len() + '…'.len_utf8();
        let clipped = clip(&line, max);
        assert_eq!(clipped, format!("{}…", "x".repeat(100)));
    }

    #[test]
    fn clip_keeps_text_it_cuts_cleanly() {
        let line = format!("{} {}", "x".repeat(100), "word ".repeat(50));
        let clipped = clip(&line, 120);
        assert!(clipped.ends_with('…'));
        assert!(clipped.len() <= 120);
        assert!(clipped.starts_with(&"x".repeat(100)));
    }
}
