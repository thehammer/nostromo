# W16 — iOS push enrichment: Notification Service Extension, lock-screen decision actions, on-phone withdrawal

## Context

W13 (`docs/plans/backplane/W13-push-relay.md`) delivers closed-vocabulary
notifications: kind, host, a short ref, and fixed phrases, built on the
primary daemon and sent through a stateless relay to APNs. The product
contract is `docs/prds/push-relay.md` (Ada's PRD). Read it whole, including
its closing **"Design-loop notes for Ada"**, which records the operator's
answers and sign-offs S1–S6 and clarifications C1–C8. The PRD has three
**ambitious bets** that need code on the phone, and this wedge builds them:

1. **On-phone enrichment.** When the phone can reach the operator's machines
   over the WireGuard VPN as a notification arrives, the phone replaces the
   contract text with the real content within 5 s. The content is the first
   line of the Mother question, the decision prompt, or the PR title. It is
   fetched directly from the primary, never via the relay. Defaults:
   - **on** for personal hosts;
   - **off** for work hosts, opt-in **per host, per device**.
   The operator confirmed that Carefeed content on the personal phone's screen
   is allowed (PRD notes, operator answer 2). If the fetch does not finish in
   time, the contract text is shown unchanged. There is never a spinner,
   blank or error.
2. **Lock-screen decision actions.** Long-pressing a decision notification
   shows one button per choice, with real labels fetched on the phone. A
   button requires an unlocked device and answers the decision on its host.
   The notification then becomes `Answered: <label>`. If the answer fails, a
   local notification within 10 s says *unreachable*, *already resolved* or
   *timed out*. With the VPN down, or when there are more choices than iOS
   can show (S4), the only action is **Open**.
3. **Withdrawal without opening the app.** When an item is resolved
   elsewhere, its notification disappears within 2 minutes (S1).

The mechanism for all three is a **Notification Service Extension (NSE)**: a
separate iOS target that iOS runs for every alert push with
`mutable-content: 1`, before display. It gets about 30 s of wall time, a small
memory budget, and network access (its traffic uses the WireGuard tunnel when
the tunnel is up; it cannot bring the tunnel up). It runs even when the app
has been force-quit, and it is not subject to the background-push budget that
makes W13's background-push withdrawal best-effort. To hide its own
notification after a withdrawal, the NSE needs
`com.apple.developer.usernotifications.filtering`. Apple grants that
entitlement on request. The app reports per device whether the build has it,
and the daemon only uses NSE withdrawal for devices that do.

The iOS app today has a single application target
(`iOS/Nostromo.xcodeproj/project.pbxproj:155-176`, product type
`com.apple.product-type.application`), no entitlements file before W13, and no
notification code before W13. W11 stores the device token in the Keychain
(`Shared/NostromoKit/Sources/NostromoKit/Transport/DeviceCredential.swift`)
and talks to the primary over `URLSessionWebSocketTask`
(`.../Transport/WebSocketClient.swift`). W13 adds `PushPayload.swift`,
registration, and `capabilities.nse_withdraw` (always `false` before this
wedge).

## Target
- **Repo:** nostromo
- **Branch:** `feat/backplane-ios-push-enrichment`
- **Base:** `origin/main` (W13 merged)

## Files to change

Daemon (Rust):

- `src/ipc/protocol.rs`: add `ClientMsg::PushDetail { item_ref }` →
  `ServerMsg::PushDetail { item_ref, waiting: bool, text: Option<String>,
  choices: Option<Vec<DecisionChoice>>, host, request_id: Option<String> }`.
  - `text` is the first line, at most 140 chars, of: the Mother job's
    `question`; the decision's `prompt`; or the PR's `title`.
  - `choices` is present for decisions only.
  - The reply is **scoped to the asking device**: an item on a sensitive tag
    (Teri/Fred focus, `SessionManager::sensitive_tags`,
    `src/ipc/session_manager.rs:365`) returns `text: None, choices: None`
    unless that device's W9 registry record has `sensitive: true`. The rule is
    the same one that decides what the device sees in the app.
  Also add `ServerMsg::DecisionAnswerResult { request_id, outcome: answered |
  already_resolved | timed_out | unknown }`, sent targeted to the answering
  connection from the `ClientMsg::DecisionAnswer` handler
  (`src/ipc/server.rs:1093-1115`; today `AlreadyAnswered`/`UnknownRequest`
  only log). When the answer is routed to a satellite (W13's
  `DecisionAnswer.host`), the result comes back the same way.
- `src/ipc/decisions.rs:102-136` (`DecisionRegistry`): the `resolved` set
  remembers *how* each id was resolved, so `timeout_request` is
  distinguishable from an answer. Make it a bounded map (last 1024 ids).
  `answer` returns `AlreadyAnswered { how }`, so the answerer can be told
  *timed out* vs *already resolved*.
- `src/push/mod.rs` (W13): the engine serves `PushDetail` from its item map
  plus the retained snapshots. For devices with `capabilities.nse_withdraw ==
  true`, `src/push/publisher.rs` sends:
  - every alert push with `mutable_content: true`;
  - each withdrawal as **one** `mutable-content` alert push at priority 10.
    Its fixed-vocabulary placeholder title/body is `Nostromo` / `Updated`;
    add both to `vocab.rs` and the allow-list test. It carries
    `data.withdraw` and `badge`, and `interruption_level: passive`.
  This replaces W13's badge-only + background pair for those devices. The NSE
  removes the target notifications and hides itself.
- `src/push/devices.rs` (W13): `RegisterPush` gains `capabilities {
  nse_withdraw }`. Prefs gain `enrich: BTreeMap<host, bool>`. These prefs are
  stored for display only; enforcement is on the phone, because enrichment
  happens there.

iOS: new extension target and app-side handling:

- `iOS/NostromoNotificationService/NotificationService.swift` (new;
  `UNNotificationServiceExtension`), with its own `Info.plist`
  (`NSExtensionPointIdentifier = com.apple.usernotifications.service`) and
  `NostromoNotificationService.entitlements`, containing the app group
  `group.<bundle id>`, the shared keychain access group, and
  `com.apple.developer.usernotifications.filtering` **only in the
  `Filtering` build configuration** (see Approach step 1). Behaviour of
  `didReceive(_:withContentHandler:)`:
  1. Parse `userInfo` with `PushPayload` (W13, NostromoKit).
  2. **Withdrawal** (`data.withdraw` present): `getDeliveredNotifications`,
     `removeDeliveredNotifications` for every request whose `userInfo["item"]`
     is listed, set the badge, then deliver an empty
     `UNNotificationContent()` (filtered: nothing shown).
  3. **Enrich?** This is a pure function `EnrichmentPolicy.shouldEnrich(host,
     hostClass, devicePrefs)`: personal → default on; work or unknown →
     default off; the per-host toggle overrides. For decisions,
     choices are fetched regardless of the text toggle (PRD C7; a one-line
     policy change if Ada decides otherwise).
  4. Fetch with a hard **4.0 s total budget** via
     `PushDetailFetcher.fetch(itemRef, deadline:)`. This is a one-shot
     `URLSessionWebSocketTask` to the primary URL from the app group. Auth
     uses the W11 token from the shared keychain, then `PushDetail`, then
     close.
  5. On `waiting == false`: deliver the contract content and also remove it
     (the item resolved in flight). On `text`: set `body` (for Mother and
     decision items the original body moves to `subtitle`). On `choices`
     where `count ≤ maxActions` (S4): register a category
     `decision.<item_ref>` with one `UNNotificationAction(identifier:
     "choice.<id>", title: label, options: [.authenticationRequired])` per
     choice. Merge into `getNotificationCategories` (prune categories whose
     notification is no longer delivered) and set `categoryIdentifier`.
     Otherwise use the static category `decision.open` (Open only).
  6. On budget expiry or any error: deliver the original contract content
     unchanged. `serviceExtensionTimeWillExpire` also delivers the contract
     content.
  The NSE must not log notification text.
- `Shared/NostromoKit/Sources/NostromoKit/Push/EnrichmentPolicy.swift`,
  `PushDetailFetcher.swift`, `DecisionCategoryBuilder.swift` (new): pure or
  injectable pieces, so they are testable under `swift test` without the
  extension host. `PushDetailFetcher` takes a transport protocol so tests use
  a fake that can stall past the deadline.
- `Shared/NostromoKit/Sources/NostromoKit/Transport/DeviceCredential.swift`
  (W11): move the Keychain item to the shared access group, with a one-time
  migration from the app-only item. Store the primary URL and per-host
  enrichment prefs in the app group's `UserDefaults(suiteName:)`, so the NSE
  can read them.
- `iOS/Nostromo/PushAppDelegate.swift` (W13), in `userNotificationCenter(_:
  didReceive:)`, for `choice.<id>` actions:
  1. Begin a background task.
  2. Connect through W11's `WebSocketClient`.
  3. Send `DecisionAnswer { host, request_id, choice_id }`.
  4. Wait up to 8 s for `DecisionAnswerResult`.
  5. On `answered`: post a local notification with the **same identifier**
     and thread, body `Answered: <label>` (no sound).
  6. Otherwise post a local notification whose body names *unreachable*
     (connect or deadline failure), *already resolved* or *timed out*.
  Never retry. Register the static categories `decision.open`, `mother` and
  `review` (Open only) at launch.
- `iOS/Nostromo/Views/NotificationSettingsView.swift` (W13): add the
  per-host "Show full details" toggles. Defaults: personal on, work off. When
  turning one on for a work host, show the one-sentence "Show Previews: When
  Unlocked" recommendation and a link to iOS Settings.
- `iOS/Nostromo.xcodeproj/project.pbxproj`: add the
  `NostromoNotificationService` app-extension target, embed it in `Nostromo`
  (Embed App Extensions phase), and link `NostromoKit`. Add a `Filtering`
  build configuration that differs from `Release` only by the filtering
  entitlement, and the app-group and keychain-group entitlements on both
  targets. The project file is hand-maintained (IDs prefixed `AA0000…`);
  follow its existing ID style.
- `iOS/Nostromo/Info.plist`: `NostromoPushFiltering` = `$(PUSH_FILTERING)`
  (YES only in `Filtering`). The app reads this to set
  `capabilities.nse_withdraw` in `RegisterPush`.

Tests:

- `Shared/NostromoKit/Tests/NostromoKitTests/EnrichmentPolicyTests.swift`:
  every host class × toggle state; unknown host = work.
- `.../PushDetailFetcherTests.swift`, with a fake transport. Cover:
  - a reply at 3.9 s → enriched;
  - a stall to 4.1 s → `nil`, with the call returning by 4.05 s;
  - a connection refused → `nil` immediately;
  - `waiting: false` is surfaced.
- `.../DecisionCategoryBuilderTests.swift`: one action per choice with real
  labels and `.authenticationRequired`; more than `maxActions` → `nil` (caller
  uses Open only); identifiers are stable per `item_ref`.
- `.../NotificationContentComposerTests.swift`: contract in + detail →
  expected title/subtitle/body; contract in + `nil` → byte-identical
  contract out. No code path produces placeholder or error text.
- `tests/push_detail.rs` (Rust): a sensitive-tag item returns no text or
  choices to a non-sensitive device; a resolved item returns `waiting:
  false`; an unknown `item_ref` → `waiting: false` with no text.
  `DecisionAnswerResult` covers each outcome, including a timed-out request
  answered afterwards → `timed_out`.
- `tests/push_engine.rs` (W13, extend): a device with `nse_withdraw` receives
  exactly one mutable-content withdrawal push (no background push), with the
  placeholder title/body passing `vocab::conforms`.

## Approach

1. **Spike on a physical device** (throwaway branch; not shipped). Answer and
   record in the PR body:
   - (a) Does a category registered inside the NSE reliably apply to the
     notification it is modifying, across 20 consecutive pushes? If not,
     switch step 5 of the NSE to a `UNNotificationContentExtension` that draws
     the choice buttons in the expanded view, keeping the same
     `.authenticationRequired` semantics via the host app's action.
   - (b) What is the maximum number of actions iOS currently displays? This
     sets `maxActions`; default to 4 if it cannot be measured.
   - (c) Does NSE network traffic reach the primary through the WireGuard
     on-demand tunnel?
   **Operator step, in parallel:** request
   `com.apple.developer.usernotifications.filtering` from Apple for the
   extension's bundle id. Until it is granted, ship the `Release`
   configuration (`nse_withdraw = false`; W13's withdrawal path stays in
   use).
2. Daemon: `PushDetail`, `DecisionAnswerResult`, resolution-kind memory,
   device capabilities, the mutable-content publisher path, and tests.
3. NostromoKit pure pieces, TDD: policy, fetcher with deadline, category
   builder, content composer.
4. Extension target, entitlements, shared keychain/app-group migration, and
   NSE wiring.
5. App action handling and the settings toggles.
6. Full suite: `cargo test`, `cargo clippy --all-targets`, and `cd
   Shared/NostromoKit && swift test`. `xcodebuild -scheme Nostromo -sdk
   iphonesimulator build` must succeed with the extension embedded.

## Acceptance criteria

Tests (Cody gates):

- `cargo test`, `swift test` and the simulator `xcodebuild` pass. No existing
  test is modified except W13's engine test, which is extended.
- `PushDetail` never returns text or choices for a sensitive-tag item to a
  device without `sensitive: true`.
- The fetcher returns within 4.05 s in every case, and a `nil` fetch yields
  contract content byte-identical to the push.
- Enrichment policy: a personal host enriches by default; a work or
  unclassified host does not, unless its per-host toggle is on.
- Category builder: one `.authenticationRequired` action per choice, labelled
  with the real label, or `nil` when choices exceed `maxActions`.
- `DecisionAnswerResult` distinguishes `answered`, `already_resolved`,
  `timed_out` and `unknown`. An answer after timeout reports `timed_out`, and
  the decision is not answered.
- A device registered with `nse_withdraw: true` receives withdrawals as a
  single mutable-content push whose visible strings pass the W13 vocabulary
  allow-list. A device without it keeps W13's badge-only + background pair.

`[device]` (operator-verified on a physical iPhone with the VPN up, after
merge; not a Cody gate):

- A personal-host Mother item shows the real question's first line within
  5 s of arrival. The relay record and the W13 sent log show only the
  contract text.
- A work-host item shows contract text until "Show full details" is turned on
  for that host on that device. After that it is enriched.
- With the VPN down, every notification shows exact contract text, with no
  intermediate state.
- Long-pressing a decision notification on an unlocked phone shows its real
  choices. Picking one closes the Mac modal as answered with that choice, and
  the notification reads `Answered: <label>`. On a locked phone, iOS asks for
  Face ID or passcode before anything is sent.
- Answering after the decision timed out → a local notification saying
  *timed out* within 10 s. With the VPN dropped mid-action → *unreachable*
  within 10 s. Neither is retried.
- With the VPN down, a decision notification offers only **Open**.
- Filtering build: answering a Mother question at the Mac removes the
  phone's notification and drops the badge within 2 minutes, without opening
  the app, including after the app has been force-quit.
- PR body records the spike results (category reliability, `maxActions`,
  NSE-over-WireGuard) and whether the filtering entitlement has been granted,
  and references `docs/prds/push-relay.md` and the sequencing memo (W16).

## Out of scope

- Any change to what goes through the relay. The vocabulary is W13's, plus
  only the `Nostromo`/`Updated` withdrawal placeholder.
- Text-reply actions for Mother questions. PR approve or request-changes
  actions.
- Enrichment of Summary notifications.
- Live Activities, widgets, and a Notification Content Extension (unless the
  spike in step 1a requires it).
- macOS notifications. Mother's Mac notifications are unchanged.
- Bringing the WireGuard tunnel up from the extension.

```yaml
suggested_config:
  cody:
    model: opus
    effort: high
    rationale: "New extension target in a hand-maintained pbxproj, shared keychain migration, hard time budgets and an on-device spike that can change the design."
  redd:
    model: sonnet
    effort: high
    rationale: "Deadline-bounded fetcher, policy matrix and answer-outcome paths need deterministic fakes; device-only behaviour must be pushed into testable units."
  marty:
    model: sonnet
    effort: medium
    rationale: "NSE glue should end thin over NostromoKit units; keep extension and app action paths sharing one composer."
  perri:
    model: sonnet
    effort: high
    rationale: "Sensitive-scope leaks via PushDetail and lock-screen answers that act without auth are the failure modes to hunt."
```
