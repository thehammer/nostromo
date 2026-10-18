# W16 — iOS push enrichment: Notification Service Extension, on-phone enrichment for personal hosts, on-phone withdrawal

## Refreshed 2026-10-18 against `origin/main` `d61c62d`

Read `docs/plans/backplane-sequencing.md` first ("What changed since
2026-10-10", bets B9 and B10) and the push PRD's design-loop notes **turn 2**.
Versus the 2026-10-10 draft of this file:
- **Lock-screen decision actions are withdrawn** (push PRD sign-off S7, bet
  B10). AP1/AP1b made the verified Mac app, by a fresh human gesture, the
  only thing that may answer a decision; a phone is not that. So this wedge
  no longer adds per-choice notification actions, `DecisionAnswerResult`, the
  decision-resolution memory in `DecisionRegistry`, or the app-side
  `DecisionAnswer` sender, and the spike items about category registration
  and the action limit are gone. A decision notification's only action is
  **Open**, which shows the decision read-only with "Answer it on your Mac".
- **Enrichment is for `personal`, non-PHI items only** (sign-off S8, bet
  B9). A `work` satellite (Kobe) publishes metadata only, so the primary
  never holds a Kobe question, prompt or PR title to hand to the phone, and
  PHI-repo items are metadata-only from any host. Work-host enrichment
  toggles are therefore not built.
- No `PROTOCOL_VERSION` bump; the primary advertises `"push_detail"`.
  `ClientMsg::PushDetail` takes the next free ordinal (54 in the memo's
  inventory) and is `Paired`-only, self-scoped.
- Tests run in CI (Rust in the RWX sandbox; Kit and the iOS build with the
  embedded extension on GitHub Actions). Hermetic: fake transports, no APNs,
  no VPN, no device.
- Adds an iOS extension target to `iOS/Nostromo.xcodeproj`: obey the memo's
  dispatch exclusions (no concurrent Xcode-touching AP/MC/terminal slice).

## Context

W13 (`docs/plans/backplane/W13-push-relay.md`) delivers closed-vocabulary
notifications: kind, host, a short ref and fixed phrases, built on the
primary daemon (Tokyo) and sent through a stateless relay to APNs. The
product contract is `docs/prds/push-relay.md` (Ada's PRD), including its
"Design-loop notes for Ada" (S1–S8, C1–C8). This wedge builds the PRD's two
remaining phone-side bets that survive B9/B10:

1. **On-phone enrichment** for personal hosts. When the phone can reach the
   primary over WireGuard as a notification arrives, it replaces the
   contract text with the real first line (Mother question or PR title; a
   decision's prompt is not fetched: see below) within 5 s, fetched directly
   from the primary, never via the relay. On by default for `personal` hosts,
   with a per-host off switch per device. If the fetch does not finish in
   time, the contract text is shown unchanged. Never a spinner, blank or
   error. Work hosts and PHI-repo items always show contract text.
2. **Withdrawal without opening the app** within 2 minutes (S1), when Apple
   grants the filtering entitlement.
   It fires for every reason W13 removes an item, including an `ack` at the
   Mac (`attention_reasons[].acked` flipping on the primary, see W13
   "Acknowledgement and withdrawal"). W16 adds no phone-side ack or answer.

Decision prompts are not enriched on the lock screen: a decision's prompt and
choices are focus content that FND-1 classifies `Focus(tag)`, and showing them
invites answering from the phone, which B10 rules out. (If Ada wants
personal-host decision prompts enriched read-only, it is a one-line policy
change in `EnrichmentPolicy`; noted in S8.)

The mechanism is a **Notification Service Extension (NSE)**: a separate iOS
target that iOS runs for every alert push with `mutable-content: 1`, before
display, with about 30 s of wall time, a small memory budget and network
access through the WireGuard tunnel when it is up (it cannot bring the tunnel
up). It runs even after the app is force-quit and is not subject to the
background-push budget that makes W13's withdrawal best-effort. To hide its
own notification after a withdrawal, the NSE needs
`com.apple.developer.usernotifications.filtering`, which Apple grants on
request. The app reports per device whether the build has it, and the daemon
uses NSE withdrawal only for devices that do.

The iOS app has a single application target in
`iOS/Nostromo.xcodeproj/project.pbxproj` (hand-maintained, ids prefixed
`AA0000…`), an entitlements file from W13, the W11 Keychain credential
(`Shared/NostromoKit/Sources/NostromoKit/Transport/DeviceCredential.swift`)
and `URLSessionWebSocketTask` client (`.../Transport/WebSocketClient.swift`),
and W13's `PushPayload.swift` and `capabilities.nse_withdraw` (always
`false` before this wedge).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ios-push-enrichment`
- **Base:** `origin/main` (W13 merged)
- **Max cost:** $50 (expected ≈ $20; see the memo's Estimate)

## Files to change

Daemon (Rust):

- `src/ipc/protocol.rs`: add `ClientMsg::PushDetail { item_ref }` →
  `ServerMsg::PushDetail { item_ref, waiting: bool, text: Option<String>,
  host }`.
  - `text` is the first line, at most 140 chars, of the Mother job's
    `question` or the PR's `title`. Decisions always get `text: None`.
  - `text` is `None` unless **all** hold: the item's host egress is
    `personal` (W10 `Hosts.egress`, or the primary itself); the item is not
    PHI-scoped (W10 `is_phi_scoped`); the item is not on a sensitive tag
    (`SessionManager` sensitive tags) or a work-send job, unless the asking
    device's registry record has `sensitive: true`. The rule is the same one
    that decides what the device sees in the app.
  - FND-1: `PushDetail` (c→d) takes the next free ordinal (bump
    `CLIENT_MSG_VARIANTS`), `Refused` in `network_policy`, allowed by W9's
    `paired_extra_allowed` for `Paired` only; the reply is `Open`, targeted
    only. Add `"push_detail"` to `Welcome.features`.
- `src/push/mod.rs` (W13): serve `PushDetail` from the item map plus the
  retained snapshots. For devices with `capabilities.nse_withdraw == true`,
  `src/push/publisher.rs` sends:
  - every alert push with `mutable_content: true`;
  - each withdrawal as **one** `mutable-content` alert push at priority 10,
    title/body `Nostromo` / `Updated` (add both to `vocab.rs` and its
    allow-list test), with `data.withdraw`, `badge`, and
    `interruption_level: passive`.
  This replaces W13's badge-only + background pair for those devices.
- `src/push/devices.rs` (W13): `RegisterPush` gains `capabilities {
  nse_withdraw }`. Prefs gain `enrich: BTreeMap<host, bool>` for display
  only (enforcement is on the phone).

iOS:

- `iOS/NostromoNotificationService/NotificationService.swift` (new;
  `UNNotificationServiceExtension`) with its own `Info.plist`
  (`NSExtensionPointIdentifier = com.apple.usernotifications.service`) and
  `NostromoNotificationService.entitlements` (app group `group.<bundle id>`,
  the shared keychain access group, and
  `com.apple.developer.usernotifications.filtering` **only in the
  `Filtering` build configuration**). `didReceive(_:withContentHandler:)`:
  1. Parse `userInfo` with `PushPayload` (W13, NostromoKit).
  2. **Withdrawal** (`data.withdraw` present): `getDeliveredNotifications`,
     `removeDeliveredNotifications` for every request whose
     `userInfo["item"]` is listed, set the badge, deliver an empty
     `UNNotificationContent()` (filtered: nothing shown).
  3. **Enrich?** `EnrichmentPolicy.shouldEnrich(kind, host, hostEgress,
     devicePrefs)`: decision → never; `work` or unknown egress → never;
     `personal` → default on, per-host toggle overrides.
  4. Fetch with a hard **4.0 s total budget** via
     `PushDetailFetcher.fetch(itemRef, deadline:)`: a one-shot
     `URLSessionWebSocketTask` to the primary URL from the app group, the W11
     token from the shared keychain, `PushDetail`, close.
  5. On `waiting == false`: deliver the contract content and also remove it.
     On `text`: set `body`, moving the original body to `subtitle`.
  6. On budget expiry or any error, deliver the original contract content
     unchanged; `serviceExtensionTimeWillExpire` does the same.
  The NSE must not log notification text. Register the static categories
  `decision.open`, `mother`, `review` (Open only) from the app at launch.
- `Shared/NostromoKit/Sources/NostromoKit/Push/EnrichmentPolicy.swift`,
  `PushDetailFetcher.swift`, `NotificationContentComposer.swift` (new): pure
  or injectable, testable under the Kit tests without the extension host.
  `PushDetailFetcher` takes a transport protocol so tests use a fake that can
  stall past the deadline.
- `Shared/NostromoKit/Sources/NostromoKit/Transport/DeviceCredential.swift`
  (W11): move the Keychain item to the shared access group with a one-time
  migration from the app-only item. Store the primary URL, the last
  `Hosts.egress` map and per-host enrichment prefs in the app group's
  `UserDefaults(suiteName:)`, so the NSE can read them.
- `iOS/Nostromo/Views/NotificationSettingsView.swift` (W13): per-host "Show
  full details" toggles for `personal` hosts only (default on). Work hosts
  are listed with the fixed line "Details stay on <host>" and no toggle.
- `iOS/Nostromo.xcodeproj/project.pbxproj`: add the
  `NostromoNotificationService` app-extension target (ids prefixed
  `BP16…`), embed it in `Nostromo` (Embed App Extensions), link
  `NostromoKit`; add a `Filtering` build configuration that differs from
  `Release` only by the filtering entitlement; app-group and keychain-group
  entitlements on both targets.
- `iOS/Nostromo/Info.plist`: `NostromoPushFiltering` = `$(PUSH_FILTERING)`
  (YES only in `Filtering`); the app reads it to set
  `capabilities.nse_withdraw` in `RegisterPush`.

Tests:

- `Shared/NostromoKit/Tests/NostromoKitTests/EnrichmentPolicyTests.swift`:
  every kind × egress × toggle; decision never enriches; unknown egress =
  work.
- `.../PushDetailFetcherTests.swift` (fake transport): reply at 3.9 s →
  enriched; stall to 4.1 s → `nil` with the call returning by 4.05 s;
  connection refused → `nil` immediately; `waiting: false` surfaced.
- `.../NotificationContentComposerTests.swift`: contract + detail →
  expected title/subtitle/body; contract + `nil` → byte-identical contract.
  No code path produces placeholder or error text.
- `tests/push_detail.rs` (Rust): a `work`-host item, a PHI-repo item on a
  `personal` host, a decision, and a sensitive-tag item for a non-sensitive
  device all return `text: None`; a resolved item → `waiting: false`; an
  unknown `item_ref` → `waiting: false`, no text; `PushDetail` from a `Tcp`
  or `Satellite` peer is refused.
- `tests/push_engine.rs` (W13, extend): a device with `nse_withdraw`
  receives exactly one mutable-content withdrawal push (no background push),
  its strings passing `vocab::conforms`.

## Approach

1. **Spike on a physical device** (operator-assisted, throwaway; record the
   answer in the PR body): does NSE network traffic reach the primary through
   the WireGuard on-demand tunnel? If not, enrichment ships disabled behind
   its toggle and the PR says so. **Operator step, in parallel:** request
   `com.apple.developer.usernotifications.filtering` for the extension's
   bundle id. Until it is granted, ship `Release` (`nse_withdraw = false`).
2. Daemon: `PushDetail`, device capabilities, the mutable-content publisher
   path, tests.
3. NostromoKit pure pieces, TDD: policy, fetcher with deadline, composer.
4. Extension target, entitlements, shared keychain/app-group migration, NSE
   wiring.
5. Settings toggles.
6. Full suite in CI: RWX sandbox for Rust; `make ci-remote ONLY=kit` and
   `ONLY=ios` (the iOS build must succeed with the extension embedded). No
   local `cargo`, `swift` or `xcodebuild`.

## Acceptance criteria

Tests (Cody gates):

- [ ] **W16-1** CI is green: Rust in the RWX sandbox and the `ubuntu-latest` job; Kit
  tests and the iOS build (extension embedded) on GitHub Actions. No
  existing test is modified except W13's engine test, which is extended.
- [ ] **W16-2** `PushDetail` never returns text for a decision, a `work`-host item, a
  PHI-scoped item, or a sensitive-tag item to a device without `sensitive:
  true`.
- [ ] **W16-3** No code in the app or the extension sends `DecisionAnswer`,
  `ApprovalAnswer`, `MotherResume` or `MotherAction` (a Kit source-policy
  test greps the extension and push sources; B10). Decision notifications use
  the static Open-only category.
- [ ] **W16-4** The fetcher returns within 4.05 s in every case, and a `nil` fetch yields
  contract content byte-identical to the push.
- [ ] **W16-5** A device registered with `nse_withdraw: true` receives withdrawals as a
  single mutable-content push whose visible strings pass the W13 vocabulary
  allow-list; a device without it keeps W13's badge-only + background pair.

`[device]` (operator-verified on a physical iPhone with the VPN up, after
merge and after installing the new build and Tokyo's daemon; not Cody
gates):

- [ ] **W16-6** A Sendai (personal) Mother item shows the real question's first line
  within 5 s of arrival; the relay record and the W13 sent log show only the
  contract text.
- [ ] **W16-7** A Kobe (work) item and a decision always show contract text.
- [ ] **W16-8** With the VPN down, every notification shows exact contract text, with no
  intermediate state.
- [ ] **W16-9** Filtering build: answering a Mother question at the Mac removes the
  phone's notification and drops the badge within 2 minutes without opening
  the app, including after a force-quit.
- [ ] **W16-10** PR body records the NSE-over-WireGuard spike result and whether the
  filtering entitlement has been granted, and references
  `docs/prds/push-relay.md` and the sequencing memo (W16).

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`). Assumes the repo's
`.mother/crew.yml` is merged before this job is added (it is read from the job's
base ref, so a worker can neither add nor loosen a gate).

- **Gates that apply:** `rust-clippy` and `rust-test` (`where: sandbox`), `swift-ci` (`make ci-remote ONLY=swift`, `where: any`), `python-test` (always on; sandbox). 
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to three fix attempts, then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `phi-security`, `ops-infra`. Lenses run
  in parallel with adherence on the gated commit once Mother PR #75 merges
  (open at the time of writing); until then run
  `mother review-lens <id> --lens <name>` on the PR's job, one lens at a time.
- **Review depth:** Manual Perri pass: the normal `perri` entry below; the lenses add a second read on the wire/credential paths. New extension target, on-phone enrichment, a credential shared with the extension.
- **Checklist:** the acceptance items above carry ids (`W16-1` to `W16-10`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- Any action that answers anything from the phone (B10; S7).
- Enrichment for work hosts, PHI repos or decisions (B9; S8).
- Any change to what goes through the relay beyond the `Nostromo`/`Updated`
  withdrawal placeholder.
- Enrichment of Summary notifications; Live Activities; widgets; a
  Notification Content Extension.
- macOS notifications (Mother's and AP3's are unchanged).
- Bringing the WireGuard tunnel up from the extension.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "New extension target in a hand-maintained pbxproj, shared keychain migration and a hard time budget; smaller after the decision actions were withdrawn."
  redd:
    model: sonnet
    effort: high
    rationale: "Deadline-bounded fetcher, the egress/PHI/sensitivity policy matrix and the no-answer source policy need deterministic fakes."
  marty:
    model: sonnet
    effort: medium
    rationale: "NSE glue should end thin over NostromoKit units; keep extension and app sharing one composer."
  perri:
    model: sonnet
    effort: high
    rationale: "Leaks of work/PHI/sensitive text via PushDetail and any path that answers from the phone are the failure modes to hunt."
lenses:
  add: [correctness, tests, phi-security, ops-infra]
  remove: []
```
