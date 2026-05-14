//! `SyntectCache` — built once at startup, shared via `Arc` across views.
//!
//! Holds the loaded `SyntaxSet` and the `base16-ocean.dark` theme so we don't
//! pay the initialisation cost on every diff render.

use anyhow::Result;
use ratatui::{
    style::{Color, Modifier, Style},
    text::{Line, Span},
};
use syntect::easy::HighlightLines;
use syntect::highlighting::{FontStyle, Style as SyntectStyle, Theme, ThemeSet};
use syntect::parsing::SyntaxSet;

pub struct SyntectCache {
    pub syntaxes: SyntaxSet,
    pub theme: Theme,
}

impl SyntectCache {
    /// Build the cache from syntect's bundled defaults.
    pub fn load() -> Result<Self> {
        let syntaxes = SyntaxSet::load_defaults_newlines();
        let theme_set = ThemeSet::load_defaults();
        let theme = theme_set
            .themes
            .get("base16-ocean.dark")
            .cloned()
            .unwrap_or_else(|| {
                // Graceful fallback: use whatever the first theme is.
                theme_set
                    .themes
                    .values()
                    .next()
                    .cloned()
                    .expect("syntect ships at least one theme")
            });
        Ok(Self { syntaxes, theme })
    }

    /// Syntax-highlight a fenced code block.
    ///
    /// `lang` is the info string from the fence (e.g. `"rust"`, `"python"`, `""`).
    /// Returns one `Line` per source line, with per-token styling.  Unknown
    /// languages fall back to plain-text rendering with a dim left bar (`│ `).
    pub fn highlight_block(&self, code: &str, lang: &str) -> Vec<Line<'static>> {
        let syntax = if lang.is_empty() {
            None
        } else {
            self.syntaxes
                .find_syntax_by_token(lang)
                .or_else(|| self.syntaxes.find_syntax_by_extension(lang))
        };

        if let Some(syntax) = syntax {
            let mut hl = HighlightLines::new(syntax, &self.theme);
            let mut out = Vec::new();
            for raw in code.lines() {
                let line_nl = format!("{raw}\n");
                let ranges = hl
                    .highlight_line(&line_nl, &self.syntaxes)
                    .unwrap_or_default();
                let spans: Vec<Span<'static>> = ranges
                    .iter()
                    .map(|(sy, text)| {
                        let t = text.trim_end_matches('\n');
                        Span::styled(t.to_string(), syntect_to_ratatui(*sy))
                    })
                    .filter(|s| !s.content.is_empty())
                    .collect();
                if spans.is_empty() {
                    out.push(Line::from(Span::raw(String::new())));
                } else {
                    out.push(Line::from(spans));
                }
            }
            out
        } else {
            // Unknown language: dim left bar
            let bar_style = Style::default().fg(Color::Rgb(80, 80, 100));
            let text_style = Style::default().fg(Color::Rgb(150, 150, 160));
            code.lines()
                .map(|raw| {
                    Line::from(vec![
                        Span::styled("│ ", bar_style),
                        Span::styled(raw.to_string(), text_style),
                    ])
                })
                .collect()
        }
    }
}

/// Convert a syntect `Style` to a ratatui `Style`.
pub(crate) fn syntect_to_ratatui(s: SyntectStyle) -> Style {
    let fg = s.foreground;
    let mut style = Style::default().fg(Color::Rgb(fg.r, fg.g, fg.b));
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
