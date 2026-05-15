//! Persistent 1-row bottom status bar.
//!
//! Renders a horizontal bar split into:
//! - **Left**: Mother queue counts, email, calendar, my-PR count, PR review queue,
//!   MCP-registered segments for the active view, toasts.
//! - **Right**: Budget posture chip + Claude rate-limit windows.
//!
//! All segments are optional and hide automatically when data is absent or zero.
//!
//! Phase 4 additions:
//! - MCP status segments: shown when their view is the active tab.
//! - Toasts: shown as `[⚡ text]` on the left, fading after 5 s.

use chrono::Utc;
use ratatui::{
    layout::{Alignment, Constraint, Layout, Rect},
    style::{Color, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};
use unicode_width::UnicodeWidthStr;

use crate::{
    app::{AppState, Toast},
    data::rate_limits::BudgetPosture,
    mcp::command::NotifyLevel,
    ui::theme,
};

// ── separator ─────────────────────────────────────────────────────────────────

const SEP: &str = " │ ";

// ── entry point ───────────────────────────────────────────────────────────────

/// Render the bottom status bar into `area` (expected height: 1).
pub fn render(f: &mut Frame, area: Rect, state: &mut AppState) {
    state.status_hitmap.clear();

    // ── Left segments ─────────────────────────────────────────────────────────

    // 'static spans: all segment content is owned (format!/String), so no
    // borrow of `state` escapes into `left_spans`. This lets us mutably
    // borrow `state.status_hitmap` inside the loop without conflict.
    let mut left_spans: Vec<Span<'static>> = Vec::new();
    let mut col_offset: u16 = area.x;

    let sep_width = SEP.width() as u16;

    // Helper: append one segment, tracking its column range in the hitmap.
    // Segments are processed one at a time to avoid holding multiple immutable
    // borrows of `state` while also needing a mutable borrow for `status_hitmap`.
    macro_rules! push_seg {
        ($seg:expr, $view_id:expr) => {
            if let Some(seg) = $seg {
                if !left_spans.is_empty() {
                    left_spans.push(Span::styled(
                        SEP,
                        Style::default().fg(theme::BORDER_INACTIVE),
                    ));
                    col_offset += sep_width;
                }
                let seg_start = col_offset;
                let seg_width: u16 = seg.iter().map(|s| s.content.width() as u16).sum();
                let seg_end = seg_start + seg_width;
                left_spans.extend(seg);
                col_offset = seg_end;
                state.status_hitmap.push((seg_start, seg_end, $view_id));
            }
        };
    }

    // Each segment is computed and consumed before the next is started, so
    // immutable borrows on `state` data do not overlap with the hitmap push.
    let seg = mother_segment(state);
    push_seg!(seg, "mother");
    let seg = email_segment(state);
    push_seg!(seg, "fred");
    let seg = calendar_segment(state);
    push_seg!(seg, "fred");
    let seg = my_pr_segment(state);
    push_seg!(seg, "perri");
    let seg = pr_queue_segment(state);
    push_seg!(seg, "perri");

    // MCP-registered segments for the active view (Phase 4).
    let mcp_segs = mcp_status_segments(state);
    for seg in mcp_segs {
        push_seg!(Some(seg), "mcp");
    }

    // Toasts (Phase 4) — shown after all regular segments.
    if let Some(toast_seg) = toast_segment(state) {
        push_seg!(Some(toast_seg), "mcp");
    }

    let _ = col_offset; // col_offset is only needed between segments; discard after last push

    // ── Right segments ────────────────────────────────────────────────────────

    let right_spans = right_segment(state);
    let right_line = Line::from(right_spans);
    let rate_width = right_line.width() as u16;

    // ── Layout ────────────────────────────────────────────────────────────────

    let [left_area, right_area] =
        Layout::horizontal([Constraint::Min(0), Constraint::Length(rate_width)]).areas(area);

    f.render_widget(Paragraph::new(Line::from(left_spans)), left_area);
    f.render_widget(
        Paragraph::new(right_line).alignment(Alignment::Right),
        right_area,
    );
}

// ── left segments ─────────────────────────────────────────────────────────────

/// Mother segment: `🏭 ▶{r} ⏸{q} ?{a} !{f}` — zero counts hidden; segment
/// hidden entirely when all counts are zero.
fn mother_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let mut running = 0usize;
    let mut queued = 0usize;
    let mut awaiting = 0usize;
    let mut failed = 0usize;

    for job in &state.mother_jobs {
        match job.state.as_str() {
            "running" => running += 1,
            "queued" => queued += 1,
            "awaiting" => awaiting += 1,
            "failed" => failed += 1,
            _ => {}
        }
    }

    if running == 0 && queued == 0 && awaiting == 0 && failed == 0 {
        return None;
    }

    let mut spans = vec![Span::styled("🏭 ", Style::default().fg(theme::FG_MUTED))];

    if running > 0 {
        spans.push(Span::styled(
            format!("▶{running}"),
            Style::default().fg(theme::SAGE),
        ));
        spans.push(Span::raw(" "));
    }
    if queued > 0 {
        spans.push(Span::styled(
            format!("⏸{queued}"),
            Style::default().fg(theme::FG_MUTED),
        ));
        spans.push(Span::raw(" "));
    }
    if awaiting > 0 {
        spans.push(Span::styled(
            format!("?{awaiting}"),
            Style::default().fg(theme::AMBER),
        ));
        spans.push(Span::raw(" "));
    }
    if failed > 0 {
        spans.push(Span::styled(
            format!("!{failed}"),
            Style::default().fg(theme::RED_SWEATER),
        ));
        spans.push(Span::raw(" "));
    }

    // Trim trailing space span if present.
    if spans.last().map(|s| s.content.as_ref()) == Some(" ") {
        spans.pop();
    }

    Some(spans)
}

/// Email segment: `📭 {total}·{unread}` — unread yellow if ≥1, red if ≥10.
fn email_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let snap = state.mailbox_rx.borrow();
    let snap = snap.as_ref()?;

    let total = snap.items.len();
    let unread = snap.unread_count;

    let unread_style = if unread >= 10 {
        Style::default().fg(theme::RED_SWEATER)
    } else if unread >= 1 {
        Style::default().fg(theme::AMBER)
    } else {
        Style::default().fg(theme::FG_MUTED)
    };

    Some(vec![
        Span::styled("📭 ", Style::default().fg(theme::FG_MUTED)),
        Span::styled(format!("{total}"), Style::default().fg(theme::FG_MUTED)),
        Span::styled("·", Style::default().fg(theme::BORDER_INACTIVE)),
        Span::styled(format!("{unread}"), unread_style),
    ])
}

/// Calendar segment: `{title} @ {relative_time}` truncated to 35 chars.
fn calendar_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let snap = state.calendar_rx.borrow();
    let snap = snap.as_ref()?;
    let next = snap.next.as_ref()?;

    let sweater = theme::Sweater::from_str(&snap.sweater);
    let color = sweater.color();

    let time_str = if next.in_minutes <= 0 {
        "now".to_string()
    } else if next.in_minutes >= 60 {
        let h = next.in_minutes / 60;
        let m = next.in_minutes % 60;
        if m == 0 {
            format!("{h}h")
        } else {
            format!("{h}h{m}m")
        }
    } else {
        format!("{}m", next.in_minutes)
    };

    let raw = format!("{} @ {}", next.title, time_str);
    let truncated = crate::ui::widgets::truncate::truncate(&raw, 35);

    Some(vec![Span::styled(truncated, Style::default().fg(color))])
}

/// My PRs segment: `{n} PRs` when any open PRs exist.
fn my_pr_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let count = state.open_pr_list.len();
    if count == 0 {
        return None;
    }
    Some(vec![Span::styled(
        format!("{count} PRs"),
        Style::default().fg(theme::FG_MUTED),
    )])
}

/// PR review queue segment: `👀 {n}` — green/yellow/red by depth.
fn pr_queue_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let count = state.perri_open_pr_count;
    if count == 0 {
        return None;
    }
    let color = if count >= 10 {
        theme::RED_SWEATER
    } else if count >= 4 {
        theme::AMBER
    } else {
        theme::SAGE
    };
    Some(vec![Span::styled(
        format!("👀 {count}"),
        Style::default().fg(color),
    )])
}

// ── MCP phase-4 segments ──────────────────────────────────────────────────────

/// Returns one `Vec<Span>` per MCP-registered segment for the active view.
///
/// Only segments whose `view_id` matches `state.active_view_id` are shown.
fn mcp_status_segments(state: &AppState) -> Vec<Vec<Span<'static>>> {
    let active = &state.active_view_id;
    let mut out: Vec<Vec<Span<'static>>> = Vec::new();

    // Collect matching segments, sorted by segment_id for stable ordering.
    let mut pairs: Vec<(&String, &crate::app::McpStatusSegment)> = state
        .mcp_status_segments
        .iter()
        .filter(|((vid, _), _)| vid == active)
        .map(|((_, sid), seg)| (sid, seg))
        .collect();
    pairs.sort_by_key(|(sid, _)| sid.as_str());

    for (_, seg) in pairs {
        let color = parse_segment_color(seg.color.as_deref());
        out.push(vec![Span::styled(seg.text.clone(), Style::default().fg(color))]);
    }

    out
}

/// Most recent non-expired toast, if any.
fn toast_segment(state: &AppState) -> Option<Vec<Span<'static>>> {
    let now = Utc::now().timestamp();
    // Find the most recently pushed toast that hasn't expired.
    let toast: Option<&Toast> = state
        .toasts
        .iter()
        .rev()
        .find(|t| t.expires_at > now);

    let toast = toast?;
    let (icon, color) = match toast.level {
        NotifyLevel::Info  => ("ℹ ", theme::SAGE),
        NotifyLevel::Warn  => ("⚠ ", theme::AMBER),
        NotifyLevel::Error => ("✕ ", theme::RED_SWEATER),
    };
    Some(vec![
        Span::styled(icon, Style::default().fg(color)),
        Span::styled(toast.text.clone(), Style::default().fg(theme::FG)),
    ])
}

/// Parse a color string into a ratatui `Color`.
///
/// Accepts named strings (`red`, `amber`, `sage`, `blue`, `muted`) or
/// 6-digit hex with leading `#` (e.g. `#ff8800`).
fn parse_segment_color(s: Option<&str>) -> Color {
    match s {
        None           => theme::FG_MUTED,
        Some("red")    => theme::RED_SWEATER,
        Some("amber")  => theme::AMBER,
        Some("sage")   => theme::SAGE,
        Some("blue")   => Color::Rgb(100, 149, 237),
        Some("muted")  => theme::FG_MUTED,
        Some(hex) if hex.starts_with('#') && hex.len() == 7 => {
            let r = u8::from_str_radix(&hex[1..3], 16).unwrap_or(180);
            let g = u8::from_str_radix(&hex[3..5], 16).unwrap_or(180);
            let b = u8::from_str_radix(&hex[5..7], 16).unwrap_or(180);
            Color::Rgb(r, g, b)
        }
        _ => theme::FG_MUTED,
    }
}

// ── right segment ─────────────────────────────────────────────────────────────

fn right_segment(state: &AppState) -> Vec<Span<'_>> {
    let mut spans: Vec<Span> = Vec::new();
    let now_epoch = Utc::now().timestamp();

    // Posture chip — hidden when Normal.
    if let Some(posture) = &state.budget_posture {
        if *posture != BudgetPosture::Normal {
            spans.push(Span::styled(
                format!("{}  ", posture.label()),
                Style::default().fg(posture.color()),
            ));
        }
    }

    // Rate-limit windows.
    if let Some(rl) = &state.rate_limits {
        let mut rate_parts: Vec<Span> = Vec::new();

        // 5h window.
        if rl.pct_5h >= 0 && rl.reset_5h > now_epoch {
            let secs = rl.reset_5h - now_epoch;
            let t = format_secs(secs);
            let color = pct_color(rl.pct_5h);
            rate_parts.push(Span::styled("5h ", Style::default().fg(theme::FG_MUTED)));
            rate_parts.push(Span::styled(
                format!("{}%", rl.pct_5h),
                Style::default().fg(color),
            ));
            rate_parts.push(Span::styled(
                format!(" · {t}"),
                Style::default().fg(theme::FG_MUTED),
            ));
        }

        // Separator between windows when both are shown.
        let show_5h = rl.pct_5h >= 0 && rl.reset_5h > now_epoch;
        let show_7d = rl.pct_7d >= 0 && rl.reset_7d > now_epoch;

        if show_5h && show_7d {
            rate_parts.push(Span::styled("  ", Style::default()));
        }

        // 7d window.
        if show_7d {
            let secs = rl.reset_7d - now_epoch;
            let t = format_secs(secs);
            let color = pct_color(rl.pct_7d);
            rate_parts.push(Span::styled("7d ", Style::default().fg(theme::FG_MUTED)));
            rate_parts.push(Span::styled(
                format!("{}%", rl.pct_7d),
                Style::default().fg(color),
            ));
            rate_parts.push(Span::styled(
                format!(" · {t}"),
                Style::default().fg(theme::FG_MUTED),
            ));
        }

        if !rate_parts.is_empty() {
            spans.extend(rate_parts);
            spans.push(Span::raw(" "));
        }
    }

    spans
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Format remaining seconds as `Xh` or `Xm`.
fn format_secs(secs: i64) -> String {
    if secs >= 3600 {
        format!("{}h", secs / 3600)
    } else {
        format!("{}m", (secs / 60).max(1))
    }
}

/// Colour for a percentage: <50% green, 50–79% yellow, ≥80% red.
fn pct_color(pct: i32) -> Color {
    if pct >= 80 {
        theme::RED_SWEATER
    } else if pct >= 50 {
        theme::AMBER
    } else {
        theme::SAGE
    }
}
