//! Transcript widget (phase 3).
//!
//! Renders `TranscriptSnapshot` entries as styled ratatui lines with:
//!
//! - A left-gutter cursor mark (`▎`) on the focused entry.
//! - Foldable `ToolUse` / `ToolResult` entries (collapsed by default).
//! - Optional `Thinking` block visibility.
//!
//! The caller owns the interaction state and passes it in; the widget is a
//! pure function of that state plus the snapshot.

use std::collections::HashMap;

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::Modifier,
    text::{Line, Span},
    widgets::{Block, Borders, Paragraph, Widget},
};

use crate::{
    transcript::snapshot::TranscriptSnapshot,
    ui::{
        theme,
        widgets::{
            syntect_cache::SyntectCache,
            transcript_layout::{self, TranscriptInteraction},
        },
    },
};

/// Transcript widget with markdown rendering, folding, and cursor gutter.
///
/// The cache key is `(entry_index, is_expanded)` so that toggling expansion
/// invalidates only the affected entry's cached lines.
pub struct TranscriptWidget<'a> {
    pub snapshot: &'a TranscriptSnapshot,
    /// Top line of the viewport (0 = top of content).
    pub scroll_offset: u16,
    pub syntect: &'a SyntectCache,
    /// Render cache keyed by `(entry_index, is_expanded)`.
    pub cache: &'a mut HashMap<(usize, bool), Vec<Line<'static>>>,
    /// Available inner width (border already subtracted).
    pub width: u16,
    /// Current interaction state (cursor, expanded set, thinking visibility).
    pub interaction: &'a TranscriptInteraction,
}

impl<'a> TranscriptWidget<'a> {
    pub fn new(
        snapshot: &'a TranscriptSnapshot,
        scroll_offset: u16,
        syntect: &'a SyntectCache,
        cache: &'a mut HashMap<(usize, bool), Vec<Line<'static>>>,
        width: u16,
        interaction: &'a TranscriptInteraction,
    ) -> Self {
        Self {
            snapshot,
            scroll_offset,
            syntect,
            cache,
            width,
            interaction,
        }
    }
}

impl Widget for TranscriptWidget<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let thinking_hint = if self.interaction.show_thinking {
            " [T]"
        } else {
            " [T off]"
        };
        let block = Block::default()
            .borders(Borders::ALL)
            .border_style(ratatui::style::Style::default().fg(theme::BORDER_ACTIVE))
            .title(Span::styled(
                format!(" Transcript{thinking_hint} "),
                ratatui::style::Style::default()
                    .fg(theme::FG)
                    .add_modifier(Modifier::BOLD),
            ));

        let inner = block.inner(area);
        block.render(area, buf);

        let plan = transcript_layout::compute(
            self.snapshot,
            self.interaction,
            self.width,
            self.syntect,
            self.cache,
        );

        let p = Paragraph::new(plan.lines).scroll((self.scroll_offset, 0));
        p.render(inner, buf);
    }
}
