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
    /// An edit putting the kept (losing) value back, so "Use it" can be undone; nil for a removed item.
    let inverse: TrackerPaneOpWire?

    var isRemoval: Bool { field == "removed" }

    /// The entries for one item's live conflicts, newest first.
    static func entries(for item: TrackerItemRow, now: Date) -> [TrackerConflictEntry] {
        item.conflicts.reversed().map { conflict in
            let current = currentValue(of: conflict.field, in: item)
            let inverse: TrackerPaneOpWire?
            switch conflict.field {
            case "status": inverse = .status(id: item.id, status: current)
            case "title", "text": inverse = .edit(id: item.id, title: nil, text: current, body: nil)
            case "note": inverse = .edit(id: item.id, title: nil, text: nil, body: current)
            default: inverse = nil
            }
            return TrackerConflictEntry(
                itemId: item.id, field: conflict.field, conflictId: conflict.conflictId,
                sentence: TrackerConflictText.sentence(conflict, current: current, now: now),
                losingValue: String(conflict.losing.prefix(TrackerConflictText.maxValueChars)),
                currentValue: String(current.prefix(TrackerConflictText.maxValueChars)),
                inverse: inverse)
        }
    }

    static func entry(for removed: TrackerRemovedConflictWire, now: Date) -> TrackerConflictEntry {
        TrackerConflictEntry(itemId: removed.itemId, field: "removed", conflictId: removed.conflictId,
                             sentence: TrackerConflictText.sentence(removed, now: now),
                             losingValue: String(removed.title.prefix(TrackerConflictText.maxValueChars)),
                             currentValue: "", inverse: nil)
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
        let action: () -> Void
    }
    let message: String
    var values: [String] = []
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
            for value in section.values {
                let box = Self.valueBox(value, width: inner)
                box.scroll.frame.origin = NSPoint(x: pad, y: y)
                root.addSubview(box.scroll)
                valueViews.append(box.text)
                y += box.scroll.frame.height + 6
            }
            var x = pad
            for button in section.buttons {
                let view = NSButton(title: button.title, target: nil, action: nil)
                view.bezelStyle = .rounded
                view.controlSize = .small
                view.font = TrackerTheme.metaFont
                view.refusesFirstResponder = true
                view.sizeToFit()
                view.frame.origin = NSPoint(x: x, y: y)
                let action = button.action
                view.target = self
                view.action = #selector(pressed(_:))
                actions[ObjectIdentifier(view)] = action
                root.addSubview(view)
                buttons.append(view)
                x += view.frame.width + 8
            }
            if !section.buttons.isEmpty { y += (buttons.last?.frame.height ?? 0) + 6 }
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
            TrackerPopoverSection(
                message: entry.sentence, values: [entry.losingValue],
                buttons: [
                    .init(title: "Keep \(TrackerConflictText.display(entry.currentValue, field: entry.field))") { resolve(entry, .current) },
                    .init(title: "Use \(TrackerConflictText.display(entry.losingValue, field: entry.field))") { resolve(entry, .losing) },
                ])
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
                sections.append(TrackerPopoverSection(
                    message: entry.sentence, values: [entry.losingValue],
                    buttons: [
                        .init(title: "Show") { show(entry.itemId) },
                        .init(title: "Keep \(TrackerConflictText.display(entry.currentValue, field: entry.field))") { resolve(entry, .current) },
                        .init(title: "Use \(TrackerConflictText.display(entry.losingValue, field: entry.field))") { resolve(entry, .losing) },
                    ]))
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
