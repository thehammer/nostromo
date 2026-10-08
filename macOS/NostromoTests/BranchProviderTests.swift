import XCTest
import Combine
// GitBranch and BranchProvider are compiled into this target directly (logic test — no host app).

// MARK: - GitBranch.lookup (real git)

/// `GitBranch.lookup(forProjectPath:)` against real throwaway repositories.
/// Blocking by design; the app only ever reaches it through `BranchProvider`.
final class GitBranchLookupTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeTempDir(_ prefix: String = "branchlookup") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// `git init -b main` — an *unborn* branch: no commits yet.
    private func makeRepo() throws -> URL {
        let dir = try makeTempDir()
        try git(dir, "init", "-q", "-b", "main")
        return dir
    }

    /// A repo with one commit on `main`.
    private func makeRepoWithCommit() throws -> URL {
        let dir = try makeRepo()
        try git(dir, "commit", "-q", "--allow-empty", "-m", "initial")
        return dir
    }

    @discardableResult
    private func git(_ dir: URL, _ args: String..., file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        // Inline identity + no signing/hooks so commits work on a bare CI box.
        p.arguments = ["-C", dir.path,
                       "-c", "user.name=Test", "-c", "user.email=test@example.com",
                       "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false",
                       "-c", "core.hooksPath=/dev/null",
                       "-c", "init.defaultBranch=main"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args) failed", file: file, line: line)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Tests

    func testUnbornBranchInAFreshRepoResolvesToTheBranchName() throws {
        let dir = try makeRepo()
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("main"))
    }

    func testCheckedOutBranchResolvesToItsName() throws {
        let dir = try makeRepoWithCommit()
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("main"))
    }

    func testBranchNameWithSlashesIsReturnedWhole() throws {
        let dir = try makeRepoWithCommit()
        try git(dir, "checkout", "-q", "-b", "feat/multi-session-labels")
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("feat/multi-session-labels"))
    }

    func testLookupFollowsBranchSwitches() throws {
        let dir = try makeRepoWithCommit()
        try git(dir, "checkout", "-q", "-b", "one")
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("one"))
        try git(dir, "checkout", "-q", "-b", "two")
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("two"))
        try git(dir, "checkout", "-q", "main")
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .resolved("main"))
    }

    func testDetachedHeadResolvesToAShortCommitSha() throws {
        let dir = try makeRepoWithCommit()
        let fullSha = try git(dir, "rev-parse", "HEAD")
        try git(dir, "checkout", "-q", "--detach")

        guard case let .resolved(name?) = GitBranch.lookup(forProjectPath: dir.path) else {
            XCTFail("a detached HEAD in a healthy repo resolves to a short sha, not nil/failed"); return
        }
        XCTAssertGreaterThanOrEqual(name.count, 7)
        XCTAssertLessThan(name.count, fullSha.count, "short, not the full 40-char sha")
        XCTAssertTrue(fullSha.hasPrefix(name), "\(name) should be a prefix of \(fullSha)")
        XCTAssertNotEqual(name, "HEAD")
    }

    func testLinkedWorktreeResolvesToItsOwnBranch() throws {
        let main = try makeRepoWithCommit()
        let parent = try makeTempDir("branchlookup-wt")
        let worktree = parent.appendingPathComponent("wt")
        try git(main, "worktree", "add", "-q", "-b", "wt-branch", worktree.path)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path,
                                                     isDirectory: &isDir))
        XCTAssertFalse(isDir.boolValue, "sanity: in a linked worktree `.git` is a file")

        XCTAssertEqual(GitBranch.lookup(forProjectPath: worktree.path), .resolved("wt-branch"))
        XCTAssertEqual(GitBranch.lookup(forProjectPath: main.path), .resolved("main"),
                       "the main checkout is unaffected by the worktree's branch")
    }

    func testDirectoryThatIsNotARepoFails() throws {
        let dir = try makeTempDir("branchlookup-norepo")
        XCTAssertEqual(GitBranch.lookup(forProjectPath: dir.path), .failed)
    }

    func testMissingDirectoryFails() {
        XCTAssertEqual(GitBranch.lookup(forProjectPath: "/nonexistent/\(UUID().uuidString)"), .failed)
    }
}

// MARK: - BranchProvider (async cache)

final class BranchProviderTests: XCTestCase {

    // MARK: Helpers

    private final class Counter {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func hit(_ path: String) { lock.lock(); counts[path, default: 0] += 1; lock.unlock() }
        func count(_ path: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[path] ?? 0 }
        var total: Int { lock.lock(); defer { lock.unlock() }; return counts.values.reduce(0, +) }
    }

    /// Thread-safe, mutable lookup table so a test can change what "git" says between refreshes.
    private final class FakeGit {
        private let lock = NSLock()
        private var table: [String: GitBranch.Lookup]
        let calls = Counter()
        init(_ table: [String: GitBranch.Lookup] = [:]) { self.table = table }
        func set(_ path: String, _ result: GitBranch.Lookup) { lock.lock(); table[path] = result; lock.unlock() }
        func lookup(_ path: String) -> GitBranch.Lookup {
            calls.hit(path)
            lock.lock(); defer { lock.unlock() }
            return table[path] ?? .resolved(nil)
        }
    }

    /// Each provider gets its own serial queue so a test can wait for "all lookups done".
    private func makeProvider(_ fake: FakeGit) -> (BranchProvider, DispatchQueue) {
        let queue = DispatchQueue(label: "branch-provider-test-\(UUID().uuidString)")
        return (BranchProvider(queue: queue, lookup: fake.lookup), queue)
    }

    private func pumpMain(_ seconds: TimeInterval = 0.25) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 20)
    }

    /// Refresh and wait until the lookups have run and their results have been published.
    private func refreshAndSettle(_ provider: BranchProvider, _ queue: DispatchQueue, _ paths: [String]) {
        provider.refresh(paths)
        queue.sync {}
        pumpMain()
    }

    private final class Recorder {
        private let lock = NSLock()
        private(set) var values: [[String: String]] = []
        private(set) var wasMain: [Bool] = []
        func record(_ v: [String: String]) {
            lock.lock(); values.append(v); wasMain.append(Thread.isMainThread); lock.unlock()
        }
    }

    /// Records every value `$branches` publishes AFTER the initial replay on subscribe.
    private func record(_ provider: BranchProvider) -> (Recorder, AnyCancellable) {
        let r = Recorder()
        let c = provider.$branches.dropFirst().sink { r.record($0) }
        return (r, c)
    }

    // MARK: Basic results

    func testStartsEmpty() {
        let (provider, _) = makeProvider(FakeGit())
        XCTAssertTrue(provider.branches.isEmpty)
        XCTAssertNil(provider.branch(for: "/p"))
    }

    func testRefreshPublishesTheResolvedBranchPerPath() {
        let fake = FakeGit(["/a": .resolved("main"), "/b": .resolved("feat/x")])
        let (provider, queue) = makeProvider(fake)

        refreshAndSettle(provider, queue, ["/a", "/b"])

        XCTAssertEqual(provider.branches, ["/a": "main", "/b": "feat/x"])
        XCTAssertEqual(provider.branch(for: "/a"), "main")
        XCTAssertEqual(provider.branch(for: "/b"), "feat/x")
        XCTAssertNil(provider.branch(for: "/never-asked"))
    }

    func testRefreshOnlyTouchesThePathsItWasGiven() {
        let fake = FakeGit(["/a": .resolved("main"), "/b": .resolved("dev")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/a", "/b"])

        fake.set("/a", .resolved("changed"))
        fake.set("/b", .resolved("changed-too"))
        refreshAndSettle(provider, queue, ["/a"])

        XCTAssertEqual(provider.branch(for: "/a"), "changed")
        XCTAssertEqual(provider.branch(for: "/b"), "dev", "/b was not part of this refresh")
    }

    // MARK: Threading

    func testLookupRunsOffTheMainThreadEvenWhenRefreshIsCalledOnMain() {
        XCTAssertTrue(Thread.isMainThread, "sanity: XCTest runs these on main")
        let ran = expectation(description: "lookup ran")
        let lock = NSLock()
        var lookupWasOnMain: Bool?
        let provider = BranchProvider(queue: DispatchQueue(label: "bp-offmain"), lookup: { _ in
            lock.lock(); lookupWasOnMain = Thread.isMainThread; lock.unlock()
            ran.fulfill()
            return .resolved("main")
        })
        provider.refresh(["/p"])
        wait(for: [ran], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(lookupWasOnMain, false)
    }

    func testResultsArePublishedOnTheMainThread() {
        let fake = FakeGit(["/p": .resolved("main")])
        let (provider, queue) = makeProvider(fake)
        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }

        refreshAndSettle(provider, queue, ["/p"])

        XCTAssertFalse(recorder.values.isEmpty, "the new branch must have been published")
        XCTAssertTrue(recorder.wasMain.allSatisfy { $0 }, "published off the main thread: \(recorder.wasMain)")
    }

    func testRefreshDoesNotBlockTheCallerWhileALookupIsStillRunning() {
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "lookup started")
        let provider = BranchProvider(queue: DispatchQueue(label: "bp-gated"), lookup: { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 15)   // bounded so a bad implementation can't hang the suite
            return .resolved("main")
        })

        let begin = Date()
        provider.refresh(["/slow"])
        let elapsed = Date().timeIntervalSince(begin)
        XCTAssertLessThan(elapsed, 2.0, "refresh must return immediately; the lookup is still gated")
        XCTAssertNil(provider.branch(for: "/slow"), "nothing is known until the lookup finishes")

        wait(for: [started], timeout: 5)
        let published = expectation(description: "published after the gate opens")
        let cancel = provider.$branches.dropFirst().sink { if $0["/slow"] == "main" { published.fulfill() } }
        gate.signal()
        wait(for: [published], timeout: 5)
        cancel.cancel()
        XCTAssertEqual(provider.branch(for: "/slow"), "main")
    }

    // MARK: Publish only on change

    func testRefreshWithIdenticalResultsDoesNotPublishAgain() {
        let fake = FakeGit(["/a": .resolved("main"), "/b": .resolved("dev")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/a", "/b"])

        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        refreshAndSettle(provider, queue, ["/a", "/b"])
        refreshAndSettle(provider, queue, ["/a"])

        XCTAssertGreaterThan(fake.calls.count("/a"), 1, "sanity: the provider really did re-check")
        XCTAssertTrue(recorder.values.isEmpty, "nothing changed, so nothing may be published: \(recorder.values)")
    }

    func testRefreshWithNoPathsPublishesNothing() {
        let (provider, queue) = makeProvider(FakeGit())
        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        refreshAndSettle(provider, queue, [])
        XCTAssertTrue(recorder.values.isEmpty)
    }

    func testAChangedBranchIsPublished() {
        let fake = FakeGit(["/p": .resolved("main")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/p"])

        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        fake.set("/p", .resolved("feat/new"))
        refreshAndSettle(provider, queue, ["/p"])

        XCTAssertEqual(recorder.values.last, ["/p": "feat/new"])
        XCTAssertEqual(provider.branch(for: "/p"), "feat/new")
    }

    func testFirstDiscoveryOfABranchIsPublished() {
        let fake = FakeGit(["/p": .resolved("main")])
        let (provider, queue) = makeProvider(fake)
        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }

        refreshAndSettle(provider, queue, ["/p"])

        XCTAssertEqual(recorder.values.last, ["/p": "main"])
    }

    // MARK: Failure and absence

    func testAFailedLookupKeepsThePreviouslyKnownBranch() {
        let fake = FakeGit(["/p": .resolved("main")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/p"])

        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        fake.set("/p", .failed)
        refreshAndSettle(provider, queue, ["/p"])

        XCTAssertEqual(provider.branch(for: "/p"), "main", "a transient git failure must not blank the sidebar")
        XCTAssertTrue(recorder.values.isEmpty, "a failure is not a change")
    }

    func testAFailedLookupForAnUnknownPathLeavesItUnknown() {
        let fake = FakeGit(["/p": .failed])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/p"])
        XCTAssertNil(provider.branch(for: "/p"))
        XCTAssertTrue(provider.branches.isEmpty)
    }

    func testARecoveredLookupUpdatesAfterAFailure() {
        let fake = FakeGit(["/p": .resolved("main")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/p"])
        fake.set("/p", .failed)
        refreshAndSettle(provider, queue, ["/p"])
        fake.set("/p", .resolved("dev"))
        refreshAndSettle(provider, queue, ["/p"])
        XCTAssertEqual(provider.branch(for: "/p"), "dev")
    }

    func testAResolvedNilRemovesTheEntry() {
        let fake = FakeGit(["/p": .resolved("main"), "/q": .resolved("dev")])
        let (provider, queue) = makeProvider(fake)
        refreshAndSettle(provider, queue, ["/p", "/q"])

        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        fake.set("/p", .resolved(nil))
        refreshAndSettle(provider, queue, ["/p"])

        XCTAssertNil(provider.branch(for: "/p"))
        XCTAssertNil(provider.branches["/p"], "removed, not stored as an empty value")
        XCTAssertEqual(provider.branches, ["/q": "dev"])
        XCTAssertEqual(recorder.values.last, ["/q": "dev"], "removal is a change and is published")
    }

    func testAResolvedNilForAPathWeNeverKnewPublishesNothing() {
        let fake = FakeGit(["/p": .resolved(nil)])
        let (provider, queue) = makeProvider(fake)
        let (recorder, cancel) = record(provider)
        defer { cancel.cancel() }
        refreshAndSettle(provider, queue, ["/p"])
        XCTAssertTrue(recorder.values.isEmpty)
        XCTAssertTrue(provider.branches.isEmpty)
    }

    // MARK: Dedup

    func testDuplicatePathsInOneRefreshAreLookedUpOnce() {
        let fake = FakeGit(["/a": .resolved("main"), "/b": .resolved("dev")])
        let (provider, queue) = makeProvider(fake)

        refreshAndSettle(provider, queue, ["/a", "/a", "/b", "/a", "/b"])

        XCTAssertEqual(fake.calls.count("/a"), 1)
        XCTAssertEqual(fake.calls.count("/b"), 1)
        XCTAssertEqual(provider.branches, ["/a": "main", "/b": "dev"])
    }

    // MARK: Real git end to end

    func testDefaultProviderResolvesARealRepositoryBranch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branchprovider-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "init", "-q", "-b", "trunk"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let provider = BranchProvider()   // default queue + real GitBranch.lookup
        let published = expectation(description: "real branch published")
        let cancel = provider.$branches.sink { if $0[dir.path] == "trunk" { published.fulfill() } }
        provider.refresh([dir.path])
        wait(for: [published], timeout: 10)
        cancel.cancel()
        XCTAssertEqual(provider.branch(for: dir.path), "trunk")
    }
}
