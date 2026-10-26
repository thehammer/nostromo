//! Plain-text snapshot of a `vt100` screen.

/// The visible rows of `screen` as plain text.
///
/// Trailing spaces are trimmed from every row, trailing blank rows are
/// dropped and rows are joined with `\n`. Leading and interior blank rows are
/// kept so the program's layout survives. A blank screen yields `""`. Only
/// the visible grid is read (never scrollback), and no styling is included.
///
/// **The text is raw: not redacted, not capped. Never send it to an agent**;
/// use [`deliver_snapshot`](super::deliver_snapshot).
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

/// The visible rows of `screen` as logical lines: a row the program wrapped
/// onto the next one (`Screen::row_wrapped`) is joined to it, so a secret that
/// wrapped is whole when it is redacted. Trailing spaces are trimmed from each
/// line and trailing blank lines are dropped; a blank screen has no lines.
///
/// Raw, like [`screen_snapshot`]: crate-private, and only for
/// [`deliver_snapshot`](super::deliver_snapshot).
pub(crate) fn snapshot_lines(screen: &vt100::Screen) -> Vec<String> {
    let (rows, cols) = screen.size();
    let mut lines = Vec::new();
    let mut line = String::new();
    for (index, row) in screen.rows(0, cols).enumerate() {
        line.push_str(&row);
        let wraps =
            u16::try_from(index).is_ok_and(|i| screen.row_wrapped(i)) && index + 1 < rows.into();
        if !wraps {
            lines.push(std::mem::take(&mut line).trim_end().to_owned());
        }
    }
    while lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    lines
}
