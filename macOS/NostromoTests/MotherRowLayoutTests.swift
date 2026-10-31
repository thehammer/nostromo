import XCTest
import AppKit
import SwiftUI
import NostromoKit

// MotherJobListViewModel, MotherJobListSwiftUI and MotherJob are compiled into this target directly.
//
// MF5: every condensed Mother job row is two lines and exactly one height.
//
//   - A row's height is MotherRowMetrics.rowHeight whatever the state, the progress, the badges, the
//     title, the origin or the column width (220 to 700 pt).
//   - Twelve jobs in two groups fit a 280 x 600 list column without scrolling.
//   - The row's age text is `12m` / `4m ago` / `2h ago` / `3d`, from an injected clock.
//   - A PR number is read from a PR URL.

final class MotherRowLayoutTests: XCTestCase {

    // MARK: - Helpers

    private let widths: [CGFloat] = [220, 259, 260, 339, 340, 700]

    // Hostile strings, copied from NostromoKit's HostileContent (which the Mac target cannot see).
    private let hostile: [String] = [
        "echo " + String(repeating: "x", count: 4_000),
        "\u{1B}[31mred text\u{1B}[0m and \u{1B}[1;32mgreen\u{1B}[0m",
        "safe\u{202E}evil\u{2066}iso\u{2067}rtl\u{2068}fsi\u{2069}\u{200E}\u{200F}tail",
        "one\ntwo\r\nthree\tfour\u{7F}five",
        "before\u{0}after",
        String(repeating: "W", count: 300),
        "a\u{034F}b\u{115F}c\u{1160}d\u{2800}e",
    ]

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeStore() throws -> FocusStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mother-row-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
    }

    private func origin(_ name: String) -> MotherOriginDisplay {
        MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: .focus, focusTag: "claudia-ABCDEF12", nameSnapshot: name, focusName: nil)),
            currentName: { _ in nil })
    }

    private func model(
        state: String, title: String = "Fix the login flow", origin: MotherOriginDisplay? = nil,
        question: String? = nil, progress: String? = nil, badges: [String] = [],
        pr: Int? = nil, reason: String? = nil, cost: String? = nil
    ) -> MotherJobRowModel {
        MotherJobRowModel(
            id: "job-1", state: state, title: title, repo: "nostromo", question: question,
            relativeTimestamp: "12m", progressLine: progress, attentionBadges: badges,
            showsProgressLine: true, origin: origin ?? .unknown,
            prNumber: pr, failureReason: reason, cost: cost)
    }

    /// The hosted condensed row's own height at `width`.
    private func height(_ m: MotherJobRowModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView:
            NostromoKit.MotherJobRow(model: m, style: .condensed).frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private var statesWithBadges: [MotherJobRowModel] {
        [
            model(state: "running", progress: "≈60% · gates 2/3 · ETA ~5-15 min", badges: ["Stalled"], cost: "$2.14"),
            model(state: "awaiting", question: "Which branch should I target?", badges: ["Needs decision", "Burning"]),
            model(state: "succeeded", pr: 907, cost: "$2.14"),
            model(state: "failed", reason: "gate 2 failed: tests", cost: "$1.00"),
            model(state: "cancelled"),
        ]
    }

    // MARK: - One height

    func testARowIsExactlyTheMetricsHeightForEveryStateAtEveryWidth() {
        for m in statesWithBadges {
            for w in widths {
                XCTAssertEqual(height(m, width: w), MotherRowMetrics.rowHeight, accuracy: 0.5,
                               "\(m.state) @\(w)")
            }
        }
    }

    func testBadgesDoNotChangeARowsHeight() {
        for state in ["running", "awaiting", "succeeded", "failed", "cancelled"] {
            for w in widths {
                let plain = height(model(state: state), width: w)
                let flagged = height(model(state: state, badges: ["Needs decision", "Stalled", "Burning"]), width: w)
                XCTAssertEqual(flagged, plain, accuracy: 0.5, "\(state) @\(w)")
            }
        }
    }

    func testProgressDoesNotChangeARowsHeight() {
        for w in widths {
            let heights = stride(from: 5, through: 95, by: 10).map { pct in
                height(model(state: "running", progress: "≈\(pct)% · gates 1/3 · ETA ~5-15 min"), width: w)
            }
            let first = heights[0]
            for (i, h) in heights.enumerated() {
                XCTAssertEqual(h, first, accuracy: 0.5, "progress step \(i) @\(w)")
            }
            XCTAssertEqual(first, MotherRowMetrics.rowHeight, accuracy: 0.5, "@\(w)")
        }
    }

    func testHostileTitlesAndOriginsKeepTheSameHeight() {
        for text in hostile {
            for w in widths {
                let m = model(state: "awaiting", title: text, origin: origin(text), question: text,
                              badges: [text], pr: nil, reason: text)
                XCTAssertEqual(height(m, width: w), MotherRowMetrics.rowHeight, accuracy: 0.5,
                               "hostile text \(text.prefix(12).debugDescription) @\(w)")
                let failed = model(state: "failed", title: text, origin: origin(text), reason: text)
                XCTAssertEqual(height(failed, width: w), MotherRowMetrics.rowHeight, accuracy: 0.5,
                               "hostile failure \(text.prefix(12).debugDescription) @\(w)")
            }
        }
    }

    func testAnEmptyTitleStillGetsTheSameHeight() {
        for w in widths {
            XCTAssertEqual(height(model(state: "queued", title: ""), width: w), MotherRowMetrics.rowHeight, accuracy: 0.5)
        }
    }

    // MARK: - A list of rows

    private func job(_ i: Int, state: String) -> MotherJob {
        MotherJob(id: "job-\(i)", state: state, repo: "nostromo", isolation: "worktree",
                  title: "Job number \(i) with a title that is rather long for a narrow column",
                  createdAt: Date(timeIntervalSince1970: 1_000), startedAt: Date(timeIntervalSince1970: 2_000),
                  finishedAt: nil, planPath: nil, question: nil, pausedReason: nil,
                  adherenceStatus: nil, currentTier: nil)
    }

    private func tableViews(in view: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTableView { found.append(t) }
            for s in v.subviews { walk(s) }
        }
        walk(view)
        return found
    }

    func testTwelveJobsInTwoGroupsFitA280By600ColumnWithoutScrolling() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        vm.jobs = (0..<6).map { job($0, state: "running") } + (6..<12).map { job($0, state: "queued") }

        let host = NSHostingView(rootView: MotherJobListSwiftUI(vm: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: .distantPast)
        }
        host.layoutSubtreeIfNeeded()

        let table = try XCTUnwrap(tableViews(in: host).first, "the list has an NSTableView")
        XCTAssertGreaterThanOrEqual(table.numberOfRows, 12, "twelve jobs (plus their group headers) are rows")
        let content = table.rect(ofRow: table.numberOfRows - 1).maxY
        XCTAssertLessThanOrEqual(content, 600, "twelve two-line rows and two headers fit 600 pt")
    }

    // MARK: - The row's age

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func aged(_ state: String, startedAgo: TimeInterval? = nil, finishedAgo: TimeInterval? = nil) -> MotherJob {
        MotherJob(id: "j", state: state, repo: "nostromo", isolation: "worktree", title: "t",
                  createdAt: now.addingTimeInterval(-9_999_999),
                  startedAt: startedAgo.map { now.addingTimeInterval(-$0) },
                  finishedAt: finishedAgo.map { now.addingTimeInterval(-$0) },
                  planPath: nil, question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    func testARunningJobShowsHowLongItHasRun() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        XCTAssertEqual(vm.rowModel(for: aged("running", startedAgo: 12 * 60), now: now).relativeTimestamp, "12m")
        XCTAssertEqual(vm.rowModel(for: aged("running", startedAgo: 45), now: now).relativeTimestamp, "45s")
        XCTAssertEqual(vm.rowModel(for: aged("running", startedAgo: 2 * 3600 + 5 * 60), now: now).relativeTimestamp, "2h5m")
        XCTAssertEqual(vm.rowModel(for: aged("running", startedAgo: 3 * 86_400), now: now).relativeTimestamp, "3d")
    }

    func testAFinishedJobShowsHowLongAgoItMoved() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        XCTAssertEqual(vm.rowModel(for: aged("succeeded", startedAgo: 9_000, finishedAgo: 4 * 60), now: now).relativeTimestamp, "4m ago")
        XCTAssertEqual(vm.rowModel(for: aged("failed", startedAgo: 90_000, finishedAgo: 2 * 3600), now: now).relativeTimestamp, "2h ago")
        XCTAssertEqual(vm.rowModel(for: aged("cancelled", startedAgo: 900_000, finishedAgo: 3 * 86_400), now: now).relativeTimestamp, "3d")
    }

    func testAnAgeNeverGoesNegativeWhenAJobStartsInTheFuture() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        // A start in the future (clock skew) reads as zero, not a negative number.
        XCTAssertEqual(vm.rowModel(for: aged("running", startedAgo: -30), now: now).relativeTimestamp, "0s")
    }

    // MARK: - Line-two fields from a job

    func testARowModelCarriesThePullRequestNumberFailureReasonAndCost() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        var j = aged("failed", startedAgo: 600, finishedAgo: 60)
        j.crew.prUrl = "https://github.com/Carefeed/nostromo/pull/907"
        j.failureReason = "gate 2 failed"
        j.costUsd = 2.14159
        let m = vm.rowModel(for: j, now: now)
        XCTAssertEqual(m.prNumber, 907)
        XCTAssertEqual(m.failureReason, "gate 2 failed")
        XCTAssertEqual(m.cost, "$2.14")
    }

    func testARowModelForAPlainJobHasNoLineTwoExtras() throws {
        let vm = MotherJobListViewModel(focusStore: try makeStore())
        let m = vm.rowModel(for: aged("queued"), now: now)
        XCTAssertNil(m.prNumber)
        XCTAssertNil(m.failureReason)
        XCTAssertNil(m.cost)
    }

    func testAPullRequestNumberIsReadFromItsUrl() {
        XCTAssertEqual(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/pull/907"), 907)
        XCTAssertEqual(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/pull/12/files"), 12)
        XCTAssertEqual(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/pull/5?diff=split"), 5)
        XCTAssertNil(MotherJobListViewModel.prNumber(fromURL: nil))
        XCTAssertNil(MotherJobListViewModel.prNumber(fromURL: ""))
        XCTAssertNil(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/issues/7"))
        XCTAssertNil(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/pull/"))
        XCTAssertNil(MotherJobListViewModel.prNumber(fromURL: "https://github.com/org/repo/pull/abc"))
    }
}
