# Backplane Sequencing — universal access to Nostromo state from every device

**Author:** Archie (drafted 2026-10-10 from an operator brief; revised
2026-10-10 after Ada's pairing PRD answered Q1)
**Status:** Draft. W11 and W15 wait on Ada's sign-off of D1–D6 (see Q1).
**Inputs:** `docs/plans/platform-evolution-sequencing.md` (bets B1–B6),
`docs/visions/iphone.md`, `docs/visions/ipad.md`,
`docs/prds/daemon-pairing-flow.md` (Ada, answers Q1), `docs/prds/push-relay.md`

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
W9  ws-transport ───┬──▶ W10 satellite-uplink ──┼──▶ W12 seq-resume ──▶ W13 push-relay ──▶ W16 ios-push-enrichment
                    │            │              │         ▲
                    │            └──▶ W15 mac-device-admin│
                    └──▶ W11 ios-ws-client ─────┘─────────┘
```

W15 depends on W10 because the Mac app only ever talks to its local daemon,
and Sendai and Kobe are satellites. Without W10's relay, the Mac's admin
verbs have no registry to reach. W11 and W15 are independent of each other
(W15 touches only `macOS/`), so they can run in parallel.

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
W15=$(mother add --plan-file docs/plans/backplane/W15-mac-device-admin.md --repo nostromo --branch feat/backplane-mac-device-admin --depends-on "$W10")
W13=$(mother add --plan-file docs/plans/backplane/W13-push-relay.md       --repo nostromo --branch feat/backplane-push-relay       --depends-on "$W12")
W16=$(mother add --plan-file docs/plans/backplane/W16-ios-push-enrichment.md --repo nostromo --branch feat/backplane-ios-push-enrichment --depends-on "$W13")
```

Q2 is answered (`docs/prds/push-relay.md`). W13 and W16 wait only on Ada's
sign-off of deviations S1–S6 in that PRD's "Design-loop notes for Ada"; W16
additionally needs the operator to request Apple's notification-filtering
entitlement (it ships without it, see S1).
W11 and W15 should **not** be enqueued until Ada signs off the deviations
D1–D6 in the PRD's "Design-loop notes for Ada" (see Q1). Nothing in D1–D6
changes W9 or W10, so W9 can go now. W10 waits only on the open technical
item below (routed-action trust).

## Wedges

| Wedge | Repo | Depends on | One line |
|---|---|---|---|
| **W14** `linux-primary` | nostromo | — | systemd user unit + `make install-daemon-linux`; satellite-free primary verified on Linux. Resolves B7's host. |
| **W9** `ws-transport` | nostromo | — | WebSocket listener, `devices.json` tokens, `PeerTrust::Paired` with live scope changes, in-memory pairings owned by the issuing connection (lockout, outcome reporting, name dedup), device-admin IPC verbs, `nostromo device {pair,list,revoke,mail-and-todos,admin}`. Ends the MDM problem for anything that can reach the primary. |
| **W10** `satellite-uplink` | nostromo | W9 | `mode = primary\|satellite`; satellite dials the primary, publishes host-tagged topics, accepts routed actions; primary routes `host:`-addressed commands. Kobe's Mother/Bishop/PTYs appear everywhere. Also relays device admin from a satellite's local clients to the primary, which enforces each satellite's `admin` level; `nostromo uplink pair` enrols a satellite by code. |
| **W11** `ios-ws-client` | nostromo | W9 (+W10 for `host`) | `WebSocketClient.swift`, Keychain token, the PRD's Pair with Nostromo flow (scan, system-Camera deep link, typed), encrypted last-known content cache, no-longer-paired wipe, Settings with Un-pair; Bonjour becomes legacy. |
| **W15** `mac-device-admin` | nostromo | W10 | Mac app **Pair a Device…** window and **Devices** list (revoke, mail-and-todos toggle), over the existing Unix socket, working from Sendai or Kobe. |
| **W12** `seq-resume` | nostromo | W10, W11 | Per-topic `seq`, replay ring, resume-on-reconnect, WS heartbeats, bounded per-client queues with `Gap`. Cellular-grade reliability. |
| **W13** `push-relay` | nostromo (+ `infra/`) | W12, Ada sign-off S1–S6 | Closed-vocabulary push engine on the primary (grace delay, coalescing, quiet hours, 07:00/17:30 summaries, withdrawal, sent log) → stateless Lambda → APNs; iOS registration, settings, deep links. |
| **W16** `ios-push-enrichment` | nostromo | W13 | Notification Service Extension: on-phone enrichment over the VPN, lock-screen decision actions, NSE withdrawal (filtering entitlement). |

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

- **Kobe cannot run WireGuard** — **retired 2026-10-10.** The WireGuard
  client is installed on Kobe alongside Twingate (Carefeed's ZTNA) and
  reaches the home network from the office. Two operational notes carried
  into W10: (1) keep Kobe's WireGuard profile **split-tunnel** —
  `AllowedIPs` = the home subnet (and the primary's address) only — so
  Carefeed traffic continues to route via Twingate and never transits the
  operator's home network; (2) the satellite's uplink URL must use the
  primary's WireGuard/LAN address, not a public name, so a Twingate DNS
  policy cannot capture it. The public-endpoint / hub fallback is no longer
  planned; B8 still keeps it a config change if that ever reverses.
- **Sensitive data on the primary.** Teri/Fred mail subjects and todos would
  be retained on Tokyo. Default in W10 is to publish them
  (`uplink.publish_sensitive = true`) because the host is the operator's own
  and the link is WireGuard; the switch exists so the answer can change
  without a redesign. Paired devices still only receive sensitive frames when
  their registry record says `sensitive: true` (W9).

## Open technical item (Archie)

- **Routed actions from devices are refused today.** W9 keeps a `Paired`
  device's `network_policy` equal to the `Tcp` allow-list (read-only plus
  `DeviceUnpairSelf`). W10 also injects primary-routed commands into a
  satellite under `Paired` trust. So W10's `MotherResume`/`MotherAction`/
  `Pty*`/`Session*` routing criterion would be refused at both ends as
  written. This predates the pairing PRD and is not changed by it. It needs
  a small bet of its own (which verbs a paired device may drive, and under
  what trust a satellite runs routed commands) before W10 is dispatched.
  Flagged here rather than quietly widened in W9.

## Questions for Ada

- **Q1 — Pairing UX — ANSWERED** by Ada's PRD
  `docs/prds/daemon-pairing-flow.md` (2026-10-10). W9, W10 and W11 were
  revised to it, and W15 was added for the Mac app, which no wedge planned
  before. Every ambitious bet (AC6, AC12 with AC24, AC13 with AC14, AC27,
  AC35), and every other AC Ada expected pushback on (AC9, AC17, AC31), is
  planned as written. **Pending Ada's sign-off**
  (design loop turn 1; details and evidence are in the PRD's "Design-loop
  notes for Ada"):
  - **D1:** iOS Local Network permission makes AC2 hold only when the
    server is reached over the VPN or from another subnet (Apple TN3179),
    plus a fifth failure state.
  - **D2:** AC3 excludes iOS's one-time camera-permission alert.
  - **D3:** a pairing dies with its window or command, or a lost
    connection; this needs one new message.
  - **D4:** the confirmation step follows a server check, so failures show
    before it.
  - **D5:** lockout counts across concurrently open codes.
  - **D6:** re-pairing via a link on an already-paired phone.

  The PRD's own open questions 1 (mail-and-todos default) and 2 (device
  admin on Kobe) are for the operator. Both are settings in these plans
  (W9 default; W9/W10 per-Mac `admin` level), so neither blocks dispatch.
- **Q2 — Push relay PRD** — **ANSWERED 2026-10-10** by Ada's
  `docs/prds/push-relay.md` (closed vocabulary per kind, host classes, 7-day
  retention). The operator also answered both of its open questions: add a
  17:30 evening summary, and Carefeed content on the phone is allowed
  (work-host enrichment is opt-in). Archie's design-loop notes at the end of
  that PRD list deviations **S1–S6, pending Ada's sign-off**: S1 2-minute
  withdrawal depends on Apple's filtering entitlement; S2 decisions are never
  coalesced; S3 size phrase omitted when unknown; S4 Open-only when choices
  exceed iOS's action limit; S5 review repo names also gated on owner ∉
  `work_owners`; S6 *times out in under 1 min*. Planned in W13 and the new
  W16.
- **Q3 — Multi-host presentation.** When Kobe's and Sendai's Mother queues
  both exist, how does the phone show them: one merged list with a host
  badge, or a host picker? W10 tags the data; W11 defaults to a merged list
  with a badge unless Ada says otherwise.
