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
///
/// ## The `.tooSmall` verdict (fix/detail-region-split-collapse — D6)
///
/// Zero was never the only way for a pane to be unusable. The confirmed
/// split-collapse defect leaves the detail region **34pt wide** in a 1760pt
/// split whose correct share is 879.5pt — non-zero on both axes, so the
/// original tripwire above reads it as perfectly healthy. `.tooSmall` is
/// the verdict for "a real size that is nonetheless not a usable one", kept
/// separate from `.notDrawable` so the existing zero-size meaning is
/// untouched and so a reader of the log can tell the two failure shapes
/// apart. Zero takes precedence: a zero-width pane is `.notDrawable`,
/// never `.tooSmall`, whatever its other axis measures.
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

    // MARK: 9. The split-collapse signature — non-zero, but far too narrow

    /// The live measurement from the PR-pickup capture set: the detail
    /// region landed 34pt wide (divider at x=1885, region x=1886..1919)
    /// where its correct share of the 1760pt split was 879.5pt. Content is
    /// present, it is in a window and it has been laid out — every
    /// precondition says this pane should be showing the operator
    /// something, and 34 points is not showing them anything.
    func testThirtyFourPointWidePaneWithContentIsTooSmall() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .tooSmall(reasons: [.tooNarrow]), """
            a 34pt-wide pane is the confirmed signature of a clamped split, and the original \
            zero-only tripwire read it as healthy for four days. Only .tooNarrow may be named — \
            the 481pt height is fine.
            """)
    }

    func testThirtyFourPointTallPaneWithContentIsTooSmall() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 900, boundsHeight: 34, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .tooSmall(reasons: [.tooShort]), """
            the same collapse on a horizontally-stacked split squeezes height instead of width — \
            the verdict must name the axis that actually failed.
            """)
    }

    func testBothDimensionsBelowTheThresholdNamesBothReasonsWidthFirst() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 40, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .tooSmall(reasons: [.tooNarrow, .tooShort]), """
            deterministic width-then-height ordering, matching the existing zero-size case — the \
            summary string is compared for equality by the view's rate limiter, so a \
            non-deterministic reason order would break de-duplication.
            """)
    }

    // MARK: 10. Zero takes precedence over too-small

    func testZeroWidthWithASmallButNonZeroHeightIsNotDrawableRatherThanTooSmall() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 0, boundsHeight: 34, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .notDrawable(reasons: [.zeroWidth]), """
            a pane with no drawable size at all is a different failure from a pane with a real \
            but unusable one, and must keep reporting as .notDrawable — the two have different \
            causes and collapsing them would blunt both.
            """)
    }

    // MARK: 11. The non-firing cases — the actual point of the new verdict

    /// The measured healthy split: 879.5pt each side. If the new threshold
    /// can fire on this, it is worse than useless.
    func testTheMeasuredHealthyDetailRegionIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 879.5, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            this is the restored-at-launch measurement — the correct, reachable target. It must \
            never trip the wire.
            """)
    }

    func testALegitimatelyNarrowButUsablePaneIsHealthy() {
        // 120pt: narrow enough to be a deliberate sidebar-ish pane, wide
        // enough to show something. Pins the shipped threshold value.
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "sidebar", hasContent: true, isLoading: false,
            boundsWidth: 120, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            a deliberately narrow pane is a legitimate layout, not a bug — the file's own doc \
            comment is explicit that a tripwire firing on a healthy pane is worse than no \
            tripwire, because it trains readers to ignore the log.
            """)
    }

    func testAPaneExactlyAtTheMinimumUsableExtentIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "sidebar", hasContent: true, isLoading: false,
            boundsWidth: PaneFirstPaintAudit.minimumUsableExtent,
            boundsHeight: PaneFirstPaintAudit.minimumUsableExtent,
            hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            the boundary is inclusive: exactly the minimum usable extent is usable. Pinned so the \
            threshold can be retuned later without anyone having to guess which side of it the \
            boundary sits on.
            """)
    }

    func testAPaneJustAboveTheMinimumUsableExtentIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "sidebar", hasContent: true, isLoading: false,
            boundsWidth: PaneFirstPaintAudit.minimumUsableExtent + 0.5, boundsHeight: 481,
            hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy)
    }

    func testAPaneJustBelowTheMinimumUsableExtentIsTooSmall() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: PaneFirstPaintAudit.minimumUsableExtent - 0.5, boundsHeight: 481,
            hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .tooSmall(reasons: [.tooNarrow]), """
            the other side of the inclusive boundary — strictly below the minimum is too small.
            """)
    }

    // MARK: 12. The four preconditions gate .tooSmall exactly as they gate .notDrawable

    func testAThirtyFourPointPaneWithNoContentIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: false, isLoading: false,
            boundsWidth: 34, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            a pane with nothing to draw yet has no size it needs to be — the new verdict must be \
            gated by exactly the same four preconditions as the existing one, not loosened.
            """)
    }

    func testAThirtyFourPointPaneThatIsLoadingIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: true,
            boundsWidth: 34, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy)
    }

    func testAThirtyFourPointPaneWithNoWindowIsHealthy() {
        // An unselected tab: no window, no drawable size, by design.
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.1", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 481, hasWindow: false, layoutPassCount: 1
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            an unselected tab is the single most common pane state in a tabs region — if the new \
            verdict fired on those, the log would be nothing but false positives.
            """)
    }

    func testAThirtyFourPointPaneBeforeItsFirstLayoutPassIsHealthy() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 481, hasWindow: true, layoutPassCount: 0
        )
        XCTAssertEqual(PaneFirstPaintAudit.verdict(m), .healthy, """
            before the first layout pass a pane's bounds are not evidence of anything — the split \
            has not had a chance to size it yet.
            """)
    }

    // MARK: 13. summary(of:) renders the new verdict deterministically

    func testSummaryRendersTheTooSmallVerdictExactly() {
        let m = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 481, hasWindow: true, layoutPassCount: 1
        )
        XCTAssertEqual(
            PaneFirstPaintAudit.summary(of: m),
            "pane=detail.0 hasContent=true loading=false hasWindow=true layoutPasses=1 " +
            "bounds=34.0x481.0 verdict=tooSmall(tooNarrow)",
            """
            the exact rendered line, so the new verdict is readable in the log and so the string \
            stays a faithful function of the Measurements — anything else in it (a timestamp, an \
            object identity) would defeat the view's rate limiter.
            """
        )
    }

    func testSummaryIsDeterministicForEqualTooSmallMeasurements() {
        let a = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 40, hasWindow: true, layoutPassCount: 3
        )
        let b = PaneFirstPaintAudit.Measurements(
            paneId: "detail.0", hasContent: true, isLoading: false,
            boundsWidth: 34, boundsHeight: 40, hasWindow: true, layoutPassCount: 3
        )
        XCTAssertEqual(PaneFirstPaintAudit.summary(of: a), PaneFirstPaintAudit.summary(of: b), """
            the rate limiter compares these strings across layout passes to decide whether a \
            violation is new — a two-reason .tooSmall verdict must render identically every time \
            or the same collapsed pane would log on every single pass.
            """)
    }
}
