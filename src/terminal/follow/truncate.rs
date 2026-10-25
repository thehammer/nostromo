//! Head-and-tail truncation of a delivery.

use super::policy::DeliveryPolicy;

/// Bytes kept back for the omitted-lines marker when the byte cap bites.
const MARKER_RESERVE: usize = 64;

/// A delivery's text after the line and byte caps.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Truncated {
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
pub fn truncate(lines: Vec<String>) -> Truncated {
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
fn clip(line: &str, max: usize) -> String {
    if line.len() < max {
        return line.to_owned();
    }
    let mut end = max.saturating_sub('…'.len_utf8());
    while !line.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &line[..end])
}
