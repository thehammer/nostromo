import XCTest

// MotherDaemonState is compiled into this target directly (logic test).

final class MotherDaemonStatusTests: XCTestCase {

    func testRunningOutputIsParsedWithItsDetail() {
        let s = MotherDaemonState.parse(stdout: "running (pid 62699, uptime 18:10:13)\n", status: 0)
        XCTAssertEqual(s, .running(detail: "pid 62699, uptime 18:10:13"))
        XCTAssertEqual(s.label, "Mother daemon running")
    }

    func testNonZeroExitMeansStoppedEvenIfTheTextSaysRunning() {
        XCTAssertEqual(MotherDaemonState.parse(stdout: "running (pid 1)", status: 1), .stopped)
    }

    func testAnythingElseMeansStopped() {
        XCTAssertEqual(MotherDaemonState.parse(stdout: "not running", status: 0), .stopped)
        XCTAssertEqual(MotherDaemonState.parse(stdout: "", status: 0), .stopped)
        XCTAssertTrue(MotherDaemonState.parse(stdout: "stopped", status: 3).isStopped)
    }

    func testRunningWithoutParenthesesKeepsTheRemainder() {
        XCTAssertEqual(MotherDaemonState.parse(stdout: "running pid 5", status: 0), .running(detail: "pid 5"))
    }

    func testUnavailableAndUnknownAreNotStopped() {
        XCTAssertFalse(MotherDaemonState.unknown.isStopped)
        XCTAssertFalse(MotherDaemonState.unavailable(reason: "custom broker").isStopped)
    }
}
