//! Mother queue view — live dashboard for Mother's job queue.
//!
//! Layout:
//!   - Row 0: Four-quadrant counts strip (running / queued / failed / awaiting)
//!   - Middle: Left list (grouped by state) + right detail pane (metadata + log tail)
//!   - Row N: Footer control hints bar
//!
//! Keybindings:
//!   - `↑/↓` — navigate job list
//!   - `Enter` — focus log tail, scroll with PgUp/PgDn/↑/↓
//!   - `v` — open plan file viewer overlay (scroll with PgUp/PgDn/↑/↓)
//!   - `x` — dismiss selected terminal-state job from view
//!   - `d` — cancel selected job (app opens confirm modal)
//!   - `r` — retry failed job (app opens confirm modal)
//!   - `a` — open await modal for awaiting job
//!   - `Esc` — exit log/plan view, return to list

use std::any::Any;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crossterm::event::{KeyCode, MouseEventKind};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{
        Block, Borders, List, ListItem, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState,
        Wrap,
    },
    Frame,
};
use tracing::debug;

use crate::{
    event::AppEvent,
    mother::{self, MotherJob, MotherStatus, PeekSnapshot},
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
    /// Full-screen plan viewer overlay.
    PlanView,
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
    /// Plan file content for the selected job (loaded async when [v] is pressed).
    plan_text: Arc<Mutex<String>>,
    /// Scroll offset within the plan viewer.
    plan_scroll: usize,
    /// Which sub-section has focus.
    focus: Focus,
    /// Last job-id we fetched the log for (avoid redundant fetches).
    last_log_id: Option<String>,
    /// Peek snapshot for the selected job (populated async).
    peek_data: Arc<Mutex<Option<PeekSnapshot>>>,
    /// Last job-id we fetched peek data for.
    last_peek_id: Option<String>,
    /// Throttle counter: only re-fetch peek every 5 ticks.
    peek_refresh_counter: u8,
    /// Job IDs dismissed from view via [x] (terminal-state only, local to this session).
    hidden_ids: HashSet<String>,
    /// Last known inner area of the job list pane.
    list_area: Rect,
    /// Last known inner area of the log tail pane.
    log_area: Rect,
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
            plan_text: Arc::new(Mutex::new(String::new())),
            plan_scroll: 0,
            focus: Focus::List,
            last_log_id: None,
            peek_data: Arc::new(Mutex::new(None)),
            last_peek_id: None,
            peek_refresh_counter: 0,
            hidden_ids: HashSet::new(),
            list_area: Rect::default(),
            log_area: Rect::default(),
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
                .filter(|j| j.state == state && !self.hidden_ids.contains(&j.id))
                .collect();
            group.sort_by_key(|j| std::cmp::Reverse(j.created_at));
            order.extend(group.iter().map(|j| j.id.clone()));
        }

        // Recent succeeded (last 10, newest first) — excluding hidden.
        let mut succeeded: Vec<&MotherJob> = self
            .jobs
            .iter()
            .filter(|j| j.is_succeeded() && !self.hidden_ids.contains(&j.id))
            .collect();
        succeeded.sort_by_key(|j| std::cmp::Reverse(j.finished_at));
        order.extend(succeeded.iter().take(10).map(|j| j.id.clone()));

        // Recent failed (last 10, newest first) — excluding hidden.
        let mut failed: Vec<&MotherJob> = self
            .jobs
            .iter()
            .filter(|j| j.is_failed() && !self.hidden_ids.contains(&j.id))
            .collect();
        failed.sort_by_key(|j| std::cmp::Reverse(j.finished_at));
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
                    *log_text.lock().unwrap() = format!("(log unavailable: {e})");
                }
            }
        });
    }

    /// Load the plan file for the selected job into `plan_text` (async).
    fn fetch_plan_for_selected(&mut self) {
        let path = match self.selected_job().and_then(|j| j.plan_path.clone()) {
            Some(p) => p,
            None => {
                *self.plan_text.lock().unwrap() = "(no plan file recorded for this job)".to_owned();
                return;
            }
        };

        let plan_text = Arc::clone(&self.plan_text);
        tokio::spawn(async move {
            match tokio::fs::read_to_string(&path).await {
                Ok(content) => {
                    *plan_text.lock().unwrap() = content;
                }
                Err(e) => {
                    *plan_text.lock().unwrap() = format!("(cannot read plan {path}: {e})");
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

    // ── peek fetch ────────────────────────────────────────────────────────────

    fn maybe_fetch_peek(&mut self) {
        let id = match self.selected_job().map(|j| j.id.clone()) {
            Some(id) => id,
            None => return,
        };
        if self.last_peek_id.as_deref() == Some(&id) {
            return;
        }
        self.last_peek_id = Some(id.clone());

        let peek_data = Arc::clone(&self.peek_data);
        tokio::spawn(async move {
            match mother::peek(&id).await {
                Ok(snap) => {
                    *peek_data.lock().unwrap() = Some(snap);
                }
                Err(e) => {
                    debug!("peek error for {id}: {e:#}");
                }
            }
        });
    }

    fn refresh_peek_for_running(&mut self) {
        self.peek_refresh_counter = self.peek_refresh_counter.wrapping_add(1);
        if !self.peek_refresh_counter.is_multiple_of(5) {
            return;
        }
        let is_running = self
            .selected_job()
            .map(|j| j.state == "running")
            .unwrap_or(false);
        if is_running {
            self.last_peek_id = None;
            self.maybe_fetch_peek();
        }
    }

    fn clear_detail_cache(&mut self) {
        self.last_log_id = None;
        self.last_peek_id = None;
        *self.log_text.lock().unwrap() = String::new();
        *self.peek_data.lock().unwrap() = None;
        self.log_scroll = 0;
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
            ("Queued", self.status.queued, theme::AMBER),
            ("Failed", self.status.failed, theme::RED_SWEATER),
            ("Awaiting", self.status.awaiting, theme::RED_SWEATER),
        ];

        for (i, (label, count, color)) in cells.iter().enumerate() {
            let active = *count > 0;
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(if active {
                    *color
                } else {
                    theme::BORDER_INACTIVE
                }));
            let inner = block.inner(chunks[i]);
            f.render_widget(block, chunks[i]);

            let count_span = Span::styled(
                format!("{count}"),
                Style::default()
                    .fg(if active { *color } else { theme::FG_MUTED })
                    .add_modifier(Modifier::BOLD),
            );
            let label_span =
                Span::styled(format!(" {label}"), Style::default().fg(theme::FG_MUTED));
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
                    Span::styled(
                        title,
                        Style::default().fg(if is_sel { theme::FG } else { theme::FG_MUTED }),
                    ),
                ];
                if !job.repo.is_empty() {
                    line_spans.push(Span::styled(
                        format!("  [{}]", job.repo),
                        Style::default().fg(theme::FG_MUTED),
                    ));
                }

                let mut item = ListItem::new(Line::from(line_spans));
                if is_sel {
                    item = item.style(Style::default().bg(ratatui::style::Color::Rgb(40, 40, 60)));
                }
                Some(item)
            })
            .collect();

        f.render_widget(List::new(items), inner);
    }

    fn render_detail_pane(&mut self, f: &mut Frame, area: Rect) {
        let focused = self.focus == Focus::LogTail;
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if focused {
                theme::BORDER_ACTIVE
            } else {
                theme::BORDER_INACTIVE
            }))
            .title(Span::styled(
                " Detail ",
                Style::default().fg(theme::FG_MUTED),
            ));
        let inner = block.inner(area);
        f.render_widget(block, area);

        let job = match self.selected_job().cloned() {
            Some(j) => j,
            None => {
                f.render_widget(
                    Paragraph::new(Span::styled(
                        "(no selection)",
                        Style::default().fg(theme::FG_MUTED),
                    )),
                    inner,
                );
                return;
            }
        };

        let peek = self.peek_data.lock().unwrap().clone();

        // Dynamic layout: summary + [todos] + activity + log
        let todo_count = peek.as_ref().map(|p| p.todos.len()).unwrap_or(0).min(8);
        let todo_height = if todo_count > 0 {
            (todo_count as u16) + 1
        } else {
            0
        }; // rows + header
        let activity_height: u16 = 5; // header + 3 calls + blank
        let summary_height: u16 = 2; // status line + blank separator

        let log_min: u16 = 4;
        let used = summary_height + todo_height + activity_height + 1; // +1 for "Log" label
        let log_height = inner.height.saturating_sub(used).max(log_min);

        let mut constraints = vec![Constraint::Length(summary_height)];
        if todo_height > 0 {
            constraints.push(Constraint::Length(todo_height));
        }
        constraints.push(Constraint::Length(activity_height));
        constraints.push(Constraint::Length(1)); // "Log" label
        constraints.push(Constraint::Min(log_height));

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints(constraints)
            .split(inner);

        let mut idx = 0;

        // ── Summary ───────────────────────────────────────────────────────────
        self.render_summary_line(f, chunks[idx], &job);
        idx += 1;

        // ── Todos ─────────────────────────────────────────────────────────────
        if todo_height > 0 {
            if let Some(ref p) = peek {
                render_todos(f, chunks[idx], &p.todos);
            }
            idx += 1;
        }

        // ── Activity ──────────────────────────────────────────────────────────
        render_activity(f, chunks[idx], peek.as_ref());
        idx += 1;

        // ── Log label + tail ──────────────────────────────────────────────────
        f.render_widget(
            Paragraph::new(Line::from(Span::styled(
                "Log",
                Style::default().fg(theme::FG_MUTED),
            ))),
            chunks[idx],
        );
        idx += 1;
        self.render_log_tail(f, chunks[idx]);
    }

    fn render_summary_line(&self, f: &mut Frame, area: Rect, job: &MotherJob) {
        use chrono::Local;
        let (color, glyph) = state_style(&job.state);

        let created = job
            .created_at
            .map(|t| t.with_timezone(&Local).format("%H:%M").to_string())
            .unwrap_or_else(|| "—".into());
        let arrow = job
            .started_at
            .map(|t| format!("→{}", t.with_timezone(&Local).format("%H:%M")))
            .unwrap_or_default();
        let finished = job
            .finished_at
            .map(|t| format!("→{}", t.with_timezone(&Local).format("%H:%M")))
            .unwrap_or_default();
        let time_str = format!("{created}{arrow}{finished}");

        let repo = if job.repo.is_empty() {
            "—"
        } else {
            &job.repo
        };
        let tier = job.current_tier.as_deref().unwrap_or("—");

        let id_short = &job.id[..job.id.len().min(12)];

        let spans = vec![
            Span::styled(
                format!("{glyph} "),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
            Span::styled(job.state.as_str(), Style::default().fg(color)),
            Span::styled("  ", Style::default()),
            Span::styled(repo, Style::default().fg(theme::FG_MUTED)),
            Span::styled("  ", Style::default()),
            Span::styled(tier, Style::default().fg(theme::AMBER)),
            Span::styled("  ", Style::default()),
            Span::styled(time_str, Style::default().fg(theme::FG_MUTED)),
            Span::styled("  ", Style::default()),
            Span::styled(id_short, Style::default().fg(theme::FG_MUTED)),
        ];
        f.render_widget(Paragraph::new(Line::from(spans)), area);
    }

    fn render_log_tail(&mut self, f: &mut Frame, area: Rect) {
        self.log_area = area;
        let log = self.log_text.lock().unwrap().clone();
        let lines: Vec<Line> = if log.is_empty() {
            vec![Line::from(Span::styled(
                "(no log yet)",
                Style::default().fg(theme::FG_MUTED),
            ))]
        } else {
            format_log_as_conversation(&log)
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

    /// Full-screen overlay showing the plan file for the selected job.
    fn render_plan_overlay(&self, f: &mut Frame, area: Rect) {
        let title = self
            .selected_job()
            .and_then(|j| j.plan_path.as_deref())
            .map(|p| format!(" Plan: {p} "))
            .unwrap_or_else(|| " Plan ".to_owned());

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(theme::BORDER_ACTIVE))
            .title(Span::styled(title, Style::default().fg(theme::FG_MUTED)));
        let inner = block.inner(area);
        f.render_widget(block, area);

        let text = self.plan_text.lock().unwrap().clone();
        let lines: Vec<Line> = if text.is_empty() {
            vec![Line::from(Span::styled(
                "(loading…)",
                Style::default().fg(theme::FG_MUTED),
            ))]
        } else {
            text.lines()
                .map(|l| Line::from(Span::styled(l, Style::default().fg(theme::FG))))
                .collect()
        };

        let total = lines.len();
        let scroll = self.plan_scroll.min(total.saturating_sub(1));

        let para = Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .scroll((scroll as u16, 0));
        f.render_widget(para, inner);

        if total > inner.height as usize {
            let mut sb_state = ScrollbarState::new(total).position(scroll);
            f.render_stateful_widget(
                Scrollbar::new(ScrollbarOrientation::VerticalRight),
                inner,
                &mut sb_state,
            );
        }
    }

    /// Single-row control hints bar rendered at the bottom of the view.
    fn render_footer(&self, f: &mut Frame, area: Rect) {
        let (nav, actions) = match self.focus {
            Focus::List => (
                vec![
                    Span::styled("↑↓", Style::default().fg(theme::FG)),
                    Span::styled(" nav  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("Enter", Style::default().fg(theme::FG)),
                    Span::styled(" log  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("v", Style::default().fg(theme::FG)),
                    Span::styled(" plan  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("x", Style::default().fg(theme::FG)),
                    Span::styled(" dismiss  ", Style::default().fg(theme::FG_MUTED)),
                ],
                vec![
                    Span::styled("d", Style::default().fg(theme::AMBER)),
                    Span::styled(" cancel  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("r", Style::default().fg(theme::AMBER)),
                    Span::styled(" retry  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("a", Style::default().fg(theme::AMBER)),
                    Span::styled(" await", Style::default().fg(theme::FG_MUTED)),
                ],
            ),
            Focus::LogTail => (
                vec![
                    Span::styled("↑↓ PgUp PgDn", Style::default().fg(theme::FG)),
                    Span::styled(" scroll  ", Style::default().fg(theme::FG_MUTED)),
                ],
                vec![
                    Span::styled("Esc", Style::default().fg(theme::AMBER)),
                    Span::styled(" back", Style::default().fg(theme::FG_MUTED)),
                ],
            ),
            Focus::PlanView => (
                vec![
                    Span::styled("↑↓ PgUp PgDn", Style::default().fg(theme::FG)),
                    Span::styled(" scroll  ", Style::default().fg(theme::FG_MUTED)),
                ],
                vec![
                    Span::styled("Esc", Style::default().fg(theme::AMBER)),
                    Span::styled(" back", Style::default().fg(theme::FG_MUTED)),
                ],
            ),
        };

        let separator = Span::styled("  │  ", Style::default().fg(theme::BORDER_INACTIVE));
        let mut spans = nav;
        spans.push(separator);
        spans.extend(actions);

        f.render_widget(Paragraph::new(Line::from(spans)), area);
    }
}

// ── detail pane sub-renderers (free fns, borrow only what they need) ─────────

fn render_todos(f: &mut Frame, area: Rect, todos: &[crate::mother::PeekTodo]) {
    let completed = todos.iter().filter(|t| t.status == "completed").count();
    let total = todos.len();

    let mut lines = vec![Line::from(vec![
        Span::styled("Todos ", Style::default().fg(theme::FG_MUTED)),
        Span::styled(
            format!("[{completed}/{total}]"),
            Style::default().fg(if completed == total {
                theme::SAGE
            } else {
                theme::AMBER
            }),
        ),
    ])];

    for todo in todos.iter().take(8) {
        let (icon, icon_style) = match todo.status.as_str() {
            "completed" => ("✓", Style::default().fg(theme::SAGE)),
            "in_progress" => (
                "▶",
                Style::default()
                    .fg(theme::AMBER)
                    .add_modifier(Modifier::BOLD),
            ),
            "cancelled" => ("✗", Style::default().fg(theme::FG_MUTED)),
            _ => ("○", Style::default().fg(theme::FG_MUTED)),
        };
        let text_style = if todo.status == "in_progress" {
            Style::default().fg(theme::FG)
        } else {
            Style::default().fg(theme::FG_MUTED)
        };
        let content = crate::ui::widgets::truncate::truncate(
            &todo.content,
            area.width.saturating_sub(5) as usize,
        );
        lines.push(Line::from(vec![
            Span::styled(format!(" {icon} "), icon_style),
            Span::styled(content, text_style),
        ]));
    }

    f.render_widget(Paragraph::new(lines), area);
}

fn render_activity(f: &mut Frame, area: Rect, peek: Option<&crate::mother::PeekSnapshot>) {
    let mut lines = vec![Line::from(Span::styled(
        "Activity",
        Style::default().fg(theme::FG_MUTED),
    ))];

    match peek {
        None => {
            lines.push(Line::from(Span::styled(
                "  (loading…)",
                Style::default().fg(theme::FG_MUTED),
            )));
        }
        Some(p) if p.tool_trail.is_empty() => {
            lines.push(Line::from(Span::styled(
                "  (no activity yet)",
                Style::default().fg(theme::FG_MUTED),
            )));
        }
        Some(p) => {
            // Show last 3 calls, oldest first
            let start = p.tool_trail.len().saturating_sub(3);
            for call in &p.tool_trail[start..] {
                let label = format!("  [{:<12}]  ", call.tool);
                let brief_width = area.width.saturating_sub(label.len() as u16) as usize;
                let brief = crate::ui::widgets::truncate::truncate(&call.brief, brief_width);
                lines.push(Line::from(vec![
                    Span::styled(label, Style::default().fg(theme::FG_MUTED)),
                    Span::styled(brief, Style::default().fg(theme::FG)),
                ]));
            }
        }
    }

    f.render_widget(Paragraph::new(lines), area);
}

/// Parse the raw log JSONL into human-readable lines.
///
/// The log file is Claude Code's stdout transcript.  It contains a mix of:
/// - `=== key: value ===` Mother header lines
/// - JSON lines: `{"type":"system",...}`, `{"type":"assistant",...}`, etc.
/// - Occasional plain-text output
///
/// We strip noise (system init, rate-limit events, tool results) and render
/// assistant text + tool calls in a readable format.
fn format_log_as_conversation(raw: &str) -> Vec<Line<'static>> {
    let mut out: Vec<Line<'static>> = Vec::new();

    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // === key: value === Mother metadata headers
        if line.starts_with("===") && line.ends_with("===") {
            let inner = line.trim_matches('=').trim().to_owned();
            out.push(Line::from(Span::styled(
                inner,
                Style::default().fg(theme::FG_MUTED),
            )));
            continue;
        }

        // Try JSON
        if line.starts_with('{') {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(line) {
                match val.get("type").and_then(|t| t.as_str()) {
                    // ── skip noise ────────────────────────────────────────────
                    Some("system") | Some("rate_limit_event") | Some("user") => continue,

                    // ── assistant message ─────────────────────────────────────
                    Some("assistant") => {
                        let content = val.pointer("/message/content").and_then(|c| c.as_array());
                        if let Some(blocks) = content {
                            for block in blocks {
                                match block.get("type").and_then(|t| t.as_str()) {
                                    Some("text") => {
                                        let text = block
                                            .get("text")
                                            .and_then(|t| t.as_str())
                                            .unwrap_or("")
                                            .to_owned();
                                        for tline in text.lines() {
                                            let tline = tline.to_owned();
                                            if !tline.trim().is_empty() {
                                                out.push(Line::from(Span::styled(
                                                    tline,
                                                    Style::default().fg(theme::FG),
                                                )));
                                            }
                                        }
                                    }
                                    Some("tool_use") => {
                                        let name = block
                                            .get("name")
                                            .and_then(|n| n.as_str())
                                            .unwrap_or("?")
                                            .to_owned();
                                        let brief = log_tool_brief(&name, block.get("input"));
                                        out.push(Line::from(vec![
                                            Span::styled("→ ", Style::default().fg(theme::AMBER)),
                                            Span::styled(
                                                format!("[{name}]"),
                                                Style::default().fg(theme::FG_MUTED),
                                            ),
                                            Span::styled(
                                                format!("  {brief}"),
                                                Style::default().fg(theme::FG),
                                            ),
                                        ]));
                                    }
                                    _ => {}
                                }
                            }
                        }
                    }
                    _ => continue,
                }
                continue;
            }
            // Unparseable JSON — skip silently
            continue;
        }

        // Plain non-JSON text
        out.push(Line::from(Span::styled(
            line.to_owned(),
            Style::default().fg(theme::FG),
        )));
    }

    if out.is_empty() {
        out.push(Line::from(Span::styled(
            "(no output yet)",
            Style::default().fg(theme::FG_MUTED),
        )));
    }
    out
}

fn log_tool_brief(tool: &str, input: Option<&serde_json::Value>) -> String {
    let _ = tool;
    let Some(inp) = input.and_then(|v| v.as_object()) else {
        return String::new();
    };
    for key in &["file_path", "path", "command", "pattern", "description"] {
        if let Some(v) = inp.get(*key).and_then(|v| v.as_str()) {
            let s = v.replace('\n', " ⏎ ");
            return s.chars().take(100).collect();
        }
    }
    String::new()
}

// ── state → colour/glyph ─────────────────────────────────────────────────────

fn state_style(state: &str) -> (ratatui::style::Color, &'static str) {
    match state {
        "awaiting" => (theme::RED_SWEATER, "⏸"),
        "running" => (theme::SAGE, "▶"),
        "queued" | "ready" => (theme::AMBER, "◷"),
        "succeeded" => (theme::SAGE, "✓"),
        "failed" => (theme::RED_SWEATER, "✗"),
        "cancelled" => (theme::FG_MUTED, "⊘"),
        _ => (theme::FG_MUTED, "?"),
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
        // TODO: surface Mother errors — MotherView has no `error: Option<String>` field yet.
        // When added, render a 1-row yellow banner here (same pattern as fred/perri).

        // Kick off log + peek fetches if needed.
        self.maybe_fetch_log();
        self.maybe_fetch_peek();

        let chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // counts strip
                Constraint::Min(5),    // main area
                Constraint::Length(1), // footer control bar
            ])
            .split(area);

        self.render_counts_strip(f, chunks[0]);

        let main = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Ratio(2, 5), Constraint::Ratio(3, 5)])
            .split(chunks[1]);

        // Record inner areas for mouse hit-testing (subtract 1-px border on each side).
        self.list_area = shrink_border(main[0]);
        self.render_job_list(f, main[0]);
        self.render_detail_pane(f, main[1]);

        // Plan overlay covers the entire main area (counts strip + list/detail).
        if self.focus == Focus::PlanView {
            // Overlay spanning counts strip through detail pane (chunks[0] + chunks[1]).
            let overlay = Rect {
                x: area.x,
                y: area.y,
                width: area.width,
                height: chunks[0].height + chunks[1].height,
            };
            self.render_plan_overlay(f, overlay);
        }

        self.render_footer(f, chunks[2]);
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

                    Focus::PlanView => {
                        match k.code {
                            KeyCode::Esc => {
                                self.focus = Focus::List;
                            }
                            KeyCode::PageUp => {
                                self.plan_scroll = self.plan_scroll.saturating_sub(10);
                            }
                            KeyCode::PageDown => {
                                self.plan_scroll = self.plan_scroll.saturating_add(10);
                            }
                            KeyCode::Up => {
                                self.plan_scroll = self.plan_scroll.saturating_sub(1);
                            }
                            KeyCode::Down => {
                                self.plan_scroll = self.plan_scroll.saturating_add(1);
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
                                    self.clear_detail_cache();
                                }
                                return EventOutcome::Consumed;
                            }
                            KeyCode::Down => {
                                if !self.display_order.is_empty()
                                    && self.selected + 1 < self.display_order.len()
                                {
                                    self.selected += 1;
                                    self.clear_detail_cache();
                                }
                                return EventOutcome::Consumed;
                            }
                            KeyCode::Enter => {
                                self.focus = Focus::LogTail;
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('v') | KeyCode::Char('V') => {
                                // Open plan viewer overlay.
                                *self.plan_text.lock().unwrap() = String::new();
                                self.plan_scroll = 0;
                                self.fetch_plan_for_selected();
                                self.focus = Focus::PlanView;
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('x') | KeyCode::Char('X') => {
                                // Dismiss terminal-state job from view.
                                if let Some(job) = self.selected_job().cloned() {
                                    if matches!(
                                        job.state.as_str(),
                                        "succeeded" | "failed" | "cancelled"
                                    ) {
                                        self.hidden_ids.insert(job.id);
                                        self.rebuild_display_order();
                                        // Clamp selection after removal.
                                        if !self.display_order.is_empty() {
                                            self.selected =
                                                self.selected.min(self.display_order.len() - 1);
                                        } else {
                                            self.selected = 0;
                                        }
                                        self.clear_detail_cache();
                                    }
                                }
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('d') | KeyCode::Char('D') => {
                                if let Some(job) = self.selected_job().cloned() {
                                    // Only for non-terminal states.
                                    if !matches!(job.state.as_str(), "succeeded" | "cancelled") {
                                        self.pending_action = Some(MotherAction::CancelJob(job));
                                    }
                                }
                                return EventOutcome::Consumed;
                            }

                            KeyCode::Char('r') | KeyCode::Char('R') => {
                                if let Some(job) = self.selected_job().cloned() {
                                    if job.is_failed() {
                                        self.pending_action = Some(MotherAction::RetryJob(job));
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

        // Mouse scroll: hit-test against tracked pane areas.
        if let AppEvent::Mouse(m) = ev {
            let in_list = rect_contains(self.list_area, m.column, m.row);
            let in_log = rect_contains(self.log_area, m.column, m.row);
            match m.kind {
                MouseEventKind::ScrollUp => {
                    if self.focus == Focus::PlanView {
                        self.plan_scroll = self.plan_scroll.saturating_sub(3);
                    } else if in_log {
                        self.log_scroll = self.log_scroll.saturating_sub(3);
                    } else if in_list && self.selected > 0 {
                        self.selected -= 1;
                        self.clear_detail_cache();
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if self.focus == Focus::PlanView {
                        self.plan_scroll = self.plan_scroll.saturating_add(3);
                    } else if in_log {
                        self.log_scroll = self.log_scroll.saturating_add(3);
                    } else if in_list
                        && !self.display_order.is_empty()
                        && self.selected + 1 < self.display_order.len()
                    {
                        self.selected += 1;
                        self.clear_detail_cache();
                    }
                    return EventOutcome::Consumed;
                }
                _ => {}
            }
        }

        EventOutcome::Ignored
    }

    fn on_tick(&mut self) {
        self.refresh_log_for_running();
        self.refresh_peek_for_running();
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn rect_contains(r: Rect, col: u16, row: u16) -> bool {
    col >= r.x && col < r.x + r.width && row >= r.y && row < r.y + r.height
}

/// Return the inner rect after removing a 1-cell border on all sides.
fn shrink_border(r: Rect) -> Rect {
    Rect {
        x: r.x.saturating_add(1),
        y: r.y.saturating_add(1),
        width: r.width.saturating_sub(2),
        height: r.height.saturating_sub(2),
    }
}
