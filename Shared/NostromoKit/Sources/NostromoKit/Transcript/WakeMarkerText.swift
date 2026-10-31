import Foundation

/// What a muted marker in the transcript's user slot says, and where a click on it goes.
///
/// A marker stands in for a turn the user did not type but the agent received (a Mother job notice
/// today; a background-task wake later). The text is built here, once, and drawn as plain text:
/// every mark (`⟲`, the quotes, the state words, `PR #n`) is computed by the app, and the only
/// untrusted text, a job's title, sits inside the quotes after `FoldTextSanitizer` and a cap. So a
/// title cannot draw a second marker, a badge or a tick of its own.
public struct WakeMarkerContent: Equatable {
    /// The one line drawn in the transcript.
    public let line: String
    /// The tooltip, one entry per line.
    public let tooltipLines: [String]
    public let accessibilityLabel: String
    public let target: WakeMarkerTarget

    public init(line: String, tooltipLines: [String], accessibilityLabel: String, target: WakeMarkerTarget) {
        self.line = line
        self.tooltipLines = tooltipLines
        self.accessibilityLabel = accessibilityLabel
        self.target = target
    }
}

/// What a click on a marker opens.
public enum WakeMarkerTarget: Equatable {
    case motherJob(id: String)
    /// Several jobs: the first one opens, with the Mother focus's list in view.
    case motherJobs(ids: [String])
    case none
}

public enum WakeMarkerText {

    /// The marker mark every line starts with.
    public static let mark = "⟲"

    /// Longest title in the one-line marker, ellipsis included.
    public static let lineTitleLimit = 80
    /// Longest title in a tooltip or accessibility line, ellipsis included.
    public static let tooltipTitleLimit = 120
    /// Most jobs listed in a tooltip; the rest are counted.
    public static let tooltipJobLimit = 20

    /// Longest unknown state shown as text.
    private static let stateLimit = 24

    /// The marker for a Mother job notice.
    public static func motherNotice(_ items: [MotherNoticeItemWire]) -> WakeMarkerContent {
        guard let first = items.first else {
            return WakeMarkerContent(line: "\(mark) Mother update", tooltipLines: [],
                                     accessibilityLabel: "Mother update.", target: .none)
        }
        if items.count == 1 {
            let tooltip = detail(first, titleLimit: tooltipTitleLimit)
            let pull = first.prNumber.map { ", pull request \($0)" } ?? ""
            return WakeMarkerContent(
                line: "\(mark) Mother: \"\(title(first, limit: lineTitleLimit))\" \(stateWords(first.state))\(prSuffix(first))",
                tooltipLines: [tooltip],
                accessibilityLabel: "Mother update: \(title(first, limit: tooltipTitleLimit)) \(stateWords(first.state))\(pull).",
                target: .motherJob(id: first.jobId))
        }
        var lines = items.prefix(tooltipJobLimit).map { detail($0, titleLimit: tooltipTitleLimit) }
        if items.count > tooltipJobLimit { lines.append("…and \(items.count - tooltipJobLimit) more") }
        return WakeMarkerContent(
            line: "\(mark) \(items.count) Mother updates",
            tooltipLines: lines,
            accessibilityLabel: "\(items.count) Mother updates. " + lines.joined(separator: "; "),
            target: .motherJobs(ids: items.map(\.jobId)))
    }

    // MARK: Pieces

    /// `"<title>" <state words>` (· PR #n).
    private static func detail(_ item: MotherNoticeItemWire, titleLimit: Int) -> String {
        "\"\(title(item, limit: titleLimit))\" \(stateWords(item.state))\(prSuffix(item))"
    }

    private static func prSuffix(_ item: MotherNoticeItemWire) -> String {
        item.prNumber.map { " · PR #\($0)" } ?? ""
    }

    private static func title(_ item: MotherNoticeItemWire, limit: Int) -> String {
        let clean = FoldTextSanitizer.sanitize(item.title).trimmingCharacters(in: .whitespaces)
        return capped(clean.isEmpty ? "Untitled job" : clean, to: limit)
    }

    /// `state` as words. An unknown state is shown as text, but only as plain words (letters,
    /// digits, spaces, `-`), so it cannot carry a mark either.
    static func stateWords(_ state: String) -> String {
        switch state {
        case "succeeded": return "succeeded"
        case "failed": return "failed"
        case "cancelled", "canceled": return "cancelled"
        case "awaiting": return "needs you"
        case "pr_merged": return "PR merged"
        case "pr_opened": return "PR opened"
        case "running": return "running"
        case "queued": return "queued"
        default:
            return plainWords(state)
        }
    }

    /// An unknown state as plain words: ASCII letters, digits, spaces and `-` only (`_` is a space),
    /// at most `stateLimit` characters; `updated` when nothing is left.
    private static func plainWords(_ state: String) -> String {
        var words = ""
        for scalar in FoldTextSanitizer.sanitize(state).unicodeScalars.prefix(256) {
            if scalar == "_" || scalar == " " {
                words.append(" ")
            } else if scalar == "-" || (scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))) {
                words.unicodeScalars.append(scalar)
            }
        }
        let trimmed: String = capped(words.trimmingCharacters(in: CharacterSet.whitespaces), to: stateLimit)
        return trimmed.isEmpty ? "updated" : trimmed
    }

    /// `text` cut to at most `limit` characters, ending in `…` when it was cut.
    private static func capped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
