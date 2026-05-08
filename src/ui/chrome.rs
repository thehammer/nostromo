//! Tab bar, status bar, break-glass banner, and sidebar widgets.
//!
//! Phase 5c: sweater-colour status indicators on the tab bar.
//! - Perri tab: amber when open PR count > 5, red when > 10.
//! - Cody and Mother tabs: amber when any Mother job has been running > 15 min.
//! - Split mode: focused-pane view title highlighted; non-focused panes listed dimly.

use ratatui::{
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};
use chrono::{Local, Utc};

use crate::{
    agent_bus::ActivityEvent,
    app::AppState,
    data::{
        break_glass::BreakGlassRequest,
        fred_calendar::CalendarSnapshot,
        fred_mailbox::MailboxSnapshot,
    },
    ui::{theme, widgets::truncate::truncate},
};

// ── sweater helpers ───────────────────────────────────────────────────────────

/// Sweater colour for the Perri tab based on open PR count.
fn perri_sweater_style(open_pr_count: usize) -> Option<Style> {
    if open_pr_count > 10 {
        Some(Style::default().fg(theme::RED_SWEATER))
    } else if open_pr_count > 5 {
        Some(Style::default().fg(theme::AMBER))
    } else {
        None
    }
}

/// True when any Mother job has been running for more than 15 minutes.
fn any_job_over_15_min(state: &AppState) -> bool {
    let threshold = chrono::Duration::minutes(15);
    let now = Utc::now();
    state.mother_jobs.iter().any(|job| {
        if job.state == "running" {
            if let Some(started) = job.started_at {
                return (now - started) > threshold;
            }
        }
        false
    })
}

// ── tab bar ───────────────────────────────────────────────────────────────────

/// Render the top tab bar.  Returns the area below the tab bar.
///
/// `active_pty_capturing` — when `true`, a `●` badge is appended to the
/// active tab label to indicate that the PTY is capturing input.
///
/// `state` is used to compute per-tab sweater-colour indicators and the
/// split-mode pane count badge.
pub fn render_tab_bar(
    f: &mut Frame,
    area: Rect,
    titles: &[&str],
    active: usize,
    active_pty_capturing: bool,
    state: &AppState,
) -> Rect {
    let bar_area = Rect { height: 1, ..area };
    let below = Rect {
        y: area.y + 1,
        height: area.height.saturating_sub(1),
        ..area
    };

    let any_long_job = any_job_over_15_min(state);
    let pane_count = if state.split_mode { state.layout.leaf_count() } else { 0 };

    let mut spans: Vec<Span> = Vec::new();
    for (i, &title) in titles.iter().enumerate() {
        let is_active = i == active;

        // Per-tab sweater colour override.
        let sweater_style: Option<Style> = match title {
            "Perri" => perri_sweater_style(state.perri_open_pr_count),
            "Cody" | "Mother" => {
                if any_long_job {
                    Some(Style::default().fg(theme::AMBER))
                } else {
                    None
                }
            }
            _ => None,
        };

        let label = format!(" {title} ");

        if is_active {
            let base = Style::default()
                .fg(theme::FG)
                .bg(theme::BORDER_ACTIVE)
                .add_modifier(Modifier::BOLD);

            // Apply sweater background colour when the active tab has a status.
            let style = if let Some(sw) = sweater_style {
                base.bg(sw.fg.unwrap_or(theme::BORDER_ACTIVE))
            } else {
                base
            };

            spans.push(Span::styled(label, style));

            if active_pty_capturing {
                spans.push(Span::styled(
                    "● ",
                    Style::default().fg(theme::AMBER).bg(theme::BORDER_ACTIVE),
                ));
            }

            // Split mode: show pane count badge on the active tab.
            if pane_count > 1 {
                let focused_view = state.layout.focused_view_idx(&state.focused_path);
                spans.push(Span::styled(
                    format!("[{}/{}] ", focused_view + 1, pane_count),
                    Style::default().fg(theme::FG_MUTED).bg(theme::BORDER_ACTIVE),
                ));
            }
        } else {
            // Inactive tab: use sweater foreground colour if applicable.
            let style = sweater_style.unwrap_or_else(|| Style::default().fg(theme::FG_MUTED));
            spans.push(Span::styled(label, style));
        }
        spans.push(Span::raw(" "));
    }

    // In split mode, append a dim list of non-active split panes after the tab row.
    if pane_count > 1 {
        spans.push(Span::styled(
            format!(" split:{pane_count} "),
            Style::default().fg(theme::FG_MUTED),
        ));
    }

    let tab_line = Line::from(spans);
    let p = Paragraph::new(tab_line);
    f.render_widget(p, bar_area);

    below
}

// ── status bar ────────────────────────────────────────────────────────────────

/// Render the bottom status bar.  Returns the area above the status bar.
pub fn render_status_bar(
    f: &mut Frame,
    area: Rect,
    mailbox: Option<&MailboxSnapshot>,
    calendar: Option<&CalendarSnapshot>,
    recent_activity: &[ActivityEvent],
    status_note: Option<&str>,
) -> Rect {
    let bar_area = Rect {
        y: area.y + area.height.saturating_sub(1),
        height: 1,
        ..area
    };
    let above = Rect {
        height: area.height.saturating_sub(1),
        ..area
    };

    let time_str = Local::now().format("%H:%M").to_string();

    let unread = mailbox.map(|m| m.unread_count).unwrap_or(0);
    let mail_str = format!(" ✉ {unread} ");

    let next_str = calendar
        .and_then(|c| c.next.as_ref())
        .map(|n| {
            if n.in_minutes <= 0 {
                format!(" ◷ {} (now) ", n.title)
            } else {
                format!(" ◷ {} ({}m) ", n.title, n.in_minutes)
            }
        })
        .unwrap_or_else(|| " ◷ — ".to_string());

    let activity_str = if let Some(note) = status_note {
        format!(" {note} ")
    } else {
        recent_activity
            .last()
            .map(|ev| format!(" ⚙ {}: {} ", ev.agent, ev.summary))
            .unwrap_or_else(|| " ⚙ — ".to_string())
    };

    let left = format!(" {time_str}{mail_str}{next_str}");

    let right_str = if area.width >= 140 {
        let count = recent_activity.len().min(5);
        let events: Vec<String> = recent_activity
            .iter()
            .rev()
            .take(count)
            .map(|ev| format!("{}: {}", ev.agent, truncate(&ev.summary, 20)))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        if events.is_empty() {
            String::new()
        } else {
            format!(" {} ", events.join("  ·  "))
        }
    } else {
        String::new()
    };

    let used = left.len() + right_str.len() + 2;
    let available = (area.width as usize).saturating_sub(used);
    let activity_display = truncate(&activity_str, available.max(6));

    let full_line = if right_str.is_empty() {
        format!("{left}{activity_display}")
    } else {
        let pad = (area.width as usize)
            .saturating_sub(left.len() + activity_display.len() + right_str.len());
        format!("{left}{activity_display}{:>pad$}{right_str}", "", pad = pad)
    };

    let line = Line::from(Span::styled(
        truncate(&full_line, area.width as usize),
        Style::default().fg(theme::FG_MUTED),
    ));
    let p = Paragraph::new(line).block(
        Block::default()
            .borders(Borders::TOP)
            .border_style(Style::default().fg(theme::BORDER_INACTIVE)),
    );
    f.render_widget(p, bar_area);

    above
}

// ── break-glass banner ────────────────────────────────────────────────────────

/// Render a one-row break-glass banner between the tab bar and content area.
///
/// Returns the remaining area below the banner.  If `break_glass` is `None`,
/// returns `area` unchanged (no banner rendered).
pub fn render_break_glass_banner(
    f: &mut Frame,
    area: Rect,
    break_glass: Option<&BreakGlassRequest>,
) -> Rect {
    let req = match break_glass {
        Some(r) => r,
        None => return area,
    };

    let banner_area = Rect { height: 1, ..area };
    let below = Rect {
        y: area.y + 1,
        height: area.height.saturating_sub(1),
        ..area
    };

    let text = format!(
        " ⚠ BREAK-GLASS: {} — press Ctrl-B to review ",
        req.action
    );
    let line = Line::from(Span::styled(
        truncate(&text, area.width as usize),
        Style::default()
            .fg(ratatui::style::Color::Black)
            .bg(theme::RED_SWEATER)
            .add_modifier(Modifier::BOLD),
    ));
    f.render_widget(Paragraph::new(line), banner_area);

    below
}

// ── render_chrome ─────────────────────────────────────────────────────────────

/// Render chrome and return content area.
#[allow(clippy::too_many_arguments)]
pub fn render_chrome(
    f: &mut Frame,
    full_area: Rect,
    titles: &[&str],
    active: usize,
    active_pty_capturing: bool,
    mailbox: Option<&MailboxSnapshot>,
    calendar: Option<&CalendarSnapshot>,
    recent_activity: &[ActivityEvent],
    break_glass: Option<&BreakGlassRequest>,
    status_note: Option<&str>,
    state: &AppState,
) -> Rect {
    let after_tabs = render_tab_bar(f, full_area, titles, active, active_pty_capturing, state);
    let after_banner = render_break_glass_banner(f, after_tabs, break_glass);
    render_status_bar(f, after_banner, mailbox, calendar, recent_activity, status_note)
}
