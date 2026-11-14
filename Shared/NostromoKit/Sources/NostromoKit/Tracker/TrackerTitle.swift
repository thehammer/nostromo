import Foundation

/// Which branch of the display rule produced a split.
public enum TrackerTitleRule: Equatable {
    /// The text fits in `TrackerTitle.maxChars`: it is the title.
    case whole
    /// The text was split at a separator (`": "`, `"; "`, two spaces, `" — "`, `". "`).
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

    public static func split(_ text: String) -> TrackerTitleSplit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        guard chars.count > maxChars else {
            return TrackerTitleSplit(title: trimmed, rest: nil, rule: .whole)
        }
        var depth = 0
        for i in 0...maxChars {
            if i >= minOffset, depth == 0, let sep = separators.first(where: { matches($0, in: chars, at: i) }) {
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

    private static func matches(_ sep: [Character], in chars: [Character], at i: Int) -> Bool {
        i + sep.count <= chars.count && Array(chars[i..<(i + sep.count)]) == sep
    }

    private static func string(_ slice: ArraySlice<Character>) -> String {
        String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
