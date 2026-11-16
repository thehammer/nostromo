import AppKit
import XCTest

/// Resuming a conversation that ran with no codebase, and resuming one whose folder is gone into a new
/// empty folder: the focus that comes back, the choice the user is offered (and its keyboard), what goes
/// to the daemon, and that nothing is made or sent until the user has actually chosen.
final class NoCodebaseResumeTests: XCTestCase {

    private typealias F = HistoryFixtures
    private let fm = FileManager.default
    private var sender: RecordingHistorySender!
    private var focusStore: FocusStore!
    private var store: ConversationHistoryStore!
    private var committed: [Focus] = []
    private var scheduled: [(TimeInterval, () -> Void)] = []

    override func setUp() {
        super.setUp()
        CreateFocusSheet.rememberedTab = .new
        sender = RecordingHistorySender()
        let url = fm.temporaryDirectory.appendingPathComponent("focuses-\(UUID().uuidString).json")
        focusStore = FocusStore(storageURL: url)
        committed = []
        scheduled = []
        var n = 0
        store = ConversationHistoryStore(
            sender: sender, focusStore: { [unowned self] in focusStore },
            makeRequestId: { n += 1; return "req\(n)" }, makeFocusId: { "ABCDEF12-0000-0000-0000-000000000000" },
            now: { F.now }, schedule: { [unowned self] d, w in scheduled.append((d, w)) })
        store.commitFocus = { [unowned self] in committed.append($0) }
        // Never the real clean-up: it would look at the real spaces root.
        store.noCodebaseSweeper = { _, _ in }
    }

    override func tearDown() {
        CreateFocusSheet.rememberedTab = .new
        super.tearDown()
    }

    // MARK: Fixtures

    private func ncEntry(_ id: String = "nc1", folder: String = "/spaces/OLD", status: ConversationStatusWire = .available,
                         agent: String = "claudia") -> ConversationEntryWire {
        var e = F.entry(id, agent: agent, project: nil, status: status, noCodebase: true)
        e.projectName = "No codebase"
        e.projectPath = folder
        return e
    }

    private func goneRepoEntry(_ id: String = "g1", main: String? = "/Users/x/Code/nostromo",
                               worktree: Bool = true) -> ConversationEntryWire {
        var e = F.entry(id, status: .folderGone(worktree: worktree), mainCheckout: main)
        e.projectPath = "/Users/x/Code/nostromo-feature-x"
        return e
    }

    private func reply(_ outcome: String = "ready", requestId: String = "req1", tag: String? = "claudia-ABCDEF12",
                       reason: String? = nil, agent: String? = "claudia", project: String? = nil) -> ServerMsg {
        var j: [String: Any] = ["request_id": requestId, "outcome": outcome]
        if outcome != "refused" {
            if let tag { j["tag"] = tag }
            if let agent { j["agent"] = agent }
            if let project { j["project_path"] = project }
        }
        if let reason { j["reason"] = reason }
        let w = try! JSONDecoder().decode(ConversationResumeResultWire.self, from: JSONSerialization.data(withJSONObject: j))
        return .conversationResumeResult(w)
    }

    // MARK: Criterion 36: a no-codebase conversation comes back as a no-codebase focus

    func testResumingANoCodebaseEntryBuildsANoCodebaseFocusInTheSameFolder() throws {
        store.ingest(.conversationHistory(F.history([ncEntry(folder: "/spaces/OLD")])))
        store.resume("nc1")
        store.ingest(reply(project: "/spaces/OLD"))

        let focus = try XCTUnwrap(committed.first)
        XCTAssertEqual(committed.count, 1)
        XCTAssertTrue(focus.noCodebase)
        XCTAssertEqual(focus.workingDirectory, "/spaces/OLD", "the same folder")
        XCTAssertNil(focus.projectPath, "never a repo")
        XCTAssertEqual(focus.org, "Personal")
        XCTAssertEqual(focus.agentTag, "claudia")
        XCTAssertEqual(focus.sessionWorkingDirectory, "/spaces/OLD")
        XCTAssertEqual(focus.resumedAt, F.now)
        XCTAssertEqual(focus.sessionTag, "claudia-ABCDEF12")
        XCTAssertEqual(sender.resumeNoCodebaseFolders, [nil], "its own folder exists: no new folder is asked for")
        XCTAssertEqual(sender.resumePlaces, [nil])
    }

    func testResumingARepoEntryStillBuildsARepoFocus() throws {
        store.ingest(.conversationHistory(F.history([F.entry("r1", agent: "cody")])))
        store.resume("r1")
        store.ingest(reply(tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/nostromo"))
        let focus = try XCTUnwrap(committed.first)
        XCTAssertFalse(focus.noCodebase)
        XCTAssertEqual(focus.projectPath, "/tmp/nostromo")
        XCTAssertNil(focus.workingDirectory)
    }

    func testAnEntryThatIsGoneAndWasNoCodebaseResumedIntoANewFolderUsesTheNewOne() throws {
        store.ingest(.conversationHistory(F.history([ncEntry(folder: "/spaces/OLD", status: .folderGone(worktree: false))])))
        store.resume("nc1", noCodebaseFolder: "/spaces/NEW")
        store.ingest(reply(project: "/spaces/NEW"))
        let focus = try XCTUnwrap(committed.first)
        XCTAssertTrue(focus.noCodebase)
        XCTAssertEqual(focus.workingDirectory, "/spaces/NEW", "the new folder, not the gone one")
    }

    // MARK: Resuming into a new folder

    func testAGoneRepoConversationResumedIntoANewFolderBecomesANoCodebaseFocus() throws {
        store.ingest(.conversationHistory(F.history([goneRepoEntry()])))
        store.resume("g1", noCodebaseFolder: "/spaces/NEW")
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW"], "the new folder goes to the daemon")
        XCTAssertEqual(sender.resumePlaces, [nil], "and not as a place in a repo")

        store.ingest(reply(project: "/spaces/NEW"))
        let focus = try XCTUnwrap(committed.first)
        XCTAssertTrue(focus.noCodebase, "the conversation now has no codebase")
        XCTAssertEqual(focus.workingDirectory, "/spaces/NEW")
        XCTAssertNil(focus.projectPath, "the old repo is not kept")
        XCTAssertEqual(focus.org, "Personal")
    }

    func testTheNewFolderIsUsedEvenWhenTheReplyNamesNoPath() throws {
        store.ingest(.conversationHistory(F.history([goneRepoEntry()])))
        store.resume("g1", noCodebaseFolder: "/spaces/NEW")
        store.ingest(reply(project: nil))
        let focus = try XCTUnwrap(committed.first)
        XCTAssertTrue(focus.noCodebase)
        XCTAssertEqual(focus.workingDirectory, "/spaces/NEW")
        XCTAssertNil(focus.projectPath)
    }

    func testAnOrdinaryResumeSendsNoFolder() {
        store.ingest(.conversationHistory(F.history([F.entry("r1")])))
        store.resume("r1")
        XCTAssertEqual(sender.resumeNoCodebaseFolders, [nil])
    }

    func testTheSameNewFolderIsSentAgainWhenTheDaemonSaysItIsStarting() {
        store.ingest(.conversationHistory(F.history([goneRepoEntry()])))
        store.resume("g1", noCodebaseFolder: "/spaces/NEW")
        store.ingest(reply("refused", reason: "starting"))
        XCTAssertEqual(scheduled.count, 1)
        scheduled.removeFirst().1()
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW", "/spaces/NEW"],
                       "a retry never makes a second folder")
    }

    func testTheFrameCarriesTheFolderOnlyWhenOneWasChosen() throws {
        func object(_ frame: ClientConversationResume) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        }
        XCTAssertNil(try object(ClientConversationResume(requestId: "r", id: "s", newTag: "t"))["no_codebase_folder"])
        let chosen = try object(ClientConversationResume(requestId: "r", id: "s", newTag: "t",
                                                         noCodebaseFolder: "/spaces/NEW"))
        XCTAssertEqual(chosen["no_codebase_folder"] as? String, "/spaces/NEW")
        XCTAssertNil(chosen["place"])
    }

    // MARK: What the daemon says about no-codebase conversations

    func testAnEntryThatRanWithNoCodebaseSaysSoAndOlderDaemonsSayNothing() throws {
        let yes = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"no_codebase":true,"status":{"kind":"available"}}"#
        let no = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"status":{"kind":"available"}}"#
        XCTAssertTrue(try JSONDecoder().decode(ConversationEntryWire.self, from: Data(yes.utf8)).noCodebase)
        XCTAssertFalse(try JSONDecoder().decode(ConversationEntryWire.self, from: Data(no.utf8)).noCodebase)
    }

    func testTheListingNamesTheFoldersStillInUseAndAnOlderDaemonDoesNot() throws {
        let with = #"{"request_id":"r","entries":[],"first_prompts_enabled":true,"revision":1,"referenced_space_folders":["/spaces/A","/spaces/B"]}"#
        let without = #"{"request_id":"r","entries":[],"first_prompts_enabled":true,"revision":1}"#
        XCTAssertEqual(try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(with.utf8)).referencedSpaceFolders,
                       ["/spaces/A", "/spaces/B"])
        XCTAssertNil(try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(without.utf8)).referencedSpaceFolders,
                     "absent is not the same as empty: the clean-up must not run on it")
    }

    // MARK: The choice

    func testAGoneWorktreeWithAMainCheckoutOffersBothWaysAndMainStaysTheDefault() throws {
        let choice = try XCTUnwrap(ResumeChoice.make(for: goneRepoEntry()))
        XCTAssertEqual(choice.buttons.map(\.title),
                       ["Resume in nostromo", "Resume with no codebase", "Cancel", "Show Transcript in Finder"])
        XCTAssertEqual(choice.outcome(forButtonIndex: 0), .resumeInMain("/Users/x/Code/nostromo"))
        XCTAssertEqual(choice.outcome(forButtonIndex: 1), .resumeWithNoCodebase)
        XCTAssertEqual(choice.outcome(forButtonIndex: 2), .cancel)
        XCTAssertEqual(choice.outcome(forButtonIndex: 3), .showTranscript)
    }

    func testWithNoMainCheckoutResumeWithNoCodebaseIsTheOnlyResumeOption() throws {
        let choice = try XCTUnwrap(ResumeChoice.make(for: goneRepoEntry(main: nil)))
        XCTAssertEqual(choice.buttons.map(\.title), ["Resume with no codebase", "Cancel", "Show Transcript in Finder"])
        XCTAssertEqual(choice.outcome(forButtonIndex: 0), .resumeWithNoCodebase, "Return picks it")
        XCTAssertFalse(choice.buttons.contains { if case .resumeInMain = $0.outcome { return true } else { return false } })
        XCTAssertTrue(choice.detail.contains("no codebase"), "it says what will happen: \(choice.detail)")
    }

    func testAGoneProjectFolderThatIsNotAWorktreeCanStillResumeWithNoCodebase() throws {
        let choice = try XCTUnwrap(ResumeChoice.make(for: goneRepoEntry(main: "/Users/x/Code/nostromo", worktree: false)))
        XCTAssertEqual(choice.buttons.map(\.title), ["Resume with no codebase", "Cancel", "Show Transcript in Finder"],
                       "a plain folder has no main checkout to offer")
        XCTAssertEqual(choice.outcome(forButtonIndex: 0), .resumeWithNoCodebase)
    }

    func testAGoneNoCodebaseFolderOffersANewOneAndNeverAMainCheckout() throws {
        var e = ncEntry(status: .folderGone(worktree: true))
        e.mainCheckout = "/Users/x/Code/nostromo"   // whatever the daemon sent, a no-codebase entry has no repo
        let choice = try XCTUnwrap(ResumeChoice.make(for: e))
        XCTAssertEqual(choice.buttons.map(\.title), ["Resume with no codebase", "Cancel", "Show Transcript in Finder"])
        XCTAssertTrue(choice.message.contains("no-codebase folder no longer exists"), choice.message)
        XCTAssertFalse(choice.detail.lowercased().contains("main checkout"), choice.detail)
    }

    func testTheKeyboardReturnIsTheFirstButtonEscIsCancelAndTheNewButtonIsReachable() throws {
        for (name, entry) in [("with a main checkout", goneRepoEntry()), ("without one", goneRepoEntry(main: nil))] {
            let choice = try XCTUnwrap(ResumeChoice.make(for: entry))
            let alert = choice.alert()
            let titles = alert.buttons.map(\.title)
            let newIndex = try XCTUnwrap(titles.firstIndex(of: "Resume with no codebase"), name)
            let cancelIndex = try XCTUnwrap(titles.firstIndex(of: "Cancel"), name)

            XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return is the first button: \(name)")
            XCTAssertEqual(alert.buttons[cancelIndex].keyEquivalent, "\u{1b}", "Esc is Cancel: \(name)")
            XCTAssertFalse(choice.escapeCancelsFirstButton, "Cancel is not first, so the buttons' own keys serve: \(name)")
            XCTAssertEqual(choice.outcome(forButtonIndex: cancelIndex), .cancel, name)

            let button = alert.buttons[newIndex]
            XCTAssertTrue(button.isEnabled, "reachable: \(name)")
            XCTAssertFalse(button.isHidden, name)
            if newIndex != 0 {
                XCTAssertNotEqual(button.keyEquivalent, "\r", "it never takes Return from the default: \(name)")
            }
            XCTAssertNotEqual(button.keyEquivalent, "\u{1b}", "or Esc from Cancel: \(name)")
            let spoken = button.accessibilityLabel() ?? ""
            XCTAssertTrue(spoken.lowercased().contains("no codebase"), "VoiceOver says what it does: \(spoken)")
            XCTAssertGreaterThan(spoken.count, button.title.count - 1)
            XCTAssertFalse(spoken.contains("\u{22EF}"))
        }
    }

    func testNoTwoButtonsShareAKeyEquivalent() throws {
        for entry in [goneRepoEntry(), goneRepoEntry(main: nil), ncEntry(status: .folderGone(worktree: false))] {
            let keys = try XCTUnwrap(ResumeChoice.make(for: entry)).alert().buttons.map(\.keyEquivalent).filter { !$0.isEmpty }
            XCTAssertEqual(keys.count, Set(keys).count, "keys: \(keys)")
        }
    }

    func testAGoneFolderRowCanBeResumedFromTheList() {
        XCTAssertTrue(ResumeTabView.isResumable(goneRepoEntry(worktree: false)))
        XCTAssertTrue(ResumeTabView.isResumable(goneRepoEntry(worktree: true)))
        XCTAssertTrue(ResumeTabView.isResumable(ncEntry(status: .folderGone(worktree: false))))
    }

    // MARK: Through the sheet

    private var sheet: CreateFocusSheet!
    private var makerCalls = 0

    private func makeSheet(maker: (() -> Result<URL, NoCodebaseFolder.Failure>)? = nil) {
        let sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                                     agents: ["claudia"], projects: ["/tmp/alpha"], history: store, onCreate: { _ in })
        makerCalls = 0
        sheet.noCodebaseFolderMaker = { [unowned self] in
            makerCalls += 1
            return maker?() ?? .success(URL(fileURLWithPath: "/spaces/NEW-\(makerCalls)", isDirectory: true))
        }
        self.sheet = sheet
    }

    private func answering(_ answers: [ResumeChoice.Outcome]) -> () -> [ResumeChoice] {
        var asked: [ResumeChoice] = []
        var remaining = answers
        sheet.choicePresenter = { choice, done in
            asked.append(choice)
            if !remaining.isEmpty { done(remaining.removeFirst()) }
        }
        return { asked }
    }

    private func open(_ e: ConversationEntryWire) {
        store.ingest(.conversationHistory(F.history([e])))
        sheet.selectTab(.resume)
        sheet.resumeTab.resumeSelected()
    }

    func testChoosingResumeWithNoCodebaseMakesANewFolderAndSendsItWithTheResume() {
        makeSheet()
        let asked = answering([.resumeWithNoCodebase])
        open(goneRepoEntry(main: nil))
        XCTAssertEqual(asked().count, 1)
        XCTAssertEqual(makerCalls, 1)
        XCTAssertEqual(sender.resumes.count, 1)
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW-1"])
        XCTAssertEqual(sender.resumePlaces, [nil])
        XCTAssertEqual(sender.resumeConfirms, [false])
    }

    func testResumeWithNoCodebaseWorksWhenAMainCheckoutWasAlsoOffered() {
        makeSheet()
        _ = answering([.resumeWithNoCodebase])
        open(goneRepoEntry())
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW-1"])
        XCTAssertEqual(sender.resumePlaces, [nil], "not the main checkout")
    }

    func testAPlainGoneFolderResumesWithNoCodebaseFromTheList() {
        makeSheet()
        _ = answering([.resumeWithNoCodebase])
        open(goneRepoEntry(worktree: false))
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW-1"])
    }

    func testCancellingMakesNoFolderAndSendsNothing() {
        makeSheet()
        _ = answering([.cancel])
        open(goneRepoEntry(main: nil))
        XCTAssertEqual(makerCalls, 0, "no folder is made until the user chooses")
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testNothingIsMadeOrSentWhileTheChoiceIsStillOpen() {
        makeSheet()
        _ = answering([])
        open(goneRepoEntry(main: nil))
        XCTAssertEqual(makerCalls, 0)
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testAFolderThatCannotBeMadeShowsWhyAndSendsNothing() {
        makeSheet(maker: { .failure(.rootInsideGitRepo) })
        _ = answering([.resumeWithNoCodebase])
        open(goneRepoEntry(main: nil))
        XCTAssertTrue(sender.resumes.isEmpty, "nothing is asked of the daemon without a folder")
        XCTAssertEqual(sheet.resumeTab.messageText, NoCodebaseFolder.Failure.rootInsideGitRepo.reason)
    }

    func testAfterAFailureTheRowCanBeResumedAgain() {
        var fail = true
        makeSheet(maker: { fail ? .failure(.couldNotCreate) : .success(URL(fileURLWithPath: "/spaces/OK", isDirectory: true)) })
        _ = answering([.resumeWithNoCodebase, .resumeWithNoCodebase])
        open(goneRepoEntry(main: nil))
        XCTAssertTrue(sender.resumes.isEmpty)
        fail = false
        sheet.resumeTab.resumeSelected()
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/OK"], "the failed attempt left the row free")
    }

    func testAGoneWorktreeThatMayBeOpenElsewhereAsksTwiceAndMakesTheFolderOnlyAfterTheSecondAnswer() {
        makeSheet()
        var e = goneRepoEntry(main: nil)
        e.status = .folderGone(worktree: true, activeElsewhere: true)
        let asked = answering([.resumeWithNoCodebase, .resumeAnyway])
        open(e)
        XCTAssertEqual(asked().count, 2)
        XCTAssertEqual(asked()[1].buttons.map(\.title), ["Cancel", "Resume anyway"])
        XCTAssertEqual(makerCalls, 1)
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW-1"])
        XCTAssertEqual(sender.resumeConfirms, [true])
    }

    func testCancellingTheOpenElsewhereQuestionMakesNoFolderAtAll() {
        makeSheet()
        var e = goneRepoEntry(main: nil)
        e.status = .folderGone(worktree: true, activeElsewhere: true)
        _ = answering([.resumeWithNoCodebase, .cancel])
        open(e)
        XCTAssertEqual(makerCalls, 0, "no empty folder is left behind by a resume that was not confirmed")
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testAStaleOpenElsewhereRefusalResendsTheSameNewFolderWithTheConfirmation() {
        makeSheet()
        let asked = answering([.resumeWithNoCodebase, .resumeAnyway])
        open(goneRepoEntry(main: nil))
        XCTAssertEqual(sender.resumes.count, 1)

        store.ingest(reply("refused", requestId: sender.resumes.last!.requestId, reason: "active_elsewhere"))
        XCTAssertEqual(asked().count, 2, "it asked, rather than showing an error")
        XCTAssertEqual(sender.resumes.count, 2)
        XCTAssertEqual(sender.resumeNoCodebaseFolders, ["/spaces/NEW-1", "/spaces/NEW-1"], "the folder already made, not another")
        XCTAssertEqual(sender.resumeConfirms, [false, true])
        XCTAssertEqual(makerCalls, 1)
    }

    func testAResumedNoCodebaseFocusOpensWithoutAnOrgLookupAndPersonal() throws {
        var opened: [Focus] = []
        let sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved("Carefeed") }),
                                     agents: ["claudia"], projects: ["/tmp/alpha"], history: store,
                                     onCreate: { opened.append($0) })
        sheet.noCodebaseFolderMaker = { .success(URL(fileURLWithPath: "/spaces/NEW", isDirectory: true)) }
        self.sheet = sheet
        _ = answering([.resumeWithNoCodebase])
        open(goneRepoEntry(main: nil))
        store.ingest(reply(requestId: sender.resumes.last!.requestId, project: "/spaces/NEW"))

        let focus = try XCTUnwrap(opened.first, "it opens at once, not after a lookup")
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(focus.noCodebase)
        XCTAssertEqual(focus.org, "Personal")
        XCTAssertEqual(focus.workingDirectory, "/spaces/NEW")
    }
}
