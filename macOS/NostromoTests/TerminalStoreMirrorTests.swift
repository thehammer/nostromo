import XCTest
import Combine

// `TerminalSessionStore`, slice 1e: one window drives a terminal's size, every other window mirrors it,
// and a daemon that went away makes its terminals unavailable until the daemon lists them again.
//
// Contract in brief:
//   * The effective driver of a terminal is the window that last typed (or clicked) while its view is
//     still alive, else the window of the earliest registered live view.
//   * Only the driver's resize reaches the daemon; mirrors are told the daemon's size instead.
//   * A window that takes over sends its own size first, then its input.
//   * After the daemon connection drops, nothing is sent for those terminals until a terminal list
//     arrives; that list is the truth (ended, gone, or still running and re-attached).

/// A view that records everything the store tells it, including its role.
final class MirrorSink: TerminalByteSink {
    enum Call: Equatable {
        case feed([UInt8])
        case reset
        case apply(cols: Int, rows: Int)
        case focus
        case setDriver(Bool)
    }

    let windowId: String
    var preferredSize: (cols: Int, rows: Int)?
    private(set) var calls: [Call] = []

    init(windowId: String, preferredSize: (cols: Int, rows: Int)? = nil) {
        self.windowId = windowId
        self.preferredSize = preferredSize
    }

    func feed(_ bytes: [UInt8]) { calls.append(.feed(bytes)) }
    func reset() { calls.append(.reset) }
    func apply(cols: Int, rows: Int) { calls.append(.apply(cols: cols, rows: rows)) }
    func takeKeyboardFocus() { calls.append(.focus) }
    func setDriver(_ isDriver: Bool) { calls.append(.setDriver(isDriver)) }

    func clear() { calls.removeAll() }
    /// Every role it was told, in order.
    var roles: [Bool] { calls.compactMap { if case .setDriver(let v) = $0 { return v } else { return nil } } }
    /// Every size it was told to apply, in order.
    var applies: [Call] { calls.filter { if case .apply = $0 { return true } else { return false } } }
}

final class TerminalStoreMirrorTests: XCTestCase {

    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var sent: [TerminalClientMessage] = []
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var store: TerminalSessionStore!
    private var retained: [MirrorSink] = []
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
                      cols: Int = 80, rows: Int = 24, endedReason: String? = nil) -> TerminalInfo {
        TerminalInfo(terminalId: id, tag: tag, paneId: pane, kind: kind, label: "Terminal", cwd: "/tmp", target: nil,
                     status: status, exitCode: nil, endedReason: endedReason, cols: cols, rows: rows,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                     follower: nil, idleClosesAt: nil)
    }

    private func state(_ i: TerminalInfo) { store.ingest(.terminalState(i)) }

    /// A view in `window` for the pane of `t1` (or another pane), registered with the store.
    @discardableResult
    private func view(_ window: String, size: (cols: Int, rows: Int)? = nil, pane: String = "terminal-a") -> MirrorSink {
        let s = MirrorSink(windowId: window, preferredSize: size)
        retained.append(s)
        store.register(s, tag: "core-1", paneId: pane)
        return s
    }

    /// Connected, `t1` (80x24, running) described. Nothing registered yet.
    private func connectedTerminal() {
        store.connectionChanged(true)
        state(info())
    }

    private func replay(_ text: String, cols: Int, rows: Int) {
        store.ingest(.terminalReplay(TerminalReplayFrame(terminalId: "t1", cols: cols, rows: rows,
                                                         bytes: Array(text.utf8))))
    }

    private func availabilityChanges(_ reachable: Bool) -> Int {
        changes.filter { $0 == .availability(daemonReachable: reachable) }.count
    }

    // MARK: - Who drives

    func testTheFirstWindowToShowATerminalIsItsDriverAndTheNextOnesAreMirrors() {
        connectedTerminal()
        let a = view("w1"), b = view("w2")

        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w1"))
        XCTAssertFalse(store.isDriver(terminalId: "t1", windowId: "w2"))
        XCTAssertEqual(a.roles, [true])
        XCTAssertEqual(b.roles, [false])
    }

    func testADriverClaimedByAWindowThatHasNoViewDoesNotCount() {
        connectedTerminal()
        view("w1"); view("w2")

        store.claimDriver(terminalId: "t1", fromWindow: "w-gone")

        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w1"), "falls back to the earliest live view")
        XCTAssertFalse(store.isDriver(terminalId: "t1", windowId: "w-gone"))
    }

    // MARK: - Resize is the driver's alone

    func testAResizeFromAMirrorWindowIsDroppedAndDoesNotChangeTheKnownSize() {
        connectedTerminal()
        view("w1"); view("w2")
        sent.removeAll()

        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w2")
        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")

        // The mirror's size was not remembered as the daemon's: the driver asking for the daemon's
        // real size is still "unchanged", and asking for the mirror's size is a real change.
        store.resize(terminalId: "t1", cols: 80, rows: 24, fromWindow: "w1")
        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 100, rows: 30)])
    }

    func testAResizeFromTheDriverWindowIsForwardedAndNotRepeated() {
        connectedTerminal()
        view("w1"); view("w2")
        sent.removeAll()

        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")

        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 100, rows: 30)])
    }

    func testAMirrorViewNeverSendsItsSizeWhenItRegisters() {
        connectedTerminal()
        view("w1", size: (cols: 100, rows: 30))
        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 100, rows: 30), .attach(terminalId: "t1")])
        sent.removeAll()

        view("w2", size: (cols: 150, rows: 50))

        XCTAssertTrue(sent.isEmpty, "a second window shows the driver's size; it sends nothing: \(sent)")
    }

    // MARK: - Taking over: typing or clicking

    func testInputFromAMirrorWindowMakesItTheDriverAndSendsItsSizeBeforeTheInput() {
        connectedTerminal()
        view("w1"); view("w2", size: (cols: 120, rows: 40))
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: Array("ls\n".utf8), fromWindow: "w2")

        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 120, rows: 40),
                              .input(terminalId: "t1", bytes: Array("ls\n".utf8))])
        XCTAssertEqual(store.driverWindow["t1"], "w2")
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"))
        XCTAssertFalse(store.isDriver(terminalId: "t1", windowId: "w1"))
    }

    func testTheNewDriverIsToldItDrivesAndTheOldDriverIsToldItMirrorsAtTheNewSize() {
        connectedTerminal()
        let a = view("w1"), b = view("w2", size: (cols: 120, rows: 40))
        a.clear(); b.clear()

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w2")

        XCTAssertEqual(b.roles, [true])
        XCTAssertEqual(a.roles, [false])
        XCTAssertEqual(a.applies, [.apply(cols: 120, rows: 40)], "the old driver now follows the new size")
        XCTAssertTrue(b.applies.isEmpty, "the new driver already is that size: \(b.calls)")
    }

    func testTypingAgainInTheDriverWindowSendsNoExtraResizeAndNoNewRoles() {
        connectedTerminal()
        let a = view("w1", size: (cols: 100, rows: 30)), b = view("w2", size: (cols: 120, rows: 40))
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w2")
        a.clear(); b.clear(); sent.removeAll()
        b.preferredSize = (cols: 90, rows: 20)   // the window is mid-resize; only its resize events speak for it

        store.sendInput(terminalId: "t1", bytes: [0x62], fromWindow: "w2")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: [0x62])])
        XCTAssertTrue(a.roles.isEmpty && b.roles.isEmpty, "unchanged roles are not re-sent")
    }

    func testAnAutoReplyFromAMirrorWindowIsDroppedAndNeitherTakesOverNorSendsASize() {
        connectedTerminal()
        let a = view("w1"), b = view("w2", size: (cols: 120, rows: 40))
        a.clear(); b.clear(); sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), fromWindow: "w2", autoReply: true)

        XCTAssertEqual(sent, [])
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w1"))
        XCTAssertTrue(a.roles.isEmpty && b.roles.isEmpty)
    }

    func testAnAutoReplyFromTheDriverIsForwarded() {
        connectedTerminal()
        view("w1"); view("w2", size: (cols: 120, rows: 40))
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), fromWindow: "w1", autoReply: true)

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: Array("\u{1b}[1;1R".utf8), autoReply: true)])
    }

    func testAPromotedMirrorsRepliesAreForwardedAndTheOldDriversAreNot() {
        connectedTerminal()
        view("w1"); view("w2", size: (cols: 120, rows: 40))
        store.claimDriver(terminalId: "t1", fromWindow: "w2")
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: [0x52], fromWindow: "w1", autoReply: true)
        XCTAssertEqual(sent, [])
        store.sendInput(terminalId: "t1", bytes: [0x52], fromWindow: "w2", autoReply: true)
        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: [0x52], autoReply: true)])
    }

    func testAMirrorWithNoSizeYetTakesOverWithoutSendingAResize() {
        connectedTerminal()
        view("w1"); view("w2", size: nil)
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w2")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: [0x61])])
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"))
    }

    func testAMirrorWhoseSizeEqualsTheDaemonsTakesOverWithoutSendingAResize() {
        connectedTerminal()
        view("w1"); view("w2", size: (cols: 80, rows: 24))
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w2")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: [0x61])])
    }

    func testClickingAMirrorWindowMakesItTheDriverAndSendsItsSizeButNoInput() {
        connectedTerminal()
        let a = view("w1"), b = view("w2", size: (cols: 120, rows: 40))
        a.clear(); b.clear(); sent.removeAll()

        store.claimDriver(terminalId: "t1", fromWindow: "w2")

        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 120, rows: 40)])
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"))
        XCTAssertEqual(b.roles, [true])
        XCTAssertEqual(a.roles, [false])
        XCTAssertEqual(a.applies, [.apply(cols: 120, rows: 40)])
    }

    func testClickingTheWindowThatAlreadyDrivesChangesNothing() {
        connectedTerminal()
        let a = view("w1", size: (cols: 100, rows: 30)), b = view("w2")
        a.clear(); b.clear(); sent.removeAll()

        store.claimDriver(terminalId: "t1", fromWindow: "w1")
        store.claimDriver(terminalId: "t1", fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        XCTAssertTrue(a.roles.isEmpty && b.roles.isEmpty)
    }

    func testAnEndedTerminalCanStillBeClaimedByClickButStillDropsInput() {
        store.connectionChanged(true)
        state(info(status: .ended))
        view("w1"); view("w2")
        sent.removeAll()

        store.claimDriver(terminalId: "t1", fromWindow: "w2")
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"))

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")
        XCTAssertFalse(sent.contains { if case .input = $0 { return true } else { return false } }, "sent: \(sent)")
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"), "dropped input does not take over")
    }

    func testRolesAreSentToAViewOnlyWhenTheyChange() {
        connectedTerminal()
        let a = view("w1"), b = view("w2")

        store.claimDriver(terminalId: "t1", fromWindow: "w2")
        store.claimDriver(terminalId: "t1", fromWindow: "w2")
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w2")
        store.claimDriver(terminalId: "t1", fromWindow: "w1")

        XCTAssertEqual(a.roles, [true, false, true])
        XCTAssertEqual(b.roles, [false, true, false])
    }

    // MARK: - Mirrors follow the daemon's size

    func testAStateThatChangesTheSizeResizesMirrorsButNotTheDriver() {
        connectedTerminal()
        let a = view("w1"), b = view("w2"), c = view("w3")
        a.clear(); b.clear(); c.clear()

        state(info(cols: 100, rows: 50))

        XCTAssertTrue(a.applies.isEmpty, "the driver sized the terminal itself: \(a.calls)")
        XCTAssertEqual(b.applies, [.apply(cols: 100, rows: 50)])
        XCTAssertEqual(c.applies, [.apply(cols: 100, rows: 50)])
    }

    func testAStateWithTheSameSizeAppliesNothingToAnyView() {
        connectedTerminal()
        let a = view("w1"), b = view("w2")
        a.clear(); b.clear()

        state(info(cols: 80, rows: 24))

        XCTAssertTrue(a.applies.isEmpty)
        XCTAssertTrue(b.applies.isEmpty)
    }

    func testAReplayStillResetsAppliesAndFeedsEveryViewDriverAndMirrorAlike() {
        connectedTerminal()
        let a = view("w1"), b = view("w2")
        a.clear(); b.clear()

        replay("prompt$ ", cols: 132, rows: 43)

        for v in [a, b] {
            XCTAssertEqual(v.calls, [.reset, .apply(cols: 132, rows: 43), .feed(Array("prompt$ ".utf8))])
        }
    }

    // MARK: - The driver leaves

    func testWhenTheDriversViewLeavesTheEarliestRemainingViewDrivesAndSendsItsSize() {
        connectedTerminal()
        let a = view("w1"), b = view("w2", size: (cols: 120, rows: 40)), c = view("w3", size: (cols: 150, rows: 50))
        b.clear(); c.clear(); sent.removeAll()

        store.unregister(a)

        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w2"))
        XCTAssertFalse(store.isDriver(terminalId: "t1", windowId: "w3"))
        XCTAssertEqual(b.roles, [true])
        XCTAssertTrue(c.roles.isEmpty, "w3 stays a mirror: \(c.calls)")
        XCTAssertEqual(sent, [.resize(terminalId: "t1", cols: 120, rows: 40)], "no detach: views remain")
    }

    func testWhenAnExplicitDriverLeavesTheEarliestRemainingViewTakesOver() {
        connectedTerminal()
        let a = view("w1"), b = view("w2"), c = view("w3", size: (cols: 150, rows: 50))
        store.claimDriver(terminalId: "t1", fromWindow: "w3")
        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w3"))
        a.clear(); b.clear(); c.clear(); sent.removeAll()

        store.unregister(c)

        XCTAssertTrue(store.isDriver(terminalId: "t1", windowId: "w1"))
        XCTAssertEqual(a.roles, [true])
        XCTAssertTrue(b.roles.isEmpty)
    }

    func testAMirrorLeavingChangesNoRoleAndSendsNothing() {
        connectedTerminal()
        let a = view("w1"), b = view("w2", size: (cols: 120, rows: 40))
        a.clear(); sent.removeAll()

        store.unregister(b)

        XCTAssertTrue(a.roles.isEmpty)
        XCTAssertEqual(sent, [], "a mirror going away is not the last view, so no detach and no resize")
    }

    // MARK: - Daemon unavailable

    func testLosingTheConnectionMarksEveryDescribedTerminalUnavailableAndAnnouncesItOnce() {
        store.connectionChanged(true)
        state(info("t1", pane: "terminal-a"))
        state(info("t2", pane: "terminal-b"))
        changes.removeAll()

        store.connectionChanged(false)

        XCTAssertTrue(store.isDaemonUnavailable(terminalId: "t1"))
        XCTAssertTrue(store.isDaemonUnavailable(terminalId: "t2"))
        XCTAssertEqual(availabilityChanges(false), 1)
        XCTAssertEqual(availabilityChanges(true), 0)
    }

    func testNothingIsUnavailableWhileTheDaemonIsConnected() {
        connectedTerminal()
        view("w1")
        XCTAssertFalse(store.isDaemonUnavailable(terminalId: "t1"))
    }

    func testWhileTheDaemonIsUnavailableInputResizeCloseAndRestartSendNothing() {
        connectedTerminal()
        view("w1")
        store.connectionChanged(false)
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        store.close(terminalId: "t1")
        store.restart(terminalId: "t1")
        XCTAssertTrue(sent.isEmpty, "sent while down: \(sent)")

        store.connectionChanged(true)
        sent.removeAll()
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")
        store.close(terminalId: "t1")
        store.restart(terminalId: "t1")
        XCTAssertTrue(sent.isEmpty, "a bare reconnect does not make the terminal usable again: \(sent)")
    }

    func testReconnectingWithoutATerminalListAttachesNothingAndStaysUnavailable() {
        connectedTerminal()
        view("w1")
        store.connectionChanged(false)
        sent.removeAll(); changes.removeAll()

        store.connectionChanged(true)

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
        XCTAssertTrue(store.isDaemonUnavailable(terminalId: "t1"))
        XCTAssertEqual(availabilityChanges(true), 0)
    }

    func testTheTerminalListAfterAReconnectRestoresTheTruth() {
        store.connectionChanged(true)
        state(info("t-ended", pane: "p-ended"))
        state(info("t-running", pane: "p-running"))
        state(info("t-noview", pane: "p-noview"))
        state(info("t-gone", pane: "p-gone"))
        view("w1", pane: "p-ended")
        view("w1", pane: "p-running")
        store.connectionChanged(false)
        store.connectionChanged(true)
        sent.removeAll(); changes.removeAll()

        store.ingest(.terminalList(TerminalListFrame(terminals: [
            info("t-ended", pane: "p-ended", status: .ended, endedReason: "daemon_stopped"),
            info("t-running", pane: "p-running"),
            info("t-noview", pane: "p-noview"),
        ])))

        XCTAssertEqual(store.terminals["t-ended"]?.status, .ended)
        XCTAssertEqual(store.terminals["t-ended"]?.endedReason, "daemon_stopped")
        XCTAssertEqual(store.terminals["t-running"]?.status, .running)
        XCTAssertNil(store.terminals["t-gone"], "a terminal the daemon no longer lists is forgotten")
        for id in ["t-ended", "t-running", "t-noview"] {
            XCTAssertFalse(store.isDaemonUnavailable(terminalId: id), id)
        }
        XCTAssertEqual(availabilityChanges(true), 1)
        XCTAssertEqual(sent, [.attach(terminalId: "t-running")],
                       "only a running terminal with a live view is attached: \(sent)")
    }

    func testTerminalsWorkAgainOnceTheListHasArrived() {
        connectedTerminal()
        view("w1")
        store.connectionChanged(false)
        store.connectionChanged(true)
        store.ingest(.terminalList(TerminalListFrame(terminals: [info()])))
        sent.removeAll()

        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")
        store.resize(terminalId: "t1", cols: 100, rows: 30, fromWindow: "w1")

        XCTAssertEqual(sent, [.input(terminalId: "t1", bytes: [0x61]),
                              .resize(terminalId: "t1", cols: 100, rows: 30)])
    }

    func testAnEndedTerminalFromTheListDropsInputAndIsNotAttachedEvenWithAView() {
        connectedTerminal()
        view("w1")
        store.connectionChanged(false)
        store.connectionChanged(true)
        sent.removeAll()

        store.ingest(.terminalList(TerminalListFrame(terminals: [
            info(status: .ended, endedReason: "daemon_stopped"),
        ])))
        store.sendInput(terminalId: "t1", bytes: [0x61], fromWindow: "w1")

        XCTAssertTrue(sent.isEmpty, "sent: \(sent)")
    }

    func testTheVeryFirstConnectStillAttachesAtOnceWithoutWaitingForAList() {
        state(info())
        view("w1")
        XCTAssertTrue(sent.isEmpty)

        store.connectionChanged(true)

        XCTAssertEqual(sent, [.attach(terminalId: "t1")])
        XCTAssertFalse(store.isDaemonUnavailable(terminalId: "t1"))
    }
}
