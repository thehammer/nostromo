//! Teri view: live todo list (left) + embedded PTY REPL (right).

use std::any::Any;

use chrono::{NaiveDate, TimeZone, Utc};
use crossterm::event::{KeyCode, KeyModifiers, MouseEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};
use tokio::sync::watch;

use crate::{
    data::{
        context_usage::{ContextUsage, ContextUsageReader},
        teri_todos::TeriTodosSnapshot,
    },
    event::AppEvent,
    pty::{PtyBackend, PtyWidget},
    transcript::TranscriptPane,
    ui::theme,
    views::{EventOutcome, View, ViewCtx},
};

const TERI_PTY_TAG: &str = "teri";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Pane {
    Todos,
    Repl,
}

pub struct TeriView {
    todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>,
    ctx: ViewCtx,
    pty: Option<PtyBackend>,
    pty_capturing: bool,
    pane_focus: Pane,
    repl_area: Rect,
    repl_scroll: u16,
    todos_selected: usize,
    // ── transcript pane ───────────────────────────────────────────────────────
    /// Transcript overlay (Ctrl+T toggles; shown as right 40% when visible).
    transcript: TranscriptPane,
    /// Last area used to render the transcript (for mouse hit-testing).
    transcript_render_area: Rect,
    // ── context usage ─────────────────────────────────────────────────────────
    _context_usage_reader: Option<ContextUsageReader>,
    context_usage_rx: Option<tokio::sync::watch::Receiver<Option<ContextUsage>>>,
}

impl TeriView {
    pub fn new(todos_rx: watch::Receiver<Option<TeriTodosSnapshot>>, ctx: ViewCtx) -> Self {
        // Attempt to reattach to an existing daemon PTY for this view.
        let mut pty = Self::try_reattach(&ctx);

        // Recover session context for the transcript pane.
        let mut transcript = TranscriptPane::new();
        let store = crate::sessions::SessionStore::load();
        let stored_entry = store.get(TERI_PTY_TAG).cloned();

        // If no live daemon PTY exists, check the session store and auto-spawn.
        if pty.is_none() {
            if let Some(ref entry) = stored_entry {
                let args: Vec<&str> = entry.args.iter().map(String::as_str).collect();
                match ctx.pty_factory.spawn(
                    TERI_PTY_TAG,
                    &entry.cmd,
                    &args,
                    (80, 24),
                    ctx.event_tx.clone(),
                ) {
                    Ok(b) => {
                        tracing::info!(
                            view_tag = TERI_PTY_TAG,
                            "auto-spawned PTY from session store"
                        );
                        pty = Some(b);
                    }
                    Err(e) => {
                        tracing::warn!("session-store auto-spawn failed for {TERI_PTY_TAG}: {e}");
                    }
                }
            }
        }

        // Restore session context for Ctrl+T transcript bring-up.
        let mut init_ctx_reader = None;
        let mut init_ctx_rx = None;
        if let Some(entry) = stored_entry {
            let sid_opt = entry.session_id.clone().or_else(|| {
                entry.cwd.as_deref()
                    .and_then(crate::transcript::find_latest_session_id_for_cwd)
            });
            if let Some(sid) = sid_opt {
                let cwd = entry.cwd
                    .or_else(|| std::env::current_dir().ok())
                    .unwrap_or_else(|| std::path::PathBuf::from("/tmp"));
                transcript.set_session_context(cwd.clone(), sid.clone());
                let (r, rx) = ContextUsageReader::spawn(cwd, sid);
                init_ctx_reader = Some(r);
                init_ctx_rx = Some(rx);
            }
        }

        let pty_capturing = pty.is_some();
        let pane_focus = if pty_capturing {
            Pane::Repl
        } else {
            Pane::Todos
        };

        Self {
            todos_rx,
            ctx,
            pty,
            pty_capturing,
            pane_focus,
            repl_area: Rect::new(0, 0, 80, 24),
            repl_scroll: 0,
            todos_selected: 0,
            transcript,
            transcript_render_area: Rect::default(),
            _context_usage_reader: init_ctx_reader,
            context_usage_rx: init_ctx_rx,
        }
    }

    fn start_context_reader(&mut self, cwd: std::path::PathBuf, session_id: String) {
        let (reader, rx) = ContextUsageReader::spawn(cwd, session_id);
        self._context_usage_reader = Some(reader);
        self.context_usage_rx = Some(rx);
    }

    fn try_reattach(ctx: &ViewCtx) -> Option<PtyBackend> {
        let info = ctx
            .pty_factory
            .list_existing(TERI_PTY_TAG)
            .into_iter()
            .find(|p| p.alive)?;

        tracing::info!(
            pty_id = %info.pty_id,
            view_tag = TERI_PTY_TAG,
            "TeriView reattaching to existing daemon PTY"
        );

        ctx.pty_factory
            .attach(
                &info.pty_id,
                (info.cols, info.rows),
                ctx.event_tx.clone(),
                TERI_PTY_TAG,
            )
            .ok()
    }

    fn render_todos(&mut self, f: &mut Frame, area: Rect) {
        let snap = self.todos_rx.borrow();
        let snap = snap.as_ref();

        let stale = snap.map(|s| s.stale).unwrap_or(false);
        let error = snap.and_then(|s| s.error.as_deref());
        let items_ref = snap.map(|s| s.items.as_slice()).unwrap_or(&[]);

        let focused = self.pane_focus == Pane::Todos;
        let border_color = if focused {
            theme::BORDER_ACTIVE
        } else {
            theme::BORDER_INACTIVE
        };

        let mut title = " Teri Todos ".to_string();
        if stale {
            title.push_str("(stale) ");
        }

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(border_color))
            .title(Span::styled(title, Style::default().fg(theme::FG_MUTED)));

        let inner = block.inner(area);
        f.render_widget(block, area);

        if let Some(err) = error {
            let p = Paragraph::new(Span::styled(
                format!("⚠ {err}"),
                Style::default().fg(theme::UNREAD),
            ));
            f.render_widget(p, inner);
            return;
        }

        if items_ref.is_empty() {
            let lines = vec![
                Line::from(vec![]),
                Line::from(vec![Span::styled(
                    "No active todos",
                    Style::default()
                        .fg(theme::FG_MUTED)
                        .add_modifier(Modifier::DIM),
                )]),
            ];
            let p = Paragraph::new(lines).alignment(Alignment::Center);
            f.render_widget(p, inner);
            return;
        }

        // Clamp selected index.
        if self.todos_selected >= items_ref.len() {
            self.todos_selected = items_ref.len().saturating_sub(1);
        }

        let list_items: Vec<ListItem> = items_ref
            .iter()
            .enumerate()
            .map(|(i, todo)| {
                let priority_style = match todo.priority {
                    1 => Style::default().fg(theme::RED_SWEATER),
                    2 => Style::default().fg(theme::AMBER),
                    4 | 5 => Style::default().add_modifier(Modifier::DIM),
                    _ => Style::default().fg(theme::FG),
                };

                // Build label
                let mut label = format!("[P{}] {}", todo.priority, todo.title);

                if let Some(jira) = &todo.jira_key {
                    label.push_str(&format!("  {jira}"));
                }

                if let Some(due) = &todo.due_date {
                    let due_str = NaiveDate::parse_from_str(due, "%Y-%m-%d")
                        .ok()
                        .and_then(|d| d.and_hms_opt(0, 0, 0))
                        .map(|naive| Utc.from_utc_datetime(&naive))
                        .map(|dt| crate::ui::widgets::relative_time::format_relative_now(&dt))
                        .unwrap_or_else(|| due.clone());
                    label.push_str(&format!("  {due_str}"));
                }

                let mut style = priority_style;
                if focused && i == self.todos_selected {
                    style = style.add_modifier(Modifier::REVERSED);
                }

                ListItem::new(Line::from(Span::styled(label, style)))
            })
            .collect();

        let list = List::new(list_items);
        f.render_widget(list, inner);
    }

    fn render_repl(&mut self, f: &mut Frame, area: Rect) {
        let border_color = if self.pane_focus == Pane::Repl && self.pty_capturing {
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
                " Teri REPL ",
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
                    "[ TERI ]",
                    Style::default()
                        .fg(theme::FG_MUTED)
                        .add_modifier(Modifier::DIM),
                )]),
                Line::from(vec![]),
                Line::from(vec![Span::styled(
                    "Press Enter to start Teri REPL",
                    Style::default().fg(theme::FG_MUTED),
                )]),
            ];
            let p = Paragraph::new(lines).alignment(Alignment::Center);
            f.render_widget(p, inner);
        }
    }
}

impl View for TeriView {
    fn id(&self) -> &'static str {
        "teri"
    }

    fn title(&self) -> &str {
        "Teri"
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        // 40% todos, 60% REPL (when transcript visible, REPL+transcript split 60/40).
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
            .split(area);

        self.render_todos(f, chunks[0]);

        if self.transcript.is_visible() {
            // Split the REPL column 60 (PTY) / 40 (transcript) horizontally.
            let repl_chunks = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
                .split(chunks[1]);
            self.render_repl(f, repl_chunks[0]);
            self.transcript_render_area = repl_chunks[1];
            self.transcript.render(f, repl_chunks[1]);
        } else {
            self.render_repl(f, chunks[1]);
        }

        // Resize PTY if the area changed.
        if let Some(pty) = &mut self.pty {
            let (cols, rows) = (self.repl_area.width, self.repl_area.height);
            pty.resize(cols, rows);
        }
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
        if let AppEvent::Key(k) = ev {
            // Tab (no modifiers) always toggles pane focus.
            if k.code == KeyCode::Tab && k.modifiers == KeyModifiers::NONE {
                self.pane_focus = match self.pane_focus {
                    Pane::Todos => Pane::Repl,
                    Pane::Repl => Pane::Todos,
                };
                self.pty_capturing = self.pane_focus == Pane::Repl && self.pty.is_some();
                return EventOutcome::Consumed;
            }

            // Ctrl+T — toggle transcript pane (nav mode only).
            if k.code == KeyCode::Char('t')
                && k.modifiers == KeyModifiers::CONTROL
                && !self.pty_capturing
            {
                self.transcript.toggle_visible();
                return EventOutcome::Consumed;
            }

            // Transcript navigation when visible and not capturing PTY.
            if self.transcript.is_visible() && !self.pty_capturing && self.transcript.on_key(k) {
                return EventOutcome::Consumed;
            }

            // Scroll keys when a PTY is present (intercept before PTY forwarding).
            if self.pty.is_some() {
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
                } else if self.repl_scroll > 0 && self.pane_focus == Pane::Repl {
                    // Any other key resets to live view in REPL pane.
                    self.repl_scroll = 0;
                }
            }

            // Forward keys to PTY when in REPL pane and capturing.
            if self.pane_focus == Pane::Repl && self.pty_capturing {
                if let Some(pty) = &mut self.pty {
                    pty.send_key(k);
                    return EventOutcome::Consumed;
                }
            }

            // Enter in REPL pane with no PTY: spawn the agent.
            if k.code == KeyCode::Enter && self.pane_focus == Pane::Repl && self.pty.is_none() {
                let sid = uuid::Uuid::new_v4().to_string();
                let sid_clone = sid.clone();
                let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                let args = [
                    "--dangerously-skip-permissions",
                    "--agent",
                    "teri",
                    "--remote-control",
                    "Teri",
                    "-n",
                    "Teri",
                    "--session-id",
                    &sid_clone,
                ];
                match self.ctx.pty_factory.spawn(
                    TERI_PTY_TAG,
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
                        self.transcript.set_session_context(cwd.clone(), sid.clone());
                        self.start_context_reader(cwd.clone(), sid.clone());
                        let mut store = crate::sessions::SessionStore::load();
                        store.record(
                            TERI_PTY_TAG,
                            "claude",
                            &args,
                            Some(cwd),
                            Some(sid),
                        );
                    }
                    Err(e) => {
                        tracing::warn!("failed to spawn PTY for teri: {e}");
                    }
                }
                return EventOutcome::Consumed;
            }

            // Todos navigation when in Todos pane.
            if self.pane_focus == Pane::Todos {
                let snap = self.todos_rx.borrow();
                let count = snap.as_ref().map(|s| s.items.len()).unwrap_or(0);
                drop(snap);

                match k.code {
                    KeyCode::Char('j') | KeyCode::Down => {
                        if count > 0 {
                            self.todos_selected = (self.todos_selected + 1) % count;
                        }
                        return EventOutcome::Consumed;
                    }
                    KeyCode::Char('k') | KeyCode::Up => {
                        if count > 0 {
                            self.todos_selected =
                                self.todos_selected.checked_sub(1).unwrap_or(count - 1);
                        }
                        return EventOutcome::Consumed;
                    }
                    _ => {}
                }
            }
        }

        // Mouse scroll: scroll the REPL (delegate to transcript when visible).
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

    /// Returns `true` whenever this view wants global key handling suppressed.
    ///
    /// In the Todos pane we return `true` so that Tab reaches `on_event` for
    /// pane-switching rather than being consumed as a global view-cycle key.
    /// In the Repl pane we mirror `agent_generic`: true only while PTY is active.
    fn pty_capturing_input(&self) -> bool {
        match self.pane_focus {
            Pane::Todos => true,
            Pane::Repl => self.pty.is_some() && self.pty_capturing,
        }
    }

    fn set_pty_capturing_input(&mut self, capturing: bool) {
        if self.pty.is_some() {
            self.pty_capturing = capturing;
        }
    }

    fn focus(&mut self) {
        self.pane_focus = Pane::Repl;
        self.pty_capturing = self.pty.is_some();
    }

    fn blur(&mut self) {
        self.pty_capturing = false;
    }

    fn toggle_transcript(&mut self) -> bool {
        self.transcript.toggle_visible();
        true
    }

    fn apply_pane_content(
        &mut self,
        pane_id: &str,
        _content: &crate::mcp::command::PaneContent,
    ) -> Result<(), String> {
        match pane_id {
            "todos" | "repl" => Err("readonly_pane".into()),
            _ => Err("unknown_pane".into()),
        }
    }

    fn context_pct(&self) -> Option<f32> {
        self.context_usage_rx
            .as_ref()
            .and_then(|rx| rx.borrow().as_ref().map(|u| u.pct))
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
