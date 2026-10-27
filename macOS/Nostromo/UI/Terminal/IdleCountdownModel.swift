import Foundation

/// The idle banner's state. The daemon sets `idle_closes_at` at its warning mark (13 minutes without
/// a keystroke; the shell closes two minutes later) and clears it on a keystroke or keep-alive;
/// output alone changes nothing.
enum IdleCountdownModel {

    enum State: Equatable {
        case hidden
        case counting(secondsLeft: Int)
    }

    static func state(idleClosesAt: String?, now: Date) -> State {
        guard let closesAt = idleClosesAt.flatMap(parse) else { return .hidden }
        return .counting(secondsLeft: max(0, Int(closesAt.timeIntervalSince(now).rounded(.up))))
    }

    /// "Closing in 1:59 (no keystrokes for 13 minutes)". `warnAfterSecs` is the daemon's own warning
    /// threshold (`TerminalInfo.idleWarnAfterSecs`), so a daemon that runs a shorter clock says so;
    /// without it (an older daemon) the text claims no figure.
    static func text(secondsLeft: Int, warnAfterSecs: Int? = nil) -> String {
        let s = max(0, secondsLeft)
        let idle = warnAfterSecs.map { duration($0) } ?? "a while"
        return String(format: "Closing in %d:%02d (no keystrokes for %@)", s / 60, s % 60, idle)
    }

    /// "13 minutes", "1 minute", "2 minutes 10 seconds", "20 seconds".
    static func duration(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let (minutes, rest) = (total / 60, total % 60)
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        if minutes == 0 { return unit(rest, "second") }
        return rest == 0 ? unit(minutes, "minute") : unit(minutes, "minute") + " " + unit(rest, "second")
    }

    // One formatter each, built once: the banner parses a time every second for every remote pane.
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    private static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }
}
