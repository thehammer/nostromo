import XCTest
import AppKit
import Combine
import NostromoKit

// AP4: "Allow for this session" on the Mac: the two-step human gate, the card's chooser and confirm,
// the session-rules chip in the input bar, the popover with Revoke, and the store behind them.
//
// What an operator can rely on:
//   - choosing a rule in the card's `This session` menu only SELECTS it: nothing is sent until a
//     second, separate human gesture presses `Allow for this session`;
//   - that second gesture cannot be the first one again, cannot follow it by less than 0.3 s of event
//     time, cannot be a held-key repeat, a double-click, a click elsewhere in the card or a key while
//     another control has focus; a synthetic or event-less press (VoiceOver off) completes neither step;
//   - the decision sent carries the id and the exact text the card showed;
//   - the chip shows `N session rules` in its own fixed-width slot, so it appearing, changing and going
//     moves nothing, and a new daemon connection clears it before the daemon replays;
//   - Revoke is one human gesture and sends exactly one revoke.
//
// Layout is read from real frames after `layoutSubtreeIfNeeded()`; no run-loop timing. Events are real
// `NSEvent`s with chosen timestamps (`GestureFixtures`), and the permit is injected where a test needs a
// person's gesture without a hardware event.

// MARK: - Fixtures

private enum RuleFixtures {

    static let exactText = "Bash(rm -rf ~/Library/Caches/a)"
    static let prefixText = "Bash(rm -rf ~/Library/Caches/:*)"

    static let candidates: [[String: Any]] = [
        ["id": "c-exact", "rule_text": exactText, "summary": "Allows exactly this command again",
         "kind": "exact", "overrides": "Bash(rm:*)"],
        ["id": "c-prefix", "rule_text": prefixText,
         "summary": "Allows `rm -rf` on one or more paths inside `~/Library/Caches/`, with no other flags",
         "kind": "path_prefix", "overrides": "Bash(rm:*)"],
    ]

    static let options = ApprovalTestRequests.allOptions + ["allow_session"]

    static func request(id: String = "req-1", command: String = "rm -rf ~/Library/Caches/a",
                        reasonKind: String = "ask_rule", withCandidates: Bool = true,
                        subagentType: String? = nil) throws -> ApprovalRequestWire {
        try ApprovalTestRequests.bash(command, id: id, subagentType: subagentType, reasonKind: reasonKind,
                                      options: withCandidates ? options : ApprovalTestRequests.allOptions,
                                      sessionRuleCandidates: withCandidates ? candidates : [])
    }

    static func rule(_ id: String = "rule-1", text: String = prefixText, uses: UInt64 = 0,
                     agentId: String? = nil) -> ApprovalSessionRule {
        ApprovalSessionRule(id: id, ruleText: text, summary: "Allows `rm -rf` inside `~/Library/Caches/`",
                            kind: .pathPrefix, createdAtMs: 1_760_000_000_000, uses: uses, agentId: agentId)
    }

    static func frame(_ tag: String = "cody-1", _ rules: [ApprovalSessionRule]) -> ApprovalEvent {
        .sessionRules(ApprovalSessionRulesFrame(tag: tag, rules: rules))
    }
}

/// A window with a button and the events a person would send it.
private struct EventRig {
    let window: NSWindow
    let button: NSButton

    init() {
        window = GestureFixtures.offscreenWindow()
        // An `ApprovalButton` can take keyboard focus (a plain button only with Full Keyboard Access).
        let b = ApprovalButton(title: "Answer", target: nil, action: nil)
        b.frame = NSRect(x: 20, y: 20, width: 120, height: 32)
        window.contentView!.addSubview(b)
        button = b
    }

    /// A point inside the button, in window coordinates.
    var inside: NSPoint { button.convert(NSPoint(x: 5, y: 5), to: nil) }
    var outside: NSPoint { NSPoint(x: 380, y: 220) }

    func mouse(_ type: NSEvent.EventType = .leftMouseUp, at point: NSPoint? = nil, number: Int, time: TimeInterval,
               clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point ?? inside, modifierFlags: [], timestamp: time,
                           windowNumber: window.windowNumber, context: nil, eventNumber: number,
                           clickCount: clickCount, pressure: 1)!
    }

    func key(code: UInt16 = 49, time: TimeInterval, isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: time,
                         windowNumber: window.windowNumber, context: nil, characters: " ",
                         charactersIgnoringModifiers: " ", isARepeat: isARepeat, keyCode: code)!
    }
}

/// A person's gesture for every event (the gate's own extra rules are what these tests are about).
private let anyHuman: SessionRuleGesture.Permit = { _, _, _ in .human(sourcePid: nil, sourceState: nil) }

private func uptime(_ clock: @escaping () -> TimeInterval) -> () -> TimeInterval { clock }

// MARK: - The gate

final class SessionRuleGestureTests: MouseQueueTestCase {

    private var rig: EventRig!

    override func setUp() {
        super.setUp()
        rig = EventRig()
    }

    override func tearDown() {
        rig.window.close()
        rig = nil
        super.tearDown()
    }

    /// The gate with a person's permit and a handler clock the test moves. Without a `clock` the handler
    /// clock ticks half a second per reading, as two real clicks would (a frozen clock is refused as too soon).
    private func gate(clock: (() -> TimeInterval)? = nil) -> SessionRuleGesture {
        var ticks: TimeInterval = 100
        let uptime = clock ?? { ticks += 0.5; return ticks }
        return SessionRuleGesture(permit: anyHuman, uptime: uptime)
    }

    // MARK: HumanGesture

    func testASyntheticEventCompletesNeitherStep() throws {
        let now = ProcessInfo.processInfo.systemUptime
        let realPermit: SessionRuleGesture.Permit = { event, view, menu in
            HumanGesture.permit(event, control: view, menuSelection: menu, contextMenuPick: menu,
                                voiceOverEnabled: { false }, allowsSynthetic: { false }, now: { now })
        }
        let gesture = SessionRuleGesture(permit: realPermit)
        let synthetic = try GestureFixtures.marked(rig.key(time: now))

        XCTAssertEqual(gesture.select(event: synthetic, control: rig.button), .refused(.notHuman(.appControl)))
        XCTAssertFalse(gesture.hasSelection)
        XCTAssertEqual(gesture.confirm(event: synthetic, button: rig.button), .refused(.notHuman(.appControl)))
        XCTAssertEqual(gesture.single(event: synthetic, button: rig.button), .refused(.notHuman(.appControl)))
    }

    func testAnEventlessPressWithVoiceOverOffCompletesNeitherStep() {
        let gesture = SessionRuleGesture(permit: { event, view, menu in
            HumanGesture.permit(event, control: view, menuSelection: menu, contextMenuPick: menu,
                                voiceOverEnabled: { false }, allowsSynthetic: { false })
        })
        XCTAssertEqual(gesture.select(event: nil, control: rig.button), .refused(.notHuman(.accessibilityPress)))
        XCTAssertFalse(gesture.hasSelection)
        XCTAssertEqual(gesture.confirm(event: nil, button: rig.button), .refused(.notHuman(.accessibilityPress)))
        XCTAssertEqual(gesture.single(event: nil, button: rig.button), .refused(.notHuman(.accessibilityPress)))
    }

    func testTheMenuPickIsPermittedAsAMenuSelectionAndTheConfirmIsNot() {
        var picks: [Bool] = []
        let gesture = SessionRuleGesture(permit: { _, _, menu in
            picks.append(menu)
            return .human(sourcePid: nil, sourceState: nil)
        }, uptime: { 100 })
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        _ = gesture.confirm(event: rig.mouse(number: 2, time: 11), button: rig.button)
        XCTAssertEqual(picks, [true, false], "step 1 may be a menu selection (it cannot confirm), step 2 never")
    }

    // MARK: Two events

    func testTheSameEventCannotPickAndConfirm() {
        let gesture = gate()
        let event = rig.mouse(number: 7, time: 10)
        XCTAssertEqual(gesture.select(event: event, control: rig.button), .allowed)
        XCTAssertEqual(gesture.confirm(event: event, button: rig.button), .refused(.sameEvent))
        XCTAssertTrue(gesture.hasSelection, "a refused confirm changes nothing")
        // Same type, timestamp and number built again is the same event.
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 7, time: 10), button: rig.button), .refused(.sameEvent))
    }

    func testAConfirmLessThanAThirdOfASecondAfterThePickIsRefusedOnEventTimeEvenIfTheHandlersRanFarApart() {
        var clock: TimeInterval = 100
        let gesture = gate(clock: { clock })
        XCTAssertEqual(gesture.select(event: rig.mouse(number: 1, time: 10.00), control: rig.button), .allowed)
        clock = 100.4   // the main thread was busy: the handlers ran 0.4 s apart ...
        // ... but the events were 0.15 s apart: one gesture's two instants, not two gestures.
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 10.15), button: rig.button), .refused(.tooSoon))
        XCTAssertTrue(gesture.hasSelection)
    }

    func testAConfirmLaterInEventTimeButHandledTogetherWithThePickIsRefused() {
        let gesture = gate(clock: { 100 })   // the handler clock never moved: forged event stamps
        XCTAssertEqual(gesture.select(event: rig.mouse(number: 1, time: 10.0), control: rig.button), .allowed)
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 10.4), button: rig.button), .refused(.tooSoon))
        XCTAssertTrue(gesture.hasSelection)
    }

    func testAConfirmZeroPointFourSecondsLaterOnBothClocksIsAllowed() {
        var clock: TimeInterval = 100
        let gesture = gate(clock: { clock })
        XCTAssertEqual(gesture.select(event: rig.mouse(number: 1, time: 10.0), control: rig.button), .allowed)
        clock = 100.4
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 10.4), button: rig.button), .allowed)
        XCTAssertFalse(gesture.hasSelection, "a confirm uses the pick up")
    }

    func testAnEventlessConfirmIsMeasuredOnTheHandlerClock() {
        var clock: TimeInterval = 100
        let gesture = gate(clock: { clock })
        XCTAssertEqual(gesture.select(event: nil, control: rig.button), .allowed)   // VoiceOver on
        clock = 100.1
        XCTAssertEqual(gesture.confirm(event: nil, button: rig.button), .refused(.tooSoon))
        clock = 100.5
        XCTAssertEqual(gesture.confirm(event: nil, button: rig.button), .allowed)
    }

    func testAConfirmWithNothingPickedIsRefused() {
        XCTAssertEqual(gate().confirm(event: rig.mouse(number: 1, time: 10), button: rig.button), .refused(.noSelection))
    }

    func testAPickExpiresAfterFifteenSeconds() {
        var clock: TimeInterval = 100
        let gesture = gate(clock: { clock })
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        clock = 100 + SessionRuleGesture.selectionLifetime + 1
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 30), button: rig.button), .refused(.expired))
        XCTAssertFalse(gesture.hasSelection)
    }

    // MARK: Aimed at the button

    func testAHeldKeyRepeatIsRefused() {
        let gesture = gate()
        rig.window.makeFirstResponder(rig.button)
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        XCTAssertEqual(gesture.confirm(event: rig.key(time: 11, isARepeat: true), button: rig.button), .refused(.repeatedKey))
        XCTAssertEqual(gesture.confirm(event: rig.key(time: 11, isARepeat: false), button: rig.button), .allowed)
    }

    func testADoubleClickIsRefused() {
        let gesture = gate()
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 11, clickCount: 2), button: rig.button),
                       .refused(.multiClick))
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 3, time: 12, clickCount: 3), button: rig.button),
                       .refused(.multiClick))
    }

    func testAMouseEventOutsideTheButtonIsRefused() {
        let gesture = gate()
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        // A click elsewhere in the card followed by a programmatic press of the button: the current event is that click.
        XCTAssertEqual(gesture.confirm(event: rig.mouse(at: rig.outside, number: 2, time: 11), button: rig.button),
                       .refused(.outsideControl))
        XCTAssertTrue(gesture.hasSelection)
    }

    func testAKeyIsRefusedWhileAnotherControlHasFocusOrWhenItIsNotSpaceOrReturn() {
        let gesture = gate()
        _ = gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button)
        let other = ApprovalButton(title: "Other", target: nil, action: nil)
        other.frame = NSRect(x: 200, y: 20, width: 80, height: 32)
        rig.window.contentView?.addSubview(other)
        rig.window.makeFirstResponder(other)
        XCTAssertEqual(gesture.confirm(event: rig.key(time: 11), button: rig.button), .refused(.notFocused))

        rig.window.makeFirstResponder(rig.button)
        XCTAssertEqual(gesture.confirm(event: rig.key(code: 0, time: 12), button: rig.button), .refused(.wrongKey))
        XCTAssertEqual(gesture.confirm(event: rig.key(code: 36, time: 13), button: rig.button), .allowed, "Return")
    }

    func testARealShapedClickInsideTheButtonAfterTheGapIsAllowed() {
        let gesture = gate()
        XCTAssertEqual(gesture.select(event: rig.mouse(number: 1, time: 10), control: rig.button), .allowed)
        XCTAssertEqual(gesture.confirm(event: rig.mouse(number: 2, time: 10.5), button: rig.button), .allowed)
    }

    // MARK: Revoke is one step

    func testRevokeNeedsOneHumanGestureAimedAtItsButtonAndRefusesTheSameThingsAConfirmDoes() {
        let gesture = gate()
        XCTAssertEqual(gesture.single(event: rig.mouse(number: 1, time: 10), button: rig.button), .allowed)
        XCTAssertEqual(gesture.single(event: rig.mouse(at: rig.outside, number: 2, time: 10), button: rig.button),
                       .refused(.outsideControl))
        XCTAssertEqual(gesture.single(event: rig.mouse(number: 3, time: 10, clickCount: 2), button: rig.button),
                       .refused(.multiClick))
        XCTAssertEqual(gesture.single(event: rig.key(time: 10, isARepeat: true), button: rig.button), .refused(.repeatedKey))
    }
}

// MARK: - The chip, the store and the popover

final class SessionRulesStoreAndChipTests: MouseQueueTestCase {

    private var keepAlive: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        keepAlive = []
    }

    // MARK: Store

    func testTheStoreKeepsWhatTheDaemonLastSaidPerFocusAndTellsTheFocusOnlyWhenItChanged() {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        let changes = ApprovalTap(store.sessionRulesChanges)

        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        store.handle(RuleFixtures.frame("cody-2", [RuleFixtures.rule("b"), RuleFixtures.rule("c")]))
        XCTAssertEqual(store.sessionRules(tag: "cody-1").map(\.id), ["a"])
        XCTAssertEqual(store.sessionRules(tag: "cody-2").map(\.id), ["b", "c"])
        XCTAssertEqual(changes.values, ["cody-1", "cody-2"])

        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))   // the same picture: nothing new
        XCTAssertEqual(changes.values, ["cody-1", "cody-2"])

        store.handle(RuleFixtures.frame("cody-1", []))   // REPLACE: an empty frame ends them
        XCTAssertEqual(store.sessionRules(tag: "cody-1"), [])
        XCTAssertEqual(store.sessionRules(tag: "cody-2").count, 2, "another focus is untouched")
        XCTAssertEqual(changes.values, ["cody-1", "cody-2", "cody-1"])
    }

    func testANewDaemonConnectionClearsEveryRuleBeforeTheReplay() {
        let store = ApprovalRecorder().makeStore()
        let changes = ApprovalTap(store.sessionRulesChanges)
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        store.handle(RuleFixtures.frame("cody-2", [RuleFixtures.rule("b")]))
        let before = changes.values.count

        store.handle(.connectionStarted)   // the daemon restarted (or the socket came back): the chip must not go stale

        XCTAssertEqual(store.sessionRules(tag: "cody-1"), [])
        XCTAssertEqual(store.sessionRules(tag: "cody-2"), [])
        XCTAssertEqual(Set(changes.values.dropFirst(before)), ["cody-1", "cody-2"], "every chip is told")
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))   // then the replay
        XCTAssertEqual(store.sessionRules(tag: "cody-1").map(\.id), ["a"])
    }

    func testRevokeSendsOnlyForARuleTheStoreHoldsAndOnlyWithAConnection() {
        let recorder = ApprovalRecorder()
        var connected = true
        let store = recorder.makeStore(canSend: { connected })
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))

        XCTAssertFalse(store.revoke(tag: "cody-1", ruleId: "unknown"))
        connected = false
        XCTAssertFalse(store.revoke(tag: "cody-1", ruleId: "a"), "no connection: nothing sent")
        connected = true
        XCTAssertTrue(store.revoke(tag: "cody-1", ruleId: "a"))
        XCTAssertEqual(recorder.revoked, [ApprovalRecorder.Revoke(tag: "cody-1", ruleID: "a")])
        XCTAssertEqual(store.sessionRules(tag: "cody-1").map(\.id), ["a"], "the rule goes when the daemon says so, not before")
    }

    func testTheOutcomesOfASessionAllowHaveWords() {
        XCTAssertEqual(ApprovalStore.outcomeText("allowed_for_session"), "Allowed for this session")
        XCTAssertEqual(ApprovalStore.outcomeText("allowed_by_session_rule"), "Allowed by session rule")
        XCTAssertEqual(ApprovalStore.alreadyResolvedText(outcome: "allowed_for_session"), "Already allowed for this session")
    }

    // MARK: Chip

    func testTheChipReadsOneRuleOrNRulesAndIsHiddenWithNone() {
        let chip = SessionRulesChip()
        XCTAssertTrue(chip.isHidden)
        chip.apply(count: 1)
        XCTAssertEqual(chip.title, "1 rule")
        XCTAssertFalse(chip.isHidden)
        chip.apply(count: 3)
        XCTAssertEqual(chip.title, "3 rules")
        XCTAssertEqual(chip.accessibilityRole(), .button)
        XCTAssertTrue(chip.accessibilityLabel()?.contains("3 session rules") == true)
        chip.setFit(.countOnly)
        XCTAssertEqual(chip.title, "3")
        chip.setFit(.hidden)
        XCTAssertTrue(chip.isHidden)
        chip.setFit(.full)
        chip.apply(count: 0)
        XCTAssertTrue(chip.isHidden)
    }

    func testEveryCountFitsTheSlotAndTheCountAloneFitsTheNarrowerOne() {
        for n in 1 ... SessionRulesChip.countCap {
            let full = NSAttributedString(string: SessionRulesChip.text(count: n, fit: .full),
                                          attributes: [.font: SessionRulesChip.font]).size().width
            XCTAssertLessThanOrEqual(ceil(full) + 2 * SessionRulesChip.horizontalPadding, SessionRulesChip.slotWidth + 0.001, "\(n)")
            let bare = NSAttributedString(string: SessionRulesChip.text(count: n, fit: .countOnly),
                                          attributes: [.font: SessionRulesChip.font]).size().width
            XCTAssertLessThanOrEqual(ceil(bare) + 2 * SessionRulesChip.horizontalPadding, SessionRulesChip.countWidth + 0.001, "\(n)")
        }
        XCTAssertLessThan(SessionRulesChip.countWidth, SessionRulesChip.slotWidth)
    }

    // MARK: Popover

    private func popoverContent(store: ApprovalStore, gesture: SessionRuleGesture = SessionRuleGesture(permit: anyHuman),
                                event: @escaping () -> NSEvent?) -> SessionRulesPopoverContent {
        let content = SessionRulesPopoverContent(tag: "cody-1", store: store, gesture: gesture, currentEvent: event,
                                                 timeZone: TimeZone(identifier: "UTC")!)
        keepAlive.append(content)
        return content
    }

    func testThePopoverListsEveryRulesExactTextAndWhatItCoversWhenItWasGrantedAndHowOftenItWasUsed() {
        let store = ApprovalRecorder().makeStore()
        store.handle(RuleFixtures.frame("cody-1", [
            RuleFixtures.rule("a", uses: 1),
            RuleFixtures.rule("b", text: "Bash(git push)", uses: 3, agentId: "agent_x"),
        ]))
        let content = popoverContent(store: store, event: { nil })

        XCTAssertEqual(content.rows.map(\.ruleText), [RuleFixtures.prefixText, "Bash(git push)"])
        XCTAssertEqual(content.rows[0].detail, "granted 8:53 am · used 1 time")
        XCTAssertEqual(content.rows[1].detail, "granted 8:53 am · used 3 times · for sub-agent agent_x")
        XCTAssertEqual(content.rows.map(\.summary), [RuleFixtures.rule().summary, RuleFixtures.rule().summary])
        XCTAssertEqual(Set(content.revokeButtons.keys), ["a", "b"])
        XCTAssertEqual(content.revokeButtons["a"]?.title, "Revoke")
    }

    func testRevokeByAPersonSendsExactlyOneRevoke() {
        let rig = EventRig()
        defer { rig.window.close() }
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        var current: NSEvent?
        let content = popoverContent(store: store, event: { current })
        let button = try! XCTUnwrap(content.revokeButtons["a"])
        // A click inside the Revoke button.
        current = rig.mouse(at: button.convert(NSPoint(x: 4, y: 4), to: nil), number: 1, time: 10)

        XCTAssertTrue(content.revoke(ruleID: "a", button: button))

        XCTAssertEqual(recorder.revoked, [ApprovalRecorder.Revoke(tag: "cody-1", ruleID: "a")])
        // A click elsewhere is not a press of Revoke.
        current = rig.mouse(at: NSPoint(x: 5_000, y: 5_000), number: 2, time: 11)
        XCTAssertFalse(content.revoke(ruleID: "a", button: button))
        XCTAssertEqual(recorder.revoked.count, 1)
    }

    func testARefusedRevokeSendsNothingAndIsReported() {
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        let eventless = SessionRuleGesture(permit: { event, view, menu in
            HumanGesture.permit(event, control: view, menuSelection: menu, contextMenuPick: menu,
                                voiceOverEnabled: { false }, allowsSynthetic: { false })
        })
        let content = popoverContent(store: store, gesture: eventless, event: { nil })
        let button = try! XCTUnwrap(content.revokeButtons["a"])

        XCTAssertFalse(content.revoke(ruleID: "a", button: button))

        XCTAssertEqual(recorder.revoked, [], "an event-less press with VoiceOver off revokes nothing")
        XCTAssertEqual(recorder.reports, [ApprovalRecorder.Report(requestID: nil, control: "revoke_session_rule", channel: .accessibility)])
    }

    func testASyntheticRevokeIsRefusedAndReportedAsAppControl() throws {
        let rig = EventRig()
        defer { rig.window.close() }
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        let now = ProcessInfo.processInfo.systemUptime
        let gesture = SessionRuleGesture(permit: { event, view, menu in
            HumanGesture.permit(event, control: view, menuSelection: menu, contextMenuPick: menu,
                                voiceOverEnabled: { false }, allowsSynthetic: { false }, now: { now })
        })
        let synthetic = try GestureFixtures.marked(rig.key(time: now))
        let content = popoverContent(store: store, gesture: gesture, event: { synthetic })
        let button = try! XCTUnwrap(content.revokeButtons["a"])

        XCTAssertFalse(content.revoke(ruleID: "a", button: button))
        XCTAssertEqual(recorder.revoked, [])
        XCTAssertEqual(recorder.reports.map(\.channel), [.appControl])
    }
}

// MARK: - The card

final class SessionRuleCardTests: MouseQueueTestCase {

    private var rig: EventRig!
    private var current: NSEvent?

    override func setUp() {
        super.setUp()
        rig = EventRig()
    }

    override func tearDown() {
        rig.window.close()
        rig = nil
        super.tearDown()
    }

    private func harness(_ request: ApprovalRequestWire, permit: @escaping SessionRuleGesture.Permit = anyHuman,
                         clock: @escaping () -> TimeInterval = { 100 }) -> ApprovalCardHarness {
        ApprovalCardHarness(self, request: request,
                            gesture: SessionRuleGesture(permit: permit, uptime: clock),
                            currentEvent: { [unowned self] in self.current })
    }

    /// A click on `button`, as a person's event at `time`.
    private func click(_ button: NSView, number: Int, time: TimeInterval, in window: NSWindow) -> NSEvent {
        let point = button.convert(NSPoint(x: 4, y: 4), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                  clickCount: 1, pressure: 1)!
    }

    private func select(_ h: ApprovalCardHarness, index: Int, time: TimeInterval = 10) {
        let button = h.card.sessionButton!
        current = click(button, number: 1, time: time, in: h.window)
        XCTAssertTrue(h.card.selectSessionRule(h.card.options.sessionRules[index], control: button))
        // What the host does when the card asks for more room (`onNeedsLayout`): measure again and lay out.
        h.card.frame.size.height = h.card.preferredHeight(forWidth: h.card.frame.width, maxHeight: 520)
        h.relayout()
    }

    // MARK: What the card offers

    func testACardWithoutCandidatesHasNoThisSessionControl() throws {
        let h = harness(try RuleFixtures.request(withCandidates: false))
        XCTAssertNil(h.card.sessionButton)
        XCTAssertNil(h.card.sessionConfirmButton)
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"])
        XCTAssertEqual(h.card.listing.sessionRules, [])
    }

    func testACardWithCandidatesOffersTheMenuBesideAllowOnceAndNoConfirmUntilARuleIsPicked() throws {
        let h = harness(try RuleFixtures.request())
        XCTAssertEqual(h.card.sessionButton?.title, "This session ▾")
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once", "allow_session"])
        XCTAssertEqual(h.card.listing.sessionRules.map(\.ruleText), [RuleFixtures.exactText, RuleFixtures.prefixText])
        XCTAssertTrue(h.card.sessionConfirmButton?.isHidden == true, "no pick, no confirm button")
        XCTAssertNil(h.card.listing.sessionSelectedID)
        XCTAssertNil(h.card.listing.sessionPanel)
        // Beside Allow once, not on top of it.
        let pop = h.card.sessionButton!.frame, allow = h.card.allowButton!.frame
        XCTAssertLessThanOrEqual(pop.maxX, allow.minX + 0.5)
    }

    func testNeitherButtonHasAKeyEquivalentAndNeitherIsTheDefault() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 1)
        for button in [h.card.sessionButton!, h.card.sessionConfirmButton!] {
            XCTAssertEqual(button.keyEquivalent, "")
        }
        XCTAssertNil(h.window.defaultButtonCell, "no button on the card is the default")
    }

    // MARK: Step 1 only selects

    func testChoosingARuleOnlySelectsItAndSendsNothing() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 1)

        XCTAssertEqual(h.recorder.sent, [], "a pick answers nothing")
        XCTAssertEqual(h.recorder.reports, [])
        XCTAssertEqual(h.card.selectedCandidate?.id, "c-prefix")
        XCTAssertEqual(h.card.listing.sessionSelectedID, "c-prefix")
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, .pending)
    }

    func testThePanelShowsExactlyWhatWillBeAllowed() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 1)
        let candidate = h.card.options.sessionRules[1]

        let panel = try XCTUnwrap(h.card.listing.sessionPanel)
        XCTAssertEqual(panel, [
            candidate.ruleText,
            candidate.summary,
            "For Cody in this session only, until it stops, restarts or you Clear Context",
            "Overrides your rule Bash(rm:*) for matching commands, this session only",
        ])
        XCTAssertFalse(h.card.sessionConfirmButton!.isHidden)
        XCTAssertEqual(h.card.sessionConfirmButton?.title, "Allow for this session")
        // Inside the card's own frame, not only in the menu.
        for view in [h.card.sessionConfirmButton!] {
            XCTAssertTrue(h.card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.frame), "\(view.frame) in \(h.card.bounds)")
        }
    }

    func testAnAskRuleRequestWhoseRuleIsUnknownSaysSoAndAnotherRequestSaysNothingOfOverriding() throws {
        let noRule = try ApprovalTestRequests.bash(
            "rm -rf ~/Library/Caches/a", options: RuleFixtures.options,
            sessionRuleCandidates: [["id": "c1", "rule_text": RuleFixtures.exactText, "summary": "s", "kind": "exact"]])
        let h = harness(noRule)
        select(h, index: 0)
        XCTAssertEqual(h.card.listing.sessionPanel?.last, "Overrides your ask rule for matching commands, this session only")

        let other = harness(try RuleFixtures.request(id: "req-2", reasonKind: "other"))
        select(other, index: 0)
        XCTAssertEqual(other.card.listing.sessionPanel?.count, 3, "no overrides line")
        XCTAssertFalse(other.card.listing.sessionPanel!.contains { $0.contains("Overrides") })
    }

    func testARefusedPickSelectsNothingAndIsReported() throws {
        let h = harness(try RuleFixtures.request(), permit: { _, _, _ in .refused(reason: .accessibilityPress) })
        XCTAssertFalse(h.card.selectSessionRule(h.card.options.sessionRules[0], control: h.card.sessionButton!))
        XCTAssertNil(h.card.selectedCandidate)
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_session", channel: .accessibility)])
        XCTAssertEqual(h.recorder.sent, [])
    }

    // MARK: Step 2 confirms

    func testARealShapedConfirmAfterTheGapSendsExactlyOneAllowSessionNamingTheShownRule() throws {
        var clock: TimeInterval = 100   // the handlers' clock must move too: both gaps count
        let h = harness(try RuleFixtures.request(), clock: { clock })
        select(h, index: 1, time: 10)
        let confirm = h.card.sessionConfirmButton!
        XCTAssertTrue(confirm.isEnabled)

        clock = 100.5
        current = click(confirm, number: 2, time: 10.5, in: h.window)
        confirm.performClick(nil)
        confirm.performClick(nil)   // a second press changes nothing: the store answers once

        XCTAssertEqual(h.recorder.sent.count, 1)
        let sent = try XCTUnwrap(h.recorder.sent.first)
        XCTAssertEqual(sent.requestID, "req-1")
        XCTAssertEqual(sent.decision, ApprovalDecisionWire(kind: .allowSession, candidateId: "c-prefix",
                                                           ruleText: RuleFixtures.prefixText))
        XCTAssertEqual(sent.windowID, "w-test")
    }

    func testTheSameEventForBothStepsSendsNothingAndKeepsThePick() throws {
        let h = harness(try RuleFixtures.request())
        let confirm = h.card.sessionConfirmButton!
        let event = click(confirm, number: 5, time: 10, in: h.window)
        current = event
        XCTAssertTrue(h.card.selectSessionRule(h.card.options.sessionRules[0], control: h.card.sessionButton!))
        // Showing the panel un-hid the confirm button; the very same event "presses" it.
        confirm.performClick(nil)

        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertEqual(h.card.selectedCandidate?.id, "c-exact", "a refused confirm keeps the selection")
    }

    func testAConfirmTooSoonOnEventTimeOrAClickElsewhereOrADoubleClickSendsNothing() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 0, time: 10)
        let confirm = h.card.sessionConfirmButton!

        current = click(confirm, number: 2, time: 10.1, in: h.window)   // 0.1 s later
        confirm.performClick(nil)
        XCTAssertEqual(h.recorder.sent, [], "too soon")

        // A click elsewhere in the card, then a programmatic press of the button: the current event is that click.
        current = NSEvent.mouseEvent(with: .leftMouseUp, location: h.card.convert(NSPoint(x: 2, y: 2), to: nil),
                                     modifierFlags: [], timestamp: 11, windowNumber: h.window.windowNumber, context: nil,
                                     eventNumber: 3, clickCount: 1, pressure: 1)
        confirm.performClick(nil)
        XCTAssertEqual(h.recorder.sent, [], "an event outside the button")

        current = NSEvent.mouseEvent(with: .leftMouseUp, location: confirm.convert(NSPoint(x: 4, y: 4), to: nil),
                                     modifierFlags: [], timestamp: 12, windowNumber: h.window.windowNumber, context: nil,
                                     eventNumber: 4, clickCount: 2, pressure: 1)
        confirm.performClick(nil)
        XCTAssertEqual(h.recorder.sent, [], "a double click")
        XCTAssertNotNil(h.card.selectedCandidate)
    }

    func testAnEventlessConfirmWithVoiceOverOffSendsNothingAndIsReported() throws {
        let strict: SessionRuleGesture.Permit = { event, view, menu in
            // The pick is a person's; the confirm arrives with no event at all.
            if menu { return .human(sourcePid: nil, sourceState: nil) }
            return HumanGesture.permit(event, control: view, voiceOverEnabled: { false }, allowsSynthetic: { false })
        }
        let h = harness(try RuleFixtures.request(), permit: strict, clock: { 100 })
        select(h, index: 0)
        current = nil
        h.card.sessionConfirmButton!.performClick(nil)
        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_session", channel: .accessibility)])
    }

    func testTheConfirmIsDisabledUntilTheWholeInputWasShown() throws {
        let request = try ApprovalTestRequests.bash(ApprovalTestRequests.heredoc300Command, commandCount: 14,
                                                    options: RuleFixtures.options,
                                                    sessionRuleCandidates: RuleFixtures.candidates)
        let h = harness(request)
        select(h, index: 0)
        XCTAssertFalse(h.card.sessionConfirmButton!.isEnabled, "the input has lines nobody has seen")
        XCTAssertFalse(h.card.canAllowSession)

        ApprovalTestViews.readThrough(h.card.inputView)
        h.relayout()
        XCTAssertTrue(h.card.sessionConfirmButton!.isEnabled, "once every line was shown")
    }

    // MARK: Reverting

    func testThePickRevertsWhenTheRequestChanges() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 0)
        XCTAssertNotNil(h.card.selectedCandidate)

        h.store.answer("req-1", ApprovalDecisionWire(kind: .deny), windowID: "w")   // the state moves on
        h.sync()

        XCTAssertNil(h.card.selectedCandidate)
        XCTAssertTrue(h.card.sessionConfirmButton!.isHidden)
        XCTAssertNil(h.card.listing.sessionPanel)
    }

    func testThePickRevertsWhenTheCardLeavesItsWindow() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 0)
        h.card.removeFromSuperview()
        XCTAssertNil(h.card.selectedCandidate)
    }

    func testThePickRevertsAfterFifteenSeconds() throws {
        let h = harness(try RuleFixtures.request())
        select(h, index: 0)
        let expiry = expectation(description: "the pick reverts")
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionRuleGesture.selectionLifetime + 0.5) { expiry.fulfill() }
        wait(for: [expiry], timeout: SessionRuleGesture.selectionLifetime + 3)
        XCTAssertNil(h.card.selectedCandidate)
    }
}

// MARK: - The input bar's slot

final class SessionRulesSlotTests: MouseQueueTestCase {

    private var keepAlive: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        keepAlive = []
    }

    private func settle(_ bar: ReplInputBar, in window: NSWindow) {
        for _ in 0 ..< 3 {
            window.contentView?.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
        }
    }

    private func bar(width: CGFloat, store: ApprovalStore, bind: Bool = true) -> (ReplInputBar, NSWindow) {
        let window = makeRigWindow(self, size: NSSize(width: width, height: 60))
        let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        window.contentView?.addSubview(bar)
        if bind { bar.bindSessionRules(tag: "cody-1", store: store) }
        settle(bar, in: window)
        keepAlive.append(bar)
        return (bar, window)
    }

    func testTheSlotIsZeroWidthUntilBoundThenFixedWhateverTheChipShowsAndNothingElseMoves() {
        let store = ApprovalRecorder().makeStore()
        let (bar, window) = bar(width: 700, store: store, bind: false)
        XCTAssertEqual(bar.sessionRulesSlot.frame.width, 0, accuracy: 0.5, "no session: no space")
        bar.bindSessionRules(tag: "cody-1", store: store)
        settle(bar, in: window)
        XCTAssertEqual(bar.sessionRulesSlot.frame.width, SessionRulesChip.slotWidth, accuracy: 0.5)
        XCTAssertTrue(bar.sessionRulesChip.isHidden, "no rules: nothing drawn in the slot")

        let composer = bar.textView.enclosingScrollView?.frame
        let height = bar.frame.height
        let steps: [[ApprovalSessionRule]] = [
            [RuleFixtures.rule("a")],
            [RuleFixtures.rule("a"), RuleFixtures.rule("b")],
            (0 ..< 32).map { RuleFixtures.rule("r\($0)") },
            [],
        ]
        for rules in steps {
            store.handle(RuleFixtures.frame("cody-1", rules))
            settle(bar, in: window)
            XCTAssertEqual(bar.sessionRulesChip.isHidden, rules.isEmpty, "\(rules.count)")
            XCTAssertEqual(bar.sessionRulesSlot.frame.width, SessionRulesChip.slotWidth, accuracy: 0.5, "\(rules.count)")
            XCTAssertEqual(bar.textView.enclosingScrollView?.frame, composer, "the composer must not move: \(rules.count)")
            XCTAssertEqual(bar.frame.height, height, accuracy: 0.5, "the bar's height must not change: \(rules.count)")
            XCTAssertLessThanOrEqual(bar.sessionRulesChip.frame.width, bar.sessionRulesSlot.frame.width + 0.5, "\(rules.count)")
        }
    }

    func testTheChipAppearsChangesAndGoesWithTheStoreAndOnAReconnect() {
        let store = ApprovalRecorder().makeStore()
        let (bar, _) = bar(width: 700, store: store)
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        XCTAssertEqual(bar.sessionRulesChip.title, "1 rule")
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a"), RuleFixtures.rule("b")]))
        XCTAssertEqual(bar.sessionRulesChip.title, "2 rules")
        store.handle(RuleFixtures.frame("cody-2", [RuleFixtures.rule("z")]))   // another focus: not this bar's
        XCTAssertEqual(bar.sessionRulesChip.title, "2 rules")
        store.handle(.connectionStarted)
        XCTAssertTrue(bar.sessionRulesChip.isHidden, "a reconnect clears the chip before the replay")
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        XCTAssertFalse(bar.sessionRulesChip.isHidden)
        store.handle(RuleFixtures.frame("cody-1", []))
        XCTAssertTrue(bar.sessionRulesChip.isHidden)
    }

    func testTheChipShowsWhatItsSlotHasRoomForAsTheBarNarrows() {
        let store = ApprovalRecorder().makeStore()
        store.handle(RuleFixtures.frame("cody-1", (0 ..< 32).map { RuleFixtures.rule("r\($0)") }))
        var fits: [SessionRulesChip.Fit] = []
        for width in [CGFloat(700), 420, 330, 250] {
            let (bar, window) = bar(width: width, store: store)
            settle(bar, in: window)
            fits.append(bar.sessionRulesChip.fit)
            // Never overlapping the composer or the send button.
            let composer = bar.textView.enclosingScrollView!.frame
            if !bar.sessionRulesChip.isHidden {
                let chip = bar.sessionRulesSlot.convert(bar.sessionRulesChip.frame, to: bar)
                XCTAssertLessThanOrEqual(composer.maxX, chip.minX + 0.5, "\(Int(width)) pt: the chip must not overlap the composer")
                XCTAssertTrue(bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains(chip), "\(Int(width)) pt")
            }
        }
        XCTAssertEqual(fits.first, .full)
        // Full, then the count alone, then gone: never the other way round as the bar narrows.
        let order: [SessionRulesChip.Fit] = [.full, .countOnly, .hidden]
        let ranks = fits.map { order.firstIndex(of: $0)! }
        XCTAssertEqual(ranks, ranks.sorted(), "\(fits)")
    }

    func testInANarrowBarTheBackgroundSlotGivesWayBeforeTheSessionRulesSlot() {
        let store = ApprovalRecorder().makeStore()
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        let tasks = BA3UIWorld(self)
        for width in stride(from: CGFloat(700), through: 220, by: -40) {
            let window = makeRigWindow(self, size: NSSize(width: width, height: 60))
            let bar = ba3uiMakeBar(in: window, frame: NSRect(x: 0, y: 0, width: width, height: 60), store: tasks.store)
            bar.bindSessionRules(tag: "cody-1", store: store)
            keepAlive.append(bar)
            settle(bar, in: window)
            let sessionFull = bar.sessionRulesSlot.frame.width + 0.5 >= SessionRulesChip.slotWidth
            let backgroundFull = bar.backgroundSlot.frame.width + 0.5 >= BackgroundChip.slotWidth
            if !sessionFull {
                XCTAssertFalse(backgroundFull, "\(Int(width)) pt: the session slot gave way while the background slot was still whole")
            }
            let parts = [("composer", bar.textView.enclosingScrollView!.frame), ("session rules", bar.sessionRulesSlot.frame),
                         ("background", bar.backgroundSlot.frame)]
            for (i, a) in parts.enumerated() {
                for b in parts[(i + 1)...] {
                    let overlap = a.1.intersection(b.1)
                    XCTAssertFalse(!overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5,
                                   "\(Int(width)) pt: \(a.0) and \(b.0) overlap")
                }
            }
        }
    }

    // MARK: Scroll safety

    func testTheChipAppearingChangingAndGoingMovesTheTranscriptAtMostOnePoint() {
        for following in [true, false] {
            let rig = following ? SafetyRig.followingTail(self) : SafetyRig.scrolledUp(self)
            let store = ApprovalRecorder().makeStore()
            rig.inputBar.bindSessionRules(tag: "cody-1", store: store)
            rig.window.contentView?.layoutSubtreeIfNeeded()
            let steps: [(String, [ApprovalSessionRule])] = [
                ("the chip appears", [RuleFixtures.rule("a")]),
                ("the chip changes", [RuleFixtures.rule("a", uses: 4), RuleFixtures.rule("b")]),
                ("the chip goes", []),
            ]
            for (name, rules) in steps {
                rig.assertNoMove("\(name) (following: \(following))", following: following) {
                    store.handle(RuleFixtures.frame("cody-1", rules))
                }
            }
        }
    }
}

// MARK: - AP6: the chip's popover and the log link into the Rules list

final class PersistedRulesNavigationTests: MouseQueueTestCase {

    func testTheSessionRulesPopoverHasAnAllRulesButtonThatOpensTheRulesWindow() {
        _ = NSApplication.shared
        let store = ApprovalRecorder().makeStore()
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a")]))
        let content = SessionRulesPopoverContent(tag: "cody-1", store: store, gesture: SessionRuleGesture(permit: anyHuman),
                                                 currentEvent: { nil }, timeZone: TimeZone(identifier: "UTC")!)
        var opened = 0
        content.openAllRules = { opened += 1 }
        let button = try! XCTUnwrap(content.allRulesButton)
        XCTAssertEqual(button.title, "All rules…")
        button.performClick(nil)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(store.persistedRules, [], "opening the list changes nothing")
    }

    func testTheApprovalsWindowHasARulesButtonThatOpensTheRulesWindow() {
        let world = ApprovalsLogWorld()
        var opened = 0
        world.view.openRules = { opened += 1 }
        XCTAssertEqual(world.view.rulesButton.title, "Rules…")
        world.view.rulesButton.performClick(nil)
        XCTAssertEqual(opened, 1)
    }
}

// MARK: - AP6: "Always allow…" on the card

/// The panel behind `This session ▾ ▸ Always allow…`: two steps (open, then Write rule), exactly the rule and
/// scope shown, and nothing sent until the second, separate human gesture.
final class AlwaysAllowCardTests: MouseQueueTestCase {

    private var current: NSEvent?
    /// The handlers' clock (the gate takes the smaller of this gap and the events' own).
    private var clock: TimeInterval = 100
    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
        super.tearDown()
    }

    private static let root = "/opt/work/x"
    private static let options = RuleFixtures.options + ["allow_always"]

    private func request(id: String = "req-1", candidates: [[String: Any]] = RuleFixtures.candidates,
                         options: [String] = AlwaysAllowCardTests.options, root: String? = AlwaysAllowCardTests.root,
                         isGit: Bool? = true, reasonKind: String = "ask_rule") throws -> ApprovalRequestWire {
        try ApprovalTestRequests.bash("rm -rf ~/Library/Caches/a", id: id, reasonKind: reasonKind, options: options,
                                      sessionRuleCandidates: candidates, repoRoot: root, repoIsGit: isGit)
    }

    private func harness(_ request: ApprovalRequestWire, permit: @escaping SessionRuleGesture.Permit = anyHuman) -> ApprovalCardHarness {
        ApprovalCardHarness(self, request: request,
                            gesture: SessionRuleGesture(permit: permit, uptime: { [unowned self] in self.clock }),
                            currentEvent: { [unowned self] in self.current })
    }

    private func click(_ view: NSView, number: Int, time: TimeInterval, in window: NSWindow, clickCount: Int = 1) -> NSEvent {
        let point = view.convert(NSPoint(x: 4, y: 4), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                  clickCount: clickCount, pressure: 1)!
    }

    /// What the host does when the card asks for more room.
    private func relayout(_ h: ApprovalCardHarness) {
        h.card.frame.size.height = h.card.preferredHeight(forWidth: h.card.frame.width, maxHeight: 520)
        h.relayout()
    }

    /// Step 1 by a person: `Always allow…` chosen in the menu at event time `time` (the handler clock is `time + 90`).
    @discardableResult
    private func open(_ h: ApprovalCardHarness, number: Int = 1, time: TimeInterval = 10) -> Bool {
        let button = h.card.sessionButton!
        current = click(button, number: number, time: time, in: h.window)
        clock = time + 90
        let opened = h.card.openAlwaysPanel(control: button)
        relayout(h)
        return opened
    }

    /// Change a pop-up to item `index` as a person at event time `time`; returns whether the card accepted it.
    @discardableResult
    private func choose(_ h: ApprovalCardHarness, _ popup: NSPopUpButton, index: Int, number: Int, time: TimeInterval) -> Bool {
        popup.selectItem(at: index)
        current = click(popup, number: number, time: time, in: h.window)
        clock = time + 90
        let accepted = h.card.changeAlwaysChoice(from: popup)
        relayout(h)
        return accepted
    }

    /// Press `Write rule` as a person's event at `time` (handler clock `time + 90`).
    @discardableResult
    private func write(_ h: ApprovalCardHarness, number: Int, time: TimeInterval, clickCount: Int = 1) -> Bool {
        let button = h.card.alwaysWriteButton!
        current = click(button, number: number, time: time, in: h.window, clickCount: clickCount)
        clock = time + 90
        return h.card.writeRule(from: button)
    }

    private func decision(_ id: String, _ text: String, _ scope: ApprovalRuleScope) -> ApprovalDecisionWire {
        ApprovalDecisionWire(kind: .allowAlways, candidateId: id, ruleText: text, scope: scope)
    }

    // MARK: What the card offers

    func testAlwaysAllowIsOfferedWhenTheDaemonListedItWithACandidateAndARepoRootAndAddsNoButton() throws {
        let h = harness(try request())
        XCTAssertTrue(h.card.listing.alwaysOffered)
        XCTAssertEqual(h.card.sessionButton?.title, "This session ▾")
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once", "allow_session"],
                       "Always allow… is a menu item, never a button")
        XCTAssertNil(h.card.listing.alwaysPanel, "closed until chosen")
        XCTAssertEqual(h.card.listing.jsonObject["always_offered"] as? Bool, true)
        XCTAssertTrue(h.card.listing.jsonObject["always_panel"] is NSNull)
    }

    func testAlwaysAllowIsNotOfferedWithoutTheOptionACandidateOrARepoRoot() throws {
        let unlisted = harness(try request(options: RuleFixtures.options))
        XCTAssertFalse(unlisted.card.listing.alwaysOffered)
        XCTAssertFalse(unlisted.card.openAlwaysPanel(control: unlisted.card.sessionButton!))

        let noCandidates = harness(try request(id: "req-2", candidates: []))
        XCTAssertFalse(noCandidates.card.listing.alwaysOffered)

        let noRoot = harness(try request(id: "req-3", root: nil, isGit: nil))
        XCTAssertFalse(noRoot.card.listing.alwaysOffered)
        XCTAssertFalse(noRoot.card.openAlwaysPanel(control: noRoot.card.sessionButton!))
        XCTAssertFalse(noRoot.card.alwaysIsOpen)

        let safety = harness(try request(id: "req-4", reasonKind: "safety_check"))
        XCTAssertFalse(safety.card.listing.alwaysOffered)
    }

    func testAlwaysAllowAloneStillGivesTheMenuItsButton() throws {
        // The daemon listed allow_always but not allow_session: the menu exists for Always allow… alone.
        let h = harness(try request(options: ApprovalTestRequests.allOptions + ["allow_always"]))
        XCTAssertTrue(h.card.listing.alwaysOffered)
        XCTAssertNotNil(h.card.sessionButton)
        XCTAssertEqual(h.card.listing.options.map(\.id), ["deny", "deny_with_note", "deny_and_stop", "allow_once"])
    }

    // MARK: Step 1 opens a panel and sends nothing

    func testOpeningThePanelPreselectsTheExactRuleAndTheRepositoryAndShowsEveryLine() throws {
        // The daemon sent the broad candidate first: the exact one is still the preselected.
        let h = harness(try request(candidates: Array(RuleFixtures.candidates.reversed())))
        XCTAssertTrue(open(h))

        XCTAssertEqual(h.card.listing.alwaysPanel, [
            RuleFixtures.exactText,
            "Write this rule to ~/.nostromo/approvals/rules.json",
            "This repository (/opt/work/x)",
            "Every Nostromo session in /opt/work/x will run this without asking",
            "Your ~/.claude/settings.json is not changed",
        ])
        XCTAssertEqual(h.card.alwaysCandidatePopup?.titleOfSelectedItem, RuleFixtures.exactText)
        XCTAssertEqual(h.card.alwaysCandidatePopup?.itemTitles, [RuleFixtures.exactText, RuleFixtures.prefixText])
        XCTAssertEqual(h.card.alwaysScopePopup?.titleOfSelectedItem, "This repository (/opt/work/x)")
        XCTAssertEqual(h.card.alwaysScopePopup?.itemTitles, ["This repository (/opt/work/x)", "All repositories"])
        XCTAssertEqual(h.card.alwaysWriteButton?.title, "Write rule")
        XCTAssertEqual(h.card.alwaysCopyButton?.title, "Copy rule")
        XCTAssertEqual(h.card.alwaysCancelButton?.title, "Cancel")
        XCTAssertEqual(h.recorder.sent, [], "step 1 answers nothing")
        XCTAssertEqual(h.recorder.reports, [])
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, .pending)
        // Inside the card's own frame, not a sheet.
        for view in [h.card.alwaysWriteButton!, h.card.alwaysCopyButton!, h.card.alwaysCancelButton!] {
            let frame = h.card.convert(view.bounds, from: view)
            XCTAssertTrue(h.card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) in \(h.card.bounds)")
        }
    }

    func testAFolderThatIsNotARepositoryIsCalledAFolder() throws {
        let h = harness(try request(isGit: false))
        XCTAssertTrue(open(h))
        XCTAssertEqual(h.card.alwaysScopePopup?.titleOfSelectedItem, "This folder (/opt/work/x)")
        XCTAssertEqual(h.card.listing.alwaysPanel?[2], "This folder (/opt/work/x)")
    }

    func testNothingIsSentByOpeningChangingEitherPopUpCopyingOrCancelling() throws {
        let h = harness(try request())
        let board = NSPasteboard(name: NSPasteboard.Name("nostromo.test.\(UUID().uuidString)"))
        pasteboards.append(board)
        h.card.pasteboard = board
        XCTAssertTrue(open(h, number: 1, time: 10))
        XCTAssertTrue(choose(h, h.card.alwaysCandidatePopup!, index: 1, number: 2, time: 20))
        XCTAssertTrue(choose(h, h.card.alwaysScopePopup!, index: 1, number: 3, time: 30))

        h.card.alwaysCopyButton!.performClick(nil)
        XCTAssertEqual(board.string(forType: .string), RuleFixtures.prefixText, "Copy rule puts the rule as shown on the pasteboard")
        XCTAssertEqual(h.recorder.sent, [])

        h.card.alwaysCancelButton!.performClick(nil)
        XCTAssertFalse(h.card.alwaysIsOpen)
        XCTAssertNil(h.card.listing.alwaysPanel)
        XCTAssertEqual(h.recorder.sent, [], "nothing was sent at any step")
        XCTAssertEqual(h.recorder.reports, [])
        XCTAssertEqual(h.store.entry(id: "req-1")?.state, .pending)
    }

    func testChangingEitherPopUpUpdatesWhatThePanelShows() throws {
        let h = harness(try request())
        open(h)
        choose(h, h.card.alwaysCandidatePopup!, index: 1, number: 2, time: 20)
        XCTAssertEqual(h.card.listing.alwaysPanel?[0], RuleFixtures.prefixText)
        choose(h, h.card.alwaysScopePopup!, index: 1, number: 3, time: 30)
        let panel = try XCTUnwrap(h.card.listing.alwaysPanel)
        XCTAssertEqual(panel[2], "All repositories")
        XCTAssertEqual(panel[3], "Every Nostromo session in all repositories will run this without asking")
        XCTAssertEqual(panel[4], "Your ~/.claude/settings.json is not changed")
    }

    // MARK: Step 2 writes

    func testWriteRuleAfterTheGapSendsExactlyOneAllowAlwaysNamingTheShownRuleAndScope() throws {
        let h = harness(try request())
        open(h, time: 10)
        XCTAssertTrue(h.card.alwaysWriteButton!.isEnabled)

        current = click(h.card.alwaysWriteButton!, number: 2, time: 10.5, in: h.window)
        clock = 100.5
        h.card.alwaysWriteButton!.performClick(nil)
        h.card.alwaysWriteButton!.performClick(nil)   // a second press changes nothing: the store answers once

        XCTAssertEqual(h.recorder.sent.count, 1)
        XCTAssertEqual(h.recorder.sent.first?.requestID, "req-1")
        XCTAssertEqual(h.recorder.sent.first?.decision, decision("c-exact", RuleFixtures.exactText, .repo))
        XCTAssertEqual(h.recorder.sent.first?.windowID, "w-test")
    }

    func testWriteRuleNamesTheRuleAndScopeLastChosenNotThePreselectedOnes() throws {
        let h = harness(try request())
        open(h, number: 1, time: 10)
        choose(h, h.card.alwaysCandidatePopup!, index: 1, number: 2, time: 20)
        choose(h, h.card.alwaysScopePopup!, index: 1, number: 3, time: 30)

        XCTAssertTrue(write(h, number: 4, time: 31))
        XCTAssertEqual(h.recorder.sent.map(\.decision), [decision("c-prefix", RuleFixtures.prefixText, .allRepos)])
    }

    func testAFastDoubleActionAfterAPopUpChangeCannotWriteABroaderRule() throws {
        let h = harness(try request())
        open(h, number: 1, time: 10)
        // Long after opening, the person widens the scope, and a second action follows at once.
        choose(h, h.card.alwaysScopePopup!, index: 1, number: 2, time: 20)
        XCTAssertFalse(write(h, number: 3, time: 20.1), "0.1 s after the last choice")
        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertTrue(h.card.alwaysIsOpen, "the panel stays, showing the broader scope")
        XCTAssertEqual(h.card.listing.alwaysPanel?[2], "All repositories")

        XCTAssertTrue(write(h, number: 4, time: 21), "a separate gesture after the gap")
        XCTAssertEqual(h.recorder.sent.map(\.decision), [decision("c-exact", RuleFixtures.exactText, .allRepos)])
    }

    func testAFastDoubleActionAfterChangingTheRuleCannotWriteTheNewRule() throws {
        let h = harness(try request())
        open(h, number: 1, time: 10)
        choose(h, h.card.alwaysCandidatePopup!, index: 1, number: 2, time: 20)
        XCTAssertFalse(write(h, number: 3, time: 20.2))
        XCTAssertEqual(h.recorder.sent, [])
    }

    func testWriteRuleIsRefusedWhenTheEventIsTheOneThatOpenedThePanel() throws {
        let h = harness(try request())
        // A key event (space) opens the panel; the very same event "presses" Write rule.
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10,
                                   windowNumber: h.window.windowNumber, context: nil, characters: " ",
                                   charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        current = key
        clock = 100
        XCTAssertTrue(h.card.openAlwaysPanel(control: h.card.sessionButton!))
        relayout(h)
        clock = 101
        XCTAssertFalse(h.card.writeRule(from: h.card.alwaysWriteButton!))
        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertTrue(h.card.alwaysIsOpen)
    }

    func testWriteRuleIsRefusedForAClickOutsideTheButtonADoubleClickAndAHandlerClockThatHasNotMoved() throws {
        let h = harness(try request())
        open(h, number: 1, time: 10)

        current = click(h.card.alwaysCancelButton!, number: 2, time: 11, in: h.window)   // aimed at another control
        clock = 101
        XCTAssertFalse(h.card.writeRule(from: h.card.alwaysWriteButton!))

        XCTAssertFalse(write(h, number: 3, time: 12, clickCount: 2), "a double click")

        // Event times far apart, but the handlers ran back to back with the pick (forged timestamps).
        current = click(h.card.alwaysWriteButton!, number: 4, time: 50, in: h.window)
        clock = 100.05
        XCTAssertFalse(h.card.writeRule(from: h.card.alwaysWriteButton!))

        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertTrue(h.card.alwaysIsOpen, "a refused Write rule keeps the panel")
    }

    func testASyntheticWriteRuleSendsNothingAndIsReportedAsAppControl() throws {
        let appControl: SessionRuleGesture.Permit = { _, _, menu in
            menu ? .human(sourcePid: nil, sourceState: nil) : .refused(reason: .appControl)
        }
        let h = harness(try request(), permit: appControl)
        open(h, time: 10)

        XCTAssertFalse(write(h, number: 2, time: 11))

        XCTAssertEqual(h.recorder.sent, [])
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_always", channel: .appControl)])
    }

    func testASyntheticOpenOpensNothingAndIsReported() throws {
        let h = harness(try request(), permit: { _, _, _ in .refused(reason: .accessibilityPress) })
        XCTAssertFalse(h.card.openAlwaysPanel(control: h.card.sessionButton!))
        XCTAssertFalse(h.card.alwaysIsOpen)
        XCTAssertNil(h.card.listing.alwaysPanel)
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_always", channel: .accessibility)])
        XCTAssertEqual(h.recorder.sent, [])
    }

    func testARefusedPopUpChangePutsThePopUpBackAndChangesNothing() throws {
        var human = true
        let h = harness(try request(), permit: { _, _, _ in
            human ? .human(sourcePid: nil, sourceState: nil) : .refused(reason: .appControl)
        })
        open(h)
        human = false

        XCTAssertFalse(choose(h, h.card.alwaysScopePopup!, index: 1, number: 2, time: 20))

        XCTAssertEqual(h.card.alwaysScopePopup?.titleOfSelectedItem, "This repository (/opt/work/x)", "put back on what the panel shows")
        XCTAssertEqual(h.card.listing.alwaysPanel?[2], "This repository (/opt/work/x)")
        XCTAssertEqual(h.recorder.reports, [ApprovalRecorder.Report(requestID: "req-1", control: "allow_always", channel: .appControl)])
        XCTAssertEqual(h.recorder.sent, [])
    }

    func testWriteRuleIsDisabledUntilTheWholeInputWasShown() throws {
        let long = try ApprovalTestRequests.bash(ApprovalTestRequests.heredoc300Command, commandCount: 14,
                                                 options: Self.options, sessionRuleCandidates: RuleFixtures.candidates,
                                                 repoRoot: Self.root, repoIsGit: true)
        let h = harness(long)
        XCTAssertTrue(open(h))
        XCTAssertFalse(h.card.alwaysWriteButton!.isEnabled, "the input has lines nobody has seen")
        XCTAssertFalse(h.card.canWriteRule)
        XCTAssertFalse(write(h, number: 2, time: 11))
        XCTAssertEqual(h.recorder.sent, [])

        ApprovalTestViews.readThrough(h.card.inputView)
        h.relayout()
        XCTAssertTrue(h.card.alwaysWriteButton!.isEnabled)
    }

    // MARK: Reverting

    func testThePanelClosesWhenTheRequestChanges() throws {
        let h = harness(try request())
        open(h)
        h.store.answer("req-1", ApprovalDecisionWire(kind: .deny), windowID: "w")
        h.sync()
        XCTAssertFalse(h.card.alwaysIsOpen)
        XCTAssertNil(h.card.listing.alwaysPanel)
    }

    func testThePanelClosesWhenTheCardLeavesItsWindow() throws {
        let h = harness(try request())
        open(h)
        h.card.removeFromSuperview()
        XCTAssertFalse(h.card.alwaysIsOpen)
    }

    func testThePanelRevertsAfterTheSessionPicksLifetime() throws {
        let h = harness(try request())
        open(h)
        XCTAssertTrue(h.card.alwaysIsOpen)
        let expiry = expectation(description: "the panel reverts")
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionRuleGesture.selectionLifetime + 0.5) { expiry.fulfill() }
        wait(for: [expiry], timeout: SessionRuleGesture.selectionLifetime + 3)
        XCTAssertFalse(h.card.alwaysIsOpen)
        XCTAssertEqual(h.recorder.sent, [])
    }

    func testChoosingASessionRuleClosesTheAlwaysPanelAndOpeningTheAlwaysPanelDropsASessionPick() throws {
        let h = harness(try request())
        open(h, number: 1, time: 10)
        current = click(h.card.sessionButton!, number: 2, time: 20, in: h.window)
        clock = 110
        XCTAssertTrue(h.card.selectSessionRule(h.card.options.sessionRules[0], control: h.card.sessionButton!))
        XCTAssertFalse(h.card.alwaysIsOpen, "one panel at a time")
        XCTAssertEqual(h.card.selectedCandidate?.id, "c-exact")

        current = click(h.card.sessionButton!, number: 3, time: 30, in: h.window)
        clock = 120
        XCTAssertTrue(h.card.openAlwaysPanel(control: h.card.sessionButton!))
        XCTAssertNil(h.card.selectedCandidate)
        XCTAssertNil(h.card.listing.sessionPanel)
        XCTAssertTrue(h.card.alwaysIsOpen)
    }

    // MARK: Refusals from the daemon

    func testARuleRefusalKeepsThePanelWithItsReasonAndDenyStaysAvailable() throws {
        let cases: [(code: String, reason: String?, text: String)] = [
            ("rule_refused", "That rule is too broad", "Not sent: That rule is too broad"),
            ("rules_quarantined", nil, "Not sent: The rules file changed outside Nostromo. Review it in Approval Rules first."),
            ("rule_limit", nil, "Not sent: There are 200 rules already. Remove one in Approval Rules first."),
            ("rule_write_failed", nil, "Not sent: The rules file could not be written. Nothing was allowed."),
        ]
        for (index, c) in cases.enumerated() {
            clock = 100
            let h = harness(try request(id: "req-\(index)"))
            open(h, time: 10)
            XCTAssertTrue(write(h, number: 2, time: 11), c.code)
            h.store.handle(.answerRefused(try ApprovalTestRequests.refused(id: "req-\(index)", code: c.code, reason: c.reason)))
            h.sync()
            relayout(h)

            XCTAssertTrue(h.card.alwaysIsOpen, "\(c.code): the panel stays, so the reason is read where it was chosen")
            XCTAssertEqual(h.card.listing.alwaysPanel?.last, c.text, c.code)
            XCTAssertTrue(h.card.denyButton.isEnabled, "\(c.code): Deny is never stranded")
            XCTAssertFalse(h.card.alwaysWriteButton!.isEnabled, "\(c.code): the rule is not re-sent")

            h.card.denyButton.performClick(nil)
            XCTAssertEqual(h.recorder.sent.map(\.decision).last, ApprovalDecisionWire(kind: .deny), c.code)
            XCTAssertEqual(h.recorder.sent.count, 2, "\(c.code): the rule once, then the Deny")
        }
    }

    // MARK: Height

    func testThePanelChangesTheCardsHeightOnlyWhenItOpensAndCloses() throws {
        let h = harness(try request())
        let board = NSPasteboard(name: NSPasteboard.Name("nostromo.test.\(UUID().uuidString)"))
        pasteboards.append(board)
        h.card.pasteboard = board
        let width = h.card.frame.width
        let closed = h.card.preferredHeight(forWidth: width, maxHeight: 520)

        open(h, number: 1, time: 10)
        let opened = h.card.preferredHeight(forWidth: width, maxHeight: 520)
        XCTAssertGreaterThan(opened, closed, "the panel has room of its own inside the card")

        choose(h, h.card.alwaysCandidatePopup!, index: 1, number: 2, time: 20)
        XCTAssertEqual(h.card.preferredHeight(forWidth: width, maxHeight: 520), opened, "a pop-up change moves nothing")
        choose(h, h.card.alwaysScopePopup!, index: 1, number: 3, time: 30)
        XCTAssertEqual(h.card.preferredHeight(forWidth: width, maxHeight: 520), opened, "nor does the scope")
        h.card.alwaysCopyButton!.performClick(nil)
        XCTAssertEqual(h.card.preferredHeight(forWidth: width, maxHeight: 520), opened, "nor Copy rule")

        h.card.alwaysCancelButton!.performClick(nil)
        XCTAssertEqual(h.card.preferredHeight(forWidth: width, maxHeight: 520), closed, "closing gives the room back")
    }
}

private extension NSPopUpButton {
    var itemTitles: [String] { itemArray.map(\.title) }
}
