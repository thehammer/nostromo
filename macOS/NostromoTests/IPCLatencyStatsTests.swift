import XCTest

// IPCLatencyStats is compiled into this test target directly (logic test —
// no host app, no sockets).

/// Verifies `IPCLatencyStats` behaviour: round-trip correlation, pending-queue
/// bounds, disconnect bookkeeping, and percentile agreement with the Rust
/// side's `ToolStats`. Tests inject timestamps via the `at:` parameters
/// rather than sleeping, so latency values are exact and the suite stays
/// fast and non-flaky.
final class IPCLatencyStatsTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func snapshot(_ stats: IPCLatencyStats) -> IPCLatencyStats.Snapshot {
        stats.snapshot()
    }

    // MARK: - Round-trip correlation

    func testSessionAttachMatchesSessionTurnsBySameTag() {
        let stats = IPCLatencyStats()
        stats.recordSend(type: "session_attach", tag: "focus-1", bytes: 10, at: base)
        stats.recordReceive(type: "session_turns", tag: "focus-1", deltaKind: nil, bytes: 20,
                            decodeSeconds: 0.001, at: base.addingTimeInterval(0.05))

        let snap = snapshot(stats)
        let row = snap.roundTrips.first { $0.bucket == "session_attach->session_turns" }
        XCTAssertEqual(row?.matched, 1)
        XCTAssertEqual(row?.lastMs ?? -1, 50.0, accuracy: 0.001)
    }

    func testSessionAttachDoesNotMatchDifferentTag() {
        let stats = IPCLatencyStats()
        stats.recordSend(type: "session_attach", tag: "focus-1", bytes: 10, at: base)
        stats.recordReceive(type: "session_turns", tag: "focus-2", deltaKind: nil, bytes: 20,
                            decodeSeconds: 0.001, at: base.addingTimeInterval(0.05))

        let snap = snapshot(stats)
        let row = snap.roundTrips.first { $0.bucket == "session_attach->session_turns" }
        XCTAssertNil(row, "different tag must not produce a matched round trip")
        XCTAssertEqual(snap.unmatchedPending, 1)
    }

    func testSessionSendMatchesTurnStartedButNotBlockAppended() {
        let stats = IPCLatencyStats()
        stats.recordSend(type: "session_send", tag: "focus-1", bytes: 10, at: base)
        stats.recordReceive(type: "session_turn_delta", tag: "focus-1", deltaKind: "block_appended",
                            bytes: 20, decodeSeconds: 0.001, at: base.addingTimeInterval(0.02))

        var snap = snapshot(stats)
        XCTAssertNil(snap.roundTrips.first { $0.bucket == "session_send->turn_started" })
        XCTAssertEqual(snap.unmatchedPending, 1, "block_appended must not consume the pending send")

        stats.recordReceive(type: "session_turn_delta", tag: "focus-1", deltaKind: "turn_started",
                            bytes: 20, decodeSeconds: 0.001, at: base.addingTimeInterval(0.03))
        snap = snapshot(stats)
        let row = snap.roundTrips.first { $0.bucket == "session_send->turn_started" }
        XCTAssertEqual(row?.matched, 1)
        XCTAssertNotNil(row?.note, "the approximation caveat must be visible in the JSON, not just a comment")
        XCTAssertEqual(snap.unmatchedPending, 0)
    }

    // MARK: - FIFO pairing

    func testFIFOPairingMatchesOldestSendFirst() {
        let stats = IPCLatencyStats()
        stats.recordSend(type: "session_attach", tag: "t", bytes: 1, at: base)
        stats.recordSend(type: "session_attach", tag: "t", bytes: 1, at: base.addingTimeInterval(1))

        stats.recordReceive(type: "session_turns", tag: "t", deltaKind: nil, bytes: 1,
                            decodeSeconds: 0, at: base.addingTimeInterval(0.1))
        stats.recordReceive(type: "session_turns", tag: "t", deltaKind: nil, bytes: 1,
                            decodeSeconds: 0, at: base.addingTimeInterval(1.1))

        let snap = snapshot(stats)
        let row = snap.roundTrips.first { $0.bucket == "session_attach->session_turns" }
        XCTAssertEqual(row?.matched, 2)
        XCTAssertEqual(snap.unmatchedPending, 0)
    }

    // MARK: - Pending cap

    func testPendingCapDropsOldestAndCountsDropped() {
        let stats = IPCLatencyStats()
        let extra = 5
        for i in 0..<(IPCLatencyStats.maxPendingPerKey + extra) {
            stats.recordSend(type: "session_attach", tag: "t", bytes: 1,
                             at: base.addingTimeInterval(Double(i)))
        }

        let snap = snapshot(stats)
        XCTAssertEqual(snap.unmatchedPending, IPCLatencyStats.maxPendingPerKey)
        XCTAssertEqual(snap.droppedPendingSends, extra)
    }

    // MARK: - Disconnect bookkeeping

    func testNoteDisconnectClearsPendingIntoAbandonedAndKeepsMatchedSamples() {
        let stats = IPCLatencyStats()
        stats.noteConnect()
        stats.recordSend(type: "session_attach", tag: "matched", bytes: 1, at: base)
        stats.recordReceive(type: "session_turns", tag: "matched", deltaKind: nil, bytes: 1,
                            decodeSeconds: 0, at: base.addingTimeInterval(0.01))

        stats.recordSend(type: "session_attach", tag: "unmatched-1", bytes: 1, at: base)
        stats.recordSend(type: "session_attach", tag: "unmatched-2", bytes: 1, at: base)

        stats.noteDisconnect()

        let snap = snapshot(stats)
        XCTAssertEqual(snap.abandonedOnDisconnect, 2)
        XCTAssertEqual(snap.unmatchedPending, 0)
        XCTAssertFalse(snap.connected)
        let row = snap.roundTrips.first { $0.bucket == "session_attach->session_turns" }
        XCTAssertEqual(row?.matched, 1, "previously matched samples survive a disconnect")
    }

    func testFirstConnectIsNotAReconnectButSubsequentOnesAre() {
        let stats = IPCLatencyStats()
        stats.noteConnect()
        XCTAssertEqual(snapshot(stats).reconnects, 0)

        stats.noteDisconnect()
        stats.noteConnect()
        XCTAssertEqual(snapshot(stats).reconnects, 1)

        stats.noteDisconnect()
        stats.noteConnect()
        XCTAssertEqual(snapshot(stats).reconnects, 2)
    }

    // MARK: - Percentile agreement with the Rust side

    /// Same 1...100 ms fixture as `src/mcp/tool_stats.rs`'s
    /// `percentiles_over_1_to_100ms` unit test — a drift between the two
    /// percentile implementations shows up as a failing test on whichever
    /// side moved.
    func testPercentileAgreementWith1To100msFixture() {
        let stats = IPCLatencyStats()
        for ms in 1...100 {
            stats.recordSend(type: "ping", tag: nil, bytes: 1, at: base)
            stats.recordReceive(type: "pong", tag: nil, deltaKind: nil, bytes: 1,
                                decodeSeconds: 0, at: base.addingTimeInterval(Double(ms) / 1000.0))
        }

        let snap = snapshot(stats)
        let row = snap.roundTrips.first { $0.bucket == "ping->pong" }
        XCTAssertEqual(row?.p50Ms ?? -1, 50.0, accuracy: 0.001)
        XCTAssertEqual(row?.p95Ms ?? -1, 95.0, accuracy: 0.001)
        XCTAssertEqual(row?.maxMs ?? -1, 100.0, accuracy: 0.001)
    }

    // MARK: - Frame/byte counters with no round-trip bucket

    func testFrameCountersAccumulateForTypeWithNoRoundTripBucket() {
        let stats = IPCLatencyStats()
        stats.recordSend(type: "session_detach", tag: "t", bytes: 10, at: base)
        stats.recordSend(type: "session_detach", tag: "t", bytes: 20, at: base)

        let snap = snapshot(stats)
        let row = snap.outbound.first { $0.type == "session_detach" }
        XCTAssertEqual(row?.frames, 2)
        XCTAssertEqual(row?.bytes, 30)
        XCTAssertTrue(snap.roundTrips.isEmpty, "session_detach has no reply mapping")
        XCTAssertEqual(snap.unmatchedPending, 0, "types with no round-trip rule never enter pending")
    }
}
