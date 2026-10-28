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
    /// Work the store asked to run later (`schedule`), oldest first. Nothing runs until a test says so.
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var store: TerminalSessionStore!
    /// Sinks are held weakly by the store; keep them alive for the whole test.
    private var retained: [FakeTerminalSink] = []
    private var changes: [TerminalChange] = []
    private var subscription: AnyCancellable?

    override func setUp() {
        super.setUp()
        clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
        sent = []
        scheduled = []
        retained = []
        changes = []
        store = TerminalSessionStore(now: { [unowned self] in self.clock },
                                     schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
                                     transport: { [unowned self] in self.sent.append($0) })
        subscription = store.changes.sink { [unowned self] in self.changes.append($0) }
    }

    override func tearDown() {
        subscription = nil
        store = nil
        scheduled = []
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

    /// The terminal_input frames sent so far, as (bytes, autoReply), in the order they were sent.
    private var inputFrames: [(bytes: [UInt8], autoReply: Bool)] {
        sent.compactMap { message in
            if case .input(_, let bytes, let autoReply) = message { return (bytes: bytes, autoReply: autoReply) }
            return nil
        }
    }

    /// Run the oldest scheduled closure (a paste's next chunk coming due). False when none is waiting.
    @discardableResult
    private func runNextScheduled() -> Bool {
        guard !scheduled.isEmpty else { return false }
        scheduled.removeFirst().work()
        return true
    }

    /// Let every waiting chunk of a paste go out.
    private func drainScheduled() {
        var guardCount = 0
        while runNextScheduled() {
            guardCount += 1
            if guardCount > 1000 { return XCTFail("the store keeps scheduling work") }
        }
    }

    /// `count` distinct bytes (a repeating, non-periodic-looking pattern) so a reorder or a dropped
    /// chunk changes the result.
    private func pasteBytes(_ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 % 251) } }

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
        store.ingest(.terminalList(TerminalListFrame(terminals: [info("t1", pane: "terminal-a"), info("t2", pane: "terminal-b")])))

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
        XCTAssertEqual(store.driverWindow["t1"], "w-typing")
    }

    func testInputIsDroppedForAnEndedConnectingOrUnknownTerminal() {
        state(info("ended", pane: "p1", status: .ended))
        state(info("connecting", pane: "p2", status: .connecting))

        store.sendInput(terminalId: "ended", bytes: [0x61], fromWindow: "w1")
        store.sendInput(terminalId: "connecting", bytes: [0x61], fromWindow: "w1")
        store.sendInput(terminalId: "nope", bytes: [0x61], fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        XCTAssertNil(store.driverWindow["ended"])
    }

    func testNothingTypedPastedOrAutoRepliedReachesAConnectingTerminalUntilItIsRunning() {
        state(info(status: .connecting))
        let paste = pasteBytes(TerminalSessionStore.inputChunkBytes + 1)

        store.sendInput(terminalId: "t1", bytes: Array("ls\n".utf8), fromWindow: "w1")
        store.sendInput(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), fromWindow: "w1", autoReply: true)
        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        drainScheduled()

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        XCTAssertTrue(scheduled.isEmpty, "nothing may be queued for later either")
        XCTAssertNil(store.driverWindow["t1"], "a dropped keystroke does not make a window the driver")

        state(info(status: .running))

        store.sendInput(terminalId: "t1", bytes: Array("ls\n".utf8), fromWindow: "w1")
        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: Array("ls\n".utf8))])
        XCTAssertEqual(store.driverWindow["t1"], "w1")

        store.sendInput(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), fromWindow: "w1", autoReply: true)
        XCTAssertEqual(inputFrames.last?.bytes, Array("\u{1b}[1;1R".utf8))
        XCTAssertEqual(inputFrames.last?.autoReply, true)

        sent = []
        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        drainScheduled()
        XCTAssertEqual(inputFrames.flatMap { $0.bytes }, paste, "the same paste goes out once the shell is running")
    }

    func testEmptyInputIsNeverSent() {
        state(info())
        store.sendInput(terminalId: "t1", bytes: [], fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(store.driverWindow["t1"])
    }

    func testInputStopsOnceTheTerminalHasEnded() {
        state(info(status: .running))
        state(info(status: .ended))

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty)
    }

    // MARK: - Input: auto replies

    func testAnAutoReplyIsSentMarkedAndAnOrdinaryInputIsNot() {
        state(info())

        store.sendInput(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), fromWindow: "w1", autoReply: true)
        store.sendInput(terminalId: "t1", bytes: Array("ls\n".utf8), fromWindow: "w1")
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1", autoReply: false)

        XCTAssertEqual(sent, [
            .input(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), autoReply: true),
            .input(terminalId: "t1", bytes: Array("ls\n".utf8), autoReply: false),
            .input(terminalId: "t1", bytes: [0x61], autoReply: false),
        ])
        XCTAssertEqual(inputFrames.map { $0.autoReply }, [true, false, false])
    }

    func testAnAutoReplyDoesNotMakeItsWindowTheDriverButAKeystrokeDoes() {
        state(info())

        store.sendInput(terminalId: "t1", bytes: [0x72], fromWindow: "w-reply", autoReply: true)
        XCTAssertNil(store.driverWindow["t1"], "a reply is not a person at that window")

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w-typing")
        XCTAssertEqual(store.driverWindow["t1"], "w-typing")

        store.sendInput(terminalId: "t1", bytes: [0x72], fromWindow: "w-reply", autoReply: true)
        XCTAssertEqual(store.driverWindow["t1"], "w-typing", "a later reply from another window does not take it over")
    }

    func testAnAutoReplyIsStillDroppedForATerminalThatIsNotRunning() {
        state(info(status: .ended))
        store.sendInput(terminalId: "t1", bytes: [0x72], fromWindow: "w1", autoReply: true)
        store.sendInput(terminalId: "nope", bytes: [0x72], fromWindow: "w1", autoReply: true)
        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    // MARK: - Input: large pastes go out in ordered chunks

    func testAnInputUpToOneChunkIsOneFrameSentImmediately() {
        state(info())
        let exactly = pasteBytes(TerminalSessionStore.inputChunkBytes)

        store.sendInput(terminalId: "t1", bytes: exactly, fromWindow: "w1")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: exactly)])
        XCTAssertTrue(scheduled.isEmpty, "nothing waits behind a single frame")
    }

    func testAnInputOneByteOverTheChunkSizeGoesOutAsTwoFrames() {
        state(info())
        let bytes = pasteBytes(TerminalSessionStore.inputChunkBytes + 1)

        store.sendInput(terminalId: "t1", bytes: bytes, fromWindow: "w1")
        drainScheduled()

        let frames = inputFrames.map { $0.bytes }
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames.first?.count, TerminalSessionStore.inputChunkBytes)
        XCTAssertEqual(frames.last?.count, 1)
        XCTAssertEqual(frames.flatMap { $0 }, bytes)
    }

    func testAHundredKilobytePasteGoesOutAsOrderedChunksNoneOverTheLimit() {
        state(info())
        let paste = pasteBytes(100 * 1024)

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        drainScheduled()

        let frames = inputFrames
        XCTAssertGreaterThan(frames.count, 1)
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.bytes.count, TerminalSessionStore.inputChunkBytes)
            XCTAssertFalse(frame.bytes.isEmpty)
            XCTAssertFalse(frame.autoReply, "a paste is a person's")
        }
        XCTAssertEqual(frames.flatMap { $0.bytes }, paste, "the chunks joined in order are exactly the paste")
        XCTAssertEqual(sent.count, frames.count, "nothing but input frames went out")
    }

    func testOnlyTheFirstChunkGoesOutNowAndTheRestAreSpacedOutOneAtATime() {
        state(info())
        let paste = pasteBytes(100 * 1024)
        let expectedChunks = (paste.count + TerminalSessionStore.inputChunkBytes - 1) / TerminalSessionStore.inputChunkBytes

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")

        XCTAssertEqual(inputFrames.count, 1, "the first chunk is sent at once")
        XCTAssertEqual(inputFrames.first?.bytes, Array(paste.prefix(TerminalSessionStore.inputChunkBytes)))
        XCTAssertEqual(scheduled.count, 1, "the second chunk waits for its turn")
        XCTAssertEqual(scheduled.first?.delay, TerminalSessionStore.inputChunkInterval)

        for sentSoFar in 2...expectedChunks {
            XCTAssertTrue(runNextScheduled(), "chunk \(sentSoFar) should have been scheduled")
            XCTAssertEqual(inputFrames.count, sentSoFar, "one more chunk per scheduled run")
            if sentSoFar < expectedChunks {
                XCTAssertEqual(scheduled.count, 1)
                XCTAssertEqual(scheduled.first?.delay, TerminalSessionStore.inputChunkInterval,
                               "every gap is inputChunkInterval")
            }
        }
        XCTAssertTrue(scheduled.isEmpty, "nothing is scheduled after the last chunk")
        XCTAssertFalse(runNextScheduled())
        XCTAssertEqual(inputFrames.flatMap { $0.bytes }, paste)
    }

    func testAKeystrokeTypedDuringAPasteIsDeliveredAfterTheLastChunkNotBetweenChunks() {
        state(info())
        let paste = pasteBytes(100 * 1024)

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        XCTAssertEqual(inputFrames.count, 1)
        store.sendInput(terminalId: "t1", bytes: [0x71], fromWindow: "w2")
        XCTAssertEqual(inputFrames.count, 1, "the keystroke waits behind the paste")
        drainScheduled()

        let frames = inputFrames
        XCTAssertEqual(frames.last?.bytes, [0x71], "the keystroke is the last frame")
        XCTAssertEqual(frames.last?.autoReply, false)
        XCTAssertEqual(frames.dropLast().flatMap { $0.bytes }, paste, "the paste arrives whole and in order before it")
    }

    func testAnAutoReplyDuringAPasteIsAlsoDeliveredAfterTheLastChunk() {
        state(info())
        let paste = pasteBytes(100 * 1024)
        let reply = Array("\u{1b}[?1;2c".utf8)

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        store.sendInput(terminalId: "t1", bytes: reply, fromWindow: "w1", autoReply: true)
        XCTAssertEqual(inputFrames.count, 1, "the reply waits behind the paste")
        drainScheduled()

        let frames = inputFrames
        XCTAssertEqual(frames.last?.bytes, reply)
        XCTAssertEqual(frames.last?.autoReply, true, "it is still marked as a reply")
        XCTAssertEqual(frames.dropLast().flatMap { $0.bytes }, paste)
        XCTAssertTrue(frames.dropLast().allSatisfy { !$0.autoReply })
    }

    func testInputsDuringAPasteKeepTheOrderTheyWereMadeIn() {
        state(info())
        let paste = pasteBytes(70 * 1024)

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        store.sendInput(terminalId: "t1", bytes: [0x31], fromWindow: "w1")
        store.sendInput(terminalId: "t1", bytes: [0x32], fromWindow: "w1", autoReply: true)
        store.sendInput(terminalId: "t1", bytes: [0x33], fromWindow: "w1")
        drainScheduled()

        let tail = inputFrames.suffix(3).map { $0.bytes }
        XCTAssertEqual(tail, [[0x31], [0x32], [0x33]])
        XCTAssertEqual(inputFrames.dropLast(3).flatMap { $0.bytes }, paste)
    }

    func testAPasteForOneTerminalDoesNotHoldBackAnotherTerminal() {
        state(info("t1", pane: "terminal-a"))
        state(info("t2", pane: "terminal-b"))

        store.sendInput(terminalId: "t1", bytes: pasteBytes(100 * 1024), fromWindow: "w1")
        store.sendInput(terminalId: "t2", bytes: [0x71], fromWindow: "w1")

        XCTAssertEqual(sent.last, TerminalClientMessage.input(terminalId: "t2", bytes: [0x71]),
                       "typing into another terminal is not queued behind this paste")
    }

    func testInputGoesOutImmediatelyAgainOnceAPasteHasFinished() {
        state(info())
        store.sendInput(terminalId: "t1", bytes: pasteBytes(100 * 1024), fromWindow: "w1")
        drainScheduled()
        let before = sent.count

        store.sendInput(terminalId: "t1", bytes: [0x71], fromWindow: "w1")

        XCTAssertEqual(sent.count, before + 1)
        XCTAssertEqual(sent.last, TerminalClientMessage.input(terminalId: "t1", bytes: [0x71]))
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testTheRestOfAPasteIsNotSentOnceTheTerminalHasEnded() {
        state(info(status: .running))
        let paste = pasteBytes(100 * 1024)

        store.sendInput(terminalId: "t1", bytes: paste, fromWindow: "w1")
        XCTAssertEqual(inputFrames.count, 1)
        state(info(status: .ended))
        drainScheduled()

        XCTAssertEqual(inputFrames.count, 1, "no chunk goes to a terminal that ended: \(sent.count) frames")
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testTheRestOfAPasteIsNotSentOnceTheTerminalIsClosed() {
        state(info())
        store.sendInput(terminalId: "t1", bytes: pasteBytes(100 * 1024), fromWindow: "w1")
        store.ingest(.terminalClosed(TerminalClosedInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a",
                                                        label: "Terminal", kind: .local, reason: "user_closed",
                                                        exitCode: nil, target: nil)))
        drainScheduled()

        XCTAssertEqual(inputFrames.count, 1)
    }

    func testAnEndedTerminalsDroppedBacklogDoesNotLeakIntoItsRestart() {
        state(info("t-old", status: .running))
        store.sendInput(terminalId: "t-old", bytes: pasteBytes(100 * 1024), fromWindow: "w1")
        state(info("t-new", status: .running))       // restart: same pane, new id, the old one is forgotten
        drainScheduled()
        sent.removeAll()

        store.sendInput(terminalId: "t-new", bytes: [0x71], fromWindow: "w1")

        XCTAssertEqual(sent, [.input(terminalId: "t-new", bytes: [0x71])])
    }

    // MARK: - The local copy: no copy per frame, and a late view gets the newest bytes in order

    /// `count` lines of exactly 200 bytes each, "L00000:" then filler then "\n", as one stream, and the
    /// same lines one by one.
    private func numberedLines(_ count: Int) -> (stream: [UInt8], lines: [[UInt8]]) {
        var lines: [[UInt8]] = []
        for n in 0..<count {
            let head = "L" + String(format: "%05d", n) + ":"
            let body = String(repeating: "x", count: 200 - head.utf8.count - 1)
            lines.append(Array((head + body + "\n").utf8))
        }
        return (lines.flatMap { $0 }, lines)
    }

    func testStreamingMoreThanTheCapacityOfOutputCopiesNoBufferWhileOneViewIsBound() {
        attachedTerminal()
        let (stream, lines) = numberedLines(12_000)
        XCTAssertGreaterThan(stream.count, TerminalSessionStore.replayCapacity, "the fixture must overflow the copy")

        for line in lines { output(bytes: line) }

        XCTAssertEqual(store.replayBytesMaterialized, 0,
                       "taking a frame in must not copy the buffer (that made a stream O(n squared))")
    }

    func testALateViewAfterAHugeStreamGetsExactlyTheNewestBytesInOrderStartingAtALine() {
        let first = attachedTerminal()
        let (stream, lines) = numberedLines(12_000)
        for line in lines { output(bytes: line) }
        XCTAssertEqual(store.replayBytesMaterialized, 0)
        XCTAssertEqual(first.fedBytes, stream, "the live view saw every byte")

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        let fed = late.fedBytes
        XCTAssertFalse(fed.isEmpty)
        XCTAssertLessThanOrEqual(fed.count, TerminalSessionStore.replayCapacity)
        XCTAssertGreaterThan(fed.count, TerminalSessionStore.replayCapacity - 4096, "nearly the whole capacity is kept")
        XCTAssertTrue(fed.elementsEqual(stream.suffix(fed.count)),
                      "what the late view gets is the tail of the stream, unbroken and in order")
        XCTAssertEqual(stream[stream.count - fed.count - 1], 0x0A, "the copy starts on a whole line: the byte before it ended a line")
        XCTAssertEqual(fed.first, UInt8(ascii: "L"))
        XCTAssertEqual(fed.suffix(200), ArraySlice(lines[11_999]), "the newest line is last")
        XCTAssertEqual(store.replayBytesMaterialized, fed.count,
                       "the bytes copied out of the buffer are the ones the late view was given")
    }

    func testBytesOlderThanTheCapacityAreGoneFromALateViewAfterTheTrim() {
        attachedTerminal()
        let (_, lines) = numberedLines(12_000)
        for line in lines { output(bytes: line) }

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        let text = late.fedText
        XCTAssertFalse(text.contains("L00000:"), "the oldest line must have been dropped")
        XCTAssertFalse(text.contains("L00100:"))
        XCTAssertTrue(text.contains("L11999:"))
        XCTAssertTrue(text.contains("L11000:"), "recent lines are still there")
    }

    func testAnotherLateViewMaterialisesTheBufferAgainAndGetsTheSameBytes() {
        attachedTerminal()
        let (_, lines) = numberedLines(12_000)
        for line in lines { output(bytes: line) }
        let a = sink(window: "w2")
        store.register(a, tag: "core-1", paneId: "terminal-a")
        let b = sink(window: "w3")
        store.register(b, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(a.fedBytes, b.fedBytes)
        XCTAssertEqual(store.replayBytesMaterialized, a.fedBytes.count + b.fedBytes.count)
    }

    func testAStreamThatFitsIsGivenToALateViewWhole() {
        attachedTerminal()
        let (stream, lines) = numberedLines(100)
        for line in lines { output(bytes: line) }

        let late = sink(window: "w2")
        store.register(late, tag: "core-1", paneId: "terminal-a")

        XCTAssertEqual(late.fedBytes, stream)
        XCTAssertEqual(store.replayBytesMaterialized, stream.count)
    }

    // MARK: - Refused input notice

    func testOnlyARefusedInputForSizeOrBusyGetsTheOverlayNotice() {
        let notice = TerminalRefusedFrame.inputNotice
        XCTAssertFalse(notice.isEmpty)
        XCTAssertEqual(TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_too_large").overlayNotice, notice)
        XCTAssertEqual(TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_busy").overlayNotice, notice)
        XCTAssertEqual(TerminalRefusedFrame(op: "input", terminalId: nil, code: "terminal_input_busy").overlayNotice, notice)
    }

    func testOtherRefusalsGetNoOverlayNotice() {
        XCTAssertNil(TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_forbidden").overlayNotice)
        XCTAssertNil(TerminalRefusedFrame(op: "input", terminalId: "t1", code: "no_such_terminal").overlayNotice)
        XCTAssertNil(TerminalRefusedFrame(op: "open", terminalId: "t1", code: "terminal_input_too_large").overlayNotice,
                     "the code alone is not enough: it has to be a refused input")
        XCTAssertNil(TerminalRefusedFrame(op: "close", terminalId: "t1", code: "terminal_input_busy").overlayNotice)
        XCTAssertNil(TerminalRefusedFrame(op: "resize", terminalId: nil, code: "bad_size").overlayNotice)
    }

    func testTheOverlayNoticeIsFixedTextThatNeverContainsWhatWasRefused() {
        let secret = "CANARY-PASTE-9f3a1c"
        // The frame can only carry op, terminal and code; whatever a person pasted is not part of it.
        let a = TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_too_large")
        let b = TerminalRefusedFrame(op: "input", terminalId: "t-\(secret)", code: "terminal_input_busy")

        XCTAssertEqual(a.overlayNotice, b.overlayNotice, "the text does not vary with the frame")
        XCTAssertFalse(a.overlayNotice?.contains(secret) ?? true)
        XCTAssertFalse(b.overlayNotice?.contains(secret) ?? true, "not even a terminal id is echoed")
        XCTAssertFalse(TerminalRefusedFrame.inputNotice.contains("t1"))
    }

    func testARefusedInputStillReachesSubscribersSoThePaneCanShowTheNotice() {
        let refused = TerminalRefusedFrame(op: "input", terminalId: "t1", code: "terminal_input_too_large")
        store.ingest(.terminalRefused(refused))
        XCTAssertEqual(changes, [.refused(refused)])
        if case .refused(let frame)? = changes.first {
            XCTAssertEqual(frame.overlayNotice, TerminalRefusedFrame.inputNotice)
        } else {
            XCTFail("no refused change")
        }
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

    func testATerminalMissingFromTheListAndTheClosedListIsForgottenAndPublished() {
        state(info("t-lost", pane: "terminal-lost"))
        var changes: [TerminalChange] = []
        let cancel = store.changes.sink { changes.append($0) }
        defer { cancel.cancel() }

        store.ingest(.terminalList(TerminalListFrame(terminals: [info("t1", pane: "terminal-a")])))

        XCTAssertNil(store.terminals["t-lost"])
        XCTAssertTrue(changes.contains(.availability(daemonReachable: true)), "\(changes)")
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

    // MARK: - Agent follow (3c)

    func testInvitingAFollowerSendsTheInviteWithTheScreenChoice() {
        attachedTerminal()
        sent.removeAll()

        store.inviteFollow(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)
        store.inviteFollow(terminalId: "t1", followerTag: "cody-1", includeScreen: true)

        XCTAssertEqual(sent, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false),
                              .followInvite(terminalId: "t1", followerTag: "cody-1", includeScreen: true)])
    }

    func testStoppingAndResumingAFollowSendEachFrame() {
        attachedTerminal()
        sent.removeAll()

        store.stopFollow(terminalId: "t1")
        store.resumeFollow(terminalId: "t1")

        XCTAssertEqual(sent, [.followStop(terminalId: "t1"), .followResume(terminalId: "t1")])
    }

    func testSendingASelectionSendsItOnceToTheTargetWithItsTextVerbatim() {
        attachedTerminal()
        sent.removeAll()

        store.sendSelection(terminalId: "t1", targetTag: "claudia-1", text: "  error: boom\n")

        XCTAssertEqual(sent, [.sendSelection(terminalId: "t1", targetTag: "claudia-1", text: "  error: boom\n")])
    }

    func testAnEmptySelectionSendsNothing() {
        attachedTerminal()
        sent.removeAll()

        store.sendSelection(terminalId: "t1", targetTag: "claudia-1", text: "")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    func testNoFollowFrameIsSentWhileTheDaemonIsUnavailable() {
        attachedTerminal()
        store.connectionChanged(false)
        sent.removeAll()

        store.inviteFollow(terminalId: "t1", followerTag: "claudia-1", includeScreen: true)
        store.stopFollow(terminalId: "t1")
        store.resumeFollow(terminalId: "t1")
        store.sendSelection(terminalId: "t1", targetTag: "claudia-1", text: "boom")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    func testFollowFramesGoOutAgainOnceTheDaemonIsBack() {
        attachedTerminal()
        store.connectionChanged(false)
        store.connectionChanged(true)
        store.ingest(.terminalList(TerminalListFrame(terminals: [info()])))
        sent.removeAll()

        store.stopFollow(terminalId: "t1")

        XCTAssertEqual(sent, [.followStop(terminalId: "t1")])
    }

    func testAFrameThatIsNotATerminalFrameIsIgnored() {
        store.ingest(.unknown)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(sent.isEmpty)
    }
}

// MARK: - A remote shell closing (2c): the toast, and Reconnect

/// A remote shell that was running and closes says so in the window(s) showing its focus, with
/// Reconnect (a new request, so the confirm sheet appears again). A connection that never got past
/// `connecting` is a failure the failure sheet reports, so it gets no "closed" toast.
final class RemoteShellClosedToastTests: XCTestCase {

    private var store: TerminalSessionStore!
    private var remote: RemoteShellStore!
    private var sentToRemote: [RemoteShellClientMessage] = []
    private var toasts: [TerminalToast] = []
    private var subscription: AnyCancellable?

    private let target = TerminalTarget(project: "admin-portal", environment: "production",
                                        service: "scheduler", shellType: "shell")

    override func setUp() {
        super.setUp()
        sentToRemote = []
        toasts = []
        remote = RemoteShellStore(transport: { [unowned self] in self.sentToRemote.append($0) })
        store = TerminalSessionStore(remoteShells: remote)
        subscription = store.toasts.sink { [unowned self] in self.toasts.append($0) }
    }

    override func tearDown() {
        subscription = nil
        store = nil
        remote = nil
        super.tearDown()
    }

    private func ecsInfo(status: TerminalStatus) -> TerminalInfo {
        TerminalInfo(terminalId: "t9", tag: "core-1", paneId: "terminal-e", kind: .ecs, label: "production",
                     cwd: nil, target: target, status: status, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                     follower: nil, idleClosesAt: nil)
    }

    private func closed(kind: TerminalKind = .ecs, target: TerminalTarget? = nil, reason: String = "remote_exit",
                        exitCode: Int? = 0) -> TerminalClosedInfo {
        TerminalClosedInfo(terminalId: "t9", tag: "core-1", paneId: "terminal-e", label: "production",
                           kind: kind, reason: reason, exitCode: exitCode, target: target ?? self.target)
    }

    func testARunningRemoteShellThatClosesToastsItsFocusWithTheReasonAndAReconnectAction() throws {
        store.ingest(.terminalState(ecsInfo(status: .running)))

        store.ingest(.terminalClosed(closed()))

        let toast = try XCTUnwrap(toasts.first)
        XCTAssertEqual(toasts.count, 1)
        XCTAssertEqual(toast.tag, "core-1")
        XCTAssertEqual(toast.message, "production \u{00B7} admin-portal \u{00B7} scheduler shell closed: remote session ended, exit 0")
        XCTAssertEqual(toast.action?.title, "Reconnect")
    }

    func testReconnectAsksTheDaemonForTheSameTargetInTheSameFocusAndNothingElseHappensByItself() throws {
        store.ingest(.terminalState(ecsInfo(status: .running)))
        store.ingest(.terminalClosed(closed()))
        XCTAssertTrue(sentToRemote.isEmpty, "nothing reconnects until Reconnect is clicked")

        try XCTUnwrap(toasts.first?.action).handler()

        XCTAssertEqual(sentToRemote, [.open(tag: "core-1", target: target)])
        // A request to open, never an answer: the confirm sheet still has to be clicked through.
        XCTAssertFalse(sentToRemote.contains { if case .answer = $0 { return true } else { return false } })
    }

    func testAShellThatNeverGotPastConnectingIsAFailedConnectionNotAClosedShell() {
        store.ingest(.terminalState(ecsInfo(status: .connecting)))

        store.ingest(.terminalClosed(closed(reason: "sso_expired", exitCode: nil)))

        XCTAssertTrue(toasts.isEmpty, "the failure sheet reports it")
    }

    func testALocalTerminalClosingMakesNoRemoteShellToast() {
        store.ingest(.terminalClosed(closed(kind: .local, reason: "exited")))
        XCTAssertTrue(toasts.isEmpty)
    }

    func testARemoteShellThatClosedWhileTheDaemonWasStoppedStillToasts() {
        // `terminal_list.closed`: this app never saw it running, but it was.
        store.ingest(.terminalList(TerminalListFrame(terminals: [], closed: [closed(reason: "daemon_stopped", exitCode: nil)])))

        XCTAssertEqual(toasts.first?.message,
                       "production \u{00B7} admin-portal \u{00B7} scheduler shell closed: Nostromo daemon restarted")
    }
}
