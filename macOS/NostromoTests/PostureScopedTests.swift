import XCTest

// PostureSnapshot / WindowPace are compiled into this target directly (logic test).

final class PostureScopedTests: XCTestCase {

    func testScopedEntryBecomesFableRow() {
        let rows = PostureSnapshot.parseScoped([
            ["model": "Fable", "used_pct": 25, "elapsed_pct": 50.0,
             "pace": 0.5, "resets_at": 1_800_000_000, "severity": "normal"],
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "F")
        XCTAssertEqual(rows[0].window.usedPct, 25)
        XCTAssertEqual(rows[0].window.pace, 0.5, accuracy: 0.001)
    }

    func testMissingPaceIsDerivedAndNullResetsTolerated() {
        let rows = PostureSnapshot.parseScoped([
            ["model": "Fable", "used_pct": 10, "elapsed_pct": 20.0, "resets_at": NSNull()],
        ])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].window.pace, 0.5, accuracy: 0.001)
        XCTAssertEqual(rows[0].window.resetsAt, 0)
    }

    func testAbsentOrMalformedScopedYieldsNoRows() {
        XCTAssertTrue(PostureSnapshot.parseScoped(nil).isEmpty)
        XCTAssertTrue(PostureSnapshot.parseScoped([["used_pct": 1]]).isEmpty)
    }
}
