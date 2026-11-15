import XCTest
import AppKit

/// Renaming a conversation in History: what is sent, what the row shows, what a resume labels the focus.
final class RenameEntryTests: XCTestCase {
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
        store.ingest(.conversationHistory(F.history([F.entry("a", title: "Old title")])))
        sheet.selectTab(.resume)
    }

    override func tearDown() {
        CreateFocusSheet.rememberedTab = .new
        super.tearDown()
    }

    private func key(_ chars: String, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                         windowNumber: sheet.window!.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testRenameSendsTheTrimmedTitleCappedAtSixtyCharacters() {
        store.rename("a", to: "  New title  ")
        store.rename("a", to: String(repeating: "x", count: 90))
        XCTAssertEqual(sender.renames.map(\.title), ["New title", String(repeating: "x", count: 60)])
        XCTAssertEqual(sender.renames.map(\.id), ["a", "a"])
    }

    func testABlankTitleClearsIt() {
        store.rename("a", to: "   ")
        XCTAssertEqual(sender.renames.count, 1)
        XCTAssertNil(sender.renames[0].title)
    }

    func testTheRowShowsTheTitleTheDaemonListsAfterTheRename() {
        var m = ConversationHistoryModel(entries: [F.entry("a", title: "New title")], now: { F.now }, calendar: F.utcCalendar())
        XCTAssertEqual(m.text(for: m.entries[0]).title, "New title")
        m.entries = [F.entry("a", title: "Old title")]
        XCTAssertEqual(m.text(for: m.entries[0]).title, "Old title")
    }

    func testCommandRAndTheMenuReachRenameFromTheKeyboardAndTheMouse() {
        var asked: [String] = []
        sheet.renameTitleProvider = { e, apply in asked.append(e.id); apply("Typed name") }
        XCTAssertTrue(sheet.window!.performKeyEquivalent(with: key("r", code: 15)))
        XCTAssertEqual(asked, ["a"])
        XCTAssertEqual(sender.renames.map(\.title), ["Typed name"])
        XCTAssertTrue(sheet.resumeTab.menuTitles(for: F.entry("a")).contains("Rename\u{2026}"))
    }

    func testTheRenameFieldStartsWithTheCurrentTitleAndIsFirstResponder() {
        let (alert, field) = RenameEntryAlert.make(currentTitle: "Old title")
        XCTAssertEqual(field.stringValue, "Old title")
        XCTAssertTrue(alert.window.initialFirstResponder === field)
        XCTAssertEqual(alert.buttons.map(\.title), ["Rename", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Return renames")
        XCTAssertEqual(field.accessibilityLabel(), "Conversation name")
    }

    func testAResumedFocusIsLabelledWithTheRenamedTitle() {
        var committed: [Focus] = []
        let s = ConversationHistoryStore(sender: sender, makeRequestId: { "req1" },
                                         makeFocusId: { "ABCDEF12-0000-0000-0000-000000000000" })
        s.ingest(.conversationHistory(F.history([F.entry("a", agent: "cody")])))
        s.commitFocus = { committed.append($0) }
        s.resume("a")
        let j: [String: Any] = ["request_id": "req1", "outcome": "ready", "tag": "cody-ABCDEF12", "agent": "cody",
                                "project_path": "/tmp/nostromo", "label": "Renamed title"]
        let w = try! JSONDecoder().decode(ConversationResumeResultWire.self, from: JSONSerialization.data(withJSONObject: j))
        s.ingest(.conversationResumeResult(w))
        XCTAssertEqual(committed.first?.label, "Renamed title")
    }
}
