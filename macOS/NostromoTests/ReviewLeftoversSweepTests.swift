import XCTest
import AppKit
import NostromoKit

// Review-leftovers sweep 2 (Mac): three small gaps Perri's reviews named.
//
//   * #471  `SessionSpawnMsg` carries `no_codebase` on the wire (the daemon refuses a no-codebase spawn
//           without a folder, so a dropped flag would be a silent policy change).
//   * #462  `NostromodClient.sendPerriAction` writes the `perri_action` frame the daemon reads, and the
//           Perri focus's pane is built with its Perri wiring.
//   * #460  The list row cleans the title it shows even for a job with no title, whose `job.id` is shown
//           instead: the decode cleans the title, never the id.
//
// A real `NostromodClient` is connected to a scripted `FakeDaemon` (NostromodClientHandshakeTests.swift)
// over a real socket, the way SessionQueueWireTests does, so the test sees the frame as written.

final class NostromodClientFrameEncodingTests: XCTestCase {

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private func connect() throws -> (NostromodClient, FakeDaemon) {
        let daemon = FakeDaemon(scripts: [.init(features: [])])
        try daemon.start()
        addTeardownBlock { daemon.stop() }
        let client = NostromodClient(socketPath: daemon.path)
        client.start()
        XCTAssertTrue(waitUntil { client.connected.value }, "the client never connected")
        return (client, daemon)
    }

    /// The first frame of `type` the daemon read, once it arrived.
    private func firstFrame(_ daemon: FakeDaemon, ofType type: String) throws -> [String: Any] {
        XCTAssertTrue(waitUntil { !daemon.frames(connection: 0, ofType: type).isEmpty }, "no `\(type)` frame arrived")
        return try XCTUnwrap(daemon.frames(connection: 0, ofType: type).first).json
    }

    // MARK: #471 no_codebase

    func testASpawnForAFocusWithNoCodebaseCarriesNoCodebaseTrue() throws {
        let (client, daemon) = try connect()

        client.sessionSpawn(tag: "cody-1", agentName: "cody", viewName: "v", cwd: "/tmp/spaces/abc",
                            sessionId: nil, remoteControl: false, noCodebase: true)

        let frame = try firstFrame(daemon, ofType: "session_spawn")
        XCTAssertEqual(frame["no_codebase"] as? Bool, true)
        XCTAssertEqual(frame["tag"] as? String, "cody-1")
        XCTAssertEqual(frame["cwd"] as? String, "/tmp/spaces/abc")
    }

    func testAnOrdinarySpawnCarriesNoCodebaseFalse() throws {
        let (client, daemon) = try connect()

        client.sessionSpawn(tag: "cody-2", agentName: "cody", viewName: "v", cwd: "/tmp/repo",
                            sessionId: nil, remoteControl: false)

        let frame = try firstFrame(daemon, ofType: "session_spawn")
        XCTAssertEqual(frame["no_codebase"] as? Bool, false, "the key is always on the wire, false for a codebase focus")
    }

    // MARK: #462 sendPerriAction

    func testLoadPrIsWrittenAsAPerriActionFrameNamingTheFocus() throws {
        let (client, daemon) = try connect()

        client.sendPerriAction(action: "load_pr", prNumber: 12, repo: "acme/web", tag: "perri-1a2b3c4d")

        let frame = try firstFrame(daemon, ofType: "perri_action")
        XCTAssertEqual(frame["action"] as? String, "load_pr")
        XCTAssertEqual(frame["pr_number"] as? Int, 12)
        XCTAssertEqual(frame["repo"] as? String, "acme/web")
        XCTAssertEqual(frame["tag"] as? String, "perri-1a2b3c4d")
    }

    func testAPerriActionWithoutAFocusLeavesTheTagOutSoTheDaemonUsesTheBuiltInPerri() throws {
        let (client, daemon) = try connect()

        client.sendPerriAction(action: "clear", prNumber: nil, repo: nil, tag: nil)

        let frame = try firstFrame(daemon, ofType: "perri_action")
        XCTAssertEqual(frame["action"] as? String, "clear")
        XCTAssertNil(frame["tag"], "no tag key at all: nil means the built-in Perri focus")
    }

    // MARK: A send reports whether it left the process

    func testASessionSendReportsWhetherTheFrameWasWritten() throws {
        let (client, daemon) = try connect()
        XCTAssertTrue(client.sessionSend(tag: "cody-1", text: "hi"))
        _ = try firstFrame(daemon, ofType: "session_send")

        let offline = NostromodClient(socketPath: "/dev/null")
        XCTAssertFalse(offline.sessionSend(tag: "cody-1", text: "hi"), "not connected: nothing was written")
        XCTAssertFalse(offline.sessionSend(tag: "cody-1", text: "hi", clientRef: "c-1"))
    }
}

// MARK: - #462 the Perri focus's pane wiring

final class PerriFocusPaneWiringTests: XCTestCase {

    private func leaf(agent: String) throws -> PaneContentNSView {
        let focus = Focus(id: "1a2b3c4d-0000", agentTag: agent, projectPath: "/tmp/x", isBuiltIn: false)
        let view = DynamicFocusView(focus: focus, windowId: "perri-wiring-\(UUID().uuidString.prefix(6))")
        return try XCTUnwrap(view.makeLeafView(paneId: "queue-test", reusing: nil) as? PaneContentNSView)
    }

    func testAPerriFocusBuildsItsPaneAsAPerriPaneWithRowControls() throws {
        let pane = try leaf(agent: "perri")
        XCTAssertTrue(pane.isPerriFocus)
        XCTAssertNotNil(pane.rowActions, "a Perri queue row gets the side-pane controls")
    }

    func testAnotherAgentsFocusPaneIsNotAPerriPane() throws {
        let pane = try leaf(agent: "cody")
        XCTAssertFalse(pane.isPerriFocus)
        XCTAssertNil(pane.rowActions)
    }
}

// MARK: - #460 the row title for a job with no title

final class MotherRowTitleFallbackTests: XCTestCase {

    private func makeVM() throws -> MotherJobListViewModel {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mother-row-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return MotherJobListViewModel(focusStore: FocusStore(storageURL: dir.appendingPathComponent("focuses.json")))
    }

    private func job(id: String, title: String) -> MotherJob {
        MotherJob(id: id, state: "queued", repo: "nostromo", isolation: "worktree", title: title,
                  createdAt: Date(timeIntervalSince1970: 1_000), startedAt: nil, finishedAt: nil,
                  planPath: nil, question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    func testAJobWithNoTitleShowsItsIdCleanedBecauseOnlyTheTitleIsCleanedWhenDecoded() throws {
        let dirty = "job-\u{1B}[31mred\u{7}\nnext"
        let row = try makeVM().rowModel(for: job(id: dirty, title: ""))

        XCTAssertNotEqual(row.title, dirty, "the id is not shown raw")
        XCTAssertEqual(row.title, FoldTextSanitizer.sanitizeInline(dirty))
        XCTAssertFalse(row.title.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F },
                       "no control character reaches the row: \(row.title.debugDescription)")
    }

    func testTheDecodeCleansTheTitleButNotTheIdWhichIsWhyTheRowCleansTheFallback() throws {
        let json = """
        {"id":"j\\u0007x","state":"queued","repo":"r","isolation":"worktree","title":"t\\u0007itle"}
        """
        let decoded = try JSONDecoder().decode(MotherJobSlim.self, from: Data(json.utf8)).toMotherJob()
        XCTAssertEqual(decoded.title, FoldTextSanitizer.sanitizeInline("t\u{7}itle"), "the title is cleaned at decode")
        XCTAssertEqual(decoded.id, "j\u{7}x", "the id is kept as the daemon sent it")
    }

    func testATitledJobShowsItsTitleUnchanged() throws {
        let row = try makeVM().rowModel(for: job(id: "j1", title: "Fix the picker"))
        XCTAssertEqual(row.title, "Fix the picker")
    }
}
