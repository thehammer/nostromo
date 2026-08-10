import XCTest
// ProcessRunner is compiled into this test target directly (logic test — no
// host app, no @testable import — see MotherBrokerClientTests.swift for the
// established pattern in this target).

// MARK: - ProcessRunnerTests

/// Regression + contract tests for `ProcessRunner.runCapturingStdout`.
///
/// The motivating bug: Nostromo's macOS GUI spawned `mother list --format
/// json` via `Process`+`Pipe` and called `waitUntilExit()` *before* draining
/// the pipe. A `Pipe` has a fixed ~64KB OS buffer — once the child's stdout
/// exceeded that, the child blocked in `write()` waiting for the parent to
/// drain, while the parent blocked in `waitUntilExit()` waiting for the
/// child to exit. Permanent mutual deadlock, 98% CPU, zombie children.
///
/// `ProcessRunner.runCapturingStdout` exists specifically to make that
/// deadlock structurally impossible: it must drain stdout concurrently with
/// (not after) waiting for exit.
final class ProcessRunnerTests: XCTestCase {

    // ──────────────────────────────────────────────────────────────────────
    // TEST 1 (mandatory / regression guard): output exceeding the pipe's
    // ~64KB buffer must not deadlock, and the full byte count must come back.
    // ──────────────────────────────────────────────────────────────────────

    func testRunCapturingStdout_handlesOutputLargerThanPipeBuffer_withoutDeadlocking() {
        let expectation = XCTestExpectation(description: "large-output process completes")
        var result: (data: Data, status: Int32)?

        // ~200KB of stdout — comfortably past the ~64KB pipe buffer that
        // triggered the real-world deadlock.
        let byteCount = 200_000

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessRunner.runCapturingStdout(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "head -c \(byteCount) /dev/zero"]
            )
            expectation.fulfill()
        }

        // If the deadlock regresses, this wait times out (a clear, fast
        // failure) instead of hanging the test suite indefinitely.
        wait(for: [expectation], timeout: 10)

        XCTAssertNotNil(result, "expected a result; process must not hang or fail to launch")
        XCTAssertEqual(result?.data.count, byteCount,
                        "full stdout must be captured even when it exceeds the pipe buffer")
        XCTAssertEqual(result?.status, 0, "well-formed child process should exit 0")
    }

    // ──────────────────────────────────────────────────────────────────────
    // TEST 2 (recommended): small/no-output case — mirrors the
    // `/usr/bin/which` fallback path in AppStore.swift that also routes
    // through this helper.
    // ──────────────────────────────────────────────────────────────────────

    func testRunCapturingStdout_handlesSmallOutput() {
        let expectation = XCTestExpectation(description: "small-output process completes")
        var result: (data: Data, status: Int32)?

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessRunner.runCapturingStdout(
                URL(fileURLWithPath: "/bin/echo"),
                arguments: ["-n", "hello"]
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data, "hello".data(using: .utf8))
        XCTAssertEqual(result?.status, 0)
    }

    func testRunCapturingStdout_handlesEmptyOutput() {
        let expectation = XCTestExpectation(description: "empty-output process completes")
        var result: (data: Data, status: Int32)?

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessRunner.runCapturingStdout(
                URL(fileURLWithPath: "/bin/echo"),
                arguments: ["-n", ""]
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.data.count, 0)
        XCTAssertEqual(result?.status, 0)
    }

    // ──────────────────────────────────────────────────────────────────────
    // TEST 3 (optional): a nonexistent executable path must not crash the
    // process — it should surface as a nil result.
    // ──────────────────────────────────────────────────────────────────────

    func testRunCapturingStdout_returnsNilWhenLaunchFails() {
        let expectation = XCTestExpectation(description: "launch-failure process completes")
        var result: (data: Data, status: Int32)?
        var completed = false

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessRunner.runCapturingStdout(
                URL(fileURLWithPath: "/no/such/executable-\(UUID().uuidString)"),
                arguments: []
            )
            completed = true
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertTrue(completed, "must return promptly rather than hang on a bad executable path")
        XCTAssertNil(result, "a failed launch should surface as nil, not a crash or a fake result")
    }

    // ──────────────────────────────────────────────────────────────────────
    // TEST 4 (recommended): exit status is propagated faithfully, not just
    // hardcoded to 0 — a nonzero-exiting child must report its real status.
    // ──────────────────────────────────────────────────────────────────────

    func testRunCapturingStdout_propagatesNonZeroExitStatus() {
        let expectation = XCTestExpectation(description: "nonzero-exit process completes")
        var result: (data: Data, status: Int32)?

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessRunner.runCapturingStdout(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 7"]
            )
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, 7)
    }
}
