import XCTest
import AppKit
import NostromoKit

// MV-5: the other two ways the Mother pane can ask for more height than the window has.
//
// (a) The Overview tab and the job list beside it: a very large number of jobs with long titles, repos
//     and questions, delivered the way the app delivers them (a broker snapshot into `AppStore`, which the
//     real `MotherView` listens to). The Overview tab itself is a fixed "Select a job" label; the data-driven
//     part is the job list and the counts strip, which is what is exercised here.
// (b) A job whose crew data makes a tall crew panel (40 long-named gates, 25 lens rows, a hold with options
//     and 2,000-character consequences and question, long meta, a 200-item plan), opened through the REAL
//     path: the snapshot, then `MotherView.requestedJobId`, so `MotherView` itself builds the detail with
//     `AppStore` as its host. The panel's height is `MotherCrewPanelModel.height`, a fixed function of
//     its rows, which is taller than the whole window here.
//
// The job in (b) is `failed`, not `awaiting`: a hold shows for any job with an open decision, and a
// finished job needs nobody, so the shared `AppStore` raises no needs-you notification for it.
final class MotherOverviewAndCrewOverflowTests: XCTestCase {

    private func resetStoreWhenDone() {
        addTeardownBlock {
            MotherView.requestedJobId = nil
            AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        }
    }

    private func overviewJobs(count: Int, titleOf: (Int) -> String) -> [MotherJob] {
        let states = ["running", "queued", "failed", "succeeded"]
        return (0..<count).map { n in
            MotherJob(id: "ov-\(n)", state: states[n % states.count],
                      repo: titleOf(n), isolation: "worktree", title: titleOf(n),
                      createdAt: Date(), startedAt: Date(), finishedAt: nil, planPath: nil,
                      question: n % 5 == 0 ? titleOf(n) : nil,
                      pausedReason: nil, adherenceStatus: nil, currentTier: nil)
        }
    }

    // MARK: - (a) Overview and job list

    func testTheOverviewFitsTheWindowWithHundredsOfJobsWithLongTitles() throws {
        let w = try MD.makeWindow(self, index: 980)
        resetStoreWhenDone()
        XCTAssertEqual(w.pane.activePaneId, MotherView.overviewPaneId, "precondition: the Overview tab is showing")
        MD.assertFits(w, "control: Overview with no jobs")

        AppStore.shared.applyBrokerEventForTesting(.snapshot(
            overviewJobs(count: 600) { MDText.prose("JOB-\($0)", chars: 600) }))
        MD.pump(w.window, seconds: 1)

        XCTAssertEqual(AppStore.shared.motherJobs.count, 600, "precondition: the app holds the 600 jobs")
        XCTAssertEqual(w.pane.activePaneId, MotherView.overviewPaneId, "precondition: still on the Overview tab")
        MD.assertFits(w, "Overview, 600 jobs with 600-character titles")
    }

    func testTheOverviewFitsTheWindowWithJobTitlesThatHaveNoSpacesToWrapAt() throws {
        let w = try MD.makeWindow(self, index: 981)
        resetStoreWhenDone()

        AppStore.shared.applyBrokerEventForTesting(.snapshot(
            overviewJobs(count: 300) { "JOB-\($0)-" + String(repeating: "x", count: 3_000) }))
        MD.pump(w.window, seconds: 1)

        XCTAssertEqual(AppStore.shared.motherJobs.count, 300, "precondition: the app holds the 300 jobs")
        MD.assertFits(w, "Overview, 300 jobs with 3000-character unbroken titles")
    }

    func testTheOverviewKeepsFittingAsTheJobListGrowsAndShrinks() throws {
        let w = try MD.makeWindow(self, index: 982)
        resetStoreWhenDone()
        for count in [1, 40, 800, 3, 0] {
            AppStore.shared.applyBrokerEventForTesting(.snapshot(
                overviewJobs(count: count) { MDText.prose("JOB-\($0)", chars: 300) }))
            MD.pump(w.window, seconds: 0.6)
            XCTAssertEqual(AppStore.shared.motherJobs.count, count, "precondition: the app holds \(count) jobs")
            MD.assertFits(w, "Overview, \(count) jobs")
        }
    }

    // MARK: - (b) A tall crew panel in a job opened through MotherView

    private func openHeavyJobThroughMotherView(_ w: MDWindow, id: String, others: [MotherJob] = []) throws -> MotherJobDetail {
        let dir = try MD.makeTemp(self)
        let plan = dir.appendingPathComponent("plan.md")
        try MDFixtures.planText(items: 200, long: true, version: 0).write(to: plan, atomically: true, encoding: .utf8)

        let heavy = MDFixtures.job(id: id, long: [.gates, .lenses, .consequences, .question, .meta, .title],
                                   state: "failed", planPath: plan.path)
        resetStoreWhenDone()
        MotherView.requestedJobId = id
        AppStore.shared.applyBrokerEventForTesting(.snapshot([heavy] + others))

        let paneId = MotherView.tabPaneId(for: id)
        let opened = MD.pumpUntil(w.window) { w.pane.hasTab(paneId) }
        XCTAssertTrue(opened, "precondition: MotherView opened the job's tab")
        let detail = try XCTUnwrap(MD.allSubviews(w.motherView).compactMap { $0 as? MotherJobDetail }.first,
                                   "precondition: MotherView built a job detail")
        addTeardownBlock { detail.select(nil) }   // stops its log timer

        let planShown = MD.pumpUntil(w.window) {
            MD.allSubviews(detail).filter { ($0 as? NSTextField)?.stringValue.hasPrefix("PLAN-") == true }.count == 200
        }
        XCTAssertTrue(planShown, "precondition: the plan checklist rendered")
        MD.pump(w.window)
        return detail
    }

    func testAJobWithATallCrewPanelOpenedThroughTheMotherViewFitsTheWindow() throws {
        let w = try MD.makeWindow(self, index: 983)
        let detail = try openHeavyJobThroughMotherView(w, id: "crew-heavy")

        XCTAssertEqual(w.pane.activePaneId, MotherView.tabPaneId(for: "crew-heavy"), "precondition: the job tab is frontmost")
        XCTAssertGreaterThan(detail.crewSection.expectedHeight, w.contentSize.height,
                             "precondition: the crew panel alone is taller than the window")
        MD.assertFits(w, detail: detail, "tall crew panel, opened through MotherView")
    }

    func testATallCrewPanelStillFitsWhileHundredsOfLongJobsAreListed() throws {
        let w = try MD.makeWindow(self, index: 984)
        let others = overviewJobs(count: 300) { MDText.prose("JOB-\($0)", chars: 400) }
        let detail = try openHeavyJobThroughMotherView(w, id: "crew-heavy-2", others: others)
        MD.pump(w.window, seconds: 0.6)

        XCTAssertEqual(AppStore.shared.motherJobs.count, 301, "precondition: the app holds the 301 jobs")
        MD.assertFits(w, detail: detail, "tall crew panel with 300 other jobs listed")
    }

    func testATallCrewPanelFollowsTheJobsStateChangesWithoutOverflowing() throws {
        let w = try MD.makeWindow(self, index: 985)
        let detail = try openHeavyJobThroughMotherView(w, id: "crew-heavy-3")

        // The same job refreshed by the broker (a later snapshot with a different state and more gates).
        let dir = try MD.makeTemp(self)
        let plan = dir.appendingPathComponent("plan.md")
        try MDFixtures.planText(items: 200, long: true, version: 0).write(to: plan, atomically: true, encoding: .utf8)
        for (state, gates) in [("cancelled", 60), ("failed", 5), ("succeeded", 80)] {
            let job = MDFixtures.job(id: "crew-heavy-3", long: [.gates, .lenses, .consequences, .question, .meta, .title],
                                     state: state, planPath: plan.path, gateCount: gates)
            AppStore.shared.applyBrokerEventForTesting(.snapshot([job]))
            MD.pump(w.window, seconds: 0.6)
            MD.assertFits(w, detail: detail, "crew panel, job \(state) with \(gates) gates")
        }
    }
}
