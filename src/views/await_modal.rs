//! Await-modal view.
//!
//! Displayed as a centered overlay when a Mother job transitions to `awaiting`.
//! The operator can approve (provide an answer), deny (cancel the job), or
//! dismiss without acting.

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::Paragraph,
    Frame,
};

use crate::{
    mother::MotherJob,
    ui::{
        theme,
        widgets::{modal, truncate::truncate},
    },
    views::EventOutcome,
};

/// Sub-state within the await modal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AwaitModalMode {
    /// Showing the question; waiting for a/d/v/Esc.
    Prompt,
    /// Operator typed `a`; now entering the answer text.
    Typing { input: String },
}

/// Await-modal state.
pub struct AwaitModal {
    pub job: MotherJob,
    pub mode: AwaitModalMode,
}

impl AwaitModal {
    pub fn new(job: MotherJob) -> Self {
        Self {
            job,
            mode: AwaitModalMode::Prompt,
        }
    }

    /// Handle a key event.  Returns the action the app should take.
    pub fn on_key(
        &mut self,
        k: &crossterm::event::KeyEvent,
    ) -> AwaitAction {
        use crossterm::event::KeyCode;

        match &mut self.mode {
            AwaitModalMode::Typing { input } => match k.code {
                KeyCode::Enter => {
                    let answer = std::mem::take(input);
                    return AwaitAction::Approve(answer);
                }
                KeyCode::Esc => {
                    self.mode = AwaitModalMode::Prompt;
                }
                KeyCode::Backspace => {
                    input.pop();
                }
                KeyCode::Char(c) => {
                    input.push(c);
                }
                _ => {}
            },

            AwaitModalMode::Prompt => match k.code {
                KeyCode::Char('a') | KeyCode::Char('A') => {
                    self.mode = AwaitModalMode::Typing {
                        input: String::new(),
                    };
                }
                KeyCode::Char('d') | KeyCode::Char('D') => {
                    return AwaitAction::Deny;
                }
                KeyCode::Char('v') | KeyCode::Char('V') => {
                    return AwaitAction::ViewDiff;
                }
                KeyCode::Esc => {
                    return AwaitAction::Dismiss;
                }
                _ => {}
            },
        }

        AwaitAction::Consumed
    }

    pub fn render(&self, f: &mut Frame, area: Rect) {
        let overlay = modal::centered(70, 60, area);
        let title = truncate(&format!("{} — {}", self.job.id, self.job.title), 60);
        let inner = modal::clear_and_block(f, overlay, &title);

        let question = self
            .job
            .question
            .as_deref()
            .unwrap_or("(no question recorded)");

        match &self.mode {
            AwaitModalMode::Prompt => {
                let chunks = Layout::default()
                    .direction(Direction::Vertical)
                    .constraints([
                        Constraint::Min(2),    // question body
                        Constraint::Length(1), // spacer
                        Constraint::Length(1), // hint line
                    ])
                    .split(inner);

                f.render_widget(
                    Paragraph::new(question)
                        .style(Style::default().fg(theme::FG))
                        .wrap(ratatui::widgets::Wrap { trim: false }),
                    chunks[0],
                );

                let hint = Line::from(vec![
                    Span::styled("[a] ", Style::default().fg(theme::SAGE)),
                    Span::styled("approve  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("[d] ", Style::default().fg(theme::RED_SWEATER)),
                    Span::styled("deny  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("[v] ", Style::default().fg(theme::AMBER)),
                    Span::styled("view diff  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("[esc] ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("dismiss", Style::default().fg(theme::FG_MUTED)),
                ]);
                f.render_widget(Paragraph::new(hint), chunks[2]);
            }

            AwaitModalMode::Typing { input } => {
                let chunks = Layout::default()
                    .direction(Direction::Vertical)
                    .constraints([
                        Constraint::Min(2),    // question body
                        Constraint::Length(1), // spacer
                        Constraint::Length(1), // input line
                        Constraint::Length(1), // hint
                    ])
                    .split(inner);

                f.render_widget(
                    Paragraph::new(question)
                        .style(Style::default().fg(theme::FG_MUTED))
                        .wrap(ratatui::widgets::Wrap { trim: false }),
                    chunks[0],
                );

                let input_line = Line::from(vec![
                    Span::styled("Answer: ", Style::default().fg(theme::SAGE)),
                    Span::styled(
                        format!("{input}█"),
                        Style::default()
                            .fg(theme::FG)
                            .add_modifier(Modifier::BOLD),
                    ),
                ]);
                f.render_widget(Paragraph::new(input_line), chunks[2]);

                let hint = Line::from(vec![
                    Span::styled("[Enter] ", Style::default().fg(theme::SAGE)),
                    Span::styled("submit  ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("[Esc] ", Style::default().fg(theme::FG_MUTED)),
                    Span::styled("back", Style::default().fg(theme::FG_MUTED)),
                ]);
                f.render_widget(Paragraph::new(hint), chunks[3]);
            }
        }
    }
}

/// Action returned by `AwaitModal::on_key`.
#[derive(Debug, Clone)]
pub enum AwaitAction {
    Consumed,
    /// Operator provided an answer.
    Approve(String),
    /// Operator denied (cancel the job).
    Deny,
    /// Switch to Perri and focus its diff pane on the worktree.
    ViewDiff,
    /// Close the modal without acting.
    Dismiss,
}

/// Outcome from `EventOutcome::Consumed` — unused here but kept for trait compat.
#[allow(dead_code)]
pub fn consumed() -> EventOutcome {
    EventOutcome::Consumed
}
