# W10 — Satellite mode: a nostromd that publishes upstream and accepts routed actions

## Context

After W9 (`docs/plans/backplane/W9-ws-transport.md`) `nostromd` has an
authenticated WebSocket listener and a `PeerTrust::Paired` tier. The
operator's topology (`docs/plans/backplane-sequencing.md`, bet B7) has one
**primary** daemon on an always-on host (Tokyo) and **satellites** on the
Macs that actually own PTYs, repositories, Mother queues and Bishop posture
— in particular Kobe, a managed laptop that may only ever *dial out* and
must not be discoverable.

Today `nostromd` is a single role: it binds listeners, tails
`~/.claude/activity.jsonl` (`src/bin/nostromd.rs:325-362`), polls
`mother list --format json` every 2 s (`src/bin/nostromd.rs:384-390`,
`src/mother/mod.rs:228-240`), and broadcasts the results to local
subscribers through `Server`'s `broadcast::Sender<ServerMsg>`
(`src/ipc/server.rs:80-115`). The retained-frame cache
(`src/ipc/server.rs:54,107-109,1351`) replays the latest frame per key to a
newly subscribed client.

This wedge adds `mode = "satellite"`: the daemon keeps every local
behaviour, **binds nothing off-loopback and advertises nothing on mDNS**,
dials the primary as a `Paired` client, forwards its locally broadcast
frames upstream tagged with its host name, and accepts `ClientMsg`s the
primary routes back to it. The primary learns to tag, merge and route by
`host`. The result is that Kobe's Mother jobs, Bishop posture, activity and
PTYs are visible and actionable from any device that can reach the primary,
while Kobe's own TUI/Mac app keep working over the Unix socket with the
VPN down. Mother and Bishop are not modified.

It also carries **device administration upward** for Ada's pairing PRD
(`docs/prds/daemon-pairing-flow.md`, cited as PRD-ACn). The operator pairs,
lists, revokes and re-scopes phones and iPads from the Mac app on Sendai or
Kobe (PRD-AC11–13, AC18, AC23–25, AC35), and both are satellites. W9 put the
device registry and every pairing on the primary, and made the admin verbs
work for local Unix clients there. This wedge lets a satellite forward those
verbs from **its own local clients** up its existing outbound uplink, and
relay the answers back. Nothing ever connects *toward* the satellite, so this
works from Kobe (PRD-AC12, AC24). How much a satellite may do is held on the
**primary**, in the satellite's own registry record (`admin: full |
read_only | off`, from W9). A satellite's local config can narrow it but
never widen it. That keeps the decision about a managed laptop (the PRD's
open question 2) on the operator's own host.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-satellite-uplink`
- **Base:** `origin/main` (W9 merged)

## Files to change

- `src/config.rs:51-60, 160-226` — add
  `mode: DaemonMode` (`Primary` default | `Satellite`), `host_name:
  Option<String>` (default: `gethostname()` lower-cased, first label),
  and an `uplink: Option<UplinkConfig>` table: `{ url: String,
  token_path: PathBuf (default ~/.nostromo/uplink-token, mode 0600),
  publish_sensitive: bool (default true), publish_topics:
  Option<Vec<Topic>> (default: all), device_admin: DeviceAdmin (`full`
  default, `read_only` or `off`; a local *narrowing* of what the primary
  grants) }`. Env overrides `NOSTROMD_MODE`,
  `NOSTROMD_UPLINK_URL`. Validation: `Satellite` requires `uplink`.
- `src/ipc/protocol.rs` — add `host: Option<String>` with
  `#[serde(default, skip_serializing_if = "Option::is_none")]` to the
  retained/stateful variants: `ServerMsg::MotherJobs` (`:1222`),
  `MotherStatusline`, `MotherAwaitDetected`, `Activity` (inside
  `ActivityEvent`, `src/agent_bus.rs`), `PtyList`/`PtyInfo` (`:117`),
  `Focuses`. Add `host: Option<String>` to the action-bearing
  `ClientMsg`s: `MotherResume` (`:1074`), `MotherAction`, `PtyAttach`,
  `PtyInput`, `PtyResize`, `PtyKill`, `PtyDetach`, `PtySpawn`,
  `SessionSpawn` and its siblings. Add `ClientMsg::Hello.role:
  Option<HelloRole>` (`Client` default | `Satellite { host }`), and
  `ServerMsg::Hosts { hosts: Vec<HostInfo> }` (`{name, connected_since,
  last_seen}`) plus `ServerMsg::HostUnavailable { host }`. Add `"hosts"`
  to `Welcome.features`. W9's admin frames (`DevicePairing`,
  `DevicePairOutcome`, `DeviceRevoked`, `DeviceAdminError`) gain an
  optional `origin: Option<String>` (`#[serde(default,
  skip_serializing_if)]`). A satellite stamps it with the local connection
  key that asked, and the primary echoes it, so the satellite can deliver
  the answer to that one local client. Add `DeviceAdminError` reasons
  `server_unreachable` and `not_permitted_on_this_mac`.
- `src/ipc/uplink.rs` (new, satellite side) — `spawn(config, server:
  &Server)`: reconnect loop with the backoff shape of
  `src/data/relay_client.rs:198-237` (1 s → 60 s cap), `Authorization:
  Bearer` from `token_path`, `Hello { role: Satellite { host } }`,
  `Subscribe { topics: [] }` is **not** sent (a satellite publishes, it
  does not subscribe). Forward: subscribe to `server.broadcast` and
  `server.retained`, apply `peer::outbound(PeerTrust::Paired { sensitive:
  publish_sensitive }, msg, tags)` so withholding uses the same gate as any
  network peer, stamp `host`, send. On (re)connect, replay the retained
  cache first so the primary has a full picture. Inbound: every
  `ClientMsg` received from the primary is injected into the local
  `handle_client_msg` under `PeerTrust::Paired { sensitive: publish_sensitive }`
  with a synthetic `conn_key` `uplink:<primary-conn-id>`; targeted replies
  go back up the same socket. **Device-admin relay (upward):** a W9 admin
  verb from a *local, non-network* client of the satellite is stamped with
  `origin = <that conn_key>` and sent up the uplink. It is never executed
  locally (the satellite has no `devices.json` authority) and never accepted
  from a network peer or from a primary-injected message, so it cannot loop.
  If the uplink is down, the satellite answers at once with
  `DeviceAdminError { server_unreachable }` (PRD-AC18). If the local
  `device_admin` narrowing forbids the verb, it answers
  `not_permitted_on_this_mac`. Frames that come down with an `origin` go
  only to that local connection. When that local connection closes, the
  satellite sends `DevicePairCancel` for any pairing it started. When the
  uplink drops, every relayed pairing's local client gets
  `DevicePairOutcome::connection_lost`. The satellite subscribes upstream to
  `Topic::Devices` only (it still subscribes to nothing else), retains the
  latest `Devices` frame, and republishes it to its local clients, so the
  Mac's Devices list is live (PRD-AC23, AC25).
- `src/main.rs` (W9's `Subcommand`) — add `nostromo uplink pair --url
  ws://<primary>:47101 <code>`. It dials the primary without a token and
  sends `Pair { code, name: <host_name>, kind: satellite }` against a code
  issued on the primary by `nostromo device pair --satellite <host>`. It
  writes the returned token to `uplink.token_path` (0600), creating the
  parent directory, and prints only `Enrolled <host> with <primary>`. The
  token is never printed. `nostromo device …` run on a satellite goes
  through the same relay as the Mac app.
- `src/ipc/router.rs` (new, primary side) — `HostTable`: `host → (conn
  sender, HostInfo)`. Registered when a `Hello { role: Satellite }` is
  accepted on the WS listener (W9's `ws.rs`), removed on disconnect; both
  broadcast `Hosts`. `route(msg: ClientMsg) -> Routed { Local | Remote(host) |
  Unavailable }` by the message's `host` field (`None` = local).
- `src/ipc/server.rs:661` — `handle_client_msg` consults the router first
  when `msg.host().is_some()`; `Remote` forwards and returns, `Unavailable`
  replies `HostUnavailable`. The retained cache key gains the host:
  `retain_broadcasts` (`:1351`) keys `MotherJobs` etc. by `(variant, host)`
  so one host's snapshot never overwrites another's. **Satellite admin
  authorisation (primary side):** a W9 admin verb arriving on a satellite's
  uplink connection is executed only if that satellite's registry record
  has `admin: full`. With `read_only`, only `DeviceList` is executed and the
  rest get `DeviceAdminError { not_permitted_on_this_mac }`. With `off`,
  everything gets that error. `DevicePairStart { satellite: Some(_) }`
  (satellite enrolment) is always refused over an uplink. Pairings started
  this way are owned by `(uplink connection, origin)` and are cancelled
  when the uplink drops. `Devices` broadcasts go to satellite connections
  whose record allows at least `read_only`.
- `src/ipc/ws.rs` (W9) — recognise `Hello.role == Satellite` and hand the
  connection to the router instead of the subscriber loop; a satellite's
  frames are *published* into the primary's broadcast channel (through
  `peer::outbound` again — a satellite is still a network peer). A
  satellite's token is a W9 registry record of `kind: satellite`. It never
  appears in the phone/iPad device list.
- `src/bin/nostromd.rs:117-160` — in `Satellite` mode: force
  `tcp_listen_addr`/`ws_listen_addr` to loopback (log if the config asked
  otherwise), **skip `mdns::advertise`** (`:150`), and call
  `uplink::spawn`. In `Primary` mode: construct the `HostTable` and pass it
  to the WS listener.
- `src/mother/mod.rs:166` — no change to `MotherJob`; the host travels on
  the envelope, not the job.
- `tests/uplink_roundtrip.rs` (new) — two in-process `Server`s in one tokio
  runtime (primary on `127.0.0.1:0` WS + tempdir Unix; satellite with its
  own tempdirs and `mode = satellite`). Drive the satellite's broadcast
  channel directly (no real Mother).
- `README.md` §Daemon — primary vs satellite, `config.toml` example for
  Kobe, the "VPN down" behaviour, and the operator note that a satellite on
  a managed laptop should use a **split-tunnel** WireGuard profile
  (`AllowedIPs` = home subnet) with `uplink.url` pointing at the primary's
  WireGuard/LAN address, so corporate traffic stays on its own VPN.

## Approach

1. **Additive wire fields.** Land `host`/`role`/`Hosts` in `protocol.rs` with
   defaults so every existing decoder (Rust tests, `NostromoKit/Wire/*.swift`
   via `MotherWireTests` fixtures) keeps passing. Run `cargo test` and
   `swift test` in `Shared/NostromoKit` before touching behaviour.
2. **Router on the primary.** Implement `router.rs` and the
   `handle_client_msg` hook; unit-test `route()` and the per-host retained
   keys with no sockets.
3. **Uplink on the satellite.** Implement `uplink.rs` as a pure function of
   the `Server`'s channels; it must be startable in a test without the
   pollers.
4. **Mode wiring in `nostromd.rs`.** Satellite: loopback-only listeners, no
   mDNS, uplink task. Primary: host table. A primary with no `uplink` is
   byte-for-byte today's daemon.
5. **Round trip test.** Satellite broadcasts `MotherJobs{jobs:[j1]}` →
   primary's Unix-socket subscriber receives it with `host: Some("sat")`;
   subscriber sends `MotherResume{host: Some("sat"), ..}` → the satellite's
   `handle_client_msg` is invoked with it (assert via a stubbed
   `SessionManager`/Mother hook or by observing the satellite's broadcast of
   the resulting refusal/ack); `MotherResume{host: Some("nope")}` →
   `HostUnavailable`. Disconnect the satellite → primary broadcasts `Hosts`
   without it; reconnect → retained `MotherJobs` for `sat` reappears.
6. **Device-admin relay.** With the two-server harness (primary record for
   `sat` set to `admin: full`): a Unix client on the satellite sends
   `DevicePairStart` and gets `DevicePairing` with the **primary's**
   `server_url`. A WS device redeems the code against the primary, and the
   satellite's Unix client receives `DevicePairOutcome::paired` within 2 s.
   A second Unix client on the satellite does not see that outcome. Then:
   `DeviceRevoke` and `DeviceSetScope` from the satellite take effect on the
   primary; with the record at `read_only`, `DeviceList` works and
   `DeviceRevoke` gets `not_permitted_on_this_mac`; with the uplink down,
   `DevicePairStart` gets `server_unreachable` at once; closing the
   satellite's Unix client cancels its pairing on the primary (a later
   redeem gets `invalid`); and `Devices` updates reach the satellite's Unix
   client.
7. **Sensitive gate.** With `publish_sensitive = false`, assert a `TeriState`
   broadcast on the satellite never reaches the primary; with `true`, it
   does and the primary re-applies `may_receive` per downstream peer.

## Acceptance criteria

- `cargo test` and `cd Shared/NostromoKit && swift test` pass; no existing
  test is modified except to add fixtures with `host` present.
- In `satellite` mode, `lsof -iTCP -sTCP:LISTEN -p <pid>` shows only
  loopback listeners and no `_nostromo._tcp` service is registered
  (`dns-sd -B _nostromo._tcp` returns nothing from this host).
- A satellite's `MotherJobs`, `MotherStatusline`, `Activity`, `PtyList` and
  `Focuses` arrive at the primary's subscribers with `host` set; the
  primary's own carry `host: None`.
- `MotherResume`/`MotherAction`/`Pty*`/`Session*` with `host: Some(h)` are
  executed on satellite `h` and the resulting state change is broadcast back
  within one round-trip; unknown or disconnected `h` → `HostUnavailable`.
- Retained frames are keyed per host: two satellites' `MotherJobs` coexist
  and a reconnecting client receives both.
- `publish_sensitive = false` withholds exactly the frames
  `peer::may_receive(PeerTrust::Tcp, …)` would withhold; `true` sends them,
  and the primary still withholds them from `Paired { sensitive: false }`
  clients.
- With the uplink unreachable, the satellite's Unix-socket clients see no
  behaviour change other than a `Hosts`-style status frame indicating
  `uplink: disconnected`; reconnect uses exponential backoff capped at 60 s.
- A W9 device-admin verb sent by a local client of a satellite is executed
  on the primary and answered to that client alone, with no connection
  initiated toward the satellite. Pair outcomes arrive within 2 s of
  redemption (PRD-AC12, AC13 transport; W15 renders them).
- The primary enforces the satellite's registry `admin` capability. A
  satellite's local config can only narrow it. Satellite enrolment is never
  accepted over an uplink.
- Admin verbs from a satellite's network peers, or from primary-injected
  messages, are never forwarded upward.
- Uplink down → `DeviceAdminError { server_unreachable }` within 100 ms,
  and every relayed open pairing reports `connection_lost` to its client.
- `nostromo uplink pair` writes the token file with mode 0600 and never
  prints the token.
- No clippy warnings. PR body references the sequencing memo (W10).

## Out of scope

- Any Swift/iOS/Mac-app change — including showing `host` (W11) and the
  Mac Pair/Devices UI (W15).
- Executing device admin on a satellite. The registry exists only on the
  primary.
- `seq`/resume/replay-on-reconnect beyond retained-cache replay (W12).
- Carrying PTY bytes as binary frames (they travel as today's base64 JSON).
- Changes to Mother or Bishop; the satellite shells out to `mother` exactly
  as today.
- A public/hub endpoint for a satellite that cannot run WireGuard (the
  sequencing memo's risk section).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Two-daemon routing, per-host retained keys and an injected-command path under network trust; subtle and cross-cutting."
  redd:
    model: sonnet
    effort: high
    rationale: "The round-trip test runs two servers in one runtime and must assert routing, retention and sensitive gating in both directions."
  marty:
    model: sonnet
    effort: medium
    rationale: "Host plumbing will touch many variants; a pass to centralise host()/with_host() accessors is expected."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "Commands injected from the network into a satellite, plus device admin relayed up from a managed laptop; both trust boundaries must be airtight."
```
