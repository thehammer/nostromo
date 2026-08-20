import AppKit

/// The line-addressable code renderer: a gutter, scroll-to-line, and marked
/// ranges, shared by the `code` and `diff` content kinds (W2 —
/// curated-agent-views).
///
/// ## Why AppKit, and why a sibling rather than a replacement (D7)
///
/// `PaneContentNSView` already layers persistent AppKit chrome over a single
/// long-lived `NSHostingView` whose `@Published` model is the only thing that
/// changes — the discipline that preserves scroll position across a content
/// push. This view follows the same rule: it is built once, shown for the two
/// code kinds and hidden for the other five, and never torn down. A pane that
/// flips between kinds keeps both views alive and toggles `isHidden`.
///
/// SwiftUI has no line-number gutter and no way to scroll a `Text` to a
/// character offset, which is why this is `NSTextView` and not a `ScrollView`.
///
/// ## Why the decisions live elsewhere
///
/// Every judgement this view makes — which character range is line 412, which
/// row a diff anchor resolves to, whether an anchor already on screen should
/// move the viewport — is computed by `CodeDocument`, `DiffDocument`, and
/// `ScrollDecision`. Those are `Foundation`-only types the host-less test
/// bundle can compile. What is left here is obedience: apply the attributes,
/// draw the numbers, scroll where you were told.
final class CodeContentView: NSView {

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let textView   = NSTextView()
    private let ruler:       LineNumberRulerView

    /// UTF-16 offset each rendered row starts at, so the visible row range is a
    /// binary search rather than a rescan of the whole document.
    private var rowOffsets = RowOffsetIndex()
    /// The parsed document, kept so an address-only push resolves against it
    /// instead of re-splitting a large file on every re-emphasis.
    private var codeDocument: CodeDocument?
    private var diffDocument: DiffDocument?
    /// Gutter label per row; empty string for a row that has no number (a file
    /// banner, a hunk header, a `\ No newline` marker).
    private var gutterLabels: [String] = []

    /// What was last rendered, so an idempotent push does no work at all — the
    /// same "an idempotent push is invisible" rule `PaneContentNSView.update`
    /// applies one level up.
    private var lastRendered: PaneContentWire?
    private var lastAddress:  PaneAddress?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        ruler = LineNumberRulerView(textView: textView)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        textView.isEditable                = false
        textView.isSelectable              = true
        textView.drawsBackground           = true
        textView.backgroundColor           = .black
        textView.textColor                 = Theme.fg
        textView.font                      = Theme.monoFont
        textView.isRichText                = false
        textView.isVerticallyResizable     = true
        textView.isHorizontallyResizable   = false
        textView.autoresizingMask          = [.width]
        textView.textContainerInset        = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.appearance                = NSAppearance(named: .darkAqua)

        scrollView.documentView            = textView
        scrollView.hasVerticalScroller     = true
        scrollView.hasHorizontalScroller   = false
        scrollView.drawsBackground         = true
        scrollView.backgroundColor         = .black
        scrollView.appearance              = NSAppearance(named: .darkAqua)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.verticalRulerView       = ruler
        scrollView.hasVerticalRuler        = true
        scrollView.rulersVisible           = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Rendering

    /// Whether this view is the renderer for `content`. The one place the
    /// code-kind set is spelled, so `PaneContentNSView`'s show/hide and this
    /// view's own dispatch cannot disagree.
    static func handles(_ content: PaneContentWire?) -> Bool {
        switch content {
        case .code, .diff: return true
        default:           return false
        }
    }

    /// Render `content` and honour `address`.
    ///
    /// Re-rendering identical content is skipped entirely; an address-only
    /// change re-applies emphasis and re-evaluates the scroll without rebuilding
    /// the text, which is what makes "re-emphasise without re-anchoring" cheap.
    func update(content: PaneContentWire, address: PaneAddress?) {
        let contentChanged = content != lastRendered
        if contentChanged {
            switch content {
            case .code(let payload):
                apply(document: CodeDocument(payload: payload))
            case .diff(let payload):
                apply(diff: DiffDocument(payload: payload))
            default:
                return
            }
            lastRendered = content
        }
        guard contentChanged || address != lastAddress else { return }
        lastAddress = address
        applyAddress(address)
    }

    private func apply(document: CodeDocument) {
        codeDocument = document
        diffDocument = nil
        let attributed = NSMutableAttributedString(
            string: document.text,
            attributes: [.font: Theme.monoFont, .foregroundColor: Theme.fg]
        )
        setText(attributed)
        gutterLabels = (0..<document.lineCount).map { String(document.firstLine + $0) }
        rowOffsets = RowOffsetIndex(rowLengths: document.lines.map { $0.utf16.count })
        ruler.reload(labels: gutterLabels, rowOffsets: rowOffsets)
    }

    private func apply(diff: DiffDocument) {
        diffDocument = diff
        codeDocument = nil
        setText(NSMutableAttributedString(
            attributedString: buildDiffAttributedString(diff.text, font: Theme.monoFont)
        ))
        // A diff's gutter shows the new-side number, falling back to the old
        // side for a deleted line — the same precedence anchor resolution uses,
        // so what the operator reads in the gutter is what an agent can address.
        gutterLabels = diff.rows.map { row in
            if let n = row.newN { return String(n) }
            if let n = row.oldN { return String(n) }
            return ""
        }
        rowOffsets = RowOffsetIndex(rowLengths: diff.rows.map { $0.text.utf16.count })
        ruler.reload(labels: gutterLabels, rowOffsets: rowOffsets)
    }

    private func setText(_ attributed: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributed)
    }

    // MARK: - Addressing

    private func applyAddress(_ address: PaneAddress?) {
        clearEmphasis()
        guard let address else { return }

        let rows = resolveRows(address)
        for range in rows.emphasisRanges {
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: Theme.cornflower.withAlphaComponent(0.22),
                range: range
            )
        }
        ruler.setEmphasised(rows.emphasisRows)

        // The criterion this whole indirection exists for: an anchor already on
        // screen must not move the viewport.
        switch ScrollDecision.decide(anchorLine: rows.anchorRow, visibleLines: visibleRowRange()) {
        case .none:
            break
        case .scrollTo(let row):
            scrollRowToCentre(row)
        }
        ruler.needsDisplay = true
    }

    private struct ResolvedAddress {
        var anchorRow: Int?
        var emphasisRows: Set<Int> = []
        var emphasisRanges: [NSRange] = []
    }

    private func resolveRows(_ address: PaneAddress) -> ResolvedAddress {
        var resolved = ResolvedAddress(anchorRow: nil)

        if let document = codeDocument {
            if case .line(_, let line)? = address.anchor, document.contains(line: line) {
                resolved.anchorRow = line - document.firstLine
            }
            for emphasis in address.emphasis {
                guard case .lineRange(_, let start, let end) = emphasis,
                      let range = document.characterRange(fromLine: start, toLine: end)
                else { continue }
                resolved.emphasisRanges.append(range)
                for line in start...end where document.contains(line: line) {
                    resolved.emphasisRows.insert(line - document.firstLine)
                }
            }
        } else if let document = diffDocument {
            if case .line(let path, let line)? = address.anchor {
                resolved.anchorRow = document.rowIndex(forPath: path, line: line)
            }
            for emphasis in address.emphasis {
                guard case .lineRange(let path, let start, let end) = emphasis else { continue }
                let indices = document.rowIndices(forPath: path, from: start, to: end)
                guard let first = indices.first, let last = indices.last,
                      let range = document.characterRange(fromRow: first, toRow: last)
                else { continue }
                resolved.emphasisRanges.append(range)
                indices.forEach { resolved.emphasisRows.insert($0) }
            }
        }
        return resolved
    }

    private func clearEmphasis() {
        guard let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        ruler.setEmphasised([])
    }

    // MARK: - Viewport

    /// The inclusive row range currently on screen, or `nil` before layout has
    /// produced one (a first paint, which always honours its anchor).
    private func visibleRowRange() -> ClosedRange<Int>? {
        guard !rowOffsets.isEmpty,
              let layoutManager = textView.layoutManager,
              let container     = textView.textContainer
        else { return nil }

        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 1 else { return nil }

        let inset      = textView.textContainerInset
        let bounds     = visible.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: container)
        guard glyphRange.length > 0 else { return nil }

        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let first = rowOffsets.row(containingOffset: charRange.location)
        let last  = rowOffsets.row(containingOffset: max(charRange.location, NSMaxRange(charRange) - 1))
        return first...max(first, last)
    }

    private func scrollRowToCentre(_ row: Int) {
        guard row >= 0, row < rowOffsets.count,
              let layoutManager = textView.layoutManager,
              let container     = textView.textContainer
        else { return }

        let length = (row + 1 < rowOffsets.count
                      ? rowOffsets[row + 1] - 1
                      : (textView.string as NSString).length) - rowOffsets[row]
        let charRange  = NSRange(location: rowOffsets[row], length: max(0, length))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let rect       = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

        // `scrollRangeToVisible` alone would leave the anchor pinned to
        // whichever edge it entered from. Centring it is what makes "here is
        // the line, and here is its context" true.
        textView.scrollRangeToVisible(charRange)
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = textView.bounds.height
        let centred        = rect.midY + textView.textContainerInset.height - viewportHeight / 2
        let clamped        = max(0, min(centred, max(0, documentHeight - viewportHeight)))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

// MARK: - LineNumberRulerView

/// The gutter. Draws one right-aligned label per line fragment, using the text
/// view's own layout so a wrapped line is numbered once — at its first fragment
/// — rather than once per visual row.
final class LineNumberRulerView: NSRulerView {

    private weak var target: NSTextView?
    private var labels: [String] = []
    /// Shared with the code view so finding the first visible row is a binary
    /// search — counting newlines in a substring of everything above the
    /// viewport is O(document) on every single scroll frame, which is exactly
    /// the wrong cost for a large file.
    private var rowOffsets = RowOffsetIndex()
    private var emphasised: Set<Int> = []

    init(textView: NSTextView) {
        self.target = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) { fatalError() }

    func reload(labels: [String], rowOffsets: RowOffsetIndex) {
        self.labels = labels
        self.rowOffsets = rowOffsets
        // Size the gutter to the widest label it will ever draw, so the text
        // doesn't shift horizontally as the operator scrolls into four-digit
        // territory.
        let digits = labels.map(\.count).max() ?? 1
        ruleThickness = max(34, CGFloat(digits) * 8 + 16)
        needsDisplay = true
    }

    func setEmphasised(_ rows: Set<Int>) {
        emphasised = rows
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView      = target,
              let layoutManager = textView.layoutManager,
              let container     = textView.textContainer,
              let scrollView    = self.scrollView
        else { return }

        NSColor.black.setFill()
        rect.fill()

        let text       = textView.string as NSString
        let visible    = scrollView.contentView.documentVisibleRect
        let inset      = textView.textContainerInset
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visible.offsetBy(dx: -inset.width, dy: -inset.height),
            in: container
        )
        let charRange  = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Which row the first visible character belongs to.
        var row = rowOffsets.row(containingOffset: min(charRange.location, max(0, text.length - 1)))
        // Whether we've processed the first enumerated fragment yet. `row` is
        // already correct for that first fragment regardless of whether it
        // happens to start a paragraph or continue one — `rowOffsets.row`
        // already accounts for that. Every *subsequent* paragraph-starting
        // fragment means we've moved to a new row and must increment before
        // reading `row`, not after: incrementing only in a `defer` (i.e.
        // after use) meant that once the viewport's top landed mid-wrapped
        // line — ordinary scrolling of any long line, not an edge case — the
        // first fragment correctly drew nothing (it's a continuation), but
        // the *next* fragment (the real start of the next row) still read
        // the stale, not-yet-incremented `row` and drew the previous row's
        // number. Every label for the rest of the visible viewport was then
        // off by one.
        var isFirstFragment = true

        let font = NSFont.monospacedDigitSystemFont(ofSize: Theme.monoFont.pointSize - 1, weight: .regular)

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, fragmentRange, _ in
            let fragmentCharRange = layoutManager.characterRange(
                forGlyphRange: fragmentRange, actualGlyphRange: nil
            )
            // Only the fragment that starts a paragraph carries the number; a
            // soft-wrapped continuation gets a blank gutter, the way every
            // editor does it.
            let isParagraphStart = fragmentCharRange.location == 0
                || text.character(at: fragmentCharRange.location - 1) == 10  // "\n"
            if !isFirstFragment && isParagraphStart {
                row += 1
            }
            isFirstFragment = false
            guard isParagraphStart, row >= 0, row < self.labels.count else { return }

            let label = self.labels[row]
            guard !label.isEmpty else { return }

            let colour: NSColor = self.emphasised.contains(row) ? Theme.cornflower : Theme.fgMuted
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
            let size = label.size(withAttributes: attrs)
            let y    = usedRect.minY + inset.height - visible.minY + (usedRect.height - size.height) / 2
            label.draw(
                at: NSPoint(x: self.ruleThickness - size.width - 8, y: y),
                withAttributes: attrs
            )
        }
    }
}
