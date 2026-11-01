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

// MARK: - The store

final class TaskStopStoreTests: XCTestCase {

    private var rig: TSRig!
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        rig = TSRig(self)
    }

    override func tearDown() {
        bag.removeAll()
        rig = nil
        super.tearDown()
    }

    private func startStopping(_ id: String = "a", accepted: Bool = true) {
        rig.snapshot([rig.task(id)])
        rig.requestStop(id)
        if accepted { rig.answer("accepted") }
    }

    // MARK: Accepted

    func testAnAcceptedStopStaysStoppingUntilASnapshotShowsTheTaskOver() {
        rig.snapshot([rig.task("a")])
        rig.requestStop("a")
        XCTAssertEqual(rig.sender.stops.map { $0.taskId }, ["a"], "exactly one session_task_stop went out")
        XCTAssertEqual(rig.sender.stops.map { $0.tag }, [TSRig.tag])
        XCTAssertTrue(rig.asRunning("a").stopping, "from the click on")

        rig.answer("accepted")

        XCTAssertTrue(rig.asRunning("a").stopping, "the CLI took it; the task is not over until a snapshot says so")
        XCTAssertEqual(rig.row("a")?.statusLabel, "running", "the store never marks a task stopped on its own")
        XCTAssertEqual(rig.row("a")?.isEnded, false)

        rig.snapshot([rig.task("a", status: .stopped)])

        XCTAssertEqual(rig.row("a")?.statusLabel, "stopped")
        XCTAssertFalse(rig.asRunning("a").stopping, "the stop state is cleared, not just hidden")
        XCTAssertNil(rig.asRunning("a").failure)
        XCTAssertFalse(rig.display("a").offered, "a task that is over has nothing to stop")
        rig.fireConfirmation()
        XCTAssertNil(rig.asRunning("a").failure, "the confirmation timer of a finished stop says nothing")
    }

    func testWithNoTerminalSnapshotWithinTenSecondsTheStopFailsAndTheTaskStillShowsRunning() {
        startStopping()
        XCTAssertEqual(BackgroundTaskStore.confirmationTimeout, 10)
        XCTAssertTrue(rig.storeSchedule.delays.contains(10), "the store asked for a 10 s timer")

        rig.fireConfirmation()

        let shown = rig.display("a")
        XCTAssertEqual(shown.failure, "no confirmation from Claude Code")
        XCTAssertFalse(shown.stopping)
        XCTAssertTrue(shown.offered, "the user may try again")
        XCTAssertEqual(rig.row("a")?.statusLabel, "running", "the list still says what the daemon said")
        XCTAssertEqual(rig.row("a")?.isEnded, false)
    }

    func testAnOlderRequestsConfirmationTimerChangesNothingAboutANewerRequest() {
        startStopping()                                  // request 0, timer 1
        rig.store.forget(tag: TSRig.tag)
        rig.snapshot([rig.task("a")])
        rig.requestStop("a")
        rig.answer("accepted", request: 1)               // request 1, timer 2

        rig.storeSchedule.fireFirst(where: { $0 >= BackgroundTaskStore.confirmationTimeout })

        XCTAssertTrue(rig.asRunning("a").stopping, "timer 1 belongs to a request that is gone")
        XCTAssertNil(rig.asRunning("a").failure)
        rig.fireConfirmation()
        XCTAssertEqual(rig.asRunning("a").failure, "no confirmation from Claude Code")
    }

    func testAnAcceptedStopWhoseTaskIsNoLongerListedIsCleared() {
        startStopping()

        rig.snapshot([rig.task("other")])

        XCTAssertFalse(rig.asRunning("a").stopping)
        XCTAssertNil(rig.asRunning("a").failure)
    }

    // MARK: Failures

    func testARefusalShowsTheCLIsWordsAsTheFailure() throws {
        startStopping(accepted: false)

        rig.answer("refused", message: "Task is protected")

        let shown = rig.display("a")
        XCTAssertEqual(shown.failure, "Task is protected")
        XCTAssertFalse(shown.stopping)
        XCTAssertEqual(rig.row("a")?.statusLabel, "running")
    }

    func testAHostileTenKilobyteRefusalIsSanitisedAndNeverLongerThanTheLimit() throws {
        startStopping(accepted: false)

        rig.answer("refused", message: tsHostileReason)

        let failure = try XCTUnwrap(rig.display("a").failure)
        XCTAssertEqual(BackgroundTaskStore.StopReason.limit, 120)
        XCTAssertLessThanOrEqual(failure.count, 120, "cut to the limit")
        XCTAssertTrue(failure.hasSuffix("\u{2026}"), "and says it was cut")
        XCTAssertTrue(failure.hasPrefix("refused"), "it is still the CLI's words")
        XCTAssertTrue(failure.contains("link"), "text between escape sequences survives")
        XCTAssertFalse(failure.contains("\n"))
        let bad = failure.unicodeScalars.filter(tsIsForbiddenScalar).map { String($0.value, radix: 16) }
        XCTAssertEqual(bad, [], "no control, bidi or filler scalar survives: \(failure.debugDescription)")
    }

    func testAReasonAtTheLimitIsKeptAndOneOverIsCut() throws {
        startStopping(accepted: false)
        rig.answer("refused", message: String(repeating: "x", count: 120))
        XCTAssertEqual(rig.display("a").failure, String(repeating: "x", count: 120))

        rig.requestStop("a")
        rig.answer("refused", message: String(repeating: "x", count: 121))
        let cut = try XCTUnwrap(rig.display("a").failure)
        XCTAssertEqual(cut.count, 120)
        XCTAssertTrue(cut.hasSuffix("\u{2026}"))
    }

    func testAReasonThatIsOneGraphemeOfTenThousandCombiningMarksIsStillBounded() throws {
        startStopping(accepted: false)

        rig.answer("refused", message: "e" + String(repeating: "\u{0301}", count: 5_000))

        let failure = try XCTUnwrap(rig.display("a").failure)
        XCTAssertLessThanOrEqual(failure.unicodeScalars.count, 120,
                                 "the cap is on what is stored and drawn, not on grapheme clusters")
    }

    func testARefusalWithNothingReadableFallsBackToAPlainReason() {
        startStopping(accepted: false)
        rig.answer("refused", message: "\u{115F}\u{2800}\u{202E}\u{1B}[0m  ")
        XCTAssertEqual(rig.display("a").failure, "Claude Code refused", "an all-invisible message says nothing")

        rig.requestStop("a")
        rig.answer("refused", message: nil)
        XCTAssertEqual(rig.display("a").failure, "Claude Code refused")
    }

    func testATimeoutAnswerSaysTheCLIDidNotAnswer() {
        startStopping(accepted: false)

        rig.answer("timeout")

        XCTAssertEqual(rig.display("a").failure, "Claude Code didn't answer")
        XCTAssertFalse(rig.display("a").stopping)
    }

    func testNoAnswerAtAllSaysTheCLIDidNotAnswer() {
        startStopping(accepted: false)

        rig.fireRequestTimeouts()

        XCTAssertEqual(rig.display("a").failure, "Claude Code didn't answer")
        XCTAssertFalse(rig.display("a").stopping)
    }

    func testAStopWithNoDaemonConnectionFailsAtOnceAndSendsNothing() {
        let offline = TSRig(self, connected: false)
        offline.snapshot([offline.task("a")])

        offline.requestStop("a")

        XCTAssertNotNil(offline.display("a").failure)
        XCTAssertFalse(offline.display("a").stopping)
        XCTAssertTrue(offline.sender.stops.isEmpty)
    }

    func testAFailedStopCanBeTriedAgain() {
        startStopping(accepted: false)
        rig.answer("refused", message: "busy")
        XCTAssertNotNil(rig.display("a").failure)

        rig.requestStop("a")

        XCTAssertEqual(rig.sender.stops.count, 2, "a second request went out")
        XCTAssertTrue(rig.display("a").stopping)
        XCTAssertNil(rig.display("a").failure, "the old failure is gone while the new request is out")
    }

    func testAskingAgainWhileAStopIsOutSendsNothingMore() {
        startStopping(accepted: false)

        rig.requestStop("a")
        rig.requestStop("a")

        XCTAssertEqual(rig.sender.stops.count, 1)
    }

    func testAnUnrecognisedOutcomeIsAFailureNotASuccess() throws {
        startStopping(accepted: false)

        rig.answer("surprise")

        let shown = rig.display("a")
        XCTAssertNotNil(shown.failure)
        XCTAssertFalse(shown.stopping)
        XCTAssertEqual(rig.row("a")?.statusLabel, "running")
    }

    // MARK: Unsupported and not running

    func testAnUnsupportedAnswerMeansStopIsNeverOfferedAgain() {
        startStopping(accepted: false)

        rig.answer("unsupported")

        let shown = rig.display("a")
        XCTAssertFalse(shown.offered)
        XCTAssertTrue(shown.unsupported)
        XCTAssertFalse(shown.stopping)
        XCTAssertEqual(rig.row("a")?.stopOffered, false, "the list row stops offering it too")

        rig.snapshot([rig.task("a"), rig.task("b")], stop: nil)

        XCTAssertFalse(rig.display("a").offered, "a snapshot that does not say otherwise keeps it off")
        XCTAssertFalse(rig.display("b").offered, "for every task of the focus")
    }

    func testANotRunningAnswerClearsTheStopStateAndLeavesTheStatusToTheSnapshot() {
        startStopping(accepted: false)

        rig.answer("not_running")

        let shown = rig.asRunning("a")
        XCTAssertFalse(shown.stopping)
        XCTAssertNil(shown.failure)
        XCTAssertEqual(rig.row("a")?.statusLabel, "running", "only the daemon's snapshot says a task ended")
    }

    func testAStoreWithNoStopSupportInformationOffersStop() {
        rig.snapshot([rig.task("a")], stop: nil)

        XCTAssertTrue(rig.display("a").offered)
        XCTAssertFalse(rig.display("a").unsupported)

        rig.snapshot([rig.task("a")], stop: false)
        XCTAssertFalse(rig.display("a").offered)
        XCTAssertTrue(rig.display("a").unsupported)
    }

    // MARK: Surviving and clearing

    func testTheStopStateSurvivesASnapshotThatReplacesTheListWhileTheTaskStillRuns() {
        rig.snapshot([rig.task("a")])
        rig.requestStop("a")
        rig.snapshot([rig.task("a", "npm run dev --watch"), rig.task("b")])
        XCTAssertTrue(rig.asRunning("a").stopping, "while the request is out")

        rig.answer("accepted")
        rig.snapshot([rig.task("a", "npm run dev --watch (3 clients)"), rig.task("b")])

        XCTAssertTrue(rig.asRunning("a").stopping, "while the CLI has it")
        XCTAssertFalse(rig.asRunning("b").stopping)
        XCTAssertEqual(rig.row("a")?.statusLabel, "running")
    }

    func testForgettingTheFocusClearsItAndALateAnswerDoesNotBringItBack() {
        startStopping(accepted: false)

        rig.store.forget(tag: TSRig.tag)

        XCTAssertFalse(rig.asRunning("a").stopping)
        rig.answer("refused", message: "late")
        XCTAssertNil(rig.store.state(for: TSRig.tag), "a late answer does not make the forgotten focus exist again")
        XCTAssertNil(rig.asRunning("a").failure)
    }

    func testANewSessionClearsTheStopState() {
        startStopping()

        rig.snapshot([rig.task("a")], session: "s2")

        XCTAssertFalse(rig.asRunning("a").stopping)
        XCTAssertNil(rig.asRunning("a").failure)
    }

    func testANewDaemonEpochClearsTheStopState() {
        startStopping()

        rig.snapshot([rig.task("a")], epoch: "e2")

        XCTAssertFalse(rig.asRunning("a").stopping)
        XCTAssertNil(rig.asRunning("a").failure)
    }

    func testALostConnectionClearsTheStopStateAndTheTasksShowStopped() {
        startStopping()

        rig.disconnect()

        XCTAssertFalse(rig.asRunning("a").stopping)
        XCTAssertEqual(rig.row("a")?.statusLabel, "stopped")
        rig.snapshot([rig.task("a")])
        XCTAssertFalse(rig.asRunning("a").stopping, "and it is not back after the reconnect's snapshot")
        XCTAssertNil(rig.asRunning("a").failure)
    }

    func testAnAnswerToAnOlderRequestCannotChangeANewerOne() {
        startStopping(accepted: false)                   // request 0
        rig.disconnect()
        rig.snapshot([rig.task("a")])
        rig.requestStop("a")                             // request 1

        rig.answer("refused", message: "stale", request: 0)

        XCTAssertTrue(rig.asRunning("a").stopping, "request 1 is still out")
        XCTAssertNil(rig.asRunning("a").failure)
        rig.answer("refused", message: "fresh", request: 1)
        XCTAssertEqual(rig.display("a").failure, "fresh")
    }

    // MARK: Publishing

    func testStopStateChangesArePublishedForTheFocusAndCoalescedLikeAnyOtherChange() {
        rig.snapshot([rig.task("a")])
        let watched: TSRig = rig
        var heard: [(tag: String, stopping: Bool, failure: String?)] = []
        rig.store.changes.sink { tag in
            let shown = watched.asRunning("a")
            heard.append((tag, shown.stopping, shown.failure))
        }.store(in: &bag)

        rig.requestStop("a")
        XCTAssertEqual(heard.count, 1, "the request is published at once")
        XCTAssertEqual(heard.first?.tag, TSRig.tag)
        XCTAssertEqual(heard.first?.stopping, true)

        rig.answer("refused", message: "first", advance: 0.05)
        rig.requestStop("a", advance: 0.05)
        rig.answer("refused", message: "second", request: 1, advance: 0.05)
        XCTAssertEqual(heard.count, 1, "changes within a quarter second wait for one delivery")

        rig.flushCoalescing()

        XCTAssertEqual(heard.count, 2, "three changes, one delivery")
        XCTAssertEqual(heard.last?.stopping, false)
        XCTAssertEqual(heard.last?.failure, "second", "and it carries the latest state")
    }

    func testAStopTimingOutIsPublished() {
        startStopping()
        let watched: TSRig = rig
        var failures: [String?] = []
        rig.store.changes.sink { _ in failures.append(watched.asRunning("a").failure) }.store(in: &bag)

        rig.fireConfirmation()

        XCTAssertEqual(failures.last ?? nil, "no confirmation from Claude Code")
    }

    // MARK: The status is never the store's to decide

    func testTheRowIsNeverStoppedWhileTheLatestSnapshotSaysRunning() {
        let ids = ["a", "b", "c"]
        let outcomes = ["accepted", "accepted", "refused", "timeout", "unsupported", "not_running", "surprise"]

        for seed in 1 ... 25 {
            let world = TSRig(self)
            var rng = TSSeededGenerator(seed: UInt64(seed))
            var latest: [String: TaskStatusWire] = [:]

            for step in 0 ..< 60 {
                let op = Int.random(in: 0 ..< 7, using: &rng)
                switch op {
                case 0, 1:
                    var tasks: [TaskMetaWire] = []
                    latest = [:]
                    for id in ids {
                        guard Int.random(in: 0 ..< 10, using: &rng) < 8 else { continue }
                        let status: TaskStatusWire = Int.random(in: 0 ..< 10, using: &rng) < 6 ? .running : .stopped
                        latest[id] = status
                        tasks.append(world.task(id, status: status))
                    }
                    world.snapshot(tasks)
                case 2:
                    let id = ids[Int.random(in: 0 ..< ids.count, using: &rng)]
                    if let row = world.row(id), !row.isEnded, world.asRunning(id).offered { world.requestStop(id) }
                case 3:
                    if !world.sender.stops.isEmpty {
                        let request = Int.random(in: 0 ..< world.sender.stops.count, using: &rng)
                        let outcome = outcomes[Int.random(in: 0 ..< outcomes.count, using: &rng)]
                        world.answer(outcome, message: Bool.random(using: &rng) ? "no such task" : nil, request: request)
                    }
                case 4:
                    world.fireConfirmation()
                case 5:
                    world.fireRequestTimeouts()
                default:
                    world.flushCoalescing()
                }

                for id in ids {
                    let context = "seed \(seed) step \(step) op \(op) task \(id)"
                    let status = latest[id]
                    let shown = world.asRunning(id)
                    if status == .running {
                        XCTAssertEqual(world.row(id)?.statusLabel, "running", context)
                        XCTAssertEqual(world.row(id)?.isEnded, false, context)
                    } else {
                        XCTAssertFalse(shown.stopping, "a task the snapshot shows over (or omits) is not being stopped: \(context)")
                        XCTAssertNil(shown.failure, context)
                    }
                    if shown.stopping { XCTAssertEqual(status, .running, context) }
                }
            }
        }
    }
}

// MARK: - The popover

final class TaskStopPopoverTests: XCTestCase {

    private var rig: TSRig!
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        TSGestureSeams.install(on: self)
        _ = NSApplication.shared
        rig = TSRig(self)
    }

    override func tearDown() {
        bag.removeAll()
        rig = nil
        super.tearDown()
    }

    private func loadList(stop: Bool? = true) {
        rig.snapshot([rig.task("job1", "npm run dev", startedAgo: 60),
                      rig.task("job2", "pnpm test", startedAgo: 30),
                      rig.task("done1", "npm run build", status: .completed, startedAgo: 120)], stop: stop)
    }

    private func rowView(_ vc: BackgroundPopoverViewController, _ id: String) throws -> BackgroundTaskRowView {
        try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == id }, "no visible row \(id)")
    }

    private func select(_ vc: BackgroundPopoverViewController, _ id: String) throws {
        let index = try XCTUnwrap(vc.selectables.firstIndex { ($0 as? BackgroundTaskRowView)?.row.id == id },
                                  "row \(id) cannot hold the selection")
        vc.select(index)
    }

    private func stopTitle(_ vc: BackgroundPopoverViewController, _ id: String) throws -> String {
        tsTitle(try rowView(vc, id).stopButton)
    }

    // MARK: Offering Stop

    func testARunningRowHasAStopButtonAndAnEndedRowHasNone() throws {
        loadList()
        let vc = rig.makeController()

        let running = try rowView(vc, "job1")
        let button = try XCTUnwrap(running.stopButton, "a running row offers Stop")
        XCTAssertFalse(button.isHidden)
        XCTAssertEqual(tsTitle(button), "Stop")
        XCTAssertEqual(button.accessibilityLabel(), "Stop " + running.row.title)

        let ended = try rowView(vc, "done1")
        XCTAssertTrue(ended.stopButton == nil || ended.stopButton?.isHidden == true, "an ended row offers nothing")
    }

    func testARowThatEndsLosesItsStopButton() throws {
        loadList()
        let vc = rig.makeController()
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop")

        rig.snapshot([rig.task("job1", "npm run dev", status: .completed), rig.task("job2", "pnpm test")])
        vc.reload()

        let ended = try rowView(vc, "job1")
        XCTAssertTrue(ended.stopButton?.isHidden ?? true)
    }

    func testWhenTheCLICannotStopTasksThereIsNoStopButtonOrMenuItem() throws {
        loadList(stop: false)
        let vc = rig.makeController()

        for id in ["job1", "job2"] {
            let view = try rowView(vc, id)
            XCTAssertTrue(view.stopButton == nil || view.stopButton?.isHidden == true, "\(id)")
            XCTAssertFalse(vc.contextMenu(for: view.row).items.map { $0.title }.contains("Stop"), "\(id)")
        }
    }

    func testTheWindowActionsOfferStopOnlyForATaskThatCanBeStoppedAndNeverSendOnTheirOwn() throws {
        loadList()
        let actions = BackgroundTaskWindowActions()
        let rows = rig.store.list(for: TSRig.tag)

        XCTAssertTrue(actions.canStop(try XCTUnwrap(rows.running.first), tag: TSRig.tag))
        XCTAssertFalse(actions.canStop(try XCTUnwrap(rows.ended.first), tag: TSRig.tag))
        actions.stop(try XCTUnwrap(rows.running.first), tag: TSRig.tag)
        XCTAssertTrue(rig.sender.stops.isEmpty, "Stop is the button's two clicks, never one call")
    }

    // MARK: ⌘.

    func testCommandPeriodStartsTheTwoStepForTheSelectedRowAndTwiceSendsExactlyOneStop() throws {
        loadList()
        let vc = rig.makeController()
        try select(vc, "job1")

        XCTAssertTrue(vc.handleKey(tsCommandPeriod()), "the popover takes ⌘. (it never reaches the input bar's interrupt)")
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop?")
        XCTAssertTrue(rig.sender.stops.isEmpty)

        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stopping\u{2026}")
        XCTAssertEqual(rig.sender.stops.map { $0.taskId }, ["job1"])
        XCTAssertEqual(rig.sender.stops.map { $0.tag }, [TSRig.tag])
        XCTAssertTrue(rig.display("job1").stopping, "the store shows it too")

        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))
        XCTAssertEqual(rig.sender.stops.count, 1, "a third ⌘. sends nothing more")
        XCTAssertTrue(rig.sender.outputs.isEmpty, "and nothing but session_task_stop was ever asked of the daemon")
    }

    func testCommandPeriodActsOnTheSelectedRowOnly() throws {
        loadList()
        let vc = rig.makeController()
        try select(vc, "job2")

        _ = vc.handleKey(tsCommandPeriod())
        _ = vc.handleKey(tsCommandPeriod())

        XCTAssertEqual(rig.sender.stops.map { $0.taskId }, ["job2"])
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop")
    }

    func testCommandPeriodWithoutAStoppableSelectionDoesNothingButIsStillConsumed() throws {
        loadList()
        let vc = rig.makeController()

        vc.select(nil)
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))

        try select(vc, "done1")
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))

        XCTAssertTrue(rig.sender.stops.isEmpty)
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop")
        XCTAssertEqual(try stopTitle(vc, "job2"), "Stop")
    }

    func testCommandPeriodWithARefusedGestureChangesNothing() throws {
        loadList()
        let vc = rig.makeController()
        try select(vc, "job1")

        rig.verdict = .refused(reason: .appControl)
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()), "still the popover's key")
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop")

        rig.verdict = tsHuman
        _ = vc.handleKey(tsCommandPeriod())
        rig.verdict = .refused(reason: .staleEvent)
        _ = vc.handleKey(tsCommandPeriod())

        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop?", "a refused second press does not send")
        XCTAssertTrue(rig.sender.stops.isEmpty)
    }

    func testTwoPressesFarApartAreNotAConfirmation() throws {
        loadList()
        let vc = rig.makeController()
        try select(vc, "job1")

        _ = vc.handleKey(tsCommandPeriod())
        rig.buttonSchedule.fireAll()                     // 3 s pass
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop")
        _ = vc.handleKey(tsCommandPeriod())

        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop?")
        XCTAssertTrue(rig.sender.stops.isEmpty)
    }

    // MARK: Context menu

    func testTheContextMenusStopArmsTheRowsButtonAndNeverSendsByItself() throws {
        loadList()
        let vc = rig.makeController()
        let menu = vc.contextMenu(for: try rowView(vc, "job1").row)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Stop" },
                                  "the menu offers Stop: \(menu.items.map { $0.title })")

        menu.performActionForItem(at: index)
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop?")
        XCTAssertTrue(rig.sender.stops.isEmpty)

        menu.performActionForItem(at: index)
        XCTAssertTrue(rig.sender.stops.isEmpty, "choosing Stop again is not the second click")

        try rowView(vc, "job1").stopButton?.clicked(nil)
        XCTAssertEqual(rig.sender.stops.count, 1)
    }

    func testARefusedMenuGestureDoesNothingAndTheMenuHasItsOwnGestureCheck() throws {
        loadList()
        let vc = rig.makeController()
        let menu = vc.contextMenu(for: try rowView(vc, "job1").row)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Stop" })

        rig.menuVerdict = .refused(reason: .accessibilityPress)
        menu.performActionForItem(at: index)
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop", "a refused menu selection does nothing")

        rig.menuVerdict = tsHuman
        rig.verdict = .refused(reason: .appControl)
        menu.performActionForItem(at: index)
        XCTAssertEqual(try stopTitle(vc, "job1"), "Stop?", "the menu is judged by the menu's check")
    }

    func testTheMenuHasNoStopForAnEndedRow() throws {
        loadList()
        let vc = rig.makeController()

        let menu = vc.contextMenu(for: try rowView(vc, "done1").row)

        XCTAssertFalse(menu.items.map { $0.title }.contains("Stop"))
    }

    // MARK: Shared state

    func testTwoPopoversOnTheSameTaskShowTheSameStoppingAndTheSameFailure() throws {
        loadList()
        let first = rig.makeController()
        let second = rig.makeController()
        rig.store.changes.sink { _ in
            first.reload()
            second.reload()
        }.store(in: &bag)
        try select(first, "job1")

        rig.clock.advance(1)
        _ = first.handleKey(tsCommandPeriod())
        _ = first.handleKey(tsCommandPeriod())

        XCTAssertEqual(try stopTitle(first, "job1"), "Stopping\u{2026}")
        XCTAssertEqual(try stopTitle(second, "job1"), "Stopping\u{2026}", "the other popover shows it too")
        XCTAssertEqual(try rowView(second, "job1").stopButton?.isEnabled, false)
        XCTAssertEqual(try stopTitle(second, "job2"), "Stop", "and only for that task")

        rig.answer("refused", message: "Task is protected")

        for vc in [first, second] {
            let view = try rowView(vc, "job1")
            XCTAssertEqual(view.stopNoticeText, "Couldn't stop: Task is protected")
            XCTAssertEqual(tsTitle(view.stopButton), "Stop", "the button is back, with the real status beside the notice")
            XCTAssertEqual(view.statusText, "running")
        }
        XCTAssertEqual(try rowView(second, "job2").stopNoticeText, "")
    }

    func testVoiceOverHearsStoppingAndTheFailureAsTheRowsValue() throws {
        loadList()
        let vc = rig.makeController()
        rig.store.changes.sink { _ in vc.reload() }.store(in: &bag)
        try select(vc, "job1")
        XCTAssertNil(try rowView(vc, "job1").accessibilityValue(), "nothing to add while all is well")

        rig.clock.advance(1)
        _ = vc.handleKey(tsCommandPeriod())
        _ = vc.handleKey(tsCommandPeriod())
        XCTAssertEqual(try rowView(vc, "job1").accessibilityValue() as? String, "Stopping\u{2026}")

        rig.answer("refused", message: "Task is protected")
        let view = try rowView(vc, "job1")
        XCTAssertEqual(view.accessibilityValue() as? String, "Couldn't stop: Task is protected")
        XCTAssertNil(try rowView(vc, "job2").accessibilityValue(), "only the failed row says it")
    }

    func testARowBuiltWhileStopWasUnsupportedGetsItsButtonWhenSupportTurnsOn() throws {
        loadList(stop: false)
        let vc = rig.makeController()
        let view = try rowView(vc, "job1")
        XCTAssertNil(view.stopButton, "precondition: no button while the CLI cannot stop tasks")

        loadList(stop: true)
        vc.reload()

        let later = try rowView(vc, "job1")
        XCTAssertTrue(later === view, "the same row view")
        XCTAssertEqual(later.stopButton?.isHidden, false, "support turned on: the row now offers Stop")
        XCTAssertEqual(tsTitle(later.stopButton), "Stop")
    }

    func testAHostileFailureNeverChangesARowsSizeOrLeavesItsBounds() throws {
        rig.snapshot([rig.task("job1", "npm run dev")])
        let row = try XCTUnwrap(rig.row("job1"))
        let width = BackgroundPopoverViewController.width - 8
        let height = BackgroundTaskRowView.height(for: row)
        let window = makeRigWindow(self, size: NSSize(width: width, height: height))
        let view = BackgroundTaskRowView(row: row)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.addSubview(view)
        view.installStop(TaskStopButton(requestStop: { _ in }))
        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }
        layout()
        XCTAssertEqual(view.stopNoticeText, "", "precondition: no notice yet")

        rig.requestStop("job1")
        rig.answer("refused", message: tsHostileReason)
        view.applyStop(rig.display("job1"))
        layout()

        XCTAssertTrue(view.stopNoticeText.hasPrefix("Couldn't stop: "), view.stopNoticeText)
        XCTAssertEqual(view.frame.width, width, accuracy: 0.5, "the row keeps the width it was given")
        XCTAssertEqual(view.frame.height, height, accuracy: 0.5)
        for sub in rigAllSubviews(of: view) where !sub.isHidden {
            let frame = sub.convert(sub.bounds, to: view)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(type(of: sub)) \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, view.bounds.width + 0.5,
                                     "\(type(of: sub)) \(frame) extends past the row's \(view.bounds.width) pt")
        }
        let notice = rigAllSubviews(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == view.stopNoticeText }
        XCTAssertLessThanOrEqual(notice?.frame.width ?? .infinity, 200.5, "the notice never takes more than a third of the row")
    }

    // MARK: Teardown

    func testARowViewItsButtonAndTheControllerAreReleasedOnceTheirTaskIsForgotten() throws {
        loadList()
        var vc: BackgroundPopoverViewController?
        weak var weakRow: BackgroundTaskRowView?
        weak var weakButton: TaskStopButton?
        weak var weakController: BackgroundPopoverViewController?
        // Everything that touches the views runs inside a pool: AppKit hands back autoreleased
        // `subviews` arrays that would otherwise keep the rows alive until the test method ends.
        try autoreleasepool {
            let made = rig.makeController()
            vc = made
            weakController = made
            let view = try rowView(made, "job1")
            weakRow = view
            weakButton = view.stopButton
            view.stopButton?.clicked(nil)               // a revert timer is pending
        }

        autoreleasepool {
            rig.store.forget(tag: TSRig.tag)
            vc?.reload()
        }
        tsDrain()

        XCTAssertNil(weakRow, "the row view of a forgotten task is gone")
        XCTAssertNil(weakButton, "and so is its button")
        XCTAssertNotNil(weakController)

        vc = nil
        tsDrain()
        XCTAssertNil(weakController, "the controller lets go too")
        rig.buttonSchedule.fireAll()                    // the pending timer is harmless
    }
}

// MARK: - The task window

final class TaskStopWindowTests: XCTestCase {

    private var rig: TSRig!

    override func setUp() {
        super.setUp()
        TSGestureSeams.install(on: self)
        _ = NSApplication.shared
        rig = TSRig(self)
    }

    override func tearDown() {
        rig.manager.closeAll()
        rig = nil
        super.tearDown()
    }

    private func open(_ id: String) throws -> TaskWindowController {
        try XCTUnwrap(rig.manager.open(tag: TSRig.tag, taskId: id), "\(id) did not open")
    }

    private func layout(_ controller: TaskWindowController) {
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        rigSettle(0.05)
        controller.panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: Offering Stop

    func testEveryKindOfWindowHasAStopButtonWhileTheTaskRuns() throws {
        rig.snapshot([rig.task("sh", "npm run dev"),
                      rig.task("ag", "Find callers", kind: .agent),
                      rig.task("wf", "nightly", kind: .workflow)])

        for id in ["sh", "ag", "wf"] {
            let header = try open(id).body.header
            let button = try XCTUnwrap(header.stopButton, "\(id): the header has a Stop")
            XCTAssertFalse(button.isHidden, id)
            XCTAssertEqual(tsTitle(button), "Stop", id)
            XCTAssertEqual(button.accessibilityLabel(), "Stop " + header.descriptionText, id)
            XCTAssertEqual(header.stopNoticeText, "", id)
        }
    }

    func testALongDescriptionIsCutInTheButtonsAccessibilityLabel() throws {
        let long = String(repeating: "x", count: 200)
        rig.snapshot([rig.task("wf", long, kind: .workflow)])

        let button = try XCTUnwrap(try open("wf").body.header.stopButton)

        XCTAssertEqual(button.accessibilityLabel(), "Stop " + String(repeating: "x", count: TaskStopButton.maxDescriptionInLabel))
    }

    func testTheButtonGoesWhenTheTaskEnds() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let header = try open("wf").body.header
        XCTAssertEqual(header.stopButton?.isHidden, false)

        rig.snapshot([rig.task("wf", "nightly", kind: .workflow, status: .completed)])

        XCTAssertEqual(header.stopButton?.isHidden, true, "an ended task has nothing to stop")
    }

    func testWhenTheCLICannotStopTasksTheHeaderSaysSoAndHasNoButton() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)], stop: false)

        let header = try open("wf").body.header

        XCTAssertEqual(header.stopNoticeText, "This Claude Code version can't stop tasks from Nostromo")
        XCTAssertTrue(header.stopButton == nil || header.stopButton?.isHidden == true)
    }

    func testAnEndedTaskDoesNotSayTheCLICannotStopIt() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow, status: .completed)], stop: false)

        let header = try open("wf").body.header

        XCTAssertEqual(header.stopNoticeText, "")
        XCTAssertTrue(header.stopButton == nil || header.stopButton?.isHidden == true)
    }

    // MARK: ⌘.

    func testCommandPeriodInAWindowCallsItsStopShortcutAndIsConsumed() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let controller = try open("wf")
        var calls = 0
        controller.panel.onStopShortcut = { _ in calls += 1 }

        let handled = controller.panel.performKeyEquivalent(with: tsCommandPeriod())

        XCTAssertTrue(handled)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.isOpen, "and it does not close the window")
    }

    func testCommandPeriodTwiceInAWindowSendsExactlyOneStop() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let controller = try open("wf")

        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))
        XCTAssertEqual(tsTitle(controller.body.header.stopButton), "Stop?")
        XCTAssertTrue(rig.sender.stops.isEmpty)
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))

        XCTAssertEqual(rig.sender.stops.map { $0.taskId }, ["wf"])
        XCTAssertEqual(tsTitle(controller.body.header.stopButton), "Stopping\u{2026}")
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))
        XCTAssertEqual(rig.sender.stops.count, 1)
    }

    func testCommandPeriodWithARefusedGestureIsConsumedAndDoesNothing() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let controller = try open("wf")
        rig.verdict = .refused(reason: .appControl)

        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))

        XCTAssertEqual(tsTitle(controller.body.header.stopButton), "Stop")
        XCTAssertTrue(rig.sender.stops.isEmpty)
    }

    func testCommandPeriodInTheWindowOfAnEndedTaskIsConsumedAndSendsNothing() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow, status: .completed)])
        let controller = try open("wf")

        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))

        XCTAssertTrue(rig.sender.stops.isEmpty)
    }

    // MARK: Shared state

    func testTheWindowShowsWhatAPopoverStartedAndWhatCameOfIt() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let controller = try open("wf")
        let vc = rig.makeController(actions: BackgroundTaskWindowActions(manager: rig.manager))
        try selectRow(vc, "wf")
        rig.clock.advance(1)

        _ = vc.handleKey(tsCommandPeriod())
        _ = vc.handleKey(tsCommandPeriod())

        let header = controller.body.header
        XCTAssertEqual(tsTitle(header.stopButton), "Stopping\u{2026}", "the window shows what the popover started")
        XCTAssertEqual(header.stopButton?.isEnabled, false)

        rig.answer("refused", message: "Task is protected")

        XCTAssertEqual(header.stopNoticeText, "Couldn't stop: Task is protected")
        XCTAssertEqual(tsTitle(header.stopButton), "Stop")

        rig.snapshot([rig.task("wf", "nightly", kind: .workflow, status: .stopped)])
        XCTAssertEqual(header.stopNoticeText, "", "once the task is over there is nothing to say about stopping it")
        XCTAssertEqual(header.stopButton?.isHidden, true)
    }

    private func selectRow(_ vc: BackgroundPopoverViewController, _ id: String) throws {
        let index = try XCTUnwrap(vc.selectables.firstIndex { ($0 as? BackgroundTaskRowView)?.row.id == id })
        vc.select(index)
    }

    func testAHostileFailureNeverWidensTheHeaderOrLeavesIt() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        let controller = try open("wf")
        controller.panel.setContentSize(TaskWindowFrame.minimumSize)
        layout(controller)
        let header = controller.body.header
        let panelSize = controller.panel.frame.size
        let headerWidth = header.frame.width

        rig.requestStop("wf")
        rig.answer("refused", message: tsHostileReason)
        layout(controller)

        XCTAssertTrue(header.stopNoticeText.hasPrefix("Couldn't stop: "), header.stopNoticeText)
        XCTAssertEqual(controller.panel.frame.size.width, panelSize.width, accuracy: 0.5, "the window did not widen")
        XCTAssertEqual(controller.panel.frame.size.height, panelSize.height, accuracy: 0.5)
        XCTAssertEqual(header.frame.width, headerWidth, accuracy: 0.5, "nor did the header")
        let labels = rigAllSubviews(of: header).compactMap { $0 as? NSTextField }
        let notice = try XCTUnwrap(labels.first { $0.stringValue == header.stopNoticeText })
        var inside: [NSView] = [notice]
        if let button = header.stopButton { inside.append(button) }
        for view in inside {
            let frame = view.convert(view.bounds, to: header)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(type(of: view)) \(frame)")
            XCTAssertLessThanOrEqual(frame.maxX, header.bounds.width + 0.5,
                                     "\(type(of: view)) \(frame) extends past the header's \(header.bounds.width) pt")
        }
    }

    // MARK: Teardown

    func testClosingAWindowReleasesItsHeaderButtonAndControllerAndItsTimerIsHarmless() throws {
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow)])
        weak var weakController: TaskWindowController?
        weak var weakHeader: TaskWindowHeaderView?
        weak var weakButton: TaskStopButton?
        try autoreleasepool {
            let controller = try open("wf")
            weakController = controller
            weakHeader = controller.body.header
            weakButton = controller.body.header.stopButton
            controller.body.header.stopButton?.clicked(nil)   // a revert timer is pending
            controller.close()
        }
        tsDrain()

        XCTAssertFalse(rig.manager.isOpen(tag: TSRig.tag, taskId: "wf"))
        XCTAssertNil(weakController)
        XCTAssertNil(weakHeader)
        XCTAssertNil(weakButton)
        rig.buttonSchedule.fireAll()
        rig.snapshot([rig.task("wf", "nightly", kind: .workflow, status: .completed)])   // and so is a later change
    }
}

// MARK: - Nothing is logged

final class TaskStopLoggingTests: XCTestCase {

    private static let sources = [
        "Nostromo/UI/Background/TaskStopButton.swift",
        "Nostromo/Data/BackgroundTaskStore.swift",
        "Nostromo/UI/Background/BackgroundTaskRowView.swift",
    ]

    /// The file's code without its comment lines.
    private static func code(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)        // .../macOS/NostromoTests/TaskStopTests.swift
            .deletingLastPathComponent()                   // .../macOS/NostromoTests
            .deletingLastPathComponent()                   // .../macOS
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func loggingCalls(in code: String) -> [String] {
        let patterns = [#"\bprint\("#, #"\bdebugPrint\("#, #"\bNSLog\("#, #"\bos_log\("#, #"\bLogger\b"#,
                        #"\blog\.(debug|info|notice|warning|error|fault)"#, #"\bappLog\."#]
        return patterns.filter { code.range(of: $0, options: .regularExpression) != nil }
    }

    func testTheLoggingScanSeesCallsButNotComments() {
        XCTAssertFalse(Self.loggingCalls(in: "print(\"\\(reason)\")").isEmpty)
        XCTAssertFalse(Self.loggingCalls(in: "NSLog(\"%@\", text)").isEmpty)
        XCTAssertFalse(Self.loggingCalls(in: "let l = Logger(subsystem: \"a\", category: \"b\")").isEmpty)
        XCTAssertTrue(Self.loggingCalls(in: "let blog = 1").isEmpty, "a word that merely contains `log` is not a call")
        XCTAssertTrue(Self.loggingCalls(in: "let total = 1").isEmpty)
    }

    func testNoStopSourceLogsAReasonADescriptionOrOutput() throws {
        var hits: [String] = []
        for path in Self.sources {
            for hit in Self.loggingCalls(in: try Self.code(path)) { hits.append("\(path): \(hit)") }
        }

        XCTAssertTrue(hits.isEmpty, """
            Stop's files must not log: a refusal reason, a task description or an output line in a log line is \
            content in a log. Found: \(hits.joined(separator: "; "))
            """)
    }
}

// MARK: - Only the button may ask for a stop

/// The gate lives in `TaskStopButton`, and the compiler enforces it: `BackgroundTaskStore.requestStop` needs a
/// `StopConfirmation`, whose initializer is `fileprivate` to `TaskStopButton.swift`. This scan is the second
/// line: nothing but the two button closures (the popover's row button and the task window's header button)
/// may call `requestStop`, and nothing outside `TaskRequests` may reach the daemon's stop verb by another
/// road. A third route would be a Stop that skipped the gate.
final class TaskStopGateFitnessTests: XCTestCase {

    private static let nostromo = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/TaskStopTests.swift
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Nostromo")

    /// Every call on an object (`x.requestStop(`, `x?.requestStop(`) in `code`; definitions and the button's
    /// own closure (`requestStop()`) are not calls on one.
    private static func calls(in code: String) -> Int {
        code.components(separatedBy: ".requestStop(").count - 1
    }

    private static func matches(_ pattern: String, in code: String) -> Int {
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    private static func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Relative path -> code (comment lines dropped) for every Swift file of the app.
    private static func sources() throws -> [String: String] {
        var all: [String: String] = [:]
        let files = try XCTUnwrap(FileManager.default.enumerator(at: nostromo, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            all[String(url.path.dropFirst(nostromo.path.count + 1))] = try code(url)
        }
        return all
    }

    /// Per file, how many times `pattern` matches, for the files where it does.
    private static func hits(_ pattern: String, in sources: [String: String]) -> [String: Int] {
        sources.compactMapValues { code in
            let count = matches(pattern, in: code)
            return count > 0 ? count : nil
        }
    }

    func testTheScanSeesACallOnAnObjectButNotADefinitionOrAComment() {
        XCTAssertEqual(Self.calls(in: "store.requestStop(tag: t, taskId: i)"), 1)
        XCTAssertEqual(Self.calls(in: "store?.requestStop(tag: t, taskId: i)"), 1)
        XCTAssertEqual(Self.calls(in: "func requestStop(tag: String, taskId: String) {"), 0)
        XCTAssertEqual(Self.calls(in: "requestStop()"), 0)
    }

    func testTheWidenedScansSeeTheWaysAroundTheCallScan() {
        let bareCall = #"requestStop\(tag:"#
        XCTAssertEqual(Self.matches(bareCall, in: "requestStop(tag: t, taskId: i)"), 1, "a bare call in a store extension")
        XCTAssertEqual(Self.matches(bareCall, in: "store.requestStop(tag: t"), 1)

        let reference = #"requestStop(?!\s*[(:])"#
        XCTAssertEqual(Self.matches(reference, in: "let f = store.requestStop"), 1, "a function reference")
        XCTAssertEqual(Self.matches(reference, in: "let f = store.requestStop\n"), 1)
        XCTAssertEqual(Self.matches(reference, in: "#selector(Store.requestStop)"), 1)
        XCTAssertEqual(Self.matches(reference, in: "func requestStop(tag: t) {"), 0)
        XCTAssertEqual(Self.matches(reference, in: "requestStop: { _ in }"), 0)

        let wire = #"sendTaskStop\(|ClientMsg\.sessionTaskStop\b|ClientSessionTaskStop\b|\.sessionTaskStop\b|"session_task_stop""#
        XCTAssertEqual(Self.matches(wire, in: "sender.sendTaskStop(requestId: r, tag: t, taskId: i)"), 1)
        XCTAssertEqual(Self.matches(wire, in: "send(ClientMsg.sessionTaskStop(x))"), 1)
        XCTAssertEqual(Self.matches(wire, in: "ServerMsg.sessionTaskStopResult(x)"), 0, "the answer is not the verb")
    }

    func testRequestStopIsCalledOnlyFromTheTwoButtonClosuresAndTheStoreItself() throws {
        let allowed: [String: Int] = [
            "UI/Background/BackgroundPopover.swift": 1,        // the row button's requestStop closure
            "UI/Background/TaskWindowHeaderView.swift": 1,     // the header button's requestStop closure
            "Data/BackgroundTaskStore.swift": 1,               // the store forwarding to TaskRequests
        ]
        var found: [String: Int] = [:]
        for (path, code) in try Self.sources() {
            let count = Self.calls(in: code)
            if count > 0 { found[path] = count }
        }

        XCTAssertEqual(found, allowed, "requestStop( may be called only from the two button closures")
    }

    /// A bare `requestStop(tag:` (no receiver) or a reference to the function (`store.requestStop`,
    /// `#selector`, a key path) would not show in the call scan above.
    func testNoBareCallOrFunctionReferenceToRequestStop() throws {
        let sources = try Self.sources()

        XCTAssertEqual(Self.hits(#"requestStop\(tag:"#, in: sources),
                       ["UI/Background/BackgroundPopover.swift": 1,
                        "UI/Background/TaskWindowHeaderView.swift": 1,
                        "Data/BackgroundTaskStore.swift": 2,          // its definition, and the forward to TaskRequests
                        "Data/TaskRequests.swift": 1],                // the daemon-facing definition
                       "requestStop(tag: appears only where a button closure, the store or TaskRequests puts it")

        // Outside the button itself (its own `requestStop` closure property), the name is a call or a label.
        let outsideTheButton = sources.filter { $0.key != "UI/Background/TaskStopButton.swift" }
        XCTAssertEqual(Self.hits(#"requestStop(?!\s*[(:])"#, in: outsideTheButton), [:],
                       "a function reference to requestStop would route around the call scan")
    }

    /// `session_task_stop` is sent by `TaskRequests` through its sender, and only `TaskRequests.requestStop`
    /// calls the sender's `sendTaskStop`; the sender itself (`NostromodClient`) is the one place the wire
    /// message is built.
    func testTheDaemonsStopVerbIsReachedOnlyThroughTaskRequests() throws {
        let sources = try Self.sources()

        XCTAssertEqual(Self.hits(#"sendTaskStop\("#, in: sources),
                       ["Data/TaskRequests.swift": 2,        // the sender protocol's requirement and its one call
                        "Data/NostromodClient.swift": 1],    // the sender's implementation
                       "sendTaskStop( is called from TaskRequests only")

        let nonDefinitions = sources.mapValues { $0.replacingOccurrences(of: "func sendTaskStop(", with: "") }
        XCTAssertEqual(Self.hits(#"sendTaskStop\("#, in: nonDefinitions), ["Data/TaskRequests.swift": 1])

        XCTAssertEqual(Self.hits(#"ClientMsg\.sessionTaskStop\b|\.sessionTaskStop\b|ClientSessionTaskStop\b|"session_task_stop""#,
                                 in: sources),
                       ["Data/NostromodClient.swift": 2],    // building and tagging the message in `sendTaskStop`
                       "the stop message is built only where the sender builds it")
    }

    func testTheTwoCallersAreInsideTheButtonsRequestStopClosure() throws {
        for path in ["UI/Background/BackgroundPopover.swift", "UI/Background/TaskWindowHeaderView.swift"] {
            let code = try Self.code(Self.nostromo.appendingPathComponent(path))
            XCTAssertNotNil(code.range(of: #"requestStop:\s*\{[\s\S]{0,200}?\.requestStop\("#, options: .regularExpression),
                            "\(path): the call must sit in a TaskStopButton's requestStop closure")
        }
    }
}
