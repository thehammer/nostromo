import XCTest
import AppKit
import NostromoKit

// BA3: the scroll-safety gate for the Background activity chip and popover (PRD "Scroll and focus
// safety", Phase 5, criteria 1 and 2).
//
// Every event the chip and popover can cause runs inside `SafetyRig.assertNoMove` (ScrollSafetyGate.swift),
// in a pane that is following the tail and in one scrolled up into the middle of the transcript, with a
// REAL `ReplInputBar` (bound to a real `BackgroundTaskStore`) under the transcript, holding the keyboard
// and partly typed text. The gate asserts the transcript's first visible line moved at most 1 pt (and a
// following pane kept its bottom at 0), and that the input bar's height, the composer's frame, the window's
// first responder, the composer's text and its selection are untouched.
//
// Events: the chip appearing, changing (1 -> 12 running, running -> failed, a task progressing) and
// disappearing (opened once = seen); the popover opening by click, updating (ten snapshots), scrolling its
// list, closing by Esc and by a click outside (`close()`; a real click outside needs the window server);
// a second input bar bound to the same focus in a second window doing the same; and the keyboard path:
// opening with shift-command-B puts the keyboard in the list, closing it gives the composer back with the
// exact text and selection.
//
// The slot is bound BEFORE the first layout, so the chip appearing has a reserved place to appear in (the
// real pane binds when it gets its session). The rig's windows are ordered in (animations off) so a real
// `NSPopover` can anchor to the input bar. No wall clock (injected store clock), no real pasteboard or
// UserDefaults, no daemon.

// BA4 adds the task window to the gate (PRD "Scroll and focus safety", criteria 1 and 2, for the slice that
// opens windows): a `TaskWindowManager` over the pane's own store, with a fake daemon behind its output
// requests, opens a REAL `TaskPanel` for a running shell task. Opening it, 50 store snapshots and 50 output
// appends reaching it, scrolling its own text and closing it must move the main transcript's first visible
// line by at most 1 pt (and keep a following pane at the bottom), and leave the main window's first
// responder, composer text and selection exactly as they were: in a following pane and in one scrolled up.
// A two-window variant keeps the panel open across the events and closes it with Esc; a terminal variant
// holds the keyboard in a terminal stand-in and asserts the daemon connection saw no byte at all.
//
// On key status: `RigWindow` (the shared test window) overrides `isKeyWindow` to always answer true, and a
// headless runner may not make any window key, so "the rig window is key again after the panel closes" is
// asserted in the strongest form that holds there: the rig window's first responder is still the composer
// (a window that lost key status and got it back keeps its first responder, one that was cleared does not),
// the panel is not the key window afterwards, and it cannot become the main window at all.

final class BackgroundScrollSafetyTests: XCTestCase {

    private struct Pane {
        let rig: SafetyRig
        let world: BA3UIWorld
        var bar: ReplInputBar { rig.inputBar }
    }

    private var bars: [ReplInputBar] = []

    override func setUp() {
        super.setUp()
        bars = []
        TSGestureSeams.install(on: self)
    }

    override func tearDown() {
        bars.forEach { $0.backgroundPopover?.close() }
        bars = []
        super.tearDown()
    }

    /// `SafetyRig.followingTail` / `.scrolledUp`, with the Background slot bound before layout and
    /// the composer focused after.
    private func pane(following: Bool, world given: BA3UIWorld? = nil) -> Pane {
        let world = given ?? BA3UIWorld(self)
        let rig = SafetyRig(self, turns: SafetyFixtures.transcript())
        rig.window.animationBehavior = .none
        rig.window.orderFront(nil)
        rig.inputBar.bindBackground(tag: "gate", store: world.store, displayName: "Claudia")
        bars.append(rig.inputBar)
        rig.inputBar.layoutSubtreeIfNeeded()
        rig.window.contentView?.layoutSubtreeIfNeeded()
        rig.start()
        if !following {
            rig.userScroll(to: rig.virtualizer.offset(of: 3) + 40)
            rig.followTail.setPinned(false, cause: .harness)
            rig.settle()
        }
        rig.inputBar.layoutSubtreeIfNeeded()
        rig.window.contentView?.layoutSubtreeIfNeeded()
        rig.settle()
        rig.focusComposer()
        return Pane(rig: rig, world: world)
    }

    private func scrollList(of popover: BackgroundPopover, to y: CGFloat) {
        let scrollView = popover.viewController.scrollView
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    private func waitForClose(_ bar: ReplInputBar, file: StaticString = #filePath, line: UInt = #line) {
        modelWaitUntil(file: file, line: line) { bar.backgroundPopover == nil }
    }

    private func assertComposerIntact(_ rig: SafetyRig, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "\(name): the composer has the keyboard", file: file, line: line)
        XCTAssertEqual(rig.textView.string, SafetyRig.typedText, "\(name): the typed text", file: file, line: line)
        XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection, "\(name): the selection", file: file, line: line)
    }

    // MARK: The chip

    func testTheChipAppearingChangingAndDisappearingMovesNothingAndTakesNoFocus() {
        for following in [true, false] {
            let p = pane(following: following)
            let chip = p.bar.backgroundChip
            XCTAssertTrue(chip.isHidden, "precondition: nothing to report")

            p.rig.assertNoMove("chip appears (following: \(following))", following: following) {
                p.world.ingest(p.world.running(1))
            }
            XCTAssertEqual(chip.chipState, .running(1))

            p.rig.assertNoMove("a task progresses (following: \(following))", following: following) {
                p.world.ingest([p.world.task("job0", kind: .agent, "job number 0", startedAgo: 1_000, subagentType: "redd",
                                             tokens: 9_000, toolUses: 4, lastTool: "Edit")])
                p.world.detail("job0", progressSummary: "writing the tests")
            }

            p.rig.assertNoMove("chip changes 1 -> 12 running (following: \(following))", following: following) {
                p.world.ingest(p.world.running(12))
            }
            XCTAssertEqual(chip.chipState, .running(12))

            p.rig.assertNoMove("chip changes running -> failed (following: \(following))", following: following) {
                p.world.ingest([p.world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)])
            }
            XCTAssertEqual(chip.chipState, .failed(1))

            p.rig.assertNoMove("chip disappears once seen (following: \(following))", following: following) {
                p.world.markSeen()
            }
            XCTAssertEqual(chip.chipState, .hidden)
            XCTAssertTrue(chip.isHidden)
            XCTAssertFalse(chip.hasKeyboardFocus)
        }
    }

    // MARK: The popover, opened by a click

    func testOpeningUpdatingScrollingAndClosingTheListMovesNothing() throws {
        for following in [true, false] {
            let p = pane(following: following)
            let bar = p.bar
            p.world.ingest(p.world.running(8))
            let name = { (step: String) in "\(step) (following: \(following))" }

            p.rig.assertNoMove(name("popover opens by click"), following: following) {
                bar.toggleBackgroundPopover(takeKeyboard: false)
            }
            let popover = try XCTUnwrap(bar.backgroundPopover, "the popover is open")
            XCTAssertTrue(popover.isShown)
            XCTAssertFalse(popover.tookKeyboard, "a click never takes the keyboard")
            assertComposerIntact(p.rig, name("after opening"))

            p.rig.assertNoMove(name("ten snapshots update the open list"), following: following) {
                for n in 1 ... 10 { p.world.ingest(p.world.running(n * 4)) }
            }
            XCTAssertEqual(popover.viewController.list.running.count, 40, "the open list shows the last snapshot")

            p.rig.assertNoMove(name("the list scrolls"), following: following) {
                scrollList(of: popover, to: 100)
            }
            XCTAssertEqual(popover.viewController.scrollView.contentView.bounds.origin.y, 100, accuracy: 1,
                           "the list scrolled inside the popover")

            p.rig.assertNoMove(name("Esc closes the list"), following: following) {
                XCTAssertNil(popover.handleMonitoredKey(BA3UIKey.keyDown(BA3UIKey.escape)), "Esc is consumed")
                waitForClose(bar)
            }
            assertComposerIntact(p.rig, name("after Esc"))

            p.rig.assertNoMove(name("the list reopens"), following: following) {
                bar.toggleBackgroundPopover(takeKeyboard: false)
            }
            let again = try XCTUnwrap(bar.backgroundPopover)
            XCTAssertTrue(again.isShown)

            p.rig.assertNoMove(name("a click outside closes the list"), following: following) {
                again.close()
                waitForClose(bar)
            }
            assertComposerIntact(p.rig, name("after a click outside"))
        }
    }

    func testOpeningAFailedListHidesTheChipWithoutMovingAnything() throws {
        for following in [true, false] {
            let p = pane(following: following)
            p.world.ingest([p.world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: 1)])
            XCTAssertEqual(p.bar.backgroundChip.chipState, .failed(1), "precondition")
            p.world.clock.advance(1)

            p.rig.assertNoMove("opening the list hides the failed chip (following: \(following))", following: following) {
                p.bar.toggleBackgroundPopover(takeKeyboard: false)
            }

            XCTAssertEqual(p.bar.backgroundChip.chipState, .hidden)
            XCTAssertTrue(p.bar.backgroundPopover?.isShown ?? false)
        }
    }

    // MARK: The popover, opened from the keyboard

    func testOpeningWithShiftCommandBTakesTheKeyboardIntoTheListAndClosingGivesTheComposerBack() throws {
        for following in [true, false] {
            let p = pane(following: following)
            let bar = p.bar
            p.world.ingest(p.world.fixture())

            p.rig.assertNoMove("shift-command-B opens the list (following: \(following))", following: following,
                               focusMovesOnPurpose: true) {
                bar.showBackgroundPopover(nil)
            }

            let popover = try XCTUnwrap(bar.backgroundPopover)
            XCTAssertTrue(popover.isShown)
            XCTAssertTrue(popover.tookKeyboard, "opened from the keyboard: the keyboard goes into the list")
            let content = popover.viewController.contentView
            let popoverWindow = try XCTUnwrap(content.window, "the list has a window")
            XCTAssertTrue(popoverWindow.firstResponder === content, "the list's content view is its window's first responder")
            XCTAssertEqual(popover.viewController.selectedIndex, 0, "the first row is selected")
            XCTAssertEqual(popover.viewController.selectedRow?.id, "agent")

            p.rig.assertNoMove("Esc in the list closes it (following: \(following))", following: following,
                               focusMovesOnPurpose: true) {
                content.keyDown(with: BA3UIKey.keyDown(BA3UIKey.escape))
                waitForClose(bar)
            }

            XCTAssertFalse(popover.isShown)
            XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView, "the composer is the first responder again")
            XCTAssertEqual(p.rig.textView.string, SafetyRig.typedText, "with exactly the text it had")
            XCTAssertEqual(p.rig.textView.selectedRange(), SafetyRig.typedSelection, "and exactly the selection it had")
        }
    }

    func testShiftCommandBAgainClosesTheListAndTheComposerIsBack() throws {
        let p = pane(following: true)
        p.world.ingest(p.world.fixture())
        p.bar.showBackgroundPopover(nil)
        let popover = try XCTUnwrap(p.bar.backgroundPopover)
        XCTAssertTrue(popover.tookKeyboard, "precondition")

        p.rig.assertNoMove("shift-command-B again (following: true)", following: true, focusMovesOnPurpose: true) {
            _ = popover.viewController.contentView.tryToPerform(BackgroundShortcut.action, with: nil)
            waitForClose(p.bar)
        }

        assertComposerIntact(p.rig, "after the second shift-command-B")
    }

    // MARK: A second window on the same focus

    func testASecondWindowOnTheSameFocusDoingTheSameMovesTheFirstPaneNotAtAll() throws {
        for following in [true, false] {
            let p = pane(following: following)
            let second = ba3uiVisibleWindow(self, size: NSSize(width: 600, height: 60))
            let bar2 = ba3uiMakeBar(in: second, store: p.world.store, displayName: "Claudia")
            bars.append(bar2)
            let name = { (step: String) in "\(step) (following: \(following))" }
            // Making the second window key is not the event under test.
            XCTAssertTrue(p.rig.window.firstResponder === p.rig.textView, "precondition")

            p.rig.assertNoMove(name("tasks start and change while two windows watch"), following: following) {
                p.world.ingest(p.world.running(1))
                p.world.ingest(p.world.running(12))
            }
            XCTAssertEqual(bar2.backgroundChip.title, p.bar.backgroundChip.title, "both windows show the same chip")
            XCTAssertEqual(p.bar.backgroundChip.chipState, .running(12))

            p.rig.assertNoMove(name("the second window opens its list, it updates, scrolls and closes"), following: following) {
                bar2.toggleBackgroundPopover(takeKeyboard: false)
                for n in 1 ... 10 { p.world.ingest(p.world.running(n * 3)) }
                if let popover = bar2.backgroundPopover { scrollList(of: popover, to: 80) }
                bar2.backgroundPopover?.close()
                waitForClose(bar2)
            }
            XCTAssertNil(bar2.backgroundPopover)
            XCTAssertEqual(bar2.backgroundChip.title, p.bar.backgroundChip.title)
            assertComposerIntact(p.rig, name("after the second window's list"))

            p.world.ingest([p.world.task("job0", "job number 0", status: .failed, startedAgo: 1_000, endedAgo: 1)])
            XCTAssertEqual(p.bar.backgroundChip.chipState, .failed(1), "precondition")
            p.world.clock.advance(1)

            p.rig.assertNoMove(name("the second window opens the failed list, so this window's chip goes"), following: following) {
                bar2.toggleBackgroundPopover(takeKeyboard: false)
            }
            XCTAssertEqual(p.bar.backgroundChip.chipState, .hidden, "seen in one window is seen in both")
            XCTAssertEqual(bar2.backgroundChip.chipState, .hidden)

            p.rig.assertNoMove(name("the second window takes the keyboard into its list and gives it back"), following: following) {
                bar2.backgroundPopover?.close()
                waitForClose(bar2)
                bar2.showBackgroundPopover(nil)
                bar2.backgroundPopover?.close()
                waitForClose(bar2)
            }
            assertComposerIntact(p.rig, name("after the second window's keyboard visit"))
        }
    }

    // MARK: BA5: Stop

    private static let human: HumanGestureVerdict = .human(sourcePid: nil, sourceState: nil)

    private func title(_ button: TaskStopButton?) -> String { button?.attributedTitle.string ?? "<no button>" }

    /// Every step of a Stop: the first click, the 3 s revert, the confirming click, `Stopping…`, the task
    /// ending (`stopped`) and `Couldn't stop: …`, in the popover. Each runs inside `assertNoMove` (first
    /// visible line <= 1 pt, composer text, selection and first responder unchanged) and also asserts that
    /// no visible row changed height, the list's document kept its height and the popover's own first
    /// responder stayed where it was (a notice or button that grew a row, or took the keyboard, fails here).
    func testEachStepOfStoppingATaskInThePopoverMovesNothing() throws {
        for following in [true, false] {
            let gate = BA5StopGate(self)
            let p = pane(following: following, world: gate.world)
            let bar = p.bar
            gate.world.ingest(gate.world.running(3))
            let name = { (step: String) in "\(step) (following: \(following))" }

            p.rig.assertNoMove(name("popover opens"), following: following) {
                bar.toggleBackgroundPopover(takeKeyboard: false)
            }
            let popover = try XCTUnwrap(bar.backgroundPopover)
            let vc = popover.viewController
            vc.stopPermit = { _ in Self.human }
            vc.stopMenuPermit = { _ in Self.human }
            vc.stopSchedule = { delay, work in gate.buttonHand.schedule(delay, work) }
            let popoverWindow = try XCTUnwrap(vc.view.window, "the list has a window")
            func rowView(_ id: String) throws -> BackgroundTaskRowView {
                try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == id }, "no visible row \(id)")
            }
            func heights() -> [String: CGFloat] {
                Dictionary(uniqueKeysWithValues: vc.visibleRowViews.map { ($0.row.id, $0.frame.height) })
            }
            func documentHeight() -> CGFloat { vc.scrollView.documentView?.frame.height ?? 0 }

            func step(_ what: String, rowsKeepTheirHeight: Bool = true, _ event: () -> Void) {
                let rows = heights()
                let document = documentHeight()
                let responder = popoverWindow.firstResponder
                XCTAssertFalse(rows.isEmpty, "\(name(what)): precondition: rows are shown")
                p.rig.assertNoMove(name(what), following: following) {
                    gate.world.clock.advance(1)
                    event()
                    gate.flushDeliveries()
                }
                if rowsKeepTheirHeight {
                    XCTAssertEqual(heights(), rows, "\(name(what)): a row changed height")
                    XCTAssertEqual(documentHeight(), document, accuracy: 0.5, "\(name(what)): the list changed height")
                }
                XCTAssertTrue(popoverWindow.firstResponder === responder, "\(name(what)): the popover's first responder moved")
                assertComposerIntact(p.rig, name(what))
            }

            step("first click on Stop") { try? rowView("job0").stopButton?.clicked(nil) }
            XCTAssertEqual(title(try rowView("job0").stopButton), "Stop?")
            XCTAssertEqual(gate.sender.stops.count, 0)

            step("the 3 s revert") { gate.buttonHand.fire(where: { $0 == 3 }) }
            XCTAssertEqual(title(try rowView("job0").stopButton), "Stop")

            step("the confirm click") {
                try? rowView("job0").stopButton?.clicked(nil)
                try? rowView("job0").stopButton?.clicked(nil)
            }
            XCTAssertEqual(gate.sender.stops.count, 1, "exactly one stop was sent")
            XCTAssertEqual(title(try rowView("job0").stopButton), "Stopping\u{2026}")

            step("the daemon accepts: still Stopping\u{2026}") { gate.answer("accepted", taskId: "job0") }
            XCTAssertEqual(title(try rowView("job0").stopButton), "Stopping\u{2026}")

            step("a refusal shows Couldn't stop") {
                try? rowView("job1").stopButton?.clicked(nil)
                try? rowView("job1").stopButton?.clicked(nil)
                gate.answer("refused", message: "Task is protected", taskId: "job1")
            }
            XCTAssertEqual(try rowView("job1").stopNoticeText, "Couldn't stop: Task is protected")
            XCTAssertEqual(title(try rowView("job1").stopButton), "Stop")

            step("a timeout shows Couldn't stop") {
                try? rowView("job2").stopButton?.clicked(nil)
                try? rowView("job2").stopButton?.clicked(nil)
                gate.answer("timeout", taskId: "job2")
            }
            XCTAssertEqual(try rowView("job2").stopNoticeText, "Couldn't stop: Claude Code didn't answer")

            // job0's stop was accepted at "the daemon accepts" and no snapshot has shown it over since.
            step("10 s pass with no confirmation") {
                gate.storeHand.fire(where: { $0 >= BackgroundTaskStore.confirmationTimeout })
            }
            XCTAssertEqual(try rowView("job0").stopNoticeText, "Couldn't stop: no confirmation from Claude Code")
            XCTAssertEqual(title(try rowView("job0").stopButton), "Stop")

            // The row leaves the running section for Ended, so its own height is allowed to differ.
            step("the snapshot reports the task stopped", rowsKeepTheirHeight: false) {
                gate.world.ingest([gate.world.task("job0", "job number 0", status: .stopped, startedAgo: 1_000, endedAgo: 1),
                                   gate.world.task("job1", "job number 1", startedAgo: 999),
                                   gate.world.task("job2", "job number 2", startedAgo: 998)])
            }
            let stopped = try rowView("job0")
            XCTAssertEqual(stopped.statusText, "stopped")
            XCTAssertTrue(stopped.stopButton?.isHidden ?? true, "a stopped task offers no Stop")
            XCTAssertEqual(try rowView("job1").stopNoticeText, "Couldn't stop: Task is protected", "the failure survives the snapshot")
            XCTAssertEqual(gate.sender.stops.count, 3)

            step("the CLI turns out not to support Stop") {
                gate.world.store.ingest(.sessionTasks(SessionTasksWire(
                    tag: "gate", sessionId: "session-1", daemonEpoch: "epoch-1", stopSupported: false,
                    tasks: [gate.world.task("job0", "job number 0", status: .stopped, startedAgo: 1_000, endedAgo: 1),
                            gate.world.task("job1", "job number 1", startedAgo: 999),
                            gate.world.task("job2", "job number 2", startedAgo: 998)])))
            }
            XCTAssertTrue(try rowView("job1").stopButton?.isHidden ?? true, "no Stop is offered once it is unsupported")
        }
    }

    /// The same steps in a task window: its header holds the button and the notice (the title line is pinned
    /// to the stack's trailing edge), so the header, the panel and the main pane must all stay put.
    func testEachStepOfStoppingATaskInATaskWindowMovesNothing() throws {
        for following in [true, false] {
            let gate = BA5StopGate(self)
            let p = pane(following: following, world: gate.world)
            let tw = BA4TWWorld(self, tag: "gate", world: gate.world, keyWindow: p.rig.window)
            tw.ingest([tw.task("job0", "npm run dev"), tw.task("job1", "npm run build")])
            tw.manager.stopPermit = { _ in Self.human }
            tw.manager.stopSchedule = { delay, work in gate.buttonHand.schedule(delay, work) }
            let name = { (step: String) in "\(step) (following: \(following))" }

            var opened: [TaskWindowController] = []
            p.rig.assertNoMove(name("two task windows open"), following: following) {
                opened = ["job0", "job1"].compactMap { tw.open($0) }
                tw.pump()
                opened.forEach { $0.panel.contentView?.layoutSubtreeIfNeeded() }
            }
            XCTAssertEqual(opened.count, 2, "precondition: both windows opened")
            let (c0, c1) = (opened[0], opened[1])
            func header(_ c: TaskWindowController) -> TaskWindowHeaderView { c.body.header }

            func step(_ what: String, headersKeepTheirHeight: Bool = true, _ event: () -> Void) {
                let heights = opened.map { header($0).frame.height }
                let frames = opened.map { $0.panel.frame }
                let responders = opened.map { $0.panel.firstResponder }
                p.rig.assertNoMove(name(what), following: following) {
                    gate.world.clock.advance(1)
                    event()
                    gate.flushDeliveries()
                    opened.forEach { $0.panel.contentView?.layoutSubtreeIfNeeded() }
                }
                // An ended task's own header may differ (its status line); the other window's may not.
                let checked = headersKeepTheirHeight ? Array(opened.indices) : [1]
                for index in checked {
                    XCTAssertEqual(header(opened[index]).frame.height, heights[index], accuracy: 0.5,
                                   "\(name(what)): window \(index)'s header changed height")
                }
                XCTAssertEqual(opened.map { $0.panel.frame }, frames, "\(name(what)): a window moved or resized")
                for (index, panel) in opened.enumerated() {
                    XCTAssertTrue(panel.panel.firstResponder === responders[index], "\(name(what)): window \(index)'s first responder moved")
                }
                assertComposerIntact(p.rig, name(what))
            }

            step("first click on Stop") { header(c0).stopButton?.clicked(nil) }
            XCTAssertEqual(title(header(c0).stopButton), "Stop?")
            XCTAssertEqual(gate.sender.stops.count, 0)

            step("the 3 s revert") { gate.buttonHand.fire(where: { $0 == 3 }) }
            XCTAssertEqual(title(header(c0).stopButton), "Stop")

            step("the confirm click") {
                header(c0).stopButton?.clicked(nil)
                header(c0).stopButton?.clicked(nil)
            }
            XCTAssertEqual(gate.sender.stops.count, 1)
            XCTAssertEqual(title(header(c0).stopButton), "Stopping\u{2026}")

            step("the daemon accepts: still Stopping\u{2026}") { gate.answer("accepted", taskId: "job0") }
            XCTAssertEqual(title(header(c0).stopButton), "Stopping\u{2026}")

            step("a refusal shows Couldn't stop") {
                header(c1).stopButton?.clicked(nil)
                header(c1).stopButton?.clicked(nil)
                gate.answer("refused", message: "Task is protected", taskId: "job1")
            }
            XCTAssertEqual(header(c1).stopNoticeText, "Couldn't stop: Task is protected")
            XCTAssertEqual(title(header(c1).stopButton), "Stop")

            // job0's stop was accepted at "the daemon accepts" and no snapshot has shown it over since.
            step("10 s pass with no confirmation") {
                gate.storeHand.fire(where: { $0 >= BackgroundTaskStore.confirmationTimeout })
            }
            XCTAssertEqual(header(c0).stopNoticeText, "Couldn't stop: no confirmation from Claude Code")
            XCTAssertEqual(title(header(c0).stopButton), "Stop")

            step("the snapshot reports the task stopped", headersKeepTheirHeight: false) {
                tw.ingest([tw.task("job0", "npm run dev", status: .stopped), tw.task("job1", "npm run build")])
            }
            XCTAssertTrue(header(c0).stopButton?.isHidden ?? true, "a stopped task offers no Stop")
            XCTAssertEqual(header(c1).stopNoticeText, "Couldn't stop: Task is protected")
            XCTAssertEqual(gate.sender.stops.count, 2)

            // A new daemon epoch clears the failure, so the header can say why there is no button. Its height
            // may change (the button goes), so this is not a `step`: the pane and the panels still must not move.
            let frames = opened.map { $0.panel.frame }
            p.rig.assertNoMove(name("the CLI turns out not to support Stop"), following: following) {
                gate.world.clock.advance(1)
                tw.world.store.ingest(.sessionTasks(SessionTasksWire(
                    tag: "gate", sessionId: "session-1", daemonEpoch: "epoch-2", stopSupported: false,
                    tasks: [tw.task("job0", "npm run dev", status: .stopped), tw.task("job1", "npm run build")])))
                gate.flushDeliveries()
                opened.forEach { $0.panel.contentView?.layoutSubtreeIfNeeded() }
            }
            XCTAssertEqual(opened.map { $0.panel.frame }, frames, "\(name("unsupported")): a window moved or resized")
            assertComposerIntact(p.rig, name("unsupported"))
            XCTAssertEqual(header(c1).stopNoticeText, "This Claude Code version can't stop tasks from Nostromo")
            XCTAssertTrue(header(c1).stopButton?.isHidden ?? true)
        }
    }

    /// Cmd-. in the popover and in a task window starts the two-step Stop of that task: two presses send exactly
    /// one `session_task_stop` and the input bar's interrupt (its Stop button's Cmd-.) never runs. The task
    /// requests' sender can only record outputs and stops, so the interrupt is watched where it would
    /// start: the bar's `onInterrupt`, which `ReplView` wires to `session.interrupt()` (`session_interrupt`).
    func testCommandPeriodInThePopoverAndAWindowSendsOnlyAStopAndNeverAnInterrupt() throws {
        let gate = BA5StopGate(self)
        let p = pane(following: true, world: gate.world)
        var interrupts = 0
        p.bar.onInterrupt = { interrupts += 1 }
        gate.world.ingest(gate.world.running(2))
        p.bar.toggleBackgroundPopover(takeKeyboard: true)
        let popover = try XCTUnwrap(p.bar.backgroundPopover)
        let vc = popover.viewController
        vc.stopPermit = { _ in Self.human }
        vc.stopSchedule = { delay, work in gate.buttonHand.schedule(delay, work) }
        let index = try XCTUnwrap(vc.selectables.firstIndex { ($0 as? BackgroundTaskRowView)?.row.id == "job0" })
        vc.select(index)

        gate.world.clock.advance(1)
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()), "the popover consumes Cmd-.")
        XCTAssertEqual(gate.sender.stops.count, 0, "one press only arms")
        XCTAssertTrue(vc.handleKey(tsCommandPeriod()))
        XCTAssertEqual(gate.sender.stops.count, 1, "the second press sends exactly one session_task_stop")
        XCTAssertEqual(interrupts, 0, "and no interrupt")

        let tw = BA4TWWorld(self, tag: "gate", world: gate.world, keyWindow: p.rig.window)
        tw.manager.stopPermit = { _ in Self.human }
        tw.manager.stopSchedule = { delay, work in gate.buttonHand.schedule(delay, work) }
        let controller = try XCTUnwrap(tw.open("job1"))
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()), "the window consumes Cmd-.")
        XCTAssertEqual(gate.sender.stops.count, 1)
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: tsCommandPeriod()))
        XCTAssertEqual(gate.sender.stops.count, 2, "one more stop, for the window's own task")
        XCTAssertEqual(interrupts, 0, "Cmd-. never reaches the input bar's interrupt")
        XCTAssertTrue(gate.sender.outputs.isEmpty, "the sender saw stops and nothing else")
    }

    /// The branch that protects the composer is the popover's key monitor: with the popover holding the
    /// keyboard it takes ⌘. for the selected row's Stop (returning nil, so AppKit never sends it on to the
    /// main window's key-equivalent search, where the input bar's interrupt lives); without the keyboard
    /// it hands the event back untouched. Both are checked here the way the monitor uses them: whatever it
    /// returns is what the main window then gets.
    func testTheMonitorTakesCommandPeriodWhenThePopoverHasTheKeyboardAndOtherwiseLeavesItAlone() throws {
        let gate = BA5StopGate(self)
        let p = pane(following: true, world: gate.world)
        var interrupts = 0
        p.bar.onInterrupt = { interrupts += 1 }
        gate.world.ingest(gate.world.running(2))
        p.bar.toggleBackgroundPopover(takeKeyboard: true)
        let popover = try XCTUnwrap(p.bar.backgroundPopover)
        XCTAssertTrue(popover.tookKeyboard, "precondition: the popover holds the keyboard")
        let vc = popover.viewController
        vc.stopPermit = { _ in Self.human }
        vc.stopSchedule = { delay, work in gate.buttonHand.schedule(delay, work) }
        let index = try XCTUnwrap(vc.selectables.firstIndex { ($0 as? BackgroundTaskRowView)?.row.id == "job0" })
        vc.select(index)

        func dispatch(_ event: NSEvent) -> NSEvent? {
            let passedOn = popover.handleMonitoredKey(event)
            if let passedOn { _ = p.rig.window.performKeyEquivalent(with: passedOn) }
            return passedOn
        }

        XCTAssertNil(dispatch(tsCommandPeriod()), "the monitor consumes ⌘. while the popover has the keyboard")
        XCTAssertEqual(gate.sender.stops.count, 0, "one press only arms")
        XCTAssertNil(dispatch(tsCommandPeriod()))
        XCTAssertEqual(gate.sender.stops.count, 1, "the second sends the one stop")
        XCTAssertEqual(interrupts, 0, "and ⌘. never reached the main window's composer")
        XCTAssertTrue(gate.sender.outputs.isEmpty)

        let plain = BA3UIKey.keyDown(0, "a")
        XCTAssertTrue(popover.handleMonitoredKey(plain) === plain, "other keys go on unchanged")
    }

    func testTheMonitorLeavesCommandPeriodToTheWindowWhenThePopoverDoesNotHoldTheKeyboard() throws {
        let gate = BA5StopGate(self)
        let p = pane(following: true, world: gate.world)
        gate.world.ingest(gate.world.running(1))
        p.bar.toggleBackgroundPopover(takeKeyboard: false)
        let popover = try XCTUnwrap(p.bar.backgroundPopover)
        XCTAssertFalse(popover.tookKeyboard, "precondition: the composer keeps the keyboard")
        let event = tsCommandPeriod()

        XCTAssertTrue(popover.handleMonitoredKey(event) === event,
                      "with the composer holding the keyboard, ⌘. is the composer's (its interrupt), not a Stop")
        XCTAssertEqual(gate.sender.stops.count, 0)
    }

    // MARK: BA4: a task window

    private static func lines(_ range: Range<Int>) -> String {
        range.map { "output line \($0)\n" }.joined()
    }

    /// A task-window manager over the pane's own store, its key window the rig window, with a running
    /// shell task `job0` and some output behind it.
    private func taskWindows(_ p: Pane, keyWindow: NSWindow? = nil) -> BA4TWWorld {
        let tw = BA4TWWorld(self, tag: "gate", world: p.world, keyWindow: keyWindow ?? p.rig.window)
        tw.ingest([tw.task("job0", "npm run dev")])
        tw.outputs["job0"] = Self.lines(0 ..< 60)
        return tw
    }

    /// 50 rounds of what a live task window receives: a new snapshot (new description) and a poll that
    /// finds more output.
    private func feed(_ tw: BA4TWWorld, rounds: Int = 50) {
        for n in 1 ... rounds {
            tw.ingest([tw.task("job0", "npm run dev (step \(n))")])
            tw.outputs["job0", default: ""] += Self.lines((60 + (n - 1) * 5) ..< (60 + n * 5))
            tw.poll()
        }
    }

    /// The window's own text scrolled to its top and back to the tail.
    private func scrollOwnText(of controller: TaskWindowController) {
        guard let output = controller.body as? TaskOutputView else { return XCTFail("a shell window shows output") }
        output.scrollView.contentView.scroll(to: .zero)
        output.scrollView.reflectScrolledClipView(output.scrollView.contentView)
        output.jumpToLatest()
    }

    func testATaskWindowOpeningUpdatingScrollingAndClosingMovesNothingInTheMainPane() {
        for following in [true, false] {
            let p = pane(following: following)
            let tw = taskWindows(p)
            let name = { (step: String) in "\(step) (following: \(following))" }
            var shown = ""
            var title = ""

            p.rig.assertNoMove(name("a task window opens, takes 50 updates, scrolls and closes"), following: following) {
                guard let controller = tw.open("job0") else { return XCTFail("the task window did not open") }
                tw.pump()
                controller.panel.contentView?.layoutSubtreeIfNeeded()
                feed(tw)
                scrollOwnText(of: controller)
                shown = (controller.body as? TaskOutputView)?.shownText ?? ""
                title = controller.panel.title
                controller.close()
            }

            XCTAssertTrue(shown.contains("output line 309"), "precondition: the window really received its 50 appends")
            XCTAssertEqual(title, "Claudia \u{00B7} Shell: npm run dev (step 50)", "and its 50 snapshots")
            XCTAssertEqual(tw.manager.openCount, 0)
            XCTAssertEqual(tw.pollScheduler.liveCount, 0, "nothing keeps polling after it closed")
            assertComposerIntact(p.rig, name("after the task window closed"))
        }
    }

    func testEachStepOfATaskWindowsLifeMovesNothingInTheMainPaneWhileItStaysOpenAlongsideIt() {
        for following in [true, false] {
            let p = pane(following: following)
            let tw = taskWindows(p)
            let name = { (step: String) in "\(step) (following: \(following))" }
            var opened: TaskWindowController?

            p.rig.assertNoMove(name("the task window opens"), following: following) {
                opened = tw.open("job0")
                tw.pump()
                opened?.panel.contentView?.layoutSubtreeIfNeeded()
            }
            guard let controller = opened, let output = controller.body as? TaskOutputView else {
                XCTFail("the task window did not open (following: \(following))")
                continue
            }
            XCTAssertTrue(controller.isOpen && controller.panel.isVisible, "precondition: the panel is open alongside the rig window")

            p.rig.assertNoMove(name("the task window takes the keyboard in its own text"), following: following) {
                _ = controller.panel.makeFirstResponder(output.textView)
            }

            p.rig.assertNoMove(name("50 updates reach the open task window"), following: following) {
                feed(tw)
            }
            XCTAssertTrue(output.shownText.contains("output line 309"), "precondition: the updates reached it")

            p.rig.assertNoMove(name("its own text scrolls"), following: following) {
                scrollOwnText(of: controller)
            }

            p.rig.assertNoMove(name("its text is selected and copied"), following: following) {
                output.textView.selectAll(nil)
                output.copyAll()
            }
            XCTAssertEqual(tw.pasteboard.string(forType: .string), tw.outputs["job0"], "Copy All went to the injected pasteboard")

            p.rig.assertNoMove(name("Esc closes it"), following: following) {
                XCTAssertTrue(controller.panel.performKeyEquivalent(with: BA3UIKey.keyDown(BA3UIKey.escape)), "Esc is consumed")
            }

            XCTAssertFalse(controller.isOpen)
            XCTAssertEqual(tw.manager.openCount, 0)
            XCTAssertTrue(p.rig.window.isKeyWindow, "the rig window is key (always true for this test window: see the file comment)")
            XCTAssertFalse(NSApplication.shared.keyWindow === controller.panel, "the closed panel is not the key window")
            XCTAssertFalse(controller.panel.canBecomeMain, "and it never was the main window")
            assertComposerIntact(p.rig, name("after the task window closed"))
        }
    }

    func testATaskWindowOpeningAndClosingSendsNoBytesToATerminalThatHoldsTheKeyboard() throws {
        // `NostromoTerminalView` and `TerminalPaneHostView` link SwiftTerm, which the test bundle does not,
        // so the terminal is a stand-in that does what the real one does with the keyboard: keys go to
        // `TerminalSessionStore.sendInput`, and it reports focus changes (a terminal with focus reporting
        // writes ESC [ I / ESC [ O when it gains or loses first responder). Whatever reaches the daemon
        // connection is recorded by the store's transport.
        let wire = BA4TerminalWire()
        let store = TerminalSessionStore(now: { Date(timeIntervalSinceReferenceDate: 1_000_000) },
                                         schedule: { _, _ in }, transport: { wire.sent.append($0) })
        store.connectionChanged(true)
        store.ingest(.terminalState(TerminalInfo(
            terminalId: "t1", tag: "gate", paneId: "terminal-a", kind: .local, label: "zsh", cwd: "/tmp",
            target: nil, status: .running, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
            requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil, follower: nil,
            idleClosesAt: nil)))

        let host = ba3uiVisibleWindow(self, size: NSSize(width: 600, height: 300))
        let terminal = BA4TerminalStandIn(frame: host.contentView!.bounds, store: store, terminalId: "t1", windowId: "w1")
        host.contentView?.addSubview(terminal)
        XCTAssertTrue(host.makeFirstResponder(terminal), "precondition: the terminal holds the keyboard")
        terminal.type("l")
        XCTAssertFalse(wire.inputFrames.isEmpty, "precondition: what the terminal sends does reach the recorded connection")
        let before = wire.sent.count

        let tw = BA4TWWorld(self, tag: "gate", keyWindow: host)
        tw.ingest([tw.task("job0", "npm run dev")])
        tw.outputs["job0"] = Self.lines(0 ..< 60)
        let controller = try XCTUnwrap(tw.open("job0"))
        tw.pump()
        feed(tw)
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: BA3UIKey.keyDown(47, ".", flags: .command)), "Cmd-. stays in the panel")
        XCTAssertTrue(controller.panel.performKeyEquivalent(with: BA3UIKey.keyDown(BA3UIKey.escape)), "Esc closes it")

        XCTAssertEqual(tw.manager.openCount, 0, "precondition: the window opened and closed")
        XCTAssertEqual(wire.sent.count, before, "no frame at all reached the terminal's connection: \(wire.sent.dropFirst(before))")
        XCTAssertTrue(host.firstResponder === terminal, "the terminal still holds the keyboard")

        terminal.type("x")
        XCTAssertGreaterThan(wire.sent.count, before, "and it is still wired to the connection")
    }
}

// MARK: - BA5: a store with a recording daemon behind Stop

/// Timers held by hand: what is asked for waits until the test fires it.
private final class BA5Hand {
    private var items: [(delay: TimeInterval, work: () -> Void)] = []

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        items.append((delay, work))
    }

    func fire(where match: (TimeInterval) -> Bool) {
        let due = items.filter { match($0.delay) }
        items.removeAll { match($0.delay) }
        due.forEach { $0.work() }
    }
}

/// A `BA3UIWorld` whose store sends Stop through real `TaskRequests` to a recording sender, and whose
/// store timers (4 Hz coalescing, the 10 s confirmation) and request timeouts do not run on their own.
private final class BA5StopGate {
    let sender = BA4TWSender()
    let storeHand = BA5Hand()
    let requestHand = BA5Hand()
    /// The buttons' 3 s confirmation reverts.
    let buttonHand = BA5Hand()
    let requests: TaskRequests
    let world: BA3UIWorld

    init(_ testCase: XCTestCase) {
        let ids = BA4TWCounter()
        let requestHand = self.requestHand
        let storeHand = self.storeHand
        let requests = TaskRequests(makeRequestId: { ids.next() }, schedule: { delay, work in requestHand.schedule(delay, work) })
        requests.sender = sender
        self.requests = requests
        world = BA3UIWorld(testCase, requests: { requests }, schedule: { delay, work in storeHand.schedule(delay, work) })
    }

    /// The daemon's `session_task_stop_result` for the latest stop sent.
    /// The store's deferred, coalesced deliveries (not its 10 s confirmation timers).
    func flushDeliveries() {
        storeHand.fire(where: { $0 < BackgroundTaskStore.confirmationTimeout })
    }

    func answer(_ outcome: String, message: String? = nil, taskId: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let requestId = sender.stops.last else { return XCTFail("no stop was sent", file: file, line: line) }
        world.clock.advance(1)
        var object: [String: Any] = ["request_id": requestId, "tag": "gate", "task_id": taskId, "outcome": outcome]
        if let message { object["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let wire = try? JSONDecoder().decode(SessionTaskStopResultWire.self, from: data) else {
            return XCTFail("could not build the daemon's answer", file: file, line: line)
        }
        requests.ingest(.sessionTaskStopResult(wire))
    }
}

// MARK: - A terminal that holds the keyboard

/// What reached the daemon connection from the terminal store.
private final class BA4TerminalWire {
    var sent: [TerminalClientMessage] = []

    var inputFrames: [TerminalClientMessage] {
        sent.filter { if case .input = $0 { return true } else { return false } }
    }
}

/// Stands in for the SwiftTerm views: keys and focus reports go to the store like the real terminal's do.
private final class BA4TerminalStandIn: NSView {
    private let store: TerminalSessionStore
    private let terminalId: String
    private let windowId: String

    init(frame: NSRect, store: TerminalSessionStore, terminalId: String, windowId: String) {
        self.store = store
        self.terminalId = terminalId
        self.windowId = windowId
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        send("\u{1B}[I", autoReply: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        send("\u{1B}[O", autoReply: true)
        return true
    }

    override func keyDown(with event: NSEvent) {
        type(event.characters ?? "")
    }

    func type(_ text: String) {
        send(text, autoReply: false)
    }

    private func send(_ text: String, autoReply: Bool) {
        _ = store.sendInput(terminalId: terminalId, bytes: Array(text.utf8), fromWindow: windowId, autoReply: autoReply)
    }
}
