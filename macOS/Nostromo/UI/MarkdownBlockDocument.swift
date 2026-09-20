import AppKit

/// Turns a `pr_conversation` payload's markdown-parsed blocks into one
/// attributed string plus the character-range arithmetic comment anchoring
/// needs (W3 — curated-agent-views).
///
/// `AppKit`-only logic — no `NSTextView`, no window — so the host-less
/// `NostromoTests` bundle can compile and test it directly (dual-membership
/// in `project.pbxproj`), the same discipline `CodeDocument`/`DiffDocument`
/// established in W2. `ConversationContentView` is the thin AppKit shell that
/// renders what this produces and does nothing else: no markdown knowledge,
/// no range arithmetic of its own.
///
/// Fenced code blocks are the one criterion that must be exactly right —
/// rendered monospaced with a tinted background and original indentation
/// intact, never as literal backticks and flattened prose. Everything else
/// (nested lists, tables, blockquotes) renders at reasonable fidelity.
struct MarkdownBlockDocument: Equatable {
    /// The full attributed conversation: an optional title, the PR
    /// description, then every thread's comments in rendered order.
    let attributedString: NSAttributedString
    /// Character range of each comment's rendered content, keyed by its `id`
    /// — how an anchor or emphasis resolves to a scroll position or
    /// highlight range. UTF-16 offsets, matching `NSRange`/`NSTextView`.
    let commentRanges: [String: NSRange]
    /// Comment ids in rendered order.
    let commentOrder: [String]

    init(title: String, body: [MdBlock], threads: [ConversationThreadModel]) {
        let result = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]
        var order: [String] = []

        if !title.isEmpty {
            result.append(Self.headingRun(title, level: 1))
            result.append(Self.blockBreak())
        }
        if !body.isEmpty {
            result.append(Self.render(blocks: body, indent: 0))
            result.append(Self.blockBreak())
        }

        for thread in threads {
            for comment in thread.comments {
                let start = result.length
                result.append(Self.commentHeader(author: comment.author, date: comment.createdAt))
                result.append(Self.render(blocks: comment.body, indent: 0))
                let range = NSRange(location: start, length: result.length - start)
                ranges[comment.id] = range
                order.append(comment.id)
                result.append(Self.blockBreak())
            }
        }

        attributedString = result
        commentRanges = ranges
        commentOrder = order
    }

    /// The character range of `id`'s comment, if it appears in this document.
    func range(ofComment id: String) -> NSRange? {
        commentRanges[id]
    }

    static func == (lhs: MarkdownBlockDocument, rhs: MarkdownBlockDocument) -> Bool {
        lhs.attributedString.isEqual(to: rhs.attributedString)
            && lhs.commentRanges == rhs.commentRanges
            && lhs.commentOrder == rhs.commentOrder
    }

    // MARK: - Comment framing

    static func commentHeader(author: String, date: Date) -> NSAttributedString {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = "\(author) · \(formatter.string(from: date))\n"
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.fgMuted,
        ])
    }

    static func blockBreak() -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: textAttrs())
    }

    /// The blank line after a paragraph/heading/code block — the separator
    /// every top-level block that isn't itself a list/quote/table/rule ends
    /// with.
    static func paragraphBreak() -> NSAttributedString {
        NSAttributedString(string: "\n\n", attributes: textAttrs())
    }

    // MARK: - Block rendering

    static func render(blocks: [MdBlock], indent: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for block in blocks {
            out.append(render(block: block, indent: indent))
        }
        return out
    }

    static func render(block: MdBlock, indent: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let prefix = String(repeating: "  ", count: indent)
        switch block {
        case .paragraph(let spans):
            if indent > 0 { out.append(NSAttributedString(string: prefix, attributes: textAttrs())) }
            out.append(render(spans: spans))
            out.append(paragraphBreak())
        case .heading(let level, let spans):
            out.append(headingRun(plainText(spans), level: level))
            out.append(paragraphBreak())
        case .codeBlock(let lang, let text):
            out.append(codeBlockRun(text, lang: lang, indent: indent))
            out.append(paragraphBreak())
        case .list(let ordered, let start, let items):
            for (i, item) in items.enumerated() {
                let bullet = ordered ? "\((start ?? 1) + i). " : "•  "
                out.append(NSAttributedString(string: prefix + bullet, attributes: textAttrs()))
                out.append(render(blocks: item, indent: indent + 1))
            }
        case .quote(let blocks):
            out.append(NSAttributedString(string: prefix + "▎ ", attributes: mutedAttrs()))
            out.append(render(blocks: blocks, indent: indent + 1))
        case .table(let header, let rows):
            if !header.isEmpty {
                out.append(tableRowRun(header))
            }
            for row in rows {
                out.append(tableRowRun(row))
            }
            out.append(NSAttributedString(string: "\n", attributes: textAttrs()))
        case .rule:
            out.append(NSAttributedString(
                string: String(repeating: "─", count: 40) + "\n\n",
                attributes: mutedAttrs()
            ))
        }
        return out
    }

    static func tableRowRun(_ cells: [[MdSpan]]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: "| ", attributes: mutedAttrs()))
        for (i, cell) in cells.enumerated() {
            out.append(render(spans: cell))
            out.append(NSAttributedString(
                string: i < cells.count - 1 ? " | " : " |\n",
                attributes: mutedAttrs()
            ))
        }
        return out
    }

    // MARK: - Inline span rendering

    static func render(spans: [MdSpan]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            out.append(render(span: span))
        }
        return out
    }

    static func render(span: MdSpan) -> NSAttributedString {
        switch span {
        case .text(let text):
            return NSAttributedString(string: text, attributes: textAttrs())
        case .code(let text):
            return NSAttributedString(string: text, attributes: inlineCodeAttrs())
        case .emph(let spans):
            return styled(spans, italic: true, bold: false)
        case .strong(let spans):
            return styled(spans, italic: false, bold: true)
        case .strike(let spans):
            let inner = NSMutableAttributedString(attributedString: render(spans: spans))
            inner.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: NSRange(location: 0, length: inner.length)
            )
            return inner
        case .link(let spans, let url):
            let inner = NSMutableAttributedString(attributedString: render(spans: spans))
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.cornflower,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            if let resolved = URL(string: url) {
                attrs[.link] = resolved
            }
            inner.addAttributes(attrs, range: NSRange(location: 0, length: inner.length))
            return inner
        case .image(let alt, _):
            let text = alt.isEmpty ? "[image]" : "[image: \(alt)]"
            return NSAttributedString(string: text, attributes: mutedAttrs())
        }
    }

    static func styled(_ spans: [MdSpan], italic: Bool, bold: Bool) -> NSAttributedString {
        let inner = NSMutableAttributedString(attributedString: render(spans: spans))
        var traits: NSFontTraitMask = []
        if italic { traits.insert(.italicFontMask) }
        if bold { traits.insert(.boldFontMask) }
        let font = NSFontManager.shared.convert(Theme.monoFont, toHaveTrait: traits)
        inner.addAttribute(.font, value: font, range: NSRange(location: 0, length: inner.length))
        return inner
    }

    static func headingRun(_ text: String, level: Int) -> NSAttributedString {
        let size: CGFloat = max(13, 20 - CGFloat(level - 1) * 2)
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: Theme.fg,
        ])
    }

    /// A fenced/indented code block, monospaced with a tinted background —
    /// the criterion this whole file exists to satisfy. `text` is rendered
    /// byte-for-byte (including its original indentation); only a trailing
    /// newline is dropped so it doesn't compound with the block separator
    /// this function's caller appends.
    static func codeBlockRun(_ text: String, lang: String?, indent: Int) -> NSAttributedString {
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        let prefix = String(repeating: "  ", count: indent)
        let indented = body
            .components(separatedBy: "\n")
            .map { prefix + $0 }
            .joined(separator: "\n")
        _ = lang // reserved for syntax highlighting, explicitly out of scope (D8-equivalent for this wedge)
        return NSAttributedString(string: indented + "\n", attributes: [
            .font: Theme.monoFont,
            .foregroundColor: Theme.fg,
            .backgroundColor: NSColor.white.withAlphaComponent(0.08),
        ])
    }

    static func plainText(_ spans: [MdSpan]) -> String {
        spans.map(plainText).joined()
    }

    static func plainText(_ span: MdSpan) -> String {
        switch span {
        case .text(let t), .code(let t):
            return t
        case .emph(let spans), .strong(let spans), .strike(let spans):
            return plainText(spans)
        case .link(let spans, _):
            return plainText(spans)
        case .image(let alt, _):
            return alt
        }
    }

    static func textAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.fg]
    }

    static func mutedAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.fgMuted]
    }

    static func inlineCodeAttrs() -> [NSAttributedString.Key: Any] {
        [
            .font: Theme.firaCode(size: 12),
            .foregroundColor: Theme.fg,
            .backgroundColor: NSColor.white.withAlphaComponent(0.12),
        ]
    }
}
