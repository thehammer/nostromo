# W9 — Add an authenticated WebSocket transport to nostromd

## Context

`nostromd` serves the Mac app over a Unix socket and iOS over a raw,
**unauthenticated** TCP listener (`src/bin/nostromd.rs:117-150`, default
`0.0.0.0:47100`, found by Bonjour via `src/mdns.rs`). Both run the same
`handle_client` loop (`src/ipc/server.rs:254`), which assumes it owns the
length-prefixed framing in `src/ipc/codec.rs`. Trust is derived from the
transport alone: `PeerTrust::from_transport` (`src/ipc/peer.rs:53-58`) maps
`Transport::Tcp` to the least-trusted tier, and `peer.rs` withholds every
Teri/Fred-derived frame from it.

This wedge adds a third transport: **WebSocket**, carrying the same
`ClientMsg`/`ServerMsg` JSON one message per text frame, authenticated at the
HTTP upgrade with a per-device bearer token, and admitted under a new
`PeerTrust::Paired` tier. It is the foundation for every off-host client in
`docs/plans/backplane-sequencing.md` (bets B2, B8): the primary daemon will
run on an always-on host and be reached over the operator's WireGuard VPN,
and a managed laptop that may only *dial out* will connect as a satellite
(W10). Device tokens are required even inside the VPN: the token is the
device's application identity (revocation, per-device sensitive-data scope,
the push relay's key), while WireGuard is only a network identity.

No Ada PRD exists for the pairing UX (`docs/prds/daemon-pairing-flow.md` is a
stub). This wedge therefore builds only the **wire exchange and CLI**; the
phone-side flow is W11, after Q1 in the sequencing memo is answered.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ws-transport`
- **Base:** `origin/main`

## Files to change

- `Cargo.toml:96` — `tokio-tungstenite = { version = "0.24", features =
  ["rustls-tls-native-roots"] }` is already present (used as a client by
  `src/data/relay_client.rs`). No new feature is needed for server-side
  `accept_hdr_async`. Add `sha2 = "0.10"` and `rand = "0.8"` if not already
  transitive (check `cargo tree -i sha2`), and `qrcode = "0.14"` (text QR for
  the `pair` subcommand; `default-features = false`).
- `src/ipc/peer.rs:31-58` — add `Transport::Ws` and `PeerTrust::Paired { sensitive: bool }`.
  `is_network()` (`:61-66`) returns `true` for `Paired`. Every exhaustive
  match in this module that names `PeerTrust::Tcp` gains a `Paired` arm;
  `may_receive` (`:709-722`) lets a `Paired { sensitive: true }` peer through
  the `ServerClass::Sensitive` / sensitive-tag gates and otherwise treats
  `Paired` exactly like `Tcp`. `network_policy` (`:775`) is unchanged for
  `Paired` (same allow-list as `Tcp`) **except** that `ClientMsg::Pair` is
  `Allowed` before authentication (see approach step 4).
- `src/ipc/devices.rs` (new) — `DeviceRegistry` over
  `~/.nostromo/devices.json` (`NOSTROMO_DEVICES_PATH` override):
  `{"devices":[{"id","label","token_hash","sensitive","created_at",
  "last_seen_at","revoked_at"}],"pair_codes":[{"code_hash","label",
  "expires_at"}]}`. Tokens are 32 random bytes, base64url, SHA-256 hashed at
  rest; plaintext is returned only from `add()`/`redeem_pair_code()`.
  Methods: `load`, `save` (atomic: write `.tmp` then rename), `add(label,
  sensitive) -> (Device, String)`, `validate(token) -> Option<Device>`,
  `revoke(id)`, `issue_pair_code(label) -> String` (6 digits, 5-minute TTL,
  single use), `redeem_pair_code(code, label) -> Option<(Device, String)>`,
  `touch_last_seen(id)`. A `tokio::sync::watch::Sender<u64>` "revocation
  epoch" bumps on every `revoke` so live connections can observe it.
- `src/ipc/ws.rs` (new) — `accept_loop_ws(listener, devices, …)`: for each
  `TcpStream`, `tokio_tungstenite::accept_hdr_async` with a callback that
  reads `Authorization: Bearer <token>`; a valid token yields
  `PeerTrust::Paired { sensitive }` and the device id; a missing token is
  admitted as **unauthenticated-pairing-only** (it may send exactly one
  `ClientMsg::Pair` and is closed after the reply); an invalid or revoked
  token is rejected at upgrade with HTTP 401. After upgrade, run
  `handle_client_ws` (below). Text frames carry one JSON message; binary
  frames are reserved for a later PTY-bytes path and are rejected with close
  code 1003 in this wedge; a text frame over `MAX_FRAME_LEN`
  (`protocol.rs:45`) closes with 1009.
- `src/ipc/server.rs:254-660` — split `handle_client` into a framing layer
  and a body. Keep the signature and behaviour of today's function for Unix
  and TCP (`handle_client_framed`), and add `handle_client_ws` taking a
  `WebSocketStream<TcpStream>`. Both call the existing `handle_client_msg`
  (`:661`) and the outbound filter `peer::outbound`. Add
  `Server::bind_ws(listener, devices, pty_mgr, session_mgr, perri_state_dir,
  decisions)` mirroring `bind_tcp` (`:148-163`). The WS loop also `select!`s
  on the revocation epoch and closes with code 4001 when its device is
  revoked.
- `src/ipc/protocol.rs:27` — bump `PROTOCOL_VERSION` to 5 (`MIN_CLIENT_VERSION`
  stays 2). Add `ClientMsg::Pair { code: String, label: String }` and
  `ServerMsg::Paired { device_id: String, token: String }`,
  `ServerMsg::Unauthorized { reason: String }`. Add `"ws"` and `"pair"` to
  `Welcome.features` (`:1208-1219`) so a client can detect the capability.
- `src/config.rs:51-60, 215-226` — `ws_addr: Option<SocketAddr>`,
  `ws_listen_addr()` resolving `NOSTROMD_WS_ADDR` → `config.toml ws_addr` →
  default `0.0.0.0:47101`. Flip `DEFAULT_TCP_ADDR` to `127.0.0.1:47100`
  (the raw listener becomes loopback-only by default; LAN TCP now needs an
  explicit opt-in).
- `src/bin/nostromd.rs:117-160` — construct the `DeviceRegistry`, bind the
  WS listener next to the TCP one, log its address at INFO. Keep mDNS
  advertising for the TCP port (W10 turns it off in satellite mode).
- `src/main.rs:24-60` — the binary has a flat `Args` struct today; add a
  clap `Subcommand` `Device { Add { label, --sensitive }, List, Revoke { id },
  Pair { label } }`. `add` prints the plaintext token once; `pair` prints a
  6-digit code and a text QR encoding `nostromo://pair?host=<ws host>&
  port=<ws port>&code=<code>`, then exits (the daemon redeems it).
- `tests/ipc_ws_transport.rs` (new) — mirrors `tests/ipc_tcp_transport.rs`:
  bind the server on `127.0.0.1:0` plus a tempdir Unix socket and a tempdir
  `NOSTROMO_DEVICES_PATH`; connect with `tokio_tungstenite::connect_async`.
- `tests/ipc_peer_gating.rs` — extend with `Paired { sensitive: false }`
  (behaves like `Tcp`) and `Paired { sensitive: true }` (receives
  `TeriState`/Fred frames) cases.
- `README.md:88-160` — §Daemon: WebSocket endpoint, `nostromo device`,
  pairing walkthrough; mark the raw TCP listener deprecated.

## Approach

1. **Trust tier first.** Add `Transport::Ws`/`PeerTrust::Paired` and let the
   compiler walk you through every exhaustive match in `peer.rs`. Decide each
   arm deliberately; the default is "same as `Tcp`". Only `may_receive` and
   `outbound` treat `sensitive: true` differently.
2. **Registry.** Implement `devices.rs` with unit tests in-module: add →
   validate round-trip, revoke → validate fails, pair code TTL and single
   use, atomic save survives a simulated crash (tmp file left behind is
   ignored on load).
3. **Split `handle_client`.** Extract the handshake + loop body so it is
   parameterised by a `send`/`recv` pair rather than owning `read_frame`/
   `write_frame`. The Unix/TCP path must produce byte-identical frames to
   today — `tests/ipc_codec.rs` and `tests/ipc_tcp_transport.rs` are the
   regression guard.
4. **Upgrade-time auth.** In `ws.rs`, authenticate in the `accept_hdr_async`
   callback. Three outcomes: `Paired` (token valid), `PairingOnly` (no
   token: the loop accepts one `Hello` then one `Pair`, replies `Paired` or
   `Unauthorized`, and closes), `401` (bad token). Never read a token from
   the URL query string.
5. **Revocation closes sockets.** Each WS task holds a `watch::Receiver` of
   the revocation epoch; on change it re-validates its device id and closes
   with 4001 if revoked. Target: under one second.
6. **CLI.** Wire `nostromo device …` as a subcommand that runs without
   starting the TUI. `pair` writes the code into the registry file (the
   daemon re-reads the file on each `Pair` attempt; the file is small).
7. **Tests.** `tests/ipc_ws_transport.rs`: (a) valid token → `Welcome` with
   `features` containing `"ws"`, `Subscribe`, receive a broadcast; (b) no
   token + valid pair code → `Paired{token}` and the token then works; (c)
   bad token → 401 at upgrade; (d) revoke during a live connection → close
   4001 within 1 s; (e) oversize frame → close 1009; (f) a `Paired {
   sensitive: false }` peer never receives a `TeriState` broadcast, a
   `sensitive: true` peer does.

## Acceptance criteria

- `cargo test` passes; `tests/ipc_codec.rs`, `tests/ipc_tcp_transport.rs`
  and `tests/ipc_peer_gating.rs` pass **without modification** (gating gains
  new cases only).
- With `NOSTROMD_WS_ADDR` unset, the daemon binds `0.0.0.0:47101` and logs it;
  with `NOSTROMD_WS_ADDR=off`, no WS listener is bound.
- `DEFAULT_TCP_ADDR` is loopback; a fresh config binds no non-loopback raw
  TCP listener.
- A WS upgrade without a valid token can do nothing but `Pair`; any other
  `ClientMsg` on an unauthenticated socket yields `Unauthorized` and close.
- Tokens are stored only as SHA-256 hashes; plaintext appears only on the
  stdout of `nostromo device add` / in the `Paired` reply, and never in logs
  (grep the test log output for the token).
- `nostromo device revoke <id>` closes that device's open WS connections
  within 1 s and its next upgrade is refused with 401.
- Pair codes expire after 5 minutes and are single-use; redeeming the same
  code twice fails.
- `Welcome.features` includes `"ws"` and `"pair"` on every transport.
- No clippy warnings (`cargo clippy --all-targets -- -D warnings`).
- PR body references `docs/plans/backplane-sequencing.md` (W9).

## Out of scope

- Satellite mode / uplink / `host` tagging (W10).
- Any Swift change (W11).
- `seq`/replay/heartbeats (W12).
- TLS on the WS listener (`wss://` is a later config switch; the endpoint is
  reached inside WireGuard).
- Removing the raw TCP listener or mDNS (deprecate only).
- Binary PTY frames (reject with 1003 for now).
- QR *scanning* UX on the phone; the typed-code path is all W11 needs.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New authenticated network surface, new trust tier through peer.rs's exhaustive matches, and a handle_client refactor that must stay byte-identical for Unix."
  redd:
    model: sonnet
    effort: high
    rationale: "Auth accept/reject, revocation race, pair-code TTL, oversize frames and sensitive gating all need real socket tests, not mocks."
  marty:
    model: sonnet
    effort: medium
    rationale: "The framing split will leave duplication between the framed and WS loops worth consolidating; bounded scope."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First authenticated listener in the codebase; token handling and the Paired gating are CVE-shaped if wrong."
```
