import XCTest
import AppKit
import SwiftUI

// The Devices and Pair-a-Device windows and the human-gesture gate in front of what they send.
//
// Contract.
//   * A press in either window acts only on a person's own input AND only when that input belongs to the
//     window being pressed. A SwiftUI `.alert`, `.sheet` or popover is a window of its own, so a click there is
//     "not a user event" and a confirmation shown that way can never send. The Revoke confirmation is therefore
//     a row of the Devices window itself (the end-to-end tests drive the real SwiftUI view to prove it).
//   * A press that was not a person's own sends nothing and says so (`gestureNotice`).
//   * The menu pick that opens the Pair window asks for the code: a menu item's event belongs to the menu, not
//     to the window, but every other check still applies.
//   * Closing the Pair window (any way) cancels the open pairing, so the code dies with the window.
//
// How the real SwiftUI view is driven. SwiftUI builds no accessibility tree in the unit-test process (tried:
// `accessibilityChildren` of the hosting view and of every view below it stays empty with the AX automation
// flags and `setAccessibilityEnabled` on, offscreen or on screen), so buttons cannot be found by role and
// pressed with `accessibilityPerformPress`. The tests press them with real mouse events sent through the real
// window (`NSWindow.sendEvent`) at points of the row that holds the button, and watch the effect: a row
// appearing in or leaving the Devices window's list (the table is AppKit), the model, and the transport.
// A SwiftUI `Text` cannot be read back, so the confirmation's wording is not asserted here; that it appears as
// a row of this very window is.
//
// Mutations (to be run by hand), and the tests that fail for each:
//   W1 restore `.alert(item:)` for the Revoke confirmation (and the inline row gone)
//        -> testPressingRevokeAsksInsideTheWindowAndConfirmingSendsTheRevoke, testCancelClosesTheConfirmationWithoutSending,
//           testAConfirmationPressWhoseEventBelongsToAnotherWindowSendsNothingAndSaysSo,
//           testNeitherWindowPresentsAnythingInAWindowOfItsOwn
//   W2 `DeviceWindowGesture.verdict` ignores the window (permits a control from the event's own window)
//        -> testAnEventOfAnotherWindowIsNotAUserEvent, testAConfirmationPressWhoseEventBelongsToAnotherWindowSendsNothingAndSaysSo,
//           testShowCodePressWhoseEventBelongsToAnotherWindowSendsNothingAndSaysSo
//   W3 `windowWillClose` empty
//        -> testClosingThePairWindowCancelsTheOpenPairing (the Cancel button cancels by itself, so
//           testCancelInThePairWindowCancelsTheOpenPairingOnce still passes: it is the button path)
//   W4 `beginFromMenuPick` without `menuSelection: true`
//        -> testAMenuPickAsksForTheCode
//   W5 the Pair view maps `.issueFailed` to another sentence, or drops the 'Waiting for the server' line
//        -> DeviceWindowPresentationSourceTests.testThePairViewShowsTheCouldntMakeACodeSentenceForIssueFailed,
//           testThePairViewSaysItIsWaitingForTheServerAndDisablesNewCodeWhileNewCodeCannotBeRequested
// (W1-W5 were each run by hand and failed the tests named; the real SwiftUI view is driven with real events.)
final class DeviceWindowGestureTests: MouseQueueTestCase {

    // MARK: Rig

    private final class FakeTransport: DeviceAdminTransport {
        enum Call: Equatable {
            case pairStart(String)
            case pairCancel(request: String, pairing: String)
            case list(String)
            case revoke(request: String, device: String)
        }
        var calls: [Call] = []
        func devicePairStart(requestId: String) { calls.append(.pairStart(requestId)) }
        func devicePairCancel(requestId: String, pairingId: String) { calls.append(.pairCancel(request: requestId, pairing: pairingId)) }
        func deviceList(requestId: String) { calls.append(.list(requestId)) }
        func deviceRevoke(requestId: String, device: String) { calls.append(.revoke(request: requestId, device: device)) }
    }

    /// The input behind the control being pressed. The test swaps what it makes; the controller asks it at
    /// the moment a control acts, so an event is always fresh.
    private final class EventSource {
        var make: () -> NSEvent? = { nil }
    }

    /// One of the two windows with everything a test needs around it.
    private final class Subject {
        let controller: NSWindowController
        let window: NSWindow
        let model: DeviceAdminModel
        let transport: FakeTransport
        let events: EventSource
        let gesture: () -> HumanGestureVerdict
        init(controller: NSWindowController, window: NSWindow, model: DeviceAdminModel, transport: FakeTransport,
             events: EventSource, gesture: @escaping () -> HumanGestureVerdict) {
            self.controller = controller; self.window = window; self.model = model; self.transport = transport
            self.events = events; self.gesture = gesture
        }
    }

    private let human = HumanGestureVerdict.human(sourcePid: nil, sourceState: nil)
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func pump(_ seconds: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func isHuman(_ verdict: HumanGestureVerdict) -> Bool {
        if case .human = verdict { return true }
        return false
    }

    /// A model connected to `transport` (ids r1, r2, ...), at `level` and with `devices` listed.
    private func makeModel(_ transport: FakeTransport, level: String = "full", devices: [DeviceSummary] = []) -> DeviceAdminModel {
        var n = 0
        let model = DeviceAdminModel(transport: transport, makeId: { n += 1; return "r\(n)" })
        model.connectionChanged(connected: true, devicesSupported: true)
        model.handle(.deviceAdminLevel(DeviceAdminLevelWire(level: level)))
        if !devices.isEmpty { model.handle(.devices(DevicesWire(devices: devices))) }
        return model
    }

    /// Gives `window` a window number without showing it to anyone: borderless (a titled window is pulled back
    /// onto a screen), parked far off every screen, ordered front.
    private func parkOffscreen(_ window: NSWindow) {
        window.styleMask = [.borderless]
        window.animationBehavior = .none
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        for _ in 0..<6 { pump() }
        addTeardownBlock { if window.isVisible { window.close() } }
    }

    private func devicesSubject(devices: [DeviceSummary]? = nil) -> Subject {
        let transport = FakeTransport()
        let phone = DeviceSummary(id: "d1", name: "Ada's iPhone", kind: "iphone", pairedAt: when)
        let model = makeModel(transport, devices: devices ?? [phone])
        let events = EventSource()
        let controller = DevicesWindowController(model: model, currentEvent: { events.make() })
        let window = controller.window!
        parkOffscreen(window)
        return Subject(controller: controller, window: window, model: model, transport: transport, events: events,
                       gesture: { controller.gesture() })
    }

    private func pairSubject(level: String = "full") -> Subject {
        let transport = FakeTransport()
        let model = makeModel(transport, level: level)
        let events = EventSource()
        let controller = PairDeviceWindowController(model: model, currentEvent: { events.make() })
        let window = controller.window!
        parkOffscreen(window)
        return Subject(controller: controller, window: window, model: model, transport: transport, events: events,
                       gesture: { controller.gesture() })
    }

    /// A second window, standing in for the alert's own panel (or a menu).
    private func anotherWindow() -> NSWindow {
        let window = GestureFixtures.offscreenWindow()
        addTeardownBlock { window.close() }
        return window
    }

    private var bothWindows: [(name: String, subject: Subject)] {
        [("Devices", devicesSubject()), ("Pair a Device", pairSubject())]
    }

    // MARK: The gate, through each controller's own closure

    func testAFreshClickOrKeyPressOfTheWindowIsAPersonsOwn() {
        for (name, s) in bothWindows {
            for make in [{ GestureFixtures.mouse(.leftMouseUp, in: s.window) },
                         { GestureFixtures.mouse(.leftMouseDown, in: s.window) },
                         { GestureFixtures.key(.keyDown, in: s.window) }] {
                s.events.make = make
                XCTAssertTrue(isHuman(s.gesture()), "\(name): \(String(describing: make().type))")
            }
        }
    }

    // A SwiftUI alert is a panel of its own: the click on its button belongs to that panel, not to the window.
    func testAnEventOfAnotherWindowIsNotAUserEvent() {
        let panel = anotherWindow()
        for (name, s) in bothWindows {
            s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: panel) }
            XCTAssertEqual(s.gesture(), .refused(reason: .notAUserEvent), "\(name) click")
            s.events.make = { GestureFixtures.key(.keyDown, in: panel) }
            XCTAssertEqual(s.gesture(), .refused(reason: .notAUserEvent), "\(name) key")
        }
    }

    func testNoEventIsRefusedAsAnAccessibilityPress() {
        // With VoiceOver on, an event-less press is a person's: the answer is not this test's business then.
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        for (name, s) in bothWindows {
            s.events.make = { nil }
            XCTAssertEqual(s.gesture(), .refused(reason: .accessibilityPress), name)
        }
    }

    func testAStaleEventIsRefused() {
        for (name, s) in bothWindows {
            let old = ProcessInfo.processInfo.systemUptime - 5
            s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window, timestamp: old) }
            XCTAssertEqual(s.gesture(), .refused(reason: .staleEvent), name)
        }
    }

    func testAnAppControlEventIsRefused() throws {
        for (name, s) in bothWindows {
            let marked = try GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: s.window))
            s.events.make = { marked }
            XCTAssertEqual(s.gesture(), .refused(reason: .appControl), "\(name) click")
            let markedKey = try GestureFixtures.marked(GestureFixtures.key(.keyDown, in: s.window))
            s.events.make = { markedKey }
            XCTAssertEqual(s.gesture(), .refused(reason: .appControl), "\(name) key")
        }
    }

    // MARK: Driving the real SwiftUI view with real mouse events

    /// A press and release at `point` (window coordinates), sent through the window like the OS would. The
    /// release is also queued first, so a table's tracking loop (a click on dead space) finds it and ends.
    private func click(_ window: NSWindow, at point: NSPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: now,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: now,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        window.sendEvent(up)
        MouseQueueTestCase.drainEventQueue()
        pump(0.02)
    }

    /// Clicks each point in turn until `done` holds; whether it did.
    private func clickUntil(_ window: NSWindow, _ points: [NSPoint], _ done: () -> Bool) -> Bool {
        for point in points {
            click(window, at: point)
            if done() { return true }
        }
        return done()
    }

    private func table(in window: NSWindow) -> NSTableView? {
        func find(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// `row` of the Devices window's list, in window coordinates.
    private func rect(ofRow row: Int, in table: NSTableView) -> NSRect {
        table.convert(table.rect(ofRow: row), to: nil)
    }

    /// Row-major points inside `rect`: `ys` bottom to top (or the reverse), `xs` left to right (or the reverse).
    private func grid(in rect: NSRect, xs: ClosedRange<CGFloat>, step: CGFloat, topDown: Bool = false,
                      rightToLeft: Bool = false) -> [NSPoint] {
        var ys = Array(stride(from: rect.minY + 6, to: rect.maxY, by: step))
        var xValues = Array(stride(from: rect.minX + xs.lowerBound, through: rect.minX + xs.upperBound, by: step))
        if topDown { ys.reverse() }
        if rightToLeft { xValues.reverse() }
        return ys.flatMap { y in xValues.map { NSPoint(x: $0, y: y) } }
    }

    /// Press the device row's "Revoke…" (at its trailing edge, vertically centred). True once a confirmation row
    /// has appeared in the window's own list.
    private func pressRevokeEllipsis(_ s: Subject) -> Bool {
        guard let table = table(in: s.window) else { return false }
        let before = table.numberOfRows
        let row = rect(ofRow: before - 1, in: table)
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window) }
        let points = stride(from: row.maxX - 8, to: row.maxX - 170, by: -8).map { NSPoint(x: $0, y: row.midY) }
        return clickUntil(s.window, points) { table.numberOfRows > before }
    }

    /// Press the confirmation's own buttons: the left one is "Revoke", the right one "Cancel". True once the
    /// confirmation row has gone again.
    private func pressConfirmation(_ s: Subject, cancel: Bool) -> Bool {
        guard let table = table(in: s.window) else { return false }
        let before = table.numberOfRows
        let row = rect(ofRow: before - 1, in: table)
        let points = grid(in: row, xs: 8...260, step: 6, rightToLeft: cancel)
        return clickUntil(s.window, points) { table.numberOfRows < before }
    }

    func testPressingRevokeAsksInsideTheWindowAndConfirmingSendsTheRevoke() throws {
        let s = devicesSubject()
        XCTAssertEqual(try XCTUnwrap(table(in: s.window)).numberOfRows, 2, "precondition: the section header and one device")

        XCTAssertTrue(pressRevokeEllipsis(s), "Revoke… must show its confirmation as a row of this very window")
        XCTAssertEqual(s.transport.calls, [], "Revoke… alone asks, it does not send")
        XCTAssertNil(s.model.gestureNotice)

        // The person's click on the confirmation's Revoke button, in this window.
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window) }
        XCTAssertTrue(pressConfirmation(s, cancel: false), "the confirmation's Revoke button must be pressable")
        XCTAssertEqual(s.transport.calls, [.revoke(request: "r1", device: "d1")])
        XCTAssertNil(s.model.gestureNotice)
        XCTAssertEqual(try XCTUnwrap(table(in: s.window)).numberOfRows, 2, "the confirmation closes")
    }

    // What the old `.alert` did: its button's event belongs to the alert's own panel.
    func testAConfirmationPressWhoseEventBelongsToAnotherWindowSendsNothingAndSaysSo() throws {
        let s = devicesSubject()
        let panel = anotherWindow()
        XCTAssertTrue(pressRevokeEllipsis(s))

        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: panel) }
        XCTAssertTrue(pressConfirmation(s, cancel: false))
        XCTAssertEqual(s.transport.calls, [], "an event that is not this window's never sends a revoke")
        XCTAssertEqual(s.model.gestureNotice, DeviceAdminCopy.notAUserAction)
    }

    func testCancelClosesTheConfirmationWithoutSending() throws {
        let s = devicesSubject()
        XCTAssertTrue(pressRevokeEllipsis(s))
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window) }
        XCTAssertTrue(pressConfirmation(s, cancel: true), "Cancel must close the confirmation")
        XCTAssertEqual(s.transport.calls, [])
        XCTAssertNil(s.model.gestureNotice)
        XCTAssertEqual(try XCTUnwrap(table(in: s.window)).numberOfRows, 2)
    }

    // The Pair window's Show Code button, pressed for real, asks through the window's own gate.
    private func pressShowCode(_ s: Subject, until done: () -> Bool) -> Bool {
        let content = s.window.contentView!.bounds
        let top = NSRect(x: content.minX, y: content.maxY - 260, width: content.width, height: 260)
        let points = grid(in: top, xs: (content.width / 2)...(content.width / 2), step: 6, topDown: true)
        return clickUntil(s.window, points, done)
    }

    func testShowCodeAsksForACodeWhenPressedByAPerson() {
        let s = pairSubject()
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window) }
        XCTAssertTrue(pressShowCode(s) { s.model.pair == .issuing }, "Show Code must ask for a code")
        XCTAssertEqual(s.transport.calls, [.pairStart("r1")])
        XCTAssertNil(s.model.gestureNotice)
    }

    func testShowCodePressWhoseEventBelongsToAnotherWindowSendsNothingAndSaysSo() {
        let s = pairSubject()
        let panel = anotherWindow()
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: panel) }
        XCTAssertTrue(pressShowCode(s) { s.model.gestureNotice != nil }, "Show Code must have been pressed")
        XCTAssertEqual(s.transport.calls, [])
        XCTAssertEqual(s.model.gestureNotice, DeviceAdminCopy.notAUserAction)
        XCTAssertEqual(s.model.pair, .idle)
    }

    // MARK: The menu pick

    /// A fresh left-click as a menu item hands it on: it belongs to no window of the app.
    private func menuClick(timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: timestamp,
                           windowNumber: 0, context: nil, eventNumber: 9, clickCount: 1, pressure: 1)!
    }

    func testAMenuPickAsksForTheCode() {
        let panel = anotherWindow()
        let candidates: [(String, () -> NSEvent)] = [
            ("a click that belongs to no window", { self.menuClick() }),
            ("a click that belongs to another window", { GestureFixtures.mouse(.leftMouseUp, in: panel) }),
        ]
        for (name, make) in candidates {
            let s = pairSubject()
            s.events.make = make
            (s.controller as! PairDeviceWindowController).beginFromMenuPick()
            XCTAssertEqual(s.transport.calls, [.pairStart("r1")], name)
            XCTAssertEqual(s.model.pair, .issuing, name)
            XCTAssertNil(s.model.gestureNotice, name)
        }
    }

    func testAMenuPickThatWasNotAPersonsOwnAsksForNothingAndSaysSo() throws {
        let panel = anotherWindow()
        let stale = ProcessInfo.processInfo.systemUptime - 5
        let cases: [(String, () throws -> NSEvent)] = [
            ("a key press of another window", { GestureFixtures.key(.keyDown, in: panel) }),
            ("a stale click", { self.menuClick(timestamp: stale) }),
            ("an app-control click", { try GestureFixtures.marked(self.menuClick()) }),
        ]
        for (name, make) in cases {
            let s = pairSubject()
            let event = try make()
            s.events.make = { event }
            (s.controller as! PairDeviceWindowController).beginFromMenuPick()
            XCTAssertEqual(s.transport.calls, [], name)
            XCTAssertEqual(s.model.gestureNotice, DeviceAdminCopy.notAUserAction, name)
            XCTAssertEqual(s.model.pair, .idle, name)
        }
    }

    func testAMenuPickWithNoEventAsksForNothingAndSaysSo() {
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        let s = pairSubject()
        s.events.make = { nil }
        (s.controller as! PairDeviceWindowController).beginFromMenuPick()
        XCTAssertEqual(s.transport.calls, [])
        XCTAssertEqual(s.model.gestureNotice, DeviceAdminCopy.notAUserAction)
    }

    // MARK: Closing the Pair window

    /// Shows a code in `s`: ask, then feed the code the daemon would send for that request.
    private func showACode(_ s: Subject, pairing: String = "p1") {
        s.model.beginPairing(gesture: human)
        s.model.handle(.devicePairing(DevicePairingWire(
            requestId: "r1", pairingId: pairing, code: "123456",
            serverUrl: "nostromo://pair?v=1&host=h&port=7&code=123456", expiresAt: when.addingTimeInterval(1_000_000_000))))
        guard case .showing = s.model.pair else { return XCTFail("precondition: a code is showing") }
    }

    func testClosingThePairWindowCancelsTheOpenPairing() {
        let s = pairSubject()
        showACode(s)
        s.transport.calls.removeAll()
        s.window.close()
        XCTAssertEqual(s.transport.calls, [.pairCancel(request: "r2", pairing: "p1")])
        XCTAssertEqual(s.model.pair, .idle)
    }

    func testClosingThePairWindowWithNothingOpenSendsNothing() {
        let s = pairSubject()
        s.window.close()
        XCTAssertEqual(s.transport.calls, [])
        XCTAssertEqual(s.model.pair, .idle)
    }

    // The Cancel button of a showing code closes the window and cancels the pairing: once.
    func testCancelInThePairWindowCancelsTheOpenPairingOnce() {
        let s = pairSubject()
        showACode(s)
        s.transport.calls.removeAll()
        s.events.make = { GestureFixtures.mouse(.leftMouseUp, in: s.window) }
        let content = s.window.contentView!.bounds
        let points = grid(in: content, xs: (content.width / 2)...(content.width / 2), step: 6, topDown: true)
        XCTAssertTrue(clickUntil(s.window, points) { s.model.pair == .idle }, "Cancel must have been pressed")
        XCTAssertEqual(s.transport.calls, [.pairCancel(request: "r2", pairing: "p1")], "one cancel, not one per close path")
        XCTAssertFalse(s.window.isVisible, "Cancel closes the window")
    }
}

// MARK: - Nothing is presented in a window of its own

// A confirmation shown in another window can never pass the window gate above. Read from the sources, since
// the rule is about what any screen could ever present. Comments are not code and are ignored.
final class DeviceWindowPresentationSourceTests: XCTestCase {

    private func source(_ relative: String, file: StaticString = #filePath) throws -> String {
        let url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .appendingPathComponent("../Nostromo/\(relative)").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func withoutComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: #"(?<!:)//.*$"#, options: .regularExpression) else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    func testNeitherWindowPresentsAnythingInAWindowOfItsOwn() throws {
        let forbidden = [#"\.alert\s*\("#, #"\.confirmationDialog\s*\("#, #"\.sheet\s*\("#, #"\.popover\s*\("#,
                         #"NSAlert"#, #"beginSheetModal"#]
        for path in ["UI/DevicesWindow.swift", "UI/PairDeviceWindow.swift"] {
            let code = withoutComments(try source(path))
            XCTAssertFalse(code.isEmpty, path)
            for pattern in forbidden {
                XCTAssertNil(code.range(of: pattern, options: .regularExpression),
                             "\(path) must not use \(pattern): what it presents is a window the gate refuses")
            }
        }
    }

    // SwiftUI text cannot be read back in the unit-test process (see the note on the gesture tests), so which
    // sentence each Pair-window state shows is checked in the source: the state, then the copy it must use.

    private func pairView() throws -> String { withoutComments(try source("UI/PairDeviceWindow.swift")) }

    private func assertCase(_ state: String, shows copy: String, in code: String, file: StaticString = #filePath, line: UInt = #line) {
        let pattern = #"case\s+\.\#(state)\s*:\s*message\(\s*DeviceAdminCopy\.\#(copy)\s*\)"#
        XCTAssertNotNil(code.range(of: pattern, options: .regularExpression),
                        "the Pair view must show DeviceAdminCopy.\(copy) for .\(state)", file: file, line: line)
    }

    func testThePairViewShowsTheCouldntMakeACodeSentenceForIssueFailed() throws {
        let code = try pairView()
        assertCase("issueFailed", shows: "issueFailed", in: code)
        assertCase("failed", shows: "saveFailed", in: code)
        XCTAssertEqual(DeviceAdminCopy.issueFailed, "Couldn't make a pairing code. Try again.")
        XCTAssertNotEqual(DeviceAdminCopy.issueFailed, DeviceAdminCopy.saveFailed)
    }

    func testThePairViewSaysItIsWaitingForTheServerAndDisablesNewCodeWhileNewCodeCannotBeRequested() throws {
        let code = try pairView()
        XCTAssertNotNil(code.range(of: #"\.disabled\(\s*!model\.canRequestNewCode\s*\)"#, options: .regularExpression),
                        "New Code is disabled while the model says it cannot be requested")
        XCTAssertNotNil(code.range(of: #"if\s+!model\.canRequestNewCode\s*\{\s*Text\(DeviceAdminCopy\.waitingForServer\)"#,
                                   options: .regularExpression),
                        "and the window says it is waiting for the server")
    }

    func testThePairViewAsksAgainEveryFewSecondsWhileWaiting() throws {
        let code = try pairView()
        XCTAssertNotNil(code.range(of: #"Timer\.publish\(every:\s*3[\s\S]*?probeWhileWaiting\(\)"#, options: .regularExpression))
    }
}
