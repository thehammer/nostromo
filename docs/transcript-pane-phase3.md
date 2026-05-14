# Transcript pane phase 3 — foldable tool calls, thinking toggle, keyboard navigation

## Context

Phases 1 and 2 (`docs/transcript-pane-phase{1,2}.md`) shipped a markdown-aware
transcript pane in Perri that tails Claude Code's JSONL session log. Tool
uses currently render as a single summary line; `ToolResult` entries truncate
at 120 chars; `Thinking` entries always show (dimmed).

Phase 3 makes the pane interactive: foldable tool calls (collapsed by default,
showing tool name + first-line summary; expand to show full input JSON and
result), a thinking-block visibility toggle, and proper keyboard navigation
(`j`/`k` to move between entries, `o`/`Enter` to expand/collapse, `T` to
toggle thinking, `g`/`G` to jump, mouse-wheel scroll).

The reader and markdown renderer are unchanged. This phase introduces a
small interaction model layer on top of the snapshot.

## Target
- **Repo:** nostromo
- **Branch:** feat/transcript-pane-phase3
- **Base:** origin/main (after phase 2 lands)

## Files to change

- `src/ui/widgets/transcript.rs` — extend the widget with an interaction state
  parameter (cursor index, expanded set, thinking visibility flag) passed in
  by the host view.
- `src/transcript/snapshot.rs` — no changes to the public types. Add a helper
  `impl TranscriptSnapshot { pub fn navigable_entries(&self, show_thinking: bool)
  -> Vec<usize> }` that returns indices the cursor can land on (skip `Thinking`
  when `show_thinking=false`; skip `TurnEnd` always).
- `src/views/perri.rs` — add interaction state:
  - `transcript_cursor: usize` (index into the snapshot's `entries`).
  - `transcript_expanded: HashSet<usize>` (set of entry indices currently
    expanded; applies to `ToolUse` and `ToolResult`).
  - `transcript_show_thinking: bool` (default `false`).
  - Key handling while transcript is visible and PTY not capturing.
- `src/ui/widgets/transcript_layout.rs` — **new**. Computes per-entry line
  ranges given the snapshot + interaction state, so cursor navigation can map
  entry index → screen row and we can render a left-gutter cursor mark.
- `tests/transcript_interaction.rs` — **new** unit/integration tests covering
  navigation, expansion, and thinking toggle behaviour against a fixture
  snapshot.

## Approach

1. **Interaction state on PerriView.**
   - Add the three fields above; initialize cursor to "last entry" whenever
     the snapshot length grows (auto-follow tail). If the user has moved the
     cursor away from the last entry, **do not** snap back on append — track a
     `transcript_following: bool` that flips to `false` on any explicit
     navigation key and back to `true` when the cursor reaches the final entry
     via `G` or by scrolling to the bottom.

2. **Navigable index list.**
   - In `TranscriptSnapshot::navigable_entries`, return indices where
     `matches!(entry, UserMessage(..) | AssistantText(..) | ToolUse{..} |
     ToolResult{..} | Thinking(..) if show_thinking)`. Skip `TurnEnd`.
   - Cursor movement clamps to this list (`j` → next index, `k` → previous).

3. **Tool-call folding.**
   - Collapsed render (default):
     - `ToolUse` → `▸ ⚙ <name>  <one-line summary>` where summary is the first
       line of `serde_json::to_string_pretty(&input)` truncated at width-12.
     - `ToolResult` → `▸ ↳ <tool_use_id short>  <first 80 chars of content>`.
   - Expanded render (index in `transcript_expanded`):
     - `▾ ⚙ <name>` followed by pretty-printed JSON in a syntect-highlighted
       `json` block (reuse the phase-2 code-block path: feed the pretty JSON
       through `render_markdown` wrapped in ```json fences). Indent two
       columns.
     - For `ToolResult`, render the full content. If it looks like markdown
       (heuristic: contains `\n#` or fenced block), render via
       `render_markdown`; otherwise render as plain wrapped text.
   - The expand/collapse arrow (`▸` / `▾`) is in `theme::style_dim()`.

4. **Thinking visibility.**
   - When `transcript_show_thinking == false`, omit `Thinking` entries
     entirely from the rendered output **and** from `navigable_entries`. The
     toggle is sticky for the lifetime of the view.
   - When `true`, render `Thinking(text)` as dim italic with prefix `· `,
     wrapped at width-2. Long thinking blocks (>20 lines) collapse to first
     5 lines + a `… (N more lines, press o to expand)` hint, and join the
     `transcript_expanded` set when expanded (same key as tool folding).

5. **Keybindings (transcript visible, PTY not capturing).**
   - `j` / `Down` — cursor next.
   - `k` / `Up` — cursor prev.
   - `g` — jump to first navigable entry.
   - `G` — jump to last; sets `transcript_following = true`.
   - `o` / `Enter` — toggle `transcript_expanded.insert/remove(cursor)`.
   - `T` — toggle `transcript_show_thinking`. If turning off and the cursor
     was on a `Thinking` entry, advance to the next visible entry.
   - `PageUp` / `PageDown` — move cursor by half the pane height.
   - `Home` / `End` — synonyms for `g` / `G`.
   - Mouse wheel — moves the cursor (not just the scroll offset) so the
     selection follows the user's eye. Hovering and left-clicking on a
     `ToolUse` or `ToolResult` line toggles expansion (reuse the existing
     mouse plumbing in the views — see how `src/views/perri.rs` already
     handles `MouseEventKind::Down(Left)` for the queue).
   - All other keys fall through to the PTY when capturing resumes.

6. **Layout helper.**
   - `transcript_layout::compute(snapshot, state, width) -> LayoutPlan` where
     `LayoutPlan { lines: Vec<Line<'static>>, entry_rows: HashMap<usize,
     Range<u16>> }`. The widget uses `entry_rows[cursor]` to draw a left-gutter
     marker (`▎` in `theme::CURSOR`) and to compute auto-scroll: if the cursor
     row is outside the visible window, adjust `scroll` to bring it in.
   - The layout helper is the unit-testable core (no ratatui rendering;
     returns plain data), making the interaction tests fast.

7. **Cache update.**
   - The phase-2 `transcript_cache` is keyed on entry index; expansion changes
     the rendered output, so the cache key becomes `(entry_index,
     is_expanded)`. Use `HashMap<(usize, bool), Vec<Line<'static>>>`.
   - Invalidate on width change as before, plus on `transcript_show_thinking`
     change (clear the whole cache).

8. **Tests.**
   - `tests/transcript_interaction.rs`:
     - Build a `TranscriptSnapshot` fixture with: user, assistant-text,
       tool-use, tool-result, thinking, assistant-text, turn-end.
     - Test 1: `navigable_entries(show_thinking=false)` skips thinking and
       turn-end.
     - Test 2: cursor starts at last navigable, `k` moves back, `j` returns;
       wraps at bounds (clamp, don't wrap).
     - Test 3: `o` on tool-use index toggles membership in `expanded`; layout
       produces more lines when expanded than when collapsed.
     - Test 4: `T` flips thinking visibility; layout line count grows; cursor
       on thinking-index is preserved when toggled on, advances when off.
     - Test 5: cursor auto-scroll: with a pane height of 10 and 50 lines, set
       cursor entry whose `entry_rows[idx]` falls at row 30 → scroll adjusts to
       bring it within view.

9. **Manual verification.**
   - In Perri with a recent claude session: `Ctrl+T` opens transcript, `j`/`k`
     moves a visible cursor between entries, `o` expands a `Bash`/`Read`
     tool-use, `T` reveals thinking blocks, `G` re-engages tail-follow.

## Acceptance criteria

- `cargo test --all` passes (existing + new interaction tests).
- `cargo clippy --all-targets -- -D warnings` passes.
- Manually: cursor is visibly drawn via a left-gutter mark on the current
  entry; navigation feels responsive (<50ms per keystroke at 1000-entry
  snapshots).
- Manually: collapsed tool-use lines are one row each; expanded shows full
  pretty-printed input with json syntax highlighting via syntect.
- Manually: `T` toggles thinking blocks both visually and from the cursor's
  navigation list.
- Branch is `feat/transcript-pane-phase3`. PR body links this plan file and
  notes that phase 4 (multi-view rollout) is the next step.

## Out of scope

- Multi-view rollout (phase 4).
- Selectable text / copy-to-clipboard — defer; ratatui doesn't ship a
  selection model and this is large enough to be its own ticket.
- Search inside the transcript (`/` to filter) — defer.
- Persisting the expanded set across restarts — in-memory only.
- Animated transitions on expand/collapse.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Interaction model spans state, layout, key handling, and cache invariants. Many small correctness traps."
  redd:
    model: sonnet
    effort: high
    rationale: "Layout helper is the unit-testable core; coverage of navigation/expansion/toggle interactions matters."
  marty:
    model: sonnet
    effort: medium
    rationale: "Refactor pass to consolidate the layout helper API and any duplication with phase-2 rendering."
  perri:
    model: sonnet
    effort: medium
    rationale: "Self-contained on Perri; reviewer focuses on key-handling correctness and cache invalidation."
```
