# Nostromo MCP — Agent-Driven Pane Layout (Phase 1)

This is the **daemon-hosted** layout surface: it lets a daemon-hosted agent
session assemble its own pane workspace on its first turn, instead of the shape
being frozen in a hand-written Swift view. It is the foundation of the
"agent is the window manager" vision (Phase 1: imperative pane tools).

It is distinct from — and additive to — the TUI's in-process MCP server
(`docs/mcp/panes.md`), which is unchanged.

## Architecture

```
agent (claude, --agent <name>)
  │  stdio MCP frames
  ▼
nostromo-mcp-bridge   ── Unix socket (NOSTROMO_MCP_SOCKET) ──▶  nostromd
  (Hello { pty_id = focus tag })                                  │
                                                                  ├─ McpServer (daemon-hosted)
                                                                  ├─ PaneRegistry  (per-focus tree, persisted)
                                                                  └─ broadcast::Sender<ServerMsg>
                                                                        │  FocusLayout / PaneContent / FocusCreated
                                                                        ▼
                                                       macOS / iOS clients (Topic::Layout) render the tree
```

- The daemon is the **single source of truth** for every focus's pane structure.
  A focus is keyed by its session `tag`.
- A focus's structure is a **pane tree** (a recursive split tree). On a fresh
  spawn it is a single `repl` leaf; the agent grows it with `create_pane`.
- Pane **content** is a separate broadcast (`PaneContent`) carrying no geometry,
  so an operator's manual drag-resize survives content refreshes — only a
  structural call (`create_pane` / `reset_panes` / `set_pane_layout`) re-declares
  geometry.

## Identity

A daemon-hosted session is spawned with:

| Env var | Value |
|---------|-------|
| `NOSTROMO_MCP_SOCKET` | the daemon MCP socket (`~/.nostromo/mcp-daemon.sock` by default) |
| `NOSTROMO_PTY_ID` | the focus **tag** (the identity key the bridge sends in its Hello frame) |
| `NOSTROMO_VIEW_ID` | the focus tag |

plus `--mcp-config <~/.nostromo/mcp-bridge.json>` registering the
`nostromo-mcp-bridge` stdio server. `get_self` and the pane tools resolve the
caller's focus from the Hello `pty_id`.

## Pane tree wire shape

```json
{ "kind": "leaf", "pane_id": "repl" }

{ "kind": "split", "direction": "horizontal",
  "children": [ { "kind": "leaf", "pane_id": "repl" },
                { "kind": "leaf", "pane_id": "jobs" } ],
  "ratios": [0.5, 0.5] }
```

Invariants the daemon upholds on every mutation:

1. exactly one `"repl"` leaf per focus,
2. pane ids unique within a focus,
3. every split is well-formed (`children.len() == ratios.len() >= 2`),
4. `reset` + the identical create sequence ⇒ a byte-identical tree
   (idempotent rebuild).

## Tools

### `nostromo.create_pane({ pane_id, position, relative_to, view_id? })`

Splits the `relative_to` leaf, inserting `pane_id` on the side implied by
`position` (`split_left` / `split_right` / `split_above` / `split_below`). Omit
`view_id` to target the caller's own focus. Returns `{ "ok": true, "tree": … }`.

Errors: `unknown_view`, `unknown_pane` (relative_to absent), `duplicate_pane`,
`invalid_position`.

### `nostromo.reset_panes({ view_id? })`

Collapses the focus back to a single `repl` pane (used by a restarting agent
before rebuilding). Returns `{ "ok": true }`. Error: `unknown_view`.

### `nostromo.set_pane_layout({ view_id, ratios })`

Re-declares layout. `ratios` may be either a full pane **tree** (an object with
`"kind"`, or `{ "tree": <PaneTree> }`) — replaces the tree wholesale after
validating invariants — or a flat **ratio map** `{ "<pane_id>": <ratio> }` that
updates the ratios of any split whose direct leaf children are named, leaving
structure untouched. Broadcasts a structural `FocusLayout`.

### `nostromo.set_pane_content({ view_id, pane_id, content })`

Pushes content to a pane without touching geometry. Broadcasts `PaneContent`.
Content shape: `{ "kind": "text", "text": "…" }` or
`{ "kind": "json_snapshot", "value": … }`.

### `nostromo.create_focus({ agent, title, working_directory?, initial_context? })`

Spawns a new persistent focus running `agent`, seeds its first turn with
`initial_context`, registers it, and broadcasts `FocusCreated` so every client
adds the tab. Idempotent: a live focus with the derived tag returns its
existing `focus_id`. Returns `{ "focus_id": "<agent>-<slug(title)>" }`.

Errors: `invalid_working_directory` (not an absolute existing dir),
`spawn_failed`.

## Error contract

Every tool returns either a success object or
`{ "error": "<snake_case_code>", "detail"?: "…" }` — never a panic, never a
malformed frame. The daemon-hosted tools mutate the registry under its mutex and
broadcast synchronously, so they do not use the 5 s event-loop command timeout
the TUI path uses.

## The curated flow (curated-agent-views W5)

The tools above are the imperative window-manager surface: an agent decides
the pane shapes and pushes content into them itself, call by call. W5 adds a
second, narrower surface over the same machinery for a caller that only wants
to *point at things*, not manage geometry:

```
nostromo.apply_layout({ "name": "perri-curated" })   // once, at session start
nostromo.show({ "type": "pr_diff", "target": { "repo": "acme/web", "number": 42 } })
nostromo.show({ "type": "file", "target": { "path": "src/main.rs" },
                "anchor": { "kind": "line", "line": 88 }, "reason": "..." })
```

`apply_layout name: perri-curated` assembles the starting tree — a queue and
a REPL, nothing else (see `docs/mcp/panes.md`'s "The `perri-curated` layout"
section). From there, every subsequent `nostromo.show` call is what used to
be a `reset_panes`/`create_pane`/`set_pane_layout`/`set_pane_content` (or
`refresh_pane_content`) sequence: `show` resolves where the requested view
belongs, creates the `detail` region the first time one is needed, opens or
reuses a tab, fetches the view's content server-side, and brings it to front
— all in one call, with the placement decision made by a deterministic
engine rather than by the calling agent. See `docs/mcp/tools.md`'s
"`nostromo.show`" section for the full argument and error contract, and
`docs/mcp/panes.md`'s "Placement rules" section for how a show is placed.

**This does not remove the raw tools above.** `create_pane`, `reset_panes`,
`set_pane_layout`, `set_pane_content`, `set_pane_focus`, `apply_layout`, and
`refresh_pane_content` are unchanged, still callable, and still the only way
to assemble a layout that isn't one of the five curated view types — this is
exactly how Mother's, Fred's, and Teri's views work today, and how Perri's own
review flow works until her prompt is rewritten to use `show` instead (see
`docs/mcp/tools.md`'s "Per-caller tool withdrawal" section — the mechanism
that will eventually narrow Perri specifically to the curated surface ships
inert, and stays inert until that prompt change lands).

## Transport trust

`nostromd` serves the Mac app over a Unix socket and iOS/LAN clients over an
unauthenticated TCP listener. Each connection is tagged with a `PeerTrust`
(`src/ipc/peer.rs`) by the accept loop that received it: Unix → `LocalOther`,
TCP → `Tcp`. A network (`Tcp`) peer is **never** sent Teri/Fred data, whatever
topics it subscribed to (an empty topic list means "everything"):

- `fred_state`, `teri_state`, `work_source_status`, `work_snapshot`,
  `teri_picks`, `work_detail`, `work_send_preview` and `work_send_result` frames
  are dropped before topic matching, and are never replayed from the retained
  cache. After subscribing, a network peer gets one `withheld` frame naming
  the topics (`fred`, `teri`, `work`).
- `work_detail_request`, `work_refresh`, `picks_refresh`,
  `work_send_preview_request`, `work_send` and `fred_seed` are refused with
  `requires_secure_connection` (in the matching targeted result frame) and
  change nothing.
- Anything that can carry the same text through an *older* frame is scoped by
  focus tag (or Mother job id) and withheld for a **sensitive** tag: session
  transcripts (`session_turns`, `session_turn_delta`, `session_state`,
  `session_summary_update`, ...), `pane_content`, `focus_layout`,
  `notification`, `decision_request` / `decision_resolved`, `activity` /
  `activity_snapshot`, per-focus `perri_state`, and the Mother job frames of a
  work-derived job. This applies on replay, broadcast and targeted paths.
  Unattributed `activity` events are withheld.
- A tag is sensitive when it is `fred` / `teri`, runs the `fred`/`teri` agent
  (any tag), or was created from work items (`work_send`) or through
  `nostromo.create_focus` with `initial_context` or from a Fred/Teri session
  (`SensitiveTags`, persisted beside `daemon-sessions.json`). A network peer's
  `session_attach` / `session_send` / `session_control` / `session_interrupt` /
  `session_spawn`, `close_pane`, `mother_action` / `mother_resume` for a
  sensitive tag or job are refused with `requires_secure_connection`.
- `session_list_resp` and `mother_jobs` omit sensitive entries. In focus frames
  a network peer sees no `project_path`, `label` or `session_summary`, and a
  sensitive focus shows only its agent name (a work-derived tag is replaced
  by an opaque id).

Every `ServerMsg` / `ClientMsg` variant is classified in `peer.rs` through an
exhaustive `match`, so adding a variant does not compile until it is classified.
That is **not** a security audit: the whole unauthenticated listener is tracked
separately (`.claude/wip/nostromd-tcp-47100-exposure`). `pty_spawn`,
`focus_registry_push`, `perri_action`, `decision_answer` for ordinary focuses and
the content of non-sensitive focuses are knowingly still reachable by a network
peer; `peer.rs` lists them in a block comment.

### Version skew (`Welcome.features`)

An older daemon drops a connection whose `subscribe` names a topic it does not
know. `Topic` now decodes unknown names as `unknown` (ignored), and the daemon's
`welcome` carries an additive `features` list (`"work"`). The Mac client
subscribes to the base topics immediately and sends a second `subscribe`
adding `work` only when that connection's `welcome` lists it; a later
`subscribe` on a live connection replaces the topic list and replays retained
frames for the topics it adds (never to a network peer).

## Native panes

Some panes are hosted natively by the Mac app rather than filled by an agent:
`mother_queue` (Mother), `teri_surface` (Teri) and `fred_hud` (Fred). The daemon
seeds each focus's default layout when the Mac pushes its focus registry (a
Teri/Fred layout that already exists without its native pane is wrapped, native
pane first, so nothing is lost). `teri_surface` and `fred_hud` cannot be closed
(`close_pane` returns `not_closable`) or dropped: `apply_layout` / `set_layout`
on `teri` or `fred` with a tree that lacks the focus's native pane is refused
with `native_pane_required` and the layout is left unchanged. `reset_panes`
restores the default native layout for those two focuses.
