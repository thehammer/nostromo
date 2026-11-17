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

    /// What a typed title becomes: line breaks and tabs are spaces, hidden format characters and
    /// control characters are gone (the daemon refuses them in a `title`), the ends are trimmed.
    public static func normalizedTitle(_ typed: String) -> String {
        let spaced = typed.unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}": return " "
            default: return Character(scalar)
            }
        }
        let clean = String(String.UnicodeScalarView(String(spaced).unicodeScalars.filter {
            !isInvisible($0) && !($0.properties.generalCategory == .control)
        }))
        return clean.trimmingCharacters(in: .whitespaces)
    }

    /// The title an editor opens with for the stored `text`: the whole text when it fits, else the
    /// split's title (without the `…` of a cut) computed on the raw text.
    public static func editableTitle(text: String) -> String {
        let split = split(text)
        return split.rule == .cut ? String(split.title.dropLast()) : split.title
    }

    /// The text after the title the pane shows under the fold, raw, without the `…` of a cut.
    public static func rawRest(text: String) -> String? {
        let split = split(text)
        guard let rest = split.rest else { return nil }
        return split.rule == .cut ? String(rest.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : rest
    }

    /// The title and body a title edit sends so that what the row showed stays shown: the typed
    /// title (split by the display rule when it is over `maxChars`, its rest going first in the
    /// body), then what was under the fold: the old text's rest, then the old note. The body is
    /// empty when nothing is left.
    public static func restructure(text: String, note: String?, newTitle: String) -> (title: String, body: String) {
        let typed = normalizedTitle(newTitle)
        let typedSplit = split(typed)
        let title = typedSplit.rule == .cut ? String(typedSplit.title.dropLast()) : typedSplit.title
        let overflow = typedSplit.rule == .cut
            ? typedSplit.rest.map { String($0.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
            : typedSplit.rest
        let parts = [overflow, rawRest(text: text), note].compactMap { $0 }.filter { !$0.isEmpty }
        return (title, parts.joined(separator: "\n\n"))
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
