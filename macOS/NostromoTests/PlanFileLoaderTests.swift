import XCTest
import AppKit
import NostromoKit

// SR7: what a plan path may turn into on screen. The rules (`PlanFileRules.read`) decide, for any path
// Mother hands us, whether its bytes are ever read and what the outcome is; the loader (`PlanFileLoader`)
// runs them off the main thread, delivers only the newest load's result, and watches the file.
//
// Everything here uses temp files. Waits are conditions pumped on the run loop (the timeout is only the
// failure bound); the watcher's debounce is a `ManualPlanReloadScheduler` fired by hand.

// MARK: - Shared support (also used by PlanDocumentViewTests and MotherDetailSwitchTests)

/// Fixtures, temp directories and run-loop waits for the plan-viewer tests.
enum PlanTestSupport {

    /// `Shared/NostromoKit/Tests/NostromoKitTests/Fixtures/plans`, found from this file (the Mac test
    /// target cannot see Kit's test resources).
    static let fixtureDirectory: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }   // NostromoTests, macOS, repo root
        return url.appendingPathComponent("Shared/NostromoKit/Tests/NostromoKitTests/Fixtures/plans", isDirectory: true)
    }()

    static func fixtureURL(_ name: String) -> URL { fixtureDirectory.appendingPathComponent(name) }

    static func fixtureText(_ name: String) throws -> String {
        try String(contentsOf: fixtureURL(name), encoding: .utf8)
    }

    /// A fresh directory that is removed when the test ends.
    static func tempDirectory(_ tc: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tc.addTeardownBlock {
            // A test may have left a file unreadable; make everything removable first.
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for item in items { _ = chmod(dir.appendingPathComponent(item).path, 0o644) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    /// A copy of a fixture in `dir` under `name` (default: `plan.md`).
    @discardableResult
    static func copyFixture(_ fixture: String, into dir: URL, as name: String = "plan.md") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL(fixture), to: url)
        return url
    }

    /// Runs the main run loop until `condition` holds (true) or `timeout` passes (false). The timeout is a
    /// failure bound, not a duration the test depends on.
    static func pumpUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if condition() { return true }
        }
        return condition()
    }

    /// Edit a file in place (the same inode: a write event, not a rename).
    static func writeInPlace(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    /// Replace a file the way an editor's safe-save does (a new inode renamed over the path).
    static func writeAtomically(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A scheduler whose pending work runs only when a test calls `fire()`.
final class ManualPlanReloadScheduler: PlanReloadScheduler {

    private final class Token: PlanReloadToken {
        var work: (() -> Void)?
        func cancel() { work = nil }
    }

    private var tokens: [Token] = []
    /// Every `schedule` call, cancelled or not.
    private(set) var scheduledCount = 0
    /// The `delay` of every `schedule` call, in order, cancelled or not.
    private(set) var delays: [TimeInterval] = []
    /// Work that was scheduled and neither cancelled nor run.
    var livePendingCount: Int { tokens.filter { $0.work != nil }.count }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> PlanReloadToken {
        scheduledCount += 1
        delays.append(delay)
        let token = Token()
        token.work = work
        tokens.append(token)
        return token
    }

    /// Run everything still pending.
    func fire() {
        let due = tokens
        tokens = []
        for token in due {
            guard let work = token.work else { continue }
            token.work = nil
            work()
        }
    }
}

// MARK: - Rules

final class PlanFileRulesTests: XCTestCase {

    private func read(_ url: URL) -> PlanFileResult { PlanFileRules.read(path: url.path) }

    private func file(_ dir: URL, _ name: String, _ bytes: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func inode(_ path: String) -> UInt64 {
        var info = stat()
        return stat(path, &info) == 0 ? UInt64(info.st_ino) : 0
    }

    // MARK: Refusals that never read the bytes

    func testAFileThatIsNotMarkdownIsRefusedAndItsBytesNeverShow() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let secret = "SECRET-\(UUID().uuidString)"
        let url = try file(dir, "notes.txt", Data(secret.utf8))
        let result = read(url)
        XCTAssertEqual(result, .notMarkdown)
        XCTAssertFalse("\(result)".contains("SECRET-"), "the outcome carries none of the file's text")
    }

    func testAMarkdownNamedLinkToANonMarkdownFileIsRefusedByWhatItResolvesTo() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let secret = "SECRET-\(UUID().uuidString)"
        let target = try file(dir, "secret.txt", Data(secret.utf8))
        let link = dir.appendingPathComponent("plan.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = read(link)
        XCTAssertEqual(result, .notMarkdown)
        XCTAssertFalse("\(result)".contains("SECRET-"))
    }

    func testADirectoryNamedLikeMarkdownIsRefused() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let folder = dir.appendingPathComponent("x.md", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(read(folder), .notMarkdown)
    }

    func testAPipeNamedLikeMarkdownIsRefusedWithoutBlocking() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let fifo = dir.appendingPathComponent("x.md")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0, "the fixture pipe could not be made")

        var result: PlanFileResult?
        let finished = expectation(description: "the read of a pipe returned")
        DispatchQueue.global(qos: .utility).async {
            result = PlanFileRules.read(path: fifo.path)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 20)   // a failure bound: a read that blocks never fulfils
        XCTAssertEqual(result, .notMarkdown)
    }

    // MARK: Size

    func testAFileOfExactlyOneMebibyteLoads() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try file(dir, "plan.md", Data(repeating: UInt8(ascii: "a"), count: 1_048_576))
        guard case .loaded(let text, _, _) = read(url) else { return XCTFail("a 1,048,576 byte file must load") }
        XCTAssertEqual(text.utf8.count, 1_048_576)
    }

    func testAFileOneByteOverOneMebibyteIsTooLarge() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try file(dir, "plan.md", Data(repeating: UInt8(ascii: "a"), count: 1_048_577))
        XCTAssertEqual(read(url), .tooLarge)
    }

    // MARK: Text

    func testBytesThatAreNotUTF8AreRefused() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try file(dir, "plan.md", Data([0xFF, 0xFE, 0x41, 0x80, 0x0A]))
        XCTAssertEqual(read(url), .notUTF8)
    }

    // MARK: Access

    func testAFileWithNoPermissionsIsNotReadable() throws {
        try XCTSkipIf(geteuid() == 0, "root reads files whatever their mode")
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = try file(dir, "plan.md", Data("# Hidden\n".utf8))
        XCTAssertEqual(chmod(url.path, 0o000), 0)
        XCTAssertEqual(read(url), .notReadable)
    }

    func testAMissingFileIsNotFound() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        XCTAssertEqual(read(dir.appendingPathComponent("gone.md")), .notFound)
    }

    func testAnEmptyPathIsNotFound() {
        XCTAssertEqual(PlanFileRules.read(path: ""), .notFound)
    }

    // MARK: What loads

    func testMarkdownExtensionsAreAcceptedInAnyCase() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        for name in ["a.MD", "b.markdown", "c.mdown", "d.Markdown", "e.md"] {
            let url = try file(dir, name, Data("# \(name)\n".utf8))
            guard case .loaded(let text, _, _) = read(url) else { XCTFail("\(name) must load"); continue }
            XCTAssertEqual(text, "# \(name)\n")
        }
    }

    func testALinkToARealMarkdownFileLoadsAndReportsTheResolvedPath() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let realDir = dir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let target = try file(realDir, "actual.md", Data("# Linked\n".utf8))
        let link = dir.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        guard case .loaded(let text, let url, let modified) = read(link) else { return XCTFail("a link to a .md file must load") }
        XCTAssertEqual(text, "# Linked\n")
        XCTAssertEqual(url.lastPathComponent, "actual.md", "the url is where the bytes came from, not the link")
        XCTAssertEqual(inode(url.path), inode(target.path))
        XCTAssertNotNil(modified)
    }
}

// MARK: - Loader

final class PlanFileLoaderTests: XCTestCase {

    /// A loader with a manual scheduler, and every result it delivers.
    private final class Probe {
        let scheduler = ManualPlanReloadScheduler()
        let loader: PlanFileLoader
        private(set) var results: [PlanFileResult] = []
        private(set) var deliveredOnMain = true

        init(reader: PlanFileLoader.Reader? = nil, readQueue: DispatchQueue = .global(qos: .utility)) {
            if let reader {
                loader = PlanFileLoader(reader: reader, scheduler: scheduler, readQueue: readQueue)
            } else {
                loader = PlanFileLoader(scheduler: scheduler, readQueue: readQueue)
            }
            loader.onResult = { [weak self] result in
                if !Thread.isMainThread { self?.deliveredOnMain = false }
                self?.results.append(result)
            }
        }

        var texts: [String] {
            results.compactMap { if case .loaded(let text, _, _) = $0 { return text } else { return nil } }
        }
    }

    private func waitFor(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) {
        XCTAssertTrue(PlanTestSupport.pumpUntil(condition), "timed out waiting for \(what)", file: file, line: line)
    }

    /// Everything queued on the main queue so far has run.
    private func drainMain() {
        var done = false
        DispatchQueue.main.async { done = true }
        XCTAssertTrue(PlanTestSupport.pumpUntil { done })
    }

    // MARK: Loading

    func testLoadDeliversTheFileOnTheMainThread() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("# One\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        waitFor("the first result") { !probe.results.isEmpty }
        XCTAssertEqual(probe.texts, ["# One\n"])
        XCTAssertTrue(probe.deliveredOnMain)
    }

    func testLoadingANilOrEmptyPathReadsNothingAndWatchesNothing() throws {
        let probe = Probe(reader: { _ in XCTFail("nothing may be read"); return .notFound })
        probe.loader.load(path: nil)
        probe.loader.load(path: "")
        drainMain()
        XCTAssertTrue(probe.results.isEmpty)
        XCTAssertFalse(probe.loader.isWatching)
    }

    // MARK: Stale results

    func testAResultFromAnOlderLoadIsNeverDelivered() {
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "plan.loader.test.read", attributes: .concurrent)
        let probe = Probe(reader: { path in
            if path == "/slow-first" { gate.wait(); return .notFound }
            return .loaded(text: path, url: URL(fileURLWithPath: path), modified: nil)
        }, readQueue: queue)

        probe.loader.load(path: "/slow-first")
        probe.loader.load(path: "/second")
        waitFor("the second path's result") { !probe.results.isEmpty }

        gate.signal()                                 // the first read finishes now, too late
        queue.sync(flags: .barrier) {}                // ...and its hop to the main queue is enqueued
        drainMain()                                   // ...and has run, if it was going to

        XCTAssertEqual(probe.results, [.loaded(text: "/second", url: URL(fileURLWithPath: "/second"), modified: nil)])
    }

    func testStopDropsAResultStillInFlight() {
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "plan.loader.test.read", attributes: .concurrent)
        let probe = Probe(reader: { _ in gate.wait(); return .notFound }, readQueue: queue)

        probe.loader.load(path: "/anything")
        probe.loader.stop()
        gate.signal()
        queue.sync(flags: .barrier) {}
        drainMain()

        XCTAssertTrue(probe.results.isEmpty, "a read that finished after stop() is not delivered")
    }

    func testEachLoadAndStopTakesANewGeneration() {
        let probe = Probe(reader: { _ in .notFound })
        let g0 = probe.loader.generation
        probe.loader.load(path: "/a")
        let g1 = probe.loader.generation
        probe.loader.stop()
        let g2 = probe.loader.generation
        XCTAssertLessThan(g0, g1)
        XCTAssertLessThan(g1, g2)
    }

    // MARK: Watching

    func testAnInPlaceEditSchedulesAReloadAndAfterItTheNewTextArrivesAndTheWatchStays() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("first\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        waitFor("the first result") { probe.texts == ["first\n"] }
        XCTAssertTrue(probe.loader.isWatching)
        XCTAssertFalse(probe.loader.hasPendingReload)

        try PlanTestSupport.writeInPlace("second\n", to: url)
        waitFor("the edit to be seen") { probe.loader.hasPendingReload }
        XCTAssertEqual(probe.texts, ["first\n"], "nothing reloads before the scheduler runs")

        probe.scheduler.fire()
        waitFor("the reloaded text") { probe.texts.last == "second\n" }
        XCTAssertTrue(probe.loader.isWatching, "the watch is armed again after a reload")
        XCTAssertFalse(probe.loader.hasPendingReload)

        // A second edit still reloads.
        try PlanTestSupport.writeInPlace("third\n", to: url)
        waitFor("the second edit to be seen") { probe.loader.hasPendingReload }
        probe.scheduler.fire()
        waitFor("the second reload") { probe.texts.last == "third\n" }
    }

    func testReplacingTheFileAtomicallyAlsoReloadsAndRearmsOnTheNewFile() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("first\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        waitFor("the first result") { probe.texts == ["first\n"] }

        try PlanTestSupport.writeAtomically("replaced\n", to: url)
        waitFor("the replacement to be seen") { probe.loader.hasPendingReload }
        probe.scheduler.fire()
        waitFor("the replaced text") { probe.texts.last == "replaced\n" }
        XCTAssertTrue(probe.loader.isWatching, "the watch moved to the new file")

        // The new file is the one watched: an in-place edit of it reloads.
        try PlanTestSupport.writeInPlace("edited after replace\n", to: url)
        waitFor("the edit of the new file to be seen") { probe.loader.hasPendingReload }
        probe.scheduler.fire()
        waitFor("the reload of the new file") { probe.texts.last == "edited after replace\n" }
    }

    func testABurstOfChangesIsOneReload() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("zero\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        waitFor("the first result") { probe.texts == ["zero\n"] }

        for n in 1...5 { try PlanTestSupport.writeInPlace("burst \(n)\n", to: url) }
        waitFor("the burst to be seen") { probe.loader.hasPendingReload }
        XCTAssertEqual(probe.scheduler.livePendingCount, 1, "events coalesce into one pending reload")

        let before = probe.results.count
        probe.scheduler.fire()
        waitFor("the reload") { probe.results.count > before }
        drainMain()
        XCTAssertEqual(probe.results.count, before + 1, "one reload for the whole burst")
        XCTAssertEqual(probe.texts.last, "burst 5\n")
    }

    func testStopCancelsTheWatchAndNothingReloadsAfterIt() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("zero\n", to: url)
        let stopped = Probe()
        let witness = Probe()          // watches the same file, so it can tell when the write was noticed
        stopped.loader.load(path: url.path)
        witness.loader.load(path: url.path)
        waitFor("both first results") { !stopped.results.isEmpty && !witness.results.isEmpty }
        XCTAssertTrue(stopped.loader.isWatching)

        stopped.loader.stop()
        XCTAssertFalse(stopped.loader.isWatching)

        try PlanTestSupport.writeInPlace("after stop\n", to: url)
        waitFor("the witness to see the write") { witness.loader.hasPendingReload }
        drainMain()
        XCTAssertEqual(stopped.scheduler.scheduledCount, 0, "a stopped loader schedules nothing")
        XCTAssertFalse(stopped.loader.hasPendingReload)
        stopped.scheduler.fire()
        drainMain()
        XCTAssertEqual(stopped.results.count, 1, "and reloads nothing")
    }

    func testStopCancelsAReloadThatWasAlreadyPending() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("zero\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        waitFor("the first result") { probe.texts == ["zero\n"] }
        try PlanTestSupport.writeInPlace("one\n", to: url)
        waitFor("the edit to be seen") { probe.loader.hasPendingReload }

        probe.loader.stop()
        XCTAssertFalse(probe.loader.hasPendingReload)
        probe.scheduler.fire()
        drainMain()
        XCTAssertEqual(probe.texts, ["zero\n"])
    }

    func testADeallocatedLoaderLeavesNoWatchBehind() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("zero\n", to: url)
        let witness = Probe()
        witness.loader.load(path: url.path)
        waitFor("the witness's first result") { !witness.results.isEmpty }

        let scheduler = ManualPlanReloadScheduler()
        weak var weakLoader: PlanFileLoader?
        var delivered = 0
        autoreleasepool {
            let loader = PlanFileLoader(scheduler: scheduler)
            loader.onResult = { _ in delivered += 1 }
            weakLoader = loader
            loader.load(path: url.path)
            XCTAssertTrue(loader.isWatching)
        }
        XCTAssertTrue(PlanTestSupport.pumpUntil { weakLoader == nil }, "the loader is freed once nothing holds it")
        let deliveredBefore = delivered

        try PlanTestSupport.writeInPlace("after dealloc\n", to: url)
        waitFor("the witness to see the write") { witness.loader.hasPendingReload }
        drainMain()
        XCTAssertEqual(scheduler.scheduledCount, 0, "a write after deallocation schedules nothing")
        XCTAssertEqual(delivered, deliveredBefore)
    }
}

// MARK: - Looking again for a file that is not there

/// A file that is not there yet (or was deleted and has not come back) cannot be watched, so the loader asks
/// again on its scheduler: after 0.5 s, then 1, 2, 4, 8, 16, and 30 s from then on, until it finds the file or
/// is stopped. Every wait here is a `ManualPlanReloadScheduler` fired by hand; the run loop is pumped on
/// conditions, never for a duration.
final class PlanFileLoaderRetryTests: XCTestCase {

    /// A reader that counts its calls (and the paths it was asked for) from whatever queue it runs on.
    private final class Reads {
        private let lock = NSLock()
        private var paths: [String] = []
        private var script: [PlanFileResult]
        private let fallback: PlanFileResult
        init(script: [PlanFileResult] = [], then fallback: PlanFileResult = .notFound) {
            self.script = script
            self.fallback = fallback
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
        var asked: [String] { lock.lock(); defer { lock.unlock() }; return paths }
        func read(_ path: String) -> PlanFileResult {
            lock.lock(); defer { lock.unlock() }
            paths.append(path)
            return script.isEmpty ? fallback : script.removeFirst()
        }
    }

    private final class Probe {
        let scheduler = ManualPlanReloadScheduler()
        let reads: Reads
        let loader: PlanFileLoader
        private(set) var results: [PlanFileResult] = []

        init(_ reads: Reads) {
            self.reads = reads
            loader = PlanFileLoader(reader: { reads.read($0) }, scheduler: scheduler)
            loader.onResult = { [weak self] in self?.results.append($0) }
        }
    }

    private static let missing = "/redd-no-such-directory/plan.md"

    private func waitFor(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        XCTAssertTrue(PlanTestSupport.pumpUntil(condition), "timed out waiting for \(what)", file: file, line: line)
    }

    /// Everything queued on the main queue so far has run.
    private func drainMain() {
        var done = false
        DispatchQueue.main.async { done = true }
        XCTAssertTrue(PlanTestSupport.pumpUntil { done })
    }

    /// Fire the scheduler once and wait for the answer that brings.
    private func fireAndWaitForAnotherResult(_ probe: Probe, file: StaticString = #filePath, line: UInt = #line) {
        let before = probe.results.count
        probe.scheduler.fire()
        waitFor("the next look at the file", file: file, line: line) { probe.results.count > before }
    }

    // MARK: The schedule

    func testTheWaitBetweenLooksDoublesFromHalfASecondAndStopsAtThirty() {
        let expected: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30, 30, 30]
        XCTAssertEqual((0 ..< expected.count).map { PlanFileLoader.retryDelay(afterAttempts: $0) }, expected)
        for attempt in [20, 100, 10_000, Int.max] {
            XCTAssertEqual(PlanFileLoader.retryDelay(afterAttempts: attempt), 30, "attempt \(attempt)")
        }
    }

    func testAMissingFileIsLookedForAgainWithGrowingWaits() {
        let probe = Probe(Reads())
        probe.loader.load(path: Self.missing)
        waitFor("the first answer") { probe.results.count == 1 }
        XCTAssertEqual(probe.results, [.notFound])
        XCTAssertTrue(probe.loader.hasPendingRetry, "a file that is not there is looked for again")
        XCTAssertEqual(probe.loader.retryAttempt, 1)
        XCTAssertFalse(probe.loader.isWatching, "there is nothing to watch yet")
        XCTAssertFalse(probe.loader.hasPendingReload)
        XCTAssertEqual(probe.scheduler.delays, [0.5])
        XCTAssertEqual(probe.scheduler.livePendingCount, 1)

        for _ in 1 ... 8 { fireAndWaitForAnotherResult(probe) }

        XCTAssertEqual(probe.results.count, 9)
        XCTAssertTrue(probe.results.allSatisfy { $0 == .notFound })
        XCTAssertEqual(probe.scheduler.delays, [0.5, 1, 2, 4, 8, 16, 30, 30, 30], "the waits follow retryDelay(afterAttempts:)")
        XCTAssertEqual(probe.loader.retryAttempt, 9)
        XCTAssertTrue(probe.loader.hasPendingRetry)
        XCTAssertEqual(probe.scheduler.livePendingCount, 1, "one look is scheduled at a time")
        XCTAssertEqual(probe.reads.count, 9, "a look is one read")
        XCTAssertEqual(Set(probe.reads.asked), [Self.missing])
    }

    func testNothingIsReadAgainUntilTheSchedulerRuns() {
        let probe = Probe(Reads())
        probe.loader.load(path: Self.missing)
        waitFor("the first answer") { probe.results.count == 1 }
        drainMain()
        drainMain()
        XCTAssertEqual(probe.reads.count, 1, "the loader waits for its scheduler: it does not poll")
    }

    // MARK: A file that shows up

    func testAFileThatAnswersEndsTheLookingAndStartsTheCountOver() {
        let url = URL(fileURLWithPath: "/redd-found/plan.md")
        let reads = Reads(script: [.notFound, .notFound, .loaded(text: "# Here\n", url: url, modified: nil), .notFound])
        let probe = Probe(reads)
        probe.loader.load(path: Self.missing)
        waitFor("the first answer") { probe.results.count == 1 }
        fireAndWaitForAnotherResult(probe)
        XCTAssertEqual(probe.loader.retryAttempt, 2)
        XCTAssertEqual(probe.scheduler.delays, [0.5, 1])

        fireAndWaitForAnotherResult(probe)
        XCTAssertEqual(probe.results.last, .loaded(text: "# Here\n", url: url, modified: nil))
        XCTAssertEqual(probe.loader.retryAttempt, 0, "a file ends the count")
        XCTAssertFalse(probe.loader.hasPendingRetry, "and the looking")
        XCTAssertEqual(probe.scheduler.livePendingCount, 0)
        XCTAssertEqual(probe.scheduler.delays, [0.5, 1], "a loaded answer schedules nothing")

        // The file goes away again: the waits start from the beginning, not from where they were.
        probe.loader.reload()
        waitFor("the answer after it went") { probe.results.count == 4 }
        XCTAssertEqual(probe.results.last, .notFound)
        XCTAssertEqual(probe.scheduler.delays, [0.5, 1, 0.5])
        XCTAssertEqual(probe.loader.retryAttempt, 1)
    }

    func testAnAnswerThatIsNotNotFoundIsNeverLookedForAgain() {
        for answer: PlanFileResult in [.notReadable, .notMarkdown, .tooLarge, .notUTF8] {
            let probe = Probe(Reads(script: [], then: answer))
            probe.loader.load(path: Self.missing)
            waitFor("the answer \(answer)") { probe.results.count == 1 }
            drainMain()
            XCTAssertFalse(probe.loader.hasPendingRetry, "\(answer)")
            XCTAssertEqual(probe.loader.retryAttempt, 0, "\(answer)")
            XCTAssertEqual(probe.scheduler.scheduledCount, 0, "\(answer): nothing is scheduled")
        }
    }

    // MARK: Stopping

    func testStopCancelsTheLookingAndNothingIsReadAfterIt() {
        let probe = Probe(Reads())
        probe.loader.load(path: Self.missing)
        waitFor("the first answer") { probe.results.count == 1 }
        XCTAssertTrue(probe.loader.hasPendingRetry)

        probe.loader.stop()

        XCTAssertFalse(probe.loader.hasPendingRetry)
        XCTAssertEqual(probe.loader.retryAttempt, 0)
        XCTAssertEqual(probe.scheduler.livePendingCount, 0)
        probe.scheduler.fire()
        drainMain()
        drainMain()
        XCTAssertEqual(probe.reads.count, 1, "firing the scheduler reads nothing more")
        XCTAssertEqual(probe.results.count, 1)
    }

    func testLoadingNoPathCancelsTheLookingToo() {
        for none in [nil, ""] as [String?] {
            let probe = Probe(Reads())
            probe.loader.load(path: Self.missing)
            waitFor("the first answer") { probe.results.count == 1 }
            XCTAssertTrue(probe.loader.hasPendingRetry)

            probe.loader.load(path: none)

            XCTAssertFalse(probe.loader.hasPendingRetry, "path \(String(describing: none))")
            XCTAssertEqual(probe.loader.retryAttempt, 0)
            probe.scheduler.fire()
            drainMain()
            drainMain()
            XCTAssertEqual(probe.reads.count, 1, "nothing is read for no path")
            XCTAssertEqual(probe.results.count, 1)
        }
    }

    func testALookStillInFlightWhenTheLoaderIsStoppedLeavesNoLookingBehind() {
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "plan.loader.retry.test.read", attributes: .concurrent)
        let scheduler = ManualPlanReloadScheduler()
        let loader = PlanFileLoader(reader: { _ in gate.wait(); return .notFound }, scheduler: scheduler, readQueue: queue)
        var results = 0
        loader.onResult = { _ in results += 1 }

        loader.load(path: Self.missing)
        loader.stop()                   // the read has not answered yet
        gate.signal()
        queue.sync(flags: .barrier) {}
        drainMain()

        XCTAssertEqual(results, 0, "an answer that came after stop() is not delivered")
        XCTAssertFalse(loader.hasPendingRetry, "and it does not start a look of its own")
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    // MARK: A new path

    func testALookForAnOlderPathNeverReadsTheNewOne() {
        let url = URL(fileURLWithPath: "/redd-new/plan.md")
        let reads = Reads(script: [.notFound, .loaded(text: "new\n", url: url, modified: nil)])
        let probe = Probe(reads)
        probe.loader.load(path: "/redd-old/plan.md")
        waitFor("the old path's answer") { probe.results.count == 1 }
        XCTAssertTrue(probe.loader.hasPendingRetry)

        probe.loader.load(path: "/redd-new/plan.md")
        waitFor("the new path's answer") { probe.results.count == 2 }
        XCTAssertEqual(probe.reads.asked, ["/redd-old/plan.md", "/redd-new/plan.md"])
        XCTAssertFalse(probe.loader.hasPendingRetry, "the old path's look was called off")
        XCTAssertEqual(probe.scheduler.livePendingCount, 0)

        probe.scheduler.fire()          // whatever the old path left behind runs now
        drainMain()
        drainMain()
        XCTAssertEqual(probe.reads.asked, ["/redd-old/plan.md", "/redd-new/plan.md"], "nothing was read again")
        XCTAssertEqual(probe.results.count, 2)
    }

    func testANewPathStartsItsOwnWaitsFromTheBeginning() {
        let probe = Probe(Reads())
        probe.loader.load(path: "/redd-old/plan.md")
        waitFor("the first answer") { probe.results.count == 1 }
        for _ in 1 ... 3 { fireAndWaitForAnotherResult(probe) }
        XCTAssertEqual(probe.scheduler.delays, [0.5, 1, 2, 4])

        probe.loader.load(path: "/redd-new/plan.md")
        waitFor("the new path's answer") { probe.results.count == 5 }

        XCTAssertEqual(probe.scheduler.delays, [0.5, 1, 2, 4, 0.5], "the new path is looked for after 0.5 s again")
        XCTAssertEqual(probe.loader.retryAttempt, 1)
        XCTAssertEqual(probe.scheduler.livePendingCount, 1, "only the new path's look is scheduled")
    }

    func testReloadingWhileALookIsScheduledLeavesExactlyOneLook() {
        let probe = Probe(Reads())
        probe.loader.load(path: Self.missing)
        waitFor("the first answer") { probe.results.count == 1 }

        probe.loader.reload()
        waitFor("the reload's answer") { probe.results.count == 2 }

        XCTAssertEqual(probe.scheduler.livePendingCount, 1, "the look that was scheduled was replaced, not added to")
        XCTAssertTrue(probe.loader.hasPendingRetry)
    }

    // MARK: Teardown

    func testALookScheduledWhenTheLoaderIsFreedReadsNothing() {
        let reads = Reads()
        let scheduler = ManualPlanReloadScheduler()
        weak var weakLoader: PlanFileLoader?
        var answered = 0
        var loader: PlanFileLoader? = PlanFileLoader(reader: { reads.read($0) }, scheduler: scheduler)
        weakLoader = loader
        loader?.onResult = { _ in answered += 1 }
        loader?.load(path: Self.missing)
        waitFor("the first answer") { answered == 1 }
        XCTAssertEqual(scheduler.livePendingCount, 1)

        loader = nil

        XCTAssertTrue(PlanTestSupport.pumpUntil { weakLoader == nil }, "the loader is freed once nothing holds it")
        XCTAssertEqual(scheduler.livePendingCount, 0, "its look went with it")
        scheduler.fire()
        drainMain()
        drainMain()
        XCTAssertEqual(reads.count, 1, "firing what is left reads nothing")
        XCTAssertEqual(answered, 1)
    }

    // MARK: End to end, with a real file

    func testAFileCreatedAfterTheFirstLookIsLoadedByTheNextOneAndThenWatched() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("later.md")
        let scheduler = ManualPlanReloadScheduler()
        let loader = PlanFileLoader(scheduler: scheduler)
        var results: [PlanFileResult] = []
        loader.onResult = { results.append($0) }

        loader.load(path: url.path)
        waitFor("the missing file to be reported") { results == [.notFound] }
        XCTAssertTrue(loader.hasPendingRetry)

        try PlanTestSupport.writeInPlace("# Later\n", to: url)
        scheduler.fire()
        waitFor("the file to be loaded") {
            if case .loaded(let text, _, _)? = results.last { return text == "# Later\n" }
            return false
        }
        XCTAssertFalse(loader.hasPendingRetry)
        XCTAssertEqual(loader.retryAttempt, 0)
        XCTAssertTrue(loader.isWatching, "once it is there the watcher takes over")
    }
}
