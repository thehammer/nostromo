# iOS verification

`iOS/Nostromo.xcodeproj` has exactly one target — the application itself.
There is no `ios-test` make target, no `swift test` invocation for the app,
and no `xcodebuild`/`swift test` job in `.github/workflows/`. Before
`ios-curated-view-parity` W2, the iOS app's own view code (12 Swift files,
~2,300 lines, all view code — the store, transport, and wire types live in
`Shared/NostromoKit`, consumed by both platforms) had no test coverage at
all. Its recent history is three reactive switch-exhaustiveness fixes, each
landing as a comment explaining after the fact why a particular case was a
stub — a target maintained by the compiler complaining, one incident at a
time.

That gap is what this doc is about, and why it's split into three layers
rather than one. Run all three before considering an iOS change to pane
rendering, addressing, or queue marking complete.

## L1 — logic

**What:** Pure value types and pure functions in `Shared/NostromoKit`,
covered by XCTest in `Shared/NostromoKit/Tests/NostromoKitTests/`.
Everything the iOS *and* macOS clients share — wire decoding, the
`DaemonStore` message-routing logic, `PerriPRRowModel`/`PaneAddress.marks`,
`PaneSurfaceStub`'s stub-message table — lives here, not in either app
target, specifically so it can be tested this way.

**Run:**

```
make kit-test
```

which is `swift test --package-path Shared/NostromoKit` — a plain SwiftPM
test run. **No paired iOS device and no simulator required or used.** As of
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
`LayoutChangeClassifierTests`) — except macOS's equivalent suite runs only
as part of `mac-test`, which is itself local-only (device/simulator-bound
`xcodebuild`), while this one actually runs in CI, because it's Python
scanning Swift text rather than a compiled Swift test bundle.

**Run:**

```
make python-test
```

which runs `tests/ios_policy` alongside `tests/transcript_load` and
`tests/doctor`. This is the same command CI runs
(`.github/workflows/ci.yml`, the `python-tooling` job, on `macos-latest`),
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

**Why this is local-only.** `IOS_DEVICE_ID` names a specific paired
physical iPhone. That's not incidental — it's the whole reason this layer
exists separately from L2: this repo does not run iOS unit tests against a
simulator, anywhere, ever (see below), so the only way to get L3's
signal — "does this actually compile for the real target" — is against
real hardware, which CI doesn't have.

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
| The **live rotation transition** preserves both regions' frontmost tabs and both surfaces' scroll positions, with nothing reloading and nothing jumping to the top | A claim about a live view hierarchy mid-transition; there is no test target on this platform and no simulator in CI |
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

## Why no simulator, anywhere

It would be easy to ask: why not add an `xcodebuild test -destination
'platform=iOS Simulator'` target and get real Swift test execution instead
of a Python text scan? Two reasons, one load-bearing and one incidental.

The load-bearing one: the whole point of splitting verification into layers
that don't need a device is that a check nobody can run locally without
attaching hardware is a check that silently stops being checked the moment
a contributor doesn't have that hardware handy. A simulator sidesteps the
*device* requirement, but not the discipline problem — the moment a
simulator-bound test target exists, the temptation is to route "is this
actually going to work" questions through it whether or not the answer
needs a simulator, and now everything as fast as it is slow. L1 and L2 stay
fast, headless, and CI-eligible by construction: only real behavior that
`xcodebuild build` (L3) or a device (never automated) can answer is allowed
to require either.

The incidental one, recorded here so it isn't rediscovered by someone
re-opening this question: `iOS/Nostromo.xcodeproj` lists its sources
through explicit `PBXBuildFile`/`PBXFileReference`/`PBXGroup` entries rather
than a `PBXFileSystemSynchronizedRootGroup`, and has no checked-in shared
scheme (`make ios-build`'s `-scheme Nostromo` resolves via Xcode
autocreation, not a committed `.xcscheme`). Adding a test target means
hand-editing four `project.pbxproj` sections and committing a scheme — real
cost, for a capability (simulator-bound `XCTest`) this doc has already
argued against wanting.

Adding an `xcodebuild` job to CI at all — simulator or device — remains a
deliberate deferral, tracked in `.claude/prds/ios-curated-view-parity.md`,
not an oversight.
