# Nostromo MCP — Pane Reference

Phase 3 adds mutation tools that target individual panes within Nostromo views.
This document lists every view, its pane ids, and which `set_pane_content`
payloads each pane accepts or rejects.

---

## Global pane error codes

| Code | Meaning |
|------|---------|
| `unknown_view` | The `view_id` is not registered |
| `unknown_pane` | The `pane_id` is not known for this view |
| `readonly_pane` | Pane is data-driven or PTY-owned; content mutations are not accepted |
| `not_supported` | The view has no `apply_pane_content` implementation for any pane |
| `unsupported_payload` | Pane exists but not for this content type (e.g. JSON snapshot to a text-only pane) |
| `event_loop_timeout` | Main event loop did not reply within 5 s |
| `event_loop_closed` | Event channel was closed (Nostromo is shutting down) |

---

## Views and panes

### `perri` — PR review view

| Pane | `set_pane_content` | Notes |
|------|-------------------|-------|
| `pr_queue` | ❌ `readonly_pane` | Driven by the `perri_queue_rx` watch channel; mutations refused |
| `diff` | ✅ `PaneContent::Text(s)` | Overrides syntect-rendered diff until next `pr_rx` update |
| `diff` | ❌ `unsupported_payload` | `JsonSnapshot` is not accepted |
| `repl` | ❌ `readonly_pane` | PTY-owned |

**Layout ratios** (`set_pane_layout`):

```json
{ "top_row": 0.6, "queue": 0.4 }
```

- `top_row` — fraction of vertical space given to the queue+diff row vs. REPL (0.1–0.9)
- `queue` — fraction of horizontal space given to the PR queue list vs. diff pane (0.1–0.9)

**Perri-specific mutating tools** (Phase 3):

| Tool | Effect |
|------|--------|
| `perri.load_pr({ number, repo, highlights? })` | Writes `current-pr.json` + touches `.dirty` → native watcher fetches PR diff |
| `perri.clear_current_pr()` | Removes `current-pr.json` + touches `.dirty` → diff pane clears |
| `perri.set_selected_index({ index })` | Moves the queue selection cursor |

---

### `fred` — Email + calendar view

| Pane | `set_pane_content` | Notes |
|------|-------------------|-------|
| `mailbox` | ❌ `readonly_pane` | Driven by `fred_mailbox_rx` |
| `calendar` | ❌ `readonly_pane` | Driven by `fred_calendar_rx` |
| `repl` | ❌ `readonly_pane` | PTY-owned |

`set_pane_layout` is not supported for Fred (returns `not_supported`).

---

### `mother` — Job queue view

| Pane | `set_pane_content` | Notes |
|------|-------------------|-------|
| `job_list` | ❌ `readonly_pane` | Driven by `MotherJobs` events |
| `log` | ❌ `readonly_pane` | Async log tail |
| `preview` | ❌ `readonly_pane` | Async plan viewer |

**Mother-specific mutating tools** (Phase 3):

| Tool | Effect |
|------|--------|
| `mother.enqueue_job({ plan_path })` | `mother add --plan <path>` — returns `{ id, title, status }` |
| `mother.cancel_job({ id })` | `mother cancel <id>` |
| `mother.archive_job({ id })` | `mother archive <id>` |
| `mother.resume_job({ id, answer })` | `mother resume <id> <answer>` |

---

### `teri` — Todo list view

| Pane | `set_pane_content` | Notes |
|------|-------------------|-------|
| `todos` | ❌ `readonly_pane` | Driven by `teri_todos_rx` |
| `repl` | ❌ `readonly_pane` | PTY-owned |

---

### `claudia`, `cody`, `kennedy` — Generic agent views

| Pane | `set_pane_content` | Notes |
|------|-------------------|-------|
| `repl` | ❌ `readonly_pane` | PTY-owned |

---

## Global mutation tools

### `nostromo.switch_active_view({ view_id })`

Switches the active tab, calling `blur()` on the previous view and `focus()` on the new one.

### `nostromo.set_pane_focus({ view_id, pane_id })`

Focuses the named view (same as `switch_active_view`; the `pane_id` is recorded for
future sub-pane focus routing in Phase 4).

### `nostromo.set_pane_content({ view_id, pane_id, content })`

Content payload shape:

```json
// Text:
{ "type": "text", "text": "..." }

// JSON snapshot:
{ "type": "json_snapshot", "value": { ... } }
```

### `nostromo.set_pane_layout({ view_id, ratios })`

Ratios are view-specific.  See the per-view sections above for accepted keys.
All ratio values are clamped to `[0.1, 0.9]`.

---

## Phase 4 roadmap

- Fred `mailbox` and `calendar` panes will accept `JsonSnapshot` overrides.
- Teri `todos` will accept `JsonSnapshot` mutations (add/complete items).
- Removing the dirty-file mechanism; replacing with direct push to `pr_rx`.
- Pane-level focus (not just view-level) for multi-pane views.
