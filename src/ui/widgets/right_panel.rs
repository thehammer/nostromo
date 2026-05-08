//! Right-panel widget — renders a `RightPanelSnapshot` into a vertical stack.

use chrono::Local;
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};

use crate::{data::right_panel_source::RightPanelSnapshot, ui::theme};

/// Render the right-panel context sidebar into `area`.
pub fn render(f: &mut Frame, area: Rect, snap: &RightPanelSnapshot) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(theme::BORDER_INACTIVE))
        .title(Span::styled(
            " Context ",
            Style::default()
                .fg(theme::FG_MUTED)
                .add_modifier(Modifier::BOLD),
        ));
    let inner = block.inner(area);
    f.render_widget(block, area);

    // Split vertically: task title | recent tools | open files | footer
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // task title
            Constraint::Min(3),    // recent tools
            Constraint::Min(3),    // open files
            Constraint::Length(1), // last-activity timestamp
        ])
        .split(inner);

    // Task title
    let title_block = Block::default()
        .borders(Borders::BOTTOM)
        .border_style(Style::default().fg(theme::BORDER_INACTIVE))
        .title(Span::styled(" Task ", Style::default().fg(theme::FG_MUTED)));
    let title_inner = title_block.inner(chunks[0]);
    f.render_widget(title_block, chunks[0]);
    let title_text = if snap.task_title.is_empty() {
        "—".to_string()
    } else {
        snap.task_title.clone()
    };
    f.render_widget(
        Paragraph::new(title_text).style(Style::default().fg(theme::FG)),
        title_inner,
    );

    // Recent tools
    let tools_block = Block::default()
        .borders(Borders::BOTTOM)
        .border_style(Style::default().fg(theme::BORDER_INACTIVE))
        .title(Span::styled(" Tools ", Style::default().fg(theme::FG_MUTED)));
    let tools_inner = tools_block.inner(chunks[1]);
    f.render_widget(tools_block, chunks[1]);
    let tool_items: Vec<ListItem> = if snap.recent_tools.is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "—",
            Style::default().fg(theme::FG_MUTED),
        )))]
    } else {
        snap.recent_tools
            .iter()
            .map(|t| {
                ListItem::new(Line::from(Span::styled(
                    t.as_str(),
                    Style::default().fg(theme::SAGE),
                )))
            })
            .collect()
    };
    f.render_widget(List::new(tool_items), tools_inner);

    // Open files
    let files_block = Block::default()
        .borders(Borders::BOTTOM)
        .border_style(Style::default().fg(theme::BORDER_INACTIVE))
        .title(Span::styled(" Files ", Style::default().fg(theme::FG_MUTED)));
    let files_inner = files_block.inner(chunks[2]);
    f.render_widget(files_block, chunks[2]);
    let file_items: Vec<ListItem> = if snap.open_files.is_empty() {
        vec![ListItem::new(Line::from(Span::styled(
            "—",
            Style::default().fg(theme::FG_MUTED),
        )))]
    } else {
        snap.open_files
            .iter()
            .map(|f| {
                // Show only the last path component to save space.
                let name = std::path::Path::new(f)
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or(f.as_str());
                ListItem::new(Line::from(Span::styled(
                    name,
                    Style::default().fg(theme::AMBER),
                )))
            })
            .collect()
    };
    f.render_widget(List::new(file_items), files_inner);

    // Last-activity footer
    let local = snap.last_activity.with_timezone(&Local);
    let ts_str = local.format("%H:%M:%S").to_string();
    let tokens_str = if snap.total_tokens > 0 {
        format!(" {ts_str}  {tok}tok", tok = snap.total_tokens)
    } else {
        format!(" {ts_str}")
    };
    f.render_widget(
        Paragraph::new(tokens_str).style(Style::default().fg(theme::FG_MUTED)),
        chunks[3],
    );
}
