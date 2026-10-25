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
//     and 2,000-character consequences and question, long meta, a 200-item plan), shown as a tab of the
//     Mother pane through the shared rig. The panel's height is `MotherCrewPanelModel.height`, a fixed
//     function of its rows, which is taller than the whole window here. (Opening the tab through
//     `MotherView.requestedJobId` was tried first: that static is consumed by whichever live MotherView
//     sees the snapshot first, so it is not deterministic in a process that has built other windows.)
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

    // MARK: - (b) A tall crew panel in a job detail of the Mother pane

    private static let heavyFields: Set<MDField> = [.gates, .lenses, .consequences, .question, .meta, .title, .planChecklist]

    func testAJobWithATallCrewPanelFitsTheWindow() throws {
        let rig = try MD.makeRig(self, long: Self.heavyFields, index: 983)

        XCTAssertGreaterThan(rig.detail.crewSection.expectedHeight, rig.w.contentSize.height,
                             "precondition: the crew panel alone is taller than the window")
        MD.assertFits(rig, "tall crew panel")
    }

    func testATallCrewPanelStillFitsWhileHundredsOfLongJobsAreListed() throws {
        let rig = try MD.makeRig(self, long: Self.heavyFields, index: 984)
        resetStoreWhenDone()
        AppStore.shared.applyBrokerEventForTesting(.snapshot(overviewJobs(count: 300) { MDText.prose("JOB-\($0)", chars: 400) }))
        MD.pump(rig.window, seconds: 0.8)

        XCTAssertEqual(AppStore.shared.motherJobs.count, 300, "precondition: the app holds the 300 jobs")
        XCTAssertGreaterThan(rig.detail.crewSection.expectedHeight, rig.w.contentSize.height,
                             "precondition: the crew panel alone is taller than the window")
        MD.assertFits(rig, "tall crew panel with 300 other jobs listed")
    }

    func testATallCrewPanelFollowsTheJobsStateChangesWithoutOverflowing() throws {
        let rig = try MD.makeRig(self, long: Self.heavyFields, index: 985)

        for (state, gates) in [("cancelled", 60), ("failed", 5), ("succeeded", 80), ("awaiting", 40)] {
            rig.state = state
            rig.setGates(gates)
            rig.awaitRendered()
            MD.assertFits(rig, "crew panel, job \(state) with \(gates) gates")
        }
    }
}
