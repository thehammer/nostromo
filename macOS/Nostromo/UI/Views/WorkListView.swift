import AppKit

// The list half of every Teri tab: a filter bar over a view-based
// `NSOutlineView` (row reuse, 1,000 items without dropped frames). The view
// knows nothing about todos, Jira or Sentry: the tab hands it a
// `WorkListConfig` (how to draw a row, how to title a group, which filters to
// offer) and the surface feeds it `WorkListSnapshot`s.

// MARK: - Configuration

/// What a row shows. Built by the tab; `WorkListView` only lays it out.
struct WorkRowContent: Equatable {
    /// "P1" … "P5": priority is text first, colour second.
    var priorityText: String?
    /// 1 = most urgent; colours the priority text.
    var priorityRank: Int?
    var title: String
    /// "Overdue by 2 days", "Due today", "Due Fri".
    var dueText: String?
    /// Overdue or due today: drawn in the alert colour.
    var dueIsUrgent: Bool
    var statusText: String?
    /// What VoiceOver reads: source, type, title, priority, age.
    var accessibilityLabel: String

    init(priorityText: String? = nil, priorityRank: Int? = nil, title: String, dueText: String? = nil,
         dueIsUrgent: Bool = false, statusText: String? = nil, accessibilityLabel: String) {
        self.priorityText = priorityText
        self.priorityRank = priorityRank
        self.title = title
        self.dueText = dueText
        self.dueIsUrgent = dueIsUrgent
        self.statusText = statusText
        self.accessibilityLabel = accessibilityLabel
    }
}

/// How a tab wants its list to look and which filters it offers.
struct WorkListConfig {
    /// Draws one row.
    var rowContent: (WorkItem) -> WorkRowContent
    /// Header text of a group (only called for sources that have groups).
    var groupTitle: (WorkGroup) -> String = { $0.key ?? "" }
    /// One toggle chip per value of this facet, with its count.
    var chipFacet: WorkFacet?
    /// Multi-select menus, one per facet.
    var menuFacets: [WorkFacet] = []
    /// Sort choices; the popup is hidden when there are fewer than two.
    var sortOptions: [(title: String, key: WorkSortKey)] = []
    var searchPlaceholder: String = "Filter"

    /// A plain title + status row, for sources whose tab has not been built yet.
    static func generic(sourceLabel: String) -> WorkListConfig {
        WorkListConfig(rowContent: { item in
            WorkRowContent(
                priorityText: item.priority?.label,
                priorityRank: item.priority?.rank,
                title: item.title,
                statusText: item.status,
                accessibilityLabel: "\(sourceLabel) \(item.kind), \(item.title)")
        })
    }

    /// Every facet the filter bar needs counted.
    var facets: [WorkFacet] { (chipFacet.map { [$0] } ?? []) + menuFacets }
}

// MARK: - View

final class WorkListView: NSView {
    var onSelectionChange: ((WorkItem?) -> Void)?
    /// Return (or double-click) on a row.
    var onOpen: ((WorkItem) -> Void)?
    var onFilterChange: ((WorkFilter, WorkSortKey) -> Void)?
    var onCollapsedGroupsChange: (([String]) -> Void)?

    private(set) var filter = WorkFilter()
    private(set) var sort: WorkSortKey = .newest
    private(set) var collapsedGroups: Set<String> = []

    private let config: WorkListConfig
    private let outline = WorkOutlineView()
    private let scroll = NSScrollView()
    private let filterBar = NSStackView()
    private let chipStack = NSStackView()
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var menuButtons: [WorkFacet: NSPopUpButton] = [:]
    private let placeholderLabel = NSTextField(wrappingLabelWithString: "")
    private let skeleton = WorkSkeletonView()

    private let scheduler: WorkScheduler
    private let searchDebounce: TimeInterval
    private var cancelPendingSearch: (() -> Void)?

    private var roots: [Node] = []
    private var snapshot: WorkListSnapshot?
    private var isApplying = false
    /// What the outline currently shows, to skip a reload when nothing visible changed.
    private var shownLayout: [LayoutEntry]?
    /// What the filter bar was last built for.
    private var shownControls: ControlsKey?
    /// Row content by item id, valid for one calendar day (rows say "Due today").
    private var rowCache: [String: (item: WorkItem, content: WorkRowContent)] = [:]
    private var rowCacheDay: Date?

    /// How many times the chips and menus were rebuilt (tests: unchanged data must not rebuild).
    private(set) var filterControlRebuildCount = 0

    // MARK: Nodes

    private final class Node {
        var item: WorkItem?
        let content: WorkRowContent?
        let groupKey: String?
        let groupTitle: String?
        var children: [Node]

        init(item: WorkItem, content: WorkRowContent) {
            self.item = item; self.content = content
            groupKey = nil; groupTitle = nil; children = []
        }

        init(groupKey: String, title: String, children: [Node]) {
            item = nil; content = nil
            self.groupKey = groupKey; groupTitle = title; self.children = children
        }
    }

    /// One row of the outline as drawn: what must differ for a reload to be needed.
    private struct LayoutEntry: Equatable {
        let groupKey: String?
        let groupTitle: String?
        let itemId: String?
        let content: WorkRowContent?
        let depth: Int
    }

    private struct ControlsKey: Equatable {
        let counts: [WorkFacet: [String: Int]]
        let filter: WorkFilter
    }

    // MARK: Init

    init(config: WorkListConfig, scheduler: WorkScheduler = .main, searchDebounce: TimeInterval = 0.12) {
        self.config = config
        self.scheduler = scheduler
        self.searchDebounce = searchDebounce
        super.init(frame: .zero)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// Restore remembered filter state (does not notify).
    func restore(filter: WorkFilter, sort: WorkSortKey, collapsedGroups: [String]) {
        self.filter = filter
        self.sort = sort
        self.collapsedGroups = Set(collapsedGroups)
        cancelPendingSearch?()
        cancelPendingSearch = nil
        searchField.stringValue = filter.query
        if let index = config.sortOptions.firstIndex(where: { $0.key == sort }) {
            sortPopup.selectItem(at: index)
        }
        rebuildFilterControls()
    }

    /// Show `snapshot`. `isLoading` shows skeleton rows while there is nothing
    /// yet; `placeholder` is a message over an empty list ("Nothing to do").
    func apply(snapshot: WorkListSnapshot, isLoading: Bool, placeholder: String?) {
        self.snapshot = snapshot
        let newRoots = buildNodes(from: snapshot)
        let layout = Self.layout(of: newRoots)
        if layout == shownLayout {
            // Same rows as drawn: refresh the items behind them (a hidden field may
            // have changed) without touching the outline, its scroll position or selection.
            for (old, new) in zip(flatten(roots), flatten(newRoots)) { old.item = new.item }
        } else {
            let selectedId = selectedItem?.id
            roots = newRoots
            shownLayout = layout
            isApplying = true
            outline.reloadData()
            for node in roots where node.item == nil {
                if let key = node.groupKey, !collapsedGroups.contains(key) { outline.expandItem(node) }
            }
            if let selectedId, let row = row(forItemId: selectedId) {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            isApplying = false
        }

        let isEmpty = snapshot.filteredCount == 0
        skeleton.isHidden = !(isLoading && snapshot.totalCount == 0)
        let message: String? = isEmpty
            ? (snapshot.totalCount > 0 ? "No items match the filter" : placeholder)
            : nil
        placeholderLabel.stringValue = message ?? ""
        placeholderLabel.isHidden = message == nil || !skeleton.isHidden
        rebuildFilterControlsIfNeeded()
    }

    /// Select the row for `itemId` (nil clears). Notifies only when `notify`.
    func select(itemId: String?, notify: Bool = false) {
        isApplying = !notify
        defer { isApplying = false }
        guard let itemId, let row = row(forItemId: itemId) else {
            outline.deselectAll(nil)
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    var selectedItem: WorkItem? {
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return nil }
        return node.item
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    /// The list itself takes the keyboard (arrows, Return).
    func focusList() {
        window?.makeFirstResponder(outline)
    }

    /// Item rows currently in the outline, in display order (collapsed groups hide theirs).
    var visibleRows: [WorkRowContent] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.content }
    }

    var visibleGroupHeaders: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? Node)?.groupTitle }
    }

    // MARK: Build

    private func setUp() {
        translatesAutoresizingMaskIntoConstraints = false

        chipStack.orientation = .horizontal
        chipStack.spacing = 4

        searchField.placeholderString = config.searchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setAccessibilityLabel("Search items")

        sortPopup.removeAllItems()
        for option in config.sortOptions { sortPopup.addItem(withTitle: option.title) }
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)
        sortPopup.isHidden = config.sortOptions.count < 2
        sortPopup.setAccessibilityLabel("Sort order")

        filterBar.orientation = .horizontal
        filterBar.spacing = 6
        filterBar.alignment = .centerY
        filterBar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        filterBar.addArrangedSubview(chipStack)
        for facet in config.menuFacets {
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.setAccessibilityLabel("Filter by \(facet.rawValue)")
            menuButtons[facet] = button
            filterBar.addArrangedSubview(button)
        }
        filterBar.addArrangedSubview(searchField)
        filterBar.addArrangedSubview(sortPopup)
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("work"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 30
        outline.indentationPerLevel = 0
        outline.floatsGroupRows = false
        outline.usesAutomaticRowHeights = false
        outline.allowsMultipleSelection = false
        outline.backgroundColor = Theme.bg
        outline.selectionHighlightStyle = .regular
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.setAccessibilityLabel("Work items")

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.alignment = .center
        placeholderLabel.textColor = Theme.fgMuted
        placeholderLabel.isHidden = true
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false

        skeleton.isHidden = true
        skeleton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(filterBar)
        addSubview(scroll)
        addSubview(skeleton)
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: topAnchor),
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            skeleton.topAnchor.constraint(equalTo: scroll.topAnchor),
            skeleton.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            skeleton.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 16),
        ])
    }

    private func buildNodes(from snapshot: WorkListSnapshot) -> [Node] {
        let today = Calendar.current.startOfDay(for: Date())
        if rowCacheDay != today { rowCache.removeAll(); rowCacheDay = today }
        // Bounded: ids of items that left the list are only dropped here.
        if rowCache.count > 4 * max(snapshot.totalCount, 250) { rowCache.removeAll() }

        func itemNode(_ item: WorkItem) -> Node {
            if let cached = rowCache[item.id], cached.item == item {
                return Node(item: item, content: cached.content)
            }
            let content = config.rowContent(item)
            rowCache[item.id] = (item, content)
            return Node(item: item, content: content)
        }
        // A source that is one flat list has a single group with no key: no header rows.
        if snapshot.groups.count == 1, snapshot.groups[0].key == nil {
            return snapshot.groups[0].items.map(itemNode)
        }
        return snapshot.groups.map { group in
            Node(groupKey: group.key ?? "", title: config.groupTitle(group), children: group.items.map(itemNode))
        }
    }

    private func flatten(_ nodes: [Node]) -> [Node] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    private static func layout(of roots: [Node], depth: Int = 0) -> [LayoutEntry] {
        roots.flatMap { node in
            [LayoutEntry(groupKey: node.groupKey, groupTitle: node.groupTitle, itemId: node.item?.id,
                         content: node.content, depth: depth)]
                + layout(of: node.children, depth: depth + 1)
        }
    }

    private func row(forItemId id: String) -> Int? {
        for row in 0..<outline.numberOfRows {
            if (outline.item(atRow: row) as? Node)?.item?.id == id { return row }
        }
        return nil
    }

    // MARK: Filter bar

    /// Rebuild the chips and menus only when their counts or the selected filter changed.
    private func rebuildFilterControlsIfNeeded() {
        guard currentControlsKey != shownControls else { return }
        rebuildFilterControls()
    }

    private var currentControlsKey: ControlsKey {
        ControlsKey(counts: snapshot?.facetCounts ?? [:], filter: filter)
    }

    private func rebuildFilterControls() {
        filterControlRebuildCount += 1
        let key = currentControlsKey
        shownControls = key
        let counts = key.counts
        // Chips
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let facet = config.chipFacet {
            let selected = Set(values(of: facet, in: filter))
            for (value, count) in (counts[facet] ?? [:]).sorted(by: { $0.key < $1.key }) {
                chipStack.addArrangedSubview(makeChip(value: value, count: count, isOn: selected.contains(value)))
            }
            // A selected value with no items left still needs a chip to turn it off.
            for value in selected where counts[facet]?[value] == nil {
                chipStack.addArrangedSubview(makeChip(value: value, count: 0, isOn: true))
            }
        }
        // Menus
        for (facet, button) in menuButtons {
            let selected = Set(values(of: facet, in: filter))
            button.removeAllItems()
            button.addItem(withTitle: selected.isEmpty ? facet.rawValue.capitalized : "\(facet.rawValue.capitalized) (\(selected.count))")
            for (value, count) in (counts[facet] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let item = NSMenuItem(title: "\(value) (\(count))", action: #selector(menuValueChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = MenuChoice(facet: facet, value: value)
                item.state = selected.contains(value) ? .on : .off
                button.menu?.addItem(item)
            }
        }
    }

    private func makeChip(value: String, count: Int, isOn: Bool) -> NSButton {
        let chip = NSButton(title: "\(value) \(count)", target: self, action: #selector(chipToggled(_:)))
        chip.setButtonType(.pushOnPushOff)
        chip.bezelStyle = .recessed
        chip.state = isOn ? .on : .off
        chip.identifier = NSUserInterfaceItemIdentifier(value)
        chip.setAccessibilityLabel("\(value), \(count) items")
        return chip
    }

    private final class MenuChoice {
        let facet: WorkFacet
        let value: String
        init(facet: WorkFacet, value: String) { self.facet = facet; self.value = value }
    }

    private func values(of facet: WorkFacet, in filter: WorkFilter) -> [String] {
        switch facet {
        case .source:      return filter.sources.map(\.rawValue)
        case .kind:        return filter.kinds
        case .repo:        return filter.repos
        case .project:     return filter.projects
        case .status:      return filter.statuses
        case .environment: return filter.environments
        }
    }

    private func toggle(_ value: String, in facet: WorkFacet) {
        func flip(_ list: inout [String]) {
            if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
        }
        switch facet {
        case .source:
            if let source = WorkSource(rawValue: value) {
                if let i = filter.sources.firstIndex(of: source) { filter.sources.remove(at: i) } else { filter.sources.append(source) }
            }
        case .kind:        flip(&filter.kinds)
        case .repo:        flip(&filter.repos)
        case .project:     flip(&filter.projects)
        case .status:      flip(&filter.statuses)
        case .environment: flip(&filter.environments)
        }
        onFilterChange?(filter, sort)
    }

    @objc private func chipToggled(_ sender: NSButton) {
        guard let facet = config.chipFacet, let value = sender.identifier?.rawValue else { return }
        toggle(value, in: facet)
    }

    @objc private func menuValueChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MenuChoice else { return }
        toggle(choice.value, in: choice.facet)
    }

    /// Each keystroke restarts a short timer; the filter runs once typing pauses.
    @objc private func searchChanged() {
        cancelPendingSearch?()
        cancelPendingSearch = scheduler.schedule(searchDebounce) { [weak self] in
            self?.cancelPendingSearch = nil
            self?.applySearchText()
        }
    }

    private func applySearchText() {
        guard filter.query != searchField.stringValue else { return }
        filter.query = searchField.stringValue
        onFilterChange?(filter, sort)
    }

    @objc private func sortChanged() {
        let index = sortPopup.indexOfSelectedItem
        guard config.sortOptions.indices.contains(index) else { return }
        sort = config.sortOptions[index].key
        onFilterChange?(filter, sort)
    }

    // MARK: Actions

    @objc private func rowDoubleClicked() { openSelected() }

    private func openSelected() {
        if let item = selectedItem { onOpen?(item) }
    }
}

// MARK: - Outline data source / delegate

extension WorkListView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return roots.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.item == nil
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? Node)?.item == nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        (item as? Node)?.item == nil ? 24 : 30
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        if let title = node.groupTitle {
            let id = NSUserInterfaceItemIdentifier("group")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? WorkGroupCellView ?? WorkGroupCellView(identifier: id)
            cell.configure(title: title)
            return cell
        }
        guard let content = node.content else { return nil }
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? WorkRowCellView ?? WorkRowCellView(identifier: id)
        cell.configure(content)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying else { return }
        onSelectionChange?(selectedItem)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        groupToggled(notification, collapsed: true)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        groupToggled(notification, collapsed: false)
    }

    private func groupToggled(_ notification: Notification, collapsed: Bool) {
        guard !isApplying, let node = notification.userInfo?["NSObject"] as? Node, let key = node.groupKey else { return }
        if collapsed { collapsedGroups.insert(key) } else { collapsedGroups.remove(key) }
        onCollapsedGroupsChange?(collapsedGroups.sorted())
    }
}

// MARK: - Outline subclass

/// Adds Return/Enter as "open" to the standard outline-view keyboard handling.
final class WorkOutlineView: NSOutlineView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return, keypad Enter
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Cells

private final class WorkGroupCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.fgMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String) {
        label.stringValue = title
        setAccessibilityLabel(title)
    }
}

private final class WorkRowCellView: NSTableCellView {
    private let priority = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let due = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        priority.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        title.font = NSFont.systemFont(ofSize: 13)
        title.textColor = Theme.fg
        title.lineBreakMode = .byTruncatingTail
        due.font = NSFont.systemFont(ofSize: 11)
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = Theme.fgMuted
        let trailing = NSStackView(views: [due, status])
        trailing.orientation = .horizontal
        trailing.spacing = 8
        for v in [priority, title, trailing] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            priority.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            priority.centerYAnchor.constraint(equalTo: centerYAnchor),
            priority.widthAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: priority.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ content: WorkRowContent) {
        priority.stringValue = content.priorityText ?? ""
        priority.textColor = Self.color(forRank: content.priorityRank)
        title.stringValue = content.title
        due.stringValue = content.dueText ?? ""
        due.textColor = content.dueIsUrgent ? Theme.redSweater : Theme.fgMuted
        status.stringValue = content.statusText ?? ""
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(content.accessibilityLabel)
    }

    private static func color(forRank rank: Int?) -> NSColor {
        switch rank {
        case 1:  return Theme.redSweater
        case 2:  return Theme.amber
        case 3:  return Theme.cornflower
        default: return Theme.fgMuted
        }
    }
}

/// Grey bars standing in for rows while the first data is on its way.
private final class WorkSkeletonView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        Theme.borderInactive.withAlphaComponent(0.6).setFill()
        var y: CGFloat = 12
        var widthFactor: [CGFloat] = [0.7, 0.55, 0.8, 0.45, 0.65, 0.5, 0.75]
        while y < bounds.height - 20, !widthFactor.isEmpty {
            let w = (bounds.width - 32) * widthFactor.removeFirst()
            NSBezierPath(roundedRect: NSRect(x: 16, y: y, width: w, height: 12), xRadius: 4, yRadius: 4).fill()
            y += 30
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}
