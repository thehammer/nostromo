# Nostromo native on iPhone / iPad (north star)

**Type:** idea · **Repo:** nostromo · **Status:** parked (vision / north star)

## The vision

Run **Nostromo natively on iPhone and iPad**, owning the **full session
lifecycle and remote access end-to-end**. A Nostromo mobile client attaches to
`nostromod` (or its successor broker) over the network and renders the same
**structured turn model** we built for the macOS GUI — NOT the Claude app, NOT a
terminal. Same focuses, same daemon-hosted persistent sessions, same
mirroring — just reachable from a phone or tablet.

This is the thing the operator ultimately wants. Everything in the
persistent-bidirectional-session-host work is a step toward it.

## Why this, vs. riding Anthropic's relay

Established empirically (2026-05-31, see
`docs/prds/persistent-bidirectional-session-host.md`):

- Claude Code's native `--remote-control` (the Claude-app relay) **only works in
  interactive mode**, which is mutually exclusive with the `--print` /
  stream-json structured output Nostromo renders. So the Claude app can never
  drive Nostromo's structured sessions directly.
- A **handoff stopgap** exists (stop the stream-json process, resume the same
  session interactively with `--remote-control` for the phone, hand back) — but
  it's a swap, not true ownership, and it puts the operator in the Claude app,
  not Nostromo.

To get Nostromo's *own* experience on mobile, with structured rendering and full
control, we have to **own the transport and the client** — not borrow
Anthropic's relay.

## What it requires (rough shape, not a plan)

1. **A network-reachable broker.** `nostromod` is a local Unix socket today; the
   mobile client needs a network transport with authentication (the cross-device
   + auth requirements already in the PRD). This is the "build our own remote
   client over nostromd" path — the first real step.
2. **The session-host protocol exposed remotely.** The v3 `Session*` IPC
   (attach / send / turn deltas / state) is already the right surface; it needs a
   secure remote binding.
3. **A native iOS/iPadOS client** that speaks that protocol and renders the turn
   model (the daemon already owns parsing in Rust, so the model is portable).
4. **Lifecycle ownership** — start/stop/resume/crash-recovery driven from mobile,
   not just the Mac.

## Sequencing

- **Now:** parked. The macOS structured-local experience shipped (Milestone B).
- **Stopgap, when wanted:** the interactive-`--resume` handoff + GUI toggles
  (see the PRD).
- **First real step toward this:** the own-remote-client-over-nostromd transport
  (network + auth). That transport is what the mobile client connects to.
- **Then:** the native iPhone/iPad app.

No work scheduled. Captured so the north star isn't lost and so the transport
work, when it happens, is framed as building toward this rather than a one-off.
