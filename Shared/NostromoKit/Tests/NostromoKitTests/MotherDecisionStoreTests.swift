// NostromoKit — MotherDecisionStoreTests.swift
//
// MC3: the send state of one job's current decision. The Mac keeps one store per job and
// drives it from option-button clicks and the broker's answers. The contract these tests
// pin down:
//
// - A decision is answered at most once from the UI: after `request` the store is
//   `.sending`, and a second click (or an `.sent` one) gets no command.
// - A failed send can be retried; the failure keeps which option was tried.
// - `override_open` (the "open the PR with red gates" choice) needs a deliberate second
//   step: a confirm. No confirm, no command.
// - An option that takes text is only sendable with non-blank text of at most 4000
//   characters, and the command carries the trimmed text; other options carry none.
// - The store follows the job's decision: a new decision id starts over, even from `.sent`;
//   a late result for an older decision never touches the new one.

import XCTest
@testable import NostromoKit

final class MotherDecisionStoreTests: XCTestCase {

    // MARK: - Builders

    private let guidance = MotherDecisionOption(
        id: .resumeWithGuidance, label: "Resume with guidance",
        consequence: "Re-runs the worker with your guidance.", takesText: true)
    private let escalate = MotherDecisionOption(
        id: .escalate, label: "Escalate", consequence: "Re-runs one tier up.", takesText: false)
    private let overrideOpt = MotherDecisionOption(
        id: .overrideOpen, label: "Open anyway", consequence: "Opens the PR with red gates recorded.", takesText: false)
    private let cancel = MotherDecisionOption(
        id: .cancel, label: "Cancel", consequence: "Stops the job.", takesText: false)

    private func decision(_ id: String = "d-1", resolvedAt: String? = nil) -> MotherDecision {
        MotherDecision(
            id: id, kind: "gate_hold",
            options: [guidance, escalate, overrideOpt, cancel],
            openedAt: "2026-10-17T12:00:00.000Z", resolvedAt: resolvedAt)
    }

    private func store(following id: String = "d-1") -> MotherDecisionStore {
        var s = MotherDecisionStore()
        s.sync(decision: decision(id))
        return s
    }

    // MARK: - Start

    func testANewStoreFollowsNothingAndIsIdle() {
        let s = MotherDecisionStore()
        XCTAssertNil(s.decisionId)
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(s.canSend(option: escalate, text: ""))
    }

    func testStoreWithNoDecisionNeverReturnsACommand() {
        var s = MotherDecisionStore()
        XCTAssertNil(s.request(option: escalate, text: ""))
        XCTAssertFalse(s.beginConfirm(option: .overrideOpen))
        XCTAssertEqual(s.state, .idle)
    }

    func testSyncingAnOpenDecisionFollowsItsIdAndStaysIdle() {
        let s = store(following: "d-7")
        XCTAssertEqual(s.decisionId, "d-7")
        XCTAssertEqual(s.state, .idle)
    }

    // MARK: - Sending (idle -> sending -> sent)

    func testRequestingAnOptionReturnsItsCommandAndMovesToSending() {
        var s = store()
        let command = s.request(option: escalate, text: "")
        XCTAssertEqual(command, MotherDecisionCommand(decisionId: "d-1", option: .escalate, text: nil))
        XCTAssertEqual(s.state, .sending(.escalate))
    }

    func testASuccessfulSendMovesFromSendingToSent() {
        var s = store()
        _ = s.request(option: cancel, text: "")
        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .sent(.cancel))
    }

    func testASecondRequestWhileSendingGetsNoCommand() {
        var s = store()
        XCTAssertNotNil(s.request(option: escalate, text: ""))
        XCTAssertFalse(s.canSend(option: escalate, text: ""))
        XCTAssertFalse(s.canSend(option: cancel, text: ""))
        XCTAssertNil(s.request(option: escalate, text: ""), "no double send")
        XCTAssertNil(s.request(option: cancel, text: ""), "a different option does not slip through either")
        XCTAssertEqual(s.state, .sending(.escalate))
    }

    func testARequestAfterSentGetsNoCommand() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.succeeded(decisionId: "d-1")
        XCTAssertFalse(s.canSend(option: escalate, text: ""))
        XCTAssertNil(s.request(option: escalate, text: ""))
        XCTAssertNil(s.request(option: cancel, text: ""))
        XCTAssertEqual(s.state, .sent(.escalate))
    }

    func testBeginConfirmIsRefusedWhileSendingAndAfterSent() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        XCTAssertFalse(s.beginConfirm(option: .overrideOpen))
        XCTAssertEqual(s.state, .sending(.escalate))
        s.succeeded(decisionId: "d-1")
        XCTAssertFalse(s.beginConfirm(option: .overrideOpen))
        XCTAssertEqual(s.state, .sent(.escalate))
    }

    // MARK: - Failure and retry

    func testAFailedSendKeepsTheOptionAndTheKindOfFailure() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.failed(decisionId: "d-1", kind: .invalidState)
        XCTAssertEqual(s.state, .failed(.escalate, .invalidState))
    }

    func testAfterAFailureARequestReturnsACommandAgain() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.failed(decisionId: "d-1", kind: .disconnected)
        XCTAssertTrue(s.canSend(option: escalate, text: ""))
        XCTAssertTrue(s.canSend(option: cancel, text: ""), "a retry may pick another option")
        XCTAssertEqual(s.request(option: cancel, text: ""),
                       MotherDecisionCommand(decisionId: "d-1", option: .cancel, text: nil))
        XCTAssertEqual(s.state, .sending(.cancel))
    }

    func testEveryFailureKindCanBeRecordedAndRetried() {
        let kinds: [BrokerErrorKind] = [.noSuchJob, .invalidState, .unauthorized, .unavailable, .timeout, .disconnected, .other]
        for kind in kinds {
            var s = store()
            _ = s.request(option: escalate, text: "")
            s.failed(decisionId: "d-1", kind: kind)
            XCTAssertEqual(s.state, .failed(.escalate, kind))
            XCTAssertNotNil(s.request(option: escalate, text: ""), "retry after \(kind)")
        }
    }

    // MARK: - Results outside .sending, and late results

    func testASuccessOrFailureOutsideSendingIsIgnored() {
        var s = store()
        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .idle)
        s.failed(decisionId: "d-1", kind: .timeout)
        XCTAssertEqual(s.state, .idle)

        _ = s.request(option: escalate, text: "")
        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .sent(.escalate))
        s.failed(decisionId: "d-1", kind: .timeout)
        XCTAssertEqual(s.state, .sent(.escalate), "a failure after success does not undo it")

        var f = store()
        _ = f.request(option: escalate, text: "")
        f.failed(decisionId: "d-1", kind: .timeout)
        f.succeeded(decisionId: "d-1")
        XCTAssertEqual(f.state, .failed(.escalate, .timeout), "a success after a failure is not applied")
    }

    func testAResultForAnOlderDecisionIsIgnoredWhileTheNewOneIsSending() {
        var s = store(following: "d-1")
        _ = s.request(option: escalate, text: "")
        s.sync(decision: decision("d-2"))
        XCTAssertEqual(s.state, .idle)
        _ = s.request(option: cancel, text: "")
        XCTAssertEqual(s.state, .sending(.cancel))

        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .sending(.cancel), "the old decision's success must not complete the new send")
        s.failed(decisionId: "d-1", kind: .timeout)
        XCTAssertEqual(s.state, .sending(.cancel), "the old decision's failure must not fail the new send")

        s.succeeded(decisionId: "d-2")
        XCTAssertEqual(s.state, .sent(.cancel))
    }

    func testAResultForADecisionTheStoreNoLongerFollowsChangesNothing() {
        var s = store(following: "d-1")
        _ = s.request(option: escalate, text: "")
        s.sync(decision: nil)
        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.decisionId)
    }

    // MARK: - Following the job's decision

    func testSyncingNilClearsTheDecisionAndTheState() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.sync(decision: nil)
        XCTAssertNil(s.decisionId)
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.request(option: escalate, text: ""))
    }

    func testSyncingAResolvedDecisionClearsTheDecisionAndTheState() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.succeeded(decisionId: "d-1")
        s.sync(decision: decision("d-1", resolvedAt: "2026-10-17T12:05:00.000Z"))
        XCTAssertNil(s.decisionId)
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.request(option: escalate, text: ""), "a resolved decision cannot be answered again")
    }

    func testSyncingANewDecisionIdResetsToIdleEvenFromSent() {
        var s = store(following: "d-1")
        _ = s.request(option: escalate, text: "")
        s.succeeded(decisionId: "d-1")
        XCTAssertEqual(s.state, .sent(.escalate))

        s.sync(decision: decision("d-2"))
        XCTAssertEqual(s.decisionId, "d-2")
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(s.request(option: escalate, text: "")?.decisionId, "d-2")
    }

    func testSyncingANewDecisionIdResetsFromSendingFailedAndConfirming() {
        var sending = store(following: "d-1")
        _ = sending.request(option: escalate, text: "")
        sending.sync(decision: decision("d-2"))
        XCTAssertEqual(sending.state, .idle)

        var failed = store(following: "d-1")
        _ = failed.request(option: escalate, text: "")
        failed.failed(decisionId: "d-1", kind: .timeout)
        failed.sync(decision: decision("d-2"))
        XCTAssertEqual(failed.state, .idle)

        var confirming = store(following: "d-1")
        XCTAssertTrue(confirming.beginConfirm(option: .overrideOpen))
        confirming.sync(decision: decision("d-2"))
        XCTAssertEqual(confirming.state, .idle)
    }

    func testSyncingTheSameDecisionIdKeepsTheState() {
        var s = store(following: "d-1")
        _ = s.request(option: escalate, text: "")
        s.sync(decision: decision("d-1"))
        XCTAssertEqual(s.state, .sending(.escalate))
        s.succeeded(decisionId: "d-1")
        s.sync(decision: decision("d-1"))
        XCTAssertEqual(s.state, .sent(.escalate))

        var f = store(following: "d-1")
        _ = f.request(option: escalate, text: "")
        f.failed(decisionId: "d-1", kind: .unavailable)
        f.sync(decision: decision("d-1"))
        XCTAssertEqual(f.state, .failed(.escalate, .unavailable))

        var c = store(following: "d-1")
        XCTAssertTrue(c.beginConfirm(option: .overrideOpen))
        c.sync(decision: decision("d-1"))
        XCTAssertEqual(c.state, .confirming(.overrideOpen))
    }

    // MARK: - override_open needs a confirm

    func testOverrideOpenGetsNoCommandWithoutAConfirm() {
        var s = store()
        XCTAssertFalse(s.canSend(option: overrideOpt, text: ""))
        XCTAssertNil(s.request(option: overrideOpt, text: ""))
        XCTAssertEqual(s.state, .idle, "a refused request changes nothing")
    }

    func testBeginConfirmThenRequestSendsOverrideOpen() {
        var s = store()
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        XCTAssertEqual(s.state, .confirming(.overrideOpen))
        XCTAssertTrue(s.canSend(option: overrideOpt, text: ""))
        XCTAssertEqual(s.request(option: overrideOpt, text: ""),
                       MotherDecisionCommand(decisionId: "d-1", option: .overrideOpen, text: nil))
        XCTAssertEqual(s.state, .sending(.overrideOpen))
    }

    func testCancellingTheConfirmReturnsToIdleAndOverrideOpenIsGatedAgain() {
        var s = store()
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        s.cancelConfirm()
        XCTAssertEqual(s.state, .idle)
        XCTAssertNil(s.request(option: overrideOpt, text: ""))
    }

    func testCancelConfirmOutsideConfirmingDoesNothing() {
        var s = store()
        s.cancelConfirm()
        XCTAssertEqual(s.state, .idle)

        _ = s.request(option: escalate, text: "")
        s.cancelConfirm()
        XCTAssertEqual(s.state, .sending(.escalate))
        s.succeeded(decisionId: "d-1")
        s.cancelConfirm()
        XCTAssertEqual(s.state, .sent(.escalate))

        var f = store()
        _ = f.request(option: escalate, text: "")
        f.failed(decisionId: "d-1", kind: .timeout)
        f.cancelConfirm()
        XCTAssertEqual(f.state, .failed(.escalate, .timeout))
    }

    func testAFailedOverrideNeedsANewConfirmBeforeItCanBeSentAgain() {
        var s = store()
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        _ = s.request(option: overrideOpt, text: "")
        s.failed(decisionId: "d-1", kind: .unavailable)
        XCTAssertEqual(s.state, .failed(.overrideOpen, .unavailable))

        XCTAssertFalse(s.canSend(option: overrideOpt, text: ""), "the earlier confirm does not carry over")
        XCTAssertNil(s.request(option: overrideOpt, text: ""))

        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        XCTAssertNotNil(s.request(option: overrideOpt, text: ""))
        XCTAssertEqual(s.state, .sending(.overrideOpen))
    }

    func testBeginConfirmIsAllowedAfterAFailure() {
        var s = store()
        _ = s.request(option: escalate, text: "")
        s.failed(decisionId: "d-1", kind: .timeout)
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        XCTAssertEqual(s.state, .confirming(.overrideOpen))
    }

    func testWhileConfirmingOverrideOtherOptionsCanStillBeSent() {
        var s = store()
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        XCTAssertTrue(s.canSend(option: escalate, text: ""))
        XCTAssertEqual(s.request(option: escalate, text: "")?.option, .escalate)
        XCTAssertEqual(s.state, .sending(.escalate))
    }

    // MARK: - takes_text

    func testAnOptionThatTakesTextCannotBeSentWithEmptyOrBlankText() {
        var s = store()
        for blank in ["", " ", "   ", "\n", "\t \n  "] {
            XCTAssertFalse(s.canSend(option: guidance, text: blank), "\(blank.debugDescription)")
            XCTAssertNil(s.request(option: guidance, text: blank), "\(blank.debugDescription)")
        }
        XCTAssertEqual(s.state, .idle, "refused requests leave the store idle")
    }

    func testTheCommandCarriesTheTrimmedText() {
        var s = store()
        let command = s.request(option: guidance, text: "  \n Use the v2 endpoint instead.  \n")
        XCTAssertEqual(command, MotherDecisionCommand(decisionId: "d-1", option: .resumeWithGuidance,
                                                      text: "Use the v2 endpoint instead."))
        XCTAssertEqual(s.state, .sending(.resumeWithGuidance))
    }

    func testTextInsideTheGuidanceIsKeptVerbatim() {
        var s = store()
        let command = s.request(option: guidance, text: "line one\n\nline  two")
        XCTAssertEqual(command?.text, "line one\n\nline  two")
    }

    func testExactlyFourThousandCharactersIsSendable() {
        XCTAssertEqual(MotherDecisionStore.maxTextLength, 4_000)
        let text = String(repeating: "a", count: 4_000)
        XCTAssertTrue(MotherDecisionStore.textIsSendable(text))
        var s = store()
        XCTAssertTrue(s.canSend(option: guidance, text: text))
        XCTAssertEqual(s.request(option: guidance, text: text)?.text, text)
    }

    func testFourThousandAndOneCharactersIsNotSendable() {
        let text = String(repeating: "a", count: 4_001)
        XCTAssertFalse(MotherDecisionStore.textIsSendable(text))
        var s = store()
        XCTAssertFalse(s.canSend(option: guidance, text: text))
        XCTAssertNil(s.request(option: guidance, text: text))
        XCTAssertEqual(s.state, .idle)
    }

    func testTheLengthLimitIsMeasuredOnTheTrimmedText() {
        let padded = "   " + String(repeating: "a", count: 4_000) + "\n\n  "
        XCTAssertTrue(MotherDecisionStore.textIsSendable(padded))
        var s = store()
        XCTAssertEqual(s.request(option: guidance, text: padded)?.text, String(repeating: "a", count: 4_000))
    }

    func testTextIsSendableNeedsNonBlankText() {
        XCTAssertFalse(MotherDecisionStore.textIsSendable(""))
        XCTAssertFalse(MotherDecisionStore.textIsSendable("  \n\t"))
        XCTAssertTrue(MotherDecisionStore.textIsSendable("x"))
    }

    func testOptionsThatDoNotTakeTextCarryNoTextAndIgnoreWhatWasTyped() {
        for option in [escalate, cancel] {
            var s = store()
            XCTAssertTrue(s.canSend(option: option, text: ""), "\(option.id.raw) needs no text")
            let command = s.request(option: option, text: "stray guidance typed earlier")
            XCTAssertEqual(command, MotherDecisionCommand(decisionId: "d-1", option: option.id, text: nil))
        }
        var s = store()
        XCTAssertTrue(s.beginConfirm(option: .overrideOpen))
        let stray = s.request(option: overrideOpt, text: "stray")
        XCTAssertNotNil(stray)
        XCTAssertNil(stray?.text)
    }

    func testTextTooLongForGuidanceDoesNotBlockAnOptionThatTakesNoText() {
        let text = String(repeating: "a", count: 5_000)
        let s = store()
        XCTAssertTrue(s.canSend(option: escalate, text: text))
        XCTAssertTrue(s.canSend(option: cancel, text: text))
    }

    // MARK: - Unknown options

    func testAnUnknownOptionIdCanBeSentLikeAnyOtherOption() {
        let future = MotherDecisionOption(id: .unknown("defer"), label: "Defer", consequence: "Later.", takesText: false)
        var s = store()
        XCTAssertTrue(s.canSend(option: future, text: ""))
        XCTAssertEqual(s.request(option: future, text: ""),
                       MotherDecisionCommand(decisionId: "d-1", option: .unknown("defer"), text: nil))
        XCTAssertEqual(s.state, .sending(.unknown("defer")))
    }

    func testAnUnknownOptionThatTakesTextFollowsTheTextRule() {
        let future = MotherDecisionOption(id: .unknown("note"), label: "Note", consequence: "", takesText: true)
        var s = store()
        XCTAssertFalse(s.canSend(option: future, text: "  "))
        XCTAssertNil(s.request(option: future, text: ""))
        XCTAssertEqual(s.request(option: future, text: " hi ")?.text, "hi")
    }
}
