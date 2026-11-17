import XCTest
import AppKit
import Combine
import NostromoKit

// T3b: the tracker pane edits the board (PRD 36, 41, 43, Mac halves). Real `TrackerPaneView`s over the
// golden board, a fake sender that records every `tracker_edit` frame, and a fake daemon that answers
// the way the real one does (a new board version, then `tracker_edit_result`). Every collaborator is
// injected: no wall clock, no daemon, no UserDefaults.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Show the tick (or any control) without the features: `testWithoutTheFeaturesThePaneIsReadOnly` fails.
//  - Send `status` with the version the board has NOW instead of the one the user saw (or a stale one):
//    the base-version assertions fail.
//  - Update the row before the daemon answers (optimistic display): `…NoOptimisticDisplay` fails.
//  - Rebuild every row on an edit: `rowsUpdatedLast == 1` assertions fail.
//  - Send the legacy item's title edit without the restructure body: the restructure test fails.
//  - Close the editor when the result arrives instead of when the board does: the dimmed-until-board
//    test shows the old title.
//  - Skip the undo registration, or register the redo wrong: the undo/redo test fails.
//  - Let ⌘Z reach the composer's field editor or the window's manager: the composer-focus test fails.
//  - Skip the hold on a row with an open editor: the "agent update keeps the editor" test fails.
//  - Let the tick and the disclosure share hit area: the hit-test case fails.

private typealias Fx = TrackerPaneFx

/// One pane with a fake daemon behind it.
final class TrackerEditHarness {
    struct Sent {
        let requestId: String
        let base: UInt64
        let ops: [TrackerPaneOpWire]
    }

    private final class Box {
        var sent: [Sent] = []
        var supported = true
    }

    let rig: TrackerPaneRig
    var script: TrackerBoardScript
    /// What the pane's edit controller scheduled (the 5 s answer timeout, the 6 s notice).
    let edits: TrackerManualScheduler
    private let box: Box
    private(set) var version = 7

    var sent: [Sent] { box.sent }
    var supported: Bool {
        get { box.supported }
        set { box.supported = newValue }
    }
    var pane: TrackerPaneView { rig.pane }
    var window: NSWindow { rig.window }

    init(_ test: XCTestCase, supported: Bool = true, size: NSSize = NSSize(width: 360, height: 600),
         appearance: NSAppearance? = nil,
         configure: (inout TrackerBoardScript) throws -> Void = { _ in },
         file: StaticString = #filePath, line: UInt = #line) throws {
        let box = Box()
        box.supported = supported
        let tag = Fx.uniqueTag()
        let store = Fx.makeImmediateStore()
        let clock = TrackerManualClock(Fx.now)
        let scheduler = TrackerManualScheduler()
        let edits = TrackerManualScheduler()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TrackerEdit-\(UUID().uuidString)"))
        test.addTeardownBlock { pasteboard.releaseGlobally() }
        let pane = TrackerPaneView(
            tag: tag, store: store, now: { clock.date }, reduceMotion: { false }, pasteboard: pasteboard,
            schedule: { scheduler.schedule($0, $1) }, timeZone: Fx.utc, tickInterval: nil,
            editSupported: { box.supported },
            editSender: { _, requestId, base, _, ops in
                box.sent.append(Sent(requestId: requestId, base: base, ops: ops))
                return true
            },
            editSchedule: { edits.schedule($0, $1) })
        let hostSize = NSSize(width: size.width, height: size.height + Fx.hostPadding)
        let window = makeRigWindow(test, size: hostSize, appearance: appearance)
        let host = RigFlippedDoc(frame: NSRect(origin: .zero, size: hostSize))
        pane.frame = NSRect(origin: .zero, size: size)
        let composer = NSTextField(string: "")
        composer.frame = NSRect(x: 0, y: size.height + 3, width: size.width, height: 28)
        host.addSubview(pane)
        host.addSubview(composer)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        rig = TrackerPaneRig(window: window, host: host, pane: pane, store: store, tag: tag, clock: clock,
                             scheduler: scheduler, pasteboard: pasteboard, composer: composer)
        self.edits = edits
        self.box = box
        var script = try TrackerBoardScript(tag: tag, file: file)
        try configure(&script)
        self.script = script
        rig.push(script, file: file, line: line)
    }

    func row(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> TrackerRowView {
        try XCTUnwrap(pane.rowViews["item:\(id)"], "no row for \(id); rows: \(pane.displayedRows.map(\.key))",
                      file: file, line: line)
    }

    /// The daemon applies the last edit: the board moves to the next version with `change`, then the result.
    func echo(_ change: (inout TrackerBoardScript) throws -> Void, resultFirst: Bool = false,
              file: StaticString = #filePath, line: UInt = #line) throws {
        guard let last = sent.last else {
            XCTFail("nothing was sent", file: file, line: line)
            return
        }
        version += 1
        try change(&script)
        script.setVersion(version)
        if resultFirst {
            answer(last.requestId, ok: true, version: UInt64(version))
            rig.push(script, file: file, line: line)
        } else {
            rig.push(script, file: file, line: line)
            answer(last.requestId, ok: true, version: UInt64(version))
        }
        rig.settle()
    }

    /// A board change nobody here made (an agent, a file edit).
    func agentChange(_ change: (inout TrackerBoardScript) throws -> Void,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        version += 1
        try change(&script)
        script.setVersion(version)
        rig.push(script, file: file, line: line)
    }

    func answer(_ requestId: String, ok: Bool, version: UInt64 = 0, error: [String: Any]? = nil) {
        var object: [String: Any] = ["tag": rig.tag, "request_id": requestId, "ok": ok, "version": version]
        if let error { object["error"] = error }
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object)
        // swiftlint:disable:next force_try
        let result = try! JSONDecoder().decode(TrackerEditResultWire.self, from: data)
        rig.store.ingestEditResult(result)
        rig.settle()
    }

    /// Fire the scheduled work that was set for `delay` seconds (the answer timeout is 5).
    func fire(_ delay: TimeInterval) {
        edits.scheduled.filter { $0.delay == delay }.forEach { $0.work() }
    }

    func type(_ text: String, into editor: TrackerTitleEditor) {
        if let field = editor.currentEditor() as? NSTextView { field.string = text } else { editor.stringValue = text }
    }

    func pressReturn(in editor: TrackerTitleEditor) {
        _ = editor.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    func pressEscape(in editor: TrackerTitleEditor) {
        _ = editor.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    func commandReturn() -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }
}

final class TrackerEditingTests: XCTestCase {

    private let plain = "revie-1111"       // todo, short text, no note
    private let withNote = "check-1000"    // in progress, short text, a note: foldable
    private let longLegacy = "Rotate the signing key: the vendor rotated it on Tuesday and every consumer must refresh its "
        + "cached copy before the next deploy window opens, so this stays open."

    private func setText(_ id: String, _ text: String) -> (inout TrackerBoardScript) throws -> Void {
        { script in
            try script.updateItem(id) {
                $0["text"] = text
                $0["text_spans"] = [["kind": "text", "text": text]]
            }
        }
    }

    // MARK: - The feature gate

    func testWithoutTheFeaturesThePaneIsReadOnly() throws {
        let h = try TrackerEditHarness(self, supported: false)
        let row = try h.row(plain)
        XCTAssertNil(row.tickButton, "no tick without tracker_edit_v1 + tracker_conflict_ids_v1")
        XCTAssertEqual(row.menuItems().map(\.title), ["Copy as Markdown"], "no edit items in the menu")
        h.pane.toggleNote(item: withNote)
        let noted = try h.row(withNote)
        XCTAssertNil(noted.editTitleButton)
        XCTAssertNil(noted.statusPopUp)
        XCTAssertFalse(h.pane.showReport()["edit_enabled"] as? Bool ?? true)
        h.pane.tick(item: plain)
        h.pane.beginEdit(item: plain, kind: .title)
        XCTAssertTrue(h.sent.isEmpty, "nothing is sent, and no editor opens")
        XCTAssertNil(row.activeEditor)
    }

    func testTheFeaturesTurningOnLaterGivesEveryRowItsControls() throws {
        let h = try TrackerEditHarness(self, supported: false)
        XCTAssertNil(try h.row(plain).tickButton)
        h.supported = true
        h.pane.render()
        XCTAssertNotNil(try h.row(plain).tickButton)
    }

    // MARK: - Tick and status (PRD 36)

    func testTickAndUntickSendTheExpectedOpAgainstTheVersionTheUserSaw() throws {
        let h = try TrackerEditHarness(self)
        let tick = try XCTUnwrap(try h.row(plain).tickButton)
        tick.performClick(nil)
        XCTAssertEqual(h.sent.map(\.ops), [[.status(id: plain, status: "done")]])
        XCTAssertEqual(h.sent.first?.base, 7, "the board version the user was looking at")
        try h.echo { try $0.setStatus(plain, "done") }
        XCTAssertEqual(h.pane.rowsUpdatedLast, 1, "the daemon's board changes one row and rebuilds no other")
        XCTAssertEqual(try h.row(plain).tickButton?.title, "✓")

        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "todo")], "back to the status it had before the tick")
        XCTAssertEqual(h.sent.last?.base, 8)
    }

    func testThereIsNoOptimisticDisplay() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        XCTAssertEqual(try h.row(plain).tickButton?.title, "○", "the row shows the file's truth until the board arrives")
    }

    func testAnUntickGoesBackToTodoWhenThePaneDidNotTickIt() throws {
        let h = try TrackerEditHarness(self)
        try h.agentChange { try $0.setStatus("revie-1111", "done") }   // an agent finished it: the row stays in place, struck
        h.pane.tick(item: plain)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "todo")])
    }

    func testEachStatusFromTheMenuAndThePullDownReachesTheDaemon() throws {
        let h = try TrackerEditHarness(self)
        h.pane.toggleNote(item: withNote)
        let row = try h.row(withNote)
        let pull = try XCTUnwrap(row.statusPopUp)
        let choices = pull.menu?.items.dropFirst().filter { $0.representedObject != nil } ?? []
        XCTAssertEqual(choices.compactMap { $0.representedObject as? String },
                       ["todo", "in-progress", "blocked", "needs-you", "done"])
        for item in choices {
            guard let wire = item.representedObject as? String, wire != "in-progress" else { continue }
            h.pane.setStatus(item: withNote, to: wire)
            XCTAssertEqual(h.sent.last?.ops, [.status(id: withNote, status: wire)])
            XCTAssertEqual(h.sent.last?.base, 7)
        }
        XCTAssertEqual(h.sent.count, 4, "the current status sends nothing")

        let count = h.sent.count
        let menuChoice = try XCTUnwrap(row.editMenuItems().first { $0.title == "Status" }?.submenu?.items
            .first { ($0.representedObject as? String) == "blocked" })
        XCTAssertEqual(menuChoice.state, .off)
        XCTAssertTrue(Fx.invoke(menuChoice))
        XCTAssertEqual(h.sent.count, count + 1)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: withNote, status: "blocked")])
    }

    func testTheTickIsACheckboxAndItsCustomActionsNameWhatVoiceOverCanDo() throws {
        let h = try TrackerEditHarness(self)
        let tick = try XCTUnwrap(try h.row(plain).tickButton)
        XCTAssertEqual(tick.accessibilityRole(), .checkBox)
        XCTAssertEqual(tick.accessibilityLabel(), "Done: Review queue job 8812")
        XCTAssertEqual((tick.accessibilityValue() as? NSNumber)?.intValue, 0)
        XCTAssertEqual(tick.accessibilityHelp(), "Status: to do")
        let names = (tick.accessibilityCustomActions() ?? []).map(\.name)
        XCTAssertEqual(names, ["Edit title", "Edit details", "Set status to In progress", "Set status to Blocked",
                               "Set status to Needs you", "Set status to Done"].filter { $0 != "Set status to To do" })
        let blocked = try XCTUnwrap(tick.accessibilityCustomActions()?.first { $0.name == "Set status to Blocked" })
        XCTAssertEqual(blocked.handler?(), true)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "blocked")])

        h.pane.toggleNote(item: withNote)
        let disclosure = try XCTUnwrap(try h.row(withNote).disclosureButton)
        XCTAssertEqual(disclosure.accessibilityLabel(), "Details: Check referral 4411 duplicate")
        XCTAssertTrue((disclosure.accessibilityCustomActions() ?? []).map(\.name).contains("Edit details"))
    }

    func testCommandAndBoundItemsHaveNoTickAndNoStatusMenu() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem("revie-1111") {
                $0["bound"] = ["source": "mother.job", "as_of": TrackerPaneFx.iso(1_760_547_900), "badly_stale": false]
            }
        }
        let bound = try h.row(plain)
        XCTAssertNil(bound.tickButton)
        XCTAssertFalse(bound.editMenuItems().contains { $0.title == "Status" })
        XCTAssertTrue(bound.editMenuItems().contains { $0.title == "Edit Title" }, "its text is still the user's")

        let commands = h.script.itemNodes.filter { ($0["kind"] as? String) == "command" }.compactMap { $0["id"] as? String }
        let command = try XCTUnwrap(commands.first, "the golden board has command rows")
        let row = try h.row(command)
        XCTAssertNil(row.tickButton)
        XCTAssertFalse(row.editMenuItems().contains { $0.title == "Status" })
        h.pane.tick(item: command)
        h.pane.setStatus(item: command, to: "done")
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: - The title editor

    func testTheTitleEditorSavesOnReturnAndSendsOnlyTheTitle() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let row = try h.row(plain)
        let editor = try XCTUnwrap(row.titleEditor)
        XCTAssertEqual(editor.stringValue, "Review queue job 8812", "opens on the raw title")
        h.type("Review the queue job", into: editor)
        h.pressReturn(in: editor)
        XCTAssertEqual(h.sent.map(\.ops), [[.edit(id: plain, title: "Review the queue job", text: nil, body: nil)]])
        XCTAssertEqual(h.sent.first?.base, 7)
    }

    func testEscapeCancelsTheTitleEditorWithNoOp() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Something else", into: editor)
        h.pressEscape(in: editor)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertNil(try h.row(plain).titleEditor)
        XCTAssertTrue(h.pane.editSessions.isEmpty)
    }

    func testLosingFocusSavesAChangedTitleAndDropsAnUnchangedOne() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        XCTAssertTrue(h.window.firstResponder === editor.currentEditor(), "the editor has focus")
        h.type("Changed title", into: editor)
        h.window.makeFirstResponder(h.rig.composer)
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: "Changed title", text: nil, body: nil)],
                       "nothing typed is silently dropped")

        let h2 = try TrackerEditHarness(self)
        h2.pane.beginEdit(item: plain, kind: .title)
        h2.window.makeFirstResponder(h2.rig.composer)
        XCTAssertTrue(h2.sent.isEmpty, "an unchanged title sends nothing")
        XCTAssertNil(try h2.row(plain).titleEditor)
    }

    func testAnEmptyTitleCancelsWithANotice() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("  \n  ", into: editor)
        h.pressReturn(in: editor)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.pane.notice.text, "A title can't be empty")
    }

    func testAnOverlongTitleKeepsEveryCharacterTitleThenBody() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        let rest = String(repeating: "x", count: 90)
        h.type("Title part: \(rest)", into: editor)
        h.pressReturn(in: editor)
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: "Title part", text: nil, body: rest)],
                       "a long paste is neither cut nor refused")
    }

    func testALegacyLongItemsTitleEditRestructuresSoTheRowShowsWhatItShowed() throws {
        let cut = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let h = try TrackerEditHarness(self, configure: setText("revie-1111", cut))
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        XCTAssertEqual(editor.stringValue, TrackerTitle.editableTitle(text: cut), "no ellipsis of a cut")
        XCTAssertFalse(editor.stringValue.contains("…"))
        h.type("Renamed", into: editor)
        h.pressReturn(in: editor)
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: "Renamed", text: nil,
                                                body: TrackerTitle.rawRest(text: cut))])
        let body = try XCTUnwrap(h.sent.last?.ops.first.flatMap { op -> String? in
            if case .edit(_, _, _, let body) = op { return body }
            return nil
        })
        XCTAssertEqual(body.split(separator: " ").count + editor.original.split(separator: " ").count, 30,
                       "every word still shows: the retitled one under the fold")
    }

    func testTheTitleEditorNeverChangesExpansionOrRowHeight() throws {
        let h = try TrackerEditHarness(self, configure: setText("revie-1111", "Rotate the signing key: " + String(repeating: "body ", count: 20)))
        let row = try h.row(plain)
        let before = row.frame.height
        h.pane.beginEdit(item: plain, kind: .title)
        XCTAssertEqual(row.frame.height, before, accuracy: 0.01)
        XCTAssertFalse(h.pane.folds.expandedItems.contains(plain))
        let editor = try XCTUnwrap(row.titleEditor)
        let titleFrame = try XCTUnwrap(row.textViews.first?.frame)
        XCTAssertEqual(editor.frame.minX, titleFrame.minX, accuracy: 0.01)
        XCTAssertEqual(editor.frame.minY, titleFrame.minY, accuracy: 0.01)
        XCTAssertEqual(editor.frame.width, titleFrame.width, accuracy: 0.01, "exactly the title's frame")
        h.type("x", into: editor)
        h.pressEscape(in: editor)
        XCTAssertEqual(try h.row(plain).frame.height, before, accuracy: 0.01)
    }

    // MARK: - The details editor

    func testEditDetailsOnACollapsedRowExpandsItAndItStaysExpandedAfterSaveAndCancel() throws {
        let h = try TrackerEditHarness(self)
        XCTAssertFalse(try h.row(withNote).row.item?.isExpanded ?? true)
        h.pane.beginEdit(item: withNote, kind: .details)
        XCTAssertTrue(h.pane.folds.expandedItems.contains(withNote))
        let editor = try XCTUnwrap(try h.row(withNote).detailsEditor)
        XCTAssertEqual(editor.string, "Seen on host 14, see the log for detail", "the raw note")
        h.window.makeFirstResponder(editor)
        editor.string = "Seen on host 15"
        XCTAssertTrue(editor.performKeyEquivalent(with: h.commandReturn()), "⌘Return saves")
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: withNote, title: nil, text: nil, body: "Seen on host 15")])

        let h2 = try TrackerEditHarness(self)
        h2.pane.beginEdit(item: withNote, kind: .details)
        let editor2 = try XCTUnwrap(try h2.row(withNote).detailsEditor)
        editor2.string = "typed then cancelled"
        editor2.cancelOperation(nil)
        XCTAssertTrue(h2.sent.isEmpty, "Esc sends nothing")
        XCTAssertTrue(h2.pane.folds.expandedItems.contains(withNote), "the user asked to see the details")
        XCTAssertTrue(try h2.row(withNote).row.item?.isExpanded ?? false)
    }

    func testLosingFocusSavesAChangedDetailsEditor() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: withNote, kind: .details)
        let editor = try XCTUnwrap(try h.row(withNote).detailsEditor)
        XCTAssertTrue(h.window.firstResponder === editor)
        editor.string = "changed"
        h.window.makeFirstResponder(h.rig.composer)
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: withNote, title: nil, text: nil, body: "changed")])
    }

    func testALegacyItemsDetailsAreTheRestPlusTheNoteAndSaveRestructures() throws {
        let h = try TrackerEditHarness(self, configure: { script in
            try self.setText("check-1000", self.longLegacy)(&script)
        })
        h.pane.beginEdit(item: withNote, kind: .details)
        let editor = try XCTUnwrap(try h.row(withNote).detailsEditor)
        let rest = try XCTUnwrap(TrackerTitle.rawRest(text: longLegacy))
        XCTAssertEqual(editor.string, rest + "\n\nSeen on host 14, see the log for detail")
        editor.string = "new body"
        editor.commit()
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: withNote, title: "Rotate the signing key", text: nil, body: "new body")],
                       "the title as displayed, then the body")
    }

    func testABoundItemsSourceLineIsShownAboveTheEditorAndNotInIt() throws {
        let h = try TrackerEditHarness(self) { script in
            try script.updateItem("check-1000") {
                $0["note"] = "job 7: running\nyour own words"
                $0["bound"] = ["source": "mother.job", "as_of": TrackerPaneFx.iso(1_760_547_900), "badly_stale": false]
            }
        }
        h.pane.beginEdit(item: withNote, kind: .details)
        let row = try h.row(withNote)
        XCTAssertEqual(row.detailsEditor?.string, "your own words")
        XCTAssertTrue(Fx.allTexts(in: row).contains("job 7: running"), "the source-owned line stays visible, read-only")
    }

    func testTheDisclosureSavesADirtyDetailsEditorThenCollapses() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: withNote, kind: .details)
        let editor = try XCTUnwrap(try h.row(withNote).detailsEditor)
        editor.string = "dirty"
        h.pane.toggleNote(item: withNote)
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: withNote, title: nil, text: nil, body: "dirty")])
        XCTAssertFalse(h.pane.folds.expandedItems.contains(withNote), "then it collapses")
    }

    // MARK: - Pending, errors, timeout, holds

    func testTheEditorStaysDimmedUntilTheBoardHasTheVersionThenClosesWithoutShowingTheOldTitle() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Brand new title", into: editor)
        h.pressReturn(in: editor)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.alphaValue, 0.5, accuracy: 0.01)
        XCTAssertEqual(editor.stringValue, "Brand new title", "showing the saved text")

        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: true, version: 8)
        XCTAssertNotNil(try h.row(plain).titleEditor, "the result alone does not close it: the board has not got there")
        try h.agentChange { try $0.setText(self.plain, "Brand new title") }
        XCTAssertNil(try h.row(plain).titleEditor, "closed when the board with the version arrived")
        let shown = try h.row(plain).visibleText
        XCTAssertTrue(shown.contains("Brand new title"))
        XCTAssertFalse(shown.contains("Review queue job 8812"), "no flash of the old value")
        XCTAssertFalse(try h.row(plain).isHighlighted, "the user's own confirmed edit does not flash")
    }

    func testABoardThatArrivesBeforeTheResultIsHeldUntilTheResultCloses() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Newer", into: editor)
        h.pressReturn(in: editor)
        try h.echo({ try $0.setText(self.plain, "Newer") }, resultFirst: false)
        XCTAssertNil(try h.row(plain).titleEditor)
        XCTAssertTrue(try h.row(plain).visibleText.contains("Newer"))
        XCTAssertFalse(try h.row(plain).isHighlighted)
    }

    func testAnAgentChangeToTheSameItemWaitsForTheEditorButAnotherRowUpdatesAtOnce() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("typing in progress", into: editor)
        try h.agentChange {
            try $0.setOwner(self.plain, "agent")
            try $0.setStatus("verif-1037", "blocked")
        }
        XCTAssertEqual(h.pane.rowsUpdatedLast, 1, "only the other row was rebuilt")
        XCTAssertEqual(try h.row("verif-1037").row.item?.status, .blocked)
        XCTAssertNil(try h.row(plain).row.item?.owner, "this row waits for its editor")
        XCTAssertNotNil(try h.row(plain).titleEditor)
        XCTAssertEqual(editor.typed, "typing in progress", "text kept")
        XCTAssertTrue(h.window.firstResponder === editor.currentEditor(), "first responder kept")
    }

    func testAnErrorMakesTheEditorEditableAgainWithTheTextIntactAndSaysWhy() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("keep my words", into: editor)
        h.pressReturn(in: editor)
        h.answer(try XCTUnwrap(h.sent.last).requestId, ok: false,
                 error: ["code": "board_unreadable", "reason": "line 42"])
        XCTAssertTrue(editor.isEditable)
        XCTAssertEqual(editor.typed, "keep my words")
        XCTAssertEqual(h.pane.notice.text, "Not saved: the board file can't be read (line 42).")
        h.fire(6)
        XCTAssertNil(h.pane.notice.text, "the notice goes after 6 s")
    }

    func testFiveSecondsOfSilenceIsATimeoutNotice() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("slow", into: editor)
        h.pressReturn(in: editor)
        XCTAssertTrue(h.edits.delays.contains(5))
        h.fire(5)
        XCTAssertEqual(h.pane.notice.text, "Not saved: the daemon didn't answer in time.")
        XCTAssertTrue(editor.isEditable)
    }

    func testEveryDaemonErrorCodeHasAPlainSentence() {
        func message(_ code: String, _ reason: String? = nil) -> String {
            TrackerItemEditing.message(for: TrackerEditErrorWire(code: code, reason: reason))
        }
        XCTAssertEqual(message("board_missing"), "Not saved: the board file is gone.")
        XCTAssertEqual(message("unknown_item"), "Not saved: that item is no longer on the board.")
        XCTAssertEqual(message("not_operator_app"), "Not saved: only the Nostromo app can change the board.")
        XCTAssertEqual(message("board_too_large"), "Not saved: the board is too large to edit.")
        XCTAssertEqual(message("invalid_args", "title is too long"), "Not saved: title is too long")
        XCTAssertEqual(message("invalid_args", "that conflict is no longer kept (settled elsewhere or dropped); look again"),
                       "That conflict is no longer there: look again.")
    }

    func testFocusReturnsToTheComposerAfterAnEditor() throws {
        let h = try TrackerEditHarness(self)
        h.window.makeFirstResponder(h.rig.composer)
        let composerEditor = try XCTUnwrap(h.rig.composer.currentEditor())
        (composerEditor as? NSTextView)?.string = "half-written message"
        (composerEditor as? NSTextView)?.setSelectedRange(NSRange(location: 4, length: 3))
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("renamed", into: editor)
        h.pressReturn(in: editor)
        XCTAssertNotNil(h.rig.composer.currentEditor(), "the composer has focus again")
        XCTAssertTrue(h.window.firstResponder === h.rig.composer.currentEditor())
        XCTAssertEqual(h.rig.composer.stringValue, "half-written message")
    }

    // MARK: - Undo (⌘Z, ⇧⌘Z)

    func testAMouseTickMakesTheSinkFirstResponderAndUndoRedoSendTheInverseOps() throws {
        let h = try TrackerEditHarness(self)
        XCTAssertEqual(h.pane.undoManager?.canUndo, false)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        XCTAssertTrue(h.window.firstResponder === h.pane.sink, "so the next ⌘Z undoes this edit")
        try h.echo { try $0.setStatus(self.plain, "done") }

        XCTAssertEqual(h.pane.undoManager?.undoMenuItemTitle, "Undo Tick")
        XCTAssertTrue(h.window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) ?? false)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "todo")])
        XCTAssertEqual(h.sent.last?.base, 8, "against the board the user sees now")
        try h.echo { try $0.setStatus(self.plain, "todo") }

        XCTAssertTrue(h.window.firstResponder?.tryToPerform(Selector(("redo:")), with: nil) ?? false)
        XCTAssertEqual(h.sent.last?.ops, [.status(id: plain, status: "done")])
    }

    func testWithTheComposerFocusedCommandZDoesNotReachTheTracker() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        try h.echo { try $0.setStatus(self.plain, "done") }
        h.window.makeFirstResponder(h.rig.composer)
        let count = h.sent.count
        _ = h.rig.composer.currentEditor()?.tryToPerform(Selector(("undo:")), with: nil)
        XCTAssertEqual(h.sent.count, count, "the composer's typing undo is the composer's")
        XCTAssertTrue(h.window.undoManager !== h.pane.editing.undoManager, "never the window's manager")
    }

    func testTitleAndDetailsEditsUndoToTheOldValues() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("A new title", into: editor)
        h.pressReturn(in: editor)
        try h.echo { try $0.setText(self.plain, "A new title") }
        h.pane.performUndo()
        XCTAssertEqual(h.sent.last?.ops, [.edit(id: plain, title: nil, text: "Review queue job 8812", body: nil)])
        XCTAssertEqual(h.pane.editing.undoManager.redoMenuItemTitle, "Redo Title Edit")
    }

    func testAnUndoWhoseItemIsGoneSaysSo() throws {
        let h = try TrackerEditHarness(self)
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        try h.echo { try $0.setStatus(self.plain, "done") }
        try h.agentChange { try $0.removeItem(self.plain) }
        h.pane.performUndo()
        XCTAssertEqual(h.pane.notice.text, "Couldn't undo: the item was removed.")
        XCTAssertEqual(h.sent.count, 1)
    }

    // MARK: - Keyboard, focus and hit areas

    func testTheTabOrderIsTickThenDisclosureThenTheActionsLine() throws {
        let h = try TrackerEditHarness(self)
        h.pane.toggleNote(item: withNote)
        let row = try h.row(withNote)
        let named: [(String, NSView?)] = [("tick", row.tickButton), ("disclosure", row.disclosureButton),
                                          ("editTitle", row.editTitleButton), ("editDetails", row.editDetailsButton),
                                          ("status", row.statusPopUp)]
        let order = row.subviews.compactMap { view in named.first { $0.1 === view }?.0 }
        XCTAssertEqual(order, ["tick", "disclosure", "editTitle", "editDetails", "status"])
        for view in [row.tickButton, row.disclosureButton, row.editTitleButton, row.editDetailsButton, row.statusPopUp] {
            XCTAssertEqual(view?.refusesFirstResponder, false, "reachable with Full Keyboard Access")
        }
    }

    func testSpaceOnTheTickKeepsFocusThereAcrossTheRebuildAndSpaceOnEditTitleOpensTheEditor() throws {
        let h = try TrackerEditHarness(self)
        let tick = try XCTUnwrap(try h.row(plain).tickButton)
        XCTAssertTrue(h.window.makeFirstResponder(tick))
        tick.performClick(nil)
        XCTAssertTrue(h.window.firstResponder === tick, "a key press keeps the focus it has: no sink")
        try h.echo { try $0.setStatus(self.plain, "done") }
        let rebuilt = try h.row(plain)
        XCTAssertTrue(h.window.firstResponder === rebuilt.tickButton, "focus survives the rebuild")

        h.pane.toggleNote(item: withNote)
        let title = try XCTUnwrap(try h.row(withNote).editTitleButton)
        XCTAssertTrue(h.window.makeFirstResponder(title))
        title.performClick(nil)
        let editor = try XCTUnwrap(try h.row(withNote).titleEditor)
        h.type("From the keyboard", into: editor)
        h.pressReturn(in: editor)
        try h.echo { try $0.setText(self.withNote, "From the keyboard") }
        let again = try h.row(withNote)
        XCTAssertTrue(h.window.firstResponder === again.editTitleButton,
                      "after save, focus is back on the rebuilt row's Edit title")
    }

    func testEveryPointOfTheTickAndTheDisclosureReachesExactlyOneControl() throws {
        let h = try TrackerEditHarness(self)
        let row = try h.row(withNote)
        let tick = try XCTUnwrap(row.tickButton)
        let disclosure = try XCTUnwrap(row.disclosureButton)
        XCTAssertGreaterThanOrEqual(tick.frame.width, 20)
        XCTAssertGreaterThanOrEqual(tick.frame.height, 20)
        XCTAssertGreaterThanOrEqual(disclosure.frame.width, 20)
        XCTAssertGreaterThanOrEqual(disclosure.frame.height, 20)
        XCTAssertTrue(tick.frame.intersection(disclosure.frame).isEmpty, "the two never overlap")
        for x in stride(from: tick.frame.minX + 1, to: tick.frame.maxX, by: 3) {
            for y in stride(from: 2.0, to: 20.0, by: 4) {
                let hit = row.hitTest(row.convert(NSPoint(x: x, y: y), to: row.superview))
                XCTAssertTrue(hit === tick, "(\(x), \(y)) reaches the tick, got \(String(describing: hit))")
            }
        }
        for x in stride(from: disclosure.frame.minX + 1, to: disclosure.frame.maxX, by: 3) {
            for y in stride(from: 2.0, to: 20.0, by: 4) {
                let hit = row.hitTest(row.convert(NSPoint(x: x, y: y), to: row.superview))
                XCTAssertTrue(hit === disclosure, "(\(x), \(y)) reaches the disclosure, got \(String(describing: hit))")
            }
        }
    }

    // MARK: - The strip and the sidebar pill follow the pane

    func testTheStripAndThePillFollowAStatusChangeAndATick() throws {
        let h = try TrackerEditHarness(self)
        let before = try XCTUnwrap(h.pane.board)
        let pillBefore = TrackerNeedsYouProducer.items(tag: h.rig.tag, board: before).count
        let stripBefore = h.pane.presentation?.strip.entries.count ?? -1

        let needs = try XCTUnwrap(try h.row(plain).editMenuItems().first { $0.title == "Status" }?.submenu?.items
            .first { ($0.representedObject as? String) == "needs-you" })
        XCTAssertTrue(Fx.invoke(needs))
        try h.echo { try $0.setStatus(self.plain, "needs-you") }
        let board = try XCTUnwrap(h.pane.board)
        XCTAssertEqual(h.pane.presentation?.strip.entries.count, stripBefore + 1)
        XCTAssertTrue(h.pane.presentation?.strip.entries.contains { $0.text.contains("Review queue job 8812") } ?? false)
        XCTAssertEqual(TrackerNeedsYouProducer.items(tag: h.rig.tag, board: board).count, pillBefore + 1)

        h.pane.tick(item: plain)
        try h.echo { try $0.setStatus(self.plain, "done") }
        XCTAssertEqual(h.pane.presentation?.strip.entries.count, stripBefore)
        XCTAssertEqual(TrackerNeedsYouProducer.items(tag: h.rig.tag, board: try XCTUnwrap(h.pane.board)).count, pillBefore)
    }

    func testATitleEditOfANeedsYouItemShowsTheNewTitleInTheStripAndChangesNoCounts() throws {
        let h = try TrackerEditHarness(self) { try $0.setStatus("revie-1111", "needs-you") }
        let count = h.pane.presentation?.strip.entries.count
        let ids = TrackerNeedsYouProducer.items(tag: h.rig.tag, board: try XCTUnwrap(h.pane.board)).map(\.id)
        h.pane.beginEdit(item: plain, kind: .title)
        let editor = try XCTUnwrap(try h.row(plain).titleEditor)
        h.type("Renamed needs-you item", into: editor)
        h.pressReturn(in: editor)
        try h.echo { try $0.setText(self.plain, "Renamed needs-you item") }
        XCTAssertTrue(h.pane.presentation?.strip.entries.contains { $0.text.contains("Renamed needs-you item") } ?? false)
        XCTAssertEqual(h.pane.presentation?.strip.entries.count, count)
        XCTAssertEqual(TrackerNeedsYouProducer.items(tag: h.rig.tag, board: try XCTUnwrap(h.pane.board)).map(\.id), ids)
    }

    // MARK: - The scroll and focus gates for an edit

    func testNoEditMovesTheReadingLineMoreThanAPoint() throws {
        let h = try TrackerEditHarness(self, size: NSSize(width: 360, height: 300))
        for y in [0.0, 420.0] {
            h.rig.scroll(to: y)
            let before = h.pane.anchorSnapshot(windowIndex: 0)
            let visible = try XCTUnwrap(h.pane.displayedRows.first { row in
                guard let item = row.item, let view = h.pane.rowViews[row.key] else { return false }
                return item.isTickable && view.frame.minY > before.scrollY + 40 && view.frame.maxY < before.scrollY + 250
            }?.item?.id, "a tickable row on screen at \(y)")
            h.pane.tick(item: visible)
            try h.echo { try $0.setStatus(visible, "blocked") }
            h.pane.beginEdit(item: visible, kind: .title)
            let editor = try XCTUnwrap(try h.row(visible).titleEditor)
            h.type("Gate title \(y)", into: editor)
            h.pressReturn(in: editor)
            try h.echo { try $0.setText(visible, "Gate title \(y)") }
            h.pane.beginEdit(item: visible, kind: .details)
            let details = try XCTUnwrap(try h.row(visible).detailsEditor)
            details.string = (0..<6).map { "line \($0)" }.joined(separator: "\n")
            details.didChangeText()
            h.rig.settle()
            let after = h.pane.anchorSnapshot(windowIndex: 0)
            XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey, "at \(y)")
            XCTAssertEqual(after.firstVisible?.offsetPt ?? -99, before.firstVisible?.offsetPt ?? 99, accuracy: 1.0, "at \(y)")
            details.cancelOperation(nil)
            h.rig.settle()
        }
    }

    func testTheNoticeAppearingAndGoingKeepsTheLineBeingReadWhereItIsOnScreen() throws {
        let h = try TrackerEditHarness(self, size: NSSize(width: 360, height: 300))
        h.rig.scroll(to: 420)
        let reading = try XCTUnwrap(h.pane.displayedRows.first { row in
            guard let view = h.pane.rowViews[row.key], row.item != nil else { return false }
            let rect = h.pane.convert(view.bounds, from: view)
            return rect.minY > h.pane.scrollView.frame.minY + 20 && rect.maxY < h.pane.bounds.maxY - 20
        })
        let view = try XCTUnwrap(h.pane.rowViews[reading.key])
        let before = h.pane.convert(view.bounds, from: view).minY
        h.pane.editing.showNotice("Not saved: test")
        h.rig.settle()
        XCTAssertEqual(h.pane.convert(view.bounds, from: view).minY, before, accuracy: 1.0, "the notice appeared")
        XCTAssertGreaterThan(h.pane.notice.frame.height, 0)
        h.pane.editing.showNotice(nil)
        h.rig.settle()
        XCTAssertEqual(h.pane.convert(view.bounds, from: view).minY, before, accuracy: 1.0, "the notice went")
    }

    func testAMouseTickLeavesTheComposersTextAndSelectionAlone() throws {
        let h = try TrackerEditHarness(self)
        h.window.makeFirstResponder(h.rig.composer)
        let field = try XCTUnwrap(h.rig.composer.currentEditor() as? NSTextView)
        field.string = "typing a message"
        try XCTUnwrap(try h.row(plain).tickButton).performClick(nil)
        XCTAssertEqual(h.rig.composer.stringValue, "typing a message")
    }

    // MARK: - tracker show

    func testTrackerShowReportsTheEditingState() throws {
        let h = try TrackerEditHarness(self)
        h.pane.beginEdit(item: plain, kind: .title)
        let report = h.pane.showReport()
        XCTAssertEqual(report["edit_enabled"] as? Bool, true)
        let sections = report["sections"] as? [[String: Any]] ?? []
        let items = sections.flatMap { $0["items"] as? [[String: Any]] ?? [] }
        let item = try XCTUnwrap(items.first { ($0["id"] as? String) == plain })
        XCTAssertEqual(item["editing"] as? String, "title")
        XCTAssertEqual(item["tickable"] as? Bool, true)
        XCTAssertEqual(item["status_editable"] as? Bool, true)
        let other = try XCTUnwrap(items.first { ($0["id"] as? String) == withNote })
        XCTAssertEqual(other["editing"] as? String, "none")
    }
}
