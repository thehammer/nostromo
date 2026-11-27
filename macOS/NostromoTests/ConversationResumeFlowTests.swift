import XCTest
import AppKit

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

    func testCancelReleasesTheTagOfEveryRequestInFlight() {
        store.resume("sid1")
        let tag = sender.resumes[0].newTag
        store.cancelResumes()
        XCTAssertEqual(sender.releases, [tag])
        store.cancelResumes()
        XCTAssertEqual(sender.releases, [tag], "nothing left in flight to release")
    }

    func testCancelAfterTheReplyReleasesNothing() {
        store.resume("sid1")
        store.ingest(reply("ready", tag: "cody-ABCDEF12", agent: "cody", project: "/tmp/nostromo"))
        store.cancelResumes()
        XCTAssertTrue(sender.releases.isEmpty, "the focus exists; the daemon's tag is in use")
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


// The New Focus sheet's callback in a real `MainLayout`: a resumed focus flushes the registry to the
// daemon before it is switched to (the daemon reserved its tag and needs the registry entry before the
// spawn); a plain new focus without a chosen model does not.
final class MainLayoutResumeSheetTests: XCTestCase {
    private var focusStore: FocusStore!
    private var layout: MainLayout!
    private var window: NSWindow!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainLayoutResumeSheetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        focusStore = FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
        let displayUUID = "resume-sheet-\(UUID().uuidString)"
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 700),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        layout = MainLayout(windowIndex: 0, displayUUID: displayUUID, focusStore: focusStore)
        window.contentView = layout
        window.alphaValue = 0
        addTeardownBlock { [window] in window?.orderOut(nil); window?.contentView = nil }
    }

    func testAResumedFocusFlushesTheRegistryBeforeItIsSwitchedTo() {
        var events: [String] = []
        let focus = Focus(id: UUID().uuidString, agentTag: "cody", projectPath: "/tmp/p", isBuiltIn: false,
                          label: nil, resumedAt: Date())
        layout.commitFocusFromSheet(focus, flushRegistry: { events.append("flush") },
                                    switchTo: { _ in events.append("switch") })
        XCTAssertEqual(events, ["flush", "switch"])
        XCTAssertTrue(focusStore.focuses.contains { $0.id == focus.id })
    }

    func testAPlainNewFocusWithoutAModelDoesNotFlush() {
        var events: [String] = []
        let focus = Focus(id: UUID().uuidString, agentTag: "cody", projectPath: "/tmp/p", isBuiltIn: false, label: nil)
        layout.commitFocusFromSheet(focus, flushRegistry: { events.append("flush") },
                                    switchTo: { _ in events.append("switch") })
        XCTAssertEqual(events, ["switch"])
    }
}


// A resumed focus waits for its org lookup only briefly: the daemon holds the reserved tag for 15 s.
final class ResumeOrgLookupBoundTests: XCTestCase {
    private var sender: RecordingHistorySender!
    private var store: ConversationHistoryStore!
    private var gate: DispatchSemaphore!
    private var savedLimit: TimeInterval!

    override func setUp() {
        super.setUp()
        sender = RecordingHistorySender()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("focuses-\(UUID().uuidString).json")
        let focusStore = FocusStore(storageURL: url)
        store = ConversationHistoryStore(sender: sender, focusStore: { focusStore })
        gate = DispatchSemaphore(value: 0)
        savedLimit = CreateFocusSheet.resumeOrgLookupLimit
        CreateFocusSheet.resumeOrgLookupLimit = 0.2
    }

    override func tearDown() {
        gate.signal()   // let the stuck lookup finish
        CreateFocusSheet.resumeOrgLookupLimit = savedLimit
        super.tearDown()
    }

    private func makeSheet(onCreate: @escaping (Focus) -> Void) -> CreateFocusSheet {
        let gate = self.gate!
        return CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in gate.wait(); return .resolved("Org") }),
                                agents: ["cody"], projects: ["/tmp/p"], history: store, onCreate: onCreate)
    }

    private func resumed() -> Focus {
        Focus(id: UUID().uuidString, agentTag: "cody", projectPath: "/tmp/never-resolved", isBuiltIn: false,
              label: nil, resumedAt: Date())
    }

    func testAStuckOrgLookupDoesNotHoldTheResumedFocusBack() {
        let created = expectation(description: "opened without an org")
        var opened: Focus?
        let sheet = makeSheet { opened = $0; created.fulfill() }
        store.commitFocus?(resumed())
        wait(for: [created], timeout: 5)
        XCTAssertNil(opened?.org)
        _ = sheet
    }

    func testCancellingDuringTheLookupGivesTheTagBack() {
        var opened = false
        let sheet = makeSheet { _ in opened = true }
        let focus = resumed()
        store.commitFocus?(focus)
        sheet.cancelTapped()
        // The lookup limit firing is what gives the tag back: that release is the signal that the sheet has
        // finished with the cancelled resume, however long the limit takes on this machine.
        waitUntil("the lookup limit never fired, so the tag was never given back") { !sender.releases.isEmpty }
        drainMain()   // a stray late create would still be counted
        XCTAssertFalse(opened)
        XCTAssertEqual(sender.releases, [focus.sessionTag])
    }
}
