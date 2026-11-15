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

    func testASensitiveGoneWorktreeStillOffersTheMainCheckoutAndNeverSaysItIsGone() throws {
        // The daemon sends a sensitive entry no path but its main checkout.
        var e = F.entry("s", status: .folderGone(worktree: true), sensitive: true, mainCheckout: "/Users/x/Code/nostromo")
        e.projectPath = nil; e.projectName = nil
        let choice = try XCTUnwrap(ResumeChoice.make(for: e))
        XCTAssertEqual(choice.buttons.first?.title, "Resume in nostromo")
        XCTAssertFalse(choice.detail.contains("gone too"))
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

    func testCancelIsTheDefaultAndEscapeStillCancels() throws {
        // A first button titled Cancel would lose Return to NSAlert's implicit Esc binding; it must hold Return.
        let elsewhere = try XCTUnwrap(ResumeChoice.make(for: F.entry("a", status: .activeElsewhere)))
        let alert = elsewhere.alert()
        XCTAssertEqual(alert.buttons[0].title, "Cancel")
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return is Cancel")
        XCTAssertNotEqual(alert.buttons[1].keyEquivalent, "\r")
        XCTAssertTrue(elsewhere.escapeCancelsFirstButton, "so Esc is handled by the sheet, and means Cancel")
        XCTAssertEqual(elsewhere.outcome(forButtonIndex: 0), .cancel)
        // With no main checkout, Cancel is first there too.
        let noMain = try XCTUnwrap(ResumeChoice.make(for: gone(main: nil)))
        XCTAssertEqual(noMain.alert().buttons[0].keyEquivalent, "\r")
        XCTAssertTrue(noMain.escapeCancelsFirstButton)
        // With a main checkout, the first button is Resume in main and Cancel keeps Esc.
        let withMain = try XCTUnwrap(ResumeChoice.make(for: gone()))
        XCTAssertFalse(withMain.escapeCancelsFirstButton)
        XCTAssertEqual(withMain.alert().buttons[1].keyEquivalent, "\u{1b}")
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(ResumeChoice.isEscape(esc))
    }

    // MARK: a gone worktree that may also be open elsewhere

    private func answering(_ answers: [ResumeChoice.Outcome]) -> () -> [ResumeChoice] {
        var asked: [ResumeChoice] = []
        var remaining = answers
        sheet.choicePresenter = { choice, done in
            asked.append(choice)
            if !remaining.isEmpty { done(remaining.removeFirst()) }
        }
        return { asked }
    }

    private func goneAndActive() -> ConversationEntryWire {
        var e = gone()
        e.status = .folderGone(worktree: true, activeElsewhere: true)
        return e
    }

    private func open(_ e: ConversationEntryWire) {
        store.ingest(.conversationHistory(F.history([e])))
        sheet.selectTab(.resume)
        sheet.resumeTab.resumeSelected()
    }

    func testAGoneWorktreeThatIsAlsoActiveElsewhereAsksBothAndSendsBothAnswers() {
        let asked = answering([.resumeInMain("/Users/x/Code/nostromo"), .resumeAnyway])
        open(goneAndActive())
        XCTAssertEqual(asked().count, 2, "the place first, then the open-elsewhere question")
        XCTAssertEqual(asked()[1].buttons.map(\.title), ["Cancel", "Resume anyway"])
        XCTAssertEqual(sender.resumePlaces, ["/Users/x/Code/nostromo"])
        XCTAssertEqual(sender.resumeConfirms, [true])
    }

    func testCancellingTheSecondQuestionSendsNothing() {
        let asked = answering([.resumeInMain("/Users/x/Code/nostromo"), .cancel])
        open(goneAndActive())
        XCTAssertEqual(asked().count, 2)
        XCTAssertTrue(sender.resumes.isEmpty)
    }

    func testAGoneWorktreeNotActiveElsewhereAsksOnlyOnce() {
        let asked = answering([.resumeInMain("/Users/x/Code/nostromo")])
        open(gone())
        XCTAssertEqual(asked().count, 1)
        XCTAssertEqual(sender.resumeConfirms, [false])
    }

    func testTheFolderGoneStatusDecodesItsActiveElsewhereFlag() throws {
        let json = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"status":{"kind":"folder_gone","worktree":true,"active_elsewhere":true}}"#
        let e = try JSONDecoder().decode(ConversationEntryWire.self, from: Data(json.utf8))
        XCTAssertEqual(e.status, .folderGone(worktree: true, activeElsewhere: true))
        XCTAssertTrue(e.status.isAlsoActiveElsewhere)
        let old = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"status":{"kind":"folder_gone","worktree":true}}"#
        XCTAssertFalse(try JSONDecoder().decode(ConversationEntryWire.self, from: Data(old.utf8)).status.isAlsoActiveElsewhere)
    }

    // MARK: a stale list: the daemon refuses with active_elsewhere

    private func refuse(_ reason: String) {
        let j: [String: Any] = ["request_id": sender.resumes.last!.requestId, "outcome": "refused", "reason": reason]
        let w = try! JSONDecoder().decode(ConversationResumeResultWire.self, from: JSONSerialization.data(withJSONObject: j))
        store.ingest(.conversationResumeResult(w))
    }

    func testARefusalForActiveElsewhereOffersResumeAnywayAndKeepsThePlace() {
        let asked = answering([.resumeInMain("/Users/x/Code/nostromo"), .resumeAnyway])
        open(gone())
        XCTAssertEqual(sender.resumes.count, 1)
        refuse("active_elsewhere")
        XCTAssertEqual(asked().count, 2, "the refusal asked, rather than showing an error")
        XCTAssertEqual(asked()[1].buttons.map(\.title), ["Cancel", "Resume anyway"])
        XCTAssertEqual(sender.resumes.count, 2)
        XCTAssertEqual(sender.resumePlaces, ["/Users/x/Code/nostromo", "/Users/x/Code/nostromo"])
        XCTAssertEqual(sender.resumeConfirms, [false, true])
    }

    func testCancellingAfterAStaleRefusalSendsNoSecondRequest() {
        _ = answering([.resumeInMain("/Users/x/Code/nostromo"), .cancel])
        open(gone())
        refuse("active_elsewhere")
        XCTAssertEqual(sender.resumes.count, 1)
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
