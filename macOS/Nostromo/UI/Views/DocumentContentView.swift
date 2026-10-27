import AppKit

/// The `document` renderer: a dated title and markdown blocks, with an optional banner strip above
/// and a row of action buttons below (Huey's report, context and setup panes).
///
/// Follows `TicketContentView`'s shape: a persistent sibling of `PaneContentNSView`'s hosting view,
/// shown for the `document` kind and hidden for the others, never torn down. All judgement —
/// payload -> attributed text, which links are actions — lives in `DocumentBlockDocument` and
/// `DocumentLinkPolicy` (host-less-testable). This view's job is obedience: draw what it is given,
/// and report a click as an action id or a URL to open.
///
/// Links: `https:` opens in the browser, `nostromo-action:<id>` is an action, anything else is
/// ignored. Buttons are always actions. The view never talks to the daemon itself; the owner wires
/// `onAction`.
final class DocumentContentView: NSView, NSTextViewDelegate {

    // MARK: - Hooks

    /// Called with an action id when a button, or a `nostromo-action:` link, is clicked.
    var onAction: (String) -> Void = { _ in }
    /// Called with an `https:` URL the reader clicked. Defaults to the system browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    // MARK: - Subviews

    private let stack = NSStackView()
    private let bannerBox = NSView()
    private let bannerLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let buttonRow = ActionButtonRow()

    /// The banner text currently shown, or nil when the strip is hidden.
    var bannerText: String? { bannerBox.isHidden ? nil : bannerLabel.stringValue }
    /// The banner's level, for the strip's colour.
    private(set) var bannerLevel: DocBannerLevel?
    /// The action buttons currently shown, in order.
    var actionButtons: [NSButton] { buttonRow.buttons }
    /// The rendered title and body.
    var renderedText: String { textView.string }

    private var document: DocumentBlockDocument?
    private var lastRendered: PaneContentWire?
    private var lastTitle: String?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        appearance = NSAppearance(named: .darkAqua)

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
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.appearance = NSAppearance(named: .darkAqua)
        scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)

        bannerBox.wantsLayer = true
        bannerBox.isHidden = true
        bannerLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        bannerLabel.textColor = Theme.fg
        bannerLabel.isSelectable = true
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerBox.addSubview(bannerLabel)
        NSLayoutConstraint.activate([
            bannerLabel.topAnchor.constraint(equalTo: bannerBox.topAnchor, constant: 6),
            bannerLabel.bottomAnchor.constraint(equalTo: bannerBox.bottomAnchor, constant: -6),
            bannerLabel.leadingAnchor.constraint(equalTo: bannerBox.leadingAnchor, constant: 10),
            bannerLabel.trailingAnchor.constraint(equalTo: bannerBox.trailingAnchor, constant: -10),
        ])

        buttonRow.isHidden = true
        buttonRow.onClick = { [weak self] id in self?.onAction(id) }

        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [bannerBox, scrollView, buttonRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Rendering

    /// Whether this view is the renderer for `content`. The one place the document kind is spelled,
    /// so `PaneContentNSView`'s show/hide and this view's own dispatch cannot disagree.
    static func handles(_ content: PaneContentWire?) -> Bool {
        if case .document = content { return true }
        return false
    }

    /// Render `content`. A document pushed again unchanged does no work at all.
    func update(content: PaneContentWire) {
        guard content != lastRendered else { return }
        guard case .document(let payload) = content else { return }
        let doc = DocumentBlockDocument(payload: payload)
        document = doc

        // Another day's report starts at the top; the same document refreshed (a verdict recorded,
        // a regeneration) keeps the reader's place.
        let keepPlace = payload.title == lastTitle
        let scrollY = scrollView.contentView.bounds.origin.y
        textView.textStorage?.setAttributedString(doc.attributedString)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: keepPlace ? scrollY : 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        showBanner(payload.banner)
        buttonRow.setActions(payload.actions)
        buttonRow.isHidden = payload.actions.isEmpty
        lastRendered = content
        lastTitle = payload.title
    }

    /// Drop everything held, the moment a pane stops rendering the `document` kind, so a later
    /// re-show can never resurface a previous document and `lastRendered` can never suppress a
    /// repaint the pane needs. Must not touch the subviews' identity.
    func clearContent() {
        lastRendered = nil
        lastTitle = nil
        document = nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        bannerBox.isHidden = true
        bannerLevel = nil
        buttonRow.setActions([])
        buttonRow.isHidden = true
    }

    private func showBanner(_ banner: DocBanner?) {
        guard let banner, !banner.text.isEmpty else {
            bannerBox.isHidden = true
            bannerLevel = nil
            return
        }
        bannerLabel.stringValue = banner.text
        let tint: NSColor = banner.level == .warning ? Theme.amber : Theme.cornflower
        bannerBox.layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
        bannerLevel = banner.level
        bannerBox.isHidden = false
    }

    // MARK: - Links

    /// Act on a clicked link: `https:` opens, `nostromo-action:` is an action, the rest is ignored.
    /// Always reports the click as handled so the text view never opens anything itself.
    @discardableResult
    func handleLink(_ link: Any) -> Bool {
        switch DocumentLinkPolicy.disposition(for: link) {
        case .openInBrowser(let url): openURL(url)
        case .action(let id): onAction(id)
        case .ignore: break
        }
        return true
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        handleLink(link)
    }
}

// MARK: - ActionButtonRow

/// The document's buttons, laid out left to right and wrapped onto further lines when the pane is
/// narrow, so no action is ever clipped away.
final class ActionButtonRow: NSView {
    var onClick: (String) -> Void = { _ in }
    private(set) var buttons: [NSButton] = []

    private let inset: CGFloat = 10
    private let gap: CGFloat = 8
    private let padding: CGFloat = 6
    private var measuredWidth: CGFloat = 0

    /// Rows run from the top edge down.
    override var isFlipped: Bool { true }

    func setActions(_ actions: [DocAction]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = actions.map { action in
            let button = ActionButton(title: action.label, actionID: action.id)
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.appearance = NSAppearance(named: .darkAqua)
            if action.primary { button.bezelColor = Theme.cornflower }
            button.target = self
            button.action = #selector(didClick(_:))
            button.sizeToFit()
            addSubview(button)
            return button
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: place(width: measuredWidth, apply: false))
    }

    override func layout() {
        super.layout()
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = place(width: bounds.width, apply: true)
    }

    /// Lay the buttons out in `width` and return the height they need.
    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        guard !buttons.isEmpty else { return 0 }
        let usable = max(width, 1) - inset * 2
        var x: CGFloat = 0
        var rowTop: CGFloat = padding
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.frame.size
            if x > 0, x + size.width > usable {
                x = 0
                rowTop += rowHeight + gap
                rowHeight = 0
            }
            if apply { button.setFrameOrigin(NSPoint(x: inset + x, y: rowTop)) }
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return rowTop + rowHeight + padding
    }

    @objc private func didClick(_ sender: NSButton) {
        guard let button = sender as? ActionButton else { return }
        onClick(button.actionID)
    }
}

/// A button that remembers the action id it stands for.
final class ActionButton: NSButton {
    let actionID: String

    init(title: String, actionID: String) {
        self.actionID = actionID
        super.init(frame: .zero)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }
}
