import AppKit
import XCTest

final class RepoOrgTests: XCTestCase {

    // MARK: URL parsing

    func testCarefeedForms() {
        let urls = [
            "git@github.com:carefeed/portal.git",
            "git@github.com:carefeed/portal",
            "ssh://git@github.com/carefeed/portal.git",
            "ssh://git@github.com/carefeed/portal",
            "https://github.com/carefeed/portal.git",
            "https://github.com/carefeed/portal",
            "https://user:token@github.com/carefeed/portal.git",
            "https://x-access-token@github.com/carefeed/portal",
            "git@github.com:CareFeed/portal.git",
            "  https://github.com/CAREFEED/portal\n",
        ]
        for u in urls {
            XCTAssertEqual(RepoOrg.org(forRemoteURL: u), "Carefeed", u)
        }
    }

    func testPersonalForms() {
        XCTAssertEqual(RepoOrg.org(forRemoteURL: "git@github.com:thehammer/nostromo.git"), "Personal")
        XCTAssertEqual(RepoOrg.org(forRemoteURL: "https://github.com/thehammer/nostromo"), "Personal")
        XCTAssertEqual(RepoOrg.org(forRemoteURL: "ssh://git@github.com/TheHammer/nostromo.git"), "Personal")
    }

    func testUnknownOwnerAndHostAndGarbageAreNil() {
        let urls = [
            "git@github.com:someoneelse/repo.git",
            "https://github.com/someoneelse/repo",
            "git@gitlab.com:carefeed/portal.git",
            "https://bitbucket.org/thehammer/repo.git",
            "https://notgithub.com/carefeed/portal",
            "",
            "   ",
            "garbage",
            "github.com",
            "/Users/me/local/repo",
            "https://github.com/carefeed",
            "https://github.com/carefeed/",
            "git@github.com:carefeed",
            "git@notgithub.com:carefeed/x",
            "git@github.com.evil.example:carefeed/x",
            "https://github.com.evil.example/carefeed/x",
            "git@github.com-:carefeed/x",
            "git@github.com-a.evil.example:carefeed/x",
            "git@github-:carefeed/x",
            "git@githubx:carefeed/x",
        ]
        for u in urls {
            XCTAssertNil(RepoOrg.org(forRemoteURL: u), u)
        }
    }

    func testHostVariantsAndSSHAliases() {
        let cases: [(String, String)] = [
            ("https://www.github.com/carefeed/x", "Carefeed"),
            ("ssh://git@ssh.github.com:443/thehammer/x.git", "Personal"),
            ("git@github.com-personal:thehammer/x", "Personal"),
            ("git@github.com-work:carefeed/x", "Carefeed"),
            ("git@github-work:carefeed/x", "Carefeed"),
            ("git@github-personal:thehammer/x.git", "Personal"),
            ("ssh://git@github.com-work/carefeed/x", "Carefeed"),
        ]
        for (u, expected) in cases {
            XCTAssertEqual(RepoOrg.org(forRemoteURL: u), expected, u)
        }
    }

    // MARK: Temp git repo

    func testProjectPathWithOriginForms() throws {
        let cases: [(String, String)] = [
            ("git@github.com:carefeed/portal.git", "Carefeed"),
            ("ssh://git@github.com/carefeed/portal", "Carefeed"),
            ("https://github.com/thehammer/nostromo.git", "Personal"),
            ("https://user:pw@github.com/CareFeed/portal", "Carefeed"),
        ]
        for (url, expected) in cases {
            let dir = try makeRepo()
            defer { try? FileManager.default.removeItem(at: dir) }
            try git(dir, "remote", "add", "origin", url)
            XCTAssertEqual(RepoOrg.org(forProjectPath: dir.path), expected, url)
        }
    }

    func testProjectPathFallsBackToOnlyRemoteWhenNoOrigin() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "remote", "add", "upstream", "git@github.com:thehammer/x.git")
        XCTAssertEqual(RepoOrg.org(forProjectPath: dir.path), "Personal")
    }

    func testUnknownOriginIsNilEvenWhenAnotherRemoteIsKnown() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "remote", "add", "origin", "git@github.com:someoneelse/x.git")
        try git(dir, "remote", "add", "a-first", "git@github.com:carefeed/x.git")
        XCTAssertNil(RepoOrg.org(forProjectPath: dir.path))
    }

    /// Without origin, the alphabetically first remote name wins.
    func testNoOriginUsesAlphabeticallyFirstRemote() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "remote", "add", "zeta", "git@github.com:thehammer/x.git")
        try git(dir, "remote", "add", "alpha", "git@github.com:carefeed/x.git")
        XCTAssertEqual(RepoOrg.org(forProjectPath: dir.path), "Carefeed")
    }

    func testProjectPathWithNoRemoteIsNil() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(RepoOrg.org(forProjectPath: dir.path))
    }

    func testProjectPathNotARepoIsNil() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoorg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(RepoOrg.org(forProjectPath: dir.path))
        XCTAssertNil(RepoOrg.org(forProjectPath: "/nonexistent/\(UUID().uuidString)"))
    }

    // MARK: Resolver (cache + off-main)

    func testResolverRunsLookupOffMainAndCallsBackOnMain() {
        let lookedUpOnMain = expectation(description: "lookup")
        var lookupWasOnMain: Bool?
        let resolver = RepoOrgResolver(lookup: { _ in
            lookupWasOnMain = Thread.isMainThread
            lookedUpOnMain.fulfill()
            return .resolved("Carefeed")
        })
        let done = expectation(description: "completion")
        var result: String?
        var completionOnMain = false
        resolver.resolve("/p") { org in
            result = org
            completionOnMain = Thread.isMainThread
            done.fulfill()
        }
        wait(for: [lookedUpOnMain, done], timeout: 5)
        XCTAssertEqual(lookupWasOnMain, false)
        XCTAssertTrue(completionOnMain)
        XCTAssertEqual(result, "Carefeed")
    }

    func testResolverCachesIncludingNilResults() {
        var calls = 0
        let lock = NSLock()
        let resolver = RepoOrgResolver(lookup: { path in
            lock.lock(); calls += 1; lock.unlock()
            return .resolved(path == "/known" ? "Personal" : nil)
        })
        XCTAssertNil(resolver.cached("/known"))
        for path in ["/known", "/unknown"] {
            let done = expectation(description: path)
            resolver.resolve(path) { _ in done.fulfill() }
            wait(for: [done], timeout: 5)
        }
        XCTAssertEqual(resolver.cached("/known"), .some("Personal"))
        XCTAssertNotNil(resolver.cached("/unknown"))          // cached...
        XCTAssertNil(resolver.cached("/unknown") ?? nil)      // ...as nil
        let again = expectation(description: "again")
        resolver.resolve("/known") { org in
            XCTAssertEqual(org, "Personal")
            again.fulfill()
        }
        wait(for: [again], timeout: 5)
        XCTAssertEqual(calls, 2)
    }

    // MARK: Remote listing parsing

    func testListingPrefersOriginEvenWhenUnknown() {
        let listing = """
        remote.a-first.url git@github.com:carefeed/x.git
        remote.origin.url git@github.com:someoneelse/x.git
        """
        XCTAssertNil(RepoOrg.org(forRemoteListing: listing))
    }

    func testListingWithoutOriginUsesFirstSortedAndHandlesDottedNames() {
        let listing = """
        remote.zeta.url git@github.com:thehammer/x.git
        remote.my.fork.url git@github.com:carefeed/x.git
        """
        XCTAssertEqual(RepoOrg.org(forRemoteListing: listing), "Carefeed")
    }

    func testLookupDistinguishesNoRemoteFromFailure() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(RepoOrg.lookup(forProjectPath: dir.path), .resolved(nil))
        XCTAssertEqual(RepoOrg.lookup(forProjectPath: "/nonexistent/\(UUID().uuidString)"), .failed)
    }

    // MARK: Resolver failure semantics

    func testFailedLookupIsNotCachedAndIsRetried() {
        let lock = NSLock()
        var calls = 0
        let resolver = RepoOrgResolver(lookup: { _ in
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            return n == 1 ? .failed : .resolved("Carefeed")
        })
        let first = expectation(description: "first")
        var firstOrg: String? = "unset"
        resolver.resolve("/p") { firstOrg = $0; first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertNil(firstOrg)
        XCTAssertNil(resolver.cached("/p"))

        let second = expectation(description: "second")
        var secondOrg: String?
        resolver.resolve("/p") { secondOrg = $0; second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(secondOrg, "Carefeed")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(resolver.cached("/p"), .some("Carefeed"))
    }

    func testConcurrentResolvesShareOneLookup() {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        let resolver = RepoOrgResolver(lookup: { _ in
            lock.lock(); calls += 1; lock.unlock()
            gate.wait()
            return .resolved("Personal")
        })
        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        resolver.resolve("/p") { _ in both.fulfill() }
        resolver.resolve("/p") { _ in both.fulfill() }
        gate.signal()
        wait(for: [both], timeout: 5)
        XCTAssertEqual(calls, 1)
    }

    // MARK: Sheet async paths

    /// A resolver whose lookups block until `release()` is called.
    private final class GatedLookup {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private(set) var calls = 0
        var results: [String: RepoOrg.Lookup]
        init(_ results: [String: RepoOrg.Lookup]) { self.results = results }
        func lookup(_ path: String) -> RepoOrg.Lookup {
            lock.lock(); calls += 1; lock.unlock()
            gate.wait()
            return results[path] ?? .resolved(nil)
        }
        func release(_ n: Int = 1) { for _ in 0..<n { gate.signal() } }
    }

    private func makeSheet(_ g: GatedLookup, onCreate: @escaping (Focus) -> Void) -> CreateFocusSheet {
        CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: g.lookup),
                         agents: ["claudia"], projects: ["/tmp/alpha", "/tmp/beta"],
                         onCreate: onCreate)
    }

    private func pumpMain(_ seconds: TimeInterval = 0.3) {
        let e = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { e.fulfill() }
        wait(for: [e], timeout: 20)
    }

    func testStaleLookupDoesNotOverwriteNewerPreview() {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed"), "/tmp/beta": .resolved("Personal")])
        let sheet = makeSheet(g) { _ in }
        sheet.selectProject(at: 1)   // moves on before alpha's lookup completes
        g.release(2)
        pumpMain()
        XCTAssertTrue(sheet.previewText.contains("Beta"), sheet.previewText)
        XCTAssertFalse(sheet.previewText.contains("Alpha"), sheet.previewText)
    }

    func testCreateBeforeLookupCompletesCreatesExactlyOneFocusWithOrg() {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed")])
        var created: [Focus] = []
        let sheet = makeSheet(g) { created.append($0) }
        sheet.createTapped()
        XCTAssertFalse(sheet.isCreateEnabled)
        sheet.createTapped()   // re-entrant tap while pending
        g.release(2)
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.org, "Carefeed")
        XCTAssertEqual(created.first?.projectPath, "/tmp/alpha")
    }

    func testCancelWhilePendingCreatesNothing() {
        let g = GatedLookup(["/tmp/alpha": .resolved("Carefeed")])
        var created: [Focus] = []
        let sheet = makeSheet(g) { created.append($0) }
        sheet.createTapped()
        sheet.cancelTapped()
        g.release(2)
        pumpMain()
        XCTAssertTrue(created.isEmpty)
    }

    func testFailedLookupStillCreatesFocusWithNilOrgAndRetriesLater() {
        let g = GatedLookup(["/tmp/alpha": .failed])
        var created: [Focus] = []
        let resolver = RepoOrgResolver(lookup: g.lookup)
        let sheet = CreateFocusSheet(orgResolver: resolver, agents: ["claudia"],
                                     projects: ["/tmp/alpha"]) { created.append($0) }
        sheet.createTapped()
        g.release(2)
        pumpMain()
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created.first?.org)
        XCTAssertNil(resolver.cached("/tmp/alpha"))   // not cached; retried next time
    }

    // MARK: Sheet view tree — no Org picker, preview under the Project row

    func testCreateFocusSheetHasNoOrgPickerAndPreviewSitsUnderProject() throws {
        let sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }), onCreate: { _ in })
        let content = try XCTUnwrap(sheet.window?.contentView)
        content.layoutSubtreeIfNeeded()

        var all: [NSView] = []
        func walk(_ v: NSView) { all.append(v); v.subviews.forEach(walk) }
        walk(content)

        XCTAssertTrue(all.filter { $0 is NSSegmentedControl }.isEmpty)
        let labels = all.compactMap { ($0 as? NSTextField) }
        XCTAssertFalse(labels.contains { $0.stringValue == "Org:" })

        let project = try XCTUnwrap(labels.first { $0.stringValue == "Project:" })
        // Preview is the grey 11pt label; it must be anchored below the Project row.
        let preview = try XCTUnwrap(labels.first { $0.font?.pointSize == 11 })
        XCTAssertLessThanOrEqual(preview.frame.maxY, project.frame.minY + 0.5)
    }

    // MARK: Helpers

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repoorg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(dir, "init", "-q")
        return dir
    }

    private func git(_ dir: URL, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args) failed")
    }
}
