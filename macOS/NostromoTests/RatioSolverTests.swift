import XCTest
// RatioSolver is compiled into this target directly (logic test — no host
// app, no window). No module imports needed.

// MARK: - RatioSolverTests

/// Behavioural tests for `RatioSolver.dividerPositions` (fix/detail-region-content-not-rendering).
///
/// Extracted from the arithmetic inline in `DynamicFocusView.applyRatios`, so
/// it can be exercised without a real `NSSplitView`/window. The `nil` cases
/// are the actual regression coverage: the pre-fix bug was a caller treating
/// "the split has no real size yet" (`total <= 0`, the state a split is in
/// for at least one run-loop turn after construction) as if ratios had been
/// successfully applied, so nothing ever retried and the operator's dragged
/// (or the agent's authored) ratios silently never took effect. A solver
/// that refuses to answer in that state, rather than returning some
/// plausible-looking garbage, is what lets a caller tell "not yet" apart
/// from "done."
final class RatioSolverTests: XCTestCase {

    // MARK: 1. Two equal children, zero divider thickness

    func testTwoEqualChildrenWithNoDividerThicknessSplitTheMidpoint() {
        let positions = RatioSolver.dividerPositions(
            ratios: [0.5, 0.5], total: 100, dividerThickness: 0, subviewCount: 2
        )
        XCTAssertEqual(positions, [50.0])
    }

    // MARK: 2. Three equal children, non-zero divider thickness

    func testThreeEqualChildrenAccountForDividerThicknessBeforeDistributingProportionally() {
        // usable = total - dividerThickness * (subviewCount - 1) = 306 - 3*2 = 300
        // each child's share = usable * (1/3) = 100
        // divider 0 = 0 + 100 = 100
        // divider 1 = (100 + dividerThickness) + 100 = 103 + 100 = 203
        let positions = RatioSolver.dividerPositions(
            ratios: [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0], total: 306, dividerThickness: 3, subviewCount: 3
        )
        guard let positions else {
            XCTFail("expected divider positions, got nil")
            return
        }
        XCTAssertEqual(positions.count, 2)
        XCTAssertEqual(positions[0], 100.0, accuracy: 0.001)
        XCTAssertEqual(positions[1], 203.0, accuracy: 0.001)
    }

    // MARK: 3. total <= 0 refuses to answer

    func testZeroTotalReturnsNilRatherThanTreatingNoSizeYetAsApplied() {
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [0.5, 0.5], total: 0, dividerThickness: 0, subviewCount: 2))
    }

    func testNegativeTotalReturnsNil() {
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [0.5, 0.5], total: -5, dividerThickness: 0, subviewCount: 2))
    }

    // MARK: 4. Ratios not summing to ~1.0 refuse to answer

    func testRatiosSummingFarBelowOneReturnNil() {
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [0.5, 0.3], total: 100, dividerThickness: 0, subviewCount: 2))
    }

    func testRatiosWithinToleranceOfOneStillProduceAResult() {
        // Sum is 1.005 — within the documented ~0.01 tolerance.
        let positions = RatioSolver.dividerPositions(
            ratios: [0.5, 0.505], total: 100, dividerThickness: 0, subviewCount: 2
        )
        XCTAssertNotNil(positions, "a sum within tolerance of 1.0 must still produce a result, not be rejected")
    }

    func testRatiosJustOutsideToleranceOfOneReturnNil() {
        // Sum is 1.05 — clearly outside the documented ~0.01 tolerance.
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [0.5, 0.55], total: 100, dividerThickness: 0, subviewCount: 2))
    }

    // MARK: 5. ratios.count mismatched against subviewCount refuses to answer

    func testRatiosCountNotMatchingSubviewCountReturnsNil() {
        XCTAssertNil(RatioSolver.dividerPositions(
            ratios: [0.3, 0.3, 0.4], total: 100, dividerThickness: 0, subviewCount: 2
        ))
    }

    // MARK: 6. subviewCount <= 0 refuses to answer

    func testZeroSubviewCountReturnsNil() {
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [], total: 100, dividerThickness: 0, subviewCount: 0))
    }

    func testNegativeSubviewCountReturnsNil() {
        XCTAssertNil(RatioSolver.dividerPositions(ratios: [], total: 100, dividerThickness: 0, subviewCount: -1))
    }

    // MARK: - Edge cases

    func testASingleSubviewProducesNoDividersButIsNotAnErrorCase() {
        let positions = RatioSolver.dividerPositions(
            ratios: [1.0], total: 100, dividerThickness: 4, subviewCount: 1
        )
        XCTAssertEqual(positions, [], "one subview has zero dividers — that's a valid, empty answer, not a nil/failure")
    }

    // MARK: 7. Round trip: dividerPositions → child extents → normalized ratios (D4)

    /// Mirrors `DynamicFocusView.currentRatios`'s exact normalization —
    /// dividing each child's own extent by the *sum of the children's own
    /// extents*, not by the split's full bounds (which also includes divider
    /// thickness, belonging to no child). `currentRatios` is private to
    /// `DynamicFocusView` and this logic-only test target doesn't compile
    /// that AppKit file, so this reimplements the same arithmetic inline
    /// rather than calling it — see `DynamicFocusViewWiringTests` for the
    /// textual fitness function pinning that the real implementation matches
    /// this shape (no `split.bounds` reference).
    ///
    /// This is what D4 guarantees stays true: apply ratios via the solver,
    /// read the resulting layout back via this same normalization, and get
    /// back what you started with — no systematic under-sum from divider
    /// thickness leaking into the computed ratios.
    private func normalizedRatios(fromChildSizes sizes: [Double]) -> [Double] {
        let sum = sizes.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1.0 / Double(sizes.count), count: sizes.count) }
        return sizes.map { $0 / sum }
    }

    /// Derive each child's size from `dividerPositions`' output the same way
    /// its own loop lays them out: divider `i`'s position is the *end*
    /// coordinate of child `i` (before the divider that follows it), so
    /// child 0's size is simply `positions[0]`, an interior child's size is
    /// the gap between consecutive divider positions minus the divider
    /// thickness sitting between them, and the last child (which has no
    /// trailing divider recorded in `positions`) fills whatever remains of
    /// `total` after the last divider and its thickness.
    private func childSizes(fromPositions positions: [Double], total: Double, dividerThickness: Double, subviewCount: Int) -> [Double] {
        guard subviewCount > 1 else { return [total] }
        var sizes: [Double] = []
        sizes.append(positions[0])
        for i in 1..<(subviewCount - 1) {
            sizes.append(positions[i] - positions[i - 1] - dividerThickness)
        }
        sizes.append(total - positions[positions.count - 1] - dividerThickness)
        return sizes
    }

    func testRoundTripEvenlySplitTwoChildrenRecoversOriginalRatios() {
        let ratios = [0.5, 0.5]
        let total = 800.0
        let dividerThickness = 6.0
        guard let positions = RatioSolver.dividerPositions(
            ratios: ratios, total: total, dividerThickness: dividerThickness, subviewCount: 2
        ) else {
            XCTFail("expected divider positions, got nil")
            return
        }
        let sizes = childSizes(fromPositions: positions, total: total, dividerThickness: dividerThickness, subviewCount: 2)
        let recovered = normalizedRatios(fromChildSizes: sizes)
        for (original, actual) in zip(ratios, recovered) {
            XCTAssertEqual(actual, original, accuracy: 0.0001)
        }
    }

    func testRoundTripThreeUnevenChildrenWithThinDividerRecoversOriginalRatios() {
        let ratios = [0.3, 0.3, 0.4]
        let total = 1000.0
        let dividerThickness = 1.0
        guard let positions = RatioSolver.dividerPositions(
            ratios: ratios, total: total, dividerThickness: dividerThickness, subviewCount: 3
        ) else {
            XCTFail("expected divider positions, got nil")
            return
        }
        let sizes = childSizes(fromPositions: positions, total: total, dividerThickness: dividerThickness, subviewCount: 3)
        let recovered = normalizedRatios(fromChildSizes: sizes)
        for (original, actual) in zip(ratios, recovered) {
            XCTAssertEqual(actual, original, accuracy: 0.0001)
        }
    }

    func testRoundTripThreeVeryUnevenChildrenWithThickDividerRecoversOriginalRatios() {
        // A more extreme, less "conveniently round" split, and a divider
        // thick enough that the old bounds-based normalization would have
        // shown a visible, systematic deficit — this is the case that most
        // directly stresses D4's child-extent-sum normalization.
        let ratios = [0.7, 0.2, 0.1]
        let total = 500.0
        let dividerThickness = 4.0
        guard let positions = RatioSolver.dividerPositions(
            ratios: ratios, total: total, dividerThickness: dividerThickness, subviewCount: 3
        ) else {
            XCTFail("expected divider positions, got nil")
            return
        }
        let sizes = childSizes(fromPositions: positions, total: total, dividerThickness: dividerThickness, subviewCount: 3)
        let recovered = normalizedRatios(fromChildSizes: sizes)
        for (original, actual) in zip(ratios, recovered) {
            XCTAssertEqual(actual, original, accuracy: 0.0001)
        }
    }

    // MARK: 8. Narrow-split refusal — the exact case D3 made recoverable instead of fatal

    func testRatiosUndersummingByDividerThicknessDeficitOnANarrowSplitReturnNil() {
        // Before D4's child-extent-sum normalization, `currentRatios` divided
        // by the split's own full bounds (which include divider thickness
        // that belongs to no child), producing a ratio set that
        // systematically summed to `1 - dividerThickness/total` instead of
        // 1.0 (observed: 0.9995, 0.9993, 0.9994 on wide splits). On a narrow
        // split that same deficit is large enough to exceed
        // `dividerPositions`' own `abs(sum - 1.0) < 0.01` tolerance: here
        // dividerThickness/total = 6/100 = 0.06, well past 0.01.
        //
        // Before D3, a solver refusal here was indistinguishable from a
        // successful application and abandoned the ratios forever; after D3,
        // `RatioSplitView.layout()` keeps `desiredRatios` set on a `nil` and
        // retries next layout pass instead. This test only pins that the
        // solver still (correctly) refuses this input — the retry behavior
        // itself lives in `DynamicFocusViewWiringTests`' textual checks,
        // since `RatioSplitView` isn't compiled into this logic-only target.
        let dividerThickness = 6.0
        let total = 100.0
        let deficit = dividerThickness / total // 0.06 — exceeds the 0.01 tolerance
        let undersummedRatios = [0.5 - deficit / 2, 0.5 - deficit / 2] // sums to 1 - deficit = 0.94

        XCTAssertNil(RatioSolver.dividerPositions(
            ratios: undersummedRatios, total: total, dividerThickness: dividerThickness, subviewCount: 2
        ))
    }
}
