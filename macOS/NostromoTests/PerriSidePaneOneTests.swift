import XCTest
import AppKit
import NostromoKit

// Perri side pane, slice 1: a queue-row click pins the PR for its own focus and
// opens nothing; a Perri row's context menu gains the two browser items; the
// daemon's Jira site rides on `perri_state`. Tests inject the sender, opener
// and state directory so nothing touches the daemon, the browser or the real
// `~/.claude/state/perri`.

private func queueItem(repo: String = "acme/web", number: Int = 7,
                       url: String = "https://github.com/acme/web/pull/7") -> PRQueueItem {
    PRQueueItem(repo: repo, number: number, title: "t", author: "a", bucket: "requested",
                newActivity: false, url: url, ciState: .unknown, headSha: "abc")
}

final class PerriRowClickPinsFocusTests: XCTestCase {
    private var tempDir: URL!
    private var originalDir: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("perri-row-click-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        originalDir = AppStore.shared.perriStateDirectory
        AppStore.shared.perriStateDirectory = tempDir.path
    }

    override func tearDown() {
        AppStore.shared.perriActionSender = nil
        AppStore.shared.perriStateDirectory = originalDir
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testRowClickInAPerriFocusSendsOneLoadPrFrameForThatFocusAndWritesNothing() throws {
        var frames: [(String, Int?, String?, String?)] = []
        AppStore.shared.perriActionSender = { frames.append(($0, $1, $2, $3)) }

        let focus = Focus(id: "1a2b3c4d-0000", agentTag: "perri", projectPath: "/tmp/x",
                          isBuiltIn: false)
        let view = DynamicFocusView(focus: focus, windowId: "perri-row-click-\(UUID().uuidString.prefix(6))")
        let pane = try XCTUnwrap(view.makeLeafView(paneId: "queue-test", reusing: nil) as? PaneContentNSView)
        pane.onLoadPR("acme/web", 7)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.0, "load_pr")
        XCTAssertEqual(frames.first?.1, 7)
        XCTAssertEqual(frames.first?.2, "acme/web")
        XCTAssertEqual(frames.first?.3, focus.sessionTag, "the frame names the clicked focus")
        XCTAssertEqual(focus.sessionTag, "perri-1a2b3c4d")
        let written = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertEqual(written, [], "no legacy current-pr.json / current-pr.dirty")
    }

    func testIsPerriFocusFollowsTheBareAgentName() {
        func f(_ agent: String) -> Focus { Focus(id: "x", agentTag: agent, projectPath: nil, isBuiltIn: false) }
        XCTAssertTrue(f("perri").isPerriFocus)
        XCTAssertTrue(f("Perri").isPerriFocus)
        XCTAssertTrue(f("mother:perri").isPerriFocus)
        XCTAssertFalse(f("perri-lens").isPerriFocus)
        XCTAssertFalse(f("cody").isPerriFocus)
    }
}

final class PerriRowBrowserMenuTests: XCTestCase {
    func testPerriRowOffersBothBrowserItemsAndTheyCallTheOpener() {
        let items = PaneContentView.browserMenuItems(
            repo: "acme/web", number: 7, itemURL: "https://github.com/acme/web/pull/7",
            isPerriFocus: true)
        XCTAssertEqual(items.map(\.title), ["Open Conversation in Browser", "Open Diff in Browser"])

        var opened: [URL] = []
        for entry in items { (({ opened.append($0) }) as (URL) -> Void)(entry.url) }
        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://github.com/acme/web/pull/7",
            "https://github.com/acme/web/pull/7/files",
        ])
    }

    func testNonGitHubItemURLFallsBackToTheRepoAndNumber() {
        let items = PaneContentView.browserMenuItems(
            repo: "acme/web", number: 9, itemURL: "https://evil.example/x", isPerriFocus: true)
        XCTAssertEqual(items.map(\.url.absoluteString), [
            "https://github.com/acme/web/pull/9",
            "https://github.com/acme/web/pull/9/files",
        ])
    }

    func testNonPerriFocusHasNeitherItem() {
        XCTAssertTrue(PaneContentView.browserMenuItems(
            repo: "acme/web", number: 7, itemURL: "https://github.com/acme/web/pull/7",
            isPerriFocus: false).isEmpty)
    }

    func testHostCarriesTheInjectedOpenerAndFlag() {
        let model = PaneContentModel()
        var opened: URL?
        model.openExternalURL = { opened = $0 }
        model.isPerriFocus = true
        model.openExternalURL(URL(string: "https://github.com/a/b/pull/1")!)
        XCTAssertEqual(opened?.absoluteString, "https://github.com/a/b/pull/1")
    }
}

final class PerriStateJiraSiteDecodeTests: XCTestCase {
    override func tearDown() {
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: AppStore.shared.perriQueue,
                                                    current: nil, jiraSite: nil))
        super.tearDown()
    }

    func testFrameWithJiraSiteSetsIt() {
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [], current: nil,
                                                    jiraSite: "carefeed.atlassian.net"))
        XCTAssertEqual(AppStore.shared.perriJiraSite, "carefeed.atlassian.net")
    }

    func testFrameWithoutItClearsIt() {
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [], current: nil,
                                                    jiraSite: "carefeed.atlassian.net"))
        AppStore.shared.applyForTesting(.perriState(tag: "perri", queue: [], current: nil))
        XCTAssertNil(AppStore.shared.perriJiraSite)
    }

    func testWireFrameDecodesJiraSite() throws {
        let with = #"{"type":"perri_state","tag":"perri","queue":[],"current":null,"jira_site":"carefeed.atlassian.net"}"#
        let without = #"{"type":"perri_state","tag":"perri","queue":[],"current":null}"#
        let client = NostromodClient()
        func site(_ json: String) throws -> String? {
            let raw = Data(json.utf8)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            guard case .perriState(_, _, _, let s) = client.decode(type_: "perri_state", json: obj, raw: raw)
            else { XCTFail("not a perri_state"); return nil }
            return s
        }
        XCTAssertEqual(try site(with), "carefeed.atlassian.net")
        XCTAssertNil(try site(without))
    }
}
