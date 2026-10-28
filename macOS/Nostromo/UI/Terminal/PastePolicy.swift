import Foundation

/// Whether a paste goes straight to the shell or asks first.
enum PasteDecision: Equatable {
    case send
    /// Ask first: the text is `lines` lines, and each may run as a command.
    case confirm(lines: Int)
}

enum PastePolicy {

    /// Longest preview the confirmation shows, in characters.
    static let previewLimit = 200
    private static let previewLines = 3

    /// A pane that is not known to be local asks (`kind` nil, `.ecs`, `.unknown`) for any text that
    /// contains a newline, a trailing one included (`"rm -rf x\n"` runs the moment it lands), and for any
    /// text with a control or invisible character other than a tab: an escape sequence can end a
    /// bracketed paste early, Ctrl-O or Ctrl-D act on their own, and U+2028, U+0085, vertical tab and
    /// form feed are line breaks to some programs. A local shell never asks. `\r\n` and `\r` count as one
    /// line break each, and one trailing newline does not make a second line.
    static func decide(kind: TerminalKind?, text: String) -> PasteDecision {
        guard kind != .local, text.unicodeScalars.contains(where: { $0 != "\t" && (isInvisible($0) || isLineBreak($0)) }) else {
            return .send
        }
        return .confirm(lines: lineCount(text))
    }

    static func lineCount(_ text: String) -> Int {
        normalisedLines(text).count
    }

    /// The first three lines for the confirmation to show, control and invisible characters made
    /// visible (U+FFFD), at most `previewLimit` characters, "…" when anything was cut.
    static func preview(_ text: String) -> String {
        let lines = normalisedLines(text)
        var shown = lines.prefix(previewLines).joined(separator: "\n").unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "\n": return "\n"
            case "\t": return " "
            default: return isInvisible(scalar) ? "\u{FFFD}" : Character(scalar)
            }
        }
        var cut = lines.count > previewLines
        if shown.count > previewLimit {
            shown = Array(shown.prefix(previewLimit))
            cut = true
        }
        return String(shown) + (cut ? "\u{2026}" : "")
    }

    private static func normalisedLines(_ text: String) -> [String] {
        var normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        if normalised.hasSuffix("\n") { normalised.removeLast() }
        return normalised.components(separatedBy: "\n")
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
            || scalar.properties.generalCategory == .format
    }
}
