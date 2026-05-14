# MCP Phase 4 — Agent.md migration, notifications, status-bar segments, deprecate shell scripts

## Context

Phases 1–3 (`docs/mcp-phase{1,2,3}.md`) built the MCP server, the read-only
introspection surface, and the pane-mutation + cross-view dispatch surface.
The MCP server is live and useful, but agents still use the old dirty-file
convention because their `~/.claude/agents/<name>.md` instructions tell them
to. Phase 4 finishes the work: migrate agents off shell scripts, add the
small set of "nice to have" surfaces that round out the design
(notifications + status-bar segments), and deprecate `~/.claude/lib/perri-*.sh`.

This phase also touches files **outside** the nostromo repo — specifically
`~/.claude/agents/*.md` and `~/.claude/lib/*.sh`. Those edits will be
described as part of the plan but executed manually by the operator after
the in-repo changes land. The Mother job for Phase 4 covers only the
in-repo work; a checklist for the operator-side changes is documented in
`docs/mcp/migration.md`.

No Jira ticket; tracked via `docs/mcp-phase{1..4}.md`.

## Target
- **Repo:** nostromo
- **Branch:** feat/mcp-phase4
- **Base:** Phase 3 branch (rebase to `origin/main` after Phase 3 merges)

## Files to change

### In-repo (this Mother job)

- `src/mcp/tools/notify.rs` — **new**. `nostromo.notify({ message: string,
  level?: "info"|"warn"|"error", view_id?: string })`. Sends an
  `AppEvent::McpCommand(McpCommand::Notify { ... })` to the event loop.
  Adds a transient status-bar toast that fades after 5s.

- `src/mcp/command.rs` — extend `McpCommand` with:
  ```rust
  Notify { message: String, level: NotifyLevel, source_view: Option<String>, reply: oneshot::Sender<McpReply<()>> },
  RegisterStatusSegment { view_id: String, segment_id: String, text: String, color: Option<String>, reply: oneshot::Sender<McpReply<()>> },
  ClearStatusSegment { view_id: String, segment_id: String, reply: oneshot::Sender<McpReply<()>> },
  ```
  `NotifyLevel { Info, Warn, Error }`.

- `src/app.rs` — `AppState` gains:
  ```rust
  pub toasts: VecDeque<Toast>,                                 // recent notifications
  pub mcp_status_segments: HashMap<(String, String), McpStatusSegment>,   // (view_id, segment_id) → text/color
  ```
  `Toast { text, level, expires_at }`. Garbage-collect expired entries on
  every Tick.

  Handle `McpCommand::Notify` by pushing a toast and forwarding to
  `ui::status_bar::render` (which already runs every frame).

  Handle `RegisterStatusSegment` / `ClearStatusSegment` by mutating
  `mcp_status_segments` and triggering a re-render via
  `event_tx.send(AppEvent::AgentUpdate { view_id: "mother" })` (or any
  view; the event loop redraws on any AgentUpdate).

- `src/ui/status_bar.rs` — extend the renderer to:
  - Draw toasts on the bottom-right of the status bar (or as an overlay
    row above) — pick the spot that minimises layout disruption; the
    review-PR sweater segment already occupies left/center.
  - Draw MCP-registered status segments for the active view. Format:
    `<view_id>: <text>` with an optional color (parse hex or use a small
    named-color table — `red`, `amber`, `sage`, `blue`, `muted`).

- `src/mcp/tools/notify.rs`, `src/mcp/tools/status_segment.rs` — **new**
  handler files for the three new tools (`nostromo.notify`,
  `nostromo.register_status_segment`, `nostromo.clear_status_segment`).

- `src/mcp/tools/mod.rs` — register the new tools.

- `src/data/perri_pr_native.rs:43`, `src/data/perri_queue_native.rs:110` —
  add a `tokio::sync::Notify` or `watch::Sender<()>` triggered by the
  MCP `perri.load_pr` mutation in addition to the existing dirty-file
  watch. The dirty-file path remains as a fallback. After this change,
  Perri's data sources accept refresh signals from either source.

- `docs/mcp/migration.md` — **new** operator-facing checklist describing
  the agent.md and shell-script changes (see the "Out-of-repo" section
  below). The Mother job does not execute these edits; the operator runs
  them manually after the in-repo PR merges.

- `docs/mcp/tools.md` — **new** consolidated reference listing every MCP
  tool shipped across all four phases with its input schema and output
  shape. Generated from the registry; can be hand-written if codegen is
  too much work for this phase.

- `tests/mcp_notify.rs` — **new**. Integration test calling
  `nostromo.notify(...)` and asserting a `Toast` lands in `AppState`.
  Use the same fake-event-loop harness from Phase 3.

- `tests/mcp_status_segment.rs` — **new**. Register a segment, assert it
  appears in `mcp_status_segments`. Clear it, assert it's gone.

### Out-of-repo (operator runs after merge — documented in `docs/mcp/migration.md`)

- `~/.claude/agents/perri.md` — replace every reference to
  `~/.claude/lib/perri-load-pr.sh` with the MCP call
  `perri.load_pr({ number, repo, highlights })`. Replace
  `~/.claude/lib/perri-refresh.sh` and `perri-refresh.sh --clear` with
  `perri.clear_current_pr()`. Remove the "NEVER run touch/rm against
  `~/.claude/state/perri/*`" warning (no longer relevant). Add a startup
  bullet: "On first message, call `nostromo.get_self()` to confirm view
  context; call `perri.list_pr_queue()` to read the queue."

- `~/.claude/agents/fred.md` — similar: any `touch ~/.claude/state/fred/*.dirty`
  references become `fred.list_unread_emails()` / `fred.list_calendar_events()`
  consumers; agents asking Fred for mailbox/calendar state from other views
  can now do so directly via MCP.

- `~/.claude/agents/mother.md` (if it exists) and any other agent.md that
  references the dirty-file convention — audit and migrate.

- `~/.claude/lib/perri-load-pr.sh`, `~/.claude/lib/perri-refresh.sh` —
  add a top-of-file deprecation banner:
  ```bash
  #!/usr/bin/env bash
  # DEPRECATED 2026-05: use the MCP tools `perri.load_pr` / `perri.clear_current_pr`
  # instead. This script remains as a fallback for sessions without an MCP-enabled
  # nostromo. Scheduled for removal: 2026-08.
  ```
  Keep them functional for one release window.

- `~/.claude/settings.json` (or `~/.claude/mcp.json`) — add the nostromo
  MCP server entry pointing at `/usr/local/bin/nostromo-mcp-bridge`
  (assumes Phase 1 installation steps). The exact JSON shape lives in
  `docs/mcp/example-claude-mcp.json` (added in Phase 1).

## Approach

1. **Implement notifications.** Add the `McpCommand::Notify` variant +
   `AppState::toasts` + status-bar rendering. Toasts auto-expire after 5s.

2. **Implement status segments.** Add the register/clear commands +
   `AppState::mcp_status_segments` + status-bar rendering. Segments are
   per-view and only shown when their view is active (matches the
   existing sweater-color convention for the PR queue).

3. **Add direct-push refresh for Perri data sources.** Today,
   `perri.load_pr` writes the JSON file and touches the dirty sentinel
   (Phase 3 design). After Phase 4, the dirty file is no longer required —
   but keep the watcher in place so the shell scripts remain functional
   during the deprecation window. Add a parallel `Notify` signal:
   ```rust
   pub struct PerriPrNativeSource {
       refresh_tx: tokio::sync::mpsc::UnboundedSender<()>,   // direct push from MCP
       // existing fields ...
   }
   ```
   Wire `apply_pane_content` and `perri.load_pr` to send on `refresh_tx`
   in addition to touching the sentinel.

4. **Write `docs/mcp/migration.md`.** Step-by-step operator checklist:
   - Install `nostromo-mcp-bridge`.
   - Add MCP entry to `~/.claude/settings.json`.
   - Edit each agent.md per the diffs in this document.
   - Add deprecation banners to the shell scripts.
   - Confirm by launching Nostromo + Perri's REPL and asking Claude to
     call `nostromo.get_self()` + `perri.list_pr_queue()`.

5. **Write `docs/mcp/tools.md`.** Consolidated reference. Either generate
   from `tools::registry().describe()` at build time (preferred — add a
   `cargo run --bin nostromo-mcp-docs > docs/mcp/tools.md` step in
   `Makefile`) or hand-roll if codegen is too much. If hand-rolling, link
   each entry to the source file for the handler.

6. **Smoke tests.**
   - From Perri's REPL, call `nostromo.notify({ message: "hi", level: "info" })`,
     observe a toast in the status bar.
   - From any REPL, call `nostromo.register_status_segment({ view_id: "perri",
     segment_id: "pending_review", text: "3 PRs", color: "amber" })`,
     switch to Perri, observe the segment.
   - Clear the segment, observe it disappear.

## Acceptance criteria

- `cargo build` and `cargo test` pass.
- `tests/mcp_notify.rs` and `tests/mcp_status_segment.rs` pass.
- Toasts appear in the status bar and fade after 5s.
- MCP-registered status segments appear when their view is active and
  disappear when cleared or when the view is blurred.
- `perri.load_pr` invoked via MCP triggers a `pr_rx` update without the
  dirty-file fallback (verifiable in a test via the new direct-push
  channel).
- `docs/mcp/migration.md` covers the agent.md edits, shell-script
  deprecation banners, and Claude Code MCP server config exactly enough
  that the operator can execute the migration without referring back to
  this plan.
- `docs/mcp/tools.md` lists every tool from Phases 1–4 with input/output
  shapes, kept in sync with the registry (build-step or hand-rolled).
- Deprecation banners are added to `~/.claude/lib/perri-load-pr.sh` and
  `~/.claude/lib/perri-refresh.sh` — but only as part of the operator
  checklist, not the Mother job itself.
- PR title includes "MCP phase 4" and references this phase plan.

## Out of scope

- Removing `~/.claude/lib/perri-*.sh`. They stay for one release window.
  Removal is a future, separate task.
- Removing the dirty-file watchers in `src/data/*_native.rs`. They stay as
  a fallback; the MCP direct-push is additive.
- Inter-agent pub/sub. The user said "probably defer" — defer.
- Focus/blur callbacks for agents to pause/resume work. The user said
  "stretch" — defer.
- Read-only PTY scrollback access. Defer — privacy-adjacent design
  question.
- Authentication on the MCP socket. Local socket + filesystem perms (0600)
  remain the only guard. Revisit when/if exposing over TCP.
- Migrating `~/.claude/agents/*.md` automatically — operator does this
  manually per `docs/mcp/migration.md`.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Smaller scope than Phase 3 — three new tools, two app-state fields, status-bar rendering tweaks. The hard cross-thread work is already done."
  redd:
    model: sonnet
    effort: medium
    rationale: "Tests follow the Phase-3 pattern; main risk is status-bar rendering regressions, which are visual and tricky to assert."
  marty:
    model: sonnet
    effort: medium
    rationale: "Light refactor pass to consolidate MCP-command handler dispatch (Phases 3 + 4 added many variants)."
  perri:
    model: sonnet
    effort: medium
    rationale: "Lower stakes than Phase 3; correctness mostly limited to status-bar rendering and toast lifecycle."
```
