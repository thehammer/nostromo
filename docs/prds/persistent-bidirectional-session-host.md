# PRD: Persistent bidirectional session host + remote control

**Author:** Ada
**Captured:** 2026-05-30
**Status:** ready-for-archie
**Surface:** macOS app only (`macOS/Nostromo/`). The Rust TUI under `src/`
and its separate `--remote-control` plan are explicitly out of scope.

## Problem

Every focus in the Nostromo macOS app (Mother, Perri, Fred, Teri, and
dynamic ones like "Claudia in <project>") is backed by a `ChatSession`
that spawns a **brand-new one-shot `claude -p` process for every single
user message**, parses its stream-json output to build the turn list,
and persists the resulting `session_id` so the next message can
`--resume` the conversation.

This one-shot-per-message model is the source of three distinct,
observable problems:

1. **Nothing outside the app can drive a session.** Each message is an
   ephemeral process that exists only for the duration of one turn. There
   is no live, addressable session that another Claude session, a script,
   an MCP server, or the operator on another device could send a message
   to, read the state of, or steer. The operator wants "remote control" —
   to talk to a running focus by name (e.g. send a message to "Claudia")
   from outside the app — and the current architecture makes that
   impossible by construction.

2. **Permission requests can only be bypassed, never answered.** A `-p`
   invocation has no input channel back into the running process, so when
   a tool-permission gate fires there is no way to approve or deny it. The
   app currently ships a blanket bypass policy (an inline `--settings`
   `bypassPermissions` mode) as a safety net precisely because a gate that
   fires in `-p` dead-loops with no surface to answer it. The operator has
   no ability to make a per-call approve/deny decision, even when they'd
   want to.

3. **Per-message process spawn cost and fragility.** Spinning up a fresh
   `claude` process on every message adds startup latency to each turn,
   and the permission context proved fragile across `--resume` and spawned
   sub-agents (the exact failure mode that forced the bypass). The session
   feels less like a live conversation and more like a series of
   disconnected requests.

These are not three features; they are three symptoms of one root cause —
the session host has no persistent, two-way connection to a running
`claude` process. Fixing the host architecture is the precondition for
all three.

## Remote control via Anthropic's relay — DISPROVEN (2026-05-31)

**The relay-ride assumption below is empirically false.** During Milestone B
implementation we verified that Claude Code's `--remote-control` is **inert in
`--input-format stream-json` / `--print` mode**: the flag is accepted but the
session never registers with Anthropic's relay, so it **never appears in the
Claude mobile/web app**. Confirmed three ways: two live daemon sessions spawned
with `--remote-control "<name>"` + a sent message + a fresh focus all failed to
show on the phone; and a controlled `--debug-file` probe of a stream-json
`--remote-control` session showed **zero** remote-control/relay/registration log
activity (only normal API + MCP connections). The earlier mode-3 spike's "20+
TLS connections" were normal API/MCP traffic, not a relay registration —
mis-read as evidence RC worked.

**Root cause (the fork flagged from day one):** native phone remote control
requires an **interactive** session; structured stream-json rendering requires
**`--print`** mode; a single `claude` process cannot be both. The macOS GUI's
daemon-hosted focuses are stream-json, so they are **fundamentally not
controllable from the Claude app** via `--remote-control`.

**What still holds:** persistent daemon-hosted sessions, survival across daemon
restarts, and multi-window mirroring all work and shipped. Only the
*native-phone-RC* leg is closed.

**Paths to phone control (future, pick one):**
- The **Rust TUI** already runs interactive `--remote-control` PTY sessions that
  *do* register on the relay — that is the phone vehicle today, separate from
  the GUI.
- **Build our own remote client** over `nostromd` (the network transport set
  aside at planning time) — the only way to get phone control *with* structured
  rendering. This is now its own project, not a flag.
- **Dispatch / Channels** for fire-and-forget from the phone (not live steering).

The `displayName` plumbing and the `remote_control` spawn parameter are kept
(harmless, default off) in case a focus is ever driven in interactive mode.

## Resolved decisions (operator)

Two scope/safety questions were settled by the operator and are now
requirements, not open questions:

1. **Remote control is cross-device in v1 — NOT local-only.** The intended
   external caller is the operator driving focuses from the **Claude iOS
   app**, so the transport must be reachable from another device on the
   network (not a localhost-only socket). Whatever auth/pairing that implies
   is part of the design. (This supersedes the earlier "local-only acceptable
   for v1" framing — cross-device is in scope.)

2. **No Nostromo-side restriction on who may answer permission requests.**
   An external caller may approve/deny permission gates. Rationale: the only
   caller is the operator via the Claude iOS app, which already presents
   permission UX client-side, so gating it again on Nostromo's end adds no
   safety. The transport's auth (decision 1) is the trust boundary; beyond
   authenticating the caller, do not add a separate operator-only restriction
   on answering permissions.

## Audience

A single operator (Hammer) running the Nostromo macOS app as a personal
HUD/IDE for a stable of Claude Code agents, in these situations:

- **Driving a focus interactively** in a REPL window — typing a message,
  watching the structured stream-json render in `ReplView`, expecting
  conversational continuity within and across turns. Many times a day.

- **Hitting a moment that wants a real permission decision** — a tool
  call the operator would like to consciously approve or deny rather than
  having silently bypassed. Today this is impossible; the operator either
  accepts blanket bypass or the turn dead-loops.

- **Wanting to reach a running focus from elsewhere** — from another
  Claude session, a terminal script, an MCP-connected tool, or
  (eventually) a remote device — to send "Claudia" a message, read what
  state she's in, or approve a pending tool call, without being in front
  of that REPL window. This is the operator's stated "I want remote
  control" need.

- **Returning to the app after a restart** and expecting every focus's
  conversation to still be there, exactly as it works today.

## Success criteria

The PRD is satisfied when:

1. **One persistent process per focus.** A focus's `claude` process is
   started once and stays alive across many messages; sending a second
   message to a focus does **not** spawn a second `claude` process. The
   operator can send N messages and observe a single long-lived process
   servicing all of them.

2. **Conversational continuity is preserved or improved.** Multi-turn
   context within a session works at least as well as the current
   `--resume` model — a later message correctly sees the context of
   earlier ones in the same focus.

3. **The structured render is unchanged.** `ReplView` continues to render
   `ChatSession`'s published turns as a structured chat REPL parsed from
   stream-json — **not** a raw terminal. No visual regression in how turns,
   tool calls, and assistant text appear.

4. **Session persistence across app restarts still works.** After quitting
   and relaunching the app, each focus shows its prior conversation and can
   continue it, matching today's behaviour (today via
   `~/.nostromo/gui-sessions.json` + `--resume`). The mechanism may change;
   the observable guarantee must not.

5. **Multi-window mirroring still works.** Two windows showing the same
   focus observe the same live session; a message sent or a turn streamed
   in one is reflected in the other, as the shared session registry
   provides today.

6. **A permission request can be answered, not only bypassed.** When a tool
   call triggers a permission gate, the app can surface that request in the
   REPL UI and the operator can **approve or deny** it, with the running
   session proceeding accordingly. A policy-driven auto-approve (including
   the current bypass) remains available as a configured default.

7. **A focus is addressable by a stable name and drivable from outside the
   app.** An external caller can, by referring to a focus's name (the same
   label shown on its view), at minimum:
   - send a user message to that focus, and have it appear and stream in
     the REPL exactly as if typed in the window;
   - read the focus's current state (e.g. is it idle / mid-turn / awaiting
     a permission decision, and its recent turns);
   - respond to a pending permission request for that focus
     (approve / deny).
   The transport/mechanism is deliberately unspecified here (see Open
   questions); the requirement is the *capability* and its surface.

8. **The bypass safety net survives.** The inline-`--settings` bypass-by-
   default behaviour shipped recently remains the configured default
   posture, so nothing regresses for focuses where the operator does not
   want to be prompted.

9. **Lifecycle is controllable.** The operator (and the host) can start,
   stop, restart, and resume a focus's session deliberately — including
   recovering cleanly if the underlying process dies — without losing the
   rendered conversation or corrupting persisted state.

Not required for v1 (good follow-ups, defer):

- A full permission *policy editor* UI beyond approve/deny + the existing
  default.
- Image forwarding to the subprocess (already a known gap, tracked
  separately; persistent input may make it easier but it is not in scope
  here).
- Multiplexing more than one concurrent in-flight turn per focus beyond
  whatever the current queue-and-drain behaviour already provides.

## In scope

- **Redesign of `ChatSession`** from one-shot `claude -p`-per-message to a
  **single long-lived bidirectional `claude` process per focus**, using
  `--input-format stream-json --output-format stream-json` so the host
  writes user messages (and permission/control responses) to the process's
  stdin as stream-json and reads events from stdout. Sessions named via
  `-n <ViewName>` so the running session's name matches its view label.

- **Session lifecycle management:** start on first need, keep alive across
  messages, stop/restart on demand, resume/recover after a process death or
  app restart, and tear down cleanly on focus removal.

- **Input path:** delivering user messages to the live process over stdin
  as stream-json, replacing the per-message `-p` argument.

- **Event parsing:** continuing to consume the stream-json event stream to
  build the published turn list, including handling a continuous stream
  rather than a per-turn process that exits at turn boundary (turn-boundary
  detection now comes from the stream, not from process termination).

- **Permission request/response handling:** detecting a permission request
  in the event stream, surfacing it in `ReplView` as an answerable prompt,
  and writing the operator's (or policy's) approve/deny decision back to the
  process over stdin.

- **The remote-control product surface:** the definition of what an external
  caller can do to a named focus (send message / read state / answer
  permission), the addressing model (focus name == view label), the
  authority/trust expectations for who may drive a focus, and the
  requirements the transport must satisfy. (Choosing the transport is
  Archie's; see Open questions.)

- **Preserving persistence, mirroring, and the structured render** as
  cross-cutting invariants per the success criteria.

## Out of scope

- The Rust TUI under `src/` and its separate
  `docs/plans/cc-repl-remote-control-by-default.md`. This PRD does not touch
  it and does not adopt its `--remote-control` approach (that flag is for
  interactive PTY sessions and is **not** applicable to the print/stream-json
  model — do not rely on it).
- Mother's background workers / job orchestration.
- The concrete wire protocol and transport for external remote control —
  define the capability and requirements; let planning choose the mechanism.
- A permission policy-editor UI beyond approve/deny + default posture.
- Image forwarding to the subprocess.

## Constraints to honor

- **Structured render, not a terminal.** `ReplView` must keep rendering the
  parsed stream-json turn model. This is not a PTY/terminal surface and must
  not become one.
- **Persistence across restarts.** Conversations must survive app restarts,
  as they do today (currently `~/.nostromo/gui-sessions.json` + `--resume`).
  If the persistence mechanism must change to fit a long-lived process, the
  *observable* guarantee (conversation is there and continuable after
  relaunch) must be preserved.
- **Multi-window mirroring.** The shared session registry behaviour
  (`AppStore.session(for:agentName:workingDirectory:)`) must be preserved —
  multiple windows on one focus share one session.
- **Bypass-by-default safety net stays.** The recently shipped inline
  `--settings` `bypassPermissions` policy remains the default posture and
  must keep being scoped to Nostromo's sessions only (never the operator's
  global `~/.claude/settings.json`).

## Verified technical facts (claude 2.1.158, confirmed this session)

These are provided to ground the requirements; they are not design
decisions.

- `--input-format <format>` "only works with --print" and supports
  `stream-json` — this is the bidirectional input channel.
- `--output-format stream-json` emits the event stream the app already
  parses.
- `-n, --name <name>` sets a display name for the session.
- `--remote-control [name]` exists but is for **interactive** sessions, not
  the print/stream-json model — do not rely on it.
- `--settings <file-or-json>` accepts inline JSON; already used to scope a
  bypass policy to Nostromo without touching global settings.
- `--permission-mode <mode>` includes `default`, `bypassPermissions`, and
  others.
- The **exact stream-json control-message shapes** for permission
  request/response are NOT yet verified — this is a research item for
  planning, not something to invent.

## Risks and unknowns

- **Unverified permission control protocol.** The precise stream-json
  control-message shapes for a permission request (process → host) and the
  approve/deny response (host → process) are not yet confirmed. The entire
  "answer a permission, don't just bypass" capability depends on this
  existing and being usable over stdin. If it doesn't exist in a usable
  form, success criterion #6 may need to fall back to bypass-only for v1.
  Archie should verify this early — it gates the design.

- **Persistence model may not survive the architecture change.** Today's
  persistence leans on `--resume <session_id>` between separate processes.
  Whether `--resume` composes with a long-lived `--input-format stream-json`
  process — or whether persistence needs a different approach (replaying
  the on-disk session JSONL, keeping the process alive, or something else) —
  is unknown and could be the hardest part. Success criterion #4 must hold
  regardless of which path is chosen.

- **Process longevity and failure modes.** A long-lived process can crash,
  hang, leak, or be killed by the OS. The redesign must define recovery
  behaviour without losing the rendered conversation or corrupting persisted
  state. More live processes (one per focus) also raises resource-footprint
  questions compared to the current spawn-and-exit model.

- **Continuous-stream parsing.** Turn boundaries currently coincide with
  process termination. With a persistent process, boundaries must be derived
  from the event stream itself; mis-detecting them would corrupt the turn
  model and visibly break the render.

- **Remote-control safety → reframed as transport auth.** Per Resolved
  decision 2, answering permissions is intentionally allowed for
  authenticated callers, so the risk is NOT "should an external caller
  answer permissions" (settled: yes). The real risk concentrates in the
  **cross-device transport's authentication**: because an authenticated
  caller can approve tool calls (and the bypass default already runs),
  weak transport auth would let an unintended party drive an agent with
  full tool access. The transport must authenticate that the caller is the
  operator's device; that auth is the entire trust boundary and must be an
  explicit, deliberate part of the design, not an accident of the chosen
  mechanism.

## Open questions

For Archie / research to resolve during planning. Not for Ada to answer
definitively.

1. **Permission control protocol.** What are the exact stream-json
   control-message shapes for a permission request from the process and the
   approve/deny response back over stdin? Does claude 2.1.158 support this in
   the `--input-format stream-json --print` model at all? (Gates criterion #6.)

2. **Persistence with a persistent process.** Does `--resume` work with a
   long-lived `--input-format stream-json` process, or does cross-restart
   persistence need a different approach (JSONL replay as already done in
   `loadScrollback`, process hand-off, or other)? (Gates criterion #4.)

3. **Remote-control transport.** What should the external transport be? The
   app already ships a daemon (`nostromd`) and a Unix-socket IPC client
   (`NostromodClient`, length-prefixed JSON frames, pub/sub topics, auto-
   reconnect) — is that the natural home for remote control, or is a local
   socket per focus, or an MCP server, the better fit? Capability and
   requirements are fixed here; the mechanism is Archie's call.

4. **Remote-control authority model.** RESOLVED (see Resolved decisions):
   external callers may answer permission requests; there is no operator-only
   restriction on Nostromo's end. The remaining design work is the
   **transport auth/pairing** that authenticates the caller (decision 1's
   cross-device requirement) — that authentication IS the trust boundary.
   Archie should design that auth; it is not "who may answer permissions"
   (settled) but "how do we know the caller is the operator's device."

5. **Migration / rollout.** Can the persistent-process host land
   incrementally behind the existing UI (e.g. one focus type first, or a
   feature flag, with the one-shot path as fallback), or is it a hard cutover
   for all focuses at once? What's the safe rollback if the long-lived
   process model misbehaves in daily use?

6. **Naming collisions.** Focus names (and thus `-n <ViewName>`) include
   dynamic ones like "Claudia in <project>". Are these guaranteed unique and
   stable enough to serve as the remote-control address, or does addressing
   need a separate stable key (the current registry uses a `tag` distinct
   from `agentName`)?
