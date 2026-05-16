# Daemon Mother Read-API for Non-TUI Clients

## Context

The Nostromo daemon (`nostromd`, `src/bin/nostromd.rs`) already polls
`mother list --format json` every 2 s and broadcasts the result to
subscribed IPC clients as `ServerMsg::MotherJobs`,
`ServerMsg::MotherStatusline`, and `ServerMsg::MotherAwaitDetected`.
Today the only consumer is the TUI. The next wave of platform work (the
Mac-native status-bar item; mobile surfaces) needs a *second* type of
client — a small, possibly short-lived process that wants the current
state immediately, not after waiting up to 2 s for the next poll.

The daemon is *almost* there. Three small gaps need closing before we
can confidently let a second client subscribe in production:

1. **Snapshot-on-demand.** A new client today subscribes and waits for
   the next poll. Status-bar items reopening from sleep need an
   immediate `MotherJobs` reply.
2. **Multi-client fan-out is implicit, not tested.** The `broadcast::
   Sender` in `src/ipc/server.rs` supports multiple receivers, but
   there is no test covering "two clients subscribe to MotherJobs and
   both receive every message." We're going to depend on this
   property — let's enforce it with a test.
3. **No client SDK.** Any non-TUI consumer has to re-implement the
   length-prefixed JSON framing, Hello/Subscribe handshake, and JSON
   shape parsing. We have client code (`src/ipc/client.rs`) but it's
   wired tightly to the TUI app event loop. A small extracted client
   helper lets the status-bar item (and any future Rust-side client,
   including the Swift app via a thin FFI shim) consume the same wire
   format without re-implementation drift.

This is part of the platform-evolution sequencing memo
(`docs/plans/platform-evolution-sequencing.md`), wedge W1. It unblocks
W3 (mac-status-bar-item) without requiring the larger W2
(mcp-network-transport) decision.

## Target
- **Repo:** nostromo
- **Branch:** `feat/daemon-mother-readapi`
- **Base:** `origin/main`

## Files to change

- `src/ipc/protocol.rs:84-142` — extend `ClientMsg` with
  `Snapshot { topics: Vec<Topic> }` request variant; extend
  `ServerMsg` if needed for a typed snapshot reply (probably reuse
  existing `MotherJobs` / `MotherStatusline` variants — daemon
  responds with one of each requested topic, drained from the current
  state).
- `src/ipc/server.rs:1-370` — handle `ClientMsg::Snapshot`: server-side
  cache of the most recent `MotherJobs`/`MotherStatusline` broadcast,
  populated by the broadcast write path; on `Snapshot` request, write
  the cached values back to the requesting client only (not the
  broadcast channel).
- `src/bin/nostromd.rs:78-204` — wire the cached-state hooks: when the
  daemon polls Mother, update the cache *before* broadcasting, so a
  `Snapshot` request answered between polls returns the same data the
  most recent subscriber saw.
- `src/ipc/client.rs:1-174` — refactor to expose a public
  `nostromo::ipc::ReadClient` that:
  - connects, performs the Hello handshake (protocol_version = 2),
  - issues `Subscribe` and/or `Snapshot`,
  - exposes `ServerMsg` as an `async fn next() -> Option<ServerMsg>`,
  - reconnects with exponential backoff on socket close.
  The existing TUI consumer path remains; the new `ReadClient` is an
  alternative entry point. Do *not* change the wire protocol the TUI
  uses.
- `tests/daemon_readapi.rs` (new) — integration test covering snapshot
  semantics and multi-client fan-out.

## Approach

1. **Protocol additions, no-break.** Add `ClientMsg::Snapshot { topics:
   Vec<Topic> }`. Do not bump `PROTOCOL_VERSION`; old clients simply
   never send the new message. Add a doc-comment paragraph to
   `protocol.rs` describing snapshot semantics.
2. **Server-side state cache.** In `src/ipc/server.rs`, add a small
   `LastBroadcast` struct holding `Option<Vec<MotherJob>>` and
   `Option<MotherStatus>`, behind an `Arc<RwLock<_>>`. Update from the
   same writer path that calls `broadcast_tx.send(...)` in
   `src/bin/nostromd.rs`. The IPC server reads from this cache when
   handling a `Snapshot` request, and writes the values directly to
   the connection's writer (not the broadcast channel).
3. **Client SDK.** Pull the connect/handshake/decode logic out of
   `src/ipc/client.rs` into `src/ipc/read_client.rs`, leaving the TUI
   wrapper unchanged. The new module's surface: `ReadClient::connect(
   socket_path) -> Result<Self>`, `subscribe(topics)`,
   `snapshot(topics)`, `next() -> Option<ServerMsg>`, `close()`. No
   knowledge of `AppEvent`.
4. **Tests.** New file `tests/daemon_readapi.rs`:
   - `snapshot_returns_immediately` — start a test daemon (via the
     existing daemon test harness pattern, see if `tests/`
     already has one; if not, spawn `nostromd` as a child process
     bound to a tempdir socket and a mock `mother` shim). After the
     daemon has polled once, a new client issuing `Snapshot([MotherJobs])`
     receives a `MotherJobs` reply within 100 ms (no waiting for the
     next 2 s poll).
   - `two_clients_receive_same_broadcast` — two `ReadClient`s
     subscribe to `MotherJobs`. Trigger one mother-poll. Both clients
     observe one `MotherJobs` message.
   - `slow_client_does_not_block_fast_client` — one client never
     reads its socket; a second client still observes new broadcasts
     within one poll interval. (The `broadcast` channel's
     `RecvError::Lagged` already covers this; this test makes it
     explicit so a future change can't regress it.)
5. **Mocking `mother list`.** The poller calls `mother::list_jobs()`
   which shells out to the `mother` CLI. For tests, gate on an env
   var (`NOSTROMO_TEST_MOTHER_FIXTURE=<path-to-json>`) read in
   `src/mother.rs::list_jobs`. If set, return parsed jobs from that
   file instead of shelling out. Tests write fixture files into a
   tempdir and set the env var on the spawned daemon. (If gating
   adds too much surface, alternative: invoke `list_jobs` directly
   in-process from the test, skipping the spawned-daemon path.)

## Acceptance criteria

Behavioural (none from Ada — this is technical infrastructure):

Technical / non-functional (Archie):

- `ClientMsg::Snapshot` over a freshly-connected client returns the
  most recent `MotherJobs` and/or `MotherStatusline` within **100 ms**,
  with no busy-wait for the 2-second polling tick.
- Two simultaneous IPC clients subscribed to `MotherJobs` each receive
  every broadcast; no fan-out is missed and message ordering is
  preserved per-client.
- A non-consuming client does not delay or drop broadcasts to a
  consuming client (Tokio `broadcast::Sender` already provides this;
  test asserts it).
- `nostromo::ipc::ReadClient` is `pub` from the library crate and is
  documented with a usage example in the module rustdoc.
- The existing TUI integration tests continue to pass without
  modification.
- `PROTOCOL_VERSION` is **not** bumped. Old TUIs running against the
  new daemon work identically.
- New code is gated behind no new feature flags or env vars *in
  production* (test-only env var for the fixture path is fine).
- PR body references this plan and the sequencing memo.

## Out of scope

- TCP / TLS / network transport — that is wedge W2
  (`docs/plans/mcp-network-transport.md`).
- Moving the MCP server into the daemon — that is the larger B1
  decision called out in the sequencing memo.
- Mutating tools (Mother enqueue, etc.) from a non-TUI client. This
  wedge is read-only.
- Auth / pairing / device tokens. Unix socket file permissions remain
  the only access control. Network exposure happens in W2.
- Adding budget posture or calendar to the daemon broadcast.
  Sequencing memo Q4 deliberately defers that decision.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Daemon + IPC code is fragile; multi-client fan-out semantics easy to break. Wide blast radius if TUI regresses."
  redd:
    model: sonnet
    effort: high
    rationale: "Tests are the safety net here. Multi-client and snapshot timing tests need careful construction; daemon-as-child-process harness may not exist yet."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor pass once Cody lands; mostly tidying the extracted ReadClient module boundary."
  perri:
    model: sonnet
    effort: high
    rationale: "Touches protocol surface and daemon binary — anything subtle here ships to every future client. Reviewer needs to be thorough."
```
