//! Ctrl-D debug overlay — shows daemon status, PTY state, Mother job count,
//! IPC socket path, and the last 20 lines of the most-recent nostromo log file.

use ratatui::{
    layout::{Constraint, Direction, Layout, Rect},
    style::{Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, Clear, Paragraph, Wrap},
    Frame,
};

use crate::{app::AppState, ui::theme, views::BoxedView};

/// Render the debug overlay as a centered popup on top of the current frame.
pub fn render(f: &mut Frame, area: Rect, state: &AppState, views: &[BoxedView], active: usize) {
    // Centered popup: 80 cols wide, at most 30 rows tall (with 4-row margin).
    let popup = centered_popup(80, area.height.saturating_sub(4).min(30), area);

    f.render_widget(Clear, popup);

    let block = Block::default()
        .title(Span::styled(
            " debug (any key to dismiss) ",
            Style::default().fg(theme::FG_MUTED),
        ))
        .borders(Borders::ALL)
        .border_style(Style::default().fg(theme::BORDER_ACTIVE));

    let inner = block.inner(popup);
    f.render_widget(block, popup);

    if inner.height < 4 {
        return;
    }

    // Vertically divide into 5 sections:
    //   [0] Daemon info   — 2 rows
    //   [1] PTYs          — min(views.len()+2, 6) rows
    //   [2] Mother        — 2 rows
    //   [3] Mouse log     — min(12+1, 14) rows
    //   [4] Log tail      — remainder
    let pty_rows = (views.len() as u16 + 2).min(8);
    let mouse_rows = (state.mouse_event_log.len() as u16 + 1).min(14);
    let sections = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(2),
            Constraint::Length(pty_rows),
            Constraint::Length(2),
            Constraint::Length(mouse_rows),
            Constraint::Min(0),
        ])
        .split(inner);

    // ── Daemon ──────────────────────────────────────────────────────────────
    let daemon_lines = vec![
        Line::from(Span::styled(
            " Daemon",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(vec![
            Span::styled("  connected=", theme::style_muted()),
            Span::styled(
                state.daemon_connected.to_string(),
                if state.daemon_connected {
                    Style::default().fg(theme::SAGE)
                } else {
                    Style::default().fg(theme::AMBER)
                },
            ),
            Span::styled("  socket=", theme::style_muted()),
            Span::styled(
                state.daemon_socket_path.display().to_string(),
                Style::default().fg(theme::FG),
            ),
        ]),
    ];
    f.render_widget(Paragraph::new(daemon_lines), sections[0]);

    // ── PTYs ────────────────────────────────────────────────────────────────
    let mut pty_lines = vec![Line::from(Span::styled(
        " PTYs",
        Style::default().add_modifier(Modifier::BOLD),
    ))];
    for (idx, view) in views.iter().enumerate() {
        let capturing = view.pty_capturing_input();
        pty_lines.push(Line::from(vec![
            Span::styled(format!("  [{}] ", idx), theme::style_muted()),
            Span::styled(view.title().to_string(), Style::default().fg(theme::FG)),
            Span::styled("  pty_capturing=", theme::style_muted()),
            Span::styled(
                capturing.to_string(),
                if capturing {
                    Style::default().fg(theme::SAGE)
                } else {
                    Style::default().fg(theme::FG_MUTED)
                },
            ),
        ]));
    }
    // TODO: query daemon for full PTY list
    f.render_widget(Paragraph::new(pty_lines), sections[1]);

    // ── Mother ──────────────────────────────────────────────────────────────
    let mother_lines = vec![
        Line::from(Span::styled(
            " Mother",
            Style::default().add_modifier(Modifier::BOLD),
        )),
        Line::from(vec![
            Span::styled("  jobs=", theme::style_muted()),
            Span::styled(
                state.mother_jobs.len().to_string(),
                Style::default().fg(theme::FG),
            ),
            Span::styled("  active_view=", theme::style_muted()),
            Span::styled(active.to_string(), Style::default().fg(theme::FG)),
        ]),
    ];
    f.render_widget(Paragraph::new(mother_lines), sections[2]);

    // ── Mouse event log ─────────────────────────────────────────────────────
    if sections[3].height > 1 {
        let mut mouse_lines = vec![Line::from(Span::styled(
            " Mouse events (recent)",
            Style::default().add_modifier(Modifier::BOLD),
        ))];
        for entry in &state.mouse_event_log {
            mouse_lines.push(Line::from(Span::styled(
                format!("  {entry}"),
                theme::style_muted(),
            )));
        }
        f.render_widget(Paragraph::new(mouse_lines), sections[3]);
    }

    // ── Log tail ────────────────────────────────────────────────────────────
    if sections[4].height > 1 {
        let log_text = tail_log(20);
        let log_lines: Vec<Line> = {
            let header = Line::from(Span::styled(
                " Log (last 20 lines)",
                Style::default().add_modifier(Modifier::BOLD),
            ));
            let mut ls = vec![header];
            for l in log_text.lines() {
                ls.push(Line::from(Span::styled(
                    format!("  {l}"),
                    theme::style_muted(),
                )));
            }
            ls
        };
        f.render_widget(
            Paragraph::new(log_lines).wrap(Wrap { trim: false }),
            sections[4],
        );
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Return a centered `Rect` of the given fixed width and height inside `area`.
fn centered_popup(width: u16, height: u16, area: Rect) -> Rect {
    let w = width.min(area.width);
    let h = height.min(area.height);
    let x = area.x + area.width.saturating_sub(w) / 2;
    let y = area.y + area.height.saturating_sub(h) / 2;
    Rect {
        x,
        y,
        width: w,
        height: h,
    }
}

/// Return the last `n` lines of the most-recently-modified `nostromo.log.*`
/// file in the nostromo cache log directory.  Returns an empty string on any
/// error (debug overlay should degrade gracefully).
fn tail_log(n: usize) -> String {
    let log_dir = nostromo_log_dir();

    let latest = std::fs::read_dir(&log_dir).ok().and_then(|entries| {
        entries
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with("nostromo.log"))
            .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())
    });

    let path = match latest {
        Some(entry) => entry.path(),
        None => return String::new(),
    };

    let content = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(_) => return String::new(),
    };

    let lines: Vec<&str> = content.lines().collect();
    let start = lines.len().saturating_sub(n);
    lines[start..].join("\n")
}

/// Resolve the nostromo log directory (mirrors `log_directory()` in `main.rs`).
fn nostromo_log_dir() -> std::path::PathBuf {
    if let Some(proj) = directories::ProjectDirs::from("", "", "nostromo") {
        proj.cache_dir().join("log")
    } else {
        dirs_next::home_dir()
            .unwrap_or_else(|| std::path::PathBuf::from("."))
            .join(".cache")
            .join("nostromo")
            .join("log")
    }
}
