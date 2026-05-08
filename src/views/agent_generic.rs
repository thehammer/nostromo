//! Generic agent view — status header + embedded PTY REPL.
//!
//! Used for Claudia, Cody, Kennedy, Mother, and any future agent that doesn't
//! yet have a dedicated view layout.

use std::any::Any;

use crossterm::event::KeyCode;
use ratatui::{
    layout::{Alignment, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};

use crate::{
    event::AppEvent,
    pty::{PtyHost, PtyWidget},
    ui::theme,
    views::{EventOutcome, View, ViewCtx},
};

pub struct GenericView {
    id: &'static str,
    title: &'static str,
    ctx: ViewCtx,
    pty: Option<PtyHost>,
    /// Whether the PTY is currently capturing keystrokes.
    pty_capturing: bool,
    /// Last known inner area of the REPL pane, used for PTY sizing.
    repl_area: Rect,
}

impl GenericView {
    pub fn new(id: &'static str, title: &'static str, ctx: ViewCtx) -> Self {
        Self {
            id,
            title,
            ctx,
            pty: None,
            pty_capturing: false,
            repl_area: Rect::new(0, 0, 80, 24),
        }
    }

    fn render_repl(&mut self, f: &mut Frame, area: Rect) {
        let border_color = if self.pty_capturing {
            theme::BORDER_ACTIVE
        } else if self.pty.is_some() {
            theme::AMBER
        } else {
            theme::BORDER_INACTIVE
        };
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(border_color))
            .title(Span::styled(
                format!(" {} REPL ", self.title),
                Style::default().fg(theme::FG_MUTED),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        // Remember the inner area for PTY spawn sizing and resize.
        self.repl_area = inner;

        if let Some(pty) = &self.pty {
            let guard = pty.parser.lock().unwrap();
            f.render_widget(PtyWidget::new(guard), inner);
        } else {
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
                    "Press Enter to start agent REPL",
                    Style::default().fg(theme::FG_MUTED),
                )]),
            ];
            let p = Paragraph::new(lines).alignment(Alignment::Center);
            f.render_widget(p, inner);
        }
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
        self.render_repl(f, area);

        // Resize PTY if the area changed.
        if let Some(pty) = &mut self.pty {
            let (cols, rows) = (self.repl_area.width, self.repl_area.height);
            pty.resize(cols, rows);
        }
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
        // Forward keys to the PTY only when it is active and capturing input.
        if self.pty_capturing {
            if let Some(pty) = &mut self.pty {
                if let AppEvent::Key(k) = ev {
                    pty.send_key(k);
                    return EventOutcome::Consumed;
                }
            }
        }

        if let AppEvent::Key(k) = ev {
            if k.code == KeyCode::Enter && self.pty.is_none() {
                let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                match PtyHost::spawn(
                    "claude",
                    &["--agent", self.id],
                    (cols, rows),
                    self.ctx.event_tx.clone(),
                    self.id,
                ) {
                    Ok(host) => {
                        self.pty = Some(host);
                        self.pty_capturing = true;
                    }
                    Err(e) => {
                        tracing::warn!("failed to spawn PTY for {}: {e}", self.id);
                    }
                }
                return EventOutcome::Consumed;
            }
        }

        EventOutcome::Ignored
    }

    fn on_resize(&mut self, _area: Rect) {
        if let Some(pty) = &mut self.pty {
            let (cols, rows) = (self.repl_area.width.max(1), self.repl_area.height.max(1));
            pty.resize(cols, rows);
        }
    }

    fn pty_capturing_input(&self) -> bool {
        self.pty.is_some() && self.pty_capturing
    }

    fn set_pty_capturing_input(&mut self, capturing: bool) {
        if self.pty.is_some() {
            self.pty_capturing = capturing;
        }
    }

    fn focus(&mut self) {
        if self.pty.is_some() {
            self.pty_capturing = true;
        }
    }

    fn blur(&mut self) {
        self.pty_capturing = false;
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
