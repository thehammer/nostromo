# W9 — Add an authenticated WebSocket transport and device pairing to nostromd

## Refreshed 2026-11-23 against `origin/main` `8f0328b9`

Read the memo's "Readiness", "What changed since 2026-10-18", bet **B11** and
the re-derived "Wire inventory" first. Versus the 2026-10-18 version of this
file (line numbers in this file are re-derived; the 2026-10-18 notes further
down are history):
- **Ordinals.** `CLIENT_MSG_VARIANTS` is **98** (`src/ipc/peer.rs:2491`,
  asserted again at `:2639-2640`). This wedge's seven verbs take **98–104**
  (`PairCheck` 98 … `DeviceRevoke` 104) and the constant becomes **105**
  (2026-11-23: nine before Q2 removed `DevicePairUpdate` and
  `DeviceSetScope`).
  Each new verb also gets a fixture in `every_client_msg()`; none goes into
  `NETWORK_ALLOWED` (`:2461`), because `DeviceUnpairSelf` is admitted by
  `paired_extra_allowed`, not by `network_policy`.
- **Unblocked.** AP2a, AP3 and MC4 are merged; the only exclusion left is "no
  other job editing the session wire at the same time" (memo, "Dispatch
  order").
- **B11 lands here.** The merge gate (`merged_turns_v1`, #514) must count only
  attached connections that can send user messages. This wedge changes
  `refresh_merge_gate` (`src/ipc/session_manager/mod.rs:3846-3855`) so network
  peers never count, and the WebSocket handshake carries `Hello.capabilities`
  through the shared parse (`src/ipc/server.rs:643-666`). New criteria
  W9-19 (W9-20 is the install criterion).
- **Packaging.** `make install-daemon` (`Makefile:136-193`) now builds through
  `make daemon` (`:129-130`), copies from `$(NOSTROMO_TARGET_DIR)/release`,
  stages and signs three binaries and runs the restart guard first. The
  `nostromo` CLI joins that recipe as a fourth, independent binary (details
  under Files).
- **More verbs are refused for a `Paired` device.** The 57 verbs merged since
  2026-10-18 are all `Refused` in `network_policy` (`peer.rs:1070-1181`) and
  the new frames are almost all `LocalOnly`; a `Paired` peer inherits that.
  The B10 gating cases add the newest operator-only verbs (below).
- **Gates.** `.mother/crew.yml` exists. `python-test` runs on the host
  (`where: any`, correct) and triggers on this wedge because `tests/**`
  matches the new Rust test files **and** because this wedge edits the
  `Makefile`. Narrowing `tests/**` (memo, crew delta 7) does not change that:
  the `Makefile` must stay in `python-test`'s `when`, because
  `tests/restart_guard` and `tests/gates/test_python_test_split.py` read its
  recipe. Lenses run automatically (Mother #75); the repo default is all four.

## Sign-offs folded in (2026-11-23: Ada's memo and the operator's decisions)

Ada signed off D1–D7 and the operator answered Q1–Q8 on 2026-11-23 (memo,
"Decision log 2026-11-23"). Ada is rewriting `docs/prds/daemon-pairing-flow.md`
in parallel, so this file cites decisions by id, not by PRD line. What changes
here:
- **D6, re-pairing an already-paired phone, is new daemon work** (PRD AC57,
  AC58). A server counts as "the same server" only if it proves it already
  knows this device's pairing, without the device revealing its credential or
  anything replayable. Mechanism (challenge and proof, Approach 4a): the
  first `PairCheck` returns a per-code random `challenge` in `PairOffer`; a
  device that holds a credential sends a second `PairCheck` carrying `proof =
  HMAC-SHA256(key = SHA-256(token), msg = challenge ‖ code)`; the server
  compares it with the same HMAC over each active device record's stored
  `token_hash` and answers `knows_device: true | false`, **at most once per
  code** (a later proof on that code gets no answer). A hostile server learns
  only an HMAC bound to its own challenge and code, which neither connects as
  the device nor replays anywhere. `server_id` is not trusted for this (it is
  unauthenticated). On `Pair { replace: true }` after a `true` answer, the
  registry revokes the matched record (`revoked_by: replaced`, "Replaced by
  re-pairing") **before** name dedup, so the phone keeps its name, closes the
  old record's sockets with 4001, and saves once. Any other case is a plain
  pairing; the different-server path (warning, wipe, `DeviceUnpairSelf` to
  the old server) is the phone's (W11). Tests (q)–(s), criterion W9-21.
- **D4 (server check before confirmation): two rules made explicit.** A
  correct `PairCheck` never uses up the code; only `Pair` does. A wrong code at
  `PairCheck` counts toward the lockout like a wrong `Pair`. An unreachable
  check never reaches the daemon, so it counts for nothing. If the code expires
  or is cancelled between `PairCheck` and `Pair`, `Pair` answers
  `PairRefused { expired }` or `{ invalid }` (W11 keeps the edited name).
  Test (t), criterion W9-22.
- **D5 (lockout across open codes)** is already Approach 5. No change.
- **D3 (a code dies with its window or command)** is already built (outcome
  `connection_lost`). The terminal line is now Ada's copy (CLI, `device pair`).
  Criterion W9-13 checks it.
- **D1 (Local Network denied)** needs nothing here: a denied attempt never
  reaches the daemon, so it never uses up a code (Approach 7).
- **Q1: Kobe's device-admin level is a new `revoke-only` level.** The
  satellite `admin` field gains `revoke_only` (`full | revoke_only | read_only
  | off`). W9 stores and prints it; an unset level is `revoke_only` (Ada's
  rule), so Sendai needs an explicit `--admin full`. W10 enforces it on the primary, and W15 defines the
  behaviour in full (W15, "Revoke-only device-admin level (Q1)"). No new verb
  and no new ordinal.
- **Q2: mail, calendar and todos stay home in v1, for every host, with no
  checkbox, flag, toggle or config key** (Ada's PRD, decision log Q2). So this
  wedge **does not build** the per-device mail-and-todos permission at all:
  no `sensitive` field on `PeerTrust::Paired`, the registry, the pairing or
  any frame; no `DevicePairUpdate` or `DeviceSetScope` verb (the ordinals
  shrink to 98–104); no `--no-mail-and-todos` flag and no `device
  mail-and-todos` subcommand; no live re-scope. A `Paired` peer is withheld
  the Teri, Fred and work topics exactly like `Tcp`, with `Withheld { reason:
  "not_shared" }`. The terminal's line is Ada's copy: **"Mail, calendar and
  todos aren't shared from your Macs in this version."** Opening it up later
  is a new wedge (the PRD's deferred AC35). Criterion W9-23.
- **B11** is unchanged (above).

## Refreshed 2026-10-18 against `origin/main` `d61c62d` (history)

Read `docs/plans/backplane-sequencing.md` first: "What changed since
2026-10-10", bets B9/B10 and the "Wire inventory" table are binding on this
plan. In short, versus the 2026-10-10 draft of this file:
- FND-1 exists and is default-deny. `ServerClass::LocalOnly` already exists
  (BA0, AP0b) and means "never to any network peer"; this wedge adds a new
  `ServerClass::Admin` for device-admin frames instead.
- Approval and decision answers come only from the verified Mac app
  (`PeerTrust::OperatorApp`, AP1/AP1b). A `Paired` device gets exactly `Tcp`'s
  verbs plus `DeviceUnpairSelf`, and never a `LocalOnly` frame.
- There is no `nostromo` binary (R1 removed the TUI and `src/main.rs`). The
  CLI is a new `[[bin]] nostromo` at `src/bin/nostromo_cli.rs`.
- No `PROTOCOL_VERSION` bump (stays 4); capabilities go in `Welcome.features`.
- The WebSocket listener defaults to loopback; the primary opts in.
- Binary frames close with 1003 (the PTY host is gone; nothing uses them).
- Tests run in CI, not locally (RWX sandbox for Rust, GitHub Actions for
  Swift); all hermetic.

## Context

`nostromd` serves the Mac app over a Unix socket and legacy iOS builds over a
raw, **unauthenticated** TCP listener (bound in `src/bin/nostromd.rs:353-378`,
default **loopback** `127.0.0.1:47100`, `src/config.rs:46`, `tcp_listen_addr`
`:482`; found by Bonjour via `src/mdns.rs`, advertised at `nostromd.rs:384`).
Both run the generic `handle_client` loop (`src/ipc/server.rs:617`) with the
length-prefixed framing in `src/ipc/codec.rs`, then `handle_client_msg`
(`:1430`). Trust: `PeerTrust` (`src/ipc/peer.rs:47-55`) is `OperatorApp` (a Unix peer the
macOS-only verifier in `src/ipc/peer_verify.rs` matched against
`~/.nostromo/operator-app.pin`), `LocalOther` (any other Unix peer) or `Tcp`.
FND-1 (`peer.rs`) classifies every frame: `classify_server_msg` (`:717`),
`may_receive` (`:970`), `outbound` (`:987`), the default-deny
`network_policy` (`:1054`, 13 verbs `Allowed`, 85 `Refused`),
`targets_sensitive_session` (`:1197`), `redact_for_network` (`:1344`),
`withheld_msg` (`:1424`), and the ordinal tripwire `CLIENT_MSG_VARIANTS = 98`
(`:2491`). The session manager's merge gate counts attached connections that
did not declare `merged_turns_v1` (`src/ipc/session_manager/mod.rs:3846-3855`).

This wedge adds a third transport, **WebSocket**. It carries the same
`ClientMsg`/`ServerMsg` JSON, one message per text frame. It authenticates
each connection with a per-device bearer token at the HTTP upgrade and
admits it under a new `PeerTrust::Paired` tier. It is the foundation for
every off-host client in `docs/plans/backplane-sequencing.md` (bets B2, B8).
The primary daemon runs on an always-on host reached over the operator's
WireGuard VPN. A managed laptop that may only *dial out* connects to it as a
satellite (W10). Device tokens are required even inside the VPN: the token is
the device's application identity (revocation, the push relay's key), while WireGuard is only a network identity.

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
- **Max cost:** $65 (expected ≈ $26; see the memo's Estimate; raised from $60
  on 2026-11-23 for D6 and the revoke-only level; Q2 then removed two verbs,
  so the cap is kept as headroom)

## Files to change

- `Cargo.toml:106` — `tokio-tungstenite = { version = "0.24", features =
  ["rustls-tls-native-roots"] }` is already present (a client in
  `src/data/relay_client.rs`). Server-side `accept_hdr_async` needs no new
  feature. `sha2 = "0.10"` is already a direct dependency (`:92`). Add
  `rand = "0.8"` unless it is already direct (check `Cargo.lock`; a `uuid` v4
  is not a token source). Add `qrcode = "0.14"` with
  `default-features = false` for the terminal QR. Add a `[[bin]]` entry
  `nostromo` → `src/bin/nostromo_cli.rs` next to the existing seven
  (`Cargo.toml:13-39`).
- `src/ipc/peer.rs:34-74` — add `Transport::Ws` and
  `PeerTrust::Paired` (no fields: the device id travels on the connection,
  not in the trust value, so `PeerTrust` stays `Copy`; Q2 means there is no
  per-device scope in v1).
  `is_network()` returns `true` for `Paired`. Every exhaustive match that
  names `PeerTrust::Tcp` gains a deliberate `Paired` arm; the default is
  "same as `Tcp`". `PeerTrust::Paired` is never `OperatorApp`-equivalent for
  any purpose (decision operators, approval renderers, `operator_nonce`).
  - `may_receive`/`outbound` (`:970-996`): `Paired` is treated exactly like
    `Tcp`: `ServerClass::Sensitive` (Teri, Fred, work) and `LocalOnly` stay
    `false`, and `redact_for_network` applies.
  - `classify_server_msg` (`:717-888`): add `ServerClass::Admin` for the
    device-admin frames (below). `may_receive` delivers `Admin` to
    non-network peers only in this wedge; W10 adds the satellite exception.
    The pairing-reply frames (`PairOffer`, `Paired`, `PairRefused`,
    `Unauthorized`, `DeviceUnpaired`) are `Open` and are only ever written
    targeted to the socket that asked; a unit test asserts `Server::broadcast`
    is never called with them.
  - `network_policy` (`:1054-1183`), `targets_sensitive_session`
    (`:1197`) and the ordinal table (`:2494-2595`) gain every new
    `ClientMsg`: `PairCheck` 98, `Pair` 99, `DeviceUnpairSelf` 100,
    `DevicePairStart` 101, `DevicePairCancel` 102, `DeviceList` 103,
    `DeviceRevoke` 104; `CLIENT_MSG_VARIANTS` 98 → 105 (if another merged plan took ordinal 98
    first, continue from the next free one and re-derive), plus the two
    asserts at `:2639-2640`, the history comment above them, and one fixture
    each in `every_client_msg()`. Policy: `PairCheck`/`Pair` → `Refused` (they are
    accepted only on a token-less pairing socket, enforced in `ws.rs` before
    dispatch); `DeviceUnpairSelf` → `Refused` here and allowed by a
    `Paired`-only check in `handle_client_msg`; every `Device*` admin verb →
    `Refused` for every network peer (W10 adds the one satellite exception).
    `NetworkPolicy` stays a two-value enum; the `Paired` special cases live
    in one function, `peer::paired_extra_allowed(&ClientMsg) -> bool`.
  - `withheld_msg` (`:1424`) takes a reason. Today's
    `requires_secure_connection` stays for `Tcp`. A `Paired` peer gets reason
    `not_shared` (Q2), so the phone says "Mail, calendar and todos stay on
    your Mac in this version." (PRD-AC34).
- `src/ipc/devices.rs` (new) — `DeviceRegistry` over
  `~/.nostromo/devices.json` (`NOSTROMO_DEVICES_PATH` override, mode 0600,
  atomic write: `.tmp` then rename). Per device: `id`, `name`, `kind`
  (`iphone | ipad | satellite`), `token_hash` (SHA-256 of 32 random bytes,
  base64url), `admin` (satellites only: `full | revoke_only |
  read_only | off`, default `revoke_only`; Q1, meaning defined in W15),
  `paired_at`, `last_seen_at`, `revoked_at`, `revoked_by`
  (`operator | device | replaced`; `replaced` is D6). A `server_id` (random,
  minted on first load) is stored once at the top level. Revoked records are
  kept (PRD-AC23, AC30). Operations: validate a token; redeem a pairing (name
  dedup, see Approach 4; replacement, Approach 4a); revoke by id; set a
  satellite's `admin`; touch last-seen. The token's plaintext exists only in the `Paired` reply. The
  registry publishes a `tokio::sync::watch` **registry epoch** that bumps
  on every revoke and admin change, so live connections
  re-check their own record.
- `src/ipc/pairing.rs` (new) — the in-memory `PairingTable` on the primary.
  Each open pairing holds the code hash, an optional name hint,
  `kind` (`device | satellite`), `expires_at` (5 min), the issuing
  connection's key (and, for one relayed by W10, the satellite's origin
  key) and a sender for its outcome. Outcomes are `paired { name, kind,
  replaced }`, `expired`, `cancelled`, `locked_out` and
  `connection_lost`. Wrong-attempt accounting is described in Approach 5.
  Expired code hashes are kept as tombstones for 1 hour so a late attempt
  gets `expired` rather than `invalid`. Cancelled, used and locked-out
  codes leave no tombstone, so they answer `invalid` (PRD failure table:
  "wrong (or already used)").
- `src/ipc/ws.rs` (new) — `accept_loop_ws`. For each `TcpStream`, run
  `tokio_tungstenite::accept_hdr_async` with a callback that reads
  `Authorization: Bearer <token>` (never a query string). There are three
  admission outcomes. **Paired** (valid, unrevoked token): run
  `handle_client_ws` under `Paired` with the device id.
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
  `MAX_FRAME_LEN` (`src/ipc/protocol.rs:52`) closes with 1009.
  Unauthenticated upgrades are rate-limited per source IP: 20 per minute,
  then refused at upgrade with HTTP 429.
- `src/ipc/server.rs:617-1429` — `handle_client` is already generic over the
  stream type; give it a framing seam (a send/receive pair) so a
  `WebSocketStream<TcpStream>` can drive the same body. Unix and TCP keep
  today's behaviour byte-for-byte. Both call `handle_client_msg` (`:1430`)
  and the `peer::outbound` filter. The body's `trust` becomes mutable for WS
  peers. AP1b's answer-time re-inspection and `operator_nonce` paths are
  Unix-only and must not be reachable from a WS peer (a test sends
  `DecisionAnswer` and `ApprovalAnswer` from a `Paired`
  socket and asserts `requires_secure_connection` with no side effect). Then:
  - **Retained replay** (the `Subscribe` and re-subscribe paths in
    `handle_client`):
    today a network peer gets no retained frame and one `Withheld`. Change
    it so a network peer is replayed every retained frame that passes
    `outbound(trust, …)`, and gets a `Withheld` only for topics its trust
    actually withholds. `Tcp` behaviour is unchanged (it is withheld
    everything retained today, and still is).
  - **Registry epoch** in the WS `select!`: on change, re-read this
    connection's device record. If revoked: send `Unauthorized { reason:
    "revoked" }`, close 4001 (under 1 s). Other connections are untouched
    (PRD-AC28). (No scope re-check: Q2 removed per-device scope in v1.)
  - Add `Server::bind_ws(listener, devices, pairing, …)` mirroring
    `bind_tcp` (`:280`).
  - **Hello capabilities on WebSocket (B11).** The WS path feeds its first
    text frame to the same Hello parse (`:643-666`), so `capabilities` and
    `merge_capable` are recorded for a WS connection exactly as for Unix and
    TCP. Do not special-case it; B11 is enforced in the session manager.
  - **On disconnect** of any connection, cancel the pairings it owns
    (outcome `connection_lost`). A pairing never outlives the window or
    command that shows its code.
  - **Device-admin dispatch** in `handle_client_msg`, for non-network peers
    only (`OperatorApp` or `LocalOther`; the CLI is `LocalOther`, and Tokyo
    has no `OperatorApp` at all because the verifier is macOS-only). W10 adds
    satellites. Every admin verb is appended to the daemon log with the
    peer's trust and verb name, never a code or token: `DevicePairStart`,
    `DevicePairCancel` (honoured only from the connection that owns the
    pairing; any other caller gets `DeviceAdminError { unknown_pairing }`),
    `DeviceList`, `DeviceRevoke`. Plus
    `DeviceUnpairSelf` for an authenticated device, which revokes only the
    connection's own device id (`revoked_by: device`), replies
    `DeviceUnpaired`, then closes 4001 (PRD-AC31).
  - **Device-list broadcasts**: on every registry change and on every device
    connect/disconnect, broadcast `Devices { devices }` (class `Admin`,
    topic `devices`).
- `src/ipc/protocol.rs` — **no `PROTOCOL_VERSION` change** (stays 4 at
  `:34`; capability is the `Welcome.features` strings below). Add
  `Topic::Devices` (`Topic` enum `:73-89`; `Unknown` stays last with
  `#[serde(other)]`). Messages:
  - Client → daemon, device side: `PairCheck { code, proof: Option<String> }`;
    `Pair { code, name, kind, replace: bool }` (D6; new fields
    `#[serde(default)]`; `proof` never logged); `DeviceUnpairSelf`.
  - Daemon → device: `PairOffer { name_hint: Option<String>, server_id,
    challenge, knows_device: Option<bool> }` (`knows_device` present only in
    the reply to the first proof on a code); `Paired { device_id, token, name,
    server_id, replaced: bool }` (`replaced` only repeats the already-given
    answer);
    `PairRefused { reason: expired | invalid }`;
    `Unauthorized { reason }`; `DeviceUnpaired`.
  - Client → daemon, admin side (each carries a client-minted `request_id`):
    `DevicePairStart { name_hint, satellite: Option<String> }`;
    `DevicePairCancel { pairing_id }`; `DeviceList`;
    `DeviceRevoke { device }` (id, or exact name of an *active* device).
  - Daemon → admin client: `DevicePairing { request_id, pairing_id, code,
    server_url, expires_at }`;
    `DevicePairOutcome { pairing_id, outcome }` (`paired` also carries
    `replaced: bool`); `Devices { devices: Vec<DeviceSummary> }`;
    `DeviceRevoked { request_id, device_id, was_connected }`;
    `DeviceAdminError { request_id, reason }` (reasons in this wedge:
    `unknown_device`, `ambiguous_name`, `unknown_pairing`; W10 adds
    `server_unreachable` and `not_permitted_on_this_mac`). `DeviceSummary`
    has `id, name, kind, paired_at, last_seen_at, connected, revoked_at,
    revoked_by` and **never** a token or hash. Every new field is
    `#[serde(default)]`. Satellites are excluded from the
    phone/iPad list and reported in a separate `hosts` array.
  - Add `"ws"`, `"pair"` and `"devices"` to `Welcome.features` (built in
    `welcome_msg`, `src/ipc/server.rs:568-600`; constants next to the
    existing ones at `server.rs:83-100`).
  - The QR/URL payload is `nostromo://pair?v=1&host=<h>&port=<p>&code=<c>`.
    The name hint is *not* in it; the device learns it from `PairOffer`.
- `src/config.rs:46-60, 475-490` — add `ws_addr: Option<SocketAddr>` and
  `ws_listen_addr()` (`NOSTROMD_WS_ADDR` → `config.toml ws_addr` → default
  **`127.0.0.1:47101`**, matching `DEFAULT_TCP_ADDR`; `off` disables). The
  primary opts in with `ws_addr = "0.0.0.0:47101"` (or its WireGuard/LAN
  address); a non-loopback bind logs one INFO line naming the address. Also add `pair_host: Option<String>`:
  the address devices are told to use. The default is the bound WS address
  if it is specific; otherwise the first non-loopback, non-link-local IPv4
  of the host. Log the chosen value at INFO. (No mail-and-todos config key:
  Q2.)
- `src/bin/nostromd.rs:353-398` — construct the `DeviceRegistry` and
  `PairingTable`, bind the WS listener next to the TCP one, and log its
  address. Keep mDNS for the TCP port (W10 turns it off in satellite mode).
- `src/bin/nostromo_cli.rs` (new) — a small clap binary named `nostromo`
  with one subcommand group, `device`. With no subcommand it prints help and
  exits 0 (there is no TUI any more). Every subcommand talks to the
  **local** daemon over the Unix socket with `DaemonClient`
  (`src/ipc/client.rs`).
- `Makefile` — the CLI fits the current recipe like this:
  `daemon` (`:129-130`) adds `--bin nostromo`; `install-daemon`
  (`:136-193`) copies `$(NOSTROMO_TARGET_DIR)/release/nostromo` to a new
  inode beside the real `nostromd`, `codesign --force -s - --identifier
  nostromo`, and moves it into place **after** `nostromd` (it is not part of
  the bridge/guard/daemon all-or-nothing swap: nothing the daemon runs depends
  on it, so a failed CLI copy prints a warning and leaves the daemon
  installed), then symlinks `~/.local/bin/nostromo` if absent and echoes
  `Installed nostromo to …`. The restart guard already runs first; the CLI
  adds no restart. `uninstall-daemon` (`:195-201`) removes it; `install`
  (`:22-28`, `cargo install --path .`) picks the new bin up by itself and
  lists it in its echo; replace the comment at `:25` (an old TUI binary named
  `nostromo` may still sit in `~/.cargo/bin` on the operator's Macs, and the
  new CLI deliberately overwrites it; if `~/.local/bin/nostromo` and
  `~/.cargo/bin/nostromo` differ after install, print which one `PATH`
  resolves first). If W14's `install-daemon-linux` is on
  main, install `nostromo` there too (no `codesign` on Linux).
  On the primary that daemon does the work itself; on a satellite W10
  relays it. Subcommands:
  - `device pair [NAME]` — prints the server URL, the code as `NNN NNN`, a
    text QR, a live countdown on one updating line, and Ada's line `Mail,
    calendar and todos aren't shared from your Macs in this version.` (Q2; no
    flag, no other mail wording). It **stays running** until the outcome.
    Paired: `Paired: <final name>.`, exit 0. Expired: `Code expired. Run the command again for a
    new one.`, exit 1. Locked out: `Too many wrong attempts. This code is no
    longer valid. Run the command again for a new one.`, exit 1. Ctrl-C sends
    `DevicePairCancel`, prints `Cancelled. The code no longer works.`, exit
    130. Lost connection to the server (D3, Ada's copy): `Lost the connection
    to the server. This code no longer works. Run the command again when
    you're connected.`, exit 1 (PRD-AC14, AC17).
  - `device pair --satellite <host> [--admin full|revoke-only|read-only|off]`
    — primary only (refused when relayed). Issues a satellite enrolment code
    for W10's `nostromo uplink pair`. An unset `--admin` means `revoke-only`
    for every enrolment (Q1 and Ada's rule that unset means revoke-only);
    Sendai gets `--admin full` explicitly. This replaces
    the earlier `device add`, which printed a token (PRD-AC37 forbids that).
  - `device list [--all]` — columns: NAME, KIND, PAIRED, LAST SEEN
    (`Connected now` or `2 h ago`). Then a `Revoked` group with revoke times, and `Replaced by
    re-pairing` for `revoked_by: replaced` (D6). `--all` adds the satellites
    with their admin level (PRD-AC23).
  - `device revoke <name-or-id>` — prints `Revoked <name>. Disconnected
    just now.` or `Revoked <name>. Wasn't connected; it will be refused the
    next time it tries.` (PRD-AC25, AC26, AC29).
  - `device admin <host> full|revoke-only|read-only|off` — primary only;
    changes a satellite's device-admin capability (used by W10/W15).
- `tests/ipc_ws_transport.rs` (new) — mirrors `tests/ipc_tcp_transport.rs`.
  Bind on `127.0.0.1:0`, a tempdir Unix socket and a tempdir
  `NOSTROMO_DEVICES_PATH`, and connect with
  `tokio_tungstenite::connect_async`.
- `tests/device_pairing.rs` (new) — pairing lifecycle driven from a Unix
  admin client plus WS device sockets; see Approach 8.
- `tests/ipc_peer_gating.rs` — add `Paired` cases (behaves like `Tcp`, never
  receives `TeriState`/`FredState`/work frames, `Withheld` reason
  `not_shared`), plus B10 cases: a `Paired` peer subscribed to everything never receives
  any `LocalOnly` frame (drive it from the classification list rather than a
  hand list: approval frames, `SessionTaskDetail`, `SessionQueue*`,
  `AuthoredPrs*`, `TrackerBoard`, `ConversationHistory*`, `SessionMcpResult`,
  `Terminal*`, `RemoteShell*` are all in it), does receive `ApprovalPending`
  and `TrackerSummary` for a non-sensitive tag, and has `ApprovalAnswer`,
  `ApprovalRefusalReport`, `DecisionAnswer`, `MotherResume`, `MotherAction`,
  `SessionSend`, `SessionQueueTakeBack`, `AuthoredPrMerge`, `TrackerEdit` and
  `SessionMcp` refused with no side effect.
- `src/ipc/session_manager/mod.rs:3846-3855` (`refresh_merge_gate`) and its
  call sites (`:1965-1970` attach, `:2059-2076` network attach and detach,
  `:3218-3231` connection drop) — B11: a connection counts as legacy only if
  it is attached and is **not** in `network_clients` (`:720-723`). Pass
  `&self.network_clients` in beside `&self.merge_capable`. Unit tests next to
  the existing merge tests (`src/ipc/session_manager/merge_delivery_tests.rs`):
  (1) a local client that declared it plus a network peer that declared nothing,
  both attached → merges; (2) the app plus a local client that declared
  nothing → does not merge (unchanged); (3) a network peer detaches or drops →
  the gate is recounted and the queue snapshot rebroadcast as today. Update
  the "Gate" paragraph of `docs/message-queue.md` to say network peers do not
  count, and why (they cannot send, so cannot echo).
- `README.md:88-160` — §Daemon: WebSocket endpoint, `pair_host`, the
  `nostromo device` commands, a pairing walkthrough. Mark the raw TCP
  listener deprecated.

## Approach

1. **Trust tier first.** Add `Transport::Ws`/`PeerTrust::Paired` and the
   `Admin` class, then let the compiler walk you through every exhaustive
   match in `peer.rs`. Decide each arm deliberately, and add the ordinals and
   the `CLIENT_MSG_VARIANTS` bump in the same commit.
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
4a. **Re-pair proof and replace (D6).** Each open pairing holds a random
   32-byte `challenge` (returned in every `PairOffer` for it), a
   `proof_answered` flag and an optional `matched_device`. The first
   `PairCheck` with a `proof` on a code computes HMAC-SHA256(`token_hash`,
   `challenge ‖ code`) for every active `iphone`/`ipad` record
   (constant-time compares, all records, no early exit), stores the match,
   sets `proof_answered`, and replies `knows_device`. Later proofs on that code
   get a `PairOffer` with no `knows_device`. On a `Pair { replace: true }`
   whose code is accepted and whose pairing has a `matched_device` still
   active, do this in one registry transaction and one save: mark the old record revoked
   (`revoked_by: replaced`), then dedup the new name (so the old name is
   free), then insert the new record. Then bump the registry epoch, so the old
   record's live sockets get `Unauthorized { revoked }` and 4001 under 1 s
   (W11 has already closed its own old socket), and reply `Paired { replaced:
   true }`; the issuer's `DevicePairOutcome::paired` also says `replaced:
   true`. `Pair { replace: true }` without a match is a plain pairing with
   `replaced: false`. The only oracle is `knows_device`, once per code, and
   only with a valid code the operator issued (PRD AC58). A wrong code revokes
   nothing and counts toward the lockout. The proof is never logged. If the
   phone lost its old token (or sends no proof), the re-pair is a fresh
   pairing: the name gets a suffix
   ("iPhone 2") and the old entry stays active until the operator revokes it
   (W11 says so).
5. **Wrong-attempt lockout** (PRD-AC17). A wrong code (a `PairCheck` or
   `Pair` that matches no open pairing and no tombstone) cannot be pinned on
   one pairing. So it counts against **every pairing open at that moment**.
   When a pairing's count reaches 5, it is removed (no tombstone) and its
   issuer gets `locked_out`. In the normal case one pairing is open, so this
   is exactly the PRD's rule. A correct `PairCheck` does not use the code.
   The successful `Pair` does, and it resets nothing else. A wrong code at
   `PairCheck` counts exactly like a wrong `Pair` (D4). Two open codes lock out
   together (D5, signed off as written).
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
   (d) a `Paired` peer never receives `TeriState`, `FredState` or a work
   frame, and its subscribe yields `Withheld { reason: "not_shared" }`;
   (e) a `Paired` peer is replayed exactly what the outbound filter allows
   (currently none), plus one `Withheld { not_shared }`, on subscribe. (The
   held-approval replay over a `Paired` socket is a follow-up in
   `tests/approvals_wire.rs`.)
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
   (l) `DevicePairCancel` for a pairing owned by another connection →
   `DeviceAdminError { unknown_pairing }` and the pairing stays open;
   (m) `DeviceUnpairSelf` → the record is revoked with `revoked_by: device`
   and the socket is closed;
   (n) device-admin verbs on a WS device socket → refused;
   (o) a device token never appears in captured log output;
   (p) a WS device whose `Hello` declares `capabilities: ["merged_turns_v1"]`
   and one that declares nothing both attach to a busy session with a local
   (Unix) client that declared `merged_turns_v1` also attached (the gate looks
   only at the declared capability; the operator-app verifier is macOS-only,
   `src/ipc/peer_verify.rs:350`, `:375`, `:386`, `:677`, `:740`, so no Linux
   test can be the verified app): queued typed messages still merge (B11), and the
   connection's declared capability is recorded;
   (q) D6, same server: device A pairs as "iPhone" and stays connected; a new
   code is checked with A's proof (→ `knows_device: true`) and redeemed with
   `replace: true` and name "iPhone" → the
   reply is `Paired { name: "iPhone", replaced: true }`, A's old socket is
   closed with 4001 in under 1 s, the old record is in the revoked group with
   `revoked_by: replaced`, and a `Devices` broadcast shows both;
   (r) D6, no match: a proof from an unknown, revoked or satellite credential
   → `knows_device: false`, then `Pair { replace: true }` → `replaced: false`,
   nothing revoked; a second proof on the same code (even A's) → no
   `knows_device` (AC58); the challenge differs per code, so a proof captured
   for one code fails on another; no proof → "iPhone 2" and A stays active;
   (s) proofs never appear in captured log output (extends (o)), and no
   `Pair` or `PairCheck` field accepts a raw token or token hash;
   (t) D4: a correct `PairCheck` twice, then `Pair` → paired (the check used
   nothing); four wrong `PairCheck`s plus one wrong `Pair` → `locked_out`;
   `PairCheck` ok, then expiry, then `Pair` → `PairRefused { expired }`;
   `PairCheck` ok, then cancel, then `Pair` → `PairRefused { invalid }`;
   (u) Q2: no frame the pairing flow or `Devices` sends has a `sensitive` or
   mail field (a serde round-trip test on the fixtures), and `nostromo device
   pair` prints Ada's "Mail, calendar and todos aren't shared from your Macs
   in this version." and no other mail wording.
9. **CLI.** Implement `nostromo device …` in `src/bin/nostromo_cli.rs`
   over `DaemonClient`. Test the
   output formatting and exit codes with the outcome stream stubbed, and
   cover one end-to-end `device pair` → redeem → exit 0 in
   `tests/device_pairing.rs`.

## Acceptance criteria

Behavioural criteria from the PRD that this wedge delivers on the daemon
side: PRD-AC9, AC14, AC16, AC17, AC21, AC23 (terminal), AC25/26 (daemon
behaviour and terminal output), AC28, AC29, AC31 (server side), AC32 (server
side), AC36, AC56–58 (AC35 is deferred by Q2), AC37 (terminal and logs), and the
daemon side of sign-offs D3, D4, D5, D6, Q1 and Q2 (cited by decision id,
because Ada is rewriting the PRD's numbering in parallel).

Technical criteria:
- [ ] **W9-1** CI is green on the PR: the Rust build, clippy and tests (RWX sandbox,
  `rwx sandbox exec -- cargo test …`, and the `ubuntu-24.04` Rust jobs in
  `.github/workflows/ci.yml`), and the Python tooling job. **Do not run
  `cargo` locally** (the toolchain guard blocks it); use the sandbox or
  `make ci-remote ONLY=rust`. Every new test is hermetic: loopback sockets on
  port 0, tempdirs, an injected clock; no real network.
- [ ] **W9-2** `tests/ipc_codec.rs`, `tests/ipc_tcp_transport.rs` and
  `tests/ipc_peer_gating.rs` keep every existing case unmodified (gating
  gains new cases only), and `tests/fixtures/mother-contract/*.golden.json`
  are unchanged.
- [ ] **W9-3** With `NOSTROMD_WS_ADDR` unset the daemon binds `127.0.0.1:47101` and logs
  it and the `pair_host`. With `ws_addr = "0.0.0.0:47101"` it binds all
  interfaces. With `NOSTROMD_WS_ADDR=off` no WS listener is bound.
- [ ] **W9-4** `CLIENT_MSG_VARIANTS` and the ordinal table cover every new verb; the
  FND-1 exhaustiveness tests pass.
- [ ] **W9-5** B10: no `LocalOnly` frame reaches a `Paired` peer, and no approval or
  decision answer is accepted from one (the gating cases above).
- [ ] **W9-6** A WS socket without a token can send only `Hello`, `PairCheck` and one
  `Pair`. Anything else gets `Unauthorized { not_paired }` and close.
- [ ] **W9-7** An unknown or revoked token completes the upgrade, receives
  `Unauthorized { revoked | unknown }`, and is closed with 4001.
- [ ] **W9-8** Tokens are stored only as SHA-256 hashes. Plaintext appears only in the
  `Paired` frame: never on any CLI output, list, `Devices` frame, or log
  (test (o) greps the captured log).
- [ ] **W9-9** Revoking a device closes its live sockets in under 1 s and leaves every
  other device's sockets open.
- [ ] **W9-10** `DevicePairCancel` is honoured only from the connection that owns the
  pairing (test (l)). (Was the scope-change criterion; Q2 removed per-device
  scope in v1.)
- [ ] **W9-11** A pairing is in daemon memory only. It is cancelled when its issuing
  connection drops, and `devices.json` never contains a code.
- [ ] **W9-12** Lockout follows Approach 5. A wrong-code storm from one IP is also capped
  by the 20/min upgrade limit.
- [ ] **W9-13** `nostromo device pair` exits 0 only on `paired`, and non-zero on expiry,
  lockout, cancel and lost connection; the lost-connection line is D3's
  exact copy.
- [ ] **W9-14** `nostromo` with no subcommand prints help and exits 0; `make
  install-daemon` installs it signed next to `nostromd`.
- [ ] **W9-15** Device-admin frames (`Devices`, `DevicePairing`, `DevicePairOutcome`,
  `DeviceRevoked`) are never delivered to a `Tcp` or device `Paired` peer.
- [ ] **W9-16** `Welcome.features` includes `"ws"`, `"pair"` and `"devices"` on every
  transport, and `PROTOCOL_VERSION` is still 4.
- [ ] **W9-17** No clippy warnings (`cargo clippy --all-targets -- -D warnings`).
- [ ] **W9-18** PR body references `docs/plans/backplane-sequencing.md` (W9) and
  `docs/prds/daemon-pairing-flow.md`.
- [ ] **W9-19** B11: an attached network peer (legacy `Tcp` or `Paired`) never closes
  the merge gate, with or without `merged_turns_v1`; an attached local peer
  that did not declare it still closes it. Unit tests (1)–(3) and socket test
  (p) pass, and `tests/session_queue_bytes.rs` is unmodified and green.
- [ ] **W9-20** `make install-daemon` installs the signed `nostromo` CLI after the
  three existing binaries without changing their order or the restart guard,
  and `make uninstall-daemon` removes it.
- [ ] **W9-21** D6 (PRD AC57, AC58): `knows_device` is answered from a
  challenge-bound HMAC proof at most once per code; `Pair { replace: true }`
  after a match revokes the old record (`revoked_by: replaced`) in the same
  save, keeps the name without a suffix, and closes the old record's sockets
  with 4001 in under 1 s; nothing the device sends is its token, its hash or
  replayable on another code; proofs are never logged (tests (q)–(s)).
- [ ] **W9-22** D4: `PairCheck` never uses up a code, a wrong `PairCheck` counts toward
  the lockout, and expiry or cancel between check and `Pair` gives
  `PairRefused { expired }` / `{ invalid }` (test (t)).
- [ ] **W9-23** Q2 (PRD AC56): no `TeriState`, `FredState` or work frame reaches a
  `Paired` peer, the withheld reason is `not_shared`, there is no
  mail-and-todos verb, flag, config key or frame field, and the CLI prints
  only "Mail, calendar and todos aren't shared from your Macs in this
  version." (tests (d), (u)).
- [ ] **W9-24** Q1: the registry and CLI accept `full | revoke_only | read_only | off`
  (`revoke-only` on the command line) for a satellite, an enrolment without
  `--admin` is `revoke_only` whatever its egress (Sendai is enrolled with an
  explicit `--admin full`), and `device list --all` prints the
  level. (Enforcement is W10's.)

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`; rechecked at `0a38549` on
2026-11-23). The repo's `.mother/crew.yml` is on main since MC5 (#290): it is
read from the job's base ref, so a worker can neither add nor loosen a gate.

- **Gates that apply (2026-11-23, `.mother/crew.yml` on main):** `rust-fmt`
  (non-blocking), `rust-clippy`, `rust-test` (`where: sandbox`), `python-test`
  (`where: any`, on the host; it triggers because `tests/**` matches the new
  Rust test files and because this wedge edits the `Makefile`), `shellcheck`
  only if a script changes. `swift-ci` is skipped (no Swift paths). Mother's
  code runs the checks serially (memo, crew delta 6). Measured per pass: Rust
  ≈ 5 min, `python-test` ≈ 20 (memo, "Estimate"), so ≈ 25 min, inside
  `budget_minutes: 75` (#519, merged). Crew delta 7 does **not** remove
  `python-test` here: the `Makefile` stays in its `when` because
  `tests/restart_guard` and `tests/gates` read the recipe.
  `max_attempts` is 2.
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to two fix attempts (`max_attempts: 2`), then a `gate_hold`.
- **Reviewer lenses:** all four are the repo default (`.mother/crew.yml:61`);
  the yaml block below keeps its `add` list for readability. They run
  automatically in parallel with adherence on the gated commit (Mother #75,
  merged).
- **Review depth:** **Manual Perri pass is still required** (the `perri` entry below at xhigh, then the operator's review). Lens findings are input to it, not a substitute: a lens sees only the diff (patch input is capped at 120 KB, so a large wedge will report `coverage_gap` findings), and Mother's `phi-security` checklist is written for care data, so it does not know this repo's trust tiers (B9, B10). First authenticated listener and token issuer.
- **Checklist:** the acceptance items above carry ids (`W9-1` to `W9-24`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- Satellite mode, uplink, `host` tagging, and relaying device admin from a
  satellite (W10). This wedge's admin verbs work from local Unix clients on
  the daemon that owns `devices.json`.
- Any Swift change: iOS (W11), Mac app (W15).
- `seq`/replay/heartbeats (W12).
- TLS on the WS listener (`wss://` is a later config switch; the endpoint is
  reached inside WireGuard).
- Removing the raw TCP listener or mDNS (deprecate only).
- Binary frames of any kind (closed with 1003). Terminals and PTYs (the PTY
  host is gone; terminal-pane frames are `LocalOnly`).
- Anything an agent session could use: device admin is never exposed as an
  MCP tool.
- Renaming a device; multiple operators; permissions beyond mail-and-todos
  (PRD out of scope).
- The phone's side of D6 (computing the proof, the different-server
  warning, wiping content, telling the old server): W11. The old server sees
  only an ordinary `DeviceUnpairSelf`.
- Enforcing the `revoke_only` level for relayed admin verbs (W10) and its Mac
  UI (W15).
- Any way to share mail, calendar or todos with a device (Q2, PRD AC56): no
  flag, key, verb or field in v1; opening it up is a later wedge.
- Widening what a `Paired` device may *do* (it gets the `Tcp` allow-list
  plus `DeviceUnpairSelf`, and W13's self-scoped push verbs later). Per bet
  B10, approval/decision answers are never accepted from it.

## Pinned wire vector: the re-pair proof (D6)

W11 (Kit) must produce these exact bytes. The encoding, exactly:

- **key** = the raw 32-byte SHA-256 of the token's **base64url text** (the
  token string as the daemon issued it, hashed as UTF-8 bytes; not decoded);
- **message** = the challenge's **base64url text** (as it appears in
  `PairOffer.challenge`, UTF-8 bytes) followed by the pairing code **reduced to
  its digits** (`123 456` is `123456`);
- **proof** = HMAC-SHA256(key, message), encoded **base64url without padding**.

| Input | Value |
| --- | --- |
| token | `dG9rZW4tZm9yLXRoZS1maXhlZC12ZWN0b3ItMDAwMDAwMDA` |
| SHA-256(token) (key, hex) | `6ea97a4459aa83bb2f9776d280a02605de0d9614bb35991db08c6173e40fc47c` |
| challenge | `Y2hhbGxlbmdlLWZvci10aGUtZml4ZWQtdmVjdG9yLTAwMDA` |
| code | `123456` |
| **proof** | `ONMjmbNsnby-4Laxp33owC99gferbRJQsDdW6Ofz4cA` |

The vector is checked in as `the_proof_encoding_is_pinned_by_a_fixed_vector`
in `src/ipc/devices.rs`, next to the RFC 4231 HMAC vector.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New authenticated network surface, new trust tier through peer.rs's exhaustive matches, live trust changes, pairing state machine, and a byte-identical handle_client split."
  redd:
    model: sonnet
    effort: high
    rationale: "Auth, revocation race, re-pair proof, lockout, TTL, dedup and CLI exit codes all need real socket tests with an injectable clock."
  marty:
    model: sonnet
    effort: medium
    rationale: "The framing split and admin dispatch will leave duplication worth consolidating; bounded scope."
  perri:
    model: sonnet
    effort: xhigh
    rationale: "First authenticated listener and token issuer; pairing-only sockets, lockout, live trust and B10 refusals are CVE-shaped. Sonnet at xhigh per operator default."
lenses:
  add: [correctness, tests, phi-security]
  remove: []
```
