import AppKit
import QuartzCore

/// The staging drawer at the bottom of a terminal pane (SwiftTerm-free, manual layout; the host gives it
/// the pane's width and the height `preferredHeight(forBodyHeight:width:)` says).
///
/// It exists only while the store has a list for the terminal (`state` active or frozen): otherwise it is
/// hidden, zero high and runs no timer. A header says who staged what and how many; the rows (at most 5
/// before it scrolls, never more than 45% of the pane body) are `StagingRowView`s reused by entry id. A
/// 4 pt divider at the top drags the height (between the one-line strip and 60% of the body; remembered
/// per pane in memory) and the chevron collapses it to a one-line strip. It grows as entries arrive but
/// does not shrink while entries remain unless the user collapses or drags it, so a shell is not resized
/// for every change.
///
/// A frame arriving never takes the keyboard for the drawer and never scrolls the terminal (when the list
/// goes away, a drawer that held the keyboard hands it back to the terminal). Nothing a row shows changes
/// height across the 1.5 s reading delay, and the room for the one-or-two-line reason is always reserved
/// while there are rows, so no row moves at the moment it becomes clickable. Everything the
/// agent wrote appears only inside a row's command and note slots. In the real app app-control sees none
/// of it (`AppControlAX`, `ScreenshotRedaction`).
///
/// Keyboard (once ⇧⌘J or a click has given it the keyboard): Up/Down and Tab/Shift-Tab move the
/// selection, Space inserts the selected row through the same controller a click uses, Return and
/// Enter do nothing and are never forwarded, Escape gives the keyboard back to the terminal. Nothing in
/// the drawer has a key equivalent and there is no default button.
///
/// In a production-treated pane (not known to be local, or a local shell running another program) the header
/// starts with a fixed, non-truncating token (`PRODUCTION`, `REMOTE`, `RUNNING`) in the pane's hazard colour, and
/// every row shows its whole command. A `×` (and the menu's Hide Staged Commands) closes the drawer for the
/// pane (memory only); the daemon's list is untouched and the pane header shows a `3 staged` chip that reopens it.
final class StagingDrawerView: NSView, TerminalPixelSource {

    static let dividerHeight: CGFloat = 4
    static let stripHeight: CGFloat = 24
    static let maxVisibleRows = 5
    static let maxBodyFraction: CGFloat = 0.45
    static let maxDragFraction: CGFloat = 0.6
    /// A reason ("Click the terminal to drive it from this window") wraps to this many lines at narrow widths.
    static let reasonLines = 2
    /// A pane body shorter than this shows only the strip.
    static let minBodyForRows: CGFloat = 120

    /// Dragged heights, per pane, for the life of the app.
    private static var rememberedHeights: [String: CGFloat] = [:]
    /// Panes whose drawer the user closed, for the life of the app.
    private static var hiddenPanes: Set<String> = []
    static let archivedToggleHeight: CGFloat = 22

    var terminalPixelArea: NSView { self }

    /// The host re-lays out when the height this drawer wants changed.
    var onLayoutChange: (() -> Void)?
    /// Escape.
    var onReturnToTerminal: (() -> Void)?
    /// The pane header's `3 staged` chip: the count while the user has closed the drawer and a list exists
    /// (nil otherwise); `pulse` when an entry just arrived.
    var onChipChange: ((_ count: Int?, _ pulse: Bool) -> Void)?
    private var lastChip: Int?

    // Observable by tests.
    private(set) var tickTimer: Timer?
    private(set) var rowUpdateCount = 0
    private(set) var pulseCount = 0
    private(set) var hasList = false
    private(set) var isCollapsed = false
    private(set) var selectedEntryId: String?
    private(set) var rowViews: [String: StagingRowView] = [:]
    var orderedRows: [StagingRowView] { order.compactMap { rowViews[$0] } }
    private(set) var notice: String?
    private(set) var isArchivedExpanded = false
    /// The user closed this pane's drawer (× or the menu); a list may exist behind it.
    var isUserHidden: Bool { Self.hiddenPanes.contains(paneKey) }

    private let controller: StagingInsertController
    private let staging: TerminalStagingStore
    private let date: () -> Date
    private let reduceMotion: () -> Bool
    private let paneKey: String
    private var observation: TerminalStagingStore.Observation?
    private var userHeight: CGFloat?
    private var grownHeight: CGFloat = 0
    private var list: TerminalStagingList?
    private var env: StagingEnvironment?
    private var order: [String] = []
    private var lastModels: [StagingRowModel] = []
    private var lastRevision: Int?
    private var lastCount: Int?
    /// The pane body is too short for rows: only the strip shows.
    private var stripOnly = false
    private var reasonSlot: (width: CGFloat, height: CGFloat)?
    private var lastOwner: String?
    private var lastWindowRect: NSRect?
    private var archivedSnapshot: [ArchivedStagedEntry] = []
    private var archivedRows: [StagingArchivedRowView] = []

    private let divider = StagingDividerView()
    private let chevron = StagingClickableLabel()
    private let leadLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = StagingClickableLabel()
    private let stripButton = StagingClickableLabel()
    private let reasonLabel = NSTextField(labelWithString: "")
    /// `PRODUCTION`, `REMOTE` or `RUNNING`: separate from the text, fixed, never truncated.
    let tokenLabel = NSTextField(labelWithString: "")
    private let closeLabel = StagingClickableLabel()
    private let archivedToggle = StagingClickableLabel()
    private let scroll = NSScrollView()
    private let documentView = StagingFlippedView()

    init(controller: StagingInsertController, staging: TerminalStagingStore = .shared, paneKey: String,
         date: @escaping () -> Date = Date.init,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.controller = controller
        self.staging = staging
        self.paneKey = paneKey
        self.date = date
        self.reduceMotion = reduceMotion
        self.userHeight = Self.rememberedHeights[paneKey]
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor
        layer?.masksToBounds = true
        isHidden = true
        setAccessibilityIdentifier("staging-drawer")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Staged commands")
        leadLabel.font = Theme.statusFont
        leadLabel.textColor = Theme.fg
        leadLabel.lineBreakMode = .byTruncatingTail
        leadLabel.isSelectable = false
        countLabel.font = Theme.statusFont
        countLabel.textColor = Theme.fg
        countLabel.isSelectable = false
        reasonLabel.font = Theme.statusFont
        reasonLabel.textColor = Theme.amber
        // Word wrapping, at most two lines, the last one cut with an ellipsis. (`.byTruncatingTail` would
        // switch the cell's wrapping off: one truncated line in a two-line frame.)
        reasonLabel.lineBreakMode = .byWordWrapping
        reasonLabel.maximumNumberOfLines = Self.reasonLines
        reasonLabel.cell?.truncatesLastVisibleLine = true
        reasonLabel.isSelectable = false
        chevron.title = "\u{25BE}"
        chevron.setAccessibilityLabel("Collapse staged commands")
        chevron.onClick = { [weak self] in self?.setCollapsed(true) }
        stripButton.onClick = { [weak self] in self?.setCollapsed(false) }
        stripButton.wantsLayer = true
        stripButton.label.font = Theme.statusFont
        stripButton.label.textColor = Theme.fg
        menuButton.title = "\u{25BE}"
        menuButton.setAccessibilityLabel("Staged commands menu")
        menuButton.onClick = { [weak self] in self?.showHeaderMenu() }
        tokenLabel.isSelectable = false
        tokenLabel.isHidden = true
        tokenLabel.lineBreakMode = .byClipping
        tokenLabel.alignment = .center
        tokenLabel.wantsLayer = true
        tokenLabel.layer?.backgroundColor = Theme.hazardRed.cgColor
        tokenLabel.layer?.cornerRadius = 3
        tokenLabel.textColor = Theme.hazardText
        tokenLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tokenLabel.setAccessibilityIdentifier("staging-drawer-environment")
        closeLabel.title = "\u{00D7}"
        closeLabel.setAccessibilityLabel("Hide staged commands")
        closeLabel.onClick = { [weak self] in
            guard let self else { return }
            self.setUserHidden(true, event: NSApp.currentEvent, control: self.closeLabel, fromMenu: false)
        }
        archivedToggle.onClick = { [weak self] in self?.toggleArchived() }
        controller.onConfirmedResult = { [weak self] result in self?.rowResult(result) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        scroll.borderType = .noBorder
        divider.onDrag = { [weak self] height in self?.dragged(to: height) }
        divider.currentHeight = { [weak self] in self?.frame.height ?? 0 }
        for view in [divider, scroll, reasonLabel, leadLabel, countLabel, chevron, menuButton, closeLabel, tokenLabel, stripButton] as [NSView] {
            addSubview(view)
        }
        bind()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("StagingDrawerView is created in code") }

    deinit {
        tickTimer?.invalidate()
    }

    // MARK: - Store

    /// Observes the store for the terminal the controller names now; call again when the pane's terminal changes.
    func bind() {
        observation = nil
        guard let id = controller.terminalId else { return }
        // Weak: the store holds the handler, the drawer holds the token.
        observation = staging.observe(terminalId: id) { [weak self] in self?.refresh() }
    }

    /// Re-reads the list and the terminal's state. Cheap when nothing changed: the timer, the host's
    /// alternate-screen check and every store frame all come here.
    func refresh() {
        guard let id = controller.terminalId, let list = staging.list(for: id), list.state != .none,
              let env = controller.environment() else {
            if hasList { clearList() }
            return
        }
        let wasEmpty = !hasList
        let now = staging.now
        let models = StagingDrawerModel.rows(for: list, env: env, shownSince: { staging.shownSince(terminalId: id, entryId: $0) },
                                             now: now, date: date())
        // A new owner (another agent followed the terminal) opens a closed drawer again.
        if let lastOwner, lastOwner != list.ownerTag { Self.hiddenPanes.remove(paneKey) }
        lastOwner = list.ownerTag
        let archivedNow = staging.archivedEntries(for: id)
        let structural = wasEmpty || list.revision != lastRevision || env != self.env || !sameRows(models, lastModels)
            || archivedNow != archivedSnapshot
        if let previous = lastCount, list.entries.count > previous {
            if isCollapsed { pulse() }
            if isUserHidden { onChipChange?(list.entries.count, true) }
        }
        lastCount = list.entries.count
        updateChip(count: list.entries.count)
        guard structural else {
            // Only the clock moved (an age, `inserted 2m ago`): update those texts in place. The rows are
            // not laid out again, and a refusal's reason stays.
            if models != lastModels {
                for model in models { rowViews[model.entryId]?.updateAges(model) }
                lastModels = models
            }
            for row in archivedRows { row.update(now: date()) }
            updateTimer()
            return
        }
        // A refusal's reason stays only until what it was about changes (a revision, a row's state).
        if list.revision != lastRevision || !sameRows(models, lastModels) { notice = nil }
        self.list = list
        self.env = env
        lastRevision = list.revision
        lastModels = models
        hasList = true
        isHidden = isUserHidden
        apply(list: list, env: env, models: models, archived: archivedNow)
        updateTimer()
        askForLayoutIfNeeded()
    }

    /// The same rows, in the same order, apart from what the clock moves.
    private func sameRows(_ a: [StagingRowModel], _ b: [StagingRowModel]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.matchesApartFromAges($1) }
    }

    private func clearList() {
        // The drawer is about to hide: if it holds the keyboard, give it back to the terminal.
        if window?.firstResponder === self { onReturnToTerminal?() }
        hasList = false
        Self.hiddenPanes.remove(paneKey)
        lastOwner = nil
        archivedSnapshot = []
        for row in archivedRows { row.removeFromSuperview() }
        archivedRows = []
        updateChip(count: nil)
        list = nil
        env = nil
        lastModels = []
        lastRevision = nil
        lastCount = nil
        grownHeight = 0
        notice = nil
        selectedEntryId = nil
        for row in rowViews.values { row.removeFromSuperview() }
        rowViews.removeAll()
        order = []
        isHidden = true
        updateTimer()
        askForLayoutIfNeeded()
    }

    private func apply(list: TerminalStagingList, env: StagingEnvironment, models: [StagingRowModel],
                       archived: [ArchivedStagedEntry]) {
        let shared = StagingDrawerModel.sharedReason(env)
        let safety = env.safety
        let parts = StagingDrawerModel.headerParts(list)
        if safety.isProduction {
            leadLabel.stringValue = StagingDrawerModel.productionHeaderText(list, safety: safety)
            countLabel.stringValue = ""
            countLabel.isHidden = true
        } else {
            leadLabel.stringValue = parts.lead
            countLabel.stringValue = parts.count ?? ""
            countLabel.isHidden = parts.count == nil
        }
        leadLabel.lineBreakMode = list.entries.isEmpty ? .byWordWrapping : .byTruncatingTail
        leadLabel.maximumNumberOfLines = list.entries.isEmpty ? 0 : 1
        tokenLabel.stringValue = safety.token ?? ""
        tokenLabel.isHidden = safety.token == nil
        setAccessibilityLabel(StagingDrawerModel.accessibilityText(list, safety: safety))
        stripButton.title = StagingDrawerModel.stripText(list)
        menuButton.isHidden = false
        syncArchived(archived)
        reasonLabel.stringValue = shared?.text ?? notice ?? ""
        reasonLabel.isHidden = reasonLabel.stringValue.isEmpty
        let present = Set(models.map(\.entryId))
        for (id, row) in rowViews where !present.contains(id) {
            row.removeFromSuperview()
            rowViews[id] = nil
        }
        if let selected = selectedEntryId, !present.contains(selected) { selectedEntryId = nil }
        for model in models {
            let row = rowViews[model.entryId] ?? makeRow(model)
            if row.apply(model, showsReason: shared == nil, canModify: !env.isMirror) { rowUpdateCount += 1 }
        }
        order = models.map(\.entryId)
        for (id, row) in rowViews { row.isSelected = id == selectedEntryId }
        needsLayout = true
    }

    /// The footer's read-only rows follow the store's archived entries (memory only).
    private func syncArchived(_ entries: [ArchivedStagedEntry]) {
        guard entries != archivedSnapshot else { return }
        archivedSnapshot = entries
        for row in archivedRows { row.removeFromSuperview() }
        archivedRows = entries.reversed().map { StagingArchivedRowView(entry: $0, now: date()) }
        for row in archivedRows { documentView.addSubview(row) }
        archivedToggle.removeFromSuperview()
        if !entries.isEmpty { documentView.addSubview(archivedToggle) }
        for row in archivedRows { row.isHidden = !isArchivedExpanded }
        archivedToggle.title = archivedToggleTitle
    }

    private var archivedToggleTitle: String {
        "Archived (\(archivedSnapshot.count)) " + (isArchivedExpanded ? "\u{25BE}" : "\u{25B8}")
    }

    private func toggleArchived() {
        isArchivedExpanded.toggle()
        archivedToggle.title = archivedToggleTitle
        for row in archivedRows { row.isHidden = !isArchivedExpanded }
        needsLayout = true
        onLayoutChange?()
    }

    private func updateChip(count: Int?) {
        let chip = isUserHidden ? count : nil
        guard chip != lastChip else { return }
        lastChip = chip
        onChipChange?(chip, false)
    }

    private func makeRow(_ model: StagingRowModel) -> StagingRowView {
        let row = StagingRowView(model: model)
        row.controller = controller
        row.onResult = { [weak self] result in self?.rowResult(result) }
        row.onNeedsLayout = { [weak self] in
            self?.needsLayout = true
            self?.onLayoutChange?()
        }
        rowViews[model.entryId] = row
        documentView.addSubview(row)
        return row
    }

    private func rowResult(_ result: StagingInsertResult) {
        switch result {
        case .refused(let reason):
            notice = reason.text
            if let shared = env.flatMap(StagingDrawerModel.sharedReason) { notice = shared.text }
            reasonLabel.stringValue = notice ?? ""
            reasonLabel.isHidden = reasonLabel.stringValue.isEmpty
            needsLayout = true
            onLayoutChange?()
        case .inserted:
            notice = nil
        default:
            break
        }
        // The state changed under the click (an insert, a refusal): show it now.
        refresh()
    }

    // MARK: - Collapse, drag, menu

    func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        isCollapsed = collapsed
        if collapsed { selectedEntryId = nil }
        lastModels = []     // lay out again
        refresh()
        needsLayout = true
        onLayoutChange?()
    }

    private func dragged(to height: CGFloat) {
        guard !isCollapsed else { return }
        userHeight = height
        Self.rememberedHeights[paneKey] = height
        needsLayout = true
        onLayoutChange?()
    }

    /// The `▾` menu (also built by tests). Every action is gated inside the controller.
    func makeHeaderMenu() -> NSMenu {
        let menu = NSMenu(title: "Staged commands")
        menu.autoenablesItems = false
        let canModify = !(env?.isMirror ?? true)
        func item(_ title: String, _ action: Selector, enabled: Bool = true, on: Bool = false) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            entry.state = on ? .on : .off
            return entry
        }
        menu.addItem(item("Archive Placed Commands", #selector(archivePlacedStaged(_:)),
                          enabled: canModify && lastModels.contains { $0.placed }))
        menu.addItem(item("Archive Commands After I Run Them", #selector(toggleAutoArchive(_:)),
                          on: TerminalStagingStore.autoArchiveEnabled))
        menu.addItem(item("Let Agents Stage Commands Here", #selector(toggleStagingHere(_:)),
                          on: controller.terminalId.map { staging.isEnabled(terminalId: $0) } ?? true))
        menu.addItem(.separator())
        menu.addItem(item("Hide Staged Commands", #selector(hideStaged(_:))))
        menu.addItem(item("Clear all", #selector(clearAllStaged(_:)), enabled: canModify && list?.entries.isEmpty == false))
        return menu
    }

    private func showHeaderMenu() {
        makeHeaderMenu().popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY), in: self)
    }

    @objc private func clearAllStaged(_ sender: NSMenuItem) {
        controller.clearAll(event: NSApp.currentEvent, control: self)
    }

    @objc private func archivePlacedStaged(_ sender: NSMenuItem) {
        rowResult(controller.archivePlaced(event: NSApp.currentEvent, control: self, fromMenu: true))
    }

    @objc private func toggleAutoArchive(_ sender: NSMenuItem) {
        controller.setAutoArchive(!TerminalStagingStore.autoArchiveEnabled, event: NSApp.currentEvent, control: self)
    }

    @objc private func toggleStagingHere(_ sender: NSMenuItem) {
        guard let id = controller.terminalId else { return }
        controller.setStagingEnabledHere(!staging.isEnabled(terminalId: id), event: NSApp.currentEvent, control: self, fromMenu: true)
    }

    @objc private func hideStaged(_ sender: NSMenuItem) {
        setUserHidden(true, event: NSApp.currentEvent, control: self, fromMenu: true)
    }

    /// Closes (or reopens) the drawer for this pane: memory only; the daemon's list is untouched and the agent
    /// keeps staging. A person's act only (`TerminalInputGuard`, through the controller).
    @discardableResult
    func setUserHidden(_ hidden: Bool, event: NSEvent?, control: NSView, fromMenu: Bool) -> Bool {
        guard hasList, controller.allowsHideControl(event: event, control: control, fromMenu: fromMenu) else { return false }
        guard hidden != isUserHidden else { return true }
        if hidden {
            Self.hiddenPanes.insert(paneKey)
            if window?.firstResponder === self { onReturnToTerminal?() }
        } else {
            Self.hiddenPanes.remove(paneKey)
        }
        lastModels = []
        refresh()
        needsLayout = true
        onLayoutChange?()
        return true
    }

    private func pulse() {
        pulseCount += 1
        guard !reduceMotion(), let layer = stripButton.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.3
        animation.duration = 0.35
        animation.autoreverses = true
        layer.add(animation, forKey: "staging-pulse")
    }

    // MARK: - Height

    /// The height this drawer wants in a pane whose body is `bodyHeight` high and `width` wide; 0 when
    /// there is no list. Grows with the entries but does not shrink while any remain (unless collapsed
    /// or dragged), so the shell is not resized for every change.
    func preferredHeight(forBodyHeight bodyHeight: CGFloat, width: CGFloat) -> CGFloat {
        guard hasList, let list, !isUserHidden else { return 0 }
        let strip = Self.dividerHeight + Self.stripHeight
        stripOnly = bodyHeight < Self.minBodyForRows
        if isCollapsed || stripOnly { return min(strip, bodyHeight) }
        let header = Self.dividerHeight + headerHeight(width: width)
        guard !list.entries.isEmpty else {
            grownHeight = 0
            return min(header, bodyHeight)
        }
        let cap = bodyHeight * Self.maxBodyFraction
        let natural = header + reasonHeight(width: width) + visibleRowsHeight(width: width)
        var height = min(natural, cap)
        if let userHeight {
            height = min(max(userHeight, strip), bodyHeight * Self.maxDragFraction)
        } else {
            height = min(max(height, grownHeight), cap)
            grownHeight = height
        }
        return min(max(height, strip), bodyHeight)
    }

    private func headerHeight(width: CGFloat) -> CGFloat {
        guard let list, list.entries.isEmpty else { return Self.stripHeight }
        let text = leadLabel.attributedStringValue
        let available = max(40, width - 30)
        let h = ceil(text.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height)
        return max(Self.stripHeight, h + 8)
    }

    /// `text`'s label height at `width`: one or two lines, as the label's own cell draws them (its
    /// internal padding included).
    private func reasonLabelHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let available = max(20, width - 16)
        let full = StagingRowView.cellHeight(of: text, font: Theme.statusFont, width: available)
        let capped = StagingRowView.cellHeight(of: StagingRowView.lines(Self.reasonLines), font: Theme.statusFont, width: available)
        return min(full, capped)
    }

    private func reasonLabelHeight(width: CGFloat) -> CGFloat {
        reasonLabelHeight(of: reasonLabel.stringValue, width: width)
    }

    /// The room above the rows for the reason: the most any reason needs at `width`, whether one is showing
    /// or not, so a reason appearing (a refusal) or clearing (a change, the delay ending, this window
    /// becoming the driver) never moves a row or resizes the drawer. None while there are no rows.
    private func reasonHeight(width: CGFloat) -> CGFloat {
        guard list?.entries.isEmpty == false else { return 0 }
        if let cached = reasonSlot, cached.width == width { return cached.height }
        let tallest = StagingDisabledReason.allCases.map { reasonLabelHeight(of: $0.text, width: width) }.max() ?? 0
        reasonSlot = (width, tallest + 2)
        return tallest + 2
    }

    private func visibleRowsHeight(width: CGFloat) -> CGFloat {
        orderedRows.prefix(Self.maxVisibleRows).reduce(0) { $0 + $1.height(forWidth: max(0, width - 12)) }
            + (archivedSnapshot.isEmpty ? 0 : Self.archivedToggleHeight)
    }

    private func askForLayoutIfNeeded() {
        needsLayout = true
        onLayoutChange?()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        noteWindowMove()
        let w = bounds.width
        divider.frame = NSRect(x: 0, y: 0, width: w, height: Self.dividerHeight)
        divider.isHidden = isCollapsed
        var y = Self.dividerHeight
        let expanded = hasList && !isCollapsed && !stripOnly
        stripButton.isHidden = expanded || !hasList
        let hasToken = hasList && !tokenLabel.stringValue.isEmpty
        tokenLabel.isHidden = !hasToken
        for view in [leadLabel, countLabel, reasonLabel, scroll] as [NSView] { view.isHidden = !expanded || (view === reasonLabel && reasonLabel.stringValue.isEmpty) }
        if !expanded {
            chevron.isHidden = true
            menuButton.isHidden = true
            closeLabel.isHidden = true
            var stripX: CGFloat = 8
            if hasToken {
                let size = fitToken(width: max(0, w - 8))
                tokenLabel.frame = NSRect(x: 4, y: y + (Self.stripHeight - size.height) / 2, width: size.width, height: size.height)
                stripX = 4 + size.width + 4
            }
            stripButton.frame = NSRect(x: stripX, y: y, width: max(0, w - stripX - 8), height: Self.stripHeight)
            return
        }
        let headerH = headerHeight(width: w)
        // From the left: the token (never clipped), then the chevron, then the menu, then the close x, each only
        // while it fits; the x goes first when the pane is narrow (its action stays in the menu).
        var x: CGFloat = 6
        if hasToken {
            let size = fitToken(width: max(0, w - 8))
            tokenLabel.frame = NSRect(x: 4, y: y + (Self.stripHeight - size.height) / 2, width: size.width, height: size.height)
            x = 4 + size.width + 3
        }
        var room = w - 4 - x
        let showChevron = room >= 14
        if showChevron { room -= 14 }
        let showMenu = room >= 18
        if showMenu { room -= 18 }
        let showClose = room >= 16
        chevron.isHidden = !showChevron
        menuButton.isHidden = !showMenu
        closeLabel.isHidden = !showClose
        chevron.frame = NSRect(x: x, y: y, width: 14, height: Self.stripHeight)
        var right = w - 4
        if showClose {
            closeLabel.frame = NSRect(x: right - 16, y: y, width: 16, height: Self.stripHeight)
            right -= 16
        }
        let menuW: CGFloat = showMenu ? 18 : 0
        menuButton.frame = NSRect(x: right - menuW, y: y, width: menuW, height: Self.stripHeight)
        right -= menuW + 2
        let countW = countLabel.isHidden ? 0 : ceil(countLabel.intrinsicContentSize.width) + 4
        let leadX: CGFloat = showChevron ? x + 16 : x
        let countX = max(leadX, right - countW)
        countLabel.frame = NSRect(x: countX, y: y + (Self.stripHeight - countLabel.intrinsicContentSize.height) / 2,
                                  width: min(countW, max(0, right - leadX)), height: countLabel.intrinsicContentSize.height)
        let leadWidth = max(0, countX - leadX - (countLabel.isHidden ? 0 : 2))
        if list?.entries.isEmpty == true {
            leadLabel.frame = NSRect(x: leadX, y: y + 4, width: max(0, right - leadX), height: headerH - 6)
        } else {
            leadLabel.frame = NSRect(x: leadX, y: y + (Self.stripHeight - 14) / 2, width: leadWidth, height: 14)
        }
        y += headerH
        if !reasonLabel.isHidden {
            reasonLabel.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: reasonLabelHeight(width: w))
        }
        y += reasonHeight(width: w)     // reserved whether or not a reason shows
        let scrollHeight = max(0, bounds.height - y)
        scroll.frame = NSRect(x: 0, y: y, width: w, height: scrollHeight)
        let rowWidth = max(0, w - (scroll.hasVerticalScroller && scroll.scrollerStyle == .legacy ? 15 : 0))
        var rowY: CGFloat = 0
        for row in orderedRows {
            let h = row.height(forWidth: rowWidth)
            row.frame = NSRect(x: 0, y: rowY, width: rowWidth, height: h)
            rowY += h
        }
        if !archivedSnapshot.isEmpty {
            archivedToggle.frame = NSRect(x: StagingRowView.horizontalPadding, y: rowY, width: max(0, rowWidth - 16), height: Self.archivedToggleHeight)
            rowY += Self.archivedToggleHeight
            if isArchivedExpanded {
                for row in archivedRows {
                    let h = row.height(forWidth: rowWidth)
                    row.frame = NSRect(x: 0, y: rowY, width: rowWidth, height: h)
                    rowY += h
                }
            }
        }
        documentView.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(rowY, scrollHeight))
    }

    /// The token at the largest bold size (10 pt down to 6 pt) that fits `width`: it is never clipped.
    private func fitToken(width: CGFloat) -> NSSize {
        var size: CGFloat = 10
        while true {
            tokenLabel.font = NSFont.systemFont(ofSize: size, weight: .bold)
            let natural = tokenLabel.intrinsicContentSize
            if natural.width + 8 <= width || size <= 6 { return NSSize(width: natural.width + 8, height: natural.height + 2) }
            size -= 1
        }
    }

    /// The drawer moved (its origin or width changed in the window; its height does not count, it is
    /// bottom-anchored): a click that began before the move must not insert, so every row of the terminal
    /// restarts its reading delay. The first layout does not count.
    private func noteWindowMove() {
        guard window != nil, hasList, !isHidden else {
            lastWindowRect = nil
            return
        }
        let rect = convert(bounds, to: nil)
        defer { lastWindowRect = rect }
        guard let last = lastWindowRect else { return }
        guard abs(rect.minX - last.minX) > 0.5 || abs(rect.minY - last.minY) > 0.5 || abs(rect.width - last.width) > 0.5 else { return }
        guard let id = controller.terminalId else { return }
        // At once (a click that began before the move must not insert), without telling observers from inside layout.
        staging.restartReadingDelay(terminalId: id, notify: false)
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // MARK: - Timer (only while visible, in a window, with entries)

    private func updateTimer() {
        let needed = window != nil && !isHidden && list?.entries.isEmpty == false
        if !needed {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        // Common modes: ages keep counting while a menu is open or the divider is dragged.
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
        if window != nil { refresh() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh()
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { hasList }

    /// ⇧⌘J: the drawer takes the keyboard (focus only; nothing is inserted). False when there is nothing to focus.
    @discardableResult
    func focusRows() -> Bool {
        guard hasList, let window else { return false }
        // Reopening a closed drawer is a person's act too (⇧⌘J is a menu key).
        if isUserHidden, !setUserHidden(false, event: NSApp.currentEvent, control: self, fromMenu: true) { return false }
        if isCollapsed { setCollapsed(false) }
        if selectedEntryId == nil { select(order.first) }
        return window.makeFirstResponder(self)
    }

    private static let spaceBlockingModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: moveSelection(by: -1)
        case 125: moveSelection(by: 1)
        case 48:  moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        case 49:
            // Only a plain, first Space places a row: a held key repeats key-downs (each would take a fresh
            // snapshot), and a Space with a modifier is some other shortcut.
            guard !event.isARepeat, event.modifierFlags.isDisjoint(with: Self.spaceBlockingModifiers) else { return }
            if let id = selectedEntryId { rowViews[id]?.activate(with: event) }
        case 53:  onReturnToTerminal?()
        default:  break    // Return and Enter (main and keypad) land here too: swallowed, never forwarded.
        }
    }

    override func mouseDown(with event: NSEvent) {}

    private func moveSelection(by step: Int) {
        guard !order.isEmpty else { return }
        let current = selectedEntryId.flatMap { order.firstIndex(of: $0) }
        let next = min(max((current ?? (step > 0 ? -1 : order.count)) + step, 0), order.count - 1)
        select(order[next])
    }

    private func select(_ id: String?) {
        selectedEntryId = id
        for (rowId, row) in rowViews { row.isSelected = rowId == id }
        if let id, let row = rowViews[id] { documentView.scrollToVisible(row.frame) }
    }
}

/// A flipped container, so rows stack from the top.
final class StagingFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The 4 pt grab line at the drawer's top. Dragging up makes the drawer taller.
final class StagingDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var currentHeight: (() -> CGFloat)?
    private var start: (y: CGFloat, height: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.borderInactive.cgColor
    }

    required init?(coder: NSCoder) { fatalError("StagingDividerView is created in code") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        start = (event.locationInWindow.y, currentHeight?() ?? 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(start.height + (event.locationInWindow.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }
}
