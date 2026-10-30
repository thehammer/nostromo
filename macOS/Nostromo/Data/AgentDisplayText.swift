import Foundation

/// How text an agent supplied is shown: as plain text, never as anything that could hide or reorder
/// what a person reads. One sanitiser for every agent-supplied name, note and label
/// (`RemoteShellStore`, the staging drawer).
enum AgentDisplayText {

    /// The longest staged command Nostromo will insert, in scalars (the daemon refuses more).
    static let maxCommandScalars = 1_000

    /// `text` as one plain line: format characters (bidi overrides, zero-width, BOM) and the invisible
    /// fillers are dropped, control characters, newlines and U+2028/2029/U+0085 become spaces, runs of
    /// spaces collapse, the ends are trimmed and anything past `limit` is cut (the last character is
    /// "…"). Nil when nothing is left.
    static func plain(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if isInvisible(scalar) { return nil }
            return CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                ? " " : scalar
        }))
        let collapsed = spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "\u{2026}"
    }

    /// Text with something visible in it: whitespace, format characters and the fillers do not count.
    static func hasVisibleContent(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !isInvisible(scalar)
        }
    }

    /// May Nostromo place `command` at a shell's prompt? Non-empty, at most 1,000 scalars, and no
    /// scalar that is a control (tab included), a format character, a line or paragraph separator,
    /// U+0085 or an invisible filler. The daemon already refuses such text; this is the app's own check
    /// at the moment of the click.
    static func isInsertable(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        var count = 0
        for scalar in command.unicodeScalars {
            count += 1
            if count > maxCommandScalars { return false }
            if isControl(scalar) || isInvisible(scalar) || isLineSeparator(scalar) { return false }
        }
        return true
    }

    /// Format characters (category Cf) and the characters that draw nothing without being Cf: Hangul
    /// fillers (U+3164, U+115F, U+1160, U+FFA0), the combining grapheme joiner (U+034F) and the braille
    /// blank (U+2800).
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format || fillers.contains(scalar.value)
    }

    private static let fillers: Set<UInt32> = [0x3164, 0x115F, 0x1160, 0xFFA0, 0x034F, 0x2800]

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0x85
    }
}
