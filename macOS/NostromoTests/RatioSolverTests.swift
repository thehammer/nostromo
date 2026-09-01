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
}
