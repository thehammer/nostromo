# nostromo Phase 3 — Mother integration, await modal, context panel, break-glass

## Delivery model

**Trunk-based. Do NOT open a pull request.**
When work is complete and tests pass, merge the feature branch directly to `main` and push:
```bash
git checkout main && git merge --ff-only feature/phase3-mother-integration && git push origin main
```
Do not run `gh pr create` or any equivalent.

## Context

`nostromo` is a Ratatui-based Rust TUI at `~/Code/nostromo` that aims to be a unified
cockpit for a fleet of Claude Code agents (Fred, Perri, Cody, Claudia, Kennedy,
Mother). Phase 1 shipped the scaffold (tab bar, Fred + Perri views, agent stubs).
Phase 2 (assumed complete before this plan executes) wired:

- A real PTY into REPL panes via `portable-pty` + `vt100`.
- An `AgentBus` (`src/agent_bus.rs`) tailing `~/.claude/activity.jsonl` and
  re-broadcasting structured `AgentEvent`s over a `tokio::sync::broadcast` channel.
- Syntect-highlighted diff rendering inside Perri's diff pane.

Phase 3 turns the Mother tab from a placeholder into a real queue dashboard,
adds an inline await/approval modal that surfaces operator questions raised by
Mother workers, adds a toggleable right-side context panel sourced from
`AgentBus`, and adds a "break-glass" propose/confirm UI (a nostromo-side
sentinel convention defined in this plan — Mother itself has no break-glass
primitive today).

There is no Jira/GitHub ticket for this phase; it tracks the project plan in
`~/Code/nostromo/docs/`.

## Target

- **Repo:** `~/Code/nostromo`
- **Branch:** `feature/phase3-mother-integration`
- **Base:** `origin/main`

## Authoritative Mother conventions (verified against `~/Code/mother`)

The executor MUST treat the following as the contract — they were read from
`~/Code/mother/plugins/mother/` at plan time. Do not assume; if anything looks
inconsistent, re-read those files.

- **State root.** `MOTHER_ROOT` defaults to `$HOME/.mother`. Job JSON files
  live at `$MOTHER_ROOT/jobs/<id>.json` (one per job). Logs at
  `$MOTHER_ROOT/logs/<id>.log`. Events at `$MOTHER_ROOT/events/<id>.jsonl`.
  Source: `~/Code/mother/plugins/mother/lib/state.sh:12-18`.
- **Statusline cache.** `MOTHER_STATUSLINE_CACHE` defaults to
  `/tmp/.mother-statusline`. Format is a single line:
  `running:queued:failed:awaiting` (four colon-separated integers; old caches
  may be three-field — treat a missing fourth field as 0).
  Source: `~/Code/mother/plugins/mother/statusline/segment.sh:19,56-83,95-105`.
  NOTE: this differs from the original brief which said
  `running:queued:succeeded:failed`. The brief was wrong. Use the format above.
- **Job listing.** `mother list --format json` emits a JSON array of full job
  objects (one per job in `$MOTHER_ROOT/jobs/`). The flag is `--format json`,
  not `--json`. Filters: `--state <state>`, `--repo <repo>`.
  Source: `~/Code/mother/plugins/mother/bin/mother:311-369`.
- **Awaiting state.** When a worker calls `mother await --question "..."` it
  atomically transitions the job JSON to `state: "awaiting"` and writes the
  question into the job's `.question` field, plus a `.paused_reason` (e.g.
  `"user"`). It also appends an `awaiting_input` event to the events file.
  No separate sentinel file is created — the job JSON itself is the signal.
  Source: `~/Code/mother/plugins/mother/bin/mother:1043-1098`.
- **Resuming an awaiting job (operator-facing).** `mother resume <id> "<answer>"`
  writes `pending_answer`, transitions the job state to `ready`, and the
  daemon's next tick spawns a fresh worker with the answer prepended to the
  plan. Answer can be passed positionally, via `--from-file <path>`, or via
  stdin (`-`). Source: `~/Code/mother/plugins/mother/bin/mother:1099-1163`.
- **There is no "deny" primitive for awaits.** The closest operator action is
  `mother cancel <id>`, which transitions an `awaiting` job to `cancelled`
  with `reason: "user_cancelled_awaiting"`. Use `cancel` to implement "deny".
  Source: `~/Code/mother/plugins/mother/bin/mother:744-747`.
- **Cancel / dequeue.** `mother cancel <id>` works for any non-terminal state
  (queued, ready, running, awaiting). Use it for the `d` keybinding on the
  Mother tab.
- **Retry.** Mother does NOT expose a `mother retry` subcommand. To retry a
  failed job, the operator must re-enqueue with `mother add` against the same
  plan. For phase 3, the `r` keybinding on a failed job opens a confirmation
  modal that, on confirm, shells out to `mother add --plan <path>` using the
  plan path stored in the failed job's JSON (field: `.plan_path` — verify by
  inspecting one job JSON during implementation; if absent, fall back to
  showing the failed job's tail and disabling retry with a status-bar note).
- **Break-glass.** Not a Mother primitive. We invent a nostromo-local
  convention: a sentinel file at `$HOME/.nostromo/break-glass.json` (containing
  `{action, summary, requested_at}`). Operator confirms by writing
  `$HOME/.nostromo/break-glass.response` with `approved` or `denied`.
  This file path must be documented in `docs/break-glass.md` (new).

## Files to change

### Existing

- `src/mother.rs` — rewrite. Replace stub with:
  - `MotherStatus { running, queued, failed, awaiting }` parsed from
    `/tmp/.mother-statusline` (env override `MOTHER_STATUSLINE_CACHE`).
  - `MotherJob` struct mirroring the JSON Mother emits (id, state, repo,
    isolation, title, created_at, started_at, finished_at, plan_path,
    question, paused_reason, adherence_status, current_tier).
  - `async fn list_jobs() -> Result<Vec<MotherJob>>` shelling out to
    `mother list --format json` (env override `MOTHER_BIN`, default `mother`).
  - `async fn tail_log(id: &str, n: usize) -> Result<String>` reading the last
    `n` lines from `$MOTHER_ROOT/logs/<id>.log` (env: `MOTHER_ROOT`, default
    `$HOME/.mother`). Use `tokio::fs` + line-tailing in pure Rust; do NOT shell
    out to `tail`.
  - `async fn cancel(id: &str)`, `async fn resume(id: &str, answer: &str)`,
    `async fn add_plan(plan_path: &Path)` thin wrappers around the CLI.
  - Keep `status_line()` for backward compat in the global status bar; update
    it to read the four-field cache and surface `awaiting` count when nonzero.

- `src/views/mod.rs` — add `pub mod mother;` and remove the generic Mother
  stub registration in `app.rs`.

- `src/app.rs:33-40` — replace
  `Box::new(views::agent_generic::GenericView::new("mother", "Mother"))`
  with `Box::new(views::mother::MotherView::new(config.clone(), bus.clone()))`.
  Wire an `AgentBus` instance (currently not constructed in `run`); thread a
  `bus: Arc<AgentBus>` through `run` so Fred/Perri/Mother and the new context
  panel can subscribe. Construct the bus once at the top of `run`, pass to all
  views that need it.

- `src/app.rs` event loop — extend the `KeyCode` match arm:
  - `KeyCode::Char('r') if k.modifiers.contains(CONTROL)` → toggle
    `app_state.right_panel_visible`.
  - `KeyCode::Char('b') if k.modifiers.contains(CONTROL)` → if break-glass
    sentinel present, open break-glass modal; otherwise no-op.
  - Modal events: when a modal is active (await modal, retry confirm,
    break-glass modal), route key events to the modal first; the modal returns
    `EventOutcome::Consumed` to short-circuit further dispatch.

- `src/ui/mod.rs` — modify `render` to:
  1. After drawing chrome, if `right_panel_visible`, split `content_area`
     horizontally 75/25 and render the active view in the left chunk and the
     context panel in the right chunk.
  2. Draw any active modal as a centered overlay last (use
     `ratatui::widgets::Clear` then a bordered `Paragraph`/`List` block).
  3. Render the break-glass banner inside `chrome::render_chrome` when the
     sentinel is present (status-bar tail or dedicated banner row above tabs —
     pick one and document it).

- `src/event.rs` — add new `AppEvent` variants:
  - `MotherJobs(Vec<MotherJob>)` — pushed by a polling task every ~2s.
  - `MotherStatusline(MotherStatus)` — pushed when statusline cache changes.
  - `AwaitDetected(MotherJob)` — fired when poller observes a job transitioning
    into `awaiting` since the last poll.
  - `BreakGlassDetected(BreakGlassRequest)` — fired by a `notify` watcher on
    `$HOME/.nostromo/`.
  - `RightPanelData(RightPanelSnapshot)` — fired when the right panel's
    upstream data changes.

### New

- `src/views/mother.rs` — Mother queue view. Sections:
  - Top: 4-quadrant counts strip (running / queued / failed / awaiting), color
    coded (sage / amber / red).
  - Left list: jobs grouped by section in this order: `awaiting` (red),
    `running` (sage with spinner), `queued`+`ready` (amber), recent
    `succeeded` (last 10), recent `failed` (last 10). Up/down arrows to move
    selection.
  - Right detail pane: selected job's metadata + last 30 lines of its log
    (refreshed on selection change and every 2s for running jobs).
  - Keybindings (active when this view is focused):
    - `Enter` — focus the log tail, scroll with PgUp/PgDn.
    - `d` — cancel selected job (calls `mother cancel <id>` after confirm).
    - `r` — on a failed job, open retry confirm modal; on confirm,
      `mother add --plan <plan_path>`.
    - `a` — if selected job is `awaiting`, open the await modal.

- `src/views/await_modal.rs` — modal struct + render fn.
  - Inputs: `MotherJob` with `state == "awaiting"` and `question`.
  - Layout: centered 70%×60% overlay. Title shows job id + title. Body shows
    question. Footer: `[a] approve  [d] deny  [v] view diff  [esc] dismiss`.
  - `a` — prompt for an inline single-line answer (text input row); on submit,
    call `mother::resume(id, answer)`.
  - `d` — call `mother::cancel(id)` (deny == cancel-from-awaiting; this is the
    only mother-supported deny path).
  - `v` — close modal, switch active view to Perri, focus its diff pane on the
    job's worktree HEAD diff (Perri exposes a public method
    `focus_diff_for_worktree(path: &Path)` — add it).

- `src/views/break_glass_modal.rs` — modal showing the proposed action,
  summary, and `[y] confirm  [n] deny  [esc] dismiss`. On `y`, write
  `approved` to `$HOME/.nostromo/break-glass.response` and remove the sentinel.
  On `n`, write `denied` and remove the sentinel.

- `src/ui/widgets/right_panel.rs` — pure render fn that takes a
  `RightPanelSnapshot { task_title, recent_tools: Vec<String> (last 5),
  open_files: Vec<String>, total_tokens: u64, last_activity: DateTime<Utc> }`
  and draws a vertically stacked summary in the given `Rect`.

- `src/ui/widgets/modal.rs` — small helper that draws a centered `Rect`
  (`fn centered(width_pct: u16, height_pct: u16, area: Rect) -> Rect`) and
  a function `clear_and_block(f, area, title)` to render the modal frame.

- `src/data/mother_poll.rs` — spawned tokio task:
  - Watches `/tmp/.mother-statusline` with `notify` and emits
    `MotherStatusline` on change.
  - Polls `mother list --format json` every 2s; diffs against last snapshot;
    emits `MotherJobs(...)` always and `AwaitDetected(job)` for any job whose
    state crossed into `awaiting` since the last poll.

- `src/data/break_glass.rs` — `notify` watcher on `$HOME/.nostromo/`. When
  `break-glass.json` appears, parse it and emit `BreakGlassDetected`.

- `src/data/right_panel_source.rs` — subscribes to `AgentBus`, maintains a
  per-agent `RightPanelSnapshot` (rolling window of 5 tool calls), emits
  `RightPanelData` on change for the currently-active agent id.

- `tests/mother_status_parse.rs` — unit tests for parsing the four-field
  statusline (and three-field fallback).

- `tests/mother_list_json_parse.rs` — fixture-based test using a checked-in
  sample under `tests/fixtures/mother_list.json` (use the JSON shape from
  `~/Code/mother/plugins/mother/bin/mother:311-369` — fields `id`, `state`,
  `repo`, `isolation`, `title`, `created_at`, `plan_path`, `question`,
  `paused_reason`, `adherence_status`, `current_tier`).

- `tests/await_modal.rs` — render the modal into a test backend and assert it
  contains the question, job id, and the four key hints.

- `docs/break-glass.md` — new short doc describing the nostromo-side sentinel
  convention (paths, JSON shape, response semantics) so this convention is
  discoverable.

## Approach

1. **Branch + skeleton.** Create `feature/phase3-mother-integration` off
   `origin/main`. Add empty modules so the project compiles after each step.

2. **Verify Mother conventions on disk.** Before touching code, run
   `sed -n '1,25p' ~/Code/mother/plugins/mother/lib/state.sh`, peek at
   `~/Code/mother/plugins/mother/statusline/segment.sh`, and inspect a real
   job JSON if one exists in `$HOME/.mother/jobs/`. Cross-check the field
   names and statusline format against the conventions table above. If
   anything has drifted, update the structs in `src/mother.rs` and the
   fixture in `tests/fixtures/mother_list.json` to match.

3. **Rewrite `src/mother.rs`.** Implement the structs and async helpers.
   Use `tokio::process::Command` for shellouts; resolve `mother` via env
   `MOTHER_BIN` (default `mother`). Tests in `tests/mother_status_parse.rs`
   and `tests/mother_list_json_parse.rs` must pass before moving on.

4. **Spawn pollers.** Implement `src/data/mother_poll.rs`. Wire it into
   `app::run` alongside the existing `*_rx` watch channels. Adapt the event
   loop to receive these events via `tokio::select!` or by funneling them
   into the existing `mpsc::UnboundedSender<AppEvent>` (the latter matches
   the current pattern — prefer it).

5. **Build the Mother view.** Implement `src/views/mother.rs` consuming the
   most recent `MotherJobs` snapshot held in the view's own state (updated
   from `AppEvent::MotherJobs`). Render counts strip, list, detail pane.
   Implement keybindings; the `d`/`r`/`a` flows open modals (see step 7).

6. **Right panel.** Add `right_panel_visible: bool` to a small `AppState`
   (or pass through to `ui::render`). Implement
   `src/data/right_panel_source.rs` and `src/ui/widgets/right_panel.rs`.
   Update `src/ui/mod.rs` to split horizontally when visible. Bind `Ctrl-R`
   in `src/app.rs`.

7. **Modals.** Add `src/ui/widgets/modal.rs` helpers. Implement
   `src/views/await_modal.rs`, `src/views/break_glass_modal.rs`, and a small
   `ConfirmModal` for cancel/retry confirmations. Modal state lives on
   `AppState` (only one active modal at a time). Modal receives key events
   first and returns `EventOutcome::Consumed` to short-circuit propagation.

8. **Wire `AwaitDetected`.** In the event loop, when `AwaitDetected(job)`
   fires and no modal is active, open the await modal. Approve calls
   `mother::resume`; deny calls `mother::cancel`; view-diff switches the
   active view to Perri and calls
   `PerriView::focus_diff_for_worktree(...)`.

9. **Break-glass.** Implement `src/data/break_glass.rs` and the
   `BreakGlassDetected` event. When detected, render a persistent banner in
   the chrome status bar (modify `src/ui/chrome.rs`); `Ctrl-B` opens the
   modal; on confirm/deny, write the response file and remove the sentinel.
   Add `docs/break-glass.md`.

10. **Tests.** Write the unit/integration tests listed under "Files to
    change → New". Use ratatui's `TestBackend` for modal-render assertions.
    `cargo test` must pass.

11. **Build clean.** `cargo build --release` with `RUSTFLAGS="-Dwarnings"`
    must produce no warnings. Run `cargo clippy --all-targets -- -D warnings`
    and fix anything it flags.

12. **Commit + PR.** One commit per logical step (8–12 commits is fine).
    Final PR title: `feat(phase3): mother queue view, await modal, context
    panel, break-glass`. PR body summarizes the four sub-features and lists
    the `mother` CLI commands nostromo now invokes.

## Acceptance criteria

- The Mother tab renders a four-field counts strip and lists jobs grouped by
  state. Counts update within ~2s of `/tmp/.mother-statusline` changing.
- `Enter` on a job tails its log; `d` cancels (with confirm); `r` retries a
  failed job by re-adding its `plan_path` (or shows a clear error if absent);
  `a` on an awaiting job opens the await modal.
- The await modal fires automatically (without user navigation) within ~2s of
  any Mother job transitioning to `awaiting`. Approving submits an answer via
  `mother resume <id> "<answer>"`; denying calls `mother cancel <id>`. The
  job leaves the `awaiting` state in Mother as a result (verifiable by
  watching `mother list --format json`).
- `Ctrl-R` toggles a 25%-width right panel showing the active agent's task
  title, last 5 tool calls, open files, total tokens, and last-activity
  timestamp, all sourced from `AgentBus` (no new file watchers for
  activity.jsonl — reuse phase-2 wiring).
- When `$HOME/.nostromo/break-glass.json` exists, a banner is visible in the
  status bar regardless of active view. `Ctrl-B` opens the break-glass
  modal; `y` writes `approved`, `n` writes `denied` to
  `$HOME/.nostromo/break-glass.response`, and the sentinel file is removed.
- `cargo build --release` is clean with `RUSTFLAGS="-Dwarnings"`. `cargo
  clippy --all-targets -- -D warnings` is clean. `cargo test` passes.
- All four new test files (`mother_status_parse`, `mother_list_json_parse`,
  `await_modal`, plus a smoke test for `right_panel`) pass.
- PR body explicitly lists which `mother` CLI subcommands nostromo invokes
  (`list`, `cancel`, `resume`, `add`) and the env vars it honors
  (`MOTHER_ROOT`, `MOTHER_BIN`, `MOTHER_STATUSLINE_CACHE`).

## Out of scope

- Implementing a Mother "retry" primitive in Mother itself. If `plan_path` is
  absent on failed jobs, surface a status-bar note and skip retry — do not
  modify the `mother` binary.
- Native Graph or GitHub clients (phase 4).
- The `nostromod` daemon (phase 5).
- Any change to `~/Code/mother`. Phase 3 is read-only against Mother's CLI
  and on-disk state.
- Designing a generic plugin/hook system. Hardcode the Mother integration.
- Persisting the right panel toggle state across nostromo restarts.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Mother IPC is precise (statusline format, JSON shape, await/resume contract); multiple new modules with concurrent pollers and modal routing."
  redd:
    model: sonnet
    effort: medium
    rationale: "Tests are mostly fixture-based parsers and one TestBackend modal render; medium effort is sufficient."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass — extract modal helpers and ensure event-loop changes stay tidy."
  perri:
    model: sonnet
    effort: high
    rationale: "Reviewer must catch IPC contract drift against Mother's on-disk format and modal/event-loop ordering bugs that are easy to miss."
```
