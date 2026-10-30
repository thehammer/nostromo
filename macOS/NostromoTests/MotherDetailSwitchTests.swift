import XCTest
import AppKit
import Combine
import NostromoKit

// R12 / R13 at the level of the Mother job detail: one pane per job with a switch under the title,
// Overview | Plan | Log (Plan only while the job has a plan path).
//
//   - Overview is everything that used to sit above the log tail; Log fills the area under the switch;
//     Plan is the in-pane plan view. Only the segment on show is visible.
//   - The segment is the detail's own (a job tab's): `select` starts at Overview, `update` never moves it.
//   - The Log label carries a dot while lines arrived that the reader has not seen.
//   - The plan keeps its reading position through every update the detail gets, and nothing is left
//     behind (no watcher, no view) when a job tab goes away.
//
// The real layout and window are used where the test is about layout, the key view loop or a window
// (MDRig, indices 990...997); the rest drives a detail on its own. Waits are conditions, never sleeps.

final class MotherDetailSwitchTests: XCTestCase {

    // MARK: - Helpers

    private typealias Segment = MotherJobDetail.Segment

    /// A host that records what the detail asks of the app, on top of the harness stub.
    private final class PlanRecordingHost: MotherJobDetailHost {
        let base = MDStubHost()
        var openedPlans: [String] = []

        var brokerConnected: Bool { base.brokerConnected }
        var brokerConnectedPublisher: AnyPublisher<Bool, Never> { base.brokerConnectedPublisher }
        var motherActionErrorPublisher: AnyPublisher<String?, Never> { base.motherActionErrorPublisher }
        var motherPeeksPublisher: AnyPublisher<[String: MotherPeekPayload], Never> { base.motherPeeksPublisher }
        func peek(for jobId: String) -> MotherPeekPayload? { base.peek(for: jobId) }
        var usesDefaultBroker: Bool { base.usesDefaultBroker }
        func motherBinary() -> URL? { nil }
        func answerJob(_ id: String, text: String) {}
        var supportsAnswerOption: Bool { true }
        var supportsAck: Bool { false }
        var motherDecisionChangesPublisher: AnyPublisher<Void, Never> { base.motherDecisionChangesPublisher }
        func motherDecisionState(jobId: String, decisionId: String) -> MotherDecisionSendState { .idle }
        func beginMotherDecisionConfirm(jobId: String, decisionId: String, option: MotherDecisionOptionID) {}
        func cancelMotherDecisionConfirm(jobId: String, decisionId: String) {}
        func answerMotherDecision(jobId: String, decisionId: String, option: MotherDecisionOption, text: String) {}
        func ackMotherAttention(jobId: String, reason: MotherAttentionReason) {}
        func cancelJob(_ id: String) {}
        func retryJob(_ id: String) {}
        func forceStartJob(_ id: String) {}
        func escalateJob(_ id: String) {}
        func archiveJob(_ id: String) {}
        func openPlan(path: String) { openedPlans.append(path) }
        func clearMotherActionError() {}
    }

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }

    private func job(_ id: String = "j1", state: String = "awaiting", plan: String?, progress: Int? = nil,
                     longTitle: Bool = false) -> MotherJob {
        MDFixtures.job(id: id, long: longTitle ? [.title] : [], state: state, planPath: plan, progressPct: progress, bare: true)
    }

    /// A detail on its own (no window), with a log file for jobs `j1` and `j2`.
    private func makeDetail(host: MotherJobDetailHost = MDStubHost()) throws -> (detail: MotherJobDetail, dir: URL) {
        let dir = try PlanTestSupport.tempDirectory(self)
        for id in ["j1", "j2"] {
            try MDFixtures.logText(lines: 1, long: false).write(to: dir.appendingPathComponent("\(id).log"), atomically: true, encoding: .utf8)
        }
        let detail = MotherJobDetail(host: host, logDirectory: dir)
        addTeardownBlock { detail.select(nil) }
        return (detail, dir)
    }

    private func waitForLog(_ detail: MotherJobDetail, file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil { detail.logTextView.string.contains("LOG-0 ") }
        XCTAssertTrue(ok, "the log tail never rendered", file: file, line: line)
    }

    private func waitForPlan(_ detail: MotherJobDetail, file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil { detail.planView?.state == .document }
        XCTAssertTrue(ok, "the plan never rendered; state is \(String(describing: detail.planView?.state))", file: file, line: line)
    }

    private func planCopy(_ fixture: String = "plan-full.md", dir: URL) throws -> String {
        try PlanTestSupport.copyFixture(fixture, into: dir, as: "plan.md").path
    }

    /// Only `segment` is on show, and the switch says so.
    private func assertOnly(_ segment: Segment, _ detail: MotherJobDetail,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(detail.selectedSegment, segment, file: file, line: line)
        XCTAssertEqual(!detail.contentScrollView.isHiddenOrHasHiddenAncestor, segment == .overview, "Overview shown", file: file, line: line)
        XCTAssertEqual(!detail.logScrollView.isHiddenOrHasHiddenAncestor, segment == .log, "Log shown", file: file, line: line)
        XCTAssertEqual(detail.planView.map { !$0.isHiddenOrHasHiddenAncestor } ?? false, segment == .plan, "Plan shown", file: file, line: line)
        XCTAssertFalse(detail.segmentControl.isHiddenOrHasHiddenAncestor, "the switch is always there", file: file, line: line)
        XCTAssertEqual(detail.segmentControl.selectedSegment, detail.visibleSegments.firstIndex(of: segment), file: file, line: line)
    }

    private func textFields(in view: NSView) -> [NSTextField] { MD.allSubviews(view).compactMap { $0 as? NSTextField } }

    // MARK: - Which segments a job has

    func testAJobWithoutAPlanHasOnlyOverviewAndLog() throws {
        let (detail, _) = try makeDetail()
        for plan in [nil, ""] as [String?] {
            detail.select(job(plan: plan))
            XCTAssertEqual(detail.visibleSegments, [.overview, .log], "plan path \(String(describing: plan))")
            XCTAssertEqual(detail.segmentControl.segmentCount, 2)
            XCTAssertEqual(detail.segmentLabel(.overview), "Overview")
            XCTAssertEqual(detail.segmentLabel(.log), "Log")
            XCTAssertNil(detail.segmentLabel(.plan))

            detail.selectSegment(.plan)
            XCTAssertEqual(detail.selectedSegment, .overview, "there is no Plan to choose")
            XCTAssertNil(detail.planView, "and no plan view is built for it")
        }
    }

    func testAJobWithAPlanHasOverviewPlanAndLogInThatOrder() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: try planCopy(dir: dir)))
        XCTAssertEqual(detail.visibleSegments, [.overview, .plan, .log])
        XCTAssertEqual(detail.segmentControl.segmentCount, 3)
        XCTAssertEqual([Segment.overview, .plan, .log].compactMap { detail.segmentLabel($0) }, ["Overview", "Plan", "Log"])
    }

    // MARK: - What each segment shows

    func testANewJobStartsOnTheOverviewWhateverItsState() throws {
        let (detail, dir) = try makeDetail()
        let plan = try planCopy(dir: dir)
        for state in ["awaiting", "running", "done"] {
            detail.select(job("j1", state: state, plan: plan))
            assertOnly(.overview, detail)
            XCTAssertTrue(detail.planView == nil || detail.planView?.isHidden == true)

            detail.selectSegment(.log)
            assertOnly(.log, detail)
            detail.select(job("j2", state: state, plan: plan))
            assertOnly(.overview, detail)
        }
    }

    func testOnlyTheSelectedSegmentIsVisibleAndEachSelectionShowsItsOwnView() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: try planCopy(dir: dir)))
        for segment in [Segment.log, .plan, .overview, .plan, .log, .overview] {
            detail.selectSegment(segment)
            assertOnly(segment, detail)
        }
    }

    func testTheOverviewHasNoLogTailAndThereIsNoViewPlanButton() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: try planCopy(dir: dir)))
        detail.selectSegment(.plan)
        waitForPlan(detail)
        detail.selectSegment(.log)
        waitForLog(detail)

        for field in textFields(in: detail) {
            XCTAssertFalse(field.stringValue.lowercased().contains("log tail"), "the old LOG TAIL label is gone: '\(field.stringValue)'")
        }
        let buttons = MD.allSubviews(detail).compactMap { $0 as? NSButton }
        XCTAssertFalse(buttons.contains { $0.title == "View Plan" }, "the plan is a segment now, not a button")
        XCTAssertTrue(detail.logTextView.string.contains("LOG-0"), "the log itself is still shown, under its segment")
    }

    func testThePlanHeaderOpensThePlanThroughTheHost() throws {
        let host = PlanRecordingHost()
        let (detail, dir) = try makeDetail(host: host)
        let plan = try planCopy(dir: dir)
        detail.select(job(plan: plan))
        detail.selectSegment(.plan)
        waitForPlan(detail)

        let open = try XCTUnwrap(detail.planView?.openButton)
        _ = open.sendAction(open.action, to: open.target)
        XCTAssertEqual(host.openedPlans, [plan], "Open ↗ in the plan header is what View Plan was")
    }

    // MARK: - One segment per tab (per detail)

    func testUpdatesNeverChangeTheSegmentOnShow() throws {
        let (detail, dir) = try makeDetail()
        let plan = try planCopy(dir: dir)
        detail.select(job(plan: plan))

        for segment in [Segment.log, .plan] {
            detail.selectSegment(segment)
            for i in 1...50 {
                detail.update(job(state: i % 2 == 0 ? "running" : "awaiting", plan: plan, progress: i, longTitle: i % 3 == 0))
                XCTAssertEqual(detail.selectedSegment, segment, "update #\(i) moved the reader off \(segment)")
            }
            assertOnly(segment, detail)
        }
    }

    func testSelectingAnotherJobGoesBackToTheOverview() throws {
        let (detail, dir) = try makeDetail()
        let plan = try planCopy(dir: dir)
        detail.select(job("j1", plan: plan))
        detail.selectSegment(.log)
        detail.select(job("j2", plan: plan))
        assertOnly(.overview, detail)

        detail.selectSegment(.plan)
        detail.update(job("j1", plan: plan))   // another id through update is a selection
        assertOnly(.overview, detail)
    }

    func testTheSwitchFollowsThePlanPathAndFallsBackToTheOverview() throws {
        let (detail, dir) = try makeDetail()
        let plan = try planCopy(dir: dir)
        detail.select(job(plan: plan))
        detail.selectSegment(.plan)
        waitForPlan(detail)
        XCTAssertTrue(detail.planView?.isWatchingFile == true)

        detail.update(job(plan: nil))
        XCTAssertEqual(detail.visibleSegments, [.overview, .log], "the Plan segment goes with the path")
        XCTAssertEqual(detail.segmentControl.segmentCount, 2)
        assertOnly(.overview, detail)
        XCTAssertEqual(detail.planView?.isWatchingFile, false, "and so does the watcher")

        detail.update(job(plan: plan))
        XCTAssertEqual(detail.visibleSegments, [.overview, .plan, .log], "the segment comes back with the path")
        XCTAssertEqual(detail.selectedSegment, .overview, "but the reader is not moved onto it")
    }

    func testLeavingThePlanSegmentStopsItsWatcherAndComingBackReadsAgain() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: try planCopy(dir: dir)))
        detail.selectSegment(.plan)
        waitForPlan(detail)
        let planView = try XCTUnwrap(detail.planView)
        XCTAssertTrue(planView.isWatchingFile)

        detail.selectSegment(.log)
        XCTAssertFalse(planView.isWatchingFile, "a hidden plan holds no watcher")
        detail.selectSegment(.plan)
        XCTAssertTrue(planView.isWatchingFile)
        waitForPlan(detail)
    }

    func testTheSwitchsOwnChoicesSelectTheirSegments() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: try planCopy(dir: dir)))
        let control = detail.segmentControl
        // What an arrow key does to a segmented control: move the selection, then send the action.
        for (index, segment) in detail.visibleSegments.enumerated().reversed() {
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
            assertOnly(segment, detail)
        }
        for (index, segment) in detail.visibleSegments.enumerated() {
            control.selectedSegment = index
            _ = control.sendAction(control.action, to: control.target)
            assertOnly(segment, detail)
        }
    }

    // MARK: - The Log's dot

    func testTheFirstLogLoadAfterSelectingAJobDoesNotMarkTheLog() throws {
        let (detail, _) = try makeDetail()
        detail.select(job("j1", state: "done", plan: nil))
        waitForLog(detail)
        XCTAssertFalse(detail.logHasUnseenLines)
        XCTAssertEqual(detail.segmentLabel(.log), "Log")

        detail.select(job("j2", state: "done", plan: nil))
        waitForLog(detail)
        XCTAssertFalse(detail.logHasUnseenLines, "the first load of the next job is not news either")
        XCTAssertEqual(detail.segmentLabel(.log), "Log")
    }

    func testNewLogLinesWhileAnotherSegmentShowsPutADotOnTheLogUntilItIsShown() throws {
        let (detail, _) = try makeDetail()
        detail.select(job(state: "done", plan: nil))
        waitForLog(detail)

        detail.setLogAttributed(MDFixtures.logText(lines: 4, long: false))
        XCTAssertTrue(detail.logHasUnseenLines)
        XCTAssertTrue(detail.segmentLabel(.log)?.contains("\u{2022}") == true, "label: \(String(describing: detail.segmentLabel(.log)))")
        XCTAssertEqual(detail.segmentLabel(.overview), "Overview")

        detail.selectSegment(.log)
        XCTAssertFalse(detail.logHasUnseenLines, "showing the Log clears it")
        XCTAssertEqual(detail.segmentLabel(.log), "Log")
    }

    func testThereIsNoDotWhileTheLogIsOnShowAndItComesBackAfterLeaving() throws {
        let (detail, _) = try makeDetail()
        detail.select(job(state: "done", plan: nil))
        waitForLog(detail)
        detail.selectSegment(.log)

        detail.setLogAttributed(MDFixtures.logText(lines: 3, long: false))
        detail.setLogAttributed(MDFixtures.logText(lines: 6, long: false))
        XCTAssertFalse(detail.logHasUnseenLines, "the reader is looking at them")
        XCTAssertEqual(detail.segmentLabel(.log), "Log")

        detail.selectSegment(.overview)
        detail.setLogAttributed(MDFixtures.logText(lines: 9, long: false))
        XCTAssertTrue(detail.logHasUnseenLines)
        XCTAssertTrue(detail.segmentLabel(.log)?.contains("\u{2022}") == true)
    }

    func testSelectingAnotherJobClearsTheDot() throws {
        let (detail, _) = try makeDetail()
        detail.select(job("j1", state: "done", plan: nil))
        waitForLog(detail)
        detail.setLogAttributed(MDFixtures.logText(lines: 4, long: false))
        XCTAssertTrue(detail.logHasUnseenLines)

        detail.select(job("j2", state: "done", plan: nil))
        XCTAssertFalse(detail.logHasUnseenLines)
        XCTAssertEqual(detail.segmentLabel(.log), "Log")
    }

    // MARK: - What a screen reader says for each segment

    func testTheLogSegmentIsReadOutAsNewLinesWhileItHasADotAndAsLogOtherwise() throws {
        let (detail, _) = try makeDetail()
        detail.select(job(state: "done", plan: nil))
        waitForLog(detail)
        XCTAssertFalse(detail.logHasUnseenLines)
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log")

        detail.setLogAttributed(MDFixtures.logText(lines: 4, long: false))
        XCTAssertTrue(detail.logHasUnseenLines)
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log, new lines", "the dot is not read out as a bullet")
        XCTAssertEqual(detail.segmentAccessibilityLabel(.overview), "Overview", "the other segments are unaffected")

        detail.selectSegment(.log)
        XCTAssertFalse(detail.logHasUnseenLines)
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log", "showing the Log clears it")

        detail.selectSegment(.overview)
        detail.setLogAttributed(MDFixtures.logText(lines: 9, long: false))
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log, new lines", "and it comes back after leaving")
        detail.select(job("j2", state: "done", plan: nil))
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log", "another job starts clean")
    }

    func testThePlanSegmentHasNoLabelWithoutAPlanAndIsNamedPlanWithOne() throws {
        let (detail, dir) = try makeDetail()
        detail.select(job(plan: nil))
        XCTAssertNil(detail.segmentAccessibilityLabel(.plan), "there is no Plan segment to name")
        XCTAssertEqual(detail.segmentAccessibilityLabel(.overview), "Overview")

        detail.select(job(plan: try planCopy(dir: dir)))
        XCTAssertEqual(detail.segmentAccessibilityLabel(.plan), "Plan")
        XCTAssertEqual(detail.segmentAccessibilityLabel(.overview), "Overview")
        XCTAssertEqual(detail.segmentAccessibilityLabel(.log), "Log")

        detail.select(job(plan: ""))
        XCTAssertNil(detail.segmentAccessibilityLabel(.plan), "an empty plan path is no plan")
    }

    // MARK: - Nothing is left behind (MF4-12)

    func testOpeningAndClosingManyDetailsLeavesNoDetailPlanViewOrWatcherBehind() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let plan = try planCopy(dir: dir)
        var details: [Weak<MotherJobDetail>] = []
        var planViews: [Weak<PlanDocumentView>] = []

        for i in 0..<20 {
            try autoreleasepool {
                let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir)
                detail.select(job("jx-\(i)", plan: plan))
                detail.selectSegment(.plan)
                let planView = try XCTUnwrap(detail.planView)
                waitForPlan(detail)
                XCTAssertTrue(planView.isWatchingFile, "detail #\(i) watches its plan while it shows it")

                detail.select(nil)
                XCTAssertFalse(planView.isWatchingFile, "detail #\(i): closing the job stops the watcher")
                details.append(Weak(detail))
                planViews.append(Weak(planView))
            }
        }

        let freed = PlanTestSupport.pumpUntil { details.allSatisfy { $0.value == nil } && planViews.allSatisfy { $0.value == nil } }
        XCTAssertTrue(freed, "still alive: \(details.filter { $0.value != nil }.count) details, \(planViews.filter { $0.value != nil }.count) plan views")
    }

    // MARK: - In the real layout (MDRig, window indices 990...997)

    /// The rig's detail showing a copy of `fixture` as its job's plan.
    private func rigWithPlan(index: Int, fixture: String = "plan-full.md") throws -> (rig: MDRig, plan: URL) {
        let rig = try MD.makeRig(self, long: [], index: index)
        let plan = try PlanTestSupport.copyFixture(fixture, into: rig.dir, as: "plan.md")
        rig.planPath = plan.path
        rig.detail.update(rig.currentJob())
        return (rig, plan)
    }

    private func waitForPlan(_ rig: MDRig, file: StaticString = #filePath, line: UInt = #line) {
        let ok = MD.pumpUntil(rig.window) { rig.detail.planView?.state == .document }
        XCTAssertTrue(ok, "the plan never rendered", file: file, line: line)
        rig.window.contentView?.layoutSubtreeIfNeeded()
    }

    private func scroll(_ view: PlanDocumentView, toY y: CGFloat) {
        let clip = view.documentScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        view.documentScrollView.reflectScrolledClipView(clip)
    }

    func testTheOverviewIsTheDefaultAndTheTitleStateAndSwitchSitAboveEverySegment() throws {
        let rig = try MD.makeRig(self, long: [], index: 990)   // an awaiting job
        assertOnly(.overview, rig.detail)
        XCTAssertGreaterThan(rig.detail.contentScrollView.frame.height, 50)
        XCTAssertNil(rig.detail.planView)

        // A new job, too.
        try rig.selectOtherJob(planItems: 3)
        assertOnly(.overview, rig.detail)

        let detail = rig.detail
        let title = try XCTUnwrap(textFields(in: detail).first { $0.stringValue == "A job" })
        let state = try XCTUnwrap(textFields(in: detail).first { $0.stringValue == "AWAITING" })
        for segment in detail.visibleSegments {
            detail.selectSegment(segment)
            if segment == .plan { waitForPlan(rig) }
            rig.window.contentView?.layoutSubtreeIfNeeded()
            for (name, view) in [("title", title), ("state", state), ("switch", detail.segmentControl)] as [(String, NSView)] {
                XCTAssertFalse(view.isHiddenOrHasHiddenAncestor, "the \(name) is shown with \(segment)")
            }
            let titleBottom = detail.convert(title.bounds, from: title).maxY
            let stateBottom = detail.convert(state.bounds, from: state).maxY
            XCTAssertLessThanOrEqual(titleBottom, detail.segmentControl.frame.minY + 1, "the title is above the switch")
            XCTAssertLessThanOrEqual(stateBottom, detail.segmentControl.frame.minY + 1, "the state is above the switch")
        }
    }

    func testTheLogFillsTheAreaUnderTheSwitch() throws {
        let rig = try MD.makeRig(self, long: [], index: 991)
        let detail = rig.detail
        detail.selectSegment(.log)
        let laidOut = MD.pumpUntil(rig.window) { detail.logScrollView.frame.height > 100 }
        XCTAssertTrue(laidOut, "the log has no area: \(detail.logScrollView.frame)")

        assertOnly(.log, detail)
        let log = detail.logScrollView.frame
        let switchBottom = detail.segmentControl.frame.maxY
        XCTAssertGreaterThanOrEqual(log.minY, switchBottom - 0.5, "the log starts under the switch")
        XCTAssertLessThanOrEqual(log.minY, switchBottom + 20, "...right under it")
        XCTAssertEqual(log.maxY, detail.bounds.height - 16, accuracy: 1, "and runs to the bottom margin")
        XCTAssertTrue(detail.logTextView.string.contains("LOG-0"))
    }

    func testChoosingPlanRendersThePlanAndHidesTheOtherTwo() throws {
        let (rig, _) = try rigWithPlan(index: 992)
        let detail = rig.detail
        detail.selectSegment(.plan)
        waitForPlan(rig)

        assertOnly(.plan, detail)
        let planView = try XCTUnwrap(detail.planView)
        XCTAssertEqual(planView.fileNameText, "plan.md")
        XCTAssertEqual(planView.criteriaText, "✓ 3/7 criteria")
        XCTAssertGreaterThan(planView.frame.height, 100)
        XCTAssertGreaterThanOrEqual(planView.frame.minY, detail.segmentControl.frame.maxY - 0.5, "the plan is under the switch")
        XCTAssertLessThanOrEqual(planView.frame.maxX, detail.bounds.width + 0.5, "and inside the pane")
        XCTAssertFalse(planView.headings.isEmpty)

        detail.selectSegment(.overview)
        assertOnly(.overview, detail)
    }

    func testTheSwitchAndThePlanHeaderControlsTakeTheKeyboard() throws {
        let (rig, _) = try rigWithPlan(index: 993)
        let detail = rig.detail
        detail.selectSegment(.plan)
        waitForPlan(rig)
        let planView = try XCTUnwrap(detail.planView)

        XCTAssertTrue(detail.segmentControl.acceptsFirstResponder, "the switch takes the keyboard")
        let controls: [NSView] = [planView.outlineButton, planView.openButton, planView.finderButton, planView.copyPathButton]
        for control in controls {
            XCTAssertTrue(control.acceptsFirstResponder, "\(type(of: control)) can take the keyboard")
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
        }

        // Behind another segment, the plan's controls are not in the loop at all.
        detail.selectSegment(.overview)
        for control in controls {
            XCTAssertFalse(control.canBecomeKeyView, "\(type(of: control)) is hidden, so it is skipped")
        }
    }

    func testTabbingFromTheSwitchReachesThePlanHeaderControls() throws {
        try XCTSkipUnless(NSApp?.isFullKeyboardAccessEnabled == true,
                          "controls other than text fields join the key view loop only with full keyboard access")
        let (rig, _) = try rigWithPlan(index: 997)
        let detail = rig.detail
        detail.selectSegment(.plan)
        waitForPlan(rig)
        let planView = try XCTUnwrap(detail.planView)
        rig.window.recalculateKeyViewLoop()

        var reached = Set<ObjectIdentifier>()
        var cursor: NSView? = detail.segmentControl
        for _ in 0..<400 {
            cursor = cursor?.nextValidKeyView
            guard let next = cursor, !reached.contains(ObjectIdentifier(next)) else { break }
            reached.insert(ObjectIdentifier(next))
        }
        for (name, control) in [("outline", planView.outlineButton), ("Open", planView.openButton),
                                ("Finder", planView.finderButton), ("copy", planView.copyPathButton)] as [(String, NSView)] {
            XCTAssertTrue(control.canBecomeKeyView, "\(name) can be a key view")
            XCTAssertTrue(reached.contains(ObjectIdentifier(control)), "Tab reaches \(name) from the switch")
        }
    }

    func testThePlanKeepsItsPlaceThroughFiftyDetailUpdatesLogLinesAndPeeks() throws {
        let (rig, _) = try rigWithPlan(index: 994, fixture: "plan-2000-lines.md")
        let detail = rig.detail
        detail.selectSegment(.plan)
        waitForPlan(rig)
        let planView = try XCTUnwrap(detail.planView)

        let target = try XCTUnwrap(planView.headings.first { $0.title.hasPrefix("Section 40:") })
        scroll(planView, toY: target.frame.minY - 40)
        let anchor = try XCTUnwrap(planView.headings.first { $0.frame.maxY > planView.scrollOffset })
        let before = anchor.frame.minY - planView.scrollOffset
        let offset = planView.scrollOffset
        XCTAssertGreaterThan(offset, 5_000, "the reader is deep in the plan")

        func assertStill(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            guard let now = planView.headings.first(where: { $0.title == anchor.title }) else {
                return XCTFail("\(label): the anchor heading is gone", file: file, line: line)
            }
            XCTAssertEqual(now.frame.minY - planView.scrollOffset, before, accuracy: 1, "\(label): the heading moved", file: file, line: line)
            XCTAssertEqual(planView.scrollOffset, offset, accuracy: 0.01, "\(label): the plan scrolled", file: file, line: line)
        }

        for i in 1...50 {
            rig.setProgress(i)
            rig.setState(i % 2 == 0 ? "running" : "awaiting")
            rig.setGates(2 + i % 6)
            if i == 25 { rig.long.insert(.title); detail.update(rig.currentJob()) }
            detail.setLogAttributed(MDFixtures.logText(lines: 3 + i, long: false))
            rig.sendPeek(todos: 1 + i % 4, long: false)
            assertStill("after round \(i)")
        }

        let logArrived = MD.pumpUntil(rig.window) { detail.logTextView.string.contains("LOG-52 ") }
        XCTAssertTrue(logArrived)
        assertStill("after everything settled")
        XCTAssertEqual(detail.selectedSegment, .plan)
        XCTAssertEqual(planView.state, .document)
    }

    func testAWatcherDrivenReloadKeepsTheReaderOnTheSameHeadingAtTheSameOffset() throws {
        let (rig, plan) = try rigWithPlan(index: 995, fixture: "plan-2000-lines.md")
        let detail = rig.detail
        let scheduler = ManualPlanReloadScheduler()
        var made: PlanFileLoader?
        detail.makePlanFileLoader = {
            let loader = PlanFileLoader(scheduler: scheduler)
            made = loader
            return loader
        }
        detail.selectSegment(.plan)
        waitForPlan(rig)
        let loader = try XCTUnwrap(made, "the detail built its plan view with the injected loader")
        let planView = try XCTUnwrap(detail.planView)

        let target = try XCTUnwrap(planView.headings.first { $0.title.hasPrefix("Section 40:") })
        scroll(planView, toY: target.frame.minY - 40)
        let anchor = try XCTUnwrap(planView.headings.first { $0.frame.maxY > planView.scrollOffset })
        let before = anchor.frame.minY - planView.scrollOffset

        var lines = try PlanTestSupport.fixtureText("plan-2000-lines.md").components(separatedBy: "\n")
        lines.insert(contentsOf: (0..<40).flatMap { ["", "Inserted paragraph \($0) above the reading position."] }, at: 1)
        try PlanTestSupport.writeInPlace(lines.joined(separator: "\n"), to: plan)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload }, "the edit was never noticed")
        scheduler.fire()

        let moved = MD.pumpUntil(rig.window) {
            planView.headings.first { $0.title == anchor.title }.map { $0.frame.minY != anchor.frame.minY } ?? false
        }
        XCTAssertTrue(moved, "the reload never changed the document")
        let now = try XCTUnwrap(planView.headings.first { $0.title == anchor.title })
        XCTAssertEqual(now.frame.minY - planView.scrollOffset, before, accuracy: 1)
        XCTAssertEqual(detail.selectedSegment, .plan)
    }

    func testADetailTakenOutOfItsWindowStopsWatchingItsPlan() throws {
        let (rig, _) = try rigWithPlan(index: 996)
        rig.detail.selectSegment(.plan)
        waitForPlan(rig)
        let planView = try XCTUnwrap(rig.detail.planView)
        XCTAssertTrue(planView.isWatchingFile)
        XCTAssertNotNil(rig.detail.window)

        rig.detail.removeFromSuperview()
        XCTAssertNil(rig.detail.window)
        XCTAssertFalse(planView.isWatchingFile, "a job tab that is not on screen holds no watcher")
    }
}
