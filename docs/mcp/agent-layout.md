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
Content shape: `{ "type": "text", "text": "…" }` or
`{ "type": "json_snapshot", "value": … }`.

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
