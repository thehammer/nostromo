import AppKit
import Combine
import NostromoKit

// The Mother pane's Overview: the author's open PRs, grouped by what each is waiting on.
//
// The daemon computes grouping and order; this view words, collapses and caps them, and holds still the row
// the reader is on. A fixable row has one button (Tell <focus>, Choose focus…, Start a session…) when the
// daemon can hand off; it and Return on the row open a preview, a picker or a sheet, and never send.

// MARK: - Outline

/// The outline, with the keys and clicks the Overview adds: ⌘O, ⌘R, ⌘-click, a context menu and hover.
final class AuthoredPrsOutlineView: NSOutlineView {
    var onOpenOnGitHub: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCommandClick: ((Int) -> Void)?
    var onHover: ((Int?) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    /// Return on the selected row (the keyboard way to the row's button). It never sends anything.
    var onReturn: ((NSEvent) -> Void)?

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    /// Return on a row opens its preview (or picker, or sheet) when it has a button; it never sends anything.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?(event)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only while the list has focus; elsewhere in the window ⌘O and ⌘R mean what they always did.
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "o": onOpenOnGitHub?(); return true
        case "r": onRefresh?(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let row = self.row(at: convert(event.locationInWindow, from: nil))
            if row >= 0 {
                selectRowIndexes([row], byExtendingSelection: false)
                onCommandClick?(row)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        selectRowIndexes([row], byExtendingSelection: false)
        return onContextMenu?(row)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        onHover?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) { onHover?(nil) }
}

// MARK: - Messages and skeleton

/// A centred plain-text message: the empty and not-connected states.
final class AuthoredPrsMessageView: NSView {
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    /// `Show all`, only under a filter that matches nothing.
    let showAllButton = NSButton(title: "Show all", target: nil, action: nil)
    var onShowAll: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        showAllButton.target = self
        showAllButton.action = #selector(showAllPressed)
        showAllButton.isHidden = true
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AuthoredPrsPalette.text
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AuthoredPrsPalette.muted
        let stack = NSStackView(views: [titleLabel, detailLabel, showAllButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [titleLabel, detailLabel] {
            label.alignment = .center
            label.isSelectable = false
            label.allowsEditingTextAttributes = false
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showAllPressed() { onShowAll?() }

    func show(title: String, detail: String?, offersShowAll: Bool = false) {
        showAllButton.isHidden = !offersShowAll
        titleLabel.stringValue = title
        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = detail == nil
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([title, detail].compactMap { $0 }.joined(separator: ". "))
    }
}

/// Grey bars where rows will be, for the first moments after launch or a reconnect.
final class AuthoredPrsSkeletonView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        AuthoredPrsPalette.chipFill.setFill()
        var y: CGFloat = 12
        for _ in 0..<3 {
            for (inset, width, h) in [(CGFloat(16), min(bounds.width * 0.55, 360), CGFloat(10)),
                                      (CGFloat(32), min(bounds.width * 0.4, 260), CGFloat(8)),
                                      (CGFloat(32), min(bounds.width * 0.3, 200), CGFloat(8))] {
                NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: max(0, width), height: h), xRadius: h / 2, yRadius: h / 2).fill()
                y += h + 9
            }
            y += 14
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityLabel("Loading your open PRs")
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Overview

private final class OverviewNode: NSObject {
    enum Kind {
        case group(AuthoredPrsGroupModel)
        case row(AuthoredPrRowModel)
        case more(AuthoredPrGroup, String)
    }
    var kind: Kind
    var children: [OverviewNode] = []
    init(_ kind: Kind) { self.kind = kind }
}

final class AuthoredPrsOverviewView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// How long the skeleton stands in for a list that has not arrived.
    static let skeletonSeconds: TimeInterval = 5

    // MARK: Injected

    var clock: () -> Date
    var timeZone: TimeZone
    /// Opens a validated PR URL. Tests record instead of launching a browser.
    var opener: (URL) -> Void = { ActivationAudit.note("authored-prs:open-on-github"); NSWorkspace.shared.open($0) }
    /// ⟳ and ⌘R.
    var refreshAction: () -> Void = { AppStore.shared.requestAuthoredPrsRefresh() }
    /// A Mother job id was pressed.
    var onOpenJob: (String) -> Void = { id in
        MotherView.requestedJobId = id
        NotificationCenter.default.post(name: MotherView.openJobNotification, object: nil)
    }
    var demand: AuthoredPrsDemandReporter?
    /// The hand-off behind the row buttons; nil leaves the Overview read-only.
    var handoff: AuthoredPrHandoff?
    /// The Merge button's confirmation and the merge itself; nil leaves rows without attempts.
    var merger: AuthoredPrMerger? {
        didSet {
            mergerObservation = merger?.changes.sink { [weak self] in self?.mergerChanged() }
            rebuildRows()
        }
    }

    // MARK: State

    private(set) var snapshot: AuthoredPrsSnapshot?
    private(set) var connection: AuthoredPrsConnection = .connected
    /// The rows on screen: the snapshot, except that a selected or hovered row stays where it is.
    private(set) var displayed: [AuthoredPr] = []
    private(set) var hoveredId: String?
    /// The daemon advertised `authored_prs_notify_v1`: rows get their button and told line.
    private(set) var handoffAvailable = false
    /// The daemon advertised `authored_prs_perri_v1`: rows get Perri's badge.
    private(set) var perriAvailable = false
    /// The daemon advertised `authored_prs_merge_v1`: READY rows get their Merge button (with Perri's verdicts too).
    private(set) var mergeAvailable = false
    /// The Repo and Session pop-ups' selection. It only chooses which rows show: the header total, the pinned
    /// row's pill, the sidebar pills and notifications all read the full snapshot.
    private(set) var filter: AuthoredPrsFilterSelection
    private let filterStore: AuthoredPrsFilterStore
    private var shownFilterResult: AuthoredPrsFilterResult?
    private var showAll: Set<AuthoredPrGroup> = []
    private var collapsed: Set<AuthoredPrGroup> = []
    private var skeletonDeadline: Date
    private var isReloading = false
    private var ticks = 0
    private var timer: Timer?
    private var groupNodes: [AuthoredPrGroup: OverviewNode] = [:]
    private var rowNodes: [String: OverviewNode] = [:]
    private var moreNodes: [AuthoredPrGroup: OverviewNode] = [:]
    private var topNodes: [OverviewNode] = []
    private var cancellables = Set<AnyCancellable>()
    private var mergerObservation: AnyCancellable?
    private var notifyingMerger = false
    /// The attempts the rows on screen were built from.
    private var shownAttempts: [String: AuthoredPrMergeAttempt] = [:]

    // MARK: Views

    let header = AuthoredPrsHeaderView()
    let filterStrip = AuthoredPrsFilterStripView()
    private var stripHeight: NSLayoutConstraint!
    let outline = AuthoredPrsOutlineView()
    private let scroll = NSScrollView()
    private let message = AuthoredPrsMessageView()
    private let skeleton = AuthoredPrsSkeletonView()
    private var headerHeight: NSLayoutConstraint!

    // MARK: Init

    init(frame: NSRect = .zero, clock: @escaping () -> Date = Date.init, timeZone: TimeZone = .current,
         store: AppStore? = AppStore.shared, filterDefaults: UserDefaults = AuthoredPrsFilterStore.defaults) {
        self.clock = clock
        self.timeZone = timeZone
        filterStore = AuthoredPrsFilterStore(defaults: filterDefaults)
        filter = filterStore.load()
        skeletonDeadline = clock().addingTimeInterval(Self.skeletonSeconds)
        super.init(frame: frame)
        build()
        if let store { bind(to: store) }
        refreshChrome()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = AuthoredPrsPalette.background.cgColor
        setAccessibilityElement(false)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pr"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.indentationPerLevel = 0
        outline.intercellSpacing = .zero
        outline.rowSizeStyle = .custom
        outline.style = .plain
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAutomaticRowHeights = false
        outline.dataSource = self
        outline.delegate = self
        outline.focusRingType = .none
        outline.setAccessibilityLabel("My open PRs")
        outline.onOpenOnGitHub = { [weak self] in self?.openSelectedOnGitHub() }
        outline.onRefresh = { [weak self] in self?.refresh() }
        outline.onCommandClick = { [weak self] row in self?.openOnGitHub(row: row) }
        outline.onHover = { [weak self] row in self?.setHovered(rowId: row.flatMap { self?.rowId(atOutlineRow: $0) }) }
        outline.onContextMenu = { [weak self] row in self?.contextMenu(forOutlineRow: row) }
        outline.onReturn = { [weak self] event in self?.activateSelected(event: event) }

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        message.translatesAutoresizingMaskIntoConstraints = false
        skeleton.translatesAutoresizingMaskIntoConstraints = false
        header.onRefresh = { [weak self] in self?.refresh() }
        filterStrip.onChange = { [weak self] selection in self?.setFilter(selection) }
        message.onShowAll = { [weak self] in self?.setFilter(.all) }

        for v in [header, filterStrip, scroll, message, skeleton] as [NSView] { addSubview(v) }
        stripHeight = filterStrip.heightAnchor.constraint(equalToConstant: 0)
        headerHeight = header.heightAnchor.constraint(equalToConstant: AuthoredPrsHeaderView.height(noteCount: 0))
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerHeight,
            filterStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            stripHeight,
        ] + [scroll, message, skeleton].flatMap { body -> [NSLayoutConstraint] in
            [body.topAnchor.constraint(equalTo: filterStrip.bottomAnchor), body.leadingAnchor.constraint(equalTo: leadingAnchor),
             body.trailingAnchor.constraint(equalTo: trailingAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor)]
        })
    }

    private func bind(to store: AppStore) {
        apply(snapshot: store.authoredPrs, connection: store.authoredPrsConnection)
        // Publishers deliver the new value before the property holds it: use what is handed over.
        store.$authoredPrs
            .dropFirst()
            .sink { [weak self] snap in guard let self else { return }; self.apply(snapshot: snap, connection: self.connection) }
            .store(in: &cancellables)
        store.$authoredPrsConnection
            .dropFirst()
            .sink { [weak self] conn in guard let self else { return }; self.apply(snapshot: self.snapshot, connection: conn) }
            .store(in: &cancellables)
        demand = store.authoredPrsDemand
        handoff = store.authoredPrHandoff
        merger = store.authoredPrMerger
        setHandoffAvailable(store.authoredPrsNotifySupported)
        setPerriAvailable(store.authoredPrsPerriSupported)
        setMergeAvailable(store.authoredPrsMergeSupported)
        store.$authoredPrsNotifySupported
            .dropFirst()
            .sink { [weak self] supported in self?.setHandoffAvailable(supported) }
            .store(in: &cancellables)
        store.$authoredPrsPerriSupported
            .dropFirst()
            .sink { [weak self] supported in self?.setPerriAvailable(supported) }
            .store(in: &cancellables)
        store.$authoredPrsMergeSupported
            .dropFirst()
            .sink { [weak self] supported in self?.setMergeAvailable(supported) }
            .store(in: &cancellables)
    }

    /// The daemon can (or can no longer) hand a PR to a focus: rows are rebuilt with or without their button.
    func setHandoffAvailable(_ available: Bool) {
        guard available != handoffAvailable else { return }
        handoffAvailable = available
        rebuildRows()
    }

    /// The daemon sends (or no longer sends) Perri's verdict: rows are rebuilt with or without the badge.
    func setPerriAvailable(_ available: Bool) {
        guard available != perriAvailable else { return }
        perriAvailable = available
        rebuildRows()
    }

    /// The daemon can (or can no longer) merge: rows are rebuilt with or without their Merge button.
    func setMergeAvailable(_ available: Bool) {
        guard available != mergeAvailable else { return }
        mergeAvailable = available
        rebuildRows()
    }

    // MARK: Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            timer = nil
            demand?.overviewRemoved(self)
        } else {
            if timer == nil {
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            demand?.overviewChanged(self)
        }
    }

    override func viewDidHide() { super.viewDidHide(); demand?.overviewChanged(self) }
    override func viewDidUnhide() { super.viewDidUnhide(); demand?.overviewChanged(self) }

    /// Put the keyboard on the list (⌘0): ↑/↓ then move between rows without a mouse.
    func focusList() {
        window?.makeFirstResponder(outline)
    }

    // MARK: Applying data

    /// Show `snapshot` (nil before the first one). A selected or hovered row keeps its place.
    func apply(snapshot new: AuthoredPrsSnapshot?, connection newConnection: AuthoredPrsConnection) {
        if newConnection == .connected, connection == .reconnecting, new == nil {
            skeletonDeadline = clock().addingTimeInterval(Self.skeletonSeconds)
        }
        snapshot = new
        connection = newConnection
        reconcile()
        refreshChrome()
    }

    /// Re-evaluate time: the Merged/Closed linger, freshness words and ages. Called once a second.
    func tick() {
        ticks += 1
        reconcile()
        if ticks % 30 == 0, !displayed.isEmpty { rebuildRows() }
        refreshChrome()
    }

    private func reconcile() {
        guard let snapshot else {
            if !displayed.isEmpty { displayed = []; rebuildRows() }
            return
        }
        let now = clock()
        let incoming = snapshot.prs.filter { !AuthoredPrsPresentation.isExpired($0, now: now) }
        let merged = AuthoredPrsHold.merge(displayed: displayed, incoming: incoming, held: heldIds)
        if merged != displayed {
            displayed = merged
            rebuildRows()
        }
    }

    private var heldIds: Set<String> {
        var ids = Set<String>()
        if let hoveredId { ids.insert(hoveredId) }
        if let selectedRowId { ids.insert(selectedRowId) }
        return ids
    }

    // MARK: Header and states

    private func refreshChrome() {
        let now = clock()
        guard let snapshot else {
            header.apply(model: nil, notes: connection == .reconnecting ? [.init(text: AuthoredPrsPresentation.reconnectingText, isWarning: true)] : [])
            setHeaderNotes(connection == .reconnecting ? 1 : 0)
            if now < skeletonDeadline {
                show(.skeleton)
            } else {
                message.show(title: "Waiting for Nostromo to report your PRs…", detail: nil)
                show(.message)
            }
            applyFilterStrip(filterResult, visible: false)
            scroll.alphaValue = 1
            return
        }
        let result = filterResult
        let showsList = AuthoredPrsPresentation.body(snapshot) == .list && !displayed.isEmpty
        let matchedOpen = filter.isActive && showsList ? result.prs.filter { $0.lifecycle == .open }.count : nil
        let model = AuthoredPrsPresentation.header(snapshot, now: now, timeZone: timeZone, matchedOpen: matchedOpen)
        var notes: [AuthoredPrsHeaderView.Note] = []
        if connection == .reconnecting { notes.append(.init(text: AuthoredPrsPresentation.reconnectingText, isWarning: true)) }
        if let showing = model.showing { notes.append(.init(text: showing)) }
        if let hidden = AuthoredPrsPresentation.hiddenOrgsNote(snapshot) { notes.append(.init(text: hidden, isWarning: true)) }
        if let asOf = model.asOf { notes.append(.init(text: asOf)) }
        header.apply(model: model, notes: notes)
        setHeaderNotes(notes.count)

        switch AuthoredPrsPresentation.body(snapshot) {
        case .notConnected:
            message.show(title: AuthoredPrsPresentation.notConnectedTitle, detail: AuthoredPrsPresentation.notConnectedDetail)
            show(.message)
        case .empty:
            message.show(title: AuthoredPrsPresentation.emptyText, detail: nil)
            show(.message)
        case .list:
            if displayed.isEmpty {
                message.show(title: AuthoredPrsPresentation.emptyText, detail: nil)
                show(.message)
            } else if case .noMatch(let text) = result.emptyState {
                message.show(title: text, detail: nil, offersShowAll: true)
                show(.message)
            } else {
                show(.list)
            }
        }
        applyFilterStrip(result, visible: showsList)
        scroll.alphaValue = (connection == .reconnecting || model.asOf != nil) ? 0.5 : 1
    }

    /// The strip shows with the list, and stays above a `no match` message so the reader can change it.
    private func applyFilterStrip(_ result: AuthoredPrsFilterResult, visible: Bool) {
        filterStrip.isHidden = !visible
        stripHeight.constant = visible ? AuthoredPrsFilterStripView.height : 0
        // Rebuilding the pop-ups every tick would close a menu the reader has open.
        if visible, shownFilterResult.map({ !Self.sameStrip($0, result) }) ?? true { filterStrip.apply(result) }
        shownFilterResult = visible ? result : nil
    }

    private static func sameStrip(_ a: AuthoredPrsFilterResult, _ b: AuthoredPrsFilterResult) -> Bool {
        a.selection == b.selection && a.repoEntries == b.repoEntries && a.sessionEntries == b.sessionEntries
    }

    private var filterResult: AuthoredPrsFilterResult { AuthoredPrsFilter.apply(displayed, selection: filter) }

    /// The reader picked a repo or a session (or Clear, or Show all). Remembered across launches. The scroll
    /// goes back to the top: the rows under the old position are not the rows under the new one.
    func setFilter(_ selection: AuthoredPrsFilterSelection) {
        guard selection != filter else { return }
        filter = selection
        filterStore.save(selection)
        rebuildRows()
        refreshChrome()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private enum Body { case skeleton, message, list }

    private func show(_ body: Body) {
        skeleton.isHidden = body != .skeleton
        message.isHidden = body != .message
        scroll.isHidden = body != .list
    }

    private func setHeaderNotes(_ count: Int) {
        headerHeight.constant = AuthoredPrsHeaderView.height(noteCount: count)
    }

    // MARK: Outline contents

    private var groupModels: [AuthoredPrsGroupModel] {
        AuthoredPrsPresentation.groups(filterResult.prs, unfiltered: filter.isActive ? displayed : nil,
                                       showAll: showAll, now: clock(), timeZone: timeZone,
                                       handoff: handoffAvailable,
                                       tellable: handoff.map { Set($0.openFocuses().map(\.tag)) },
                                       perri: perriAvailable, merge: mergeAvailable && merger != nil,
                                       mergeAttempts: merger?.attempts ?? [:])
    }

    private func rebuildRows() {
        shownAttempts = merger?.attempts ?? [:]
        let selected = selectedRowId
        var newRowNodes: [String: OverviewNode] = [:]
        var tops: [OverviewNode] = []
        for group in groupModels {
            let node = groupNodes[group.group] ?? OverviewNode(.group(group))
            node.kind = .group(group)
            groupNodes[group.group] = node
            var children: [OverviewNode] = group.rows.map { row in
                let child = rowNodes[row.id] ?? OverviewNode(.row(row))
                child.kind = .row(row)
                newRowNodes[row.id] = child
                return child
            }
            if let more = group.showMoreTitle {
                let m = moreNodes[group.group] ?? OverviewNode(.more(group.group, more))
                m.kind = .more(group.group, more)
                moreNodes[group.group] = m
                children.append(m)
            }
            node.children = children
            tops.append(node)
        }
        rowNodes = newRowNodes
        topNodes = tops

        isReloading = true
        outline.reloadData()
        for node in tops {
            if case .group(let g) = node.kind, !collapsed.contains(g.group) { outline.expandItem(node) }
        }
        if let selected, let node = rowNodes[selected] {
            let index = outline.row(forItem: node)
            if index >= 0 { outline.selectRowIndexes([index], byExtendingSelection: false) }
        }
        isReloading = false
        // A confirmation about a row that is no longer what the person read is cancelled. That is the merger
        // saying it changed: the rows it would be told to rebuild are the ones just built.
        notifyingMerger = true
        merger?.rowsDidChange(rowNodes.values.compactMap { node in
            if case .row(let model) = node.kind { return model }
            return nil
        }, from: self)
        notifyingMerger = false
    }

    /// An attempt moved on, or a confirmation opened or closed: the rows say so.
    private func mergerChanged() {
        guard !notifyingMerger, let merger else { return }
        // Opening or closing a confirmation changes nothing a row shows: rebuilding then would replace the row
        // view the popover is pointing at.
        guard merger.attempts != shownAttempts else { return }
        rebuildRows()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? OverviewNode else { return topNodes.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? OverviewNode else { return topNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? OverviewNode, case .group = node.kind else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? OverviewNode else { return AuthoredPrRowView.rowHeight }
        switch node.kind {
        case .group: return AuthoredPrsGroupHeaderView.height
        case .row: return AuthoredPrRowView.rowHeight
        case .more: return AuthoredPrsShowMoreView.height
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("prRowBackground")
        let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? AuthoredPrsRowBackground) ?? {
            let v = AuthoredPrsRowBackground()
            v.identifier = id
            return v
        }()
        if let node = item as? OverviewNode, case .row(let model) = node.kind { view.isHovered = model.id == hoveredId } else { view.isHovered = false }
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? OverviewNode else { return nil }
        switch node.kind {
        case .group(let group):
            let id = NSUserInterfaceItemIdentifier("prGroup")
            let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? AuthoredPrsGroupHeaderView) ?? {
                let v = AuthoredPrsGroupHeaderView(); v.identifier = id; return v
            }()
            view.configure(group)
            return view
        case .row(let model):
            let id = NSUserInterfaceItemIdentifier("prRow")
            let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? AuthoredPrRowView) ?? {
                let v = AuthoredPrRowView(); v.identifier = id; return v
            }()
            view.onOpenJob = { [weak self] in self?.onOpenJob($0) }
            view.onTell = { [weak self] model in self?.tell(model) }
            view.onMerge = { [weak self] model in self?.merge(model) }
            view.onDismissMergeNotice = { [weak self] model in self?.merger?.dismissNotice(rowId: model.id) }
            view.configure(model)
            return view
        case .more(let group, let title):
            let id = NSUserInterfaceItemIdentifier("prMore")
            let view = (outlineView.makeView(withIdentifier: id, owner: nil) as? AuthoredPrsShowMoreView) ?? {
                let v = AuthoredPrsShowMoreView(); v.identifier = id; return v
            }()
            view.configure(title: title)
            view.onPress = { [weak self] in self?.showMore(group) }
            return view
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        // The selection moved: whatever the old one was holding back now applies.
        reconcile()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? OverviewNode, case .group(let g) = node.kind else { return }
        collapsed.remove(g.group)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? OverviewNode, case .group(let g) = node.kind else { return }
        collapsed.insert(g.group)
    }

    // MARK: Selection, hover, collapse

    private func node(atOutlineRow row: Int) -> OverviewNode? { outline.item(atRow: row) as? OverviewNode }

    private func rowId(atOutlineRow row: Int) -> String? {
        guard let node = node(atOutlineRow: row), case .row(let model) = node.kind else { return nil }
        return model.id
    }

    /// The id of the selected PR row; nil when nothing, or a group header, is selected.
    var selectedRowId: String? { rowId(atOutlineRow: outline.selectedRow) }

    /// The pointer is over `rowId`'s row, or off every row (nil). A row under the pointer holds its place.
    func setHovered(rowId: String?) {
        guard rowId != hoveredId else { return }
        let old = hoveredId
        hoveredId = rowId
        for id in [old, rowId].compactMap({ $0 }) {
            if let node = rowNodes[id] {
                let index = outline.row(forItem: node)
                if index >= 0, let bg = outline.rowView(atRow: index, makeIfNecessary: false) as? AuthoredPrsRowBackground {
                    bg.isHovered = id == rowId
                }
            }
        }
        reconcile()
    }

    /// Select a PR row by id (a seam for tests and for jumping to a row).
    func selectRow(id: String) {
        guard let node = rowNodes[id] else { return }
        let index = outline.row(forItem: node)
        guard index >= 0 else { return }
        outline.selectRowIndexes([index], byExtendingSelection: false)
        outline.scrollRowToVisible(index)
    }

    func clearSelection() { outline.deselectAll(nil) }

    func collapse(_ group: AuthoredPrGroup) {
        if let node = groupNodes[group] { outline.collapseItem(node) }
    }

    func expand(_ group: AuthoredPrGroup) {
        if let node = groupNodes[group] { outline.expandItem(node) }
    }

    func isCollapsed(_ group: AuthoredPrGroup) -> Bool { collapsed.contains(group) }

    private func showMore(_ group: AuthoredPrGroup) {
        showAll.insert(group)
        rebuildRows()
    }

    // MARK: Observable shape (tests and accessibility checks)

    /// The PR row ids on screen, in order.
    var displayedRowIds: [String] {
        topNodes.flatMap { node in node.children.compactMap { child -> String? in
            if case .row(let m) = child.kind { return m.id }
            return nil
        } }
    }

    /// Group titles on screen, in order.
    var groupTitles: [String] {
        topNodes.compactMap { if case .group(let g) = $0.kind { return g.title }; return nil }
    }

    /// The outline row index of a PR row, if it is on screen.
    func outlineRow(forRowId id: String) -> Int? {
        guard let node = rowNodes[id] else { return nil }
        let index = outline.row(forItem: node)
        return index >= 0 ? index : nil
    }

    /// The laid-out view of a PR row, made if needed.
    func rowView(forRowId id: String) -> AuthoredPrRowView? {
        guard let index = outlineRow(forRowId: id) else { return nil }
        return outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? AuthoredPrRowView
    }

    func groupHeaderView(for group: AuthoredPrGroup) -> AuthoredPrsGroupHeaderView? {
        guard let node = groupNodes[group] else { return nil }
        let index = outline.row(forItem: node)
        return index >= 0 ? outline.view(atColumn: 0, row: index, makeIfNecessary: true) as? AuthoredPrsGroupHeaderView : nil
    }

    var isShowingSkeleton: Bool { !skeleton.isHidden }
    var isShowingList: Bool { !scroll.isHidden }
    /// The message on screen (title and detail), nil while the list or skeleton is.
    var shownMessage: (title: String, detail: String?)? {
        guard !message.isHidden else { return nil }
        return (message.titleLabel.stringValue, message.detailLabel.isHidden ? nil : message.detailLabel.stringValue)
    }
    var isDimmed: Bool { scroll.alphaValue < 1 }

    // MARK: Actions

    /// ⟳ and ⌘R. Does nothing while the daemon says a refresh is blocked.
    func refresh() {
        guard let snapshot, snapshot.refreshBlocked == nil else { return }
        refreshAction()
    }

    private func openSelectedOnGitHub() {
        guard let id = selectedRowId, let model = model(forRowId: id) else { return }
        openOnGitHub(model)
    }

    private func openOnGitHub(row: Int) {
        guard let node = node(atOutlineRow: row), case .row(let model) = node.kind else { return }
        openOnGitHub(model)
    }

    /// Open the PR on GitHub, but only a URL that is exactly `https://github.com/<owner>/<repo>/pull/<n>`.
    func openOnGitHub(_ model: AuthoredPrRowModel) {
        guard let url = AuthoredPrsLinks.pullRequestURL(model.url, repo: model.repo, number: model.number) else { return }
        opener(url)
    }

    /// The row's button was pressed: open its preview, picker or sheet (after the human-gesture check).
    private func tell(_ model: AuthoredPrRowModel) {
        guard let handoff, let rowView = rowView(forRowId: model.id) else { return }
        handoff.activate(model, anchor: rowView, event: NSApp.currentEvent, control: rowView.tellButton)
    }

    /// Merge was pressed (or VoiceOver's Merge action ran): open the confirmation, after the human-gesture check.
    /// It never sends: only the confirmation's Merge does.
    private func merge(_ model: AuthoredPrRowModel) {
        guard let merger, let rowView = rowView(forRowId: model.id) else { return }
        merger.activate(model, anchor: rowView, event: NSApp.currentEvent, control: rowView.mergeButton, owner: self)
    }

    /// Return on the selected row: the same as its button, when it has one.
    func activateSelected(event: NSEvent?) {
        guard let handoff, let id = selectedRowId, let model = model(forRowId: id), model.tellButton != nil,
              let rowView = rowView(forRowId: id) else { return }
        handoff.activate(model, anchor: rowView, event: event, control: outline)
    }

    private func model(forRowId id: String) -> AuthoredPrRowModel? {
        guard let node = rowNodes[id], case .row(let model) = node.kind else { return nil }
        return model
    }

    private func contextMenu(forOutlineRow row: Int) -> NSMenu? {
        guard let node = node(atOutlineRow: row), case .row(let model) = node.kind else { return nil }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open on GitHub", action: #selector(openFromMenu(_:)), keyEquivalent: "o")
        open.keyEquivalentModifierMask = .command
        open.representedObject = model.id
        open.target = self
        menu.addItem(open)
        if let job = model.ownerJobId {
            let item = NSMenuItem(title: "Show Mother Job \(job)", action: #selector(showJobFromMenu(_:)), keyEquivalent: "")
            item.representedObject = job
            item.target = self
            menu.addItem(item)
        }
        if handoffAvailable, model.ownerKind == .linked {
            let item = NSMenuItem(title: "Unlink", action: #selector(unlinkFromMenu(_:)), keyEquivalent: "")
            item.representedObject = model.id
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func unlinkFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let model = model(forRowId: id), let handoff else { return }
        handoff.unlink(model, event: NSApp.currentEvent, control: outline)
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let model = model(forRowId: id) { openOnGitHub(model) }
    }

    @objc private func showJobFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onOpenJob(id) }
    }

    /// The context menu a row offers, for tests.
    func contextMenu(forRowId id: String) -> NSMenu? {
        outlineRow(forRowId: id).flatMap { contextMenu(forOutlineRow: $0) }
    }
}
