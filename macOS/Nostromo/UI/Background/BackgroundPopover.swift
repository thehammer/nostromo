import AppKit
import Combine
import NostromoKit

// MARK: - Actions

/// What a row can do beyond Copy Description. Later slices implement these (Open: BA4, Stop: BA5,
/// Show in Transcript: BA6); until one does, its item is not shown and its key does nothing.
protocol BackgroundTaskActions: AnyObject {
    func canOpen(_ row: BackgroundTaskRow, tag: String) -> Bool
    func open(_ row: BackgroundTaskRow, tag: String)
    func canStop(_ row: BackgroundTaskRow, tag: String) -> Bool
    func stop(_ row: BackgroundTaskRow, tag: String)
    func canShowInTranscript(_ row: BackgroundTaskRow, tag: String) -> Bool
    func showInTranscript(_ row: BackgroundTaskRow, tag: String)
}

extension BackgroundTaskActions {
    func canOpen(_ row: BackgroundTaskRow, tag: String) -> Bool { false }
    func open(_ row: BackgroundTaskRow, tag: String) {}
    func canStop(_ row: BackgroundTaskRow, tag: String) -> Bool { false }
    func stop(_ row: BackgroundTaskRow, tag: String) {}
    func canShowInTranscript(_ row: BackgroundTaskRow, tag: String) -> Bool { false }
    func showInTranscript(_ row: BackgroundTaskRow, tag: String) {}
}

/// No actions yet (BA3): rows can only be copied.
final class NoBackgroundTaskActions: BackgroundTaskActions {
    static let shared = NoBackgroundTaskActions()
}

// MARK: - Section header

/// `Ended`, or the `▸ Housekeeping (N)` disclosure (clickable; ←/→ and Return too).
final class BackgroundSectionHeaderView: NSView {
    static let height: CGFloat = 22

    private let label = NSTextField(labelWithString: "")
    private(set) var isSelected = false
    var onClick: (() -> Void)?

    var text: String { label.stringValue }
    var textColor: NSColor? { label.textColor }

    init(text: String, isDisclosure: Bool) {
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height))
        wantsLayer = true
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = BackgroundPalette.muted
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: BackgroundTaskRowView.horizontalInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -BackgroundTaskRowView.horizontalInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityChildren([])
        setAccessibilityRole(isDisclosure ? .button : .staticText)
        setText(text)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setText(_ text: String) {
        label.stringValue = text
        setAccessibilityLabel(text)
    }

    func setSelected(_ on: Bool) {
        guard isSelected != on else { return }
        isSelected = on
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = on ? BackgroundPalette.selectionRing.cgColor : nil
        setAccessibilitySelected(on)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}

// MARK: - Content view

/// The popover's content view. Takes the keyboard only when the popover was opened from the
/// keyboard (⇧⌘B) or the user clicked into it; hands keys to the controller.
final class BackgroundPopoverContentView: NSView, BackgroundShortcutTarget {
    var acceptsKeyboard = false
    var onKeyDown: ((NSEvent) -> Bool)?
    /// ⇧⌘B while the popover holds the keyboard: close it.
    var onShortcut: (() -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { acceptsKeyboard }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc func showBackgroundPopover(_ sender: Any?) {
        onShortcut?()
    }

    @objc var canShowBackgroundPopover: Bool { true }
}

/// The scrolling list's document view.
private final class BackgroundListDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - View controller

/// The list: header (`Background activity: Claudia`, `2 running`), the running tasks, `Ended`,
/// and the collapsed `▸ Housekeeping (N)`. Fixed width; as tall as its content up to
/// `maxHeight`, then the list scrolls inside it.
final class BackgroundPopoverViewController: NSViewController {
    static let width: CGFloat = 460
    static let maxHeight: CGFloat = 420
    static let headerHeight: CGFloat = 30
    static let bottomInset: CGFloat = 6
    static let emptyText = "No background activity"

    let tag: String
    let displayName: String
    private let store: BackgroundTaskStore
    private let actions: BackgroundTaskActions
    private let pasteboard: NSPasteboard
    private let announce: (String) -> Void

    /// What the popover shows now (the model `nostromo-app tasks list` formats too).
    private(set) var list: BackgroundTaskList = .empty
    private(set) var housekeepingExpanded = false
    /// The rows and headers that can hold the keyboard selection, top to bottom.
    private(set) var selectables: [NSView] = []
    private(set) var selectedIndex: Int?
    /// How many times the list was rebuilt from the store (a tick or a change).
    private(set) var reloadCount = 0
    /// Statuses at the last reload, to announce a task that failed while the popover is shown.
    private var lastStatuses: [String: TaskStatusWire] = [:]

    let headerTitle = NSTextField(labelWithString: "")
    let headerCount = NSTextField(labelWithString: "")
    let scrollView = NSScrollView()
    private let documentView = BackgroundListDocumentView()
    private let emptyLabel = NSTextField(labelWithString: BackgroundPopoverViewController.emptyText)
    private var rowViews: [String: BackgroundTaskRowView] = [:]
    private var endedHeader: BackgroundSectionHeaderView?
    private var housekeepingHeader: BackgroundSectionHeaderView?
    private var listHeight: NSLayoutConstraint!

    /// Closes the popover (set by `BackgroundPopover`).
    var requestClose: (() -> Void)?

    var contentView: BackgroundPopoverContentView { view as! BackgroundPopoverContentView }

    init(tag: String, displayName: String, store: BackgroundTaskStore, actions: BackgroundTaskActions,
         pasteboard: NSPasteboard = .general, announce: @escaping (String) -> Void) {
        self.tag = tag
        self.displayName = displayName
        self.store = store
        self.actions = actions
        self.pasteboard = pasteboard
        self.announce = announce
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let content = BackgroundPopoverContentView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 120))
        content.appearance = NSAppearance(named: .darkAqua)
        content.wantsLayer = true
        content.layer?.backgroundColor = BackgroundPalette.background.cgColor
        content.onKeyDown = { [weak self] in self?.handleKey($0) ?? false }
        content.onCancel = { [weak self] in self?.requestClose?() }
        content.onShortcut = { [weak self] in self?.requestClose?() }

        headerTitle.stringValue = "Background activity: \(displayName)"
        headerTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        headerTitle.textColor = BackgroundPalette.text
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerCount.font = .systemFont(ofSize: 11)
        headerCount.textColor = BackgroundPalette.muted
        headerCount.alignment = .right
        headerCount.setContentCompressionResistancePriority(.required, for: .horizontal)
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = BackgroundPalette.separator.cgColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView
        documentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: 0)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = BackgroundPalette.muted
        emptyLabel.isHidden = true

        for v in [headerTitle, headerCount, separator, scrollView] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        listHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            headerTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: BackgroundTaskRowView.horizontalInset),
            headerTitle.centerYAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight / 2),
            headerCount.leadingAnchor.constraint(greaterThanOrEqualTo: headerTitle.trailingAnchor, constant: 12),
            headerCount.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -BackgroundTaskRowView.horizontalInset),
            headerCount.centerYAnchor.constraint(equalTo: headerTitle.centerYAnchor),
            separator.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            listHeight,
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.bottomInset),
        ])
        view = content
        reload()
    }

    // MARK: Reload

    /// Rebuild what is shown from the store: a change for this tag, or the elapsed tick. Row views
    /// are kept per task and updated in place; the selection and the scroll position stay.
    func reload() {
        _ = view   // load the view first: `reload` can run before the popover shows
        reloadCount += 1
        let next = store.list(for: tag)
        announceNewFailures(in: next)
        list = next
        headerCount.stringValue = list.runningCountText

        let selectedKey = selectedIndex.flatMap { selectables.indices.contains($0) ? key(of: selectables[$0]) : nil }
        var ordered: [NSView] = []
        var placed: [(NSView, CGFloat)] = []
        var used = Set<String>()
        func rowView(_ row: BackgroundTaskRow) -> BackgroundTaskRowView {
            used.insert(row.id)
            let display = stopDisplay(for: row)
            if let existing = rowViews[row.id] {
                // Stop support can turn on after the row was built: the button follows it.
                if existing.stopButton == nil, row.stopOffered { existing.installStop(makeStopButton(taskId: row.id)) }
                existing.apply(row, stop: display)
                return existing
            }
            let view = BackgroundTaskRowView(row: row)
            view.onClick = { [weak self] clicked in self?.clicked(clicked) }
            view.menuProvider = { [weak self] in self?.contextMenu(for: $0) }
            if row.stopOffered { view.installStop(makeStopButton(taskId: row.id)) }
            view.applyStop(display)
            rowViews[row.id] = view
            return view
        }
        // Lay `rows` out next; each can hold the keyboard selection.
        func placeRows(_ rows: [BackgroundTaskRow]) {
            for row in rows {
                let v = rowView(row)
                placed.append((v, BackgroundTaskRowView.height(for: row)))
                ordered.append(v)
            }
        }

        placeRows(list.running)
        if !list.ended.isEmpty {
            let header = endedHeader ?? BackgroundSectionHeaderView(text: "Ended", isDisclosure: false)
            endedHeader = header
            placed.append((header, BackgroundSectionHeaderView.height))
            placeRows(list.ended)
        } else {
            endedHeader = nil
        }
        if !list.housekeeping.isEmpty {
            let header = housekeepingHeader ?? {
                let h = BackgroundSectionHeaderView(text: "", isDisclosure: true)
                h.onClick = { [weak self] in self?.setHousekeepingExpanded(!(self?.housekeepingExpanded ?? true)) }
                return h
            }()
            housekeepingHeader = header
            header.setText(housekeepingTitle)
            placed.append((header, BackgroundSectionHeaderView.height))
            ordered.append(header)
            if housekeepingExpanded { placeRows(list.housekeeping) }
        } else {
            housekeepingHeader = nil
        }
        for (id, v) in rowViews where !used.contains(id) {
            v.tearDown()
            v.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }

        // Lay the document out top-down (flipped).
        let wanted = Set(placed.map { ObjectIdentifier($0.0) })
        for sub in documentView.subviews where !wanted.contains(ObjectIdentifier(sub)) && sub !== emptyLabel {
            sub.removeFromSuperview()
        }
        var y: CGFloat = 4
        for (v, height) in placed {
            if v.superview !== documentView { documentView.addSubview(v) }
            v.frame = NSRect(x: 4, y: y, width: Self.width - 8, height: height)
            y += height
        }
        if placed.isEmpty {
            if emptyLabel.superview !== documentView { documentView.addSubview(emptyLabel) }
            emptyLabel.isHidden = false
            emptyLabel.sizeToFit()
            emptyLabel.setFrameOrigin(NSPoint(x: BackgroundTaskRowView.horizontalInset + 4, y: 8))
            y = 8 + emptyLabel.frame.height + 8
        } else {
            emptyLabel.isHidden = true
            y += 4
        }
        documentView.setFrameSize(NSSize(width: Self.width, height: y))
        let listMax = Self.maxHeight - Self.headerHeight - 1 - Self.bottomInset
        listHeight.constant = min(y, listMax)
        preferredContentSize = NSSize(width: Self.width,
                                      height: Self.headerHeight + 1 + listHeight.constant + Self.bottomInset)

        selectables = ordered
        if let selectedKey, let index = ordered.firstIndex(where: { key(of: $0) == selectedKey }) {
            select(index, scroll: false)
        } else if let selectedIndex, !ordered.isEmpty {
            select(min(selectedIndex, ordered.count - 1), scroll: false)
        } else {
            select(nil, scroll: false)
        }
    }

    var housekeepingTitle: String {
        "\(housekeepingExpanded ? "\u{25BE}" : "\u{25B8}") Housekeeping (\(list.housekeeping.count))"
    }

    /// The rows on screen, top to bottom (headers excluded).
    var visibleRowViews: [BackgroundTaskRowView] {
        documentView.subviews.compactMap { $0 as? BackgroundTaskRowView }.sorted { $0.frame.minY < $1.frame.minY }
    }

    var housekeepingHeaderView: BackgroundSectionHeaderView? { housekeepingHeader }
    var endedHeaderView: BackgroundSectionHeaderView? { endedHeader }
    var isShowingEmptyState: Bool { !emptyLabel.isHidden && emptyLabel.superview != nil }

    func setHousekeepingExpanded(_ expanded: Bool) {
        guard housekeepingExpanded != expanded else { return }
        housekeepingExpanded = expanded
        reload()
    }

    // MARK: Selection and keys

    /// Put the keyboard selection on the first row (⇧⌘B).
    func selectFirst() {
        select(selectables.isEmpty ? nil : 0, scroll: true)
    }

    func select(_ index: Int?, scroll: Bool = true) {
        selectedIndex = index
        for (i, v) in selectables.enumerated() {
            let on = i == index
            (v as? BackgroundTaskRowView)?.setSelected(on)
            (v as? BackgroundSectionHeaderView)?.setSelected(on)
        }
        if scroll, let index, selectables.indices.contains(index) {
            documentView.scrollToVisible(selectables[index].frame)
        }
    }

    var selectedRow: BackgroundTaskRow? {
        guard let selectedIndex, selectables.indices.contains(selectedIndex) else { return nil }
        return (selectables[selectedIndex] as? BackgroundTaskRowView)?.row
    }

    /// ↑/↓ between rows, Return opens (or toggles Housekeeping), ←/→ collapse/expand Housekeeping,
    /// Esc closes. True when the key was the popover's.
    func handleKey(_ event: NSEvent) -> Bool {
        if BackgroundGesture.isStopShortcut(event) {
            stopSelected(event)
            return true
        }
        switch event.keyCode {
        case 125: // down
            guard !selectables.isEmpty else { return true }
            select(min((selectedIndex ?? -1) + 1, selectables.count - 1))
            return true
        case 126: // up
            guard !selectables.isEmpty else { return true }
            select(max((selectedIndex ?? selectables.count) - 1, 0))
            return true
        case 123: // left
            if list.housekeeping.isEmpty { return true }
            let wasInside = selectedRow?.isHousekeeping == true
            setHousekeepingExpanded(false)
            if wasInside, let header = housekeepingHeader, let i = selectables.firstIndex(where: { $0 === header }) { select(i) }
            return true
        case 124: // right
            if !list.housekeeping.isEmpty { setHousekeepingExpanded(true) }
            return true
        case 36, 76: // Return, Enter
            activateSelection()
            return true
        case 53: // Esc
            requestClose?()
            return true
        default:
            return false
        }
    }

    /// ⌘. on the selected row: its two-step Stop (each keypress behind the human-gesture check). Nothing
    /// when no row is selected or the row cannot be stopped; the key is the popover's either way.
    func stopSelected(_ event: NSEvent? = nil) {
        guard let row = selectedRow else { return }
        rowViews[row.id]?.stopButton?.shortcut(event)
    }

    /// Stop the revert timers of every row's button (the popover closed).
    func invalidateStops() {
        for view in rowViews.values { view.tearDown() }
    }

    private func stopDisplay(for row: BackgroundTaskRow) -> BackgroundTaskStore.StopDisplay {
        store.stopDisplay(tag: tag, taskId: row.id, ended: row.isEnded)
    }

    private func makeStopButton(taskId: String) -> TaskStopButton {
        TaskStopButton(
            permit: { [weak self] in self?.stopPermit($0) ?? .refused(reason: .notAUserEvent) },
            menuPermit: { [weak self] in self?.stopMenuPermit($0) ?? .refused(reason: .notAUserEvent) },
            schedule: { [weak self] delay, work in
                if let self { self.stopSchedule(delay, work) }
            },
            requestStop: { [weak self] confirmation in
                guard let self else { return }
                self.store.requestStop(tag: self.tag, taskId: taskId, confirmation: confirmation)
            })
    }

    /// Return on the selection: open the task (BA4), or toggle Housekeeping.
    func activateSelection() {
        guard let selectedIndex, selectables.indices.contains(selectedIndex) else { return }
        if selectables[selectedIndex] === housekeepingHeader {
            setHousekeepingExpanded(!housekeepingExpanded)
        } else if let row = selectedRow, actions.canOpen(row, tag: tag) {
            actions.open(row, tag: tag)
        }
    }

    private func clicked(_ rowView: BackgroundTaskRowView) {
        if let index = selectables.firstIndex(where: { $0 === rowView }) { select(index, scroll: false) }
        onRowClick?(rowView.row)
        if actions.canOpen(rowView.row, tag: tag) { actions.open(rowView.row, tag: tag) }
    }

    /// The human-gesture checks and the revert timer of the rows' Stop buttons (tests replace them).
    var stopPermit: BackgroundGesture.Permit = BackgroundGesture.defaultPermit
    var stopMenuPermit: BackgroundGesture.Permit = BackgroundGesture.defaultMenuPermit
    var stopSchedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A row was clicked (the popover then takes the keyboard: the user is in it).
    var onRowClick: ((BackgroundTaskRow) -> Void)?

    private func key(of view: NSView) -> String? {
        if let row = view as? BackgroundTaskRowView { return "task:" + row.row.id }
        if view === housekeepingHeader { return "housekeeping" }
        return nil
    }

    // MARK: Context menu

    /// Copy Description now; Open, Stop and Show in Transcript once a later slice implements them.
    func contextMenu(for row: BackgroundTaskRow) -> NSMenu {
        let menu = NSMenu()
        let actions = self.actions, tag = self.tag
        if actions.canOpen(row, tag: tag) {
            menu.addItem(item("Open") { actions.open(row, tag: tag) })
        }
        if actions.canStop(row, tag: tag) {
            // The row's button goes to `Stop?`; the second click is still required.
            menu.addItem(item("Stop") { [weak self] in
                self?.rowViews[row.id]?.stopButton?.arm()
                actions.stop(row, tag: tag)
            })
        }
        menu.addItem(item("Copy Description") { [weak self] in self?.copyDescription(row) })
        if actions.canShowInTranscript(row, tag: tag) {
            menu.addItem(item("Show in Transcript") { actions.showInTranscript(row, tag: tag) })
        }
        return menu
    }

    func copyDescription(_ row: BackgroundTaskRow) {
        pasteboard.clearContents()
        pasteboard.setString(row.description, forType: .string)
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        BlockMenuItem(title: title, action: action)
    }

    // MARK: Announcements

    /// One announcement when tasks fail while the popover is shown; nothing for any other change.
    private func announceNewFailures(in next: BackgroundTaskList) {
        let rows = next.allRows
        defer { lastStatuses = Dictionary(rows.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a }) }
        guard reloadCount > 1 else { return }   // the first load is not news
        // Failed now and not failed at the last reload (a task new since then counts too).
        let failed = rows.filter { $0.isFailed && lastStatuses[$0.id] != .failed }
        guard !failed.isEmpty else { return }
        announce(failed.count == 1 ? "\(failed[0].title) failed" : "\(failed.count) background tasks failed")
    }
}

/// A menu item that runs a closure.
private final class BlockMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// MARK: - Popover

/// The `NSPopover` around `BackgroundPopoverViewController`, anchored to the chip.
///
/// Focus (PRD "Scroll and focus safety"): opened by a click, it never takes the keyboard: the
/// composer keeps it (if showing moved the key window or first responder, both are put back at
/// once). Opened by ⇧⌘B, it takes the keyboard and selects the first row. However it closes (Esc,
/// a click outside, ⇧⌘B again), the key window, first responder and selection it took them from
/// get them back, except that a click-opened popover (which never took them) leaves the first
/// responder wherever it is by then: a click outside that landed in another composer keeps it.
/// Esc closes it in both cases: a local key monitor consumes Esc, and only Esc, while it is shown.
final class BackgroundPopover: NSObject, NSPopoverDelegate {
    let viewController: BackgroundPopoverViewController
    private let popover = NSPopover()
    private let store: BackgroundTaskStore
    private let schedule: ElapsedTicker.Schedule
    private var subscription: AnyCancellable?
    private var cancelTick: (() -> Void)?
    private var keyMonitor: Any?
    private var saved: (window: NSWindow?, responder: NSResponder?, selection: [NSValue]?) = (nil, nil, nil)

    /// Called when the popover has closed, however it closed.
    var onDidClose: (() -> Void)?
    /// The popover holds (or held) the keyboard: opened by ⇧⌘B, or the user clicked a row.
    private(set) var tookKeyboard = false
    /// Elapsed ticks delivered while shown.
    private(set) var tickCount = 0

    var isShown: Bool { popover.isShown }
    var tag: String { viewController.tag }

    /// - Parameters:
    ///   - schedule: runs the 1 Hz elapsed tick (tests pass a manual one).
    ///   - announce: VoiceOver announcements (tests capture them).
    init(tag: String, displayName: String, store: BackgroundTaskStore,
         actions: BackgroundTaskActions = NoBackgroundTaskActions.shared,
         pasteboard: NSPasteboard = .general,
         schedule: @escaping ElapsedTicker.Schedule = ElapsedTicker.onMainQueue,
         announce: ((String) -> Void)? = nil) {
        self.store = store
        self.schedule = schedule
        let announcer: (String) -> Void = announce ?? { text in
            guard let app = NSApp else { return }
            NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        viewController = BackgroundPopoverViewController(tag: tag, displayName: displayName, store: store,
                                                         actions: actions, pasteboard: pasteboard,
                                                         announce: announcer)
        super.init()
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.animates = false
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        viewController.requestClose = { [weak self] in self?.close() }
        viewController.onRowClick = { [weak self] _ in self?.takeKeyboard(selectFirst: false) }
    }

    /// Open above `view` (the chip). `takeKeyboard`: opened by ⇧⌘B (explicit keyboard intent).
    func show(relativeTo view: NSView, takeKeyboard: Bool) {
        guard !popover.isShown else { return }
        let window = view.window
        let responder = window?.firstResponder
        saved = (window, responder, (responder as? NSTextView)?.selectedRanges)
        let keyBefore = NSApp?.keyWindow
        tookKeyboard = false
        viewController.contentView.acceptsKeyboard = false
        viewController.reload()

        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        store.markSeen(tag: tag)
        startLiveUpdates()
        installKeyMonitor()

        if takeKeyboard {
            self.takeKeyboard(selectFirst: true)
        } else {
            // A click never moves the keyboard: undo whatever showing did.
            if let keyBefore, NSApp?.keyWindow !== keyBefore { keyBefore.makeKey() }
            restoreResponder()
        }
    }

    func close() {
        popover.performClose(nil)
    }

    /// The popover's window takes the keyboard, its content view the first responder.
    private func takeKeyboard(selectFirst: Bool) {
        guard popover.isShown else { return }
        tookKeyboard = true
        let content = viewController.contentView
        content.acceptsKeyboard = true
        content.window?.makeKey()
        content.window?.makeFirstResponder(content)
        if selectFirst { viewController.selectFirst() }
    }

    /// What the local key monitor does with a key-down while the popover is shown: Esc closes it
    /// and is consumed; every other key goes on unchanged.
    func handleMonitoredKey(_ event: NSEvent) -> NSEvent? {
        guard popover.isShown, event.type == .keyDown else { return event }
        if tookKeyboard, BackgroundGesture.isStopShortcut(event) {
            // ⌘. in the popover is the selected row's Stop, never the input bar's interrupt.
            viewController.stopSelected(event)
            return nil
        }
        guard event.keyCode == 53 else { return event }
        close()
        return nil
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        viewController.invalidateStops()
        tearDown()
        store.markSeen(tag: tag)
        let hadKeyboard = tookKeyboard
        tookKeyboard = false
        viewController.contentView.acceptsKeyboard = false
        if hadKeyboard || NSApp?.keyWindow == nil || NSApp?.keyWindow === viewController.view.window {
            if let window = saved.window, window.isVisible, NSApp?.keyWindow !== window { window.makeKey() }
        }
        if hadKeyboard || firstResponderIsFree() { restoreResponder() }
        saved = (nil, nil, nil)
        onDidClose?()
    }

    // MARK: Private

    /// Whether nobody holds the first responder in the window the popover was opened from: it is nil,
    /// the window itself, or something in the popover's own window. If it is anything else, the user
    /// has moved on (a click outside that landed in another pane's composer before this close was
    /// delivered) and that is where the keyboard stays. A click-opened popover never moved it.
    private func firstResponderIsFree() -> Bool {
        guard let window = saved.window else { return false }
        guard let current = window.firstResponder, current !== window else { return true }
        guard let popoverWindow = viewController.view.window else { return false }
        if current === popoverWindow { return true }
        return (current as? NSView)?.window === popoverWindow
    }

    /// Put the first responder and its selection back where they were, if they moved.
    private func restoreResponder() {
        guard let window = saved.window, let responder = saved.responder else { return }
        if window.firstResponder !== responder { window.makeFirstResponder(responder) }
        if let text = responder as? NSTextView, let selection = saved.selection, text.selectedRanges != selection {
            text.selectedRanges = selection
        }
    }

    private func startLiveUpdates() {
        subscription = store.changes
            .filter { [weak self] in $0 == self?.tag }
            .sink { [weak self] _ in self?.refresh() }
        scheduleTick()
    }

    private func refresh() {
        guard popover.isShown else { return }
        viewController.reload()
        scheduleTick()
    }

    /// One tick a second while something runs (elapsed times move); none otherwise.
    private func scheduleTick() {
        cancelTick?()
        cancelTick = nil
        guard popover.isShown, !viewController.list.running.isEmpty else { return }
        cancelTick = schedule(1) { [weak self] in
            guard let self else { return }
            self.cancelTick = nil
            self.tickCount += 1
            self.refresh()
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleMonitoredKey(event)
        }
    }

    private func tearDown() {
        subscription = nil
        cancelTick?()
        cancelTick = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
