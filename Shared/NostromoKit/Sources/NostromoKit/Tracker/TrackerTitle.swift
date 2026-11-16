import Foundation

/// Which branch of the display rule produced a split.
public enum TrackerTitleRule: Equatable {
    /// The text fits in `TrackerTitle.maxChars`: it is the title.
    case whole
    /// The text was split at a separator (`": "`, `"; "`, two spaces, `" — "`, `". "` unless it follows
    /// an abbreviation such as `e.g.`).
    case separator
    /// No separator in range: cut at a word with `…` on both sides.
    case cut
}

/// An item's text as a one-line title and what goes under the fold.
public struct TrackerTitleSplit: Equatable {
    public let title: String
    public let rest: String?
    public let rule: TrackerTitleRule
}

/// The rule that derives a one-line title from an item's text. It only decides what the pane
/// shows: it never rewrites the file, the wire or the stored text. See `docs/mcp/tracker.md`.
public enum TrackerTitle {
    /// Equals `MAX_TITLE_CHARS` in `src/tracker/ops.rs`; a title this short is never split.
    public static let maxChars = 80

    private static let separators: [[Character]] = [": ", "; ", "  ", " — ", ". "].map { Array($0) }
    private static let opening: Set<Character> = ["(", "[", "{"]
    private static let closing: Set<Character> = [")", "]", "}"]
    private static let minOffset = 3
    private static let ellipsis = "…"
    /// A word ending in a period that does not end a sentence: `". "` after one of these is not a
    /// separator. A single capital letter ("J. Smith", "A. Plan") counts too.
    private static let abbreviations: Set<String> = ["e.g.", "i.e.", "vs.", "etc.", "approx."]

    /// Bidi controls, zero-width characters and U+2028/2029 (what the `title` field refuses in
    /// `src/tracker/ops.rs`, `is_hidden_format_char`). Removed from text the row derives a title from.
    public static func stripInvisible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isInvisible($0) }))
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: return true
        default: return false
        }
    }

    public static func split(_ text: String) -> TrackerTitleSplit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard chars.count > maxChars else {
            return TrackerTitleSplit(title: trimmed, rest: nil, rule: .whole)
        }
        var depth = 0
        for i in 0...maxChars {
            if i >= minOffset, depth == 0,
               let sep = separators.first(where: { matches($0, in: chars, at: i) && !endsAbbreviation($0, in: chars, at: i) }) {
                let title = string(chars[..<i])
                let rest = string(chars[(i + sep.count)...])
                return TrackerTitleSplit(title: title, rest: rest.isEmpty ? nil : rest, rule: .separator)
            }
            if opening.contains(chars[i]) {
                depth += 1
            } else if closing.contains(chars[i]) {
                depth = max(0, depth - 1)
            }
        }
        let cut = (minOffset..<maxChars).last(where: { chars[$0] == " " }) ?? (maxChars - 1)
        return TrackerTitleSplit(title: string(chars[..<cut]) + ellipsis,
                                 rest: ellipsis + string(chars[cut...]),
                                 rule: .cut)
    }

    /// The `". "` at `i` follows an abbreviation ("e.g.", "vs.", "J.") rather than ending a sentence.
    private static func endsAbbreviation(_ sep: [Character], in chars: [Character], at i: Int) -> Bool {
        guard sep == [".", " "] else { return false }
        var start = i
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        let word = string(chars[start...i])
        if abbreviations.contains(word.lowercased()) { return true }
        return word.count == 2 && word.first!.isUppercase && word.first!.isLetter
    }

    private static func matches(_ sep: [Character], in chars: [Character], at i: Int) -> Bool {
        i + sep.count <= chars.count && Array(chars[i..<(i + sep.count)]) == sep
    }

    private static func string(_ slice: ArraySlice<Character>) -> String {
        String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
