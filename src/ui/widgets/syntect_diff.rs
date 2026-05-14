//! `SyntectDiff` — Ratatui widget that renders a unified diff with
//! syntax highlighting from syntect.
//!
//! For each hunk body line the file-appropriate syntax is used; `+` / `-` / `@@`
//! line accents are layered on top using the nostromo theme colours so the diff
//! structure remains visually clear.

use std::sync::Arc;

use ratatui::{
    buffer::Buffer,
    layout::Rect,
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::Widget,
};
use syntect::easy::HighlightLines;
use syntect::highlighting::Style as SyntectStyle;

use super::syntect_cache::SyntectCache;
use crate::ui::theme;
use crate::ui::widgets::truncate::truncate;

/// A Ratatui widget that renders `diff_text` with syntax highlighting.
pub struct SyntectDiff<'a> {
    diff: &'a str,
    cache: Arc<SyntectCache>,
    max_lines: usize,
}

impl<'a> SyntectDiff<'a> {
    pub fn new(diff: &'a str, cache: Arc<SyntectCache>) -> Self {
        Self {
            diff,
            cache,
            max_lines: usize::MAX,
        }
    }

    /// Restrict rendering to the first `n` lines (useful when the caller
    /// knows the available height).
    #[allow(dead_code)]
    pub fn max_lines(mut self, n: usize) -> Self {
        self.max_lines = n;
        self
    }

    fn render_lines(&self, area: Rect) -> Vec<Line<'static>> {
        // Detect the filename from `+++ b/<path>` so we can pick the right syntax.
        let mut syntax_ref = self.cache.syntaxes.find_syntax_plain_text();
        for line in self.diff.lines().take(10) {
            if let Some(rest) = line.strip_prefix("+++ b/") {
                if let Some(s) = self
                    .cache
                    .syntaxes
                    .find_syntax_for_file(rest)
                    .ok()
                    .flatten()
                {
                    syntax_ref = s;
                }
                break;
            }
        }

        let mut highlighter = HighlightLines::new(syntax_ref, &self.cache.theme);
        let mut result: Vec<Line<'static>> = Vec::new();

        for raw_line in self.diff.lines().take(self.max_lines) {
            // Determine the diff accent colour for this line prefix.
            let accent: Option<Color> = if raw_line.starts_with('+') && !raw_line.starts_with("+++")
            {
                Some(theme::SAGE)
            } else if raw_line.starts_with('-') && !raw_line.starts_with("---") {
                Some(theme::RED_SWEATER)
            } else if raw_line.starts_with("@@") {
                Some(theme::AMBER)
            } else {
                None
            };

            // syntect highlight_line wants a &str ending with '\n' but we've
            // already stripped it — append one temporarily.
            let line_with_nl = format!("{raw_line}\n");
            let ranges = highlighter
                .highlight_line(&line_with_nl, &self.cache.syntaxes)
                .unwrap_or_default();

            let spans: Vec<Span<'static>> = ranges
                .iter()
                .map(|(sy_style, text)| {
                    // Strip the trailing newline we added.
                    let text = text.trim_end_matches('\n');
                    let mut style = syntect_style_to_ratatui(*sy_style);
                    // Override foreground with diff accent when present.
                    if let Some(fg) = accent {
                        style = style.fg(fg);
                    }
                    Span::styled(text.to_string(), style)
                })
                .filter(|s| !s.content.is_empty())
                .collect();

            if spans.is_empty() {
                result.push(Line::from(Span::styled(
                    truncate(raw_line, area.width as usize),
                    accent
                        .map(|c| Style::default().fg(c))
                        .unwrap_or(theme::style_muted()),
                )));
            } else {
                result.push(Line::from(spans));
            }
        }

        result
    }
}

impl<'a> Widget for SyntectDiff<'a> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let lines = self.render_lines(area);
        for (i, line) in lines.into_iter().take(area.height as usize).enumerate() {
            let y = area.y + i as u16;
            if y >= buf.area.bottom() {
                break;
            }
            let mut x = area.x;
            for span in line.spans {
                let style = span.style;
                for ch in span.content.chars() {
                    if x >= area.x + area.width || x >= buf.area.right() {
                        break;
                    }
                    if let Some(cell) = buf.cell_mut((x, y)) {
                        let mut s = String::new();
                        s.push(ch);
                        cell.set_symbol(&s);
                        cell.set_style(style);
                    }
                    x += 1;
                }
            }
        }
    }
}

fn syntect_style_to_ratatui(s: SyntectStyle) -> Style {
    let fg = s.foreground;
    let mut style = Style::default().fg(Color::Rgb(fg.r, fg.g, fg.b));

    use syntect::highlighting::FontStyle;
    if s.font_style.contains(FontStyle::BOLD) {
        style = style.add_modifier(Modifier::BOLD);
    }
    if s.font_style.contains(FontStyle::ITALIC) {
        style = style.add_modifier(Modifier::ITALIC);
    }
    if s.font_style.contains(FontStyle::UNDERLINE) {
        style = style.add_modifier(Modifier::UNDERLINED);
    }

    style
}
