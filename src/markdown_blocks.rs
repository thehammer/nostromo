//! Markdown → structured block model (W3 — curated-agent-views, bet B5).
//!
//! Converts raw markdown (a PR description, a review comment body) into a
//! `Vec<`[`MdBlock`]`>` using `pulldown-cmark`'s event stream. This is the
//! server side of B5: the daemon owns CommonMark parsing so every client —
//! today's macOS renderer, and iOS/`ticket` later (W4 reuses this module) —
//! gets correct fenced-code rendering without writing a parser of its own.
//! `MarkdownRenderer` (the Swift transcript renderer) is untouched; this is a
//! second, block-driven path.
//!
//! The walk is a small stack machine rather than a recursive-descent parser
//! because pulldown-cmark's event stream is flat (`Start`/`End` pairs, not a
//! tree): block-level nesting (list > item > blocks, quote > blocks, table >
//! rows > cells) and inline nesting (emphasis inside a link inside a
//! paragraph) are each modelled as their own stack. pulldown-cmark's parser is
//! infallible and always emits a well-nested event stream — even source with
//! an unclosed fence or an unclosed emphasis run gets matching `End` events
//! before the stream terminates — so this walk never needs to guess at how to
//! recover from malformed input.

use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

use crate::ipc::protocol::{MdBlock, MdSpan};

/// Convert `markdown` into a block list.
pub fn markdown_to_blocks(markdown: &str) -> Vec<MdBlock> {
    let opts = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    let mut walker = Walker::new();
    for event in Parser::new_ext(markdown, opts) {
        walker.handle(event);
    }
    walker.finish()
}

// ── Inline span nesting ───────────────────────────────────────────────────────

/// What an open nested-inline-span level (emphasis/strong/strike/link) will
/// wrap its accumulated children into when it closes. Paragraph/heading/
/// table-cell inline runs are tracked separately in `root_spans` — their
/// accumulated spans become a block/cell's `spans` field directly, with no
/// wrapping, which is why they don't need a variant here.
enum InlineKind {
    Emph,
    Strong,
    Strike,
    Link(String),
}

// ── Block accumulation ───────────────────────────────────────────────────────

/// One list under construction: whether it's ordered, its starting number,
/// and the item block-lists collected so far.
struct ListFrame {
    ordered: bool,
    start: Option<u64>,
    items: Vec<Vec<MdBlock>>,
}

/// One table under construction.
struct TableFrame {
    header: Vec<Vec<MdSpan>>,
    rows: Vec<Vec<Vec<MdSpan>>>,
    in_head: bool,
    /// Cells collected for the row currently open.
    current_row: Vec<Vec<MdSpan>>,
}

struct Walker {
    /// Stack of "the blocks accumulating at this nesting level" — the root
    /// document (always index 0), an open blockquote, or an open list item.
    blocks: Vec<Vec<MdBlock>>,
    /// Stack of open lists. A list contributes no entry to `blocks` itself —
    /// only its items do, each as its own `blocks` frame.
    lists: Vec<ListFrame>,
    /// Stack of open tables.
    tables: Vec<TableFrame>,
    /// Stack of open "outermost inline run" accumulators — one entry per open
    /// paragraph, heading, or table cell. Never more than one entry deep in
    /// practice: none of paragraph/heading/table-cell can nest inside another.
    root_spans: Vec<Vec<MdSpan>>,
    /// Whether the single open `root_spans` entry (if any) was opened
    /// implicitly by [`push_span`](Self::push_span) rather than by an
    /// explicit `Paragraph`/`Heading`/`TableCell` start.
    ///
    /// This exists because pulldown-cmark does not wrap a "tight" list
    /// item's text in `Start(Paragraph)`/`End(Paragraph)` at all (only a
    /// "loose" list — one with blank lines between items — gets real
    /// paragraph tags) — the common case for real PR descriptions, which
    /// almost never have blank lines between list items. Without this, a
    /// bare `Text` event with nothing open had nowhere to go and was
    /// silently dropped by `push_span`'s "neither open" fallback, which
    /// deleted every tight-list item's own text. Text is now given
    /// somewhere to land the moment it arrives (see `push_span`), and this
    /// flag is how [`flush_implicit_paragraph`](Self::flush_implicit_paragraph)
    /// knows to fold it into a real `Paragraph` block at the next block
    /// boundary rather than leaving it for an `End(Paragraph)` that will
    /// never come.
    root_span_is_implicit: bool,
    /// Stack of open nested-inline-span levels (emphasis/strong/strike/link)
    /// inside whatever `root_spans` level is currently open.
    inline_stack: Vec<(InlineKind, Vec<MdSpan>)>,
    /// Heading level currently open, set on `Start(Heading)` and consumed on
    /// its matching `End`.
    heading_level: Option<u8>,
    /// Raw text accumulated for an open code block — never inline-parsed, and
    /// never trimmed: the acceptance bar is "byte-for-byte apart from the
    /// fence lines", so nothing here manipulates whitespace.
    code_buf: String,
    code_lang: Option<String>,
    in_code_block: bool,
    /// Alt text accumulated for an open image — flattened to plain text,
    /// matching how every renderer treats image alt content in practice.
    in_image: bool,
    image_alt: String,
    image_url: String,
}

impl Walker {
    fn new() -> Self {
        Walker {
            blocks: vec![Vec::new()],
            lists: Vec::new(),
            tables: Vec::new(),
            root_spans: Vec::new(),
            root_span_is_implicit: false,
            inline_stack: Vec::new(),
            heading_level: None,
            code_buf: String::new(),
            code_lang: None,
            in_code_block: false,
            in_image: false,
            image_alt: String::new(),
            image_url: String::new(),
        }
    }

    fn finish(mut self) -> Vec<MdBlock> {
        self.flush_implicit_paragraph();
        self.blocks.into_iter().next().unwrap_or_default()
    }

    // ── dispatch ──────────────────────────────────────────────────────────────

    fn handle(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag_end) => self.end(tag_end),
            Event::Text(text) => self.text(&text),
            Event::Code(text) => self.inline_code(&text),
            Event::Html(text) | Event::InlineHtml(text) => self.html(&text),
            Event::SoftBreak => self.soft_break(),
            Event::HardBreak => self.hard_break(),
            Event::Rule => self.rule(),
            Event::TaskListMarker(checked) => self.task_marker(checked),
            Event::FootnoteReference(_) => {}
            // Math extensions are not enabled in `Options` above, so these
            // never fire in practice; handled for exhaustiveness by treating
            // the raw source as literal text, same as HTML.
            Event::InlineMath(text) | Event::DisplayMath(text) => self.html(&text),
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => self.root_spans.push(Vec::new()),
            Tag::Heading { level, .. } => {
                self.heading_level = Some(heading_level_u8(level));
                self.root_spans.push(Vec::new());
            }
            Tag::CodeBlock(kind) => {
                // See the matching comment on `Tag::List` below — a fenced
                // code block can nest inside a tight list item exactly the
                // same way a nested list can.
                self.flush_implicit_paragraph();
                self.in_code_block = true;
                self.code_lang = match kind {
                    CodeBlockKind::Fenced(info) => {
                        let lang = info.split_whitespace().next().unwrap_or("");
                        if lang.is_empty() {
                            None
                        } else {
                            Some(lang.to_string())
                        }
                    }
                    CodeBlockKind::Indented => None,
                };
                self.code_buf.clear();
            }
            Tag::List(start) => {
                // A tight list item accumulates its own text as an *implicit*
                // paragraph in `root_spans` (no blank line ever closed it —
                // see `flush_implicit_paragraph`'s doc comment). Without this
                // flush, a list nested directly inside such an item with no
                // blank line between ("- outer\n  - inner one\n") started its
                // own inline text while the outer item's implicit paragraph
                // was still the open `root_spans` level, so the outer text
                // and the nested list's first item's text landed in the
                // *same* accumulator — `flush_implicit_paragraph`'s previous
                // call sites (the various `TagEnd::Item`/`List`/`BlockQuote`
                // handlers below) only fire once a block *closes*, never when
                // one *opens* nested inside a still-open implicit paragraph.
                self.flush_implicit_paragraph();
                self.lists.push(ListFrame {
                    ordered: start.is_some(),
                    start,
                    items: Vec::new(),
                });
            }
            // A list item and a blockquote are both "open a new
            // block-accumulation frame" — same concept, same body; they only
            // differ in what their matching `End` does with the frame. Only
            // `BlockQuote` needs the flush here: a nested blockquote has the
            // exact same "opens inside a still-open implicit paragraph"
            // hazard `Tag::List` above documents, but a nested `Item` doesn't
            // — sibling items are already flushed at `TagEnd::Item`, and the
            // *first* item's case is already covered by `Tag::List`'s own
            // flush immediately above it.
            Tag::BlockQuote(_) => {
                self.flush_implicit_paragraph();
                self.blocks.push(Vec::new());
            }
            Tag::Item => self.blocks.push(Vec::new()),
            Tag::Table(_alignments) => {
                self.flush_implicit_paragraph();
                self.tables.push(TableFrame {
                    header: Vec::new(),
                    rows: Vec::new(),
                    in_head: false,
                    current_row: Vec::new(),
                });
            }
            Tag::TableHead => {
                if let Some(t) = self.tables.last_mut() {
                    t.in_head = true;
                }
            }
            Tag::TableRow => {
                if let Some(t) = self.tables.last_mut() {
                    t.current_row.clear();
                }
            }
            Tag::TableCell => self.root_spans.push(Vec::new()),
            // Guarded by `!self.in_image`: while an image's alt text is being
            // accumulated, `text()`/`inline_code()` divert straight into
            // `image_alt` (flattening any inline markup inside the alt to
            // plain text, by design). If a nested Emphasis/Strong/etc. still
            // pushed an `inline_stack` frame here, its matching `End` would
            // pop an empty frame and leak a stray empty span into the
            // *enclosing* paragraph once the image itself closes — the
            // frame must simply not open at all during this window.
            Tag::Emphasis if !self.in_image => {
                self.inline_stack.push((InlineKind::Emph, Vec::new()));
            }
            Tag::Strong if !self.in_image => {
                self.inline_stack.push((InlineKind::Strong, Vec::new()));
            }
            Tag::Strikethrough if !self.in_image => {
                self.inline_stack.push((InlineKind::Strike, Vec::new()));
            }
            Tag::Link { dest_url, .. } if !self.in_image => {
                self.inline_stack
                    .push((InlineKind::Link(dest_url.to_string()), Vec::new()));
            }
            Tag::Image { dest_url, .. } => {
                self.in_image = true;
                self.image_alt.clear();
                self.image_url = dest_url.to_string();
            }
            _ => {}
        }
    }

    fn end(&mut self, tag_end: TagEnd) {
        match tag_end {
            TagEnd::Paragraph => {
                let spans = self.root_spans.pop().unwrap_or_default();
                self.push_block(MdBlock::Paragraph { spans });
            }
            TagEnd::Heading(_) => {
                let level = self.heading_level.take().unwrap_or(1);
                let spans = self.root_spans.pop().unwrap_or_default();
                self.push_block(MdBlock::Heading { level, spans });
            }
            TagEnd::CodeBlock => {
                self.in_code_block = false;
                let lang = self.code_lang.take();
                let text = std::mem::take(&mut self.code_buf);
                self.push_block(MdBlock::CodeBlock { lang, text });
            }
            TagEnd::Item => {
                // A "tight" list (the common case — no blank lines between
                // items) never gets an explicit Paragraph start/end around
                // its item text at all; flush whatever `push_span` opened
                // implicitly before this item's block frame is popped, or
                // the item's own text is lost.
                self.flush_implicit_paragraph();
                let item_blocks = self.blocks.pop().unwrap_or_default();
                if let Some(list) = self.lists.last_mut() {
                    list.items.push(item_blocks);
                }
            }
            TagEnd::List(_) => {
                self.flush_implicit_paragraph();
                if let Some(list) = self.lists.pop() {
                    self.push_block(MdBlock::List {
                        ordered: list.ordered,
                        start: list.start,
                        items: list.items,
                    });
                }
            }
            TagEnd::BlockQuote(_) => {
                self.flush_implicit_paragraph();
                let inner = self.blocks.pop().unwrap_or_default();
                self.push_block(MdBlock::Quote { blocks: inner });
            }
            TagEnd::Table => {
                if let Some(t) = self.tables.pop() {
                    self.push_block(MdBlock::Table {
                        header: t.header,
                        rows: t.rows,
                    });
                }
            }
            TagEnd::TableHead => {
                if let Some(t) = self.tables.last_mut() {
                    t.in_head = false;
                    t.header = std::mem::take(&mut t.current_row);
                }
            }
            TagEnd::TableRow => {
                if let Some(t) = self.tables.last_mut() {
                    let row = std::mem::take(&mut t.current_row);
                    // `TableHead`'s own `End` (above) already promoted the
                    // header row out of `current_row`, so a row that reaches
                    // here is always a body row.
                    t.rows.push(row);
                }
            }
            TagEnd::TableCell => {
                let spans = self.root_spans.pop().unwrap_or_default();
                if let Some(t) = self.tables.last_mut() {
                    t.current_row.push(spans);
                }
            }
            // Whichever nested-inline-span level this closes, the pop/wrap/
            // re-attach logic is the same — `close_inline` reads the kind off
            // the stack itself.
            //
            // Guarded by `!self.in_image`, mirroring the matching `Start`
            // arms: an Emphasis/Strong/Strikethrough/Link *inside* an image's
            // alt text never pushed an `inline_stack` frame in the first
            // place (the `Start` guard skips it — see that comment), so
            // firing `close_inline()` here unconditionally would pop
            // whatever frame actually *is* on top: the real, enclosing
            // Strong/Emphasis/etc. that was legitimately opened before the
            // image started. `"**bold ![*alt*](url) more**"` closed the
            // outer `Strong` the instant the inner `Emphasis` inside the alt
            // text ended, splitting "more" out of the bold run instead of
            // keeping it inside.
            TagEnd::Emphasis | TagEnd::Strong | TagEnd::Strikethrough | TagEnd::Link
                if !self.in_image =>
            {
                self.close_inline()
            }
            TagEnd::Image => {
                self.in_image = false;
                let alt = std::mem::take(&mut self.image_alt).trim().to_string();
                let url = std::mem::take(&mut self.image_url);
                self.push_span(MdSpan::Image { alt, url });
            }
            _ => {}
        }
    }

    fn text(&mut self, s: &str) {
        if self.in_code_block {
            self.code_buf.push_str(s);
            return;
        }
        if self.in_image {
            self.image_alt.push_str(s);
            return;
        }
        self.push_span(MdSpan::Text {
            text: s.to_string(),
        });
    }

    fn inline_code(&mut self, s: &str) {
        if self.in_image {
            self.image_alt.push_str(s);
            return;
        }
        self.push_span(MdSpan::Code {
            text: s.to_string(),
        });
    }

    /// HTML — block-level (`Event::Html`) or inline (`Event::InlineHtml`) — is
    /// passed through as literal text rather than interpreted, matching the
    /// plan's "HTML blocks (passed through as text)" requirement.
    fn html(&mut self, s: &str) {
        if self.in_code_block {
            self.code_buf.push_str(s);
            return;
        }
        if self.in_image {
            self.image_alt.push_str(s);
            return;
        }
        if !self.root_spans.is_empty() || !self.inline_stack.is_empty() {
            self.push_span(MdSpan::Text {
                text: s.to_string(),
            });
        } else {
            // A standalone HTML block with no enclosing paragraph — wrap it
            // as its own paragraph so it isn't silently dropped.
            self.push_block(MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: s.to_string(),
                }],
            });
        }
    }

    fn soft_break(&mut self) {
        if self.in_code_block {
            self.code_buf.push('\n');
        } else if self.in_image {
            self.image_alt.push(' ');
        } else {
            self.push_span(MdSpan::Text {
                text: " ".to_string(),
            });
        }
    }

    fn hard_break(&mut self) {
        if self.in_code_block {
            self.code_buf.push('\n');
        } else {
            self.push_span(MdSpan::Text {
                text: "\n".to_string(),
            });
        }
    }

    fn rule(&mut self) {
        self.push_block(MdBlock::Rule);
    }

    fn task_marker(&mut self, checked: bool) {
        let text = if checked { "[x] " } else { "[ ] " }.to_string();
        self.push_span(MdSpan::Text { text });
    }

    // ── shared helpers ──────────────────────────────────────────────────────

    /// Pop the innermost open nested-inline-span level, wrap its accumulated
    /// children per its kind, and push the result into whatever is now the
    /// new innermost open span level (an outer inline span, or the
    /// paragraph/heading/cell `root_spans` level beneath it).
    fn close_inline(&mut self) {
        let Some((kind, spans)) = self.inline_stack.pop() else {
            return;
        };
        let wrapped = match kind {
            InlineKind::Emph => MdSpan::Emph { spans },
            InlineKind::Strong => MdSpan::Strong { spans },
            InlineKind::Strike => MdSpan::Strike { spans },
            InlineKind::Link(url) => MdSpan::Link { spans, url },
        };
        self.push_span(wrapped);
    }

    /// Append `span` to whatever inline level is currently open: the
    /// innermost nested span if one is open, else the current
    /// paragraph/heading/cell `root_spans` level.
    ///
    /// When neither is open — the tight-list-item case `root_span_is_implicit`
    /// documents — a fresh `root_spans` level is opened implicitly so the
    /// span has somewhere to land; [`flush_implicit_paragraph`] folds it into
    /// a real `Paragraph` block at the next block boundary.
    fn push_span(&mut self, span: MdSpan) {
        if let Some((_, spans)) = self.inline_stack.last_mut() {
            spans.push(span);
            return;
        }
        if self.root_spans.is_empty() {
            self.root_spans.push(Vec::new());
            self.root_span_is_implicit = true;
        }
        self.root_spans.last_mut().unwrap().push(span);
    }

    /// Fold an implicitly-opened `root_spans` level (see
    /// `root_span_is_implicit`) into a real `Paragraph` block appended to the
    /// current block-accumulation level, if one is open. A no-op when the
    /// open `root_spans` level (if any) was opened explicitly by a real
    /// `Paragraph`/`Heading`/`TableCell` tag — those are already flushed by
    /// their own `End` handler.
    fn flush_implicit_paragraph(&mut self) {
        if !self.root_span_is_implicit {
            return;
        }
        self.root_span_is_implicit = false;
        if let Some(spans) = self.root_spans.pop() {
            if !spans.is_empty() {
                self.push_block(MdBlock::Paragraph { spans });
            }
        }
    }

    /// Append `block` to whatever the innermost open block-accumulation
    /// level is: the root document, an open blockquote, or an open list item.
    fn push_block(&mut self, block: MdBlock) {
        if let Some(top) = self.blocks.last_mut() {
            top.push(block);
        }
    }
}

fn heading_level_u8(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── 1. fenced code blocks ────────────────────────────────────────────────

    #[test]
    fn a_fenced_code_block_with_a_language_tag_produces_lang_some() {
        let md = "```rust\nfn main() {}\n```\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::CodeBlock {
                lang: Some("rust".to_string()),
                text: "fn main() {}\n".to_string(),
            }]
        );
    }

    #[test]
    fn a_fenced_code_block_with_no_language_tag_produces_lang_none() {
        let md = "```\nfn main() {}\n```\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::CodeBlock {
                lang: None,
                text: "fn main() {}\n".to_string(),
            }]
        );
    }

    #[test]
    fn code_block_text_is_byte_for_byte_identical_to_the_source_apart_from_fence_lines() {
        // Leading/trailing blank lines and internal indentation inside the
        // fence must survive untouched — no trimming beyond the fence markers.
        let md = "```python\n\n    def f():\n        pass\n\n```\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::CodeBlock { text, .. } => {
                assert_eq!(text, "\n    def f():\n        pass\n\n");
            }
            other => panic!("expected CodeBlock, got {other:?}"),
        }
    }

    #[test]
    fn an_unclosed_fence_at_eof_still_produces_a_code_block_with_the_trailing_content() {
        // No closing ``` at all — pulldown-cmark auto-closes at EOF, and the
        // walk must not panic or drop the tail.
        let md = "```rust\nfn f() {\n    body();\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::CodeBlock {
                lang: Some("rust".to_string()),
                text: "fn f() {\n    body();\n".to_string(),
            }]
        );
    }

    #[test]
    fn a_fenced_code_block_indented_inside_a_list_item_produces_a_dedented_code_block_nested_in_the_item(
    ) {
        let md = "- item one\n  ```rust\n  fn f() {}\n  ```\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List { items, .. } => {
                assert_eq!(items.len(), 1);
                let code = items[0].iter().find_map(|b| match b {
                    MdBlock::CodeBlock { lang, text } => Some((lang.clone(), text.clone())),
                    _ => None,
                });
                assert_eq!(
                    code,
                    Some((Some("rust".to_string()), "fn f() {}\n".to_string())),
                    "the nested fence must be dedented to exactly its own content, item blocks: {:?}",
                    items[0]
                );
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    // ── 2. list structure ────────────────────────────────────────────────────

    #[test]
    fn nested_lists_round_trip_their_items_structure() {
        // Blank lines throughout so every level is "loose" (CommonMark wraps
        // item text in a Paragraph) rather than tight — see the tight-list bug
        // noted in the test report; this test is about nesting depth/item
        // count, not that bug.
        let md = "- outer\n\n  - inner one\n\n  - inner two\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List { ordered, items, .. } => {
                assert!(!ordered);
                assert_eq!(items.len(), 1, "one outer item");
                let outer_item = &items[0];
                assert!(
                    matches!(&outer_item[0], MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "outer".into() }])
                );
                match &outer_item[1] {
                    MdBlock::List {
                        ordered: inner_ordered,
                        items: inner_items,
                        ..
                    } => {
                        assert!(!inner_ordered);
                        assert_eq!(inner_items.len(), 2, "two inner items");
                        assert!(matches!(
                            &inner_items[0][0],
                            MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "inner one".into() }]
                        ));
                        assert!(matches!(
                            &inner_items[1][0],
                            MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "inner two".into() }]
                        ));
                    }
                    other => panic!("expected nested List, got {other:?}"),
                }
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    #[test]
    fn a_tight_nested_list_with_no_blank_lines_keeps_the_outer_items_own_text() {
        // The bug the test above deliberately sidesteps (see its own comment):
        // no blank line between the outer item's text and the nested list, so
        // the whole thing is "tight" and the outer item's text is an implicit
        // paragraph in root_spans, not yet flushed when the nested List's
        // Start tag fires. Before the fix, the outer item's "outer" text and
        // the nested list's first item's "inner one" landed in the same
        // still-open accumulator and came out merged onto the *inner* item,
        // with the outer item left holding nothing.
        let md = "- outer\n  - inner one\n  - inner two\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List { ordered, items, .. } => {
                assert!(!ordered);
                assert_eq!(items.len(), 1, "one outer item");
                let outer_item = &items[0];
                assert_eq!(
                    outer_item.len(),
                    2,
                    "the outer item must hold its own paragraph *and* the nested list, \
                     not just the nested list with the outer text merged into it: {outer_item:?}"
                );
                assert!(
                    matches!(&outer_item[0], MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "outer".into() }]),
                    "the outer item's own text must survive as its own paragraph, not be \
                     merged into the nested list's first item: {:?}",
                    outer_item[0]
                );
                match &outer_item[1] {
                    MdBlock::List {
                        ordered: inner_ordered,
                        items: inner_items,
                        ..
                    } => {
                        assert!(!inner_ordered);
                        assert_eq!(inner_items.len(), 2, "two inner items");
                        assert!(matches!(
                            &inner_items[0][0],
                            MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "inner one".into() }]
                        ));
                        assert!(matches!(
                            &inner_items[1][0],
                            MdBlock::Paragraph { spans } if spans == &vec![MdSpan::Text { text: "inner two".into() }]
                        ));
                    }
                    other => panic!("expected nested List, got {other:?}"),
                }
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    #[test]
    fn strong_wrapping_an_image_with_emphasised_alt_text_does_not_close_early() {
        // Regression test: the TagEnd arm for Emphasis/Strong/Strikethrough/
        // Link used to fire unconditionally, even while `in_image` was true
        // — i.e. even for a TagEnd whose matching Start was skipped by the
        // `!self.in_image` guard because it opened *inside* an image's alt
        // text. `close_inline()` then popped whatever frame actually was on
        // top of `inline_stack`: the real, enclosing Strong that legitimately
        // opened before the image did — closing it the instant the alt
        // text's own inner Emphasis ended, stranding the trailing " more
        // text" outside the bold run instead of inside it.
        let md = "**bold text ![*alt*](http://x.com/i.png) more text**\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::Paragraph { spans } => {
                assert_eq!(
                    spans.len(),
                    1,
                    "the whole line must be one Strong span, not split around the image: {spans:?}"
                );
                match &spans[0] {
                    MdSpan::Strong { spans: inner } => {
                        assert_eq!(
                            inner.len(),
                            3,
                            "\"bold text \", the image, and \" more text\" must all be inside \
                             the same Strong span: {inner:?}"
                        );
                        assert!(matches!(&inner[0], MdSpan::Text { text } if text == "bold text "));
                        assert!(matches!(&inner[1], MdSpan::Image { alt, .. } if alt == "alt"));
                        assert!(
                            matches!(&inner[2], MdSpan::Text { text } if text == " more text"),
                            "\" more text\" must still be inside the Strong span, not a \
                             sibling of it: {inner:?}"
                        );
                    }
                    other => panic!("expected the outer span to be Strong, got {other:?}"),
                }
            }
            other => panic!("expected a single Paragraph, got {other:?}"),
        }
    }

    #[test]
    fn an_ordered_list_starting_at_three_captures_the_start_number() {
        let md = "3. foo\n\n4. bar\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List {
                ordered,
                start,
                items,
            } => {
                assert!(ordered);
                assert_eq!(*start, Some(3));
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    // ── 3. tables ─────────────────────────────────────────────────────────────

    #[test]
    fn a_table_with_a_header_and_data_row_produces_correct_cell_spans() {
        let md = "| a | b |\n| --- | --- |\n| 1 | 2 |\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Table {
                header: vec![
                    vec![MdSpan::Text { text: "a".into() }],
                    vec![MdSpan::Text { text: "b".into() }],
                ],
                rows: vec![vec![
                    vec![MdSpan::Text { text: "1".into() }],
                    vec![MdSpan::Text { text: "2".into() }],
                ]],
            }]
        );
    }

    // ── 4. links and images ──────────────────────────────────────────────────

    #[test]
    fn a_link_produces_a_link_span_with_its_url() {
        let md = "[text](http://example.com)\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Link {
                    spans: vec![MdSpan::Text {
                        text: "text".into()
                    }],
                    url: "http://example.com".into(),
                }],
            }]
        );
    }

    #[test]
    fn an_image_produces_an_image_span_with_alt_and_url() {
        let md = "![a screenshot](http://example.com/img.png)\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Image {
                    alt: "a screenshot".into(),
                    url: "http://example.com/img.png".into(),
                }],
            }]
        );
    }

    #[test]
    fn an_image_alt_with_inline_markup_is_flattened_to_plain_text_with_no_stray_spans() {
        // The alt text uses **bold** markup in the source; the resulting
        // MdSpan::Image::alt must be the flattened plain text "alt text", and
        // the enclosing paragraph must carry nothing but the Image span — no
        // leftover inline-formatting span from the alt's markup.
        let md = "![alt **text**](http://example.com/img.png)\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Image {
                    alt: "alt text".into(),
                    url: "http://example.com/img.png".into(),
                }],
            }],
            "alt-text markup must not leak a stray span into the enclosing paragraph"
        );
    }

    // ── 5. inline nesting ─────────────────────────────────────────────────────

    #[test]
    fn emphasis_nested_inside_a_link_produces_correctly_nested_spans() {
        let md = "[*em link*](http://example.com)\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Link {
                    spans: vec![MdSpan::Emph {
                        spans: vec![MdSpan::Text {
                            text: "em link".into()
                        }],
                    }],
                    url: "http://example.com".into(),
                }],
            }]
        );
    }

    // ── 6. line breaks ────────────────────────────────────────────────────────

    #[test]
    fn a_hard_line_break_is_representable_as_a_text_span_containing_a_newline() {
        let md = "line one  \nline two\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![
                    MdSpan::Text {
                        text: "line one".into()
                    },
                    MdSpan::Text { text: "\n".into() },
                    MdSpan::Text {
                        text: "line two".into()
                    },
                ],
            }]
        );
    }

    // ── 7. HTML passthrough ───────────────────────────────────────────────────

    #[test]
    fn a_standalone_html_block_is_passed_through_as_literal_text_and_never_dropped() {
        let md = "<div>\n  hi\n</div>\n";
        let blocks = markdown_to_blocks(md);
        // Every line of the HTML block must survive somewhere as literal text
        // — never dropped, never interpreted as markdown or as a tag.
        let mut all_text = String::new();
        for b in &blocks {
            if let MdBlock::Paragraph { spans } = b {
                for s in spans {
                    if let MdSpan::Text { text } = s {
                        all_text.push_str(text);
                    }
                }
            }
        }
        assert!(all_text.contains("<div>"), "got: {blocks:?}");
        assert!(all_text.contains("hi"), "got: {blocks:?}");
        assert!(all_text.contains("</div>"), "got: {blocks:?}");
        assert!(
            !blocks.is_empty(),
            "a standalone HTML block must not be silently dropped"
        );
    }

    #[test]
    fn inline_html_inside_a_paragraph_is_passed_through_as_literal_text_within_that_paragraph() {
        let md = "Some text with <b>inline</b> html.\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![
                    MdSpan::Text {
                        text: "Some text with ".into()
                    },
                    MdSpan::Text { text: "<b>".into() },
                    MdSpan::Text {
                        text: "inline".into()
                    },
                    MdSpan::Text {
                        text: "</b>".into()
                    },
                    MdSpan::Text {
                        text: " html.".into()
                    },
                ],
            }]
        );
    }

    // ── 8. blockquotes and rules ──────────────────────────────────────────────

    #[test]
    fn a_blockquote_produces_a_quote_block_with_its_inner_paragraph_intact() {
        let md = "> quoted text\n> more\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Quote {
                blocks: vec![MdBlock::Paragraph {
                    spans: vec![
                        MdSpan::Text {
                            text: "quoted text".into()
                        },
                        MdSpan::Text { text: " ".into() },
                        MdSpan::Text {
                            text: "more".into()
                        },
                    ],
                }],
            }]
        );
    }

    #[test]
    fn a_horizontal_rule_produces_a_rule_block() {
        let md = "above\n\n---\n\nbelow\n";
        let blocks = markdown_to_blocks(md);
        assert!(blocks.contains(&MdBlock::Rule), "got: {blocks:?}");
    }

    // ── 9. plain text ─────────────────────────────────────────────────────────

    #[test]
    fn plain_text_with_no_markdown_constructs_produces_a_single_paragraph() {
        let md = "just some plain text with nothing special in it\n";
        let blocks = markdown_to_blocks(md);
        assert_eq!(
            blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "just some plain text with nothing special in it".into(),
                }],
            }]
        );
    }

    // ── 10. tight-list item text (found while testing — see test report) ────

    #[test]
    fn a_plain_tight_bullet_list_with_no_blank_lines_preserves_each_items_text() {
        // A tight list — the default, overwhelmingly common GitHub-flavoured
        // markdown style with no blank line between items — must not lose the
        // items' own text. pulldown-cmark does not wrap tight-list item text
        // in Start(Paragraph)/End(Paragraph); it emits it as a bare `Text`
        // event directly inside the `Item`. `Walker::push_span` only appends
        // to `root_spans` (populated by Paragraph/Heading/TableCell) or
        // `inline_stack` — neither is open for a bare tight-list item, so the
        // text is silently dropped by the "neither open" fallback.
        let md = "- item one\n- item two\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List { items, .. } => {
                assert_eq!(items.len(), 2);
                assert!(
                    !items[0].is_empty(),
                    "first tight list item's text must not be dropped, got: {items:?}"
                );
                assert!(
                    !items[1].is_empty(),
                    "second tight list item's text must not be dropped, got: {items:?}"
                );
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    #[test]
    fn a_tight_list_items_own_text_survives_alongside_a_nested_code_block() {
        // The exact shape the plan's AC describes ("a fenced code block
        // indented inside a list item"), written the way a PR review comment
        // naturally would be — no blank line before the fence. The item's own
        // label text must survive next to the nested CodeBlock, not just the
        // CodeBlock alone.
        let md = "- item one\n  ```rust\n  fn f() {}\n  ```\n";
        let blocks = markdown_to_blocks(md);
        match &blocks[0] {
            MdBlock::List { items, .. } => {
                let has_text = items[0].iter().any(|b| {
                    matches!(b, MdBlock::Paragraph { spans } if spans.iter().any(|s| matches!(s, MdSpan::Text { text } if text.contains("item one"))))
                });
                assert!(
                    has_text,
                    "the list item's own text (\"item one\") must survive alongside its nested code block, got: {items:?}"
                );
            }
            other => panic!("expected List, got {other:?}"),
        }
    }
}
