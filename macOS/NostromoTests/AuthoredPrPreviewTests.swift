import XCTest
import AppKit
import NostromoKit

// The preview popover: the message the daemon built, shown verbatim, and the one button that sends it.
//
// Contract.
//  * The text is the daemon's, character for character, in a read-only, selectable, monospaced text view; the
//    title says who gets it ("Send to Cody (nostromo)"); "Last told: …" says when they last were.
//  * Cancel and Esc send nothing. Send, by a person's gesture, sends the daemon's digest; on ok the popover
//    finishes as sent and the focus is shown with the keyboard in its input.
//  * The PR changed under the message (`changed`): the message is asked for again and a line says so; stale
//    text is never sent.
//  * The owner focus closing while the popover is open turns Send into "Start a session…".
//  * A daemon failure, or no answer, keeps the popover open with its words; nothing is switched to, nobody
//    is recorded as told.
//  * SP4: Send does nothing for app-control input, an Accessibility press or a stale event.
//
// Mutations (to be run by hand), and the test that fails for each:
//   M1 the text is edited, trimmed or rendered (Markdown/attributed)  -> testItShowsTheDaemonsTextVerbatim...
//   M2 Cancel or Esc sends                                              -> testCancelAndEscapeSendNothing
//   M3 Send sends the wrong digest, or twice on a double press          -> testSendWithAHumanGestureSendsTheDaemonsDigestExactlyOnce
//   M4 `changed` sends again with the old digest                        -> testChangedAsksForTheMessageAgainAndSaysSoAndNeverResendsTheOldDigest
//   M5 a failure switches to the focus or closes the popover            -> testAFailureKeepsThePopoverOpenWithItsWordsAndSwitchesToNothing
//   M6 the owner closing leaves Send as it was                          -> testTheOwnerClosingTurnsSendIntoStartASession
//   M7 Send skips `HumanGesture`                                        -> testSendDoesNothingForInputThatIsNotAHumanGesture
final class AuthoredPrPreviewTests: MouseQueueTestCase {

    private var window: NSWindow!
    private var transport: RecordingTransport!
    private var control: NSButton!
    private var outcomes: [AuthoredPrPreviewSession.Outcome] = []

    override func setUp() {
        super.setUp()
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 600, height: 700))
        control = HF.control(in: window)
        transport = RecordingTransport()
        outcomes = []
    }

    override func tearDown() {
        window.contentView = nil
        window.close()
        window = nil
        super.tearDown()
    }

    /// A session and its popover content, in the window, with its preview requested.
    private func open(permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live,
                      pr: AuthoredPr = HF.pr()) -> (session: AuthoredPrPreviewSession, vc: AuthoredPrPreviewViewController) {
        let session = AuthoredPrPreviewSession(row: HF.row(pr), tag: HF.tag, transport: transport, permit: permit)
        session.onFinish = { [weak self] in self?.outcomes.append($0) }
        let vc = AuthoredPrPreviewViewController(session: session)
        vc.clock = { APT.t0 }
        window.contentView?.addSubview(vc.view)
        session.start()
        return (session, vc)
    }

    /// `open` and the daemon answers with `payload`.
    private func openReady(payload: AuthoredPrPreviewPayload = HF.payload(), permit: @escaping AuthoredPrGesture.Permit = AuthoredPrGesture.live)
        -> (session: AuthoredPrPreviewSession, vc: AuthoredPrPreviewViewController) {
        let opened = open(permit: permit)
        transport.answerPreview(.ok(payload))
        return opened
    }

    // MARK: - What it shows

    func testItAsksTheDaemonForTheMessageForItsOwnerAndSaysItIsPreparing() {
        let (_, vc) = open()
        XCTAssertEqual(transport.calls, [.preview(repo: HF.repo, number: 458, target: .focus(tag: HF.tag))])
        XCTAssertEqual(vc.message.textView.string, "Preparing the message…")
        XCTAssertFalse(vc.sendButton.isEnabled, "nothing to send yet")
    }

    func testItShowsTheDaemonsTextVerbatimInAReadOnlySelectableMonospacedView() {
        let text = "PR a/b#458 needs attention:\n- Failing checks: **lint** <b>not bold</b>\n   indented   with   spaces\n"
            + "https://github.com/a/b/pull/458\nunicode: ✓ ✗ é\n"
        let (_, vc) = openReady(payload: HF.payload(text: text))
        let view = vc.message.textView
        XCTAssertEqual(view.string, text, "the text is exactly what the daemon sent")
        XCTAssertFalse(view.isEditable, "read-only")
        XCTAssertTrue(view.isSelectable, "selectable, so it can be copied")
        XCTAssertEqual(view.font?.isFixedPitch, true, "monospaced")
        XCTAssertFalse(view.isRichText, "plain text: nothing the daemon sent is styled")
        XCTAssertFalse(APT.hasLink(view.attributedString()), "no link is made out of it")
        XCTAssertEqual(vc.titleLabel.stringValue, "Send to Cody (nostromo)")
        XCTAssertEqual(vc.sendButton.title, "Send and switch ⏎")
        XCTAssertTrue(vc.sendButton.isEnabled)
    }

    func testTheSendButtonIsTheDefaultAndCancelIsEscape() {
        let (_, vc) = openReady()
        XCTAssertEqual(vc.sendButton.keyEquivalent, "\r")
        XCTAssertEqual(vc.cancelButton.keyEquivalent, "\u{1b}")
        XCTAssertEqual(vc.cancelButton.title, "Cancel")
    }

    func testItSaysWhenTheFocusWasLastToldOrThatItNeverWas() {
        let never = openReady(payload: HF.payload(lastTold: nil))
        XCTAssertEqual(never.vc.lastToldLabel.stringValue, "Last told: never")

        let told = AuthoredPrLastTold(name: "Cody in Nostromo", at: APT.t0.addingTimeInterval(-60))
        let recently = openReady(payload: HF.payload(lastTold: told))
        XCTAssertEqual(recently.vc.lastToldLabel.stringValue, "Last told: 1m ago (Cody)")
    }

    // MARK: - Cancel and Esc

    func testCancelAndEscapeSendNothing() {
        let (session, vc) = openReady(permit: { _, _, _ in true })
        vc.cancelButton.performClick(nil)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(transport.handedOff.isEmpty, "Cancel sent nothing")
        XCTAssertEqual(transport.calls.count, 1, "and asked for nothing more than the preview")

        session.cancel()
        XCTAssertEqual(outcomes, [.cancelled], "cancelling twice finishes once")
    }

    // MARK: - Send

    func testSendWithAHumanGestureSendsTheDaemonsDigestExactlyOnce() {
        let (session, vc) = openReady(payload: HF.payload(digest: "digest-7"))

        session.send(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.notifies, [.notify(repo: HF.repo, number: 458, tag: HF.tag, digest: "digest-7")],
                       "the daemon's digest goes back, untouched")
        XCTAssertFalse(vc.sendButton.isEnabled, "while it is being sent the button is off")

        session.send(event: HF.human(in: window), control: control)
        vc.sendButton.performClick(nil)
        XCTAssertEqual(transport.notifies.count, 1, "a second press while sending sends nothing more")
        XCTAssertTrue(outcomes.isEmpty, "still waiting for the daemon")
    }

    func testSendFromTheButtonAfterAPersonsClick() {
        let (_, vc) = openReady(permit: { _, _, _ in true })
        vc.sendButton.performClick(nil)
        XCTAssertEqual(transport.notifies.count, 1)
    }

    func testOkFinishesAsSent() {
        let (session, _) = openReady()
        session.send(event: HF.human(in: window), control: control)
        transport.answerNotify(.ok(AuthoredPrDone()))
        XCTAssertEqual(outcomes, [.sent(tag: HF.tag)])
    }

    func testSendBeforeTheMessageArrivesSendsNothing() {
        let (session, _) = open()
        session.send(event: HF.human(in: window), control: control)
        XCTAssertTrue(transport.handedOff.isEmpty)
    }

    // MARK: - Send, end to end: the focus is shown

    func testAnOkSendClosesThePopoverAndShowsTheFocusWithTheKeyboardInItsInput() throws {
        let rig = HandoffRig(window: window)
        let pr = HF.pr()
        let model = HF.row(pr)

        rig.handoff.activate(model, anchor: control, event: HF.human(in: window), control: control)
        let session = try XCTUnwrap(rig.preview, "a preview is open")
        rig.transport.answerPreview(.ok(HF.payload()))
        session.send(event: HF.human(in: window), control: control)
        XCTAssertTrue(rig.host.log.isEmpty, "nothing is switched to before the daemon says ok")
        XCTAssertNotNil(rig.handoff.presented, "still open while sending")

        rig.transport.answerNotify(.ok(AuthoredPrDone()))

        XCTAssertNil(rig.handoff.presented, "the popover is gone")
        XCTAssertEqual(rig.dismissals, 1)
        XCTAssertEqual(rig.host.log, ["switchTo:\(HF.tag)", "bringToFront", "focusInput"],
                       "the window the click came from is switched to the focus and its input gets the keyboard")
        XCTAssertGreaterThanOrEqual(rig.counters.activations, 1, "Nostromo comes forward")
    }

    func testAFocusAlreadyShownInAnotherWindowIsRaisedInsteadOfSwitchingThisOne() throws {
        let rig = HandoffRig(window: window)
        let other = APT.window(size: NSSize(width: 300, height: 300))
        defer { other.close() }
        let shower = FakeFocusHost(window: other, shows: HF.tag)
        let host = rig.host
        rig.handoff.presenter.hosts = { [host, shower] in [host, shower] }

        rig.handoff.activate(HF.row(HF.pr()), anchor: control, event: HF.human(in: window), control: control)
        rig.transport.answerPreview(.ok(HF.payload()))
        try XCTUnwrap(rig.preview).send(event: HF.human(in: window), control: control)
        rig.transport.answerNotify(.ok(AuthoredPrDone()))

        XCTAssertEqual(shower.log, ["bringToFront", "focusInput"], "the window already showing it comes forward")
        XCTAssertTrue(rig.host.log.isEmpty, "the window the click came from is left alone")
    }

    // MARK: - changed

    func testChangedAsksForTheMessageAgainAndSaysSoAndNeverResendsTheOldDigest() {
        let (session, vc) = openReady(payload: HF.payload(text: "old message", digest: "old"))
        session.send(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.notifies.count, 1)

        transport.answerNotify(.failed(code: "changed"))

        XCTAssertEqual(transport.previews.count, 2, "the message is asked for again")
        XCTAssertEqual(vc.noteLabel.stringValue, "The PR changed; check the message again")
        XCTAssertFalse(vc.noteLabel.isHidden)
        XCTAssertTrue(outcomes.isEmpty, "the popover stays open")

        transport.answerPreview(.ok(HF.payload(text: "new message", digest: "new")))
        XCTAssertEqual(vc.message.textView.string, "new message", "the new text is shown for the person to read")
        XCTAssertEqual(transport.notifies.count, 1, "nothing was sent for the new text yet")

        session.send(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.notifies.last, .notify(repo: HF.repo, number: 458, tag: HF.tag, digest: "new"),
                       "the next send carries the new digest, never the old one")
    }

    // MARK: - The owner closes

    func testTheOwnerClosingTurnsSendIntoStartASession() {
        let (session, vc) = openReady(permit: { _, _, _ in true })
        XCTAssertEqual(vc.sendButton.title, "Send and switch ⏎")

        session.openFocusesChanged(["some-other-focus"])

        XCTAssertEqual(vc.sendButton.title, "Start a session…")
        XCTAssertTrue(vc.sendButton.isEnabled)
        vc.sendButton.performClick(nil)
        XCTAssertEqual(outcomes, [.startSession], "pressing it moves on to starting a session")
        XCTAssertTrue(transport.handedOff.isEmpty, "nothing is sent to the closed focus")
    }

    func testTheOwnerStillOpenLeavesSendAlone() {
        let (session, vc) = openReady()
        session.openFocusesChanged([HF.tag, "another"])
        XCTAssertEqual(vc.sendButton.title, "Send and switch ⏎")
    }

    func testTheOwnerClosingUnderAHandOffOpensTheStartSheet() throws {
        let rig = HandoffRig(window: window)
        rig.handoff.activate(HF.row(HF.pr()), anchor: control, event: HF.human(in: window), control: control)
        let session = try XCTUnwrap(rig.preview)
        rig.transport.answerPreview(.ok(HF.payload()))

        rig.focusTags.send(["unrelated"])
        XCTAssertEqual(session.sendTitle, "Start a session…")
        session.send(event: HF.human(in: window), control: control)

        XCTAssertNotNil(rig.startModel, "the Start a session sheet replaces the preview")
        XCTAssertTrue(rig.transport.handedOff.isEmpty)
        XCTAssertEqual(rig.transport.previews.last, .preview(repo: HF.repo, number: 458, target: .newSession))
    }

    func testADaemonThatSaysTheOwnerIsClosedOffersStartASession() {
        let (_, vc) = open()
        transport.answerPreview(.failed(code: "owner_closed"))
        XCTAssertEqual(vc.sendButton.title, "Start a session…")
    }

    // MARK: - Failure

    func testAFailureKeepsThePopoverOpenWithItsWordsAndSwitchesToNothing() throws {
        let codes = ["not_running", "unknown_focus", "nothing_to_fix", "unknown_pr", "unavailable", "not_operator_app", "unheard_of"]
        for code in codes {
            let rig = HandoffRig(window: window)
            rig.handoff.activate(HF.row(HF.pr()), anchor: control, event: HF.human(in: window), control: control)
            let session = try XCTUnwrap(rig.preview, code)
            let vc = AuthoredPrPreviewViewController(session: session)
            vc.clock = { APT.t0 }
            _ = vc.view
            rig.transport.answerPreview(.ok(HF.payload()))
            session.send(event: HF.human(in: window), control: control)

            rig.transport.answerNotify(.failed(code: code))

            XCTAssertEqual(vc.noteLabel.stringValue, AuthoredPrsHandoffWords.failure(code: code), "\(code): its words")
            XCTAssertFalse(vc.noteLabel.isHidden, code)
            XCTAssertNotNil(rig.handoff.presented, "\(code): still open")
            XCTAssertEqual(rig.dismissals, 0, code)
            XCTAssertTrue(rig.host.log.isEmpty, "\(code): nothing was switched to")
            XCTAssertTrue(vc.sendButton.isEnabled, "\(code): the person can try again")
        }
    }

    func testNoAnswerFromTheDaemonKeepsItOpenAndSaysItIsNotReachable() throws {
        let rig = HandoffRig(window: window)
        rig.handoff.activate(HF.row(HF.pr()), anchor: control, event: HF.human(in: window), control: control)
        let session = try XCTUnwrap(rig.preview)
        let vc = AuthoredPrPreviewViewController(session: session)
        _ = vc.view
        rig.transport.answerPreview(.ok(HF.payload()))
        session.send(event: HF.human(in: window), control: control)

        rig.transport.answerNotify(.unreachable)

        XCTAssertEqual(vc.noteLabel.stringValue, "Couldn't send: Nostromo isn't reachable")
        XCTAssertNotNil(rig.handoff.presented)
        XCTAssertTrue(rig.host.log.isEmpty)
    }

    func testAPreviewThatFailsOrNeverComesShowsItsWordsAndHasNothingToSend() {
        let failed = open()
        transport.answerPreview(.failed(code: "unknown_pr"))
        XCTAssertEqual(failed.vc.noteLabel.stringValue, "Couldn't send: this PR is no longer in the list")
        XCTAssertEqual(failed.vc.message.textView.string, "", "no message to show")
        failed.session.send(event: HF.human(in: window), control: control)
        XCTAssertTrue(transport.handedOff.isEmpty, "with no message there is nothing to send")

        let lost = open()
        transport.answerPreview(.unreachable)
        XCTAssertEqual(lost.vc.noteLabel.stringValue, "Couldn't send: Nostromo isn't reachable")
    }

    // MARK: - SP4

    func testSendDoesNothingForInputThatIsNotAHumanGesture() throws {
        let (session, vc) = openReady()
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: window)
            session.send(event: event, control: control)
            XCTAssertTrue(transport.notifies.isEmpty, "\(kind): nothing was sent")
            XCTAssertTrue(vc.sendButton.isEnabled, "\(kind): the preview did not move on")
            XCTAssertTrue(outcomes.isEmpty, "\(kind): it did not finish")
        }
        session.send(event: HF.human(in: window), control: control)
        XCTAssertEqual(transport.notifies.count, 1, "a person's click still sends: it was only the gesture that was refused")
    }

    func testPressingSendWithNoPersonBehindItSendsNothing() throws {
        try HF.skipIfVoiceOver()
        let (_, vc) = openReady()
        vc.sendButton.performClick(nil)   // the action reads `NSApp.currentEvent`: none, or not a click in this window
        XCTAssertTrue(transport.notifies.isEmpty)
    }

    func testStartASessionAfterTheOwnerClosedAlsoNeedsAPerson() throws {
        let (session, _) = openReady()
        session.openFocusesChanged([])
        for kind in NotAHumanGesture.allCases {
            let event = try kind.event(in: window)
            session.send(event: event, control: control)
            XCTAssertTrue(outcomes.isEmpty, "\(kind): the sheet did not open")
        }
    }
}
