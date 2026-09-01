import AppKit

/// The `pr_conversation` renderer: a PR's description and its comment/review
/// threads, rendered from the daemon's markdown-block model (W3 —
/// curated-agent-views).
///
/// Follows `CodeContentView`'s shape exactly (D6/D7 precedent from W2): a
/// persistent sibling of `PaneContentNSView`'s hosting view, shown for the
/// `pr_conversation` kind and hidden for the other kinds, never torn down —
/// so a pane that flips kinds and flips back keeps its scroll position.
///
/// All the judgement — markdown → attributed text, which character range is
/// which comment — lives in `MarkdownBlockDocument`, a `Foundation`/`AppKit`
/// value type the host-less test bundle can compile. This view's job is
/// obedience: render what it's given, scroll where `ScrollDecision` says to.
final class ConversationContentView: NSView {

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    /// The parsed document, kept so an address-only push (re-anchor,
    /// re-emphasise) resolves against it without re-rendering the markdown.
    private var document: MarkdownBlockDocument?

    /// What was last rendered, so an idempotent push does no work at all —
    /// the same rule `PaneContentNSView.update`/`CodeContentView.update` apply.
    private var lastRendered: PaneContentWire?
    private var lastAddress: PaneAddress?

    /// The exact ranges `clearEmphasis()` must undo — never the whole
    /// document. `.backgroundColor` is also how a fenced code block's tint
    /// (`MarkdownBlockDocument`'s own rendering, baked into the attributed
    /// string `update()` just installed) is represented. Clearing the whole
    /// document's `.backgroundColor` on every single call — including the
    /// one immediately following a content change, before this view has
    /// painted a single frame with the new document — wiped every code
    /// block's tint the instant it was set.
    private var lastEmphasisRanges: [NSRange] = []

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
    /// conversation-kind set is spelled, so `PaneContentNSView`'s show/hide
    /// and this view's own dispatch cannot disagree.
    static func handles(_ content: PaneContentWire?) -> Bool {
        if case .prConversation = content { return true }
        return false
    }

    /// Render `content` and honour `address`.
    func update(content: PaneContentWire, address: PaneAddress?) {
        let contentChanged = content != lastRendered
        if contentChanged {
            guard case .prConversation(let payload) = content else { return }
            let doc = MarkdownBlockDocument(title: payload.title, body: payload.body, threads: payload.threads)
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
    /// `pr_conversation` kind, so a later re-show can never resurface a
    /// previous conversation's text/emphasis, and `lastRendered` can never
    /// suppress a repaint the pane actually needs.
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
        lastEmphasisRanges = []
        textView.textStorage?.setAttributedString(NSAttributedString())
    }

    // MARK: - Addressing

    private func applyAddress(_ address: PaneAddress?) {
        clearEmphasis()
        guard let address, let document else { return }

        var emphasisRanges: [NSRange] = []
        for emphasis in address.emphasis {
            guard case .comment(let id) = emphasis, let range = document.range(ofComment: id) else { continue }
            emphasisRanges.append(range)
        }
        for range in emphasisRanges {
            textView.textStorage?.addAttribute(
                .backgroundColor,
                value: Theme.cornflower.withAlphaComponent(0.22),
                range: range
            )
        }
        lastEmphasisRanges = emphasisRanges

        var anchorStart: Int?
        if case .comment(let id)? = address.anchor, let range = document.range(ofComment: id) {
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
        // Only the ranges *this view* tinted for emphasis — never the whole
        // document. A blanket clear over the full length also strips
        // MarkdownBlockDocument's own fenced-code-block background, which
        // uses the same attribute and is otherwise indistinguishable from
        // emphasis tinting once both are just ".backgroundColor" in the
        // storage. On a fresh content render this ran with the *new*
        // document's ranges out of range for the *old* lastEmphasisRanges
        // anyway (see the guard below), so this is safe to call unconditionally.
        for range in lastEmphasisRanges where range.location + range.length <= storage.length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        lastEmphasisRanges = []
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
