// NostromoKit — DecisionStoreTests.swift
//
// Verifies DecisionStore's claim-once semantics and bounded FIFO eviction
// (W3 — iOS decision answering).
//
// `claimAnswer` records the FIRST resolution claimed for a given requestId
// and silently refuses every subsequent claim for that same id, regardless
// of what resolution kind is being claimed second — the daemon's broadcast
// is the one source of truth per request, and iOS must never let a late or
// duplicate broadcast (or a race between a locally-initiated answer and a
// daemon-side resolution arriving first) clobber whatever was recorded
// first. The store is also a bounded FIFO (cap 64): the oldest resolution
// is evicted once a 65th distinct id is claimed, and an evicted id reverts
// to fully unresolved — as if it had never been claimed — rather than
// being permanently locked out.
//
// `DecisionStore` asserts `Thread.isMainThread` internally. XCTest test
// methods run on the main thread by default, so no special dispatch is
// needed here (unlike `DaemonStoreTests.swift`, which routes through an
// actual `@MainActor` `NetworkClient`/`DaemonStore` pair).

import XCTest
@testable import NostromoKit

final class DecisionStoreTests: XCTestCase {

    // MARK: - claimAnswer: true exactly once, per resolution kind

    func testClaimAnswerReturnsTrueOnceForChoiceThenFalse() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .choice("x")))
        XCTAssertFalse(store.claimAnswer(requestId: "r1", record: .choice("x")))
    }

    func testClaimAnswerReturnsTrueOnceForDismissedThenFalse() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .dismissed))
        XCTAssertFalse(store.claimAnswer(requestId: "r1", record: .dismissed))
    }

    func testClaimAnswerReturnsTrueOnceForResolvedElsewhereThenFalse() {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: .resolvedElsewhere("timeout")))
        XCTAssertFalse(store.claimAnswer(requestId: "r1", record: .resolvedElsewhere("timeout")))
    }

    // MARK: - Every ordering of the three kinds: the second claim never wins

    /// Claims `first` (asserting it wins), then claims `second` for the same
    /// requestId (asserting it's refused and `first` is left untouched).
    /// Shared by the six ordering tests below — each still gets its own
    /// `XCTestCase` method (and so its own line in a failure report), but the
    /// claim/assert boilerplate they'd otherwise all repeat lives here once.
    private func assertFirstClaimWins(
        _ first: DecisionResolutionRecord,
        thenRefuses second: DecisionResolutionRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let store = DecisionStore()
        XCTAssertTrue(store.claimAnswer(requestId: "r1", record: first), file: file, line: line)
        XCTAssertFalse(store.claimAnswer(requestId: "r1", record: second), file: file, line: line)
        XCTAssertEqual(store.resolution(for: "r1"), first, file: file, line: line)
    }

    func testChoiceThenDismissedLeavesOriginalChoiceUntouched() {
        assertFirstClaimWins(.choice("approve"), thenRefuses: .dismissed)
    }

    func testDismissedThenChoiceLeavesOriginalDismissedUntouched() {
        assertFirstClaimWins(.dismissed, thenRefuses: .choice("approve"))
    }

    func testChoiceThenResolvedElsewhereLeavesOriginalChoiceUntouched() {
        assertFirstClaimWins(.choice("approve"), thenRefuses: .resolvedElsewhere("timeout"))
    }

    func testResolvedElsewhereThenChoiceLeavesOriginalResolvedElsewhereUntouched() {
        assertFirstClaimWins(.resolvedElsewhere("timeout"), thenRefuses: .choice("approve"))
    }

    func testDismissedThenResolvedElsewhereLeavesOriginalDismissedUntouched() {
        assertFirstClaimWins(.dismissed, thenRefuses: .resolvedElsewhere("cancelled"))
    }

    func testResolvedElsewhereThenDismissedLeavesOriginalResolvedElsewhereUntouched() {
        assertFirstClaimWins(.resolvedElsewhere("cancelled"), thenRefuses: .dismissed)
    }

    // MARK: - resolution(for:) distinguishes all four states

    func testResolutionForUnclaimedIdIsNil() {
        let store = DecisionStore()
        XCTAssertNil(store.resolution(for: "never-claimed"))
    }

    func testResolutionForChoiceIsChoice() {
        let store = DecisionStore()
        _ = store.claimAnswer(requestId: "r1", record: .choice("approve"))
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"))
    }

    func testResolutionForDismissedIsDismissed() {
        let store = DecisionStore()
        _ = store.claimAnswer(requestId: "r1", record: .dismissed)
        XCTAssertEqual(store.resolution(for: "r1"), .dismissed)
    }

    func testResolutionForResolvedElsewhereIsResolvedElsewhere() {
        let store = DecisionStore()
        _ = store.claimAnswer(requestId: "r1", record: .resolvedElsewhere("timeout"))
        XCTAssertEqual(store.resolution(for: "r1"), .resolvedElsewhere("timeout"))
    }

    // MARK: - Bounded FIFO: cap 64, oldest evicted first, never grows past it

    func testFIFOEvictsOldestAtCapacityAndNeverGrowsPastIt() {
        let store = DecisionStore()
        let ids = (0..<65).map { "req-\($0)" }

        for id in ids {
            _ = store.claimAnswer(requestId: id, record: .dismissed)
        }

        XCTAssertEqual(store.trackedRequestCount, 64, "the FIFO must never grow past its cap of 64")
        XCTAssertNil(
            store.resolution(for: ids.first!),
            "the first-claimed id must be evicted once a 65th distinct id is claimed"
        )
        XCTAssertEqual(
            store.resolution(for: ids.last!), .dismissed,
            "the most-recently-claimed id must still be tracked"
        )
    }

    // MARK: - An evicted id behaves as fully unresolved — it is re-claimable

    func testAnEvictedIdCanBeClaimedAgainAsIfNeverClaimed() {
        let store = DecisionStore()
        let ids = (0..<65).map { "req-\($0)" }
        for id in ids {
            _ = store.claimAnswer(requestId: id, record: .dismissed)
        }

        let evictedId = ids.first!
        XCTAssertNil(store.resolution(for: evictedId), "sanity check: the id must be evicted before re-claiming it")
        XCTAssertTrue(
            store.claimAnswer(requestId: evictedId, record: .choice("approve")),
            "an evicted id must be claimable again, exactly as if it had never been claimed"
        )
        XCTAssertEqual(store.resolution(for: evictedId), .choice("approve"))
    }

    // MARK: - Independent request ids never interfere with one another

    func testIndependentRequestIdsNeverInterfere() {
        let store = DecisionStore()
        _ = store.claimAnswer(requestId: "r1", record: .choice("approve"))
        _ = store.claimAnswer(requestId: "r2", record: .dismissed)
        _ = store.claimAnswer(requestId: "r3", record: .resolvedElsewhere("timeout"))

        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"))
        XCTAssertEqual(store.resolution(for: "r2"), .dismissed)
        XCTAssertEqual(store.resolution(for: "r3"), .resolvedElsewhere("timeout"))

        // A failed re-claim attempt on r2 must not perturb r1 or r3.
        XCTAssertFalse(store.claimAnswer(requestId: "r2", record: .choice("nope")))
        XCTAssertEqual(store.resolution(for: "r1"), .choice("approve"))
        XCTAssertEqual(store.resolution(for: "r3"), .resolvedElsewhere("timeout"))
    }
}
