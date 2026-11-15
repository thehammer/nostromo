import AppKit
import XCTest

/// The New Focus sheet's "No codebase" choice: first in the Project menu, previewed and created like any
/// other project, with its own private folder and never an org lookup or a repo path. The folder maker is
/// replaced in every test, so the real home and `~/.nostromo-spaces` are never touched.
final class NoCodebaseCreateTests: XCTestCase {

    private typealias F = HistoryFixtures
    private let fm = FileManager.default
    private var spaces: URL!
    private var store: ConversationHistoryStore!
    private var created: [Focus] = []
    private var makerCalls = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        CreateFocusSheet.rememberedTab = .new
        spaces = fm.temporaryDirectory.appendingPathComponent("nocodebase-create-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: spaces, withIntermediateDirectories: true)
        let spacesURL = spaces!
        addTeardownBlock { try? FileManager.default.removeItem(at: spacesURL) }
        store = ConversationHistoryStore(sender: RecordingHistorySender())
        created = []
        makerCalls = 0
    }

    override func tearDown() {
        CreateFocusSheet.rememberedTab = .new
        super.tearDown()
    }

    // MARK: Helpers

    /// A sheet whose org lookups all answer "Carefeed" (so an org of "Personal" can only come from the
    /// no-codebase rule) and whose folder maker makes a real folder under the temp spaces root.
    private func makeSheet(agents: [String] = ["claudia"], projects: [String] = ["/tmp/alpha", "/tmp/beta"]) -> CreateFocusSheet {
        let sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved("Carefeed") }),
                                     agents: agents, projects: projects, history: store,
                                     onCreate: { [unowned self] in created.append($0) })
        sheet.noCodebaseFolderMaker = { [unowned self] in
            makerCalls += 1
            let folder = spaces.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: false)
            return .success(folder)
        }
        return sheet
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

    private func placeholder(of sheet: CreateFocusSheet) throws -> String? {
        let content = try XCTUnwrap(sheet.window?.contentView)
        let field = try XCTUnwrap(allViews(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        return field.placeholderString
    }

    // MARK: The menu

    func testTheProjectMenuStartsWithNoCodebaseThenASeparatorThenTheRepos() {
        let sheet = makeSheet()
        XCTAssertEqual(sheet.projectMenuTitles, ["No codebase", "-", "alpha", "beta"])
    }

    func testARepoIsStillTheDefaultWhenThereAreRepos() {
        let sheet = makeSheet()
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia in Alpha", "the first repo, as before")
    }

    func testWithNoReposNoCodebaseIsTheChoiceAndCreateIsEnabled() {
        let sheet = makeSheet(projects: [])
        XCTAssertEqual(sheet.projectMenuTitles, ["No codebase", "-"])
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia (no codebase)")
        XCTAssertTrue(sheet.isCreateEnabled, "nothing to pick is no longer a dead end")
    }

    // MARK: The preview

    func testChoosingNoCodebasePreviewsTheAgentWithNoCodebaseAndCreateIsEnabled() throws {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia (no codebase)")
        XCTAssertEqual(try placeholder(of: sheet), "Claudia (no codebase)", "a blank label reads as what you will get")
        XCTAssertTrue(sheet.isCreateEnabled)
    }

    func testThePreviewFollowsTheAgentAndATypedLabel() {
        let sheet = makeSheet(agents: ["claudia", "cody"])
        sheet.selectNoCodebase()
        sheet.selectAgent(at: 1)
        XCTAssertEqual(sheet.previewText, "\u{2192} Cody (no codebase)")
        sheet.typeLabel("Scratch")
        XCTAssertEqual(sheet.previewText, "\u{2192} Scratch")
        sheet.typeLabel("")
        XCTAssertEqual(sheet.previewText, "\u{2192} Cody (no codebase)")
    }

    func testGoingBackToARepoPreviewsTheRepoAgain() {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        sheet.selectProject(at: 1)
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia in Beta")
        sheet.selectProject(at: 0)
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia in Alpha")
    }

    // MARK: Create

    func testCreatingWithNoCodebaseMakesAFocusInItsOwnFolderWithNoRepoAndTheOrgPersonal() throws {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        sheet.createTapped()
        pumpMain()

        let focus = try XCTUnwrap(created.first)
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(focus.noCodebase)
        XCTAssertNil(focus.projectPath, "no repo: everything that means the repo stays off")
        XCTAssertEqual(focus.org, "Personal", "never looked up")
        XCTAssertEqual(focus.effectiveOrg, "Personal")
        XCTAssertEqual(focus.agentTag, "claudia")
        XCTAssertFalse(focus.isBuiltIn)
        XCTAssertNil(focus.label)
        XCTAssertEqual(focus.displayName, "Claudia (no codebase)")
        let folder = try XCTUnwrap(focus.workingDirectory)
        XCTAssertEqual(URL(fileURLWithPath: folder).deletingLastPathComponent().path, spaces.path,
                       "the working directory is a child of the spaces root")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: folder, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(focus.sessionWorkingDirectory, folder, "the session and a new Terminal run there")
        XCTAssertNotNil(UUID(uuidString: focus.id), "ids stay UUIDs so the session tag derives")
    }

    func testATypedLabelSurvivesANoCodebaseCreate() throws {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        sheet.typeLabel("  Memo  ")
        sheet.createTapped()
        pumpMain()
        let focus = try XCTUnwrap(created.first)
        XCTAssertEqual(focus.label, "Memo")
        XCTAssertEqual(focus.displayName, "Memo")
        XCTAssertTrue(focus.noCodebase)
    }

    func testEachNoCodebaseCreateGetsItsOwnFolder() throws {
        let first = makeSheet(); first.selectNoCodebase(); first.createTapped()
        let second = makeSheet(); second.selectNoCodebase(); second.createTapped()
        pumpMain()
        XCTAssertEqual(created.count, 2)
        XCTAssertNotEqual(created[0].workingDirectory, created[1].workingDirectory)
        XCTAssertNotEqual(created[0].id, created[1].id)
    }

    func testPressingCreateTwiceMakesOneFolderAndOneFocus() {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        sheet.createTapped()
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(makerCalls, 1, "a second press must not leave a second empty folder behind")
    }

    func testAFolderIsOnlyMadeForNoCodebase() throws {
        let sheet = makeSheet()   // a repo is selected
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(makerCalls, 0, "choosing a repo makes no folder")
    }

    // MARK: A folder that cannot be made

    func testWhenTheFolderCannotBeMadeTheReasonShowsNoFocusIsMadeAndCreateWorksAgain() throws {
        let sheet = makeSheet()
        sheet.noCodebaseFolderMaker = { .failure(.rootInsideGitRepo) }
        sheet.selectNoCodebase()
        XCTAssertEqual(sheet.projectErrorText, "", "nothing is wrong until Create is pressed")

        sheet.createTapped()
        pumpMain()

        XCTAssertTrue(created.isEmpty, "no focus without a folder")
        XCTAssertEqual(sheet.projectErrorText, NoCodebaseFolder.Failure.rootInsideGitRepo.reason)
        XCTAssertFalse(sheet.projectErrorText.isEmpty)
        XCTAssertTrue(sheet.isCreateEnabled, "the user can fix it and try again")

        // Fixed: the same sheet creates.
        sheet.noCodebaseFolderMaker = { [unowned self] in .success(spaces.appendingPathComponent("ok", isDirectory: true)) }
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.workingDirectory, spaces.appendingPathComponent("ok", isDirectory: true).path)
    }

    func testEachFailureReasonIsShownAsItsOwnWords() {
        for failure in [NoCodebaseFolder.Failure.couldNotCreate, .rootIsSymlink, .ancestorHoldsInstructions("CLAUDE.md")] {
            let sheet = makeSheet()
            sheet.noCodebaseFolderMaker = { .failure(failure) }
            sheet.selectNoCodebase()
            sheet.createTapped()
            XCTAssertEqual(sheet.projectErrorText, failure.reason)
        }
    }

    func testTheErrorGoesAwayWhenTheProjectChanges() {
        let sheet = makeSheet()
        sheet.noCodebaseFolderMaker = { .failure(.couldNotCreate) }
        sheet.selectNoCodebase()
        sheet.createTapped()
        XCTAssertFalse(sheet.projectErrorText.isEmpty)
        sheet.selectProject(at: 0)
        XCTAssertEqual(sheet.projectErrorText, "")
    }

    func testTheErrorSitsUnderTheProjectRowInsideTheSheetAndCoversNothing() throws {
        let sheet = makeSheet(projects: [])
        sheet.noCodebaseFolderMaker = { .failure(.rootInsideGitRepo) }
        sheet.createTapped()
        let window = try XCTUnwrap(sheet.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let views = allViews(content)
        let error = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Project error" })
        let editable = try XCTUnwrap(views.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let create = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Create" })
        func frame(_ v: NSView) -> NSRect { content.convert(v.bounds, from: v) }

        XCTAssertEqual(error.stringValue, NoCodebaseFolder.Failure.rootInsideGitRepo.reason)
        XCTAssertGreaterThan(frame(error).height, 12, "the message has room to be read")
        XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame(error)), "inside the sheet")
        XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame(create)), "Create is still in the sheet")
        XCTAssertLessThan(frame(error).intersection(frame(editable)).height, 1, "it does not cover the Label field")
        XCTAssertLessThan(frame(error).intersection(frame(create)).height, 1, "or the Create button")
    }

    // MARK: Repos still create the right focus after No codebase

    func testPickingARepoAfterNoCodebaseCreatesThatRepoFocus() throws {
        let sheet = makeSheet()
        sheet.selectNoCodebase()
        sheet.selectProject(at: 1)
        sheet.createTapped()
        pumpMain()

        let focus = try XCTUnwrap(created.first)
        XCTAssertEqual(focus.projectPath, "/tmp/beta", "the second repo, not the one next to it in the menu")
        XCTAssertFalse(focus.noCodebase)
        XCTAssertNil(focus.workingDirectory)
        XCTAssertEqual(focus.org, "Carefeed", "a repo is still looked up")
        XCTAssertEqual(makerCalls, 0)
    }

    func testEachRepoCreatesAtItsOwnPath() throws {
        for (index, path) in ["/tmp/alpha", "/tmp/beta"].enumerated() {
            created = []
            let sheet = makeSheet()
            sheet.selectProject(at: index)
            sheet.createTapped()
            pumpMain()
            XCTAssertEqual(created.first?.projectPath, path, "repo \(index)")
        }
    }

    func testTheDefaultRepoCreatesAtTheFirstPath() throws {
        let sheet = makeSheet(projects: ["/tmp/only"])
        sheet.createTapped()
        pumpMain()
        XCTAssertEqual(created.first?.projectPath, "/tmp/only")
    }

    func testSelectingARepoThatDoesNotExistChangesNothing() {
        let sheet = makeSheet()
        sheet.selectProject(at: 1)
        sheet.selectProject(at: 7)
        XCTAssertEqual(sheet.previewText, "\u{2192} Claudia in Beta")
    }
}
