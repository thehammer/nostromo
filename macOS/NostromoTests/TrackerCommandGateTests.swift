import XCTest
import AppKit
import NostromoKit

// "No agent path to any shell; the human pastes, manually, every time." The Ran it checkbox changes the
// board (it ticks a staged command as run), so it is a human-gesture-gated control like the staging and
// Merge ones: `HumanGesture.permit` first. Input from app-control, an Accessibility press with no event
// and a stale event are refused, say so on the block, and send nothing. Copy sends nothing at all.
final class TrackerCommandGateTests: MouseQueueTestCase {

    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 420, height: 200))
        addTeardownBlock { [window] in window?.close() }
    }

    private struct Rig {
        let block: TrackerCommandBlockView
        let fired: () -> Int
    }

    /// A block in the window whose gate is the REAL `HumanGesture.permit` on `event()`, with the
    /// environment seams pinned (no VoiceOver, no synthetic input allowed).
    private func rig(event: @escaping () -> NSEvent?, voiceOver: Bool = false, ran: Bool = false) -> Rig {
        let board = NSPasteboard(name: NSPasteboard.Name("TrackerGate-\(UUID().uuidString)"))
        addTeardownBlock { board.releaseGlobally() }
        let block = TrackerCommandBlockView(command: "php artisan queue:retry 8812", env: .prod, ran: ran,
                                            canMarkRan: true, pasteboard: board)
        block.frame = NSRect(x: 0, y: 0, width: 380, height: block.height(forWidth: 380))
        window.contentView!.addSubview(block)
        block.layoutSubtreeIfNeeded()
        var count = 0
        block.onRanIt = { count += 1 }
        block.permit = { control in
            HumanGesture.permit(event(), control: control, voiceOverEnabled: { voiceOver }, allowsSynthetic: { false })
        }
        return Rig(block: block, fired: { count })
    }

    private func click() -> NSEvent { GestureFixtures.mouse(.leftMouseUp, in: window) }

    func testAPersonsClickTicksIt() {
        let r = rig(event: { self.click() })
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 1)
        XCTAssertNil(r.block.noticeText)
    }

    func testAnEventStampedByAppControlIsRefusedAndSaysSo() throws {
        let event = try GestureFixtures.marked(click())
        let r = rig(event: { event })
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 0, "nothing sent")
        XCTAssertEqual(r.block.noticeText, "Not ticked: click it yourself")
        XCTAssertEqual(r.block.noticeLabel?.isHidden, false)
        XCTAssertEqual(r.block.ranItCheckbox.state, .off)
    }

    func testARefusedUntickSaysNotUnticked() throws {
        let event = try GestureFixtures.marked(click())
        let r = rig(event: { event }, ran: true)
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 0)
        XCTAssertEqual(r.block.noticeText, "Not unticked: click it yourself")
        XCTAssertEqual(r.block.ranItCheckbox.state, .on, "the box still shows what the board says")
    }

    func testAnAccessibilityPressWithNoEventIsRefused() {
        let r = rig(event: { nil })
        r.block.ranItCheckbox.accessibilityPerformPress()
        XCTAssertEqual(r.fired(), 0, "an osascript AXPress is not a person")
        XCTAssertNotNil(r.block.noticeText)
    }

    func testAStaleEventIsRefused() {
        let old = GestureFixtures.mouse(.leftMouseUp, in: window,
                                        timestamp: ProcessInfo.processInfo.systemUptime - 30)
        let r = rig(event: { old })
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 0)
        XCTAssertNotNil(r.block.noticeText)
    }

    func testAPressWhileAnAppControlRequestIsRunningIsRefused() {
        let r = rig(event: { self.click() })
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 0)
        XCTAssertNotNil(r.block.noticeText)
    }

    func testAPersonsClickAfterARefusalWorksAndClearsTheNotice() throws {
        var event: NSEvent? = try GestureFixtures.marked(click())
        let r = rig(event: { event })
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertNotNil(r.block.noticeText)
        event = click()
        r.block.ranItCheckbox.performClick(nil)
        XCTAssertEqual(r.fired(), 1)
        XCTAssertNil(r.block.noticeText)
        XCTAssertEqual(r.block.noticeLabel?.isHidden, true)
    }

    /// The gate a block has when nobody replaces it is the live one (`HumanGesture.permit` on the current event).
    func testTheDefaultGateIsTheLiveOneAndRefusesWhileAppControlRuns() {
        let block = TrackerCommandBlockView(command: "ls", env: .prod, ran: false, canMarkRan: true,
                                            pasteboard: NSPasteboard(name: NSPasteboard.Name("TrackerGate-\(UUID().uuidString)")))
        window.contentView!.addSubview(block)
        var fired = 0
        block.onRanIt = { fired += 1 }
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        block.ranItCheckbox.performClick(nil)
        block.ranItCheckbox.accessibilityPerformPress()
        XCTAssertEqual(fired, 0)
        XCTAssertNotNil(block.noticeText)
    }

    func testCopySendsNothingWhateverTheEvent() throws {
        let event = try GestureFixtures.marked(click())
        let r = rig(event: { event })
        r.block.copyButton.performClick(nil)
        r.block.copyButton.accessibilityPerformPress()
        XCTAssertEqual(r.fired(), 0, "Copy never reaches the tick")
    }
}
