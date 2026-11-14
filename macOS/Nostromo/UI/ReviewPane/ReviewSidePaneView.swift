import AppKit
import Combine
import WebKit

/// One tab in the strip. Reads as a radio-button tab ("tab 2 of 3, #4520 Diff, pull request 4520 in
/// carefeed/referral-monitor") with its own close button ("Close #4520 Diff").
final class ReviewTabItemView: NSView {
    let tab: ReviewTab
    let closeButton = NSButton()
    private let titleField = NSTextField(labelWithString: "")
    var onSelect: ((ReviewTab) -> Void)?
    var onClose: ((ReviewTab) -> Void)?
    var onCloseOthers: ((ReviewTab) -> Void)?

    init(tab: ReviewTab, position: Int, count: Int, selected: Bool) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (selected ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.15, alpha: 1)).cgColor
        layer?.cornerRadius = 4
        titleField.stringValue = (tab.unsent ? "● " : "") + tab.title
        titleField.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        titleField.textColor = NSColor(white: selected ? 1 : 0.82, alpha: 1)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor(white: 0.82, alpha: 1)
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("Close \(tab.title)")
        closeButton.toolTip = "Close \(tab.title)"
        let stack = NSStackView(views: [titleField, closeButton])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 90), widthAnchor.constraint(lessThanOrEqualToConstant: 190),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
        ])
        toolTip = tab.fullDescription
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("tab \(position) of \(count), \(tab.fullDescription)")
        setAccessibilityValue(selected ? 1 : 0)
        let menu = NSMenu()
        menu.addItem(withTitle: "Close Tab", action: #selector(closePressed), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOthersPressed), keyEquivalent: "").target = self
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseDown(with event: NSEvent) { onSelect?(tab) }
    override func accessibilityPerformPress() -> Bool { onSelect?(tab); return true }
    @objc private func closePressed() { onClose?(tab) }
    @objc private func closeOthersPressed() { onCloseOthers?(tab) }
}

/// The tab group: a horizontal strip of `ReviewTabItemView`.
final class ReviewTabStripView: NSView {
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private(set) var items: [ReviewTabItemView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Side pane tabs")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(tabs: [ReviewTab], activeID: ReviewTab.ID?, make: (ReviewTab, Int, Int, Bool) -> ReviewTabItemView) {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        items = tabs.enumerated().map { make($1, $0 + 1, tabs.count, $1.id == activeID) }
        items.forEach { stack.addArrangedSubview($0) }
        setAccessibilityTabs(items)
        setAccessibilityChildren(items)
    }
}

/// The side pane: tab strip, per-tab chrome (back, forward, reload, host and path, Open in Browser) and
/// the active tab's web view. Painted over in app-control screenshots and read as one fixed entry by
/// `tree`/`find`/`ax` (SR7).
final class ReviewSidePaneView: NSView, TerminalPixelSource {

    var terminalPixelArea: NSView { self }
    var pixelAreaLabel: String { AppControlAX.reviewPaneHiddenText }

    static let minimumWidth: CGFloat = 380

    let model: ReviewPaneModel
    let strip = ReviewTabStripView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let locationField = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open in Browser", target: nil, action: nil)
    private let contentArea = NSView()
    private let otherWindowCover = ReviewMessageView(opaque: true)
    private var shownController: ReviewTabController?
    private var cancellables = Set<AnyCancellable>()
    private var navObservers: [NSKeyValueObservation] = []

    /// Asks before discarding unsent text. Default: a Nostromo sheet. Tests replace it.
    var confirmDiscard: (ReviewTab, NSWindow?) async -> Bool = ReviewSidePaneView.runDiscardSheet

    init(model: ReviewPaneModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Review side pane")
        buildChrome()
        otherWindowCover.show("Side pane is open in another window.")
        otherWindowCover.isHidden = true
        Publishers.CombineLatest(model.$tabs, model.$activeID)
            .sink { [weak self] tabs, active in self?.apply(tabs: tabs, activeID: active) }
            .store(in: &cancellables)
        model.$presenterID
            .sink { [weak self] id in
                guard let self else { return }
                self.otherWindowCover.isHidden = id == nil || id == ObjectIdentifier(self)
                if !self.otherWindowCover.isHidden { self.detachShown() }
                else { self.apply(tabs: self.model.tabs, activeID: self.model.activeID) }
            }
            .store(in: &cancellables)
        model.focusRequests
            .sink { [weak self] in self?.focusActiveWebView() }
            .store(in: &cancellables)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            model.claimPresenter(ObjectIdentifier(self))
            apply(tabs: model.tabs, activeID: model.activeID)
        }
    }

    /// Whether this view owns the web views (the most recently shown window's pane does).
    private var isPresenter: Bool { model.presenterID == nil || model.presenterID == ObjectIdentifier(self) }

    // MARK: Tabs

    func focusActiveWebView() {
        guard isPresenter, let controller = shownController else { return }
        controller.focusWebView()
    }

    /// Closes after asking when the tab holds unsent text.
    func requestClose(_ tab: ReviewTab) async {
        if await model.unsentCheck(tab) {
            guard await confirmDiscard(tab, window) else { return }
        }
        model.close(tab)
    }

    private func apply(tabs: [ReviewTab], activeID: ReviewTab.ID?) {
        strip.apply(tabs: tabs, activeID: activeID) { [weak self] tab, position, count, selected in
            let item = ReviewTabItemView(tab: tab, position: position, count: count, selected: selected)
            item.onSelect = { self?.model.focus($0) }
            item.onClose = { tab in Task { @MainActor in await self?.requestClose(tab) } }
            item.onCloseOthers = { tab in self?.model.closeOthers(than: tab) }
            return item
        }
        guard isPresenter, window != nil else { return }
        let active = tabs.first { $0.id == activeID }
        detachShown()
        guard let active else { updateChrome(nil); return }
        let controller = model.ensureController(for: active)
        shownController = controller
        let view = controller.contentView
        view.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor), view.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentArea.topAnchor), view.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
        controller.loadInitial()
        updateChrome(controller)
    }

    private func detachShown() {
        shownController?.contentView.removeFromSuperview()
        shownController = nil
        navObservers.removeAll()
    }

    // MARK: Chrome

    private func buildChrome() {
        for (button, symbol, label, action) in [
            (backButton, "chevron.left", "Back", #selector(goBack)),
            (forwardButton, "chevron.right", "Forward", #selector(goForward)),
            (reloadButton, "arrow.clockwise", "Reload", #selector(reload)),
        ] as [(NSButton, String, String, Selector)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.contentTintColor = NSColor(white: 0.9, alpha: 1)
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.target = self
            button.action = action
        }
        locationField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        locationField.textColor = NSColor(white: 0.82, alpha: 1)
        locationField.lineBreakMode = .byTruncatingMiddle
        locationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.target = self
        openButton.action = #selector(openInBrowser)
        openButton.toolTip = "Open this page in your default browser"
        let bar = NSStackView(views: [backButton, forwardButton, reloadButton, locationField, openButton])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        let column = NSStackView(views: [strip, bar, contentArea])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        otherWindowCover.translatesAutoresizingMaskIntoConstraints = false
        addSubview(otherWindowCover)
        for sub in [strip, bar, contentArea] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: 30),
            bar.heightAnchor.constraint(equalToConstant: 28),
            otherWindowCover.leadingAnchor.constraint(equalTo: leadingAnchor), otherWindowCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            otherWindowCover.topAnchor.constraint(equalTo: topAnchor), otherWindowCover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateChrome(nil)
    }

    private func updateChrome(_ controller: ReviewTabController?) {
        navObservers.removeAll()
        guard let controller else {
            locationField.stringValue = ""
            [backButton, forwardButton, reloadButton, openButton].forEach { $0.isEnabled = false }
            return
        }
        let web = controller.webView
        let refresh = { [weak self, weak web, weak controller] in
            guard let self, let web, let controller else { return }
            self.backButton.isEnabled = web.canGoBack
            self.forwardButton.isEnabled = web.canGoForward
            self.reloadButton.isEnabled = true
            self.openButton.isEnabled = true
            let url = web.url ?? controller.tab.currentURL
            self.locationField.stringValue = (url.host ?? "") + url.path
        }
        navObservers = [
            web.observe(\.url) { _, _ in refresh() },
            web.observe(\.canGoBack) { _, _ in refresh() },
            web.observe(\.canGoForward) { _, _ in refresh() },
        ]
        refresh()
    }

    @objc private func goBack() { shownController?.webView.goBack() }
    @objc private func goForward() { shownController?.webView.goForward() }
    @objc private func reload() { shownController?.webView.reload() }
    @objc private func openInBrowser() { shownController?.openCurrentInBrowser() }

    // MARK: Discard sheet

    @MainActor
    static func runDiscardSheet(tab: ReviewTab, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard the text you typed in \(tab.title)?"
        alert.informativeText = "It hasn't been sent. Closing the tab loses it."
        alert.addButton(withTitle: "Keep Tab")        // default
        alert.addButton(withTitle: "Close Tab")
        guard let window else { return alert.runModal() == .alertSecondButtonReturn }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertSecondButtonReturn) }
        }
    }
}
