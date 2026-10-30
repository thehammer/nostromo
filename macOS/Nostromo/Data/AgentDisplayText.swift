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

    /// May Nostromo place `command` at a shell's prompt? The daemon's own text rules, checked again at the
    /// moment of the click (defence in depth): non-empty, at most 1,000 scalars; no control character (tab
    /// included), format character, invisible filler or variation selector, no line or paragraph separator,
    /// U+0085, no text that opens or closes a `<nostromo-` element; and no whitespace that could hide text:
    /// none at either end, no space character but U+0020, no run of more than 4 spaces. (Secrets and
    /// production-shell commands are the daemon's to refuse.)
    static func isInsertable(_ command: String) -> Bool {
        guard let first = command.unicodeScalars.first, let last = command.unicodeScalars.last,
              !first.properties.isWhitespace, !last.properties.isWhitespace else { return false }
        var count = 0
        var spaceRun = 0
        for scalar in command.unicodeScalars {
            count += 1
            if count > maxCommandScalars { return false }
            if isControl(scalar) || isInvisible(scalar) || isHiddenByTheDaemon(scalar) || isLineSeparator(scalar) { return false }
            if scalar == " " {
                spaceRun += 1
                if spaceRun > maxSpaceRun { return false }
            } else {
                spaceRun = 0
                if scalar.properties.isWhitespace { return false }
            }
        }
        let lower = command.lowercased()
        return !lower.contains("<nostromo-") && !lower.contains("</nostromo-")
    }

    /// The longest run of consecutive spaces a command may hold (the daemon's rule).
    static let maxSpaceRun = 4

    /// Format characters (category Cf) and the characters that draw nothing without being Cf: Hangul
    /// fillers (U+3164, U+115F, U+1160, U+FFA0), the combining grapheme joiner (U+034F) and the braille
    /// blank (U+2800).
    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format || fillers.contains(scalar.value)
    }

    private static let fillers: Set<UInt32> = [0x3164, 0x115F, 0x1160, 0xFFA0, 0x034F, 0x2800]

    /// What the daemon's `is_invisible` drops beyond format characters and the fillers above: soft hyphen,
    /// Arabic and Syriac marks, Khmer inherent vowels, Mongolian selectors, variation selectors, unassigned
    /// format-like code points (U+2065, U+FFF0...), musical and shorthand format controls, tag characters.
    private static func isHiddenByTheDaemon(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x0600...0x0605, 0x061C, 0x06DD, 0x070F, 0x0890...0x0891, 0x08E2, 0x115F, 0x1160,
             0x17B4...0x17B5, 0x180B...0x180F, 0x200B...0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2060...0x206F,
             0x2800, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF0...0xFFFB, 0x110BD, 0x110CD, 0x13430...0x1343F,
             0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0000...0xE0FFF:
            return true
        default:
            return false
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
    }

    private static func isLineSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x2028 || scalar.value == 0x2029 || scalar.value == 0x85
    }
}
