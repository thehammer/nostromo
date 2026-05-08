//! Modal overlay helpers.
//!
//! Provides a utility function to compute a centered `Rect` and a helper that
//! renders the modal frame (clearing the background and drawing a bordered
//! block with a title).

use ratatui::{
    layout::Rect,
    style::Style,
    widgets::{Block, Borders, Clear},
    Frame,
};

use crate::ui::theme;

/// Compute a centered sub-rect that occupies `width_pct`% of the area's width
/// and `height_pct`% of its height.
pub fn centered(width_pct: u16, height_pct: u16, area: Rect) -> Rect {
    let w = (area.width * width_pct / 100).max(4);
    let h = (area.height * height_pct / 100).max(3);
    let x = area.x + area.width.saturating_sub(w) / 2;
    let y = area.y + area.height.saturating_sub(h) / 2;
    Rect::new(x, y, w, h)
}

/// Clear `area` and render a bordered block with `title`.
///
/// Returns the inner `Rect` (inside the border) for the caller to draw content
/// into.
pub fn clear_and_block(f: &mut Frame, area: Rect, title: &str) -> Rect {
    f.render_widget(Clear, area);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(theme::BORDER_ACTIVE))
        .title(format!(" {title} "))
        .title_style(Style::default().fg(theme::FG));
    let inner = block.inner(area);
    f.render_widget(block, area);
    inner
}
