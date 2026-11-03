import XCTest
import AppKit
import NostromoKit

// MotherQuotaGateControl, QuotaGateConfirmation, BackgroundGesture, TSGestureSeams (TaskStopTests) and the
// app's sources are compiled into this target directly.
//
// Mother's quota gate on the Mac: a three-option control, On · Off until reset · Off, that asks Mother to
// change a switch which lets work through whatever the quota. The control is human-only and follows the
// Background Stop pattern (`TaskStopButton`), so these tests mirror `TaskStopTests`:
//
//   - ON is one permitted gesture.
//   - Either OFF is two: the first click arms (and sends nothing), a second, distinct, deliberate click on
//     the same option within a few seconds confirms and sends exactly once.
//   - "Distinct and deliberate" means: not the same event, not a key repeat, not the second click of a
//     double-click, at least 0.3 s after the arm on the event clock AND on the handler clock, and aimed at
//     the button. A refused confirm changes nothing: the arm and its timer carry on.
//   - Arming ends by itself (the injected schedule), when the window loses key, when the armed button loses
//     focus, and when the broker's gate becomes the armed one. It never sends.
//   - Every click and key press runs the human-gesture check first; a refusal does nothing.
//   - The control only shows what `update` gives it: disabled while a command is in flight and while the
//     gate's state is unknown; the already-current option does nothing.
//
// No wall clock, no broker: the permit is scripted (or the real `HumanGesture.permit` over real events), the
// event clock and the handler clock are set by hand, and every timer is a list the test fires.
// The harness types below are internal: `MotherQuotaStripTests` reuses them.

// MARK: - Harness

let qgHuman: HumanGestureVerdict = .human(sourcePid: nil, sourceState: nil)
let qgRefused: HumanGestureVerdict = .refused(reason: .notAUserEvent)

/// A scheduler held by hand: what is asked for waits until the test fires it.
final class QGSchedule {
    private var items: [(delay: TimeInterval, work: () -> Void)] = []

    var delays: [TimeInterval] { items.map { $0.delay } }
    var count: Int { items.count }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        items.append((delay, work))
    }

    /// Run (and drop) the oldest item.
    func fireFirst() {
        guard !items.isEmpty else { return }
        items.removeFirst().work()
    }

    func fireAll() {
        let due = items.map { $0.work }
        items = []
        for work in due { work() }
    }
}

private var qgEventNumber = 70_000

/// One gate control in a real (offscreen) window, wired to a scripted (or the real) human-gesture check.
///
/// Times are set by hand. A press `at: t` is stamped `t` seconds into the test on the event clock and, unless
/// `handlerAt:` says otherwise, `t` seconds into the test on the handler clock (`BackgroundGesture.now`).
final class QGHarness {
    let window: NSWindow
    let clock: TSGestureClock
    let schedule = QGSchedule()
    /// What the scripted permit says.
    var verdict: HumanGestureVerdict = qgHuman
    /// With VoiceOver on, an event-less press is a human one (real-permit harnesses only).
    var voiceOver = false
    /// The event behind the action being handled (`BackgroundGesture.currentEvent`).
    var event: NSEvent?
    private(set) var sent: [MotherQuotaGateRequest] = []
    private(set) var confirmations: [QuotaGateConfirmation] = []
    private(set) var armedChanges: [MotherQuotaGateRequest?] = []
    private(set) var permitCalls = 0
    private(set) var control: MotherQuotaGateControl!

    private let eventBase: TimeInterval
    private static let handlerBase: TimeInterval = 1_000

    /// - Parameters:
    ///   - real: ask the real `HumanGesture.permit` (events stamped just before now, as AppKit's are) instead of
    ///     the scripted verdict.
    ///   - hostControl: put the control in the window; false when a strip will adopt it.
    init(_ testCase: XCTestCase, real: Bool = false, hostControl: Bool = true) {
        let window = GestureFixtures.offscreenWindow()
        let clock = TSGestureSeams.install(on: testCase)
        self.window = window
        self.clock = clock
        self.eventBase = real ? ProcessInfo.processInfo.systemUptime - 0.7 : 50_000
        clock.step = 0   // the handler clock moves only when a test says so
        clock.now = Self.handlerBase
        BackgroundGesture.currentEvent = { [weak self] in self?.event }
        testCase.addTeardownBlock { window.close() }

        control = MotherQuotaGateControl(
            permit: { [unowned self] view in
                self.permitCalls += 1
                guard real else { return self.verdict }
                return HumanGesture.permit(self.event, control: view, voiceOverEnabled: { self.voiceOver },
                                           allowsSynthetic: { false })
            },
            schedule: { [unowned self] delay, work in self.schedule.schedule(delay, work) },
            send: { [unowned self] request, confirmation in
                self.sent.append(request)
                self.confirmations.append(confirmation)
            })
        control.onArmedChange = { [unowned self] armed in self.armedChanges.append(armed) }
        control.update(gate: .on, inFlight: false)
        if hostControl { host(control, at: 20) }
    }

    /// Put `view` at the top left of the window and lay it out.
    func host(_ view: NSView, at inset: CGFloat) {
        let content = window.contentView!
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            view.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
        ])
        content.layoutSubtreeIfNeeded()
    }

    // MARK: State

    func setGate(_ gate: MotherQuotaGate, inFlight: Bool = false) {
        control.update(gate: gate, inFlight: inFlight)
    }

    var armed: MotherQuotaGateRequest? { control.armed }

    func button(_ request: MotherQuotaGateRequest) -> NSButton { control.button(for: request) }

    /// The centre of an option's button, in window coordinates.
    func center(of request: MotherQuotaGateRequest) -> NSPoint {
        let b = button(request)
        return b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
    }

    /// A point in the window that is on none of the options.
    var offButton: NSPoint { NSPoint(x: window.contentView!.bounds.maxX - 4, y: 3) }

    /// Make an option the window's first responder (Space and Return reach it only then).
    func focus(_ request: MotherQuotaGateRequest, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.makeFirstResponder(button(request)), "the option must be able to take focus",
                      file: file, line: line)
    }

    // MARK: Events

    func mouse(at t: TimeInterval, clickCount: Int = 1, location: NSPoint) -> NSEvent {
        qgEventNumber += 1
        return NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                                  timestamp: eventBase + t, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: qgEventNumber, clickCount: clickCount, pressure: 1)!
    }

    func key(at t: TimeInterval, code: UInt16 = 49, isARepeat: Bool = false) -> NSEvent {
        let characters = code == 49 ? " " : (code == 36 || code == 76 ? "\r" : "a")
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: eventBase + t,
                                windowNumber: window.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: isARepeat, keyCode: code)!
    }

    // MARK: Gestures

    /// Run the option's action as AppKit does for a press: with `event` as the current event.
    func fire(_ request: MotherQuotaGateRequest, with event: NSEvent?, handlerAt t: TimeInterval) {
        clock.now = Self.handlerBase + t
        self.event = event
        let b = button(request)
        _ = b.sendAction(b.action, to: b.target)
    }

    /// A click on `request`'s button (or at `location`), `t` seconds in on the event clock.
    func click(_ request: MotherQuotaGateRequest, at t: TimeInterval, handlerAt: TimeInterval? = nil,
               clickCount: Int = 1, location: NSPoint? = nil) {
        let event = mouse(at: t, clickCount: clickCount, location: location ?? center(of: request))
        fire(request, with: event, handlerAt: handlerAt ?? t)
    }

    /// A key press (Space by default) while `request`'s button has the action.
    func press(_ request: MotherQuotaGateRequest, at t: TimeInterval, handlerAt: TimeInterval? = nil,
               code: UInt16 = 49, isARepeat: Bool = false) {
        fire(request, with: key(at: t, code: code, isARepeat: isARepeat), handlerAt: handlerAt ?? t)
    }

    /// An action with no event at all (an Accessibility press).
    func pressWithoutEvent(_ request: MotherQuotaGateRequest, handlerAt t: TimeInterval) {
        fire(request, with: nil, handlerAt: t)
    }

    /// Let queued main-queue work (notification blocks) run.
    func drain() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
    }
}

private let qgOffOptions: [MotherQuotaGateRequest] = [.off, .offUntilReset]
private let qgAllOptions: [MotherQuotaGateRequest] = [.on, .offUntilReset, .off]

// MARK: - Two steps for OFF, one for ON

final class MotherQuotaGateControlTests: MouseQueueTestCase {

    private func harness(real: Bool = false) -> QGHarness { QGHarness(self, real: real) }

    // MARK: Arming

    func testTheFirstClickOnEitherOffOptionArmsAndSendsNothing() {
        let cases: [(request: MotherQuotaGateRequest, from: MotherQuotaGate)] = [
            (.off, .on), (.offUntilReset, .on), (.off, .offUntilReset), (.offUntilReset, .off),
        ]
        for (request, from) in cases {
            let h = harness()
            h.setGate(from)

            h.click(request, at: 0)

            XCTAssertEqual(h.armed, request, "\(request) from \(from): the first click arms")
            XCTAssertTrue(h.sent.isEmpty, "\(request) from \(from): and sends nothing")
            XCTAssertEqual(h.schedule.delays, [MotherQuotaGateControl.confirmInterval], "the arm expires on its own")
            XCTAssertEqual(h.armedChanges, [request], "the strip is told once")
        }
    }

    func testTheArmLastsLongerThanADoubleClickAndNotForever() {
        XCTAssertGreaterThan(MotherQuotaGateControl.confirmInterval, BackgroundGesture.minConfirmDelay)
        XCTAssertLessThanOrEqual(MotherQuotaGateControl.confirmInterval, 10)
    }

    // MARK: Confirming

    func testASecondDistinctClickSendsExactlyTheArmedRequestOnce() {
        for request in qgOffOptions {
            let h = harness()
            h.click(request, at: 0)
            h.click(request, at: 0.5)

            XCTAssertEqual(h.sent, [request], "\(request): one send, the armed request")
            XCTAssertNil(h.armed, "the arm is spent")
            XCTAssertEqual(h.armedChanges, [request, nil])
            XCTAssertEqual(h.confirmations.count, 1)

            // The command is now in flight: nothing more goes until the broker has answered.
            h.click(request, at: 1.2)
            h.click(request, at: 2.0)
            XCTAssertEqual(h.sent, [request], "\(request): a further click while waiting sends nothing")
        }
    }

    func testTheArmsTimerNoLongerCanDisarmAnythingOnceTheRequestWentOut() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.5)
        XCTAssertEqual(h.sent, [.off])

        h.schedule.fireAll()

        XCTAssertEqual(h.sent, [.off], "an old timer sends nothing")
        XCTAssertEqual(h.armedChanges, [.off, nil], "and does not announce a second disarm")
    }

    func testAnAnswerThatLeavesTheGateOffLetsTheNextChangeBeginAfresh() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.5)
        h.setGate(.off, inFlight: false)   // the broker's ack: the gate is off, nothing in flight

        h.click(.offUntilReset, at: 5)
        XCTAssertEqual(h.armed, .offUntilReset, "a new change starts with an arm, not a send")
        XCTAssertEqual(h.sent, [.off])
        h.click(.offUntilReset, at: 5.6)
        XCTAssertEqual(h.sent, [.off, .offUntilReset])
    }

    // MARK: One gesture never arms and confirms

    func testADoubleClickArmsAtMostAndNeverConfirms() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.15, clickCount: 2)   // the OS double-click interval

        XCTAssertEqual(h.armed, .off, "the second click of a double-click leaves it armed")
        XCTAssertTrue(h.sent.isEmpty, "and sends nothing")
        XCTAssertEqual(h.schedule.count, 1, "the arm and its timer are untouched")

        h.click(.off, at: 1.0)
        XCTAssertEqual(h.sent, [.off], "a deliberate click later does confirm")
    }

    func testAClickThatIsAlreadyPartOfAMultiClickCannotArm() {
        for count in [2, 3] {
            let h = harness()
            h.click(.off, at: 0, clickCount: count)
            XCTAssertNil(h.armed, "clickCount \(count)")
            XCTAssertEqual(h.schedule.count, 0, "nothing was armed, so no timer")
            XCTAssertTrue(h.sent.isEmpty)
        }
    }

    func testAHeldKeyArmsAtMostAndNeverConfirms() {
        let h = harness()
        h.focus(.off)
        h.press(.off, at: 0)
        XCTAssertEqual(h.armed, .off)

        h.press(.off, at: 0.5, isARepeat: true)   // key repeat starts about half a second in
        h.press(.off, at: 0.53, isARepeat: true)
        h.press(.off, at: 0.56, isARepeat: true)

        XCTAssertEqual(h.armed, .off, "repeats of a held Space do not confirm")
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.schedule.count, 1)

        h.press(.off, at: 1.0)
        XCTAssertEqual(h.sent, [.off], "a fresh key press does")
    }

    func testAKeyRepeatCannotArm() {
        let h = harness()
        h.focus(.off)
        h.press(.off, at: 0, isARepeat: true)
        XCTAssertNil(h.armed)
        XCTAssertEqual(h.schedule.count, 0)
    }

    func testTheSameClickEventTwiceIsOneGesture() {
        let h = harness()
        let event = h.mouse(at: 0, location: h.center(of: .off))
        h.fire(.off, with: event, handlerAt: 0)
        h.fire(.off, with: event, handlerAt: 1)   // plenty of handler time: only the event's identity is in question

        XCTAssertEqual(h.armed, .off)
        XCTAssertTrue(h.sent.isEmpty)

        h.click(.off, at: 0.5)
        XCTAssertEqual(h.sent, [.off], "a different event does confirm")
    }

    func testTheSameKeyEventTwiceIsOneGesture() {
        let h = harness()
        h.focus(.off)
        let event = h.key(at: 0)
        h.fire(.off, with: event, handlerAt: 0)
        h.fire(.off, with: event, handlerAt: 1)

        XCTAssertEqual(h.armed, .off)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testAConfirmTooSoonOnTheEventClockIsRefusedEvenIfTheHandlerClockSaysLater() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.1, handlerAt: 0.6)   // events 0.1 s apart; the handler ran 0.6 s later

        XCTAssertTrue(h.sent.isEmpty, "a forged or bunched timestamp cannot stretch the gap")
        XCTAssertEqual(h.armed, .off)
        XCTAssertEqual(h.schedule.count, 1)
    }

    func testAConfirmTooSoonOnTheHandlerClockIsRefusedEvenIfTheEventClockSaysLater() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.6, handlerAt: 0.1)   // events 0.6 s apart; the handler ran 0.1 s later

        XCTAssertTrue(h.sent.isEmpty, "the smaller of the two gaps decides")
        XCTAssertEqual(h.armed, .off)
        XCTAssertEqual(h.schedule.count, 1)
    }

    func testAConfirmStampedBeforeTheArmIsRefused() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: -0.5, handlerAt: 1.0)

        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armed, .off)
    }

    func testAConfirmAtOneTenthOfASecondIsRefusedAndAtFourTenthsAccepted() {
        let h = harness()
        h.click(.off, at: 0)

        h.click(.off, at: 0.1)
        XCTAssertTrue(h.sent.isEmpty, "0.1 s after the arm is the same gesture")
        XCTAssertEqual(h.armed, .off)

        h.click(.off, at: 0.4)
        XCTAssertEqual(h.sent, [.off], "0.4 s on both clocks is deliberate")
    }

    func testARefusedConfirmLeavesTheArmAndItsTimerAsTheyWere() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.1)   // refused: too soon
        XCTAssertEqual(h.schedule.delays, [MotherQuotaGateControl.confirmInterval], "no second timer, none dropped")
        XCTAssertEqual(h.armedChanges, [.off], "the strip is not told of a change that did not happen")

        h.schedule.fireAll()

        XCTAssertNil(h.armed, "the original timer still ends the arm")
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: Aim

    func testAClickOutsideTheButtonNeitherArmsNorConfirms() {
        let h = harness()
        h.click(.off, at: 0, location: h.offButton)
        XCTAssertNil(h.armed, "a human click elsewhere in the window is not a click on Off")
        XCTAssertEqual(h.schedule.count, 0)

        h.click(.off, at: 1)   // properly aimed: arms
        XCTAssertEqual(h.armed, .off)

        h.click(.off, at: 2, location: h.offButton)
        XCTAssertTrue(h.sent.isEmpty, "a click elsewhere does not confirm")
        XCTAssertEqual(h.armed, .off, "and leaves the arm")
        XCTAssertEqual(h.schedule.count, 1, "and its timer")

        h.click(.off, at: 3)
        XCTAssertEqual(h.sent, [.off])
    }

    func testAClickOnAnotherOptionsButtonDoesNotCountForThisOne() {
        let h = harness()
        h.click(.off, at: 0, location: h.center(of: .on))
        XCTAssertNil(h.armed, "the event landed on On, not on Off")

        h.click(.off, at: 1)
        h.click(.off, at: 2, location: h.center(of: .offUntilReset))
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armed, .off)
    }

    func testAnEventThatIsNeitherAClickNorAKeyDoesNothing() throws {
        let h = harness()
        let other = try XCTUnwrap(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 50_000,
            windowNumber: h.window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0))
        h.fire(.off, with: other, handlerAt: 0)
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: The arm ends

    func testArmingExpiresByItselfAndSendsNothing() {
        let h = harness()
        h.click(.off, at: 0)

        h.schedule.fireAll()

        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armedChanges, [.off, nil])

        h.click(.off, at: 10)
        XCTAssertEqual(h.armed, .off, "a click after the expiry is a first click again")
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testAnOldArmsTimerCannotCutANewerArmShort() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.offUntilReset, at: 0.5)   // re-arms: the first timer is now stale
        XCTAssertEqual(h.schedule.count, 2)

        h.schedule.fireFirst()
        XCTAssertEqual(h.armed, .offUntilReset, "the first arm's timer does not end the second arm")

        h.schedule.fireFirst()
        XCTAssertNil(h.armed, "the second arm's own timer does")
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testAnArmThatWasSpentAndAnotherBegunIsNotCutShortByTheFirstsTimer() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.off, at: 0.5)   // sent
        h.setGate(.off)
        h.click(.offUntilReset, at: 2)
        XCTAssertEqual(h.armed, .offUntilReset)

        h.schedule.fireFirst()   // the timer of the arm that was spent

        XCTAssertEqual(h.armed, .offUntilReset)
    }

    func testTheArmEndsWhenTheWindowLosesKey() {
        let h = harness()
        h.click(.off, at: 0)
        XCTAssertEqual(h.armed, .off)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: h.window)
        h.drain()

        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armedChanges, [.off, nil])
    }

    func testAnotherWindowLosingKeyDoesNotEndTheArm() {
        let h = harness()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        h.click(.off, at: 0)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        h.drain()

        XCTAssertEqual(h.armed, .off)
    }

    func testTheArmEndsWhenTheControlLeavesItsWindow() {
        let h = harness()
        h.click(.off, at: 0)
        h.control.removeFromSuperview()
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testTheArmEndsWhenTheBrokerReportsTheGateTheArmWasFor() {
        for request in qgOffOptions {
            let h = harness()
            h.click(request, at: 0)
            XCTAssertEqual(h.armed, request)

            h.setGate(request.resultingGate)   // someone else (the CLI, a reset) already put it there

            XCTAssertNil(h.armed, "\(request): nothing is left to confirm")
            XCTAssertTrue(h.sent.isEmpty)
            XCTAssertEqual(h.armedChanges, [request, nil])
        }
    }

    func testTheSameGateArrivingAgainDoesNotEndTheArm() {
        let h = harness()
        h.click(.off, at: 0)

        h.setGate(.on)   // an unchanged block, as the broker re-sends them
        h.setGate(.on)

        XCTAssertEqual(h.armed, .off)
        h.click(.off, at: 0.6)
        XCTAssertEqual(h.sent, [.off])
    }

    func testTheArmEndsWhenTheControlBecomesUnavailable() {
        let a = harness()
        a.click(.off, at: 0)
        a.setGate(.on, inFlight: true)
        XCTAssertNil(a.armed, "a command is already on its way")

        let b = harness()
        b.click(.off, at: 0)
        b.setGate(.unknown("future"))
        XCTAssertNil(b.armed, "the state is no longer one this build understands")
    }

    func testTheArmEndsWhenTheArmedButtonLosesKeyboardFocus() {
        let h = harness()
        h.focus(.off)
        h.press(.off, at: 0)
        XCTAssertEqual(h.armed, .off)

        XCTAssertTrue(h.window.makeFirstResponder(nil))

        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: Re-arming

    func testClickingTheOtherOffOptionWhileArmedReArmsAndNeedsItsOwnConfirm() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.offUntilReset, at: 0.5)

        XCTAssertEqual(h.armed, .offUntilReset, "it moves the arm")
        XCTAssertTrue(h.sent.isEmpty, "and confirms neither")
        XCTAssertEqual(h.armedChanges, [.off, .offUntilReset])

        h.click(.offUntilReset, at: 0.6)   // 0.1 s after the re-arm
        XCTAssertTrue(h.sent.isEmpty, "the re-arm's own 0.3 s counts, not the first arm's")

        h.click(.offUntilReset, at: 1.0)
        XCTAssertEqual(h.sent, [.offUntilReset], "and the request is the re-armed one, not the first")
    }

    func testTheFirstOptionsConfirmAfterAReArmOnlyArmsItAgain() {
        let h = harness()
        h.click(.off, at: 0)
        h.click(.offUntilReset, at: 0.5)
        h.click(.off, at: 1.5)   // not the armed option any more

        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armed, .off)
    }

    // MARK: ON

    func testOnIsOneGestureFromEitherOffState() {
        for from in [MotherQuotaGate.off, .offUntilReset] {
            let h = harness()
            h.setGate(from)

            h.click(.on, at: 0)

            XCTAssertEqual(h.sent, [.on], "from \(from)")
            XCTAssertNil(h.armed)
            XCTAssertEqual(h.schedule.count, 0, "ON arms nothing")
        }
    }

    func testOnWithAKeyPressIsOneGestureToo() {
        let h = harness()
        h.setGate(.off)
        h.focus(.on)
        h.press(.on, at: 0)
        XCTAssertEqual(h.sent, [.on])
    }

    func testOnEndsAnArmWithoutSendingTheOff() {
        let h = harness()
        h.setGate(.offUntilReset)
        h.click(.off, at: 0)
        XCTAssertEqual(h.armed, .off)

        h.click(.on, at: 0.5)

        XCTAssertEqual(h.sent, [.on], "only the ON went out")
        XCTAssertNil(h.armed)
        XCTAssertEqual(h.armedChanges, [.off, nil])

        h.schedule.fireAll()
        XCTAssertEqual(h.sent, [.on])
    }

    // MARK: The human-gesture check

    func testARefusedGestureDoesNothingForEveryOption() {
        let gates: [MotherQuotaGate] = [.on, .off, .offUntilReset]
        for gate in gates {
            for request in qgAllOptions where request.resultingGate != gate {
                let h = harness()
                h.setGate(gate)
                h.verdict = qgRefused

                h.click(request, at: 0)
                h.click(request, at: 1)

                XCTAssertNil(h.armed, "\(request) from \(gate)")
                XCTAssertTrue(h.sent.isEmpty, "\(request) from \(gate)")
                XCTAssertEqual(h.schedule.count, 0, "\(request) from \(gate): nothing armed, no timer")
                XCTAssertGreaterThan(h.permitCalls, 0, "the check ran")
            }
        }
    }

    func testARefusedConfirmLeavesTheArmAndItsTimerAndALaterPermittedOneConfirms() {
        let h = harness()
        h.click(.off, at: 0)
        h.verdict = qgRefused
        h.click(.off, at: 1)

        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.armed, .off)
        XCTAssertEqual(h.schedule.count, 1)

        h.verdict = qgHuman
        h.click(.off, at: 1.5)
        XCTAssertEqual(h.sent, [.off])
    }

    func testARefusedKeyPressDoesNothing() {
        let h = harness()
        h.verdict = qgRefused
        h.focus(.off)
        h.press(.off, at: 0)
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    // MARK: Disabled and current

    func testTheControlIsDisabledWhileACommandIsInFlight() {
        let h = harness()
        h.setGate(.on, inFlight: true)

        for request in qgAllOptions {
            XCTAssertFalse(h.button(request).isEnabled, "\(request)")
        }
        for request in qgAllOptions where request != .on {
            h.fire(request, with: h.mouse(at: 0, location: h.center(of: request)), handlerAt: 0)
            h.fire(request, with: h.mouse(at: 1, location: h.center(of: request)), handlerAt: 1)
        }
        h.setGate(.off, inFlight: true)
        h.fire(.on, with: h.mouse(at: 2, location: h.center(of: .on)), handlerAt: 2)

        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty, "not even a press that reaches the action does anything")
        XCTAssertEqual(h.schedule.count, 0)

        h.setGate(.on, inFlight: false)
        for request in qgAllOptions {
            XCTAssertTrue(h.button(request).isEnabled, "\(request) works again once the command is answered")
        }
        h.click(.off, at: 5)
        XCTAssertEqual(h.armed, .off)
    }

    func testTheControlIsDisabledWhenTheGateIsUnknown() {
        let h = harness()
        h.setGate(.unknown("future_state"))

        for request in qgAllOptions {
            XCTAssertFalse(h.button(request).isEnabled, "\(request)")
            h.click(request, at: 0)
            h.click(request, at: 1)
        }

        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
        XCTAssertEqual(h.schedule.count, 0)
        XCTAssertFalse(h.button(.off).acceptsFirstResponder, "a disabled option cannot take keyboard focus")
        // Even a key press that reaches a focused, disabled option does nothing: the control checks `isActive` first.
        h.click(.off, at: 2)
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testClickingTheOptionAlreadyInForceDoesNothing() {
        let cases: [(MotherQuotaGate, MotherQuotaGateRequest)] = [(.on, .on), (.off, .off), (.offUntilReset, .offUntilReset)]
        for (gate, request) in cases {
            let h = harness()
            h.setGate(gate)

            h.click(request, at: 0)
            h.click(request, at: 1)

            XCTAssertNil(h.armed, "\(gate)")
            XCTAssertTrue(h.sent.isEmpty, "\(gate)")
            XCTAssertEqual(h.schedule.count, 0, "\(gate): nothing armed")
        }
    }

    // MARK: Accessibility

    func testEveryOptionHasASpokenLabelAndTheCurrentOneIsMarkedSelected() {
        let h = harness()
        let labels: [MotherQuotaGateRequest: String] = [
            .on: "Turn quota gate on",
            .offUntilReset: "Turn quota gate off until the next reset",
            .off: "Turn quota gate off",
        ]
        for current in [MotherQuotaGate.on, .off, .offUntilReset] {
            h.setGate(current)
            for request in qgAllOptions {
                XCTAssertEqual(h.button(request).accessibilityLabel(), labels[request], "\(request)")
                let selected = request.resultingGate == current
                XCTAssertEqual(h.button(request).accessibilityValue() as? String,
                               selected ? "selected" : "not selected", "\(request) while \(current)")
            }
        }
    }

    func testTheControlIsOneNamedGroup() {
        let h = harness()
        XCTAssertEqual(h.control.accessibilityRole(), .radioGroup)
        XCTAssertEqual(h.control.accessibilityLabel(), "Quota gate")
    }

    func testTheArmedOptionSaysItNeedsConfirmingAndSaysItAgainWhenItIsDisarmed() {
        for request in qgOffOptions {
            let h = harness()
            let plain = h.button(request).accessibilityLabel()
            let plainTitle = h.button(request).attributedTitle.string
            XCTAssertFalse(plainTitle.hasSuffix("?"))

            h.click(request, at: 0)

            let label = h.button(request).accessibilityLabel() ?? ""
            XCTAssertTrue(label.hasPrefix("Confirm"), "\(request): \(label)")
            XCTAssertTrue(label.contains("again"), "it says a second activation is needed: \(label)")
            XCTAssertNotEqual(label, plain)
            XCTAssertTrue(h.button(request).attributedTitle.string.hasSuffix("?"), "the armed option asks")
            for other in qgAllOptions where other != request {
                XCTAssertFalse(h.button(other).attributedTitle.string.hasSuffix("?"), "only the armed one asks")
                XCTAssertFalse((h.button(other).accessibilityLabel() ?? "").hasPrefix("Confirm"))
            }
            if request == .offUntilReset {
                XCTAssertTrue(label.contains("until the next reset"), "it names which off: \(label)")
            }

            h.schedule.fireAll()
            XCTAssertEqual(h.button(request).accessibilityLabel(), plain, "back to normal once the arm ends")
            XCTAssertEqual(h.button(request).attributedTitle.string, plainTitle)
        }
    }

    // MARK: Keyboard

    func testSpaceReturnAndEnterOnTheFocusedButtonFollowTheSameTwoSteps() {
        for code: UInt16 in [49, 36, 76] {
            for request in qgOffOptions {
                let h = harness()
                h.focus(request)

                h.press(request, at: 0, code: code)
                XCTAssertEqual(h.armed, request, "key \(code): the first press arms")
                h.press(request, at: 0.1, code: code)
                XCTAssertTrue(h.sent.isEmpty, "key \(code): 0.1 s later is the same press")
                h.press(request, at: 0.6, code: code)
                XCTAssertEqual(h.sent, [request], "key \(code): a second, deliberate press confirms")
            }
        }
    }

    func testAKeyPressCountsOnlyWhileThatButtonHasKeyboardFocus() {
        let unfocused = harness()
        unfocused.press(.off, at: 0)
        XCTAssertNil(unfocused.armed, "no button has focus")

        let elsewhere = harness()
        elsewhere.focus(.on)
        elsewhere.press(.off, at: 0)
        XCTAssertNil(elsewhere.armed, "another option has focus, not Off")
    }

    func testOtherKeysDoNotActivateAFocusedButton() {
        let h = harness()
        h.focus(.off)
        h.press(.off, at: 0, code: 0)    // "a"
        h.press(.off, at: 1, code: 53)   // Escape
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testAnEnabledOptionTakesKeyboardFocus() {
        let h = harness()
        for request in qgAllOptions {
            XCTAssertTrue(h.window.makeFirstResponder(h.button(request)), "\(request) is keyboard operable")
        }
    }

    // MARK: Without an event (VoiceOver)

    func testAnEventlessPressIsRefusedWithoutVoiceOverAndFollowsTheTwoStepsWithIt() {
        let off = harness(real: true)
        off.pressWithoutEvent(.off, handlerAt: 0)
        XCTAssertNil(off.armed, "an Accessibility press from another process is not a person")

        let on = harness(real: true)
        on.voiceOver = true
        on.pressWithoutEvent(.off, handlerAt: 0)
        XCTAssertEqual(on.armed, .off, "VoiceOver's own press arms")
        on.pressWithoutEvent(.off, handlerAt: 0.1)
        XCTAssertTrue(on.sent.isEmpty, "the handler clock alone must show 0.3 s")
        on.pressWithoutEvent(.off, handlerAt: 0.5)
        XCTAssertEqual(on.sent, [.off])
    }
}

// MARK: - The production gate check is the default

final class MotherQuotaGateDefaultPermitTests: MouseQueueTestCase {

    /// A control built the way the strip builds it (no `permit` given) asks the real human-gesture check, which
    /// refuses a press that arrives without an event of its own (an Accessibility press from another process).
    func testAControlWithTheDefaultCheckRefusesAnEventlessPress() {
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }   // VoiceOver's own press is a person's
        let h = QGHarness(self, hostControl: false)
        var sent = 0
        let control = MotherQuotaGateControl(send: { _, _ in sent += 1 })
        control.update(gate: .on, inFlight: false)
        h.host(control, at: 20)

        for request in qgAllOptions {
            let b = control.button(for: request)
            h.event = nil
            _ = b.sendAction(b.action, to: b.target)
            _ = b.sendAction(b.action, to: b.target)
        }

        XCTAssertNil(control.armed, "the default check does not let an event-less press arm")
        XCTAssertEqual(sent, 0)
    }
}

// MARK: - With the real human-gesture check

final class MotherQuotaGateRealGestureTests: MouseQueueTestCase {

    func testTwoFreshClicksInTheControlsOwnWindowArmAndConfirm() {
        let h = QGHarness(self, real: true)
        h.click(.offUntilReset, at: 0)
        XCTAssertEqual(h.armed, .offUntilReset)
        h.click(.offUntilReset, at: 0.5)
        XCTAssertEqual(h.sent, [.offUntilReset])
    }

    func testOnIsOneFreshClick() {
        let h = QGHarness(self, real: true)
        h.setGate(.off)
        h.click(.on, at: 0.3)
        XCTAssertEqual(h.sent, [.on])
    }

    func testAStaleEventIsRefusedOnTheFirstAndOnTheSecondClick() {
        let h = QGHarness(self, real: true)
        h.click(.off, at: -10)
        XCTAssertNil(h.armed, "a stale event cannot start the two steps")

        h.click(.off, at: 0)
        h.click(.off, at: -10, handlerAt: 1)
        XCTAssertEqual(h.armed, .off, "nor finish them")
        XCTAssertTrue(h.sent.isEmpty)

        h.click(.off, at: 0.5)
        XCTAssertEqual(h.sent, [.off])
    }

    func testAClickForAnotherWindowIsRefused() {
        let h = QGHarness(self, real: true)
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: other)
        h.fire(.off, with: event, handlerAt: 0)
        XCTAssertNil(h.armed)
    }

    func testAnAppControlGestureIsRefusedForEveryOption() {
        for request in qgAllOptions {
            let h = QGHarness(self, real: true)
            h.setGate(request == .on ? .off : .on)
            SyntheticInputGate.begin()   // what app-control does around every request it runs
            defer { SyntheticInputGate.end() }

            h.click(request, at: 0)
            h.click(request, at: 0.5)

            XCTAssertNil(h.armed, "\(request)")
            XCTAssertTrue(h.sent.isEmpty, "\(request)")
        }
    }

    func testAnAppControlKeyPressIsRefused() {
        let h = QGHarness(self, real: true)
        h.focus(.off)
        let stamped = SyntheticInputGate.stamped(h.key(at: 0))
        h.fire(.off, with: stamped, handlerAt: 0)
        XCTAssertNil(h.armed)
        XCTAssertTrue(h.sent.isEmpty)
    }
}

// MARK: - Where the gate can be reached from

/// The compiler enforces the gate: `AppStore.requestQuotaGate` needs a `QuotaGateConfirmation`, whose
/// initializer is `fileprivate` to `MotherQuotaStrip.swift`. This scan is the second line (as
/// `TaskStopGateFitnessTests` is for Stop): the store method is called only from the strip's control, the
/// broker command only from the store, the wire verb only in the broker client, and nothing an agent can
/// drive (app-control, the MCP server and bridge, the daemon's IPC, a URL scheme or AppleScript handler)
/// mentions the quota gate at all. A new route would be a gate change that skipped the gesture.
final class MotherQuotaGateFitnessTests: MouseQueueTestCase {

    private static let repo = URL(fileURLWithPath: #filePath)   // .../macOS/NostromoTests/<this file>
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let strip = "UI/Views/MotherQuotaStrip.swift"
    private static let appStore = "Data/AppStore.swift"
    private static let brokerClient = "Data/MotherBrokerClient.swift"

    /// Source text with whole-line comments dropped.
    private static func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Relative path (from the repo root) -> code, for every file under `path` with one of `extensions`.
    /// `path` may be one file.
    private static func sources(under path: String, extensions: Set<String>) throws -> [String: String] {
        let root = repo.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [:] }
        var urls: [URL] = []
        if isDirectory.boolValue {
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in walker where extensions.contains(url.pathExtension) { urls.append(url) }
        } else {
            urls = [root]
        }
        var all: [String: String] = [:]
        for url in urls {
            all[String(url.path.dropFirst(repo.path.count + 1))] = try code(url)
        }
        return all
    }

    /// The app's Swift sources, keyed by their path below `macOS/Nostromo/`.
    private static func appSources() throws -> [String: String] {
        let prefix = "macOS/Nostromo/"
        let found = try sources(under: "macOS/Nostromo", extensions: ["swift"])
        XCTAssertFalse(found.isEmpty, "the scan found no app sources: has the directory moved?")
        return Dictionary(uniqueKeysWithValues: found.map { (String($0.key.dropFirst(prefix.count)), $0.value) })
    }

    private static func matches(_ pattern: String, in code: String, options: NSRegularExpression.Options = []) -> Int {
        // swiftlint:disable:next force_try
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        return regex.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
    }

    /// Per file, how many times `pattern` matches, for the files where it does.
    private static func hits(_ pattern: String, in sources: [String: String],
                             options: NSRegularExpression.Options = []) -> [String: Int] {
        sources.compactMapValues { code in
            let count = matches(pattern, in: code, options: options)
            return count > 0 ? count : nil
        }
    }

    /// `code` without the definition line(s) of `name`, so the remaining matches are calls and references.
    private static func withoutDefinitions(of name: String, _ sources: [String: String]) -> [String: String] {
        sources.mapValues { $0.replacingOccurrences(of: "func \(name)(", with: "func __definition__(") }
    }

    // MARK: The scan itself

    func testTheScansSeeACallAReferenceAndADefinition() {
        let call = #"requestQuotaGate\("#
        XCTAssertEqual(Self.matches(call, in: "AppStore.shared.requestQuotaGate(request, confirmation: c)"), 1)
        XCTAssertEqual(Self.matches(call, in: "requestQuotaGate(request, confirmation: c)"), 1, "a bare call")
        XCTAssertEqual(Self.matches(#"requestQuotaGate(?!\s*\()"#, in: "let f = store.requestQuotaGate\n"), 1, "a reference")
        XCTAssertEqual(Self.matches(#"requestQuotaGate(?!\s*\()"#, in: "#selector(AppStore.requestQuotaGate)"), 1)
        XCTAssertEqual(Self.matches(#"requestQuotaGate(?!\s*\()"#, in: "store.requestQuotaGate(x)"), 0)
        let stripped = Self.withoutDefinitions(of: "requestQuotaGate",
                                               ["a": "func requestQuotaGate(_ r: R, confirmation: C) {"])
        XCTAssertEqual(Self.matches(call, in: stripped["a"]!), 0, "the definition is not a call")
    }

    // MARK: Who may call what

    func testRequestQuotaGateIsCalledOnlyFromTheGateControlsStrip() throws {
        let sources = Self.withoutDefinitions(of: "requestQuotaGate", try Self.appSources())

        XCTAssertEqual(Set(Self.hits(#"requestQuotaGate\("#, in: sources).keys), [Self.strip],
                       "requestQuotaGate( may be called only from the strip's control closure")
        XCTAssertEqual(Self.hits(#"requestQuotaGate(?!\s*\()"#, in: sources), [:],
                       "a reference to requestQuotaGate (selector, key path, function value) would route around the call scan")
        let definitions = Self.hits(#"func requestQuotaGate\("#, in: try Self.appSources())
        XCTAssertEqual(Set(definitions.keys), [Self.appStore], "defined once, in the store")
    }

    func testSetQuotaGateIsCalledOnlyFromTheStore() throws {
        let sources = Self.withoutDefinitions(of: "setQuotaGate", try Self.appSources())

        XCTAssertEqual(Set(Self.hits(#"setQuotaGate\("#, in: sources).keys), [Self.appStore],
                       "the broker command is sent only through the store's gated request")
        XCTAssertEqual(Self.hits(#"setQuotaGate(?!\s*\()"#, in: sources), [:], "no function reference either")
        XCTAssertEqual(Set(Self.hits(#"func setQuotaGate\("#, in: try Self.appSources()).keys), [Self.brokerClient],
                       "defined once, in the broker client")
    }

    func testTheWireVerbQuotaGateAppearsOnlyInTheBrokerClient() throws {
        // The Mac app, the shared Kit and the iOS app: a literal verb anywhere else is a second way to send it.
        var all = try Self.sources(under: "macOS/Nostromo", extensions: ["swift"])
        all.merge(try Self.sources(under: "Shared/NostromoKit/Sources", extensions: ["swift"])) { a, _ in a }
        all.merge(try Self.sources(under: "iOS", extensions: ["swift"])) { a, _ in a }

        let verb = #""quota-gate""#
        let found = Set(Self.hits(verb, in: all).keys)

        XCTAssertTrue(found.contains("macOS/Nostromo/\(Self.brokerClient)"), "the scan must see the broker client's own verb")
        XCTAssertTrue(found.isSubset(of: ["macOS/Nostromo/\(Self.brokerClient)",
                                          "Shared/NostromoKit/Sources/NostromoKit/Mother/MotherQuota.swift"]),
                      "the wire verb \(verb) appears in: \(found.sorted())")
    }

    func testAQuotaGateConfirmationIsMadeOnlyInsideTheControl() throws {
        let sources = try Self.appSources()

        XCTAssertEqual(Set(Self.hits(#"QuotaGateConfirmation\("#, in: sources).keys), [Self.strip],
                       "only MotherQuotaStrip.swift can (it is fileprivate there)")

        let file = try XCTUnwrap(sources[Self.strip])
        XCTAssertEqual(Self.matches(#"QuotaGateConfirmation\(\)"#, in: file), 1, "one place mints one")
        let mint = try XCTUnwrap(file.range(of: "QuotaGateConfirmation()"))
        let control = try XCTUnwrap(file.range(of: "final class MotherQuotaGateControl"))
        let stripClass = try XCTUnwrap(file.range(of: "final class MotherQuotaStrip"))
        XCTAssertTrue(mint.lowerBound > control.lowerBound && mint.lowerBound < stripClass.lowerBound,
                      "the confirmation is minted inside the gate control, after its gesture steps, not by the strip")
    }

    // MARK: Nothing an agent can drive

    func testNoAgentFacingSurfaceMentionsTheQuotaGate() throws {
        let surfaces: [(path: String, extensions: Set<String>)] = [
            ("macOS/Nostromo/AppControl", ["swift"]),        // the app-control socket (`bin/nostromo-app`)
            ("src/mcp", ["rs"]),                              // the MCP server's tools
            ("src/bin/nostromo_mcp_bridge.rs", ["rs"]),
            ("src/ipc", ["rs"]),                              // the daemon's IPC to the app
            ("bin/nostromo-app", ["", "py", "sh"]),
        ]
        let pattern = #"quota[-_ ]?gate"#
        for surface in surfaces {
            let found = try Self.sources(under: surface.path, extensions: surface.extensions)
            XCTAssertFalse(found.isEmpty, "the scan found no files under \(surface.path): has it moved?")
            XCTAssertEqual(Self.hits(pattern, in: found, options: .caseInsensitive), [:],
                           "\(surface.path) is reachable by an agent and must not mention the quota gate")
        }
    }

    func testNoURLSchemeOrAppleScriptHandlerMentionsTheQuotaGate() throws {
        let handlerMarkers = #"NSScriptCommand|NSAppleScript|NSAppleEventManager|handleGetURL|application\(_[^)]*open urls|CFBundleURLTypes"#
        let swift = try Self.appSources()
        let handlers = swift.filter { Self.matches(handlerMarkers, in: $0.value) > 0 }
        XCTAssertEqual(Self.hits(#"quota[-_ ]?gate"#, in: handlers, options: .caseInsensitive), [:],
                       "a URL-scheme or AppleScript handler must not reach the quota gate")

        // And no scripting definition or Info.plist URL type names it.
        for path in ["macOS/Nostromo/Info.plist"] {
            let url = Self.repo.appendingPathComponent(path)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            XCTAssertEqual(Self.matches(#"quota[-_ ]?gate"#, in: text, options: .caseInsensitive), 0, path)
        }
    }
}
