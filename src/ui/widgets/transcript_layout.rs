//! Layout computation for the interactive transcript pane (phase 3).
//!
//! [`compute`] converts a `TranscriptSnapshot` + interaction state into a
//! [`LayoutPlan`] that maps each entry index to a row range within the rendered
//! output.  The widget uses this to:
//!
//! - Draw a left-gutter cursor mark (`▎`) next to the focused entry.
//! - Auto-scroll so the focused entry is always within the visible window.
//!
//! The helper is intentionally free of Ratatui rendering — it works on plain
//! data so it can be unit-tested without a frame or buffer.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use ratatui::style::Modifier;
use ratatui::text::{Line, Span};

use crate::{
    transcript::snapshot::{TranscriptEntry, TranscriptSnapshot},
    ui::{
        theme,
        widgets::{markdown::render_markdown, syntect_cache::SyntectCache},
    },
};

// ── Interaction state ─────────────────────────────────────────────────────────

/// Interaction state for the transcript pane, threaded through layout and
/// rendering so the widget can be a pure function of state.
#[derive(Debug, Clone)]
pub struct TranscriptInteraction {
    /// Index into `snapshot.entries` of the currently focused entry.
    pub cursor: usize,
    /// Indices of `ToolUse`, `ToolResult`, and long `Thinking` entries that
    /// are currently expanded.  Collapsed entries render as a single summary
    /// line; expanded entries show their full content.
    pub expanded: HashSet<usize>,
    /// Whether `Thinking` blocks are included in the navigation list and
    /// rendered at all.
    pub show_thinking: bool,
    /// Whether the cursor is "following" the tail (auto-advances on append).
    pub following: bool,
}

impl Default for TranscriptInteraction {
    fn default() -> Self {
        Self {
            cursor: 0,
            expanded: HashSet::new(),
            show_thinking: false,
            following: true,
        }
    }
}

// ── Layout plan ───────────────────────────────────────────────────────────────

/// The output of [`compute`].
#[derive(Debug)]
pub struct LayoutPlan {
    /// All rendered lines, in order, ready for display.
    pub lines: Vec<Line<'static>>,
    /// Maps entry index → the range of rows (within `lines`) that entry
    /// occupies.  Only navigable entries are present.
    pub entry_rows: HashMap<usize, Range<u16>>,
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Compute the full layout for the transcript pane.
///
/// - `snapshot` — the current transcript state.
/// - `state` — the current interaction state (cursor, expanded set, …).
/// - `width` — the inner pane width in columns (border excluded).
/// - `syntect` — used for code-block highlighting inside expanded tool entries.
/// - `cache` — render cache keyed by `(entry_index, is_expanded)`; populated
///   on miss.
pub fn compute(
    snapshot: &TranscriptSnapshot,
    state: &TranscriptInteraction,
    width: u16,
    syntect: &SyntectCache,
    cache: &mut HashMap<(usize, bool), Vec<Line<'static>>>,
) -> LayoutPlan {
    let mut all_lines: Vec<Line<'static>> = Vec::new();
    let mut entry_rows: HashMap<usize, Range<u16>> = HashMap::new();

    for (idx, entry) in snapshot.entries.iter().enumerate() {
        let is_cursor = idx == state.cursor;
        let is_expanded = state.expanded.contains(&idx);

        match entry {
            TranscriptEntry::TurnEnd => {
                // Render as a visual separator but don't add to entry_rows.
                all_lines.push(Line::from(Span::styled(
                    "─".repeat(width.saturating_sub(2) as usize),
                    ratatui::style::Style::default().fg(theme::BORDER_INACTIVE),
                )));
            }

            TranscriptEntry::Thinking(text) if !state.show_thinking => {
                // Omit entirely.
                let _ = text;
            }

            TranscriptEntry::UserMessage(text) => {
                let start = all_lines.len() as u16;
                for (i, part) in text.lines().enumerate() {
                    let (prefix_style, body_modifier) = if i == 0 {
                        (
                            ratatui::style::Style::default()
                                .fg(theme::SAGE)
                                .add_modifier(Modifier::BOLD),
                            Modifier::empty(),
                        )
                    } else {
                        (theme::style_sage(), Modifier::empty())
                    };
                    all_lines.push(gutter_line(
                        Line::from(vec![
                            Span::styled("┃ ".to_string(), prefix_style),
                            Span::styled(
                                part.to_string(),
                                ratatui::style::Style::default()
                                    .fg(theme::SAGE)
                                    .add_modifier(body_modifier),
                            ),
                        ]),
                        is_cursor,
                    ));
                }
                let end = all_lines.len() as u16;
                entry_rows.insert(idx, start..end);
            }

            TranscriptEntry::AssistantText(md) => {
                let cached = cache
                    .entry((idx, false))
                    .or_insert_with(|| render_markdown(md, syntect, width.saturating_sub(2)));
                let start = all_lines.len() as u16;
                for line in cached.clone() {
                    all_lines.push(gutter_line(line, is_cursor));
                }
                let end = all_lines.len() as u16;
                entry_rows.insert(idx, start..end);
            }

            TranscriptEntry::Thinking(text) => {
                // show_thinking is true here (handled above otherwise).
                let start = all_lines.len() as u16;
                let text_lines: Vec<&str> = text.lines().collect();
                let is_long = text_lines.len() > 20;

                if is_long && !is_expanded {
                    // Show first 5 lines + hint.
                    for part in text_lines.iter().take(5) {
                        all_lines.push(gutter_line(thinking_line(part, true), is_cursor));
                    }
                    let remaining = text_lines.len() - 5;
                    all_lines.push(gutter_line(
                        Line::from(Span::styled(
                            format!("… ({remaining} more lines, press o to expand)"),
                            theme::style_dim(),
                        )),
                        is_cursor,
                    ));
                } else {
                    for part in &text_lines {
                        all_lines.push(gutter_line(thinking_line(part, false), is_cursor));
                    }
                }
                let end = all_lines.len() as u16;
                entry_rows.insert(idx, start..end);
            }

            TranscriptEntry::ToolUse { name, input } => {
                let start = all_lines.len() as u16;

                if is_expanded {
                    // Header line.
                    all_lines.push(gutter_line(
                        Line::from(vec![
                            Span::styled("▾ ", theme::style_dim()),
                            Span::styled(
                                format!("⚙ {name}"),
                                ratatui::style::Style::default()
                                    .fg(theme::AMBER)
                                    .add_modifier(Modifier::BOLD),
                            ),
                        ]),
                        is_cursor,
                    ));
                    // Expanded JSON body — use cached render.
                    let body_lines = cache.entry((idx, true)).or_insert_with(|| {
                        let json_src = serde_json::to_string_pretty(input).unwrap_or_default();
                        let md = format!("```json\n{json_src}\n```");
                        let mut rendered = render_markdown(&md, syntect, width.saturating_sub(4));
                        // Indent 2 columns.
                        for line in &mut rendered {
                            line.spans.insert(0, Span::raw("  "));
                        }
                        rendered
                    });
                    for line in body_lines.clone() {
                        all_lines.push(gutter_line(line, is_cursor));
                    }
                } else {
                    // Collapsed: single summary line.
                    let summary = first_line_of_json(input, width.saturating_sub(12) as usize);
                    all_lines.push(gutter_line(
                        Line::from(vec![
                            Span::styled("▸ ", theme::style_dim()),
                            Span::styled(
                                format!("⚙ {name}  "),
                                ratatui::style::Style::default()
                                    .fg(theme::AMBER)
                                    .add_modifier(Modifier::BOLD),
                            ),
                            Span::styled(summary, theme::style_muted()),
                        ]),
                        is_cursor,
                    ));
                }

                let end = all_lines.len() as u16;
                entry_rows.insert(idx, start..end);
            }

            TranscriptEntry::ToolResult {
                tool_use_id,
                content,
            } => {
                let start = all_lines.len() as u16;

                if is_expanded {
                    // Header.
                    let id_short = &tool_use_id[..tool_use_id.len().min(8)];
                    all_lines.push(gutter_line(
                        Line::from(vec![
                            Span::styled("▾ ", theme::style_dim()),
                            Span::styled(
                                format!("↳ {id_short}"),
                                ratatui::style::Style::default()
                                    .fg(theme::FG_MUTED)
                                    .add_modifier(Modifier::BOLD),
                            ),
                        ]),
                        is_cursor,
                    ));
                    // Body: render as markdown if it looks like it, else wrapped plain text.
                    let body_lines = cache.entry((idx, true)).or_insert_with(|| {
                        if looks_like_markdown(content) {
                            render_markdown(content, syntect, width.saturating_sub(4))
                        } else {
                            wrap_plain(content, width.saturating_sub(4) as usize)
                        }
                    });
                    for line in body_lines.clone() {
                        all_lines.push(gutter_line(line, is_cursor));
                    }
                } else {
                    // Collapsed: single preview line.
                    let preview: String = content.chars().take(80).collect();
                    let preview = if content.len() > 80 {
                        format!("{preview}…")
                    } else {
                        preview
                    };
                    let id_short = &tool_use_id[..tool_use_id.len().min(8)];
                    all_lines.push(gutter_line(
                        Line::from(vec![
                            Span::styled("▸ ", theme::style_dim()),
                            Span::styled(format!("↳ {id_short}  "), theme::style_muted()),
                            Span::styled(preview, theme::style_muted()),
                        ]),
                        is_cursor,
                    ));
                }

                let end = all_lines.len() as u16;
                entry_rows.insert(idx, start..end);
            }
        }
    }

    if all_lines.is_empty() {
        all_lines.push(Line::from(Span::styled(
            " No transcript yet…",
            theme::style_muted(),
        )));
    }

    LayoutPlan {
        lines: all_lines,
        entry_rows,
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Prepend a left-gutter cursor mark when `is_cursor` is true, otherwise a
/// blank gutter cell.
fn gutter_line(mut line: Line<'static>, is_cursor: bool) -> Line<'static> {
    let gutter = if is_cursor {
        Span::styled("▎", ratatui::style::Style::default().fg(theme::CURSOR))
    } else {
        Span::raw(" ")
    };
    line.spans.insert(0, gutter);
    line
}

/// Render a single line of thinking text as dim italic with `· ` prefix.
fn thinking_line(part: &str, first: bool) -> Line<'static> {
    let prefix = if first { "· " } else { "  " };
    Line::from(vec![
        Span::styled(
            prefix.to_string(),
            ratatui::style::Style::default()
                .fg(theme::FG_MUTED)
                .add_modifier(Modifier::ITALIC),
        ),
        Span::styled(part.to_string(), theme::style_muted()),
    ])
}

/// Return the first non-empty line of a pretty-printed JSON value, truncated
/// to `max_cols` columns.
fn first_line_of_json(value: &serde_json::Value, max_cols: usize) -> String {
    let s = serde_json::to_string_pretty(value).unwrap_or_default();
    let first = s.lines().next().unwrap_or("").trim();
    if first.len() > max_cols {
        format!("{}…", &first[..max_cols])
    } else {
        first.to_string()
    }
}

/// Heuristic: does `text` look like it contains markdown?
fn looks_like_markdown(text: &str) -> bool {
    text.contains("\n#") || text.contains("```") || text.contains("\n- ") || text.contains("\n* ")
}

/// Wrap `text` at `width` columns as plain lines (no markdown parsing).
fn wrap_plain(text: &str, width: usize) -> Vec<Line<'static>> {
    if width == 0 {
        return vec![];
    }
    let mut lines = Vec::new();
    for src_line in text.lines() {
        if src_line.is_empty() {
            lines.push(Line::from(vec![]));
            continue;
        }
        let mut start = 0;
        let chars: Vec<char> = src_line.chars().collect();
        while start < chars.len() {
            let end = (start + width).min(chars.len());
            let chunk: String = chars[start..end].iter().collect();
            lines.push(Line::from(Span::styled(chunk, theme::style_muted())));
            start = end;
        }
    }
    if lines.is_empty() {
        lines.push(Line::from(vec![]));
    }
    lines
}

// ── Auto-scroll helper ────────────────────────────────────────────────────────

/// Given the cursor entry's row range and the visible pane height, compute the
/// `scroll_offset` (top line index to display) that keeps the cursor in view.
///
/// `current_offset` is the current top-of-view line index; returned unchanged
/// if the cursor is already visible.
pub fn scroll_to_cursor(
    entry_rows: &HashMap<usize, Range<u16>>,
    cursor: usize,
    pane_height: u16,
    current_offset: u16,
) -> u16 {
    let Some(range) = entry_rows.get(&cursor) else {
        return current_offset;
    };
    let entry_top = range.start;
    let entry_bot = range.end.saturating_sub(1);

    if entry_top < current_offset {
        // Cursor is above the viewport — scroll up.
        entry_top
    } else if entry_bot >= current_offset + pane_height {
        // Cursor is below the viewport — scroll down just enough.
        entry_bot.saturating_sub(pane_height.saturating_sub(1))
    } else {
        current_offset
    }
}
