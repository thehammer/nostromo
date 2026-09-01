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
`perri.list_pr_queue`, `perri.get_current_pr`, `perri.get_pr_diff`, and
`nostromo.get_file`). A binding is structural metadata stored on
`PaneRegistry` — `(tag, pane_id) -> (source, params)` — never content. It
answers one question: "does this pane refresh itself?"

### Lifecycle

- **One source per pane.** Binding a pane that's already bound replaces the
  old source (and its params); it never accumulates.
- **A binding can carry `params`** (curated-agent-views W2). `params` is the
  source's own argument object, passed through verbatim — it is what makes a
  source say *which* thing: `nostromo.get_file` is one source, but a pane
  bound to it also records which file it shows, or a daemon restart would
  repaint it as some other file. `PaneRegistry` knows nothing about the
  shape; only the fetcher validates it. A binding with no params behaves
  exactly as it did before the field existed.
- **`repl` can never be bound**, and a pane not currently a leaf of the
  focus's tree is silently refused (logged at `debug!`, not an error).
- **A binding dies with its pane.** `reset_panes` drops every binding for
  that tag; `set_pane_layout` with a tree that omits a previously-bound pane
  drops just that pane's binding.
- **A binding survives a daemon restart.** It's persisted alongside the pane
  tree in `~/.nostromo/daemon-panes.json`, params included. On restart, a
  binding whose source has been retired (no longer in `known_sources()`) is
  dropped, and the daemon repaints every reloaded binding immediately — no
  tool call needed. The store is versioned: `version: 3` carries
  `{source, params}` bindings, `version: 2` carries bare source-name strings
  (loaded as `params: null`), and an unversioned bare tree map is the
  original V1 format. All three still load.
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

As of `ios-curated-view-parity` W5 (below), this section and "Client
rendering (iOS)" describe two presentations of the *same* tree — macOS
renders every `Split` branch simultaneously with a tab strip per `Tabs`
region; iOS flattens the whole tree into one compact strip. Both key off the
same `LayoutChangeClassifier` semantics for when to honour `active` without
fighting the operator.

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

iOS got decoder correctness only in W1: a tabs node's children flattened into
the existing per-pane `TabView` alongside every other non-repl pane, with no
dedicated tabs UI, no `active`/`focused_pane` honouring, and tabs labelled
from the pane id rather than `labels`. `ios-curated-view-parity` W5 replaced
that with a real compact tab strip — see below.

### Client rendering (iOS)

iOS renders a non-repl pane's content in
`iOS/Nostromo/Views/Panes/PaneSurfaceView.swift`, keyed by the same
`PaneContentWire` switch macOS's `PaneContentView.swift` uses, but with no
AppKit siblings layered over it — SwiftUI only, all the way down. `text`,
`json_snapshot`, `loading`, `error`, and `unknown` render generically;
`pr_list` renders bucket-grouped `PerriPRRow`s at parity with macOS,
including the queue-row marking below and the swipe-to-approve confirmation
gate.

`code`, `diff`, `pr_conversation`, and `ticket` are **not rendered** — each
shows an honest stub instead (`PaneSurfaceStub` in NostromoKit is the single
source of the stub copy). This is deliberate, not a gap nobody got to: the
PRD's organizing rule is that "a surface may be absent, and a surface may be
simplified. A surface may never look complete when it isn't." Before
ios-curated-view-parity W2, `code` rendered its raw file text in a
monospaced view — no gutter, no scroll-to-anchor, no emphasis, discarding
`path`/`revision`/`first_line` entirely. That looked like a working file
view and wasn't one; the operator had no way to tell that the line an agent
pointed at wasn't the line she was reading. W2 deleted that rendering rather
than keep a half-built one, and each stub names the specific addressing it
can't show (a line, a comment, a section) rather than saying only "isn't
available." W7 (`code`), W8 (`diff`), and W9 (`pr_conversation`/`ticket`)
replace these stubs with real renderers; each later wedge updates this
section when it does, so this stays the one place a reader learns the two
clients aren't rendering the same thing.

`PaneAddress` (below) reaches iOS the same way it reaches macOS —
`DynamicFocusView` passes `layout.paneAddress[paneId]` into
`PaneSurfaceView` — and iOS's only present use of `anchor`/`emphasis` is
`pr_list` queue-row marking; the stub kinds above have no addressing to
render yet, matching what they show. `reason` is used more broadly — see the
tab strip below.

### Tabs and layout on iOS: the compact strip (`ios-curated-view-parity` W5)

Real split views are impractical on a phone-width screen, so iOS never
renders `Split`/`Tabs` as simultaneously-visible regions the way macOS does.
Instead, `NostromoKit`'s `TabPlan.build(tree:content:)` flattens the whole
`PaneTree` — depth-first, `Split` and `Tabs` children alike — into a single
ordered list of tab-strip entries, rendered by
`iOS/Nostromo/Views/Panes/TabStripView.swift` as one horizontal strip at the
top of the focus, with no chrome at all when the tree is a single `repl`
leaf. Two `Tabs` nodes in one tree stay as two contiguous runs in that
flattened order rather than interleaving — the strip reflects the tree's
shape, not a bare pane-id walk.

**Labels never come from a pane id.** A `tabs` node's `labels` are used
positionally against `children`; a leaf reached any other way (a `Split`
child, or a `tabs` entry whose label is missing or the array is too short)
falls back to a name derived from that pane's *content kind* —
`"Repl"`/`"Queue"`/`"Diff"`/`"File"`/`"Conversation"`/`"Ticket"`, or the
neutral `"View"` — never `paneId.capitalized`. This is `TabPlan.fallbackLabel`
in `Shared/NostromoKit/Sources/NostromoKit/Layout/TabPlan.swift`.

**`active`/`focused_pane` are honoured, but never fight the operator.**
`NostromoKit`'s `LayoutChangeClassifier` (a port of macOS's own — see above)
classifies each incoming tree against the previous one; `FocusRegionState`
(`Shared/NostromoKit/Sources/NostromoKit/Layout/FocusRegionState.swift`)
then moves the compact strip's frontmost pane only on a
`.activeTabOnly`/`.tabMembership`/`.splitTopology` change, never on
`.identical`/`.contentOnly` — a content-only republish (by far the most
frequent broadcast) must never yank the operator back to a tab they've since
navigated away from. `focused_pane`, when it names a pane still present,
always wins on top of that — this is what makes a deliberate `nostromo.show`
actually bring its tab to front on iOS, which it did not before W5.

**Unread is derived, not remembered.** `DaemonStore` tracks a
`paneContentVersion` per pane, incremented once for every `pane_content` push
it actually applies (never for one its `.loading`-suppression guard drops).
A pane is unread iff it isn't the strip's current frontmost pane and its
version has advanced past what `FocusRegionState` last recorded for it;
tapping a tab clears its mark immediately. The frontmost tab's
`PaneAddress.reason`, when present, renders as a dimmed caption beneath the
strip — the same "why am I looking at this" line macOS renders as a tab
caption (`TabRegionView.setCaption(_:for:)`).

**iOS resolves no placement.** The compact strip renders whatever tree the
daemon sends; there is no identity-reuse rule, no type ordering, no tab cap,
and no eviction policy on the client, and no split ratio is persisted
locally — every layout decision remains the daemon-side placement engine's
alone (see `nostromo.show` above).

See `docs/ios-verification.md` for how this rendering is verified given
`iOS/Nostromo.xcodeproj` has no test target.

Ambient activity (`ios-curated-view-parity` W4) is a related but separate
surface, deliberately not a pane or a tab: the `activity` view type never
reaches the pane tree on either platform (R1), so it doesn't appear in
`PaneSurfaceView`'s switch above. It's the always-present
`ActivityTickerBar`/`ActivityStreamsSheet` pair in
`iOS/Nostromo/Views/Activity/`, composed by `DynamicFocusView` above
`TranscriptView`'s input bar (or as a plain bottom inset on a non-repl
surface). See `docs/activity.md` for the full ambient-activity picture,
including where iOS's client-side retention bounds diverge from macOS's.

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

W1 transported every variant but rendered only `reason` — as a tab's caption,
dimmed and truncated, sourced from that tab's own last-pushed content. **W2
renders `anchor` and `emphasis` for the `code` and `diff` content kinds**
(see below); the remaining variants (`comment`, `section`, `queue_row`) still
decode, round-trip, and are otherwise inert. The dedup logic in
`pane_sources::run_pane_source_broadcaster` treats `address` as part of the
change-detection key, so an address-only push (identical content and
freshness) is still broadcast rather than silently dropped as a duplicate —
which is what makes "re-emphasise this same file without re-fetching it"
cheap. The two W2 sources derive an address from their `params`; every other
daemon-side call site passes `address: None`.

---

## Line-addressable code (`code` / `diff`) — curated-agent-views W2

Two content kinds render with a line-number gutter, scroll-to-line, and marked
ranges. Both are produced daemon-side; the client renders.

### `code` — a file at a revision

```json
{
  "kind": "code",
  "path": "src/ipc/session_manager.rs",
  "revision": "a1b2c3d",
  "first_line": 1,
  "text": "use std::..."
}
```

Text plus the line number its first line represents, rather than an array of
per-line objects: the client splits and numbers, which keeps a whole-file
payload the same size as the `text` variant it replaces.

Produced by **`nostromo.get_file`**, whose `params` are:

| field | meaning |
| --- | --- |
| `path` (required) | repo-relative, resolved against the focus's session cwd |
| `revision` | `"working"` (the on-disk tree), any git revision, or **omit** for the PR-under-review's head SHA when a PR is loaded, else the working tree |
| `anchor_line` | 1-based line to scroll to; becomes `address.anchor` |
| `emphasis` | `[{start, end}]` (or `[[start, end]]`) inclusive 1-based ranges; becomes `address.emphasis` |
| `reason` | one short phrase, rendered as the tab's caption |

A non-`working` revision is read via `git show <rev>:<path>` in the session
cwd, falling back to the GitHub contents API when the local clone doesn't have
the object — which is the common case for a PR head from a fork that was never
fetched. That fallback needs the network, so it only runs on the tool path;
the daemon's synchronous restart-repaint skips a pane it can't resolve locally
rather than replacing its content with an error.

**`nostromo.get_file` is deliberately not watch-driven.** A `file` pane is a
snapshot of a revision; live-updating it would contradict the revision it says
it is showing. It is also not re-fetched by the background broadcaster.

**Refusals.** Every one of these fails *before* anything is broadcast, so a
pane that already has content keeps it — a bad show never destroys what the
operator was reading. Each is a distinct code: `invalid_params`,
`unknown_path`, `path_escapes_root`, `not_utf8`, `anchor_beyond_eof`,
`invalid_emphasis_range`, `unresolvable_revision`. The one exception is a pane
this same call just put into `Loading` — there is nothing to preserve, and an
error beats a spinner that never resolves.

### `diff` — a PR's change, per file

```json
{
  "kind": "diff",
  "repo": "acme/web",
  "number": 42,
  "files": [
    {
      "path": "src/main.rs",
      "old_path": null,
      "status": "modified",
      "additions": 3,
      "deletions": 1,
      "hunks": [
        {
          "header": "@@ -10,3 +10,5 @@ fn main() {",
          "old_start": 10,
          "new_start": 10,
          "lines": [
            { "kind": "context", "old_n": 10, "new_n": 10, "text": "let x = 1;" },
            { "kind": "removed", "old_n": 11, "text": "let y = 2;" },
            { "kind": "added",   "new_n": 11, "text": "let y = 3;" }
          ]
        }
      ]
    }
  ],
  "too_large": false,
  "changed_files": 1
}
```

`status` is one of `added` / `removed` / `modified` / `renamed`; a line's
`kind` is one of `context` / `added` / `removed` / `meta`. A `meta` line is a
line the format carries but gives no content meaning to — notably
`\ No newline at end of file` — kept rather than dropped so the parser never
loses a line.

A diff needs this structure (where `code` does not) because
`anchor: {kind: "line", path, line}` must resolve to exactly one row, and only
something that has parsed the hunk headers knows which side of a hunk a given
line number lives on. **New-side numbering wins**; a line present only on the
old side resolves to its removal row.

Produced by **`perri.get_pr_diff`**, which is watch-driven off the same
current-PR channel as `perri.get_current_pr`, so a bound pane refreshes itself
with no tool call. Its optional `params` are `{anchor, emphasis, reason}`,
carrying wire-shaped `Anchor`/`Emphasis` values through to `address`.

**There is no display budget.** The whole diff is sent and the whole diff is
rendered. The fetch-level large-diff gate in `perri_pr_native.rs` is a
different thing — a protection against pulling a megabyte over the wire — and
when it trips, `too_large` is `true`, `files` is empty, and the client says so
explicitly and names `changed_files`. A stated limit is not silent truncation;
the old client-side 150-line cap was, and it is gone.

---

## Markdown blocks and `pr_conversation` — curated-agent-views W3

Markdown (a PR description, a review comment) is parsed **server-side** with
`pulldown-cmark` into a block model, and travels on the wire as structured
data — never as a markdown string the client re-parses. This is what makes a
fenced code block in a PR description or review comment render as an actual
code block, monospaced with its indentation intact, instead of literal
backticks and flattened prose.

```json
{ "kind": "code_block", "lang": "rust", "text": "fn main() {\n    todo!()\n}" }
```

An `MdBlock` is one of `paragraph`, `heading` (`level` 1–6), `code_block`
(`lang` is the fence's language token, `null` for an unlabelled fence or an
indented block), `list` (`ordered`, optional `start`, `items: [[MdBlock]]`),
`quote` (`blocks: [MdBlock]`), `table` (`header`/`rows` of `[[MdSpan]]`), and
`rule`. An `MdSpan` — inline content inside a block — is one of `text`,
`code`, `emph`/`strong`/`strike` (each wrapping nested `spans`), `link`
(`spans`, `url`), and `image` (`alt`, `url`). Both are defined once in
`src/ipc/protocol.rs` and reused by `ticket` (curated-agent-views W4, below)
— this is not a `pr_conversation`-specific format.

### `pr_conversation` — a PR's description and comment/review threads

```json
{
  "kind": "pr_conversation",
  "repo": "acme/web",
  "number": 42,
  "title": "feat: add user authentication",
  "author": "alice",
  "url": "https://github.com/acme/web/pull/42",
  "body": [ { "kind": "paragraph", "spans": [{ "kind": "text", "text": "..." }] } ],
  "threads": [
    {
      "id": "inline-9001",
      "kind": "inline",
      "path": "src/main.rs",
      "line": 42,
      "diff_hunk": "@@ -40,3 +40,3 @@ ...",
      "resolved": false,
      "comments": [
        { "id": "9001", "author": "bob", "created_at": "2024-01-01T00:00:00Z",
          "body": [ { "kind": "code_block", "lang": null, "text": "..." } ] }
      ]
    }
  ],
  "conversation_error": null
}
```

`kind` on a thread is `issue` (a top-level PR conversation comment), `review`
(a whole-PR review with a written body), or `inline` (a review-comment thread
anchored to a file/line). Inline threads are assembled by walking each
comment's `in_reply_to_id` up to its root; a reply whose stated root isn't in
the fetched page becomes a root of its own rather than being dropped.
`resolved` is always `false` today — GitHub's REST API doesn't expose
inline-thread resolution, only its GraphQL API does.

Produced by **`perri.get_pr_conversation`**, watch-driven off the same
current-PR channel as `perri.get_current_pr` and `perri.get_pr_diff` — a bound
pane refreshes itself with no tool call. Its optional `params` are
`{anchor, emphasis, reason}`, the same generic `Anchor`/`Emphasis` passthrough
`perri.get_pr_diff` uses; the variant that applies here is
`{"kind": "comment", "id": "..."}` for both. **A `params.anchor`/`params.emphasis`
naming a comment id absent from the fetched conversation is refused —
`unknown_comment_id` — leaving the pane's existing content untouched,** the
same "a bad show never destroys what you were reading" discipline `code`/`diff`
apply to a bad line.

**Partial failure is explicit.** The daemon makes three REST calls per fetch
(issue comments, review comments, reviews); if the PR fetch itself succeeds
but one or more of those three fails, `conversation_error` names which, and
`threads` carries whatever the other calls returned — never blanked, and never
presented as a complete conversation it isn't.

---

## `ticket` — an issue-tracker ticket — curated-agent-views W4

```json
{
  "kind": "ticket",
  "provider": "jira",
  "key": "CORE-2841",
  "summary": "Referral status doesn't sync to the portal",
  "status": "In Progress",
  "assignee": "Alice Smith",
  "url": "https://carefeed.atlassian.net/browse/CORE-2841",
  "sections": [
    { "name": "description", "heading": null,
      "blocks": [ { "kind": "paragraph", "spans": [{ "kind": "text", "text": "..." }] } ] },
    { "name": "acceptance_criteria",
      "heading": [{ "kind": "text", "text": "Acceptance Criteria" }],
      "blocks": [ { "kind": "list", "ordered": false, "start": null, "items": [ ["..."] ] } ] }
  ],
  "comments": [
    { "index": 1, "author": "bob", "created_at": "2024-01-01T00:00:00Z",
      "body": [ { "kind": "paragraph", "spans": [{ "kind": "text", "text": "..." }] } ] }
  ]
}
```

`provider` names which registered issue-tracker backend produced this ticket
— a request field, not a view type, so Linear or GitHub Issues can register a
second provider later without a new `PaneContentWire` variant. v1 registers
exactly one provider, `jira`.

`sections` splits the ticket's description on its own headings: every block
before the first heading is the `"description"` section (`heading: null`);
each subsequent heading starts a new section whose `name` is that heading's
text, lowercased/normalized, then resolved against an aliasable table (see
below) — so `## Acceptance Criteria`, `## AC`, and `## Definition of Done` all
resolve to the same canonical `"acceptance_criteria"` name. `comments` is
chronological and 1-indexed; a comment is addressable the same way a section
is, via the reserved name `"comment:<index>"`.

Produced by **`nostromo.get_ticket`**, params `{ provider, key, anchor?,
emphasis?, reason? }` — the same generic `Anchor`/`Emphasis`/`reason`
passthrough `perri.get_pr_diff`/`perri.get_pr_conversation` use; the variant
that applies here is `{"kind": "section", "name": "acceptance_criteria"}` (or
`"comment:3"`) for both `anchor` and `emphasis`. Unlike every other source,
`ticket` is **not watch-driven** — a ticket is a one-shot fetch, not a live
subscription — and it is the first source that talks to a service outside
GitHub.

**Refusals are specific, and never render as raw text or blank the pane:**

| `error` | Meaning |
|---|---|
| `unsupported_provider` | `provider` isn't registered. The daemon's log/response names every provider it *does* support. |
| `provider_unconfigured` | `provider` is registered (`jira` always is) but has no resolved credentials — see `docs/jira-provider.md`. The message names the credentials file and all three variable names. |
| `unknown_ticket` | The provider's backend has no such ticket (Jira returned 404). |
| `unknown_section` | `anchor`/`emphasis` named a section (or `comment:<n>`) that doesn't exist on *this* ticket — the message lists every section that does. |
| `fetch_failed` | The provider ran but failed for some other reason (network error, non-2xx status, malformed response) — this one does **not** leave the pane's content untouched, the same way a `code`/`file` fetch failure on a live source stays loud. |

**A short in-memory TTL cache** (60 seconds, keyed `(provider, key)`, never
persisted across a daemon restart) means repeatedly showing the same ticket —
including the daemon's own startup repaint of a bound `ticket` pane — costs at
most one HTTP request per window, not one per repaint.

---

## Placement rules (`views.yaml`) — curated-agent-views W5

`nostromo.show` (see `docs/mcp/tools.md`) is backed by a deterministic
placement engine (`src/mcp/views/`) that decides where a view lands from data
alone — no LLM inference, no hidden state beyond what's derived from the
pane registry. This section documents the rules-as-data (`views.yaml`) and
where the engine enforces each of the PRD's eight placement rules, R1–R8.

### The `region` name on a `PaneTree::Tabs` node

A `Tabs` node gained an optional `region` field (`src/ipc/protocol.rs`):
`None` for every tabs node written before W5, and for any tabs node an agent
builds by hand through `apply_layout`/`set_pane_layout` — **the layout schema
DSL has no `region:` keyword.** `SchemaNode::to_pane_tree`
(`src/mcp/layout_schema.rs`) always emits `region: None`; a named region is
exclusively an artifact of the placement engine itself, set only by
`views::tree::build_tabs` when the engine creates or rebuilds the `detail`
region for a curated show. The name is how `nostromo.show` finds "the detail
region" again in a tree it is itself about to mutate, and it survives a
daemon restart because the pane tree is persisted. A tabs node with `region:
None` is invisible to the placement engine: an agent's own
`apply_layout`-built tabs region behaves exactly as it did before W5, and the
engine will never adopt, reuse, or evict any of its tabs.

### `views.yaml` schema

The engine's entire input, besides the derived view state and the request.
Compiled-in default at `src/mcp/views.yaml`; shadowed **wholesale** (not
merged) by `~/.nostromo/views.yaml` if present, re-read fresh on every
`nostromo.show` call — the same no-caching, override-wins discipline
`~/.nostromo/layouts/<name>.yaml` follows for named layouts. A present-but-
malformed override is `invalid_views_config`, not a silent fallback to the
compiled-in rules — an operator who edited the file wants to know the edit is
broken, not have it look like it had no effect.

```yaml
regions:
  <region-name>:
    tabbed: true | false            # required
    pane: <pane-id>                 # required when tabbed: false — the one pane this region is
    pane_prefix: <string>           # required when tabbed: true — new tab ids are "<prefix>.<n>"
    tab_cap: <int>?                 # optional; omitted means unbounded
    evict: least_recently_focused_unpinned?  # optional; omitted means never evict (a cap is simply exceeded)
    create:                         # ordered candidates for bringing the region into existence (D5)
      - relative_to: <pane-id>      # the pane id to split; first whose pane is live wins
        position: split_left | split_right | split_above | split_below
        ratios: [<f32>, <f32>]      # exactly two

views:
  <view-type-name>:
    region: <region-name>           # R1: this type's one home region
    order: <u32>                    # R3: sort key among the region's tabs, ties break on identity
```

Validated at load: every `views.*.region` must name a declared region; an
untabbed region needs `pane`; a tabbed region needs `pane_prefix`; every
`create` rule needs exactly two ratios and a recognised `position`. The
compiled-in default (`src/mcp/views.yaml`):

```yaml
regions:
  queue:
    tabbed: false
    pane: queue
    create:
      - { relative_to: repl, position: split_above, ratios: [0.6, 0.4] }
  detail:
    tabbed: true
    tab_cap: 6
    evict: least_recently_focused_unpinned
    pane_prefix: detail
    create:
      - { relative_to: queue, position: split_right, ratios: [0.5, 0.5] }
      - { relative_to: repl, position: split_above, ratios: [0.6, 0.4] }

views:
  review_queue: { region: queue, order: 0 }
  pr_conversation: { region: detail, order: 1 }
  pr_diff: { region: detail, order: 2 }
  ticket: { region: detail, order: 3 }
  file: { region: detail, order: 4 }
```

### R1–R8, and where each is enforced

| Rule | Enforced |
|---|---|
| **R1** home region | `views.yaml`'s `views.<type>.region`, resolved in `placement::place`. A request whose home region doesn't exist yet gets a `create_region` intent (see below); a non-tabbed region already holding a *different* view refuses the show (`region_not_tabbed`) — this is what keeps the queue region single-purpose. |
| **R2** identity reuse | `placement::place` — a live tab whose `(view_type, identity)` matches the request is reused: re-anchored, re-labelled, brought to front. Anchor/emphasis/reason are not part of `ViewIdentity`, so "the same file at a different line" is the same view by construction, not by a special case. |
| **R3** new identity, new tab | `placement::place`'s `insertion_index` — a new tab is inserted at the position `(views.<type>.order, identity.key())` dictates, so where a tab lands is a function of what it holds, never of arrival order. |
| **R4** cap and eviction | `placement::place`'s `pick_victim`, run only when adding a *new* tab would push the region over `tab_cap`: the least-recently-focused tab that is neither frontmost nor pinned, ties breaking leftmost. A region every tab of which is pinned or frontmost simply runs one over the cap rather than refusing the show. |
| **R5** focus asymmetry | `placement::place` unconditionally makes the target tab frontmost, new or reused, by construction of `tab_index`; `tools::show` sends `FocusLayout` with `focused_pane` set to it unconditionally. There is no configuration knob for this — a deliberate, settled PRD decision. |
| **R6** no pointless motion | **Enforced on the client, not here.** The daemon has no way to know what the operator's viewport is currently showing, so `nostromo.show` always sends the anchor and lets W2's client-side `ScrollDecision` decide whether that means actually scrolling. This is the one rule with no representation anywhere in `src/mcp/views/`. |
| **R7** modals are not a content channel | **Enforced by omission.** `ViewType` has no modal variant and `nostromo.show`'s schema has no free-text content field (see `docs/mcp/tools.md`) — there is no plumbing through which a decision could be routed as a "view." W6 owns the decision surface. |
| **R8** PR change resets | `placement::place`, when a `pr_conversation`/`pr_diff` show names a `(repo, number)` other than the one currently live in the detail region; and `placement::reset_for_pr_change`, called from `tools::show::reset_for_pr_change`, which `perri.load_pr`/`perri.clear_current_pr` invoke when the PR under review itself changes. Both close every `file`/`ticket` tab and the previous PR's conversation/diff tabs, keeping only the new PR's. |

### The `perri-curated` layout

`src/mcp/layouts/perri-curated.yaml` is a second compiled-in named layout,
registered alongside `perri-standard`. Its starting tree is just a queue and
a REPL — `split(vertical, [leaf queue, leaf repl], [0.6, 0.4])` — with `queue`
bound to `perri.list_pr_queue`/`pr_list`, matching the PRD's walking scenario:
"the top region shows only the review queue … nothing else has anything to
say yet." There is no `diff` pane and no `detail` region in the layout
itself; the detail region comes into existence only when the placement engine
splits it off on the first `nostromo.show` of a `pr_conversation`, `pr_diff`,
`file`, or `ticket` view, and it is removed again when its last tab closes.

This differs from `perri-standard`, which declares a fixed three-pane
`queue`/`diff`/`repl` tree up front, with `diff` bound to
`perri.get_current_pr`. **`perri-standard` is unchanged and stays
byte-identical** to its pre-W5 content — it is the fallback path for a caller
still driving the raw pane tools (`create_pane`, `set_pane_content`,
`apply_layout`, `refresh_pane_content`, …) directly rather than
`nostromo.show`, and its non-regression (including live refresh, restart
repaint, and `badly_stale` marking) is a stated acceptance criterion of this
wedge.

### Creating and removing the detail region

The `detail` region does not exist in `perri-curated`'s tree until the first
`nostromo.show` that needs one. At that point the engine picks the first
`create` candidate from `views.yaml` whose `relative_to` pane is actually
live in the focus — `queue` (split right, `[0.5, 0.5]`) if the queue pane
exists, else `repl` (split above, `[0.6, 0.4]`) as a fallback for a bare
focus with no queue at all — and the applier (`tools::show::apply_to_tree`)
builds the tabs node via `views::tree::insert_beside`. This is the same
tree-mutation path R4's eviction and R8's reset both use, so a region's
creation and its removal are not separate machinery: `views::tree::
remove_tabs_region` collapses the split back out when a region's last tab is
closed, whether that closure came from R4 evicting down to nothing (never
happens in the compiled-in rules, since eviction only fires when adding a
tab, which always leaves at least one) or, in practice, from R8's reset
leaving zero survivors in the region.

---

## Pane ids are recycled — client state must be too

`new_pane_id` (`src/mcp/views/placement.rs`) allocates the lowest free
`<prefix>.<n>` id for a tabbed region (e.g. `detail.0`) — it does not mint a
fresh, ever-increasing id. The same id is reissued the moment its previous
occupant's tab closes: R8's PR-change reset tears down every
`pr_conversation`/`pr_diff`/`file`/`ticket` tab in the detail region, and the
very next `nostromo.show` can hand `detail.0` right back out for a
**completely different view**.

This makes a pane id a **slot**, not an identity. A client that keys any
per-pane cache — a rendered document, a scroll offset, a "last rendered this
content, skip the repaint" check, whatever a given content-kind renderer
holds onto between pushes — by pane id alone, and never clears that cache
when the pane's occupant changes, will go on rendering a new PR's diff with
the previous PR's document still cached underneath it: a gutter, a cached
line count, or an idempotent-push guard built on top of that stale cache is
now describing a document nobody asked for.

Two things a client must do to stay correct under recycling:

- **Prune per-pane content/freshness/address state down to the pane ids
  named by the *current* tree, on every structural layout broadcast** — not
  only when a later content push happens to touch that pane. A structural
  broadcast and the content push(es) that follow it are separate messages;
  there is a real (short) window between them where a recycled pane id has
  no content yet. Show a plain "waiting for content…" placeholder in that
  window — that's the correct, honest intermediate state — rather than
  carrying the previous occupant's content forward into it.
- **Clear a content-kind renderer's own cached state the moment that pane
  stops being rendered as that kind** — not just on a content *change*
  within the same kind, but on the transition away from the kind
  altogether. Otherwise a renderer that's hidden and later reshown
  resurfaces holding whatever document it last had, independently of what
  the pane actually contains now — e.g. a line-number gutter left over from
  a file that isn't on screen anymore, drawn over whatever text a different
  kind is now showing in the same space.

(Nostromo's macOS client implements both of these — see
`AppStore.swift`'s `.focusLayout` handling for the prune, and
`DynamicFocusView.swift`'s `PaneContentNSView.update` /
`CodeContentView.clearContent()` and its siblings for the per-kind clear.)

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
