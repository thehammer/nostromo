# Transcript pane phase 4 — roll transcript pane out to Fred, Mother, Teri, and the generic agent view (Claudia/Cody/Kennedy)

## Context

Phases 1–3 (`docs/transcript-pane-phase{1,2,3}.md`) built the transcript pane
in Perri only: session-id pinning, JSONL tailing, markdown rendering, tool
folding, thinking toggle, keyboard navigation. The reader and widget are
self-contained and view-agnostic.

Phase 4 rolls the same pane out to every REPL-bearing view: Fred
(`src/views/fred.rs`), Mother (`src/views/mother.rs`), Teri
(`src/views/teri.rs`), and the generic agent view
(`src/views/agent_generic.rs`) used by Claudia, Cody, and Kennedy. Each view
already follows the same pattern as Perri: a PTY field, a `try_reattach`
helper, an Enter-to-spawn handler, and a `SessionStore::record` call. We
extract the transcript wiring into a small mixin-style helper to avoid
copy-paste across six views.

## Target
- **Repo:** nostromo
- **Branch:** feat/transcript-pane-phase4
- **Base:** origin/main (after phase 3 lands)

## Files to change

- `src/transcript/integration.rs` — **new**. View-side helper that owns the
  `TranscriptReader`, `watch::Receiver<TranscriptSnapshot>`, interaction
  state, and render cache. Exposes:
  - `pub struct TranscriptPane { ... }` with `pub fn new() -> Self` (no
    args; lazy bring-up).
  - `pub fn bring_up(&mut self, cwd: PathBuf, session_id: String)` — start
    the reader.
  - `pub fn tear_down(&mut self)` — drop reader on PTY exit.
  - `pub fn toggle_visible(&mut self)` / `pub fn is_visible(&self) -> bool`.
  - `pub fn on_key(&mut self, key: &KeyEvent) -> bool` — returns `true` if
    consumed. Implements all phase-3 keybindings.
  - `pub fn on_mouse(&mut self, ev: &MouseEvent, area: Rect) -> bool`.
  - `pub fn render(&mut self, f: &mut Frame, area: Rect, syntect:
    &SyntectCache)`.
- `src/transcript/mod.rs` — `pub mod integration; pub use integration::TranscriptPane;`.
- `src/views/perri.rs` — refactor: replace the inline transcript fields and
  key handling with `transcript: TranscriptPane`. Behaviour unchanged; this
  is a structural extraction so the other views can adopt the same pattern.
- `src/views/fred.rs` — add `transcript: TranscriptPane`. Wire:
  - In `FredView::new`, after PTY reattach/auto-spawn, capture the session
    id (from `SessionStore` or generated) and stash it for lazy bring-up.
  - In the Enter-to-spawn handler (`src/views/fred.rs:610-650` area; locate
    by `FRED_PTY_TAG` + `&["--dangerously-skip-permissions", "--agent",
    "fred"]`), generate a UUID, append `--session-id`, persist via
    `SessionStore::record`.
  - In `on_event`, when transcript is visible and PTY not capturing, delegate
    keys to `self.transcript.on_key(&k)`; otherwise existing fred behaviour.
  - Layout: when visible, replace the right-hand pane (today: calendar /
    image renderer slot) with the transcript pane. Confirm the calendar pane
    is not the only thing in that column — if it is, transcript and calendar
    share the column via a vertical split (50/50). Adjust based on
    `src/views/fred.rs` layout reading at edit time.
- `src/views/mother.rs` — same pattern. Mother's REPL is the
  `mother` agent. Mother does **not** auto-spawn from `SessionStore`
  (verify by reading `src/views/mother.rs`); the transcript bring-up should
  still work whenever a PTY exists. Layout: Mother has a queue / activity
  panel arrangement; transcript replaces the right side when toggled.
- `src/views/teri.rs` — same pattern. Teri's spawn site is at
  `src/views/teri.rs:328-355`. Add `--session-id` there. Teri's layout is
  simpler (mostly PTY); transcript splits the area 50/50 vertically when
  visible.
- `src/views/agent_generic.rs` — same pattern for Claudia/Cody/Kennedy. The
  generic view has the simplest layout (status header + PTY); transcript
  splits the PTY area 50/50 vertically when visible. Spawn site is the
  Enter-to-spawn path; locate by `id` (the view id is the agent name) and
  the same `claude` args pattern.
- `src/sessions.rs` — no schema changes; v2 already supports `session_id`
  per entry (phase 1).
- `tests/transcript_integration.rs` — **new**. A single end-to-end test that
  uses the `TranscriptPane` helper directly (no view): bring up against a
  tempdir, write JSONL, assert visible toggle + key handling.
- `tests/views_transcript_smoke.rs` — **new**. For each of the five views
  (perri, fred, mother, teri, generic("claudia")), construct the view in a
  test harness (mock `ViewCtx`, in-memory `pty_factory`), simulate `Ctrl+T`,
  assert the view does not panic and the transcript is wired. Use whatever
  test harness pattern already exists in the repo for views — check
  `tests/` and `src/views/` for an existing example; if none, scope this to
  `perri` only and document the gap.

## Approach

1. **Extract `TranscriptPane` into `src/transcript/integration.rs`.**
   - Move the phase-1/2/3 fields off `PerriView` onto `TranscriptPane`.
   - `TranscriptPane::on_key` implements all phase-3 keybindings (j/k/o/T/g/G/
     Enter/PageUp/PageDown/Home/End) and returns `true` when consumed.
   - `TranscriptPane::render` does the full pane render including borders,
     title (`" Transcript "` with the short session-id in muted style),
     cursor mark, and scroll.
   - Constructor takes no args; views build it via `TranscriptPane::new()`.
   - `bring_up(cwd, session_id)` is idempotent — calling it again with a
     different sid tears down and restarts. Calling with the same sid is a
     no-op.

2. **Refactor Perri to use `TranscriptPane`.**
   - This must be a pure refactor: identical behaviour, all phase-3 tests
     continue to pass with no changes to expected outputs.
   - After refactor, run the phase-2 markdown snapshot tests and phase-3
     interaction tests — they must remain green without edits.

3. **Wire each remaining view.**
   - For each of fred/mother/teri/agent_generic:
     - Read the file, locate the spawn site, the reattach helper, and the
       `on_event` key dispatcher.
     - Add `transcript: TranscriptPane` field, initialize in `new()`.
     - At spawn time: generate UUID, add `--session-id`, persist via
       `SessionStore::record(tag, "claude", &args, cwd, Some(sid))`.
     - At reattach time: read `session_id` from the stored entry; if `None`,
       call `transcript::path::find_latest_session_id_for_cwd(&cwd)`.
     - Cache the resolved sid + cwd on the view; defer `bring_up` until first
       `Ctrl+T` to avoid spinning up watchers for views the user never
       toggles.
     - In `on_event`: when `Ctrl+T` arrives and PTY not capturing,
       `bring_up` if needed and `toggle_visible`. Forward other keys to
       `transcript.on_key` when visible and PTY not capturing.
     - In layout/render: when `transcript.is_visible()`, allocate a sub-rect
       (see per-view layout decisions in "Files to change" above) and call
       `transcript.render(f, sub_rect, &self.syntect)`. Views that don't
       already hold a `SyntectCache` get one from `ViewCtx` — confirm
       `ViewCtx` carries it (it does for Perri; check the rest and thread it
       through if needed).

4. **Per-view layout decisions.** Read each view file at edit time and pick
   the placement that least disrupts the existing UX:
   - **Fred** — right column already holds the calendar; transcript shares
     the right column 50/50 vertical when visible. If that crowds the
     calendar unacceptably, fall back to replacing the calendar entirely
     while the transcript is visible (and restore it on toggle off). Note
     the decision in the PR body.
   - **Mother** — Mother's right column shows the activity panel. Replace
     it while the transcript is visible (Mother power-users will be the
     ones turning the transcript on, and the activity panel is one click
     away on toggle-off).
   - **Teri** — split the PTY area 60/40 (PTY on the left, transcript on
     the right) when visible.
   - **Generic (Claudia/Cody/Kennedy)** — split the PTY area 50/50
     vertically when visible.
   - In every case, the toggle is `Ctrl+T` in nav mode (PTY not capturing),
     matching Perri.

5. **Smoke tests across views.**
   - `tests/views_transcript_smoke.rs` constructs each view via a minimal
     harness, simulates `Ctrl+T` (with the PTY in non-capturing state), and
     asserts the transcript becomes visible. The goal is to catch
     copy-paste errors in the per-view wiring (wrong tag, missing key
     handler, panic in layout).
   - If no view-construction harness exists in the repo, add a small one in
     `tests/common/mod.rs` that builds a `ViewCtx` against an
     `InProcessPtyFactory` and stub channels. Mark the harness as
     test-only (cfg(test)).

6. **Documentation.**
   - Add a short section to the top-level `README.md` (if one exists; check
     first) under "REPL views" documenting the `Ctrl+T` toggle and the
     keybindings. If `README.md` already has a key-help table, append to it.
     If not, skip — do not invent a new docs file.

## Acceptance criteria

- `cargo test --all` passes including the new integration and per-view smoke
  tests.
- `cargo clippy --all-targets -- -D warnings` passes.
- Manually: opening a fresh REPL in each of Perri, Fred, Mother, Teri, and
  one generic-view agent (Claudia) and pressing `Ctrl+T` shows a transcript
  pane tailing that conversation's JSONL log.
- Manually: restarting Nostromo and reattaching to existing PTYs preserves
  the ability to bring up the transcript (the sid is read from
  `sessions.toml`).
- The phase-2 and phase-3 test suites are unmodified and still pass — the
  Perri refactor in step 2 is observably behaviour-preserving.
- Branch is `feat/transcript-pane-phase4`. PR body links this plan file and
  notes which per-view layout choice was made for each view.

## Out of scope

- Selectable text / copy-to-clipboard (still deferred).
- Search-in-transcript.
- Persisting `transcript_visible` / expanded-set / thinking-toggle across
  restarts.
- Replacing the PTY view entirely — transcript stays read-only and
  additive.
- New views or new agents — only the five existing REPL-bearing views.
- Daemon-side changes — the daemon needs no awareness of session ids
  beyond passing the spawn args through, which it already does.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Mostly mechanical rollout once TranscriptPane is extracted. The extraction itself is a careful refactor but well-bounded."
  redd:
    model: sonnet
    effort: medium
    rationale: "Per-view smoke tests are repetitive; the integration test is the load-bearing one."
  marty:
    model: sonnet
    effort: medium
    rationale: "Five near-identical wirings — refactor pass should consolidate any drift."
  perri:
    model: sonnet
    effort: high
    rationale: "Reviewer must verify each view's spawn-site, reattach-path, and layout decision individually — easy place for subtle copy-paste bugs."
```
