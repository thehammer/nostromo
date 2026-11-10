import XCTest
import AppKit
import Combine
import NostromoKit

// T5: "Waiting on you" and the background summary row in the tracker pane (PRD 49 and 50).
//
// What the strip lists and in what order, that a click on an entry goes where it says (a decision's
// sheet, a board item, the focus's approval card, the background list) and nothing else, that the
// summary row says what BA's chip says at every step and never writes to the board, that growing
// and shrinking the strip or the row never moves what the reader is reading, and the
// `DecisionCoordinator` hooks the strip is fed from.
//
// Everything is injected: a fake decision provider (a subject the test publishes on), an
// `ApprovalStore` fed by hand, a `BackgroundTaskStore` with a ticking clock, an immediate scheduler
// and a private `UserDefaults` suite, the pane's own `now`, a private pasteboard, and a recording
// `TrackerWaitingActions` and background-list opener. No wall clock, no real pasteboard, no
// `UserDefaults.standard`. Boards are the golden frame decoded through the app's own decoder
// (`TrackerBoardScript`), edited in memory.

// MARK: - Fakes

/// The focus's pending decisions, and the sheet a click would show.
private final class WSDecisions: TrackerDecisionProviding {
    var pending: [String: [TrackerDecisionSummary]] = [:]
    let subject = PassthroughSubject<String, Never>()
    private(set) var shown: [String] = []

    var decisionsChanged: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }

    func pendingDecisions(tag: String) -> [TrackerDecisionSummary] { pending[tag] ?? [] }

    func showDecision(requestId: String) { shown.append(requestId) }

    /// A request arrived for `tag`.
    func add(_ requestId: String, _ text: String, tag: String) {
        pending[tag, default: []].append(TrackerDecisionSummary(requestId: requestId, text: text))
        subject.send(tag)
    }

    /// The request was answered (here or elsewhere): it leaves, and the change is published.
    func answer(_ requestId: String, tag: String) {
        pending[tag]?.removeAll { $0.requestId == requestId }
        subject.send(tag)
    }
}

/// The focus's REPL pane, as far as the summary row goes.
private final class WSRepl: TrackerBackgroundListOpening {
    private(set) var opened = 0
    func showBackgroundList() { opened += 1 }
}

private final class WSActionLog {
    private(set) var approvals: [String] = []
    func recordApprovals(_ tag: String) { approvals.append(tag) }
}

// MARK: - Fixtures

private enum WSFx {
    typealias Script = TrackerBoardScript

    static let commandItem = "rotat-2702"   // Findings, near the bottom of the board
    static let ranCommand = "verif-1481"
    static let needsYouItems = ["docum-1740", "backf-1777"]

    /// The golden board with nothing waiting: no `needs-you` item, every item a plain item, not ran.
    static func quiet(tag: String, file: StaticString = #filePath) throws -> Script {
        var script = try Script(tag: tag, file: file)
        for id in script.itemIDs() {
            try script.updateItem(id) { item in
                if item["status"] as? String == "needs-you" { item["status"] = "todo" }
                item["kind"] = "item"
                item["ran"] = false
            }
        }
        return script
    }

    /// PRD 49's board: 2 needs-you items, 1 un-run command, 1 ran command.
    static func prd(tag: String, file: StaticString = #filePath) throws -> Script {
        var script = try quiet(tag: tag, file: file)
        for id in needsYouItems { try script.setStatus(id, "needs-you") }
        try script.updateItem(commandItem) { $0["kind"] = "command"; $0["ran"] = false }
        try script.updateItem(ranCommand) { $0["kind"] = "command"; $0["ran"] = true }
        return script
    }

    static func task(_ id: String, _ status: TaskStatusWire, ended: UInt64? = nil, kind: TaskKindWire = .agent,
                     housekeeping: Bool = false, backgrounded: Bool? = nil, parent: String? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: "work \(id)", parentTaskId: parent,
                     isBackgrounded: backgrounded, housekeeping: housekeeping, status: status,
                     startedAtMs: 1_000, endedAtMs: ended)
    }

    static func keys(_ entries: [TrackerWaitingEntry]) -> [String] { entries.map(\.key) }

    static let sentinel = "SENTINEL_SECRET_TOOL_INPUT"

    /// The summary row's text for a chip, the way the pane must show it.
    static func summaryText(_ chip: BackgroundChipState) -> String {
        chip.text.map { $0 + " in the background" } ?? ""
    }
}

// MARK: - The pane and what it is wired to

private final class WSRig {
    let window: NSWindow
    let host: RigFlippedDoc
    let pane: TrackerPaneView
    let store: TrackerStore
    let tag: String
    let decisions = WSDecisions()
    let approvals: ApprovalStore
    let background: BackgroundTaskStore
    let actions = WSActionLog()
    let repl = WSRepl()
    let composer = NSTextField(string: "")
    var script: TrackerBoardScript

    /// Pushes since creation (to number the board versions).
    private var storeChanges = 0
    private var storeSubscription: AnyCancellable?
    /// How many times the board store announced a change for the tag.
    var boardDeliveries: Int { storeChanges }

    init(_ testCase: XCTestCase, size: NSSize, hasRepl: Bool, script: TrackerBoardScript) {
        let tag = script.tag
        self.tag = tag
        self.script = script
        store = TrackerPaneFx.makeImmediateStore()
        approvals = ApprovalStore(send: { _, _, _ in }, report: { _, _, _ in }, schedule: { _, _ in })

        let suite = "TrackerWaitingStripTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        testCase.addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let clock = TrackerTickingClock()
        background = BackgroundTaskStore(now: { clock.next() }, schedule: { _, work in work() }, defaults: defaults)

        let paneClock = TrackerManualClock(TrackerPaneFx.now)
        let log = actions
        pane = TrackerPaneView(tag: tag, store: store, decisions: decisions, approvals: approvals,
                               background: background,
                               actions: TrackerWaitingActions(showApprovals: { log.recordApprovals($0) }),
                               now: { paneClock.date }, reduceMotion: { true },
                               pasteboard: rigPrivatePasteboard(testCase), schedule: { _, _ in },
                               timeZone: TrackerPaneFx.utc, tickInterval: nil)
        let hostSize = NSSize(width: size.width, height: size.height + TrackerPaneFx.hostPadding)
        window = makeRigWindow(testCase, size: hostSize)
        host = RigFlippedDoc(frame: NSRect(origin: .zero, size: hostSize))
        pane.frame = NSRect(origin: .zero, size: size)
        composer.frame = NSRect(x: 0, y: size.height + 3, width: size.width, height: 28)
        host.addSubview(pane)
        host.addSubview(composer)
        window.contentView = host
        if hasRepl {
            let repl = self.repl
            pane.replProvider = { repl }
        }
        window.makeFirstResponder(composer)
        storeSubscription = store.changes.filter { $0 == tag }.sink { [weak self] _ in self?.storeChanges += 1 }
        settle()
    }

    static func make(_ testCase: XCTestCase, size: NSSize = NSSize(width: 360, height: 420), hasRepl: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line,
                     board: (String) throws -> TrackerBoardScript = { try WSFx.quiet(tag: $0) }) throws -> WSRig {
        let rig = WSRig(testCase, size: size, hasRepl: hasRepl, script: try board(TrackerPaneFx.uniqueTag()))
        rig.pushBoard()
        return rig
    }

    // MARK: Driving

    func settle() {
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
    }

    /// Lets deliveries that hop to the main queue land, then lays out.
    func settleAsync() {
        rigSettle(0.05)
        settle()
    }

    func pushBoard(file: StaticString = #filePath, line: UInt = #line) {
        do {
            store.ingest(try script.message())
        } catch {
            XCTFail("could not decode the board: \(error)", file: file, line: line)
        }
        settleAsync()
    }

    func edit(_ change: (inout TrackerBoardScript) throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do {
            try change(&script)
        } catch {
            return XCTFail("could not edit the board: \(error)", file: file, line: line)
        }
        pushBoard(file: file, line: line)
    }

    func ingestTasks(_ tasks: [TaskMetaWire]) {
        background.ingest(.sessionTasks(SessionTasksWire(tag: tag, daemonEpoch: "e1", tasks: tasks)))
        settleAsync()
    }

    func markSeen() {
        background.markSeen(tag: tag)
        settleAsync()
    }

    func addDecision(_ id: String, _ text: String = "Ship it?") {
        decisions.add(id, text, tag: tag)
        settleAsync()
    }

    func answerDecision(_ id: String) {
        decisions.answer(id, tag: tag)
        settleAsync()
    }

    func addApproval(_ id: String, command: String = "rm -rf build/") throws {
        approvals.handle(.request(try ApprovalTestRequests.bash(command, id: id, tag: tag,
                                                               description: "\(WSFx.sentinel)_DESC")))
        settleAsync()
    }

    func clearApprovals() {
        approvals.handle(.snapshot([]))
        settleAsync()
    }

    // MARK: Reading

    var entries: [TrackerWaitingEntry] { pane.strip.strip.entries }
    var entryKeys: [String] { WSFx.keys(entries) }
    var title: String { pane.strip.strip.title }
    var summaryRow: TrackerBackgroundRow { pane.backgroundRow }

    // MARK: Clicking

    private func click(_ view: NSView) {
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 6, y: 6), modifierFlags: [],
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: event)
    }

    func clickEntry(_ key: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let row = pane.strip.entryRows.first(where: { $0.entry.key == key }) else {
            return XCTFail("no strip row \(key); rows: \(pane.strip.entryRows.map(\.entry.key))", file: file, line: line)
        }
        click(row)
        settleAsync()
    }

    func clickSummary() {
        click(pane.backgroundRow)
        settleAsync()
    }

    // MARK: Scrolling and where things are

    func scroll(to y: CGFloat) {
        pane.clipView.scroll(to: NSPoint(x: 0, y: y))
        pane.scrollView.reflectScrolledClipView(pane.clipView)
        settle()
    }

    func screenTop(of key: String) -> CGFloat? {
        pane.rowViews[key].map { $0.convert($0.bounds, to: nil).maxY }
    }

    func paneOwnsFirstResponder() -> Bool {
        guard let view = window.firstResponder as? NSView else { return false }
        return view === pane || view.isDescendant(of: pane)
    }

    /// Run `change` and assert that what the reader sees did not move: at the top of the board the
    /// pane stays at the top with the first row still first (at most 1 pt into it); anywhere else
    /// the row being read stays within 1 pt of where it was on screen; and when nothing above the
    /// scroll view changed height, the first visible row is the same one at the same offset. The
    /// pane never takes the keyboard.
    func assertNoMove(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                      _ change: () throws -> Void) rethrows {
        let before = pane.anchorSnapshot(windowIndex: 0)
        XCTAssertNotNil(before.firstVisible, "\(name): the pane has a first visible row", file: file, line: line)
        let readKey = before.firstVisible?.rowKey
        let screenBefore = readKey.flatMap(screenTop(of:))
        let chromeBefore = pane.scrollView.frame.minY
        let atTop = before.scrollY <= 0.5
        let responderBefore = window.firstResponder

        try change()
        settleAsync()

        let after = pane.anchorSnapshot(windowIndex: 0)
        if atTop && pane.scrollView.frame.minY != chromeBefore {
            XCTAssertLessThanOrEqual(after.scrollY, 0.5, "\(name): the pane left the top (scrollY \(after.scrollY))",
                                     file: file, line: line)
            XCTAssertEqual(after.firstVisible?.rowKey, readKey, "\(name): first visible row changed", file: file, line: line)
            XCTAssertLessThanOrEqual(after.firstVisible?.offsetPt ?? .infinity, 1, "\(name): scrolled into the first row",
                                     file: file, line: line)
        } else if let readKey, let screenBefore, let screenAfter = screenTop(of: readKey) {
            XCTAssertLessThanOrEqual(abs(screenAfter - screenBefore), 1,
                                     "\(name): the line being read (\(readKey)) moved on screen", file: file, line: line)
        } else {
            XCTFail("\(name): the first visible row \(readKey ?? "nil") is no longer shown", file: file, line: line)
        }
        if pane.scrollView.frame.minY == chromeBefore {
            XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey,
                           "\(name): first visible row changed", file: file, line: line)
            let drift = abs((after.firstVisible?.offsetPt ?? .infinity) - (before.firstVisible?.offsetPt ?? 0))
            XCTAssertLessThanOrEqual(drift, 1, "\(name): first visible row moved \(drift) pt", file: file, line: line)
        }
        XCTAssertFalse(paneOwnsFirstResponder(), "\(name): the tracker took keyboard focus", file: file, line: line)
        XCTAssertTrue(window.firstResponder === responderBefore,
                      "\(name): the first responder changed to \(String(describing: window.firstResponder))",
                      file: file, line: line)
    }
}

// MARK: - The strip

final class TrackerWaitingStripTests: MouseQueueTestCase {

    // MARK: PRD 49

    func testTheStripShowsDecisionsCommandsNeedsYouThenFailedTasksUnderTheirCount() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.addDecision("d1", "Ship the deploy?")
        rig.ingestTasks([WSFx.task("bg-failed", .failed, ended: 100), WSFx.task("bg-ok", .completed, ended: 100)])

        XCTAssertEqual(rig.entryKeys, ["decision:d1", "item:rotat-2702", "item:docum-1740", "item:backf-1777",
                                       "task:bg-failed"])
        XCTAssertEqual(rig.title, "Waiting on you (5)")
        XCTAssertTrue(rig.pane.strip.text.contains("Waiting on you (5)"), rig.pane.strip.text)
        XCTAssertFalse(rig.pane.strip.isHidden)
        XCTAssertEqual(rig.pane.strip.entryRows.count, 5, "one visible row each")
        XCTAssertEqual(rig.pane.strip.entryRows.map(\.entry.key), rig.entryKeys, "the rows are in the entries' order")
        XCTAssertTrue(rig.pane.strip.text.contains("Ship the deploy?"))
    }

    func testClickingTheDecisionEntryShowsThatRequestsSheetAndAnswersNothing() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.addDecision("d1")
        rig.addDecision("d2", "Which branch?")
        rig.clickEntry("decision:d2")
        XCTAssertEqual(rig.decisions.shown, ["d2"], "the existing presenter is asked for that request id")
        XCTAssertEqual(rig.decisions.pending[rig.tag]?.map(\.requestId), ["d1", "d2"], "clicking does not answer")
        XCTAssertEqual(Array(rig.entryKeys.prefix(2)), ["decision:d1", "decision:d2"])
    }

    func testAnsweringADecisionRemovesItsEntryWithinOneDelivery() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.addDecision("d1")
        XCTAssertEqual(rig.title, "Waiting on you (4)")
        XCTAssertTrue(rig.entryKeys.contains("decision:d1"))

        rig.decisions.answer("d1", tag: rig.tag)
        rig.settleAsync()
        XCTAssertFalse(rig.entryKeys.contains("decision:d1"))
        XCTAssertEqual(rig.title, "Waiting on you (3)")
        XCTAssertFalse(rig.pane.strip.text.contains("Ship it?"))
    }

    func testADecisionForAnotherFocusIsNotListed() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.decisions.add("other", "Not yours", tag: "some-other-focus")
        rig.settleAsync()
        XCTAssertFalse(rig.entryKeys.contains("decision:other"))
        XCTAssertEqual(rig.title, "Waiting on you (3)")
    }

    func testTickingACommandRemovesItsEntryAndTheRanCommandNeverHadOne() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        XCTAssertTrue(rig.entryKeys.contains("item:rotat-2702"))
        XCTAssertFalse(rig.entryKeys.contains("item:verif-1481"), "a ran command does not wait on anyone")

        rig.edit { try $0.updateItem(WSFx.commandItem) { $0["ran"] = true } }
        XCTAssertFalse(rig.entryKeys.contains("item:rotat-2702"))
        XCTAssertEqual(rig.title, "Waiting on you (2)")
    }

    func testANeedsYouItemMovedOnLeavesTheStrip() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.edit { try $0.setStatus("docum-1740", "in-progress") }
        XCTAssertEqual(rig.entryKeys, ["item:rotat-2702", "item:backf-1777"])
    }

    func testAnItemThatIsBothACommandAndNeedsYouIsOneEntry() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        rig.edit { script in
            try script.updateItem("docum-1740") { $0["kind"] = "command"; $0["ran"] = false }
        }
        XCTAssertEqual(rig.entryKeys.filter { $0 == "item:docum-1740" }.count, 1)
        XCTAssertEqual(rig.title, "Waiting on you (3)")
    }

    func testAFailedTaskLeavesTheStripWhenTheBackgroundListIsSeen() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        rig.ingestTasks([WSFx.task("bg", .failed, ended: 100)])
        XCTAssertEqual(rig.entryKeys, ["task:bg"])
        rig.markSeen()
        XCTAssertEqual(rig.entryKeys, [], "BA's own seen rule: it left the chip, so it leaves the strip")
        XCTAssertTrue(rig.pane.strip.isHidden || rig.pane.strip.preferredHeight == 0)
    }

    func testClickingAFailedTaskEntryOpensTheBackgroundListAndNothingElse() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        rig.ingestTasks([WSFx.task("bg", .failed, ended: 100)])
        rig.clickEntry("task:bg")
        XCTAssertEqual(rig.repl.opened, 1)
        XCTAssertEqual(rig.decisions.shown, [])
        XCTAssertEqual(rig.actions.approvals, [])
    }

    // MARK: Approvals

    func testApprovalsAreOneRowWithOnlyACountAndAClickShowsTheFocusCard() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        try rig.addApproval("req-a", command: "rm -rf \(WSFx.sentinel)/")
        XCTAssertEqual(rig.entryKeys, ["approvals"])
        XCTAssertEqual(rig.pane.strip.entryRows.first?.entry.text, "1 approval waiting")
        XCTAssertEqual(rig.title, "Waiting on you (1)")

        try rig.addApproval("req-b", command: "curl \(WSFx.sentinel)")
        try rig.addApproval("req-c", command: "mv \(WSFx.sentinel) /tmp")
        XCTAssertEqual(rig.entryKeys, ["approvals"], "still one row")
        XCTAssertEqual(rig.pane.strip.entryRows.first?.entry.text, "3 approvals waiting")
        XCTAssertEqual(rig.title, "Waiting on you (3)", "the count matches the sidebar pill")

        rig.clickEntry("approvals")
        XCTAssertEqual(rig.actions.approvals, [rig.tag], "the link goes to this focus's approval card")
        XCTAssertEqual(rig.decisions.shown, [])
    }

    func testNoToolInputOrAgentDescriptionAppearsAnywhereInThePane() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        try rig.addApproval("req-a", command: "rm -rf \(WSFx.sentinel)/")
        let texts = TrackerPaneFx.allTexts(in: rig.pane)
            + [rig.pane.strip.text, rig.pane.strip.toolTip ?? ""]
            + rig.pane.strip.entryRows.compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(texts.isEmpty)
        for text in texts {
            XCTAssertFalse(text.contains(WSFx.sentinel), "tool input or description leaked: \(text)")
        }
        XCTAssertTrue(rig.pane.strip.text.contains("1 approval waiting"))
    }

    func testResolvingEveryApprovalRemovesTheRow() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        try rig.addApproval("req-a")
        XCTAssertEqual(rig.entryKeys, ["approvals"])
        rig.clearApprovals()
        XCTAssertEqual(rig.entryKeys, [])
    }

    // MARK: Command entries scroll the pane

    func testClickingACommandEntryScrollsThePaneToThatItem() throws {
        let rig = try WSRig.make(self, size: NSSize(width: 360, height: 300)) { try WSFx.prd(tag: $0) }
        rig.scroll(to: 0)
        XCTAssertEqual(rig.pane.clipView.bounds.origin.y, 0, accuracy: 0.5, "setup: at the top")

        rig.clickEntry("item:\(WSFx.commandItem)")
        let view = try XCTUnwrap(rig.pane.rowViews["item:\(WSFx.commandItem)"])
        let maxY = max(rig.pane.documentView.frame.height - rig.pane.clipView.bounds.height, 0)
        let expected = min(max(view.frame.minY, 0), maxY)
        XCTAssertGreaterThan(expected, 100, "setup: the item is well down the board")
        XCTAssertEqual(rig.pane.clipView.bounds.origin.y, expected, accuracy: 1,
                       "the item's row is at the top of the viewport (within the clamp)")
        XCTAssertFalse(rig.paneOwnsFirstResponder(), "a scroll is not a focus change")
        XCTAssertEqual(rig.decisions.shown, [])
    }

    func testClickingANeedsYouEntryScrollsThePaneToThatItem() throws {
        let rig = try WSRig.make(self, size: NSSize(width: 360, height: 300)) { try WSFx.prd(tag: $0) }
        rig.scroll(to: 0)
        rig.clickEntry("item:backf-1777")
        let view = try XCTUnwrap(rig.pane.rowViews["item:backf-1777"])
        let maxY = max(rig.pane.documentView.frame.height - rig.pane.clipView.bounds.height, 0)
        XCTAssertEqual(rig.pane.clipView.bounds.origin.y, min(max(view.frame.minY, 0), maxY), accuracy: 1)
        XCTAssertGreaterThan(rig.pane.clipView.bounds.origin.y, 100)
    }

    func testAClickOnAnEntryNeverChangesTheBoard() throws {
        let rig = try WSRig.make(self) { try WSFx.prd(tag: $0) }
        let before = rig.store.board(for: rig.tag)
        let deliveries = rig.boardDeliveries
        rig.addDecision("d1")
        for key in rig.entryKeys { rig.clickEntry(key) }
        XCTAssertEqual(rig.store.board(for: rig.tag), before)
        XCTAssertEqual(rig.boardDeliveries, deliveries)
    }

    // MARK: Gate: the reader's position

    func testTheStripGrowingAndShrinkingNeverMovesTheReaderAtTheTop() throws {
        try runGate(startingAt: .top)
    }

    func testTheStripGrowingAndShrinkingNeverMovesTheReaderScrolledIntoTheBoard() throws {
        try runGate(startingAt: .mid)
    }

    private enum Start { case top, mid }

    private func runGate(startingAt start: Start) throws {
        let rig = try WSRig.make(self, size: NSSize(width: 380, height: 420)) { try WSFx.quiet(tag: $0) }
        XCTAssertEqual(rig.pane.strip.preferredHeight, 0, "setup: nothing waits")
        XCTAssertEqual(rig.pane.backgroundRow.preferredHeight, 0, "setup: no background work")
        switch start {
        case .top:
            rig.scroll(to: 0)
        case .mid:
            let frame = try XCTUnwrap(rig.pane.rowViews["section:next"]?.frame)
            rig.scroll(to: frame.minY + 10)
            XCTAssertGreaterThan(rig.pane.anchorSnapshot(windowIndex: 0).scrollY, 100, "setup: scrolled in")
        }

        // 0 -> 1
        rig.assertNoMove("0 -> 1 (a decision arrives)") { rig.decisions.add("d1", "Ship it?", tag: rig.tag) }
        XCTAssertGreaterThan(rig.pane.strip.preferredHeight, 0, "the strip appeared")
        XCTAssertEqual(rig.pane.strip.strip.count, 1)

        // 1 -> 5
        try rig.assertNoMove("1 -> 5 (two decisions, a needs-you item and an un-run command)") {
            rig.decisions.add("d2", "Which branch?", tag: rig.tag)
            rig.decisions.add("d3", "Which tag?", tag: rig.tag)
            try rig.script.setStatus("docum-1740", "needs-you")
            try rig.script.updateItem(WSFx.commandItem) { $0["kind"] = "command"; $0["ran"] = false }
            rig.store.ingest(try rig.script.message())
        }
        XCTAssertEqual(rig.pane.strip.strip.count, 5)

        // Past the visible lines: the rest fold into "+ N more", the count keeps them.
        try rig.assertNoMove("5 -> 6 (an approval)") { try rig.approvals.handle(.request(
            ApprovalTestRequests.bash("rm -rf build/", id: "req-a", tag: rig.tag))) }
        XCTAssertEqual(rig.pane.strip.strip.count, 6)

        // Only the title changes: the strip's height does not.
        try rig.assertNoMove("6 -> 7 (a second approval changes only the count)") { try rig.approvals.handle(.request(
            ApprovalTestRequests.bash("rm -rf dist/", id: "req-b", tag: rig.tag))) }
        XCTAssertEqual(rig.pane.strip.strip.count, 7)

        // The summary row: appears, changes, disappears.
        rig.assertNoMove("summary row appears") { rig.background.ingest(.sessionTasks(SessionTasksWire(
            tag: rig.tag, daemonEpoch: "e1", tasks: [WSFx.task("A", .running)]))) }
        XCTAssertGreaterThan(rig.pane.backgroundRow.preferredHeight, 0, "the summary row appeared")

        rig.assertNoMove("summary row changes (two running)") { rig.background.ingest(.sessionTasks(SessionTasksWire(
            tag: rig.tag, daemonEpoch: "e1", tasks: [WSFx.task("A", .running), WSFx.task("B", .running)]))) }
        XCTAssertTrue(rig.pane.backgroundRow.text.contains("2 running"), rig.pane.backgroundRow.text)

        rig.assertNoMove("tasks fail: the summary changes and failed tasks join the strip") {
            rig.background.ingest(.sessionTasks(SessionTasksWire(
                tag: rig.tag, daemonEpoch: "e1",
                tasks: [WSFx.task("A", .failed, ended: 10), WSFx.task("B", .failed, ended: 20)])))
        }
        XCTAssertTrue(rig.pane.backgroundRow.text.contains("2 failed"), rig.pane.backgroundRow.text)
        XCTAssertEqual(rig.pane.strip.strip.count, 9)

        rig.assertNoMove("summary row disappears once seen, and so do the failed tasks") { rig.background.markSeen(tag: rig.tag) }
        XCTAssertEqual(rig.pane.backgroundRow.preferredHeight, 0, "the summary row went")
        XCTAssertEqual(rig.pane.strip.strip.count, 7)

        // 7 -> 0
        try rig.assertNoMove("everything answered, ticked and resolved") {
            for id in ["d1", "d2", "d3"] { rig.decisions.answer(id, tag: rig.tag) }
            try rig.script.setStatus("docum-1740", "todo")
            try rig.script.updateItem(WSFx.commandItem) { $0["ran"] = true }
            rig.approvals.handle(.snapshot([]))
            rig.store.ingest(try rig.script.message())
        }
        XCTAssertEqual(rig.pane.strip.strip.count, 0)
        XCTAssertEqual(rig.pane.strip.preferredHeight, 0, "the strip went")
    }
}

// MARK: - The summary row (PRD 50)

final class TrackerBackgroundSummaryRowTests: MouseQueueTestCase {

    private enum Step {
        case snapshot([TaskMetaWire], chip: String)
        case seen(chip: String)
    }

    private typealias T = WSFx

    /// 25 snapshots: tasks start, finish, fail, are stopped, are housekeeping or not listed, and are seen.
    private func script() -> [Step] {
        let a1 = T.task("A", .running), b1 = T.task("B", .running)
        let h = T.task("H", .running, housekeeping: true)
        let c1 = T.task("C", .running, parent: "A")
        let aDone = T.task("A", .completed, ended: 10), bFailed = T.task("B", .failed, ended: 20)
        let cDone = T.task("C", .completed, ended: 30)
        let d1 = T.task("D", .running), dFailed = T.task("D", .failed, ended: 40)
        let dDone = T.task("D", .completed, ended: 40), eFailed = T.task("E", .failed, ended: 50)
        let fStopped = T.task("F", .stopped, ended: 60)
        let g1 = T.task("G", .running), gPaused = T.task("G", .paused), gWeird = T.task("G", .unknown("weird"))
        let gFailed = T.task("G", .failed, ended: 70)
        let shellFg = T.task("S", .failed, ended: 80, kind: .shell)
        let shellBg = T.task("S", .failed, ended: 80, kind: .shell, backgrounded: true)
        let ended1 = [aDone, bFailed, cDone]
        let ended2 = ended1 + [dFailed, eFailed]
        let hundred = (0..<100).map { T.task("W\($0)", .running) }
        return [
            .snapshot([], chip: "hidden"),
            .snapshot([a1], chip: "running"),
            .snapshot([a1, b1], chip: "running"),
            .snapshot([a1, b1, h], chip: "running"),
            .snapshot([a1, b1, c1], chip: "running"),
            .snapshot([aDone, b1, c1], chip: "running"),
            .snapshot([aDone, bFailed, c1], chip: "running"),
            .snapshot(ended1, chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot(ended1 + [d1], chip: "running"),
            .snapshot(ended1 + [dFailed], chip: "failed"),
            .snapshot(ended2, chip: "failed"),
            .snapshot(ended1 + [dDone, eFailed], chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot(ended2 + [fStopped], chip: "done"),
            .snapshot(ended2 + [fStopped, g1], chip: "running"),
            .snapshot(ended2 + [fStopped, gPaused], chip: "running"),
            .snapshot(ended2 + [fStopped, gWeird], chip: "running"),
            .snapshot(ended2 + [fStopped, gFailed, shellFg], chip: "failed"),
            .snapshot(ended2 + [fStopped, gFailed, shellBg], chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot([], chip: "hidden"),
            .snapshot([T.task("X", .running)], chip: "running"),
            .snapshot(hundred, chip: "running"),
            .snapshot([], chip: "hidden"),
        ]
    }

    func testTheRowSaysWhatTheChipSaysAtEveryStepOfAScriptedFixtureAndTheBoardIsNeverWritten() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        let boardBefore = try XCTUnwrap(rig.store.board(for: rig.tag))
        let deliveriesBefore = rig.boardDeliveries
        let steps = script()
        XCTAssertGreaterThanOrEqual(steps.count, 20)

        var visited = Set<String>()
        for (index, step) in steps.enumerated() {
            let expectedChip: String
            switch step {
            case .snapshot(let tasks, let chip):
                rig.ingestTasks(tasks)
                expectedChip = chip
            case .seen(let chip):
                rig.markSeen()
                expectedChip = chip
            }
            let chip = rig.background.list(for: rig.tag).chip
            XCTAssertEqual(chip.name, expectedChip, "step \(index): the fixture is what it says")
            XCTAssertEqual(rig.summaryRow.text, WSFx.summaryText(chip), "step \(index): the row reads the chip's numbers")
            XCTAssertEqual(rig.summaryRow.isHidden, chip == .hidden, "step \(index): hidden iff the chip is")
            XCTAssertEqual(rig.summaryRow.preferredHeight > 0, chip != .hidden, "step \(index): no height when hidden")
            visited.insert(chip.name)
        }
        XCTAssertEqual(visited, ["hidden", "running", "done", "failed"], "the fixture visits every chip state")

        XCTAssertEqual(rig.store.board(for: rig.tag), boardBefore, "no task was written to the board")
        XCTAssertEqual(rig.boardDeliveries, deliveriesBefore, "the board was not touched at all")
        XCTAssertEqual(try rig.script.decodedBoard(), boardBefore)
    }

    func testClickingTheRowOpensTheFocusesBackgroundList() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        rig.ingestTasks([WSFx.task("A", .running), WSFx.task("B", .running)])
        XCTAssertEqual(rig.summaryRow.text, "\u{25F7} 2 running in the background")
        XCTAssertTrue(rig.summaryRow.isEnabled)
        XCTAssertEqual(rig.repl.opened, 0)

        rig.clickSummary()
        XCTAssertEqual(rig.repl.opened, 1, "the focus's input bar was asked to show its popover")
        XCTAssertFalse(rig.paneOwnsFirstResponder())
    }

    func testTheRowListsNoTasks() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        rig.ingestTasks([WSFx.task("A", .running), WSFx.task("B", .running)])
        let texts = TrackerPaneFx.allTexts(in: rig.pane)
        XCTAssertFalse(texts.contains { $0.contains("work A") || $0.contains("work B") }, "no task titles: \(texts)")
        XCTAssertEqual(rig.entryKeys, [], "running tasks are not waiting on anyone")
    }

    func testWithoutAReplPaneTheRowIsDisabledWithATooltipAndAClickDoesNothing() throws {
        let rig = try WSRig.make(self, hasRepl: false) { try WSFx.quiet(tag: $0) }
        rig.ingestTasks([WSFx.task("A", .running)])
        XCTAssertFalse(rig.summaryRow.isHidden, "the numbers still show")
        XCTAssertEqual(rig.summaryRow.text, "\u{25F7} 1 running in the background")
        XCTAssertFalse(rig.summaryRow.isEnabled)
        XCTAssertFalse((rig.summaryRow.toolTip ?? "").isEmpty, "it says why")
        XCTAssertFalse(rig.summaryRow.accessibilityPerformPress())

        rig.clickSummary()   // nothing to open, and nothing breaks
        XCTAssertEqual(rig.repl.opened, 0)
        XCTAssertFalse(rig.paneOwnsFirstResponder())

        // The REPL appears (the focus view found it): the row is live.
        let repl = rig.repl
        rig.pane.replProvider = { repl }
        rig.settle()
        XCTAssertTrue(rig.summaryRow.isEnabled)
        XCTAssertNil(rig.summaryRow.toolTip)
        rig.clickSummary()
        XCTAssertEqual(rig.repl.opened, 1)
    }

    func testTheRowIsHiddenWhileThereIsNoBackgroundWork() throws {
        let rig = try WSRig.make(self) { try WSFx.quiet(tag: $0) }
        XCTAssertTrue(rig.summaryRow.isHidden)
        XCTAssertEqual(rig.summaryRow.preferredHeight, 0)
        rig.ingestTasks([WSFx.task("A", .completed, ended: 10)])
        XCTAssertEqual(rig.summaryRow.text, "\u{2713} 1 done in the background")
        rig.markSeen()
        XCTAssertTrue(rig.summaryRow.isHidden)
    }
}

// MARK: - DecisionCoordinator: what the strip is fed from

private final class WSSheet: DecisionSheetControlling {
    let decision: PendingDecision
    private let store: DecisionStore
    private let onAnswer: (String?) -> Void
    private(set) var closeReasons: [String] = []
    private(set) var isClosed = false
    var windowCompletion: (() -> Void)?

    init(decision: PendingDecision, store: DecisionStore, onAnswer: @escaping (String?) -> Void) {
        self.decision = decision
        self.store = store
        self.onAnswer = onAnswer
    }

    /// The operator taps a choice: claim the answer in the store, forward it once, end the sheet.
    func answer(_ choiceId: String) {
        guard !isClosed else { return }
        isClosed = true
        if store.claimAnswer(requestId: decision.requestId, record: .choice(choiceId)) { onAnswer(choiceId) }
        windowCompletion?()
    }

    func closeWithoutAnswering(reason: DecisionCloseReason) {
        switch reason {
        case .retargeting: closeReasons.append("retargeting")
        case .supersededElsewhere: closeReasons.append("supersededElsewhere")
        case .operatorChose: closeReasons.append("operatorChose")
        case .operatorDismissed: closeReasons.append("operatorDismissed")
        }
        guard !isClosed else { return }
        isClosed = true
        windowCompletion?()
    }
}

private final class WSWindow: DecisionHostWindow {
    var isVisibleNow: Bool
    var isKeyNow: Bool
    var frontOrder: Int
    var activeFocusTag: String?
    private(set) var shown: [WSSheet] = []

    init(visible: Bool = true, key: Bool = false, order: Int = 0, focus: String? = nil) {
        isVisibleNow = visible
        isKeyNow = key
        frontOrder = order
        activeFocusTag = focus
    }

    func showDecisionSheet(_ sheet: DecisionSheetControlling, completion: @escaping () -> Void) {
        guard let fake = sheet as? WSSheet else { return XCTFail("unexpected sheet type") }
        fake.windowCompletion = completion
        shown.append(fake)
    }

    var liveSheets: [WSSheet] { shown.filter { !$0.isClosed } }
}

private final class WSAttention: AttentionSink {
    func raiseAttention(tag: String, key: String) {}
    func clearAttention(key: String) {}
}

private final class WSCoordinatorRig {
    let store = DecisionStore()
    var windows: [WSWindow] = []
    private(set) var sheets: [WSSheet] = []
    private(set) var answers: [String] = []
    private(set) var changes: [String] = []
    private var subscription: AnyCancellable?
    private let attention = WSAttention()

    private(set) lazy var coordinator = DecisionCoordinator(
        store: store, attention: attention,
        windows: { [unowned self] in self.windows.map { $0 as DecisionHostWindow } },
        makeSheet: { [unowned self] decision, onAnswer in
            let sheet = WSSheet(decision: decision, store: self.store, onAnswer: onAnswer)
            self.sheets.append(sheet)
            return sheet
        },
        sendAnswer: { [unowned self] requestId, _ in self.answers.append(requestId) })

    init() {
        subscription = coordinator.changes.sink { [weak self] in self?.changes.append($0) }
    }

    static func decision(_ requestId: String, tag: String = "perri") -> PendingDecision {
        PendingDecision(tag: tag, requestId: requestId, prompt: "Submit review?", detail: nil,
                        choices: [DecisionChoiceWire(id: "approve", label: "Approve", detail: nil)],
                        contextPaneId: nil)
    }

    func pendingIds(_ tag: String) -> [String] { coordinator.pendingDecisions(tag: tag).map(\.requestId) }
}

final class TrackerDecisionFeedTests: XCTestCase {

    func testChangesFiresWithTheFocusTagWhenARequestArrives() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1", tag: "perri"))
        XCTAssertEqual(rig.changes, ["perri"])
        rig.coordinator.present(WSCoordinatorRig.decision("r2", tag: "teri"))
        XCTAssertEqual(rig.changes, ["perri", "teri"])
    }

    func testChangesFiresWhenARequestIsResolvedElsewhere() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        rig.coordinator.handleResolved(ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered",
                                                        choiceId: "approve"))
        XCTAssertEqual(rig.changes, ["perri", "perri"])
        XCTAssertEqual(rig.pendingIds("perri"), [])
    }

    func testChangesFiresWhenTheOperatorAnswersTheSheet() throws {
        let rig = WSCoordinatorRig()
        rig.windows = [WSWindow(key: true, focus: "perri")]
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        let sheet = try XCTUnwrap(rig.windows[0].liveSheets.first)
        sheet.answer("approve")
        XCTAssertEqual(rig.answers, ["r1"])
        XCTAssertEqual(rig.changes, ["perri", "perri"])
        XCTAssertEqual(rig.pendingIds("perri"), [])
    }

    func testAResolvedRequestThatReplaysIsNeitherListedNorAnnounced() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        rig.coordinator.handleResolved(ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered",
                                                        choiceId: "approve"))
        let announced = rig.changes.count
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        XCTAssertEqual(rig.pendingIds("perri"), [])
        XCTAssertEqual(rig.changes.count, announced)
    }

    func testPendingDecisionsAreOldestFirstAndOnlyForTheAskedTag() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1", tag: "perri"))
        rig.coordinator.present(WSCoordinatorRig.decision("r2", tag: "teri"))
        rig.coordinator.present(WSCoordinatorRig.decision("r3", tag: "perri"))
        rig.coordinator.present(WSCoordinatorRig.decision("r4", tag: "perri"))
        XCTAssertEqual(rig.pendingIds("perri"), ["r1", "r3", "r4"])
        XCTAssertEqual(rig.pendingIds("teri"), ["r2"])
        XCTAssertEqual(rig.pendingIds("nobody"), [])

        rig.coordinator.handleResolved(ResolvedDecision(tag: "perri", requestId: "r3", resolution: "answered",
                                                        choiceId: nil))
        XCTAssertEqual(rig.pendingIds("perri"), ["r1", "r4"], "order kept; the resolved one is gone")
    }

    func testARequestWithNoWindowYetIsStillPending() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        XCTAssertEqual(rig.pendingIds("perri"), ["r1"], "outstanding whether or not a sheet is up")
        XCTAssertEqual(rig.sheets.count, 0)
    }

    // MARK: reveal

    func testRevealPresentsAnOutstandingRequestThatHasNoSheetWithoutAnsweringIt() {
        let rig = WSCoordinatorRig()
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))   // no window: left outstanding
        let window = WSWindow(key: true, focus: "perri")
        rig.windows = [window]
        XCTAssertEqual(window.liveSheets.count, 0)

        rig.coordinator.reveal(requestId: "r1")
        XCTAssertEqual(window.liveSheets.count, 1, "its sheet is up now")
        XCTAssertEqual(window.liveSheets.first?.decision.requestId, "r1")
        XCTAssertEqual(rig.answers, [], "revealing never answers")
        XCTAssertEqual(rig.pendingIds("perri"), ["r1"], "still waiting on the operator")
    }

    func testRevealMovesTheSheetToTheBestWindowWithoutAnsweringIt() {
        let rig = WSCoordinatorRig()
        let elsewhere = WSWindow(key: true, focus: "teri")
        rig.windows = [elsewhere]
        rig.coordinator.present(WSCoordinatorRig.decision("r1", tag: "perri"))
        XCTAssertEqual(elsewhere.liveSheets.count, 1, "setup: on the only window there is")

        let asking = WSWindow(order: 1, focus: "perri")
        rig.windows = [elsewhere, asking]
        rig.coordinator.reveal(requestId: "r1")

        XCTAssertEqual(asking.liveSheets.count, 1, "now on the window showing the asking focus")
        XCTAssertEqual(elsewhere.liveSheets.count, 0)
        XCTAssertEqual(elsewhere.shown.first?.closeReasons, ["retargeting"], "closed as a move, not an answer")
        XCTAssertEqual(rig.answers, [])
        XCTAssertEqual(rig.pendingIds("perri"), ["r1"])
    }

    func testRevealWhenTheSheetIsAlreadyOnTheBestWindowChangesNothing() {
        let rig = WSCoordinatorRig()
        let window = WSWindow(key: true, focus: "perri")
        rig.windows = [window]
        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        rig.coordinator.reveal(requestId: "r1")
        XCTAssertEqual(window.shown.count, 1, "no second sheet")
        XCTAssertEqual(window.liveSheets.count, 1)
        XCTAssertEqual(window.shown.first?.closeReasons, [])
        XCTAssertEqual(rig.answers, [])
    }

    func testRevealOfAnUnknownOrFinishedRequestDoesNothing() {
        let rig = WSCoordinatorRig()
        let window = WSWindow(key: true, focus: "perri")
        rig.windows = [window]
        rig.coordinator.reveal(requestId: "ghost")
        XCTAssertEqual(window.shown.count, 0)

        rig.coordinator.present(WSCoordinatorRig.decision("r1"))
        rig.coordinator.handleResolved(ResolvedDecision(tag: "perri", requestId: "r1", resolution: "answered",
                                                        choiceId: "approve"))
        let shownBefore = window.shown.count
        rig.coordinator.reveal(requestId: "r1")
        XCTAssertEqual(window.shown.count, shownBefore, "a finished request is not shown again")
        XCTAssertEqual(rig.answers, [])
    }

    // MARK: The line the strip shows

    func testTheStripLineIsThePromptsFirstLineCutToFit() {
        XCTAssertEqual(DecisionPresenter.summaryLine(of: "Ship it?\nMore detail below"), "Ship it?")
        XCTAssertEqual(DecisionPresenter.summaryLine(of: ""), "Decision needed")
        let long = DecisionPresenter.summaryLine(of: String(repeating: "x", count: 300))
        XCTAssertLessThanOrEqual(long.count, 100)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
    }
}
