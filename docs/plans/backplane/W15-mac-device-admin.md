# W15 — Pair a Device and Devices in the Mac app

## Refreshed 2026-10-18 against `origin/main` `d61c62d`

Versus the 2026-10-10 draft (read the memo's "What changed" and "Install
coordination"):
- Line references re-derived (`NostromodClient.swift`: `enum ServerMsg`
  `:144`, `sendHello` `:747-750` still at `protocolVersion: 4`,
  `featureTopics` `:780-787`, `send(_:type:)` `:1016`, `decode` `:1125`;
  `AppDelegate.setupMenu` `:218`). No protocol version change.
- **Human gesture.** The app's sensitive controls now pass through
  `HumanGesture.permit(NSApp.currentEvent, control:)`
  (`macOS/Nostromo/Security/HumanGesture.swift`, AP1). **Pair a Device…**'s
  code issuance, the **Will see mail and todos** checkbox (turning it on),
  each row's **Mail and todos** toggle (turning it on) and **Revoke** call it
  first and do nothing on `.refused`, so app-control and synthetic input
  cannot pair a device or widen a device's scope. No `keyEquivalent` on any
  of them.
- **Menu collisions.** AP3, BA3 and FV4 also edit `setupMenu`; do not run
  this wedge concurrently with them. New Mac files need `project.pbxproj`
  entries with ids prefixed `BP0000` (following the `AA0000…` style), so do
  not run it concurrently with AP2a, T1, terminal 1d, or any other slice
  that edits the Mac Xcode project.
- Tests run on GitHub Actions (`swift-tests-mac`, `make ci-remote
  ONLY=mac`); no local `xcodebuild`.

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
(`macOS/Nostromo/Data/NostromodClient.swift`, Hello at `:747-750`,
protocol version 4). So it needs no new transport. It sends these verbs to
its local daemon and renders the answers. W9 and W10 take care of the
primary, the relay, and Kobe's dial-out-only constraint.

Today the Mac app has no settings, pairing or devices UI. The app menu is
built in `macOS/Nostromo/AppDelegate.swift` `setupMenu` (`:218`). Standalone
windows follow the `NSWindowController` pattern in
`macOS/Nostromo/UI/CreateFocusSheet.swift:1-45`, and SwiftUI content is
hosted in AppKit elsewhere (`macOS/Nostromo/UI/MainLayout.swift`).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-mac-device-admin`
- **Base:** `origin/main` (W9 and W10 merged)
- **Max cost:** $35 (expected ≈ $14; see the memo's Estimate)

## Files to change

- `macOS/Nostromo/AppDelegate.swift` (`setupMenu`, `:218`) — add **Pair a
  Device…** and **Devices…** to the app menu, above Quit and below a
  separator. No new key equivalents (check the reserved-shortcut list in the
  agent-tracker and approvals design contracts; ⌥⌘A is AP3's).
  Each opens or brings forward a single window instance.
- `macOS/Nostromo/Data/NostromodClient.swift`:
  - `:144` (`enum ServerMsg`) — add cases `devicePairing`,
    `devicePairOutcome`, `devices`, `deviceRevoked` and `deviceAdminError`.
  - `:1125` (`decode`) — decode them with `Decodable` structs defined in
    a new `macOS/Nostromo/Data/DeviceWire.swift`. `DeviceSummary`: `id,
    name, kind, paired_at, last_seen_at, connected, sensitive, revoked_at`.
  - `:780` — add `"devices": "devices"` to `featureTopics`, so the
    topic is subscribed only when the daemon advertises it.
  - Add the senders `devicePairStart(sensitive:) -> requestId`,
    `devicePairUpdate`, `devicePairCancel`, `deviceList`, `deviceRevoke`
    and `deviceSetScope`, following the existing `send(_:type:)`
    (`:1016`). Keep the Hello at `protocolVersion: 4`; gate on
    `Welcome.features` containing `"devices"`.
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
- [ ] **W15-1** CI is green on GitHub Actions (`swift-tests-mac`, `swift-tests-kit`;
  re-run with `make ci-remote ONLY=mac`), including the three new test
  files. No local `xcodebuild`. Tests are hermetic (fake client, no daemon).
- [ ] **W15-2** `DeviceAdminModelTests` assert that a `.refused` human-gesture result
  sends nothing for pair, scope-on and revoke.
- [ ] **W15-3** No new transport, socket or listener in the Mac app. All admin traffic
  goes over the existing Unix socket to the local daemon.
- [ ] **W15-4** The Pair window never renders a code unless it holds a `DevicePairing`
  for its current `request_id`. A late `DevicePairing` for a cancelled
  request is ignored and cancelled.
- [ ] **W15-5** Closing either window leaves no open pairing on the primary (verified
  manually with `nostromo device list` showing no new device, and a
  device redeem then getting "That code isn't right").
- [ ] **W15-6** The `devices` topic is subscribed only when `Welcome.features` contains
  `"devices"`. Against an older daemon, both menu items show the
  unreachable message rather than hanging.
- [ ] **W15-7** Manual checks (operator, after `make mac-install` on each Mac; list results
  in the PR body or a follow-up comment; not Cody gates):
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
- [ ] **W15-8** PR body references the sequencing memo (W15) and the PRD.

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`). Assumes the repo's
`.mother/crew.yml` is merged before this job is added (it is read from the job's
base ref, so a worker can neither add nor loosen a gate).

- **Gates that apply:** `swift-ci` (`make ci-remote ONLY=swift`, `where: any`), `python-test` (always on; sandbox). The Rust gates are skipped (no Rust paths).
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to three fix attempts, then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`. `phi-security` is removed for this plan to save a lens run: it is not mandatory in this repo and this wedge adds no wire or trust. Lenses run
  in parallel with adherence on the gated commit once Mother PR #75 merges
  (open at the time of writing); until then run
  `mother review-lens <id> --lens <name>` on the PR's job, one lens at a time.
- **Review depth:** Lenses plus Mother's adherence review are enough here; no extra manual Perri pass beyond the `perri` entry below. Mac UI over W9/W10 verbs; no new wire, no new trust.
- **Checklist:** the acceptance items above carry ids (`W15-1` to `W15-8`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

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
lenses:
  add: [correctness, tests]
  remove: [phi-security]
```
