import XCTest

// `TerminalLatencyStats`: key down -> first output fed, measured on an injected clock so every
// number is exact. The target it is judged against is p95 < 30 ms.

final class TerminalLatencyStatsTests: XCTestCase {

    private var now: TimeInterval = 1_000
    private var stats: TerminalLatencyStats!

    override func setUp() {
        super.setUp()
        now = 1_000
        stats = TerminalLatencyStats(clock: { [unowned self] in self.now })
    }

    override func tearDown() {
        stats = nil
        super.tearDown()
    }

    /// One key, then its echo `ms` milliseconds later.
    private func sample(ms: Double) {
        stats.noteKeyDown()
        now += ms / 1000
        stats.noteOutputFed()
    }

    // MARK: - Pairing

    func testAKeyThenOutputIsOneSampleOfTheElapsedTime() throws {
        stats.noteKeyDown()
        now += 0.012
        stats.noteOutputFed()

        let s = stats.snapshot
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.012, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.012, accuracy: 1e-9)
    }

    func testOutputWithNoKeyWaitingIsNotASample() throws {
        stats.noteOutputFed()
        stats.noteOutputFed()

        XCTAssertEqual(stats.snapshot, TerminalLatencyStats.Snapshot(count: 0, p50: nil, p95: nil))
    }

    func testOneKeyIsAnsweredByOnlyTheFirstOutputAfterIt() throws {
        stats.noteKeyDown()
        now += 0.010
        stats.noteOutputFed()
        now += 0.010
        stats.noteOutputFed()

        XCTAssertEqual(stats.snapshot.count, 1)
    }

    func testABurstOfKeysPairsOldestFirstWithTheOutputsThatFollow() throws {
        stats.noteKeyDown()           // t = 0
        now += 0.010
        stats.noteKeyDown()           // t = 10 ms
        now += 0.010
        stats.noteKeyDown()           // t = 20 ms
        now += 0.010                  // t = 30 ms
        stats.noteOutputFed()         // oldest key: 30 ms
        now += 0.010                  // t = 40 ms
        stats.noteOutputFed()         // second key: 30 ms
        now += 0.010                  // t = 50 ms
        stats.noteOutputFed()         // third key: 30 ms

        let s = stats.snapshot
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.030, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.030, accuracy: 1e-9)
    }

    func testPairingIsFirstInFirstOutNotNewestFirst() throws {
        stats.noteKeyDown()           // t = 0
        now += 0.050
        stats.noteKeyDown()           // t = 50 ms
        now += 0.010
        stats.noteOutputFed()         // pairs with the t = 0 key: 60 ms (newest-first would give 10 ms)

        XCTAssertEqual(try XCTUnwrap(stats.snapshot.p50), 0.060, accuracy: 1e-9)
    }

    // MARK: - Stale and bounded

    func testAKeyOlderThanTheStaleLimitIsDroppedWithoutASample() throws {
        stats.noteKeyDown()
        now += TerminalLatencyStats.staleAfter + 0.5
        stats.noteOutputFed()

        XCTAssertEqual(stats.snapshot.count, 0)
    }

    func testAKeyJustInsideTheStaleLimitStillCounts() throws {
        stats.noteKeyDown()
        now += TerminalLatencyStats.staleAfter - 0.5
        stats.noteOutputFed()

        XCTAssertEqual(stats.snapshot.count, 1)
    }

    func testAnIgnoredKeyDoesNotStealTheEchoOfALaterKey() throws {
        stats.noteKeyDown()                                    // never echoed
        now += TerminalLatencyStats.staleAfter + 1
        stats.noteKeyDown()                                    // the real one
        now += 0.020
        stats.noteOutputFed()

        let s = stats.snapshot
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.020, accuracy: 1e-9)
    }

    func testAtMostMaxPendingKeysAreQueued() throws {
        let extra = 10
        for _ in 0..<(TerminalLatencyStats.maxPending + extra) { stats.noteKeyDown() }
        now += 0.001
        for _ in 0..<(TerminalLatencyStats.maxPending + extra) { stats.noteOutputFed() }

        XCTAssertEqual(stats.snapshot.count, TerminalLatencyStats.maxPending)
    }

    // MARK: - Percentiles

    func testP50AndP95AreNearestRankOverKnownSamples() throws {
        for ms in 1...100 { sample(ms: Double(ms)) }

        let s = stats.snapshot
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.050, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.095, accuracy: 1e-9)
    }

    func testPercentilesDoNotDependOnTheOrderSamplesArrivedIn() throws {
        for ms in (1...100).reversed() { sample(ms: Double(ms)) }

        let s = stats.snapshot
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.050, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.095, accuracy: 1e-9)
    }

    func testAnOutlierMovesP95ButNotP50() throws {
        for _ in 0..<19 { sample(ms: 10) }
        sample(ms: 400)

        let s = stats.snapshot
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.010, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.010, accuracy: 1e-9, "1 in 20 is the 95th rank, so the outlier is above it")

        sample(ms: 400)
        XCTAssertEqual(try XCTUnwrap(stats.snapshot.p95), 0.400, accuracy: 1e-9)
    }

    func testThereAreNoPercentilesBeforeTheFirstSample() throws {
        let s = stats.snapshot
        XCTAssertEqual(s.count, 0)
        XCTAssertNil(s.p50)
        XCTAssertNil(s.p95)
    }

    // MARK: - The window

    func testOnlyTheLastWindowOfSamplesIsKeptButCountKeepsCounting() throws {
        let window = TerminalLatencyStats.sampleWindow
        XCTAssertEqual(window, 500)
        for _ in 0..<window { sample(ms: 100) }            // older, slow samples
        for _ in 0..<window { sample(ms: 5) }              // newer, fast samples fill the whole window

        let s = stats.snapshot
        XCTAssertEqual(s.count, window * 2, "count is every key ever measured")
        XCTAssertEqual(try XCTUnwrap(s.p50), 0.005, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.p95), 0.005, accuracy: 1e-9, "the old slow samples have been dropped")
    }

    // MARK: - Reset

    func testResetForgetsSamplesCountAndWaitingKeys() throws {
        sample(ms: 10)
        stats.noteKeyDown()

        stats.reset()
        now += 0.010
        stats.noteOutputFed()                              // the waiting key was forgotten too

        XCTAssertEqual(stats.snapshot, TerminalLatencyStats.Snapshot(count: 0, p50: nil, p95: nil))
    }

    // MARK: - Report

    func testTheReportSaysThereAreNoSamplesYet() throws {
        let text = stats.report()
        XCTAssertTrue(text.contains("no samples"), text)
        XCTAssertFalse(text.contains("p95="), text)
    }

    func testTheReportShowsP50P95InMillisecondsAndWithinTheTarget() throws {
        for _ in 0..<10 { sample(ms: 12) }

        let text = stats.report()
        XCTAssertTrue(text.contains("p50=12.0 ms"), text)
        XCTAssertTrue(text.contains("p95=12.0 ms"), text)
        XCTAssertTrue(text.contains("count=10"), text)
        XCTAssertTrue(text.contains("30 ms"), text)
        XCTAssertTrue(text.contains("within"), text)
        XCTAssertFalse(text.contains("OVER"), text)
    }

    func testTheReportFlagsAP95OverTheTarget() throws {
        for _ in 0..<10 { sample(ms: 45) }

        let text = stats.report()
        XCTAssertTrue(text.contains("p95=45.0 ms"), text)
        XCTAssertTrue(text.contains("OVER"), text)
        XCTAssertFalse(text.contains("within"), text)
    }

    func testTheTargetIsThirtyMilliseconds() throws {
        XCTAssertEqual(TerminalLatencyStats.p95Target, 0.030, accuracy: 1e-12)
    }
}
