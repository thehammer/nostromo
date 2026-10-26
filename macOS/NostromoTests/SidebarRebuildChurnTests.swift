import XCTest
import AppKit
import Darwin
import NostromoKit

// A sidebar that is rebuilt when nothing changed leaks memory for good.
//
// What leaks: every time AppKit creates a NEW `NSTextField` / `NSImageView` / `NSButton` and shows it
// in a window, it registers KVO dependency records (`NSKeyValueDependency`, `NSKeyValueContext` and
// their blocks, about 3 to 10 per control) that are never freed. Measured in CI; the 2026-10-25 heap
// held about 2 million of them. So a view tree that is torn down and rebuilt needlessly costs memory
// on every rebuild, forever.
//
// What triggered it: the daemon sends one `perri_state` frame per focus every 60 s whether or not
// anything changed. `AppStore` wrote `perriQueue` and `perriDetailByTag` on each one (an `@Published`
// write publishes even when the value is equal), and `TabBarView` subscribes to `perriDetailByTag` and
// tore down and rebuilt every sidebar row (`setFocuses`) on each publish: dozens of new labels a minute.
//
// What the guard prevents: `AppStore` writes only a changed value, and `TabBarView.setFocuses` returns
// early when the rows it would build equal the rows already built. These tests pin the behaviour from
// outside: unchanged frames leave the very same row views in place and do not grow live malloc blocks,
// while a frame that does change something still updates the sidebar, and `PRDetail` / `PRQueueItem`
// compare by value so the store can tell the two apart.
//
// Frames are fed through `AppStore.shared.applyForTesting`, the seam that runs the same `handle` the
// live IPC stream uses without `start()` (which connects to the daemon and watches the real home).

private enum SidebarChurnMeter {
    static func blocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }
}

final class SidebarRebuildChurnTests: XCTestCase {

    // MARK: - Rig

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Sidebar {
        let tabBar: TabBarView
        let window: NSWindow
    }

    private var store: AppStore { AppStore.shared }

    override func setUp() {
        super.setUp()
        // Leave the shared store as found: the frames below write the global queue and the per-tag PR.
        let originalQueue = AppStore.shared.perriQueue
        addTeardownBlock {
            for tag in ["perri", "fred", "ghost-tag"] {
                AppStore.shared.applyForTesting(.perriState(tag: tag, queue: originalQueue, current: nil))
            }
        }
    }

    /// A mix of built-ins and dynamic focuses in three orgs, two of the repos shared by two focuses
    /// (so repo headers appear), 10 focuses in all.
    private func makeFocuses() -> [Focus] {
        func dynamic(_ id: String, _ agent: String, _ repo: String, org: String) -> Focus {
            Focus(id: id, agentTag: agent, projectPath: "/tmp/sbrch-nonexistent/\(repo)",
                  isBuiltIn: false, org: org, sessionSummary: nil)
        }
        return Focus.builtIns + [
            dynamic("sbrch-1", "claudia", "admin-portal", org: "Carefeed"),
            dynamic("sbrch-2", "cody",    "admin-portal", org: "Carefeed"),
            dynamic("sbrch-3", "claudia", "nostromo",     org: "Carefeed"),
            dynamic("sbrch-4", "cody",    "acme-web",     org: "Acme"),
            dynamic("sbrch-5", "redd",    "acme-web",     org: "Acme"),
            dynamic("sbrch-6", "claudia", "zeta-tool",    org: "Zeta"),
        ]
    }

    private func makeSidebar(focuses: [Focus]) -> Sidebar {
        let size = NSSize(width: 240, height: 700)
        let tabBar = TabBarView(frame: NSRect(origin: .zero, size: size))
        tabBar.autoresizingMask = [.width, .height]
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = tabBar
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            window.orderOut(nil)
            window.contentView = nil
        }
        tabBar.setFocuses(focuses)
        settle(window)
        return Sidebar(tabBar: tabBar, window: window)
    }

    private func settle(_ window: NSWindow, turns: Int = 10) {
        for _ in 0 ..< turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Runs the main queue until everything enqueued before this call has run (the sidebar's
    /// subscription hops to the main queue, so a marker enqueued after the frames runs after their sinks).
    private func drainMainQueue() {
        var reached = false
        DispatchQueue.main.async { reached = true }
        let deadline = Date().addingTimeInterval(20)
        while !reached, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(reached, "the main queue never drained")
        for _ in 0 ..< 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    /// The sidebar's row views, top to bottom: org headers, repo headers and focus items.
    private func rowViews(_ sidebar: Sidebar) throws -> [NSView] {
        let scroll = try XCTUnwrap(scrollView(in: sidebar.tabBar), "the sidebar has a scroll view")
        let document = try XCTUnwrap(scroll.documentView, "the sidebar has a document view")
        return document.subviews
    }

    private func focusItems(_ sidebar: Sidebar) throws -> [NavTabItem] {
        try rowViews(sidebar).compactMap { $0 as? NavTabItem }
    }

    private func identities(_ views: [NSView]) -> [ObjectIdentifier] { views.map { ObjectIdentifier($0) } }

    private func queueItems() -> [PRQueueItem] {
        (1 ... 3).map {
            PRQueueItem(repo: "Carefeed/admin-portal", number: 100 + $0, title: "PR \($0)", author: "someone",
                        bucket: "needs_review", newActivity: false, url: "https://example.test/pr/\($0)",
                        ciState: .success, headSha: "sha\($0)")
        }
    }

    private func prDetail(number: Int, repo: String = "Carefeed/admin-portal", title: String = "A title") throws -> PRDetail {
        try decodeDetail(["pr_number": number, "repo": repo, "title": title])
    }

    // MARK: - 1. Unchanged frames do not rebuild the sidebar

    func testUnchangedPerriStateFramesLeaveTheSidebarRowViewsInPlace() throws {
        let sidebar = makeSidebar(focuses: makeFocuses())
        let rowsBefore = try rowViews(sidebar)
        XCTAssertGreaterThan(rowsBefore.count, 10, "precondition: org headers, repo headers and focus rows are on screen")
        XCTAssertEqual(try focusItems(sidebar).count, 10, "precondition: one item per focus")
        let queue = queueItems()
        let tags = ["perri", "fred", "ghost-tag"]

        // The first frame may change the store (the global queue); once it has, the sidebar is at rest.
        for tag in tags { store.applyForTesting(.perriState(tag: tag, queue: queue, current: nil)) }
        drainMainQueue()
        settle(sidebar.window)
        let identitiesBefore = identities(try rowViews(sidebar))

        for i in 0 ..< 200 {
            for tag in tags { store.applyForTesting(.perriState(tag: tag, queue: queue, current: nil)) }
            if i % 25 == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        }
        drainMainQueue()
        settle(sidebar.window)

        XCTAssertEqual(store.perriQueue, queue, "precondition: the frames were handled")
        XCTAssertEqual(identities(try rowViews(sidebar)), identitiesBefore,
                       "600 frames that changed nothing replaced sidebar row views: every rebuild creates new "
                       + "labels whose AppKit KVO records are never freed")
    }

    func testUnchangedPerriStateFramesDoNotGrowLiveMallocBlocks() throws {
        let sidebar = makeSidebar(focuses: makeFocuses())
        let queue = queueItems()
        let tags = ["perri", "fred", "ghost-tag"]
        let frames = 200 * tags.count
        let allowedBlocksPerFrame = 2

        func burst(_ rounds: Int) {
            for i in 0 ..< rounds {
                for tag in tags { store.applyForTesting(.perriState(tag: tag, queue: queue, current: nil)) }
                if i % 25 == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            }
            drainMainQueue()
        }

        burst(20)
        settle(sidebar.window)
        let before = SidebarChurnMeter.blocksInUse()

        burst(200)
        settle(sidebar.window)
        let growth = SidebarChurnMeter.blocksInUse() - before

        XCTFail("TEMP-MEASURE sidebar churn: \(frames) unchanged frames, live malloc blocks +\(growth), rebuilt-counter \(RebuildCounters.snapshot)")
        XCTAssertLessThan(growth, frames * allowedBlocksPerFrame,
                          "\(frames) frames that changed nothing left \(growth) more live malloc blocks "
                          + "(allowed \(frames * allowedBlocksPerFrame)): the sidebar is being rebuilt, and every new "
                          + "label leaks AppKit KVO records for good")
    }

    // MARK: - 2. A frame that changes something still updates the sidebar

    func testAFrameThatChangesAFocusesPRStillUpdatesItsSidebarRow() throws {
        try XCTSkipUnless(FocusStore.shared.focuses.contains { $0.sessionTag == "perri" },
                          "the Perri built-in is disabled in this environment, so the store would not record its PR")
        let sidebar = makeSidebar(focuses: makeFocuses())
        func perriRow() throws -> NavTabItem {
            try XCTUnwrap(try focusItems(sidebar).first { $0.focus.id == "perri" }, "the sidebar has a Perri row")
        }
        XCTAssertEqual(try perriRow().secondaryText, FocusPRLabel.noPR, "precondition: no PR yet")

        // A PR loads.
        store.applyForTesting(.perriState(tag: "perri", queue: queueItems(),
                                          current: try prDetail(number: 4242)))
        let loaded = FocusPRLabel.secondary(repo: "Carefeed/admin-portal", number: 4242, fallback: nil)
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? perriRow().secondaryText) == loaded }
        XCTAssertEqual(try perriRow().secondaryText, loaded, "the row shows the PR under review")
        XCTAssertNotEqual(loaded, FocusPRLabel.noPR)

        // The same PR again changes nothing; a different PR does.
        store.applyForTesting(.perriState(tag: "perri", queue: queueItems(),
                                          current: try prDetail(number: 4242)))
        drainMainQueue()
        XCTAssertEqual(try perriRow().secondaryText, loaded)

        store.applyForTesting(.perriState(tag: "perri", queue: queueItems(),
                                          current: try prDetail(number: 4300, repo: "Carefeed/nostromo")))
        let changed = FocusPRLabel.secondary(repo: "Carefeed/nostromo", number: 4300, fallback: nil)
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? perriRow().secondaryText) == changed }
        XCTAssertEqual(try perriRow().secondaryText, changed, "a different PR replaces the label")

        // The PR clears.
        store.applyForTesting(.perriState(tag: "perri", queue: queueItems(), current: nil))
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? perriRow().secondaryText) == FocusPRLabel.noPR }
        XCTAssertEqual(try perriRow().secondaryText, FocusPRLabel.noPR, "clearing the PR says so")
    }

    func testChangingTheFocusListStillRebuildsTheSidebarRows() throws {
        let focuses = makeFocuses()
        let sidebar = makeSidebar(focuses: focuses)
        XCTAssertEqual(try focusItems(sidebar).count, 10)

        sidebar.tabBar.setFocuses(Array(focuses.dropLast()))
        settle(sidebar.window)
        XCTAssertEqual(try focusItems(sidebar).count, 9, "a removed focus loses its row")
        XCTAssertFalse(try focusItems(sidebar).contains { $0.focus.id == "sbrch-6" })

        sidebar.tabBar.setFocuses(focuses)
        settle(sidebar.window)
        XCTAssertEqual(try focusItems(sidebar).count, 10, "and gets it back")
        XCTAssertTrue(try focusItems(sidebar).contains { $0.focus.id == "sbrch-6" })
    }

    // MARK: - 3. Value equality of what a frame carries

    private func decodeDetail(_ overrides: [String: Any] = [:]) throws -> PRDetail {
        var json: [String: Any] = [
            "pr_number": 7, "repo": "Carefeed/admin-portal", "title": "Fix the thing", "author": "someone",
            "url": "https://example.test/pr/7", "diff": "diff --git a/x b/x\n+line\n", "diff_too_large": false,
            "ci_checks": [["name": "build", "state": "success"],
                          ["name": "lint", "state": "failure", "detail": "boom"]],
            "additions": 10, "deletions": 2, "changed_files": 3, "head_sha": "abc123",
        ]
        for (key, value) in overrides { json[key] = value }
        return try JSONDecoder().decode(PRDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPRDetailsDecodedFromIdenticalJSONAreEqual() throws {
        XCTAssertEqual(try decodeDetail(), try decodeDetail())
    }

    func testPRDetailsDifferWhenAnyFieldAFrameCouldChangeDiffers() throws {
        let base = try decodeDetail()
        let variations: [(String, [String: Any])] = [
            ("title", ["title": "Another title"]),
            ("head sha", ["head_sha": "def456"]),
            ("diff", ["diff": "diff --git a/y b/y\n+other\n"]),
            ("a CI check's state", ["ci_checks": [["name": "build", "state": "failure"],
                                                  ["name": "lint", "state": "failure", "detail": "boom"]]]),
            ("a CI check's detail", ["ci_checks": [["name": "build", "state": "success"],
                                                   ["name": "lint", "state": "failure", "detail": "different"]]]),
            ("the number of CI checks", ["ci_checks": [["name": "build", "state": "success"]]]),
            ("additions", ["additions": 11]),
            ("deletions", ["deletions": 3]),
            ("changed files", ["changed_files": 4]),
            ("PR number", ["pr_number": 8]),
            ("repo", ["repo": "Carefeed/nostromo"]),
            ("author", ["author": "someone else"]),
            ("error", ["error": "rate limited"]),
        ]
        for (name, overrides) in variations {
            XCTAssertNotEqual(base, try decodeDetail(overrides), "details differing in \(name) must not be equal")
        }
    }

    func testPRQueueItemsCompareByValue() {
        func item(repo: String = "Carefeed/admin-portal", number: Int = 1, title: String = "t", author: String = "a",
                  bucket: String = "needs_review", newActivity: Bool = false, url: String = "https://example.test/1",
                  ciState: CiState = .success, headSha: String = "sha") -> PRQueueItem {
            PRQueueItem(repo: repo, number: number, title: title, author: author, bucket: bucket,
                        newActivity: newActivity, url: url, ciState: ciState, headSha: headSha)
        }
        XCTAssertEqual(item(), item())
        XCTAssertNotEqual(item(), item(repo: "Carefeed/nostromo"))
        XCTAssertNotEqual(item(), item(number: 2))
        XCTAssertNotEqual(item(), item(title: "other"))
        XCTAssertNotEqual(item(), item(author: "b"))
        XCTAssertNotEqual(item(), item(bucket: "changes_req"))
        XCTAssertNotEqual(item(), item(newActivity: true))
        XCTAssertNotEqual(item(), item(url: "https://example.test/2"))
        XCTAssertNotEqual(item(), item(ciState: .failure))
        XCTAssertNotEqual(item(), item(headSha: "other"))
    }
}
