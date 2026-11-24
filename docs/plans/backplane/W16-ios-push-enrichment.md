# W16 — iOS push enrichment: Notification Service Extension and on-phone enrichment for personal hosts

## Refreshed 2026-11-24 against `origin/main` `4cafd5e8` (W9 as built)

Wins over the sections below where they differ.
- **Ordinal.** W9 shipped eight verbs, 98–105 (with `DeviceSetAdmin` at 105;
  `src/ipc/peer.rs:2685-2692`), so `CLIENT_MSG_VARIANTS` is 106 (`:2582`) and
  W13 takes 106–110 (push verbs 106–109, `OperatorPresence` 110). **`PushDetail`
  takes 111, and the constant goes 111 → 112.** Re-derive on the base.
- **There is no `paired_extra_allowed`** (removed in W9's follow-up, #528).
  `PushDetail` is `Refused` in `network_policy` and handled only for
  `(PeerTrust::Paired, Some(device_id))` by W13's push-engine pre-dispatch
  hook, which sits beside `DeviceHub::dispatch` at the pre-dispatch site in
  `handle_client` (`src/ipc/server.rs:1379-1395`; the pattern is
  `DeviceUnpairSelf`'s, `src/ipc/device_hub.rs:259-266`). Add `PushDetail` to
  that hook; it returns `NotHandled` for every other trust, so FND-1 refuses
  it. See W13, "Refreshed 2026-11-24".
- **`RegisterPush.capabilities` exists from W13** (W13 now puts
  `capabilities: PushCapabilities` on the verb, not only on the record); this
  wedge adds `nse: bool` to that struct (`#[serde(default)]`).
- **The extension cannot remove its own notification.** Step 5 of the
  extension's flow said it would "also remove" a notification that no longer
  needs the operator. An NSE must deliver a notification; suppressing or
  removing it needs Apple's notification-filtering entitlement, which is not
  being requested (memo, decision log). Corrected in place below.

## Refreshed 2026-11-23 against `origin/main` `8f0328b9`

Versus the 2026-10-18 version (read the memo's "What changed since
2026-10-18" and "CI prerequisites"):
- **Ordinal.** `ClientMsg::PushDetail` takes **110** (after W9's 98–104 and
  W13's 105–109, which since the 2026-11-23 sign-offs include
  `OperatorPresence` at 109), not 54; `CLIENT_MSG_VARIANTS` 110 → 111.
  Re-derive on the base.
- **Entitlement: not requested** (2026-11-23; see "Sign-offs folded in"). No
  Apple action gates this wedge.
- **Tests.** If the iOS-T prerequisite has merged, add the extension target to
  the shared scheme and cover the App Group and shared-keychain wiring with a
  hosted simulator test; the pure pieces stay in Kit as planned. If not, say
  so in the PR body.
- **Dispatch.** Only "no other job editing `iOS/Nostromo.xcodeproj`" remains
  of the old exclusions.

## Sign-offs folded in (2026-11-23: Ada's memo, the operator's decisions, the entitlement finding)

Memo, "Decision log 2026-11-23". Ada is rewriting `docs/prds/push-relay.md`
in parallel; decisions are cited by id. **This section wins over older text
below.** W16 waits for nothing but W13.

- **S1, withdrawal: the v1 mechanism is W13's, and it is the design, not a
  fallback.** Apple's Notification Service Extension Filtering entitlement
  (`com.apple.developer.usernotifications.filtering`) was investigated on
  2026-11-23 and is **not being requested**: the request form
  (developer.apple.com/contact/request/notification-service) needs the App
  Store URL and numeric Apple ID of a published app and one of four use cases
  (end-to-end encrypted messaging; earthquake warnings; education platforms
  retracting urgent alerts; healthcare professionals' patient-care alerts
  being retracted; location sharing is ineligible). Nostromo is a personal
  tool, not on the App Store, and none of those truthfully applies, so it
  must not be requested under one of them. Withdrawal therefore is:
  1. **Replace in place** (W13): the primary sends a passive alert with the
     same APNs collapse identifier, `Kind · host` / `ref no longer needs
     you`, and the corrected badge. Apple documents that notifications sharing
     a collapse identifier are shown to the user as one; that the passive
     replacement updates in place without lighting the screen is
     **unverified** until W13-26's device check.
  2. **Removal when the app runs** (W13): on launch and every foreground
     connect the app removes delivered notifications whose items are no longer
     waiting (including the "no longer needs you" ones) and sets the badge.
  3. **No silent (background) removal push in v1.** Ada's sign-off memo (S1)
     chose replace in place over best-effort removal, and the push PRD's v1
     withdrawal is replace in place plus removal when the app runs, with
     silent removal only as a later, optional enhancement (and a PRD test that
     the operator's machines never send a background push to remove a
     notification; W13-35). Background pushes are throttled and not delivered
     to a force-quit app anyway.
  W16 adds nothing to withdrawal except that the NSE must pass a
  replacement push (`data.resolved: true`) through **unenriched** and
  byte-identical (criterion W16-12).
- **The Filtering path is an optional later enhancement, off by default.**
  The `nse_withdraw` capability (W13, always `false`) and the NSE's
  withdrawal branch are cheap and stay, behind the flag, unit-tested in Kit.
  The `Filtering` build configuration and its entitlements file are kept only
  if they are a small `project.pbxproj` delta; if not, drop them and say so in
  the PR body. No shipped build sets `nse_withdraw = true`. Revisit only if
  Apple's categories ever fit.
- **S4: withdrawn** (moot under S7). No action-limit work.
- **S7 / operator Q4.** Open is the only action on every category; nothing
  answers from the phone (W16-3).
- **S8 as amended: personal-host decisions are enriched read-only.** For a
  decision from a `personal`, non-PHI host on a non-sensitive tag, in a
  repository whose owner is known and not a work owner, `PushDetail.text` is the first line of the
  prompt (≤ 140 chars) and the composer shows it as the body ending
  **" · answer on your Mac"**, with no choice buttons (the Open-only
  category). Ada's AC: with the VPN up, a decision from a personal, non-PHI
  host displays the first line of its prompt within 5 s, and the notification
  offers no choice actions. Criterion W16-11.
- **Operator Q3: work-host and PHI notifications never carry extra detail on
  the phone.** This reverses the operator's 2026-10-10 answer. `PushDetail`
  returns no text for them, and the settings screen lists each work host with
  "Details stay on" and its name ("Details stay on kobe") and no toggle.
- **Enrichment is owner-gated (Ada's PRD).** An item with no repository, or
  whose owner is unknown or a work owner, is treated as work: fixed text only.
  Owners come from W13 (S5): reviews from `owner/repo`, Mother jobs only from
  `pr_url`, decisions from the focus's `origin` remote. So on Sendai extra
  detail appears only for Mother jobs and decisions in a known non-work-owner
  repository, never for today's reviews (all Carefeed).
- **The extension must actually run (mutable content).** iOS runs a
  Notification Service Extension only for an alert push that carries
  `mutable-content: 1`. `RegisterPush.capabilities` gains `nse: bool`, which
  W16 builds set to `true`; for such a device the publisher sets
  `mutable_content: true` on **every** alert push (independent of
  `nse_withdraw`), and the extension passes through anything it does not
  enrich unchanged. Criterion W16-13. (Ada's caveat for the operator:
  keep Carefeed checkouts other than the two PHI repositories off Sendai, or
  classify Sendai as work.)

## Refreshed 2026-10-18 against `origin/main` `d61c62d` (history)

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
  `ClientMsg::PushDetail` takes the next free ordinal (111 as of
  2026-11-24; the memo's wire inventory) and is `Paired`-only, self-scoped.
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
   contract text with the real first line (Mother question, PR title, or a
   decision's prompt read-only per S8 as amended; owner-gated) within 5 s, fetched directly
   from the primary, never via the relay. On by default for `personal` hosts,
   with a per-host off switch per device. If the fetch does not finish in
   time, the contract text is shown unchanged. Never a spinner, blank or
   error. Work hosts and PHI-repo items always show contract text.
2. *(2026-11-23: withdrawn from this wedge.)* Silent withdrawal needed
   Apple's filtering entitlement, which is not being requested; W13's
   replace-in-place is the v1 withdrawal (see "Sign-offs folded in").

Decision prompts on personal, non-PHI hosts **are** enriched, read-only,
ending "· answer on your Mac" (S8 as amended); choices are never shown and
there are no answer actions (B10).

The mechanism is a **Notification Service Extension (NSE)**: a separate iOS
target that iOS runs for every alert push with `mutable-content: 1`, before
display, with about 30 s of wall time, a small memory budget and network
access through the WireGuard tunnel when it is up (it cannot bring the tunnel
up). It runs even after the app is force-quit. (Hiding its own notification
would need the filtering entitlement, which is not being requested; see
"Sign-offs folded in".)

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
    `question`, the PR's `title`, or (S8 as amended) the decision's
    `prompt`; never `detail` or choice labels.
  - `text` is `None` unless **all** hold: the item's host egress is
    `personal` (W10 `Hosts.egress`, or the primary itself); the item is not
    PHI-scoped (W10 `is_phi_scoped`); the item is not on a sensitive tag
    (`SessionManager` sensitive tags) or a work-send job; and the item's
    repository owner is known and not in `push.work_owners` (W13, S5). The
    rule never exceeds what the device sees in the app.
  - FND-1: `PushDetail` (c→d) takes the next free ordinal (111; bump
    `CLIENT_MSG_VARIANTS` to 112), `Refused` in `network_policy`, handled for
    `Paired` only by W13's push-engine pre-dispatch hook beside
    `DeviceHub::dispatch` (`server.rs:1379-1395`); the reply is `Open`,
    targeted only. Add `"push_detail"` to `Welcome.features`.
- `src/push/mod.rs` (W13): serve `PushDetail` from the item map plus the
  retained snapshots. **Optional, off by default** (see "Sign-offs folded
  in"): for devices with `capabilities.nse_withdraw == true`, which no shipped
  build sets, `src/push/publisher.rs` sends:
  - every alert push with `mutable_content: true`;
  - each withdrawal as **one** `mutable-content` alert push at priority 10,
    title/body `Nostromo` / `Updated` (add both to `vocab.rs` and its
    allow-list test), with `data.withdraw`, `badge`, and
    `interruption_level: passive`.
  This replaces W13's replace-in-place push for those devices only.
- `src/push/publisher.rs` (W13): for a device whose `capabilities.nse` is
  `true`, set `mutable_content: true` on every alert push (originals and W13
  replacements), whatever `nse_withdraw` says.
- `src/push/devices.rs` (W13): `RegisterPush` gains `capabilities { nse,
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
  2. **Withdrawal** (optional Filtering path only; `data.withdraw` present;
     without the filtering entitlement an extension cannot hide its own
     notification, so this branch never runs in a shipped build): `getDeliveredNotifications`,
     `removeDeliveredNotifications` for every request whose
     `userInfo["item"]` is listed, set the badge, deliver an empty
     `UNNotificationContent()` (filtered: nothing shown).
  3. **Enrich?** `EnrichmentPolicy.shouldEnrich(kind, host, hostEgress,
     devicePrefs)`: `data.resolved` (a W13 replacement) → never; `work` or
     unknown egress → never; `personal` → default on (decisions included,
     read-only, S8), per-host toggle overrides.
  4. Fetch with a hard **4.0 s total budget** via
     `PushDetailFetcher.fetch(itemRef, deadline:)`: a one-shot
     `URLSessionWebSocketTask` to the primary URL from the app group, the W11
     token from the shared keychain, `PushDetail`, close.
  5. On `waiting == false`: deliver the contract content unchanged. The
     extension cannot suppress or remove its own notification (that needs
     Apple's filtering entitlement, which is not requested); the stale
     notification is replaced by W13's withdrawal push (same collapse id) and
     removed when the app next runs.
     On `text`: set `body`, moving the original body to `subtitle`; for a
     decision the body is `<text> · answer on your Mac`.
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
  are listed with the fixed line "Details stay on" plus the host name
  ("Details stay on kobe") and no toggle.
- `iOS/Nostromo.xcodeproj/project.pbxproj`: add the
  `NostromoNotificationService` app-extension target (ids prefixed
  `BP16…`), embed it in `Nostromo` (Embed App Extensions), link
  `NostromoKit`; add a `Filtering` build configuration that differs from
  `Release` only by the filtering entitlement (optional, see "Sign-offs
  folded in"); app-group and keychain-group
  entitlements on both targets.
- `iOS/Nostromo/Info.plist`: `NostromoPushFiltering` = `$(PUSH_FILTERING)`
  (YES only in `Filtering`); the app reads it to set
  `capabilities.nse_withdraw` in `RegisterPush`.

Tests:

- `Shared/NostromoKit/Tests/NostromoKitTests/EnrichmentPolicyTests.swift`:
  every kind × egress × toggle; a personal-host decision enriches; a
  replacement (`resolved`) never does; unknown egress = work.
- `.../PushDetailFetcherTests.swift` (fake transport): reply at 3.9 s →
  enriched; stall to 4.1 s → `nil` with the call returning by 4.05 s;
  connection refused → `nil` immediately; `waiting: false` surfaced.
- `.../NotificationContentComposerTests.swift`: contract + detail →
  expected title/subtitle/body; contract + `nil` → byte-identical contract.
  No code path produces placeholder or error text.
- `tests/push_detail.rs` (Rust): a `work`-host item (decision included), a
  PHI-repo item on a `personal` host, a sensitive-tag item, a Mother job with
  a bare `repo` and no `pr_url`, and a Carefeed review on Sendai all return
  `text: None`; a personal, non-PHI decision
  returns the prompt's first line and never `detail` or a choice label; a resolved item → `waiting: false`; an
  unknown `item_ref` → `waiting: false`, no text; `PushDetail` from a `Tcp`
  or `Satellite` peer is refused.
- `tests/push_engine.rs` (W13, extend): a device with `nse: true` gets
  `mutable_content: true` on every alert push and one with `nse: false` gets
  none; a device with `nse_withdraw` (test only; optional path) receives exactly one mutable-content withdrawal push,
  its strings passing `vocab::conforms`; a default device still gets W13's
  replacement push.

## Approach

1. **Spike on a physical device** (operator-assisted, throwaway; record the
   answer in the PR body): does NSE network traffic reach the primary through
   the WireGuard on-demand tunnel? If not, enrichment ships disabled behind
   its toggle and the PR says so. Ship `Release` (`nse_withdraw = false`);
   the filtering entitlement is not requested ("Sign-offs folded in").
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

- [ ] **W16-1** CI is green: Rust in the RWX sandbox and the `ubuntu-24.04` Rust jobs; Kit
  tests and the iOS build (extension embedded) on GitHub Actions. No
  existing test is modified except W13's engine test, which is extended.
- [ ] **W16-2** `PushDetail` never returns text for a `work`-host item, a PHI-scoped
  item, a sensitive-tag item, or an item whose owner is unknown or a work
  owner, and never returns a decision's `detail` or choice labels.
- [ ] **W16-3** No code in the app or the extension sends `DecisionAnswer`,
  `ApprovalAnswer`, `MotherResume` or `MotherAction` (a Kit source-policy
  test greps the extension and push sources; B10). Decision notifications use
  the static Open-only category.
- [ ] **W16-4** The fetcher returns within 4.05 s in every case, and a `nil` fetch yields
  contract content byte-identical to the push.
- [ ] **W16-5** (Optional path, test only.) A device registered with
  `nse_withdraw: true` receives withdrawals as a single mutable-content push
  whose visible strings pass the W13 vocabulary allow-list; every shipped
  configuration registers `nse_withdraw: false` and keeps W13's
  replace-in-place push.

`[device]` (operator-verified on a physical iPhone with the VPN up, after
merge and after installing the new build and Tokyo's daemon; not Cody
gates):

- [ ] **W16-6** A Sendai (personal) Mother item in a known non-work-owner repository
  (a job with a personal `pr_url`) shows the real question's first line
  within 5 s of arrival; the relay record and the W13 sent log show only the
  contract text.
- [ ] **W16-7** A Kobe (work) item, including a Kobe decision, always shows contract
  text.
- [ ] **W16-8** With the VPN down, every notification shows exact contract text, with no
  intermediate state.
- [ ] **W16-9** With the NSE embedded, answering a Mother question at the Mac still
  replaces the phone's notification with "… no longer needs you" and drops
  the badge within 2 minutes without opening the app, including after a
  force-quit (the NSE passes the replacement through unchanged).
- [ ] **W16-10** PR body records the NSE-over-WireGuard spike result and whether the
  optional `Filtering` configuration was kept or dropped, and references
  `docs/prds/push-relay.md` and the sequencing memo (W16).
- [ ] **W16-11** S8 as amended: with the VPN up, a decision from a personal, non-PHI
  host shows the first line of its prompt ending " · answer on your Mac"
  within 5 s, and the notification offers no choice actions (Kit composer
  test; `[device]` check on a physical iPhone).
- [ ] **W16-12** The NSE delivers a W13 replacement push (`data.resolved: true`)
  byte-identical and unenriched (Kit composer test).
- [ ] **W16-13** A device registered with `capabilities.nse: true` receives
  `mutable_content: true` on every alert push, independent of
  `nse_withdraw` (engine test), so W16-6 and W16-11 can pass; the extension
  passes unenriched pushes through byte-identical.

## Mother crew: gates, lenses, checklist and calibration

Adopts the Mother features summarised in the memo's "Mother features adopted"
(read from Mother `origin/main` `e597389`; rechecked at `0a38549` on
2026-11-23). The repo's `.mother/crew.yml` is on main since MC5 (#290): it is
read from the job's base ref, so a worker can neither add nor loosen a gate.

- **Gates that apply:** `rust-clippy` and `rust-test` (`where: sandbox`), `swift-ci` (`make ci-remote ONLY=swift`, `where: any`), `python-test` (`where: any`, on the host, when its `when` paths match; `tests/**` and `Makefile` are among them). 
  Mother runs them on the pushed head after the worker exits: sandbox gates
  through `rwx sandbox reset` / `exec` / `stop`, `swift-ci` as a plain command
  from the job worktree. Gate commands never go through the worker's Bash tool,
  so the toolchain guard does not apply to them. The worker still runs the same
  commands itself before opening the PR (`rwx sandbox exec -- ...`,
  `make ci-remote ...`) and never runs `cargo` or `xcodebuild` locally. In
  observe mode a red gate is recorded, not enforced, so the criteria above remain
  the contract; if the repo has been promoted to enforce by dispatch time, the
  same worker session gets up to two fix attempts (`max_attempts: 2`), then a `gate_hold`.
- **Reviewer lenses:** the plan's yaml block adds `correctness`, `tests`, `phi-security`, `ops-infra`. Lenses run
  automatically in parallel with adherence on the gated commit (Mother #75,
  merged since this was first written); the repo default is all four lenses
  (`.mother/crew.yml:61`), so only a `remove` entry changes anything.
- **Review depth:** Manual Perri pass: the normal `perri` entry below; the lenses add a second read on the wire/credential paths. New extension target, on-phone enrichment, a credential shared with the extension.
- **Checklist:** the acceptance items above carry ids (`W16-1` to `W16-13`) so
  `mother add` seeds Mother's checklist and the progress figure can use it. The
  worker ticks each with `mother check <job> --done --evidence <short ref>` only
  when its test or check has passed.
- **Calibration record** (for `mother retro`; see the memo's Estimate): after the
  job, note the job id, actual cost and active time against the numbers in the
  Target section, the ETA band shown at about 50% and whether the job landed in
  it, gate time per pass and attempts used, and any `moved_back` reason.

## Out of scope

- Any action that answers anything from the phone (B10; S7).
- Enrichment for work hosts or PHI repos (B9; S8; operator Q3).
- Requesting the filtering entitlement, or any silent (background) removal
  push (S1).
- Any change to what goes through the relay beyond the optional
  `Nostromo`/`Updated` withdrawal placeholder.
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
