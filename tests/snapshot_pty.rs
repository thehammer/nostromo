//! Smoke test for `PtyWidget`: feed a deterministic byte stream into a
//! `vt100::Parser`, render via `PtyWidget` to a Ratatui `TestBackend`, and
//! snapshot the result with `insta`.

use ratatui::{backend::TestBackend, layout::Rect, Terminal};

use nostromo::pty::PtyWidget;

/// Feed `bytes` into a fresh vt100 parser sized `(cols, rows)` and return
/// a text snapshot of the rendered buffer.
fn render_pty_bytes(bytes: &[u8], cols: u16, rows: u16) -> String {
    let mut parser = vt100::Parser::new(rows, cols, 0);
    parser.process(bytes);

    let backend = TestBackend::new(cols, rows);
    let mut terminal = Terminal::new(backend).unwrap();

    // Wrap in an Arc<Mutex<>> as PtyWidget expects.
    let parser_arc = std::sync::Arc::new(std::sync::Mutex::new(parser));

    terminal
        .draw(|f| {
            let guard = parser_arc.lock().unwrap();
            f.render_widget(PtyWidget::new(guard), Rect::new(0, 0, cols, rows));
        })
        .unwrap();

    let buffer = terminal.backend().buffer().clone();
    let mut lines: Vec<String> = Vec::new();
    for y in 0..buffer.area.height {
        let row: String = (0..buffer.area.width)
            .map(|x| {
                buffer
                    .cell((x, y))
                    .map(|c| c.symbol().chars().next().unwrap_or(' '))
                    .unwrap_or(' ')
            })
            .collect();
        lines.push(row.trim_end().to_string());
    }
    lines.join("\n")
}

#[test]
fn pty_widget_renders_plain_text() {
    // Feed a simple "Hello, world!" followed by a newline.
    let snapshot = render_pty_bytes(b"Hello, world!\r\n", 40, 5);
    insta::assert_snapshot!("pty_plain_text", snapshot);
}

#[test]
fn pty_widget_renders_ansi_colours() {
    // ESC[32m = green; ESC[m = reset.
    let bytes = b"\x1b[32mGREEN\x1b[m and \x1b[31mRED\x1b[m\r\n";
    let snapshot = render_pty_bytes(bytes, 40, 5);
    insta::assert_snapshot!("pty_ansi_colours", snapshot);
}

#[test]
fn pty_widget_renders_cursor_position() {
    // Move cursor to col 5 row 1 (1-indexed in ANSI: \x1b[2;6H).
    let bytes = b"ABCDE\x1b[2;6HX\r\n";
    let snapshot = render_pty_bytes(bytes, 20, 5);
    insta::assert_snapshot!("pty_cursor_position", snapshot);
}

#[test]
fn pty_widget_empty_screen() {
    let snapshot = render_pty_bytes(b"", 20, 5);
    insta::assert_snapshot!("pty_empty_screen", snapshot);
}
