import XCTest
import AppKit
import NostromoKit

// The `/mcp` panel's controller against a fake daemon connection: what it asks, what it shows for each
// answer, and its own 5 s rate limit. `McpPanelController`, `McpRequests` and the Kit types are compiled
// into this target directly.

/// Records what would have gone to the daemon.
final class McpFakeSender: McpRequestSending {
    struct Sent: Equatable {
        let id: String
        let tag: String
        let action: String
        let server: String?
        let enabled: Bool?
    }
    var daemonAdvertisesSessionMcp = true
    private(set) var sent: [Sent] = []

    func sendSessionMcp(requestId: String, tag: String, action: String, server: String?, enabled: Bool?) {
        sent.append(Sent(id: requestId, tag: tag, action: action, server: server, enabled: enabled))
    }
}

/// A `McpRequests` with ids `req-1`, `req-2`, …, a manual clock and a manual scheduler.
final class McpHarness {
    let sender = McpFakeSender()
    var clock = Date(timeIntervalSince1970: 1_000_000)
    private(set) var scheduled: [(due: Date, work: () -> Void)] = []
    private var counter = 0
    private(set) lazy var requests: McpRequests = {
        let r = McpRequests(makeRequestId: { [unowned self] in self.counter += 1; return "req-\(self.counter)" },
                            schedule: { [unowned self] delay, work in self.scheduled.append((self.clock.addingTimeInterval(delay), work)) })
        r.sender = sender
        return r
    }()

    var now: () -> Date { { [unowned self] in self.clock } }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void {
        { [unowned self] delay, work in self.scheduled.append((self.clock.addingTimeInterval(delay), work)) }
    }

    /// Answer the request `id`.
    func answer(_ id: String, tag: String = "tag-1", action: String, _ outcome: McpOutcomeWire,
                message: String? = nil, servers: [McpServerViewWire]? = nil) {
        requests.ingest(.sessionMcpResult(SessionMcpResultWire(requestId: id, tag: tag, action: action,
                                                                 outcome: outcome, message: message, servers: servers)))
    }

    /// Time passes; everything scheduled to run by then runs.
    func advance(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        let due = scheduled.filter { $0.due <= clock }
        scheduled.removeAll { $0.due <= clock }
        due.forEach { $0.work() }
    }
}

final class McpPanelTests: XCTestCase {
    private let harness = McpHarness()

    private var servers: [McpServerViewWire] {
        [McpServerViewWire(name: "nostromo", status: .connected, scope: "user", transport: "stdio", toolCount: 12, nostromoBridge: true),
         McpServerViewWire(name: "callimachus", status: .failed, scope: "user", transport: "stdio", toolCount: 0, error: "spawn failed"),
         McpServerViewWire(name: "claude.ai Metabase", status: .disabled, scope: "claudeai", transport: "claudeai-proxy", toolCount: nil)]
    }

    private func makeController(path: String? = "/Users/me/code/app") -> McpPanelController {
        let c = McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: path, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        // These tests are about what the panel does; who may press is `McpPanelGestureTests`.
        c.permit = { _ in .human(sourcePid: nil, sourceState: nil) }
        return c
    }

    /// A controller that has asked for and been given the list.
    private func openWithList(_ list: [McpServerViewWire]? = nil) -> McpPanelController {
        let c = makeController()
        c.refresh()
        harness.answer("req-1", action: "status", .ok, servers: list ?? servers)
        return c
    }

    private func row(_ c: McpPanelController, _ name: String) throws -> McpRowView {
        try XCTUnwrap(c.panelView.rowViews.first { $0.row?.name == name }, "no row \(name)")
    }

    // MARK: Opening and rows

    func testOpeningAsksForTheStatusAndShowsLoadingUntilItAnswers() {
        let c = makeController()
        c.refresh()
        XCTAssertEqual(harness.sender.sent, [.init(id: "req-1", tag: "tag-1", action: "status", server: nil, enabled: nil)])
        XCTAssertEqual(c.phase, .loading)
        XCTAssertEqual(c.panelView.stateField.stringValue, "Loading MCP servers…")
        XCTAssertTrue(c.panelView.rowViews.isEmpty)
    }

    func testTheRowsShowNameStatusWordScopeTransportAndCount() throws {
        let c = openWithList()
        XCTAssertEqual(c.panelView.rowViews.count, 3)
        let failed = try row(c, "callimachus")
        XCTAssertEqual(failed.statusLabel.stringValue, "Failed")
        XCTAssertEqual(failed.scopeField.stringValue, "user")
        XCTAssertEqual(failed.transportField.stringValue, "stdio")
        XCTAssertEqual(failed.toolsField.stringValue, "0")
        XCTAssertEqual(failed.errorField.stringValue, "spawn failed")
        XCTAssertFalse(failed.errorField.isHidden)
        let off = try row(c, "claude.ai Metabase")
        XCTAssertEqual(off.statusLabel.stringValue, "Disabled")
        XCTAssertEqual(off.toolsField.stringValue, "—")
        XCTAssertTrue(c.panelView.footnoteField.stringValue.contains("can still read Connected"))
    }

    func testNostromoWithItsBridgeOfflineSaysSo() throws {
        var list = servers
        list[0] = McpServerViewWire(name: "nostromo", status: .connected, toolCount: 12, nostromoBridge: false)
        let c = openWithList(list)
        let r = try row(c, "nostromo")
        XCTAssertEqual(r.errorField.stringValue, "Claude says connected · Nostromo bridge offline")
    }

    // MARK: Buttons

    func testButtonAvailabilityFollowsTheRow() throws {
        let c = openWithList()
        let nostromo = try row(c, "nostromo")
        XCTAssertFalse(nostromo.reconnectButton.isHidden)
        XCTAssertTrue(nostromo.toggleButton.isHidden, "nostromo cannot be disabled from here")
        let off = try row(c, "claude.ai Metabase")
        XCTAssertTrue(off.reconnectButton.isHidden, "a disabled server has nothing to reconnect")
        XCTAssertEqual(off.toggleButton.title, "Enable")
        XCTAssertEqual(try row(c, "callimachus").toggleButton.title, "Disable")
    }

    func testTheButtonsAreLabelledForVoiceOver() throws {
        let c = openWithList()
        let failed = try row(c, "callimachus")
        XCTAssertEqual(failed.reconnectButton.accessibilityLabel(), "Reconnect callimachus")
        XCTAssertEqual(failed.toggleButton.accessibilityLabel(), "Disable callimachus")
        let meta = try row(c, "claude.ai Metabase")
        XCTAssertEqual(meta.toggleButton.accessibilityLabel(), "Enable claude.ai Metabase")
        XCTAssertTrue((failed.accessibilityLabel() ?? "").contains("Failed"), "the row's label carries its status")
        XCTAssertTrue(failed.isAccessibilityElement())
    }

    func testTheButtonsTakeKeyboardFocusAndReturnPressesThem() throws {
        let c = openWithList()
        let button = try row(c, "callimachus").reconnectButton
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(button.canBecomeKeyView)
        let ret = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                                 isARepeat: false, keyCode: 36))
        button.keyDown(with: ret)
        XCTAssertEqual(harness.sender.sent.last?.action, "reconnect")
    }

    // MARK: Reconnect

    func testReconnectSendsOnceDisablesTheRowAndShowsTheResult() throws {
        let c = openWithList()
        let before = harness.sender.sent.count
        c.reconnect("callimachus")
        XCTAssertEqual(harness.sender.sent.count, before + 1)
        XCTAssertEqual(harness.sender.sent.last, .init(id: "req-2", tag: "tag-1", action: "reconnect", server: "callimachus", enabled: nil))
        var r = try row(c, "callimachus")
        XCTAssertFalse(r.reconnectButton.isEnabled)
        XCTAssertFalse(r.toggleButton.isEnabled)
        XCTAssertFalse(r.spinner.isHidden)

        // A second click while it runs sends nothing.
        c.reconnect("callimachus")
        XCTAssertEqual(harness.sender.sent.count, before + 1)

        var fixed = servers
        fixed[1] = McpServerViewWire(name: "callimachus", status: .connected, toolCount: 4)
        harness.answer("req-2", action: "reconnect", .ok, servers: fixed)
        r = try row(c, "callimachus")
        XCTAssertEqual(r.statusLabel.stringValue, "Connected", "the list refreshes from the answer")
        XCTAssertEqual(r.noteField.stringValue, "Reconnected.")
    }

    func testTheButtonsStayOffForFiveSecondsWhateverTheDaemonSays() throws {
        let c = openWithList()
        c.reconnect("callimachus")
        harness.answer("req-2", action: "reconnect", .ok, servers: servers)
        XCTAssertFalse(try row(c, "callimachus").reconnectButton.isEnabled, "answered at once, still cooling")
        c.reconnect("callimachus")
        XCTAssertEqual(harness.sender.sent.filter { $0.action == "reconnect" }.count, 1)

        harness.advance(4)
        XCTAssertFalse(try row(c, "callimachus").reconnectButton.isEnabled)
        harness.advance(1.5)
        XCTAssertTrue(try row(c, "callimachus").reconnectButton.isEnabled)
        c.reconnect("callimachus")
        XCTAssertEqual(harness.sender.sent.filter { $0.action == "reconnect" }.count, 2)
    }

    func testAFailureIsShownInAmberOnTheRowAndTheListStays() throws {
        let c = openWithList()
        c.reconnect("callimachus")
        harness.answer("req-2", action: "reconnect", .refused, message: "Server not found: callimachus")
        let r = try row(c, "callimachus")
        XCTAssertEqual(r.noteField.stringValue, "Server not found: callimachus")
        XCTAssertEqual(r.noteField.textColor, Theme.amber)
        XCTAssertEqual(c.panelView.rowViews.count, 3)
    }

    func testARateLimitedAnswerIsShownVerbatim() throws {
        let c = openWithList()
        c.reconnect("callimachus")
        harness.answer("req-2", action: "reconnect", .rateLimited, message: "wait 3 s before trying callimachus again")
        XCTAssertEqual(try row(c, "callimachus").noteField.stringValue, "wait 3 s before trying callimachus again")
    }

    func testATimeoutOrALostConnectionIsAnErrorOnTheRow() throws {
        let c = openWithList()
        c.reconnect("callimachus")
        harness.requests.failPendingRequests(reason: "The daemon connection was lost")
        XCTAssertEqual(try row(c, "callimachus").noteField.stringValue, "The daemon connection was lost")
    }

    // MARK: Disable and enable

    func testDisableAsksFirstAndNamesTheFolderAndThePersistence() throws {
        let c = openWithList()
        var asked: [String] = []
        c.confirmDisable = { message, completion in asked.append(message); completion(false) }
        c.toggle("callimachus")
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix("Disable callimachus for /Users/me/code/app?"), asked[0])
        XCTAssertTrue(asked[0].contains("every session in that folder, including terminal sessions"), asked[0])
        XCTAssertEqual(harness.sender.sent.filter { $0.action == "toggle" }.count, 0, "declined: nothing sent")

        c.confirmDisable = { _, completion in completion(true) }
        c.toggle("callimachus")
        XCTAssertEqual(harness.sender.sent.last, .init(id: "req-2", tag: "tag-1", action: "toggle", server: "callimachus", enabled: false))
    }

    func testWithoutAProjectPathTheConfirmationSaysThisSessionsFolder() {
        let c = makeController(path: nil)
        c.refresh()
        harness.answer("req-1", action: "status", .ok, servers: servers)
        var asked = ""
        c.confirmDisable = { message, completion in asked = message; completion(false) }
        c.toggle("callimachus")
        XCTAssertTrue(asked.contains("this session's folder"), asked)
    }

    func testEnableNeedsNoConfirmation() throws {
        let c = openWithList()
        c.confirmDisable = { _, _ in XCTFail("an enable must not ask") }
        c.toggle("claude.ai Metabase")
        XCTAssertEqual(harness.sender.sent.last, .init(id: "req-2", tag: "tag-1", action: "toggle", server: "claude.ai Metabase", enabled: true))
    }

    func testNostromoCanNotBeDisabledEvenIfAskedTo() {
        let c = openWithList()
        c.confirmDisable = { _, completion in completion(true) }
        let before = harness.sender.sent.count
        c.toggle("nostromo")
        XCTAssertTrue(c.panelView.rowViews.first { $0.row?.name == "nostromo" }?.toggleButton.isHidden == true,
                      "the panel never offers it")
        XCTAssertEqual(harness.sender.sent.count, before, "and a forced call writes nothing")
        XCTAssertFalse(harness.sender.sent.contains { $0.action == "toggle" }, "no toggle request is written")
    }

    // MARK: States

    func testANotRunningSessionShowsTheMessageAndNoButtons() {
        let c = makeController()
        c.refresh()
        harness.answer("req-1", action: "status", .notRunning, message: "the session is not running")
        XCTAssertEqual(c.phase, .notRunning)
        XCTAssertEqual(c.panelView.stateField.stringValue,
                       "This session isn't running. Send it a message or restart it, then open /mcp again.")
        XCTAssertTrue(c.panelView.rowViews.isEmpty)
    }

    func testAnOldCliGetsTheHonestMessageAndNoActions() {
        let c = makeController()
        c.refresh()
        harness.answer("req-1", action: "status", .unsupported, message: "this Claude Code is too old for MCP control")
        XCTAssertTrue(c.panelView.stateField.stringValue.contains("too old for MCP control"))
        XCTAssertTrue(c.panelView.rowViews.isEmpty)
    }

    func testATimeoutOnTheListIsShownAndRefreshWorksAgain() {
        let c = makeController()
        c.refresh()
        harness.answer("req-1", action: "status", .timeout)
        XCTAssertTrue(c.panelView.stateField.stringValue.contains("did not answer"))
        XCTAssertTrue(c.panelView.refreshButton.isEnabled)
        c.refresh()
        XCTAssertEqual(harness.sender.sent.filter { $0.action == "status" }.count, 2)
    }

    func testRefreshIsOffWhileItRuns() {
        let c = makeController()
        c.refresh()
        XCTAssertFalse(c.panelView.refreshButton.isEnabled)
        c.refresh()
        XCTAssertEqual(harness.sender.sent.count, 1)
    }

    // MARK: Closing

    func testEscapeIsTheCloseButtonsKeyAndClosesThePanel() {
        let c = openWithList()
        XCTAssertEqual(c.panelView.closeButton.keyEquivalent, "\u{1b}")
        c.panelView.closeButton.performClick(nil)
        XCTAssertTrue(c.isClosed)
    }

    func testAnAnswerAfterCloseChangesNothing() {
        let c = makeController()
        c.refresh()
        c.close()
        harness.answer("req-1", action: "status", .ok, servers: servers)
        XCTAssertTrue(c.panelView.rowViews.isEmpty)
    }

    func testTheHeaderNamesTheFocus() {
        let c = makeController()
        XCTAssertTrue(c.panelView.titleField.stringValue.contains("Cody"))
        XCTAssertEqual(c.panelView.subtitleField.stringValue, "MCP servers as Claude Code reports them")
    }
}

// MARK: - Real window fixtures

/// A panel shown as a real sheet on an offscreen window, with the list answered.
fileprivate final class McpWindowRig {
    let harness = McpHarness()
    let parent = GestureFixtures.offscreenWindow()
    let controller: McpPanelController

    static let servers: [McpServerViewWire] = [
        McpServerViewWire(name: "nostromo", status: .connected, scope: "user", transport: "stdio", toolCount: 12, nostromoBridge: true),
        McpServerViewWire(name: "callimachus", status: .failed, scope: "user", transport: "stdio", toolCount: 0, error: "spawn failed"),
        McpServerViewWire(name: "claude.ai Metabase", status: .disabled, scope: "claudeai", transport: "claudeai-proxy", toolCount: nil),
    ]

    init(list: [McpServerViewWire] = McpWindowRig.servers) {
        controller = McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: "/Users/me/code/app",
                                        requests: harness.requests, now: harness.now, schedule: harness.schedule)
        controller.permit = { _ in .human(sourcePid: nil, sourceState: nil) }
        controller.show(on: parent)
        harness.answer("req-1", action: "status", .ok, servers: list)
    }

    var sheet: NSWindow { controller.sheetWindow! }
    func row(_ name: String) -> McpRowView { controller.panelView.rowViews.first { $0.row?.name == name }! }
    var toggles: [McpFakeSender.Sent] { harness.sender.sent.filter { $0.action == "toggle" } }

    func close() {
        controller.close()
        parent.close()
    }
}

private func mcpSpin(_ seconds: TimeInterval = 0.4) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

// MARK: - Many servers

/// The daemon lists up to 200 servers. A click, an answer and the 5 s cooldown each change one row, and
/// must touch only that row: rebuilding all of them blocked the main thread for seconds.
final class McpPanelScaleTests: XCTestCase {
    private let harness = McpHarness()

    private func list(_ count: Int = 200, failing: Set<Int> = []) -> [McpServerViewWire] {
        (0..<count).map { i in
            McpServerViewWire(name: "server-\(i)", status: failing.contains(i) ? .failed : .connected, scope: "user",
                              transport: "stdio", toolCount: i, error: failing.contains(i) ? "boom" : nil)
        }
    }

    private func timed(_ label: String, _ work: () -> Void) {
        let start = Date()
        work()
        print("MCP-PERF \(label): \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }

    func testAChangeOnOneOfTwoHundredRowsTouchesOnlyThatRow() throws {
        let c = McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: nil, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        c.permit = { _ in .human(sourcePid: nil, sourceState: nil) }
        c.refresh()
        timed("200 rows, first list") { harness.answer("req-1", action: "status", .ok, servers: list()) }
        let views = c.panelView.rowViews
        XCTAssertEqual(views.count, 200)

        /// Run `change`, then assert every row view is the one it was, only `touched` did any work, and the
        /// panel was brought up to date once, without rebuilding the stack.
        func check(_ label: String, touched: Set<Int>, _ change: () -> Void) throws {
            let applied = views.map(\.applyCount)
            let renders = c.renderCount
            let rebuilds = c.panelView.stackRebuildCount
            timed(label, change)
            let now = c.panelView.rowViews
            XCTAssertEqual(now.count, 200, label)
            for (i, view) in now.enumerated() {
                XCTAssertTrue(view === views[i], "\(label): row \(i) is a new view")
                XCTAssertEqual(view.applyCount - applied[i], touched.contains(i) ? 1 : 0, "\(label): row \(i)")
            }
            XCTAssertEqual(c.renderCount - renders, 1, "\(label): one render")
            XCTAssertEqual(c.panelView.stackRebuildCount, rebuilds, "\(label): the stack is left alone")
        }

        try check("click", touched: [100]) { c.reconnect("server-100") }
        try check("answer", touched: [100]) {
            harness.answer("req-2", action: "reconnect", .ok, servers: list())
        }
        try check("cooldown expiry", touched: [100]) { harness.advance(6) }
        c.refresh()
        try check("another row failing", touched: [7]) {
            harness.answer("req-3", action: "status", .ok, servers: list(failing: [7]))
        }
    }

    func testAServerLeavingRebuildsTheStackButKeepsTheOtherRowViews() {
        let c = McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: nil, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        c.refresh()
        harness.answer("req-1", action: "status", .ok, servers: list(5))
        let before = c.panelView.rowViews
        c.refresh()
        harness.answer("req-2", action: "status", .ok, servers: Array(list(5).dropFirst()))
        let after = c.panelView.rowViews
        XCTAssertEqual(after.count, 4)
        for (a, b) in zip(after, before.dropFirst()) { XCTAssertTrue(a === b) }
    }

    func testTwoServersWithTheSameNameGetTheirOwnRows() {
        let c = McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: nil, requests: harness.requests,
                                   now: harness.now, schedule: harness.schedule)
        c.refresh()
        let twin = McpServerViewWire(name: "twin", status: .connected, toolCount: 1)
        harness.answer("req-1", action: "status", .ok, servers: [twin, twin])
        let rows = c.panelView.rowViews
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0] === rows[1])
    }
}

// MARK: - Tab

/// Tab in a real window. The rows are made after the window is up, so the Tab order has to be set by hand
/// and again after each render; it is walked here through the explicit `nextKeyView` chain and through the
/// window's own `selectNextKeyView` (what Tab calls).
final class McpPanelKeyLoopTests: MouseQueueTestCase {
    private func buttons(_ rig: McpWindowRig, _ names: [(String, Bool)]) -> [NSView] {
        names.map { name, reconnect in
            let row = rig.row(name)
            return reconnect ? row.reconnectButton : row.toggleButton
        }
    }

    private func chain(from start: NSView, steps: Int) -> [NSView] {
        var out: [NSView] = []
        var at: NSView? = start
        for _ in 0..<steps { at = at?.nextKeyView; if let at { out.append(at) } }
        return out
    }

    func testEveryRowButtonIsReachableInOrderThenRefreshThenClose() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let panel = rig.controller.panelView
        // nostromo: Reconnect only; callimachus: both; Metabase (disabled): Enable only.
        let expected = buttons(rig, [("nostromo", true), ("callimachus", true), ("callimachus", false), ("claude.ai Metabase", false)])
            + [panel.refreshButton, panel.closeButton]

        XCTAssertEqual(chain(from: expected[0], steps: expected.count).map(ObjectIdentifier.init),
                       (Array(expected.dropFirst()) + [expected[0]]).map(ObjectIdentifier.init),
                       "the explicit chain runs the buttons in order and round again")

        // What Tab does: the window moves on from the focused control.
        XCTAssertTrue(rig.sheet.makeFirstResponder(expected[0]))
        var visited: [NSResponder?] = []
        for _ in 1..<expected.count {
            rig.sheet.selectNextKeyView(nil)
            visited.append(rig.sheet.firstResponder)
        }
        XCTAssertEqual(visited.map { $0.map(ObjectIdentifier.init) }, expected.dropFirst().map(ObjectIdentifier.init),
                       "Tab reaches every enabled button in order, Refresh and Close last")
    }

    func testAButtonThatIsOffIsSkippedAndComesBackWhenItIsEnabled() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let panel = rig.controller.panelView
        rig.controller.reconnect("callimachus")
        XCTAssertFalse(rig.row("callimachus").reconnectButton.isEnabled)
        XCTAssertTrue(rig.sheet.makeFirstResponder(rig.row("nostromo").reconnectButton))
        rig.sheet.selectNextKeyView(nil)
        XCTAssertTrue(rig.sheet.firstResponder === rig.row("claude.ai Metabase").toggleButton, "the busy row is skipped")

        rig.harness.advance(6)
        rig.harness.answer("req-2", action: "reconnect", .ok, servers: McpWindowRig.servers)
        XCTAssertTrue(rig.sheet.makeFirstResponder(rig.row("nostromo").reconnectButton))
        rig.sheet.selectNextKeyView(nil)
        XCTAssertTrue(rig.sheet.firstResponder === rig.row("callimachus").reconnectButton)
        _ = panel
    }

    func testRowsThatArriveLaterJoinTheLoop() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        rig.controller.refresh()
        rig.harness.advance(0)
        var more = McpWindowRig.servers
        more.append(McpServerViewWire(name: "late", status: .connected, scope: "user", transport: "stdio", toolCount: 1))
        rig.harness.answer("req-2", action: "status", .ok, servers: more)
        let late = rig.row("late")
        let ring = chain(from: rig.controller.panelView.refreshButton, steps: 8)
        XCTAssertTrue(ring.contains { $0 === late.reconnectButton })
        XCTAssertTrue(ring.contains { $0 === late.toggleButton })
        XCTAssertTrue(chain(from: rig.row("claude.ai Metabase").toggleButton, steps: 1)[0] === late.reconnectButton,
                      "after the last old row comes the new one")
    }
}

// MARK: - Who may press

/// Every action is held to `HumanGesture`: Reconnect, Enable, Disable, the confirmation's Disable and the
/// badge. Real `HumanGesture.permit` over real events in a real window.
final class McpPanelGestureTests: MouseQueueTestCase {
    enum Kind { case fresh, noEvent, appControl, stale }

    private var kind: Kind = .fresh

    private func event(for window: NSWindow?) throws -> NSEvent? {
        let window = try XCTUnwrap(window, "the control is in a window")
        switch kind {
        case .fresh: return GestureFixtures.mouse(.leftMouseUp, in: window)
        case .noEvent: return nil
        case .appControl: return try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        case .stale: return GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: ProcessInfo.processInfo.systemUptime - 30)
        }
    }

    private func makeRig() -> McpWindowRig {
        let rig = McpWindowRig()
        addTeardownBlock { rig.close() }
        rig.controller.permit = { [unowned self] control in
            HumanGesture.permit(try? self.event(for: control.window), control: control,
                                voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        return rig
    }

    private let refusals: [Kind] = [.noEvent, .appControl, .stale]

    func testAPersonsOwnClickReconnects() {
        let rig = makeRig()
        rig.row("callimachus").reconnectButton.performClick(nil)
        XCTAssertEqual(rig.harness.sender.sent.last?.action, "reconnect")
    }

    func testAReconnectThatIsNotAPersonsDoesNothing() {
        for k in refusals {
            kind = k
            let rig = makeRig()
            rig.row("callimachus").reconnectButton.performClick(nil)
            XCTAssertEqual(rig.harness.sender.sent.map(\.action), ["status"], "\(k): nothing was sent")
            XCTAssertTrue(rig.row("callimachus").reconnectButton.isEnabled, "\(k): the row did not start")
        }
    }

    func testADisableThatIsNotAPersonsDoesNotEvenAsk() {
        for k in refusals {
            kind = k
            let rig = makeRig()
            rig.row("callimachus").toggleButton.performClick(nil)
            mcpSpin()
            XCTAssertNil(rig.controller.confirmSheet, "\(k): no confirmation")
            XCTAssertTrue(rig.toggles.isEmpty, "\(k)")
        }
    }

    func testAnEnableThatIsNotAPersonsDoesNothing() {
        for k in refusals {
            kind = k
            let rig = makeRig()
            rig.row("claude.ai Metabase").toggleButton.performClick(nil)
            XCTAssertTrue(rig.toggles.isEmpty, "\(k)")
        }
        kind = .fresh
        let rig = makeRig()
        rig.row("claude.ai Metabase").toggleButton.performClick(nil)
        XCTAssertEqual(rig.toggles.map(\.enabled), [true], "a person's click enables")
    }

    func testTheConfirmationsDisableIsAPersonsPressOrNothing() throws {
        for k in refusals {
            kind = .fresh
            let rig = makeRig()
            rig.row("callimachus").toggleButton.performClick(nil)
            let alert = try XCTUnwrap(rig.controller.confirmSheet, "the confirmation is up")
            kind = k
            alert.disableButton.performClick(nil)
            mcpSpin()
            XCTAssertTrue(rig.toggles.isEmpty, "\(k): nothing sent")
            XCTAssertNotNil(rig.controller.confirmSheet, "\(k): the confirmation stays")

            kind = .fresh
            alert.disableButton.performClick(nil)
            mcpSpin()
            XCTAssertEqual(rig.toggles.map(\.enabled), [false], "a person's press disables")
        }
    }
}

// MARK: - The real confirmation sheet

/// Every other test stubs `confirmDisable`; these drive the sheet that ships.
final class McpPanelConfirmationTests: MouseQueueTestCase {
    private func ask(_ rig: McpWindowRig) throws -> McpConfirmSheet {
        rig.row("callimachus").toggleButton.performClick(nil)
        return try XCTUnwrap(rig.controller.confirmSheet, "the confirmation is up")
    }

    func testCancelIsTheDefaultButtonAndDisableIsMarkedDestructive() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let alert = try ask(rig)
        XCTAssertEqual([alert.cancelButton.title, alert.disableButton.title], ["Cancel", "Disable"])
        XCTAssertTrue(alert.window.defaultButtonCell === alert.cancelButton.cell, "Cancel is the default button")
        XCTAssertFalse(alert.window.defaultButtonCell === alert.disableButton.cell, "Disable is not the default")
        XCTAssertTrue(alert.disableButton.hasDestructiveAction)
        XCTAssertTrue(alert.message.contains("~/.claude.json"), alert.message)
        XCTAssertTrue(alert.message.contains("/Users/me/code/app"), alert.message)
        XCTAssertTrue(alert.message.contains("terminal sessions"), alert.message)
        alert.cancelButton.performClick(nil)
        mcpSpin()
    }

    func testReturnCancelsAndSendsNothingAndTheDisableGoesOnlyOnTheExplicitClick() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let alert = try ask(rig)
        // Return presses the window's default button: that is Cancel.
        let returnTarget = try XCTUnwrap(alert.window.defaultButtonCell, "the sheet has a default button")
        XCTAssertEqual(returnTarget.title, "Cancel")
        returnTarget.performClick(nil)
        mcpSpin()
        XCTAssertNil(rig.controller.confirmSheet, "the sheet is gone")
        XCTAssertTrue(rig.toggles.isEmpty, "Return did not disable")
        XCTAssertTrue(rig.row("callimachus").toggleButton.isEnabled, "the row did not start")

        let again = try ask(rig)
        mcpSpin()
        XCTAssertTrue(rig.toggles.isEmpty, "an open confirmation sends nothing by itself")
        again.disableButton.performClick(nil)
        mcpSpin()
        XCTAssertEqual(rig.toggles, [.init(id: "req-2", tag: "tag-1", action: "toggle", server: "callimachus", enabled: false)])
    }

    func testCancelAndEscapeSendNothing() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        var alert = try ask(rig)
        alert.cancelButton.performClick(nil)
        mcpSpin()
        XCTAssertTrue(rig.toggles.isEmpty)
        alert = try ask(rig)
        XCTAssertEqual(alert.cancelButton.title, "Cancel")
        alert.window.cancelOperation(nil)  // what Esc does in a sheet
        mcpSpin()
        XCTAssertTrue(rig.toggles.isEmpty)
        XCTAssertNil(rig.controller.confirmSheet, "Esc ends the confirmation")
        XCTAssertTrue(rig.sheet.sheets.isEmpty, "Esc closes the sheet window")
    }

    func testCancelClosesTheSheetWindowAsWellAsEndingTheConfirmation() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let alert = try ask(rig)
        alert.cancelButton.performClick(nil)
        mcpSpin()
        XCTAssertNil(rig.controller.confirmSheet, "Cancel ends the confirmation")
        XCTAssertTrue(rig.sheet.sheets.isEmpty, "Cancel closes the sheet window")
    }

    // MARK: One confirmation at a time

    private func twoDisableable() -> [McpServerViewWire] {
        McpWindowRig.servers + [McpServerViewWire(name: "other", status: .connected, scope: "user", transport: "stdio", toolCount: 1)]
    }

    func testDisableOnAnotherRowWhileAConfirmationIsUpDoesNotStackASecondSheet() throws {
        let rig = McpWindowRig(list: twoDisableable())
        defer { rig.close() }
        let first = try ask(rig)
        rig.row("other").toggleButton.performClick(nil)
        mcpSpin()
        XCTAssertTrue(rig.controller.confirmSheet === first, "still the first confirmation")
        XCTAssertEqual(rig.sheet.sheets.count, 1, "no second sheet")

        first.disableButton.performClick(nil)
        mcpSpin()
        XCTAssertEqual(rig.toggles.map(\.server), ["callimachus"], "only the confirmed server is toggled")
        XCTAssertEqual(rig.toggles.map(\.enabled), [false])
        XCTAssertNil(rig.controller.confirmSheet)
        XCTAssertTrue(rig.sheet.sheets.isEmpty)
    }

    func testPressingDisableTwiceOnTheSameRowAsksOnce() throws {
        let rig = McpWindowRig()
        defer { rig.close() }
        let first = try ask(rig)
        rig.row("callimachus").toggleButton.performClick(nil)
        mcpSpin()
        XCTAssertTrue(rig.controller.confirmSheet === first)
        XCTAssertEqual(rig.sheet.sheets.count, 1)
    }

    /// Each way out of the confirmation ends it and closes its window, so the panel is not left stuck.
    func testCancelEscapeAndDisableEachCloseTheSheetAndTheDisableSendsExactlyOnce() throws {
        enum Exit: String, CaseIterable { case cancel, escape, disable }
        for exit in Exit.allCases {
            let rig = McpWindowRig()
            defer { rig.close() }
            let alert = try ask(rig)
            rig.row("callimachus").toggleButton.performClick(nil)  // a second press while it is up
            XCTAssertEqual(rig.sheet.sheets.count, 1, "\(exit): one sheet")
            switch exit {
            case .cancel: alert.cancelButton.performClick(nil)
            case .escape: alert.window.cancelOperation(nil)
            case .disable: alert.disableButton.performClick(nil)
            }
            mcpSpin()
            XCTAssertNil(rig.controller.confirmSheet, "\(exit): confirmation ended")
            XCTAssertTrue(rig.sheet.sheets.isEmpty, "\(exit): sheet window closed")
            if exit == .disable {
                XCTAssertEqual(rig.toggles.map(\.enabled), [false], "\(exit): exactly one disable")
                XCTAssertEqual(rig.toggles.map(\.server), ["callimachus"])
            } else {
                XCTAssertTrue(rig.toggles.isEmpty, "\(exit): nothing sent")
                // The panel is usable again.
                rig.row("callimachus").toggleButton.performClick(nil)
                XCTAssertNotNil(rig.controller.confirmSheet, "\(exit): Disable asks again")
                XCTAssertEqual(rig.sheet.sheets.count, 1, "\(exit): a fresh sheet")
            }
        }
    }
}

// MARK: - Keyboard focus survives a refresh

/// A refresh re-renders the rows. The focused button must stay focused when its row survives, and when its
/// row goes, focus lands on a safe control (the next row's same kind of button, else Refresh), never on a
/// control that would act on some other server by surprise.
final class McpPanelFocusTests: MouseQueueTestCase {
    private func server(_ name: String, _ status: McpStatusKind = .connected) -> McpServerViewWire {
        McpServerViewWire(name: name, status: status, scope: "user", transport: "stdio", toolCount: 1)
    }

    /// Focus `pick(rig)`, then answer a refresh with `after`; returns the rig.
    private func refresh(_ rig: McpWindowRig, to after: [McpServerViewWire]) {
        rig.controller.refresh()
        rig.harness.advance(0)
        rig.harness.answer("req-2", action: "status", .ok, servers: after)
    }

    func testFocusStaysOnTheSameButtonWhenAnEarlierRowLeaves() throws {
        let rig = McpWindowRig(list: [server("other"), server("callimachus", .failed), server("claude.ai Metabase", .disabled)])
        defer { rig.close() }
        let focused = rig.row("callimachus").toggleButton
        XCTAssertTrue(rig.sheet.makeFirstResponder(focused))
        refresh(rig, to: [server("callimachus", .failed), server("claude.ai Metabase", .disabled)])
        XCTAssertTrue(rig.sheet.firstResponder === focused, "same button object, not whatever now sits at its old position")
        XCTAssertTrue(rig.row("callimachus").toggleButton === focused)
        XCTAssertFalse(rig.sheet.firstResponder === rig.row("claude.ai Metabase").toggleButton)
    }

    func testFocusIsKeptWhenNothingChanges() throws {
        let list = [server("other"), server("callimachus", .failed), server("claude.ai Metabase", .disabled)]
        let rig = McpWindowRig(list: list)
        defer { rig.close() }
        let focused = rig.row("callimachus").reconnectButton
        XCTAssertTrue(rig.sheet.makeFirstResponder(focused))
        refresh(rig, to: list)
        XCTAssertTrue(rig.sheet.firstResponder === focused)
    }

    func testFocusedRowLeavingMovesFocusToTheNextRowsSameKindOfButton() throws {
        let rig = McpWindowRig(list: [server("callimachus", .failed), server("other"), server("claude.ai Metabase", .disabled)])
        defer { rig.close() }
        XCTAssertTrue(rig.sheet.makeFirstResponder(rig.row("callimachus").toggleButton))
        refresh(rig, to: [server("other"), server("claude.ai Metabase", .disabled)])
        XCTAssertTrue(rig.sheet.firstResponder === rig.row("other").toggleButton, "the following row's Disable")
    }

    func testFocusedReconnectLeavingMovesFocusToTheNextRowsReconnect() throws {
        let rig = McpWindowRig(list: [server("callimachus", .failed), server("other")])
        defer { rig.close() }
        XCTAssertTrue(rig.sheet.makeFirstResponder(rig.row("callimachus").reconnectButton))
        refresh(rig, to: [server("other")])
        XCTAssertTrue(rig.sheet.firstResponder === rig.row("other").reconnectButton, "the following row's Reconnect")
    }

    func testFocusedLastRowLeavingMovesFocusToRefresh() throws {
        let rig = McpWindowRig(list: [server("other"), server("callimachus", .failed)])
        defer { rig.close() }
        XCTAssertTrue(rig.sheet.makeFirstResponder(rig.row("callimachus").toggleButton))
        refresh(rig, to: [server("other")])
        XCTAssertTrue(rig.sheet.firstResponder === rig.controller.panelView.refreshButton, "no row follows, so Refresh")
        XCTAssertFalse(rig.sheet.firstResponder === rig.row("other").toggleButton, "not the previous row's button")
    }
}
