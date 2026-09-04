import Foundation

/// Converts `MdBlock`/`MdSpan` trees into `ProseRow`s (ios-curated-view-parity
/// W9, D1) — the shared primitive `ConversationPlan` and `TicketPlan` both
/// call to render a description/section/comment's blocks into one flat row
/// list, so a rendering improvement here lands on both surfaces at once (D7).
///
/// Ported in spirit from `MarkdownBlockDocument.render(block:indent:)`
/// (`macOS/Nostromo/UI/MarkdownBlockDocument.swift:105-143`), but producing
/// rows rather than an `NSAttributedString` run: a list item's marker and a
/// blockquote's marker are their own structural row, with the item/quote's
/// own block content following as further rows nested one indent level
/// deeper — the same convention for both, so nesting is never a special
/// case, only an incremented `indent`.
public enum ProsePlan {

    /// Append `blocks`' rows to `rows`, starting at `nextId` (advanced past
    /// every row appended) and nested at `indent`.
    public static func appendRows(for blocks: [MdBlock], indent: Int, rows: inout [ProseRow], nextId: inout Int) {
        for block in blocks {
            appendRow(for: block, indent: indent, rows: &rows, nextId: &nextId)
        }
    }

    private static func appendRow(for block: MdBlock, indent: Int, rows: inout [ProseRow], nextId: inout Int) {
        switch block {
        case .paragraph(let spans):
            rows.append(ProseRow(id: nextId, kind: .paragraph, indent: indent, spans: spans))
            nextId += 1

        case .heading(let level, let spans):
            rows.append(ProseRow(id: nextId, kind: .heading(level: level), indent: indent, spans: spans))
            nextId += 1

        case .codeBlock(let lang, let text):
            rows.append(ProseRow(id: nextId, kind: .codeBlock(lang: lang, text: text), indent: indent))
            nextId += 1

        case .list(let ordered, let start, let items):
            for (i, item) in items.enumerated() {
                let marker = ordered ? "\((start ?? 1) + i)." : "•"
                rows.append(ProseRow(id: nextId, kind: .listItem(ordered: ordered, marker: marker), indent: indent))
                nextId += 1
                appendRows(for: item, indent: indent + 1, rows: &rows, nextId: &nextId)
            }

        case .quote(let blocks):
            rows.append(ProseRow(id: nextId, kind: .quote, indent: indent))
            nextId += 1
            appendRows(for: blocks, indent: indent + 1, rows: &rows, nextId: &nextId)

        case .table(let header, let tableRows):
            if !header.isEmpty {
                rows.append(ProseRow(id: nextId, kind: .tableRow(cells: header, isHeader: true), indent: indent))
                nextId += 1
            }
            for row in tableRows {
                rows.append(ProseRow(id: nextId, kind: .tableRow(cells: row, isHeader: false), indent: indent))
                nextId += 1
            }

        case .rule:
            rows.append(ProseRow(id: nextId, kind: .rule, indent: indent))
            nextId += 1
        }
    }

    // MARK: - Plain-text projection (D5)
    //
    // The text `Emphasis.textRange(start:end:)` resolves offsets against —
    // UTF-16 code units, matching the offsets macOS's `NSRange` uses, so a
    // range means the same thing on both clients even though this client
    // never builds an `NSAttributedString`. Every row contributes SOME text
    // so an offset inside any row lands somewhere sane; a purely structural
    // row (`.listItem`, `.quote`, `.rule`) contributes an empty string since
    // there is nothing there to select.

    /// One row's plain-text contribution to the document's projection (see
    /// `plainText(for:)`).
    public static func plainText(of row: ProseRow) -> String {
        switch row.kind {
        case .heading, .paragraph:
            return plainText(of: row.spans)
        case .codeBlock(_, let text):
            return text
        case .listItem, .quote, .rule:
            return ""
        case .tableRow(let cells, _):
            return cells.map { plainText(of: $0) }.joined(separator: " | ")
        case .documentHeader(let header):
            return [header.key, header.title, header.author, header.status, header.assignee, header.url]
                .compactMap { $0 }
                .joined(separator: " ")
        case .threadHeader:
            return ""
        case .commentHeader(let author, _):
            return author
        case .sectionHeader(_, let display):
            return display
        case .notice(let kind):
            switch kind {
            case .conversationIncomplete(let reason):
                return reason
            }
        }
    }

    /// The whole plan's plain-text projection: every row's own text, joined
    /// by `"\n"` — the string `ProseAddressing`'s `.textRange` resolution
    /// walks to find which row (and which range within it) an offset range
    /// falls into. Stable for a given `rows`: the same plan produces the
    /// same offsets twice.
    public static func plainText(for rows: [ProseRow]) -> String {
        rows.map(plainText(of:)).joined(separator: "\n")
    }

    /// The plain-text rendering of a span run — ported from
    /// `MarkdownBlockDocument.plainText(_:)`
    /// (`macOS/Nostromo/UI/MarkdownBlockDocument.swift:241-256`): visible
    /// text only, never a raw URL or a code fence marker.
    public static func plainText(of spans: [MdSpan]) -> String {
        spans.map(plainText(of:)).joined()
    }

    public static func plainText(of span: MdSpan) -> String {
        switch span {
        case .text(let t), .code(let t):
            return t
        case .emph(let spans), .strong(let spans), .strike(let spans):
            return plainText(of: spans)
        case .link(let spans, _):
            return plainText(of: spans)
        case .image(let alt, _):
            return alt
        }
    }
}
