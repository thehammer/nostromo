import XCTest
import AppKit

// Behavioural spec for `HumanGesture.permit` and for the one control that uses
// it today, `DecisionSheet`.
//
// Contract. A control that answers an agent (a decision's choices, its Dismiss
// and Esc) acts only on a human gesture. An agent can drive the app-control
// socket (`nostromo-app click/key/type`), which synthesises events inside this
// process, and can press a button through Accessibility; neither may answer for
// the person. `permit` is handed the event behind the control's action and says
// `.human` (with the event's source pid and state id, recorded for the OS-level
// question of events posted by another process) or `.refused(reason)`.
//
// Harness notes.
// - Real-typed events are `NSEvent.mouseEvent` / `keyEvent` with the window's
//   number: their `window` resolves, and they carry no marker.
// - A marked event is the same event pushed through a `CGEvent` with
//   `.eventSourceUserData` stamped, then `NSEvent(cgEvent:)`: this is how
//   app-control builds what it posts. Round-tripping a real-typed event (rather
//   than building a `CGEvent` from scratch) is deliberate: `NSEvent(cgEvent:)`
//   of a scratch `CGEvent` has window number 0 and a global location, whereas
//   the round trip keeps the window, location, characters and key code.
// - Windows are borderless, parked far off every screen, and ordered front so
//   they have a window number.

// MARK: - Shared fixtures (internal: SyntheticInputGateTests uses them too)

enum GestureFixtures {

    /// A window with a window number, parked outside every screen.
    static func offscreenWindow(size: NSSize = NSSize(width: 400, height: 240)) -> NSWindow {
        _ = NSApplication.shared
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return w
    }

    /// A button in `window`, like the controls that answer an agent.
    static func control(in window: NSWindow) -> NSButton {
        let b = NSButton(title: "Answer", target: nil, action: nil)
        b.frame = NSRect(x: 20, y: 20, width: 120, height: 32)
        window.contentView!.addSubview(b)
        return b
    }

    /// `timestamp` is on `NSEvent.timestamp`'s clock (seconds since boot);
    /// the default is now, so the event is fresh.
    static func mouse(_ type: NSEvent.EventType, in window: NSWindow,
                      at point: NSPoint = NSPoint(x: 30, y: 30),
                      timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: timestamp,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 4242, clickCount: 1, pressure: 1)!
    }

    /// Esc by default.
    static func key(_ type: NSEvent.EventType = .keyDown, in window: NSWindow,
                    characters: String = "\u{1b}", keyCode: UInt16 = 53,
                    timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                         timestamp: timestamp,
                         windowNumber: window.windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    static func other(in window: NSWindow) -> NSEvent {
        NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           subtype: 0, data1: 0, data2: 0)!
    }

    /// `event` pushed through a `CGEvent` whose source fields are set: the
    /// shape of an event built by app-control (`userData` = the marker) or of
    /// a hardware event (`userData` 0). Window, location and key data survive.
    static func throughCGEvent(_ event: NSEvent, userData: Int64, pid: Int64? = nil,
                               state: Int64? = nil) throws -> NSEvent {
        let cg = try XCTUnwrap(event.cgEvent, "NSEvent has no CGEvent to stamp")
        cg.setIntegerValueField(.eventSourceUserData, value: userData)
        if let pid { cg.setIntegerValueField(.eventSourceUnixProcessID, value: pid) }
        if let state { cg.setIntegerValueField(.eventSourceStateID, value: state) }
        return try XCTUnwrap(NSEvent(cgEvent: cg), "NSEvent(cgEvent:) returned nil")
    }

    /// An event stamped the way app-control stamps what it synthesises.
    static func marked(_ event: NSEvent) throws -> NSEvent {
        try throughCGEvent(event, userData: SyntheticInputGate.marker)
    }
}

// MARK: - HumanGesture.permit

final class HumanGestureTests: XCTestCase {

    private func makeWindowAndControl() -> (NSWindow, NSButton) {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        return (window, GestureFixtures.control(in: window))
    }

    private func verdict(_ event: NSEvent?, _ control: NSView, voiceOver: Bool = false,
                         allowsSynthetic: Bool = false) -> HumanGestureVerdict {
        HumanGesture.permit(event, control: control,
                            voiceOverEnabled: { voiceOver }, allowsSynthetic: { allowsSynthetic })
    }

    // MARK: Harness sanity

    func testTestWindowsHaveANumberAndEventsResolveToThem() throws {
        let (window, _) = makeWindowAndControl()
        XCTAssertGreaterThan(window.windowNumber, 0)
        XCTAssertTrue(GestureFixtures.mouse(.leftMouseUp, in: window).window === window)
        XCTAssertTrue(GestureFixtures.key(in: window).window === window)
        XCTAssertTrue(try GestureFixtures.throughCGEvent(GestureFixtures.mouse(.leftMouseUp, in: window),
                                                         userData: 0).window === window)
    }

    // MARK: Events from app-control

    func testRefusesAnEventStampedWithTheAppControlMarkerAsAppControl() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        XCTAssertEqual(verdict(event, control), .refused(reason: .appControl))
    }

    func testRefusesAMarkedKeyDownAsAppControl() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.marked(GestureFixtures.key(in: window))
        XCTAssertEqual(verdict(event, control), .refused(reason: .appControl))
    }

    func testAcceptsAMarkedEventWhenTheBuildAllowsSyntheticInput() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.throughCGEvent(GestureFixtures.mouse(.leftMouseUp, in: window),
                                                       userData: SyntheticInputGate.marker, pid: 4321, state: 9)
        XCTAssertEqual(verdict(event, control, allowsSynthetic: true),
                       .human(sourcePid: 4321, sourceState: 9))
    }

    func testRefusesAPlainRealTypedEventWhileAnAppControlRequestIsRunning() throws {
        let (window, control) = makeWindowAndControl()
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        XCTAssertEqual(verdict(event, control), .refused(reason: .appControl))
    }

    func testRefusesAnAccessibilityPressWhileAnAppControlRequestIsRunningAsAppControl() {
        let (_, control) = makeWindowAndControl()
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        XCTAssertEqual(verdict(nil, control, voiceOver: true), .refused(reason: .appControl))
    }

    func testAppControlOutranksTheWrongWindowCheck() throws {
        let (_, control) = makeWindowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: other))
        XCTAssertEqual(verdict(event, control), .refused(reason: .appControl))
    }

    func testAppControlRequestEndedSoARealGestureIsAcceptedAgain() {
        let (window, control) = makeWindowAndControl()
        SyntheticInputGate.begin()
        SyntheticInputGate.end()
        XCTAssertEqual(verdict(GestureFixtures.mouse(.leftMouseUp, in: window), control).isHuman, true)
    }

    // MARK: No event (Accessibility press)

    func testRefusesActionWithNoEventWhenVoiceOverIsOffAsAnAccessibilityPress() {
        let (_, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(nil, control, voiceOver: false), .refused(reason: .accessibilityPress))
    }

    func testAcceptsActionWithNoEventWhenVoiceOverIsOn() {
        let (_, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(nil, control, voiceOver: true), .human(sourcePid: nil, sourceState: nil))
    }

    // MARK: Real gestures

    func testAcceptsARealMouseUpInTheControlsWindow() {
        let (window, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(GestureFixtures.mouse(.leftMouseUp, in: window), control).isHuman, true)
    }

    func testAcceptsARealMouseDownInTheControlsWindow() {
        let (window, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(GestureFixtures.mouse(.leftMouseDown, in: window), control).isHuman, true)
    }

    func testAcceptsARealKeyDownInTheControlsWindow() {
        let (window, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(GestureFixtures.key(.keyDown, in: window), control).isHuman, true)
    }

    func testAcceptsAnEventWithoutTheMarkerAndRecordsItsSourcePidAndState() throws {
        let (window, control) = makeWindowAndControl()
        // userData 0 is what a hardware event carries.
        let event = try GestureFixtures.throughCGEvent(GestureFixtures.mouse(.leftMouseUp, in: window),
                                                       userData: 0, pid: 777, state: 5)
        XCTAssertEqual(verdict(event, control), .human(sourcePid: 777, sourceState: 5))
    }

    func testRecordsTheSourcePidAndStateOfAKeyDownToo() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.throughCGEvent(GestureFixtures.key(in: window),
                                                       userData: 0, pid: 778, state: 6)
        XCTAssertEqual(verdict(event, control), .human(sourcePid: 778, sourceState: 6))
    }

    // MARK: Not a user event

    func testRefusesAMouseUpDeliveredToAnotherWindow() {
        let (_, control) = makeWindowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        XCTAssertEqual(verdict(GestureFixtures.mouse(.leftMouseUp, in: other), control),
                       .refused(reason: .notAUserEvent))
    }

    func testRefusesAKeyDownDeliveredToAnotherWindow() {
        let (_, control) = makeWindowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        XCTAssertEqual(verdict(GestureFixtures.key(in: other), control), .refused(reason: .notAUserEvent))
    }

    func testRefusesEventTypesThatAreNotAClickOrAKeyPress() {
        let (window, control) = makeWindowAndControl()
        let events: [(String, NSEvent)] = [
            ("mouseMoved", GestureFixtures.mouse(.mouseMoved, in: window)),
            ("leftMouseDragged", GestureFixtures.mouse(.leftMouseDragged, in: window)),
            ("rightMouseUp", GestureFixtures.mouse(.rightMouseUp, in: window)),
            ("rightMouseDown", GestureFixtures.mouse(.rightMouseDown, in: window)),
            ("keyUp", GestureFixtures.key(.keyUp, in: window)),
            ("applicationDefined", GestureFixtures.other(in: window)),
        ]
        for (name, event) in events {
            XCTAssertEqual(verdict(event, control), .refused(reason: .notAUserEvent), "\(name) must not answer")
        }
    }

    // MARK: Stale events
    //
    // AppKit leaves `NSApp.currentEvent` set to the last event it dispatched,
    // so an event-less action (an Accessibility press from another process)
    // can run while an old human click is still "current". An event older
    // than `HumanGesture.maxEventAge` is not the gesture behind the action.
    // `now` = 100 and whole/half-second timestamps keep the float math exact.

    private let clock: TimeInterval = 100

    private func verdict(_ event: NSEvent?, _ control: NSView, at now: TimeInterval,
                         voiceOver: Bool = false) -> HumanGestureVerdict {
        HumanGesture.permit(event, control: control, voiceOverEnabled: { voiceOver },
                            allowsSynthetic: { false }, now: { now })
    }

    func testTheMaximumEventAgeIsOneSecond() {
        XCTAssertEqual(HumanGesture.maxEventAge, 1.0)
    }

    func testRefusesAMouseUpOneAndAHalfSecondsOldAsStale() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - 1.5)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .staleEvent))
    }

    func testRefusesAKeyDownOneAndAHalfSecondsOldAsStale() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.key(.keyDown, in: window, timestamp: clock - 1.5)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .staleEvent))
    }

    func testRefusesAStaleMouseDownAsStale() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.mouse(.leftMouseDown, in: window, timestamp: clock - 30)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .staleEvent))
    }

    func testAcceptsAMouseUpAFifthOfASecondOld() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - 0.2)
        XCTAssertEqual(verdict(event, control, at: clock).isHuman, true)
    }

    func testAcceptsAKeyDownAFifthOfASecondOld() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.key(.keyDown, in: window, timestamp: clock - 0.2)
        XCTAssertEqual(verdict(event, control, at: clock).isHuman, true)
    }

    func testAcceptsAMouseUpExactlyTheMaximumAgeOld() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - HumanGesture.maxEventAge)
        XCTAssertEqual(event.timestamp, 99, "harness: the timestamp must survive NSEvent exactly")
        XCTAssertEqual(verdict(event, control, at: clock).isHuman, true)
    }

    func testAcceptsAKeyDownExactlyTheMaximumAgeOld() {
        let (window, control) = makeWindowAndControl()
        let event = GestureFixtures.key(.keyDown, in: window, timestamp: clock - HumanGesture.maxEventAge)
        XCTAssertEqual(verdict(event, control, at: clock).isHuman, true)
    }

    func testAStaleHardwareStyleEventIsRefusedEvenThoughItCarriesNoMarker() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.throughCGEvent(
            GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - 1.5), userData: 0, pid: 1, state: 1)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .staleEvent))
    }

    func testTheDefaultClockIsTheEventClockSoARealStaleEventIsRefused() {
        let (window, control) = makeWindowAndControl()
        // No `now` injected: the production clock must be NSEvent.timestamp's.
        let event = GestureFixtures.mouse(.leftMouseUp, in: window,
                                          timestamp: ProcessInfo.processInfo.systemUptime - 5)
        XCTAssertEqual(verdict(event, control), .refused(reason: .staleEvent))
    }

    func testTheDefaultClockAcceptsAFreshEvent() {
        let (window, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(GestureFixtures.mouse(.leftMouseUp, in: window), control).isHuman, true)
    }

    // Order: the earlier refusals still name the real cause when the event is also stale.

    func testAStaleMarkedEventIsRefusedAsAppControl() throws {
        let (window, control) = makeWindowAndControl()
        let event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - 5))
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .appControl))
    }

    func testAStaleEventDuringAnAppControlRequestIsRefusedAsAppControl() {
        let (window, control) = makeWindowAndControl()
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: clock - 5)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .appControl))
    }

    func testAStaleEventInAnotherWindowIsRefusedAsNotAUserEvent() {
        let (_, control) = makeWindowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: other, timestamp: clock - 5)
        XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .notAUserEvent))
    }

    func testAStaleEventOfTheWrongTypeIsRefusedAsNotAUserEvent() {
        let (window, control) = makeWindowAndControl()
        let events: [(String, NSEvent)] = [
            ("mouseMoved", GestureFixtures.mouse(.mouseMoved, in: window, timestamp: clock - 5)),
            ("keyUp", GestureFixtures.key(.keyUp, in: window, timestamp: clock - 5)),
        ]
        for (name, event) in events {
            XCTAssertEqual(verdict(event, control, at: clock), .refused(reason: .notAUserEvent), name)
        }
    }

    func testNoEventIsJudgedByVoiceOverWhateverTheClockSays() {
        let (_, control) = makeWindowAndControl()
        XCTAssertEqual(verdict(nil, control, at: clock, voiceOver: false), .refused(reason: .accessibilityPress))
        XCTAssertEqual(verdict(nil, control, at: clock, voiceOver: true), .human(sourcePid: nil, sourceState: nil))
    }
}

private extension HumanGestureVerdict {
    var isHuman: Bool {
        if case .human = self { return true }
        return false
    }
}

// MARK: - DecisionSheet

// The sheet's choice buttons and its Dismiss (the Esc key equivalent routes to
// the same action) answer an agent's question, so they take only a human
// gesture. A refused attempt does nothing at all: the sheet stays armed, the
// store is not claimed, `onAnswer` is not called, and a real gesture still
// answers afterwards.
//
// The sheet's own window is used as the event's window (never presented on a
// parent, never shown on screen). `currentEvent` stands in for
// `NSApp.currentEvent`, the event behind the button's action.

final class DecisionSheetHumanGestureTests: XCTestCase {

    private let requestId = "req-ap1"
    private var store: DecisionStore!
    private var answers: [String?] = []
    private var sheet: DecisionSheet!
    private var window: NSWindow!

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT"] != nil,
                      "NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT is set in this environment; unset it to run these tests")
        _ = NSApplication.shared
        store = DecisionStore()
        answers = []
        sheet = DecisionSheet(
            requestId: requestId, prompt: "Deploy to production?", detail: nil,
            choices: [.init(id: "approve", label: "Approve", detail: nil),
                      .init(id: "deny", label: "Deny", detail: nil)],
            store: store, resolution: nil,
            onAnswer: { [unowned self] in answers.append($0) })
        sheet.voiceOverEnabled = { false }
        window = try XCTUnwrap(sheet.window)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        addTeardownBlock { [sheet, window] in
            window?.delegate = nil  // closing must not answer on the way out
            sheet?.currentEvent = { nil }
            window?.close()
        }
        XCTAssertGreaterThan(window.windowNumber, 0, "the sheet's window needs a number for events to resolve to it")
    }

    private var buttons: [NSButton] { window.contentView!.subviews.compactMap { $0 as? NSButton } }
    private func choiceButton(_ id: String) throws -> NSButton {
        try XCTUnwrap(buttons.first { $0.identifier?.rawValue == id }, "no choice button \(id)")
    }
    private func dismissButton() throws -> NSButton {
        try XCTUnwrap(buttons.first { $0.title == "Dismiss" && $0.keyEquivalent == "\u{1b}" }, "no Dismiss button")
    }

    private func assertStillArmed(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(answers.count, 0, "onAnswer was called. \(message)", file: file, line: line)
        XCTAssertNil(store.resolution(for: requestId), "the store was claimed. \(message)", file: file, line: line)
        for id in ["approve", "deny"] {
            XCTAssertTrue(try choiceButton(id).isEnabled, "choice \(id) was disabled. \(message)", file: file, line: line)
        }
        XCTAssertTrue(try dismissButton().isEnabled, "Dismiss was disabled. \(message)", file: file, line: line)
    }

    // MARK: Refused

    func testAMarkedMouseUpOnAChoiceDoesNotAnswer() throws {
        let event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed("a click synthesised by app-control must not answer")
    }

    func testAMarkedKeyDownEscOnDismissDoesNotAnswer() throws {
        let event = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: window))
        sheet.currentEvent = { event }
        try dismissButton().performClick(nil)
        try assertStillArmed("an Esc synthesised by app-control must not dismiss")
    }

    func testAChoiceActionWithNoEventAndVoiceOverOffDoesNotAnswer() throws {
        sheet.currentEvent = { nil }
        sheet.voiceOverEnabled = { false }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed("an Accessibility press must not answer")
    }

    func testDismissWithNoEventAndVoiceOverOffDoesNotDismiss() throws {
        sheet.currentEvent = { nil }
        sheet.voiceOverEnabled = { false }
        try dismissButton().performClick(nil)
        try assertStillArmed("an Accessibility press must not dismiss")
    }

    func testAChoicePressedWhileAnAppControlRequestIsRunningDoesNotAnswer() throws {
        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { event }
        try choiceButton("deny").performClick(nil)
        try assertStillArmed("anything that runs inside an app-control request must not answer")
    }

    func testAMouseUpFromAnotherWindowOnAChoiceDoesNotAnswer() throws {
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: other)
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed("an event for a different window is not this sheet's gesture")
    }

    // MARK: Accepted

    func testARealMouseUpOnAChoiceAnswersOnceWithThatChoice() throws {
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { event }
        try choiceButton("deny").performClick(nil)
        XCTAssertEqual(answers, ["deny"])
        XCTAssertEqual(store.resolution(for: requestId), .choice("deny"))
    }

    func testARealEscKeyDownOnDismissDismissesOnce() throws {
        let event = GestureFixtures.key(.keyDown, in: window)
        sheet.currentEvent = { event }
        try dismissButton().performClick(nil)
        XCTAssertEqual(answers.count, 1)
        XCTAssertNil(answers.first ?? "not nil", "Dismiss answers with nil")
        XCTAssertEqual(store.resolution(for: requestId), .dismissed)
    }

    func testAHardwareStyleEventCarryingNoMarkerAnswers() throws {
        let event = try GestureFixtures.throughCGEvent(GestureFixtures.mouse(.leftMouseUp, in: window),
                                                       userData: 0, pid: 1, state: 1)
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        XCTAssertEqual(answers, ["approve"])
    }

    func testAPressWithNoEventAnswersWhenVoiceOverIsOn() throws {
        sheet.currentEvent = { nil }
        sheet.voiceOverEnabled = { true }
        try choiceButton("approve").performClick(nil)
        XCTAssertEqual(answers, ["approve"])
    }

    // MARK: A refusal leaves the sheet armed

    func testARealClickStillAnswersAfterARefusedAttempt() throws {
        let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        sheet.currentEvent = { marked }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed()

        let real = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { real }
        try choiceButton("approve").performClick(nil)
        XCTAssertEqual(answers, ["approve"], "the sheet must still answer a human after refusing an agent")
        XCTAssertEqual(store.resolution(for: requestId), .choice("approve"))
    }

    func testARealEscStillDismissesAfterARefusedSyntheticEsc() throws {
        let marked = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: window))
        sheet.currentEvent = { marked }
        try dismissButton().performClick(nil)
        try assertStillArmed()

        let real = GestureFixtures.key(.keyDown, in: window)
        sheet.currentEvent = { real }
        try dismissButton().performClick(nil)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(store.resolution(for: requestId), .dismissed)
    }

    func testAnAnsweredSheetIgnoresASecondRealClick() throws {
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        try choiceButton("deny").performClick(nil)
        XCTAssertEqual(answers, ["approve"])
    }

    // MARK: A stale event does not answer

    func testAChoiceWhoseCurrentEventIsAStaleRealMouseUpDoesNotAnswer() throws {
        sheet.now = { 100 }
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: 98.5)
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed("a left-over click from 1.5 s ago is not the gesture behind this press")
    }

    func testDismissWhoseCurrentEventIsAStaleEscDoesNotDismiss() throws {
        sheet.now = { 100 }
        let event = GestureFixtures.key(.keyDown, in: window, timestamp: 98.5)
        sheet.currentEvent = { event }
        try dismissButton().performClick(nil)
        try assertStillArmed("a left-over Esc from 1.5 s ago is not the gesture behind this dismissal")
    }

    func testAChoiceWithAStaleEventIsRefusedOnTheRealClockToo() throws {
        // `now` left at its default: the sheet's clock must be NSEvent.timestamp's.
        let event = GestureFixtures.mouse(.leftMouseUp, in: window,
                                          timestamp: ProcessInfo.processInfo.systemUptime - 5)
        sheet.currentEvent = { event }
        try choiceButton("approve").performClick(nil)
        try assertStillArmed("a 5 s old click must not answer")
    }

    func testAFreshClickStillAnswersAfterAStaleOneWasRefused() throws {
        sheet.now = { 100 }
        let stale = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: 98.5)
        sheet.currentEvent = { stale }
        try choiceButton("deny").performClick(nil)
        try assertStillArmed()

        let fresh = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: 99.8)
        sheet.currentEvent = { fresh }
        try choiceButton("deny").performClick(nil)
        XCTAssertEqual(answers, ["deny"])
        XCTAssertEqual(store.resolution(for: requestId), .choice("deny"))
    }

    // MARK: The close box and ⌘W
    //
    // Closing the window dismisses the decision, so it too takes a human
    // gesture: a refused close keeps the sheet up and answers nothing.

    private func willClose() {
        sheet.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    func testAMarkedCloseIsRefusedAndDoesNotAnswer() throws {
        let event = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: window))
        sheet.currentEvent = { event }
        XCTAssertFalse(sheet.windowShouldClose(window), "a close synthesised by app-control must be refused")
        try assertStillArmed()
    }

    func testACloseDuringAnAppControlRequestIsRefusedAndDoesNotAnswer() throws {
        SyntheticInputGate.begin()
        let event = GestureFixtures.key(.keyDown, in: window)
        sheet.currentEvent = { event }
        let allowed = sheet.windowShouldClose(window)
        SyntheticInputGate.end()
        XCTAssertFalse(allowed, "a close inside an app-control request must be refused")
        try assertStillArmed()
    }

    func testACloseWithNoEventAndVoiceOverOffIsRefused() throws {
        sheet.currentEvent = { nil }
        sheet.voiceOverEnabled = { false }
        XCTAssertFalse(sheet.windowShouldClose(window), "an Accessibility close from another process must be refused")
        try assertStillArmed()
    }

    func testACloseWhoseCurrentEventIsStaleIsRefused() throws {
        sheet.now = { 100 }
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: 98.5)
        sheet.currentEvent = { event }
        XCTAssertFalse(sheet.windowShouldClose(window), "a left-over click must not close the sheet")
        try assertStillArmed()
    }

    func testAFreshHumanCloseIsAllowedAndThenDismissesExactlyOnce() throws {
        let event = GestureFixtures.key(.keyDown, in: window)
        sheet.currentEvent = { event }
        XCTAssertTrue(sheet.windowShouldClose(window), "a real Esc in the sheet's window may close it")
        try assertStillArmed("asking whether to close must not itself answer")

        willClose()
        willClose()  // AppKit may deliver the close notification again
        XCTAssertEqual(answers.count, 1, "the close must dismiss exactly once: \(answers)")
        XCTAssertNil(answers.first ?? "not nil", "a close answers with nil")
        XCTAssertEqual(store.resolution(for: requestId), .dismissed)
    }

    func testAnAnsweredSheetMayCloseWithoutASecondAnswer() throws {
        let click = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { click }
        try choiceButton("approve").performClick(nil)
        XCTAssertEqual(answers, ["approve"])

        sheet.currentEvent = { nil }  // whatever closes it now, it's done
        XCTAssertTrue(sheet.windowShouldClose(window), "a resolved sheet must be free to close")
        willClose()
        XCTAssertEqual(answers, ["approve"], "closing an answered sheet must not answer again")
        XCTAssertEqual(store.resolution(for: requestId), .choice("approve"))
    }

    func testASheetClosedWithoutAnsweringMayCloseAndNeverAnswers() throws {
        sheet.closeWithoutAnswering(reason: .supersededElsewhere)
        sheet.currentEvent = { nil }
        XCTAssertTrue(sheet.windowShouldClose(window))
        willClose()
        XCTAssertEqual(answers.count, 0)
    }

    func testASheetBuiltForAnAlreadyResolvedRequestMayCloseAndNeverAnswers() throws {
        let resolvedStore = DecisionStore()
        _ = resolvedStore.claimAnswer(requestId: "req-done", record: .dismissed)
        var late: [String?] = []
        let inert = DecisionSheet(
            requestId: "req-done", prompt: "Deploy?", detail: nil,
            choices: [.init(id: "approve", label: "Approve", detail: nil)],
            store: resolvedStore, resolution: .dismissed, onAnswer: { late.append($0) })
        inert.currentEvent = { nil }
        inert.voiceOverEnabled = { false }
        let inertWindow = try XCTUnwrap(inert.window)
        addTeardownBlock { inertWindow.delegate = nil; inertWindow.close() }

        XCTAssertTrue(inert.windowShouldClose(inertWindow))
        inert.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: inertWindow))
        XCTAssertEqual(late.count, 0, "an inert sheet must never answer")
    }

    // The same, through AppKit's own close path (`performClose` asks
    // `windowShouldClose`, then closes, which sends `windowWillClose`).

    func testPerformCloseWithAMarkedEventLeavesTheDecisionUnanswered() throws {
        let event = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        sheet.currentEvent = { event }
        window.performClose(nil)
        try assertStillArmed("a synthesised close-box click must not dismiss")
    }

    func testPerformCloseWithAFreshHumanClickDismissesOnce() throws {
        let event = GestureFixtures.mouse(.leftMouseUp, in: window)
        sheet.currentEvent = { event }
        window.performClose(nil)
        XCTAssertEqual(answers.count, 1, "\(answers)")
        XCTAssertEqual(store.resolution(for: requestId), .dismissed)
    }
}
