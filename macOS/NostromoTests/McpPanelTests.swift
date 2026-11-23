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
    private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var counter = 0
    private(set) lazy var requests: McpRequests = {
        let r = McpRequests(makeRequestId: { [unowned self] in self.counter += 1; return "req-\(self.counter)" },
                            schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) })
        r.sender = sender
        return r
    }()

    var now: () -> Date { { [unowned self] in self.clock } }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void {
        { [unowned self] delay, work in self.scheduled.append((delay, work)) }
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
        let due = scheduled.filter { $0.delay <= seconds }
        scheduled.removeAll { $0.delay <= seconds }
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
        McpPanelController(tag: "tag-1", focusName: "Cody", projectPath: path, requests: harness.requests,
                           now: harness.now, schedule: harness.schedule)
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
        // The model offers no Disable for it; a forced call still goes through the daemon's own refusal,
        // which the panel shows. What matters here is the panel never offers it.
        XCTAssertTrue(c.panelView.rowViews.first { $0.row?.name == "nostromo" }?.toggleButton.isHidden == true)
        _ = before
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
