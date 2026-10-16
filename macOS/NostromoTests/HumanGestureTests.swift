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

    static func mouse(_ type: NSEvent.EventType, in window: NSWindow,
                      at point: NSPoint = NSPoint(x: 30, y: 30)) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 4242, clickCount: 1, pressure: 1)!
    }

    /// Esc by default.
    static func key(_ type: NSEvent.EventType = .keyDown, in window: NSWindow,
                    characters: String = "\u{1b}", keyCode: UInt16 = 53) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
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
}
