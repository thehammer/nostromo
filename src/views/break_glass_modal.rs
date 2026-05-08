//! Break-glass modal.
//!
//! Shown when `$HOME/.nostromo/break-glass.json` exists.  The operator can
//! confirm (`y`) or deny (`n`) the proposed action; nostromo writes the
//! response to `$HOME/.nostromo/break-glass.response` and removes the sentinel.

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::Style,
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};

use crate::{
    data::break_glass::BreakGlassRequest,
    ui::{theme, widgets::modal},
    views::EventOutcome,
};

/// Break-glass modal state.
pub struct BreakGlassModal {
    pub request: BreakGlassRequest,
}

/// Action returned by `BreakGlassModal::on_key`.
#[derive(Debug, Clone)]
pub enum BreakGlassAction {
    Consumed,
    /// Operator confirmed the action.
    Confirm,
    /// Operator denied the action.
    Deny,
    /// Operator dismissed without deciding.
    Dismiss,
}

impl BreakGlassModal {
    pub fn new(request: BreakGlassRequest) -> Self {
        Self { request }
    }

    pub fn on_key(&self, k: &crossterm::event::KeyEvent) -> BreakGlassAction {
        use crossterm::event::KeyCode;
        match k.code {
            KeyCode::Char('y') | KeyCode::Char('Y') => BreakGlassAction::Confirm,
            KeyCode::Char('n') | KeyCode::Char('N') => BreakGlassAction::Deny,
            KeyCode::Esc => BreakGlassAction::Dismiss,
            _ => BreakGlassAction::Consumed,
        }
    }

    pub fn render(&self, f: &mut Frame, area: Rect) {
        let overlay = modal::centered(60, 50, area);
        let inner = modal::clear_and_block(f, overlay, "⚠ Break-Glass Request");

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(1), // action
                Constraint::Min(3),    // summary
                Constraint::Length(1), // timestamp
                Constraint::Length(1), // spacer
                Constraint::Length(1), // hint
            ])
            .split(inner);

        // Action line
        let action_line = Line::from(vec![
            Span::styled("Action: ", Style::default().fg(theme::FG_MUTED)),
            Span::styled(
                &self.request.action,
                Style::default().fg(theme::RED_SWEATER),
            ),
        ]);
        f.render_widget(Paragraph::new(action_line), chunks[0]);

        // Summary
        f.render_widget(
            Paragraph::new(self.request.summary.as_str())
                .style(Style::default().fg(theme::FG))
                .wrap(ratatui::widgets::Wrap { trim: false }),
            chunks[1],
        );

        // Timestamp
        use chrono::Local;
        let ts = self
            .request
            .requested_at
            .with_timezone(&Local)
            .format("%Y-%m-%d %H:%M:%S")
            .to_string();
        let ts_line = Line::from(Span::styled(
            format!("Requested: {ts}"),
            Style::default().fg(theme::FG_MUTED),
        ));
        f.render_widget(Paragraph::new(ts_line), chunks[2]);

        // Hint
        let hint = Line::from(vec![
            Span::styled("[y] ", Style::default().fg(theme::SAGE)),
            Span::styled("confirm  ", Style::default().fg(theme::FG_MUTED)),
            Span::styled("[n] ", Style::default().fg(theme::RED_SWEATER)),
            Span::styled("deny  ", Style::default().fg(theme::FG_MUTED)),
            Span::styled("[esc] ", Style::default().fg(theme::FG_MUTED)),
            Span::styled("dismiss", Style::default().fg(theme::FG_MUTED)),
        ]);
        f.render_widget(Paragraph::new(hint), chunks[4]);
    }
}

/// Confirm-modal for simple yes/no prompts (cancel, retry).
pub struct ConfirmModal {
    pub prompt: String,
}

pub enum ConfirmAction {
    Consumed,
    Yes,
    No,
    Dismiss,
}

impl ConfirmModal {
    pub fn new(prompt: impl Into<String>) -> Self {
        Self {
            prompt: prompt.into(),
        }
    }

    pub fn on_key(&self, k: &crossterm::event::KeyEvent) -> ConfirmAction {
        use crossterm::event::KeyCode;
        match k.code {
            KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => ConfirmAction::Yes,
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => ConfirmAction::No,
            _ => ConfirmAction::Consumed,
        }
    }

    pub fn render(&self, f: &mut Frame, area: Rect) {
        let overlay = modal::centered(50, 30, area);
        let inner = modal::clear_and_block(f, overlay, "Confirm");

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Min(2), Constraint::Length(1)])
            .split(inner);

        f.render_widget(
            Paragraph::new(self.prompt.as_str())
                .style(Style::default().fg(theme::FG))
                .wrap(ratatui::widgets::Wrap { trim: false }),
            chunks[0],
        );

        let hint = Line::from(vec![
            Span::styled("[y/Enter] ", Style::default().fg(theme::SAGE)),
            Span::styled("yes  ", Style::default().fg(theme::FG_MUTED)),
            Span::styled("[n/Esc] ", Style::default().fg(theme::RED_SWEATER)),
            Span::styled("no", Style::default().fg(theme::FG_MUTED)),
        ]);
        f.render_widget(Paragraph::new(hint), chunks[1]);
    }
}

#[allow(dead_code)]
pub fn consumed() -> EventOutcome {
    EventOutcome::Consumed
}
