# Host the persistent, bidirectional stream-json session in `nostromod` (Rust), with the macOS app as a thin attach-client

## Context

The Nostromo macOS app (`macOS/Nostromo/`) backs every focus (Mother, Perri,
Fred, Teri, and dynamic "Claudia in <project>" focuses) with a `ChatSession`
that spawns a **brand-new one-shot `claude -p` process for every user
message**, parses its stdout stream-json into a published turn list, and
persists the resulting `session_id` so the next message can `--resume`. This
one-shot-per-message model is the source of three symptoms of one root cause
(no persistent two-way channel to a running `claude`): nothing outside can
drive a session; permission gates can only be bypassed, never answered; and
per-message spawn cost/fragility.

This plan re-architects the session host into a **single long-lived
`--input-format stream-json --output-format stream-json` process per focus**.
**Two findings, verified empirically this session against `claude` 2.1.158 at
`/Users/hammer/.local/bin/claude`, materially change the original design:**

1. **Mode-3 remote control coexists with structured stream-json.** A
   *persistent* `--input-format stream-json` session can ALSO carry
   `--remote-control <Name> -n <Name>`. We fed one message over a held-open
   stdin pipe: the process **stayed alive** (unlike `-p`, which exits after one
   turn), held **10+ ESTABLISHED TLS connections to Anthropic's range
   (`160.79.104.10:443`)** while idle (the remote-control relay staying
   connected), AND still emitted the stream-json we render. `-p` +
   `--remote-control` is a confirmed no-op (the `-p` process exits, so RC has
   nothing to attach to). **Consequence:** structured stream-json rendering and
   native Claude-iOS-app remote control are NOT mutually exclusive — they
   coexist on ONE persistent stream-json session. The earlier PRD framing
   ("`--remote-control` is for interactive PTY only, not the print/stream-json
   model — do not rely on it") is **superseded for the persistent (non-`-p`)
   case.** This **removes the entire "build our own cross-device TLS+token
   network listener" workstream** — cross-device remote control is Anthropic's
   relay, reached natively by the operator's Claude iOS app, not a transport we
   build.

2. **The persistent session is hosted in `nostromod` (the Rust daemon at
   `src/bin/nostromd.rs`), NOT in the Swift app.** Operator decision, locked.
   Rationale: the daemon must outlive the GUI so the remote-controllable
   session stays live across app restarts/crashes, and it is already the IPC
   hub that owns long-lived child processes (`PtyManager`) on behalf of
   clients. **Consequence:** the stream-json parsing, turn model, and session
   lifecycle move OUT of Swift `ChatSession`/`ChatModels` and INTO Rust
   (`nostromod`). The Swift `ChatSession` becomes a **thin attach-client** over
   the existing length-prefixed JSON-frame IPC (`NostromodClient.swift` ↔
   `src/ipc/`). Multi-window mirroring, persistence, and the structured render
   are preserved, but their authority moves to the daemon.

Authoritative PRD: `docs/prds/persistent-bidirectional-session-host.md` (read
its "Resolved decisions" and "Success criteria" — they remain the contract,
except the transport open question, now answered by finding 1).

### Operator decisions already settled (do not re-open)

1. **Remote control is cross-device in v1, via Anthropic's native relay.** The
   caller is the operator's Claude iOS app connecting to the relay that the
   persistent `--remote-control` session already maintains. We do **not** build
   a network listener; we just spawn the session with `--remote-control <Focus>
   -n <Focus>` and let the relay do the cross-device work.
2. **No Nostromo-side gate on who may answer permissions.** Any caller the
   relay/app authenticates may approve/deny. Anthropic's relay auth is the
   trust boundary; we add none.
3. **Session host lives in `nostromod`.** Swift is a thin client.
4. **Mirroring model = daemon broadcast (OUTPUT path).** The daemon owns the
   canonical turn model. It parses `claude` stdout **once**, maintains the
   authoritative turn list, and pushes turn deltas to **all** attached windows.
   Clients are **dumb renderers** — there is no client-side parsing and no
   client-side sync/merge. This **supersedes** any earlier framing in which a
   Swift shared `ChatSession` instance (the `AppStore.sessionRegistry`) stayed
   authoritative for the turn model; mirroring is now a daemon fan-out. The
   `sessionRegistry` survives only as the local attach/dedupe handle (criterion
   #5), not as the source of truth for turns.

### Input path / user-message model (operator-confirmed)

OUTPUT (agent turns, tool calls, results) is pure daemon broadcast per decision
4 above. INPUT (user messages) is the **deliberate exception**, with a subtlety
that must be designed for explicitly:

- **Local origin (Mac window):** a client originates a user message → sends it
  to the daemon over IPC (`SessionSend`) → the daemon writes it to `claude`'s
  stdin as a stream-json frame. The **originating** window MAY optimistically
  render the message immediately for latency (the existing queue-and-drain UX),
  but that optimistic echo is a client-local affordance, not the source of
  truth.
- **Phone origin (relay):** with `--remote-control` on, a user message can
  **also** originate from the phone, arriving via Anthropic's relay **directly
  into the `claude` process** — it never touches our stdin and the daemon never
  sees it on the input side. For Mac windows to display phone-typed messages,
  the daemon must observe them on the **OUTPUT** stream.
- **The unifier (to be verified — Phase 0).** The `--replay-user-messages` flag
  ("re-emit user messages from stdin back on stdout for acknowledgment") is the
  candidate that collapses both directions into ONE rendering path: if `claude`
  re-emits **all** user messages on stdout — relay/phone-origin **included**,
  not only stdin-origin — then the daemon RENDERS every user message (local and
  phone) off the output stream as just another broadcast event, while still
  INJECTING locally-originated messages to stdin. One source of truth, both
  directions; the client does nothing but optimistic echo.

  **Caution:** the `claude` 2.1.158 `--help` text scopes the flag to messages
  "from stdin," which suggests it may NOT cover relay/phone-origin messages.
  This is suggestive, not authoritative — the doc-string predates remote
  control, and phone-origin `user` events may surface on stdout independently of
  this flag. **Phase 0 must settle it empirically** (new spike below). The input
  design **branches on the answer:**
  - **If `--replay-user-messages` (or the stream itself) re-emits phone-origin
    user messages:** unified model — daemon renders ALL user messages off the
    output stream; `SessionSend` only injects to stdin and the daemon does NOT
    separately broadcast the locally-injected message (it will come back on the
    output stream like any other). Clients optimistically echo and reconcile
    against the authoritative replayed event.
  - **If it only re-emits stdin-origin messages:** the daemon separately
    broadcasts locally-injected user messages to attached windows (so non-
    originating Mac windows see them) AND still renders phone-origin user
    messages from whatever `user`-event the stream does surface. If the stream
    surfaces NOTHING for phone-origin user messages, phone-typed prompts will be
    invisible to the Mac GUI in v1 — flag this as a known limitation and file a
    follow-up.

### Spike findings (verified empirically this session, `claude` 2.1.158)

- **Persistence with a long-lived process — RESOLVED.** A persistent
  `--input-format stream-json` process started with `--session-id <uuid>`
  writes `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` as today. A NEW
  stream-json process started with `--resume <uuid>` recalls prior context and
  **preserves the same session_id** (no fork). `--resume` **composes** with the
  persistent stream-json model. Assign `--session-id <uuid>` up front for
  deterministic ids/recovery.
- **Multi-message per process — RESOLVED.** One persistent process serviced two
  sequential user messages (two `result` events from one PID). **Turn boundary
  = the `result` event**, not process termination.
- **Mode-3 remote control coexistence — RESOLVED** (see Context finding 1). The
  one open visual confirmation (the phone actually attaching/displaying) is an
  **acceptance check** the operator performs by opening the Claude app; the
  behavioral evidence (process longevity + persistent TLS to Anthropic + stream
  output) is strong.
- **Permission control protocol in mode 3 — RE-OPENED, must spike (Phase 0).**
  The original plan concluded the answer mechanism is an in-app MCP
  `--permission-prompt-tool` server. **With remote control connected, a
  permission prompt may instead be answerable NATIVELY on the phone via the
  Claude app's own permission UX over the relay** — which could remove the need
  to build the MCP permission server entirely. This is now the primary Phase-0
  unknown. The inline `--settings` bypass (already shipped on
  `fix/repl-headless-permissions`) remains the DEFAULT safety net for when no
  device is attached.

## Target

This plan splits into **two milestones with different execution surfaces** (see
"Milestones / dispatch boundary" below). The dispatchable half is Milestone A.

**Milestone A — the Rust core + spikes (BACKGROUND-DISPATCHABLE):**

- **Repo:** nostromo
- **Isolation:** git **worktree** (Cody runs headlessly in a worktree; no GUI).
- **Branch:** `feature/session-host-daemon-core`
- **Base:** `fix/repl-headless-permissions` (commit `24257e3`). Verified this
  session: 2 commits ahead of `main` (`c1be420`), 0 behind; carries BOTH the
  inline `--settings` bypass safety net (`24257e3 fix(repl): never dead-loop on
  permission prompts in headless sessions`) and the window-balloon fix
  (`280c914`). It has **not** merged to `main`. The bypass commit is load-
  bearing (criterion #8). Do **not** base on bare `main` or the bypass net is
  missing. **This branch is local-only — it MUST be pushed to the remote before
  the worktree job starts** so the worktree can fetch and branch from it. (If it
  merges to `main` before dispatch, base on `origin/main` instead — confirm with
  the operator.)

**Milestone B — the Swift thin-client cutover (INTERACTIVE, NOT for Mother):**

- **Repo:** nostromo
- **Branch:** `feature/session-host-swift-client` (based on Milestone A's branch
  once it lands).
- **Base:** Milestone A's merged branch (or its tip if not yet merged).
- Runs **locally with the operator**, not in a worktree — it requires the
  running GUI, the operator's eyes, and the phone (see Milestone B acceptance).

## Architecture overview (read before the file list)

```
  Claude iOS app  ──(Anthropic relay, native RC)──┐
                                                    ▼
  ┌─────────────────────────────────────────────────────────────────┐
  │ nostromod (Rust, src/bin/nostromd.rs)                             │
  │  SessionManager  ← NEW: mirrors PtyManager, but for stream-json   │
  │    per focus: one persistent `claude … stream-json --remote-      │
  │      control <Focus> -n <Focus> --session-id <uuid>` child        │
  │    • supervises lifecycle (start/stop/restart/crash-recovery)     │
  │    • parses stdout stream-json → turn model (Rust)                │
  │    • writes user messages to stdin as stream-json                 │
  │    • broadcasts turn deltas to attached IPC clients               │
  └─────────────────────────────────────────────────────────────────┘
        ▲  length-prefixed JSON frames over Unix socket (src/ipc/)
        │  (LOCAL ONLY — Swift GUI client; not the cross-device path)
  ┌─────────────────────────────────────────────────────────────────┐
  │ macOS app (Swift)                                                 │
  │  ChatSession  ← becomes a THIN ATTACH-CLIENT:                     │
  │    • SessionAttach <focus tag> → receives turn snapshot + deltas  │
  │    • SessionSend <focus tag> <text>                               │
  │    • SessionAnswerPermission (if Phase 0 needs it)                │
  │    • publishes `turns` to ReplView exactly as today               │
  │  AppStore.sessionRegistry / session(for:) unchanged (mirroring)   │
  └─────────────────────────────────────────────────────────────────┘
```

The **local** Unix-socket IPC stays for the Swift GUI client (it is correct
that it is local-only — the Swift app and daemon are on the same machine).
**Cross-device RC is Anthropic's relay, not our socket** — this is the key
change from the prior plan, which proposed building a TLS+token listener. That
listener workstream is **dropped**.

## Milestones / dispatch boundary

A background Cody running in a worktree CANNOT verify the GUI, the phone attach,
or the daemon against the live GUI. The plan therefore splits along the
**headless-verifiability** line:

### Milestone A — BACKGROUND-DISPATCHABLE (Cody in a worktree)

Everything that is buildable and testable **without Swift, the GUI, or a
phone**: the Phase 0 spikes and the entire Rust core in `nostromod`.

- **Scope:** Phase 0 spikes (mode-3 coexistence; permission surfacing;
  `--replay-user-messages` scope) + `src/ipc/session_manager.rs`,
  `src/ipc/stream_json.rs`, the v2→v3 additions in `src/ipc/protocol.rs`, the
  routing in `src/ipc/server.rs`, the wiring in `src/bin/nostromd.rs`, the
  exports in `src/ipc/mod.rs`, and the daemon-side session-id store.
- **Acceptance:** `cargo build` + `cargo test` pass, **plus a headless
  integration harness** (a `#[test]`/`#[tokio::test]` or `tests/` integration
  test) that: spawns a **real** `claude` stream-json child via `SessionManager`,
  connects a test IPC client over the Unix socket, sends a user message with the
  new `SessionSend`, and asserts that `SessionTurns`/`SessionTurnDelta` events
  come back with a turn that completes on the `result` event. No Swift, no GUI,
  no phone touched in this milestone. (See "Milestone A — self-contained
  section" below for the full standalone spec a Cody job executes end-to-end.)
- **Self-contained:** YES — the dedicated section below restates everything a
  fresh Cody needs, so it can be enqueued to Mother on its own.

### Milestone B — INTERACTIVE (NOT for Mother)

Everything that needs the running GUI, the operator's eyes, or the phone:

- The Swift thin-client cutover (`ChatSession`, `ChatModels`,
  `NostromodClient`, `AppStore`).
- The feature-flagged per-focus migration and one-shot fallback (Phase 4).
- Remote-control enablement and the **phone visual-attach acceptance check**.
- The mode-3 RC mirroring direction (phone-typed message appears in `ReplView`).

This milestone is executed locally with the operator; it is documented in this
plan (Phases 2–4) but is **out of scope for any background dispatch**.

## Files to change

### Rust — new session host in `nostromod` (the heart of the change)

- `src/ipc/session_manager.rs` (new) — `SessionManager`, modeled closely on
  `src/ipc/pty_manager.rs` (read it; it is the template for daemon-owned,
  client-surviving child processes with broadcast fan-out and attach/detach).
  Differences vs. `PtyManager`:
  - The child is `claude … --input-format stream-json --output-format
    stream-json` (not a PTY). Use plain piped stdin/stdout (`tokio::process` or
    `std::process` + a blocking reader task like `PtyManager`'s
    `_reader_task`), **not** `portable_pty`.
  - Instead of buffering raw bytes into a scrollback ring, **parse stdout
    line-by-line into the turn model** (see `src/ipc/stream_json.rs` below) and
    broadcast structured turn deltas.
  - Keyed by **focus `tag`** (stable; the Swift side already addresses sessions
    by `tag`, distinct from display name).
  - Owns lifecycle: `spawn_session`, `send_user_message`, `stop`, `restart`
    (with `--resume <uuid>`), crash-recovery auto-restart, `attach`/`detach`,
    teardown on focus removal, `kill_all_on_shutdown` (wire into the existing
    SIGTERM path in `nostromd.rs:90-96`).
- `src/ipc/stream_json.rs` (new) — the **Rust port of the turn model + parser**
  currently in Swift `ChatModels.swift`. Parses stream-json events
  (`assistant`/`user` message blocks, tool calls, `result`) into a `Turn` /
  `TurnBlock` model. **Turn boundary = `result` event** (Spike-confirmed), not
  EOF. This is the parsing-correctness core; Redd's fixtures target it.
- `src/ipc/protocol.rs` — extend the wire protocol (currently
  `ClientMsg`/`ServerMsg`, length-prefixed JSON frames, `PROTOCOL_VERSION = 2`
  at line 22). **Bump `PROTOCOL_VERSION` to 3** and `MIN_CLIENT_VERSION`
  accordingly (the Swift client sends `protocol_version: 2` in
  `NostromodClient.swift:134` — bump it there too). Add:
  - `ClientMsg::SessionSpawn { tag, agent_name, view_name, cwd, session_id?,
    remote_control: bool }` — start (or resume) a focus's persistent session.
  - `ClientMsg::SessionAttach { tag }` / `SessionDetach { tag }` — mirror
    `PtyAttach`/`PtyDetach`; on attach the daemon sends a turn snapshot then
    streams deltas.
  - `ClientMsg::SessionSend { tag, text }` — enqueue a user message.
  - `ClientMsg::SessionControl { tag, action: stop|restart|new_session }`.
  - `ClientMsg::SessionAnswerPermission { tag, request_id, decision }` — only
    if Phase 0 finds an over-stdin permission path is needed (may be unused if
    the phone answers natively).
  - `ClientMsg::SessionList`.
  - `ServerMsg::SessionTurns { tag, turns }` (snapshot on attach),
    `ServerMsg::SessionTurnDelta { tag, … }` (live updates),
    `ServerMsg::SessionState { tag, state }` (idle/mid-turn/awaiting-permission/
    crashed), `ServerMsg::SessionPermissionRequest { tag, request_id, tool,
    input }` (only if Phase 0 needs the in-app path), `ServerMsg::SessionExited
    { tag, exit_code }`, `ServerMsg::SessionListResp { sessions }`.
  - Reuse the existing `Topic` mechanism or add a `Sessions` topic if a
    subscribe model is cleaner than per-attach.
- `src/ipc/server.rs` — route the new `ClientMsg` variants in `handle_client`
  to a shared `Arc<Mutex<SessionManager>>`, exactly as PTY commands route to
  `PtyManager` today (the three-way `tokio::select!` and
  `client_sender_registry` pattern documented at `server.rs:7-18`).
- `src/bin/nostromd.rs` — construct `SessionManager` alongside `PtyManager`
  (`nostromd.rs:52`), hand it to `Server::bind`, and call its
  `kill_all_on_shutdown` in the SIGTERM block (`nostromd.rs:90-96`).
- `src/ipc/mod.rs` — export the new modules.
- **Session-id / persistence store (Rust).** Today the Swift side persists
  per-focus session ids in `~/.nostromo/gui-sessions.json`
  (`ChatSession.swift` `loadId`/`saveId`, ~lines 220-248). The daemon now owns
  session lifecycle, so it must own (or read/write) this map. Decide in Phase 1
  (see Open decisions Q-store): either the daemon reads/writes
  `gui-sessions.json` directly (compat with the one-shot fallback path), or a
  new daemon-side store keyed by `tag`. **The on-disk JSONL under
  `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` is unchanged** (Spike 2) — it
  is `claude`'s own file and remains the source of truth for scrollback.

### Swift — `ChatSession` becomes a thin attach-client

- `macOS/Nostromo/Data/ChatSession.swift` — **gut the subprocess machinery**
  (the `Process` spawn at ~55-168, `terminationHandler`, the
  `readabilityHandler`/`processChunk` stdout parsing) behind the new flag.
  Replace with:
  - On `init`/first need: send `SessionSpawn` + `SessionAttach { tag }` over
    `NostromodClient`.
  - `send(_:)` (line 55): send `SessionSend { tag, text }` instead of spawning.
    Keep the published optimistic user-turn append and the queue-and-drain UX.
  - Receive `SessionTurns`/`SessionTurnDelta`/`SessionState` from
    `NostromodClient.messages` and update the published `turns` so `ReplView`
    renders identically. The **parsing now happens in Rust**; Swift consumes a
    structured turn payload.
  - `newSession()` (line 44), stop/restart → `SessionControl`.
  - The inline `--settings` bypass JSON (line 90) **moves to the daemon's spawn
    args** but stays the default posture (criterion #8); it must remain scoped
    to Nostromo sessions, never the global `~/.claude/settings.json`.
  - `loadScrollback` (259-343) and `findClaude` (348-374): **move the
    equivalents to Rust** (the daemon spawns `claude` and reads the JSONL). The
    Swift versions can be deleted once the flag is the only path, but **keep
    them while the one-shot fallback exists** (Rollout).
- `macOS/Nostromo/Data/ChatModels.swift` — the turn model stays as the Swift
  *render* model, but it is now **populated from the daemon's payload**, not
  parsed from a raw stream locally. Add a Codable mapping from the daemon's
  `SessionTurns`/`SessionTurnDelta` JSON to the existing `ChatTurn`/`TurnBlock`
  types. If Phase 0 requires an in-app permission card, add a
  `.permissionRequest` `TurnBlock` case + `PermissionRequestData` here.
- `macOS/Nostromo/Data/NostromodClient.swift` — add the new outbound
  `ClientMsg` encoders (`SessionSpawn`/`SessionAttach`/`SessionSend`/
  `SessionControl`/`SessionAnswerPermission`/`SessionList`) and inbound
  `ServerMsg` decoders (`SessionTurns`/`SessionTurnDelta`/`SessionState`/
  `SessionPermissionRequest`/`SessionExited`/`SessionListResp`). Bump the
  `protocolVersion: 2` literal at line 134 to match the new `PROTOCOL_VERSION`.
- `macOS/Nostromo/Data/AppStore.swift` — `sessionRegistry` (line 42) and
  `session(for:agentName:workingDirectory:)` (48-53) stay **exactly** as-is
  (criterion #5). The shared `ChatSession` instance now mirrors daemon state
  rather than owning a process, so multi-window mirroring is preserved for free
  (both windows attach to the same daemon session via the same `tag`). Add
  teardown on focus removal → `SessionControl { stop }` so daemon sessions
  don't leak.
- `macOS/Nostromo/UI/Views/ReplView.swift` — unchanged for normal rendering
  (it still binds `session.$turns`). Only touched if Phase 0 requires an in-app
  permission card (reuse the `AskQuestionData` option-button pattern).

### Tests

- `src/ipc/stream_json.rs` (Rust `#[cfg(test)]`) — fixture-driven: feed a
  recorded stream-json transcript (multiple turns, tool calls, one `result` per
  turn) and assert the parsed turn model; assert completion is driven by
  `result`, not EOF. **Capture real fixtures during Phase 0.**
- `src/ipc/session_manager.rs` (Rust tests) — multi-message-on-one-process
  ordering; crash/restart recovery preserves turns and `--resume`s; attach
  delivers a snapshot then deltas; teardown kills the child. Model the test
  style on existing `src/ipc/codec.rs` tests.
- `src/ipc/protocol.rs` — serde round-trip for the new message variants
  (regression guard for the `MotherJobs` struct-vs-tuple serialization class of
  bug in commit `d3cd65d`).
- `macOS/NostromoTests/` — does a test target exist? Verified there is a
  `macOS/NostromoTests/` reference in the prior plan but **confirm against
  `Nostromo.xcodeproj`**. If none exists, standing one up is a prerequisite for
  Redd; flag it rather than silently skipping. Swift-side tests cover: decoding
  daemon `SessionTurns`/`SessionTurnDelta` payloads into the render model;
  attach-client reconnect behaviour (the daemon may restart — Swift must
  re-attach, cf. `DaemonReconnected` handling, `protocol.rs:224-229`).

## Approach

### Phase 0 — Spike the unknowns (do this first; branch the rest on it)

The persistence and multi-message spikes are RESOLVED (Context). Two things
still need empirical confirmation against `/Users/hammer/.local/bin/claude`
(v2.1.158; not on PATH in non-interactive shells; macOS has no `timeout` — wrap
with `perl -e 'alarm shift; exec @ARGV' <secs> <cmd...>`):

1. **Confirm mode-3 coexistence holds in a clean run.** Spawn:
   ```
   claude --remote-control SpikeFocus -n SpikeFocus \
     --input-format stream-json --output-format stream-json --verbose \
     --settings '{"permissions":{"defaultMode":"bypassPermissions"}}' \
     --session-id <uuid>
   ```
   Hold stdin open, feed one
   `{"type":"user","message":{"role":"user","content":"say hi"}}\n` frame.
   Confirm: (a) the process stays alive after the `result` event, (b) it holds
   ESTABLISHED TLS to Anthropic's range while idle (`lsof -nP -p <pid> | grep
   443` or `nettop`), (c) stream-json renders. Record the exact event sequence
   as a **parser fixture** for `stream_json.rs`.
2. **Determine how a permission request surfaces in mode 3.** With RC connected
   and `--permission-mode default` (NOT bypass), drive a real tool call (ask it
   to Write a file). Observe:
   - Does a permission request appear as a **stream event** on stdout (and if
     so, capture the exact shape)?
   - Or is it handled **entirely by the relay/phone** (the Claude app shows the
     prompt; nothing actionable appears on our stdout)?
   - Is the in-app MCP `--permission-prompt-tool` server (the prior plan's
     mechanism) still needed at all, or does the phone answering natively make
     it redundant?

   Also re-confirm `--permission-prompt-tool` is a recognized flag (run it with
   no value; expect `option '--permission-prompt-tool <tool>' argument missing`,
   NOT `unknown option`) so the MCP path remains available as a fallback.

3. **Determine the scope of `--replay-user-messages` — does it cover
   relay/phone-origin user messages, or only stdin-origin?** This gates the
   entire input-path design (see Context → "Input path / user-message model").
   The `claude` 2.1.158 `--help` text reads "re-emit user messages **from
   stdin** back on stdout … (only works with `--input-format=stream-json` and
   `--output-format=stream-json`)" — suggestive of stdin-only, but NOT
   authoritative. Verify empirically against `/Users/hammer/.local/bin/claude`:
   - Spawn the persistent mode-3 session from step 1 **with
     `--replay-user-messages` added**.
   - Feed one user message over **stdin** and confirm it is re-emitted on stdout
     (capture the exact event shape — this is the stdin-origin baseline and a
     parser fixture).
   - Then send a user message **from the phone** (operator action, via the
     Claude iOS app attached to the same RC session) and watch the daemon's
     stdout stream. Record whether the phone-origin message appears as a `user`
     event on stdout (a) only with `--replay-user-messages`, (b) on the raw
     stream regardless of the flag, or (c) **not at all**.
   - Also note whether stdin-origin and phone-origin user events are
     distinguishable in the payload (e.g. a source/origin field) — the daemon
     needs to know which to avoid double-rendering a locally-echoed message.

   **Decision branch — input path** (record the chosen branch + captured
   payloads in the PR description):
   - **(a) or (b) — phone-origin user messages DO surface on stdout:** adopt the
     **unified** model. The daemon renders all user messages off the output
     stream; `SessionSend` injects to stdin only and does NOT separately
     broadcast the local message. Clients optimistically echo and reconcile
     against the replayed event (dedupe by content/id within a short window).
   - **(c) — phone-origin user messages do NOT surface on stdout:** the daemon
     separately broadcasts locally-injected messages to attached windows so non-
     originating Mac windows see them, and phone-typed prompts are a **known v1
     limitation** (invisible to the Mac GUI). File a follow-up; surface to the
     operator. This does not block Milestone A's headless acceptance (which
     tests only the local stdin→stdout round-trip).

**Decision branch — permissions:**
- **If the phone answers natively (likely, given RC):** v1 ships with **bypass
  as the no-device default** and **native phone approval when a device is
  attached**. **Do NOT build the in-app MCP permission server** (it is removed
  from scope). Criterion #6 is satisfied by the relay/phone path. Surface this
  to the operator with the captured evidence.
- **If a permission request DOES surface as a stdout stream event we can
  answer over stdin:** the daemon surfaces it via `SessionPermissionRequest`,
  the Swift card answers via `SessionAnswerPermission`, and the daemon writes
  the response to the child's stdin. Build that path.
- **If neither works in this binary:** fall back to bypass-only for v1
  (criterion #6 explicitly permits this), file a follow-up, and surface it.

Record the chosen branch in the PR description with the captured payloads.

### Phase 1 — `SessionManager` in `nostromod` (persistent lifecycle + parsing)

3. **Port the turn model + parser to Rust** in `src/ipc/stream_json.rs`,
   driven by the Phase-0 fixtures. Turn completes on `result`.
4. **Build `SessionManager`** (`src/ipc/session_manager.rs`) on the
   `PtyManager` template:
   - `spawn_session(tag, agent_name, view_name, cwd, session_id?, remote_control)`
     spawns ONE child:
     ```
     claude --settings '{"permissions":{"defaultMode":"bypassPermissions"}}' \
       --input-format stream-json --output-format stream-json --verbose \
       --agent <agent_name> -n <view_name> \
       [--remote-control <view_name>] \
       --session-id <uuid> | --resume <uuid>
     ```
     `--remote-control <view_name>` is included when `remote_control: true`
     (default on for focuses the operator wants reachable from the phone; see
     Rollout). Keep one piped stdin handle open for the process lifetime; run a
     blocking stdout reader task that feeds the parser and broadcasts deltas
     (mirror `PtyManager`'s `_reader_task` + `output_tx` fan-out).
   - **Assign `--session-id <uuid>` up front** (Spike 2): generate per focus,
     persist keyed by `tag` (see Open decisions Q-store). On restart, pass
     `--resume <uuid>`.
5. **Input path:** `send_user_message(tag, text)` writes
   `{"type":"user","message":{"role":"user","content":"<text>"}}\n` to the
   child's stdin. Preserve queue-and-drain (one in-flight turn per focus; PRD
   defers multiplexing). Optionally `--replay-user-messages` for an echo ack.
6. **Lifecycle:** `stop` (close stdin, kill, mark dead), `restart` (stop then
   spawn with `--resume <uuid>`), **crash-recovery** (on unexpected child exit
   while attached or with queued messages: mark the in-flight turn errored,
   broadcast `SessionState::crashed`, **auto-restart with `--resume <uuid>>`**;
   cap restarts in a window to avoid crash loops), `new_session` (drop the
   persisted uuid, fresh one next spawn), and teardown on focus removal. Wire
   `kill_all_on_shutdown` into the SIGTERM path.
7. **Attach/broadcast:** `SessionAttach` sends a `SessionTurns` snapshot then
   streams `SessionTurnDelta`/`SessionState`. Multiple Swift windows attaching
   to the same `tag` all receive the same stream (criterion #5 — mirroring is
   now a daemon broadcast, even cleaner than the prior shared-instance model).

### Phase 2 — Swift thin attach-client

8. Add the new IPC encoders/decoders to `NostromodClient.swift`; bump the
   protocol version.
9. Rewrite `ChatSession` to attach/send/control over IPC instead of spawning a
   process. Map daemon turn payloads into the existing `ChatTurn`/`TurnBlock`
   render model (`ChatModels.swift`) so `ReplView` is unchanged.
10. Handle daemon restart: on `DaemonReconnected` (the auto-reconnect
    pseudo-event, `protocol.rs:224-229` / commit `543f13d`), re-issue
    `SessionAttach` for every live focus so the GUI re-syncs. The daemon's
    sessions survive the GUI client dropping (that is the whole point).
11. **Permissions (only if Phase 0 chose the in-app path):** render the
    `.permissionRequest` card in `ReplView`; approve/deny →
    `SessionAnswerPermission`. If Phase 0 chose the native-phone path, **skip
    this entirely** — the phone is the surface.

### Phase 3 — Remote control (native, via Anthropic's relay)

12. **No custom transport.** Remote control is delivered by spawning the
    persistent session with `--remote-control <view_name> -n <view_name>`
    (Phase 1 step 4). The Claude iOS app connects to Anthropic's relay and
    drives the focus by its name. Our only work here is:
    - Choosing which focuses spawn with `--remote-control` on (Rollout / a
      per-focus flag).
    - Ensuring `-n <view_name>` is the focus's display name so the phone shows
      a recognizable label (the focus `tag` remains the LOCAL IPC address;
      the RC name is the human-facing relay handle).
    - **Acceptance:** the operator opens the Claude iOS app and confirms the
      named focus is drivable from the phone (the visual-attach check from
      Phase 0). Messages sent from the phone should stream into the same
      daemon session and therefore appear in the macOS `ReplView` (mirroring),
      because both the phone (via relay) and the GUI (via IPC) observe the same
      child process. **Verify this mirroring direction explicitly** — it is the
      payoff of hosting in the daemon.
13. **Trust boundary = Anthropic's relay auth.** We add none (operator decision
    2). Document that turning `--remote-control` on for a focus exposes it to
    whoever the operator's Claude account/relay authenticates — acceptable per
    the PRD.

### Phase 4 — Incremental rollout (no hard cutover; daily use must not break)

14. **Feature-flag the daemon-hosted path per focus.** The app runs full-screen
    across displays and relaunching disrupts the operator; do NOT hard-cut all
    focuses. Gate the daemon-host path behind a flag (a `UserDefaults` key, or a
    per-focus toggle) with **the existing Swift one-shot `-p` path as the
    fallback** — keep it intact and working. Cut over **one focus type first**
    (recommend a single built-in like Fred or Teri) to validate in daily use,
    then widen.
15. **Safe rollback:** flipping the flag off reverts a focus to the Swift
    one-shot spawn. Persistence is compatible across both (same per-focus
    session uuid + the same `~/.claude/projects/.../<uuid>.jsonl` + `--resume`),
    so toggling does not lose conversations — provided the daemon and Swift
    agree on where the per-focus uuid is stored (Open decisions Q-store).
16. **`--remote-control` on/off is its own per-focus toggle**, off by default
    until the operator opts a focus in.

---

## Milestone A — self-contained section (the background-dispatchable job)

> **This section is self-contained.** A fresh Cody with no conversation history
> can execute it end-to-end without reading the rest of the plan. The Phases
> above give richer rationale, but everything required is restated here.

### A.0 — What you are building

You are adding a **persistent stream-json session host to the Rust daemon
`nostromod`** (binary at `src/bin/nostromd.rs`). Today the macOS Swift app
spawns a brand-new one-shot `claude -p` process per user message. This work
moves session hosting into the daemon: ONE long-lived `claude --input-format
stream-json --output-format stream-json` child **per focus**, supervised by a
new `SessionManager` (modeled on the existing `PtyManager`), parsing the child's
stdout into a turn model and broadcasting turn deltas to attached IPC clients.

**You touch ONLY Rust.** Do NOT modify any Swift (`macOS/**`), do NOT build the
GUI, do NOT attempt phone/remote-control verification. Those are a separate
milestone the operator runs by hand.

### A.1 — Repo, branch, base, isolation

- **Repo:** nostromo. **Isolation:** git worktree.
- **Base ref:** `fix/repl-headless-permissions` (commit `24257e3`) — NOT bare
  `main`. This base carries the inline `--settings` `bypassPermissions` safety
  net that the daemon spawn must preserve. The base is pushed to the remote;
  fetch it and create your branch from it. If it has merged to `origin/main` by
  the time you start, base on `origin/main` instead.
- **Branch:** `feature/session-host-daemon-core`.
- **Commit/PR:** reference this plan (`docs/plans/persistent-bidirectional-
  session-host.md`) and the PRD (`docs/prds/persistent-bidirectional-session-
  host.md`) in the PR body. State the Phase-0 spike outcomes (mode-3
  coexistence, permission surfacing, `--replay-user-messages` scope) with the
  captured payloads.

### A.2 — Environment facts (no conversation history needed)

- The `claude` binary is at `/Users/hammer/.local/bin/claude`, version 2.1.158.
  It is **not on PATH** in non-interactive shells — use the absolute path, and
  in the daemon resolve it the way the current code resolves `claude` (port the
  Swift `findClaude` logic, ~`ChatSession.swift:348-374`, to Rust; check the
  same candidate locations including `~/.local/bin/claude`).
- macOS has **no `timeout`**; in spike scripts wrap with
  `perl -e 'alarm shift; exec @ARGV' <secs> <cmd...>`.
- The IPC is length-prefixed JSON frames over a Unix socket
  (`nostromo::ipc::default_socket_path()`); current `PROTOCOL_VERSION = 2`
  (`src/ipc/protocol.rs:22`).
- `Server::bind(socket_path, pty_mgr)` is the current signature
  (`src/ipc/server.rs:43`) — you will extend it (or its construction) to also
  carry the `SessionManager`.
- SIGTERM/SIGINT shutdown calls `pty_mgr.kill_all_on_shutdown()` in
  `src/bin/nostromd.rs` (the `tokio::select!` block ~lines 78-96); add the
  session manager's teardown alongside it.
- `PtyManager` (`src/ipc/pty_manager.rs`) is your **template** for daemon-owned,
  client-surviving children with broadcast fan-out and attach/detach (its
  `_reader_task` + `output_tx` pattern). Differences: your child uses **plain
  piped stdin/stdout** (`tokio::process` or a blocking reader task), NOT
  `portable_pty`; and instead of a raw scrollback ring you parse stdout into a
  structured turn model.

### A.3 — Spikes first (Phase 0), then build

Do the spikes in `A.3` **before** writing the parser, and capture real
transcripts as test fixtures. All spikes run against
`/Users/hammer/.local/bin/claude`.

1. **Mode-3 + stream-json coexistence.** Spawn:
   ```
   claude --remote-control SpikeFocus -n SpikeFocus \
     --input-format stream-json --output-format stream-json --verbose \
     --settings '{"permissions":{"defaultMode":"bypassPermissions"}}' \
     --session-id <uuid>
   ```
   Hold stdin open; feed one
   `{"type":"user","message":{"role":"user","content":"say hi"}}\n` frame.
   Confirm the process **stays alive after the `result` event** (unlike `-p`),
   and that stream-json renders. **Note:** the `--help` text claims
   `--input-format stream-json` "only works with `--print`"; the operator
   observed coexistence empirically this session, but **re-confirm it in a clean
   run** and record the exact event sequence as a parser fixture. If coexistence
   does NOT hold headlessly, capture the failure and proceed with the
   stream-json parsing/lifecycle work anyway (it does not depend on RC) — RC is a
   Milestone B concern.
2. **`--replay-user-messages` scope (gates the input path).** Add
   `--replay-user-messages` to the spawn. Feed a user message over **stdin** and
   confirm it is re-emitted on stdout; capture the exact event shape. (The
   phone-origin half of this spike is a Milestone B / operator check — you can
   only verify the **stdin-origin** re-emit headlessly. Record the stdin-origin
   shape and note that phone-origin coverage is deferred to the operator.)
3. **Permission surfacing (gates whether any permission plumbing is built).**
   With RC notionally connected and `--permission-mode default` (NOT bypass),
   drive a real tool call (ask it to Write a file) and observe whether a
   permission request appears as a **stdout stream event** (capture its shape)
   or not. Also re-confirm `--permission-prompt-tool` is a recognized flag (run
   with no value; expect `argument missing`, not `unknown option`). For
   Milestone A, the daemon ships with **`bypassPermissions` as the default spawn
   posture** (the load-bearing safety net) regardless of outcome; the
   `SessionPermissionRequest`/`SessionAnswerPermission` protocol variants are
   defined but only wired through if a stdout-answerable path is found. The
   native-phone path is verified in Milestone B.

Record all three outcomes (with payloads) for the PR body.

### A.4 — Build the Rust core

Implement, driven by the fixtures from A.3:

1. **`src/ipc/stream_json.rs` (new)** — the turn-model parser. Parse stream-json
   events (`assistant`/`user` message blocks, tool calls/results, `result`) into
   a `Turn`/`TurnBlock` model. **Turn boundary = the `result` event, NOT EOF.**
   This is the parsing-correctness core. Provide `#[cfg(test)]` fixture-driven
   tests (model the style on `src/ipc/codec.rs` tests): feed a recorded
   multi-turn transcript and assert the parsed turn model and that completion is
   driven by `result`.
2. **`src/ipc/session_manager.rs` (new)** — `SessionManager` on the `PtyManager`
   template, keyed by focus **`tag`**. Responsibilities:
   - `spawn_session(tag, agent_name, view_name, cwd, session_id?,
     remote_control)` spawns ONE child:
     ```
     claude --settings '{"permissions":{"defaultMode":"bypassPermissions"}}' \
       --input-format stream-json --output-format stream-json --verbose \
       --agent <agent_name> -n <view_name> \
       [--remote-control <view_name>] \
       (--session-id <uuid> | --resume <uuid>)
     ```
     Keep one piped stdin handle open for the process lifetime; run a reader task
     that feeds the parser and broadcasts deltas (mirror `PtyManager`'s
     `_reader_task` + `output_tx` fan-out). The `--remote-control` flag is
     included only when `remote_control: true`. Resolve the `claude` path in
     Rust (port `findClaude`).
   - `send_user_message(tag, text)` writes
     `{"type":"user","message":{"role":"user","content":"<text>"}}\n` to stdin.
     Preserve **queue-and-drain** (one in-flight turn per focus). Per the A.3
     spike-2 input-path branch: in the unified case do NOT separately broadcast
     the local message; in the stdin-only case DO broadcast it to attached
     windows.
   - `stop` (close stdin, kill, mark dead), `restart` (stop then spawn with
     `--resume <uuid>`), **crash-recovery** (on unexpected child exit: mark the
     in-flight turn errored, broadcast `SessionState::crashed`, auto-restart with
     `--resume <uuid>`, with a **crash-loop cap** in a time window),
     `new_session` (drop the persisted uuid, fresh one next spawn),
     `attach`/`detach`, teardown on focus removal, and
     `kill_all_on_shutdown` (wired into the SIGTERM path).
   - **Session-id store (daemon-owned):** assign `--session-id <uuid>` up front,
     persist keyed by `tag`. Recommended: a daemon-side
     `~/.nostromo/daemon-sessions.json`. (The Swift one-shot fallback reads a
     compatible store — call it out in the PR so Milestone B can reconcile; do
     NOT modify Swift here.) The on-disk
     `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` is `claude`'s own file and
     is unchanged.
3. **`src/ipc/protocol.rs`** — bump `PROTOCOL_VERSION` 2→3 (and
   `MIN_CLIENT_VERSION` accordingly). Add the `ClientMsg` variants:
   `SessionSpawn { tag, agent_name, view_name, cwd, session_id?, remote_control }`,
   `SessionAttach { tag }`, `SessionDetach { tag }`, `SessionSend { tag, text }`,
   `SessionControl { tag, action }` (stop|restart|new_session),
   `SessionAnswerPermission { tag, request_id, decision }`, `SessionList`. And
   the `ServerMsg` variants: `SessionTurns { tag, turns }` (snapshot on attach),
   `SessionTurnDelta { tag, … }`, `SessionState { tag, state }`
   (idle|mid-turn|awaiting-permission|crashed), `SessionPermissionRequest { tag,
   request_id, tool, input }`, `SessionExited { tag, exit_code }`,
   `SessionListResp { sessions }`. **Add serde round-trip tests** for every new
   variant — this guards against the `MotherJobs` struct-vs-tuple serialization
   bug class (commit `d3cd65d`); prefer **struct variants**, not tuple variants.
4. **`src/ipc/server.rs`** — route the new `ClientMsg` variants in
   `handle_client` to a shared `Arc<Mutex<SessionManager>>`, exactly as PTY
   commands route to `PtyManager` (the three-way `tokio::select!` +
   `client_sender_registry` pattern).
5. **`src/bin/nostromd.rs`** — construct `SessionManager` alongside `PtyManager`,
   hand it to the server, and call its teardown in the SIGTERM block next to
   `kill_all_on_shutdown`.
6. **`src/ipc/mod.rs`** — export the new modules.

### A.5 — Milestone A acceptance criteria (the contract)

Cody verifies ALL of these before opening the PR:

- `cargo build` succeeds with no new warnings in changed files.
- `cargo test` passes, including: the `stream_json` fixture tests (turn boundary
  = `result`, not EOF); the `session_manager` tests (multi-message-on-one-
  process ordering; crash/restart recovery preserves turns and `--resume`s;
  attach delivers a snapshot then deltas; teardown kills the child); and the
  `protocol.rs` serde round-trip tests for every new variant.
- **Headless integration harness passes** (a `#[tokio::test]` or `tests/`
  integration test, gated/ignored if CI lacks the `claude` binary, runnable
  locally): it spawns a **real** `claude` stream-json child via
  `SessionManager`, connects a test IPC client over the Unix socket, sends a
  user message via `SessionSend`, and asserts `SessionTurns`/`SessionTurnDelta`
  events come back with a turn that completes on the `result` event. This is the
  end-to-end proof that the new IPC path drives a real session headlessly.
- The daemon's default spawn posture includes the inline `--settings`
  `bypassPermissions` net (scoped to Nostromo sessions; never the global
  `~/.claude/settings.json`).
- The PR body states the three Phase-0 spike outcomes with captured payloads,
  references the plan and PRD, and notes which input-path branch (unified vs.
  stdin-only-broadcast) the parser/SessionManager implements.

### A.6 — Milestone A out of scope (do NOT do these)

- Any Swift / `macOS/**` change. (Milestone B.)
- The GUI, `ReplView`, `ChatSession`, `NostromodClient`, `AppStore`.
- Phone / remote-control visual verification (the daemon may *spawn* with
  `--remote-control` behind the flag, but verifying the phone attaches is
  Milestone B / operator).
- The feature-flag rollout and one-shot fallback wiring on the Swift side.
- Building a custom cross-device transport (dropped entirely; RC is Anthropic's
  relay).
- Touching the operator's global `~/.claude/settings.json`.

---

## Acceptance criteria

Technical / non-functional (complement Ada's behavioural ACs in the PRD). These
cover the **full plan (both milestones)**. For a background dispatch, only the
Milestone A subset (section "A.5") applies — the Swift/GUI/phone criteria below
belong to Milestone B and are verified by the operator. Cody verifies before
opening a PR:

- **Rust builds & tests:** `cargo build` and `cargo test` pass; new
  `stream_json` and `session_manager` tests pass; `protocol.rs` serde
  round-trip tests pass.
- **Swift builds:** `cd macOS && xcodebuild -project Nostromo.xcodeproj -scheme
  Nostromo -configuration Debug build` succeeds with no new warnings in changed
  files. Swift tests build & pass if a target exists (else the gap is flagged).
- **One process per focus (crit #1):** with the flag on, sending N messages to
  a focus results in exactly one `claude` child in the daemon servicing all N
  (Rust unit test feeding multiple frames + one observed child; manual via
  Activity Monitor).
- **Turn boundaries from the stream (crit #2):** the Rust parser test feeds a
  recorded transcript and asserts the turn model, with completion driven by
  `result`, not EOF.
- **Structured render unchanged (crit #3):** `ReplView` still binds
  `session.$turns`; no terminal/PTY surface. A normal conversation renders
  identically to today. The render model is now fed from the daemon payload.
- **Persistence across restart (crit #4):** quit and relaunch the GUI — the
  focus shows prior turns (daemon session was still alive, or resumed from the
  uuid) and a follow-up continues the same conversation. Also: kill `nostromod`
  and confirm the GUI re-attaches and the session resumes via `--resume`.
- **Multi-window mirroring (crit #5):** two `ReplView`s on the same `tag`
  reflect the same live turns (now a daemon broadcast). `AppStore.session(for:)`
  semantics unchanged.
- **Cross-device remote control (crit #7, native):** a focus spawned with
  `--remote-control <name>` is drivable from the operator's Claude iOS app;
  messages from the phone stream into the same daemon session and appear in the
  macOS `ReplView`. (Operator confirms the phone attach.) NO custom network
  listener is shipped.
- **Answerable permission OR documented fallback (crit #6):** per the Phase-0
  branch — native phone approval, or an in-app card, or documented bypass-only
  with a follow-up. The PR states which and links the captured evidence.
- **Bypass safety net survives (crit #8):** the inline `--settings`
  `bypassPermissions` remains the default spawn posture (now in the daemon) and
  is scoped to Nostromo sessions only — never the global
  `~/.claude/settings.json`.
- **Lifecycle controllable (crit #9):** start/stop/restart/resume work; a
  killed child auto-restarts with `--resume` without dropping the rendered
  conversation or corrupting the per-focus uuid store; crash-loop guard exists.
- **Rollout safety:** the daemon-host path is behind a per-focus flag; flipping
  it off restores the Swift one-shot path with no conversation loss.
- **PR body** references the PRD and this plan, and states the Phase-0
  permission outcome and the mode-3 RC confirmation.

## Out of scope

- **Building a custom cross-device transport** (TCP/WebSocket/TLS listener,
  token pairing, `Auth.swift`). Removed by the mode-3 finding — RC is
  Anthropic's relay. (This was a major workstream in the prior revision; it is
  gone.)
- The Rust TUI's `--remote-control` PTY approach for *interactive* sessions
  (`docs/plans/cc-repl-remote-control-by-default.md`) — distinct from the
  persistent stream-json RC here; do not conflate.
- Mother's background workers / job orchestration.
- A full permission policy-editor UI beyond approve/deny + the default posture.
- Image forwarding to the subprocess (known gap; `--image` invalid).
- Multiplexing more than one concurrent in-flight turn per focus beyond
  queue-and-drain.
- Touching the operator's global `~/.claude/settings.json`.
- Re-deriving who may answer permissions (settled: any relay-authenticated
  caller).

## Open decisions to surface before implementation

1. **Base ref + branch split.** The plan ships as two branches:
   `feature/session-host-daemon-core` (Milestone A, dispatchable) and
   `feature/session-host-swift-client` (Milestone B, based on A). Both base on
   `fix/repl-headless-permissions` (`24257e3`) — NOT bare `main` (it carries the
   load-bearing bypass net, criterion #8). That base is **local-only and must be
   pushed to the remote before Milestone A is dispatched to a worktree.** If it
   merges to `main` first, base on `origin/main`.
2. **Q-store — where does the per-focus session uuid live now that the daemon
   owns lifecycle?** Recommend the daemon owns a store keyed by `tag`
   (`~/.nostromo/daemon-sessions.json` or extend `gui-sessions.json`), and the
   Swift one-shot fallback reads the same file so a flag flip doesn't fork the
   conversation. **Confirm the file/format with the operator** — it is the
   rollback-safety hinge.
3. **`--remote-control` always-on vs. per-focus opt-in.** Recommend per-focus
   opt-in, off by default, given it exposes the focus to the relay. Confirm
   whether the operator wants it on by default for built-ins.
4. **Permission surfacing in mode 3** (Phase 0 step 2 outcome) — this picks
   whether we build the in-app MCP server / stdin answer path or rely on the
   phone. **Gating; resolve in Phase 0 before Phase 2 step 11.**
5. **Swift test target:** does `macOS/Nostromo.xcodeproj` have a unit-test
   target? If not, standing one up is a prerequisite for Redd — confirm it's
   acceptable to add in this PR.
6. **First flagged focus:** which focus rolls out first (recommend a built-in
   like Fred or Teri before dynamic Claudia focuses)?
7. **Protocol bump coordination:** bumping `PROTOCOL_VERSION` to 3 means an old
   GUI talking to a new daemon (or vice versa) is rejected by the handshake.
   Since the operator runs both from this repo and `make` restarts `nostromd`
   on install (commit `6b4b54e`), this is acceptable — but confirm the install
   flow restarts both so a version skew window doesn't strand the GUI.

# Routing config is scoped to MILESTONE A (the background-dispatchable Rust
# core + spikes). Milestone B is run interactively by the operator, not Mother.
# Suggested --max-cost for Milestone A: $25. Rationale: new Rust daemon
# subsystem (~5-6 files) + parser + crash-recovery + a headless integration
# harness that spawns a real `claude` child, plus three empirical spikes. Larger
# than a typical fix but bounded to Rust with a hard acceptance gate; $25 leaves
# headroom for spike iteration and test-debugging without runaway.
```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "New Rust daemon subsystem: persistent child supervision, stream-json turn parser, crash recovery, IPC protocol v3 bump, headless harness. Correctness-critical in the daily-use stack."
  redd:
    model: sonnet
    effort: high
    rationale: "Stream-json parser tests (turn boundary = result), message ordering, crash/restart recovery, serde round-trips for each new protocol variant; coverage gates a cross-process change."
  marty:
    model: sonnet
    effort: medium
    rationale: "Consolidate SessionManager against the PtyManager template and shared lifecycle/state-machine patterns after the feature lands; standard refactor pass."
  perri:
    model: opus
    effort: high
    rationale: "Reviews a process-lifecycle + IPC-protocol-bump change in the Rust daemon; a missed recovery, version-skew, or persistence-fork bug is high-blast-radius."
```
