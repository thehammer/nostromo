import XCTest

/// The private folder a "No codebase" focus runs in: one fresh, empty, owner-only folder per focus, under
/// a spaces root that no repo's instructions, settings or hooks can reach. Everything here runs inside a
/// throwaway fake home; the real home and `~/.nostromo-spaces` are never touched (the helpers take the
/// home, the code root and the root as parameters).
final class NoCodebaseFolderTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!
    private var home: URL!
    private var code: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("nocodebase-folder-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        code = home.appendingPathComponent("Code", isDirectory: true)
        try fm.createDirectory(at: code, withIntermediateDirectories: true)
        let baseURL = self.base!
        addTeardownBlock { try? FileManager.default.removeItem(at: baseURL) }
    }

    // MARK: Helpers

    private func mkdir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func touch(_ url: URL, _ text: String = "x") throws {
        try mkdir(url.deletingLastPathComponent())
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }

    private func create(root: URL? = nil, makeID: (() -> String)? = nil) -> Result<URL, NoCodebaseFolder.Failure> {
        let root = root ?? NoCodebaseFolder.defaultRoot(home: home)
        if let makeID {
            return NoCodebaseFolder.create(root: root, home: home, codeRoot: code, makeID: makeID)
        }
        return NoCodebaseFolder.create(root: root, home: home, codeRoot: code)
    }

    private func assertRefused(_ result: Result<URL, NoCodebaseFolder.Failure>, _ expected: NoCodebaseFolder.Failure,
                               _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success(let url):
            XCTFail("expected a refusal (\(expected)) but a folder was made at \(url.path) \(message)", file: file, line: line)
        case .failure(let failure):
            XCTAssertEqual(failure, expected, message, file: file, line: line)
            XCTAssertFalse(failure.reason.isEmpty, "a refusal says why", file: file, line: line)
        }
    }

    private func assertNothingMadeUnder(_ root: URL, file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(names.isEmpty, "a refusal leaves no folder behind, found \(names)", file: file, line: line)
    }

    // MARK: The folder it makes

    func testCreateMakesAnEmptyFolderUnderTheRootNamedByAUUID() throws {
        let root = NoCodebaseFolder.defaultRoot(home: home)
        let folder = try create(root: root).get()
        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path, "a direct child of the root")
        XCTAssertNotNil(UUID(uuidString: folder.lastPathComponent), "named by a UUID, the only name the clean-up touches")
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [], "empty: no instructions, settings or files")
    }

    func testTheFolderIsPrivateToTheOwner() throws {
        let folder = try create().get()
        XCTAssertEqual(try mode(of: folder), 0o700)
    }

    func testTheRootIsMadePrivateWhenItIsMade() throws {
        let root = NoCodebaseFolder.defaultRoot(home: home)
        XCTAssertFalse(fm.fileExists(atPath: root.path))
        _ = try create(root: root).get()
        XCTAssertEqual(try mode(of: root), 0o700)
    }

    func testARootThatWasLeftOpenIsTightenedToPrivate() throws {
        let root = NoCodebaseFolder.defaultRoot(home: home)
        try mkdir(root)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        _ = try create(root: root).get()
        XCTAssertEqual(try mode(of: root), 0o700)
    }

    func testEveryCallMakesItsOwnNewFolder() throws {
        let first = try create().get()
        try touch(first.appendingPathComponent("work.txt"), "first conversation's file")
        let second = try create().get()
        XCTAssertNotEqual(first.path, second.path, "never one shared folder")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: second.path), [], "the second starts empty")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: first.path), ["work.txt"], "and the first is untouched")
    }

    func testANameThatAlreadyExistsIsNeverReused() throws {
        let root = NoCodebaseFolder.defaultRoot(home: home)
        let id = "11111111-2222-3333-4444-555555555555"
        let first = try create(root: root, makeID: { id }).get()
        try touch(first.appendingPathComponent("keep.txt"))
        assertRefused(create(root: root, makeID: { id }), .couldNotCreate, "a folder that exists is not adopted")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: first.path), ["keep.txt"], "what was there stays")
    }

    // MARK: Where the root is

    func testTheDefaultRootIsNostromoSpacesUnderHome() {
        XCTAssertEqual(NoCodebaseFolder.defaultDirectoryName, ".nostromo-spaces",
                       "pins parity with the daemon's SPACES_DIR_NAME; change both together")
        XCTAssertEqual(NoCodebaseFolder.defaultRoot(home: URL(fileURLWithPath: "/Users/x", isDirectory: true)).path,
                       "/Users/x/.nostromo-spaces")
        XCTAssertEqual(NoCodebaseFolder.root(env: [:], home: URL(fileURLWithPath: "/Users/x", isDirectory: true)).path,
                       "/Users/x/.nostromo-spaces")
    }

    func testTheEnvironmentMovesTheRootAndAnEmptyValueDoesNot() {
        let h = URL(fileURLWithPath: "/Users/x", isDirectory: true)
        XCTAssertEqual(NoCodebaseFolder.environmentKey, "NOSTROMO_SPACES_ROOT", "the daemon reads the same variable")
        XCTAssertEqual(NoCodebaseFolder.root(env: ["NOSTROMO_SPACES_ROOT": "/tmp/spaces"], home: h).path, "/tmp/spaces")
        XCTAssertEqual(NoCodebaseFolder.root(env: ["NOSTROMO_SPACES_ROOT": ""], home: h).path, "/Users/x/.nostromo-spaces")
    }

    func testTheRootIsNotUnderTheDaemonsPrivateState() {
        let root = NoCodebaseFolder.defaultRoot(home: URL(fileURLWithPath: "/Users/x", isDirectory: true)).path
        XCTAssertFalse(root.hasPrefix("/Users/x/.nostromo/"), "an agent must never work next to approvals and history")
    }

    // MARK: Refusals

    func testARootInsideAGitRepoIsRefused() throws {
        let repo = home.appendingPathComponent("repo", isDirectory: true)
        try mkdir(repo.appendingPathComponent(".git"))
        let root = repo.appendingPathComponent("spaces", isDirectory: true)
        assertRefused(create(root: root), .rootInsideGitRepo)
        XCTAssertFalse(fm.fileExists(atPath: root.path), "the root is not made either")
    }

    func testARootInsideALinkedWorktreeIsRefused() throws {
        // A linked worktree's `.git` is a file.
        let tree = home.appendingPathComponent("repo-feature", isDirectory: true)
        try touch(tree.appendingPathComponent(".git"), "gitdir: /elsewhere")
        assertRefused(create(root: tree.appendingPathComponent("spaces", isDirectory: true)), .rootInsideGitRepo)
    }

    func testAnExistingRootThatIsItselfARepoIsRefused() throws {
        let root = home.appendingPathComponent("spaces", isDirectory: true)
        try mkdir(root.appendingPathComponent(".git"))
        assertRefused(create(root: root), .rootInsideGitRepo)
    }

    func testARootInsideTheCodeRootIsRefused() throws {
        let root = code.appendingPathComponent("spaces", isDirectory: true)
        assertRefused(create(root: root), .rootInsideCodeRoot)
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    func testTheCodeRootItselfIsRefused() throws {
        assertRefused(create(root: code), .rootInsideCodeRoot)
        assertNothingMadeUnder(code)
    }

    func testAFolderThatMerelySharesTheCodeRootsNamePrefixIsNotInsideIt() throws {
        // `~/Code-spaces` is not inside `~/Code`.
        let root = home.appendingPathComponent("Code-spaces", isDirectory: true)
        let folder = try create(root: root).get()
        XCTAssertEqual(folder.deletingLastPathComponent().path, root.path)
    }

    func testTheHomeFolderItselfIsRefused() throws {
        assertRefused(create(root: home), .rootIsHome)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: home.path), ["Code"], "nothing was added to home")
    }

    func testARootThatIsASymbolicLinkIsRefused() throws {
        let real = base.appendingPathComponent("real", isDirectory: true)
        try mkdir(real)
        let link = home.appendingPathComponent("spaces", isDirectory: false)
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        assertRefused(create(root: link), .rootIsSymlink, "even when it points at a fine folder")
        assertNothingMadeUnder(real)
    }

    func testARootThatIsAFileIsRefused() throws {
        let file = home.appendingPathComponent("spaces")
        try touch(file)
        assertRefused(create(root: file), .rootNotDirectory)
    }

    func testARootWhoseParentIsMissingIsRefusedAndNothingIsMade() throws {
        let root = home.appendingPathComponent("no/such/parent/spaces", isDirectory: true)
        assertRefused(create(root: root), .rootParentMissing)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("no").path), "no intermediate folders either")
    }

    // MARK: Instructions an ancestor would colour the conversation with

    private func assertAncestorFileRefuses(_ relative: String, named name: String,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        let project = base.appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        try touch(project.appendingPathComponent(relative))
        let parent = project.appendingPathComponent("deeper", isDirectory: true)
        try mkdir(parent)
        let root = parent.appendingPathComponent("spaces", isDirectory: true)
        let result = create(root: root)
        assertRefused(result, .ancestorHoldsInstructions(name), "\(relative) above the root", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: root.path), "\(relative): the root is not made", file: file, line: line)
        if case .failure(let failure) = result {
            XCTAssertFalse(failure.reason.contains(base.path), "the reason names the file, never a path", file: file, line: line)
            XCTAssertTrue(failure.reason.contains(name), "the reason says which file", file: file, line: line)
        }
    }

    func testAClaudeMdInAnAncestorRefuses() throws { try assertAncestorFileRefuses("CLAUDE.md", named: "CLAUDE.md") }
    func testAClaudeLocalMdInAnAncestorRefuses() throws { try assertAncestorFileRefuses("CLAUDE.local.md", named: "CLAUDE.local.md") }
    func testAnMcpJsonInAnAncestorRefuses() throws { try assertAncestorFileRefuses(".mcp.json", named: ".mcp.json") }
    func testProjectSettingsInAnAncestorRefuse() throws {
        try assertAncestorFileRefuses(".claude/settings.json", named: ".claude/settings.json")
    }
    func testLocalProjectSettingsInAnAncestorRefuse() throws {
        try assertAncestorFileRefuses(".claude/settings.local.json", named: ".claude/settings.local.json")
    }

    func testTheWholeWalkIsCheckedNotJustTheParent() throws {
        // The instructions sit four folders above the root.
        let top = base.appendingPathComponent("top", isDirectory: true)
        try touch(top.appendingPathComponent("CLAUDE.md"))
        let parent = top.appendingPathComponent("a/b/c", isDirectory: true)
        try mkdir(parent)
        assertRefused(create(root: parent.appendingPathComponent("spaces", isDirectory: true)),
                      .ancestorHoldsInstructions("CLAUDE.md"))
    }

    func testInstructionsInAnExistingRootItselfRefuse() throws {
        let root = home.appendingPathComponent("spaces", isDirectory: true)
        try touch(root.appendingPathComponent("CLAUDE.md"))
        assertRefused(create(root: root), .ancestorHoldsInstructions("CLAUDE.md"))
    }

    func testInstructionsInTheHomeFolderRefuse() throws {
        // `~/CLAUDE.md` is read by walking up from the folder; only `~/.claude` is the user's own.
        try touch(home.appendingPathComponent("CLAUDE.md"))
        assertRefused(create(), .ancestorHoldsInstructions("CLAUDE.md"))
    }

    func testTheUsersOwnClaudeSettingsAloneDoNotRefuse() throws {
        try touch(home.appendingPathComponent(".claude/settings.json"), "{}")
        try touch(home.appendingPathComponent(".claude/settings.local.json"), "{}")
        let folder = try create().get()
        XCTAssertEqual(folder.deletingLastPathComponent().path, NoCodebaseFolder.defaultRoot(home: home).path)
    }

    func testTheUsersOwnClaudeFolderInstructionsDoNotRefuse() throws {
        try touch(home.appendingPathComponent(".claude/CLAUDE.md"), "my own instructions")
        XCTAssertNoThrow(try create().get())
    }

    func testProjectSettingsOutsideTheHomeFolderStillRefuseWhenHomeAlsoHasSome() throws {
        // The home exemption is for the home folder only.
        try touch(home.appendingPathComponent(".claude/settings.json"), "{}")
        let project = home.appendingPathComponent("elsewhere", isDirectory: true)
        try touch(project.appendingPathComponent(".claude/settings.json"), "{}")
        assertRefused(create(root: project.appendingPathComponent("spaces", isDirectory: true)),
                      .ancestorHoldsInstructions(".claude/settings.json"))
    }

    // MARK: Every refusal speaks

    func testEveryFailureHasADistinctReasonWithNoPathInIt() {
        let all: [NoCodebaseFolder.Failure] = [
            .rootIsSymlink, .rootNotDirectory, .rootParentMissing, .rootIsHome, .rootInsideCodeRoot,
            .rootInsideGitRepo, .ancestorHoldsInstructions("CLAUDE.md"), .couldNotCreate, .notEmpty,
        ]
        let reasons = all.map(\.reason)
        XCTAssertEqual(Set(reasons).count, reasons.count, "each failure says something different")
        for reason in reasons {
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("/"), "a reason is words, not a path: \(reason)")
        }
    }
}
