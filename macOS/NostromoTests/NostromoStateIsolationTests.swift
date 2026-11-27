import XCTest

// Every store that keeps the operator's state on disk is built from `NostromoHome`, which under XCTest is a
// per-process temporary directory. These tests pin that for each store the app has: the path it uses by
// default is inside the test home and is not under the real `~/.nostromo` (or `~/.mother`, `~/.claude`).
//
// Mutation: make `NostromoHome.isRunningUnderTests` false, or build one store's path from
// `FileManager.default.homeDirectoryForCurrentUser`: the matching test below fails, and
// `tests/state_path_policy` fails on the source.
//
// Sources are compiled into this target directly; nothing here touches the real directories. (The app-control
// socket is not compiled into this target; `tests/state_path_policy` covers its path.)

final class NostromoStateIsolationTests: XCTestCase {

    private let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path + "/"
    private var testRoot: String { NostromoHome.testRoot.resolvingSymlinksInPath().path + "/" }

    /// `path` is inside this process's test home and nowhere in the real one. A path that an environment
    /// variable overrides (the daemon's own sockets) is the variable's value when it is set: inside a Nostromo
    /// agent session `NOSTROMO_MCP_SOCKET` is, so that one assertion only bites where it is unset (CI).
    private func assertInTestHome(_ path: String, overriddenBy env: String? = nil, file: StaticString = #filePath,
                                  line: UInt = #line) {
        if let env, let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
            XCTAssertEqual(path, value, "\(env) overrides", file: file, line: line)
            return
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        XCTAssertTrue(resolved.hasPrefix(testRoot), "\(path) is not inside the test home \(testRoot)", file: file, line: line)
        XCTAssertFalse(resolved.hasPrefix(realHome + ".nostromo"), "\(path) is the real ~/.nostromo", file: file, line: line)
        XCTAssertFalse(resolved.hasPrefix(realHome + ".mother"), "\(path) is the real ~/.mother", file: file, line: line)
    }

    func testTheComposerHistoryStoreLivesInTheTestHome() {
        assertInTestHome(ComposerHistoryStore.sharedDirectory.path)
        assertInTestHome(ComposerHistoryStore.shared.directory.path)
    }

    func testTheSensitivityMarksLiveBesideTheComposerHistoryInTheTestHome() throws {
        let directory = try XCTUnwrap(FocusSensitivity.sharedMarksDirectory, "marks persist when the history does")
        XCTAssertEqual(directory, ComposerHistoryStore.sharedDirectory)
        assertInTestHome(directory.path)
    }

    /// The incident of #511: a test that sent a work item wrote `sensitive-marks.v1.json` into the real
    /// `~/.nostromo/composer-history.v1`. With the seam the shared instance writes it, but into the test home.
    func testSendingAWorkItemWritesTheMarksIntoTheTestHomeNotTheRealOne() throws {
        let realMarks = URL(fileURLWithPath: realHome).appendingPathComponent(".nostromo/composer-history.v1/\(FocusSensitivity.marksFileName)")
        let realBefore = try? FileManager.default.attributesOfItem(atPath: realMarks.path)[.modificationDate] as? Date

        FocusSensitivity.shared.noteWorkSend(tag: "isolation-\(UUID().uuidString)")

        let testMarks = ComposerHistoryStore.sharedDirectory.appendingPathComponent(FocusSensitivity.marksFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testMarks.path), "the marks were written under the test home")
        assertInTestHome(testMarks.path)
        let realAfter = try? FileManager.default.attributesOfItem(atPath: realMarks.path)[.modificationDate] as? Date
        XCTAssertEqual(realAfter, realBefore, "the real marks file is untouched")
    }

    func testTheFocusListLivesInTheTestHome() {
        assertInTestHome(FocusStore.shared.storageURL.path)
    }

    func testTheTranscriptFoldStoreLivesInTheTestHome() {
        assertInTestHome(TranscriptFoldStore.shared.fileURL.path)
    }

    /// The incident of #496: `TaskWindowTests` (through `ActivationAudit`) appended 163 lines to the real
    /// `~/.nostromo/logs/window-placement.log`.
    func testTheWindowPlacementLogLivesInTheTestHomeAndTheSharedLogWritesThere() throws {
        assertInTestHome(WindowPlacementLog.defaultFileURL.path)
        let realLog = URL(fileURLWithPath: realHome).appendingPathComponent(".nostromo/logs/window-placement.log")
        let realSize = (try? FileManager.default.attributesOfItem(atPath: realLog.path)[.size] as? NSNumber)?.intValue

        WindowPlacementLog.shared.log("isolation", "line from NostromoStateIsolationTests")
        WindowPlacementLog.shared.flush()

        let written = try String(contentsOf: WindowPlacementLog.defaultFileURL, encoding: .utf8)
        XCTAssertTrue(written.contains("line from NostromoStateIsolationTests"))
        let realSizeAfter = (try? FileManager.default.attributesOfItem(atPath: realLog.path)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(realSizeAfter, realSize, "the real window-placement.log did not grow")
    }

    func testTheAttachmentStagingDirectoryLivesInTheTestHome() {
        assertInTestHome(ImagePasteboard.stagingDir.path)
    }

    func testTheCaptureDirectoriesLiveInTheTestHome() {
        assertInTestHome(OverflowCapture.defaultDirectory.path)
        assertInTestHome(PaneBlankCapture.defaultDirectory.path)
    }

    func testTheHueyFolderLivesInTheTestHome() {
        assertInTestHome(DocumentLinkPolicy.hueyRoot().path)
    }

    func testTheSocketsLiveInTheTestHome() {
        assertInTestHome(NostromodClient.defaultSocketPath, overriddenBy: "NOSTROMD_SOCKET")
        assertInTestHome(DaemonDiagnostics.mcpSocketPath(), overriddenBy: "NOSTROMO_MCP_SOCKET")
        let broker = MotherBrokerClient.defaultSocketPath
        let env = ProcessInfo.processInfo.environment
        if env["MOTHER_BROKER_SOCK"] == nil && env["MOTHER_ROOT"] == nil {
            assertInTestHome(broker)
        }
    }

    func testTheApplicationSupportWritersLiveInTheTestHome() {
        assertInTestHome(PaneContentDump.directory.path)
        assertInTestHome(TranscriptDiagnostics.streamURL.path, overriddenBy: "NOSTROMO_DIAG_PATH")
    }

    func testTheNoCodebaseRootLivesInTheTestHome() {
        assertInTestHome(NoCodebaseFolder.root().path)
    }

    func testThePerriStateDirectoryLivesInTheTestHome() {
        assertInTestHome(AppStore.shared.perriStateDirectory)
    }

    /// `~/.claude` (agents, budget posture, Perri state) is read from the test home: a fresh one has no agents,
    /// whatever the developer's real `~/.claude/agents` holds.
    func testOtherToolsDirectoriesAreReadFromTheTestHome() {
        assertInTestHome(NostromoHome.userHome.appendingPathComponent(".claude").path)
        XCTAssertEqual(CreateFocusSheet.discoverAgents(), [], "agents come from <test home>/.claude/agents")
        if ProcessInfo.processInfo.environment["NOSTROMO_CODE_ROOT"] == nil {
            XCTAssertEqual(CreateFocusSheet.discoverProjects(), [], "projects come from <test home>/Code")
        }
    }
}
