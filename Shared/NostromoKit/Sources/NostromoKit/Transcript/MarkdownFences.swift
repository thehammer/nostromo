import Foundation

/// A pure, Foundation-only scanner for fenced code blocks in transcript text.
///
/// This is a deliberate subset of CommonMark: fences are the only block structure
/// the Mac transcript card renderer needs to see, because everything else it
/// handles is line-based. Rules:
///
/// - **Opening fence:** any amount of leading spaces or tabs, then three or more
///   of the same fence character (`` ` `` or `~`), then an optional info string.
///   A backtick fence's info string may not contain a backtick, so ```` ```x``` ````
///   in the middle of prose stays inline code. Indentation is deliberately
///   unbounded (CommonMark allows 0-3): Claude nests fences inside list items and
///   the renderer has no list containers or indented code blocks.
/// - **Closing fence:** optional leading whitespace, then the same character at
///   least as many times as the opener, then only whitespace. A shorter run, or
///   a run of the other character, is a content line.
/// - **Content:** up to the opener's indentation width in leading spaces is
///   removed (a tab counts as one column); the rest of the line is kept
///   byte-exact.
/// - **Unterminated fence:** the block runs to the end of the text with
///   `isClosed == false`, so a partial message still renders as code.
/// - No blank line is required before or after a fence.
///
/// Line endings are normalised (`\r\n` to `\n`) before scanning.
public enum MarkdownFences {

    public struct CodeBlock: Equatable, Sendable {
        /// The trimmed info string; `""` when there is none.
        public let info: String
        /// First whitespace-delimited token of `info`; nil when `info` is empty.
        public let language: String?
        /// Content lines joined with `\n`, fence lines excluded.
        public let code: String
        public let isClosed: Bool
        /// The exact original lines, fences included, joined with `\n`.
        public let source: String

        public init(info: String, language: String?, code: String, isClosed: Bool, source: String) {
            self.info = info
            self.language = language
            self.code = code
            self.isClosed = isClosed
            self.source = source
        }
    }

    public enum Segment: Equatable, Sendable {
        /// Original lines between code blocks, joined with `\n`, untrimmed.
        case prose(String)
        case code(CodeBlock)
    }

    /// Splits `text` into prose and code segments. Joining every segment's text
    /// (`prose` string or `code.source`) with `\n` reproduces the line-ending
    /// normalised input exactly.
    public static func segments(of text: String) -> [Segment] {
        let lines = normalised(text)
        var result: [Segment] = []
        var prose: [String] = []
        var i = 0

        while i < lines.count {
            guard let opener = opener(in: lines[i]) else {
                prose.append(lines[i])
                i += 1
                continue
            }
            if !prose.isEmpty {
                result.append(.prose(prose.joined(separator: "\n")))
                prose = []
            }

            var content: [String] = []
            var isClosed = false
            var j = i + 1
            while j < lines.count {
                if isCloser(lines[j], for: opener) {
                    isClosed = true
                    break
                }
                content.append(removeIndent(opener.indent, from: lines[j]))
                j += 1
            }
            let end = isClosed ? j : lines.count - 1
            let info = opener.info
            result.append(.code(CodeBlock(
                info: info,
                language: info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                code: content.joined(separator: "\n"),
                isClosed: isClosed,
                source: lines[i...end].joined(separator: "\n"))))
            i = end + 1
        }

        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    /// True iff `segments(of:)` would yield at least one code block. Any opener
    /// counts, even an unterminated one.
    public static func containsFence(_ text: String) -> Bool {
        normalised(text).contains { opener(in: $0) != nil }
    }

    // MARK: - Scanning

    private struct Opener {
        let char: Character
        let length: Int
        let indent: Int
        let info: String
    }

    private static func normalised(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    private static func isIndent(_ c: Character) -> Bool { c == " " || c == "\t" }

    private static func opener(in line: String) -> Opener? {
        let body = line.drop(while: isIndent)
        let indent = line.count - body.count
        guard let char = body.first, char == "`" || char == "~" else { return nil }
        let run = body.prefix(while: { $0 == char })
        guard run.count >= 3 else { return nil }
        let info = body.dropFirst(run.count).trimmingCharacters(in: .whitespaces)
        if char == "`" && info.contains("`") { return nil }
        return Opener(char: char, length: run.count, indent: indent, info: info)
    }

    private static func isCloser(_ line: String, for opener: Opener) -> Bool {
        let body = line.drop(while: isIndent)
        let run = body.prefix(while: { $0 == opener.char })
        guard run.count >= opener.length else { return false }
        return body.dropFirst(run.count).allSatisfy(isIndent)
    }

    private static func removeIndent(_ width: Int, from line: String) -> String {
        guard width > 0 else { return line }
        return String(line.dropFirst(line.prefix(width).prefix(while: { $0 == " " }).count))
    }
}
