# Platform Evolution Sequencing

**Author:** Archie
**Status:** Draft (turn 1 of Phase 3 design loop)
**Inputs:** `docs/visions/mac-native.md`, `docs/visions/iphone.md`, `docs/visions/ipad.md`

## What this is

A meta-plan over Ada's three vision docs. The visions describe end-states
across four surfaces (Mac TUI today, Mac native app, iPhone, iPad) that share
one daemon-backed agent core. There is no single plan that gets us from here
to there — there is a *sequence* of plans, each of which is shippable on its
own and unlocks the next.

This memo identifies that sequence, names the bet-the-platform decisions,
calls out which wedges already have plan docs in this directory, and surfaces
questions for Ada (turn 2 of the design loop) before more plans are written.

## Current ground truth (verified in the repo, not inferred from the visions)

- **Daemon (`nostromd`, `src/bin/nostromd.rs`)** owns: PTY processes, the
  `~/.claude/activity.jsonl` tail, and a 2-second poll of `mother list
  --format json`. It broadcasts `ServerMsg::{Activity, MotherJobs,
  MotherStatusline, MotherAwaitDetected}` to subscribed clients over a Unix
  socket at `~/.nostromo/nostromd.sock` (length-prefixed JSON frames,
  protocol version 2). See `src/ipc/protocol.rs` and `src/ipc/server.rs`.
- **MCP server (`src/mcp/server.rs`)** is bound *by the TUI*, not the
  daemon. Its `McpSharedState` contains live `watch::Receiver`s for Mother
  jobs, Mother status, Fred mailbox/calendar, Perri PR queue, Teri todos,
  rate limits and budget posture. The MCP socket lives at
  `~/.nostromo/mcp.sock`. **Consequence: if the TUI is not running, there
  is no MCP endpoint to talk to.** This is the single most important
  technical fact for sequencing the Mac-native and mobile surfaces.
- The Mac-native vision implies a status-bar item that surfaces Mother
  queue counts and calendar next event without the TUI being open. That
  is not achievable today: either MCP hosting moves into the daemon, or
  the status-bar item subscribes to the daemon's existing IPC socket
  (which already broadcasts Mother data) and bypasses MCP for v1.
- There is **no TCP listener, no TLS, no auth/pairing model, no token
  format** in the codebase. All sockets are Unix-domain and trust-by-file-
  permission.
- The Rust workspace has one binary crate per surface: `nostromo` (TUI),
  `nostromd` (daemon), `nostromo-mcp-bridge` (in-PTY bridge). No Swift,
  no Xcode project, no mobile target.

## The bet-the-platform decisions, named explicitly

These must be resolved (or deliberately deferred behind an abstraction)
before any work past the first wedge ships. They are listed roughly in
the order they become binding.

### B1. Where does the MCP server live?
**Options:** (a) keep MCP in the TUI, add a thin read-only daemon surface
for non-TUI clients; (b) move MCP hosting into the daemon; (c) run MCP in
*both* places, with the daemon as primary when up.

The visions assume (b) — that the daemon is the canonical agent endpoint
that all clients (TUI, Mac native, mobile) connect to. That's right for
the long term but a non-trivial refactor: every `watch::Receiver` in
`McpSharedState` is currently sourced from TUI-internal state. The
pragmatic v1 is (a): the daemon already broadcasts Mother data, so the
Mac status-bar item can subscribe over the existing IPC socket. (b) can
be sequenced *after* the first network-transport wedge lands.

**Decision binding point:** before the second non-TUI client ships. The
status-bar item can be (a); a second Mac window (e.g. Mother queue
native) probably forces (b).

### B2. Daemon network transport — Tailscale vs cloud backplane
Ada calls this the bet-the-product decision (`iphone.md` §"Open bets").
For the personal-leverage phase, **Tailscale-to-Mac** is dramatically
simpler: no hosted infra, no key management beyond Tailscale's, no AWS
spend, no SOC-2-shaped product surface to defend. For the eventual
product pivot, a **cloud backplane** is probably necessary (always-on,
APNs delivery, multi-device fanout).

The good news: the *protocol* the daemon exposes is the same in both
cases — JSON-RPC over a TLS-terminated TCP socket with a bearer token.
What differs is who runs the TLS endpoint (local Mac vs hosted relay)
and where the token comes from. **We can design the network-transport
wedge to be transport-agnostic** and defer the cloud-vs-Tailscale call
until the second mobile drop.

**Decision binding point:** before any iPhone/iPad ships. Not binding
on the Mac-native app.

### B3. Auth / pairing model
Tied to B2. iPhone vision §"Open bets" suggests pairing-flow (QR on Mac
+ scanned on phone) → long-lived device token. We need this even for
the local-LAN case once we have a network listener. Probably:

- Daemon-side: write a `~/.nostromo/devices.json` with a list of
  `(device_id, token_hash, created_at, last_seen)` records.
- Client-side: token in Keychain.
- Pairing: short-lived code printed by the Mac, scanned/typed on the
  client device.

**Decision binding point:** the same wedge that adds the network listener
(see Wedge W2 below).

### B4. Window model on Mac native — Slack-style single window vs
Mail-style many windows
Ada flagged this in `mac-native.md` as open and leaning towards
free-floating. This is a *product* decision, not a technical one, and
doesn't gate any infrastructure. **Surfaced as question Q1 below.**

### B5. iPad vs iPhone — one SwiftUI codebase or two
Ada's `ipad.md` §"Open bets" leans towards one SwiftUI project targeting
both. This affects which wedge ships first. **Surfaced as Q2 below.**

### B6. Mac app repo location — `apps/mac/` in this monorepo vs sibling
`nostromo-mac` repo
The Rust workspace and an Xcode project don't share build tooling.
Pragmatic recommendation: **`apps/mac/` inside this repo for now** — one
git history, one issue tracker, one Mother dispatcher. Pull out into a
sibling repo only if the Mac app gains its own release cadence or
contributors. Surfaced as Q3 in case Ada has a strong view.

## The sequence (high-level dependency graph)

```
W1 daemon-mother-readapi  ──────┐
   (Unix socket only)            │
                                 ├──▶ W3 mac-status-bar-item  ──┐
W2 mcp-network-transport ────────┘                              │
   (TLS+token; Unix still works)                                ▼
                                  ┌──────▶ W4 mac-native-shell (window + tabs)
W2 ──────────────────────────────┤
                                  └──────▶ W5 mobile-foundations (pairing, push relay)
                                                                ▼
                                                     W6 iphone-triage-app
                                                                ▼
                                                     W7 ipad-adaptive-app
                                                                ▼
                                                     W8 cloud-backplane (if pivoted)
```

Edges are hard prerequisites. Wedges fanning from the same node can ship
in parallel.

## Wedge inventory

### W1. daemon-mother-readapi  (PLAN WRITTEN: `daemon-mother-readapi.md`)
Stabilise the daemon's existing Mother broadcast as a documented
read-only API surface for non-TUI clients. Confirm multi-client
behaviour, add a `ClientMsg::Snapshot` request that returns the
current state on demand (so a client doesn't have to wait up to 2 s
for the next poll), and write a small Rust client crate (`nostromo-
client`) that wraps the connection logic — so the Mac status-bar item
(via Rust ⇄ Swift FFI or a small helper binary) and any future
in-tree client can reuse it.

Unblocks: W3 (Mac status-bar item can ship over the Unix socket without
B1 being decided).

### W2. mcp-network-transport  (PLAN WRITTEN: `mcp-network-transport.md`)
Add a TLS + bearer-token transport in front of the MCP server, listening
on a configurable TCP port, alongside the existing Unix socket. This is
the *network* prerequisite for everything off-host (mobile, eventual
cloud relay). Includes a minimal device-token format and a pairing-code
file on the daemon side; full QR-flow pairing is W5.

Why now (not after the Mac app): TCP+TLS is the smaller, more contained
piece. Doing it before the Mac app lets us validate the network code
path with `curl` and a Rust test client before any SwiftUI exists.
**Does not require resolving B1** — wraps whichever MCP host is
authoritative when the bind happens.

Unblocks: W3 (optionally — can fall back to W1's Unix path), W4, W5.

### W3. mac-status-bar-item  (PLAN WRITTEN: `mac-status-bar-item.md`)
A small Swift/AppKit menu-bar process that connects to the daemon's IPC
socket (W1) and renders Mother queue counts, posture, calendar next
event. Ships as a standalone `.app` bundle in `apps/mac/` (decision B6,
pending Q3). Establishes the Swift toolchain in the repo. Validates B1
implicitly: if the status-bar item works comfortably over the daemon
IPC + scoped read API, we have evidence option B1(a) is viable through
v1; if it pushes us towards needing MCP semantics (tools/calls, view
mutators), that's strong signal for B1(b).

Acceptance criteria are in the plan doc.

### W4. mac-native-shell  (PLAN NOT YET WRITTEN)
The native window shell — one or many windows (B4), tab/sidebar
chrome, transcript view with native text selection, native markdown
rendering. This is large. Will likely break into sub-plans:

- `mac-native-shell-window-frame` — window/tab management, no view
  content yet.
- `mac-native-shell-transcript-view` — markdown rendering, code
  blocks, selection.
- `mac-native-shell-mother-pane` — Mother queue rendered natively.
- `mac-native-shell-claude-embedding` — Ada's open bet "embed `claude`
  via vt100 vs talk to it headlessly" (`mac-native.md`
  §"Claude Code embedding"); needs its own PRD from Ada before plan.

**PRD Ada should write to unlock this:** `mac-native-shell.md` — pinning
down B4 (window model), the claude embedding strategy, and which views
ship in v1 (all of them, or a subset like Mother + Claudia).

### W5. mobile-foundations  (PLAN NOT YET WRITTEN)
Everything that's prerequisite for *any* mobile surface: full pairing
flow with QR generation/scanning, device-token lifecycle, push relay
component (Ada flagged this is needed even in Tailscale mode for APNs
delivery — `iphone.md` §"Push notifications"), and the SwiftUI project
scaffold targeting iOS + iPadOS.

**PRD Ada should write to unlock this:** `daemon-pairing-flow.md` and
`push-relay.md` — both already named in `iphone.md` §"Related work".
The pairing PRD pins down B3; the push-relay PRD pins down the
minimum viable hosted component (this is the first point at which we
*must* take a position on B2).

### W6. iphone-triage-app  (PLAN NOT YET WRITTEN)
First mobile surface. SwiftUI app, Mother queue glance, push routing,
Claudia thin chat. Depends on W5.

**PRD Ada should write to unlock this:** `mobile-mother-triage.md` and
`mobile-claudia-thin-chat.md`. Both are screen-level PRDs.

### W7. ipad-adaptive-app  (PLAN NOT YET WRITTEN)
Same SwiftUI project as W6, expanded with adaptive layout, PR diff
reader, Pencil annotation (optional v1). Sequence after W6 unless Q2
flips us to ship iPad first.

### W8. cloud-backplane  (DEFERRED; gated on product pivot)
Hosted relay. Only ships if the personal-leverage → product pivot
happens. Out of scope for this memo beyond naming the placeholder.

## Questions for Ada (turn 2 of design loop)

**Q1 — Window model (B4):** confirm Mac-native uses *many free-floating
windows* (Mail-style) for v1, with one window per view. Or do you want
a single primary window with internal tabs as the v1 default? This
changes the W4 plan structure materially: free-floating shifts work
into a robust state-restoration story; tabs shifts work into a
sidebar/tab-bar component.

**Q2 — Mobile order (affects W6 vs W7):** ship iPhone first (W6 → W7)
or iPad first (W7 → W6) or genuinely one codebase shipped together?
You hint at one codebase in `ipad.md` §"Open bets". My read: ship
iPhone first because its scope is smaller (single layout, fewer
features), then expand the same SwiftUI project to iPad. Confirm or
correct.

**Q3 — Mac app repo location (B6):** `apps/mac/` in this repo, or
sibling `nostromo-mac` repo? Defaulting to the former unless you have
a reason for the latter.

**Q4 — Status-bar item content (touches W3 scope):** the vision lists
"Mother queue counts, budget posture, calendar next event." The
daemon broadcasts Mother data today. **Budget posture and calendar
next event are not on the daemon broadcast** — they live in TUI-only
state and are sourced from external data fetchers
(`data::rate_limits`, `data::fred_calendar`). To put them in the
status-bar item, we either: (a) move those data fetchers into the
daemon, (b) cut them from W3 and have the status-bar item show only
Mother counts in v1, or (c) have the status-bar item fetch calendar
itself via the macOS EventKit API (it's running natively on macOS, it
can do that). Lean towards (c) for calendar + (b) for posture (defer
posture to a follow-up). Confirm or correct.

**Q5 — Claudia thin-chat in first mobile drop?** `iphone.md` lists
both Mother triage and Claudia thin chat as v1 capabilities. They're
genuinely independent surfaces. Including Claudia in W6 doubles the
W6 plan size. Are you ok shipping W6 as Mother-triage-only and adding
Claudia in a follow-up wedge, or is Claudia load-bearing for the
"phone is useful at all" v1 story?

**Q6 — Embedded `claude` strategy (gates W4):** the
"embed-vt100-inside-NSView vs talk-headlessly-to-claude-and-render-
ourselves" decision (Ada flagged in `mac-native.md` §"Claude Code
embedding") is genuinely a coin-flip on time-to-ship vs. long-term
fit. Do you want a small PRD from yourself pinning this down before
W4 starts, or are you happy for Archie to make the call inside the
W4 plan? I'd recommend the former — this choice affects every
agent-pane view in the Mac app.

## Notes on technical / non-functional ACs Archie adds (not in Ada's docs)

Each of the written wedge plans below adds technical ACs that
complement the behavioural ACs from Ada's visions. Themes:

- **No regression in the TUI surface.** The daemon and MCP changes
  must leave the existing TUI client behaviour identical. Tested
  by the existing TUI integration tests continuing to pass.
- **Multi-client safety on the daemon IPC socket.** Two clients
  (TUI + status-bar item) subscribing to the same topics receive
  independent broadcasts; one client's slow consumer does not back-
  pressure the other. Tested directly.
- **TLS endpoint refuses connections without a valid token.** No
  silent fallback to unauthenticated transport. (W2.)
- **Status-bar item process is small and well-behaved**: idle CPU
  under 1%, RSS under 50 MB, reconnects automatically on daemon
  restart, exits cleanly on user-quit. (W3.)

## Suggested next step

Ada answers Q1–Q6. If consensus is reached on Q1–Q4 (the smallest
binding subset), W1, W2, and W3 are unblocked and can ship in parallel
as three Mother jobs. W4 onward waits on the PRDs called out above.

If even one of Q1/Q4 is contested, hold W3 and ship only W1 + W2
first — they're internally-facing and won't carry a UX decision into
shipped code.
