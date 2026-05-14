# MCP Phase 2 — Read-only introspection: list_views, get_view_state, per-view getters

## Context

Phase 1 (`docs/mcp-phase1.md`) established the MCP scaffolding: a Unix-socket
server hosted in-process by Nostromo, env-var-based caller identification
(`NOSTROMO_PTY_ID` injected into every spawned PTY), and one working tool
(`nostromo.get_self`). Phase 2 builds out the read-only introspection surface.

After this phase, an agent running inside any Nostromo PTY can ask:

- "What other views are mounted, and what's their high-level state?"
- "Give me Perri's PR queue / current PR."
- "Give me Fred's unread mailbox / today's calendar."
- "Give me Mother's current job list."

No mutation yet — those are Phase 3. The data sources already exist as
`watch::Receiver<Option<T>>` channels in `src/data/*_native.rs` files; we
plumb them into `McpSharedState` and expose them as MCP tools.

This phase has the highest practical payoff per LOC because it immediately
removes the need for agents to shell out to helper scripts to read state.
A Perri-hosted Claude can call `nostromo.perri.list_pr_queue()` instead of
running `~/.claude/bin/perri-queue-pane --json`.

Tracked via `docs/mcp-phase{1..4}.md`; no Jira ticket.

## Target
- **Repo:** nostromo
- **Branch:** feat/mcp-phase2
- **Base:** origin/main (after Phase 1 lands; if Phase 1 is on a feature
  branch, base off that branch instead and rebase after merge)

## Files to change

- `src/mcp/state.rs` — extend `McpSharedState` with watch-receiver handles
  for every read-only data source the new tools need:
  ```rust
  pub struct McpSharedState {
      // ... existing fields from Phase 1 ...
      pub perri_queue_rx: watch::Receiver<Option<PrQueueSnapshot>>,
      pub perri_pr_rx: watch::Receiver<Option<PrSnapshot>>,
      pub fred_mailbox_rx: watch::Receiver<Option<MailboxSnapshot>>,
      pub fred_calendar_rx: watch::Receiver<Option<CalendarSnapshot>>,
      pub mother_jobs_rx: watch::Receiver<Vec<MotherJob>>,
      pub mother_status_rx: watch::Receiver<Option<MotherStatus>>,
      pub teri_todos_rx: watch::Receiver<Option<TodosSnapshot>>,
      pub rate_limits_rx: watch::Receiver<Option<RateLimits>>,
      pub budget_posture_rx: watch::Receiver<Option<BudgetPosture>>,
  }
  ```
  Note: `mother_jobs_rx` and `mother_status_rx` don't currently exist as
  watch channels — they flow through `AppEvent::MotherJobs` /
  `AppEvent::MotherStatusline` directly to the event loop. Add a small
  `watch::Sender` in `app::run` that mirrors those events into a watch
  channel for MCP. Same for rate-limits and budget-posture.

- `src/app.rs:184-329` — at startup, after spawning the data sources (lines
  198-221), also build the mirror watch channels for the event-driven data
  (Mother jobs/status, rate limits, posture) and pass all of these into
  `McpSharedState`. In the main event loop, when handling
  `AppEvent::MotherJobs(jobs)` etc., also `.send()` to the mirror channel.

- `src/mcp/tools/mod.rs` — register the new tools. Naming convention:
  `nostromo.<verb>` for global tools, `<view_id>.<verb>` for view-scoped
  tools.

- `src/mcp/tools/list_views.rs` — **new**. `nostromo.list_views()` →
  ```json
  [
    {
      "id": "perri",
      "title": "Perri",
      "pane_ids": ["pr_queue", "diff", "repl"],
      "summary": { "open_pr_count": 3, "stale": false }
    },
    {
      "id": "fred",
      "title": "Fred",
      "pane_ids": ["mailbox", "calendar", "repl"],
      "summary": { "unread_email_count": 7, "today_events": 4 }
    },
    {
      "id": "mother",
      "title": "Mother",
      "pane_ids": ["job_list", "log", "preview"],
      "summary": { "running_jobs": 1, "awaiting_jobs": 0, "queued_jobs": 2 }
    },
    ... (claudia, cody, kennedy, teri)
  ]
  ```
  - `summary` is view-specific — write a small `fn summary_for(view_id, state) -> serde_json::Value` and dispatch on `view_id`.
  - Agents without specialised state (claudia/cody/kennedy) get `{}`.

- `src/mcp/tools/get_view_state.rs` — **new**. `nostromo.get_view_state({ view_id: string })`.
  Returns the full snapshot the named view would render right now. Internally
  dispatches to the per-view getters below. Returns `{ "error": "unknown_view" }`
  for bad ids.

- `src/mcp/tools/perri.rs` — **new** module with three tools:
  - `perri.list_pr_queue()` → JSON array of items from
    `perri_queue_rx.borrow().as_ref().map(|s| s.items.clone()).unwrap_or_default()`.
    Each item: `{ repo, number, title, author, bucket, new_activity, url }`
    (matches the existing `PrQueueItem` shape in
    `src/data/perri_queue_native.rs`).
  - `perri.get_current_pr()` → `{ number, repo, title, author, additions,
    deletions, files_changed, ci_status, url, updated_at, highlights, diff,
    stale, error }` from `perri_pr_rx`. Returns `null` if no PR is loaded.
  - `perri.get_state()` → composite `{ queue: [...], current_pr: {...},
    selected_index: <selected_pr usize from view>, stale: bool }`. Pulling
    `selected_index` requires reading from the view; for Phase 2, omit it
    and add it in Phase 3 alongside other view-mutation surfaces. Document
    the omission.

- `src/mcp/tools/fred.rs` — **new**. Tools:
  - `fred.list_unread_emails()` → unread items from `fred_mailbox_rx`. Fields:
    `{ id, subject, from, received_at, snippet, is_unread, has_attachments }`
    (match the existing `MailboxItem` shape in
    `src/data/fred_mailbox_native.rs`).
  - `fred.list_calendar_events({ date?: "YYYY-MM-DD" })` → events from
    `fred_calendar_rx`. If `date` omitted, return today's events. Use
    `chrono` for date parsing; bad dates → `{ error: "bad_date" }`.
  - `fred.get_state()` → `{ unread_count, today_event_count, mailbox: [...],
    calendar: [...] }`.

- `src/mcp/tools/mother.rs` — **new**. Tools:
  - `mother.list_jobs({ include_archived?: bool, status?: string })` →
    `Vec<MotherJob>` from `mother_jobs_rx`. Filter on `status` if provided.
    `include_archived` defaults to false (the live receiver already excludes
    archived jobs; if true, call `mother::list_jobs().await` directly).
  - `mother.get_job({ id: string })` → one job, or `null`.
  - `mother.tail_log({ id: string, lines?: u32 })` → string. Calls
    `mother::tail_log(id, lines.unwrap_or(50)).await`. Bounded at 500.
  - `mother.peek({ id: string })` → calls `mother::peek(id).await`, returns
    the `PeekSnapshot` shape.
  - `mother.get_status()` → latest `MotherStatus` from `mother_status_rx`.

- `src/mcp/tools/teri.rs` — **new**. Tool:
  - `teri.list_todos()` → todos from `teri_todos_rx`.

- `src/mcp/tools/nostromo_meta.rs` — **new**. Tools that are useful from
  any view:
  - `nostromo.get_worktree_info()` → `{ cwd, branch, parent_repo, is_worktree }`.
    Use `git2` if convenient; otherwise shell out to `git -C <cwd>
    rev-parse --show-toplevel` and `git symbolic-ref --short HEAD`.
    `git2` adds a heavy dep; prefer the shell-out via
    `tokio::process::Command`. The handler must time out at 2s and return
    `{ error: "git_timeout" }` rather than block.
  - `nostromo.get_rate_limits()` → latest `RateLimits` snapshot.
  - `nostromo.get_budget_posture()` → latest `BudgetPosture`.

- `src/mcp/tools/mod.rs` — registry update. List all 12 new tools with
  their handler functions and (if using rmcp's derive) JSON Schema inputs.
  If hand-rolled, write a small `match name { ... }` dispatcher.

- `tests/mcp_introspection.rs` — **new**. Integration test. Stand up an
  `McpSharedState` populated with synthetic snapshots (use
  `watch::channel(...)` with pre-set values). Connect a test client to the
  socket, call each tool, assert the JSON shape. Cover happy path for each
  tool plus 3-4 error cases (`unknown_view`, `bad_date`, missing job id).

- `tests/fixtures/mcp_perri_queue.json`, `tests/fixtures/mcp_fred_mailbox.json` —
  **new** small fixture files used by the integration test to seed the
  watch channels.

## Approach

1. **Inventory the data sources.** Verify by reading each `*_native.rs` file
   that the watch-channel receivers expose the snapshot types the tools
   need. The relevant files: `src/data/perri_queue_native.rs`,
   `src/data/perri_pr_native.rs`, `src/data/fred_mailbox_native.rs`,
   `src/data/fred_calendar_native.rs`, `src/data/teri_todos.rs`,
   `src/data/rate_limits_watcher.rs`. Take note of the exact snapshot
   field names; the tools' JSON output should match exactly so consumers
   don't have to learn two shapes.

2. **Add the mirror channels.** Mother jobs and status arrive as
   `AppEvent::MotherJobs` / `AppEvent::MotherStatusline` in
   `src/app.rs:445-453`. Build a `watch::channel::<Vec<MotherJob>>(vec![])`
   alongside, store the `Sender` in a small struct held by `app::run`, and
   `.send()` whenever the event arrives. Same for `RateLimitsChanged` and
   `PostureChanged`. Pass the `Receiver` halves into `McpSharedState`.

3. **Thread `McpSharedState` clones.** It already has `event_tx` and
   `views_meta` from Phase 1. Add the new receiver fields. `McpSharedState`
   should remain cheap-Clone (it's a bundle of `Arc`s and `watch::Receiver`s,
   both clone in O(1)).

4. **Implement the tools.** Each tool handler is small: borrow the relevant
   watch receiver, clone the value, serialize. Keep handlers in dedicated
   files per view (`tools/perri.rs`, `tools/fred.rs`, …) so adding
   capabilities later is local.

5. **Schema-driven inputs.** For tools taking arguments
   (`get_view_state`, `mother.get_job`, etc.), define an input struct with
   `#[derive(Deserialize, JsonSchema)]` so MCP `tools/list` exposes
   schemas to clients. Validate with `serde`; return
   `{ error: "invalid_args", detail: ... }` on failure.

6. **Manual smoke.** Launch Nostromo with `RUST_LOG=info,nostromo::mcp=debug`,
   open Perri's REPL, invoke `nostromo.list_views()` and `perri.list_pr_queue()`
   from Claude, confirm output matches what's visible on screen.

## Acceptance criteria

- `cargo build` and `cargo test` pass.
- `tests/mcp_introspection.rs` passes, covering all 12 new tools + the
  enumerated error paths.
- Calling `nostromo.list_views` returns exactly seven views matching the
  ones registered in `src/app.rs:273-314`.
- Each view-specific `*.list_*` / `*.get_*` tool returns JSON whose shape
  matches the corresponding `*_native.rs` snapshot type field-for-field
  (field names match; no renaming).
- Manual smoke test: from inside Perri's REPL, calling `perri.list_pr_queue()`
  returns the same PR list the queue pane is showing.
- `nostromo.get_worktree_info()` returns sensible output in both a regular
  clone and a `git worktree` worktree, and degrades gracefully (returns an
  error JSON, does not panic) outside any git repo.
- No new dirty-file mechanisms are introduced; existing ones remain in
  place untouched.
- PR title includes "MCP phase 2" and references this phase plan.

## Out of scope

- Any mutating tool (`set_pane_content`, `set_pane_focus`, `set_pane_layout`,
  `mother.cancel_job`, etc.). Phase 3.
- Migrating agent.md files off the dirty-file convention. Phase 4.
- Cross-view dispatch (Claudia → Mother enqueue). Phase 3.
- Notifications / status-bar segment registration. Phase 4.
- Adding selection state (`perri.selected_pr_index`) to read-only outputs —
  views own that, and exposing it cleanly requires the view-state plumbing
  introduced in Phase 3.
- Read-only access to other PTYs' scrollback. Deferred; privacy-adjacent and
  the daemon already buffers scrollback so exposing it is a larger design
  question.
- Inter-agent pub/sub messaging.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Repetitive but well-scoped: 12 tool handlers wired to existing watch channels. The harder seams (state, identification) shipped in Phase 1."
  redd:
    model: sonnet
    effort: high
    rationale: "Twelve tools × happy/error paths; fixture-driven assertions. Tightest test pass of the four phases."
  marty:
    model: sonnet
    effort: medium
    rationale: "Tool handlers will share patterns (borrow → clone → serialize); consolidate via a small macro or helper if duplication grows."
  perri:
    model: sonnet
    effort: medium
    rationale: "Field-shape correctness is the main review surface; protocol soundness was settled in Phase 1."
```
