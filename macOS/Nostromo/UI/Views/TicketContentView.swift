import AppKit

/// The `ticket` renderer: an issue-tracker ticket's header, sections, and
/// comments (W4 — curated-agent-views).
///
/// Follows `ConversationContentView`'s shape exactly (D6/D7 precedent from
/// W3, itself following W2): a persistent sibling of `PaneContentNSView`'s
/// hosting view, shown for the `ticket` kind and hidden for the others,
/// never torn down — so a pane that flips kinds and flips back keeps its
/// scroll position. All judgement — payload -> attributed text, which
/// character range is which section/comment — lives in
/// `TicketBlockDocument` (a separate, host-less-testable file). This view's
/// job is obedience: render what it's given, scroll where `ScrollDecision`
/// says to.
final class TicketContentView: NSView {

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    /// The parsed document, kept so an address-only push (re-anchor,
    /// re-emphasise) resolves against it without re-rendering.
    private var document: TicketBlockDocument?

    /// What was last rendered, so an idempotent push does no work at all.
    private var lastRendered: PaneContentWire?
    private var lastAddress: PaneAddress?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .black
        textView.textColor = Theme.fg
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.appearance = NSAppearance(named: .darkAqua)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

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
    /// ticket-kind set is spelled, so `PaneContentNSView`'s show/hide and
    /// this view's own dispatch cannot disagree.
    static func handles(_ content: PaneContentWire?) -> Bool {
        if case .ticket = content { return true }
        return false
    }

    /// Render `content` and honour `address`.
    func update(content: PaneContentWire, address: PaneAddress?) {
        let contentChanged = content != lastRendered
        if contentChanged {
            guard case .ticket(let payload) = content else { return }
            let doc = TicketBlockDocument(payload: payload)
            document = doc
            textView.textStorage?.setAttributedString(doc.attributedString)
            lastRendered = content
        }
        guard contentChanged || address != lastAddress else { return }
        lastAddress = address
        applyAddress(address)
    }

    /// Drop everything this view is holding — called by
    /// `PaneContentNSView.update` the moment a pane stops rendering the
    /// `ticket` kind, so a later re-show can never resurface a previous
    /// ticket's text/emphasis, and `lastRendered` can never suppress a
    /// repaint the pane actually needs.
    ///
    /// Trade-off, stated on purpose (mirrors `CodeContentView.clearContent()`):
    /// this gives up preserving scroll position across a kind flip-and-back,
    /// in exchange for never resurfacing stale content as though it were
    /// current — the right trade for a code-review tool.
    ///
    /// Must NOT touch `scrollView`/`textView`'s identity or remove either
    /// from the hierarchy — this view is still built once and never torn
    /// down, it just stops showing stale content while hidden.
    func clearContent() {
        lastRendered = nil
        lastAddress = nil
        document = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: - Addressing

    private func applyAddress(_ address: PaneAddress?) {
        clearEmphasis()
        guard let address, let document else { return }

        var emphasisRanges: [NSRange] = []
        for emphasis in address.emphasis {
            guard case .section(let name) = emphasis, let range = document.range(forSectionOrComment: name) else { continue }
            emphasisRanges.append(range)
        }
        for range in emphasisRanges {
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: Theme.cornflower.withAlphaComponent(0.22),
                range: range
            )
        }

        var anchorStart: Int?
        if case .section(let name)? = address.anchor, let range = document.range(forSectionOrComment: name) {
            anchorStart = range.location
        }

        switch ScrollDecision.decide(anchor: anchorStart, visibleRange: visibleCharacterRange()) {
        case .none:
            break
        case .scrollTo(let target):
            scrollOffsetToCentre(target)
        }
    }

    private func clearEmphasis() {
        guard let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    // MARK: - Viewport

    /// The UTF-16 character range currently on screen, or `nil` before layout
    /// has produced one (a first paint, which always honours its anchor).
    private func visibleCharacterRange() -> ClosedRange<Int>? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              storage.length > 0
        else { return nil }

        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 1 else { return nil }

        let inset = textView.textContainerInset
        let bounds = visible.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: container)
        guard glyphRange.length > 0 else { return nil }

        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let last = max(charRange.location, NSMaxRange(charRange) - 1)
        return charRange.location...last
    }

    private func scrollOffsetToCentre(_ offset: Int) {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage,
              offset >= 0, offset < storage.length
        else { return }

        let charRange = NSRange(location: offset, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)

        textView.scrollRangeToVisible(charRange)
        let viewportHeight = scrollView.contentView.bounds.height
        let documentHeight = textView.bounds.height
        let centred = rect.midY + textView.textContainerInset.height - viewportHeight / 2
        let clamped = max(0, min(centred, max(0, documentHeight - viewportHeight)))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
