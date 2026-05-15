# Nostromo MCP Migration Guide

## Overview

Phases 1–4 of the MCP integration ship a Unix-socket MCP server inside
Nostromo and a lightweight bridge binary (`nostromo-mcp-bridge`) that Claude
Code connects to via stdio.  Once the Phase 4 PR merges, agents should use MCP
tools instead of the legacy shell-script conventions.

This document is the **operator checklist** for migrating agent instructions
and deprecating the old shell scripts.  Execute these steps after the Phase 4
PR is merged and deployed.

---

## Step 1 — Install `nostromo-mcp-bridge`

The bridge binary was introduced in Phase 1 (`src/bin/nostromo_mcp_bridge.rs`).
It is compiled with `cargo build --release` and installed to `/usr/local/bin`:

```bash
cargo build --release --bin nostromo-mcp-bridge
sudo cp target/release/nostromo-mcp-bridge /usr/local/bin/
```

Verify:

```bash
nostromo-mcp-bridge --version
```

---

## Step 2 — Register the MCP server with Claude Code

Add the Nostromo server to `~/.claude/settings.json` (or `mcp.json` — wherever
your Claude Code MCP config lives).  The full JSON shape is in
`docs/mcp/example-claude-mcp.json`:

```json
{
  "mcpServers": {
    "nostromo": {
      "type": "stdio",
      "command": "nostromo-mcp-bridge",
      "env": {}
    }
  }
}
```

Restart Claude Code after editing.

Confirm by asking Claude:

```
Call nostromo.get_self() and tell me what you get.
```

You should see a JSON blob with `view_id`, `session_id`, and `pane_ids`.

---

## Step 3 — Edit `~/.claude/agents/perri.md`

Replace the legacy shell-script calls with MCP tool calls.

### Remove

```markdown
- To load a PR for review: run `~/.claude/lib/perri-load-pr.sh <number> <owner/repo>`
- To clear the current PR: run `~/.claude/lib/perri-refresh.sh --clear`
- NEVER run touch/rm against `~/.claude/state/perri/*` directly.
```

### Replace with

```markdown
- On first message, call `nostromo.get_self()` to confirm view context.
- Call `perri.list_pr_queue()` to read the current review queue.
- To load a PR for review: call `perri.load_pr({ "number": <n>, "repo": "<owner/repo>", "highlights": "<optional notes>" })`.
- To clear the current PR: call `perri.clear_current_pr()`.
```

---

## Step 4 — Edit `~/.claude/agents/fred.md`

Replace any `touch ~/.claude/state/fred/*.dirty` references.  Fred's data is
now accessible directly via MCP:

- `fred.list_unread_emails()` — returns the live mailbox snapshot.
- `fred.list_calendar_events()` — returns today's calendar (or pass `{ "date": "YYYY-MM-DD" }`).
- `fred.get_state()` — returns `{ unread_count, today_event_count, mailbox, calendar }`.

Remove any lines about touching dirty-sentinel files or running shell scripts to
trigger a refresh.

---

## Step 5 — Audit other `agent.md` files

Check any other files in `~/.claude/agents/` that reference the dirty-file
convention or shell scripts under `~/.claude/lib/`:

```bash
grep -r "dirty\|perri-load-pr\|perri-refresh" ~/.claude/agents/
```

For each hit, replace the shell-script call with the equivalent MCP tool call.
The full tool reference is in `docs/mcp/tools.md`.

---

## Step 6 — Add deprecation banners to shell scripts

The shell scripts remain functional for one release window to support sessions
running without an MCP-enabled Nostromo.  Add this banner at the top of each:

**`~/.claude/lib/perri-load-pr.sh`:**

```bash
#!/usr/bin/env bash
# DEPRECATED 2026-05: use the MCP tool `perri.load_pr` instead.
# This script remains as a fallback for sessions without an MCP-enabled
# Nostromo. Scheduled for removal: 2026-08.
```

**`~/.claude/lib/perri-refresh.sh`:**

```bash
#!/usr/bin/env bash
# DEPRECATED 2026-05: use the MCP tool `perri.clear_current_pr` instead.
# This script remains as a fallback for sessions without an MCP-enabled
# Nostromo. Scheduled for removal: 2026-08.
```

---

## Step 7 — Smoke test

1. Launch Nostromo (`nostromd` or the binary directly).
2. Open a Claude Code session in a Perri REPL pane.
3. Ask Claude to call `nostromo.get_self()` — verify view context comes back.
4. Ask Claude to call `perri.list_pr_queue()` — verify queue data appears.
5. Ask Claude to call `nostromo.notify({ "message": "MCP migration complete", "level": "info" })` — verify a toast appears briefly in the status bar.
6. Ask Claude to call `nostromo.register_status_segment({ "view_id": "perri", "segment_id": "test", "text": "✓ MCP live", "color": "sage" })` — switch to the Perri tab and verify the segment appears in the status bar.
7. Call `nostromo.clear_status_segment({ "view_id": "perri", "segment_id": "test" })` and verify it disappears.

---

## Removal timeline

| Date    | Action |
|---------|--------|
| 2026-05 | Phase 4 ships; banners added; agents migrated (this checklist). |
| 2026-08 | Remove `~/.claude/lib/perri-load-pr.sh` and `~/.claude/lib/perri-refresh.sh`. |
| 2026-08 | Remove dirty-file watchers from `src/data/*_native.rs`. |
