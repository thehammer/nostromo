# Nostromo MCP Tool Reference

Consolidated reference for every MCP tool shipped across Phases 1–4.

All tools are invoked over the `nostromo-mcp-bridge` stdio transport (see
`docs/mcp/example-claude-mcp.json` for the Claude Code server config).

Handler source files live under `src/mcp/tools/`.

---

## Phase 1 — Identity

### `nostromo.get_self`

Returns identity information about the calling Nostromo PTY session.

**Input**: *(none)*

**Output**:
```json
{
  "view_id":    "perri",
  "view_title": "Perri — PR Review",
  "pane_ids":   ["queue", "diff", "repl"],
  "session_id": "uuid-string",
  "spawned_at": "2026-05-14T17:00:00Z"
}
```

Source: `src/mcp/tools/get_self.rs`

---

## Phase 2 — Read-only introspection

### `nostromo.list_views`

Returns all registered views with their pane ids and a per-view summary.

**Input**: *(none)*

**Output**: `{ "views": [ { "id", "title", "pane_ids", "summary" }, ... ] }`

Source: `src/mcp/tools/list_views.rs`

---

### `nostromo.get_view_state`

Returns the full live state snapshot for a named view.

**Input**:
```json
{ "view_id": "perri" }
```

**Output**: view-specific JSON blob (see per-view sections below).

Source: `src/mcp/tools/get_view_state.rs`

---

### `nostromo.get_worktree_info`

Returns git worktree info for the calling PTY's working directory.

**Input**: *(none)*

**Output**:
```json
{
  "cwd":          "/path/to/repo",
  "branch":       "feat/mcp-phase4",
  "repo_root":    "/path/to/repo",
  "is_worktree":  true
}
```

Source: `src/mcp/tools/nostromo_meta.rs`

---

### `nostromo.get_rate_limits`

Returns the latest Claude rate-limit snapshot.

**Input**: *(none)*

**Output**:
```json
{
  "pct_5h":    42,
  "reset_5h":  1747000000,
  "pct_7d":    18,
  "reset_7d":  1747200000
}
```

Source: `src/mcp/tools/nostromo_meta.rs`

---

### `nostromo.get_budget_posture`

Returns the current global budget posture.

**Input**: *(none)*

**Output**: `{ "posture": "normal" }` — values: `flush`, `normal`, `elevated`, `conservative`, `critical`.

Source: `src/mcp/tools/nostromo_meta.rs`

---

### `perri.list_pr_queue`

Returns Perri's live PR review queue (all three buckets).

**Input**: *(none)*

**Output**:
```json
{
  "requested":   [ { "number", "title", "repo", "author", "url" }, ... ],
  "needs_review": [...],
  "changes_req": [...]
}
```

Source: `src/mcp/tools/perri.rs`

---

### `perri.get_current_pr`

Returns the PR currently loaded in Perri's diff pane, or `null` if none.

**Input**: *(none)*

**Output**: `{ "number", "repo", "title", "author", "url", "stale" }` or `null`.

Source: `src/mcp/tools/perri.rs`

---

### `perri.get_state`

Returns `{ queue, current_pr, stale }`.

**Input**: *(none)*

Source: `src/mcp/tools/perri.rs`

---

### `fred.list_unread_emails`

Returns unread emails from Fred's mailbox.

**Input**: *(none)*

**Output**: `{ "emails": [ { "id", "from", "subject", "received_at", "unread" }, ... ] }`

Source: `src/mcp/tools/fred.rs`

---

### `fred.list_calendar_events`

Returns today's calendar events (or events on a specific date).

**Input**:
```json
{ "date": "2026-05-14" }  // optional; omit for today
```

**Output**: `{ "date", "events": [ { "title", "start", "end", "in_minutes" }, ... ] }`

Source: `src/mcp/tools/fred.rs`

---

### `fred.get_state`

Returns Fred's composite state: `{ unread_count, today_event_count, mailbox, calendar }`.

**Input**: *(none)*

Source: `src/mcp/tools/fred.rs`

---

### `mother.list_jobs`

Returns Mother's job list.

**Input**:
```json
{
  "include_archived": false,
  "status": "running"  // optional filter
}
```

**Output**: `{ "jobs": [ { "id", "title", "status", "created_at", "updated_at" }, ... ] }`

Source: `src/mcp/tools/mother.rs`

---

### `mother.get_job`

Returns a single Mother job by id.

**Input**: `{ "id": "job-id" }`

**Output**: job object or `null`.

Source: `src/mcp/tools/mother.rs`

---

### `mother.tail_log`

Returns the last N lines of a job's log.

**Input**: `{ "id": "job-id", "lines": 50 }` — `lines` max 500.

**Output**: `{ "lines": [ "...", ... ] }`

Source: `src/mcp/tools/mother.rs`

---

### `mother.peek`

Returns a live snapshot of a running job: todo list, recent tool calls, last
assistant text, and any pending await question.

**Input**: `{ "id": "job-id" }`

Source: `src/mcp/tools/mother.rs`

---

### `mother.get_status`

Returns the current Mother status summary.

**Input**: *(none)*

**Output**: `{ "running": 1, "queued": 2, "failed": 0, "awaiting": 1 }`

Source: `src/mcp/tools/mother.rs`

---

### `teri.list_todos`

Returns Teri's active todo list (open, in_progress, blocked items).

**Input**: *(none)*

**Output**: `{ "todos": [ { "id", "text", "status", "created_at" }, ... ] }`

Source: `src/mcp/tools/teri.rs`

---

## Phase 3 — Pane mutations and cross-view dispatch

### `nostromo.set_pane_content`

Set the content of a named pane within a view.

**Input**:
```json
{
  "view_id": "perri",
  "pane_id": "diff",
  "content": { "type": "text", "text": "diff --git ..." }
}
```

Content can also be `{ "type": "json_snapshot", "value": { ... } }`.

**Output**: `{ "ok": true }` or `{ "error": "unknown_view | unknown_pane | not_supported" }`

Source: `src/mcp/tools/set_pane.rs`

---

### `nostromo.set_pane_focus`

Focus a specific pane within a view (also switches the active view tab).

**Input**: `{ "view_id": "perri", "pane_id": "diff" }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/set_pane.rs`

---

### `nostromo.set_pane_layout`

Update a view's pane-split ratios.

**Input**:
```json
{
  "view_id": "perri",
  "ratios": { "top_row": 0.6, "queue": 0.4 }
}
```

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/set_pane.rs`

---

### `nostromo.switch_active_view`

Switch the globally-active Nostromo view tab.

**Input**: `{ "view_id": "mother" }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/switch_view.rs`

---

### `perri.load_pr`

Load a pull request into Perri's diff pane.

**Input**:
```json
{
  "number":     42,
  "repo":       "owner/repo",
  "highlights": "optional review notes"
}
```

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.clear_current_pr`

Clear the currently-loaded PR from Perri's diff pane.

**Input**: *(none)*

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.set_selected_index`

Set the selected PR index in Perri's queue list.

**Input**: `{ "index": 2 }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/perri_mutators.rs`

---

### `mother.enqueue_job`

Enqueue a plan file as a new Mother job.

**Input**: `{ "plan_path": "/absolute/path/to/plan.md" }`

**Output**: `{ "id": "job-id", "title": "Plan title", "status": "queued" }`

Source: `src/mcp/tools/mother_mutators.rs`

---

### `mother.cancel_job`

Cancel a running, queued, or awaiting Mother job.

**Input**: `{ "id": "job-id" }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/mother_mutators.rs`

---

### `mother.archive_job`

Archive a terminal-state Mother job.

**Input**: `{ "id": "job-id" }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/mother_mutators.rs`

---

### `mother.resume_job`

Resume an awaiting Mother job with the operator's answer.

**Input**: `{ "id": "job-id", "answer": "yes, use option B" }`

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/mother_mutators.rs`

---

## Phase 4 — Notifications and status segments

### `nostromo.notify`

Post a transient toast notification to the Nostromo status bar.  The toast
auto-expires after **5 seconds**.

**Input**:
```json
{
  "message": "Build complete ✓",
  "level":   "info",
  "view_id": "cody"
}
```

- `level`: `"info"` (default) | `"warn"` | `"error"`
- `view_id`: optional; informational attribution only (does not filter display)

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/notify.rs`

---

### `nostromo.register_status_segment`

Add or update a named status-bar segment for a view.  The segment is displayed
in the status bar **only when the named view is the active tab**.

**Input**:
```json
{
  "view_id":    "perri",
  "segment_id": "pending_review",
  "text":       "3 PRs",
  "color":      "amber"
}
```

- `color`: named (`red`, `amber`, `sage`, `blue`, `muted`) or 6-digit hex (`#ff8800`).
- Multiple segments for the same view are shown in `segment_id` alphabetical order.

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/status_segment.rs`

---

### `nostromo.clear_status_segment`

Remove a named status-bar segment.

**Input**:
```json
{
  "view_id":    "perri",
  "segment_id": "pending_review"
}
```

**Output**: `{ "ok": true }`

Source: `src/mcp/tools/status_segment.rs`
