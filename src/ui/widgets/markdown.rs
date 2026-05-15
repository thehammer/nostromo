//! Markdown → Ratatui renderer (transcript pane, phase 2).
//!
//! Entry point: [`render_markdown`].  Consumes a markdown source string and
//! returns a `Vec<Line<'static>>` suitable for caching across frames.  All
//! spans are owned so the caller may cache them without holding a borrow.
//!
//! ## Supported constructs
//!
//! - Headings H1–H6 (colour-coded, blank line after)
//! - Paragraphs (word-wrapped at `width`)
//! - Emphasis / Strong / Strikethrough
//! - Inline code (distinct fg colour)
//! - Fenced code blocks (syntect-highlighted; long lines truncated with `…`)
//! - Bullet and ordered lists (nested, indented)
//! - Block quotes (prefixed with `▎ `)
//! - Horizontal rules (`─` spanning width)
//! - Tables (unicode box-drawing at full width, ASCII fallback when narrow)
//! - Links (`text ⟨url⟩`)
//! - Images (`[image: alt]` placeholder)
//! - Task list markers (`[x] ` / `[ ] `)
//!
//! ## Word wrapping
//!
//! Text is split at word (whitespace) boundaries.  Code blocks are **not**
//! wrapped — long lines are truncated with `…` instead.

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::{
    style::{Modifier, Style},
    text::{Line, Span},
};
use unicode_width::UnicodeWidthStr;

use crate::ui::{theme, widgets::syntect_cache::SyntectCache};

// ── Public entry point ────────────────────────────────────────────────────────

/// Render `src` as markdown into a list of styled ratatui lines.
///
/// `width` is the available terminal width in columns.  Pass the inner width
/// of the pane (border already subtracted).
pub fn render_markdown(src: &str, syntect: &SyntectCache, width: u16) -> Vec<Line<'static>> {
    let opts = Options::ENABLE_TABLES
        | Options::ENABLE_STRIKETHROUGH
        | Options::ENABLE_TASKLISTS
        | Options::ENABLE_FOOTNOTES;
    let mut ctx = Ctx::new(syntect, width as usize);
    for ev in Parser::new_ext(src, opts) {
        ctx.handle(ev);
    }
    ctx.finish()
}

// ── Internal word-wrap helper ─────────────────────────────────────────────────

/// Decomposed inline token (one word or space run).
struct Token {
    text: String,
    style: Style,
    is_space: bool,
}

/// Pack accumulated `tokens` into `Vec<Line>` that fit within `width` columns.
/// `indent_w` is the already-consumed column width for block prefixes (list
/// bullets, blockquote bars, etc.) that appear on every continuation line.
fn pack_tokens(tokens: Vec<Token>, width: usize, indent_w: usize) -> Vec<Line<'static>> {
    if tokens.is_empty() {
        return vec![Line::from(vec![])];
    }
    let eff = if width > indent_w { width - indent_w } else { 1 };

    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut cur: Vec<Span<'static>> = Vec::new();
    let mut cur_w: usize = 0;

    for tok in tokens {
        let w = UnicodeWidthStr::width(tok.text.as_str());
        if tok.is_space {
            if cur_w > 0 {
                // Only add space if something is already on the line.
                cur.push(Span::styled(tok.text, tok.style));
                cur_w += w;
            }
        } else if cur_w == 0 {
            // First word on this line.
            cur.push(Span::styled(tok.text, tok.style));
            cur_w = w;
        } else if cur_w + w <= eff {
            cur.push(Span::styled(tok.text, tok.style));
            cur_w += w;
        } else {
            // Flush and start new line.
            // Trim trailing spaces from current line.
            while cur.last().map(|s: &Span| s.content.trim().is_empty()).unwrap_or(false) {
                cur.pop();
            }
            lines.push(Line::from(std::mem::take(&mut cur)));
            cur.push(Span::styled(tok.text, tok.style));
            cur_w = w;
        }
    }

    while cur.last().map(|s: &Span| s.content.trim().is_empty()).unwrap_or(false) {
        cur.pop();
    }
    if !cur.is_empty() {
        lines.push(Line::from(cur));
    }
    if lines.is_empty() {
        lines.push(Line::from(vec![]));
    }
    lines
}

/// Convert a string and style into word-level `Token`s.
fn tokenise(text: &str, style: Style) -> Vec<Token> {
    let mut out = Vec::new();
    let mut chars = text.char_indices().peekable();
    while let Some((start, ch)) = chars.next() {
        if ch.is_whitespace() {
            // Collect the whitespace run.
            let mut end = start + ch.len_utf8();
            while chars.peek().map(|(_, c)| c.is_whitespace()).unwrap_or(false) {
                let (_, nc) = chars.next().unwrap();
                end += nc.len_utf8();
            }
            out.push(Token { text: " ".to_string(), style, is_space: true });
            let _ = end; // consumed
        } else {
            // Collect a word.
            let mut end = start + ch.len_utf8();
            while chars.peek().map(|(_, c)| !c.is_whitespace()).unwrap_or(false) {
                let (_, nc) = chars.next().unwrap();
                end += nc.len_utf8();
            }
            out.push(Token { text: text[start..end].to_string(), style, is_space: false });
        }
    }
    out
}

// ── Renderer context ──────────────────────────────────────────────────────────

struct Ctx<'a> {
    syntect: &'a SyntectCache,
    width: usize,

    /// Finished output lines.
    out: Vec<Line<'static>>,

    /// Inline token accumulator for the current block.
    tokens: Vec<Token>,

    /// Style modifier stack (Emphasis / Strong / Strikethrough).
    style_stack: Vec<Style>,

    /// Block-level prefix (blockquote / list item).
    prefix: String,

    /// Cached unicode column width of `prefix`.
    prefix_w: usize,

    // ── Heading ───────────────────────────────────────────────────────────────
    heading: Option<HeadingLevel>,

    // ── Code block ───────────────────────────────────────────────────────────
    in_code_block: bool,
    code_lang: String,
    code_buf: String,

    // ── Lists ─────────────────────────────────────────────────────────────────
    /// Stack of list contexts.  `None` = bullet, `Some(n)` = ordered (counter).
    list_stack: Vec<Option<u64>>,

    // ── Block quote ───────────────────────────────────────────────────────────
    blockquote_depth: usize,

    // ── Table ─────────────────────────────────────────────────────────────────
    in_table: bool,
    in_table_head: bool,
    table_headers: Vec<String>,
    table_rows: Vec<Vec<String>>,
    cur_row: Vec<String>,
    cur_cell: String,

    // ── Link ──────────────────────────────────────────────────────────────────
    link_dest: Option<String>,

    // ── Image alt text accumulation ───────────────────────────────────────────
    in_image: bool,
    image_alt: String,
}

impl<'a> Ctx<'a> {
    fn new(syntect: &'a SyntectCache, width: usize) -> Self {
        Self {
            syntect,
            width,
            out: Vec::new(),
            tokens: Vec::new(),
            style_stack: Vec::new(),
            prefix: String::new(),
            prefix_w: 0,
            heading: None,
            in_code_block: false,
            code_lang: String::new(),
            code_buf: String::new(),
            list_stack: Vec::new(),
            blockquote_depth: 0,
            in_table: false,
            in_table_head: false,
            table_headers: Vec::new(),
            table_rows: Vec::new(),
            cur_row: Vec::new(),
            cur_cell: String::new(),
            link_dest: None,
            in_image: false,
            image_alt: String::new(),
        }
    }

    // ── Current inline style ──────────────────────────────────────────────────

    fn cur_style(&self) -> Style {
        self.style_stack.last().copied().unwrap_or_else(theme::style_normal)
    }

    // ── Push inline token ─────────────────────────────────────────────────────

    fn push_text(&mut self, text: &str, style: Style) {
        self.tokens.extend(tokenise(text, style));
    }

    // ── Flush inline tokens as lines ──────────────────────────────────────────

    fn flush_inline(&mut self) {
        if self.tokens.is_empty() {
            return;
        }
        let toks = std::mem::take(&mut self.tokens);
        let prefix_w = self.prefix_w;
        let width = self.width;
        let prefix = self.prefix.clone();

        let wrapped = pack_tokens(toks, width, prefix_w);
        for mut line in wrapped {
            if !prefix.is_empty() {
                let mut spans = vec![Span::styled(prefix.clone(), theme::style_muted())];
                spans.append(&mut line.spans);
                line = Line::from(spans);
            }
            self.out.push(line);
        }
    }

    fn blank_line(&mut self) {
        self.out.push(Line::from(vec![]));
    }

    // ── Rebuild prefix from list/blockquote state ─────────────────────────────

    fn rebuild_prefix(&mut self) {
        let mut p = String::new();
        // Blockquote bars.
        for _ in 0..self.blockquote_depth {
            p.push_str("▎ ");
        }
        // List indentation (innermost list adds the bullet; outer lists add spaces).
        if let Some(depth) = self.list_stack.len().checked_sub(1) {
            for _ in 0..depth {
                p.push_str("  ");
            }
        }
        self.prefix_w = UnicodeWidthStr::width(p.as_str());
        self.prefix = p;
    }

    // ── Table rendering ───────────────────────────────────────────────────────

    fn flush_table(&mut self) {
        if self.table_headers.is_empty() && self.table_rows.is_empty() {
            return;
        }

        let num_cols = self
            .table_headers
            .len()
            .max(self.table_rows.iter().map(|r| r.len()).max().unwrap_or(0));
        if num_cols == 0 {
            return;
        }

        // Compute per-column max widths (header + data rows).
        let mut col_widths: Vec<usize> = vec![0; num_cols];
        for (i, h) in self.table_headers.iter().enumerate() {
            col_widths[i] = col_widths[i].max(UnicodeWidthStr::width(h.as_str()));
        }
        for row in &self.table_rows {
            for (i, cell) in row.iter().enumerate() {
                if i < num_cols {
                    col_widths[i] = col_widths[i].max(UnicodeWidthStr::width(cell.as_str()));
                }
            }
        }

        // Ensure minimum 1 char per column.
        for w in &mut col_widths {
            if *w == 0 {
                *w = 1;
            }
        }

        // Natural width: borders + padding.  Each cell: "│ " + content + " "
        let natural: usize = col_widths.iter().sum::<usize>() + num_cols * 3 + 1;
        let unicode = natural <= self.width;

        let h_style = Style::default()
            .fg(theme::FG)
            .add_modifier(Modifier::BOLD);
        let border_style = theme::style_muted();
        let cell_style = theme::style_normal();

        if unicode {
            // ── Unicode box-drawing ─────────────────────────────────────────
            let top = build_box_line(&col_widths, '┌', '┬', '┐', '─');
            let mid = build_box_line(&col_widths, '├', '┼', '┤', '─');
            let bot = build_box_line(&col_widths, '└', '┴', '┘', '─');

            self.out.push(Line::from(Span::styled(top, border_style)));

            // Header row.
            if !self.table_headers.is_empty() {
                let row_line = build_cell_line(&self.table_headers, &col_widths, h_style, border_style);
                self.out.push(row_line);
                self.out.push(Line::from(Span::styled(mid.clone(), border_style)));
            }

            // Data rows.
            for (ri, row) in self.table_rows.iter().enumerate() {
                let padded: Vec<String> = (0..num_cols)
                    .map(|i| row.get(i).cloned().unwrap_or_default())
                    .collect();
                let row_line = build_cell_line(&padded, &col_widths, cell_style, border_style);
                self.out.push(row_line);
                if ri < self.table_rows.len() - 1 {
                    // Omit mid separator between data rows for a cleaner look.
                }
            }

            self.out.push(Line::from(Span::styled(bot, border_style)));
        } else {
            // ── ASCII pipe fallback ─────────────────────────────────────────
            if !self.table_headers.is_empty() {
                let mut spans = vec![Span::styled("| ", border_style)];
                for (i, h) in self.table_headers.iter().enumerate() {
                    spans.push(Span::styled(h.clone(), h_style));
                    if i < self.table_headers.len() - 1 {
                        spans.push(Span::styled(" | ", border_style));
                    }
                }
                spans.push(Span::styled(" |", border_style));
                self.out.push(Line::from(spans));
            }
            for row in &self.table_rows {
                let mut spans = vec![Span::styled("| ", border_style)];
                for (i, cell) in row.iter().enumerate() {
                    spans.push(Span::styled(cell.clone(), cell_style));
                    if i < row.len() - 1 {
                        spans.push(Span::styled(" | ", border_style));
                    }
                }
                spans.push(Span::styled(" |", border_style));
                self.out.push(Line::from(spans));
            }
        }

        self.blank_line();
        self.table_headers.clear();
        self.table_rows.clear();
        self.cur_row.clear();
        self.cur_cell.clear();
        self.in_table = false;
        self.in_table_head = false;
    }

    // ── Event handler ─────────────────────────────────────────────────────────

    fn handle(&mut self, ev: Event<'_>) {
        match ev {
            // ── Block starts ──────────────────────────────────────────────────
            Event::Start(Tag::Heading { level, .. }) => {
                self.heading = Some(level);
            }
            Event::Start(Tag::Paragraph) => {
                // Nothing to do — tokens accumulate via Text events.
            }
            Event::Start(Tag::CodeBlock(kind)) => {
                self.in_code_block = true;
                self.code_lang = match kind {
                    CodeBlockKind::Fenced(info) => info.split_whitespace().next().unwrap_or("").to_string(),
                    CodeBlockKind::Indented => String::new(),
                };
                self.code_buf.clear();
            }
            Event::Start(Tag::List(start)) => {
                self.list_stack.push(start);
                self.rebuild_prefix();
            }
            Event::Start(Tag::Item) => {
                self.flush_inline();
                // Emit the bullet/number as part of the prefix for this item.
                let bullet = match self.list_stack.last_mut() {
                    Some(Some(ref mut n)) => {
                        let s = format!("{}. ", n);
                        *n += 1;
                        s
                    }
                    _ => "• ".to_string(),
                };
                // Indent by (depth-1)*2 spaces + bullet.
                let depth = self.list_stack.len().saturating_sub(1);
                let indent = "  ".repeat(depth);
                let full = format!("{}{}{}", indent, bullet, " ".repeat(0));
                self.prefix_w = UnicodeWidthStr::width(full.as_str());
                self.prefix = full;
            }
            Event::Start(Tag::BlockQuote(_)) => {
                self.flush_inline();
                self.blockquote_depth += 1;
                self.rebuild_prefix();
            }
            Event::Start(Tag::Table(_)) => {
                self.flush_inline();
                self.in_table = true;
                self.table_headers.clear();
                self.table_rows.clear();
            }
            Event::Start(Tag::TableHead) => {
                self.in_table_head = true;
                self.cur_row.clear();
            }
            Event::Start(Tag::TableRow) => {
                self.cur_row.clear();
            }
            Event::Start(Tag::TableCell) => {
                self.cur_cell.clear();
            }
            Event::Start(Tag::Emphasis) => {
                let base = self.cur_style();
                self.style_stack.push(base.add_modifier(Modifier::ITALIC));
            }
            Event::Start(Tag::Strong) => {
                let base = self.cur_style();
                self.style_stack.push(base.add_modifier(Modifier::BOLD));
            }
            Event::Start(Tag::Strikethrough) => {
                let base = self.cur_style();
                self.style_stack.push(base.add_modifier(Modifier::CROSSED_OUT));
            }
            Event::Start(Tag::Link { dest_url, .. }) => {
                self.link_dest = Some(dest_url.to_string());
            }
            Event::Start(Tag::Image { .. }) => {
                self.in_image = true;
                self.image_alt.clear();
            }
            Event::Start(_) => {}

            // ── Block ends ────────────────────────────────────────────────────
            Event::End(TagEnd::Heading(_)) => {
                let level = self.heading.take();
                let style = heading_style(level);
                // Apply heading style to all accumulated tokens.
                for tok in &mut self.tokens {
                    tok.style = style;
                }
                self.flush_inline();
                self.blank_line();
            }
            Event::End(TagEnd::Paragraph) => {
                self.flush_inline();
                self.blank_line();
            }
            Event::End(TagEnd::CodeBlock) => {
                // Strip trailing newline from buf.
                let code = self.code_buf.trim_end_matches('\n').to_string();
                let lang = self.code_lang.clone();

                let max_display = self.width.saturating_sub(self.prefix_w + 2);
                let mut highlighted = self.syntect.highlight_block(&code, &lang);

                // Truncate long lines with `…`.
                for line in &mut highlighted {
                    let total_w: usize = line
                        .spans
                        .iter()
                        .map(|s| UnicodeWidthStr::width(s.content.as_ref()))
                        .sum();
                    if total_w > max_display && max_display > 1 {
                        truncate_line(line, max_display);
                    }
                }

                self.out.extend(highlighted);
                self.blank_line();
                self.in_code_block = false;
                self.code_buf.clear();
                self.code_lang.clear();
            }
            Event::End(TagEnd::List(_)) => {
                self.flush_inline();
                self.list_stack.pop();
                self.rebuild_prefix();
                self.blank_line();
            }
            Event::End(TagEnd::Item) => {
                self.flush_inline();
                // Reset to list-level prefix (no bullet on continuation lines).
                self.rebuild_prefix();
            }
            Event::End(TagEnd::BlockQuote(_)) => {
                self.flush_inline();
                self.blockquote_depth = self.blockquote_depth.saturating_sub(1);
                self.rebuild_prefix();
                self.blank_line();
            }
            Event::End(TagEnd::Table) => {
                self.flush_table();
            }
            Event::End(TagEnd::TableHead) => {
                self.table_headers = std::mem::take(&mut self.cur_row);
                self.in_table_head = false;
            }
            Event::End(TagEnd::TableRow) => {
                if !self.in_table_head {
                    self.table_rows.push(std::mem::take(&mut self.cur_row));
                }
            }
            Event::End(TagEnd::TableCell) => {
                self.cur_row.push(std::mem::take(&mut self.cur_cell));
            }
            Event::End(TagEnd::Emphasis)
            | Event::End(TagEnd::Strong)
            | Event::End(TagEnd::Strikethrough) => {
                self.style_stack.pop();
            }
            Event::End(TagEnd::Link) => {
                if let Some(url) = self.link_dest.take() {
                    let dim = theme::style_muted();
                    self.push_text(&format!(" ⟨{url}⟩"), dim);
                }
            }
            Event::End(TagEnd::Image) => {
                let alt = std::mem::take(&mut self.image_alt);
                let placeholder = format!("[image: {}]", alt.trim());
                let style = theme::style_muted();
                self.push_text(&placeholder, style);
                self.in_image = false;
            }
            Event::End(_) => {}

            // ── Inline events ─────────────────────────────────────────────────
            Event::Text(s) => {
                if self.in_code_block {
                    self.code_buf.push_str(&s);
                } else if self.in_table {
                    self.cur_cell.push_str(&s);
                } else if self.in_image {
                    self.image_alt.push_str(&s);
                } else {
                    let style = self.cur_style();
                    // For links, use link style.
                    let effective_style = if self.link_dest.is_some() {
                        theme::style_link()
                    } else {
                        style
                    };
                    self.push_text(&s, effective_style);
                }
            }
            Event::Code(s) => {
                // Inline code.
                if self.in_table {
                    self.cur_cell.push_str(&s);
                } else {
                    let style = theme::style_code_inline();
                    self.tokens.push(Token {
                        text: s.to_string(),
                        style,
                        is_space: false,
                    });
                }
            }
            Event::Html(s) | Event::InlineHtml(s) => {
                // Pass HTML through as plain text.
                if self.in_table {
                    self.cur_cell.push_str(&s);
                } else {
                    let style = theme::style_muted();
                    self.push_text(&s, style);
                }
            }
            Event::SoftBreak => {
                // Treat as a space.
                if self.in_code_block {
                    self.code_buf.push('\n');
                } else if self.in_table {
                    self.cur_cell.push(' ');
                } else {
                    self.tokens.push(Token {
                        text: " ".to_string(),
                        style: self.cur_style(),
                        is_space: true,
                    });
                }
            }
            Event::HardBreak => {
                if self.in_code_block {
                    self.code_buf.push('\n');
                } else {
                    self.flush_inline();
                }
            }
            Event::Rule => {
                self.flush_inline();
                let w = self.width.max(1);
                let rule = "─".repeat(w);
                self.out.push(Line::from(Span::styled(rule, theme::style_muted())));
                self.blank_line();
            }
            Event::TaskListMarker(checked) => {
                let marker = if checked { "[x] " } else { "[ ] " };
                self.push_text(marker, theme::style_normal());
            }
            Event::FootnoteReference(_) => {}
            Event::InlineMath(_) | Event::DisplayMath(_) => {}
        }
    }

    // ── Finalise ──────────────────────────────────────────────────────────────

    fn finish(mut self) -> Vec<Line<'static>> {
        self.flush_inline();
        // Remove trailing blank lines.
        while self.out.last().map(|l: &Line| l.spans.is_empty()).unwrap_or(false) {
            self.out.pop();
        }
        if self.out.is_empty() {
            self.out.push(Line::from(Span::styled(
                "(empty)".to_string(),
                theme::style_muted(),
            )));
        }
        self.out
    }
}

// ── Heading style ─────────────────────────────────────────────────────────────

fn heading_style(level: Option<HeadingLevel>) -> Style {
    use ratatui::style::Color;
    match level {
        Some(HeadingLevel::H1) => Style::default()
            .fg(theme::AMBER)
            .add_modifier(Modifier::BOLD),
        Some(HeadingLevel::H2) => Style::default()
            .fg(theme::SAGE)
            .add_modifier(Modifier::BOLD),
        _ => Style::default()
            .fg(Color::Rgb(200, 200, 200))
            .add_modifier(Modifier::BOLD),
    }
}

// ── Table box-drawing helpers ─────────────────────────────────────────────────

fn build_box_line(col_widths: &[usize], left: char, mid: char, right: char, fill: char) -> String {
    let mut s = String::new();
    s.push(left);
    for (i, &w) in col_widths.iter().enumerate() {
        s.extend(std::iter::repeat_n(fill, w + 2));
        if i < col_widths.len() - 1 {
            s.push(mid);
        }
    }
    s.push(right);
    s
}

fn build_cell_line(
    cells: &[String],
    col_widths: &[usize],
    cell_style: Style,
    border_style: Style,
) -> Line<'static> {
    let mut spans: Vec<Span<'static>> = Vec::new();
    spans.push(Span::styled("│", border_style));
    for (i, w) in col_widths.iter().enumerate() {
        let content = cells.get(i).cloned().unwrap_or_default();
        let cw = UnicodeWidthStr::width(content.as_str());
        let pad = if cw < *w { " ".repeat(*w - cw) } else { String::new() };
        spans.push(Span::styled(" ", border_style));
        spans.push(Span::styled(content, cell_style));
        spans.push(Span::styled(pad + " ", border_style));
        spans.push(Span::styled("│", border_style));
    }
    Line::from(spans)
}

// ── Code block line truncation ────────────────────────────────────────────────

fn truncate_line(line: &mut Line<'static>, max_w: usize) {
    if max_w == 0 {
        line.spans.clear();
        return;
    }
    let mut total = 0usize;
    let mut truncated = false;
    let mut new_spans: Vec<Span<'static>> = Vec::new();
    for span in std::mem::take(&mut line.spans) {
        let sw = UnicodeWidthStr::width(span.content.as_ref());
        if total + sw <= max_w.saturating_sub(1) {
            total += sw;
            new_spans.push(span);
        } else {
            // Trim this span to fit + append ellipsis.
            let avail = max_w.saturating_sub(total + 1); // 1 for `…`
            let trimmed = char_truncate(&span.content, avail);
            if !trimmed.is_empty() {
                new_spans.push(Span::styled(trimmed, span.style));
            }
            new_spans.push(Span::styled("…".to_string(), theme::style_muted()));
            truncated = true;
            break;
        }
    }
    if !truncated && total >= max_w {
        // Edge: exactly at limit, no ellipsis needed.
    }
    line.spans = new_spans;
}

fn char_truncate(s: &str, max_w: usize) -> String {
    let mut out = String::new();
    let mut w = 0;
    for ch in s.chars() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(1);
        if w + cw > max_w {
            break;
        }
        out.push(ch);
        w += cw;
    }
    out
}

// ── Inline unit tests ─────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::widgets::syntect_cache::SyntectCache;

    fn mk_syntect() -> SyntectCache {
        SyntectCache::load().expect("syntect loads")
    }

    #[test]
    fn short_text_no_wrap() {
        let sc = mk_syntect();
        let lines = render_markdown("Hello world", &sc, 40);
        let text: String = lines.iter().flat_map(|l| l.spans.iter().map(|s| s.content.as_ref())).collect();
        assert!(text.contains("Hello"));
        assert!(text.contains("world"));
        assert_eq!(lines.len(), 1);
    }

    #[test]
    fn word_wrap_at_width() {
        let sc = mk_syntect();
        // 10 words of ~4 chars each at width 20 should produce multiple lines.
        let src = "word word word word word word word word word word";
        let lines = render_markdown(src, &sc, 20);
        assert!(
            lines.len() >= 2,
            "expected wrapping but got {} lines",
            lines.len()
        );
    }

    #[test]
    fn code_block_styles() {
        let sc = mk_syntect();
        let src = "```rust\nfn main() { println!(\"hi\"); }\n```";
        let lines = render_markdown(src, &sc, 80);
        // Collect all distinct foreground colours from the code block lines.
        use std::collections::HashSet;
        let styles: HashSet<_> = lines
            .iter()
            .flat_map(|l| l.spans.iter().map(|s| s.style.fg))
            .collect();
        assert!(
            styles.len() > 1,
            "expected >1 distinct style from syntect highlighting, got {:?}",
            styles
        );
    }
}
