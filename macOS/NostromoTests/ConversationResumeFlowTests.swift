import XCTest

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
            // The same entry point the sheet's callback uses: it decides whether to flush, not this test.
            FocusCreation.commitFromSheet(focus, store: focusStore, flushRegistry: { events.append("flush") }) { _ in
                events.append("switch")
            }
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

    func testAFocusWithoutResumedAtDoesNotForceAFlush() {
        FocusCreation.commitFromSheet(Focus(id: "x1", agentTag: "cody", projectPath: nil, isBuiltIn: false),
                                      store: focusStore, flushRegistry: { events.append("flush") }) { _ in }
        XCTAssertTrue(events.isEmpty)
    }

    func testCancelClearsWhatIsInFlightAndALateReadyMakesNoFocus() {
        store.resume("sid1")
        store.cancelResumes()
        store.commitFocus = nil
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/nostromo"))
        XCTAssertTrue(committed.isEmpty)
        XCTAssertTrue(focusStore.focuses.filter { !$0.isBuiltIn }.isEmpty)
        store.resume("sid1")
        XCTAssertEqual(sender.resumes.count, 2, "the row is free again after Cancel")
    }

    func testCancelStopsTheStartingRetry() {
        store.resume("sid1")
        store.ingest(reply("refused", reason: "starting"))
        XCTAssertEqual(scheduled.count, 1)
        store.cancelResumes()
        scheduled.removeFirst().1()
        XCTAssertEqual(sender.resumes.count, 1, "no further request after Cancel")
    }

    func testAnAgentMismatchAdoptsTheDaemonsReservedTagInsteadOfOrphaningIt() {
        store.resume("sid1")   // the request guessed tag cody-ABCDEF12
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "teri", project: "/tmp/nostromo"))
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].sessionTag, "cody-ABCDEF12")
        XCTAssertEqual(committed[0].agentTag, "teri")
    }

    func testTheResumedLabelIsNormalised() {
        store.resume("sid1")
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/p",
                           label: "  " + String(repeating: "x", count: 90) + "\n"))
        XCTAssertEqual(committed[0].label?.count, Focus.maxLabelLength)
    }

    func testOneBadEntryDoesNotBlankTheList() throws {
        let good = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"sensitive":false,"status":{"kind":"available"}}"#
        let bad = #"{"id":"b","title":7}"#
        let json = #"{"request_id":"r","entries":[\#(good),\#(bad),\#(good.replacingOccurrences(of: "\"a\"", with: "\"c\""))],"first_prompts_enabled":true,"revision":2}"#
        let wire = try JSONDecoder().decode(ConversationHistoryWire.self, from: Data(json.utf8))
        XCTAssertEqual(wire.entries.map(\.id), ["a", "c"])
    }

    func testAnUnknownStatusKindIsShownButNeverResumable() throws {
        let json = #"{"id":"a","title":"T","agent":"cody","last_active_ms":1,"status":{"kind":"from_the_future"}}"#
        let e = try JSONDecoder().decode(ConversationEntryWire.self, from: Data(json.utf8))
        XCTAssertEqual(e.status, .unknown)
        XCTAssertFalse(ResumeTabView.isResumable(e))
        XCTAssertTrue(ConversationHistoryModel.isUnavailable(e.status))
    }

    func testShowTranscriptOnlyRevealsARegularJsonlUnderClaudeProjects() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
        let projects = home.appendingPathComponent(".claude/projects/p")
        try fm.createDirectory(at: projects, withIntermediateDirectories: true)
        let good = projects.appendingPathComponent("s.jsonl")
        try "x".write(to: good, atomically: true, encoding: .utf8)
        let outside = home.appendingPathComponent("other.jsonl")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        let link = projects.appendingPathComponent("link.jsonl")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let txt = projects.appendingPathComponent("s.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)
        func ok(_ u: URL) -> Bool { ConversationHistoryStore.isShowableTranscript(u.path, home: home) }
        XCTAssertTrue(ok(good))
        XCTAssertFalse(ok(outside), "outside ~/.claude/projects")
        XCTAssertFalse(ok(link), "a symlink out of the projects folder")
        XCTAssertFalse(ok(txt), "not a .jsonl")
        XCTAssertFalse(ok(projects), "a directory")
    }

    func testQuittingWithPromptsOffDropsTheListing() {
        store.ingest(.conversationHistory(F.history([F.entry("sid1", prompt: "hi")], prompts: false)))
        store.appWillTerminate()
        XCTAssertNil(store.history)
    }
}
