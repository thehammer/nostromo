import XCTest
import Combine

// NostromodClient, ServerMsg, ChatSession, ChatTurn, TurnPayloadStore,
// TurnReconciler, DaemonTurn, DaemonTurnDelta, DaemonResultSummary are
// compiled into this test target directly (logic test — no host app).
//
// `TurnPayloadStore.hotWindow` is a `static let`, currently 200. These tests
// deliver a couple of hundred synthetic turns by design, both to push the
// append-time boundary and to reproduce the splice that moves it by more
// than one index at once.

/// Cold-turn compaction used to examine a single computed index
/// (`turns.count - 1 - hotWindow`) each time a turn was appended. That is
/// correct only when the transcript grows by exactly one turn between checks.
/// A reconnect snapshot splice or a `historyUnavailable` marker insert changes
/// the list length by more than one, so the boundary jumps past turns that are
/// never examined again — they keep their full ~36 KB payload for the life of
/// the session. The fix sweeps `0..<(turns.count - hotWindow)`, skipping turns
/// that are already cold, are markers, or are still streaming, and runs that
/// sweep from both the turn-append path and `adoptSnapshot`.
///
/// These tests drive `ChatSession` the same way `SessionHealthTests` does: a
/// real `NostromodClient` that never calls `start()`, with `ServerMsg` values
/// pumped directly through `client.messages`. Compaction compresses off the
/// main thread and hops back via `DispatchQueue.main`, so every assertion
/// about coldness polls rather than reading state synchronously after a send.
final class ChatSessionCompactionTests: XCTestCase {

    private var client:  NostromodClient!
    private var session: ChatSession!

    private let hotWindow = TurnPayloadStore.hotWindow
    /// Small allowance for turns still mid-compression at the instant the
    /// invariant is checked. Must stay far below the ~30-turn band the bug
    /// leaves behind, or this test stops being able to fail.
    private let margin = 10

    override func setUp() {
        super.setUp()
        client  = NostromodClient(socketPath: "/dev/null")
        session = ChatSession(tag: "test", agentName: "cody", displayName: "Cody",
                              workingDirectory: nil, client: client)
    }

    override func tearDown() {
        session = nil
        client  = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Distinct, monotonic timestamps — `ChatTurn.identityKey` and the
    /// reconciler's matching both key off this, so two turns must never share
    /// one.
    private func timestamp(_ seq: Int) -> String {
        Self.iso.string(from: Self.base.addingTimeInterval(Double(seq)))
    }

    /// Deliver one turn as live deltas, the same shape the daemon uses:
    /// `turnStarted` then `turnCompleted`. `blocks: []` is enough — an empty
    /// turn compacts fine, and the point here is the sweep's index math, not
    /// its payload encoding (that's `TurnPayloadStoreTests`'s job).
    private func deliverCompleteTurn(id: String, seq: Int) {
        let started = DaemonTurn(id: id, userInput: "turn-\(seq)",
                                 timestamp: timestamp(seq), blocks: [], isComplete: false)
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnStarted(started)))
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnCompleted(
            turnId: id,
            summary: DaemonResultSummary(durationMs: 1, costUsd: 0, isError: false),
            contextTokens: nil)))
    }

    /// The invariant under test: every turn older than the hot window is
    /// either a marker, still streaming, or has gone cold. True regardless of
    /// what moved the boundary there.
    private func coldnessHoldsOutsideTheHotWindow() -> Bool {
        let boundary = session.turns.count - hotWindow
        guard boundary > 0 else { return true }
        for turn in session.turns[0 ..< boundary] {
            if turn.marker != nil { continue }
            if !turn.isComplete { continue }
            if turn.truncatedLengths == nil { return false }
        }
        return true
    }

    /// Poll the main run loop — compaction is asynchronous, so nothing here
    /// can be observed synchronously right after a `send`.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.02,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(pollInterval))
        }
        return true
    }

    /// Waits until at least `expectedTurnCount` turns have actually landed in
    /// `session.turns`, via `ChatSession`'s `.receive(on: DispatchQueue.main)`
    /// hop off `client.messages.send(...)`.
    ///
    /// This is deliberately a **separate question** from "is it cold outside
    /// the hot window": `coldnessHoldsOutsideTheHotWindow()` is vacuously true
    /// on an empty transcript (`boundary = 0 - hotWindow <= 0` → `true`), so a
    /// `waitUntil` built only on that condition can return before the run loop
    /// is ever pumped, leaving every assertion after it looking at `[]`. Every
    /// test below calls this — proving delivery — before it ever asks whether
    /// what was delivered went cold. An invariant helper must not be
    /// satisfiable by the absence of the thing it measures; that is exactly the
    /// class of defect the bounded-transcript work exists to fix, and reintroducing it here would
    /// make these tests pass for the wrong reason.
    @discardableResult
    private func waitUntilDelivered(_ expectedTurnCount: Int, timeout: TimeInterval = 15,
                                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        waitUntil(timeout: timeout, file: file, line: line) {
            self.session.turns.count >= expectedTurnCount
        }
    }

    // MARK: - 1. Append-time baseline

    /// Passes before the fix too: turns arrive one at a time here, so the old
    /// single-index check and the new sweep agree. Proves the sweep didn't
    /// break the working case.
    func testColdTurnsSettleAtTheHotWindowBoundaryAsTurnsAppendOneAtATime() {
        let total = hotWindow + 30
        for seq in 0 ..< total {
            deliverCompleteTurn(id: "t\(seq)", seq: seq)
        }

        waitUntilDelivered(total)
        waitUntil { self.coldnessHoldsOutsideTheHotWindow() }
        waitUntil { self.session.hotPayloadTurnCount <= self.hotWindow + self.margin }
    }

    // MARK: - 2. Self-healing after a splice — the finding

    /// A snapshot sharing no common ground with what's retained (the
    /// reconciler's "we were away too long" branch) inserts a `.gap` marker
    /// and appends the whole snapshot as a new tail — every existing index
    /// shifts by (1 marker + snapshot.count) in one step. The old single-index
    /// check only ever re-examines the one turn at the new boundary; the band
    /// of turns between the old boundary and the new one is never looked at
    /// again. Before the fix this test fails with `hotPayloadTurnCount`
    /// stuck around hotWindow + 30; after the fix it settles back at
    /// hotWindow.
    func testCompactionSelfHealsAfterAReconnectSnapshotSplicesEveryIndex() {
        let firstBatch = hotWindow + 30
        for seq in 0 ..< firstBatch {
            deliverCompleteTurn(id: "t\(seq)", seq: seq)
        }
        waitUntilDelivered(firstBatch)
        waitUntil { self.coldnessHoldsOutsideTheHotWindow() }

        let spliceCount = 30
        let snapshot = (0 ..< spliceCount).map { i in
            DaemonTurn(id: "s\(i)", userInput: "second-life-\(i)",
                      timestamp: timestamp(100_000 + i), blocks: [], isComplete: true)
        }
        client.messages.send(.sessionTurns(tag: "test", turns: snapshot))
        // firstBatch (no common ground found, so kept as-is) + 1 `.gap` marker + spliceCount.
        let afterSplice = firstBatch + 1 + spliceCount
        waitUntilDelivered(afterSplice)

        // One more live turn — the append path the old single-index check ran on.
        deliverCompleteTurn(id: "u0", seq: 200_000)
        waitUntilDelivered(afterSplice + 1)

        waitUntil(timeout: 15) { self.coldnessHoldsOutsideTheHotWindow() }
        waitUntil(timeout: 15) { self.session.hotPayloadTurnCount <= self.hotWindow + self.margin }
    }

    // MARK: - 3. A marker is never compacted

    func testTheGapMarkerInsertedBySpliceIsNeverSkeletonized() throws {
        let firstBatch = hotWindow + 30
        for seq in 0 ..< firstBatch {
            deliverCompleteTurn(id: "t\(seq)", seq: seq)
        }
        waitUntilDelivered(firstBatch)
        waitUntil { self.coldnessHoldsOutsideTheHotWindow() }

        let spliceCount = 30
        let snapshot = (0 ..< spliceCount).map { i in
            DaemonTurn(id: "s\(i)", userInput: "second-life-\(i)",
                      timestamp: timestamp(100_000 + i), blocks: [], isComplete: true)
        }
        client.messages.send(.sessionTurns(tag: "test", turns: snapshot))
        let afterSplice = firstBatch + 1 + spliceCount
        waitUntilDelivered(afterSplice)

        deliverCompleteTurn(id: "u0", seq: 200_000)
        waitUntilDelivered(afterSplice + 1)

        waitUntil(timeout: 15) { self.coldnessHoldsOutsideTheHotWindow() }

        let marker = try XCTUnwrap(session.turns.first { $0.isGapMarker },
                                   "expected a gap marker after a no-common-ground splice")
        XCTAssertNil(marker.truncatedLengths,
                     "a marker is a statement about missing history, not a turn with a payload to shed")

        switch session.payloadStore.hydrate(marker) {
        case .full:
            break   // never compacted, so it must still be reported as its own full (empty) content
        case .unavailable:
            XCTFail("a marker that was never compacted must never be reported unavailable either")
        }
    }

    // MARK: - 4. An incomplete old turn is revisited, not abandoned

    /// The old single-index check skipped an incomplete turn once and never
    /// looked at it again, however far later turns buried it. The sweep must
    /// revisit it on a later delta, once it has actually completed.
    func testAnIncompleteOldTurnIsRevisitedOnceItCompletesRatherThanAbandoned() throws {
        let held = DaemonTurn(id: "held", userInput: "still-typing",
                              timestamp: timestamp(0), blocks: [], isComplete: false)
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnStarted(held)))
        waitUntilDelivered(1)

        // Bury it well past the hot window with further complete turns.
        let buryCount = hotWindow + 10
        for i in 0 ..< buryCount {
            deliverCompleteTurn(id: "b\(i)", seq: i + 1)
        }
        waitUntilDelivered(1 + buryCount)
        waitUntil { self.coldnessHoldsOutsideTheHotWindow() }

        func findHeld() -> ChatTurn? { session.turns.first { $0.daemonId == "held" } }

        let heldWhileStreaming = try XCTUnwrap(findHeld(), "the held turn vanished from the transcript")
        XCTAssertNil(heldWhileStreaming.truncatedLengths,
                     "a turn still streaming must never be compacted, however far it gets buried")

        // Complete it, then deliver one more turn — the append path that runs the sweep.
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnCompleted(
            turnId: "held",
            summary: DaemonResultSummary(durationMs: 1, costUsd: 0, isError: false),
            contextTokens: nil)))
        deliverCompleteTurn(id: "final", seq: buryCount + 1)
        waitUntilDelivered(1 + buryCount + 1)

        waitUntil(timeout: 15) {
            guard let held = findHeld() else { return false }
            return held.truncatedLengths != nil
        }
    }
}
