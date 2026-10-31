import XCTest
import AppKit
import Combine
import SwiftUI
import NostromoKit

// MotherJobListViewModel, MotherJobDetail, MotherOriginLine, FocusStore and Focus are compiled into this
// target directly (logic test).
//
// MF3: every Mother job row, and the job detail, says who queued the job.
//
//   - A row's origin follows the daemon's annotation and the app's current focus names.
//   - A rename or a removal reaches the row in the same run-loop turn as the FocusStore publish: no
//     expectation, no wait. (`onOriginsChanged` is how the Mother view refreshes open detail lines.)
//   - Only an open focus is clickable; a closed focus, an unverified claim, You and unknown are text.
//   - The detail's origin line is one line under the title: a link when clickable, a label otherwise,
//     and it truncates rather than widening the detail.
//
// Every FocusStore here is backed by a throwaway file; `FocusStore.shared` is never touched.

// MARK: - The row's origin

final class MotherOriginRowTests: XCTestCase {

    // MARK: Helpers

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeStore() throws -> FocusStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mother-origin-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
    }

    private func dynamicFocus(id: String = "ABCDEF12-0000-4000-8000-000000000001", label: String? = nil) -> Focus {
        var f = Focus(id: id, agentTag: "claudia", projectPath: "/Users/hammer/Code/admin-portal",
                      isBuiltIn: false, org: "Carefeed")
        f.label = label
        return f
    }

    private func job(_ id: String = "j1", state: String = "running") -> MotherJob {
        MotherJob(id: id, state: state, repo: "nostromo", isolation: "worktree", title: "title-\(id)",
                  createdAt: Date(timeIntervalSince1970: 1_000), startedAt: nil, finishedAt: nil,
                  planPath: nil, question: nil, pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    private func note(_ kind: MotherOriginKind, tag: String? = nil, snapshot: String? = nil,
                      focusName: String? = nil) -> MotherJobAnnotation {
        MotherJobAnnotation(origin: MotherOriginView(kind: kind, focusTag: tag, nameSnapshot: snapshot, focusName: focusName))
    }

    private func makeVM(_ store: FocusStore, jobs: [MotherJob] = [], annotations: [String: MotherJobAnnotation] = [:])
        -> MotherJobListViewModel {
        let vm = MotherJobListViewModel(focusStore: store)
        vm.jobs = jobs
        vm.setAnnotations(annotations)
        return vm
    }

    // MARK: Origin by kind

    func testEachKindOfOriginShowsOnItsRow() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Fix the login flow")
        store.add(focus)
        let jobs = ["f", "x", "v", "y", "u", "r", "bare"].map { job($0) }
        let annotations = [
            "f": note(.focus, tag: focus.sessionTag, snapshot: "Fix login"),
            "x": note(.focus, tag: "claudia-GONE0001", snapshot: "Gone focus"),
            "v": note(.unverified, tag: "claudia-D00DFEED", snapshot: "Claimed name"),
            "y": note(.you),
            "u": note(.unknown),
            "r": note(.other("robot"), tag: focus.sessionTag),
        ]
        let vm = makeVM(store, jobs: jobs, annotations: annotations)
        func origin(_ id: String) -> MotherOriginDisplay? { vm.rowModel(for: jobs.first { $0.id == id }!).origin }

        XCTAssertEqual(origin("f")?.text, "Fix the login flow")
        XCTAssertEqual(origin("x")?.text, "Gone focus (closed)")
        XCTAssertEqual(origin("v")?.text, "Claimed name?")
        XCTAssertEqual(origin("v")?.badge, "unverified")
        XCTAssertEqual(origin("y")?.text, "You")
        XCTAssertEqual(origin("u")?.text, "origin unknown")
        XCTAssertEqual(origin("r")?.text, "origin unknown", "a kind this build does not know reads as unknown")
        XCTAssertEqual(origin("bare")?.text, "origin unknown", "a job with no annotation reads as unknown")
    }

    func testEveryRowHasAnOriginEvenBeforeAnyAnnotationArrives() throws {
        let vm = makeVM(try makeStore(), jobs: [job("j1")])
        XCTAssertEqual(vm.rowModel(for: job("j1")).origin?.text, "origin unknown")
    }

    func testARowsSpokenSummaryNamesTheJobThenItsOrigin() throws {
        let vm = makeVM(try makeStore(), jobs: [job("j1")], annotations: ["j1": note(.you)])
        XCTAssertEqual(vm.rowModel(for: job("j1")).accessibilitySummary, "title-j1. From You. nostromo.")
    }

    func testAnArrivingAnnotationChangesTheRowAndAnnouncesIt() throws {
        let vm = makeVM(try makeStore(), jobs: [job("j1")])
        var announced = 0
        vm.onOriginsChanged = { announced += 1 }
        vm.setAnnotations(["j1": note(.you)])
        XCTAssertEqual(vm.rowModel(for: job("j1")).origin?.text, "You")
        XCTAssertEqual(announced, 1)
    }

    func testTheSameAnnotationsAgainAnnounceNothing() throws {
        let vm = makeVM(try makeStore(), jobs: [job("j1")], annotations: ["j1": note(.you)])
        var announced = 0
        vm.onOriginsChanged = { announced += 1 }
        vm.setAnnotations(["j1": note(.you)])
        XCTAssertEqual(announced, 0, "an equal frame must not churn the detail lines")
    }

    func testAnOriginDisplayForAJobTheListNeverHeardOfIsUnknown() throws {
        let vm = makeVM(try makeStore())
        XCTAssertEqual(vm.originDisplay(forJobId: "nobody").text, "origin unknown")
    }

    // MARK: Rename

    func testARenameShowsOnTheRowAsSoonAsTheCallReturns() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Before")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Before")])
        XCTAssertEqual(vm.rowModel(for: job()).origin?.text, "Before")

        XCTAssertTrue(store.rename(id: focus.id, label: "After"))

        // No run-loop turn, no expectation: the same call stack.
        XCTAssertEqual(vm.rowModel(for: job()).origin?.text, "After")
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").text, "After")
    }

    func testARenameAnnouncesItselfAndTheRowAlreadyShowsTheNewNameWhenItDoes() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Before")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Before")])
        var seenDuringCallback: [String] = []
        vm.onOriginsChanged = { seenDuringCallback.append(vm.originDisplay(forJobId: "j1").text) }

        store.rename(id: focus.id, label: "After")

        XCTAssertFalse(seenDuringCallback.isEmpty, "a rename must tell the Mother view to refresh its detail lines")
        XCTAssertEqual(seenDuringCallback.last, "After", "the callback must see the new name, not the old one")
    }

    func testARenameKeepsTheOriginClickableAndOnTheSameTag() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Before")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Before")])
        store.rename(id: focus.id, label: "After")
        let origin = vm.rowModel(for: job()).origin
        XCTAssertEqual(origin?.isClickable, true)
        XCTAssertEqual(origin?.focusTag, focus.sessionTag, "a rename changes the name, never the address")
    }

    func testAfterARenameTheTooltipSaysWhatTheJobWasQueuedAs() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Old name")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Old name")])
        XCTAssertFalse(vm.originDisplay(forJobId: "j1").tooltip.contains("queued as"), "same name: nothing to add")
        store.rename(id: focus.id, label: "New name")
        let tooltip = vm.originDisplay(forJobId: "j1").tooltip
        XCTAssertTrue(tooltip.contains("queued as Old name"), tooltip)
        XCTAssertTrue(tooltip.contains(focus.sessionTag), tooltip)
    }

    func testClearingALabelFallsBackToTheFocusesDefaultName() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Custom")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Custom")])
        store.rename(id: focus.id, label: nil)
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").text, "Claudia in Admin Portal")
    }

    func testARenameOfAnotherFocusLeavesThisRowAlone() throws {
        let store = try makeStore()
        let mine = dynamicFocus(label: "Mine")
        let other = dynamicFocus(id: "ABCDEF12-0000-4000-8000-000000000002", label: "Other")
        store.add(mine)
        store.add(other)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: mine.sessionTag, snapshot: "Mine")])
        store.rename(id: other.id, label: "Other renamed")
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").text, "Mine")
    }

    // MARK: Removal

    func testRemovingTheFocusTurnsTheOriginIntoAMutedNonClickableClosedName() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Fix the login flow")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Fix the login flow")])
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").isClickable, true)

        store.remove(focus)

        let origin = vm.rowModel(for: job()).origin
        XCTAssertEqual(origin?.text, "Fix the login flow (closed)")
        XCTAssertEqual(origin?.isMuted, true)
        XCTAssertEqual(origin?.isClickable, false)
        XCTAssertEqual(origin?.tooltip.hasPrefix("This focus is closed."), true)
    }

    func testRemovalAnnouncesItselfAndTheCallbackAlreadySeesTheFocusClosed() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Doomed")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Doomed")])
        var seen: [Bool] = []
        vm.onOriginsChanged = { seen.append(vm.originDisplay(forJobId: "j1").isClickable) }

        store.remove(focus)

        XCTAssertFalse(seen.isEmpty, "a removal must tell the Mother view to refresh its detail lines")
        XCTAssertEqual(seen.last, false, "the callback must see the focus closed")
    }

    func testAFocusAddedAfterTheJobWasQueuedMakesTheOriginClickableAgain() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Back again")
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Back again")])
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").isClickable, false)
        store.add(focus)
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").isClickable, true)
        XCTAssertEqual(vm.originDisplay(forJobId: "j1").text, "Back again")
    }

    func testTheFilterSeesARenameToo() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Before")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: "Before")])
        store.rename(id: focus.id, label: "After")
        XCTAssertEqual(vm.filtered.entries.map(\.title), ["All", "After"])
    }

    // MARK: Clicking

    func testOnlyAnOpenFocusIsClickable() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Open one")
        store.add(focus)
        let jobs = ["open", "closed", "unverified", "you", "unknown"].map { job($0) }
        let vm = makeVM(store, jobs: jobs, annotations: [
            "open": note(.focus, tag: focus.sessionTag),
            "closed": note(.focus, tag: "claudia-GONE0001", snapshot: "Gone"),
            "unverified": note(.unverified, tag: focus.sessionTag, snapshot: "Claims the open one"),
            "you": note(.you),
            "unknown": note(.unknown, tag: focus.sessionTag),
        ])
        func clickable(_ id: String) -> Bool? { vm.rowModel(for: jobs.first { $0.id == id }!).origin?.isClickable }
        XCTAssertEqual(clickable("open"), true)
        XCTAssertEqual(clickable("closed"), false)
        XCTAssertEqual(clickable("unverified"), false, "an unverified claim never links, even to an open focus")
        XCTAssertEqual(clickable("you"), false)
        XCTAssertEqual(clickable("unknown"), false)
    }

    func testAClickHandsTheFocusTagToTheOpenFocusCallback() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Open one")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag)])
        var opened: [String] = []
        vm.openFocus = { opened.append($0) }

        let origin = vm.originDisplay(forJobId: "j1")
        XCTAssertTrue(origin.isClickable)
        vm.openFocus(try XCTUnwrap(origin.focusTag))

        XCTAssertEqual(opened, [focus.sessionTag])
    }

    func testAnOpenOriginsTagIsTheFocusesSessionTagNotItsNameOrId() throws {
        let store = try makeStore()
        let focus = dynamicFocus(label: "Named")
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag)])
        let tag = vm.originDisplay(forJobId: "j1").focusTag
        XCTAssertEqual(tag, "claudia-ABCDEF12")
        XCTAssertNotEqual(tag, focus.id)
    }

    // MARK: Hostile names on a row

    func testAHostileFocusNameNeverReachesTheRow() throws {
        let store = try makeStore()
        let hostile = "safe\u{202E}evil\u{2066}\u{1B}[31mred\u{0}nul\u{3164}fill\nline\u{2028}sep"
        let focus = dynamicFocus(label: hostile)
        store.add(focus)
        let vm = makeVM(store, jobs: [job()], annotations: ["j1": note(.focus, tag: focus.sessionTag, snapshot: hostile)])
        let origin = try XCTUnwrap(vm.rowModel(for: job()).origin)
        for s in [origin.text, origin.accessibilityText] {
            for scalar in s.unicodeScalars {
                let v = scalar.value
                XCTAssertFalse(v <= 0x1F || v == 0x7F || v == 0x202E || v == 0x2066 || v == 0x3164 || v == 0x2028,
                               "U+\(String(v, radix: 16)) survived in \(s)")
            }
        }
    }

    // MARK: Show My Jobs (MF3-5)

    override func setUp() {
        super.setUp()
        MotherView.requestedFilterTag = nil
    }

    func testTheContextMenuItemReportsItsFocusThroughOnShowJobs() {
        let focus = dynamicFocus(label: "Fix login")
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        var reported: [Focus] = []
        tabBar.onShowJobs = { reported.append($0) }
        tabBar.setFocuses([focus])

        func items(in v: NSView) -> [NavTabItem] {
            v.subviews.flatMap { ($0 as? NavTabItem).map { [$0] } ?? [] } + v.subviews.flatMap(items(in:))
        }
        guard let menu = items(in: tabBar).first(where: { $0.menu != nil })?.menu,
              let item = menu.items.first(where: { $0.title == "Show My Jobs" }), let action = item.action else {
            return XCTFail("the dynamic focus's context menu has no Show My Jobs item")
        }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(reported.map(\.id), [focus.id])
    }

    func testTheRequestRecordsTheTagBeforeSwitchingThenAnnouncesIt() {
        var order: [String] = []
        let observer = NotificationCenter.default.addObserver(forName: MotherView.showJobsNotification, object: nil, queue: nil) { _ in
            order.append("posted(tag=\(MotherView.requestedFilterTag ?? "nil"))")
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        MotherView.requestShowJobs(tag: "claudia-ABCDEF12") { order.append("switched(tag=\(MotherView.requestedFilterTag ?? "nil"))") }
        XCTAssertEqual(order, ["switched(tag=claudia-ABCDEF12)", "posted(tag=claudia-ABCDEF12)"])
    }

    func testAnUnconsumedRequestExpiresSoALaterViewDoesNotApplyIt() throws {
        let saved = MotherView.requestLifetime
        MotherView.requestLifetime = 0.05
        defer { MotherView.requestLifetime = saved }
        MotherView.requestShowJobs(tag: "claudia-ABCDEF12") {}
        XCTAssertEqual(MotherView.requestedFilterTag, "claudia-ABCDEF12", "still pending for a view about to apply it")
        let expired = expectation(description: "request expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
        XCTAssertNil(MotherView.requestedFilterTag)
        let later = makeVM(try makeStore())
        later.applyShowJobsRequest(isKeyWindow: true)
        XCTAssertEqual(later.filter, .all)
    }

    func testTheFromHeaderKeepsItsClearButtonInsideAt280Points() throws {
        let vm = makeVM(try makeStore())
        let tag = "claudia-ABCDEF12"
        vm.filter = .focus(tag: tag)
        let result = MotherJobFilterResult(
            groups: [], matched: 12, total: 34,
            entries: [MotherOriginFilterEntry(selection: .all, title: "All", count: 34),
                      MotherOriginFilterEntry(selection: .focus(tag: tag), title: String(repeating: "W", count: 40), count: 12)],
            selectionTitle: String(repeating: "W", count: 40))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 24), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MotherFromHeader(vm: vm, result: result))
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        host.layoutSubtreeIfNeeded()

        func find(_ el: Any, label: String, depth: Int = 0) -> NSRect? {
            guard depth < 12 else { return nil }
            if let a = el as? NSAccessibilityElementProtocol, (el as AnyObject).accessibilityLabel?() == label {
                return a.accessibilityFrame?()
            }
            let kids = (el as AnyObject).accessibilityChildren?() ?? []
            for k in kids { if let r = find(k, label: label, depth: depth + 1) { return r } }
            return nil
        }
        let button = try XCTUnwrap(find(host, label: "Show all jobs"), "the clear button is not in the header")
        let hostFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
        XCTAssertLessThanOrEqual(button.maxX, hostFrame.maxX + 0.5, "the clear button stays inside a 280 pt header")
        XCTAssertGreaterThanOrEqual(button.minX, hostFrame.minX)
    }

    func testOnlyTheKeyWindowsListAppliesTheFilterAndEachWindowKeepsItsOwn() throws {
        let store = try makeStore()
        let key = makeVM(store), other = makeVM(store)
        other.filter = .you   // the other window's own filter

        MotherView.requestShowJobs(tag: "claudia-ABCDEF12") {}
        other.applyShowJobsRequest(isKeyWindow: false)
        XCTAssertEqual(other.filter, .you, "a window that is not key leaves its filter alone")
        XCTAssertEqual(key.filter, .all)
        XCTAssertEqual(MotherView.requestedFilterTag, "claudia-ABCDEF12", "a non-key window leaves the request for the key one")

        key.applyShowJobsRequest(isKeyWindow: true)
        XCTAssertEqual(key.filter, .focus(tag: "claudia-ABCDEF12"))
        XCTAssertNil(MotherView.requestedFilterTag, "the request is consumed once applied")
        XCTAssertEqual(other.filter, .you)

        other.applyShowJobsRequest(isKeyWindow: true)
        XCTAssertEqual(other.filter, .you, "nothing pending, nothing changes")
    }
}

// MARK: - The detail's origin line

final class MotherOriginLineTests: XCTestCase {

    // MARK: Helpers

    private func job(repo: String = "Carefeed/payments") -> MotherJob {
        MotherJob(id: "j1", state: "running", repo: repo, isolation: "worktree", title: "A job",
                  createdAt: nil, startedAt: nil, finishedAt: nil, planPath: nil, question: nil,
                  pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    private func note(_ kind: MotherOriginKind, tag: String? = nil, snapshot: String? = nil,
                      focusName: String? = nil) -> MotherJobAnnotation {
        MotherJobAnnotation(origin: MotherOriginView(kind: kind, focusTag: tag, nameSnapshot: snapshot, focusName: focusName))
    }

    private func display(_ kind: MotherOriginKind, tag: String? = nil, snapshot: String? = nil, focusName: String? = nil,
                         open: [String: String] = [:]) -> MotherOriginDisplay {
        MotherOriginDisplay.make(annotation: note(kind, tag: tag, snapshot: snapshot, focusName: focusName),
                                 currentName: { open[$0] })
    }

    private func makeDetail(width: CGFloat = 320, repo: String = "Carefeed/payments") throws -> MotherJobDetail {
        let dir = try PlanTestSupport.tempDirectory(self)
        let frame = NSRect(x: 0, y: 0, width: width, height: 700)
        let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir, frame: frame)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = detail
        addTeardownBlock {
            detail.select(nil)
            window.contentView = nil
            window.close()
        }
        detail.select(job(repo: repo))
        detail.layoutSubtreeIfNeeded()
        return detail
    }

    // MARK: The text

    func testTheLineReadsFromTheOriginThenTheRepo() {
        XCTAssertEqual(MotherOriginLine.text(for: display(.you), repo: "nostromo"), "From You · nostromo")
    }

    func testAClickableOriginCarriesALinkArrow() {
        let d = display(.focus, tag: "t1", snapshot: "Fix login", open: ["t1": "Fix login"])
        XCTAssertEqual(MotherOriginLine.text(for: d, repo: "nostromo"), "From Fix login ↗ · nostromo")
    }

    func testAClosedFocusHasNoArrowAndSaysClosed() {
        let d = display(.focus, tag: "t1", snapshot: "Fix login")
        XCTAssertEqual(MotherOriginLine.text(for: d, repo: "nostromo"), "From Fix login (closed) · nostromo")
    }

    func testAnUnverifiedClaimCarriesItsBadge() {
        let d = display(.unverified, tag: "t1", snapshot: "Claimed")
        XCTAssertEqual(MotherOriginLine.text(for: d, repo: "nostromo"), "From Claimed? (unverified) · nostromo")
    }

    func testAnUnknownOriginReadsAsUnknown() {
        XCTAssertEqual(MotherOriginLine.text(for: .unknown, repo: "nostromo"), "From origin unknown · nostromo")
    }

    func testNoRepoLeavesNoDanglingSeparator() {
        XCTAssertEqual(MotherOriginLine.text(for: display(.you), repo: ""), "From You")
    }

    func testAHostileRepoIsSanitisedAndCapped() {
        let repo = "evil\u{202E}repo\u{1B}[31m\u{0}" + String(repeating: "x", count: 5_000)
        let text = MotherOriginLine.text(for: display(.you), repo: repo)
        XCTAssertLessThan(text.count, 100)
        for scalar in text.unicodeScalars {
            XCTAssertFalse(scalar.value <= 0x1F || scalar.value == 0x202E, "U+\(String(scalar.value, radix: 16)) survived")
        }
    }

    // MARK: The detail shows it

    func testSetOriginShowsTheLineUnderTheTitleWithTheJobsRepo() throws {
        let detail = try makeDetail()
        detail.setOrigin(display(.you), onTap: nil)
        detail.layoutSubtreeIfNeeded()
        XCTAssertEqual(detail.originLine.label.stringValue, "From You · Carefeed/payments")
        XCTAssertFalse(detail.originLine.isHidden)
    }

    func testANonClickableOriginIsALabelNotAButton() throws {
        let detail = try makeDetail()
        for d in [display(.you), .unknown, display(.unverified, tag: "t", snapshot: "C"), display(.focus, tag: "t", snapshot: "Gone")] {
            detail.setOrigin(d, onTap: nil)
            XCTAssertFalse(detail.originLine.label.isHidden, "\(d.text) is text")
            XCTAssertTrue(detail.originLine.button.isHidden, "\(d.text) is not a link")
        }
    }

    func testAClickableOriginIsAButtonAndPressingItCallsTheTap() throws {
        let detail = try makeDetail()
        var taps = 0
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Fix login", open: ["t1": "Fix login"]), onTap: { taps += 1 })
        detail.layoutSubtreeIfNeeded()
        let button = detail.originLine.button
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(detail.originLine.label.isHidden)
        XCTAssertEqual(button.attributedTitle.string, "From Fix login ↗ · Carefeed/payments")
        XCTAssertEqual(taps, 0)
        button.sendAction(button.action, to: button.target)
        XCTAssertEqual(taps, 1)
    }

    func testTheLineCarriesTheTooltipAndTheSpokenForm() throws {
        let detail = try makeDetail()
        let d = display(.unverified, tag: "t", snapshot: "Claimed")
        detail.setOrigin(d, onTap: nil)
        XCTAssertEqual(detail.originLine.label.toolTip, d.tooltip)
        XCTAssertEqual(detail.originLine.label.accessibilityLabel(), d.accessibilityText)
    }

    func testARenameUpdatesTheLineInPlace() throws {
        let detail = try makeDetail()
        let tap: () -> Void = {}
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Before", open: ["t1": "Before"]), onTap: tap)
        XCTAssertEqual(detail.originLine.button.attributedTitle.string, "From Before ↗ · Carefeed/payments")
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Before", open: ["t1": "After"]), onTap: tap)
        XCTAssertEqual(detail.originLine.button.attributedTitle.string, "From After ↗ · Carefeed/payments")
        XCTAssertEqual(detail.originLine.label.stringValue, "From After ↗ · Carefeed/payments")
    }

    func testClosingTheFocusTurnsTheLinkIntoMutedText() throws {
        let detail = try makeDetail()
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Doomed", open: ["t1": "Doomed"]), onTap: {})
        XCTAssertFalse(detail.originLine.button.isHidden)
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Doomed"), onTap: nil)
        XCTAssertTrue(detail.originLine.button.isHidden)
        XCTAssertFalse(detail.originLine.label.isHidden)
        XCTAssertEqual(detail.originLine.label.stringValue, "From Doomed (closed) · Carefeed/payments")
    }

    func testSettingAnEqualOriginAgainDoesNotInvalidateTheLayout() throws {
        let detail = try makeDetail()
        let d = display(.focus, tag: "t1", snapshot: "Same", open: ["t1": "Same"])
        detail.setOrigin(d, onTap: {})
        detail.layoutSubtreeIfNeeded()
        XCTAssertFalse(detail.needsLayout, "precondition: the detail is laid out")
        detail.setOrigin(d, onTap: {})
        XCTAssertFalse(detail.needsLayout, "a progress tick with the same origin must not relayout the detail")
        XCTAssertEqual(detail.originLine.label.stringValue, "From Same ↗ · Carefeed/payments")
    }

    // MARK: Width

    func testTheLineIsVisibleAndFitsInsideANarrowDetail() throws {
        let width: CGFloat = 320
        let detail = try makeDetail(width: width)
        detail.setOrigin(display(.focus, tag: "t1", snapshot: "Fix the login flow", open: ["t1": "Fix the login flow"]), onTap: {})
        detail.layoutSubtreeIfNeeded()
        let line = detail.originLine
        XCTAssertGreaterThan(line.frame.width, 100, "the origin line collapsed to \(line.frame.width) pt: it would show nothing")
        XCTAssertLessThanOrEqual(line.frame.width, width - 32 + 1, "the line overruns the detail's margins")
        XCTAssertGreaterThan(line.frame.height, 0)
    }

    func testAHugeNameTruncatesInsteadOfWideningTheDetail() throws {
        let width: CGFloat = 240
        let huge = "echo " + String(repeating: "x", count: 9_995)
        let detail = try makeDetail(width: width, repo: "Carefeed/payments")
        detail.setOrigin(display(.you), onTap: nil)
        detail.layoutSubtreeIfNeeded()
        let before = detail.fittingSize.width

        detail.setOrigin(display(.focus, tag: "t1", snapshot: huge, open: ["t1": huge]), onTap: {})
        detail.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(detail.originLine.frame.width, width - 32 + 1, "the line is wider than the pane")
        XCTAssertLessThanOrEqual(detail.frame.width, width + 1, "the detail grew to \(detail.frame.width) pt")
        XCTAssertEqual(detail.fittingSize.width, before, accuracy: 1, "a long name must not raise the width the detail demands")
    }

    func testAHugeRepoDoesNotWidenTheDetailEither() throws {
        let width: CGFloat = 240
        let detail = try makeDetail(width: width, repo: String(repeating: "r", count: 9_000))
        detail.setOrigin(display(.you), onTap: nil)
        detail.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(detail.originLine.frame.width, width - 32 + 1)
        XCTAssertLessThanOrEqual(detail.frame.width, width + 1)
    }
}
