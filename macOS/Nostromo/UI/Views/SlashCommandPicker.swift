import AppKit
import NostromoKit

// The slash-command picker: typing `/` at the start of the input lists the session's commands.
//
// `SlashCommandPicker` is the state (what is open, what matches, what is selected) and `SlashCommandPickerView`
// draws it. It is an overlay, not a popover: the text view keeps first responder throughout, so the keys
// (Up, Down, Tab, Return, Esc) reach it through `ChatTextView.keyInterceptor`, and nothing is ever typed into
// the list.

// MARK: - State

final class SlashCommandPicker {

    /// Rows shown at once; the list scrolls past that.
    static let maxVisibleRows = 8

    private(set) var isOpen = false
    private(set) var rows: [SlashCommandEntryWire] = []
    private(set) var selection = 0
    /// The list is the built-in table, not what the session reported.
    private(set) var isFallback = false
    private(set) var query = ""
    /// The text an Esc closed the picker for: it stays closed until the text changes.
    private var dismissedText: String?

    /// The session's commands. Set by the input bar once it is bound to a session.
    var catalog: () -> SlashCommandCatalog = { .fallback }
    /// The picker opened: ask for a fresh list.
    var onOpen: (() -> Void)?
    /// Rows, selection or open state changed.
    var onChange: (() -> Void)?
    /// A line for VoiceOver ("3 commands", "/context, Show current context usage").
    var onAnnounce: ((String) -> Void)?
    /// A row was clicked or completed with the keyboard.
    var onChoose: ((SlashCommandEntryWire) -> Void)?

    var selectedEntry: SlashCommandEntryWire? { rows.indices.contains(selection) ? rows[selection] : nil }

    /// What the typed text says about the picker. `caret` is a UTF-16 offset into `text`.
    func update(text: String, caret: Int) {
        let ns = text as NSString
        let slash: unichar = 0x2F
        guard ns.length > 0, ns.character(at: 0) == slash, caret >= 1, caret <= ns.length else {
            dismissedText = nil
            return close()
        }
        let typed = ns.substring(to: caret)
        guard typed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            dismissedText = nil
            return close()
        }
        if dismissedText == text { return }
        dismissedText = nil
        let newQuery = String(typed.dropFirst())
        let wasOpen = isOpen
        let queryChanged = newQuery != query
        query = newQuery
        isOpen = true
        reload(resetSelection: !wasOpen || queryChanged)
        if !wasOpen {
            onOpen?()
            onAnnounce?(rows.count == 1 ? "1 command" : "\(rows.count) commands")
        }
    }

    /// The daemon's list changed while the picker is open.
    func refresh() {
        guard isOpen else { return }
        reload(resetSelection: false)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        rows = []
        selection = 0
        query = ""
        onChange?()
    }

    /// Esc: closed, and it stays closed for this text.
    func dismiss(text: String) {
        dismissedText = text
        close()
    }

    /// Up or Down, wrapping.
    func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selection = ((selection + delta) % rows.count + rows.count) % rows.count
        onChange?()
        if let entry = selectedEntry { onAnnounce?(Self.accessibilityLabel(for: entry)) }
    }

    /// `text` with its first token replaced by the selected command and a space; nil with no selection.
    func completion(of text: String) -> (text: String, caret: Int)? {
        guard let entry = selectedEntry else { return nil }
        return Self.complete(text, with: entry)
    }

    static func complete(_ text: String, with entry: SlashCommandEntryWire) -> (text: String, caret: Int) {
        let ns = text as NSString
        var end = 0
        while end < ns.length, !isWhitespace(ns.character(at: end)) { end += 1 }
        let rest = ns.substring(from: end)
        let head = "/\(entry.name)"
        let joined = head + (rest.first?.isWhitespace == true ? rest : " " + rest)
        return (joined, (head as NSString).length + 1)
    }

    static func accessibilityLabel(for entry: SlashCommandEntryWire) -> String {
        if let description = entry.description, !description.isEmpty { return "/\(entry.name), \(description)" }
        return "/\(entry.name)"
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func reload(resetSelection: Bool) {
        let catalog = catalog()
        isFallback = catalog.isFallback
        rows = SlashCommandFilter.rank(query: query, in: catalog.entries)
        if resetSelection || !rows.indices.contains(selection) { selection = 0 }
        onChange?()
    }
}

// MARK: - View

final class SlashCommandPickerView: NSView {

    static let rowHeight: CGFloat = 26
    static let footerHeight: CGFloat = 24
    static let verticalInset: CGFloat = 4
    static let footerText = "Skills and custom commands appear after this session's first message."
    static let emptyText = "No matching commands"

    private let picker: SlashCommandPicker
    private var rowViews: [SlashCommandRowView] = []
    private let footer = NSTextField(labelWithString: SlashCommandPickerView.footerText)
    private let emptyLabel = NSTextField(labelWithString: SlashCommandPickerView.emptyText)
    /// Index of the first visible row.
    private(set) var firstRow = 0

    override var isFlipped: Bool { true }

    init(picker: SlashCommandPicker) {
        self.picker = picker
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor
        layer?.borderColor = Theme.borderInactive.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        for label in [footer, emptyLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = Theme.fgMuted
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild what is drawn from the picker's state; call after the picker's `onChange`.
    func reload() {
        isHidden = !picker.isOpen
        let visible = min(picker.rows.count, SlashCommandPicker.maxVisibleRows)
        // Keep the selection on screen.
        if picker.selection < firstRow { firstRow = picker.selection }
        if picker.selection >= firstRow + visible { firstRow = picker.selection - visible + 1 }
        firstRow = max(0, min(firstRow, max(0, picker.rows.count - visible)))
        while rowViews.count < visible {
            let row = SlashCommandRowView()
            row.onClick = { [weak self] entry in self?.picker.onChoose?(entry) }
            addSubview(row)
            rowViews.append(row)
        }
        for (i, row) in rowViews.enumerated() {
            if i < visible {
                let index = firstRow + i
                row.configure(entry: picker.rows[index], selected: index == picker.selection)
                row.isHidden = false
            } else {
                row.isHidden = true
            }
        }
        emptyLabel.isHidden = !picker.rows.isEmpty
        footer.isHidden = !picker.isFallback
        invalidateIntrinsicContentSize()
        needsLayout = true
        setAccessibilityChildren(rowViews.filter { !$0.isHidden })
    }

    /// The height the picker wants for its rows (and the footer).
    var preferredHeight: CGFloat {
        let rows = max(1, min(picker.rows.count, SlashCommandPicker.maxVisibleRows))
        return Self.verticalInset * 2 + CGFloat(rows) * Self.rowHeight + (picker.isFallback ? Self.footerHeight : 0)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight) }

    override func layout() {
        super.layout()
        var y = Self.verticalInset
        for row in rowViews where !row.isHidden {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
            y += Self.rowHeight
        }
        if !emptyLabel.isHidden {
            emptyLabel.frame = NSRect(x: 12, y: Self.verticalInset + 4, width: max(bounds.width - 24, 0), height: 16)
        }
        if !footer.isHidden {
            footer.frame = NSRect(x: 12, y: bounds.height - Self.footerHeight + 4,
                                  width: max(bounds.width - 24, 0), height: 16)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard picker.rows.count > SlashCommandPicker.maxVisibleRows else { return super.scrollWheel(with: event) }
        let step = event.scrollingDeltaY > 0 ? -1 : (event.scrollingDeltaY < 0 ? 1 : 0)
        let visible = SlashCommandPicker.maxVisibleRows
        firstRow = max(0, min(firstRow + step, picker.rows.count - visible))
        reload()
    }

    /// The rows now on screen.
    var visibleRows: [SlashCommandRowView] { rowViews.filter { !$0.isHidden } }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { !isHidden }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? {
        let n = picker.rows.count
        return "Slash commands, \(n) \(n == 1 ? "command" : "commands")"
    }
    override func accessibilityChildren() -> [Any]? { visibleRows }
}

// MARK: - Row

final class SlashCommandRowView: NSView {

    static let horizontalInset: CGFloat = 12
    static let columnGap: CGFloat = 8

    private let nameLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(labelWithString: "")
    private(set) var entry: SlashCommandEntryWire?
    private(set) var isSelected = false
    var onClick: ((SlashCommandEntryWire) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = Theme.firaCode(size: 12)
        nameLabel.textColor = Theme.fg
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = Theme.fgMuted
        descriptionLabel.font = .systemFont(ofSize: 11)
        descriptionLabel.textColor = Theme.fgMuted
        for label in [nameLabel, hintLabel, descriptionLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.isSelectable = false
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(entry: SlashCommandEntryWire, selected: Bool) {
        self.entry = entry
        isSelected = selected
        nameLabel.stringValue = "/\(entry.name)"
        hintLabel.stringValue = entry.argumentHint ?? ""
        descriptionLabel.stringValue = entry.description ?? ""
        needsLayout = true
        needsDisplay = true
        setAccessibilityLabel(SlashCommandPicker.accessibilityLabel(for: entry))
    }

    /// The text drawn for each column, for tests.
    var shownName: String { nameLabel.stringValue }
    var shownDescription: String { descriptionLabel.stringValue }
    var shownHint: String { hintLabel.stringValue }
    var descriptionFrame: NSRect { descriptionLabel.frame }
    var nameFrame: NSRect { nameLabel.frame }

    override func layout() {
        super.layout()
        let inset = Self.horizontalInset
        let available = max(bounds.width - 2 * inset, 0)
        let lineY = (bounds.height - 16) / 2
        var x = inset
        var remaining = available

        let nameWidth = min(ceil(nameLabel.intrinsicContentSize.width), remaining)
        nameLabel.frame = NSRect(x: x, y: lineY, width: nameWidth, height: 16)
        x += nameWidth + Self.columnGap
        remaining -= nameWidth + Self.columnGap

        hintLabel.isHidden = hintLabel.stringValue.isEmpty || remaining < 40
        if !hintLabel.isHidden {
            // The hint never takes more than a third of what is left: the description is the point.
            let hintWidth = min(ceil(hintLabel.intrinsicContentSize.width), remaining / 3)
            hintLabel.frame = NSRect(x: x, y: lineY, width: hintWidth, height: 16)
            x += hintWidth + Self.columnGap
            remaining -= hintWidth + Self.columnGap
        }
        descriptionLabel.isHidden = descriptionLabel.stringValue.isEmpty || remaining < 24
        descriptionLabel.frame = NSRect(x: x, y: lineY, width: max(remaining, 0), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor(white: 1, alpha: 0.09).setFill()
        NSBezierPath(rect: bounds.insetBy(dx: 4, dy: 1)).fill()
        Theme.selectionBackground.setFill()
        NSBezierPath(rect: NSRect(x: 4, y: 3, width: 2, height: bounds.height - 6)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if let entry { onClick?(entry) }
    }

    // The text view keeps first responder: a click here is never a focus change.
    override var acceptsFirstResponder: Bool { false }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .row }
    override func isAccessibilitySelected() -> Bool { isSelected }
    override func accessibilityPerformPress() -> Bool {
        if let entry { onClick?(entry) }
        return true
    }
    override func accessibilityChildren() -> [Any]? { [] }
}
