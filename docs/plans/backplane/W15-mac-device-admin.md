# W15 — Pair a Device and Devices in the Mac app

## Context

Ada's PRD `docs/prds/daemon-pairing-flow.md` (cited as PRD-ACn; read its
"Design-loop notes for Ada" too) makes the **Mac app** the primary place
where the operator pairs a phone or iPad, sees which devices can reach
Nostromo, revokes one, and turns a device's mail-and-todos access on or off.
That has to work from either Mac: Sendai at home, or Kobe, the managed work
laptop that may only dial out. The server itself (Tokyo) is headless.

The daemon side is already planned:
- **W9** (`docs/plans/backplane/W9-ws-transport.md`) puts the device
  registry and every pairing on the primary daemon. It adds admin verbs on
  the IPC protocol, each carrying a client-minted `request_id`:
  `DevicePairStart { name_hint, sensitive, satellite: None }`,
  `DevicePairUpdate { pairing_id, sensitive }`,
  `DevicePairCancel { pairing_id }`, `DeviceList`,
  `DeviceRevoke { device }`, `DeviceSetScope { device, sensitive }`.
- Their answers are: `DevicePairing { request_id, pairing_id, code,
  server_url, expires_at, sensitive }`; `DevicePairOutcome { pairing_id,
  outcome: paired{name,kind,sensitive} | expired | cancelled | locked_out |
  connection_lost }`; `DeviceRevoked { request_id, device_id,
  was_connected }`; `DeviceAdminError { request_id, reason }`; and live
  `Devices { devices }` broadcasts on topic `devices`. `Welcome.features`
  includes `"devices"`.
- A pairing is owned by the connection that started it and dies with it.
- **W10** (`W10-satellite-uplink.md`) makes Sendai and Kobe satellites. A
  satellite relays these verbs from its local clients up its outbound
  uplink to the primary, and answers `DeviceAdminError {
  server_unreachable }` at once when the uplink is down. It answers
  `not_permitted_on_this_mac` when the primary has limited that Mac's
  admin capability (`full | read_only | off`).

The Mac app talks only to its **local** daemon over the Unix socket
(`macOS/Nostromo/Data/NostromodClient.swift:459-620`, Hello at `:587-603`,
protocol version 4). So it needs no new transport. It sends these verbs to
its local daemon and renders the answers. W9 and W10 take care of the
primary, the relay, and Kobe's dial-out-only constraint.

Today the Mac app has no settings, pairing or devices UI. The app menu holds
only **Quit** (`macOS/Nostromo/AppDelegate.swift:136-148`). Standalone
windows follow the `NSWindowController` pattern in
`macOS/Nostromo/UI/CreateFocusSheet.swift:1-45`, and SwiftUI content is
hosted in AppKit elsewhere (`macOS/Nostromo/UI/MainLayout.swift`).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-mac-device-admin`
- **Base:** `origin/main` (W9 and W10 merged)

## Files to change

- `macOS/Nostromo/AppDelegate.swift:136-148` — add **Pair a Device…** and
  **Devices…** to the app menu, above Quit and below a separator. No new
  key equivalents (⌘⇧D is taken by `copyTranscriptDiagnostics`, `:171-176`).
  Each opens or brings forward a single window instance.
- `macOS/Nostromo/Data/NostromodClient.swift`:
  - `:133-216` (`enum ServerMsg`) — add cases `devicePairing`,
    `devicePairOutcome`, `devices`, `deviceRevoked` and `deviceAdminError`.
  - `:874-1075` (`decode`) — decode them with `Decodable` structs defined in
    a new `macOS/Nostromo/Data/DeviceWire.swift`. `DeviceSummary`: `id,
    name, kind, paired_at, last_seen_at, connected, sensitive, revoked_at`.
  - `:605-620` — add `"devices": "devices"` to `featureTopics`, so the
    topic is subscribed only when the daemon advertises it.
  - Add the senders `devicePairStart(sensitive:) -> requestId`,
    `devicePairUpdate`, `devicePairCancel`, `deviceList`, `deviceRevoke`
    and `deviceSetScope`, following the existing `send(_:type:)`
    (`:779`). Bump the Hello `protocolVersion` to 5 only if the daemon
    requires it for these verbs. W9 keeps `MIN_CLIENT_VERSION` at 2, so 4
    stays valid.
- `macOS/Nostromo/Data/DeviceAdminModel.swift` (new) — an
  `ObservableObject` owned by `AppStore`
  (`macOS/Nostromo/Data/AppStore.swift:153, 1027`). It routes the new
  `ServerMsg` cases. It holds `devices` (split into active and revoked),
  `adminAvailability` (`available | serverUnreachable |
  daemonNotRunning | readOnly | off`, derived from `client.connected`, the
  `devices` feature, and the last `DeviceAdminError`), and per-row
  transient status after a revoke. It also runs the one pairing session the
  Pair window shows. It exposes intent methods and no wire details, so it
  can be unit-tested with a fake client.
- `macOS/Nostromo/UI/PairDeviceWindow.swift` (new; `NSWindowController`
  hosting a SwiftUI view, after `CreateFocusSheet`):
  - **Issuing:** on open, send `DevicePairStart { sensitive: true }`.
    Never show a code until `DevicePairing` arrives.
  - **Showing:** a large QR of `server_url`'s `nostromo://pair?…` payload
    (CoreImage `CIQRCodeGenerator`, error-correction `M`, nearest-neighbour
    scaling), the server address from `server_url` (the primary's, never
    this Mac's, PRD-AC11), the code grouped `NNN NNN`, a countdown "Expires
    in m:ss" driven by `expires_at`, a checkbox **Will see mail and todos**
    (checked; toggling sends `DevicePairUpdate`), and **Cancel** (sends
    `DevicePairCancel`, closes).
  - **Outcomes, without user action:** `paired` → "Paired: <name>.
    Includes mail and todos" (or "Mail and todos are off") with **Done**,
    within 2 s of redemption (PRD-AC13). `expired` → "This code expired"
    with **New Code**. `locked_out` → "Too many wrong attempts. This code is
    no longer valid" with **New Code** (PRD-AC17). `connection_lost` → the
    copy pending Ada (design-loop note D3) with **New Code**.
  - **Unavailable** (`server_unreachable`, or the local daemon not running)
    → "Can't reach your Nostromo server, so this Mac can't make a pairing
    code right now." and no code (PRD-AC18). `not_permitted_on_this_mac` →
    copy pending Ada (open question 2).
  - Closing the window sends `DevicePairCancel` (the PRD's "Cancel"
    outcome; W9 cancels on disconnect anyway).
- `macOS/Nostromo/UI/DevicesWindow.swift` (new; same pattern) — a list
  with one row per active device: name, kind, "Paired <date>", last seen
  ("Connected now" when `connected`, else a relative time), a **Mail and
  todos** toggle (sends `DeviceSetScope`), and an inline **Revoke…**
  button. A separate **Revoked** section shows the revoke time
  (PRD-AC23). Opening it sends `DeviceList`, then follows `Devices`
  broadcasts live.
  - **Revoke…** opens a confirmation alert: "Revoke <name>? It will be
    disconnected immediately and will need to pair again." with
    **Revoke** / Cancel. On `DeviceRevoked`, the row (now in Revoked) shows
    "Disconnected just now" if `was_connected`, else "Wasn't connected. It
    will be refused the next time it tries." (PRD-AC24–26).
  - Click budget from an open app (PRD-AC24): app-menu title (1) →
    **Devices…** (2) → row **Revoke…** (3) → alert **Revoke** (4).
  - `readOnly` → the list shows, and the toggle and Revoke are disabled
    with a one-line explanation (copy pending Ada; only if the operator
    answers open question 2 "read-only").
  - Unreachable → the last list received, marked stale, under the "Can't
    reach your Nostromo server" line, with every control disabled.
- `macOS/NostromoTests/DeviceAdminModelTests.swift` (new) — a fake client
  drives the model: issue → pairing shown; paired/expired/locked_out/
  connection_lost transitions; the unreachable error shows no code; the
  checkbox sends `DevicePairUpdate`; revoke flows, with
  `was_connected` true/false text; the `Devices` broadcast regroups
  active/revoked; read-only disables actions.
- `macOS/NostromoTests/DeviceWireDecodingTests.swift` (new) — fixtures
  for each new frame. A `DeviceSummary` fixture containing an extra
  `token` key still decodes, and the model never stores or renders it.
- `macOS/NostromoTests/PairQRTests.swift` (new) — the generated QR decodes
  (`CIDetector` type QR) back to exactly the `nostromo://pair` URL.

## Approach

1. Wire structs and `decode` cases with fixture tests (the shapes are in
   W9's `src/ipc/protocol.rs`; copy fixture JSON from W9's Rust tests).
2. `DeviceAdminModel` with the fake client, TDD per outcome.
3. Menu items, then `PairDeviceWindow`, then `DevicesWindow`. Keep views
   thin, with all state in the model.
4. QR generation helper and its round-trip test.
5. Manual end-to-end on Kobe and Sendai against a primary with W9 and W10
   (see the acceptance criteria).

## Acceptance criteria

Behavioural criteria from the PRD delivered in the Mac app: PRD-AC11, AC12
(UI side), AC13, AC15, AC17 (issuer side), AC18, AC23 (Mac side), AC24,
AC25/AC26 (row status), AC35 (Mac toggle), AC37 (no credential on any Mac
surface).

Technical criteria:
- `make test` (or the CI macOS job, `.github/workflows/ci.yml:110+`) passes,
  including the three new test files.
- No new transport, socket or listener in the Mac app. All admin traffic
  goes over the existing Unix socket to the local daemon.
- The Pair window never renders a code unless it holds a `DevicePairing`
  for its current `request_id`. A late `DevicePairing` for a cancelled
  request is ignored and cancelled.
- Closing either window leaves no open pairing on the primary (verified
  manually with `nostromo device list` showing no new device, and a
  device redeem then getting "That code isn't right").
- The `devices` topic is subscribed only when `Welcome.features` contains
  `"devices"`. Against an older daemon, both menu items show the
  unreachable message rather than hanging.
- Manual checks (list results in the PR body):
  - On **Kobe** (satellite, WireGuard split-tunnel up), **Pair a Device…** →
    an iPhone scans → the window says "Paired: …" within 2 s; nothing
    listens off-loopback on Kobe (`lsof -iTCP -sTCP:LISTEN`) (PRD-AC12,
    AC13).
  - On Kobe with WireGuard off → **Pair a Device…** shows the unreachable
    message (PRD-AC18).
  - On Sendai, revoke a connected iPad in ≤ 4 clicks → the row says
    "Disconnected just now" within 1 s and the iPad shows the
    no-longer-paired screen within 5 s (PRD-AC24, AC25).
  - Toggle an iPad's **Mail and todos** off → its Fred/Teri tabs show the
    explanation within 5 s; on → content returns (PRD-AC35).
- PR body references the sequencing memo (W15) and the PRD.

## Out of scope

- Any Rust or iOS change (W9, W10, W11). If a needed frame is missing,
  stop and raise it rather than patching the daemon here.
- Renaming devices, satellite enrolment UI, and changing a satellite's
  `admin` capability (that is `nostromo device admin` on the primary only).
- Re-authenticating the operator before pair or revoke (PRD out of scope).
- A TUI pairing surface (PRD out of scope).
- Showing the `host` badge or multi-host Mother data in the Mac app.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Two AppKit-hosted SwiftUI windows and a model over an existing Unix-socket client; the protocol and relay are already built."
  redd:
    model: sonnet
    effort: medium
    rationale: "Model-level tests with a fake client cover every outcome; wire fixtures copied from W9."
  marty:
    model: sonnet
    effort: medium
    rationale: "Keep view code thin and the model the single source of state."
  perri:
    model: sonnet
    effort: high
    rationale: "Device admin from a managed laptop; check no code is shown without a live pairing and nothing secret is rendered or logged."
```
