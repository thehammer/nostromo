//! `PtyWidget` — renders a `vt100::Screen` into a Ratatui `Buffer`.

use std::sync::MutexGuard;

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    widgets::Widget,
};

use crate::ui::theme;

/// Renders the contents of a locked `vt100::Parser` into a Ratatui buffer.
///
/// When `scroll_offset > 0` the widget shifts the view into the scrollback
/// buffer, hides the cursor, and shows a dim `[scroll: N]` indicator in the
/// top-right corner of the pane.
///
/// Holds the `MutexGuard` for the duration of `Widget::render`; the lock is
/// released when the widget is consumed.
pub struct PtyWidget<'a> {
    guard: MutexGuard<'a, vt100::Parser>,
    scroll_offset: u16,
}

impl<'a> PtyWidget<'a> {
    pub fn new(guard: MutexGuard<'a, vt100::Parser>, scroll_offset: u16) -> Self {
        Self {
            guard,
            scroll_offset,
        }
    }
}

impl<'a> Widget for PtyWidget<'a> {
    fn render(mut self, area: Rect, buf: &mut Buffer) {
        // Shift the parser's view into the scrollback buffer for this render.
        // We reset to 0 afterwards so the live view is restored between frames.
        self.guard.set_scrollback(self.scroll_offset as usize);

        let (cursor_row, cursor_col, show_cursor) = {
            let screen = self.guard.screen();
            let (cursor_row, cursor_col) = screen.cursor_position();
            // Hide cursor when scrolled away from live view.
            let show_cursor = !screen.hide_cursor() && self.scroll_offset == 0;
            (cursor_row, cursor_col, show_cursor)
        };

        {
            let screen = self.guard.screen();
            for row in 0..area.height {
                for col in 0..area.width {
                    let Some(cell) = screen.cell(row, col) else {
                        continue;
                    };

                    let contents = cell.contents();
                    let display = if contents.is_empty() { " " } else { &contents };

                    let mut style = build_style(cell);

                    // Render cursor as reverse-video overlay.
                    if show_cursor && row == cursor_row && col == cursor_col {
                        style = style.add_modifier(Modifier::REVERSED);
                    }

                    let x = area.x + col;
                    let y = area.y + row;
                    if x < buf.area.right() && y < buf.area.bottom() {
                        if let Some(c) = buf.cell_mut((x, y)) {
                            c.set_symbol(display);
                            c.set_style(style);
                        }
                    }
                }
            }
        }
        // screen borrow released — safe to mutate guard again.
        self.guard.set_scrollback(0);

        // Dim scroll indicator in top-right corner when scrolled.
        if self.scroll_offset > 0 {
            let label = format!("[scroll: {}]", self.scroll_offset);
            let indicator_style = theme::style_muted().add_modifier(Modifier::DIM);
            let label_len = label.len() as u16;
            let x_start = area.x + area.width.saturating_sub(label_len);
            let y = area.y;
            for (i, ch) in label.chars().enumerate() {
                let x = x_start + i as u16;
                if x < buf.area.right() && y < buf.area.bottom() {
                    if let Some(c) = buf.cell_mut((x, y)) {
                        c.set_symbol(&ch.to_string());
                        c.set_style(indicator_style);
                    }
                }
            }
        }
    }
}

fn vt100_color_to_ratatui(c: vt100::Color) -> Option<Color> {
    match c {
        vt100::Color::Default => None,
        vt100::Color::Idx(i) => Some(Color::Indexed(i)),
        vt100::Color::Rgb(r, g, b) => Some(Color::Rgb(r, g, b)),
    }
}

fn build_style(cell: &vt100::Cell) -> Style {
    let mut style = Style::default();

    if let Some(fg) = vt100_color_to_ratatui(cell.fgcolor()) {
        style = style.fg(fg);
    }
    if let Some(bg) = vt100_color_to_ratatui(cell.bgcolor()) {
        style = style.bg(bg);
    }

    if cell.bold() {
        style = style.add_modifier(Modifier::BOLD);
    }
    if cell.italic() {
        style = style.add_modifier(Modifier::ITALIC);
    }
    if cell.underline() {
        style = style.add_modifier(Modifier::UNDERLINED);
    }
    if cell.inverse() {
        style = style.add_modifier(Modifier::REVERSED);
    }

    style
}
