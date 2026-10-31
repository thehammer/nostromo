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
/// A frame arriving never changes the first responder and never scrolls the terminal. Everything the
/// agent wrote appears only inside a row's command and note slots. In the real app app-control sees none
/// of it (`AppControlAX`, `ScreenshotRedaction`).
///
/// Keyboard (once ⇧⌘J or a click has given it the keyboard): Up/Down and Tab/Shift-Tab move the
/// selection, Space inserts the selected row through the same controller a click uses, Return and
/// Enter do nothing and are never forwarded, Escape gives the keyboard back to the terminal. Nothing in
/// the drawer has a key equivalent and there is no default button.
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

    var terminalPixelArea: NSView { self }

    /// The host re-lays out when the height this drawer wants changed.
    var onLayoutChange: (() -> Void)?
    /// Escape.
    var onReturnToTerminal: (() -> Void)?

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

    private let divider = StagingDividerView()
    private let chevron = StagingClickableLabel()
    private let leadLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let menuButton = StagingClickableLabel()
    private let stripButton = StagingClickableLabel()
    private let reasonLabel = NSTextField(labelWithString: "")
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
        reasonLabel.lineBreakMode = .byTruncatingTail
        reasonLabel.maximumNumberOfLines = Self.reasonLines
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
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = documentView
        scroll.borderType = .noBorder
        divider.onDrag = { [weak self] height in self?.dragged(to: height) }
        divider.currentHeight = { [weak self] in self?.frame.height ?? 0 }
        for view in [divider, scroll, reasonLabel, leadLabel, countLabel, chevron, menuButton, stripButton] as [NSView] {
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
        let structural = wasEmpty || list.revision != lastRevision || env != self.env || !sameRows(models, lastModels)
        if let previous = lastCount, isCollapsed, list.entries.count > previous { pulse() }
        lastCount = list.entries.count
        guard structural else {
            // Only the clock moved (an age, `inserted 2m ago`): update those texts in place. The rows are
            // not laid out again, and a refusal's reason stays.
            if models != lastModels {
                for model in models { rowViews[model.entryId]?.updateAges(model) }
                lastModels = models
            }
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
        isHidden = false
        apply(list: list, env: env, models: models)
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

    private func apply(list: TerminalStagingList, env: StagingEnvironment, models: [StagingRowModel]) {
        let shared = StagingDrawerModel.sharedReason(env)
        let parts = StagingDrawerModel.headerParts(list)
        leadLabel.stringValue = parts.lead
        leadLabel.lineBreakMode = list.entries.isEmpty ? .byWordWrapping : .byTruncatingTail
        leadLabel.maximumNumberOfLines = list.entries.isEmpty ? 0 : 1
        countLabel.stringValue = parts.count ?? ""
        countLabel.isHidden = parts.count == nil
        stripButton.title = StagingDrawerModel.stripText(list)
        menuButton.isHidden = list.entries.isEmpty
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

    private func showHeaderMenu() {
        let menu = NSMenu(title: "Staged commands")
        menu.autoenablesItems = false
        let clear = NSMenuItem(title: "Clear all", action: #selector(clearAllStaged(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !(env?.isMirror ?? true)
        menu.addItem(clear)
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY), in: self)
    }

    @objc private func clearAllStaged(_ sender: NSMenuItem) {
        controller.clearAll(event: NSApp.currentEvent, control: self)
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
        guard hasList, let list else { return 0 }
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

    /// The reason's label height at `width` (one or two lines; wrapping is by word, inside the cell's padding).
    private func reasonLabelHeight(width: CGFloat) -> CGFloat {
        let text = reasonLabel.stringValue
        guard !text.isEmpty else { return 0 }
        let one = ceil(NSLayoutManager().defaultLineHeight(for: Theme.statusFont))
        let available = max(20, width - 16 - 4)
        let full = ceil(NSAttributedString(string: text, attributes: [.font: Theme.statusFont])
            .boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin]).height)
        return min(max(full, one), one * CGFloat(Self.reasonLines))
    }

    private func reasonHeight(width: CGFloat) -> CGFloat {
        reasonStringIsEmpty ? 0 : reasonLabelHeight(width: width) + 2
    }

    private var reasonStringIsEmpty: Bool { reasonLabel.stringValue.isEmpty }

    private func visibleRowsHeight(width: CGFloat) -> CGFloat {
        orderedRows.prefix(Self.maxVisibleRows).reduce(0) { $0 + $1.height(forWidth: max(0, width - 12)) }
    }

    private func askForLayoutIfNeeded() {
        needsLayout = true
        onLayoutChange?()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        divider.frame = NSRect(x: 0, y: 0, width: w, height: Self.dividerHeight)
        divider.isHidden = isCollapsed
        var y = Self.dividerHeight
        let expanded = hasList && !isCollapsed && !stripOnly
        stripButton.isHidden = expanded || !hasList
        for view in [chevron, leadLabel, countLabel, reasonLabel, scroll] as [NSView] { view.isHidden = !expanded || (view === reasonLabel && reasonLabel.stringValue.isEmpty) }
        if hasList, list?.entries.isEmpty == false { menuButton.isHidden = !expanded } else { menuButton.isHidden = true }
        if !expanded {
            stripButton.frame = NSRect(x: 8, y: y, width: max(0, w - 16), height: Self.stripHeight)
            return
        }
        let headerH = headerHeight(width: w)
        chevron.frame = NSRect(x: 6, y: y, width: 16, height: Self.stripHeight)
        let menuW: CGFloat = menuButton.isHidden ? 0 : 22
        menuButton.frame = NSRect(x: w - menuW - 4, y: y, width: menuW, height: Self.stripHeight)
        let countW = countLabel.isHidden ? 0 : ceil(countLabel.intrinsicContentSize.width) + 4
        let leadX: CGFloat = 24
        let right = w - menuW - 6
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
            y += reasonHeight(width: w)
        }
        let scrollHeight = max(0, bounds.height - y)
        scroll.frame = NSRect(x: 0, y: y, width: w, height: scrollHeight)
        let rowWidth = max(0, w - (scroll.hasVerticalScroller && scroll.scrollerStyle == .legacy ? 15 : 0))
        var rowY: CGFloat = 0
        for row in orderedRows {
            let h = row.height(forWidth: rowWidth)
            row.frame = NSRect(x: 0, y: rowY, width: rowWidth, height: h)
            rowY += h
        }
        documentView.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(rowY, scrollHeight))
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
