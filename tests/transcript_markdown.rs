//! Render-fixture tests for the markdown → ratatui renderer.
//!
//! Each test renders a markdown snippet at width=80, serialises the resulting
//! lines to plain text (spans joined, no ANSI), and asserts against an
//! expected string defined inline.
//!
//! One test also verifies the syntect path by asserting that a Rust fenced
//! code block produces more than one distinct foreground colour.

use nostromo::ui::widgets::{markdown::render_markdown, syntect_cache::SyntectCache};
use std::collections::HashSet;

fn sc() -> SyntectCache {
    SyntectCache::load().expect("syntect loads")
}

/// Serialise lines to a `Vec<String>` by joining each line's spans.
fn line_text(lines: &[ratatui::text::Line]) -> Vec<String> {
    lines
        .iter()
        .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect::<String>())
        .collect()
}

// ── Headings + paragraphs ────────────────────────────────────────────────────

#[test]
fn headings_and_paragraphs() {
    let src = "# Title\n\nSome paragraph text here.\n\n## Section\n\nAnother paragraph.";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // H1 and H2 should appear as their own lines.
    assert!(
        text.iter().any(|l| l.contains("Title")),
        "H1 missing; got: {:?}",
        text
    );
    assert!(
        text.iter().any(|l| l.contains("Section")),
        "H2 missing; got: {:?}",
        text
    );
    assert!(
        text.iter().any(|l| l.contains("paragraph text")),
        "paragraph text missing; got: {:?}",
        text
    );
}

// ── Nested lists ─────────────────────────────────────────────────────────────

#[test]
fn nested_bullet_list() {
    let src = "- item one\n- item two\n  - nested\n- item three\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    assert!(
        text.iter().any(|l| l.contains("item one")),
        "item one missing; got: {:?}",
        text
    );
    assert!(
        text.iter().any(|l| l.contains("nested")),
        "nested item missing; got: {:?}",
        text
    );
    // Nested item should have more leading whitespace than top-level items.
    let nested_line = text.iter().find(|l| l.contains("nested")).unwrap();
    let top_line = text.iter().find(|l| l.contains("item one")).unwrap();
    assert!(
        nested_line.len() > top_line.len() || nested_line.starts_with(' ') || nested_line.starts_with("  "),
        "nested item not visually indented; nested={:?} top={:?}",
        nested_line,
        top_line
    );
}

#[test]
fn ordered_list() {
    let src = "1. first\n2. second\n3. third\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    assert!(text.iter().any(|l| l.contains("first")), "first missing; got: {:?}", text);
    assert!(text.iter().any(|l| l.contains("second")), "second missing; got: {:?}", text);
    assert!(text.iter().any(|l| l.contains("1.")), "1. marker missing; got: {:?}", text);
}

// ── Fenced code block (Rust) ─────────────────────────────────────────────────

#[test]
fn rust_code_block_text() {
    let src = "```rust\nfn add(a: i32, b: i32) -> i32 {\n    a + b\n}\n```";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // The function signature should appear in the text.
    assert!(
        text.iter().any(|l| l.contains("fn add")),
        "fn add not found; got: {:?}",
        text
    );
}

#[test]
fn rust_code_block_has_multiple_styles() {
    // Core acceptance criterion: syntect produces >1 distinct style.
    let src = "```rust\nfn hello(name: &str) -> String {\n    format!(\"Hello, {}!\", name)\n}\n```";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);

    // Collect all distinct foreground colours present in the output.
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

// ── Table ─────────────────────────────────────────────────────────────────────

#[test]
fn table_3x3() {
    let src = "| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // Headers and cells should appear.
    assert!(text.iter().any(|l| l.contains('A')), "col A missing; got: {:?}", text);
    assert!(text.iter().any(|l| l.contains('1')), "cell 1 missing; got: {:?}", text);
    assert!(text.iter().any(|l| l.contains('6')), "cell 6 missing; got: {:?}", text);

    // At width=80, the natural table fits so box-drawing chars should appear.
    let has_box = text.iter().any(|l| l.contains('┌') || l.contains('│'));
    assert!(has_box, "expected unicode box-drawing at width=80; got: {:?}", text);
}

#[test]
fn table_fallback_narrow_width() {
    // At very narrow width the ASCII pipe fallback should kick in.
    let src = "| Column A | Column B | Column C |\n|----------|----------|----------|\n| data 1   | data 2   | data 3   |\n";
    let sc = sc();
    // Width of 20 is way narrower than the natural table width (~36+).
    let lines = render_markdown(src, &sc, 20);
    let text = line_text(&lines);

    assert!(text.iter().any(|l| l.contains("Column A")), "header missing in fallback; got: {:?}", text);
}

// ── Block quote with emphasis ─────────────────────────────────────────────────

#[test]
fn blockquote_with_emphasis() {
    let src = "> This is *important* text\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // The blockquote prefix character should appear.
    assert!(
        text.iter().any(|l| l.contains("▎")),
        "blockquote prefix ▎ missing; got: {:?}",
        text
    );
    // The text content should be present.
    assert!(
        text.iter().any(|l| l.contains("important")),
        "blockquote text missing; got: {:?}",
        text
    );
}

// ── Links ─────────────────────────────────────────────────────────────────────

#[test]
fn link_renders_text_and_url() {
    let src = "See [the docs](https://example.com) for more.";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // Link text should appear.
    assert!(
        text.iter().any(|l| l.contains("the docs")),
        "link text missing; got: {:?}",
        text
    );
    // URL should appear in the ⟨url⟩ annotation.
    assert!(
        text.iter().any(|l| l.contains("example.com")),
        "link url missing; got: {:?}",
        text
    );
}

// ── Horizontal rule ──────────────────────────────────────────────────────────

#[test]
fn horizontal_rule() {
    let src = "Before\n\n---\n\nAfter\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    // The ─ rule line should appear somewhere.
    assert!(
        text.iter().any(|l| l.contains('─')),
        "horizontal rule ─ missing; got: {:?}",
        text
    );
}

// ── Task list ─────────────────────────────────────────────────────────────────

#[test]
fn task_list_markers() {
    let src = "- [x] done\n- [ ] todo\n";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    assert!(
        text.iter().any(|l| l.contains("[x]")),
        "checked marker missing; got: {:?}",
        text
    );
    assert!(
        text.iter().any(|l| l.contains("[ ]")),
        "unchecked marker missing; got: {:?}",
        text
    );
}

// ── Inline code ──────────────────────────────────────────────────────────────

#[test]
fn inline_code_preserved() {
    let src = "Use `cargo build` to compile.";
    let sc = sc();
    let lines = render_markdown(src, &sc, 80);
    let text = line_text(&lines);

    assert!(
        text.iter().any(|l| l.contains("cargo build")),
        "inline code text missing; got: {:?}",
        text
    );

    // Inline code should have a distinct style from regular text.
    let inline_span_styles: HashSet<_> = lines
        .iter()
        .flat_map(|l| l.spans.iter())
        .filter(|s| s.content.contains("cargo build"))
        .map(|s| s.style.fg)
        .collect();

    // Regular text uses FG; inline code uses a different colour.
    let normal_fg = ratatui::style::Color::Rgb(220, 220, 220);
    assert!(
        !inline_span_styles.iter().all(|c| *c == Some(normal_fg)),
        "inline code should use a distinct fg colour; styles: {:?}",
        inline_span_styles
    );
}

// ── Cache invalidation ────────────────────────────────────────────────────────

#[test]
fn cache_does_not_recompute_on_same_snapshot() {
    use nostromo::transcript::snapshot::{TranscriptEntry, TranscriptSnapshot};
    use nostromo::ui::widgets::transcript::TranscriptWidget;
    use ratatui::{buffer::Buffer, layout::Rect, widgets::Widget};
    use std::collections::HashMap;
    use std::path::PathBuf;
    use std::sync::Arc;

    let sc = sc();
    let snap = TranscriptSnapshot {
        entries: Arc::new(vec![TranscriptEntry::AssistantText(
            "Hello **world**!".to_string(),
        )]),
        path: PathBuf::from("/tmp/test.jsonl"),
        session_id: "test-sid".to_string(),
    };

    let mut cache: HashMap<usize, Vec<ratatui::text::Line<'static>>> = HashMap::new();
    let width = 80u16;
    let area = Rect::new(0, 0, 82, 20);

    // First render: fills cache.
    {
        let mut buf = Buffer::empty(area);
        TranscriptWidget::new(&snap, 0, &sc, &mut cache, width).render(area, &mut buf);
    }
    assert_eq!(cache.len(), 1, "cache should have 1 entry after first render");

    // Second render: should NOT add new entries (count stays the same).
    let cache_len_before = cache.len();
    {
        let mut buf = Buffer::empty(area);
        TranscriptWidget::new(&snap, 0, &sc, &mut cache, width).render(area, &mut buf);
    }
    assert_eq!(
        cache.len(),
        cache_len_before,
        "cache should not grow on re-render of same snapshot"
    );
}
