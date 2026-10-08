import AppKit
import XCTest

/// The small "Rename…" sheet for a sidebar focus. Blank means "clear the label".
final class RenameFocusSheetTests: XCTestCase {

    // MARK: - Helpers

    /// Records every `onSave` call. `[String?]` so "called with nil" is distinguishable from "not called".
    private final class SaveRecorder {
        private(set) var calls: [String?] = []
        func record(_ v: String?) { calls.append(v) }
    }

    private func makeSheet(current: String?, _ recorder: SaveRecorder) -> RenameFocusSheet {
        RenameFocusSheet(currentLabel: current, onSave: { recorder.record($0) })
    }

    private func allViews(_ root: NSView) -> [NSView] {
        var all: [NSView] = []
        func walk(_ v: NSView) { all.append(v); v.subviews.forEach(walk) }
        walk(root)
        return all
    }

    private func editableField(_ sheet: RenameFocusSheet) throws -> NSTextField {
        let content = try XCTUnwrap(sheet.window?.contentView)
        let fields = allViews(content).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        XCTAssertEqual(fields.count, 1, "exactly one editable text field")
        return try XCTUnwrap(fields.first)
    }

    // MARK: - Prefill

    func testFieldIsPrefilledWithTheCurrentLabel() {
        let sheet = makeSheet(current: "Hotfix", SaveRecorder())
        XCTAssertEqual(sheet.labelText, "Hotfix")
    }

    func testFieldIsEmptyWhenThereIsNoCurrentLabel() {
        let sheet = makeSheet(current: nil, SaveRecorder())
        XCTAssertEqual(sheet.labelText, "")
    }

    func testVisibleFieldShowsThePrefill() throws {
        let sheet = makeSheet(current: "Hotfix", SaveRecorder())
        XCTAssertEqual(try editableField(sheet).stringValue, "Hotfix")
        let empty = makeSheet(current: nil, SaveRecorder())
        XCTAssertEqual(try editableField(empty).stringValue, "")
    }

    // MARK: - View tree

    func testWindowHasAnEditableFieldAndSaveAndCancelButtons() throws {
        let sheet = makeSheet(current: nil, SaveRecorder())
        let content = try XCTUnwrap(sheet.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = allViews(content)

        XCTAssertEqual(views.compactMap { $0 as? NSTextField }.filter { $0.isEditable }.count, 1)
        let titles = views.compactMap { ($0 as? NSButton)?.title }
        XCTAssertTrue(titles.contains("Save"), "buttons: \(titles)")
        XCTAssertTrue(titles.contains("Cancel"), "buttons: \(titles)")
    }

    func testSaveAndCancelButtonsAreWiredToTheSheet() throws {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: "Hotfix", recorder)
        let content = try XCTUnwrap(sheet.window?.contentView)
        let buttons = allViews(content).compactMap { $0 as? NSButton }
        let save = try XCTUnwrap(buttons.first { $0.title == "Save" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })

        cancel.performClick(nil)
        XCTAssertTrue(recorder.calls.isEmpty, "Cancel must not save")

        save.performClick(nil)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first ?? "unset", "Hotfix")
    }

    func testTypeLabelPutsTheTextInTheVisibleField() throws {
        let sheet = makeSheet(current: nil, SaveRecorder())
        sheet.typeLabel("Refactor")
        XCTAssertEqual(sheet.labelText, "Refactor")
        XCTAssertEqual(try editableField(sheet).stringValue, "Refactor")
    }

    // MARK: - Save

    func testSaveCallsOnSaveOnceWithTheTrimmedLabel() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: nil, recorder)
        sheet.typeLabel("  Hotfix  ")
        sheet.saveTapped()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first ?? "unset", "Hotfix")
    }

    func testSaveWithBlankTextClearsTheLabelByPassingNil() {
        for blank in ["", "   ", "\n\t"] {
            let recorder = SaveRecorder()
            let sheet = makeSheet(current: "Hotfix", recorder)
            sheet.typeLabel(blank)
            sheet.saveTapped()
            XCTAssertEqual(recorder.calls.count, 1, blank.debugDescription)
            XCTAssertEqual(recorder.calls.count == 1 ? recorder.calls[0] : "unset", nil,
                           "\(blank.debugDescription) means 'clear the label'")
        }
    }

    func testSaveCapsAnOverlongLabelAtSixtyCharacters() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: nil, recorder)
        sheet.typeLabel(String(repeating: "R", count: 100))
        sheet.saveTapped()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first ?? "unset", String(repeating: "R", count: 60))
    }

    func testSaveWithoutEditingKeepsTheCurrentLabel() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: "Hotfix", recorder)
        sheet.saveTapped()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first ?? "unset", "Hotfix")
    }

    func testSaveWithoutEditingAnUnlabeledFocusPassesNil() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: nil, recorder)
        sheet.saveTapped()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.count == 1 ? recorder.calls[0] : "unset", nil)
    }

    /// What is actually in the visible field is what gets saved, not just what the seam last saw.
    func testSaveUsesWhateverIsInTheVisibleField() throws {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: "Old", recorder)
        try editableField(sheet).stringValue = "  Direct edit  "
        sheet.saveTapped()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first ?? "unset", "Direct edit")
    }

    // MARK: - Cancel

    func testCancelCallsNothing() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: "Hotfix", recorder)
        sheet.typeLabel("Something else entirely")
        sheet.cancelTapped()
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testCancelOnAFreshSheetCallsNothing() {
        let recorder = SaveRecorder()
        let sheet = makeSheet(current: nil, recorder)
        sheet.cancelTapped()
        XCTAssertTrue(recorder.calls.isEmpty)
    }
}
