import XCTest
// `RatioApplicationAudit` is compiled into this target directly (logic test —
// no host app, no window, no AppKit), the same idiom as `RatioSolverTests`
// and `PaneRenderPlanTests`. No module imports needed.

// MARK: - RatioApplicationAuditTests

/// Behavioural coverage for `RatioApplicationAudit` — the judgement that
/// tells `applyRatios` whether the split it just asked for is the split it
/// actually got, and tells `RatioSplitView.layout()` whether to try again
/// (fix/detail-region-split-collapse — D1/D2/D3).
///
/// ## Why this type exists
///
/// `NSSplitView.setPosition(_:ofDividerAt:)` is free to clamp what it is
/// handed and reports nothing when it does. `applyRatios` returned `true`
/// unconditionally after calling it, so `RatioSplitView.layout()` read a
/// clamp as a successful application, cleared `desiredRatios`, and never
/// retried — the existing retry path was unreachable in principle.
///
/// The measured failure this suite is written against: tearing down and
/// re-inserting the detail region on a PR pickup landed a requested
/// `[0.5, 0.5]` at `0.9807 / 0.0193` — a 34pt-wide detail region in a
/// 1760pt split whose correct share is 879.5pt each — and never recovered,
/// still identical five minutes later. An earlier capture of the same
/// defect measured `0.978 / 0.022`. A healthy restored-at-launch split
/// measures 879.5pt, so the correct outcome is reachable; nothing about
/// the geometry made this unsatisfiable.
///
/// ## The two questions, kept separate
///
/// `outcome` answers "did we land where we asked?" — a pure comparison.
/// `progress` answers "so what should layout() do next?" and is the D2
/// anti-spin rule: a split whose children genuinely cannot reach the
/// requested ratio must stop re-applying on every layout pass forever,
/// but a split that is merely still moving must not be given up on. The
/// plan explicitly forbids resolving that with an attempt cap, because a
/// window resize legitimately needs many passes and a cap would silently
/// reintroduce this bug at some other window size. The tests below pin
/// "two consecutive identical results" as the stop condition instead, and
/// deliberately include a 12-pass improving sequence that must keep
/// retrying throughout.
///
/// ## Conventions pinned here
///
/// - **Tolerance boundary is inclusive**: a per-child delta strictly
///   greater than `tolerance` is a miss; a delta exactly equal to it is
///   applied. Boundary cases below use binary-exact values (halves,
///   quarters, eighths) so the assertion is about the rule and not about
///   floating-point representation.
/// - **A shape we cannot compare is never a success**: mismatched
///   `requested`/`achieved` counts, and the degenerate empty-vs-empty
///   case, both report `.missed`. There is nothing to verify, and
///   certifying an unverified split as applied is precisely the defect.
///   The `worstDelta` carried in those cases is not meaningful and is
///   deliberately not pinned — only the "never `.applied`" half is
///   behaviour anyone depends on.
final class RatioApplicationAuditTests: XCTestCase {

    // MARK: - Helpers

    /// Extracts the miss magnitude, failing the test if the outcome was
    /// anything else. Keeps the arithmetic assertions readable and keeps
    /// `Double` payloads out of exact `Equatable` comparisons.
    private func worstDelta(
        _ outcome: RatioApplicationAudit.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Double? {
        guard case .missed(let delta) = outcome else {
            XCTFail("expected .missed, got \(outcome)", file: file, line: line)
            return nil
        }
        return delta
    }

    // MARK: - outcome: the requested split was achieved

    func testAnExactlyAchievedSplitIsApplied() {
        XCTAssertEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.5, 0.5]),
            .applied,
            "a split that landed exactly where it was asked to land is the one unambiguous success"
        )
    }

    func testASplitWithinToleranceIsApplied() {
        XCTAssertEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.52, 0.48]),
            .applied,
            """
            two percentage points off is layout noise, not a clamp — the audit must not turn \
            ordinary rounding into an endless retry loop.
            """
        )
    }

    func testAFourWayEvenSplitThatLandsExactlyIsApplied() {
        XCTAssertEqual(
            RatioApplicationAudit.outcome(
                requested: [0.25, 0.25, 0.25, 0.25],
                achieved: [0.25, 0.25, 0.25, 0.25]
            ),
            .applied,
            "the judgement is per-child and must hold for splits wider than two children"
        )
    }

    // MARK: - outcome: the measured failures

    /// The live measurement from the PR-pickup capture set
    /// (`/tmp/qa2/01-pickup-d2.png`): the divider landed at x=1885 in a
    /// 1760pt split, leaving the detail region 34pt wide where its correct
    /// share was 879.5pt. This is the case the pre-fix code reported as a
    /// successful application.
    func testTheMeasuredPickupCollapseIsAMiss() {
        let outcome = RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.9807, 0.0193])
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.4807, accuracy: 1e-9, """
            a 48-percentage-point miss must be reported as the size it is — the magnitude is what \
            the giving-up log line names, so it has to be the real worst-child distance, not a \
            flag.
            """)
    }

    /// The independently-captured earlier measurement of the same defect
    /// (2026-09-04). Different capture, same verdict — the audit must not
    /// be tuned so tightly to one screenshot that a second sighting of the
    /// same bug slips through.
    func testTheEarlierMeasurementOfTheSameCollapseIsAlsoAMiss() {
        let outcome = RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.978, 0.022])
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.478, accuracy: 1e-9)
    }

    func testAThreeWaySplitCollapsedIntoItsFirstChildIsAMiss() {
        let outcome = RatioApplicationAudit.outcome(
            requested: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            achieved: [0.9, 0.05, 0.05]
        )
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.9 - 1.0 / 3.0, accuracy: 1e-9, """
            with three children the worst child is the swollen one, not either starved one — the \
            reported magnitude must be the maximum per-child distance, not the first or the mean.
            """)
    }

    func testAFourWaySplitCollapsedIntoItsFirstChildIsAMiss() {
        let outcome = RatioApplicationAudit.outcome(
            requested: [0.25, 0.25, 0.25, 0.25],
            achieved: [0.7, 0.1, 0.1, 0.1]
        )
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.45, accuracy: 1e-9)
    }

    // MARK: - outcome: the tolerance boundary

    func testADeltaExactlyAtTheToleranceIsApplied() {
        // Binary-exact values so this asserts the inclusive-boundary rule
        // rather than a floating-point representation accident: the worst
        // per-child delta here is exactly 0.25.
        XCTAssertEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.75, 0.25], tolerance: 0.25),
            .applied,
            "the boundary is inclusive: a delta equal to the tolerance is within tolerance"
        )
    }

    func testADeltaJustInsideTheToleranceIsApplied() {
        XCTAssertEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.625, 0.375], tolerance: 0.25),
            .applied
        )
    }

    func testADeltaJustOutsideTheToleranceIsAMiss() {
        let outcome = RatioApplicationAudit.outcome(
            requested: [0.5, 0.5], achieved: [0.8125, 0.1875], tolerance: 0.25
        )
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.3125, accuracy: 1e-9, """
            strictly greater than the tolerance is a miss — that is the whole rule, and the two \
            tests above pin the other side of it.
            """)
    }

    func testTheDefaultToleranceAdmitsFourPointsAndRejectsSix() {
        // Pins the shipped default without naming the constant: four
        // percentage points off is fine, six is not.
        XCTAssertEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.54, 0.46]),
            .applied,
            "four percentage points per child must sit inside the default tolerance"
        )
        XCTAssertNotEqual(
            RatioApplicationAudit.outcome(requested: [0.5, 0.5], achieved: [0.56, 0.44]),
            .applied,
            "six percentage points per child must sit outside the default tolerance"
        )
    }

    func testTheToleranceIsPerChildNotAggregate() {
        // Three children where two are near-perfect and one is badly off.
        // A sum-of-errors or mean-of-errors reading would dilute the bad
        // child below the default tolerance and certify this as applied.
        let outcome = RatioApplicationAudit.outcome(
            requested: [0.4, 0.3, 0.3],
            achieved: [0.4, 0.42, 0.18]
        )
        guard let delta = worstDelta(outcome) else { return }
        XCTAssertEqual(delta, 0.12, accuracy: 1e-9, """
            one collapsed child is the bug, however well the others landed — averaging across \
            children is exactly how a 34pt pane hides behind an 879pt one.
            """)
    }

    // MARK: - outcome: shapes that cannot be verified are never successes

    func testAchievedWithFewerChildrenThanRequestedIsAMiss() {
        // The split reported two children for a three-way request — the
        // shapes do not line up, so there is nothing to compare and
        // therefore nothing to certify.
        let outcome = RatioApplicationAudit.outcome(
            requested: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
            achieved: [0.5, 0.5]
        )
        guard case .missed = outcome else {
            XCTFail("a count mismatch must never be reported as applied, got \(outcome)")
            return
        }
    }

    func testAchievedWithMoreChildrenThanRequestedIsAMiss() {
        let outcome = RatioApplicationAudit.outcome(
            requested: [0.5, 0.5],
            achieved: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]
        )
        guard case .missed = outcome else {
            XCTFail("a count mismatch must never be reported as applied, got \(outcome)")
            return
        }
    }

    func testAnEmptySplitIsAMissRatherThanAVacuousSuccess() {
        // Pinned rule: with no children there is no evidence the ratios
        // were applied, and "no evidence" must not read as "applied" —
        // that is the shape of the original defect. The caller retries,
        // which is harmless on a split that genuinely has no children
        // because layout() only runs the audit on a sized split.
        let outcome = RatioApplicationAudit.outcome(requested: [], achieved: [])
        guard case .missed = outcome else {
            XCTFail("an unverifiable empty split must not be certified as applied, got \(outcome)")
            return
        }
    }

    // MARK: - progress: within tolerance ends the retry loop

    func testProgressReportsAppliedOnAFirstPassThatLandedWithinTolerance() {
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.5, 0.5], previousAchieved: nil
            ),
            .applied
        )
    }

    func testProgressReportsAppliedEvenWhenThePreviousPassWasBadlyOff() {
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.51, 0.49], previousAchieved: [0.9807, 0.0193]
            ),
            .applied,
            """
            history is only consulted to decide whether to give up — a pass that actually landed \
            is a success no matter how bad the pass before it was. This is the recovery case: the \
            pickup collapse followed by a good pass must resolve, not stay stuck.
            """
        )
    }

    // MARK: - progress: out of tolerance and still moving keeps retrying

    func testProgressRetriesOnTheFirstOutOfTolerancePass() {
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.9807, 0.0193], previousAchieved: nil
            ),
            .retry,
            """
            with no previous pass to compare against there is no evidence the layout has settled — \
            the first sighting of a clamp must be retried, never given up on. This single case is \
            what the pre-fix code got wrong, in the opposite direction: it reported success.
            """
        )
    }

    func testProgressRetriesWhileTheSplitIsStillMoving() {
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.80, 0.20], previousAchieved: [0.98, 0.02]
            ),
            .retry,
            "a split that moved 18 points closer between passes is converging on the request, not stuck"
        )
    }

    func testProgressRetriesWhenTheSplitMovedFurtherAway() {
        // Movement in the wrong direction is still movement: the layout
        // has not settled, so there is no basis to declare it unreachable.
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.90, 0.10], previousAchieved: [0.80, 0.20]
            ),
            .retry
        )
    }

    func testProgressRetriesWhenTheNumberOfChildrenChangedBetweenPasses() {
        // A tabs region gaining a child mid-flight is a different split
        // than the one measured last pass — not two identical results.
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                achieved: [0.9, 0.05, 0.05],
                previousAchieved: [0.98, 0.02]
            ),
            .retry
        )
    }

    // MARK: - progress: two identical out-of-tolerance passes give up

    func testProgressGivesUpAfterTwoConsecutiveIdenticalOutOfTolerancePasses() {
        let progress = RatioApplicationAudit.progress(
            requested: [0.5, 0.5], achieved: [0.98, 0.02], previousAchieved: [0.98, 0.02]
        )
        guard case .converged(let delta) = progress else {
            XCTFail("expected .converged after two identical out-of-tolerance passes, got \(progress)")
            return
        }
        XCTAssertEqual(delta, 0.48, accuracy: 1e-9, """
            giving up must report how far off it gave up — that magnitude is what makes the \
            single .error log line actionable rather than just noisy.
            """)
    }

    /// The stuck sequence end to end: the first sighting is retried, the
    /// second identical sighting stops. Two passes, not a counter.
    func testAStuckSplitRetriesOnceThenConverges() {
        let stuck: [Double] = [0.9807, 0.0193]
        XCTAssertEqual(
            RatioApplicationAudit.progress(requested: [0.5, 0.5], achieved: stuck, previousAchieved: nil),
            .retry,
            "pass 1: nothing to compare against yet"
        )
        let second = RatioApplicationAudit.progress(
            requested: [0.5, 0.5], achieved: stuck, previousAchieved: stuck
        )
        guard case .converged = second else {
            XCTFail("pass 2 landed identically to pass 1 — the layout has settled elsewhere, got \(second)")
            return
        }
    }

    // MARK: - progress: "the same" tolerates float noise, and only float noise

    func testAHalfOfATenthOfAPointOfDriftCountsAsTheSamePass() {
        // 0.0005 per child — below the convergence epsilon. Two passes
        // that differ only by this much are the same pass measured twice,
        // not a layout still inching towards the request.
        let progress = RatioApplicationAudit.progress(
            requested: [0.5, 0.5],
            achieved: [0.9807, 0.0193],
            previousAchieved: [0.9812, 0.0188]
        )
        guard case .converged = progress else {
            XCTFail("sub-epsilon drift between passes must read as identical, got \(progress)")
            return
        }
    }

    func testAFullPointOfDriftCountsAsMovementAndKeepsRetrying() {
        // 0.01 per child — an order of magnitude above the convergence
        // epsilon, so this is a layout that is still moving.
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: [0.98, 0.02], previousAchieved: [0.97, 0.03]
            ),
            .retry,
            """
            the epsilon exists to absorb measurement noise, not to swallow real movement — if it \
            did, a slowly-converging window resize would be abandoned mid-flight.
            """
        )
    }

    func testDriftOnAnyChildCountsAsMovementEvenIfTheOthersAreIdentical() {
        XCTAssertEqual(
            RatioApplicationAudit.progress(
                requested: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                achieved: [0.90, 0.05, 0.05],
                previousAchieved: [0.90, 0.09, 0.01]
            ),
            .retry,
            "sameness is all-children-agree; one child still moving means the split still is"
        )
    }

    // MARK: - progress: an improving sequence is never abandoned

    /// The four-pass sequence a recovering split walks through: badly
    /// clamped, then progressively closer, then inside tolerance. Every
    /// intermediate pass must be retried and the last must resolve — a
    /// stop rule that fired anywhere in the middle would leave the
    /// operator with a permanently collapsed region, which is the bug.
    func testAnImprovingSequenceKeepsRetryingUntilItLands() {
        let sequence: [[Double]] = [
            [0.98, 0.02],
            [0.80, 0.20],
            [0.60, 0.40],
            [0.51, 0.49]
        ]
        var previous: [Double]?
        for (index, achieved) in sequence.enumerated() {
            let progress = RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: achieved, previousAchieved: previous
            )
            let expected: RatioApplicationAudit.Progress = index == sequence.count - 1 ? .applied : .retry
            XCTAssertEqual(progress, expected, """
                pass \(index + 1) of \(sequence.count) achieved \(achieved) against a requested \
                [0.5, 0.5] — expected \(expected).
                """)
            previous = achieved
        }
    }

    /// The explicit anti-attempt-counter test. A window resize legitimately
    /// drives many layout passes, so twelve consecutive out-of-tolerance
    /// passes that are each measurably different from the last must all
    /// keep retrying. Any fixed cap — three, five, ten — reintroduces the
    /// collapsed-region bug at whatever window size happens to need more
    /// passes than the cap allows.
    func testTwelveConsecutiveImprovingPassesAllKeepRetrying() {
        var previous: [Double]?
        for pass in 0..<12 {
            let first = 0.98 - 0.02 * Double(pass)   // 0.98 down to 0.76
            let achieved = [first, 1.0 - first]
            let progress = RatioApplicationAudit.progress(
                requested: [0.5, 0.5], achieved: achieved, previousAchieved: previous
            )
            XCTAssertEqual(progress, .retry, """
                pass \(pass + 1) achieved \(achieved) — still \(String(format: "%.2f", first - 0.5)) \
                off and still moving. Giving up here would mean the stop rule is counting attempts \
                instead of detecting a settled layout.
                """)
            previous = achieved
        }
    }
}
