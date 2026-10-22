import XCTest
import AppKit
import NostromoKit

// WO2: when a window's `MainLayout` pokes past its window, a structured, content-free JSON
// capture is written once (rate limited per window, pruned to the newest few), so the next
// occurrence of the 2026-10-20/21/22 overflow hands over the measurement before a relaunch
// clears it. Every test writes only into a fresh temp directory.
final class OverflowCaptureTests: XCTestCase {

    // MARK: - Rig (copied from WindowContentOverflowTests, which stays untouched)

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// A MainLayout whose frame can be pinned, so a hook test keeps its overflow across layout passes.
    private final class PinnedLayout: MainLayout {
        var pinnedSize: NSSize?
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(pinnedSize ?? newSize)
        }
    }

    private struct Rig {
        let window: NSWindow
        let layout: MainLayout
    }

    private static let size = NSSize(width: 1920, height: 1080)

    private static let replPlusText: PaneTree = .split(direction: .horizontal,
                                                       children: [.leaf(paneId: "repl"), .leaf(paneId: "plans")],
                                                       ratios: [0.5, 0.5])

    private func makeRig(index: Int,
                         planText: String? = nil,
                         make: (Int, String) -> MainLayout = { MainLayout(windowIndex: $0, displayUUID: $1) }) -> Rig {
        let displayUUID = "wo2-\(UUID().uuidString)"
        let focus = Focus.builtIns.first { $0.id == "perri" }!
        UserDefaults.standard.set("perri", forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID))
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: DisplayFocusKeys.activeTabKey(displayUUID: displayUUID)) }

        let store = AppStore.shared
        store.applyForTesting(.focusLayout(tag: focus.sessionTag, tree: Self.replPlusText, focusedPane: nil))
        if let planText {
            store.applyForTesting(.paneContent(tag: focus.sessionTag, paneId: "plans", content: .text(planText),
                                               freshness: nil, address: nil))
        }

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: Self.size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let layout = make(index, displayUUID)
        window.contentView = layout
        window.setContentSize(Self.size)
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }
        settle(window)
        return Rig(window: window, layout: layout)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    // MARK: - Helpers

    private func freshDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("overflow-capture-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A rig that captures into `dir` and never schedules its automatic capture within a test.
    private func makeCapturingRig(index: Int, dir: URL, planText: String? = nil) -> Rig {
        let rig = makeRig(index: index, planText: planText)
        rig.layout.overflowCaptureDirectory = dir
        rig.layout.overflowCaptureDelay = 3600
        return rig
    }

    private func contentSize(of window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// The real Dell incident: a layout 43 pt taller than its window.
    private func overflowBy43(_ rig: Rig) {
        let content = contentSize(of: rig.window)
        rig.layout.setFrameSize(NSSize(width: content.width, height: content.height + 43))
        XCTAssertEqual(rig.layout.contentOverflow, CGSize(width: 0, height: 43), "the synthetic overflow did not take")
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15T08:00:00Z

    private func utc(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    private func captureNames(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("layout-overflow-") && $0.hasSuffix(".json") }
            .sorted()
    }

    private func readReport(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "the capture is not a JSON object", file: file, line: line)
    }

    private func flatten(_ node: [String: Any]) -> [[String: Any]] {
        let kids = (node["children"] as? [[String: Any]]) ?? []
        return [node] + kids.flatMap { flatten($0) }
    }

    private func depth(_ node: [String: Any]) -> Int {
        let kids = (node["children"] as? [[String: Any]]) ?? []
        return 1 + (kids.map { depth($0) }.max() ?? 0)
    }

    /// Views that carry distinctive class names, to find them in the tree.
    private final class OCPokingProbe: NSView {}
    private final class OCDocumentHolder: NSView {}
    private final class OCZZDocBelowDocument: NSView {}
    private final class OCChainLink: NSView {}

    // MARK: - WO2-1: content-free

    func testCaptureContainsStructureOnlyAndNeverAnyTextFromTheWindow() throws {
        let paneSentinel = "SENTINEL-7f3a-pane-text-transcript"
        let rig = makeCapturingRig(index: 7, dir: freshDirectory(), planText: paneSentinel)
        let dir = rig.layout.overflowCaptureDirectory!

        let sentinels = [
            "SENTINEL-7f3a-textfield", "SENTINEL-7f3a-button", "SENTINEL-7f3a-tooltip",
            "SENTINEL-7f3a-a11y-label", "SENTINEL-7f3a-identifier", "SENTINEL-7f3a-textview",
            "SENTINEL-7f3a-window-title", "SENTINEL-7f3a-placeholder", "SENTINEL-7f3a-a11y-help",
            paneSentinel,
        ]
        rig.window.title = "SENTINEL-7f3a-window-title"

        let field = NSTextField(labelWithString: "SENTINEL-7f3a-textfield")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 20)
        field.toolTip = "SENTINEL-7f3a-tooltip"
        field.setAccessibilityLabel("SENTINEL-7f3a-a11y-label")
        field.setAccessibilityHelp("SENTINEL-7f3a-a11y-help")
        field.identifier = NSUserInterfaceItemIdentifier("SENTINEL-7f3a-identifier")
        rig.layout.addSubview(field)

        let input = NSTextField(frame: NSRect(x: 10, y: 40, width: 200, height: 20))
        input.placeholderString = "SENTINEL-7f3a-placeholder"
        rig.layout.addSubview(input)

        let button = NSButton(title: "SENTINEL-7f3a-button", target: nil, action: nil)
        button.frame = NSRect(x: 10, y: 70, width: 200, height: 24)
        rig.layout.addSubview(button)

        let textView = NSTextView(frame: NSRect(x: 10, y: 100, width: 200, height: 40))
        textView.string = "SENTINEL-7f3a-textview"
        rig.layout.addSubview(textView)

        settle(rig.window)
        overflowBy43(rig)
        let url = try XCTUnwrap(rig.layout.captureOverflowIfNeeded(now: t0), "an overflowing window must produce a capture")

        let text = try String(contentsOf: url, encoding: .utf8)
        for sentinel in sentinels {
            XCTAssertFalse(text.contains(sentinel), "the capture leaked \(sentinel)")
        }
        XCTAssertFalse(text.contains("SENTINEL-7f3a"), "the capture leaked window text")

        let report = try readReport(url)
        for key in ["schema", "capturedAtUTC", "windowIndex", "screen", "windowFrame", "contentSize", "layoutFrame",
                    "contentOverflow", "focus", "isKey", "fullscreen", "tree"] {
            XCTAssertNotNil(report[key], "missing top-level key \(key)")
        }
        XCTAssertEqual(report["windowIndex"] as? Int, 7)
        XCTAssertEqual(report["focus"] as? String, "perri", "a built-in focus is reported by its id")
        XCTAssertEqual(report["capturedAtUTC"] as? String, utc(t0))
        let overflow = try XCTUnwrap(report["contentOverflow"] as? [String: Any])
        XCTAssertEqual(overflow["h"] as? Double, 43)
        XCTAssertEqual(overflow["w"] as? Double, 0)
        let tree = try XCTUnwrap(report["tree"] as? [String: Any])
        XCTAssertEqual(tree["class"] as? String, "MainLayout")
        let classes = flatten(tree).compactMap { $0["class"] as? String }
        XCTAssertTrue(classes.contains("NSTextField"), "the tree should name the views it walked: \(classes.prefix(20))")
        XCTAssertTrue(classes.contains { $0.contains("TabBarView") }, "the tree should reach the chrome views")
        XCTAssertTrue(captureNames(in: dir).count == 1)
    }

    // MARK: - File mode and name

    func testCaptureFileIsOwnerOnlyAndNamedForWindowAndUTCTime() throws {
        let rig = makeCapturingRig(index: 3, dir: freshDirectory())
        overflowBy43(rig)
        let url = try XCTUnwrap(rig.layout.captureOverflowIfNeeded(now: t0))

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertEqual(url.lastPathComponent, "layout-overflow-3-\(utc(t0)).json")
        XCTAssertEqual(utc(t0), "20270115T080000Z", "the stamp fixture itself")
        XCTAssertNotNil(url.lastPathComponent.range(of: #"^layout-overflow-3-\d{8}T\d{6}Z\.json$"#, options: .regularExpression))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                       rig.layout.overflowCaptureDirectory!.standardizedFileURL.path)
    }

    // MARK: - Rate limit

    func testAWindowIsCapturedOnceUntilTheIntervalHasPassed() throws {
        let dir = freshDirectory()
        let rig = makeCapturingRig(index: 1, dir: dir)
        overflowBy43(rig)

        XCTAssertNotNil(rig.layout.captureOverflowIfNeeded(now: t0))
        XCTAssertNil(rig.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(1)))
        XCTAssertNil(rig.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(599)),
                     "inside the 600 s interval nothing is written")
        XCTAssertEqual(captureNames(in: dir).count, 1)

        let later = t0.addingTimeInterval(601)
        let second = try XCTUnwrap(rig.layout.captureOverflowIfNeeded(now: later), "after the interval a new capture is written")
        XCTAssertEqual(second.lastPathComponent, "layout-overflow-1-\(utc(later)).json")
        XCTAssertEqual(captureNames(in: dir).count, 2)
    }

    func testOneWindowsCaptureDoesNotRateLimitAnotherWindow() throws {
        let dir = freshDirectory()
        let a = makeCapturingRig(index: 11, dir: dir)
        let b = makeCapturingRig(index: 12, dir: dir)
        overflowBy43(a)
        overflowBy43(b)

        XCTAssertNotNil(a.layout.captureOverflowIfNeeded(now: t0))
        let other = try XCTUnwrap(b.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(5)),
                                  "window 12 has its own interval")
        XCTAssertEqual(other.lastPathComponent, "layout-overflow-12-\(utc(t0.addingTimeInterval(5))).json")
        XCTAssertEqual(captureNames(in: dir).count, 2)
    }

    // MARK: - No overflow

    func testAWindowWhoseLayoutFitsWritesNothing() {
        let dir = freshDirectory()
        let rig = makeCapturingRig(index: 2, dir: dir)
        XCTAssertEqual(rig.layout.contentOverflow, .zero)
        XCTAssertNil(rig.layout.captureOverflowIfNeeded(now: t0))
        XCTAssertTrue(captureNames(in: dir).isEmpty)
        XCTAssertNil(rig.layout.latestOverflowCapturePath)
    }

    func testWithoutAnExplicitDirectoryTestsNeverWriteACapture() {
        let rig = makeRig(index: 4)
        XCTAssertNil(rig.layout.overflowCaptureDirectory)
        overflowBy43(rig)
        XCTAssertNil(rig.layout.captureOverflowIfNeeded(now: t0), "under XCTest an unconfigured layout must not write into the home directory")
        XCTAssertNil(rig.layout.latestOverflowCapturePath)
    }

    // MARK: - Pruning

    func testOnlyTheFiveNewestCapturesOverAllWindowsAreKept() throws {
        let dir = freshDirectory()
        let a = makeCapturingRig(index: 21, dir: dir)
        let b = makeCapturingRig(index: 22, dir: dir)
        let c = makeCapturingRig(index: 23, dir: dir)
        for rig in [a, b, c] { overflowBy43(rig) }

        // Per window the captures are more than 600 s apart.
        let schedule: [(Rig, Int, TimeInterval)] = [
            (a, 21, 0), (b, 22, 10), (c, 23, 20),
            (a, 21, 700), (b, 22, 710), (c, 23, 720),
            (a, 21, 1400),
        ]
        for (rig, _, offset) in schedule {
            XCTAssertNotNil(rig.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(offset)), "offset \(offset)")
        }

        let expected = schedule.dropFirst(2).map { "layout-overflow-\($0.1)-\(utc(t0.addingTimeInterval($0.2))).json" }.sorted()
        XCTAssertEqual(captureNames(in: dir), expected, "the two oldest captures are removed, the five newest remain")
    }

    // MARK: - latestOverflowCapturePath

    func testLatestCapturePathIsNilUntilACaptureThenTheNewestOfThatWindowOnly() throws {
        let dir = freshDirectory()
        let a = makeCapturingRig(index: 31, dir: dir)
        let b = makeCapturingRig(index: 32, dir: dir)
        overflowBy43(a)
        overflowBy43(b)
        XCTAssertNil(a.layout.latestOverflowCapturePath)
        XCTAssertNil(b.layout.latestOverflowCapturePath)

        let first = try XCTUnwrap(a.layout.captureOverflowIfNeeded(now: t0))
        XCTAssertEqual(a.layout.latestOverflowCapturePath, first.path)
        XCTAssertNil(b.layout.latestOverflowCapturePath, "another window's capture is not this window's")

        let otherWindow = try XCTUnwrap(b.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(2000)))
        XCTAssertEqual(b.layout.latestOverflowCapturePath, otherWindow.path)
        XCTAssertEqual(a.layout.latestOverflowCapturePath, first.path, "a newer file of window 32 does not displace window 31's")

        let second = try XCTUnwrap(a.layout.captureOverflowIfNeeded(now: t0.addingTimeInterval(1000)))
        XCTAssertEqual(a.layout.latestOverflowCapturePath, second.path, "the newest capture of the window wins")
    }

    // MARK: - Structure

    func testPokingViewsListOnlyStrongConstraintsAndEveryNodeCarriesItsSizingFacts() throws {
        let rig = makeCapturingRig(index: 41, dir: freshDirectory())
        let layout = rig.layout

        // A view that demands 3000 pt through a strong constraint, plus a weak one that must not be listed.
        let probe = OCPokingProbe()
        probe.translatesAutoresizingMaskIntoConstraints = false
        layout.addSubview(probe)
        let strongWidth = probe.widthAnchor.constraint(equalToConstant: 3000)
        strongWidth.priority = NSLayoutConstraint.Priority(800)
        let weakCentre = probe.centerXAnchor.constraint(equalTo: layout.centerXAnchor)
        weakCentre.priority = NSLayoutConstraint.Priority(600)
        NSLayoutConstraint.activate([
            probe.leadingAnchor.constraint(equalTo: layout.leadingAnchor),
            probe.topAnchor.constraint(equalTo: layout.topAnchor),
            probe.heightAnchor.constraint(equalToConstant: 10),
            strongWidth, weakCentre,
        ])

        // A deep chain, to see the depth cap.
        var parent: NSView = layout
        for _ in 0..<20 {
            let link = OCChainLink(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            parent.addSubview(link)
            parent = link
        }
        settle(rig.window)
        overflowBy43(rig)

        let url = try XCTUnwrap(layout.captureOverflowIfNeeded(now: t0))
        let tree = try XCTUnwrap(try readReport(url)["tree"] as? [String: Any])
        let nodes = flatten(tree)

        XCTAssertLessThanOrEqual(depth(tree), 15, "root plus at most 14 levels")
        XCTAssertEqual(depth(tree), 15, "a 20-link chain is cut at the cap, not earlier")

        var poking = 0
        var notPoking = 0
        for node in nodes {
            let cls = node["class"] as? String ?? "?"
            for key in ["frame", "frameInWindow", "fittingSize", "intrinsicContentSize", "isHidden", "hugging",
                        "compressionResistance", "translatesAutoresizingMask", "pokesPastWindow"] {
                XCTAssertNotNil(node[key], "\(cls) lacks \(key)")
            }
            for key in ["hugging", "compressionResistance"] {
                let pair = node[key] as? [String: Any]
                XCTAssertNotNil(pair?["h"] as? Double, "\(cls).\(key).h")
                XCTAssertNotNil(pair?["v"] as? Double, "\(cls).\(key).v")
            }
            if node["pokesPastWindow"] as? Bool == true {
                poking += 1
                let constraints = node["constraints"] as? [[String: Any]]
                XCTAssertNotNil(constraints, "\(cls) pokes past the window and must list its constraints")
                for c in constraints ?? [] {
                    XCTAssertGreaterThanOrEqual(c["priority"] as? Double ?? 0, 750, "\(cls) lists a weak constraint: \(c)")
                    for key in ["first", "firstAttribute", "relation", "second", "secondAttribute", "constant",
                                "multiplier", "priority", "constraintClass"] {
                        XCTAssertNotNil(c[key], "\(cls) constraint lacks \(key)")
                    }
                }
            } else {
                notPoking += 1
                XCTAssertNil(node["constraints"], "\(cls) does not poke past the window and must not list constraints")
            }
        }
        XCTAssertGreaterThan(poking, 0)
        XCTAssertGreaterThan(notPoking, 0)

        let root = tree
        XCTAssertEqual(root["pokesPastWindow"] as? Bool, true, "the enlarged MainLayout itself pokes past the window")

        let probeNode = try XCTUnwrap(nodes.first { ($0["class"] as? String)?.contains("OCPokingProbe") == true })
        XCTAssertEqual(probeNode["pokesPastWindow"] as? Bool, true)
        let listed = try XCTUnwrap(probeNode["constraints"] as? [[String: Any]])
        XCTAssertTrue(listed.contains { $0["firstAttribute"] as? String == "width" && $0["constant"] as? Double == 3000
                                        && $0["priority"] as? Double == 800 },
                      "the 800-priority width demand must be named: \(listed)")
        XCTAssertFalse(listed.contains { $0["priority"] as? Double == 600 }, "a 600-priority constraint is below the floor")
    }

    func testNothingBelowAScrollViewsDocumentViewIsRecorded() throws {
        let rig = makeCapturingRig(index: 42, dir: freshDirectory())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = OCDocumentHolder(frame: NSRect(x: 0, y: 0, width: 300, height: 5000))
        document.addSubview(OCZZDocBelowDocument(frame: NSRect(x: 0, y: 0, width: 100, height: 100)))
        scroll.documentView = document
        rig.layout.addSubview(scroll)
        settle(rig.window)
        overflowBy43(rig)

        let url = try XCTUnwrap(rig.layout.captureOverflowIfNeeded(now: t0))
        let tree = try XCTUnwrap(try readReport(url)["tree"] as? [String: Any])
        let classes = flatten(tree).compactMap { $0["class"] as? String }
        XCTAssertTrue(classes.contains { $0.contains("OCDocumentHolder") }, "the document view itself is recorded")
        XCTAssertFalse(classes.contains { $0.contains("OCZZDocBelowDocument") }, "nothing below the document view is recorded")
    }

    // MARK: - Automatic hook

    /// `layout()` schedules a capture on its own, a moment later, if the overflow is still there.
    func testALayoutPassWithAPersistentOverflowWritesExactlyOneCaptureOnItsOwn() throws {
        let dir = freshDirectory()
        let rig = makeRig(index: 51, make: { PinnedLayout(windowIndex: $0, displayUUID: $1) })
        let pinned = try XCTUnwrap(rig.layout as? PinnedLayout)
        rig.layout.overflowCaptureDirectory = dir
        rig.layout.overflowCaptureDelay = 0

        let content = contentSize(of: rig.window)
        let enlarged = NSSize(width: content.width, height: content.height + 43)
        pinned.pinnedSize = enlarged
        rig.layout.setFrameSize(enlarged)
        XCTAssertEqual(rig.layout.contentOverflow, CGSize(width: 0, height: 43))

        rig.layout.needsLayout = true
        rig.layout.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(3)
        while captureNames(in: dir).isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        // More layout passes and run-loop turns must not add a second file (rate limit).
        for _ in 0..<5 {
            rig.layout.needsLayout = true
            rig.layout.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let names = captureNames(in: dir)
        XCTAssertEqual(names.count, 1, "exactly one automatic capture: \(names)")
        XCTAssertTrue(names.first?.hasPrefix("layout-overflow-51-") == true)
        XCTAssertNotNil(rig.layout.latestOverflowCapturePath)
    }
}
