import Foundation

/// The muted markers for turns the CLI injected as user messages that the user did not type: a
/// message from another Claude session, a loaded skill, a conversation summary or other context.
/// Built here, drawn as plain text; every mark and separator is computed by the app, and the only
/// untrusted text (name, mode, body) is sanitised, bounded and kept clear of the separators, so it
/// cannot draw a badge or a second marker of its own.
extension WakeMarkerText {

    /// The mark of a peer message line.
    public static let peerMark = "↘"
    /// The mark of an injected-context line.
    public static let injectedMark = "ⓘ"
    /// Longest sender name in the line.
    public static let peerNameLimit = 40
    /// Longest first line of a body in the one-line marker.
    public static let peerLineBodyLimit = 120
    /// Longest text a tooltip or the copy text carries (the wire already caps it at 8 KiB).
    public static let tooltipBodyLimit = 1_500
    /// The mode that draws a warning badge; every other mode is quiet text.
    public static let warningMode = "bypass"

    /// `↘ <name> · <mode>: <first line>…`; several messages from one sender merge into
    /// `↘ 3 messages from <name>`, the first lines in the tooltip and all bodies in the copy text.
    public static func peerMessage(_ items: [PeerMessageItemWire], omitted: Int) -> WakeMarkerContent {
        let total = items.count + max(0, omitted)
        guard let first = items.first else {
            return WakeMarkerContent(line: "\(peerMark) Message from another session", tooltipLines: [],
                                     accessibilityLabel: "Message from another session.", target: .none)
        }
        let name = senderName(first)
        let mode = senderMode(first)
        let sameSender = items.allSatisfy { senderName($0) == name }
        let socket = first.fromSocket.map { FoldTextSanitizer.sanitize($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let copy = items.map(\.body).map(FoldTextSanitizer.sanitizeMultiline).joined(separator: "\n\n")

        if total == 1 {
            let text = FoldTextSanitizer.sanitizeMultiline(first.body)
            let head = capped(oneLine(text), to: peerLineBodyLimit) + (first.truncated && !text.isEmpty ? "…" : "")
            let modeText = mode.map { " · \($0)" } ?? ""
            var tooltip = [capped(text, to: tooltipBodyLimit)]
            if let socket { tooltip.append("From \(socket)") }
            return WakeMarkerContent(
                line: "\(peerMark) \(name)\(modeText): \(head)",
                tooltipLines: tooltip,
                accessibilityLabel: "Message from session \(name),\(mode.map { " \($0) mode," } ?? "") \(capped(text, to: tooltipBodyLimit)).",
                target: .none,
                badge: mode == warningMode ? mode : nil,
                copyText: copy)
        }
        let who = sameSender ? name : "other sessions"
        let tipLines = items.prefix(tooltipJobLimit).map { item -> String in
            let line = capped(oneLine(FoldTextSanitizer.sanitizeMultiline(item.body)), to: peerLineBodyLimit)
            return sameSender ? line : "\(senderName(item)): \(line)"
        }
        var lines = tipLines
        if total > lines.count { lines.append("…and \(total - lines.count) more") }
        return WakeMarkerContent(
            line: "\(peerMark) \(total) messages from \(who)",
            tooltipLines: lines,
            accessibilityLabel: "\(total) messages from \(sameSender ? "session \(name)" : "other sessions"). " + lines.joined(separator: "; "),
            target: .none,
            badge: nil,
            copyText: copy)
    }

    /// The marker for an injected-context turn: `kind` `skill` reads `Skill loaded: <name>`, `summary`
    /// `Conversation summary`, anything else `Injected context`. The text is the tooltip's and the
    /// copy text; it never appears raw in the line.
    public static func injectedContext(kind: String, title: String, text: String, truncated: Bool) -> WakeMarkerContent {
        let cleanTitle = capped(oneLine(FoldTextSanitizer.sanitize(title)), to: peerNameLimit)
        let words: String
        switch kind {
        case "skill": words = "Skill loaded: \(cleanTitle.isEmpty ? "unnamed" : cleanTitle)"
        case "summary": words = "Conversation summary"
        default: words = "Injected context"
        }
        let body = FoldTextSanitizer.sanitizeMultiline(text)
        let tip = capped(body, to: tooltipBodyLimit) + (truncated ? "\n…" : "")
        return WakeMarkerContent(
            line: "\(injectedMark) \(words)",
            tooltipLines: body.isEmpty ? [] : [tip],
            accessibilityLabel: "\(words). Not typed by you.",
            target: .none,
            badge: nil,
            copyText: body)
    }

    // MARK: Pieces

    /// The name as one line, capped, without the separators the line itself draws (`:` and `·`).
    private static func senderName(_ item: PeerMessageItemWire) -> String {
        let raw = FoldTextSanitizer.sanitize(item.fromName ?? "")
        let scalars = raw.unicodeScalars.map { $0 == ":" || $0 == "·" ? " " : $0 }
        let clean = oneLine(String(String.UnicodeScalarView(scalars)))
        return capped(clean.isEmpty ? "another session" : clean, to: peerNameLimit)
    }

    /// The mode as plain words (letters, digits, `-`), or nil.
    private static func senderMode(_ item: PeerMessageItemWire) -> String? {
        guard let raw = item.fromMode else { return nil }
        let allowed = FoldTextSanitizer.sanitize(raw).unicodeScalars
            .filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
        let word = String(String.UnicodeScalarView(allowed.prefix(16)))
        return word.isEmpty ? nil : word
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private static func capped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
