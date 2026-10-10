# W9 — Add an authenticated WebSocket transport and device pairing to nostromd

## Context

`nostromd` serves the Mac app over a Unix socket and iOS over a raw,
**unauthenticated** TCP listener (`src/bin/nostromd.rs:117-147`, found by
Bonjour via `src/mdns.rs`; `DEFAULT_TCP_ADDR` is already loopback,
`src/config.rs:46`). Both run the same `handle_client` loop
(`src/ipc/server.rs:254-630`), which owns the length-prefixed framing in
`src/ipc/codec.rs`. Trust comes from the transport alone:
`PeerTrust::from_transport` (`src/ipc/peer.rs:53-58`) maps `Transport::Tcp`
to the least-trusted tier, and `peer.rs` withholds every Teri/Fred-derived
frame from it.

This wedge adds a third transport, **WebSocket**. It carries the same
`ClientMsg`/`ServerMsg` JSON, one message per text frame. It authenticates
each connection with a per-device bearer token at the HTTP upgrade and
admits it under a new `PeerTrust::Paired` tier. It is the foundation for
every off-host client in `docs/plans/backplane-sequencing.md` (bets B2, B8).
The primary daemon runs on an always-on host reached over the operator's
WireGuard VPN. A managed laptop that may only *dial out* connects to it as a
satellite (W10). Device tokens are required even inside the VPN: the token is
the device's application identity (revocation, per-device mail-and-todos
scope, the push relay's key), while WireGuard is only a network identity.

It also builds the **daemon side of device pairing and device management**
specified by Ada's PRD `docs/prds/daemon-pairing-flow.md` (answers Q1). The
PRD's acceptance criteria are cited below as **PRD-ACn**. Its design-loop
notes (appended to that file) record the agreed interpretations. In short,
the primary daemon owns the device registry and every pairing. A pairing is
started by a *local* client (the `nostromo device pair` command, or, through
W10's uplink, a satellite Mac's app per W15). It lives in the daemon's
memory, is owned by the connection that started it, and is reported back to
that connection when it is redeemed, expires, is cancelled or is locked out.
Devices redeem codes over the WebSocket listener without a token.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ws-transport`
- **Base:** `origin/main`

## Files to change

- `Cargo.toml:96` — `tokio-tungstenite = { version = "0.24", features =
  ["rustls-tls-native-roots"] }` is already present (a client in
  `src/data/relay_client.rs`). Server-side `accept_hdr_async` needs no new
  feature. Add `sha2 = "0.10"` and `rand = "0.8"` unless already direct
  dependencies (check `cargo tree -i sha2`). Add `qrcode = "0.14"` with
  `default-features = false` for the terminal QR.
- `src/ipc/peer.rs:31-66` — add `Transport::Ws` and
  `PeerTrust::Paired { sensitive: bool }`. `is_network()` returns `true` for
  `Paired`. Every exhaustive match that names `PeerTrust::Tcp` gains a
  deliberate `Paired` arm; the default is "same as `Tcp`".
  - `may_receive`/`outbound` (`:709-730`): a `Paired { sensitive: true }`
    peer passes the `ServerClass::Sensitive` gate and the sensitive-tag gates
    for Teri/Fred **state** frames (`TeriState`, `FredState`,
    `WorkSourceStatus`, `WorkSnapshot`, `TeriPicks`). Everything else treats
    `Paired` exactly like `Tcp`.
  - `classify_server_msg` (`:613-677`): the new device-admin frames
    (below) get a new class, `ServerClass::LocalOnly`. It is delivered to a
    non-network peer and to a satellite link (W10), and never to a `Tcp` or
    device `Paired` peer.
  - `network_policy` (`:775-813`) and `targets_sensitive_session`
    (`:826-866`) classify every new `ClientMsg`: `PairCheck`/`Pair` are
    allowed **only** on a pairing-only socket (enforced in `ws.rs`, not here);
    `DeviceUnpairSelf` is `Allowed` for an authenticated device; every
    `Device*` admin verb is `Refused` for every network peer (W10 adds the
    one satellite exception).
  - `withheld_msg` (`:935-941`) takes a reason. Today's
    `requires_secure_connection` stays for `Tcp`. A `Paired { sensitive:
    false }` peer gets reason `device_scope`, so the client can say *why*
    (PRD-AC34).
- `src/ipc/devices.rs` (new) — `DeviceRegistry` over
  `~/.nostromo/devices.json` (`NOSTROMO_DEVICES_PATH` override, mode 0600,
  atomic write: `.tmp` then rename). Per device: `id`, `name`, `kind`
  (`iphone | ipad | satellite`), `token_hash` (SHA-256 of 32 random bytes,
  base64url), `sensitive`, `admin` (satellites only: `full | read_only |
  off`), `paired_at`, `last_seen_at`, `revoked_at`, `revoked_by`
  (`operator | device`). A `server_id` (random, minted on first load) is
  stored once at the top level. Revoked records are kept (PRD-AC23, AC30).
  Operations: validate a token; redeem a pairing (name dedup, see Approach
  4); revoke by id; set `sensitive`; set a satellite's `admin`; touch
  last-seen. The token's plaintext exists only in the `Paired` reply. The
  registry publishes a `tokio::sync::watch` **registry epoch** that bumps
  on every revoke, scope change and admin change, so live connections
  re-check their own record.
- `src/ipc/pairing.rs` (new) — the in-memory `PairingTable` on the primary.
  Each open pairing holds the code hash, an optional name hint, `sensitive`,
  `kind` (`device | satellite`), `expires_at` (5 min), the issuing
  connection's key (and, for one relayed by W10, the satellite's origin
  key) and a sender for its outcome. Outcomes are `paired { name, kind,
  sensitive }`, `expired`, `cancelled`, `locked_out` and
  `connection_lost`. Wrong-attempt accounting is described in Approach 5.
  Expired code hashes are kept as tombstones for 1 hour so a late attempt
  gets `expired` rather than `invalid`. Cancelled, used and locked-out
  codes leave no tombstone, so they answer `invalid` (PRD failure table:
  "wrong (or already used)").
- `src/ipc/ws.rs` (new) — `accept_loop_ws`. For each `TcpStream`, run
  `tokio_tungstenite::accept_hdr_async` with a callback that reads
  `Authorization: Bearer <token>` (never a query string). There are three
  admission outcomes. **Paired** (valid, unrevoked token): run
  `handle_client_ws` under `Paired { sensitive }` with the device id.
  **Pairing-only** (no header): the socket may send `Hello`, any number of
  `PairCheck`, then one `Pair`; it is closed after the `Pair` reply or 60 s,
  and any other message gets `Unauthorized { reason: "not_paired" }` and
  close. **Rejected** (header present but the token is unknown or revoked):
  complete the upgrade, send `Unauthorized { reason: "revoked" | "unknown"
  }`, and close with code **4001**. This is deliberate. A device must be
  able to tell "this server refuses me" apart from "I can't reach the
  server" (PRD-AC22, AC26, AC32), and an app-level frame plus close code is
  unambiguous where an HTTP 401 from an intermediary is not. Text frames
  carry one JSON message. Binary frames close with 1003. A text frame over
  `MAX_FRAME_LEN` (`src/ipc/protocol.rs:45`) closes with 1009.
  Unauthenticated upgrades are rate-limited per source IP: 20 per minute,
  then refused at upgrade with HTTP 429.
- `src/ipc/server.rs:254-630` — split `handle_client` into a framing layer
  and a body. Unix and TCP keep today's behaviour byte-for-byte
  (`handle_client_framed`). `handle_client_ws` takes a
  `WebSocketStream<TcpStream>`. Both call `handle_client_msg` (`:661`) and
  the `peer::outbound` filter. The body's `trust` becomes mutable for WS
  peers. Then:
  - **Retained replay** (`:481-488` and the re-subscribe path `:571-582`):
    today a network peer gets no retained frame and one `Withheld`. Change
    it so a network peer is replayed every retained frame that passes
    `outbound(trust, …)`, and gets a `Withheld` only for topics its trust
    actually withholds. `Tcp` behaviour is unchanged (it is withheld
    everything retained today, and still is).
  - **Registry epoch** in the WS `select!`: on change, re-read this
    connection's device record. If revoked: send `Unauthorized { reason:
    "revoked" }`, close 4001 (under 1 s). If `sensitive` changed to false:
    set `trust`, send `Withheld { topics: [fred, teri, work], reason:
    "device_scope" }`. If it changed to true: set `trust` and replay the
    retained frames that now pass (PRD-AC35). Other connections are
    untouched (PRD-AC28).
  - Add `Server::bind_ws(listener, devices, pairing, …)` mirroring
    `bind_tcp` (`:148-163`).
  - **On disconnect** of any connection, cancel the pairings it owns
    (outcome `connection_lost`). A pairing never outlives the window or
    command that shows its code.
  - **Device-admin dispatch** in `handle_client_msg`, for non-network peers
    only (W10 adds satellites): `DevicePairStart`, `DevicePairUpdate`,
    `DevicePairCancel`, `DeviceList`, `DeviceRevoke`, `DeviceSetScope`. Plus
    `DeviceUnpairSelf` for an authenticated device, which revokes only the
    connection's own device id (`revoked_by: device`), replies
    `DeviceUnpaired`, then closes 4001 (PRD-AC31).
  - **Device-list broadcasts**: on every registry change and on every device
    connect/disconnect, broadcast `Devices { devices }` (class `LocalOnly`,
    topic `devices`).
- `src/ipc/protocol.rs:26` — bump `PROTOCOL_VERSION` to 5
  (`MIN_CLIENT_VERSION` stays 2). Add `Topic::Devices`. Messages:
  - Client → daemon, device side: `PairCheck { code }`;
    `Pair { code, name, kind }`; `DeviceUnpairSelf`.
  - Daemon → device: `PairOffer { name_hint: Option<String>, sensitive,
    server_id }`; `Paired { device_id, token, name, sensitive, server_id }`;
    `PairRefused { reason: expired | invalid }`;
    `Unauthorized { reason }`; `DeviceUnpaired`.
  - Client → daemon, admin side (each carries a client-minted `request_id`):
    `DevicePairStart { name_hint, sensitive, satellite: Option<String> }`;
    `DevicePairUpdate { pairing_id, sensitive }`;
    `DevicePairCancel { pairing_id }`; `DeviceList`;
    `DeviceRevoke { device }` (id, or exact name of an *active* device);
    `DeviceSetScope { device, sensitive }`.
  - Daemon → admin client: `DevicePairing { request_id, pairing_id, code,
    server_url, expires_at, sensitive }`; `DevicePairOutcome { pairing_id,
    outcome }`; `Devices { devices: Vec<DeviceSummary> }`;
    `DeviceRevoked { request_id, device_id, was_connected }`;
    `DeviceAdminError { request_id, reason }`. `DeviceSummary` has `id,
    name, kind, paired_at, last_seen_at, connected, sensitive, revoked_at`
    and **never** a token or hash. Satellites are excluded from the
    phone/iPad list and reported in a separate `hosts` array.
  - Add `"ws"`, `"pair"` and `"devices"` to `Welcome.features`
    (`:1208-1219`).
  - The QR/URL payload is `nostromo://pair?v=1&host=<h>&port=<p>&code=<c>`.
    Name and scope are *not* in it; the device learns them from `PairOffer`.
- `src/config.rs:51-60, 215-226` — add `ws_addr: Option<SocketAddr>` and
  `ws_listen_addr()` (`NOSTROMD_WS_ADDR` → `config.toml ws_addr` → default
  `0.0.0.0:47101`; `off` disables). Also add `pair_host: Option<String>`:
  the address devices are told to use. The default is the bound WS address
  if it is specific; otherwise the first non-loopback, non-link-local IPv4
  of the host. Log the chosen value at INFO.
- `src/bin/nostromd.rs:117-160` — construct the `DeviceRegistry` and
  `PairingTable`, bind the WS listener next to the TCP one, and log its
  address. Keep mDNS for the TCP port (W10 turns it off in satellite mode).
- `src/main.rs:39-58` — the binary has a flat `Args` struct. Add an
  optional clap `Subcommand`, `Device`, so `nostromo` with no subcommand
  still opens the TUI unchanged. Every subcommand talks to the **local**
  daemon over the Unix socket with `DaemonClient` (`src/ipc/client.rs:79-160`).
  On the primary that daemon does the work itself; on a satellite W10
  relays it. Subcommands:
  - `device pair [NAME] [--no-mail-and-todos]` — prints the server URL, the
    code as `NNN NNN`, a text QR, a live countdown on one updating line,
    and the scope ("Will see mail and todos" / "Won't see mail and
    todos"). It **stays running** until the outcome. Paired:
    `Paired: <final name>. Includes mail and todos.` (or `Mail and todos
    are off.`), exit 0. Expired: `Code expired. Run the command again for a
    new one.`, exit 1. Locked out: `Too many wrong attempts. This code is no
    longer valid. Run the command again for a new one.`, exit 1. Ctrl-C sends
    `DevicePairCancel`, prints `Cancelled. The code no longer works.`, exit
    130. Lost connection to the server: say so, exit 1 (PRD-AC14, AC17).
  - `device pair --satellite <host> [--admin full|read-only|off]` — primary
    only (refused when relayed). Issues a satellite enrolment code for W10's
    `nostromo uplink pair`. This replaces the earlier `device add`, which
    printed a token (PRD-AC37 forbids that).
  - `device list [--all]` — columns: NAME, KIND, PAIRED, LAST SEEN
    (`Connected now` or `2 h ago`), MAIL & TODOS (`on`/`off`). Then a
    `Revoked` group with revoke times. `--all` adds the satellites
    (PRD-AC23).
  - `device revoke <name-or-id>` — prints `Revoked <name>. Disconnected
    just now.` or `Revoked <name>. Wasn't connected; it will be refused the
    next time it tries.` (PRD-AC25, AC26, AC29).
  - `device mail-and-todos <name-or-id> on|off` (PRD-AC35).
  - `device admin <host> full|read-only|off` — primary only; changes a
    satellite's device-admin capability (used by W10/W15).
- `tests/ipc_ws_transport.rs` (new) — mirrors `tests/ipc_tcp_transport.rs`.
  Bind on `127.0.0.1:0`, a tempdir Unix socket and a tempdir
  `NOSTROMO_DEVICES_PATH`, and connect with
  `tokio_tungstenite::connect_async`.
- `tests/device_pairing.rs` (new) — pairing lifecycle driven from a Unix
  admin client plus WS device sockets; see Approach 8.
- `tests/ipc_peer_gating.rs` — add `Paired { sensitive: false }` (behaves
  like `Tcp`, `Withheld` reason `device_scope`) and `Paired { sensitive:
  true }` (receives `TeriState`/`FredState`) cases.
- `README.md:88-160` — §Daemon: WebSocket endpoint, `pair_host`, the
  `nostromo device` commands, a pairing walkthrough. Mark the raw TCP
  listener deprecated.

## Approach

1. **Trust tier first.** Add `Transport::Ws`/`PeerTrust::Paired` and the
   `LocalOnly` class, then let the compiler walk you through every
   exhaustive match in `peer.rs`. Decide each arm deliberately.
2. **Registry** (`devices.rs`), with in-module unit tests: redeem →
   validate round trip; revoke → validate fails; atomic save survives a
   leftover `.tmp`; revoked records kept; `server_id` stable across loads.
   Persist `last_seen_at` on connect and disconnect, and at most once a
   minute while connected. Live "Connected now" comes from the connection
   table, not the file.
3. **Pairing table** (`pairing.rs`) as a pure state machine over an
   injectable clock. Unit-test TTL, single use, cancel, tombstones and
   lockout without sockets.
4. **Name dedup** (PRD-AC9). The redeeming device proposes `name`. If an
   *active* device already has that name (case-insensitive), the registry
   appends ` 2`, ` 3`, … to the first free suffix. The final name goes back
   in `Paired` and in the issuer's `DevicePairOutcome`. Revoked names do not
   block reuse.
5. **Wrong-attempt lockout** (PRD-AC17). A wrong code (a `PairCheck` or
   `Pair` that matches no open pairing and no tombstone) cannot be pinned on
   one pairing. So it counts against **every pairing open at that moment**.
   When a pairing's count reaches 5, it is removed (no tombstone) and its
   issuer gets `locked_out`. In the normal case one pairing is open, so this
   is exactly the PRD's rule. A correct `PairCheck` does not use the code.
   The successful `Pair` does, and it resets nothing else.
6. **Split `handle_client`.** Parameterise the handshake and loop body by a
   send/receive pair instead of `read_frame`/`write_frame`. The Unix/TCP
   path must produce byte-identical frames: `tests/ipc_codec.rs` and
   `tests/ipc_tcp_transport.rs` are the regression guard.
7. **Upgrade-time auth and the pairing-only socket** in `ws.rs`, as
   specified under Files. An unreachable attempt never reaches the daemon,
   so it never uses up a code (PRD-AC21).
8. **Tests.** In `tests/ipc_ws_transport.rs`:
   (a) valid token → `Welcome` with `"ws"`, subscribe, receive a broadcast;
   (b) bad or unknown token → `Unauthorized` + close 4001;
   (c) oversize frame → 1009; binary frame → 1003;
   (d) a `Paired { sensitive: false }` peer never receives `TeriState`, and
   its subscribe yields `Withheld { reason: "device_scope" }`;
   (e) a `sensitive: true` peer is replayed the retained `TeriState` on
   subscribe.
   In `tests/device_pairing.rs`:
   (f) an admin client sends `DevicePairStart`, a device sends `PairCheck`
   then `Pair` → device gets `Paired`, the admin gets `DevicePairOutcome::
   paired` within 2 s;
   (g) a second device paired under the same name gets `<name> 2`;
   (h) expiry → `expired` outcome; a later attempt with that code gets
   `PairRefused { expired }`;
   (i) cancel, and separately dropping the admin connection → a later
   attempt gets `invalid`;
   (j) five wrong codes → `locked_out`, then the correct code → `invalid`;
   (k) `DeviceRevoke` on a connected device closes it with 4001 in under
   1 s with `was_connected: true`, and a second connected device is
   unaffected;
   (l) `DeviceSetScope` false on a live `sensitive: true` device → it gets
   `Withheld { device_scope }` and no further `TeriState`; true → it is
   replayed the retained `TeriState` without reconnecting, within 1 s;
   (m) `DeviceUnpairSelf` → the record is revoked with `revoked_by: device`
   and the socket is closed;
   (n) device-admin verbs on a WS device socket → refused;
   (o) a device token never appears in captured log output.
9. **CLI.** Implement `nostromo device …` over `DaemonClient`. Test the
   output formatting and exit codes with the outcome stream stubbed, and
   cover one end-to-end `device pair` → redeem → exit 0 in
   `tests/device_pairing.rs`.

## Acceptance criteria

Behavioural criteria from the PRD that this wedge delivers on the daemon
side: PRD-AC9, AC14, AC16, AC17, AC21, AC23 (terminal), AC25/26 (daemon
behaviour and terminal output), AC28, AC29, AC31 (server side), AC32 (server
side), AC35 (daemon and terminal), AC36, AC37 (terminal and logs).

Technical criteria:
- `cargo test` passes. `tests/ipc_codec.rs`, `tests/ipc_tcp_transport.rs`
  and `tests/ipc_peer_gating.rs` pass **without modification** (gating gains
  new cases only).
- With `NOSTROMD_WS_ADDR` unset the daemon binds `0.0.0.0:47101` and logs
  it and the `pair_host`. With `NOSTROMD_WS_ADDR=off` no WS listener is
  bound.
- A WS socket without a token can send only `Hello`, `PairCheck` and one
  `Pair`. Anything else gets `Unauthorized { not_paired }` and close.
- An unknown or revoked token completes the upgrade, receives
  `Unauthorized { revoked | unknown }`, and is closed with 4001.
- Tokens are stored only as SHA-256 hashes. Plaintext appears only in the
  `Paired` frame: never on any CLI output, list, `Devices` frame, or log
  (test (o) greps the captured log).
- Revoking a device closes its live sockets in under 1 s and leaves every
  other device's sockets open.
- A scope change reaches a connected device in under 1 s, in both
  directions, without a reconnect.
- A pairing is in daemon memory only. It is cancelled when its issuing
  connection drops, and `devices.json` never contains a code.
- Lockout follows Approach 5. A wrong-code storm from one IP is also capped
  by the 20/min upgrade limit.
- `nostromo device pair` exits 0 only on `paired`, and non-zero on expiry,
  lockout, cancel and lost connection.
- `nostromo` with no subcommand behaves exactly as before.
- Device-admin frames (`Devices`, `DevicePairing`, `DevicePairOutcome`,
  `DeviceRevoked`) are never delivered to a `Tcp` or device `Paired` peer.
- `Welcome.features` includes `"ws"`, `"pair"` and `"devices"` on every
  transport.
- No clippy warnings (`cargo clippy --all-targets -- -D warnings`).
- PR body references `docs/plans/backplane-sequencing.md` (W9) and
  `docs/prds/daemon-pairing-flow.md`.

## Out of scope

- Satellite mode, uplink, `host` tagging, and relaying device admin from a
  satellite (W10). This wedge's admin verbs work from local Unix clients on
  the daemon that owns `devices.json`.
- Any Swift change: iOS (W11), Mac app (W15).
- `seq`/replay/heartbeats (W12).
- TLS on the WS listener (`wss://` is a later config switch; the endpoint is
  reached inside WireGuard).
- Removing the raw TCP listener or mDNS (deprecate only).
- Binary PTY frames (rejected with 1003 for now).
- Renaming a device; multiple operators; permissions beyond mail-and-todos
  (PRD out of scope).
- Widening what a `Paired` device may *do* (`network_policy` stays the `Tcp`
  allow-list plus `DeviceUnpairSelf`). See the sequencing memo's note on
  routed actions.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New authenticated network surface, new trust tier through peer.rs's exhaustive matches, live trust changes, pairing state machine, and a byte-identical handle_client split."
  redd:
    model: sonnet
    effort: high
    rationale: "Auth, revocation race, scope flip, lockout, TTL, dedup and CLI exit codes all need real socket tests with an injectable clock."
  marty:
    model: sonnet
    effort: medium
    rationale: "The framing split and admin dispatch will leave duplication worth consolidating; bounded scope."
  perri:
    model: opus
    effort: high
    rationale: "First authenticated listener and token issuer; pairing-only sockets, lockout and live trust changes are CVE-shaped if wrong."
```
