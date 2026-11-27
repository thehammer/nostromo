# iOS verification

`iOS/Nostromo.xcodeproj` has two targets: the application, and `NostromoTests`,
a unit-test bundle hosted inside the app (`iOS/NostromoTests/`, run by `make
ios-test`, layer L5 below). The test target is deliberately small and
deliberately last in line: almost everything about the iOS app is verified
without it. Before `ios-curated-view-parity` W2, the iOS app's own view code
(12 Swift files, ~2,300 lines, all view code — the store, transport, and
wire types live in `Shared/NostromoKit`, consumed by both platforms) had no
test coverage at all. Its recent history is three reactive
switch-exhaustiveness fixes, each landing as a comment explaining after the
fact why a particular case was a stub — a target maintained by the compiler
complaining, one incident at a time.

That gap is what this doc is about, and why it's split into layers rather
than one. Run L1–L3 before considering an iOS change to pane rendering,
addressing, or queue marking complete. L4 (below) is macOS-only — it exists
because the same "compiles" vs. "actually runs" gap this doc names for iOS
turned out to have a macOS instance too, discovered the hard way. L5 is the
iOS simulator layer, and it is for the backplane runtime only: see its rule
and its reviewer checklist before adding a test to it.

## L1 — logic

**What:** Pure value types and pure functions in `Shared/NostromoKit`,
covered by XCTest in `Shared/NostromoKit/Tests/NostromoKitTests/`.
Everything the iOS *and* macOS clients share — wire decoding, the
`DaemonStore` message-routing logic, `PerriPRRowModel`/`PaneAddress.marks`,
and, as of W9, the platform-neutral `ProseRow` plan and its
`ConversationPlan`/`TicketPlan`/`ProseAddressing` resolvers — lives here,
not in either app target, specifically so it can be tested this way.

**Run:**

```
make kit-test
```

which is `swift test --package-path Shared/NostromoKit` — a plain SwiftPM
test run, and also the `Swift tests (NostromoKit)` PR check. **No paired iOS device and no simulator required or used.** As of
`ios-curated-view-parity` W2 this runs 124+ tests in just over a second.

**What it can verify:** decoding correctness, `Equatable` conformance,
row-model mapping, the queue-row marking predicate (`PaneAddress.marks`) and
its isolation from every other row field, the stub-message table's
per-kind coverage. Anything expressible as "given this value, this pure
function returns that value."

**What it cannot verify:** that a SwiftUI view actually renders what the
logic says it should, that a view is wired to the right store property, or
that the app compiles at all. That's L2 and L3.

## L2 — wiring and policy

**What:** Source-scanning tests over `iOS/Nostromo/**/*.swift` as text, in
`tests/ios_policy/`. See `tests/ios_policy/README.md` for the full
rationale and the no-skip constraint it operates under. These are the iOS
analogue of macOS's own source-text fitness functions
(`macOS/NostromoTests/DecisionStoreTests.swift`,
`macOS/NostromoTests/TurnInteractionTests.swift`,
`ActivityTickerWiringTests.swift`, the last three checks in
`LayoutChangeClassifierTests`) — the macOS suite runs as part of `mac-test`
(the `Swift tests (Mac app)` PR check; see `docs/ci.md`), while this one is
Python scanning Swift text rather than a compiled Swift test bundle, so it
needs no Xcode at all.

**Run:**

```
make python-test
```

which runs `tests/ios_policy` alongside `tests/transcript_load` and
`tests/doctor`. This is the same command CI runs
(`.github/workflows/ci.yml`, the `python-tooling` job, on `macos-26`),
so a local pass and a CI pass can't drift apart. **No paired iOS device and
no simulator required or used** — it's a plain Python source scan.

**What it can verify:** structural properties of the source text — that a
`switch` over `PaneContentWire` has no `default:` arm (so a new case must
break the compile rather than fall through silently), that every
`toRowModel(` call passes `marked:`, that the deleted raw-text `.code` dump
(`payload.text`) doesn't reappear, that `address:` is actually plumbed from
`DynamicFocusView` into the pane surface, that a swipe-to-approve action's
staged value never derives from the pane's `address` (marking must stay
visual-only), and that stub copy comes from `PaneSurfaceStub` rather than
being hand-typed into a view.

**What it cannot verify:** anything about runtime behavior, or any property
that isn't expressible as a textual pattern over the source. It is,
explicitly, "a textual heuristic, not a control-flow proof" — the same
caveat macOS's own fitness functions carry. A sufficiently adversarial
rewrite could satisfy the letter of a check while violating its intent; it
has not been fooled by any mistake that has actually happened in this
codebase.

**The no-skip constraint.** The CI job this suite runs in greps its output
for `... skipped` / `(skipped=` and fails the build on either — a skipped
test is a vacuously passing test. `tests/ios_policy` must never introduce a
skip mechanism, and checks that on itself as a second, local guard (see its
README).

## L3 — compile

**What:** An actual build of the iOS app target, against a paired physical
device.

**Run:**

```
make ios-build
```

which targets `IOS_DEVICE_ID` (overridable: `make ios-build
IOS_DEVICE_ID=<uuid>`) — a real, paired iPhone, not a simulator. The recipe
carries a `set -o pipefail` guard (matching `mac`/`mac-test`'s own
rationale): without it, the recipe's exit status is `grep`'s, and a build
that failed for a reason grep's pattern doesn't print — or one that hung —
could still exit 0.

**What it can verify:** that the app actually compiles, with the exact
toolchain and deployment target the shipped app uses, and produces a
`.app` bundle. It's also the only layer here that would catch an Xcode
project-file mistake (a source file registered in the wrong build phase, a
missing framework reference) — L1 and L2 both operate below the project
file.

**What it cannot verify:** anything about behavior at all — it's a compile
check, not a test run.

**Where it runs.** `make ios-build` is local-only: `IOS_DEVICE_ID` names a
specific paired physical iPhone, and a release build against real hardware
is the one compile signal CI cannot give. CI runs the same compile for the
simulator, as the first step of the `iOS simulator build` job (generic
`iOS Simulator` destination, no signing), so a compile break or a project-file
mistake is caught on every PR that touches the app; the same job then runs
L5.

## L4 — does the thing actually run (macOS)

**What:** `bin/nostromo-launch-smoke` — build the macOS app, launch it
against a fixture daemon, and confirm from the running app's own reported
measurements that it reached a real, laid-out multi-pane AppKit layout,
survived a 15s observation window, produced no crash report, settled its
CPU, and painted every pane at a real size.

**Run:**

```
make mac-smoke
```

**Why this layer exists.** L3 (`xcodebuild build`) proves the Swift
compiles. It cannot prove anything about live AppKit behavior — in
particular, AppKit *reentrancy*: on 2026-09-03, every launch of the macOS
app crashed with a stack overflow inside `RatioSplitView.layout()`
(`.claude/bugs/resolved/2026-09-03-ratiosplitview-layout-infinite-recursion-crash-on-launch.md`
in the primary repo checkout), while `make mac` built cleanly, `make
mac-test` passed 535 tests, and CI was green on both jobs. `NostromoTests`
is a host-less logic bundle — no `NSApplication`, no `NSWindow`, no AppKit
layout loop — so this class of bug was not under-tested there, it was
*structurally unreachable* there, the same way L1/L2 on the iOS side cannot
observe anything that needs a real render pass. This is that gap's macOS
instance, closed the same way: build the smallest thing that can actually
exercise the live behavior, and make it fast enough to run before opening a
PR.

**What it can verify:** that the built app launches, that a focus reaches a
tree containing a real split (not just a single leaf — the daemon-driven
pane tree at a fresh launch, with no daemon answering, degrades to a
single leaf that never constructs a split view at all, so this is not
optional setup, it's the reproduction condition), that ≥2 panes actually
laid out at a non-zero size, that at least one `RatioSplitView` reported its
ratios successfully applied (positive proof it reached
`NSSplitView.setPosition` and returned — the exact call that hung forever in
the 2026-09-03 defect), that the app survived 15 real seconds without dying,
spinning, or producing a crash report, and that no pane laid out to zero
width or height. That last check is content-independent: a pane that
completed a layout pass in a real window but collapsed to zero size is a
violation whether or not `pane_content` has arrived for it, since the
fixture daemon this check drives never pushes content at all — gating the
check on content having arrived would make it silently inert on every run.
Validated against the bug it exists to catch: `make mac-smoke-validate`
reintroduces the exact 2026-09-03 defect in a scratch worktree and asserts
the check reports FAIL, then reverts and asserts PASS.

**What it cannot verify:** anything this file's "out of scope" list already
names for the feature that built it — no UI driving (no clicks, no divider
drags), no screenshot/visual-diff verification, and only four failure
modes (process death, a crash report, unsettled CPU, a zero-size laid-out
pane) — not constraint conflicts, layout warnings, wrong-but-alive layouts,
or drawing artifacts. It also cannot verify multi-window or
multi-display-specific layout: it opens exactly one window, on one screen,
to avoid commandeering the operator's real displays, so a defect that only
manifests with several windows or at a particular display geometry is
outside what a green here means. A CI runner (from W2 on) is one virtual
display of unstable size, while the operator has three real ones — the same
environment-divergence caveat L2's "textual heuristic, not a control-flow
proof" line carries, restated for geometry instead of source text. **A green
here means "it launched and exercised a live multi-pane split for 15
seconds," not "the GUI is fine."**

**Why this check needs no device.** It needs no simulator and no paired
device — the identical command runs on the Mac a developer is already
developing on and (from W2) on a stock GitHub-hosted macOS runner, because
GitHub's macOS runner images auto-login into a real, live Aqua/WindowServer
session. It also needs no test target at all, just a built `.app` and a
socket.

## L5 — iOS simulator (backplane runtime only)

**What:** `NostromoTests`, an XCTest bundle hosted by the iOS app
(`iOS/NostromoTests/`), run in an iOS Simulator process.

**App Transport Security is only visible here.** On iOS 17 and later ATS refuses a plain `ws://`
connection to an IP address unless the app's `Info.plist` sets `NSAllowsLocalNetworking`
(`NSAppTransportSecurity`; never `NSAllowsArbitraryLoads`). `URLSessionWebSocketTask` is an ATS-governed
URLSession task (the legacy `NetworkClient` uses `NWConnection`, which ATS does not cover, which is why the
old transport worked without it). A SwiftPM test binary has no `Info.plist`, so no Kit test can notice a
missing key: every Kit test opens sockets ATS never sees, and a phone with the key missing would fail every
connection with error -1022, shown as "can't reach" forever. `AppTransportSecurityTests` runs in the hosted
app, starts an in-process `NWListener` WebSocket server on loopback and reaches it over plain `ws://` on
`127.0.0.1` and `[::1]` through a raw `URLSessionWebSocketTask`, `WebSocketClient` and `PairingClient`; it
fails if ATS blocks any of them. `tests/ios_policy` scans `Info.plist` for the same keys.

**Limit, measured:** with `NSAllowsLocalNetworking` flipped to `false` (a mutation branch, CI run 45712146182)
the live connections to loopback and to the runner's LAN address still succeeded on the Simulator, and only
the test that reads the built `Info.plist` failed. So on the Simulator the live tests cannot show that the key
matters (either the Simulator does not enforce ATS for IP literals or ATS does not govern `ws://` there). What
they prove is that the app's own transports work inside an app bundle; the key itself is guarded by the
built-plist test and the policy scan, and by Apple's documented iOS 17 behaviour. Whether a real iPhone on a
WireGuard address connects is a device check (W11-13), not something CI shows.

What `NSAllowsLocalNetworking` covers is the pairing-address rule: an IPv4 or IPv6 literal (a VPN address
such as a WireGuard `10.x` or a Tailscale `100.x` included), a `.local` name, or a single-word name. A full
domain name (`mac.tailnet.ts.net`, `mac.example.com`) is outside it, and the list cannot be extended at run
time: an `NSExceptionDomains` entry is fixed in the built app, so it would have to name one operator's
domain. So the pairing screen says to use the IP address or a `.local` name (`PairingCopy.addressHint`), and a
"can't reach" for a full domain name carries the same sentence. Which names are covered is Apple's documented
behaviour for the key; the loopback test proves the IP-literal half on the Simulator. A real device on a VPN
address is a manual check (W11-13).

**Run:**

```
make ios-test
```

which is `xcodebuild test` of the shared `Nostromo` scheme (it includes the
`NostromoTests` target) against `IOS_SIM_NAME` (default `iPhone 17`, a device
every iOS runtime on the `macos-26` runner image ships), signed ad hoc (`CODE_SIGN_IDENTITY=-`, no team, no profile) so the hosted app has entitlements and the Keychain tests can run.
Derived data goes on `/Volumes/Scratch` when it is mounted (otherwise
`iOS/build/`); see `docs/ci.md`. It also runs as the second build step of the
`iOS simulator build` PR check (`make ci-remote ONLY=ios` dispatches it). It
fails if no test executed, so a bundle that silently lost its tests cannot pass.
It needs an iOS Simulator runtime installed (Xcode > Settings > Components); on
a Mac without one, rely on `make ci-remote ONLY=ios`.

**The rule.** *Only what needs an iOS process goes in L5; everything else
stays L1 or L2.* "Needs an iOS process" means behaviour whose answer depends
on iOS itself and that no value-type test or text scan can observe:

- Keychain access groups (the backplane's device credential store, W11);
- URL handling: `onOpenURL` / the `nostromo://pair` handler (W11);
- the file protection class of the encrypted content cache (W11);
- extension and App Group wiring: the Notification Service Extension's
  shared container (W16), APNs registration state (W13);
- the hosted harness itself (the smoke tests that keep L5 from going vacuous).

Everything else — decoding, state machines, retry and backoff, pairing
protocol logic, cache encryption and eviction logic, enrichment policy, row
models, layout plans — is a pure function of its inputs and belongs in L1
(`Shared/NostromoKit`, `make kit-test`). Wiring and source-shape rules belong
in L2 (`tests/ios_policy`). What a human has to look at (rendering, motion,
legibility) is device-only, as before.

**Why the rule is this strict.** The reason is discipline, not cost. L1 and
L2 stay fast, headless and runnable by anyone with no simulator installed
only while they remain the default home for a check. The moment a
simulator-bound target exists, the temptation is to route every "is this
actually going to work" question through it whether or not the answer needs a
simulator, and a layer that boots a simulator is slower, flakier and harder
to run locally than the layers beneath it. So the target is for the
backplane's runtime surface only, and the rule is made visible and checked:

- every file under `iOS/NostromoTests/` starts with an `// L5:` header line
  naming the iOS-only behaviour it needs, and a policy test
  (`tests/ios_policy/test_ios_l5_headers.py`, part of `make python-test`)
  fails on a file without one;
- the same policy test fails if a file in `iOS/NostromoTests/` is not
  compiled by the `NostromoTests` target (a hand-listed source that is not in
  the project file is never run);
- review applies the checklist below.

**Reviewer checklist for a change that touches `iOS/NostromoTests/`:**

1. Does the file's `// L5:` header name an iOS-only behaviour from the list
   above (or a new one the PR argues for), not "tests the thing"?
2. Could the same assertion run in `make kit-test` if the logic moved into
   `NostromoKit`? If yes, it belongs there, and the iOS side should be a thin
   caller that L2 can scan.
3. Does it fail without iOS? Delete the iOS-specific call (the Keychain
   access group, the URL, the protection attribute) and check the assertion
   still bites. A test that passes either way is an L1 test in the wrong place.
4. Does it avoid the network, the real Keychain contents of the developer, and
   wall-clock sleeps? L5 runs on a stock runner with no daemon. Note the host
   app really launches `ContentView` under the test host: on a simulator whose
   defaults already hold a saved daemon host it will try to connect, so a local
   `make ios-test` is only hermetic on a simulator that has never been pointed
   at a daemon (a fresh one shows the discovery sheet instead).
5. Does the PR body say what L5 does *not* show (for example, behaviour that
   differs on a real device, such as Keychain on a locked phone or APNs
   delivery)? The simulator is not a device.

**What it can verify:** that code which needs an iOS process behaves as
intended in one (Keychain with an access group, a URL delivered to the
app, a file's protection attribute, the App Group container resolving), and
that the app itself launches under a test host.

**What it cannot verify:** anything a real device decides — APNs delivery,
data protection while locked, Face ID, the Simulator's own Keychain being a
softer approximation of the device's — and anything perceptual (see the
worked example below). A green L5 means "this iOS-process behaviour holds on
the Simulator," not "the app works on the phone."

**What is in it today:** the two smoke files, W11's backplane files, W13's `PushSheetEnvironmentTests` and W16's `NotificationExtensionBundleTests` (the last two are not described below; read their `// L5:` headers). `NostromoSmokeTests`: the
app is a SwiftUI `@main App` with no hand-written app delegate, so the honest equivalent of "the app
delegate launches" is that UIKit's delegate for the app is live in the process, and that the bundle can
reach app-module code (`ConnectionSettings`) and construct `NetworkClient` the way `NostromoApp` does.
`HostedHarnessTests` proves the bundle really runs hosted in the app inside an iOS process.
`KeychainCredentialStoreTests` (the device credential's item attributes, `AfterFirstUnlockThisDeviceOnly`,
round trip, delete on revoke, token never in UserDefaults), `PairLinkRoutingTests` (the `nostromo` URL
scheme in the built Info.plist, the camera and Local Network reasons, and `AppSession.handle(url:)` routing
a valid link to the confirmation step and refusing a bad one) and `ContentCacheProtectionTests` (the cache
file's `complete` protection class, backup exclusion, wipe), `AppTransportSecurityTests` (below),
`AppSessionLaunchTests` (an orphaned credential is deleted at launch, a hostile link after a reinstall sees
no token or proof, a revoke clears the credential and the content before the screen changes, the legacy
transport is reachable before any pairing) and a small loopback WebSocket server they share. All carry
`// L5:` headers. What they do not
show: the Simulator's Keychain and file protection are softer than a device's, so a locked phone is a
manual check (W11-13).

## Worked example: ambient activity (W4)

`ios-curated-view-parity` W4 (the always-present activity ticker) is a
useful worked example of how the three layers divide a single feature's
criteria, because most of what makes the ticker trustworthy is provable
without a device at all:

- **L1** (`ActivityStreamModelTests.swift`, `ActivityWireTests.swift`,
  `DaemonStoreTests.swift`): stream assembly and subagent nesting, the
  ticker's three-state text (waiting / event / N-agents-active), both
  not-ingesting health messages and `displayText`'s health-wins rule,
  `seq`-gap detection and per-stream isolation, wire decode correctness for
  all three `ServerMsg` activity cases, per-focus attribution and the
  reserved unattributed key, gap→snapshot-request with its one-outstanding-
  per-tag rate limit, and — the part macOS's own model doesn't have to
  prove — bounded retention: the per-stream and store-wide caps, the
  finished-before-running-before-main reclaim order, and that the ticker
  still has something to show after a reclaim.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): the ticker's
  fixed-height single-line shape (the mechanism that keeps an arriving
  event from resizing the transcript's bottom inset and shifting its scroll
  offset), that no file under `Views/Activity/` ever scrolls, steals first
  responder, or hides behind `UserDefaults`/`@AppStorage`/a `Toggle`, that
  `TranscriptView`'s autoscroll is still keyed only on `store.turns.count`,
  that no raw `tool_input`/`cwd`/`tool_use_id` is ever read, and that the
  expanded sheet is presented from the focus view rather than from
  `TranscriptView` or `PaneSurfaceView`.
- **L3** (`make ios-build`): that the two new files compile and are
  actually wired into the app target's build phase.

What's left over — genuinely **UI-observable only**, provable at neither L1
nor L2 nor L3 — is exactly the property that motivated the feature in the
first place: that watching the ticker update, on a real device, while
holding the transcript scrolled to a fixed position, produces no visible
motion at all. No text-scan or compile check can observe a pixel not
moving; the manual verification steps in the wedge's plan (scroll, hold,
watch several events arrive) are the only check that exists for it, and a
build that passes L1–L3 is a necessary but not sufficient signal that this
property holds. The same is true of the long-fan-out memory plateau — L1
proves the cap arithmetic is right, but only Xcode's memory gauge over a
real extended session shows the cap actually holding operationally.

## Worked example: `ask_decision` end to end (W3)

`ios-curated-view-parity` W3 (wiring `nostromo.ask_decision` on iOS) is
notable because its riskiest property — a second, contradictory answer
reaching a blocked agent, or a system-initiated close reading as an
operator's explicit Skip — is exactly the kind of thing this three-layer
split exists to make provable without a device:

- **L1** (`DecisionStoreTests.swift`, `DecisionWireTests.swift`,
  `DaemonStoreTests.swift`): the answer-once claim gate and its bounded
  FIFO, `decision_request`/`decision_resolved` decode correctness (never
  tested before this wedge), `ClientDecisionAnswer`'s `choice_id: null`
  vs. omitted-key distinction, the pending-decision queue's dedup/drop/
  arrival-order rules, and the mapping from a `decision_resolved` frame to
  `.choice`/`.dismissed`/`.resolvedElsewhere`. One fact needed a Swift
  source-scan rather than a behavioral assertion, for a scope reason, not a
  laziness one: "does `renders_decisions: true` still have a
  `.decisionRequest` handler behind it" spans two files
  (`NetworkClient.swift`, `DaemonStore.swift`) both under
  `Shared/NostromoKit`, outside `tests/ios_policy`'s remit (scoped to
  `iOS/Nostromo`) — so that specific pairing is asserted as an L1 XCTest
  reading `DaemonStore.swift`'s own source text, the same technique
  `ClientMsgTests.swift` already uses to pin `sendHello()`'s literal
  `rendersDecisions` argument.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): no `@State` in a
  `Decision`-named file holds answered/resolved-shaped state,
  `DecisionSheetView` is constructed from exactly one place
  (`NostromoApp.swift`) and never with a hard-coded `resolution: nil`,
  there is exactly one `answerDecision(` call site and `claimAnswer`
  precedes it in file order, every `case .supersededByDaemon` body sends
  nothing, and the one-tap/always-gated asymmetry between the decision
  surface and `perriApprove`'s `confirmationDialog` holds in both
  directions.
- **L3** (`make ios-build`): that the new file compiles and is wired into
  the app target's build phase.

What's left over — genuinely **UI-observable only** — are the two
properties no text-scan or compile check can see: that the sheet actually
*renders* on a real device with the prompt, detail, focus name, and each
choice's own detail legible, and that two clients (Mac + phone) racing to
answer the same request resolve to exactly one winning answer with the
loser's screen updating to the resolved state rather than an error. Both
are covered only by the wedge's plan's manual verification steps.

## Worked example: the compact tab strip (W5)

`ios-curated-view-parity` W5 (honoured focus, real labels, `reason`
captions, unread marks) is the layer split at its most load-bearing, because
the single most important property it adds — a content-only layout republish
must never fight the operator's own tab choice — is exactly the kind of
thing a compile check can't see and a screenshot can't prove either:

- **L1** (`LayoutChangeClassifierTests.swift`, `TabPlanTests.swift`,
  `FocusRegionStateTests.swift`, `DaemonStoreTests.swift`): the full D4
  transition table (`.contentOnly`/`.identical` never move the frontmost
  pane even when the tree's own `active` disagrees; `.activeTabOnly`/
  `.tabMembership`/`.splitTopology` do; `focused_pane` always wins on top),
  the flattening order (`repl` first, two `tabs` nodes staying contiguous,
  no leaf dropped or duplicated), the label-fallback rule never producing a
  pane id, unread derivation including the suppressed-`.loading` and
  frontmost-push cases, and that a `focus_layout` arrival actually
  classifies against the previously-stored tree and applies the transition.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): that no pane id is
  ever user-visible via `.capitalized`, that no second bottom tab bar exists
  outside `NostromoApp.swift`, that no view assigns to the root tab
  selection or mutates a navigation path, that the frontmost pane comes from
  `FocusRegionState` rather than view `@State`, that no local
  placement/ratio persistence exists, that the unread glyph is
  opacity-toggled rather than conditionally inserted, and that the W4
  ticker still survives the rewrite.
- **L3** (`make ios-build`): that `TabStripView.swift` compiles and is wired
  into the app target's build phase, and that the rewritten
  `DynamicFocusView.swift` still builds with no new warnings.

What's left over — genuinely **UI-observable only** — is everything about
*seeing* the strip do the right thing on a real device: that a shown tab is
actually frontmost on arrival, that switching tabs preserves scroll
position, that the unread dot doesn't reflow the strip when it appears, and
that a show arriving while the operator is in an unrelated root tab (Fred)
leaves them there. L1's transition-table tests prove the *decision* is
correct in isolation; only a device shows the decision landing on screen.

## Worked example: the iPad's regions (W6) — and the widest gap in this doc

`ios-curated-view-parity` W6 (two presentations, selected by horizontal width
class) is the wedge where the distance between **tested** and **verified** is
largest, and the PRD says so itself:

> The iPad layout is the one thing here nobody will be able to check… "Two
> regions, correctly proportioned, that survive a rotation with their scroll
> positions intact" is a claim about a live view hierarchy on a device that is
> not in CI and has no test target. The mitigation is the pure-function
> requirement — the layout *decision* is testable even when the layout
> *rendering* isn't — but it is a partial mitigation, and the regular-width
> presentation is the part of this PRD most likely to be quietly half-working.

(The PRD predates L5. A test target now exists, but it is scoped to behaviour
that needs an iOS process, not to layout or rendering, so the rendering half
below is still device-only.)

This section is the honest accounting of which half is which. Treat it as a
warning about where to spend review attention, not as a formality.

### Covered at L1 — decided by a value, proven with no device

`layoutPlan(tree:width:)` is a pure function of a `PaneTree` and a
`WidthClass`, with no view hierarchy, no `GeometryReader`, no environment and
no device. That is not stylistic: extracting the layout *decision* is the only
form in which any of this is checkable at all, so everything that can live
there does.

- **The plan shape**, for both widths: a single `repl` leaf as one bare
  region; a two-way split as two regions with the direction preserved;
  nested splits as regions *within* regions rather than a flattened row (the
  assertion that catches a depth-one walk); two `tabs` nodes under a split as
  two regions with distinct paths sharing no pane; a `tabs` node whose child
  is a `split` as a region within a tab.
- **Direction semantics** — that `horizontal` means a vertical divider
  (left | right), asserted on the plan's own field, with the meaning stated in
  the test's name. Getting this backwards produces a layout that looks
  deliberate and is wrong.
- **Ratio normalisation**, against every malformed shape a daemon could emit:
  unnormalised, too short, too long, empty, zero, negative, `NaN`, `±inf`,
  extreme skew. Every case asserts the invariant the view depends on — shares
  sum to 1, every share strictly positive — because a plan whose shares don't
  sum to 1 blanks a region on screen.
- **Totality**: for a table of ~15 tree shapes (including one decoded through
  the unknown-`kind` fallback), every leaf in `tree.paneIds` appears exactly
  once in the plan, at **both** widths. No drops, no duplicates.
- **Path stability**: a given node's `RegionPath` is identical whether the
  plan was built compact or regular. This is the single most load-bearing
  assertion in the wedge — it is what lets a frontmost tab, an unread mark or
  a scroll key written in one presentation resolve in the other.
- **The compact path is still W5's**, asserted by comparing the plan's entries
  against `TabPlan.build` directly, so a future edit cannot quietly fork it.
- **The state transitions** (`FocusRegionStateTests`): frontmost and unread
  surviving a width-class change, the scroll-restore decision including its
  already-visible-means-don't-move clause, and pruning of state for a region
  the tree no longer contains.
- **The store's per-region wiring** (`DaemonStoreTests`), driven through real
  `focus_layout`/`pane_content` ingestion: a `focused_pane` landing in one
  region leaves a sibling region's frontmost tab unmoved; unread is tracked
  per region; the compact region keeps W5's behaviour alongside; a re-sent
  identical tree still never fights the operator's per-region tab choice.

### Covered at L2 — structural, checked by scanning source text

- Nothing under `iOS/` references a device, screen, or orientation API
  (`UIDevice`, `userInterfaceIdiom`, `UIScreen`, `UIInterfaceOrientation*`,
  `orientation`, `willTransition(to:`). This is what keeps "the width test is
  the only branch" true over time.
- `@Environment(\.horizontalSizeClass)` is declared in exactly one file, and
  `WidthClass` is named only by an **explicit allowlist** — the focus view,
  the region container, and (from W8) the diff surface — so adding a consumer
  requires editing the policy and therefore noticing.
- No gesture in the region container and no persisted ratio key anywhere: the
  operator cannot resize a region.
- **No sheet is presented from inside a region view.** This is the structural
  form of two preservation criteria (an open activity surface and a presented
  decision surviving a width change), and asserting the structure is stronger
  than asserting the outcome, because the outcome is only observable on a
  device.
- The region container references the plan's `shares` and contains no layout
  fraction of its own — a heuristic over arithmetic, and one that will not
  catch a fraction laundered through a named constant.
- No durable scroll-restore key lives in view `@State`.

### Checkable ONLY by hand, on an iPad

These are not covered by L1, L2 or L3, and no amount of further test-writing
would cover them. They are verified by running the manual pass in the wedge's
plan on a real device and writing the observations into the PR body:

| Criterion | Why nothing automated can see it |
|---|---|
| Two regions are **actually on screen at once**, visibly proportioned to the ratios the daemon sent | L1 proves the plan says `0.6/0.4`; only an eye confirms the pixels do |
| The **live rotation transition** preserves both regions' frontmost tabs and both surfaces' scroll positions, with nothing reloading and nothing jumping to the top | A claim about a live view hierarchy mid-transition; L5 hosts tests in the app but is scoped to iOS-process behaviour, not to judging a live transition, and the Simulator is not the device |
| The same transition arriving by **dragging a Split View divider** rather than rotating | Same, by a second route that exercises different SwiftUI machinery |
| **Per-region unread legibility** — that a mark in the region the operator is *not* looking at is noticeable from a normal viewing distance without hunting | An unread dot's existence is testable; its peripheral-vision legibility is a perceptual property |
| The divider **does not look draggable** and nothing happens when you try | L2 proves no gesture is attached; only looking confirms it doesn't invite the attempt |
| **Slide Over presents the compact layout**, identical to the phone | Requires an iPad in a multitasking configuration |
| Every renderer and the ticker **look and behave identically at both widths** | The claim is about absence of difference across two live renderings |

One row the PRD asks for is **not on that table, because it cannot be**: "a
presented decision survives a width-class change." As of W6 the iOS app has no
decision surface at all — W3 (`no_operator`/answer-once) landed on macOS only,
and nothing under `iOS/` renders or answers an `ask_decision`. The structural
half of the criterion is in place and enforced (no sheet is presented from
inside a region, and the app root is where a decision would present, above the
hierarchy a width change destroys), but the behavioural half is **vacuous on
iOS today** and should be re-verified by hand by whichever wedge brings the
decision surface to iOS. Recording it as passing would be exactly the
false-confidence this doc exists to prevent.

A build that passes L1, L2 and L3 is a **necessary but not sufficient** signal
that W6 works. If you are reviewing this wedge and the PR body does not record
what was actually seen on the device for each row above, the regular-width
presentation has not been verified — it has only been argued for.

### One thing W6 changed that is worth knowing about

"Nothing reloads" could not be satisfied by scroll restoration alone. The
transcript's turns used to live in a `@StateObject` inside `TranscriptView`,
and a width-class change destroys and rebuilds that view — producing a fresh,
empty store that re-requested the whole snapshot from the daemon, blanked the
transcript, and let its autoscroll drag the operator to the bottom of a
conversation she was reading the middle of. W6 hoists the `TranscriptStore`
into `DaemonStore` (keyed by focus tag) and makes `attach`/`detach` idempotent
and reference-counted, with teardown deferred one main-actor hop so it
survives a rebuild whose `onAppear`/`onDisappear` can fire in either order.
That ordering is not something L1 can observe either — it is on the manual
list above, under the rotation row.

## Worked example: the `code` surface (W7)

`ios-curated-view-parity` W7 replaces the `code` stub with a real renderer
(`CodeSurfaceView.swift`) and is the wedge the PRD names as the one that must
not be softened: on a phone, "the agent points at line 412" is the entire
value of showing a file at all. It is also a useful worked example because
most of what makes it trustworthy is, unusually, provable with no device —
the line arithmetic and the honesty rule are both pure functions ported into
`Shared/NostromoKit`, and only the wrapping/scrolling/gutter *rendering* is
UI-observable only.

- **L1** (`CodeDocumentTests.swift`, `RowOffsetIndexTests.swift`,
  `ScrollDecisionTests.swift`, `AnchorResolutionTests.swift`,
  `RevisionLabelTests.swift`): the ported macOS suites passing unmodified —
  line splitting, UTF-16 character-range arithmetic (including an emoji
  case that diverges from `String.count`), out-of-document lookups
  returning `nil` rather than a clamped range, and the scroll/no-scroll
  decision table. `AnchorResolutionTests` is new: the three-state
  `AnchorResolution`/`EmphasisResolution` resolvers, including the case
  macOS's own `TicketContentView.resolveRows` gets wrong — an anchor kind
  this surface can't use (`.comment`, `.section`, `.queueRow`) resolves to
  `.unresolved` with a reason, where macOS silently drops it — and the
  "partially in range clips to the intersecting rows, fully out of range is
  `.matchedNothing`, never a clamped span" rule for emphasis.
  `RevisionLabelTests` proves `working` and a 40-character SHA produce
  different, non-hash-shaped, non-blank labels.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): that the raw dump
  cannot come back (`payload.text` referenced only inside a
  `CodeDocument(` construction — the file-scanning analogue of the L1
  proof), no truncation of any kind (no `prefix(`, no `lineLimit(` on the
  content column, no numeric row cap — `PerriView.swift`'s own truncated
  diff excluded by path as the deliberately different, deferred surface),
  no horizontal scrolling, the `HStack(alignment: .top` gutter/wrap
  mechanism, every `scrollTo(` gated by a `case .scrollTo` decision (ported
  from macOS's `CodeContentViewTests`, broadened to accept `ScrollRestore`
  alongside `ScrollDecision` — iOS's width-class rebuild has no macOS
  analogue), no `.id(` keyed on `address`/`anchor`/`emphasis` (the
  never-rebuilds-on-re-anchor property), every `AnchorResolution`/
  `EmphasisResolution` case name referenced in the view (paired with L1's
  exhaustive switches so an added case can't be silently ignored on either
  end), and that `WidthClass`/`horizontalSizeClass` appear nowhere in this
  file — a file view is the same file view at both widths.
- **L3** (`make ios-build`): that `CodeSurfaceView.swift` compiles and is
  wired into the app target's build phase, with no new warnings.

What's left over — genuinely **UI-observable only** — is watching a real
file render: that a soft-wrapped line's continuation actually shows a blank
gutter cell rather than a repeated or advancing number, that a long line
visibly wraps rather than requiring a horizontal pan, that an anchor already
in the viewport really doesn't move the scroll position, that re-showing the
same file at a new line really doesn't flash or rebuild before moving, and
that an emoji-bearing file's gutter numbers stay visually aligned with the
lines they label. L1 proves the arithmetic behind each of these; only a
device shows the arithmetic landing on screen.

## Worked example: `pr_diff` (W8)

`ios-curated-view-parity` W8 replaces the `diff` stub with a real renderer
that is also this PRD's only deliberate *structural* divergence from macOS
(file-list-first on iOS, one flat document on macOS). That divergence is
safe only because line resolution itself is NOT allowed to diverge — the
same `path:line` must land on the same line on both clients — which is
exactly the kind of claim a device can't check but a ported test suite can.

- **L1** (`DiffDocumentTests.swift`, `DiffAddressingTests.swift`,
  `FocusRegionStateTests.swift`'s new cases): `DiffDocumentTests` is macOS's
  14-test suite ported and passing **unmodified** — flattening order, marker
  restoration per kind (`.meta` verbatim), new-side-wins when a line is both
  a removal and an addition, the removal-row fallback for an old-side-only
  line, path-scoped vs. `nil`-path search, `rowIndices` empty-not-clamped,
  the `tooLarge` notice's singular/plural wording, a rename header, and
  `text == rows joined`. Any test that had needed a change to pass would
  have been a reported cross-client divergence, not an adjustment — none
  did. `DiffAddressingTests` covers the diff-flavoured resolvers: the
  `tooLarge` gate taking priority over every anchor/emphasis-specific rule
  (a gated diff has no rows to resolve against, so even an unusable anchor
  kind must still report the gate), "this file isn't in the diff" and "this
  line isn't in the diff" as two distinctly-worded, distinctly-assertable
  reasons, and `matchedNothing` vs. `.rows([])` regression guards. The
  `FocusRegionState` additions cover the selected-file slot (identity-scoped
  so a changed PR silently stops resolving a stale filename, survives a
  `.splitTopology` rebuild, pruned when its pane is no longer live) and the
  per-file scroll-restore trio.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): `WidthClass` named
  only by the allowlist, now including `DiffSurfaceView.swift` (and *not*
  `DiffFileListView.swift`/`DiffFileContentView.swift`, which take identical
  parameters at both widths); no truncation and no horizontal panning across
  the three new files; rows rendered through the SAME `CodeRowView` `code`
  uses (asserted by reference, not by re-deriving the gutter/wrap rules a
  second time); every scroll gated by a `case .scrollTo` decision; no
  `newN`/`oldN` COMPARISON anywhere under `iOS/` (a plain nil-coalescing read
  for gutter display is fine — resolving which row a line means is
  `DiffDocument`/`DiffAddressing`'s job, never re-derived in a view); no
  `@State` named `selectedFile`/`currentFile` (the selected file lives in
  `FocusRegionState`); every `AnchorResolution`/`EmphasisResolution` case
  name referenced in `DiffSurfaceView.swift`; and that `tooLarge` is named
  in `DiffSurfaceView.swift` at all (an honest heuristic — it proves the
  branch exists, not that it's structured to replace the whole surface;
  that structural claim is why `tooLarge` is checked FIRST in this view's
  `body`, before either width's arrangement, rather than trusted to a
  regex).
- **L3** (`make ios-build`): that the three new files and the extracted
  `CodeRowView` compile and are wired into the app target's build phase,
  with no new warnings, and that `.diff` leaving `PaneSurfaceStub`'s
  deferred-kinds table doesn't break the switch's exhaustiveness anywhere.

What's left over — genuinely **UI-observable only** — is everything the PRD
actually cares about seeing: that the anchored bypass really opens straight
into the file with **no list flash** first; that the regular-width
arrangement really shows the list and the content **at the same time**,
and that selecting a different file really doesn't lose the list; that a
line this PR deletes really lands on the same visual line on both clients
side by side; that added/removed/context/hunk-header rows are really
distinguishable in dark mode and in a greyscale screenshot (colour is one of
three signals, never the only one); and that a `tooLarge` diff really reads
as gated rather than as an empty, unremarkable PR. L1 proves the resolution
arithmetic agrees between clients; only a device shows the two clients
agreeing on screen, side by side.

## Worked example: the prose surface (W9)

`ios-curated-view-parity` W9 replaces both remaining stubs (`pr_conversation`,
`ticket`) with one renderer, and is the wedge where iOS deliberately renders
**more** of the payload than macOS does — thread grouping, resolved state,
and `conversation_error` are all on the wire and all discarded by macOS's
`MarkdownBlockDocument`. That asymmetry is exactly why this wedge's L1 suite
is unusually load-bearing: every one of those three facts, plus every
unresolved-anchor reason, is a property of a row list, not of a rendered
screen, so it is provable with no device at all.

- **L1** (`ProsePlanTests.swift`, `ConversationPlanTests.swift`,
  `TicketPlanTests.swift`, `ProseAddressingTests.swift`): every `MdBlock`/
  `MdSpan` kind maps to a row/span, including nesting (increasing `indent`,
  never flattening), `lang` surviving a fenced block, and a stable,
  ascending row `id` sequence. `ConversationPlanTests` ports
  `MarkdownBlockDocumentTests`'s ordering assertion as a row-index
  assertion — thread order, then comment order, never interleaved — and
  separately proves an inline thread's header carries `path`/`line` while a
  general thread's does not, a resolved thread's header carries the flag, and
  `conversation_error` produces a notice row when set and none when absent
  (both directions asserted, so a permanent warning on a healthy PR would be
  caught same as a missing one on a broken one). `TicketPlanTests` ports
  `TicketBlockDocumentTests`'s header/nil-assignee assertions and proves the
  display-name mapping matches macOS's `TicketBlockDocument.displayName(_:)`
  by name in the test comment. `ProseAddressingTests` is the honesty suite:
  every `Anchor`/`Emphasis` case this surface can't use resolves to
  `.unresolved`/`.matchedNothing` with a reason naming what was asked for —
  an absent comment id (naming the id and the actual comment count), an
  anchor kind a conversation can't use (naming the kind — the exact case
  macOS's `ConversationContentView` drops), a ticket section name that
  cannot be matched (naming the requested name **and** falling back to the
  description's row — both halves asserted in one test, because either half
  alone reproduces a different macOS bug), a malformed or out-of-range
  `"comment:<n>"` index (naming both the requested and actual counts), and
  that re-emphasising is a pure function — calling `resolve(emphasis:)` a
  second time carries no memory of the first call, which is what makes the
  `TicketContentView.clearEmphasis` wipe-everything defect structurally
  impossible here rather than merely avoided by care.
- **L2** (`tests/ios_policy/test_ios_view_policy.py`): `ProseSurfaceView.swift`
  reads no width class (a dedicated pin, on top of the generic allowlist
  check `DiffSurfaceView.swift` alone remains on); no truncation (no
  `prefix(`, no numeric row cap, no `lineLimit(` scoped to `codeBlockView`);
  no horizontal panning; every `scrollTo(` gated by a `case .scrollTo`
  decision; `thread.resolved`/`.path`/`.line` all referenced in the view (the
  anti-`MarkdownBlockDocument` policy, named as such in its failure message);
  `.conversationIncomplete` referenced (the client-side half of "the PRD's
  forbidden state is pinned," paired with L1's "renders when set, not when
  absent" pair); every `AnchorResolution`/`EmphasisResolution` case name
  present (paired with L1's exhaustive switches); no client-side markdown
  parsing anywhere under `iOS/` (no `AttributedString(markdown:`, no manual
  backtick or `#`-prefix scan) — a standing prohibition, not a property of
  one file; and `lang` is never discarded, banning both macOS's exact shape
  (`_ = lang`) and its client-side equivalent (a `.codeBlock` pattern that
  never binds `lang` at all). Every check from W2–W8 still passes unchanged,
  and the `PaneSurfaceStub` table — empty as of this wedge — was deleted
  along with its L1 test rather than kept as a vestigial table with no
  entries and no explanation.
- **L3** (`make ios-build`): that `ProseSurfaceView.swift` compiles and is
  wired into the app target's build phase, with no new warnings, and that
  `.prConversation`/`.ticket` leaving the stub table doesn't break the
  `PaneContentWire` switch's exhaustiveness.

What's left over — genuinely **UI-observable only** — is everything about
*seeing* the divergence from macOS land correctly: that an inline review
thread's `path:line` badge and a resolved thread's three-signal styling are
actually legible (in dark mode and in greyscale); that a `conversation_error`
notice actually sits above the partial threads rather than replacing them;
that a fenced code block in a comment actually renders monospaced rather
than as flattened prose; that re-emphasising a ticket section actually
leaves the previous section's inline-code and code-block tints alone on
screen (not just in the resolver's return value); and that the same PR,
viewed on macOS and iOS side by side, visibly shows the divergence this PRD
accepts as a risk — an inline comment and a general comment looking
identical on one client and distinct on the other; an unmatched section
anchor looking identical to a matched one on macOS and stating its own
failure on iOS. L1 proves every one of these is a fact about the row list;
only a device (two, side by side) shows the two clients disagreeing on
screen exactly where this PRD says they're allowed to.

## Coverage across all nine wedges

Every wedge from `ios-curated-view-parity` is now shipped. This table is the
honest summary: what is provable without a device (L1 pure-function logic,
L2 source-scanning policy), and what remains checkable only by hand.

| Wedge | Surface | L1 | L2 | Device-only |
|---|---|---|---|---|
| W1 | Tabs decoder correctness | ✅ | — | Tab strip rendering on a real tree |
| W2 | Verification harness + `pr_list`/queue-row marking | ✅ | ✅ | — |
| W3 | (macOS) PR conversation data/fetch | ✅ (macOS) | — | — |
| W4 | Ambient activity ticker | ✅ | ✅ | No-visible-motion while scrolled; long-fan-out memory plateau |
| W5 | Compact tab strip: focus, labels, `reason`, unread | ✅ | ✅ | Frontmost-on-arrival, scroll-position-on-switch, unread-dot reflow, background-tab isolation |
| W6 | iPad two-presentation layout | ✅ (plan only) | ✅ | The entire regular-width presentation on screen: proportions, live rotation, Split View divider drag, per-region unread legibility, Slide Over |
| W7 | `code` surface | ✅ | ✅ | Wrap/gutter rendering, anchor-in-viewport stability, re-show without flash, emoji gutter alignment |
| W8 | `pr_diff` surface | ✅ | ✅ | Anchored bypass with no list flash, side-by-side file list, cross-client line agreement on screen, dark-mode/greyscale kind legibility |
| W9 | `pr_conversation`/`ticket` prose surface | ✅ | ✅ | Thread/resolved-state/`conversation_error` legibility, fenced-code rendering, per-range emphasis surviving re-emphasis on screen, the macOS/iOS divergence seen side by side |

The pattern holds across every wedge with a rendering surface: the
**decision** (what should be shown, and what an anchor resolves to) is
provable at L1 with no device; the **rendering** of that decision — wrapping,
scrolling, colour, legibility, motion — is provable only by running the app
on real hardware and looking. A green `make kit-test`/`make python-test`/
`make ios-build` run is a necessary, not sufficient, signal for any wedge in
this table; the device-only column is what a PR body must still report on
by hand.

## Why L5 is a backplane-only layer

This section replaces the earlier "Why no simulator, anywhere" argument. That
section said the repo does not run iOS unit tests against a simulator,
anywhere, ever. The operator reversed that on 2026-11-25 (open question 12 in
`docs/plans/backplane-sequencing.md`), because the backplane changes the
balance: W11 adds a Keychain credential store, a `nostromo://pair` URL handler,
an encrypted content cache and the pairing screens; W13 adds APNs registration;
W16 adds a Notification Service Extension. The logic of all of those lives in
`NostromoKit` and is tested at L1 (`WebSocketClientTests`, `PairingClientTests`,
`DeviceCredentialTests`, `ContentCacheTests`, `EnrichmentPolicyTests`,
`PushDetailFetcherTests`). What cannot be tested there is what only runs in an
iOS process: Keychain access groups, the URL handler, the cache's file
protection class, the extension's App Group wiring. With no backplane yet, the
operator also cannot test those on a device. L5 exists for exactly that.

What the earlier argument got right, and what is kept as the rule: a check that
needs special hardware or a heavy runtime is a check that silently stops being
checked when a contributor does not have it handy, and once a simulator-bound
target exists the temptation is to route "is this actually going to work"
questions through it whether or not they need a simulator. That is why L5 is
scoped by what needs an iOS process (see the rule in L5 above), why the scope
is stated in a header on every file and checked by `tests/ios_policy`, and why
L1 and L2 stay the default home for every other check.

What changed with the reversal: a simulator no longer needs special hardware
(CI runs it on a stock macOS runner, and a developer needs only an installed
Simulator runtime), and the cost the earlier argument called incidental is
paid: `iOS/Nostromo.xcodeproj` now has a hand-edited `NostromoTests` target
(sources are listed explicitly in the project file, not in a
`PBXFileSystemSynchronizedRootGroup`, which is why the policy test checks
membership) and a committed shared `Nostromo` scheme that includes it. The
`iOS simulator build` CI job builds and tests; it keeps its name because it is a
required check.

If the target stops earning its keep (no L5 file for a release or two, or L5
tests that pass without iOS), delete it: this layer is meant to stay small.
