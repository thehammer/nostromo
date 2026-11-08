import XCTest
import AppKit
import Combine
import NostromoKit

// AP6: persisted "Always allow…" rules on the Mac: what the store keeps and sends, and the Rules list
// (Window ▸ Approval Rules).
//
// What an operator can rely on:
//   - the store holds exactly what the daemon's `approval_rules` last said (REPLACE), tells its listeners
//     only when that changed, and forgets it when the connection restarts;
//   - Remove is one human gesture and sends one remove; Review… only shows what is in a changed rules
//     file; `Turn these rules on` is a second, separate gesture and sends the hash of the file that was
//     reviewed, never another; Discard is one gesture;
//   - a synthetic or app-control press does none of these, and is reported with its control's name.

private let anyHuman: SessionRuleGesture.Permit = { _, _, _ in .human(sourcePid: nil, sourceState: nil) }

private enum AP6Rules {

    static let path = "/Users/h/.nostromo/approvals/rules.json"

    static func rule(_ id: String, text: String = "Bash(ls /a/b)", scope: ApprovalRuleScope = .repo,
                     root: String? = "/Users/h/Code/x", from request: String = "req-9", uses: UInt64 = 3,
                     active: Bool = true, inactiveReason: String? = nil) -> PersistedRule {
        PersistedRule(id: id, ruleText: text, summary: "s", kind: .exact, scope: scope, root: scope == .repo ? root : nil,
                      createdAtMs: 1_760_021_220_000, createdFromRequestId: request, uses: uses, active: active,
                      inactiveReason: inactiveReason)
    }

    static func quarantine(hash: String = "hash-1", rules: [PersistedRule] = []) -> RulesQuarantine {
        RulesQuarantine(reason: "external_change", fileSha256: hash, rulesInFile: rules)
    }

    static func frame(_ rules: [PersistedRule] = [], quarantined: RulesQuarantine? = nil) -> ApprovalEvent {
        .rules(ApprovalRulesFrame(rules: rules, quarantined: quarantined, path: path))
    }
}

// MARK: - The store

final class PersistedRulesStoreTests: XCTestCase {

    func testTheRulesFrameSetsWhatTheStoreHoldsAndListenersHearOnlyOfRealChanges() {
        let store = ApprovalRecorder().makeStore()
        let changes = ApprovalTap(store.persistedRulesChanges)

        store.handle(AP6Rules.frame([AP6Rules.rule("a")]))
        XCTAssertEqual(store.persistedRules.map(\.id), ["a"])
        XCTAssertEqual(store.rulesPath, AP6Rules.path)
        XCTAssertNil(store.rulesQuarantine)
        XCTAssertEqual(changes.values.count, 1)

        store.handle(AP6Rules.frame([AP6Rules.rule("a")]))   // the same picture: nothing new
        XCTAssertEqual(changes.values.count, 1)

        store.handle(AP6Rules.frame([AP6Rules.rule("a", uses: 4)]))   // a use count moved
        XCTAssertEqual(changes.values.count, 2)

        store.handle(AP6Rules.frame([], quarantined: AP6Rules.quarantine(rules: [AP6Rules.rule("q")])))   // REPLACE, and the quarantine
        XCTAssertEqual(store.persistedRules, [])
        XCTAssertEqual(store.rulesQuarantine?.fileSha256, "hash-1")
        XCTAssertEqual(store.rulesQuarantine?.rulesInFile.map(\.id), ["q"])
        XCTAssertEqual(changes.values.count, 3)
    }

    func testANewDaemonConnectionForgetsTheRulesAndTheQuarantineUntilTheReplay() {
        let store = ApprovalRecorder().makeStore()
        let changes = ApprovalTap(store.persistedRulesChanges)
        store.handle(AP6Rules.frame([AP6Rules.rule("a")], quarantined: AP6Rules.quarantine()))
        let before = changes.values.count

        store.handle(.connectionStarted)

        XCTAssertEqual(store.persistedRules, [])
        XCTAssertNil(store.rulesQuarantine)
        XCTAssertEqual(changes.values.count, before + 1, "the list is told it is stale")
        store.handle(AP6Rules.frame([AP6Rules.rule("a")]))
        XCTAssertEqual(store.persistedRules.map(\.id), ["a"])

        // Nothing held, nothing to tell.
        let empty = ApprovalRecorder().makeStore()
        let quiet = ApprovalTap(empty.persistedRulesChanges)
        empty.handle(.connectionStarted)
        XCTAssertEqual(quiet.values.count, 0)
    }

    func testRemoveSendsOnlyForAKnownRuleAndOnlyWithAConnectionAndTheRuleStaysUntilTheDaemonSaysSo() {
        let recorder = ApprovalRecorder()
        var connected = true
        let store = recorder.makeStore(canSend: { connected })
        store.handle(AP6Rules.frame([AP6Rules.rule("a")]))

        XCTAssertFalse(store.removeRule(id: "unknown"))
        connected = false
        XCTAssertFalse(store.removeRule(id: "a"), "no connection: nothing sent")
        XCTAssertEqual(recorder.removedRules, [])
        connected = true
        XCTAssertTrue(store.removeRule(id: "a"))
        XCTAssertEqual(recorder.removedRules, ["a"])
        XCTAssertEqual(store.persistedRules.map(\.id), ["a"], "the rule goes when the daemon says so, not before")
    }

    func testKeepSendsOnlyTheHashTheDaemonListedAndOnlyWithAConnection() {
        let recorder = ApprovalRecorder()
        var connected = true
        let store = recorder.makeStore(canSend: { connected })
        XCTAssertFalse(store.keepQuarantinedRules(fileSha256: "hash-1"), "nothing is quarantined")

        store.handle(AP6Rules.frame([], quarantined: AP6Rules.quarantine(hash: "hash-1")))
        XCTAssertFalse(store.keepQuarantinedRules(fileSha256: "other-hash"), "a different file than the daemon listed")
        XCTAssertFalse(store.keepQuarantinedRules(fileSha256: ""))
        connected = false
        XCTAssertFalse(store.keepQuarantinedRules(fileSha256: "hash-1"))
        XCTAssertEqual(recorder.keptRules, [])
        connected = true
        XCTAssertTrue(store.keepQuarantinedRules(fileSha256: "hash-1"))
        XCTAssertEqual(recorder.keptRules, ["hash-1"])

        // The file changed again: the old hash is no longer one the daemon lists.
        store.handle(AP6Rules.frame([], quarantined: AP6Rules.quarantine(hash: "hash-2")))
        XCTAssertFalse(store.keepQuarantinedRules(fileSha256: "hash-1"))
        XCTAssertEqual(recorder.keptRules, ["hash-1"])
    }

    func testDiscardSendsOnlyWhileAFileIsQuarantinedAndWithAConnection() {
        let recorder = ApprovalRecorder()
        var connected = true
        let store = recorder.makeStore(canSend: { connected })
        XCTAssertFalse(store.discardQuarantinedRules())
        store.handle(AP6Rules.frame([], quarantined: AP6Rules.quarantine()))
        connected = false
        XCTAssertFalse(store.discardQuarantinedRules())
        connected = true
        XCTAssertTrue(store.discardQuarantinedRules())
        XCTAssertEqual(recorder.discards, 1)
    }

    func testACallYourRuleAllowedNeverShownReadsAllowedByYourRuleOnItsRow() throws {
        let store = ApprovalRecorder().makeStore()
        let statuses = ApprovalTap(store.statusChanges)
        store.handle(.resolved(try ApprovalAP2bFixtures.resolved(id: "never-seen", outcome: "allowed_by_your_rule",
                                                                 toolUseId: "toolu_rule")))
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_rule"]), .allowedByYourRule)
        XCTAssertEqual(store.rowStatus(toolUseIds: ["toolu_rule"])?.text(), "allowed by your rule")
        XCTAssertEqual(statuses.values, ["toolu_rule"])
    }

    func testTheRuleRefusalsHoldTheRequestWithTheReasonAndOnlyADenyCanFollow() throws {
        let allowAlways = ApprovalDecisionWire(kind: .allowAlways, candidateId: "c", ruleText: "Bash(ls)", scope: .repo)
        for (code, reason) in [("rule_refused", "That rule is too broad" as String?), ("rule_write_failed", nil),
                               ("rules_quarantined", nil), ("rule_limit", nil)] {
            let recorder = ApprovalRecorder()
            let store = recorder.makeStore()
            store.handle(.request(try ApprovalTestRequests.simpleRm(id: "a")))
            XCTAssertTrue(store.answer("a", allowAlways, windowID: "w1"), code)
            XCTAssertEqual(store.entry(id: "a")?.state, .inFlight(.allowAlways), code)

            store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "a", code: code, reason: reason)))

            guard case .notSent(let text)? = store.entry(id: "a")?.state else {
                XCTFail("\(code): expected .notSent, got \(String(describing: store.entry(id: "a")?.state))")
                continue
            }
            XCTAssertTrue(text.hasPrefix("Not sent: "), "\(code): \(text)")
            XCTAssertGreaterThan(text.count, "Not sent: ".count, code)
            if let reason { XCTAssertEqual(text, "Not sent: \(reason)", "the daemon's reason is the card's reason") }
            XCTAssertEqual(store.pendingCount(tag: "cody-1"), 1, "\(code): the request is still waiting")

            XCTAssertFalse(store.answer("a", allowAlways, windowID: "w1"), "\(code): the rule is never re-sent")
            XCTAssertFalse(store.answer("a", ApprovalDecisionWire(kind: .allowOnce), windowID: "w1"), code)
            XCTAssertTrue(store.answer("a", ApprovalDecisionWire(kind: .deny), windowID: "w1"), "\(code): Deny is never stranded")
            XCTAssertEqual(recorder.sent.map(\.decision.kind), [.allowAlways, .deny], code)
        }
    }

    func testTheOutcomeOfAnAlwaysAllowHasWords() {
        XCTAssertFalse(ApprovalStore.outcomeText("allowed_always").isEmpty)
        XCTAssertEqual(ApprovalStore.outcomeText("allowed_by_your_rule"), "Allowed by your rule")
    }
}

// MARK: - The Rules list

final class PersistedRulesViewTests: MouseQueueTestCase {

    private var window: NSWindow!
    private var current: NSEvent?
    private var clock: TimeInterval = 100
    private var opened: [ApprovalsLogLink] = []
    private var recorder: ApprovalRecorder!
    private var store: ApprovalStore!
    private var view: PersistedRulesView!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = GestureFixtures.offscreenWindow(size: NSSize(width: 700, height: 500))
        recorder = ApprovalRecorder()
        store = recorder.makeStore()
        opened = []
    }

    override func tearDown() {
        window.close()
        window = nil
        view = nil
        super.tearDown()
    }

    /// The Rules list over the store, in a window, with a person's permit unless `permit` says otherwise.
    private func makeView(permit: @escaping SessionRuleGesture.Permit = anyHuman) {
        let gesture = SessionRuleGesture(permit: permit, uptime: { [unowned self] in self.clock },
                                         lifetime: PersistedRulesView.reviewLifetime)
        view = PersistedRulesView(store: store, gesture: gesture, currentEvent: { [unowned self] in self.current },
                                  home: "/Users/h", timeZone: TimeZone(identifier: "UTC")!,
                                  openRequest: { [unowned self] in self.opened.append($0) })
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 420)
        window.contentView!.addSubview(view)
        layout()
    }

    private func layout() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func feed(_ event: ApprovalEvent) {
        store.handle(event)
        layout()
    }

    /// A person's click on `button`, as event `number` at `time`; the handler clock reads `time + 90`.
    private func click(_ button: NSView, number: Int, time: TimeInterval, clickCount: Int = 1) {
        let point = button.convert(NSPoint(x: 4, y: 4), to: nil)
        current = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                     clickCount: clickCount, pressure: 1)
        clock = time + 90
    }

    private let appControl: SessionRuleGesture.Permit = { _, _, _ in .refused(reason: .appControl) }

    // MARK: Rows

    func testEveryRuleShowsItsTextScopeFileCreatedTimeUsesAndState() {
        makeView()
        feed(AP6Rules.frame([
            AP6Rules.rule("a", text: "Bash(ls /a/b)", scope: .repo, root: "/Users/h/Code/x", uses: 3),
            AP6Rules.rule("b", text: "Bash(rm -rf /tmp/:*)", scope: .allRepos, uses: 1, active: false, inactiveReason: "path_changed"),
        ]))

        XCTAssertEqual(view.rows.map(\.ruleText), ["Bash(ls /a/b)", "Bash(rm -rf /tmp/:*)"])
        XCTAssertEqual(view.rows[0].detail, "Repository: ~/Code/x · created oct 9, 2:47 pm · used 3 times · active")
        XCTAssertEqual(view.rows[1].detail,
                       "All repositories · created oct 9, 2:47 pm · used 1 time · inactive: a path it covers has changed")
        XCTAssertEqual(view.rows.map(\.active), [true, false])
        XCTAssertEqual(view.rows.map(\.file), ["File: ~/.nostromo/approvals/rules.json", "File: ~/.nostromo/approvals/rules.json"])
        XCTAssertEqual(Set(view.removeButtons.keys), ["a", "b"])
        XCTAssertEqual(view.removeButtons["a"]?.title, "Remove")
        XCTAssertNil(view.bannerText)
        XCTAssertNil(view.reviewButton, "nothing to review while the file is trusted")
    }

    func testAnEmptyListSaysSoAndFollowsTheStore() {
        makeView()
        XCTAssertEqual(view.rows, [])
        feed(AP6Rules.frame([AP6Rules.rule("a")]))
        XCTAssertEqual(view.rows.count, 1)
        feed(AP6Rules.frame([]))
        XCTAssertEqual(view.rows, [])
        XCTAssertTrue(view.removeButtons.isEmpty)
    }

    func testTheCreatedFromLinkOpensThatRequestInTheApprovalsWindowAndChangesNothing() {
        makeView()
        feed(AP6Rules.frame([AP6Rules.rule("a", from: "req-9"), AP6Rules.rule("b", from: "")]))

        view.createdFromButtons["a"]!.performClick(nil)
        XCTAssertEqual(opened, [ApprovalsLogLink(requestId: "req-9")])
        XCTAssertEqual(view.createdFromButtons["b"]?.isEnabled, false, "a rule with no origin has nothing to open")
        view.createdFromButtons["b"]!.performClick(nil)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(recorder.removedRules, [])
    }

    // MARK: Remove

    func testRemoveByAPersonSendsExactlyOneRemoveAndTheRowStaysUntilTheDaemonSaysSo() {
        makeView()
        feed(AP6Rules.frame([AP6Rules.rule("a"), AP6Rules.rule("b")]))
        let button = view.removeButtons["a"]!
        click(button, number: 1, time: 10)

        XCTAssertTrue(view.remove(ruleID: "a", button: button), "one gesture, no confirm step")

        XCTAssertEqual(recorder.removedRules, ["a"])
        XCTAssertEqual(view.rows.map(\.ruleID), ["a", "b"])
        feed(AP6Rules.frame([AP6Rules.rule("b")]))
        XCTAssertEqual(view.rows.map(\.ruleID), ["b"])
    }

    func testARemoveAimedOutsideItsButtonSendsNothing() {
        makeView()
        feed(AP6Rules.frame([AP6Rules.rule("a")]))
        let button = view.removeButtons["a"]!
        current = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 5_000, y: 5_000), modifierFlags: [], timestamp: 10,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        XCTAssertFalse(view.remove(ruleID: "a", button: button))
        click(button, number: 2, time: 11, clickCount: 2)
        XCTAssertFalse(view.remove(ruleID: "a", button: button), "a double click")
        XCTAssertEqual(recorder.removedRules, [])
    }

    func testASyntheticRemoveSendsNothingAndIsReportedAsRemoveRule() {
        makeView(permit: appControl)
        feed(AP6Rules.frame([AP6Rules.rule("a")]))
        let button = view.removeButtons["a"]!
        click(button, number: 1, time: 10)

        XCTAssertFalse(view.remove(ruleID: "a", button: button))

        XCTAssertEqual(recorder.removedRules, [])
        XCTAssertEqual(recorder.reports, [ApprovalRecorder.Report(requestID: nil, control: "remove_rule", channel: .appControl)])
    }

    // MARK: The quarantine

    func testAChangedRulesFileShowsTheBannerAndReviewDiscardButNoTurnOn() {
        makeView()
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(rules: [AP6Rules.rule("q")])))

        XCTAssertEqual(view.bannerText, "Rules file changed outside Nostromo; rules are off until you review them")
        XCTAssertEqual(view.reviewButton?.title, "Review…")
        XCTAssertEqual(view.discardButton?.title, "Discard")
        XCTAssertNil(view.turnOnButton, "rules cannot be turned on without reviewing them")
        XCTAssertNil(view.reviewLines)

        feed(AP6Rules.frame([AP6Rules.rule("a")]))   // the daemon says the file is trusted again
        XCTAssertNil(view.bannerText)
        XCTAssertNil(view.reviewButton)
    }

    func testReviewShowsWhatIsInTheFileAndWhichRulesWouldStayInactiveAndSendsNothing() {
        makeView()
        let inFile = [AP6Rules.rule("q1", text: "Bash(ls)"),
                      AP6Rules.rule("q2", text: "Bash(rm)", active: false, inactiveReason: "path_changed"),
                      AP6Rules.rule("q3", text: "Bash(rm -rf /tmp/a)", scope: .allRepos, active: false,
                                    inactiveReason: "scope_unconfirmed")]
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(rules: inFile)))
        click(view.reviewButton!, number: 1, time: 10)

        XCTAssertTrue(view.review(button: view.reviewButton!))

        XCTAssertEqual(view.reviewLines, [
            "Bash(ls)  ·  Repository: ~/Code/x · would stay active",
            "Bash(rm)  ·  Repository: ~/Code/x · would stay inactive: a path it covers has changed",
            "Bash(rm -rf /tmp/a)  ·  ALL repositories · would stay inactive: it applies to all repositories and has not been confirmed again",
        ])
        XCTAssertNotNil(view.turnOnButton)
        XCTAssertNotNil(view.cancelReviewButton)
        XCTAssertEqual(recorder.keptRules, [], "Review… sends nothing")
        XCTAssertEqual(recorder.discards, 0)
        XCTAssertEqual(recorder.removedRules, [])
    }

    func testReviewOfAFileNoRuleCouldBeReadFromSaysSo() {
        makeView()
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(rules: [])))
        click(view.reviewButton!, number: 1, time: 10)
        XCTAssertTrue(view.review(button: view.reviewButton!))
        XCTAssertEqual(view.reviewLines, ["No rules could be read from the file"])
    }

    func testASyntheticReviewShowsNothingAndIsReported() {
        makeView(permit: appControl)
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(rules: [AP6Rules.rule("q")])))
        click(view.reviewButton!, number: 1, time: 10)
        XCTAssertFalse(view.review(button: view.reviewButton!))
        XCTAssertNil(view.reviewLines)
        XCTAssertEqual(recorder.reports.map(\.channel), [.appControl])
        XCTAssertEqual(recorder.reports.map(\.control), ["keep_rules"])
        XCTAssertEqual(recorder.keptRules, [])
    }

    /// Review at event time 10, then the Turn on button is on screen.
    private func reviewed(hash: String = "hash-1") -> ApprovalButton {
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(hash: hash, rules: [AP6Rules.rule("q")])))
        click(view.reviewButton!, number: 1, time: 10)
        XCTAssertTrue(view.review(button: view.reviewButton!))
        layout()
        return view.turnOnButton!
    }

    func testTurningTheRulesOnIsASecondDistinctGestureAfterTheGapAndSendsOneKeepWithTheReviewedHash() {
        makeView()
        let turnOn = reviewed()

        // The same event as the review, too soon, and aimed elsewhere: nothing.
        current = NSEvent.mouseEvent(with: .leftMouseUp, location: turnOn.convert(NSPoint(x: 4, y: 4), to: nil),
                                     modifierFlags: [], timestamp: 10, windowNumber: window.windowNumber, context: nil,
                                     eventNumber: 1, clickCount: 1, pressure: 1)
        clock = 100
        XCTAssertFalse(view.turnOn(button: turnOn), "the same event")
        click(turnOn, number: 2, time: 10.1)
        XCTAssertFalse(view.turnOn(button: turnOn), "0.1 s after the review")
        XCTAssertEqual(recorder.keptRules, [])

        click(turnOn, number: 3, time: 11)
        XCTAssertTrue(view.turnOn(button: turnOn))
        XCTAssertFalse(view.turnOn(button: turnOn), "the review is spent: a second press sends nothing")

        XCTAssertEqual(recorder.keptRules, ["hash-1"])
        XCTAssertNil(view.reviewLines)
    }

    func testASyntheticTurnOnSendsNothingAndIsReported() {
        var human = true
        makeView(permit: { _, _, _ in human ? .human(sourcePid: nil, sourceState: nil) : .refused(reason: .appControl) })
        let turnOn = reviewed()
        human = false
        click(turnOn, number: 2, time: 11)
        XCTAssertFalse(view.turnOn(button: turnOn))
        XCTAssertEqual(recorder.keptRules, [])
        XCTAssertEqual(recorder.reports, [ApprovalRecorder.Report(requestID: nil, control: "keep_rules", channel: .appControl)])
    }

    func testAFileThatChangedAfterTheReviewIsNeverTurnedOnByTheOldReview() {
        makeView()
        let turnOn = reviewed(hash: "hash-1")

        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine(hash: "hash-2", rules: [AP6Rules.rule("q"), AP6Rules.rule("sneaky")])))

        XCTAssertNil(view.reviewLines, "the review no longer stands")
        XCTAssertNil(view.turnOnButton)
        XCTAssertNotNil(view.reviewButton, "the new file is reviewed from the start")
        click(turnOn, number: 2, time: 11)
        XCTAssertFalse(view.turnOn(button: turnOn))
        XCTAssertEqual(recorder.keptRules, [], "neither the old hash nor the new one was sent")
    }

    func testAFileTrustedAgainDuringTheReviewIsNotKeptAgain() {
        makeView()
        let turnOn = reviewed()
        feed(AP6Rules.frame([AP6Rules.rule("a")]))
        click(turnOn, number: 2, time: 11)
        XCTAssertFalse(view.turnOn(button: turnOn))
        XCTAssertEqual(recorder.keptRules, [])
    }

    func testCancellingTheReviewReturnsToReviewAndSendsNothing() {
        makeView()
        _ = reviewed()
        view.cancelReviewButton!.performClick(nil)
        XCTAssertNil(view.reviewLines)
        XCTAssertNil(view.turnOnButton)
        XCTAssertNotNil(view.reviewButton)
        XCTAssertEqual(recorder.keptRules, [])
    }

    func testDiscardIsOneGestureAndTheOnlyThingItSendsIsADiscard() {
        makeView()
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine()))
        let button = view.discardButton!
        click(button, number: 1, time: 10)

        XCTAssertTrue(view.discard(button: button))

        XCTAssertEqual(recorder.discards, 1)
        XCTAssertEqual(recorder.keptRules, [])
    }

    func testASyntheticDiscardSendsNothingAndIsReportedAsDiscardRules() {
        makeView(permit: appControl)
        feed(AP6Rules.frame([], quarantined: AP6Rules.quarantine()))
        let button = view.discardButton!
        click(button, number: 1, time: 10)
        XCTAssertFalse(view.discard(button: button))
        XCTAssertEqual(recorder.discards, 0)
        XCTAssertEqual(recorder.reports, [ApprovalRecorder.Report(requestID: nil, control: "discard_rules", channel: .appControl)])
    }
}
