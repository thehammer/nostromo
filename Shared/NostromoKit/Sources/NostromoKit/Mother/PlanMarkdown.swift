import Foundation

// A plan's markdown as a small, safe document model.
//
// The Mac plan view draws this model and nothing else: it never sees the markdown, a URL to an
// image, or a character the sanitiser drops (SR2: a plan's text is untrusted). Pure Foundation:
// `AttributedString(markdown:)` does the parsing, this file walks its presentation intents.

// MARK: - Model

/// Inline content of a block.
public enum PlanSpan: Equatable, Sendable {
    case text(String)
    case code(String)
    case emph([PlanSpan])
    case strong([PlanSpan])
    case strike([PlanSpan])
    /// `url` is the link's target exactly as written. Whether and how to open it is the view's call.
    case link([PlanSpan], url: String)
    /// An image. Its URL is dropped here: nothing downstream can fetch it.
    case image(alt: String)

    /// The visible text: code and image alt included, link text included, URLs excluded.
    public var plainText: String {
        switch self {
        case .text(let s), .code(let s), .image(alt: let s): return s
        case .emph(let spans), .strong(let spans), .strike(let spans), .link(let spans, _): return spans.plainText
        }
    }
}

extension Array where Element == PlanSpan {
    /// The visible text of the spans, concatenated.
    public var plainText: String { map(\.plainText).joined() }
}

public struct PlanListItem: Equatable, Sendable {
    /// nil: not a task item. false: `[ ] `. true: `[x] ` or `[X] `. The marker is not in the spans.
    public let task: Bool?
    public let blocks: [PlanBlock]

    public init(task: Bool?, blocks: [PlanBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

public struct PlanBlock: Equatable, Sendable {
    /// Unique per block in the document, in document order (a container before its children), and
    /// the same for the same text: a view that is rebuilt can find "the same block" again.
    public let index: Int
    public let kind: Kind

    public indirect enum Kind: Equatable, Sendable {
        case heading(level: Int, spans: [PlanSpan])
        case paragraph([PlanSpan])
        case list(ordered: Bool, start: Int, items: [PlanListItem])
        case codeBlock(lang: String?, text: String)
        case table(header: [[PlanSpan]], rows: [[[PlanSpan]]])
        case quote([PlanBlock])
        case rule
    }

    public init(index: Int, kind: Kind) {
        self.index = index
        self.kind = kind
    }
}

/// One heading, for the outline.
public struct PlanOutlineEntry: Equatable, Sendable {
    public let blockIndex: Int
    public let level: Int
    public let title: String

    public init(blockIndex: Int, level: Int, title: String) {
        self.blockIndex = blockIndex
        self.level = level
        self.title = title
    }
}

public struct PlanDocument: Equatable, Sendable {
    /// The top-level blocks.
    public let blocks: [PlanBlock]
    /// Every heading, at any depth, in document order.
    public let outline: [PlanOutlineEntry]

    public init(blocks: [PlanBlock] = [], outline: [PlanOutlineEntry] = []) {
        self.blocks = blocks
        self.outline = outline
    }
}

// MARK: - Parser

public enum PlanMarkdown {

    /// Blocks nested deeper than this are flattened into their parent, so hostile nesting costs a
    /// bounded amount of stack in the parser and in the view that draws it.
    static let maxDepth = 32

    /// A run's block path (outermost first) is cut to this many components before a tree is built from
    /// it: the first `maxPathComponents - tailComponents` and the last `tailComponents` (the leaf block
    /// and the list item or table row around it). Foundation reports a million-deep path for a million
    /// `>`, and a chain of that many nodes cannot be walked, freed or drawn on a small stack. What is
    /// dropped is nesting, never text: the leaf keeps its content and lands in the nearest kept parent.
    /// That keeps `maxDepth` levels of quote (1 component each) or of list (2 each) intact, so a
    /// plan nested as deep as it can be drawn is untouched. The converter also flattens past
    /// `maxDepth`, so its recursion is bounded by this path length, not by the file.
    static let maxPathComponents = 2 * maxDepth + 2 * tailComponents
    static let tailComponents = 3

    /// A line's leading container markers (`>`, a bullet or an ordered-list marker) beyond this many are
    /// dropped before parsing (their text stays). Foundation's parser is not cancellable and its cost grows
    /// with nesting depth times the number of inline runs: 256 KiB of `>` followed by short emphasis spans
    /// took 7 s at 2,500 levels and 23 s at 10,000, again at every file-watch reload. Past `maxDepth` the
    /// converter flattens anyway, so the extra markers draw nothing.
    static let maxMarkersPerLine = maxDepth

    /// A line's leading white space beyond this many columns (a tab counts 4) is dropped before parsing,
    /// for the same reason: indentation is how lists nest, and every 2 to 4 columns is a level. It keeps
    /// `maxDepth` levels of the widest lists (4 columns each); deeper lines land at the deepest kept level.
    static let maxIndentColumns = 4 * maxDepth

    /// The most block-path components (summed over all runs) that are looked at in full. The source
    /// bounds above make the real figure a few million at most for 256 KiB; a run past this budget is
    /// reduced to its leaf (its text is kept) so a shape the bounds missed still costs a bounded amount.
    static let maxPathWork = 12_000_000

    /// Never crashes and never throws: text Foundation cannot read at all is an empty document.
    public static func parse(_ text: String) -> PlanDocument {
        parseCounting(text).document
    }

    /// [`parse`], and how many block-path components the runs of the parsed text had to be walked
    /// through: a measure of the work that does not depend on the machine (for tests).
    static func parseCounting(_ text: String) -> (document: PlanDocument, pathComponents: Int) {
        // Sanitise first so an escape sequence cannot be split by the markdown syntax around it,
        // and again per span, so the model alone is safe whatever the parser did.
        let clean = boundingNesting(FoldTextSanitizer.sanitizeMultiline(text))
        guard !clean.allSatisfy(\.isWhitespace) else { return (PlanDocument(), 0) }

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let attributed = try? AttributedString(markdown: clean, options: options) else { return (PlanDocument(), 0) }

        var tree = Tree()
        var work = 0
        for run in attributed.runs {
            tree.add(text: String(attributed[run.range].characters),
                     path: boundedPath(run.presentationIntent, work: &work),
                     inline: run.inlinePresentationIntent ?? [],
                     link: run.link?.absoluteString,
                     image: run.imageURL?.absoluteString)
        }
        var converter = Converter()
        let blocks = converter.blocks(tree.roots, depth: 0)
        return (PlanDocument(blocks: blocks, outline: converter.outline), work)
    }

    /// The text with each line's container prefix bounded: at most `maxMarkersPerLine` leading container
    /// markers (`>`, `-`, `*` or `+` followed by white space, 1 to 9 digits and `.` or `)` followed by
    /// white space; the rest, and the white space after each dropped one, are removed; the three kinds
    /// share the one cap) and at most `maxIndentColumns` of white space in each stretch of it. Only that
    /// prefix is touched, and only nesting is flattened, never text: whatever followed the markers is
    /// still there. One pass. Expects `\n` line breaks (`sanitizeMultiline` leaves no other).
    ///
    /// Code is left alone: the lines of a fenced code block that opens at the very start of a line (three
    /// or more backticks or tildes, as the parser reads a fence) are copied as they are, up to the line
    /// that closes it, because their white space is the code's own. A line is only skipped when the
    /// parser is certain to be inside that same code block, so nothing it would nest escapes the cap.
    /// That holds only while this tracker and the parser agree on which lines open and close a fence, so
    /// recognition is switched off, for the rest of the text, by anything that could make them differ: a
    /// line that starts with `<` (an HTML block can swallow a fence line) and a fence-shaped line
    /// indented 1 to 3 columns (the parser may have a fence open there that a fence line at the start of
    /// a line closes, or none, if a list item ended). A fence inside a quote or list item is never
    /// recognised. All the other lines are bounded like any other.
    static func boundingNesting(_ text: String) -> String {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), quote = UInt8(ascii: ">"), newline = UInt8(ascii: "\n")
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var fence: Fence?
        var trustsFences = true
        var i = 0
        while i < bytes.count {
            if let current = fence {   // inside a fenced code block: the line is code
                let end = lineEnd(in: bytes, from: i)
                if current.isClosed(by: bytes, lineStart: i, lineEnd: end) { fence = nil }
                out.append(contentsOf: bytes[i ..< end])
                i = end
                continue
            }
            var markers = 0
            var columns = 0
            var dropping = false
            prefix: while i < bytes.count {
                let byte = bytes[i]
                switch byte {
                case space, tab:
                    if !dropping {
                        columns += byte == tab ? 4 : 1
                        if columns <= maxIndentColumns { out.append(byte) }
                    }
                    i += 1
                case quote:
                    markers += 1
                    columns = 0
                    dropping = markers > maxMarkersPerLine
                    if !dropping { out.append(byte) }
                    i += 1
                default:
                    let length = listMarkerLength(in: bytes, at: i)
                    guard length > 0 else { break prefix }
                    markers += 1
                    columns = 0
                    dropping = markers > maxMarkersPerLine
                    if !dropping { out.append(contentsOf: bytes[i ..< i + length]) }
                    i += length
                }
            }
            if trustsFences, i < bytes.count, markers == 0, columns <= 3 {
                if bytes[i] == UInt8(ascii: "<") {
                    trustsFences = false
                } else if bytes[i] == UInt8(ascii: "`") || bytes[i] == UInt8(ascii: "~"),
                          let opened = Fence(opening: bytes, at: i, lineEnd: lineEnd(in: bytes, from: i)) {
                    if columns == 0 { fence = opened } else { trustsFences = false }
                }
            }
            while i < bytes.count {   // the rest of the line is the text
                let byte = bytes[i]
                out.append(byte)
                i += 1
                if byte == newline { break }
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The index just past the line that starts at `start` (past its line break, or the end of the text).
    private static func lineEnd(in bytes: [UInt8], from start: Int) -> Int {
        var end = start
        while end < bytes.count {
            end += 1
            if bytes[end - 1] == UInt8(ascii: "\n") { break }
        }
        return end
    }

    /// An open fenced code block, as `cmark` reads one: a line of three or more backticks (none in the rest
    /// of the line) or tildes opens it; a line of at least as many of the same character, indented 3 columns
    /// at most and followed by nothing but spaces and tabs, closes it. It runs to the end of the text if no
    /// line does.
    private struct Fence {
        let character: UInt8
        let length: Int

        /// The fence that the line `[at, lineEnd)` opens, if it does (`at` is the start of the line).
        init?(opening bytes: [UInt8], at start: Int, lineEnd: Int) {
            let character = bytes[start]
            guard character == UInt8(ascii: "`") || character == UInt8(ascii: "~") else { return nil }
            var end = start
            while end < lineEnd, bytes[end] == character { end += 1 }
            guard end - start >= 3 else { return nil }
            if character == UInt8(ascii: "`"), bytes[end ..< lineEnd].contains(UInt8(ascii: "`")) { return nil }
            self.character = character
            self.length = end - start
        }

        func isClosed(by bytes: [UInt8], lineStart: Int, lineEnd: Int) -> Bool {
            var i = lineStart
            while i < lineEnd, i - lineStart < 4, bytes[i] == UInt8(ascii: " ") { i += 1 }
            guard i - lineStart <= 3 else { return false }
            let run = i
            while i < lineEnd, bytes[i] == character { i += 1 }
            guard i - run >= length else { return false }
            return bytes[i ..< lineEnd].allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\n") }
        }
    }

    /// The length of a list marker (without the white space after it) that starts at `i`, or 0:
    /// `-`, `*` or `+`, or 1 to 9 digits and `.` or `)`; either one followed by a space or a tab.
    private static func listMarkerLength(in bytes: [UInt8], at i: Int) -> Int {
        let bullets = [UInt8(ascii: "-"), UInt8(ascii: "*"), UInt8(ascii: "+")]
        var end = i
        if bullets.contains(bytes[i]) {
            end = i + 1
        } else {
            while end < bytes.count, bytes[end] >= UInt8(ascii: "0"), bytes[end] <= UInt8(ascii: "9") { end += 1 }
            guard (1 ... 9).contains(end - i), end < bytes.count,
                  bytes[end] == UInt8(ascii: ".") || bytes[end] == UInt8(ascii: ")")
            else { return 0 }
            end += 1
        }
        guard end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") else { return 0 }
        return end - i
    }

    /// The run's block path, outermost first, cut to `maxPathComponents`. Touches only the components it
    /// keeps, so a million-deep path costs a million steps to count and a few dozen to copy. `work` adds
    /// up the components seen; once it passes `maxPathWork` a run keeps only its leaf `tailComponents`.
    private static func boundedPath(_ intent: PresentationIntent?, work: inout Int) -> [PresentationIntent.IntentType] {
        guard let components = intent?.components else { return [] }   // innermost first
        work += components.count
        if work > maxPathWork { return Array(components.prefix(tailComponents).reversed()) }
        guard components.count > maxPathComponents else { return components.reversed() }
        let outer = components.suffix(maxPathComponents - tailComponents).reversed()
        let inner = components.prefix(tailComponents).reversed()
        return Array(outer) + Array(inner)
    }

    // MARK: Tree of presentation intents

    private final class Node {
        let kind: PresentationIntent.Kind
        var children: [Node] = []
        var runs: [InlineRun] = []
        var code = ""

        init(kind: PresentationIntent.Kind) { self.kind = kind }
    }

    private struct InlineRun {
        let text: String
        let intent: InlineIntent
        let link: String?
        /// Only to merge the runs of one image; never stored in the model.
        let image: String?
    }

    private typealias InlineIntent = InlinePresentationIntent

    private struct Tree {
        var roots: [Node] = []
        private var byIdentity: [Int: Node] = [:]
        private var syntheticParagraph: Node?

        mutating func add(text: String, path: [PresentationIntent.IntentType], inline: InlineIntent,
                          link: String?, image: String?) {
            let run = InlineRun(text: text, intent: inline, link: link, image: image)
            guard !path.isEmpty else {
                // Text outside any block: its own paragraph, shared by runs that follow each other.
                let node = syntheticParagraph ?? Node(kind: .paragraph)
                if syntheticParagraph == nil { syntheticParagraph = node; roots.append(node) }
                node.runs.append(run)
                return
            }
            syntheticParagraph = nil
            var parent: Node?
            for component in path {
                let node: Node
                if let existing = byIdentity[component.identity] {
                    node = existing
                } else {
                    node = Node(kind: component.kind)
                    byIdentity[component.identity] = node
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                }
                parent = node
            }
            guard let leaf = parent else { return }
            switch leaf.kind {
            case .codeBlock: leaf.code += text
            default: leaf.runs.append(run)
            }
        }
    }

    // MARK: Nodes to blocks

    private struct Converter {
        var nextIndex = 0
        var outline: [PlanOutlineEntry] = []

        mutating func blocks(_ nodes: [Node], depth: Int) -> [PlanBlock] {
            var result: [PlanBlock] = []
            for node in nodes { result.append(contentsOf: block(node, depth: depth)) }
            return result
        }

        private mutating func take() -> Int {
            defer { nextIndex += 1 }
            return nextIndex
        }

        private mutating func block(_ node: Node, depth: Int) -> [PlanBlock] {
            switch node.kind {
            case .header(level: let level):
                let spans = Spans.make(node.runs)
                guard !spans.isEmpty else { return [] }
                let index = take()
                let level = min(max(level, 1), 6)
                outline.append(PlanOutlineEntry(blockIndex: index, level: level, title: spans.plainText))
                return [PlanBlock(index: index, kind: .heading(level: level, spans: spans))]

            case .paragraph:
                let spans = Spans.make(node.runs)
                guard !spans.isEmpty else { return [] }
                return [PlanBlock(index: take(), kind: .paragraph(spans))]

            case .orderedList, .unorderedList:
                guard depth < PlanMarkdown.maxDepth else { return blocks(node.children, depth: depth) }
                let ordered: Bool
                if case .orderedList = node.kind { ordered = true } else { ordered = false }
                let index = take()
                var start = 1
                if ordered, let first = node.children.first, case .listItem(ordinal: let n) = first.kind { start = n }
                var items: [PlanListItem] = []
                for child in node.children {
                    guard case .listItem = child.kind else { continue }
                    var content = blocks(child.children, depth: depth + 1)
                    let task = Self.takeTaskMarker(from: &content)
                    items.append(PlanListItem(task: task, blocks: content))
                }
                return [PlanBlock(index: index, kind: .list(ordered: ordered, start: start, items: items))]

            case .codeBlock(languageHint: let hint):
                let text = Self.trimmingOneTrailingNewline(FoldTextSanitizer.sanitizeMultiline(node.code))
                let lang = hint.flatMap { FoldTextSanitizer.sanitizeInline($0).trimmingCharacters(in: .whitespaces) }
                return [PlanBlock(index: take(), kind: .codeBlock(lang: (lang?.isEmpty ?? true) ? nil : lang, text: text))]

            case .blockQuote:
                guard depth < PlanMarkdown.maxDepth else { return blocks(node.children, depth: depth) }
                let index = take()
                let inner = blocks(node.children, depth: depth + 1)
                return [PlanBlock(index: index, kind: .quote(inner))]

            case .thematicBreak:
                return [PlanBlock(index: take(), kind: .rule)]

            case .table:
                var header: [[PlanSpan]] = []
                var rows: [[[PlanSpan]]] = []
                for child in node.children {
                    let cells = child.children.map { Spans.make($0.runs) }
                    switch child.kind {
                    case .tableHeaderRow: header = cells
                    case .tableRow: rows.append(cells)
                    default: break
                    }
                }
                return [PlanBlock(index: take(), kind: .table(header: header, rows: rows))]

            default:
                // A list item, row or cell with no container: its content is still the plan's.
                return blocks(node.children, depth: depth)
            }
        }

        /// A task item's first text is `[ ] `, `[x] ` or `[X] `. Removes the marker from the spans.
        private static func takeTaskMarker(from content: inout [PlanBlock]) -> Bool? {
            guard let first = content.first, case .paragraph(var spans) = first.kind,
                  case .text(let head)? = spans.first
            else { return nil }
            let done: Bool
            if head.hasPrefix("[ ] ") { done = false }
            else if head.hasPrefix("[x] ") || head.hasPrefix("[X] ") { done = true }
            else { return nil }
            let rest = String(head.dropFirst(4))
            if rest.isEmpty { spans.removeFirst() } else { spans[0] = .text(rest) }
            content[0] = PlanBlock(index: first.index, kind: .paragraph(spans))
            return done
        }

        private static func trimmingOneTrailingNewline(_ text: String) -> String {
            text.hasSuffix("\n") ? String(text.dropLast()) : text
        }
    }

    // MARK: Runs to spans

    private enum Spans {
        static func make(_ runs: [InlineRun]) -> [PlanSpan] {
            var result: [PlanSpan] = []
            var i = 0
            while i < runs.count {
                if let url = runs[i].link {
                    var j = i
                    while j < runs.count, runs[j].link == url { j += 1 }
                    let inner = plain(Array(runs[i..<j]))
                    if !inner.isEmpty { result.append(.link(inner, url: url)) }
                    i = j
                } else {
                    var j = i
                    while j < runs.count, runs[j].link == nil { j += 1 }
                    result.append(contentsOf: plain(Array(runs[i..<j])))
                    i = j
                }
            }
            return result
        }

        /// Runs without a link around them: images (adjacent runs of one image are one) and styled text.
        private static func plain(_ runs: [InlineRun]) -> [PlanSpan] {
            var result: [PlanSpan] = []
            var i = 0
            while i < runs.count {
                let run = runs[i]
                if let image = run.image {
                    var alt = ""
                    while i < runs.count, runs[i].image == image {
                        alt += FoldTextSanitizer.sanitizeInline(runs[i].text)
                        i += 1
                    }
                    result.append(.image(alt: alt))
                    continue
                }
                i += 1
                if run.intent.contains(.lineBreak) { result.append(.text("\n")); continue }
                let text = FoldTextSanitizer.sanitizeInline(run.text)
                guard !text.isEmpty else { continue }
                var span: PlanSpan = run.intent.contains(.code) ? .code(text) : .text(text)
                if run.intent.contains(.strikethrough) { span = .strike([span]) }
                if run.intent.contains(.emphasized) { span = .emph([span]) }
                if run.intent.contains(.stronglyEmphasized) { span = .strong([span]) }
                result.append(span)
            }
            return result
        }
    }
}
