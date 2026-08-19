import AppKit

/// Renders a `PaneTree.tabs` node: a tab strip over a stack of **resident**
/// child views (W1 — curated-agent-views).
///
/// Every child view is added once, up front, and kept alive for the whole
/// life of this `TabRegionView` — a tab switch is purely a visibility
/// toggle. That is deliberate (D6): no view is ever torn down or recreated,
/// so scroll position, `NSHostingView` identity, and `PaneContentModel` state
/// all survive a tab switch structurally, with no scroll-offset bookkeeping
/// of any kind needed.
///
/// Clicking a tab makes it frontmost immediately, with **no daemon round
/// trip** — this is operator input local to the client. The daemon's own
/// `active` index (and `focused_pane`, when it names one of this node's
/// children) are honoured only when a fresh tree arrives; after that,
/// frontmost-ness is this view's own state until the next structural update.
final class TabRegionView: NSView {

    // MARK: - Types

    /// One tab: a stable pane id, its display label, and the (already built,
    /// already resident) child view.
    struct Tab {
        let paneId: String
        let label: String
        let view: NSView
    }

    // MARK: - Init

    private var tabs: [Tab]
    private(set) var activePaneId: String

    /// Unread pane ids — a content push for a pane that isn't currently
    /// frontmost sets this; it clears the moment that tab becomes frontmost.
    /// Derived entirely client-side (D6) — the daemon has no business
    /// knowing which tab the operator is looking at.
    private var unreadPaneIds: Set<String> = []

    /// The frontmost content's `reason` (from its `PaneAddress`), shown as a
    /// dimmed, truncated caption under the tab's label.
    private var captions: [String: String] = [:]

    private let stripStack = NSStackView()
    private let contentContainer = NSView()
    private var tabButtons: [String: TabButtonView] = [:]

    init(tabs: [Tab], activePaneId: String) {
        self.tabs = tabs
        self.activePaneId = tabs.contains(where: { $0.paneId == activePaneId })
            ? activePaneId
            : (tabs.first?.paneId ?? activePaneId)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        stripStack.orientation = .horizontal
        stripStack.spacing = 0
        stripStack.distribution = .fillEqually
        stripStack.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stripStack)
        addSubview(contentContainer)

        NSLayoutConstraint.activate([
            stripStack.topAnchor.constraint(equalTo: topAnchor),
            stripStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stripStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripStack.heightAnchor.constraint(equalToConstant: Self.stripHeight),

            contentContainer.topAnchor.constraint(equalTo: stripStack.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for tab in tabs {
            let button = TabButtonView(label: tab.label) { [weak self] in
                self?.selectTab(tab.paneId)
            }
            tabButtons[tab.paneId] = button
            stripStack.addArrangedSubview(button)

            tab.view.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(tab.view)
            NSLayoutConstraint.activate([
                tab.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                tab.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                tab.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                tab.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        refreshVisibilityAndSelection()
    }

    private static let stripHeight: CGFloat = 26

    // MARK: - Public API

    /// Every pane id this region currently hosts, in tab order.
    var paneIds: [String] { tabs.map(\.paneId) }

    /// Bring `paneId` to front — called both for a local click and for a
    /// daemon-driven `focused_pane` hint that names one of this node's tabs.
    func selectTab(_ paneId: String) {
        guard tabs.contains(where: { $0.paneId == paneId }) else { return }
        activePaneId = paneId
        unreadPaneIds.remove(paneId)
        refreshVisibilityAndSelection()
    }

    /// Record a content push for `paneId`. Marks it unread (with no
    /// front-stealing) unless it's already the frontmost tab — a push for
    /// the visible tab is just... visible, not "unread."
    func noteContentPushed(for paneId: String) {
        guard paneId != activePaneId, tabs.contains(where: { $0.paneId == paneId }) else { return }
        unreadPaneIds.insert(paneId)
        refreshBadge(for: paneId)
    }

    /// Update the caption shown under `paneId`'s label — the frontmost
    /// content's `PaneAddress.reason`, dimmed and truncated. `nil` hides it.
    func setCaption(_ reason: String?, for paneId: String) {
        captions[paneId] = reason
        tabButtons[paneId]?.setCaption(reason)
    }

    // MARK: - Private

    private func refreshVisibilityAndSelection() {
        for tab in tabs {
            tab.view.isHidden = tab.paneId != activePaneId
            tabButtons[tab.paneId]?.setSelected(tab.paneId == activePaneId)
            refreshBadge(for: tab.paneId)
        }
    }

    private func refreshBadge(for paneId: String) {
        tabButtons[paneId]?.setUnread(unreadPaneIds.contains(paneId))
    }
}

// MARK: - TabButtonView

/// A single tab button: label, optional dimmed caption, and an unread dot.
private final class TabButtonView: NSView {
    private let label: String
    private let onClick: () -> Void

    private let labelField = NSTextField(labelWithString: "")
    private let captionField = NSTextField(labelWithString: "")
    private let unreadDot = NSView()
    private let clickButton = NSButton()

    init(label: String, onClick: @escaping () -> Void) {
        self.label = label
        self.onClick = onClick
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        labelField.stringValue = label
        labelField.font = Theme.tabFont
        labelField.textColor = Theme.fg
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false

        captionField.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        captionField.textColor = Theme.fgMuted
        captionField.lineBreakMode = .byTruncatingTail
        captionField.isHidden = true
        captionField.translatesAutoresizingMaskIntoConstraints = false

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = Theme.cornflower.cgColor
        unreadDot.layer?.cornerRadius = 3
        unreadDot.isHidden = true
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        clickButton.isBordered = false
        clickButton.title = ""
        clickButton.target = self
        clickButton.action = #selector(didClick)
        clickButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelField)
        addSubview(captionField)
        addSubview(unreadDot)
        addSubview(clickButton)

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labelField.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            captionField.leadingAnchor.constraint(equalTo: labelField.leadingAnchor),
            captionField.topAnchor.constraint(equalTo: labelField.bottomAnchor),
            captionField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            unreadDot.centerYAnchor.constraint(equalTo: topAnchor, constant: 8),
            unreadDot.widthAnchor.constraint(equalToConstant: 6),
            unreadDot.heightAnchor.constraint(equalToConstant: 6),

            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func didClick() { onClick() }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = (selected ? Theme.bgBarActive : Theme.bgBar).cgColor
        labelField.font = selected ? Theme.tabFontBold : Theme.tabFont
    }

    func setUnread(_ unread: Bool) {
        unreadDot.isHidden = !unread
    }

    func setCaption(_ text: String?) {
        if let text, !text.isEmpty {
            captionField.stringValue = text
            captionField.isHidden = false
        } else {
            captionField.stringValue = ""
            captionField.isHidden = true
        }
    }
}
