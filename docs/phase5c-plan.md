# Nostromo Phase 5c — Split panes, command palette, sweater status colours

## Context

Phase 5c is the final workspace-replacement phase. It adds a split-pane layout system, a `Ctrl-P` command palette, and sweater-colour status indicators on the tab bar. Builds on 5a (daemon) and 5b (PTY detach/attach).

**Branch on `origin/main` after 5b has merged.**

The user ships trunk-based. 5c must land on `main` independently.

## Target

- **Repo:** nostromo (`~/Code/nostromo`)
- **Branch:** `feature/phase5c-layout-palette`
- **Base:** `origin/main` (after 5b merged)

## Files to change

**New layout system:**
- `src/layout/mod.rs` — module root.
- `src/layout/tree.rs` (~200 lines) — recursive layout tree:
  ```rust
  pub enum LayoutNode {
      Leaf { view_idx: usize },
      Split { dir: SplitDir, ratio: u16 /* 0..100 */, a: Box<LayoutNode>, b: Box<LayoutNode> },
  }
  pub enum SplitDir { Horizontal, Vertical }
  pub enum Side { A, B }   // path through tree to identify focused leaf

  impl LayoutNode {
      pub fn rects(&self, area: Rect) -> Vec<(usize, Rect)>;
      pub fn focused_view_idx(&self, focused_path: &[Side]) -> usize;
      pub fn split(&mut self, focused_path: &[Side], dir: SplitDir, new_view_idx: usize);
      pub fn close(&mut self, focused_path: &[Side]);
  }
  ```
- `src/layout/persist.rs` (~80 lines) — serde load/save to `~/.nostromo/layout.toml`. On load failure, return `LayoutNode::Leaf { view_idx: 0 }` (single-pane, today's behaviour unchanged). Schema:
  ```toml
  version = 1
  [tree]
  type = "split"
  dir  = "horizontal"
  ratio = 60
  [tree.a]
  type = "leaf"
  view = "fred"
  [tree.b]
  type = "leaf"
  view = "perri"
  ```

**App integration (`src/app.rs`):**
- `AppState` additions:
  ```rust
  pub layout: LayoutNode,
  pub focused_path: Vec<layout::Side>,
  pub palette: Option<CommandPalette>,
  pub split_mode: bool,          // false = today's single-view behaviour (default)
  pub pending_chord: Option<KeyCode>,
  pub mother_jobs: Vec<MotherJob>,
  pub perri_open_pr_count: usize,
  ```
- Render path: if `split_mode == false`, today's render call unchanged. If `split_mode == true`, walk `state.layout.rects(full_area)`, render each leaf's view into its rect. Focused leaf gets highlighted border (`theme::BORDER_ACTIVE` or Cyan). Tab bar shows focused leaf's view title + small split indicator (e.g. `[2/3]`).
- Key handling additions (in `AppEvent::Key` block, before PTY-focus guard):
  - `Ctrl-P` → open `CommandPalette::new(build_items(...))`.
  - `Ctrl-W` → set `pending_chord = Some(KeyCode::Char('w'))`.
  - If `pending_chord == Some(KeyCode::Char('w'))`, consume next key:
    - `s` → `state.layout.split(..., SplitDir::Vertical, next_view_idx)`
    - `v` → `state.layout.split(..., SplitDir::Horizontal, next_view_idx)`
    - `q` → `state.layout.close(...)`
    - `h/j/k/l` → move focus through pane tree
    - `t` → toggle `split_mode`
    - anything else → reset chord, do not consume
  - **`Ctrl-W` is reserved even when PTY is focused** — do not forward it to the child process.
  - Persist layout after every mutation via `layout::persist::save(&state.layout)`.
- Palette dispatch: `Execute(action)` → `apply_palette_action(action, &mut state, &mut views)`. Modal priority: palette key handling sits *after* existing modals (Await, BreakGlass, ConfirmCancel, ConfirmRetry).

**Command palette (`src/views/command_palette.rs`, ~220 lines):**
```rust
pub struct CommandPalette { query, cursor, items, filtered, selected }
pub struct PaletteItem { id, label, category: PaletteCategory, action: PaletteAction }
pub enum PaletteAction {
    SwitchView(&'static str),
    SpawnFredRepl,
    SpawnAgentRepl(&'static str),  // cody, claudia, kennedy
    OpenPrDiff(String),
    ApproveMotherJob(String),
    CancelMotherJob(String),
    SplitHorizontal, SplitVertical, ClosePane,
    ToggleRightPanel, ToggleSplitMode,
}
pub enum PaletteOutcome { Consumed, Dismiss, Execute(PaletteAction) }
impl CommandPalette {
    pub fn new(items: Vec<PaletteItem>) -> Self;
    pub fn on_key(&mut self, k: &KeyEvent) -> PaletteOutcome;
    pub fn render(&self, f: &mut Frame, area: Rect);
}
```
- Fuzzy match: subsequence-match scoring inline (no new crate). Score = sum of (1 / position_gap); tie-break by shorter label. Unit tests in `tests/palette_fuzzy.rs`.
- `build_items(&AppState, jobs: &[MotherJob], prs: &[PerriPr]) -> Vec<PaletteItem>` — called when palette opens. Covers all `PaletteAction` variants.
- Overlay: centred 60%-wide, 40%-tall block on top of current layout. `Block::default().borders(Borders::ALL)` with `theme::BORDER_ACTIVE`. Top row: search query. Body: filtered list with selection highlight. Esc/Ctrl-C dismisses; Enter executes.

**Sweater status colours (`src/ui/chrome.rs` or wherever tab bar renders):**
- Read `src/ui/theme.rs` first to confirm the exact constant names for amber and red.
- Per-tab colour computation:
  - **Perri tab:** `state.perri_open_pr_count`. > 5 → amber, > 10 → red.
  - **Cody + Mother tabs:** for each job in `state.mother_jobs`, compute `now - started_at`. Any job > 15 min → amber.
- Status indicators as per-tab border/background colour, not title text (must remain readable).
- Populate `state.perri_open_pr_count` from the existing `pr_rx` watch in `app::run`; add a small reader task if not already present.
- Populate `state.mother_jobs` from `AppEvent::MotherJobs`.

**Tab bar in split mode:**
- When `split_mode == true`, show focused-pane view title with highlight; non-focused panes listed dimly. All within 1 row height.

## Approach

1. Branch `feature/phase5c-layout-palette` off post-5b `origin/main`. Confirm with `git fetch origin && git log -1 origin/main`.
2. Add `src/layout/{mod,tree,persist}.rs`. Unit tests:
   - `layout_tree.rs`: `rects` for 3-pane horizontal split, L-shape, single leaf.
   - `layout_tree.rs`: `split`/`close` round-trips.
   - `layout_persist.rs`: save/load round-trip via tempfile.
3. Extend `AppState` with new fields. Initialise `split_mode = false`, `layout = Leaf { view_idx: 0 }`. Load persisted layout on startup; fall back to single-leaf default on error.
4. Implement `Ctrl-W` chord state machine in `app.rs`. Chord consumed; unmatched subsequent keys reset it. `Ctrl-W` intercepted **before** the PTY-focus guard.
5. Implement split-mode render in `app.rs::run`. Each leaf rendered into its rect; views already use ratio-based layout so they should adapt to smaller areas.
6. Implement `CommandPalette` in `src/views/command_palette.rs`. Wire `Ctrl-P` in `app.rs`.
7. Implement `build_items` covering all `PaletteAction` variants. Wire `apply_palette_action`.
8. Add sweater-status logic to tab-bar rendering. Confirm colour constant names by reading `src/ui/theme.rs` before writing.
9. Audit `Ctrl-W`-vs-PTY-focus: confirm `Ctrl-W` is not forwarded to child process when PTY is focused. Fix if needed (add `Ctrl-W` to the reserved-keys list intercepted before the PTY key-forward path).
10. Manual test:
    - `Ctrl-W t` → enable split mode. Single leaf renders sanely.
    - `Ctrl-W s` → vertical split. Both panes render. `~/.nostromo/layout.toml` written. Restart nostromo — layout restored.
    - `Ctrl-P` → palette. Type "fre" → "Switch to Fred" appears. Enter switches.
    - Perri with >5 open PRs → Perri tab amber.
    - Mother job running >15 min → Mother/Cody tab amber.
11. Update `README.md`: layout chord cheatsheet + palette keybinding.
12. Open PR titled `feat(phase5c): split panes, command palette, sweater status colours`.

## Acceptance criteria

- `cargo test` passes including new layout tree, persist, and palette fuzzy tests.
- `Ctrl-W t` toggles split mode; `Ctrl-W s`/`v` create splits; `Ctrl-W q` closes pane; `Ctrl-W h/j/k/l` moves focus.
- Layout persisted to `~/.nostromo/layout.toml` after every mutation; restored on startup.
- Default behaviour (no user action): single-pane, single view, identical to current `main`.
- `Ctrl-P` opens palette; fuzzy search works; Enter executes; Esc dismisses.
- Perri tab amber when open PR count > 5, red when > 10.
- Cody and Mother tabs amber when any job running > 15 minutes.
- `Ctrl-W` chord honoured even when PTY view is focused (not forwarded to child process).
- Active-pane focus indicator visible in tab bar in split mode.
- PR body references this plan and includes "Phase 5c of nostromo workspace replacement".

## Out of scope

- Drag-to-resize panes with mouse. Splits are 50/50 by default.
- Floating windows / picture-in-picture.
- Per-pane scrollback search.
- Custom palette item plugins / external command registration.
- Sweater-colour threshold customisation (thresholds are constants).
- Removing existing `Tab`/`BackTab` view cycling — keep both navigation models.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Self-contained UI feature work — layout tree, palette overlay, status colours. New code, mostly additive; no daemon ownership shifts."
  marty:
    model: sonnet
    effort: low
    rationale: "downgrade: mostly new modules; little existing code to consolidate. Light pass to confirm theme constants are reused, not redefined."
  perri:
    model: sonnet
    effort: medium
    rationale: "Reviewer should check Ctrl-W-vs-PTY-focus interaction and palette modal priority ordering vs existing modals."
  redd:
    skip: true
    rationale: "No TUI test harness; layout/palette unit tests added inline. Skipping per user direction."
```
