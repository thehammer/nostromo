import XCTest
import Combine
import NostromoKit

// `TrackerStore` (T1): the one place every window's tracker pane reads a focus's board from.
//
// What it promises: frames reach their own tag only; a `board: null` frame never blanks a focus;
// an identical board is still delivered (the pane's own diff makes it a no-op, which is what the
// render probe of PRD criterion 20 measures); deliveries are coalesced to at most one per 100 ms per
// tag with the final state always delivered; every subscriber sees the same board at every delivery;
// a lost daemon connection keeps every board; `forget(tag:)` drops one focus and only that one.
//
// Boards are the golden frame decoded through the app's own decoder (`TrackerPaneFx`, defined in
// TrackerPaneViewTests.swift). Time is a clock the test moves and a scheduler the test flushes.

final class TrackerStoreTests: XCTestCase {

    private typealias Fx = TrackerPaneFx

    /// What one subscriber heard: the tag, the board it read at that moment and the (fake) time.
    private struct Delivery: Equatable {
        let tag: String
        let board: TrackerBoardViewWire?
        let at: Date
    }

    private func record(_ store: TrackerStore, clock: TrackerManualClock? = nil,
                        into bag: inout Set<AnyCancellable>, _ sink: @escaping (Delivery) -> Void) {
        store.changes.sink { tag in
            sink(Delivery(tag: tag, board: store.board(for: tag), at: clock?.date ?? Date(timeIntervalSince1970: 0)))
        }.store(in: &bag)
    }

    private func script(_ tag: String, version: Int? = nil, _ edit: (inout TrackerBoardScript) throws -> Void = { _ in }) throws -> TrackerBoardScript {
        var s = try TrackerBoardScript(tag: tag)
        if let version { s.setVersion(version) }
        try edit(&s)
        return s
    }

    // MARK: - Routing

    func testABoardFrameIsKeptUnderItsOwnTagAndAnnouncedForThatTagOnly() throws {
        let store = Fx.makeImmediateStore()
        var bag = Set<AnyCancellable>()
        var heard: [String] = []
        record(store, into: &bag) { heard.append($0.tag) }

        let a = try script("kate-a")
        store.ingest(try a.message())

        XCTAssertEqual(store.board(for: "kate-a"), try a.decodedBoard())
        XCTAssertNil(store.board(for: "kate-b"), "another focus has no board")
        XCTAssertEqual(heard, ["kate-a"])
    }

    func testTwoFocusesKeepTheirOwnBoards() throws {
        let store = Fx.makeImmediateStore()
        let a = try script("kate-a", version: 1)
        let b = try script("kate-b", version: 2) { try $0.setStatus("verif-1037", "blocked") }
        store.ingest(try a.message())
        store.ingest(try b.message())
        XCTAssertEqual(store.board(for: "kate-a"), try a.decodedBoard())
        XCTAssertEqual(store.board(for: "kate-b"), try b.decodedBoard())
        XCTAssertNotEqual(store.board(for: "kate-a"), store.board(for: "kate-b"))
    }

    func testASummaryFrameIsKeptUnderItsOwnTagAndAnnouncedForThatTagOnly() throws {
        let store = Fx.makeImmediateStore()
        var bag = Set<AnyCancellable>()
        var heard: [String] = []
        record(store, into: &bag) { heard.append($0.tag) }

        store.ingest(try Fx.summaryMessage(tag: "kate-a"))

        let summary = try XCTUnwrap(store.summary(for: "kate-a"))
        XCTAssertTrue(summary.hasTracker)
        XCTAssertEqual(summary.counts.needsYou, 10)
        XCTAssertEqual(summary.counts.done, 17)
        XCTAssertNil(store.summary(for: "kate-b"))
        XCTAssertNil(store.board(for: "kate-a"), "a summary is not a board")
        XCTAssertEqual(heard, ["kate-a"])

        store.ingest(try Fx.summaryMessage(tag: "kate-a"))
        XCTAssertEqual(heard, ["kate-a"], "an identical summary is not announced again")
    }

    func testFramesThatAreNotTrackerFramesAreIgnored() throws {
        let store = Fx.makeImmediateStore()
        var heard: [String] = []
        var bag = Set<AnyCancellable>()
        record(store, into: &bag) { heard.append($0.tag) }
        store.ingest(.unknown)
        XCTAssertEqual(heard, [])
    }

    // MARK: - A null board never blanks a focus

    func testANullBoardKeepsTheLastBoardAndAnnouncesNothing() throws {
        let store = Fx.makeImmediateStore()
        let a = try script("kate-a")
        store.ingest(try a.message())
        var bag = Set<AnyCancellable>()
        var heard: [String] = []
        record(store, into: &bag) { heard.append($0.tag) }

        store.ingest(try Fx.nullBoardMessage(tag: "kate-a"))

        XCTAssertEqual(store.board(for: "kate-a"), try a.decodedBoard(), "the pane keeps what it was showing")
        XCTAssertEqual(heard, [])
    }

    func testANullBoardForAFocusWithNoBoardStaysEmpty() throws {
        let store = Fx.makeImmediateStore()
        store.ingest(try Fx.nullBoardMessage(tag: "kate-a"))
        XCTAssertNil(store.board(for: "kate-a"))
    }

    // MARK: - Identical boards are delivered; the pane's diff makes them a no-op

    func testAnIdenticalBoardIsDeliveredAndReadsTheSame() throws {
        let store = Fx.makeImmediateStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(store, into: &bag) { deliveries.append($0) }

        let a = try script("kate-a")
        store.ingest(try a.message())
        store.ingest(try a.message())
        store.ingest(try a.message())

        XCTAssertEqual(deliveries.count, 3)
        XCTAssertTrue(deliveries.allSatisfy { $0.board == deliveries.first?.board }, "every delivery reads the same board")
    }

    func testAChangedBoardIsDeliveredAndReadsAsTheNewOne() throws {
        let store = Fx.makeImmediateStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(store, into: &bag) { deliveries.append($0) }

        var s = try script("kate-a", version: 7)
        store.ingest(try s.message())
        try s.setStatus("verif-1037", "blocked")
        s.setVersion(8)
        store.ingest(try s.message())

        XCTAssertEqual(deliveries.count, 2)
        XCTAssertEqual(deliveries.last?.board?.version, 8)
        XCTAssertEqual(deliveries.last?.board, try s.decodedBoard())
    }

    // MARK: - Coalescing: at most 10 Hz per tag, the final state always delivered

    func testTheFirstChangeIsDeliveredAtOnceAndLaterOnesWithinTheWindowFoldIntoOneDeliveryOfTheLatest() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { deliveries.append($0) }

        manual.store.ingest(try script("kate-a", version: 1).message())
        XCTAssertEqual(deliveries.count, 1, "the first change goes out at once")
        XCTAssertEqual(deliveries.first?.board?.version, 1)
        XCTAssertTrue(manual.scheduler.scheduled.isEmpty)

        manual.clock.advance(0.02)
        manual.store.ingest(try script("kate-a", version: 2).message())
        manual.clock.advance(0.03)
        manual.store.ingest(try script("kate-a", version: 3).message())
        XCTAssertEqual(deliveries.count, 1, "changes inside the 100 ms window wait")
        XCTAssertEqual(manual.scheduler.scheduled.count, 1, "and share one scheduled delivery")
        XCTAssertTrue(manual.scheduler.delays.allSatisfy { $0 > 0 && $0 <= 0.1 }, "due within the window: \(manual.scheduler.delays)")

        manual.clock.advance(0.05)   // 100 ms after the first delivery
        manual.scheduler.flush()
        XCTAssertEqual(deliveries.count, 2, "exactly one later delivery")
        XCTAssertEqual(deliveries.last?.board?.version, 3, "and it reads the latest board, not the one that arrived first")
        XCTAssertEqual(deliveries.last?.board, manual.store.board(for: "kate-a"))
    }

    func testNeverMoreThanOneDeliveryPerHundredMillisecondsForATag() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { deliveries.append($0) }

        // A burst: a change every 10 ms for a second, flushing whatever is due as time passes.
        for version in 1...100 {
            manual.store.ingest(try script("kate-a", version: version).message())
            manual.clock.advance(0.01)
            // The main run loop would fire a scheduled delivery when its delay is over; here, when 100 ms
            // have passed since the previous delivery.
            if let last = deliveries.last, manual.clock.date.timeIntervalSince(last.at) >= 0.1 {
                manual.scheduler.flush()
            }
        }
        manual.clock.advance(0.1)
        manual.scheduler.flush()

        XCTAssertGreaterThanOrEqual(deliveries.count, 2)
        XCTAssertLessThanOrEqual(deliveries.count, 12, "a second of changes is about ten deliveries, not a hundred")
        for (earlier, later) in zip(deliveries, deliveries.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.at.timeIntervalSince(earlier.at), 0.0999, "two deliveries closer than 100 ms")
        }
        XCTAssertEqual(deliveries.last?.board?.version, 100, "the final state is always delivered")
    }

    func testAChangeAfterAQuietPeriodIsDeliveredAtOnceAgain() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { deliveries.append($0) }

        manual.store.ingest(try script("kate-a", version: 1).message())
        manual.clock.advance(0.5)
        manual.store.ingest(try script("kate-a", version: 2).message())
        XCTAssertEqual(deliveries.count, 2, "nothing was waiting, so nothing waited")
        XCTAssertTrue(manual.scheduler.scheduled.isEmpty)
    }

    func testCoalescingIsPerTag() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { deliveries.append($0) }

        manual.store.ingest(try script("kate-a", version: 1).message())
        manual.store.ingest(try script("kate-a", version: 2).message())   // held
        manual.store.ingest(try script("kate-b", version: 1).message())   // another focus: not held by kate-a's window
        XCTAssertEqual(deliveries.map(\.tag), ["kate-a", "kate-b"])

        manual.clock.advance(0.1)
        manual.scheduler.flush()
        XCTAssertEqual(deliveries.map(\.tag), ["kate-a", "kate-b", "kate-a"])
        XCTAssertEqual(deliveries.last?.board?.version, 2)
    }

    func testTwoSubscribersSeeTheSameBoardAtEveryDelivery() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var first: [Delivery] = []
        var second: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { first.append($0) }
        record(manual.store, clock: manual.clock, into: &bag) { second.append($0) }

        for version in 1...6 {
            manual.store.ingest(try script("kate-a", version: version) { try $0.setText("revie-1111", "Review (\(version))") }.message())
            manual.clock.advance(0.04)
            if manual.clock.date.timeIntervalSince(first.last?.at ?? .distantPast) >= 0.1 { manual.scheduler.flush() }
        }
        manual.clock.advance(0.1)
        manual.scheduler.flush()

        XCTAssertGreaterThanOrEqual(first.count, 2)
        XCTAssertEqual(first, second, "every delivery reaches both, with the same board in hand")
        XCTAssertEqual(first.last?.board?.version, 6)
    }

    // MARK: - A lost connection keeps everything

    func testALostDaemonConnectionKeepsEveryBoardAndSummary() throws {
        let store = Fx.makeImmediateStore()
        let a = try script("kate-a", version: 1)
        let b = try script("kate-b", version: 2)
        store.ingest(try a.message())
        store.ingest(try b.message())
        store.ingest(try Fx.summaryMessage(tag: "kate-a"))
        var bag = Set<AnyCancellable>()
        var heard: [String] = []
        record(store, into: &bag) { heard.append($0.tag) }

        store.daemonDisconnected()

        XCTAssertEqual(store.board(for: "kate-a"), try a.decodedBoard())
        XCTAssertEqual(store.board(for: "kate-b"), try b.decodedBoard())
        XCTAssertNotNil(store.summary(for: "kate-a"))
        XCTAssertEqual(heard, [], "nobody is told to blank")
    }

    func testTheReconnectsReplayReplacesTheBoardInPlace() throws {
        let store = Fx.makeImmediateStore()
        var s = try script("kate-a", version: 1)
        store.ingest(try s.message())
        store.daemonDisconnected()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(store, into: &bag) { deliveries.append($0) }

        try s.setStatus("verif-1037", "blocked")
        s.setVersion(2)
        store.ingest(try s.message())

        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(store.board(for: "kate-a"), try s.decodedBoard())
    }

    // MARK: - forget

    func testForgettingAFocusDropsItsBoardAndSummaryAndNothingElse() throws {
        let store = Fx.makeImmediateStore()
        let b = try script("kate-b", version: 2)
        store.ingest(try script("kate-a", version: 1).message())
        store.ingest(try b.message())
        store.ingest(try Fx.summaryMessage(tag: "kate-a"))
        store.ingest(try Fx.summaryMessage(tag: "kate-b"))

        store.forget(tag: "kate-a")

        XCTAssertNil(store.board(for: "kate-a"))
        XCTAssertNil(store.summary(for: "kate-a"))
        XCTAssertEqual(store.board(for: "kate-b"), try b.decodedBoard())
        XCTAssertNotNil(store.summary(for: "kate-b"))
    }

    func testAForgottenFocusGetsNoLateDeliveryAndAFreshBoardForTheSameTagIsDeliveredAtOnce() throws {
        let manual = Fx.makeManualStore()
        var bag = Set<AnyCancellable>()
        var deliveries: [Delivery] = []
        record(manual.store, clock: manual.clock, into: &bag) { deliveries.append($0) }

        manual.store.ingest(try script("kate-a", version: 1).message())
        manual.store.ingest(try script("kate-a", version: 2).message())   // held for the end of the window
        manual.store.forget(tag: "kate-a")
        manual.clock.advance(0.1)
        manual.scheduler.flush()
        XCTAssertEqual(deliveries.count, 1, "the focus is gone: no delivery for it")
        XCTAssertNil(manual.store.board(for: "kate-a"))

        manual.store.ingest(try script("kate-a", version: 3).message())
        XCTAssertEqual(deliveries.count, 2, "a new focus with the same tag starts fresh")
        XCTAssertEqual(deliveries.last?.board?.version, 3)
    }

    // MARK: - Wiring (AppStore.swift is not driven here; read as text, like the other wiring tests)

    private func appStoreSource() throws -> String {
        try String(contentsOf: Fx.repoRoot().appendingPathComponent("macOS/Nostromo/Data/AppStore.swift"), encoding: .utf8)
    }

    func testAppStoreRoutesTrackerFramesToTheSharedStore() throws {
        let source = try appStoreSource()
        let caseRange = try XCTUnwrap(source.range(of: "case .trackerBoard, .trackerSummary:"),
                                      "AppStore.handle must name both tracker frames in one case")
        // The next lines up to the following `case` are that case's body.
        let rest = source[caseRange.upperBound...]
        let body = rest.components(separatedBy: "\n        case ").first ?? ""
        XCTAssertTrue(body.contains("TrackerStore.shared.ingest(msg)"), "the case hands the frame to the store: \(body)")
    }

    func testAppStoreForgetsAFocusWhenItsPerFocusStateIsEvicted() throws {
        let source = try appStoreSource()
        let start = try XCTUnwrap(source.range(of: "func evictPerFocusState(tag: String) {"))
        let tail = source[start.upperBound...]
        let body = tail.components(separatedBy: "\n    }\n").first ?? ""
        XCTAssertTrue(body.contains("TrackerStore.shared.forget(tag: tag)"), "evictPerFocusState must forget the tag's tracker: \(body)")
    }

    func testAppStoreTellsTheStoreWhenTheDaemonConnectionDrops() throws {
        let source = try appStoreSource()
        XCTAssertTrue(source.contains("TrackerStore.shared.daemonDisconnected()"),
                      "a dropped connection must reach the tracker store (so it keeps boards instead of blanking)")
    }
}
