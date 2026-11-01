import Foundation

/// What a muted marker in the transcript's user slot says, and where a click on it goes.
///
/// A marker stands in for a turn the user did not type but the agent received (a Mother job notice
/// today; a background-task wake later). The text is built here, once, and drawn as plain text:
/// every mark (`⟲`, the quotes, the state words, `PR #n`) is computed by the app, and the only
/// untrusted text, a job's title, sits inside the quotes after `FoldTextSanitizer`, a cap and quote replacement. So a
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
    /// A background task: its window opens.
    case backgroundTask(id: String)
    /// Several background events: the pane's background list opens.
    case backgroundTasks(ids: [String])
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

    /// Every double-quote scalar a title could use to close the quoted region.
    private static let doubleQuotes: Set<Unicode.Scalar> = [
        "\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}", "\u{2036}",
        "\u{FF02}", "\u{275D}", "\u{275E}", "\u{301D}", "\u{301E}", "\u{301F}", "\u{02BA}",
    ]

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
                line: "\(mark) Mother: \(stateWords(first.state)) \"\(title(first, limit: lineTitleLimit))\"\(prSuffix(first))",
                tooltipLines: [tooltip],
                accessibilityLabel: "Mother update: \(stateWords(first.state)), \(title(first, limit: tooltipTitleLimit))\(pull).",
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

    /// The marker for a background task wake. State-first, like the Mother marker. `omitted` counts
    /// events the daemon dropped past its cap; they only count toward the total.
    public static func taskWake(_ items: [TaskWakeItemWire], omitted: Int) -> WakeMarkerContent {
        let total = items.count + max(0, omitted)
        guard let first = items.first else {
            return WakeMarkerContent(line: "\(mark) Background event", tooltipLines: [],
                                     accessibilityLabel: "Background event.", target: .none)
        }
        if total == 1 {
            let words = wakeWords(first)
            let desc = wakeDescription(first, limit: lineTitleLimit)
            let tipDesc = wakeDescription(first, limit: tooltipTitleLimit)
            let line = desc.isEmpty ? "\(mark) \(words)" : "\(mark) \(words) \"\(desc)\""
            return WakeMarkerContent(
                line: line,
                tooltipLines: [wakeDetail(first, limit: tooltipTitleLimit)],
                accessibilityLabel: tipDesc.isEmpty ? "\(wakeAXPrefix(first))." : "\(wakeAXPrefix(first)), \(tipDesc).",
                target: first.taskId.map { .backgroundTask(id: $0) } ?? .none)
        }
        var lines = items.prefix(tooltipJobLimit).map { wakeDetail($0, limit: tooltipTitleLimit) }
        if total > tooltipJobLimit { lines.append("…and \(total - tooltipJobLimit) more") }
        return WakeMarkerContent(
            line: "\(mark) \(total) background events",
            tooltipLines: lines,
            accessibilityLabel: "\(total) background events. " + lines.joined(separator: "; "),
            target: .backgroundTasks(ids: items.compactMap(\.taskId)))
    }

    // MARK: Pieces

    /// `<Kind>: <outcome words>`, or `Background event` for an item with nothing to name.
    private static func wakeWords(_ item: TaskWakeItemWire) -> String {
        if item.kind == "other", item.outcome == "event", item.description.isEmpty { return "Background event" }
        return "\(kindWords(item.kind)): \(outcomeWords(item))"
    }

    private static func wakeAXPrefix(_ item: TaskWakeItemWire) -> String {
        "Background \(kindWords(item.kind)): \(outcomeWords(item))"
    }

    private static func wakeDetail(_ item: TaskWakeItemWire, limit: Int) -> String {
        let desc = wakeDescription(item, limit: limit)
        let words = "\(kindWords(item.kind)): \(outcomeWords(item))"
        return desc.isEmpty ? words : "\(words) \"\(desc)\""
    }

    private static func kindWords(_ kind: String) -> String {
        switch kind {
        case "shell": return "Shell"
        case "monitor": return "Monitor"
        case "agent": return "Agent"
        default: return "Background task"
        }
    }

    private static func outcomeWords(_ item: TaskWakeItemWire) -> String {
        switch item.outcome {
        case "new_output": return "new output"
        case "completed": return item.kind == "agent" ? "finished" : "completed"
        case "failed": return "failed"
        case "stopped": return "stopped"
        case "ended": return "ended"
        case "event": return "event"
        default: return plainWords(item.outcome)
        }
    }

    /// The sanitised, quote-neutralised, capped description; empty when there is none.
    private static func wakeDescription(_ item: TaskWakeItemWire, limit: Int) -> String {
        let clean = neutralised(item.description)
        return clean.isEmpty ? "" : capped(clean, to: limit)
    }

    /// Double quotes become `'` so text cannot close the quoted region and forge what follows.
    /// Scalar level: a quote with a combining mark after it is one Character, but still a quote.
    private static func neutralised(_ text: String) -> String {
        let scalars = FoldTextSanitizer.sanitize(text).unicodeScalars.map { doubleQuotes.contains($0) ? "'" : $0 }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    /// `<state words> "<title>"` (· PR #n). The state comes first so tail truncation never hides it.
    private static func detail(_ item: MotherNoticeItemWire, titleLimit: Int) -> String {
        "\(stateWords(item.state)) \"\(title(item, limit: titleLimit))\"\(prSuffix(item))"
    }

    private static func prSuffix(_ item: MotherNoticeItemWire) -> String {
        item.prNumber.map { " · PR #\($0)" } ?? ""
    }

    private static func title(_ item: MotherNoticeItemWire, limit: Int) -> String {
        // Double quotes become `'` so the title cannot close the quoted region and forge what follows.
        // Scalar level: a quote with a combining mark after it is one Character, but still a quote.
        let scalars = FoldTextSanitizer.sanitize(item.title).unicodeScalars.map { doubleQuotes.contains($0) ? "'" : $0 }
        let clean = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
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
