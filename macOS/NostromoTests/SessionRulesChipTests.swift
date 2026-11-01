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

final class SessionRuleGestureTests: XCTestCase {

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

    /// The gate with a person's permit and a handler clock the test moves.
    private func gate(clock: @escaping () -> TimeInterval = { 100 }) -> SessionRuleGesture {
        SessionRuleGesture(permit: anyHuman, uptime: clock)
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

    func testAConfirmAThirdOfASecondLaterInEventTimeIsAllowedEvenIfTheHandlersRanTogether() {
        let gesture = gate(clock: { 100 })   // the handler clock never moved
        XCTAssertEqual(gesture.select(event: rig.mouse(number: 1, time: 10.0), control: rig.button), .allowed)
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

final class SessionRulesStoreAndChipTests: XCTestCase {

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
        XCTAssertEqual(chip.title, "1 session rule")
        XCTAssertFalse(chip.isHidden)
        chip.apply(count: 3)
        XCTAssertEqual(chip.title, "3 session rules")
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

final class SessionRuleCardTests: XCTestCase {

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

    private func harness(_ request: ApprovalRequestWire, permit: SessionRuleGesture.Permit = anyHuman,
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
        let h = harness(try RuleFixtures.request())
        select(h, index: 1, time: 10)
        let confirm = h.card.sessionConfirmButton!
        XCTAssertTrue(confirm.isEnabled)

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

final class SessionRulesSlotTests: XCTestCase {

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
        XCTAssertEqual(bar.sessionRulesChip.title, "1 session rule")
        store.handle(RuleFixtures.frame("cody-1", [RuleFixtures.rule("a"), RuleFixtures.rule("b")]))
        XCTAssertEqual(bar.sessionRulesChip.title, "2 session rules")
        store.handle(RuleFixtures.frame("cody-2", [RuleFixtures.rule("z")]))   // another focus: not this bar's
        XCTAssertEqual(bar.sessionRulesChip.title, "2 session rules")
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
