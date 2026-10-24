//! The display of a very large command (PR #270 review fix-up N1).
//!
//! Building the display used to rescan every separator for every line: quadratic
//! (4.4 s for a 160 KB command of 40,000 short lines in a debug build; minutes for
//! 4 MiB), and the approval broker's single worker thread builds it for every
//! request. The contract now:
//!
//! - a command of up to [`MAX_DISPLAY_COMMAND_BYTES`] is displayed in full, as
//!   ever (the round trip of `tests/approvals_display.rs` still holds), in time
//!   linear in its size;
//! - a bigger one is not broken down at all: its display is the one fixed line
//!   [`COMMAND_TOO_LARGE_LINE`], built at once. (What is shown does not
//!   pretend to be the command: it does not reassemble to it.)

use std::time::{Duration, Instant};

use nostromo::approvals::display::{
    ApprovalDisplay, LineKind, COMMAND_TOO_LARGE_LINE, MAX_DISPLAY_COMMAND_BYTES,
};
use nostromo::approvals::request::ToolKind;
use serde_json::json;

/// Debug builds are slow; this is still far below what the quadratic version took.
const BOUND: Duration = Duration::from_secs(2);

/// `unit` repeated until the command is exactly `bytes` long (`unit` is ASCII).
fn command_of(unit: &str, bytes: usize) -> String {
    let mut s = unit.repeat(bytes / unit.len());
    s.push_str(&"x".repeat(bytes - s.len()));
    assert_eq!(s.len(), bytes);
    s
}

fn bash(command: &str) -> ApprovalDisplay {
    ApprovalDisplay::build(ToolKind::Bash, &json!({ "command": command }))
}

/// Build the display on its own thread and give up after [`BOUND`]: a quadratic
/// build must fail this test, not hang the run for minutes (its thread is simply
/// abandoned; the test process exits when the tests are done).
#[track_caller]
fn timed_bash(what: &str, command: &str) -> ApprovalDisplay {
    let command = command.to_owned();
    let (tx, rx) = std::sync::mpsc::channel();
    let started = Instant::now();
    std::thread::spawn(move || {
        let _ = tx.send(bash(&command));
    });
    let display = rx
        .recv_timeout(BOUND)
        .unwrap_or_else(|_| panic!("{what}: building the display did not finish within {BOUND:?}"));
    let took = started.elapsed();
    assert!(took < BOUND, "{what}: building the display took {took:?}");
    display
}

#[test]
fn the_limits_are_32_kib_and_one_fixed_line() {
    assert_eq!(MAX_DISPLAY_COMMAND_BYTES, 32 * 1024);
    assert_eq!(COMMAND_TOO_LARGE_LINE, "(command too large to display)");
}

#[test]
fn a_4_mib_command_of_a_million_short_lines_is_shown_as_too_large_at_once() {
    // Each of these has a separator on every line, which is what made the old
    // code quadratic; ~1M, ~1.4M and ~2M lines.
    for unit in ["a;b\n", "a&\n", ";\n"] {
        let command = command_of(unit, 4 * 1024 * 1024);

        let d = timed_bash(&format!("4 MiB of {unit:?}"), &command);

        let shown = d.shown_text();
        assert!(
            shown.contains(COMMAND_TOO_LARGE_LINE),
            "{unit:?}: {:.200}",
            shown
        );
        assert!(
            shown.len() < 1024,
            "{unit:?}: the command is not shown, only the line that says so: {} bytes",
            shown.len()
        );
        assert!(d.lines.len() < 10, "{unit:?}: {} lines", d.lines.len());
        assert_ne!(
            d.reassemble(),
            command,
            "{unit:?}: a display that does not show the command must not reassemble to it"
        );
    }
}

#[test]
fn a_command_over_the_cap_is_shown_as_too_large_whatever_it_looks_like() {
    for command in [
        "x".repeat(MAX_DISPLAY_COMMAND_BYTES + 1), // one enormous line
        "echo hello world\n".repeat(MAX_DISPLAY_COMMAND_BYTES / 16), // many plain lines
        format!(
            "cat <<'EOF'\n{}EOF\n",
            "body line\n".repeat(MAX_DISPLAY_COMMAND_BYTES / 8)
        ), // a huge here-doc
        "é".repeat(MAX_DISPLAY_COMMAND_BYTES),     // multi-byte text
    ] {
        assert!(command.len() > MAX_DISPLAY_COMMAND_BYTES);

        let d = timed_bash("an oversize command", &command);

        assert!(
            d.shown_text().contains(COMMAND_TOO_LARGE_LINE),
            "{:.100}",
            d.shown_text()
        );
        assert!(d.shown_text().len() < 1024);
    }
}

#[test]
fn a_command_just_under_the_cap_is_displayed_in_full_and_still_reassembles_byte_for_byte() {
    for unit in ["echo hi && ls\n", "x", "a;b\n"] {
        let command = command_of(unit, MAX_DISPLAY_COMMAND_BYTES - 16);

        let d = timed_bash(&format!("{unit:?} just under the cap"), &command);

        assert!(
            !d.shown_text().contains(COMMAND_TOO_LARGE_LINE),
            "{unit:?}: under the cap it is shown, not replaced"
        );
        assert_eq!(
            d.reassemble(),
            command,
            "{unit:?}: nothing elided, nothing rewritten (T-INV-2)"
        );
        assert!(d.lines.iter().all(|l| l.kind == LineKind::Command));
    }
}

#[test]
fn a_32_kb_command_of_8000_short_lines_is_displayed_in_full_in_bounded_time() {
    let command = "a;b\n".repeat(8_000);
    assert_eq!(command.len(), 32_000);

    let d = timed_bash("8,000 lines of `a;b`", &command);

    assert!(!d.shown_text().contains(COMMAND_TOO_LARGE_LINE));
    assert_eq!(d.reassemble(), command);
    assert_eq!(
        d.lines.len(),
        16_001,
        "each `a;` and `b` is its own numbered line, as for a short command, and the \
         newline that ends the command leaves an empty last line (as it always did)"
    );
    assert_eq!(d.lines[0].number, 1);
    assert_eq!(d.lines[16_000].number, 16_001);
}

#[test]
fn a_short_command_is_displayed_exactly_as_before() {
    // The ordinary case, unchanged (the full set is in tests/approvals_display.rs).
    let d = bash("ls /tmp && rm -rf /tmp/x; echo done");

    assert!(!d.shown_text().contains(COMMAND_TOO_LARGE_LINE));
    assert_eq!(d.lines.len(), 3, "cut after `&&` and after `;`");
    assert_eq!(d.reassemble(), "ls /tmp && rm -rf /tmp/x; echo done");
    assert_eq!(d.command_count, Some(3));
}

#[test]
fn a_command_of_exactly_the_cap_is_displayed_and_one_byte_over_is_replaced() {
    let at = command_of("x", MAX_DISPLAY_COMMAND_BYTES);
    let d = timed_bash("exactly at the cap", &at);
    assert!(
        !d.shown_text().contains(COMMAND_TOO_LARGE_LINE),
        "at the cap it is shown, not replaced"
    );
    assert_eq!(d.reassemble(), at);

    let over = command_of("x", MAX_DISPLAY_COMMAND_BYTES + 1);
    let d = timed_bash("one byte over the cap", &over);
    assert!(
        d.shown_text().contains(COMMAND_TOO_LARGE_LINE),
        "one byte over, it is not"
    );
    assert_ne!(d.reassemble(), over);
}

#[test]
fn a_command_the_tokenizer_cannot_finish_reading_is_still_displayed_in_full_under_the_cap() {
    // Under the display cap the whole text is shown even when the tokenizer gives up on it
    // (`unparsed` says so); nothing is elided. (T-INV-2)
    let command = "$( ".repeat(MAX_DISPLAY_COMMAND_BYTES / 3);
    assert!(command.len() <= MAX_DISPLAY_COMMAND_BYTES);

    let d = timed_bash("an unreadable command under the cap", &command);

    assert!(d.unparsed, "the tokenizer could not read it");
    assert!(!d.shown_text().contains(COMMAND_TOO_LARGE_LINE));
    assert_eq!(d.reassemble(), command, "everything is shown");
}
