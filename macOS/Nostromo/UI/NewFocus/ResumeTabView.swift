import AppKit

/// One row of the Resume list: fixed-height, frame-laid-out so what is drawn is predictable.
final class ResumeRowView: NSView {
    static let height: CGFloat = 82
    static let margin: CGFloat = 12
    static let menuButtonWidth: CGFloat = 26

    let titleField = ResumeRowView.label(size: 13, weight: .semibold, color: .white)
    let detailField = ResumeRowView.label(size: 11, weight: .regular, color: NSColor(white: 0.68, alpha: 1))
    let promptField = ResumeRowView.label(size: 11, weight: .regular, color: NSColor(white: 0.82, alpha: 1))
    let statusField = ResumeRowView.label(size: 11, weight: .medium, color: NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.35, alpha: 1))
    let menuButton = NSButton()
    var onMenu: ((NSView) -> Void)?

    private static func label(size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.usesSingleLineMode = true
        f.maximumNumberOfLines = 1
        f.cell?.truncatesLastVisibleLine = true
        return f
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [titleField, detailField, promptField, statusField].forEach(addSubview)
        menuButton.title = "\u{22EF}"
        menuButton.isBordered = false
        menuButton.font = .systemFont(ofSize: 15, weight: .bold)
        menuButton.contentTintColor = NSColor(white: 0.8, alpha: 1)
        menuButton.target = self
        menuButton.action = #selector(menuTapped)
        menuButton.setAccessibilityLabel("More actions")
        addSubview(menuButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func menuTapped() { onMenu?(menuButton) }

    func configure(_ t: ConversationHistoryModel.RowText) {
        titleField.stringValue = t.title
        detailField.stringValue = t.detail
        promptField.stringValue = [t.prs, t.firstPrompt].compactMap { $0 }.joined(separator: "  ")
        statusField.stringValue = t.status ?? ""
        // The row is one accessibility element; its label carries the words, status included.
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(t.accessibilityLabel)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let m = Self.margin
        let textW = max(0, bounds.width - 2 * m - Self.menuButtonWidth)
        let fullW = max(0, bounds.width - 2 * m)
        // Top-down: the table is flipped, rows are not; lay out from the top edge of the bounds.
        var y = bounds.height - 8
        func place(_ f: NSTextField, _ h: CGFloat, width: CGFloat) {
            y -= h
            f.frame = NSRect(x: m, y: y, width: width, height: h)
        }
        place(titleField, 17, width: textW)
        place(detailField, 15, width: fullW)
        place(promptField, 15, width: fullW)
        place(statusField, 15, width: fullW)
        menuButton.frame = NSRect(x: bounds.width - m - Self.menuButtonWidth, y: bounds.height - 8 - 20,
                                  width: Self.menuButtonWidth, height: 20)
    }

    /// Selection highlight.
    var isSelected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }
}

/// The Resume tab: search, grouped rows, the first-prompts switch. Backed by `ConversationHistoryModel`.
final class ResumeTabView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item { case header(ConversationHistoryModel.Group, collapsed: Bool), row(ConversationEntryWire) }

    static let searchPlaceholder = "Search title, agent, project, branch, PR, prompt"

    let searchField = NSSearchField()
    let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let banner = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    let promptsCheckbox = NSButton(checkboxWithTitle: "Show first prompts", target: nil, action: nil)

    private(set) var model: ConversationHistoryModel
    private var items: [Item] = []
    private var unavailableExpanded = false
    private var supported = true

    var onResume: ((ConversationEntryWire) -> Void)?
    var onRemove: ((ConversationEntryWire) -> Void)?
    var onShowTranscript: ((ConversationEntryWire) -> Void)?
    var onCancel: (() -> Void)?
    var onSelectionChange: (() -> Void)?
    var onFirstPromptsToggled: ((Bool) -> Void)?

    init(model: ConversationHistoryModel = ConversationHistoryModel()) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 480))
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        searchField.placeholderString = Self.searchPlaceholder
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search conversations")
        for f in [banner, message] {
            f.font = .systemFont(ofSize: 11)
            f.textColor = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.35, alpha: 1)
            f.lineBreakMode = .byTruncatingTail
            f.isHidden = true
        }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        promptsCheckbox.target = self
        promptsCheckbox.action = #selector(promptsToggled)
        promptsCheckbox.state = .on
        for v in [searchField, banner, message, scroll, promptsCheckbox] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            banner.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            banner.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -4),
            message.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            message.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            message.bottomAnchor.constraint(equalTo: promptsCheckbox.topAnchor, constant: -6),
            promptsCheckbox.leadingAnchor.constraint(equalTo: searchField.leadingAnchor),
            promptsCheckbox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -48),
        ])
    }

    // MARK: Data

    /// Replace the listing. `supported` false: the daemon lacks the history.
    func update(history: ConversationHistoryWire?, supported: Bool) {
        self.supported = supported
        model.entries = history?.entries ?? []
        promptsCheckbox.state = (history?.firstPromptsEnabled ?? true) ? .on : .off
        if !supported {
            showBanner("Needs a newer Nostromo daemon: run make install-daemon.")
        } else if let kept = history?.degradedKept {
            showBanner("History couldn\u{2019}t be read (\(kept) entries kept)")
        } else {
            showBanner(nil)
        }
        reload()
    }

    func setNow(_ now: @escaping () -> Date, calendar: Calendar) {
        model.now = now
        model.calendar = calendar
        reload()
    }

    func showMessage(_ text: String?) {
        message.stringValue = text ?? ""
        message.isHidden = (text ?? "").isEmpty
    }

    private func showBanner(_ text: String?) {
        banner.stringValue = text ?? ""
        banner.isHidden = (text ?? "").isEmpty
    }

    var bannerText: String? { banner.isHidden ? nil : banner.stringValue }
    var messageText: String? { message.isHidden ? nil : message.stringValue }

    func hide(_ id: String) { model.hide(id); reload() }
    func unhide(_ id: String) { model.unhide(id); reload() }

    private func reload() {
        let selected = selectedEntry?.id
        items = []
        for g in model.groups {
            if g.kind == .unavailable {
                let collapsed = !unavailableExpanded && model.query.isEmpty
                items.append(.header(g, collapsed: collapsed))
                if !collapsed { items.append(contentsOf: g.rows.map(Item.row)) }
            } else {
                items.append(.header(g, collapsed: false))
                items.append(contentsOf: g.rows.map(Item.row))
            }
        }
        tableView.reloadData()
        if let selected, let idx = items.firstIndex(where: { if case .row(let e) = $0 { return e.id == selected } else { return false } }) {
            select(row: idx)
        } else if let first = items.firstIndex(where: { if case .row = $0 { return true } else { return false } }) {
            select(row: first)
        }
        onSelectionChange?()
    }

    // MARK: Selection and keys

    var selectedEntry: ConversationEntryWire? {
        let r = tableView.selectedRow
        guard items.indices.contains(r), case .row(let e) = items[r] else { return nil }
        return e
    }

    /// Visible rows in order (tests, and the keys' walk).
    var visibleEntries: [ConversationEntryWire] {
        items.compactMap { if case .row(let e) = $0 { return e } else { return nil } }
    }

    private func select(row: Int) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        refreshHighlights()
        onSelectionChange?()
    }

    private func refreshHighlights() {
        for r in 0..<items.count {
            (tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? ResumeRowView)?.isSelected = (r == tableView.selectedRow)
        }
    }

    func moveSelection(by delta: Int) {
        let rows = items.indices.filter { if case .row = items[$0] { return true } else { return false } }
        guard !rows.isEmpty else { return }
        let cur = rows.firstIndex(of: tableView.selectedRow) ?? (delta > 0 ? -1 : rows.count)
        select(row: rows[max(0, min(rows.count - 1, cur + delta))])
    }

    func typeSearch(_ text: String) {
        searchField.stringValue = text
        model.query = text
        reload()
    }

    static func isResumable(_ e: ConversationEntryWire) -> Bool {
        switch e.status {
        case .available, .running: return true
        // Unknown statuses are not resumable: only a status this app understands is.
        default: return false
        }
    }

    func resumeSelected() {
        guard let e = selectedEntry, Self.isResumable(e) else { return }
        onResume?(e)
    }

    func removeSelected() {
        guard let e = selectedEntry else { return }
        onRemove?(e)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        model.query = searchField.stringValue
        reload()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)): resumeSelected(); return true
        // With an empty search the caret has nothing to move through: → opens and ← closes Unavailable.
        case #selector(NSResponder.moveRight(_:)) where model.query.isEmpty && !unavailableExpanded:
            toggleUnavailable(); return true
        case #selector(NSResponder.moveLeft(_:)) where model.query.isEmpty && unavailableExpanded:
            toggleUnavailable(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = items[row] { return 26 }
        return ResumeRowView.height
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .row = items[row] { return true }
        return false
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshHighlights()
        onSelectionChange?()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .header(let g, let collapsed):
            let f = NSTextField(labelWithString: g.kind == .unavailable ? (collapsed ? "\u{25B8} " : "\u{25BE} ") + g.title : g.title)
            f.font = .systemFont(ofSize: 11, weight: .semibold)
            f.textColor = NSColor(white: 0.6, alpha: 1)
            f.setAccessibilityLabel(g.title)
            if g.kind == .unavailable {
                // VoiceOver can press it; the keyboard uses → / ← in the search field.
                f.setAccessibilityRole(.button)
                f.setAccessibilityLabel("\(g.title), \(collapsed ? "collapsed" : "expanded")")
                f.setAccessibilityPerformPress { [weak self] in self?.toggleUnavailable(); return true }
            }
            return f
        case .row(let e):
            let v = ResumeRowView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: ResumeRowView.height))
            v.configure(model.text(for: e))
            v.isSelected = (row == tableView.selectedRow)
            v.onMenu = { [weak self] anchor in self?.showMenu(for: e, at: anchor) }
            v.menu = menu(for: e)
            return v
        }
    }

    /// Open or close the Unavailable group (double-click, → / ←, or VoiceOver press).
    func toggleUnavailable() {
        unavailableExpanded.toggle()
        reload()
    }

    var isUnavailableExpanded: Bool { unavailableExpanded }

    @objc private func doubleClicked() {
        let r = tableView.clickedRow
        guard items.indices.contains(r) else { return }
        switch items[r] {
        case .header(let g, _) where g.kind == .unavailable:
            toggleUnavailable()
        case .row:
            select(row: r); resumeSelected()
        default: break
        }
    }

    // MARK: Menu

    private final class EntryItem: NSMenuItem { var entry: ConversationEntryWire? }

    private func menu(for e: ConversationEntryWire) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let i = EntryItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.entry = e; i.isEnabled = enabled
            m.addItem(i)
        }
        add("Resume", #selector(menuResume(_:)), enabled: Self.isResumable(e))
        add("Remove from History", #selector(menuRemove(_:)))
        add("Show Transcript in Finder", #selector(menuShow(_:)), enabled: e.transcriptPath != nil)
        return m
    }

    /// The row menu's titles (tests).
    func menuTitles(for e: ConversationEntryWire) -> [String] { menu(for: e).items.map(\.title) }

    private func showMenu(for e: ConversationEntryWire, at anchor: NSView) {
        menu(for: e).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func menuResume(_ i: EntryItem) { if let e = i.entry { onResume?(e) } }
    @objc private func menuRemove(_ i: EntryItem) { if let e = i.entry { onRemove?(e) } }
    @objc private func menuShow(_ i: EntryItem) { if let e = i.entry { onShowTranscript?(e) } }

    @objc private func promptsToggled() { onFirstPromptsToggled?(promptsCheckbox.state == .on) }
}
