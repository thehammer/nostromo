# W11 — iOS/iPadOS client over WebSocket with device pairing

## Context

The iOS app reaches `nostromd` today through
`Shared/NostromoKit/Sources/NostromoKit/Transport/NetworkClient.swift`
(357 lines). It uses `NWConnection(.tcp)` with length-prefixed framing, a
Hello/Welcome/Subscribe handshake at `:231-247`, 3 s app-level pings and a
1 s → 30 s reconnect backoff. It finds the Mac first with
`DaemonDiscovery.swift` (`NWBrowser` over `_nostromo._tcp`; Bonjour keys in
`iOS/Nostromo/Info.plist:5-10`). `iOS/Nostromo/NostromoApp.swift:15-46`
builds a `NetworkClient` from `ConnectionSettings` (UserDefaults host/port,
`Views/ConnectionSettingsView.swift:11-32`) and, on first launch, presents
`DaemonDiscoveryView`. `DaemonStore`
(`Shared/NostromoKit/Sources/NostromoKit/Store/DaemonStore.swift`) holds
everything in memory only. The Fred/Teri views show a placeholder when a
topic is withheld (`iOS/Nostromo/Views/FredView.swift:16-22`,
`TeriView.swift:40`) and show a disconnected view whenever the socket is
down.

That path is dead for the operator's managed laptop (MDM blocks discovery
and inbound connections). It is also irrelevant once the primary daemon runs
on an always-on host reached over WireGuard
(`docs/plans/backplane-sequencing.md`, B2/B7/B8). W9 gave the daemon:
- an authenticated WebSocket listener (default port 47101, `Authorization:
  Bearer <token>`);
- a pairing-only socket (`PairCheck { code }` → `PairOffer { name_hint,
  sensitive, server_id }` or `PairRefused { expired | invalid }`; `Pair {
  code, name, kind }` → `Paired { device_id, token, name, sensitive,
  server_id }`);
- `Unauthorized { reason }` + close 4001 for a revoked or unknown token;
- live scope changes (`Withheld { reason: "device_scope" }`, or a replay of
  retained Fred/Teri frames);
- `DeviceUnpairSelf`;
- the QR payload `nostromo://pair?v=1&host=&port=&code=`.

W10 added `host: Option<String>` to the stateful frames, so one primary
presents several hosts' Mother queues and PTYs.

This wedge builds the device half of Ada's PRD
`docs/prds/daemon-pairing-flow.md` (cited as PRD-ACn; read its "Design-loop
notes for Ada" too). It replaces the transport in `NostromoKit` with a
`URLSessionWebSocketTask` client and keeps the token in the Keychain. It
adds the **Pair with Nostromo** first-launch flow (scan, system-Camera deep
link, typed code, confirmation, success, four failure states), a persisted
**last-known content cache** (needed so "can't reach" still shows content
across relaunches), the **no-longer-paired** screen with a content wipe,
Settings with **Un-pair**, and live mail-and-todos scope. Bonjour stays only
as a legacy option in Settings. The macOS app is untouched (W15 does the Mac
side).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ios-ws-client`
- **Base:** `origin/main` (W9 merged; W10 merged for the `host` field)

## Files to change

- `Shared/NostromoKit/Sources/NostromoKit/Transport/WebSocketClient.swift`
  (new) — the same public surface as `NetworkClient` (`@MainActor`,
  `@Published connected`, `messages: PassthroughSubject<ServerMsg, Never>`,
  `send(_:)`, `start()/stop()`), over `URLSessionWebSocketTask`. It builds
  `ws://<host>:<port>/` with the bearer header, then sends
  `Hello{protocol_version: 5}` and `Subscribe{topics: [],
  renders_decisions: true}` as `NetworkClient.swift:231-247` does. One JSON
  message per text frame, WS `sendPing` every 20 s, reconnect backoff 1 s →
  30 s. It exposes `ConnectionState { connecting, connected, unreachable,
  localNetworkDenied, notPaired(reason) }`. Only an `Unauthorized` frame or
  close code 4001 yields `notPaired`. No other failure (timeout, refused,
  DNS, TLS, an HTTP error at upgrade) ever does (PRD-AC22).
  `localNetworkDenied` is detected with an `NWConnection` path probe (see
  the PRD design-loop notes, D1).
- `.../Transport/DeviceCredential.swift` (new) — Keychain wrapper
  (`kSecClassGenericPassword`, service `com.hammer.nostromo.device`, one
  fixed account; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
  Stores `{token, deviceId, serverId, name, sensitive}`: `load()`,
  `save(_:)`, `clear()`. It is protocol-typed so tests inject an in-memory
  store. It is **not** keyed by address, so changing the address keeps the
  pairing (PRD-AC33).
- `.../Transport/PairingClient.swift` (new) — opens a token-less WS and
  runs `check(code) -> PairOffer` and `pair(code, name, kind) -> Paired`
  with typed errors `expired`, `invalid`, `unreachable` and
  `localNetworkDenied`. `kind` comes from `UIDevice.userInterfaceIdiom`.
- `.../Transport/PairLink.swift` (new) — parse and validate
  `nostromo://pair?v=1&host=&port=&code=` (six digits only, port 1–65535,
  host non-empty). Pure; unit-tested.
- `.../Store/ContentCache.swift` (new) — persists the last-known snapshot
  the tabs render (`motherJobs`, `perriQueue`, `perriCurrentPr`, `focuses`,
  `sessions`, `fredMailbox`, `fredCalendar`, `teriTodos`, plus a
  `savedAt`) as one JSON file in Application Support, written atomically
  with `FileProtectionType.complete` and excluded from backup. Debounced
  writes (at most every 5 s). `wipe()` deletes the file synchronously.
  Fred/Teri fields are written only while the device's scope is
  `sensitive: true`, and are purged at once when it goes false.
- `.../Store/DaemonStore.swift:156-170, 293-400` — accept a transport
  protocol that both clients satisfy. Add `@Published pairingState` (from
  the client's `ConnectionState`), `isStale`, and `deviceScope`. Hydrate
  from `ContentCache` at init when a credential exists. On `.withheld(topics,
  reason: "device_scope")`, clear `fredMailbox`, `fredCalendar`,
  `teriTodos` and the work data, and purge them from the cache
  (PRD-AC35). Today's `:391` keeps stale content. Add `wipeAll()`, which
  clears every published collection and calls `ContentCache.wipe()`. Keep
  jobs keyed by `(host, id)` so two hosts' queues merge without collision
  (default presentation per Q3: one list, host badge).
- `.../Wire/ClientMsg.swift` — add `pairCheck`, `pair`, `deviceUnpairSelf`
  and the optional `host` on `MotherResume`/`MotherAction`/`Pty*`.
- `.../Wire/ServerMsg.swift` — add `pairOffer`, `paired`, `pairRefused`,
  `unauthorized`, `deviceUnpaired`, `hosts`, `hostUnavailable`, and the
  optional `host` on `MotherJobs`/`MotherStatusline`/`MotherAwaitDetected`/
  `PtyList`. Decode `withheld.reason`.
- `.../Transport/NetworkClient.swift` — keep it, marked
  `@available(*, deprecated)`. It is selected only by "Local network
  (legacy)" in Settings.
- `iOS/Nostromo/NostromoApp.swift:15-46` — the root becomes a small state
  machine: **no credential** → `PairWithNostromoView`; **credential** →
  the main tabs over `WebSocketClient` (hydrated from the cache);
  **notPaired** → `NoLongerPairedView`. Remove the first-launch
  `DaemonDiscoveryView` sheet (`:27-45`); discovery stays reachable only
  from Settings under the legacy transport. Add `.onOpenURL`: a valid
  `nostromo://pair` link goes straight to the confirmation step with
  address and code applied (PRD-AC6). With an existing pairing, the
  confirmation says it will replace this device's current pairing (see the
  design-loop notes). Replace the toolbar `network` button
  (`:201-213`) with a gear that opens `DeviceSettingsView`.
- `iOS/Nostromo/Views/Pairing/PairWithNostromoView.swift` (new) — title
  **Pair with Nostromo**, the PRD's instruction text, and the **Scan Code**
  (primary) and **Enter Code Instead** buttons, and nothing else
  (PRD-AC1). No permission is requested before Scan. When a hardware
  keyboard is attached, Return activates **Enter Code Instead** and typing
  a digit jumps into the code field (PRD-AC4).
- `.../Pairing/QRScannerView.swift` (new) — `AVCaptureMetadataOutput` with
  `.qr` in a `UIViewControllerRepresentable`. The camera permission is
  requested on first appearance only. Denied → a message with a button to
  **Enter Code Instead** (PRD-AC2). A non-`nostromo://pair` QR is ignored
  with an inline hint.
- `.../Pairing/EnterCodeView.swift` (new) — the server address field
  (pre-filled from the last address used, PRD-AC5) and a six-digit field.
  Digits only, cursor advances as digits are typed, submits on the sixth
  digit or Return. `@FocusState` drives the whole path from a hardware
  keyboard with no touches (PRD-AC4).
- `.../Pairing/ConfirmPairingView.swift` (new) — shown only after a
  successful `PairCheck`. It shows "Pair this <iPhone|iPad> with Nostromo at
  <address>?", an editable **Name** pre-filled with `name_hint` or the
  device kind, the scope line from `PairOffer.sensitive`, and **Pair**
  (`.keyboardShortcut(.defaultAction)`) (PRD-AC7).
- `.../Pairing/PairingSuccessView.swift` (new) — "Paired as <final name>.
  Includes mail and todos" / "Mail and todos are off for this <kind>",
  showing `Paired.name` (the deduplicated name, PRD-AC9, AC10). It hands
  over to the tabs once the first `MotherJobs` arrives, or after 1.5 s,
  whichever is later.
- `.../Pairing/PairingErrorBanner.swift` (new) — the four PRD failure
  sentences verbatim, with the real address and device kind (PRD-AC19). A
  fifth state, `localNetworkDenied`, uses copy pending Ada (design-loop
  notes, D1). The entered address and code stay in place, and **Try Again**
  is one tap (PRD-AC20).
- `iOS/Nostromo/Views/NoLongerPairedView.swift` (new) — full screen: "This
  <iPhone|iPad> is no longer paired with Nostromo. Pair it again to
  reconnect." and **Pair Again** → `PairWithNostromoView` with the address
  pre-filled (PRD-AC30, AC32). Before this view renders, the app runs
  `DeviceCredential.clear()`, then `DaemonStore.wipeAll()` (memory and
  cache file), in that order (PRD-AC27).
- `iOS/Nostromo/Views/UnreachableBanner.swift` (new) — "Can't reach
  Nostromo at <address>. If you're away from home, turn on your VPN." over
  last-known content marked stale (PRD-AC22). `FredView.swift:16-22`,
  `TeriView.swift` and the Mother/Perri/Sessions views stop replacing their
  content with `disconnectedView` when cached content exists.
- `iOS/Nostromo/Views/FredView.swift:18-19`, `TeriView.swift:40` — when
  withheld with reason `device_scope`: "Mail and todos are turned off for
  this <iPad>. Change this from Devices on your Mac." No spinner and no
  empty list (PRD-AC34).
- `iOS/Nostromo/Views/DeviceSettingsView.swift` (new; replaces the
  `ConnectionSettingsView` entry point, which stays reachable under
  "Advanced → Local network (legacy)"):
  - **Server address**, editable. On save, reconnect with the same
    credential. If the new address answers 4001, the normal
    no-longer-paired path applies (PRD-AC33).
  - This device's **name** and **mail-and-todos** scope, read-only (no
    control can change scope, PRD-AC36).
  - **Un-pair This iPhone/iPad**, with a confirmation. Reachable: send
    `DeviceUnpairSelf`, await `DeviceUnpaired` (5 s timeout), wipe, and
    return to the pairing screen. Unreachable or timeout: wipe, and show
    "Forgotten on this <iPhone>. Revoke it from your Mac's Devices list when
    you can." (PRD-AC31).
- `iOS/Nostromo/Views/ConnectionSettingsView.swift:11-32` —
  `ConnectionSettings` keeps `host` (last address used, never cleared by a
  revoke or un-pair) and gains `port` (default 47101) and `transport:
  .webSocket | .legacyTCP` (default `.webSocket`).
- `iOS/Nostromo/Info.plist` — add `CFBundleURLTypes` with scheme `nostromo`
  (PRD-AC6) and `NSCameraUsageDescription` ("Nostromo uses the camera only
  to scan the pairing code shown on your Mac."). Keep the Bonjour keys for
  legacy. `iOS/Nostromo.xcodeproj/project.pbxproj:392,426` keep
  `INFOPLIST_KEY_NSLocalNetworkUsageDescription`, reworded to "Nostromo
  connects to your Nostromo server when it's on this Wi-Fi network."
- Tests (`Shared/NostromoKit/Tests/NostromoKitTests/`, new unless noted):
  - `WebSocketClientTests.swift`, `PairingClientTests.swift` — an
    in-process WS listener (`NWListener` with `.webSocket` options) drives
    the clients: handshake order, bearer header present, 4001 →
    `notPaired`, connection refused → `unreachable` (never `notPaired`),
    reconnect after server close, `PairCheck` → `PairOffer`, `Pair` →
    `Paired` saved through the injected credential store.
  - `DeviceCredentialTests.swift`, `PairLinkTests.swift`.
  - `ContentCacheTests.swift` — round trip; `wipe()` leaves no file;
    Fred/Teri never written while scope is off.
  - Extend `DaemonStoreTests.swift` (`device_scope` withheld clears Fred/
    Teri and the cache; `wipeAll()` empties every collection; hydrate from
    the cache marks `isStale`) and `MotherWireTests.swift` (fixtures with
    `host` present and absent).

## Approach

1. Wire types first (`ClientMsg`/`ServerMsg` additions, all optional or
   additive), then run `swift test`. Every existing fixture must still
   decode.
2. `DeviceCredential`, `PairLink`, `ContentCache`: pure or injectable, and
   unit-tested.
3. `PairingClient`, then `WebSocketClient`, each against the in-process WS
   listener. Mirror `NetworkClient`'s handshake and backoff constants.
   Replace the 3 s app ping with a WS ping at 20 s. Keep the failure
   classification (`notPaired` vs `unreachable`) in one function with a
   table-driven test. It guards PRD-AC22, the criterion most likely to
   regress quietly.
4. `DaemonStore`: transport protocol, cache hydration, `device_scope`
   handling, `wipeAll()`.
5. Views: the pairing flow, then the root state machine and `.onOpenURL`,
   then the no-longer-paired screen, the unreachable banner, and Settings.
6. Store keying by `(host, id)` and the host badge on Mother rows (hidden
   when every job has `host == nil`).
7. Build the iOS simulator target in CI (`.github/workflows/ci.yml:110+`)
   and run the `NostromoKit` tests.

## Acceptance criteria

Behavioural criteria from the PRD delivered on the device: PRD-AC1–10,
AC19–22, AC25–27 (device side), AC30–34, AC35 (device side), AC36, AC37
(device side). Those that need a real device and a live primary are listed
as manual checks.

Technical criteria:
- `cd Shared/NostromoKit && swift test` passes. Existing wire tests are
  unmodified apart from added fixtures.
- A fresh install (no Keychain item) opens **Pair with Nostromo**. No
  discovery sheet, no host/port form, and no permission prompt appear before
  **Scan Code** is tapped.
- The token lives only in the Keychain (`…ThisDeviceOnly`). It is never in
  UserDefaults, the content cache, logs, or any view (grep test over
  `os_log` capture in the client tests).
- Only `Unauthorized` or close code 4001 moves the app to the
  no-longer-paired state. A table-driven test proves that refused, timeout,
  DNS failure, network down, close 1001/1006 and HTTP 5xx at upgrade all
  yield `unreachable`.
- On `notPaired`, the credential is cleared, then the cache file is deleted,
  then the screen renders. After a relaunch, `ContentCache` has no file and
  `DaemonStore` is empty.
- The cache is written with `FileProtectionType.complete`, excluded from
  backup, and never contains Fred/Teri data while scope is off.
- `device_scope` withheld clears on-screen Fred/Teri content at once; the
  daemon delivers it in under 1 s (W9).
- After **Pair** on a reachable server, the first `MotherJobs` frame is
  rendered within 3 s (PRD-AC8).
- A `nostromo://pair` link with a malformed code or host shows an error and
  never sends anything.
- The app runs with Local Network permission denied whenever the server is
  reached through the VPN or a routed (non-Wi-Fi-subnet) address
  (PRD-AC2 as amended by design-loop note D1). When the server is on the
  same Wi-Fi subnet and access is denied, it shows the
  `localNetworkDenied` state, never "unreachable" and never the pairing
  screen.
- Manual checks (no stack tooling exists for iOS; list results in the PR
  body):
  - iPhone, system Camera pointed at a `nostromo device pair` QR → "Open in
    Nostromo" → confirmation with address and code applied (PRD-AC6).
  - iPad with a Magic Keyboard pairs by typed code with no touches
    (PRD-AC4).
  - Phone on cellular + WireGuard connects to the primary's address;
    WireGuard off → banner, stale content, no pairing screen, and the same
    after a relaunch; WireGuard back on → reconnects by itself (PRD-AC22).
  - Revoke from the terminal while connected → the no-longer-paired screen
    within 5 s; relaunch shows no content (PRD-AC25, AC27).
- PR body references the sequencing memo (W11) and the PRD.

## Out of scope

- The Mac app (W15) and every daemon change (W9, W10).
- Push notifications / APNs registration (W13).
- `seq`/resume (W12); this client reconnects and relies on retained frames.
- Removing `NetworkClient`/Bonjour (deprecated, selectable under legacy).
- Renaming the device after pairing; pairing with more than one server;
  detecting whether the VPN is on (PRD out of scope).
- Universal links (`https://` with an apple-app-site-association file);
  there is no public domain. The custom scheme is the deep link.
- Any control on the device that changes its own mail-and-todos scope.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New transport, Keychain, persisted cache with wipe ordering, camera scanner, deep link and a multi-screen first-run flow across NostromoKit and the iOS target."
  redd:
    model: sonnet
    effort: high
    rationale: "Needs an in-process WebSocket listener; the notPaired-vs-unreachable classification and the wipe ordering are the regressions that matter."
  marty:
    model: sonnet
    effort: medium
    rationale: "Two clients behind one protocol plus several small pairing views; consolidate shared handshake/backoff and copy."
  perri:
    model: sonnet
    effort: high
    rationale: "Token storage, the unauthenticated pairing socket, deep-link input validation and on-disk content of mail subjects are the client-side security surface."
```
