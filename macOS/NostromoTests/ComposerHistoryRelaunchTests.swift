import XCTest
import Combine

// Composer history across a relaunch: a focus that was sent a work item must never reach the disk, even
// though the app has forgotten the work send by the time it starts again. Behaviour under test:
//   - the work-send marks survive a relaunch (kept as SHA-256 hex, never the tag), so the first thing typed
//     into such a focus after the relaunch is not written, and an old file for it is deleted;
//   - nothing is written while sensitivity is not yet known (the daemon's conversation list has not been
//     answered, or the marks could not be read); once known, only non-sensitive focuses are written;
//   - the connection tells the history store when to ask for the list, and when the answer (or the lack
//     of one) makes sensitivity known.
//
// Every store, marks file and history file lives under a temp directory; the user's real
// `~/.nostromo/composer-history.v1` is snapshotted before and compared after, and `FocusSensitivity.shared`
// and `ComposerHistoryStore.shared` are never touched. A "relaunch" is a new FocusSensitivity and a new
// ComposerHistoryStore over the same directory. No sleeping: a manual scheduler is run by the test, or
// `flush()` waits for the file queue.

/// A scheduler the test runs by hand (the debounce firing), unlike the idle one that never runs anything.
private final class RelaunchManualScheduler {
    private final class Item {
        let work: () -> Void
        var cancelled = false
        init(_ work: @escaping () -> Void) { self.work = work }
    }
    private var items: [Item] = []

    var scheduler: WorkScheduler {
        WorkScheduler { [weak self] _, work in
            let item = Item(work)
            self?.items.append(item)
            return { item.cancelled = true }
        }
    }

    /// Fires everything scheduled so far that was not cancelled (what the debounce elapsing does).
    func runAll() {
        let due = items
        items = []
        for item in due where !item.cancelled { item.work() }
    }
}

final class ComposerHistoryRelaunchTests: XCTestCase {

    private var root: URL!
    /// The history directory, which is also where the marks file lives (as the app wires it).
    private var directory: URL { root.appendingPathComponent("composer-history.v1", isDirectory: true) }
    private var cancellables: Set<AnyCancellable> = []
    private var realListingBefore: [String]?

    private static let realDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nostromo/composer-history.v1", isDirectory: true)

    /// Names, sizes and modification times of the user's real history directory; nil when it is absent.
    private static func realListing() -> [String]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: realDirectory.path) else { return nil }
        return names.sorted().map { name in
            let attrs = try? FileManager.default.attributesOfItem(atPath: realDirectory.appendingPathComponent(name).path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? -1
            let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            return "\(name)|\(size)|\(modified)"
        }
    }

    override func setUpWithError() throws {
        realListingBefore = Self.realListing()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-history-relaunch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        cancellables = []
        try? FileManager.default.removeItem(at: root)   // the test's own temp tree
        XCTAssertEqual(Self.realListing(), realListingBefore, "the real ~/.nostromo/composer-history.v1 was not touched")
    }

    // MARK: Helpers

    private func sensitivity(known: @escaping () -> Bool = { true },
                             knownChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
                             entries: @escaping () -> [ConversationEntryWire] = { [] },
                             entriesChanged: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
                             marksDirectory: URL? = nil) -> FocusSensitivity {
        FocusSensitivity(entries: entries, entriesChanged: entriesChanged, known: known, knownChanged: knownChanged,
                         marksDirectory: marksDirectory ?? directory)
    }

    private func store(_ sensitivity: FocusSensitivityProviding, scheduler: WorkScheduler? = nil) -> ComposerHistoryStore {
        ComposerHistoryStore(directory: directory, persists: true, sensitivity: sensitivity,
                             scheduler: scheduler ?? WorkScheduler { _, _ in { } })
    }

    private var marksFile: URL { directory.appendingPathComponent(FocusSensitivity.marksFileName) }

    private func allFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Composer-history files only (not the marks file).
    private func historyFiles() -> [URL] {
        allFiles().filter { $0.pathExtension == "json" && $0.lastPathComponent != FocusSensitivity.marksFileName }
    }

    private func historyFileName(_ tag: String) -> String { "\(FocusSensitivity.tagHash(tag)).json" }

    private func hasHistoryFile(for tag: String) -> Bool {
        historyFiles().contains { $0.lastPathComponent == historyFileName(tag) }
    }

    private func mode(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue & 0o777
    }

    /// The tag was work-sent in an earlier run: the marks file says so, and no object remembers it.
    private func markInEarlierRun(_ tag: String) {
        sensitivity().noteWorkSend(tag: tag)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marksFile.path), "the work send was persisted")
    }

    private func conversation(_ id: String, tag: String, sensitive: Bool) -> ConversationEntryWire {
        HistoryFixtures.entry(id, status: .running(tag: tag, open: true), sensitive: sensitive)
    }

    // MARK: 1. Relaunch

    func testAfterARelaunchTheFirstEntryIntoAWorkSentFocusIsNeverWritten() {
        markInEarlierRun("work-1")

        let relaunched = store(sensitivity())
        relaunched.record(tag: "work-1", text: "first thing after relaunch")
        relaunched.record(tag: "plain-1", text: "ordinary")
        relaunched.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"), "no file under its hash name")
        XCTAssertEqual(historyFiles().count, 1, "only the ordinary focus has a file")
        XCTAssertTrue(hasHistoryFile(for: "plain-1"))
        XCTAssertEqual(relaunched.entries(tag: "work-1"), ["first thing after relaunch"], "memory still works")
        XCTAssertEqual(store(sensitivity()).entries(tag: "work-1"), [], "and a second relaunch finds nothing for it")
    }

    func testAfterARelaunchTheDebounceFiringNeverWritesAWorkSentFocus() {
        markInEarlierRun("work-1")
        let manual = RelaunchManualScheduler()
        let relaunched = store(sensitivity(), scheduler: manual.scheduler)

        relaunched.record(tag: "work-1", text: "secret")
        relaunched.record(tag: "plain-1", text: "ordinary")
        manual.runAll()      // the debounce elapses
        relaunched.flush()   // waits for the file queue

        XCTAssertFalse(hasHistoryFile(for: "work-1"))
        XCTAssertTrue(hasHistoryFile(for: "plain-1"), "the debounce did write the ordinary focus")
        XCTAssertFalse(allFiles().contains { $0.lastPathComponent.hasPrefix(FocusSensitivity.tagHash("work-1")) },
                       "no file of any kind has its hash name")
    }

    func testAnOldHistoryFileOfAWorkSentFocusIsDeletedAfterARelaunch() throws {
        // A file written before the work send was ever noted (an earlier build, or before the focus was marked).
        let earlier = store(FakeFocusSensitivity())
        earlier.record(tag: "work-1", text: "old note")
        earlier.record(tag: "plain-1", text: "keep me")
        earlier.flush()
        XCTAssertTrue(hasHistoryFile(for: "work-1"))
        markInEarlierRun("work-1")
        XCTAssertTrue(hasHistoryFile(for: "work-1"), "nothing has deleted it yet")

        let relaunched = store(sensitivity())
        XCTAssertEqual(relaunched.entries(tag: "work-1"), [], "not recalled from the old file")
        relaunched.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"), "the old file is deleted")
        XCTAssertTrue(hasHistoryFile(for: "plain-1"), "other focuses are left alone")
        XCTAssertEqual(store(sensitivity()).entries(tag: "plain-1"), ["keep me"])
    }

    func testAnOldHistoryFileIsDeletedWhenTheFirstEntryIsRecordedIntoTheFocusAfterARelaunch() {
        let earlier = store(FakeFocusSensitivity())
        earlier.record(tag: "work-1", text: "old note")
        earlier.flush()
        markInEarlierRun("work-1")

        let relaunched = store(sensitivity())
        relaunched.record(tag: "work-1", text: "new")
        relaunched.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"))
        XCTAssertEqual(relaunched.entries(tag: "work-1"), ["new"], "the old note was not recalled into the new history")
    }

    func testTheWorkSendMarkSurvivesSeveralRelaunches() {
        markInEarlierRun("work-1")
        for _ in 0..<3 {
            let s = sensitivity()
            XCTAssertTrue(s.isSensitive(tag: "work-1", agentName: nil))
            XCTAssertFalse(s.isSensitive(tag: "plain-1", agentName: nil))
            let relaunched = store(s)
            relaunched.record(tag: "work-1", text: "x")
            relaunched.flush()
        }
        XCTAssertFalse(hasHistoryFile(for: "work-1"))
    }

    // MARK: 2. Not yet known

    func testNothingIsWrittenWhileSensitivityIsNotKnownAndThePendingEntriesAreWrittenOnceItIs() {
        var known = false
        let becameKnown = PassthroughSubject<Void, Never>()
        let manual = RelaunchManualScheduler()
        let s = sensitivity(known: { known }, knownChanged: becameKnown.eraseToAnyPublisher())
        let history = store(s, scheduler: manual.scheduler)

        history.record(tag: "plain-1", text: "typed early")
        manual.runAll()
        history.flush()
        XCTAssertEqual(historyFiles().count, 0, "not written: a focus not yet known not to be sensitive")
        XCTAssertEqual(history.entries(tag: "plain-1"), ["typed early"], "but memory has it")

        known = true
        let written = expectation(description: "the pending write happens once sensitivity is known, unprompted")
        history.onWriteCompleted = { written.fulfill() }
        becameKnown.send()
        manual.runAll()   // the debounce the reschedule asked for; no flush() here
        wait(for: [written], timeout: 5)

        XCTAssertTrue(hasHistoryFile(for: "plain-1"))
        XCTAssertEqual(store(sensitivity()).entries(tag: "plain-1"), ["typed early"])
    }

    func testFlushWritesNothingWhileSensitivityIsNotKnown() {
        let fake = FakeFocusSensitivity()
        fake.isKnown = false
        let history = store(fake)
        history.record(tag: "t", text: "a")
        history.flush()
        history.flush()
        XCTAssertEqual(allFiles().count, 0)

        fake.becomeKnown()
        history.flush()
        XCTAssertTrue(hasHistoryFile(for: "t"), "known now: written")
    }

    func testAFocusThatTurnsOutToBeSensitiveWhenTheListArrivesIsNeverWritten() {
        var known = false
        var listed: [ConversationEntryWire] = []
        let becameKnown = PassthroughSubject<Void, Never>()
        let listChanged = PassthroughSubject<Void, Never>()
        let s = sensitivity(known: { known }, knownChanged: becameKnown.eraseToAnyPublisher(),
                            entries: { listed }, entriesChanged: listChanged.eraseToAnyPublisher())
        let manual = RelaunchManualScheduler()
        let history = store(s, scheduler: manual.scheduler)

        history.record(tag: "work-1", text: "secret typed before the answer")
        history.record(tag: "plain-1", text: "ordinary")

        // The daemon answers: work-1 is a sensitive running conversation.
        listed = [conversation("c1", tag: "work-1", sensitive: true), conversation("c2", tag: "plain-1", sensitive: false)]
        known = true
        listChanged.send()
        becameKnown.send()
        manual.runAll()
        history.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"), "sensitive: never written")
        XCTAssertTrue(hasHistoryFile(for: "plain-1"), "not sensitive: written")
        XCTAssertEqual(history.entries(tag: "work-1"), ["secret typed before the answer"], "memory has it")
    }

    func testAFocusMarkedByAWorkSendWhileNotYetKnownIsNeverWrittenOnceKnown() {
        let fake = FakeFocusSensitivity()
        fake.isKnown = false
        let history = store(fake)
        history.record(tag: "work-1", text: "secret")
        history.record(tag: "plain-1", text: "ordinary")
        fake.becomeSensitive("work-1")
        fake.becomeKnown()
        history.flush()
        XCTAssertFalse(hasHistoryFile(for: "work-1"))
        XCTAssertTrue(hasHistoryFile(for: "plain-1"))
    }

    func testAMarkedFocusStaysUnwrittenAfterRelaunchWhileTheDaemonHasNotAnsweredAndAfterItDoes() {
        markInEarlierRun("work-1")
        var known = false
        let becameKnown = PassthroughSubject<Void, Never>()
        let s = sensitivity(known: { known }, knownChanged: becameKnown.eraseToAnyPublisher())
        let history = store(s)
        history.record(tag: "work-1", text: "secret")
        history.flush()
        known = true
        becameKnown.send()
        history.flush()
        XCTAssertFalse(hasHistoryFile(for: "work-1"))
        XCTAssertEqual(historyFiles().count, 0)
    }

    func testBecameKnownFiresOnlyWhenKnownIsTrue() {
        var known = false
        let knownChanged = PassthroughSubject<Void, Never>()
        let s = sensitivity(known: { known }, knownChanged: knownChanged.eraseToAnyPublisher())
        var fired = 0
        s.becameKnown.sink { fired += 1 }.store(in: &cancellables)
        XCTAssertFalse(s.isKnown)
        knownChanged.send()
        XCTAssertEqual(fired, 0, "a knownChanged that leaves it unknown is not 'became known'")
        known = true
        knownChanged.send()
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(s.isKnown)
    }

    // MARK: 3. Connection and the conversation list

    /// The app's wiring, with the history store standing in for the daemon's connection state.
    private func wired(_ sender: RecordingHistorySender)
        -> (conversations: ConversationHistoryStore, sensitivity: FocusSensitivity) {
        let conversations = ConversationHistoryStore(sender: sender)
        conversations.noCodebaseSweeper = { _, _ in }
        let s = FocusSensitivity(entries: { conversations.history?.entries ?? [] },
                                 entriesChanged: conversations.changes.eraseToAnyPublisher(),
                                 known: { conversations.sensitivityKnown },
                                 knownChanged: conversations.knownChanges.eraseToAnyPublisher(),
                                 marksDirectory: directory)
        return (conversations, s)
    }

    func testADaemonWithoutTheListMakesSensitivityKnownOnConnectAndSendsNoGet() {
        let sender = RecordingHistorySender()
        sender.daemonAdvertisesConversationHistory = false
        let (conversations, _) = wired(sender)
        XCTAssertFalse(conversations.sensitivityKnown, "not before a connection")
        var announced = 0
        conversations.knownChanges.sink { announced += 1 }.store(in: &cancellables)

        conversations.connectionChanged(true)

        XCTAssertTrue(conversations.sensitivityKnown)
        XCTAssertEqual(announced, 1)
        XCTAssertEqual(sender.gets, 0, "nothing to ask a daemon that has no list")
    }

    func testOnADaemonWithoutTheListAWorkSentFocusStaysInMemoryAndAnUnmarkedOneIsWritten() {
        markInEarlierRun("work-1")   // a work item was sent into it before the relaunch
        let sender = RecordingHistorySender()
        sender.daemonAdvertisesConversationHistory = false
        let (conversations, s) = wired(sender)
        let history = store(s)

        history.record(tag: "work-1", text: "secret")
        history.record(tag: "plain-1", text: "ordinary")
        history.flush()
        XCTAssertEqual(historyFiles().count, 0, "nothing before the connection says sensitivity is known")

        conversations.connectionChanged(true)
        history.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"), "the marked focus stays memory only")
        XCTAssertTrue(hasHistoryFile(for: "plain-1"), "the unmarked one is written")
        XCTAssertEqual(history.entries(tag: "work-1"), ["secret"])
    }

    func testOnADaemonWithTheListConnectingSendsExactlyOneGetAndSensitivityStaysUnknownUntilAListingIsIngested() {
        let sender = RecordingHistorySender()
        let (conversations, s) = wired(sender)
        let history = store(s)

        conversations.connectionChanged(true)
        XCTAssertEqual(sender.gets, 1)
        XCTAssertFalse(conversations.sensitivityKnown, "asked, not answered")
        XCTAssertFalse(s.isKnown)

        history.record(tag: "plain-1", text: "typed before the answer")
        history.flush()
        XCTAssertEqual(historyFiles().count, 0, "nothing written until the listing arrives")

        conversations.ingest(.conversationHistory(HistoryFixtures.history([])))
        XCTAssertTrue(conversations.sensitivityKnown)
        XCTAssertTrue(s.isKnown)
        history.flush()
        XCTAssertTrue(hasHistoryFile(for: "plain-1"), "known and not sensitive: written")
    }

    func testAListingThatNamesASensitiveRunningFocusKeepsItOffTheDisk() {
        let sender = RecordingHistorySender()
        let (conversations, s) = wired(sender)
        let history = store(s)
        conversations.connectionChanged(true)

        history.record(tag: "work-1", text: "secret")
        history.record(tag: "plain-1", text: "ordinary")
        conversations.ingest(.conversationHistory(HistoryFixtures.history([
            conversation("c1", tag: "work-1", sensitive: true),
            conversation("c2", tag: "plain-1", sensitive: false)])))
        history.flush()

        XCTAssertFalse(hasHistoryFile(for: "work-1"))
        XCTAssertTrue(hasHistoryFile(for: "plain-1"))
    }

    func testKnownChangesFiresAfterChangesWhenAListingIsIngestedAndOnlyTheFirstTime() {
        let sender = RecordingHistorySender()
        let (conversations, _) = wired(sender)
        var order: [String] = []
        conversations.changes.sink { order.append("changes") }.store(in: &cancellables)
        conversations.knownChanges.sink { order.append("known") }.store(in: &cancellables)

        conversations.ingest(.conversationHistory(HistoryFixtures.history([])))
        conversations.ingest(.conversationHistory(HistoryFixtures.history([])))

        XCTAssertEqual(order, ["changes", "known", "changes"], "known follows the listing's own change, once")
    }

    func testEachReconnectAsksAgainAndADisconnectAsksNothing() {
        let sender = RecordingHistorySender()
        let (conversations, _) = wired(sender)

        conversations.connectionChanged(false)
        XCTAssertEqual(sender.gets, 0, "a disconnect sends nothing")

        conversations.connectionChanged(true)
        XCTAssertEqual(sender.gets, 1)
        conversations.connectionChanged(false)
        XCTAssertEqual(sender.gets, 1)
        conversations.connectionChanged(true)
        XCTAssertEqual(sender.gets, 2, "a reconnect asks again")
    }

    func testIfTheDaemonNeverAnswersNothingIsWrittenForTheWholeRun() {
        let sender = RecordingHistorySender()
        let (conversations, s) = wired(sender)
        let manual = RelaunchManualScheduler()
        let history = store(s, scheduler: manual.scheduler)
        conversations.connectionChanged(true)
        conversations.connectionChanged(false)
        conversations.connectionChanged(true)

        history.record(tag: "plain-1", text: "a")
        manual.runAll()
        history.flush()
        history.record(tag: "plain-1", text: "b")
        manual.runAll()
        history.flush()

        XCTAssertFalse(conversations.sensitivityKnown)
        XCTAssertEqual(historyFiles().count, 0, "fail closed")
        XCTAssertEqual(history.entries(tag: "plain-1"), ["b", "a"], "memory works")
    }

    // MARK: 4. The marks file

    func testTheMarksFileIs0600InADirectory0700AndHoldsTheHashOfTheTag() throws {
        let old = umask(0)
        defer { umask(old) }
        sensitivity().noteWorkSend(tag: "work-1")

        XCTAssertEqual(try mode(of: marksFile), 0o600)
        XCTAssertEqual(try mode(of: directory), 0o700)
        let text = try String(contentsOf: marksFile, encoding: .utf8)
        XCTAssertTrue(text.contains(FocusSensitivity.tagHash("work-1")), "the hash is in the file")
        XCTAssertEqual(FocusSensitivity.tagHash("work-1").count, 64)
        XCTAssertEqual(allFiles().filter { $0.lastPathComponent.hasSuffix(".tmp") }.count, 0, "no temporary left behind")
    }

    func testAnExistingWideDirectoryIsTightenedWhenTheMarksFileIsWritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        sensitivity().noteWorkSend(tag: "work-1")
        XCTAssertEqual(try mode(of: directory), 0o700)
        XCTAssertEqual(try mode(of: marksFile), 0o600)
    }

    func testNeitherTheMarksFileNorAnyOtherFileHoldsTheTagOrTheEntryText() throws {
        let tag = "CANARY-TAG-claudia-7f3a"
        let secret = "CANARY-ENTRY-do-not-persist"
        let s = sensitivity()
        let history = store(s)
        history.record(tag: tag, text: secret)       // typed, then
        s.noteWorkSend(tag: tag)                     // the work item is sent
        history.record(tag: tag, text: secret + "2")
        history.record(tag: "plain-1", text: "ordinary")
        history.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: marksFile.path))
        for file in allFiles() {
            let bytes = try Data(contentsOf: file)
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertFalse(text.contains("CANARY-TAG"), "\(file.lastPathComponent) holds the tag")
            XCTAssertFalse(text.contains("CANARY-ENTRY"), "\(file.lastPathComponent) holds entry text")
            XCTAssertFalse(file.lastPathComponent.contains("CANARY"), "a file name holds the tag")
        }
        XCTAssertTrue(try String(contentsOf: marksFile, encoding: .utf8).contains(FocusSensitivity.tagHash(tag)))
    }

    func testClearHistoryOnAMarkedFocusDoesNotUnmarkIt() throws {
        let s = sensitivity()
        let history = store(s)
        s.noteWorkSend(tag: "work-1")
        history.record(tag: "work-1", text: "secret")

        history.clear(tag: "work-1")
        XCTAssertEqual(history.entries(tag: "work-1"), [])
        XCTAssertTrue(s.isSensitive(tag: "work-1", agentName: nil), "still sensitive")
        XCTAssertTrue(try String(contentsOf: marksFile, encoding: .utf8).contains(FocusSensitivity.tagHash("work-1")),
                      "and still in the marks file")

        history.record(tag: "work-1", text: "after clear")
        history.flush()
        XCTAssertFalse(hasHistoryFile(for: "work-1"), "still never written")

        let relaunchedSensitivity = sensitivity()
        XCTAssertTrue(relaunchedSensitivity.isSensitive(tag: "work-1", agentName: nil), "and after a relaunch")
    }

    func testClosingAMarkedFocusDoesNotUnmarkItEither() throws {
        let s = sensitivity()
        let history = store(s)
        s.noteWorkSend(tag: "work-1")
        history.removeFocus(tag: "work-1")
        XCTAssertTrue(sensitivity().isSensitive(tag: "work-1", agentName: nil))
    }

    func testAMarkLoadedFromTheFileIsRespectedBeforeAnyHistoryFileIsLoaded() {
        markInEarlierRun("work-1")
        let s = sensitivity()
        XCTAssertTrue(s.isSensitive(tag: "work-1", agentName: nil), "known from the file alone, no scan, no entry list")
        XCTAssertFalse(s.isSensitive(tag: "plain-1", agentName: nil))

        // A store that has loaded nothing yet: the very first record into the tag.
        let history = store(s)
        history.record(tag: "work-1", text: "first")
        history.flush()
        XCTAssertEqual(historyFiles().count, 0)
        XCTAssertTrue(history.isMemoryOnly(tag: "work-1"))
    }

    func testMarksFromSeveralWorkSendsAllSurvive() {
        let s = sensitivity()
        s.noteWorkSend(tag: "work-1")
        s.noteWorkSend(tag: "work-2")
        let relaunched = sensitivity()
        XCTAssertTrue(relaunched.isSensitive(tag: "work-1", agentName: nil))
        XCTAssertTrue(relaunched.isSensitive(tag: "work-2", agentName: nil))
        XCTAssertFalse(relaunched.isSensitive(tag: "work-3", agentName: nil))
    }

    private func assertFailsClosedOnMarksFile(containing bytes: Data, _ label: String,
                                              file: StaticString = #filePath, line: UInt = #line) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try bytes.write(to: marksFile)
        let becameKnown = PassthroughSubject<Void, Never>()
        let s = sensitivity(known: { true }, knownChanged: becameKnown.eraseToAnyPublisher())
        var fired = 0
        s.becameKnown.sink { fired += 1 }.store(in: &cancellables)

        XCTAssertFalse(s.isKnown, "\(label): unreadable marks mean sensitivity is not known", file: file, line: line)
        becameKnown.send()
        XCTAssertEqual(fired, 0, "\(label): and never becomes known", file: file, line: line)

        let manual = RelaunchManualScheduler()
        let history = store(s, scheduler: manual.scheduler)
        history.record(tag: "plain-1", text: "ordinary")
        manual.runAll()
        history.flush()
        XCTAssertEqual(historyFiles().count, 0, "\(label): nothing is written", file: file, line: line)
        XCTAssertEqual(history.entries(tag: "plain-1"), ["ordinary"], "\(label): memory still works", file: file, line: line)
    }

    func testAMarksFileOfGarbageBytesLeavesSensitivityUnknownAndNothingIsWritten() throws {
        try assertFailsClosedOnMarksFile(containing: Data([0xFF, 0x00, 0xFE, 0x13, 0x37, 0x80]), "garbage")
    }

    func testAMarksFileOfTruncatedJSONLeavesSensitivityUnknownAndNothingIsWritten() throws {
        try assertFailsClosedOnMarksFile(containing: Data("{\"version\":1,\"tags\":[\"ab".utf8), "truncated")
    }

    func testAMarksFileOfAnUnknownVersionLeavesSensitivityUnknownAndNothingIsWritten() throws {
        try assertFailsClosedOnMarksFile(containing: Data("{\"version\":2,\"tags\":[]}".utf8), "wrong version")
    }

    func testAMissingMarksFileIsNotCorruptItIsNoMarks() {
        let s = sensitivity()
        XCTAssertTrue(s.isKnown, "a first run has no marks file and that is fine")
        let history = store(s)
        history.record(tag: "plain-1", text: "a")
        history.flush()
        XCTAssertTrue(hasHistoryFile(for: "plain-1"))
    }

    func testAMarkThatCannotBeSavedLeavesSensitivityUnknownSoNothingIsWritten() throws {
        // The "directory" is a regular file, so the marks file cannot be created and a relaunch would forget the mark.
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let s = sensitivity(marksDirectory: blocker)
        XCTAssertTrue(s.isKnown)
        s.noteWorkSend(tag: "work-1")
        XCTAssertTrue(s.isSensitive(tag: "work-1", agentName: nil), "still sensitive for this run")
        XCTAssertFalse(s.isKnown, "but sensitivity is no longer trusted: fail closed")

        let history = store(s)
        history.record(tag: "plain-1", text: "ordinary")
        history.flush()
        XCTAssertEqual(history.entries(tag: "plain-1"), ["ordinary"], "memory still works")
        XCTAssertFalse(hasHistoryFile(for: "plain-1"), "nothing is written")
    }

    func testAMarksFileHoldsOnlyDigestsAfterManyMarks() throws {
        let s = sensitivity()
        let tags = (0..<5).map { "CANARY-TAG-\($0)" }
        tags.forEach { s.noteWorkSend(tag: $0) }
        let text = try String(contentsOf: marksFile, encoding: .utf8)
        XCTAssertFalse(text.contains("CANARY"))
        for tag in tags { XCTAssertTrue(text.contains(FocusSensitivity.tagHash(tag))) }
    }
}
