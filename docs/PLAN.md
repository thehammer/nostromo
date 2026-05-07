# Design and scaffold nostromo — a Ratatui-based AI agent IDE

> This document is the original plan artifact committed alongside the phase 1 scaffold.
> See the project README for current status.

## Context

The user currently runs Claude Code agents inside a tmux layout with windows for agent dashboards and project workspaces. The two most elaborate windows — `Perri` (PR queue + current PR diff + REPL) and `Fred` (mailbox + today calendar + REPL) — are driven by ~1600 lines of bash scripts that poll external APIs on timers, write transient files, and rely on tmux to compose panes.

This setup works but has obvious ceilings. tmux gives panes but nothing about the panes is *aware* of each other. There's no unified activity feed, no inline approval for Mother `await` checkpoints, no syntax highlighting for diffs, no mouse interactions, and adding a new agent dashboard means writing more bash and shoving it into another tmux window. The agents themselves (fred, perri, claudia, cody, kennedy) increasingly behave like a team — the UI should reflect that.

`nostromo` is a Ratatui-based Rust TUI that replaces the fred/perri bash dashboards in phase 1, embeds the Claude CLI via a real PTY in phase 2, and grows into a unified AI-IDE shell that could plausibly replace iTerm2+tmux as the user's primary terminal workspace.

## Architecture

**Crate stack (phase 1):**
- `ratatui = "0.29"`, `crossterm = "0.28"` — TUI + backend
- `tokio` (rt-multi-thread, macros, process, time, sync, signal)
- `serde`, `serde_json`, `toml`
- `anyhow`, `thiserror`
- `tracing`, `tracing-subscriber`, `tracing-appender`
- `directories`, `chrono`, `notify`
- `insta` (dev), `clap` (derive)

**Added in later phases:**
- `portable-pty = "0.8"` — phase 2, PTY embedding
- `vt100` or `alacritty_terminal` — phase 2, PTY rendering
- `reqwest`, `oauth2` — phase 4, native Graph/GitHub clients
- `syntect` or `tree-sitter-highlight` — phase 2, diff syntax highlighting

**Data flow:** Each `DataSource` runs in its own tokio task, refreshes on interval AND on dirty-file notify wakeup, pushes snapshots to `tokio::sync::watch` channels. Views read latest snapshot value on each render. ~10Hz render when dirty, idle otherwise.

## Source layout

```
src/
  main.rs          — entry, arg parsing, terminal init/teardown, panic hook
  lib.rs           — re-exports for integration tests
  app.rs           — App run loop, view registry
  event.rs         — crossterm event polling → AppEvent
  config.rs        — TOML config loader
  agent_bus.rs     — phase 1 stub; phase 2: tails activity.jsonl
  mother.rs        — phase 1 stub; phase 3: real Mother queue client
  ui/
    mod.rs         — root render function
    chrome.rs      — tab bar, status bar
    theme.rs       — colour palette (sage/amber/red sweater)
    widgets/
      relative_time.rs
      truncate.rs
  views/
    mod.rs         — View trait + BoxedView
    fred.rs        — mailbox + calendar + REPL placeholder
    perri.rs       — PR queue + diff + REPL placeholder
    agent_generic.rs — stub view for Claudia/Cody/Kennedy/Mother
  data/
    mod.rs         — DataSource trait
    fred_mailbox.rs  — shells out to fred-mailbox-pane --json
    fred_calendar.rs — shells out to fred-calendar-pane --json
    perri_queue.rs   — shells out to perri-queue-pane --json
    perri_pr.rs      — shells out to perri-diff-pane --json
    dirty_file.rs    — polls dirty-file sentinels
tests/
  snapshot_fred.rs
  snapshot_perri.rs
docs/
  PLAN.md          — this file
```

## Phased build plan

**Phase 1 — Fred + Perri parity (complete).** Scaffold repo, render Fred/Perri using existing bash scripts with `--json` mode, tab bar, status bar, mouse focus, theme port. REPL = foreground-suspend placeholder.

**Phase 2 — Embedded PTY + diff viewer.** Real PTY via `portable-pty` + `vt100`. Syntax-highlighted diffs via `syntect`. Activity sidebar wired to `AgentBus` (tails `~/.claude/activity.jsonl`).

**Phase 3 — Mother integration + inline approval.** Mother queue panel, inline modal on `await`, right context panel, break-glass propose/confirm UI.

**Phase 4 — Native data clients.** Replace bash polling with native Rust: `reqwest` + cached OAuth for Microsoft Graph (delta queries), `octocrab` for GitHub PRs.

**Phase 5 — Workspace replacement.** Multi-window mode, companion daemon `nostromod` for detach/attach, drop tmux entirely for agent workspace.

## New ideas beyond current fred/perri

1. **Unified activity stream with replay.** Every agent emits structured events to `~/.claude/activity.jsonl`. TUI tails it, renders left sidebar. `Enter` on event jumps to relevant view. `Shift-R` opens replay mode.

2. **Inline `await` approval modal.** When a Mother job hits `await`, a modal fires regardless of active view.

3. **Agent context panel.** Right-side toggleable pane: current task title, last 5 tool calls, open files, total tokens.

4. **PR queue with diff prefetch + inline approve.** Mouse-clickable rows load diff in place. `Shift-A` to approve from queue.

5. **Sweater colour everywhere.** Perri tab amber at >5 PRs, red at >10. Cody tab amber at >15min runtime.

6. **Command palette + agent dispatch.** `Ctrl-P` — fuzzy palette for any agent action.

7. **Multi-monitor session mirror.** All TUI instances connect to `nostromod` over Unix socket.

## Terminal recommendation

**Ghostty as primary, Alacritty as fallback.** GPU-accelerated, native macOS feel. Switch when phase 2 ships; keep iTerm2 for phase 1.
