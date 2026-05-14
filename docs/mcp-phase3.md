# MCP Phase 3 — Pane mutation tools and cross-view dispatch (Claudia → Mother)

## Context

Phases 1 and 2 (`docs/mcp-phase{1,2}.md`) shipped MCP scaffolding and the
read-only introspection surface. Phase 3 closes the loop: agents can now
mutate Nostromo's UI state and dispatch actions across views, without
shelling out.

The user's brief calls out three explicit capability families for this phase:

1. **Pane mutation** — `set_pane_content`, `set_pane_focus`, `set_pane_layout`.
2. **Cross-view dispatch** — most importantly, Claudia/Cody/Kennedy → Mother
   `enqueue_job` so a sub-agent can ask the queue manager to add work without
   running `mother add` in a subshell.
3. **Job control** — `mother.cancel_job`, `mother.archive_job`,
   `mother.retry_job`, `mother.approve_await` (resume an awaiting job).

The trick: the MCP server runs on a tokio task; view state lives in
`AppState` + the `BoxedView` instances, owned exclusively by the main event
loop in `src/app.rs:333-668`. We bridge across by introducing a new
`AppEvent` variant carrying MCP commands; the main loop dispatches each
to the right view exactly as it does keyboard events.

No Jira ticket; tracked via `docs/mcp-phase{1..4}.md`.

## Target
- **Repo:** nostromo
- **Branch:** feat/mcp-phase3
- **Base:** Phase 2 branch (rebase to `origin/main` after Phase 2 merges)

## Files to change

- `src/event.rs` — extend `AppEvent`:
  ```rust
  /// A command from the MCP server intended for the main event loop.
  ///
  /// Boxed to keep AppEvent size uniform — McpCommand can carry large strings.
  McpCommand(Box<McpCommand>),
  ```
  Define `pub enum McpCommand` in a new module `src/mcp/command.rs` (declared
  from `src/mcp/mod.rs`). Variants:
  ```rust
  pub enum McpCommand {
      SetPaneContent { view_id: String, pane_id: String, content: PaneContent, reply: oneshot::Sender<McpReply<()>> },
      SetPaneFocus  { view_id: String, pane_id: String, reply: oneshot::Sender<McpReply<()>> },
      SetPaneLayout { view_id: String, ratios: serde_json::Value, reply: oneshot::Sender<McpReply<()>> },
      SwitchActiveView { view_id: String, reply: oneshot::Sender<McpReply<()>> },
      PerriLoadPr { number: u64, repo: String, highlights: Option<String>, reply: oneshot::Sender<McpReply<()>> },
      PerriClearCurrentPr { reply: oneshot::Sender<McpReply<()>> },
      MotherEnqueue { plan_path: PathBuf, reply: oneshot::Sender<McpReply<MotherJobLite>> },
      MotherCancel { job_id: String, reply: oneshot::Sender<McpReply<()>> },
      MotherArchive { job_id: String, reply: oneshot::Sender<McpReply<()>> },
      MotherResume { job_id: String, answer: String, reply: oneshot::Sender<McpReply<()>> },
      GetPerriSelectedIndex { reply: oneshot::Sender<McpReply<usize>> },
      SetPerriSelectedIndex { index: usize, reply: oneshot::Sender<McpReply<()>> },
  }
  pub type McpReply<T> = Result<T, String>;
  pub enum PaneContent {
      Text(String),
      JsonSnapshot(serde_json::Value), // structured payloads e.g. for the diff pane
  }
  ```
  - `oneshot::Sender` is from `tokio::sync::oneshot`. Each handler awaits the
    reply with a 5s timeout; on timeout returns `"event_loop_timeout"`.

- `src/app.rs:388-668` — extend the main event-loop match to handle
  `AppEvent::McpCommand(cmd)`. Implement each variant:
  - **SetPaneFocus / SwitchActiveView**: look up `view_id` in `views`, update
    `active`, call `views[old].blur()` / `views[new].focus()`. Update
    `state.focused_path` when in `split_mode`. Reply `Ok(())`.
  - **SetPaneContent**: dispatch to the view's new
    `View::apply_pane_content(pane_id, content) -> Result<(), String>`
    method (added below). View returns Err on unknown pane id.
  - **SetPaneLayout**: deserialize `ratios` into a view-specific struct
    (e.g. `PerriRatios`); update the view's internal ratios; call
    `pane_ratios::save(&p)`.
  - **PerriLoadPr / PerriClearCurrentPr**: call into Perri's new
    `pub fn load_pr(&mut self, number, repo, highlights)` /
    `pub fn clear_current_pr(&mut self)` (added below). These methods
    write to `~/.claude/state/perri/current-pr.json` + touch the dirty
    sentinel — exactly what `~/.claude/lib/perri-load-pr.sh` does today,
    but in-process, so the Bash permission system doesn't gate it.
    (Phase 4 will remove the dirty-file step once the watcher is replaced
    by a direct push.)
  - **MotherEnqueue**: validate `plan_path` exists and is a regular file,
    then call `mother::add_plan(&plan_path).await`. Reply with a
    `MotherJobLite { id, title, status }` derived by re-listing jobs and
    finding the newly added one (`mother add` does not currently return
    the new id — confirm by reading `src/mother.rs:225`; if it does, use
    it directly).
  - **MotherCancel / MotherArchive**: call `mother::cancel` /
    `mother::archive`.
  - **MotherResume**: call `mother::resume(id, answer).await`.
  - **GetPerriSelectedIndex / SetPerriSelectedIndex**: downcast Perri view,
    read/write `selected_pr`.

- `src/views/mod.rs` — extend the `View` trait:
  ```rust
  /// Apply a structural change to a pane. Returns Err with a stable
  /// machine-readable string for unknown panes or invalid payloads.
  fn apply_pane_content(&mut self, _pane_id: &str, _content: &PaneContent) -> Result<(), String> {
      Err("not_supported".into())
  }
  /// Set the layout ratios from a JSON value. Same convention.
  fn apply_pane_layout(&mut self, _ratios: &serde_json::Value) -> Result<(), String> {
      Err("not_supported".into())
  }
  ```
  Add `pub use crate::mcp::command::PaneContent;` import.

- `src/views/perri.rs` — implement:
  - `apply_pane_content`: pane ids `"pr_queue"` / `"diff"` / `"repl"`.
    Allowed mutations:
    - `pr_queue` + `PaneContent::JsonSnapshot(value)` → no-op (queue is
      data-driven from the watch channel; refuse with
      `Err("readonly_pane")`).
    - `diff` + `PaneContent::Text(s)` → store as an override and render in
      place of the syntect-rendered diff (use an internal
      `Option<String> diff_override` field; cleared on next watch update).
    - `repl` + `PaneContent::Text(_)` → `Err("readonly_pane")` (PTY-owned).
  - `apply_pane_layout`: deserialize a `PerriRatios` JSON, clamp via
    `ui::pane_ratios::clamp`, save.
  - `pub fn load_pr(&mut self, number: u64, repo: String, highlights: Option<String>)`:
    construct the JSON record from a `gh pr view` call (or rather, the
    cached `pr_rx` snapshot for the matching PR; if not present, fall back
    to spawning `gh pr view ... --json ...`), write
    `~/.claude/state/perri/current-pr.json`, touch
    `~/.claude/state/perri/current-pr.dirty`. The existing
    `perri_pr_native` watcher picks it up.
  - `pub fn clear_current_pr(&mut self)`: remove `current-pr.json`, touch
    the dirty sentinel.

- `src/views/fred.rs`, `src/views/mother.rs`, `src/views/teri.rs`,
  `src/views/agent_generic.rs` — implement `apply_pane_content` for the
  panes that make sense (mailbox/calendar overrides, mother job-list pinned
  filter, teri todos override) and refuse the rest. Phase 3 implements
  Perri thoroughly; the other views get minimal `apply_pane_content`
  implementations that handle one or two clearly useful panes and return
  `"not_supported"` for the others. **Document which panes are accepted
  per view in `docs/mcp/panes.md`.**

- `src/mcp/tools/mod.rs` — register the new tools:
  - `nostromo.set_pane_content({ view_id, pane_id, content })`
  - `nostromo.set_pane_focus({ view_id, pane_id })`
  - `nostromo.set_pane_layout({ view_id, ratios })`
  - `nostromo.switch_active_view({ view_id })`
  - `perri.load_pr({ number, repo, highlights? })`
  - `perri.clear_current_pr()`
  - `perri.set_selected_index({ index })`
  - `mother.enqueue_job({ plan_path })`
  - `mother.cancel_job({ id })`
  - `mother.archive_job({ id })`
  - `mother.resume_job({ id, answer })`

- `src/mcp/tools/{set_pane.rs, switch_view.rs, perri_mutators.rs, mother_mutators.rs}` —
  **new** handler files. Each one constructs an `McpCommand`, attaches a
  `oneshot::channel`, sends through `state.event_tx`, awaits the reply with
  a 5s timeout, and returns it as the MCP tool result. Errors propagate
  with a stable string code (`"unknown_view"`, `"unknown_pane"`,
  `"readonly_pane"`, `"not_supported"`, `"plan_not_found"`,
  `"mother_cli_error: <msg>"`, etc.).

- `src/mcp/state.rs` — already has `event_tx`. No new fields strictly needed,
  but consider an `Arc<AtomicUsize> active_view_idx` mirror so read-only
  introspection tools can report which view is focused without round-tripping
  through the event loop. Optional; if added, update `app::run` to mirror
  `active` into it.

- `tests/mcp_mutations.rs` — **new** integration test. Tougher than the
  Phase-2 tests because mutations require a partial app-loop. Use a
  lightweight test harness:
  - Construct an `McpSharedState` with a synthetic `mpsc::UnboundedSender`.
  - Spawn the MCP server.
  - Spawn a "fake event loop" task that drains the receiver and handles
    each `McpCommand` with stubbed behaviour: for SetPaneFocus, record
    the requested view_id; for MotherEnqueue, return a stub job; etc.
  - Call each mutating tool from a test client, assert the stubbed loop
    saw the right command and the tool returned the expected reply.
  - For PerriLoadPr, use a `tempfile::TempDir` and override the home dir
    via `HOME` env var so the test writes into the tempdir, not the
    user's `~/.claude`.

- `tests/mcp_perri_load_pr_integration.rs` — **new** end-to-end test for
  the most important mutation. Use the real PerriView (no stubbed loop)
  inside a small `App` harness; assert that calling `perri.load_pr(...)`
  via MCP results in `current-pr.json` written to the temp HOME and the
  `pr_rx` watch channel updating with the new PR data within 1s.

- `docs/mcp/panes.md` — **new**. Reference doc listing every view and its
  pane ids + which `apply_pane_content` payloads each pane accepts. Refer
  to this from agent.md migration in Phase 4.

## Approach

1. **Add the command channel.** Define `McpCommand` and the `AppEvent`
   variant. Update `src/event.rs` and add `src/mcp/command.rs`.

2. **Extend `View`.** Add the two new trait methods with default Err
   implementations so non-overriding views compile without change. Wire
   `PaneContent` import.

3. **Implement Perri mutations.** Add `load_pr`, `clear_current_pr`, and
   `apply_pane_content` / `apply_pane_layout`. Reuse the existing JSON
   shape from `~/.claude/lib/perri-load-pr.sh` so the watcher in
   `src/data/perri_pr_native.rs` accepts it unchanged.

4. **Implement Mother mutations.** Thin wrappers over existing async
   functions in `src/mother.rs`. The handlers spawn the async work and
   await it before replying.

5. **Implement the event-loop dispatcher.** In `src/app.rs`, after the
   existing `AppEvent::AgentUpdate` short-circuit (line 422), add a branch
   for `AppEvent::McpCommand(cmd)` that pattern-matches each variant and
   sends `Ok` / `Err` through the oneshot reply.

6. **Implement the tool handlers.** Each one is small (~30 lines):
   parse args → construct command + oneshot → send → await with timeout
   → return result.

7. **Cross-view dispatch test.** From inside Cody's REPL (simulated in a
   test), call `mother.enqueue_job({ plan_path: "<tempdir>/plan.md" })`,
   assert the stubbed event loop sees `MotherEnqueue` with the right path.

8. **Manual smoke.**
   - Launch Nostromo, in Perri's REPL ask Claude to call
     `perri.load_pr({ number: <real PR>, repo: "thehammer/nostromo" })`,
     verify the diff pane updates.
   - From Cody's REPL, call `nostromo.switch_active_view({ view_id: "mother" })`,
     verify Nostromo switches focus to the Mother tab.
   - From Mother's REPL, call `mother.archive_job({ id: "<some terminal job>" })`,
     verify the job leaves the list.

## Acceptance criteria

- `cargo build` and `cargo test` pass.
- `tests/mcp_mutations.rs` and `tests/mcp_perri_load_pr_integration.rs` pass.
- Every mutating tool exists in the registry and returns within 5s under
  load (graceful timeout, not a hang).
- All MCP tool errors are stable, machine-readable strings (no panics, no
  free-form messages mixed with codes — convention: `snake_case_code` or
  `snake_case_code: <human detail>`).
- `perri.load_pr` produces the same `current-pr.json` shape that the
  existing `perri_pr_native` watcher accepts (round-trip: write via MCP,
  read back via the watcher, observe a new `PrSnapshot` in `pr_rx`).
- `nostromo.switch_active_view` correctly swaps the active view and emits
  blur/focus.
- The PR body lists each new tool and its accepted/rejected payload codes.
- PR title includes "MCP phase 3" and references this phase plan.

## Out of scope

- Removing the dirty-file mechanism. Phase 4 owns that.
- Migrating agent.md files. Phase 4.
- Adding notifications, status-bar segments, or focus/blur callbacks.
  Phase 4.
- Read-only PTY scrollback access. Deferred.
- Inter-agent pub/sub. Deferred.
- Authorising mutations (any connected MCP client can mutate anything).
  Acceptable for local-socket; revisit if exposing over TCP.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New cross-thread command channel touches every view, mother CLI shell-out, and the app event loop. Highest-stakes phase for correctness."
  redd:
    model: sonnet
    effort: high
    rationale: "Mutation tests need a fake event loop + a real-view integration test. Coverage gaps here become latent UX bugs."
  marty:
    model: sonnet
    effort: medium
    rationale: "Tool handlers share the same send-await-timeout shape; consolidate via a helper after the first three land."
  perri:
    model: sonnet
    effort: high
    rationale: "Cross-thread mutation correctness, oneshot lifetimes, view downcasts — the kind of code a missed review pays for at runtime."
```
