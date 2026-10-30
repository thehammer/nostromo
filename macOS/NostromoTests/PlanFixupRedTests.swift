import XCTest
import AppKit
import NostromoKit

// MF4 fix-up: three behaviours of the plan viewer that the first cut got wrong.
//
//   - A plan item's text is untrusted: the Overview checklist shows it with the same characters
//     removed as everywhere else (bidi controls, zero-width and blank fillers, escape sequences).
//   - A plan file that is not there yet (or is deleted and comes back) is picked up when it appears:
//     the loader keeps trying after `.notFound`, on the injected scheduler.
//   - The Overview checklist follows the file on disk, like the Plan view does, without the job
//     changing and without anyone calling `update`.
//
// Waits are conditions pumped on the main run loop (the timeout is only the failure bound); the
// loader's debounce is the `ManualPlanReloadScheduler`, fired by hand. The checklist and the plan view
// of a detail use the real debounce (0.3 s), so those waits are bounded at 10 s, never fixed sleeps.

final class PlanFixupRedTests: XCTestCase {

    // MARK: - A detail on its own (stub host, private log directory)

    private func makeDetail() throws -> (detail: MotherJobDetail, dir: URL) {
        let dir = try PlanTestSupport.tempDirectory(self)
        let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir, frame: NSRect(x: 0, y: 0, width: 800, height: 900))
        addTeardownBlock { detail.select(nil) }
        return (detail, dir)
    }

    private func job(plan: String) -> MotherJob {
        MDFixtures.job(id: "j-plan", long: [], state: "succeeded", planPath: plan, bare: true)
    }

    /// The rows of the Overview's plan checklist, nil while there is none.
    private func checklistRows(_ detail: MotherJobDetail) -> [NSView]? {
        guard let list = MD.allSubviews(detail).first(where: { NSStringFromClass(type(of: $0)).contains("PlanChecklistView") }),
              let stack = list.subviews.compactMap({ $0 as? NSStackView }).first
        else { return nil }
        return stack.arrangedSubviews
    }

    /// The label of each checklist row (the row's text, not its done/open icon).
    private func checklistLabels(_ detail: MotherJobDetail) -> [String] {
        (checklistRows(detail) ?? []).compactMap { row in
            let fields = MD.allSubviews(row).compactMap { $0 as? NSTextField }.map(\.stringValue)
            return fields.first { $0 != "○" && $0 != "✓" }
        }
    }

    private func waitForRowCount(_ count: Int, _ detail: MotherJobDetail, timeout: TimeInterval = 10,
                                 _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil(timeout: timeout) { self.checklistRows(detail)?.count == count }
        XCTAssertTrue(ok, "\(what): expected \(count) checklist rows, saw \(String(describing: checklistRows(detail)?.count))",
                      file: file, line: line)
    }

    private func waitForPlan(_ detail: MotherJobDetail, file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil { detail.planView?.state == .document }
        XCTAssertTrue(ok, "the plan never rendered; state is \(String(describing: detail.planView?.state))", file: file, line: line)
    }

    // MARK: - 3. The checklist shows an item's text with the unsafe characters removed

    func testTheOverviewChecklistShowsAnItemWithBidiInvisibleAndEscapeCharactersRemoved() throws {
        let (detail, dir) = try makeDetail()
        let url = dir.appendingPathComponent("plan.md")
        let hostile = "run\u{202E}evil\u{200B}\u{3164}\u{2800}x\u{1B}[31mred\u{1B}[0m"
        try PlanTestSupport.writeInPlace("- [ ] plain item\n- [ ] \(hostile)\n", to: url)

        detail.select(job(plan: url.path))
        waitForRowCount(2, detail, "the plan's two items")

        let labels = checklistLabels(detail)
        XCTAssertEqual(labels, ["plain item", "runevilxred"])
        for label in labels {
            for scalar in ["\u{202E}", "\u{200B}", "\u{3164}", "\u{2800}", "\u{1B}"] {
                XCTAssertFalse(label.contains(scalar), "'\(label)' still holds U+\(String(scalar.unicodeScalars.first!.value, radix: 16, uppercase: true))")
            }
        }
    }

    // MARK: - 5. The loader keeps trying after the file was not there

    private final class Probe {
        let scheduler = ManualPlanReloadScheduler()
        let loader: PlanFileLoader
        private(set) var results: [PlanFileResult] = []

        init() {
            loader = PlanFileLoader(scheduler: scheduler)
            loader.onResult = { [weak self] in self?.results.append($0) }
        }

        var texts: [String] {
            results.compactMap { if case .loaded(let text, _, _) = $0 { return text } else { return nil } }
        }
    }

    /// Fires the scheduler and pumps the main run loop, over and over, until `condition` holds (true) or
    /// `timeout` passes (false). However the loader is built to notice a file (an event, a retry), a
    /// scheduler that is fired has what it needs to react, and a loader that scheduled nothing cannot.
    private func fireUntil(_ probe: Probe, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            probe.scheduler.fire()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if condition() { return true }
        }
        return condition()
    }

    func testAPlanFileThatAppearsAfterNotFoundIsLoadedAndWatched() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        let probe = Probe()
        probe.loader.load(path: url.path)
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.results.contains(.notFound) }, "the missing file was never reported")

        try PlanTestSupport.writeInPlace("# It came\n", to: url)

        XCTAssertTrue(fireUntil(probe) { probe.texts.last == "# It came\n" },
                      "the file appeared but was never loaded; results: \(probe.results)")
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.loader.isWatching }, "the loader watches the file once it is loaded")
    }

    func testAPlanFileThatIsDeletedAndComesBackIsLoadedAgainAndWatched() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try PlanTestSupport.writeInPlace("first\n", to: url)
        let probe = Probe()
        probe.loader.load(path: url.path)
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.texts == ["first\n"] })
        XCTAssertTrue(probe.loader.isWatching)

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.loader.hasPendingReload }, "the deletion was never noticed")
        probe.scheduler.fire()
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.results.last == .notFound }, "the reload of a deleted file reports notFound")

        try PlanTestSupport.writeInPlace("second\n", to: url)

        XCTAssertTrue(fireUntil(probe) { probe.texts.last == "second\n" },
                      "the file came back but was never loaded; results: \(probe.results)")
        XCTAssertTrue(PlanTestSupport.pumpUntil { probe.loader.isWatching }, "the watch is armed on the new file")
    }

    // MARK: - 8. The Overview checklist follows the file

    private func twoItemPlan(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("a.md")
        try PlanTestSupport.writeInPlace("- [ ] first\n- [x] second\n", to: url)
        return url
    }

    private static let threeItems = "- [ ] first\n- [x] second\n- [ ] third\n"

    func testTheOverviewChecklistFollowsAnInPlaceEditOfItsFileWithoutAnyUpdate() throws {
        let (detail, dir) = try makeDetail()
        let url = try twoItemPlan(in: dir)
        detail.select(job(plan: url.path))
        waitForRowCount(2, detail, "the plan's two items")

        try PlanTestSupport.writeInPlace(Self.threeItems, to: url)

        waitForRowCount(3, detail, "after the file was edited in place")
        XCTAssertEqual(checklistLabels(detail), ["first", "second", "third"])
    }

    func testTheOverviewChecklistFollowsAnAtomicReplacementOfItsFileWithoutAnyUpdate() throws {
        let (detail, dir) = try makeDetail()
        let url = try twoItemPlan(in: dir)
        detail.select(job(plan: url.path))
        waitForRowCount(2, detail, "the plan's two items")

        try PlanTestSupport.writeAtomically(Self.threeItems, to: url)

        waitForRowCount(3, detail, "after the file was replaced")
        XCTAssertEqual(checklistLabels(detail), ["first", "second", "third"])
    }

    func testTheOverviewChecklistAgreesWithThePlanViewAfterTheFileChangedWhileThePlanWasShowing() throws {
        let (detail, dir) = try makeDetail()
        let url = try twoItemPlan(in: dir)
        detail.select(job(plan: url.path))
        waitForRowCount(2, detail, "the plan's two items")

        detail.selectSegment(.plan)
        waitForPlan(detail)
        let planView = try XCTUnwrap(detail.planView)
        XCTAssertEqual(planView.criteriaText, "✓ 1/2 criteria")

        try PlanTestSupport.writeInPlace(Self.threeItems, to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil(timeout: 10) { planView.criteriaText == "✓ 1/3 criteria" },
                      "the plan view never followed the edit; it says \(String(describing: planView.criteriaText))")

        detail.selectSegment(.overview)

        waitForRowCount(3, detail, "back on the Overview after the edit")
        let total = planView.criteriaText?
            .split(separator: " ").dropFirst().first?
            .split(separator: "/").last.flatMap { Int($0) }
        XCTAssertEqual(checklistRows(detail)?.count, total, "the checklist and the plan's criteria count are the same number")
    }
}
