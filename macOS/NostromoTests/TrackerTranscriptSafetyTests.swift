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

    private func makePane(following: Bool) throws -> Pane {
        let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
        let window = rig.window
        let content = try XCTUnwrap(window.contentView)
        let top = rig.clip.bounds.minY
        let leftWidth = content.frame.width
        let height = content.frame.height

        let split = NSSplitView(frame: content.frame)
        split.isVertical = true
        split.dividerStyle = .thin
        window.contentView = split
        window.setContentSize(NSSize(width: leftWidth + split.dividerThickness + Self.trackerWidth, height: height))

        let harness = try TrackerGateHarness(self)
        split.addArrangedSubview(content)
        split.addArrangedSubview(harness.pane)
        split.adjustSubviews()
        split.setPosition(leftWidth, ofDividerAt: 0)
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

    private func runScript(following: Bool) throws {
        let p = try makePane(following: following)
        let rig = p.rig
        let tracker = p.harness.pane

        // The setup is what the criterion describes.
        XCTAssertTrue(rig.window.contentView === p.split)
        XCTAssertEqual(p.split.arrangedSubviews.count, 2)
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

        for (i, event) in TrackerGateScript.events().enumerated() {
            let name = "\(following ? "following" : "scrolled up") #\(i + 1) \(event.name)"
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
}
