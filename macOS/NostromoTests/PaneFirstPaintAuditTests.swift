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

// MARK: - Shared construction helpers

/// The reporting/rate-limit suites below are almost entirely *pairwise*
/// comparisons: two measurements that differ in exactly one field, and the
/// question is what the audit does about that one difference. Spelling all
/// seven fields out twice per test (the style of the verdict suite above,
/// where each measurement stands alone) would bury the single varying field
/// in noise, so those suites build their measurements through this helper
/// and name only what differs.
private func paneMeasurement(
    paneId: String = "detail.0",
    hasContent: Bool = true,
    isLoading: Bool = false,
    width: Double,
    height: Double,
    hasWindow: Bool = true,
    layoutPassCount: Int = 1
) -> PaneFirstPaintAudit.Measurements {
    PaneFirstPaintAudit.Measurements(
        paneId: paneId, hasContent: hasContent, isLoading: isLoading,
        boundsWidth: width, boundsHeight: height,
        hasWindow: hasWindow, layoutPassCount: layoutPassCount
    )
}

// MARK: - PaneFirstPaintAuditReportingTests

/// Behavioural tests for `PaneFirstPaintAudit.shouldReport(_:previous:)` —
/// the sampling rule that decides whether an unhealthy verdict is worth
/// putting on the wire *yet*.
///
/// `.tooSmall` on its own false-positives badly. Measured on the
/// reproduction bench for fix/detail-region-split-collapse, on panes that
/// ended up completely healthy:
///
/// | pane     | pass | measured    | settled at    |
/// |----------|------|-------------|---------------|
/// | queue    | 1    | 639.5 x 36  | 639.5 x 485.5 |
/// | queue    | 6    | 639.5 x 56  | 639.5 x 485.5 |
/// | detail.0 | 1    | 48 x 10     | 639.5 x 459.5 |
///
/// 48 is *wider* than the real failure's 34pt, so no threshold can separate
/// a healthy pane mid-layout from a genuinely collapsed one. The
/// discriminator is not how small the pane is but whether the **offending
/// axis** has stopped moving — and it must be checked per-axis, because the
/// bench's genuinely-collapsed detail panes measured 44 x 434.5 then
/// 44 x 385.5: width pinned at its floor while height was still arriving.
/// Requiring *both* axes to hold still would have missed the real bug.
///
/// As everywhere else in this file: a tripwire that fires on a healthy pane
/// is worse than no tripwire, so the suite leans on the non-firing cases.
final class PaneFirstPaintAuditReportingTests: XCTestCase {

    // MARK: 14. A healthy pane is never reported

    func testAHealthyPaneIsNeverReported() {
        let m = paneMeasurement(width: 900, height: 600)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            a healthy verdict has nothing to report, with or without history.
            """)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: m), """
            a healthy pane that has held perfectly still is still healthy — "unchanged" is only a \
            discriminator once the verdict says something is wrong.
            """)
    }

    // MARK: 15. .notDrawable reports immediately, whatever the history

    func testAZeroSizedPaneIsReportedOnItsFirstSightingWithNoPreviousMeasurement() {
        let m = paneMeasurement(paneId: "queue", width: 900, height: 0)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            pre-existing behaviour that must not regress: a pane with content, a window and a \
            completed layout pass that has no drawable size at all is reported at once — it is \
            usually not going to lay out again, so waiting for a second sighting would mean never \
            reporting the original first-paint bug.
            """)
    }

    func testAZeroSizedPaneIsReportedEvenWhileItsOtherAxisIsStillMoving() {
        let m = paneMeasurement(paneId: "queue", width: 0, height: 481, layoutPassCount: 2)
        let previous = paneMeasurement(paneId: "queue", width: 0, height: 300, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            the settling rule is scoped to .tooSmall only — .notDrawable must never be delayed or \
            suppressed by a still-changing measurement.
            """)
    }

    func testAZeroSizedPaneIsReportedEvenWhenEverythingHasChangedSinceTheLastPass() {
        let m = paneMeasurement(paneId: "queue", width: 0, height: 0, layoutPassCount: 2)
        let previous = paneMeasurement(paneId: "queue", width: 900, height: 600, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous))
    }

    // MARK: 16. .tooSmall has nothing to compare on its first sighting

    func testATooSmallPaneIsNotReportedOnItsFirstSighting() {
        let m = paneMeasurement(width: 34, height: 481)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            with no previous measurement there is no way to tell a collapsed pane from a healthy \
            one still on its way to a real size, and the file's standing rule breaks the tie in \
            favour of silence.
            """)
    }

    // MARK: 17. The three measured healthy transients must stay silent

    /// Each row of the bench table above, on its first sighting. These are
    /// the false positives that motivated the whole rule.
    func testTheMeasuredHealthyQueueTransientAtPassOneIsNotReported() {
        let m = paneMeasurement(paneId: "queue", width: 639.5, height: 36)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            measured on the bench: this queue pane settled at 639.5 x 485.5 and was entirely \
            healthy. Reporting it would be a false positive.
            """)
    }

    func testTheMeasuredHealthyQueueTransientAtPassSixIsNotReported() {
        let m = paneMeasurement(paneId: "queue", width: 639.5, height: 56, layoutPassCount: 6)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            six passes in and still 56pt tall — "it has had plenty of passes by now" is not the \
            discriminator, so a high layoutPassCount must not make the audit any more willing to \
            report a first sighting.
            """)
    }

    func testTheMeasuredHealthyDetailTransientAtPassOneIsNotReported() {
        let m = paneMeasurement(width: 48, height: 10)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: nil), """
            48 x 10 on a pane that settled at 639.5 x 459.5 — and 48 is *wider* than the real \
            failure's 34pt, which is precisely why no threshold could ever separate these two \
            populations.
            """)
    }

    /// The queue pane's two bench sightings in sequence: the offending axis
    /// (height) moved between them, so it is still settling.
    func testTheMeasuredHealthyQueuePaneIsNotReportedWhileItsHeightIsStillArriving() {
        let m = paneMeasurement(paneId: "queue", width: 639.5, height: 56, layoutPassCount: 6)
        let previous = paneMeasurement(paneId: "queue", width: 639.5, height: 36, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            width held still between the two passes, but width is not the offending axis — the \
            verdict is .tooShort, and the height moved 36 -> 56. Checking the wrong axis (or "any \
            axis held still") would turn this healthy pane into a report.
            """)
    }

    // MARK: 18. The real failure: one axis pinned, the other still arriving

    /// The bench's genuinely-collapsed detail pane, measured across two
    /// passes: `44 x 434.5` then `44 x 385.5`. Width is pinned at its
    /// floor; height is still moving. This MUST report — a rule that waited
    /// for both axes to hold still would have missed the actual bug.
    func testAPaneWhoseWidthIsPinnedAtItsFloorIsReportedEvenWhileItsHeightIsStillMoving() {
        let m = paneMeasurement(width: 44, height: 385.5, layoutPassCount: 2)
        let previous = paneMeasurement(width: 44, height: 434.5, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            this is the real defect as measured on the bench. The verdict is .tooNarrow, and the \
            width has not budged off 44 across two passes — that is a clamped split, not a pane \
            mid-layout. The height still changing is irrelevant to a width violation.
            """)
    }

    func testAPaneThatStaysCollapsedAcrossPassesIsReported() {
        let m = paneMeasurement(width: 34, height: 481, layoutPassCount: 5)
        let previous = paneMeasurement(width: 34, height: 481, layoutPassCount: 4)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            34pt wide and holding — the confirmed signature of the split-collapse defect. If this \
            did not report, the instrument would have nothing left to catch.
            """)
    }

    // MARK: 19. .tooNarrow keys off width only

    func testANarrowPaneIsNotReportedWhileItsWidthIsStillChanging() {
        let m = paneMeasurement(width: 48, height: 481, layoutPassCount: 2)
        let previous = paneMeasurement(width: 34, height: 481, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            the offending axis is still moving — the pane is on its way somewhere, even if it is \
            currently below the threshold.
            """)
    }

    func testANarrowPaneIsReportedWhenItsWidthHoldsWhileItsHeightChangesFreely() {
        // Both heights are comfortably above the threshold, so the verdict
        // really is .tooNarrow alone — a height that dipped below 120 would
        // add .tooShort and pull in the stricter both-axes rule, which is a
        // different case (see 21 below).
        let m = paneMeasurement(width: 34, height: 200, layoutPassCount: 2)
        let previous = paneMeasurement(width: 34, height: 900, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            a 700pt swing on the healthy axis says nothing about a width violation — the width has \
            not moved off 34, and that is the whole finding.
            """)
    }

    // MARK: 20. .tooShort keys off height only

    func testAShortPaneIsReportedWhenItsHeightHoldsWhileItsWidthChangesFreely() {
        let m = paneMeasurement(paneId: "queue", width: 700, height: 56, layoutPassCount: 2)
        let previous = paneMeasurement(paneId: "queue", width: 639.5, height: 56, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            the verdict is .tooShort and the height has not moved — the pane is pinned short even \
            though the window is evidently still resizing it horizontally.
            """)
    }

    func testAShortPaneIsNotReportedWhileItsHeightIsStillChanging() {
        let m = paneMeasurement(paneId: "queue", width: 639.5, height: 60, layoutPassCount: 2)
        let previous = paneMeasurement(paneId: "queue", width: 639.5, height: 56, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            a 4pt move is still a move — the offending axis has not settled, so there is no \
            evidence of a collapse yet.
            """)
    }

    // MARK: 21. Two reasons require both axes to have settled

    func testAPaneSmallOnBothAxesIsReportedOnlyWhenBothAxesHaveSettled() {
        let m = paneMeasurement(width: 48, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(width: 48, height: 10, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            both offending axes have stopped moving, so both violations are real.
            """)
    }

    func testAPaneSmallOnBothAxesIsNotReportedWhileItsWidthIsStillChanging() {
        let m = paneMeasurement(width: 48, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(width: 34, height: 10, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            one settled axis is not enough when both are named — the pane is demonstrably still \
            being laid out.
            """)
    }

    func testAPaneSmallOnBothAxesIsNotReportedWhileItsHeightIsStillChanging() {
        let m = paneMeasurement(width: 48, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(width: 48, height: 40, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous))
    }

    func testAPaneSmallOnBothAxesIsNotReportedWhileBothAxesAreStillChanging() {
        let m = paneMeasurement(width: 48, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(width: 34, height: 40, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous))
    }

    // MARK: 22. The layout-pass counter is not part of the comparison

    func testAPaneIsStillReportedWhenOnlyItsLayoutPassCountHasChanged() {
        let m = paneMeasurement(width: 34, height: 481, layoutPassCount: 9)
        let previous = paneMeasurement(width: 34, height: 481, layoutPassCount: 1)
        XCTAssertTrue(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            the counter increments on every pass by definition, so "previous differs" must never \
            be read off the whole Measurements value — only off the offending axis. Reading it off \
            equality of the two Measurements would silence every real report.
            """)
    }

    // MARK: 23. The four preconditions still dominate the settling rule

    /// Each of these has an *identical* previous measurement — i.e. the
    /// geometry has demonstrably settled — and must still stay silent,
    /// because the verdict is `.healthy` and a settled healthy pane is just
    /// a pane.
    func testASettledTinyPaneWithNoContentIsNotReported() {
        let m = paneMeasurement(hasContent: false, width: 34, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(hasContent: false, width: 34, height: 10, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            a pane before its first content push has no size it needs to be, however long it holds \
            that size. The preconditions gate reporting exactly as they gate the verdict.
            """)
    }

    func testASettledTinyPaneThatIsLoadingIsNotReported() {
        let m = paneMeasurement(isLoading: true, width: 34, height: 10, layoutPassCount: 2)
        let previous = paneMeasurement(isLoading: true, width: 34, height: 10, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous))
    }

    func testASettledTinyPaneWithNoWindowIsNotReported() {
        let m = paneMeasurement(paneId: "detail.1", width: 34, height: 10, hasWindow: false, layoutPassCount: 2)
        let previous = paneMeasurement(paneId: "detail.1", width: 34, height: 10, hasWindow: false, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            an unselected tab holds a nonsense size indefinitely and by design — this is the single \
            most common way a settled-and-tiny pane arises, and reporting it would drown the log.
            """)
    }

    func testASettledTinyPaneBeforeItsFirstLayoutPassIsNotReported() {
        let m = paneMeasurement(width: 34, height: 10, layoutPassCount: 0)
        let previous = paneMeasurement(width: 34, height: 10, layoutPassCount: 0)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            no layout pass yet means the bounds are not evidence of anything, and two \
            not-yet-laid-out sightings are not evidence twice over.
            """)
    }

    func testASettledZeroSizedPaneWithNoContentIsNotReported() {
        let m = paneMeasurement(hasContent: false, width: 0, height: 0, layoutPassCount: 2)
        let previous = paneMeasurement(hasContent: false, width: 0, height: 0, layoutPassCount: 1)
        XCTAssertFalse(PaneFirstPaintAudit.shouldReport(m, previous: previous), """
            .notDrawable reports unconditionally, but only once the preconditions have actually \
            produced a .notDrawable verdict — "always report" must not leak past the guard.
            """)
    }
}

// MARK: - PaneFirstPaintAuditViolationKeyTests

/// Behavioural tests for `PaneFirstPaintAudit.violationKey(of:)` — the
/// rate-limit *identity* of a violation, as distinct from `summary(of:)`,
/// the line that gets logged.
///
/// `PaneContentNSView` rate-limits its `.error` tripwire by comparing a
/// string across layout passes. It used `summary(of:)` — which names
/// `layoutPasses=N`, incrementing every single pass — so it never
/// deduplicated anything. Harmless while the only verdict was
/// `.notDrawable` (a zero-size pane usually stops laying out); not harmless
/// once `.tooSmall` fires on a pane that is alive and relaying out, where
/// it was observed flooding the log thousands of times in a single run.
///
/// The key must therefore ignore the pass counter and *nothing else*: every
/// other field is part of the violation's identity, and dropping one would
/// silently merge two distinct violations into one report.
final class PaneFirstPaintAuditViolationKeyTests: XCTestCase {

    // MARK: 24. The defect that motivated the key

    func testMeasurementsDifferingOnlyInLayoutPassCountShareAViolationKey() {
        let a = paneMeasurement(width: 34, height: 481, layoutPassCount: 1)
        let b = paneMeasurement(width: 34, height: 481, layoutPassCount: 87)
        XCTAssertEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b), """
            this is the whole reason the function exists. A pane stuck in one bad state produces a \
            new measurement every layout pass differing only in the counter; if that changed the \
            rate-limit key, the limiter would log every pass — which is exactly the flood that was \
            observed.
            """)
    }

    func testTheSummaryStillDistinguishesWhatTheViolationKeyDeliberatelyIgnores() {
        let a = paneMeasurement(width: 34, height: 481, layoutPassCount: 1)
        let b = paneMeasurement(width: 34, height: 481, layoutPassCount: 87)
        XCTAssertNotEqual(PaneFirstPaintAudit.summary(of: a), PaneFirstPaintAudit.summary(of: b), """
            the two functions are deliberately different: the summary is what a human reads and it \
            still reports how many passes have happened. Pinning this keeps the split honest — if \
            someone "simplified" violationKey back into summary, this test and the one above \
            cannot both pass.
            """)
    }

    // MARK: 25. Every other field is part of the violation's identity

    /// Each of these pairs is chosen to differ in exactly one field *and*
    /// share a verdict, so the test fails if that field is dropped from the
    /// key rather than passing incidentally on a differing `verdict=`.
    func testADifferentPaneIdProducesADifferentViolationKey() {
        let a = paneMeasurement(paneId: "queue", width: 900, height: 600)
        let b = paneMeasurement(paneId: "detail.0", width: 900, height: 600)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b), """
            two panes in the same bad state are two violations, not one — rate-limiting them \
            together would hide the second pane entirely.
            """)
    }

    func testADifferentWidthProducesADifferentViolationKey() {
        let a = paneMeasurement(width: 200, height: 600)
        let b = paneMeasurement(width: 300, height: 600)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b), """
            a pane that moves from one bad width to another is in a new state and deserves a fresh \
            report.
            """)
    }

    func testADifferentHeightProducesADifferentViolationKey() {
        let a = paneMeasurement(width: 900, height: 600)
        let b = paneMeasurement(width: 900, height: 700)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b))
    }

    func testADifferentHasContentProducesADifferentViolationKey() {
        let a = paneMeasurement(hasContent: true, width: 900, height: 600)
        let b = paneMeasurement(hasContent: false, width: 900, height: 600)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b), """
            hasContent is one of the four preconditions and is what makes a measurement damning or \
            innocuous — the geometry here is healthy in both cases precisely so this fails if the \
            field is dropped, rather than passing off a differing verdict.
            """)
    }

    func testADifferentIsLoadingProducesADifferentViolationKey() {
        let a = paneMeasurement(isLoading: false, width: 900, height: 600)
        let b = paneMeasurement(isLoading: true, width: 900, height: 600)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b))
    }

    func testADifferentHasWindowProducesADifferentViolationKey() {
        let a = paneMeasurement(width: 900, height: 600, hasWindow: true)
        let b = paneMeasurement(width: 900, height: 600, hasWindow: false)
        XCTAssertNotEqual(PaneFirstPaintAudit.violationKey(of: a), PaneFirstPaintAudit.violationKey(of: b))
    }

    // MARK: 26. The key names the verdict

    /// `.tooSmall` and `.notDrawable` cannot coincide on geometry — that is
    /// what separates them — so the geometry necessarily differs and only
    /// the `verdict=` fragment is compared.
    func testTheViolationKeyNamesTheVerdictSoTheTwoFailureShapesAreNeverRateLimitedTogether() {
        let tooSmall = paneMeasurement(width: 34, height: 481)
        let notDrawable = paneMeasurement(width: 0, height: 481)
        let tooSmallFragment = verdictFragment(of: PaneFirstPaintAudit.violationKey(of: tooSmall))
        let notDrawableFragment = verdictFragment(of: PaneFirstPaintAudit.violationKey(of: notDrawable))
        XCTAssertEqual(tooSmallFragment, "verdict=tooSmall(tooNarrow)")
        XCTAssertEqual(notDrawableFragment, "verdict=notDrawable(zeroWidth)")
        XCTAssertNotEqual(tooSmallFragment, notDrawableFragment, """
            a collapsed pane and a zero-size pane are different failures with different causes; \
            the key must keep them apart so one cannot rate-limit the other into silence.
            """)
    }

    // MARK: 27. The key and the summary can never disagree about the verdict

    func testTheViolationKeyAndTheSummaryAgreeOnTheVerdictForEveryVerdictShape() {
        let cases: [(String, PaneFirstPaintAudit.Measurements)] = [
            ("healthy", paneMeasurement(width: 900, height: 600)),
            ("no content", paneMeasurement(hasContent: false, width: 0, height: 0)),
            ("zero width", paneMeasurement(width: 0, height: 481)),
            ("zero on both axes", paneMeasurement(width: 0, height: 0)),
            ("too narrow", paneMeasurement(width: 34, height: 481)),
            ("too short", paneMeasurement(width: 900, height: 34)),
            ("too small on both axes", paneMeasurement(width: 48, height: 10))
        ]
        for (label, m) in cases {
            let key = PaneFirstPaintAudit.violationKey(of: m)
            XCTAssertTrue(key.contains("verdict="), "\(label): the key must carry a verdict= field")
            let fragment = verdictFragment(of: key)
            XCTAssertTrue(PaneFirstPaintAudit.summary(of: m).contains(fragment), """
                \(label): the logged line and the rate-limit key must render the verdict \
                identically — they share one private helper today, and if they ever drifted apart \
                the log would name one failure while the limiter deduplicated on another. Key \
                fragment "\(fragment)" not found in summary "\(PaneFirstPaintAudit.summary(of: m))".
                """)
        }
    }
}

/// The trailing `verdict=…` field of a `violationKey`/`summary` line.
/// Returns the empty string if absent, which the callers assert against
/// separately.
private func verdictFragment(of line: String) -> String {
    guard let range = line.range(of: "verdict=") else { return "" }
    return String(line[range.lowerBound...])
}
