# iOS view policy tests

Run with:

```
python3 -m unittest discover -s tests/ios_policy -v
```

These are source-scanning policy tests over `iOS/Nostromo/**/*.swift` — not
tests of app behaviour, tests of what the source *looks like*. They exist
because `iOS/Nostromo.xcodeproj` has exactly one target (the app itself), so
nothing runs an iOS unit test with no paired device and no simulator. This
directory is what fills that gap for the properties that matter and can be
checked as text.

## Why this exists (ios-curated-view-parity, W2)

iOS's pane-content rendering (`iOS/Nostromo/Views/Panes/PaneSurfaceView.swift`
and its siblings) is agent-authored-content plumbing shared with macOS, but
until W2 it had no test coverage at all — its recent history is three
reactive switch-exhaustiveness fixes, each a comment explaining after the
fact why a case was a stub. That is a target maintained by the compiler
complaining, one incident at a time. W2 through W9 add four real content
renderers on top of that plumbing; without a harness, every one of them is a
renderer that can break silently on the next wire change.

## The three-layer verification model

See `docs/ios-verification.md` for the full picture. In short:

- **L1 — logic.** Pure value types in `Shared/NostromoKit`, covered by
  XCTest, run by `make kit-test`. No simulator, no device.
- **L2 — wiring and policy.** This directory. Runs as part of
  `make python-test`, which already runs in CI (`.github/workflows/ci.yml`,
  the `python-tooling` job) on `macos-latest`.
- **L3 — compile.** `make ios-build`. Device-bound (the `Makefile`'s
  `IOS_DEVICE_ID` targets a paired physical iPhone), so it is local-only —
  it does not run in CI and this suite cannot substitute for it.

No iOS unit-test target or scheme is added to `Nostromo.xcodeproj`, and no
`xcodebuild`/`swift test` job is added to CI. Both are deliberate — see
`docs/ios-verification.md` for why — and this directory (a Python source
scan, not a Swift test bundle) is the mechanism that makes the L2 layer
possible without either.

## A policy is added by the wedge that makes it true

`test_ios_view_policy.py` currently covers exactly the checks W2
(`ios-curated-view-parity`) makes true: the `.code` raw-text dump is gone,
`address:` reaches the pane surface, every `pr_list` row passes `marked:`,
every deferred-content switch stays exhaustive, and every stub string comes
from `PaneSurfaceStub`. Each later wedge (W4, W5, W7, W8, W9) adds its own
checks alongside its own feature work, rather than this file trying to
anticipate everything up front.

A policy suite introduced in a state where some of its checks already fail
is a red build. A policy suite introduced in a state where its checks
*cannot* fail is decoration — the exact defect class
`tests/transcript_load`'s `UniversalVacuityTests` /
`VacuityTestActuallyBitesTests` pattern exists to catch, one level up. This
suite follows the same discipline: **every check has a companion "bites"
test**, run against a synthetic source string rather than the real tree,
proving the check can actually fail before trusting it to guard anything.

## The no-skip constraint

The CI job this suite runs in greps its output for `... skipped` and
`(skipped=` and fails the build on either — a skipped test is a vacuously
passing test, which is the same defect this whole suite exists to prevent
one level up again. `test_ios_view_policy.py` must never introduce a
`@unittest.skip`, a `self.skipTest(...)`, or any other skip mechanism; a
dedicated test in this file (`SuiteNeverSkipsTests`) checks its own source
for exactly that as a second, local guard.
