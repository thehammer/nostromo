import Foundation
import NostromoKit

/// Converts NostromoKit's markdown model (what the tracker frames carry) to the macOS-local copy
/// `MarkdownBlockDocument` renders (`Models.swift`), the two being structurally identical.
///
/// One change on the way: the daemon sends a task list's markers as literal `[ ] ` / `[x] ` text at
/// the start of the item, which this turns into `☐ ` / `☑ ` so a task list reads as one.
enum TrackerMdAdapter {

    static func blocks(_ blocks: [NostromoKit.MdBlock]) -> [MdBlock] {
        blocks.map(block)
    }

    static func spans(_ spans: [NostromoKit.MdSpan]) -> [MdSpan] {
        spans.map(span)
    }

    static func block(_ block: NostromoKit.MdBlock) -> MdBlock {
        switch block {
        case .paragraph(let s): return .paragraph(spans(s))
        case .heading(let level, let s): return .heading(level: level, spans: spans(s))
        case .codeBlock(let lang, let text): return .codeBlock(lang: lang, text: text)
        case .list(let ordered, let start, let items):
            return .list(ordered: ordered, start: start, items: items.map { taskItem(blocks($0)) })
        case .quote(let inner): return .quote(blocks(inner))
        case .table(let header, let rows): return .table(header: header.map(spans), rows: rows.map { $0.map(spans) })
        case .rule: return .rule
        }
    }

    static func span(_ span: NostromoKit.MdSpan) -> MdSpan {
        switch span {
        case .text(let t): return .text(t)
        case .code(let t): return .code(t)
        case .emph(let s): return .emph(spans(s))
        case .strong(let s): return .strong(spans(s))
        case .strike(let s): return .strike(spans(s))
        case .link(let s, let url): return .link(spans: spans(s), url: url)
        case .image(let alt, let url): return .image(alt: alt, url: url)
        }
    }

    /// The box a task-list marker becomes.
    static let unchecked = "☐ "
    static let checked = "☑ "

    /// A list item whose first paragraph starts with `[ ] ` or `[x] ` gets a box instead.
    static func taskItem(_ item: [MdBlock]) -> [MdBlock] {
        guard case .paragraph(var spans)? = item.first, case .text(let text)? = spans.first else { return item }
        let box: String
        if text.hasPrefix("[ ] ") {
            box = unchecked
        } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
            box = checked
        } else {
            return item
        }
        spans[0] = .text(box + String(text.dropFirst(4)))
        return [.paragraph(spans)] + item.dropFirst()
    }
}
