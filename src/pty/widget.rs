//! `PtyWidget` — renders a `vt100::Screen` into a Ratatui `Buffer`.

use std::sync::MutexGuard;

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    widgets::Widget,
};

/// Renders the contents of a locked `vt100::Parser` into a Ratatui buffer.
///
/// Holds the `MutexGuard` for the duration of `Widget::render`; the lock is
/// released when the widget is consumed.
pub struct PtyWidget<'a> {
    guard: MutexGuard<'a, vt100::Parser>,
}

impl<'a> PtyWidget<'a> {
    pub fn new(guard: MutexGuard<'a, vt100::Parser>) -> Self {
        Self { guard }
    }
}

impl<'a> Widget for PtyWidget<'a> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let screen = self.guard.screen();
        let (cursor_row, cursor_col) = screen.cursor_position();
        let show_cursor = !screen.hide_cursor();

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
