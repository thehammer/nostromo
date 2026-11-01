import XCTest
import Foundation

// `TerminalStagingStore`: the commands agents have staged for each terminal, as the daemon last said.
//
//   * A frame whose revision is not newer than the last one seen for that terminal is ignored, and
//     notifies nobody.
//   * `state: none` removes the list; `terminal_closed` and a lost daemon connection remove it too
//     (a lost connection also forgets every revision, because a restarted daemon counts from the start).
//   * A frame the app cannot read (`listUnreadable`) drops that terminal's list like `none` does, but KEEPS
//     its revision: a replayed frame must not bring the dropped list back (a closed terminal forgets it).
//   * `shownSince`: when an entry's current (command, note) was first received, on the store's injected
//     clock. Kept for every entry while no entry's text changed; restarted for EVERY entry when any entry's
//     command or note changes, or when the sequence of entry ids changes (a row appeared, went away or
//     moved): an edit that changes one row's height shifts every row below it.
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

    // MARK: A frame the app cannot read

    func testAnUnreadableListIsDroppedForThatTerminalOnlyAndItsObserverIsToldOnce() {
        clock = 700
        store.ingest(frame([entry("a", "ls")], terminal: "t-1", revision: 5))
        store.ingest(frame([entry("a", "pwd")], terminal: "t-2", revision: 5))
        var gone = 0, other = 0
        let first = store.observe(terminalId: "t-1") { gone += 1 }
        let second = store.observe(terminalId: "t-2") { other += 1 }

        store.listUnreadable("t-1")

        XCTAssertNil(store.list(for: "t-1"))
        XCTAssertNil(shown("a", terminal: "t-1"), "no entry of it is being read any more")
        XCTAssertEqual(store.list(for: "t-2")?.entries.first?.command, "pwd", "another terminal's list is untouched")
        XCTAssertEqual(shown("a", terminal: "t-2"), 700)
        XCTAssertEqual(gone, 1, "its drawer is told once")
        XCTAssertEqual(other, 0)
        withExtendedLifetime([first, second]) {}
    }

    func testAnUnreadableListForATerminalWithNoListNotifiesNobody() {
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        let before = store.notificationCount

        store.listUnreadable(id)
        store.listUnreadable("nobody")

        XCTAssertNil(store.list(for: id))
        XCTAssertEqual(store.notificationCount, before)
        XCTAssertEqual(calls, 0)
        withExtendedLifetime(token) {}
    }

    func testAnUnreadableListKeepsTheRevisionSoAReplayedFrameCannotBringTheListBack() {
        store.ingest(frame([entry("a", "ls")], revision: 5))
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }

        store.listUnreadable(id)
        XCTAssertNil(store.list(for: id), "harness: the list is gone")
        XCTAssertEqual(calls, 1, "harness: and the observer was told")
        let before = store.notificationCount

        store.ingest(frame([entry("a", "replayed")], revision: 4))
        store.ingest(frame([entry("a", "replayed too")], revision: 5))

        XCTAssertNil(store.list(for: id), "revisions 4 and 5 were seen already: neither brings the list back")
        XCTAssertNil(shown("a"))
        XCTAssertEqual(store.notificationCount, before, "and nobody is told about them")
        XCTAssertEqual(calls, 1)

        store.ingest(frame([entry("a", "ls -la")], revision: 6))

        XCTAssertEqual(store.list(for: id)?.entries.first?.command, "ls -la", "a newer revision is accepted")
        XCTAssertEqual(calls, 2)
        withExtendedLifetime(token) {}
    }

    func testAnUnreadableListIsNotTheSameAsAClosedTerminalWhichForgetsItsRevision() {
        store.ingest(frame([entry("a", "ls")], terminal: "t-1", revision: 50))
        store.ingest(frame([entry("a", "ls")], terminal: "t-2", revision: 50))

        store.listUnreadable("t-1")
        store.terminalClosed("t-2")
        store.ingest(frame([entry("a", "again")], terminal: "t-1", revision: 1))
        store.ingest(frame([entry("a", "again")], terminal: "t-2", revision: 1))

        XCTAssertNil(store.list(for: "t-1"), "an unreadable list still remembers revision 50")
        XCTAssertEqual(store.list(for: "t-2")?.entries.first?.command, "again", "a closed terminal's next list may start from 1")
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

    func testShownSinceRestartsForEveryEntryWhenOneEntrysCommandChanges() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("a", "ls -la"), entry("b", "pwd")]))

        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("b"), 760, "an edit may change a row's height and move every row below it")
    }

    func testShownSinceRestartsForEveryEntryWhenOneEntrysNoteChanges() {
        clock = 700
        store.ingest(frame([entry("a", "ls", note: "old"), entry("b", "pwd")]))

        clock = 760
        store.ingest(frame([entry("a", "ls", note: "new"), entry("b", "pwd")]))
        XCTAssertEqual(shown("a"), 760)
        XCTAssertEqual(shown("b"), 760, "a longer note makes the row taller and moves the rows below it")

        clock = 800
        store.ingest(frame([entry("a", "ls", note: nil), entry("b", "pwd")]))
        XCTAssertEqual(shown("a"), 800, "dropping the note is a change too")
        XCTAssertEqual(shown("b"), 800)
    }

    func testAnEditToTheFirstRowRearmsTheReadingDelayOfTheRowBelowItWhoseTextDidNotChange() {
        clock = 700
        store.ingest(frame([entry("a", "ls"), entry("b", "pwd", note: "where am i")]))
        clock = 740
        XCTAssertEqual(shown("b"), 700)

        clock = 760
        store.ingest(frame([entry("a", "ls -la --color=always"), entry("b", "pwd", note: "where am i")]))

        XCTAssertEqual(store.entry(terminalId: id, entryId: "b")?.command, "pwd", "row b's text is untouched")
        XCTAssertEqual(store.entry(terminalId: id, entryId: "b")?.note, "where am i")
        XCTAssertEqual(shown("b"), 760, "but row b moved, so it is read afresh from the moment of the edit")
    }

    func testAFrameThatChangesNoTextKeepsEveryShownSinceEvenWhenOtherFieldsChange() {
        clock = 700
        store.ingest(frame([entry("a", "ls", note: "n"), entry("b", "pwd")]))
        clock = 710
        store.ingest(frame([entry("a", "ls", note: "n"), entry("b", "pwd"), entry("c", "date")]))
        XCTAssertEqual(shown("a"), 710)

        clock = 900
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        store.ingest(frame([StagingFixtures.entry("a", 1, "ls", note: "n", insertedCount: 3, lastInsertedAt: later),
                            StagingFixtures.entry("b", 1, "pwd", insertedCount: 1, lastInsertedAt: later),
                            entry("c", "date")]))

        XCTAssertEqual(shown("a"), 710, "only insert counts changed")
        XCTAssertEqual(shown("b"), 710)
        XCTAssertEqual(shown("c"), 710)
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


// MARK: - S2: switches, archive, auto-archive, reading-delay restarts, UI events

extension TerminalStagingStoreTests {

    private func makeStore(defaults: UserDefaults? = nil) -> (TerminalStagingStore, UserDefaults) {
        let suite = defaults ?? UserDefaults(suiteName: "redd.store.\(UUID().uuidString)")!
        let made = TerminalStagingStore(clock: { [unowned self] in self.clock }, transport: { [unowned self] in self.frames.append($0) },
                                        defaults: suite)
        return (made, suite)
    }

    private func placed(_ id: String, _ command: String, number: Int = 1) -> StagingEntry {
        StagingFixtures.entry(id, number, command, insertedCount: 1, lastInsertedAt: StagingFixtures.baseDate)
    }

    private func listFrame(_ entries: [StagingEntry], owner: String = "owner-tag", enabled: Bool = true, foreground: String? = nil,
                       state: TerminalStagingState = .active) -> TerminalStagingList {
        revision += 1
        return StagingFixtures.list(terminalId: id, state: state, owner: owner, revision: revision, entries: entries,
                                    enabled: enabled, foreground: foreground)
    }

    // MARK: Global switch

    func testTheGlobalSwitchDefaultsOnIsSavedAndRestoredByANewStoreWithNoLists() {
        let (first, suite) = makeStore()
        XCTAssertTrue(first.globalEnabled, "registered default true")
        first.ingest(listFrame([entry("a", "ls")]))
        first.setGlobalEnabled(false)
        XCTAssertEqual(suite.object(forKey: TerminalStagingStore.globalEnabledKey) as? Bool, false)
        XCTAssertEqual(frames.last, .stagingSetGlobal(enabled: false))
        XCTAssertNil(first.list(for: id), "off hides every drawer at once")

        let (second, _) = makeStore(defaults: suite)   // a relaunch
        XCTAssertFalse(second.globalEnabled, "the setting survives a relaunch")
        XCTAssertNil(second.list(for: id), "the lists never do")
    }

    func testTheGlobalSwitchIsReadOnceAtLaunchAndNeverObserved() {
        let (made, suite) = makeStore()
        suite.set(false, forKey: TerminalStagingStore.globalEnabledKey)    // another process: `defaults write`
        made.ingest(listFrame([entry("a", "ls")]))
        XCTAssertTrue(made.globalEnabled, "a write by another process changes nothing while the app runs")
        XCTAssertNotNil(made.list(for: id))
    }

    func testWhileTheGlobalSwitchIsOffIncomingListsAreIgnoredAndTurningOnSendsTrue() {
        let (made, _) = makeStore()
        made.setGlobalEnabled(false)
        made.ingest(listFrame([entry("a", "ls")]))
        XCTAssertNil(made.list(for: id))
        made.setGlobalEnabled(true)
        XCTAssertEqual(frames.last, .stagingSetGlobal(enabled: true))
        made.ingest(listFrame([entry("a", "ls")]))
        XCTAssertNotNil(made.list(for: id))
        frames.removeAll()
        made.resendGlobal()
        XCTAssertEqual(frames, [.stagingSetGlobal(enabled: true)])
    }

    // MARK: Per-terminal switch

    func testEnabledIsTheLastValueTheDaemonSentAndSurvivesNoneFramesUntilTheTerminalClosesOrTheConnectionDrops() {
        XCTAssertTrue(store.isEnabled(terminalId: id), "every terminal starts enabled")
        store.ingest(listFrame([], enabled: false, state: .none))
        XCTAssertFalse(store.isEnabled(terminalId: id))
        store.ingest(listFrame([], enabled: false, state: .none))
        XCTAssertFalse(store.isEnabled(terminalId: id))
        store.terminalClosed(id)
        XCTAssertTrue(store.isEnabled(terminalId: id))

        store.ingest(listFrame([], enabled: false, state: .none))
        store.connectionChanged(false)
        XCTAssertTrue(store.isEnabled(terminalId: id))
        store.setEnabled(terminalId: id, enabled: false)
        XCTAssertEqual(frames.last, .stagingSetEnabled(terminalId: id, enabled: false))
        XCTAssertTrue(store.isEnabled(terminalId: id), "the check follows the daemon's frame, not the request")
    }

    func testANoneFrameThatOnlyChangesEnabledNotifiesTheMenuObservers() {
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        store.ingest(listFrame([], enabled: false, state: .none))
        XCTAssertEqual(calls, 1)
        _ = token
    }

    // MARK: Archive

    func testArchiveSendsTheFrameMovesTheEntryToTheFooterAndOutOfTheList() {
        store.ingest(listFrame([placed("a", "ls", number: 1), entry("b", "pwd")]))
        store.archive(terminalId: id, entryId: "a", auto: false)

        XCTAssertEqual(frames.last, .stagingRemove(terminalId: id, entryId: "a", archive: "manual"))
        XCTAssertEqual(store.list(for: id)?.entries.map(\.id), ["b"], "gone from the list at once")
        XCTAssertNil(store.entry(terminalId: id, entryId: "a"), "an archived entry can never be inserted")
        XCTAssertEqual(store.archivedEntries(for: id).map(\.entryId), ["a"])
        XCTAssertEqual(store.archivedEntries(for: id).first?.command, "ls")

        store.archive(terminalId: id, entryId: "b", auto: true)
        XCTAssertEqual(frames.last, .stagingRemove(terminalId: id, entryId: "b", archive: "auto"))
        store.archive(terminalId: id, entryId: "zzz", auto: false)
        XCTAssertEqual(store.archivedEntries(for: id).count, 2, "nothing for an entry that is not there")
    }

    func testAtMostTwelveArchivedEntriesAreKeepAndTheOldestIsDropped() {
        let entries = (1...14).map { placed("e\($0)", "echo \($0)", number: $0) }
        store.ingest(listFrame(entries))
        for entry in entries { store.archive(terminalId: id, entryId: entry.id, auto: false) }
        let kept = store.archivedEntries(for: id).map(\.entryId)
        XCTAssertEqual(kept.count, 12)
        XCTAssertEqual(kept.first, "e3")
        XCTAssertEqual(kept.last, "e14")
    }

    func testArchivedEntriesAreForgottenWhenTheOwnerChangesTheListGoesTheTerminalClosesTheConnectionDropsOrStagingIsOff() {
        func archiveOne() {
            store.ingest(listFrame([placed("a", "ls"), entry("b", "pwd")]))
            store.archive(terminalId: id, entryId: "a", auto: false)
            XCTAssertEqual(store.archivedEntries(for: id).count, 1)
        }
        archiveOne()
        store.ingest(listFrame([entry("b", "pwd")], owner: "another-focus"))
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "a new owner")

        archiveOne()
        store.ingest(listFrame([], state: .none))
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "the list went none")

        archiveOne()
        store.terminalClosed(id)
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "the terminal closed")

        archiveOne()
        store.connectionChanged(false)
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "the connection dropped")

        let (made, _) = makeStore()
        made.ingest(listFrame([placed("a", "ls")]))
        made.archive(terminalId: id, entryId: "a", auto: false)
        made.setGlobalEnabled(false)
        XCTAssertTrue(made.archivedEntries(for: id).isEmpty, "staging is off")
    }

    // MARK: Reading delay

    func testRestartingTheReadingDelayRestartsEveryEntryAndNotifies() {
        store.ingest(listFrame([entry("a", "ls"), entry("b", "pwd")]))
        clock += 10
        var calls = 0
        let token = store.observe(terminalId: id) { calls += 1 }
        store.restartReadingDelay(terminalId: id)
        XCTAssertEqual(shown("a"), clock)
        XCTAssertEqual(shown("b"), clock)
        XCTAssertEqual(calls, 1)
        store.restartReadingDelay(terminalId: "another")
        XCTAssertEqual(calls, 1, "no list, nothing to restart")
        _ = token
    }

    func testAChangeOfTheForegroundProgramRestartsTheReadingDelay() {
        store.ingest(listFrame([entry("a", "ls")]))
        let first = shown("a")
        clock += 5
        store.ingest(listFrame([entry("a", "ls")]))
        XCTAssertEqual(shown("a"), first, "nothing changed")
        clock += 5
        store.ingest(listFrame([entry("a", "ls")], foreground: "ssh"))
        XCTAssertEqual(shown("a"), clock, "ssh started: read it again")
    }

    // MARK: UI events

    func testJustChangedIsSentAtMostOncePerSecondPerTerminalAndCancelIsNeverThrottled() {
        store.reportUIEvent(.justChanged, terminalId: id)
        store.reportUIEvent(.justChanged, terminalId: id)
        XCTAssertEqual(frames, [.stagingUIEvent(terminalId: id, event: "just_changed")])
        store.reportUIEvent(.justChanged, terminalId: "another")
        XCTAssertEqual(frames.count, 2)
        clock += 1.1
        store.reportUIEvent(.justChanged, terminalId: id)
        XCTAssertEqual(frames.count, 3)
        store.reportUIEvent(.confirmCancelled, terminalId: id)
        store.reportUIEvent(.confirmCancelled, terminalId: id)
        XCTAssertEqual(frames.suffix(2), [.stagingUIEvent(terminalId: id, event: "confirm_cancelled"),
                                          .stagingUIEvent(terminalId: id, event: "confirm_cancelled")])
    }

    func testAConfirmedInsertIsReportedAsConfirmed() {
        store.reportInserted(terminalId: id, entryId: "a", bytes: 3, confirmed: true)
        XCTAssertEqual(frames, [.stagingInserted(terminalId: id, entryId: "a", bytes: 3, confirmed: true)])
    }

    // MARK: Auto-archive (memory only, off by default)

    func testAutoArchiveIsOffInAFreshProcessAndNoUserDefaultsWriteTurnsItOn() {
        XCTAssertFalse(TerminalStagingStore.autoArchiveEnabled)
        let (made, suite) = makeStore()
        for key in ["nostromo.terminal.autoArchive", "nostromo.terminal.stagingAutoArchive", "autoArchive", TerminalStagingStore.globalEnabledKey] {
            suite.set(true, forKey: key)
        }
        _ = made
        let (another, _) = makeStore(defaults: suite)
        _ = another
        XCTAssertFalse(TerminalStagingStore.autoArchiveEnabled, "it is never read from UserDefaults")
        another.ingest(listFrame([placed("a", "ls")]))
        another.notePlaced(terminalId: id, entryId: "a", command: "ls")
        XCTAssertFalse(another.hasPendingAutoArchive(terminalId: id), "off: an insert waits for nothing")
    }

    func testAutoArchiveArchivesAPlacedEntryOnlyAfterAPersonsEnterForTheIdenticalCommand() {
        TerminalStagingStore.setAutoArchive(true)
        addTeardownBlock { TerminalStagingStore.setAutoArchive(false) }
        store.ingest(listFrame([placed("a", "ls"), placed("b", "pwd", number: 2)]))
        store.notePlaced(terminalId: id, entryId: "a", command: "ls")
        XCTAssertTrue(store.hasPendingAutoArchive(terminalId: id))

        store.personTyped(terminalId: id, bytes: Array("ls".utf8))
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "no Enter yet")
        store.personTyped(terminalId: id, bytes: [0x0D])
        XCTAssertEqual(store.archivedEntries(for: id).map(\.entryId), ["a"])
        XCTAssertEqual(frames.last, .stagingRemove(terminalId: id, entryId: "a", archive: "auto"))
        XCTAssertFalse(store.hasPendingAutoArchive(terminalId: id))
    }

    func testCtrlUOrCtrlCBeforeTheEnterDropsThePendingEntries() {
        TerminalStagingStore.setAutoArchive(true)
        addTeardownBlock { TerminalStagingStore.setAutoArchive(false) }
        for key: UInt8 in [0x15, 0x03] {
            store.ingest(listFrame([placed("a", "ls")]))
            store.notePlaced(terminalId: id, entryId: "a", command: "ls")
            store.personTyped(terminalId: id, bytes: [key, 0x0D])
            XCTAssertTrue(store.archivedEntries(for: id).isEmpty, "\(key)")
            XCTAssertFalse(store.hasPendingAutoArchive(terminalId: id))
        }
    }

    func testAReplaceThatChangedTheCommandDropsTheAutoArchivePending() {
        TerminalStagingStore.setAutoArchive(true)
        addTeardownBlock { TerminalStagingStore.setAutoArchive(false) }
        store.ingest(listFrame([placed("a", "ls")]))
        store.notePlaced(terminalId: id, entryId: "a", command: "ls")
        store.ingest(listFrame([placed("a", "rm -rf /tmp/x")]))
        XCTAssertFalse(store.hasPendingAutoArchive(terminalId: id))
        store.personTyped(terminalId: id, bytes: [0x0D])
        XCTAssertTrue(store.archivedEntries(for: id).isEmpty)
    }
}
