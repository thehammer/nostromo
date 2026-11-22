import XCTest
import Combine
import CryptoKit

// `ComposerHistoryStore` (message queue S4): per-focus history of what the user sent from the composer,
// newest first. Rules (A44), per-focus isolation (A45), persistence behind `persistsAcrossRelaunch`
// (A46), file modes (SP2), the sensitive switch (SP3), Clear History (A47), `removeNewest` (A48 seam),
// and `FocusSensitivity`. ComposerHistoryStore, FocusSensitivity and the wire types are compiled into
// this target directly (logic test, no host app).
//
// Never the real `~/.nostromo`: every store writes under a temp directory. No sleeping: `flush()` writes
// what is pending and waits for the file queue.

/// A `FocusSensitivityProviding` the tests drive.
final class FakeFocusSensitivity: FocusSensitivityProviding {
    var sensitiveTags: Set<String> = []
    private let subject = PassthroughSubject<String, Never>()
    var becameSensitive: AnyPublisher<String, Never> { subject.eraseToAnyPublisher() }

    func isSensitive(tag: String, agentName: String?) -> Bool { sensitiveTags.contains(tag) }

    func becomeSensitive(_ tag: String) {
        sensitiveTags.insert(tag)
        subject.send(tag)
    }
}

/// Scheduled work is kept, never run: `flush()` is the only thing that writes.
private func idleScheduler() -> WorkScheduler {
    WorkScheduler { _, _ in { } }
}

final class ComposerHistoryStoreTests: XCTestCase {

    private var root: URL!
    private var directory: URL { root.appendingPathComponent("composer-history.v1", isDirectory: true) }
    private var sensitivity: FakeFocusSensitivity!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sensitivity = FakeFocusSensitivity()
    }

    override func tearDownWithError() throws {
        cancellables = []
        try? FileManager.default.removeItem(at: root)   // the test's own temp tree
    }

    private func makeStore(persists: Bool = true) -> ComposerHistoryStore {
        ComposerHistoryStore(directory: directory, persists: persists, sensitivity: sensitivity,
                             scheduler: idleScheduler())
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    // MARK: Rules (A44)

    func testEntriesAreNewestFirst() {
        let store = makeStore()
        ["a", "b", "c"].forEach { store.record(tag: "t", text: $0) }
        XCTAssertEqual(store.entries(tag: "t"), ["c", "b", "a"])
    }

    func testAConsecutiveDuplicateIsRecordedOnceAndANonConsecutiveRepeatIsKept() {
        let store = makeStore()
        ["a", "a", "b", "a", "a"].forEach { store.record(tag: "t", text: $0) }
        XCTAssertEqual(store.entries(tag: "t"), ["a", "b", "a"])
    }

    func testThe201stEntryEvictsTheOldest() {
        let store = makeStore()
        for i in 1...201 { store.record(tag: "t", text: "m\(i)") }
        let entries = store.entries(tag: "t")
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.first, "m201")
        XCTAssertEqual(entries.last, "m2", "m1, the oldest, was evicted")
    }

    func testAnEntryOver20000CharactersIsNotRecordedButExactly20000Is() {
        let store = makeStore()
        store.record(tag: "t", text: String(repeating: "x", count: 20_001))
        XCTAssertEqual(store.entries(tag: "t"), [])
        let exact = String(repeating: "y", count: 20_000)
        store.record(tag: "t", text: exact)
        XCTAssertEqual(store.entries(tag: "t"), [exact])
    }

    func testEmptyTextIsNotRecorded() {
        let store = makeStore()
        store.record(tag: "t", text: "")
        XCTAssertEqual(store.entries(tag: "t"), [])
    }

    // MARK: Per focus (A45)

    func testTwoFocusesNeverSeeEachOthersEntries() {
        let store = makeStore()
        store.record(tag: "one", text: "for one")
        store.record(tag: "two", text: "for two")
        XCTAssertEqual(store.entries(tag: "one"), ["for one"])
        XCTAssertEqual(store.entries(tag: "two"), ["for two"])
    }

    // MARK: removeNewest (A48 seam)

    func testRemoveNewestRemovesOnlyTheNewestMatchingEntry() {
        let store = makeStore()
        ["x", "y", "x", "z"].forEach { store.record(tag: "t", text: $0) }   // newest first: z x y x
        XCTAssertTrue(store.removeNewest(tag: "t", matching: "x"))
        XCTAssertEqual(store.entries(tag: "t"), ["z", "y", "x"])
        XCTAssertFalse(store.removeNewest(tag: "t", matching: "nope"))
        XCTAssertEqual(store.entries(tag: "t"), ["z", "y", "x"])
    }

    // MARK: Changes

    func testChangesPublishRecordedClearedAndRemoved() {
        let store = makeStore()
        var seen: [ComposerHistoryChange] = []
        store.changes.sink { seen.append($0) }.store(in: &cancellables)
        store.record(tag: "t", text: "a")
        store.removeNewest(tag: "t", matching: "a")
        store.record(tag: "t", text: "b")
        store.clear(tag: "t")
        store.removeFocus(tag: "t")
        XCTAssertEqual(seen, [.recorded(tag: "t"), .removed(tag: "t"), .recorded(tag: "t"),
                              .cleared(tag: "t"), .cleared(tag: "t")])
    }

    // MARK: Persistence (A46)

    func testHistorySurvivesRelaunchSameTagNewStoreFromDisk() {
        let first = makeStore()
        ["a", "b", "c"].forEach { first.record(tag: "claudia", text: $0) }
        first.flush()
        let second = makeStore()   // the app relaunched
        XCTAssertEqual(second.entries(tag: "claudia"), ["c", "b", "a"])
        XCTAssertEqual(second.entries(tag: "other"), [])
    }

    func testOneFileNamedBySHA256OfTheTag() throws {
        let store = makeStore()
        store.record(tag: "claudia", text: "hello")
        store.flush()
        let name = try XCTUnwrap(files().first?.lastPathComponent)
        XCTAssertEqual(files().count, 1)
        XCTAssertTrue(name.hasSuffix(".json"))
        let hex = SHA256.hash(data: Data("claudia".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(name, "\(hex).json", "named by the sha256 hex digest of the tag")
        XCTAssertFalse(name.contains("claudia"), "the tag is not in the file name")
    }

    func testWithPersistenceOffNothingTouchesTheDisk() {
        let store = makeStore(persists: false)
        store.record(tag: "t", text: "a")
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(store.entries(tag: "t"), ["a"], "memory still works")
    }

    func testThePersistenceConstantDefaultsToYes() {
        XCTAssertTrue(ComposerHistoryStore.persistsAcrossRelaunch, "open question 3: yes, the PRD's recommendation")
    }

    func testClosingTheFocusDeletesItsHistoryFromMemoryAndDisk() {
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.record(tag: "keep", text: "b")
        store.flush()
        XCTAssertEqual(files().count, 2)
        store.removeFocus(tag: "t")
        store.flush()
        XCTAssertEqual(store.entries(tag: "t"), [])
        XCTAssertEqual(files().count, 1, "only the other focus's file remains")
        XCTAssertEqual(makeStore().entries(tag: "t"), [])
        XCTAssertEqual(makeStore().entries(tag: "keep"), ["b"])
    }

    func testClearDeletesMemoryAndDiskAtOnce() {
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.flush()
        store.clear(tag: "t")
        XCTAssertEqual(store.entries(tag: "t"), [], "memory at once")
        store.flush()
        XCTAssertEqual(files().count, 0, "and the file")
        XCTAssertEqual(makeStore().entries(tag: "t"), [])
    }

    func testAClearedFocusRecordsAgainAfterwards() {
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.flush()
        store.clear(tag: "t")
        store.record(tag: "t", text: "b")
        store.flush()
        XCTAssertEqual(makeStore().entries(tag: "t"), ["b"])
    }

    // MARK: File modes (SP2)

    func testDirectoryIs0700AndFilesAre0600() throws {
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.flush()
        XCTAssertEqual(try mode(of: directory), 0o700)
        let file = try XCTUnwrap(files().first)
        XCTAssertEqual(try mode(of: file), 0o600)
    }

    func testAnExistingWideDirectoryIsTightenedAndNoTemporaryFileIsLeftBehind() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.flush()
        XCTAssertEqual(try mode(of: directory), 0o700)
        XCTAssertEqual(files().count, 1, "the temporary file was renamed away")
    }

    func testFilesStayPrivateUnderAPermissiveUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        let store = makeStore()
        store.record(tag: "t", text: "a")
        store.flush()
        XCTAssertEqual(try mode(of: try XCTUnwrap(files().first)), 0o600)
        XCTAssertEqual(try mode(of: directory), 0o700)
    }

    // MARK: Corrupt files (H4-16)

    func testACorruptFileIsEmptyHistoryWithOneLogLineNamingTheErrorClassNotTheContents() throws {
        let store = makeStore()
        store.record(tag: "t", text: "seed")
        store.flush()
        let file = try XCTUnwrap(files().first)
        try Data("{\"version\":1,\"entries\":[\"CANARY-SECRET".utf8).write(to: file)

        let reloaded = makeStore()
        var logged: [String] = []
        reloaded.logError = { logged.append($0) }
        XCTAssertEqual(reloaded.entries(tag: "t"), [])
        XCTAssertEqual(reloaded.entries(tag: "t"), [], "asked again: still empty, and no second line")
        XCTAssertEqual(logged.count, 1)
        XCTAssertTrue(logged[0].contains("DecodingError") || logged[0].contains("Error"), "an error class: \(logged)")
        XCTAssertFalse(logged[0].contains("CANARY"), "never entry text")

        reloaded.record(tag: "t", text: "works")
        reloaded.flush()
        XCTAssertEqual(makeStore().entries(tag: "t"), ["works"], "the composer works and the file is replaced")
    }

    func testAnUnknownVersionIsEmptyHistoryWithOneLogLine() throws {
        let store = makeStore()
        store.record(tag: "t", text: "seed")
        store.flush()
        let file = try XCTUnwrap(files().first)
        try Data("{\"version\":99,\"entries\":[\"a\"]}".utf8).write(to: file)
        let reloaded = makeStore()
        var logged: [String] = []
        reloaded.logError = { logged.append($0) }
        XCTAssertEqual(reloaded.entries(tag: "t"), [])
        XCTAssertEqual(logged.count, 1)
    }

    func testAFileWithMoreThanTheCapOrOversizeEntriesIsTrimmedOnLoad() throws {
        let store = makeStore()
        store.record(tag: "t", text: "seed")
        store.flush()
        let file = try XCTUnwrap(files().first)
        let many = (0..<300).map { "e\($0)" } + [String(repeating: "z", count: 20_001)]
        let body: [String: Any] = ["version": 1, "entries": [String(repeating: "z", count: 20_001)] + many.dropLast()]
        try JSONSerialization.data(withJSONObject: body).write(to: file)
        let entries = makeStore().entries(tag: "t")
        XCTAssertEqual(entries.count, 200)
        XCTAssertEqual(entries.first, "e0", "the oversize entry is dropped")
    }

    // MARK: The sensitive switch (SP3)

    func testAFocusThatBecomesSensitiveHasItsFileDeletedAtOnceAndIsNeverWrittenAgain() {
        let store = makeStore()
        store.record(tag: "work", text: "before")
        store.record(tag: "plain", text: "kept")
        store.flush()
        XCTAssertEqual(files().count, 2)

        sensitivity.becomeSensitive("work")
        store.flush()   // waits for the file queue only; nothing was pending
        XCTAssertEqual(files().count, 1, "the sensitive focus's file is gone")

        store.record(tag: "work", text: "after")
        store.flush()
        XCTAssertEqual(files().count, 1, "never written again")
        XCTAssertEqual(store.entries(tag: "work"), ["after", "before"], "history still works in memory")
        XCTAssertTrue(store.isMemoryOnly(tag: "work"))
        XCTAssertFalse(store.isMemoryOnly(tag: "plain"))
        XCTAssertEqual(makeStore().entries(tag: "work"), [], "a relaunch finds nothing for it")
        XCTAssertEqual(makeStore().entries(tag: "plain"), ["kept"])
    }

    func testAPendingWriteIsDroppedWhenTheFocusBecomesSensitive() {
        let store = makeStore()
        store.record(tag: "work", text: "secret")   // pending, not yet written
        sensitivity.becomeSensitive("work")
        store.flush()
        XCTAssertEqual(files().count, 0)
    }

    func testAFocusAlreadySensitiveWhenRecordedIsNeverWritten() {
        sensitivity.sensitiveTags = ["work"]
        let store = makeStore()
        store.record(tag: "work", text: "a")
        store.flush()
        XCTAssertEqual(files().count, 0)
        XCTAssertEqual(store.entries(tag: "work"), ["a"])
    }

    func testClearOfASensitiveFocusStillWorks() {
        let store = makeStore()
        sensitivity.becomeSensitive("work")
        store.record(tag: "work", text: "a")
        store.clear(tag: "work")
        XCTAssertEqual(store.entries(tag: "work"), [])
    }

    // MARK: FocusSensitivity

    private func conversation(_ id: String, tag: String?, sensitive: Bool) -> ConversationEntryWire {
        HistoryFixtures.entry(id, status: tag.map { .running(tag: $0, open: true) } ?? .available,
                                             sensitive: sensitive)
    }

    func testFocusSensitivityKnowsTheAlwaysSensitiveAgents() {
        let s = FocusSensitivity(entries: { [] }, entriesChanged: Empty().eraseToAnyPublisher())
        for agent in ["fred", "teri", "huey", "Fred", "TERI", "plugin:huey", " fred "] {
            XCTAssertTrue(s.isSensitive(tag: "x", agentName: agent), agent)
        }
        for agent in ["claudia", "cody", "frederick", nil] as [String?] {
            XCTAssertFalse(s.isSensitive(tag: "x", agentName: agent), "\(agent ?? "nil")")
        }
        XCTAssertTrue(s.isSensitive(tag: "huey-run", agentName: nil))
    }

    func testAConversationEntryMarkedSensitiveAndRunningMarksItsTagOnceAndPublishes() {
        var entries: [ConversationEntryWire] = []
        let changed = PassthroughSubject<Void, Never>()
        let s = FocusSensitivity(entries: { entries }, entriesChanged: changed.eraseToAnyPublisher())
        var events: [String] = []
        s.becameSensitive.sink { events.append($0) }.store(in: &cancellables)

        entries = [conversation("c1", tag: "work-1", sensitive: true),
                   conversation("c2", tag: "plain-1", sensitive: false),
                   conversation("c3", tag: nil, sensitive: true)]
        changed.send()
        changed.send()
        XCTAssertEqual(events, ["work-1"], "once, and not for a non-sensitive or a not-running entry")
        XCTAssertTrue(s.isSensitive(tag: "work-1", agentName: nil))
        XCTAssertFalse(s.isSensitive(tag: "plain-1", agentName: nil))
    }

    func testAWorkSendMarksTheFocusOnce() {
        let s = FocusSensitivity(entries: { [] }, entriesChanged: Empty().eraseToAnyPublisher())
        var events: [String] = []
        s.becameSensitive.sink { events.append($0) }.store(in: &cancellables)
        s.noteWorkSend(tag: "w")
        s.noteWorkSend(tag: "w")
        XCTAssertEqual(events, ["w"])
        XCTAssertTrue(s.isSensitive(tag: "w", agentName: nil))
    }

    func testTheStoreFollowsTheRealFocusSensitivityOnAWorkSend() {
        let real = FocusSensitivity(entries: { [] }, entriesChanged: Empty().eraseToAnyPublisher())
        let store = ComposerHistoryStore(directory: directory, persists: true, sensitivity: real, scheduler: idleScheduler())
        store.record(tag: "w", text: "a")
        store.flush()
        XCTAssertEqual(files().count, 1)
        real.noteWorkSend(tag: "w")
        store.flush()
        XCTAssertEqual(files().count, 0)
    }
}
