import AppKit

/// A small clickable text (the drawer's chevron and menu, a row's Show all). No target-action and no key
/// equivalent: a click calls `onClick`; VoiceOver's press does the same.
final class StagingClickableLabel: NSView {
    var onClick: (() -> Void)?
    let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = Theme.statusFont
        label.textColor = Theme.followBlue
        label.lineBreakMode = .byClipping
        label.isSelectable = false
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("StagingClickableLabel is created in code") }

    /// One button: its own text field is not a second element.
    override func accessibilityChildren() -> [Any]? { [] }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            setAccessibilityLabel(newValue)
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: min(size.width, bounds.width), height: size.height)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// One staged command. Draws only what `StagingRowModel` says: the number, the state glyph, the command
/// exactly as staged (monospaced, left to right, wrapped at any character, at most 3 lines until Show all),
/// its age, then the app's labels, the state line and the agent's note (labelled unverified, at most 2
/// lines). The agent's text is never anywhere else. Its text is not selectable; Copy is in the context menu.
///
/// A click inserts only through `StagingInsertController`: the mouse-down takes a snapshot, the mouse-up
/// (a person's, inside the row) inserts it. A double-click's second click, a right or control click, and
/// everything else insert nothing. The row clips to its own bounds, so stacked combining marks cannot
/// draw over a neighbour.
final class StagingRowView: NSView {

    static let collapsedLines = 3
    static let noteLines = 2
    static let horizontalPadding: CGFloat = 8
    static let numberWidth: CGFloat = 22
    static let glyphWidth: CGFloat = 14
    static let ageWidth: CGFloat = 34
    static let verticalPadding: CGFloat = 5

    private(set) var model: StagingRowModel
    /// Reasons that apply to every row are shown once under the header, not on each row.
    private(set) var showsReason = true
    private(set) var canModify = true
    var isSelected = false { didSet { if isSelected != oldValue { updateSelection() } } }
    private(set) var isExpanded = false
    /// What the click found; the drawer shows a refusal.
    var onResult: ((StagingInsertResult) -> Void)?
    /// Show all changed the row's height.
    var onNeedsLayout: (() -> Void)?
    weak var controller: StagingInsertController?

    private let numberLabel = NSTextField(labelWithString: "")
    private let glyphLabel = NSTextField(labelWithString: "")
    private let commandLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private let labelsLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let showAll = StagingClickableLabel()
    /// A left click went down on this row (nil: none, or one that can never insert).
    private var pending: StagingSnapshot?
    private var cache: (width: CGFloat, layout: Layout)?

    private struct Layout {
        var height: CGFloat
        var number, glyph, command, age, labels, state, note, showAll: NSRect
        var truncatedCommand: Bool
    }

    init(model: StagingRowModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        for label in [numberLabel, glyphLabel, commandLabel, ageLabel, labelsLabel, stateLabel, noteLabel] {
            label.isSelectable = false
            label.isEditable = false
            label.lineBreakMode = .byWordWrapping
            addSubview(label)
        }
        commandLabel.lineBreakMode = .byCharWrapping
        // Stacked combining marks can draw far outside their line (macOS 14+ no longer clips a text field
        // to its bounds): the command's own label clips, so the lines below it stay readable.
        commandLabel.clipsToBounds = true
        for label in [numberLabel, glyphLabel, ageLabel, labelsLabel, stateLabel, noteLabel] { label.font = Theme.statusFont }
        showAll.title = "Show all"
        showAll.onClick = { [weak self] in
            guard let self else { return }
            self.isExpanded.toggle()
            self.cache = nil
            self.render()
            self.needsLayout = true
            self.onNeedsLayout?()
        }
        addSubview(showAll)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("staging-row")
        render()
    }

    required init?(coder: NSCoder) { fatalError("StagingRowView is created in code") }

    // MARK: - Content

    /// Redraws only when something it shows changed; returns whether it did.
    @discardableResult
    func apply(_ model: StagingRowModel, showsReason: Bool, canModify: Bool) -> Bool {
        guard model != self.model || showsReason != self.showsReason || canModify != self.canModify else { return false }
        self.model = model
        self.showsReason = showsReason
        self.canModify = canModify
        cache = nil
        render()
        needsLayout = true
        return true
    }

    /// Only the ages moved (the clock ticked): updates those texts in place. The row is not laid out again
    /// unless the state line it shows now needs a different height.
    func updateAges(_ model: StagingRowModel) {
        guard model != self.model else { return }
        let heightBefore = cache?.layout.height
        self.model = model
        ageLabel.stringValue = model.age
        ageLabel.textColor = model.ageIsStale ? Theme.amber : Theme.fgMuted
        if let line = stateLine, stateLabel.stringValue != line {
            stateLabel.stringValue = line
            cache = nil
            if let heightBefore, heightBefore != layoutInfo(width: bounds.width).height {
                needsLayout = true
                onNeedsLayout?()
            }
        }
        setAccessibilityLabel(model.accessibilityLabel)
    }

    private func render() {
        numberLabel.stringValue = "\(model.number)"
        numberLabel.textColor = Theme.fgMuted
        numberLabel.alignment = .right
        glyphLabel.stringValue = model.glyph
        glyphLabel.alignment = .center
        switch model.state {
        case .ready: glyphLabel.textColor = Theme.followBlue
        case .inserted: glyphLabel.textColor = Theme.sage
        case .disabled: glyphLabel.textColor = Theme.fgMuted
        }
        commandLabel.attributedStringValue = Self.commandText(model.command, dimmed: model.disabledReason != nil)
        commandLabel.maximumNumberOfLines = isExpanded ? 0 : Self.collapsedLines
        ageLabel.stringValue = model.age
        ageLabel.textColor = model.ageIsStale ? Theme.amber : Theme.fgMuted
        ageLabel.alignment = .right
        labelsLabel.stringValue = model.labels.joined(separator: "\n")
        labelsLabel.textColor = Theme.amber
        labelsLabel.isHidden = model.labels.isEmpty
        stateLabel.stringValue = stateLine ?? ""
        stateLabel.textColor = Theme.fgMuted
        stateLabel.isHidden = stateLine == nil
        noteLabel.stringValue = model.noteText ?? ""
        noteLabel.textColor = Theme.fgMuted
        noteLabel.maximumNumberOfLines = Self.noteLines
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = model.noteText == nil
        showAll.title = isExpanded ? "Show less" : "Show all"
        setAccessibilityLabel(model.accessibilityLabel)
        toolTip = nil
    }

    /// The second line under the command: `inserted 2m ago`, or this row's own reason.
    private var stateLine: String? {
        switch model.state {
        case .ready: return nil
        case .inserted(let ago): return ago
        case .disabled(let reason): return showsReason || !reason.appliesToEveryRow ? reason.text : nil
        }
    }

    /// The command exactly as staged: monospaced, forced left to right (Hebrew or Arabic letters must not
    /// reorder a command line), wrapped at any character.
    static func commandText(_ command: String, dimmed: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.baseWritingDirection = .leftToRight
        style.lineBreakMode = .byCharWrapping
        // Left-to-right OVERRIDE (what U+202D does, as an attribute so the command's own text is untouched):
        // the direction in the low bits, NSTextWritingDirectionOverride (1 << 1) on top.
        let override = NSNumber(value: NSWritingDirection.leftToRight.rawValue | (1 << 1))
        return NSAttributedString(string: command, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: dimmed ? Theme.fgMuted : Theme.fg,
            .paragraphStyle: style,
            .writingDirection: [override],
        ])
    }

    // MARK: - Layout

    /// The height the row needs at `width` (cached by width until the content changes).
    func height(forWidth width: CGFloat) -> CGFloat {
        layoutInfo(width: width).height
    }

    override func layout() {
        super.layout()
        let info = layoutInfo(width: bounds.width)
        numberLabel.frame = info.number
        glyphLabel.frame = info.glyph
        commandLabel.frame = info.command
        ageLabel.frame = info.age
        labelsLabel.frame = info.labels
        stateLabel.frame = info.state
        noteLabel.frame = info.note
        showAll.frame = info.showAll
        showAll.isHidden = !info.truncatedCommand
    }

    private func layoutInfo(width: CGFloat) -> Layout {
        if let cache, cache.width == width { return cache.layout }
        let pad = Self.horizontalPadding
        let textX = pad + Self.numberWidth + Self.glyphWidth + 4
        let textWidth = max(20, width - textX - Self.ageWidth - pad)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)))
        // The command is measured by the cell it is drawn in, so its internal padding (which narrows the
        // wrap width and adds to the height) is counted: a command that draws as 4 lines is never taken
        // for 3, which would cut the last line with no Show all.
        let chrome = max(0, Self.cellHeight(of: Self.commandText("X", dimmed: false), width: textWidth, wrapping: .byCharWrapping) - lineHeight)
        let fullHeight = Self.cellHeight(of: commandLabel.attributedStringValue, width: textWidth, wrapping: .byCharWrapping)
        let fullLines = max(1, Int(((fullHeight - chrome) / lineHeight).rounded()))
        let truncated = !isExpanded && fullLines > Self.collapsedLines
        let shownLines = isExpanded ? fullLines : min(fullLines, Self.collapsedLines)
        var y = Self.verticalPadding
        let commandRect = NSRect(x: textX, y: y, width: textWidth, height: CGFloat(shownLines) * lineHeight + chrome)
        y = commandRect.maxY
        var showAllRect = NSRect.zero
        if fullLines > Self.collapsedLines {
            showAllRect = NSRect(x: textX, y: y + 1, width: min(80, textWidth), height: 14)
            y = showAllRect.maxY
        }
        func secondary(_ label: NSTextField, lines: Int) -> NSRect {
            guard !label.isHidden else { return .zero }
            // The label's own cell measures it, so its internal padding is counted here too.
            let attributed = NSAttributedString(string: label.stringValue, attributes: [.font: Theme.statusFont])
            let full = Self.cellHeight(of: attributed, width: textWidth)
            let one = Self.cellHeight(of: NSAttributedString(string: "X", attributes: [.font: Theme.statusFont]), width: textWidth)
            let chrome = max(0, one - ceil(NSLayoutManager().defaultLineHeight(for: Theme.statusFont)))
            let h = lines == 0 ? full : min(full, (one - chrome) * CGFloat(lines) + chrome)
            let rect = NSRect(x: textX, y: y + 1, width: textWidth, height: ceil(h))
            y = rect.maxY
            return rect
        }
        let labelsRect = secondary(labelsLabel, lines: 0)
        let stateRect = secondary(stateLabel, lines: 2)
        let noteRect = secondary(noteLabel, lines: Self.noteLines)
        let height = y + Self.verticalPadding
        let info = Layout(
            height: ceil(height),
            number: NSRect(x: pad, y: Self.verticalPadding, width: Self.numberWidth, height: lineHeight),
            glyph: NSRect(x: pad + Self.numberWidth, y: Self.verticalPadding, width: Self.glyphWidth, height: lineHeight),
            command: commandRect,
            age: NSRect(x: width - pad - Self.ageWidth, y: Self.verticalPadding, width: Self.ageWidth, height: lineHeight),
            labels: labelsRect, state: stateRect, note: noteRect, showAll: showAllRect, truncatedCommand: fullLines > Self.collapsedLines)
        cache = (width, info)
        return info
    }

    /// The height a text field's own cell needs for `text` at `width` when it wraps by `wrapping` and has
    /// no line limit: what it draws, internal padding included.
    static func cellHeight(of text: NSAttributedString, width: CGFloat, wrapping: NSLineBreakMode = .byWordWrapping) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = wrapping       // a label clips by default, which would measure one line
        field.maximumNumberOfLines = 0
        field.attributedStringValue = text
        guard let cell = field.cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.borderInactive.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    private func updateSelection() {
        layer?.backgroundColor = isSelected ? NSColor(white: 1, alpha: 0.08).cgColor : nil
    }

    // MARK: - Mouse (the only insert paths: a click's up after its down, Space, VoiceOver's press)

    /// Everything inside the row is the row's: its labels never take a click or start a text selection.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        if !showAll.isHidden, showAll.frame.contains(convert(point, from: superview)) { return showAll }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        pending = nil
        guard event.clickCount == 1, !event.modifierFlags.contains(.control) else {
            controller?.refuseClick()
            return
        }
        pending = controller?.snapshot(entryId: model.entryId)
    }

    override func mouseUp(with event: NSEvent) {
        let snapshot = pending
        pending = nil
        guard let snapshot, bounds.contains(convert(event.locationInWindow, from: nil)),
              let result = controller?.insert(snapshot, event: event, control: self) else { return }
        onResult?(result)
    }

    override func rightMouseDown(with event: NSEvent) {
        pending = nil
        controller?.refuseClick()
        super.rightMouseDown(with: event)
    }

    /// Space on the selected row: the snapshot is taken now, at the key-down.
    @discardableResult
    func activate(with event: NSEvent?) -> StagingInsertResult? {
        guard let controller, let snapshot = controller.snapshot(entryId: model.entryId) else { return nil }
        let result = controller.insert(snapshot, event: event, control: self)
        onResult?(result)
        return result
    }

    override func accessibilityPerformPress() -> Bool {
        activate(with: NSApp.currentEvent) != nil
    }

    /// One VoiceOver button per row, spoken from the model's label: the command, note and state fields are
    /// not elements of their own. Show all (when the row shows it) is the only child.
    override func accessibilityChildren() -> [Any]? {
        layoutInfo(width: bounds.width).truncatedCommand ? [showAll] : []
    }

    // MARK: - Context menu: Copy and Remove (each is gated inside `StagingInsertController`)

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Staged command")
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(copyStagedCommand(_:)), keyEquivalent: "")
        copy.target = self
        // Copy works on a row that cannot be placed, but not within the reading delay of a change.
        copy.isEnabled = controller?.isReadable(entryId: model.entryId) ?? false
        let remove = NSMenuItem(title: "Remove", action: #selector(removeStagedCommand(_:)), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = canModify
        menu.addItem(copy)
        menu.addItem(remove)
        return menu
    }

    @objc private func copyStagedCommand(_ sender: NSMenuItem) {
        controller?.copy(entryId: model.entryId, event: NSApp.currentEvent, control: self)
    }

    @objc private func removeStagedCommand(_ sender: NSMenuItem) {
        controller?.remove(entryId: model.entryId, event: NSApp.currentEvent, control: self)
    }
}
