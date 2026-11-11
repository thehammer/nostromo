import AppKit
import Combine
import NostromoKit

/// The pinned "Waiting on you (N)" strip at the top of the tracker pane, outside its scroll view.
///
/// A title line and one line per entry, each a link to where the thing is (a decision's sheet, an
/// item on the board, the focus's approval card, the background list). At most `maxVisibleEntries`
/// lines show; the rest fold into "+ N more" (the title's count still includes them). It has no
/// height at all when nothing waits, so its height changes only when the entries do, and the pane
/// applies that change above the scroll view's clip, keeping the clip's content where it was
/// (`TrackerPaneView`). It never takes the keyboard.
final class TrackerWaitingStrip: NSView {
    override var isFlipped: Bool { true }

    static let titleHeight: CGFloat = 22
    static let entryHeight: CGFloat = 20
    static let maxVisibleEntries = 5

    /// A click on an entry (a user act).
    var onSelect: ((TrackerWaitingEntry) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let moreLabel = NSTextField(labelWithString: "")
    private(set) var entryRows: [TrackerWaitingEntryRow] = []
    private(set) var strip = TrackerStrip(entries: [])

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.stripFill.cgColor
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = TrackerTheme.text
        moreLabel.font = TrackerTheme.metaFont
        moreLabel.textColor = TrackerTheme.muted
        for label in [titleLabel, moreLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.refusesFirstResponder = true
            addSubview(label)
        }
        isHidden = true   // nothing waits until a board says so
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    /// The entries that get a line of their own.
    var visibleEntries: [TrackerWaitingEntry] { Array(strip.entries.prefix(Self.maxVisibleEntries)) }

    private var overflow: Int { max(strip.entries.count - Self.maxVisibleEntries, 0) }

    /// The height the strip wants: 0 when nothing waits, else the title and its lines.
    var preferredHeight: CGFloat {
        guard strip.count > 0 else { return 0 }
        return Self.titleHeight + Self.entryHeight * CGFloat(visibleEntries.count + (overflow > 0 ? 1 : 0))
    }

    /// What the strip reads, as plain text: the title, then every entry (shown or folded).
    var text: String {
        guard strip.count > 0 else { return strip.title }
        return strip.title + ":  " + strip.entries.map(\.text).joined(separator: "  ·  ")
    }

    func update(_ strip: TrackerStrip) {
        guard strip != self.strip else { return }
        self.strip = strip
        titleLabel.stringValue = strip.title
        for row in entryRows { row.removeFromSuperview() }
        entryRows = visibleEntries.map { entry in
            let row = TrackerWaitingEntryRow(entry: entry)
            row.onClick = { [weak self] in self?.onSelect?(entry) }
            addSubview(row)
            return row
        }
        moreLabel.stringValue = overflow > 0 ? "+ \(overflow) more" : ""
        moreLabel.isHidden = overflow == 0
        toolTip = strip.entries.map { entry in
            entry.detail.map { "\(entry.text) (\($0))" } ?? entry.text
        }.joined(separator: "\n")
        isHidden = strip.count == 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = TrackerRowView.hPad
        let width = max(bounds.width, 1)
        titleLabel.frame = NSRect(x: inset, y: 3, width: max(width - inset * 2, 1), height: 16)
        var y = Self.titleHeight
        for row in entryRows {
            row.frame = NSRect(x: 0, y: y, width: width, height: Self.entryHeight)
            y += Self.entryHeight
        }
        moreLabel.frame = NSRect(x: inset, y: y + 2, width: max(width - inset * 2, 1), height: 16)
    }
}

/// One line of the strip: the entry's text and where it comes from, a link.
final class TrackerWaitingEntryRow: NSView {
    override var isFlipped: Bool { true }

    let entry: TrackerWaitingEntry
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")

    init(entry: TrackerWaitingEntry) {
        self.entry = entry
        super.init(frame: .zero)
        let out = NSMutableAttributedString(string: entry.text, attributes: [
            .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.text])
        if let detail = entry.detail {
            out.append(NSAttributedString(string: "  ·  \(detail)", attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.muted]))
        }
        label.attributedStringValue = out
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.refusesFirstResponder = true
        addSubview(label)
        setAccessibilityRole(.button)
        setAccessibilityLabel(entry.detail.map { "\(entry.text), \($0)" } ?? entry.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let inset = TrackerRowView.hPad + TrackerRowView.gap
        label.frame = NSRect(x: inset, y: 2, width: max(bounds.width - inset - TrackerRowView.hPad, 1), height: 16)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        // A click, and nothing else: no first-responder change, no drag.
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - The tracker as a producer of the app-wide "needs you" source

/// Tells `NeedsYouCoordinator` (the one owner of the Dock badge, the sidebar pill and the notifier)
/// which tracker items wait on the person, across every focus with a board: `needs-you` items and
/// un-run staged commands, one content-free item each (`TrackerNeedsYouProducer`). It builds no
/// badge and posts nothing. Main thread only.
final class TrackerNeedsYouBadges {
    /// The one wired in `AppDelegate`; `AppStore` pokes it when a focus goes away.
    static weak var live: TrackerNeedsYouBadges?

    private let store: TrackerStore
    private let publish: ([NeedsYouItem]) -> Void
    private var subscription: AnyCancellable?
    private var lastPublished: [NeedsYouItem]?

    init(store: TrackerStore, publish: @escaping ([NeedsYouItem]) -> Void) {
        self.store = store
        self.publish = publish
        subscription = store.changes.sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Re-read every board and publish what is waiting (nothing is published again if it is the
    /// same list).
    func refresh() {
        let items = store.boards.keys.sorted().flatMap { tag in
            store.boards[tag].map { TrackerNeedsYouProducer.items(tag: tag, board: $0) } ?? []
        }
        guard items != lastPublished else { return }
        lastPublished = items
        publish(items)
    }
}

// MARK: - What the strip and the summary row reach through

/// The focus's pending decisions and how to show one: `DecisionPresenter` in the app, a fake in tests.
protocol TrackerDecisionProviding: AnyObject {
    func pendingDecisions(tag: String) -> [TrackerDecisionSummary]
    /// A focus tag whose waiting decisions changed.
    var decisionsChanged: AnyPublisher<String, Never> { get }
    func showDecision(requestId: String)
}

extension DecisionPresenter: TrackerDecisionProviding {}

/// The focus's REPL pane, as far as the summary row goes: it opens the Background activity popover
/// from the input bar (BA3's own entry point).
protocol TrackerBackgroundListOpening: AnyObject {
    func showBackgroundList()
}

extension ReplView: TrackerBackgroundListOpening {}

/// Where the strip's other links go.
struct TrackerWaitingActions {
    /// Select the focus and show its approval card.
    var showApprovals: (_ tag: String) -> Void

    static let live = TrackerWaitingActions(showApprovals: { tag in
        if let current = ApprovalStore.shared.current(tag: tag) {
            ApprovalStore.shared.setCollapsed(current.request.requestId, false)
        }
        LiveApprovalRouter().showFocus(tag: tag)
        ApprovalStore.shared.changes.send(tag)
    })
}
