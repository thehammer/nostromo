import Foundation

/// Jira ticket keys arrive from the daemon, but a pane's content can be pushed by an agent, so every
/// key is checked before it is drawn or put in a URL.
public enum TicketKeys {
    /// The most keys one PR row offers.
    public static let maxKeys = 5
    /// The most digits a key's number has: a longer one is not a key.
    public static let maxDigits = 10

    /// `[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,9}` (ASCII only).
    public static func isValid(_ key: String) -> Bool {
        let parts = key.utf8.split(separator: UInt8(ascii: "-"), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let prefix = Array(parts[0]), number = Array(parts[1])
        func upper(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
        func digit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
        return (2...10).contains(prefix.count)
            && upper(prefix[0])
            && prefix.allSatisfy { upper($0) || digit($0) }
            && (1...maxDigits).contains(number.count)
            && number[0] != 48
            && number.allSatisfy(digit)
    }

    /// The well-formed keys of `keys`, first appearance wins, at most `maxKeys`.
    public static func sanitize(_ keys: [String]) -> [String] {
        var out: [String] = []
        for key in keys where isValid(key) && !out.contains(key) {
            out.append(key)
            if out.count == maxKeys { break }
        }
        return out
    }
}
