import AppKit
import NostromoKit

/// Selectable, non-editable text for the tracker pane: wraps at the width it is laid out to and
/// reports the height that takes. TextKit 1, so measuring and drawing use the same layout manager.
///
/// It never takes keyboard focus on its own (only a click in it does, which is how a selection
/// starts), and a right click adds the row's own items (Copy as Markdown) above the standard ones.
final class TrackerTextView: NSTextView {
    /// Items put at the top of the context menu (the row's Copy as Markdown).
    var extraMenuItems: () -> [NSMenuItem] = { [] }

    static func make(singleLine: Bool = false) -> TrackerTextView {
        let view = TrackerTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.selectedTextAttributes = Theme.selectionAttributes
        view.linkTextAttributes = [.foregroundColor: Theme.cornflower,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue]
        if let container = view.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            if singleLine {
                container.maximumNumberOfLines = 1
                container.lineBreakMode = .byTruncatingTail
            }
        }
        return view
    }

    var hasSelection: Bool { selectedRange().length > 0 }

    /// Replace the text, keeping nothing of the old one (selection included).
    func set(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
    }

    /// The height of the text wrapped at `width`; also sizes the container to it.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        guard (textStorage?.length ?? 0) > 0 else { return 0 }
        return ceil(layout.usedRect(for: container).height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let extra = extraMenuItems()
        guard !extra.isEmpty else { return menu }
        for (i, item) in extra.enumerated() { menu.insertItem(item, at: i) }
        menu.insertItem(.separator(), at: extra.count)
        return menu
    }
}

/// A horizontal-only scroller for one wide block (a fenced code block or a table) inside the
/// vertical tracker pane. Vertical wheel movement goes on to the pane, so the block never traps it.
final class TrackerHorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Free prose (and expanded item notes) from the board: markdown blocks laid out top to bottom.
/// Paragraphs, headings, lists (task lists with ☐/☑), quotes and rules are one wrapping text view
/// per run, via `MarkdownBlockDocument.render`; each fenced code block (monospaced) and each table
/// (a grid) sits in its own horizontal scroller, so only that block scrolls sideways.
final class TrackerProseView: NSView {
    override var isFlipped: Bool { true }

    private enum Segment {
        case text(TrackerTextView)
        case wide(scroll: TrackerHorizontalScrollView, content: NSView, size: NSSize)
    }

    private var segments: [Segment] = []
    private(set) var blocks: [MdBlock] = []
    static let spacing: CGFloat = 6

    /// Items every text view of this prose adds to its context menu.
    var extraMenuItems: () -> [NSMenuItem] = { [] } {
        didSet { textViews.forEach { $0.extraMenuItems = extraMenuItems } }
    }

    init(blocks: [MdBlock]) {
        super.init(frame: .zero)
        set(blocks: blocks)
    }

    required init?(coder: NSCoder) { fatalError() }

    var textViews: [TrackerTextView] {
        segments.compactMap { segment -> TrackerTextView? in
            if case .text(let view) = segment { return view }
            return nil
        }
    }

    /// The fenced code blocks' and tables' horizontal scrollers, top to bottom.
    var wideBlockScrollViews: [NSScrollView] {
        segments.compactMap { segment -> NSScrollView? in
            if case .wide(let scroll, _, _) = segment { return scroll }
            return nil
        }
    }

    /// All the text the prose shows, as plain characters.
    var plainText: String {
        segments.map { segment -> String in
            switch segment {
            case .text(let view): return view.string
            case .wide(_, let content, _): return Self.plainText(of: content)
            }
        }.joined(separator: "\n")
    }

    func set(blocks: [MdBlock]) {
        self.blocks = blocks
        subviews.forEach { $0.removeFromSuperview() }
        segments = []
        var run: [MdBlock] = []
        func flush() {
            guard !run.isEmpty else { return }
            let view = TrackerTextView.make()
            view.set(Self.trimmed(MarkdownBlockDocument.render(blocks: run, indent: 0)))
            view.extraMenuItems = extraMenuItems
            addSubview(view)
            segments.append(.text(view))
            run = []
        }
        for block in blocks {
            switch block {
            case .codeBlock(let lang, let text):
                flush()
                segments.append(makeWide(Self.codeView(text: text, lang: lang)))
            case .table(let header, let rows):
                flush()
                segments.append(makeWide(Self.tableView(header: header, rows: rows)))
            default:
                run.append(block)
            }
        }
        flush()
    }

    /// Lays the segments out at `width` and returns the total height.
    @discardableResult
    func layout(width: CGFloat) -> CGFloat {
        var y: CGFloat = 0
        for (i, segment) in segments.enumerated() {
            if i > 0 { y += Self.spacing }
            switch segment {
            case .text(let view):
                let h = view.height(forWidth: width)
                view.frame = NSRect(x: 0, y: y, width: width, height: h)
                y += h
            case .wide(let scroll, let content, let size):
                scroll.frame = NSRect(x: 0, y: y, width: width, height: size.height)
                content.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, width), height: size.height))
                y += size.height
            }
        }
        return y
    }

    // MARK: - Wide blocks

    private func makeWide(_ content: (view: NSView, size: NSSize)) -> Segment {
        let scroll = TrackerHorizontalScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.codeBlockBackground
        scroll.borderType = .noBorder
        scroll.documentView = content.view
        addSubview(scroll)
        return .wide(scroll: scroll, content: content.view, size: content.size)
    }

    static let widePadding: CGFloat = 6

    /// A non-wrapping monospaced text view holding the code exactly as written.
    static func codeView(text: String, lang: String?) -> (view: NSView, size: NSSize) {
        let view = TrackerTextView.make()
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        view.set(NSAttributedString(string: body, attributes: [.font: Theme.monoFont, .foregroundColor: Theme.fg]))
        view.textContainerInset = NSSize(width: widePadding, height: widePadding)
        guard let container = view.textContainer, let layout = view.layoutManager else { return (view, .zero) }
        container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = NSSize(width: ceil(used.width) + widePadding * 2, height: ceil(used.height) + widePadding * 2)
        return (view, size)
    }

    /// A grid: one selectable cell per table cell, the header row bold.
    static func tableView(header: [[MdSpan]], rows: [[[MdSpan]]]) -> (view: NSView, size: NSSize) {
        let all = (header.isEmpty ? [] : [header]) + rows
        let columns = all.map(\.count).max() ?? 0
        let cells: [[NSView]] = all.enumerated().map { r, row in
            (0 ..< columns).map { c -> NSView in
                let spans = c < row.count ? row[c] : []
                let field = NSTextField(labelWithAttributedString: MarkdownBlockDocument.render(spans: spans))
                if r == 0 && !header.isEmpty {
                    field.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                }
                field.textColor = Theme.fg
                field.isSelectable = true
                return field
            }
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.xPlacement = .leading
        grid.yPlacement = .center
        let container = TrackerFlippedView()
        container.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = true
        let fitting = grid.fittingSize
        grid.frame = NSRect(x: widePadding, y: widePadding, width: fitting.width, height: fitting.height)
        return (container, NSSize(width: ceil(fitting.width) + widePadding * 2, height: ceil(fitting.height) + widePadding * 2))
    }

    static func trimmed(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        while out.length > 0, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    static func plainText(of view: NSView) -> String {
        if let field = view as? NSTextField { return field.stringValue }
        if let text = view as? NSTextView { return text.string }
        if let grid = view as? NSGridView {
            return (0 ..< grid.numberOfRows).map { r in
                (0 ..< grid.numberOfColumns).compactMap { c in
                    (grid.cell(atColumnIndex: c, rowIndex: r).contentView as? NSTextField)?.stringValue
                }.joined(separator: " | ")
            }.joined(separator: "\n")
        }
        return view.subviews.map(plainText(of:)).joined(separator: "\n")
    }
}

/// A plain flipped container (y grows down), for the tracker's document and wide blocks.
final class TrackerFlippedView: NSView {
    override var isFlipped: Bool { true }
}
