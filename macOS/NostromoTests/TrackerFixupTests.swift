import XCTest
import AppKit
import Combine
import NostromoKit

// T3b fix-ups (Perri's review of PR #480): each case below began as a probe against the real
// `TrackerPaneView` that failed, and is now a permanent regression test.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Undo of a long item through `edit.text` (cut at 500) instead of `restore_text`: the undo-ops cases fail.
//  - A refusal wiping the whole undo history (`removeAllActions`): the history case fails.
//  - `setEditorPending(false)` taking focus unconditionally: the composer-focus cases fail.
//  - Buttons titled with the full value in one row: the popover-layout cases fail.
//  - The disclosure rect reaching over the title: the hit-test case fails at textX - 1 / textX / textX + 2.
//  - Sending the newest board version for a row that is held back: the held-row cases fail.
//  - A grapheme count for the title limit, a details save with the raw title, a stale refusal that does not
//    look again, a late `ok` that leaves an editor open, a timeout that clears the typed text.
//  - A key equivalent on any row context menu or popover button: the menu walk fails.

final class TrackerFixupTests: XCTestCase {

    private let plain = "revie-1111"       // todo, short text, no note
    private let withNote = "check-1000"    // in progress, short text, a note

    private func setText(_ id: String, _ text: String) -> (inout TrackerBoardScript) throws -> Void {
        { script in
            try script.updateItem(id) {
                $0["text"] = text
                $0["text_spans"] = [["kind": "text", "text": text]]
            }
        }
    }

    private func editOp(_ op: TrackerPaneOpWire?) -> (title: String?, text: String?, body: String?)? {
        if case .edit(_, let title, let text, let body)? = op { return (title, text, body) }
        return nil
    }

    // MARK: - 1. Undo of a long item goes through restore_text

    func testUndoOfATitleEditOnA628CharacterItemRestoresItWholeWithRestoreText() throws {
        let long = (0..<104).map { "word\($0)" }.joined(separator: " ")
        XCTAssertGreaterThan(long.count, 500)
        let h = try TrackerEditHarness(self, configure: setText(plain, long))
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Short new title", into: editor)
        h.pressReturn(in: editor)
        try h.echo { try $0.setText(self.plain, "Short new title") }
        h.pane.performUndo()
        let ops = try XCTUnwrap(h.sent.last).ops
        XCTAssertTrue(ops.contains(.restoreText(id: plain, text: long)), "the whole text goes back: \(ops)")
        XCTAssertFalse(ops.contains { editOp($0)?.text != nil }, "never through edit.text, which the daemon cuts at 500")
    }

    func testTheUseInverseOfATitleConflictRestoresWithRestoreText() throws {
        let long = String(repeating: "t", count: 70)
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) {
                $0["conflicts"] = [["conflict_id": "7.1", "field": "title", "losing": long, "losing_by": "agent claudia",
                                    "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4),
                                    "index": 0]]
            }
        }
        let item = try XCTUnwrap(try h.row(withNote).row.item)
        let entry = try XCTUnwrap(TrackerConflictEntry.entries(for: item, now: TrackerPaneFx.now).first)
        XCTAssertEqual(entry.inverse, [.restoreText(id: withNote, text: item.editText)])
    }

    // MARK: - 2. One refusal does not wipe the undo history

    func testARefusedTickLeavesTheEarlierTickUndoable() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        try h.echo { try $0.setStatus(self.plain, "done") }
        try XCTUnwrap(try h.row(withNote).tickButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        XCTAssertTrue(h.pane.editing.undoManager.canUndo, "A can still be undone")
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "todo")], "the undo is A's, not B's, and it ran")
    }

    func testARefusedEditCannotBeUndoneItself() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        let count = h.sent.count
        h.pane.performUndo()
        XCTAssertEqual(h.sent.count, count, "nothing was applied, so nothing is undone")
    }

    // MARK: - 3. A late refusal or timeout does not take focus from the composer

    private func saveTitleFromComposer(_ h: TrackerEditHarness) throws -> NSResponder {
        h.window.makeFirstResponder(h.rig.composer)
        let composerEditor = try XCTUnwrap(h.rig.composer.currentEditor())
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("renamed", into: editor)
        h.pressReturn(in: editor)
        XCTAssertTrue(h.window.firstResponder === composerEditor, "setup: focus went back to the composer on save")
        return composerEditor
    }

    func testALateRefusalLeavesFocusInTheComposer() throws {
        let h = try TrackerEditHarness(self)
        let composer = try saveTitleFromComposer(h)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_unreadable", "reason": "x"])
        XCTAssertTrue(h.window.firstResponder === composer, "now \(String(describing: h.window.firstResponder))")
        XCTAssertTrue(try h.row(plain).titleEditor?.isEditable ?? false, "the editor is editable again, without focus")
    }

    func testATimeoutLeavesFocusInTheComposerAndKeepsTheTypedText() throws {
        let h = try TrackerEditHarness(self)
        let composer = try saveTitleFromComposer(h)
        h.fire(5)
        XCTAssertTrue(h.window.firstResponder === composer)
        XCTAssertEqual(try h.row(plain).titleEditor?.typed, "renamed", "a timeout never destroys what was typed")
    }

    /// Composer focused, edit, Return, then the user clicks back into the (read-only, pending) editor and the
    /// refusal arrives: focus must end up in the editor or the composer, never on the bare window.
    func testARefusalAfterClickingBackIntoThePendingEditorLeavesFocusInAnInput() throws {
        let h = try TrackerEditHarness(self)
        let composer = try saveTitleFromComposer(h)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        _ = h.window.makeFirstResponder(editor)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        let now = h.window.firstResponder
        XCTAssertFalse(now === h.window, "focus must not be dropped onto the window")
        XCTAssertTrue(now === composer || now === editor || now === editor.currentEditor(), "now \(String(describing: now))")
    }

    func testARefusalWhileTheEditorStillHasFocusReturnsFocusToIt() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        // beginEdit already gave the editor focus. (A second makeFirstResponder(editor) here resigns and
        // re-takes it, and the resign saves the unchanged text, which closes the editor before anything is typed.)
        XCTAssertTrue(h.window.firstResponder === editor.currentEditor(), "setup: the editor has focus")
        h.type("kept", into: editor)
        h.pressReturn(in: editor)
        // The save is pending and the editor, read-only, still has the focus it had (nothing took it elsewhere).
        XCTAssertTrue(h.window.firstResponder === editor.currentEditor(), "setup: the pending editor has focus")
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        XCTAssertTrue(h.window.firstResponder === editor.currentEditor() || h.window.firstResponder === editor,
                      "an editor that owns focus keeps it")
    }

    // MARK: - Round 3: refusals, late answers, undo

    func testARefusedOlderEditLeavesNoDeadUndoEntryBehindANewerOne() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)       // B, older
        let refused = try XCTUnwrap(h.sent.last).requestId
        try XCTUnwrap(try h.row(withNote).tickButton).performClick(nil)    // A, newer
        h.answer(refused, ok: false, error: ["code": "board_missing"])
        XCTAssertTrue(h.pane.editing.undoManager.canUndo, "A can be undone")
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.status(id: withNote, status: "in-progress")], "the undo is A's")
        XCTAssertFalse(h.pane.editing.undoManager.canUndo, "B's refused entry is gone, not an \"Undo Tick\" that sends nothing")
    }

    func testTheRefusalStaysOnScreenWhileTheEditorItHeldIsOpen() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("kept", into: editor)
        h.pressReturn(in: editor)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        h.fire(6)
        XCTAssertEqual(h.pane.notice.text, "Not saved: the board file is gone.", "still there, and the editor is still open")
        XCTAssertNotNil(try h.row(plain).titleEditor)
        h.pressEscape(in: editor)
        XCTAssertNil(h.pane.notice.text)
    }

    func testALateOkAfterATimeoutKeepsWhatWasTypedSince() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Slow title", into: editor)
        h.pressReturn(in: editor)
        h.fire(5)                                                    // no answer: the editor opens up again
        h.type("Slow title, and more", into: editor)
        try h.echo({ try $0.setText(self.plain, "Slow title") }, resultFirst: false)   // the late ok
        let still = try XCTUnwrap(try h.row(plain).titleEditor, "the late ok must not close an editor with newer typing")
        XCTAssertEqual(still.typed, "Slow title, and more")
        XCTAssertTrue(still.isEditable)
        h.pressReturn(in: still)
        XCTAssertEqual(h.sent.count, 2, "what was typed since is a new edit")
        XCTAssertEqual(h.sent.last?.base, 8, "against the board the first save made")
    }

    func testUndoAfterALateOkRestoresTheTitleTheLateOkSaved() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Slow title", into: editor)
        h.pressReturn(in: editor)
        h.fire(5)
        h.type("Slow title, and more", into: editor)
        try h.echo(setText(plain, "Slow title"), resultFirst: false)   // the late ok
        let still = try XCTUnwrap(try h.row(plain).titleEditor)
        h.pressReturn(in: still)
        try h.echo(setText(plain, "Slow title, and more"))
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.restoreText(id: plain, text: "Slow title")],
                       "the second save's undo goes back to what the late ok saved, not past it")
    }

    func testAnUndoIsMadeAgainstTheVersionTheRowShowsNotTheNewestBoard() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        try h.echo { try $0.setStatus(self.plain, "done") }          // the row shows version 8
        let textView = try XCTUnwrap(try h.row(plain).textViews.first)
        XCTAssertTrue(h.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        rigSettle(0.02)
        XCTAssertNotNil(try h.row(plain).selectedTextView, "setup: a selection holds the row")
        let shown = try h.row(plain).visibleText
        try h.agentChange { script in
            try script.updateItem(self.plain) {
                $0["text"] = "Rewritten by an agent"
                $0["text_spans"] = [["kind": "text", "text": "Rewritten by an agent"]]
            }
        }
        XCTAssertEqual(h.version, 9)
        XCTAssertEqual(try h.row(plain).visibleText, shown, "setup: the selection holds the row at version 8's content")
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "todo")])
        XCTAssertEqual(h.sent.last?.base, 8, "not 9: the user never saw version 9's text")
    }

    // MARK: - 4. The text-conflict popover stays inside itself

    private func noteConflict(_ losing: String) -> [[String: Any]] {
        [["conflict_id": "7.1", "field": "note", "losing": losing, "losing_by": "agent claudia", "winning_by": "pane (you)",
          "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4), "index": 0]]
    }

    private func assertPopoverIsInsideItself(_ losing: String, field: String = "note",
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        var conflict = noteConflict(losing)
        conflict[0]["field"] = field
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) { $0["conflicts"] = conflict }
        }
        try XCTUnwrap(try h.row(withNote).conflictButton, file: file, line: line).performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover, file: file, line: line)
        let content = try XCTUnwrap(popover.contentView, file: file, line: line)
        XCTAssertEqual(content.frame.width, TrackerConflictPopover.width, accuracy: 0.5, file: file, line: line)
        XCTAssertFalse(popover.buttons.isEmpty, file: file, line: line)
        for button in popover.buttons {
            XCTAssertFalse(button.isHidden, file: file, line: line)
            XCTAssertGreaterThanOrEqual(button.frame.minX, 0, "\(button.title): left", file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxX, content.bounds.maxX, "\(button.title) ends at \(button.frame.maxX) in a \(content.bounds.width) pt popover", file: file, line: line)
            XCTAssertLessThanOrEqual(button.frame.maxY, content.bounds.maxY, "\(button.title): bottom", file: file, line: line)
            XCTAssertLessThanOrEqual(button.title.count, 20, "a short fixed label, not the value", file: file, line: line)
        }
        let labels = popover.buttons.compactMap { $0.accessibilityLabel() }.joined(separator: " | ")
        XCTAssertTrue(labels.contains(String(losing.prefix(60))), "VoiceOver reads the other value on its button: \(labels)", file: file, line: line)
        XCTAssertEqual(popover.valueViews.count, 2, "both values shown above the buttons", file: file, line: line)
        for view in popover.valueViews {
            XCTAssertGreaterThan(view.accessibilityLabel()?.count ?? 0, 10, "each value is labelled", file: file, line: line)
            XCTAssertNotNil(view.toolTip, "the full value is in its tooltip", file: file, line: line)
        }
        popover.close()
    }

    func testAPopoverWithA70CharacterTextConflictKeepsEveryButtonInside() throws {
        try assertPopoverIsInsideItself(String(repeating: "m", count: 70))
    }

    func testAPopoverWithA400CharacterConflictKeepsEveryButtonInside() throws {
        try assertPopoverIsInsideItself(String(repeating: "word ", count: 80))
    }

    func testATitleConflictPopoverKeepsEveryButtonInsideToo() throws {
        try assertPopoverIsInsideItself(String(repeating: "t", count: 70), field: "title")
    }

    func testTheHeaderChipPopoverWithALongConflictKeepsEveryButtonInside() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) { $0["conflicts"] = self.noteConflict(String(repeating: "q", count: 400)) }
        }
        h.pane.header.conflictChip?.performClick(nil)
        let popover = try XCTUnwrap(h.pane.activePopover)
        let content = try XCTUnwrap(popover.contentView)
        for button in popover.buttons {
            XCTAssertLessThanOrEqual(button.frame.maxX, content.bounds.maxX, "\(button.title) ends at \(button.frame.maxX)")
        }
        XCTAssertTrue(popover.buttons.contains { $0.title == "Show" })
        popover.close()
    }

    // MARK: - 5. The disclosure does not cover the title

    func testNoPointOfTheTitleReachesTheDisclosureOrTheTick() throws {
        let h = try TrackerEditHarness(self)
        h.pane.toggleNote(item: withNote)
        let row = try h.row(withNote)
        let title = try XCTUnwrap(row.textViews.first)
        let textX = title.frame.minX
        XCTAssertEqual(textX, TrackerRowView.textX, accuracy: 0.01)
        let tick = try XCTUnwrap(row.tickButton), disclosure = try XCTUnwrap(row.disclosureButton)
        XCTAssertLessThanOrEqual(disclosure.frame.maxX, textX + 0.001, "the disclosure ends where the title starts")
        XCTAssertGreaterThanOrEqual(tick.frame.width, 20)
        XCTAssertGreaterThanOrEqual(tick.frame.height, 20)
        for x in [textX - 1, textX, textX + 2] {
            let hit = row.hitTest(row.convert(NSPoint(x: x, y: 10), to: row.superview))
            if x >= textX {
                XCTAssertFalse(hit === disclosure || hit === tick, "x = \(x) is the title's, got \(String(describing: hit))")
            } else {
                XCTAssertTrue(hit === disclosure, "x = \(x) is the disclosure's, got \(String(describing: hit))")
            }
        }
        XCTAssertFalse(row.foldHitRect.contains(NSPoint(x: textX, y: 10)))
        XCTAssertFalse(row.foldHitRect.contains(NSPoint(x: textX + 2, y: 10)))
    }

    // MARK: - 6. An edit of a held row names the version the user saw

    /// A pane with `plain` (and `withNote`) showing version 7's content, held by a text selection while an
    /// agent changes both (version 8).
    private func heldHarness(_ id: String, expanded: Bool = false,
                             agent: ((inout TrackerBoardScript) throws -> Void)? = nil,
                             configure: @escaping (inout TrackerBoardScript) throws -> Void = { _ in })
        throws -> TrackerEditHarness {
        let h = try TrackerEditHarness(self, configure: configure)
        if expanded { h.pane.toggleNote(item: id) }   // opening a row's details lets go of a selection in it
        let row = try h.row(id)
        let textView = try XCTUnwrap(row.textViews.first)
        XCTAssertTrue(h.window.makeFirstResponder(textView))
        textView.setSelectedRange(NSRange(location: 0, length: 4))
        rigSettle(0.02)
        XCTAssertNotNil(try h.row(id).selectedTextView, "setup: a selection holds the row")
        let old = try h.row(id).visibleText
        try h.agentChange(agent ?? { script in
            try script.updateItem(id) {
                $0["text"] = "Rewritten by an agent"
                $0["text_spans"] = [["kind": "text", "text": "Rewritten by an agent"]]
            }
        })
        XCTAssertEqual(try h.row(id).visibleText, old, "setup: the held row still shows version 7's content")
        XCTAssertEqual(h.version, 8)
        return h
    }

    func testATickOfAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(plain)
        h.pane.tick(item: plain)
        XCTAssertEqual(h.sent.last?.base, 7, "not 8: the user never saw version 8's text")
    }

    func testAStatusChangeOfAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(plain)
        h.pane.setStatus(item: plain, to: "blocked")
        XCTAssertEqual(h.sent.last?.base, 7)
    }

    func testATitleEditOfAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(plain)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("My title", into: editor)
        h.pressReturn(in: editor)
        XCTAssertEqual(h.sent.last?.base, 7)
    }

    /// The row is open already, so opening the editor does not touch the selection that holds it: the row still
    /// shows version 7 and the edit is made against 7.
    func testADetailsEditOfAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(plain, expanded: true)
        h.pane.beginEdit(item: plain, kind: .details)
        let editor = try XCTUnwrap(try h.row(plain).detailsEditor)
        editor.string = "A note"
        editor.didChangeText()
        editor.commit()
        XCTAssertEqual(h.sent.last?.base, 7)
    }

    /// A collapsed held row: opening its details expands it, which lets go of the selection, so the row (and the
    /// editor's text, taken from it) is now version 8's. Version 8 is then what the user is editing, and what is sent.
    func testOpeningDetailsOnACollapsedHeldRowShowsAndEditsTheNewestVersion() throws {
        let h = try heldHarness(plain)
        h.pane.beginEdit(item: plain, kind: .details)
        XCTAssertTrue(try h.row(plain).visibleText.contains("Rewritten by an agent"), "the expand refreshed the row")
        let editor = try XCTUnwrap(try h.row(plain).detailsEditor)
        editor.string = "A note"
        editor.didChangeText()
        editor.commit()
        XCTAssertEqual(h.sent.last?.base, 8)
    }

    private let legacyRest = ": the vendor rotated it on Tuesday and every consumer must refresh its cached copy before the next "
        + "deploy window opens, so this stays open."

    /// The details editor's save and its undo are built from the row the user is editing (version 8's, after the
    /// expand let go of the hold), not from the row as it was drawn (version 7's): otherwise an agent's rename
    /// is silently reverted.
    func testEditingDetailsOnAHeldLegacyRowKeepsTheAgentsRenameAndUndoesToIt() throws {
        let renamed = "Agent renamed this one" + legacyRest
        let h = try heldHarness(plain, agent: setText(plain, renamed), configure: setText(plain, "Rotate the signing key" + legacyRest))
        h.pane.beginEdit(item: plain, kind: .details)
        let editor = try XCTUnwrap(try h.row(plain).detailsEditor)
        let rest = try XCTUnwrap(TrackerTitle.rawRest(text: renamed))
        XCTAssertEqual(editor.string, rest, "setup: the editor opened on version 8's text")
        editor.string = rest + " Also this."
        editor.didChangeText()
        editor.commit()
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: "Agent renamed this one", text: nil, body: rest + " Also this.")],
                       "the agent's title is kept, not reverted to version 7's")
        XCTAssertEqual(h.sent.last?.base, 8)
        try h.echo { _ in }
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.restoreText(id: plain, text: renamed), .edit(id: plain, title: nil, text: nil, body: "")],
                       "undo puts back version 8's text, not version 7's")
    }

    func testReplacingAnAgentsNoteOnAHeldRowUndoesToTheAgentsNote() throws {
        let h = try heldHarness(plain, agent: { try $0.updateItem(self.plain) { $0["note"] = "agent note" } })
        h.pane.beginEdit(item: plain, kind: .details)
        let editor = try XCTUnwrap(try h.row(plain).detailsEditor)
        XCTAssertEqual(editor.string, "agent note", "setup: the editor opened on version 8's note")
        editor.string = "mine"
        editor.didChangeText()
        editor.commit()
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: nil, text: nil, body: "mine")])
        try h.echo { _ in }
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: nil, text: nil, body: "agent note")],
                       "undo gives the agent's note back, it does not send an empty body")
    }

    func testResolvingAConflictOnAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(withNote) { script in
            try script.updateItem(self.withNote) {
                $0["conflicts"] = [["conflict_id": "7.1", "field": "status", "losing": "todo", "losing_by": "agent claudia",
                                    "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4),
                                    "index": 0]]
            }
        }
        try XCTUnwrap(try h.row(withNote).conflictButton).performClick(nil)
        h.pane.activePopover?.buttons[0].performClick(nil)
        XCTAssertEqual(h.sent.last?.base, 7)
    }

    func testClearingABadgeOnAHeldRowSendsTheVersionItShowed() throws {
        let h = try heldHarness(plain) { script in
            try script.updateItem(self.plain) { $0["sensitive"] = ["classes": ["phone"]] }
        }
        h.pane.clearBadge(item: plain)
        XCTAssertEqual(h.sent.last?.base, 7, "clear_badge must not approve text the user has not seen")
    }

    func testAnUnheldRowSendsTheNewestVersionAndTheBoardsEpochWhenItHasOne() throws {
        let h = try TrackerEditHarness(self) { script in script.setEpoch("run-1") }
        try h.agentChange { try $0.setOwner("verif-1037", "agent") }
        h.pane.tick(item: plain)
        XCTAssertEqual(h.sent.last?.base, 8)
        XCTAssertEqual(h.sent.last?.epoch, "run-1")
        let plainBoard = try TrackerEditHarness(self)
        plainBoard.pane.tick(item: plain)
        XCTAssertNil(plainBoard.sent.last?.epoch, "no epoch is invented")
    }

    // MARK: - 7 and 8. Titles the daemon accepts

    func testATitleOf80LettersWrittenAsLetterPlusAccentIsSplitBecauseTheDaemonCountsScalars() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        let typed = String(repeating: "e\u{301}", count: 80)
        h.type(typed, into: editor)
        h.pressReturn(in: editor)
        let op = try XCTUnwrap(editOp(h.sent.last?.ops.first))
        XCTAssertLessThanOrEqual(try XCTUnwrap(op.title).unicodeScalars.count, 80, "the title the daemon sees fits")
        XCTAssertFalse((op.body ?? "").isEmpty, "the rest is kept in the note, not lost")
        XCTAssertEqual(((op.title ?? "") + (op.body ?? "")).unicodeScalars.count, 160, "nothing was dropped")
    }

    func testALegacyDetailsSaveSendsTheNormalisedTitle() throws {
        let legacy = "Rotate\u{200B} the signing key: the vendor rotated it on Tuesday and every consumer must refresh its "
            + "cached copy before the next deploy window opens, so this stays open."
        let h = try TrackerEditHarness(self, configure: setText(plain, legacy))
        h.pane.beginEdit(item: plain, kind: .details)
        let editor = try XCTUnwrap(try h.row(plain).detailsEditor)
        editor.string = "My note"
        editor.didChangeText()
        editor.commit()
        let op = try XCTUnwrap(editOp(h.sent.last?.ops.first))
        let title = try XCTUnwrap(op.title)
        XCTAssertFalse(title.unicodeScalars.contains { $0.value == 0x200B }, "no zero-width character in the title: \(title.debugDescription)")
        XCTAssertLessThanOrEqual(title.unicodeScalars.count, 80)
        XCTAssertEqual(title, TrackerTitle.normalizedTitle(title))
    }

    // MARK: - 9. "Look again" refreshes the board

    func testAStaleRefusalShowsTheBoardAsItIsNowEvenOverATextSelection() throws {
        let h = try heldHarness(plain)
        try XCTUnwrap(try h.row(withNote).tickButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false,
                 error: ["code": "invalid_args", "reason": "base is stale", "stale": true])
        XCTAssertEqual(h.pane.notice.text, "Not saved: that changed since you looked. Look again.")
        XCTAssertTrue(try h.row(plain).visibleText.contains("Rewritten by an agent"), "the held row shows version 8 now")
    }

    func testTheOlderDaemonsStaleReasonsLookAgainToo() throws {
        let h = try heldHarness(plain)
        try XCTUnwrap(try h.row(withNote).tickButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false,
                 error: ["code": "invalid_args", "reason": "that changed since you looked; look again"])
        XCTAssertTrue(try h.row(plain).visibleText.contains("Rewritten by an agent"))
    }

    func testAnOrdinaryRefusalDoesNotReleaseTheHold() throws {
        let h = try heldHarness(plain)
        try XCTUnwrap(try h.row(withNote).tickButton).performClick(nil)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false, error: ["code": "board_missing"])
        XCTAssertFalse(try h.row(plain).visibleText.contains("Rewritten by an agent"), "only a stale refusal looks again")
    }

    // MARK: - 10. created, a late ok, a timeout

    func testARestoredItemThatComesBackUnderANewIdIsFollowed() throws {
        let removed: [String: Any] = ["conflict_id": "8.1", "item_id": "gone-1", "title": "A removed task",
                                      "losing_by": "pane (you)", "winning_by": "agent cody",
                                      "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 3),
                                      "source": "- [ ] A removed task — todo <!-- #gone-1 1760540000 -->\n"]
        let h = try TrackerEditHarness(self, size: NSSize(width: 360, height: 300)) { $0.setRemovedConflicts([removed]) }
        h.rig.scroll(to: 900)
        h.pane.header.conflictChip?.performClick(nil)
        h.pane.activePopover?.buttons[0].performClick(nil)
        try h.echo({ script in
            script.setRemovedConflicts([])
            try script.insertItem(id: "new-77", section: "now", text: "A removed task")
        }, created: ["new-77"])
        let row = try h.row("new-77")
        let rect = h.pane.convert(row.bounds, from: row)
        XCTAssertGreaterThanOrEqual(rect.minY, h.pane.scrollView.frame.minY - 1, "the restored item is on screen: \(rect)")
        XCTAssertLessThanOrEqual(rect.minY, h.pane.bounds.maxY, "the restored item is on screen: \(rect)")
    }

    func testAnOkThatArrivesAfterTheTimeoutIsTreatedAsApplied() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Slow title", into: editor)
        h.pressReturn(in: editor)
        let request = try XCTUnwrap(h.sent.last)
        h.fire(5)
        XCTAssertNotNil(try h.row(plain).titleEditor, "after the timeout the editor is open with the text")
        XCTAssertEqual(editor.typed, "Slow title")
        try h.echo({ try $0.setText(self.plain, "Slow title") }, resultFirst: false)   // the board arrives, then the late ok
        XCTAssertEqual(h.sent.count, 1, "never a blind retry")
        _ = request
        XCTAssertNil(try h.row(plain).titleEditor, "the late ok closed the editor")
        XCTAssertTrue(try h.row(plain).visibleText.contains("Slow title"), "it shows the confirmed value")
    }

    // MARK: - 11. The conflict mark's words

    func testTheConflictMarkSaysWhoSetWhatAndWhoSetItAfter() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) {
                $0["conflicts"] = [["conflict_id": "7.1", "field": "status", "losing": "in-progress", "losing_by": "agent claudia",
                                    "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4),
                                    "index": 0]]
                // "blocked", not "done": a done item folds into the Done group and has no row to read.
                $0["status"] = "blocked"
            }
        }
        let mark = try XCTUnwrap(try h.row(withNote).conflictButton)
        XCTAssertEqual(mark.accessibilityLabel(),
                       "Conflict on status: agent claudia set in progress, then you changed it; it now reads blocked")
    }

    func testTwoWindowsAreToldApartAsAnotherWindow() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) {
                $0["conflicts"] = [["conflict_id": "7.1", "field": "status", "losing": "todo", "losing_by": "pane (window b)",
                                    "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4),
                                    "index": 0]]
            }
        }
        XCTAssertTrue(try XCTUnwrap(try h.row(withNote).conflictButton?.accessibilityLabel()).contains("another window set todo"))
    }

    // MARK: - 13. The scroll gate, measured after each edit event

    func testEveryEditEventLeavesTheReadingLineWhereItWas() throws {
        for y in [0.0, 420.0] {
            let h = try TrackerEditHarness(self, size: NSSize(width: 360, height: 300)) { script in
                try script.updateItem(self.withNote) {
                    $0["conflicts"] = [["conflict_id": "7.1", "field": "status", "losing": "todo", "losing_by": "agent claudia",
                                        "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4),
                                        "index": 0]]
                }
                try script.updateItem(self.plain) { $0["sensitive"] = ["classes": ["phone"]] }
            }
            h.rig.scroll(to: y)
            func check(_ name: String) {
                h.rig.settle()
                let after = h.pane.anchorSnapshot(windowIndex: 0)
                XCTAssertEqual(after.firstVisible?.rowKey, reference.firstVisible?.rowKey, "\(name) at \(y): first visible row")
                XCTAssertEqual(after.firstVisible?.offsetPt ?? -99, reference.firstVisible?.offsetPt ?? 99, accuracy: 1.0,
                               "\(name) at \(y)")
            }
            let reference = h.pane.anchorSnapshot(windowIndex: 0)
            let id = "verif-1037"
            h.pane.tick(item: id)
            check("tick sent")
            try h.echo { try $0.setStatus(id, "done") }; check("tick applied")
            h.pane.setStatus(item: id, to: "blocked")
            try h.echo { try $0.setStatus(id, "blocked") }; check("status")
            h.pane.beginEdit(item: id, kind: .title)
            check("begin edit")
            let editor = try XCTUnwrap(try h.row(id).titleEditor)
            h.type("Gate title", into: editor)
            h.pressReturn(in: editor); check("commit title")
            try h.echo { try $0.setText(id, "Gate title") }; check("title applied")
            h.pane.beginEdit(item: id, kind: .details)
            let details = try XCTUnwrap(try h.row(id).detailsEditor)
            details.string = (0..<6).map { "line \($0)" }.joined(separator: "\n")
            details.didChangeText(); check("details typed")
            details.commit(); check("details saved")
            try h.echo { try $0.setNote(id, paragraphs: ["line"]) }; check("details applied")
            h.pane.performUndo(); check("undo")
            h.pane.resolve(TrackerConflictEntry(itemId: withNote, field: "status", conflictId: "7.1", sentence: "", losingValue: "todo",
                                                currentValue: "in-progress", inverse: []), .current)
            try h.echo { try $0.updateItem(self.withNote) { $0["conflicts"] = [] } }; check("resolve")
            h.pane.clearBadge(item: plain)
            try h.echo { try $0.updateItem(self.plain) { $0["sensitive"] = nil } }; check("clear badge")
        }
    }

    // MARK: - 14. No key equivalent on any context menu or popover button

    private func allKeyEquivalents(in menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            (item.keyEquivalent.isEmpty ? [] : ["\(item.title): \(item.keyEquivalent)"])
                + (item.submenu.map(allKeyEquivalents) ?? [])
        }
    }

    func testNoTrackerContextMenuOrPopoverButtonCarriesAKeyEquivalent() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem(self.withNote) {
                $0["conflicts"] = self.noteConflict("an older note")
            }
            try script.updateItem(self.plain) { $0["sensitive"] = ["classes": ["phone"]] }
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: h.window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        var walked = 0
        for key in h.pane.displayedRows.map(\.key) {
            guard let view = h.pane.rowViews[key], let menu = view.menu(for: event) else { continue }
            walked += 1
            XCTAssertEqual(allKeyEquivalents(in: menu), [], "row \(key)'s context menu")
        }
        XCTAssertGreaterThan(walked, 5, "the walk reached the rows' menus")
        let headerMenu = try XCTUnwrap(h.pane.header.menu(for: event))
        XCTAssertEqual(allKeyEquivalents(in: headerMenu), [])
        for opener in [try h.row(withNote).conflictButton, try h.row(plain).sensitiveButton, h.pane.header.conflictChip] {
            try XCTUnwrap(opener).performClick(nil)
            let popover = try XCTUnwrap(h.pane.activePopover)
            XCTAssertTrue(popover.buttons.allSatisfy { $0.keyEquivalent.isEmpty }, "popover buttons have no key equivalent")
            popover.close()
        }
    }
}
