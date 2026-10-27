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
        scan(Array(text.utf8)).map(\.element)
    }

    /// An element with the byte range it covers in the text.
    private struct Scanned {
        let element: Element
        let range: Range<Int>
    }

    private static func scan(_ bytes: [UInt8]) -> [Scanned] {
        var out: [Scanned] = []
        var rest = 0
        while let start = find(prefix, in: bytes, from: rest) {
            let head = start + 1
            guard let close = bytes[head...].firstIndex(of: UInt8(ascii: ">")) else { break }
            let nameEnd = bytes[head ..< close].firstIndex { $0 == UInt8(ascii: "/") || isSpace($0) } ?? close
            let name = Array(bytes[head ..< nameEnd])
            if name == outputName {
                let end = find(outputEnd, in: bytes, from: close + 1).map { $0 + outputEnd.count } ?? bytes.count
                out.append(Scanned(element: Element(isOutput: true, text: string(bytes[start ..< end])),
                                   range: start ..< end))
                rest = end
            } else {
                if name == followName {
                    out.append(Scanned(element: Element(isOutput: false, text: string(bytes[start ... close])),
                                       range: start ..< close + 1))
                }
                rest = close + 1
            }
        }
        return out
    }

    /// Whatever the agent received that the item blocks do not show: `text` with every recognised
    /// element removed (and, after a follow notice, the daemon's own sentence for it), trimmed.
    /// Nil when nothing but whitespace is left.
    ///
    /// The daemon only checks that a prompt STARTS with an element, so a forged or hand-typed
    /// message can carry real instructions after one, after a closing output tag, or in an
    /// element it does not recognise. Those must stay visible.
    public static func unshownText(for items: [TerminalOriginItem], in text: String) -> String? {
        let bytes = Array(text.utf8)
        var leftover: [UInt8] = []
        var cursor = 0
        for (i, scanned) in scan(bytes).enumerated() {
            leftover += bytes[cursor ..< scanned.range.lowerBound]
            cursor = scanned.range.upperBound
            // A forged output element with no closing tag swallows the text after it into the
            // collapsed block (visible on expand, by design). It is removed here only when its
            // item is an output item, which `texts(for:in:)` then shows; otherwise it stays.
            if scanned.element.isOutput {
                if !(items.indices.contains(i) && !items[i].isNotice) { cursor = scanned.range.lowerBound }
                continue
            }
            // A genuine notice is exactly the element the daemon writes, a newline, then one
            // known sentence. Any other follow element (extra or unknown attribute, unterminated
            // head, other quoting or order, oversized value) is not removed: it stays in the
            // leftover so its full text shows.
            guard items.indices.contains(i), items[i].isNotice, isGenuine(scanned.element.text, for: items[i]) else {
                cursor = scanned.range.lowerBound
                continue
            }
            // Never consume an element the notice view will not explain: leave it visible.
            guard let sentence = noticeSentence(for: items[i]) else {
                cursor = scanned.range.lowerBound
                continue
            }
            let known = Array(("\n" + sentence).utf8)
            if bytes.count >= cursor + known.count, bytes[cursor ..< cursor + known.count].elementsEqual(known) {
                cursor += known.count
            }
        }
        leftover += bytes[cursor...]
        let rest = string(leftover[...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }

    /// Whether `element` is byte for byte the notice element the daemon writes for `item`
    /// (`notice` in `follow/manager.rs`): `event`, `terminal_id`, `pane`, optional `reason`, each
    /// value escaped as `escape_attribute` does. The values are bounded as the daemon's are (a
    /// known event, a terminal id, a pane name), because `item` is parsed from the same text and
    /// so cannot vouch for a value that is itself the payload.
    private static func isGenuine(_ element: String, for item: TerminalOriginItem) -> Bool {
        guard let event = item.event, ["started", "resumed", "paused", "stopped"].contains(event),
              item.terminalId.utf8.count <= 64,
              item.terminalId.utf8.allSatisfy({ isIdByte($0) }),
              item.pane.utf8.count <= maxPaneBytes,
              isDaemonReason(item.reason, event: event) else { return false }
        let reasonAttr = item.reason.map { " reason=\"\(escapeAttribute($0))\"" } ?? ""
        let canonical = "<nostromo-terminal-follow event=\"\(event)\" terminal_id=\"\(escapeAttribute(item.terminalId))\""
            + " pane=\"\(escapeAttribute(item.pane))\"\(reasonAttr)/>"
        return element == canonical
    }

    /// A pane name past this is shown in full in the bubble rather than truncated in the
    /// one-line notice (a narrow notice line fits far fewer bytes, so keep this small).
    private static let maxPaneBytes = 48
    private static let maxTagBytes = 64

    /// The reasons the daemon writes (`EndReason::code`, `pause_code` in `follow/manager.rs`):
    /// only on `paused` and `stopped`; `moved_to ` takes a focus tag (`[A-Za-z0-9._-]`).
    private static func isDaemonReason(_ reason: String?, event: String) -> Bool {
        guard let reason else { return event == "started" || event == "resumed" }
        switch event {
        case "paused":
            return ["too_much_output", "too_many_deliveries"].contains(reason)
        case "stopped":
            if ["user_stopped", "pane_closed", "terminal_restarted", "session_ended", "app_closed"].contains(reason) {
                return true
            }
            guard reason.hasPrefix("moved_to ") else { return false }
            let tag = Array(reason.utf8.dropFirst("moved_to ".utf8.count))
            return !tag.isEmpty && tag.count <= maxTagBytes && tag != [0x2E] && tag != [0x2E, 0x2E]
                && tag.allSatisfy { isIdByte($0) || $0 == UInt8(ascii: ".") }
        default:
            return false
        }
    }

    private static func isIdByte(_ b: UInt8) -> Bool {
        (0x30 ... 0x39).contains(b) || (0x41 ... 0x5A).contains(b) || (0x61 ... 0x7A).contains(b)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    /// `escape_attribute` in `ipc/stream_json.rs`.
    private static func escapeAttribute(_ v: String) -> String {
        v.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The sentence the daemon writes after a follow notice (`follow/manager.rs`). The pane name
    /// is not ours, so the daemon neutralises any element prefix in it; so does this.
    private static func noticeSentence(for item: TerminalOriginItem) -> String? {
        let pane = item.pane
        let sentence: String
        switch item.event {
        case "started":
            sentence = "You are now following \(pane). Output it produces from now on will be delivered to you; you cannot type into it."
        case "resumed":
            sentence = "Following \(pane) resumed. Output it produces from now on will be delivered to you."
        case "paused":
            let why: String
            switch item.reason {
            case "too_much_output": why = "too much output"
            case "too_many_deliveries": why = "too many deliveries in the last hour"
            default: return nil
            }
            sentence = "Following \(pane) paused itself: \(why). Nothing more is delivered until the user resumes it."
        case "stopped":
            guard let code = item.reason else { return nil }
            let why: String
            switch code {
            case "user_stopped": why = "the user stopped it"
            case "pane_closed": why = "the terminal closed"
            case "terminal_restarted": why = "the terminal was restarted"
            case "session_ended": why = "this session ended"
            case "app_closed": why = "the Nostromo app closed"
            default:
                guard code.hasPrefix("moved_to ") else { return nil }
                why = "the user invited \(code.dropFirst("moved_to ".count)) to follow it instead"
            }
            sentence = "You are no longer following \(pane) (\(why))."
        default:
            return nil
        }
        return sentence
            .replacingOccurrences(of: "<nostromo-terminal-", with: "&lt;nostromo-terminal-")
            .replacingOccurrences(of: "</nostromo-terminal-", with: "&lt;/nostromo-terminal-")
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
