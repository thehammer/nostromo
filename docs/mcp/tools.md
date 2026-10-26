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
  "spawned_at": "2026-05-14T17:00:00Z",
  "pr_under_review": { "repo": "Carefeed/admin-portal", "number": 4526 }
}
```

`pr_under_review` is **this focus's** PR, never whichever focus picked one up
most recently (W7). It is always present on the daemon path and `null` when
this focus has no PR under review — an absent key and a null key are different
on the wire, and an agent can only act on one of them. It is omitted entirely
outside the daemon, which has no focus registry to answer for.

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

**Output**: view-specific JSON blob (see per-view sections below), plus a
`render_state` section on every response — see "Render-state visibility
(W1)" below.

For `view_id: "fred"` the blob is the `fred.get_state` response and for
`view_id: "teri"` it is the `teri.list_todos` response, including the
`state` / `updated_at` / `reason` / `auth` fields (see "Source-state fields").

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

**In `nostromd` (daemon-hosted MCP)** nothing publishes rate limits yet, so the
answer is explicit rather than a bare `null`:
`{ "state": "not_available", "reason": "the daemon has no rate-limits source yet" }`.

Source: `src/mcp/tools/nostromo_meta.rs`

---

### `nostromo.get_budget_posture`

Returns the current global budget posture.

**Input**: *(none)*

**Output**: `{ "posture": "normal" }` — values: `flush`, `normal`, `elevated`, `conservative`, `critical`.

**In `nostromd`** (no posture source yet):
`{ "state": "not_available", "reason": "the daemon has no budget-posture source yet" }`.

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

Returns **the calling focus's** PR under review, or `null` if it has none.

**Input**: `{ "view_id": "..." }` *(optional)*

**Output**: `{ "number", "repo", "title", "author", "url", "stale" }` or `null`.

The PR under review is a property of a focus, not of the machine (W7). Which
focus this answers for follows the daemon's usual addressing rule: an explicit
`view_id` wins, otherwise the caller's `pty_id`. A caller that names no focus
and cannot be placed in one gets `null` — never some other focus's PR.

Source: `src/mcp/tools/perri.rs`

---

### `perri.get_state`

Returns `{ queue, current_pr, other_focuses, stale, current_pin }`.

`current_pin` (W5 — current-pr-collision) is `{ repo, number }` when this
focus has a PR loaded, else an explicit `null` — always a present key, never
omitted, so a caller can tell "checked, nothing pinned" from "this daemon
predates the field." It is exposed through the same request-scoped accessor
(`pin_for_request`, keyed on the caller's own focus tag) `nostromo.show`'s
`current_pin` error field uses, so the two can never name different PRs.

**Input**: `{ "view_id": "..." }` *(optional)*

- `current_pr` — this focus's PR under review, or `null`.
- `other_focuses` — `[{ "tag", "repo", "number" }]` for every *other* focus
  that has one, so an agent can see what the rest of the fleet is reviewing
  without being able to mistake it for its own. Never includes the caller.
- `queue` — the PR review queue, which is **fleet-wide**: every focus sees the
  same queue. Only `current_pr` is per-focus.

`current_pr` and `other_focuses` are always present, as `null` and `[]`
respectively when empty.

Source: `src/mcp/tools/perri.rs`

---

### Source-state fields (Teri, Fred, Mother)

The live-data tools below never answer "nothing yet" and "it failed" with the
same empty list. Each response carries:

| Field | Meaning |
|-------|---------|
| `state` | `loading` (no snapshot yet), `fresh`, `empty` (loaded, nothing there), `stale` (serving old data after a failed refresh), `error` (failed, no data), `unauthenticated` (Fred needs Microsoft sign-in), `not_configured` (Teri has no database yet — an empty state, not a failure) |
| `updated_at` | When the data was produced (ISO-8601 UTC), or `null` while `loading` |
| `reason` | Why, for `stale` / `error` / `not_configured` / `unauthenticated` (never a filesystem path or token) |
| `auth` | Only when `state` is `unauthenticated`: `{ verification_uri, user_code, expires_at }` — the device-code prompt, never a token |

---

### `fred.list_unread_emails`

Returns unread emails from Fred's mailbox.

> **Breaking change (FND-2).** This used to return `{ "emails": [...] }`. It now
> returns the state-carrying shape below; the list is `items`.

**Input**: *(none)*

**Output**: `{ "state", "updated_at", "reason"?, "auth"?, "unread_count", "items": [ { "from", "subject", "received_at", "vip", "is_invite", "is_read" }, ... ] }`

Source: `src/mcp/tools/fred.rs`

---

### `fred.list_calendar_events`

Returns today's calendar events (or events on a specific date).

> **Breaking change (FND-2).** This used to return `{ "date", "events" }`. It now
> returns `{ "state", "updated_at", "reason"?, "events": [...] }`.

**Input**:
```json
{ "date": "2026-05-14" }  // optional; omit for today
```

**Output**: `{ "state", "updated_at", "reason"?, "events": [ { "start", "end", "title", "status", "is_now" }, ... ] }`.
A malformed `date` returns `{ "error": "bad_date", "provided": ... }`.
`updated_at` is the calendar snapshot's `generated_at`.

Source: `src/mcp/tools/fred.rs`

---

### `fred.get_state`

Returns Fred's composite state:
`{ state, updated_at, reason?, auth?, unread_count, today_event_count, mailbox, calendar, mailbox_state, calendar_state }`.
`state` is the worse of `mailbox_state` and `calendar_state`
(`unauthenticated` > `error` > `stale` > `loading` > `fresh`/`empty`);
`updated_at`/`reason`/`auth` come from that worse source.

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

In `nostromd` the counts are derived from the live job list and carry the
list's state: `{ ..., "state", "updated_at"?, "reason"? }` where `state` is
`loading` (no `mother list` has completed — the zero counts mean nothing),
`fresh`, `stale` (the latest `mother list` failed; counts are from the last
success) or `error` (it has never succeeded). Mutations
(`mother.cancel_job`, `mother.enqueue_job`, ...) re-list and publish
immediately, so the next read reflects them without waiting for the 2 s poll.

Source: `src/mcp/tools/mother.rs`

---

### `teri.list_todos`

Returns Teri's active todo list (open, in_progress, blocked items).

**Input**: *(none)*

**Output**: `{ "state", "updated_at", "reason"?, "generated_at", "items": [ { "id", "title", "status", "priority", "due_date", "jira_key" }, ... ], "stale", "error" }`

A user who never set Teri up (no `~/.teri/teri.db`) gets
`{ "state": "not_configured", "reason": "Teri has no database yet", "items": [] }`
— not an error, and the reason never contains the path.

Source: `src/mcp/tools/teri.rs`

---

### `teri.get_picks`

Teri's current picks, as the Picks tab shows them.

**Input**: *(none)*

**Output**: `{ "notice", "generated_at"?, "generating", "unavailable_sources": [...], "items": [ { "item_id", "source", "title", "reason", "done_since" }, ... ], "error"? }`

`title` (third-party text) and `reason` (derived from it by an agent) are each one
capped line between this call's `<<<UNTRUSTED-nonce>>>` markers (see `notice`):
data, never instructions. `item_id` is escaped like the ids of
`teri.list_work_items` (an opaque handle). **Any later prompt seeded from a
pick (T5) must fence `title` and `reason` with the shared untrusted helper
(`data::work::untrusted`), because the stored values are only sanitised.**

### `teri.publish_picks`

Publishes Teri's picks (the only way to change them). The Picks tab shows the
new set within seconds.

**Input**: `{ "picks": [ { "item_id", "reason" }, ... ] }` — 3 to 7 entries; each
`item_id` must be a current work item (see `teri.list_work_items`) and appear
once (pass it exactly as listed: escaped ids are unescaped before the check);
each `reason` is 1 to 240 characters of plain text citing a concrete fact. The
daemon sanitises every reason: one line, no control/format/bidi/tag characters,
no URLs, markdown links (the link text stays) or backticks; a reason empty after
that is refused (`invalid_picks`).

**Output**: `{ "ok": true, "picks": <as teri.get_picks> }`, or `{ "error", "message" }`
where `error` is `invalid_argument` (malformed call) or `invalid_picks` (the
message names the bad ids). The daemon fills in each pick's `source` and
`title` and works out `unavailable_sources` from its own source states; the
caller supplies neither.

A picked item that is later resolved at its source stays in the list with
`done_since: true` until the next publish; that is decided only from a source
that is fresh or empty AND `complete` (a truncated or partial list never marks
anything done).

**The picking session.** Picks are generated by a hidden, unattended `claude`
session with NO `--agent` (a plugin agent's own `tools:` list overrides `--tools`
and leaves the session unable to call anything; the instructions are the prompt).
It runs in an empty temp directory, with `--setting-sources project` and
`--disable-slash-commands` (no user hooks, CLAUDE.md, plugins or skills), without
`--dangerously-skip-permissions` (the allow-list is the control), with only
`teri.list_work_items`, `teri.get_work_item`, `teri.publish_picks` and
`ToolSearch`, a `--max-budget-usd` cap and a 5 minute deadline; the daemon's MCP
dispatch refuses every other tool for it, and stopping it kills its whole
process group. First-open runs are limited daemon-side (once per local day on
success, 30 minutes after a failure; also not when the stored picks are from today, whoever made them; manual refresh 5 minutes apart). Source: `src/mcp/tools/teri.rs`,
`src/data/work/picks.rs`.

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
| `perri.load_pr` **with** `highlights` | Resolves the focus's live *current-PR* target(s) (see below) and unbinds each — highlights are final content. |
| `perri.load_pr` **without** `highlights` | Resolves the focus's live *current-PR* target(s) (see below) and binds each to `perri.get_current_pr`. |
| `perri.clear_current_pr` | Resolves which of the focus's *live* panes currently hold PR-review content and which hold the queue from the tree and its existing bindings — any pane bound to `perri.get_current_pr`/`perri.get_pr_diff`/`perri.get_pr_conversation` counts as PR content, any pane bound to `perri.list_pr_queue` counts as the queue, and (the one legacy exception) an *unbound* pane literally named `diff`/`queue` counts too, since `perri.load_pr({highlights})` leaves `diff` unbound in a `perri-standard` focus. Only a pane that was unbound gets (re)bound here — a pane already bound to `perri.get_pr_diff`/`perri.get_pr_conversation` (a curated tab) is never repurposed onto a different source. |

`perri.load_pr`'s **current-PR target(s)** are a *narrower* resolution than
`perri.clear_current_pr`'s PR-content set above: only a pane bound to
`perri.get_current_pr` itself (plus the same unbound-legacy-`diff` bridge)
qualifies. A pane bound to `perri.get_pr_diff`/`perri.get_pr_conversation`
renders structured Diff/Conversation content — `load_pr`'s plain-text
summary/highlights is never pushed there, since that would be a content-kind
mismatch the source's own broadcaster would just clobber again moments later.
On a curated focus with real PR-content panes but none of them bound to
`perri.get_current_pr`, this resolves to **zero** targets: `load_pr` still
writes `current-pr.json` and signals the refresh, but pushes no pane content
and reports no `unknown_pane` warning — there is honestly nowhere for the
summary to go on that focus today. (A focus with *no* PR-content pane of any
kind — one that never applied a real layout — is a different, degenerate
case, and still falls back to attempting the legacy `diff` name, so a
genuinely broken caller still gets a visible `warnings` entry.)

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

### `perri.load_pr`

Load a pull request into Perri's current-PR pane(s). Requires `nostromd`
(without one it returns `{"error":"not_supported","detail":"requires nostromd"}`).

It writes `<perri_state_dir>/current-pr/<tag>.json` +
  touches `current-pr.dirty` (see `src/data/perri_current_pr.rs`), signals the native PR source's
  refresh channel for that focus, and pushes to every one of the focus's
  resolved **current-PR target(s)** (see the live-pane-sources bindings
  section above — only a pane bound to `perri.get_current_pr`, plus the
  narrow unbound-legacy-`diff` bridge; never a `perri.get_pr_diff`/
  `perri.get_pr_conversation`-bound tab):
  - `highlights` given → that text is pushed as each target's final content —
    it is never overwritten by a server-rendered summary.
  - `highlights` omitted → pushes `Loading` to each target (first paint
    only — suppressed if it already has content, per the live-pane-sources
    `Loading` rule above), then waits (bounded by a per-daemon settle
    timeout, default 12s) for the refetched snapshot to match `(repo,
    number)`, then pushes the same `Text` summary
    `nostromo.apply_layout`/`nostromo.refresh_pane_content` would render for
    `perri.get_current_pr`. If the wait does not settle, pushes a
    `"Fetching <repo>#<n>… (still loading)"` placeholder and reports why —
    see **"When the refetch doesn't settle"** below.

  **When the refetch doesn't settle.** The result then carries *both*
  `pending` and `retryable`, plus a human-readable `detail`. `ok` stays
  `true` in every case — the pin was written and the panes were painted, and
  that much genuinely succeeded.

  | outcome | `pending` | `retryable` | what to do |
  |---|---|---|---|
  | the refetch settled (normal) | *absent* | *absent* | nothing; the content is in the pane |
  | the settle timeout elapsed | `true` | `true` | success-with-fetch-in-flight; asking again later is reasonable |
  | the PR source task is gone | `false` | `false` | **stop.** Nothing is in flight and nothing ever will be — retrying can never help |

  Branch on `retryable`, not on `pending`. The presence of `retryable` means
  "this did not settle"; its value means "could it ever". The source-gone case
  happens when `PerriPrNativeSource`'s task has exited, which `run()` does
  outright when `build_client()` fails (no `gh` token, unreadable
  `hosts.yml`). Before this was split out, that case reported `pending: true`
  — "in flight, retry" — beside a `detail` saying nothing was in flight and
  retrying would not help, and an agent branching on the machine-readable
  field retried forever.

  Also moves the daemon's agent-scoped selected index (see
  `perri.set_selected_index`) to this PR's position in the current queue,
  if it's there.

  Before any of the above, closes every curated tab whose review context
  just went stale (R8 — the same teardown described under
  `perri.clear_current_pr` below): the previous PR's `pr_conversation`/
  `pr_diff` tabs and any `file`/`ticket` tabs. On a curated focus this can
  empty the tabbed detail region entirely, and an emptied region is removed
  from the tree rather than left lingering. If the region existed a moment
  before that happened, `load_pr` immediately rebuilds it for the *new* PR —
  the same outcome `nostromo.show(pr_conversation)` followed by
  `show(pr_diff)` would produce, so a caller that never calls `nostromo.show`
  at all (the macOS GUI's "click a PR row" action, notably) still ends up
  with a usable, visible detail region instead of one that silently vanished.
  The rebuild does not fetch: each recreated tab is bound to its PR-backed
  source and painted `Loading`, then filled in by the same watch-driven
  broadcaster that already keeps a *surviving* `pr_conversation`/`pr_diff`
  tab fresh across a PR change — so `load_pr` never blocks on this even if
  the underlying PR fetch never resolves. A curated focus that never had a
  detail region gets nothing conjured into it, and a `perri-standard` focus
  (no such region at all) is completely unaffected. A later explicit
  `nostromo.show` for the same PR re-anchors the rebuilt tabs (R2's identity
  reuse) rather than duplicating them.

  On a curated focus whose only PR-content panes are `perri.get_pr_diff`/
  `perri.get_pr_conversation`-bound tabs, this resolves to **zero** targets:
  the call still succeeds, still writes the pointer file and signals the
  refresh, but pushes no pane content and reports no `unknown_pane`
  warning — there is nowhere for the summary to go on that focus today
  (a product question, not covered by this tool). A pane push that can't be
  delivered because the resolved focus has *no* PR-content pane of any kind
  degrades to a `warnings` entry rather than failing the call — the file
  write and the refresh signal still happen either way.

  **The PR under review is a property of the focus (W7).** The pin is written
  under the resolved focus's tag, and nothing this call does changes what any
  other focus reports. There is no gate: a pickup succeeds even when another
  focus is already reviewing the same PR — no prompt, no confirmation, no
  block, no wait.

  A caller that names no focus and cannot be placed in one is **refused** with
  `unidentified_caller` rather than succeeding, because a pin belonging to no
  focus is one no surface will ever show. An empty-string `pty_id` counts as
  absent, not as a focus named `""`.

  A focus's pin dies with the focus: when a focus is removed, its pin is
  deleted outright. `nostromo.create_focus` derives its tag deterministically
  from `(agent, title)`, so a focus recreated under a reused tag starts with
  no PR under review rather than inheriting the dead focus's. This holds for
  agent-created focuses too: their eviction exemption lasts only until the
  first registry push that names them, after which they depart on the same
  two-consecutive-push rule as any other focus. A sweep on each push also
  collects pins whose focus disappeared while the daemon was not running.

**Input**:
```json
{
  "number":     42,
  "repo":       "owner/repo",
  "highlights": "optional review notes",
  "view_id":    "optional — daemon-hosted only; omit to target the caller's own focus"
}
```

**Output**: `{ "ok": true, "pane_ids": [...] }` (daemon — the resolved
current-PR target pane ids actually pushed to, possibly empty), or — when the
refetch didn't settle — `{ "ok": true, "pane_ids": [...], "pending": ...,
"retryable": ..., "detail": "..." }` (daemon; see **"When the refetch doesn't
settle"** above for the `pending`/`retryable` combinations), optionally with a
`warnings` array.

**Errors**: `invalid_args` (missing/zero `number`, missing/empty `repo`, a repo slug outside `owner/repo` form / `[A-Za-z0-9._-]`, or a focus tag that is not a safe filename), `unidentified_caller` (no `view_id` and no usable `pty_id`), `not_supported` (no daemon, or Perri's state dir isn't configured), `io_error`.

Source: `src/mcp/tools/perri_mutators.rs`, `src/data/perri_current_pr.rs`

---

### `perri.clear_current_pr`

Clear the currently-loaded PR from every pane that's showing it — whichever
layout template built the focus, and whatever those panes happen to be named.

Requires `nostromd`. It removes the calling focus's `current-pr/<tag>.json` (a no-op,
  not an error, if it's already absent) and only that focus's — no other
  focus's PR changes. Touches both `current-pr.dirty` and `queue.dirty`,
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
**Input**: `{ "view_id": "optional — daemon-hosted only" }`

**Output**: `{ "ok": true, "cleared": ["<pane ids pushed the no-PR placeholder>"], "queue": ["<pane ids refreshed with the queue>"], "closed": ["<pane ids the curated teardown closed>"] }`, optionally with a `warnings` array (daemon).

**Errors**: `invalid_args` (a focus tag that is not a safe filename), `unidentified_caller` (no `view_id` and no usable `pty_id`; clearing "the PR under review" with no focus to clear it *for* would, pre-W7, have wiped whichever focus held the global slot), `not_supported` (no daemon), `io_error`.

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.set_selected_index`

Set the selected PR index in Perri's queue list, clamped to the current
queue length (`0` when the queue is empty).

Requires `nostromd`. An **agent-scoped, in-memory** index
  (`DaemonMcpBackend::perri.selected_index`) — bookkeeping only. It moves no
  GUI highlight; there is no wire/client concept of "selected row" yet (a
  follow-up, not covered by this tool).
**Input**: `{ "index": 2 }`

**Output**: `{ "ok": true }`

**Errors**: `invalid_args` (missing/non-integer `index`), `not_supported` (no daemon).

Source: `src/mcp/tools/perri_mutators.rs`

---

### `perri.get_selected_index`

Returns the selected PR index — see `perri.set_selected_index` for what
"selected" means. Requires `nostromd`.

**Input**: *(none)*

**Output**: `{ "index": 0 }`

**Errors**: `not_supported` (no daemon).

Source: `src/mcp/tools/perri_mutators.rs`

---

### `mother.enqueue_job`

Enqueue a plan file as a new Mother job (`mother add`).

> **Breaking change (FND-2).** `repo` and `branch` are now **required**
> (`mother add` needs both); a call with only `plan_path` is `invalid_args`.

**Input**:
```json
{
  "plan_path": "/absolute/path/to/plan.md",
  "repo": "nostromo",
  "branch": "feature/my-change",
  "repo_path": "/Users/me/Code/nostromo",
  "base": "origin/main",
  "max_cost": 10,
  "label": "my-label",
  "depends_on": ["ab12cd34"]
}
```

- `plan_path` must be an **absolute** path (the daemon's cwd is not yours) to a
  file that exists and contains a `suggested_config` block.
- `repo` is a bare repo **name** as `mother add --repo NAME` takes it (e.g.
  `nostromo`), not an `owner/slug`. Unless `repo_path` is given, the checkout is
  `~/Code/<repo>`.
- `repo`, `branch`, `repo_path`, `base`, `label` and every `depends_on` entry
  are rejected (`invalid_args`) if they start with `-`.

**Output**: `{ "id": "job-id" }` .
Errors: `invalid_args`, `plan_not_found`, `mother_cli_error` (carries the CLI's
stderr; includes CLI timeouts — every daemon-side `mother` call is bounded at
30 s, stdin closed, process killed on timeout; override with
`NOSTROMO_MOTHER_CLI_TIMEOUT_MS`), and `mother_job_has_open_pr` (with a `hint`
pointing at `mother reconcile`) for retries the CLI refuses because the job's
branch already has an open PR.

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

## Decision modals (W6)

### `nostromo.ask_decision`

Pose a decision as a modal over the window and **block** until the operator
answers, dismisses it, or the call times out. This is **not a content
channel**: there is no free-form content field anywhere in the input — only a
bounded `prompt`, an optional bounded `detail` string, and 2 or more labelled
choices. An agent that wants to show something has the raw pane tools (or a
future curated `nostromo.show`); this tool can only ask.

Daemon-hosted only — without a daemon there is no window to attach a sheet to.

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
- `{ "error": "not_supported" }` — not daemon-hosted.

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
`set_pane_content`, `set_pane_layout`, `create_pane`,
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
| `file` | `{path, repo?, revision?}` | `{kind:"line", line}` | `{kind:"line_range", start, end}` |
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
| `region_not_tabbed` | The view's home region already holds a *different* view and isn't tabbed (R1). Not reachable with the compiled-in rules — the review queue is a tab of the tabbed `detail` region — only via an operator `views.yaml` override. |
| `region_not_creatable` | The view's home region doesn't exist yet, and none of its `create` candidates in `views.yaml` names a pane currently live in this focus. |
| `pane_id_taken` | Creating a non-tabbed region would need a pane id something else in this focus already holds. |
| `invalid_views_config` | `views.yaml` (compiled-in or override) is malformed. |
| `unknown_source` / `fetch_failed` | The view's underlying fetcher isn't in the closed registry, or ran but failed — the same codes `apply_layout`/`refresh_pane_content` surface. |
| `invalid_params` / `unknown_path` / `path_escapes_root` / `not_utf8` / `anchor_beyond_eof` / `invalid_emphasis_range` / `unresolvable_revision` / `revision_repo_mismatch` / `revision_required` | `file`'s fetch-level refusals (`FileSourceError`) — see `docs/mcp/panes.md`'s `code`/`diff` section. `revision_repo_mismatch` (W5 — current-pr-collision) is a request that resolved to a revision only a PR pinned to a *different* repo than the caller's own working directory could serve — refused rather than silently rendering that foreign repo's content. |

**`repo` — showing a file from the PR's repo when you aren't in a checkout of it.** A reviewer agent (Perri) runs from one working directory and reviews PRs in many repos, so for her a `file` request without `repo` can never succeed: the daemon resolves the path against the caller's own root, and the W5 guard (above) refuses a PR head revision from a repo that root isn't. Pass `repo` (`owner/name`, the same slug rule as a `{repo, number}` target) and the daemon **skips the local checkout entirely** and reads the file from GitHub at `revision`:

- `revision` omitted → the pinned PR's head SHA **if that PR is in the same `repo`**; otherwise `revision_required` (there is no checkout to fall back to, and guessing a branch would silently serve content you didn't ask for).
- The repo is part of the view's identity: `README.md` shown from two repos is two tabs, not one re-anchored tab.
- Explicitly naming the repo is what makes this safe under W5: the guard exists to stop the daemon silently serving a foreign repo's content under an *implicit* repo; here the repo is stated, not inferred.
- Reads are authenticated with the daemon's existing GitHub token and bounded by the same timeouts as the rest of the GitHub client. A successful read is cached in memory by `repo|revision|path` (a revision is immutable) so a repaint — which cannot call the network — can still serve it; after a daemon restart the cache is cold and a repaint returns `unresolvable_revision` until the file is shown again.

`file` without `repo` is unchanged. It remains the right choice for an agent whose working directory *is* the repo.
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
"acme/ops", "number": 42}}`. This is scoped narrowly: for most codes, an
explicit `revision` doesn't carry it (the caller already named exactly what
it asked for), no other view type ever carries it, and with no PR pinned the
key is absent entirely (never `null`) — a bare refusal is unchanged from
before W5. **`revision_repo_mismatch` is the one exception** — it is *only*
ever produced with an explicit `revision` (an implicit one degrades to the
working tree and fails as `unknown_path` instead, never reaching this code),
so it carries `current_pin` unconditionally; otherwise the one refusal whose
entire reason for existing is a pin mismatch would be the one refusal that
doesn't name the pin. The point is telling an agent *why* an
otherwise-ordinary-looking refusal just happened: a second, independent
session pinning a different PR mid-review.

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

## Phase 6 — Render-state visibility (W1)

`nostromo.show` and every other layout-mutating tool return success the
moment the **daemon** accepts and registers the call — `PaneRegistry` only
ever stores the tree it was told to build, never what any window actually
painted. Closing that gap needs a fact the daemon doesn't have: what a
client's view hierarchy actually materialised. The macOS app reports that
fact once per window at the end of its own reconcile pass
(`ClientMsg::RenderedShape`); this tool (and the `render_state` section
`nostromo.get_view_state` gained alongside it) serves it back, diffed
against the daemon's own expected tree.

### `nostromo.get_render_state`

Reports, per attached window, whether what a focus's client actually
rendered agrees with what the daemon expects.

**Input**: `{ "view_id": "optional — defaults to the caller's own focus" }`

**Output**:
```json
{
  "tag": "perri",
  "expected": ["detail.0", "detail.1", "detail.2", "queue", "repl"],
  "windows": [
    { "window_id": "0",
      "rendered": ["detail.0", "detail.1", "detail.2", "queue", "repl"],
      "missing": [], "extra": [],
      "reported_at": "2026-09-04T20:55:01Z", "age_ms": 1200, "agrees": true },
    { "window_id": "2",
      "rendered": ["queue", "repl"],
      "missing": ["detail.0", "detail.1", "detail.2"], "extra": [],
      "reported_at": "2026-09-04T20:48:11Z", "age_ms": 412000, "agrees": false }
  ],
  "windows_reporting": 2,
  "agrees_everywhere": false
}
```

A tag no window has ever reported for returns `"windows": []` and
`"agrees_everywhere": null` — **never** `true`. Absence of a report is not
evidence of agreement: a client that crashed, never connected, or hasn't
caught up to the daemon's latest broadcast yet must not read the same as a
client that checked in and confirmed. `missing` is expected-but-not-rendered
(what the caller most likely wants to fix); `extra` is
rendered-but-not-expected (a stale pane the client hasn't torn down yet).

`reported_at` is the *client's* timestamp, not the daemon's receipt time —
`age_ms` is how long ago that window last checked in, which is what tells a
caller whether a report is even worth trusting for the show it just issued.

#### What this tool does **not** tell you

**It reports hierarchy membership, not visibility.** `agrees: true` means
every expected pane id exists in the client's view hierarchy. It says
nothing about whether any of those panes has a usable size, sits on screen,
is unobscured, or was ever painted.

This is not a hypothetical gap. On 2026-09-08 all three windows reported
`agrees: true`, `missing: []`, `extra: []` for
`["queue", "detail.0", "detail.1", "repl"]`, freshly, twice, 65 seconds
apart — while the detail region was **34 points wide** in a split whose
correct share was 879.5 points, and the operator could see nothing but the
queue. The region was a member of the hierarchy, so this tool was right, and
useless. Reading it as "the screen is fine" is what kept a live-blocking bug
invisible for four days
(`.claude/bugs/open/2026-09-08-detail-region-hierarchy-self-reports-rendered-but-nothing-is-visibly-painted-on-w7.md`).

Extending the per-window report to carry pane geometry would close this and
is worth doing; it needs a `ClientMsg::RenderedShape` wire change and was
deliberately left out of the fix for the collapse itself. Until then, the
instruments that *can* answer "is it actually usable" are:

- **Debug ▸ Copy pane diagnostics** (⌘⇧P) — per-pane bounds on demand.
- The `panes` log category's `PaneFirstPaintAudit` line, which since
  `fix/detail-region-split-collapse` reports `tooSmall` for a pane that is
  non-zero but unusably small, not only one that is literally zero-sized.
- A screenshot. Still the only thing that proves a human can see it.

**If an operator says they cannot see something this tool calls fine,
the operator is right.** An instrument trusted beyond what it measures is
worse than no instrument, because it ends the investigation.

**Errors**: `unidentified_caller` (no `view_id` and no caller `pty_id` to
target), `not_supported` (non-daemon-hosted MCP server).

Source: `src/mcp/tools/render_state.rs`

### `nostromo.get_view_state`'s `render_state` section

Every `nostromo.get_view_state` response now carries the same information
under a `render_state` key, keyed on the requested `view_id` — this is the
tool an agent already reaches for, so the comparison is discoverable there
without a second tool name. Same shape as `nostromo.get_render_state`'s
output above.

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
      - nostromo.create_pane
      - nostromo.reset_panes
      - nostromo.apply_layout
      - nostromo.refresh_pane_content
```

**One tool is exempt: `nostromo.tracker`.** `ALWAYS_AVAILABLE`
(`src/mcp/tool_policy.rs`) lists tools that `filter_descriptors` never removes
and `ToolPolicy::denies` never denies, even when a policy names them. The
session instructions (`src/mcp/instructions.rs`, see
[`tracker.md`](tracker.md#discoverability)) tell every Nostromo agent to use
the tracker, so withdrawing it from one agent would contradict its own prompt.
The list is deliberately a single entry.

Every other caller — Mother, Fred, Teri, Cody, and anyone else the policy
doesn't name — sees a `tools/list` byte-for-byte identical to what it always
returned, whether or not this policy is armed for Perri.

Source: `src/mcp/tool_policy.rs`, `src/mcp/server.rs` (`TOOL_FORBIDDEN_CODE`),
`src/mcp/tools/mod.rs` (`tool_descriptors_for`, the `dispatch_inner` gate).

---

## Terminals

### `nostromo.open_terminal`

Open a terminal pane (the user's login shell) in the caller's own focus. The user types into it; **no MCP tool can write to, read from or close a terminal**.

**Input** (the only property is optional; `additionalProperties: false`):
```json
{ "working_directory": "/Users/me/Code/repo" }
```

`working_directory` must be an absolute path to an existing directory. Default: the focus session's working directory, else `$HOME`. There is no `command`, `args`, `env`, `initial_input` or `view_id`: the target is always the caller's own focus (its Hello `pty_id`).

No Nostromo path lets an agent run anything in the terminal. The starting directory is the agent's choice, though, so anything the user's shell runs on its own in a directory (prompt hooks, a trusted `direnv`/`mise` file, `core.fsmonitor`) runs there as the user would expect it to in any terminal opened in that directory. Agent-opened terminals count against the same per-focus (8) and daemon-wide (32) limits as the user's, and agents also have a lower quota of their own: 2 open per focus and 6 across the daemon (live or ended; only the user closes one, which frees the quota). The rest is reserved for the user, so an agent in a loop cannot leave the user with `terminal_limit_reached`.

**Who may call it.** A plain agent session (a Hello `pty_id` naming a focus). It is refused with `-32001` (`Forbidden`, the same as a tool the operator's policy withdraws) before anything else happens for: a session an unauthenticated network peer is steering (it is also hidden from that session's `tools/list`), the picks session (`PICKS_TOOLS` only), and an agent the operator's `tool-policy.yaml` denies it to. Each refusal is audited (`refused {channel: "mcp", op: "open", code: "forbidden", focus, tool}`: no arguments) and starts nothing. A Mother worker connects with no focus (no `NOSTROMO_PTY_ID`), so it gets `unknown_view` and nothing opens.

The tool's name is `nostromo.open_terminal` (a dot, like `nostromo.show`); the plan wrote `nostromo_open_terminal`. The MCP refusal audit budget (120 lines a minute) is per channel (all MCP callers share it), not per focus.

**Output**: `{ "ok": true, "terminal_id": "<uuid>", "pane_id": "terminal-<8 hex>" }`. The new leaf does not take keyboard focus. The open is audited (`opened`, `requested_by: focus`).

| `error` | Meaning |
|---|---|
| `unknown_argument` | Any key other than `working_directory`; `detail` is the key. Nothing is created. |
| `invalid_working_directory` | Relative, missing or not a directory. |
| `unknown_view` | No identifiable caller, or its focus is unknown to the daemon. |
| `terminal_limit_reached` | The focus (8) or the daemon (32) is at its terminal limit. |
| `terminal_agent_quota_reached` | Agents already have 2 terminals open in this focus or 6 in the daemon; the user can still open more, and closing one frees the quota. Audited (`refused`, `op: "open"`). |
| `terminal_open_failed` / `terminal_audit_unavailable` | The shell could not start, or the audit log cannot be written (no terminal runs unaudited). |
| `not_supported` | Not hosted by `nostromo` (the daemon). |

Source: `src/mcp/tools/terminal.rs`, `src/terminal/agent_api.rs`

### Refused terminal paths: JSON-RPC `-32002`

A request on the MCP socket that looks like writing to, reading from or closing a terminal gets its own JSON-RPC error code, **`-32002`** (`TERMINAL_FORBIDDEN_CODE`, `src/mcp/server.rs`), distinct from `-32601` (no such tool) and `-32001` (withdrawn by policy). The message is `terminal_<op>_forbidden: <name>` with `op` one of `input`, `read`, `close`. Each is audited as `refused {channel: "mcp", focus, op, tool}` and changes nothing.

- `tools/call` with a name that mentions `terminal|shell|pty|tty|console` and an op verb (input: `input|write|send|key|paste|type|signal|kill|interrupt|exec|run|stdin`; read: `read|output|screen|scrollback|tail|capture|snapshot`; close: `close|remove|destroy|detach|stop`), or a bare `send_keys`/`stdin`-style name. No such tool is registered. A real tool that the classifier would match must be added to `EXEMPT_TOOL_NAMES` (`src/mcp/tools/terminal.rs`); a test fails if any registered name is classified.
- A raw frame with no `jsonrpc` key whose `type` starts `terminal_`/`pty_`, or a request whose `method` starts `terminal/`/`pty/` (case, `.` and `-` for `_` are normalised).

`src/mcp/` cannot name the terminal write path at all: `tests/terminal_policy.rs` scans it as text for `OperatorCap`, `TerminalManager`, the terminal-input message, `.input(`, `access::` and `mint(` (the way to get a cap). The scan is a tripwire (an alias could get around it); the real guard is that `TerminalAgentApi.manager` is a private field, so MCP code can only open, ask and audit. Terminal I/O is only available to the verified Mac app over IPC ([`../terminal.md`](../terminal.md)).

### `terminal_pane_protected` and `reserved_pane_id`

An agent layout call cannot remove, replace or overwrite a live terminal pane. The call fails with `{"error": "terminal_pane_protected"}`, changes nothing and is audited (`refused`, `op: "layout"` or `"content"`):

| Tool | Refused when |
|---|---|
| `nostromo.reset_panes` | the focus has a live terminal |
| `nostromo.set_pane_layout` / `nostromo.apply_layout` | the new tree omits a live terminal's leaf; `apply_layout` also refuses a `panes` entry that names one (`content`) |
| `nostromo.set_pane_content` / `nostromo.refresh_pane_content` | `pane_id` is a live terminal's pane (`content`) |
| `nostromo.show` | its placement would land in or close a terminal pane (never happens in practice: terminal tabs are pinned) |

`nostromo.set_pane_layout` and `nostromo.apply_layout` cannot hide a terminal either (`nostromo.show` can still open a new frontmost tab over the terminal's tab: the terminal stays one click away). A full tree that puts a live terminal's leaf in a `tabs` node as an inactive tab fails with `terminal_pane_hidden`, and a tree or ratio map that leaves a terminal's leaf (or any subtree holding it) under 10% of the layout (the ratios multiply down the tree, so two 0.3 splits leave 0.09), or a split holding it with a zero or negative ratio, fails with `terminal_pane_too_small`; both change nothing and are audited like the above (`op: "layout"`).

A ratio-only `set_pane_layout` (including one naming the terminal's pane, as long as it keeps the pane at 10% or more of the layout) and a full tree that keeps the leaf visible still succeed. A terminal goes away only when the user closes it, its shell exits, or its focus is removed (`closed`, reason `user_closed`/`exited`/`focus_removed`).

Pane ids starting with `terminal-` are reserved: `nostromo.create_pane` with one, or a full tree (`set_pane_layout`, `apply_layout`) containing a `terminal-` leaf that is not a live terminal of that focus, fails with `reserved_pane_id`.

---

## Agent tracker

| Tool | Purpose | Reference |
|---|---|---|
| `nostromo.tracker` | Open a markdown task board and change it item by item (`open`, `upsert`, `status`, `remove`, `move`, `log`, `read`); edits made in an editor are picked up and attributed; deltas per session. | [`tracker.md`](tracker.md) |

Source: `src/mcp/tools/tracker.rs`, `src/tracker/`

### `nostromo.list_remote_shell_targets`

What `nostromo.request_remote_shell` accepts, read from the user's ECS configuration on every call. No arguments (`additionalProperties: false`).

**Output**: `{ "ok": true, "projects": [{ "name", "default_service?", "environments": [{ "name", "services": [...] }] }], "shell_types": [...] }`, or `{ "error": "remote_shells_not_configured", "detail": "<why>" }`. Any argument: `unknown_argument`. Withheld from a session an unauthenticated network peer is steering, like `nostromo.open_terminal`.

### `nostromo.request_remote_shell`

Ask the user to open a shell on a remote (ECS) service. **The agent only asks; the user decides.** Nostromo shows a confirmation sheet in the app and the shell opens only if the user clicks **Connect**. The agent can never type into the shell and cannot see its output unless the user invites it to follow (a later slice). Use this instead of the `ecs_*` shell functions or tmux panes, which the production-shell guard blocks for agents; the guard allows this tool (its name does not match, and it has no `command`, `cmd` or `script` field).

**Input** (`additionalProperties: false`):
```json
{ "project": "admin-portal", "environment": "prod", "service": "sched", "shell_type": "shell", "reason": "check why the scheduler is stuck" }
```
`project`, `environment`, `service` and `shell_type` are required; common aliases (`prod`, `sched`, `ap`) are accepted, in any case. `reason` is optional, at most 200 characters, and is shown to the user. Any other key, including `command`, `cmd` and `script`, is `unknown_argument` (nothing is asked). The caller is always its own focus (its Hello `pty_id`); there is no `view_id`.

The call blocks until the user answers or about 5 minutes pass. It is withheld from a network-driven session and the picks session, like `nostromo.open_terminal` (refused with `-32001`, audited `op: "remote_request"`). If the agent's connection closes while it waits, the request is abandoned and the sheet closes.

**Output**: `{ "ok": true, "outcome": "connected", "terminal_id", "pane_id" }` once the user connected.

| `error` | Meaning |
|---|---|
| `invalid_target` | A word is outside the vocabulary: `detail`, and `valid: { field, values }` lists what is accepted. Nobody was asked. |
| `unknown_argument` | Any key other than the five above; `detail` is the key. |
| `reason_too_long` / `invalid_args` | `reason` over 200 characters; a missing or non-string argument. |
| `unknown_view` | No identifiable caller, or its focus is unknown to the daemon. |
| `remote_shells_not_configured` | No ECS `config.json`, or a value in it is not safe to run (`detail` says why; an unsafe value is named by a fixed code, never quoted). |
| `no_operator` | No Nostromo app that can show the sheet is connected (immediately; nothing was sent). |
| `request_pending` | Another request is waiting for the user (immediately). |
| `cancelled` / `dismissed` | The user cancelled or dismissed the sheet. No terminal exists. |
| `timeout` | The user did not answer in time. |
| `connect_failed` | The user connected but the shell could not be opened: `reason` (a code, e.g. `not_available`) and `remedy` (fixed text for that code). Nothing the AWS CLI printed is returned: no `detail`. No pane exists. |
| `not_supported` | Not hosted by `nostromo` (the daemon). |

Source: `src/mcp/tools/remote_shell.rs`; flow in `src/terminal/remote_request.rs`. Both tool names are dotted like the rest (`nostromo.request_remote_shell`); the plan wrote them with underscores. The guard-consistency test checks both spellings.

### `nostromo.list_terminals`

The terminals the caller can see: those in its own focus, and any other focus's terminal it is following. **Metadata only, never output.** No arguments (`additionalProperties: false`). The caller is always its own focus (its Hello `pty_id`); there is no `view_id`.

**Output**: `{ "ok": true, "terminals": [{ "terminal_id", "label", "kind": "local" | "ecs", "status": "connecting" | "running" | "ended", "followed_by_you" }] }`. `followed_by_you` is true while the caller is the terminal's follower (active or paused). Errors: `unknown_argument`, `unknown_view`, `not_supported`.

### `nostromo.request_follow`

Ask the user to let the caller follow one of **its own focus's** terminals. **The agent only asks; the user decides.** Following means what the terminal prints is delivered into the agent's conversation (redacted, capped) and `nostromo.read_terminal_screen` works; the agent still cannot type into the terminal.

**Input** (`additionalProperties: false`): `{ "terminal_id": "<from nostromo.list_terminals>", "reason": "why you want to follow it" }`. `terminal_id` is required; `reason` is optional, at most 200 characters, and is shown to the user (control and bidi characters stripped). Any other key is `unknown_argument` (nothing is asked).

The call blocks (up to 5 minutes) on a decision sheet, answerable by the verified Nostromo app only (the decision flow's own rule: no other process can answer it). Prompt: `<agent> in <focus> asks to follow <pane>. Output will be sent to <agent>'s model.`; for a remote (`ecs`) pane it leads with `Output from <ENVIRONMENT, uppercased> will be sent to <agent>'s model.` Choices: `allow`, `deny`. Allow starts following (`via: "request"`, without the screen) from inside the call: if the call is dropped first (the agent's connection closes, or the session ends) the sheet is withdrawn (also when it is still queued behind another decision of the focus) and nothing follows. If the same terminal is already followed by another focus, the sheet says so (allowing moves it). It is withheld from a network-driven session and the picks session, like the other terminal tools.

**Output**: `{ "ok": true, "outcome": "following" }` (also at once, with no sheet, when the caller already follows that terminal).

| `error` | Meaning |
|---|---|
| `no_operator` | No verified app that can show the sheet **and** declared `terminal_follow_ui` (it can show who follows and stop it) is connected. Immediate (nothing was shown, nothing queued). Also returned if the app went away between its Allow and the invitation: nothing follows with no app left to show or stop it. |
| `denied` / `dismissed` / `timeout` / `cancelled` | The user chose Deny / dismissed the sheet / did not answer in time / the agent's session ended while it waited. Nothing follows. |
| `request_pending` | Another follow request from this focus is waiting for the user. |
| `unknown_terminal` | Not a terminal of the caller's focus. The same answer for another focus's terminal and for one that does not exist. |
| `terminal_not_running` | The terminal's shell has ended (or is still connecting). |
| `follower_not_running` | The user allowed it but the caller's session was gone. |
| `follow_unavailable` | Following is not set up in this daemon. |
| `reason_too_long` / `invalid_args` / `unknown_argument` / `unknown_view` / `not_supported` | As for the other terminal tools. |

### `nostromo.read_terminal_screen`

The current screen of a terminal **the caller follows**, as plain text with secrets redacted (the same redaction and caps as a follow delivery; rows the program wrapped are joined first so a secret that wrapped is whole). Works while the follow is active or paused, for a shell and for a full-screen program; stops working the moment the user stops it, the terminal closes, or following moves to another focus.

**Input** (`additionalProperties: false`): `{ "terminal_id": "..." }` (required).

**Output**: `{ "ok": true, "text", "lines", "redactions" }`.

| `error` | Meaning |
|---|---|
| `terminal_read_forbidden` | The caller does not follow that terminal. The same answer whether the terminal is unfollowed, followed by someone else, or does not exist. Audited as `refused {channel: "mcp", op: "read", tool: "nostromo.read_terminal_screen"}`. Nothing is injected anywhere. |
| `redaction_failed` | Redaction failed, so nothing is returned (fail closed). |
| `invalid_args` / `unknown_argument` / `unknown_view` / `not_supported` | As above. |

A successful read is audited as `screen_read {terminal_id, focus, lines, bytes}`: counts only, never the text.

Source: `src/mcp/tools/terminal_follow.rs`; the methods on `TerminalAgentApi` in `src/terminal/agent_api.rs`. The classifier that refuses read-shaped terminal tool names (`-32002`) exempts exactly `nostromo.read_terminal_screen`; every other read-shaped name, including `nostromo_read_terminal_screen` and `nostromo.read_terminal_output`, is still refused. None of the three names matches the production-shell guard's tool-name rule and none has a `command`, `cmd` or `script` field (`tests/remote_shell_guard_consistency.rs`).
