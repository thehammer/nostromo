//! Generic agent view — status header + embedded PTY REPL.
//!
//! Used for Claudia, Cody, Kennedy, Mother, and any future agent that doesn't
//! yet have a dedicated view layout.

use std::any::Any;

use crossterm::event::{KeyCode, KeyModifiers, MouseEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph},
    Frame,
};

use crate::{
    event::AppEvent,
    pty::{PtyBackend, PtyWidget},
    transcript::TranscriptPane,
    ui::theme,
    views::{EventOutcome, View, ViewCtx},
};

pub struct GenericView {
    id: &'static str,
    title: &'static str,
    ctx: ViewCtx,
    pty: Option<PtyBackend>,
    /// Whether the PTY is currently capturing keystrokes.
    pty_capturing: bool,
    /// Last known inner area of the REPL pane, used for PTY sizing.
    repl_area: Rect,
    /// Rows scrolled back in the REPL pane (0 = live view).
    repl_scroll: u16,
    // ── transcript pane ───────────────────────────────────────────────────────
    /// Transcript overlay (Ctrl+T toggles; shown as right 50% when visible).
    transcript: TranscriptPane,
    /// Last area used to render the transcript (for mouse hit-testing).
    transcript_render_area: Rect,
}

impl GenericView {
    pub fn new(id: &'static str, title: &'static str, ctx: ViewCtx) -> Self {
        // Attempt to reattach to an existing daemon PTY for this view.
        let mut pty = Self::try_reattach(id, &ctx);

        // Recover session context for the transcript pane.
        let mut transcript = TranscriptPane::new();
        let store = crate::sessions::SessionStore::load();
        let stored_entry = store.get(id).cloned();

        // If no live daemon PTY exists, check the session store and auto-spawn.
        if pty.is_none() {
            if let Some(ref entry) = stored_entry {
                let (cols, rows) = (80u16, 24u16);
                let args: Vec<&str> = entry.args.iter().map(String::as_str).collect();
                match ctx.pty_factory.spawn(
                    id,
                    &entry.cmd,
                    &args,
                    (cols, rows),
                    ctx.event_tx.clone(),
                ) {
                    Ok(backend) => {
                        tracing::info!(view_tag = id, "auto-spawned PTY from session store");
                        pty = Some(backend);
                    }
                    Err(e) => {
                        tracing::warn!("session-store auto-spawn failed for {id}: {e}");
                    }
                }
            }
        }

        // Restore session context for Ctrl+T transcript bring-up.
        if let Some(entry) = stored_entry {
            let sid_opt = entry.session_id.clone().or_else(|| {
                entry
                    .cwd
                    .as_deref()
                    .and_then(crate::transcript::find_latest_session_id_for_cwd)
            });
            if let Some(sid) = sid_opt {
                let cwd = entry
                    .cwd
                    .or_else(|| std::env::current_dir().ok())
                    .unwrap_or_else(|| std::path::PathBuf::from("/tmp"));
                transcript.set_session_context(cwd, sid);
            }
        }

        let pty_capturing = pty.is_some();

        Self {
            id,
            title,
            ctx,
            pty,
            pty_capturing,
            repl_area: Rect::new(0, 0, 80, 24),
            repl_scroll: 0,
            transcript,
            transcript_render_area: Rect::default(),
        }
    }

    /// Reattach to a live daemon PTY if one exists for this view's tag.
    fn try_reattach(view_tag: &'static str, ctx: &ViewCtx) -> Option<PtyBackend> {
        let existing = ctx.pty_factory.list_existing(view_tag);
        let info = existing.into_iter().find(|p| p.alive)?;

        tracing::info!(
            pty_id = %info.pty_id,
            view_tag,
            "GenericView reattaching to existing daemon PTY"
        );

        ctx.pty_factory
            .attach(
                &info.pty_id,
                (info.cols, info.rows),
                ctx.event_tx.clone(),
                view_tag,
            )
            .ok()
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

        self.repl_area = inner;

        if let Some(pty) = &self.pty {
            let parser = pty.parser();
            let guard = parser.lock().unwrap();
            f.render_widget(PtyWidget::new(guard, self.repl_scroll), inner);
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
        if self.transcript.is_visible() {
            // 50/50 split: REPL on left, transcript on right.
            let cols = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
                .split(area);
            self.render_repl(f, cols[0]);
            self.transcript_render_area = cols[1];
            self.transcript.render(f, cols[1]);
        } else {
            self.transcript_render_area = Rect::default();
            self.render_repl(f, area);
        }

        // Resize PTY if the area changed.
        if let Some(pty) = &mut self.pty {
            let (cols, rows) = (self.repl_area.width.max(1), self.repl_area.height.max(1));
            pty.resize(cols, rows);
        }
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
        // Intercept scroll keys when a PTY pane is present, before forwarding
        // to the PTY. This lets users scroll the REPL history even while
        // capturing is active.
        if self.pty.is_some() {
            if let AppEvent::Key(k) = ev {
                let scroll_up = k.code == KeyCode::PageUp
                    || (k.code == KeyCode::Up && k.modifiers.contains(KeyModifiers::SHIFT));
                let scroll_down = k.code == KeyCode::PageDown
                    || (k.code == KeyCode::Down && k.modifiers.contains(KeyModifiers::SHIFT));

                if scroll_up {
                    self.repl_scroll = self.repl_scroll.saturating_add(self.repl_area.height / 2);
                    return EventOutcome::Consumed;
                } else if scroll_down {
                    self.repl_scroll = self.repl_scroll.saturating_sub(self.repl_area.height / 2);
                    return EventOutcome::Consumed;
                } else if self.repl_scroll > 0 {
                    // Any other key resets to live view and falls through.
                    self.repl_scroll = 0;
                }
            }
        }

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
            // Ctrl+T — toggle transcript pane (nav mode only).
            if k.code == KeyCode::Char('t')
                && k.modifiers == KeyModifiers::CONTROL
                && !self.pty_capturing
            {
                self.transcript.toggle_visible();
                return EventOutcome::Consumed;
            }

            // Transcript navigation keys when visible and not in PTY.
            if self.transcript.is_visible() && !self.pty_capturing && self.transcript.on_key(k) {
                return EventOutcome::Consumed;
            }

            if k.code == KeyCode::Enter && self.pty.is_none() {
                let sid = uuid::Uuid::new_v4().to_string();
                let sid_clone = sid.clone();
                let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                let args = [
                    "--dangerously-skip-permissions",
                    "--agent",
                    self.id,
                    "--remote-control",
                    self.title,
                    "-n",
                    self.title,
                    "--session-id",
                    &sid_clone,
                ];
                match self.ctx.pty_factory.spawn(
                    self.id,
                    "claude",
                    &args,
                    (cols, rows),
                    self.ctx.event_tx.clone(),
                ) {
                    Ok(backend) => {
                        self.pty = Some(backend);
                        self.pty_capturing = true;
                        let cwd = std::env::current_dir()
                            .unwrap_or_else(|_| std::path::PathBuf::from("/tmp"));
                        self.transcript
                            .set_session_context(cwd.clone(), sid.clone());
                        let mut store = crate::sessions::SessionStore::load();
                        store.record(self.id, "claude", &args, Some(cwd), Some(sid));
                    }
                    Err(e) => {
                        tracing::warn!("failed to spawn PTY for {}: {e}", self.id);
                    }
                }
                return EventOutcome::Consumed;
            }
        }

        // Mouse events: delegate to transcript first, then scroll the REPL.
        if let AppEvent::Mouse(m) = ev {
            if self.transcript.is_visible()
                && self.transcript.on_mouse(m, self.transcript_render_area)
            {
                return EventOutcome::Consumed;
            }

            match m.kind {
                MouseEventKind::ScrollUp => {
                    if let Some(pty) = &mut self.pty {
                        let key = crossterm::event::KeyEvent::new(
                            crossterm::event::KeyCode::PageUp,
                            crossterm::event::KeyModifiers::NONE,
                        );
                        pty.send_key(&key);
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if let Some(pty) = &mut self.pty {
                        let key = crossterm::event::KeyEvent::new(
                            crossterm::event::KeyCode::PageDown,
                            crossterm::event::KeyModifiers::NONE,
                        );
                        pty.send_key(&key);
                    }
                    return EventOutcome::Consumed;
                }
                _ => {}
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

    fn toggle_transcript(&mut self) -> bool {
        self.transcript.toggle_visible();
        true
    }

    fn jump_to_latest_turn(&mut self) -> bool {
        self.transcript.open_and_jump_to_latest()
    }

    fn apply_pane_content(
        &mut self,
        pane_id: &str,
        _content: &crate::mcp::command::PaneContent,
    ) -> Result<(), String> {
        match pane_id {
            "repl" => Err("readonly_pane".into()),
            _ => Err("unknown_pane".into()),
        }
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
