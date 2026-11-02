// NostromoKit — ApprovalRowStatusTextTests.swift
//
// AP2b: what a tool call's transcript row says about its permission request. The daemon's
// `approval_resolved.outcome` maps to one status, each status to one exact line (or to nothing).

import XCTest
@testable import NostromoKit

final class ApprovalRowStatusTextTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - outcome -> status

    func testAnAllowedOnceOutcomeReadsAsApprovedAtThatTime() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("allowed_once", atMs: 1_234), .approved(atMs: 1_234))
    }

    func testAnAllowedForSessionOutcomeReadsAsApprovedAtThatTime() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("allowed_for_session", atMs: 5), .approved(atMs: 5))
    }

    func testAnAnsweredOutcomeReadsAsApprovedAtThatTime() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("answered", atMs: 99), .approved(atMs: 99))
    }

    func testDeniedAndDeniedAndStoppedBothReadAsDeniedByYou() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("denied", atMs: 1), .deniedByYou)
        XCTAssertEqual(ApprovalRowStatus.forOutcome("denied_and_stopped", atMs: 1), .deniedByYou)
    }

    func testATimedOutOutcomeReadsAsDeniedForNoAnswer() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("timed_out", atMs: 1), .deniedNoAnswer)
    }

    func testANoAppOutcomeReadsAsDeniedBecauseNostromoClosed() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("no_app", atMs: 1), .deniedAppClosed)
    }

    func testBothRestartOutcomesReadAsDeniedBecauseNostromoRestarted() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("restart", atMs: 1), .deniedRestarted)
        XCTAssertEqual(ApprovalRowStatus.forOutcome("restart_crash", atMs: 1), .deniedRestarted)
    }

    func testAnApprovalUnavailableOutcomeReadsAsDeniedUnavailable() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("approval_unavailable", atMs: 1), .deniedUnavailable)
    }

    func testAnInvalidRequestOutcomeReadsAsDeniedUnreadable() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("invalid_request", atMs: 1), .deniedUnreadable)
    }

    func testAGuardBlockedOutcomeReadsAsBlockedByTheGuard() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("guard_blocked", atMs: 1), .blockedByGuard)
    }

    func testRuleAllowedOutcomesReadAsTheirOwnStatuses() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("allowed_by_session_rule", atMs: 1), .allowedBySessionRule)
        XCTAssertEqual(ApprovalRowStatus.forOutcome("allowed_by_your_rule", atMs: 1), .allowedByYourRule)
    }

    func testWithdrawnAndCancelledOutcomesLeaveTheRowSayingNothing() {
        XCTAssertEqual(ApprovalRowStatus.forOutcome("withdrawn", atMs: 1), .withdrawn)
        XCTAssertEqual(ApprovalRowStatus.forOutcome("cancelled", atMs: 1), .withdrawn)
    }

    func testAnOutcomeThisBuildHasNoWordsForLeavesTheRowSayingNothing() {
        for outcome in ["deny_write_failed", "too_large", "something_new", "", "ALLOWED_ONCE", "allowed_once "] {
            XCTAssertEqual(ApprovalRowStatus.forOutcome(outcome, atMs: 1), .withdrawn, "outcome '\(outcome)'")
        }
    }

    // MARK: - status -> text

    func testAwaitingReadsAwaitingYourApproval() {
        XCTAssertEqual(ApprovalRowStatus.awaiting.text(timeZone: utc), "awaiting your approval")
    }

    func testRuleAllowedStatusesReadTheirRule() {
        XCTAssertEqual(ApprovalRowStatus.allowedBySessionRule.text(timeZone: utc), "allowed by session rule")
        XCTAssertEqual(ApprovalRowStatus.allowedByYourRule.text(timeZone: utc), "allowed by your rule")
    }

    func testEveryDenialReadsItsReason() {
        XCTAssertEqual(ApprovalRowStatus.deniedByYou.text(timeZone: utc), "denied by you")
        XCTAssertEqual(ApprovalRowStatus.deniedNoAnswer.text(timeZone: utc), "denied: no answer in 15 min")
        XCTAssertEqual(ApprovalRowStatus.deniedAppClosed.text(timeZone: utc), "denied: Nostromo closed")
        XCTAssertEqual(ApprovalRowStatus.deniedRestarted.text(timeZone: utc), "denied: Nostromo restarted")
        XCTAssertEqual(ApprovalRowStatus.deniedUnavailable.text(timeZone: utc), "denied: approvals unavailable")
        XCTAssertEqual(ApprovalRowStatus.deniedUnreadable.text(timeZone: utc), "denied: unreadable request")
    }

    func testABlockedCallReadsTheGuardByName() {
        XCTAssertEqual(ApprovalRowStatus.blockedByGuard.text(timeZone: utc), "blocked: production-shell guard")
    }

    func testAWithdrawnRequestSaysNothing() {
        XCTAssertNil(ApprovalRowStatus.withdrawn.text(timeZone: utc))
    }

    // MARK: - approved by you · HH:mm

    /// 2025-10-09 14:02:30 UTC.
    private let afternoonMs: UInt64 = 1_760_018_550_000

    func testApprovedReadsTheTimeOnA24HourClockInTheGivenZone() {
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: afternoonMs).text(timeZone: utc),
                       "approved by you \u{00B7} 14:02")
    }

    func testTheSameMomentReadsDifferentlyInAnotherZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!        // UTC+9, 23:02
        let chicago = TimeZone(identifier: "America/Chicago")! // UTC-5 in October (CDT), 09:02
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: afternoonMs).text(timeZone: tokyo),
                       "approved by you \u{00B7} 23:02")
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: afternoonMs).text(timeZone: chicago),
                       "approved by you \u{00B7} 09:02")
    }

    func testHoursAndMinutesBelowTenKeepTheirLeadingZero() {
        // 2025-10-09 03:05:00 UTC
        let ms: UInt64 = 1_759_979_100_000
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: ms).text(timeZone: utc), "approved by you \u{00B7} 03:05")
    }

    func testMidnightReadsZeroZeroZeroZeroNotTwelveOrTwentyFour() {
        // 2025-10-09 00:00:00 UTC
        let ms: UInt64 = 1_759_968_000_000
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: ms).text(timeZone: utc), "approved by you \u{00B7} 00:00")
    }

    func testTheLastMinuteOfTheDayReadsTwentyThreeFiftyNine() {
        // 2025-10-09 23:59:59 UTC
        let ms: UInt64 = 1_760_054_399_000
        XCTAssertEqual(ApprovalRowStatus.approved(atMs: ms).text(timeZone: utc), "approved by you \u{00B7} 23:59")
    }

    func testAfternoonReadsOnA24HourClockNotWithAnAmPmSuffix() {
        let text = ApprovalRowStatus.approved(atMs: afternoonMs).text(timeZone: utc) ?? ""
        XCTAssertFalse(text.localizedCaseInsensitiveContains("pm"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("am"))
    }

    // MARK: - isAwaiting

    func testOnlyAwaitingIsAwaiting() {
        XCTAssertTrue(ApprovalRowStatus.awaiting.isAwaiting)
        let others: [ApprovalRowStatus] = [
            .approved(atMs: 1), .allowedBySessionRule, .allowedByYourRule, .deniedByYou, .deniedNoAnswer,
            .deniedAppClosed, .deniedRestarted, .deniedUnavailable, .deniedUnreadable, .blockedByGuard, .withdrawn,
        ]
        for status in others { XCTAssertFalse(status.isAwaiting, "\(status)") }
    }

    // MARK: - nothing but words

    func testEveryStatusExceptWithdrawnHasANonEmptyLine() {
        let all: [ApprovalRowStatus] = [
            .awaiting, .approved(atMs: 1), .allowedBySessionRule, .allowedByYourRule, .deniedByYou,
            .deniedNoAnswer, .deniedAppClosed, .deniedRestarted, .deniedUnavailable, .deniedUnreadable,
            .blockedByGuard,
        ]
        for status in all {
            let text = status.text(timeZone: utc)
            XCTAssertNotNil(text, "\(status)")
            XCTAssertFalse((text ?? "").isEmpty, "\(status)")
        }
    }
}
