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
