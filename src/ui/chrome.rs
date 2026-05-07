//! Tab bar, status bar, and sidebar widgets — shared chrome across all views.

use ratatui::{
    layout::Rect,
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};
use chrono::Local;

use crate::{
    data::{fred_calendar::CalendarSnapshot, fred_mailbox::MailboxSnapshot},
    ui::theme,
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
pub fn render_status_bar(
    f: &mut Frame,
    area: Rect,
    mailbox: Option<&MailboxSnapshot>,
    calendar: Option<&CalendarSnapshot>,
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

    let left = format!(" {time_str}{mail_str}{next_str} ⚙ mother: — ");

    let line = Line::from(Span::styled(left, Style::default().fg(theme::FG_MUTED)));
    let p = Paragraph::new(line).block(
        Block::default()
            .borders(Borders::TOP)
            .border_style(Style::default().fg(theme::BORDER_INACTIVE)),
    );
    f.render_widget(p, bar_area);

    above
}

/// Render chrome and return content area.
pub fn render_chrome(
    f: &mut Frame,
    full_area: Rect,
    titles: &[&str],
    active: usize,
    mailbox: Option<&MailboxSnapshot>,
    calendar: Option<&CalendarSnapshot>,
) -> Rect {
    let after_tabs = render_tab_bar(f, full_area, titles, active);
    render_status_bar(f, after_tabs, mailbox, calendar)
}
