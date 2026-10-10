# WebSocket Backplane (Sendai primary, Kobe satellite, WireGuard reach)

**Status:** Draft (2026-10-10). Resolves sequencing bet **B2** and absorbs the
network-listener half of W2 (`mcp-network-transport.md`); supersedes that
plan's TLS+token TCP listener.

## Context

Today exactly one `nostromd` runs, on **Kobe** (the Carefeed-managed MacBook
Pro). It serves the Mac app over a Unix socket and iOS/iPad over an
*unauthenticated* TCP listener (`0.0.0.0:47100`) that iOS finds via Bonjour
(`_nostromo._tcp`, `src/mdns.rs`, `NostromoKit/Transport/DaemonDiscovery.swift`).
Two things make this a dead end:

1. **Kobe is closed when the operator is away.** A sleeping laptop has no
   daemon. No transport fixes that; the shared-state home has to move to the
   always-on personal Mac Mini, **Sendai**.
2. **Kobe's MDM now blocks the iOS↔Mac first contact.** The exact control
   is unknown (multicast discovery, inbound firewall / stealth mode, or a
   filtering network extension) but every candidate is defeated the same way:
   Kobe must only ever *dial out*, and nobody discovers Kobe via mDNS.

Reachability is solved by infrastructure that already exists: a **WireGuard
VPN on the operator's UDM Pro**. iPhone, iPad and Kobe join the home network
over WireGuard and reach Sendai at a stable private address. No hosted hub,
no public endpoint, no TLS certificate management. The only cloud component
left is the APNs push relay (`docs/prds/push-relay.md`), which is a one-shot
HTTPS POST and lives in AWS (operator has a personal account and admin on the
Carefeed account).

The *backplane* is therefore three things, all inside this repo:

- a **WebSocket transport** for the existing `ClientMsg`/`ServerMsg` protocol,
  with device-token auth and a new trust tier;
- a **satellite mode** for `nostromd` so Kobe keeps owning its PTYs, repos,
  Mother queue and Bishop posture but publishes them *upstream* to Sendai and
  accepts actions routed back down;
- **reliability semantics** (per-topic `seq`, replay, heartbeats, bounded
  queues) that the current broadcast-and-hope IPC lacks and that a phone on
  cellular needs.

### Decisions recorded here

| # | Decision | Rationale |
|---|---|---|
| D1 | **Sendai runs the primary daemon.** Kobe runs a satellite. | Only always-on machine. Kobe sleeping is the root cause of "can't work commuting". |
| D2 | **WireGuard (UDM Pro) is the data plane.** No hub, no port-forward. | Already provisioned; iOS WireGuard app supports on-demand activation off the home SSID. Resolves B2 as "VPN-to-Mac"; Tailscale is not required. |
| D3 | **WebSocket, not raw TCP, for every network peer.** `ws://` inside the tunnel; TLS optional (`wss://`) for a later public endpoint. | Native on Apple platforms (`URLSessionWebSocketTask`, ping/pong, proxy-friendly), gives message framing for free, and lets a satellite *dial out*. Same JSON bodies as today, so the Swift decoders don't change. |
| D4 | **Device tokens stay even inside WireGuard.** | A WireGuard peer is a *network* identity; a device token is an *application* identity: it names the device for revocation, drives per-device sensitive-data scoping, and is what the push relay keys on. |
| D5 | **AWS hosts only the push relay**, serverless (Lambda function URL → APNs). Personal account by default. | The payload is `{title, job_id}`-shaped; detail is fetched over WireGuard on tap. Nothing Carefeed-sensitive leaves the tunnel. Revisit the account if payloads ever grow. |
| D6 | **Teri/Fred state is retained on Sendai** (default) but the satellite can withhold it (`publish_sensitive = false`). | Sendai is the operator's own machine and the link is WireGuard. The switch exists so the answer can change without a redesign. |
| D7 | **Session conversations do not ride the backplane.** | `persistent-bidirectional-session-host.md` chose Remote Control (Anthropic's relay). The backplane carries state, PTYs and actions only. |
| D8 | **Mother and Bishop are not modified.** | They stay host-local; the satellite's existing pollers are the bridge. Mother's broker is never exposed off-host. |

### What is deferred, and what reopens it

- **Kobe cannot run WireGuard** (MDM forbids VPN configurations, or the
  office network drops UDP 51820 — try UDP/443 on the UDM first): the
  satellite needs a public `wss://` endpoint. Two options, ordered by
  effort: a UDM port-forward to Sendai with a DDNS name and ACME cert, or
  the hosted payload-blind hub described in the previous design round
  (one Fargate task running a `nostromo-hub` binary). D3 keeps either a
  config change on the satellite side. Not built in this plan.
- **Coding while commuting.** Nothing runs on a closed Kobe. Personal repos
  get Mother + workers on Sendai (it is just a second satellite-less host
  once D1 lands). Carefeed repos go to Claude Code cloud sessions tracked
  over Remote Control; Mother dispatching to a cloud session instead of a
  local worktree is a Mother-side feature, out of scope here.

## Topology

```
                 ┌────────────────────────────────────────┐
                 │ Sendai — nostromd (primary)            │
                 │  retained state · seq/replay ring      │
                 │  devices.json · push intents → AWS     │
                 │  local sources: own PTYs, Mother (if   │
                 │  installed), activity tail             │
                 └───────────────┬────────────────────────┘
          ws://sendai.lan:47101  │   (all peers reach it over WireGuard
          ┌──────────────┬───────┼─────────────┬────────────────┐
          ▼              ▼       ▼             ▼                ▼
   Kobe nostromd     Kobe Mac  Kobe TUI     iPhone            iPad
   (satellite)       app       (unchanged,  (paired)         (paired)
   dials out;        (paired)  Unix socket
   Mother, Bishop,             to the local
   PTYs, repos                 satellite)
```

A satellite still binds its Unix socket, so the TUI and Mac app on Kobe keep
working with zero latency even if WireGuard is down; they just see only
Kobe-local state until the uplink returns. Every topic a satellite publishes
is tagged with its `host`, so a client can tell Kobe's Mother queue from
Sendai's.

## Target

- **Repo:** nostromo
- **Branch:** `claude/nostromo-websocket-backplane-p4g6y0`
- **Base:** `origin/main`

## Files to change

### Phase 1 — WebSocket transport, device auth, satellite uplink

- `Cargo.toml` — `tokio-tungstenite` is already a dependency (client side
  for `relay_client.rs`); add the `server` feature usage (no new crate).
  Add `sha2` (token hashing) if not already transitively present.
- `src/ipc/peer.rs` — add `Transport::Ws` and `PeerTrust::Paired`. The
  exhaustive matches in `classify_server_msg` / `network_policy` must be
  extended deliberately: `Paired` is `is_network() == true` and inherits the
  `Tcp` allow-list, **plus** the sensitive-tag gate is relaxed for a device
  whose registry record has `sensitive: true`. `Transport::Tcp` is kept for
  one release so the current iOS build still connects on the LAN, then
  removed.
- `src/ipc/ws.rs` (new) — `accept_loop_ws(listener, …)`: `TcpListener` →
  `tokio_tungstenite::accept_hdr_async`, reading `Authorization: Bearer`
  and `X-Nostromo-Device` from the upgrade request. On success, adapt the
  WS stream to the message-oriented interface `handle_client` needs. Text
  frames carry one JSON `ClientMsg`/`ServerMsg`; binary frames are reserved
  for PTY bytes (`PtyOutput`/`PtyInput` payloads). Frames over
  `MAX_FRAME_LEN` close the socket with code 1009.
- `src/ipc/server.rs` — split `handle_client` so the framing is pluggable:
  the existing length-prefixed path becomes `handle_client_framed` and the
  new one `handle_client_ws`, both delegating to the same
  `handle_client_msg` / outbound filter. `bind_ws(listener, devices, …)`
  alongside `bind_tcp`.
- `src/ipc/devices.rs` (new) — `~/.nostromo/devices.json`
  `{devices: [{id, label, token_hash, sensitive, created_at, last_seen_at,
  revoked_at}]}`; SHA-256 at rest; plaintext printed once by the CLI.
  `validate(token) -> Option<Device>` is read-on-connect; `revoke(id)` also
  closes live sockets via a `watch` the WS loop observes.
- `src/main.rs` — `nostromo device {add,list,revoke,pair}` subcommands.
  `pair` prints a QR (text) encoding `{host, port, code}` where `code` is a
  5-minute one-time pairing code that the phone exchanges for a device
  token over the same WS endpoint (`ClientMsg::Pair`). This is the minimum
  of `docs/prds/daemon-pairing-flow.md`; the PRD's UX is not changed here.
- `src/ipc/protocol.rs` — bump `PROTOCOL_VERSION` to 5; add
  `ClientMsg::Pair { code, label }`, `ServerMsg::Paired { device_id, token }`,
  `ServerMsg::Unauthorized`. Add an optional `host: Option<String>` to the
  retained-topic messages (`MotherJobs`, `MotherStatusline`, `Activity`,
  `PtyList`, `Focuses`); `None` means "the daemon you are talking to".
- `src/config.rs` — `ws_listen_addr()` (`NOSTROMD_WS_ADDR`, default
  `0.0.0.0:47101`), `mode = "primary" | "satellite"`,
  `uplink = { url, device_token_path, publish_sensitive }`. `tcp_listen_addr`
  default flips to `127.0.0.1:47100` (deprecation step for the raw listener).
- `src/bin/nostromd.rs` — bind the WS listener; in `satellite` mode also
  spawn `uplink::run` and skip mDNS advertising entirely (D2 makes
  discovery unnecessary, and it is the thing Kobe's MDM objects to).
- `src/ipc/uplink.rs` (new) — satellite side. Dials the primary with the
  device token (same reconnect/backoff shape as `data/relay_client.rs`),
  sends `Hello{role: satellite, host}`, then forwards every locally
  broadcast `ServerMsg` whose topic is in the publish set, tagged with
  `host`. Receives `ClientMsg`s the primary routes to this host
  (`MotherResume`, `MotherAction`, `PtyAttach`, `PtyInput`, …) and injects
  them into the local `handle_client_msg` path under `PeerTrust::Paired`.
- `src/ipc/router.rs` (new, primary side) — maps `host` → satellite
  connection; a client `ClientMsg` carrying `host: Some("kobe")` is
  forwarded to that uplink instead of handled locally. Unknown or offline
  host → `ServerMsg::HostUnavailable`.
- `Shared/NostromoKit/Sources/NostromoKit/Transport/WebSocketClient.swift`
  (new) — `URLSessionWebSocketTask` client implementing the same
  Hello/Welcome/Subscribe dance as `NetworkClient.swift`, token from
  Keychain, host from settings (default `sendai.lan`). `DaemonDiscovery`
  and the Bonjour entitlements become optional (kept for the LAN fallback
  while `Transport::Tcp` exists).
- `iOS/Nostromo/Views/ConnectionSettingsView.swift` — host, port, pair
  (scan or type code), "connected via WireGuard?" hint when the host is
  unreachable (the app cannot see the VPN state; it can only say what it
  tried).
- `macOS/Nostromo/...` — the Mac app on Kobe talks to the *local* satellite
  over the Unix socket as today; no change in phase 1.
- `README.md` — §Daemon: primary vs satellite, WireGuard assumption,
  pairing walkthrough. Mark the TCP listener deprecated.

### Phase 2 — reliability

- `src/ipc/seq.rs` (new) — per-topic monotonic `seq` stamped on every
  broadcast; a bounded replay ring per topic (default 1,000 messages or
  8 MiB, whichever first). `ClientMsg::Subscribe` gains
  `resume: BTreeMap<Topic, u64>`; on a resumable gap the daemon replays,
  otherwise it sends the retained snapshot and a `ServerMsg::Gap{topic}`.
- `src/ipc/ws.rs` — WS ping every 20 s, close after 60 s without pong;
  per-client bounded outbound queue (256 messages); on overflow drop
  non-retained messages and emit `Gap` rather than stall the broadcast
  channel (mirrors Mother broker's `gap` sub-event).
- `src/ipc/uplink.rs` — the satellite resumes with its own `seq` map so a
  WireGuard blip does not replay the world.
- Swift `WebSocketClient` — persist last `seq` per topic; resume on
  reconnect and on foreground.

### Phase 3 — push

- `src/push/intent.rs` (new) — primary emits `PushIntent{device_ids, title,
  subtitle, deep_link}` for `MotherAwaitDetected`, `DecisionRequest`,
  Perri review-requested, and POSTs it (outbound HTTPS, bearer) to the
  relay. Offline relay is logged and dropped; the phone catches up on
  next connect.
- `infra/push-relay/` (new) — Lambda (Rust or TypeScript, operator's
  call) with a function URL; validates the daemon bearer; forwards to APNs
  with token-based auth (`.p8`); maps `device_id` → APNs device token
  registered by the app via the same URL. CDK or a 60-line SAM template;
  personal AWS account (D5).
- iOS — register for remote notifications, post the APNs token to the
  relay on launch, deep-link into the Mother/Perri item on tap.

## Approach

1. **Prove the uplink before touching clients.** Build `ws.rs`, `devices.rs`
   and `uplink.rs`; run a primary and a satellite on one machine with two
   `NOSTROMO_HOME`s; assert that a `MotherJobs` broadcast from the satellite
   appears on the primary's Unix socket with `host: "kobe"`, and that a
   `MotherResume{host: "kobe"}` sent to the primary reaches the satellite's
   Mother. This is the integration test and the demo.
2. **Keep framing pluggable, not generic over `AsyncRead`.** The current
   `handle_client<S: AsyncRead + AsyncWrite>` assumes it owns framing.
   Rather than fight tungstenite's `Stream<Item = Message>` into that
   shape, lift the body into `handle_client_msg` (already exists) plus an
   outbound filter, and write two thin loops. The length-prefixed loop is
   unchanged for Unix.
3. **Trust is decided once, at upgrade.** `PeerTrust::Paired` is assigned
   only after a valid, unrevoked token; everything after that reuses the
   `peer.rs` allow-list machinery. No per-message token checks.
4. **Satellite is a role, not a fork.** The same binary and the same
   pollers; `mode` only decides whether the uplink task runs and whether
   mDNS is advertised. A primary with `uplink` unset is today's daemon.
5. **Host tagging is additive.** `host: None` keeps every existing decoder
   valid; the Mac app and TUI ignore the field until they grow a host
   selector.
6. **Deprecate, don't delete, the TCP listener** in phase 1 so the shipped
   iOS build keeps working on the home LAN during the transition; remove it
   with the phase-2 PR once the WS client has shipped.
7. **Test matrix.** Rust: `tests/ws_transport.rs` (auth accept/reject,
   oversize frame, revoke-closes-socket), `tests/uplink_roundtrip.rs`
   (step 1), `tests/seq_resume.rs` (phase 2). Swift: `NostromoKitTests`
   for the WS client decode path, reusing the existing fixture frames.

## Acceptance criteria

Phase 1:

- A `nostromd` in `satellite` mode binds **no** non-loopback listener and
  advertises nothing on mDNS. `lsof -i` on Kobe shows only outbound
  connections from the daemon.
- With WireGuard up, iPhone and iPad connect to Sendai's `ws://` endpoint
  using a paired token and see both Sendai's and Kobe's Mother queues,
  distinguished by `host`.
- `MotherResume`/`MotherAction` from the phone against a Kobe job executes
  on Kobe within one round-trip; the resulting state change arrives back on
  the phone without a poll.
- A revoked device's open socket closes within one second and its next
  connect receives `Unauthorized`.
- Teri/Fred frames reach a paired device only when its registry record has
  `sensitive: true`; the satellite publishes them only when
  `publish_sensitive = true`. Both default to the recorded decision (D6) and
  are tested in both positions.
- Kobe's Mac app and TUI behave exactly as before with WireGuard **down**
  (local-only state, no errors beyond an "uplink disconnected" chip).
- All existing IPC, peer-trust and session tests pass unmodified.

Phase 2:

- Killing WireGuard on the phone for 30 s and restoring it yields no
  duplicate and no missing `MotherJobs` message (asserted by `seq`).
- A client that stops reading for 10 s receives a `Gap` and the daemon's
  broadcast channel lag counter does not grow.

Phase 3:

- `MotherAwaitDetected` on Kobe produces an APNs notification on the phone
  within 10 s with no PR title or mail subject in the payload; tapping it
  opens the job.

## Out of scope

- Hosted hub / public endpoint (reopened only if Kobe cannot run WireGuard).
- End-to-end encryption above WireGuard.
- Moving Mother or Bishop into the daemon, or changing either repo.
- Carrying Claude session conversations (D7).
- Multi-tenant anything; one operator, one primary.
- The full pairing UX of `daemon-pairing-flow.md` (only the wire exchange
  and CLI are built here).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New transport, trust tier, and a two-daemon routing layer touching peer.rs's exhaustive matches. Mistakes leak sensitive data or strand the iOS client."
  redd:
    model: sonnet
    effort: high
    rationale: "Two-process integration tests (primary + satellite), auth rejection paths, seq/resume edge cases."
  marty:
    model: sonnet
    effort: medium
    rationale: "handle_client split and the host-tag plumbing will want a tidy pass; bounded scope."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First authenticated network surface and first cross-host action routing. Review for token handling, revocation races, and sensitive-tag bypasses."
```
