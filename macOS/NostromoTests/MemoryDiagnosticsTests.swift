import XCTest
import AppKit

// The two places a person (or a script) reads memory evidence from after the fact:
//
//   1. The pane-blank capture (`PaneRenderWatch`, "Capture render state now" and the automatic
//      blank capture) gains a top-level `memory` object: the `MemorySummary` JSON form.
//   2. `TranscriptDiagnostics.Report` (Debug > Copy transcript diagnostics, and the
//      `NOSTROMO_DIAG_INTERVAL` stream) gains the malloc figures and the top memory categories
//      beside the footprint it already carried.
//
// The incident these answer: the app sat at 1.8 GB for hours and nothing the app could write down
// said where the memory was. A capture taken at the moment of a blank, or a diagnostics line taken
// every minute, must now carry that without anybody running `heap` by hand.
//
// Both stay content-free: numbers and fixed names only, nothing a user or the OS named.
//
// Part 1 drives a REAL `ReplView` in an offscreen window (the same rig `PaneBlankDetectorTests`
// uses) and reads the capture file back as JSON. Part 2 reads `snapshot()` and `reportJSON()`.
final class MemoryDiagnosticsTests: XCTestCase {

    // MARK: - Part 1: the pane-blank capture

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private struct Pane {
        let repl: ReplView
        let window: NSWindow
        let tag: String
        let dir: URL
        var watch: PaneRenderWatch { repl.renderWatch }
    }

    private var client: NostromodClient { AppStore.shared.client }

    private func tempDirectory() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("memory-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func wall(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    /// A real transcript pane in an offscreen (alpha 0) window. Captures go to a fresh temp
    /// directory, and "is on screen" is forced true, because offscreen occlusion is unreliable.
    private func makePane(size: NSSize = NSSize(width: 900, height: 700)) -> Pane {
        let tag = "mdt-\(UUID().uuidString)"
        let dir = tempDirectory()
        let repl = ReplView(tag: tag)
        repl.renderWatch.captureDirectory = dir
        repl.renderWatch.visibilityOverride = true

        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        repl.frame = NSRect(origin: .zero, size: size)
        repl.autoresizingMask = [.width, .height]
        window.contentView = repl
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            repl.renderWatch.visibilityOverride = false
            window.orderOut(nil)
            window.contentView = nil
        }
        settle(window)
        return Pane(repl: repl, window: window, tag: tag, dir: dir)
    }

    private func settle(_ window: NSWindow) {
        for _ in 0 ..< 4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    private func pump(_ pane: Pane, _ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        pane.window.contentView?.layoutSubtreeIfNeeded()
        pane.window.displayIfNeeded()
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

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let prose = "The transcript keeps a long paragraph of ordinary words so that each turn is tall enough to matter. "

    private func turn(_ i: Int) -> DaemonTurn {
        DaemonTurn(id: "turn-\(i)",
                   userInput: "question number \(i)",
                   timestamp: Self.iso.string(from: Self.base.addingTimeInterval(Double(i))),
                   blocks: [.text(String(repeating: Self.prose, count: 6))],
                   isComplete: true)
    }

    private func makeMaterializedPane(turns count: Int = 12) -> Pane {
        let pane = makePane()
        client.messages.send(.sessionSpawned(tag: pane.tag, sessionId: "session-\(pane.tag)"))
        client.messages.send(.sessionTurns(tag: pane.tag, turns: (0 ..< count).map { turn($0) }))
        waitUntil {
            self.pump(pane, 0.02)
            return pane.repl.visibleTurnViewCount > 0
        }
        pump(pane)
        return pane
    }

    private func readJSON(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "the capture is not a JSON object", file: file, line: line)
    }

    private static let memoryKeys: Set<String> =
        ["physicalFootprintBytes", "mallocBlocksInUse", "mallocBytesInUse", "categories"]

    /// Every top-level key a capture carried before this change. The new `memory` key is added to
    /// these, never instead of any of them.
    private static let previousTopLevelKeys: Set<String> =
        ["schema", "capturedAtUTC", "trigger", "reason", "rule", "severity", "detail", "suppressedHits",
         "events", "app", "screens", "diagnostics", "pane", "window"]

    private func assertWellFormedMemory(_ json: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let memory = try XCTUnwrap(json["memory"] as? [String: Any],
                                   "the capture has no top-level `memory` object", file: file, line: line)
        XCTAssertEqual(Set(memory.keys), Self.memoryKeys,
                       "`memory` is the MemorySummary JSON form: these four keys, nothing else",
                       file: file, line: line)
        XCTAssertGreaterThan((memory["physicalFootprintBytes"] as? NSNumber)?.intValue ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan((memory["mallocBlocksInUse"] as? NSNumber)?.intValue ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan((memory["mallocBytesInUse"] as? NSNumber)?.intValue ?? 0, 0, file: file, line: line)

        let categories = try XCTUnwrap(memory["categories"] as? [[String: Any]], file: file, line: line)
        XCTAssertFalse(categories.isEmpty, "a running process has dirty memory", file: file, line: line)
        for category in categories {
            XCTAssertEqual(Set(category.keys), ["name", "dirtyBytes"], file: file, line: line)
            XCTAssertFalse((category["name"] as? String ?? "").isEmpty, file: file, line: line)
            XCTAssertGreaterThan((category["dirtyBytes"] as? NSNumber)?.intValue ?? 0, 0, file: file, line: line)
        }
        let sizes = categories.compactMap { ($0["dirtyBytes"] as? NSNumber)?.intValue }
        XCTAssertEqual(sizes, sizes.sorted(by: >), "largest first", file: file, line: line)
    }

    func testAManualCaptureCarriesTheMemorySummary() throws {
        let pane = makeMaterializedPane()

        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)),
                                "a manual capture always writes")
        let json = try readJSON(url)

        try assertWellFormedMemory(json)
    }

    func testTheMemorySummaryDoesNotReplaceAnyPreviousCaptureKey() throws {
        let pane = makeMaterializedPane()

        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)))
        let json = try readJSON(url)

        let missing = Self.previousTopLevelKeys.subtracting(json.keys)
        XCTAssertTrue(missing.isEmpty, "the capture lost keys it had before: \(missing.sorted())")
        XCTAssertEqual(Set(json.keys), Self.previousTopLevelKeys.union(["memory", "viewRebuilds"]),
                       "`memory` and `viewRebuilds` are the only keys added at the top level")
    }

    /// The blank capture is the reason the summary is there: a pane going blank while the app is
    /// huge is exactly the case where "where is the memory" matters. An automatic capture, written
    /// when the detector fires, carries it too.
    func testAnAutomaticBlankCaptureCarriesTheMemorySummaryToo() throws {
        let pane = makeMaterializedPane()
        pane.repl.evictAllTurnViewsForTesting()

        let t = PaneRenderWatch.monotonicMs()
        XCTAssertTrue(pane.watch.evaluate(nowMs: t, wall: wall(0)).isEmpty)
        XCTAssertTrue(pane.watch.evaluate(nowMs: t + 150, wall: wall(0)).isEmpty)
        let hits = pane.watch.evaluate(nowMs: t + 350, wall: wall(1))
        XCTAssertEqual(hits.map(\.rule), [.emptyViewport], "precondition: the simulated blank was detected")

        let url = try XCTUnwrap(pane.watch.lastCaptureURL, "the blank wrote a capture")
        let json = try readJSON(url)
        XCTAssertEqual(json["trigger"] as? String, "auto")
        try assertWellFormedMemory(json)
    }

    /// Content-free: nothing in `memory` but numbers and the category names.
    func testTheMemoryObjectHoldsNoStringsExceptCategoryNames() throws {
        let pane = makeMaterializedPane()
        let url = try XCTUnwrap(pane.watch.captureNow(nowMs: PaneRenderWatch.monotonicMs(), wall: wall(0)))
        let memory = try XCTUnwrap(try readJSON(url)["memory"] as? [String: Any])

        for (key, value) in memory where key != "categories" {
            XCTAssertTrue(value is NSNumber, "\(key) must be a number, got \(type(of: value))")
        }
        for category in try XCTUnwrap(memory["categories"] as? [[String: Any]]) {
            XCTAssertTrue(category["dirtyBytes"] is NSNumber)
            let name = try XCTUnwrap(category["name"] as? String)
            XCTAssertFalse(name.contains("/"), "a path must never reach a capture: '\(name)'")
            XCTAssertLessThan(name.count, 40)
        }
    }

    // MARK: - Part 2: TranscriptDiagnostics.Report

    func testTheDiagnosticsSnapshotCarriesTheMallocFiguresAndTheTopMemoryCategories() {
        let report = TranscriptDiagnostics.snapshot()

        XCTAssertGreaterThan(report.physFootprintBytes, 0, "the existing footprint field is still filled")
        XCTAssertGreaterThan(report.mallocBlocksInUse, 0)
        XCTAssertGreaterThan(report.mallocBytesInUse, 0)
        XCTAssertFalse(report.topMemoryCategories.isEmpty, "a running process has dirty memory")
        XCTAssertTrue(report.topMemoryCategories.allSatisfy { $0.dirtyBytes > 0 })
        XCTAssertTrue(report.topMemoryCategories.allSatisfy { !$0.name.isEmpty })
        let sizes = report.topMemoryCategories.map(\.dirtyBytes)
        XCTAssertEqual(sizes, sizes.sorted(by: >), "largest first")
    }

    func testTheDiagnosticsJSONContainsTheNewKeysBesideTheOldOnes() throws {
        let text = TranscriptDiagnostics.reportJSON()
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let json = try XCTUnwrap(object as? [String: Any], "reportJSON() must be a JSON object, got: \(text.prefix(80))")

        // Kept.
        for key in ["physFootprintBytes", "physFootprintMB", "maxMaterializedPerPane", "panes", "runID", "pid"] {
            XCTAssertNotNil(json[key], "reportJSON() lost `\(key)`")
        }
        // Added.
        XCTAssertGreaterThan((json["mallocBlocksInUse"] as? NSNumber)?.intValue ?? 0, 0)
        XCTAssertGreaterThan((json["mallocBytesInUse"] as? NSNumber)?.intValue ?? 0, 0)
        let categories = try XCTUnwrap(json["topMemoryCategories"] as? [[String: Any]],
                                       "reportJSON() has no `topMemoryCategories` array")
        XCTAssertFalse(categories.isEmpty)
        for category in categories {
            XCTAssertEqual(Set(category.keys), ["name", "dirtyBytes"])
            XCTAssertGreaterThan((category["dirtyBytes"] as? NSNumber)?.intValue ?? 0, 0)
        }
    }

    /// The JSONL stream line is what `transcript-load-report.py` reads: one `snapshot()` per
    /// interval, encoded compactly. The new fields must survive that encoding as well.
    func testTheDiagnosticsStreamEncodingCarriesTheNewKeys() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(TranscriptDiagnostics.snapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["mallocBlocksInUse"])
        XCTAssertNotNil(json["mallocBytesInUse"])
        XCTAssertNotNil(json["topMemoryCategories"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\n"), "a stream line is one line")
    }

    func testAMemoryCategoryRoundTripsThroughJSON() throws {
        let category = TranscriptDiagnostics.MemoryCategory(name: "Malloc Small", dirtyBytes: 1_759_000_000)

        let data = try JSONEncoder().encode(category)
        let decoded = try JSONDecoder().decode(TranscriptDiagnostics.MemoryCategory.self, from: data)

        XCTAssertEqual(decoded, category)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["name", "dirtyBytes"])
    }
}
