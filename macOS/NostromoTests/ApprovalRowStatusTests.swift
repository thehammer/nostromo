import XCTest
import AppKit
import Combine
import NostromoKit

// AP2b: a tool call's permission request, in place on its transcript row; one card paged `1 of 3`; the same
// request in two windows; and the production-shell guard's bar.
//
// These tests pin behaviour from outside, the way a person (or `nostromo-app`) sees it: the strings a row's
// suffix field shows, its frame, the pulse on its dot, the card's page text and buttons, the bar's line and
// where it sits. They never read private state. Time is injected: the store's timers (the 2 s outcome and the
// 60 s bar) are closures `ApprovalRecorder` holds for a test to run by hand; no sleeps, no wall clock.
//
// Contents:
//   * `ApprovalAP2bFixtures`: frames and requests the daemon would send.
//   * `ApprovalStatusStoreTests`: the store's row statuses, the bound, and the guard notice (no AppKit).
//   * `ApprovalRowStatusRowTests`: the tool row (`ToolGroupRowView`, `ToolGroupView`, `ChatTurnView`).
//   * `ApprovalActivityHeaderStatusTests`: the Focus view's activity header row.
//   * `ApprovalPagingHostTests`: `1 of 3`, ‹ ›, answering each request on its own.
//   * `ApprovalTwoWindowTests`: one request in two windows.
//   * `ApprovalGuardBarTests`: the bar over the card slot.
//   * `ApprovalAP2bSourceScanTests`: nothing here adds a menu item, a key equivalent, a focus change or an announcement.

private typealias F = FoldFixtures

// MARK: - What the daemon would send

enum ApprovalAP2bFixtures {

    static let atMs: UInt64 = 1_760_000_123_456

    static func guardBlocked(tag: String = "cody-1", toolUseId: String = "toolu_g", entryId: String = "entry-1",
                             atMs: UInt64 = ApprovalAP2bFixtures.atMs,
                             summary: String = "Bash tmux") throws -> ApprovalGuardBlockedFrame {
        let json: [String: Any] = ["tag": tag, "tool_use_id": toolUseId, "entry_id": entryId,
                                   "at_ms": NSNumber(value: atMs), "summary": summary]
        return try JSONDecoder().decode(ApprovalGuardBlockedFrame.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func resolved(id: String, outcome: String, tag: String = "cody-1", byWindow: String? = "w-other",
                         atMs: UInt64 = ApprovalAP2bFixtures.atMs) throws -> ApprovalResolvedFrame {
        var json: [String: Any] = ["tag": tag, "request_id": id, "outcome": outcome, "at_ms": NSNumber(value: atMs)]
        if let byWindow = byWindow { json["by_window"] = byWindow }
        return try JSONDecoder().decode(ApprovalResolvedFrame.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// A one-line Bash request for the call `toolUseId` (the stock builders name the call `toolu_<id>`).
    static func request(id: String, toolUseId: String, tag: String = "cody-1") throws -> ApprovalRequestWire {
        let command = "rm -rf build/"
        let root: [String: Any] = [
            "request_id": id,
            "tag": tag,
            "tool_use_id": toolUseId,
            "agent": ["name": "cody"] as [String: Any],
            "tool_name": "Bash",
            "display_name": "Bash",
            "tool_kind": "bash",
            "input": ["command": command] as [String: Any],
            "display": ApprovalTestRequests.display(lines: ApprovalTestRequests.plainBashLines(command), commandCount: 1),
            "reason": ["kind": "ask_rule", "text": "your rule Bash(rm:*) in ~/.claude/settings.json"] as [String: Any],
            "flags": ["default_to_no": false, "suppress_always_allow_rule": false,
                      "requires_user_interaction": false, "classifier_approvable": false] as [String: Any],
            "options": ApprovalTestRequests.allOptions,
            "session_rule_candidates": [Any](),
            "created_at_ms": 1_760_000_000_000,
            "deadline_at_ms": NSNumber(value: ApprovalTestRequests.freshDeadlineMs()),
        ]
        return try JSONDecoder().decode(ApprovalRequestWire.self, from: JSONSerialization.data(withJSONObject: root))
    }

    /// The text a row shows for an approval at `atMs`: `approved by you · HH:mm` in the local zone.
    static func approvedPattern() -> String { "^· approved by you \u{00B7} [0-2][0-9]:[0-5][0-9]$" }
}

/// Records what a `PassthroughSubject` sent.
final class ApprovalTap<Value> {
    private(set) var values: [Value] = []
    private var subscription: AnyCancellable?

    init(_ subject: PassthroughSubject<Value, Never>) {
        subscription = subject.sink { [unowned self] in self.values.append($0) }
    }
}

private func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - The store

final class ApprovalStatusStoreTests: XCTestCase {

    private func make() -> (ApprovalStore, ApprovalRecorder) {
        let recorder = ApprovalRecorder()
        return (recorder.makeStore(), recorder)
    }

    private func request(_ store: ApprovalStore, _ id: String, tag: String = "cody-1") throws {
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: id, tag: tag)))
    }

    private func resolve(_ store: ApprovalStore, _ id: String, _ outcome: String, atMs: UInt64 = ApprovalAP2bFixtures.atMs,
                         tag: String = "cody-1") throws {
        store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: id, outcome: outcome, tag: tag, atMs: atMs)))
    }

    // MARK: Awaiting

    func testARequestMakesItsCallAwaitingAndTellsTheRowsAndTheFocus() throws {
        let (store, _) = make()
        let statuses = ApprovalTap(store.statusChanges)
        let changes = ApprovalTap(store.changes)

        try request(store, "a")

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .awaiting)
        XCTAssertEqual(statuses.values, ["toolu_a"], "the call's rows are told, by tool_use_id")
        XCTAssertEqual(changes.values, ["cody-1"], "and the focus, as before")
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
    }

    func testACallThatWasNeverAskedAboutHasNoStatus() throws {
        let (store, _) = make()
        try request(store, "a")
        XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_other"]))
        XCTAssertNil(store.rowStatus(toolUseIds: []))
    }

    func testARowOverSeveralCallsReadsAwaitingWhileAnyOfThemWaits() throws {
        let (store, _) = make()
        try request(store, "a")
        try request(store, "b")
        try resolve(store, "b", "allowed_once")

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a", "toolu_b"]), .awaiting)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_b", "toolu_a"]), .awaiting, "the order of the list does not matter")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_b"]), .approved(atMs: ApprovalAP2bFixtures.atMs))
    }

    // MARK: Resolved

    func testAResolvedRequestRecordsItsOutcomeAtItsTimeAndTellsTheRows() throws {
        let cases: [(outcome: String, status: ApprovalRowStatus)] = [
            ("allowed_once", .approved(atMs: ApprovalAP2bFixtures.atMs)),
            ("answered", .approved(atMs: ApprovalAP2bFixtures.atMs)),
            ("denied", .deniedByYou),
            ("denied_and_stopped", .deniedByYou),
            ("timed_out", .deniedNoAnswer),
            ("no_app", .deniedAppClosed),
            ("restart", .deniedRestarted),
            ("restart_crash", .deniedRestarted),
            ("approval_unavailable", .deniedUnavailable),
            ("invalid_request", .deniedUnreadable),
            ("guard_blocked", .blockedByGuard),
            ("allowed_by_session_rule", .allowedBySessionRule),
            ("allowed_by_your_rule", .allowedByYourRule),
        ]
        for (outcome, status) in cases {
            let (store, _) = make()
            try request(store, "a")
            let statuses = ApprovalTap(store.statusChanges)

            try resolve(store, "a", outcome)

            XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), status, outcome)
            XCTAssertEqual(statuses.values, ["toolu_a"], "\(outcome): the row is told once")
        }
    }

    func testAnApprovalReadsTheTimeTheDaemonSaidNotTheTimeItArrived() throws {
        let (store, _) = make()
        try request(store, "a")
        try resolve(store, "a", "allowed_once", atMs: 1_234_567)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .approved(atMs: 1_234_567))
    }

    func testARequestWithdrawnCancelledOrEndedInAnUnknownWayLeavesTheCallWithNoStatus() throws {
        for outcome in ["withdrawn", "cancelled", "deny_write_failed", "too_large", "something_new"] {
            let (store, _) = make()
            try request(store, "a")
            try request(store, "keep")
            let statuses = ApprovalTap(store.statusChanges)

            try resolve(store, "a", outcome)

            XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_a"]), "\(outcome): the row says nothing")
            XCTAssertEqual(statuses.values, ["toolu_a"], "\(outcome): the row that said awaiting is told")
            XCTAssertEqual(store.statusCount(tag: "cody-1"), 1, "\(outcome): only the other call is kept")
            XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_keep"]), .awaiting)
        }
    }

    func testTheStatusSurvivesTheEntryBeingDroppedTwoSecondsLater() throws {
        let (store, recorder) = make()
        try request(store, "a")
        try resolve(store, "a", "denied")
        XCTAssertNotNil(store.entry(id: "a"), "precondition: the outcome is still on the card")

        recorder.runScheduled()

        XCTAssertNil(store.entry(id: "a"), "the card's entry is gone")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedByYou, "the row's status is not")
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
    }

    func testAResolvedFrameForAnUnknownRequestChangesNothingAndTellsNoRow() throws {
        let (store, _) = make()
        try request(store, "a")
        let statuses = ApprovalTap(store.statusChanges)

        try resolve(store, "ghost", "denied")

        XCTAssertTrue(statuses.values.isEmpty)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .awaiting)
        XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_ghost"]))
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
    }

    func testTheFirstEndingStands() throws {
        let (store, _) = make()
        try request(store, "a")
        try resolve(store, "a", "denied")
        try resolve(store, "a", "timed_out")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedByYou)
    }

    // MARK: Snapshot

    func testASnapshotMakesWhatItHoldsAwaiting() throws {
        let (store, _) = make()
        let statuses = ApprovalTap(store.statusChanges)

        store.handle(.snapshot([try ApprovalTestRequests.simpleRm(id: "a"), try ApprovalTestRequests.simpleRm(id: "b")]))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .awaiting)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_b"]), .awaiting)
        XCTAssertEqual(Set(statuses.values), ["toolu_a", "toolu_b"])
    }

    func testAnAwaitingCallWhoseRequestTheSnapshotDropsIsForgottenAndItsRowIsTold() throws {
        let (store, _) = make()
        try request(store, "a")
        try request(store, "b")
        let statuses = ApprovalTap(store.statusChanges)

        store.handle(.snapshot([try ApprovalTestRequests.simpleRm(id: "b")]))

        XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_a"]), "the daemon no longer holds it: the row stops saying awaiting")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_b"]), .awaiting)
        XCTAssertTrue(statuses.values.contains("toolu_a"))
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
    }

    func testASnapshotDoesNotForgetACallThatAlreadyHasAnOutcome() throws {
        let (store, recorder) = make()
        try request(store, "a")
        try resolve(store, "a", "denied")
        try request(store, "b")
        try resolve(store, "b", "allowed_once")
        recorder.runScheduled()

        store.handle(.snapshot([]))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedByYou)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_b"]), .approved(atMs: ApprovalAP2bFixtures.atMs))
    }

    // MARK: Refusals

    func testAnAnswerRefusedAsUnknownForAnAwaitingCallForgetsItsStatus() throws {
        let (store, _) = make()
        try request(store, "a")
        XCTAssertTrue(store.answer("a", ApprovalDecisionWire(kind: .deny), windowID: "w1"))
        let statuses = ApprovalTap(store.statusChanges)

        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "unknown_request")))

        XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_a"]), "the daemon never held it: nothing to wait for")
        XCTAssertTrue(statuses.values.contains("toolu_a"))
    }

    func testAnAnswerRefusedAsAlreadyResolvedAfterTheResolvedFrameLeavesTheFirstEndingStanding() throws {
        let (store, _) = make()
        try request(store, "a")
        XCTAssertTrue(store.answer("a", ApprovalDecisionWire(kind: .allowOnce), windowID: "w1"))

        try resolve(store, "a", "timed_out")
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "already_resolved", outcome: "denied")))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedNoAnswer, "the resolved frame came first and stands")
    }

    func testAnAnswerRefusedAsAlreadyResolvedBeforeTheResolvedFrameSeedsTheStatusFromItsOutcome() throws {
        let (store, _) = make()
        try request(store, "a")
        XCTAssertTrue(store.answer("a", ApprovalDecisionWire(kind: .allowOnce), windowID: "w1"))
        let statuses = ApprovalTap(store.statusChanges)

        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "already_resolved", outcome: "timed_out")))
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedNoAnswer, "the refusal says how it ended")
        XCTAssertEqual(statuses.values, ["toolu_a"], "and the row is told")

        try resolve(store, "a", "timed_out")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedNoAnswer)
    }

    func testALostResolvedFrameCannotLeaveTheCallAwaitingForEver() throws {
        let (store, _) = make()
        try request(store, "a")
        XCTAssertTrue(store.answer("a", ApprovalDecisionWire(kind: .allowOnce), windowID: "w1"))

        // The resolved frame never arrives; only the refusal does.
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "already_resolved", outcome: "denied")))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .deniedByYou)
    }

    func testARefusalWithoutAnOutcomeOrWithAnUnknownOneStopsTheAwaitingToo() throws {
        for outcome in [nil, "something_new"] as [String?] {
            let (store, _) = make()
            try request(store, "a")
            store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "already_resolved", outcome: outcome)))
            XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_a"]), "outcome \(outcome ?? "nil"): the row stops saying awaiting")
        }
    }

    func testARefusalThatIsNotAboutAlreadyResolvedLeavesTheCallAwaiting() throws {
        let (store, _) = make()
        try request(store, "a")
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: "invalid_answer", outcome: "denied")))
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_a"]), .awaiting)
    }

    func testALateFrameForAnOldRequestDoesNotOverwriteTheNewRequestsWaitOnAReusedToolUseId() throws {
        let (store, _) = make()
        store.handle(.request(try ApprovalAP2bFixtures.request(id: "r1", toolUseId: "toolu_same")))
        try resolve(store, "r1", "denied")                      // r1's entry lingers for two seconds
        store.handle(.request(try ApprovalAP2bFixtures.request(id: "r2", toolUseId: "toolu_same")))
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_same"]), .awaiting)

        try resolve(store, "r1", "allowed_once")                // a late duplicate for r1
        store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "r1", code: "already_resolved", outcome: "allowed_once")))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_same"]), .awaiting, "r2 is still waiting")

        try resolve(store, "r2", "allowed_once")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_same"]), .approved(atMs: ApprovalAP2bFixtures.atMs))
    }

    // MARK: Bounded (T-AP2b-2)

    func testSixHundredRequestsResolvedThroughTheStoreKeepTheNewestFiveHundredForTheFocus() throws {
        let (store, _) = make()
        for i in 0 ..< 600 {
            try request(store, "r\(i)")
            try resolve(store, "r\(i)", "denied")
        }

        XCTAssertEqual(store.statusCount(tag: "cody-1"), 500)
        for i in 0 ..< 100 { XCTAssertNil(store.rowStatus(toolUseIds: ["toolu_r\(i)"]), "toolu_r\(i) is the oldest: gone") }
        for i in 100 ..< 600 { XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_r\(i)"]), .deniedByYou, "toolu_r\(i) remains") }
    }

    func testAnotherFocusHasItsOwnFiveHundred() throws {
        let (store, _) = make()
        for i in 0 ..< 3 {
            try request(store, "ada\(i)", tag: "ada-1")
            try resolve(store, "ada\(i)", "denied", tag: "ada-1")
        }
        for i in 0 ..< 600 {
            try request(store, "c\(i)")
            try resolve(store, "c\(i)", "denied")
        }

        XCTAssertEqual(store.statusCount(tag: "cody-1"), 500)
        XCTAssertEqual(store.statusCount(tag: "ada-1"), 3, "a busy focus does not evict another's")
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_ada0"]), .deniedByYou)
    }

    // MARK: The guard (no card)

    func testAGuardBlockMarksItsCallBlockedAndCreatesNoRequestAndNoCard() throws {
        let (store, _) = make()
        let statuses = ApprovalTap(store.statusChanges)
        let changes = ApprovalTap(store.changes)

        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_g")))

        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_g"]), .blockedByGuard)
        XCTAssertEqual(statuses.values, ["toolu_g"])
        XCTAssertEqual(changes.values, ["cody-1"], "the focus is told so the bar can show")
        XCTAssertTrue(store.visible(tag: "cody-1").isEmpty, "no entry, so no card, ever")
        XCTAssertNil(store.current(tag: "cody-1"))
        XCTAssertEqual(store.pendingCount(tag: "cody-1"), 0)
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
    }

    func testAGuardBlockGivesTheFocusANoticeForTheBar() throws {
        let (store, _) = make()
        XCTAssertNil(store.guardNotice(tag: "cody-1"))

        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(entryId: "e1", summary: "Bash ecs_connect")))

        let notice = try XCTUnwrap(store.guardNotice(tag: "cody-1"))
        XCTAssertEqual(notice.frame.summary, "Bash ecs_connect")
        XCTAssertEqual(notice.frame.toolUseId, "toolu_g")
        XCTAssertNil(store.guardNotice(tag: "ada-1"), "another focus has none")
    }

    func testTheBarHidesItselfAfterAMinuteAndTellsTheFocus() throws {
        let (store, recorder) = make()
        let changes = ApprovalTap(store.changes)
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked()))
        XCTAssertEqual(ApprovalStore.guardBarVisibleSeconds, 60)
        XCTAssertEqual(recorder.scheduled.map { $0.delay }, [60], "the store schedules its own removal")
        let before = changes.values.count

        recorder.runScheduled()

        XCTAssertNil(store.guardNotice(tag: "cody-1"))
        XCTAssertEqual(Array(changes.values.dropFirst(before)), ["cody-1"])
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_g"]), .blockedByGuard, "the row keeps saying so")
    }

    func testANewerBlockReplacesTheNoticeAndTheOldTimerDoesNotClearIt() throws {
        let (store, recorder) = make()
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_1", entryId: "e1", summary: "Bash tmux")))
        let oldTimer = try XCTUnwrap(recorder.scheduled.first { $0.delay == 60 })
        recorder.scheduled = []

        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_2", entryId: "e2", summary: "Bash ecs_connect")))
        let newTimer = try XCTUnwrap(recorder.scheduled.first { $0.delay == 60 })
        XCTAssertEqual(store.guardNotice(tag: "cody-1")?.frame.summary, "Bash ecs_connect", "the newer block replaced it")

        oldTimer.work()
        XCTAssertEqual(store.guardNotice(tag: "cody-1")?.frame.summary, "Bash ecs_connect", "the old minute ending does not clear the new notice")

        newTimer.work()
        XCTAssertNil(store.guardNotice(tag: "cody-1"))
    }

    func testClosingTheBarClearsItAndTellsTheFocus() throws {
        let (store, _) = make()
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked()))
        let changes = ApprovalTap(store.changes)

        store.dismissGuardNotice(tag: "cody-1")

        XCTAssertNil(store.guardNotice(tag: "cody-1"))
        XCTAssertEqual(changes.values, ["cody-1"])
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_g"]), .blockedByGuard, "closing the bar does not unsay what the row says")
    }

    func testABlockAfterTheBarWasClosedShowsAgainAndTheOldTimerLeavesItAlone() throws {
        let (store, recorder) = make()
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(entryId: "e1")))
        let oldTimer = try XCTUnwrap(recorder.scheduled.first { $0.delay == 60 })
        store.dismissGuardNotice(tag: "cody-1")

        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_h", entryId: "e2")))
        oldTimer.work()

        XCTAssertEqual(store.guardNotice(tag: "cody-1")?.frame.entryId, "e2")
    }

    func testARepeatOfTheSameBlockAfterTheBarWasClosedDoesNotShowItAgain() throws {
        let (store, recorder) = make()
        let frame = try ApprovalAP2bFixtures.guardBlocked(entryId: "e1")
        store.handle(.guardBlocked(frame))
        store.dismissGuardNotice(tag: "cody-1")
        let changes = ApprovalTap(store.changes)
        recorder.scheduled = []

        store.handle(.guardBlocked(frame))

        XCTAssertNil(store.guardNotice(tag: "cody-1"), "the closed bar stays closed")
        XCTAssertTrue(changes.values.isEmpty)
        XCTAssertTrue(recorder.scheduled.isEmpty, "and no new minute is started")
    }

    func testARepeatOfTheSameBlockAfterTheBarHidItselfDoesNotShowItAgain() throws {
        let (store, recorder) = make()
        let frame = try ApprovalAP2bFixtures.guardBlocked(entryId: "e1")
        store.handle(.guardBlocked(frame))
        recorder.runScheduled()
        XCTAssertNil(store.guardNotice(tag: "cody-1"), "precondition")

        store.handle(.guardBlocked(frame))

        XCTAssertNil(store.guardNotice(tag: "cody-1"))
    }

    func testABlockForOneFocusLeavesAnotherFocusAlone() throws {
        let (store, _) = make()
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(tag: "cody-1", toolUseId: "toolu_1", entryId: "e1")))
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(tag: "ada-1", toolUseId: "toolu_2", entryId: "e2")))

        store.dismissGuardNotice(tag: "cody-1")

        XCTAssertNil(store.guardNotice(tag: "cody-1"))
        XCTAssertEqual(store.guardNotice(tag: "ada-1")?.frame.entryId, "e2")
        XCTAssertEqual(store.statusCount(tag: "cody-1"), 1)
        XCTAssertEqual(store.statusCount(tag: "ada-1"), 1)
    }
}

// MARK: - The tool row

/// Shared helpers: a window, a row, a store, a clock-free way to feed it.
class ApprovalRowTestCase: XCTestCase {

    let reading = ApprovalAP2bFixtures.atMs

    func makeStore() -> (ApprovalStore, ApprovalRecorder) {
        let recorder = ApprovalRecorder()
        return (recorder.makeStore(), recorder)
    }

    func request(_ store: ApprovalStore, _ id: String, tag: String = "cody-1") throws {
        store.handle(.request(try ApprovalTestRequests.simpleRm(id: id, tag: tag)))
    }

    func resolve(_ store: ApprovalStore, _ id: String, _ outcome: String, atMs: UInt64 = ApprovalAP2bFixtures.atMs,
                 tag: String = "cody-1") throws {
        store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: id, outcome: outcome, tag: tag, atMs: atMs)))
    }

    /// Settled calls with the tool_use_ids `ids` (`toolu_a` for the request `a`).
    func settledGroup(_ ids: [String]) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for id in ids {
            blocks.append(F.foldCall("Bash", id: id, summary: "cmd \(id)", full: F.bashInput("cmd \(id)")))
            blocks.append(F.foldResult(id: id))
        }
        return F.group(blocks)
    }

    /// The last call has no result yet: the group is running.
    func runningGroup(_ ids: [String]) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for (i, id) in ids.enumerated() {
            blocks.append(F.foldCall("Bash", id: id, summary: "cmd \(id)", full: F.bashInput("cmd \(id)"), start: Double(i)))
            if i < ids.count - 1 { blocks.append(F.foldResult(id: id, time: Double(i) + 0.5)) }
        }
        return F.group(blocks, outcome: .open)
    }

    func makeRow(_ group: ToolGroup, store: ApprovalStore?, width: CGFloat = 600, reduceMotion: Bool = false,
                 window provided: RigWindow? = nil) -> (RigWindow, ToolGroupRowView) {
        let window = provided ?? makeRigWindow(self, size: NSSize(width: 800, height: 200))
        let row = ToolGroupRowView(group: group, isExpanded: false, payloadAvailable: true,
                                   reduceMotion: { reduceMotion }, now: { F.at(0) }, approvals: store)
        row.frame = NSRect(x: 20, y: 100, width: width, height: FoldRowView.height)
        window.contentView!.addSubview(row)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, row)
    }

    func shown(_ row: FoldRowView) -> String { row.approvalField.isHidden ? "" : row.approvalField.stringValue }

    func fields(_ row: FoldRowView) -> [String] {
        [row.summaryField.stringValue, row.badgeField.stringValue, row.timeField.stringValue, row.stoppedField.stringValue]
            + [row.badgeField.isHidden, row.timeField.isHidden, row.stoppedField.isHidden].map { String($0) }
    }
}

final class ApprovalRowStatusRowTests: ApprovalRowTestCase {

    // MARK: What the row says

    func testARowForACallAwaitingApprovalSaysSo() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        XCTAssertFalse(row.approvalField.isHidden)
        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval")
        XCTAssertEqual(row.approvalField.accessibilityLabel(), "awaiting your approval", "VoiceOver reads the words, not the bullet")
    }

    func testARowWithNoStatusShowsNothing() throws {
        let (store, _) = makeStore()
        try request(store, "other")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        XCTAssertTrue(row.approvalField.isHidden)
        XCTAssertEqual(row.approvalField.stringValue, "")
    }

    func testARowBuiltWithoutAStoreNeverShowsAnything() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: nil)

        XCTAssertTrue(row.approvalField.isHidden)
        try resolve(store, "a", "denied")
        XCTAssertTrue(row.approvalField.isHidden, "even when the call has a status elsewhere")
        XCTAssertEqual(row.approvalField.stringValue, "")
    }

    func testEveryOutcomeReadsItsWordsOnTheRow() throws {
        let cases: [(outcome: String, text: String?)] = [
            ("denied", "· denied by you"),
            ("denied_and_stopped", "· denied by you"),
            ("timed_out", "· denied: no answer in 15 min"),
            ("no_app", "· denied: Nostromo closed"),
            ("restart", "· denied: Nostromo restarted"),
            ("restart_crash", "· denied: Nostromo restarted"),
            ("approval_unavailable", "· denied: approvals unavailable"),
            ("invalid_request", "· denied: unreadable request"),
            ("guard_blocked", "· blocked: production-shell guard"),
            ("allowed_by_session_rule", "· allowed by session rule"),
            ("allowed_by_your_rule", "· allowed by your rule"),
            ("withdrawn", nil),
            ("cancelled", nil),
            ("something_new", nil),
        ]
        for (outcome, text) in cases {
            let (store, _) = makeStore()
            try request(store, "a")
            let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
            XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval", "\(outcome): precondition")

            try resolve(store, "a", outcome)

            XCTAssertEqual(shown(row), text ?? "", outcome)
            XCTAssertEqual(row.approvalField.isHidden, text == nil, "\(outcome): hidden when there is nothing to say")
            XCTAssertEqual(row.approvalField.accessibilityLabel(), text.map { String($0.dropFirst(2)) },
                           "\(outcome): the label is the text without the bullet")
        }
    }

    func testAnApprovalReadsTheTimeOnA24HourClock() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        try resolve(store, "a", "allowed_once", atMs: reading)

        XCTAssertTrue(matches(row.approvalField.stringValue, ApprovalAP2bFixtures.approvedPattern()), row.approvalField.stringValue)
        let label = try XCTUnwrap(row.approvalField.accessibilityLabel())
        XCTAssertTrue(label.hasPrefix("approved by you"), label)
        XCTAssertFalse(label.hasPrefix("·"), "no bullet in the VoiceOver label")
    }

    func testAnAnsweredQuestionReadsAsApprovedToo() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        try resolve(store, "a", "answered")

        XCTAssertTrue(matches(row.approvalField.stringValue, ApprovalAP2bFixtures.approvedPattern()), row.approvalField.stringValue)
    }

    func testARowStopsSayingAwaitingWhenTheRequestIsWithdrawnOrTheDaemonNoLongerHoldsIt() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        XCTAssertFalse(row.approvalField.isHidden, "precondition")

        store.handle(.snapshot([]))

        XCTAssertTrue(row.approvalField.isHidden)
        XCTAssertEqual(row.approvalField.stringValue, "")
    }

    // MARK: Which calls a row reads

    func testAnAwaitingCallWinsOverAnApprovedOneInTheSameGroup() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        try request(store, "b")
        try resolve(store, "b", "allowed_once")
        let (_, row) = makeRow(settledGroup(["toolu_a", "toolu_b"]), store: store)

        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval")
    }

    func testWhenNoCallIsAwaitingTheRowReadsTheLatest() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        try request(store, "b")
        try resolve(store, "a", "allowed_once")
        try resolve(store, "b", "denied")
        let (_, row) = makeRow(settledGroup(["toolu_a", "toolu_b"]), store: store)

        XCTAssertEqual(row.approvalField.stringValue, "· denied by you")
    }

    func testADeniedCallKeepsTheGroupFromReadingApprovedWhicheverCameLast() throws {
        for order in [["a", "b"], ["b", "a"]] {
            let (store, _) = makeStore()
            try request(store, "a")
            try request(store, "b")
            try resolve(store, order[0] == "a" ? "a" : "b", "denied")
            try resolve(store, order[1] == "a" ? "a" : "b", "allowed_once")
            let (_, row) = makeRow(settledGroup(["toolu_a", "toolu_b"]), store: store)

            XCTAssertEqual(row.approvalField.stringValue, "· denied by you", "denied first: \(order[0])")
        }
    }

    func testACallWithNoToolUseIdIsIgnored() throws {
        let (store, _) = makeStore()
        try request(store, "b")
        let anonymous = FoldBlock.toolCall(FoldCall(name: "Bash", toolUseId: nil, inputSummary: "mystery", inputFull: F.bashInput("mystery")))
        let group = F.group([anonymous, F.foldCall("Bash", id: "toolu_b", summary: "cmd b", full: F.bashInput("cmd b")), F.foldResult(id: "toolu_b")])
        let (_, row) = makeRow(group, store: store)
        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval", "the call that has an id still counts")

        let onlyAnonymous = F.group([anonymous])
        let (_, alone) = makeRow(onlyAnonymous, store: store)
        XCTAssertTrue(alone.approvalField.isHidden, "a group of calls with no id reads nothing")
    }

    func testARowReadsTheStatusAlreadyRecordedWhenItIsBuilt() throws {
        let (store, recorder) = makeStore()
        try request(store, "a")
        try resolve(store, "a", "denied")
        recorder.runScheduled()

        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        XCTAssertEqual(row.approvalField.stringValue, "· denied by you", "a row scrolled back into view says what happened")
    }

    func testARowUpdatesInPlaceWhenItsCallChanges() throws {
        let (store, _) = makeStore()
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        XCTAssertTrue(row.approvalField.isHidden)

        try request(store, "a")
        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval")
        try resolve(store, "a", "timed_out")
        XCTAssertEqual(row.approvalField.stringValue, "· denied: no answer in 15 min")
    }

    func testARowIgnoresChangesToOtherCalls() throws {
        let (store, _) = makeStore()
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)

        try request(store, "elsewhere")
        try resolve(store, "elsewhere", "denied")

        XCTAssertTrue(row.approvalField.isHidden)
    }

    func testUpdatingTheRowsGroupReadsTheNewCallsStatus() throws {
        let (store, _) = makeStore()
        try request(store, "b")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        XCTAssertTrue(row.approvalField.isHidden)

        row.update(group: settledGroup(["toolu_a", "toolu_b"]))

        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval")
        row.update(group: settledGroup(["toolu_a"]))
        XCTAssertTrue(row.approvalField.isHidden, "and drops it when the call is no longer in the group")
    }

    func testAGuardBlockedCallReadsBlockedOnItsRow() throws {
        let (store, _) = makeStore()
        let (_, row) = makeRow(settledGroup(["toolu_g"]), store: store)

        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_g")))

        XCTAssertEqual(row.approvalField.stringValue, "· blocked: production-shell guard")
    }

    func testTwoRowsForTheSameCallInTwoWindowsBothUpdateFromOneEvent() throws {
        let (store, _) = makeStore()
        let (_, first) = makeRow(settledGroup(["toolu_a"]), store: store)
        let (_, second) = makeRow(settledGroup(["toolu_a"]), store: store)

        try request(store, "a")
        XCTAssertEqual(first.approvalField.stringValue, "· awaiting your approval")
        XCTAssertEqual(second.approvalField.stringValue, "· awaiting your approval")

        try resolve(store, "a", "denied")
        XCTAssertEqual(first.approvalField.stringValue, "· denied by you")
        XCTAssertEqual(second.approvalField.stringValue, "· denied by you")
    }

    func testARowMaterialisedLaterInAnotherWindowShowsTheStatusAlreadyRecorded() throws {
        let (store, recorder) = makeStore()
        let (_, first) = makeRow(settledGroup(["toolu_a"]), store: store)
        try request(store, "a")
        try resolve(store, "a", "denied")
        recorder.runScheduled()

        let (_, later) = makeRow(settledGroup(["toolu_a"]), store: store)

        XCTAssertEqual(first.approvalField.stringValue, "· denied by you")
        XCTAssertEqual(later.approvalField.stringValue, "· denied by you")
    }

    // MARK: Subagent calls

    /// 0 Agent call, 1 the subagent's call, 2 its result, 3 the Agent's own result.
    private var agentTurn: ChatTurn {
        F.turn([F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
                F.call("Bash", id: "toolu_sub", summary: "grep -r foo", parent: "toolu_agent"),
                F.result("foo.txt", id: "toolu_sub", parent: "toolu_agent"),
                F.result("report", id: "toolu_agent")])
    }

    func testAGroupViewReadsTheStatusOfACallItsSubagentMade() throws {
        let turn = agentTurn
        let group = try XCTUnwrap(F.groups(of: turn).first)
        XCTAssertFalse(group.subagentBlocks.isEmpty, "precondition: the sub call hangs under the Agent call")
        let (store, _) = makeStore()
        try request(store, "sub")

        let view = ToolGroupView(group: group, blocks: turn.blocks, contentAvailable: true,
                                 folds: FoldResolver(), isExpanded: false, approvals: store)

        XCTAssertEqual(view.row.approvalField.stringValue, "· awaiting your approval", "the subagent's request shows on the Agent's row")
        try resolve(store, "sub", "denied")
        XCTAssertEqual(view.row.approvalField.stringValue, "· denied by you", "and follows it in place")
    }

    func testAGroupViewPicksUpASubagentCallThatArrivesLater() throws {
        let early = F.turn([F.call("Agent", id: "toolu_agent", summary: "explore the repo")], complete: false)
        let (store, _) = makeStore()
        try request(store, "sub")
        let view = ToolGroupView(group: try XCTUnwrap(F.groups(of: early).first), blocks: early.blocks, contentAvailable: true,
                                 folds: FoldResolver(), isExpanded: false, approvals: store)
        XCTAssertTrue(view.row.approvalField.isHidden, "precondition: the subagent has not shown its call yet")

        let later = agentTurn
        _ = view.update(group: try XCTUnwrap(F.groups(of: later).first), blocks: later.blocks)

        XCTAssertEqual(view.row.approvalField.stringValue, "· awaiting your approval")
    }

    func testATurnViewBuiltWithTheStoreShowsStatusOnItsToolRows() throws {
        let turn = F.turn(F.run(2, prefix: "toolu_c"))
        let (store, _) = makeStore()
        try request(store, "c1")
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState(), approvals: store)
        view.setIslandWidth(900)

        let rows = rigAllSubviews(of: view).compactMap { ($0 as? ToolGroupView)?.row }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.approvalField.stringValue, "· awaiting your approval")

        try resolve(store, "c1", "allowed_once")
        XCTAssertTrue(matches(rows.first?.approvalField.stringValue ?? "", ApprovalAP2bFixtures.approvedPattern()))
    }

    // MARK: Nothing else about the row changes

    func testApprovalsChangeNeitherTheSummaryNorTheTimeNorTheFailureNorTheStoppedFields() throws {
        let group = F.failingGroup()
        let ids = group.calls.compactMap(\.toolUseId)
        XCTAssertFalse(ids.isEmpty)
        let (_, plain) = makeRow(group, store: nil)
        let (store, _) = makeStore()
        let (_, withStore) = makeRow(group, store: store)
        XCTAssertEqual(fields(withStore), fields(plain), "precondition: a store with nothing in it changes nothing")

        for (i, id) in ids.enumerated() {
            let requestId = "r\(i)"
            store.handle(.request(try ApprovalAP2bFixtures.request(id: requestId, toolUseId: id)))
            XCTAssertEqual(fields(withStore), fields(plain), "awaiting: \(id)")
            try resolve(store, requestId, "denied")
            XCTAssertEqual(fields(withStore), fields(plain), "denied: \(id)")
        }
        XCTAssertEqual(withStore.approvalField.stringValue, "· denied by you")
    }

    func testTheRowStaysOneControlAndAClickOnTheStatusTogglesItLikeAClickAnywhere() throws {
        let (store, recorder) = makeStore()
        try request(store, "a")
        let (window, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        var toggles: [Bool] = []
        row.onToggle = { toggles.append($0) }
        let rect = row.approvalField.convert(row.approvalField.bounds, to: nil)

        try AppControlMouse.click(in: window, at: NSPoint(x: rect.midX, y: rect.midY))

        XCTAssertEqual(toggles, [true], "the whole row is one control: the click toggled it")
        XCTAssertTrue(recorder.sent.isEmpty, "and answered nothing")
        XCTAssertEqual(store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(row.approvalField.stringValue, "· awaiting your approval")
    }

    // MARK: Height (the row is a fixed 22 pt)

    private enum Step {
        case request(String)
        case resolve(String, String)
        case block(String)
        case regroup([String])
    }

    func testTheRowKeepsItsHeightAndItsFrameThroughEveryStatusInAWideRowAndANarrowOne() throws {
        for width in [CGFloat(700), CGFloat(260)] {
            let (store, _) = makeStore()
            let ids = ["toolu_a", "toolu_b", "toolu_c", "toolu_d"]
            let (window, row) = makeRow(settledGroup(ids), store: store, width: width)
            window.contentView!.layoutSubtreeIfNeeded()
            let baseFrame = row.frame
            let baseFitting = row.fittingSize.height
            XCTAssertEqual(baseFrame.height, 22, "precondition")
            XCTAssertEqual(FoldRowView.height, 22)

            let steps: [(String, Step, String?)] = [
                ("awaiting", .request("a"), "· awaiting your approval"),
                ("approved", .resolve("a", "allowed_once"), nil),
                ("denied", .request("b"), nil),
                ("denied", .resolve("b", "denied"), "· denied by you"),
                ("timed out", .request("c"), nil),
                ("timed out", .resolve("c", "timed_out"), "· denied: no answer in 15 min"),
                ("blocked", .block("toolu_d"), "· blocked: production-shell guard"),
                ("none", .regroup(["toolu_unrelated"]), ""),
            ]
            for (name, step, expected) in steps {
                switch step {
                case .request(let id): try request(store, id)
                case .resolve(let id, let outcome): try resolve(store, id, outcome)
                case .block(let toolUseId): store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: toolUseId)))
                case .regroup(let newIds): row.update(group: settledGroup(newIds))
                }
                window.contentView!.layoutSubtreeIfNeeded()
                let at = "\(name) at \(Int(width)) pt"
                if let expected = expected { XCTAssertEqual(shown(row), expected, at) }
                XCTAssertEqual(row.frame, baseFrame, "\(at): the row's own frame is untouched")
                XCTAssertEqual(row.frame.height, 22, at)
                XCTAssertEqual(row.fittingSize.height, baseFitting, accuracy: 0.5, "\(at): the row asks for the same height")
                if !row.approvalField.isHidden {
                    let field = row.approvalField
                    XCTAssertLessThanOrEqual(field.frame.maxX, row.bounds.maxX + 0.5, "\(at): the status stays inside the row")
                    if width >= 700 {
                        XCTAssertGreaterThanOrEqual(field.frame.width, field.intrinsicContentSize.width - 0.5,
                                                    "\(at): in a wide row the status keeps its full text width")
                    }
                    XCTAssertEqual(field.frame.height, field.intrinsicContentSize.height, accuracy: 2, at)
                }
            }
        }
    }

    func testInAWideRowTheStatusFitsInsideTheRowAndTheSummaryGivesWayBeforeIt() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store, width: 700)
        XCTAssertLessThanOrEqual(row.approvalField.frame.maxX, row.bounds.maxX + 0.5)
        XCTAssertGreaterThan(row.approvalField.frame.minX, row.summaryField.frame.minX)
    }

    func testInANarrowPaneTheLongestStatusStaysInsideTheRowAndTruncatesAtTheTail() throws {
        let (store, _) = makeStore()
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_a")))
        let (window, row) = makeRow(settledGroup(["toolu_a"]), store: store, width: 260)
        window.contentView!.layoutSubtreeIfNeeded()
        let field = row.approvalField

        XCTAssertEqual(shown(row), "· blocked: production-shell guard")
        XCTAssertLessThanOrEqual(field.frame.maxX, row.bounds.maxX + 0.5, "the field is inside the row, not spilling past its edge")
        XCTAssertGreaterThanOrEqual(field.frame.minX, row.bounds.minX)
        XCTAssertEqual(field.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(row.frame.height, 22, "the row keeps its height")
        XCTAssertGreaterThan(field.frame.width, 0)
    }

    func testAStatusChangeAsksNothingOfTheRowsGroupView() throws {
        let (store, _) = makeStore()
        let group = settledGroup(["toolu_a"])
        let blocks: [TurnBlock] = [F.call("Bash", id: "toolu_a", summary: "cmd a"), F.result("ok", id: "toolu_a")]
        let view = ToolGroupView(group: group, blocks: blocks, contentAvailable: true, folds: FoldResolver(),
                                 isExpanded: false, approvals: store)
        view.setFrameSize(NSSize(width: 600, height: view.row.frame.height))
        view.layoutSubtreeIfNeeded()
        var heightChanges = 0
        view.onHeightChange = { heightChanges += 1 }
        let frame = view.frame, rowFrame = view.row.frame

        try request(store, "a")
        try resolve(store, "a", "allowed_once")
        store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(toolUseId: "toolu_a")))
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(heightChanges, 0, "no layout request escapes a status change")
        XCTAssertEqual(view.frame, frame)
        XCTAssertEqual(view.row.frame, rowFrame)
    }

    // MARK: The activity dot

    func testWhileACallAwaitsApprovalTheDotStaysButDoesNotPulseAndResumesWhenItMovesOn() throws {
        let (store, _) = makeStore()
        let (_, row) = makeRow(runningGroup(["toolu_a"]), store: store)
        XCTAssertTrue(row.isShowingActivity, "precondition: a running group shows its dot")
        XCTAssertNotNil(row.activityLayer.animation(forKey: "pulse"), "precondition: and pulses")

        try request(store, "a")
        XCTAssertTrue(row.isShowingActivity, "the dot is still the running signal")
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"), "but it is not a spinner while a person is being asked")

        try resolve(store, "a", "allowed_once")
        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNotNil(row.activityLayer.animation(forKey: "pulse"), "the call is running again: the pulse resumes")
    }

    func testARowBuiltWhileACallAwaitsDoesNotPulse() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(runningGroup(["toolu_a"]), store: store)

        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"))
    }

    func testARowUpdatedWhileACallAwaitsStillDoesNotPulse() throws {
        let (store, _) = makeStore()
        try request(store, "b")
        let (_, row) = makeRow(runningGroup(["toolu_a"]), store: store)
        XCTAssertNotNil(row.activityLayer.animation(forKey: "pulse"), "precondition")

        row.update(group: runningGroup(["toolu_a", "toolu_b"]))

        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"))
    }

    func testARowThatWasWithdrawnOutOfAwaitingPulsesAgain() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(runningGroup(["toolu_a"]), store: store)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"), "precondition")

        store.handle(.snapshot([]))

        XCTAssertNotNil(row.activityLayer.animation(forKey: "pulse"))
    }

    func testWithReduceMotionTheDotNeverPulsesWhateverTheStatus() throws {
        let (store, _) = makeStore()
        let (_, row) = makeRow(runningGroup(["toolu_a"]), store: store, reduceMotion: true)
        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"))

        try request(store, "a")
        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"))

        try resolve(store, "a", "allowed_once")
        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"), "resuming never starts a pulse under Reduce Motion")
    }

    func testASettledRowHasNoDotWhateverItsStatus() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, row) = makeRow(settledGroup(["toolu_a"]), store: store)
        XCTAssertFalse(row.isShowingActivity)
        try resolve(store, "a", "allowed_once")
        XCTAssertFalse(row.isShowingActivity)
    }
}

// MARK: - The Focus view's activity header

final class ApprovalActivityHeaderStatusTests: ApprovalRowTestCase {

    private func makeHeader(_ group: ToolGroup, store: ApprovalStore?, width: CGFloat = 600) -> (RigWindow, ActivityRowHeaderView) {
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 200))
        let segment = ActivitySegment(key: "a:\(group.key)", members: [.group(group)])
        let header = ActivityRowHeaderView(segment: segment, isExpanded: false, payloadAvailable: true,
                                           reduceMotion: { false }, approvals: store)
        header.frame = NSRect(x: 20, y: 100, width: width, height: FoldRowView.height)
        window.contentView!.addSubview(header)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, header)
    }

    func testTheActivityRowReadsTheStatusOfItsCalls() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, header) = makeHeader(settledGroup(["toolu_a", "toolu_b"]), store: store)

        XCTAssertEqual(header.approvalField.stringValue, "· awaiting your approval")
        XCTAssertEqual(header.approvalField.accessibilityLabel(), "awaiting your approval")
    }

    func testTheActivityRowUpdatesInPlaceAndKeepsItsHeight() throws {
        let (store, _) = makeStore()
        let (window, header) = makeHeader(settledGroup(["toolu_a"]), store: store, width: 160)
        let frame = header.frame
        let fitting = header.fittingSize.height
        XCTAssertTrue(header.approvalField.isHidden)

        try request(store, "a")
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.approvalField.stringValue, "· awaiting your approval")
        XCTAssertEqual(header.frame, frame)
        XCTAssertEqual(header.fittingSize.height, fitting, accuracy: 0.5)

        try resolve(store, "a", "denied")
        window.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.approvalField.stringValue, "· denied by you")
        XCTAssertEqual(header.frame, frame)
        XCTAssertEqual(header.fittingSize.height, fitting, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(header.approvalField.frame.width, header.approvalField.intrinsicContentSize.width - 0.5)
    }

    func testTheActivityRowReadsTheNewSegmentWhenItIsUpdated() throws {
        let (store, _) = makeStore()
        try request(store, "b")
        let (_, header) = makeHeader(settledGroup(["toolu_a"]), store: store)
        XCTAssertTrue(header.approvalField.isHidden)

        let grown = settledGroup(["toolu_a", "toolu_b"])
        header.update(segment: ActivitySegment(key: "a:\(grown.key)", members: [.group(grown)]))

        XCTAssertEqual(header.approvalField.stringValue, "· awaiting your approval")
    }

    func testAnActivityRowWithoutAStoreShowsNothing() throws {
        let (store, _) = makeStore()
        try request(store, "a")
        let (_, header) = makeHeader(settledGroup(["toolu_a"]), store: nil)
        XCTAssertTrue(header.approvalField.isHidden)
    }
}

// MARK: - A host in a window

/// A host over a pane, with an optional composer holding focus, for the store the test supplies or its own.
final class ApprovalPane {
    let recorder: ApprovalRecorder
    let store: ApprovalStore
    let window: RigWindow
    let host: ApprovalOverlayHost
    let composer: NSTextView?

    init(_ testCase: XCTestCase, store provided: ApprovalStore? = nil, recorder providedRecorder: ApprovalRecorder? = nil,
         tag: String = "cody-1", windowID: String = "w-test", agentName: (() -> String?)? = { "Cody" },
         size: NSSize = NSSize(width: 640, height: 500), withComposer: Bool = false) {
        let recorder = providedRecorder ?? ApprovalRecorder()
        let store = provided ?? recorder.makeStore()
        let window = makeRigWindow(testCase, size: size)
        var composer: NSTextView?
        if withComposer {
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
            window.contentView!.addSubview(view)
            view.string = "half a thought"
            _ = window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 2, length: 4))
            composer = view
        }
        let host = ApprovalOverlayHost(tag: tag, store: store, agentName: agentName, windowID: { windowID },
                                       permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true },
                                       reduceMotion: { true })
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView!.addSubview(host)
        self.recorder = recorder
        self.store = store
        self.window = window
        self.host = host
        self.composer = composer
        layout()
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func arrive(_ request: ApprovalRequestWire) {
        store.handle(.request(request))
        layout()
    }

    func arrive(_ ids: [String], tag: String = "cody-1") throws {
        for id in ids { store.handle(.request(try ApprovalTestRequests.simpleRm(id: id, tag: tag))) }
        layout()
    }

    /// The composer still holds focus, its text and its selection.
    func assertComposerUntouched(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let composer = composer else { return XCTFail("no composer", file: file, line: line) }
        XCTAssertTrue(window.firstResponder === composer, "\(message): the composer keeps focus", file: file, line: line)
        XCTAssertEqual(composer.string, "half a thought", "\(message): its text", file: file, line: line)
        XCTAssertEqual(composer.selectedRange(), NSRange(location: 2, length: 4), "\(message): its selection", file: file, line: line)
    }
}

// MARK: - Paging (criterion 35)

final class ApprovalPagingHostTests: XCTestCase {

    private func deny() -> ApprovalDecisionWire { ApprovalDecisionWire(kind: .deny) }

    func testThreeRequestsForOneFocusShowOneCardPagedOneOfThree() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])

        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(p.host.subviews.filter { $0 is ApprovalCardView }.count, 1, "one card for the focus")
        XCTAssertEqual(card.request.id, "a", "the oldest first")
        XCTAssertEqual(card.pageText, "1 of 3")
        XCTAssertEqual(p.host.page?.label, "1 of 3")
        XCTAssertEqual(p.host.listings.first?.page, 1)
        XCTAssertEqual(p.host.listings.first?.of, 3)
        XCTAssertEqual(card.pagePreviousButton.isEnabled, false, "nothing before the first")
        XCTAssertEqual(card.pageNextButton.isEnabled, true)
        XCTAssertEqual(card.pagePreviousButton.isHidden, false)
        XCTAssertEqual(card.pageNextButton.isHidden, false)
    }

    func testShowingTheNextRequestAnswersNothingAndTheLastPageHasNoNext() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])

        p.host.showNext()
        p.layout()
        var card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "b")
        XCTAssertEqual(card.pageText, "2 of 3")
        XCTAssertEqual(card.pagePreviousButton.isEnabled, true)
        XCTAssertEqual(card.pageNextButton.isEnabled, true)
        XCTAssertEqual(p.host.listings.first?.requestID, "b")
        XCTAssertEqual(p.host.listings.first?.page, 2)

        p.host.showNext()
        p.layout()
        card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "c")
        XCTAssertEqual(card.pageText, "3 of 3")
        XCTAssertEqual(card.pagePreviousButton.isEnabled, true)
        XCTAssertEqual(card.pageNextButton.isEnabled, false, "no wrap past the last")

        p.host.showNext()
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "c", "Next on the last page does nothing")
        XCTAssertEqual(p.host.card?.pageText, "3 of 3")

        XCTAssertTrue(p.recorder.sent.isEmpty, "paging sends nothing")
        for id in ["a", "b", "c"] { XCTAssertEqual(p.store.entry(id: id)?.state, ApprovalAnswerState.pending, id) }
    }

    func testShowingThePreviousRequestWalksBackAndStopsAtTheFirst() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        p.host.showNext(); p.host.showNext()
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "c", "precondition")

        p.host.showPrevious(); p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b")
        XCTAssertEqual(p.host.card?.pageText, "2 of 3")
        p.host.showPrevious(); p.layout()
        XCTAssertEqual(p.host.card?.request.id, "a")
        XCTAssertEqual(p.host.card?.pageText, "1 of 3")
        p.host.showPrevious(); p.layout()
        XCTAssertEqual(p.host.card?.request.id, "a", "no wrap before the first")
        XCTAssertTrue(p.recorder.sent.isEmpty)
    }

    func testThePageButtonsPageTheHost() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])

        try XCTUnwrap(p.host.card?.pageNextButton).performClick(nil)
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b")
        XCTAssertEqual(p.host.card?.pageText, "2 of 3")

        try XCTUnwrap(p.host.card?.pagePreviousButton).performClick(nil)
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "a")
        XCTAssertTrue(p.recorder.sent.isEmpty, "pressing ‹ or › answers nothing")
    }

    func testAPageButtonAsksForTheNeighbouringRequest() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(id: "y"))
        var asked: [String] = []
        h.card.onShowRequest = { asked.append($0) }
        h.card.setPage(ApprovalPage(position: 2, count: 3, previousID: "p", nextID: "n", currentID: "y"))
        h.relayout()
        XCTAssertEqual(h.card.pageText, "2 of 3")

        try XCTUnwrap(h.card.pageNextButton).performClick(nil)
        try XCTUnwrap(h.card.pagePreviousButton).performClick(nil)

        XCTAssertEqual(asked, ["n", "p"])
        XCTAssertTrue(h.recorder.sent.isEmpty)
    }

    func testADisabledPageButtonAsksForNothing() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(id: "y"))
        var asked: [String] = []
        h.card.onShowRequest = { asked.append($0) }
        h.card.setPage(ApprovalPage(position: 1, count: 2, previousID: nil, nextID: "n", currentID: "y"))

        try XCTUnwrap(h.card.pagePreviousButton).performClick(nil)

        XCTAssertEqual(asked, [])
    }

    func testTheCardSaysNothingOfPagesAgainWhenTheyAreCleared() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(id: "y"))
        h.card.setPage(ApprovalPage(position: 1, count: 3, previousID: nil, nextID: "n", currentID: "y"))
        XCTAssertEqual(h.card.pageText, "1 of 3", "precondition")

        h.card.setPage(nil)

        XCTAssertEqual(h.card.pageText, "")
        XCTAssertTrue(h.card.pagePreviousButton.isHidden)
        XCTAssertTrue(h.card.pageNextButton.isHidden)
        XCTAssertEqual(h.card.listing.page, 1)
        XCTAssertEqual(h.card.listing.of, 1)
    }

    func testALoneRequestShowsNoPageTextAndNoPageButtons() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a"])

        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.pageText, "")
        XCTAssertTrue(card.pagePreviousButton.isHidden, "no ‹")
        XCTAssertTrue(card.pageNextButton.isHidden, "no ›")
        XCTAssertNil(p.host.page.flatMap { $0.count > 1 ? $0 : nil }, "nothing to page through")
        XCTAssertEqual(p.host.listings.first?.page, 1)
        XCTAssertEqual(p.host.listings.first?.of, 1)
        let visible = ApprovalTestViews.buttons(in: card, visibleOnly: true).map(\.title)
        XCTAssertFalse(visible.contains("‹") || visible.contains("›"), "\(visible)")
    }

    func testTheArrowsAreApprovalButtonsThatTakeNoReturnKeyAndNoFocusOnArrival() throws {
        let p = ApprovalPane(self, withComposer: true)
        try p.arrive(["a", "b"])
        let card = try XCTUnwrap(p.host.card)

        for button in [card.pagePreviousButton, card.pageNextButton] {
            let button = try XCTUnwrap(button)
            XCTAssertEqual(button.keyEquivalent, "", "no button on the card answers to Return or Esc")
        }
        p.assertComposerUntouched("two requests arrived")
        p.host.showNext()
        p.layout()
        p.assertComposerUntouched("paging")
        try XCTUnwrap(p.host.card?.pagePreviousButton).performClick(nil)
        p.layout()
        p.assertComposerUntouched("a page button was pressed")
    }

    func testThePagePeopleAreOnDoesNotJumpWhenAnotherRequestArrives() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        p.host.showNext()
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b", "precondition")

        try p.arrive(["d"])

        XCTAssertEqual(p.host.card?.request.id, "b", "still the one the person is on")
        XCTAssertEqual(p.host.card?.pageText, "2 of 4")
        XCTAssertEqual(p.host.listings.first?.page, 2)
        XCTAssertEqual(p.host.listings.first?.of, 4)
        XCTAssertEqual(p.host.card?.pageNextButton.isEnabled, true)
    }

    func testARequestArrivingWhileOnTheFirstPageLeavesTheFirstShown() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b"])

        try p.arrive(["c"])

        XCTAssertEqual(p.host.card?.request.id, "a")
        XCTAssertEqual(p.host.card?.pageText, "1 of 3")
    }

    func testEachRequestIsAnsweredOnItsOwn() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        p.host.showNext()
        p.layout()
        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "b", "precondition")

        card.denyButton.performClick(nil)

        XCTAssertEqual(p.recorder.sent, [ApprovalRecorder.Sent(requestID: "b", decision: deny(), windowID: "w-test")],
                       "exactly one approval_answer, for the request on screen")
        XCTAssertEqual(p.store.entry(id: "a")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(p.store.entry(id: "c")?.state, ApprovalAnswerState.pending)
        XCTAssertEqual(p.store.entry(id: "b")?.state, ApprovalAnswerState.inFlight(.deny), "the answered one is on its way, the others still wait")
    }

    func testAnAnsweredRequestShowsItsOutcomeThenTheCardMovesToTheNextOne() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        p.host.showNext()
        p.layout()
        try XCTUnwrap(p.host.card).denyButton.performClick(nil)

        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "b", outcome: "denied", byWindow: "w-test")))
        p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b", "the outcome shows where the card is")
        XCTAssertEqual(p.host.listings.first?.state, "Denied")

        p.recorder.runScheduled()
        p.layout()

        XCTAssertEqual(p.host.card?.request.id, "c", "the next one, not back to the first")
        XCTAssertEqual(p.host.card?.pageText, "2 of 2")
        XCTAssertEqual(p.host.card?.denyButton.isEnabled, true, "and it is waiting for its own answer")
        XCTAssertEqual(p.recorder.sent.count, 1)
    }

    func testWhenOnlyOneRequestIsLeftThePageControlsGoAway() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b"])
        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "a", outcome: "denied")))
        p.recorder.runScheduled()
        p.layout()

        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "b")
        XCTAssertEqual(card.pageText, "")
        XCTAssertTrue(card.pagePreviousButton.isHidden)
        XCTAssertTrue(card.pageNextButton.isHidden)
        XCTAssertEqual(p.host.listings.first?.of, 1)
    }

    func testPagingBackAndForthNeverMakesARequestAnswerableTwice() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b"])
        try XCTUnwrap(p.host.card).denyButton.performClick(nil)
        XCTAssertEqual(p.recorder.sent.count, 1, "precondition")

        p.host.showNext(); p.layout()
        p.host.showPrevious(); p.layout()

        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "a")
        XCTAssertFalse(card.denyButton.isEnabled, "the answered request does not become answerable again")
        XCTAssertFalse(card.allowButton?.isEnabled ?? false)
        card.denyButton.performClick(nil)
        card.allowButton?.performClick(nil)
        XCTAssertEqual(p.recorder.sent.count, 1, "still one answer for #a")
        XCTAssertFalse(p.store.answer("a", deny(), windowID: "w-test"))
    }

    func testPagingOffAnUnansweredRequestAndBackLeavesItAnswerable() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b"])

        p.host.showNext(); p.layout()
        p.host.showPrevious(); p.layout()

        XCTAssertEqual(p.host.card?.request.id, "a")
        XCTAssertEqual(p.host.card?.denyButton.isEnabled, true)
    }

    func testThereIsNoAllowAllControlOnAnyPage() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        let known: Set<String> = ["allow_once", "deny", "deny_and_stop", "deny_with_note"]
        for position in 1 ... 3 {
            let card = try XCTUnwrap(p.host.card)
            XCTAssertEqual(card.pageText, "\(position) of 3")
            let ids = try XCTUnwrap(p.host.listings.first).options.map(\.id)
            XCTAssertTrue(Set(ids).isSubset(of: known), "page \(position): \(ids)")
            XCTAssertFalse(ids.contains { $0.contains("allow_all") || $0.contains("all_requests") || $0.hasSuffix("_all") }, "\(ids)")
            for title in ApprovalTestViews.buttons(in: card).map(\.title).map({ $0.lowercased() }) {
                XCTAssertFalse(title.contains("allow all") || title.contains("approve all") || title.contains("all requests") || title == "all", title)
            }
            p.host.showNext()
            p.layout()
        }
    }

    func testPagingChangesWhatTheListingReportsAndNothingElseAboutTheFocus() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        let before = try XCTUnwrap(p.host.listings.first)

        p.host.showNext()
        p.layout()
        let after = try XCTUnwrap(p.host.listings.first)

        XCTAssertEqual(before.requestID, "a")
        XCTAssertEqual(after.requestID, "b")
        XCTAssertEqual(after.focus, before.focus)
        XCTAssertEqual(p.store.pendingCount(tag: "cody-1"), 3)
        XCTAssertEqual(p.host.page?.currentID, "b")
        XCTAssertEqual(p.host.page?.previousID, "a")
        XCTAssertEqual(p.host.page?.nextID, "c")
    }

    func testAnotherFocusRequestsAreNotPagedInto() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a"])
        try p.arrive(["z"], tag: "someone-else")

        XCTAssertEqual(p.host.card?.pageText, "")
        XCTAssertEqual(p.host.page?.count, 1)
    }

    func testTheCardKeepsItsHeightWhenAPageIndicatorAppearsAndTheNextRequestIsShown() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a"])
        let height = try XCTUnwrap(p.host.card).frame.height

        try p.arrive(["b"])
        XCTAssertEqual(p.host.card?.frame.height ?? 0, height, accuracy: 0.5, "`1 of 2` appears in place")
        p.host.showNext()
        p.layout()
        XCTAssertEqual(p.host.card?.frame.height ?? 0, height, accuracy: 0.5, "and the next simple request is as tall")
    }
}

// MARK: - Two windows (criterion 34)

final class ApprovalTwoWindowTests: XCTestCase {

    private func twoWindows(tag: String = "cody-1") -> (ApprovalPane, ApprovalPane) {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let a = ApprovalPane(self, store: store, recorder: recorder, tag: tag, windowID: "w-A")
        let b = ApprovalPane(self, store: store, recorder: recorder, tag: tag, windowID: "w-B")
        return (a, b)
    }

    func testBothWindowsShowTheCardForTheSameRequest() throws {
        let (a, b) = twoWindows()

        try a.arrive(["req-1"])
        b.layout()

        XCTAssertEqual(a.host.card?.request.id, "req-1")
        XCTAssertEqual(b.host.card?.request.id, "req-1")
        XCTAssertFalse(a.host.card === b.host.card, "two cards, one request")
    }

    func testAnAnswerInOneWindowIsSentOnceAndShowsAsTheOutcomeInTheOther() throws {
        let (a, b) = twoWindows()
        try a.arrive(["req-1"])
        b.layout()
        let cardA = try XCTUnwrap(a.host.card), cardB = try XCTUnwrap(b.host.card)
        XCTAssertEqual(cardA.allowButton?.isEnabled, true, "precondition: A can allow")
        XCTAssertEqual(cardB.allowButton?.isEnabled, true, "precondition: B can allow")

        cardA.allowButton?.performClick(nil)

        XCTAssertEqual(a.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: ApprovalDecisionWire(kind: .allowOnce), windowID: "w-A")],
                       "one approval_answer, with A's window id")

        a.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "req-1", outcome: "allowed_once", byWindow: "w-A")))
        a.layout(); b.layout()

        XCTAssertEqual(b.host.listings.first?.state, "Allowed once", "B's card shows the outcome")
        XCTAssertEqual(a.host.listings.first?.state, "Allowed once")
        XCTAssertTrue(try XCTUnwrap(b.host.listings.first).options.allSatisfy { !$0.enabled }, "and B's buttons are off")
        XCTAssertEqual(b.host.card?.allowButton?.isEnabled, false)
        XCTAssertEqual(b.host.card?.denyButton.isEnabled, false)
    }

    func testTheOtherWindowCannotAnswerAfterwards() throws {
        let (a, b) = twoWindows()
        try a.arrive(["req-1"])
        b.layout()
        try XCTUnwrap(a.host.card).allowButton?.performClick(nil)
        a.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "req-1", outcome: "allowed_once", byWindow: "w-A")))
        b.layout()
        let cardB = try XCTUnwrap(b.host.card)

        cardB.allowButton?.performClick(nil)
        cardB.denyButton.performClick(nil)
        cardB.denyAndStopButton?.performClick(nil)

        XCTAssertEqual(a.recorder.sent.count, 1, "still the one answer")
        XCTAssertFalse(b.store.answer("req-1", ApprovalDecisionWire(kind: .deny), windowID: "w-B"))
    }

    func testAnAnswerAlreadyInFlightFromOneWindowCannotBeFollowedByAnotherFromTheOther() throws {
        let (a, b) = twoWindows()
        try a.arrive(["req-1"])
        b.layout()

        try XCTUnwrap(a.host.card).denyButton.performClick(nil)
        b.layout()
        b.host.card?.denyButton.performClick(nil)
        b.host.card?.allowButton?.performClick(nil)

        XCTAssertEqual(a.recorder.sent.map(\.windowID), ["w-A"])
        XCTAssertEqual(a.recorder.sent.count, 1)
    }

    func testPagingInOneWindowDoesNotChangeTheOthersPage() throws {
        let (a, b) = twoWindows()
        try a.arrive(["a", "b", "c"])
        b.layout()

        a.host.showNext()
        a.layout(); b.layout()

        XCTAssertEqual(a.host.card?.request.id, "b")
        XCTAssertEqual(a.host.page?.position, 2)
        XCTAssertEqual(b.host.card?.request.id, "a", "B still shows the first")
        XCTAssertEqual(b.host.page?.position, 1)
        XCTAssertEqual(b.host.card?.pageText, "1 of 3")

        b.host.showNext(); b.host.showNext()
        b.layout()
        XCTAssertEqual(b.host.card?.request.id, "c")
        XCTAssertEqual(a.host.card?.request.id, "b", "and A is where it was")
    }

    func testDroppingTheEntryRemovesBothCards() throws {
        let (a, b) = twoWindows()
        try a.arrive(["req-1"])
        b.layout()
        a.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "req-1", outcome: "denied", byWindow: "w-A")))
        XCTAssertNotNil(a.host.card, "precondition: the outcome is on the cards for its two seconds")
        XCTAssertNotNil(b.host.card)

        a.recorder.runScheduled()
        a.layout(); b.layout()

        XCTAssertNil(a.host.card)
        XCTAssertNil(b.host.card)
        XCTAssertTrue(a.host.listings.isEmpty)
        XCTAssertTrue(b.host.listings.isEmpty)
    }

    func testAWindowOpenedLaterShowsTheCardForTheRequestStillWaiting() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let a = ApprovalPane(self, store: store, recorder: recorder, windowID: "w-A")
        try a.arrive(["req-1"])

        let late = ApprovalPane(self, store: store, recorder: recorder, windowID: "w-late")

        XCTAssertEqual(late.host.card?.request.id, "req-1")
        XCTAssertEqual(late.host.listings.first?.state, a.host.listings.first?.state)
    }
}

// MARK: - The guard bar

final class ApprovalGuardBarTests: XCTestCase {

    private func block(_ p: ApprovalPane, tag: String = "cody-1", toolUseId: String = "toolu_g", entryId: String = "e1",
                       summary: String = "Bash tmux") throws {
        p.store.handle(.guardBlocked(try ApprovalAP2bFixtures.guardBlocked(tag: tag, toolUseId: toolUseId, entryId: entryId, summary: summary)))
        p.layout()
    }

    private let sendInput = "Blocked: Cody tried to send input to a production shell"
    private let openShell = "Blocked: Cody tried to open a production shell"

    // MARK: What it says

    func testABlockedTmuxCallShowsABarThatNamesTheAgentAndWhatItTried() throws {
        let p = ApprovalPane(self)
        XCTAssertNil(p.host.guardBar, "precondition")

        try block(p, summary: "Bash tmux")

        let bar = try XCTUnwrap(p.host.guardBar)
        XCTAssertEqual(bar.textLabel.stringValue, sendInput)
        XCTAssertEqual(bar.accessibilityLabel(), sendInput, "VoiceOver reads the line")
        XCTAssertTrue(bar.superview === p.host)
    }

    func testABlockedProductionShellOpenReadsOpenAProductionShell() throws {
        let p = ApprovalPane(self)
        try block(p, summary: "Bash ecs_connect")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, openShell)
    }

    func testTheTmuxPathAndTheOtherToolsReadAsTheirOwnVerb() throws {
        let p = ApprovalPane(self)
        try block(p, summary: "Bash /opt/homebrew/bin/tmux")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, sendInput)
        try block(p, toolUseId: "toolu_h", entryId: "e2", summary: "Bash ecs_open_tmux_pane")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, openShell, "a name that only contains tmux is not tmux input")
    }

    func testWithoutAnAgentNameTheBarSaysAnAgent() throws {
        let p = ApprovalPane(self, agentName: { nil })
        try block(p, summary: "Bash tmux")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, "Blocked: An agent tried to send input to a production shell")
    }

    func testWithNoAgentNameProviderTheBarSaysAnAgent() throws {
        let p = ApprovalPane(self, agentName: nil)
        try block(p, summary: "Bash aws")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, "Blocked: An agent tried to open a production shell")
    }

    // MARK: No card

    func testABlockMakesNoCardAndNoListing() throws {
        let p = ApprovalPane(self)

        try block(p)

        XCTAssertNil(p.host.card)
        XCTAssertTrue(p.host.listings.isEmpty)
        XCTAssertEqual(p.store.pendingCount(tag: "cody-1"), 0)
        XCTAssertTrue(p.store.visible(tag: "cody-1").isEmpty)
        XCTAssertTrue(p.recorder.sent.isEmpty)
    }

    func testAnotherFocusBlockDoesNotShowAndANewHostForTheFocusShowsTheActiveBar() throws {
        let p = ApprovalPane(self)

        try block(p, tag: "ada-1", toolUseId: "toolu_x", entryId: "e9")
        XCTAssertNil(p.host.guardBar, "ada's block is not this focus's")

        try block(p, tag: "cody-1")
        let later = ApprovalPane(self, store: p.store, recorder: p.recorder, windowID: "w-later")
        XCTAssertEqual(later.host.guardBar?.textLabel.stringValue, sendInput, "a pane built after the block still shows it")
    }

    // MARK: Where it sits

    func testWithACardOnScreenTheBarSitsAboveItWithTheSameXAndWidth() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a"])
        XCTAssertFalse(p.host.isFlipped, "precondition: the host is not flipped, so `above` is a larger y")

        try block(p)

        let card = try XCTUnwrap(p.host.card), bar = try XCTUnwrap(p.host.guardBar)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, card.frame.maxY - 0.5, "the bar is above the card")
        XCTAssertEqual(bar.frame.minX, card.frame.minX, accuracy: 0.5)
        XCTAssertEqual(bar.frame.width, card.frame.width, accuracy: 0.5)
        XCTAssertEqual(bar.frame.height, GuardBlockedBar.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(bar.frame.maxY, p.host.bounds.maxY + 0.5, "inside the pane")
    }

    func testWithNoCardTheBarSitsWhereTheCardWould() throws {
        let p = ApprovalPane(self, size: NSSize(width: 700, height: 500))

        try block(p)

        let bar = try XCTUnwrap(p.host.guardBar)
        XCTAssertEqual(bar.frame.minY, ApprovalOverlayHost.bottomInset, accuracy: 0.5)
        XCTAssertEqual(bar.frame.minX, ApprovalOverlayHost.leadingInset, accuracy: 0.5)
        XCTAssertEqual(bar.frame.width, 700 - ApprovalOverlayHost.leadingInset - ApprovalOverlayHost.trailingInset, accuracy: 0.5)
    }

    func testTheBarMovesAboveACardThatArrivesAndBackDownWhenTheCardLeaves() throws {
        let p = ApprovalPane(self)
        try block(p)
        let alone = try XCTUnwrap(p.host.guardBar).frame
        XCTAssertEqual(alone.minY, ApprovalOverlayHost.bottomInset, accuracy: 0.5, "precondition")

        try p.arrive(["a"])
        let card = try XCTUnwrap(p.host.card), bar = try XCTUnwrap(p.host.guardBar)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, card.frame.maxY - 0.5)

        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "a", outcome: "denied")))
        p.recorder.scheduled.filter { $0.delay == ApprovalStore.outcomeVisibleSeconds }.forEach { $0.work() }
        p.layout()

        XCTAssertNil(p.host.card)
        XCTAssertEqual(try XCTUnwrap(p.host.guardBar).frame.minY, ApprovalOverlayHost.bottomInset, accuracy: 0.5)
    }

    func testTheHostTakesClicksOnTheBarsButtonsAndOnlyThere() throws {
        let p = ApprovalPane(self)
        try block(p)
        let bar = try XCTUnwrap(p.host.guardBar)
        let close = bar.closeButton.convert(bar.closeButton.bounds, to: p.host)

        let hit = try XCTUnwrap(p.host.hitTest(NSPoint(x: close.midX, y: close.midY)), "the close button can be pressed")
        XCTAssertTrue(hit.isDescendant(of: bar))
        XCTAssertNil(p.host.hitTest(NSPoint(x: bar.frame.midX, y: p.host.bounds.maxY - 4)), "the transcript above it still gets its clicks")
    }

    // MARK: Closing and timing out

    func testTheCloseButtonIsLabelledCloseAndDismissesTheBarInEveryWindowOfTheFocus() throws {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let a = ApprovalPane(self, store: store, recorder: recorder, windowID: "w-A")
        let b = ApprovalPane(self, store: store, recorder: recorder, windowID: "w-B", agentName: { "Cody" })
        try block(a)
        b.layout()
        XCTAssertNotNil(b.host.guardBar, "precondition: both windows show it")
        let close = try XCTUnwrap(a.host.guardBar).closeButton
        XCTAssertEqual(close.accessibilityLabel(), "Close")

        close.performClick(nil)
        a.layout(); b.layout()

        XCTAssertNil(a.host.guardBar)
        XCTAssertNil(b.host.guardBar)
        XCTAssertNil(store.guardNotice(tag: "cody-1"))
    }

    func testTheBarHidesItselfWhenTheStoresMinuteEnds() throws {
        let p = ApprovalPane(self)
        try block(p)
        let timer = try XCTUnwrap(p.recorder.scheduled.first { $0.delay == ApprovalStore.guardBarVisibleSeconds })

        timer.work()
        p.layout()

        XCTAssertNil(p.host.guardBar)
        XCTAssertNil(p.store.guardNotice(tag: "cody-1"))
    }

    func testANewerBlockReplacesTheLineAndTheOldMinuteDoesNotHideIt() throws {
        let p = ApprovalPane(self)
        try block(p, entryId: "e1", summary: "Bash tmux")
        let oldTimer = try XCTUnwrap(p.recorder.scheduled.first { $0.delay == 60 })
        p.recorder.scheduled = []

        try block(p, toolUseId: "toolu_h", entryId: "e2", summary: "Bash ecs_connect")
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, openShell, "the newer block's line")

        oldTimer.work()
        p.layout()
        XCTAssertEqual(p.host.guardBar?.textLabel.stringValue, openShell, "the old timer did not hide the new bar")
    }

    // MARK: Never takes focus

    func testTheBarAndItsButtonsNeverBecomeFirstResponderAndTheComposerIsUntouched() throws {
        let p = ApprovalPane(self, withComposer: true)
        try block(p)
        p.assertComposerUntouched("the bar appeared")
        let bar = try XCTUnwrap(p.host.guardBar)

        XCTAssertFalse(bar.acceptsFirstResponder)
        XCTAssertTrue(bar.closeButton.refusesFirstResponder)
        XCTAssertTrue(bar.logLink.refusesFirstResponder)

        bar.closeButton.performClick(nil)
        p.layout()
        p.assertComposerUntouched("the bar was closed")
    }

    func testTheBarAppearingWithACardOnScreenTakesNoFocusEither() throws {
        let p = ApprovalPane(self, withComposer: true)
        try p.arrive(["a"])
        p.assertComposerUntouched("the card arrived")

        try block(p)
        p.assertComposerUntouched("the bar arrived over the card")

        p.recorder.scheduled.filter { $0.delay == 60 }.forEach { $0.work() }
        p.layout()
        p.assertComposerUntouched("the bar timed out")
    }

    // MARK: The link is inert until the log exists

    func testTheLogLinkDoesNothingYet() throws {
        let p = ApprovalPane(self)
        try block(p)
        let bar = try XCTUnwrap(p.host.guardBar)
        let link = bar.logLink

        XCTAssertFalse(link.isEnabled, "disabled")
        XCTAssertNil(link.target, "no target")
        XCTAssertNil(link.action, "no action")

        link.performClick(nil)
        p.layout()

        XCTAssertNotNil(p.host.guardBar, "pressing it neither closes the bar nor opens anything")
        XCTAssertNotNil(p.store.guardNotice(tag: "cody-1"))
        XCTAssertTrue(p.recorder.sent.isEmpty)
    }

    // MARK: The row says so too

    func testTheRowOfABlockedCallReadsBlockedWhileTheBarIsUpAndAfterItGoes() throws {
        let p = ApprovalPane(self)
        let group = FoldFixtures.group([FoldFixtures.foldCall("Bash", id: "toolu_g", summary: "tmux send-keys", full: FoldFixtures.bashInput("tmux send-keys")),
                                        FoldFixtures.foldResult(id: "toolu_g", isError: true)])
        let row = ToolGroupRowView(group: group, isExpanded: false, payloadAvailable: true, reduceMotion: { false },
                                   now: { FoldFixtures.at(0) }, approvals: p.store)
        row.frame = NSRect(x: 0, y: 0, width: 600, height: FoldRowView.height)

        try block(p, toolUseId: "toolu_g")
        XCTAssertEqual(row.approvalField.stringValue, "· blocked: production-shell guard")

        p.store.dismissGuardNotice(tag: "cody-1")
        XCTAssertEqual(row.approvalField.stringValue, "· blocked: production-shell guard", "closing the bar does not unsay it")
    }
}

// MARK: - Source scans (T-AP2b-3)

final class ApprovalAP2bSourceScanTests: XCTestCase {

    private func code(_ path: String) throws -> [String] {
        try DecisionCoordinatorTests.codeLines(ofSourceAt: path)
    }

    private func approvalFiles() throws -> [String] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Nostromo/UI/Approvals")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }.sorted()
    }

    func testTheScanSeesTheGuardBar() throws {
        XCTAssertTrue(try approvalFiles().contains("GuardBlockedBar.swift"))
    }

    func testNothingInTheApprovalUIAddsAMenuItemAMainMenuEntryOrAKeyEquivalentHook() throws {
        let literal = try NSRegularExpression(pattern: "keyEquivalent\\s*(=|:)\\s*\"[^\"]")
        for file in try approvalFiles() {
            for line in try code("UI/Approvals/\(file)") {
                let range = NSRange(location: 0, length: (line as NSString).length)
                // The card's own `Deny ▾` pop-up (AP2a) is a context menu of one item with no key equivalent, not the main menu.
                if file != "ApprovalCardView.swift" {
                    XCTAssertFalse(line.contains("NSMenuItem("), "UI/Approvals/\(file) adds a menu item: \(line)")
                }
                XCTAssertFalse(line.contains("mainMenu"), "UI/Approvals/\(file) touches the main menu: \(line)")
                XCTAssertFalse(line.contains("performKeyEquivalent"), "UI/Approvals/\(file) takes key equivalents: \(line)")
                XCTAssertNil(literal.firstMatch(in: line, range: range), "UI/Approvals/\(file) gives a control a key equivalent: \(line)")
            }
        }
    }

    func testTheGuardBarAndTheRowStatusFileNeverTouchFocusKeyStatusActivationOrVoiceOver() throws {
        var files = ["UI/Approvals/GuardBlockedBar.swift"]
        if try approvalFiles().contains("ApprovalRowStatus.swift") { files.append("UI/Approvals/ApprovalRowStatus.swift") }
        let forbidden = ["makeFirstResponder", "becomeFirstResponder", "makeKey", "activate", "orderFront", "NSAccessibility.post",
                         "requestUserAttention", "makeMain"]
        for file in files {
            let lines = try code(file)
            for needle in forbidden {
                let hits = lines.filter { $0.contains(needle) }
                XCTAssertTrue(hits.isEmpty, "\(file) must not use `\(needle)`: the bar and the row status never take focus or announce: \(hits)")
            }
        }
    }

    func testTheRowsApprovalCodeNeverTouchesFocusKeyStatusActivationOrVoiceOver() throws {
        let forbidden = ["makeFirstResponder", "makeKey", "activate", "orderFront", "NSAccessibility.post"]
        for file in ["UI/Views/ToolGroupView.swift", "UI/Views/ActivityRowView.swift"] {
            let approvalLines = try code(file).filter { $0.lowercased().contains("approval") }
            XCTAssertFalse(approvalLines.isEmpty, "\(file): the scan expects to find the row's approval code")
            for needle in forbidden {
                let hits = approvalLines.filter { $0.contains(needle) }
                XCTAssertTrue(hits.isEmpty, "\(file): a line about approvals uses `\(needle)`: \(hits)")
            }
        }
    }

    func testTheGuardBarIsOnTheArrivalPathAndNeverMovesFocus() throws {
        let joined = try code("UI/Approvals/GuardBlockedBar.swift").joined(separator: "\n")
        XCTAssertFalse(joined.contains("makeFirstResponder"))
        XCTAssertFalse(joined.contains("becomeFirstResponder"))
        XCTAssertFalse(joined.contains("NSAccessibility.post"), "the bar is announced nowhere")
    }
}

// MARK: - Paging keeps what the person was doing (AF2-4, nits)

final class ApprovalPagingStateTests: XCTestCase {

    private func askThenSimple(_ p: ApprovalPane) throws {
        p.store.handle(.request(try QuestionTestRequests.ask(id: "q", options: QuestionTestRequests.offered)))
        p.store.handle(.request(try ApprovalTestRequests.simpleRm(id: "b")))
        p.layout()
    }

    func testAQuestionFormKeepsItsChoicesAndTypedTextWhenThePersonPagesAwayAndBack() throws {
        let p = ApprovalPane(self)
        try askThenSimple(p)
        XCTAssertEqual(p.host.card?.request.id, "q")
        var form = try XCTUnwrap(p.host.card?.questionForm)
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        QuestionTestViews.press(form.optionButton(question: 1, option: 0))
        QuestionTestViews.press(form.optionButton(question: 1, option: 2))
        let other = try XCTUnwrap(form.otherField(question: 1))
        QuestionTestViews.enter("something else", into: other, in: p.window)
        let before = form.selections
        XCTAssertEqual(before[0].selected, [1], "precondition")
        XCTAssertEqual(before[1].otherText, "something else", "precondition")

        p.host.showNext(); p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b")
        p.host.showPrevious(); p.layout()

        form = try XCTUnwrap(p.host.card?.questionForm)
        XCTAssertEqual(p.host.card?.request.id, "q")
        XCTAssertEqual(form.selections, before, "the draft came back")
        XCTAssertEqual(form.otherField(question: 1)?.stringValue, "something else", "with the typed text on screen")
        XCTAssertEqual(form.optionButton(question: 0, option: 1)?.state, .on)
        XCTAssertEqual(form.optionButton(question: 1, option: 2)?.state, .on)
        XCTAssertTrue(p.recorder.sent.isEmpty, "paging, and the draft, sent nothing")
        XCTAssertEqual(p.store.entry(id: "q")?.state, ApprovalAnswerState.pending)
    }

    func testTheDraftIsForgottenWhenItsRequestEnds() throws {
        let p = ApprovalPane(self)
        try askThenSimple(p)
        let form = try XCTUnwrap(p.host.card?.questionForm)
        QuestionTestViews.press(form.optionButton(question: 0, option: 1))
        p.host.showNext(); p.layout()

        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "q", outcome: "denied")))
        p.recorder.runScheduled()
        p.layout()
        p.store.handle(.request(try QuestionTestRequests.ask(id: "q", options: QuestionTestRequests.offered)))
        p.layout()
        while p.host.card?.request.id != "q", p.host.page?.nextID != nil { p.host.showNext(); p.layout() }

        XCTAssertEqual(p.host.card?.request.id, "q")
        XCTAssertEqual(p.host.card?.questionForm?.selections.first?.selected, [], "a new request starts with an empty form")
    }

    func testThePersonReadsTheInputAgainAfterPagingBack() throws {
        let p = ApprovalPane(self)
        p.store.handle(.request(try ApprovalTestRequests.heredoc300(id: "a")))
        p.store.handle(.request(try ApprovalTestRequests.simpleRm(id: "b")))
        p.layout()
        var card = try XCTUnwrap(p.host.card)
        XCTAssertFalse(card.inputView.hasShownEveryLine, "precondition")
        ApprovalTestViews.readThrough(card.inputView)
        XCTAssertTrue(card.inputView.hasShownEveryLine, "precondition: read through")
        XCTAssertTrue(card.canAllow, "precondition")

        p.host.showNext(); p.layout()
        p.host.showPrevious(); p.layout()

        card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.request.id, "a")
        XCTAssertFalse(card.inputView.hasShownEveryLine, "the scroll gate starts over on a rebuilt card")
        XCTAssertFalse(card.canAllow)
    }

    func testWhenTheCurrentRequestEndsTheNextOneTakesItsPlaceNotTheFirst() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c", "d"])
        p.host.showNext(); p.layout()
        XCTAssertEqual(p.host.card?.request.id, "b", "precondition")

        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "b", outcome: "denied")))
        p.recorder.runScheduled()
        p.layout()

        XCTAssertEqual(p.host.card?.request.id, "c", "the one that moved into b's place")
        XCTAssertEqual(p.host.page?.label, "2 of 3")
    }

    func testWhenTheLastRequestEndsThePageFallsBackToTheNewLast() throws {
        let p = ApprovalPane(self)
        try p.arrive(["a", "b", "c"])
        p.host.showNext(); p.host.showNext(); p.layout()

        p.store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "c", outcome: "denied")))
        p.recorder.runScheduled()
        p.layout()

        XCTAssertEqual(p.host.card?.request.id, "b")
    }

    func testThePageLabelIsWideEnoughForTwoDigitCounts() throws {
        let p = ApprovalPane(self)
        try p.arrive((1 ... 12).map { "r\($0)" })
        for _ in 0 ..< 9 { p.host.showNext() }
        p.layout()

        let card = try XCTUnwrap(p.host.card)
        XCTAssertEqual(card.pageText, "10 of 12")
        let label = try XCTUnwrap(card.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "10 of 12" })
        XCTAssertGreaterThanOrEqual(label.frame.width, ceil(label.cell?.cellSize.width ?? 0), "the whole text fits")
        XCTAssertLessThanOrEqual(label.frame.maxX, card.bounds.maxX)
    }
}
