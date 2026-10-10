# W11 — iOS/iPadOS client over WebSocket with device pairing

## Context

The iOS app reaches `nostromd` today through
`Shared/NostromoKit/Sources/NostromoKit/Transport/NetworkClient.swift`
(357 lines: `NWConnection(.tcp)`, the length-prefixed framing, a
Hello/Welcome/Subscribe handshake at `:231-247`, 3 s app-level pings,
1 s → 30 s reconnect backoff) after discovering the Mac with
`DaemonDiscovery.swift` (`NWBrowser` over `_nostromo._tcp`; entitlements in
`iOS/Nostromo/Info.plist:5-10`). `iOS/Nostromo/NostromoApp.swift:16-44`
wires `ConnectionSettings` (UserDefaults host/port,
`Views/ConnectionSettingsView.swift:11-32`) and `DaemonDiscoveryView`.

That path is dead for the operator's managed laptop (discovery and inbound
connections are blocked by MDM) and irrelevant once the primary daemon runs
on an always-on host reached over WireGuard (`docs/plans/backplane-sequencing.md`,
B2/B7/B8). W9 gave the daemon an authenticated WebSocket listener
(default port 47101, `Authorization: Bearer <device token>`, a `Pair { code,
label }` exchange that returns `Paired { device_id, token }`, and
`Unauthorized`). W10 added `host: Option<String>` to the stateful frames so
one primary presents several hosts' Mother queues and PTYs.

This wedge replaces the transport in the shared `NostromoKit` package with a
`URLSessionWebSocketTask` client, stores the device token in the Keychain,
adds a pair-by-code screen, and keeps Bonjour as an optional LAN fallback
while the raw TCP listener still exists. The macOS app continues to use the
Unix socket and is untouched.

**Depends on Ada's Q1** (pairing UX) in the sequencing memo. Until it is
answered this plan specifies a *typed 6-digit code* flow only; QR scanning
is a follow-up.

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ios-ws-client`
- **Base:** `origin/main` (W9 merged; W10 merged for the `host` field)

## Files to change

- `Shared/NostromoKit/Sources/NostromoKit/Transport/WebSocketClient.swift`
  (new) — same public surface as `NetworkClient` (`@MainActor`,
  `@Published connected`, `messages: PassthroughSubject<ServerMsg, Never>`,
  `send(_:)`, `start()/stop()`), implemented over
  `URLSessionWebSocketTask`. Builds `ws://<host>:<port>/` with the bearer
  header; sends `Hello{protocol_version: 5}` then
  `Subscribe{topics: [], renders_decisions: true}` exactly as
  `NetworkClient.swift:231-247`; one JSON message per text frame; WS-level
  `sendPing` every 20 s; reconnect backoff 1 s → 30 s; surfaces a typed
  `ConnectionState { connecting, connected, unauthorized, unreachable }`.
  Decodes `Paired`/`Unauthorized` and `HostUnavailable`.
- `Shared/NostromoKit/Sources/NostromoKit/Transport/DeviceCredential.swift`
  (new) — Keychain wrapper (`kSecClassGenericPassword`, service
  `com.hammer.nostromo.device`, account = daemon host): `load()`, `save(token,
  deviceId)`, `clear()`. Protocol-typed so tests can inject an in-memory
  store.
- `Shared/NostromoKit/Sources/NostromoKit/Transport/PairingClient.swift`
  (new) — opens an unauthenticated WS, sends `Hello` + `Pair{code,label}`,
  returns the token or a typed error (`expired`, `invalid`, `unreachable`).
- `Shared/NostromoKit/Sources/NostromoKit/Wire/ClientMsg.swift` — add
  `Pair`, and the optional `host` on `MotherResume`/`MotherAction`/`Pty*`.
- `Shared/NostromoKit/Sources/NostromoKit/Wire/ServerMsg.swift` — add
  `Paired`, `Unauthorized`, `Hosts`, `HostUnavailable`, and optional `host`
  on `MotherJobs`/`MotherStatusline`/`MotherAwaitDetected`/`PtyList`.
- `Shared/NostromoKit/Sources/NostromoKit/Wire/MotherJob.swift` — unchanged;
  the host rides the envelope. Store layer (`Store/DaemonStore.swift`) keeps
  jobs keyed by `(host, id)` so two hosts' queues merge without collision
  (default presentation per Q3: one list, host badge).
- `Shared/NostromoKit/Sources/NostromoKit/Transport/NetworkClient.swift` —
  keep, mark `@available(*, deprecated)`; selected only when the user picks
  "Local network (legacy)" in settings.
- `iOS/Nostromo/Views/ConnectionSettingsView.swift:11-32` — settings become
  `{host, port (default 47101), transport: .webSocket | .legacyTCP}`; add
  "Pair this device" (label field + 6-digit code) and "Forget pairing"
  (clears Keychain, disconnects).
- `iOS/Nostromo/Views/PairDeviceView.swift` (new) — the typed-code screen;
  shows the daemon's instructions (`nostromo device pair --label iPhone` on
  the primary) and the three error states.
- `iOS/Nostromo/NostromoApp.swift:16-44, 212` — construct `WebSocketClient`
  when a credential exists, `PairDeviceView` when none; `DaemonDiscoveryView`
  only under `.legacyTCP`. Show a one-line banner when state is
  `.unreachable` reading "Can't reach <host>. Is your VPN on?" (the app
  cannot read WireGuard state; it can only say what it tried).
- `iOS/Nostromo/Info.plist:5-10` — keep the Bonjour keys (still needed for
  legacy) but the app must run with local-network permission denied.
- `Shared/NostromoKit/Tests/NostromoKitTests/WebSocketClientTests.swift`,
  `PairingClientTests.swift`, `DeviceCredentialTests.swift` (new) — a tiny
  in-process WS echo server (`NWListener` with `.webSocket` protocol
  options) drives the client: handshake order, token header present,
  `Unauthorized` → state, reconnect after server close, `Paired` persists
  through the injected credential store. Extend `MotherWireTests.swift`
  with `host` present/absent fixtures.

## Approach

1. Wire types first (`ClientMsg`/`ServerMsg` additions with optional `host`);
   run `swift test` — every existing fixture must still decode.
2. `DeviceCredential` with an injectable store; unit-test the protocol.
3. `PairingClient`, then `WebSocketClient`, each against the in-process WS
   listener. Mirror `NetworkClient`'s handshake and backoff constants so
   behaviour is familiar; replace the 3 s app ping with WS ping at 20 s.
4. Settings + pairing screen; `NostromoApp` selects the client by credential
   and transport setting.
5. Store keying by `(host, id)` and the host badge on Mother rows (the badge
   is hidden when every job has `host == nil`).
6. Run the existing iOS simulator build in CI (`.github/workflows/ci.yml:110+`)
   and the `NostromoKit` test target.

## Acceptance criteria

- `cd Shared/NostromoKit && swift test` passes; existing wire tests are
  unmodified apart from added fixtures.
- With a paired credential and the daemon reachable, the app connects over
  WS, receives `Welcome` with `features` containing `"ws"`, and shows the
  same Mother/Perri/Activity content it showed over TCP.
- With no credential, launch lands on the pairing screen; a valid code
  yields a connected app without restart; an expired/invalid code shows the
  matching error; the token is never written to UserDefaults or logs.
- A revoked device (daemon closes 4001 / next upgrade 401) lands on the
  pairing screen with a "This device was un-paired" message.
- Jobs from two hosts display in one list with a host badge; actions on a
  job are sent with that job's `host`; `HostUnavailable` shows an inline
  error on the row.
- The app functions with Local Network permission denied (no Bonjour).
- `[stack]`-style manual check (no stack tooling exists for iOS; list in PR
  body): phone on cellular + WireGuard → connects to the primary's
  WireGuard address; WireGuard off → `.unreachable` banner.
- PR body references the sequencing memo (W11) and Q1's answer.

## Out of scope

- QR *scanning* (typed code only until Q1 is written).
- macOS app changes.
- Push notifications / APNs registration (W13).
- `seq`/resume (W12); this client reconnects and relies on retained frames.
- Removing `NetworkClient`/Bonjour (deprecated, selectable).

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New transport, Keychain handling and app-launch flow across NostromoKit and the iOS target; must coexist with the legacy client."
  redd:
    model: sonnet
    effort: high
    rationale: "Needs an in-process WebSocket listener to test handshake, auth failure and reconnect without a daemon."
  marty:
    model: sonnet
    effort: medium
    rationale: "Two clients with one public surface — extract a protocol and share the handshake/backoff code."
  perri:
    model: sonnet
    effort: high
    rationale: "Token storage and the unauthenticated pairing socket are the security-relevant surface on the client side."
```
