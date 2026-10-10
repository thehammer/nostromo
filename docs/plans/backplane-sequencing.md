# Backplane Sequencing — universal access to Nostromo state from every device

**Author:** Archie (drafted 2026-10-10 from an operator brief; no Ada PRD yet —
see Q1–Q3)
**Status:** Draft
**Inputs:** `docs/plans/platform-evolution-sequencing.md` (bets B1–B6),
`docs/visions/iphone.md`, `docs/visions/ipad.md`,
`docs/prds/daemon-pairing-flow.md` (stub), `docs/prds/push-relay.md` (stub)

## Notation

- **W*N*** — **Wedge.** A shippable unit of work with its own plan in
  `docs/plans/backplane/W<N>-<slug>.md`, enqueued as one Mother job.
  Numbering continues from the platform memo (W1–W8 are taken).
- **Q*N*** — **Question for Ada.** Product question to answer before the
  dependent wedge is dispatched.
- **B*N*** — **Bet.** Architectural decision with cross-cutting consequences.
  B1–B6 are defined in the platform memo; B7–B8 are new here.

## The brief, restated

The operator has five machines:

| Host | What it is | Role today | Role after this memo |
|---|---|---|---|
| **Kobe** | Carefeed-managed MacBook Pro | runs the only `nostromd`; Mother; Bishop; Carefeed repos | **satellite** — keeps all of that, publishes upstream, dials out only |
| **Sendai** | personal Mac Mini, always on | — | **primary** candidate (B7); Mother for personal repos |
| **Tokyo** | personal Linux workstation, always on | — | **primary** candidate (B7) |
| **iPhone / iPad** | mobile | LAN-only via Bonjour + raw TCP | paired WebSocket clients over WireGuard |

Two facts drive everything:

1. **Kobe is closed when the operator commutes.** No daemon runs. The home
   of shared state must move to an always-on host. (The platform memo's
   "Tailscale-to-Mac" assumed the Mac in question was awake.)
2. **Kobe's MDM recently broke iOS↔Mac first contact.** The current path is
   Bonjour discovery (`src/mdns.rs`, `_nostromo._tcp`) followed by an
   *inbound* unauthenticated TCP connection to `0.0.0.0:47100`
   (`src/bin/nostromd.rs:117-150`). Every plausible MDM control (multicast
   filtering, inbound firewall / stealth mode, a filtering network
   extension) is defeated the same way: Kobe only ever dials **out**, and
   nothing discovers Kobe.

Reachability already exists: a **WireGuard VPN on the operator's UDM Pro**.
Phone, iPad and Kobe join the home network over it and reach the primary at
a stable private address. No hosted hub. The one cloud component left is the
APNs push relay (W13), a one-shot HTTPS POST, in the operator's personal AWS
account.

## Bets

### B2 (platform memo) — RESOLVED: VPN-to-home over WireGuard
Not Tailscale, not a cloud backplane. The daemon exposes a WebSocket
endpoint on the home network; the UDM Pro's WireGuard is the only
off-site path. A hosted hub is reopened only if Kobe cannot run the
WireGuard client (see "Risks").

### B7 — Which always-on host is the primary: Sendai (macOS) or Tokyo (Linux)?
Evidence gathered:

- `.github/workflows/ci.yml:19-47` already runs `cargo build --all-targets`,
  clippy and `cargo test` on **`ubuntu-latest`**. The Rust workspace, and
  therefore `nostromd`, builds and passes tests on Linux today. The
  platform-specific pieces are packaging only: `Makefile:47-75`
  (`install-daemon` is launchd + `codesign`) and the launchd plist.
- The primary does **not** need Mother or Bishop locally: satellites
  publish `MotherJobs`/`MotherStatusline`/posture. Bishop is macOS-only
  (keychain, `bin/bishop:964`); Mother's `daemon install` on Linux is a
  TODO (`bin/mother:3243-3248`) but `mother daemon start` works.
- A primary wants: never sleeps, no MDM, no GUI session required, headroom
  for the replay ring and many PTY scrollbacks. That is a headless Linux
  box. Sendai additionally runs a Mac app and would want to be a satellite
  for its *own* PTYs and personal-repo Mother anyway.

**Decision: Tokyo is the primary; Sendai and Kobe are satellites.** W14
(Linux packaging) is small, independent, and goes first. If W14 surfaces a
blocker (it should not), Sendai takes the primary role with no change to
W9–W13 — `mode = primary` is a config value.

### B8 — Wire protocol: WebSocket carrying the existing JSON, not a new protocol
Every network peer speaks `ClientMsg`/`ServerMsg` (`src/ipc/protocol.rs`)
as one JSON text frame per message over WebSocket (`ws://` inside the
tunnel; `wss://` is a config switch for a future public endpoint). Binary
frames are reserved for PTY bytes. The length-prefixed codec
(`src/ipc/codec.rs`) stays for the Unix socket. Rationale: Apple platforms
have a first-class client (`URLSessionWebSocketTask`, ping/pong,
background-task friendly); framing comes free; a satellite can *dial out*
through anything that passes HTTPS; the Swift decoders do not change.

Device tokens remain **even inside WireGuard**: a WireGuard peer is a
network identity, a device token is an application identity (revocation,
per-device sensitive-data scope, the key the push relay uses).

## Dependency graph and dispatch order

```
W14 linux-primary ──────────────────────────────┐ (independent; decides B7's host)
                                                │
W9  ws-transport ───┬──▶ W10 satellite-uplink ──┼──▶ W12 seq-resume ──▶ W13 push-relay
                    │                           │         ▲
                    └──▶ W11 ios-ws-client ─────┘─────────┘
```

Mother dispatch (ids are whatever `mother add` prints; `--depends-on` gates
on the dependency's PR being **merged**, so the order below is also the
merge order):

```bash
cd ~/Code/nostromo
W14=$(mother add --plan-file docs/plans/backplane/W14-linux-primary.md    --repo nostromo --branch feat/backplane-linux-primary)
W9=$( mother add --plan-file docs/plans/backplane/W9-ws-transport.md      --repo nostromo --branch feat/backplane-ws-transport)
W10=$(mother add --plan-file docs/plans/backplane/W10-satellite-uplink.md --repo nostromo --branch feat/backplane-satellite-uplink --depends-on "$W9")
W11=$(mother add --plan-file docs/plans/backplane/W11-ios-ws-client.md    --repo nostromo --branch feat/backplane-ios-ws-client    --depends-on "$W9")
W12=$(mother add --plan-file docs/plans/backplane/W12-seq-resume.md       --repo nostromo --branch feat/backplane-seq-resume       --depends-on "$W10,$W11")
W13=$(mother add --plan-file docs/plans/backplane/W13-push-relay.md       --repo nostromo --branch feat/backplane-push-relay       --depends-on "$W12")
```

W13 should **not** be enqueued until Q2 is answered (its PRD is a stub).

## Wedges

| Wedge | Repo | Depends on | One line |
|---|---|---|---|
| **W14** `linux-primary` | nostromo | — | systemd user unit + `make install-daemon-linux`; satellite-free primary verified on Linux. Resolves B7's host. |
| **W9** `ws-transport` | nostromo | — | WebSocket listener, `devices.json` tokens, `PeerTrust::Paired`, `nostromo device {add,list,revoke,pair}`, `Pair` wire exchange. Ends the MDM problem for anything that can reach the primary. |
| **W10** `satellite-uplink` | nostromo | W9 | `mode = primary\|satellite`; satellite dials the primary, publishes host-tagged topics, accepts routed actions; primary routes `host:`-addressed commands. Kobe's Mother/Bishop/PTYs appear everywhere. |
| **W11** `ios-ws-client` | nostromo | W9 | `WebSocketClient.swift`, Keychain token, pair-by-QR/code, host selector; Bonjour becomes optional. |
| **W12** `seq-resume` | nostromo | W10, W11 | Per-topic `seq`, replay ring, resume-on-reconnect, WS heartbeats, bounded per-client queues with `Gap`. Cellular-grade reliability. |
| **W13** `push-relay` | nostromo (+ `infra/`) | W12, Q2 | Daemon push intents → Lambda → APNs; iOS registration and deep links. |

## What this sequence deliberately does not do

- **Carry session conversations.** `persistent-bidirectional-session-host.md`
  chose Remote Control (Anthropic's relay) for that. The backplane carries
  state, PTY bytes and actions.
- **Change Mother or Bishop.** They stay host-local; the satellite's existing
  pollers (`src/bin/nostromd.rs:384-390`, `src/mother/mod.rs:228`) are the
  bridge. Mother's broker is never exposed off-host.
- **Make coding work from a closed laptop.** Nothing runs on a sleeping Kobe.
  Personal repos: Mother on Sendai as a satellite. Carefeed repos: Claude
  Code cloud sessions tracked over Remote Control; Mother dispatching to a
  cloud session instead of a local worktree is a Mother feature for a later
  memo.
- **Host a hub or add E2E above WireGuard.** Reopened only by the risk below.

## Risks

- **Kobe cannot run WireGuard** (MDM forbids VPN payloads, or the office
  network drops UDP 51820 — try moving the UDM listener to UDP/443 first).
  Then the satellite needs a public `wss://` endpoint: a UDM port-forward to
  the primary with a DDNS name and an ACME certificate, or a payload-blind
  hub (one Fargate task). B8 keeps either a satellite config change. Test on
  Kobe before W10 is dispatched: install the WireGuard app, import the UDM
  profile, `ping` the primary's WireGuard address.
- **Sensitive data on the primary.** Teri/Fred mail subjects and todos would
  be retained on Tokyo. Default in W10 is to publish them
  (`uplink.publish_sensitive = true`) because the host is the operator's own
  and the link is WireGuard; the switch exists so the answer can change
  without a redesign. Paired devices still only receive sensitive frames when
  their registry record says `sensitive: true` (W9).

## Questions for Ada

- **Q1 — Pairing UX** (`docs/prds/daemon-pairing-flow.md` is a stub). W9
  builds only the wire exchange and the CLI; W11 needs the phone-side flow
  specified (scan vs typed code, what success looks like, re-pair after
  revocation).
- **Q2 — Push relay PRD** (`docs/prds/push-relay.md` is a stub). W13 is not
  dispatched until the payload contract (what may appear in a notification
  body) and the retention policy are written down.
- **Q3 — Multi-host presentation.** When Kobe's and Sendai's Mother queues
  both exist, how does the phone show them: one merged list with a host
  badge, or a host picker? W10 tags the data; W11 defaults to a merged list
  with a badge unless Ada says otherwise.
