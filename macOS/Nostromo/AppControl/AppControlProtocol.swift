import Foundation
import AppKit

/// Wire protocol for the app's QA control socket (see `AppControlServer`).
///
/// One JSON object per line in, one JSON object per line out:
///   → `{"cmd":"click","window":0,"x":120,"y":40}`
///   ← `{"ok":true,"result":{...}}`  or  `{"ok":false,"error":"..."}`
///
/// Coordinates are **window content coordinates with a top-left origin** (what
/// a screenshot of the window shows), so a point read off a screenshot or the
/// `tree` dump can be fed straight back to `click`.
struct AppControlRequest {
    let cmd: String
    let args: [String: Any]

    static func parse(_ line: String) -> Result<AppControlRequest, AppControlError> {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String, !cmd.isEmpty
        else { return .failure(.badRequest("expected a JSON object with a \"cmd\" string")) }
        return .success(AppControlRequest(cmd: cmd, args: obj))
    }

    func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
    func double(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }
    func string(_ key: String) -> String? { args[key] as? String }
    func strings(_ key: String) -> [String]? { args[key] as? [String] }
}

enum AppControlError: Error, Equatable {
    case badRequest(String)
    case noSuchWindow(Int)
    case notFound(String)
    case failed(String)

    var message: String {
        switch self {
        case .badRequest(let m):  return "bad request: \(m)"
        case .noSuchWindow(let i): return "no window with index \(i)"
        case .notFound(let m):    return "not found: \(m)"
        case .failed(let m):      return m
        }
    }
}

enum AppControlWire {
    static func ok(_ result: Any) -> String { encode(["ok": true, "result": result]) }
    static func fail(_ error: AppControlError) -> String { encode(["ok": false, "error": error.message]) }

    private static func encode(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8)
        else { return "{\"ok\":false,\"error\":\"unencodable response\"}" }
        return s
    }
}

/// Pure geometry/modifier helpers, kept free of AppKit state so they are testable.
enum AppControlGeometry {
    /// Top-left-origin content point → AppKit window point (bottom-left origin).
    static func windowPoint(x: Double, y: Double, contentHeight: Double) -> NSPoint {
        NSPoint(x: x, y: contentHeight - y)
    }

    /// AppKit rect in a view's own coordinates → top-left-origin rect in the
    /// window's content area. `viewFrameInWindow` is the view's frame converted
    /// to window (bottom-left) coordinates.
    static func topLeftRect(viewFrameInWindow r: NSRect, contentHeight: Double) -> [String: Double] {
        ["x": r.minX, "y": contentHeight - r.maxY, "w": r.width, "h": r.height]
    }

    static func modifiers(_ names: [String]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for n in names {
            switch n.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift":          flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: break
            }
        }
        return flags
    }
}

/// Mouse-event synthesis for the control socket's `click` and `drag`.
///
/// Kept apart from `AppControlServer` so a logic test can drive it against real
/// views in an offscreen window.
///
/// ## Why the mouse-up is queued *before* the mouse-down is sent
///
/// `NSWindow.sendEvent(mouseDown)` on a view that tracks the mouse (an
/// `NSControl`, a selectable `NSTextField`, an `NSTextView`) does not return
/// until the gesture ends: AppKit runs a nested loop on `nextEventMatchingMask`
/// that waits for the matching `leftMouseUp`. Sending a down and then an up from
/// the same call stack therefore never reaches the up — the call parks in that
/// loop, the whole app freezes, and it stays frozen until a *real* mouse event
/// arrives. (`sample` shows the main thread in `-[NSTextView mouseDown:]` under
/// `nextEventMatchingMask`.) So the drags and the up are queued first, and the
/// loop finds them. Views that do not track simply handle the down and leave the
/// rest in the queue; `deliverQueuedMouseEvents` then hands those on in order.
enum AppControlMouse {

    /// Monotonic across calls so successive gestures never reuse an event number.
    private static var nextEventNumber = 1
    /// Last timestamp handed out. Each gesture starts at `max(now, last + 1 ms)`,
    /// so the second click of a double-click never starts before the first one's
    /// mouse-up (which is stamped slightly after its down).
    private static var lastTimestamp: TimeInterval = 0

    static func click(in window: NSWindow, at point: NSPoint, flags: NSEvent.ModifierFlags = [],
                      count: Int = 1) throws {
        for clickCount in 1...max(count, 1) {
            let number = takeEventNumber()
            let t = takeTimestamp()
            guard let down = event(.leftMouseDown, window, point, flags, number, clickCount, t),
                  let up = event(.leftMouseUp, window, point, flags, number, clickCount, t + 0.001)
            else { throw AppControlError.failed("could not synthesise mouse events") }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            deliverQueuedMouseEvents(to: window)
        }
    }

    /// Press at `from`, drag through `steps` intermediate points, release at `to`.
    static func drag(in window: NSWindow, from: NSPoint, to: NSPoint, steps: Int = 8,
                     flags: NSEvent.ModifierFlags = []) throws {
        let number = takeEventNumber()
        let n = max(steps, 1)
        let t = takeTimestamp(span: Double(n + 1) * 0.001)
        guard let down = event(.leftMouseDown, window, from, flags, number, 1, t) else {
            throw AppControlError.failed("could not synthesise mouse events")
        }
        var queued: [NSEvent] = []
        for i in 1...n {
            let f = CGFloat(i) / CGFloat(n)
            let p = NSPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f)
            guard let moved = event(.leftMouseDragged, window, p, flags, number, 1, t + 0.001 * Double(i)) else {
                throw AppControlError.failed("could not synthesise mouse events")
            }
            queued.append(moved)
        }
        guard let up = event(.leftMouseUp, window, to, flags, number, 1, t + 0.001 * Double(n + 1)) else {
            throw AppControlError.failed("could not synthesise mouse events")
        }
        queued.append(up)
        for e in queued { NSApp.postEvent(e, atStart: false) }
        window.sendEvent(down)
        deliverQueuedMouseEvents(to: window)
    }

    /// Whatever the down did not consume (it did not track) still goes to the
    /// window, in order, so the call returns with the gesture complete.
    private static func deliverQueuedMouseEvents(to window: NSWindow) {
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        while let e = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(e)
        }
    }

    /// A start time later than every timestamp already handed out, reserving
    /// `span` seconds for the events of this gesture.
    private static func takeTimestamp(span: TimeInterval = 0.001) -> TimeInterval {
        let t = max(ProcessInfo.processInfo.systemUptime, lastTimestamp + 0.001)
        lastTimestamp = t + span
        return t
    }

    private static func takeEventNumber() -> Int {
        defer { nextEventNumber += 1 }
        return nextEventNumber
    }

    private static func event(_ type: NSEvent.EventType, _ window: NSWindow, _ point: NSPoint,
                              _ flags: NSEvent.ModifierFlags, _ number: Int, _ clickCount: Int,
                              _ timestamp: TimeInterval) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: timestamp,
                           windowNumber: window.windowNumber, context: nil, eventNumber: number,
                           clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)
    }
}
