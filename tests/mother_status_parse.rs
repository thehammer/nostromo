//! Unit tests for `MotherStatus::parse`.

use nostromo::mother::MotherStatus;

#[test]
fn four_field_statusline() {
    let s = MotherStatus::parse("1:2:0:3");
    assert_eq!(s.running, 1);
    assert_eq!(s.queued, 2);
    assert_eq!(s.failed, 0);
    assert_eq!(s.awaiting, 3);
}

#[test]
fn three_field_fallback_awaiting_defaults_to_zero() {
    let s = MotherStatus::parse("2:5:1");
    assert_eq!(s.running, 2);
    assert_eq!(s.queued, 5);
    assert_eq!(s.failed, 1);
    assert_eq!(s.awaiting, 0);
}

#[test]
fn all_zeros() {
    let s = MotherStatus::parse("0:0:0:0");
    assert_eq!(s, MotherStatus::default());
}

#[test]
fn trailing_newline_stripped() {
    let s = MotherStatus::parse("3:4:2:1\n");
    assert_eq!(s.running, 3);
    assert_eq!(s.queued, 4);
    assert_eq!(s.failed, 2);
    assert_eq!(s.awaiting, 1);
}

#[test]
fn empty_string_returns_default() {
    let s = MotherStatus::parse("");
    assert_eq!(s, MotherStatus::default());
}

#[test]
fn status_line_shows_awaiting_when_nonzero() {
    let s = MotherStatus {
        running: 1,
        queued: 0,
        failed: 0,
        awaiting: 2,
    };
    assert!(s.status_line().contains("awaiting"));
}

#[test]
fn status_line_shows_running_when_no_awaiting() {
    let s = MotherStatus {
        running: 3,
        queued: 1,
        failed: 0,
        awaiting: 0,
    };
    let line = s.status_line();
    assert!(line.contains("running"), "expected 'running' in '{line}'");
    assert!(line.contains("queued"), "expected 'queued' in '{line}'");
}

#[test]
fn status_line_idle_when_all_zero() {
    let s = MotherStatus::default();
    assert!(s.status_line().contains("idle"));
}
