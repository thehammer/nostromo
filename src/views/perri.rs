//! Perri view: PR queue (top-left) + current PR diff (top-right) + REPL.

use std::any::Any;

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
    ui::{
        theme,
        widgets::truncate::truncate,
    },
    views::{EventOutcome, View},
};

pub struct PerriView {
    queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
    pr_rx: watch::Receiver<Option<PrSnapshot>>,
    selected_pr: usize,
    #[allow(dead_code)]
    config: Config,
}

impl PerriView {
    pub fn new(
        queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
        pr_rx: watch::Receiver<Option<PrSnapshot>>,
        config: Config,
    ) -> Self {
        Self { queue_rx, pr_rx, selected_pr: 0, config }
    }

    fn render_queue(&self, f: &mut Frame, area: Rect) {
        let snap = self.queue_rx.borrow();
        let snap = snap.as_ref();

        let count = snap.map(|s| s.items.len()).unwrap_or(0);
        let stale = snap.map(|s| s.stale).unwrap_or(false);

        let queue_color = match count {
            0..=4 => theme::SAGE,
            5..=9 => theme::AMBER,
            _ => theme::RED_SWEATER,
        };

        let stale_suffix = if stale { " (stale)" } else { "" };
        let title = format!(" PR Queue [{count}]{stale_suffix} ");

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(queue_color))
            .title(Span::styled(
                title,
                Style::default().fg(queue_color).add_modifier(Modifier::BOLD),
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
                        let req_glyph = if pr.requested { "★ " } else { "  " };
                        let req_style = if pr.requested {
                            theme::style_amber()
                        } else {
                            theme::style_normal()
                        };

                        let selected_glyph = if i == self.selected_pr { "▶ " } else { "  " };

                        let number_str = format!("#{}", pr.number);
                        let repo_short = pr.repo.split('/').last().unwrap_or(&pr.repo);
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
                            Span::styled(
                                format!(" {}", repo_short),
                                theme::style_muted(),
                            ),
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

        let list = List::new(items);
        f.render_widget(list, inner);
    }

    fn render_diff(&self, f: &mut Frame, area: Rect) {
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

        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(theme::BORDER_INACTIVE))
            .title(Span::styled(
                truncate(&pr_title, area.width as usize - 4),
                Style::default().fg(theme::FG).add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        let lines: Vec<Line> = if let Some(s) = snap {
            if s.diff.is_empty() {
                vec![Line::from(Span::styled(
                    " No diff available",
                    theme::style_muted(),
                ))]
            } else {
                // Phase 1: render raw diff with basic +/- colouring.
                // Phase 2 adds syntect highlighting.
                s.diff
                    .lines()
                    .take(inner.height as usize)
                    .map(|l| {
                        let style = if l.starts_with('+') {
                            Style::default().fg(theme::SAGE)
                        } else if l.starts_with('-') {
                            Style::default().fg(theme::RED_SWEATER)
                        } else if l.starts_with("@@") {
                            Style::default().fg(theme::AMBER)
                        } else {
                            theme::style_muted()
                        };
                        Line::from(Span::styled(truncate(l, inner.width as usize), style))
                    })
                    .collect()
            }
        } else {
            vec![Line::from(Span::styled(
                " Loading diff…",
                theme::style_muted(),
            ))]
        };

        let p = Paragraph::new(lines);
        f.render_widget(p, inner);
    }

    fn render_repl_placeholder(&self, f: &mut Frame, area: Rect) {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(Style::default().fg(theme::BORDER_INACTIVE))
            .title(Span::styled(
                " REPL ",
                Style::default().fg(theme::FG_MUTED),
            ));

        let inner = block.inner(area);
        f.render_widget(block, area);

        let lines = vec![
            Line::from(vec![]),
            Line::from(Span::styled(
                "Press Enter to launch perri REPL (claude --agent perri)",
                theme::style_muted(),
            )),
            Line::from(Span::styled(
                "(embedded PTY: phase 2)",
                Style::default()
                    .fg(theme::FG_MUTED)
                    .add_modifier(Modifier::DIM),
            )),
        ];

        let p = Paragraph::new(lines);
        f.render_widget(p, inner);
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
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Percentage(70), Constraint::Percentage(30)])
            .split(area);

        let top_cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
            .split(rows[0]);

        self.render_queue(f, top_cols[0]);
        self.render_diff(f, top_cols[1]);
        self.render_repl_placeholder(f, rows[1]);
    }

    fn on_event(&mut self, ev: &AppEvent) -> EventOutcome {
        use crossterm::event::KeyCode;
        use crate::event::AppEvent;

        if let AppEvent::Key(k) = ev {
            match k.code {
                KeyCode::Down | KeyCode::Char('j') => {
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
                KeyCode::Up | KeyCode::Char('k') => {
                    let len = self
                        .queue_rx
                        .borrow()
                        .as_ref()
                        .map(|s| s.items.len())
                        .unwrap_or(0);
                    if len > 0 {
                        self.selected_pr =
                            self.selected_pr.checked_sub(1).unwrap_or(len - 1);
                    }
                    return EventOutcome::Consumed;
                }
                _ => {}
            }
        }
        EventOutcome::Ignored
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn Any {
        self
    }
}
