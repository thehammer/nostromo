import XCTest
import AppKit
import NostromoKit

/// The Mother view has no tabs: the job list is the navigation and the right-hand side shows the
/// selected job's detail, or the "Select a job" empty state.
final class MotherViewSelectionTests: XCTestCase {

    private var window: NSWindow!
    private var view: MotherView!
    private var savedCoalescing: TimeInterval = 0
    private var savedMax = 8

    override func setUp() {
        super.setUp()
        savedCoalescing = MotherView.selectionCoalescing
        savedMax = MotherView.maxCachedDetails
        MotherView.selectionCoalescing = 0
        MotherView.requestedJobId = nil
        let suite = UserDefaults(suiteName: "MotherViewSelectionTests.\(UUID().uuidString)")!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        addTeardownBlock { MotherView.widthDefaults = previous }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: true)
        view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
    }

    override func tearDown() {
        MotherView.selectionCoalescing = savedCoalescing
        MotherView.maxCachedDetails = savedMax
        MotherView.requestedJobId = nil
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        window.contentView = nil
        view = nil
        super.tearDown()
    }

    private func job(_ id: String, state: String = "running", title: String? = nil) -> MotherJob {
        MotherJob(id: id, state: state, repo: "nostromo", isolation: "none", title: title ?? "Job \(id)",
                  createdAt: Date(), startedAt: Date(), finishedAt: nil, planPath: nil,
                  question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    private func descendants(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap { descendants(of: $0) } }

    private func publish(_ jobs: [MotherJob]) {
        AppStore.shared.applyBrokerEventForTesting(.snapshot(jobs))
        let deadline = Date().addingTimeInterval(3)
        while AppStore.shared.motherJobs.map(\.id) != jobs.map(\.id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Shape

    func testThereIsNoTabStripInTheMotherView() {
        XCTAssertFalse(descendants(of: view).contains { $0 is TabRegionView })
        view.listDidSelect(job("a"))
        XCTAssertFalse(descendants(of: view).contains { $0 is TabRegionView })
    }

    func testNothingSelectedShowsTheEmptyState() {
        XCTAssertNil(view.selectedJobId)
        XCTAssertNil(view.shownDetail)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), MotherView.emptyAccessibilityLabel)
    }

    // MARK: - Selecting

    func testSelectingAJobThenAnotherReplacesTheDetail() throws {
        let a = job("a"), b = job("b")
        view.listDidSelect(a)
        let detailA = try XCTUnwrap(view.shownDetail)
        XCTAssertTrue(detailA.isDescendant(of: view))
        XCTAssertEqual(detailA.currentJobId, "a")

        view.listDidSelect(b)
        let detailB = try XCTUnwrap(view.shownDetail)
        XCTAssertEqual(detailB.currentJobId, "b")
        XCTAssertTrue(detailB.isDescendant(of: view))
        XCTAssertFalse(detailA.isDescendant(of: view), "A's detail is out of the hierarchy")
        XCTAssertFalse(detailA.isShown)
        XCTAssertTrue(detailB.isShown)
        XCTAssertEqual(view.detailContainer.accessibilityLabel(), "Job detail: Job b")
    }

    func testSelectingTheSelectedJobAgainChangesNothing() throws {
        view.listDidSelect(job("a"))
        let first = try XCTUnwrap(view.shownDetail)
        view.listDidSelect(job("a"))
        XCTAssertTrue(view.shownDetail === first)
        XCTAssertEqual(view.selectedJobId, "a")
        XCTAssertEqual(view.cachedDetailCount, 1)
    }

    func testReselectingAKeepsItsDraftAndSegment() throws {
        view.listDidSelect(job("a"))
        let detailA = try XCTUnwrap(view.shownDetail)
        detailA.replyTextView.string = "half a thought"
        detailA.selectSegment(.log)

        view.listDidSelect(job("b"))
        view.listDidSelect(job("a"))

        XCTAssertTrue(view.shownDetail === detailA, "the same detail comes back")
        XCTAssertEqual(detailA.replyTextView.string, "half a thought")
        XCTAssertEqual(detailA.selectedSegment, .log)
    }

    // MARK: - Hidden details run nothing

    func testAHiddenDetailHasNoLogTimerAndItReturnsWhenShownAgain() throws {
        view.listDidSelect(job("a"))
        let detailA = try XCTUnwrap(view.shownDetail)
        XCTAssertTrue(detailA.isLogTimerRunning, "precondition: a running job's log is live while shown")

        view.listDidSelect(job("b"))
        let detailB = try XCTUnwrap(view.shownDetail)
        XCTAssertFalse(detailA.isLogTimerRunning, "hidden: no timer")
        XCTAssertTrue(detailB.isLogTimerRunning)

        view.listDidSelect(job("a"))
        XCTAssertTrue(detailA.isLogTimerRunning)
        XCTAssertFalse(detailB.isLogTimerRunning)
    }

    func testAnUpdateDoesNotRestartAHiddenDetailsTimer() throws {
        view.listDidSelect(job("a", state: "queued"))
        let detailA = try XCTUnwrap(view.shownDetail)
        view.listDidSelect(job("b", state: "queued"))
        // A starts running while hidden.
        publish([job("a", state: "running"), job("b", state: "queued")])
        XCTAssertFalse(detailA.isLogTimerRunning)
    }

    // MARK: - Cache bound

    func testOnlyTheMostRecentlyViewedDetailsAreKept() {
        MotherView.maxCachedDetails = 2
        for id in ["a", "b", "c", "d"] { view.listDidSelect(job(id)) }
        XCTAssertEqual(view.cachedDetailCount, 2)
        XCTAssertNil(view.cachedDetail(for: "a"))
        XCTAssertNil(view.cachedDetail(for: "b"))
        XCTAssertNotNil(view.cachedDetail(for: "c"))
        XCTAssertNotNil(view.cachedDetail(for: "d"))
    }

    func testADetailWithADraftIsNeverEvicted() throws {
        MotherView.maxCachedDetails = 2
        view.listDidSelect(job("a"))
        let detailA = try XCTUnwrap(view.shownDetail)
        detailA.replyTextView.string = "keep me"
        for id in ["b", "c", "d"] { view.listDidSelect(job(id)) }
        XCTAssertTrue(view.cachedDetail(for: "a") === detailA)
        XCTAssertNil(view.cachedDetail(for: "b"))
    }

    // MARK: - Leaving the queue

    func testAnArchivedSelectedJobKeepsShowingItsEndedDetail() throws {
        publish([job("a"), job("b")])
        view.listDidSelect(job("a"))
        let detailA = try XCTUnwrap(view.shownDetail)

        publish([job("b")])

        XCTAssertEqual(view.selectedJobId, "a", "the reader has not clicked elsewhere: the detail stays")
        XCTAssertTrue(view.shownDetail === detailA)
        XCTAssertTrue(detailA.isDescendant(of: view))
        XCTAssertNil(detailA.currentJob, "it shows the ended (empty) state")
        XCTAssertFalse(detailA.isLogTimerRunning)
    }

    // MARK: - Deep links

    func testADeepLinkSelectsTheJob() throws {
        MotherView.requestedJobId = "b"
        view.openRequestedJob(in: [job("a"), job("b")])
        XCTAssertNil(MotherView.requestedJobId, "consumed")
        XCTAssertEqual(view.selectedJobId, "b")
        XCTAssertEqual(try XCTUnwrap(view.shownDetail).currentJobId, "b")
    }

    func testADeepLinkToAJobNotInTheListWaits() {
        MotherView.requestedJobId = "zzz"
        view.openRequestedJob(in: [job("a")])
        XCTAssertEqual(MotherView.requestedJobId, "zzz")
        XCTAssertNil(view.selectedJobId)
    }

    // MARK: - Arrow keys

    func testRapidSelectionChangesBuildOnlyTheLastDetail() {
        MotherView.selectionCoalescing = 0.05
        for id in ["a", "b", "c", "d"] { view.listDidSelect(job(id)) }
        XCTAssertEqual(view.cachedDetailCount, 0, "nothing built while the presses continue")

        let deadline = Date().addingTimeInterval(3)
        while view.selectedJobId == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        XCTAssertEqual(view.selectedJobId, "d")
        XCTAssertEqual(view.cachedDetailCount, 1)
    }
}
