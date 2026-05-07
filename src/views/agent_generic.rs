//! Generic agent view — status header + REPL placeholder.
//!
//! Used for Claudia, Cody, Kennedy, Mother, and any future agent that doesn't
//! yet have a dedicated view layout.

use std::any::Any;

use ratatui::{
    layout::{Alignment, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};

use crate::{
    event::AppEvent,
    ui::theme,
    views::{EventOutcome, View},
};

pub struct GenericView {
    id: &'static str,
    title: &'static str,
}

impl GenericView {
    pub fn new(id: &'static str, title: &'static str) -> Self {
        Self { id, title }
    }
}

impl View for GenericView {
    fn id(&self) -> &'static str {
        self.id
    }

    fn title(&self) -> &str {
        self.title
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(theme::BORDER_INACTIVE))
            .title(Span::styled(
                format!(" {} ", self.title),
                Style::default()
                    .fg(theme::FG)
                    .add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        let lines = vec![
            Line::from(vec![]),
            Line::from(vec![Span::styled(
                format!("[ {} ]", self.title.to_uppercase()),
                Style::default()
                    .fg(theme::FG_MUTED)
                    .add_modifier(Modifier::DIM),
            )]),
            Line::from(vec![]),
            Line::from(vec![Span::styled(
                "Press Enter to launch agent REPL",
                Style::default().fg(theme::FG_MUTED),
            )]),
            Line::from(vec![]),
            Line::from(vec![Span::styled(
                "(embedded PTY: phase 2)",
                Style::default()
                    .fg(theme::FG_MUTED)
                    .add_modifier(Modifier::DIM),
            )]),
        ];

        let p = Paragraph::new(lines).alignment(Alignment::Center);
        f.render_widget(p, inner);
    }

    fn on_event(&mut self, _ev: &AppEvent) -> EventOutcome {
        EventOutcome::Ignored
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
