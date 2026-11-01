import XCTest
import AppKit
import NostromoKit

// BA3: the Background activity chip, its slot in the input bar, and the shortcut that opens the popover.
//
// Covers (PRD "The chip", Phase 1; design contract 2.7 and 2.8):
//   - the chip's text, state, tooltip, accessibility label and hidden state for running, done, failed;
//   - the slot the input bar reserves (`BackgroundChip.slotWidth`) fits every chip state and never changes;
//   - updating the chip never moves keyboard focus, never changes the bar's size, never rewraps the composer;
//   - `canShowBackgroundPopover` / `validateMenuItem`, two bars on one store showing the same chip,
//     `BackgroundShortcut.bar(in:)` choosing the focused pane's bar;
//   - the main menu: exactly one item on shift-command-B (Session > Background Activity...), Debug's
//     Capture render state moved to option-shift-command-B;
//   - shift-command-B in the composer opens the popover and leaves the composer text alone.
//
// This file also holds the support types the other three BA3 UI test files share (`BA3UI*`): a clock and
// schedulers moved by hand, a `BackgroundTaskStore` over a private UserDefaults suite, task builders and
// key-event builders. Nothing here reads the wall clock, the real pasteboard, the app's UserDefaults domain,
// a daemon or the user's app.

// MARK: - Shared support (BA3UI*)

/// A clock the test moves by hand.
final class BA3UIClock {
    /// Seconds since 1970 when the world began.
    let start: TimeInterval
    private(set) var time: TimeInterval

    init(start: TimeInterval = 1_800_000_000) {
        self.start = start
        time = start
    }

    var date: Date { Date(timeIntervalSince1970: time) }
    var nowMs: UInt64 { UInt64(time * 1000) }

    func advance(_ seconds: TimeInterval) { time += seconds }
}

/// The store's own scheduler for coalesced deliveries (at most four a second per focus). It runs the
/// deferred delivery at once: these tests are about what the chip and popover do with a delivery, not about
/// the coalescing window (`BackgroundTaskStoreTests` owns that), and a delivery that never ran would leave
/// the store believing one is still due and swallow every later change.
final class BA3UIStoreScheduler {
    /// Every delay asked for, in order.
    private(set) var delays: [TimeInterval] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        delays.append(delay)
        work()
    }
}

/// The popover's one-second tick (`ElapsedTicker.Schedule`): one-shots held by hand.
final class BA3UITickScheduler {
    private struct Timer {
        let id: Int
        let delay: TimeInterval
        let fire: () -> Void
    }

    private var timers: [Timer] = []
    private var nextId = 0
    /// Every delay ever asked for, in order.
    private(set) var requestedDelays: [TimeInterval] = []

    /// One-shots waiting to fire (cancelled ones are gone).
    var pendingCount: Int { timers.count }
    var pendingDelays: [TimeInterval] { timers.map(\.delay) }

    func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let id = nextId
        nextId += 1
        timers.append(Timer(id: id, delay: delay, fire: fire))
        requestedDelays.append(delay)
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    /// Fire the oldest waiting tick. False when none waits.
    @discardableResult
    func fireNext() -> Bool {
        guard !timers.isEmpty else { return false }
        let next = timers.removeFirst()
        next.fire()
        return true
    }
}

enum BA3UIKey {
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53

    /// The characters AppKit reports for the keys the popover handles.
    private static func defaultCharacters(_ code: UInt16) -> String {
        switch code {
        case down: return "\u{F701}"
        case up: return "\u{F700}"
        case left: return "\u{F702}"
        case right: return "\u{F703}"
        case returnKey: return "\r"
        case escape: return "\u{1B}"
        default: return ""
        }
    }

    static func event(_ type: NSEvent.EventType = .keyDown, _ code: UInt16, _ characters: String = "",
                      flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let text = characters.isEmpty ? defaultCharacters(code) : characters
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                context: nil, characters: text, charactersIgnoringModifiers: text,
                                isARepeat: false, keyCode: code)!
    }

    static func keyDown(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        event(.keyDown, code, characters, flags: flags)
    }
}

/// A store with an injected clock and scheduler over a private UserDefaults suite (removed at teardown),
/// with task builders. Task times are relative to the moment the world began, so a task built early keeps
/// its start while `clock` moves on and its elapsed time grows.
final class BA3UIWorld {
    let clock: BA3UIClock
    let storeScheduler: BA3UIStoreScheduler
    let store: BackgroundTaskStore

    /// `requests` and `schedule` are for BA5's Stop gate: a recording daemon behind `requestStop`, and timers
    /// held by hand (the default scheduler runs its work at once).
    init(_ testCase: XCTestCase, requests: (() -> TaskRequests)? = nil,
         schedule hand: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        let clock = BA3UIClock()
        let scheduler = BA3UIStoreScheduler()
        self.clock = clock
        self.storeScheduler = scheduler
        let suite = "BA3-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let schedule: (TimeInterval, @escaping () -> Void) -> Void = hand ?? { delay, work in scheduler.schedule(delay, work) }
        if let requests {
            store = BackgroundTaskStore(now: { clock.date }, schedule: schedule, defaults: defaults, requests: requests)
        } else {
            store = BackgroundTaskStore(now: { clock.date }, schedule: schedule, defaults: defaults)
        }
        store.tasksSupported = true
        testCase.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    }

    /// `seconds` before the world began (negative: after).
    func stamp(_ secondsAgo: Double) -> UInt64 {
        UInt64(Int64((clock.start * 1000).rounded()) - Int64((secondsAgo * 1000).rounded()))
    }

    func task(_ id: String, kind: TaskKindWire = .shell, _ description: String,
              status: TaskStatusWire = .running, startedAgo: Double? = 5, endedAgo: Double? = nil,
              durationMs: UInt64? = nil, parent: String? = nil, housekeeping: Bool = false,
              subagentType: String? = nil, tokens: UInt64? = nil, toolUses: UInt64? = nil,
              lastTool: String? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: description, subagentType: subagentType,
                     parentTaskId: parent, isBackgrounded: kind == .shell ? true : nil,
                     housekeeping: housekeeping, status: status,
                     startedAtMs: startedAgo.map(stamp), endedAtMs: endedAgo.map(stamp),
                     durationMs: durationMs, totalTokens: tokens, toolUses: toolUses, lastToolName: lastTool)
    }

    /// Two running (a subagent and the shell it started), three ended (completed, failed, stopped) and one
    /// housekeeping task. At the world's start the agent has run 2 m 05 s.
    func fixture() -> [TaskMetaWire] {
        [
            task("agent", kind: .agent, "Write failing tests for the chip", startedAgo: 125,
                 subagentType: "redd", tokens: 18_200, toolUses: 11, lastTool: "Edit"),
            task("child", "cargo test -p nostromo", startedAgo: 40, parent: "agent"),
            task("built", "npm run build", status: .completed, startedAgo: 312, endedAgo: 240, durationMs: 72_000),
            task("explore", kind: .agent, "Find callers of the old API", status: .failed, startedAgo: 578,
                 endedAgo: 540, durationMs: 38_000, subagentType: "explore"),
            task("dev", "pnpm dev", status: .stopped, startedAgo: 4_000, endedAgo: 1_320),
            task("chore", "ambient watcher", startedAgo: 900, housekeeping: true),
        ]
    }

    /// `count` running shells, newest first by id order, all different from any smaller count.
    func running(_ count: Int) -> [TaskMetaWire] {
        (0 ..< count).map { task("job\($0)", "job number \($0)", startedAgo: Double(1_000 - $0)) }
    }

    /// Deliver a snapshot. The clock moves first (default one second, past the store's 4 Hz coalescing
    /// window, so the change goes out at once).
    func ingest(_ tasks: [TaskMetaWire], tag: String = "gate", advance: TimeInterval = 1,
                epoch: String = "epoch-1") {
        clock.advance(advance)
        store.ingest(.sessionTasks(SessionTasksWire(tag: tag, sessionId: "session-1", daemonEpoch: epoch,
                                                    stopSupported: true, tasks: tasks)))
    }

    func detail(_ taskId: String, tag: String = "gate", preview: String? = nil, progressSummary: String? = nil,
                advance: TimeInterval = 1) {
        clock.advance(advance)
        store.ingest(.sessionTaskDetail(SessionTaskDetailWire(tag: tag, taskId: taskId, preview: preview,
                                                              progressSummary: progressSummary)))
    }

    func markSeen(_ tag: String = "gate") {
        clock.advance(1)
        store.markSeen(tag: tag)
    }
}

/// An offscreen window that can be shown (so an `NSPopover` can anchor to it). Closed by `makeRigWindow`'s teardown.
func ba3uiVisibleWindow(_ testCase: XCTestCase, size: NSSize = NSSize(width: 600, height: 60)) -> RigWindow {
    let window = makeRigWindow(testCase, size: size)
    // Ordering a window in with the default animation can leak a worker thread in a test process.
    window.animationBehavior = .none
    window.orderFront(nil)
    return window
}

/// A real input bar in `window`, bound to `tag` on `store`.
@discardableResult
func ba3uiMakeBar(in window: NSWindow, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 60),
                  tag: String = "gate", store: BackgroundTaskStore, displayName: String? = "Claudia",
                  bind: Bool = true) -> ReplInputBar {
    let bar = ReplInputBar(frame: frame)
    window.contentView?.addSubview(bar)
    if bind { bar.bindBackground(tag: tag, store: store, displayName: displayName) }
    window.contentView?.layoutSubtreeIfNeeded()
    return bar
}

// MARK: - Tests

final class BackgroundChipTests: XCTestCase {

    private var world: BA3UIWorld!
    private var bars: [ReplInputBar] = []
    private var previousMainMenu: NSMenu?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        world = BA3UIWorld(self)
        bars = []
        modelStores = []
        modelSenders = []
        previousMainMenu = NSApp.mainMenu
    }

    override func tearDown() {
        bars.forEach { $0.backgroundPopover?.close() }
        bars = []
        NSApp.mainMenu = previousMainMenu
        world = nil
        super.tearDown()
    }

    private func makeBar(in window: NSWindow, frame: NSRect = NSRect(x: 0, y: 0, width: 600, height: 60),
                         tag: String = "gate", bind: Bool = true) -> ReplInputBar {
        let bar = ba3uiMakeBar(in: window, frame: frame, tag: tag, store: world.store, bind: bind)
        bars.append(bar)
        return bar
    }

    // MARK: The chip's text, state, tooltip and label

    func testARunningChipReadsTheCountAndIsLabelledForVoiceOver() {
        let chip = BackgroundChip()
        chip.apply(.running(2), tooltip: nil)

        XCTAssertEqual(chip.title, "\u{25F7} 2 running")
        XCTAssertEqual(chip.chipState, .running(2))
        XCTAssertEqual(chip.accessibilityLabel(), "Background activity: 2 running")
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.accessibilityRole(), .button)
    }

    func testDoneAndFailedChipsReadAndAreLabelledWithTheirCounts() {
        let chip = BackgroundChip()

        chip.apply(.done(3), tooltip: nil)
        XCTAssertEqual(chip.title, "\u{2713} 3 done")
        XCTAssertEqual(chip.accessibilityLabel(), "Background activity: 3 done")
        XCTAssertFalse(chip.isHidden)

        chip.apply(.failed(1), tooltip: nil)
        XCTAssertEqual(chip.title, "\u{2715} 1 failed")
        XCTAssertEqual(chip.accessibilityLabel(), "Background activity: 1 failed")
        XCTAssertFalse(chip.isHidden)
    }

    func testAChipWithNothingToReportIsHiddenAndComesBackWhenThereIsSomething() {
        let chip = BackgroundChip()
        XCTAssertTrue(chip.isHidden, "a new chip says nothing")

        chip.apply(.running(1), tooltip: nil)
        XCTAssertFalse(chip.isHidden)

        chip.apply(.hidden, tooltip: nil)
        XCTAssertTrue(chip.isHidden)
        XCTAssertEqual(chip.title, "")
        XCTAssertEqual(chip.chipState, .hidden)

        chip.apply(.done(2), tooltip: nil)
        XCTAssertFalse(chip.isHidden)
    }

    func testOnlyAFailedChipIsDrawnInTheFailureColour() {
        let chip = BackgroundChip()
        chip.apply(.failed(1), tooltip: nil)
        XCTAssertEqual(chip.titleColor, Theme.foldFailure)

        for state in [BackgroundChipState.running(1), .done(2)] {
            chip.apply(state, tooltip: nil)
            XCTAssertEqual(chip.titleColor, BackgroundChip.textColor, "\(state)")
            XCTAssertNotEqual(chip.titleColor, Theme.foldFailure, "\(state)")
        }
    }

    func testTheTooltipListsTheFirstThreeRunningTasksAndNoMore() throws {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window)
        let tasks = [
            world.task("a", "oldest task", startedAgo: 400),
            world.task("b", "second task", startedAgo: 300),
            world.task("c", "third task", startedAgo: 200),
            world.task("d", "newest task", startedAgo: 100),
        ]

        world.ingest(tasks)

        let lines = try XCTUnwrap(bar.backgroundChip.toolTip).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, "three running tasks are named: \(lines)")
        let titles = Set(tasks.map(\.description))
        XCTAssertTrue(lines.allSatisfy { titles.contains($0) }, "each line is a running task's description: \(lines)")
        XCTAssertEqual(lines, world.store.list(for: "gate").running.prefix(3).map(\.title),
                       "the first three, in the order the popover lists them")
        XCTAssertEqual(Set(lines).count, 3, "no task is named twice")

        world.ingest(Array(tasks.prefix(2)))
        XCTAssertEqual(try XCTUnwrap(bar.backgroundChip.toolTip).components(separatedBy: "\n").count, 2,
                       "two running tasks are two lines")
    }

    func testAHiddenChipHasNoTooltip() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window)
        world.ingest([world.task("a", "build", startedAgo: 10)])
        XCTAssertNotNil(bar.backgroundChip.toolTip, "precondition")

        world.ingest([])

        XCTAssertTrue(bar.backgroundChip.isHidden)
        XCTAssertTrue(bar.backgroundChip.toolTip == nil || bar.backgroundChip.toolTip == "")
    }

    // MARK: The slot

    /// The widest text any chip state can show: the counts cap at `99+`, so a hundred of anything is the
    /// longest (and `99` itself is checked too, in case the cap is ever raised).
    private let widestChipStates: [BackgroundChipState] = [.running(100), .done(100), .failed(100), .running(99),
                                                            .done(99), .failed(99), .running(1_000_000)]

    private func naturalWidth(of text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: BackgroundChip.font]).size().width)
            + 2 * BackgroundChip.horizontalPadding
    }

    func testTheSlotIsAtLeastAsWideAsTheLongestChipTextPlusPadding() {
        let texts = widestChipStates.compactMap(\.text)
        XCTAssertFalse(texts.isEmpty, "precondition")
        let widest = texts.map(naturalWidth).max() ?? 0
        print("BA3 slotWidth: \(BackgroundChip.slotWidth)")
        XCTContext.runActivity(named: "BA3 slotWidth: \(BackgroundChip.slotWidth)") { _ in }

        XCTAssertGreaterThanOrEqual(BackgroundChip.slotWidth, widest - 0.001,
                                    "slot \(BackgroundChip.slotWidth) vs the longest chip text + padding \(widest)")
        for text in texts {
            XCTAssertGreaterThanOrEqual(BackgroundChip.slotWidth, naturalWidth(of: text) - 0.001, "`\(text)` must fit the slot")
        }
    }

    func testEveryChipStateFitsTheSlotAndKeepsTheChipHeight() {
        let chip = BackgroundChip()
        let states: [BackgroundChipState] = [.hidden, .running(1), .running(12), .running(99), .running(100), .done(1),
                                             .done(99), .done(100), .failed(1), .failed(99), .failed(100)]
        for state in states {
            chip.apply(state, tooltip: nil)
            XCTAssertLessThanOrEqual(chip.intrinsicContentSize.width, BackgroundChip.slotWidth + 0.001, "\(state)")
            XCTAssertEqual(chip.intrinsicContentSize.height, BackgroundChip.height, "\(state)")
            if let text = state.text {
                // Not the clamped intrinsic size: the text itself, measured, fits.
                let natural = naturalWidth(of: text)
                XCTAssertLessThanOrEqual(natural, BackgroundChip.slotWidth + 0.001, "`\(text)` needs \(natural) pt")
            }
        }
    }

    func testAHundredRunningChipIsDrawnInFullWithinTheSlotNotClipped() {
        let chip = BackgroundChip()
        chip.apply(.running(100), tooltip: nil)

        XCTAssertEqual(chip.title, "\u{25F7} 99+ running")
        XCTAssertLessThanOrEqual(naturalWidth(of: chip.title), BackgroundChip.slotWidth + 0.001,
                                 "the chip's own text is not wider than the slot reserved for it")
        XCTAssertEqual(chip.intrinsicContentSize.width, naturalWidth(of: chip.title), accuracy: 0.5,
                       "so its natural width is not clamped")
        XCTAssertEqual(chip.accessibilityLabel(), "Background activity: 100 running", "VoiceOver still hears the real count")
    }

    func testTheSlotIsZeroWidthUntilBoundThenFixedWhateverTheChipSays() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window, bind: false)
        XCTAssertEqual(bar.backgroundSlot.frame.width, 0, accuracy: 0.5, "no session: no space taken")

        bar.bindBackground(tag: "gate", store: world.store, displayName: "Claudia")
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.backgroundSlot.frame.width, BackgroundChip.slotWidth, accuracy: 0.5)
        let composer = bar.textView.enclosingScrollView?.frame
        let barHeight = bar.frame.height

        let steps: [[TaskMetaWire]] = [
            world.running(1), world.running(12), world.running(99),
            [world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)],
            [],
        ]
        for tasks in steps {
            world.ingest(tasks)
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(bar.backgroundSlot.frame.width, BackgroundChip.slotWidth, accuracy: 0.5, "\(bar.backgroundChip.title)")
            XCTAssertEqual(bar.textView.enclosingScrollView?.frame, composer, "the composer's frame must not change: \(bar.backgroundChip.title)")
            XCTAssertEqual(bar.frame.height, barHeight, accuracy: 0.5, "the bar's height must not change: \(bar.backgroundChip.title)")
            XCTAssertLessThanOrEqual(bar.backgroundChip.frame.width, bar.backgroundSlot.frame.width + 0.5,
                                     "the chip stays inside its slot: \(bar.backgroundChip.title)")
        }
    }

    // MARK: Counts above 99

    func testCountsAboveNinetyNineReadNinetyNinePlus() {
        XCTAssertEqual(BackgroundChipState.running(100).text, "\u{25F7} 99+ running")
        XCTAssertEqual(BackgroundChipState.done(150).text, "\u{2713} 99+ done")
        XCTAssertEqual(BackgroundChipState.failed(1_000).text, "\u{2715} 99+ failed")
        XCTAssertEqual(BackgroundChipState.running(99).text, "\u{25F7} 99 running", "99 is still shown as it is")
        XCTAssertEqual(BackgroundChipState.running(12).text, "\u{25F7} 12 running")
    }

    func testAHundredTasksOnABoundBarReadNinetyNinePlusButAreLabelledWithTheRealCount() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window)

        world.ingest(world.running(100))
        bar.layoutSubtreeIfNeeded()

        XCTAssertEqual(bar.backgroundChip.chipState, .running(100), "the state keeps the real count")
        XCTAssertEqual(bar.backgroundChip.title, "\u{25F7} 99+ running")
        XCTAssertEqual(bar.backgroundChip.accessibilityLabel(), "Background activity: 100 running")
        XCTAssertLessThanOrEqual(bar.backgroundChip.frame.width, bar.backgroundSlot.frame.width + 0.5,
                                 "the chip stays inside its slot")
        XCTAssertEqual(bar.backgroundSlot.frame.width, BackgroundChip.slotWidth, accuracy: 0.5,
                       "and the slot is still the same width as for one task")
    }

    // MARK: How much of itself the chip shows

    func testAnIconOnlyChipShowsJustTheGlyphOfItsState() {
        let chip = BackgroundChip()
        let expectations: [(BackgroundChipState, String)] = [(.running(2), "\u{25F7}"), (.done(3), "\u{2713}"),
                                                              (.failed(1), "\u{2715}"), (.running(100), "\u{25F7}")]
        for (state, icon) in expectations {
            chip.apply(state, tooltip: nil)
            chip.setFit(.iconOnly)
            XCTAssertEqual(chip.fit, .iconOnly)
            XCTAssertEqual(chip.title, icon, "\(state): the glyph alone")
            XCTAssertEqual(chip.title, state.icon)
            XCTAssertFalse(chip.isHidden, "\(state): an icon-only chip is still there")
            XCTAssertEqual(chip.accessibilityLabel(), state.accessibilityLabel,
                           "\(state): VoiceOver still gets the whole story from the icon")
            XCTAssertLessThanOrEqual(chip.intrinsicContentSize.width, BackgroundChip.iconWidth + 0.5,
                                     "\(state): the icon needs no more than the icon width")
            chip.setFit(.full)
        }
    }

    func testTheIconWidthIsBetweenNothingAndTheFullSlot() {
        XCTAssertGreaterThan(BackgroundChip.iconWidth, 2 * BackgroundChip.horizontalPadding, "room for a glyph and its padding")
        XCTAssertLessThan(BackgroundChip.iconWidth, BackgroundChip.slotWidth, "the icon alone is narrower than the text")
        for state in [BackgroundChipState.running(1), .done(1), .failed(1)] {
            XCTAssertLessThanOrEqual(naturalWidth(of: state.icon ?? ""), BackgroundChip.iconWidth + 0.001, "\(state)'s glyph fits")
        }
    }

    func testAHiddenFitHidesTheChipAndFullBringsItBack() {
        let chip = BackgroundChip()
        chip.apply(.running(2), tooltip: "two jobs")
        XCTAssertFalse(chip.isHidden, "precondition")
        XCTAssertEqual(chip.title, "\u{25F7} 2 running", "precondition")

        chip.setFit(.hidden)
        XCTAssertEqual(chip.fit, .hidden)
        XCTAssertTrue(chip.isHidden, "no room: no chip")

        chip.setFit(.full)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.title, "\u{25F7} 2 running", "the whole text again")
        XCTAssertEqual(chip.toolTip, "two jobs", "nothing else was lost on the way")
        XCTAssertEqual(chip.chipState, .running(2))
    }

    func testAChipWithNothingToReportStaysHiddenInEveryFit() {
        let chip = BackgroundChip()
        chip.apply(.hidden, tooltip: nil)
        for fit in [BackgroundChip.Fit.full, .iconOnly, .hidden, .full] {
            chip.setFit(fit)
            XCTAssertTrue(chip.isHidden, "a hidden state is hidden at \(fit) too")
            XCTAssertEqual(chip.title, "", "and says nothing at \(fit)")
        }
    }

    func testAChipThatHadNoRoomStaysHiddenWhenItsStateChangesUntilThereIsRoom() {
        let chip = BackgroundChip()
        chip.apply(.running(1), tooltip: nil)
        chip.setFit(.hidden)

        chip.apply(.failed(2), tooltip: nil)
        XCTAssertTrue(chip.isHidden, "a new state does not squeeze a chip into a slot with no room")

        chip.setFit(.iconOnly)
        XCTAssertFalse(chip.isHidden)
        XCTAssertEqual(chip.title, "\u{2715}")

        chip.apply(.done(4), tooltip: nil)
        XCTAssertEqual(chip.title, "\u{2713}", "a new state keeps the fit the slot gave it")

        chip.setFit(.full)
        XCTAssertEqual(chip.title, "\u{2713} 4 done")
    }

    func testChangingTheFitNeverMovesTheKeyboard() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window)
        bar.textView.string = "half a thought"
        XCTAssertTrue(window.makeFirstResponder(bar.textView))
        world.ingest(world.running(3))

        for fit in [BackgroundChip.Fit.iconOnly, .hidden, .full] {
            bar.backgroundChip.setFit(fit)
            XCTAssertTrue(window.firstResponder === bar.textView, "\(fit): the composer keeps the keyboard")
            XCTAssertEqual(bar.textView.string, "half a thought", "\(fit)")
        }
    }

    // MARK: Narrow panes

    /// One narrow-pane rig: a window and a bound bar `width` wide, the chip showing 100 running tasks, optionally
    /// with the model chip showing and Stop up (a turn running).
    private struct NarrowRig {
        let window: RigWindow
        let bar: ReplInputBar
        let world: BA3UIWorld
    }

    private var modelStores: [ModelStore] = []
    private var modelSenders: [ModelRequestRecorder] = []

    private func makeNarrowRig(width: CGFloat, modelChip: Bool = false, stopShowing: Bool = false) -> NarrowRig {
        let window = makeRigWindow(self, size: NSSize(width: width, height: 60))
        // Its own store, so the bar is bound before the tasks arrive whichever variant it is.
        let rigWorld = BA3UIWorld(self)
        let bar = ba3uiMakeBar(in: window, frame: NSRect(x: 0, y: 0, width: width, height: 60), store: rigWorld.store)
        bars.append(bar)
        if modelChip {
            let sender = ModelRequestRecorder()
            let store = ModelStore(sender: sender)
            store.connectionChanged(true)
            modelSenders.append(sender)
            modelStores.append(store)
            bar.bindModel(tag: "gate", agentName: "claudia", store: store)
            let state = SessionModelStateWire(tag: "gate",
                                              recorded: RecordedModelWire(model: "sonnet", effort: nil, source: .focus),
                                              reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                              running: true)
            store.ingest(.sessionModelState(state))
            modelWaitUntil { !bar.modelChip.isHidden }
        }
        if stopShowing {
            bar.setRunning(true)
            addTeardownBlock { bar.setRunning(false) }
        }
        rigWorld.ingest(rigWorld.running(100))
        settle(bar, in: window)
        return NarrowRig(window: window, bar: bar, world: rigWorld)
    }

    /// Layout until nothing moves (a chip changing its fit asks for one more pass).
    private func settle(_ bar: ReplInputBar, in window: NSWindow) {
        for _ in 0 ..< 3 {
            window.contentView?.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
        }
    }

    private func resize(_ rig: NarrowRig, to width: CGFloat) {
        rig.window.setContentSize(NSSize(width: width, height: 60))
        rig.bar.setFrameSize(NSSize(width: width, height: 60))
        settle(rig.bar, in: rig.window)
    }

    private func sendButton(of bar: ReplInputBar, file: StaticString = #filePath, line: UInt = #line) -> NSButton? {
        let found = bar.subviews.compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == "Send" || $0.title == "Send" }
        XCTAssertNotNil(found, "the bar has a Send button", file: file, line: line)
        return found
    }

    private func stopButton(of bar: ReplInputBar) -> NSButton? {
        bar.subviews.compactMap { $0 as? NSButton }.first { $0.attributedTitle.string.contains("Stop") || $0.title.contains("Stop") }
    }

    /// What a narrow bar must never do: widen its window, move off its pane, or put one control on another;
    /// and, where the arithmetic allows (`composerFits`), keep the composer a usable width.
    private func assertTheBarHolds(_ rig: NarrowRig, width: CGFloat, composerFits: Bool, _ name: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let bar = rig.bar
        settle(bar, in: rig.window)
        XCTAssertEqual(rig.window.frame.width, width, accuracy: 0.5,
                       "\(name): the window must never widen to fit the bar", file: file, line: line)
        XCTAssertEqual(bar.frame.width, width, accuracy: 0.5, "\(name): the bar keeps the pane's width", file: file, line: line)
        XCTAssertEqual(bar.frame.minX, 0, accuracy: 0.5, "\(name): the bar stays on the pane", file: file, line: line)
        if let content = rig.window.contentView {
            XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(bar.frame),
                          "\(name): the bar \(bar.frame) must stay inside the pane \(content.bounds)", file: file, line: line)
        }

        guard let composer = bar.textView.enclosingScrollView?.frame else {
            return XCTFail("\(name): the composer has a scroll view", file: file, line: line)
        }
        var parts: [(String, NSRect)] = [("composer", composer), ("background slot", bar.backgroundSlot.frame)]
        if !bar.modelChip.isHidden { parts.append(("model chip", bar.modelChip.frame)) }
        if let send = sendButton(of: bar, file: file, line: line) { parts.append(("Send", send.frame)) }
        if let stop = stopButton(of: bar), !stop.isHidden { parts.append(("Stop", stop.frame)) }

        let barBounds = bar.bounds.insetBy(dx: -0.5, dy: -0.5)
        for (label, frame) in parts {
            XCTAssertTrue(barBounds.contains(frame), "\(name): \(label) \(frame) must stay inside the bar \(bar.bounds)",
                          file: file, line: line)
        }
        for (i, a) in parts.enumerated() {
            for b in parts[(i + 1)...] {
                let overlap = a.1.intersection(b.1)
                let overlaps = !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
                XCTAssertFalse(overlaps, "\(name): \(a.0) \(a.1) and \(b.0) \(b.1) must not overlap",
                               file: file, line: line)
            }
        }

        let chip = bar.backgroundChip
        if !chip.isHidden {
            let slot = bar.backgroundSlot
            XCTAssertTrue(slot.bounds.insetBy(dx: -0.5, dy: -0.5).contains(chip.frame),
                          "\(name): a visible chip \(chip.frame) must sit inside its slot \(slot.bounds)", file: file, line: line)
        }

        if composerFits {
            let wanted = max(ReplInputBar.composerMinimumWidth, ReplInputBar.composerMinimumFraction * width)
            XCTAssertGreaterThanOrEqual(composer.width, wanted - 0.5,
                                        "\(name): the composer is \(composer.width) pt wide, it must keep at least \(wanted)",
                                        file: file, line: line)
        }
    }

    /// Runs the four things a pane can have on its bar (nothing extra, Stop, the model chip, both).
    ///
    /// `composerFits` is false where the bar cannot give the composer its minimum even with the slot and the
    /// model chip squeezed to nothing: with Stop up (64 pt and its gap) a 260 pt bar has 80 pt left for the
    /// composer. There the test only checks that nothing overlaps or leaves the bar.
    private func assertEveryVariantHolds(at width: CGFloat, stopFits: Bool,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let variants: [(name: String, model: Bool, stop: Bool, composerFits: Bool)] = [
            ("plain", false, false, true),
            ("stop showing", false, true, stopFits),
            ("model chip showing", true, false, true),
            ("model chip and stop showing", true, true, stopFits),
        ]
        for variant in variants {
            let rig = makeNarrowRig(width: width, modelChip: variant.model, stopShowing: variant.stop)
            XCTAssertEqual(rig.bar.backgroundChip.chipState, .running(100), "\(width) pt, \(variant.name): precondition",
                           file: file, line: line)
            assertTheBarHolds(rig, width: width, composerFits: variant.composerFits, "\(Int(width)) pt, \(variant.name)",
                              file: file, line: line)
        }
    }

    func testABarAt420PointsKeepsEverythingInsideAndTheComposerWide() {
        assertEveryVariantHolds(at: 420, stopFits: true)
    }

    func testABarAt320PointsKeepsEverythingInsideAndTheComposerWide() {
        assertEveryVariantHolds(at: 320, stopFits: true)
    }

    func testABarAt260PointsKeepsEverythingInsideAndTheComposerWideWhereItCan() {
        // The composer's minimum is only asserted for the variants without Stop: with Stop up there is not
        // the room (see `assertEveryVariantHolds`).
        assertEveryVariantHolds(at: 260, stopFits: false)
    }

    func testTheChipGivesWayToTheComposerAsTheBarNarrows() {
        let cases: [(width: CGFloat, fit: BackgroundChip.Fit)] = [(420, .full), (320, .iconOnly), (260, .hidden)]
        for (width, fit) in cases {
            let rig = makeNarrowRig(width: width)
            let chip = rig.bar.backgroundChip
            XCTAssertEqual(chip.fit, fit, "\(Int(width)) pt: how much of itself the chip shows")
            switch fit {
            case .full:
                XCTAssertEqual(chip.title, "\u{25F7} 99+ running", "\(Int(width)) pt: the whole text")
                XCTAssertFalse(chip.isHidden)
                XCTAssertEqual(rig.bar.backgroundSlot.frame.width, BackgroundChip.slotWidth, accuracy: 0.5,
                               "\(Int(width)) pt: the slot is its full width while there is room")
            case .iconOnly:
                XCTAssertEqual(chip.title, BackgroundChipState.running(100).icon, "\(Int(width)) pt: the icon alone")
                XCTAssertFalse(chip.isHidden)
                XCTAssertLessThan(rig.bar.backgroundSlot.frame.width, BackgroundChip.slotWidth,
                                  "\(Int(width)) pt: the slot gave way")
            case .hidden:
                XCTAssertTrue(chip.isHidden, "\(Int(width)) pt: no room for even the icon, so no chip")
            }
            XCTAssertEqual(chip.accessibilityLabel(), "Background activity: 100 running",
                           "\(Int(width)) pt: the label does not shrink with the chip")
            assertTheBarHolds(rig, width: width, composerFits: true, "\(Int(width)) pt")
        }
    }

    func testAtTwoHundredSixtyPointsTheChipIsNoLongerWholeAndNeverOverhangsItsSlot() {
        // The edge between the icon and nothing depends on the glyph's measured width, so this checks the
        // rule rather than the name: not the whole text, and whatever is drawn fits the slot it has.
        let rig = makeNarrowRig(width: 260)
        let chip = rig.bar.backgroundChip

        XCTAssertNotEqual(chip.fit, .full, "260 pt has no room for `\u{25F7} 99+ running`")
        XCTAssertEqual(chip.isHidden, chip.fit == .hidden, "a chip is hidden exactly when it has no room at all")
        if chip.fit == .iconOnly {
            XCTAssertEqual(chip.title, "\u{25F7}")
            XCTAssertGreaterThanOrEqual(rig.bar.backgroundSlot.frame.width + 0.5, BackgroundChip.iconWidth,
                                        "an icon is shown only in a slot that fits it")
        }
    }

    func testTheSlotReturnsWhenThePaneWidens() {
        for narrow in [CGFloat(320), CGFloat(230)] {
            let rig = makeNarrowRig(width: narrow)
            XCTAssertNotEqual(rig.bar.backgroundChip.fit, .full, "\(Int(narrow)) pt: precondition")

            resize(rig, to: 600)

            XCTAssertEqual(rig.bar.backgroundSlot.frame.width, BackgroundChip.slotWidth, accuracy: 0.5,
                           "from \(Int(narrow)) pt: the slot is its full width again")
            XCTAssertEqual(rig.bar.backgroundChip.fit, .full, "from \(Int(narrow)) pt")
            XCTAssertFalse(rig.bar.backgroundChip.isHidden)
            XCTAssertEqual(rig.bar.backgroundChip.title, "\u{25F7} 99+ running", "from \(Int(narrow)) pt: the whole text is back")
            assertTheBarHolds(rig, width: 600, composerFits: true, "widened from \(Int(narrow)) pt")
        }
    }

    func testTheSameBarNarrowedAndWidenedAgainFollowsItsWidthBothWays() {
        let rig = makeNarrowRig(width: 600)
        XCTAssertEqual(rig.bar.backgroundChip.fit, .full, "precondition")

        resize(rig, to: 320)
        XCTAssertEqual(rig.bar.backgroundChip.fit, .iconOnly, "narrowed to 320 pt")
        XCTAssertEqual(rig.bar.backgroundChip.title, "\u{25F7}")

        resize(rig, to: 230)
        XCTAssertEqual(rig.bar.backgroundChip.fit, .hidden, "narrowed to 230 pt")
        XCTAssertTrue(rig.bar.backgroundChip.isHidden)

        resize(rig, to: 420)
        XCTAssertEqual(rig.bar.backgroundChip.fit, .full, "widened to 420 pt")
        XCTAssertEqual(rig.bar.backgroundChip.title, "\u{25F7} 99+ running")
        XCTAssertFalse(rig.bar.backgroundChip.isHidden)
    }

    func testANarrowBarStillShowsAChipWhoseStateChangesWithoutTheComposerMoving() {
        let rig = makeNarrowRig(width: 320)
        let composer = rig.bar.textView.enclosingScrollView?.frame

        rig.world.ingest([rig.world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)])
        settle(rig.bar, in: rig.window)

        XCTAssertEqual(rig.bar.backgroundChip.chipState, .failed(1), "precondition")
        XCTAssertEqual(rig.bar.backgroundChip.fit, .iconOnly)
        XCTAssertEqual(rig.bar.backgroundChip.title, "\u{2715}", "the failure's own icon, not the running one")
        XCTAssertEqual(rig.bar.textView.enclosingScrollView?.frame, composer,
                       "a chip changing state never changes the composer's width, narrow or not")
    }

    func testANarrowBarWithNothingToReportHasTheSameComposerAsWithAChip() {
        let withChip = makeNarrowRig(width: 320)
        let composerWithChip = withChip.bar.textView.enclosingScrollView?.frame

        withChip.world.ingest([])
        settle(withChip.bar, in: withChip.window)

        XCTAssertTrue(withChip.bar.backgroundChip.isHidden, "precondition")
        XCTAssertEqual(withChip.bar.textView.enclosingScrollView?.frame, composerWithChip,
                       "the chip going does not hand its room to the composer")
    }

    // MARK: Focus

    func testTheChipNeverTakesTheKeyboardWhenItsStateChanges() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window)
        bar.textView.string = "half a thought"
        XCTAssertTrue(window.makeFirstResponder(bar.textView))
        bar.textView.setSelectedRange(NSRange(location: 2, length: 4))

        func assertUntouched(_ step: String, chip: BackgroundChipState, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(bar.backgroundChip.chipState, chip, step, file: file, line: line)
            XCTAssertTrue(window.firstResponder === bar.textView, "\(step): the composer keeps the keyboard", file: file, line: line)
            XCTAssertFalse(bar.backgroundChip.hasKeyboardFocus, "\(step): the chip has no focus ring", file: file, line: line)
            XCTAssertEqual(bar.textView.string, "half a thought", step, file: file, line: line)
            XCTAssertEqual(bar.textView.selectedRange(), NSRange(location: 2, length: 4), step, file: file, line: line)
        }

        assertUntouched("hidden", chip: .hidden)
        world.ingest(world.running(1))
        assertUntouched("running", chip: .running(1))
        world.ingest(world.running(12))
        assertUntouched("12 running", chip: .running(12))
        world.ingest([world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)])
        assertUntouched("failed", chip: .failed(1))
        world.markSeen()
        assertUntouched("hidden again", chip: .hidden)
        XCTAssertTrue(bar.backgroundChip.isHidden)
    }

    // MARK: Whether the popover can open

    func testTheShortcutIsUnavailableBeforeTheBarIsBoundAndWithoutDaemonSupport() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window, bind: false)
        let item = BackgroundShortcut.makeMenuItem()

        XCTAssertFalse(bar.canShowBackgroundPopover, "no session yet")
        XCTAssertFalse(bar.validateMenuItem(item))

        world.store.tasksSupported = false
        bar.bindBackground(tag: "gate", store: world.store, displayName: "Claudia")
        XCTAssertFalse(bar.canShowBackgroundPopover, "the daemon does not report background tasks")
        XCTAssertFalse(bar.validateMenuItem(item))

        world.store.tasksSupported = true
        XCTAssertTrue(bar.canShowBackgroundPopover)
        XCTAssertTrue(bar.validateMenuItem(item), "the menu item follows the bar")

        world.store.tasksSupported = false
        XCTAssertFalse(bar.validateMenuItem(item), "and follows it back")
    }

    func testOtherMenuItemsStayEnabledWhateverTheBackgroundShortcutSays() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = makeBar(in: window, bind: false)
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(bar.validateMenuItem(copy))
    }

    // MARK: Two bars, one store

    func testTwoWindowsBoundToTheSameFocusShowTheSameChipAfterEveryChange() {
        let windowA = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let windowB = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let barA = makeBar(in: windowA)
        let barB = makeBar(in: windowB)

        func assertSame(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(barA.backgroundChip.title, barB.backgroundChip.title, step, file: file, line: line)
            XCTAssertEqual(barA.backgroundChip.isHidden, barB.backgroundChip.isHidden, step, file: file, line: line)
            XCTAssertEqual(barA.backgroundChip.chipState, barB.backgroundChip.chipState, step, file: file, line: line)
            XCTAssertEqual(barA.backgroundChip.accessibilityLabel(), barB.backgroundChip.accessibilityLabel(), step, file: file, line: line)
        }

        assertSame("nothing yet")
        world.ingest(world.running(2))
        assertSame("two running")
        XCTAssertEqual(barA.backgroundChip.title, "\u{25F7} 2 running")
        world.ingest(world.running(12))
        assertSame("twelve running")
        world.ingest([world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)])
        assertSame("one failed")
        XCTAssertEqual(barB.backgroundChip.title, "\u{2715} 1 failed")
        world.markSeen()
        assertSame("seen")
        XCTAssertTrue(barA.backgroundChip.isHidden)
    }

    func testABarShowsOnlyItsOwnFocusTasks() {
        let windowA = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let windowB = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let barA = makeBar(in: windowA, tag: "claudia")
        let barB = makeBar(in: windowB, tag: "cody")

        world.ingest(world.running(3), tag: "claudia")

        XCTAssertEqual(barA.backgroundChip.title, "\u{25F7} 3 running")
        XCTAssertTrue(barB.backgroundChip.isHidden, "another focus's tasks are not this pane's")
        XCTAssertEqual(barB.backgroundChip.chipState, .hidden)
    }

    // MARK: Which bar the shortcut picks

    private func twoBars() -> (window: NSWindow, a: ReplInputBar, b: ReplInputBar) {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 140))
        let a = makeBar(in: window, frame: NSRect(x: 0, y: 0, width: 600, height: 60), tag: "tag-a")
        let b = makeBar(in: window, frame: NSRect(x: 0, y: 70, width: 600, height: 60), tag: "tag-b")
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, a, b)
    }

    func testTheShortcutPicksTheBarWhoseComposerHasTheKeyboard() {
        let (window, a, b) = twoBars()

        XCTAssertTrue(window.makeFirstResponder(b.textView))
        XCTAssertTrue(BackgroundShortcut.bar(in: window) === b)
        XCTAssertTrue(window.makeFirstResponder(a.textView))
        XCTAssertTrue(BackgroundShortcut.bar(in: window) === a, "not simply the first or the last bar: the one in use")
    }

    func testTheShortcutIgnoresABarThatCannotOpenAPopover() {
        let (window, a, b) = twoBars()
        XCTAssertTrue(window.makeFirstResponder(b.textView))
        XCTAssertTrue(BackgroundShortcut.bar(in: window) === b, "precondition")

        world.store.tasksSupported = false

        XCTAssertNil(BackgroundShortcut.bar(in: window), "neither bar can open it")
        XCTAssertTrue(BackgroundShortcut.bars(in: window).isEmpty)
        _ = a
    }

    // MARK: The menu

    private func symbol(of item: NSMenuItem) -> String? {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return nil }
        var mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
        // An upper-case letter means shift already.
        if key.count == 1, key != key.lowercased() { mask.remove(.shift) }
        var out = ""
        if mask.contains(.control) { out += "\u{2303}" }
        if mask.contains(.option) { out += "\u{2325}" }
        if mask.contains(.shift) { out += "\u{21E7}" }
        if mask.contains(.command) { out += "\u{2318}" }
        return out + key.lowercased()
    }

    private func walk(_ menu: NSMenu, path: [String] = []) -> [(item: NSMenuItem, path: [String])] {
        var found: [(item: NSMenuItem, path: [String])] = []
        for item in menu.items {
            found.append((item, path))
            if let submenu = item.submenu { found += walk(submenu, path: path + [submenu.title]) }
        }
        return found
    }

    func testExactlyOneMainMenuItemIsShiftCommandBAndItIsBackgroundActivityInTheSessionMenu() throws {
        let menu = MainMenu.make(target: nil)
        let shiftB = walk(menu).filter { symbol(of: $0.item) == "\u{21E7}\u{2318}b" }

        XCTAssertEqual(shiftB.count, 1, "shift-command-B is on exactly one item: \(shiftB.map { $0.item.title })")
        let hit = try XCTUnwrap(shiftB.first)
        XCTAssertEqual(hit.item.title, "Background Activity\u{2026}")
        XCTAssertEqual(hit.item.action, BackgroundShortcut.action)
        XCTAssertEqual(hit.item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift])
        XCTAssertEqual(hit.path, ["Session"], "it lives in the Session menu")
        XCTAssertNil(hit.item.target, "no target: the action walks the responder chain from the key window")
    }

    func testCaptureRenderStateMovedToOptionShiftCommandB() throws {
        let menu = MainMenu.make(target: nil)
        let capture = try XCTUnwrap(walk(menu).first { $0.item.title == "Capture render state now" })

        XCTAssertEqual(symbol(of: capture.item), "\u{2325}\u{21E7}\u{2318}b")
        XCTAssertEqual(capture.path, ["Debug"])
        let others = walk(menu).filter { $0.item.title != "Capture render state now" && $0.path == ["Debug"] }
        XCTAssertFalse(others.contains { symbol(of: $0.item) == "\u{21E7}\u{2318}b" }, "no Debug item still uses shift-command-B")
    }

    func testTheSessionMenuHoldsTheBackgroundItemNextToTheModelItem() throws {
        let menu = MainMenu.make(target: nil)
        let session = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == "Session" })
        let actions = session.items.map(\.action)
        XCTAssertTrue(actions.contains(BackgroundShortcut.action))
        XCTAssertTrue(actions.contains(ModelShortcut.action), "the model shortcut is still there")
    }

    // MARK: Shift-command-B in the composer

    private func typedBar() -> (window: RigWindow, bar: ReplInputBar) {
        let window = ba3uiVisibleWindow(self)
        let bar = makeBar(in: window)
        bar.textView.string = "half a thought about the dep"
        XCTAssertTrue(window.makeFirstResponder(bar.textView))
        bar.textView.setSelectedRange(NSRange(location: 5, length: 6))
        return (window, bar)
    }

    /// Route used: the responder chain, from the composer's text view, with the menu item's action. A real
    /// shift-command-B goes menu item -> `NSApp.target(forAction:)` -> first responder chain -> the bar, so
    /// this walks the same chain from the same starting point. (The menu-bar route is tried in the next test.)
    func testShiftCommandBInTheComposerOpensThePopoverAndTypesNothing() throws {
        let (window, bar) = typedBar()
        let item = BackgroundShortcut.makeMenuItem()
        let responder = try XCTUnwrap(window.firstResponder)

        let handled = responder.tryToPerform(BackgroundShortcut.action, with: item)

        XCTAssertTrue(handled, "the action must be handled somewhere on the composer's responder chain")
        XCTAssertNotNil(bar.backgroundPopover)
        XCTAssertTrue(bar.backgroundPopover?.isShown ?? false, "the popover opens")
        XCTAssertEqual(bar.backgroundPopover?.tookKeyboard, true, "opened from the keyboard: the keyboard goes into it")
        XCTAssertEqual(bar.textView.string, "half a thought about the dep", "no `B` was typed")
        XCTAssertEqual(bar.textView.selectedRange(), NSRange(location: 5, length: 6))
    }

    /// Route used: `NSMenu.performKeyEquivalent(with:)` on a main menu installed as `NSApp.mainMenu`. Whether
    /// the menu can validate and send a nil-target action depends on the test process having a key window the
    /// application knows about, which a logic bundle may not. When it cannot route, this skips (it does not pass).
    func testShiftCommandBThroughTheMainMenuOpensThePopoverWhenTheMenuCanRoute() throws {
        let (window, bar) = typedBar()
        NSApp.mainMenu = MainMenu.make(target: nil)
        let probe = BackgroundShortcut.makeMenuItem()
        try XCTSkipUnless((NSApp.target(forAction: BackgroundShortcut.action, to: nil, from: probe) as AnyObject?) === bar,
                          "the test process has no key window to route a nil-target menu action from")

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "B", charactersIgnoringModifiers: "b",
            isARepeat: false, keyCode: 11))

        let handled = try XCTUnwrap(NSApp.mainMenu).performKeyEquivalent(with: event)

        XCTAssertTrue(handled)
        XCTAssertTrue(bar.backgroundPopover?.isShown ?? false)
        XCTAssertEqual(bar.textView.string, "half a thought about the dep", "no `B` was typed")
    }
}
