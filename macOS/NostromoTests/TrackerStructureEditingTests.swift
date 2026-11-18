import XCTest
import AppKit
import Combine
import NostromoKit

// T3b2: the tracker pane adds, moves and removes items (the Mac half). Real `TrackerPaneView`s over the golden
// board, a fake sender that records every `tracker_edit` frame and a fake daemon that answers the way the real one
// does (a new board version, then `tracker_edit_result`), all from `TrackerEditHarness` (TrackerEditingTests.swift).
// Every collaborator is injected: no wall clock (the pane's 10 s banner is the injected `schedule`, the 5 s and 6 s
// edit timers are the harness's `edits` scheduler), no daemon, no UserDefaults, no real pasteboard.
//
// The behaviours, by what the user does:
//  - Add: "+ Add item" (click, or Space) becomes a focused title field; Return creates the item after the section's
//    last open item and keeps the field open and empty; Esc closes it; leaving it with text creates; an 81+ character
//    title keeps every character (title, then body).
//  - Move: by dragging (`dragBegan` / `dragMoved` / `dragDropped` / `dragEnded`, the calls the AppKit drag session
//    makes), by the Move pull-down and context menu, and by VoiceOver's custom actions; every way sends the same `move`.
//  - Remove: no dialog; a banner offers Undo for 10 s; ⌘Z keeps it after; the restore carries the item's exact markdown.
//  - Undo and redo of each, and the rule that the user's own move or removal shows at once while an agent's on-screen
//    move still waits.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Send `after` as the section's last item including done ones, or not at all: the add tests fail.
//  - Close the add field when Return creates (instead of emptying it): the second-item test fails.
//  - Let a refused add clear the typed text: the refusal test fails.
//  - Draw the drop indicator by changing row frames, apply a render during a drag, or accept another pane's drag:
//    the drag tests fail.
//  - Send the destination relative to the dragged item itself: the neighbour tests fail.
//  - Send `restore` with the title instead of the exact `source`, or restore to the section's end: the restore tests fail.
//  - Keep the banner after 10 s, or drop ⌘Z with it: the lifetime test fails.
//  - Hold the user's own move or removal like an agent's: the exempt tests fail.
//  - Drop focus from the Move pull-down when its row is rebuilt: the focus tests fail.
//  - Show an add row to a daemon that cannot take edits: the read-only add-row tests fail.
//  - Put an item back at the place fixed when it was removed (or moved), not worked out against the board now: the
//    undo-place tests fail. Drop the undo entry or the banner when a restore (or a move back) is refused: the refused tests fail.
//  - Send the newest board version instead of the version the held row shows, for a move, a removal or a drop: the held-row tests fail.
//  - Let a drop take the keyboard from the composer: the drop-focus test fails.
//  - Register a new undo (or clear redo) from the banner's Undo of an older removal: the banner-undo test fails.
//  - Offer Remove (button, menu, VoiceOver) or accept `removeItem` under an open editor: the Remove-under-an-editor tests fail.

private typealias Fx = TrackerPaneFx
private typealias Script = TrackerBoardScript

/// Where a restore or a move back is expected to land: beside an item, or at the end of the section.
private enum PlaceExpectation {
    case before(String), after(String), sectionEnd

    var before: String? { if case .before(let id) = self { return id } else { return nil } }
    var after: String? { if case .after(let id) = self { return id } else { return nil } }
}

private let nowIds = ["check-1000", "verif-1037", "retry-1074", "revie-1111", "draft-1148",
                      "close-1185", "repro-1222", "triag-1259", "docum-1296", "backf-1333"]

final class TrackerStructureEditingTests: MouseQueueTestCase {

    // MARK: - Setup and helpers

    private func harness(supported: Bool = true, height: CGFloat = 900,
                         configure: (inout TrackerBoardScript) throws -> Void = { _ in },
                         file: StaticString = #filePath, line: UInt = #line) throws -> TrackerEditHarness {
        try TrackerEditHarness(self, supported: supported, size: NSSize(width: 360, height: height),
                               configure: configure, file: file, line: line)
    }

    private func addRow(_ h: TrackerEditHarness, _ section: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> TrackerRowView {
        try XCTUnwrap(h.pane.rowViews[TrackerRow.addKey(section)],
                      "no add row for \(section); rows: \(h.pane.displayedRows.map(\.key))", file: file, line: line)
    }

    /// Open the add field the way a click does and hand it back.
    private func openAdd(_ h: TrackerEditHarness, _ section: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> (row: TrackerRowView, field: TrackerTitleEditor) {
        let row = try addRow(h, section, file: file, line: line)
        let button = try XCTUnwrap(row.addItemButton, "the add row has its button", file: file, line: line)
        button.performClick(nil)
        let field = try XCTUnwrap(row.addField, "activating the add row opens its field", file: file, line: line)
        return (row, field)
    }

    /// The ids of the open items the pane shows under `section`, top to bottom.
    private func shownIDs(_ h: TrackerEditHarness, in section: String) -> [String] {
        var current = ""
        var ids: [String] = []
        for row in h.pane.displayedRows {
            switch row.content {
            case .section(let heading):
                current = heading.id
            case .item(let item) where row.key == TrackerRow.itemKey(item.id) && current == section && !item.isDone:
                ids.append(item.id)
            default:
                break
            }
        }
        return ids
    }

    private func pending(_ h: TrackerEditHarness) -> [TrackerAnchorSnapshot.Pending] {
        h.pane.anchorSnapshot(windowIndex: 0).pending
    }

    private func newItem(_ id: String, _ section: String, _ text: String) -> Script.Obj {
        Script.newItemNode(id: id, section: section, text: text)
    }

    private func expand(_ h: TrackerEditHarness, _ id: String) {
        if !h.pane.folds.expandedItems.contains(id) { h.pane.toggleNote(item: id) }
    }

    private func removeButton(_ h: TrackerEditHarness, _ id: String,
                              file: StaticString = #filePath, line: UInt = #line) throws -> TrackerChipButton {
        expand(h, id)
        return try XCTUnwrap(try h.row(id, file: file, line: line).removeButton, "the expanded row has Remove", file: file, line: line)
    }

    private func payload(_ h: TrackerEditHarness, _ id: String) -> (id: String, pane: String) {
        (id: id, pane: h.pane.paneIdentity)
    }

    /// A point in the row's upper or lower half, in the document's coordinates (where the drag session reports it).
    private func point(_ h: TrackerEditHarness, over key: String, lower: Bool,
                       file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let frame = try XCTUnwrap(h.pane.rowViews[key]?.frame, "no row \(key) to drop on", file: file, line: line)
        return NSPoint(x: frame.midX, y: lower ? frame.maxY - 3 : frame.minY + 3)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1))
    }

    private func removedBanner(_ title: String) -> String { "Removed “\(title)”. Undo" }

    /// The daemon applies the user's removal of `id`.
    private func echoRemoval(_ h: TrackerEditHarness, _ id: String, resultFirst: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        try h.echo({ try $0.removeItem(id) }, resultFirst: resultFirst, file: file, line: line)
    }

    // MARK: - Add: opening the field

    func testClickingAddItemOpensAFocusedFieldInPlaceAtTheSameHeight() throws {
        let h = try harness()
        let row = try addRow(h, "now")
        let button = try XCTUnwrap(row.addItemButton)
        XCTAssertEqual(button.title, "+ Add item")
        XCTAssertEqual(button.accessibilityLabel(), "Add item to Now", "VoiceOver says which section it adds to")
        XCTAssertNil(row.addField)
        let heightBefore = row.frame.height

        button.performClick(nil)
        h.rig.settle()

        let field = try XCTUnwrap(row.addField, "the row became a title field")
        XCTAssertNotNil(field.currentEditor(), "the field is being edited")
        XCTAssertTrue(h.window.firstResponder === field.currentEditor(), "and has keyboard focus")
        XCTAssertTrue(h.sent.isEmpty, "opening the field sends nothing")
        XCTAssertEqual(row.height(forWidth: row.frame.width), heightBefore, accuracy: 0.01, "the row keeps its height")
        XCTAssertEqual(row.frame.height, heightBefore, accuracy: 0.01)
        XCTAssertTrue(button.isHidden, "the label is replaced by the field, not drawn under it")
        XCTAssertEqual(field.frame.height, TrackerRowView.addLineHeight, accuracy: 0.01)
        XCTAssertEqual(field.frame.minX, TrackerRowView.textX, accuracy: 0.01, "it starts where the titles start")
        XCTAssertEqual(h.pane.addSessions.keys.sorted(), ["now"])
    }

    func testSpaceOnTheFocusedAddRowOpensTheFieldAndReturnCreatesTheItemWithoutTheMouse() throws {
        let h = try harness()
        let row = try addRow(h, "next")
        let button = try XCTUnwrap(row.addItemButton)
        XCTAssertEqual(button.refusesFirstResponder, false, "reachable with Full Keyboard Access")
        XCTAssertTrue(h.window.makeFirstResponder(button))
        button.performClick(nil)    // what Space does on a focused button

        let field = try XCTUnwrap(row.addField)
        XCTAssertTrue(row.addFieldOwnsFocus, "typing goes straight into the field")
        h.type("Keyboard only", into: field)
        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.map(\.ops), [[.add(section: "next", title: "Keyboard only", body: nil, before: nil, after: "triag-1703")]])
        XCTAssertEqual(h.sent.first?.base, 7, "against the board the user was looking at")
    }

    // MARK: - Add: creating

    func testReturnSendsAnAddAfterTheSectionsLastOpenItemAndTheFieldStaysOpenAndEmptyForTheNext() throws {
        let h = try harness()
        let (row, field) = try openAdd(h, "now")
        h.type("Brand new item", into: field)
        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.map(\.ops), [[.add(section: "now", title: "Brand new item", body: nil, before: nil, after: "backf-1333")]],
                       "after the last open item of Now, with the title as typed and no body")
        XCTAssertEqual(h.sent.first?.base, 7)
        XCTAssertFalse(field.isEditable, "read-only while the item is being created")
        XCTAssertEqual(field.alphaValue, 0.5, accuracy: 0.01, "and dimmed")
        XCTAssertEqual(field.stringValue, "Brand new item", "still showing what was sent")
        XCTAssertNil(h.pane.rowViews["item:brand-0001"], "no optimistic row: the board has not got it yet")

        try h.echo({ try $0.insert(self.newItem("brand-0001", "now", "Brand new item"), section: "now", after: "backf-1333") },
                   created: ["brand-0001"])
        XCTAssertEqual(shownIDs(h, in: "now").last, "brand-0001", "the board's item is now the last of Now")
        XCTAssertTrue(row.addField === field, "the same field is still open")
        XCTAssertEqual(row.addFieldText, "", "and empty")
        XCTAssertTrue(field.isEditable)
        XCTAssertEqual(field.alphaValue, 1, accuracy: 0.01)
        XCTAssertTrue(row.addFieldOwnsFocus, "with focus still in it, ready for a second item")
        XCTAssertTrue(h.window.firstResponder === field.currentEditor())

        h.type("Second item", into: field)
        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.last?.ops, [.add(section: "now", title: "Second item", body: nil, before: nil, after: "brand-0001")],
                       "the second item goes after the first one")
        XCTAssertEqual(h.sent.last?.base, 8)
        try h.echo({ try $0.insert(self.newItem("brand-0002", "now", "Second item"), section: "now", after: "brand-0001") },
                   resultFirst: true, created: ["brand-0002"])
        XCTAssertEqual(Array(shownIDs(h, in: "now").suffix(2)), ["brand-0001", "brand-0002"])
        XCTAssertEqual(row.addFieldText, "", "empty again, whichever of the result and the board came first")
        XCTAssertTrue(row.addFieldOwnsFocus)
    }

    func testAnAddInOneSectionDoesNotTouchAnotherSectionsRowOrField() throws {
        let h = try harness()
        let other = try addRow(h, "next")
        let (_, field) = try openAdd(h, "now")
        h.type("Only for Now", into: field)
        h.pressReturn(in: field)
        XCTAssertNil(other.addField, "Next's add row is untouched")
        XCTAssertEqual(h.pane.addSessions.keys.sorted(), ["now"])
    }

    func testEscapeClosesTheFieldAndSendsNothingWhetherOrNotTextWasTyped() throws {
        let cases: [String?] = [nil, "never mind"]
        for typed in cases {
            let h = try harness()
            let (row, field) = try openAdd(h, "now")
            let heightBefore = row.frame.height
            if let typed { h.type(typed, into: field) }
            h.pressEscape(in: field)
            XCTAssertTrue(h.sent.isEmpty, "Esc sends nothing (typed \(typed ?? "nothing"))")
            XCTAssertNil(row.addField, "the field is closed")
            XCTAssertTrue(h.pane.addSessions.isEmpty)
            let button = try XCTUnwrap(row.addItemButton, "the row is the add row again")
            XCTAssertFalse(button.isHidden)
            XCTAssertEqual(row.frame.height, heightBefore, accuracy: 0.01)

            button.performClick(nil)
            let again = try XCTUnwrap(row.addField, "it can be opened again")
            XCTAssertEqual(row.addFieldText, "", "empty: the cancelled text did not come back")
            _ = again
        }
    }

    func testReturnOnAnEmptyOrBlankFieldSendsNothingAndKeepsTheFieldOpen() throws {
        let h = try harness()
        let (row, field) = try openAdd(h, "now")
        h.pressReturn(in: field)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertTrue(row.addField === field, "still open")
        h.type("   \n  ", into: field)
        h.pressReturn(in: field)
        XCTAssertTrue(h.sent.isEmpty, "blanks are nothing")
        XCTAssertTrue(row.addField === field)

        h.type("Now a real one", into: field)
        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.last?.ops, [.add(section: "now", title: "Now a real one", body: nil, before: nil, after: "backf-1333")],
                       "the field still works after the empty Returns")
    }

    func testLeavingTheFieldWithTextCreatesTheItemThenTheFieldClosesAndFocusStaysWhereTheUserPutIt() throws {
        let h = try harness()
        h.window.makeFirstResponder(h.rig.composer)
        let composerEditor = try XCTUnwrap(h.rig.composer.currentEditor() as? NSTextView)
        composerEditor.string = "half-written message"
        let (row, field) = try openAdd(h, "now")
        h.type("Typed, then clicked away", into: field)

        h.window.makeFirstResponder(h.rig.composer)
        XCTAssertEqual(h.sent.map(\.ops), [[.add(section: "now", title: "Typed, then clicked away", body: nil, before: nil, after: "backf-1333")]],
                       "nothing typed is silently dropped")
        try h.echo({ try $0.insert(self.newItem("brand-0001", "now", "Typed, then clicked away"), section: "now", after: "backf-1333") },
                   created: ["brand-0001"])
        XCTAssertNil(row.addField, "focus left, so the field closes once its item is on the board (Return keeps it open)")
        XCTAssertTrue(h.pane.addSessions.isEmpty)
        XCTAssertNotNil(h.rig.composer.currentEditor(), "the composer has focus")
        XCTAssertTrue(h.window.firstResponder === h.rig.composer.currentEditor(), "focus did not jump back into the pane")
        XCTAssertEqual(h.rig.composer.stringValue, "half-written message")
    }

    func testLeavingAnEmptyFieldClosesItAndSendsNothing() throws {
        let h = try harness()
        h.window.makeFirstResponder(h.rig.composer)
        let (row, field) = try openAdd(h, "now")
        h.type("  ", into: field)
        h.window.makeFirstResponder(h.rig.composer)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertNil(row.addField, "an unused field does not linger")
        XCTAssertTrue(h.pane.addSessions.isEmpty)
    }

    func testEscapeGivesFocusBackToTheComposerThatHadItBeforeTheFieldOpened() throws {
        let h = try harness()
        h.window.makeFirstResponder(h.rig.composer)
        let composerEditor = try XCTUnwrap(h.rig.composer.currentEditor() as? NSTextView)
        composerEditor.string = "half-written message"
        let (_, field) = try openAdd(h, "now")
        XCTAssertFalse(h.window.firstResponder === h.rig.composer.currentEditor(), "setup: the field took focus")
        h.pressEscape(in: field)
        XCTAssertNotNil(h.rig.composer.currentEditor(), "the composer has focus again")
        XCTAssertTrue(h.window.firstResponder === h.rig.composer.currentEditor())
        XCTAssertEqual(h.rig.composer.stringValue, "half-written message")
    }

    func testATitleOverEightyCharactersKeepsEveryCharacterAsTitleThenBody() throws {
        let h = try harness()
        let (_, field) = try openAdd(h, "now")
        let typed = (1...20).map { "word\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(typed.count, 80, "setup")
        h.type(typed, into: field)
        h.pressReturn(in: field)
        guard case .add(let section, let title, let body, let before, let after)? = h.sent.last?.ops.first else {
            return XCTFail("no add was sent: \(h.sent)")
        }
        XCTAssertEqual(h.sent.last?.ops.count, 1)
        XCTAssertEqual(section, "now")
        XCTAssertNil(before)
        XCTAssertEqual(after, "backf-1333")
        XCTAssertFalse(title.isEmpty)
        XCTAssertLessThanOrEqual(title.unicodeScalars.count, 80, "the daemon refuses a longer title")
        XCTAssertNotNil(body, "the rest goes in the body")
        XCTAssertEqual([title, body ?? ""].joined(separator: " "), typed, "a long paste is neither cut nor refused")
    }

    func testARefusedAddKeepsTheTypedTextSaysWhyAndCanBeSentAgain() throws {
        let h = try harness()
        let (row, field) = try openAdd(h, "now")
        h.type("keep my words", into: field)
        h.pressReturn(in: field)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_unreadable", "reason": "line 42"])
        XCTAssertTrue(row.addField === field, "the field stays")
        XCTAssertTrue(field.isEditable, "editable again")
        XCTAssertEqual(field.typed, "keep my words", "the text is intact")
        XCTAssertEqual(h.pane.notice.text, "Not saved: the board file can't be read (line 42).")

        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.count, 2, "Return tries again")
        XCTAssertEqual(h.sent.last?.ops, [.add(section: "now", title: "keep my words", body: nil, before: nil, after: "backf-1333")])
    }

    func testAnAgentAddingAnItemToTheSectionNeverRebuildsTheOpenFieldAndTheNextItemGoesAfterIt() throws {
        let h = try harness()
        let (row, field) = try openAdd(h, "now")
        h.type("half-typed", into: field)
        let before = row.frame.minY
        try h.agentChange { try $0.insert(self.newItem("agent-0001", "now", "Agent's item"), section: "now", after: "backf-1333") }
        XCTAssertTrue(h.pane.rowViews["add:now"] === row, "the add row is the same view")
        XCTAssertTrue(row.addField === field, "and its field is still open")
        XCTAssertEqual(field.typed, "half-typed", "the typed text is untouched")
        XCTAssertTrue(row.addFieldOwnsFocus)
        XCTAssertGreaterThan(row.frame.minY, before, "the row moved down for the new item")

        h.pressReturn(in: field)
        XCTAssertEqual(h.sent.last?.ops, [.add(section: "now", title: "half-typed", body: nil, before: nil, after: "agent-0001")],
                       "it goes after the section's last item as the pane shows it now")
    }

    // MARK: - Add: where the row exists

    func testNoAddRowUnderWaitingDoneOrABannerAndOneUnderEverySectionUnderAllAndOpen() throws {
        let h = try harness()
        func addKeys() -> [String] { h.pane.displayedRows.map(\.key).filter { $0.hasPrefix("add:") } }
        XCTAssertEqual(addKeys(), ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"].map { "add:\($0)" })
        XCTAssertEqual(h.pane.showReport()["add_rows"] as? [String], ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"])
        h.pane.setFilter(.open)
        XCTAssertEqual(addKeys(), ["now", "next", "waiting-on-you", "findings", "loose-ends"].map { "add:\($0)" })
        h.pane.setFilter(.waiting)
        XCTAssertEqual(addKeys(), [], "no add row under Waiting on you")
        XCTAssertTrue(h.pane.rowViews.keys.allSatisfy { !$0.hasPrefix("add:") }, "and no row view for one")
        h.pane.setFilter(.done)
        XCTAssertEqual(addKeys(), [], "no add row under Done")
        h.pane.setFilter(.all)
        XCTAssertEqual(addKeys().count, 6)
        try h.agentChange { $0.setBanner(["type": "missing"]) }
        XCTAssertEqual(addKeys(), [], "none when the board cannot be read")
        XCTAssertEqual(h.pane.showReport()["add_rows"] as? [String], [])
    }

    func testAReadOnlyPaneNeverOpensAFieldOrSendsAnything() throws {
        let h = try harness(supported: false)
        if let button = h.pane.rowViews["add:now"]?.addItemButton { button.performClick(nil) }
        h.pane.beginAdd(section: "now")
        XCTAssertNil(h.pane.rowViews["add:now"]?.addField, "no field without tracker_edit_v1")
        XCTAssertTrue(h.pane.addSessions.isEmpty)
        XCTAssertTrue(h.sent.isEmpty)
        h.pane.moveItem("verif-1037", .down)
        h.pane.removeItem("verif-1037")
        XCTAssertTrue(h.sent.isEmpty, "no move or remove either")
        XCTAssertNil(h.pane.notice.spokenText)
        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"), at: try point(h, over: "item:draft-1148", lower: false)), [],
                       "nothing accepts a drag")
        XCTAssertFalse(h.pane.dragDropped(payload: payload(h, "verif-1037"), at: try point(h, over: "item:draft-1148", lower: false)))
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: - Add: undo and redo

    func testCommandZOfAnAddRemovesTheCreatedItemAndRedoPutsItBackExactly() throws {
        let h = try harness()
        let (_, field) = try openAdd(h, "now")
        h.type("Brand new item", into: field)
        h.pressReturn(in: field)
        let node = newItem("brand-0001", "now", "Brand new item")
        try h.echo({ try $0.insert(node, section: "now", after: "backf-1333") }, created: ["brand-0001"])
        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Add Item")

        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: "brand-0001")], "undo removes the item the daemon created")
        XCTAssertEqual(h.sent.last?.base, 8, "against the board the user sees now")
        XCTAssertNil(h.pane.notice.spokenText, "no Removed banner for an undo")
        try echoRemoval(h, "brand-0001")
        XCTAssertNil(h.pane.rowViews["item:brand-0001"])

        h.pane.performRedo()
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: try XCTUnwrap(node["source"] as? String), section: "now", before: nil, after: "backf-1333")],
                       "redo brings back the same markdown after the same item")
    }

    // MARK: - Move by dragging

    func testDraggingAnItemBetweenTwoOthersInItsSectionSendsAMoveAfterTheUpperOneAndDrawsALineOnTheSeam() throws {
        let h = try harness()
        let id = "verif-1037"
        let frames = h.rig.rowFrames
        h.pane.dragBegan()
        let over = try point(h, over: "item:draft-1148", lower: false)
        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, id), at: over), .move)
        XCTAssertFalse(h.pane.dropIndicator.isHidden, "the line is showing")
        let seam = try XCTUnwrap(h.pane.rowViews["item:draft-1148"]).frame.minY
        XCTAssertEqual(h.pane.dropIndicator.frame.midY, seam, accuracy: 0.5, "on the seam between the two rows")
        XCTAssertEqual(h.pane.dropIndicator.frame.height, TrackerDropIndicatorView.thickness, accuracy: 0.01)
        XCTAssertEqual(h.rig.rowFrames, frames, "drawing the line moves no row")

        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, id), at: over))
        XCTAssertEqual(h.sent.map(\.ops), [[.move(id: id, section: "now", before: nil, after: "revie-1111")]])
        XCTAssertEqual(h.sent.first?.base, 7)
        XCTAssertTrue(h.pane.dropIndicator.isHidden, "the line goes with the drop")
        h.pane.dragEnded()
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds, "no optimistic display: the board decides")
    }

    func testDraggingToTheTopOfASectionAndBelowItsLastItemSendsBeforeAndAfter() throws {
        let h = try harness()
        h.pane.dragBegan()
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, "verif-1037"), at: try point(h, over: "item:check-1000", lower: false)))
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "verif-1037", section: "now", before: "check-1000", after: nil)])
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, "verif-1037"), at: try point(h, over: "item:backf-1333", lower: true)))
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "verif-1037", section: "now", before: nil, after: "backf-1333")])
        h.pane.dragEnded()
    }

    func testDraggingAnItemToAnotherSectionLandsBesideTheRowUnderThePointer() throws {
        let h = try harness()
        let id = "verif-1037"
        h.pane.dragBegan()
        let over = try point(h, over: "item:audit-1407", lower: true)
        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, id), at: over), .move)
        let seam = try XCTUnwrap(h.pane.rowViews["item:audit-1407"]).frame.maxY
        XCTAssertEqual(h.pane.dropIndicator.frame.midY, seam, accuracy: 0.5, "under the row the pointer is in the lower half of")
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, id), at: over))
        XCTAssertEqual(h.sent.map(\.ops), [[.move(id: id, section: "next", before: nil, after: "audit-1407")]])
        h.pane.dragEnded()
    }

    func testDroppingOnASectionHeadingOrItsAddRowMovesToTheEndOfThatSectionWithTheLineAboveTheAddRow() throws {
        for key in ["section:next", "add:next"] {
            let h = try harness()
            let id = "verif-1037"
            h.pane.dragBegan()
            let over = try point(h, over: key, lower: false)
            XCTAssertEqual(h.pane.dragMoved(payload: payload(h, id), at: over), .move, key)
            let add = try XCTUnwrap(h.pane.rowViews["add:next"]).frame.minY
            XCTAssertEqual(h.pane.dropIndicator.frame.midY, add, accuracy: 0.5, "\(key): the line sits on top of Next's add row")
            XCTAssertTrue(h.pane.dragDropped(payload: payload(h, id), at: over), key)
            XCTAssertEqual(h.sent.map(\.ops), [[.move(id: id, section: "next", before: nil, after: nil)]], key)
            h.pane.dragEnded()
        }
    }

    func testADropOnTheDoneGroupOnItselfOrIntoItsOwnSlotIsRefusedAndSendsNothing() throws {
        let h = try harness()
        let id = "verif-1037"
        let places: [(String, String, Bool)] = [
            ("the Done group", "done:findings", false),
            ("itself, upper half", "item:verif-1037", false),
            ("itself, lower half", "item:verif-1037", true),
            ("the seam under the item above", "item:check-1000", true),
            ("the seam above the item below", "item:retry-1074", false),
        ]
        h.pane.dragBegan()
        for (name, key, lower) in places {
            let over = try point(h, over: key, lower: lower)
            XCTAssertEqual(h.pane.dragMoved(payload: payload(h, id), at: over), [], "\(name): not a place to drop")
            XCTAssertTrue(h.pane.dropIndicator.isHidden, "\(name): no line")
            XCTAssertFalse(h.pane.dragDropped(payload: payload(h, id), at: over), "\(name): the drop is refused")
        }
        XCTAssertTrue(h.sent.isEmpty, "nothing was sent for any of them")
        h.pane.dragEnded()
    }

    func testADragFromAnotherPaneOrOfAnItemTheViewDoesNotShowIsRefused() throws {
        let h = try harness()
        let over = try point(h, over: "item:draft-1148", lower: false)
        let foreign = (id: "verif-1037", pane: "some-other-pane")
        h.pane.dragBegan()
        XCTAssertEqual(h.pane.dragMoved(payload: foreign, at: over), [], "another pane's drag is not accepted")
        XCTAssertTrue(h.pane.dropIndicator.isHidden)
        XCTAssertFalse(h.pane.dragDropped(payload: foreign, at: over))
        let stale = (id: "nobody-0000", pane: h.pane.paneIdentity)
        XCTAssertEqual(h.pane.dragMoved(payload: stale, at: over), [])
        XCTAssertFalse(h.pane.dragDropped(payload: stale, at: over))
        XCTAssertTrue(h.sent.isEmpty)
        h.pane.dragEnded()
    }

    func testTheLineGoesWhenThePointerLeavesAnAcceptingRowOrTheDragEndsWithoutADrop() throws {
        let h = try harness()
        h.pane.dragBegan()
        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"), at: try point(h, over: "item:draft-1148", lower: false)), .move)
        XCTAssertFalse(h.pane.dropIndicator.isHidden)
        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"), at: try point(h, over: "done:findings", lower: false)), [])
        XCTAssertTrue(h.pane.dropIndicator.isHidden, "over a row that refuses it, no line")

        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"), at: try point(h, over: "item:draft-1148", lower: false)), .move)
        h.pane.dragExited()
        XCTAssertTrue(h.pane.dropIndicator.isHidden, "leaving the pane hides it")

        XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"), at: try point(h, over: "item:draft-1148", lower: false)), .move)
        h.pane.dragEnded()
        XCTAssertTrue(h.pane.dropIndicator.isHidden, "a drag that ends anywhere ends the line")
        XCTAssertFalse(h.pane.isDragging)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testNothingOnScreenChangesWhileARowIsBeingDraggedAndTheBoardShowsWhenItEnds() throws {
        let h = try harness()
        h.rig.push(h.script)    // an identical board changes no row: a baseline of 0
        XCTAssertEqual(h.pane.rowsUpdatedLast, 0, "setup")
        let frames = h.rig.rowFrames
        let generation = h.pane.renderGeneration

        h.pane.dragBegan()
        XCTAssertTrue(h.pane.isDragging)
        XCTAssertEqual(h.pane.showReport()["dragging"] as? Bool, true)
        try h.agentChange { script in
            try script.setStatus("revie-1111", "blocked")
            try script.insert(self.newItem("agent-0001", "now", "Agent's item"), section: "now", after: "check-1000")
            try script.removeItem("close-1185")
        }
        XCTAssertEqual(h.pane.rowsUpdatedLast, 0, "no row was built or updated during the drag")
        XCTAssertEqual(h.pane.renderGeneration, generation, "nothing was rendered")
        XCTAssertEqual(h.rig.rowFrames, frames, "no row moved or changed size")
        XCTAssertEqual(try h.row("revie-1111").row.item?.status, .todo, "still the content the user was dragging among")
        XCTAssertNotNil(h.pane.rowViews["item:close-1185"], "the removed row is still there")
        XCTAssertNil(h.pane.rowViews["item:agent-0001"], "the new row is not there yet")

        h.pane.dragEnded()
        XCTAssertFalse(h.pane.isDragging)
        XCTAssertEqual(h.pane.showReport()["dragging"] as? Bool, false)
        XCTAssertEqual(try h.row("revie-1111").row.item?.status, .blocked, "the board shows as soon as the drag ends")
        XCTAssertNotNil(h.pane.rowViews["item:agent-0001"])
        XCTAssertGreaterThan(h.pane.rowsUpdatedLast, 0)
    }

    func testTheDaemonsAnswerToADropThatArrivesBeforeTheDragEndsIsShownWhenItEnds() throws {
        let h = try harness()
        let id = "verif-1037"
        h.pane.dragBegan()
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, id), at: try point(h, over: "item:draft-1148", lower: false)))
        try h.echo { try $0.place(id, section: "now", after: "revie-1111") }
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds, "the board is held while the session is still open")
        h.pane.dragEnded()
        XCTAssertEqual(shownIDs(h, in: "now"), ["check-1000", "retry-1074", "revie-1111", "verif-1037"] + Array(nowIds.suffix(6)),
                       "and shown the moment it ends")
    }

    func testThePanesDragPayloadRoundTripsThroughThePasteboardAndOtherDataIsNotOne() throws {
        let pasteboard = rigPrivatePasteboard(self)
        pasteboard.clearContents()
        pasteboard.setData(try JSONSerialization.data(withJSONObject: ["id": "verif-1037", "pane": "p-1"]),
                           forType: TrackerRowView.dragType)
        let payload = try XCTUnwrap(TrackerRowView.dragPayload(pasteboard))
        XCTAssertEqual(payload.id, "verif-1037")
        XCTAssertEqual(payload.pane, "p-1")

        pasteboard.clearContents()
        pasteboard.setString("verif-1037", forType: .string)
        XCTAssertNil(TrackerRowView.dragPayload(pasteboard), "plain text is not a tracker item")
        pasteboard.clearContents()
        pasteboard.setData(try JSONSerialization.data(withJSONObject: ["id": "verif-1037"]), forType: TrackerRowView.dragType)
        XCTAssertNil(TrackerRowView.dragPayload(pasteboard), "a payload that does not name its pane is refused")
        pasteboard.clearContents()
        pasteboard.setData(Data("not json".utf8), forType: TrackerRowView.dragType)
        XCTAssertNil(TrackerRowView.dragPayload(pasteboard))

        let h = try harness()
        XCTAssertTrue(h.pane.documentView.registeredDraggedTypes.contains(TrackerRowView.dragType),
                      "the document takes tracker item drops")
    }

    func testAPressThatBarelyMovesIsNotADragAndAnEditorOrStubOrReadOnlyRowCannotBeDragged() throws {
        let h = try harness()
        let row = try h.row("verif-1037")
        var began = 0
        row.onDragBegan = { began += 1 }
        let start = row.convert(NSPoint(x: 100, y: 10), to: nil)
        row.pressBegan(try mouse(.leftMouseDown, at: start, in: h.window))
        XCTAssertFalse(row.trackDrag(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y), in: h.window)),
                       "3 pt or less is still a click")
        XCTAssertEqual(began, 0)

        // A row with an open title editor is for typing in.
        h.pane.beginEdit(item: "revie-1111", kind: .title)
        let editing = try h.row("revie-1111")
        editing.onDragBegan = { began += 1 }
        editing.pressBegan(try mouse(.leftMouseDown, at: start, in: h.window))
        XCTAssertFalse(editing.trackDrag(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: h.window)))

        // A stub is not an item the user can move.
        try h.agentChange { try $0.removeItem("close-1185") }
        let stub = try XCTUnwrap(h.pane.rowViews["item:close-1185"])
        guard case .stub = stub.row.content else { return XCTFail("setup: an agent's removal of an on-screen item leaves a stub") }
        stub.onDragBegan = { began += 1 }
        stub.pressBegan(try mouse(.leftMouseDown, at: start, in: h.window))
        XCTAssertFalse(stub.trackDrag(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: h.window)))

        // A read-only pane's rows have no drag at all.
        let readOnly = try harness(supported: false)
        let plain = try readOnly.row("verif-1037")
        plain.onDragBegan = { began += 1 }
        plain.pressBegan(try mouse(.leftMouseDown, at: start, in: readOnly.window))
        XCTAssertFalse(plain.trackDrag(try mouse(.leftMouseDragged, at: NSPoint(x: start.x + 40, y: start.y), in: readOnly.window)))
        XCTAssertEqual(began, 0, "no drag began for any of them")
    }

    func testAClickOnTheTickWithAWobbleStillTicksAndAReleaseOutsideDoesNot() throws {
        let h = try harness()
        let tick = try XCTUnwrap(try h.row("revie-1111").tickButton)
        let centre = tick.convert(NSPoint(x: tick.bounds.midX, y: tick.bounds.midY), to: nil)
        tick.mouseDown(with: try mouse(.leftMouseDown, at: centre, in: h.window))
        tick.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: centre.x + 2, y: centre.y), in: h.window))
        tick.mouseUp(with: try mouse(.leftMouseUp, at: centre, in: h.window))
        XCTAssertEqual(h.sent.map(\.ops), [[.status(id: "revie-1111", status: "done")]], "a click that wobbles 2 pt is a click")

        let again = try XCTUnwrap(try h.row("verif-1037").tickButton)
        let there = again.convert(NSPoint(x: again.bounds.midX, y: again.bounds.midY), to: nil)
        again.mouseDown(with: try mouse(.leftMouseDown, at: there, in: h.window))
        again.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: there.x + 200, y: there.y), in: h.window))
        XCTAssertEqual(h.sent.count, 1, "releasing away from the tick cancels the click")
    }

    func testAClickOnARowsTimeIsAClickOnTheRowSoADragCanStartThere() throws {
        let h = try harness()
        let row = try h.row("verif-1037")
        let time = try XCTUnwrap(row.timeLabel)
        let inSuperview = row.convert(NSPoint(x: time.frame.midX, y: time.frame.midY), to: row.superview)
        XCTAssertTrue(row.hitTest(inSuperview) === row, "the time label is part of the row, not a view of its own")
    }

    // MARK: - Move by menu, pull-down and VoiceOver

    private func moveMenuItems(_ row: TrackerRowView, file: StaticString = #filePath, line: UInt = #line) throws -> [NSMenuItem] {
        let menu = try XCTUnwrap(row.movePopUp?.menu, "the expanded row has a Move pull-down", file: file, line: line)
        row.menuNeedsUpdate(menu)
        return Array(menu.items.dropFirst())
    }

    func testTheMovePullDownOffersUpDownAndEveryOtherSectionAndDisablesWhatWouldDoNothing() throws {
        let h = try harness { try $0.setNote("backf-1333", paragraphs: ["a note so the last item can open"]) }
        expand(h, "check-1000")
        expand(h, "backf-1333")
        let all = ["Move Up", "Move Down", "Move to Next", "Move to Waiting on you", "Move to Done", "Move to Findings", "Move to Loose ends"]

        let first = try moveMenuItems(try h.row("check-1000"))
        XCTAssertEqual(first.filter { !$0.isSeparatorItem }.map(\.title), all)
        XCTAssertEqual(first.first { $0.title == "Move Up" }?.isEnabled, false, "nothing above the first item")
        XCTAssertEqual(first.first { $0.title == "Move Down" }?.isEnabled, true)
        XCTAssertTrue(first.filter { $0.title.hasPrefix("Move to") }.allSatisfy(\.isEnabled))

        let last = try moveMenuItems(try h.row("backf-1333"))
        XCTAssertEqual(last.first { $0.title == "Move Up" }?.isEnabled, true)
        XCTAssertEqual(last.first { $0.title == "Move Down" }?.isEnabled, false, "nothing below the last item")
        XCTAssertEqual(try h.row("check-1000").movePopUp?.accessibilityLabel(), "Move: Check referral 4411 duplicate")
        XCTAssertEqual(try h.row("check-1000").removeButton?.accessibilityLabel(), "Remove: Check referral 4411 duplicate")
    }

    func testEachMoveChoiceOfThePullDownSendsTheMatchingMoveAndFocusStaysOnThePullDown() throws {
        let h = try harness()
        let id = "draft-1148"
        expand(h, id)

        func choose(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let row = try h.row(id, file: file, line: line)
            let pop = try XCTUnwrap(row.movePopUp, file: file, line: line)
            XCTAssertTrue(h.window.makeFirstResponder(pop), "the pull-down takes keyboard focus", file: file, line: line)
            let item = try XCTUnwrap(try moveMenuItems(row, file: file, line: line).first { $0.title == title },
                                     "no menu item \(title)", file: file, line: line)
            Fx.invoke(item, file: file, line: line)
        }
        func assertFocusOnThePullDown(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let row = try h.row(id, file: file, line: line)
            XCTAssertNotNil(row.movePopUp, "\(message): the row is still expanded with its Move", file: file, line: line)
            XCTAssertTrue(h.window.firstResponder === row.movePopUp, "\(message): focus is on that row's Move pull-down, got \(String(describing: h.window.firstResponder))",
                          file: file, line: line)
        }

        try choose("Move Up")
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: "revie-1111", after: nil)])
        XCTAssertEqual(h.sent.last?.base, 7)
        try h.echo { try $0.place(id, section: "now", before: "revie-1111") }
        try assertFocusOnThePullDown("after Move Up")

        try choose("Move Down")
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "revie-1111")],
                       "draft-1148 is above revie-1111 now: down is after the item below it")
        try h.echo { try $0.place(id, section: "now", after: "revie-1111") }
        try assertFocusOnThePullDown("after Move Down")

        try choose("Move to Findings")
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "findings", before: nil, after: nil)])
        try h.echo { try $0.place(id, section: "findings") }
        XCTAssertEqual(try h.row(id).row.item?.sectionId, "findings", "the row shows in Findings")
        try assertFocusOnThePullDown("after Move to Findings (a different section's rebuilt row)")
    }

    func testThePullDownIsRefreshedWhenItOpensSoItFollowsTheNeighboursNow() throws {
        // Findings is off screen at the top of the board, so an agent's reorder there applies at once.
        let h = try harness(height: 500) { try $0.setNote("repro-2554", paragraphs: ["a note so the row can open"]) }
        expand(h, "repro-2554")
        XCTAssertFalse(h.pane.visibleKeys().contains("item:repro-2554"), "setup: off screen")
        XCTAssertEqual(try moveMenuItems(try h.row("repro-2554")).first { $0.title == "Move Up" }?.isEnabled, false,
                       "the first open item of Findings")
        try h.agentChange { try $0.place("rotat-2702", section: "findings", before: "repro-2554") }
        XCTAssertEqual(try moveMenuItems(try h.row("repro-2554")).first { $0.title == "Move Up" }?.isEnabled, true,
                       "something is above it now: opening the pull-down says so")
    }

    func testTheContextMenuHasAMoveSubmenuAndRemoveAndEachDoesWhatItSays() throws {
        let h = try harness()
        let row = try h.row("draft-1148")
        let items = row.editMenuItems()
        XCTAssertEqual(items.map(\.title), ["Edit Title", "Edit Details", "Status", "Move", "Remove"])
        let move = try XCTUnwrap(items.first { $0.title == "Move" }?.submenu)
        XCTAssertEqual(move.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Move Up", "Move Down", "Move to Next", "Move to Waiting on you", "Move to Done", "Move to Findings", "Move to Loose ends"])
        Fx.invoke(try XCTUnwrap(move.items.first { $0.title == "Move to Next" }))
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "draft-1148", section: "next", before: nil, after: nil)])
        Fx.invoke(try XCTUnwrap(items.first { $0.title == "Remove" }))
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: "draft-1148")])
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Draft search index"))

        let readOnly = try harness(supported: false)
        XCTAssertEqual(try readOnly.row("draft-1148").menuItems().map(\.title), ["Copy as Markdown"], "no Move or Remove without the features")
    }

    func testVoiceOverOffersMoveUpDownEachOtherSectionAndRemoveAndEachDoesIt() throws {
        let h = try harness()
        func names(_ id: String) throws -> [String] {
            let tick = try XCTUnwrap(try h.row(id).tickButton)
            return (tick.accessibilityCustomActions() ?? []).map(\.name).filter { $0.hasPrefix("Move") || $0 == "Remove" }
        }
        let sections = ["Move to Next", "Move to Waiting on you", "Move to Done", "Move to Findings", "Move to Loose ends"]
        XCTAssertEqual(try names("draft-1148"), ["Move up", "Move down"] + sections + ["Remove"])
        XCTAssertEqual(try names("check-1000"), ["Move down"] + sections + ["Remove"], "no Move up on the first item")
        XCTAssertEqual(try names("backf-1333"), ["Move up"] + sections + ["Remove"], "no Move down on the last item")

        func action(_ name: String) throws -> NSAccessibilityCustomAction {
            let tick = try XCTUnwrap(try h.row("draft-1148").tickButton)
            return try XCTUnwrap(tick.accessibilityCustomActions()?.first { $0.name == name }, "no VoiceOver action \(name)")
        }
        XCTAssertEqual(try action("Move up").handler?(), true)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "draft-1148", section: "now", before: "revie-1111", after: nil)])
        XCTAssertEqual(try action("Move down").handler?(), true)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "draft-1148", section: "now", before: nil, after: "close-1185")])
        XCTAssertEqual(try action("Move to Findings").handler?(), true)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "draft-1148", section: "findings", before: nil, after: nil)])
        XCTAssertEqual(try action("Remove").handler?(), true)
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: "draft-1148")])
    }

    func testVoiceOversMoveActionsFollowTheNeighboursAfterTheBoardChangesWithoutRebuildingTheRow() throws {
        // Findings is off screen at the top of the board, so an agent's reorder there applies at once. The row of
        // repro-2554 is not rebuilt (its own content is the same), but it now has an item above it.
        let h = try harness(height: 500)
        func names() throws -> [String] {
            let tick = try XCTUnwrap(try h.row("repro-2554").tickButton)
            return (tick.accessibilityCustomActions() ?? []).map(\.name).filter { $0.hasPrefix("Move up") || $0.hasPrefix("Move down") }
        }
        XCTAssertEqual(try names(), ["Move down"], "setup: the first open item of Findings")
        XCTAssertFalse(h.pane.visibleKeys().contains("item:repro-2554"), "setup: off screen")
        try h.agentChange { try $0.place("rotat-2702", section: "findings", before: "repro-2554") }
        XCTAssertEqual(try names(), ["Move up", "Move down"], "an item above it now: VoiceOver can move it up")
    }

    // MARK: - Remove: the banner

    func testRemoveSendsTheRemoveShowsTheUndoBannerAtOnceAndTheRowGoesWhenTheBoardSaysSo() throws {
        let h = try harness()
        let id = "check-1000"
        let button = try removeButton(h, id)
        XCTAssertEqual(button.title, "Remove")
        XCTAssertNil(h.pane.notice.spokenText)

        button.performClick(nil)
        XCTAssertEqual(h.sent.map(\.ops), [[.remove(id: id)]])
        XCTAssertEqual(h.sent.first?.base, 7)
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Check referral 4411 duplicate"))
        XCTAssertEqual(h.pane.notice.actionButton?.title, "Undo")
        XCTAssertEqual(h.pane.notice.actionButton?.accessibilityLabel(), "Undo")
        XCTAssertFalse(h.pane.notice.isHidden)
        XCTAssertEqual(h.pane.notice.frame.height, TrackerNoticeView.height, accuracy: 0.01)
        XCTAssertNotNil(h.pane.rowViews["item:\(id)"], "no optimistic removal: the row stays until the board says")
        XCTAssertEqual(h.pane.showReport()["notice"] as? String, removedBanner("Check referral 4411 duplicate"))

        try echoRemoval(h, id)
        XCTAssertNil(h.pane.rowViews["item:\(id)"], "the row is gone at once (no 'removed' stub: the user did it)")
        XCTAssertTrue(pending(h).isEmpty, "nothing is held back")
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Check referral 4411 duplicate"), "the banner outlasts the daemon's answer")
    }

    func testUndoOnTheBannerWithinTenSecondsSendsARestoreOfTheExactMarkdownToTheSamePlace() throws {
        let h = try harness()
        let id = "check-1000"
        let node = try XCTUnwrap(h.script.item(id))
        let source = try XCTUnwrap(node["source"] as? String)
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)

        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: source, section: "now", before: "verif-1037", after: nil)],
                       "the item's own markdown, back before the item that followed it")
        XCTAssertEqual(h.sent.last?.base, 8, "against the board the user sees")
        XCTAssertNil(h.pane.notice.spokenText, "the banner goes at once")
        XCTAssertEqual(h.pane.notice.frame.height, 0, accuracy: 0.01)

        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [id])
        XCTAssertEqual(Array(shownIDs(h, in: "now").prefix(2)), ["check-1000", "verif-1037"], "back at the top where it was")
    }

    func testTheBannerLastsTenSecondsAndCommandZStillRestoresAfterIt() throws {
        let h = try harness()
        XCTAssertEqual(TrackerPaneView.removalBannerLifetime, 10)
        let id = "check-1000"
        let node = try XCTUnwrap(h.script.item(id))
        let source = try XCTUnwrap(node["source"] as? String)
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)
        let timers = h.rig.scheduler.scheduled.filter { $0.delay == 10 }
        XCTAssertEqual(timers.count, 1, "the pane scheduled its banner for 10 s with the injected schedule")
        XCTAssertNotNil(h.pane.notice.spokenText, "showing until then")

        timers.forEach { $0.work() }
        XCTAssertNil(h.pane.notice.spokenText, "the banner is gone after 10 s")
        XCTAssertTrue(h.pane.notice.isHidden)
        XCTAssertEqual(h.pane.notice.frame.height, 0, accuracy: 0.01, "and gives its space back")
        XCTAssertNil(h.pane.showReport()["notice"] as? String)

        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Remove Item")
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: source, section: "now", before: "verif-1037", after: nil)],
                       "⌘Z still restores, with the same markdown, long after the banner")
    }

    func testCommandZRightAfterARemoveRestoresItAndTheBannerGoesAndRedoRemovesItAgain() throws {
        let h = try harness()
        let id = "check-1000"
        let node = try XCTUnwrap(h.script.item(id))
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)

        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: try XCTUnwrap(node["source"] as? String), section: "now", before: "verif-1037", after: nil)])
        XCTAssertNil(h.pane.notice.spokenText, "the item is back: the banner's offer is spent")
        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [id])

        h.pane.performRedo()
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: id)], "redo removes it again")
    }

    func testARestoredItemThatComesBackUnderANewIdIsTheOneRedoRemoves() throws {
        let h = try harness()
        let id = "check-1000"
        var node = try XCTUnwrap(h.script.item(id))
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)
        h.pane.performUndo()
        node["id"] = "check-9999"
        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: ["check-9999"])
        h.pane.performRedo()
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: "check-9999")], "the daemon named it: redo follows the new id")
    }

    func testASecondRemovalReplacesTheBannerAndItsUndoRestoresTheSecondItem() throws {
        let h = try harness()
        let first = "check-1000", second = "draft-1148"
        try removeButton(h, first).performClick(nil)
        try echoRemoval(h, first)
        try removeButton(h, second).performClick(nil)
        try echoRemoval(h, second)
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Draft search index"), "the banner names the newest removal")

        let timers = h.rig.scheduler.scheduled.filter { $0.delay == 10 }
        XCTAssertEqual(timers.count, 2)
        timers[0].work()
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Draft search index"), "the first removal's timer does not take the newer banner down")
        timers[1].work()
        XCTAssertNil(h.pane.notice.spokenText)

        // Again, and this time press Undo on the banner.
        let third = "docum-1296"
        let thirdNode = try XCTUnwrap(h.script.item(third))
        try removeButton(h, third).performClick(nil)
        try echoRemoval(h, third)
        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: try XCTUnwrap(thirdNode["source"] as? String), section: "now",
                                                   before: nil, after: "triag-1259")],
                       "the banner's Undo restores the newest removal, after the item that was above it then")
    }

    func testTheBannersUndoWhenTheRemovalIsNotTheNewestUndoRestoresItDirectlyAndNeverRestoresItTwice() throws {
        let h = try harness()
        let id = "check-1000"
        let node = try XCTUnwrap(h.script.item(id))
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)
        h.pane.setStatus(item: "verif-1037", to: "blocked")
        try h.echo { try $0.setStatus("verif-1037", "blocked") }
        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Status", "setup: the newest undo is the status change")

        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: try XCTUnwrap(node["source"] as? String), section: "now", before: "verif-1037", after: nil)],
                       "the banner restores its own removal, not whatever ⌘Z would do next")
        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [id])

        var steps = 0
        while h.pane.editing.undoManager.canUndo, steps < 6 {
            steps += 1
            let sentBefore = h.sent.count
            h.pane.performUndo()
            guard h.sent.count > sentBefore, let op = h.sent.last?.ops.first else { continue }
            switch op {
            case .remove(let removed): try echoRemoval(h, removed)
            case .status(let statusId, let status): try h.echo { try $0.setStatus(statusId, status) }
            default: break
            }
        }
        let restores = h.sent.filter { sent in sent.ops.contains { if case .restore = $0 { return true } else { return false } } }
        XCTAssertEqual(restores.count, 1, "the item was restored once, by the banner; ⌘Z never restores a second copy")
    }

    func testAFailedRestoreShowsANoticeDoesNotRetryAndLeavesNoRedo() throws {
        let h = try harness()
        let id = "check-1000"
        try removeButton(h, id).performClick(nil)
        try echoRemoval(h, id)
        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        let count = h.sent.count
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_unreadable", "reason": "line 7"])
        XCTAssertEqual(h.pane.notice.text, "Not saved: the board file can't be read (line 7).")
        XCTAssertNil(h.pane.notice.actionButton, "the notice is only a notice")
        h.fire(6)
        h.rig.settle()
        XCTAssertNotEqual(h.pane.notice.text, "Not saved: the board file can't be read (line 7).", "the notice goes after 6 s")
        XCTAssertEqual(h.pane.notice.spokenText, removedBanner("Check referral 4411 duplicate"),
                       "and the removal's banner is back: a refused restore leaves the removal undoable")
        XCTAssertEqual(h.sent.count, count, "nothing was sent again: the pane does not retry")
        XCTAssertFalse(h.pane.editing.undoManager.canRedo, "there is no redo of an undo that did not happen")
    }

    func testARefusedRemoveTakesTheBannerBackSaysWhyAndLeavesNothingToUndo() throws {
        let h = try harness()
        let id = "check-1000"
        try removeButton(h, id).performClick(nil)
        XCTAssertNotNil(h.pane.notice.actionButton, "setup: the banner is up")
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "unknown_item"])
        XCTAssertEqual(h.pane.notice.text, "Not saved: that item is no longer on the board.")
        XCTAssertNil(h.pane.notice.actionButton, "nothing was removed: there is nothing to undo")
        XCTAssertEqual(h.pane.notice.spokenText, "Not saved: that item is no longer on the board.")
        XCTAssertNotNil(h.pane.rowViews["item:\(id)"], "the row is still there")
        XCTAssertFalse(h.pane.editing.undoManager.canUndo)
    }

    func testRemovingOrMovingARowThatIsOnlyAStubSendsNothing() throws {
        let h = try harness()
        try h.agentChange { try $0.removeItem("close-1185") }
        guard case .stub = try XCTUnwrap(h.pane.rowViews["item:close-1185"]).row.content else {
            return XCTFail("setup: the agent's removal left a stub on screen")
        }
        h.pane.removeItem("close-1185")
        h.pane.moveItem("close-1185", .up)
        h.pane.moveItem("close-1185", .toSection("next"))
        XCTAssertTrue(h.sent.isEmpty, "a stub is not an item the user can move or remove")
        XCTAssertNil(h.pane.notice.spokenText, "and no Removed banner for it")
    }

    // MARK: - The user's own change shows at once; an agent's on-screen move still waits

    func testYourOwnMoveShowsAtOnceEvenOnScreenWhicheverOfTheResultAndTheBoardComesFirst() throws {
        for resultFirst in [false, true] {
            let h = try harness()
            h.pane.moveItem("verif-1037", .down)
            XCTAssertEqual(h.sent.last?.ops, [.move(id: "verif-1037", section: "now", before: nil, after: "retry-1074")])
            try h.echo({ try $0.place("verif-1037", section: "now", after: "retry-1074") }, resultFirst: resultFirst)
            XCTAssertEqual(shownIDs(h, in: "now"), ["check-1000", "retry-1074", "verif-1037"] + Array(nowIds.suffix(7)),
                           "result first: \(resultFirst): the pane shows the move at once")
            XCTAssertTrue(pending(h).isEmpty, "result first: \(resultFirst): nothing is held back: \(pending(h))")
        }
    }

    func testYourOwnMoveToAnotherSectionLeavesNoStubAndNoMovingCopy() throws {
        let h = try harness()
        h.pane.moveItem("verif-1037", .toSection("next"))
        try h.echo { try $0.place("verif-1037", section: "next") }
        XCTAssertEqual(try h.row("verif-1037").row.item?.sectionId, "next")
        XCTAssertEqual(shownIDs(h, in: "next").last, "verif-1037")
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds.filter { $0 != "verif-1037" })
        XCTAssertFalse(h.pane.rowViews.keys.contains { $0.hasPrefix("moving:") }, "no moving: copy")
        XCTAssertTrue(pending(h).isEmpty)
    }

    func testAnAgentsMoveOfAnOnScreenItemIsStillHeldWhereTheReaderSeesIt() throws {
        let h = try harness()
        try h.agentChange { try $0.place("draft-1148", section: "now") }
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds, "the reader's order did not change")
        XCTAssertTrue(pending(h).contains(TrackerAnchorSnapshot.Pending(key: "item:draft-1148", kind: "kept_in_place")),
                      "the agent's reorder waits: \(pending(h))")

        let other = try harness()
        try other.agentChange { try $0.place("draft-1148", section: "next") }
        XCTAssertTrue(pending(other).contains(TrackerAnchorSnapshot.Pending(key: "item:draft-1148", kind: "moved")),
                      "an agent's move to another section leaves its stub: \(pending(other))")
    }

    func testTheExemptionEndsWithTheBoardThatShowsTheUsersMoveSoTheAgentsNextMoveWaits() throws {
        let h = try harness()
        h.pane.moveItem("verif-1037", .down)
        try h.echo { try $0.place("verif-1037", section: "now", after: "retry-1074") }
        XCTAssertTrue(pending(h).isEmpty, "setup: the user's move applied")
        try h.agentChange { try $0.place("verif-1037", section: "now") }
        XCTAssertFalse(pending(h).isEmpty, "the agent moving the same item afterwards is held like any agent move")
    }

    func testYourOwnRemovalLeavesNoStubButAnAgentsStillDoes() throws {
        for resultFirst in [false, true] {
            let h = try harness()
            h.pane.removeItem("revie-1111")
            try echoRemoval(h, "revie-1111", resultFirst: resultFirst)
            XCTAssertNil(h.pane.rowViews["item:revie-1111"], "result first: \(resultFirst): gone at once")
            XCTAssertTrue(pending(h).isEmpty)
        }
        let h = try harness()
        try h.agentChange { try $0.removeItem("revie-1111") }
        XCTAssertTrue(pending(h).contains(TrackerAnchorSnapshot.Pending(key: "item:revie-1111", kind: "removed")),
                      "an agent's removal of an on-screen item leaves a stub: \(pending(h))")
    }

    // MARK: - Undo and redo of a move

    func testCommandZOfAMoveMovesItBackToWhereTheViewHadItAndRedoMovesItAgain() throws {
        let h = try harness()
        let id = "verif-1037"
        h.pane.moveItem(id, .down)
        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Move Item")
        try h.echo { try $0.place(id, section: "now", after: "retry-1074") }

        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "check-1000")],
                       "back after the item that was above it")
        XCTAssertEqual(h.sent.last?.base, 8, "against the board the user sees now")
        try h.echo { try $0.place(id, section: "now", after: "check-1000") }
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds, "back where it was")
        XCTAssertEqual(h.pane.editing.undoManager.redoMenuItemTitle, "Redo Move Item")

        h.pane.performRedo()
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "retry-1074")])
    }

    func testCommandZOfAMoveToAnotherSectionPutsItBackInItsOldPlace() throws {
        let h = try harness()
        let id = "draft-1148"
        h.pane.moveItem(id, .toSection("findings"))
        try h.echo { try $0.place(id, section: "findings") }
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "revie-1111")])
    }

    func testAnUndoOfAMoveWhoseItemIsGoneSaysSoAndSendsNothing() throws {
        let h = try harness()
        h.pane.moveItem("verif-1037", .down)
        try h.echo { try $0.place("verif-1037", section: "now", after: "retry-1074") }
        try h.agentChange { try $0.removeItem("verif-1037") }
        let count = h.sent.count
        h.pane.performUndo()
        XCTAssertEqual(h.pane.notice.text, "Couldn't undo: the item was removed.")
        XCTAssertEqual(h.sent.count, count)
    }

    func testARefusedMoveLeavesNothingToUndoAndSaysWhy() throws {
        let h = try harness()
        h.pane.moveItem("verif-1037", .down)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "unknown_item"])
        // A move names its neighbour: the daemon's unknown_item is about that item, not the one the user moved.
        XCTAssertEqual(h.pane.notice.text, "Not saved: the place for it changed (the item next to it moved or is gone). Try again.")
        XCTAssertFalse(h.pane.editing.undoManager.canUndo)
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds)
    }

    func testAMoveToWhereTheItemAlreadyIsSendsNothing() throws {
        let h = try harness()
        h.pane.moveItem("check-1000", .up)
        h.pane.moveItem("backf-1333", .down)
        XCTAssertTrue(h.sent.isEmpty, "nothing above the first item, nothing below the last")
        XCTAssertFalse(h.pane.editing.undoManager.canUndo)
    }

    // MARK: - Fix-ups: a daemon without edit support gets no add row

    private func addKeys(_ h: TrackerEditHarness) -> [String] {
        h.pane.displayedRows.map(\.key).filter { $0.hasPrefix("add:") }
    }

    /// Every "+ Add item" button anywhere in the pane's view tree.
    private func addButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton, button.title == "+ Add item" { found.append(button) }
        for sub in view.subviews { found += addButtons(in: sub) }
        return found
    }

    func testAPaneWhoseDaemonCannotTakeEditsHasNoAddRowNoAddButtonAndReportsNoAddRows() throws {
        let h = try harness(supported: false)
        XCTAssertEqual(addKeys(h), [], "no add row among the rows")
        XCTAssertTrue(h.pane.rowViews.keys.allSatisfy { !$0.hasPrefix("add:") }, "and no row view for one")
        XCTAssertTrue(addButtons(in: h.pane).isEmpty, "no add control in the view tree: it would only do nothing")
        XCTAssertEqual(h.pane.showReport()["add_rows"] as? [String], [], "tracker show agrees")
        XCTAssertEqual(h.pane.showReport()["edit_enabled"] as? Bool, false)
        for filter in [TrackerFilter.open, .all] {
            h.pane.setFilter(filter)
            XCTAssertEqual(addKeys(h), [], "\(filter): still none")
        }
    }

    func testTheAddRowsAppearWhenTheDaemonGainsEditSupportAndGoWhenItLosesIt() throws {
        let h = try harness(supported: false)
        XCTAssertEqual(addKeys(h), [])
        h.supported = true
        h.pane.render()
        h.rig.settle()
        XCTAssertEqual(addKeys(h), ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"].map { "add:\($0)" })
        XCTAssertEqual(h.pane.showReport()["add_rows"] as? [String], ["now", "next", "waiting-on-you", "done", "findings", "loose-ends"])
        XCTAssertEqual(addButtons(in: h.pane).count, 6, "each with its button")

        h.supported = false
        h.pane.render()
        h.rig.settle()
        XCTAssertEqual(addKeys(h), [], "the rows go with the support")
        XCTAssertTrue(h.pane.rowViews.keys.allSatisfy { !$0.hasPrefix("add:") })
        XCTAssertTrue(addButtons(in: h.pane).isEmpty)
        XCTAssertEqual(h.pane.showReport()["add_rows"] as? [String], [])
    }

    // MARK: - Fix-ups: an undo works its place out against the board as it is then

    private func source(_ h: TrackerEditHarness, _ id: String) throws -> String {
        try XCTUnwrap(try XCTUnwrap(h.script.item(id))["source"] as? String)
    }

    /// The user removes `id`; the daemon applies it.
    private func removeAndEcho(_ h: TrackerEditHarness, _ id: String) throws {
        h.pane.removeItem(id)
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: id)], "setup")
        try echoRemoval(h, id)
    }

    /// Undo the removal the way the user does: the banner's Undo, or ⌘Z.
    private func undoRemoval(_ h: TrackerEditHarness, viaBanner: Bool) throws {
        if viaBanner {
            try XCTUnwrap(h.pane.notice.actionButton, "the banner is up").performClick(nil)
        } else {
            h.pane.performUndo()
        }
    }

    func testUndoingARemovalPutsItBesideTheOtherNeighbourWhenTheOneItWasBesideIsGone() throws {
        // draft-1148 sat between revie-1111 and close-1185.
        let scenarios: [(String, (inout TrackerBoardScript) throws -> Void, PlaceExpectation)] = [
            ("the item above was removed by an agent", { try $0.removeItem("revie-1111") }, .before("close-1185")),
            ("the item above was moved to another section by an agent", { try $0.place("revie-1111", section: "next") }, .before("close-1185")),
            ("the item below was removed (the one above is still there)", { try $0.removeItem("close-1185") }, .after("revie-1111")),
            ("both neighbours were removed", { try $0.removeItem("revie-1111"); try $0.removeItem("close-1185") }, .sectionEnd),
            ("both neighbours were moved to another section", { try $0.place("revie-1111", section: "next"); try $0.place("close-1185", section: "next") }, .sectionEnd),
        ]
        for viaBanner in [true, false] {
            for (name, change, expected) in scenarios {
                let h = try harness()
                let id = "draft-1148"
                let markdown = try source(h, id)
                try removeAndEcho(h, id)
                try h.agentChange(change)
                try undoRemoval(h, viaBanner: viaBanner)
                XCTAssertEqual(h.sent.last?.ops, [.restore(source: markdown, section: "now", before: expected.before, after: expected.after)],
                               "\(name) (via \(viaBanner ? "the banner" : "⌘Z")): the place is worked out against the board now")
            }
        }
    }

    func testUndoingTheRemovalOfAnEdgeItemWhoseOnlyNeighbourIsGoneRestoresToTheSectionEnd() throws {
        let h = try harness()
        let markdown = try source(h, "check-1000")
        try removeAndEcho(h, "check-1000")      // the first item: only verif-1037 was beside it
        try h.agentChange { try $0.removeItem("verif-1037") }
        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: markdown, section: "now", before: nil, after: nil)],
                       "never a neighbour that is gone")
    }

    func testARefusedRestoreKeepsTheBannerAndTheCommandZEntryAndDoesNotBlameTheItem() throws {
        for viaBanner in [true, false] {
            let h = try harness()
            let id = "check-1000"
            let markdown = try source(h, id)
            let node = try XCTUnwrap(h.script.item(id))
            let banner = removedBanner("Check referral 4411 duplicate")
            try removeAndEcho(h, id)
            let restore = [TrackerPaneOpWire.restore(source: markdown, section: "now", before: "verif-1037", after: nil)]

            try undoRemoval(h, viaBanner: viaBanner)
            XCTAssertEqual(h.sent.last?.ops, restore, "setup")
            h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "unknown_item"])
            let text = try XCTUnwrap(h.pane.notice.text)
            XCTAssertTrue(text.hasPrefix("Not saved: the place for it changed"), "via \(viaBanner): says what changed: \(text)")
            XCTAssertFalse(text.contains("no longer on the board"), "the item is not what is missing: \(text)")

            h.fire(6)
            h.rig.settle()
            XCTAssertEqual(h.pane.notice.spokenText, banner, "via \(viaBanner): the banner is back once the notice has gone")
            XCTAssertEqual(h.pane.notice.actionButton?.title, "Undo")
            XCTAssertEqual(h.pane.showReport()["notice"] as? String, banner)
            XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Remove Item", "via \(viaBanner): ⌘Z still has it")
            XCTAssertFalse(h.pane.editing.undoManager.canRedo, "nothing was undone, so there is no redo")

            let count = h.sent.count
            h.pane.performUndo()
            XCTAssertEqual(h.sent.count, count + 1, "via \(viaBanner): ⌘Z tries again")
            XCTAssertEqual(h.sent.last?.ops, restore)
            try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [id])
            XCTAssertEqual(Array(shownIDs(h, in: "now").prefix(2)), ["check-1000", "verif-1037"], "via \(viaBanner): and this time it is back")
            XCTAssertNotNil(h.pane.rowViews["item:check-1000"], "via \(viaBanner): the row is on the board again")
        }
    }

    func testARefusedRestoreFromTheBannerCanBeTriedAgainFromTheBannerToo() throws {
        let h = try harness()
        let id = "check-1000"
        let node = try XCTUnwrap(h.script.item(id))
        try removeAndEcho(h, id)
        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "unknown_item"])
        h.fire(6)
        h.rig.settle()
        let count = h.sent.count
        try XCTUnwrap(h.pane.notice.actionButton, "the banner offers Undo again").performClick(nil)
        XCTAssertEqual(h.sent.count, count + 1)
        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [id])
        XCTAssertEqual(Array(shownIDs(h, in: "now").prefix(2)), ["check-1000", "verif-1037"])
    }

    func testUndoingAMoveWorksItsPlaceOutAgainstTheBoardNow() throws {
        // verif-1037 sat between check-1000 and retry-1074 and was moved down past retry-1074.
        let scenarios: [(String, (inout TrackerBoardScript) throws -> Void, PlaceExpectation)] = [
            ("the item above it was removed", { try $0.removeItem("check-1000") }, .before("retry-1074")),
            ("the item above it went to another section", { try $0.place("check-1000", section: "next") }, .before("retry-1074")),
            ("the item below it was removed (the one above is still there)", { try $0.removeItem("retry-1074") }, .after("check-1000")),
            ("both were removed", { try $0.removeItem("check-1000"); try $0.removeItem("retry-1074") }, .sectionEnd),
        ]
        for (name, change, expected) in scenarios {
            let h = try harness()
            let id = "verif-1037"
            h.pane.moveItem(id, .down)
            try h.echo { try $0.place(id, section: "now", after: "retry-1074") }
            try h.agentChange(change)
            h.pane.performUndo()
            XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: expected.before, after: expected.after)],
                           "\(name): the move back is worked out against the board now")
        }
    }

    func testARefusedUndoOfAMoveKeepsItsCommandZEntrySaysThePlaceChangedAndCanBeTriedAgain() throws {
        let h = try harness()
        let id = "verif-1037"
        h.pane.moveItem(id, .down)
        try h.echo { try $0.place(id, section: "now", after: "retry-1074") }

        h.pane.performUndo()
        let back = [TrackerPaneOpWire.move(id: id, section: "now", before: nil, after: "check-1000")]
        XCTAssertEqual(h.sent.last?.ops, back, "setup")
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "unknown_item"])
        let text = try XCTUnwrap(h.pane.notice.text)
        XCTAssertTrue(text.hasPrefix("Not saved: the place for it changed"), text)
        XCTAssertFalse(text.contains("no longer on the board"), text)
        XCTAssertTrue(h.pane.editing.undoManager.canUndo, "the undo entry is still there")
        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, "Undo Move Item")
        XCTAssertFalse(h.pane.editing.undoManager.canRedo, "the move was not undone: nothing to redo")

        let count = h.sent.count
        h.pane.performUndo()
        XCTAssertEqual(h.sent.count, count + 1, "⌘Z tries the move back again")
        XCTAssertEqual(h.sent.last?.ops, back)
        try h.echo { try $0.place(id, section: "now", after: "check-1000") }
        XCTAssertEqual(shownIDs(h, in: "now"), nowIds, "and this time it went")
        XCTAssertEqual(h.pane.editing.undoManager.redoMenuItemTitle, "Redo Move Item")
    }

    // MARK: - Fix-ups: a held row's move, removal and drop name the version the row shows

    /// `id` shows version 7's content, held by a text selection, while an agent changes its text (version 8).
    private func heldHarness(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> TrackerEditHarness {
        let h = try harness(file: file, line: line)
        let textView = try XCTUnwrap(try h.row(id, file: file, line: line).textViews.first, file: file, line: line)
        XCTAssertTrue(h.window.makeFirstResponder(textView), file: file, line: line)
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        rigSettle(0.02)
        XCTAssertNotNil(try h.row(id, file: file, line: line).selectedTextView, "setup: a selection holds the row", file: file, line: line)
        let shown = try h.row(id, file: file, line: line).visibleText
        try h.agentChange({ script in
            try script.updateItem(id) {
                $0["text"] = "Rewritten by an agent"
                $0["text_spans"] = [["kind": "text", "text": "Rewritten by an agent"]]
            }
        }, file: file, line: line)
        XCTAssertEqual(h.version, 8, "setup", file: file, line: line)
        XCTAssertEqual(try h.row(id, file: file, line: line).visibleText, shown,
                       "setup: the held row still shows version 7's content", file: file, line: line)
        return h
    }

    func testAMoveOfAHeldRowSendsTheVersionItShowedNotTheNewestBoard() throws {
        let id = "revie-1111"
        let h = try heldHarness(id)
        h.pane.moveItem(id, .down)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "draft-1148")], "setup: the move went")
        XCTAssertEqual(h.sent.last?.base, 7, "not 8: the user never saw version 8's text")
    }

    func testARemovalOfAHeldRowSendsTheVersionItShowedNotTheNewestBoard() throws {
        let id = "revie-1111"
        let h = try heldHarness(id)
        h.pane.removeItem(id)
        XCTAssertEqual(h.sent.last?.ops, [.remove(id: id)], "setup: the removal went")
        XCTAssertEqual(h.sent.last?.base, 7, "not 8: the user never saw version 8's text")
    }

    func testADropOfAHeldRowSendsTheVersionItShowedNotTheNewestBoard() throws {
        let id = "revie-1111"
        let h = try heldHarness(id)
        h.pane.dragBegan()
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, id), at: try point(h, over: "item:close-1185", lower: true)))
        XCTAssertEqual(h.sent.last?.ops, [.move(id: id, section: "now", before: nil, after: "close-1185")], "setup: the drop went")
        XCTAssertEqual(h.sent.last?.base, 7, "not 8: the user never saw version 8's text")
        h.pane.dragEnded()
    }

    // MARK: - Fix-ups: a drop does not take the keyboard

    private func drop(_ h: TrackerEditHarness, file: StaticString = #filePath, line: UInt = #line) throws {
        h.pane.dragBegan()
        XCTAssertTrue(h.pane.dragDropped(payload: payload(h, "verif-1037"),
                                         at: try point(h, over: "item:draft-1148", lower: false, file: file, line: line)),
                      "setup: the drop was taken", file: file, line: line)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "verif-1037", section: "now", before: nil, after: "revie-1111")],
                       "the move is sent", file: file, line: line)
        h.pane.dragEnded()
    }

    func testADropLeavesTheComposerFirstResponderSoTypingGoesOn() throws {
        let h = try harness()
        XCTAssertTrue(h.window.makeFirstResponder(h.rig.composer))
        let editor = try XCTUnwrap(h.rig.composer.currentEditor() as? NSTextView)
        editor.string = "half-written message"
        try drop(h)
        XCTAssertTrue(h.window.firstResponder === h.rig.composer.currentEditor(), "the composer still has the keyboard")
        XCTAssertFalse(h.window.firstResponder === h.pane.sink, "the pane did not take it")
        XCTAssertEqual(h.rig.composer.stringValue, "half-written message")
        try h.echo { try $0.place("verif-1037", section: "now", after: "revie-1111") }
        XCTAssertTrue(h.window.firstResponder === h.rig.composer.currentEditor(), "nor when the daemon's board arrives")
    }

    func testADropLeavesTheSinkFirstResponderWhenThePaneAlreadyHadTheKeyboard() throws {
        let h = try harness()
        h.pane.focusSink()
        XCTAssertTrue(h.window.firstResponder === h.pane.sink, "setup")
        try drop(h)
        XCTAssertTrue(h.window.firstResponder === h.pane.sink, "the pane keeps the focus it had")
    }

    func testADropWithNothingFocusedDoesNotGiveThePaneTheKeyboard() throws {
        let h = try harness()
        h.window.makeFirstResponder(nil)
        try drop(h)
        XCTAssertFalse(h.window.firstResponder === h.pane.sink, "a drop is not a keyboard action")
    }

    // MARK: - Fix-ups: the banner's Undo when the removal is not the newest undo

    private func statusID(_ op: TrackerPaneOpWire?) -> String? {
        if case .status(let id, _)? = op { return id }
        return nil
    }

    func testTheBannersUndoOfAnOlderRemovalRestoresOnlyThatAndLeavesEveryOtherUndoAndRedoAlone() throws {
        let h = try harness()
        let a = "check-1000"
        let node = try XCTUnwrap(h.script.item(a))
        let markdown = try source(h, a)
        try removeAndEcho(h, a)                                           // the removal, with its banner
        h.pane.setStatus(item: "close-1185", to: "blocked")               // an older edit ...
        try h.echo { try $0.setStatus("close-1185", "blocked") }
        h.pane.setStatus(item: "triag-1259", to: "blocked")               // ... and a newer one, which is undone
        try h.echo { try $0.setStatus("triag-1259", "blocked") }
        h.pane.performUndo()
        XCTAssertEqual(statusID(h.sent.last?.ops.first), "triag-1259", "setup: ⌘Z undid the newest edit")
        try h.echo { try $0.setStatus("triag-1259", "todo") }
        let undoTitle = h.pane.editing.undoManager.undoMenuItemTitle
        XCTAssertEqual(undoTitle, "Undo Status", "setup: the removal is not the newest undo")
        XCTAssertEqual(h.pane.editing.undoManager.redoMenuItemTitle, "Redo Status", "setup: a redo exists")
        XCTAssertNotNil(h.pane.notice.actionButton, "setup: the banner is still up")

        let before = h.sent.count
        try XCTUnwrap(h.pane.notice.actionButton).performClick(nil)
        XCTAssertEqual(h.sent.count, before + 1, "one op")
        XCTAssertEqual(h.sent.last?.ops, [.restore(source: markdown, section: "now", before: "verif-1037", after: nil)],
                       "exactly the removal's own restore")
        try h.echo({ try $0.insert(node, section: "now", before: "verif-1037") }, created: [a])

        XCTAssertEqual(h.pane.editing.undoManager.undoMenuItemTitle, undoTitle, "no undo entry was added by the restore")
        XCTAssertTrue(h.pane.editing.undoManager.canRedo, "the redo was not cleared")
        XCTAssertEqual(h.pane.editing.undoManager.redoMenuItemTitle, "Redo Status")

        h.pane.performRedo()
        XCTAssertEqual(statusID(h.sent.last?.ops.first), "triag-1259", "the redo is still the one that was there")
        try h.echo { try $0.setStatus("triag-1259", "blocked") }
        h.pane.performUndo()
        XCTAssertEqual(statusID(h.sent.last?.ops.first), "triag-1259")
        try h.echo { try $0.setStatus("triag-1259", "todo") }

        h.pane.performUndo()
        XCTAssertEqual(statusID(h.sent.last?.ops.first), "close-1185", "⌘Z goes on to the other edit, not to the removal again")
        try h.echo { try $0.setStatus("close-1185", "in-progress") }
        let count = h.sent.count
        for _ in 0..<5 where h.pane.editing.undoManager.canUndo { h.pane.performUndo() }
        XCTAssertEqual(h.sent.count, count, "nothing else is left to undo: the removal's own entry was spent")
        let restores = h.sent.filter { $0.ops.contains { if case .restore = $0 { return true } else { return false } } }
        XCTAssertEqual(restores.count, 1, "the item was restored once")
    }

    // MARK: - Fix-ups: Remove is not offered under an open editor

    private func openEditor(_ h: TrackerEditHarness, _ id: String, _ kind: TrackerEditKind) throws {
        expand(h, id)
        h.pane.beginEdit(item: id, kind: kind)
        let row = try h.row(id)
        XCTAssertNotNil(kind == .title ? row.titleEditor : row.detailsEditor, "setup: the \(kind) editor is open")
    }

    private func closeEditor(_ h: TrackerEditHarness, _ id: String, _ kind: TrackerEditKind) throws {
        let row = try h.row(id)
        if kind == .title { h.pressEscape(in: try XCTUnwrap(row.titleEditor)) } else { try XCTUnwrap(row.detailsEditor).cancelOperation(nil) }
        XCTAssertNil(try h.row(id).activeEditor, "setup: the editor closed")
    }

    func testTheRowHasNoRemoveButtonWhileItsTitleOrDetailsEditorIsOpenAndHasItAgainAfter() throws {
        for kind in [TrackerEditKind.title, .details] {
            let h = try harness()
            let id = "check-1000"
            expand(h, id)
            XCTAssertNotNil(try h.row(id).removeButton, "setup: an expanded row has Remove")
            try openEditor(h, id, kind)
            XCTAssertNil(try h.row(id).removeButton, "\(kind): no Remove button under the open editor")
            XCTAssertNotNil(try h.row(id).movePopUp, "\(kind): the rest of the row's controls are untouched")
            try closeEditor(h, id, kind)
            XCTAssertNotNil(try h.row(id).removeButton, "\(kind): Remove is offered again once the editor has closed")
        }
    }

    func testTheContextMenuHasNoRemoveWhileAnEditorIsOpenAndHasItAgainAfter() throws {
        for kind in [TrackerEditKind.title, .details] {
            let h = try harness()
            let id = "draft-1148"
            try openEditor(h, id, kind)
            let open = try h.row(id).editMenuItems().map(\.title)
            XCTAssertFalse(open.contains("Remove"), "\(kind): \(open)")
            XCTAssertTrue(open.contains("Move"), "\(kind): the rest of the menu is there: \(open)")
            XCTAssertFalse(try h.row(id).menuItems().map(\.title).contains("Remove"), "\(kind): nor in the whole menu")
            try closeEditor(h, id, kind)
            XCTAssertTrue(try h.row(id).editMenuItems().map(\.title).contains("Remove"), "\(kind): back after the editor closes")
        }
    }

    func testVoiceOverDoesNotOfferRemoveWhileAnEditorIsOpenAndOffersItAgainAfter() throws {
        func names(_ h: TrackerEditHarness, _ id: String) throws -> [String] {
            let tick = try XCTUnwrap(try h.row(id).tickButton)
            return (tick.accessibilityCustomActions() ?? []).map(\.name)
        }
        for kind in [TrackerEditKind.title, .details] {
            let h = try harness()
            let id = "draft-1148"
            XCTAssertTrue(try names(h, id).contains("Remove"), "setup")
            try openEditor(h, id, kind)
            let open = try names(h, id)
            XCTAssertFalse(open.contains("Remove"), "\(kind): \(open)")
            XCTAssertTrue(open.contains("Move down"), "\(kind): the other actions stay: \(open)")
            try closeEditor(h, id, kind)
            XCTAssertTrue(try names(h, id).contains("Remove"), "\(kind): back after the editor closes")
        }
    }

    func testTheOnePaneRemoveRefusesAnItemWhoseEditorIsOpenOrWhoseEditIsBeingSavedAndWorksAfter() throws {
        for kind in [TrackerEditKind.title, .details] {
            let h = try harness()
            let id = "check-1000"
            try openEditor(h, id, kind)
            h.pane.removeItem(id)
            XCTAssertTrue(h.sent.isEmpty, "\(kind): nothing is sent while the editor is open")
            XCTAssertNil(h.pane.notice.spokenText, "\(kind): and no Removed banner")
            XCTAssertFalse(h.pane.editing.undoManager.canUndo, "\(kind): and nothing to undo")
            try closeEditor(h, id, kind)
            h.pane.removeItem(id)
            XCTAssertEqual(h.sent.map(\.ops), [[.remove(id: id)]], "\(kind): once the editor has closed it removes")
        }

        // The edit was sent and its board has not come: the item is still not removed from under its save.
        let h = try harness()
        let id = "revie-1111"
        h.pane.beginEdit(item: id, kind: .title)
        let editor = try XCTUnwrap(try h.row(id).titleEditor)
        h.type("Review the queue job", into: editor)
        h.pressReturn(in: editor)
        XCTAssertEqual(h.sent.map(\.ops), [[.edit(id: id, title: "Review the queue job", text: nil, body: nil)]], "setup: the save is on its way")
        h.pane.removeItem(id)
        XCTAssertEqual(h.sent.count, 1, "no removal while its edit waits for the board")
        XCTAssertNil(h.pane.notice.spokenText)
    }

    // MARK: - The strip and the sidebar pill follow a removal, its Undo and an add

    /// The ids the sidebar pill counts for this pane's board.
    private func pillIDs(_ h: TrackerEditHarness) throws -> Set<String> {
        Set(TrackerNeedsYouProducer.items(tag: h.rig.tag, board: try XCTUnwrap(h.pane.board)).map(\.id))
    }

    /// The keys of the waiting strip's entries.
    private func stripKeys(_ h: TrackerEditHarness) -> Set<String> {
        Set(h.pane.presentation?.strip.entries.map(\.key) ?? [])
    }

    /// Put the restored node back where the restore op the pane sent says (what the daemon does).
    private func echoRestore(_ h: TrackerEditHarness, _ node: TrackerBoardScript.Obj, file: StaticString = #filePath, line: UInt = #line) throws {
        guard case .restore(_, let section, let before, let after)? = h.sent.last?.ops.first else {
            return XCTFail("the last thing sent was not a restore: \(h.sent.last.map { "\($0.ops)" } ?? "nothing")", file: file, line: line)
        }
        let id = try XCTUnwrap(node["id"] as? String, file: file, line: line)
        try h.echo({ try $0.insert(node, section: section, before: before, after: after) }, created: [id], file: file, line: line)
    }

    func testRemovingANeedsYouItemDropsItFromTheStripAndThePillOnceTheDaemonEchoesAndUndoBringsItBackToBoth() throws {
        for viaBanner in [true, false] {
            let how = viaBanner ? "the banner's Undo" : "⌘Z"
            let h = try harness()
            let id = "backf-1777"        // one of the golden board's ten needs-you items
            let node = try XCTUnwrap(h.script.item(id))
            let strip = stripKeys(h), pill = try pillIDs(h)
            let total = strip.count        // the golden board's ten needs-you items and its three un-run commands
            XCTAssertGreaterThanOrEqual(total, 10, "setup: items wait on the person")
            XCTAssertEqual(pill.count, total, "setup: and the pill counts the same")
            XCTAssertTrue(strip.contains("item:\(id)"))
            XCTAssertEqual(h.pane.presentation?.strip.title, "Waiting on you (\(total))")

            h.pane.removeItem(id)
            XCTAssertEqual(h.sent.map(\.ops), [[.remove(id: id)]], "\(how): the removal is sent now, not when the banner expires")
            XCTAssertEqual(stripKeys(h), strip, "\(how): nothing changes before the daemon's board: no optimistic strip")
            XCTAssertEqual(try pillIDs(h), pill)

            try echoRemoval(h, id)
            XCTAssertEqual(stripKeys(h), strip.subtracting(["item:\(id)"]), "\(how): the strip dropped it once the daemon echoed")
            XCTAssertEqual(h.pane.presentation?.strip.title, "Waiting on you (\(total - 1))")
            XCTAssertEqual(try pillIDs(h).count, total - 1, "\(how): and so did the pill's count")
            XCTAssertFalse(try pillIDs(h).contains { $0.hasSuffix("item:\(id)") }, "\(how): the pill no longer counts that item")
            XCTAssertNotNil(h.pane.notice.actionButton, "\(how): setup: the banner is still up")

            try undoRemoval(h, viaBanner: viaBanner)
            XCTAssertEqual(stripKeys(h).count, total - 1, "\(how): the strip waits for the daemon's board for the restore too")
            try echoRestore(h, node)
            XCTAssertEqual(stripKeys(h), strip, "\(how): Undo brought the item back to the strip")
            XCTAssertEqual(h.pane.presentation?.strip.title, "Waiting on you (\(total))")
            XCTAssertEqual(try pillIDs(h), pill, "\(how): and to the pill")
        }
    }

    func testRemovingANeedsYouItemAfterTheBannerHasExpiredStillRestoresItToTheStripAndThePillWithCommandZ() throws {
        let h = try harness()
        let id = "backf-1777"
        let node = try XCTUnwrap(h.script.item(id))
        let strip = stripKeys(h), pill = try pillIDs(h)
        h.pane.removeItem(id)
        try echoRemoval(h, id)
        h.rig.scheduler.scheduled.filter { $0.delay == 10 }.forEach { $0.work() }
        XCTAssertNil(h.pane.notice.spokenText, "setup: the banner expired")
        XCTAssertEqual(stripKeys(h).count, strip.count - 1)

        h.pane.performUndo()
        try echoRestore(h, node)
        XCTAssertEqual(stripKeys(h), strip, "the strip has it again")
        XCTAssertEqual(try pillIDs(h), pill, "and so does the pill")
    }

    func testAddingAnItemToASectionDoesNotChangeTheStripOrThePill() throws {
        for section in ["waiting-on-you", "now"] {
            let h = try harness()
            let strip = stripKeys(h), pill = try pillIDs(h)
            let last = try XCTUnwrap(h.script.openItemIDs(inSection: section).last)
            let (_, field) = try openAdd(h, section)
            h.type("An item that waits on nobody", into: field)
            h.pressReturn(in: field)
            XCTAssertEqual(h.sent.map(\.ops), [[.add(section: section, title: "An item that waits on nobody", body: nil, before: nil, after: last)]])
            try h.echo({ try $0.insert(self.newItem("added-0001", section, "An item that waits on nobody"), section: section, after: last) },
                       created: ["added-0001"])
            XCTAssertNotNil(h.pane.rowViews["item:added-0001"], "\(section): setup: the new row is on the board")
            XCTAssertEqual(stripKeys(h), strip, "\(section): the strip is the same")
            XCTAssertEqual(h.pane.presentation?.strip.count, strip.count, "\(section): and counts the same")
            XCTAssertEqual(try pillIDs(h), pill, "\(section): the pill counts the same")
        }
    }

    // MARK: - Focus

    func testAMouseMoveMakesTheSinkFirstResponderSoCommandZUndoesIt() throws {
        let h = try harness()
        h.window.makeFirstResponder(nil)
        h.pane.moveItem("verif-1037", .down)
        XCTAssertTrue(h.window.firstResponder === h.pane.sink, "so the next ⌘Z undoes this edit")
        try h.echo { try $0.place("verif-1037", section: "now", after: "retry-1074") }
        XCTAssertTrue(h.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false)
        XCTAssertEqual(h.sent.last?.ops, [.move(id: "verif-1037", section: "now", before: nil, after: "check-1000")])
    }
}
