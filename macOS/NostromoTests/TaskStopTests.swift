import XCTest
import QuartzCore
import AppKit
import Combine
import NostromoKit

// BA5: stopping a Background task. The behaviour, from outside:
//
// - The button is two-step. `Stop` -> (click) `Stop?` -> (second click within 3 s) `Stopping…`, disabled;
//   with no second click the confirmation reverts to `Stop`. Every click, shortcut and menu selection runs
//   the human-gesture check first; a refused gesture changes nothing and never reaches `requestStop`.
// - The store owns what Stop shows. It never decides a task's status: the task is `stopped` only when a
//   snapshot says so. An accepted stop stays `Stopping…` until a snapshot shows the task over; if none does
//   within 10 s, `no confirmation from Claude Code`. A refusal's reason is the CLI's words, sanitised and cut
//   to 120 characters. The state is shared (every popover and window on the task shows it) and goes with a
//   forgotten focus, a new session, a new daemon epoch and a lost connection.
// - ⌘. is the selected row's (popover) or the window's two-step Stop; it is consumed either way.
// - Nothing is logged with a reason, a description or output in it.
//
// No wall clock, no daemon: the sender records what it is asked, every timer is a list the test fires by hand,
// the clock moves only when the test says so. Real popovers are not shown; the view controller is read the
// way the existing BA3 tests read it. Task panels are real (the manager makes them), closed at teardown.

// MARK: - Support

fileprivate let tsHuman: HumanGestureVerdict = .human(sourcePid: nil, sourceState: nil)

fileprivate typealias TSDisplay = BackgroundTaskStore.StopDisplay

private var tsEventClock: TimeInterval = 0

/// A fresh ⌘. key event each call: its own timestamp, so two presses are two events.
func tsCommandPeriod(isARepeat: Bool = false) -> NSEvent {
    tsEventClock += 1
    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: tsEventClock,
                            windowNumber: 0, context: nil, characters: ".", charactersIgnoringModifiers: ".",
                            isARepeat: isARepeat, keyCode: 47)!
}

/// The clock the gesture gate reads (`BackgroundGesture.now`). Each read moves it `step` seconds, so
/// two gestures in a test are 0.5 s apart unless it is set by hand (`step = 0`).
final class TSGestureClock {
    var now: TimeInterval = 1000
    var step: TimeInterval = 0.5

    func read() -> TimeInterval {
        now += step
        return now
    }
}

/// Install the gate's seams for one test: the clock, and no current event (an event-less action). The
/// real ones come back at teardown.
enum TSGestureSeams {
    @discardableResult
    static func install(on testCase: XCTestCase) -> TSGestureClock {
        let clock = TSGestureClock()
        let oldNow = BackgroundGesture.now
        let oldEvent = BackgroundGesture.currentEvent
        BackgroundGesture.now = { clock.read() }
        BackgroundGesture.currentEvent = { nil }
        testCase.addTeardownBlock {
            BackgroundGesture.now = oldNow
            BackgroundGesture.currentEvent = oldEvent
        }
        return clock
    }
}

fileprivate func tsTitle(_ button: TaskStopButton?) -> String { button?.attributedTitle.string ?? "<no button>" }

fileprivate func tsDrain() {
    for _ in 0 ..< 5 {
        autoreleasepool {
            CATransaction.flush()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }
}

/// Characters a Stop reason must never carry: controls, bidi overrides and isolates, and the filler glyphs.
fileprivate func tsIsForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00 ... 0x1F, 0x7F ... 0x9F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0x200E, 0x200F,
         0x115F, 0x1160, 0x2800, 0x3164, 0xFFA0:
        return true
    default:
        return false
    }
}

fileprivate let tsHostileReason: String = "refused\u{202E}evil"
    + "\u{1B}[31mred\u{1B}[0m"
    + "\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\"
    + "\u{115F}\u{1160}\u{2800}\u{3164}\u{FFA0}\u{0}\u{7}"
    + " first\nsecond\r\nthird "
    + String(repeating: "W", count: 10_240)

/// A scheduler held by hand: what is asked for waits until the test fires it.
fileprivate final class TSSchedule {
    private var items: [(delay: TimeInterval, work: () -> Void)] = []

    var delays: [TimeInterval] { items.map { $0.delay } }
    var count: Int { items.count }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        items.append((delay, work))
    }

    /// Run (and drop) every item whose delay `match`es.
    func fire(where match: (TimeInterval) -> Bool) {
        var due: [() -> Void] = []
        var kept: [(delay: TimeInterval, work: () -> Void)] = []
        for item in items {
            if match(item.delay) { due.append(item.work) } else { kept.append(item) }
        }
        items = kept
        for work in due { work() }
    }

    /// Run (and drop) the oldest item whose delay `match`es.
    func fireFirst(where match: (TimeInterval) -> Bool) {
        guard let index = items.firstIndex(where: { match($0.delay) }) else { return }
        let item = items.remove(at: index)
        item.work()
    }

    func fireAll() { fire(where: { _ in true }) }
}

/// What `TaskRequests` sends to the daemon connection, recorded.
fileprivate final class TSSender: TaskRequestSending {
    struct Stop {
        let requestId: String
        let tag: String
        let taskId: String
    }

    private(set) var stops: [Stop] = []
    private(set) var outputs: [String] = []

    func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        outputs.append(requestId)
    }

    func sendTaskStop(requestId: String, tag: String, taskId: String) {
        stops.append(Stop(requestId: requestId, tag: tag, taskId: taskId))
    }
}

/// A seeded generator (SplitMix64): the same seed gives the same interleaving on every run.
fileprivate struct TSSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A real store, real `TaskRequests`, a recording sender, and a real window manager, all on hand-run timers.
/// One focus (`claudia`). The clock moves a second before every helper that changes something, which is past
/// the store's coalescing window, so every change is delivered at once unless a test says otherwise.
fileprivate final class TSRig {
    static let tag = "claudia"

    let clock = BA3UIClock()
    /// The store's own scheduler: coalesced deliveries (a fraction of a second) and the 10 s confirmation.
    let storeSchedule = TSSchedule()
    /// `TaskRequests`' 12 s timeouts.
    let requestSchedule = TSSchedule()
    /// The buttons' 3 s confirmation reverts.
    let buttonSchedule = TSSchedule()
    let pollScheduler = BA4TWPollScheduler()
    let sender = TSSender()
    let requests: TaskRequests
    let store: BackgroundTaskStore
    private(set) var manager: TaskWindowManager!

    /// What the human-gesture check says for the buttons these helpers build.
    var verdict: HumanGestureVerdict = tsHuman
    var menuVerdict: HumanGestureVerdict = tsHuman

    init(_ testCase: XCTestCase, connected: Bool = true) {
        let ids = BA4TWCounter()
        let clock = self.clock
        let storeSchedule = self.storeSchedule
        let requestSchedule = self.requestSchedule
        let poll = self.pollScheduler
        let sender = self.sender

        let requests = TaskRequests(makeRequestId: { ids.next() },
                                    schedule: { delay, work in requestSchedule.schedule(delay, work) })
        if connected { requests.sender = sender }

        let suite = "TS-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = BackgroundTaskStore(now: { clock.date },
                                        schedule: { delay, work in storeSchedule.schedule(delay, work) },
                                        defaults: defaults,
                                        requests: { requests })
        store.tasksSupported = true

        let registry = TaskOutputRegistry(store: store, requests: requests,
                                          schedule: { delay, work in poll.schedule(delay, work) },
                                          now: { clock.date })
        let frameSuite = "TSW-\(UUID().uuidString)"
        let frameDefaults = UserDefaults(suiteName: frameSuite)!
        let board = NSPasteboard(name: NSPasteboard.Name("TSW-\(UUID().uuidString)"))
        let manager = TaskWindowManager(store: store, registry: registry,
                                        focusName: { _ in "Claudia" },
                                        source: { _ in nil },
                                        defaults: frameDefaults, pasteboard: board,
                                        visibleScreens: { [BA4TWWorld.realScreen()] },
                                        keyWindow: { nil },
                                        now: { clock.date })

        self.requests = requests
        self.store = store
        self.manager = manager
        manager.stopPermit = makePermit(menu: false)
        manager.stopSchedule = { [buttonSchedule] delay, work in buttonSchedule.schedule(delay, work) }

        testCase.addTeardownBlock {
            manager.closeAll()
            defaults.removePersistentDomain(forName: suite)
            frameDefaults.removePersistentDomain(forName: frameSuite)
            board.releaseGlobally()
        }
    }

    func makePermit(menu: Bool) -> BackgroundGesture.Permit {
        return { [weak self] _ in
            guard let self else { return .refused(reason: .notAUserEvent) }
            return menu ? self.menuVerdict : self.verdict
        }
    }

    // MARK: Building

    func task(_ id: String, _ description: String = "npm run dev", kind: TaskKindWire = .shell,
              status: TaskStatusWire = .running, startedAgo: Double = 60) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: description,
                     isBackgrounded: kind == .shell ? true : nil, status: status,
                     startedAtMs: clock.nowMs - UInt64(startedAgo * 1000),
                     endedAtMs: status.isTerminal ? clock.nowMs : nil,
                     hasOutput: kind == .shell || kind == .monitor)
    }

    func makeController(actions: BackgroundTaskActions = BackgroundTaskWindowActions()) -> BackgroundPopoverViewController {
        let vc = BackgroundPopoverViewController(tag: TSRig.tag, displayName: "Claudia", store: store,
                                                 actions: actions, announce: { _ in })
        let schedule = buttonSchedule
        vc.stopPermit = makePermit(menu: false)
        vc.stopMenuPermit = makePermit(menu: true)
        vc.stopSchedule = { delay, work in schedule.schedule(delay, work) }
        _ = vc.view
        return vc
    }

    // MARK: Driving the store

    func snapshot(_ tasks: [TaskMetaWire], session: String? = "s1", epoch: String = "e1", stop: Bool? = true) {
        clock.advance(1)
        store.ingest(.sessionTasks(SessionTasksWire(tag: TSRig.tag, sessionId: session, daemonEpoch: epoch,
                                                    stopSupported: stop, tasks: tasks)))
    }

    /// A Stop the only way one can be asked for: through a real `TaskStopButton` given two permitted,
    /// distinct, well-spaced gestures (only the button can mint the `StopConfirmation` the store needs).
    func requestStop(_ id: String, advance: TimeInterval = 1) {
        clock.advance(advance)
        let oldNow = BackgroundGesture.now, oldEvent = BackgroundGesture.currentEvent
        var gestureClock: TimeInterval = 5000
        BackgroundGesture.now = { gestureClock += 1; return gestureClock }
        BackgroundGesture.currentEvent = { nil }
        defer { BackgroundGesture.now = oldNow; BackgroundGesture.currentEvent = oldEvent }
        let button = TaskStopButton(permit: { _ in tsHuman }, menuPermit: { _ in tsHuman },
                                    schedule: { _, _ in },
                                    requestStop: { [store] confirmation in
                                        store.requestStop(tag: TSRig.tag, taskId: id, confirmation: confirmation)
                                    })
        button.update(TSDisplay(offered: true), description: "")
        button.clicked(nil)
        button.clicked(nil)
    }

    /// The daemon's `session_task_stop_result` for the `request`th stop sent (default: the latest).
    func answer(_ outcome: String, message: String? = nil, request index: Int? = nil, advance: TimeInterval = 1) {
        clock.advance(advance)
        let position = index ?? (sender.stops.count - 1)
        guard sender.stops.indices.contains(position) else {
            XCTFail("no stop request #\(position) was sent")
            return
        }
        let call = sender.stops[position]
        var object: [String: Any] = ["request_id": call.requestId, "tag": call.tag, "task_id": call.taskId,
                                     "outcome": outcome]
        if let message { object["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let wire = try? JSONDecoder().decode(SessionTaskStopResultWire.self, from: data) else {
            XCTFail("could not build the daemon's answer")
            return
        }
        requests.ingest(.sessionTaskStopResult(wire))
    }

    func disconnect() {
        clock.advance(1)
        store.daemonDisconnected()
    }

    /// The 10 s "did a snapshot show it over?" timers.
    func fireConfirmation() {
        clock.advance(1)
        storeSchedule.fire(where: { $0 >= BackgroundTaskStore.confirmationTimeout })
    }

    /// The deferred, coalesced deliveries.
    func flushCoalescing() {
        storeSchedule.fire(where: { $0 < BackgroundTaskStore.confirmationTimeout })
    }

    /// `TaskRequests`' own timeouts: nothing answered a request in time.
    func fireRequestTimeouts() {
        clock.advance(1)
        requestSchedule.fireAll()
    }

    // MARK: Reading

    func row(_ id: String) -> BackgroundTaskRow? {
        store.list(for: TSRig.tag).allRows.first { $0.id == id }
    }

    /// What a Stop control shows for `id`, with the task counted as not over (reads the stop state itself).
    func asRunning(_ id: String) -> TSDisplay {
        store.stopDisplay(tag: TSRig.tag, taskId: id, ended: false)
    }

    /// What a Stop control shows for `id`, as the list says the task stands.
    func display(_ id: String) -> TSDisplay {
        store.stopDisplay(tag: TSRig.tag, taskId: id, ended: row(id)?.isEnded ?? true)
    }
}

// MARK: - The button

/// One `TaskStopButton` with a scripted gesture check, a hand-run revert timer and a counter for `requestStop`.
fileprivate final class TSButtonRig {
    var verdict: HumanGestureVerdict = tsHuman
    var menuVerdict: HumanGestureVerdict = tsHuman
    let schedule = TSSchedule()
    private(set) var stops = 0
    private(set) var button: TaskStopButton!

    init(offered: Bool = true, description: String = "npm run dev") {
        button = TaskStopButton(
            permit: { [unowned self] _ in self.verdict },
            menuPermit: { [unowned self] _ in self.menuVerdict },
            schedule: { [unowned self] delay, work in self.schedule.schedule(delay, work) },
            requestStop: { [unowned self] _ in self.stops += 1 })
        button.update(TSDisplay(offered: offered), description: description)
    }

    func click() { button.clicked(nil) }

    func show(offered: Bool = true, stopping: Bool = false, failure: String? = nil, unsupported: Bool = false,
              description: String = "npm run dev") {
        button.update(TSDisplay(offered: offered, stopping: stopping, failure: failure, unsupported: unsupported),
                      description: description)
    }

    var title: String { tsTitle(button) }
}

final class TaskStopButtonTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TSGestureSeams.install(on: self)
    }

    private let refusals: [HumanGestureRefusal] = [.appControl, .staleEvent, .notAUserEvent, .accessibilityPress, .futureEvent]

    func testAFreshButtonSaysStopAndNamesTheTaskForVoiceOver() {
        let rig = TSButtonRig()

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertFalse(rig.button.isHidden)
        XCTAssertTrue(rig.button.isEnabled)
        XCTAssertEqual(rig.button.accessibilityLabel(), "Stop npm run dev")
    }

    func testTheFirstClickAsksToConfirmAndSendsNothing() {
        let rig = TSButtonRig()

        rig.click()

        XCTAssertEqual(rig.title, "Stop?")
        XCTAssertEqual(rig.button.accessibilityLabel(), "Confirm stop npm run dev")
        XCTAssertEqual(rig.stops, 0)
        XCTAssertEqual(TaskStopButton.confirmInterval, 3, "the confirmation lasts 3 s")
        XCTAssertEqual(rig.schedule.delays, [3])
    }

    func testWithNoSecondClickWithinThreeSecondsItGoesBackToStopAndSendsNothing() {
        let rig = TSButtonRig()
        rig.click()

        rig.schedule.fireAll()

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.button.accessibilityLabel(), "Stop npm run dev")
        XCTAssertEqual(rig.stops, 0)
        rig.click()
        XCTAssertEqual(rig.title, "Stop?", "after the revert it takes two clicks again")
        XCTAssertEqual(rig.stops, 0)
    }

    func testASecondClickWithinThreeSecondsSendsExactlyOneStopAndShowsStoppingDisabled() {
        let rig = TSButtonRig()

        rig.click()
        rig.click()

        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.title, "Stopping\u{2026}")
        XCTAssertFalse(rig.button.isEnabled)
        rig.click()
        rig.button.shortcut()
        rig.button.arm()
        XCTAssertEqual(rig.stops, 1, "nothing more goes out while it is stopping")
        rig.schedule.fireAll()
        XCTAssertEqual(rig.title, "Stopping\u{2026}", "the revert timer does not undo a sent stop")
        XCTAssertEqual(rig.stops, 1)
    }

    func testAnOldRevertTimerCannotCancelALaterConfirmation() {
        let rig = TSButtonRig()
        rig.click()                                   // timer 1
        rig.click()                                   // sent
        rig.show(failure: "Claude Code refused")      // the store says it failed: back to Stop
        XCTAssertEqual(rig.title, "Stop")
        rig.click()                                   // timer 2

        rig.schedule.fireFirst(where: { _ in true })  // timer 1 fires late

        XCTAssertEqual(rig.title, "Stop?", "the second confirmation is still open")
    }

    func testAStoreUpdateDuringTheConfirmationDoesNotCloseIt() {
        let rig = TSButtonRig()
        rig.click()

        rig.show()

        XCTAssertEqual(rig.title, "Stop?")
        rig.click()
        XCTAssertEqual(rig.stops, 1)
    }

    func testWhenTheStoreSaysStoppingTheButtonSaysStoppingAndWhenItFailsItIsStopAgain() {
        let rig = TSButtonRig()

        rig.show(stopping: true)
        XCTAssertEqual(rig.title, "Stopping\u{2026}")
        XCTAssertFalse(rig.button.isEnabled)

        rig.show(failure: "no confirmation from Claude Code")
        XCTAssertEqual(rig.title, "Stop")
        XCTAssertTrue(rig.button.isEnabled)
    }

    func testAButtonThatIsNotOfferedIsHiddenAndInert() {
        let rig = TSButtonRig(offered: false)

        XCTAssertTrue(rig.button.isHidden)
        rig.click()
        rig.button.shortcut()
        rig.button.arm()

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.schedule.count, 0)
        XCTAssertEqual(rig.stops, 0)

        let open = TSButtonRig()
        open.show(offered: false)
        XCTAssertTrue(open.button.isHidden, "once the task is over the button goes")
        open.click()
        XCTAssertEqual(open.stops, 0)
    }

    func testAnEmptyDescriptionStillGivesAReadableLabel() {
        let rig = TSButtonRig(description: "")

        XCTAssertEqual(rig.button.accessibilityLabel(), "Stop task")
    }

    // MARK: The gesture

    func testAHumanVerdictProceedsWhateverItsSource() {
        for verdict in [tsHuman, HumanGestureVerdict.human(sourcePid: 4242, sourceState: 1)] {
            let rig = TSButtonRig()
            rig.verdict = verdict
            rig.click()
            rig.click()
            XCTAssertEqual(rig.stops, 1, "\(verdict)")
        }
    }

    func testARefusedGestureNeverChangesTheButtonOrSendsAnything() {
        for reason in refusals {
            let rig = TSButtonRig()
            rig.verdict = .refused(reason: reason)
            rig.menuVerdict = .refused(reason: reason)

            rig.click()
            rig.button.shortcut()
            rig.button.arm()

            XCTAssertEqual(rig.title, "Stop", "\(reason)")
            XCTAssertEqual(rig.schedule.count, 0, "\(reason): no confirmation was opened")
            XCTAssertEqual(rig.stops, 0, "\(reason)")
        }
    }

    func testARefusedSecondGestureDoesNotAdvanceToStopping() {
        for reason in refusals {
            let rig = TSButtonRig()
            rig.click()
            XCTAssertEqual(rig.title, "Stop?")

            rig.verdict = .refused(reason: reason)
            rig.click()
            rig.button.shortcut()

            XCTAssertEqual(rig.title, "Stop?", "\(reason): still waiting for a real second click")
            XCTAssertEqual(rig.stops, 0, "\(reason)")

            rig.verdict = tsHuman
            rig.click()
            XCTAssertEqual(rig.stops, 1, "\(reason): a real second click still works")
        }
    }

    func testTheShortcutIsTwoStepsEachBehindItsOwnGestureCheck() {
        let rig = TSButtonRig()

        rig.button.shortcut()
        XCTAssertEqual(rig.title, "Stop?")
        XCTAssertEqual(rig.stops, 0)
        rig.button.shortcut()
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.title, "Stopping\u{2026}")
    }

    func testTheMenuOnlyArmsTheButtonAndNeedsTheMenuGesture() {
        let rig = TSButtonRig()
        rig.verdict = .refused(reason: .staleEvent)   // the menu's own check is the one that counts for arm()

        rig.button.arm()
        XCTAssertEqual(rig.title, "Stop?", "the menu selection armed it")
        rig.button.arm()
        XCTAssertEqual(rig.title, "Stop?")
        XCTAssertEqual(rig.stops, 0, "the menu never sends: the second click is required")

        let refused = TSButtonRig()
        refused.menuVerdict = .refused(reason: .appControl)
        refused.button.arm()
        XCTAssertEqual(refused.title, "Stop", "a refused menu selection does nothing")
        XCTAssertEqual(refused.schedule.count, 0)

        let click = TSButtonRig()
        click.verdict = .refused(reason: .appControl)   // a click does not borrow the menu's verdict
        click.click()
        XCTAssertEqual(click.title, "Stop")
    }

    // MARK: Teardown

    func testATimerThatFiresAfterInvalidateChangesNothing() {
        let rig = TSButtonRig()
        rig.click()
        rig.button.invalidate()
        let before = rig.title

        rig.schedule.fireAll()

        XCTAssertEqual(rig.title, before)
        XCTAssertEqual(rig.stops, 0)
    }

    func testAButtonWithAPendingRevertTimerDoesNotOutliveItsOwner() {
        let schedule = TSSchedule()
        weak var weakButton: TaskStopButton?
        autoreleasepool {
            let button = TaskStopButton(permit: { _ in tsHuman }, menuPermit: { _ in tsHuman },
                                        schedule: { delay, work in schedule.schedule(delay, work) },
                                        requestStop: { _ in })
            button.update(TSDisplay(offered: true), description: "npm run dev")
            button.clicked(nil)
            weakButton = button
        }
        tsDrain()

        XCTAssertNil(weakButton, "the pending timer holds the button weakly")
        schedule.fireAll()   // and firing it afterwards is harmless
    }

    // MARK: ⌘. and the notice text

    func testTheStopShortcutIsCommandPeriodAndNothingElse() {
        XCTAssertTrue(BackgroundGesture.isStopShortcut(tsCommandPeriod()))
        XCTAssertTrue(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(47, ".", flags: [.command, .capsLock])))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(47, ".", flags: [.command, .shift])))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(47, ".", flags: [.command, .option])))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(47, ".", flags: [.control])))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(47, ".")))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.keyDown(43, ",", flags: .command)))
        XCTAssertFalse(BackgroundGesture.isStopShortcut(BA3UIKey.event(.keyUp, 47, ".", flags: .command)))
    }

    func testTheNoticeSaysWhyStopFailedOrThatTheCLICannotStop() {
        let failed = TSDisplay(offered: true, failure: "Task is protected")
        XCTAssertEqual(TaskStopNotice.text(for: failed, showUnsupported: true), "Couldn't stop: Task is protected")
        XCTAssertEqual(TaskStopNotice.text(for: failed, showUnsupported: false), "Couldn't stop: Task is protected")

        let unsupported = TSDisplay(offered: false, unsupported: true)
        XCTAssertEqual(TaskStopNotice.text(for: unsupported, showUnsupported: true),
                       "This Claude Code version can't stop tasks from Nostromo")
        XCTAssertNil(TaskStopNotice.text(for: unsupported, showUnsupported: false), "a list row does not repeat it")

        XCTAssertNil(TaskStopNotice.text(for: TSDisplay(offered: true), showUnsupported: true))
    }
}

// MARK: - The gesture check, for real

/// A button wired to the real `HumanGesture.permit` over an event the test sets, in a real (offscreen) window.
fileprivate final class TSGestureRig {
    let window: NSWindow
    let other: NSWindow
    var event: NSEvent?
    /// `NSWorkspace.isVoiceOverEnabled`, as the gesture check sees it.
    var voiceOver = false
    let reverts = TSSchedule()
    private(set) var stops = 0
    private(set) var button: TaskStopButton!

    init() {
        window = GestureFixtures.offscreenWindow()
        other = GestureFixtures.offscreenWindow()
        button = TaskStopButton(
            permit: { [unowned self] control in
                HumanGesture.permit(self.event, control: control,
                                    voiceOverEnabled: { self.voiceOver }, allowsSynthetic: { false })
            },
            menuPermit: { [unowned self] control in
                HumanGesture.permit(self.event, control: control, menuSelection: true, contextMenuPick: true,
                                    voiceOverEnabled: { self.voiceOver }, allowsSynthetic: { false })
            },
            schedule: { [unowned self] delay, work in self.reverts.schedule(delay, work) },
            requestStop: { [unowned self] _ in self.stops += 1 })
        button.update(TSDisplay(offered: true), description: "npm run dev")
        button.frame = NSRect(x: 10, y: 10, width: 100, height: 40)
        window.contentView?.addSubview(button)
    }

    var title: String { tsTitle(button) }

    /// Make the button the window's first responder (Space and Return reach it only then).
    func focusButton() {
        XCTAssertTrue(window.makeFirstResponder(button), "the button must be able to take focus")
    }

    func close() {
        window.close()
        other.close()
    }
}

final class TaskStopRealGestureTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TSGestureSeams.install(on: self)
    }

    private func makeRig() -> TSGestureRig {
        let rig = TSGestureRig()
        BackgroundGesture.currentEvent = { [weak rig] in rig?.event }
        addTeardownBlock { rig.close() }
        return rig
    }

    func testAFreshClickInTheButtonsOwnWindowIsAHumanGesture() {
        let rig = makeRig()
        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.window)

        rig.button.clicked(nil)
        XCTAssertEqual(rig.title, "Stop?")
        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.window)   // a second, distinct click
        rig.button.clicked(nil)

        XCTAssertEqual(rig.stops, 1)
    }

    func testAStaleEventIsRefusedOnTheFirstAndOnTheSecondClick() {
        let rig = makeRig()
        let stale = GestureFixtures.mouse(.leftMouseUp, in: rig.window,
                                          timestamp: ProcessInfo.processInfo.systemUptime - 10)
        rig.event = stale
        rig.button.clicked(nil)
        XCTAssertEqual(rig.title, "Stop", "a stale event cannot start the two steps")

        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.window)
        rig.button.clicked(nil)
        rig.event = stale
        rig.button.clicked(nil)
        XCTAssertEqual(rig.title, "Stop?", "nor finish them")
        XCTAssertEqual(rig.stops, 0)

        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.window)
        rig.button.clicked(nil)
        XCTAssertEqual(rig.stops, 1)
    }

    func testAnEventForAnotherWindowIsRefused() {
        let rig = makeRig()
        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.other)

        rig.button.clicked(nil)
        rig.button.shortcut()

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.stops, 0)
    }

    func testAnAppControlEventIsRefused() throws {
        let rig = makeRig()
        rig.event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: rig.window))

        rig.button.clicked(nil)
        rig.button.shortcut()

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.stops, 0)
    }

    func testNoCurrentEventIsAnAccessibilityPressAndIsRefused() {
        let rig = makeRig()
        rig.event = nil

        rig.button.clicked(nil)

        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.stops, 0)
    }

    func testAKeyPressInTheButtonsWindowDrivesTheShortcut() {
        let rig = makeRig()
        rig.event = GestureFixtures.key(in: rig.window, characters: ".", keyCode: 47)
        rig.button.shortcut()
        rig.event = GestureFixtures.key(in: rig.window, characters: ".", keyCode: 47)   // a second, distinct press
        rig.button.shortcut()

        XCTAssertEqual(rig.stops, 1)
    }

    func testAMenuSelectionMayCarryTheMenusMouseEventButNotAStaleOrKeyEventOfAnotherWindow() {
        let rig = makeRig()
        rig.event = GestureFixtures.mouse(.leftMouseUp, in: rig.other)   // the menu's own event
        rig.button.arm()
        XCTAssertEqual(rig.title, "Stop?", "a chosen menu item is armed by the menu's mouse event")

        let stale = makeRig()
        stale.event = GestureFixtures.mouse(.leftMouseUp, in: stale.other,
                                            timestamp: ProcessInfo.processInfo.systemUptime - 10)
        stale.button.arm()
        XCTAssertEqual(stale.title, "Stop", "a stale one is refused")

        let key = makeRig()
        key.event = GestureFixtures.key(in: key.other, characters: ".", keyCode: 47)
        key.button.arm()
        XCTAssertEqual(key.title, "Stop", "a key event must still be the button's own window's")
    }
}

// MARK: - One gesture never arms and confirms

private var tsUnique: TimeInterval = 0

/// Events are stamped 0.7 s ago plus `at`, so two events `at` seconds apart are that far apart in event time
/// and both still read as fresh to `HumanGesture` (at most 1 s old, at most 0.25 s ahead of now): keep `at`
/// under 0.9. Each call is its own event (its own event number, its own sub-microsecond timestamp).
fileprivate func tsStamp(_ at: TimeInterval) -> TimeInterval {
    tsUnique += 0.000_001
    return ProcessInfo.processInfo.systemUptime - 0.7 + at + tsUnique
}

/// A mouse event for `window`, `at` seconds into the test's event time, inside the button.
fileprivate func tsMouse(_ type: NSEvent.EventType = .leftMouseUp, in window: NSWindow, clickCount: Int = 1,
                         at: TimeInterval = 0, location: NSPoint = NSPoint(x: 30, y: 30)) -> NSEvent {
    let stamp = tsStamp(at)
    return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: stamp,
                              windowNumber: window.windowNumber, context: nil,
                              eventNumber: Int(tsUnique * 1_000_000), clickCount: clickCount, pressure: 1)!
}

/// A key event for `window` (nil: no window, as a chosen menu item's), `at` seconds into the test's event time.
fileprivate func tsKey(in window: NSWindow?, characters: String = ".", keyCode: UInt16 = 47,
                       flags: NSEvent.ModifierFlags = .command, isARepeat: Bool = false,
                       at: TimeInterval = 0) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: tsStamp(at),
                     windowNumber: window?.windowNumber ?? 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: isARepeat, keyCode: keyCode)!
}

/// The arm and the confirm must be two gestures. Real `HumanGesture.permit` and real events; the gate's
/// clock is set by hand (`step = 0`), so "0.1 s after the arm" is exactly that.
final class TaskStopOneGestureTests: XCTestCase {

    private var clock: TSGestureClock!

    override func setUp() {
        super.setUp()
        clock = TSGestureSeams.install(on: self)
        clock.step = 0
    }

    private func makeRig() -> TSGestureRig {
        let rig = TSGestureRig()
        BackgroundGesture.currentEvent = { [weak rig] in rig?.event }
        addTeardownBlock { rig.close() }
        return rig
    }

    private func click(_ rig: TSGestureRig, _ event: NSEvent) {
        rig.event = event
        rig.button.clicked(nil)
    }

    private func press(_ rig: TSGestureRig, _ event: NSEvent) {
        rig.event = event
        rig.button.shortcut(event)
    }

    func testADoubleClickArmsButNeverConfirms() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window, clickCount: 1))
        XCTAssertEqual(rig.title, "Stop?")

        clock.now += 0.15   // the OS double-click interval
        click(rig, tsMouse(in: rig.window, clickCount: 2, at: 0.15))

        XCTAssertEqual(rig.title, "Stop?", "the second click of a double-click leaves it armed")
        XCTAssertEqual(rig.stops, 0, "and sends nothing: `Stop?` was never seen")
        XCTAssertEqual(rig.reverts.count, 1, "the armed state and its revert are untouched")

        clock.now += 1
        click(rig, tsMouse(in: rig.window, clickCount: 1, at: 0.8))
        XCTAssertEqual(rig.stops, 1, "a deliberate click later does confirm")
    }

    func testAClickThatIsAlreadyTheSecondOfADoubleClickCannotArm() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window, clickCount: 2))
        XCTAssertEqual(rig.title, "Stop")
        click(rig, tsMouse(in: rig.window, clickCount: 3))
        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.stops, 0)
    }

    func testAHeldShortcutArmsAtMostAndNeverConfirms() {
        let rig = makeRig()
        press(rig, tsKey(in: rig.window))
        XCTAssertEqual(rig.title, "Stop?")

        clock.now += 0.5   // key repeat starts about half a second in
        press(rig, tsKey(in: rig.window, isARepeat: true, at: 0.5))
        clock.now += 0.03
        press(rig, tsKey(in: rig.window, isARepeat: true, at: 0.53))

        XCTAssertEqual(rig.title, "Stop?", "repeats of a held ⌘. do not confirm")
        XCTAssertEqual(rig.stops, 0)

        clock.now += 1
        press(rig, tsKey(in: rig.window, at: 0.8))
        XCTAssertEqual(rig.stops, 1, "a fresh key press does")
    }

    func testAKeyRepeatCannotArm() {
        let rig = makeRig()
        press(rig, tsKey(in: rig.window, isARepeat: true))
        XCTAssertEqual(rig.title, "Stop")
        XCTAssertEqual(rig.reverts.count, 0, "nothing was armed, so no revert was scheduled")
    }

    func testTheSameEventTwiceIsOneGesture() {
        let rig = makeRig()
        let event = tsMouse(in: rig.window)
        click(rig, event)
        clock.now += 1   // plenty of time: only the event identity is in question
        click(rig, event)

        XCTAssertEqual(rig.title, "Stop?")
        XCTAssertEqual(rig.stops, 0)

        click(rig, tsMouse(in: rig.window, at: 0.5))
        XCTAssertEqual(rig.stops, 1)
    }

    func testTheSameKeyEventTwiceIsOneGesture() {
        let rig = makeRig()
        let event = tsKey(in: rig.window)
        press(rig, event)
        clock.now += 1
        press(rig, event)
        XCTAssertEqual(rig.title, "Stop?")
        XCTAssertEqual(rig.stops, 0)
    }

    func testAConfirmAtOneTenthOfASecondIsRefusedAndAtFourTenthsAccepted() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))

        clock.now += 0.1
        click(rig, tsMouse(in: rig.window, at: 0.1))
        XCTAssertEqual(rig.stops, 0, "0.1 s after the arm is the same gesture")
        XCTAssertEqual(rig.title, "Stop?")

        clock.now += 0.3   // 0.4 s after the arm
        click(rig, tsMouse(in: rig.window, at: 0.4))
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.title, "Stopping\u{2026}")
    }

    func testARefusedConfirmLeavesTheThreeSecondRevertRunning() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))
        clock.now += 0.1
        click(rig, tsMouse(in: rig.window, at: 0.1))   // refused: too soon
        XCTAssertEqual(rig.reverts.delays, [TaskStopButton.confirmInterval])

        rig.reverts.fireAll()
        XCTAssertEqual(rig.title, "Stop", "the original revert still puts the button back")
        XCTAssertEqual(rig.stops, 0)
    }

    func testTwoDistinctGesturesHalfASecondApartStopOnce() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))
        clock.now += 0.5
        click(rig, tsMouse(in: rig.window, at: 0.5))
        XCTAssertEqual(rig.stops, 1)
    }

    // MARK: Space and Return on the focused button

    func testSpaceOrReturnOnTheFocusedButtonFollowsTheSameRules() {
        for (characters, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
            let rig = makeRig()
            rig.focusButton()
            let first = tsKey(in: rig.window, characters: characters, keyCode: code, flags: [])
            click(rig, first)
            XCTAssertEqual(rig.title, "Stop?", "key \(code) arms")

            click(rig, first)
            clock.now += 1
            click(rig, first)
            XCTAssertEqual(rig.stops, 0, "key \(code): the same press is not a confirmation")

            click(rig, tsKey(in: rig.window, characters: characters, keyCode: code, flags: [], isARepeat: true, at: 0.5))
            XCTAssertEqual(rig.stops, 0, "key \(code): a repeat of a held key is not one either")

            click(rig, tsKey(in: rig.window, characters: characters, keyCode: code, flags: [], at: 0.5))
            XCTAssertEqual(rig.stops, 1, "key \(code): a second press does")
        }
    }

    func testAHeldSpaceCannotArm() {
        let rig = makeRig()
        rig.focusButton()
        click(rig, tsKey(in: rig.window, characters: " ", keyCode: 49, flags: [], isARepeat: true))
        XCTAssertEqual(rig.title, "Stop")
    }

    // MARK: An Accessibility press

    func testAnAccessibilityPressWithVoiceOverOnIsSpacedByTheClock() {
        let rig = makeRig()
        rig.voiceOver = true
        rig.event = nil

        rig.button.clicked(nil)
        XCTAssertEqual(rig.title, "Stop?", "with VoiceOver on, an event-less press is a person's")
        clock.now += 0.1
        rig.button.clicked(nil)
        XCTAssertEqual(rig.stops, 0, "but a second one 0.1 s later is the same gesture")

        clock.now += 0.3
        rig.button.clicked(nil)
        XCTAssertEqual(rig.stops, 1)
    }

    func testAnAccessibilityPressWithVoiceOverOffIsStillRefused() {
        let rig = makeRig()
        rig.event = nil
        rig.button.clicked(nil)
        XCTAssertEqual(rig.title, "Stop")
    }

    // MARK: The context menu

    func testAMenuChosenByKeyboardOrByRightButtonReleaseArmsTheButton() {
        let keyboard = makeRig()
        keyboard.event = tsKey(in: nil, characters: "\r", keyCode: 36, flags: [])   // the menu's own key event
        keyboard.button.arm()
        XCTAssertEqual(keyboard.title, "Stop?", "a menu item chosen with Return arms")

        let rightButton = makeRig()
        rightButton.event = tsMouse(.rightMouseUp, in: rightButton.other)            // released over the item
        rightButton.button.arm()
        XCTAssertEqual(rightButton.title, "Stop?", "a menu item chosen by releasing the right button arms")

        let elsewhere = makeRig()
        elsewhere.event = tsKey(in: elsewhere.other, characters: "\r", keyCode: 36, flags: [])
        elsewhere.button.arm()
        XCTAssertEqual(elsewhere.title, "Stop", "a key event of another window is still refused")
    }

    func testAMenuPickDoesNotConfirmEvenWhenChosenTwice() {
        let rig = makeRig()
        rig.event = tsMouse(.rightMouseUp, in: rig.other)
        rig.button.arm()
        rig.button.arm()
        XCTAssertEqual(rig.stops, 0, "the menu only arms")
        XCTAssertEqual(rig.title, "Stop?")
    }

    // MARK: The event must be aimed at this button

    private let elsewhere = NSPoint(x: 300, y: 200)   // in the window, outside the button (10...110 x 10...50)

    func testAFreshClickElsewhereInTheWindowCannotArmTheButton() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window, location: elsewhere))   // a click on another row, then a programmatic press

        XCTAssertEqual(rig.title, "Stop", "the event did not target this button")
        XCTAssertEqual(rig.reverts.count, 0)
    }

    func testAFreshClickElsewhereInTheWindowCannotConfirmAnArmedButton() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))                        // armed by a click on the button
        clock.now += 1.5
        click(rig, tsMouse(in: rig.window, at: 0.6, location: elsewhere))   // another row clicked; the press has no event of its own

        XCTAssertEqual(rig.stops, 0, "a click elsewhere is not the confirm")
        XCTAssertEqual(rig.title, "Stop?", "and it leaves the armed state alone")

        click(rig, tsMouse(in: rig.window, at: 0.8))               // a click inside the button still works
        XCTAssertEqual(rig.stops, 1)
    }

    func testSpaceOrReturnWorksOnlyWhileTheButtonIsTheFirstResponder() {
        let rig = makeRig()
        click(rig, tsKey(in: rig.window, characters: " ", keyCode: 49, flags: []))
        XCTAssertEqual(rig.title, "Stop", "a key press that is not going to this button cannot arm it")

        rig.focusButton()
        click(rig, tsKey(in: rig.window, characters: "a", keyCode: 0, flags: []))
        XCTAssertEqual(rig.title, "Stop", "only Space and Return activate a focused button")

        click(rig, tsKey(in: rig.window, characters: " ", keyCode: 49, flags: []))
        XCTAssertEqual(rig.title, "Stop?", "Space on the focused button arms it")

        _ = rig.window.makeFirstResponder(nil)
        click(rig, tsKey(in: rig.window, characters: " ", keyCode: 49, flags: [], at: 0.5))
        XCTAssertEqual(rig.stops, 0, "and once the focus has moved on, a Space is not its confirm")
    }

    // MARK: The spacing is event time

    func testTwoEventsFifteenHundredthsApartAreOneGestureWhateverTheHandlerClockSays() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))
        clock.now += 0.4   // the handlers ran 0.4 s apart (a busy main thread) ...
        click(rig, tsMouse(in: rig.window, at: 0.15))   // ... but the clicks were 0.15 s apart

        XCTAssertEqual(rig.stops, 0, "the gap is the events', not the handler's")
        XCTAssertEqual(rig.title, "Stop?")
    }

    func testTwoEventsFourTenthsApartOnBothClocksAreTwoGestures() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))
        clock.now += 0.4   // handled 0.4 s apart ...
        click(rig, tsMouse(in: rig.window, at: 0.4))   // ... and 0.4 s apart on the wire

        XCTAssertEqual(rig.stops, 1)
    }

    /// A legitimate pair that the main thread handled in a burst (0.05 s apart) is refused even though the
    /// events were 0.4 s apart: the event clock alone can be forged, so both must show the gap. Harmless:
    /// the button stays armed and the user clicks again.
    func testALegitimatePairHandledInABurstIsRefusedAndASecondClickConfirms() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))
        clock.now += 0.05
        click(rig, tsMouse(in: rig.window, at: 0.4))
        XCTAssertEqual(rig.stops, 0)
        XCTAssertEqual(rig.title, "Stop?")

        clock.now += 0.5
        click(rig, tsMouse(in: rig.window, at: 0.8))
        XCTAssertEqual(rig.stops, 1)
    }

    func testForgedEventTimestampsWithNoRealGapAreRefused() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window))               // armed, stamped "now - 0.7"
        click(rig, tsMouse(in: rig.window, at: 0.9))      // confirm stamped 0.9 s later; handler clock gap is 0

        XCTAssertEqual(rig.stops, 0, "a 0.9 s event gap with no real gap is a forgery")
        XCTAssertEqual(rig.title, "Stop?")
    }

    func testAConfirmStampedBeforeTheArmIsRefused() {
        let rig = makeRig()
        click(rig, tsMouse(in: rig.window, at: 0.5))
        clock.now += 1
        click(rig, tsMouse(in: rig.window, at: 0.0))
        XCTAssertEqual(rig.stops, 0)
    }

    // MARK: The hit test uses the button's own coordinates

    /// The button sits in a flipped container whose origin is (50, 60) in the window, so its frame
    /// ((5,5)-(105,45), in the container) and its place in the window (x 55...155, y 115...155) differ.
    /// (30, 30) is inside the frame read as window coordinates and outside the button; (100, 130) is
    /// outside that frame and on the button.
    func testTheHitTestIsInTheButtonsOwnCoordinatesNotItsFrames() {
        let rig = makeRig()
        let container = TSFlippedView(frame: NSRect(x: 50, y: 60, width: 200, height: 100))
        rig.window.contentView?.addSubview(container)
        rig.button.removeFromSuperview()
        rig.button.frame = NSRect(x: 5, y: 5, width: 100, height: 40)
        container.addSubview(rig.button)

        let insideFrameOnly = NSPoint(x: 30, y: 30)
        let onButton = NSPoint(x: 100, y: 130)

        click(rig, tsMouse(in: rig.window, location: insideFrameOnly))
        XCTAssertEqual(rig.title, "Stop", "a click off the button cannot arm it, whatever its frame says")
        click(rig, tsMouse(in: rig.window, location: onButton))
        XCTAssertEqual(rig.title, "Stop?", "a click on the button arms it")

        clock.now += 1
        click(rig, tsMouse(in: rig.window, at: 0.8, location: insideFrameOnly))
        XCTAssertEqual(rig.stops, 0, "a click off the button cannot confirm")
        click(rig, tsMouse(in: rig.window, at: 0.8, location: onButton))
        XCTAssertEqual(rig.stops, 1)
    }
}

fileprivate final class TSFlippedView: NSView {
    override var isFlipped: Bool { true }
}
