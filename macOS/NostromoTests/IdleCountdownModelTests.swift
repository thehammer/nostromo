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

    func testFormattingUsesTheDaemonsWarnFigure() {
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 119, warnAfterSecs: 780), "Closing in 1:59 (no keystrokes for 13 minutes)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 5, warnAfterSecs: 780), "Closing in 0:05 (no keystrokes for 13 minutes)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 120, warnAfterSecs: 780), "Closing in 2:00 (no keystrokes for 13 minutes)")
    }

    func testTheNoKeystrokeFigureIsNeverTheHardCodedThirteenMinutes() {
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 90, warnAfterSecs: 60), "Closing in 1:30 (no keystrokes for 1 minute)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 90, warnAfterSecs: 130), "Closing in 1:30 (no keystrokes for 2 minutes 10 seconds)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 90, warnAfterSecs: 20), "Closing in 1:30 (no keystrokes for 20 seconds)")
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 90, warnAfterSecs: 1), "Closing in 1:30 (no keystrokes for 1 second)")
    }

    func testAnOlderDaemonThatSendsNoFigureGetsAVagueOneNotAMadeUpNumber() {
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: 119, warnAfterSecs: nil), "Closing in 1:59 (no keystrokes for a while)")
    }

    func testSecondsLeftNeverShowsNegative() {
        XCTAssertEqual(IdleCountdownModel.text(secondsLeft: -4, warnAfterSecs: 780), "Closing in 0:00 (no keystrokes for 13 minutes)")
    }
}
