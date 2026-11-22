import AppKit

// Message queue S2: the chips above the composer.
//
// A message sent while the agent is busy waits in the daemon's queue, and this area says so: a header
// ("Waiting for Cody to finish · 2 queued") and one chip per message, oldest at the top, newest directly
// above the composer. A chip is never a transcript bubble; the bubble appears when the daemon delivers.
// The area is zero height with no chips, and with more than `collapsedLimit` it shows the newest few
// plus "Show N more"; expanded, it scrolls inside a height `maxHeight` bounds so the composer stays
// visible. Edit and Remove are human-gated (`HumanGesture.permit`): a refused gesture does nothing.

// MARK: - Words

/// What a chip and the header say. Pure, so the rules are unit tests.
enum QueuedMessageText {

    /// Longest first line a chip shows before the ellipsis.
    static let maxFirstLine = 80

    static func header(displayName: String, count: Int, waitingForSignIn: Bool) -> String {
        let who = waitingForSignIn ? "Waiting for sign-in" : "Waiting for \(displayName) to finish"
        return "\(who) · \(count) queued"
    }

    /// `From Mother overview`, `From work item`, `From an agent`; empty for a typed message.
    static func originLabel(_ entry: QueuedMessage) -> String? {
        guard !entry.isTyped else { return nil }
        switch entry.appLabel {
        case "mother_overview": return "From Mother overview"
        case "work_item": return "From work item"
        case "agent_seed": return "From an agent"
        default: return "From the app"
        }
    }

    /// The chip's one line: the first line trimmed and cut with an ellipsis, `(+N lines)` for the rest,
    /// `+N image(s)`, and `own turn` on a slash command. An app message reads as its origin.
    static func summary(_ entry: QueuedMessage) -> String {
        var parts: [String] = []
        if let origin = originLabel(entry) { parts.append(origin) }
        let lines = entry.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var first = (lines.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
        if first.count > maxFirstLine { first = String(first.prefix(maxFirstLine)).trimmingCharacters(in: .whitespaces) + "…" }
        if entry.isTyped { parts.append(first) }
        var line = parts.joined(separator: ": ")
        let extra = lines.count - 1
        if extra > 0 { line += " (+\(extra) line\(extra == 1 ? "" : "s"))" }
        if entry.imageCount > 0 { line += " +\(entry.imageCount) image\(entry.imageCount == 1 ? "" : "s")" }
        if entry.isCommand { line += " · own turn" }
        return line
    }

    /// What VoiceOver reads: the whole text, never the truncated line.
    static func accessibilityLabel(_ entry: QueuedMessage, index: Int, total: Int) -> String {
        var label = "Queued message \(index) of \(total): "
        label += entry.isTyped ? entry.text : "\(originLabel(entry) ?? "From the app"), \(entry.text)"
        if entry.imageCount > 0 { label += ", \(entry.imageCount) image\(entry.imageCount == 1 ? "" : "s")" }
        if entry.isCommand { label += ", own turn" }
        return label
    }

    static let editDisabledReason = "Send or clear what you're typing first"
}

// MARK: - Chip

final class QueuedChipView: NSView {

    static let height: CGFloat = 28

    let entry: QueuedMessage
    let index: Int
    let total: Int
    let label: NSTextField
    let editButton = NSButton()
    let removeButton = NSButton()

    var onEdit: ((QueuedMessage) -> Void)?
    var onRemove: ((QueuedMessage) -> Void)?
    var permit: (NSView) -> HumanGestureVerdict = { HumanGesture.permit(NSApp?.currentEvent, control: $0) }

    /// Edit takes the message into the composer, so it waits for an empty one.
    var editEnabled = true {
        didSet { applyEditState() }
    }

    private var canEdit: Bool { entry.isTyped && entry.canTakeBack }

    init(entry: QueuedMessage, index: Int, total: Int) {
        self.entry = entry
        self.index = index
        self.total = total
        label = NSTextField(labelWithString: QueuedMessageText.summary(entry))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.bgBar.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.borderInactive.cgColor

        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.fg
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip = entry.text   // hover shows the whole message
        label.setAccessibilityElement(false)
        addSubview(label)

        configure(editButton, title: "✎", help: "Edit", action: #selector(editPressed))
        configure(removeButton, title: "✕", help: "Remove", action: #selector(removePressed))
        editButton.setAccessibilityLabel("Edit queued message")
        removeButton.setAccessibilityLabel("Remove queued message")
        editButton.isHidden = !canEdit
        applyEditState()

        // One element for VoiceOver: the full text, with Edit and Remove as actions (no Edit on app messages).
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(QueuedMessageText.accessibilityLabel(entry, index: index, total: total))
        updateAccessibilityActions()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 22
        var right = bounds.width - 6
        removeButton.frame = NSRect(x: right - buttonSize, y: (bounds.height - buttonSize) / 2,
                                    width: buttonSize, height: buttonSize)
        right = removeButton.frame.minX - 2
        if canEdit {
            editButton.frame = NSRect(x: right - buttonSize, y: removeButton.frame.minY, width: buttonSize, height: buttonSize)
            right = editButton.frame.minX - 4
        }
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: (bounds.height - size.height) / 2, width: max(0, right - 10), height: size.height)
    }

    /// A click on the body edits, like Edit.
    override func mouseDown(with event: NSEvent) {
        edit()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: remove()          // Delete, forward delete
        case 36, 76, 49: edit()         // Return, Enter, Space
        default: super.keyDown(with: event)
        }
    }

    /// The Edit action as a person triggers it. False when it did nothing.
    @discardableResult
    func edit() -> Bool {
        guard canEdit, editEnabled, case .human = permit(self) else { return false }
        onEdit?(entry)
        return true
    }

    /// The Remove action as a person triggers it. False when it did nothing.
    @discardableResult
    func remove() -> Bool {
        guard case .human = permit(self) else { return false }
        onRemove?(entry)
        return true
    }

    override func accessibilityPerformPress() -> Bool { edit() }

    // MARK: Private

    private func configure(_ button: NSButton, title: String, help: String, action: Selector) {
        button.title = title
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = Theme.fgMuted
        button.toolTip = help
        button.target = self
        button.action = action
        addSubview(button)
    }

    private func applyEditState() {
        editButton.isEnabled = editEnabled
        editButton.toolTip = editEnabled ? "Edit" : QueuedMessageText.editDisabledReason
        editButton.setAccessibilityHelp(editEnabled ? nil : QueuedMessageText.editDisabledReason)
        updateAccessibilityActions()
    }

    private func updateAccessibilityActions() {
        var actions: [NSAccessibilityCustomAction] = []
        if canEdit && editEnabled {
            actions.append(NSAccessibilityCustomAction(name: "Edit") { [weak self] in self?.edit() ?? false })
        }
        actions.append(NSAccessibilityCustomAction(name: "Remove") { [weak self] in self?.remove() ?? false })
        setAccessibilityCustomActions(actions)
        setAccessibilityHelp(canEdit && !editEnabled ? QueuedMessageText.editDisabledReason : nil)
    }

    @objc private func editPressed() { edit() }
    @objc private func removePressed() { remove() }
}

// MARK: - The area

final class QueuedMessagesView: NSView {

    /// More chips than this collapse to the newest few plus "Show N more".
    static let collapsedLimit = 3
    static let headerHeight: CGFloat = 24
    static let rowGap: CGFloat = 4
    static let verticalPadding: CGFloat = 6
    static let statusHeight: CGFloat = 20

    var onEdit: ((QueuedMessage) -> Void)?
    var onRemove: ((QueuedMessage) -> Void)?
    var permit: (NSView) -> HumanGestureVerdict = { HumanGesture.permit(NSApp?.currentEvent, control: $0) }
    /// Called when `preferredHeight` changed, so the host can resize this area.
    var onHeightChange: (() -> Void)?

    /// The tallest this area may be: the host sets a third of the pane. The composer must stay visible.
    var maxHeight: CGFloat = .greatestFiniteMagnitude {
        didSet { if maxHeight != oldValue { needsLayout = true; onHeightChange?() } }
    }

    private(set) var entries: [QueuedMessage] = []
    private(set) var isExpanded = false
    private(set) var headerText = ""
    /// A short message under the chips ("Already sent"), shown for a few seconds.
    private(set) var statusText: String?

    /// Edit waits for an empty composer.
    var composerHasDraft = false {
        didSet {
            guard composerHasDraft != oldValue else { return }
            chips.forEach { $0.editEnabled = !composerHasDraft }
        }
    }

    let headerLabel = NSTextField(labelWithString: "")
    let showMoreButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let content = FlippedView()
    private(set) var chips: [QueuedChipView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = Theme.fgMuted
        headerLabel.lineBreakMode = .byTruncatingTail
        addSubview(headerLabel)

        showMoreButton.isBordered = false
        showMoreButton.font = .systemFont(ofSize: 11)
        showMoreButton.contentTintColor = Theme.cornflower
        showMoreButton.target = self
        showMoreButton.action = #selector(toggleExpanded)
        addSubview(showMoreButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.fgMuted
        statusLabel.isHidden = true
        addSubview(statusLabel)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = content
        addSubview(scroll)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    // MARK: Content

    func setContent(entries newEntries: [QueuedMessage], displayName: String, waitingForSignIn: Bool) {
        let before = preferredHeight
        entries = newEntries
        if entries.count <= Self.collapsedLimit { isExpanded = false }
        headerText = QueuedMessageText.header(displayName: displayName, count: entries.count,
                                              waitingForSignIn: waitingForSignIn)
        headerLabel.stringValue = headerText
        rebuildChips()
        updateGroupAccessibility()
        finishChange(heightBefore: before)
    }

    func setStatus(_ text: String?) {
        let before = preferredHeight
        statusText = text
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        finishChange(heightBefore: before)
    }

    /// Chips shown now, oldest first: all when expanded, else the newest `collapsedLimit`.
    var visibleEntries: [QueuedMessage] {
        isExpanded || entries.count <= Self.collapsedLimit ? entries : Array(entries.suffix(Self.collapsedLimit))
    }

    var hiddenCount: Int { entries.count - visibleEntries.count }

    /// The height this area wants, never above `maxHeight`; zero with nothing to show.
    var preferredHeight: CGFloat {
        guard !entries.isEmpty || statusText != nil else { return 0 }
        let want = naturalHeight
        return min(want, max(maxHeight, 0))
    }

    @objc func toggleExpanded() {
        let before = preferredHeight
        isExpanded.toggle()
        rebuildChips()
        finishChange(heightBefore: before)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        let pad: CGFloat = 12
        var y = Self.verticalPadding
        if !entries.isEmpty {
            let more = showMoreButton.isHidden ? 0 : showMoreButton.intrinsicContentSize.width + 4
            headerLabel.frame = NSRect(x: pad, y: y + 3, width: max(0, width - 2 * pad - more), height: 16)
            showMoreButton.frame = NSRect(x: width - pad - more + 4, y: y, width: max(0, more - 4), height: 22)
            y += Self.headerHeight
        }
        let statusRow = statusText == nil ? 0 : Self.statusHeight
        let listHeight = max(0, bounds.height - y - Self.verticalPadding - statusRow)
        scroll.frame = NSRect(x: 0, y: y, width: width, height: listHeight)
        scroll.isHidden = entries.isEmpty
        let rowCount = CGFloat(chips.count)
        let docHeight = rowCount * QueuedChipView.height + max(0, rowCount - 1) * Self.rowGap
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(docHeight, listHeight))
        for (i, chip) in chips.enumerated() {
            chip.frame = NSRect(x: pad, y: CGFloat(i) * (QueuedChipView.height + Self.rowGap),
                                width: max(0, width - 2 * pad), height: QueuedChipView.height)
        }
        statusLabel.frame = NSRect(x: pad, y: bounds.height - Self.verticalPadding - statusRow + 2,
                                   width: max(0, width - 2 * pad), height: 16)
        if isExpanded, listHeight < docHeight { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, docHeight - listHeight))) }
    }

    // MARK: Private

    /// The height with every row at its own size, before `maxHeight`.
    private var naturalHeight: CGFloat {
        var h = Self.verticalPadding * 2
        if !entries.isEmpty {
            let rows = CGFloat(visibleEntries.count)
            h += Self.headerHeight + rows * QueuedChipView.height + max(0, rows - 1) * Self.rowGap
        }
        if statusText != nil { h += Self.statusHeight }
        return h
    }

    private func rebuildChips() {
        chips.forEach { $0.removeFromSuperview() }
        let shown = visibleEntries
        let firstNumber = entries.count - shown.count + 1
        chips = shown.enumerated().map { offset, entry in
            let chip = QueuedChipView(entry: entry, index: firstNumber + offset, total: entries.count)
            chip.editEnabled = !composerHasDraft
            chip.permit = { [weak self] in self?.permit($0) ?? .refused(reason: .notAUserEvent) }
            chip.onEdit = { [weak self] in self?.onEdit?($0) }
            chip.onRemove = { [weak self] in self?.onRemove?($0) }
            content.addSubview(chip)
            return chip
        }
        let hidden = hiddenCount
        showMoreButton.isHidden = entries.count <= Self.collapsedLimit
        showMoreButton.title = isExpanded ? "Show fewer" : "Show \(hidden) more"
        showMoreButton.setAccessibilityLabel(isExpanded ? "Show fewer queued messages" : "Show \(hidden) more queued messages")
    }

    private func updateGroupAccessibility() {
        let count = entries.count
        scroll.setAccessibilityElement(true)
        scroll.setAccessibilityRole(.group)
        scroll.setAccessibilityLabel("Queued messages, \(count)")
        setAccessibilityLabel("Queued messages, \(count)")
    }

    private func finishChange(heightBefore: CGFloat) {
        isHidden = preferredHeight == 0
        needsLayout = true
        if preferredHeight != heightBefore { onHeightChange?() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
