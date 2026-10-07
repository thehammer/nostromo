import Foundation

/// What the Mother daemon is doing, as shown in the Mother pane header.
enum MotherDaemonState: Equatable {
    case unknown                       // not checked yet
    case running(detail: String)       // e.g. "pid 62699, uptime 18:10:13"
    case stopped
    case unavailable(reason: String)   // not queried (e.g. a QA broker is in use)

    /// Parse `mother daemon status`: it prints `running (pid N, uptime …)` and
    /// exits 0 when up; anything else (non-zero exit, other text) means down.
    static func parse(stdout: String, status: Int32) -> MotherDaemonState {
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, text.lowercased().hasPrefix("running") else { return .stopped }
        var detail = String(text.dropFirst("running".count)).trimmingCharacters(in: .whitespaces)
        if detail.hasPrefix("("), detail.hasSuffix(")") { detail = String(detail.dropFirst().dropLast()) }
        return .running(detail: detail)
    }

    var label: String {
        switch self {
        case .unknown:                 return "Mother daemon: checking…"
        case .running:                 return "Mother daemon running"
        case .stopped:                 return "Mother daemon stopped"
        case .unavailable(let reason): return "Mother daemon: \(reason)"
        }
    }

    var isStopped: Bool { self == .stopped }
}
