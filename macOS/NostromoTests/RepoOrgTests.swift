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
            return "Carefeed"
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
            return path == "/known" ? "Personal" : nil
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

    // MARK: Sheet view tree — no Org picker, preview under the Project row

    func testCreateFocusSheetHasNoOrgPickerAndPreviewSitsUnderProject() throws {
        let sheet = CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in nil }), onCreate: { _ in })
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
