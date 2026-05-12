//! Fred view: mailbox (top-left) + calendar (top-right) + embedded PTY REPL.

use std::any::Any;

use crossterm::event::KeyCode;
use ratatui::{
    layout::{Alignment, Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, Paragraph},
    Frame,
};
use tokio::sync::watch;

use crate::{
    config::Config,
    data::{fred_calendar::CalendarSnapshot, fred_mailbox::MailboxSnapshot},
    event::AppEvent,
    pty::{PtyBackend, PtyWidget},
    ui::{
        theme::{self, Sweater},
        widgets::{relative_time::format_relative_now, truncate::truncate},
    },
    views::{EventOutcome, View, ViewCtx},
};

/// Tag used to identify Fred's PTY in the daemon registry.
const FRED_PTY_TAG: &str = "fred";

pub struct FredView {
    mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
    calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,
    #[allow(dead_code)]
    config: Config,
    ctx: ViewCtx,
    pty: Option<PtyBackend>,
    /// Whether the PTY is currently capturing keystrokes.
    pty_capturing: bool,
    /// Last known inner area of the REPL pane.
    repl_area: Rect,
}

impl FredView {
    pub fn new(
        mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
        calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,
        config: Config,
        ctx: ViewCtx,
    ) -> Self {
        // Attempt to reattach to an existing daemon PTY for this view.
        let pty = Self::try_reattach(&ctx);

        let pty_capturing = pty.is_some();

        Self {
            mailbox_rx,
            calendar_rx,
            config,
            ctx,
            pty,
            pty_capturing,
            repl_area: Rect::new(0, 0, 80, 10),
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
    pub fn calendar_snapshot_cloned(&self) -> Option<CalendarSnapshot> {
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

    fn render_calendar(&self, f: &mut Frame, area: Rect) {
        let snap = self.calendar_rx.borrow();
        let snap = snap.as_ref();

        let sweater = snap
            .map(|s| Sweater::from_str(&s.sweater))
            .unwrap_or_default();
        let stale = snap.map(|s| s.stale).unwrap_or(false);
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

        let lines: Vec<Line> = if let Some(s) = snap {
            let mut ls: Vec<Line> = s
                .events
                .iter()
                .map(|ev| {
                    let is_cancelled = ev.status == "cancelled" || ev.status == "declined";
                    let is_tentative = ev.status == "tentativelyAccepted";

                    let now_glyph = if ev.is_now { "▶ " } else { "  " };

                    let style = if is_cancelled {
                        Style::default()
                            .fg(ratatui::style::Color::DarkGray)
                            .add_modifier(Modifier::CROSSED_OUT)
                    } else if is_tentative {
                        Style::default().fg(ratatui::style::Color::DarkGray)
                    } else if ev.is_now {
                        theme::style_amber()
                    } else {
                        theme::style_normal()
                    };

                    let time_style = if is_cancelled {
                        Style::default().fg(ratatui::style::Color::DarkGray)
                    } else {
                        theme::style_muted()
                    };

                    let start_str = ev
                        .start
                        .map(|dt| {
                            let local: chrono::DateTime<chrono::Local> = dt.into();
                            local.format("%H:%M").to_string()
                        })
                        .unwrap_or_else(|| "?".into());

                    let title_width = (inner.width as usize).saturating_sub(10);
                    let title_str = truncate(&ev.title, title_width.max(4));

                    Line::from(vec![
                        Span::styled(now_glyph, style),
                        Span::styled(format!("{start_str} "), time_style),
                        Span::styled(title_str, style),
                    ])
                })
                .collect();

            if let Some(next) = &s.next {
                ls.push(Line::from(vec![]));
                let countdown = if next.in_minutes <= 0 {
                    format!("▶ {} — now", next.title)
                } else {
                    format!("▶ {} in {}m", next.title, next.in_minutes)
                };
                ls.push(Line::from(Span::styled(
                    truncate(&countdown, (inner.width as usize).saturating_sub(2).max(4)),
                    theme::style_for_sweater(sweater),
                )));
            }

            ls
        } else {
            vec![Line::from(Span::styled(
                " Loading calendar…",
                theme::style_muted(),
            ))]
        };

        let p = Paragraph::new(lines);
        f.render_widget(p, inner);
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
            f.render_widget(PtyWidget::new(guard), inner);
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

        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
            .split(content_area);

        let top_cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)])
            .split(rows[0]);

        self.render_mailbox(f, top_cols[0]);
        self.render_calendar(f, top_cols[1]);
        self.render_repl(f, rows[1]);

        // Resize PTY if the pane size changed.
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
                    }
                    Err(e) => {
                        tracing::warn!("failed to spawn PTY for fred: {e}");
                    }
                }
                return EventOutcome::Consumed;
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

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
