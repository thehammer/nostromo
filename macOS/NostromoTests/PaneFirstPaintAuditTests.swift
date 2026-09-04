import XCTest
// PaneFirstPaintAudit is compiled into this target directly (logic test —
// no host app, no window, no AppKit needed). No module imports needed.

// MARK: - PaneFirstPaintAuditTests

/// Behavioural tests for `PaneFirstPaintAudit.verdict`/`summary` — the
/// diagnostics tripwire that detects "content was pushed to a pane, but the
/// pane has zero drawable size" (see the primary repo's
/// `.claude/bugs/open/2026-08-14-queue-pane-renders-blank-on-the-first-pane-content-push-after-a-fresh-session-app-launch.md`
/// for the full investigation record this instrument exists to catch a
/// recurrence of).
///
/// This is diagnostics-only: there is no reproduced bug and no fix in this
/// branch, just an observability instrument plus the tests pinning its
/// contract. `PaneFirstPaintAudit.swift` doesn't exist yet — these tests are
/// expected to fail to compile/run until it's added (RED phase).
///
/// The negative cases (3-6 below) are the actual point of this suite: a
/// tripwire that fires during normal healthy operation — a pane that simply
/// hasn't received content yet, is mid-load, isn't in a window, or hasn't
/// had a layout pass — is worse than no tripwire at all, because it trains
/// whoever reads the log to ignore it. `verdict` must stay silent unless
/// every one of hasContent/isLoading/hasWindow/layoutPassCount lines up to
/// say "this pane really should be drawable right now" AND the bounds say
/// it isn't.
final class PaneFirstPaintAuditTests: XCTestCase {

    // MARK: 1. Fully healthy pane

    func testFullyHealthyPaneIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: true, isLoading: false,
            boundsWidth: 900, boundsHeight: 600, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            content present, in a window, laid out, non-zero bounds on both axes — nothing about \
            this pane should ever trip the wire.
            """)
    }

    // MARK: 2. The regression this bug report is about

    /// Pins the exact shape of the bug documented in the primary repo's
    /// `.claude/bugs/open/2026-08-14-queue-pane-renders-blank-on-the-first-pane-content-push-after-a-fresh-session-app-launch.md`:
    /// content pushed, pane in a window, laid out at least once, but zero
    /// height — must be flagged, and flagged with the specific dimension
    /// that's actually wrong, not the other one.
    func testQueuePaneZeroHeightWithContentIsNotDrawable() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "queue", hasContent: true, isLoading: false,
            boundsWidth: 900, boundsHeight: 0, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .notDrawable(reasons: [.zeroHeight]), """
            content is present, the pane has a window, and it's had a layout pass — a zero-height \
            bounds at that point is exactly the fresh-launch first-paint bug this diagnostic exists \
            to catch. Must name only .zeroHeight, since width (900) is fine.
            """)
    }

    // MARK: 3. No content yet is healthy, even with zero bounds

    func testNoContentYetWithZeroBoundsIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: false, isLoading: false,
            boundsWidth: 0, boundsHeight: 0, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            a pane before its first content push is normal and must never trip the wire, no matter \
            how small its bounds are.
            """)
    }

    // MARK: 4. Loading is healthy, even with zero bounds

    func testLoadingWithZeroBoundsIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: true, isLoading: true,
            boundsWidth: 0, boundsHeight: 0, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            a transient loading frame is expected to have nothing to draw yet — isLoading must \
            suppress the tripwire even with zero bounds.
            """)
    }

    // MARK: 5. No window is healthy, regardless of content/bounds

    func testNoWindowIsHealthyEvenWithContentAndZeroBounds() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: true, isLoading: false,
            boundsWidth: 0, boundsHeight: 0, hasWindow: false, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            a pane in an unselected tab or a window mid-construction has no drawable size by \
            design — that's not evidence of a bug, however loud the other fields look.
            """)
    }

    // MARK: 6. No layout pass yet is healthy, whatever else is set

    func testNoLayoutPassYetIsHealthyRegardlessOfOtherFields() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: true, isLoading: false,
            boundsWidth: 0, boundsHeight: 0, hasWindow: true, layoutPassCount: 0
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            before the first layout pass there's no evidence either way — layoutPassCount == 0 must \
            suppress the tripwire no matter what else is set.
            """)
    }

    // MARK: 7. Both dimensions non-positive names both reasons, width first

    func testBothDimensionsNonPositiveNamesBothReasonsWidthFirst() {
        // boundsHeight is -1, not just 0, to make sure the implementation
        // checks "<= 0" and not "== 0".
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "p1", hasContent: true, isLoading: false,
            boundsWidth: 0, boundsHeight: -1, hasWindow: true, layoutPassCount: 1
        )
        guard case .notDrawable(let reasons) = PaneFirstPaintAudit.verdict(m) else {
            XCTFail("expected .notDrawable when both dimensions are <= 0 with all other preconditions satisfied")
            return
        }
        XCTAssertEqual(reasons, [.zeroWidth, .zeroHeight], """
            both reasons must be present in a deterministic width-then-height order — assert the \
            exact array, not just "contains both".
            """)
    }

    // MARK: 8. summary(of:) is deterministic

    func testSummaryIsDeterministicForEqualMeasurements() {
        let a = PaneFirstPaintAudit.Measurements(
            paneId: "queue", hasContent: true, isLoading: false,
            boundsWidth: 900, boundsHeight: 0, hasWindow: true, layoutPassCount: 1
        )
        let b = PaneFirstPaintAudit.Measurements(
            paneId: "queue", hasContent: true, isLoading: false,
            boundsWidth: 900, boundsHeight: 0, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(a, b, "sanity check: the two separately-constructed Measurements values must actually be equal")
        XCTAssertEqual(PaneFirstPaintAudit.summary(of: a), PaneFirstPaintAudit.summary(of: b), """
            production code will use this string to rate-limit repeated log lines — if two \
            logically-identical measurements produced different summary strings (e.g. because it \
            embedded a timestamp or object identity instead of only the Measurements fields), the \
            rate limiter would never actually de-duplicate anything.
            """)
    }
}
