import XCTest
import AppKit
import NostromoKit

// T1: the transcript side of the tracker gate (PRD "Scroll, layout and focus safety", criterion 19, Mac half).
//
// The window is an `NSSplitView` (vertical divider): the `SafetyRig`'s transcript and input bar on the
// left, a `TrackerPaneView` on the right. The tracker runs the same thirty scripted updates as
// `TrackerScrollSafetyTests` (`TrackerGateScript`). After every one:
//   - the divider has not moved (both subviews keep their frames);
//   - the transcript's first visible line moved at most 1 pt (scrolled up) or the bottom offset is still 0
//     (following), and the composer kept first responder, text, selection and height
//     (`SafetyRig.assertNoMove`);
//   - the tracker pane, and none of its subviews, is the window's first responder.
//
// The rig builds its own window and lays its scroll view and input bar out against `window.contentView`.
// The split view is made without changing the rig: that content view moves, constraints and all, into the
// split's left side, the window gets the split as its content view, and the window is widened by the
// tracker's width so the transcript keeps the width the rig laid it out at.

final class TrackerTranscriptSafetyTests: XCTestCase {

    private static let trackerWidth: CGFloat = 380

    private struct Pane {
        let rig: SafetyRig
        let harness: TrackerGateHarness
        let split: NSSplitView
        /// The rig's content view (transcript, input bar, overlay), the split's left side.
        let left: NSView
        let leftWidth: CGFloat
    }

    private func makePane(following: Bool, editing: Bool = false) throws -> Pane {
        let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
        let window = rig.window
        let content = try XCTUnwrap(window.contentView)
        let top = rig.clip.bounds.minY
        let leftWidth = content.frame.width
        let height = content.frame.height

        // Classic (non-arranged) split subviews with explicit frames, so AppKit never redistributes the
        // widths: the window grows by the tracker's width, then the split takes the transcript's content
        // view on the left at its original width and the tracker on the right.
        let split = NSSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        // Not arranged: an arranged split lays its subviews out with its own constraints and holding
        // priorities and would not keep the frames below.
        split.arrangesAllSubviews = false
        let total = leftWidth + split.dividerThickness + Self.trackerWidth
        window.setContentSize(NSSize(width: total, height: height))
        split.frame = NSRect(x: 0, y: 0, width: total, height: height)
        window.contentView = split

        let harness = try TrackerGateHarness(self, editing: editing)
        split.addSubview(content)
        split.addSubview(harness.pane)
        content.autoresizingMask = []
        harness.pane.autoresizingMask = []
        content.frame = NSRect(x: 0, y: 0, width: leftWidth, height: height)
        harness.pane.frame = NSRect(x: leftWidth + split.dividerThickness, y: 0, width: Self.trackerWidth, height: height)
        split.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        // Moving the rig's views out of and back into a window resigns the composer and may have nudged
        // the transcript: put both back before the script starts.
        if following {
            rig.followTail.scrollToBottom()
        } else if abs(rig.clip.bounds.minY - top) > 0.5 {
            rig.userScroll(to: top)
        }
        rig.settle()
        rig.focusComposer()

        try harness.push()
        harness.layout()
        try harness.start(.mid)
        return Pane(rig: rig, harness: harness, split: split, left: content, leftWidth: leftWidth)
    }

    private func runScript(following: Bool, events: [TrackerGateEvent] = TrackerGateScript.events(),
                           label: String = "") throws {
        let p = try makePane(following: following)
        let rig = p.rig
        let tracker = p.harness.pane

        // The setup is what the criterion describes.
        XCTAssertTrue(rig.window.contentView === p.split)
        XCTAssertEqual(p.split.subviews.count, 2)
        XCTAssertEqual(p.left.frame.width, p.leftWidth, accuracy: 0.5, "the transcript kept its width")
        XCTAssertGreaterThan(tracker.frame.width, 300, "the tracker has room on the right of the divider")
        XCTAssertNotNil(rig.snapshot().firstVisible, "the transcript has a first visible block")
        XCTAssertNotNil(tracker.anchorSnapshot(windowIndex: 0).firstVisible, "the tracker has a first visible row")
        XCTAssertGreaterThan(tracker.anchorSnapshot(windowIndex: 0).scrollY, 0, "the tracker is scrolled into the board")
        XCTAssertEqual(rig.followTail.isPinned, following, "the transcript is \(following ? "following the tail" : "scrolled up")")
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "the composer holds focus")
        XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
        XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection)
        XCTAssertFalse(p.harness.paneOwnsFirstResponder())

        let leftFrame = p.left.frame
        let trackerFrame = tracker.frame

        for (i, event) in events.enumerated() {
            let name = "\(label)\(following ? "following" : "scrolled up") #\(i + 1) \(event.name)"
            rig.assertNoMove(name, following: following) {
                do {
                    try p.harness.perform(event)
                } catch {
                    XCTFail("\(name): \(error)")
                }
            }
            XCTAssertEqual(p.left.frame, leftFrame, "\(name): the divider moved (transcript side)")
            XCTAssertEqual(tracker.frame, trackerFrame, "\(name): the divider moved (tracker side)")
            XCTAssertFalse(p.harness.paneOwnsFirstResponder(),
                           "\(name): the tracker took keyboard focus (\(String(describing: rig.window.firstResponder)))")
        }
    }

    func testThirtyTrackerUpdatesLeaveAScrolledUpTranscriptAndItsComposerUntouched() throws {
        try runScript(following: false)
    }

    func testThirtyTrackerUpdatesKeepAFollowingTranscriptAtTheBottomWithItsComposerUntouched() throws {
        try runScript(following: true)
    }

    // T6: link chips and the stale footnote next to a transcript. Clicking a chip (PR, ticket, file,
    // URL) and a bound item going badly stale and recovering move neither the divider, the transcript
    // nor the composer, and the tracker does not take focus.

    func testLinkClicksAndStaleFootnotesLeaveAScrolledUpTranscriptUntouched() throws {
        try runScript(following: false, events: TrackerLinkGateScript.events(), label: "links ")
    }

    func testLinkClicksAndStaleFootnotesKeepAFollowingTranscriptAtTheBottom() throws {
        try runScript(following: true, events: TrackerLinkGateScript.events(), label: "links ")
    }

    // T3b: pane edits next to a transcript. A mouse tick or status change, and an editor opened, typed in
    // and saved from a focused composer, move neither the divider, the transcript nor the composer's text
    // and selection; the editor hands focus back to the composer. (A mouse edit puts focus on the pane's
    // sink so ⌘Z undoes it, on purpose: see `TrackerPaneView.focusSink`.)

    private func runEditing(following: Bool) throws {
        let p = try makePane(following: following, editing: true)
        let rig = p.rig
        let pane = p.harness.pane
        let leftFrame = p.left.frame
        let trackerFrame = pane.frame
        let id = try XCTUnwrap(pane.displayedRows.first { row in
            guard let item = row.item, item.isTickable, let view = pane.rowViews[row.key] else { return false }
            let rect = pane.convert(view.bounds, from: view)
            return rect.minY > pane.scrollView.frame.minY + 10 && rect.maxY < pane.bounds.maxY - 10
        }?.item?.id, "a tickable row on screen")

        rig.assertNoMove("mouse tick", following: following, focusMovesOnPurpose: true) { pane.tick(item: id) }
        rig.assertNoMove("mouse status change", following: following, focusMovesOnPurpose: true) {
            pane.setStatus(item: id, to: "blocked")
        }
        rig.focusComposer()
        rig.assertNoMove("title editor opened, typed in and saved", following: following) {
            pane.beginEdit(item: id, kind: .title)
            guard let editor = pane.rowViews["item:\(id)"]?.titleEditor else { return XCTFail("no title editor") }
            (editor.currentEditor() as? NSTextView)?.string = "A title typed at the gate"
            editor.commit()
        }
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "focus returned to the composer")
        XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
        XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection)
        XCTAssertEqual(p.left.frame, leftFrame, "the divider moved (transcript side)")
        XCTAssertEqual(pane.frame, trackerFrame, "the divider moved (tracker side)")
    }

    func testPaneEditsLeaveAScrolledUpTranscriptAndItsComposerUntouched() throws {
        try runEditing(following: false)
    }

    func testPaneEditsKeepAFollowingTranscriptAtTheBottomWithItsComposerUntouched() throws {
        try runEditing(following: true)
    }
}
