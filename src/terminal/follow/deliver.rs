//! [`deliver`]: the one public way from terminal bytes to agent-ready text.
//!
//! The order is fixed here so no caller can get it wrong:
//!
//! 1. take the committed lines from the [`LineAssembler`] (the live cursor row
//!    stays in the assembler until it commits, so the redactor only ever sees
//!    whole lines);
//! 2. REDACT them;
//! 3. only then apply the line and byte caps. Truncating first can cut a token
//!    so its remaining prefix is shorter than any pattern's minimum and slips
//!    through; the cut also re-checks its tail for such stubs.
//!
//! Redaction fails closed: if it panics, the text is [`Delivery::Withheld`].
//! The panic hook still runs, so a panic message that quotes the offending
//! text would reach the log; the redaction rules never slice by assumed
//! offsets and are fuzzed, which is what keeps that from happening.

use std::panic::{catch_unwind, AssertUnwindSafe};

use super::lines::LineAssembler;
use super::policy::DeliveryPolicy;
use super::snapshot::snapshot_lines;
use super::truncate::truncate;
use crate::terminal::redact::{RedactionKind, Redactor};

/// Text to show instead of a withheld delivery, if the caller wants to tell
/// the agent something went missing. It carries no terminal content.
pub const WITHHELD_MARKER: &str = "[output withheld: redaction failed]";

/// The outcome of [`deliver`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Delivery {
    /// Redacted, capped text. At most [`DeliveryPolicy::CAP_BYTES`] bytes;
    /// empty when there was nothing to deliver (callers send nothing then).
    Text {
        text: String,
        /// Lines that went in (after redaction merged any private-key block).
        lines_total: usize,
        /// Lines missing from `text`; equals the `N` of the omitted-lines
        /// marker, or 0 when there is none.
        omitted: usize,
        /// One entry per redaction made, in order of appearance (the text
        /// itself is never reported).
        redactions: Vec<RedactionKind>,
    },
    /// Redaction failed, so no text may be delivered. **Callers must treat
    /// this as no delivery**: send nothing from the terminal (at most
    /// [`WITHHELD_MARKER`]) and never fall back to the raw lines.
    Withheld,
}

impl Delivery {
    /// The text to deliver, if any.
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text { text, .. } => Some(text),
            Self::Withheld => None,
        }
    }

    /// Whether the line or byte cap cut anything.
    pub fn is_capped(&self) -> bool {
        matches!(self, Self::Text { omitted, .. } if *omitted > 0)
    }
}

/// Take the committed lines from `assembler`, redact them, cap them, and
/// report the delivery to `policy` (so the caller must NOT call
/// [`DeliveryPolicy::on_delivered`] itself; a withheld delivery and an empty
/// one are not reported). Call it when the policy says
/// [`Decision::Deliver`](super::Decision::Deliver).
///
/// `redactor` carries private-key block state between deliveries: use one per
/// terminal.
pub fn deliver(
    assembler: &mut LineAssembler,
    redactor: &mut Redactor,
    policy: &mut DeliveryPolicy,
) -> Delivery {
    deliver_lines(assembler.take_committed(), redactor, policy)
}

/// Redact and cap the screen of a full-screen program: the public way from a
/// raw [`screen_snapshot`](super::screen_snapshot) to agent text. It is the same pipeline as
/// [`deliver`] (redact first, cap second, fail closed), and reports the
/// delivery to `policy` the same way (a blank screen is not a delivery).
///
/// Rows the program wrapped are joined before redaction, so a secret that
/// wrapped onto a second row is whole. A snapshot stands alone, so it is
/// redacted with a fresh [`Redactor`]: a private-key block left open at the
/// bottom of the screen neither carries into this terminal's later deliveries
/// nor inherits state from them. The flip side: a screen scrolled into the
/// middle of a key (the `BEGIN` line off-screen) has no marker to recognise,
/// and its body lines are delivered as the text they are.
pub fn deliver_snapshot(screen: &vt100::Screen, policy: &mut DeliveryPolicy) -> Delivery {
    deliver_snapshot_in(screen, policy, false)
}

/// [`deliver_snapshot`] for a screen of a terminal whose own output may have
/// been inside a private-key block when it was drawn (`key_open`: the
/// terminal's [`Redactor`] says so). A screen that starts in the middle of a
/// key (its `BEGIN` scrolled off) is redacted down to the key's `END`, or
/// entirely when the key has not ended: it is recognised by an `END` line with
/// no `BEGIN` above it, or by `key_open`.
pub fn deliver_snapshot_in(
    screen: &vt100::Screen,
    policy: &mut DeliveryPolicy,
    key_open: bool,
) -> Delivery {
    let lines = snapshot_lines(screen);
    let mut redactor = Redactor::for_screen(&lines, key_open);
    deliver_lines(lines, &mut redactor, policy)
}

/// [`deliver`] for lines that did not come from an assembler (a screen
/// snapshot split into lines). Crate-private: the lines must be whole.
pub(crate) fn deliver_lines(
    lines: Vec<String>,
    redactor: &mut Redactor,
    policy: &mut DeliveryPolicy,
) -> Delivery {
    deliver_with(lines, redactor, policy, Redactor::redact_lines)
}

/// The delivery pipeline with the redaction step injectable, so the fail-closed
/// path can be exercised.
pub(crate) fn deliver_with(
    lines: Vec<String>,
    redactor: &mut Redactor,
    policy: &mut DeliveryPolicy,
    redact: impl FnOnce(&mut Redactor, &[String]) -> (Vec<String>, Vec<RedactionKind>),
) -> Delivery {
    if lines.is_empty() {
        // Nothing to deliver is not a delivery: the policy is not told.
        return Delivery::Text {
            text: String::new(),
            lines_total: 0,
            omitted: 0,
            redactions: Vec::new(),
        };
    }
    let delivery = catch_unwind(AssertUnwindSafe(|| {
        let (redacted, redactions) = redact(redactor, &lines);
        let truncated = truncate(redacted);
        Delivery::Text {
            text: truncated.text,
            lines_total: truncated.lines_total,
            omitted: truncated.omitted,
            redactions,
        }
    }));
    match delivery {
        Ok(delivery) => {
            policy.on_delivered(delivery.is_capped());
            delivery
        }
        Err(_) => {
            redactor.assume_unredacted(&lines);
            Delivery::Withheld
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::Decision;
    use super::*;

    fn fresh() -> (Redactor, DeliveryPolicy) {
        (Redactor::new(), DeliveryPolicy::new())
    }

    /// A screen of `rows` rows showing `text` (lines joined by CRLF, scrolled
    /// as a terminal would).
    fn screen_showing(rows: u16, text: &str) -> vt100::Parser {
        let mut parser = vt100::Parser::new(rows, 80, 0);
        parser.process(text.replace('\n', "\r\n").as_bytes());
        parser
    }

    fn key_lines(body_lines: usize, with_end: bool) -> String {
        let mut lines = vec!["$ cat id_rsa".to_string()];
        lines.push("-----BEGIN RSA PRIVATE KEY-----".into());
        lines.extend((0..body_lines).map(|i| format!("KEYBODY{i:03}")));
        if with_end {
            lines.push("-----END RSA PRIVATE KEY-----".into());
        }
        lines.push("$ ".into());
        lines.join("\n")
    }

    #[test]
    fn a_key_whose_begin_scrolled_off_the_screen_is_redacted_down_to_its_end() {
        // 30 body lines on a 10-row screen: BEGIN and most of the body are gone.
        let parser = screen_showing(10, &key_lines(30, true));
        let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
        let text = delivery.text().unwrap();
        assert!(!text.contains("KEYBODY"), "{text}");
        assert!(text.contains("[redacted: private-key]"), "{text}");
        assert!(
            text.ends_with("$"),
            "what follows the key is kept: {text:?}"
        );
    }

    #[test]
    fn a_screen_inside_a_key_that_has_not_ended_is_redacted_when_the_stream_says_so() {
        let parser = screen_showing(10, &key_lines(30, false).replace("$ ", "more"));
        let plain = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
        // Without the stream's state, body lines alone cannot be told from text.
        assert!(plain.text().unwrap().contains("KEYBODY"));
        let delivery = deliver_snapshot_in(parser.screen(), &mut DeliveryPolicy::new(), true);
        assert!(
            !delivery.text().unwrap().contains("KEYBODY"),
            "{delivery:?}"
        );
    }

    #[test]
    fn a_whole_key_on_the_screen_still_keeps_the_lines_before_it() {
        let parser = screen_showing(40, &key_lines(5, true));
        let delivery = deliver_snapshot(parser.screen(), &mut DeliveryPolicy::new());
        let text = delivery.text().unwrap();
        assert!(text.contains("$ cat id_rsa"), "{text}");
        assert!(!text.contains("KEYBODY"), "{text}");
    }

    #[test]
    fn a_panicking_redaction_withholds_and_never_returns_the_raw_text() {
        let (mut redactor, mut policy) = fresh();
        let lines = vec!["raw secret text".to_string()];
        let delivery = deliver_with(lines, &mut redactor, &mut policy, |_, _| {
            panic!("redactor exploded")
        });
        assert_eq!(delivery, Delivery::Withheld);
        assert_eq!(delivery.text(), None);
        assert!(!format!("{delivery:?}").contains("raw secret"));
    }

    #[test]
    fn a_failed_redaction_that_may_have_opened_a_key_keeps_swallowing() {
        let (mut redactor, mut policy) = fresh();
        let lines = vec!["-----BEGIN RSA PRIVATE KEY-----".to_string()];
        let delivery = deliver_with(lines, &mut redactor, &mut policy, |_, _| panic!("boom"));
        assert_eq!(delivery, Delivery::Withheld);
        assert!(redactor.inside_private_key());
        let next = deliver_lines(vec!["MIIFAKEBODY".to_string()], &mut redactor, &mut policy);
        assert!(!next.text().unwrap().contains("MIIFAKEBODY"));
    }

    #[test]
    fn a_panic_does_not_poison_the_next_delivery() {
        let (mut redactor, mut policy) = fresh();
        let _ = deliver_with(vec!["x".into()], &mut redactor, &mut policy, |_, _| {
            panic!("boom")
        });
        let next = deliver_lines(vec!["hello".to_string()], &mut redactor, &mut policy);
        assert_eq!(next.text(), Some("hello"));
    }

    #[test]
    fn a_withheld_delivery_does_not_reset_the_capped_counter() {
        let (mut redactor, mut policy) = fresh();
        let many: Vec<String> = (0..300).map(|i| format!("line {i}")).collect();
        for _ in 0..2 {
            let d = deliver_lines(many.clone(), &mut redactor, &mut policy);
            assert!(d.is_capped());
        }
        let _ = deliver_with(vec!["x".into()], &mut redactor, &mut policy, |_, _| {
            panic!("boom")
        });
        let d = deliver_lines(many, &mut redactor, &mut policy);
        assert!(d.is_capped());
        // Three capped deliveries in a row (the withheld one in between does
        // not count either way) pause following.
        assert!(matches!(
            policy.on_tick(std::time::Instant::now(), None, false),
            Decision::Pause { .. }
        ));
    }

    #[test]
    fn key_body_that_outlives_its_dropped_header_is_still_swallowed() {
        let mut assembler = LineAssembler::new();
        assembler.feed(b"-----BEGIN RSA PRIVATE KEY-----\n");
        for i in 0..super::super::MAX_BUFFERED_ROWS + 5 {
            assembler.feed(format!("KB{}\n", i % 10).as_bytes());
        }
        let (mut redactor, mut policy) = fresh();
        let text = deliver(&mut assembler, &mut redactor, &mut policy)
            .text()
            .unwrap()
            .to_owned();
        assert!(!text.contains("KB"), "{text}");
        assert!(text.contains("[redacted: private-key]"));
    }
}
