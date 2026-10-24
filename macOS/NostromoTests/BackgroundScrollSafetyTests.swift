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
    }

    override func tearDown() {
        bars.forEach { $0.backgroundPopover?.close() }
        bars = []
        super.tearDown()
    }

    /// `SafetyRig.followingTail` / `.scrolledUp`, with the Background slot bound before layout and
    /// the composer focused after.
    private func pane(following: Bool) -> Pane {
        let world = BA3UIWorld(self)
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

            p.rig.assertNoMove("shift-command-B opens the list (following: \(following))", following: following) {
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

            p.rig.assertNoMove("Esc in the list closes it (following: \(following))", following: following) {
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

        p.rig.assertNoMove("shift-command-B again (following: true)", following: true) {
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
}
