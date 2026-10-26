import XCTest
import Combine

// `TerminalSessionStore`: what the daemon told this app about terminals, the views showing them,
// and the frames the app sends back. Views are fakes (`FakeTerminalSink`), the daemon connection is
// the `transport` closure, and time is a variable, so every behaviour here is exact and instant.
//
// Contract in brief:
//   * `terminal_attach` goes out for a terminal's first view, `terminal_detach` after its last;
//     a reconnect attaches again whatever still has a view.
//   * A later view starts from the bytes the first one has.
//   * Input only for a running terminal; resize once per distinct size; refusal reports rate limited.
//   * A terminal this app asked for takes the keyboard in the window that asked, once.

final class FakeTerminalSink: TerminalByteSink {
    enum Call: Equatable {
        case feed([UInt8])
        case reset
        case apply(cols: Int, rows: Int)
        case focus
    }

    let windowId: String
    var preferredSize: (cols: Int, rows: Int)?
    private(set) var calls: [Call] = []

    init(windowId: String = "w1", preferredSize: (cols: Int, rows: Int)? = nil) {
        self.windowId = windowId
        self.preferredSize = preferredSize
    }

    func feed(_ bytes: [UInt8]) { calls.append(.feed(bytes)) }
    func reset() { calls.append(.reset) }
    func apply(cols: Int, rows: Int) { calls.append(.apply(cols: cols, rows: rows)) }
    func takeKeyboardFocus() { calls.append(.focus) }

    func clear() { calls.removeAll() }
    var focusCount: Int { calls.filter { $0 == .focus }.count }
    /// Every byte fed, in order.
    var fedBytes: [UInt8] {
        calls.reduce(into: [UInt8]()) { out, call in if case .feed(let b) = call { out += b } }
    }
    var fedText: String { String(decoding: fedBytes, as: UTF8.self) }
}

final class TerminalSessionStoreTests: XCTestCase {

    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var sent: [TerminalClientMessage] = []
    private var store: TerminalSessionStore!
    /// Sinks are held weakly by the store; keep them alive for the whole test.
    private var retained: [FakeTerminalSink] = []
    private var changes: [TerminalChange] = []
    private var subscription: AnyCancellable?

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        sent = []
        retained = []
        changes = []
        store = TerminalSessionStore(now: { [unowned self] in self.clock },
                                     transport: { [unowned self] in self.sent.append($0) })
        subscription = store.changes.sink { [unowned self] in self.changes.append($0) }
    }

    override func tearDown() {
        subscription = nil
        store = nil
        retained = []
        super.tearDown()
    }

    // MARK: Helpers

    private func info(_ id: String = "t1", tag: String = "core-1", pane: String = "terminal-a",
                      kind: TerminalKind = .local, status: TerminalStatus = .running,
                      cols: Int = 80, rows: Int = 24, cwd: String? = "/tmp",
                      label: String = "Terminal", openedBy: String? = nil) -> TerminalInfo {
        TerminalInfo(terminalId: id, tag: tag, paneId: pane, kind: kind, label: label, cwd: cwd, target: nil,
                     status: status, exitCode: nil, endedReason: nil, cols: cols, rows: rows,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: openedBy,
                     follower: nil, idleClosesAt: nil)
    }

    private func sink(window: String = "w1", size: (cols: Int, rows: Int)? = nil) -> FakeTerminalSink {
        let s = FakeTerminalSink(windowId: window, preferredSize: size)
        retained.append(s)
        return s
    }

    private func state(_ i: TerminalInfo) { store.ingest(.terminalState(i)) }

    private func replay(_ text: String, id: String = "t1", cols: Int = 80, rows: Int = 24) {
        store.ingest(.terminalReplay(TerminalReplayFrame(terminalId: id, cols: cols, rows: rows,
                                                         bytes: Array(text.utf8))))
    }

    private func output(_ text: String, id: String = "t1") {
        output(bytes: Array(text.utf8), id: id)
    }

    private func output(bytes: [UInt8], id: String = "t1") {
        store.ingest(.terminalOutput(TerminalOutputFrame(terminalId: id, bytes: bytes)))
    }

    /// Connected, `t1` described, one view registered for its pane. Returns the view.
    @discardableResult
    private func attachedTerminal(window: String = "w1") -> FakeTerminalSink {
        store.connectionChanged(true)
        state(info())
        let s = sink(window: window)
        store.register(s, tag: "core-1", paneId: "terminal-a")
        return s
    }

    // MARK: - Attach and detach are reference counted

    func testTheFirstViewAttachesAndOnlyTheLastViewDetaches() {
        store.connectionChanged(true)
        state(info())
        let a = sink(), b = sink(window: "w2")

        store.register(a, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(sent, [.attach(terminalId: "t1")])

        store.register(b, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(sent, [.attach(terminalId: "t1")], "a second view of the same terminal does not attach again")

        store.unregister(a)
        XCTAssertEqual(sent, [.attach(terminalId: "t1")], "no detach while another view remains")

        store.unregister(b)
        XCTAssertEqual(sent, [.attach(terminalId: "t1"), .detach(terminalId: "t1")])
    }

    func testAViewRegisteredBeforeTheDaemonDescribesItsTerminalAttachesWhenItIsDescribed() {
        store.connectionChanged(true)
        let a = sink()
        store.register(a, tag: "core-1", paneId: "terminal-a")
        XCTAssertTrue(sent.isEmpty, "nothing to attach yet")

        state(info())
        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
    }

    func testAViewForAnotherPaneOrAnotherFocusDoesNotAttachThisTerminal() {
        store.connectionChanged(true)
        state(info(tag: "core-1", pane: "terminal-a"))
        store.register(sink(), tag: "core-1", paneId: "terminal-other")
        store.register(sink(), tag: "other-focus", paneId: "terminal-a")
        XCTAssertTrue(sent.isEmpty)
    }

    func testNothingIsAttachedWhileNotConnectedAndTheAttachGoesOutWhenTheConnectionComesUp() {
        state(info())
        store.register(sink(), tag: "core-1", paneId: "terminal-a")
        XCTAssertTrue(sent.isEmpty, "no connection, nothing sent")

        store.connectionChanged(true)
        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
    }

    func testAReconnectAttachesAgainEveryTerminalThatStillHasAView() {
        store.connectionChanged(true)
        state(info("t1", pane: "terminal-a"))
        state(info("t2", pane: "terminal-b"))
        store.register(sink(), tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(sent, [.attach(terminalId: "t1")])

        store.connectionChanged(false)
        sent.removeAll()
        store.connectionChanged(true)

        XCTAssertEqual(sent, [.attach(terminalId: "t1")], "t2 has no view, so it is not attached")
    }

    func testAViewThatLeftWhileDisconnectedIsNotAttachedAfterTheReconnect() {
        let a = attachedTerminal()
        store.connectionChanged(false)
        store.unregister(a)
        sent.removeAll()

        store.connectionChanged(true)
        XCTAssertTrue(sent.isEmpty)
    }

    func testNoDetachIsSentWhileTheConnectionIsDown() {
        let a = attachedTerminal()
        store.connectionChanged(false)
        sent.removeAll()

        store.unregister(a)
        XCTAssertTrue(sent.isEmpty)
    }

    func testNoDetachIsSentForATerminalTheDaemonNoLongerKnows() {
        let a = attachedTerminal()
        sent.removeAll()

        store.ingest(.terminalClosed(TerminalClosedInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a",
                                                        label: "Terminal", kind: .local, reason: "exited",
                                                        exitCode: 0, target: nil)))
        store.unregister(a)

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    func testRegisteringTheSameViewAgainReplacesItInsteadOfAddingASecondView() {
        let a = attachedTerminal()

        store.register(a, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(store.sinkCount(for: "t1"), 1)

        sent.removeAll()
        store.unregister(a)
        XCTAssertEqual(store.sinkCount(for: "t1"), 0)
        XCTAssertEqual(sent, [.detach(terminalId: "t1")], "one unregister releases it")
    }

    // MARK: - The first view's size goes out before the attach

    func testTheFirstViewsSizeIsSentBeforeTheAttachWhenItDiffersFromTheDaemons() {
        store.connectionChanged(true)
        state(info(cols: 80, rows: 24))
        store.register(sink(size: (cols: 120, rows: 40)), tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 120, rows: 40), .attach(terminalId: "t1")])
    }

    func testNoResizeIsSentWhenTheFirstViewsSizeEqualsTheDaemons() {
        store.connectionChanged(true)
        state(info(cols: 80, rows: 24))
        store.register(sink(size: (cols: 80, rows: 24)), tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
    }

    func testAViewThatHasNotBeenLaidOutYetSendsNoResize() {
        store.connectionChanged(true)
        state(info(cols: 80, rows: 24))
        store.register(sink(size: nil), tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
    }

    // MARK: - Late views are primed

    func testASecondViewOfAnAttachedTerminalStartsFromTheScreenTheFirstOneHas() {
        let a = attachedTerminal()
        replay("hello ", cols: 100, rows: 30)
        output("world")
        sent.removeAll()
        a.clear()

        let b = sink(window: "w2")
        store.register(b, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(b.calls, [.reset, .apply(cols: 100, rows: 30), .feed(Array("hello world".utf8))])
        XCTAssertTrue(sent.isEmpty, "the daemon is not asked again: \(sent)")
        XCTAssertTrue(a.calls.isEmpty, "the first view is not disturbed: \(a.calls)")
    }

    func testASecondViewBeforeAnyBytesGetsTheDaemonsSizeAndNothingToFeed() {
        attachedTerminal()
        let b = sink(window: "w2")
        store.register(b, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(b.calls, [.reset, .apply(cols: 80, rows: 24)])
    }

    // MARK: - Replay and output reach every view

    func testAReplayResetsResizesAndFeedsEveryView() {
        let a = attachedTerminal()
        let b = sink(window: "w2")
        store.register(b, tag: "core-1", paneId: "terminal-a")
        a.clear(); b.clear()

        replay("prompt$ ", cols: 132, rows: 43)

        for view in [a, b] {
            XCTAssertEqual(view.calls, [.reset, .apply(cols: 132, rows: 43), .feed(Array("prompt$ ".utf8))])
        }
    }

    func testOutputIsFedToEveryViewOfThatTerminalOnly() {
        let a = attachedTerminal()
        let b = sink(window: "w2")
        store.register(b, tag: "core-1", paneId: "terminal-a")
        state(info("t9", pane: "terminal-z"))
        let z = sink(window: "w3")
        store.register(z, tag: "core-1", paneId: "terminal-z")
        a.clear(); b.clear(); z.clear()

        output("abc", id: "t1")

        XCTAssertEqual(a.calls, [.feed(Array("abc".utf8))])
        XCTAssertEqual(b.calls, [.feed(Array("abc".utf8))])
        XCTAssertTrue(z.calls.isEmpty, "another terminal's view gets nothing: \(z.calls)")
    }

    func testOutputForATerminalNobodyIsViewingIsIgnored() {
        store.connectionChanged(true)
        output("stray", id: "t-unknown")
        let a = sink()
        state(info())
        store.register(a, tag: "core-1", paneId: "terminal-a")

        XCTAssertFalse(a.fedText.contains("stray"))
    }

    // MARK: - The local copy is bounded

    func testTheLocalCopyKeepsOnlyTheNewestBytes() {
        attachedTerminal()
        let total = TerminalSessionStore.replayCapacity + 1000
        let bytes = (0..<total).map { UInt8($0 % 251) }
        output(bytes: bytes)

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        let fed = late.fedBytes
        XCTAssertLessThanOrEqual(fed.count, TerminalSessionStore.replayCapacity)
        XCTAssertGreaterThan(fed.count, TerminalSessionStore.replayCapacity - 4096 - 1, "it should keep nearly the capacity")
        XCTAssertTrue(fed.suffix(1000).elementsEqual(bytes.suffix(1000)), "the newest bytes are the ones kept")
    }

    func testATrimmedCopyStartsAtALineBoundaryWhenOneIsNear() {
        attachedTerminal()
        let total = TerminalSessionStore.replayCapacity + 500
        var bytes = [UInt8](repeating: 0x41, count: total)
        bytes[600] = 0x0A                 // 100 bytes into what survives the cut
        bytes[601] = 0x42                 // the first byte of the next line
        output(bytes: bytes)

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(late.fedBytes.first, 0x42, "the copy starts on a whole line, not mid-line")
        XCTAssertLessThanOrEqual(late.fedBytes.count, TerminalSessionStore.replayCapacity)
    }

    func testAReplayLargerThanTheCapacityIsAlsoBoundedForLateViews() {
        attachedTerminal()
        let total = TerminalSessionStore.replayCapacity + 100
        let bytes = (0..<total).map { UInt8($0 % 251) }
        store.ingest(.terminalReplay(TerminalReplayFrame(terminalId: "t1", cols: 80, rows: 24, bytes: bytes)))

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        XCTAssertLessThanOrEqual(late.fedBytes.count, TerminalSessionStore.replayCapacity)
        XCTAssertTrue(late.fedBytes.suffix(100).elementsEqual(bytes.suffix(100)))
    }

    func testAReplayReplacesTheLocalCopy() {
        attachedTerminal()
        output("old screen ")
        replay("fresh")

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(late.fedText, "fresh")
    }

    // MARK: - Input

    func testInputGoesToARunningTerminalAndRemembersTheWindowThatTypedIt() {
        state(info(status: .running))

        store.sendInput(terminalId: "t1", bytes: Array("ls\n".utf8), fromWindow: "w-typing")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: Array("ls\n".utf8))])
        XCTAssertEqual(store.lastInputWindow["t1"], "w-typing")
    }

    func testInputIsDroppedForAnEndedConnectingOrUnknownTerminal() {
        state(info("ended", pane: "p1", status: .ended))
        state(info("connecting", pane: "p2", status: .connecting))

        store.sendInput(terminalId: "ended", bytes: [0x61], fromWindow: "w1")
        store.sendInput(terminalId: "connecting", bytes: [0x61], fromWindow: "w1")
        store.sendInput(terminalId: "nope", bytes: [0x61], fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        XCTAssertNil(store.lastInputWindow["ended"])
    }

    func testEmptyInputIsNeverSent() {
        state(info())
        store.sendInput(terminalId: "t1", bytes: [], fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(store.lastInputWindow["t1"])
    }

    func testInputStopsOnceTheTerminalHasEnded() {
        state(info(status: .running))
        state(info(status: .ended))

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Resize

    func testAResizeIsSentOncePerDistinctSize() {
        state(info(cols: 80, rows: 24))

        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 90, rows: 30, fromWindow: "w1")

        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 100, rows: 30),
                              .resize(terminalId: "t1", cols: 90, rows: 30)])
    }

    func testAResizeToTheSizeTheDaemonAlreadyHasIsNotSent() {
        state(info(cols: 80, rows: 24))
        store.resize(terminalId: "t1", cols: 80, rows: 24, fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)
    }

    func testAResizeToTheSizeOfTheLastReplayIsNotSent() {
        state(info(cols: 80, rows: 24))
        replay("x", cols: 120, rows: 40)

        store.resize(terminalId: "t1", cols: 120, rows: 40, fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)

        store.resize(terminalId: "t1", cols: 80, rows: 24, fromWindow: "w1")
        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 80, rows: 24)],
                       "going back to another size is a real change")
    }

    func testAStateThatChangesTheDaemonsSizeUpdatesWhatCountsAsUnchanged() {
        state(info(cols: 80, rows: 24))
        state(info(cols: 100, rows: 50))

        store.resize(terminalId: "t1", cols: 100, rows: 50, fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)
    }

    func testDegenerateOrUnknownResizesAreNotSent() {
        state(info())
        store.resize(terminalId: "t1", cols: 0, rows: 24, fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 80, rows: 0, fromWindow: "w1")
        store.resize(terminalId: "nope", cols: 100, rows: 30, fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Close and restart

    func testCloseAndRestartGoToTheDaemon() {
        state(info())
        store.close(terminalId: "t1")
        store.restart(terminalId: "t1")
        XCTAssertEqual(sent, [.close(terminalId: "t1"), .restart(terminalId: "t1")])
    }

    // MARK: - Refusal reports

    func testARefusalIsReportedAsAppControl() {
        store.reportRefusal(terminalId: "t1", op: .input)
        XCTAssertEqual(sent, [.refusalReport(terminalId: "t1", op: .input, channel: "app_control")])
    }

    func testRefusalReportsAreLimitedToOnePerSecondPerTerminalAndOp() {
        store.reportRefusal(terminalId: "t1", op: .input)
        clock.addTimeInterval(0.5)
        store.reportRefusal(terminalId: "t1", op: .input)
        XCTAssertEqual(sent.count, 1, "a second report inside the interval is dropped")

        clock.addTimeInterval(0.6)
        store.reportRefusal(terminalId: "t1", op: .input)
        XCTAssertEqual(sent.count, 2, "after the interval it goes out again")
    }

    func testTheIntervalIsMeasuredFromTheLastReportThatWasSent() {
        store.reportRefusal(terminalId: "t1", op: .input)
        clock.addTimeInterval(0.7)
        store.reportRefusal(terminalId: "t1", op: .input)         // dropped
        clock.addTimeInterval(0.7)                                // 1.4 s after the one that was sent
        store.reportRefusal(terminalId: "t1", op: .input)
        XCTAssertEqual(sent.count, 2)
    }

    func testDifferentOpsAndDifferentTerminalsAreNotLimitedByEachOther() {
        store.reportRefusal(terminalId: "t1", op: .input)
        store.reportRefusal(terminalId: "t1", op: .close)
        store.reportRefusal(terminalId: "t2", op: .input)
        store.reportRefusal(terminalId: nil, op: .input)
        XCTAssertEqual(sent.count, 4)
    }

    func testTheRefusalIntervalIsOneSecond() {
        XCTAssertEqual(TerminalSessionStore.refusalReportInterval, 1)
    }

    // MARK: - Keyboard focus for a terminal this window opened

    func testATerminalThisWindowAskedForTakesTheKeyboardInThatWindowOnly() {
        store.connectionChanged(true)
        let mine = sink(window: "w-mine")
        let other = sink(window: "w-other")
        store.register(mine, tag: "core-1", paneId: "terminal-a")
        store.register(other, tag: "core-1", paneId: "terminal-a")

        store.expectKeyboardFocus(clientRequestId: "req-1", windowId: "w-mine")
        state(info(openedBy: "req-1"))

        XCTAssertEqual(mine.focusCount, 1)
        XCTAssertEqual(other.focusCount, 0)
    }

    func testTheKeyboardIsTakenExactlyOnce() {
        let mine = sink(window: "w-mine")
        store.connectionChanged(true)
        store.register(mine, tag: "core-1", paneId: "terminal-a")
        store.expectKeyboardFocus(clientRequestId: "req-1", windowId: "w-mine")

        state(info(openedBy: "req-1"))
        state(info(cols: 100, openedBy: "req-1"))
        state(info(cols: 110, openedBy: "req-1"))

        XCTAssertEqual(mine.focusCount, 1)
    }

    func testAClaimWhoseViewRegistersLaterIsDeliveredWhenTheViewRegisters() {
        store.connectionChanged(true)
        store.expectKeyboardFocus(clientRequestId: "req-1", windowId: "w-mine")
        state(info(openedBy: "req-1"))

        let elsewhere = sink(window: "w-other")
        store.register(elsewhere, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(elsewhere.focusCount, 0, "another window's view does not collect the claim")

        clock.addTimeInterval(TerminalSessionStore.focusClaimLifetime - 1)
        let mine = sink(window: "w-mine")
        store.register(mine, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(mine.focusCount, 1)
        XCTAssertEqual(elsewhere.focusCount, 0)
    }

    func testAClaimExpiresAfterItsLifetime() {
        store.connectionChanged(true)
        store.expectKeyboardFocus(clientRequestId: "req-1", windowId: "w-mine")
        state(info(openedBy: "req-1"))

        clock.addTimeInterval(TerminalSessionStore.focusClaimLifetime + 1)
        let mine = sink(window: "w-mine")
        store.register(mine, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(mine.focusCount, 0, "a view that shows up long after the request does not grab the keyboard")
    }

    func testATerminalWithNoMatchingTokenNeverTakesFocus() {
        store.connectionChanged(true)
        let a = sink(window: "w1")
        store.register(a, tag: "core-1", paneId: "terminal-a")
        store.expectKeyboardFocus(clientRequestId: "req-mine", windowId: "w1")

        state(info("t-agent", openedBy: "req-from-an-agent"))
        XCTAssertEqual(a.focusCount, 0)

        state(info("t-agent", openedBy: nil))
        XCTAssertEqual(a.focusCount, 0)
    }

    func testATokenForAnotherRequestIsNotSpentByAnUnrelatedTerminal() {
        store.connectionChanged(true)
        let a = sink(window: "w1")
        store.register(a, tag: "core-1", paneId: "terminal-a")
        store.expectKeyboardFocus(clientRequestId: "req-1", windowId: "w1")

        state(info(openedBy: "someone-else"))
        XCTAssertEqual(a.focusCount, 0)

        state(info(openedBy: "req-1"))
        XCTAssertEqual(a.focusCount, 1)
    }

    // MARK: - Restart and close

    func testARestartRebindsTheViewToTheNewTerminalAndForgetsTheOldOne() {
        store.connectionChanged(true)
        state(info("t-old"))
        let a = sink()
        store.register(a, tag: "core-1", paneId: "terminal-a")
        sent.removeAll()
        a.clear()

        state(info("t-new", status: .running))

        XCTAssertEqual(sent, [.attach(terminalId: "t-new")])
        XCTAssertNil(store.terminals["t-old"])
        XCTAssertEqual(store.info(forPane: "terminal-a", tag: "core-1")?.terminalId, "t-new")

        output("stale", id: "t-old")
        output("fresh", id: "t-new")
        XCTAssertEqual(a.fedText, "fresh")
    }

    func testClosingATerminalForgetsIt() {
        let a = attachedTerminal()
        a.clear()
        sent.removeAll()

        store.ingest(.terminalClosed(TerminalClosedInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a",
                                                        label: "Terminal", kind: .local, reason: "user_closed",
                                                        exitCode: nil, target: nil)))

        XCTAssertNil(store.terminals["t1"])
        XCTAssertNil(store.info(forPane: "terminal-a", tag: "core-1"))
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")
        output("late", id: "t1")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(a.calls.isEmpty, "\(a.calls)")
    }

    func testATerminalListDescribesEveryTerminalAndForgetsTheClosedOnes() {
        state(info("t-gone", pane: "terminal-gone"))
        let closed = TerminalClosedInfo(terminalId: "t-gone", tag: "core-1", paneId: "terminal-gone",
                                        label: "Terminal", kind: .ecs, reason: "daemon_stopped",
                                        exitCode: nil, target: nil)

        store.ingest(.terminalList(TerminalListFrame(terminals: [info("t1", pane: "terminal-a"),
                                                                 info("t2", pane: "terminal-b")],
                                                     closed: [closed])))

        XCTAssertNotNil(store.terminals["t1"])
        XCTAssertNotNil(store.terminals["t2"])
        XCTAssertNil(store.terminals["t-gone"])
    }

    func testAListedTerminalIsAttachedToItsViewLikeAStateFrame() {
        store.connectionChanged(true)
        store.register(sink(), tag: "core-1", paneId: "terminal-a")

        store.ingest(.terminalList(TerminalListFrame(terminals: [info()])))

        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
    }

    // MARK: - Queries

    func testInfoForPaneNeedsBothThePaneAndTheFocus() {
        state(info("t1", tag: "core-1", pane: "terminal-a"))
        state(info("t2", tag: "core-2", pane: "terminal-a"))

        XCTAssertEqual(store.info(forPane: "terminal-a", tag: "core-1")?.terminalId, "t1")
        XCTAssertEqual(store.info(forPane: "terminal-a", tag: "core-2")?.terminalId, "t2")
        XCTAssertNil(store.info(forPane: "terminal-b", tag: "core-1"))
        XCTAssertNil(store.info(forPane: "terminal-a", tag: "core-3"))
    }

    func testSinkCountCountsLiveViewsOfATerminal() {
        let a = attachedTerminal()
        XCTAssertEqual(store.sinkCount(for: "t1"), 1)
        let b = sink(window: "w2")
        store.register(b, tag: "core-1", paneId: "terminal-a")
        XCTAssertEqual(store.sinkCount(for: "t1"), 2)
        store.unregister(a)
        XCTAssertEqual(store.sinkCount(for: "t1"), 1)
        XCTAssertEqual(store.sinkCount(for: "other"), 0)
    }

    // MARK: - Header title

    private let home = "/Users/hammer"

    func testALocalTerminalsHeaderIsTheShellAndTheDirectoryUnderHome() {
        let t = info(cwd: "/Users/hammer/Code/nostromo")
        XCTAssertEqual(t.headerTitle(home: home, shell: "/bin/zsh"), "zsh: ~/Code/nostromo")
    }

    func testTheHomeDirectoryItselfIsATilde() {
        XCTAssertEqual(info(cwd: home).headerTitle(home: home, shell: "/bin/zsh"), "zsh: ~")
    }

    func testADirectoryOutsideHomeIsShownAbsolute() {
        XCTAssertEqual(info(cwd: "/tmp/work").headerTitle(home: home, shell: "/bin/zsh"), "zsh: /tmp/work")
    }

    func testASiblingOfHomeWithTheSamePrefixIsNotUnderHome() {
        XCTAssertEqual(info(cwd: "/Users/hammerhead/x").headerTitle(home: home, shell: "/bin/zsh"),
                       "zsh: /Users/hammerhead/x")
    }

    func testARemoteTerminalsHeaderIsItsOwnLabel() {
        let t = info(kind: .ecs, cwd: "/srv/app", label: "admin-portal / production / web")
        XCTAssertEqual(t.headerTitle(home: home, shell: "/bin/zsh"), "admin-portal / production / web")
    }

    func testATerminalWithoutADirectoryUsesItsLabel() {
        XCTAssertEqual(info(cwd: nil, label: "Terminal").headerTitle(home: home, shell: "/bin/zsh"), "Terminal")
        XCTAssertEqual(info(cwd: "", label: "Terminal").headerTitle(home: home, shell: "/bin/zsh"), "Terminal")
    }

    func testWithoutAShellTheLabelStandsInForItsName() {
        let t = info(cwd: "/Users/hammer/Code", label: "Terminal")
        XCTAssertEqual(t.headerTitle(home: home, shell: nil), "Terminal: ~/Code")
        XCTAssertEqual(t.headerTitle(home: home, shell: ""), "Terminal: ~/Code")
    }

    func testTheShellIsShownByItsBaseName() {
        let t = info(cwd: "/tmp")
        XCTAssertEqual(t.headerTitle(home: home, shell: "/opt/homebrew/bin/fish"), "fish: /tmp")
    }

    // MARK: - Changes

    func testChangesAnnounceStateClosedAndRefusedFrames() {
        let i = info()
        let closed = TerminalClosedInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a", label: "Terminal",
                                        kind: .local, reason: "exited", exitCode: 0, target: nil)
        let refused = TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_forbidden")

        store.ingest(.terminalState(i))
        store.ingest(.terminalClosed(closed))
        store.ingest(.terminalRefused(refused))

        XCTAssertEqual(changes, [.info(i), .closed(closed), .refused(refused)])
    }

    func testAFrameThatIsNotATerminalFrameIsIgnored() {
        store.ingest(.unknown)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }
}
