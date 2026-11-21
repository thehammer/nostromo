import AppKit
import NostromoKit

/// One conflict the pane can settle: an overwritten value of an item's field, or a removed item.
struct TrackerConflictEntry: Equatable {
    let itemId: String
    /// `status`, `title`, `text`, `note`, … or `removed` for a removed item.
    let field: String
    /// The opaque id `resolve_conflict` names (never parsed).
    let conflictId: String
    /// A sentence built from labels ("agent claudia set status to “in progress”, then you set it to “done”, 4 s ago.").
    let sentence: String
    /// The value that lost, and the value now in place, as plain text (cut at 500 characters).
    let losingValue: String
    let currentValue: String
    /// The ops putting the kept (losing) value back, so "Use it" can be undone; empty for a removed item.
    /// A title or text goes back with `restore_text` (it is not cut at 500 characters, `edit`'s text is).
    let inverse: [TrackerPaneOpWire]

    var isRemoval: Bool { field == "removed" }

    /// The entries for one item's live conflicts, newest first.
    static func entries(for item: TrackerItemRow, now: Date) -> [TrackerConflictEntry] {
        item.conflicts.reversed().map { conflict in
            let current = currentValue(of: conflict.field, in: item)
            let inverse: [TrackerPaneOpWire]
            switch conflict.field {
            case "status": inverse = [.status(id: item.id, status: current)]
            case "title", "text": inverse = [.restoreText(id: item.id, text: current)]
            case "note": inverse = [.edit(id: item.id, title: nil, text: nil, body: current)]
            default: inverse = []
            }
            return TrackerConflictEntry(
                itemId: item.id, field: conflict.field, conflictId: conflict.conflictId,
                sentence: TrackerConflictText.sentence(conflict, current: current, now: now),
                losingValue: TrackerConflictText.safe(String(conflict.losing.prefix(TrackerConflictText.maxValueChars))),
                currentValue: TrackerConflictText.safe(String(current.prefix(TrackerConflictText.maxValueChars))),
                inverse: inverse)
        }
    }

    static func entry(for removed: TrackerRemovedConflictWire, now: Date) -> TrackerConflictEntry {
        TrackerConflictEntry(itemId: removed.itemId, field: "removed", conflictId: removed.conflictId,
                             sentence: TrackerConflictText.sentence(removed, now: now),
                             losingValue: TrackerConflictText.safe(String(removed.title.prefix(TrackerConflictText.maxValueChars))),
                             currentValue: "", inverse: [])
    }

    private static func currentValue(of field: String, in item: TrackerItemRow) -> String {
        switch field {
        case "status": return item.status.wireName
        case "title", "text": return item.editText
        case "note": return item.editNote ?? ""
        default: return ""
        }
    }
}

/// What a popover shows: a sentence, optional plain-text value boxes, and buttons.
struct TrackerPopoverSection {
    struct Button {
        let title: String
        /// What VoiceOver reads when it differs from the title (a short title carries its value here).
        var accessibilityLabel: String?
        let action: () -> Void

        init(title: String, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
            self.title = title
            self.accessibilityLabel = accessibilityLabel
            self.action = action
        }
    }
    let message: String
    var values: [String] = []
    /// A caption above each value, in order (a value without one has none).
    var valueCaptions: [String] = []
    var buttons: [Button] = []
}

/// A small transient popover: sections of text, values and buttons, used for conflicts (settle either
/// side), removed items (Restore, Dismiss) and the sensitive-data review.
///
/// Opened by mouse it takes no key focus, so the composer keeps it: its buttons refuse first responder.
/// Opened from the keyboard its first button is first responder and Esc closes it and gives focus back
/// to whatever opened it.
final class TrackerConflictPopover: NSObject, NSPopoverDelegate {
    static let width: CGFloat = 320

    let sections: [TrackerPopoverSection]
    /// Every button, in order (tests press them).
    private(set) var buttons: [NSButton] = []
    private(set) var valueViews: [TrackerPopoverValueView] = []
    private(set) var messageLabels: [NSTextField] = []
    var isShown: Bool { popover.isShown }
    /// The laid-out content (tests measure it).
    var contentView: NSView? { popover.contentViewController?.view }
    private let popover = NSPopover()
    private var returnFocusTo: NSResponder?
    private var fromKeyboard = false

    init(sections: [TrackerPopoverSection]) {
        self.sections = sections
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = makeContent()
    }

    /// Show it below `anchor`. `fromKeyboard`: the opener was a key press or a VoiceOver action.
    func show(relativeTo anchor: NSView, fromKeyboard: Bool) {
        self.fromKeyboard = fromKeyboard
        returnFocusTo = fromKeyboard ? anchor : nil
        for button in buttons { button.refusesFirstResponder = !fromKeyboard }
        // A popover whose content can take focus becomes the key window: a mouse-opened one has nothing
        // that can, so the composer stays key.
        for view in valueViews { view.allowsFocus = fromKeyboard }
        // Opened by mouse it takes no key focus: whoever had it (the composer) keeps it.
        let window = anchor.window
        let prior = fromKeyboard ? nil : window?.firstResponder
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        if fromKeyboard, let first = buttons.first {
            first.window?.makeFirstResponder(first)
        } else if let prior, let window, window.firstResponder !== prior {
            let owner = (prior as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : nil } ?? prior
            window.makeFirstResponder(owner)
        }
    }

    func close() {
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard fromKeyboard, let target = returnFocusTo as? NSView, let window = target.window else { return }
        window.makeFirstResponder(target)
    }

    // MARK: - Content

    private func makeContent() -> NSView {
        let width = Self.width
        let pad: CGFloat = 12
        let inner = width - pad * 2
        let root = PopoverRoot()
        var y = pad
        for section in sections {
            let label = NSTextField(wrappingLabelWithString: section.message)
            label.font = TrackerTheme.textFont
            label.textColor = TrackerTheme.text
            label.isSelectable = false
            label.refusesFirstResponder = true
            let labelHeight = ceil(label.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height)
            label.frame = NSRect(x: pad, y: y, width: inner, height: labelHeight)
            root.addSubview(label)
            messageLabels.append(label)
            y += labelHeight + 6
            for (index, value) in section.values.enumerated() {
                let caption = index < section.valueCaptions.count ? section.valueCaptions[index] : nil
                if let caption {
                    let label = NSTextField(labelWithString: caption)
                    label.font = TrackerTheme.metaFont
                    label.textColor = TrackerTheme.muted
                    label.refusesFirstResponder = true
                    label.frame = NSRect(x: pad, y: y, width: inner, height: 14)
                    root.addSubview(label)
                    y += 16
                }
                let box = Self.valueBox(value, width: inner)
                box.text.setAccessibilityLabel((caption ?? "Value") + ": " + value)
                box.text.toolTip = value
                box.scroll.frame.origin = NSPoint(x: pad, y: y)
                root.addSubview(box.scroll)
                valueViews.append(box.text)
                y += box.scroll.frame.height + 6
            }
            // Buttons sit in a row and wrap to the next when the row is full: none runs off the popover.
            var x = pad
            var rowHeight: CGFloat = 0
            for button in section.buttons {
                let view = NSButton(title: button.title, target: nil, action: nil)
                view.bezelStyle = .rounded
                view.controlSize = .small
                view.font = TrackerTheme.metaFont
                view.refusesFirstResponder = true
                view.lineBreakMode = .byTruncatingTail
                view.sizeToFit()
                view.frame.size.width = min(view.frame.width, inner)
                if x > pad, x + view.frame.width > pad + inner {
                    x = pad
                    y += rowHeight + 6
                }
                view.frame.origin = NSPoint(x: x, y: y)
                view.toolTip = button.accessibilityLabel
                if let label = button.accessibilityLabel { view.setAccessibilityLabel(label) }
                let action = button.action
                view.target = self
                view.action = #selector(pressed(_:))
                actions[ObjectIdentifier(view)] = action
                root.addSubview(view)
                buttons.append(view)
                rowHeight = max(rowHeight, view.frame.height)
                x += view.frame.width + 8
            }
            if !section.buttons.isEmpty { y += rowHeight + 6 }
            y += 8
        }
        root.frame = NSRect(x: 0, y: 0, width: width, height: y + pad - 8)
        return root
    }

    private var actions: [ObjectIdentifier: () -> Void] = [:]

    @objc private func pressed(_ sender: NSButton) {
        let action = actions[ObjectIdentifier(sender)]
        popover.close()
        action?()
    }

    /// A value as plain, scrollable, non-editable text with no link detection: never markdown.
    private static func valueBox(_ value: String, width: CGFloat) -> (scroll: NSScrollView, text: TrackerPopoverValueView) {
        let text = TrackerPopoverValueView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false
        text.drawsBackground = false
        text.font = TrackerTheme.metaFont
        text.textColor = TrackerTheme.text
        text.textContainerInset = NSSize(width: 4, height: 3)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.string = String(value.prefix(TrackerConflictText.maxValueChars))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = TrackerTheme.badgeFill
        scroll.borderType = .noBorder
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? 14
        scroll.frame.size.height = min(max(ceil(used) + 8, 22), 90)
        return (scroll, text)
    }
}

/// A value shown in a popover: plain text that takes focus only when the popover was opened from the keyboard.
final class TrackerPopoverValueView: NSTextView {
    var allowsFocus = false
    override var acceptsFirstResponder: Bool { allowsFocus }
}

/// The popover's content: flipped, so sections stack top to bottom.
private final class PopoverRoot: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - The popovers the pane opens

enum TrackerPopovers {
    /// Settle one item's live conflicts: keep what is there, or use the value that lost.
    static func item(_ item: TrackerItemRow, now: Date,
                     resolve: @escaping (TrackerConflictEntry, TrackerConflictKeepWire) -> Void) -> TrackerConflictPopover {
        TrackerConflictPopover(sections: TrackerConflictEntry.entries(for: item, now: now).map { entry in
            choice(entry, extra: [], resolve: resolve)
        })
    }

    /// The header chip's list: every live conflict (with Show) and every removed item (Restore, Dismiss).
    static func board(_ board: TrackerBoardViewWire, now: Date,
                      show: @escaping (String) -> Void,
                      resolve: @escaping (TrackerConflictEntry, TrackerConflictKeepWire) -> Void) -> TrackerConflictPopover {
        var sections: [TrackerPopoverSection] = []
        for node in board.nodes {
            guard case .item(let wire) = node, !wire.conflicts.isEmpty else { continue }
            let row = TrackerPresenter.itemRow(wire, sectionTitle: "", folds: TrackerFoldState(), now: now, timeZone: .current)
            for entry in TrackerConflictEntry.entries(for: row, now: now) {
                sections.append(choice(entry, extra: [.init(title: "Show") { show(entry.itemId) }], resolve: resolve))
            }
        }
        for removed in board.removedConflicts {
            let entry = TrackerConflictEntry.entry(for: removed, now: now)
            sections.append(removal(entry, resolve: resolve))
        }
        return TrackerConflictPopover(sections: sections)
    }

    static func removals(_ removed: [TrackerRemovedConflictWire], now: Date,
                         resolve: @escaping (TrackerConflictEntry, TrackerConflictKeepWire) -> Void) -> TrackerConflictPopover {
        TrackerConflictPopover(sections: removed.map {
            removal(TrackerConflictEntry.entry(for: $0, now: now), resolve: resolve)
        })
    }

    /// Keep what is there or use the value that lost. A status is a short word, so its buttons carry it; a
    /// title, text or note can be any length, so its buttons have fixed short labels and the two values are
    /// shown above them as wrapped, selectable text (VoiceOver reads each value on its button).
    private static func choice(_ entry: TrackerConflictEntry, extra: [TrackerPopoverSection.Button],
                               resolve: @escaping (TrackerConflictEntry, TrackerConflictKeepWire) -> Void) -> TrackerPopoverSection {
        let keep: TrackerPopoverSection.Button
        let use: TrackerPopoverSection.Button
        var section: TrackerPopoverSection
        if entry.field == "status" {
            keep = .init(title: "Keep \(TrackerConflictText.display(entry.currentValue, field: entry.field))") { resolve(entry, .current) }
            use = .init(title: "Use \(TrackerConflictText.display(entry.losingValue, field: entry.field))") { resolve(entry, .losing) }
            section = TrackerPopoverSection(message: entry.sentence, values: [entry.losingValue])
        } else {
            keep = .init(title: "Keep current",
                         accessibilityLabel: "Keep current value: \(entry.currentValue)") { resolve(entry, .current) }
            use = .init(title: "Use other value",
                        accessibilityLabel: "Use other value: \(entry.losingValue)") { resolve(entry, .losing) }
            section = TrackerPopoverSection(message: entry.sentence, values: [entry.currentValue, entry.losingValue],
                                            valueCaptions: ["Current value", "Other value"])
        }
        section.buttons = extra + [keep, use]
        return section
    }

    private static func removal(_ entry: TrackerConflictEntry,
                                resolve: @escaping (TrackerConflictEntry, TrackerConflictKeepWire) -> Void) -> TrackerPopoverSection {
        TrackerPopoverSection(message: entry.sentence, buttons: [
            .init(title: "Restore") { resolve(entry, .losing) },
            .init(title: "Dismiss") { resolve(entry, .current) },
        ])
    }

    /// The review of a sensitive badge.
    static func sensitive(_ item: TrackerItemRow, share: @escaping () -> Void,
                          editDetails: @escaping () -> Void) -> TrackerConflictPopover {
        let what = TrackerConflictText.classList(item.sensitive?.classes ?? [])
        return TrackerConflictPopover(sections: [TrackerPopoverSection(
            message: "Nostromo isn't showing this item's text to the agent because it may contain a \(what).",
            buttons: [.init(title: "It's fine, share it", action: share),
                      .init(title: "Edit details", action: editDetails)])])
    }
}
