import XCTest
import AppKit

// The window title (Window menu, Mission Control, the title the system shows when the title bar is
// hidden) says PRODUCTION first while the window's focus has a remote shell open: "PRODUCTION — <label>".
// The warning leads, so a long focus label that the system truncates can never push it out of view.
// The title follows the focus when it is renamed, and drops the warning when the shell is gone.
//
// A real `MainLayout` in an off-screen window, fed by the real `TerminalSessionStore.shared` (what these
// tests add to it is removed again in teardown) and by a private `FocusStore` backed by a temporary file,
// so nothing here touches the app's own focuses file.

final class MainLayoutWindowTitleTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private let dash = "\u{2014}"
    private var focusStore: FocusStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainLayoutWindowTitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        focusStore = FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        wait(for: [expectation], timeout: timeout)
    }

    private func addFocus(label: String?) -> Focus {
        let focus = Focus(id: UUID().uuidString, agentTag: "cody", projectPath: "/Users/hammer/Code/nostromo-title-test",
                          isBuiltIn: false, label: label)
        focusStore.add(focus)
        return focus
    }

    private func openRemoteShell(tag: String, environment: String = "production", status: TerminalStatus = .running,
                                 kind: TerminalKind = .ecs, withTarget: Bool = true, id: String = UUID().uuidString) -> TerminalInfo {
        let target = withTarget
            ? TerminalTarget(project: "admin-portal", environment: environment, service: "scheduler", shellType: "shell")
            : nil
        let info = TerminalInfo(terminalId: id, tag: tag, paneId: "terminal-title-test-\(id.prefix(6))", kind: kind,
                                label: environment, cwd: nil, target: target, status: status, exitCode: nil,
                                endedReason: nil, cols: 80, rows: 24,
                                requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                                follower: nil, idleClosesAt: nil)
        TerminalSessionStore.shared.ingest(.terminalState(info))
        addTeardownBlock {
            TerminalSessionStore.shared.ingest(.terminalClosed(TerminalClosedInfo(
                terminalId: info.terminalId, tag: info.tag, paneId: info.paneId, label: info.label, kind: info.kind,
                reason: "user_closed", exitCode: nil, target: info.target)))
        }
        return info
    }

    /// A `MainLayout` whose active focus is `focus`, in an off-screen window.
    private func makeWindow(showing focus: Focus) -> NSWindow {
        let displayUUID = "title-\(UUID().uuidString)"
        let key = DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)
        UserDefaults.standard.set(focus.id, forKey: key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }

        let size = NSSize(width: 1000, height: 700)
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = MainLayout(windowIndex: 0, displayUUID: displayUUID, focusStore: focusStore)
        window.contentView = layout
        window.setContentSize(size)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        return window
    }

    func testTheTitleLeadsWithProductionWhileTheFocusHasARemoteShellOpen() throws {
        let focus = addFocus(label: "Billing fix")
        _ = openRemoteShell(tag: focus.sessionTag)
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "PRODUCTION \(self.dash) Billing fix" }
        XCTAssertEqual(window.title, "PRODUCTION \(dash) Billing fix")
    }

    func testALongLabelCannotPushTheWarningOutOfTheTitle() throws {
        let focus = addFocus(label: String(repeating: "very long label ", count: 5))
        _ = openRemoteShell(tag: focus.sessionTag)
        let window = makeWindow(showing: focus)
        waitUntil { window.title.hasPrefix("PRODUCTION \(self.dash) ") }
        XCTAssertTrue(window.title.hasPrefix("PRODUCTION \(dash) "), window.title)
        XCTAssertEqual(window.title, "PRODUCTION \(dash) \(focus.displayName)")
    }

    func testTheTitleFollowsAFocusRename() throws {
        let focus = addFocus(label: "Old name")
        _ = openRemoteShell(tag: focus.sessionTag)
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "PRODUCTION \(self.dash) Old name" }

        XCTAssertTrue(focusStore.rename(id: focus.id, label: "New name"))
        waitUntil { window.title == "PRODUCTION \(self.dash) New name" }
        XCTAssertEqual(window.title, "PRODUCTION \(dash) New name")
    }

    func testTheTitleStaysPlainWithoutARemoteShell() throws {
        let focus = addFocus(label: "Plain focus")
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "Plain focus" }
        XCTAssertEqual(window.title, "Plain focus")
    }

    func testAnEndedRemoteShellDoesNotKeepTheWarning() throws {
        let focus = addFocus(label: "Ended shell")
        _ = openRemoteShell(tag: focus.sessionTag, status: .ended)
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "Ended shell" }
        XCTAssertEqual(window.title, "Ended shell")
    }

    func testTheWarningAppearsWhenAShellOpensAndGoesWhenItCloses() throws {
        let focus = addFocus(label: "Live focus")
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "Live focus" }

        let info = openRemoteShell(tag: focus.sessionTag)
        waitUntil { window.title == "PRODUCTION \(self.dash) Live focus" }
        XCTAssertEqual(window.title, "PRODUCTION \(dash) Live focus")

        TerminalSessionStore.shared.ingest(.terminalClosed(TerminalClosedInfo(
            terminalId: info.terminalId, tag: info.tag, paneId: info.paneId, label: info.label, kind: info.kind,
            reason: "user_closed", exitCode: nil, target: info.target)))
        waitUntil { window.title == "Live focus" }
        XCTAssertEqual(window.title, "Live focus")
    }

    func testAShellWithNoTargetStillGetsAWarningInTheTitle() throws {
        let focus = addFocus(label: "Mystery shell")
        _ = openRemoteShell(tag: focus.sessionTag, kind: .unknown, withTarget: false)
        let window = makeWindow(showing: focus)
        waitUntil { window.title == "REMOTE \(self.dash) Mystery shell" }
        XCTAssertEqual(window.title, "REMOTE \(dash) Mystery shell")
    }
}
