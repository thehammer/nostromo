//! Fred view: mailbox (top-left) + calendar (top-right) + embedded PTY REPL.

use std::any::Any;
use std::collections::BTreeMap;
use std::sync::mpsc;

use chrono::{DateTime, Local, TimeZone};
use crossterm::event::{KeyCode, KeyModifiers, MouseButton, MouseEventKind};
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};
use ratatui_image::{
    picker::Picker,
    protocol::StatefulProtocol,
    thread::{ResizeRequest, ResizeResponse, ThreadProtocol},
    StatefulImage,
};
use std::sync::mpsc::Receiver as MpscReceiver;
use tokio::sync::watch;

use crate::{
    config::Config,
    data::{
        fred_calendar::CalendarEvent, fred_mailbox::MailboxSnapshot, rate_limits::PostureSnapshot,
    },
    event::AppEvent,
    pty::{PtyBackend, PtyWidget},
    ui::{
        drag::{self, DividerAxis, DragState},
        pane_ratios,
        theme::{self, Sweater},
        widgets::{relative_time::format_relative_now, truncate::truncate},
    },
    views::{
        fred_calendar_image::render_calendar_to_image, pace_bars_image::render_pace_bars_to_image,
        EventOutcome, View, ViewCtx,
    },
};

/// Tag used to identify Fred's PTY in the daemon registry.
const FRED_PTY_TAG: &str = "fred";

// ── Calendar timeline constants ───────────────────────────────────────────────

/// Working hours start (local, inclusive).
const WORK_START_HOUR: u32 = 8;
/// Working hours end (local, exclusive).
const WORK_END_HOUR: u32 = 18;
/// Minutes per visual row quantum.
const MINS_PER_ROW: i64 = 15;
/// Width of the time-label column ("HH:MM ").
const LABEL_COLS: usize = 6;

// ── Internal rendering types ──────────────────────────────────────────────────

/// What kind of visual cell an event occupies in a given slot row.
#[derive(Clone, Copy, Debug, PartialEq)]
enum CellKind {
    Top,
    Content { is_title_row: bool },
    Bottom,
}

/// Pre-computed display properties for one filtered event.
struct EvData {
    col: usize,
    start_local: DateTime<Local>,
    start_slot: i64,
    num_rows: i64,
    duration_str: String,
    title: String,
    is_cancelled: bool,
    is_tentative: bool,
    is_now_ev: bool,
    is_past: bool,
}

// ── FredView ──────────────────────────────────────────────────────────────────

pub struct FredView {
    mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
    calendar_rx: watch::Receiver<Option<crate::data::fred_calendar::CalendarSnapshot>>,
    #[allow(dead_code)]
    config: Config,
    ctx: ViewCtx,
    pty: Option<PtyBackend>,
    /// Whether the PTY is currently capturing keystrokes.
    pty_capturing: bool,
    /// Last known inner area of the REPL pane.
    repl_area: Rect,
    /// Last known inner area of the calendar pane.
    calendar_area: Rect,
    /// Current scroll offset for the calendar pane (number of 15-min slot rows).
    calendar_scroll: u16,
    /// Rows scrolled back in the REPL pane (0 = live view).
    repl_scroll: u16,

    // ── Kitty-protocol image rendering ───────────────────────────────────────
    /// Graphics-protocol picker (Kitty / sixel / halfblock fallback).
    picker: Picker,
    /// Active `ThreadProtocol` state for the calendar image.
    calendar_image_state: Option<ThreadProtocol>,
    /// `StatefulProtocol` for the pace-bars widget (rebuilt on change).
    pace_bars_image_state: Option<StatefulProtocol>,
    /// `loaded_at` of the snapshot used for the last pace-bars render,
    /// for cache-busting: when this changes we re-encode the image.
    pace_bars_last_loaded_at: Option<std::time::Instant>,
    /// Cell-area size `(cols, rows)` from the last pace-bars render.
    pace_bars_last_size: Option<(u16, u16)>,
    /// Latest posture snapshot forwarded from `AppEvent::PostureSnapshot`.
    posture_snapshot: Option<PostureSnapshot>,
    /// Sender side of the background resize-encode worker channel.
    resize_tx: mpsc::Sender<ResizeRequest>,
    /// Receiver for completed `ResizeResponse` values from the worker.
    /// Polled non-blocking in `render_calendar` each frame.
    resize_result_rx: MpscReceiver<ResizeResponse>,
    /// `(area, scroll)` from the last time we issued an image generation
    /// request — used to detect when a re-render is needed.
    calendar_last_rendered: Option<(Rect, u16)>,

    // ── pane resize ──────────────────────────────────────────────────────────
    /// Fraction of vertical space given to the top row (mailbox+calendar) vs. REPL.
    col_ratio: f32,
    /// Fraction of horizontal space given to the mailbox vs. calendar.
    row_ratio: f32,
    /// Current drag state.
    drag: DragState,
    /// Y coordinate of the horizontal divider between top row and REPL.
    row_divider_row: u16,
    /// X coordinate of the vertical divider between mailbox and calendar.
    col_divider_col: u16,
    /// Parent rect for the vertical (top/REPL) split.
    main_area: Rect,
    /// Parent rect for the horizontal (mailbox/calendar) split.
    top_area: Rect,
}

impl FredView {
    pub fn new(
        mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
        calendar_rx: watch::Receiver<Option<crate::data::fred_calendar::CalendarSnapshot>>,
        config: Config,
        ctx: ViewCtx,
        picker: Picker,
    ) -> Self {
        // Attempt to reattach to an existing daemon PTY for this view.
        let mut pty = Self::try_reattach(&ctx);

        // If no live daemon PTY exists, check the session store and auto-spawn.
        if pty.is_none() {
            if let Some(entry) = crate::sessions::SessionStore::load()
                .get(FRED_PTY_TAG)
                .cloned()
            {
                let (cols, rows) = (80u16, 24u16);
                let args: Vec<&str> = entry.args.iter().map(String::as_str).collect();
                match ctx.pty_factory.spawn(
                    FRED_PTY_TAG,
                    &entry.cmd,
                    &args,
                    (cols, rows),
                    ctx.event_tx.clone(),
                ) {
                    Ok(backend) => {
                        tracing::info!(
                            view_tag = FRED_PTY_TAG,
                            "auto-spawned PTY from session store"
                        );
                        pty = Some(backend);
                    }
                    Err(e) => {
                        tracing::warn!("session-store auto-spawn failed for {FRED_PTY_TAG}: {e}");
                    }
                }
            }
        }

        let pty_capturing = pty.is_some();
        let ratios = pane_ratios::load();

        // Spawn the background resize-encode worker thread.
        // Requests flow in via `resize_tx`; completed responses come back on
        // `resize_result_rx` (polled non-blocking in `render_calendar`).
        let (resize_tx, resize_rx) = mpsc::channel::<ResizeRequest>();
        let (result_tx, resize_result_rx) = mpsc::channel::<ResizeResponse>();
        std::thread::spawn(move || {
            while let Ok(request) = resize_rx.recv() {
                if let Ok(response) = request.resize_encode() {
                    let _ = result_tx.send(response);
                }
            }
        });

        Self {
            mailbox_rx,
            calendar_rx,
            config,
            ctx,
            pty,
            pty_capturing,
            repl_area: Rect::new(0, 0, 80, 10),
            calendar_area: Rect::new(0, 0, 80, 10),
            calendar_scroll: 0,
            repl_scroll: 0,
            picker,
            calendar_image_state: None,
            pace_bars_image_state: None,
            pace_bars_last_loaded_at: None,
            pace_bars_last_size: None,
            posture_snapshot: None,
            resize_tx,
            resize_result_rx,
            calendar_last_rendered: None,
            col_ratio: ratios.fred.col,
            row_ratio: ratios.fred.row,
            drag: DragState::Idle,
            row_divider_row: 0,
            col_divider_col: 0,
            main_area: Rect::default(),
            top_area: Rect::default(),
        }
    }

    /// Reattach to a live daemon PTY if one exists for this view tag.
    fn try_reattach(ctx: &ViewCtx) -> Option<PtyBackend> {
        let existing = ctx.pty_factory.list_existing(FRED_PTY_TAG);
        let info = existing.into_iter().find(|p| p.alive)?;

        tracing::info!(
            pty_id = %info.pty_id,
            "Fred view reattaching to existing daemon PTY"
        );

        ctx.pty_factory
            .attach(
                &info.pty_id,
                (info.cols, info.rows),
                ctx.event_tx.clone(),
                FRED_PTY_TAG,
            )
            .ok()
    }

    /// Clone the current mailbox snapshot (for status bar use in ui::render).
    pub fn mailbox_snapshot_cloned(&self) -> Option<MailboxSnapshot> {
        self.mailbox_rx.borrow().clone()
    }

    /// Clone the current calendar snapshot.
    pub fn calendar_snapshot_cloned(&self) -> Option<crate::data::fred_calendar::CalendarSnapshot> {
        self.calendar_rx.borrow().clone()
    }

    fn render_mailbox(&self, f: &mut Frame, area: Rect) {
        let snap = self.mailbox_rx.borrow();
        let snap = snap.as_ref();

        let unread = snap.map(|s| s.unread_count).unwrap_or(0);
        let stale = snap.map(|s| s.stale).unwrap_or(false);

        let title_suffix = if stale { " (stale)" } else { "" };
        let title = if unread > 0 {
            format!(" ✉ Mailbox [{unread}]{title_suffix} ")
        } else {
            format!(" ✉ Mailbox{title_suffix} ")
        };

        let border_style = if unread > 0 {
            Style::default().fg(theme::UNREAD)
        } else {
            Style::default().fg(theme::BORDER_INACTIVE)
        };

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(border_style)
            .title(Span::styled(
                title,
                Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        // Auth-prompt rendering.
        if let Some(Some(prompt)) = snap.map(|s| s.auth_prompt.as_ref()) {
            let remaining = prompt.expires_at - chrono::Utc::now();
            let mins = remaining.num_minutes().max(0);
            let secs = remaining.num_seconds().max(0) % 60;

            let lines = vec![
                Line::from(Span::styled(
                    "Microsoft sign-in required",
                    Style::default()
                        .fg(theme::AMBER)
                        .add_modifier(Modifier::BOLD),
                )),
                Line::from(vec![]),
                Line::from(vec![
                    Span::styled("Visit:  ", theme::style_muted()),
                    Span::styled(
                        prompt.verification_uri.clone(),
                        Style::default()
                            .fg(theme::FG)
                            .add_modifier(Modifier::UNDERLINED),
                    ),
                ]),
                Line::from(vec![
                    Span::styled("Code:   ", theme::style_muted()),
                    Span::styled(
                        prompt.user_code.clone(),
                        Style::default()
                            .fg(theme::AMBER)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]),
                Line::from(vec![]),
                Line::from(Span::styled(
                    format!("(expires in {mins:02}:{secs:02})"),
                    theme::style_muted(),
                )),
            ];
            let p = Paragraph::new(lines).alignment(Alignment::Center);
            f.render_widget(p, inner);
            return;
        }

        let items: Vec<ListItem> = if let Some(s) = snap {
            s.items
                .iter()
                .map(|item| {
                    let from_style = if item.vip {
                        theme::style_vip()
                    } else if !item.is_read {
                        theme::style_unread()
                    } else {
                        theme::style_muted()
                    };

                    let invite_glyph = if item.is_invite { "📅 " } else { "" };
                    let unread_glyph = if !item.is_read { "● " } else { "  " };

                    let from_width = (inner.width as usize / 3).max(8);
                    let subj_width = inner.width as usize - from_width - 12;

                    let from_str = truncate(&item.from, from_width);
                    let subj_str = truncate(
                        &format!("{invite_glyph}{}", item.subject),
                        subj_width.max(4),
                    );

                    let age = item
                        .received_at
                        .as_ref()
                        .map(format_relative_now)
                        .unwrap_or_else(|| "?".into());

                    let line = Line::from(vec![
                        Span::styled(unread_glyph, from_style),
                        Span::styled(format!("{from_str:<from_width$} "), from_style),
                        Span::styled(subj_str, theme::style_normal()),
                        Span::styled(format!(" {age:>4}"), theme::style_muted()),
                    ]);

                    ListItem::new(line)
                })
                .collect()
        } else {
            vec![ListItem::new(Line::from(Span::styled(
                " Loading mailbox…",
                theme::style_muted(),
            )))]
        };

        let list = List::new(items);
        f.render_widget(list, inner);
    }

    fn render_calendar(&mut self, f: &mut Frame, area: Rect) {
        // ── Draw border & title ────────────────────────────────────────────
        let (sweater, stale, has_snap) = {
            let snap = self.calendar_rx.borrow();
            let s = snap.as_ref();
            (
                s.map(|x| Sweater::from_str(&x.sweater)).unwrap_or_default(),
                s.map(|x| x.stale).unwrap_or(false),
                s.is_some(),
            )
        };

        let stale_suffix = if stale { " (stale)" } else { "" };
        let border_style = Style::default().fg(sweater.color());
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(border_style)
            .title(Span::styled(
                format!(" 📅 Calendar{stale_suffix} "),
                Style::default()
                    .fg(sweater.color())
                    .add_modifier(Modifier::BOLD),
            ));
        let inner = block.inner(area);
        f.render_widget(block, area);

        // ── Pace bars strip (4 rows, above the calendar image) ─────────────
        const PACE_STRIP_ROWS: u16 = 4;
        let (pace_strip, cal_inner) = if inner.width >= 20 && inner.height > PACE_STRIP_ROWS {
            let chunks = Layout::default()
                .direction(Direction::Vertical)
                .constraints([Constraint::Length(PACE_STRIP_ROWS), Constraint::Min(0)])
                .split(inner);
            (Some(chunks[0]), chunks[1])
        } else {
            (None, inner)
        };

        // Render pace bars into the strip when available.
        if let Some(strip) = pace_strip {
            self.render_pace_bars(f, strip);
        }

        self.calendar_area = cal_inner;

        if !has_snap {
            let p = Paragraph::new(Line::from(Span::styled(
                " Loading calendar…",
                theme::style_muted(),
            )));
            f.render_widget(p, cal_inner);
            return;
        }

        // ── Auto-scroll: anchor near the "now" row ─────────────────────────
        // Compute focus_idx from the ASCII render helper so scroll behaviour
        // is identical to the old text path.
        {
            let snap = self.calendar_rx.borrow();
            if let Some(s) = snap.as_ref() {
                let now = chrono::Local::now();
                let (lines, focus_idx) = render_calendar_lines(
                    &s.events,
                    now,
                    cal_inner.width,
                    cal_inner.height,
                    sweater,
                );
                let viewport = cal_inner.height as usize;
                if let Some(fi) = focus_idx {
                    let target_top = fi.saturating_sub(2);
                    let max_top = lines.len().saturating_sub(viewport);
                    self.calendar_scroll = target_top.min(max_top) as u16;
                }
            }
        }

        // ── Drain any completed resize responses ───────────────────────────
        while let Ok(response) = self.resize_result_rx.try_recv() {
            if let Some(state) = &mut self.calendar_image_state {
                state.update_resized_protocol(response);
            }
        }

        // ── Compute pixel dimensions ───────────────────────────────────────
        let font_size = self.picker.font_size();
        let w_px = (cal_inner.width as u32) * (font_size.width as u32);
        let h_px = (cal_inner.height as u32) * (font_size.height as u32);

        // ── Re-generate image if area or scroll changed ────────────────────
        let needs_regen = self
            .calendar_last_rendered
            .map(|(r, s)| r != cal_inner || s != self.calendar_scroll)
            .unwrap_or(true);

        if needs_regen {
            let snap = self.calendar_rx.borrow().clone();
            if let Some(snap) = snap {
                let scroll = self.calendar_scroll;
                let cell_h = font_size.height;
                let dyn_img = render_calendar_to_image(&snap, w_px, h_px, scroll, cell_h);
                let protocol: StatefulProtocol = self.picker.new_resize_protocol(dyn_img);
                self.calendar_image_state =
                    Some(ThreadProtocol::new(self.resize_tx.clone(), Some(protocol)));
                self.calendar_last_rendered = Some((cal_inner, self.calendar_scroll));
            }
        }

        // ── Render image widget ───────────────────────────────────────────
        if let Some(state) = &mut self.calendar_image_state {
            f.render_stateful_widget(StatefulImage::new(), cal_inner, state);
        }
    }

    /// Render the pace-bars pixel widget into the 4-row strip.
    fn render_pace_bars(&mut self, f: &mut Frame, area: Rect) {
        let snap = match self.posture_snapshot.as_ref() {
            Some(s) => s,
            None => return, // nothing to render yet
        };

        let font_size = self.picker.font_size();
        let cell_size = (area.width, area.height);
        let loaded_at = snap.loaded_at;

        // Rebuild the protocol when the snapshot changed or the area resized.
        let needs_regen = self.pace_bars_image_state.is_none()
            || self.pace_bars_last_size != Some(cell_size)
            || self.pace_bars_last_loaded_at != Some(loaded_at);

        if needs_regen {
            let w_px = (area.width as u32) * (font_size.width as u32);
            let h_px = (area.height as u32) * (font_size.height as u32);
            let dyn_img = render_pace_bars_to_image(snap, w_px, h_px);
            self.pace_bars_image_state = Some(self.picker.new_resize_protocol(dyn_img));
            self.pace_bars_last_loaded_at = Some(loaded_at);
            self.pace_bars_last_size = Some(cell_size);
        }

        if let Some(state) = &mut self.pace_bars_image_state {
            f.render_stateful_widget(StatefulImage::new(), area, state);
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
            let parser = pty.parser();
            let guard = parser.lock().unwrap();
            f.render_widget(PtyWidget::new(guard, self.repl_scroll), inner);
        } else {
            let lines = vec![
                Line::from(vec![]),
                Line::from(Span::styled(
                    "Press Enter to start fred REPL (claude --agent fred)",
                    theme::style_muted(),
                )),
            ];
            let p = Paragraph::new(lines);
            f.render_widget(p, inner);
        }
    }
}

impl View for FredView {
    fn id(&self) -> &'static str {
        "fred"
    }

    fn title(&self) -> &str {
        "Fred"
    }

    fn render(&mut self, f: &mut Frame, area: Rect) {
        // Error banner: show 1-row yellow banner if any snapshot has an error.
        let mailbox_error = self
            .mailbox_rx
            .borrow()
            .as_ref()
            .and_then(|s| s.error.clone());
        let calendar_error = self
            .calendar_rx
            .borrow()
            .as_ref()
            .and_then(|s| s.error.clone());
        let error_msg = mailbox_error.or(calendar_error);

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

        if let (Some(banner), Some(ref msg)) = (banner_area, &error_msg) {
            f.render_widget(
                Paragraph::new(Line::from(Span::styled(
                    format!(" ⚠ {msg}"),
                    Style::default().fg(ratatui::style::Color::Yellow),
                ))),
                banner,
            );
        }

        // Ratio-based vertical split: top row (mailbox+calendar) vs. REPL.
        let col_pct = (self.col_ratio * 100.0) as u16;
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Percentage(col_pct),
                Constraint::Percentage(100u16.saturating_sub(col_pct)),
            ])
            .split(content_area);
        self.main_area = content_area;
        self.row_divider_row = rows[1].y;

        // Ratio-based horizontal split: mailbox vs. calendar.
        let row_pct = (self.row_ratio * 100.0) as u16;
        let top_cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([
                Constraint::Percentage(row_pct),
                Constraint::Percentage(100u16.saturating_sub(row_pct)),
            ])
            .split(rows[0]);
        self.top_area = rows[0];
        self.col_divider_col = top_cols[1].x;

        // Visual feedback when dragging.
        let dragging_id = match self.drag {
            DragState::Dragging { divider_id, .. } => Some(divider_id),
            DragState::Idle => None,
        };
        let _ = dragging_id; // highlight would need to be passed into render helpers

        self.render_mailbox(f, top_cols[0]);
        self.render_calendar(f, top_cols[1]);
        self.render_repl(f, rows[1]);

        // Resize PTY if the pane size changed.
        if let Some(pty) = &mut self.pty {
            pty.resize(self.repl_area.width.max(1), self.repl_area.height.max(1));
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

        // Cache the latest posture snapshot for the pace-bars widget.
        if let AppEvent::PostureSnapshot(snap) = ev {
            self.posture_snapshot = Some(snap.clone());
            // Invalidate cached state so the bars re-encode on next render.
            self.pace_bars_last_loaded_at = None;
            return EventOutcome::Consumed;
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
            if k.code == KeyCode::Enter && self.pty.is_none() {
                let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                match self.ctx.pty_factory.spawn(
                    FRED_PTY_TAG,
                    "claude",
                    &["--agent", "fred"],
                    (cols, rows),
                    self.ctx.event_tx.clone(),
                ) {
                    Ok(backend) => {
                        self.pty = Some(backend);
                        self.pty_capturing = true;
                        let mut store = crate::sessions::SessionStore::load();
                        store.record(
                            FRED_PTY_TAG,
                            "claude",
                            &["--agent", "fred"],
                            std::env::current_dir().ok(),
                        );
                        // TODO: remove session entry on PTY exit (no AppEvent::PtyExited today)
                    }
                    Err(e) => {
                        tracing::warn!("failed to spawn PTY for fred: {e}");
                    }
                }
                return EventOutcome::Consumed;
            }
        }

        // Mouse events: drag resize + scroll.
        if let AppEvent::Mouse(m) = ev {
            let in_repl = rect_contains(self.repl_area, m.column, m.row);
            let in_calendar = rect_contains(self.calendar_area, m.column, m.row);
            match m.kind {
                // ── drag start ────────────────────────────────────────────────
                MouseEventKind::Down(MouseButton::Left) => {
                    // Divider 0: horizontal top-row/REPL split.
                    if drag::hit_test(
                        m.column,
                        m.row,
                        0,
                        self.row_divider_row,
                        DividerAxis::Horizontal,
                        self.main_area,
                    ) {
                        self.drag = DragState::Dragging {
                            divider_id: 0,
                            parent: self.main_area,
                            axis: DividerAxis::Horizontal,
                        };
                        return EventOutcome::Consumed;
                    }
                    // Divider 1: vertical mailbox/calendar split.
                    if drag::hit_test(
                        m.column,
                        m.row,
                        self.col_divider_col,
                        0,
                        DividerAxis::Vertical,
                        self.top_area,
                    ) {
                        self.drag = DragState::Dragging {
                            divider_id: 1,
                            parent: self.top_area,
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
                            0 => self.col_ratio = new_ratio,
                            1 => self.row_ratio = new_ratio,
                            _ => {}
                        }
                        return EventOutcome::Consumed;
                    }
                }
                // ── drag end ──────────────────────────────────────────────────
                MouseEventKind::Up(MouseButton::Left) => {
                    if matches!(self.drag, DragState::Dragging { .. }) {
                        self.drag = DragState::Idle;
                        let mut p = pane_ratios::load();
                        p.fred.col = self.col_ratio;
                        p.fred.row = self.row_ratio;
                        pane_ratios::save(&p);
                        return EventOutcome::Consumed;
                    }
                }
                // ── scroll ────────────────────────────────────────────────────
                MouseEventKind::ScrollUp => {
                    if in_repl {
                        self.repl_scroll = self.repl_scroll.saturating_add(3);
                    } else if in_calendar {
                        self.calendar_scroll = self.calendar_scroll.saturating_sub(3);
                    }
                    return EventOutcome::Consumed;
                }
                MouseEventKind::ScrollDown => {
                    if in_repl {
                        self.repl_scroll = self.repl_scroll.saturating_sub(3);
                    } else if in_calendar {
                        self.calendar_scroll = self.calendar_scroll.saturating_add(3);
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
        _content: &crate::mcp::command::PaneContent,
    ) -> Result<(), String> {
        match pane_id {
            "mailbox" | "calendar" => Err("readonly_pane".into()),
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

// ── Public(crate) calendar rendering functions ────────────────────────────────

/// Assign display columns to events using greedy interval scheduling.
///
/// Returns a vec of column indices in the same order as `events`. Column 0 is
/// the leftmost. Events sorted by start time are greedily packed into the
/// smallest available column. Events with `start = None` are assigned column 0.
pub fn assign_columns(events: &[CalendarEvent]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..events.len()).collect();
    order.sort_by_key(|&i| events[i].start);

    let mut cols = vec![0usize; events.len()];
    // Track when each column becomes free (i.e., the end time of the event in it).
    let mut col_free: Vec<Option<chrono::DateTime<chrono::Utc>>> = Vec::new();

    for &idx in &order {
        let ev = &events[idx];
        // Find the smallest column that is free at ev.start.
        let col = col_free
            .iter()
            .position(|free_at| match (free_at, ev.start) {
                (Some(f), Some(s)) => *f <= s,
                _ => true, // None start/end: treat as non-overlapping
            })
            .unwrap_or(col_free.len());

        if col >= col_free.len() {
            col_free.resize(col + 1, None);
        }
        col_free[col] = ev.end;
        cols[idx] = col;
    }

    cols
}

/// Build visual `Line`s for the calendar timeline pane.
///
/// Returns `(lines, focus_idx)`:
/// - `lines`: ready to render via `Paragraph::new(lines).scroll(…)`
/// - `focus_idx`: line index of the "now" marker or first upcoming event top
///   border, used by the caller to compute the auto-scroll offset.
///
/// Only events whose `start` falls in `[08:00, 18:00)` local are rendered.
/// Gap compression is applied: no blank rows appear between event blocks.
pub fn render_calendar_lines(
    events: &[CalendarEvent],
    now: DateTime<Local>,
    width: u16,
    height: u16,
    _sweater: Sweater,
) -> (Vec<Line<'static>>, Option<usize>) {
    use crate::ui::widgets::truncate::pad_or_truncate;

    let today = now.date_naive();

    let work_start = Local
        .from_local_datetime(&today.and_hms_opt(WORK_START_HOUR, 0, 0).unwrap())
        .earliest()
        .unwrap();
    let work_end = Local
        .from_local_datetime(&today.and_hms_opt(WORK_END_HOUR, 0, 0).unwrap())
        .earliest()
        .unwrap();

    let now_within_hours = now >= work_start && now < work_end;
    // Slot index for "now" (clamped to valid range).
    let now_slot = ((now - work_start).num_minutes() / MINS_PER_ROW).max(0);

    // ── Filter events to working hours ──
    let filtered_indices: Vec<usize> = events
        .iter()
        .enumerate()
        .filter(|(_, ev)| {
            ev.start.is_some_and(|utc| {
                let local: DateTime<Local> = utc.into();
                local >= work_start && local < work_end
            })
        })
        .map(|(i, _)| i)
        .collect();

    if filtered_indices.is_empty() {
        if now_within_hours {
            return (vec![build_now_line(width)], Some(0));
        }
        return (
            vec![Line::from(Span::styled(
                " No events today",
                theme::style_muted(),
            ))],
            None,
        );
    }

    // ── Column assignment ──
    let all_cols = assign_columns(events);

    // ── Build EvData for each filtered event ──
    let ev_data: Vec<EvData> = filtered_indices
        .iter()
        .map(|&orig| {
            let ev = &events[orig];
            let col = all_cols[orig];

            let start_utc = ev.start.unwrap();
            let end_utc = ev.end.unwrap_or(start_utc + chrono::Duration::minutes(30));
            let start_local: DateTime<Local> = start_utc.into();
            let end_local: DateTime<Local> = end_utc.into();

            let duration_mins = (end_local - start_local).num_minutes().max(1);
            let cap = ((height as i64) / 3).max(1);
            let num_rows = ((duration_mins + MINS_PER_ROW - 1) / MINS_PER_ROW)
                .max(1)
                .min(cap);

            let duration_str = format_duration(duration_mins);

            let mins_from_ws = (start_local - work_start).num_minutes();
            let start_slot = (mins_from_ws / MINS_PER_ROW).max(0);

            let is_cancelled = ev.status == "cancelled" || ev.status == "declined";
            let is_tentative = ev.status == "tentativelyAccepted";
            let is_now_ev = ev.is_now;
            let is_past = !is_now_ev && end_local < now;

            EvData {
                col,
                start_local,
                start_slot,
                num_rows,
                duration_str,
                title: ev.title.clone(),
                is_cancelled,
                is_tentative,
                is_now_ev,
                is_past,
            }
        })
        .collect();

    let max_cols = ev_data.iter().map(|e| e.col).max().unwrap_or(0) + 1;
    let any_is_now = ev_data.iter().any(|e| e.is_now_ev);

    // First upcoming event index in ev_data (for bold-white time label).
    let first_upcoming: Option<usize> = ev_data
        .iter()
        .enumerate()
        .filter(|(_, e)| !e.is_past && !e.is_now_ev && !e.is_cancelled)
        .min_by_key(|(_, e)| e.start_local)
        .map(|(i, _)| i);

    // ── Column widths ──
    let content_width = (width as usize).saturating_sub(LABEL_COLS);
    let col_width = content_width.checked_div(max_cols).unwrap_or(content_width);
    let inner_width = col_width.saturating_sub(2);

    // ── Build slot grid ──
    // slot_idx → Vec<Option<(ev_data_idx, CellKind)>>, indexed by column.
    let mut grid: BTreeMap<i64, Vec<Option<(usize, CellKind)>>> = BTreeMap::new();

    for (ev_idx, info) in ev_data.iter().enumerate() {
        let col = info.col;
        let top = info.start_slot;
        let bot = top + info.num_rows + 1;

        // Top border (always placed; overwrites if needed since top borders
        // are placed first and the event owns its start slot).
        grid.entry(top).or_insert_with(|| vec![None; max_cols])[col] =
            Some((ev_idx, CellKind::Top));

        // Content rows (only fill empty cells to avoid clobbering neighbours).
        for cr in 1..=info.num_rows {
            let slot = top + cr;
            let row = grid.entry(slot).or_insert_with(|| vec![None; max_cols]);
            if row[col].is_none() {
                row[col] = Some((
                    ev_idx,
                    CellKind::Content {
                        is_title_row: cr == 1,
                    },
                ));
            }
        }

        // Bottom border (only if slot is unoccupied in this column).
        let row = grid.entry(bot).or_insert_with(|| vec![None; max_cols]);
        if row[col].is_none() {
            row[col] = Some((ev_idx, CellKind::Bottom));
        }
    }

    // ── Walk grid and emit lines ──
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut focus_idx: Option<usize> = None;
    let mut prev_slot: Option<i64> = None;
    let mut now_inserted = false;

    for (&slot, row) in &grid {
        // Insert now marker in any gap before this slot.
        if !now_inserted && now_within_hours && !any_is_now {
            let in_gap = match prev_slot {
                None => now_slot < slot,
                Some(p) => now_slot > p && now_slot < slot,
            };
            if in_gap {
                if focus_idx.is_none() {
                    focus_idx = Some(lines.len());
                }
                lines.push(build_now_line(width));
                now_inserted = true;
            }
        }

        // Track focus for first upcoming event's top border row.
        if focus_idx.is_none() {
            let is_first_upcoming_top = first_upcoming.is_some_and(|fi| {
                row.iter()
                    .any(|cell| matches!(cell, Some((ei, CellKind::Top)) if *ei == fi))
            });
            if is_first_upcoming_top {
                focus_idx = Some(lines.len());
            }
        }

        lines.push(build_slot_line(
            slot,
            row,
            &ev_data,
            &work_start,
            first_upcoming,
            col_width,
            inner_width,
            max_cols,
            &pad_or_truncate,
        ));
        prev_slot = Some(slot);
    }

    // Now marker after last event.
    if !now_inserted && now_within_hours && !any_is_now {
        if let Some(last) = prev_slot {
            if now_slot >= last {
                lines.push(build_now_line(width));
            }
        }
    }

    (lines, focus_idx)
}

// ── Private helpers ───────────────────────────────────────────────────────────

/// Format a duration in minutes as "Xm", "Xh", or "Xh Ym".
fn format_duration(mins: i64) -> String {
    if mins < 60 {
        format!("{mins}m")
    } else {
        let h = mins / 60;
        let m = mins % 60;
        if m == 0 {
            format!("{h}h")
        } else {
            format!("{h}h {m}m")
        }
    }
}

/// Build the "── now ──" marker line (amber, full width).
fn build_now_line(width: u16) -> Line<'static> {
    let now_text = " now ";
    let total = (width as usize).saturating_sub(LABEL_COLS);
    let half = total.saturating_sub(now_text.len()) / 2;
    let right = total.saturating_sub(half + now_text.len());
    Line::from(vec![
        Span::raw("      "),
        Span::styled("─".repeat(half), theme::style_amber()),
        Span::styled(now_text, theme::style_amber()),
        Span::styled("─".repeat(right), theme::style_amber()),
    ])
}

/// Return `(border_style, content_style)` for an event based on its status.
fn ev_styles(ev: &EvData) -> (Style, Style) {
    if ev.is_cancelled {
        let s = Style::default()
            .fg(Color::DarkGray)
            .add_modifier(Modifier::CROSSED_OUT);
        (s, s)
    } else if ev.is_tentative {
        let s = Style::default().fg(Color::DarkGray);
        (s, s)
    } else if ev.is_now_ev {
        (theme::style_amber(), theme::style_amber())
    } else if ev.is_past {
        let s = Style::default().fg(Color::DarkGray);
        (s, s)
    } else {
        (theme::style_muted(), theme::style_normal())
    }
}

/// Return the style for a time-label column entry.
fn label_style(ev: &EvData, first_upcoming: Option<usize>, ev_idx: usize) -> Style {
    if ev.is_past || ev.is_cancelled {
        Style::default().fg(Color::DarkGray)
    } else if first_upcoming == Some(ev_idx) {
        Style::default()
            .fg(Color::White)
            .add_modifier(Modifier::BOLD)
    } else {
        theme::style_muted()
    }
}

/// Build one rendered `Line` for a slot in the grid.
#[allow(clippy::too_many_arguments)]
fn build_slot_line(
    slot: i64,
    row: &[Option<(usize, CellKind)>],
    ev_data: &[EvData],
    work_start: &DateTime<Local>,
    first_upcoming: Option<usize>,
    col_width: usize,
    inner_width: usize,
    max_cols: usize,
    pad: &dyn Fn(&str, usize) -> String,
) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();

    // ── Time label (6 chars) ──
    // Shown on the row that contains a Top border; blank otherwise.
    let top_cell: Option<(usize, &EvData)> = row.iter().find_map(|cell| {
        if let Some((ei, CellKind::Top)) = cell {
            Some((*ei, &ev_data[*ei]))
        } else {
            None
        }
    });

    if let Some((ei, ev)) = top_cell {
        let time_str = ev.start_local.format("%H:%M ").to_string();
        let style = label_style(ev, first_upcoming, ei);
        spans.push(Span::styled(time_str, style));
    } else {
        spans.push(Span::raw("      "));
    }

    // ── Cell per column ──
    for cell in row.iter().take(max_cols) {
        match cell {
            None => {
                // Empty: fill with spaces to keep alignment.
                spans.push(Span::raw(" ".repeat(col_width)));
            }
            Some((ei, kind)) => {
                let ev = &ev_data[*ei];
                let (border_st, content_st) = ev_styles(ev);

                match kind {
                    CellKind::Top => {
                        spans.push(Span::styled("┏", border_st));
                        spans.push(Span::styled("━".repeat(inner_width), border_st));
                        spans.push(Span::styled("┓", border_st));
                    }
                    CellKind::Content { is_title_row } => {
                        spans.push(Span::styled("┃", border_st));
                        if *is_title_row {
                            let prefix = if ev.is_now_ev && !ev.is_cancelled {
                                "▶ "
                            } else {
                                " "
                            };
                            let raw = format!("{}{} ({}) ", prefix, ev.title, ev.duration_str);
                            let padded = pad(&raw, inner_width);
                            spans.push(Span::styled(padded, content_st));
                        } else {
                            spans.push(Span::styled(" ".repeat(inner_width), content_st));
                        }
                        spans.push(Span::styled("┃", border_st));
                    }
                    CellKind::Bottom => {
                        spans.push(Span::styled("┗", border_st));
                        spans.push(Span::styled("━".repeat(inner_width), border_st));
                        spans.push(Span::styled("┛", border_st));
                    }
                }
            }
        }
    }

    // Compute the slot's wall-clock time for the label (used above via top_cell).
    // We don't use `slot` directly in the span text (we use ev.start_local instead),
    // but keep this for potential future use.
    let _ = slot;
    let _ = work_start;

    Line::from(spans)
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn rect_contains(r: Rect, col: u16, row: u16) -> bool {
    col >= r.x && col < r.x + r.width && row >= r.y && row < r.y + r.height
}
