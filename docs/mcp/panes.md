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

## Live pane-source bindings (live-pane-sources)

Every pane the daemon (`nostromd`) hosts can optionally be **bound** to a
server-side `source` — one of the closed set of fetchers in
`src/mcp/tools/apply_layout.rs::known_sources()` (currently
`perri.list_pr_queue` and `perri.get_current_pr`). A binding is structural
metadata stored on `PaneRegistry` — `(tag, pane_id) -> source` — never
content. It answers one question: "does this pane refresh itself?"

### Lifecycle

- **One source per pane.** Binding a pane that's already bound replaces the
  old source; it never accumulates.
- **`repl` can never be bound**, and a pane not currently a leaf of the
  focus's tree is silently refused (logged at `debug!`, not an error).
- **A binding dies with its pane.** `reset_panes` drops every binding for
  that tag; `set_pane_layout` with a tree that omits a previously-bound pane
  drops just that pane's binding.
- **A binding survives a daemon restart.** It's persisted alongside the pane
  tree in `~/.nostromo/daemon-panes.json`. On restart, a binding whose source
  has been retired (no longer in `known_sources()`) is dropped, and the
  daemon repaints every reloaded binding immediately — no tool call needed.
- **Who binds, who unbinds** — see the table in `docs/mcp/tools.md`'s "Live
  pane-source bindings" section. The short version: a push that came from
  fetching `source` binds the pane; a push of content an agent wrote by hand
  (`set_pane_content`, or `perri.load_pr` with `highlights`) unbinds it.

### The automatic broadcaster

A bound pane is kept live by a background task (`run_pane_source_broadcaster`
in `src/mcp/pane_sources.rs`) that watches the underlying data sources and
re-pushes `PaneContent` whenever they change — well under a second for a
relay-driven GitHub event, no agent/tool-call involved. It never broadcasts
`Loading` or `Error`: on a fetch failure it leaves the pane's last-good
content alone (the periodic staleness check below is what surfaces that a
source has gone quiet). An unchanged push (identical content **and**
freshness) is never re-sent.

### The `freshness` field

Every daemon-originated `ServerMsg::PaneContent` may carry a `freshness`
object:

```json
{ "as_of": "2026-07-30T12:00:00Z", "stale": false, "badly_stale": false }
```

- `as_of` — when the source last produced good data (absent if it never has).
- `stale` — the source's own transient flag. **Clients must not render this**
  — a single missed poll is routine.
- `badly_stale` — the daemon's verdict that the source hasn't produced good
  data for more than five minutes (five consecutive missed poll cycles).
  **This is the only flag a client renders**, as a quiet as-of footnote — never
  an interruption, never a layout shift, and it clears on the next good push
  with no agent action. Overridable for manual testing only via
  `NOSTROMO_BADLY_STALE_SECS` — never a documented user setting.

`freshness` is `None`/absent for content that has no staleness concept (e.g.
agent-authored `set_pane_content`) and — by design, via `#[serde(default)]` /
optional decoding on every client — for frames from a daemon build that
predates this field. Both directions decode cleanly.

### `Loading` is a first-paint-only signal

`PaneContentWire::Loading` is broadcast **only** the first time a pane is
about to receive content (tracked by a non-persisted "has this pane ever been
painted" bit on `PaneRegistry`). A pane that already has content — from any
source, agent-authored or automatic — never sees a spinner replace it, whether
the refresh was triggered by `nostromo.refresh_pane_content` or by the
automatic broadcaster (which never sends `Loading` at all). Clients
additionally refuse to *render* an incoming `Loading` over existing non-loading
content, as a second line of defense against an older daemon or a race.

---

## Tabbed regions (`PaneTree::Tabs`) — curated-agent-views W1

A third `PaneTree` node kind, alongside `Leaf` and `Split`: a region that hosts
several panes with exactly one frontmost.

```json
{
  "kind": "tabs",
  "children": [ { "kind": "leaf", "pane_id": "ticket" }, { "kind": "leaf", "pane_id": "activity" } ],
  "labels": ["Ticket", "Activity"],
  "active": 0
}
```

- `children` — ordered tabs, left to right. In v1 every child is a `Leaf` —
  every tab is a real pane with a real `pane_id`, and its content still
  arrives via the ordinary `ServerMsg::PaneContent` broadcast for that pane
  id. Tabs are a presentation grouping, not a new content-delivery mechanism.
- `labels` — per-tab display labels, parallel to `children` (same shape as
  `Split`'s `children`/`ratios` pairing).
- `active` — index into `children` of the frontmost tab. Authoritative unless
  overridden by `FocusLayout.focused_pane` naming one of this node's children
  (see below).

**Invariants** (enforced by `PaneRegistry::validate_node`, the same choke
point as `Split`'s shape checks): `children.len() >= 1`, `labels.len() ==
children.len()`, `active < children.len()`, and — recursively through the
whole tabs subtree — **no `repl` leaf**. Hiding the REPL behind a tab is
never valid: the REPL is where the operator's hands are. A tree violating any
of these is refused as `PaneError::InvalidLayout` (or, from the
`apply_layout` DSL below, `ApplyLayoutError::ReplInTabs` specifically for the
repl case) and the registry's stored tree is left unchanged.

**Reachable today only through `set_pane_layout` (a full tree) or the
`apply_layout` DSL below** — there is no dedicated tab-mutation tool in this
wedge. `focused_pane`, `create_pane`/`reset_panes`, and every other existing
tool are unaffected; a tabs child is an ordinary leaf pane once installed, so
it can be split further with `create_pane` or bound to a live source with
`bind_source`/`refresh_pane_content` exactly like any other leaf.

### DSL form

```yaml
tree:
  direction: horizontal
  ratios: [0.7, 0.3]
  children:
    - pane: repl
    - tabs:
        - pane: ticket
          label: Ticket
        - pane: activity
          label: Activity
      active: ticket
panes:
  ticket:
    content_kind: text
  activity:
    content_kind: text
```

A `tabs:` node lists `{ pane, label }` pairs; `active` names the frontmost
pane **by id**, not index (matching the DSL's pane-id-centric vocabulary
elsewhere — it can't silently drift if `tabs:` is reordered). A schema
declaring `repl` among a `tabs:` list's panes is refused at validation time
with `repl_in_tabs`, distinct from the `invalid_schema` code used when `repl`
is bound in the top-level `panes` map.

### Client rendering (macOS, W1)

A tabs node renders as a tab strip over a stack of **resident** child views —
every tab's view is built once and kept alive for the container's whole
lifetime; switching tabs is a visibility toggle, not a rebuild, which is what
lets scroll position and view state survive a switch with no bookkeeping.
Opening, closing, reordering, relabeling, or switching a tab is classified by
`LayoutChangeClassifier` as `.tabMembership`/`.activeTabOnly` rather than a
full structural rebuild, so it never clears the operator's dragged split
ratios for the *surrounding* regions the way an actual split-topology change
does. Unread state (a content push for a tab that isn't currently frontmost)
is derived entirely client-side — the daemon has no business knowing which
tab the operator is looking at.

iOS gets decoder correctness only in this wedge: a tabs node's children
flatten into the existing per-pane `TabView` alongside every other non-repl
pane, with no dedicated tabs UI.

---

## `PaneAddress` — anchor, emphasis, and reason (curated-agent-views W1)

`ServerMsg::PaneContent` carries an optional sibling of `freshness`:

```json
{
  "type": "pane_content",
  "tag": "cody-core-1234",
  "pane_id": "ticket",
  "content": { "kind": "text", "text": "CORE-1234: ..." },
  "address": {
    "anchor": { "kind": "line", "path": "src/main.rs", "line": 42 },
    "emphasis": [ { "kind": "text_range", "start": 0, "end": 40 } ],
    "reason": "flagged by CI"
  }
}
```

`address` says where to look inside a pane's content, and why. It's a
sibling of `freshness` rather than a field on `PaneContentWire` deliberately:
that placement is what lets a caller cheaply re-anchor/re-emphasise a pane
("a show matching a live tab re-anchors it") without re-sending the content
itself. `None`/absent means "no addressing concept for this pane" — every
push before this field existed, and every push from a caller with nothing to
point at.

- `anchor` (optional) — the one place to land: `line` (a line, optionally
  scoped to one file — the `path` is how a multi-file view like `pr_diff`
  addresses a line within it), `comment` (a PR-review comment thread id),
  `section` (a named heading), or `queue_row` (a `repo`/`number` pair).
- `emphasis` (zero or more) — ranges to highlight: `line_range`, `comment`,
  `section`, `text_range` (a raw character offset range), or `queue_row`.
- `reason` (optional) — one short human-readable phrase explaining why this
  was shown.

**This wedge (W1) transports every variant but renders only `reason`** — as a
tab's caption, dimmed and truncated, sourced from that tab's own last-pushed
content. `anchor`/`emphasis` decode, round-trip, and are otherwise inert;
scrolling to a line or highlighting a range is W2 onward. The dedup logic in
`pane_sources::run_pane_source_broadcaster` treats `address` as part of the
change-detection key, so an address-only push (identical content and
freshness) is still broadcast rather than silently dropped as a duplicate —
though no source in this wedge's closed fetcher registry produces one yet;
every existing daemon-side call site passes `address: None`.

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

## `nostromo.apply_layout` — declarative layout DSL

The imperative sequence for assembling a known, fixed pane layout — `reset_panes` →
`create_pane` (×N) → `set_pane_layout` → per-pane `set_pane_content` / a read
tool — costs a full LLM turn and puts every fetched-data result in the calling
agent's context, even when the shape and the data source are already known and
involve no judgment. `nostromo.apply_layout` collapses that into one call: it
resolves a layout schema, builds the pane tree through the same `PaneRegistry`
invariants (exactly one `repl` leaf, unique ids, well-formed splits), fetches
each pane's bound data source **server-side, with no LLM involvement**, and
broadcasts one `FocusLayout` plus one `PaneContent` per non-repl pane.

It is purely additive — `create_pane`, `set_pane_layout`, `set_pane_focus`,
`set_pane_content`, and `reset_panes` are unchanged and still work for
freeform / agent-judgment layout work.

### Named mode

```json
{ "name": "perri-standard" }
```

Resolution precedence: an on-disk override at `~/.nostromo/layouts/<name>.yaml`
if present (read fresh on every call — edit it and the next `apply_layout` call
picks it up, no daemon restart needed), else a compiled-in default. An unknown
name with no override and no compiled-in default is `unknown_layout`.

### Inline mode

```json
{
  "tree": { "direction": "horizontal", "ratios": [0.5, 0.5],
            "children": [ { "pane": "notes" }, { "pane": "repl" } ] },
  "panes": { "notes": { "content_kind": "text" } }
}
```

Provide either `name` or `tree`(+`panes`), not both. Inline mode serves any
one-shot layout — including per-focus or dynamic shapes — without needing a
named schema on disk.

### The DSL

A layout schema is YAML (or, for inline mode, the equivalent JSON shape):

```yaml
name: perri-standard
description: Perri's default PR-review dashboard
tree:
  direction: vertical
  ratios: [0.6, 0.4]
  children:
    - direction: horizontal
      ratios: [0.5, 0.5]
      children:
        - pane: queue
        - pane: diff
    - pane: repl
panes:
  queue:
    source: perri.list_pr_queue
    content_kind: pr_list
  diff:
    source: perri.get_current_pr
    content_kind: text
    placeholder: "No PR loaded. Select one from the queue or ask me to pull one."
```

- `tree` — interior nodes carry `direction` (`horizontal` | `vertical`),
  `ratios`, and `children`; leaves are `{ pane: <id> }`. Converts directly to
  the existing `PaneTree` wire type; the *existing* `PaneRegistry` validation
  path (not reimplemented here) enforces exactly one `repl` leaf, unique pane
  ids, and well-formed splits.
- `panes` — a map of non-repl pane id → binding. `repl` must not appear here.
  - `source` (optional) — a name from the closed fetcher registry below. Omit
    it when the agent will populate the pane itself via `set_pane_content`
    after the layout is applied.
  - `content_kind` (required) — one of `text`, `json_snapshot`, `pr_list`,
    `loading`, `error` (the `PaneContentWire` variant surface). When the pane
    also has a `source`, `content_kind` must match what that source actually
    produces (see the fetcher registry table below) — a mismatch is rejected
    at validation time (`invalid_content_kind`) rather than silently ignored.
  - `placeholder` (optional) — shown as `text` when the source yields
    empty/null data (e.g. no PR currently loaded).

### Fetcher registry (v1)

A closed, compile-time dispatch table — adding a source is a deliberate code
change, not arbitrary code execution:

| `source` | reads | produces |
|---|---|---|
| `perri.list_pr_queue` | `perri_queue_rx` | `PrList` — the live PR queue |
| `perri.get_current_pr` | `perri_pr_rx` | `Text` — a plain-text summary (title, `owner/repo#number`, author, `+adds/-dels`, changed files), or the pane's `placeholder` when no PR is loaded |

`perri.get_current_pr`'s fetcher is intentionally a plain snapshot summary —
rendering agent "highlights" requires the LLM and cannot happen server-side.
The agent may overwrite the pane afterward with richer text via the existing
`set_pane_content`.

A pane's fetcher failing does not abort the whole layout: it broadcasts
`PaneContentWire::Error` for that pane and the call still returns `{ "ok":
true, "warnings": [...] }`, listing the failed panes.

### Error codes

| Code | Meaning |
|------|---------|
| `unknown_layout` | Named layout has no on-disk override and no compiled-in default |
| `unknown_source` | A pane's `source` isn't in the closed fetcher registry |
| `invalid_content_kind` | A pane's `content_kind` isn't a recognised `PaneContentWire` variant |
| `invalid_schema` | The schema document is malformed, or `repl` is bound as a pane in the top-level `panes` map |
| `repl_in_tabs` | A `tabs:` region named `repl` among its tab panes — distinct from `invalid_schema` above |
| `fetch_failed` | A fetcher ran but failed to produce content (reported via `warnings`, not a hard error) |
| `invalid_args` | Neither `name` nor `tree` was provided, or both were |
| `unidentified_caller` | No `view_id` and no caller `pty_id` to target |
| `not_supported` | Called against a non-daemon-hosted MCP server |
| `unknown_view` / `invalid_layout` | Reused `PaneRegistry` codes — see above |

A schema failing validation (`unknown_source`, `invalid_content_kind`,
`invalid_schema`) or a tree failing `PaneRegistry` invariants (`invalid_layout`)
does **not** mutate the registry — the focus's existing layout is left intact.

---

## `nostromo.refresh_pane_content` — content-only refresh from a registered source

`apply_layout` solves *initial assembly*, but an agent that has already
assembled its workspace still refreshes a single pane's content many times
per session (Perri re-pushing her PR queue after each review, for example).
`apply_layout` re-declares geometry on every call — correct for "assemble or
reset a layout," wrong for a routine content refresh, since it would forcibly
reset an operator's manually-dragged split ratios. `refresh_pane_content` is
the companion tool for that case: it reuses `apply_layout`'s exact fetcher
registry (the same `source` names, the same content shapes, the same error
vocabulary — there is no second, parallel source list) but emits **only** a
`PaneContent` broadcast. No `FocusLayout`, no `PaneRegistry` mutation, ever.

```json
{ "pane_id": "queue", "source": "perri.list_pr_queue" }
```

```json
{ "pane_id": "diff", "source": "perri.get_current_pr", "placeholder": "No PR loaded. Select one from the queue or ask me to pull one." }
```

- `pane_id` (required) — the pane to refresh.
- `source` (required) — a name from the same closed fetcher registry
  `apply_layout` uses. Missing and unrecognised are the same failure:
  `unknown_source`.
- `placeholder` (optional) — shown as `text` when the source yields
  empty/null data (e.g. no PR currently loaded), matching `apply_layout`'s
  per-pane `placeholder` behavior for the same source.
- `view_id` (optional) — defaults to the caller's own focus.

**When to reach for this vs. `set_pane_content`:** use `refresh_pane_content`
to pull a *registered* source into your pane — the daemon fetches and shapes
the data itself, so you never hand-build the `items`/`kind` pairing (this is
exactly the mistake that motivated this tool: a `pr_list` payload nested
inside a `json_snapshot` envelope, which rendered as inert garbage instead of
the native PR list). Use `set_pane_content` for content you author yourself —
freeform text, an explicit error, an explicit loading state, or any data that
isn't behind a registered source.

**Loading only on first paint, then content, in one call.** The tool binds the
pane to `source` and broadcasts a transient `Loading` state immediately — but
only if the pane has never been painted before (see "`Loading` is a
first-paint-only signal" above). It then broadcasts the fetched content (or an
`Error` if the fetch failed, so the pane never sticks on `Loading`), as an
ordinary `PaneContent` broadcast. The JSON response returns only after the
terminal broadcast has been sent, so `{ "ok": true }` means the content is
actually on screen, not merely "a fetch was kicked off."

### Error codes

| Code | Meaning |
|------|---------|
| `unknown_source` | `source` is missing or isn't in the closed fetcher registry (broadcasts nothing) |
| `fetch_failed` | The fetcher ran but failed to produce content (an `Error` content is broadcast; where a `placeholder` applies, e.g. no PR loaded, this is `{ok:true}` instead) |
| `invalid_args` | Missing `pane_id` |
| `unidentified_caller` | No `view_id` and no caller `pty_id` to target |
| `not_supported` | Called against a non-daemon-hosted MCP server |

A call that fails validation (`invalid_args`, `unidentified_caller`,
`unknown_source`, `not_supported`) broadcasts nothing at all — not even
`Loading`.

---

## Phase 4 roadmap

- Fred `mailbox` and `calendar` panes will accept `JsonSnapshot` overrides.
- Teri `todos` will accept `JsonSnapshot` mutations (add/complete items).
- Removing the dirty-file mechanism; replacing with direct push to `pr_rx`.
- Pane-level focus (not just view-level) for multi-pane views.
