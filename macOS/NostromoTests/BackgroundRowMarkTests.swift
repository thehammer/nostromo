import XCTest
import AppKit
import Combine
import NostromoKit

// BA6c: the `◷` on a transcript row, "Open in Background Activity", and Show in Transcript.
//
// What a person sees and does, stated from outside:
//   * A tool-group row (and, in the Focus view, the activity row a call is folded into) shows `· ◷` while a
//     call it stands for started a background task that is not over (pending, running, paused). It appears
//     and goes in place the moment the store says so, never changes the row's 22 pt height, gives way to the
//     summary first, and is read by VoiceOver ("background task running", plus an "Open background task"
//     action). A click that both begins and ends on it opens the task; any other click toggles the row.
//   * A row, and a call's own header, offer "Open in Background Activity" whenever one of its calls started a
//     task the store knows (a finished one too): one item, or a submenu `<Kind>: <description>` for several.
//     The titles are one clean line of at most 60 characters whatever the description holds.
//   * Show in Transcript scrolls a pane's transcript to the item that stands for a call (the call itself, its
//     collapsed group's row, or its collapsed activity row), a third of the way down the viewport, without
//     expanding anything, and stops following the tail. It is offered only when the pane holds the call.
//
// Real views, a real `BackgroundTaskStore` (private defaults suite, injected clock, a scheduler this file runs
// by hand) and, for Show in Transcript, a real `ReplView` fed turns the way the daemon sends them. The store's
// `changes` is a synchronous subject, so "it hides when the task ends" is asserted right after the event.
// No wall clock, no real pasteboard / UserDefaults domain / ~/.nostromo, no daemon, no logging.

private typealias F = FoldFixtures
private typealias X = FocusFixtures

// MARK: - Support (internal: BackgroundScrollSafetyTests reuses the click helpers)

/// A mouse event at `point` (window coordinates).
func ba6cMouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                       windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                       pressure: type == .leftMouseDown ? 1 : 0)!
}

/// Press on `row` at `down` and release at `up` (both window coordinates), the way the window hands a click to
/// the row that took it.
func ba6cPress(_ row: NSView, in window: NSWindow, at down: NSPoint, releasedAt up: NSPoint) {
    row.mouseDown(with: ba6cMouseEvent(.leftMouseDown, at: down, in: window))
    row.mouseUp(with: ba6cMouseEvent(.leftMouseUp, at: up, in: window))
}

/// The middle of `view`, in window coordinates.
func ba6cCenter(of view: NSView) -> NSPoint {
    let rect = view.convert(view.bounds, to: nil)
    return NSPoint(x: rect.midX, y: rect.midY)
}

/// A click on the row's `◷`.
func ba6cClickMark(of row: FoldRowView, in window: NSWindow) {
    let point = ba6cCenter(of: row.backgroundField)
    ba6cPress(row, in: window, at: point, releasedAt: point)
}

/// Work the store asked its scheduler for, run when a test says so.
private final class BA6cDeferred {
    private var work: [() -> Void] = []

    var count: Int { work.count }

    func schedule(_ delay: TimeInterval, _ job: @escaping () -> Void) {
        work.append(job)
    }

    func runAll() {
        let due = work
        work = []
        due.forEach { $0() }
    }
}

/// A store over a private defaults suite with an injected clock, task builders that carry a `tool_use_id`, and a
/// binding that records which task a row asked to open.
final class BA6cWorld {
    let tag: String
    let clock: BA3UIClock
    let store: BackgroundTaskStore
    private let deferred: BA6cDeferred
    private(set) var opened: [String] = []

    init(_ testCase: XCTestCase, tag: String = "gate") {
        let deferred = BA6cDeferred()
        let clock = BA3UIClock()
        let suite = "BA6c-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        self.tag = tag
        self.deferred = deferred
        self.clock = clock
        self.store = BackgroundTaskStore(now: { clock.date }, schedule: { delay, work in deferred.schedule(delay, work) },
                                         defaults: defaults)
        testCase.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    }

    func binding() -> BackgroundRowBinding {
        BackgroundRowBinding(store: store, tag: tag, open: { [weak self] id in self?.opened.append(id) })
    }

    var deferredCount: Int { deferred.count }

    /// Run the deliveries the store held back (the 4 Hz coalescing window).
    func deliverDeferred() { deferred.runAll() }

    func stamp(_ secondsAgo: Double) -> UInt64 {
        UInt64(Int64((clock.start * 1000).rounded()) - Int64((secondsAgo * 1000).rounded()))
    }

    func task(_ id: String, call toolUseId: String?, _ description: String = "npm run dev",
              kind: TaskKindWire = .shell, status: TaskStatusWire = .running, startedAgo: Double = 5) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: description, toolUseId: toolUseId,
                     isBackgrounded: kind == .shell ? true : nil, status: status,
                     startedAtMs: stamp(startedAgo), endedAtMs: status.isTerminal ? stamp(1) : nil,
                     hasOutput: kind == .shell)
    }

    /// A `session_tasks` snapshot. The clock moves first; `advance: 0` stays inside the store's coalescing
    /// window, so the delivery waits for `deliverDeferred()`.
    func ingest(_ tasks: [TaskMetaWire], tag other: String? = nil, advance: TimeInterval = 1) {
        clock.advance(advance)
        store.ingest(.sessionTasks(SessionTasksWire(tag: other ?? tag, sessionId: "session-1", daemonEpoch: "epoch-1",
                                                    stopSupported: true, tasks: tasks)))
    }
}

/// Scalars that must never reach a menu title or tooltip: controls (C0, DEL, C1), bidi controls, line and
/// paragraph separators, zero-width and invisible fillers, tag characters.
private func ba6cIsForbidden(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0000 ... 0x001F, 0x007F ... 0x009F, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5,
         0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A ... 0x202E, 0x2060 ... 0x2069,
         0x2800, 0x3164, 0xFEFF, 0xFFA0, 0xE0000 ... 0xE007F:
        return true
    default:
        return false
    }
}

/// Hostile task descriptions (as NostromoKit's `HostileContent`, which this target cannot see): bidi, ANSI,
/// invisible fillers, line and paragraph separators, a 10 KB line, one grapheme of thousands of scalars, all at once.
private let ba6cHostileDescriptions: [String] = {
    let bidi = "safe\u{202E}evil\u{2066}iso\u{2067}rtl\u{2068}fsi\u{2069}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}tail"
    let ansi = "\u{1B}[31mred text\u{1B}[0m and \u{1B}[1;32mgreen\u{1B}[0m \u{1B}]8;;https://x\u{1B}\\label\u{1B}]8;;\u{1B}\\"
    let fillers = "a\u{034F}b\u{115F}c\u{1160}d\u{17B4}e\u{17B5}f\u{2800}g\u{3164}h\u{FFA0}i"
    let breaks = "before\u{2028}after\u{2029}tail\nline two\r\nthree\tfour\u{7F}five"
    let long = "echo " + String(repeating: "x", count: 10_240)
    let grapheme = "x" + String(repeating: "\u{0301}", count: 5_000)
    return [bidi, ansi, fillers, breaks, long, grapheme, ansi + bidi + fillers + breaks + long]
}()

// MARK: - Tests

final class BackgroundRowMarkTests: XCTestCase {

    private var w: BA6cWorld!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        w = BA6cWorld(self)
    }

    override func tearDown() {
        w = nil
        super.tearDown()
    }

    // MARK: Fixtures

    /// Settled Bash calls with these tool_use_ids.
    private func settledGroup(_ ids: [String]) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for id in ids {
            blocks.append(F.foldCall("Bash", id: id, summary: "cmd \(id)", full: F.bashInput("cmd \(id)")))
            blocks.append(F.foldResult(id: id))
        }
        return F.group(blocks)
    }

    /// Five kinds of call, so the summary reads `Ran 1 command, read 1 file, edited 1 file, +2 more` (long enough
    /// to truncate in a narrow pane). The first call is `toolu_a`.
    private func mixedGroup() -> ToolGroup {
        F.group([
            F.foldCall("Bash", id: "toolu_a", summary: "make", full: F.bashInput("make")), F.foldResult(id: "toolu_a"),
            F.foldCall("Read", id: "toolu_r", summary: "a.swift", full: F.jsonInput(["file_path": "a.swift"]), target: "a.swift"),
            F.foldResult(id: "toolu_r"),
            F.foldCall("Edit", id: "toolu_e", summary: "a.swift", full: F.jsonInput(["file_path": "a.swift"]), target: "a.swift"),
            F.foldResult(id: "toolu_e"),
            F.foldCall("Grep", id: "toolu_g", summary: "foo", full: F.jsonInput(["pattern": "foo"])), F.foldResult(id: "toolu_g"),
            F.foldCall("WebFetch", id: "toolu_w", summary: "https://example.com", full: F.jsonInput(["url": "https://example.com"])),
            F.foldResult(id: "toolu_w"),
        ])
    }

    private func makeRow(_ group: ToolGroup, binding: BackgroundRowBinding?, width: CGFloat = 600,
                         window provided: RigWindow? = nil) -> (RigWindow, ToolGroupRowView) {
        let window = provided ?? makeRigWindow(self, size: NSSize(width: 1000, height: 200))
        let row = ToolGroupRowView(group: group, isExpanded: false, payloadAvailable: true,
                                   reduceMotion: { false }, now: { F.at(0) }, backgroundTasks: binding)
        row.frame = NSRect(x: 20, y: 100, width: width, height: FoldRowView.height)
        window.contentView!.addSubview(row)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, row)
    }

    private func segment(of group: ToolGroup) -> ActivitySegment {
        ActivitySegment(key: "a:\(group.key)", members: [.group(group)])
    }

    private func makeHeader(_ group: ToolGroup, binding: BackgroundRowBinding?,
                            width: CGFloat = 600) -> (RigWindow, ActivityRowHeaderView) {
        let window = makeRigWindow(self, size: NSSize(width: 1000, height: 200))
        let header = ActivityRowHeaderView(segment: segment(of: group), isExpanded: false, payloadAvailable: true,
                                           reduceMotion: { false }, backgroundTasks: binding)
        header.frame = NSRect(x: 20, y: 100, width: width, height: FoldRowView.height)
        window.contentView!.addSubview(header)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, header)
    }

    /// In the Focus view: a message, two calls, then the latest message and the chip. The two calls fold into
    /// one activity row (collapsed by default). Their ids are `toolu_0` and `toolu_1`.
    private func activityTurn() -> ChatTurn {
        F.turn([X.message("before")] + F.run(2, prefix: "toolu_") + [X.message("conclusion"), F.chip()])
    }

    /// A message, then three calls after it: a top-level group row, collapsed in Focus. Ids `toolu_0`...
    private func groupTurn() -> ChatTurn {
        F.turn([X.message("before")] + F.run(3, prefix: "toolu_"))
    }

    private func turnView(_ turn: ChatTurn, folds: FoldResolver? = nil, binding: BackgroundRowBinding?) -> ChatTurnView {
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState(),
                                folds: folds, backgroundTasks: binding)
        view.setIslandWidth(900)
        return view
    }

    private func callData(_ id: String?) -> ToolCallData {
        guard case .toolCall(let data) = F.call("Bash", id: id, summary: "make") else { preconditionFailure("not a call") }
        return data
    }

    private func isShown(_ row: FoldRowView) -> Bool { !row.backgroundField.isHidden }

    private func openItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == "Open in Background Activity" }
    }

    @discardableResult
    private func invoke(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private func assertCleanLine(_ text: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.unicodeScalars.contains(where: ba6cIsForbidden),
                       "\(what): a control, bidi, invisible or escape scalar survived", file: file, line: line)
        XCTAssertFalse(text.contains("[31m") || text.contains("]8;;"), "\(what): an escape sequence's text survived", file: file, line: line)
        XCTAssertLessThanOrEqual(text.count, 60, "\(what): more than 60 characters", file: file, line: line)
        XCTAssertLessThanOrEqual(text.unicodeScalars.count, 60, "\(what): more than 60 scalars", file: file, line: line)
    }

    // MARK: - Store lookups

    func testTheTaskForACallIsTheNewestWithThatIdWhateverItsStatus() {
        w.ingest([
            w.task("old", call: "toolu_x", status: .completed, startedAgo: 300),
            w.task("newest", call: "toolu_x", status: .failed, startedAgo: 20),
            w.task("middle", call: "toolu_x", status: .running, startedAgo: 100),
            w.task("lone", call: "toolu_y", status: .stopped, startedAgo: 50),
        ])

        XCTAssertEqual(w.store.task(tag: w.tag, toolUseId: "toolu_x")?.id, "newest", "the newest wins, even though it is over")
        XCTAssertEqual(w.store.task(tag: w.tag, toolUseId: "toolu_y")?.id, "lone", "a task is found in any status")
    }

    func testNothingIsFoundForAnUnknownCallFocusOrEmptyList() {
        XCTAssertNil(w.store.task(tag: w.tag, toolUseId: "toolu_x"), "no snapshot yet")
        XCTAssertNil(w.store.runningTask(tag: w.tag, toolUseIds: ["toolu_x"]))

        w.ingest([w.task("job", call: "toolu_x"), w.task("nocall", call: nil)])

        XCTAssertEqual(w.store.task(tag: w.tag, toolUseId: "toolu_x")?.id, "job")
        XCTAssertNil(w.store.task(tag: w.tag, toolUseId: "toolu_unknown"))
        XCTAssertNil(w.store.task(tag: "another-focus", toolUseId: "toolu_x"), "tasks are per focus")
        XCTAssertNil(w.store.runningTask(tag: "another-focus", toolUseIds: ["toolu_x"]))
        XCTAssertNil(w.store.runningTask(tag: w.tag, toolUseIds: []))
        XCTAssertNil(w.store.runningTask(tag: w.tag, toolUseIds: ["toolu_unknown"]))
    }

    func testTheRunningTaskSkipsFinishedOnesAndTakesTheFirstOfTheIdsThatIsNotOver() {
        w.ingest([
            w.task("t1", call: "a", status: .completed),
            w.task("t2", call: "b", status: .running),
            w.task("t3", call: "c", status: .paused),
            w.task("t4", call: "d", status: .failed),
            w.task("t5", call: "e", status: .stopped),
        ])

        XCTAssertEqual(w.store.runningTask(tag: w.tag, toolUseIds: ["a", "b", "c"])?.id, "t2", "the finished one is skipped")
        XCTAssertEqual(w.store.runningTask(tag: w.tag, toolUseIds: ["c", "b"])?.id, "t3", "the ids' order decides, not the snapshot's")
        XCTAssertEqual(w.store.runningTask(tag: w.tag, toolUseIds: ["unknown", "c"])?.id, "t3", "an unknown id is skipped")
        XCTAssertNil(w.store.runningTask(tag: w.tag, toolUseIds: ["a", "d", "e"]), "every one of them is over")
    }

    func testPendingRunningPausedAndUnclassifiedTasksAreNotOverAndTheOthersAre() {
        let notOver: [TaskStatusWire] = [.pending, .running, .paused, .unknown("something-new")]
        let over: [TaskStatusWire] = [.completed, .failed, .stopped]
        for status in notOver {
            w.ingest([w.task("t", call: "a", status: status)])
            XCTAssertEqual(w.store.runningTask(tag: w.tag, toolUseIds: ["a"])?.id, "t", "\(status) is not over")
        }
        for status in over {
            w.ingest([w.task("t", call: "a", status: status)])
            XCTAssertNil(w.store.runningTask(tag: w.tag, toolUseIds: ["a"]), "\(status) is over")
            XCTAssertEqual(w.store.task(tag: w.tag, toolUseId: "a")?.id, "t", "but the task is still known")
        }
    }

    func testTheBindingListsOneTaskPerCallInOrderWithoutRepeats() {
        let binding = w.binding()
        w.ingest([w.task("t1", call: "a", status: .completed), w.task("t2", call: "b"), w.task("t3", call: "c")])

        XCTAssertEqual(binding.tasks(toolUseIds: ["c", "x", "a", "b"]).map(\.id), ["t3", "t1", "t2"], "in the calls' order; unknown ones left out")
        XCTAssertEqual(binding.tasks(toolUseIds: ["a", "a", "b", "a"]).map(\.id), ["t1", "t2"], "a task is listed once")
        XCTAssertTrue(binding.tasks(toolUseIds: []).isEmpty)
    }

    // MARK: - The mark on a tool-group row

    func testTheMarkShowsWhileAMemberCallsTaskIsNotOverAndHidesTheMomentItEnds() {
        let (_, row) = makeRow(settledGroup(["toolu_a", "toolu_b"]), binding: w.binding())
        XCTAssertFalse(isShown(row), "no task yet")
        XCTAssertNil(row.backgroundTaskId)

        let steps: [(TaskStatusWire, Bool)] = [(.running, true), (.completed, false), (.paused, true), (.failed, false),
                                               (.pending, true), (.stopped, false), (.running, true)]
        for (status, shown) in steps {
            w.ingest([w.task("job", call: "toolu_b", status: status)])
            XCTAssertEqual(isShown(row), shown, "\(status): shown = \(shown) as soon as the store says so")
            XCTAssertEqual(row.backgroundField.stringValue, shown ? "· \u{25F7}" : "", "\(status)")
            XCTAssertEqual(row.backgroundTaskId, shown ? "job" : nil, "\(status)")
        }
    }

    func testARowBuiltAfterTheTaskStartedShowsTheMarkAtOnceAndOneBuiltAfterItEndedDoesNot() {
        w.ingest([w.task("job", call: "toolu_a")])
        let (_, running) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        XCTAssertTrue(isShown(running))
        XCTAssertEqual(running.backgroundTaskId, "job")

        w.ingest([w.task("job", call: "toolu_a", status: .completed)])
        let (_, over) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        XCTAssertFalse(isShown(over))
    }

    func testATaskForAnotherCallNeverShowsTheMark() {
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())

        w.ingest([w.task("job", call: "toolu_other"), w.task("loose", call: nil)])

        XCTAssertFalse(isShown(row))
        XCTAssertEqual(row.backgroundField.stringValue, "")
    }

    func testAChangeForAnotherFocusLeavesTheRowAlone() {
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        w.ingest([w.task("job", call: "toolu_a")])
        XCTAssertTrue(isShown(row), "precondition")

        // The end of the task is held back by the store's 4 Hz window; another focus's delivery comes first.
        w.ingest([w.task("job", call: "toolu_a", status: .completed)], advance: 0)
        XCTAssertEqual(w.deferredCount, 1, "precondition: the store holds the delivery back")
        XCTAssertTrue(isShown(row), "precondition: nobody has told the row yet")
        w.store.changes.send("another-focus")
        XCTAssertTrue(isShown(row), "another focus's change is not this row's business")

        w.deliverDeferred()
        XCTAssertFalse(isShown(row), "its own focus's delivery is")
    }

    func testARowWithoutABindingNeverShowsTheMark() {
        w.ingest([w.task("job", call: "toolu_a")])
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: nil)

        XCTAssertFalse(isShown(row), "even though the store holds a running task for its call")
        w.ingest([w.task("job", call: "toolu_a", startedAgo: 3), w.task("other", call: "toolu_a", startedAgo: 1)])
        XCTAssertFalse(isShown(row))
        XCTAssertNil(row.backgroundTaskId)
        XCTAssertFalse(row.accessibilityLabel()?.contains("background task running") ?? false)
    }

    func testUpdatingTheRowToAnotherGroupReadsThatGroupsCalls() {
        w.ingest([w.task("job", call: "toolu_b")])
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        XCTAssertFalse(isShown(row), "precondition: its call has no task")

        row.update(group: settledGroup(["toolu_a", "toolu_b"]))
        XCTAssertTrue(isShown(row), "the call the group gained has one")

        row.update(group: settledGroup(["toolu_a"]))
        XCTAssertFalse(isShown(row), "and the group that lost it does not")
    }

    func testACallASubagentMadeShowsTheMarkOnTheAgentRowAndFollowsItsTask() throws {
        let turn = F.turn([F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
                           F.call("Bash", id: "toolu_sub", summary: "npm run dev", parent: "toolu_agent"),
                           F.result("started", id: "toolu_sub", parent: "toolu_agent"),
                           F.result("report", id: "toolu_agent")])
        let group = try XCTUnwrap(F.groups(of: turn).first)
        XCTAssertFalse(group.subagentBlocks.isEmpty, "precondition: the sub call hangs under the Agent call")
        let view = ToolGroupView(group: group, blocks: turn.blocks, contentAvailable: true, folds: FoldResolver(),
                                 isExpanded: false, backgroundTasks: w.binding())
        XCTAssertFalse(isShown(view.row), "precondition")

        w.ingest([w.task("job", call: "toolu_sub")])
        XCTAssertTrue(isShown(view.row), "the subagent's background task shows on the Agent's row")
        XCTAssertEqual(view.row.backgroundTaskId, "job")

        w.ingest([w.task("job", call: "toolu_sub", status: .completed)])
        XCTAssertFalse(isShown(view.row))
    }

    func testTwoRowsForTheSameCallInTwoWindowsBothFollowOneEvent() {
        let (_, first) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        let (_, second) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())

        w.ingest([w.task("job", call: "toolu_a")])
        XCTAssertTrue(isShown(first))
        XCTAssertTrue(isShown(second))

        w.ingest([w.task("job", call: "toolu_a", status: .completed)])
        XCTAssertFalse(isShown(first))
        XCTAssertFalse(isShown(second))
    }

    func testTheRowKeepsItsHeightAndTheMarkItsWidthWithAndWithoutTheMark() {
        for width in [CGFloat(220), CGFloat(900)] {
            let world = BA6cWorld(self)
            let (window, row) = makeRow(mixedGroup(), binding: world.binding(), width: width)
            let frame = row.frame
            let fitting = row.fittingSize.height
            XCTAssertEqual(FoldRowView.height, 22)
            XCTAssertEqual(frame.height, 22)
            XCTAssertFalse(isShown(row), "precondition")

            for (shown, tasks) in [(true, [world.task("job", call: "toolu_a")]),
                                   (false, [world.task("job", call: "toolu_a", status: .completed)]),
                                   (true, [world.task("job", call: "toolu_a")])] {
                world.ingest(tasks)
                window.contentView!.layoutSubtreeIfNeeded()
                let at = "\(shown ? "with" : "without") the mark at \(Int(width)) pt"
                XCTAssertEqual(isShown(row), shown, at)
                XCTAssertEqual(row.frame, frame, "\(at): the row's own frame is untouched")
                XCTAssertEqual(row.frame.height, 22, at)
                XCTAssertEqual(row.fittingSize.height, fitting, accuracy: 0.5, "\(at): the row asks for the same height")
                guard shown else { continue }
                let field = row.backgroundField
                let rect = row.convert(field.bounds, from: field)
                XCTAssertLessThanOrEqual(rect.maxX, row.bounds.maxX + 0.5, "\(at): the mark stays inside the row")
                XCTAssertGreaterThanOrEqual(rect.minX, row.bounds.minX, at)
                XCTAssertGreaterThanOrEqual(rect.minY, -0.5, "\(at): and inside its height")
                XCTAssertLessThanOrEqual(rect.maxY, 22.5, at)
                XCTAssertGreaterThan(rect.width, 0, at)
                XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 0.5,
                                            "\(at): the mark keeps its full width")
            }
        }
    }

    func testInANarrowRowTheSummaryTruncatesBeforeTheMarkAndInAWideOneNothingTruncates() {
        for (width, narrow) in [(CGFloat(220), true), (CGFloat(900), false)] {
            let world = BA6cWorld(self)
            world.ingest([world.task("job", call: "toolu_a")])
            let (window, row) = makeRow(mixedGroup(), binding: world.binding(), width: width)
            window.contentView!.layoutSubtreeIfNeeded()
            let summary = row.summaryField
            let field = row.backgroundField
            let at = "at \(Int(width)) pt"

            XCTAssertTrue(isShown(row), at)
            XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 0.5, "\(at): the mark is whole")
            let summaryRect = row.convert(summary.bounds, from: summary)
            let fieldRect = row.convert(field.bounds, from: field)
            XCTAssertLessThanOrEqual(summaryRect.maxX, fieldRect.minX + 0.5, "\(at): the summary ends before the mark begins")
            if narrow {
                XCTAssertLessThan(summary.frame.width, summary.intrinsicContentSize.width - 0.5, "\(at): the summary gave way")
            } else {
                XCTAssertGreaterThanOrEqual(summary.frame.width, summary.intrinsicContentSize.width - 0.5, "\(at): nothing needs to give way")
            }
        }
    }

    // MARK: Clicking the mark

    func testAClickThatBeginsAndEndsOnTheMarkOpensTheRunningTaskAndDoesNotToggleTheRow() {
        let (window, row) = makeRow(settledGroup(["toolu_a", "toolu_b"]), binding: w.binding())
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        w.ingest([w.task("done", call: "toolu_a", status: .completed), w.task("running", call: "toolu_b")])
        window.contentView!.layoutSubtreeIfNeeded()
        let point = ba6cCenter(of: row.backgroundField)
        XCTAssertTrue(row.hitTest(row.superview!.convert(point, from: nil)) === row, "the row, not the label, takes the press")

        ba6cClickMark(of: row, in: window)

        XCTAssertEqual(w.opened, ["running"], "the task that is not over, not the finished one")
        XCTAssertEqual(toggles, [], "a click on the mark is not a click on the row")
        XCTAssertFalse(row.isExpanded)
    }

    func testAClickElsewhereOnTheRowTogglesItAndOpensNothing() {
        let (window, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        w.ingest([w.task("job", call: "toolu_a")])
        window.contentView!.layoutSubtreeIfNeeded()
        let summary = ba6cCenter(of: row.summaryField)

        ba6cPress(row, in: window, at: summary, releasedAt: summary)

        XCTAssertEqual(toggles, [true])
        XCTAssertEqual(w.opened, [])
    }

    func testAPressOnTheMarkReleasedElsewhereDoesNothing() {
        let (window, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        w.ingest([w.task("job", call: "toolu_a")])
        window.contentView!.layoutSubtreeIfNeeded()

        ba6cPress(row, in: window, at: ba6cCenter(of: row.backgroundField), releasedAt: ba6cCenter(of: row.summaryField))

        XCTAssertEqual(w.opened, [])
        XCTAssertEqual(toggles, [])
    }

    func testAPressElsewhereReleasedOnTheMarkDoesNothing() {
        let (window, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        w.ingest([w.task("job", call: "toolu_a")])
        window.contentView!.layoutSubtreeIfNeeded()

        ba6cPress(row, in: window, at: ba6cCenter(of: row.summaryField), releasedAt: ba6cCenter(of: row.backgroundField))

        XCTAssertEqual(w.opened, [], "a press that began elsewhere is not a click on the mark")
        XCTAssertEqual(toggles, [], "and, ending far from where it began, not a click on the row either")
    }

    func testAClickWhereTheMarkWasTogglesOnceTheTaskIsOver() {
        let (window, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        w.ingest([w.task("job", call: "toolu_a")])
        window.contentView!.layoutSubtreeIfNeeded()
        let where_ = ba6cCenter(of: row.backgroundField)
        w.ingest([w.task("job", call: "toolu_a", status: .completed)])
        XCTAssertFalse(isShown(row), "precondition")

        ba6cPress(row, in: window, at: where_, releasedAt: where_)

        XCTAssertEqual(w.opened, [], "the task is over: there is nothing to open")
        XCTAssertEqual(toggles, [true], "it is an ordinary click on the row")
    }

    // MARK: VoiceOver

    func testTheMarkIsReadByVoiceOverAndOffersAnActionThatOpensTheTaskOnlyWhileItShows() {
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        func action() -> NSAccessibilityCustomAction? { row.accessibilityCustomActions()?.first { $0.name == "Open background task" } }
        let plain = row.accessibilityLabel()
        XCTAssertFalse(plain?.contains("background task running") ?? false)
        XCTAssertNil(action(), "nothing to open yet")

        w.ingest([w.task("job", call: "toolu_a")])

        XCTAssertTrue(row.accessibilityLabel()?.contains("background task running") ?? false, "the row's label says so")
        XCTAssertTrue(row.accessibilityLabel()?.hasPrefix(plain ?? "") ?? false, "after what it said before")
        XCTAssertEqual(row.backgroundField.accessibilityLabel(), "background task running", "VoiceOver reads words, not the glyph")
        XCTAssertNotNil(action())
        XCTAssertEqual(action()?.handler?(), true)
        XCTAssertEqual(w.opened, ["job"], "the action opens the task")

        w.ingest([w.task("job", call: "toolu_a", status: .completed)])

        XCTAssertEqual(row.accessibilityLabel(), plain, "the label is what it was")
        XCTAssertNil(action(), "the action is gone with the mark")
    }

    // MARK: - The mark on the activity row (Focus view)

    func testTheActivityRowAFocusTurnFoldsACallIntoShowsTheMarkAndHidesItWhenTheTaskEnds() {
        let view = turnView(activityTurn(), binding: w.binding())
        let rows = view.activityRowViews
        XCTAssertEqual(rows.count, 1, "precondition: Focus folds the calls into one activity row")
        XCTAssertTrue(rigAllSubviews(of: view).compactMap { $0 as? ToolGroupView }.isEmpty,
                      "precondition: no tool-group row exists, so only the activity row can show the mark")
        let header = rows[0].row
        XCTAssertFalse(isShown(header), "precondition")

        w.ingest([w.task("job", call: "toolu_1")])
        XCTAssertTrue(isShown(header), "the call is folded into the activity row, so the activity row carries the mark")
        XCTAssertEqual(header.backgroundField.stringValue, "· \u{25F7}")
        XCTAssertEqual(header.backgroundTaskId, "job")

        w.ingest([w.task("job", call: "toolu_1", status: .completed)])
        XCTAssertFalse(isShown(header))
    }

    /// A subagent's own background task (it ran `npm run dev` under the Agent call) is the commonest one there
    /// is. The group row counts the calls a subagent made as the row's own; the activity row, which is what the
    /// Focus view shows instead of that group row, must too, or the mark is missing exactly where it is wanted
    /// (and Show in Transcript, which stands for the sub call by the Agent call, lands on a row with no mark).
    func testTheActivityRowShowsTheMarkForACallASubagentMadeUnderACallFoldedIntoIt() throws {
        let turn = F.turn([X.message("before"),
                           F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
                           F.call("Bash", id: "toolu_sub", summary: "npm run dev", parent: "toolu_agent"),
                           F.result("started", id: "toolu_sub", parent: "toolu_agent"),
                           F.result("report", id: "toolu_agent"),
                           X.message("conclusion"), F.chip()])
        let view = turnView(turn, binding: w.binding())
        let header = try XCTUnwrap(view.activityRowViews.first?.row, "precondition: the Agent call is folded into an activity row")
        XCTAssertFalse(isShown(header), "precondition")

        w.ingest([w.task("job", call: "toolu_sub")])
        XCTAssertTrue(isShown(header), "the subagent's task shows on the activity row its Agent call is folded into")

        w.ingest([w.task("job", call: "toolu_sub", status: .completed)])
        XCTAssertFalse(isShown(header))
    }

    func testAnActivityRowWithoutABindingOrForAnotherCallShowsNothing() {
        w.ingest([w.task("job", call: "toolu_1")])
        let bare = turnView(activityTurn(), binding: nil)
        XCTAssertFalse(isShown(bare.activityRowViews[0].row))

        let (_, other) = makeHeader(settledGroup(["toolu_x"]), binding: w.binding())
        XCTAssertFalse(isShown(other))
    }

    func testTheActivityRowKeepsItsHeightAndTheMarkItsWidth() {
        for width in [CGFloat(220), CGFloat(900)] {
            let world = BA6cWorld(self)
            let (window, header) = makeHeader(mixedGroup(), binding: world.binding(), width: width)
            let frame = header.frame
            let fitting = header.fittingSize.height
            let at = "at \(Int(width)) pt"

            world.ingest([world.task("job", call: "toolu_a")])
            window.contentView!.layoutSubtreeIfNeeded()
            XCTAssertTrue(isShown(header), at)
            XCTAssertEqual(header.frame, frame, at)
            XCTAssertEqual(header.frame.height, 22, at)
            XCTAssertEqual(header.fittingSize.height, fitting, accuracy: 0.5, "\(at): same height asked for")
            let field = header.backgroundField
            let rect = header.convert(field.bounds, from: field)
            XCTAssertLessThanOrEqual(rect.maxX, header.bounds.maxX + 0.5, "\(at): inside the row")
            XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 0.5, "\(at): whole")
            let summaryRect = header.convert(header.summaryField.bounds, from: header.summaryField)
            XCTAssertLessThanOrEqual(summaryRect.maxX, rect.minX + 0.5, "\(at): the summary ends before the mark")

            world.ingest([world.task("job", call: "toolu_a", status: .completed)])
            window.contentView!.layoutSubtreeIfNeeded()
            XCTAssertFalse(isShown(header), at)
            XCTAssertEqual(header.frame, frame, at)
            XCTAssertEqual(header.fittingSize.height, fitting, accuracy: 0.5, at)
        }
    }

    func testAClickOnTheActivityRowsMarkOpensTheTaskAndAClickElsewhereTogglesIt() {
        let (window, header) = makeHeader(settledGroup(["toolu_a"]), binding: w.binding())
        var toggles: [Bool] = []
        header.onToggle = { toggles.append($0) }
        w.ingest([w.task("job", call: "toolu_a")])
        window.contentView!.layoutSubtreeIfNeeded()

        ba6cClickMark(of: header, in: window)
        XCTAssertEqual(w.opened, ["job"])
        XCTAssertEqual(toggles, [])

        let summary = ba6cCenter(of: header.summaryField)
        ba6cPress(header, in: window, at: summary, releasedAt: summary)
        XCTAssertEqual(toggles, [true])
        XCTAssertEqual(w.opened, ["job"], "the second click opened nothing")

        ba6cPress(header, in: window, at: ba6cCenter(of: header.backgroundField), releasedAt: summary)
        XCTAssertEqual(w.opened, ["job"], "a press on the mark released elsewhere opens nothing")
        XCTAssertEqual(toggles, [true])
    }

    func testTheActivityRowIsReadByVoiceOverWithTheMarkAndOffersTheOpenAction() {
        let (_, header) = makeHeader(settledGroup(["toolu_a"]), binding: w.binding())
        XCTAssertFalse(header.accessibilityLabel()?.contains("background task running") ?? false)

        w.ingest([w.task("job", call: "toolu_a")])
        XCTAssertTrue(header.accessibilityLabel()?.contains("background task running") ?? false)
        let action = header.accessibilityCustomActions()?.first { $0.name == "Open background task" }
        XCTAssertEqual(action?.handler?(), true)
        XCTAssertEqual(w.opened, ["job"])

        w.ingest([w.task("job", call: "toolu_a", status: .completed)])
        XCTAssertFalse(header.accessibilityLabel()?.contains("background task running") ?? false)
        XCTAssertNil(header.accessibilityCustomActions()?.first { $0.name == "Open background task" })
    }

    func testTheActivityRowReadsTheNewSegmentWhenItIsUpdated() {
        w.ingest([w.task("job", call: "toolu_b")])
        let (_, header) = makeHeader(settledGroup(["toolu_a"]), binding: w.binding())
        XCTAssertFalse(isShown(header), "precondition")

        header.update(segment: segment(of: settledGroup(["toolu_a", "toolu_b"])))

        XCTAssertTrue(isShown(header))
    }

    // MARK: - Open in Background Activity

    func testTheGroupRowMenuOffersOpenOnlyWhenACallOfTheRowMapsToAKnownTask() {
        let group = settledGroup(["toolu_a", "toolu_b"])
        let (_, row) = makeRow(group, binding: w.binding())
        XCTAssertNil(openItem(in: row.contextMenu()), "the store knows no task")

        w.ingest([w.task("elsewhere", call: "toolu_zzz")])
        XCTAssertNil(openItem(in: row.contextMenu()), "a task for another call")

        w.ingest([w.task("done", call: "toolu_b", status: .completed)])
        let menu = row.contextMenu()
        let item = openItem(in: menu)
        XCTAssertEqual(item?.title, "Open in Background Activity", "a finished task is still one to open")
        XCTAssertNil(item?.submenu, "one task: one item")
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Copy Commands") && titles.contains("Copy Summary"), "the row's other items are still there")

        let (_, bare) = makeRow(group, binding: nil)
        XCTAssertNil(openItem(in: bare.contextMenu()), "no binding, no item")
    }

    func testTheActivityRowMenuOffersOpenOnlyWhenACallFoldedIntoItMapsToAKnownTask() {
        let view = turnView(activityTurn(), binding: w.binding())
        let header = view.activityRowViews[0].row
        XCTAssertNil(openItem(in: header.contextMenu()))

        w.ingest([w.task("done", call: "toolu_0", status: .failed)])
        let menu = header.contextMenu()
        XCTAssertEqual(openItem(in: menu)?.title, "Open in Background Activity", "any status")
        XCTAssertTrue(menu.items.map(\.title).contains("Copy Summary"))

        let bare = turnView(activityTurn(), binding: nil)
        XCTAssertNil(openItem(in: bare.activityRowViews[0].row.contextMenu()))
    }

    func testACallsOwnMenuOffersOpenOnlyForACallThatStartedAKnownTask() {
        let call = ToolCallView(data: callData("toolu_a"), backgroundTasks: w.binding())
        XCTAssertNil(openItem(in: call.copyMenu()), "the store knows no task")

        w.ingest([w.task("other", call: "toolu_b")])
        XCTAssertNil(openItem(in: call.copyMenu()), "a task for another call")

        w.ingest([w.task("done", call: "toolu_a", status: .completed)])
        let menu = call.copyMenu()
        XCTAssertEqual(openItem(in: menu)?.title, "Open in Background Activity")
        XCTAssertTrue(menu.items.map(\.title).contains("Copy summary"), "the call's own items are still there")

        let bare = ToolCallView(data: callData("toolu_a"), backgroundTasks: nil)
        XCTAssertNil(openItem(in: bare.copyMenu()))
        let noId = ToolCallView(data: callData(nil), backgroundTasks: w.binding())
        XCTAssertNil(openItem(in: noId.copyMenu()), "a call with no tool_use_id maps to no task")
    }

    func testTheCallsInsideAnExpandedGroupOfATurnViewOfferTheirOwnTask() throws {
        let turn = groupTurn()
        let key = try XCTUnwrap(ba6cFirstGroupKey(turn))
        let view = turnView(turn, folds: FoldResolver(groupStates: [key: true]), binding: w.binding())
        w.ingest([w.task("job", call: "toolu_1")])

        let calls = rigAllSubviews(of: view).compactMap { $0 as? ToolCallView }
        XCTAssertEqual(calls.count, 3, "precondition: the open group built its calls")
        XCTAssertEqual(calls.map { openItem(in: $0.copyMenu()) != nil }, [false, true, false],
                       "the call that started the task offers it, the others do not")
    }

    func testSeveralTasksGiveASubmenuWithOneItemPerTaskInTheCallsOrder() throws {
        let group = settledGroup(["toolu_a", "toolu_b", "toolu_c"])
        let (_, row) = makeRow(group, binding: w.binding())
        w.ingest([w.task("t2", call: "toolu_b", "audit the repo", kind: .agent),
                  w.task("t1", call: "toolu_a", "dev server", status: .completed),
                  w.task("t3", call: "toolu_c", "watch CI", kind: .monitor)])

        let parent = try XCTUnwrap(openItem(in: row.contextMenu()))
        let items = try XCTUnwrap(parent.submenu, "several tasks: a submenu").items

        XCTAssertEqual(parent.title, "Open in Background Activity")
        XCTAssertEqual(items.map(\.title), ["Shell: dev server", "Agent: audit the repo", "Monitor: watch CI"])
        XCTAssertEqual(items.map(\.toolTip), ["dev server", "audit the repo", "watch CI"], "the tooltip is the description")
    }

    func testTheItemTargetsARetainedObjectOfItsOwnAndNotTheRow() throws {
        let (_, row) = makeRow(settledGroup(["toolu_a"]), binding: w.binding())
        w.ingest([w.task("job", call: "toolu_a")])

        // The menu is gone as soon as the statement ends; the item must still have its target.
        let item = try XCTUnwrap(openItem(in: row.contextMenu()))

        let target = try XCTUnwrap(item.target, "a menu item's target is weak: something has to keep it")
        XCTAssertTrue(target is BackgroundOpenMenu.Target)
        XCTAssertFalse(target === row, "never the responder chain's row: a split window has other panes' views in it")
        XCTAssertNotNil(item.action)
    }

    func testChoosingTheItemOpensThatTaskWhateverItsStatus() throws {
        let group = settledGroup(["toolu_a", "toolu_b"])
        let (_, row) = makeRow(group, binding: w.binding())
        w.ingest([w.task("done", call: "toolu_a", status: .completed)])
        XCTAssertTrue(invoke(try XCTUnwrap(openItem(in: row.contextMenu()))))
        XCTAssertEqual(w.opened, ["done"])

        w.ingest([w.task("done", call: "toolu_a", status: .completed), w.task("live", call: "toolu_b")])
        let items = try XCTUnwrap(openItem(in: row.contextMenu())?.submenu).items
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(invoke(items[1]))
        XCTAssertTrue(invoke(items[0]))
        XCTAssertEqual(w.opened, ["done", "live", "done"], "each item opens its own task")

        let call = ToolCallView(data: callData("toolu_b"), backgroundTasks: w.binding())
        XCTAssertTrue(invoke(try XCTUnwrap(openItem(in: call.copyMenu()))))
        XCTAssertEqual(w.opened.last, "live")
    }

    func testHostileDescriptionsStayOneCleanShortLineInTitlesAndTooltips() throws {
        let both = settledGroup(["toolu_a", "toolu_b"])
        let one = settledGroup(["toolu_a"])
        let (_, severalRow) = makeRow(both, binding: w.binding())
        let (_, singleRow) = makeRow(one, binding: w.binding())

        for (n, text) in ba6cHostileDescriptions.enumerated() {
            w.ingest([w.task("t1", call: "toolu_a", text, status: .completed), w.task("t2", call: "toolu_b", text, kind: .agent)])

            let items = try XCTUnwrap(openItem(in: severalRow.contextMenu())?.submenu, "case \(n)").items
            XCTAssertEqual(items.count, 2, "case \(n)")
            for (index, item) in items.enumerated() {
                assertCleanLine(item.title, "case \(n) submenu title \(index)")
                assertCleanLine(item.toolTip ?? "", "case \(n) submenu tooltip \(index)")
                XCTAssertTrue(item.title.hasPrefix(index == 0 ? "Shell: " : "Agent: "), "case \(n): the kind leads")
            }

            let single = try XCTUnwrap(openItem(in: singleRow.contextMenu()), "case \(n)")
            assertCleanLine(single.title, "case \(n) title")
            assertCleanLine(single.toolTip ?? "", "case \(n) tooltip")

            let call = ToolCallView(data: callData("toolu_a"), backgroundTasks: w.binding())
            let callItem = try XCTUnwrap(openItem(in: call.copyMenu()), "case \(n)")
            assertCleanLine(callItem.toolTip ?? "", "case \(n) call tooltip")
        }
    }

    // MARK: - Which item stands for a call

    private func locate(_ toolUseId: String, in turn: ChatTurn, folds: FoldResolver) -> String? {
        guard let index = ToolCallLocator.blockIndex(of: toolUseId, in: turn) else { return nil }
        return ToolCallLocator.itemKey(forBlock: index, in: turn, shape: FoldShape(turn), folds: folds)
    }

    func testACallInAnExpandedGroupIsItsOwnBlock() throws {
        let turn = groupTurn()
        let key = try XCTUnwrap(ba6cFirstGroupKey(turn))

        for folds in [FoldResolver(groupStates: [key: true]), FoldResolver(expandedByDefault: true)] {
            for id in ["toolu_0", "toolu_2"] {
                let index = try XCTUnwrap(ToolCallLocator.blockIndex(of: id, in: turn))
                XCTAssertEqual(locate(id, in: turn, folds: folds), "b\(index)", "\(id) in \(folds.mode)")
            }
        }
    }

    func testACallInACollapsedGroupIsStoodForByTheGroupRow() throws {
        let turn = groupTurn()
        let key = try XCTUnwrap(ba6cFirstGroupKey(turn))

        for id in ["toolu_0", "toolu_1", "toolu_2"] {
            XCTAssertEqual(locate(id, in: turn, folds: FoldResolver()), key, "\(id) in Focus, collapsed by default")
            XCTAssertEqual(locate(id, in: turn, folds: FoldResolver(groupStates: [key: false], expandedByDefault: true)), key,
                           "\(id) in All activity, collapsed explicitly")
        }
    }

    func testACallInACollapsedActivityRowIsStoodForByTheActivityRowWhateverItsGroupDoes() throws {
        let turn = activityTurn()
        let segmentKey = try XCTUnwrap(ba6cFirstActivityKey(turn))
        let groupKey = try XCTUnwrap(ba6cFirstGroupKey(turn))
        XCTAssertNotEqual(segmentKey, groupKey)

        for id in ["toolu_0", "toolu_1"] {
            XCTAssertEqual(locate(id, in: turn, folds: FoldResolver()), segmentKey, "\(id) in Focus")
            XCTAssertEqual(locate(id, in: turn, folds: FoldResolver(groupStates: [groupKey: true])), segmentKey,
                           "\(id): the row is what shows, though its group was left open")
        }
    }

    func testACallInAnOpenActivityRowIsStoodForByItsGroupRowOrItselfAsTheGroupStands() throws {
        let turn = activityTurn()
        let segmentKey = try XCTUnwrap(ba6cFirstActivityKey(turn))
        let groupKey = try XCTUnwrap(ba6cFirstGroupKey(turn))
        let index = try XCTUnwrap(ToolCallLocator.blockIndex(of: "toolu_1", in: turn))

        XCTAssertEqual(locate("toolu_1", in: turn, folds: FoldResolver(activityStates: [segmentKey: true])), groupKey,
                       "the lane is open, its group is not")
        XCTAssertEqual(locate("toolu_1", in: turn, folds: FoldResolver(groupStates: [groupKey: true], activityStates: [segmentKey: true])),
                       "b\(index)", "both open: the call itself")
        XCTAssertEqual(locate("toolu_1", in: turn, folds: FoldResolver(expandedByDefault: true)), "b\(index)", "All activity")
    }

    func testASubagentsCallIsStoodForByTheAgentCallItRanUnder() throws {
        let turn = F.turn([F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
                           F.call("Bash", id: "toolu_sub", summary: "grep -r foo", parent: "toolu_agent"),
                           F.result("foo.txt", id: "toolu_sub", parent: "toolu_agent"),
                           F.result("report", id: "toolu_agent")])
        let key = try XCTUnwrap(ba6cFirstGroupKey(turn))
        let agentIndex = try XCTUnwrap(ToolCallLocator.blockIndex(of: "toolu_agent", in: turn))

        XCTAssertEqual(locate("toolu_sub", in: turn, folds: FoldResolver()), key, "collapsed: the group row")
        XCTAssertEqual(locate("toolu_sub", in: turn, folds: FoldResolver(groupStates: [key: true])), "b\(agentIndex)",
                       "open: the Agent call's own block, not the sub call's")
        XCTAssertEqual(locate("toolu_sub", in: turn, folds: FoldResolver(expandedByDefault: true)),
                       locate("toolu_agent", in: turn, folds: FoldResolver(expandedByDefault: true)))
    }

    func testAnUnknownCallHasNoBlockAndTheNewestBlockOfARepeatedIdIsTheOneFound() {
        let turn = F.turn([F.call("Bash", id: "toolu_r", summary: "try"), F.result("failed", id: "toolu_r", isError: true),
                           F.call("Bash", id: "toolu_r", summary: "try again"), F.result("ok", id: "toolu_r")])

        XCTAssertNil(ToolCallLocator.blockIndex(of: "toolu_nope", in: turn))
        XCTAssertEqual(ToolCallLocator.blockIndex(of: "toolu_r", in: turn), 2, "the newest")
    }
}

// MARK: - Shape helpers

/// The key of the first tool group `FoldShape` finds in `turn` (also inside an activity row).
func ba6cFirstGroupKey(_ turn: ChatTurn) -> String? {
    func find(_ items: [FoldShape.Item]) -> String? {
        for item in items {
            switch item {
            case .group(let group): return group.key
            case .activity(_, let members): if let key = find(members) { return key }
            case .block, .message: continue
            }
        }
        return nil
    }
    return find(FoldShape(turn).items)
}

/// The key of the first activity row `FoldShape` finds in `turn`.
func ba6cFirstActivityKey(_ turn: ChatTurn) -> String? {
    for item in FoldShape(turn).items {
        if case .activity(let key, _) = item { return key }
    }
    return nil
}

// MARK: - Show in Transcript, on a real pane

/// A real `ReplView` over a private fold store, fed turns the way the daemon sends them: 40 tall turns, among them
/// one with three calls after its message (a group row; `vis_*`, turn 10), one more of the same shape (`grp_*`,
/// turn 20), one whose two calls fold into an activity row (`act_*`, turn 30) and a last one with a trailing group
/// (`end_*`, turn 39).
final class BackgroundRowMarkRevealTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    struct Pane {
        let repl: ReplView
        let window: NSWindow
        let tag: String
        let folds: FV4StoreWorld
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    private var client: NostromodClient { AppStore.shared.client }

    // MARK: The pane

    private func makePane() -> Pane {
        let folds = FV4StoreWorld(self)
        let tag = "ba6c-\(UUID().uuidString)"
        let window = FixedWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        let repl = fv4MakePane(tag: tag, store: folds.store, in: window)
        // A pane must never write a capture into the user's home.
        repl.renderWatch.captureDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ba6c-\(UUID().uuidString)", isDirectory: true)
        repl.renderWatch.visibilityOverride = true
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            repl.composerBar.backgroundPopover?.close()
            repl.renderWatch.visibilityOverride = false
            window.orderOut(nil)
            window.contentView = nil
        }
        let pane = Pane(repl: repl, window: window, tag: tag, folds: folds)
        settle(pane)
        return pane
    }

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let prose = String(repeating: "The transcript keeps a long paragraph of ordinary words so that each turn is tall enough to matter. ", count: 6)

    private func calls(_ prefix: String, _ count: Int) -> [DaemonTurnBlock] {
        (0 ..< count).flatMap { i -> [DaemonTurnBlock] in
            let id = "\(prefix)_\(i)"
            return [.toolCall(toolName: "Bash", inputSummary: "make \(id)", inputFull: "{\"command\":\"make \(id)\"}",
                              meta: DaemonToolMeta(toolUseId: id)),
                    .toolResult(content: "done \(id)", isError: false, meta: DaemonToolMeta(toolUseId: id))]
        }
    }

    private func turn(_ i: Int) -> DaemonTurn {
        let summary = DaemonTurnBlock.resultSummary(durationMs: 1_000, costUsd: 0.1, isError: false)
        var blocks: [DaemonTurnBlock] = [.text(Self.prose)]
        switch i {
        case 10: blocks += calls("vis", 3)
        case 20: blocks += calls("grp", 3)
        case 30: blocks += calls("act", 2) + [.text("The conclusion. " + Self.prose)]
        case 39: blocks += calls("end", 1)
        default: break
        }
        blocks.append(summary)
        return DaemonTurn(id: "turn-\(i)", userInput: "ba6c question \(i)",
                          timestamp: Self.iso.string(from: Self.base.addingTimeInterval(Double(i))),
                          blocks: blocks, isComplete: true)
    }

    private func deliverTurns(to pane: Pane, count: Int = 40) {
        client.messages.send(.sessionSpawned(tag: pane.tag, sessionId: "session-\(pane.tag)"))
        client.messages.send(.sessionTurns(tag: pane.tag, turns: (0 ..< count).map { turn($0) }))
        modelWaitUntil {
            self.pump(pane)
            return pane.repl.visibleTurnViewCount > 0
        }
        settle(pane)
    }

    private func pump(_ pane: Pane) {
        modelFlushMain(generations: 2)
        pane.window.contentView?.layoutSubtreeIfNeeded()
        pane.window.displayIfNeeded()
    }

    /// Run the pane's passes until the transcript stops moving (bounded in run-loop turns, not seconds).
    private func settle(_ pane: Pane) {
        var last: (CGFloat, CGFloat) = (.nan, .nan)
        var stable = 0
        for _ in 0 ..< 80 {
            pump(pane)
            let scroll = transcriptScroll(pane)
            let now = (scroll?.contentView.bounds.minY ?? 0, scroll?.documentView?.frame.height ?? 0)
            stable = now == last ? stable + 1 : 0
            last = now
            if stable >= 3 { return }
        }
    }

    // MARK: Reading the pane

    private func transcriptScroll(_ pane: Pane) -> NSScrollView? {
        rigAllSubviews(of: pane.repl).compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTextView) }
    }

    private func clipOrigin(_ pane: Pane) -> CGFloat { transcriptScroll(pane)?.contentView.bounds.minY ?? .nan }

    private func viewportHeight(_ pane: Pane) -> CGFloat { transcriptScroll(pane)?.contentView.bounds.height ?? .nan }

    private func turnViews(_ pane: Pane) -> [ChatTurnView] {
        guard let doc = transcriptScroll(pane)?.documentView else { return [] }
        return rigAllSubviews(of: doc).compactMap { $0 as? ChatTurnView }
    }

    /// Where `view`'s top edge is, measured from the top of the viewport.
    private func screenTop(of view: NSView, in pane: Pane) -> CGFloat {
        guard let scroll = transcriptScroll(pane), let doc = scroll.documentView else { return .nan }
        return doc.convert(view.bounds, from: view).minY - scroll.contentView.bounds.minY
    }

    private func sessionTurn(_ i: Int, in pane: Pane) -> ChatTurn? {
        AppStore.shared.session(for: pane.tag).turns.first { $0.userInput == "ba6c question \(i)" }
    }

    private func groupView(_ key: String, in pane: Pane) -> ToolGroupView? {
        turnViews(pane).compactMap { $0.groupView(forKey: key) }.first
    }

    private func following(_ pane: Pane) -> Bool { pane.repl.anchorSnapshot(windowIndex: 0).following }

    // MARK: - Where the transcript goes

    func testRevealingAVisibleCallPutsItsTopAThirdOfTheWayDownTheViewport() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        pane.folds.store.setMode(tag: pane.tag, .allActivity)
        settle(pane)
        XCTAssertTrue(following(pane), "precondition: the pane follows the tail")

        XCTAssertTrue(pane.repl.revealToolCall(toolUseId: "vis_1"))
        settle(pane)

        let key = try XCTUnwrap(sessionTurn(10, in: pane).flatMap(ba6cFirstGroupKey))
        let group = try XCTUnwrap(groupView(key, in: pane), "the turn with the call is built")
        XCTAssertTrue(group.isExpanded, "precondition: All activity shows the group open")
        let calls = group.memberViews.compactMap { $0 as? ToolCallView }
        XCTAssertEqual(calls.count, 3, "precondition: its calls are built")
        XCTAssertEqual(screenTop(of: calls[1], in: pane), viewportHeight(pane) / 3, accuracy: 1,
                       "the second call's header sits a third of the way down")
    }

    func testRevealingACallInACollapsedGroupShowsTheGroupRowAndExpandsNothing() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let target = try XCTUnwrap(sessionTurn(20, in: pane))
        let key = try XCTUnwrap(ba6cFirstGroupKey(target))
        pane.folds.store.setMode(tag: pane.tag, .allActivity)
        pane.folds.store.setFold(tag: pane.tag, key: key, turnKey: target.identityKey, open: false, origin: .user)
        settle(pane)
        let before = pane.folds.store.foldState(tag: pane.tag, key: key)
        XCTAssertEqual(before?.open, false, "precondition: the operator closed that group in All activity")

        XCTAssertTrue(pane.repl.revealToolCall(toolUseId: "grp_2"))
        settle(pane)

        let group = try XCTUnwrap(groupView(key, in: pane), "the group's turn is built")
        XCTAssertEqual(screenTop(of: group.row, in: pane), viewportHeight(pane) / 3, accuracy: 1, "its row is what is shown")
        XCTAssertFalse(group.isExpanded, "the group is still collapsed")
        XCTAssertTrue(group.memberViews.isEmpty, "no call or result was built for it")
        XCTAssertEqual(pane.folds.store.foldState(tag: pane.tag, key: key)?.open, false)
        XCTAssertEqual(pane.folds.store.foldState(tag: pane.tag, key: key)?.origin, before?.origin, "the fold state is untouched")
    }

    func testRevealingACallInACollapsedActivityRowShowsTheActivityRowAndExpandsNothing() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let target = try XCTUnwrap(sessionTurn(30, in: pane))
        let segmentKey = try XCTUnwrap(ba6cFirstActivityKey(target))
        XCTAssertNil(pane.folds.store.explicitMode(tag: pane.tag), "precondition: the focus is in its default mode, Focus")

        XCTAssertTrue(pane.repl.revealToolCall(toolUseId: "act_1"))
        settle(pane)

        let rows = turnViews(pane).flatMap { $0.activityRowViews }.filter { $0.segment.key == segmentKey }
        let row = try XCTUnwrap(rows.first, "the activity row's turn is built")
        XCTAssertEqual(screenTop(of: row, in: pane), viewportHeight(pane) / 3, accuracy: 1, "the activity row, a third of the way down")
        XCTAssertFalse(row.isExpanded, "it stays closed")
        XCTAssertNil(pane.folds.store.foldState(tag: pane.tag, key: segmentKey), "nothing was recorded as the operator's choice")
        XCTAssertNil(pane.folds.store.explicitMode(tag: pane.tag), "and the mode did not change")
    }

    func testRevealingACallThatIsNotInTheTranscriptReturnsFalseAndMovesNothing() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let origin = clipOrigin(pane)
        let snapshot = pane.repl.anchorSnapshot(windowIndex: 0)
        XCTAssertTrue(snapshot.following, "precondition: the pane follows the tail")

        XCTAssertFalse(pane.repl.revealToolCall(toolUseId: "toolu_not_here"))
        settle(pane)

        XCTAssertEqual(clipOrigin(pane), origin, accuracy: 0.5, "the transcript did not move")
        let after = pane.repl.anchorSnapshot(windowIndex: 0)
        XCTAssertTrue(after.following, "and it still follows the tail")
        XCTAssertEqual(after.bottomOffsetPt, snapshot.bottomOffsetPt, accuracy: 0.5)
        XCTAssertEqual(after.firstVisible?.turnKey, snapshot.firstVisible?.turnKey)
        XCTAssertFalse(pane.repl.canRevealToolCall(toolUseId: "toolu_not_here"))
    }

    func testARevealStopsFollowingTheTailAndTheViewportStaysWhereItWasPut() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        XCTAssertTrue(following(pane), "precondition")

        XCTAssertTrue(pane.repl.revealToolCall(toolUseId: "grp_0"))
        settle(pane)

        let after = pane.repl.anchorSnapshot(windowIndex: 0)
        XCTAssertFalse(after.following, "the operator asked to see something else")
        XCTAssertEqual(pane.repl.renderGeometry["followingTail"], 0)
        XCTAssertGreaterThan(after.bottomOffsetPt, Double(viewportHeight(pane)), "the viewport is well above the end of the transcript")
        let key = try XCTUnwrap(sessionTurn(20, in: pane).flatMap(ba6cFirstGroupKey))
        XCTAssertEqual(screenTop(of: try XCTUnwrap(groupView(key, in: pane)).row, in: pane), viewportHeight(pane) / 3, accuracy: 1)
    }

    func testRevealingACallAtTheEndOfTheTranscriptStopsAtTheBottom() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        XCTAssertTrue(pane.repl.canRevealToolCall(toolUseId: "end_0"))

        XCTAssertTrue(pane.repl.revealToolCall(toolUseId: "end_0"))
        settle(pane)

        let snapshot = pane.repl.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(snapshot.bottomOffsetPt, 0, accuracy: 1, "a third of the way down is past the end: the bottom is as far as it goes")
        let key = try XCTUnwrap(sessionTurn(39, in: pane).flatMap(ba6cFirstGroupKey))
        let top = screenTop(of: try XCTUnwrap(groupView(key, in: pane)).row, in: pane)
        XCTAssertGreaterThanOrEqual(top, 0, "the row is in the viewport")
        XCTAssertLessThan(top, viewportHeight(pane))
    }

    // MARK: - The pane's popover actions

    struct ActionsRig {
        let pane: Pane
        let tw: BA4TWWorld
        let actions: PaneBackgroundActions
        var store: BackgroundTaskStore { tw.world.store }

        func row(_ id: String, tag: String? = nil) -> BackgroundTaskRow? {
            store.list(for: tag ?? pane.tag).allRows.first { $0.id == id }
        }
    }

    private func makeActions(pane: Pane) -> ActionsRig {
        let tw = BA4TWWorld(self, tag: pane.tag, focusName: "Pane")
        let actions = PaneBackgroundActions(pane: pane.repl, base: BackgroundTaskWindowActions(manager: tw.manager), store: tw.world.store)
        return ActionsRig(pane: pane, tw: tw, actions: actions)
    }

    func testShowInTranscriptIsOfferedOnlyForACallThisPaneHoldsInItsOwnFocus() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let rig = makeActions(pane: pane)
        rig.tw.ingest([rig.tw.task("held", toolUseId: "grp_1"), rig.tw.task("gone", toolUseId: "toolu_not_in_transcript"),
                       rig.tw.task("nocall")])
        // The same task, known under another focus.
        rig.store.ingest(.sessionTasks(SessionTasksWire(tag: "another-focus", sessionId: "s", daemonEpoch: "e", stopSupported: true,
                                                        tasks: [rig.tw.task("held", toolUseId: "grp_1")])))
        let held = try XCTUnwrap(rig.row("held"))
        let gone = try XCTUnwrap(rig.row("gone"))
        let nocall = try XCTUnwrap(rig.row("nocall"))
        let elsewhere = try XCTUnwrap(rig.row("held", tag: "another-focus"))

        XCTAssertTrue(rig.actions.canShowInTranscript(held, tag: pane.tag), "this pane, a call it holds")
        XCTAssertFalse(rig.actions.canShowInTranscript(gone, tag: pane.tag), "a call that is not in the transcript")
        XCTAssertFalse(rig.actions.canShowInTranscript(nocall, tag: pane.tag), "a task that records no call")
        XCTAssertFalse(rig.actions.canShowInTranscript(elsewhere, tag: "another-focus"), "another focus's popover, though the call is here")
        XCTAssertFalse(rig.actions.canShowInTranscript(held, tag: "another-focus"), "a tag that is not this pane's")

        let orphan = PaneBackgroundActions(pane: nil, base: BackgroundTaskWindowActions(manager: rig.tw.manager), store: rig.store)
        XCTAssertFalse(orphan.canShowInTranscript(held, tag: pane.tag), "a pane that is gone cannot show anything")
    }

    func testShowInTranscriptMovesOnlyThePaneOfTheTasksOwnFocus() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let rig = makeActions(pane: pane)
        rig.tw.ingest([rig.tw.task("held", toolUseId: "grp_1")])
        rig.store.ingest(.sessionTasks(SessionTasksWire(tag: "another-focus", sessionId: "s", daemonEpoch: "e", stopSupported: true,
                                                        tasks: [rig.tw.task("held", toolUseId: "grp_1")])))
        let origin = clipOrigin(pane)

        rig.actions.showInTranscript(try XCTUnwrap(rig.row("held", tag: "another-focus")), tag: "another-focus")
        settle(pane)
        XCTAssertEqual(clipOrigin(pane), origin, accuracy: 0.5, "another focus's task does not move this pane")
        XCTAssertTrue(following(pane))

        rig.actions.showInTranscript(try XCTUnwrap(rig.row("held")), tag: pane.tag)
        settle(pane)
        let key = try XCTUnwrap(sessionTurn(20, in: pane).flatMap(ba6cFirstGroupKey))
        XCTAssertEqual(screenTop(of: try XCTUnwrap(groupView(key, in: pane)).row, in: pane), viewportHeight(pane) / 3, accuracy: 1)
        XCTAssertFalse(following(pane))
    }

    func testChoosingShowInTranscriptInThePanesPopoverClosesItAndThenMovesTheTranscript() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let rig = makeActions(pane: pane)
        rig.tw.ingest([rig.tw.task("held", toolUseId: "grp_1")])
        let bar = pane.repl.composerBar
        bar.bindBackground(tag: pane.tag, store: rig.store, displayName: "Pane")
        bar.backgroundActions = rig.actions
        let origin = clipOrigin(pane)

        bar.toggleBackgroundPopover(takeKeyboard: false)
        let popover = try XCTUnwrap(bar.backgroundPopover, "the popover opened")
        XCTAssertTrue(popover.isShown, "precondition")
        let row = try XCTUnwrap(popover.viewController.visibleRowViews.first { $0.row.id == "held" }).row
        let menu = popover.viewController.contextMenu(for: row)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Show in Transcript" }, "offered for a call the pane holds")

        menu.performActionForItem(at: index)
        settle(pane)

        XCTAssertFalse(popover.isShown, "the popover closes before the transcript moves")
        XCTAssertNotEqual(clipOrigin(pane), origin)
        XCTAssertFalse(following(pane))
        let key = try XCTUnwrap(sessionTurn(20, in: pane).flatMap(ba6cFirstGroupKey))
        XCTAssertEqual(screenTop(of: try XCTUnwrap(groupView(key, in: pane)).row, in: pane), viewportHeight(pane) / 3, accuracy: 1)
    }

    func testOpenAndStopAreForwardedToTheWindowActionsAndStopSendsNothingByItself() throws {
        let pane = makePane()
        deliverTurns(to: pane)
        let rig = makeActions(pane: pane)
        rig.tw.ingest([rig.tw.task("running", toolUseId: "grp_1"), rig.tw.task("over", status: .completed, toolUseId: "grp_2")])
        let running = try XCTUnwrap(rig.row("running"))
        let over = try XCTUnwrap(rig.row("over"))
        let base = BackgroundTaskWindowActions(manager: rig.tw.manager)

        XCTAssertEqual(rig.actions.canOpen(running, tag: pane.tag), base.canOpen(running, tag: pane.tag))
        XCTAssertTrue(rig.actions.canOpen(over, tag: pane.tag), "any row can be opened")
        XCTAssertTrue(rig.actions.canStop(running, tag: pane.tag), "a running task offers Stop")
        XCTAssertFalse(rig.actions.canStop(over, tag: pane.tag), "an ended one does not")

        rig.actions.open(running, tag: pane.tag)
        XCTAssertTrue(rig.tw.isOpen("running"), "Open opens the task's window")
        XCTAssertFalse(rig.tw.isOpen("over"))

        rig.actions.stop(running, tag: pane.tag)
        XCTAssertTrue(rig.tw.sender.stops.isEmpty, "Stop is a two-step the popover owns: this object sends nothing")
    }
}
