//! Perri view: PR queue (top-left) + syntax-highlighted diff / transcript (top-right) + PTY REPL.

use std::any::Any;
use std::sync::Arc;

use crossterm::event::{KeyCode, KeyModifiers, MouseButton, MouseEventKind};
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
    data::{
        perri_pr::PrSnapshot,
        perri_queue::{CiState, PrQueueSnapshot},
    },
    event::AppEvent,
    pty::{PtyHost, PtyWidget},
    transcript::TranscriptPane,
    ui::{
        drag::{self, DividerAxis, DragState},
        pane_ratios, theme,
        widgets::{syntect_cache::SyntectCache, syntect_diff::SyntectDiff, truncate::truncate},
    },
    views::{EventOutcome, View, ViewCtx},
};

const PERRI_PTY_TAG: &str = "perri";

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
    // ── transcript pane ───────────────────────────────────────────────────────
    /// Transcript overlay helper (Ctrl+T toggles; shown in place of the diff).
    transcript: TranscriptPane,
    /// Last known area of the right column — used to pass to transcript mouse handler.
    transcript_render_area: Rect,
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
        // Try to recover a persisted session id from the session store so that
        // Ctrl+T works after Nostromo restarts without re-spawning the REPL.
        let mut transcript = TranscriptPane::new();
        let ratios = pane_ratios::load();

        let mut pty: Option<PtyHost> = None;
        let mut pty_capturing = false;

        {
            let store = crate::sessions::SessionStore::load();
            if let Some(entry) = store.get(PERRI_PTY_TAG) {
                // Restore transcript context.
                let sid_opt = entry.session_id.clone().or_else(|| {
                    entry
                        .cwd
                        .as_deref()
                        .and_then(crate::transcript::find_latest_session_id_for_cwd)
                });
                if let Some(sid) = sid_opt {
                    let cwd = entry
                        .cwd
                        .clone()
                        .or_else(|| std::env::current_dir().ok())
                        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"));
                    transcript.set_session_context(cwd, sid);
                }

                // Auto-spawn the REPL at the correct dimensions.
                // Perri's REPL occupies rows[1] — (1 - top_row_ratio) of terminal height.
                // Guard: skip in non-async contexts (e.g. snapshot tests) where PtyHost::spawn
                // would panic because no Tokio reactor is running.
                if tokio::runtime::Handle::try_current().is_ok() {
                    if let Ok((term_cols, term_rows)) = crossterm::terminal::size() {
                        let repl_rows = ((term_rows as f32) * (1.0 - ratios.perri.top_row)) as u16;
                        let cols = term_cols.max(20);
                        let rows = repl_rows.saturating_sub(2).max(5); // borders
                                                                       // Strip the stale --session-id and inject a fresh UUID so Claude
                                                                       // Code doesn't reject the spawn with "Session ID already in use".
                        let (fresh_args, new_sid) =
                            crate::views::agent_generic::freshen_session_id(&entry.args);
                        let args: Vec<&str> = fresh_args.iter().map(String::as_str).collect();
                        match PtyHost::spawn(
                            &entry.cmd,
                            &args,
                            (cols, rows),
                            ctx.event_tx.clone(),
                            PERRI_PTY_TAG,
                        ) {
                            Ok(host) => {
                                tracing::info!("perri: auto-spawned PTY at ({cols}x{rows})");
                                // Persist the fresh session ID and update transcript context.
                                let cwd =
                                    entry.cwd.clone().or_else(|| std::env::current_dir().ok());
                                let mut store = crate::sessions::SessionStore::load();
                                store.record(
                                    PERRI_PTY_TAG,
                                    &entry.cmd,
                                    &args,
                                    cwd.clone(),
                                    Some(new_sid.clone()),
                                );
                                if let Some(cwd) = cwd {
                                    transcript.set_session_context(cwd, new_sid);
                                }
                                pty = Some(host);
                                pty_capturing = true;
                            }
                            Err(e) => {
                                tracing::warn!("perri: auto-spawn failed: {e}");
                            }
                        }
                    }
                } // tokio runtime guard
            }
        }

        Self {
            queue_rx,
            pr_rx,
            selected_pr: 0,
            config,
            ctx,
            syntect,
            pty,
            pty_capturing,
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
            transcript,
            transcript_render_area: Rect::default(),
            diff_override: None,
        }
    }

    /// Focus the diff pane on the HEAD diff of a Mother worktree.
    pub fn focus_diff_for_worktree(&mut self, _path: &std::path::Path) {
        // No-op for now.
    }

    /// Write `current-pr.json` so the native watcher fetches the given PR.
    ///
    /// Constructs the minimal JSON shape accepted by `PerriPrNativeSource`
    /// and touches the `.dirty` sentinel.  The dirty-file watcher then picks
    /// it up and updates `pr_rx` within one poll cycle.
    pub fn load_pr(
        &mut self,
        number: u64,
        repo: String,
        highlights: Option<String>,
    ) -> Result<(), String> {
        let state_dir = self.config.perri_state_dir();
        std::fs::create_dir_all(&state_dir).map_err(|e| format!("io_error: {e}"))?;

        let pointer = serde_json::json!({
            "number": number,
            "repo": repo,
            "highlights": highlights,
        });
        let json = serde_json::to_string_pretty(&pointer)
            .map_err(|e| format!("serialization_failed: {e}"))?;

        let json_path = state_dir.join("current-pr.json");
        std::fs::write(&json_path, json.as_bytes()).map_err(|e| format!("io_error: {e}"))?;

        // Touch the dirty sentinel to wake the watcher.
        let dirty_path = state_dir.join("current-pr.dirty");
        std::fs::write(&dirty_path, b"").map_err(|e| format!("io_error: {e}"))?;

        // Clear any override so the live diff shows once pr_rx updates.
        self.diff_override = None;

        Ok(())
    }

    /// Remove `current-pr.json` and touch the dirty sentinel to clear Perri's diff pane.
    pub fn clear_current_pr(&mut self) -> Result<(), String> {
        let state_dir = self.config.perri_state_dir();
        let json_path = state_dir.join("current-pr.json");
        if json_path.exists() {
            std::fs::remove_file(&json_path).map_err(|e| format!("io_error: {e}"))?;
        }
        let dirty_path = state_dir.join("current-pr.dirty");
        std::fs::write(&dirty_path, b"").map_err(|e| format!("io_error: {e}"))?;

        self.diff_override = None;
        Ok(())
    }

    /// Return the current selected PR index.
    pub fn selected_pr_index(&self) -> usize {
        self.selected_pr
    }

    /// Set the selected PR index, clamped to the queue length.
    pub fn set_selected_pr_index(&mut self, index: usize) {
        let len = self
            .queue_rx
            .borrow()
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
                        let (req_glyph, req_style) = match pr.bucket.as_str() {
                            "requested" => ("● ", Style::default().fg(theme::BORDER_ACTIVE)),
                            "changes_req" => ("● ", theme::style_amber()),
                            _ => ("○ ", theme::style_normal()),
                        };

                        let selected_glyph = if i == self.selected_pr { "▶ " } else { "  " };
                        let number_str = format!("#{}", pr.number);
                        let repo_short = pr.repo.split('/').next_back().unwrap_or(&pr.repo);
                        // -18: 2 (selected) + 2 (bucket) + 2 (ci glyph) + 7 (number) + 1 (space)
                        // + 4 (repo short min) = leaves remaining for title
                        let label_width = (inner.width as usize).saturating_sub(18);
                        let title_str = truncate(&pr.title, label_width);

                        let ci_glyph = pr.ci_state.glyph();
                        let ci_style = match pr.ci_state {
                            CiState::Failure => theme::style_red(),
                            CiState::Pending => theme::style_amber(),
                            CiState::Success => theme::style_sage(),
                            CiState::Unknown => theme::style_muted(),
                        };

                        Line::from(vec![
                            Span::styled(selected_glyph, theme::style_muted()),
                            Span::styled(req_glyph, req_style),
                            Span::styled(format!("{ci_glyph} "), ci_style),
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
            let border_color = if dragging {
                theme::BORDER_ACTIVE
            } else {
                theme::BORDER_INACTIVE
            };
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
            // D6: skip CI block when there's nothing to show.
            let has_ci_data = !s.ci_checks.is_empty()
                || s.additions > 0
                || s.deletions > 0
                || s.changed_files > 0;

            if has_ci_data {
                // Build CI paragraph lines.
                let mut ci_lines: Vec<Line> = Vec::new();

                // Size header line.
                let file_word = if s.changed_files == 1 {
                    "file"
                } else {
                    "files"
                };
                ci_lines.push(Line::from(vec![
                    Span::styled(format!("+{}", s.additions), theme::style_sage()),
                    Span::styled(" / ", theme::style_muted()),
                    Span::styled(format!("-{}", s.deletions), theme::style_red()),
                    Span::styled(
                        format!(" · {} {} changed", s.changed_files, file_word),
                        theme::style_muted(),
                    ),
                ]));

                // Per-check lines.
                for check in &s.ci_checks {
                    let check_style = match check.state {
                        CiState::Failure => theme::style_red(),
                        CiState::Pending => theme::style_amber(),
                        CiState::Success => theme::style_sage(),
                        CiState::Unknown => theme::style_muted(),
                    };
                    ci_lines.push(Line::from(Span::styled(
                        format!("{} {}", check.state.glyph(), check.name),
                        check_style,
                    )));

                    // Expand failure log if present.
                    if let Some(detail) = &check.detail {
                        for log_line in detail.lines() {
                            ci_lines.push(Line::from(Span::styled(
                                log_line.to_owned(),
                                theme::style_muted(),
                            )));
                        }
                    }
                }

                // Separator line.
                let sep_width = inner.width as usize;
                ci_lines.push(Line::from(Span::styled(
                    "─".repeat(sep_width),
                    theme::style_muted(),
                )));

                // Cap CI block height at inner height - 3 (leave room for diff).
                let ci_height = (ci_lines.len() as u16).min(inner.height.saturating_sub(3));

                let chunks = Layout::default()
                    .direction(Direction::Vertical)
                    .constraints([Constraint::Length(ci_height), Constraint::Min(1)])
                    .split(inner);

                f.render_widget(Paragraph::new(ci_lines), chunks[0]);

                if s.diff.is_empty() {
                    let p = Paragraph::new(Line::from(Span::styled(
                        " No diff available",
                        theme::style_muted(),
                    )));
                    f.render_widget(p, chunks[1]);
                } else {
                    f.render_widget(
                        SyntectDiff::new(&s.diff, Arc::clone(&self.syntect))
                            .max_lines(chunks[1].height as usize),
                        chunks[1],
                    );
                }
            } else if s.diff.is_empty() {
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

        let dragging_id = match self.drag {
            DragState::Dragging { divider_id, .. } => Some(divider_id),
            DragState::Idle => None,
        };

        self.render_queue_with_drag(f, top_cols[0], dragging_id == Some(1));
        if self.transcript.is_visible() {
            self.transcript_render_area = top_cols[1];
            self.transcript.render(f, top_cols[1]);
        } else {
            self.render_diff_with_drag(f, top_cols[1], dragging_id == Some(1));
        }
        self.render_repl(f, rows[1]);

        if let Some(pty) = &mut self.pty {
            pty.resize(self.repl_area.width.max(1), self.repl_area.height.max(1));
        }
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
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

            // Transcript navigation — only when visible and not capturing.
            if self.transcript.is_visible() && !self.pty_capturing && self.transcript.on_key(k) {
                return EventOutcome::Consumed;
            }

            match k.code {
                KeyCode::Enter if self.pty.is_none() && !self.transcript.is_visible() => {
                    let sid = uuid::Uuid::new_v4().to_string();
                    let sid_clone = sid.clone();
                    let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                    let args = [
                        "--dangerously-skip-permissions",
                        "--agent",
                        "perri",
                        "--remote-control",
                        "Perri",
                        "-n",
                        "Perri",
                        "--session-id",
                        &sid_clone,
                    ];
                    match PtyHost::spawn(
                        "claude",
                        &args,
                        (cols, rows),
                        self.ctx.event_tx.clone(),
                        PERRI_PTY_TAG,
                    ) {
                        Ok(host) => {
                            self.pty = Some(host);
                            self.pty_capturing = true;
                            let cwd = std::env::current_dir()
                                .unwrap_or_else(|_| std::path::PathBuf::from("/tmp"));
                            self.transcript
                                .set_session_context(cwd.clone(), sid.clone());
                            let mut store = crate::sessions::SessionStore::load();
                            store.record(PERRI_PTY_TAG, "claude", &args, Some(cwd), Some(sid));
                        }
                        Err(e) => {
                            tracing::warn!("failed to spawn PTY for perri: {e}");
                        }
                    }
                    return EventOutcome::Consumed;
                }
                KeyCode::Down | KeyCode::Char('j')
                    if !self.pty_capturing && !self.transcript.is_visible() =>
                {
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
                KeyCode::Up | KeyCode::Char('k')
                    if !self.pty_capturing && !self.transcript.is_visible() =>
                {
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

        if let AppEvent::Mouse(m) = ev {
            let in_repl = rect_contains(self.repl_area, m.column, m.row);
            let in_list = rect_contains(self.pr_list_area, m.column, m.row);
            let len = self
                .queue_rx
                .borrow()
                .as_ref()
                .map(|s| s.items.len())
                .unwrap_or(0);

            // Delegate mouse events in the transcript area to the pane.
            if self.transcript.is_visible()
                && self.transcript.on_mouse(m, self.transcript_render_area)
            {
                return EventOutcome::Consumed;
            }

            match m.kind {
                MouseEventKind::Down(MouseButton::Left) => {
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
                MouseEventKind::Up(MouseButton::Left) => {
                    if matches!(self.drag, DragState::Dragging { .. }) {
                        self.drag = DragState::Idle;
                        let mut p = pane_ratios::load();
                        p.perri.top_row = self.top_row_ratio;
                        p.perri.queue = self.queue_ratio;
                        pane_ratios::save(&p);
                        return EventOutcome::Consumed;
                    }
                }
                MouseEventKind::ScrollUp => {
                    if in_repl {
                        if let Some(pty) = &mut self.pty {
                            let key = crossterm::event::KeyEvent::new(
                                crossterm::event::KeyCode::PageUp,
                                crossterm::event::KeyModifiers::NONE,
                            );
                            pty.send_key(&key);
                        }
                    } else if in_list && len > 0 {
                        self.selected_pr = self.selected_pr.checked_sub(1).unwrap_or(len - 1);
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if in_repl {
                        if let Some(pty) = &mut self.pty {
                            let key = crossterm::event::KeyEvent::new(
                                crossterm::event::KeyCode::PageDown,
                                crossterm::event::KeyModifiers::NONE,
                            );
                            pty.send_key(&key);
                        }
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
                PaneContent::JsonSnapshot(_) | PaneContent::PrList(_)
                | PaneContent::Loading | PaneContent::Error(_) => {
                    Err("unsupported_payload".into())
                }
            },
            "repl" => {
                // PTY-owned pane; reject mutations.
                Err("readonly_pane".into())
            }
            _ => Err("unknown_pane".into()),
        }
    }

    fn apply_pane_layout(&mut self, ratios: &serde_json::Value) -> Result<(), String> {
        let top_row = ratios
            .get("top_row")
            .and_then(|v| v.as_f64())
            .map(|v| v as f32);
        let queue = ratios
            .get("queue")
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
