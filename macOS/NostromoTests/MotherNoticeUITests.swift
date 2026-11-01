import XCTest
import AppKit
import SwiftUI
import Combine
import NostromoKit

// MotherView, MotherJobDetail, MotherNoticeSwitches, TabBarView, MotherNoticeBell and the job list's view
// model are compiled into this target directly.
//
// MF6: Mother notice UX on the Mac.
//
//   Row mark       `✓` / `⏸` at 220 pt, `✓ told <name>` / `⏸ held` at 400 pt; the row keeps its one
//                  height; the VoiceOver label carries the mark's sentence at every width.
//   Notices        the job detail's Overview section: one summary line, a [Details] toggle, muted
//   section        "Not notified" lines; an equal model again changes and relayouts nothing.
//   Switches       a focus's mode (sidebar menu) and the global bell run HumanGesture.permit first; a
//                  refusal sends nothing, and what the UI shows follows the daemon's state alone.
//   Bell and strip the bell shows once the daemon has reported; the strip says "Session notices off"
//                  only while the daemon says the global switch is off.
//
// No wall clock: relative times come from an injected `now`. Every FocusStore is a throwaway file.
// AppStore.shared is fed through `applyForTesting` only.

// MARK: - Shared fixtures

private let noticeNow = Date(timeIntervalSince1970: 1_800_000_000)

private func noticeMs(minutesAgo m: Double) -> Int64 {
    Int64((noticeNow.timeIntervalSince1970 - m * 60) * 1000)
}

private func toldNotice(minutesAgo m: Double = 4) -> MotherNoticeAnnotation {
    MotherNoticeAnnotation(status: .told, lastState: "succeeded", atMs: noticeMs(minutesAgo: m))
}

private func heldNotice(_ reason: String = "batching") -> MotherNoticeAnnotation {
    MotherNoticeAnnotation(status: .held, reason: reason, atMs: noticeMs(minutesAgo: 1))
}

/// What a switch handed to the daemon client.
private struct SentSetting: Equatable {
    let scope: ClientMotherNoticeSettingsSet.Scope
    let tag: String?
    let mode: MotherNoticeMode?
    let enabled: Bool?
}

private final class SettingRecorder {
    var sent: [SentSetting] = []
    func switches(_ gesture: MotherGestureInputs) -> MotherNoticeSwitches {
        MotherNoticeSwitches(gesture: gesture, send: { [self] scope, tag, mode, enabled in
            sent.append(SentSetting(scope: scope, tag: tag, mode: mode, enabled: enabled))
        })
    }
}

private enum NoticeGesture {
    /// A person: a fresh mouse-up in `window`.
    static func person(in window: NSWindow) -> MotherGestureInputs {
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        return MotherGestureInputs(currentEvent: { event }, voiceOverEnabled: { false }, allowsSynthetic: { false })
    }

    /// Every way the check must refuse, by name.
    static func refusals(in window: NSWindow) -> [(name: String, inputs: MotherGestureInputs)] {
        let synthetic = SyntheticInputGate.stamped(GestureFixtures.key(.keyDown, in: window))
        let stale = GestureFixtures.mouse(.leftMouseUp, in: window,
                                          timestamp: ProcessInfo.processInfo.systemUptime - 5)
        return [
            ("a synthetic event", MotherGestureInputs(currentEvent: { synthetic }, voiceOverEnabled: { false },
                                                      allowsSynthetic: { false })),
            ("a stale event", MotherGestureInputs(currentEvent: { stale }, voiceOverEnabled: { false },
                                                  allowsSynthetic: { false })),
            ("an Accessibility press without VoiceOver", MotherGestureInputs(currentEvent: { nil },
                                                                             voiceOverEnabled: { false },
                                                                             allowsSynthetic: { false })),
        ]
    }

    /// A VoiceOver press: no event, VoiceOver on.
    static var voiceOver: MotherGestureInputs {
        MotherGestureInputs(currentEvent: { nil }, voiceOverEnabled: { true }, allowsSynthetic: { false })
    }
}

private func feed(_ enabled: Bool, focuses: [MotherFocusNoticeState] = []) {
    AppStore.shared.applyForTesting(.motherNoticeState(MotherNoticeStateWire(enabled: enabled, focuses: focuses)))
}

// MARK: - The row's mark

final class MotherNoticeRowTests: XCTestCase {

    // MARK: Helpers

    private let measure: (String) -> CGFloat = { CGFloat($0.count) * 6 }
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeStore() throws -> FocusStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mother-notice-row-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return FocusStore(storageURL: dir.appendingPathComponent("focuses.json"))
    }

    private func origin(_ name: String = "Claudia") -> MotherOriginDisplay {
        MotherOriginDisplay.make(
            annotation: MotherJobAnnotation(origin: MotherOriginView(
                kind: .focus, focusTag: "claudia-ABCDEF12", nameSnapshot: name, focusName: nil)),
            currentName: { _ in nil })
    }

    private func model(_ mark: MotherNoticeMark?, state: String = "succeeded", badges: [String] = [],
                       title: String = "Fix the login flow") -> MotherJobRowModel {
        MotherJobRowModel(
            id: "job-1", state: state, title: title, repo: "nostromo", relativeTimestamp: "12m",
            attentionBadges: badges, showsProgressLine: true, origin: origin(),
            prNumber: 907, cost: "$2.14", noticeMark: mark)
    }

    private func told(name: String = "Claudia") -> MotherNoticeMark {
        MotherNoticeMark.make(notice: toldNotice(), originName: name, now: noticeNow)!
    }

    private func held(_ reason: String = "batching") -> MotherNoticeMark {
        MotherNoticeMark.make(notice: heldNotice(reason), originName: "Claudia", now: noticeNow)!
    }

    private func compose(_ m: MotherJobRowModel, _ width: CGFloat) -> MotherRowLineTwo {
        MotherRowLineTwo.compose(model: m, availableWidth: width, measure: measure)
    }

    private func height(_ m: MotherJobRowModel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: NostromoKit.MotherJobRow(model: m, style: .condensed).frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    // MARK: Narrow and wide

    func testToldRowShowsTheCheckAloneAt220AndTheWordsAt400() {
        let m = model(told())
        XCTAssertEqual(compose(m, 220).notifiedMark, "✓")
        XCTAssertEqual(compose(m, 339).notifiedMark, "✓")
        XCTAssertEqual(compose(m, 340).notifiedMark, "✓ told Claudia")
        XCTAssertEqual(compose(m, 400).notifiedMark, "✓ told Claudia")
        XCTAssertEqual(compose(m, 700).notifiedMark, "✓ told Claudia")
    }

    func testHeldRowShowsThePauseAloneAt220AndHeldAt400() {
        let m = model(held())
        XCTAssertEqual(compose(m, 220).notifiedMark, "⏸")
        XCTAssertEqual(compose(m, 400).notifiedMark, "⏸ held")
    }

    func testAWideMarkThatWouldTakeMoreThanFortyPercentOfTheLineFallsBackToTheGlyph() {
        let longName = String(repeating: "N", count: 24)
        let m = model(told(name: longName))
        XCTAssertEqual(compose(m, 340).notifiedMark, "✓", "a 24-character name does not fit 40% of 340 pt")
        XCTAssertTrue(compose(m, 700).notifiedMark?.hasPrefix("✓ told ") == true, "but it fits a wide line")
    }

    func testARowWithoutANoticeHasNoMarkAtAnyWidth() {
        for w: CGFloat in [220, 340, 700] {
            XCTAssertNil(compose(model(nil), w).notifiedMark, "@\(w)")
        }
    }

    func testTheMarkNeverTakesTheOriginOrTheStateFactOffTheRow() {
        let m = model(told(), badges: ["Needs decision", "Stalled"])
        for w: CGFloat in [220, 259, 260, 339, 340, 400, 700] {
            let line = compose(m, w)
            XCTAssertFalse(line.origin.isEmpty, "origin @\(w)")
            XCTAssertFalse(line.stateFact.isEmpty, "state fact @\(w)")
            XCTAssertNotNil(line.notifiedMark, "mark @\(w)")
        }
    }

    // MARK: One height

    func testTheMarkDoesNotChangeARowsHeightAtAnyWidth() {
        let hostileName = "✓ \u{1B}[31mevil\u{0}⏸" + String(repeating: "W", count: 200)
        for w: CGFloat in [220, 259, 340, 400, 700] {
            let bare = height(model(nil), width: w)
            XCTAssertEqual(bare, MotherRowMetrics.rowHeight, accuracy: 0.5, "precondition @\(w)")
            for (name, mark) in [("told", told()), ("held", held()), ("hostile", told(name: hostileName))] {
                XCTAssertEqual(height(model(mark), width: w), bare, accuracy: 0.5, "\(name) @\(w)")
                XCTAssertEqual(height(model(mark, badges: ["Needs decision", "Stalled"]), width: w), bare,
                               accuracy: 0.5, "\(name) with badges @\(w)")
            }
        }
    }

    // MARK: VoiceOver

    func testTheSpokenLabelAppendsTheMarksSentenceAtEveryWidth() {
        let without = MotherRowLineTwo.accessibilityLabel(model: model(nil))
        let toldLabel = MotherRowLineTwo.accessibilityLabel(model: model(told()))
        XCTAssertTrue(toldLabel.hasPrefix(without), "the mark only adds to the label")
        XCTAssertTrue(toldLabel.hasSuffix("Told Claudia 4 minutes ago."), toldLabel)

        let heldLabel = MotherRowLineTwo.accessibilityLabel(model: model(held("busy")))
        XCTAssertTrue(heldLabel.hasSuffix("Notice held: \(MotherNoticeText.reasonWords("busy"))."), heldLabel)
    }

    // MARK: From a job in the list

    func testAJobFromAnOpenFocusGetsAToldMarkWithItsTooltip() throws {
        let store = try makeStore()
        let focus = Focus(id: "ABCDEF12-0000-4000-8000-000000000001", agentTag: "claudia",
                          projectPath: "/Users/hammer/Code/admin-portal", isBuiltIn: false, org: "Carefeed")
        var named = focus
        named.label = "Fix the login flow"
        store.add(named)
        let job = MotherJob(id: "j1", state: "succeeded", repo: "nostromo", isolation: "worktree", title: "A job",
                            createdAt: nil, startedAt: nil, finishedAt: nil, planPath: nil, question: nil,
                            pausedReason: nil, adherenceStatus: nil, currentTier: nil)
        let vm = MotherJobListViewModel(focusStore: store)
        vm.jobs = [job]
        vm.setAnnotations(["j1": MotherJobAnnotation(
            origin: MotherOriginView(kind: .focus, focusTag: named.sessionTag, nameSnapshot: "Fix the login flow"),
            notice: toldNotice(minutesAgo: 4))])

        let mark = try XCTUnwrap(vm.rowModel(for: job, now: noticeNow).noticeMark)

        XCTAssertEqual(mark.wide, "✓ told Fix the login flow")
        XCTAssertEqual(mark.narrow, "✓")
        XCTAssertTrue(mark.tooltip.hasSuffix("4 minutes ago"), mark.tooltip)
    }

    func testOnlyAVerifiedFocusJobGetsAMarkWhateverItsNoticeSays() throws {
        let store = try makeStore()
        func job(_ id: String) -> MotherJob {
            MotherJob(id: id, state: "succeeded", repo: "nostromo", isolation: "worktree", title: id,
                      createdAt: nil, startedAt: nil, finishedAt: nil, planPath: nil, question: nil,
                      pausedReason: nil, adherenceStatus: nil, currentTier: nil)
        }
        let vm = MotherJobListViewModel(focusStore: store)
        vm.jobs = [job("unverified"), job("you"), job("bare")]
        vm.setAnnotations([
            "unverified": MotherJobAnnotation(origin: MotherOriginView(kind: .unverified, focusTag: "claudia-ABCDEF12",
                                                                       nameSnapshot: "Claimed"), notice: toldNotice()),
            "you": MotherJobAnnotation(origin: MotherOriginView(kind: .you), notice: toldNotice()),
            "bare": MotherJobAnnotation(notice: toldNotice()),
        ])
        for id in ["unverified", "you", "bare"] {
            XCTAssertNil(vm.rowModel(for: job(id), now: noticeNow).noticeMark, id)
        }
    }
}

// MARK: - The detail's Notices section

final class MotherNoticeSectionTests: XCTestCase {

    // MARK: Helpers

    private func job() -> MotherJob {
        MotherJob(id: "j1", state: "succeeded", repo: "Carefeed/payments", isolation: "worktree", title: "A job",
                  createdAt: nil, startedAt: nil, finishedAt: nil, planPath: nil, question: nil,
                  pausedReason: nil, adherenceStatus: nil, currentTier: nil)
    }

    private func makeDetail(width: CGFloat = 320) throws -> MotherJobDetail {
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
        detail.select(job())
        detail.layoutSubtreeIfNeeded()
        return detail
    }

    private func display(_ annotation: MotherJobAnnotation?, open: [String: String] = ["claudia-1": "Claudia"])
        -> MotherOriginDisplay {
        MotherOriginDisplay.make(annotation: annotation, currentName: { open[$0] })
    }

    private func focusJob(notice: MotherNoticeAnnotation?) -> MotherJobAnnotation {
        MotherJobAnnotation(origin: MotherOriginView(kind: .focus, focusTag: "claudia-1", nameSnapshot: "Claudia",
                                                     focusName: "Claudia", closed: false), notice: notice)
    }

    private func model(_ annotation: MotherJobAnnotation?, open: [String: String] = ["claudia-1": "Claudia"])
        -> MotherNoticeSectionModel? {
        MotherNoticeSectionModel.make(annotation: annotation, origin: display(annotation, open: open), now: noticeNow)
    }

    /// A told entry ten minutes ago, then a held one four minutes ago. Built from the wire JSON: the
    /// history entry type has no public initializer, and the wire is the contract anyway.
    private func twoEntryHistory() -> MotherNoticeAnnotation {
        let json = """
        {"status":"told","last_state":"succeeded","at_ms":\(noticeMs(minutesAgo: 4)),
         "history":[
           {"states":["pr_opened"],"status":"told","wake":true,"at_ms":\(noticeMs(minutesAgo: 10))},
           {"states":["succeeded"],"status":"held","reason":"batching","wake":false,"at_ms":\(noticeMs(minutesAgo: 4))}]}
        """
        return try! JSONDecoder().decode(MotherNoticeAnnotation.self, from: Data(json.utf8))
    }

    // MARK: Showing it

    func testAJobWithNoNoticeModelShowsNoSection() throws {
        let detail = try makeDetail()
        XCTAssertTrue(detail.noticeSection.isHidden)
        detail.setNotices(model(focusJob(notice: toldNotice())))
        XCTAssertFalse(detail.noticeSection.isHidden)
        detail.setNotices(nil)
        XCTAssertTrue(detail.noticeSection.isHidden)
    }

    func testEveryOriginKindShowsItsSummary() throws {
        let detail = try makeDetail()
        let cases: [(String, MotherJobAnnotation?, [String: String], muted: Bool)] = [
            ("open focus, told", focusJob(notice: toldNotice()), ["claudia-1": "Claudia"], false),
            ("open focus, held", focusJob(notice: heldNotice()), ["claudia-1": "Claudia"], false),
            ("open focus, nothing sent", focusJob(notice: nil), ["claudia-1": "Claudia"], true),
            ("closed focus", focusJob(notice: toldNotice()), [:], true),
            ("unverified", MotherJobAnnotation(origin: MotherOriginView(kind: .unverified, focusTag: "x",
                                                                        nameSnapshot: "C")), [:], true),
            ("you", MotherJobAnnotation(origin: MotherOriginView(kind: .you)), [:], true),
            ("unknown", MotherJobAnnotation(origin: MotherOriginView(kind: .unknown)), [:], true),
        ]
        var mutedColor: NSColor?
        var normalColor: NSColor?
        for (name, annotation, open, muted) in cases {
            let m = try XCTUnwrap(model(annotation, open: open), name)
            detail.setNotices(m)
            detail.layoutSubtreeIfNeeded()
            let section = detail.noticeSection
            XCTAssertFalse(section.isHidden, name)
            XCTAssertFalse(section.summaryLabel.isHidden, name)
            XCTAssertEqual(section.summaryLabel.stringValue, m.summary, name)
            XCTAssertEqual(section.summaryLabel.accessibilityLabel(), m.summary, name)
            if muted { mutedColor = section.summaryLabel.textColor } else { normalColor = section.summaryLabel.textColor }
            XCTAssertEqual(m.isMuted, muted, name)
        }
        XCTAssertNotEqual(mutedColor, normalColor, "a Not notified line is drawn muted")
    }

    func testAClosedFocusSaysSoInTheSection() throws {
        let detail = try makeDetail()
        detail.setNotices(model(focusJob(notice: toldNotice()), open: [:]))
        XCTAssertEqual(detail.noticeSection.summaryLabel.stringValue,
                       "Not notified: the focus that queued this is closed.")
        XCTAssertTrue(detail.noticeSection.detailsButton.isHidden, "nothing to expand")
    }

    // MARK: Details

    func testDetailsStartClosedAndTheToggleExpandsOneLinePerEntryThenCollapses() throws {
        let detail = try makeDetail()
        let m = try XCTUnwrap(model(focusJob(notice: twoEntryHistory())))
        XCTAssertEqual(m.details.count, 2, "precondition")
        detail.setNotices(m)
        detail.layoutSubtreeIfNeeded()
        let section = detail.noticeSection

        XCTAssertFalse(section.isExpanded)
        XCTAssertFalse(section.detailsButton.isHidden)
        XCTAssertTrue(section.detailsLabel.isHidden)

        section.toggleDetails()
        detail.layoutSubtreeIfNeeded()
        XCTAssertTrue(section.isExpanded)
        XCTAssertFalse(section.detailsLabel.isHidden)
        XCTAssertEqual(section.detailsLabel.stringValue, m.details.joined(separator: "\n"))

        section.toggleDetails()
        detail.layoutSubtreeIfNeeded()
        XCTAssertFalse(section.isExpanded)
        XCTAssertTrue(section.detailsLabel.isHidden)
    }

    func testPressingTheDetailsButtonTogglesToo() throws {
        let detail = try makeDetail()
        detail.setNotices(model(focusJob(notice: twoEntryHistory())))
        let button = detail.noticeSection.detailsButton
        button.sendAction(button.action, to: button.target)
        XCTAssertTrue(detail.noticeSection.isExpanded)
    }

    func testAnEntryLessSectionHasNoDetailsButtonAndToggleDoesNothing() throws {
        let detail = try makeDetail()
        detail.setNotices(model(focusJob(notice: toldNotice())))
        XCTAssertTrue(detail.noticeSection.detailsButton.isHidden)
        detail.noticeSection.toggleDetails()
        XCTAssertFalse(detail.noticeSection.isExpanded)
    }

    func testAnEqualModelAgainKeepsTheExpansionAndRelayoutsNothing() throws {
        let detail = try makeDetail()
        let m = try XCTUnwrap(model(focusJob(notice: twoEntryHistory())))
        detail.setNotices(m)
        detail.noticeSection.toggleDetails()
        detail.layoutSubtreeIfNeeded()
        XCTAssertTrue(detail.noticeSection.isExpanded, "precondition")
        XCTAssertFalse(detail.needsLayout, "precondition: laid out")

        detail.setNotices(try XCTUnwrap(model(focusJob(notice: twoEntryHistory()))))

        XCTAssertTrue(detail.noticeSection.isExpanded, "an unrelated job update must not collapse the details")
        XCTAssertFalse(detail.needsLayout, "an equal model must not invalidate the layout")
    }

    func testAChangedModelUpdatesTheTextInPlace() throws {
        let detail = try makeDetail()
        detail.setNotices(model(focusJob(notice: toldNotice(minutesAgo: 4))))
        let before = detail.noticeSection.summaryLabel.stringValue
        detail.setNotices(model(focusJob(notice: heldNotice())))
        XCTAssertNotEqual(detail.noticeSection.summaryLabel.stringValue, before)
        XCTAssertTrue(detail.noticeSection.summaryLabel.stringValue.contains("held"))
    }

    // MARK: Width

    func testAHostileNameWrapsInsideTheDetailAndNeverWidensIt() throws {
        let width: CGFloat = 240
        let detail = try makeDetail(width: width)
        detail.layoutSubtreeIfNeeded()
        let before = detail.fittingSize.width
        let hostile = "✓⏸ " + String(repeating: "W", count: 400)
        let a = MotherJobAnnotation(
            origin: MotherOriginView(kind: .focus, focusTag: "claudia-1", nameSnapshot: hostile, focusName: hostile),
            notice: twoEntryHistory())

        detail.setNotices(model(a, open: ["claudia-1": hostile]))
        detail.noticeSection.toggleDetails()
        detail.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(detail.noticeSection.frame.width, width - 32 + 1)
        XCTAssertLessThanOrEqual(detail.frame.width, width + 1)
        XCTAssertEqual(detail.fittingSize.width, before, accuracy: 1)
        XCTAssertFalse(detail.noticeSection.summaryLabel.stringValue.contains("✓"))
    }
}

// MARK: - The switches

final class MotherNoticeSwitchesTests: XCTestCase {

    private var window: NSWindow!
    private var control: NSButton!
    private let rec = SettingRecorder()

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow()
        control = GestureFixtures.control(in: window)
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    // MARK: Accepted

    func testAPersonsClickSendsExactlyOneFocusFrameWithTheTagAndMode() {
        let switches = rec.switches(NoticeGesture.person(in: window))
        XCTAssertTrue(switches.setFocusMode(tag: "claudia-1", mode: .quiet, control: control, menuSelection: false))
        XCTAssertEqual(rec.sent, [SentSetting(scope: .focus, tag: "claudia-1", mode: .quiet, enabled: nil)])
    }

    func testEachModeGoesOutAsItself() {
        let switches = rec.switches(NoticeGesture.person(in: window))
        for mode in [MotherNoticeMode.wake, .quiet, .off] {
            switches.setFocusMode(tag: "t", mode: mode, control: control, menuSelection: false)
        }
        XCTAssertEqual(rec.sent.map(\.mode), [.wake, .quiet, .off])
    }

    func testAVoiceOverPressIsAPerson() {
        let switches = rec.switches(NoticeGesture.voiceOver)
        XCTAssertTrue(switches.setFocusMode(tag: "t", mode: .off, control: control, menuSelection: false))
        XCTAssertTrue(switches.setGlobal(enabled: false, control: control))
        XCTAssertEqual(rec.sent.count, 2)
    }

    func testAMenuSelectionAcceptsTheMouseEventThatTrackedTheMenu() {
        let other = GestureFixtures.offscreenWindow()
        defer { other.close() }
        let tracking = GestureFixtures.mouse(.leftMouseUp, in: other)
        let inputs = MotherGestureInputs(currentEvent: { tracking }, voiceOverEnabled: { false }, allowsSynthetic: { false })
        let switches = rec.switches(inputs)

        XCTAssertTrue(switches.setFocusMode(tag: "t", mode: .quiet, control: control, menuSelection: true))
        XCTAssertFalse(switches.setFocusMode(tag: "t", mode: .quiet, control: control, menuSelection: false),
                       "without menuSelection an event for another window is not a person")
        XCTAssertEqual(rec.sent.count, 1)
    }

    func testTheGlobalSwitchSendsAGlobalFrameWithTheEnabledValueOnly() {
        let switches = rec.switches(NoticeGesture.person(in: window))
        XCTAssertTrue(switches.setGlobal(enabled: false, control: control))
        XCTAssertTrue(switches.setGlobal(enabled: true, control: control))
        XCTAssertEqual(rec.sent, [SentSetting(scope: .global, tag: nil, mode: nil, enabled: false),
                                  SentSetting(scope: .global, tag: nil, mode: nil, enabled: true)])
    }

    // MARK: Refused

    func testARefusedGestureSendsNothingAndSaysSo() {
        for (name, inputs) in NoticeGesture.refusals(in: window) {
            let switches = rec.switches(inputs)
            XCTAssertFalse(switches.setFocusMode(tag: "t", mode: .off, control: control, menuSelection: false), name)
            XCTAssertFalse(switches.setFocusMode(tag: "t", mode: .off, control: control, menuSelection: true), name)
            XCTAssertFalse(switches.setGlobal(enabled: false, control: control), name)
        }
        XCTAssertTrue(rec.sent.isEmpty, "a refused gesture changes nothing: \(rec.sent)")
    }

    func testAFutureStampedEventIsRefusedToo() {
        let future = GestureFixtures.mouse(.leftMouseUp, in: window,
                                           timestamp: ProcessInfo.processInfo.systemUptime + 60)
        let inputs = MotherGestureInputs(currentEvent: { future }, voiceOverEnabled: { false }, allowsSynthetic: { false })
        XCTAssertFalse(rec.switches(inputs).setGlobal(enabled: false, control: control))
        XCTAssertTrue(rec.sent.isEmpty)
    }
}

// MARK: - The sidebar menu

final class MotherNoticeMenuTests: XCTestCase {

    private var window: NSWindow!
    private let rec = SettingRecorder()
    private var mode: MotherNoticeMode = .wake

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 300, height: 500))
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func focus() -> Focus {
        Focus(id: "ABCDEF12-0000-4000-8000-000000000001", agentTag: "claudia",
              projectPath: "/Users/hammer/Code/admin-portal", isBuiltIn: false, org: "Carefeed")
    }

    private func items(in v: NSView) -> [NavTabItem] {
        v.subviews.flatMap { ($0 as? NavTabItem).map { [$0] } ?? [] } + v.subviews.flatMap(items(in:))
    }

    /// The sidebar with one dynamic focus, its context menu, and the Mother Notices submenu.
    private func rig(_ gesture: MotherGestureInputs) throws -> (tabBar: TabBarView, menu: NSMenu, sub: NSMenu, focus: Focus) {
        let f = focus()
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: 220, height: 400))
        window.contentView!.addSubview(tabBar)
        tabBar.noticeSwitches = rec.switches(gesture)
        tabBar.noticeMode = { [unowned self] _ in self.mode }
        tabBar.setFocuses([f])
        let menu = try XCTUnwrap(items(in: tabBar).first { $0.menu != nil }?.menu, "the focus has a context menu")
        let item = try XCTUnwrap(menu.items.first { $0.title == "Mother Notices" }, "the menu has Mother Notices")
        let sub = try XCTUnwrap(item.submenu)
        return (tabBar, menu, sub, f)
    }

    private func checked(_ sub: NSMenu) -> [String] { sub.items.filter { $0.state == .on }.map(\.title) }

    private func reopen(_ menu: NSMenu) { menu.delegate?.menuNeedsUpdate?(menu) }

    // MARK: Shape

    func testTheSubmenuOffersWakeQuietAndOffAndChecksTheDaemonsMode() throws {
        let r = try rig(NoticeGesture.person(in: window))
        XCTAssertEqual(r.sub.items.map(\.title), ["Wake", "Quiet", "Off"])
        XCTAssertEqual(checked(r.sub), ["Wake"], "a focus the daemon has no entry for is on Wake")
    }

    func testTheCheckmarkFollowsTheDaemonEachTimeTheMenuOpens() throws {
        let r = try rig(NoticeGesture.person(in: window))
        mode = .quiet
        reopen(r.menu)
        XCTAssertEqual(checked(r.sub), ["Quiet"])
        mode = .off
        reopen(r.menu)
        XCTAssertEqual(checked(r.sub), ["Off"])
        mode = .other("turbo")
        reopen(r.menu)
        XCTAssertEqual(checked(r.sub), [], "a mode this build does not know checks nothing")
    }

    // MARK: Accepted

    func testAPersonsChoiceSendsExactlyOneFrameForThatFocusAndMode() throws {
        let r = try rig(NoticeGesture.person(in: window))
        let quiet = try XCTUnwrap(r.sub.items.first { $0.title == "Quiet" })

        r.tabBar.noticeModeTapped(quiet)

        XCTAssertEqual(rec.sent, [SentSetting(scope: .focus, tag: r.focus.sessionTag, mode: .quiet, enabled: nil)])
    }

    func testEachItemSendsItsOwnMode() throws {
        let r = try rig(NoticeGesture.person(in: window))
        for title in ["Wake", "Quiet", "Off"] {
            r.tabBar.noticeModeTapped(try XCTUnwrap(r.sub.items.first { $0.title == title }))
        }
        XCTAssertEqual(rec.sent.map(\.mode), [.wake, .quiet, .off])
    }

    func testAcceptingAChoiceDoesNotMoveTheCheckmarkUntilTheDaemonSaysSo() throws {
        let r = try rig(NoticeGesture.person(in: window))
        r.tabBar.noticeModeTapped(try XCTUnwrap(r.sub.items.first { $0.title == "Off" }))
        reopen(r.menu)
        XCTAssertEqual(checked(r.sub), ["Wake"], "the daemon's mode has not changed")
        mode = .off
        reopen(r.menu)
        XCTAssertEqual(checked(r.sub), ["Off"])
    }

    // MARK: Refused

    func testARefusedChoiceSendsNothingAndTheCheckmarkStaysOnTheOldMode() throws {
        for (name, inputs) in NoticeGesture.refusals(in: window) {
            rec.sent = []
            mode = .wake
            let r = try rig(inputs)
            r.tabBar.noticeModeTapped(try XCTUnwrap(r.sub.items.first { $0.title == "Off" }))
            reopen(r.menu)

            XCTAssertTrue(rec.sent.isEmpty, "\(name): sent \(rec.sent)")
            XCTAssertEqual(checked(r.sub), ["Wake"], "\(name): the checkmark moved without the daemon")
            r.tabBar.removeFromSuperview()
        }
    }
}

// MARK: - Bell and off strip

final class MotherNoticeBellTests: XCTestCase {

    private var window: NSWindow!
    private let rec = SettingRecorder()

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 800, height: 600))
    }

    override func tearDown() {
        window.close()
        window = nil
        // AppStore.shared has no way back to "no state yet"; leave it as the default (on, no focuses).
        feed(true)
        super.tearDown()
    }

    private func bell(_ gesture: MotherGestureInputs) -> MotherNoticeBell {
        let b = MotherNoticeBell()
        window.contentView!.addSubview(b)
        b.switches = rec.switches(gesture)
        return b
    }

    private func strip() -> MotherNoticesOffStrip {
        let s = MotherNoticesOffStrip()
        window.contentView!.addSubview(s)
        return s
    }

    // MARK: Bell

    func testTheBellIsShownOnceTheDaemonHasReportedAState() {
        feed(true)
        XCTAssertFalse(bell(NoticeGesture.person(in: window)).isHidden)
    }

    func testPressingTheBellWhileOnSendsAGlobalOffFrame() {
        feed(true)
        let b = bell(NoticeGesture.person(in: window))
        XCTAssertTrue(b.isOn)
        b.pressed()
        XCTAssertEqual(rec.sent, [SentSetting(scope: .global, tag: nil, mode: nil, enabled: false)])
        XCTAssertTrue(b.isOn, "the bell redraws only when the daemon says so")
    }

    func testPressingTheBellWhileOffSendsAGlobalOnFrame() {
        feed(false)
        let b = bell(NoticeGesture.person(in: window))
        XCTAssertFalse(b.isOn)
        b.pressed()
        XCTAssertEqual(rec.sent, [SentSetting(scope: .global, tag: nil, mode: nil, enabled: true)])
    }

    func testARefusedBellPressSendsNothingAndChangesNothing() {
        feed(true)
        for (name, inputs) in NoticeGesture.refusals(in: window) {
            let b = bell(inputs)
            b.pressed()
            XCTAssertTrue(rec.sent.isEmpty, "\(name): sent \(rec.sent)")
            XCTAssertTrue(b.isOn, name)
        }
    }

    func testTheBellFollowsTheDaemonsStateWhenItChanges() {
        feed(true)
        let b = bell(NoticeGesture.person(in: window))
        feed(false)
        XCTAssertTrue(MD.pumpUntil(window) { !b.isOn }, "the bell shows Off once the daemon says Off")
        feed(true)
        XCTAssertTrue(MD.pumpUntil(window) { b.isOn })
    }

    func testTheBellHasASpokenNameAndValue() {
        feed(false)
        let b = bell(NoticeGesture.person(in: window))
        XCTAssertFalse((b.accessibilityLabel() ?? "").isEmpty)
        XCTAssertEqual(b.accessibilityValue() as? String, "Off")
    }

    // MARK: Off strip

    func testTheStripSaysSessionNoticesOffOnlyWhileTheGlobalSwitchIsOff() {
        feed(false)
        let off = strip()
        XCTAssertFalse(off.isHidden)
        XCTAssertEqual(off.label.stringValue, "Session notices off")
        XCTAssertEqual(off.label.accessibilityLabel(), "Session notices are off. Sessions are not told about their jobs.")
        XCTAssertEqual(off.fittingSize.height, 24, accuracy: 0.5)

        feed(true)
        let on = strip()
        XCTAssertTrue(on.isHidden)
        XCTAssertEqual(on.fittingSize.height, 0, accuracy: 0.5, "it takes no room while notices are on")
    }

    func testTheStripAppearsAndGoesAwayWithTheDaemonsState() {
        feed(true)
        let s = strip()
        XCTAssertTrue(s.isHidden)
        feed(false)
        XCTAssertTrue(MD.pumpUntil(window) { !s.isHidden })
        feed(true)
        XCTAssertTrue(MD.pumpUntil(window) { s.isHidden })
    }

    func testTheMotherPaneShowsTheStripAndTheBellFromTheDaemonsState() throws {
        let suite = UserDefaults(suiteName: "MotherNoticeBellTests.\(UUID().uuidString)")!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        defer { MotherView.widthDefaults = previous }
        feed(false)
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let all = MD.allSubviews(view)
        let paneStrip = try XCTUnwrap(all.compactMap { $0 as? MotherNoticesOffStrip }.first)
        let paneBell = try XCTUnwrap(all.compactMap { $0 as? MotherNoticeBell }.first)

        XCTAssertFalse(paneStrip.isHidden)
        XCTAssertFalse(paneBell.isOn)

        feed(true)
        XCTAssertTrue(MD.pumpUntil(window) { paneStrip.isHidden && paneBell.isOn })
        view.removeFromSuperview()
    }
}
