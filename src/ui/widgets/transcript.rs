//! Minimal text-only transcript widget (phase 1).
//!
//! Renders `TranscriptSnapshot` entries as colour-coded plain text lines.
//! Phase 2 will add markdown parsing; phase 3 adds tool folding.

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget, Wrap},
};

use crate::{
    transcript::snapshot::{TranscriptEntry, TranscriptSnapshot},
    ui::theme,
};

/// Text-only transcript widget.
///
/// Renders entries top-to-bottom, bottom-sticking by default.  Pass a
/// non-zero `scroll` to offset from the bottom (PageUp/Down).
pub struct TranscriptWidget<'a> {
    pub snapshot: &'a TranscriptSnapshot,
    /// Lines scrolled up from the bottom (0 = live / bottom-stick).
    pub scroll: u16,
}

impl<'a> TranscriptWidget<'a> {
    pub fn new(snapshot: &'a TranscriptSnapshot, scroll: u16) -> Self {
        Self { snapshot, scroll }
    }
}

impl Widget for TranscriptWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(ratatui::style::Style::default().fg(theme::BORDER_ACTIVE))
            .title(Span::styled(
                " Transcript ",
                ratatui::style::Style::default()
                    .fg(theme::FG)
                    .add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        block.render(area, buf);

        let lines = build_lines(self.snapshot);

        // Bottom-stick: clamp scroll so we don't scroll past the top.
        let total = lines.len() as u16;
        let visible = inner.height;

        let scroll_offset = if total <= visible {
            0
        } else {
            // scroll=0 → show bottom; scroll=N → scroll N lines up.
            let max_scroll = total.saturating_sub(visible);
            max_scroll.saturating_sub(self.scroll)
        };

        let p = Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .scroll((scroll_offset, 0));
        p.render(inner, buf);
    }
}

// ── Line builder ──────────────────────────────────────────────────────────────

fn build_lines(snapshot: &TranscriptSnapshot) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();

    for entry in snapshot.entries.iter() {
        match entry {
            TranscriptEntry::UserMessage(text) => {
                for (i, part) in text.lines().enumerate() {
                    let prefix = if i == 0 { "> " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(
                            prefix.to_string(),
                            ratatui::style::Style::default()
                                .fg(theme::SAGE)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(part.to_string(), theme::style_normal()),
                    ]));
                }
            }
            TranscriptEntry::AssistantText(text) => {
                for (i, part) in text.lines().enumerate() {
                    let prefix = if i == 0 { "« " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(
                            prefix.to_string(),
                            ratatui::style::Style::default()
                                .fg(theme::BORDER_ACTIVE)
                                .add_modifier(Modifier::BOLD),
                        ),
                        Span::styled(part.to_string(), theme::style_normal()),
                    ]));
                }
            }
            TranscriptEntry::Thinking(text) => {
                for (i, part) in text.lines().enumerate() {
                    let prefix = if i == 0 { "· " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(prefix.to_string(), theme::style_muted()),
                        Span::styled(part.to_string(), theme::style_muted()),
                    ]));
                }
            }
            TranscriptEntry::ToolUse { name, input } => {
                let input_preview = {
                    let s = serde_json::to_string(input).unwrap_or_default();
                    if s.len() > 60 {
                        format!("{}…", &s[..60])
                    } else {
                        s
                    }
                };
                lines.push(Line::from(vec![
                    Span::styled(
                        format!("⚙ {name} "),
                        ratatui::style::Style::default()
                            .fg(theme::AMBER)
                            .add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(input_preview, theme::style_muted()),
                ]));
            }
            TranscriptEntry::ToolResult { content, .. } => {
                let preview = if content.len() > 60 {
                    format!("{}…", &content[..60])
                } else {
                    content.clone()
                };
                lines.push(Line::from(vec![
                    Span::styled("↳ ".to_string(), theme::style_muted()),
                    Span::styled(preview, theme::style_muted()),
                ]));
            }
            TranscriptEntry::TurnEnd => {
                // Draw a subtle separator line.
                lines.push(Line::from(Span::styled(
                    "─".repeat(40),
                    ratatui::style::Style::default().fg(theme::BORDER_INACTIVE),
                )));
            }
        }
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            " No transcript yet…",
            theme::style_muted(),
        )));
    }

    lines
}
