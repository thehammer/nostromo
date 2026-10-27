import XCTest
import AppKit

// `RemotePasteGate`: what happens to text a person is about to put into a terminal (a paste, dictated or
// replaced text). `NostromoTerminalView` holds one and routes `paste` and `insertText` through it, so this
// is the behaviour of both.
//
// Only a terminal KNOWN to be local takes multi-line text straight away. For anything else (an `ecs` pane,
// a pane of a kind this app does not know, a pane the store has no record of, no terminal id at all) text
// with a newline, a trailing one included, asks first; with no window to ask in it is REFUSED (nothing is
// sent, the daemon is told). Nothing falls through to a plain send. A single line without a newline is
// always sent.
//
// A human Paste click cannot be produced in a test, so "after confirmation the text is sent" is not
// driven; what is driven is that `send` never runs before confirmation, nor on Cancel, Return or Escape,
// nor on a Paste click that is not a person's.

final class RemotePasteGateTests: XCTestCase {

    private var sent: [TerminalClientMessage] = []
    private var store: TerminalSessionStore!
    private var gate: RemotePasteGate!
    private var sendCount = 0

    override func setUp() {
        super.setUp()
        sent = []
        sendCount = 0
        store = TerminalSessionStore(now: { Date(timeIntervalSinceReferenceDate: 1_000_000) },
                                     schedule: { _, _ in }, transport: { [unowned self] in self.sent.append($0) })
        gate = RemotePasteGate(store: store)
    }

    override func tearDown() {
        gate = nil
        store = nil
        super.tearDown()
    }

    // MARK: Harness

    private func describe(id: String = "t1", kind: TerminalKind, target: TerminalTarget? = nil) {
        let info = TerminalInfo(terminalId: id, tag: "core-1", paneId: "terminal-\(id)", kind: kind, label: "zsh", cwd: nil,
                                target: target, status: .running, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                                requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                                follower: nil, idleClosesAt: nil)
        store.ingest(.terminalState(info))
    }

    private let production = TerminalTarget(project: "admin-portal", environment: "production", service: "scheduler", shellType: "shell")

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        addTeardownBlock { window.close() }
        return window
    }

    @discardableResult
    private func submit(_ text: String, terminalId: String? = "t1", window: NSWindow?, op: TerminalRefusedOp = .paste,
                        fromClipboard: Bool = true) -> Int {
        gate.submit(text, terminalId: terminalId, window: window, refusedOp: op, fromClipboard: fromClipboard) { [unowned self] in
            self.sendCount += 1
        }
        return sendCount
    }

    private var refusals: [(terminalId: String?, op: TerminalRefusedOp, channel: String)] {
        sent.compactMap { message in
            if case .refusalReport(let id, let op, let channel) = message { return (id, op, channel) }
            return nil
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        wait(for: [expectation], timeout: timeout)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func sheetField(_ id: String) -> String? {
        gate.pasteConfirm?.window?.contentView.flatMap { content in
            descendants(of: content).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id }?.stringValue
        }
    }

    private func sheetButton(_ id: String) -> NSButton? {
        gate.pasteConfirm?.window?.contentView.flatMap { content in
            descendants(of: content).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id }
        }
    }

    // MARK: No window: refused, never sent

    func testAMultiLineTextIntoARemoteShellWithNoWindowIsRefusedNotSent() {
        describe(kind: .ecs, target: production)
        submit("echo 1\necho 2", window: nil)
        XCTAssertEqual(sendCount, 0, "nothing reaches the shell")
        XCTAssertNil(gate.pasteConfirm)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertEqual(refusals.first?.op, .paste)
        XCTAssertEqual(refusals.first?.terminalId, "t1")
        XCTAssertEqual(refusals.first?.channel, "app_control")
    }

    func testTheRefusalCarriesTheOpTheCallerNames() {
        describe(kind: .ecs, target: production)
        submit("a\nb", window: nil, op: .input, fromClipboard: false)
        XCTAssertEqual(refusals.map(\.op), [.input], "inserted text is reported as input, a paste as paste")
        XCTAssertEqual(sendCount, 0)
    }

    func testATrailingNewlineAloneIsEnoughToRefuseWithNoWindow() {
        describe(kind: .ecs, target: production)
        submit("rm -rf x\n", window: nil)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.map(\.op), [.paste])
    }

    func testAPaneOfAnUnknownKindIsTreatedAsRemote() {
        describe(kind: .unknown)
        submit("a\nb", window: nil)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.map(\.op), [.paste])
    }

    func testAPaneTheStoreHasNoRecordOfIsTreatedAsRemote() {
        submit("a\nb", terminalId: "t-unknown", window: nil)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.first?.terminalId, "t-unknown")
        XCTAssertEqual(refusals.map(\.op), [.paste])
    }

    func testNoTerminalIdAtAllIsTreatedAsRemote() {
        submit("a\nb", terminalId: nil, window: nil)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.count, 1)
        XCTAssertNil(refusals.first?.terminalId)
    }

    // MARK: A window: asks first

    func testAMultiLineTextAsksAndSendsNothingUntilConfirmed() throws {
        describe(kind: .ecs, target: production)
        let window = makeWindow()
        submit("echo 1\necho 2\necho 3", window: window)
        let sheet = try XCTUnwrap(gate.pasteConfirm, "a confirmation is up")
        XCTAssertTrue(window.attachedSheet === sheet.window)
        XCTAssertEqual(sendCount, 0, "nothing is sent before Paste is clicked")
        XCTAssertEqual(refusals.count, 0)
        XCTAssertEqual(sheetField("paste-confirm-title"), "Paste 3 lines into PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler?")
        XCTAssertEqual(sheetField("paste-confirm-preview"), "echo 1\necho 2\necho 3")
    }

    func testASingleLineWithATrailingNewlineAsks() {
        describe(kind: .ecs, target: production)
        submit("rm -rf x\n", window: makeWindow())
        XCTAssertNotNil(gate.pasteConfirm)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(sheetField("paste-confirm-title"), "Paste 1 line into PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler?")
    }

    func testTheSheetNamesARemoteShellWhenTheTargetIsUnknown() {
        describe(kind: .ecs, target: nil)
        submit("a\nb", window: makeWindow())
        XCTAssertEqual(sheetField("paste-confirm-title"), "Paste 2 lines into REMOTE shell?")
    }

    func testTheSheetNamesARemoteShellForAnUnknownKind() {
        describe(kind: .unknown)
        submit("a\nb", window: makeWindow())
        XCTAssertEqual(sheetField("paste-confirm-title"), "Paste 2 lines into REMOTE shell?")
    }

    func testTheSheetNamesARemoteShellWhenTheStoreHasNoRecord() {
        submit("a\nb", terminalId: "t-unknown", window: makeWindow())
        XCTAssertEqual(sheetField("paste-confirm-title"), "Paste 2 lines into REMOTE shell?")
        XCTAssertEqual(sendCount, 0)
    }

    func testTheSheetAsksForAViewWithNoTerminalId() {
        submit("a\nb", terminalId: nil, window: makeWindow())
        XCTAssertNotNil(gate.pasteConfirm)
        XCTAssertEqual(sendCount, 0)
    }

    func testThePreviewShowsControlCharactersAsVisibleMarkers() {
        describe(kind: .ecs, target: production)
        submit("ls\u{1b}[31m\nid", window: makeWindow())
        XCTAssertEqual(sheetField("paste-confirm-preview"), "ls\u{FFFD}[31m\nid")
    }

    func testInsertedTextWithANewlineAsksThroughTheSamePath() {
        describe(kind: .ecs, target: production)
        let window = makeWindow()
        submit("a\nb", window: window, op: .input, fromClipboard: false)
        XCTAssertTrue(window.attachedSheet === gate.pasteConfirm?.window)
        XCTAssertEqual(sendCount, 0)
    }

    func testASecondSubmissionWhileTheSheetIsUpDoesNotStackAnotherSheet() throws {
        describe(kind: .ecs, target: production)
        let window = makeWindow()
        submit("a\nb", window: window)
        let first = try XCTUnwrap(gate.pasteConfirm)
        submit("c\nd", window: window)
        XCTAssertTrue(gate.pasteConfirm === first)
        XCTAssertEqual(sendCount, 0)
    }

    // MARK: Straight through

    func testASingleLineWithoutANewlineIsSentAtOnceWhateverTheKind() {
        describe(kind: .ecs, target: production)
        describe(id: "t2", kind: .unknown)
        describe(id: "t3", kind: .local)
        let window = makeWindow()
        for id in ["t1", "t2", "t3", "t-unknown", nil] as [String?] {
            let before = sendCount
            submit("ls -la", terminalId: id, window: window)
            XCTAssertEqual(sendCount, before + 1, "terminal \(String(describing: id))")
        }
        XCTAssertNil(gate.pasteConfirm)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(refusals.count, 0)
    }

    func testASingleLineWithoutANewlineIsSentEvenWithNoWindow() {
        describe(kind: .ecs, target: production)
        submit("ls", window: nil)
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(refusals.count, 0)
    }

    func testALocalShellTakesMultiLineTextStraightThroughWithNoSheet() {
        describe(kind: .local)
        let window = makeWindow()
        submit("echo 1\necho 2\n", window: window)
        XCTAssertEqual(sendCount, 1)
        XCTAssertNil(gate.pasteConfirm)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(refusals.count, 0)
    }

    func testALocalShellWithNoWindowIsNotRefused() {
        describe(kind: .local)
        submit("a\nb", window: nil, op: .input, fromClipboard: false)
        XCTAssertEqual(sendCount, 1)
        XCTAssertEqual(refusals.count, 0)
    }

    // MARK: Ways out of the sheet never send

    func testCancelSendsNothingAndAllowsALaterPasteToAskAgain() throws {
        describe(kind: .ecs, target: production)
        let window = makeWindow()
        submit("a\nb", window: window)
        try XCTUnwrap(sheetButton("paste-confirm-cancel")).performClick(nil)
        waitUntil { self.gate.pasteConfirm == nil }
        XCTAssertNil(gate.pasteConfirm)
        XCTAssertEqual(sendCount, 0)

        submit("a\nb", window: window)
        XCTAssertNotNil(gate.pasteConfirm, "a later paste asks again")
        XCTAssertEqual(sendCount, 0)
    }

    func testReturnNeverSends() throws {
        describe(kind: .ecs, target: production)
        submit("a\nb", window: makeWindow())
        let sheetWindow = try XCTUnwrap(gate.pasteConfirm?.window)
        _ = sheetWindow.performKeyEquivalent(with: GestureFixtures.key(in: sheetWindow, characters: "\r", keyCode: 36))
        waitUntil { self.gate.pasteConfirm == nil }
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.count, 0)
    }

    func testEscapeNeverSends() throws {
        describe(kind: .ecs, target: production)
        submit("a\nb", window: makeWindow())
        let sheetWindow = try XCTUnwrap(gate.pasteConfirm?.window)
        sheetWindow.cancelOperation(nil)
        waitUntil { self.gate.pasteConfirm == nil }
        XCTAssertEqual(sendCount, 0)
    }

    func testAPasteClickThatIsNotAHumanGestureSendsNothingIsReportedAndLeavesTheSheetUp() throws {
        describe(kind: .ecs, target: production)
        let window = makeWindow()
        submit("a\nb", window: window, op: .paste)
        let sheet = try XCTUnwrap(gate.pasteConfirm)
        try XCTUnwrap(sheetButton("paste-confirm-paste")).performClick(nil)
        XCTAssertEqual(sendCount, 0)
        XCTAssertEqual(refusals.map(\.op), [.paste])
        XCTAssertTrue(window.attachedSheet === sheet.window, "the sheet stays up")
        XCTAssertTrue(gate.pasteConfirm === sheet)
    }

    func testARefusedPasteClickOfInsertedTextIsReportedAsInput() throws {
        describe(kind: .ecs, target: production)
        submit("a\nb", window: makeWindow(), op: .input, fromClipboard: false)
        try XCTUnwrap(sheetButton("paste-confirm-paste")).performClick(nil)
        XCTAssertEqual(refusals.map(\.op), [.input])
        XCTAssertEqual(sendCount, 0)
    }

    // MARK: The parent window closing

    func testClosingTheParentWindowWhileTheSheetIsUpLetsALaterPasteAskAgain() {
        describe(kind: .ecs, target: production)
        let first = makeWindow()
        submit("a\nb", window: first)
        XCTAssertNotNil(gate.pasteConfirm)

        first.close()
        waitUntil { self.gate.pasteConfirm == nil }
        XCTAssertNil(gate.pasteConfirm, "a sheet whose window is gone is forgotten")
        XCTAssertEqual(sendCount, 0)

        let second = makeWindow()
        submit("a\nb", window: second)
        XCTAssertNotNil(gate.pasteConfirm, "the next paste asks instead of silently doing nothing")
        XCTAssertTrue(second.attachedSheet === gate.pasteConfirm?.window)
        XCTAssertEqual(sendCount, 0)
    }
}
