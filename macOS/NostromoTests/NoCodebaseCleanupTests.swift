import XCTest

/// The clean-up of no-codebase folders nothing refers to any more: it moves them to the Trash (recoverable,
/// never deleted) and touches nothing else. Every run here is pointed at a throwaway root with an injected
/// trasher and clock; the real spaces root and the real Trash are not involved, except in the one test that
/// proves the real trash call, which uses a folder it made itself.
final class NoCodebaseCleanupTests: XCTestCase {

    private typealias F = HistoryFixtures
    private let fm = FileManager.default
    private var base: URL!
    private var root: URL!

    /// An hour on, so every folder made during the test is older than the 10 minute minimum age.
    private var later: Date { Date().addingTimeInterval(3600) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("nocodebase-cleanup-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("spaces", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let baseURL = self.base!
        addTeardownBlock { try? FileManager.default.removeItem(at: baseURL) }
    }

    // MARK: Helpers

    @discardableResult
    private func makeFolder(_ name: String = UUID().uuidString, in dir: URL? = nil, withFile: Bool = true) throws -> URL {
        let folder = (dir ?? root).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if withFile { try "x".write(to: folder.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8) }
        return folder
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// A listing that is complete (not degraded) and says these folders are still named by an entry.
    private func reply(referencing referenced: [String]? = []) -> ConversationHistoryWire {
        F.history([], referenced: referenced)
    }

    private struct Outcome {
        var count: Int
        var trashed: [String]
    }

    /// Runs the clean-up with a trasher that records what it was asked to trash and removes nothing.
    @discardableResult
    private func run(_ wire: ConversationHistoryWire, open: Set<String> = [], protected: Set<String> = [],
                     now: Date? = nil, root override: URL? = nil) -> Outcome {
        var trashed: [String] = []
        let count = NoCodebaseCleanup.run(reply: wire, openWorkingDirectories: open, protectedFolders: protected,
                                          root: override ?? root, now: now ?? later,
                                          trash: { trashed.append($0.lastPathComponent) })
        return Outcome(count: count, trashed: trashed.sorted())
    }

    // MARK: What it trashes

    func testAnUnreferencedOldFolderGoesToTheTrasher() throws {
        let orphan = try makeFolder()
        let out = run(reply())
        XCTAssertEqual(out.trashed, [orphan.lastPathComponent])
        XCTAssertEqual(out.count, 1)
    }

    func testEveryUnreferencedOldFolderIsTrashedAndNothingElse() throws {
        let a = try makeFolder(), b = try makeFolder()
        let kept = try makeFolder()
        let out = run(reply(referencing: [kept.path]))
        XCTAssertEqual(out.trashed, [a.lastPathComponent, b.lastPathComponent].sorted())
        XCTAssertEqual(out.count, 2)
    }

    func testTheRealTrashTakesTheFolderOutOfTheRootAndKeepsIt() throws {
        // Prove the trash call itself on a sacrificial folder first; where there is no usable Trash
        // (a headless runner), say so instead of failing for the environment.
        let probe = try makeFolder("probe", in: base)
        var probeResult: NSURL?
        do { try fm.trashItem(at: probe, resultingItemURL: &probeResult) }
        catch { throw XCTSkip("no usable Trash here: \(error.localizedDescription)") }
        if let url = probeResult as URL? { addTeardownBlock { try? FileManager.default.removeItem(at: url) } }

        let orphan = try makeFolder()
        let name = orphan.lastPathComponent
        let count = NoCodebaseCleanup.run(reply: reply(), openWorkingDirectories: [], root: root, now: later)

        XCTAssertEqual(count, 1)
        XCTAssertFalse(exists(orphan), "it left the root")
        // Moved, not deleted: the Trash holds it. (Skipped when the Trash cannot be listed from here.)
        if let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first,
           let inTrash = try? fm.contentsOfDirectory(atPath: trash.path) {
            XCTAssertTrue(inTrash.contains(name), "the folder is in the Trash, not deleted")
            let trashed = trash.appendingPathComponent(name)
            addTeardownBlock { try? FileManager.default.removeItem(at: trashed) }
            XCTAssertTrue(exists(trashed.appendingPathComponent("work.txt")), "with what was in it")
        }
    }

    // MARK: What it leaves alone

    func testAFolderAnEntryStillNamesIsLeftAlone() throws {
        let used = try makeFolder()
        let out = run(reply(referencing: [used.path]))
        XCTAssertEqual(out.trashed, [])
        XCTAssertEqual(out.count, 0)
    }

    func testAReferenceIsMatchedAsAPathNotAsAString() throws {
        // A trailing slash, a dot segment and a dot-dot segment still name the same folder.
        let used = try makeFolder()
        let name = used.lastPathComponent
        let spellings = [used.path + "/", root.path + "/./" + name, root.path + "/other/../" + name]
        for spelling in spellings {
            XCTAssertEqual(run(reply(referencing: [spelling])).trashed, [], spelling)
        }
    }

    func testTheFolderOfAnOpenFocusIsLeftAlone() throws {
        let open = try makeFolder()
        let out = run(reply(), open: [open.path])
        XCTAssertEqual(out.trashed, [])
    }

    func testAFolderAResumeIsAboutToUseIsLeftAlone() throws {
        let protectedFolder = try makeFolder()
        let out = run(reply(), protected: [protectedFolder.path])
        XCTAssertEqual(out.trashed, [])
    }

    func testAFolderYoungerThanTheMinimumAgeIsLeftAloneAndAnOlderOneIsNot() throws {
        let folder = try makeFolder()
        let made = try XCTUnwrap(try fm.attributesOfItem(atPath: folder.path)[.creationDate] as? Date)
        XCTAssertEqual(NoCodebaseCleanup.minimumAge, 600, "ten minutes")
        XCTAssertEqual(run(reply(), now: made.addingTimeInterval(599)).trashed, [], "a minute short of ten")
        XCTAssertEqual(run(reply(), now: made.addingTimeInterval(601)).trashed, [folder.lastPathComponent])
    }

    func testAFolderMadeJustNowIsLeftAlone() throws {
        try makeFolder()
        XCTAssertEqual(run(reply(), now: Date()).trashed, [], "a Create or a resume may have just made it")
    }

    func testFoldersWithoutAUUIDNameAreLeftAlone() throws {
        for name in ["notes", "not-a-uuid", "1234", ".hidden", "\(UUID().uuidString)-copy", "x\(UUID().uuidString)"] {
            try makeFolder(name)
        }
        let out = run(reply())
        XCTAssertEqual(out.trashed, [])
        XCTAssertEqual(out.count, 0)
    }

    func testASymbolicLinkWithAUUIDNameIsLeftAloneAndSoIsWhatItPointsAt() throws {
        let elsewhere = try makeFolder("precious", in: base)
        let link = root.appendingPathComponent(UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let out = run(reply())
        XCTAssertEqual(out.trashed, [])
        XCTAssertTrue(exists(elsewhere.appendingPathComponent("work.txt")))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "the link is still a link")
    }

    func testARegularFileWithAUUIDNameIsLeftAlone() throws {
        let file = root.appendingPathComponent(UUID().uuidString)
        try "not a folder".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(run(reply()).trashed, [])
        XCTAssertTrue(exists(file))
    }

    func testOnlyDirectChildrenOfTheRootAreConsidered() throws {
        // A UUID folder inside another folder under the root, and one next to the root.
        let holder = try makeFolder("holder")
        let nested = try makeFolder(in: holder)
        let sibling = try makeFolder(in: base)
        let out = run(reply())
        XCTAssertEqual(out.trashed, [])
        XCTAssertTrue(exists(nested))
        XCTAssertTrue(exists(sibling))
    }

    func testAMissingRootTrashesNothingAndDoesNotCrash() {
        let missing = base.appendingPathComponent("no-such-root", isDirectory: true)
        XCTAssertEqual(run(reply(), root: missing).count, 0)
    }

    // MARK: When the listing cannot be trusted

    func testADegradedListingTrashesNothing() throws {
        // A listing the daemon could only partly read may be missing entries that still name folders.
        try makeFolder()
        let wire = F.history([], degraded: 3, referenced: [])
        let out = run(wire)
        XCTAssertEqual(out.trashed, [])
        XCTAssertEqual(out.count, 0)
    }

    func testADegradedListingWithNothingKeptTrashesNothingEither() throws {
        try makeFolder()
        XCTAssertEqual(run(F.history([], degraded: 0, referenced: [])).trashed, [])
    }

    func testADaemonThatDoesNotSayWhichFoldersAreInUseTrashesNothing() throws {
        // `referenced_space_folders` absent: an older daemon, so nothing can be known to be unused.
        try makeFolder()
        let out = run(reply(referencing: nil))
        XCTAssertEqual(out.trashed, [])
        XCTAssertEqual(out.count, 0)
    }

    // MARK: When trashing fails

    private struct TrashFailure: Error {}

    func testAFailedTrashLeavesTheFolderAndItsContentsInPlace() throws {
        let orphan = try makeFolder()
        let count = NoCodebaseCleanup.run(reply: reply(), openWorkingDirectories: [], root: root, now: later,
                                          trash: { _ in throw TrashFailure() })
        XCTAssertEqual(count, 0, "nothing was trashed")
        XCTAssertTrue(exists(orphan), "the folder is not deleted as a fallback")
        XCTAssertTrue(exists(orphan.appendingPathComponent("work.txt")), "nor emptied")
    }

    func testOneFailedTrashDoesNotStopTheRest() throws {
        let a = try makeFolder("00000000-0000-0000-0000-00000000000A")
        let b = try makeFolder("00000000-0000-0000-0000-00000000000B")
        var asked: [String] = []
        let count = NoCodebaseCleanup.run(reply: reply(), openWorkingDirectories: [], root: root, now: later,
                                          trash: { url in
            asked.append(url.lastPathComponent)
            if url.lastPathComponent.hasSuffix("A") { throw TrashFailure() }
        })
        XCTAssertEqual(asked.sorted(), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertEqual(count, 1, "only the one that was trashed counts")
        XCTAssertTrue(exists(a), "the failed one stays for the next run")
    }

    // MARK: The store runs it after each good listing, and protects a resume's folder

    private final class SweepRecorder {
        var calls: [(wire: ConversationHistoryWire, protected: Set<String>)] = []
    }

    private func makeStore(_ rec: SweepRecorder, sender: RecordingHistorySender) -> ConversationHistoryStore {
        let url = fm.temporaryDirectory.appendingPathComponent("focuses-\(UUID().uuidString).json")
        let focusStore = FocusStore(storageURL: url)
        let store = ConversationHistoryStore(sender: sender, focusStore: { focusStore })
        store.noCodebaseSweeper = { wire, protected in rec.calls.append((wire, protected)) }
        return store
    }

    func testEveryListingTheDaemonSendsRunsTheSweep() {
        let rec = SweepRecorder()
        let store = makeStore(rec, sender: RecordingHistorySender())
        store.ingest(.conversationHistory(F.history([], referenced: ["/spaces/a"])))
        XCTAssertEqual(rec.calls.count, 1)
        XCTAssertEqual(rec.calls.first?.wire.referencedSpaceFolders, ["/spaces/a"], "it is handed the listing")
        store.ingest(.conversationHistory(F.history([], referenced: [])))
        XCTAssertEqual(rec.calls.count, 2, "the one after a purge too")
    }

    func testAFolderAResumeIsInFlightWithIsProtectedFromTheSweep() {
        let rec = SweepRecorder()
        let sender = RecordingHistorySender()
        let store = makeStore(rec, sender: sender)
        store.ingest(.conversationHistory(F.history([F.entry("sid1", status: .folderGone(worktree: true))])))
        store.resume("sid1", noCodebaseFolder: "/spaces/NEW")
        store.ingest(.conversationHistory(F.history([F.entry("sid1")], referenced: [])))
        XCTAssertEqual(rec.calls.last?.protected, ["/spaces/NEW"],
                       "the new folder is named by nothing the daemon lists yet")
    }

    func testNothingIsProtectedWhenNoResumeIsWaiting() {
        let rec = SweepRecorder()
        let store = makeStore(rec, sender: RecordingHistorySender())
        store.ingest(.conversationHistory(F.history([], referenced: [])))
        XCTAssertEqual(rec.calls.last?.protected, [])
    }
}
