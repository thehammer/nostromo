import XCTest
import AppKit

// `TerminalInputGuard`: the one place terminal code asks "was that a person?". It is a thin wrapper
// over AP1's gate (`SyntheticInputGate`, `HumanGesture`), so these tests pin the answers a terminal
// pane depends on:
//
//   * keystrokes (typing, IME text, paste, the terminal's own replies) are refused when app-control
//     produced them, unless a QA build relaxes the gate;
//   * a control that changes a terminal (close, restart) acts only on a fresh human gesture in its
//     own window, or, when it is a main-menu item, on a human selection of that item.
//
// Events come from `GestureFixtures` (HumanGestureTests.swift): real-typed events resolve to their
// window and carry no marker; a "marked" event is stamped the way app-control stamps what it posts.

final class TerminalInputGuardTests: XCTestCase {

    private func windowAndControl() -> (NSWindow, NSButton) {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        return (window, GestureFixtures.control(in: window))
    }

    private func beginAppControlRequest() {
        SyntheticInputGate.begin()
        addTeardownBlock { SyntheticInputGate.end() }
    }

    private func control(_ event: NSEvent?, _ control: NSView, fromMenu: Bool = false,
                         voiceOver: Bool = false, allowsSynthetic: Bool = false) -> Bool {
        TerminalInputGuard.allowsControl(event: event, control: control, fromMenu: fromMenu,
                                         voiceOverEnabled: { voiceOver },
                                         allowsSynthetic: { allowsSynthetic })
    }

    // MARK: - Keystrokes: the injected seams

    func testASyntheticKeystrokeIsRefused() {
        XCTAssertFalse(TerminalInputGuard.allowsKeystroke(event: nil, isSynthetic: { _ in true },
                                                          allowsSynthetic: { false }))
    }

    func testASyntheticKeystrokeIsAllowedWhenTheBuildRelaxesTheGate() {
        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: nil, isSynthetic: { _ in true },
                                                         allowsSynthetic: { true }))
    }

    func testANonSyntheticKeystrokeIsAllowed() {
        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: nil, isSynthetic: { _ in false },
                                                         allowsSynthetic: { false }))
    }

    func testTheEventIsHandedToTheSyntheticCheck() {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let event = GestureFixtures.key(in: window, characters: "a", keyCode: 0)
        var seen: NSEvent?

        _ = TerminalInputGuard.allowsKeystroke(event: event, isSynthetic: { seen = $0; return false },
                                               allowsSynthetic: { false })

        XCTAssertTrue(seen === event)
    }

    // MARK: - Keystrokes: the real gate

    func testAKeyEventMarkedByAppControlIsRefused() throws {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let marked = try GestureFixtures.marked(GestureFixtures.key(in: window, characters: "a", keyCode: 0))

        XCTAssertFalse(TerminalInputGuard.allowsKeystroke(event: marked, allowsSynthetic: { false }))
    }

    func testAMarkedKeyEventIsAllowedWhenSyntheticInputIsAllowed() throws {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let marked = try GestureFixtures.marked(GestureFixtures.key(in: window, characters: "a", keyCode: 0))

        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: marked, allowsSynthetic: { true }))
    }

    func testARealKeyEventIsAllowed() {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let event = GestureFixtures.key(in: window, characters: "a", keyCode: 0)

        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: event, allowsSynthetic: { false }))
    }

    func testARealKeyEventIsRefusedWhileAnAppControlRequestIsRunning() {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let event = GestureFixtures.key(in: window, characters: "a", keyCode: 0)
        beginAppControlRequest()

        XCTAssertFalse(TerminalInputGuard.allowsKeystroke(event: event, allowsSynthetic: { false }))
    }

    func testTheTerminalsOwnReplyWithNoEventIsAllowedUnlessAppControlIsRunning() {
        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: nil, allowsSynthetic: { false }),
                      "device attributes and focus reports have no event of their own")

        beginAppControlRequest()
        XCTAssertFalse(TerminalInputGuard.allowsKeystroke(event: nil, allowsSynthetic: { false }),
                       "while app-control runs a command, a reply it caused is not a person's")
    }

    func testAKeystrokeIsAllowedAgainOnceTheAppControlRequestEnds() {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let event = GestureFixtures.key(in: window, characters: "a", keyCode: 0)

        SyntheticInputGate.begin()
        SyntheticInputGate.end()

        XCTAssertTrue(TerminalInputGuard.allowsKeystroke(event: event, allowsSynthetic: { false }))
    }

    // MARK: - Controls

    func testAFreshHumanClickInTheControlsOwnWindowIsAllowed() {
        let (window, button) = windowAndControl()
        XCTAssertTrue(control(GestureFixtures.mouse(.leftMouseUp, in: window), button))
        XCTAssertTrue(control(GestureFixtures.mouse(.leftMouseDown, in: window), button))
    }

    func testAFreshKeyPressInTheControlsOwnWindowIsAllowed() {
        let (window, button) = windowAndControl()
        XCTAssertTrue(control(GestureFixtures.key(in: window, characters: "w", keyCode: 13), button))
    }

    func testAMarkedClickIsRefused() throws {
        let (window, button) = windowAndControl()
        let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        XCTAssertFalse(control(marked, button))
    }

    func testAMarkedClickIsAllowedWhenSyntheticInputIsAllowed() throws {
        let (window, button) = windowAndControl()
        let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        XCTAssertTrue(control(marked, button, allowsSynthetic: true))
    }

    func testAClickIsRefusedWhileAnAppControlRequestIsRunning() {
        let (window, button) = windowAndControl()
        beginAppControlRequest()
        XCTAssertFalse(control(GestureFixtures.mouse(.leftMouseUp, in: window), button))
    }

    func testAClickDeliveredToAnotherWindowIsRefused() {
        let (_, button) = windowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        XCTAssertFalse(control(GestureFixtures.mouse(.leftMouseUp, in: other), button))
    }

    func testNoEventIsRefusedWithVoiceOverOffAndAllowedWithVoiceOverOn() {
        let (_, button) = windowAndControl()
        XCTAssertFalse(control(nil, button, voiceOver: false), "an Accessibility press from another process")
        XCTAssertTrue(control(nil, button, voiceOver: true), "VoiceOver's own press")
    }

    func testAStaleClickIsRefused() {
        let (window, button) = windowAndControl()
        let old = GestureFixtures.mouse(.leftMouseUp, in: window,
                                        timestamp: ProcessInfo.processInfo.systemUptime - 5)
        XCTAssertFalse(control(old, button))
    }

    func testTheClockSeamDecidesWhetherAClickIsStale() {
        let (window, button) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: window, timestamp: 100)
        XCTAssertTrue(TerminalInputGuard.allowsControl(event: event, control: button,
                                                       voiceOverEnabled: { false }, allowsSynthetic: { false },
                                                       now: { 100.2 }))
        XCTAssertFalse(TerminalInputGuard.allowsControl(event: event, control: button,
                                                        voiceOverEnabled: { false }, allowsSynthetic: { false },
                                                        now: { 130 }))
    }

    func testAControlThatIsNotInAWindowRefusesEvenAHumanClick() {
        let (window, _) = windowAndControl()
        let loose = NSButton(title: "Loose", target: nil, action: nil)
        XCTAssertFalse(control(GestureFixtures.mouse(.leftMouseUp, in: window), loose))
    }

    // MARK: - Controls that are main-menu items

    func testAMenuSelectionAllowsAMouseEventThatBelongsToAnotherWindow() {
        let (_, button) = windowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let event = GestureFixtures.mouse(.leftMouseUp, in: other)

        XCTAssertFalse(control(event, button, fromMenu: false), "a control that is not a menu item still needs its own window")
        XCTAssertTrue(control(event, button, fromMenu: true))
    }

    func testAMenuSelectionStillRefusesASyntheticClick() throws {
        let (window, button) = windowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }

        let markedElsewhere = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: other))
        XCTAssertFalse(control(markedElsewhere, button, fromMenu: true))
        let markedHere = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window))
        XCTAssertFalse(control(markedHere, button, fromMenu: true))

        beginAppControlRequest()
        XCTAssertFalse(control(GestureFixtures.mouse(.leftMouseUp, in: other), button, fromMenu: true))
    }

    func testAMenuSelectionStillRefusesAStaleEvent() {
        let (_, button) = windowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        let old = GestureFixtures.mouse(.leftMouseUp, in: other, timestamp: ProcessInfo.processInfo.systemUptime - 5)
        XCTAssertFalse(control(old, button, fromMenu: true))
    }

    func testAMenuSelectionStillRefusesNoEventWithVoiceOverOff() {
        let (_, button) = windowAndControl()
        XCTAssertFalse(control(nil, button, fromMenu: true, voiceOver: false))
        XCTAssertTrue(control(nil, button, fromMenu: true, voiceOver: true))
    }

    func testAMenuSelectionStillRefusesAKeyEventDeliveredToAnotherWindow() {
        let (window, button) = windowAndControl()
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }

        XCTAssertFalse(control(GestureFixtures.key(in: other, characters: "w", keyCode: 13), button, fromMenu: true))
        XCTAssertTrue(control(GestureFixtures.key(in: window, characters: "w", keyCode: 13), button, fromMenu: true),
                      "a key equivalent in the control's own window is a person typing it")
    }
}

// MARK: - HumanGesture.permit(menuSelection:)

// A chosen main-menu item's action is handed the mouse event that tracked the menu, which belongs to
// the menu and not to the control's window. With `menuSelection` set a mouse event is not held to
// the control's window; every other check (synthetic, stale, future, missing, wrong event type, a
// key equivalent in another window) still applies.

final class HumanGestureMenuSelectionTests: XCTestCase {

    private func windowAndControl() -> (NSWindow, NSButton) {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        return (window, GestureFixtures.control(in: window))
    }

    private func otherWindow() -> NSWindow {
        let other = GestureFixtures.offscreenWindow()
        addTeardownBlock { other.close() }
        return other
    }

    private func isHuman(_ verdict: HumanGestureVerdict) -> Bool {
        if case .human = verdict { return true }
        return false
    }

    private func permit(_ event: NSEvent?, _ control: NSView, menu: Bool = true,
                        voiceOver: Bool = false, allowsSynthetic: Bool = false,
                        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
        -> HumanGestureVerdict {
        HumanGesture.permit(event, control: control, menuSelection: menu,
                            voiceOverEnabled: { voiceOver }, allowsSynthetic: { allowsSynthetic }, now: now)
    }

    func testWithoutMenuSelectionAMouseEventInAnotherWindowIsStillRefused() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow())

        XCTAssertEqual(HumanGesture.permit(event, control: control, voiceOverEnabled: { false },
                                           allowsSynthetic: { false }),
                       .refused(reason: .notAUserEvent))
        XCTAssertEqual(permit(event, control, menu: false), .refused(reason: .notAUserEvent))
    }

    func testAMenuSelectionAcceptsAMouseUpOrDownBelongingToAnotherWindow() {
        let (_, control) = windowAndControl()
        let other = otherWindow()

        XCTAssertTrue(isHuman(permit(GestureFixtures.mouse(.leftMouseUp, in: other), control)))
        XCTAssertTrue(isHuman(permit(GestureFixtures.mouse(.leftMouseDown, in: other), control)))
    }

    func testAMenuSelectionStillAcceptsAMouseEventInTheControlsOwnWindow() {
        let (window, control) = windowAndControl()
        XCTAssertTrue(isHuman(permit(GestureFixtures.mouse(.leftMouseUp, in: window), control)))
    }

    func testAMenuSelectionRefusesAKeyDownInAnotherWindow() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.key(in: otherWindow(), characters: "t", keyCode: 17)
        XCTAssertEqual(permit(event, control), .refused(reason: .notAUserEvent))
    }

    func testAMenuSelectionAcceptsAKeyDownInTheControlsOwnWindow() {
        let (window, control) = windowAndControl()
        XCTAssertTrue(isHuman(permit(GestureFixtures.key(in: window, characters: "t", keyCode: 17), control)))
    }

    func testAMenuSelectionRefusesAMarkedMouseEventAsAppControl() throws {
        let (_, control) = windowAndControl()
        let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: otherWindow()))
        XCTAssertEqual(permit(marked, control), .refused(reason: .appControl))
    }

    func testAMenuSelectionAcceptsAMarkedMouseEventWhenSyntheticInputIsAllowed() throws {
        let (_, control) = windowAndControl()
        let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: otherWindow()))
        XCTAssertTrue(isHuman(permit(marked, control, allowsSynthetic: true)))
    }

    func testAMenuSelectionIsRefusedWhileAnAppControlRequestIsRunning() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow())
        SyntheticInputGate.begin()
        addTeardownBlock { SyntheticInputGate.end() }

        XCTAssertEqual(permit(event, control), .refused(reason: .appControl))
    }

    func testAMenuSelectionRefusesAStaleMouseEvent() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow(), timestamp: 98)
        XCTAssertEqual(permit(event, control, now: { 100 }), .refused(reason: .staleEvent))
    }

    func testAMenuSelectionRefusesAMouseEventStampedInTheFuture() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow(), timestamp: 100.5)
        XCTAssertEqual(permit(event, control, now: { 100 }), .refused(reason: .futureEvent))
    }

    func testAMenuSelectionAcceptsAFreshEventOnTheInjectedClock() {
        let (_, control) = windowAndControl()
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow(), timestamp: 99.5)
        XCTAssertTrue(isHuman(permit(event, control, now: { 100 })))
    }

    func testAMenuSelectionWithNoEventIsRefusedWithVoiceOverOffAndAcceptedWithItOn() {
        let (_, control) = windowAndControl()
        XCTAssertEqual(permit(nil, control, voiceOver: false), .refused(reason: .accessibilityPress))
        XCTAssertEqual(permit(nil, control, voiceOver: true), .human(sourcePid: nil, sourceState: nil))
    }

    func testAMenuSelectionRefusesEventTypesThatAreNotAClickOrAKeyPress() {
        let (_, control) = windowAndControl()
        let other = otherWindow()
        for event in [GestureFixtures.mouse(.mouseMoved, in: other),
                      GestureFixtures.mouse(.rightMouseUp, in: other),
                      GestureFixtures.key(.keyUp, in: other),
                      GestureFixtures.other(in: other)] {
            XCTAssertEqual(permit(event, control), .refused(reason: .notAUserEvent), "\(event.type)")
        }
    }

    func testAMenuSelectionForAControlNotInAWindowIsRefused() {
        let loose = NSButton(title: "Loose", target: nil, action: nil)
        let event = GestureFixtures.mouse(.leftMouseUp, in: otherWindow())
        XCTAssertEqual(permit(event, loose), .refused(reason: .notAUserEvent))
    }
}
