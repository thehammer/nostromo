# W11 — iOS/iPadOS client over WebSocket with device pairing

## Refreshed 2026-11-24 against `origin/main` `4cafd5e8` (W9 as built)

W9 merged in #526 and #528. What the phone must fit, from the code:
- **D6 proof: pinned.** Use the vector in the W9 plan's "Pinned wire vector"
  section (checked in at `src/ipc/devices.rs:862-882`); details under
  "Sign-offs folded in", D6. Nothing about the encoding is open.
- **Same socket for proof and replace** (`src/ipc/pairing.rs:41-43`, `:321`):
  see D6 below.
- **Limits the client meets** (`src/ipc/ws.rs`): a pairing-only socket lives
  60 s (`:53`) and closes with 1009 on a frame over 4 KiB (`:68`); 20
  unauthenticated upgrades per address per minute, then HTTP 429 (`:56-57`);
  a 10 s handshake timeout and at most 8 unauthenticated sockets per address
  (`:89-97`); at most 8 authenticated sockets per device, the ninth closed
  with 1008 "too many connections" (`:530-538`); an upgrade carrying an
  `Origin` header gets HTTP 403 (`:354-356`), so the client must not set one
  (`URLSessionWebSocketTask` does not by default). A revoked or unknown token
  gets `Unauthorized { reason }` then close 4001 (`:50`).
- **Ordinals:** the client sends only existing verbs (`PairCheck` 98, `Pair`
  99, `DeviceUnpairSelf` 100); `CLIENT_MSG_VARIANTS` is 106
  (`src/ipc/peer.rs:2582`). W11 adds no verb.

## Refreshed 2026-11-23 against `origin/main` `8f0328b9`

Read the memo's "Readiness", bet **B11**, "CI prerequisites" and open
question 10 (Ada **D7**) first. Versus the 2026-10-18 version:
- **Merged turns (B11).** The iOS app already declares `merged_turns_v1`
  (NostromoKit's `ClientHello` default, `Shared/NostromoKit/Sources/
  NostromoKit/Wire/ClientMsg.swift:20`, sent from `Transport/NetworkClient.
  swift:232`) and draws a merged turn as stacked bubbles
  (`iOS/Nostromo/Views/TranscriptView.swift:224-243`, from #514). The new
  WebSocket client must send the same `Hello` (capability included) and keep
  that rendering. With B11 the daemon no longer needs the phone's
  declaration to merge, but declaring it keeps the phone honest if a later
  bet lets devices send. New criterion W11-15.
- **No queue view on the phone (D7, recommended local-only).** The queue
  frames are `LocalOnly` and the queue verbs `Refused` for every network
  trust, so the app shows no queued chips, no "sent together" header and no
  take-back. If Ada chooses option (c) (a count), it is a later additive
  field, not this wedge. New criterion W11-16 (nothing in the iOS target sends
  a `session_queue_*` verb).
- **MC4 is merged.** Kit's `NeedsYouAggregator` (`Shared/NostromoKit/Sources/
  NostromoKit/NeedsYou/NeedsYou.swift:142`) and `MotherNeedsYouProducer`
  (`:186`) exist; use them. The "if MC4 has not merged" fallback below is
  dead.
- **Tests.** If the iOS-T prerequisite (memo, "CI prerequisites") has merged,
  add hosted simulator tests for what Kit cannot run: the Keychain credential
  store (access group, delete on revoke), the `nostromo://pair` URL handler
  (`onOpenURL` routes to the confirmation step) and the content cache's file
  protection class. If it has not, keep the Kit-only tests and say so in the
  PR body (criterion W11-1 is unchanged either way).
- **Dispatch.** The AP/MC/terminal exclusions are gone (all merged); only
  "no other job editing `iOS/Nostromo.xcodeproj`" remains. The iOS app is 24
  Swift files (~5,200 lines); `NostromoApp.swift` is 261 lines and creates the
  `NetworkClient` at `:17` (the old `:15-46` range still brackets the
  `@main` scene). Re-derive other iOS line numbers on the base.

## Sign-offs folded in (2026-11-23: Ada's memo and the operator's decisions)

Ada signed off D1–D7 and the operator answered Q1–Q8 (memo, "Decision log
2026-11-23"). Ada is rewriting `docs/prds/daemon-pairing-flow.md` in parallel,
so this file cites decisions by id. Where a sentence below conflicts with the
older body text, this section wins. Nothing here waits on anyone any more.

- **D1, Local Network denied (fifth failure state).** Copy, verbatim, with the
  real address: **"Nostromo can't use your local network, so it can't reach
  10.0.0.5 on this Wi-Fi. Turn on Local Network for Nostromo in Settings, or
  use your VPN."** Buttons **Open Settings** (`UIApplication.
  openSettingsURLString`) and **Try Again**. It keeps the entered address and
  code, and does **not** use up the code (a denied attempt never reaches the
  daemon). After pairing, a denied connection shows the banner variant
  **"Nostromo can't use your local network to reach 10.0.0.5. Turn it on in
  Settings or use your VPN."** instead of the VPN banner, and never moves to
  the pairing or no-longer-paired screen. No pre-prompt screen before iOS's
  alert. The amended AC2: the app pairs and runs with camera permission denied
  (typed path), and with Local Network denied whenever the server is reached
  over the VPN, over cellular, or on another subnet. The Local Network alert
  can appear only after **Scan** or a typed submit, never on the first screen.
  Criteria W11-12, W11-17.
- **D2.** The three-action count (PRD AC3) counts operator actions inside the
  app; iOS's one-time camera and Local Network alerts are not counted. No
  code; the PR body says so when reporting W11-13.
- **D4, check before confirmation.** `PairCheck` runs right after a scan or
  typed submit; "expired", "wrong" and "can't reach" show **before** the
  confirmation step. The check never uses up the code. If the code expires or
  is cancelled between the check and **Pair**, tapping **Pair** shows the
  matching failure sentence and keeps the operator's edited name. Criterion
  W11-18.
- **D6, re-pairing an already-paired phone** (PRD AC57, AC58). "Same server"
  is decided only by the server proving it knows this device, never by
  address or `server_id` (both are unauthenticated). With a credential, after
  the first `PairCheck` returns `challenge`, the phone sends a second
  `PairCheck` with `proof = HMAC-SHA256(SHA-256(token), challenge ‖ code)`
  (W9). It never sends the token or its hash to a pairing socket. The
  encoding is pinned, not open: use the exact vector in the W9 plan's
  "Pinned wire vector: the re-pair proof (D6)" section, which W9 checked in as
  `the_proof_encoding_is_pinned_by_a_fixed_vector` in `src/ipc/devices.rs`
  (`:862-882`; `pairing_proof` `:661`, `proof_for_token` `:669`): key = the
  raw SHA-256 of the token's base64url text, message = the challenge's
  base64url text followed by the code's digits, proof = base64url without
  padding. Copy that vector into `PairingClientTests` (W11-19). The proof
  `PairCheck` and the later `Pair { replace: true }` MUST go over the SAME
  pairing socket (the daemon binds the verified proof to that connection,
  `src/ipc/pairing.rs:41-43`, `:321`); do not close or reopen it between
  them, or the old pairing is not replaced.
  - **Same server** (`knows_device: true`): the confirmation adds **"This
    replaces this iPhone's current pairing. The old one will be revoked."**
    On **Pair**, stop the current `WebSocketClient` and send `Pair { …,
    replace: true }`; on `Paired`, replace the Keychain item (the old entry
    moves to Revoked server-side and the name is kept). If `Pair` fails, keep
    the old credential, **restart the old client** and show the normal failure
    state.
  - **Lost credential** (no Keychain item, e.g. after a reinstall): there is
    nothing to prove, so it is a fresh pairing; the device is named "iPhone 2"
    and the old entry stays active until the operator revokes it from the
    Devices list. The success screen does not hide this (the name shows it).
  - **Different server** (`knows_device: false`, or no answer): the confirmation leads with a warning line in the
    alert style: **"This iPhone is paired with Nostromo at 10.0.0.5. Pairing
    with 10.0.0.9 disconnects it from 10.0.0.5 and removes its Nostromo
    content."** On **Pair**: wipe local content (`DaemonStore.wipeAll()`, as on
    revoke) and stop the old client, then send `Pair { replace: false }`. On
    `Paired`: if the old server is reachable, open a short authenticated
    socket with the old credential and send `DeviceUnpairSelf` (5 s budget;
    unreachable means the old entry goes stale, as with un-pair while
    unreachable); then save the new credential. If `Pair` fails, the old
    credential is kept, the old client is restarted (content refills from the
    old server), and the normal failure state shows.
  Criterion W11-19.
- **D7 / operator Q7: the phone shows nothing from the message queue in v1.**
  Already the plan (W11-16). No count either.
- **Q8 / Q3, one merged list.** Sort "needs you" first, then by recency,
  across hosts. Every row shows its Mac's name when the list holds rows
  (live or last-known) from more than one Mac; when every row comes from one
  Mac, no row does (PRD AC52; `Hosts` is not consulted). A work-host (Kobe)
  row shows only its host, its kind's reference and fixed phrases from the
  **same vocabulary as push** (PRD AC53): a Mother job as `Job 3f9a1c2e ·
  asked a question`; a PR as `PR #4821 · small change · 3 waiting` (no size
  phrase when unknown); a session or decision as the agent from the fixed set
  (or *A session*) and its state. Tapping it opens a card with
  that metadata and the line **"Details stay on kobe."**, never a blank screen
  or an endless spinner. The phrase table lives in Kit
  (`Shared/NostromoKit/Sources/NostromoKit/NeedsYou/ReasonPhrases.swift`,
  new), generated from one fixture `tests/fixtures/push-vocab/
  reason_phrases.json` (new) that W13's `vocab.rs` will assert against, so the
  app and the lock screen cannot drift. Its entries are the push PRD's
  phrases as W13 lists them: `paused_reason` `user` → *asked a question*,
  `adherence_blocked` → *blocked after review*, `operator_hold` → *held after
  a failure*, `cost_cap` → *paused at its spend cap*, `activity`
  `pipeline_blocked` → *pipeline blocked*, anything else → *needs you*. Criterion W11-20.
- **Operator Q2: mail, calendar and todos stay home in v1, with no way to
  turn sharing on** (PRD AC56). This wedge builds **no** per-device scope:
  no `sensitive` in the credential, cache or store, no `device_scope`
  handling, and the cache never holds Fred or Teri data. Final v1 copy (the
  PRD's "Final v1 copy" table): the Fred tab, the Teri tab and device
  Settings say **"Mail, calendar and todos stay on your Mac in this
  version."** (the tabs on `Withheld { reason: "not_shared" }`). Nothing else
  mentions mail, calendar or todos: not the confirmation, not the success
  screen ("Paired as" plus the final name). Criterion W11-21.
- **Transcripts.** Personal-host, non-sensitive, non-PHI transcripts stay
  read-only as today (`TranscriptView`, through the routed `SessionAttach`);
  Kobe, sensitive and PHI transcripts never: the row's card says "Details
  stay on kobe." and no attach is sent.
- **Operator Q4.** The phone answers nothing: decisions stay read-only with
  "Answer it on your Mac" (already W11-2).

## Refreshed 2026-10-18 against `origin/main` `d61c62d` (history)

Read `docs/plans/backplane-sequencing.md` first ("What changed since
2026-10-10", bets B9 and B10, "Install coordination"). Versus the
2026-10-10 draft of this file:
- `Hello` stays at `protocol_version: 4` (no daemon bump); the client keys
  every new behaviour off `Welcome.features` (`"ws"`, `"pair"`, `"hosts"`).
- No `host` on any `Pty*` or `MotherResume`/`MotherAction` message (the PTY
  host is gone; B10 routes no mutating verb). `host` appears only on the
  server frames W10 lists and on the routable read verbs.
- Rows from a `work` host (Kobe) are **metadata only** (state, 8-hex ref,
  reason, counts); the UI renders them without titles and never tries to
  open a Kobe transcript (the primary answers `HostUnavailable {
  egress_metadata }`).
- Approvals: the app shows "needs you" counts from `ApprovalPending` only;
  there is no approve/deny control anywhere on iOS (B10). Decisions stay
  read-only on iOS as today.
- Tests run on GitHub Actions (`swift-tests-kit`, iOS build), not locally.
- Edits `iOS/Nostromo.xcodeproj`: do not dispatch while an approvals,
  crew-client or terminal slice that edits an Xcode project is running.

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
- a pairing-only socket (`PairCheck { code, proof? }` → `PairOffer {
  name_hint, server_id, challenge, knows_device? }` or `PairRefused { expired
  | invalid }`; `Pair { code, name, kind, replace }` → `Paired { device_id,
  token, name, server_id, replaced }`);
- `Unauthorized { reason }` + close 4001 for a revoked or unknown token;
- `Withheld { reason: "not_shared" }` for the Fred, Teri and work topics
  (Q2; no per-device scope);
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
Settings with **Un-pair**. Bonjour stays only
as a legacy option in Settings. The macOS app is untouched (W15 does the Mac
side).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ios-ws-client`
- **Base:** `origin/main` (W9 merged; W10 merged for the `host` field)
- **Max cost:** $65 (expected ≈ $26; see the memo's Estimate; raised from $60
  on 2026-11-23 for D1's fifth state, D6's two re-pair paths and Q8's rows)

## Files to change

- `Shared/NostromoKit/Sources/NostromoKit/Transport/WebSocketClient.swift`
  (new) — the same public surface as `NetworkClient` (`@MainActor`,
  `@Published connected`, `messages: PassthroughSubject<ServerMsg, Never>`,
  `send(_:)`, `start()/stop()`), over `URLSessionWebSocketTask`. It builds
  `ws://<host>:<port>/` with the bearer header, then sends
  `Hello{protocol_version: 4}` and `Subscribe{topics: [],
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
  Stores `{token, deviceId, serverId, name}`: `load()`,
  `save(_:)`, `clear()`. It is protocol-typed so tests inject an in-memory
  store. It is **not** keyed by address, so changing the address keeps the
  pairing (PRD-AC33).
- `.../Transport/PairingClient.swift` (new) — opens a token-less WS and
  runs `check(code, proof?) -> PairOffer` and `pair(code, name, kind,
  replace) -> Paired`, plus `proof(token, challenge, code)` (pure, tested
  against W9's pinned vector: token, challenge and code `123456` give
  `ONMjmbNsnby-4Laxp33owC99gferbRJQsDdW6Ofz4cA`),
  with typed errors `expired`, `invalid`, `unreachable` and
  `localNetworkDenied`. `kind` comes from `UIDevice.userInterfaceIdiom`.
- `.../Transport/PairLink.swift` (new) — parse and validate
  `nostromo://pair?v=1&host=&port=&code=` (six digits only, port 1–65535,
  host non-empty). Pure; unit-tested.
- `.../Store/ContentCache.swift` (new) — persists the last-known snapshot
  the tabs render (`motherJobs`, `perriQueue`, `perriCurrentPr`, `focuses`,
  `sessions`, plus a `savedAt`; never Fred or Teri data, Q2) as one JSON file in Application Support, written atomically
  with `FileProtectionType.complete` and excluded from backup. Debounced
  writes (at most every 5 s). `wipe()` deletes the file synchronously.
- `.../Store/DaemonStore.swift:156-170, 293-400` — accept a transport
  protocol that both clients satisfy. Add `@Published pairingState` (from
  the client's `ConnectionState`) and `isStale`. Hydrate from
  `ContentCache` at init when a credential exists. On `.withheld(topics,
  reason: "not_shared")`, record the topics so the Fred and Teri tabs show
  the Q2 line (PRD-AC34). Add `wipeAll()`, which
  clears every published collection and calls `ContentCache.wipe()`. Keep
  jobs keyed by `(host, id)` so two hosts' queues merge without collision
  (one merged list; badges per PRD AC52, above). Rows whose host's
  `Hosts.egress == work` render state, ref and reason only and have no
  drill-in that would request content. Add `needsYouCount` per host from
  `ApprovalPending` counts plus Mother `awaiting` jobs; it is display-only.
  Do not write a second counter: feed Kit's `NeedsYouAggregator` (MC4,
  `Shared/NostromoKit/.../NeedsYou/`, built for iOS reuse) with a Mother
  producer (awaiting or held jobs plus unacked attention reasons) and an
  approvals producer (`ApprovalPending`), and read the per-host count from its
  snapshot (MC4 is merged; 2026-11-23). The phone shows the count and the reason only: no
  `ack`, no answer, no resume control (B10).
- `.../Wire/ClientMsg.swift` — add `pairCheck`, `pair`, `deviceUnpairSelf`
  and the optional `host` on `sessionAttach`/`sessionDetach`/
  `activitySnapshotRequest`/`sessionModelGet`/`sessionList`/`focusList`
  (the only verbs W10 routes).
- `.../Wire/ServerMsg.swift` — add `pairOffer`, `paired`, `pairRefused`,
  `unauthorized`, `deviceUnpaired`, `hosts` (with `egress`),
  `hostUnavailable` (with `reason`), and the optional `host` on
  `MotherJobs`, `MotherStatusline`, `SessionListResp`, `FocusListResp`,
  `ApprovalPending`, `PerriState`, `DecisionRequest`, `DecisionResolved`.
  Decode `withheld.reason`. Metadata-shaped frames from a `work` host decode
  with their text fields absent (every such field is already optional or
  must become optional with a test).
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
  device kind, the D6 replace or different-server line when it applies (no
  mail wording), and **Pair**
  (`.keyboardShortcut(.defaultAction)`) (PRD-AC7).
- `.../Pairing/PairingSuccessView.swift` (new) — "Paired as" and the final
  name, nothing about mail, showing `Paired.name` (the deduplicated name, PRD-AC9, AC10). It hands
  over to the tabs once the first `MotherJobs` arrives, or after 1.5 s,
  whichever is later.
- `.../Pairing/PairingErrorBanner.swift` (new) — the four PRD failure
  sentences verbatim, with the real address and device kind (PRD-AC19). A
  fifth state, `localNetworkDenied`, uses D1's signed-off copy with **Open
  Settings** and **Try Again** (see "Sign-offs folded in"). The entered
  address and code stay in place, and **Try Again** is one tap (PRD-AC20).
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
  withheld with reason `not_shared`: "Mail, calendar and todos stay on your
  Mac in this version." No spinner and no empty list (PRD-AC34).
- `iOS/Nostromo/Views/DeviceSettingsView.swift` (new; replaces the
  `ConnectionSettingsView` entry point, which stays reachable under
  "Advanced → Local network (legacy)"):
  - **Server address**, editable. On save, reconnect with the same
    credential. If the new address answers 4001, the normal
    no-longer-paired path applies (PRD-AC33).
  - This device's **name**, read-only, and the line "Mail, calendar and todos
    stay on your Mac in this version." (no control, PRD-AC36, AC56).
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
    Fred/Teri never written.
  - Extend `DaemonStoreTests.swift` (`not_shared` withheld yields the Q2
    state for the Fred and Teri tabs; `wipeAll()` empties every collection; hydrate from
    the cache marks `isStale`) and `MotherWireTests.swift` (fixtures with
    `host` present and absent).

## Approach

1. Wire types first (`ClientMsg`/`ServerMsg` additions, all optional or
   additive), then run the Kit tests in CI. Every existing fixture must still
   decode.
2. `DeviceCredential`, `PairLink`, `ContentCache`: pure or injectable, and
   unit-tested.
3. `PairingClient`, then `WebSocketClient`, each against the in-process WS
   listener. Mirror `NetworkClient`'s handshake and backoff constants.
   Replace the 3 s app ping with a WS ping at 20 s. Keep the failure
   classification (`notPaired` vs `unreachable`) in one function with a
   table-driven test. It guards PRD-AC22, the criterion most likely to
   regress quietly.
4. `DaemonStore`: transport protocol, cache hydration, `not_shared`
   handling, `wipeAll()`.
5. Views: the pairing flow, then the root state machine and `.onOpenURL`,
   then the no-longer-paired screen, the unreachable banner, and Settings.
6. Store keying by `(host, id)` and the host badge on every row (shown only
   when the rows come from more than one Mac, PRD AC52).
7. Build the iOS target and run the `NostromoKit` tests on GitHub Actions
   (`make ci-remote ONLY=kit` and `ONLY=ios`); do not run `swift` or
   `xcodebuild` locally (toolchain guard).

## Acceptance criteria

Behavioural criteria from the PRD delivered on the device: PRD-AC1–10,
AC19–22, AC25–27 (device side), AC30–34, AC36, AC52–58 (device side; AC35 is deferred by Q2), AC37
(device side). Those that need a real device and a live primary are listed
as manual checks.

Technical criteria:
- [ ] **W11-1** CI is green: `swift-tests-kit` and the iOS build job on GitHub Actions
  (re-run with `make ci-remote ONLY=kit` / `ONLY=ios`). No local `swift` or
  `xcodebuild`. Existing wire tests are unmodified apart from added
  fixtures. Tests are hermetic: the in-process `NWListener` on loopback, an
  in-memory credential store; no real server, VPN or camera.
- [ ] **W11-2** No iOS control sends `ApprovalAnswer`, `DecisionAnswer`, `MotherResume`
  or `MotherAction` over the WebSocket transport (a Kit test asserts the
  `WebSocketClient` refuses to encode them; B10).
- [ ] **W11-3** A `work`-host fixture (metadata-only `MotherJobs`, pseudonymous
  `ApprovalPending`) decodes and renders rows without titles.
- [ ] **W11-4** A fresh install (no Keychain item) opens **Pair with Nostromo**. No
  discovery sheet, no host/port form, and no permission prompt appear before
  **Scan Code** is tapped.
- [ ] **W11-5** The token lives only in the Keychain (`…ThisDeviceOnly`). It is never in
  UserDefaults, the content cache, logs, or any view (grep test over
  `os_log` capture in the client tests).
- [ ] **W11-6** Only `Unauthorized` or close code 4001 moves the app to the
  no-longer-paired state. A table-driven test proves that refused, timeout,
  DNS failure, network down, close 1001/1006 and HTTP 5xx at upgrade all
  yield `unreachable`.
- [ ] **W11-7** On `notPaired`, the credential is cleared, then the cache file is deleted,
  then the screen renders. After a relaunch, `ContentCache` has no file and
  `DaemonStore` is empty.
- [ ] **W11-8** The cache is written with `FileProtectionType.complete`, excluded from
  backup, and never contains Fred/Teri data.
- [ ] **W11-9** `Withheld { not_shared }` puts the Fred and Teri tabs in the Q2 state
  with no spinner or empty list; no Fred or Teri frame is ever decoded into
  the store (Kit test).
- [ ] **W11-10** After **Pair** on a reachable server, the first `MotherJobs` frame is
  rendered within 3 s (PRD-AC8).
- [ ] **W11-11** A `nostromo://pair` link with a malformed code or host shows an error and
  never sends anything.
- [ ] **W11-12** The app runs with Local Network permission denied whenever the server is
  reached through the VPN or a routed (non-Wi-Fi-subnet) address
  (PRD-AC2 as amended by design-loop note D1). When the server is on the
  same Wi-Fi subnet and access is denied, it shows the
  `localNetworkDenied` state, never "unreachable" and never the pairing
  screen.
- [ ] **W11-13** Manual checks (no stack tooling exists for iOS; list results in the PR
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
- [ ] **W11-14** PR body references the sequencing memo (W11) and the PRD.
- [ ] **W11-15** The WebSocket client's `Hello` carries `capabilities:
  ["merged_turns_v1"]` (a Kit encoding test), and a `SessionTurns` frame with
  two or more `user_parts` still renders as separate bubbles over the new
  transport (Kit decode test plus the existing iOS view path).
- [ ] **W11-16** No iOS or Kit code path used by the iOS target sends
  `session_queue_watch`, `session_queue_take_back` or `session_queue_remove`
  (an `ios_policy` source-scan case), per Ada D7 and operator Q7.
- [ ] **W11-17** D1: a Kit test maps a Local-Network-denied path probe to
  `localNetworkDenied` (never `unreachable`, never `notPaired`); the pairing
  error and the post-pairing banner use D1's two sentences verbatim with the
  real address; the code is not sent, so not used up.
- [ ] **W11-18** D4: the confirmation step renders only after a successful
  `PairCheck`; a `PairRefused { expired | invalid }` on **Pair** after a good
  check shows the matching failure and keeps the edited name (Kit test on the
  pairing flow model).
- [ ] **W11-19** D6 (PRD AC57, AC58): with an injected credential the phone sends a
  `proof` matching a fixed test vector and never its token or token hash on a
  pairing socket; `knows_device: true` produces the replace line and `Pair {
  replace: true }`; `false` or no answer (same `server_id` or not) produces
  the warning line, wipes content before `Pair`, and sends
  `DeviceUnpairSelf` to the old address with the old token after `Paired`; a
  failed `Pair` keeps the old credential and restarts the old client; with no
  credential no proof is sent.
- [ ] **W11-20** Q8 (PRD AC52, AC53): rows (live or last-known) from two Macs are
  sorted needs-you first then recency and all carry a host name, including
  with Kobe disconnected and only last-known Kobe rows; rows from one Mac
  carry none; Kobe Mother, PR, session and decision rows use only the fixed
  forms (Mother phrases from `ReasonPhrases`, generated from
  `tests/fixtures/push-vocab/reason_phrases.json`), with marker strings in
  title, question, branch, repository and session name appearing nowhere;
  the card says "Details stay on kobe." with no content request.
- [ ] **W11-21** Q2 (PRD AC56 and the "Final v1 copy" table): the Fred tab, Teri tab
  and Settings show exactly "Mail, calendar and todos stay on your Mac in this
  version."; no other iOS string mentions mail, calendar or todos (an
  `ios_policy` string scan); no control or setting can turn sharing on.

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`; rechecked at `0a38549` on
2026-11-23). The repo's `.mother/crew.yml` is on main since MC5 (#290): it is
read from the job's base ref, so a worker can neither add nor loosen a gate.

- **Gates that apply:** `swift-ci` (`make ci-remote ONLY=swift`, `where: any`), `python-test` (`where: any`, on the host, when its `when` paths match; `tests/**` and `Makefile` are among them). The Rust gates are skipped (no Rust paths).
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to two fix attempts (`max_attempts: 2`), then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `phi-security`. Lenses run
  automatically in parallel with adherence on the gated commit (Mother #75,
  merged since this was first written); the repo default is all four lenses
  (`.mother/crew.yml:61`), so only a `remove` entry changes anything.
- **Review depth:** Manual Perri pass: the normal `perri` entry below; the lenses add a second read on the wire/credential paths. Device credential storage, the D6 proof and the cache wipe on revoke.
- **Checklist:** the acceptance items above carry ids (`W11-1` to `W11-21`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- The Mac app (W15) and every daemon change (W9, W10).
- Push notifications / APNs registration (W13).
- `seq`/resume (W12); this client reconnects and relies on retained frames.
- Removing `NetworkClient`/Bonjour (deprecated, selectable under legacy).
- Renaming the device after pairing; pairing with more than one server at
  once (D6 replaces, it never adds); detecting whether the VPN is on (PRD out
  of scope).
- A queue count on session rows (D7 option (c)); a later additive field.
- Universal links (`https://` with an apple-app-site-association file);
  there is no public domain. The custom scheme is the deep link.
- Any control or setting that shares mail, calendar or todos (Q2).

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
    rationale: "Token storage, the unauthenticated pairing socket, deep-link validation, on-disk cache contents and the no-answer-from-iOS rule are the client-side surface."
lenses:
  add: [correctness, tests, phi-security]
  remove: []
```
