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

    // T3b2: add, drag and remove next to a transcript. Dragging a row and dropping it, typing in the "+ Add item"
    // field (open, typed in, sent, answered, closed) and removing an item (the banner appearing, the Undo, the banner
    // going after 10 s) move neither the divider, the transcript nor the composer's text and selection. A drop never
    // takes the keyboard; the add field and a mouse remove take it on purpose and the add field hands it back to the
    // composer when it closes. The only frames the pane sends are the edits asked for (it has no other way to send
    // anything, `focus_layout` included).

    private func runStructure(following: Bool) throws {
        let p = try makePane(following: following, editing: true)
        let rig = p.rig
        let h = p.harness
        let pane = h.pane
        let leftFrame = p.left.frame
        let trackerFrame = pane.frame
        let label = following ? "following" : "scrolled up"

        func isOpen(_ item: TrackerItemRow) -> Bool { item.status == .todo || item.status == .inProgress || item.status == .blocked }
        let viewport = pane.clipView.bounds
        let rows = h.placedRows()
        var triple: [TrackerItemRow] = []
        for i in 0 ..< max(0, rows.count - 2) where triple.isEmpty {
            let items = rows[i ... i + 2].compactMap { placed -> TrackerItemRow? in
                guard case .item(let item) = placed.row.content, placed.key == TrackerRow.itemKey(item.id), isOpen(item),
                      placed.frame.maxY > viewport.minY, placed.frame.minY < viewport.maxY else { return nil }
                return item
            }
            if items.count == 3, Set(items.map(\.sectionId)).count == 1 { triple = items }
        }
        let (a, b, c) = try { () throws -> (TrackerItemRow, TrackerItemRow, TrackerItemRow) in
            guard triple.count == 3 else { throw TrackerGateError("no three neighbouring open items on screen") }
            return (triple[0], triple[1], triple[2])
        }()
        let section = a.sectionId
        var lastOpen: String?
        var inSection = false
        for row in pane.displayedRows {
            if case .section(let heading) = row.content { inSection = heading.id == section }
            if inSection, case .item(let item) = row.content, row.key == TrackerRow.itemKey(item.id), isOpen(item) { lastOpen = item.id }
        }
        let last = try XCTUnwrap(lastOpen, "the section has open items")

        func step(_ name: String, focusMovesOnPurpose: Bool = false, _ event: @escaping () throws -> Void) {
            let full = "\(label) \(name)"
            rig.assertNoMove(full, following: following, focusMovesOnPurpose: focusMovesOnPurpose) {
                do { try event() } catch { XCTFail("\(full): \(error)") }
            }
            XCTAssertEqual(p.left.frame, leftFrame, "\(full): the divider moved (transcript side)")
            XCTAssertEqual(pane.frame, trackerFrame, "\(full): the divider moved (tracker side)")
        }
        func over(_ id: String) throws -> NSPoint {
            let frame = try XCTUnwrap(h.frame(of: TrackerRow.itemKey(id)), "no row for \(id)")
            return NSPoint(x: frame.midX, y: frame.minY + 3)
        }

        // Drag a above c: it lands between b and c.
        let payload = (id: a.id, pane: pane.paneIdentity)
        step("a drag begins") { pane.dragBegan() }
        step("the pointer is over a row, the line shows") {
            XCTAssertEqual(pane.dragMoved(payload: payload, at: try over(c.id)), .move)
            XCTAssertFalse(pane.dropIndicator.isHidden)
        }
        step("the drop (the move is sent)") { XCTAssertTrue(pane.dragDropped(payload: payload, at: try over(c.id))) }
        step("the drag ends") { pane.dragEnded() }
        XCTAssertEqual(h.edits.sent.last?.ops, [.move(id: a.id, section: section, before: nil, after: b.id)], "the drop sent the right move")
        step("the daemon's board with the move, applied at once") { try h.echo { try $0.placeItem(a.id, after: b.id) } }
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "the composer kept the keyboard through the drop")

        // Add: the field opens (it takes the keyboard on purpose), is typed in, sends, is answered, and closes.
        let newID = "gate-structure-new"
        step("the add field opens", focusMovesOnPurpose: true) { pane.beginAdd(section: section) }
        let field = try XCTUnwrap(pane.rowViews[TrackerRow.addKey(section)]?.addField, "the add field is open")
        step("typing in the add field", focusMovesOnPurpose: true) {
            (field.currentEditor() as? NSTextView)?.string = "A title typed at the gate"
        }
        step("Return sends the add; the field waits", focusMovesOnPurpose: true) {
            _ = field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }
        XCTAssertEqual(h.edits.sent.last?.ops,
                       [.add(section: section, title: "A title typed at the gate", body: nil, before: nil, after: last)],
                       "the add went after the section's last open item")
        step("the board with the new row arrives", focusMovesOnPurpose: true) {
            try h.echo(created: [newID]) { try $0.addItem(id: newID, after: last, text: "A title typed at the gate") }
        }
        step("Esc closes the field and the keyboard goes back", focusMovesOnPurpose: true) {
            _ = field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        XCTAssertNil(pane.rowViews[TrackerRow.addKey(section)]?.addField, "the field is closed")
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "focus returned to the composer that had it before")
        XCTAssertEqual(rig.textView.string, SafetyRig.typedText, "the composer's text is intact")
        XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection, "and so is its selection")

        // Remove, with the banner coming, going and being used.
        rig.focusComposer()
        let expire = { h.scheduled.scheduled.filter { $0.delay == TrackerPaneView.removalBannerLifetime }.forEach { $0.work() } }
        step("Remove: the banner appears (a mouse edit takes the pane's keyboard)", focusMovesOnPurpose: true) { pane.removeItem(c.id) }
        XCTAssertEqual(pane.notice.actionButton?.title, "Undo", "the banner offers Undo")
        rig.focusComposer()
        step("the board without the row") { try h.echo { try $0.removeItem(c.id) } }
        step("the banner goes after 10 s") { expire() }
        XCTAssertNil(pane.notice.text, "the banner is gone")
        step("a second Remove, its banner", focusMovesOnPurpose: true) { pane.removeItem(a.id) }
        XCTAssertEqual(pane.notice.actionButton?.title, "Undo")
        rig.focusComposer()
        step("the board without it") { try h.echo { try $0.removeItem(a.id) } }
        step("the banner's Undo sends the restore and the banner goes", focusMovesOnPurpose: true) {
            try XCTUnwrap(pane.notice.actionButton).performClick(nil)
        }
        rig.focusComposer()
        step("the board with the item back") {
            try h.echo(created: [a.id]) { try $0.addItem(id: a.id, after: b.id, text: "Restored at the gate") }
        }
        XCTAssertNil(pane.notice.text)

        // The pane sent the five edits above and nothing else.
        let ops = h.edits.sent.map(\.ops)
        XCTAssertEqual(ops.count, 5, "move, add, remove, remove, restore: \(ops)")
        XCTAssertEqual(ops.dropLast().last?.first, .remove(id: a.id))
        if case .restore(_, let into, _, let after)? = ops.last?.first {
            XCTAssertEqual(into, section)
            XCTAssertEqual(after, b.id)
        } else {
            XCTFail("the last frame was not a restore: \(String(describing: ops.last))")
        }
        XCTAssertEqual(p.left.frame, leftFrame, "the divider did not move (transcript side)")
        XCTAssertEqual(pane.frame, trackerFrame, "the divider did not move (tracker side)")
    }

    func testDragAddAndRemoveLeaveAScrolledUpTranscriptAndItsComposerUntouched() throws {
        try runStructure(following: false)
    }

    func testDragAddAndRemoveKeepAFollowingTranscriptAtTheBottomWithItsComposerUntouched() throws {
        try runStructure(following: true)
    }
}
