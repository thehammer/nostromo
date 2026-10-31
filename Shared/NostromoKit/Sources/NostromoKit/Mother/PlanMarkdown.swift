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

    /// A line's leading `>` markers beyond this many are dropped before parsing (their text stays).
    /// Foundation's parser is not cancellable and its cost grows with nesting depth times the number of
    /// inline runs: 256 KiB of `>` followed by short emphasis spans took 7 s at 2,500 levels and 23 s at
    /// 10,000, again at every file-watch reload. Past `maxDepth` the converter flattens anyway, so the
    /// extra markers draw nothing.
    static let maxQuoteMarkersPerLine = maxDepth

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

    /// The text with each line's container prefix bounded: at most `maxQuoteMarkersPerLine` leading `>`
    /// markers (the rest, and the white space after each dropped one, are removed) and at most
    /// `maxIndentColumns` of white space in each stretch of it. Only that prefix is touched, and only
    /// text is flattened, never lost: whatever followed the markers is still there. One pass.
    /// Expects `\n` line breaks (`sanitizeMultiline` leaves no other).
    static func boundingNesting(_ text: String) -> String {
        let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), quote = UInt8(ascii: ">"), newline = UInt8(ascii: "\n")
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var inPrefix = true
        var quotes = 0
        var columns = 0
        var droppingAfterMarker = false
        for byte in text.utf8 {
            if byte == newline {
                out.append(byte)
                inPrefix = true
                quotes = 0
                columns = 0
                droppingAfterMarker = false
                continue
            }
            guard inPrefix else { out.append(byte); continue }
            switch byte {
            case quote:
                quotes += 1
                columns = 0
                droppingAfterMarker = quotes > maxQuoteMarkersPerLine
                if !droppingAfterMarker { out.append(byte) }
            case space, tab:
                if droppingAfterMarker { continue }
                columns += byte == tab ? 4 : 1
                if columns <= maxIndentColumns { out.append(byte) }
            default:
                inPrefix = false
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
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
