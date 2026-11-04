# Todo: other Mac layout tests that still depend on timing (found while fixing the scroll-test flake)

Left alone on purpose (out of scope of fix/mac-scroll-test-flake, which fixed `MotherDetailScrollTests` and `MotherDetailHarness`). They use the same harness (`MDRig`/`MD.makeRig`) but wait with a fixed `MD.pump(window, seconds:)` instead of a condition, or start with the 5 s startup action error still showing:

- `MotherOverviewAndCrewOverflowTests`: fixed `MD.pump(..., seconds: 1 / 0.6 / 0.8)` after delivering data (lines ~47, 60, 72, 94).
- `FocusSplitOversizedChildTests`: seven bare `MD.pump(window)` settles (lines ~95-167).
- `MotherDetailVerticalOverflowTests`, `MotherDetailSwitchTests`, `MotherDetailLabelWidthTests` (own stub, own `RunLoop.run(until:)` at ~83): assert layout right after an async update, relying on `makeRig`'s settle pump. A pass is the weaker outcome if the 5 s startup error clears mid-test (the layout is then shorter than the worst case they mean to measure).

Suggested fix, same recipe: `rig.awaitRendered()` (now drains the main queue first) instead of a fixed pump after an update; for tests that measure positions, `makeRig(..., startupError: false)`. Only worth doing if one of them shows up as a flake.
