import AppKit
import Combine

// The Teri focus: a tab strip (Picks · Todos · Jira · Sentry · Repo docs), the
// selected tab's list on the left and the selected item's detail on the right.
// It reads from an injected `WorkStore` and never touches `AppStore`; the glue
// lives in `TeriBindings`.

/// What a tab contributes to the surface. Each tab file exposes one.
struct TeriTabConfig {
    let tab: TeriTab
    /// Capitalised name used in banners ("Jira: …").
    let sourceName: String
    /// nil for a tab with no list (Picks has its own view, `TeriPicksView`).
    let list: WorkListConfig?
    /// Shown over an empty list when the source is healthy and has nothing.
    let emptyMessage: String
    /// The tab became visible (including the restored tab at launch).
    var onShow: (() -> Void)?
    /// The user left the tab, or the surface went away while it was showing.
    var onLeave: (() -> Void)?
    /// Rows that read differently as time passes ("last seen 4 min ago"): redrawn
    /// every this many seconds while the tab is showing, and whenever it is shown.
    var rowRefreshInterval: TimeInterval?
}

final class TeriSurfaceView: NSView {
    private(set) var selectedTab: TeriTab
    /// The Picks tab's list pane (shown while Picks is the selected tab).
    private(set) var picksView: TeriPicksView?
    /// Open the Send to agent sheet for this item id. Set by `TeriBindings`, which owns the
    /// sheet; nil in tests that do not look at it.
    var onSendToAgent: ((String) -> Void)?
    /// Go to the focus or Mother job a "sent to …" marker names. Set by `TeriBindings`.
    var onOpenSent: ((SentMarker) -> Void)?

    private let store: WorkStore
    private let viewState: TeriViewStateStore
    private let center: NotificationCenter
    private let scheduler: WorkScheduler
    private var cancellables = Set<AnyCancellable>()
    private var deepLinkObserver: NSObjectProtocol?
    private var cancelRowRefresh: (() -> Void)?

    private let tabStrip = NSStackView()
    private var tabButtons: [TeriTab: NSButton] = [:]
    private let disconnectedBanner = SourceStateBanner()
    private let sourceBanner = SourceStateBanner()
    private let splitView = TeriSplitView()
    private let listHost = NSView()
    private let detailView = WorkDetailView()
    private let configs: [TeriTab: TeriTabConfig]

    private var lists: [TeriTab: WorkListView] = [:]
    private var reloadScheduled = false
    /// Bumped on every reload so a slow background derivation never overwrites a newer one.
    private var derivationGeneration = 0
    /// The item the detail pane is showing (or loading), to avoid re-requesting it.
    private var detailItem: WorkItem?
    private var detailToken = 0
    /// The split width the remembered fraction was last applied for: it is applied
    /// again whenever the split view's width changes (a window resize keeps the ratio).
    private var splitAppliedWidth: CGFloat = 0

    // MARK: Init

    init(store: WorkStore, defaults: UserDefaults = .standard, center: NotificationCenter = .default,
         scheduler: WorkScheduler = .main, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.store = store
        self.center = center
        self.scheduler = scheduler
        let viewState = TeriViewStateStore(defaults: defaults, scheduler: scheduler, center: center)
        self.viewState = viewState
        let all = [TeriPicksTab.config, TeriTodosTab.config, TeriJiraTab.config,
                   TeriSentryTab.config, TeriRepoDocsTab.config]
        self.configs = Dictionary(uniqueKeysWithValues: all.map { ($0.tab, $0) })
        // Restored tab, else Picks once picks exist, else Todos.
        self.selectedTab = viewState.state.selectedTab
            ?? ((store.picks?.items.isEmpty == false) ? .picks : .todos)
        super.init(frame: .zero)
        let picksView = TeriPicksView(store: store, now: now, calendar: calendar)
        picksView.onSelect = { [weak self] pick in self?.pickSelected(pick) }
        picksView.onOpenSent = { [weak self] _, marker in self?.onOpenSent?(marker) }
        self.picksView = picksView
        buildViews()
        observe()
        tabBecameVisible(selectedTab)
        showSelectedTab()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let deepLinkObserver { center.removeObserver(deepLinkObserver) }
        viewState.flush()   // a change made in the last half second must not be lost
        cancelRowRefresh?()
        tabWasLeft(selectedTab)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusActiveList()
    }

    // MARK: Public

    /// Switch to `tab` (remembered across relaunches).
    func select(_ tab: TeriTab) {
        guard tab != selectedTab else { return }
        tabWasLeft(selectedTab)
        selectedTab = tab
        viewState.update { $0.selectedTab = tab }
        tabBecameVisible(tab)
        showSelectedTab()
    }

    /// Select an item in the current tab (as if the user had clicked it).
    func selectItem(id: String) {
        viewState.update { $0[selectedTab].selectedItemId = id }
        lists[selectedTab]?.select(itemId: id)
        syncDetail()
    }

    /// The tab strip text: "Todos 2", or a marker such as "Jira ○ Coming soon".
    func tabButtonTitle(_ tab: TeriTab) -> String {
        Self.tabTitle(tab, status: tab.source.flatMap { store.status(for: $0) },
                      itemCount: tab.source.map { store.items(for: $0).count } ?? (store.picks?.items.count ?? 0),
                      hasPicks: store.picks != nil)
    }

    /// The banner of the selected tab's source, nil when hidden.
    var visibleBannerMessage: String? { sourceBanner.isHidden ? nil : sourceBanner.content?.message }

    /// Positive "nothing here" message: only for a healthy source with no items.
    var emptyMessage: String? {
        guard let source = selectedTab.source, store.status(for: source)?.state == .empty,
              store.items(for: source).isEmpty else { return nil }
        return configs[selectedTab]?.emptyMessage
    }

    /// Width of the list pane as a fraction of the split view.
    var listPaneFraction: CGFloat {
        splitView.bounds.width > 0 ? listHost.frame.width / splitView.bounds.width : 0
    }

    var isDisconnectedBannerVisible: Bool { !disconnectedBanner.isHidden }

    /// True while the daemon connection is down: tabs are dimmed but keep their data.
    var allTabsDimmed: Bool { tabStrip.alphaValue < 1 && splitView.alphaValue < 1 }

    /// Item rows of the selected tab as drawn, in order.
    var rowTexts: [WorkRowContent] { lists[selectedTab]?.visibleRows ?? [] }

    var groupHeaderTexts: [String] { lists[selectedTab]?.visibleGroupHeaders ?? [] }

    /// The selected tab's remembered selection.
    var selectedItemId: String? { viewState.state[selectedTab].selectedItemId }

    /// Title shown in the detail pane (the item's own while loading).
    var detailTitle: String? { detailView.shownTitle }

    // MARK: Keyboard

    /// ⌘⇧S: send the selected row (or pick) to an agent. False when nothing is selected.
    @discardableResult
    func sendSelectedToAgent() -> Bool {
        let id = selectedTab == .picks ? picksView?.selectedPickId : lists[selectedTab]?.selectedItem?.id
        guard let id, let onSendToAgent else { return false }
        onSendToAgent(id)
        return true
    }

    /// Show (or stop showing) that a send is being prepared: the detail pane's button and spinner.
    func setSendPreparing(_ preparing: Bool) {
        detailView.setSendPreparing(preparing)
    }

    /// Click the "sent to …" marker on `itemId`'s row in the current tab (tests).
    @discardableResult
    func clickSentMarker(itemId: String) -> Bool {
        lists[selectedTab]?.clickSentMarker(itemId: itemId) ?? false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, isInKeyWindowResponderChain, flags == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "s", sendSelectedToAgent() {
            return true
        }
        guard event.type == .keyDown, isInKeyWindowResponderChain,
              flags == .command,
              let key = event.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: event) }

        switch key {
        case "1", "2", "3", "4", "5":
            select(TeriTab.allCases[Int(key)! - 1])
            return true
        case "r":
            if let source = selectedTab.source { store.refresh(source: source) } else { picksView?.pressRefresh() }
            return true
        case "f":
            guard let list = lists[selectedTab] else { return false }
            list.focusSearch()
            return true
        case "o":
            return detailView.openPrimary()
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// ⌘1–⌘5 and friends only act while this surface owns the keyboard, so they
    /// never steal a shortcut from another focus or window.
    private var isInKeyWindowResponderChain: Bool {
        guard let window, window.isKeyWindow else { return false }
        if window.firstResponder === self { return true }
        return (window.firstResponder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: Build

    private func buildViews() {
        tabStrip.orientation = .horizontal
        tabStrip.spacing = 6
        tabStrip.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for tab in TeriTab.allCases {
            let button = NSButton(title: tab.title, target: self, action: #selector(tabClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .recessed
            button.tag = TeriTab.allCases.firstIndex(of: tab) ?? 0
            button.setAccessibilityLabel(tab.title)
            tabButtons[tab] = button
            tabStrip.addArrangedSubview(button)
        }

        for banner in [disconnectedBanner, sourceBanner] {
            banner.wantsLayer = true
            banner.layer?.backgroundColor = Theme.bgBar.cgColor
            banner.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        sourceBanner.onRetry = { [weak self] in
            guard let self else { return }
            self.store.refresh(source: self.selectedTab.source)
        }

        listHost.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.onDividerDragEnded = { [weak self] in self?.dividerDragEnded() }
        splitView.onLayout = { [weak self] in self?.applyRememberedSplit() }
        detailView.onSendToAgent = { [weak self] id in self?.onSendToAgent?(id) }
        splitView.addArrangedSubview(listHost)
        splitView.addArrangedSubview(detailView)
        listHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        detailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabStrip.setContentHuggingPriority(.required, for: .vertical)

        let column = NSStackView(views: [tabStrip, disconnectedBanner, sourceBanner, splitView])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            disconnectedBanner.widthAnchor.constraint(equalTo: column.widthAnchor),
            sourceBanner.widthAnchor.constraint(equalTo: column.widthAnchor),
            splitView.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
    }

    private func observe() {
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)
        deepLinkObserver = center.addObserver(forName: .nostromoFocusDeepLink, object: nil, queue: .main) { [weak self] note in
            guard case .teriTab(let id)? = note.object as? FocusDeepLinkTarget, let tab = TeriTab(rawValue: id) else { return }
            self?.select(tab)
        }
    }

    // MARK: Tabs

    @objc private func tabClicked(_ sender: NSButton) {
        guard TeriTab.allCases.indices.contains(sender.tag) else { return }
        let tab = TeriTab.allCases[sender.tag]
        select(tab)
        updateTabButtons()   // a click toggled the button; show the real selection
        focusActiveList()    // a button click does not take the keyboard; the list should
    }

    private func tabBecameVisible(_ tab: TeriTab) {
        configs[tab]?.onShow?()
        if tab == .picks { picksView?.tabDidShow() }
    }

    private func tabWasLeft(_ tab: TeriTab) {
        configs[tab]?.onLeave?()
        if tab == .picks { picksView?.tabDidLeave() }
    }

    private func showSelectedTab() {
        for subview in listHost.subviews { subview.removeFromSuperview() }
        if selectedTab == .picks, let picks = picksView {
            picks.translatesAutoresizingMaskIntoConstraints = false
            listHost.addSubview(picks)
            NSLayoutConstraint.activate([
                picks.topAnchor.constraint(equalTo: listHost.topAnchor),
                picks.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
                picks.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
                picks.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),
            ])
        } else if let list = listView(for: selectedTab) {
            list.translatesAutoresizingMaskIntoConstraints = false
            listHost.addSubview(list)
            NSLayoutConstraint.activate([
                list.topAnchor.constraint(equalTo: listHost.topAnchor),
                list.bottomAnchor.constraint(equalTo: listHost.bottomAnchor),
                list.leadingAnchor.constraint(equalTo: listHost.leadingAnchor),
                list.trailingAnchor.constraint(equalTo: listHost.trailingAnchor),
            ])
        }
        detailItem = nil
        detailToken += 1
        detailView.show(.none)
        armRowRefresh()
        reload()
        if selectedTab == .picks, let id = viewState.state[.picks].selectedItemId {
            picksView?.select(itemId: id)   // the remembered pick's detail, when it is still picked
        }
        focusActiveList()
    }

    /// Redraw the selected tab's rows now and then, for a tab whose rows depend on the clock.
    private func armRowRefresh() {
        cancelRowRefresh?()
        cancelRowRefresh = nil
        guard let interval = configs[selectedTab]?.rowRefreshInterval else { return }
        let tab = selectedTab
        lists[tab]?.refreshRows()
        cancelRowRefresh = scheduler.schedule(interval) { [weak self] in
            guard let self, self.selectedTab == tab else { return }
            self.armRowRefresh()
        }
    }

    /// Give the keyboard to the active tab's list (or to the surface itself when
    /// the tab has none), so ⌘1–⌘5, ⌘F, ⌘R and ⌘O work without a click first.
    /// Never takes it from text being edited elsewhere in the window.
    private func focusActiveList() {
        guard let window,
              TeriFocusPolicy.mayTakeKeyboard(currentFirstResponder: window.firstResponder, surface: self)
        else { return }
        if let list = lists[selectedTab] {
            list.focusList()
        } else if selectedTab == .picks, let picks = picksView {
            picks.focusRows()
        } else {
            window.makeFirstResponder(self)
        }
    }

    /// The list for `tab`, created on first use with its remembered filter state.
    private func listView(for tab: TeriTab) -> WorkListView? {
        if let existing = lists[tab] { return existing }
        guard let config = configs[tab]?.list else { return nil }
        let list = WorkListView(config: config, scheduler: scheduler)
        let remembered = viewState.state[tab]
        list.restore(filter: remembered.filter, sort: remembered.sort, collapsedGroups: remembered.collapsedGroups)
        list.onSelectionChange = { [weak self] item in
            self?.viewState.update { $0[tab].selectedItemId = item?.id }
            self?.syncDetail()
        }
        list.onFilterChange = { [weak self] filter, sort in
            self?.viewState.update { $0[tab].filter = filter; $0[tab].sort = sort }
            self?.reload()
        }
        list.onCollapsedGroupsChange = { [weak self] groups in
            self?.viewState.update { $0[tab].collapsedGroups = groups }
        }
        list.onOpen = { [weak self] _ in self?.detailView.focusDetail() }
        list.onOpenSent = { [weak self] _, marker in self?.onOpenSent?(marker) }
        lists[tab] = list
        return list
    }

    // MARK: Reload

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    private func reload() {
        updateTabButtons()
        let dim: CGFloat = store.isConnected ? 1 : 0.5
        tabStrip.alphaValue = dim
        splitView.alphaValue = dim
        if store.isConnected { disconnectedBanner.isHidden = true } else { disconnectedBanner.showDisconnected() }

        guard let source = selectedTab.source, let config = configs[selectedTab], let list = listView(for: selectedTab) else {
            // Picks: its own view reads the store, and its detail follows its selection.
            sourceBanner.clear()
            return
        }
        let status = store.status(for: source)
        sourceBanner.show(status: status, sourceName: config.sourceName)

        let tab = selectedTab
        let remembered = viewState.state[tab]
        derivationGeneration += 1
        let generation = derivationGeneration
        let isLoading = status == nil || status?.state == .loading
        let placeholder = emptyMessage
        store.computeListSnapshot(source: source, filter: remembered.filter, sort: remembered.sort,
                                  facets: config.list?.facets ?? []) { [weak self] snapshot in
            guard let self, generation == self.derivationGeneration, tab == self.selectedTab else { return }
            list.apply(snapshot: snapshot, isLoading: isLoading, placeholder: placeholder)
            if let id = remembered.selectedItemId, list.selectedItem?.id != id {
                list.select(itemId: id)
            }
            self.syncDetail()
        }
    }

    private func updateTabButtons() {
        for tab in TeriTab.allCases {
            guard let button = tabButtons[tab] else { continue }
            let title = tabButtonTitle(tab)
            let selected = tab == selectedTab
            button.title = title
            // A recessed push-on-push-off button draws its off state with a system colour
            // that almost vanishes on a dark surface (and goes dimmer still when the
            // window is not key). Colour the label explicitly so every tab stays legible.
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: selected ? NSColor.white : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: selected ? .semibold : .regular),
            ])
            button.state = selected ? .on : .off
            button.setAccessibilityLabel(title)
        }
    }

    // MARK: Detail

    /// Make the detail pane show the remembered selection, asking the daemon when needed.
    private func syncDetail() {
        guard let list = lists[selectedTab], let id = viewState.state[selectedTab].selectedItemId,
              let item = list.selectedItem, item.id == id
        else {
            if detailItem != nil { detailItem = nil; detailToken += 1; detailView.show(.none) }
            return
        }
        if detailItem == item { return }
        let isNewItem = detailItem?.id != id
        detailItem = item
        detailToken += 1
        let token = detailToken
        if isNewItem { detailView.show(.loading(title: item.title), item: item) }
        loadDetail(id, title: item.title, item: item, token: token)
    }

    /// A pick was chosen (or went away): show the detail the item has in its own tab.
    private func pickSelected(_ pick: Pick?) {
        viewState.update { $0[.picks].selectedItemId = pick?.itemId }
        detailItem = nil
        detailToken += 1
        guard let pick else {
            detailView.show(.none)
            return
        }
        let token = detailToken
        let item = store.allItems.first { $0.id == pick.itemId }
        detailView.show(.loading(title: pick.title), item: item)
        loadDetail(pick.itemId, title: pick.title, item: item, token: token)
    }

    /// Ask the daemon for `id`'s detail and show it, unless `token` has gone stale.
    private func loadDetail(_ id: String, title: String, item: WorkItem?, token: Int) {
        store.requestDetail(id) { [weak self] response in
            guard let self, token == self.detailToken else { return }
            switch response {
            case .detail(.ok(let detail)):
                self.detailView.show(.detail(detail), item: item)
            case .detail(.err(let error)), .failed(let error):
                self.failDetail(title: title, item: item, message: error.message)
            case .timedOut:
                self.failDetail(title: title, item: item, message: "The daemon did not answer in time")
            case .sendPreview, .sendResult:
                break
            }
        }
    }

    private func failDetail(title: String, item: WorkItem?, message: String) {
        detailItem = nil   // the next reload tries again
        detailView.show(.failed(title: title, message: message), item: item)
    }

    // MARK: Tab titles

    /// "Todos 2" for a source with data, "Jira ○ Coming soon" for one without.
    static func tabTitle(_ tab: TeriTab, status: SourceStatus?, itemCount: Int, hasPicks: Bool) -> String {
        if tab == .picks {
            return hasPicks ? "\(tab.title) \(itemCount)" : "\(tab.title) ○ Coming soon"
        }
        guard let status else { return "\(tab.title) ◌ Loading" }
        switch status.state {
        case .fresh, .stale, .empty:  return "\(tab.title) \(itemCount)"
        case .loading:                return "\(tab.title) ◌ Loading"
        case .notConfigured:          return "\(tab.title) ○ \(status.reason == "Coming soon" ? "Coming soon" : "Not set up")"
        case .unauthenticated:        return "\(tab.title) ⊘ Sign in"
        case .rateLimited:            return "\(tab.title) ◔ Rate-limited"
        case .error:                  return "\(tab.title) ⚠ Error"
        }
    }
}

// MARK: - Split position

extension TeriSurfaceView {
    /// The user let go of the divider: remember where it is. (AppKit's own
    /// resize notifications cannot be told apart from a drag, so only the mouse
    /// tracking in `TeriSplitView` counts.)
    func dividerDragEnded() {
        guard splitView.bounds.width > 0 else { return }
        let fraction = Double(listPaneFraction)
        viewState.update { $0.splitFraction = fraction }
    }

    /// Put the divider where the user left it, and keep that proportion when the window is resized.
    fileprivate func applyRememberedSplit() {
        let width = splitView.bounds.width
        guard width > 0, width != splitAppliedWidth, let fraction = viewState.state.splitFraction else { return }
        splitAppliedWidth = width
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(CGFloat(fraction) * width, ofDividerAt: 0)
    }
}

/// The split view, telling its owner when a divider drag ends.
final class TeriSplitView: DarkSplitView {
    var onDividerDragEnded: (() -> Void)?
    /// Called after every layout pass (the split view's width is final by then).
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // tracks the drag until the mouse is released
        onDividerDragEnded?()
    }
}

// MARK: - Keyboard focus policy

enum TeriFocusPolicy {
    /// Whether the surface may move the keyboard into its list: when nothing in the
    /// window holds it, or the holder is part of the surface. Never from text being
    /// edited (or selected) in a text view elsewhere (the idea of
    /// `TranscriptFocusPolicy`), nor from another visible view.
    static func mayTakeKeyboard(currentFirstResponder: NSResponder?, surface: NSView) -> Bool {
        if let text = currentFirstResponder as? NSTextView {
            // A field editor is the window's transient editor for whichever field is
            // being edited; the field is the thing that lives in a view hierarchy.
            let owner: NSView? = text.isFieldEditor ? text.delegate as? NSView : text
            return owner?.isDescendant(of: surface) ?? false
        }
        // Another live view in the window (another focus's list) keeps its keyboard.
        guard let view = currentFirstResponder as? NSView else { return true }
        return view.isDescendant(of: surface) || view.isHiddenOrHasHiddenAncestor
    }
}
