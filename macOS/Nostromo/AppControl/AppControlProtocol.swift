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
