# W15 — Pair a Device and Devices in the Mac app

## Refreshed 2026-11-23 against `origin/main` `8f0328b9`

Versus the 2026-10-18 version:
- **Line references re-derived** (`macOS/Nostromo/Data/NostromodClient.swift`):
  `enum ServerMsg` `:167`, `sendHello` `:992-995` (still `protocolVersion: 4`;
  its `ClientHello` now also sends `capabilities: [merged_turns_v1]`, `:18-27`),
  `featureTopics` `:1089`, `send(_:type:tag:)` `:1896`, `decode` `:2036`;
  `AppDelegate.setupMenu` `macOS/Nostromo/AppDelegate.swift:492`.
  `HumanGesture` is still `macOS/Nostromo/Security/HumanGesture.swift`.
- **Collisions now.** AP3, BA3, FV4, AP2a, T1 and terminal 1d are merged,
  and so is PR #518 (merged after this refresh, `1d30909a`). Do not run this
  wedge while any job edits `macOS/Nostromo.xcodeproj` or
  `NostromodClient.swift`. Newer menu owners to avoid: slash commands, session
  history (⌘N New Focus…, ⇧⌘N Resume Conversation…, #475) and the Mother
  Overview; pick a key equivalent for **Pair a Device…** only after checking
  `setupMenu` on the base (or none).
- **Cap $50** (was $35, then $45 because the comparable Mac UI slice, message
  queue S2, spent $39; $50 since the 2026-11-23 sign-offs).
- **Gates.** `swift-ci` (≈ 24 min, measured 2026-11-23 per #519, which set its
  timeout to 2400 s and is merged) and `python-test` (≈ 20 min; its `when`
  includes `macOS/**`, so crew delta 7 does not change it): ≈ 44 min per pass.

## Sign-offs folded in (2026-11-23: Ada's memo and the operator's decisions)

Ada signed off D1–D7 and the operator answered Q1–Q8 (memo, "Decision log
2026-11-23"). Ada is rewriting `docs/prds/daemon-pairing-flow.md` in parallel;
decisions are cited by id. This section wins over older body text. Nothing
here waits on anyone.

- **D3, the code dies with its window or connection.** Pair window copy on
  `connection_lost`: **"Lost the connection to your Nostromo server, so this
  code no longer works."** Button **New Code**, disabled with "Waiting for the
  server…" until the connection returns, then enabled. Never show a fresh code
  that cannot work (same rule as the unreachable state). Devices typing the
  dead code get the existing "That code isn't right"; no new device copy.
- **D5, lockout across two open codes.** Each open Pair window (and terminal)
  shows the existing "Too many wrong attempts. This code is no longer valid"
  with **New Code**. A model test drives two models sharing one fake daemon
  and asserts both reach `locked_out`.
- **D6, re-pair revokes the old entry.** A Revoked row whose `revoked_by` is
  `replaced` reads "Replaced by re-pairing" instead of a revoke time label; no
  control on it. The window does nothing else for D6 (W9 and W11 own it).
- **Operator Q2: mail, calendar and todos stay home in v1, with no way to
  turn sharing on** (pairing-PRD AC56). The Pair window shows exactly **"Mail,
  calendar and todos aren't shared from your Macs in this version."** with no
  checkbox; the paired line is "Paired:" and the name; the Devices window has
  no mail column or toggle. Nothing else in the Mac app mentions mail,
  calendar or todos (the PRD's "Final v1 copy" table). None of the checkbox,
  toggle or their verbs is built.
- **Operator Q1: the `revoke-only` level** (defined below). Kobe is enrolled at
  it by default.
- **S7a: the Mac reports "locked or idle" for decision pushes.** See "Operator
  presence reporter (S7a)" below. It is inert until W13's daemon advertises
  `"presence"`.

### Revoke-only device-admin level (Q1)

This is the definition the other wedges cite. Principle (Ada): actions that
reduce access are safe from any surface; actions that widen it come only from
surfaces the operator fully controls.

| Level | Sees the Devices list | Revoke | Pair a device |
|---|---|---|---|
| `full` (Sendai, set explicitly; the primary's own CLI) | yes | yes | yes |
| `revoke_only` (Kobe; also any satellite whose level was never set) | yes | yes | **no** |
| `read_only` | yes | no | no |
| `off` | no | no | no |

In v1 there is no mail-and-todos control at any level (Q2); the PRD's
"turn mail and todos off" for revoke-only applies once sharing exists
(later).

- **Where it is stored and enforced.** The level is the satellite's registry
  record on the primary (`admin`, W9), set with `nostromo device admin <host>
  full|revoke-only|read-only|off` or at enrolment (`--admin`; unset means
  `revoke_only` on either egress, so Sendai is enrolled with an explicit
  `--admin full`). A satellite's
  local `uplink.device_admin` may only lower it. The primary enforces it (W10).
- **Wire.** No new client verb and no new ordinal: `revoke_only` is a new value
  of the existing `admin` field, and the existing verbs carry the requests.
  One new server frame, `DeviceAdminLevel { level, pair_from }` (W10). It
  always reaches its own satellite over that satellite's uplink, at every
  level including `off`, and the satellite passes it to its local `devices`
  subscribers; it never goes to a `Paired`, `Tcp` or `Routed` peer or to
  another satellite. `DeviceAdminError { not_permitted_on_this_mac }` stays
  the refusal.
- **Network policy, per verb, for a relayed request at `revoke_only`:**
  `DeviceList` runs; `DeviceRevoke` runs; `DevicePairCancel` runs but only
  for a pairing that connection owns (so never, in practice);
  `DevicePairStart` is refused with no side effect. Every device-admin verb stays `Refused`
  for every network trust (`Tcp`, `Paired`, `Routed`), whatever the level.
- **Mac app.** `DeviceAdminModel.adminAvailability` gains `revokeOnly`, set
  from `DeviceAdminLevel` (and, as a fallback, from a
  `not_permitted_on_this_mac` answer to `DevicePairStart`). At `revokeOnly`:
  **Pair a Device…** stays in the menu and opens a window that shows no code
  and says **"Pairing new devices is turned off on this Mac. Pair from
  sendai or run `nostromo device pair` on your server."**, where `sendai` is
  `pair_from[0]` (with no `pair_from`, only the command sentence); it sends
  no `DevicePairStart`. In **Devices…**, **Revoke…** works and nothing else
  changes. At
  `readOnly` every control is disabled with "Changes are turned off on this
  Mac." At `off` the menu items show "Device management is turned off on this
  Mac."
- **Gestures.** Revoke and scope-off still pass `HumanGesture.permit` (an
  accidental revoke is a real cost even though it is safe).

### Operator presence reporter (S7a)

W13 pushes a decision at once when the Mac presenting it is locked, asleep or
idle for 2 minutes, and otherwise 30 s after it was raised if still unanswered
(Ada S7a). The signal exists on macOS and the app already computes it:
`AuthoredPrsDemandReporter` (`macOS/Nostromo/UI/Mother/
AuthoredPrsDemandReporter.swift`) observes `com.apple.screenIsLocked` /
`com.apple.screenIsUnlocked` (distributed notifications; widely used but not
documented by Apple), `NSWorkspace.willSleepNotification` /
`didWakeNotification`, and idle time through
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` (public
API; the app already calls it on Kobe and Sendai without any extra privacy
permission). The existing reporter treats 15 minutes as idle
(`idleThreshold = 900`, `AuthoredPrsDemandReporter.swift:24`); the new
reporter uses its own 2-minute threshold. **Sleep is best effort:** when the
Mac sleeps the daemon sleeps too, so an `away` frame sent at
`willSleepNotification` may never leave the Mac; W13's 30-second rule covers
that case. This wedge adds:
- `macOS/Nostromo/UI/Mother/OperatorPresenceReporter.swift` (new; a sibling,
  not a change to the demand reporter): levels `active | away`, where `away` =
  screen locked, or asleep, or `systemIdleSeconds() >= 120`. Re-evaluate every
  15 s and on every lock, unlock, sleep and wake notification; send only on
  change and again after each reconnect's welcome; no debounce on the change
  to `away` (it is the urgent direction), 1 s on the change to `active`. Reuse
  `AuthoredPrsDemandReporter.systemIdleSeconds()` and its injectable
  notification centres for tests.
- `NostromodClient.sendOperatorPresence(state:)`: `{"type":
  "operator_presence", "state": "active"|"away"}`, sent **only** when
  `Welcome.features` contains `"presence"` (W13 adds it). Until W13 merges it
  sends nothing, and W13 falls back to its 30-second rule.
- Owned by `AppStore` next to `authoredPrsDemand` (`AppStore.swift:99`).
- `macOS/NostromoTests/OperatorPresenceReporterTests.swift` (new): lock →
  `away` at once; unlock with fresh input → `active`; idle 119 s → `active`,
  121 s → `away`; nothing sent without the feature; re-sent after reconnect.

New criteria W15-9 to W15-12.

## Refreshed 2026-10-18 against `origin/main` `d61c62d` (history)

Versus the 2026-10-10 draft (read the memo's "What changed" and "Install
coordination"):
- Line references re-derived (`NostromodClient.swift`: `enum ServerMsg`
  `:144`, `sendHello` `:747-750` still at `protocolVersion: 4`,
  `featureTopics` `:780-787`, `send(_:type:)` `:1016`, `decode` `:1125`;
  `AppDelegate.setupMenu` `:218`). No protocol version change.
- **Human gesture.** The app's sensitive controls now pass through
  `HumanGesture.permit(NSApp.currentEvent, control:)`
  (`macOS/Nostromo/Security/HumanGesture.swift`, AP1). **Pair a Device…**'s
  code issuance and **Revoke** call it first and do nothing on `.refused`, so
  app-control and synthetic input cannot pair or revoke a device. No
  `keyEquivalent` on either. (*2026-11-24:* this paragraph used to list a
  **Will see mail and todos** checkbox and a per-row **Mail and todos**
  toggle; Q2 removed both, so there is no device scope to widen in v1. See
  "Sign-offs folded in".)
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
Nostromo, and revokes one (there is no mail-and-todos control in v1, Q2).
That has to work from either Mac: Sendai at home, or Kobe, the managed work
laptop that may only dial out. The server itself (Tokyo) is headless.

The daemon side is already planned:
- **W9** (`docs/plans/backplane/W9-ws-transport.md`) puts the device
  registry and every pairing on the primary daemon. It adds admin verbs on
  the IPC protocol, each carrying a client-minted `request_id`:
  `DevicePairStart { name_hint, satellite: None }`,
  `DevicePairCancel { pairing_id }`, `DeviceList`,
  `DeviceRevoke { device }`.
- Their answers are: `DevicePairing { request_id, pairing_id, code,
  server_url, expires_at }`; `DevicePairOutcome { pairing_id,
  outcome: paired{name,kind,replaced} | expired | cancelled | locked_out |
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
  admin capability (`full | revoke_only | read_only | off`).

The Mac app talks only to its **local** daemon over the Unix socket
(`macOS/Nostromo/Data/NostromodClient.swift`, Hello at `:992-995`,
protocol version 4). So it needs no new transport. It sends these verbs to
its local daemon and renders the answers. W9 and W10 take care of the
primary, the relay, and Kobe's dial-out-only constraint.

Today the Mac app has no settings, pairing or devices UI. The app menu is
built in `macOS/Nostromo/AppDelegate.swift` `setupMenu` (`:492`). Standalone
windows follow the `NSWindowController` pattern in
`macOS/Nostromo/UI/CreateFocusSheet.swift:1-45`, and SwiftUI content is
hosted in AppKit elsewhere (`macOS/Nostromo/UI/MainLayout.swift`).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-mac-device-admin`
- **Base:** `origin/main` (W9 and W10 merged)
- **Max cost:** $50 (expected ≈ $20; see the memo's Estimate; raised to $45
  on 2026-11-23 for the S2 comparison, then to $50 for the revoke-only UI and
  the S7a presence reporter)

## Files to change

- `macOS/Nostromo/AppDelegate.swift` (`setupMenu`, `:492`) — add **Pair a
  Device…** and **Devices…** to the app menu, above Quit and below a
  separator. No new key equivalents (check the reserved-shortcut list in the
  agent-tracker and approvals design contracts; ⌥⌘A is AP3's).
  Each opens or brings forward a single window instance.
- `macOS/Nostromo/Data/NostromodClient.swift`:
  - `:167` (`enum ServerMsg`) — add cases `devicePairing`,
    `devicePairOutcome`, `devices`, `deviceRevoked` and `deviceAdminError`.
  - `:2036` (`decode`) — decode them with `Decodable` structs defined in
    a new `macOS/Nostromo/Data/DeviceWire.swift`. `DeviceSummary`: `id,
    name, kind, paired_at, last_seen_at, connected, revoked_at, revoked_by`;
    also `DeviceAdminLevel { level, pair_from }`.
  - `:1089` — add `"devices": "devices"` to `featureTopics`, so the
    topic is subscribed only when the daemon advertises it.
  - Add the senders `devicePairStart() -> requestId`, `devicePairCancel`,
    `deviceList` and `deviceRevoke`, following the existing `send(_:type:)`
    (`:1896`). Keep the Hello at `protocolVersion: 4`; gate on
    `Welcome.features` containing `"devices"`.
- `macOS/Nostromo/Data/DeviceAdminModel.swift` (new) — an
  `ObservableObject` owned by `AppStore`
  (`macOS/Nostromo/Data/AppStore.swift:153, 1027`). It routes the new
  `ServerMsg` cases. It holds `devices` (split into active and revoked),
  `adminAvailability` (`available | serverUnreachable |
  daemonNotRunning | revokeOnly | readOnly | off`, derived from `client.connected`, the
  `devices` feature, and the last `DeviceAdminError`), and per-row
  transient status after a revoke. It also runs the one pairing session the
  Pair window shows. It exposes intent methods and no wire details, so it
  can be unit-tested with a fake client.
- `macOS/Nostromo/UI/PairDeviceWindow.swift` (new; `NSWindowController`
  hosting a SwiftUI view, after `CreateFocusSheet`):
  - **Issuing:** on open, send `DevicePairStart` (unless the level is below
    `full`).
    Never show a code until `DevicePairing` arrives.
  - **Showing:** a large QR of `server_url`'s `nostromo://pair?…` payload
    (CoreImage `CIQRCodeGenerator`, error-correction `M`, nearest-neighbour
    scaling), the server address from `server_url` (the primary's, never
    this Mac's, PRD-AC11), the code grouped `NNN NNN`, a countdown "Expires
    in m:ss" driven by `expires_at`, the line "Mail, calendar and todos
    aren't shared from your Macs in this version." (no checkbox), and
    **Cancel** (sends
    `DevicePairCancel`, closes).
  - **Outcomes, without user action:** `paired` → "Paired:" and the name,
    with **Done**,
    within 2 s of redemption (PRD-AC13). `expired` → "This code expired"
    with **New Code**. `locked_out` → "Too many wrong attempts. This code is
    no longer valid" with **New Code** (PRD-AC17). `connection_lost` → D3's
    copy with **New Code** disabled until the server is back.
  - **Unavailable** (`server_unreachable`, or the local daemon not running)
    → "Can't reach your Nostromo server, so this Mac can't make a pairing
    code right now." and no code (PRD-AC18). `revoke_only` or
    `not_permitted_on_this_mac` → the Q1 copy in "Revoke-only device-admin
    level (Q1)".
  - Closing the window sends `DevicePairCancel` (the PRD's "Cancel"
    outcome; W9 cancels on disconnect anyway).
- `macOS/Nostromo/UI/DevicesWindow.swift` (new; same pattern) — a list
  with one row per active device: name, kind, "Paired <date>", last seen
  ("Connected now" when `connected`, else a relative time), and an inline
  **Revoke…** button. A separate **Revoked** section shows the revoke time
  (PRD-AC23). Opening it sends `DeviceList`, then follows `Devices`
  broadcasts live.
  - **Revoke…** opens a confirmation alert: "Revoke <name>? It will be
    disconnected immediately and will need to pair again." with
    **Revoke** / Cancel. On `DeviceRevoked`, the row (now in Revoked) shows
    "Disconnected just now" if `was_connected`, else "Wasn't connected. It
    will be refused the next time it tries." (PRD-AC24–26).
  - Click budget from an open app (PRD-AC24): app-menu title (1) →
    **Devices…** (2) → row **Revoke…** (3) → alert **Revoke** (4).
  - `revokeOnly` and `readOnly` → as specified in "Revoke-only device-admin
    level (Q1)".
  - Unreachable → the last list received, marked stale, under the "Can't
    reach your Nostromo server" line, with every control disabled.
- `macOS/NostromoTests/DeviceAdminModelTests.swift` (new) — a fake client
  drives the model: issue → pairing shown; paired/expired/locked_out/
  connection_lost transitions; the unreachable error shows no code; revoke
  flows, with
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
AC25/AC26 (row status), AC37 (no credential on any Mac
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
  - On **Sendai** (enrolled `--admin full`), **Pair a Device…** → an iPhone
    scans → the window says "Paired: …" within 2 s (PRD-AC13).
  - On **Kobe** (revoke-only, WireGuard split-tunnel up; PRD open question
    4 answered yes on 2026-11-24): **Pair a Device…** shows the
    "Pairing new devices is turned off on this Mac" line; **Devices…** →
    **Revoke…** works; nothing listens off-loopback on Kobe (`lsof -iTCP
    -sTCP:LISTEN`) (PRD-AC12 as narrowed to "manage from Kobe", AC50).
  - On Kobe with WireGuard off → **Pair a Device…** shows the unreachable
    message (PRD-AC18).
  - On Sendai, revoke a connected iPad in ≤ 4 clicks → the row says
    "Disconnected just now" within 1 s and the iPad shows the
    no-longer-paired screen within 5 s (PRD-AC24, AC25).
- [ ] **W15-8** PR body references the sequencing memo (W15) and the PRD.
- [ ] **W15-9** Q1: with `DeviceAdminLevel { revoke_only }` the model sends no
  `DevicePairStart`, the Pair window shows the "Pairing new devices is turned
  off on this Mac" copy naming `pair_from`, and Revoke is sent; `read_only`
  and `off` (which the Mac does receive) disable as specified
  (`DeviceAdminModelTests`).
- [ ] **W15-10** D3 and D5: `connection_lost` shows D3's copy with **New Code**
  disabled until the client reconnects; two models over one fake daemon both
  reach `locked_out`; a `revoked_by: replaced` row reads "Replaced by
  re-pairing".
- [ ] **W15-11** Q2 (pairing-PRD AC56, "Final v1 copy"): the Pair window says exactly "Mail,
  calendar and todos aren't shared from your Macs in this version." with no
  checkbox, the Devices window has no mail column or toggle, and no other Mac
  string mentions mail, calendar or todos (a source-string test over the new
  files).
- [ ] **W15-12** S7a: `OperatorPresenceReporterTests` pass, and nothing is sent
  unless `Welcome.features` contains `"presence"`.

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
- **Reviewer lenses:** all four stay on (the repo default). `phi-security` is kept because the S7a presence reporter sends a new signal that changes push timing. Lenses run
  automatically in parallel with adherence on the gated commit (Mother #75,
  merged since this was first written); the repo default is all four lenses
  (`.mother/crew.yml:61`), so only a `remove` entry changes anything.
- **Review depth:** Lenses plus Mother's adherence review are enough here; no extra manual Perri pass beyond the `perri` entry below. Mac UI over W9/W10 verbs, plus the presence signal that W13 uses for push timing.
- **Checklist:** the acceptance items above carry ids (`W15-1` to `W15-12`) so
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
  add: [correctness, tests, phi-security]
  remove: []
```
