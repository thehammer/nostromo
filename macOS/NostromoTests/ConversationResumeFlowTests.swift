import XCTest
@testable import Nostromo

/// The resume rules' Mac side: the store, a recording sender and a temp focus store.
final class ConversationResumeFlowTests: XCTestCase {
    private typealias F = HistoryFixtures
    private var sender: RecordingHistorySender!
    private var focusStore: FocusStore!
    private var store: ConversationHistoryStore!
    private var scheduled: [(TimeInterval, () -> Void)] = []
    private var clock = F.now
    private var committed: [Focus] = []
    private var switchedTags: [String] = []
    private var events: [String] = []

    override func setUp() {
        super.setUp()
        sender = RecordingHistorySender()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focuses-\(UUID().uuidString).json")
        focusStore = FocusStore(storageURL: url)
        var n = 0
        store = ConversationHistoryStore(
            sender: sender, focusStore: { [unowned self] in focusStore },
            makeRequestId: { n += 1; return "req\(n)" }, makeFocusId: { "ABCDEF12-0000-0000-0000-000000000000" },
            now: { [unowned self] in clock }, schedule: { [unowned self] d, w in scheduled.append((d, w)) })
        scheduled = []; committed = []; switchedTags = []; events = []; clock = F.now
        store.ingest(.conversationHistory(F.history([F.entry("sid1", agent: "cody")])))
        store.switchToTag = { [unowned self] in switchedTags.append($0); return true }
        store.commitFocus = { [unowned self] focus in
            FocusCreation.commit(focus, store: focusStore, flushRegistry: { events.append("flush") },
                                 alwaysFlush: true) { _ in events.append("switch") }
            committed.append(focus)
        }
    }

    private func reply(_ outcome: String, requestId: String = "req1", tag: String? = nil, reason: String? = nil,
                       agent: String? = nil, project: String? = nil, label: String? = nil) -> ServerMsg {
        var j: [String: Any] = ["request_id": requestId, "outcome": outcome]
        if let tag { j["tag"] = tag }; if let reason { j["reason"] = reason }
        if let agent { j["agent"] = agent }; if let project { j["project_path"] = project }
        if let label { j["label"] = label }
        let w = try! JSONDecoder().decode(ConversationResumeResultWire.self, from: JSONSerialization.data(withJSONObject: j))
        return .conversationResumeResult(w)
    }

    func testTheNewTagIsDerivedExactlyAsAFocusDerivesIt() {
        store.resume("sid1")
        XCTAssertEqual(sender.resumes.first?.newTag, "cody-ABCDEF12")
        XCTAssertEqual(Focus(id: "ABCDEF12-0000-0000-0000-000000000000", agentTag: "cody", projectPath: nil,
                             isBuiltIn: false).sessionTag, "cody-ABCDEF12")
    }

    func testSwitchSelectsTheExistingFocusAndCreatesNone() {
        store.resume("sid1")
        store.ingest(reply("switch", tag: "cody-1234"))
        XCTAssertEqual(switchedTags, ["cody-1234"])
        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(focusStore.focuses.filter { !$0.isBuiltIn }.isEmpty)
    }

    func testReadyCommitsExactlyOneFocusFromTheReplyAndFlushesBeforeSwitching() {
        store.resume("sid1")
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/nostromo", label: "My focus"))
        XCTAssertEqual(committed.count, 1)
        let f = committed[0]
        XCTAssertEqual([f.agentTag, f.projectPath, f.label], ["cody", "/tmp/nostromo", "My focus"])
        XCTAssertEqual(f.resumedAt, F.now)
        XCTAssertEqual(f.sessionTag, "cody-ABCDEF12")
        XCTAssertEqual(events, ["flush", "switch"], "the daemon needs the registry entry before the spawn")
        XCTAssertEqual(focusStore.focuses.filter { !$0.isBuiltIn }.count, 1)
    }

    func testTwoGesturesOnOneRowSendOneResume() {
        store.resume("sid1")
        store.resume("sid1")
        XCTAssertEqual(sender.resumes.count, 1)
        store.ingest(reply("switch", tag: "cody-1"))
        store.resume("sid1")
        XCTAssertEqual(sender.resumes.count, 2, "after the reply it can be tried again")
    }

    func testResumeFailedRemovesTheCreatedFocusAndOffersTheTranscript() {
        var withPath = F.entry("sid1", agent: "cody"); withPath.transcriptPath = "/tmp/t.jsonl"
        store.ingest(.conversationHistory(F.history([withPath])))
        var shown: [String?] = []
        store.onResumeFailed = { shown.append($0) }
        store.resume("sid1")
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/nostromo"))
        XCTAssertEqual(focusStore.focuses.filter { !$0.isBuiltIn }.count, 1)
        store.ingest(.conversationResumeFailed(tag: "cody-ABCDEF12", reason: "not_found_here"))
        XCTAssertTrue(focusStore.focuses.filter { !$0.isBuiltIn }.isEmpty)
        XCTAssertEqual(shown, ["/tmp/t.jsonl"])
        XCTAssertEqual(ConversationHistoryStore.resumeFailureText, "Claude couldn\u{2019}t open this conversation here.")
    }

    func testRefusalsCarryFixedWords() {
        var results: [ConversationHistoryStore.ResumeResult] = []
        let c = store.resumeResults.sink { results.append($0.1) }
        defer { c.cancel() }
        store.resume("sid1")
        store.ingest(reply("refused", reason: "folder_gone"))
        XCTAssertEqual(results, [.refused("folder_gone")])
    }

    func testStartingRetriesEverySecondForThirtySecondsThenSaysSo() {
        var results: [ConversationHistoryStore.ResumeResult] = []
        let c = store.resumeResults.sink { results.append($0.1) }
        defer { c.cancel() }
        store.resume("sid1")
        store.ingest(reply("refused", requestId: "req1", reason: "starting"))
        XCTAssertEqual(results, [.waitingToStart])
        XCTAssertEqual(scheduled.map(\.0), [1])
        scheduled.removeFirst().1()
        XCTAssertEqual(sender.resumes.count, 2, "retried")
        clock = F.now.addingTimeInterval(31)
        store.ingest(reply("refused", requestId: "req2", reason: "starting"))
        XCTAssertEqual(results.last, .gaveUp)
        XCTAssertTrue(scheduled.isEmpty, "no further retry")
        store.resume("sid1")
        XCTAssertEqual(sender.resumes.count, 3, "free to try again")
    }

    func testAnOldDaemonIsNeverAsked() {
        sender.daemonAdvertisesConversationHistory = false
        store.resume("sid1"); store.refresh()
        XCTAssertTrue(sender.resumes.isEmpty)
        XCTAssertEqual(sender.gets, 0)
    }

    func testTheResumedLineShowsUntilTheFirstSendClearsIt() {
        var f = Focus(id: "ABCDEF12-0000", agentTag: "cody", projectPath: "/tmp/nostromo", isBuiltIn: false)
        f.resumedAt = F.now
        focusStore.add(f)
        XCTAssertTrue(buildSecondary(f).hasPrefix("resumed \u{00B7} "))
        focusStore.clearResumed(tag: f.sessionTag)
        XCTAssertNil(focusStore.focuses.first { $0.id == f.id }?.resumedAt)
        XCTAssertFalse(buildSecondary(focusStore.focuses.first { $0.id == f.id }!).contains("resumed"))
    }

    func testAFocusFileWrittenBeforeHistoryStillDecodes() throws {
        let old = #"[{"id":"u","agentTag":"cody","isBuiltIn":false}]"#
        let decoded = try JSONDecoder().decode([Focus].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].resumedAt)
    }

    private func buildSecondary(_ f: Focus) -> String {
        guard case .focus(_, _, let secondary, _)? = buildNavRows([f]).first(where: {
            if case .focus = $0 { return true } else { return false } }) else { return "" }
        return secondary ?? ""
    }
}
