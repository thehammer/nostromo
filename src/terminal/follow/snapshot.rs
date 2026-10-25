//! Plain-text snapshot of a `vt100` screen.

/// The visible rows of `screen` as plain text.
///
/// Trailing spaces are trimmed from every row, trailing blank rows are
/// dropped and rows are joined with `\n`. Leading and interior blank rows are
/// kept so the program's layout survives. A blank screen yields `""`. Only
/// the visible grid is read (never scrollback), and no styling is included.
pub fn screen_snapshot(screen: &vt100::Screen) -> String {
    let (_, cols) = screen.size();
    let mut rows: Vec<String> = screen
        .rows(0, cols)
        .map(|row| row.trim_end().to_owned())
        .collect();
    while rows.last().is_some_and(|row| row.is_empty()) {
        rows.pop();
    }
    rows.join("\n")
}
