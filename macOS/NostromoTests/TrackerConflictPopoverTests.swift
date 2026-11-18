import XCTest
import AppKit
import NostromoKit

// T3b: conflicts (PRD 41, Mac half) and sensitive-data badges (PRD 43, Mac half) in the pane. The
// daemon names a conflict by an opaque `conflict_id`; the mark, the popover, the header chip and the
// buttons all work from the board the daemon sent, and every button sends exactly one `resolve_conflict`
// or `clear_badge`. Boards are the golden board plus hand-built `conflicts`, `removed_conflicts` and
// `sensitive` JSON, as the daemon encodes them.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Send the conflict's position instead of its `conflict_id`: the op assertions fail.
//  - Keep and Use swapped: the keep assertions fail.
//  - Take key focus for a mouse-opened popover: the composer-keeps-focus test fails.
//  - Skip returning focus on close for a keyboard-opened popover: the focus-return test fails.
//  - Show the sensitive badge without keeping the text: the text-visible assertion fails.
//  - Let the header chip change the header's height: the scroll gate fails.

final class TrackerConflictPopoverTests: XCTestCase {

    private let target = "check-1000"
    private let badged = "revie-1111"

    private func conflict(id: String = "7.1", field: String = "status", losing: String = "todo",
                          losingBy: String = "agent claudia", winningBy: String = "pane (you)",
                          secondsAgo: TimeInterval = 4) -> [String: Any] {
        ["conflict_id": id, "field": field, "losing": losing, "losing_by": losingBy, "winning_by": winningBy,
         "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - secondsAgo), "index": 0]
    }

    private func removed(id: String = "8.1", item: String = "gone-1", title: String = "A removed task") -> [String: Any] {
        ["conflict_id": id, "item_id": item, "title": title, "losing_by": "pane (you)", "winning_by": "agent cody",
         "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 3),
         "source": "- [ ] \(title) — todo <!-- #\(item) 1760540000 -->\n"]
    }

    private func harness(conflicts: [[String: Any]] = [], removedItems: [[String: Any]] = [],
                         size: NSSize = NSSize(width: 360, height: 600),
                         file: StaticString = #filePath, line: UInt = #line) throws -> TrackerEditHarness {
        try TrackerEditHarness(self, size: size, configure: { script in
            try script.updateItem(self.target) { $0["conflicts"] = conflicts }
            script.setRemovedConflicts(removedItems)
        }, file: file, line: line)
    }

    // MARK: - The mark and the popover

    func testAConflictShowsAMarkWithTheFirstConflictSpelledOutForVoiceOver() throws {
        let h = try harness(conflicts: [conflict(), conflict(id: "7.2", field: "note", losing: "old note")])
        let mark = try XCTUnwrap(try h.row(target).conflictButton)
        XCTAssertEqual(mark.title, "⇄ conflict")
        XCTAssertEqual(mark.accessibilityLabel(),
                       "Conflict on status: agent claudia set todo, then you changed it; it now reads in progress, and 1 more")
        XCTAssertNil(try h.row(badged).conflictButton, "only items with a conflict have the mark")
    }

    func testThePopoverTellsWhoSetWhatAndHowLongAgoAndBothValuesAreShownAsPlainText() throws {
        let h = try harness(conflicts: [conflict()])
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        XCTAssertEqual(popover.sections.count, 1)
        XCTAssertEqual(popover.sections.first?.message,
                       "agent claudia set status to “todo”, then you set it to “in progress”, 4 s ago.")
        XCTAssertEqual(popover.sections.first?.values, ["todo"])
        XCTAssertEqual(popover.buttons.map(\.title), ["Keep “in progress”", "Use “todo”"])
        XCTAssertTrue(popover.valueViews.allSatisfy { !$0.isRichText && !$0.isAutomaticLinkDetectionEnabled && !$0.isEditable })
        popover.close()
    }

    func testAValueIsCutAtFiveHundredCharactersAndNeverMarkdown() throws {
        let long = "**bold** [link](https://example.com) " + String(repeating: "x", count: 700)
        let h = try harness(conflicts: [conflict(field: "note", losing: long)])
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        // Two value boxes: the value in place first, the losing value (the long one) second.
        XCTAssertEqual(popover.valueViews.count, 2)
        XCTAssertEqual(popover.valueViews.last?.string.count, 500)
        XCTAssertTrue(popover.valueViews.last?.string.hasPrefix("**bold** [link]") ?? false, "plain text, not rendered")
        popover.close()
    }

    func testKeepSendsKeepCurrentWithTheOpaqueIdAndUseSendsKeepLosing() throws {
        let h = try harness(conflicts: [conflict(id: "1700.7.2")])
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[0].performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.resolveConflict(id: target, field: "status", keep: .current, conflictId: "1700.7.2")])
        XCTAssertEqual(h.sent.last?.base, 7)

        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[1].performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.resolveConflict(id: target, field: "status", keep: .losing, conflictId: "1700.7.2")])
        XCTAssertEqual(h.sent.count, 2, "one op per press")
    }

    func testUsingTheLosingValueCanBeUndoneButKeepingTheCurrentOneCannot() throws {
        let h = try harness(conflicts: [conflict()])
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[0].performClick(nil)
        XCTAssertFalse(h.pane.editing.undoManager.canUndo, "keep:current is not undoable")

        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[1].performClick(nil)
        XCTAssertTrue(h.pane.editing.undoManager.canUndo)
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.status(id: target, status: "in-progress")], "an edit back to the kept value")
    }

    func testAConflictThatIsGoneIsRefusedAndTheMessageSaysLookAgainWithoutRetrying() throws {
        let h = try harness(conflicts: [conflict()])
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[0].performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false,
                 error: ["code": "invalid_args", "reason": "that conflict is no longer kept (settled elsewhere or dropped); look again"])
        XCTAssertEqual(h.pane.notice.text, "That conflict is no longer there: look again.")
        XCTAssertEqual(h.sent.count, 1, "never a blind retry")
    }

    // MARK: - Removed items and the header chip

    func testRemovedItemsShowAHeaderChipAndRestoreSendsKeepLosing() throws {
        let h = try harness(removedItems: [removed()])
        let chip = try XCTUnwrap(h.pane.header.conflictChip)
        XCTAssertEqual(chip.title, "1 conflict")
        chip.performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        XCTAssertEqual(popover.sections.first?.message, "agent cody removed “A removed task” 3 s after you changed it.")
        XCTAssertEqual(popover.buttons.map(\.title), ["Restore", "Dismiss"])
        popover.buttons[0].performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.resolveConflict(id: "gone-1", field: "removed", keep: .losing, conflictId: "8.1")])
        h.pane.header.conflictChip?.performClick(nil)
        h.pane.activePopover?.buttons[1].performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.resolveConflict(id: "gone-1", field: "removed", keep: .current, conflictId: "8.1")])
    }

    func testTheHeaderChipListsLiveConflictsToo_WithAShowButtonThatScrollsToTheItem() throws {
        let h = try harness(conflicts: [conflict()], removedItems: [removed()], size: NSSize(width: 360, height: 300))
        XCTAssertEqual(h.pane.header.conflictChip?.title, "2 conflicts")
        h.pane.header.conflictChip?.performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        XCTAssertEqual(popover.sections.count, 2)
        let show = try XCTUnwrap(popover.buttons.first { $0.title == "Show" })
        h.rig.scroll(to: 900)
        show.performClick(nil)
        let row = try h.row(target)
        let top = h.pane.convert(row.bounds, from: row).minY - h.pane.scrollView.frame.minY
        XCTAssertLessThan(abs(top), 40, "the item is at the top of the board now")
    }

    func testTheHeaderChipDoesNotExistWithoutEditingOrWithoutConflicts() throws {
        let h = try harness(removedItems: [removed()])
        h.supported = false
        h.pane.render()
        XCTAssertNil(h.pane.header.conflictChip)
        XCTAssertNil(try harness().pane.header.conflictChip)
    }

    // MARK: - Focus

    func testAMouseOpenedPopoverLeavesTheComposerItsFocusAndAKeyboardOneFocusesItsFirstButton() throws {
        let h = try harness(conflicts: [conflict()])
        h.window.orderFrontRegardless()   // a popover needs a window that is on screen
        h.window.makeFirstResponder(h.rig.composer)
        let editorBefore = h.rig.composer.currentEditor()
        XCTAssertNotNil(editorBefore)
        try XCTUnwrap(try h.row(target).conflictButton).performClick(nil)
        XCTAssertTrue(h.window.firstResponder === editorBefore,
                      "the composer keeps focus (now \(String(describing: h.window.firstResponder)), key window: \(String(describing: NSApp.keyWindow)))")
        XCTAssertTrue(h.pane.activePopover?.buttons.allSatisfy { $0.refusesFirstResponder } ?? false)
        h.pane.activePopover?.close()

        let mark = try XCTUnwrap(try h.row(target).conflictButton)
        XCTAssertTrue(h.window.makeFirstResponder(mark))
        mark.performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        let first = try XCTUnwrap(popover.buttons.first)
        XCTAssertFalse(first.refusesFirstResponder)
        XCTAssertTrue(first.window?.firstResponder === first, "a key press moves focus to the first button")
        popover.close()
        XCTAssertTrue(h.window.firstResponder === mark, "Esc closes it and returns focus")
    }

    // MARK: - Sensitive badges (PRD 43)

    private func badgedHarness() throws -> TrackerEditHarness {
        try TrackerEditHarness(self) { script in
            try script.updateItem("revie-1111") { $0["sensitive"] = ["classes": ["phone"]] }
        }
    }

    func testABadgedItemShowsTheChipItsTextStaysVisibleAndTheLabelSaysWhy() throws {
        let h = try badgedHarness()
        let row = try h.row(badged)
        let chip = try XCTUnwrap(row.sensitiveButton)
        XCTAssertEqual(chip.title, "sensitive?")
        XCTAssertEqual(chip.accessibilityLabel(), "Possible sensitive data (phone number). Not shown to the agent.")
        XCTAssertEqual(chip.toolTip, chip.accessibilityLabel())
        XCTAssertTrue(row.visibleText.contains("Review queue job 8812"), "the user sees their own text")
        XCTAssertNil(try h.row(target).sensitiveButton)
    }

    func testTheReviewPopoverSaysWhatIsWithheldAndItsButtonsClearTheBadgeOrEditTheDetails() throws {
        let h = try badgedHarness()
        try XCTUnwrap(try h.row(badged).sensitiveButton).performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        XCTAssertEqual(popover.sections.first?.message,
                       "Nostromo isn't showing this item's text to the agent because it may contain a phone number.")
        XCTAssertEqual(popover.buttons.map(\.title), ["It's fine, share it", "Edit details"])
        popover.buttons[0].performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.clearBadge(id: badged)])
        XCTAssertEqual(h.sent.count, 1, "never combined with an edit in one batch")
        XCTAssertFalse(h.pane.editing.undoManager.canUndo, "clear_badge is not undoable")

        try XCTUnwrap(try h.row(badged).sensitiveButton).performClick(nil)
        h.pane.activePopover?.buttons[1].performClick(nil)
        XCTAssertNotNil(try h.row(badged).detailsEditor, "Edit details opens the details editor")
    }

    func testDroppedConflictsAreMarkedHonestlyWithoutOfferingToSettleThem() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem("revie-1111") { $0["dropped_conflicts"] = 3 }
        }
        let row = try h.row(badged)
        let mark = try XCTUnwrap(row.badges.first { $0.accessibilityLabel() == "Older conflicts were dropped" })
        XCTAssertEqual(mark.toolTip, "Older conflicts were dropped")
        XCTAssertNil(row.conflictButton, "nothing to settle: what is gone is gone")
    }

    // MARK: - Gates

    func testTheHeaderChipAppearingAndGoingMovesNothing() throws {
        let h = try harness(size: NSSize(width: 360, height: 300))
        h.rig.scroll(to: 420)
        let before = h.pane.anchorSnapshot(windowIndex: 0)
        let headerHeight = h.pane.header.frame.height
        try h.agentChange { script in
            script.setRemovedConflicts([self.removed()])
            try script.updateItem(self.target) { $0["conflicts"] = [self.conflict()] }
        }
        let during = h.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertNotNil(h.pane.header.conflictChip)
        XCTAssertEqual(h.pane.header.frame.height, headerHeight, "the header's height never changes")
        XCTAssertEqual(during.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(during.firstVisible?.offsetPt ?? -99, before.firstVisible?.offsetPt ?? 99, accuracy: 1.0)
    }

    func testResolvingAConflictAndClearingABadgeMoveTheReadingLineLessThanAPoint() throws {
        let h = try harness(conflicts: [conflict()], size: NSSize(width: 360, height: 300))
        h.rig.scroll(to: 420)
        let before = h.pane.anchorSnapshot(windowIndex: 0)
        h.pane.resolve(TrackerConflictEntry(itemId: target, field: "status", conflictId: "7.1", sentence: "", losingValue: "todo",
                                            currentValue: "in-progress", inverse: []), .current)
        try h.echo { try $0.updateItem(self.target) { $0["conflicts"] = [] } }
        h.pane.clearBadge(item: badged)
        try h.echo { try $0.updateItem(self.badged) { $0["sensitive"] = nil } }
        let after = h.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.firstVisible?.offsetPt ?? -99, before.firstVisible?.offsetPt ?? 99, accuracy: 1.0)
    }
}
