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

Returns `{ queue, current_pr, stale, current_pin }`.

`current_pin` (W5 — current-pr-collision) is `{ repo, number }` when a PR is
loaded, else an explicit `null` — always a present key, never omitted, so a
caller can tell "checked, nothing pinned" from "this daemon predates the
field." Today it names the single daemon-wide pin; it is exposed through the
same request-scoped accessor (`pin_for_request`, keyed on the caller's own
focus tag) `nostromo.show`'s `current_pin` error field uses, so both read
identically once per-focus isolation lands.

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

### Live pane-source bindings (live-pane-sources)

The daemon records, per `(view_id, pane_id)`, which server-side `source` (if
any) currently feeds that pane's content. A **bound** pane is kept live in the
background by the daemon — no agent/tool-call involved — whenever the
underlying data changes (see `docs/mcp/panes.md` for the full lifecycle and
the wire-level `freshness` field). The rule of thumb: **a push that came from
fetching `source` binds the pane; a push of content the agent wrote by hand
unbinds it.**

| Tool | Effect on bindings |
|------|--------------------|
| `nostromo.apply_layout` | Binds every pane whose schema entry declares a `source`. Never binds `repl`. |
| `nostromo.refresh_pane_content` | Binds `pane_id` to `source` **and its `params`** (same as `apply_layout`, which binds with no params) — a pane not yet in the tree is silently not bound. |
| `nostromo.set_pane_content` | **Unbinds** the pane — agent-authored content is authoritative from here on, or the next automatic push would silently overwrite it. |
| `perri.load_pr` **with** `highlights` | Unbinds `diff` — highlights are final content. |
| `perri.load_pr` **without** `highlights` | Binds `diff` to `perri.get_current_pr`. |
| `perri.clear_current_pr` | Resolves which of the focus's *live* panes currently hold PR-review content and which hold the queue from the tree and its existing bindings — any pane bound to `perri.get_current_pr`/`perri.get_pr_diff`/`perri.get_pr_conversation` counts as PR content, any pane bound to `perri.list_pr_queue` counts as the queue, and (the one legacy exception) an *unbound* pane literally named `diff`/`queue` counts too, since `perri.load_pr({highlights})` leaves `diff` unbound in a `perri-standard` focus. Only a pane that was unbound gets (re)bound here — a pane already bound to `perri.get_pr_diff`/`perri.get_pr_conversation` (a curated tab) is never repurposed onto a different source. |

Bindings persist across a daemon restart, `params` included; a restarted
daemon repaints every bound pane immediately, with no tool call. The one
exception is `nostromo.get_file` at a revision the local clone doesn't have:
resolving that needs the GitHub contents API, which the synchronous restart
path can't reach, so the pane is skipped rather than repainted with an error.

---

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

### `nostromo.refresh_pane_content`

Refresh one pane's content from a registered server-side data source — the
same closed fetcher registry `nostromo.apply_layout` uses (see
`docs/mcp/panes.md`). Content only: never re-declares geometry, so an
operator's dragged split ratios survive. Use this instead of
`set_pane_content` whenever the data comes from a known source, so the caller
never hand-constructs the content shape.

**Input**:
```json
{
  "view_id": "perri",
  "pane_id": "queue",
  "source": "perri.list_pr_queue",
  "placeholder": "No PR loaded."
}
```

**`params`** (optional, curated-agent-views W2) carries the source's own
arguments and is persisted with the binding, so a daemon restart repaints the
same thing rather than a default:

```json
{
  "view_id": "cody-core-1234",
  "pane_id": "file",
  "source": "nostromo.get_file",
  "params": {
    "path": "src/ipc/session_manager.rs",
    "anchor_line": 412,
    "emphasis": [{ "start": 409, "end": 415 }],
    "reason": "the spawn path CORE-1234 is about"
  }
}
```

Registered sources and their params:

| source | `content_kind` | params |
|--------|----------------|--------|
| `perri.list_pr_queue` | `pr_list` | none |
| `perri.get_current_pr` | `text` | none |
| `perri.get_pr_diff` | `diff` | `{ anchor?, emphasis?, reason? }` — wire-shaped `Anchor`/`Emphasis` |
| `nostromo.get_file` | `code` | `{ path, revision?, anchor_line?, emphasis?, reason? }` |
| `perri.get_pr_conversation` | `pr_conversation` | `{ anchor?, emphasis?, reason? }` — same generic passthrough as `perri.get_pr_diff`; the variant that applies here is `{"kind": "comment", "id": "..."}` |
| `nostromo.get_ticket` | `ticket` | `{ provider, key, anchor?, emphasis?, reason? }` — the variant that applies here is `{"kind": "section", "name": "acceptance_criteria"}` (or `"comment:<n>"`) |

See `docs/mcp/panes.md` for the full `code`/`diff`/`pr_conversation`/`ticket`
payload shapes, revision resolution, and the refusal set. See
`docs/jira-provider.md` for how `nostromo.get_ticket`'s `jira` provider
resolves credentials.

**Output**: `{ "ok": true }` or `{ "error": "...", "detail": "..." }`, where
`detail` is present only for a `ticket` refusal and `error` is one of
`unknown_source`, `fetch_failed`, `invalid_args`, `unidentified_caller`,
`not_supported`, or — for the file/diff/conversation/ticket sources — one of
the refusals `invalid_params`, `unknown_path`, `path_escapes_root`,
`not_utf8`, `anchor_beyond_eof`, `invalid_emphasis_range`,
`unresolvable_revision`, `revision_repo_mismatch` (W5 — current-pr-collision;
see `docs/mcp/panes.md`'s `code` section), `unknown_comment_id` (a `pr_conversation`
anchor/emphasis naming a comment id not present in the fetched conversation),
`unsupported_provider`, `provider_unconfigured`, `unknown_ticket`, or
`unknown_section` (see `docs/mcp/panes.md`'s `ticket` section for what each
means and what `detail` carries for it).

**A refusal never destroys existing pane content.** If the pane already had
content, nothing is broadcast at all; the agent gets the error and the
operator keeps reading. (The exception: a pane this same call just put into
`Loading` does get an `Error`, so it can't stick on a spinner forever.)

Source: `src/mcp/tools/refresh_pane.rs`

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

Load a pull request into Perri's diff pane. Two hosts, different behavior:

- **Daemon (`nostromd`)**: writes `<perri_state_dir>/current-pr.json` +
  touches `current-pr.dirty` (the same file contract `PerriView` writes —
  see `src/data/perri_current_pr.rs`), signals the native PR source's
  refresh channel, and pushes the resolved focus's `diff` pane itself:
  - `highlights` given → that text is pushed as the pane's final content —
    it is never overwritten by a server-rendered summary.
  - `highlights` omitted → pushes `Loading` (first paint only — suppressed if
    `diff` already has content, per the live-pane-sources `Loading` rule
    above), then waits (bounded by a per-daemon settle timeout, default 12s)
    for the refetched snapshot to
    match `(repo, number)`, then pushes the same `Text` summary
    `nostromo.apply_layout`/`nostromo.refresh_pane_content` would render for
    `perri.get_current_pr`. If the wait times out, pushes a
    `"Fetching <repo>#<n>… (still loading)"` placeholder and returns
    `pending: true` — this is success-with-fetch-in-flight, not a failure to
    retry.

  Also moves the daemon's agent-scoped selected index (see
  `perri.set_selected_index`) to this PR's position in the current queue,
  if it's there.

  A pane push that can't be delivered (the resolved focus has no `diff`
  pane, or the caller has no resolvable focus at all) degrades to a
  `warnings` entry rather than failing the call — the file write and the
  refresh signal still happen either way.

- **Standalone TUI**: writes the same file/sentinel through `PerriView`, no
  pane-push/settle/pending behavior (the TUI's own render loop already
  reads `current-pr.json`'s watch channel every frame).

**Input**:
```json
{
  "number":     42,
  "repo":       "owner/repo",
  "highlights": "optional review notes",
  "view_id":    "optional — daemon-hosted only; omit to target the caller's own focus"
}
```

**Output**: `{ "ok": true }`, or `{ "ok": true, "pending": true, "detail": "..." }` (daemon, settle timeout), optionally with a `warnings` array.

**Errors**: `invalid_args` (missing/zero `number`, missing/empty `repo`, or a repo slug outside `owner/repo` form / `[A-Za-z0-9._-]`), `not_supported` (daemon only — Perri's state dir isn't configured), `io_error`, `event_loop_closed` / `event_loop_timeout` (TUI only — the daemon path never hits these; that's the bug this tool used to have).

Source: `src/mcp/tools/perri_mutators.rs`, `src/data/perri_current_pr.rs`

---

### `perri.clear_current_pr`

Clear the currently-loaded PR from every pane that's showing it — whichever
layout template built the focus, and whatever those panes happen to be named.

- **Daemon**: removes `current-pr.json` (a no-op, not an error, if it's
  already absent), touches both `current-pr.dirty` and `queue.dirty`,
  signals both native sources' refresh channels, then closes every curated
  review tab whose PR just stopped being under review (same teardown
  `perri.load_pr` triggers on a PR change — a no-op for a focus with no
  curated regions, e.g. one still driving `perri-standard`). It then resolves
  the focus's *remaining* live panes into "holds PR content" vs. "holds the
  queue" (see the bindings table above) and, for each: a PR-content pane gets
  `"No PR loaded."` pushed (rebinding it to `perri.get_current_pr` first, but
  only if it wasn't already bound to something else); a queue pane gets
  `Loading` (first paint only — same suppression rule) then the current
  PR-queue list (via the same fetcher `nostromo.apply_layout` uses), fetched
  once and pushed to every queue pane found.
- **Standalone TUI**: removes the file/touches the sentinel via `PerriView`
  only — no pane pushes.

**Input**: `{ "view_id": "optional — daemon-hosted only" }`

**Output**: `{ "ok": true, "cleared": ["<pane ids pushed the no-PR placeholder>"], "queue": ["<pane ids refreshed with the queue>"], "closed": ["<pane ids the curated teardown closed>"] }`, optionally with a `warnings` array (daemon).

**Errors**: `not_supported` (daemon only), `io_error`, `event_loop_closed` / `event_loop_timeout` (TUI only).

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.set_selected_index`

Set the selected PR index in Perri's queue list, clamped to the current
queue length (`0` when the queue is empty).

- **Daemon**: an **agent-scoped, in-memory** index
  (`DaemonMcpBackend::perri.selected_index`) — bookkeeping only. It moves no
  GUI highlight; there is no wire/client concept of "selected row" yet (a
  follow-up, not covered by this tool).
- **Standalone TUI**: moves `PerriView`'s own selection — the same state
  keyboard navigation moves, so it does visibly move the highlighted row.

**Input**: `{ "index": 2 }`

**Output**: `{ "ok": true }`

**Errors**: `invalid_args` (missing/non-integer `index`), `event_loop_closed` / `event_loop_timeout` (TUI only).

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.get_selected_index`

Returns the selected PR index — see `perri.set_selected_index` for what
"selected" means on each host. Newly registered by this fix: the handler
existed but had no `tool_descriptors()` entry or `dispatch()` arm, so it was
unreachable on **either** host.

**Input**: *(none)*

**Output**: `{ "index": 0 }`

**Errors**: `event_loop_closed` / `event_loop_timeout` (TUI only).

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

**Distinct from `ServerMsg::Notification` (W5 — current-pr-collision).** This
tool's toast is a *TUI* status-bar affordance, routed through
`state.event_tx`, whose receiver the daemon deliberately drops — so on the
daemon-hosted path this always returns `{"error":"event_loop_gone"}`. A
separate, daemon → GUI wire message, `ServerMsg::Notification { tag, level,
message }`, exists end to end (daemon variant, `Topic::Layout` gate, macOS
client decode, toast rendering) as of W5, but currently has **no production
caller** — it was landed as reusable transport for a same-PR advisory that a
later wedge (W9) wires the first real trigger for. `level` there is
`info`/`warning`/`alert` (mirroring macOS's `ToastSeverity`), a different
vocabulary than this tool's own `info`/`warn`/`error` — the two are
unrelated, not a typo.

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

---

## Decision modals (W6)

### `nostromo.ask_decision`

Pose a decision as a modal over the window and **block** until the operator
answers, dismisses it, or the call times out. This is **not a content
channel**: there is no free-form content field anywhere in the input — only a
bounded `prompt`, an optional bounded `detail` string, and 2 or more labelled
choices. An agent that wants to show something has the raw pane tools (or a
future curated `nostromo.show`); this tool can only ask.

Daemon-hosted only — the standalone TUI MCP server has no window to attach a
sheet to.

**Input**:
```json
{
  "prompt":  "Ship it?",
  "detail":  "This touches the production migration.",
  "choices": [
    { "id": "approve", "label": "Approve" },
    { "id": "reject",  "label": "Reject",  "detail": "Block the merge" }
  ],
  "context_pane_id": "diff",
  "view_id":         "perri",
  "timeout_secs":    300
}
```

- `choices`: 2 or more; each `id` must be non-empty and unique within the
  call, each `label` non-empty and ≤ 200 chars. `prompt`/`detail`/choice
  `detail` are each capped at 2000 chars.
- `context_pane_id`: optional *reference* to a pane already showing relevant
  context — never content itself.
- `view_id`: optional; omit to target the caller's own focus.
- `timeout_secs`: optional, default 300, capped at 3600.

**Output**:
- `{ "ok": true, "choice_id": "approve" }` — the operator picked an option.
- `{ "ok": true, "outcome": "dismissed" }` — dismissed without choosing. A
  distinct outcome, not a default choice and not a hang.
- `{ "error": "invalid_args" }` — fewer than two choices, duplicate choice
  ids, or an empty/over-long prompt, detail, or label.
- `{ "error": "no_operator" }` — no connected client counts as an operator.
  A client counts as an operator iff it named `"decision"` explicitly in its
  subscribed topics, or set `renders_decisions: true` on its `Subscribe`
  frame — either is a claim that it can actually present the request to a
  human and answer it. A client that merely subscribed to everything
  (`topics: []`) does **not** count until it declares
  `renders_decisions: true`, even though it still receives `decision_request`
  broadcasts like any other subscriber. As of `ios-curated-view-parity` W3,
  iOS presents and answers decisions and subscribes with
  `renders_decisions: true` — a phone-only setup (no Mac connected) is now a
  valid operator and `ask_decision` no longer fails fast or times out on it.
  Returned **immediately** rather than blocking for the full timeout — an
  agent blocking on a closed GUI for minutes is a worse failure than a fast
  refusal.
- `{ "error": "timeout" }` — nobody answered within `timeout_secs`.
- `{ "error": "cancelled" }` — the asking session died while this call was
  outstanding.
- `{ "error": "not_supported" }` — TUI-hosted only.

**Queueing.** At most one outstanding request per focus tag is ever on the
wire at a time. A second `ask_decision` call for the same tag while the first
is still outstanding queues FIFO behind it and is broadcast only once the
first resolves — both calls are eventually answered, neither is dropped or
stacked.

**Answer-once.** A decision can be answered exactly once, enforced daemon-side
by `DecisionRegistry` (a second answer for an already-resolved `request_id` is
logged and never forwarded to the waiting caller) *and* client-side by each
client's own `DecisionStore` (macOS: `macOS/Nostromo/UI/DecisionStore.swift`;
iOS/shared: `Shared/NostromoKit/Sources/NostromoKit/Store/DecisionStore.swift`),
which holds resolved state outside the presenting view so a reconstructed
sheet for the same request can never re-arm and send twice — the same class
of bug `TurnInteractionStore` exists to prevent for `AskQuestionView`.

**iOS (`ios-curated-view-parity` W3).** iOS presents a modal sheet above its
root tab view — never from a region or focus view, so answering a decision
never changes which tab the operator is on — naming the prompt, the optional
detail, the display name of the focus that asked (falling back to the raw
tag if unknown), and one control per choice showing that choice's own
optional `detail`. Answering takes exactly one tap: unlike the queue's
swipe-to-approve, there is no confirmation dialog, because the modal itself
already interrupted the operator with the full context of what they're
choosing. `DaemonStore.pendingDecisions` is a queue, not a slot — the daemon
allows one active request per focus tag, so two different focuses can each
have a decision outstanding at once, and both are eventually presented and
answered, oldest first. A request this client has already answered, or that
the daemon reports resolved elsewhere (`decision_resolved`), renders as
already-answered rather than as a live prompt with inert controls, and a
system-initiated close (superseded by an answer elsewhere, or by that
notice) sends no `decision_answer` frame at all.

**Presented once, app-wide; resolves everywhere.** Nostromo can open one
window per attached display, but a decision is never presented more than
once: `DecisionPresenter` is the sole app-wide subscriber to
`decision_request` broadcasts and shows the sheet on exactly one window (the
operator's key window, falling back to the main window, then the first
visible one). Answering or dismissing it on that window closes it everywhere
else too — no second sheet is left behind on any other window, and no
operator action is required anywhere but the one window they used. This does
not change the `dismissed` / `timeout` outcome mapping above, or the
`timeout_secs` default/cap; it only fixes where and how many times the modal
appears and disappears.

`ServerMsg::DecisionResolved` is the wire notice behind this:

```json
{
  "type":       "decision_resolved",
  "tag":        "mother",
  "request_id": "...",
  "resolution": "answered",
  "choice_id":  "approve"
}
```

- `resolution` is one of `"answered"`, `"dismissed"`, `"timeout"`, or
  `"cancelled"` (the last for a session cancelled while the request was
  outstanding). `choice_id` is present only when `resolution == "answered"`;
  omitted from the wire entirely otherwise (never sent as `null`).
- Broadcast exactly once per resolved `request_id`, gated on `Topic::Decision`
  like `decision_request`, from whichever of `answer` / `timeout_request` /
  `cancel_tag` actually resolved it. A second answer attempt
  (`AlreadyAnswered`) or an answer for an unknown id (`UnknownRequest`)
  broadcasts nothing.
- A client that receives it for a sheet it still has on screen closes that
  sheet **without** sending any `decision_answer` frame — a system-initiated
  close (superseded by an answer elsewhere, or by this notice) must never be
  mistaken for an operator dismissal.

**Not wired to `ServerMsg::SessionPermissionRequest`.** That transport stays
unhandled and `ClientMsg::SessionAnswerPermission` stays a no-op — they were
this feature's shape precedent, not its mechanism. Wiring the permission path
means deciding a permission posture, which is a different feature.

Source: `src/mcp/tools/ask_decision.rs`, `src/ipc/decisions.rs`, `src/ipc/protocol.rs`
(`ServerMsg::DecisionResolved`), `macOS/Nostromo/UI/DecisionPresenter.swift`,
`macOS/Nostromo/UI/DecisionStore.swift`, `Shared/NostromoKit/Sources/NostromoKit/Store/DecisionStore.swift`,
`Shared/NostromoKit/Sources/NostromoKit/Store/DaemonStore.swift`,
`iOS/Nostromo/Views/DecisionSheetView.swift`, `iOS/Nostromo/NostromoApp.swift`

---

## Phase 5 — The curated view surface (curated-agent-views W5)

`nostromo.show` is the deliberate, attention-directing surface: one tool, a
closed vocabulary of five view types, and a deterministic placement engine
(`src/mcp/views/`) that decides where each view lands with no LLM inference
in the decision itself. This is where the PRD's central reversal lands:
`set_pane_content`, `set_pane_layout`, `set_pane_focus`, `create_pane`,
`reset_panes`, `apply_layout`, and `refresh_pane_content` become
implementation details this layer uses internally, rather than tools an
interactive agent reaches for directly. See `docs/mcp/panes.md`'s "Placement
rules" section for the engine's rules (R1–R8) and `docs/mcp/agent-layout.md`
for the curated flow this replaces.

### `nostromo.show`

**Input**:

| field | type | required | notes |
|---|---|---|---|
| `type` | string enum | yes | one of `review_queue`, `pr_conversation`, `pr_diff`, `file`, `ticket`. `activity` is a real view in the PRD's vocabulary but is refused here with its own code — it is populated only by the ambient path (W7), and an agent cannot push into it. Anything else is `unknown_view_type`, and the refusal names every valid type. |
| `target` | object | depends on `type` | omitted for `review_queue` (a stray one is tolerated, not refused); required and shape-checked for the other four — see the table below. |
| `anchor` | object | no | where to scroll on arrival — one `Anchor` payload (see `docs/mcp/panes.md`'s `PaneAddress` section for the wire type). |
| `emphasis` | array | no | zero or more `Emphasis` payloads to mark as significant. |
| `reason` | string | no | one short phrase shown with the view. Blank/whitespace-only is dropped rather than shown as an empty caption. |
| `view_id` | string | no | target focus tag; defaults to the caller's own focus (resolved from the `Hello` `pty_id`). A caller with no resolvable tag and no explicit `view_id` gets `unidentified_caller`. |

Targets, and the anchor/emphasis kinds each type's own source acts on:

| `type` | `target` | anchor kind | emphasis kind |
|---|---|---|---|
| `review_queue` | *(none)* | `{kind:"queue_row", repo, number}` | `{kind:"queue_row", repo, number}` |
| `pr_conversation` | `{repo, number}` | `{kind:"comment", id}` | `{kind:"comment", id}` |
| `pr_diff` | `{repo, number}` | `{kind:"line", path?, line}` | `{kind:"line_range", path?, start, end}` |
| `file` | `{path, revision?}` | `{kind:"line", line}` | `{kind:"line_range", start, end}` |
| `ticket` | `{provider, key}` | `{kind:"section", name}` (`name` may be `"comment:<n>"`) | `{kind:"section", name}` |

`repo` must parse as `owner/name` — validated by the same slug check
`perri.load_pr` uses, so there is one repo-slug validator, not two that could
disagree. `revision` on `file` is part of the view's *identity*, not just its
addressing: `{path: "a.rs"}` and `{path: "a.rs", revision: "abc"}` are two
different tabs, and re-showing the bare form later never touches the pinned
one.

**Only `file` actually enforces that an anchor/emphasis is the right kind for
the view.** Its adapter (`source_params` in `show.rs`) translates the uniform
payload into `nostromo.get_file`'s own bare `anchor_line`/`{start, end}`
dialect, and a `comment`/`section`/`queue_row` anchor or a non-`line_range`
emphasis is refused as `invalid_anchor`/`invalid_emphasis` before anything is
touched. For the other four types, `nostromo.show` forwards the anchor and
emphasis objects to the underlying source **verbatim**, with no kind check at
this layer — a `{kind:"line"}` anchor sent to a `ticket` show, for instance,
is accepted by `show` and simply has no effect, because `ticket`'s renderer
only ever pattern-matches `Anchor::Section` and silently ignores anything
else (this is deliberately covered by
`validate_comment_ids_ignores_a_non_comment_anchor_or_emphasis_kind` in
`apply_layout.rs`, for the equivalent `pr_conversation` case). A payload of
the *right* kind that names something that doesn't resolve is still refused,
downstream, as its own fetch-level error (`unknown_comment_id`,
`unknown_section`) — see below.

**Output** (success):

```json
{
  "ok": true,
  "region": "detail",
  "pane_id": "detail.2",
  "label": "session_manager.rs",
  "tab_index": 1,
  "reused": false,
  "frontmost": true,
  "evicted": null,
  "closed": []
}
```

- `region` / `pane_id` — where the view landed, so the agent can refer to it
  ("the File tab") in conversation rather than guessing.
- `label` / `tab_index` — the tab's caption and its position among its
  region's tabs, left to right.
- `reused` — `true` when an already-open tab of the same `(type, identity)`
  was re-anchored rather than a new tab being opened (R2).
- `frontmost` — always `true`. A deliberate show takes focus unconditionally,
  whether the tab is new or reused (R5 — see `docs/mcp/panes.md`).
- `evicted` — the pane id R4's cap eviction closed to make room, or `null`.
- `closed` — the pane ids R8 closed because this show named a PR other than
  the one that was under review. Always `[]` outside that trigger, and
  disjoint from `evicted` — the two are different reasons a tab goes away.

**Errors**:

| `error` | Meaning |
|---|---|
| `unknown_view_type` | `type` is missing or outside the closed vocabulary. `detail` names every valid type. |
| `activity_not_pushable` | `type: "activity"` — a real view, populated only by the ambient path (W7); `detail` also names the valid types. |
| `invalid_target` | `target` was absent or the wrong shape for this `type`, including a malformed `repo` slug. |
| `invalid_anchor` | `anchor` was present but the wrong kind for this view (`file` only — see above), or failed to deserialize as an `Anchor` at all. |
| `invalid_emphasis` | An `emphasis` entry was the wrong kind for this view, `emphasis` wasn't an array, or an entry failed to deserialize as an `Emphasis`. |
| `unknown_region` | `views.yaml` (compiled-in or override) names no such region for this view's type — only reachable through a broken override. |
| `region_not_tabbed` | The view's home region already holds a *different* view and isn't tabbed (the queue region, in the compiled-in rules — R1). |
| `region_not_creatable` | The view's home region doesn't exist yet, and none of its `create` candidates in `views.yaml` names a pane currently live in this focus. |
| `pane_id_taken` | Creating a non-tabbed region would need a pane id something else in this focus already holds. |
| `invalid_views_config` | `views.yaml` (compiled-in or override) is malformed. |
| `unknown_source` / `fetch_failed` | The view's underlying fetcher isn't in the closed registry, or ran but failed — the same codes `apply_layout`/`refresh_pane_content` surface. |
| `invalid_params` / `unknown_path` / `path_escapes_root` / `not_utf8` / `anchor_beyond_eof` / `invalid_emphasis_range` / `unresolvable_revision` / `revision_repo_mismatch` | `file`'s fetch-level refusals (`FileSourceError`) — see `docs/mcp/panes.md`'s `code`/`diff` section. `revision_repo_mismatch` (W5 — current-pr-collision) is a request that resolved to a revision only a PR pinned to a *different* repo than the caller's own working directory could serve — refused rather than silently rendering that foreign repo's content. |
| `unknown_comment_id` | A `pr_conversation` anchor/emphasis named a comment id absent from the fetched conversation. |
| `unsupported_provider` / `provider_unconfigured` / `unknown_ticket` / `unknown_section` | `ticket`'s fetch-level refusals — see `docs/mcp/panes.md`'s `ticket` section. |
| `not_supported` | Called against a non-daemon-hosted MCP server. |
| `unidentified_caller` | No `view_id` and no caller `pty_id` to target. |
| `unknown_view` | The resolved focus was removed from the registry between placement and mutation — a race, not a normal path. |
| `concurrent_modification` | The view's layout changed (a concurrent `nostromo.show`, `perri.load_pr`, or `perri.clear_current_pr` targeting the same focus) between this call's placement decision and its mutation — a race, not a normal path. The layout is left exactly as that other call left it; retry. |

**`current_pin` (W5 — current-pr-collision).** A `file` fetch-level refusal
(any of the `FileSourceError` codes above) additionally carries
`current_pin: { repo, number }` on the error payload when the request's
`revision` was omitted (an implicit revision) *and* a PR is currently pinned
— e.g. `{"error": "unknown_path", "detail": "...", "current_pin": {"repo":
"acme/ops", "number": 42}}`. This is scoped narrowly: an explicit `revision`
never carries it (the caller already named exactly what it asked for), no
other view type ever carries it, and with no PR pinned the key is absent
entirely (never `null`) — a bare refusal is unchanged from before W5. The
point is telling an agent *why* an otherwise-ordinary-looking refusal just
happened: a second, independent session pinning a different PR mid-review.

Every refusal from `unknown_view_type` through `invalid_views_config` happens
**before** the fetch and leaves the focus's layout byte-identical, broadcasting
nothing: validate → place → fetch → mutate → broadcast, in that order,
specifically so a bad show can never destroy what the operator was reading. A
fetch-level refusal follows the same discipline for every code that names
something the *caller* got wrong (`invalid_params`, `unknown_path`, …,
`unknown_comment_id`, and every `ticket` refusal except its own
`fetch_failed`); a bare `fetch_failed` means the source itself is broken and
stays loud.

**Example** — three shows in one review, starting from `perri-curated`'s bare
`queue` + `repl` tree:

Show a PR's diff — no `detail` region exists yet, so this call also creates
it (splitting `queue`, `[0.5, 0.5]`, per `views.yaml`'s first `create`
candidate):
```json
{ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } }
```
```json
{ "ok": true, "region": "detail", "pane_id": "detail.0", "label": "Diff",
  "tab_index": 0, "reused": false, "frontmost": true, "evicted": null, "closed": [] }
```

Point at a file, anchored and emphasised, with a reason:
```json
{
  "type": "file",
  "target": { "path": "src/ipc/session_manager.rs" },
  "anchor": { "kind": "line", "line": 412 },
  "emphasis": [ { "kind": "line_range", "start": 409, "end": 415 } ],
  "reason": "the spawn path this PR touches"
}
```
```json
{ "ok": true, "region": "detail", "pane_id": "detail.1", "label": "session_manager.rs",
  "tab_index": 1, "reused": false, "frontmost": true, "evicted": null, "closed": [] }
```

Point at the same file at a different line — one tab, re-anchored, not a
second tab (R2):
```json
{
  "type": "file",
  "target": { "path": "src/ipc/session_manager.rs" },
  "anchor": { "kind": "line", "line": 88 }
}
```
```json
{ "ok": true, "region": "detail", "pane_id": "detail.1", "label": "session_manager.rs",
  "tab_index": 1, "reused": true, "frontmost": true, "evicted": null, "closed": [] }
```

Source: `src/mcp/tools/show.rs`, `src/mcp/views/`.

---

### Per-caller tool withdrawal

The MCP tool surface is flat by default: `tools/list` returns the same list
to every caller, and `tools/call` will run any of them for anyone.
`~/.nostromo/tool-policy.yaml` narrows that per caller — an operator-written
denylist, not a compiled-in restriction.

**Keyed on the agent name, not the tag.** A caller's identity arrives as the
`Hello` frame's `pty_id`, which in the daemon *is* the focus tag. The policy
doesn't match the tag directly; it resolves the tag to an `agent_name`
through the focus registry — the same lookup `nostromo.get_self` already
does — so a policy that says `perri` covers a dispatched focus like
`perri-a1b2c3d4`, with no prefix-matching hack.

**Both `tools/list` and `tools/call` consult it.** Filtering `tools/list`
alone is advisory — an agent can call a tool name it never saw in the list,
and a drifting prompt will. `tools/call`'s gate, at the top of
`dispatch_inner` (`src/mcp/tools/mod.rs`), is the half that actually holds;
the list filter only stops the tool being *suggested* in the first place.

**A denied `tools/call` gets its own JSON-RPC error code, `-32001`**
(`TOOL_FORBIDDEN_CODE`, `src/mcp/server.rs`), deliberately not `-32601`
("Method not found"): the two mean different things to the calling agent.
`-32601` says "no such tool" — a fact an agent would reasonably read as a
daemon bug and retry. `-32001` says "this tool exists and works, but the
operator's policy withdraws it from you" — a fact the agent can act on (stop
reaching for it) instead of retrying against.

**Unresolved callers, and a policy that fails to load cleanly, both fail
open.** An absent or malformed `tool-policy.yaml` parses as the empty policy
(denies nothing) rather than an error. A caller with no `Hello` `pty_id`, or a
tag the focus registry doesn't recognise, gets the unfiltered surface. The
threat model here is a prompt drifting onto a withdrawn tool, not an
adversary — the alternative, failing closed, would mean a daemon-registry
hiccup silently disarming every agent's tool surface at once.

**The shipped default is empty — every deployment starts unarmed.**
`ToolPolicy::default()` denies nothing to anyone, and that is what ships
until an operator writes `~/.nostromo/tool-policy.yaml`. This is deliberate:
Perri's prompt (`~/.claude/agents/perri.md`, a different repository) still
drives `apply_layout` and `refresh_pane_content` directly today, and
withdrawing those tools in the same change that adds `nostromo.show` would
break her review flow the moment this wedge merged, before her prompt was
rewritten to use `show` instead. **W8 is what arms it** — it is expected to
write the policy below to disk and rewrite the prompt in the same change, so
the withdrawal and its replacement land together. Until then, this
mechanism, its policy model, and its tests exist and are exercised by tests
that inject a policy directly, not by anything on disk.

The policy W8 is expected to install, `INTENDED_PERRI_POLICY`
(`src/mcp/tool_policy.rs`) — documented in the mechanism's own module so the
two can't drift apart:

```yaml
agents:
  perri:
    deny:
      - nostromo.set_pane_content
      - nostromo.set_pane_layout
      - nostromo.set_pane_focus
      - nostromo.create_pane
      - nostromo.reset_panes
      - nostromo.apply_layout
      - nostromo.refresh_pane_content
```

Every other caller — Mother, Fred, Teri, Cody, and anyone else the policy
doesn't name — sees a `tools/list` byte-for-byte identical to what it always
returned, whether or not this policy is armed for Perri.

Source: `src/mcp/tool_policy.rs`, `src/mcp/server.rs` (`TOOL_FORBIDDEN_CODE`),
`src/mcp/tools/mod.rs` (`tool_descriptors_for`, the `dispatch_inner` gate).
