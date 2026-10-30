import XCTest
import Foundation

// `TerminalStagingStore`: the commands agents have staged for each terminal, as the daemon last said.
//
//   * A frame whose revision is not newer than the last one seen for that terminal is ignored, and
//     notifies nobody.
//   * `state: none` removes the list; `terminal_closed` and a lost daemon connection remove it too
//     (a lost connection also forgets every revision, because a restarted daemon counts from the start).
//   * `shownSince`: when an entry's current (command, note) was first received, on the store's injected
//     clock. Kept while the text is unchanged; restarted for one entry whose command or note changed;
//     restarted for EVERY entry when the sequence of entry ids changes (a row appeared, went away or moved).
//   * Observers are tokens: releasing one stops its calls.
//   * Remove, Clear and the insert report go out through the transport as the right frames.

final class TerminalStagingStoreTests: XCTestCase {

    private let id = StagingFixtures.terminalId
    private var clock: TimeInterval = 500
    private var frames: [TerminalClientMessage] = []
    private var store: TerminalStagingStore!
    private var revision = 0

    override func setUp() {
        super.setUp()
        clock = 500
        frames = []
        revision = 0
        store = TerminalStagingStore(clock: { [unowned self] in self.clock }, transport: { [unowned self] in self.frames.append($0) })
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func frame(_ entries: [StagingEntry], terminal: String? = nil, state: TerminalStagingState = .active,
                       revision explicit: Int? = nil) -> TerminalStagingList {
        revision += 1
        return StagingFixtures.list(terminalId: terminal ?? id, state: state, revision: explicit ?? revision, entries: entries)
    }

    private func entry(_ id: String, _ command: String, note: String? = nil) -> StagingEntry {
        StagingFixtures.entry(id, 1, command, note: note)
    }

    private func shown(_ entryId: String, terminal: String? = nil) -> TimeInterval? {
        store.shownSince(terminalId: terminal ?? id, entryId: entryId)
    }

    // MARK: Revisions

    func testAFrameIsStoredAndReadBack() {
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd")]))

        XCTAssertEqual(store.list(for: id)?.entries.map(\.command), ["ls", "pwd"])
        XCTAssertEqual(store.entry(terminalId: id, entryId: "b")?.command, "pwd")
        XCTAssertNil(store.entry(terminalId: id, entryId: "missing"))
        XCTAssertNil(store.list(for: "another-terminal"))
    }

    func testAFrameWithTheSameRevisionIsIgnoredAndNotifiesNobody() {
        store.ingest(frame([entry("a", "ls")], revision: 5))
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        let before = store.notificationCount

        store.ingest(frame([entry("a", "rm -rf the-impostor")], revision: 5))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "ls", "the list is untouched")
        XCTAssertEqual(store.notificationCount, before, "no notification at all")
        XCTAssertEqual(calls, 0)
        withExtendedLifetime(token) {}
    }

    func testAnOlderFrameIsIgnoredAndNotifiesNobody() {
        store.ingest(frame([entry("a", "ls")], revision: 5))
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        let before = store.notificationCount

        store.ingest(frame([entry("a", "older")], revision: 4))
        store.ingest(frame([], state: .none, revision: 1))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "ls")
        XCTAssertEqual(store.notificationCount, before)
        XCTAssertEqual(calls, 0)
        withExtendedLifetime(token) {}
    }

    func testANewerFrameReplacesTheListAndNotifiesTheObserverOnce() {
        store.ingest(frame([entry("a", "ls")], revision: 5))
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }

        store.ingest(frame([entry("a", "ls -la")], revision: 6))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "ls -la")
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(token) {}
    }

    func testRevisionsAreKeptPerTerminal() {
        store.ingest(frame([entry("a", "ls")], terminal: "t-1", revision: 10))
        store.ingest(frame([entry("a", "pwd")], terminal: "t-2", revision: 3))

        XCTAssertEqual(store.list(for: "t-1")?.entries.first?.command, "ls")
        XCTAssertEqual(store.list(for: "t-2")?.entries.first?.command, "pwd", "t-2's revision 3 is its first, not older than t-1's 10")
    }

    // MARK: State none, closed, connection

    func testAFrameWithStateNoneRemovesTheListAndNotifies() {
        store.ingest(frame([entry("a", "ls")]))
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }

        store.ingest(frame([], state: .none))

        XCTAssertNil(store.list(for: id))
        XCTAssertNil(shown("a"))
        XCTAssertEqual(calls, 1)
        withExtendedLifetime(token) {}
    }

    func testAFrameWithStateNoneForATerminalWithNoListNotifiesNobody() {
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        let before = store.notificationCount

        store.ingest(frame([], state: .none))

        XCTAssertNil(store.list(for: id))
        XCTAssertEqual(store.notificationCount, before)
        XCTAssertEqual(calls, 0)
        withExtendedLifetime(token) {}
    }

    func testAFrozenListStaysUntilSomethingRemovesIt() {
        store.ingest(frame([entry("a", "ls")], state: .frozen))

        XCTAssertEqual(store.list(for: id)?.state, .frozen)
        XCTAssertEqual(store.list(for: id)?.entries.count, 1)
    }

    func testTerminalClosedRemovesThatTerminalsListOnlyAndNotifiesItsObserver() {
        store.ingest(frame([entry("a", "ls")], terminal: "t-1"))
        store.ingest(frame([entry("a", "pwd")], terminal: "t-2"))
        var gone = 0, other = 0
        let first = store.observe(terminalId: "t-1") { gone += 1 }
        let second = store.observe(terminalId: "t-2") { other += 1 }

        store.terminalClosed("t-1")

        XCTAssertNil(store.list(for: "t-1"))
        XCTAssertNil(shown("a", terminal: "t-1"))
        XCTAssertNotNil(store.list(for: "t-2"))
        XCTAssertEqual(gone, 1)
        XCTAssertEqual(other, 0)
        withExtendedLifetime([first, second]) {}
    }

    func testTerminalClosedForAnUnknownTerminalNotifiesNobody() {
        let before = store.notificationCount
        store.terminalClosed("nobody")
        XCTAssertEqual(store.notificationCount, before)
    }

    func testAClosedTerminalsRevisionIsForgottenSoANewListWithALowerRevisionIsShown() {
        store.ingest(frame([entry("a", "ls")], revision: 50))
        store.terminalClosed(id)

        store.ingest(frame([entry("a", "pwd")], revision: 1))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "pwd")
    }

    func testLosingTheConnectionClearsEveryListAndNotifiesEachObserver() {
        store.ingest(frame([entry("a", "ls")], terminal: "t-1"))
        store.ingest(frame([entry("a", "pwd")], terminal: "t-2"))
        var calls: [String] = []
        let first = store.observe(terminalId: "t-1") { calls.append("t-1") }
        let second = store.observe(terminalId: "t-2") { calls.append("t-2") }

        store.connectionChanged(false)

        XCTAssertNil(store.list(for: "t-1"))
        XCTAssertNil(store.list(for: "t-2"))
        XCTAssertNil(shown("a", terminal: "t-1"))
        XCTAssertEqual(calls.sorted(), ["t-1", "t-2"])
        withExtendedLifetime([first, second]) {}
    }

    func testLosingTheConnectionForgetsRevisionsBecauseARestartedDaemonCountsFromTheStart() {
        store.ingest(frame([entry("a", "ls")], revision: 900))

        store.connectionChanged(false)
        store.ingest(frame([entry("a", "after the restart")], revision: 1))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "after the restart")
    }

    func testConnectingChangesNothing() {
        store.ingest(frame([entry("a", "ls")]))
        let before = store.notificationCount

        store.connectionChanged(true)

        XCTAssertNotNil(store.list(for: id))
        XCTAssertEqual(store.notificationCount, before)
    }

    // MARK: shownSince

    func testShownSinceIsTheStoresClockWhenTheEntryWasFirstReceived() {
        clock = 700
        store.ingest(frame([entry("a", "ls")]))

        XCTAssertEqual(shown("a"), 700)
        XCTAssertNil(shown("unknown"))
        XCTAssertNil(shown("a", terminal: "another-terminal"))
        clock = 720
        XCTAssertEqual(store.now, 720, "`now` is the same clock")
    }

    func testShownSinceIsKeptWhenAFrameRepeatsTheSameTextOfTheSameRows() {
        clock = 700
        store.ingest(frame([entry("a", "ls", note: "n"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([StagingFixtures.entry("a", 1, "ls", note: "n", insertedCount: 1, lastInsertedAt: StagingFixtures.baseDate),
                            entry("b", "pwd")]))

        XCTAssertEqual(shown("a"), 700, "only the insert count changed")
        XCTAssertEqual(shown("b"), 700)
    }

    func testShownSinceRestartsForTheEntryWhoseCommandChangedOnly() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("a", "ls -la"), entry("b", "pwd")]))

        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("b"), 700, "an edit of one entry restarts that entry alone")
    }

    func testShownSinceRestartsForTheEntryWhoseNoteChangedOnly() {
        clock = 700
        store.ingest(frame([entry("a", "ls", note: "old"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("a", "ls", note: "new"), entry("b", "pwd")]))
        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("b"), 700)

        clock = 800
        store.ingest(frame([entry("a", "ls", note: nil), entry("b", "pwd")]))
        XCTAssertEqual(shown("a"), 800, "dropping the note is a change too")
    }

    func testShownSinceRestartsForEveryEntryWhenOneIsAppended() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd"), entry("c", "date")]))

        XCTAssertEqual(shown("a"), 760, "a row appeared: nothing is where the person last saw it")
        XCTAssertEqual(shown("b"), 760)
        XCTAssertEqual(shown("c"), 760)
    }

    func testShownSinceRestartsForEveryEntryWhenOneIsRemoved() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd"), entry("c", "date")]))

        clock = 760
        store.ingest(frame([entry("a", "ls"), entry("c", "date")]))

        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("c"), 760)
        XCTAssertNil(shown("b"))
    }

    func testShownSinceRestartsForEveryEntryWhenTheOrderChanges() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("b", "pwd"), entry("a", "ls")]))

        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("b"), 760)
    }

    func testAFrozenFrameThatChangesNothingKeepsEveryShownSince() {
        clock = 700
        store.ingest(frame([entry("a", "ls")]))

        clock = 760
        store.ingest(frame([entry("a", "ls")], state: .frozen))

        XCTAssertEqual(shown("a"), 700)
    }

    func testShownSinceStartsAgainAfterTheListWasRemoved() {
        clock = 700
        store.ingest(frame([entry("a", "ls")]))
        store.ingest(frame([], state: .none))

        clock = 900
        store.ingest(frame([entry("a", "ls")]))

        XCTAssertEqual(shown("a"), 900)
    }

    // MARK: Observers

    func testAnObserverIsCalledOnlyForItsOwnTerminal() {
        var mine = 0, theirs = 0
        let a = store.observe(terminalId: "t-1") { mine += 1 }
        let b = store.observe(terminalId: "t-2") { theirs += 1 }

        store.ingest(frame([entry("a", "ls")], terminal: "t-1"))

        XCTAssertEqual(mine, 1)
        XCTAssertEqual(theirs, 0)
        withExtendedLifetime([a, b]) {}
    }

    func testReleasingTheTokenStopsTheCalls() {
        var calls = 0
        var token: TerminalStagingStore.Observation? = store.observe(terminalId: id) { calls += 1 }
        store.ingest(frame([entry("a", "ls")]))
        XCTAssertEqual(calls, 1)

        token = nil
        store.ingest(frame([entry("a", "pwd")]))
        store.terminalClosed(id)
        store.connectionChanged(false)

        XCTAssertEqual(calls, 1, "a released observation hears nothing more")
        _ = token
    }

    func testTwoObserversOfOneTerminalAreBothCalledAndReleasingOneLeavesTheOther() {
        var first = 0, second = 0
        var tokenA: TerminalStagingStore.Observation? = store.observe(terminalId: id) { first += 1 }
        let tokenB = store.observe(terminalId: id) { second += 1 }

        store.ingest(frame([entry("a", "ls")]))
        tokenA = nil
        store.ingest(frame([entry("a", "pwd")]))

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        _ = tokenA
        withExtendedLifetime(tokenB) {}
    }

    func testTheStoreDoesNotKeepAnObservationAliveAndTheHandlerCanReleaseItsOwner() {
        weak var weakOwner: ObservationOwner?
        do {
            let owner = ObservationOwner()
            weakOwner = owner
            owner.token = store.observe(terminalId: id) { [weak owner] in owner?.calls += 1 }
            store.ingest(frame([entry("a", "ls")]))
            XCTAssertEqual(owner.calls, 1)
        }
        XCTAssertNil(weakOwner, "a handler that holds its owner weakly does not keep it alive through the store")
        store.ingest(frame([entry("a", "pwd")]))
    }

    func testAnObservationOutlivingTheStoreIsHarmless() {
        var token: TerminalStagingStore.Observation?
        do {
            let short = TerminalStagingStore(clock: { 0 })
            token = short.observe(terminalId: id) {}
        }
        token = nil
        XCTAssertNil(token)
    }

    // MARK: Frames to the daemon

    func testReportInsertedSendsTheInsertedFrameWithConfirmedFalse() {
        store.reportInserted(terminalId: id, entryId: "a", bytes: 12)

        XCTAssertEqual(frames, [.stagingInserted(terminalId: id, entryId: "a", bytes: 12, confirmed: false)])
    }

    func testRemoveSendsTheRemoveFrame() {
        store.remove(terminalId: id, entryId: "a")

        XCTAssertEqual(frames, [.stagingRemove(terminalId: id, entryId: "a")])
    }

    func testClearSendsTheClearFrame() {
        store.clear(terminalId: id)

        XCTAssertEqual(frames, [.stagingClear(terminalId: id)])
    }

    func testIngestingFramesSendsNothingToTheDaemon() {
        store.ingest(frame([entry("a", "ls")]))
        store.ingest(frame([], state: .none))
        store.connectionChanged(false)
        store.terminalClosed(id)

        XCTAssertTrue(frames.isEmpty)
    }
}

/// Holds an observation token, like a drawer does.
private final class ObservationOwner {
    var token: TerminalStagingStore.Observation?
    var calls = 0
}
