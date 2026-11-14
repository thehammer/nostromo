import XCTest
@testable import Nostromo

final class ConversationHistoryModelTests: XCTestCase {
    private typealias F = HistoryFixtures

    private func model(_ entries: [ConversationEntryWire], query: String = "") -> ConversationHistoryModel {
        var m = ConversationHistoryModel(entries: entries, query: query)
        m.now = { F.now }
        m.calendar = F.utcCalendar()
        return m
    }

    func testGroupsByLocalDayNewestFirstAndUnavailableLast() {
        let m = model([
            F.entry("old", daysAgo: 20),
            F.entry("gone", daysAgo: 0, status: .unavailableDeleted),
            F.entry("week", daysAgo: 4),          // Tue 10 Nov: same week (Sunday-start), not yesterday
            F.entry("yest", daysAgo: 1),
            F.entry("t2", title: "later", daysAgo: 0),
            F.entry("t1", daysAgo: 0.1),
        ])
        let g = m.groups
        XCTAssertEqual(g.map(\.title), ["Today", "Yesterday", "Earlier this week", "Earlier", "Unavailable (1)"])
        XCTAssertEqual(g[0].rows.map(\.id), ["t2", "t1"], "newest first")
        XCTAssertEqual(g.last?.rows.map(\.id), ["gone"])
    }

    func testDayBoundaryFollowsTheInjectedTimeZone() {
        var cal = F.utcCalendar()
        cal.timeZone = TimeZone(identifier: "Pacific/Auckland")!   // 15:00 UTC is 04:00 next day there
        var m = ConversationHistoryModel(entries: [F.entry("a", daysAgo: 0)])
        m.now = { F.now }
        m.calendar = cal
        XCTAssertEqual(m.groups.first?.title, "Today")
        m.now = { F.now.addingTimeInterval(86_400) }
        XCTAssertEqual(m.groups.first?.title, "Yesterday")
    }

    func testSearchRequiresEveryWordAcrossTheAllowedFieldsOnly() {
        let e = F.entry("a", title: "Fix picker", agent: "cody", branch: "feature/resume", prs: [412], prompt: "make the sheet taller")
        func hits(_ q: String) -> Int { model([e], query: q).flatRows.count }
        XCTAssertEqual(hits("PICKER cody"), 1)
        XCTAssertEqual(hits("nostromo resume 412"), 1)
        XCTAssertEqual(hits("sheet taller"), 1)
        XCTAssertEqual(hits("picker zebra"), 0, "AND, not OR")
        // Not searchable: the id, the transcript path, the model and the label.
        var other = e
        other.label = "secretlabel"; other.model = "claude-opus-9"; other.resumedFromTag = "hiddentag"
        XCTAssertEqual(model([other], query: "secretlabel").flatRows.count, 0)
        XCTAssertEqual(model([other], query: "opus").flatRows.count, 0)
        XCTAssertEqual(model([other], query: "hiddentag").flatRows.count, 0)
        XCTAssertEqual(model([other], query: "jsonl").flatRows.count, 0)
    }

    func testFiltering500RowsPerKeystrokeIsFast() {
        let entries = (0..<500).map {
            F.entry("e\($0)", title: "Conversation \($0)", daysAgo: Double($0 % 30), branch: "feature/b\($0)",
                    prs: [$0], prompt: "first prompt number \($0)")
        }
        var m = model(entries)
        let start = Date()
        for q in ["c", "co", "con", "conv", "conv 4", "conv 49"] { m.query = q; _ = m.groups }
        XCTAssertLessThan(Date().timeIntervalSince(start) / 6, 0.05)
    }

    func testASensitiveRowSaysOnlyTitleAgentTimeAndSensitive() {
        let e = F.entry("s", title: "Plan my week", agent: "teri", sensitive: true)
        var leaky = e
        leaky.branch = "secret-branch"; leaky.firstPrompt = "do not show"; leaky.prNumbers = [9]
        let t = model([leaky]).text(for: leaky)
        XCTAssertEqual(t.status, "Sensitive")
        XCTAssertNil(t.prs); XCTAssertNil(t.firstPrompt)
        XCTAssertFalse(t.detail.contains("secret-branch"))
        XCTAssertTrue(t.accessibilityLabel.hasPrefix("Plan my week, teri, "))
        XCTAssertTrue(t.accessibilityLabel.hasSuffix(", Sensitive"))
    }

    func testRowWordsCoverStatusPromptsAndWithheldMarkers() {
        let m = model([])
        XCTAssertEqual(m.text(for: F.entry("a", status: .running(tag: "t", open: true))).status, "running · switch to")
        XCTAssertEqual(m.text(for: F.entry("a", status: .folderGone(worktree: true))).status, "worktree gone")
        XCTAssertEqual(m.text(for: F.entry("a", status: .folderGone(worktree: false))).status, "project gone")
        XCTAssertTrue(m.text(for: F.entry("a", status: .unavailableDeleted)).status!.contains("no longer has this conversation"))
        XCTAssertTrue(m.text(for: F.entry("a", status: .unavailableUnreadable)).status!.contains("Can't read this conversation"))
        XCTAssertEqual(m.text(for: F.entry("a", prs: [3, 7], prompt: "hi")).prs, "PR #3 · PR #7")
        XCTAssertEqual(m.text(for: F.entry("a", prompt: "hi")).firstPrompt, "\u{201C}hi\u{201D}")
        var img = F.entry("a"); img.firstPromptWithheld = "image"
        XCTAssertEqual(m.text(for: img).firstPrompt, "(image)")
        var cmd = F.entry("a"); cmd.firstPromptWithheld = "command:/compact"
        XCTAssertEqual(m.text(for: cmd).firstPrompt, "/compact")
        var off = F.entry("a"); off.firstPromptWithheld = "off"
        XCTAssertNil(m.text(for: off).firstPrompt)
    }

    func testHiddenRowsLeaveTheListAndComeBack() {
        var m = model([F.entry("a"), F.entry("b")])
        m.hide("a")
        XCTAssertEqual(m.flatRows.map(\.id), ["b"])
        m.unhide("a")
        XCTAssertEqual(Set(m.flatRows.map(\.id)), ["a", "b"])
    }

    func testTheWireDecodesTheDaemonsShape() throws {
        let json = """
        {"type":"conversation_history","request_id":"r","first_prompts_enabled":false,"degraded_kept":3,"revision":9,
         "entries":[{"id":"s1","title":"T","agent":"cody","sensitive":false,"last_active_ms":5,
           "status":{"kind":"folder_gone","worktree":true},"pr_numbers":[4],"first_prompt_withheld":"image"}]}
        """
        let w = try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(json.utf8))
        XCTAssertEqual(w.degradedKept, 3)
        XCTAssertEqual(w.entries[0].status, .folderGone(worktree: true))
        XCTAssertEqual(w.entries[0].prNumbers, [4])
        XCTAssertFalse(w.firstPromptsEnabled)
    }
}
