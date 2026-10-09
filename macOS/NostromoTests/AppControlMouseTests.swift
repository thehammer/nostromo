import XCTest
import AppKit

// `AppControlMouse` is what the app-control socket's `click` and `drag` verbs call.
// Contract: a synthesised gesture is a *complete* gesture (down ... up) that is
// delivered in order, and the call RETURNS. A selectable label or a button runs a
// nested mouse-tracking loop inside `window.sendEvent(mouseDown)` and only leaves
// it when it sees the mouse-up, so a click that only sends a down used to park the
// whole app in that loop until a real mouse event arrived.
//
// Harness notes. A never-activated xctest process drops `sendEvent(mouseDown)` for
// views whose `acceptsFirstMouse` is false, so every view below that has to
// *receive* a click accepts first mouse. The stock `NSWindow.sendEvent` is used
// throughout: it is the path that runs the nested tracking loop, which is the thing
// under test. The window has to be ordered front for that (AppKit drops mouse events
// for a window that is not on screen) but is parked far outside every screen.
//
// A test that would hang on the unfixed behaviour must fail instead: a watchdog
// posts a mouse-up from a background thread after a few seconds, which unsticks
// the nested loop, and the test then fails because the call needed the watchdog.

// MARK: - Harness

private final class OffscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private func makeOffscreenWindow(_ size: NSSize = NSSize(width: 500, height: 300)) -> NSWindow {
    _ = NSApplication.shared
    let w = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless, backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    w.orderFrontRegardless()
    w.makeKey()
    // Let AppKit finish setting the window up: a mouse event queued for a window
    // that has not settled yet comes back with its location displaced.
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    return w
}

private final class WatchdogState {
    private let lock = NSLock()
    private var _fired = false
    private var _cancelled = false
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return _fired }
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_cancelled else { return false }
        _fired = true
        return true
    }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
}

/// Runs `body`; once it has run for `timeout`, a background timer keeps posting a
/// mouse-up for `window` (one every quarter second) to release any nested tracking
/// loop, however many the body enters, until the body returns.
private func guarded(_ window: NSWindow, at point: NSPoint, timeout: TimeInterval = 3,
                     _ body: () throws -> Void) rethrows -> (elapsed: TimeInterval, watchdogFired: Bool) {
    let state = WatchdogState()
    // Built here, on the calling thread; the timer only posts them.
    let releases = (0..<200).map { i in
        NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 900_000 + i, clickCount: 1, pressure: 0)!
    }
    let queue = DispatchQueue.global()
    let timer = DispatchSource.makeTimerSource(queue: queue)
    let next = NSLock()
    var index = 0
    timer.schedule(deadline: .now() + timeout, repeating: 0.25)
    timer.setEventHandler {
        guard state.fire() else { return }
        next.lock(); defer { next.unlock() }
        guard index < releases.count else { return }
        NSApp.postEvent(releases[index], atStart: false)
        index += 1
    }
    timer.resume()
    let start = Date()
    defer { state.cancel(); timer.cancel() }
    try body()
    return (Date().timeIntervalSince(start), state.fired)
}

/// Mouse events still queued for `window`, drained so one test cannot leak into the next.
private func drainMouseEvents(for window: NSWindow) -> [NSEvent] {
    var out: [NSEvent] = []
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
    while let e = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
        if e.windowNumber == window.windowNumber { out.append(e) }
    }
    return out
}

private final class FirstMouseTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override class var cellClass: AnyClass? {
        get { FirstMouseTextFieldCell.self }
        set { _ = newValue }
    }
}

/// The field editor is the hit view for the second click of a double-click, so it
/// has to accept first mouse too in a window that is never natively key.
private final class FirstMouseTextFieldCell: NSTextFieldCell {
    private lazy var editor: FirstMouseEditor = {
        let e = FirstMouseEditor(frame: .zero)
        e.isFieldEditor = true
        return e
    }()
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

private final class FirstMouseEditor: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstMouseTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MouseRecord {
    let kind: String
    let clickCount: Int
    let timestamp: TimeInterval
    let eventNumber: Int
}

private final class RecordingView: NSView {
    var log: [MouseRecord] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func record(_ kind: String, _ e: NSEvent) {
        log.append(MouseRecord(kind: kind, clickCount: e.clickCount, timestamp: e.timestamp, eventNumber: e.eventNumber))
    }
    override func mouseDown(with event: NSEvent) { record("down", event) }
    override func mouseDragged(with event: NSEvent) { record("drag", event) }
    override func mouseUp(with event: NSEvent) { record("up", event) }
}

private final class ClickCounter: NSObject {
    var count = 0
    @objc func fire(_ sender: Any?) { count += 1 }
}

private func windowCentre(of view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
}

// MARK: - Tests

final class AppControlMouseTests: XCTestCase {

    /// A hang is caught by the watchdog (3 s); this only has to be "not parked", and
    /// leaves room for a loaded machine.
    private let promptly: TimeInterval = 2.0

    private func makeRecorder() -> (NSWindow, RecordingView) {
        let window = makeOffscreenWindow()
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        let view = RecordingView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
        window.contentView!.addSubview(view)
        return (window, view)
    }

    // (a) A double-click on a word of a selectable label selects that word, and returns.
    func testDoubleClickOnAWordOfASelectableLabelSelectsThatWordAndReturnsPromptly() throws {
        let window = makeOffscreenWindow(NSSize(width: 500, height: 120))
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        let text = "alpha bravo charlie delta echo foxtrot golf hotel"
        let field = FirstMouseTextField(labelWithString: text)
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: 10, y: 50, width: 480, height: 20)
        window.contentView!.addSubview(field)

        // Aim at the middle of "charlie", measured from the font so no pixels are hard-coded.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let before = ("alpha bravo " as NSString).size(withAttributes: attrs).width
        let word = ("charlie" as NSString).size(withAttributes: attrs).width
        let local = NSPoint(x: 2 + before + word / 2, y: field.bounds.midY)
        let point = field.convert(local, to: nil)

        let result = try guarded(window, at: point) {
            try AppControlMouse.click(in: window, at: point, count: 2)
        }

        XCTAssertFalse(result.watchdogFired,
                       "double-click parked in the nested tracking loop until the watchdog released it")
        XCTAssertLessThan(result.elapsed, promptly, "double-click took \(result.elapsed)s to return")
        guard let editor = field.currentEditor() as? NSTextView else {
            return XCTFail("the label is not being edited after a double-click, so nothing is selected")
        }
        XCTAssertGreaterThan(editor.selectedRange.length, 0, "double-click left an empty selection")
        // A double-click selects words, not characters. Whatever the tracking loop then
        // does with the mouse-up, the selection must start and end on word boundaries
        // and include the word that was clicked.
        let ns = editor.string as NSString
        let range = editor.selectedRange
        let selected = ns.substring(with: range)
        XCTAssertTrue(selected.contains("charlie"), "double-click on \"charlie\" selected \"\(selected)\"")
        let startsAWord = range.location == 0 || ns.character(at: range.location - 1) == unichar(32)
        let endsAWord = NSMaxRange(range) == ns.length || ns.character(at: NSMaxRange(range)) == unichar(32)
        XCTAssertTrue(startsAWord && endsAWord, "double-click selected part of a word: \"\(selected)\"")
    }

    // (b) A single click on a button fires its action exactly once, and returns.
    func testSingleClickOnAButtonFiresItsActionOnceAndReturnsPromptly() throws {
        let window = makeOffscreenWindow()
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        let counter = ClickCounter()
        let button = NSButton(title: "Go", target: counter, action: #selector(ClickCounter.fire(_:)))
        button.frame = NSRect(x: 50, y: 50, width: 120, height: 32)
        window.contentView!.addSubview(button)
        let point = windowCentre(of: button)

        let result = try guarded(window, at: point) {
            try AppControlMouse.click(in: window, at: point)
        }

        XCTAssertFalse(result.watchdogFired, "click parked in the button's tracking loop until the watchdog released it")
        XCTAssertLessThan(result.elapsed, promptly, "click took \(result.elapsed)s to return")
        XCTAssertEqual(counter.count, 1, "the button's action must fire exactly once per click")
    }

    // (c) A plain view sees the down, then the up, with the click count, and nothing is left queued.
    func testClickDeliversDownThenUpToAPlainViewAndLeavesNothingQueued() throws {
        let (window, view) = makeRecorder()
        let point = windowCentre(of: view)

        let result = try guarded(window, at: point) {
            try AppControlMouse.click(in: window, at: point)
        }

        XCTAssertFalse(result.watchdogFired)
        XCTAssertEqual(view.log.map(\.kind), ["down", "up"], "view saw \(view.log.map(\.kind))")
        XCTAssertEqual(view.log.map(\.clickCount), [1, 1])
        let leftovers = drainMouseEvents(for: window)
        XCTAssertTrue(leftovers.isEmpty,
                      "click left \(leftovers.map { "\($0.type)" }) queued; the next real event would see them")
    }

    func testDoubleClickDeliversTwoCompleteClicksWithIncreasingClickCounts() throws {
        let (window, view) = makeRecorder()
        let point = windowCentre(of: view)

        try AppControlMouse.click(in: window, at: point, count: 2)

        XCTAssertEqual(view.log.map(\.kind), ["down", "up", "down", "up"], "view saw \(view.log.map(\.kind))")
        XCTAssertEqual(view.log.map(\.clickCount), [1, 1, 2, 2])
        XCTAssertTrue(drainMouseEvents(for: window).isEmpty)
    }

    func testClickCarriesModifierFlagsOnBothEvents() throws {
        let window = makeOffscreenWindow()
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        final class FlagView: NSView {
            var flags: [NSEvent.ModifierFlags] = []
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func mouseDown(with event: NSEvent) { flags.append(event.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
            override func mouseUp(with event: NSEvent) { flags.append(event.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
        }
        let view = FlagView(frame: NSRect(x: 50, y: 50, width: 100, height: 100))
        window.contentView!.addSubview(view)

        try AppControlMouse.click(in: window, at: windowCentre(of: view), flags: [.shift])

        XCTAssertEqual(view.flags, [.shift, .shift])
    }

    // (d) A drag across selectable text selects it and returns.
    func testDragAcrossASelectableTextViewSelectsTextAndReturnsPromptly() throws {
        let window = makeOffscreenWindow(NSSize(width: 500, height: 200))
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        let tv = FirstMouseTextView(frame: NSRect(x: 20, y: 60, width: 460, height: 80))
        tv.isEditable = false
        tv.isSelectable = true
        tv.string = "The quick brown fox jumps over the lazy dog and keeps on running."
        window.contentView!.addSubview(tv)
        let from = tv.convert(NSPoint(x: 6, y: 8), to: nil)
        let to = tv.convert(NSPoint(x: 200, y: 8), to: nil)

        let result = try guarded(window, at: to) {
            try AppControlMouse.drag(in: window, from: from, to: to)
        }

        XCTAssertFalse(result.watchdogFired, "drag parked in the text view's tracking loop until the watchdog released it")
        XCTAssertLessThan(result.elapsed, promptly, "drag took \(result.elapsed)s to return")
        XCTAssertGreaterThan(tv.selectedRange.length, 0, "dragging across the text selected nothing")
        XCTAssertTrue(drainMouseEvents(for: window).isEmpty, "drag left mouse events queued")
    }

    func testDragAcrossASelectableLabelSelectsTextAndReturnsPromptly() throws {
        let window = makeOffscreenWindow(NSSize(width: 500, height: 120))
        addTeardownBlock { _ = drainMouseEvents(for: window); window.close() }
        let field = FirstMouseTextField(labelWithString: "The quick brown fox jumps over the lazy dog")
        field.isSelectable = true
        field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: 10, y: 50, width: 480, height: 20)
        window.contentView!.addSubview(field)
        let from = field.convert(NSPoint(x: 4, y: field.bounds.midY), to: nil)
        let to = field.convert(NSPoint(x: 150, y: field.bounds.midY), to: nil)

        let result = try guarded(window, at: to) {
            try AppControlMouse.drag(in: window, from: from, to: to)
        }

        XCTAssertFalse(result.watchdogFired)
        XCTAssertLessThan(result.elapsed, promptly)
        let editor = field.currentEditor() as? NSTextView
        XCTAssertNotNil(editor, "dragging across a selectable label should leave it being edited")
        XCTAssertGreaterThan(editor?.selectedRange.length ?? 0, 0, "dragging across the label selected nothing")
    }

    func testDragDeliversDownThenDraggedThenUpInOrderWithOneEventNumber() throws {
        let (window, view) = makeRecorder()
        let from = view.convert(NSPoint(x: 10, y: 10), to: nil)
        let to = view.convert(NSPoint(x: 150, y: 80), to: nil)

        let result = try guarded(window, at: to) {
            try AppControlMouse.drag(in: window, from: from, to: to)
        }

        XCTAssertFalse(result.watchdogFired)
        let kinds = view.log.map(\.kind)
        XCTAssertEqual(kinds.first, "down", "gesture must start with the mouse-down: \(kinds)")
        XCTAssertEqual(kinds.last, "up", "gesture must end with the mouse-up: \(kinds)")
        XCTAssertGreaterThanOrEqual(kinds.filter { $0 == "drag" }.count, 1, "no dragged events delivered: \(kinds)")
        XCTAssertEqual(kinds.filter { $0 == "down" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "up" }.count, 1)
        XCTAssertEqual(kinds, ["down"] + Array(repeating: "drag", count: max(kinds.count - 2, 0)) + ["up"],
                       "events out of order: \(kinds)")
        let stamps = view.log.map(\.timestamp)
        XCTAssertEqual(stamps, stamps.sorted(), "timestamps must not go backwards: \(stamps)")
        XCTAssertEqual(Set(view.log.map(\.eventNumber)).count, 1,
                       "one gesture must share one event number: \(view.log.map(\.eventNumber))")
        XCTAssertTrue(drainMouseEvents(for: window).isEmpty)
    }

    func testSuccessiveGesturesDoNotShareAnEventNumber() throws {
        let (window, view) = makeRecorder()
        let p = windowCentre(of: view)
        try AppControlMouse.click(in: window, at: p)
        try AppControlMouse.click(in: window, at: p)
        let numbers = view.log.map(\.eventNumber)
        guard numbers.count == 4 else { return XCTFail("expected two complete clicks, saw \(view.log.map(\.kind))") }
        XCTAssertNotEqual(numbers[0], numbers[2], "two clicks reused one event number: \(numbers)")
        XCTAssertEqual(numbers[0], numbers[1])
        XCTAssertEqual(numbers[2], numbers[3])
    }

    // (e) Timestamps strictly increase.
    func testClickTimestampsIncreaseStrictlyDownToUp() throws {
        let (window, view) = makeRecorder()
        try AppControlMouse.click(in: window, at: windowCentre(of: view))
        let stamps = view.log.map(\.timestamp)
        guard stamps.count == 2 else { return XCTFail("expected a down and an up, saw \(view.log.map(\.kind))") }
        XCTAssertLessThan(stamps[0], stamps[1], "mouse-up must be later than mouse-down: \(stamps)")
    }

    func testDoubleClickTimestampsIncreaseStrictlyAcrossBothClicks() throws {
        // Repeat: the second click is built straight after the first, so a timestamp
        // scheme that is only "close to now" can overlap by a sliver.
        var violations: [String] = []
        for attempt in 1...20 {
            let (window, view) = makeRecorder()
            try AppControlMouse.click(in: window, at: windowCentre(of: view), count: 2)
            let stamps = view.log.map(\.timestamp)
            guard stamps.count == 4 else { return XCTFail("attempt \(attempt): saw \(view.log.map(\.kind))") }
            for i in 1..<stamps.count where stamps[i - 1] >= stamps[i] {
                violations.append("attempt \(attempt): \(view.log[i].kind) #\(i) at \(stamps[i]) is not later than \(view.log[i - 1].kind) #\(i - 1) at \(stamps[i - 1])")
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "\(violations.count) of 20 double-clicks had non-increasing timestamps; first: \(violations.first ?? "")")
    }
}

// MARK: - Foreign mouse events and the drag step clamp

/// Every mouse event still queued, whatever window it was for. Used to prove that a
/// gesture left someone else's events alone.
private func drainAllMouseEvents() -> [NSEvent] {
    var out: [NSEvent] = []
    let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
    while let e = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
        out.append(e)
    }
    return out
}

/// An event that is not part of the gesture under test: what the operator's real
/// mouse-up (or a drag meant for another window or a sheet) looks like in the queue.
/// Small event numbers and an earlier timestamp, like the window server's.
private func foreignEvent(_ type: NSEvent.EventType, window: NSWindow, at point: NSPoint,
                          eventNumber: Int, age: TimeInterval = 5) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime - age,
                       windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
                       clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
}

/// A number no gesture in this process will have handed out.
private let foreignNumberA = 0x2BAD
private let foreignNumberB = 0x2BAE
private let foreignNumberC = 0x2BAF

/// The synthetic gesture is app-wide-queue based, so it must take only its own events
/// out of the queue. Anything else -- the operator's own mouse-up, a drag for a sheet
/// or another window -- has to come back out of the call exactly as it went in.
final class AppControlMouseForeignEventTests: XCTestCase {

    private func makeRecorder() -> (NSWindow, RecordingView) {
        let window = makeOffscreenWindow()
        addTeardownBlock { _ = drainAllMouseEvents(); window.close() }
        let view = RecordingView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
        window.contentView!.addSubview(view)
        return (window, view)
    }

    private func makeSecondWindow() -> NSWindow {
        let w = makeOffscreenWindow(NSSize(width: 300, height: 200))
        addTeardownBlock { w.close() }
        return w
    }

    /// Asserts `event` came back out of the queue the way it went in.
    private func assertUnchanged(_ event: NSEvent?, type: NSEvent.EventType, windowNumber: Int,
                                 eventNumber: Int, location: NSPoint, _ message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let event else { return XCTFail("\(message): the event is gone from the queue", file: file, line: line) }
        XCTAssertEqual(event.type, type, message, file: file, line: line)
        XCTAssertEqual(event.windowNumber, windowNumber, "\(message): window number changed", file: file, line: line)
        XCTAssertEqual(event.eventNumber, eventNumber, "\(message): event number changed", file: file, line: line)
        XCTAssertEqual(event.locationInWindow.x, location.x, accuracy: 0.5, "\(message): location changed", file: file, line: line)
        XCTAssertEqual(event.locationInWindow.y, location.y, accuracy: 0.5, "\(message): location changed", file: file, line: line)
    }

    // MARK: a mouse-up for another window

    func testAMouseUpQueuedForAnotherWindowIsNotDeliveredToTheClickedView() throws {
        let (window, view) = makeRecorder()
        let other = makeSecondWindow()
        let foreignPoint = NSPoint(x: 120, y: 80)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: other, at: foreignPoint, eventNumber: foreignNumberA),
                        atStart: false)

        try AppControlMouse.click(in: window, at: windowCentre(of: view))

        XCTAssertEqual(view.log.map(\.kind), ["down", "up"],
                       "the clicked view saw \(view.log.map(\.kind)); the other window's mouse-up leaked into this click")
        let left = drainAllMouseEvents()
        XCTAssertEqual(left.count, 1, "the click left \(left.map { "\($0.type.rawValue)@win\($0.windowNumber)" }) queued; expected exactly the other window's mouse-up")
        assertUnchanged(left.first, type: .leftMouseUp, windowNumber: other.windowNumber,
                        eventNumber: foreignNumberA, location: foreignPoint,
                        "the other window's mouse-up must stay queued for its own window")
    }

    // MARK: a mouse-up for the same window that is not this gesture's

    func testAMouseUpFromAnotherGestureOnTheSameWindowIsNotDeliveredToTheClickedView() throws {
        let (window, view) = makeRecorder()
        let foreignPoint = NSPoint(x: 77, y: 66)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: window, at: foreignPoint, eventNumber: foreignNumberA),
                        atStart: false)

        try AppControlMouse.click(in: window, at: windowCentre(of: view))

        XCTAssertEqual(view.log.map(\.kind), ["down", "up"],
                       "the clicked view saw \(view.log.map(\.kind)); the operator's own mouse-up was swallowed by the synthetic click")
        let left = drainAllMouseEvents()
        XCTAssertEqual(left.count, 1, "the click left \(left.map { "\($0.type.rawValue)#\($0.eventNumber)" }) queued; expected exactly the operator's mouse-up")
        assertUnchanged(left.first, type: .leftMouseUp, windowNumber: window.windowNumber,
                        eventNumber: foreignNumberA, location: foreignPoint,
                        "the operator's own mouse-up must stay queued")
    }

    func testAForeignMouseUpAlsoSurvivesADoubleClick() throws {
        let (window, view) = makeRecorder()
        let other = makeSecondWindow()
        let foreignPoint = NSPoint(x: 31, y: 41)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: other, at: foreignPoint, eventNumber: foreignNumberA),
                        atStart: false)

        try AppControlMouse.click(in: window, at: windowCentre(of: view), count: 2)

        XCTAssertEqual(view.log.map(\.kind), ["down", "up", "down", "up"], "view saw \(view.log.map(\.kind))")
        let left = drainAllMouseEvents()
        XCTAssertEqual(left.count, 1, "left \(left.map { "\($0.type.rawValue)#\($0.eventNumber)" })")
        assertUnchanged(left.first, type: .leftMouseUp, windowNumber: other.windowNumber,
                        eventNumber: foreignNumberA, location: foreignPoint, "the foreign mouse-up")
    }

    // MARK: dragged events

    func testForeignDraggedEventsAreNotDeliveredToTheDraggedView() throws {
        let (window, view) = makeRecorder()
        let other = makeSecondWindow()
        let otherPoint = NSPoint(x: 10, y: 20)
        let samePoint = NSPoint(x: 15, y: 25)
        NSApp.postEvent(foreignEvent(.leftMouseDragged, window: other, at: otherPoint, eventNumber: foreignNumberA), atStart: false)
        NSApp.postEvent(foreignEvent(.leftMouseDragged, window: window, at: samePoint, eventNumber: foreignNumberB), atStart: false)

        let from = view.convert(NSPoint(x: 10, y: 10), to: nil)
        let to = view.convert(NSPoint(x: 150, y: 80), to: nil)
        try AppControlMouse.drag(in: window, from: from, to: to, steps: 8)

        let kinds = view.log.map(\.kind)
        XCTAssertEqual(kinds, ["down"] + Array(repeating: "drag", count: 8) + ["up"],
                       "the dragged view saw \(kinds); foreign dragged events must not be delivered to it")
        let left = drainAllMouseEvents()
        XCTAssertEqual(left.count, 2, "expected the two foreign dragged events to stay queued, found \(left.map { "\($0.type.rawValue)#\($0.eventNumber)" })")
        assertUnchanged(left.first, type: .leftMouseDragged, windowNumber: other.windowNumber,
                        eventNumber: foreignNumberA, location: otherPoint, "first foreign drag")
        assertUnchanged(left.last, type: .leftMouseDragged, windowNumber: window.windowNumber,
                        eventNumber: foreignNumberB, location: samePoint, "second foreign drag")
    }

    // MARK: order

    func testForeignEventsComeBackInTheirOriginalOrderAheadOfAnythingQueuedLater() throws {
        let (window, view) = makeRecorder()
        let other = makeSecondWindow()
        let p1 = NSPoint(x: 11, y: 12), p2 = NSPoint(x: 21, y: 22), p3 = NSPoint(x: 31, y: 32)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: other, at: p1, eventNumber: foreignNumberA), atStart: false)
        NSApp.postEvent(foreignEvent(.leftMouseDragged, window: other, at: p2, eventNumber: foreignNumberB), atStart: false)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: window, at: p3, eventNumber: foreignNumberC), atStart: false)

        try AppControlMouse.click(in: window, at: windowCentre(of: view))
        // Something arriving after the gesture must queue up behind what was put back.
        let later = NSPoint(x: 41, y: 42)
        NSApp.postEvent(foreignEvent(.leftMouseUp, window: other, at: later, eventNumber: 0x2BB0, age: 0), atStart: false)

        XCTAssertEqual(view.log.map(\.kind), ["down", "up"], "view saw \(view.log.map(\.kind))")
        let left = drainAllMouseEvents()
        XCTAssertEqual(left.count, 4, "expected 3 foreign events and the later one, found \(left.map { "\($0.type.rawValue)#\($0.eventNumber)" })")
        guard left.count == 4 else { return }
        assertUnchanged(left[0], type: .leftMouseUp, windowNumber: other.windowNumber, eventNumber: foreignNumberA, location: p1, "1st foreign event (first in)")
        assertUnchanged(left[1], type: .leftMouseDragged, windowNumber: other.windowNumber, eventNumber: foreignNumberB, location: p2, "2nd foreign event")
        assertUnchanged(left[2], type: .leftMouseUp, windowNumber: window.windowNumber, eventNumber: foreignNumberC, location: p3, "3rd foreign event")
        assertUnchanged(left[3], type: .leftMouseUp, windowNumber: other.windowNumber, eventNumber: 0x2BB0, location: later, "the event queued after the gesture")
    }

    func testAnOrdinaryClickAndDragStillLeaveNothingQueued() throws {
        let (window, view) = makeRecorder()
        try AppControlMouse.click(in: window, at: windowCentre(of: view))
        try AppControlMouse.drag(in: window, from: view.convert(NSPoint(x: 5, y: 5), to: nil),
                                 to: view.convert(NSPoint(x: 100, y: 60), to: nil))
        XCTAssertEqual(view.log.map(\.kind).first, "down")
        XCTAssertEqual(view.log.map(\.kind).filter { $0 == "up" }.count, 2)
        XCTAssertTrue(drainAllMouseEvents().isEmpty, "a plain gesture left events queued")
    }

    // MARK: --steps clamp

    private func draggedEventCount(steps: Int) throws -> (kinds: [String], leftovers: Int) {
        let (window, view) = makeRecorder()
        let from = view.convert(NSPoint(x: 10, y: 10), to: nil)
        let to = view.convert(NSPoint(x: 190, y: 90), to: nil)
        try AppControlMouse.drag(in: window, from: from, to: to, steps: steps)
        return (view.log.map(\.kind), drainAllMouseEvents().count)
    }

    func testAnAbsurdlyLargeStepCountIsClampedToTwoHundredDraggedEvents() throws {
        let r = try draggedEventCount(steps: 100_000)
        XCTAssertEqual(r.kinds.filter { $0 == "drag" }.count, 200, "100000 steps delivered \(r.kinds.filter { $0 == "drag" }.count) dragged events")
        XCTAssertEqual(r.kinds.first, "down")
        XCTAssertEqual(r.kinds.last, "up")
        XCTAssertEqual(r.kinds.count, 202)
        XCTAssertEqual(r.leftovers, 0)
    }

    func testTwoHundredStepsIsAllowedInFull() throws {
        let r = try draggedEventCount(steps: 200)
        XCTAssertEqual(r.kinds.filter { $0 == "drag" }.count, 200)
        XCTAssertEqual(r.kinds.count, 202)
    }

    func testAZeroNegativeOrSingleStepCountStillDeliversExactlyOneDraggedEvent() throws {
        for steps in [0, -5, 1] {
            let r = try draggedEventCount(steps: steps)
            XCTAssertEqual(r.kinds, ["down", "drag", "up"], "steps: \(steps) delivered \(r.kinds)")
            XCTAssertEqual(r.leftovers, 0, "steps: \(steps)")
        }
    }
}

// MARK: - hittest report

private final class UnderlyingView: NSView {}
/// A full-size overlay that, unlike `JumpToLatestOverlay`, takes every hit itself.
private final class BlockingOverlay: NSView {}

/// `AppControlHitTest.report` answers "what would a mouse-down at this point land on,
/// and can it select text?" for the socket's `hittest` verb. It exists so a "this
/// text cannot be selected" report can be diagnosed in the running app without
/// clicking in it, so it must be accurate and strictly read-only.
final class AppControlHitTestTests: XCTestCase {

    private let markdown = "A first paragraph with enough words in it that it wraps onto a second line at this width, "
        + "and keeps going a little longer for good measure.\n\nSecond paragraph."

    private struct Card {
        let window: RigWindow
        let card: MarkdownCardView
        let textView: NSTextView
        var content: NSView { window.contentView! }
        /// A point inside the first line of the paragraph, in window coordinates.
        var firstLinePoint: NSPoint { textView.convert(NSPoint(x: 20, y: 8), to: nil) }
    }

    private func makeCard(width: CGFloat = 500) throws -> Card {
        let window = makeRigWindow(self)
        let card = MarkdownCardView(markdown: markdown)
        card.presetWidth = width
        let height = MarkdownCardView.measuredHeight(markdown: markdown, width: width)
        card.frame = NSRect(x: 40, y: 300, width: width, height: height)
        window.contentView!.addSubview(card)
        window.contentView!.layoutSubtreeIfNeeded()
        rigSettle()
        let tv = try XCTUnwrap(rigAllSubviews(of: card).compactMap { $0 as? NSTextView }.first,
                               "no text view in the card")
        return Card(window: window, card: card, textView: tv)
    }

    private func chain(_ report: [String: Any]) -> [[String: Any]] { (report["chain"] as? [[String: Any]]) ?? [] }
    private func classes(_ report: [String: Any]) -> [String] { chain(report).compactMap { $0["class"] as? String } }
    private func windowSection(_ report: [String: Any]) -> [String: Any] { (report["window"] as? [String: Any]) ?? [:] }

    private func typeName(_ v: AnyObject) -> String { String(describing: type(of: v)) }

    /// The class names a mouse-down on `hit` should be reported with: the hit view and
    /// each superview in order, up to and including the window's content view.
    private func expectedChain(from hit: NSView, upTo content: NSView) -> [String] {
        var out: [String] = []
        var cur: NSView? = hit
        while let c = cur {
            out.append(typeName(c))
            if c === content { break }
            cur = c.superview
        }
        return out
    }

    // MARK: the hit view

    func testAPointOverACardParagraphReportsItsSelectableTextView() throws {
        let c = try makeCard()
        let report = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)

        XCTAssertEqual(report["hit"] as? String, "NSTextView", "hit \(classes(report))")
        let first = try XCTUnwrap(chain(report).first)
        XCTAssertEqual(first["class"] as? String, "NSTextView")
        XCTAssertEqual(first["isSelectable"] as? Bool, true)
        XCTAssertEqual(first["isEditable"] as? Bool, false)
        XCTAssertEqual(first["isFieldEditor"] as? Bool, false)
        XCTAssertEqual(first["isHidden"] as? Bool, false)
        XCTAssertEqual(first["alphaValue"] as? Double, 1.0)
        XCTAssertNotNil(first["acceptsFirstResponder"] as? Bool, "acceptsFirstResponder missing")
        XCTAssertNotNil(first["needsLayout"] as? Bool, "needsLayout missing")
        let range = try XCTUnwrap(first["selectedRange"] as? [String: Int], "selectedRange missing: \(first)")
        XCTAssertNotNil(range["location"])
        XCTAssertNotNil(range["length"])
    }

    func testTheReportedSelectionAndFirstResponderFollowTheTextView() throws {
        let c = try makeCard()
        XCTAssertFalse(c.window.firstResponder === c.textView, "precondition")
        let before = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)
        XCTAssertEqual(chain(before).first?["isFirstResponder"] as? Bool, false)

        XCTAssertTrue(c.window.makeFirstResponder(c.textView))
        c.textView.setSelectedRange(NSRange(location: 4, length: 9))
        let after = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)

        XCTAssertEqual(chain(after).first?["isFirstResponder"] as? Bool, true)
        let range = chain(after).first?["selectedRange"] as? [String: Int]
        XCTAssertEqual(range?["location"], 4)
        XCTAssertEqual(range?["length"], 9)
        XCTAssertEqual(windowSection(after)["firstResponder"] as? String, "NSTextView")
    }

    func testTheChainRunsFromTheHitViewUpThroughEachSuperviewToTheContentView() throws {
        let c = try makeCard()
        let report = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)

        XCTAssertEqual(classes(report), expectedChain(from: c.textView, upTo: c.content),
                       "chain must be the hit view and then each superview in order")
        XCTAssertEqual(classes(report).dropFirst().first, "MarkdownCardView")
        XCTAssertEqual(classes(report).last, typeName(c.content), "chain must end at the window's content view")
    }

    func testReportedFramesAreTopLeftOriginRectsInTheWindowContent() throws {
        let c = try makeCard()
        let report = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)
        let frame = try XCTUnwrap(chain(report).first?["frame"] as? [String: Double])

        let inWindow = c.textView.convert(c.textView.bounds, to: nil)
        XCTAssertEqual(try XCTUnwrap(frame["x"]), inWindow.minX, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frame["y"]), c.content.bounds.height - inWindow.maxY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frame["w"]), inWindow.width, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frame["h"]), inWindow.height, accuracy: 0.5)
    }

    func testAPointOverASelectableLabelReportsTheLabelAndItsEditingState() throws {
        let window = makeRigWindow(self)
        let label = CopyMenuTextField(labelWithString: "A selectable label with some words in it")
        label.isSelectable = true
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 30, y: 200, width: 400, height: 20)
        window.contentView!.addSubview(label)
        window.contentView!.layoutSubtreeIfNeeded()
        let point = label.convert(NSPoint(x: 6, y: label.bounds.midY), to: nil)

        let idle = AppControlHitTest.report(in: window, at: point)
        let first = try XCTUnwrap(chain(idle).first)
        XCTAssertEqual(first["class"] as? String, "CopyMenuTextField", "hit \(classes(idle))")
        XCTAssertEqual(first["isSelectable"] as? Bool, true)
        XCTAssertEqual(first["isEditable"] as? Bool, false)
        XCTAssertEqual(first["isEditing"] as? Bool, false)
        XCTAssertNil(first["isFieldEditor"], "a label is not a text view")

        label.selectText(nil)
        let editing = AppControlHitTest.report(in: window, at: point)
        // While it is being edited the field editor sits over the label and takes the hit.
        let editor = try XCTUnwrap(chain(editing).first)
        XCTAssertEqual(editor["isFieldEditor"] as? Bool, true, "hit \(classes(editing))")
        XCTAssertEqual(editor["isFirstResponder"] as? Bool, true)
        let owner = try XCTUnwrap(chain(editing).dropFirst().first)
        XCTAssertEqual(owner["class"] as? String, "CopyMenuTextField")
        XCTAssertEqual(owner["isEditing"] as? Bool, true)
    }

    // MARK: overlays

    private struct Stack {
        let window: RigWindow
        let base: UnderlyingView
        var content: NSView { window.contentView! }
    }

    private func makeStack() -> Stack {
        let window = makeRigWindow(self, size: NSSize(width: 400, height: 300))
        let base = UnderlyingView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(base)
        return Stack(window: window, base: base)
    }

    func testAPointOutsideTheJumpPillReportsTheViewBelowNotTheOverlay() throws {
        let s = makeStack()
        let overlay = JumpToLatestOverlay(frame: s.content.bounds)
        s.content.addSubview(overlay)
        overlay.setFollowingTail(false)
        s.content.layoutSubtreeIfNeeded()

        let report = AppControlHitTest.report(in: s.window, at: NSPoint(x: 20, y: 150))

        XCTAssertEqual(report["hit"] as? String, "UnderlyingView", "chain \(classes(report))")
        XCTAssertFalse(classes(report).contains("JumpToLatestOverlay"),
                       "a pass-through overlay is not in the hit chain: \(classes(report))")
    }

    func testAPointOnTheJumpPillReportsTheButton() throws {
        let s = makeStack()
        let overlay = JumpToLatestOverlay(frame: s.content.bounds)
        s.content.addSubview(overlay)
        overlay.setFollowingTail(false)
        s.content.layoutSubtreeIfNeeded()
        let pill = overlay.button.convert(NSPoint(x: overlay.button.bounds.midX, y: overlay.button.bounds.midY), to: nil)

        let report = AppControlHitTest.report(in: s.window, at: pill)

        XCTAssertEqual(report["hit"] as? String, "NSButton", "chain \(classes(report))")
        XCTAssertEqual(classes(report).dropFirst().first, "JumpToLatestOverlay")
    }

    func testAHiddenJumpPillLetsThePointFallThroughToTheViewBelow() throws {
        let s = makeStack()
        let overlay = JumpToLatestOverlay(frame: s.content.bounds)
        s.content.addSubview(overlay)
        overlay.setFollowingTail(true)   // following the tail: the pill is hidden
        s.content.layoutSubtreeIfNeeded()
        let pill = overlay.button.convert(NSPoint(x: overlay.button.bounds.midX, y: overlay.button.bounds.midY), to: nil)

        let report = AppControlHitTest.report(in: s.window, at: pill)

        XCTAssertEqual(report["hit"] as? String, "UnderlyingView", "chain \(classes(report))")
    }

    func testAFullSizeBlockingOverlayReportsItself() throws {
        let s = makeStack()
        let overlay = BlockingOverlay(frame: s.content.bounds)
        s.content.addSubview(overlay)

        let report = AppControlHitTest.report(in: s.window, at: NSPoint(x: 200, y: 150))

        XCTAssertEqual(report["hit"] as? String, "BlockingOverlay", "chain \(classes(report))")
        XCTAssertEqual(classes(report), ["BlockingOverlay", typeName(s.content)])
    }

    // MARK: nothing there

    func testAPointOutsideTheWindowContentReportsNoHitAndAnEmptyChain() throws {
        let s = makeStack()
        let report = AppControlHitTest.report(in: s.window, at: NSPoint(x: -500, y: -500))
        XCTAssertEqual(report["hit"] as? String, "none")
        XCTAssertTrue(chain(report).isEmpty, "chain \(classes(report))")
        XCTAssertNotNil(report["window"] as? [String: Any], "the window section is still reported")
    }

    func testAWindowWithNoContentViewReportsNoHit() throws {
        let window = makeRigWindow(self, size: NSSize(width: 200, height: 100))
        window.contentView = nil
        let report = AppControlHitTest.report(in: window, at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(report["hit"] as? String, "none")
        XCTAssertTrue(chain(report).isEmpty)
    }

    // MARK: window section

    func testTheWindowSectionReportsKeyStateActiveStateAndFirstResponder() throws {
        let c = try makeCard()
        XCTAssertTrue(c.window.makeFirstResponder(c.textView))
        let report = AppControlHitTest.report(in: c.window, at: c.firstLinePoint)
        let w = windowSection(report)

        XCTAssertEqual(w["isKeyWindow"] as? Bool, true, "RigWindow is key")
        XCTAssertEqual(w["appIsActive"] as? Bool, NSApp.isActive)
        XCTAssertEqual(w["firstResponder"] as? String, "NSTextView")
    }

    func testTheWindowSectionSaysSoForAWindowThatIsNotKey() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let report = AppControlHitTest.report(in: window, at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(windowSection(report)["isKeyWindow"] as? Bool, false)
        XCTAssertNotNil(windowSection(report)["firstResponder"] as? String)
    }

    // MARK: read-only

    func testReportingChangesNothingAndSendsNoMouseEvents() throws {
        let c = try makeCard()
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        input.string = "a draft the operator is typing"
        c.content.addSubview(input)
        XCTAssertTrue(c.window.makeFirstResponder(input))
        input.setSelectedRange(NSRange(location: 2, length: 5))
        c.textView.setSelectedRange(NSRange(location: 3, length: 6))   // a leftover selection, not focused
        rigSettle()   // let AppKit create whatever the focused text view lazily adds
        c.window.displayIfNeeded()
        let frames = rigAllSubviews(of: c.content).map(\.frame)
        let responder = c.window.firstResponder
        _ = drainMouseEvents(for: c.window)

        // The card's text view, nothing at all, and the focused input itself.
        for point in [c.firstLinePoint, NSPoint(x: -10, y: -10), NSPoint(x: 5, y: 5)] {
            _ = AppControlHitTest.report(in: c.window, at: point)
            XCTAssertTrue(c.window.firstResponder === responder,
                          "reporting at \(point) moved first responder to \(String(describing: c.window.firstResponder))")
            XCTAssertEqual(c.textView.selectedRange, NSRange(location: 3, length: 6), "reporting at \(point) changed the card's selection")
            XCTAssertEqual(input.selectedRange, NSRange(location: 2, length: 5), "reporting at \(point) changed the input's selection")
            XCTAssertEqual(rigAllSubviews(of: c.content).map(\.frame), frames, "reporting at \(point) moved or resized a view")
            let events = drainAllMouseEvents()
            XCTAssertTrue(events.isEmpty, "reporting at \(point) queued \(events.map { $0.type.rawValue })")
        }
    }
}
