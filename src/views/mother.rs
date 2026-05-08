//! Mother queue view — live dashboard for Mother's job queue.
//!
//! Layout:
//!   - Row 0: Four-quadrant counts strip (running / queued / failed / awaiting)
//!   - Below: Left list (grouped by state) + right detail pane (metadata + log tail)
//!
//! Keybindings:
//!   - `↑/↓` — navigate job list
//!   - `Enter` — focus log tail, scroll with PgUp/PgDn
//!   - `d` — cancel selected job (app opens confirm modal)
//!   - `r` — retry failed job (app opens confirm modal)
//!   - `a` — open await modal for awaiting job
//!   - `Esc` — unfocus log tail

use std::any::Any;
use std::sync::{Arc, Mutex};

use crossterm::event::KeyCode;
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Scrollbar, ScrollbarOrientation,
               ScrollbarState, Wrap},
    Frame,
};
use tracing::debug;

use crate::{
    event::AppEvent,
    mother::{self, MotherJob, MotherStatus},
    ui::theme,
    views::{EventOutcome, View, ViewCtx},
};

// ── action signalling ─────────────────────────────────────────────────────────

/// Actions requested by MotherView that must be handled at the app level
/// (because they open modals whose state lives on AppState).
#[derive(Debug, Clone)]
pub enum MotherAction {
    /// `d` on any non-terminal job — confirm then cancel.
    CancelJob(MotherJob),
    /// `r` on a failed job — confirm then re-add plan.
    RetryJob(MotherJob),
    /// `a` on an awaiting job — open await modal.
    OpenAwaitModal(MotherJob),
}

// ── view ──────────────────────────────────────────────────────────────────────

/// Focus sub-state within the Mother view.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Focus {
    List,
    LogTail,
}

pub struct MotherView {
    /// Current known job list (updated from `MotherJobs` events).
    jobs: Vec<MotherJob>,
    /// Flat ordered list of job IDs in display order (awaiting, running, queued, succeeded, failed).
    display_order: Vec<String>,
    /// Index into `display_order`.
    selected: usize,
    /// Cached status counts (from `MotherStatusline` events).
    pub status: MotherStatus,
    /// Most-recent log tail for the selected job (populated async).
    log_text: Arc<Mutex<String>>,
    /// Scroll offset within the log tail.
    log_scroll: usize,
    /// Which sub-section has focus.
    focus: Focus,
    /// Last job-id we fetched the log for (avoid redundant fetches).
    last_log_id: Option<String>,
    /// Pending action to be consumed by the app event loop.
    pending_action: Option<MotherAction>,
    #[allow(dead_code)]
    ctx: ViewCtx,
}

impl MotherView {
    pub fn new(_config: crate::config::Config, ctx: ViewCtx) -> Self {
        Self {
            jobs: Vec::new(),
            display_order: Vec::new(),
            selected: 0,
            status: MotherStatus::default(),
            log_text: Arc::new(Mutex::new(String::new())),
            log_scroll: 0,
            focus: Focus::List,
            last_log_id: None,
            pending_action: None,
            ctx,
        }
    }

    /// Consume and return any pending app-level action.
    pub fn take_action(&mut self) -> Option<MotherAction> {
        self.pending_action.take()
    }

    /// Return the job currently under the cursor (if any).
    pub fn selected_job(&self) -> Option<&MotherJob> {
        let id = self.display_order.get(self.selected)?;
        self.jobs.iter().find(|j| &j.id == id)
    }

    // ── update ────────────────────────────────────────────────────────────────

    fn update_jobs(&mut self, jobs: Vec<MotherJob>) {
        self.jobs = jobs;
        self.rebuild_display_order();
        // Clamp selection.
        if !self.display_order.is_empty() {
            self.selected = self.selected.min(self.display_order.len() - 1);
        } else {
            self.selected = 0;
        }
    }

    fn rebuild_display_order(&mut self) {
        let mut order: Vec<String> = Vec::new();

        for state in ["awaiting", "running", "ready", "queued"] {
            let mut group: Vec<&MotherJob> = self
                .jobs
                .iter()
                .filter(|j| j.state == state)
                .collect();
            group.sort_by(|a, b| b.created_at.cmp(&a.created_at));
            order.extend(group.iter().map(|j| j.id.clone()));
        }

        // Recent succeeded (last 10, newest first).
        let mut succeeded: Vec<&MotherJob> = self
            .jobs
            .iter()
            .filter(|j| j.is_succeeded())
            .collect();
        succeeded.sort_by(|a, b| b.finished_at.cmp(&a.finished_at));
        order.extend(succeeded.iter().take(10).map(|j| j.id.clone()));

        // Recent failed (last 10, newest first).
        let mut failed: Vec<&MotherJob> = self
            .jobs
            .iter()
            .filter(|j| j.is_failed())
            .collect();
        failed.sort_by(|a, b| b.finished_at.cmp(&a.finished_at));
        order.extend(failed.iter().take(10).map(|j| j.id.clone()));

        self.display_order = order;
    }

    // ── log fetch ─────────────────────────────────────────────────────────────

    fn maybe_fetch_log(&mut self) {
        let id = match self.selected_job().map(|j| j.id.clone()) {
            Some(id) => id,
            None => return,
        };

        if self.last_log_id.as_deref() == Some(&id) {
            return; // already have it / fetching it
        }
        self.last_log_id = Some(id.clone());

        let log_text = Arc::clone(&self.log_text);
        tokio::spawn(async move {
            match mother::tail_log(&id, 30).await {
                Ok(text) => {
                    *log_text.lock().unwrap() = text;
                }
                Err(e) => {
                    debug!("tail_log error for {id}: {e:#}");
                    *log_text.lock().unwrap() =
                        format!("(log unavailable: {e})");
                }
            }
        });
    }

    fn refresh_log_for_running(&mut self) {
        let is_running = self
            .selected_job()
            .map(|j| j.state == "running")
            .unwrap_or(false);
        if is_running {
            self.last_log_id = None; // force re-fetch
            self.maybe_fetch_log();
        }
    }

    // ── render helpers ────────────────────────────────────────────────────────

    fn render_counts_strip(&self, f: &mut Frame, area: Rect) {
        let chunks = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Ratio(1, 4),
                Constraint::Ratio(1, 4),
                Constraint::Ratio(1, 4),
                Constraint::Ratio(1, 4),
            ])
            .split(area);

        let cells = [
            ("Running", self.status.running, theme::SAGE),
            ("Queued",  self.status.queued,  theme::AMBER),
            ("Failed",  self.status.failed,  theme::RED_SWEATER),
            ("Awaiting",self.status.awaiting, theme::RED_SWEATER),
        ];

        for (i, (label, count, color)) in cells.iter().enumerate() {
            let active = *count > 0;
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(if active { *color } else { theme::BORDER_INACTIVE }));
            let inner = block.inner(chunks[i]);
            f.render_widget(block, chunks[i]);

            let count_span = Span::styled(
                format!("{count}"),
                Style::default()
                    .fg(if active { *color } else { theme::FG_MUTED })
                    .add_modifier(Modifier::BOLD),
            );
            let label_span = Span::styled(
                format!(" {label}"),
                Style::default().fg(theme::FG_MUTED),
            );
            let line = Line::from(vec![count_span, label_span]);
            f.render_widget(Paragraph::new(line), inner);
        }
    }

    fn render_job_list(&self, f: &mut Frame, area: Rect) {
        let focused = self.focus == Focus::List;
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if focused {
                theme::BORDER_ACTIVE
            } else {
                theme::BORDER_INACTIVE
            }))
            .title(Span::styled(" Jobs ", Style::default().fg(theme::FG_MUTED)));
        let inner = block.inner(area);
        f.render_widget(block, area);

        if self.display_order.is_empty() {
            f.render_widget(
                Paragraph::new(Span::styled(
                    " (no jobs)",
                    Style::default().fg(theme::FG_MUTED),
                )),
                inner,
            );
            return;
        }

        let items: Vec<ListItem> = self
            .display_order
            .iter()
            .enumerate()
            .filter_map(|(i, id)| {
                let job = self.jobs.iter().find(|j| &j.id == id)?;
                let (color, glyph) = state_style(&job.state);
                let is_sel = i == self.selected;

                let title_str = if job.title.is_empty() {
                    job.id.as_str()
                } else {
                    job.title.as_str()
                };
                // Truncate title to fit.
                let title = crate::ui::widgets::truncate::truncate(title_str, 40);

                let mut line_spans = vec![
                    Span::styled(format!("{glyph} "), Style::default().fg(color)),
                    Span::styled(title, Style::default().fg(if is_sel { theme::FG } else { theme::FG_MUTED })),
                ];
                if !job.repo.is_empty() {
                    line_spans.push(Span::styled(
                        format!("  [{}]", job.repo),
                        Style::default().fg(theme::FG_MUTED),
                    ));
                }

                let mut item = ListItem::new(Line::from(line_spans));
                if is_sel {
                    item = item.style(
                        Style::default().bg(ratatui::style::Color::Rgb(40, 40, 60)),
                    );
                }
                Some(item)
            })
            .collect();

        f.render_widget(List::new(items), inner);
    }

    fn render_detail_pane(&self, f: &mut Frame, area: Rect) {
        let focused = self.focus == Focus::LogTail;
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if focused {
                theme::BORDER_ACTIVE
            } else {
                theme::BORDER_INACTIVE
            }))
            .title(Span::styled(" Detail ", Style::default().fg(theme::FG_MUTED)));
        let inner = block.inner(area);
        f.render_widget(block, area);

        let job = match self.selected_job() {
            Some(j) => j,
            None => {
                f.render_widget(
                    Paragraph::new(Span::styled("(no selection)", Style::default().fg(theme::FG_MUTED))),
                    inner,
                );
                return;
            }
        };

        // Split detail: metadata header + log body.
        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Length(6), Constraint::Min(3)])
            .split(inner);

        self.render_job_metadata(f, chunks[0], job);
        self.render_log_tail(f, chunks[1]);
    }

    fn render_job_metadata(&self, f: &mut Frame, area: Rect, job: &MotherJob) {
        use chrono::Local;

        let (color, _) = state_style(&job.state);
        let created = job
            .created_at
            .map(|t| t.with_timezone(&Local).format("%H:%M:%S").to_string())
            .unwrap_or_else(|| "—".to_string());
        let started = job
            .started_at
            .map(|t| t.with_timezone(&Local).format("%H:%M:%S").to_string())
            .unwrap_or_else(|| "—".to_string());

        let lines = vec![
            Line::from(vec![
                Span::styled("ID:     ", Style::default().fg(theme::FG_MUTED)),
                Span::styled(job.id.as_str(), Style::default().fg(theme::FG)),
            ]),
            Line::from(vec![
                Span::styled("State:  ", Style::default().fg(theme::FG_MUTED)),
                Span::styled(
                    job.state.as_str(),
                    Style::default().fg(color).add_modifier(Modifier::BOLD),
                ),
            ]),
            Line::from(vec![
                Span::styled("Repo:   ", Style::default().fg(theme::FG_MUTED)),
                Span::styled(
                    if job.repo.is_empty() { "—" } else { &job.repo },
                    Style::default().fg(theme::FG),
                ),
            ]),
            Line::from(vec![
                Span::styled("Created:", Style::default().fg(theme::FG_MUTED)),
                Span::styled(format!(" {created}"), Style::default().fg(theme::FG)),
                Span::styled("  Started:", Style::default().fg(theme::FG_MUTED)),
                Span::styled(format!(" {started}"), Style::default().fg(theme::FG)),
            ]),
            Line::from(vec![
                Span::styled("Tier:   ", Style::default().fg(theme::FG_MUTED)),
                Span::styled(
                    job.current_tier.as_deref().unwrap_or("—"),
                    Style::default().fg(theme::AMBER),
                ),
            ]),
            // Hint line
            Line::from(vec![
                Span::styled("[d]cancel  ", Style::default().fg(theme::FG_MUTED)),
                Span::styled("[r]retry  ", Style::default().fg(theme::FG_MUTED)),
                Span::styled("[a]await  ", Style::default().fg(theme::FG_MUTED)),
                Span::styled("[Enter]log  ", Style::default().fg(theme::FG_MUTED)),
            ]),
        ];

        f.render_widget(
            Paragraph::new(lines).style(Style::default()),
            area,
        );
    }

    fn render_log_tail(&self, f: &mut Frame, area: Rect) {
        let log = self.log_text.lock().unwrap().clone();
        let lines: Vec<Line> = if log.is_empty() {
            vec![Line::from(Span::styled(
                "(no log yet)",
                Style::default().fg(theme::FG_MUTED),
            ))]
        } else {
            log.lines()
                .map(|l| Line::from(Span::styled(l, Style::default().fg(theme::FG))))
                .collect()
        };

        let total = lines.len();
        let scroll = self.log_scroll.min(total.saturating_sub(1));

        let para = Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .scroll((scroll as u16, 0))
            .style(Style::default());
        f.render_widget(para, area);

        // Scrollbar.
        if total > area.height as usize {
            let mut sb_state = ScrollbarState::new(total).position(scroll);
            f.render_stateful_widget(
                Scrollbar::new(ScrollbarOrientation::VerticalRight),
                area,
                &mut sb_state,
            );
        }
    }
}

// ── state → colour/glyph ─────────────────────────────────────────────────────

fn state_style(state: &str) -> (ratatui::style::Color, &'static str) {
    match state {
        "awaiting" => (theme::RED_SWEATER, "⏸"),
        "running"  => (theme::SAGE,        "▶"),
        "queued" | "ready" => (theme::AMBER, "◷"),
        "succeeded" => (theme::SAGE,       "✓"),
        "failed"   => (theme::RED_SWEATER, "✗"),
        "cancelled" => (theme::FG_MUTED,   "⊘"),
        _          => (theme::FG_MUTED,    "?"),
    }
}

// ── View impl ─────────────────────────────────────────────────────────────────

impl View for MotherView {
    fn id(&self) -> &'static str {
        "mother"
    }

    fn title(&self) -> &str {
        "Mother"
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        // Kick off log fetch if needed.
        self.maybe_fetch_log();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // counts strip
                Constraint::Min(5),    // main area
            ])
            .split(area);

        self.render_counts_strip(f, chunks[0]);

        let main = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Ratio(2, 5), Constraint::Ratio(3, 5)])
            .split(chunks[1]);

        self.render_job_list(f, main[0]);
        self.render_detail_pane(f, main[1]);
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
        match ev {
            AppEvent::MotherJobs(jobs) => {
                self.update_jobs(jobs.clone());
                return EventOutcome::Consumed;
            }
            AppEvent::MotherStatusline(status) => {
                self.status = status.clone();
                return EventOutcome::Consumed;
            }
            AppEvent::Key(k) => {
                match self.focus {
                    Focus::LogTail => {
                        match k.code {
                            KeyCode::Esc => {
                                self.focus = Focus::List;
                            }
                            KeyCode::PageUp => {
                                self.log_scroll = self.log_scroll.saturating_sub(10);
                            }
                            KeyCode::PageDown => {
                                self.log_scroll = self.log_scroll.saturating_add(10);
                            }
                            KeyCode::Up => {
                                self.log_scroll = self.log_scroll.saturating_sub(1);
                            }
                            KeyCode::Down => {
                                self.log_scroll = self.log_scroll.saturating_add(1);
                            }
                            _ => return EventOutcome::Ignored,
                        }
                        return EventOutcome::Consumed;
                    }

                    Focus::List => {
                        match k.code {
                            KeyCode::Up => {
                                if self.selected > 0 {
                                    self.selected -= 1;
                                    self.last_log_id = None;
                                    *self.log_text.lock().unwrap() = String::new();
                                    self.log_scroll = 0;
                                }
                                return EventOutcome::Consumed;
                            }
                            KeyCode::Down => {
                                if !self.display_order.is_empty()
                                    && self.selected + 1 < self.display_order.len()
                                {
                                    self.selected += 1;
                                    self.last_log_id = None;
                                    *self.log_text.lock().unwrap() = String::new();
                                    self.log_scroll = 0;
                                }
                                return EventOutcome::Consumed;
                            }
                            KeyCode::Enter => {
                                self.focus = Focus::LogTail;
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('d') | KeyCode::Char('D') => {
                                if let Some(job) = self.selected_job().cloned() {
                                    // Only for non-terminal states.
                                    if !matches!(job.state.as_str(), "succeeded" | "cancelled") {
                                        self.pending_action =
                                            Some(MotherAction::CancelJob(job));
                                    }
                                }
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('r') | KeyCode::Char('R') => {
                                if let Some(job) = self.selected_job().cloned() {
                                    if job.is_failed() {
                                        self.pending_action =
                                            Some(MotherAction::RetryJob(job));
                                    }
                                }
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('a') | KeyCode::Char('A') => {
                                if let Some(job) = self.selected_job().cloned() {
                                    if job.is_awaiting() {
                                        self.pending_action =
                                            Some(MotherAction::OpenAwaitModal(job));
                                    }
                                }
                                return EventOutcome::Consumed;
                            }

                            _ => {}
                        }
                    }
                }
            }
            _ => {}
        }

        EventOutcome::Ignored
    }

    fn on_tick(&mut self) {
        self.refresh_log_for_running();
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
