import Foundation

/// The idle banner's state. The daemon sets `idle_closes_at` at the 13-minute mark (the shell closes
/// two minutes later) and clears it on a keystroke or keep-alive; output alone changes nothing.
enum IdleCountdownModel {

    enum State: Equatable {
        case hidden
        case counting(secondsLeft: Int)
    }

    static func state(idleClosesAt: String?, now: Date) -> State {
        guard let closesAt = idleClosesAt.flatMap(parse) else { return .hidden }
        return .counting(secondsLeft: max(0, Int(closesAt.timeIntervalSince(now).rounded(.up))))
    }

    /// "Closing in 1:59 (no keystrokes for 13 minutes)".
    static func text(secondsLeft: Int) -> String {
        let s = max(0, secondsLeft)
        return String(format: "Closing in %d:%02d (no keystrokes for 13 minutes)", s / 60, s % 60)
    }

    private static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
