# MCP Phase 1 — Scaffolding: socket transport, env injection on PTY spawn, end-to-end `get_self`

## Context

Nostromo's PTY-hosted agents (Perri, Fred, Mother, Claudia, Cody, Kennedy,
Teri) currently communicate with the host TUI by writing JSON snapshots into
`~/.claude/state/<agent>/*.json` and `touch`-ing dirty sentinel files. Several
sources (`src/data/perri_pr_native.rs:43`, `src/data/perri_queue_native.rs:110`,
`src/data/fred_mailbox_native.rs:69`, `src/data/fred_calendar_native.rs:59`)
poll those sentinels via `src/data/dirty_file.rs`. The convention has three
problems documented in detail in the brief: bash permission-prompt noise from
compound `touch`/`rm` commands, convention rot across agent.md files, and zero
introspection — an agent has no structured way to ask "what view am I in?"

This phase establishes the foundation for an MCP server hosted in-process by
Nostromo. Goal: prove the wiring end-to-end with **one** capability
(`nostromo.get_self`) so we can validate the transport, library choice, env
injection, and tool-registration flow before building the full surface in
Phases 2–4.

There is no Jira ticket; tracked via `docs/mcp-phase{1..4}.md`.

### Library choice (resolved in this phase)

Investigation summary (do not re-litigate during execution unless the
attempted dependency fails to build):

- **`rmcp` (official Rust MCP SDK, `modelcontextprotocol/rust-sdk`)** — actively
  maintained, supports stdio + SSE + WebSocket + custom transports, provides
  derive-macros for tool registration. Heavy dep tree but built on `tokio` +
  `serde` + `schemars`, which we already use.
- **Hand-rolled JSON-RPC over Unix socket** — Nostromo already has length-
  prefixed JSON framing in `src/ipc/codec.rs` and a working accept-loop pattern
  in `src/ipc/server.rs`. We'd reimplement the MCP handshake (`initialize`,
  `tools/list`, `tools/call`) plus JSON Schema generation. Maybe 600 lines.
- **`mcp_rust_sdk` crate** — community crate, less maintained; skip.

**Decision: use `rmcp`** with the **stdio transport per connection**, served
**over a Unix socket** (each accepted socket connection bridges to a fresh
rmcp `Service` instance speaking the MCP framing on top of the socket bytes).
Rationale: tools/list and JSON Schema generation come free; matches what
`claude` CLI expects when configured with `"type": "stdio", "command":
"socat", "args": ["-", "UNIX-CONNECT:..."]` (or equivalent shim). If `rmcp`
proves unworkable (e.g. transport coupling) **fall back to hand-rolled
JSON-RPC** — flag this in the PR body and proceed; do not block the phase.

A small companion shim binary (`nostromo-mcp-bridge`) connects to the socket
and pipes stdio to it; Claude Code's MCP config points to that bridge.

## Target
- **Repo:** nostromo
- **Branch:** feat/mcp-phase1
- **Base:** origin/main

## Files to change

- `Cargo.toml` — add deps:
  - `rmcp = { version = "0.x", features = ["server", "transport-io"] }` (pick
    the current latest on crates.io at execution time; record the version in
    the commit message). If install fails, fall back to a hand-rolled
    implementation and **omit the dep** — see Approach §6.
  - `schemars = "0.8"` for JSON Schema derivation if rmcp doesn't re-export it.
  - No other new deps; `tokio`, `serde`, `serde_json`, `anyhow`, `tracing`,
    `uuid` already present.
  - Add `[[bin]] name = "nostromo-mcp-bridge" path = "src/bin/nostromo_mcp_bridge.rs"`.

- `src/lib.rs` — register `pub mod mcp;`.

- `src/mcp/mod.rs` — **new**. Module root. Re-exports `Server`, `ToolRegistry`,
  `SelfInfo`. Documents the protocol and socket path resolution.

- `src/mcp/socket.rs` — **new**. `pub fn default_socket_path() -> PathBuf` →
  `$NOSTROMO_MCP_SOCKET` if set, else `~/.nostromo/mcp.sock`. Mirror the
  pattern from `src/ipc/protocol.rs:31-39`.

- `src/mcp/server.rs` — **new**. `pub struct McpServer` with:
  - `pub async fn bind(path: PathBuf, state: McpSharedState) -> Result<Self>`
    — removes any stale socket file, binds `UnixListener`, spawns an accept
    task. The accept task hands each connection to `serve_connection(...)`
    which constructs an rmcp `Service` (or, fallback path, a minimal
    JSON-RPC loop) bound to that socket's read/write halves.
  - `pub fn socket_path(&self) -> &Path`.
  - `pub async fn shutdown(self)` — graceful close.

- `src/mcp/state.rs` — **new**. `pub struct McpSharedState` (cheap-`Clone`,
  built around `Arc`s) holding:
  - `pub event_tx: mpsc::UnboundedSender<AppEvent>` — for future mutating
    tools to post `AppEvent::McpCommand(...)`.
  - `pub views_meta: Arc<RwLock<Vec<ViewMeta>>>` — static metadata about
    registered views (id, title, pane ids), populated at startup by `app::run`.
  - `pub ptys: Arc<RwLock<HashMap<String, PtyIdentity>>>` — `pty_id` (from
    `NOSTROMO_PTY_ID` env var, see below) → which view spawned it. Populated
    on PTY spawn, removed on Drop.
  - Phase 1 only needs `views_meta` and `ptys`; expand in later phases.
  - `pub struct PtyIdentity { pub view_id: &'static str, pub session_id: String, pub spawned_at: SystemTime }`.
  - `pub struct ViewMeta { pub id: &'static str, pub title: String, pub pane_ids: Vec<&'static str> }`.

- `src/mcp/tools/mod.rs` — **new**. Tool registry. In Phase 1 register exactly
  one tool: `nostromo.get_self`. Use rmcp's derive (or, fallback, a manual
  match on tool name).

- `src/mcp/tools/get_self.rs` — **new**. Handler:
  - Reads the caller's `NOSTROMO_PTY_ID` from the rmcp request context (rmcp
    exposes the spawned-process env via stdio; the bridge binary forwards
    `NOSTROMO_PTY_ID` from its own env into the rmcp `initialize` extras OR
    Nostromo identifies the caller by socket peer-cred + connection-time
    `Hello` payload — see Approach §3).
  - Looks up `PtyIdentity` in `McpSharedState::ptys`.
  - Returns a `SelfInfo` JSON object:
    ```json
    {
      "view_id": "perri",
      "view_title": "Perri",
      "pty_id": "<uuid>",
      "session_id": "<uuid>",
      "pane_ids": ["pr_queue", "diff", "repl"],
      "nostromo_version": "0.1.0"
    }
    ```
  - If the caller is unknown (no `NOSTROMO_PTY_ID` or no matching record):
    return a tool error `{ "error": "unidentified_caller" }`; do not panic.
  - Unit test with a stub `McpSharedState`.

- `src/bin/nostromo_mcp_bridge.rs` — **new**. ~60 line binary:
  1. Reads `NOSTROMO_MCP_SOCKET` and `NOSTROMO_PTY_ID` from env.
  2. Connects to the Unix socket.
  3. On connect, sends a one-line JSON `Hello { pty_id }` frame so the server
     can correlate this connection with the PTY identity. (This is our
     identification channel — see Approach §3.)
  4. Pipes stdin → socket and socket → stdout bidirectionally with two
     `tokio::io::copy` tasks; exits when either side closes.
  5. Errors go to stderr; never panics.

- `src/pty/host.rs:44-52` — extend `PtyHost::spawn` to inject env vars into
  `cmd_builder` before `spawn_command`:
  - `NOSTROMO_VIEW_ID=<view_id>` (the existing `view_id: &'static str` arg).
  - `NOSTROMO_PTY_ID=<uuid>` — generate a fresh `Uuid::new_v4().to_string()`
    inside spawn. Return it through a new struct field `pub pty_id: String`
    so callers/state can record it.
  - `NOSTROMO_SESSION_ID=<uuid>` — generate similarly. Field `pub session_id: String`.
  - `NOSTROMO_MCP_SOCKET=<path>` — full path to the MCP socket (read from a
    new arg threaded through `PtyFactory::spawn`; default to
    `mcp::socket::default_socket_path()`).
  - Register the new identity in `McpSharedState::ptys` after a successful
    spawn (threaded through `ViewCtx`, see below).
  - On Drop, remove from the map. Pass an `Arc<McpSharedState>` to `PtyHost`
    (new optional field) so Drop can deregister.

- `src/ipc/pty_manager.rs:124-132` — mirror the env injection in the
  daemon-side spawn so daemon-owned PTYs are equally identifiable. The
  daemon does not need access to `McpSharedState`; it just sets the env
  vars from the `client_tag` + freshly generated uuids and includes the
  generated ids in the `PtySpawned` response. Extend
  `ipc::protocol::ServerMsg::PtySpawned` with `pty_id` (already present),
  `nostromo_pty_id: String`, `nostromo_session_id: String`. Bump
  `PROTOCOL_VERSION` from 2 to 3 and `MIN_CLIENT_VERSION` to 3; document
  the breaking change in the PR body.
  - Alternative if protocol bump is undesirable: tunnel the ids back via
    a separate `ServerMsg::PtyIdentity { pty_id, nostromo_pty_id,
    nostromo_session_id }` sent immediately after `PtySpawned`, no version
    bump. **Prefer this alternative.**

- `src/pty/client.rs:67-103` — when `DaemonPtyClient::spawn_new` receives the
  `PtyIdentity` follow-up message, store the ids and pass them up so the
  view layer can register with `McpSharedState`.

- `src/pty/client.rs:283-309, 352-399` — `InProcessPtyFactory` and
  `DaemonPtyFactory`: add an `Arc<McpSharedState>` field and thread it
  through `spawn(...)` so callers don't need new arguments. Construct both
  factories with the shared state in `app::run`.

- `src/views/mod.rs` — `ViewCtx` already carries `pty_factory`. Add
  `pub mcp_state: Arc<McpSharedState>` so views can also poke the registry
  directly if needed (e.g. when a view spawns its PTY directly via
  `PtyHost::spawn` rather than the factory, like `views::perri.rs:384`).

- `src/views/perri.rs:384`, `src/views/fred.rs` (the equivalent PTY-spawn
  site), `src/views/agent_generic.rs` (its REPL spawn), `src/views/mother.rs`
  (its REPL spawn), `src/views/teri.rs` (its REPL spawn) — replace direct
  `PtyHost::spawn` calls with `ctx.pty_factory.spawn(...)` so env injection
  + registry registration happens uniformly. If a view legitimately needs
  in-process-only PTY behaviour, keep `PtyHost::spawn` but pass the env-var
  map through a new `PtyHost::spawn_with_env` constructor (add it).
  - **Caveat**: this is the largest mechanical churn in the phase. If any
    view's PTY spawning logic is too entangled to migrate cleanly, leave it
    on `PtyHost::spawn` and have `PtyHost::spawn` itself inject the standard
    env vars + register with a thread-local `MCP_STATE: OnceCell<Arc<...>>`
    initialised by `app::run`. Document the chosen approach in the PR body.

- `src/app.rs:184-329` — in `run()`:
  - Construct `McpSharedState` after `tx` is built and before factories are
    created.
  - Populate `views_meta` with the seven registered views (see the `views`
    vector at `src/app.rs:273-314`). Each `ViewMeta::pane_ids` is hardcoded
    in this phase:
    - `fred`: `["mailbox", "calendar", "repl"]`
    - `perri`: `["pr_queue", "diff", "repl"]`
    - `mother`: `["job_list", "log", "preview"]` (verify against
      `src/views/mother.rs` actual pane layout — if different, use the
      actual ids)
    - `claudia`, `cody`, `kennedy`, `teri`: `["repl"]` (or `["todos", "repl"]`
      for `teri` — verify from `src/views/teri.rs`)
  - Bind the MCP server: `let mcp = McpServer::bind(mcp::socket::default_socket_path(), mcp_state.clone()).await?;`
    (best-effort: if bind fails, log a warning and continue without MCP —
    Nostromo still works).
  - Pass `mcp_state` into both factories and into every `ViewCtx`.

- `~/.claude/mcp-servers/nostromo/config.example.json` — **new** (in this
  repo, not the user's home — committed at `docs/mcp/example-claude-mcp.json`).
  Documented example of how to register the bridge with Claude Code:
  ```json
  {
    "mcpServers": {
      "nostromo": {
        "type": "stdio",
        "command": "/usr/local/bin/nostromo-mcp-bridge",
        "env": {}
      }
    }
  }
  ```
  Plus a README note explaining `NOSTROMO_MCP_SOCKET` / `NOSTROMO_PTY_ID`
  are inherited from the PTY environment.

- `tests/mcp_get_self.rs` — **new** integration test.
  - Builds a stub `McpSharedState` with one fake `PtyIdentity` registered.
  - Spawns `McpServer` on a tempdir socket.
  - Opens a `UnixStream`, sends a `Hello { pty_id }`, then issues an MCP
    `initialize` followed by `tools/call { name: "nostromo.get_self" }`.
  - Asserts the response matches the registered identity.
  - Asserts a second connection with an unregistered `pty_id` gets the
    `unidentified_caller` error rather than a panic.

## Approach

1. **Resolve the dependency.** Add `rmcp` to `Cargo.toml`, run `cargo build`.
   If it fails (yanked, MSRV mismatch, broken transport feature), drop the
   dep and proceed with a hand-rolled JSON-RPC loop in `src/mcp/server.rs`
   using `tokio::net::UnixListener`, `tokio::io::AsyncBufReadExt` (newline-
   delimited JSON-RPC 2.0 — that's MCP's stdio framing today). Either way,
   the public surface (tool handlers, state) stays identical. Record the
   chosen path in the PR body.

2. **Scaffold the module.** Create `src/mcp/{mod.rs,socket.rs,server.rs,state.rs,tools/mod.rs,tools/get_self.rs}`. Get `cargo check` green with everything stubbed (`get_self` returns hardcoded JSON).

3. **Identification.** A bare Unix-socket connection has no way to know which
   PTY the calling `claude` process belongs to. Options:
   - (a) Have the bridge binary read `NOSTROMO_PTY_ID` from its own env and
     send a `Hello { pty_id: "<uuid>" }` as the first frame; server caches
     it on the connection. **Use this.**
   - (b) Use `SO_PEERCRED` to identify the calling pid, walk up the process
     tree to find the PTY leader, look up its env. Fragile across platforms;
     macOS support is awkward. Skip.

4. **PTY env injection.** Audit the two PTY spawn sites (`src/pty/host.rs:44-52`,
   `src/ipc/pty_manager.rs:124-132`). Each gets:
   ```
   NOSTROMO_VIEW_ID, NOSTROMO_PTY_ID, NOSTROMO_SESSION_ID, NOSTROMO_MCP_SOCKET
   ```
   Generate the uuids at spawn time, return them via the existing return
   path (`PtyHost` struct fields; daemon `PtyIdentity` follow-up message).

5. **Register identities.** Hook `PtyHost::spawn` (and the
   `DaemonPtyClient::spawn_new` success path) to insert into
   `McpSharedState::ptys`; hook `Drop` to remove.

6. **Implement `get_self`.** Look up the calling pty_id from the per-
   connection `Hello`, fetch the `PtyIdentity` and matching `ViewMeta`,
   return a `SelfInfo` JSON. Return `{ "error": "unidentified_caller" }`
   for unknown callers.

7. **Ship the bridge binary.** ~60 lines. Connect, send Hello, bidirectional
   `tokio::io::copy`. Install path documented in `docs/mcp/README.md`.

8. **Integration test.** As described in `tests/mcp_get_self.rs`.

9. **Manual smoke test.** Build, install the bridge to `/usr/local/bin/`,
   add the MCP server entry to `~/.claude/settings.json` (the operator —
   not the executor — does this), launch Nostromo, open Perri, in the REPL
   ask Claude to call `nostromo.get_self`, verify the response includes
   `view_id: "perri"`.

## Acceptance criteria

- `cargo build` and `cargo test` pass.
- `tests/mcp_get_self.rs` passes: a connected client calling `nostromo.get_self`
  with a registered `pty_id` receives the expected `SelfInfo` JSON; an
  unregistered client receives a structured error.
- PTYs spawned by Nostromo (both in-process and daemon-owned) have
  `NOSTROMO_VIEW_ID`, `NOSTROMO_PTY_ID`, `NOSTROMO_SESSION_ID`, and
  `NOSTROMO_MCP_SOCKET` in their environment. Verified by running `env | grep
  NOSTROMO_` inside any view's REPL.
- The MCP socket is created at `~/.nostromo/mcp.sock` (or
  `$NOSTROMO_MCP_SOCKET` if overridden) when Nostromo starts; removed on
  graceful shutdown.
- Failing to bind the MCP socket logs a warning but does not crash Nostromo.
- The bridge binary `target/release/nostromo-mcp-bridge` is buildable and runs
  end-to-end (manual: connect via `socat - UNIX-CONNECT:$HOME/.nostromo/mcp.sock`
  and send a Hello + initialize handshake).
- PR body documents the chosen library (`rmcp` or hand-rolled) and the
  rationale, plus the protocol-version handling decision (PtyIdentity
  follow-up vs. ServerMsg field bump).
- PR title includes "MCP phase 1" and the body mentions this phase plan.

## Out of scope

- Any MCP tool other than `nostromo.get_self`. `list_views`, `get_view_state`,
  pane mutations, cross-view dispatch, notifications, status-bar segments —
  all Phase 2+.
- Modifying any agent.md or `~/.claude/lib/perri-*.sh` files — Phase 4.
- Removing the dirty-file mechanism — Phase 4.
- Changing how `claude --agent <name>` is invoked (no `--session-id`
  threading beyond what already exists; the transcript-pane work owns that).
- Adding MCP-side authentication / authorization. Local Unix socket with
  default `0600` perms is sufficient for now.
- Persisting the PTY identity map across daemon restarts.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Cross-cutting: new module, dep choice with fallback, env injection at two PTY spawn sites, factory threading, IPC protocol nuance."
  redd:
    model: sonnet
    effort: high
    rationale: "First MCP integration test in the repo; must drive a real Unix socket against a live server. Coverage of the unidentified-caller path matters."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass once handlers settle; consolidate env-injection helper if duplicated."
  perri:
    model: sonnet
    effort: high
    rationale: "Reviewer sees every future MCP tool; missed protocol/security bugs here are systemic."
```
