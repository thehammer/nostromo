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
    data::{
        fred_calendar::CalendarSnapshot,
        fred_mailbox::MailboxSnapshot,
    },
    event::AppEvent,
    pty::{PtyHost, PtyWidget},
    ui::{
        theme::{self, Sweater},
        widgets::{relative_time::format_relative_now, truncate::truncate},
    },
    views::{EventOutcome, View, ViewCtx},
};

pub struct FredView {
    mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
    calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,
    #[allow(dead_code)]
    config: Config,
    ctx: ViewCtx,
    pty: Option<PtyHost>,
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
        Self {
            mailbox_rx,
            calendar_rx,
            config,
            ctx,
            pty: None,
            repl_area: Rect::new(0, 0, 80, 10),
        }
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

        // Auth-prompt rendering: when Graph sign-in is required, show device flow UI.
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
                        Style::default().fg(theme::FG).add_modifier(Modifier::UNDERLINED),
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
                    let now_glyph = if ev.is_now { "▶ " } else { "  " };
                    let style = if ev.is_now {
                        theme::style_amber()
                    } else {
                        theme::style_normal()
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
                        Span::styled(format!("{start_str} "), theme::style_muted()),
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
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(if self.pty.is_some() {
                theme::BORDER_ACTIVE
            } else {
                theme::BORDER_INACTIVE
            }))
            .title(Span::styled(
                " REPL ",
                Style::default().fg(theme::FG_MUTED),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        // Store the inner area for PTY spawn / resize.
        self.repl_area = inner;

        if let Some(pty) = &self.pty {
            let guard = pty.parser.lock().unwrap();
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
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Percentage(70), Constraint::Percentage(30)])
            .split(area);

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
        // When PTY is active, forward all keys to it.
        if let Some(pty) = &mut self.pty {
            if let AppEvent::Key(k) = ev {
                pty.send_key(k);
                return EventOutcome::Consumed;
            }
        }

        if let AppEvent::Key(k) = ev {
            if k.code == KeyCode::Enter && self.pty.is_none() {
                let (cols, rows) = (self.repl_area.width.max(20), self.repl_area.height.max(5));
                match PtyHost::spawn(
                    "claude",
                    &["--agent", "fred"],
                    (cols, rows),
                    self.ctx.event_tx.clone(),
                    "fred",
                ) {
                    Ok(host) => {
                        self.pty = Some(host);
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

    fn pty_focus(&self) -> bool {
        self.pty.is_some()
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
