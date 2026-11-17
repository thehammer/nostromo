import AppKit
import NostromoKit

/// The tracker pane's explicit colours (design contract §10: Dark Aqua pinned, never a semantic or
/// catalogue colour, so the measured contrast cannot depend on the system appearance).
enum TrackerTheme {
    static let background = Theme.bg
    static let text = Theme.fg
    static let muted = Theme.fgMuted
    /// Metadata on a `needs-you` row: its fill (and a chip's on top) is lighter than the pane's
    /// background, so plain muted grey would fall under 4.5:1 there.
    static let mutedOnFill = Theme.foldedProse
    /// The `needs-you` row fill; item text stays ≥ 7:1 and muted metadata ≥ 4.5:1 on it.
    static let needsYouFill = Theme.attention.withAlphaComponent(0.14)
    /// The left edge of an item touching a hazardous environment, and its badge text.
    static let hazard = Theme.foldFailure
    static let hazardFill = Theme.foldFailure.withAlphaComponent(0.18)
    static let badgeFill = NSColor(white: 1, alpha: 0.08)
    static let bannerFill = Theme.amber.withAlphaComponent(0.18)
    static let stripFill = Theme.attention.withAlphaComponent(0.10)
    /// The ≤ 1 s highlight on a changed row.
    static let changeHighlight = Theme.cornflower.withAlphaComponent(0.14)

    static func markColor(_ status: TrackerStatusWire) -> NSColor {
        switch status {
        case .todo, .unknown: return Theme.fgMuted
        case .inProgress: return Theme.cornflower
        case .blocked: return Theme.amber
        case .needsYou: return Theme.attention
        case .done: return Theme.sage
        }
    }

    static let textFont = NSFont.systemFont(ofSize: 13)
    static let metaFont = NSFont.systemFont(ofSize: 11)
    static let sectionFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// Digits of equal width, so "4 m" → "5 m" never changes the label's ink width much.
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
}

/// One row of the tracker's scrolling content: a section heading, an item, a Done group, the Log, a
/// prose block, or a stub for a held change. Laid out by frame (flipped, y grows down) at the width
/// the pane gives it; `height(forWidth:)` is what the pane stacks rows with.
///
/// Text is in non-editable, selectable `TrackerTextView`s that wrap at the row's width. An item's
/// relative time sits in a fixed-width right-aligned label, so a clock tick changes only that label
/// and never the row's layout.
final class TrackerRowView: NSView {
    override var isFlipped: Bool { true }

    static let hPad: CGFloat = 12
    static let vPad: CGFloat = 4
    static let markWidth: CGFloat = 18
    /// Reserved on every item row (foldable or not) so titles align.
    static let foldColumnWidth: CGFloat = 16
    /// The chevron itself: it sits in the fold column, clear of the status mark and of the title.
    static let foldButtonSize = NSSize(width: foldColumnWidth, height: 20)
    static let timeWidth: CGFloat = 44
    static let gap: CGFloat = 6
    /// The owner chip never grows past this (a 32-character owner is ~190 pt at 11 pt); longer owners
    /// truncate with a tail ellipsis and show in full as the chip's tooltip.
    static let maxOwnerChipWidth: CGFloat = 80
    /// The env badge's cap (a short word such as PROD or STAGING; longer ones truncate).
    static let envBadgeMaxWidth: CGFloat = 48
    static let chipHeight: CGFloat = 15

    /// The least width an item's text keeps beside its marks: when the owner chip and env badge would
    /// leave less than this on the first line they move to a line below the text instead.
    static func minimumTextWidth(forRowWidth width: CGFloat) -> CGFloat {
        max(120, width * 0.4)
    }

    /// With editing, the tick owns the row's left edge up to 4 pt short of the fold column, so it and the
    /// disclosure are both at least 20 pt wide without either reaching the title.
    static let tickRect = NSRect(x: 0, y: 0, width: hPad + markWidth - 4, height: vPad + foldButtonSize.height)
    /// With editing, the disclosure starts where the tick ends and stops exactly where the title starts, so
    /// no click on the title can toggle the fold.
    static let disclosureRect = NSRect(x: tickRect.maxX, y: 0, width: textX - tickRect.maxX,
                                       height: vPad + foldButtonSize.height)

    /// Where a click toggles the item's fold (when it has one). Without a tick: the status-mark column
    /// and the fold column on the item's first line, ending exactly where the title starts. With a tick:
    /// the disclosure's own area.
    var foldHitRect: NSRect {
        if tickButton != nil { return Self.disclosureRect }
        return NSRect(x: Self.hPad, y: 0, width: Self.textX - Self.hPad, height: Self.vPad + Self.foldButtonSize.height)
    }

    /// Where an item's title (and the rest of its content) starts.
    static let textX: CGFloat = hPad + markWidth + foldColumnWidth

    private(set) var row: TrackerRow
    /// A stub keeps at least the height of the row it replaced, so holding a change never moves
    /// what is below it.
    var minimumHeight: CGFloat = 0 {
        didSet { if minimumHeight != oldValue { measured = nil } }
    }

    var onToggleDone: ((String) -> Void)?
    var onToggleNote: ((String) -> Void)?
    var onToggleLog: (() -> Void)?
    /// Copy as Markdown on this row (an item or a section).
    var onCopyMarkdown: ((TrackerRow) -> Void)?
    /// A link chip of the item (its id, what the chip does) was clicked.
    var onOpenLink: ((String, TrackerLinkAction) -> Void)?

    /// The daemon takes pane edits: the tick, the status menu, the editors and the actions line exist.
    /// Without it the row is the read-only row.
    var editingEnabled = false {
        didSet { if editingEnabled != oldValue { build() } }
    }
    /// The tick was pressed (item id).
    var onTick: ((String) -> Void)?
    /// A status was chosen (item id, wire status).
    var onSetStatus: ((String, String) -> Void)?
    /// An editor was asked for (item id, which).
    var onBeginEdit: ((String, TrackerEditKind) -> Void)?
    /// An editor's text was committed by Return, ⌘Return or losing focus (item id, which, the text).
    var onCommitEdit: ((String, TrackerEditKind, String) -> Void)?
    /// Esc in an editor.
    var onCancelEdit: ((String, TrackerEditKind) -> Void)?
    /// The conflict mark or the sensitive badge asked for its popover (item id, anchor, from the keyboard).
    var onShowConflict: ((String, NSView, Bool) -> Void)?
    var onReviewSensitive: ((String, NSView, Bool) -> Void)?
    /// The details editor's height changed: the pane lays the rows out again.
    var onEditorResized: (() -> Void)?

    /// The ≤ 1 s change highlight is showing.
    private(set) var isHighlighted = false

    // Pieces, per kind.
    private(set) var textViews: [TrackerTextView] = []
    private var markLabel: NSTextField?
    /// The status mark as a button (editing enabled, item tickable).
    private(set) var tickButton: TrackerTickButton?
    private(set) var conflictButton: TrackerChipButton?
    private(set) var sensitiveButton: TrackerChipButton?
    private(set) var editTitleButton: TrackerChipButton?
    private(set) var editDetailsButton: TrackerChipButton?
    private(set) var statusPopUp: NSPopUpButton?
    /// The inline editors; they survive a rebuild of the row.
    private(set) var titleEditor: TrackerTitleEditor?
    private(set) var detailsEditor: TrackerDetailsEditor?
    /// A bound item's source-owned first line, shown read-only above the details editor.
    private var boundLine: NSTextField?
    private(set) var timeLabel: NSTextField?
    private(set) var badges: [NSTextField] = []
    private var ownerChip: NSTextField?
    /// "older conflicts dropped": a cap dropped something the pane can't show.
    private var droppedMark: NSTextField?
    private var boundLineText: String?
    private var mainText: TrackerTextView?
    /// The text after the title, shown under the fold.
    private var leadText: TrackerTextView?
    /// The row's prose (a prose row, or an expanded note).
    private(set) var proseView: TrackerProseView?
    /// The item's link chips, in order.
    private(set) var linkChips: [TrackerLinkChip] = []
    /// The quiet "as of 10:42" of a badly stale bound item (nil unless shown).
    private(set) var staleFootnote: NSTextField?
    /// The chips' line exists (links, or a bound item): its height is reserved whether or not the
    /// footnote shows, so a source going stale never shifts a row.
    private var hasChipLine = false
    private var disclosure: NSButton?
    /// The item's fold control (nil on a row with nothing under the fold).
    private(set) var disclosureButton: NSButton?
    private var hazardEdge: NSView?
    private let highlightLayer = CALayer()

    private var measured: (width: CGFloat, height: CGFloat)?

    init(row: TrackerRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        highlightLayer.backgroundColor = TrackerTheme.changeHighlight.cgColor
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Content

    /// Show `row`. A change of relative time alone updates the time label in place.
    func apply(_ row: TrackerRow) {
        let old = self.row
        self.row = row
        if row.differsOnlyInTime(from: old), let item = row.item, let timeLabel {
            timeLabel.stringValue = item.relativeTime
            return
        }
        build()
    }

    /// Every text the row shows, top to bottom (what `tracker show` and the tests read).
    var visibleText: String {
        var parts: [String] = []
        if let markLabel { parts.append(markLabel.stringValue) }
        if let tickButton { parts.append(tickButton.title) }
        parts += textViews.map(\.string).filter { !$0.isEmpty }
        if !linkChips.isEmpty { parts.append(linkChips.map { $0.link.text }.joined(separator: " · ")) }
        if let staleFootnote { parts.append(staleFootnote.stringValue) }
        if let proseView { parts.append(proseView.plainText) }
        parts += badges.map(\.stringValue)
        if let timeLabel, !timeLabel.stringValue.isEmpty { parts.append(timeLabel.stringValue) }
        return parts.joined(separator: " ")
    }

    /// The text view holding a non-empty selection, if any.
    var selectedTextView: TrackerTextView? {
        allTextViews.first { $0.hasSelection }
    }

    var allTextViews: [TrackerTextView] {
        textViews + (proseView?.textViews ?? [])
    }

    var isStrikethrough: Bool {
        guard let mainText, mainText.textStorage?.length ?? 0 > 0 else { return false }
        let value = mainText.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        return (value ?? 0) != 0
    }

    // MARK: - Highlight

    /// Show the change highlight, then clear it within 1 s. Nothing at all with Reduce Motion.
    func flashHighlight(reduceMotion: Bool, schedule: (TimeInterval, @escaping () -> Void) -> Void) {
        guard !reduceMotion else { return }
        isHighlighted = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.opacity = 1
        CATransaction.commit()
        schedule(0.8) { [weak self] in
            guard let self else { return }
            self.isHighlighted = false
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            self.highlightLayer.opacity = 0
            CATransaction.commit()
        }
    }

    // MARK: - Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = menuItems()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }

    /// Everything the context menu offers: the edit items (editing enabled), then Copy as Markdown.
    func menuItems() -> [NSMenuItem] {
        let edits = editMenuItems()
        let copy = copyMenuItems()
        return edits.isEmpty || copy.isEmpty ? edits + copy : edits + [.separator()] + copy
    }

    /// Edit Title, Edit Details, Status ▸ and Show Conflict (an item row, editing enabled).
    func editMenuItems() -> [NSMenuItem] {
        guard editingEnabled, case .item(let item) = row.content else { return [] }
        var items: [NSMenuItem] = []
        for (title, action) in [("Edit Title", #selector(menuEditTitle(_:))), ("Edit Details", #selector(menuEditDetails(_:)))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            items.append(entry)
        }
        if item.isStatusEditable {
            let submenu = NSMenu()
            for (name, wire) in Self.statusChoices {
                let entry = NSMenuItem(title: name, action: #selector(menuSetStatus(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = wire
                entry.state = item.status.wireName == wire ? .on : .off
                submenu.addItem(entry)
            }
            let parent = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            items.append(parent)
        }
        if !item.conflicts.isEmpty {
            let entry = NSMenuItem(title: "Show Conflict", action: #selector(menuShowConflict(_:)), keyEquivalent: "")
            entry.target = self
            items.append(entry)
        }
        return items
    }

    /// "Copy as Markdown" for an item or a section row.
    func copyMenuItems() -> [NSMenuItem] {
        switch row.content {
        case .item, .section:
            let item = NSMenuItem(title: "Copy as Markdown", action: #selector(copyMarkdown(_:)), keyEquivalent: "")
            item.target = self
            return [item]
        default:
            return []
        }
    }

    static let statusChoices: [(name: String, wire: String)] = [
        ("To do", "todo"), ("In progress", "in-progress"), ("Blocked", "blocked"), ("Needs you", "needs-you"), ("Done", "done"),
    ]

    @objc private func menuEditTitle(_ sender: Any?) { beginEditFromUser(.title) }
    @objc private func menuEditDetails(_ sender: Any?) { beginEditFromUser(.details) }
    @objc private func menuSetStatus(_ sender: NSMenuItem) {
        if let item = row.item, let wire = sender.representedObject as? String { onSetStatus?(item.id, wire) }
    }
    @objc private func menuShowConflict(_ sender: Any?) { showConflict(fromKeyboard: false) }

    private func beginEditFromUser(_ kind: TrackerEditKind) {
        if let item = row.item { onBeginEdit?(item.id, kind) }
    }

    func showConflict(fromKeyboard: Bool) {
        guard let item = row.item else { return }
        onShowConflict?(item.id, conflictButton ?? self, fromKeyboard)
    }

    func reviewSensitive(fromKeyboard: Bool) {
        guard let item = row.item else { return }
        onReviewSensitive?(item.id, sensitiveButton ?? self, fromKeyboard)
    }

    @objc func copyMarkdown(_ sender: Any?) {
        onCopyMarkdown?(row)
    }

    // MARK: - Clicks

    /// A Done group is one click target as a whole (its label must not swallow the click).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if case .doneGroup = row.content { return self }
        if tickButton == nil, hit !== disclosureButton, disclosureButton != nil,
           foldHitRect.contains(convert(point, from: superview)) {
            return self
        }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        switch row.content {
        case .doneGroup(let group): onToggleDone?(group.sectionId)
        case .item where tickButton == nil && disclosureButton != nil
            && foldHitRect.contains(convert(event.locationInWindow, from: nil)):
            toggleFold(nil)
        default: super.mouseDown(with: event)
        }
    }

    @objc private func toggleFold(_ sender: Any?) {
        if let item = row.item { onToggleNote?(item.id) }
    }

    @objc private func toggleLog(_ sender: Any?) {
        onToggleLog?()
    }

    // MARK: - Layout

    /// The row's height at `width` (cached until the content or the width changes).
    func height(forWidth width: CGFloat) -> CGFloat {
        if let measured, measured.width == width { return measured.height }
        let height = max(layoutContent(width: width), minimumHeight)
        measured = (width, height)
        return height
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
        if measured?.width != bounds.width { _ = layoutContent(width: bounds.width) }
    }

    /// Positions every piece for `width` and returns the content height.
    @discardableResult
    private func layoutContent(width: CGFloat) -> CGFloat {
        let h = Self.hPad, v = Self.vPad
        switch row.content {
        case .section:
            let countWidth = badges.first.map { ceil($0.intrinsicContentSize.width) } ?? 0
            let textWidth = max(width - h * 2 - countWidth - Self.gap, 1)
            let textHeight = mainText?.height(forWidth: textWidth) ?? 0
            let top: CGFloat = 10
            mainText?.frame = NSRect(x: h, y: top, width: textWidth, height: textHeight)
            if let count = badges.first {
                count.frame = NSRect(x: h + textWidth + Self.gap, y: top + 1, width: countWidth, height: 16)
            }
            return top + max(textHeight, 16) + v

        case .item(let item):
            return layoutItem(item, width: width)

        case .stub:
            let textWidth = max(width - h * 2 - Self.markWidth, 1)
            let textHeight = mainText?.height(forWidth: textWidth) ?? 0
            mainText?.frame = NSRect(x: h + Self.markWidth, y: v, width: textWidth, height: textHeight)
            return v + textHeight + v

        case .doneGroup, .log:
            var y = v + 2
            let textWidth = max(width - h * 2, 1)
            for view in textViews {
                let th = view.height(forWidth: textWidth)
                view.frame = NSRect(x: h, y: y, width: textWidth, height: th)
                y += th + 2
            }
            if let disclosure {
                let size = disclosure.intrinsicContentSize
                disclosure.frame = NSRect(x: h, y: y, width: size.width, height: size.height)
                y += size.height
            }
            return y + v

        case .prose:
            guard let proseView else { return 0 }
            let proseHeight = proseView.layout(width: max(width - h * 2, 1))
            proseView.frame = NSRect(x: h, y: v, width: max(width - h * 2, 1), height: proseHeight)
            return v + proseHeight + v
        }
    }

    private func layoutItem(_ item: TrackerItemRow, width: CGFloat) -> CGFloat {
        let h = Self.hPad, v = Self.vPad
        let textX = Self.textX
        // Right column: the fixed-width time, then the badges if they leave the text its minimum
        // width; otherwise the badges take a line below the text.
        var right = width - h
        timeLabel?.frame = NSRect(x: right - Self.timeWidth, y: v + 1, width: Self.timeWidth, height: 15)
        right -= Self.timeWidth + Self.gap
        let rightViews: [NSView] = [conflictButton, sensitiveButton].compactMap { $0 } + badges
        let widths = rightViews.map { badgeWidth($0) }
        let badgesWidth = widths.reduce(0) { $0 + $1 + 4 }
        let minimumText = Self.minimumTextWidth(forRowWidth: width)
        let textWidthAlone = max(right - Self.gap - textX, 1)
        let stacked = !rightViews.isEmpty && textWidthAlone - badgesWidth < minimumText
        var textWidth = textWidthAlone
        if !stacked {
            for (badge, w) in zip(rightViews, widths).reversed() {
                badge.frame = NSRect(x: right - w, y: v + 1, width: w, height: Self.chipHeight)
                right -= w + 4
            }
            textWidth = max(right - Self.gap - textX, 1)
        }
        markLabel?.frame = NSRect(x: h, y: v, width: Self.markWidth, height: 17)
        tickButton?.frame = Self.tickRect
        var y = v
        let mainHeight = mainText?.height(forWidth: textWidth) ?? 0
        mainText?.frame = NSRect(x: textX, y: y, width: textWidth, height: mainHeight)
        // The title editor sits in exactly the title's frame (the row's height never changes).
        mainText?.isHidden = titleEditor != nil
        titleEditor?.frame = NSRect(x: textX, y: y, width: textWidth, height: max(mainHeight, 17))
        y += max(mainHeight, 17)
        if stacked {
            // The chips' own line, under the text, inside the row.
            y += 2
            var x = textX
            let limit = max(width - h, textX)
            for (badge, w) in zip(rightViews, widths) {
                let fitted = min(w, max(limit - x, 1))
                badge.frame = NSRect(x: x, y: y, width: fitted, height: Self.chipHeight)
                x += fitted + 4
            }
            y += Self.chipHeight
        }

        let blockWidth = max(width - h - textX, 1)
        if let boundLine {
            y += 2
            let bh = ceil(boundLine.sizeThatFits(NSSize(width: blockWidth, height: .greatestFiniteMagnitude)).height)
            boundLine.frame = NSRect(x: textX, y: y, width: blockWidth, height: bh)
            y += bh
        }
        if let detailsEditor {
            y += 2
            let eh = detailsEditor.height(forWidth: blockWidth)
            detailsEditor.frame = NSRect(x: textX, y: y, width: blockWidth, height: eh)
            y += eh
        }
        if let leadText {
            y += 2
            let lh = leadText.height(forWidth: blockWidth)
            leadText.frame = NSRect(x: textX, y: y, width: blockWidth, height: lh)
            y += lh
        }
        if tickButton != nil {
            disclosureButton?.frame = Self.disclosureRect
        } else {
            disclosureButton?.frame = NSRect(x: h + Self.markWidth, y: v - 1,
                                             width: Self.foldButtonSize.width, height: Self.foldButtonSize.height)
        }
        if let proseView {
            y += 2
            let ph = proseView.layout(width: blockWidth)
            proseView.frame = NSRect(x: textX, y: y, width: blockWidth, height: ph)
            y += ph
        }
        let actionViews: [NSView] = [editTitleButton, editDetailsButton, statusPopUp].compactMap { $0 }
        if !actionViews.isEmpty {
            y += 2
            var x = textX
            for view in actionViews {
                let w = view === statusPopUp ? Self.statusPopUpWidth : (view as? TrackerChipButton)?.fittingWidth ?? 60
                view.frame = NSRect(x: x, y: y, width: w, height: Self.actionLineHeight)
                x += w + 6
            }
            y += Self.actionLineHeight
        }
        if hasChipLine {
            y += 2
            var right = textX + blockWidth
            if let staleFootnote {
                let w = min(ceil(staleFootnote.intrinsicContentSize.width), blockWidth)
                staleFootnote.frame = NSRect(x: right - w, y: y, width: w, height: Self.chipHeight)
                right -= w + Self.gap
            }
            var x = textX
            for chip in linkChips {
                let w = min(chip.fittingWidth, max(right - x, 0))
                chip.isHidden = w < 24
                chip.frame = NSRect(x: x, y: y, width: w, height: Self.chipHeight)
                x += w + 4
            }
            y += Self.chipHeight
        }
        let height = y + v
        hazardEdge?.frame = NSRect(x: 0, y: 0, width: 3, height: max(height, minimumHeight))
        return height
    }

    /// A badge's width: its text plus padding, never past its cap.
    private func badgeWidth(_ badge: NSView) -> CGFloat {
        if let chip = badge as? TrackerChipButton { return chip.fittingWidth }
        let cap = badge === ownerChip ? Self.maxOwnerChipWidth : Self.envBadgeMaxWidth
        let natural = (badge as? NSTextField).map { ceil($0.intrinsicContentSize.width) + 8 } ?? Self.envBadgeMaxWidth
        return badge === droppedMark ? natural : min(natural, cap)
    }

    static let actionLineHeight: CGFloat = 18
    static let statusPopUpWidth: CGFloat = ceil(("Status ▾" as NSString).size(withAttributes: [.font: TrackerTheme.metaFont]).width) + 16

    // MARK: - Building

    private func build() {
        // The rebuild destroys the row's controls: whoever had keyboard focus on one keeps it on the
        // new one (same item, same role). The inline editors are not rebuilt: they stay in place.
        let focusedRole = focusedControlRole()
        defer {
            if let focusedRole { _ = focusControl(focusedRole) }
        }
        subviews.filter { $0 !== titleEditor && $0 !== detailsEditor }.forEach { $0.removeFromSuperview() }
        textViews = []
        badges = []
        ownerChip = nil
        droppedMark = nil
        boundLine = nil
        tickButton = nil
        conflictButton = nil
        sensitiveButton = nil
        editTitleButton = nil
        editDetailsButton = nil
        statusPopUp = nil
        markLabel = nil
        timeLabel = nil
        mainText = nil
        leadText = nil
        disclosureButton = nil
        proseView = nil
        linkChips = []
        staleFootnote = nil
        hasChipLine = false
        disclosure = nil
        hazardEdge = nil
        measured = nil
        layer?.backgroundColor = nil

        switch row.content {
        case .section(let section):
            mainText = addText(NSAttributedString(string: section.title, attributes: [
                .font: TrackerTheme.sectionFont, .foregroundColor: TrackerTheme.text]))
            badges = [addLabel("\(section.count)", color: TrackerTheme.muted, font: TrackerTheme.metaFont)]

        case .item(let item):
            buildItem(item)

        case .stub(let stub):
            mainText = addText(NSAttributedString(string: stub.text, attributes: [
                .font: NSFontManager.shared.convert(TrackerTheme.metaFont, toHaveTrait: .italicFontMask),
                .foregroundColor: TrackerTheme.muted]))

        case .doneGroup(let group):
            _ = addText(NSAttributedString(string: (group.expanded ? "▾ " : "▸ ") + group.title, attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.muted]))

        case .log(let log):
            _ = addText(NSAttributedString(string: log.title, attributes: [
                .font: TrackerTheme.sectionFont, .foregroundColor: TrackerTheme.text]))
            let body = NSMutableAttributedString()
            for (i, line) in log.lines.enumerated() {
                if i > 0 { body.append(NSAttributedString(string: "\n")) }
                body.append(NSAttributedString(string: line.time + "  ", attributes: [
                    .font: TrackerTheme.timeFont, .foregroundColor: TrackerTheme.muted]))
                body.append(NSAttributedString(string: line.text, attributes: [
                    .font: TrackerTheme.textFont, .foregroundColor: TrackerTheme.text]))
            }
            if body.length > 0 { _ = addText(body) }
            if log.isCollapsible {
                disclosure = addButton(log.expanded ? "Show fewer" : "Show all (\(log.total))", action: #selector(toggleLog(_:)))
            }

        case .prose(let prose):
            let view = TrackerProseView(blocks: TrackerMdAdapter.blocks(prose.blocks))
            addSubview(view)
            proseView = view
        }
        for view in allTextViews { view.extraMenuItems = { [weak self] in self?.menuItems() ?? [] } }
        needsLayout = true
    }

    private func buildItem(_ item: TrackerItemRow) {
        if item.isNeedsYou { layer?.backgroundColor = TrackerTheme.needsYouFill.cgColor }
        let muted = item.isNeedsYou ? TrackerTheme.mutedOnFill : TrackerTheme.muted
        if item.isHazard {
            let edge = NSView()
            edge.wantsLayer = true
            edge.layer?.backgroundColor = TrackerTheme.hazard.cgColor
            addSubview(edge)
            hazardEdge = edge
        }
        if editingEnabled, item.isTickable {
            let tick = TrackerTickButton(glyph: item.mark, color: TrackerTheme.markColor(item.status))
            tick.target = self
            tick.action = #selector(tickPressed(_:))
            tick.setAccessibilityRole(.checkBox)
            tick.setAccessibilityLabel("Done: \(String(item.title.prefix(80)))")
            tick.setAccessibilityValue(item.isDone ? 1 : 0)
            tick.setAccessibilityHelp("Status: \(Self.statusName(item.status))")
            tick.toolTip = item.isDone ? "Mark not done" : "Mark done"
            tick.setAccessibilityCustomActions(customActions(for: item))
            addSubview(tick)
            tickButton = tick
        } else {
            markLabel = addLabel(item.mark, color: TrackerTheme.markColor(item.status), font: TrackerTheme.textFont)
            markLabel?.toolTip = item.boundTooltip
        }

        // The title is plain, single-line text (no markdown or link styling of agent text).
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: TrackerTheme.textFont, .foregroundColor: TrackerTheme.text])
        if item.isDone {
            title.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                               range: NSRange(location: 0, length: title.length))
        }
        let titleView = TrackerTextView.make(singleLine: true)
        titleView.set(title)
        if editingEnabled { titleView.onDoubleClick = { [weak self] in self?.beginEditFromUser(.title) } }
        addSubview(titleView)
        textViews.append(titleView)
        mainText = titleView

        if let env = item.envBadge {
            let badge = addLabel(env, color: item.isHazard ? TrackerTheme.hazard : muted,
                                 font: NSFont.systemFont(ofSize: 10, weight: .semibold))
            badge.alignment = .center
            badge.lineBreakMode = .byTruncatingTail
            badge.toolTip = env
            badge.wantsLayer = true
            badge.layer?.backgroundColor = (item.isHazard ? TrackerTheme.hazardFill : TrackerTheme.badgeFill).cgColor
            badge.layer?.cornerRadius = 3
            badges.append(badge)
        }
        if let owner = item.owner, !owner.isEmpty {
            let chip = addLabel(owner, color: muted, font: TrackerTheme.metaFont)
            chip.alignment = .center
            chip.lineBreakMode = .byTruncatingTail
            chip.toolTip = owner
            chip.wantsLayer = true
            chip.layer?.backgroundColor = TrackerTheme.badgeFill.cgColor
            chip.layer?.cornerRadius = 7
            badges.append(chip)
            ownerChip = chip
        }
        if item.droppedConflicts > 0 {
            let note = addLabel("older dropped", color: muted, font: TrackerTheme.metaFont)
            note.alignment = .center
            note.toolTip = "Older conflicts were dropped"
            note.setAccessibilityLabel("Older conflicts were dropped")
            note.wantsLayer = true
            note.layer?.backgroundColor = TrackerTheme.badgeFill.cgColor
            note.layer?.cornerRadius = 7
            badges.append(note)
            droppedMark = note
        }
        let time = addLabel(item.relativeTime, color: muted, font: TrackerTheme.timeFont)
        time.alignment = .right
        timeLabel = time

        if item.isFoldable {
            let button = NSButton(frame: .zero)
            button.bezelStyle = .disclosure
            button.setButtonType(.pushOnPushOff)
            button.title = ""
            button.state = item.isExpanded ? .on : .off
            button.refusesFirstResponder = false
            button.target = self
            button.action = #selector(toggleFold(_:))
            button.setAccessibilityLabel("Details: \(String(item.title.prefix(80)))")
            button.toolTip = item.isExpanded ? "Hide details" : "Show details"
            button.setAccessibilityRole(.disclosureTriangle)
            button.setAccessibilityValue(item.isExpanded ? 1 : 0)
            if editingEnabled { button.setAccessibilityCustomActions(customActions(for: item)) }
            addSubview(button)
            disclosureButton = button
        }
        if editingEnabled { buildEditAffordances(item, muted: muted) }
        if let titleEditor, titleEditor.superview !== self { addSubview(titleEditor) }
        if let detailsEditor {
            if let line = boundLineText {
                let label = NSTextField(wrappingLabelWithString: line)
                label.font = TrackerTheme.textFont
                label.textColor = muted
                label.isSelectable = false
                label.refusesFirstResponder = true
                label.setAccessibilityLabel("Set by its source: \(line)")
                addSubview(label)
                boundLine = label
            }
            if detailsEditor.superview !== self { addSubview(detailsEditor) }
        } else if item.isExpanded {
            let openDetails: () -> Void = { [weak self] in self?.beginEditFromUser(.details) }
            if let lead = item.bodyLead {
                let view = TrackerTextView.make()
                view.set(NSAttributedString(string: lead, attributes: [
                    .font: TrackerTheme.textFont, .foregroundColor: TrackerTheme.text]))
                if editingEnabled { view.onDoubleClick = openDetails }
                addSubview(view)
                textViews.append(view)
                leadText = view
            }
            if !item.noteBlocks.isEmpty {
                let prose = TrackerProseView(blocks: TrackerMdAdapter.blocks(item.noteBlocks))
                if editingEnabled { prose.textViews.forEach { $0.onDoubleClick = openDetails } }
                addSubview(prose)
                proseView = prose
            }
        }
        hasChipLine = !item.links.isEmpty || item.bound != nil
        for (index, link) in item.links.enumerated() {
            let chip = TrackerLinkChip(link: link, index: index, muted: muted)
            let itemId = item.id
            chip.onActivate = { [weak self] action in self?.onOpenLink?(itemId, action) }
            addSubview(chip)
            linkChips.append(chip)
        }
        if let footnote = item.staleFootnote {
            let label = addLabel(footnote, color: muted, font: TrackerTheme.metaFont)
            label.alignment = .right
            label.toolTip = "The source has not reported since then; this is its last value."
            staleFootnote = label
        }
    }

    // MARK: - Editing affordances

    static func statusName(_ status: TrackerStatusWire) -> String {
        statusChoices.first { $0.wire == status.wireName }?.name.lowercased() ?? "to do"
    }

    /// The conflict mark, the sensitive badge and (expanded) the actions line.
    private func buildEditAffordances(_ item: TrackerItemRow, muted: NSColor) {
        if !item.conflicts.isEmpty {
            let chip = TrackerChipButton(text: "⇄ conflict", color: Theme.amber, fill: TrackerTheme.badgeFill)
            chip.target = self
            chip.action = #selector(conflictPressed(_:))
            chip.setAccessibilityLabel(item.conflictSummary ?? "Conflict")
            chip.toolTip = item.conflictSummary
            addSubview(chip)
            conflictButton = chip
        }
        if item.sensitive != nil {
            let chip = TrackerChipButton(text: "sensitive?", color: Theme.amber, fill: TrackerTheme.badgeFill)
            chip.target = self
            chip.action = #selector(sensitivePressed(_:))
            chip.setAccessibilityLabel(item.sensitiveLabel ?? "Possible sensitive data")
            chip.toolTip = item.sensitiveLabel
            addSubview(chip)
            sensitiveButton = chip
        }
        guard item.isExpanded || detailsEditor != nil else { return }
        let text = TrackerTheme.mutedOnFill
        let title = TrackerChipButton(text: "Edit title", color: text, fill: nil, padding: 3)
        title.target = self
        title.action = #selector(editTitlePressed(_:))
        title.setAccessibilityLabel("Edit title: \(String(item.title.prefix(80)))")
        let details = TrackerChipButton(text: "Edit details", color: text, fill: nil, padding: 3)
        details.target = self
        details.action = #selector(editDetailsPressed(_:))
        details.setAccessibilityLabel("Edit details: \(String(item.title.prefix(80)))")
        addSubview(title)
        addSubview(details)
        editTitleButton = title
        editDetailsButton = details
        if item.isStatusEditable {
            let pop = NSPopUpButton(frame: .zero, pullsDown: true)
            pop.isBordered = false
            pop.refusesFirstResponder = false
            pop.font = TrackerTheme.metaFont
            (pop.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            pop.addItem(withTitle: "Status ▾")
            pop.item(at: 0)?.attributedTitle = NSAttributedString(string: "Status ▾", attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: text])
            for (name, wire) in Self.statusChoices {
                pop.addItem(withTitle: name)
                let entry = pop.lastItem
                entry?.representedObject = wire
                entry?.state = item.status.wireName == wire ? .on : .off
                entry?.target = self
                entry?.action = #selector(menuSetStatus(_:))
            }
            pop.setAccessibilityLabel("Status: \(Self.statusName(item.status))")
            addSubview(pop)
            statusPopUp = pop
        }
    }

    @objc private func tickPressed(_ sender: Any?) {
        if let item = row.item { onTick?(item.id) }
    }
    @objc private func conflictPressed(_ sender: NSView) { showConflict(fromKeyboard: window?.firstResponder === sender) }
    @objc private func sensitivePressed(_ sender: NSView) { reviewSensitive(fromKeyboard: window?.firstResponder === sender) }
    @objc private func editTitlePressed(_ sender: Any?) { beginEditFromUser(.title) }
    @objc private func editDetailsPressed(_ sender: Any?) { beginEditFromUser(.details) }

    /// What VoiceOver offers on the tick and the disclosure, beyond pressing them.
    func customActions(for item: TrackerItemRow) -> [NSAccessibilityCustomAction] {
        guard editingEnabled else { return [] }
        var actions: [NSAccessibilityCustomAction] = []
        func add(_ name: String, _ run: @escaping () -> Void) {
            actions.append(NSAccessibilityCustomAction(name: name, handler: { run(); return true }))
        }
        add("Edit title") { [weak self] in self?.beginEditFromUser(.title) }
        add("Edit details") { [weak self] in self?.beginEditFromUser(.details) }
        if item.isStatusEditable {
            for (name, wire) in Self.statusChoices where wire != item.status.wireName {
                let id = item.id
                add("Set status to \(name)") { [weak self] in self?.onSetStatus?(id, wire) }
            }
        }
        if !item.conflicts.isEmpty { add("Show conflict") { [weak self] in self?.showConflict(fromKeyboard: true) } }
        if item.sensitive != nil {
            add("Review possible sensitive data") { [weak self] in self?.reviewSensitive(fromKeyboard: true) }
        }
        return actions
    }

    // MARK: - Focus

    private var controls: [TrackerControlRole: NSView] {
        var found: [TrackerControlRole: NSView] = [:]
        if let tickButton { found[.tick] = tickButton }
        if let disclosureButton { found[.disclosure] = disclosureButton }
        if let conflictButton { found[.conflict] = conflictButton }
        if let sensitiveButton { found[.sensitive] = sensitiveButton }
        if let editTitleButton { found[.editTitle] = editTitleButton }
        if let editDetailsButton { found[.editDetails] = editDetailsButton }
        if let statusPopUp { found[.status] = statusPopUp }
        return found
    }

    /// The control of this row that has keyboard focus, if any.
    func focusedControlRole() -> TrackerControlRole? {
        guard let responder = window?.firstResponder else { return nil }
        return controls.first { $0.value === responder }?.key
    }

    @discardableResult
    func focusControl(_ role: TrackerControlRole) -> Bool {
        guard let control = controls[role], let window else { return false }
        return window.makeFirstResponder(control)
    }

    // MARK: - Inline editors

    /// Which editor is open (title or details), if any.
    var activeEditor: TrackerEditKind? {
        titleEditor != nil ? .title : (detailsEditor != nil ? .details : nil)
    }

    /// Save the open editor now (the disclosure was pressed on a dirty details editor).
    func commitEditor() {
        titleEditor?.commit()
        detailsEditor?.commit()
    }

    /// What the user has typed in the open editor.
    var editorText: String? { titleEditor?.typed ?? detailsEditor?.typed }

    /// Open an editor with `text`. The title editor sits in the title's frame; the details editor takes
    /// the place of the body and the note (a bound item's source line stays above it, read-only).
    func beginEditor(_ kind: TrackerEditKind, text: String, boundLine: String? = nil) {
        guard case .item = row.content, activeEditor == nil else { return }
        switch kind {
        case .title:
            let editor = TrackerTitleEditor(text: text)
            editor.onCommit = { [weak self] typed in self?.editorFinished(.title, typed) }
            editor.onCancel = { [weak self] in self?.editorCancelled(.title) }
            titleEditor = editor
        case .details:
            let editor = TrackerDetailsEditor.make(text: text)
            editor.onCommit = { [weak self] typed in self?.editorFinished(.details, typed) }
            editor.onCancel = { [weak self] in self?.editorCancelled(.details) }
            editor.onResize = { [weak self] in
                self?.measured = nil
                self?.needsLayout = true
                self?.onEditorResized?()
            }
            detailsEditor = editor
            boundLineText = boundLine
        }
        build()
        measured = nil
        needsLayout = true
        // The editor needs its frame before it can take focus (a field at zero size gives it up at once).
        layoutSubtreeIfNeeded()
        titleEditor?.arm()
        focusEditor()
        if let titleEditor, titleEditor.currentEditor() == nil { focusEditor() }
    }

    /// Give the open editor keyboard focus: a title selects all of its text, details put the caret at the end.
    func focusEditor() {
        if let titleEditor, let window {
            window.makeFirstResponder(titleEditor)
            titleEditor.currentEditor()?.selectAll(nil)
        } else if let detailsEditor, let window {
            window.makeFirstResponder(detailsEditor)
            detailsEditor.setSelectedRange(NSRange(location: (detailsEditor.string as NSString).length, length: 0))
        }
    }

    /// A save is pending (read-only, dimmed, showing the text saved) or it failed (editable again).
    func setEditorPending(_ pending: Bool) {
        // Asked before the change: making a field editable again ends the field editor that had focus.
        let ownedFocus = editorOwnsFocus
        titleEditor?.setPending(pending)
        detailsEditor?.setPending(pending)
        guard !pending else { return }
        // Editable again, but focus is not taken: after a save it went back to where it was (the composer),
        // and a refusal or a timeout that comes later must not pull what the user types into the tracker.
        // An editor that still had focus keeps it.
        if ownedFocus { focusEditor() }
        titleEditor?.reopen()
        detailsEditor?.reopen()
    }

    /// The open editor (or its field editor) is the window's first responder.
    private var editorOwnsFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let titleEditor, responder === titleEditor || (responder as? NSTextView)?.delegate === titleEditor { return true }
        if let detailsEditor, responder === detailsEditor { return true }
        return false
    }

    /// Close the open editor and show the row's own content.
    func endEditor() {
        titleEditor?.finish()
        detailsEditor?.finish()
        let editors: [NSView?] = [titleEditor, detailsEditor]
        titleEditor = nil
        detailsEditor = nil
        boundLineText = nil
        editors.forEach { $0?.removeFromSuperview() }
        build()
        measured = nil
        needsLayout = true
    }

    private func editorFinished(_ kind: TrackerEditKind, _ text: String) {
        if let item = row.item { onCommitEdit?(item.id, kind, text) }
    }

    private func editorCancelled(_ kind: TrackerEditKind) {
        if let item = row.item { onCancelEdit?(item.id, kind) }
    }

    private func addText(_ text: NSAttributedString) -> TrackerTextView {
        let view = TrackerTextView.make()
        view.set(text)
        addSubview(view)
        textViews.append(view)
        return view
    }

    private func addLabel(_ text: String, color: NSColor, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byClipping
        label.refusesFirstResponder = true
        addSubview(label)
        return label
    }

    private func addButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.refusesFirstResponder = true
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: TrackerTheme.metaFont, .foregroundColor: Theme.cornflower])
        addSubview(button)
        return button
    }
}
