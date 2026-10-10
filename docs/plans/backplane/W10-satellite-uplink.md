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

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-satellite-uplink`
- **Base:** `origin/main` (W9 merged)

## Files to change

- `src/config.rs:51-60, 160-226` — add
  `mode: DaemonMode` (`Primary` default | `Satellite`), `host_name:
  Option<String>` (default: `gethostname()` lower-cased, first label),
  and an `uplink: Option<UplinkConfig>` table: `{ url: String,
  token_path: PathBuf (default ~/.nostromo/uplink-token),
  publish_sensitive: bool (default true), publish_topics:
  Option<Vec<Topic>> (default: all) }`. Env overrides `NOSTROMD_MODE`,
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
  to `Welcome.features`.
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
  go back up the same socket.
- `src/ipc/router.rs` (new, primary side) — `HostTable`: `host → (conn
  sender, HostInfo)`. Registered when a `Hello { role: Satellite }` is
  accepted on the WS listener (W9's `ws.rs`), removed on disconnect; both
  broadcast `Hosts`. `route(msg: ClientMsg) -> Routed { Local | Remote(host) |
  Unavailable }` by the message's `host` field (`None` = local).
- `src/ipc/server.rs:661` — `handle_client_msg` consults the router first
  when `msg.host().is_some()`; `Remote` forwards and returns, `Unavailable`
  replies `HostUnavailable`. The retained cache key gains the host:
  `retain_broadcasts` (`:1351`) keys `MotherJobs` etc. by `(variant, host)`
  so one host's snapshot never overwrites another's.
- `src/ipc/ws.rs` (W9) — recognise `Hello.role == Satellite` and hand the
  connection to the router instead of the subscriber loop; a satellite's
  frames are *published* into the primary's broadcast channel (through
  `peer::outbound` again — a satellite is still a network peer).
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
6. **Sensitive gate.** With `publish_sensitive = false`, assert a `TeriState`
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
- No clippy warnings. PR body references the sequencing memo (W10).

## Out of scope

- Any Swift/iOS/Mac-app change — including showing `host` (W11).
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
    rationale: "Commands injected from the network into a satellite's local action path; the trust boundary must be airtight."
```
