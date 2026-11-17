import XCTest
import AppKit

/// "Include conversations started outside Nostromo": off by default, the daemon decides what is listed
/// (this app only labels it), and the Resume tab's rules (search, sensitivity, resume) hold for terminal rows.
final class OutsideConversationsTests: XCTestCase {
    private typealias F = HistoryFixtures
    private var sender: RecordingHistorySender!
    private var store: ConversationHistoryStore!
    private var sheet: CreateFocusSheet!

    override func setUp() {
        super.setUp()
        CreateFocusSheet.rememberedTab = .new
        sender = RecordingHistorySender()
        store = ConversationHistoryStore(sender: sender, makeRequestId: { "req" }, makeFocusId: { "ABCDEF12-0000" })
        sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                                 agents: ["claudia", "cody"], projects: ["/tmp/alpha"], history: store,
                                 onCreate: { _ in })
    }

    override func tearDown() { CreateFocusSheet.rememberedTab = .new; super.tearDown() }

    private func model() -> ConversationHistoryModel {
        var m = ConversationHistoryModel()
        m.now = { F.now }; m.calendar = F.utcCalendar()
        return m
    }

    private func show(_ w: ConversationHistoryWire) {
        store.ingest(.conversationHistory(w))
        sheet.selectTab(.resume)
    }

    func testTheSwitchIsOffByDefaultAndTurningItOnAsksTheDaemon() {
        let tab = sheet.resumeTab
        XCTAssertEqual(tab.outsideCheckbox.state, .off)
        XCTAssertEqual(tab.outsideCheckbox.title, "Include conversations started outside Nostromo")
        show(F.history([F.entry("a")]))
        XCTAssertEqual(tab.outsideCheckbox.state, .off, "a daemon that does not say means off")
        tab.outsideCheckbox.performClick(nil)
        XCTAssertEqual(sender.includeOutsideSettings, [true])
        show(F.history([F.entry("a")], includeOutside: true, outsideReady: true))
        XCTAssertEqual(tab.outsideCheckbox.state, .on)
        tab.outsideCheckbox.performClick(nil)
        XCTAssertEqual(sender.includeOutsideSettings, [true, false])
    }

    func testTerminalRowsAppearOnlyInTheDaemonsListAndSayTerminal() {
        // Off: the daemon sends none, so none show.
        show(F.history([F.entry("n1", title: "Nostromo one")]))
        XCTAssertEqual(sheet.resumeTab.visibleEntries.map(\.id), ["n1"])
        // On: the daemon's merged list shows them, labelled.
        show(F.history([F.entry("n1", title: "Nostromo one"), F.entry("t1", title: "claude", agent: "", origin: "terminal")],
                       includeOutside: true, outsideReady: true))
        let rows = sheet.resumeTab.visibleEntries
        XCTAssertEqual(Set(rows.map(\.id)), ["n1", "t1"])
        let m = model()
        let terminal = m.text(for: rows.first { $0.id == "t1" }!)
        XCTAssertTrue(terminal.title.hasPrefix("Terminal \u{00B7} "), terminal.title)
        XCTAssertTrue(terminal.accessibilityLabel.hasPrefix("Terminal, "))
        XCTAssertFalse(m.text(for: rows.first { $0.id == "n1" }!).title.contains("Terminal"))
    }

    func testLookingForTerminalConversationsShowsUntilTheIndexIsReady() {
        show(F.history([F.entry("n1")], includeOutside: true, outsideReady: false))
        XCTAssertEqual(sheet.resumeTab.bannerText, "Looking for terminal conversations\u{2026}")
        XCTAssertEqual(sheet.resumeTab.visibleEntries.map(\.id), ["n1"], "the list does not wait for the index")
        show(F.history([F.entry("n1")], includeOutside: true, outsideReady: true))
        XCTAssertNil(sheet.resumeTab.bannerText)
        show(F.history([F.entry("n1")], includeOutside: false, outsideReady: false))
        XCTAssertNil(sheet.resumeTab.bannerText, "switch off: nothing to look for")
    }

    func testSearchAndSensitivityRulesAreUnchangedForTerminalRows() {
        var m = model()
        let plain = F.entry("t1", title: "claude", agent: "cody", project: "alpha", prompt: "tidy the readme", origin: "terminal")
        let sensitive = F.entry("t2", title: "claude", agent: "teri", project: nil, sensitive: true, origin: "terminal")
        m.entries = [plain, sensitive]
        m.query = "readme"
        XCTAssertEqual(m.groups.flatMap(\.rows).map(\.id), ["t1"])
        m.query = "terminal"
        XCTAssertEqual(Set(m.groups.flatMap(\.rows).map(\.id)), ["t1", "t2"])
        let t = m.text(for: sensitive)
        XCTAssertEqual(t.status, "Sensitive")
        XCTAssertNil(t.firstPrompt)
        XCTAssertTrue(t.title.hasPrefix("Terminal"))
    }

    func testATerminalConversationWithNoAgentHereAsksWhichOneBeforeAnythingIsSent() {
        show(F.history([F.entry("t1", title: "claude", agent: "", origin: "terminal"),
                        F.entry("t2", title: "claude", agent: "", origin: "terminal")],
                       includeOutside: true, outsideReady: true))
        let t1 = sheet.resumeTab.visibleEntries.first { $0.id == "t1" }!
        let t2 = sheet.resumeTab.visibleEntries.first { $0.id == "t2" }!
        var asked: [([String], String?)] = []
        var answer: String? = "cody"
        sheet.agentChoiceProvider = { agents, pre, done in asked.append((agents, pre)); done(answer) }
        sheet.resumeTab.onResume?(t1)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].0, ["claudia", "cody"])
        XCTAssertEqual(asked[0].1, "claudia", "the New tab's default agent is preselected")
        XCTAssertEqual(sender.resumes.count, 1)
        XCTAssertEqual(sender.resumeAgents, ["cody"])
        // Cancel sends nothing.
        store.cancelResumes()
        answer = nil
        sheet.resumeTab.onResume?(t2)
        XCTAssertEqual(sender.resumes.count, 1)
    }

    func testATerminalConversationWithARecordedAgentAsksNothing() {
        show(F.history([F.entry("t1", title: "claude", agent: "cody", origin: "terminal")], includeOutside: true, outsideReady: true))
        sheet.agentChoiceProvider = { _, _, _ in XCTFail("no question: the recorded agent exists") }
        sheet.resumeTab.onResume?(sheet.resumeTab.visibleEntries[0])
        XCTAssertEqual(sender.resumeAgents, [nil])
    }

    func testTheWireCarriesTheNewFieldsAndAnOlderDaemonLeavesThemOff() throws {
        let json = #"{"request_id":"r","entries":[{"id":"t","title":"claude","agent":"","sensitive":false,"last_active_ms":1,"status":{"kind":"available"},"origin":"terminal"}],"first_prompts_enabled":true,"include_outside":true,"outside_ready":true,"revision":1}"#
        let w = try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(json.utf8))
        XCTAssertTrue(w.includeOutside && w.outsideReady)
        XCTAssertTrue(w.entries[0].isTerminal)
        let old = #"{"request_id":"r","entries":[],"first_prompts_enabled":true,"revision":1}"#
        let o = try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(old.utf8))
        XCTAssertFalse(o.includeOutside)
        XCTAssertFalse(o.outsideReady)
        let frame = try JSONEncoder().encode(ClientConversationHistorySettingsSet(requestId: "r", includeOutside: true))
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
        XCTAssertEqual(sent["include_outside"] as? Bool, true)
        XCTAssertNil(sent["first_prompts_enabled"], "the two switches are independent")
    }
}
