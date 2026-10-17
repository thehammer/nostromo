import XCTest
import AppKit

// Behavioural spec for `SyntheticInputGate`: telling input the app-control
// socket synthesised from input a person made.
//
// Two signals, either enough: depth (a request is running right now) and the
// marker every synthesised event carries in its CGEvent source user data.
// The marker has to survive the trip into an `NSEvent` and on to the action of
// a control that the synthesised click reaches: that last hop is pinned here
// against the real `AppControlMouse`.

final class SyntheticInputGateTests: XCTestCase {

    private let userApp = "com.hammer.nostromo"
    private let qaApp = "com.hammer.nostromo.qa"
    private let flag = "NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT"

    private func realEvent() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                           eventNumber: 1, clickCount: 1, pressure: 0)!
    }

    // MARK: Depth

    func testNothingIsSyntheticWhenNoAppControlRequestIsRunning() {
        XCTAssertEqual(SyntheticInputGate.depth, 0)
        XCTAssertFalse(SyntheticInputGate.isSynthetic(nil))
        XCTAssertFalse(SyntheticInputGate.isSynthetic(realEvent()))
    }

    func testEverythingIsSyntheticWhileARequestIsRunningAndNotAfter() {
        SyntheticInputGate.begin()
        XCTAssertTrue(SyntheticInputGate.isSynthetic(nil), "no event at all, during a request")
        XCTAssertTrue(SyntheticInputGate.isSynthetic(realEvent()), "a plain event, during a request")
        SyntheticInputGate.end()
        XCTAssertEqual(SyntheticInputGate.depth, 0)
        XCTAssertFalse(SyntheticInputGate.isSynthetic(nil))
        XCTAssertFalse(SyntheticInputGate.isSynthetic(realEvent()))
    }

    func testNestedRequestsStaySyntheticUntilTheOutermostEnds() {
        SyntheticInputGate.begin()
        SyntheticInputGate.begin()
        SyntheticInputGate.end()
        XCTAssertTrue(SyntheticInputGate.isSynthetic(realEvent()), "inner request ended, outer still running")
        SyntheticInputGate.end()
        XCTAssertFalse(SyntheticInputGate.isSynthetic(realEvent()))
        XCTAssertEqual(SyntheticInputGate.depth, 0)
    }

    func testAStrayEndCannotMaskTheNextRequest() {
        SyntheticInputGate.end()
        XCTAssertEqual(SyntheticInputGate.depth, 0, "depth must not go negative")
        SyntheticInputGate.begin()
        XCTAssertTrue(SyntheticInputGate.isSynthetic(realEvent()))
        SyntheticInputGate.end()
        XCTAssertFalse(SyntheticInputGate.isSynthetic(realEvent()))
    }

    // MARK: Marker

    func testTheMarkerIsAFixedNonzeroValue() {
        XCTAssertNotEqual(SyntheticInputGate.marker, 0, "0 is what every unstamped event carries")
    }

    func testAnEventBuiltFromAStampedCGEventIsSyntheticAndKeepsItsMarker() throws {
        let event = try GestureFixtures.marked(realEvent())
        XCTAssertEqual(try XCTUnwrap(event.cgEvent).getIntegerValueField(.eventSourceUserData),
                       SyntheticInputGate.marker, "the marker must survive NSEvent(cgEvent:)")
        XCTAssertTrue(SyntheticInputGate.isSynthetic(event))
    }

    func testAMarkedKeyEventIsSynthetic() throws {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let event = try GestureFixtures.marked(GestureFixtures.key(in: window))
        XCTAssertTrue(SyntheticInputGate.isSynthetic(event))
    }

    func testAnOrdinaryEventIsNotSynthetic() {
        XCTAssertFalse(SyntheticInputGate.isSynthetic(realEvent()))
    }

    func testAnEventWithAnotherUserDataValueIsNotSynthetic() throws {
        let other = try GestureFixtures.throughCGEvent(realEvent(), userData: SyntheticInputGate.marker &+ 1)
        XCTAssertFalse(SyntheticInputGate.isSynthetic(other))
        let zero = try GestureFixtures.throughCGEvent(realEvent(), userData: 0)
        XCTAssertFalse(SyntheticInputGate.isSynthetic(zero), "hardware events carry user data 0")
    }

    // MARK: Which builds accept synthetic input

    func testTheUsersAppNeverAcceptsSyntheticInput() {
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: userApp, environment: [flag: "1"]))
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: userApp, environment: [:]))
    }

    func testAQABuildAcceptsSyntheticInputOnlyWhenTheFlagIsExactlyOne() {
        XCTAssertTrue(SyntheticInputGate.allowsSynthetic(bundleIdentifier: qaApp, environment: [flag: "1"]))
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: qaApp, environment: [:]))
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: qaApp, environment: [flag: "0"]))
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: qaApp, environment: [flag: "true"]))
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: qaApp, environment: [flag: ""]))
    }

    func testAnUnknownBundleIdentifierNeverAcceptsSyntheticInput() {
        XCTAssertFalse(SyntheticInputGate.allowsSynthetic(bundleIdentifier: nil, environment: [flag: "1"]))
    }

    // MARK: Through AppControlMouse

    /// Records the event behind an action: what a control would hand `permit`.
    private final class Recorder: NSObject {
        var events: [NSEvent?] = []
        var syntheticAtAction: [Bool] = []
        @objc func fire(_ sender: Any?) {
            events.append(NSApp.currentEvent)
            syntheticAtAction.append(SyntheticInputGate.isSynthetic(NSApp.currentEvent))
        }
    }

    private final class FirstMouseButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class OffscreenKeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// A click app-control synthesises reaches the button's action as synthetic,
    /// so a control can tell it from a person's. `AppControlServer` runs every
    /// request inside `begin()/end()`, as here; that depth is what marks a click.
    /// (Clicks carry no marker: `NSEvent(cgEvent:)` rebuilds a mouse event's
    /// location unreliably, so app-control doesn't stamp them; see
    /// `SyntheticInputGate.stamped`.)
    func testAClickSynthesisedByAppControlIsSyntheticAtTheButtonAction() throws {
        _ = NSApplication.shared
        let window = OffscreenKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
                                        styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        window.makeKey()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        addTeardownBlock { window.close() }

        let recorder = Recorder()
        let button = FirstMouseButton(title: "Go", target: recorder, action: #selector(Recorder.fire(_:)))
        button.frame = NSRect(x: 50, y: 50, width: 120, height: 32)
        window.contentView!.addSubview(button)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)

        // Watchdog: a click that parks in the button's tracking loop is released
        // by a mouse-up from a background thread so the test fails instead of hanging.
        let releases = (0..<20).map { i in
            NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 900_000 + i, clickCount: 1, pressure: 0)!
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        let lock = NSLock()
        var next = 0
        timer.schedule(deadline: .now() + 3, repeating: 0.25)
        timer.setEventHandler {
            lock.lock(); defer { lock.unlock() }
            guard next < releases.count else { return }
            NSApp.postEvent(releases[next], atStart: false)
            next += 1
        }
        timer.resume()
        defer { timer.cancel() }

        SyntheticInputGate.begin()
        defer { SyntheticInputGate.end() }
        try AppControlMouse.click(in: window, at: point)

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        while NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) != nil {}

        XCTAssertEqual(recorder.events.count, 1, "the click must fire the button's action exactly once")
        guard let event = recorder.events.first ?? nil else {
            return XCTFail("the action saw no NSApp.currentEvent, so a control cannot judge it")
        }
        // Evidence for the OS-level question (events posted by another process): what an
        // in-process synthesised event reports as its source.
        let cg = event.cgEvent
        let pid = cg?.getIntegerValueField(.eventSourceUnixProcessID)
        let state = cg?.getIntegerValueField(.eventSourceStateID)
        print("AP1 synthetic event source: pid=\(pid.map(String.init) ?? "nil") state=\(state.map(String.init) ?? "nil")"
              + " type=\(event.type.rawValue) userData=\(cg?.getIntegerValueField(.eventSourceUserData).description ?? "nil")"
              + " (this process pid=\(ProcessInfo.processInfo.processIdentifier))")
        XCTAssertTrue(recorder.syntheticAtAction.first ?? false,
                      "isSynthetic must be true for the event app-control's click delivers")
        XCTAssertEqual(event.type, .leftMouseUp)
    }

    // MARK: Stamping key events

    func testAStampedKeyEventCarriesTheMarkerAndKeepsEverythingElse() throws {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 characters: "c", charactersIgnoringModifiers: "c",
                                                 isARepeat: false, keyCode: 8))
        let stamped = SyntheticInputGate.stamped(key)

        XCTAssertEqual(stamped.cgEvent?.getIntegerValueField(.eventSourceUserData), SyntheticInputGate.marker)
        XCTAssertTrue(SyntheticInputGate.isSynthetic(stamped))
        XCTAssertEqual(stamped.type, .keyDown)
        XCTAssertEqual(stamped.windowNumber, window.windowNumber)
        XCTAssertEqual(stamped.characters, "c")
        XCTAssertEqual(stamped.charactersIgnoringModifiers, "c")
        XCTAssertEqual(stamped.keyCode, 8)
        XCTAssertTrue(stamped.modifierFlags.contains(.command))
    }

    func testStampingLeavesAMouseEventAsItIs() {
        let mouse = realEvent()
        XCTAssertTrue(SyntheticInputGate.stamped(mouse) === mouse)
    }
}
