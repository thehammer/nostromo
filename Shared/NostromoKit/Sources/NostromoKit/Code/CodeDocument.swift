import Foundation

/// The line arithmetic a `code` pane's gutter, scroll, and emphasis all depend
/// on (W2 — curated-agent-views; ported into `NostromoKit` in
/// `ios-curated-view-parity` W7 so iOS's line addressing is the exact same
/// code as macOS's, rather than a second implementation that could silently
/// drift).
///
/// This exists as a plain `Foundation`-only value type, separate from the
/// AppKit/SwiftUI view code that draws it, for one reason: it must be
/// possible to assert on "which character range is line 412?" directly,
/// rather than through a rendered view — on macOS because `NostromoTests` is
/// host-less, and on iOS because there is no on-device test target at all
/// (see `docs/ios-verification.md`).
///
/// Offsets are UTF-16 code-unit counts, because that is what `NSRange` and
/// `NSTextView` measure in. Using `String.count` here would silently mis-anchor
/// any file containing an emoji or a combining mark — and because this type is
/// shared, that would also make the two clients disagree about where a given
/// line actually is.
///
/// This is a **port**, not a shared move: macOS keeps its own copy at
/// `macOS/Nostromo/UI/CodeDocument.swift` and this one lives here for iOS.
/// Deduplicating the two is deferred (memo B11) — see the PR body.
public struct CodeDocument: Equatable {
    /// Repo-relative path, as requested.
    public let path: String
    /// A git SHA/ref, or `"working"` for the on-disk working tree.
    public let revision: String
    /// The line number `lines[0]` represents — normally 1.
    public let firstLine: Int
    /// The file's lines, in order, without terminators.
    public let lines: [String]

    // MARK: - Construction

    public init(path: String, revision: String, firstLine: Int, text: String) {
        self.path      = path
        self.revision  = revision
        self.firstLine = max(1, firstLine)
        self.lines     = CodeDocument.split(text)
    }

    public init(payload: CodePayload) {
        self.init(
            path:      payload.path,
            revision:  payload.revision,
            firstLine: payload.firstLine,
            text:      payload.text
        )
    }

    /// Split `text` the way an editor numbers a file: the empty string is one
    /// (empty) line, and a trailing newline is a terminator rather than a
    /// phantom final line.
    private static func split(_ text: String) -> [String] {
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return body.components(separatedBy: "\n")
    }

    // MARK: - Geometry

    public var lineCount: Int { lines.count }

    /// The last line number this document numbers.
    public var lastLine: Int { firstLine + lines.count - 1 }

    /// The exact text the view renders — the same string the character ranges
    /// below are offsets into.
    public var text: String { lines.joined(separator: "\n") }

    /// Whether `line` is a line this document actually has.
    public func contains(line: Int) -> Bool {
        line >= firstLine && line <= lastLine
    }

    /// The character range of `line`, excluding its terminator.
    ///
    /// `nil` — rather than a clamped range — for a line outside the document:
    /// a caller that asked for line 9000 of a 200-line file has a bug, and
    /// silently scrolling to the end would hide it.
    public func characterRange(ofLine line: Int) -> NSRange? {
        guard contains(line: line) else { return nil }
        let row = line - firstLine
        return NSRange(location: startOffset(ofRow: row), length: utf16Count(lines[row]))
    }

    /// The character range spanning `start...end` inclusive, terminators
    /// between them included.
    ///
    /// `nil` when the range is inverted or either end is outside the document —
    /// the same refusal the daemon applies to an emphasis range, restated here
    /// because the view must never be handed a range it can't honour.
    public func characterRange(fromLine start: Int, toLine end: Int) -> NSRange? {
        guard start <= end, contains(line: start), contains(line: end) else { return nil }
        let startRow = start - firstLine
        let endRow   = end - firstLine
        let location = startOffset(ofRow: startRow)
        let endBound = startOffset(ofRow: endRow) + utf16Count(lines[endRow])
        return NSRange(location: location, length: endBound - location)
    }

    /// The line number at `row` (0-based index into ``lines``).
    public func lineNumber(forRow row: Int) -> Int? {
        guard row >= 0, row < lines.count else { return nil }
        return firstLine + row
    }

    /// How many digits the widest gutter label needs.
    public var gutterDigits: Int { String(lastLine).count }

    // MARK: - Offsets

    /// UTF-16 offset of the first character of `row`.
    private func startOffset(ofRow row: Int) -> Int {
        var offset = 0
        for i in 0..<row {
            offset += utf16Count(lines[i]) + 1   // +1 for the "\n" terminator
        }
        return offset
    }

    private func utf16Count(_ s: String) -> Int { s.utf16.count }
}
