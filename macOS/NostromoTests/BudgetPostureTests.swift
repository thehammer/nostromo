import XCTest
// BudgetPosture is compiled into this target directly (logic test, no host app).

/// The posture chip's label. Mother maps the legacy `conservative` to Pump the brakes, and Ease up is
/// advisory only, so the legacy value never reads as Ease up.
final class BudgetPostureTests: XCTestCase {

    func testTheLegacyConservativeReadsAsPumpTheBrakesLikeMother() throws {
        let legacy = try XCTUnwrap(BudgetPosture.from(string: "conservative"))
        let current = try XCTUnwrap(BudgetPosture.from(string: "pump the brakes"))

        XCTAssertEqual(legacy.chipLabel, "Pump the brakes")
        XCTAssertEqual(legacy.chipLabel, current.chipLabel)
    }

    func testEaseUpStaysItsOwnLabel() throws {
        XCTAssertEqual(try XCTUnwrap(BudgetPosture.from(string: "ease up")).chipLabel, "Ease up")
    }
}
