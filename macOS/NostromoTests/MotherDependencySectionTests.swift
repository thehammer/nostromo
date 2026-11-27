import XCTest
import AppKit
import NostromoKit

// The Overview's DEPENDS ON section: what a queued job depends on and why it waits.
// Behaviour from outside: the rows a reader sees, what pressing one does, how a job without
// dependencies lays out, and that the list row and the Overview describe the wait the same way.

/// Job and wait builders shared by the dependency tests.
enum MDepFixtures {
    /// A real-looking job id whose last eight characters are hex: `20261113T2213<nn>Z-afae98<nn>`.
    static func id(_ n: Int) -> String {
        String(format: "20261113T2213%02dZ-%08x", n % 60, UInt32(0xafae9800 + n))
    }

    static func job(_ id: String, state: String = "queued", title: String? = nil,
                    deps: [String] = [], wait: MotherDepWait? = nil) -> MotherJob {
        var j = MotherJob(id: id, state: state, repo: "nostromo", isolation: "none", title: title ?? "Job \(id)",
                          createdAt: Date(), startedAt: nil, finishedAt: nil, planPath: nil,
                          question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
        j.dependsOn = deps
        j.depWait = wait
        return j
    }

    static func wait(_ dep: String, _ reason: String, blocked: Bool = false, url: String? = nil) -> MotherDepWait {
        MotherDepWait(depId: dep, blocked: blocked, reason: reason, prURL: url)
    }

    static func rows(_ job: MotherJob, in queue: [MotherJob] = []) -> [MotherDependencyRow] {
        MotherDependencyPresentation.rows(for: job, lookup: { id in queue.first { $0.id == id } })
    }
}

final class MotherDependencySectionTests: XCTestCase {

    private typealias F = MDepFixtures
    private let dep = "20261113T221332Z-afae98a4"

    // MARK: - Why a job waits, per reason

    func testEveryReasonStatesWhatMotherReportsInWaitingOrBlockedWording() {
        let url = "https://github.com/o/r/pull/6233"
        // (reason, blocked, prefix, a phrase the reader needs, the list row's phrase)
        let table: [(String, Bool, String, String, String)] = [
            ("pr_open", false, "Waiting:", "PR (PR #6233) is open", "PR open, not merged"),
            ("dep_not_finished", false, "Waiting:", "not finished", "not finished"),
            ("pr_state_unknown", false, "Waiting:", "could not read", "PR state unknown"),
            ("dep_failed", true, "Blocked:", "--ignore-deps", "failed"),
            ("dep_cancelled", true, "Blocked:", "--ignore-deps", "cancelled"),
            ("dep_missing", true, "Blocked:", "cannot find", "not found"),
            ("dep_no_pr_url", true, "Blocked:", "without a PR link", "no PR link"),
            ("pr_closed_unmerged", true, "Blocked:", "closed without merging", "PR closed unmerged"),
        ]
        for (reason, blocked, prefix, phrase, listPhrase) in table {
            let job = F.job("j", deps: [dep], wait: F.wait(dep, reason, blocked: blocked, url: url))
            let row = F.rows(job)[0]
            let line = row.reasonLine ?? ""
            XCTAssertTrue(line.hasPrefix(prefix), "\(reason): \(line)")
            XCTAssertTrue(line.contains(phrase) || line.contains(phrase.replacingOccurrences(of: "(PR #6233) ", with: "")),
                          "\(reason): \(line)")
            XCTAssertEqual(row.isBlocked, blocked, reason)
            XCTAssertEqual(MotherJobListViewModel.waitText(for: job),
                           "\(blocked ? "Blocked" : "Waiting"): on job afae98a4 (\(listPhrase))", reason)
        }
    }

    func testAnUnknownReasonIsShownVerbatimWhenPlainAndGenericWhenNot() {
        let plain = F.job("j", deps: [dep], wait: F.wait(dep, "dep_on_fire"))
        XCTAssertTrue(F.rows(plain)[0].reasonLine?.hasPrefix("Waiting:") == true)
        XCTAssertTrue(F.rows(plain)[0].reasonLine?.contains("dep_on_fire") == true)
        XCTAssertEqual(MotherJobListViewModel.waitText(for: plain), "Waiting: on job afae98a4 (dep_on_fire)")

        let blocked = F.job("j", deps: [dep], wait: F.wait(dep, "dep_on_fire", blocked: true))
        XCTAssertTrue(F.rows(blocked)[0].reasonLine?.hasPrefix("Blocked:") == true)

        for odd in ["Not A Reason!", "", "<b>x</b>"] {
            let job = F.job("j", deps: [dep], wait: F.wait(dep, odd))
            let line = F.rows(job)[0].reasonLine ?? ""
            XCTAssertTrue(line.contains("unknown reason"), "\(odd): \(line)")
            XCTAssertFalse(line.contains(odd) && !odd.isEmpty, "free text is never echoed: \(line)")
        }
    }

    func testThePRNumberShowsOnlyWhenTheUrlHasOne() {
        func line(_ url: String?) -> String {
            F.rows(F.job("j", deps: [dep], wait: F.wait(dep, "pr_open", url: url)))[0].reasonLine ?? ""
        }
        XCTAssertTrue(line("https://github.com/o/r/pull/6233").contains("PR #6233"))
        XCTAssertFalse(line(nil).contains("#"))
        XCTAssertFalse(line("https://github.com/o/r/issues/5").contains("#"))
        XCTAssertFalse(line("https://github.com/o/r/pull/").contains("#"))
    }

    // MARK: - Which row carries the reason

    func testOnlyTheNamedRowHasAReasonLine() {
        let a = F.id(1), b = F.id(2), c = F.id(3)
        let job = F.job("j", deps: [a, b, c], wait: F.wait(b, "dep_not_finished"))
        let rows = F.rows(job)
        XCTAssertEqual(rows.map(\.id), [a, b, c])
        XCTAssertEqual(rows.map { $0.reasonLine != nil }, [false, true, false])
    }

    func testNoReasonLineAppearsWhileTheJobIsNotQueued() {
        for state in ["running", "ready", "succeeded", "failed", "cancelled", "awaiting"] {
            let job = F.job("j", state: state, deps: [dep], wait: F.wait(dep, "pr_open"))
            XCTAssertEqual(F.rows(job).count, 1, state)
            XCTAssertNil(F.rows(job)[0].reasonLine, state)
            XCTAssertNil(MotherJobListViewModel.waitText(for: job), state)
        }
    }

    func testADepWaitNamingAnIdOutsideDependsOnIsAppended() {
        let a = F.id(1), stray = F.id(9)
        let job = F.job("j", deps: [a], wait: F.wait(stray, "dep_not_finished"))
        let rows = F.rows(job)
        XCTAssertEqual(rows.map(\.id), [a, stray])
        XCTAssertNil(rows[0].reasonLine)
        XCTAssertNotNil(rows[1].reasonLine)
    }

    func testAJobWithoutDependenciesHasNoRows() {
        XCTAssertTrue(F.rows(F.job("j")).isEmpty)
    }

    // MARK: - Short ids and titles

    func testShortIdIsTheEightHexCharsAfterTheLastDashElseTheFirstSixteen() {
        XCTAssertEqual(MotherDependencyPresentation.shortId("20261113T221332Z-afae98a4"), "afae98a4")
        XCTAssertEqual(MotherDependencyPresentation.shortId("j-1"), "j-1")
        XCTAssertEqual(MotherDependencyPresentation.shortId("short"), "short")
        XCTAssertEqual(MotherDependencyPresentation.shortId("20261113T221332Z-zzzzzzzz"), "20261113T221332Z")
        XCTAssertEqual(MotherDependencyPresentation.shortId("20261113T221332Z-afae98a"), "20261113T221332Z")
        XCTAssertEqual(MotherDependencyPresentation.shortId("20261113T221332Z-afae98a40"), "20261113T221332Z")
        XCTAssertEqual(MotherDependencyPresentation.shortId(String(repeating: "q", count: 64)), String(repeating: "q", count: 16))
    }

    func testALongMultiLineTitleBecomesOneBoundedLine() {
        let title = "first line\n" + String(repeating: "x", count: 500)
        let queue = [F.job(dep, state: "running", title: title)]
        let row = F.rows(F.job("j", deps: [dep]), in: queue)[0]
        let shown = row.title ?? ""
        XCTAssertFalse(shown.contains("\n"))
        XCTAssertFalse(row.lineText.contains("\n"))
        XCTAssertLessThanOrEqual(shown.count, 121)
        XCTAssertTrue(shown.hasPrefix("first line "))
    }

    func testAnEmptyTitleFallsBackToTheJobId() {
        let queue = [F.job(dep, state: "running", title: "")]
        XCTAssertEqual(F.rows(F.job("j", deps: [dep]), in: queue)[0].title, dep)
    }

    // MARK: - In the queue or not

    func testADependencyInTheQueueIsAnOpenableRowWithItsTitleAndState() {
        let queue = [F.job(dep, state: "running", title: "Upstream work")]
        let row = F.rows(F.job("j", deps: [dep]), in: queue)[0]
        XCTAssertTrue(row.inQueue)
        XCTAssertEqual(row.state, "running")
        XCTAssertEqual(row.title, "Upstream work")
        XCTAssertTrue(row.lineText.contains("afae98a4") && row.lineText.contains("Upstream work"))
    }

    func testADependencyOutsideTheQueueSaysSo() {
        let row = F.rows(F.job("j", deps: [dep]))[0]
        XCTAssertFalse(row.inQueue)
        XCTAssertNil(row.state)
        XCTAssertTrue(row.lineText.contains("not in the queue (archived or unknown)"), row.lineText)
    }

    func testAMissingDependencyMotherNamesSaysMotherCannotFindIt() {
        let job = F.job("j", deps: [dep], wait: F.wait(dep, "dep_missing", blocked: true))
        let row = F.rows(job)[0]
        XCTAssertTrue(row.lineText.contains("Mother cannot find this job"), row.lineText)
        XCTAssertFalse(row.lineText.contains("archived"), row.lineText)
    }

    // MARK: - The section view

    private func makeSection(_ rows: [MotherDependencyRow], width: CGFloat = 400) -> MotherDependencySectionView {
        let s = MotherDependencySectionView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        s.update(rows: rows)
        s.layoutSubtreeIfNeeded()
        return s
    }

    private func twelve(namedIndex: Int? = nil, queue: Bool = true) -> (MotherJob, [MotherJob]) {
        let ids = (0..<12).map { F.id($0) }
        let wait = namedIndex.map { F.wait(ids[$0], "dep_not_finished") }
        let job = F.job("j", deps: ids, wait: wait)
        let jobs = queue ? ids.enumerated().map { F.job($1, state: "running", title: "Dependency \($0)") } : []
        return (job, jobs)
    }

    func testPressingAnInQueueRowOpensItByFullId() throws {
        let queue = [F.job(dep, state: "running", title: "Upstream")]
        let s = makeSection(F.rows(F.job("j", deps: [dep]), in: queue))
        var opened: [String] = []
        s.onOpen = { opened.append($0) }
        let button = try XCTUnwrap(s.visibleRowViews.first?.button, "an in-queue row is a button")
        button.performClick(nil)
        XCTAssertEqual(opened, [dep], "the full id, not the short one")
    }

    func testARowOutsideTheQueueIsPlainTextNotAButton() throws {
        let s = makeSection(F.rows(F.job("j", deps: [dep])))
        let row = try XCTUnwrap(s.visibleRowViews.first)
        XCTAssertNil(row.button)
        let label = try XCTUnwrap(row.textLabel)
        XCTAssertTrue(label.stringValue.contains("not in the queue (archived or unknown)"), label.stringValue)
    }

    func testAMissingRowShowsMotherCannotFindThisJobAsText() throws {
        let job = F.job("j", deps: [dep], wait: F.wait(dep, "dep_missing", blocked: true))
        let s = makeSection(F.rows(job))
        let label = try XCTUnwrap(s.visibleRowViews.first?.textLabel)
        XCTAssertTrue(label.stringValue.contains("Mother cannot find this job"), label.stringValue)
    }

    func testTwelveDependenciesShowFiveRowsAndAShowAllButton() {
        let (job, queue) = twelve()
        let s = makeSection(F.rows(job, in: queue))
        XCTAssertEqual(s.visibleRowViews.count, 5)
        XCTAssertEqual(s.visibleRowViews.map(\.row.id), (0..<5).map { F.id($0) }, "the first five, in order")
        XCTAssertNotNil(s.toggleButton.superview, "the toggle is shown")
        XCTAssertEqual(s.toggleButton.attributedTitle.string, "Show all 12")
    }

    func testFiveOrFewerDependenciesShowEveryRowAndNoToggle() {
        let ids = (0..<5).map { F.id($0) }
        let s = makeSection(F.rows(F.job("j", deps: ids)))
        XCTAssertEqual(s.visibleRowViews.count, 5)
        XCTAssertNil(s.toggleButton.superview)
    }

    func testTheRowMotherNamesIsAmongTheFiveShownEvenWhenItIsTheNinth() {
        let (job, queue) = twelve(namedIndex: 8)
        let s = makeSection(F.rows(job, in: queue))
        let shown = s.visibleRowViews.map(\.row.id)
        XCTAssertEqual(shown.count, 5)
        XCTAssertEqual(shown.first, F.id(8), "moved to the front")
        XCTAssertNotNil(s.visibleRowViews.first?.row.reasonLine)
        XCTAssertEqual(Set(shown).count, 5, "no row is shown twice")
    }

    func testShowAllRevealsTwelveRowsAndShowFewerGoesBack() {
        let (job, queue) = twelve()
        let s = makeSection(F.rows(job, in: queue))
        s.toggleButton.performClick(nil)
        s.layoutSubtreeIfNeeded()
        XCTAssertEqual(s.visibleRowViews.count, 12)
        XCTAssertEqual(s.toggleButton.attributedTitle.string, "Show fewer")
        s.toggleButton.performClick(nil)
        XCTAssertEqual(s.visibleRowViews.count, 5)
        XCTAssertEqual(s.toggleButton.attributedTitle.string, "Show all 12")
    }

    func testTheToggleKeepsKeyboardFocusWhenPressed() throws {
        let (job, queue) = twelve()
        let s = makeSection(F.rows(job, in: queue))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(s)
        s.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        s.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(s.toggleButton), "the toggle can take focus")
        s.toggleButton.performClick(nil)
        XCTAssertTrue(window.firstResponder === s.toggleButton, "focus stays on the toggle after Show all")
        s.toggleButton.performClick(nil)
        XCTAssertTrue(window.firstResponder === s.toggleButton, "focus stays on the toggle after Show fewer")
    }

    func testAnExpandedSectionStaysExpandedWhenARowChanges() {
        let (job, queue) = twelve()
        let s = makeSection(F.rows(job, in: queue))
        s.toggleButton.performClick(nil)
        var changed = queue
        changed[0] = F.job(F.id(0), state: "succeeded", title: "Dependency 0")
        s.update(rows: F.rows(job, in: changed))
        XCTAssertEqual(s.visibleRowViews.count, 12, "an update does not collapse what the reader opened")
        XCTAssertEqual(s.visibleRowViews.first?.row.state, "succeeded")
        XCTAssertEqual(s.toggleButton.attributedTitle.string, "Show fewer")
    }

    // MARK: Accessibility

    func testAccessibilityNamesTheGroupTheRowsAndTheToggle() throws {
        let (job, queue) = twelve(namedIndex: 0)
        let s = makeSection(F.rows(job, in: queue))
        XCTAssertEqual(s.accessibilityLabel(), "Depends on, 12 jobs")
        XCTAssertEqual(s.toggleButton.accessibilityLabel(), "Show all 12 dependencies")

        let button = try XCTUnwrap(s.visibleRowViews.first?.button)
        let label = button.accessibilityLabel() ?? ""
        XCTAssertTrue(label.contains("Dependency 0") && label.contains("running"), label)
        XCTAssertTrue(label.contains("Waiting:"), "the reason is read with the row: \(label)")
        XCTAssertEqual(button.accessibilityHelp(), "Opens this job in the Mother pane")
    }

    func testTheGroupLabelIsSingularForOneDependency() {
        let s = makeSection(F.rows(F.job("j", deps: [dep])))
        XCTAssertEqual(s.accessibilityLabel(), "Depends on, 1 job")
    }

    func testARowOutsideTheQueueIsStillDescribedToVoiceOver() throws {
        let s = makeSection(F.rows(F.job("j", deps: [dep])))
        let label = try XCTUnwrap(s.visibleRowViews.first?.textLabel?.accessibilityLabel())
        XCTAssertTrue(label.contains("afae98a4") && label.contains("not in the queue"), label)
    }

    // MARK: - In the job detail

    private struct Rig {
        let window: NSWindow
        let detail: MotherJobDetail
        var document: NSView { detail.contentScrollView.documentView! }
    }

    private func makeDetail(width: CGFloat = 420) throws -> Rig {
        let dir = try MD.makeTemp(self)
        let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 700))
        let window = MDFixedWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        window.alphaValue = 0
        window.orderFront(nil)
        detail.frame = container.bounds
        container.addSubview(detail)
        addTeardownBlock {
            detail.select(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        return Rig(window: window, detail: detail)
    }

    private func metaStack(_ detail: MotherJobDetail) -> NSView? {
        let id = MD.allSubviews(detail).compactMap { $0 as? NSTextField }.first { $0.stringValue == "ID" }
        return id?.superview?.superview
    }

    /// Distance from the section's top to the bottom of whatever sits directly above it.
    private func gapAbove(_ rig: Rig) -> CGFloat {
        let section = rig.detail.dependencySection
        let top = section.frame.minY
        let aboveBottoms = rig.document.subviews
            .filter { $0 !== section && !$0.isHidden && $0.frame.maxY <= top + 0.5 }
            .map(\.frame.maxY)
        return top - (aboveBottoms.max() ?? 0)
    }

    private func gapBelow(_ rig: Rig) throws -> CGFloat {
        let meta = try XCTUnwrap(metaStack(rig.detail), "the meta rows")
        let metaTop = rig.document.convert(meta.bounds, from: meta).minY
        return metaTop - rig.detail.dependencySection.frame.maxY
    }

    func testAJobWithoutDependenciesLeavesNoTraceInTheLayout() throws {
        let rig = try makeDetail()
        rig.detail.select(F.job("j-none", state: "running"))
        MD.pump(rig.window)
        let section = rig.detail.dependencySection
        XCTAssertEqual(section.frame.height, 0, accuracy: 0.5, "no section height")
        XCTAssertEqual(gapAbove(rig), 0, accuracy: 0.5, "no gap above it")
        XCTAssertEqual(try gapBelow(rig), 8, accuracy: 0.5, "the meta rows sit where they always did: 8 pt under the section's (empty) place")
    }

    func testDependenciesMakeRoomAndRemovingThemGivesItBack() throws {
        let rig = try makeDetail()
        let a = F.id(1), b = F.id(2)
        let queue = [F.job(a, state: "running", title: "A"), F.job(b, state: "succeeded", title: "B")]
        rig.detail.dependencyLookup = { id in queue.first { $0.id == id } }
        rig.detail.select(F.job("j-deps", deps: [a, b], wait: F.wait(a, "dep_not_finished")))
        MD.pump(rig.window)
        let section = rig.detail.dependencySection
        XCTAssertGreaterThan(section.frame.height, 20)
        XCTAssertGreaterThan(gapAbove(rig), 0, "separated from what is above")
        XCTAssertEqual(try gapBelow(rig), 8, accuracy: 0.5)

        rig.detail.update(F.job("j-deps", state: "running", deps: []))
        MD.pump(rig.window)
        XCTAssertEqual(section.frame.height, 0, accuracy: 0.5)
        XCTAssertEqual(gapAbove(rig), 0, accuracy: 0.5)
        XCTAssertEqual(try gapBelow(rig), 8, accuracy: 0.5)
    }

    func testRefreshDependenciesPicksUpADependencyStateChangeWithoutTheDependentChanging() throws {
        let rig = try makeDetail()
        var queue = [F.job(dep, state: "running", title: "Upstream")]
        rig.detail.dependencyLookup = { id in queue.first { $0.id == id } }
        let dependent = F.job("j-dep", deps: [dep], wait: F.wait(dep, "dep_not_finished"))
        rig.detail.select(dependent)
        XCTAssertEqual(rig.detail.dependencySection.rows.first?.state, "running")

        queue = [F.job(dep, state: "succeeded", title: "Upstream")]
        rig.detail.refreshDependencies()
        XCTAssertEqual(rig.detail.dependencySection.rows.first?.state, "succeeded")

        queue = []
        rig.detail.refreshDependencies()
        XCTAssertEqual(rig.detail.dependencySection.rows.first?.inQueue, false, "archived: the row says it is not in the queue")
    }

    func testPressingARowInTheDetailReportsTheDependencyId() throws {
        let rig = try makeDetail()
        let queue = [F.job(dep, state: "running", title: "Upstream")]
        rig.detail.dependencyLookup = { id in queue.first { $0.id == id } }
        var opened: [String] = []
        rig.detail.onOpenDependency = { opened.append($0) }
        rig.detail.select(F.job("j-dep", deps: [dep]))
        rig.detail.dependencySection.visibleRowViews.first?.button?.performClick(nil)
        XCTAssertEqual(opened, [dep])
    }

    // MARK: - The wait, in the list row and the Overview

    func testTheListRowSaysWhichJobAWaitingJobIsWaitingOn() {
        let id = "20261113T221332Z-afae98a4"
        let job = F.job("j", deps: [id], wait: F.wait(id, "pr_open", url: "https://github.com/o/r/pull/6233"))
        XCTAssertEqual(MotherJobListViewModel.waitText(for: job), "Waiting: on job afae98a4 (PR open, not merged)")
    }

    func testTheListRowSaysBlockedForABlockedJob() {
        let job = F.job("j", deps: [dep], wait: F.wait(dep, "dep_failed", blocked: true))
        XCTAssertEqual(MotherJobListViewModel.waitText(for: job), "Blocked: on job afae98a4 (failed)")
    }

    func testNoDependencyWaitMeansNoWaitText() {
        XCTAssertNil(MotherJobListViewModel.waitText(for: F.job("j", deps: [dep])))
    }

    func testTheOverviewValueDropsThePrefixTheLabelCarries() {
        let waiting = F.job("j", deps: [dep], wait: F.wait(dep, "dep_not_finished"))
        XCTAssertEqual(MotherJobDetail.waitingLine(for: waiting), "on job afae98a4 (not finished)")
        let blocked = F.job("j", deps: [dep], wait: F.wait(dep, "dep_cancelled", blocked: true))
        XCTAssertEqual(MotherJobDetail.waitingLine(for: blocked), "on job afae98a4 (cancelled)")
    }

    func testTheOverviewLabelsABlockedJobBlockedAndAWaitingOneWaiting() throws {
        func texts(_ detail: MotherJobDetail) -> [String] {
            MD.allSubviews(detail).compactMap { ($0 as? NSTextField)?.stringValue }
        }
        let blockedRig = try makeDetail()
        blockedRig.detail.select(F.job("j-b", deps: [dep], wait: F.wait(dep, "dep_failed", blocked: true)))
        MD.pump(blockedRig.window)
        let blocked = texts(blockedRig.detail)
        XCTAssertTrue(blocked.contains("Blocked"), "key: \(blocked)")
        XCTAssertFalse(blocked.contains("Waiting"))
        XCTAssertTrue(blocked.contains("on job afae98a4 (failed)"), "value without the prefix: \(blocked)")

        let waitingRig = try makeDetail()
        waitingRig.detail.select(F.job("j-w", deps: [dep], wait: F.wait(dep, "dep_not_finished")))
        MD.pump(waitingRig.window)
        let waiting = texts(waitingRig.detail)
        XCTAssertTrue(waiting.contains("Waiting"), "key: \(waiting)")
        XCTAssertFalse(waiting.contains("Blocked"))
        XCTAssertTrue(waiting.contains("on job afae98a4 (not finished)"))
    }

    // MARK: - In the Mother view

    private func makeMotherView() -> MotherView {
        let savedCoalescing = MotherView.selectionCoalescing
        MotherView.selectionCoalescing = 0
        MotherView.requestedJobId = nil
        let suite = UserDefaults(suiteName: "MotherDependencySectionTests.\(UUID().uuidString)")!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        addTeardownBlock {
            MotherView.selectionCoalescing = savedCoalescing
            MotherView.widthDefaults = previous
            MotherView.requestedJobId = nil
            MotherView.requestedFilterTag = nil
            AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
            window.contentView = nil
        }
        return view
    }

    private func waitUntil(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// Publishes `jobs` and waits for the Mother view's own list to show those ids: the view takes them through a
    /// main-queue hop, so the view's state (not the store's, and not a fixed delay) is the signal. It sees ids
    /// only: a publish that changes a job's state but not the id set returns at once, and its test waits on the
    /// state it cares about (the dependency row) itself.
    private func publish(_ jobs: [MotherJob], in view: MotherView) {
        AppStore.shared.applyBrokerEventForTesting(.snapshot(jobs))
        let wanted = Set(jobs.map(\.id))
        waitUntil("the view never listed \(wanted) (it lists \(view.listedJobIds))") { view.listedJobIds == wanted }
    }

    func testClickingADependencyRowSelectsThatJobAndShowsItsDetail() throws {
        let view = makeMotherView()
        let upstream = F.job(dep, state: "running", title: "Upstream work")
        let dependent = F.job("j-dependent", deps: [dep], wait: F.wait(dep, "dep_not_finished"))
        publish([dependent, upstream], in: view)
        view.listDidSelect(dependent)
        let detail = try XCTUnwrap(view.shownDetail)
        waitUntil("the dependency never showed as in the queue") { detail.dependencySection.rows.first?.inQueue == true }

        let button = try XCTUnwrap(detail.dependencySection.visibleRowViews.first?.button)
        button.performClick(nil)

        XCTAssertEqual(view.selectedJobId, dep)
        XCTAssertEqual(view.shownDetail?.currentJobId, dep)
    }

    func testClickingADependencyWorksWhileAFromFilterIsRequested() throws {
        // A filter that hides the dependency is reset to All, so the click lands on a row that is listed.
        let view = makeMotherView()
        let upstream = F.job(dep, state: "running", title: "Upstream work")
        let dependent = F.job("j-dependent", deps: [dep], wait: F.wait(dep, "dep_not_finished"))
        publish([dependent, upstream], in: view)
        view.setOriginFilter(.focus(tag: "claudia-ABCDEF12"))
        view.listDidSelect(dependent)
        let detail = try XCTUnwrap(view.shownDetail)
        waitUntil("the dependency never showed as in the queue") { detail.dependencySection.rows.first?.inQueue == true }
        XCTAssertFalse(view.listedJobIds.contains(dep), "the From: filter should hide the dependency before the click")

        detail.dependencySection.visibleRowViews.first?.button?.performClick(nil)

        XCTAssertTrue(view.listedJobIds.contains(dep), "the click should reset the From: filter so the dependency is listed")
        XCTAssertEqual(view.selectedJobId, dep)
        XCTAssertEqual(view.shownDetail?.currentJobId, dep)
    }

    func testADependencyChangingStateUpdatesTheOpenOverviewWhileTheDependentIsUnchanged() throws {
        let view = makeMotherView()
        let dependent = F.job("j-dependent", deps: [dep], wait: F.wait(dep, "dep_not_finished"))
        publish([dependent, F.job(dep, state: "running", title: "Upstream work")], in: view)
        view.listDidSelect(dependent)
        let detail = try XCTUnwrap(view.shownDetail)
        waitUntil("running dependency never showed") { detail.dependencySection.rows.first?.state == "running" }

        publish([dependent, F.job(dep, state: "succeeded", title: "Upstream work")], in: view)
        waitUntil("the row never followed the dependency to succeeded") {
            detail.dependencySection.rows.first?.state == "succeeded"
        }
    }
}
