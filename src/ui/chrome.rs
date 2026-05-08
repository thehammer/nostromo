//! Tab bar, status bar, break-glass banner, and sidebar widgets.

use ratatui::{
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};
use chrono::Local;

use crate::{
    agent_bus::ActivityEvent,
    data::{
        break_glass::BreakGlassRequest,
        fred_calendar::CalendarSnapshot,
        fred_mailbox::MailboxSnapshot,
    },
    ui::{theme, widgets::truncate::truncate},
};

/// Render the top tab bar.  Returns the area below the tab bar.
pub fn render_tab_bar(
    f: &mut Frame,
    area: Rect,
    titles: &[&str],
    active: usize,
) -> Rect {
    let bar_area = Rect { height: 1, ..area };
    let below = Rect {
        y: area.y + 1,
        height: area.height.saturating_sub(1),
        ..area
    };

    let mut spans: Vec<Span> = Vec::new();
    for (i, &title) in titles.iter().enumerate() {
        let label = format!(" {title} ");
        if i == active {
            spans.push(Span::styled(
                label,
                Style::default()
                    .fg(theme::FG)
                    .bg(theme::BORDER_ACTIVE)
                    .add_modifier(Modifier::BOLD),
            ));
        } else {
            spans.push(Span::styled(label, Style::default().fg(theme::FG_MUTED)));
        }
        spans.push(Span::raw(" "));
    }

    let tab_line = Line::from(spans);
    let p = Paragraph::new(tab_line);
    f.render_widget(p, bar_area);

    below
}

/// Render the bottom status bar.  Returns the area above the status bar.
///
/// `recent_activity` is a slice of the latest `ActivityEvent`s from the bus
/// (newest last).  The most recent event is shown in the centre of the bar;
/// when the terminal is ≥ 140 cols wide the previous four events appear on
/// the right side.
///
/// `status_note` is an optional one-shot note (e.g. "retry unavailable") shown
/// in the status bar when present.
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

    // Centre content: prefer status_note when set, otherwise most-recent activity.
    let activity_str = if let Some(note) = status_note {
        format!(" {note} ")
    } else {
        recent_activity
            .last()
            .map(|ev| format!(" ⚙ {}: {} ", ev.agent, ev.summary))
            .unwrap_or_else(|| " ⚙ — ".to_string())
    };

    let left = format!(" {time_str}{mail_str}{next_str}");

    // Right-side: up to last 5 events when terminal is wide enough.
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

    // Build the status line, fitting activity into remaining space.
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

/// Render chrome and return content area.
#[allow(clippy::too_many_arguments)]
pub fn render_chrome(
    f: &mut Frame,
    full_area: Rect,
    titles: &[&str],
    active: usize,
    mailbox: Option<&MailboxSnapshot>,
    calendar: Option<&CalendarSnapshot>,
    recent_activity: &[ActivityEvent],
    break_glass: Option<&BreakGlassRequest>,
    status_note: Option<&str>,
) -> Rect {
    let after_tabs = render_tab_bar(f, full_area, titles, active);
    let after_banner = render_break_glass_banner(f, after_tabs, break_glass);
    render_status_bar(f, after_banner, mailbox, calendar, recent_activity, status_note)
}
