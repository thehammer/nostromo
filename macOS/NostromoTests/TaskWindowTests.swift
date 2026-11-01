import XCTest
import AppKit
import Combine
import NostromoKit

// BA4: a task's window, as the app's person sees it (plan acceptance criteria "Window", "Seam",
// "Memory", "Menu validation", and the window rows of "Opening a shell row ...").
//
// Everything is built from the outside: a real `BackgroundTaskStore` fed `session_tasks` frames, a
// `TaskWindowManager` over it with every seam injected (a private defaults suite, a private
// pasteboard, the visible screens, the key window, a recording sender instead of the daemon, a
// manual poll scheduler instead of timers), and real `TaskPanel`s ordered in. What is asserted is
// what the window does: that it opens once per task, stays through the popover closing, the task
// ending and Clear Context, closes without anything but itself changing, remembers where the user
// put it, and leaves nothing alive when it is gone.
//
// Windows are real but offscreen-safe: the panels are ordered front by the manager itself (that is
// the behaviour under test), the host windows are the shared `makeRigWindow` ones (animations off,
// closed in teardown). No wall clock beyond a few short run-loop spins, no real pasteboard, no
// real UserDefaults, no ~/.nostromo, no daemon.

// MARK: - Fakes (internal: BackgroundScrollSafetyTests reuses them)

/// A one-shot timer held by hand: live until it fires or is invalidated.
final class BA4TWPollTimer: TaskPollTimer {
    private(set) var isLive = true
    let delay: TimeInterval
    fileprivate let work: () -> Void

    init(delay: TimeInterval, work: @escaping () -> Void) {
        self.delay = delay
        self.work = work
    }

    func invalidate() { isLive = false }

    fileprivate func fire() {
        guard isLive else { return }
        isLive = false
        work()
    }
}

/// The model's `TaskPollScheduler`, recording every timer so "no timer is live" can be asserted.
final class BA4TWPollScheduler {
    private(set) var timers: [BA4TWPollTimer] = []

    var liveCount: Int { timers.filter { $0.isLive }.count }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> TaskPollTimer {
        timers.removeAll { !$0.isLive }
        let timer = BA4TWPollTimer(delay: delay, work: work)
        timers.append(timer)
        return timer
    }

    /// Fire every timer that is live now, oldest first (what they schedule waits for the next call).
    func fireLive() {
        for timer in timers.filter({ $0.isLive }) { timer.fire() }
    }
}

/// What `TaskRequests` sends to the daemon connection, recorded.
final class BA4TWSender: TaskRequestSending {
    struct Output {
        let requestId: String
        let tag: String
        let taskId: String
        let offset: UInt64?
        let maxBytes: UInt32
    }

    private(set) var outputs: [Output] = []
    private(set) var stops: [String] = []

    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        outputs.append(Output(requestId: requestId, tag: tag, taskId: taskId, offset: offset, maxBytes: maxBytes))
    }

    func sendTaskStop(requestId: String, tag: String, taskId: String) {
        stops.append(requestId)
    }
}

final class BA4TWCounter {
    private var value = 0
    func next() -> String {
        value += 1
        return "req-\(value)"
    }
}

/// What a focus's transcript holds, for agent windows.
final class BA4TWSource: SubagentTranscriptSource {
    var turns: [ChatTurn] = []
    let changes = PassthroughSubject<TurnChange, Never>()
}

/// Everything a task window needs, injected, plus a fake daemon that answers output requests from
/// `outputs` (ASCII only: a byte offset is a character offset).
final class BA4TWWorld {
    let tag: String
    let world: BA3UIWorld
    let pollScheduler: BA4TWPollScheduler
    let sender: BA4TWSender
    let requests: TaskRequests
    let registry: TaskOutputRegistry
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let source: BA4TWSource
    var screens: [NSRect]
    weak var keyWindow: NSWindow?
    private(set) var manager: TaskWindowManager!

    /// The text each task's file holds, by task id.
    var outputs: [String: String] = [:]
    /// Tasks whose output the daemon reports unavailable.
    var unavailable: Set<String> = []
    private var answered = 0

    /// The main screen's visible frame (a window placed inside it is never moved by AppKit), or a
    /// plain rectangle when the run has no screen.
    static func realScreen() -> NSRect {
        NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
    }

    init(_ testCase: XCTestCase, tag: String = "claudia", world sharedWorld: BA3UIWorld? = nil,
         keyWindow: NSWindow? = nil, screens: [NSRect]? = nil, focusName: String = "Claudia") {
        let world = sharedWorld ?? BA3UIWorld(testCase)
        let scheduler = BA4TWPollScheduler()
        let sender = BA4TWSender()
        let ids = BA4TWCounter()
        let requests = TaskRequests(makeRequestId: { ids.next() }, schedule: { _, _ in })
        requests.sender = sender
        let registry = TaskOutputRegistry(store: world.store, requests: requests,
                                          schedule: { delay, work in scheduler.schedule(delay, work) },
                                          now: { world.clock.date })
        let suite = "BA4TW-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("BA4TW-\(UUID().uuidString)"))

        self.tag = tag
        self.world = world
        self.pollScheduler = scheduler
        self.sender = sender
        self.requests = requests
        self.registry = registry
        self.defaults = defaults
        self.pasteboard = board
        self.source = BA4TWSource()
        self.screens = screens ?? [BA4TWWorld.realScreen()]
        self.keyWindow = keyWindow

        let source = self.source
        manager = TaskWindowManager(
            store: world.store, registry: registry,
            focusName: { _ in focusName },
            source: { _ in source },
            defaults: defaults, pasteboard: board,
            visibleScreens: { [weak self] in self?.screens ?? [] },
            keyWindow: { [weak self] in self?.keyWindow },
            now: { world.clock.date })

        let manager = self.manager!
        testCase.addTeardownBlock {
            manager.closeAll()
            defaults.removePersistentDomain(forName: suite)
            board.releaseGlobally()
        }
    }

    // MARK: Tasks

    func task(_ id: String, kind: TaskKindWire = .shell, _ description: String = "npm run build",
              status: TaskStatusWire = .running, toolUseId: String? = nil) -> TaskMetaWire {
        let ended = status.isTerminal
        return TaskMetaWire(id: id, kind: kind, description: description, toolUseId: toolUseId,
                            isBackgrounded: kind == .shell ? true : nil, status: status,
                            startedAtMs: world.stamp(5), endedAtMs: ended ? world.stamp(1) : nil,
                            hasOutput: kind == .shell || kind == .monitor)
    }

    /// A `session_tasks` snapshot. The clock moves first, past the store's coalescing window, so the
    /// change is delivered at once.
    func ingest(_ tasks: [TaskMetaWire], session: String = "session-1", advance: TimeInterval = 1) {
        world.clock.advance(advance)
        world.store.ingest(.sessionTasks(SessionTasksWire(tag: tag, sessionId: session, daemonEpoch: "epoch-1",
                                                          stopSupported: true, tasks: tasks)))
    }

    @discardableResult
    func open(_ taskId: String) -> TaskWindowController? {
        manager.open(tag: tag, taskId: taskId)
    }

    func isOpen(_ taskId: String) -> Bool {
        manager.isOpen(tag: tag, taskId: taskId)
    }

    // MARK: The fake daemon

    /// Answer every output request not yet answered, from `outputs`.
    func pump() {
        while answered < sender.outputs.count {
            let call = sender.outputs[answered]
            answered += 1
            let bytes = Array((outputs[call.taskId] ?? "").utf8)
            let total = bytes.count
            let start: Int
            let end: Int
            if let offset = call.offset {
                start = min(Int(offset), total)
                end = min(total, start + Int(call.maxBytes))
            } else {
                end = total
                start = max(0, total - Int(call.maxBytes))
            }
            let object: [String: Any] = [
                "type": "session_task_output_result", "request_id": call.requestId, "tag": call.tag,
                "task_id": call.taskId, "outcome": unavailable.contains(call.taskId) ? "unavailable" : "ok",
                "text": String(decoding: bytes[start ..< end], as: UTF8.self),
                "start_offset": start, "end_offset": end, "total_bytes": total, "source": "file",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let wire = try? JSONDecoder().decode(SessionTaskOutputResultWire.self, from: data) else {
                XCTFail("the fake daemon could not build an output answer")
                continue
            }
            requests.ingest(.sessionTaskOutputResult(wire))
        }
    }

    /// One poll round: the model's timers fire, the daemon answers.
    func poll() {
        pollScheduler.fireLive()
        pump()
    }
}

// MARK: - Tests

final class TaskWindowTests: XCTestCase {

    private var w: BA4TWWorld!

    private let shellKey = "nostromo.taskWindow.frame.shell"
    private let agentKey = "nostromo.taskWindow.frame.agent"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        w = BA4TWWorld(self)
    }

    override func tearDown() {
        w.manager.closeAll()
        w = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func escape() -> NSEvent { BA3UIKey.keyDown(BA3UIKey.escape) }

    private func commandPeriod() -> NSEvent { BA3UIKey.keyDown(47, ".", flags: .command) }

    private func savedFrame(_ key: String) -> NSRect? {
        w.defaults.string(forKey: key).map(NSRectFromString)
    }

    private func assertSameFrame(_ a: NSRect, _ b: NSRect, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.origin.x, b.origin.x, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(a.origin.y, b.origin.y, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(a.size.width, b.size.width, accuracy: 1, message, file: file, line: line)
        XCTAssertEqual(a.size.height, b.size.height, accuracy: 1, message, file: file, line: line)
    }

    private func drainRunLoop(times: Int = 5) {
        for _ in 0 ..< times {
            autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }
        }
    }

    /// A weak reference to something that should be gone.
    private struct Probe {
        let label: String
        weak var object: AnyObject?
        init(_ label: String, _ object: AnyObject) {
            self.label = label
            self.object = object
        }
    }

    private func probes(of controller: TaskWindowController, seen: inout Set<ObjectIdentifier>) -> [Probe] {
        var found: [Probe] = []
        func add(_ label: String, _ object: AnyObject) {
            if seen.insert(ObjectIdentifier(object)).inserted { found.append(Probe(label, object)) }
        }
        add("controller", controller)
        add("panel", controller.panel)
        add("body", controller.body)
        if let model = controller.model { add("model", model) }
        return found
    }

    // MARK: Opening, reusing, counting

    func testOpeningAShellRowOpensAWindow() throws {
        w.ingest([w.task("job0")])

        let controller = try XCTUnwrap(w.open("job0"))

        XCTAssertTrue(w.isOpen("job0"))
        XCTAssertEqual(w.manager.openCount, 1)
        XCTAssertTrue(controller.isOpen)
        XCTAssertTrue(controller.panel.isVisible, "the window is on screen")
        XCTAssertEqual(controller.focusTag, "claudia")
        XCTAssertEqual(controller.taskId, "job0")
    }

    func testOpeningAgainReturnsTheSameWindowAndTheCountStaysOne() throws {
        w.ingest([w.task("job0")])
        let first = try XCTUnwrap(w.open("job0"))

        let again = try XCTUnwrap(w.open("job0"))

        XCTAssertTrue(first === again, "the same instance, not a second window")
        XCTAssertEqual(w.manager.openCount, 1)
        XCTAssertTrue(w.manager.controller(tag: "claudia", taskId: "job0") === first)
    }

    func testOpeningAgainBringsAHiddenWindowBack() throws {
        w.ingest([w.task("job0")])
        let first = try XCTUnwrap(w.open("job0"))
        first.panel.orderOut(nil)
        XCTAssertFalse(first.panel.isVisible, "precondition")

        _ = w.open("job0")

        XCTAssertTrue(first.panel.isVisible, "opening a task that has a window shows that window")
        XCTAssertEqual(w.manager.openCount, 1)
    }

    func testTwoDifferentTasksGiveTwoWindows() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])

        let a = try XCTUnwrap(w.open("job0"))
        let b = try XCTUnwrap(w.open("job1"))

        XCTAssertFalse(a === b)
        XCTAssertFalse(a.panel === b.panel)
        XCTAssertEqual(w.manager.openCount, 2)
        XCTAssertTrue(a.isOpen && b.isOpen)
    }

    func testTheSameTaskIdInTwoFocusesGivesTwoWindows() throws {
        w.ingest([w.task("job0")])
        let other = BA4TWWorld(self, tag: "other-focus", world: w.world)
        other.ingest([other.task("job0")])

        let a = try XCTUnwrap(w.open("job0"))
        let b = try XCTUnwrap(w.manager.open(tag: "other-focus", taskId: "job0"))

        XCTAssertFalse(a === b, "a window belongs to a focus and a task, not to a task id")
        XCTAssertEqual(w.manager.openCount, 2)
    }

    func testATaskTheStoreDoesNotKnowOpensNothing() {
        w.ingest([w.task("job0")])

        XCTAssertNil(w.open("never-heard-of-it"))
        XCTAssertNil(w.manager.open(tag: "no-such-focus", taskId: "job0"))
        XCTAssertEqual(w.manager.openCount, 0)
    }

    // MARK: Staying open

    func testTheWindowSurvivesTheTaskEndingAndKeepsItsOutput() throws {
        w.ingest([w.task("job0")])
        w.outputs["job0"] = "building\nstill building\n"
        let controller = try XCTUnwrap(w.open("job0"))
        w.pump()
        let view = try XCTUnwrap(controller.body as? TaskOutputView)
        XCTAssertEqual(view.shownText, "building\nstill building\n", "precondition: the output is shown")

        w.ingest([w.task("job0", status: .completed)])
        w.pump()

        XCTAssertTrue(controller.isOpen, "the window did not go when the task ended")
        XCTAssertTrue(w.isOpen("job0"))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(view.header.statusText, "completed", "the header says how it ended")
        XCTAssertEqual(view.shownText, "building\nstill building\n", "its output is still readable")
        XCTAssertEqual(controller.model?.isTaskEnded, true)
    }

    func testTheWindowSurvivesClearContext() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))
        let title = controller.panel.title

        w.ingest([], session: "session-2")

        XCTAssertTrue(controller.isOpen, "Clear Context empties the list, not the window")
        XCTAssertTrue(w.isOpen("job0"))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.title, title, "a task the store no longer lists leaves the title alone")
        XCTAssertTrue(try XCTUnwrap(w.open("job0")) === controller, "opening it again still finds the window")
    }

    func testTheWindowSurvivesThePopoverClosing() throws {
        w.ingest(w.world.fixture())
        let host = ba3uiVisibleWindow(self)
        let anchor = NSView(frame: NSRect(x: 400, y: 14, width: 80, height: 26))
        host.contentView?.addSubview(anchor)
        var closed = 0
        let popover = BackgroundPopover(tag: w.tag, displayName: "Claudia", store: w.world.store,
                                        actions: BackgroundTaskWindowActions(manager: w.manager),
                                        pasteboard: w.pasteboard, schedule: { _, _ in return {} }, announce: { _ in })
        popover.onDidClose = { closed += 1 }
        addTeardownBlock { popover.close() }
        popover.show(relativeTo: anchor, takeKeyboard: false)
        XCTAssertTrue(popover.isShown, "precondition: the list is on screen")
        let row = try XCTUnwrap(popover.viewController.visibleRowViews.first { $0.row.id == "built" })

        row.onClick?(row)
        XCTAssertTrue(w.isOpen("built"), "precondition: the click opened the window")
        popover.close()
        modelWaitUntil { closed >= 1 }

        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(w.isOpen("built"), "the window outlives the list that opened it")
        XCTAssertTrue(w.manager.controller(tag: "claudia", taskId: "built")?.panel.isVisible ?? false)
    }

    // MARK: Closing

    func testAClosedWindowIsGoneFromTheManagerAndLetsGoOfItsModel() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))
        w.pump()
        let model = try XCTUnwrap(controller.model)
        XCTAssertEqual(model.holderCount, 1, "precondition: the window holds its output model")
        XCTAssertGreaterThan(w.pollScheduler.liveCount, 0, "precondition: polling runs while the window is open")

        controller.close()

        XCTAssertFalse(w.isOpen("job0"))
        XCTAssertNil(w.manager.controller(tag: "claudia", taskId: "job0"))
        XCTAssertEqual(w.manager.openCount, 0)
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertEqual(model.holderCount, 0, "nothing holds the model once the window is gone")
        XCTAssertEqual(w.pollScheduler.liveCount, 0, "polling stopped with the window")
    }

    func testClosingWithTheCloseButtonRemovesTheWindow() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))

        controller.panel.performClose(nil)

        XCTAssertFalse(w.isOpen("job0"), "the close button's path ends in the same place as close()")
        XCTAssertEqual(w.manager.openCount, 0)
    }

    func testReopeningATaskFindsTheOutputItAlreadyHeld() throws {
        w.ingest([w.task("job0")])
        w.outputs["job0"] = "first line\n"
        let first = try XCTUnwrap(w.open("job0"))
        w.pump()
        let model = try XCTUnwrap(first.model)
        first.close()

        let second = try XCTUnwrap(w.open("job0"))

        XCTAssertTrue(second.model === model, "one output model per task, shared by whoever opens it")
        XCTAssertEqual((second.body as? TaskOutputView)?.shownText, "first line\n", "the text is there at once")
    }

    func testNoTimerIsLiveOnceTheLastWindowCloses() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev"), w.task("job2", "cargo watch")])
        for id in ["job0", "job1", "job2"] { w.outputs[id] = "output of \(id)\n" }
        let controllers = try ["job0", "job1", "job2"].map { try XCTUnwrap(w.open($0)) }
        w.pump()
        w.outputs["job0"] = "output of job0\nmore\n"
        w.poll()
        XCTAssertGreaterThanOrEqual(w.pollScheduler.liveCount, 3, "precondition: every open window keeps polling")

        controllers[0].close()
        controllers[1].close()
        XCTAssertGreaterThanOrEqual(w.pollScheduler.liveCount, 1, "the last window still polls")
        controllers[2].close()

        XCTAssertEqual(w.manager.openCount, 0)
        XCTAssertEqual(w.pollScheduler.liveCount, 0, "no poll or coalescing timer outlives the last window")
    }

    func testClosingAFocusClosesItsWindowsAndDropsItsModelsAndLeavesTheOthers() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])
        let other = BA4TWWorld(self, tag: "other-focus", world: w.world)
        other.ingest([other.task("job0")])
        let mine0 = try XCTUnwrap(w.open("job0"))
        let mine1 = try XCTUnwrap(w.open("job1"))
        let theirs = try XCTUnwrap(w.manager.open(tag: "other-focus", taskId: "job0"))
        XCTAssertNotNil(w.registry.existingModel(tag: "claudia", taskId: "job0"), "precondition")
        XCTAssertNotNil(w.registry.existingModel(tag: "other-focus", taskId: "job0"), "precondition")

        w.manager.closeWindows(forFocus: "claudia")

        XCTAssertFalse(mine0.isOpen)
        XCTAssertFalse(mine1.isOpen)
        XCTAssertFalse(w.isOpen("job0"))
        XCTAssertFalse(w.isOpen("job1"))
        XCTAssertNil(w.registry.existingModel(tag: "claudia", taskId: "job0"), "the focus's models are dropped")
        XCTAssertNil(w.registry.existingModel(tag: "claudia", taskId: "job1"))
        XCTAssertTrue(theirs.isOpen, "another focus's window stays")
        XCTAssertTrue(w.manager.isOpen(tag: "other-focus", taskId: "job0"))
        XCTAssertNotNil(w.registry.existingModel(tag: "other-focus", taskId: "job0"), "and so does its model")
        XCTAssertEqual(w.manager.openCount, 1)
    }

    func testClosingAllClosesEveryWindow() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])
        let a = try XCTUnwrap(w.open("job0"))
        let b = try XCTUnwrap(w.open("job1"))

        w.manager.closeAll()

        XCTAssertEqual(w.manager.openCount, 0)
        XCTAssertFalse(a.isOpen)
        XCTAssertFalse(b.isOpen)
    }

    // MARK: What is in the window

    func testEachKindOfTaskGetsTheBodyThatSuitsIt() throws {
        w.ingest([w.task("shell", kind: .shell), w.task("monitor", kind: .monitor, "tail -f log"),
                  w.task("agent", kind: .agent, "Find callers", toolUseId: "toolu_agent"),
                  w.task("workflow", kind: .workflow, "release"), w.task("other", kind: .other, "something"),
                  w.task("mystery", kind: .unknown("mystery"), "from a newer daemon")])

        XCTAssertTrue(try XCTUnwrap(w.open("shell")).body is TaskOutputView)
        XCTAssertTrue(try XCTUnwrap(w.open("monitor")).body is TaskOutputView)
        XCTAssertTrue(try XCTUnwrap(w.open("agent")).body is SubagentTaskView)
        XCTAssertTrue(try XCTUnwrap(w.open("workflow")).body is TaskNoOutputView)
        XCTAssertTrue(try XCTUnwrap(w.open("other")).body is TaskNoOutputView)
        XCTAssertTrue(try XCTUnwrap(w.open("mystery")).body is TaskNoOutputView, "a kind this app does not know is never an empty window")
    }

    func testAWorkflowWindowSaysThereIsNoOutputForThatKindOfTask() throws {
        w.ingest([w.task("flow", kind: .workflow, "release")])

        let body = try XCTUnwrap(try XCTUnwrap(w.open("flow")).body as? TaskNoOutputView)

        XCTAssertEqual(body.messageText, "No output available for this kind of task")
        XCTAssertNil(try XCTUnwrap(w.open("flow")).model, "no output model for a task with no output")
    }

    func testAShellWindowShowsTheTasksOutput() throws {
        w.ingest([w.task("job0")])
        w.outputs["job0"] = "compiling\nlinking\n"

        let controller = try XCTUnwrap(w.open("job0"))
        w.pump()

        XCTAssertEqual((controller.body as? TaskOutputView)?.shownText, "compiling\nlinking\n")
    }

    // MARK: The panel

    func testThePanelIsATaskPanelAndNotAnApplicationWindow() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))

        XCTAssertTrue(controller.panel is TaskPanel)
        XCTAssertFalse(controller.panel is NostromoWindow, "NostromoWindow's close ends the app")
        XCTAssertFalse(controller.panel.delegate is NostromoWindow)
        XCTAssertTrue(controller.panel.delegate === controller, "the controller is the window's delegate")
    }

    func testThePanelOpensOverAFullScreenMainWindowInsteadOfSwitchingSpaces() throws {
        w.ingest([w.task("job0")])
        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.collectionBehavior.contains(.fullScreenPrimary), "it is not itself a full-screen window")
        XCTAssertFalse(panel.styleMask.contains(.fullScreen))
    }

    func testThePanelStaysAfterClosingAndWhenTheAppDeactivatesAndIsNotFloating() throws {
        w.ingest([w.task("job0")])
        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertFalse(panel.isReleasedWhenClosed, "the controller, not AppKit, ends the panel's life")
        XCTAssertFalse(panel.hidesOnDeactivate, "it does not vanish when another app is used")
        XCTAssertFalse(panel.isFloatingPanel, "it does not float over the other windows")
    }

    func testThePanelIsAnOrdinaryTitledResizableWindow() throws {
        w.ingest([w.task("job0")])
        let panel = try XCTUnwrap(w.open("job0")).panel

        for style: NSWindow.StyleMask in [.titled, .closable, .resizable, .miniaturizable] {
            XCTAssertTrue(panel.styleMask.contains(style), "missing style \(style)")
        }
        XCTAssertFalse(panel.styleMask.contains(.fullScreen))
        XCTAssertGreaterThanOrEqual(panel.minSize.width, 1)
    }

    func testThePanelIsDarkAqua() throws {
        w.ingest([w.task("job0")])
        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertEqual(panel.appearance?.name, .darkAqua)
        XCTAssertEqual(panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)
    }

    func testClosingTheWindowNeverTerminatesTheAppBecauseTheDelegateAgrees() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))

        XCTAssertTrue(controller.windowShouldClose(controller.panel), "the delegate path: closing is simply allowed")
    }

    // MARK: The title

    func testTheTitleNamesTheFocusTheKindAndTheDescription() throws {
        w.ingest([w.task("job0", "npm run build"),
                  w.task("agent", kind: .agent, "Write failing tests", toolUseId: "toolu_agent"),
                  w.task("flow", kind: .workflow, "release")])

        XCTAssertEqual(try XCTUnwrap(w.open("job0")).panel.title, "Claudia \u{00B7} Shell: npm run build")
        XCTAssertEqual(try XCTUnwrap(w.open("agent")).panel.title, "Claudia \u{00B7} Agent: Write failing tests")
        XCTAssertEqual(try XCTUnwrap(w.open("flow")).panel.title, "Claudia \u{00B7} Workflow: release")
    }

    func testTheTitleAndHeaderFollowTheTaskWhenTheStoreChanges() throws {
        w.ingest([w.task("job0", "step 0")])
        let controller = try XCTUnwrap(w.open("job0"))

        w.ingest([w.task("job0", "step 1")])

        XCTAssertEqual(controller.panel.title, "Claudia \u{00B7} Shell: step 1")
        XCTAssertEqual((controller.body as? TaskOutputView)?.header.descriptionText, "step 1")
    }

    func testFiftyUpdatesChangeTheTitleAndNothingAboutTheWindowsPlaceOrFocus() throws {
        w.ingest([w.task("job0", "step 0")])
        let controller = try XCTUnwrap(w.open("job0"))
        let other = makeRigWindow(self)
        other.makeKeyAndOrderFront(nil)
        let panel = controller.panel
        let frame = panel.frame
        let wasKey = panel.isKeyWindow
        let wasVisible = panel.isVisible

        for n in 1 ... 50 { w.ingest([w.task("job0", "step \(n)")]) }

        XCTAssertEqual(panel.title, "Claudia \u{00B7} Shell: step 50")
        XCTAssertEqual(panel.frame, frame, "an update never moves or resizes the window")
        XCTAssertEqual(panel.isKeyWindow, wasKey, "an update never makes it key (or takes key from it)")
        XCTAssertEqual(panel.isVisible, wasVisible)
    }

    func testStoreUpdatesNeverBringAHiddenWindowBack() throws {
        w.ingest([w.task("job0", "step 0")])
        let controller = try XCTUnwrap(w.open("job0"))
        controller.panel.orderOut(nil)
        XCTAssertFalse(controller.panel.isVisible, "precondition")

        for n in 1 ... 50 { w.ingest([w.task("job0", "step \(n)")]) }

        XCTAssertFalse(controller.panel.isVisible, "an update never orders a window front")
        XCTAssertEqual(controller.panel.title, "Claudia \u{00B7} Shell: step 50", "it still keeps its title current")
    }

    // MARK: Keyboard

    func testEscClosesTheWindowAndIsConsumed() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))

        let handled = controller.panel.performKeyEquivalent(with: escape())

        XCTAssertTrue(handled, "Esc is the window's")
        XCTAssertFalse(controller.isOpen)
        XCTAssertFalse(w.isOpen("job0"))
        XCTAssertFalse(controller.panel.isVisible)
    }

    func testCommandPeriodIsConsumedAndDoesNotCloseOrReachAMainWindow() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))

        let handled = controller.panel.performKeyEquivalent(with: commandPeriod())

        XCTAssertTrue(handled, "consumed here, so it can never reach a main window's Stop")
        XCTAssertTrue(controller.isOpen, "and it does not close the window")
        XCTAssertTrue(w.isOpen("job0"))
    }

    // MARK: Where the window goes

    func testPlacingAWindowDoesNotRememberAFrame() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])

        _ = try XCTUnwrap(w.open("job0"))
        _ = try XCTUnwrap(w.open("job1"))

        XCTAssertNil(w.defaults.string(forKey: shellKey), "only the user's moves are remembered, not our own placement")
    }

    func testAUserMoveIsRememberedForThatKindOnly() throws {
        w.ingest([w.task("job0"), w.task("agent", kind: .agent, "Explore", toolUseId: "toolu_agent")])
        let controller = try XCTUnwrap(w.open("job0"))
        let panel = controller.panel

        panel.setFrame(panel.frame.offsetBy(dx: 60, dy: -60), display: false)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

        let saved = try XCTUnwrap(savedFrame(shellKey), "a move while visible is remembered")
        assertSameFrame(saved, panel.frame, "the remembered frame is where the user left it")
        XCTAssertNil(w.defaults.string(forKey: agentKey), "each kind remembers its own")
    }

    func testAUserResizeIsRemembered() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))
        let panel = controller.panel
        var resized = panel.frame
        resized.size.width += 120
        resized.size.height += 80

        panel.setFrame(resized, display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))

        let saved = try XCTUnwrap(savedFrame(shellKey))
        assertSameFrame(saved, panel.frame, "the size the user chose is remembered")
    }

    func testAMoveOfAWindowThatIsNotOnScreenIsNotRemembered() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))
        controller.panel.orderOut(nil)

        controller.panel.setFrame(controller.panel.frame.offsetBy(dx: 40, dy: -40), display: false)
        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.panel))

        XCTAssertNil(w.defaults.string(forKey: shellKey), "written only for a window that is visible")
    }

    func testAMoveAfterTheWindowClosedIsNotRemembered() throws {
        w.ingest([w.task("job0")])
        let controller = try XCTUnwrap(w.open("job0"))
        controller.close()

        controller.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: controller.panel))
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: controller.panel))

        XCTAssertNil(w.defaults.string(forKey: shellKey))
    }

    func testTheNextWindowOfAKindOpensWhereTheLastOneWasLeft() throws {
        let screen = w.screens[0]
        let remembered = NSRect(x: screen.minX + 120, y: screen.minY + 120, width: 620, height: 420)
        w.defaults.set(NSStringFromRect(remembered), forKey: shellKey)
        w.ingest([w.task("job0")])

        let panel = try XCTUnwrap(w.open("job0")).panel

        assertSameFrame(panel.frame, remembered, "a remembered frame on a screen is used as it is")
    }

    func testAFrameRememberedOffEveryScreenFallsBackToTheCascade() throws {
        let screen = w.screens[0]
        let lost = NSRect(x: screen.maxX + 4_000, y: screen.maxY + 4_000, width: 600, height: 400)
        w.defaults.set(NSStringFromRect(lost), forKey: shellKey)
        w.ingest([w.task("job0")])

        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertNotEqual(panel.frame.origin, lost.origin, "it did not open where no screen is")
        XCTAssertTrue(screen.contains(panel.frame), "it opened wholly on a screen: \(panel.frame) vs \(screen)")
    }

    func testAFrameHalfOnAScreenIsClampedOntoIt() throws {
        let screen = w.screens[0]
        let half = NSRect(x: screen.maxX - 300, y: screen.minY + 100, width: 600, height: 400)
        w.defaults.set(NSStringFromRect(half), forKey: shellKey)
        w.ingest([w.task("job0")])

        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertTrue(screen.contains(panel.frame), "pulled wholly onto the screen it was half on: \(panel.frame) vs \(screen)")
        XCTAssertEqual(panel.frame.width, 600, accuracy: 1, "its size is kept when it fits")
        XCTAssertEqual(panel.frame.height, 400, accuracy: 1)
    }

    func testASecondWindowOfTheSameKindOpensOffsetFromTheFirst() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])

        let first = try XCTUnwrap(w.open("job0")).panel
        let second = try XCTUnwrap(w.open("job1")).panel

        XCTAssertGreaterThan(second.frame.minX, first.frame.minX, "down and to the right, so the first stays visible")
        XCTAssertLessThan(second.frame.maxY, first.frame.maxY)
    }

    func testASecondWindowOpensOffsetFromARememberedFrameToo() throws {
        w.ingest([w.task("job0"), w.task("job1", "pnpm dev")])
        let first = try XCTUnwrap(w.open("job0"))
        first.panel.setFrame(first.panel.frame.offsetBy(dx: 30, dy: -30), display: false)
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: first.panel))

        let second = try XCTUnwrap(w.open("job1")).panel

        XCTAssertGreaterThan(second.frame.minX, first.panel.frame.minX)
        XCTAssertLessThan(second.frame.maxY, first.panel.frame.maxY)
        assertSameFrame(try XCTUnwrap(savedFrame(shellKey)), first.panel.frame,
                        "placing the second window did not replace what the user's move saved")
    }

    func testTheCascadeFollowsTheKeyWindowWhenThereIsNothingRemembered() throws {
        let screen = w.screens[0]
        let host = makeRigWindow(self, size: NSSize(width: 500, height: 300))
        host.setFrame(NSRect(x: screen.minX + 200, y: screen.maxY - 650, width: 500, height: 600), display: false)
        w.keyWindow = host
        w.ingest([w.task("job0")])

        let panel = try XCTUnwrap(w.open("job0")).panel

        XCTAssertGreaterThan(panel.frame.minX, host.frame.minX, "just inside the key window's corner")
        XCTAssertLessThan(panel.frame.maxY, host.frame.maxY)
    }

    // MARK: Frames (pure)

    func testTheFrameKeyIsPerKind() {
        XCTAssertEqual(TaskWindowFrame.defaultsKey(kind: .shell), "nostromo.taskWindow.frame.shell")
        XCTAssertEqual(TaskWindowFrame.defaultsKey(kind: .monitor), "nostromo.taskWindow.frame.monitor")
        XCTAssertEqual(TaskWindowFrame.defaultsKey(kind: .agent), "nostromo.taskWindow.frame.agent")
        XCTAssertEqual(TaskWindowFrame.defaultsKey(kind: .workflow), "nostromo.taskWindow.frame.workflow")
        XCTAssertEqual(TaskWindowFrame.defaultsKey(kind: .other), "nostromo.taskWindow.frame.other")
    }

    func testClampKeepsAFrameThatAlreadyFits() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let frame = NSRect(x: 100, y: 100, width: 600, height: 400)

        XCTAssertEqual(TaskWindowFrame.clamp(frame, to: [screen]), frame)
    }

    func testClampPutsAFrameOnTheScreenItOverlapsMost() {
        let left = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = NSRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let straddling = NSRect(x: 900, y: 100, width: 400, height: 300)

        let clamped = TaskWindowFrame.clamp(straddling, to: [left, right])

        XCTAssertEqual(clamped, NSRect(x: 1_000, y: 100, width: 400, height: 300), "300 of 400 points are on the right screen")
    }

    func testClampPullsAFramePartlyOffAScreenBackOnto() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        XCTAssertEqual(TaskWindowFrame.clamp(NSRect(x: 900, y: 100, width: 400, height: 300), to: [screen]),
                       NSRect(x: 600, y: 100, width: 400, height: 300))
        XCTAssertEqual(TaskWindowFrame.clamp(NSRect(x: -200, y: -150, width: 400, height: 300), to: [screen]),
                       NSRect(x: 0, y: 0, width: 400, height: 300))
    }

    func testClampGivesNothingForAFrameOnNoScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        XCTAssertNil(TaskWindowFrame.clamp(NSRect(x: 5_000, y: 5_000, width: 400, height: 300), to: [screen]))
        XCTAssertNil(TaskWindowFrame.clamp(NSRect(x: 0, y: 0, width: 400, height: 300), to: []))
    }

    func testClampShrinksAFrameBiggerThanTheScreenAndNeverBelowTheMinimum() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        XCTAssertEqual(TaskWindowFrame.clamp(NSRect(x: 0, y: 0, width: 3_000, height: 2_000), to: [screen]), screen)
        let small = TaskWindowFrame.clamp(NSRect(x: 100, y: 100, width: 50, height: 50), to: [screen])
        XCTAssertEqual(small?.width, TaskWindowFrame.minimumSize.width)
        XCTAssertEqual(small?.height, TaskWindowFrame.minimumSize.height)
    }

    // MARK: Other windows

    func testOpeningUpdatingAndClosingNeverChangesAnotherWindowsFirstResponder() throws {
        let other = makeRigWindow(self, size: NSSize(width: 500, height: 300))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        field.string = "half a thought"
        other.contentView?.addSubview(field)
        XCTAssertTrue(other.makeFirstResponder(field), "precondition")
        field.setSelectedRange(NSRange(location: 5, length: 3))
        w.keyWindow = other
        w.ingest([w.task("job0", "step 0")])
        w.outputs["job0"] = "output\n"

        let controller = try XCTUnwrap(w.open("job0"))
        w.pump()
        XCTAssertTrue(other.firstResponder === field, "opening a task window leaves the other window's first responder alone")

        for n in 1 ... 20 { w.ingest([w.task("job0", "step \(n)")]) }
        controller.close()

        XCTAssertTrue(other.firstResponder === field, "so does closing it")
        XCTAssertEqual(field.string, "half a thought")
        XCTAssertEqual(field.selectedRange(), NSRange(location: 5, length: 3))
    }

    // MARK: Menu validation

    func testWithATaskPanelKeyTheMainWindowOnlyMenuItemsAreDisabled() throws {
        w.ingest([w.task("job0")])
        let panel = try XCTUnwrap(w.open("job0")).panel

        // `AppDelegate.validateMenuItem` enables New Terminal and New Remote Shell only when
        // `NSApp.keyWindow?.contentView is MainLayout`, and the Background Activity and Model items only
        // when the key window holds an input bar. With the task panel key none of these is true: the
        // items are disabled, deliberately (a task window is not a pane to open a terminal in).
        XCTAssertFalse(panel.contentView is MainLayout)
        XCTAssertTrue(BackgroundShortcut.bars(in: panel).isEmpty)
        XCTAssertTrue(ModelShortcut.bars(in: panel).isEmpty)
        XCTAssertFalse(panel.canBecomeMain, "the main window stays the main window while a task window is key")
        XCTAssertTrue(panel.canBecomeKey)
    }

    // MARK: Seam: the input bar's actions

    func testTheInputBarOffersTheRealTaskActionsAndNotTheEmptyOnes() {
        let bar = ReplInputBar()

        XCTAssertTrue(bar.backgroundActions is BackgroundTaskWindowActions)
        XCTAssertFalse(bar.backgroundActions is NoBackgroundTaskActions)
    }

    func testEveryRowCanBeOpened() {
        w.ingest(w.world.fixture())
        let actions = BackgroundTaskWindowActions(manager: w.manager)
        let rows = w.world.store.list(for: "claudia").allRows

        XCTAssertEqual(rows.count, 6, "precondition: running, ended and housekeeping rows")
        for row in rows {
            XCTAssertTrue(actions.canOpen(row, tag: "claudia"), "\(row.id) cannot be opened")
        }
    }

    // MARK: Seam: the popover

    private func makeListController() -> BackgroundPopoverViewController {
        let vc = BackgroundPopoverViewController(tag: "claudia", displayName: "Claudia", store: w.world.store,
                                                 actions: BackgroundTaskWindowActions(manager: w.manager),
                                                 pasteboard: w.pasteboard, announce: { _ in })
        _ = vc.view
        return vc
    }

    func testClickingARowOpensItsWindow() throws {
        w.ingest(w.world.fixture())
        let vc = makeListController()
        let row = try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == "built" })

        row.onClick?(row)

        XCTAssertTrue(w.isOpen("built"))
        XCTAssertEqual(w.manager.openCount, 1)
    }

    func testReturnOnTheSelectedRowOpensItsWindow() throws {
        w.ingest(w.world.fixture())
        let vc = makeListController()
        let index = try XCTUnwrap(vc.selectables.firstIndex { ($0 as? BackgroundTaskRowView)?.row.id == "built" })

        vc.select(index)
        vc.activateSelection()

        XCTAssertTrue(w.isOpen("built"))
        XCTAssertEqual(w.manager.openCount, 1)
    }

    func testTheContextMenusOpenItemOpensTheWindow() throws {
        w.ingest(w.world.fixture())
        let vc = makeListController()
        let row = try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == "agent" }).row
        let menu = vc.contextMenu(for: row)

        let open = try XCTUnwrap(menu.items.firstIndex { $0.title == "Open" }, "the menu offers Open: \(menu.items.map(\.title))")
        menu.performActionForItem(at: open)

        XCTAssertTrue(w.isOpen("agent"))
        XCTAssertTrue(w.manager.controller(tag: "claudia", taskId: "agent")?.body is SubagentTaskView)
    }

    func testOpeningTheSameRowTwiceFromTheListStillMakesOneWindow() throws {
        w.ingest(w.world.fixture())
        let vc = makeListController()
        let row = try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == "built" })

        row.onClick?(row)
        row.onClick?(row)

        XCTAssertEqual(w.manager.openCount, 1)
    }

    // MARK: Memory

    func testOpeningAndClosingTheSameTaskFiftyTimesLeavesNothingBehind() {
        w.ingest([w.task("job0")])
        w.outputs["job0"] = "line\n"
        var seen = Set<ObjectIdentifier>()
        var all: [Probe] = []

        for _ in 0 ..< 50 {
            autoreleasepool {
                guard let controller = w.open("job0") else { return XCTFail("the window did not open") }
                all += probes(of: controller, seen: &seen)
                w.pump()
                controller.panel.contentView?.layoutSubtreeIfNeeded()
                controller.close()
            }
        }

        XCTAssertEqual(w.manager.openCount, 0)
        XCTAssertEqual(w.pollScheduler.liveCount, 0, "no timer is live after the last window closed")
        w.manager.closeAll()
        w.registry.forget(tag: "claudia")
        drainRunLoop()

        let leaked = all.filter { $0.object != nil }.map(\.label)
        XCTAssertEqual(leaked, [], "alive after 50 open/close rounds (of \(all.count) watched)")
    }

    func testOpeningFiftyDifferentTasksAndClosingThemAllLeavesNothingBehind() {
        let tasks = (0 ..< 50).map { w.task("job\($0)", "task number \($0)") }
        w.ingest(tasks)
        for task in tasks { w.outputs[task.id] = "output of \(task.id)\n" }
        var seen = Set<ObjectIdentifier>()
        var all: [Probe] = []

        for task in tasks {
            autoreleasepool {
                guard let controller = w.open(task.id) else { return XCTFail("\(task.id) did not open") }
                all += probes(of: controller, seen: &seen)
            }
        }
        w.pump()
        XCTAssertEqual(w.manager.openCount, 50)
        XCTAssertGreaterThanOrEqual(w.pollScheduler.liveCount, 50, "precondition: every open window polls")

        w.manager.closeAll()

        XCTAssertEqual(w.manager.openCount, 0)
        XCTAssertEqual(w.pollScheduler.liveCount, 0, "no timer is live after the last window closed")
        w.registry.forget(tag: "claudia")
        drainRunLoop()

        let leaked = all.filter { $0.object != nil }.map(\.label)
        XCTAssertEqual(leaked, [], "alive after 50 windows closed (of \(all.count) watched)")
    }
}
