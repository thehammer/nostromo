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

    /// The ≤ 1 s change highlight is showing.
    private(set) var isHighlighted = false

    // Pieces, per kind.
    private(set) var textViews: [TrackerTextView] = []
    private var markLabel: NSTextField?
    private(set) var timeLabel: NSTextField?
    private(set) var badges: [NSTextField] = []
    private var ownerChip: NSTextField?
    private var mainText: TrackerTextView?
    private var noteText: TrackerTextView?
    /// The row's prose (a prose row, or an expanded note).
    private(set) var proseView: TrackerProseView?
    private var linksText: TrackerTextView?
    private var disclosure: NSButton?
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
        parts += textViews.map(\.string).filter { !$0.isEmpty }
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
        let items = copyMenuItems()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
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

    @objc func copyMarkdown(_ sender: Any?) {
        onCopyMarkdown?(row)
    }

    // MARK: - Clicks

    /// A Done group is one click target as a whole (its label must not swallow the click).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if case .doneGroup = row.content { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) {
        switch row.content {
        case .doneGroup(let group): onToggleDone?(group.sectionId)
        default: super.mouseDown(with: event)
        }
    }

    @objc private func toggleNote(_ sender: Any?) {
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
        let textX = h + Self.markWidth
        // Right column: the fixed-width time, then the badges if they leave the text its minimum
        // width; otherwise the badges take a line below the text.
        var right = width - h
        timeLabel?.frame = NSRect(x: right - Self.timeWidth, y: v + 1, width: Self.timeWidth, height: 15)
        right -= Self.timeWidth + Self.gap
        let widths = badges.map { badgeWidth($0) }
        let badgesWidth = widths.reduce(0) { $0 + $1 + 4 }
        let minimumText = Self.minimumTextWidth(forRowWidth: width)
        let textWidthAlone = max(right - Self.gap - textX, 1)
        let stacked = !badges.isEmpty && textWidthAlone - badgesWidth < minimumText
        var textWidth = textWidthAlone
        if !stacked {
            for (badge, w) in zip(badges, widths).reversed() {
                badge.frame = NSRect(x: right - w, y: v + 1, width: w, height: Self.chipHeight)
                right -= w + 4
            }
            textWidth = max(right - Self.gap - textX, 1)
        }
        markLabel?.frame = NSRect(x: h, y: v, width: Self.markWidth, height: 17)
        var y = v
        let mainHeight = mainText?.height(forWidth: textWidth) ?? 0
        mainText?.frame = NSRect(x: textX, y: y, width: textWidth, height: mainHeight)
        y += max(mainHeight, 17)
        if stacked {
            // The chips' own line, under the text, inside the row.
            y += 2
            var x = textX
            let limit = max(width - h, textX)
            for (badge, w) in zip(badges, widths) {
                let fitted = min(w, max(limit - x, 1))
                badge.frame = NSRect(x: x, y: y, width: fitted, height: Self.chipHeight)
                x += fitted + 4
            }
            y += Self.chipHeight
        }

        let blockWidth = max(width - h - textX, 1)
        if let proseView {
            y += 2
            let ph = proseView.layout(width: blockWidth)
            proseView.frame = NSRect(x: textX, y: y, width: blockWidth, height: ph)
            y += ph
        } else if let noteText {
            y += 2
            let discWidth = disclosure.map { ceil($0.intrinsicContentSize.width) + Self.gap } ?? 0
            let nh = noteText.height(forWidth: max(blockWidth - discWidth, 1))
            noteText.frame = NSRect(x: textX, y: y, width: max(blockWidth - discWidth, 1), height: nh)
            if let disclosure {
                let size = disclosure.intrinsicContentSize
                disclosure.frame = NSRect(x: textX + blockWidth - size.width, y: y, width: size.width, height: max(nh, size.height))
            }
            y += nh
        }
        if proseView != nil, let disclosure {
            let size = disclosure.intrinsicContentSize
            disclosure.frame = NSRect(x: textX, y: y, width: size.width, height: size.height)
            y += size.height
        }
        if let linksText {
            y += 2
            let lh = linksText.height(forWidth: blockWidth)
            linksText.frame = NSRect(x: textX, y: y, width: blockWidth, height: lh)
            y += lh
        }
        let height = y + v
        hazardEdge?.frame = NSRect(x: 0, y: 0, width: 3, height: max(height, minimumHeight))
        return height
    }

    /// A badge's width: its text plus padding, never past its cap.
    private func badgeWidth(_ badge: NSTextField) -> CGFloat {
        let cap = badge === ownerChip ? Self.maxOwnerChipWidth : Self.envBadgeMaxWidth
        return min(ceil(badge.intrinsicContentSize.width) + 8, cap)
    }

    // MARK: - Building

    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        textViews = []
        badges = []
        ownerChip = nil
        markLabel = nil
        timeLabel = nil
        mainText = nil
        noteText = nil
        proseView = nil
        linksText = nil
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
        for view in allTextViews { view.extraMenuItems = { [weak self] in self?.copyMenuItems() ?? [] } }
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
        markLabel = addLabel(item.mark, color: TrackerTheme.markColor(item.status), font: TrackerTheme.textFont)

        let text = NSMutableAttributedString(attributedString: MarkdownBlockDocument.render(spans: TrackerMdAdapter.spans(item.textSpans)))
        if item.isDone {
            text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                              range: NSRange(location: 0, length: text.length))
        }
        mainText = addText(text)

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
        let time = addLabel(item.relativeTime, color: muted, font: TrackerTheme.timeFont)
        time.alignment = .right
        timeLabel = time

        if !item.noteBlocks.isEmpty {
            if item.noteExpanded {
                let prose = TrackerProseView(blocks: TrackerMdAdapter.blocks(item.noteBlocks))
                addSubview(prose)
                proseView = prose
            } else if let first = item.noteFirstLine {
                let view = TrackerTextView.make(singleLine: true)
                view.set(NSAttributedString(string: first, attributes: [
                    .font: TrackerTheme.metaFont, .foregroundColor: muted]))
                addSubview(view)
                textViews.append(view)
                noteText = view
            }
            if item.noteIsCollapsible {
                disclosure = addButton(item.noteExpanded ? "less" : "more", action: #selector(toggleNote(_:)))
            }
        }
        if !item.linkTexts.isEmpty {
            linksText = addText(NSAttributedString(string: item.linkTexts.joined(separator: " · "), attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: muted]))
        }
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
