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
        ]
        for u in urls {
            XCTAssertNil(RepoOrg.org(forRemoteURL: u), u)
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

    func testProjectPathFallsBackToFirstRemoteWhenNoOrigin() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try git(dir, "remote", "add", "upstream", "git@github.com:thehammer/x.git")
        XCTAssertEqual(RepoOrg.org(forProjectPath: dir.path), "Personal")
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

    // MARK: Wiring — CreateFocusSheet is AppKit and not in the test bundle.

    func testCreateFocusSheetHasNoOrgPicker() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/CreateFocusSheet.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("NSSegmentedControl"), "Org segmented control must be gone")
        XCTAssertFalse(source.contains("\"Org:\""), "Org label must be gone")
        XCTAssertFalse(source.contains("orgControl"))
        XCTAssertFalse(source.contains("selectedOrg"))
        XCTAssertTrue(source.contains("RepoOrg.org(forProjectPath:"), "Org must be inferred from the repo")
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
