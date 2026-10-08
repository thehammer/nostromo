import AppKit
import XCTest

/// The New Focus sheet gains an optional "Label:" row so several sessions of the
/// same agent in the same repo can be told apart from the moment they are made.
final class CreateFocusSheetLabelTests: XCTestCase {

    // MARK: - Helpers (small copies of the RepoOrgTests patterns; those are private there)

    /// Lookup whose per-path completion the test controls.
    private final class GatedLookup {
        private let lock = NSLock()
        private var gates: [String: DispatchSemaphore] = [:]
        var results: [String: RepoOrg.Lookup]
        init(_ results: [String: RepoOrg.Lookup] = [:]) { self.results = results }
        private func gate(_ path: String) -> DispatchSemaphore {
            lock.lock(); defer { lock.unlock() }
            if let g = gates[path] { return g }
            let g = DispatchSemaphore(value: 0)
            gates[path] = g
            return g
        }
        func lookup(_ path: String) -> RepoOrg.Lookup {
            gate(path).wait()
            return results[path] ?? .resolved(nil)
        }
        func release(path: String, _ n: Int = 1) {
            let g = gate(path)
            for _ in 0..<n { g.signal() }
        }
        func release(_ n: Int = 1) {
            for path in ["/tmp/alpha", "/tmp/beta"] { release(path: path, n) }
        }
    }

    private func makeSheet(_ g: GatedLookup, onCreate: @escaping (Focus) -> Void = { _ in }) -> CreateFocusSheet {
        CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: g.lookup),
                         agents: ["claudia"], projects: ["/tmp/alpha", "/tmp/beta"],
                         onCreate: onCreate)
    }

    /// A sheet whose org lookups answer immediately.
    private func makeImmediateSheet(onCreate: @escaping (Focus) -> Void = { _ in }) -> CreateFocusSheet {
        CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                         agents: ["claudia"], projects: ["/tmp/alpha", "/tmp/beta"],
                         onCreate: onCreate)
    }

    private func pumpMain(_ seconds: TimeInterval = 0.3) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 20)
    }

    private func allViews(_ root: NSView) -> [NSView] {
        var all: [NSView] = []
        func walk(_ v: NSView) { all.append(v); v.subviews.forEach(walk) }
        walk(root)
        return all
    }

    /// Frame of `v` in the content view's coordinate space (robust to nesting).
    private func frame(of v: NSView, in content: NSView) -> NSRect {
        content.convert(v.bounds, from: v)
    }

    private func editableFields(_ content: NSView) -> [NSTextField] {
        allViews(content).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
    }

    // MARK: - Preview

    func testLabelFieldPlaceholderIsTheCurrentDefaultName() throws {
        let sheet = makeImmediateSheet()
        let content = try XCTUnwrap(sheet.window?.contentView)
        let field = try XCTUnwrap(editableFields(content).first)
        XCTAssertEqual(field.placeholderString, "Claudia in Alpha")
    }

    func testLabelFieldPlaceholderTracksTheProjectPicker() throws {
        let sheet = makeImmediateSheet()
        let content = try XCTUnwrap(sheet.window?.contentView)
        let field = try XCTUnwrap(editableFields(content).first)

        sheet.selectProject(at: 1)

        XCTAssertEqual(field.placeholderString, "Claudia in Beta")
    }

    func testPreviewShowsTheDefaultNameWhenNoLabelIsTyped() {
        let sheet = makeImmediateSheet()
        XCTAssertEqual(sheet.previewText, "→ Claudia in Alpha")
    }

    func testPreviewShowsTheTypedLabel() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel("Hotfix")
        XCTAssertEqual(sheet.previewText, "→ Hotfix")
    }

    func testPreviewShowsTheTrimmedLabel() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel("   Hotfix \n")
        XCTAssertEqual(sheet.previewText, "→ Hotfix")
    }

    func testPreviewRevertsToTheDefaultNameWhenTheLabelIsCleared() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel("Hotfix")
        XCTAssertEqual(sheet.previewText, "→ Hotfix")
        sheet.typeLabel("")
        XCTAssertEqual(sheet.previewText, "→ Claudia in Alpha")
    }

    func testPreviewTreatsWhitespaceOnlyLabelAsNoLabel() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel("   ")
        XCTAssertEqual(sheet.previewText, "→ Claudia in Alpha")
    }

    func testPreviewCapsAnOverlongLabel() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel(String(repeating: "x", count: 100))
        XCTAssertEqual(sheet.previewText, "→ " + String(repeating: "x", count: 60))
    }

    func testTypedLabelSurvivesChangingTheProject() {
        let sheet = makeImmediateSheet()
        sheet.typeLabel("Hotfix")
        sheet.selectProject(at: 1)
        XCTAssertEqual(sheet.previewText, "→ Hotfix")
    }

    func testTypedLabelSurvivesALateOrgLookupCompleting() {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed")])
        let sheet = makeSheet(g)
        sheet.typeLabel("Hotfix")

        g.release(path: "/tmp/alpha")   // the org lookup lands after the user typed
        pumpMain()

        XCTAssertEqual(sheet.previewText, "→ Hotfix",
                       "a finishing background lookup must not overwrite what the user typed")
    }

    // MARK: - Created focus

    private func create(typing text: String?, file: StaticString = #filePath, line: UInt = #line) -> Focus? {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed")])
        var created: [Focus] = []
        let sheet = makeSheet(g) { created.append($0) }
        if let text { sheet.typeLabel(text) }
        sheet.createTapped()
        g.release(2)
        pumpMain()
        XCTAssertEqual(created.count, 1, file: file, line: line)
        return created.first
    }

    func testCreatingWithoutTypingALabelYieldsNoLabel() {
        let focus = create(typing: nil)
        XCTAssertNotNil(focus)
        XCTAssertNil(focus?.label)
    }

    func testCreatingWithBlankOrWhitespaceLabelYieldsNoLabel() {
        for blank in ["", "   ", "\n", " \t "] {
            let focus = create(typing: blank)
            XCTAssertNotNil(focus, blank.debugDescription)
            XCTAssertNil(focus?.label, "\(blank.debugDescription) must not become a label")
        }
    }

    func testCreatingWithTypedLabelYieldsTheTrimmedLabel() {
        XCTAssertEqual(create(typing: "Hotfix")?.label, "Hotfix")
        XCTAssertEqual(create(typing: "  Login flow  ")?.label, "Login flow")
    }

    func testCreatingWithOverlongLabelCapsItAtSixtyCharacters() {
        let focus = create(typing: String(repeating: "L", count: 100))
        XCTAssertEqual(focus?.label, String(repeating: "L", count: 60))
    }

    func testLabelDoesNotDisturbTheRestOfTheCreatedFocus() {
        let focus = create(typing: "Hotfix")
        XCTAssertEqual(focus?.agentTag, "claudia")
        XCTAssertEqual(focus?.projectPath, "/tmp/alpha")
        XCTAssertEqual(focus?.org, "Carefeed")
        XCTAssertEqual(focus?.isBuiltIn, false)
        XCTAssertEqual(focus?.displayName, "Hotfix")
        XCTAssertNotNil(focus.flatMap { UUID(uuidString: $0.id) }, "ids stay UUIDs so sessionTag derives")
    }

    func testTwoCreationsForTheSameAgentAndProjectProduceDistinctFocuses() {
        let a = create(typing: "One")
        let b = create(typing: "Two")
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.id, b?.id)
        XCTAssertNotEqual(a?.sessionTag, b?.sessionTag)
    }

    /// The text actually sitting in the field is what gets saved — not just what
    /// the `typeLabel` test seam last saw.
    func testWhateverIsInTheLabelFieldWhenCreateIsTappedBecomesTheLabel() throws {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed")])
        var created: [Focus] = []
        let sheet = makeSheet(g) { created.append($0) }
        let content = try XCTUnwrap(sheet.window?.contentView)
        let field = try XCTUnwrap(editableFields(content).first)

        field.stringValue = "  From the field  "
        sheet.createTapped()
        g.release(2)
        pumpMain()

        XCTAssertEqual(created.first?.label, "From the field")
    }

    func testTypeLabelPutsTheTextInTheVisibleField() throws {
        let sheet = makeImmediateSheet()
        let content = try XCTUnwrap(sheet.window?.contentView)
        let field = try XCTUnwrap(editableFields(content).first)
        sheet.typeLabel("Hotfix")
        XCTAssertEqual(field.stringValue, "Hotfix")
    }

    // MARK: - Layout

    func testLabelRowSitsBetweenProjectRowAndPreviewAndEverythingFits() throws {
        let sheet = makeImmediateSheet()
        let window = try XCTUnwrap(sheet.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let views = allViews(content)

        let textFields = views.compactMap { $0 as? NSTextField }
        let projectLabel = try XCTUnwrap(textFields.first { $0.stringValue == "Project:" })
        let labelLabel = try XCTUnwrap(textFields.first { $0.stringValue == "Label:" }, "a static \"Label:\" caption")
        XCTAssertFalse(labelLabel.isEditable)
        let fields = editableFields(content)
        XCTAssertEqual(fields.count, 1, "exactly one editable text field: the label")
        let field = try XCTUnwrap(fields.first)
        let preview = try XCTUnwrap(textFields.first { $0.font?.pointSize == 11 && $0 !== field })

        let projectFrame = frame(of: projectLabel, in: content)
        let captionFrame = frame(of: labelLabel, in: content)
        let fieldFrame = frame(of: field, in: content)
        let previewFrame = frame(of: preview, in: content)
        let labelRow = captionFrame.union(fieldFrame)

        // Same row: the caption and the field overlap vertically, field to the right.
        XCTAssertTrue(captionFrame.minY < fieldFrame.maxY && fieldFrame.minY < captionFrame.maxY,
                      "caption \(captionFrame) and field \(fieldFrame) should share a row")
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, captionFrame.maxX - 0.5)

        // Order top to bottom (AppKit y grows upward): Project, Label, preview.
        XCTAssertLessThanOrEqual(labelRow.maxY, projectFrame.minY + 0.5, "Label row is below Project")
        XCTAssertLessThanOrEqual(previewFrame.maxY, labelRow.minY + 0.5, "preview is below the Label row")

        // The field is a usable size.
        XCTAssertGreaterThanOrEqual(fieldFrame.width, 100)
        XCTAssertGreaterThanOrEqual(fieldFrame.height, 14)

        // Buttons are below the preview and nothing is clipped by the window.
        // NSPopUpButton is an NSButton subclass; only the push buttons (Create / Cancel) sit at the bottom.
        let buttons = views.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
        XCTAssertGreaterThanOrEqual(buttons.count, 2, "Create and Cancel")
        for b in buttons {
            let bf = frame(of: b, in: content)
            XCTAssertLessThanOrEqual(bf.maxY, previewFrame.minY + 0.5,
                                     "button \(b.title) \(bf) overlaps the preview \(previewFrame)")
        }
        let bounds = content.bounds
        var checked: [NSView] = [projectLabel, labelLabel, field, preview]
        checked.append(contentsOf: buttons)
        for v in checked {
            let f = frame(of: v, in: content)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(f),
                          "\(type(of: v)) frame \(f) is clipped by the content bounds \(bounds)")
        }
    }

    func testAllInteractiveRowsStillFitInsideTheWindowContent() throws {
        let sheet = makeImmediateSheet()
        let content = try XCTUnwrap(sheet.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let controls = allViews(content).filter {
            $0 is NSPopUpButton || $0 is NSButton || (($0 as? NSTextField)?.isEditable == true)
        }
        XCTAssertGreaterThanOrEqual(controls.count, 5, "agent popup, project popup, label field, Create, Cancel")
        for i in 0..<controls.count {
            for j in (i + 1)..<controls.count {
                let a = frame(of: controls[i], in: content)
                let b = frame(of: controls[j], in: content)
                XCTAssertTrue(a.intersection(b).isNull || a.intersection(b).isEmpty
                              || a.intersection(b).width < 1 || a.intersection(b).height < 1,
                              "controls overlap: \(a) vs \(b)")
            }
        }
    }
}
