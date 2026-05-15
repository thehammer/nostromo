//! Perri view: PR queue (top-left) + syntax-highlighted diff (top-right) + PTY REPL.

use std::any::Any;
use std::sync::Arc;

use crossterm::event::{KeyCode, MouseButton, MouseEventKind};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};
use tokio::sync::watch;

use crate::{
    config::Config,
    data::{perri_pr::PrSnapshot, perri_queue::PrQueueSnapshot},
    event::AppEvent,
    pty::{PtyHost, PtyWidget},
    ui::{
        drag::{self, DividerAxis, DragState},
        pane_ratios, theme,
        widgets::{syntect_cache::SyntectCache, syntect_diff::SyntectDiff, truncate::truncate},
    },
    views::{EventOutcome, View, ViewCtx},
};

pub struct PerriView {
    queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    pr_rx: watch::Receiver<Option<PrSnapshot>>,
    selected_pr: usize,
    config: Config,
    ctx: ViewCtx,
    syntect: Arc<SyntectCache>,
    pty: Option<PtyHost>,
    /// Whether the PTY is currently capturing keystrokes.
    pty_capturing: bool,
    /// Last known inner area of the REPL pane.
    repl_area: Rect,
    /// Last known inner area of the PR queue list.
    pr_list_area: Rect,
    /// Rows scrolled back in the REPL pane (0 = live view).
    repl_scroll: u16,
    // ── pane resize ──────────────────────────────────────────────────────────
    /// Fraction of vertical space given to the queue+diff row (vs. REPL).
    top_row_ratio: f32,
    /// Fraction of horizontal space given to the PR queue list (vs. diff).
    queue_ratio: f32,
    /// Current drag state.
    drag: DragState,
    /// Y coordinate of the horizontal divider between top row and REPL.
    top_row_divider_row: u16,
    /// X coordinate of the vertical divider between queue and diff.
    queue_divider_col: u16,
    /// Parent rect for the top-row split (the full content_area).
    top_row_area: Rect,
    /// Parent rect for the horizontal queue/diff split (rows[0]).
    top_cols_area: Rect,
    // ── MCP Phase 3: diff override ────────────────────────────────────────────
    /// When set, rendered in the diff pane instead of the `pr_rx` snapshot.
    /// Cleared when the `pr_rx` watch channel next delivers an update.
    diff_override: Option<String>,
}

impl PerriView {
    pub fn new(
        queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
        pr_rx: watch::Receiver<Option<PrSnapshot>>,
        config: Config,
        ctx: ViewCtx,
        syntect: Arc<SyntectCache>,
    ) -> Self {
        let ratios = pane_ratios::load();
        Self {
            queue_rx,
            pr_rx,
            selected_pr: 0,
            config,
            ctx,
            syntect,
            pty: None,
            pty_capturing: false,
            repl_area: Rect::new(0, 0, 80, 10),
            pr_list_area: Rect::new(0, 0, 40, 10),
            repl_scroll: 0,
            top_row_ratio: ratios.perri.top_row,
            queue_ratio: ratios.perri.queue,
            drag: DragState::Idle,
            top_row_divider_row: 0,
            queue_divider_col: 0,
            top_row_area: Rect::default(),
            top_cols_area: Rect::default(),
            diff_override: None,
        }
    }

    /// Focus the diff pane on the HEAD diff of a Mother worktree.
    ///
    /// Called by the app when the operator presses `v` in the await modal.
    /// Phase 3: path-based diff is not yet wired to a live data source, so
    /// this is a stub that records the path for future display.
    pub fn focus_diff_for_worktree(&mut self, _path: &std::path::Path) {
        // No-op for now — Perri's diff pane already shows the most-recently
        // fetched PR diff.  A future phase will add a `git diff HEAD` pane
        // keyed to the worktree path.
    }

    /// Write `current-pr.json` so the native watcher fetches the given PR.
    ///
    /// Constructs the minimal JSON shape accepted by `PerriPrNativeSource`
    /// and touches the `.dirty` sentinel.  The dirty-file watcher then picks
    /// it up and updates `pr_rx` within one poll cycle.
    pub fn load_pr(&mut self, number: u64, repo: String, highlights: Option<String>) -> Result<(), String> {
        let state_dir = self.config.perri_state_dir();
        std::fs::create_dir_all(&state_dir)
            .map_err(|e| format!("io_error: {e}"))?;

        let pointer = serde_json::json!({
            "number": number,
            "repo": repo,
            "highlights": highlights,
        });
        let json = serde_json::to_string_pretty(&pointer)
            .map_err(|e| format!("serialization_failed: {e}"))?;

        let json_path = state_dir.join("current-pr.json");
        std::fs::write(&json_path, json.as_bytes())
            .map_err(|e| format!("io_error: {e}"))?;

        // Touch the dirty sentinel to wake the watcher.
        let dirty_path = state_dir.join("current-pr.dirty");
        std::fs::write(&dirty_path, b"")
            .map_err(|e| format!("io_error: {e}"))?;

        // Clear any override so the live diff shows once pr_rx updates.
        self.diff_override = None;

        Ok(())
    }

    /// Remove `current-pr.json` and touch the dirty sentinel to clear Perri's diff pane.
    pub fn clear_current_pr(&mut self) -> Result<(), String> {
        let state_dir = self.config.perri_state_dir();
        let json_path = state_dir.join("current-pr.json");
        if json_path.exists() {
            std::fs::remove_file(&json_path)
                .map_err(|e| format!("io_error: {e}"))?;
        }
        let dirty_path = state_dir.join("current-pr.dirty");
        std::fs::write(&dirty_path, b"")
            .map_err(|e| format!("io_error: {e}"))?;

        self.diff_override = None;
        Ok(())
    }

    /// Return the current selected PR index.
    pub fn selected_pr_index(&self) -> usize {
        self.selected_pr
    }

    /// Set the selected PR index, clamped to the queue length.
    pub fn set_selected_pr_index(&mut self, index: usize) {
        let len = self.queue_rx.borrow()
            .as_ref()
            .map(|s| s.items.len())
            .unwrap_or(0);
        self.selected_pr = if len == 0 { 0 } else { index.min(len - 1) };
    }

    fn render_queue_with_drag(&mut self, f: &mut Frame, area: Rect, dragging: bool) {
        let snap = self.queue_rx.borrow();
        let snap = snap.as_ref();

        let count = snap.map(|s| s.items.len()).unwrap_or(0);
        let stale = snap.map(|s| s.stale).unwrap_or(false);

        let queue_color = if dragging {
            theme::BORDER_ACTIVE
        } else {
            match count {
                0..=4 => theme::SAGE,
                5..=9 => theme::AMBER,
                _ => theme::RED_SWEATER,
            }
        };

        let stale_suffix = if stale { " (stale)" } else { "" };
        let title = format!(" PR Queue [{count}]{stale_suffix} ");

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(queue_color))
            .title(Span::styled(
                title,
                Style::default()
                    .fg(queue_color)
                    .add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        let items: Vec<ListItem> = if let Some(s) = snap {
            if s.items.is_empty() {
                vec![ListItem::new(Line::from(Span::styled(
                    " ✓ Queue is empty",
                    theme::style_sage(),
                )))]
            } else {
                s.items
                    .iter()
                    .enumerate()
                    .map(|(i, pr)| {
                        // Glyph and colour reflect the bucket, matching the
                        // tmux queue pane display:
                        //   requested    → blue ●  (explicitly asked for our eyes)
                        //   needs_review → plain ○ (needs at least one approval)
                        //   changes_req  → amber ● (author responded to our request)
                        let (req_glyph, req_style) = match pr.bucket.as_str() {
                            "requested" => ("● ", Style::default().fg(theme::BORDER_ACTIVE)),
                            "changes_req" => ("● ", theme::style_amber()),
                            _ => ("○ ", theme::style_normal()),
                        };

                        let selected_glyph = if i == self.selected_pr { "▶ " } else { "  " };

                        let number_str = format!("#{}", pr.number);
                        let repo_short = pr.repo.split('/').next_back().unwrap_or(&pr.repo);
                        let label_width = inner.width as usize - 16;
                        let title_str = truncate(&pr.title, label_width);

                        Line::from(vec![
                            Span::styled(selected_glyph, theme::style_muted()),
                            Span::styled(req_glyph, req_style),
                            Span::styled(
                                format!("{number_str:<6} "),
                                Style::default().fg(theme::BORDER_ACTIVE),
                            ),
                            Span::styled(title_str, theme::style_normal()),
                            Span::styled(format!(" {}", repo_short), theme::style_muted()),
                        ])
                    })
                    .map(ListItem::new)
                    .collect()
            }
        } else {
            vec![ListItem::new(Line::from(Span::styled(
                " Loading PR queue…",
                theme::style_muted(),
            )))]
        };

        self.pr_list_area = inner;
        let list = List::new(items);
        f.render_widget(list, inner);
    }

    fn render_diff_with_drag(&self, f: &mut Frame, area: Rect, dragging: bool) {
        // If a diff_override is set, render it directly rather than pr_rx.
        if let Some(override_text) = &self.diff_override {
            let border_color = if dragging { theme::BORDER_ACTIVE } else { theme::BORDER_INACTIVE };
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(border_color))
                .title(Span::styled(
                    " Diff (override) ",
                    Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
                ));
            let inner = block.inner(area);
            f.render_widget(block, area);
            f.render_widget(
                SyntectDiff::new(override_text, Arc::clone(&self.syntect))
                    .max_lines(inner.height as usize),
                inner,
            );
            return;
        }

        let snap = self.pr_rx.borrow();
        let snap = snap.as_ref();

        let stale = snap.map(|s| s.stale).unwrap_or(false);
        let stale_suffix = if stale { " (stale)" } else { "" };

        let pr_title = snap
            .map(|s| {
                if let Some(n) = s.pr_number {
                    format!(" PR #{n} — {}{stale_suffix} ", s.title)
                } else {
                    format!(" Diff{stale_suffix} ")
                }
            })
            .unwrap_or_else(|| " Diff ".into());

        let border_color = if dragging {
            theme::BORDER_ACTIVE
        } else {
            theme::BORDER_INACTIVE
        };

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(border_color))
            .title(Span::styled(
                truncate(&pr_title, area.width as usize - 4),
                Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        if let Some(s) = snap {
            if s.diff.is_empty() {
                let p = Paragraph::new(Line::from(Span::styled(
                    " No diff available",
                    theme::style_muted(),
                )));
                f.render_widget(p, inner);
            } else {
                f.render_widget(
                    SyntectDiff::new(&s.diff, Arc::clone(&self.syntect))
                        .max_lines(inner.height as usize),
                    inner,
                );
            }
        } else {
            let p = Paragraph::new(Line::from(Span::styled(
                " Loading diff…",
                theme::style_muted(),
            )));
            f.render_widget(p, inner);
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
            .title(Span::styled(" REPL ", Style::default().fg(theme::FG_MUTED)));

        let inner = block.inner(area);
        f.render_widget(block, area);

        self.repl_area = inner;

        if let Some(pty) = &self.pty {
            let guard = pty.parser.lock().unwrap();
            f.render_widget(PtyWidget::new(guard, self.repl_scroll), inner);
        } else {
            let lines = vec![
                Line::from(vec![]),
                Line::from(Span::styled(
                    "Press Enter to start perri REPL (claude --agent perri)",
                    theme::style_muted(),
                )),
            ];
            let p = Paragraph::new(lines);
            f.render_widget(p, inner);
        }
    }
}

impl View for PerriView {
    fn id(&self) -> &'static str {
        "perri"
    }

    fn title(&self) -> &str {
        "Perri"
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        // Error banner: show 1-row yellow banner if any snapshot has an error.
        let pr_error = self.pr_rx.borrow().as_ref().and_then(|s| s.error.clone());
        let queue_error = self
            .queue_rx
            .borrow()
            .as_ref()
            .and_then(|s| s.error.clone());
        let error_msg = pr_error.or(queue_error);

        let (content_area, banner_area) = if error_msg.is_some() {
            let banner = Rect { height: 1, ..area };
            let rest = Rect {
                y: area.y + 1,
                height: area.height.saturating_sub(1),
                ..area
            };
            (rest, Some(banner))
        } else {
            (area, None)
        };

        if let (Some(banner), Some(msg)) = (banner_area, error_msg.as_deref()) {
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!(" ⚠ {msg}"),
                    Style::default().fg(ratatui::style::Color::Yellow),
                ))),
                banner,
            );
        }

        // Ratio-based vertical split: top row (queue+diff) vs. REPL.
        let top_pct = (self.top_row_ratio * 100.0) as u16;
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Percentage(top_pct),
                Constraint::Percentage(100u16.saturating_sub(top_pct)),
            ])
            .split(content_area);
        self.top_row_area = content_area;
        self.top_row_divider_row = rows[1].y;

        // Ratio-based horizontal split: queue vs. diff.
        let queue_pct = (self.queue_ratio * 100.0) as u16;
        let top_cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Percentage(queue_pct),
                Constraint::Percentage(100u16.saturating_sub(queue_pct)),
            ])
            .split(rows[0]);
        self.top_cols_area = rows[0];
        self.queue_divider_col = top_cols[1].x;

        // Visual feedback: when dragging, highlight adjacent-pane borders.
        let dragging_id = match self.drag {
            DragState::Dragging { divider_id, .. } => Some(divider_id),
            DragState::Idle => None,
        };

        self.render_queue_with_drag(f, top_cols[0], dragging_id == Some(1));
        self.render_diff_with_drag(f, top_cols[1], dragging_id == Some(1));
        self.render_repl(f, rows[1]);

        if let Some(pty) = &mut self.pty {
            pty.resize(self.repl_area.width.max(1), self.repl_area.height.max(1));
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
            match k.code {
                KeyCode::Enter if self.pty.is_none() => {
                    let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                    match PtyHost::spawn(
                        "claude",
                        &["--agent", "perri"],
                        (cols, rows),
                        self.ctx.event_tx.clone(),
                        "perri",
                    ) {
                        Ok(host) => {
                            self.pty = Some(host);
                            self.pty_capturing = true;
                        }
                        Err(e) => {
                            tracing::warn!("failed to spawn PTY for perri: {e}");
                        }
                    }
                    return EventOutcome::Consumed;
                }
                KeyCode::Down | KeyCode::Char('j') if !self.pty_capturing => {
                    let len = self
                        .queue_rx
                        .borrow()
                        .as_ref()
                        .map(|s| s.items.len())
                        .unwrap_or(0);
                    if len > 0 {
                        self.selected_pr = (self.selected_pr + 1) % len;
                    }
                    return EventOutcome::Consumed;
                }
                KeyCode::Up | KeyCode::Char('k') if !self.pty_capturing => {
                    let len = self
                        .queue_rx
                        .borrow()
                        .as_ref()
                        .map(|s| s.items.len())
                        .unwrap_or(0);
                    if len > 0 {
                        self.selected_pr = self.selected_pr.checked_sub(1).unwrap_or(len - 1);
                    }
                    return EventOutcome::Consumed;
                }
                _ => {}
            }
        }

        // Mouse events: drag resize + scroll.
        if let AppEvent::Mouse(m) = ev {
            let in_repl = rect_contains(self.repl_area, m.column, m.row);
            let in_list = rect_contains(self.pr_list_area, m.column, m.row);
            let len = self
                .queue_rx
                .borrow()
                .as_ref()
                .map(|s| s.items.len())
                .unwrap_or(0);
            match m.kind {
                // ── drag start ────────────────────────────────────────────────
                MouseEventKind::Down(MouseButton::Left) => {
                    // Divider 0: horizontal top-row/REPL split.
                    if drag::hit_test(
                        m.column,
                        m.row,
                        0,
                        self.top_row_divider_row,
                        DividerAxis::Horizontal,
                        self.top_row_area,
                    ) {
                        self.drag = DragState::Dragging {
                            divider_id: 0,
                            parent: self.top_row_area,
                            axis: DividerAxis::Horizontal,
                        };
                        return EventOutcome::Consumed;
                    }
                    // Divider 1: vertical queue/diff split.
                    if drag::hit_test(
                        m.column,
                        m.row,
                        self.queue_divider_col,
                        0,
                        DividerAxis::Vertical,
                        self.top_cols_area,
                    ) {
                        self.drag = DragState::Dragging {
                            divider_id: 1,
                            parent: self.top_cols_area,
                            axis: DividerAxis::Vertical,
                        };
                        return EventOutcome::Consumed;
                    }
                }
                // ── drag move ─────────────────────────────────────────────────
                MouseEventKind::Drag(MouseButton::Left) => {
                    if let DragState::Dragging {
                        divider_id,
                        parent,
                        axis,
                    } = self.drag
                    {
                        let new_ratio = drag::ratio_from_mouse(parent, m.column, m.row, axis);
                        match divider_id {
                            0 => self.top_row_ratio = new_ratio,
                            1 => self.queue_ratio = new_ratio,
                            _ => {}
                        }
                        return EventOutcome::Consumed;
                    }
                }
                // ── drag end ──────────────────────────────────────────────────
                MouseEventKind::Up(MouseButton::Left) => {
                    if matches!(self.drag, DragState::Dragging { .. }) {
                        self.drag = DragState::Idle;
                        // Merge-save: load current file, update only perri ratios.
                        let mut p = pane_ratios::load();
                        p.perri.top_row = self.top_row_ratio;
                        p.perri.queue = self.queue_ratio;
                        pane_ratios::save(&p);
                        return EventOutcome::Consumed;
                    }
                }
                // ── scroll ────────────────────────────────────────────────────
                MouseEventKind::ScrollUp => {
                    if in_repl {
                        self.repl_scroll = self.repl_scroll.saturating_add(3);
                    } else if in_list && len > 0 {
                        self.selected_pr = self.selected_pr.checked_sub(1).unwrap_or(len - 1);
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if in_repl {
                        self.repl_scroll = self.repl_scroll.saturating_sub(3);
                    } else if in_list && len > 0 {
                        self.selected_pr = (self.selected_pr + 1) % len;
                    }
                    return EventOutcome::Consumed;
                }
                _ => {}
            }
        }

        EventOutcome::Ignored
    }

    fn on_tick(&mut self) {
        // If pr_rx was updated, clear any MCP-set diff override so the live
        // diff takes over again.
        if self.diff_override.is_some() && self.pr_rx.has_changed().unwrap_or(false) {
            let _ = self.pr_rx.borrow_and_update();
            self.diff_override = None;
        }
    }

    fn on_resize(&mut self, _area: Rect) {
        if let Some(pty) = &mut self.pty {
            pty.resize(self.repl_area.width.max(1), self.repl_area.height.max(1));
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

    fn apply_pane_content(
        &mut self,
        pane_id: &str,
        content: &crate::mcp::command::PaneContent,
    ) -> Result<(), String> {
        use crate::mcp::command::PaneContent;
        match pane_id {
            "pr_queue" => {
                // Queue is data-driven from the watch channel; reject mutations.
                Err("readonly_pane".into())
            }
            "diff" => match content {
                PaneContent::Text(s) => {
                    self.diff_override = Some(s.clone());
                    Ok(())
                }
                PaneContent::JsonSnapshot(_) => Err("unsupported_payload".into()),
            },
            "repl" => {
                // PTY-owned pane; reject mutations.
                Err("readonly_pane".into())
            }
            _ => Err("unknown_pane".into()),
        }
    }

    fn apply_pane_layout(&mut self, ratios: &serde_json::Value) -> Result<(), String> {
        let top_row = ratios.get("top_row")
            .and_then(|v| v.as_f64())
            .map(|v| v as f32);
        let queue = ratios.get("queue")
            .and_then(|v| v.as_f64())
            .map(|v| v as f32);

        if top_row.is_none() && queue.is_none() {
            return Err("invalid_args: expected top_row and/or queue fields".into());
        }
        if let Some(r) = top_row {
            self.top_row_ratio = pane_ratios::clamp(r);
        }
        if let Some(r) = queue {
            self.queue_ratio = pane_ratios::clamp(r);
        }
        let mut p = pane_ratios::load();
        p.perri.top_row = self.top_row_ratio;
        p.perri.queue = self.queue_ratio;
        pane_ratios::save(&p);
        Ok(())
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
