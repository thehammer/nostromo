# Transcript pane phase 2 — markdown rendering with syntect-highlighted code blocks

## Context

Phase 1 (`docs/transcript-pane-phase1.md`) shipped a text-only
`TranscriptWidget` in Perri that tails Claude Code's JSONL session log and
displays user/assistant/tool entries with prefix-coded plain text. Markdown in
assistant messages currently shows as raw source (`**bold**`, fenced code
blocks unstyled, tables as ASCII pipes).

Phase 2 swaps the plain-text renderer for a real markdown pipeline using
`pulldown-cmark` for parsing and the existing `syntect` infrastructure
(`src/ui/widgets/syntect_cache.rs`, `src/ui/widgets/syntect_diff.rs`) for code
fences. The output is a `Vec<Line<'static>>` per assistant text block, cached
per entry so we don't reparse on every frame.

This phase touches only the renderer; the reader, snapshot types, session-id
plumbing, and view integration from phase 1 remain unchanged.

## Target
- **Repo:** nostromo
- **Branch:** feat/transcript-pane-phase2
- **Base:** origin/main (after phase 1 lands)

## Files to change

- `Cargo.toml` — add `pulldown-cmark = { version = "0.12", default-features = false }`
  (no html feature; we only need the parser). Verify the chosen version compiles
  against the existing `syntect = "5"` and Rust edition 2021.
- `src/ui/widgets/markdown.rs` — **new**. The markdown→ratatui renderer.
- `src/ui/widgets/transcript.rs` — replace the plain-text rendering path for
  `AssistantText` entries with the new markdown renderer. Keep user/tool/result
  rendering as plain text.
- `src/ui/widgets/mod.rs` — `pub mod markdown;` and re-export.
- `src/transcript/snapshot.rs` — add `pub struct RenderedEntry { pub lines:
  Vec<Line<'static>>, pub source_hash: u64 }` is **not** added here; rendering
  cache lives on the widget, not the snapshot. (Stated explicitly to prevent
  drift.) No changes to the public snapshot types.
- `src/views/perri.rs` — pass an `Arc<SyntectCache>` to the `TranscriptWidget`
  constructor (Perri already holds one for the diff pane). No other view-level
  changes.
- `tests/snapshots/transcript_markdown/*.txt` — **new** ratatui snapshot
  fixtures (use `insta` if already a dep; otherwise plain `assert_eq!` against
  serialized line text — check what `tests/snapshots/` currently uses and match
  it).
- `tests/transcript_markdown.rs` — **new**. Render-fixture tests.

## Approach

1. **Add `pulldown-cmark` dependency.** Use the latest 0.12.x. Confirm no
   feature flags are needed beyond defaults-off + `simd` if available. Run
   `cargo build` to confirm clean compile.

2. **Build the markdown renderer.** `src/ui/widgets/markdown.rs`:
   - `pub fn render_markdown(src: &str, syntect: &SyntectCache, width: u16) -> Vec<Line<'static>>`
   - Use `pulldown_cmark::Parser::new_ext(src, Options::ENABLE_TABLES |
     Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS |
     Options::ENABLE_FOOTNOTES)`.
   - Walk events, maintain a small state machine:
     - `Heading(level)` → bold + colour by level (H1 amber, H2 sage, H3+
       default-bold). Append a blank line after.
     - `Paragraph` → accumulate spans; flush as a `Line` on End.
     - `Emphasis` / `Strong` → push/pop a `Style` modifier stack.
     - `Code` (inline) → render with `theme::style_code_inline()` (define if
       not present; muted bg or distinct fg).
     - `CodeBlock(Fenced(info))` → buffer until End, then call
       `syntect.highlight_block(&buf, &info_string)` returning `Vec<Line<'static>>`
       and inline those (preserve the existing `SyntectCache` API; see
       `src/ui/widgets/syntect_diff.rs` for the call shape). If language is
       unknown, render with a fixed dim style and a left bar (`│ `).
     - `List(None)` (bullet) → prefix each item with `• ` indented by depth*2.
     - `List(Some(start))` (ordered) → numeric prefix `1. ` etc.
     - `BlockQuote` → prefix each line with `▎ ` in muted style.
     - `Rule` → render a horizontal `─` line spanning the width.
     - `Table` → use a small inline layout: collect rows, compute per-column
       max widths, render with unicode box-drawing characters. If the natural
       width exceeds `width`, fall back to ASCII pipes and let the outer wrap
       handle it.
     - `Link { dest_url, .. }` → render the inner text in
       `theme::style_link()` and append ` ⟨<url>⟩` dimmed.
     - `Image { .. }` → render `[image: <alt>]` placeholder.
     - `TaskListMarker(true|false)` → `[x] ` / `[ ] `.
   - Hard-wrap at `width` columns using `textwrap` (already an indirect dep
     via ratatui? if not, add `textwrap = "0.16"`) or implement a simple
     UAX-29-naïve word wrap inline. Confirm: code blocks are **not** wrapped
     (long lines scroll horizontally — phase 3 may add a horizontal scroll;
     phase 2 just truncates with `…`).
   - Return `Vec<Line<'static>>`. All spans owned (use `.to_string().into()`)
     to satisfy the `'static` bound; this is necessary because the widget
     caches them across frames.

3. **Add a per-entry render cache to `TranscriptWidget`.**
   - The widget is constructed each frame in `render_repl`; the cache must
     live longer. Move it onto `PerriView` as
     `transcript_cache: HashMap<usize, Vec<Line<'static>>>` keyed by entry
     index, invalidated when the snapshot's `entries.len()` shrinks (never
     happens — JSONL is append-only) or when `repl_area.width` changes.
   - Cache invalidation rule: if `width != last_width`, drop the cache.
   - Pass `&mut transcript_cache` and the width into the widget at render
     time. The widget renders cached lines for every `i < entries.len()` and
     fills in misses by calling `render_markdown(text, syntect, width)`.

4. **Update the widget render loop.**
   - For each entry, compute its visible lines:
     - `UserMessage(t)` → one prefix line `▸ ` + wrap the body at width-2
       in `theme::style_user()`.
     - `AssistantText(md)` → cache lookup or `render_markdown`.
     - `Thinking(t)` → dim italic, prefix `· `. (Toggle lands in phase 3.)
     - `ToolUse { name, input }` → one line, unchanged from phase 1.
     - `ToolResult { content, .. }` → muted, prefix `↳ `, truncate at 120
       chars (folding lands in phase 3).
     - `TurnEnd` → render a `─` separator.
   - Concatenate, apply `scroll`, render via `Paragraph::new(lines)` with
     `wrap: None` (we pre-wrapped).

5. **Snapshot tests.**
   - `tests/transcript_markdown.rs`:
     - Fixture inputs: headings + paragraphs; nested lists; a Rust fenced
       code block; a table with 3×3 cells; a blockquote containing emphasis;
       a link.
     - Render at fixed width=80. Serialize lines to `Vec<String>` by joining
       each line's span content. Compare against expected text in
       `tests/snapshots/transcript_markdown/*.txt`. Use exact-match assertions.
     - One test verifies the syntect path: render a ```rust fenced block,
       assert that more than one distinct style appears in the output lines
       (proxy for "highlighting happened").
   - Inline unit tests in `markdown.rs` for the wrapper (input string,
     expected line count at width 40).

6. **Manual verification checklist.**
   - In Perri, paste a markdown-heavy assistant response into the transcript
     and confirm headings, lists, code fences, tables, and links render with
     distinct styling. The PTY view continues to render the raw TUI in parallel.

## Acceptance criteria

- `cargo test --all` passes, including the new markdown snapshot tests.
- `cargo clippy --all-targets -- -D warnings` passes.
- `Cargo.toml` shows `pulldown-cmark` added with no html feature.
- Rendering an assistant message with a Rust code fence shows visibly
  highlighted Rust (verified by snapshot test asserting >1 style).
- Tables render with unicode box-drawing characters at width ≥ natural width;
  fall back gracefully when narrower.
- Cache: switching focus away and back to Perri does not recompute markdown
  for already-seen entries (verified by `tracing::trace!` counter — log "rendered
  N new entries" once per snapshot change; the count must be 0 on pure re-render).
- Branch is `feat/transcript-pane-phase2`. PR body links this plan file.

## Out of scope

- Tool-call folding, thinking visibility toggle, selectable text (phase 3).
- Multi-view rollout (phase 4) — Perri only.
- Horizontal scrolling inside code blocks; long lines truncate with `…`.
- LaTeX / math rendering.
- Inline HTML (pulldown-cmark passes it through as raw text — that's fine).
- Re-flowing on terminal width change mid-frame (we invalidate the cache and
  re-render on next frame; no smooth animation).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Markdown-to-ratatui is fiddly state-machine work with many edge cases (nested lists, code fences inside blockquotes, tables). Worth the higher effort."
  redd:
    model: sonnet
    effort: high
    rationale: "Snapshot tests must cover the matrix of markdown constructs; missed coverage here propagates visual bugs."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass after the renderer settles."
  perri:
    model: sonnet
    effort: medium
    rationale: "Self-contained module; reviewer focuses on the renderer correctness and cache invariants."
```
