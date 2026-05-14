//! Perri view: PR queue (top-left) + syntax-highlighted diff / transcript (top-right) + PTY REPL.

use std::any::Any;
use std::collections::HashMap;
use std::sync::Arc;

use crossterm::event::{KeyCode, KeyModifiers, MouseButton, MouseEventKind};
use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph, Widget},
    Frame,
};
use tokio::sync::watch;

use crate::{
    config::Config,
    data::{perri_pr::PrSnapshot, perri_queue::PrQueueSnapshot},
    event::AppEvent,
    pty::{PtyHost, PtyWidget},
    transcript::{
        snapshot::{TranscriptEntry, TranscriptSnapshot},
        TranscriptReader,
    },
    ui::{
        drag::{self, DividerAxis, DragState},
        pane_ratios,
        theme,
        widgets::{
            syntect_cache::SyntectCache,
            syntect_diff::SyntectDiff,
            transcript::TranscriptWidget,
            transcript_layout::{scroll_to_cursor, TranscriptInteraction},
            truncate::truncate,
        },
    },
    views::{EventOutcome, View, ViewCtx},
};

const PERRI_PTY_TAG: &str = "perri";

pub struct PerriView {
    queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    pr_rx: watch::Receiver<Option<PrSnapshot>>,
    selected_pr: usize,
    #[allow(dead_code)]
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
    /// Last known inner area of the transcript pane (for mouse hit-testing).
    transcript_area: Rect,
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
    /// The Claude `--session-id` for the current PTY session, if known.
    current_session_id: Option<String>,
    /// Live transcript reader (present while transcript is visible).
    transcript_reader: Option<TranscriptReader>,
    /// Watch receiver for transcript snapshots.
    transcript_rx: Option<watch::Receiver<TranscriptSnapshot>>,
    /// Whether the transcript pane is shown (default false — opt-in via Ctrl+T).
    transcript_visible: bool,
    /// Top-of-viewport line offset for the transcript pane (0 = top).
    transcript_scroll_offset: u16,
    /// Interaction state: cursor, expanded set, thinking visibility.
    transcript_interaction: TranscriptInteraction,
    /// Render cache keyed by `(entry_index, is_expanded)`.
    transcript_cache: HashMap<(usize, bool), Vec<ratatui::text::Line<'static>>>,
    /// Inner width used to build `transcript_cache`; used to detect resizes.
    last_transcript_width: u16,
    /// Last known number of entries; used to detect appends for tail-follow.
    last_entry_count: usize,
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
        let session_id_from_store = {
            let store = crate::sessions::SessionStore::load();
            store.get(PERRI_PTY_TAG).and_then(|e| {
                if e.session_id.is_some() {
                    e.session_id.clone()
                } else {
                    let cwd = e.cwd.clone().or_else(|| std::env::current_dir().ok());
                    cwd.as_deref()
                        .and_then(crate::transcript::find_latest_session_id_for_cwd)
                }
            })
        };

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
            transcript_area: Rect::default(),
            repl_scroll: 0,
            top_row_ratio: ratios.perri.top_row,
            queue_ratio: ratios.perri.queue,
            drag: DragState::Idle,
            top_row_divider_row: 0,
            queue_divider_col: 0,
            top_row_area: Rect::default(),
            top_cols_area: Rect::default(),
            current_session_id: session_id_from_store,
            transcript_reader: None,
            transcript_rx: None,
            transcript_visible: false,
            transcript_scroll_offset: 0,
            transcript_interaction: TranscriptInteraction::default(),
            transcript_cache: HashMap::new(),
            last_transcript_width: 0,
            last_entry_count: 0,
        }
    }

    /// Focus the diff pane on the HEAD diff of a Mother worktree.
    pub fn focus_diff_for_worktree(&mut self, _path: &std::path::Path) {
        // No-op for now.
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

    fn render_transcript(&mut self, f: &mut Frame, area: Rect) {
        // Inner width excludes the 1-cell border on each side.
        let inner_w = area.width.saturating_sub(2);
        let inner_h = area.height.saturating_sub(2);

        // Invalidate render cache on width change or thinking-toggle.
        if inner_w != self.last_transcript_width {
            self.transcript_cache.clear();
            self.last_transcript_width = inner_w;
        }

        self.transcript_area = Rect {
            x: area.x + 1,
            y: area.y + 1,
            width: inner_w,
            height: inner_h,
        };

        if let Some(rx) = &self.transcript_rx {
            let snap = rx.borrow().clone();

            // Tail-follow: if following and the snapshot grew, advance cursor.
            let entry_count = snap.entries.len();
            if entry_count != self.last_entry_count {
                self.last_entry_count = entry_count;
                if self.transcript_interaction.following {
                    let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
                    if let Some(&last_nav) = nav.last() {
                        self.transcript_interaction.cursor = last_nav;
                    }
                }
            }

            // Compute layout to drive auto-scroll.
            let plan = crate::ui::widgets::transcript_layout::compute(
                &snap,
                &self.transcript_interaction,
                inner_w,
                &self.syntect,
                &mut self.transcript_cache,
            );
            self.transcript_scroll_offset = scroll_to_cursor(
                &plan.entry_rows,
                self.transcript_interaction.cursor,
                inner_h,
                self.transcript_scroll_offset,
            );

            TranscriptWidget::new(
                &snap,
                self.transcript_scroll_offset,
                &self.syntect,
                &mut self.transcript_cache,
                inner_w,
                &self.transcript_interaction,
            )
            .render(area, f.buffer_mut());
        } else {
            let block = Block::default()
                .borders(Borders::ALL)
                .border_style(Style::default().fg(theme::BORDER_ACTIVE))
                .title(Span::styled(
                    " Transcript ",
                    Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
                ));
            let inner = block.inner(area);
            f.render_widget(block, area);
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    " Starting transcript reader…",
                    theme::style_muted(),
                ))),
                inner,
            );
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

    // ── Transcript navigation helpers ─────────────────────────────────────────

    /// Move cursor to the next navigable entry (clamp at last).
    fn transcript_cursor_next(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
        if let Some(pos) = nav.iter().position(|&i| i == self.transcript_interaction.cursor) {
            if pos + 1 < nav.len() {
                self.transcript_interaction.cursor = nav[pos + 1];
            }
        } else if let Some(&first) = nav.first() {
            self.transcript_interaction.cursor = first;
        }
        // Following is off when the user explicitly navigates.
        let nav2 = snap.navigable_entries(self.transcript_interaction.show_thinking);
        self.transcript_interaction.following =
            nav2.last().copied() == Some(self.transcript_interaction.cursor);
    }

    /// Move cursor to the previous navigable entry (clamp at first).
    fn transcript_cursor_prev(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
        if let Some(pos) = nav.iter().position(|&i| i == self.transcript_interaction.cursor) {
            if pos > 0 {
                self.transcript_interaction.cursor = nav[pos - 1];
            }
        } else if let Some(&first) = nav.first() {
            self.transcript_interaction.cursor = first;
        }
        self.transcript_interaction.following = false;
    }

    /// Move cursor by `delta` navigable entries (positive = forward, negative = back).
    fn transcript_cursor_by(&mut self, snap: &TranscriptSnapshot, delta: isize) {
        let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
        if nav.is_empty() {
            return;
        }
        let pos = nav
            .iter()
            .position(|&i| i == self.transcript_interaction.cursor)
            .unwrap_or(0);
        let new_pos = (pos as isize + delta).clamp(0, nav.len() as isize - 1) as usize;
        self.transcript_interaction.cursor = nav[new_pos];
        self.transcript_interaction.following =
            new_pos + 1 == nav.len();
    }

    /// Jump to the first navigable entry.
    fn transcript_cursor_first(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
        if let Some(&first) = nav.first() {
            self.transcript_interaction.cursor = first;
        }
        self.transcript_interaction.following = false;
    }

    /// Jump to the last navigable entry and re-engage tail-follow.
    fn transcript_cursor_last(&mut self, snap: &TranscriptSnapshot) {
        let nav = snap.navigable_entries(self.transcript_interaction.show_thinking);
        if let Some(&last) = nav.last() {
            self.transcript_interaction.cursor = last;
        }
        self.transcript_interaction.following = true;
    }

    /// Toggle expansion of the current cursor entry.
    fn transcript_toggle_expand(&mut self) {
        let idx = self.transcript_interaction.cursor;
        if self.transcript_interaction.expanded.contains(&idx) {
            self.transcript_interaction.expanded.remove(&idx);
        } else {
            self.transcript_interaction.expanded.insert(idx);
        }
        // Expanding/collapsing invalidates the cached lines for this entry.
        self.transcript_cache.remove(&(idx, true));
        self.transcript_cache.remove(&(idx, false));
    }

    /// Toggle thinking visibility.  If turning off and cursor is on a Thinking
    /// entry, advance to the next visible entry.
    fn transcript_toggle_thinking(&mut self, snap: &TranscriptSnapshot) {
        self.transcript_interaction.show_thinking = !self.transcript_interaction.show_thinking;
        // Toggling invalidates all thinking-block cache entries.
        self.transcript_cache.retain(|(idx, _), _| {
            !matches!(snap.entries.get(*idx), Some(TranscriptEntry::Thinking(_)))
        });

        // If now hiding thinking and cursor is on a Thinking entry, advance.
        if !self.transcript_interaction.show_thinking {
            if let Some(TranscriptEntry::Thinking(_)) =
                snap.entries.get(self.transcript_interaction.cursor)
            {
                let nav = snap.navigable_entries(false);
                // Find the next entry after the current cursor.
                let next = nav
                    .iter()
                    .find(|&&i| i > self.transcript_interaction.cursor)
                    .or_else(|| nav.first())
                    .copied();
                if let Some(next_idx) = next {
                    self.transcript_interaction.cursor = next_idx;
                }
            }
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
        if self.transcript_visible {
            self.render_transcript(f, top_cols[1]);
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
            // Ctrl+T — toggle transcript pane (only in nav mode).
            if k.code == KeyCode::Char('t')
                && k.modifiers == KeyModifiers::CONTROL
                && !self.pty_capturing
            {
                self.transcript_visible = !self.transcript_visible;
                if self.transcript_visible && self.transcript_reader.is_none() {
                    if let Some(sid) = &self.current_session_id {
                        let cwd = std::env::current_dir()
                            .unwrap_or_else(|_| std::path::PathBuf::from("/tmp"));
                        let (reader, rx) = TranscriptReader::spawn(cwd, sid.clone());
                        self.transcript_reader = Some(reader);
                        self.transcript_rx = Some(rx);
                    }
                }
                self.transcript_scroll_offset = 0;
                return EventOutcome::Consumed;
            }

            // Transcript navigation keys — only when transcript visible and not capturing PTY.
            if self.transcript_visible && !self.pty_capturing {
                // Snapshot borrow must be released before mutably borrowing self.
                let snap_opt = self.transcript_rx.as_ref().map(|rx| rx.borrow().clone());

                match k.code {
                    // j / Down — next entry.
                    KeyCode::Char('j') | KeyCode::Down => {
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_next(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    // k / Up — previous entry.
                    KeyCode::Char('k') | KeyCode::Up => {
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_prev(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    // g / Home — jump to first.
                    KeyCode::Char('g') | KeyCode::Home => {
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_first(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    // G / End — jump to last, re-engage tail-follow.
                    KeyCode::Char('G') | KeyCode::End => {
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_last(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    // o / Enter — toggle expansion of current entry.
                    KeyCode::Char('o') | KeyCode::Enter => {
                        self.transcript_toggle_expand();
                        return EventOutcome::Consumed;
                    }
                    // T — toggle thinking visibility.
                    KeyCode::Char('T') => {
                        if let Some(snap) = snap_opt {
                            self.transcript_toggle_thinking(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    // PageUp — move cursor back by half pane height.
                    KeyCode::PageUp => {
                        let half = self.transcript_area.height / 2;
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_by(&snap, -(half as isize));
                        }
                        return EventOutcome::Consumed;
                    }
                    // PageDown — move cursor forward by half pane height.
                    KeyCode::PageDown => {
                        let half = self.transcript_area.height / 2;
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_by(&snap, half as isize);
                        }
                        return EventOutcome::Consumed;
                    }
                    _ => {}
                }
            }

            match k.code {
                KeyCode::Enter if self.pty.is_none() && !self.transcript_visible => {
                    let sid = uuid::Uuid::new_v4().to_string();
                    let sid_clone = sid.clone();
                    let (cols, rows) =
                        (self.repl_area.width.max(20), self.repl_area.height.max(5));
                    let args = [
                        "--dangerously-skip-permissions",
                        "--agent",
                        "perri",
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
                            self.transcript_reader = None;
                            self.transcript_rx = None;
                            self.transcript_scroll_offset = 0;
                            self.transcript_interaction = TranscriptInteraction::default();
                            self.transcript_cache.clear();
                            self.last_entry_count = 0;
                            self.current_session_id = Some(sid.clone());
                            let mut store = crate::sessions::SessionStore::load();
                            store.record(
                                PERRI_PTY_TAG,
                                "claude",
                                &args,
                                std::env::current_dir().ok(),
                                Some(sid),
                            );
                        }
                        Err(e) => {
                            tracing::warn!("failed to spawn PTY for perri: {e}");
                        }
                    }
                    return EventOutcome::Consumed;
                }
                KeyCode::Down | KeyCode::Char('j') if !self.pty_capturing && !self.transcript_visible => {
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
                KeyCode::Up | KeyCode::Char('k') if !self.pty_capturing && !self.transcript_visible => {
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
            let in_transcript = self.transcript_visible
                && rect_contains(self.transcript_area, m.column, m.row);
            let len = self
                .queue_rx
                .borrow()
                .as_ref()
                .map(|s| s.items.len())
                .unwrap_or(0);
            match m.kind {
                MouseEventKind::Down(MouseButton::Left) => {
                    // Check transcript area for left-click to toggle expansion.
                    if in_transcript {
                        // A click anywhere in the transcript pane toggles expand
                        // on the cursor entry (the layout highlight makes it clear
                        // which entry is focused).
                        self.transcript_toggle_expand();
                        return EventOutcome::Consumed;
                    }
                    if drag::hit_test(
                        m.column, m.row,
                        0, self.top_row_divider_row,
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
                        m.column, m.row,
                        self.queue_divider_col, 0,
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
                    if let DragState::Dragging { divider_id, parent, axis } = self.drag {
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
                    if in_transcript {
                        // Scroll wheel moves the cursor (keeps selection with eye movement).
                        let snap_opt = self.transcript_rx.as_ref().map(|rx| rx.borrow().clone());
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_prev(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
                    if in_repl {
                        self.repl_scroll = self.repl_scroll.saturating_add(3);
                    } else if in_list && len > 0 {
                        self.selected_pr = self.selected_pr.checked_sub(1).unwrap_or(len - 1);
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if in_transcript {
                        let snap_opt = self.transcript_rx.as_ref().map(|rx| rx.borrow().clone());
                        if let Some(snap) = snap_opt {
                            self.transcript_cursor_next(&snap);
                        }
                        return EventOutcome::Consumed;
                    }
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

        // On each Tick, drop the transcript reader if the PTY has exited.
        if matches!(ev, AppEvent::Tick) && self.pty.is_none() {
            self.transcript_reader = None;
            self.transcript_rx = None;
        }

        EventOutcome::Ignored
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
