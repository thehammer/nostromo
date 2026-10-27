import XCTest

final class IdleCountdownModelTests: XCTestCase {
    private let closesAt = "2026-10-27T15:15:00Z"
    private let closes = ISO8601DateFormatter().date(from: "2026-10-27T15:15:00Z")!

    func testHiddenWhenTheDaemonHasNotWarned() {
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: nil, now: closes), .hidden)
    }

    func testHiddenForATimestampItCannotRead() {
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: "soon", now: closes), .hidden)
    }

    func testCountsDownFromTwoMinutes() {
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: closesAt, now: closes.addingTimeInterval(-120)),
                       .counting(secondsLeft: 120))
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: closesAt, now: closes.addingTimeInterval(-118.4)),
                       .counting(secondsLeft: 119))
    }

    func testFractionalSecondsAreAccepted() {
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: "2026-10-27T15:15:00.250Z", now: closes.addingTimeInterval(-10)),
                       .counting(secondsLeft: 11))
    }

    func testNeverNegative() {
        XCTAssertEqual(IdleCountdownModel.state(idleClosesAt: closesAt, now: closes.addingTimeInterval(30)),
                       .counting(secondsLeft: 0))
    }

    func testFormatting() {
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 119), "Closing in 1:59 (no keystrokes for 13 minutes)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 5), "Closing in 0:05 (no keystrokes for 13 minutes)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 120), "Closing in 2:00 (no keystrokes for 13 minutes)")
    }
}
