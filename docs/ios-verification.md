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
