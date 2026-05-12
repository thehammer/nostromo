//! Behavioural tests for the Fred calendar timeline renderer.
//!
//! Tests cover:
//! - Column assignment (greedy interval scheduling)
//! - "now" marker insertion in gaps
//! - Status styling (cancelled → CROSSED_OUT)
//! - Time label styling (first upcoming → White + BOLD)
//! - Gap compression (no blank rows between event blocks)

use chrono::{Local, NaiveDate, TimeZone};
use ratatui::style::{Color, Modifier, Style};

use nostromo::data::fred_calendar::CalendarEvent;
use nostromo::ui::theme::Sweater;
use nostromo::views::fred::{assign_columns, render_calendar_lines};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Build a UTC `DateTime` that corresponds to `HH:MM` in local time on the
/// fixed test date 2026-05-12.
fn local_utc(hour: u32, min: u32) -> chrono::DateTime<chrono::Utc> {
    let date = NaiveDate::from_ymd_opt(2026, 5, 12).unwrap();
    let naive = date.and_hms_opt(hour, min, 0).unwrap();
    Local
        .from_local_datetime(&naive)
        .earliest()
        .unwrap()
        .with_timezone(&chrono::Utc)
}

/// Build a local `DateTime` at `HH:MM` on 2026-05-12.
fn local_now(hour: u32, min: u32) -> chrono::DateTime<Local> {
    let date = NaiveDate::from_ymd_opt(2026, 5, 12).unwrap();
    let naive = date.and_hms_opt(hour, min, 0).unwrap();
    Local.from_local_datetime(&naive).earliest().unwrap()
}

/// Build a simple `CalendarEvent` with the given local start/end times.
fn ev(start_h: u32, start_m: u32, end_h: u32, end_m: u32, status: &str) -> CalendarEvent {
    CalendarEvent {
        start: Some(local_utc(start_h, start_m)),
        end: Some(local_utc(end_h, end_m)),
        title: "Test Event".into(),
        status: status.into(),
        is_now: false,
    }
}

// ── assign_columns tests ──────────────────────────────────────────────────────

#[test]
fn assign_columns_no_overlap_uses_one_column() {
    // Three sequential non-overlapping events → all in column 0.
    let events = vec![
        ev(9, 0, 9, 30, "accepted"),
        ev(10, 0, 10, 30, "accepted"),
        ev(11, 0, 11, 30, "accepted"),
    ];
    let cols = assign_columns(&events);
    assert_eq!(
        cols,
        vec![0, 0, 0],
        "non-overlapping events should all be in column 0"
    );
}

#[test]
fn assign_columns_two_overlapping_uses_two_columns() {
    // Two events that overlap → columns 0 and 1.
    let events = vec![
        ev(9, 0, 10, 0, "accepted"),   // 09:00–10:00
        ev(9, 30, 10, 30, "accepted"), // 09:30–10:30 — overlaps with first
    ];
    let cols = assign_columns(&events);
    let used: std::collections::HashSet<usize> = cols.iter().copied().collect();
    assert_eq!(used.len(), 2, "two overlapping events need two columns");
    assert_eq!(
        *cols.iter().max().unwrap(),
        1,
        "max column index should be 1"
    );
}

#[test]
fn assign_columns_max_concurrency_two_not_three() {
    // Three events where at most 2 overlap simultaneously.
    // A: 09:00–10:00, B: 09:30–10:30, C: 10:00–11:00
    // At 09:30–10:00: A and B overlap (2 concurrent).
    // At 10:00–10:30: B and C overlap (2 concurrent). A has ended.
    // So max concurrency = 2 → max column index = 1.
    let events = vec![
        ev(9, 0, 10, 0, "accepted"),   // A
        ev(9, 30, 10, 30, "accepted"), // B
        ev(10, 0, 11, 0, "accepted"),  // C — starts exactly when A ends
    ];
    let cols = assign_columns(&events);
    let max_col = *cols.iter().max().unwrap();
    assert!(
        max_col <= 1,
        "max concurrent = 2, so max column index should be ≤ 1, got {max_col}"
    );
}

// ── render_calendar_lines tests ───────────────────────────────────────────────

/// Collect all span text+style pairs from all lines.
fn all_spans(lines: &[ratatui::text::Line<'_>]) -> Vec<(String, Style)> {
    lines
        .iter()
        .flat_map(|l| l.spans.iter().map(|s| (s.content.to_string(), s.style)))
        .collect()
}

#[test]
fn render_includes_now_marker_in_gap() {
    // Events at 09:00–09:30 and 11:00–12:00; now = 10:00.
    // The "now" marker line should appear between the two blocks.
    let events = vec![ev(9, 0, 9, 30, "accepted"), ev(11, 0, 12, 0, "accepted")];
    let now = local_now(10, 0);

    let (lines, _) = render_calendar_lines(&events, now, 60, 40, Sweater::Sage);

    let amber_now = all_spans(&lines)
        .into_iter()
        .any(|(text, style)| text.contains("now") && style.fg == Some(Color::Rgb(255, 191, 0)));

    assert!(
        amber_now,
        "expected an amber 'now' marker span between the two event blocks"
    );
}

#[test]
fn render_marks_cancelled_with_crossed_out() {
    // A cancelled event should have CROSSED_OUT on at least one span.
    let events = vec![ev(10, 0, 11, 0, "cancelled")];
    let now = local_now(9, 0); // before the event so it's "upcoming"

    let (lines, _) = render_calendar_lines(&events, now, 60, 40, Sweater::Sage);

    let has_crossed_out = all_spans(&lines)
        .into_iter()
        .any(|(_, style)| style.add_modifier.contains(Modifier::CROSSED_OUT));

    assert!(
        has_crossed_out,
        "cancelled event should render with CROSSED_OUT modifier"
    );
}

#[test]
fn render_first_upcoming_time_label_bold_white() {
    // Past event at 09:00–09:30, upcoming at 14:00–15:00; now = 12:00.
    // The "14:00 " time label should be Color::White + BOLD.
    let events = vec![
        ev(9, 0, 9, 30, "accepted"),  // past
        ev(14, 0, 15, 0, "accepted"), // first upcoming
    ];
    let now = local_now(12, 0);

    let (lines, _) = render_calendar_lines(&events, now, 60, 40, Sweater::Sage);

    let bold_white = Style::default()
        .fg(Color::White)
        .add_modifier(Modifier::BOLD);

    let has_bold_white_label = all_spans(&lines)
        .into_iter()
        .any(|(text, style)| text.contains("14:00") && style == bold_white);

    assert!(
        has_bold_white_label,
        "first upcoming event's time label should be White + BOLD; spans:\n{:?}",
        all_spans(&lines)
            .iter()
            .filter(|(t, _)| t.contains("14:00") || t.contains("14"))
            .collect::<Vec<_>>()
    );
}

#[test]
fn render_gap_compression_no_empty_rows_between_events() {
    // Events at 09:00–09:30 and 11:00–11:30 with now outside working hours.
    // No fully-blank line should appear between the two rendered blocks.
    let events = vec![ev(9, 0, 9, 30, "accepted"), ev(11, 0, 11, 30, "accepted")];
    // now = 07:00 (outside working hours — no "now" marker inserted)
    let now = local_now(7, 0);

    let (lines, _) = render_calendar_lines(&events, now, 60, 40, Sweater::Sage);

    // Find the last line of the first block and the first line of the second.
    // A "fully blank" line has no non-space, non-empty span content.
    let is_blank = |line: &ratatui::text::Line<'_>| {
        line.spans
            .iter()
            .all(|s| s.content.chars().all(|c| c == ' '))
    };

    // Collect which lines are blank.
    let blank_lines: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| is_blank(l))
        .map(|(i, _)| i)
        .collect();

    assert!(
        blank_lines.is_empty(),
        "gap compression: no blank rows should appear between event blocks, \
         found blank lines at indices: {blank_lines:?}"
    );
}
