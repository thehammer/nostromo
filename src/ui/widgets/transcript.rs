//! Transcript widget (phase 2).
//!
//! Renders `TranscriptSnapshot` entries as styled ratatui lines.
//!
//! - `AssistantText` entries are rendered through [`markdown::render_markdown`]
//!   and cached by entry index in the caller (`PerriView`).
//! - All other entry types remain plain-text with colour-coded prefixes.
//!
//! The caller is responsible for cache management: pass `cache` and `width`
//! at construction time.  The widget fills cache misses by calling the
//! markdown renderer, so `render` effectively mutates the cache.  (The
//! widget holds a `&mut` reference which is consumed when `render` is called.)

use std::collections::HashMap;

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget},
};

use crate::{
    transcript::snapshot::{TranscriptEntry, TranscriptSnapshot},
    ui::{
        theme,
        widgets::{markdown::render_markdown, syntect_cache::SyntectCache},
    },
};

/// Transcript widget with markdown rendering for assistant messages.
///
/// Holds a `&mut` borrow on `cache` so it can populate missed entries during
/// `render`.  The borrow is consumed when the widget is rendered.
pub struct TranscriptWidget<'a> {
    pub snapshot: &'a TranscriptSnapshot,
    /// Lines scrolled up from the bottom (0 = live / bottom-stick).
    pub scroll: u16,
    pub syntect: &'a SyntectCache,
    /// Per-entry line cache keyed by entry index.  The widget fills misses.
    pub cache: &'a mut HashMap<usize, Vec<Line<'static>>>,
    /// Available inner width (border already subtracted).
    pub width: u16,
}

impl<'a> TranscriptWidget<'a> {
    pub fn new(
        snapshot: &'a TranscriptSnapshot,
        scroll: u16,
        syntect: &'a SyntectCache,
        cache: &'a mut HashMap<usize, Vec<Line<'static>>>,
        width: u16,
    ) -> Self {
        Self { snapshot, scroll, syntect, cache, width }
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

        let lines = build_lines(self.snapshot, self.syntect, self.cache, self.width);

        // Bottom-stick: clamp scroll so we don't scroll past the top.
        let total = lines.len() as u16;
        let visible = inner.height;

        let scroll_offset = if total <= visible {
            0
        } else {
            let max_scroll = total.saturating_sub(visible);
            max_scroll.saturating_sub(self.scroll)
        };

        let p = Paragraph::new(lines).scroll((scroll_offset, 0));
        p.render(inner, buf);
    }
}

// ── Line builder ──────────────────────────────────────────────────────────────

fn build_lines(
    snapshot: &TranscriptSnapshot,
    syntect: &SyntectCache,
    cache: &mut HashMap<usize, Vec<Line<'static>>>,
    width: u16,
) -> Vec<Line<'static>> {
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut new_renders = 0usize;

    for (idx, entry) in snapshot.entries.iter().enumerate() {
        match entry {
            TranscriptEntry::UserMessage(text) => {
                for (i, part) in text.lines().enumerate() {
                    let prefix = if i == 0 { "▸ " } else { "  " };
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
            TranscriptEntry::AssistantText(md) => {
                // Cache lookup — render on miss.
                let cached = cache.entry(idx).or_insert_with(|| {
                    new_renders += 1;
                    render_markdown(md, syntect, width)
                });
                lines.extend_from_slice(cached);
            }
            TranscriptEntry::Thinking(text) => {
                for (i, part) in text.lines().enumerate() {
                    let prefix = if i == 0 { "· " } else { "  " };
                    lines.push(Line::from(vec![
                        Span::styled(
                            prefix.to_string(),
                            ratatui::style::Style::default()
                                .fg(theme::FG_MUTED)
                                .add_modifier(Modifier::ITALIC),
                        ),
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
                let preview = if content.len() > 120 {
                    format!("{}…", &content[..120])
                } else {
                    content.clone()
                };
                lines.push(Line::from(vec![
                    Span::styled("↳ ".to_string(), theme::style_muted()),
                    Span::styled(preview, theme::style_muted()),
                ]));
            }
            TranscriptEntry::TurnEnd => {
                lines.push(Line::from(Span::styled(
                    "─".repeat(40),
                    ratatui::style::Style::default().fg(theme::BORDER_INACTIVE),
                )));
            }
        }
    }

    if new_renders > 0 {
        tracing::trace!("transcript: rendered {} new markdown entries", new_renders);
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            " No transcript yet…",
            theme::style_muted(),
        )));
    }

    lines
}
