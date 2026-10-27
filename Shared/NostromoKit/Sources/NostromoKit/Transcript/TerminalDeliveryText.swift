import Foundation

/// What a terminal delivery turn shows in the transcript, as plain text: the one-line summary of
/// each item, the exact text of each element, and where the `[redacted: …]` markers sit.
///
/// Pure and shared (iOS compiles it too), so the wording and the splitting are tested without
/// AppKit. The daemon wrote the turn's `userInput` (see `stream_json::parse_terminal_origin`);
/// `elements(in:)` finds the same elements the same way, so the items of an origin and the
/// elements of its text line up one to one.
public enum TerminalDeliveryText {

    // MARK: Summaries

    /// The collapsed line of a delivery item, or a notice's whole line:
    /// "Output from production · scheduler shell, 42 lines", "Selection from … , 3 lines,
    /// 2 redacted", "Following stopped: … (pane closed)".
    public static func summary(for item: TerminalOriginItem) -> String {
        item.isNotice ? noticeLine(for: item) : outputSummary(for: item)
    }

    /// "Output from <pane>, 42 lines" (", 1 redacted" when something was replaced by a marker).
    /// A selection is "Selection from <pane>, …".
    public static func outputSummary(for item: TerminalOriginItem) -> String {
        let what = item.kind == "selection" ? "Selection" : "Output"
        var line = "\(what) from \(item.pane), \(item.lines) \(item.lines == 1 ? "line" : "lines")"
        if item.redactions > 0 { line += ", \(item.redactions) redacted" }
        return line
    }

    /// One muted line for a follow notice: "Following started: <pane>",
    /// "Following stopped: <pane> (pane closed)", "Following paused: too much output".
    public static func noticeLine(for item: TerminalOriginItem) -> String {
        switch item.event {
        case "started":
            return "Following started: \(item.pane)"
        case "resumed":
            return "Following resumed: \(item.pane)"
        case "stopped":
            let why = item.reason.flatMap(stopReason).map { " (\($0))" } ?? ""
            return "Following stopped: \(item.pane)\(why)"
        case "paused":
            return "Following paused: \(item.reason.flatMap(pauseReason) ?? item.pane)"
        default:
            return "Following \(item.event ?? "changed"): \(item.pane)"
        }
    }

    /// What VoiceOver says for a delivery block: "Terminal output from <pane>, 42 lines,
    /// collapsed, button".
    public static func accessibilityLabel(for item: TerminalOriginItem, isExpanded: Bool) -> String {
        spokenLabel(for: item, isExpanded: isExpanded) + ", button"
    }

    /// `accessibilityLabel` without the role: a view that already has the button role takes this
    /// as its label, and VoiceOver adds "button" itself.
    public static func spokenLabel(for item: TerminalOriginItem, isExpanded: Bool) -> String {
        "Terminal output from \(item.pane), \(item.lines) \(item.lines == 1 ? "line" : "lines"), "
            + (isExpanded ? "expanded" : "collapsed")
    }

    private static func stopReason(_ code: String) -> String? {
        switch code {
        case "user_stopped":       return "you stopped it"
        case "pane_closed":        return "pane closed"
        case "terminal_restarted": return "terminal restarted"
        case "session_ended":      return "session ended"
        case "app_closed":         return "app closed"
        default:
            // `moved_to <tag>`: another agent was invited to follow it instead.
            return code.hasPrefix("moved_to") ? "another agent follows it now" : nil
        }
    }

    private static func pauseReason(_ code: String) -> String? {
        switch code {
        case "too_much_output":      return "too much output"
        case "too_many_deliveries":  return "too many deliveries in the last hour"
        default:                     return nil
        }
    }

    // MARK: Elements

    /// One `<nostromo-terminal-…>` element of a turn's text, exactly as the daemon wrote it.
    public struct Element: Equatable {
        /// True for an `<nostromo-terminal-output>` element, false for a follow notice.
        public let isOutput: Bool
        /// For an output element: from its opening `<` to the end of its closing tag, byte for
        /// byte what the agent received (advisory line included). For a notice: the empty
        /// element only (`<nostromo-terminal-follow …/>`).
        public let text: String
    }

    private static let prefix = Array("<nostromo-terminal-".utf8)
    private static let outputName = Array("nostromo-terminal-output".utf8)
    private static let followName = Array("nostromo-terminal-follow".utf8)
    private static let outputEnd = Array("</nostromo-terminal-output>".utf8)

    /// The elements of `text`, in order, found the way the daemon finds them for `origin`:
    /// an output element runs to its closing tag (or the end of the text when it has none), a
    /// follow notice ends at its `>`, any other element is skipped. Works on UTF-8 bytes, so a
    /// combining mark next to a `>` cannot change where an element ends.
    public static func elements(in text: String) -> [Element] {
        let bytes = Array(text.utf8)
        var out: [Element] = []
        var rest = 0
        while let start = find(prefix, in: bytes, from: rest) {
            let head = start + 1
            guard let close = bytes[head...].firstIndex(of: UInt8(ascii: ">")) else { break }
            let nameEnd = bytes[head ..< close].firstIndex { $0 == UInt8(ascii: "/") || isSpace($0) } ?? close
            let name = Array(bytes[head ..< nameEnd])
            if name == outputName {
                let end = find(outputEnd, in: bytes, from: close + 1).map { $0 + outputEnd.count } ?? bytes.count
                out.append(Element(isOutput: true, text: string(bytes[start ..< end])))
                rest = end
            } else {
                if name == followName {
                    out.append(Element(isOutput: false, text: string(bytes[start ... close])))
                }
                rest = close + 1
            }
        }
        return out
    }

    /// The exact text of each item of `items`, in order: an output item's element, or nil for a
    /// notice (which shows only its summary line) and for an item whose element the text no
    /// longer holds (the turn was truncated, or the lists disagree).
    public static func texts(for items: [TerminalOriginItem], in text: String) -> [String?] {
        let all = elements(in: text)
        return items.enumerated().map { i, item in
            // The daemon makes one item per element, in order.
            guard !item.isNotice, all.indices.contains(i), all[i].isOutput else { return nil }
            return all[i].text
        }
    }

    // MARK: Redaction markers

    /// The ranges (UTF-16, for `NSAttributedString`) of every `[redacted: <kind>]` marker in
    /// `text`.
    public static func redactionRanges(in text: String) -> [NSRange] {
        guard text.contains("[redacted:") else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return markerPattern.matches(in: text, range: whole).map(\.range)
    }

    // A kind is a short slug (`aws-key`, `private-key`); never a newline or a closing bracket.
    // swiftlint:disable:next force_try
    private static let markerPattern = try! NSRegularExpression(pattern: #"\[redacted: [^\]\n]*\]"#)

    // MARK: Byte helpers

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || (0x09 ... 0x0D).contains(b)
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// First index at or after `from` where `needle` occurs in `bytes`.
    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard let first = needle.first, bytes.count >= needle.count, from <= bytes.count - needle.count else {
            return nil
        }
        var i = from
        let last = bytes.count - needle.count
        while i <= last {
            if bytes[i] == first, bytes[i ..< i + needle.count].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }
}
