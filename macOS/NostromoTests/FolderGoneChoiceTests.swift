import XCTest
import AppKit

/// The choice a resume needs when the worktree is gone or the conversation may be open elsewhere:
/// its buttons, its default, its Esc, and that nothing is sent until the user chooses.
final class FolderGoneChoiceTests: XCTestCase {
    private typealias F = HistoryFixtures
    private var sender: RecordingHistorySender!
    private var store: ConversationHistoryStore!
    private var sheet: CreateFocusSheet!

    override func setUp() {
        super.setUp()
        CreateFocusSheet.rememberedTab = .new
        sender = RecordingHistorySender()
        store = ConversationHistoryStore(sender: sender)
        sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                                 agents: ["claudia"], projects: ["/tmp/alpha"], history: store, onCreate: { _ in })
    }

    override func tearDown() {
        CreateFocusSheet.rememberedTab = .new
        super.tearDown()
    }

    private func gone(main: String? = "/Users/x/Code/nostromo") -> ConversationEntryWire {
        var e = F.entry("g", status: .folderGone(worktree: true), mainCheckout: main)
        e.projectPath = "/Users/x/Code/nostromo-feature-x"
        return e
    }

    private func show(_ e: ConversationEntryWire, answering outcome: ResumeChoice.Outcome?) -> [ResumeChoice] {
        var asked: [ResumeChoice] = []
        sheet.choicePresenter = { choice, done in asked.append(choice); if let outcome { done(outcome) } }
        store.ingest(.conversationHistory(F.history([e])))
        sheet.selectTab(.resume)
        sheet.resumeTab.resumeSelected()
        return asked
    }

    func testTheChoiceNamesTheOldFolderAndOffersResumeInTheMainRepoAsTheDefault() throws {
        let choice = try XCTUnwrap(ResumeChoice.make(for: gone()))
        XCTAssertEqual(choice.message, "This conversation ran in nostromo-feature-x, which no longer exists.")
        XCTAssertEqual(choice.buttons.map(\.title), ["Resume in nostromo", "Cancel", "Show Transcript in Finder"])
        XCTAssertEqual(choice.outcome(forButtonIndex: 0), .resumeInMain("/Users/x/Code/nostromo"), "Return picks it")
        let alert = choice.alert()
        XCTAssertEqual(alert.buttons.map(\.title), choice.buttons.map(\.title))
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "the first button is the default")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "Esc is Cancel")
    }

    func testEscapeCancelsAndSendsNothing() {
        let asked = show(gone(), answering: .cancel)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testReturnResumesInTheMainCheckoutWithThatPlace() {
        _ = show(gone(), answering: .resumeInMain("/Users/x/Code/nostromo"))
        XCTAssertEqual(sender.resumes.count, 1)
        XCTAssertEqual(sender.resumePlaces, ["/Users/x/Code/nostromo"])
        XCTAssertEqual(sender.resumeConfirms, [false])
    }

    func testNothingIsSentWhileTheChoiceIsOpen() {
        _ = show(gone(), answering: nil)
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testWithNoMainCheckoutOnlyCancelAndShowTranscript() throws {
        let choice = try XCTUnwrap(ResumeChoice.make(for: gone(main: nil)))
        XCTAssertEqual(choice.buttons.map(\.title), ["Cancel", "Show Transcript in Finder"])
        XCTAssertFalse(choice.buttons.contains { if case .resumeInMain = $0.outcome { return true } else { return false } })
    }

    func testAPlainGoneFolderAndAnAvailableRowNeedNoChoice() {
        XCTAssertNil(ResumeChoice.make(for: F.entry("a", status: .folderGone(worktree: false))))
        XCTAssertNil(ResumeChoice.make(for: F.entry("a")))
    }

    func testEveryButtonSpeaksInWordsForVoiceOver() throws {
        let alert = try XCTUnwrap(ResumeChoice.make(for: gone())).alert()
        for b in alert.buttons {
            let label = b.accessibilityLabel() ?? ""
            XCTAssertGreaterThan(label.count, b.title.count - 1, "button \(b.title) has a spoken label: \(label)")
            XCTAssertFalse(label.contains("\u{22EF}"))
        }
    }

    // MARK: active elsewhere

    func testActiveElsewhereDefaultsToCancelAndCancelSendsNothing() throws {
        let e = F.entry("a", status: .activeElsewhere)
        let choice = try XCTUnwrap(ResumeChoice.make(for: e))
        XCTAssertEqual(choice.message, "This conversation may be open in another Claude window.")
        XCTAssertEqual(choice.detail, "Resuming it in two places can garble it. Resume anyway?")
        XCTAssertEqual(choice.buttons.map(\.title), ["Cancel", "Resume anyway"])
        XCTAssertEqual(choice.outcome(forButtonIndex: 0), .cancel, "Return cancels")
        XCTAssertEqual(choice.alert().buttons[0].keyEquivalent, "\r")
        _ = show(e, answering: .cancel)
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testResumeAnywaySendsTheConfirmation() {
        _ = show(F.entry("a", status: .activeElsewhere), answering: .resumeAnyway)
        XCTAssertEqual(sender.resumeConfirms, [true])
        XCTAssertEqual(sender.resumePlaces.count, 1)
        XCTAssertNil(sender.resumePlaces[0])
    }

    func testTheFramesCarryOnlyWhatWasChosen() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ClientConversationResume(requestId: "r", id: "s", newTag: "t"))) as! [String: Any]
        XCTAssertNil(plain["place"]); XCTAssertNil(plain["confirm_active_elsewhere"])
        let chosen = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            ClientConversationResume(requestId: "r", id: "s", newTag: "t", place: "/m", confirmActiveElsewhere: true))) as! [String: Any]
        XCTAssertEqual(chosen["place"] as? String, "/m")
        XCTAssertEqual(chosen["confirm_active_elsewhere"] as? Bool, true)
    }

    func testTheNewStatusAndMainCheckoutDecode() throws {
        let json = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"status":{"kind":"active_elsewhere"},"main_checkout":"/m"}"#
        let e = try JSONDecoder().decode(ConversationEntryWire.self, from: Data(json.utf8))
        XCTAssertEqual(e.status, .activeElsewhere)
        XCTAssertEqual(e.mainCheckout, "/m")
        XCTAssertTrue(ResumeTabView.isResumable(e))
        XCTAssertEqual(ConversationHistoryModel.statusText(.activeElsewhere), "active elsewhere?")
    }
}
