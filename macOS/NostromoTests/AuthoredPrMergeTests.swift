import XCTest
import AppKit
import Combine
import NostromoKit

// Merging a PR from the My open PRs Overview: a "Perri approved" badge and a guarded Merge button on the rows.
//
// Contract (the Kit's wording and rules have their own tests, AuthoredPrsMergeUITests.swift; this file is what
// the Mac does with them).
//  * The Merge button is on an open row of READY, only when the daemon advertised both `authored_prs_perri_v1` and
//    `authored_prs_merge_v1`; it is enabled only when Perri approved this head, a human approved and checks are
//    green. Otherwise it is shown off with the reason, and nothing it does can send anything.
//  * Pressing it is a person's gesture (`AuthoredPrGesture.Permit`): a refused gesture does nothing at all.
//    It opens a one-step confirmation (a popover); it never sends. Cancel is the default button, Merge has no key
//    equivalent, Escape cancels, Return does not merge.
//  * The confirm click is a gesture too. It sends exactly ONE request, carrying the head of the row the person
//    SAW (the confirmation's own), never the newest snapshot's. A snapshot that changes that head, or makes the
//    row not ready, while the confirmation is open cancels it. One that arrives after the confirm changes nothing.
//  * While the answer is pending the row says Merging… and a second press opens nothing. The answer is the row's
//    notice (the words of its code) or Merged. Merged never regroups the row: only a snapshot does.
//  * No new key equivalents; the row context menu has no Merge item; Return on a row never merges; rows keep
//    their height and the scroll offset, the selection and the hovered row hold still through every merge state.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1  the merge is sent without the gesture check (activate, or confirm, skips `permit`)
//        -> testActivateDoesNothingForEveryInputThatIsNotAHumanGesture, testConfirmDoesNothingForEveryInput...,
//           testTheRowsButtonDoesNothingForEveryInputThatIsNotAHumanGesture
//   M2  the button is enabled without the Perri-current-head condition (no verdict, an older approval, changes
//        requested, only comments)  -> testAnUnavailableButtonIsShownOffWithItsReasonAndPressingItOpensNothing
//   M3  the button is enabled without the human-approval condition  -> the same test ("no human approval")
//   M4  the request carries the newest snapshot's head instead of the head the person saw
//        -> testASnapshotAfterTheConfirmDoesNotChangeTheRequest, testTheRequestCarriesTheHeadOfTheRowThePersonSaw
//   M5  a snapshot with another head leaves the confirmation open
//        -> testASnapshotWithAnotherHeadWhileTheConfirmationIsOpenCancelsItAndSendsNothing,
//           testRowsDidChangeCancelsTheConfirmationWhenTheHeadMoved
//   M6  confirming twice (or a double click) sends twice  -> testConfirmingTwiceSendsExactlyOneRequest
//   M7  a second press while Merging… opens another confirmation  -> testASecondPressWhileMergingOrMergedOpensNothing
//   M8  an answer is worded as another, or an unknown code reads as success  -> testEveryAnswerShowsItsWordsOnTheRow...
//   M9  Merged regroups the row optimistically  -> testOkShowsMergedAndNeverRegroupsTheRow
//   M10 Merge has a key equivalent, or Return merges  -> testReturnNeverMerges..., testTheContextMenuHasNoMerge...,
//           testTheConfirmationsKeysAreCancelDefaultEscapeCancelsAndMergeHasNoKeyEquivalent
//   M11 the merger sends with the merge feature off  -> testWithTheMergeFeatureOffTheMergerOpensNothingAndSendsNothing
//   M12 a notice outlives a head change (or a headChanged notice does not)  -> testTheNoticeGoesWhenTheRowsHeadChanges,
//           testAHeadChangedNoticeStaysThroughAHeadChange
//   M13 a merge state moves the scroll, the selection or the hovered row  -> AuthoredPrMergeScrollSafetyTests

// MARK: - The merger and its confirmation

final class AuthoredPrMergerTests: MouseQueueTestCase {

    private var rigs: [MergeRig] = []

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    private func makeRig(allowEverything: Bool = false) -> MergeRig {
        let rig = MergeRig(allowEverything: allowEverything)
        rigs.append(rig)
        return rig
    }

    private func progress(_ rig: MergeRig, _ pr: AuthoredPr) -> AuthoredPrMergeProgress? { rig.merger.attempts[pr.id]?.progress }

    // MARK: - Opening the confirmation

    func testActivatingAReadyRowOpensAConfirmationAndSendsNothing() throws {
        let rig = makeRig()
        let pr = MF.readyPr()
        let model = MF.row(pr)

        rig.activate(model)

        let session = try XCTUnwrap(rig.session, "a confirmation is up")
        XCTAssertEqual(rig.shown.count, 1)
        XCTAssertTrue(rig.shown.first?.session === session, "and it is the one that was shown")
        XCTAssertEqual(session.confirmation, model.mergeButton?.confirmation)
        XCTAssertEqual(session.confirmation.expectedHeadShaShort, MF.headA)
        XCTAssertTrue(rig.transport.calls.isEmpty, "pressing the button asks for confirmation; it never merges")
        XCTAssertTrue(rig.merger.attempts.isEmpty, "and nothing is pending yet")
    }

    func testActivateDoesNothingForEveryInputThatIsNotAHumanGesture() throws {
        let rig = makeRig()
        let model = MF.row(MF.readyPr())
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: rig.window)
            rig.merger.activate(model, anchor: rig.control, event: event, control: rig.control)
            XCTAssertNil(rig.session, "\(kind): nothing opened")
            XCTAssertTrue(rig.shown.isEmpty, "\(kind): nothing was shown")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was asked of the daemon")
            XCTAssertEqual(rig.merger.attempts, [model.id: AuthoredPrMergeAttempt(head: MF.headA, progress: .failed(.gestureRefused))],
                           "\(kind): nothing is pending; the row says the press was refused")
        }
        // The same call with a person's click does open it: the refusals above were the gesture check.
        rig.activate(model)
        XCTAssertNotNil(rig.session, "a person's click is accepted")
    }

    func testAPressWithNoPersonBehindItDoesNothing() throws {
        try HF.skipIfVoiceOver()
        let rig = makeRig()
        rig.merger.activate(MF.row(MF.readyPr()), anchor: rig.control, event: nil, control: rig.control)
        XCTAssertNil(rig.session)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: A refused press says so, and the gesture gate is not weakened

    func testARefusedPressLeavesAWordOnTheRowAndAPersonsPressClearsIt() throws {
        let rig = makeRig()
        let model = MF.row(MF.readyPr())
        let event = try NotAHumanGesture.staleEvent.event(in: rig.window)
        rig.merger.activate(model, anchor: rig.control, event: event, control: rig.control)

        let attempt = try XCTUnwrap(rig.merger.attempts[model.id], "a refusal is not silent")
        XCTAssertEqual(attempt.progress, .failed(.gestureRefused))
        XCTAssertEqual(AuthoredPrsPresentation.mergeNotice(MF.readyPr(), attempt: attempt), "Merge was refused: use the button")
        XCTAssertNil(rig.session)
        XCTAssertTrue(rig.transport.calls.isEmpty)

        rig.activate(model)   // a person's click: a new attempt, the old word is gone
        XCTAssertNil(rig.merger.attempts[model.id])
        XCTAssertNotNil(rig.session)
    }

    func testARefusedPressNeverTouchesAMergeThatIsRunningOrDone() throws {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        rig.merger.permit = { _, _, _ in false }
        rig.merger.activate(MF.row(pr), anchor: rig.control, event: nil, control: rig.control)
        XCTAssertEqual(rig.merger.attempts[pr.id]?.progress, .merging, "still waiting for the answer to the one request")
        rig.transport.answer(.ok(AuthoredPrDone()))
        rig.merger.activate(MF.row(pr), anchor: rig.control, event: nil, control: rig.control)
        XCTAssertEqual(rig.merger.attempts[pr.id]?.progress, .merged)
        XCTAssertEqual(rig.transport.calls.count, 1)
    }

    /// A person's own click, while the app-control socket is running a request, is not a person's gesture: an agent
    /// that drives the socket can land its request while a real event is "current". Both the button and the
    /// confirmation's Merge refuse, and nothing is sent.
    func testAnAppControlRequestInProgressRefusesEvenAPersonsEventAtTheButtonAndTheConfirmation() throws {
        let rig = makeRig()
        let model = MF.row(MF.readyPr())
        SyntheticInputGate.begin()
        var ended = false
        defer { if !ended { SyntheticInputGate.end() } }
        rig.merger.activate(model, anchor: rig.control, event: MF.human(in: rig.window), control: rig.control)
        XCTAssertNil(rig.session, "the button opened nothing")
        XCTAssertEqual(rig.merger.attempts[model.id]?.progress, .failed(.gestureRefused))
        SyntheticInputGate.end(); ended = true

        rig.activate(model)
        let session = try XCTUnwrap(rig.session, "precondition: a person opened it")
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        XCTAssertTrue(rig.transport.calls.isEmpty, "Merge in the confirmation sent nothing")
        XCTAssertTrue(rig.session === session, "and the confirmation is still open")
    }

    func testAnUnavailableButtonOpensNothingWhateverTheGesture() {
        // A forged press on a row whose button is off (or that has none): nothing opens, nothing is sent.
        let rig = makeRig(allowEverything: true)
        var models: [(String, AuthoredPrRowModel)] = MF.unavailableCases.map { ($0.name, MF.row($0.pr)) }
        models.append(("a row that is not in READY", MF.row(MF.readyPr(group: .waiting))))
        models.append(("a merged PR", MF.row(MF.readyPr(lifecycle: .merged))))
        models.append(("Perri's feature off", MF.row(MF.readyPr(), perri: false)))
        models.append(("the merge feature off", MF.row(MF.readyPr(), merge: false)))
        for (name, model) in models {
            rig.activate(model)
            XCTAssertNil(rig.session, "\(name): nothing opened")
        }
        XCTAssertTrue(rig.shown.isEmpty)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.attempts.isEmpty)
    }

    func testWithTheMergeFeatureOffTheMergerOpensNothingAndSendsNothing() throws {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.transport.isMergeAvailable = false
        rig.activate(MF.row(pr))
        XCTAssertNil(rig.session, "the daemon cannot merge: no confirmation")
        XCTAssertTrue(rig.transport.calls.isEmpty)

        // And one that was already open when the feature went away cannot send either.
        rig.transport.isMergeAvailable = true
        rig.activate(MF.row(pr))
        XCTAssertNotNil(rig.session, "precondition")
        rig.transport.isMergeAvailable = false
        rig.confirm()
        XCTAssertTrue(rig.transport.calls.isEmpty, "the request is never sent without the feature")
        if case .merging? = progress(rig, pr) { XCTFail("the row must not be left Merging… for a request that was never sent") }
    }

    // MARK: - Confirming

    func testConfirmSendsOneRequestForTheRowAndMarksItMerging() throws {
        let rig = makeRig()
        let pr = MF.readyPr(458, head: MF.headA)

        rig.activate(MF.row(pr))
        XCTAssertTrue(rig.transport.calls.isEmpty, "precondition: nothing yet")
        rig.confirm()

        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 458, head: MF.headA)])
        XCTAssertEqual(rig.merger.attempts[pr.id], AuthoredPrMergeAttempt(head: MF.headA, progress: .merging))
        XCTAssertNil(rig.merger.presented, "the confirmation is finished")
        XCTAssertGreaterThanOrEqual(rig.dismissals, 1, "and taken down")
    }

    func testTheRequestCarriesTheHeadOfTheRowThePersonSaw() {
        let rig = makeRig(allowEverything: true)
        let a = MF.readyPr(1, head: MF.headA), b = MF.readyPr(2, head: MF.headB)
        rig.mergeAndWait(a)
        rig.mergeAndWait(b)
        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 1, head: MF.headA),
                                             RecordingMergeTransport.Call(repo: MF.repo, number: 2, head: MF.headB)],
                       "each request carries its own row's head")
    }

    func testConfirmingTwiceSendsExactlyOneRequest() throws {
        let rig = makeRig()
        let pr = MF.readyPr()
        rig.activate(MF.row(pr))
        let session = try XCTUnwrap(rig.session)

        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        session.confirm(event: MF.human(in: rig.window), control: rig.control)

        XCTAssertEqual(rig.transport.calls.count, 1, "one confirm, one request, however many times it is pressed")

        rig.transport.answer(.ok(AuthoredPrDone()))
        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        XCTAssertEqual(rig.transport.calls.count, 1, "and not after the answer either")
    }

    func testConfirmDoesNothingForEveryInputThatIsNotAHumanGesture() throws {
        let rig = makeRig()
        let pr = MF.readyPr()
        rig.activate(MF.row(pr))
        let session = try XCTUnwrap(rig.session)

        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: rig.window)
            session.confirm(event: event, control: rig.control)
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was sent")
            XCTAssertTrue(rig.merger.presented === session, "\(kind): the confirmation is still open")
            XCTAssertTrue(rig.merger.attempts.isEmpty, "\(kind): the row is not Merging…")
        }
        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        XCTAssertEqual(rig.transport.calls.count, 1, "a person's click still sends: it was only the gesture that was refused")
    }

    func testPressingMergeInTheConfirmationWithNoPersonBehindItSendsNothing() throws {
        try HF.skipIfVoiceOver()
        let rig = makeRig()
        rig.activate(MF.row(MF.readyPr()))
        let session = try XCTUnwrap(rig.session)
        session.confirm(event: nil, control: rig.control)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.presented === session)
    }

    func testCancelSendsNothingAndCancellingAgainOrConfirmingAfterwardsDoesNothing() throws {
        let rig = makeRig()
        let pr = MF.readyPr()
        rig.activate(MF.row(pr))
        let session = try XCTUnwrap(rig.session)

        session.cancel()

        XCTAssertNil(rig.merger.presented)
        XCTAssertGreaterThanOrEqual(rig.dismissals, 1, "the popover is taken down")
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.attempts.isEmpty)

        let dismissed = rig.dismissals
        session.cancel()
        XCTAssertEqual(rig.dismissals, dismissed, "cancelling twice finishes once")
        session.confirm(event: MF.human(in: rig.window), control: rig.control)
        XCTAssertTrue(rig.transport.calls.isEmpty, "a cancelled confirmation cannot be confirmed")
        XCTAssertTrue(rig.merger.attempts.isEmpty)
    }

    func testOpeningAnotherConfirmationReplacesTheFirstWhichCanNoLongerSend() throws {
        let rig = makeRig(allowEverything: true)
        let a = MF.readyPr(1), b = MF.readyPr(2)
        rig.activate(MF.row(a))
        let first = try XCTUnwrap(rig.session)

        rig.activate(MF.row(b))

        XCTAssertFalse(rig.session === first, "the second confirmation replaced the first")
        XCTAssertEqual(rig.session?.confirmation.number, 2)
        first.confirm(event: MF.human(in: rig.window), control: rig.control)
        XCTAssertTrue(rig.transport.calls.isEmpty, "the replaced confirmation cannot send")
        rig.confirm()
        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 2, head: MF.headA)])
    }

    // MARK: - While it is pending, and after

    func testASecondPressWhileMergingOrMergedOpensNothing() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        let shown = rig.shown.count

        rig.activate(MF.row(pr))   // the model of the row as it was when it was ready
        rig.activate(MF.row(pr, attempt: rig.merger.attempts[pr.id]))
        XCTAssertEqual(rig.shown.count, shown, "while Merging… a press opens nothing")
        XCTAssertNil(rig.session)

        rig.transport.answer(.ok(AuthoredPrDone()))
        rig.activate(MF.row(pr))
        XCTAssertEqual(rig.shown.count, shown, "once Merged, neither")
        XCTAssertEqual(rig.transport.calls.count, 1, "and there was only ever the one request")
    }

    func testOkMarksTheRowMergedAndKeepsItSo() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        rig.transport.answer(.ok(AuthoredPrDone()))
        XCTAssertEqual(rig.merger.attempts[pr.id], AuthoredPrMergeAttempt(head: MF.headA, progress: .merged))
        rig.merger.rowsDidChange([MF.row(pr)])
        XCTAssertEqual(rig.merger.attempts[pr.id]?.progress, .merged, "a snapshot that still says open does not undo it")
    }

    func testEveryAnswerFailsTheAttemptWithItsCode() {
        for (wire, _) in MF.answerWords {
            let rig = makeRig(allowEverything: true)
            let pr = MF.readyPr()
            rig.mergeAndWait(pr)
            rig.transport.answer(.failed(code: wire))
            XCTAssertEqual(progress(rig, pr), AuthoredPrMergeProgress.failed(AuthoredPrMergeCode(wire: wire)), wire)
            XCTAssertEqual(rig.merger.attempts[pr.id]?.head, MF.headA, "\(wire): the attempt remembers the head it was about")
        }
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        rig.transport.answer(.unreachable)
        XCTAssertEqual(progress(rig, pr), AuthoredPrMergeProgress.failed(.unreachable), "no answer at all")
    }

    func testAnUnknownCodeIsAGenericFailureNeverMerged() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        rig.transport.answer(.failed(code: "a_code_from_the_future"))
        XCTAssertEqual(progress(rig, pr), AuthoredPrMergeProgress.failed(.unknown))
        XCTAssertNotEqual(progress(rig, pr), AuthoredPrMergeProgress.merged)
    }

    func testANewAttemptAfterAFailureIsAllowedAndReplacesIt() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.mergeAndWait(pr)
        rig.transport.answer(.failed(code: "behind"))
        XCTAssertEqual(progress(rig, pr), AuthoredPrMergeProgress.failed(.behind))

        rig.mergeAndWait(pr)

        XCTAssertEqual(rig.transport.calls.count, 2, "the person may try again")
        XCTAssertEqual(progress(rig, pr), .merging, "and the old failure is gone")
    }

    func testDismissingANoticeRemovesAFailureAndNothingElse() {
        let rig = makeRig(allowEverything: true)
        let failed = MF.readyPr(1), merging = MF.readyPr(2)
        rig.mergeAndWait(failed)
        rig.mergeAndWait(merging)
        rig.transport.answer(.failed(code: "blocked"))   // the oldest request: `failed`

        rig.merger.dismissNotice(rowId: failed.id)
        rig.merger.dismissNotice(rowId: merging.id)

        XCTAssertNil(rig.merger.attempts[failed.id], "the failure's notice is dismissed")
        XCTAssertEqual(rig.merger.attempts[merging.id]?.progress, .merging, "a merge in flight is not something to dismiss")
        rig.merger.dismissNotice(rowId: "no/such#1")
    }

    func testEachRowHasItsOwnAttempt() {
        let rig = makeRig(allowEverything: true)
        let a = MF.readyPr(1), b = MF.readyPr(2)
        rig.mergeAndWait(a)
        rig.mergeAndWait(b)
        XCTAssertEqual(rig.transport.calls.map(\.number), [1, 2])

        rig.transport.answer(.ok(AuthoredPrDone()))
        rig.transport.answer(.failed(code: "blocked"))

        XCTAssertEqual(rig.merger.attempts[a.id]?.progress, .merged)
        XCTAssertEqual(rig.merger.attempts[b.id]?.progress, AuthoredPrMergeProgress.failed(.blocked))
    }

    func testTheChangesPublisherSaysWhenAttemptsOrTheConfirmationChange() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        var last = rig.changeCount
        func moved(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertGreaterThan(rig.changeCount, last, what, file: file, line: line)
            last = rig.changeCount
        }

        rig.activate(MF.row(pr)); moved("opening a confirmation")
        rig.confirm(); moved("confirming")
        rig.transport.answer(.failed(code: "blocked")); moved("an answer")
        rig.merger.dismissNotice(rowId: pr.id); moved("dismissing a notice")
        rig.activate(MF.row(pr)); moved("opening again")
        rig.session?.cancel(); moved("cancelling")
    }

    // MARK: - rowsDidChange

    func testRowsDidChangeKeepsTheConfirmationWhileTheRowIsTheSame() throws {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr()
        rig.activate(MF.row(pr))
        let session = try XCTUnwrap(rig.session)

        rig.merger.rowsDidChange([MF.row(pr)])
        var retitled = pr
        retitled.title = "Fix the thing, retitled"
        rig.merger.rowsDidChange([MF.row(MF.readyPr(459)), MF.row(retitled)])

        XCTAssertTrue(rig.merger.presented === session, "same head, still ready: it stays")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testRowsDidChangeCancelsTheConfirmationWhenTheHeadMoved() throws {
        for reviewed in [false, true] {
            let rig = makeRig(allowEverything: true)
            let pr = MF.readyPr(458, head: MF.headA)
            rig.activate(MF.row(pr))
            let session = try XCTUnwrap(rig.session)

            // The new head, whether or not Perri has already approved it.
            rig.merger.rowsDidChange([MF.row(MF.pushed(pr, to: MF.headB, perriReviewedIt: reviewed))])

            XCTAssertNil(rig.merger.presented, "Perri reviewed the new head: \(reviewed): the confirmation is cancelled")
            XCTAssertGreaterThanOrEqual(rig.dismissals, 1)
            session.confirm(event: MF.human(in: rig.window), control: rig.control)
            XCTAssertTrue(rig.transport.calls.isEmpty, "a cancelled confirmation sends nothing")
        }
    }

    func testRowsDidChangeCancelsTheConfirmationWhenTheButtonIsNoLongerReadyOrTheRowIsGone() throws {
        let pr = MF.readyPr()
        var broken: [(String, [AuthoredPrRowModel])] = []
        broken.append(("checks failed", [MF.row(MF.readyPr(checks: AuthoredPrChecks(state: .failing, failed: 1)))]))
        broken.append(("Perri changed their mind", [MF.row(MF.readyPr(perri: MF.verdict(.changesRequested)))]))
        broken.append(("the human approval was withdrawn", [MF.row(MF.readyPr(review: AuthoredPrReview(state: .changesRequested)))]))
        broken.append(("the row moved out of READY", [MF.row(MF.readyPr(group: .waiting))]))
        broken.append(("the PR was merged elsewhere", [MF.row(MF.readyPr(group: .waiting, lifecycle: .merged))]))
        broken.append(("the row is gone", []))
        broken.append(("only other rows are left", [MF.row(MF.readyPr(459))]))
        for (what, rows) in broken {
            let rig = makeRig(allowEverything: true)
            rig.activate(MF.row(pr))
            XCTAssertNotNil(rig.session, "\(what): precondition")
            rig.merger.rowsDidChange(rows)
            XCTAssertNil(rig.merger.presented, "\(what): cancelled")
            XCTAssertTrue(rig.transport.calls.isEmpty, what)
        }
    }

    func testASnapshotAfterTheConfirmDoesNotChangeTheRequest() {
        let rig = makeRig(allowEverything: true)
        let pr = MF.readyPr(458, head: MF.headA)
        rig.mergeAndWait(pr)

        // A push lands after the request left: it does not matter, the request already carried head A.
        rig.merger.rowsDidChange([MF.row(MF.pushed(pr, to: MF.headB, perriReviewedIt: true))])

        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 458, head: MF.headA)])
        XCTAssertEqual(rig.merger.attempts[pr.id], AuthoredPrMergeAttempt(head: MF.headA, progress: .merging),
                       "the attempt is still about the head that was sent")
    }

    // MARK: - One entry, one request shape

    private final class OneEntryTransport: AuthoredPrMergeTransport {
        var isMergeAvailable = true
        var requests = 0
        func merge(repo: String, number: Int, expectedHeadShaShort: String,
                   done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
            requests += 1
        }
    }

    func testThereIsNoWayToMergeButTheOneVerbAndItNeedsTheExpectedHead() throws {
        // `OneEntryTransport` implements `isMergeAvailable` and `merge(repo:number:expectedHeadShaShort:done:)` and
        // nothing else: it compiles only while the protocol asks for nothing more (no admin path, no force flag,
        // no second entry), and a merger drives it with exactly one call per confirm.
        let transport = OneEntryTransport()
        let merger = AuthoredPrMerger(transport: transport, permit: { _, _, _ in true })
        let window = GestureFixtures.offscreenWindow()
        defer { window.close() }
        let control = HF.control(in: window)
        var session: AuthoredPrMergeSession?
        merger.present = { s, _ in session = s }
        merger.activate(MF.row(MF.readyPr()), anchor: control, event: MF.human(in: window), control: control)
        XCTAssertEqual(transport.requests, 0, "pressing is not merging")
        try XCTUnwrap(session).confirm(event: MF.human(in: window), control: control)
        XCTAssertEqual(transport.requests, 1)

        // And the request has the five documented keys, the head among them: there is nothing to add to it.
        let request = ClientAuthoredPrMerge(requestId: "r", repo: MF.repo, number: 1, expectedHeadShaShort: MF.headA)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["type", "request_id", "repo", "number", "expected_head_sha_short"])
    }
}

// MARK: - The confirmation popover's content

final class AuthoredPrMergeConfirmationViewTests: MouseQueueTestCase {

    private var rigs: [MergeRig] = []

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    /// A confirmation for `pr` and its popover content, in the window.
    private func open(_ pr: AuthoredPr = MF.readyPr(), allowEverything: Bool = false)
        throws -> (rig: MergeRig, session: AuthoredPrMergeSession, vc: AuthoredPrMergeViewController) {
        let rig = MergeRig(allowEverything: allowEverything)
        rigs.append(rig)
        rig.activate(MF.row(pr))
        let session = try XCTUnwrap(rig.session)
        let vc = AuthoredPrMergeViewController(session: session)
        rig.window.contentView?.addSubview(vc.view)
        return (rig, session, vc)
    }

    func testTheMessageIsTheConfirmationsTextVerbatimAndPlain() throws {
        let (_, session, vc) = try open()
        XCTAssertEqual(vc.messageLabel.stringValue,
                       "Squash and merge #458 Fix the thing into main? Head 0aaaaaaa. Perri approved. Human approval: yes. Checks: green.")
        XCTAssertEqual(vc.messageLabel.stringValue, session.confirmation.message)
        XCTAssertFalse(vc.messageLabel.allowsEditingTextAttributes, "plain text")
        XCTAssertFalse(APT.hasLink(vc.messageLabel.attributedStringValue), "no link is made out of it")
    }

    func testTheConfirmationSaysWhoRecordedAnApprovalThatWasNotPerris() throws {
        let (_, _, vc) = try open(MF.readyPr(perri: MF.verdict(by: "cody:focus-x")))
        XCTAssertTrue(vc.messageLabel.stringValue.contains("Approval recorded by cody:focus-x, not by Perri."),
                      vc.messageLabel.stringValue)
        XCTAssertFalse(vc.messageLabel.stringValue.contains("Perri approved."), "it does not say Perri approved")
    }

    func testAPrTitleWithMarkupIsShownAsTextNotRendered() throws {
        let title = "**bold** <b>x</b> [a link](https://example.com) `code`"
        let (_, session, vc) = try open(MF.readyPr(title: title))
        XCTAssertTrue(vc.messageLabel.stringValue.contains(title), "the words are the PR's, character for character")
        XCTAssertEqual(vc.messageLabel.stringValue, session.confirmation.message)
        XCTAssertFalse(APT.hasLink(vc.messageLabel.attributedStringValue))
    }

    func testTheMessageNeverCarriesControlOrBidiCharactersOrALongTitle() throws {
        let raw = "Fix\u{202E}\nthe thing\u{7}" + String(repeating: "x", count: 300)
        let (_, _, vc) = try open(MF.readyPr(title: raw))
        let text = vc.messageLabel.stringValue
        XCTAssertFalse(text.unicodeScalars.contains { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format || category == .lineSeparator || category == .paragraphSeparator
        }, text.debugDescription)
        XCTAssertTrue(text.contains("…"), "a title cut at 80 characters says so")
        XCTAssertLessThan(text.count, 250, "300 characters of someone else's words do not fill the popover")
    }

    func testTheConfirmationsKeysAreCancelDefaultEscapeCancelsAndMergeHasNoKeyEquivalent() throws {
        let (rig, _, vc) = try open(allowEverything: true)
        XCTAssertEqual(vc.cancelButton.title, "Cancel")
        XCTAssertEqual(vc.mergeButton.title, "Merge")
        XCTAssertEqual(vc.cancelButton.keyEquivalent, "\r", "Cancel is the default button: Return cancels")
        XCTAssertEqual(vc.mergeButton.keyEquivalent, "", "Merge can only be pressed, never reached by a key")
        // No other control in the popover has one either.
        for button in APT.descendants(of: vc.view).compactMap({ $0 as? NSButton }) where button !== vc.cancelButton {
            XCTAssertEqual(button.keyEquivalent, "", "\(button.title)")
        }

        // Return does not merge: it reaches Cancel, never Merge.
        XCTAssertFalse(vc.mergeButton.performKeyEquivalent(with: MF.humanReturn(in: rig.window)))
        XCTAssertTrue(rig.transport.calls.isEmpty, "Return never merges")

        // Escape cancels.
        vc.cancelOperation(nil)
        XCTAssertNil(rig.merger.presented, "Escape cancels the confirmation")
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.attempts.isEmpty)
    }

    func testCancelCancelsWithoutAPersonsGestureAndSendsNothing() throws {
        let (rig, _, vc) = try open()   // the live gesture check: Cancel is not gated, only Merge is
        vc.cancelButton.performClick(nil)
        XCTAssertNil(rig.merger.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.attempts.isEmpty)
    }

    func testMergeSendsExactlyOneRequestThenIsDone() throws {
        let (rig, _, vc) = try open(allowEverything: true)
        vc.mergeButton.performClick(nil)
        vc.mergeButton.performClick(nil)
        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 458, head: MF.headA)])
        XCTAssertEqual(rig.merger.attempts["\(MF.repo)#458"]?.progress, .merging)
        XCTAssertNil(rig.merger.presented)
    }

    func testPressingMergeWithNoPersonBehindItSendsNothingAndLeavesTheConfirmationOpen() throws {
        try HF.skipIfVoiceOver()
        let (rig, session, vc) = try open()   // live check: `performClick` carries no click of this window
        vc.mergeButton.performClick(nil)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.merger.presented === session, "still open: the person can click it")
        XCTAssertTrue(vc.mergeButton.isEnabled)
    }

    func testARefusedGestureOnMergeLeavesTheConfirmationOpenForEveryKind() throws {
        let (rig, session, vc) = try open()
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: rig.window)
            session.confirm(event: event, control: vc.mergeButton)
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind)")
            XCTAssertTrue(rig.merger.presented === session, "\(kind): still open")
            XCTAssertTrue(vc.mergeButton.isEnabled, "\(kind)")
        }
    }
}

// MARK: - The live transport

final class AuthoredPrMergeLiveTransportTests: XCTestCase {

    private func ok() -> AuthoredPrAnswer<AuthoredPrDone> { .ok(AuthoredPrDone()) }

    func testAvailabilityIsWhatTheDaemonAdvertised() {
        let fixture = LiveMergeFixture()
        XCTAssertTrue(fixture.transport.isMergeAvailable)
        fixture.mergeSupported = false
        XCTAssertFalse(fixture.transport.isMergeAvailable, "the daemon (or the link) went away")
    }

    func testItSendsOneMergeRequestWithTheRepoNumberAndExpectedHeadAndNothingElse() throws {
        let fixture = LiveMergeFixture()
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "thehammer/nostromo", number: 458, expectedHeadShaShort: "0123abcd") { answers.append($0) }

        XCTAssertEqual(fixture.sent.count, 1)
        let request = try XCTUnwrap(fixture.sent.first)
        XCTAssertEqual(request.repo, "thehammer/nostromo")
        XCTAssertEqual(request.number, 458)
        XCTAssertEqual(request.expectedHeadShaShort, "0123abcd")
        XCTAssertFalse(request.requestId.isEmpty)
        XCTAssertEqual(fixture.otherSends, 0, "a merge is not a preview, a notify, a start or a link")
        XCTAssertTrue(answers.isEmpty, "nothing answers until the daemon does")
    }

    func testTheAnswerForItsRequestIdIsDeliveredOnce() throws {
        let fixture = LiveMergeFixture()
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0) }
        let id = try XCTUnwrap(fixture.sent.first).requestId

        fixture.transport.deliver(.merge(requestId: id, ok()))
        fixture.transport.deliver(.merge(requestId: id, ok()))

        XCTAssertEqual(answers, [ok()], "answered once")
    }

    func testAFailureCodeIsPassedThrough() throws {
        let fixture = LiveMergeFixture()
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0) }
        let id = try XCTUnwrap(fixture.sent.first).requestId
        fixture.transport.deliver(.merge(requestId: id, .failed(code: "perri_stale")))
        XCTAssertEqual(answers, [.failed(code: "perri_stale")])
    }

    func testAnAnswerForAnotherRequestIsIgnored() throws {
        let fixture = LiveMergeFixture()
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0) }
        let id = try XCTUnwrap(fixture.sent.first).requestId

        fixture.transport.deliver(.merge(requestId: "someone-elses-request", ok()))
        fixture.transport.deliver(.merge(requestId: id + "x", ok()))
        XCTAssertTrue(answers.isEmpty, "not this request's answer")

        fixture.transport.deliver(.merge(requestId: id, .failed(code: "blocked")))
        XCTAssertEqual(answers, [.failed(code: "blocked")], "and the right one still gets through")
    }

    func testAFrameOfAnotherVerbWithTheMergesIdIsUnreachable() throws {
        let frames: [(String, (String) -> AuthoredPrAnswerFrame)] = [
            ("preview", { .preview(requestId: $0, .failed(code: "unknown_pr")) }),
            ("notify", { .notify(requestId: $0, .ok(AuthoredPrDone())) }),
            ("link", { .link(requestId: $0, .ok(AuthoredPrDone())) }),
            ("start session", { .startSession(requestId: $0, .ok(AuthoredPrStarted(tag: "t"))) }),
        ]
        for (name, make) in frames {
            let fixture = LiveMergeFixture()
            var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
            fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0) }
            let id = try XCTUnwrap(fixture.sent.first).requestId

            fixture.transport.deliver(make(id))

            XCTAssertEqual(answers, [.unreachable], "\(name): not a merge answer, so the merge is not known to have happened")
        }
    }

    func testTwoMergesInFlightAreAnsweredEachByItsOwnId() throws {
        let fixture = LiveMergeFixture()
        var first: [AuthoredPrAnswer<AuthoredPrDone>] = [], second: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/a", number: 1, expectedHeadShaShort: "0123abcd") { first.append($0) }
        fixture.transport.merge(repo: "o/b", number: 2, expectedHeadShaShort: "4567abcd") { second.append($0) }
        XCTAssertEqual(fixture.sent.count, 2)
        XCTAssertNotEqual(fixture.sent[0].requestId, fixture.sent[1].requestId)

        fixture.transport.deliver(.merge(requestId: fixture.sent[1].requestId, .failed(code: "behind")))
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.failed(code: "behind")])
        fixture.transport.deliver(.merge(requestId: fixture.sent[0].requestId, ok()))
        XCTAssertEqual(first, [ok()])
    }

    func testAnUnansweredRequestIsUnreachableAfterTheTimeoutAndALateAnswerIsIgnored() throws {
        let fixture = LiveMergeFixture(timeout: 0.05)
        let answered = expectation(description: "the merge was answered unreachable")
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0); answered.fulfill() }
        let id = try XCTUnwrap(fixture.sent.first).requestId

        wait(for: [answered], timeout: 5)
        XCTAssertEqual(answers, [.unreachable])

        fixture.transport.deliver(.merge(requestId: id, ok()))
        XCTAssertEqual(answers, [.unreachable], "an answer after the timeout is not a second answer: the person was told it is unknown")
    }

    func testAnAnswerBeforeTheTimeoutIsNotFollowedByAnUnreachable() throws {
        let fixture = LiveMergeFixture(timeout: 0.1)
        var answers: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { answers.append($0) }
        let id = try XCTUnwrap(fixture.sent.first).requestId
        fixture.transport.deliver(.merge(requestId: id, ok()))

        let passed = expectation(description: "the timeout passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { passed.fulfill() }
        wait(for: [passed], timeout: 5)

        XCTAssertEqual(answers, [ok()], "answered once, and the timeout did not answer again")
    }

    func testALostConnectionAnswersPendingMergesUnreachableOnce() throws {
        let fixture = LiveMergeFixture()
        var first: [AuthoredPrAnswer<AuthoredPrDone>] = [], second: [AuthoredPrAnswer<AuthoredPrDone>] = []
        fixture.transport.merge(repo: "o/a", number: 1, expectedHeadShaShort: "0123abcd") { first.append($0) }
        fixture.transport.merge(repo: "o/b", number: 2, expectedHeadShaShort: "4567abcd") { second.append($0) }

        fixture.transport.connectionLost()
        fixture.transport.connectionLost()
        fixture.transport.deliver(.merge(requestId: fixture.sent[0].requestId, ok()))

        XCTAssertEqual(first, [.unreachable])
        XCTAssertEqual(second, [.unreachable])
    }
}

// MARK: - The rows in the Overview

final class AuthoredPrMergeOverviewTests: MouseQueueTestCase {

    private var rigs: [MergeOverviewRig] = []

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    private func makeRig(_ prs: [AuthoredPr], perri: Bool = true, merge: Bool = true, allowEverything: Bool = true) -> MergeOverviewRig {
        let rig = MergeOverviewRig(prs, perri: perri, merge: merge, allowEverything: allowEverything)
        rigs.append(rig)
        return rig
    }

    // MARK: What a row shows

    func testAReadyRowShowsItsBadgeAndAnEnabledMergeButton() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        let row = try rig.rowView(pr)

        XCTAssertFalse(row.perriLabel.isHidden)
        XCTAssertEqual(row.perriLabel.stringValue, "Perri ✓")
        XCTAssertEqual(row.perriLabel.toolTip, "Approved 5m ago by perri:cody-pr-1 · head 0aaaaaaa")
        XCTAssertEqual(row.perriLabel.accessibilityLabel(), "Perri approved this version")
        XCTAssertTrue(try XCTUnwrap(row.accessibilityLabel()).hasSuffix(", Perri approved this version"), "VoiceOver hears the verdict")

        XCTAssertFalse(row.mergeButton.isHidden)
        XCTAssertEqual(row.mergeButton.title, "Merge")
        XCTAssertTrue(row.mergeButton.isEnabled)
        XCTAssertTrue(row.mergeButton.toolTip?.contains("Squash") == true, "\(String(describing: row.mergeButton.toolTip))")
        XCTAssertEqual(row.mergeButton.accessibilityLabel(), "Merge PR 458")
        XCTAssertTrue(row.noticeLabel.isHidden)
        XCTAssertTrue(row.noticeDismissButton.isHidden)
    }

    func testEachBadgeKindIsShownOnItsRow() throws {
        let cases: [(AuthoredPr, String, String)] = [
            (MF.readyPr(1, perri: MF.verdict(.approved)), "Perri ✓", "Perri approved this version"),
            (MF.readyPr(2, perri: MF.verdict(.approved, current: false)), "Perri ✓ older", "Perri approved an older version"),
            (MF.readyPr(3, perri: MF.verdict(.changesRequested)), "Perri ✗", "Perri requested changes"),
            (MF.readyPr(4, perri: MF.verdict(.comment)), "Perri comments", "Perri left comments"),
        ]
        let rig = makeRig(cases.map { $0.0 })
        for (pr, text, spoken) in cases {
            let row = try rig.rowView(pr)
            XCTAssertFalse(row.perriLabel.isHidden, pr.id)
            XCTAssertEqual(row.perriLabel.stringValue, text, pr.id)
            XCTAssertEqual(row.perriLabel.accessibilityLabel(), spoken, pr.id)
            XCTAssertFalse(try XCTUnwrap(row.perriLabel.toolTip).isEmpty, "\(pr.id): the tooltip says when and by whom")
        }
        let older = try rig.rowView(cases[1].0).perriLabel.toolTip ?? ""
        XCTAssertTrue(older.contains("A new push needs a new review"), older)
    }

    func testNoBadgeWithoutAVerdictOrWithAStaleNonApprovalOrOnAMergedRow() throws {
        let prs = [
            MF.readyPr(1, perri: nil),
            MF.readyPr(2, perri: MF.verdict(.unknown)),
            MF.readyPr(3, perri: MF.verdict(.changesRequested, current: false)),
            MF.readyPr(4, perri: MF.verdict(.comment, current: false)),
            MF.readyPr(5, group: .waiting, lifecycle: .merged),
        ]
        let rig = makeRig(prs)
        for pr in prs {
            XCTAssertTrue(try rig.rowView(pr).perriLabel.isHidden, "\(pr.id): no badge")
        }
    }

    func testAnUnavailableButtonIsShownOffWithItsReasonAndPressingItOpensNothing() throws {
        let cases = MF.unavailableCases
        let rig = makeRig(cases.map(\.pr))
        for (name, pr, reason) in cases {
            let row = try rig.rowView(pr)
            XCTAssertFalse(row.mergeButton.isHidden, "\(name): shown, so the person sees why it is off")
            XCTAssertFalse(row.mergeButton.isEnabled, name)
            XCTAssertEqual(row.mergeButton.title, "Merge", name)
            XCTAssertEqual(row.mergeButton.toolTip, reason, name)
            XCTAssertEqual(row.mergeButton.accessibilityLabel(), "Merge, unavailable: \(reason)", name)
            XCTAssertTrue(row.reviewLabel.stringValue.hasSuffix(" · \(reason)"), "\(name): the reason is visible on the row: \(row.reviewLabel.stringValue)")

            // A press (even a forged one straight at the merger) opens nothing.
            row.mergeButton.performClick(nil)
            let model = try XCTUnwrap(row.model)
            rig.merger.activate(model, anchor: row, event: MF.human(in: rig.window), control: row.mergeButton)
            XCTAssertNil(rig.merger.presented, "\(name): nothing opened")
        }
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.rig.shown.isEmpty)
    }

    func testNoButtonOnARowThatIsNotAnOpenRowOfReady() throws {
        let prs = [
            MF.readyPr(1, group: .needsYou),
            MF.readyPr(2, group: .waiting),
            MF.readyPr(3, group: .draft, draft: true),
            MF.readyPr(4, group: .waiting, lifecycle: .merged),
            MF.readyPr(5, group: .waiting, lifecycle: .closed),
        ]
        let rig = makeRig(prs)
        for pr in prs {
            let row = try rig.rowView(pr)
            XCTAssertTrue(row.mergeButton.isHidden, "\(pr.id): no button")
            XCTAssertNil(row.model?.mergeButton, pr.id)
            XCTAssertFalse(row.reviewLabel.stringValue.contains("Needs Perri"), "\(pr.id): no reason, there is no button")
            XCTAssertFalse((row.accessibilityCustomActions() ?? []).contains { $0.name == "Merge" }, pr.id)
        }
    }

    // MARK: Feature gating

    func testNoBadgeWithoutPerriAndNoButtonWithoutBothFeatures() throws {
        let pr = MF.readyPr()
        let none = makeRig([pr], perri: false, merge: false)
        XCTAssertTrue(try none.rowView(pr).perriLabel.isHidden)
        XCTAssertTrue(try none.rowView(pr).mergeButton.isHidden)

        let mergeWithoutPerri = makeRig([pr], perri: false, merge: true)
        XCTAssertTrue(try mergeWithoutPerri.rowView(pr).perriLabel.isHidden, "no Perri feature: no badge")
        XCTAssertTrue(try mergeWithoutPerri.rowView(pr).mergeButton.isHidden, "no Perri feature: the button cannot be judged")

        let perriWithoutMerge = makeRig([pr], perri: true, merge: false)
        XCTAssertFalse(try perriWithoutMerge.rowView(pr).perriLabel.isHidden, "Perri's verdict is shown")
        XCTAssertTrue(try perriWithoutMerge.rowView(pr).mergeButton.isHidden, "but a daemon that cannot merge gets no dead control")

        let both = makeRig([pr])
        XCTAssertFalse(try both.rowView(pr).mergeButton.isHidden)
    }

    func testFeaturesComingAndGoingRebuildTheRows() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr], perri: false, merge: false)
        XCTAssertFalse(rig.overview.perriAvailable)
        XCTAssertFalse(rig.overview.mergeAvailable)

        rig.overview.setPerriAvailable(true)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(rig.overview.perriAvailable)
        XCTAssertFalse(try rig.rowView(pr).perriLabel.isHidden)
        XCTAssertTrue(try rig.rowView(pr).mergeButton.isHidden, "still no merge feature")

        rig.overview.setMergeAvailable(true)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertFalse(try rig.rowView(pr).mergeButton.isHidden)

        rig.overview.setPerriAvailable(false)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(try rig.rowView(pr).perriLabel.isHidden)
        XCTAssertTrue(try rig.rowView(pr).mergeButton.isHidden, "without Perri's verdicts the button goes too")

        rig.overview.setPerriAvailable(true)
        rig.overview.setMergeAvailable(false)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(try rig.rowView(pr).mergeButton.isHidden)
    }

    // MARK: Pressing

    func testPressingTheButtonOpensTheConfirmationAnchoredOnTheRowAndSendsNothing() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        let row = try rig.rowView(pr)

        try rig.press(pr)

        let session = try XCTUnwrap(rig.merger.presented, "the press opens the confirmation")
        XCTAssertEqual(session.confirmation.expectedHeadShaShort, MF.headA)
        XCTAssertEqual(session.confirmation.number, 458)
        XCTAssertTrue(rig.rig.shown.last?.anchor === row, "the popover is anchored on the row")
        XCTAssertTrue(rig.transport.calls.isEmpty, "and nothing was sent")
    }

    func testTheRowsButtonDoesNothingForEveryInputThatIsNotAHumanGesture() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr], allowEverything: false)
        // A refused press now leaves a word on the row, which rebuilds the row: each press below goes to the row
        // as it is NOW (a person only ever clicks the live button, never one the rebuild replaced).
        for kind in NotAHumanGesture.allCases {
            let row = try rig.rowView(pr)
            let model = try XCTUnwrap(row.model)
            let event = try kind.event(in: rig.window)
            rig.merger.activate(model, anchor: row, event: event, control: row.mergeButton)
            XCTAssertNil(rig.merger.presented, "\(kind): nothing opened")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind): nothing was asked of the daemon")
        }
        let row = try rig.rowView(pr)
        let model = try XCTUnwrap(row.model)
        rig.merger.activate(model, anchor: row, event: MF.human(in: rig.window), control: row.mergeButton)
        XCTAssertNotNil(rig.merger.presented, "a person's click is accepted")
    }

    func testAPressWithNoPersonBehindItDoesNothing() throws {
        try HF.skipIfVoiceOver()
        let pr = MF.readyPr()
        let rig = makeRig([pr], allowEverything: false)
        try rig.press(pr)   // `performClick`: the action runs with whatever `NSApp.currentEvent` is (none, or not this window's click)
        XCTAssertNil(rig.merger.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertEqual(try rig.noticeText(pr), "Merge was refused: use the button", "the row says so instead of nothing happening")
    }

    func testReturnNeverMergesOrOpensAConfirmation() throws {
        let ready = MF.readyPr(1), off = MF.readyPr(2, perri: nil)
        let rig = makeRig([ready, off])
        for pr in [ready, off] {
            rig.overview.selectRow(id: pr.id)
            rig.outline.keyDown(with: MF.humanReturn(in: rig.window))
            rig.overview.activateSelected(event: MF.humanReturn(in: rig.window))
            XCTAssertNil(rig.merger.presented, "\(pr.id): Return opens no confirmation")
        }
        XCTAssertTrue(rig.transport.calls.isEmpty, "Return never merges")
        XCTAssertTrue(rig.merger.attempts.isEmpty)
        XCTAssertTrue(rig.rig.shown.isEmpty)
    }

    func testTheContextMenuHasNoMergeItemAndNoNewKeyEquivalents() throws {
        let ready = MF.readyPr(1, owner: APT.motherOwner()), off = MF.readyPr(2, perri: nil)
        let linked = MF.readyPr(3, owner: AuthoredPrOwner(kind: .linked, tag: "focus-x", name: "Focus X"))
        let rig = makeRig([ready, off, linked])
        for pr in [ready, off, linked] {
            let menu = try XCTUnwrap(rig.overview.contextMenu(forRowId: pr.id), pr.id)
            XCTAssertFalse(menu.items.isEmpty, pr.id)
            for item in menu.items {
                XCTAssertFalse(item.title.lowercased().contains("merge"),
                               "\(pr.id): '\(item.title)': merging is only ever done from the button and its confirmation")
                if item.title == "Open on GitHub" {
                    XCTAssertEqual(item.keyEquivalent, "o")
                    XCTAssertEqual(item.keyEquivalentModifierMask, .command)
                } else {
                    XCTAssertEqual(item.keyEquivalent, "", "\(pr.id): '\(item.title)' has no key equivalent")
                }
            }
        }
    }

    // MARK: Pending, merged and failed

    func testWhileMergingTheButtonSaysMergingIsOffAndASecondPressOpensNothing() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)

        XCTAssertEqual(try rig.buttonTitle(pr), "Merging…")
        XCTAssertFalse(try rig.buttonIsEnabled(pr))
        XCTAssertEqual(try rig.rowView(pr).mergeButton.accessibilityLabel(), "Merge PR 458, merging")

        try rig.press(pr)
        rig.merger.activate(try XCTUnwrap(try rig.rowView(pr).model), anchor: try rig.rowView(pr), event: MF.human(in: rig.window),
                            control: try rig.rowView(pr).mergeButton)
        XCTAssertNil(rig.merger.presented, "a second press opens nothing")
        XCTAssertEqual(rig.transport.calls.count, 1, "and sends nothing")
    }

    func testOkShowsMergedAndNeverRegroupsTheRow() throws {
        let pr = MF.readyPr()
        let other = MF.readyPr(459), waiting = MF.readyPr(460, group: .waiting)
        let rig = makeRig([pr, other, waiting])
        let groups = rig.overview.groupTitles
        let ids = rig.overview.displayedRowIds
        XCTAssertEqual(groups, ["READY", "WAITING ON OTHERS"], "precondition")
        try rig.mergeAndWait(pr)

        rig.answer(.ok(AuthoredPrDone()))

        XCTAssertEqual(try rig.buttonTitle(pr), "Merged")
        XCTAssertFalse(try rig.buttonIsEnabled(pr))
        XCTAssertNil(try rig.noticeText(pr), "success has no notice")
        XCTAssertEqual(rig.overview.groupTitles, groups, "the row is not moved on the strength of our own request")
        XCTAssertEqual(rig.overview.displayedRowIds, ids)

        // A snapshot that still says open keeps the Merged state; one that says merged takes over.
        rig.apply([pr, other, waiting])
        XCTAssertEqual(try rig.buttonTitle(pr), "Merged", "kept while the row is open")
        var done = pr
        done.lifecycle = .merged
        done.group = .waiting
        rig.apply([done, other, waiting])
        XCTAssertTrue(try rig.rowView(done).mergeButton.isHidden, "the lifecycle left open: the real status takes over")
        XCTAssertTrue(try rig.rowView(done).statusLabel.stringValue.contains("Merged"))
    }

    func testEveryAnswerShowsItsWordsOnTheRowAndANewAttemptClearsThem() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        for (wire, words) in MF.answerWords {
            try rig.mergeAndWait(pr)
            XCTAssertNil(try rig.noticeText(pr), "\(wire): a new attempt clears the old notice")
            XCTAssertEqual(try rig.buttonTitle(pr), "Merging…", wire)

            rig.answer(.failed(code: wire))

            XCTAssertEqual(try rig.noticeText(pr), words, "\(wire): its words are on the row")
            XCTAssertEqual(try rig.buttonTitle(pr), "Merge", "\(wire): the button is back, as the row is still ready")
            XCTAssertTrue(try rig.buttonIsEnabled(pr), wire)
            XCTAssertFalse(try rig.rowView(pr).noticeDismissButton.isHidden, "\(wire): and it can be dismissed")
        }
    }

    func testAnAnswerThatNeverCameIsUnreachableOnTheRow() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.unreachable)
        XCTAssertEqual(try rig.noticeText(pr), MF.unreachableWords)
        XCTAssertEqual(try rig.noticeText(pr), "GitHub or Nostromo isn't reachable: check the PR before trying again")
        XCTAssertTrue(try XCTUnwrap(try rig.rowView(pr).accessibilityLabel()).hasSuffix(", merge failed: \(MF.unreachableWords)"))
    }

    func testAnUnknownCodeIsTheGenericWordsNeverMerged() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "something_the_daemon_will_say_next_year"))
        XCTAssertEqual(try rig.noticeText(pr), "The merge failed")
        XCTAssertEqual(try rig.buttonTitle(pr), "Merge", "never shown as Merged")
    }

    // MARK: The notice

    func testTheNoticeStaysUntilDismissed() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "blocked"))

        rig.apply([pr])
        rig.overview.tick()
        rig.clock.advance(120)
        rig.overview.tick()
        XCTAssertEqual(try rig.noticeText(pr), "GitHub's branch protection blocked it", "a snapshot of the same head does not clear it")

        try rig.rowView(pr).noticeDismissButton.performClick(nil)
        rig.overview.layoutSubtreeIfNeeded()

        XCTAssertNil(try rig.noticeText(pr), "dismissed")
        XCTAssertTrue(try rig.rowView(pr).noticeDismissButton.isHidden)
        XCTAssertNil(rig.merger.attempts[pr.id])
    }

    func testTheNoticeGoesWhenTheRowsHeadChanges() throws {
        let pr = MF.readyPr(458, head: MF.headA)
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "blocked"))
        XCTAssertNotNil(try rig.noticeText(pr), "precondition")

        // Someone pushed. The failure was about the old version: it is not shown against the new one.
        rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: true)])

        XCTAssertNil(try rig.noticeText(pr), "a notice about another version is gone")
        XCTAssertTrue(try rig.rowView(pr).noticeLabel.isHidden)
        XCTAssertEqual(try rig.buttonTitle(pr), "Merge")
        XCTAssertEqual(try rig.rowView(pr).model?.mergeButton?.confirmation?.expectedHeadShaShort, MF.headB)
    }

    func testAHeadChangedNoticeStaysThroughAHeadChange() throws {
        let pr = MF.readyPr(458, head: MF.headA)
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "head_changed"))

        rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: true)])
        XCTAssertEqual(try rig.noticeText(pr), "The PR changed since you looked: review it again",
                       "it is about exactly this, so it stays until dismissed or the next attempt")

        // The next attempt (against the new head) clears it.
        try rig.mergeAndWait(MF.pushed(pr, to: MF.headB, perriReviewedIt: true))
        XCTAssertNil(try rig.noticeText(pr))
        XCTAssertEqual(rig.transport.calls.last?.head, MF.headB, "and it carries the head the person saw this time")
    }

    func testAHeadChangedNoticeIsDismissable() throws {
        let pr = MF.readyPr(458, head: MF.headA)
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "head_changed"))
        rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: true)])

        try rig.rowView(pr).noticeDismissButton.performClick(nil)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertNil(try rig.noticeText(pr))
    }

    func testANoticeOnARowThatIsNoLongerOpenIsGone() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "blocked"))

        var closed = pr
        closed.lifecycle = .closed
        closed.group = .waiting
        rig.apply([closed])

        XCTAssertNil(try rig.noticeText(pr))
        XCTAssertTrue(try rig.rowView(pr).mergeButton.isHidden)
    }

    func testTheNoticeReplacesTheOwnerLineInPlaceAndTheRowKeepsItsHeight() throws {
        let pr = MF.readyPr(458, baseRef: "slash-commands-0", owner: APT.motherOwner())
        let rig = makeRig([pr])
        let row = try rig.rowView(pr)
        XCTAssertFalse(row.ownerPrefixLabel.isHiddenOrHasHiddenAncestor, "precondition: the owner line shows")
        XCTAssertFalse(row.baseLabel.isHiddenOrHasHiddenAncestor, "precondition: and so does the base")
        let index = try XCTUnwrap(rig.overview.outlineRow(forRowId: pr.id))
        let height = rig.outline.rect(ofRow: index).height

        try rig.mergeAndWait(pr)
        rig.answer(.failed(code: "perri_stale"))

        let noticed = try rig.rowView(pr)
        XCTAssertEqual(noticed.noticeLabel.stringValue, "Perri approved an older version: it needs a new review")
        XCTAssertFalse(noticed.noticeLabel.isHidden)
        XCTAssertFalse(noticed.noticeDismissButton.isHidden)
        for (name, view) in [("owner prefix", noticed.ownerPrefixLabel), ("owner job", noticed.jobButton),
                             ("owner suffix", noticed.ownerSuffixLabel), ("base", noticed.baseLabel)] as [(String, NSView)] {
            XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "\(name): the notice takes the owner line's place")
        }
        XCTAssertEqual(rig.outline.rect(ofRow: index).height, height, accuracy: 0.5, "same row height")
        XCTAssertEqual(noticed.frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5)

        noticed.noticeDismissButton.performClick(nil)
        rig.overview.layoutSubtreeIfNeeded()
        let back = try rig.rowView(pr)
        XCTAssertTrue(back.noticeLabel.isHidden)
        XCTAssertFalse(back.ownerPrefixLabel.isHiddenOrHasHiddenAncestor, "and the owner line returns")
        XCTAssertEqual(rig.outline.rect(ofRow: index).height, height, accuracy: 0.5)
    }

    func testRowsKeepTheirHeightInEveryMergeState() throws {
        let pr = MF.readyPr(458, owner: APT.motherOwner())
        let off = MF.readyPr(459, perri: nil)
        let rig = makeRig([pr, off])
        let index = try XCTUnwrap(rig.overview.outlineRow(forRowId: pr.id))
        let offIndex = try XCTUnwrap(rig.overview.outlineRow(forRowId: off.id))
        func heights(_ what: String) throws {
            for (i, id) in [(index, pr.id), (offIndex, off.id)] {
                XCTAssertEqual(rig.outline.rect(ofRow: i).height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(what): \(id)")
            }
            XCTAssertEqual(try rig.rowView(pr).frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, what)
            XCTAssertEqual(try rig.rowView(off).frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, what)
        }
        try heights("ready and unavailable")
        try rig.mergeAndWait(pr)
        try heights("merging")
        rig.answer(.failed(code: "blocked"))
        try heights("failed")
        try rig.mergeAndWait(pr)
        rig.answer(.ok(AuthoredPrDone()))
        try heights("merged")
    }

    // MARK: VoiceOver

    func testVoiceOverGetsAMergeActionOnlyWhileTheButtonIsReadyAndADismissActionOnlyWithANotice() throws {
        let pr = MF.readyPr(1, owner: APT.motherOwner())
        let off = MF.readyPr(2, perri: nil)
        let rig = makeRig([pr, off])
        func names(_ p: AuthoredPr) throws -> [String] { (try rig.rowView(p).accessibilityCustomActions() ?? []).map(\.name) }

        XCTAssertEqual(Set(try names(pr)), ["Merge", "Show Mother job a1b2c3"], "the existing action stays")
        XCTAssertEqual(try names(off), [], "an unavailable button offers no action")

        try rig.mergeAndWait(pr)
        XCTAssertEqual(Set(try names(pr)), ["Show Mother job a1b2c3"], "while Merging… there is nothing to do")
        rig.answer(.failed(code: "behind"))
        XCTAssertEqual(Set(try names(pr)), ["Merge", "Dismiss merge message", "Show Mother job a1b2c3"])

        let dismiss = try XCTUnwrap(try rig.rowView(pr).accessibilityCustomActions()?.first { $0.name == "Dismiss merge message" })
        XCTAssertTrue(dismiss.handler?() ?? false)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertNil(try rig.noticeText(pr), "the action dismissed the message")
        XCTAssertEqual(Set(try names(pr)), ["Merge", "Show Mother job a1b2c3"])
    }

    func testTheMergeActionIsTheButtonsPressAndIsGestureChecked() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        let action = try XCTUnwrap(try rig.rowView(pr).accessibilityCustomActions()?.first { $0.name == "Merge" })
        _ = action.handler?()
        XCTAssertNotNil(rig.merger.presented, "the action opens the confirmation, like the button")
        XCTAssertTrue(rig.transport.calls.isEmpty, "and sends nothing")

        let guarded = makeRig([pr], allowEverything: false)
        try HF.skipIfVoiceOver()
        let again = try XCTUnwrap(try guarded.rowView(pr).accessibilityCustomActions()?.first { $0.name == "Merge" })
        _ = again.handler?()
        XCTAssertNil(guarded.merger.presented, "with no person behind the press the gesture check refuses it")
        XCTAssertTrue(guarded.transport.calls.isEmpty)
        XCTAssertEqual(try guarded.noticeText(pr), "Merge was refused: use the button",
                       "a refused VoiceOver action tells the person what to do instead of nothing")
    }

    // MARK: Snapshots under an open confirmation

    func testASnapshotWithAnotherHeadWhileTheConfirmationIsOpenCancelsItAndSendsNothing() throws {
        for reviewed in [false, true] {
            let pr = MF.readyPr(458, head: MF.headA)
            let rig = makeRig([pr])
            try rig.press(pr)
            let session = try XCTUnwrap(rig.merger.presented, "precondition")

            rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: reviewed)])

            XCTAssertNil(rig.merger.presented, "Perri re-reviewed: \(reviewed): the head the person looked at is not the head now")
            XCTAssertTrue(rig.transport.calls.isEmpty)
            session.confirm(event: MF.human(in: rig.window), control: rig.outline)
            XCTAssertTrue(rig.transport.calls.isEmpty, "the old confirmation cannot send")
            let button = try XCTUnwrap(try rig.rowView(pr).model?.mergeButton)
            if reviewed {
                XCTAssertEqual(button.confirmation?.expectedHeadShaShort, MF.headB,
                               "the row now offers the new head's confirmation, to be read afresh")
            } else {
                XCTAssertFalse(button.isEnabled, "Perri has not reviewed the new head: nothing to confirm")
            }
        }
    }

    func testASnapshotAfterTheConfirmDoesNotChangeTheRequest() throws {
        let pr = MF.readyPr(458, head: MF.headA)
        let rig = makeRig([pr])
        try rig.mergeAndWait(pr)

        rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: true)])

        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 458, head: MF.headA)],
                       "the request carries the head the person saw, not the newest snapshot's")
        XCTAssertEqual(try rig.buttonTitle(pr), "Merging…", "still waiting for the answer to that request")

        rig.answer(.failed(code: "head_changed"))
        XCTAssertEqual(try rig.noticeText(pr), "The PR changed since you looked: review it again")
        XCTAssertEqual(try rig.buttonTitle(pr), "Merge", "and the row is ready again for the new head, to be read before pressing")
    }

    func testASnapshotThatKeepsTheHeadAndTheReadinessKeepsTheConfirmationOpen() throws {
        let pr = MF.readyPr()
        let rig = makeRig([pr])
        try rig.press(pr)
        let session = try XCTUnwrap(rig.merger.presented)

        var retitled = pr
        retitled.title = "Fix the thing, retitled"
        retitled.newComments = 2
        rig.apply([retitled])

        XCTAssertTrue(rig.merger.presented === session, "same head, still ready: nothing to re-read")
    }

    func testASnapshotThatMakesTheRowNotReadyCancelsTheConfirmation() throws {
        let broken: [(String, AuthoredPr)] = [
            ("checks failed", MF.readyPr(checks: AuthoredPrChecks(state: .failing, failed: 1))),
            ("Perri changed their mind", MF.readyPr(perri: MF.verdict(.changesRequested))),
            ("it became a draft", MF.readyPr(group: .draft, draft: true)),
            ("it moved to waiting", MF.readyPr(group: .waiting)),
            ("it was merged elsewhere", MF.readyPr(group: .waiting, lifecycle: .merged)),
        ]
        for (what, changed) in broken {
            let pr = MF.readyPr()
            let rig = makeRig([pr])
            try rig.press(pr)
            XCTAssertNotNil(rig.merger.presented, "\(what): precondition")
            rig.apply([changed])
            XCTAssertNil(rig.merger.presented, "\(what): cancelled")
            XCTAssertTrue(rig.transport.calls.isEmpty, what)
        }
    }

    func testASnapshotThatDropsTheRowCancelsTheConfirmation() throws {
        let pr = MF.readyPr(), other = MF.readyPr(459)
        let rig = makeRig([pr, other])
        try rig.press(pr)
        rig.apply([other])
        XCTAssertNil(rig.merger.presented)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: Held and stale rows act on their own head

    func testAHeldRowThatTheSnapshotRegroupedActsOnItsOwnFreshFields() throws {
        let pr = MF.readyPr(458, head: MF.headA), other = MF.readyPr(459)
        let rig = makeRig([pr, other])
        rig.overview.setHovered(rowId: pr.id)

        // The snapshot moves the row to NEEDS YOU with a failing check and a new head: the row stays under the
        // pointer in READY, but what it says and what its button does are the new facts.
        var moved = MF.pushed(pr, to: MF.headB, perriReviewedIt: true)
        moved.group = .needsYou
        moved.checks = AuthoredPrChecks(state: .failing, passed: 2, failed: 1, failingNames: ["lint"])
        rig.apply([moved, other])

        XCTAssertTrue(rig.overview.displayedRowIds.contains(pr.id), "precondition: the row is held")
        let row = try rig.rowView(pr)
        XCTAssertFalse(row.mergeButton.isHidden, "it is still in READY, so it still has its button")
        XCTAssertFalse(row.mergeButton.isEnabled, "but the button says what is true now")
        XCTAssertEqual(row.mergeButton.toolTip, "Checks not green")

        row.mergeButton.performClick(nil)
        rig.merger.activate(try XCTUnwrap(row.model), anchor: row, event: MF.human(in: rig.window), control: row.mergeButton)
        XCTAssertNil(rig.merger.presented, "nothing opens on a stale promise of readiness")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testAHeldRowWhoseHeadMovedOffersTheNewHeadsConfirmationNotTheOldOne() throws {
        let pr = MF.readyPr(458, head: MF.headA)
        let rig = makeRig([pr])
        rig.overview.setHovered(rowId: pr.id)
        rig.apply([MF.pushed(pr, to: MF.headB, perriReviewedIt: true)])

        try rig.press(pr)
        XCTAssertEqual(rig.merger.presented?.confirmation.expectedHeadShaShort, MF.headB)
        rig.confirm()
        XCTAssertEqual(rig.transport.calls.map(\.head), [MF.headB], "the held row acts on its own head")
    }
}

// MARK: - The Overview bound to the store

final class AuthoredPrMergeStoreTests: MouseQueueTestCase {

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        AppStore.shared.resetAuthoredPrsForTesting()
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        AppStore.shared.resetAuthoredPrsForTesting()
        super.tearDown()
    }

    func testTheStoresFlagsAreTrueOnlyWhenTheDaemonListsPrsAndAdvertisedTheFeature() {
        let store = AppStore.shared
        XCTAssertFalse(store.authoredPrsPerriSupported)
        XCTAssertFalse(store.authoredPrsMergeSupported)

        store.daemonConnectedForTesting(authoredPrs: true, notify: false, perri: true, merge: false)
        XCTAssertTrue(store.authoredPrsPerriSupported)
        XCTAssertFalse(store.authoredPrsMergeSupported)

        store.daemonConnectedForTesting(authoredPrs: true, notify: true, perri: true, merge: true)
        XCTAssertTrue(store.authoredPrsPerriSupported)
        XCTAssertTrue(store.authoredPrsMergeSupported)

        store.daemonConnectedForTesting(authoredPrs: false, notify: true, perri: true, merge: true)
        XCTAssertFalse(store.authoredPrsPerriSupported, "a daemon that does not list PRs has nothing to show a verdict on")
        XCTAssertFalse(store.authoredPrsMergeSupported)

        store.daemonConnectedForTesting(authoredPrs: true, perri: true, merge: true)
        store.resetAuthoredPrsForTesting()
        XCTAssertFalse(store.authoredPrsPerriSupported, "a test leaves the shared store as it found it")
        XCTAssertFalse(store.authoredPrsMergeSupported)
    }

    func testAnOverviewBoundToTheStoreFollowsItsFlagsAndUsesItsMerger() throws {
        let store = AppStore.shared
        let pr = MF.readyPr()
        store.daemonConnectedForTesting(authoredPrs: true, notify: false, perri: true, merge: true)
        let window = APT.window(size: NSSize(width: 700, height: 600))
        windows.append(window)
        let overview = AuthoredPrsOverviewView(clock: APT.FakeClock().read, timeZone: APT.utc, store: store)
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        store.applyAuthoredPrsForTesting(APT.snapshot([pr]))
        overview.layoutSubtreeIfNeeded()

        XCTAssertTrue(overview.perriAvailable)
        XCTAssertTrue(overview.mergeAvailable)
        XCTAssertTrue(overview.merger === store.authoredPrMerger, "the Overview merges through the store's merger")
        var row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertFalse(row.perriLabel.isHidden)
        XCTAssertFalse(row.mergeButton.isHidden)

        // The daemon that comes back can no longer merge.
        store.daemonConnectedForTesting(authoredPrs: true, notify: false, perri: true, merge: false)
        overview.layoutSubtreeIfNeeded()
        XCTAssertTrue(overview.perriAvailable)
        XCTAssertFalse(overview.mergeAvailable)
        row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertFalse(row.perriLabel.isHidden)
        XCTAssertTrue(row.mergeButton.isHidden, "no dead control")

        // Or no longer sends a verdict.
        store.daemonConnectedForTesting(authoredPrs: true, notify: false, perri: false, merge: true)
        overview.layoutSubtreeIfNeeded()
        row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertTrue(row.perriLabel.isHidden)
        XCTAssertTrue(row.mergeButton.isHidden)

        // Or comes back with both.
        store.daemonConnectedForTesting(authoredPrs: true, notify: false, perri: true, merge: true)
        overview.layoutSubtreeIfNeeded()
        row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertFalse(row.perriLabel.isHidden)
        XCTAssertFalse(row.mergeButton.isHidden)
    }

    func testAnOverviewOverAnOlderDaemonHasNeitherBadgeNorButton() throws {
        let store = AppStore.shared
        let pr = MF.readyPr()
        store.daemonConnectedForTesting(authoredPrs: true, notify: true)
        let window = APT.window(size: NSSize(width: 700, height: 600))
        windows.append(window)
        let overview = AuthoredPrsOverviewView(clock: APT.FakeClock().read, timeZone: APT.utc, store: store)
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        store.applyAuthoredPrsForTesting(APT.snapshot([pr]))
        overview.layoutSubtreeIfNeeded()

        XCTAssertFalse(overview.perriAvailable)
        XCTAssertFalse(overview.mergeAvailable)
        let row = try XCTUnwrap(overview.rowView(forRowId: pr.id))
        XCTAssertTrue(row.perriLabel.isHidden)
        XCTAssertTrue(row.mergeButton.isHidden)
    }
}

// MARK: - Scroll, selection and hover hold still

/// A row changing from merge-disabled to merge-enabled, entering Merging…, getting a notice and having it dismissed
/// must not move what the reader is on: the scroll offset, the selected row, or the hovered row's place.
final class AuthoredPrMergeScrollSafetyTests: MouseQueueTestCase {

    private var rigs: [MergeOverviewRig] = []

    override func tearDown() {
        rigs.forEach { $0.close() }
        rigs = []
        super.tearDown()
    }

    private let target = MF.readyPr(110, perri: nil)

    /// 20 rows in NEEDS YOU, 22 in READY (the target among them), 12 in WAITING: far taller than the window.
    private func prs(targetPerri: AuthoredPrPerri?) -> [AuthoredPr] {
        let needs = (1...20).map { APT.pr($0, repo: MF.repo, title: "Needs you \($0)", group: .needsYou) }
        let ready = (100..<122).map { n -> AuthoredPr in
            n == 110 ? MF.readyPr(110, perri: targetPerri) : MF.readyPr(n, perri: MF.verdict())
        }
        let waiting = (200..<212).map { APT.pr($0, repo: MF.repo, title: "Waiting \($0)", group: .waiting) }
        return needs + ready + waiting
    }

    private struct Held {
        var origin: CGFloat
        var selected: String?
        var hovered: String?
        var hoveredTop: CGFloat
    }

    private func held(_ rig: MergeOverviewRig, hovered: AuthoredPr) throws -> Held {
        let scroll = try XCTUnwrap(rig.scroll)
        let index = try XCTUnwrap(rig.overview.outlineRow(forRowId: hovered.id), "the hovered row is on screen")
        return Held(origin: scroll.contentView.bounds.origin.y, selected: rig.overview.selectedRowId,
                    hovered: rig.overview.hoveredId, hoveredTop: rig.outline.rect(ofRow: index).minY - scroll.contentView.bounds.origin.y)
    }

    private func assertHeld(_ before: Held, _ rig: MergeOverviewRig, hovered: AuthoredPr, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let now = try held(rig, hovered: hovered)
        XCTAssertEqual(now.origin, before.origin, accuracy: 0.5, "\(what): the scroll offset moved", file: file, line: line)
        XCTAssertEqual(now.selected, before.selected, "\(what): the selection moved", file: file, line: line)
        XCTAssertEqual(now.hovered, before.hovered, "\(what): the hovered row changed", file: file, line: line)
        XCTAssertEqual(now.hoveredTop, before.hoveredTop, accuracy: 0.5, "\(what): the hovered row is not where it was", file: file, line: line)
    }

    /// The list scrolled so the target is near the top, with the row above it selected and the one below hovered.
    private func setUpScrolled() throws -> (rig: MergeOverviewRig, hovered: AuthoredPr, before: Held) {
        let rig = MergeOverviewRig(prs(targetPerri: nil))
        rigs.append(rig)
        let selected = MF.readyPr(109, perri: MF.verdict()), hovered = MF.readyPr(111, perri: MF.verdict())
        rig.overview.selectRow(id: selected.id)
        let index = try XCTUnwrap(rig.overview.outlineRow(forRowId: target.id))
        let scroll = try XCTUnwrap(rig.scroll)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: rig.outline.rect(ofRow: index).minY - 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        rig.overview.layoutSubtreeIfNeeded()
        rig.overview.setHovered(rowId: hovered.id)
        let before = try held(rig, hovered: hovered)
        XCTAssertGreaterThan(before.origin, 500, "precondition: the list is scrolled well down")
        XCTAssertEqual(before.selected, selected.id, "precondition")
        XCTAssertEqual(before.hovered, hovered.id, "precondition")
        return (rig, hovered, before)
    }

    func testNothingMovesWhenARowBecomesMergeableAndThroughMergingFailureAndDismissal() throws {
        let (rig, hovered, before) = try setUpScrolled()
        XCTAssertFalse(try rig.buttonIsEnabled(target), "precondition: Perri has not reviewed it yet")

        // Perri approves: the button goes from off to on.
        rig.apply(prs(targetPerri: MF.verdict()))
        XCTAssertTrue(try rig.buttonIsEnabled(target), "the button is on")
        try assertHeld(before, rig, hovered: hovered, "the row became mergeable")

        // Press, confirm: Merging….
        try rig.mergeAndWait(target)
        XCTAssertEqual(try rig.buttonTitle(target), "Merging…")
        try assertHeld(before, rig, hovered: hovered, "Merging…")

        // The answer: a notice on the row.
        rig.answer(.failed(code: "behind"))
        XCTAssertNotNil(try rig.noticeText(target))
        try assertHeld(before, rig, hovered: hovered, "a notice")

        // Dismissed.
        try rig.rowView(target).noticeDismissButton.performClick(nil)
        rig.overview.layoutSubtreeIfNeeded()
        XCTAssertNil(try rig.noticeText(target))
        try assertHeld(before, rig, hovered: hovered, "the notice dismissed")
    }

    func testNothingMovesWhenAMergeSucceeds() throws {
        let (rig, hovered, before) = try setUpScrolled()
        rig.apply(prs(targetPerri: MF.verdict()))
        try rig.mergeAndWait(target)
        rig.answer(.ok(AuthoredPrDone()))
        XCTAssertEqual(try rig.buttonTitle(target), "Merged")
        try assertHeld(before, rig, hovered: hovered, "Merged")
    }

    func testNothingMovesWhenAConfirmationIsOpenedAndCancelled() throws {
        let (rig, hovered, before) = try setUpScrolled()
        rig.apply(prs(targetPerri: MF.verdict()))
        try rig.press(target)
        XCTAssertNotNil(rig.merger.presented)
        try assertHeld(before, rig, hovered: hovered, "a confirmation was opened")
        rig.merger.presented?.cancel()
        try assertHeld(before, rig, hovered: hovered, "and cancelled")
    }

    func testNothingMovesWhenASnapshotCancelsAnOpenConfirmation() throws {
        let (rig, hovered, before) = try setUpScrolled()
        rig.apply(prs(targetPerri: MF.verdict()))
        try rig.press(target)
        XCTAssertNotNil(rig.merger.presented)

        // The head moves under the confirmation: it is cancelled, and the list stays where it was.
        let moved = prs(targetPerri: MF.verdict()).map { $0.id == target.id ? MF.pushed($0, to: MF.headB, perriReviewedIt: false) : $0 }
        rig.apply(moved)

        XCTAssertNil(rig.merger.presented)
        try assertHeld(before, rig, hovered: hovered, "a snapshot cancelled the confirmation")
    }
}

// MARK: - Edge cases found in review

/// A base retargeted under an open confirmation, a link that dropped while the person read, a merge's own timeout,
/// a stale notice at the next press, and a confirmation that survives the list being rebuilt under it.
final class AuthoredPrMergeReviewFixTests: MouseQueueTestCase {

    private var rigs: [MergeRig] = []
    private var overviewRigs: [MergeOverviewRig] = []

    override func tearDown() {
        rigs.forEach { $0.close() }
        overviewRigs.forEach { $0.close() }
        rigs = []
        overviewRigs = []
        super.tearDown()
    }

    private func makeRig() -> MergeRig {
        let rig = MergeRig(allowEverything: true)
        rigs.append(rig)
        return rig
    }

    func testTheConfirmationRemembersTheBaseItSaid() throws {
        XCTAssertEqual(MF.row(MF.readyPr(baseRef: "main")).mergeButton?.confirmation?.base, "main")
        XCTAssertEqual(MF.row(MF.readyPr(baseRef: "release/2026-11")).mergeButton?.confirmation?.base, "release/2026-11")
        XCTAssertNil(MF.row(MF.readyPr(baseRef: nil)).mergeButton?.confirmation?.base)
    }

    func testARetargetedBaseCancelsTheConfirmationEvenThoughTheHeadDidNotMove() throws {
        let rig = makeRig()
        let pr = MF.readyPr(458, baseRef: "main")
        rig.activate(MF.row(pr))
        XCTAssertNotNil(rig.session, "precondition")

        // Same head, still ready, but the PR now targets another branch: the sentence the person read is untrue.
        rig.merger.rowsDidChange([MF.row(MF.readyPr(458, baseRef: "release/2026-11"))])

        XCTAssertNil(rig.merger.presented, "cancelled")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testABaseThatAppearsOrGoesCancelsTheConfirmationToo() throws {
        for (was, now) in [(String?.none, "main"), ("main", String?.none)] {
            let rig = makeRig()
            rig.activate(MF.row(MF.readyPr(458, baseRef: was)))
            rig.merger.rowsDidChange([MF.row(MF.readyPr(458, baseRef: now))])
            XCTAssertNil(rig.merger.presented, "\(String(describing: was)) -> \(String(describing: now))")
        }
    }

    func testAConfirmWhileTheLinkIsDownLeavesAFailureOnTheRowNotSilence() throws {
        let rig = makeRig()
        let pr = MF.readyPr()
        rig.activate(MF.row(pr))
        rig.transport.isMergeAvailable = false

        rig.confirm()

        XCTAssertTrue(rig.transport.calls.isEmpty, "nothing was sent")
        XCTAssertEqual(rig.merger.attempts[pr.id]?.progress, AuthoredPrMergeProgress.failed(.unreachable),
                       "the row says so, instead of the confirmation closing and nothing more")
        XCTAssertNil(rig.merger.presented)
    }

    func testPressingMergeClearsTheOldNoticeSoAHeadChangedNoticeDoesNotOutliveTheNextAttempt() throws {
        let rig = makeRig()
        let pr = MF.readyPr(458, head: MF.headA)
        rig.mergeAndWait(pr)
        rig.transport.answer(.failed(code: "head_changed"))
        XCTAssertEqual(rig.merger.attempts[pr.id]?.progress, AuthoredPrMergeProgress.failed(.headChanged), "precondition")

        // The person comes back and presses Merge on the new head, then cancels: the old news is gone.
        let again = MF.row(MF.pushed(pr, to: MF.headB, perriReviewedIt: true))
        rig.activate(again)
        rig.session?.cancel()

        XCTAssertNil(rig.merger.attempts[pr.id], "a new press starts a new attempt: the old notice is not left standing")
    }

    func testAMergeHasItsOwnTimeoutAndTheOthersKeepTheirs() throws {
        let sent = LiveMergeSent()
        let transport = AuthoredPrHandoffTransportLive(
            timeout: 0.05, supported: { true },
            sendPreview: { _ in sent.other += 1 }, sendNotify: { _ in sent.other += 1 },
            sendStart: { _ in sent.other += 1 }, sendLink: { _ in sent.other += 1 },
            mergeSupported: { true }, sendMerge: { sent.merges.append($0) }, mergeTimeout: 30)
        var merge: [AuthoredPrAnswer<AuthoredPrDone>] = []
        var link: [AuthoredPrAnswer<AuthoredPrDone>] = []
        transport.merge(repo: "o/r", number: 1, expectedHeadShaShort: "0123abcd") { merge.append($0) }
        transport.link(repo: "o/r", number: 1, tag: "t") { link.append($0) }

        let passed = expectation(description: "the short timeout passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { passed.fulfill() }
        wait(for: [passed], timeout: 5)

        XCTAssertEqual(link, [.unreachable], "the hand-off verbs time out at the short timeout")
        XCTAssertTrue(merge.isEmpty, "a merge is given longer: GitHub's merge can be slow")
        transport.deliver(.merge(requestId: try XCTUnwrap(sent.merges.first).requestId, .ok(AuthoredPrDone())))
        XCTAssertEqual(merge, [.ok(AuthoredPrDone())], "and its answer still gets through")
    }

    /// The list is rebuilt under a confirmation by an unrelated snapshot or a clock tick; the row view the
    /// confirmation was opened from may be replaced, so it must not be what the popover hangs on.
    func testOpeningAConfirmationDoesNotRebuildTheListUnderIt() throws {
        let pr = MF.readyPr(), other = MF.readyPr(459)
        let rig = MergeOverviewRig([pr, other])
        overviewRigs.append(rig)
        let before = try rig.rowView(pr)

        try rig.press(pr)
        XCTAssertNotNil(rig.merger.presented, "precondition")
        rig.overview.layoutSubtreeIfNeeded()

        XCTAssertTrue(try rig.rowView(pr) === before, "opening a confirmation changes nothing a row shows: the row view stays")
        rig.merger.presented?.cancel()
        XCTAssertTrue(try rig.rowView(pr) === before, "and neither does cancelling it")
    }

    func testAnAttemptThatChangesWhatARowShowsDoesRebuildIt() throws {
        let pr = MF.readyPr()
        let rig = MergeOverviewRig([pr])
        overviewRigs.append(rig)
        try rig.mergeAndWait(pr)
        XCTAssertEqual(try rig.buttonTitle(pr), "Merging…", "the rows follow the attempts")
        rig.answer(.ok(AuthoredPrDone()))
        XCTAssertEqual(try rig.buttonTitle(pr), "Merged")
    }
}

/// What a live transport sent, for the test above.
private final class LiveMergeSent {
    var merges: [ClientAuthoredPrMerge] = []
    var other = 0
}


// MARK: - More than one Overview

/// One merger serves every Overview (one per Mother window). An Overview that does not show the row in an open
/// confirmation (another filter, the row behind "Show more", a window just opened) must not cancel it; a real change
/// of the row still does, whichever Overview sees it.
final class AuthoredPrMergeTwoWindowTests: MouseQueueTestCase {

    private var rigs: [MergeOverviewRig] = []
    private var secondWindows: [NSWindow] = []

    override func tearDown() {
        secondWindows.forEach { $0.contentView = nil; $0.close() }
        rigs.forEach { $0.close() }
        secondWindows = []
        rigs = []
        super.tearDown()
    }

    private func makeRig(_ prs: [AuthoredPr]) -> MergeOverviewRig {
        let rig = MergeOverviewRig(prs)
        rigs.append(rig)
        return rig
    }

    /// Another window's Overview over the same merger, showing `prs`.
    private func openSecondOverview(sharing rig: MergeOverviewRig, showing prs: [AuthoredPr]) -> AuthoredPrsOverviewView {
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 700))
        secondWindows.append(window)
        let overview = AuthoredPrsOverviewView(clock: rig.clock.read, timeZone: APT.utc, store: nil)
        window.contentView = overview
        overview.layoutSubtreeIfNeeded()
        overview.merger = rig.merger
        overview.setPerriAvailable(true)
        overview.setMergeAvailable(true)
        overview.apply(snapshot: APT.snapshot(prs), connection: .connected)
        overview.layoutSubtreeIfNeeded()
        return overview
    }

    func testAnotherWindowThatDoesNotShowTheRowLeavesTheConfirmationOpen() throws {
        let pr = MF.readyPr(458), other = MF.readyPr(459)
        let rig = makeRig([pr, other])
        try rig.press(pr)
        let session = try XCTUnwrap(rig.merger.presented, "precondition")

        // A window opened now, with a list that has no #458, and then snapshots arriving in it.
        let second = openSecondOverview(sharing: rig, showing: [other])
        XCTAssertTrue(rig.merger.presented === session, "opening a window does not cancel what is being read in another")
        second.apply(snapshot: APT.snapshot([other, MF.readyPr(460)]), connection: .connected)
        second.apply(snapshot: APT.snapshot([]), connection: .connected)
        XCTAssertTrue(rig.merger.presented === session, "nor does its list changing")
        XCTAssertTrue(rig.transport.calls.isEmpty)

        // The confirmation still works.
        rig.confirm()
        XCTAssertEqual(rig.transport.calls, [RecordingMergeTransport.Call(repo: MF.repo, number: 458, head: MF.headA)])
    }

    func testARealChangeOfTheRowSeenFromAnotherWindowStillCancels() throws {
        let changes: [(String, AuthoredPr)] = [
            ("the head moved", MF.pushed(MF.readyPr(458), to: MF.headB, perriReviewedIt: true)),
            ("Perri's approval is gone", MF.readyPr(458, perri: nil)),
            ("checks went red", MF.readyPr(458, checks: AuthoredPrChecks(state: .failing, failed: 1))),
            ("the human approval was withdrawn", MF.readyPr(458, review: AuthoredPrReview(state: .changesRequested))),
            ("it became a draft", MF.readyPr(458, group: .draft, draft: true)),
        ]
        for (what, changed) in changes {
            let pr = MF.readyPr(458)
            let rig = makeRig([pr])
            let second = openSecondOverview(sharing: rig, showing: [pr])
            try rig.press(pr)
            XCTAssertNotNil(rig.merger.presented, "\(what): precondition")

            // Only the other window hears of it first (as when the first window's list is held still).
            second.apply(snapshot: APT.snapshot([changed]), connection: .connected)

            XCTAssertNil(rig.merger.presented, "\(what): cancelled, whichever window saw it")
            XCTAssertTrue(rig.transport.calls.isEmpty, what)
        }
    }

    func testTheWindowThatOpenedItStillCancelsWhenItsRowIsGone() throws {
        let pr = MF.readyPr(458), other = MF.readyPr(459)
        let rig = makeRig([pr, other])
        _ = openSecondOverview(sharing: rig, showing: [pr, other])
        try rig.press(pr)
        XCTAssertNotNil(rig.merger.presented, "precondition")

        rig.apply([other])

        XCTAssertNil(rig.merger.presented, "the row the person read is gone from the window they read it in")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }
}
