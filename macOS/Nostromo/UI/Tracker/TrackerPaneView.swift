import AppKit
import Combine
import NostromoKit

/// The native tracker pane (reserved pane id `tracker`, T1): the focus's `tracker_board` from
/// `TrackerStore`, read-only.
///
/// Top to bottom: a fixed-height header (title, "updated 2 m ago", the filter, the committable
/// badge), the banner when the file is unreadable or gone, the pinned "Waiting on you (N)" strip,
/// then an `NSScrollView` whose flipped document stacks one `TrackerRowView` per row key.
///
/// The rules it keeps (PRD "Scroll, layout and focus safety"):
/// - An update touches only the rows `TrackerDiff` names; an identical board changes nothing.
/// - Before applying anything it captures the reading position (`TrackerViewportAnchor`) and
///   restores it after layout, so the first visible row moves by less than a point wherever the
///   change was, including a banner or the strip appearing above the scroll view.
/// - Done folds, moves and removals of rows on screen are held by `TrackerDeferral` until those
///   rows leave the viewport (checked on every scroll), the pane is reopened, or the user clicks
///   the Done group; a row holding a text selection keeps its content until the selection clears.
/// - It never takes keyboard focus on its own, never shows `Loading` over content and never
///   blanks: before the first board it shows a quiet "Waiting for the tracker…" that the board
///   replaces once.
/// - A changed row is highlighted for under a second; with Reduce Motion it is not highlighted.
final class TrackerPaneView: NSView {
    override var isFlipped: Bool { true }

    let tag: String

    let header = TrackerHeaderView()
    let banner = TrackerBannerView()
    let strip = TrackerWaitingStrip()
    let scrollView = NSScrollView()
    let clipView = TrackerClipView()
    let documentView = TrackerFlippedView()
    let placeholder = NSTextField(labelWithString: "Waiting for the tracker…")

    /// The board last rendered and what it was presented as.
    private(set) var board: TrackerBoardViewWire?
    private(set) var presentation: TrackerPresentation?
    /// What is on screen now (the presentation's rows plus anything held), top to bottom.
    private(set) var displayedRows: [TrackerRow] = []
    private(set) var rowViews: [String: TrackerRowView] = [:]
    private(set) var filter: TrackerFilter = .all
    private(set) var folds = TrackerFoldState()
    private(set) var deferral = TrackerDeferral()

    /// Render probe (`tracker show`, PRD criterion 20): bumped by every render that changed a row.
    private(set) var renderGeneration = 0
    /// How many row views the last render built or updated.
    private(set) var rowsUpdatedLast = 0

    private let store: TrackerStore
    private let now: () -> Date
    private let reduceMotion: () -> Bool
    private let pasteboard: NSPasteboard
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let timeZone: TimeZone
    private let tickInterval: TimeInterval?

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var tickTimer: Timer?
    private var isApplying = false
    private var laidOutWidth: CGFloat = -1
    private var selectedKey: String?

    /// - Parameters:
    ///   - now: the clock relative times are drawn from.
    ///   - reduceMotion: whether to skip the change highlight.
    ///   - pasteboard: where Copy as Markdown writes.
    ///   - schedule: runs work after a delay (the highlight's end); tests pass their own.
    ///   - tickInterval: how often relative times refresh; nil for none (tests call `tick()`).
    init(tag: String,
         store: TrackerStore = .shared,
         now: @escaping () -> Date = Date.init,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         pasteboard: NSPasteboard = .general,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         timeZone: TimeZone = .current,
         tickInterval: TimeInterval? = 30) {
        self.tag = tag
        self.store = store
        self.now = now
        self.reduceMotion = reduceMotion
        self.pasteboard = pasteboard
        self.schedule = schedule
        self.timeZone = timeZone
        self.tickInterval = tickInterval
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        setUp()
        let myTag = tag
        store.changes
            .filter { $0 == myTag }
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        tickTimer?.invalidate()
    }

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Setup

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.background.cgColor

        header.onFilter = { [weak self] filter in self?.setFilter(filter) }
        header.onCopyBoard = { [weak self] in self?.copyBoardMarkdown() }
        addSubview(header)
        addSubview(banner)
        addSubview(strip)

        clipView.drawsBackground = false
        clipView.postsBoundsChangedNotifications = true
        scrollView.contentView = clipView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.borderType = .noBorder
        documentView.frame = NSRect(x: 0, y: 0, width: 320, height: 1)
        scrollView.documentView = documentView
        addSubview(scrollView)

        placeholder.font = TrackerTheme.metaFont
        placeholder.textColor = TrackerTheme.muted
        placeholder.refusesFirstResponder = true
        addSubview(placeholder)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: nil) { [weak self] _ in
                self?.viewportMoved()
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { [weak self] note in
                guard let self, let view = note.object as? TrackerTextView, view.isDescendant(of: self.documentView) else { return }
                self.selectionChanged(in: view)
            })
    }

    // MARK: - Rendering

    /// Present the store's board for this tag and show it.
    func render() {
        guard let board = store.board(for: tag) else { return }
        self.board = board
        commit(TrackerPresenter.present(board: board, now: now(), filter: filter, folds: folds, timeZone: timeZone),
               highlight: true)
    }

    /// Relative times moved on: refresh them (in place, no layout change, no highlight).
    func tick() {
        render()
    }

    /// The user picked a filter. View-only: nothing goes to the daemon.
    func setFilter(_ filter: TrackerFilter) {
        guard filter != self.filter else { return }
        self.filter = filter
        header.select(filter)
        deferral.releaseAll()
        render()
    }

    /// The user clicked a section's Done group: open or close it, folding what it holds now.
    func toggleDoneGroup(section: String) {
        deferral.releaseDone(section: section)
        if folds.expandedDoneGroups.remove(section) == nil { folds.expandedDoneGroups.insert(section) }
        render()
    }

    func toggleNote(item id: String) {
        if folds.expandedNotes.remove(id) == nil { folds.expandedNotes.insert(id) }
        render()
    }

    func toggleLog() {
        folds.logExpanded.toggle()
        render()
    }

    /// Show `target`, holding back what the reader must not lose and keeping their place.
    private func commit(_ target: TrackerPresentation, highlight: Bool) {
        isApplying = true
        defer { isApplying = false }
        let firstRender = presentation == nil
        if firstRender { placeholder.removeFromSuperview() }

        let anchor = captureAnchor()
        let visible = visibleKeys()
        header.update(target.header)
        banner.update(target.banner)
        strip.update(target.strip)

        let result = deferral.resolve(displayed: displayedRows, target: target,
                                      visibleKeys: visible, selectedKey: currentSelectedKey())
        presentation = target

        var updated = 0
        var changed: [TrackerRowView] = []
        for op in result.applyNow {
            switch op {
            case .remove(let key):
                rowViews.removeValue(forKey: key)?.removeFromSuperview()
            case .insert(let row, _):
                let view = makeRowView(row)
                rowViews[row.key] = view
                documentView.addSubview(view)
                updated += 1
                if case .item = row.content { changed.append(view) }
            case .update(let row):
                guard let view = rowViews[row.key] else { continue }
                let old = view.row
                if case .stub = row.content {
                    if case .stub = old.content {} else { view.minimumHeight = view.frame.height }
                } else {
                    view.minimumHeight = 0
                }
                view.apply(row)
                updated += 1
                let renamedInPlace = result.renamed.values.contains(row.key)
                if !row.differsOnlyInTime(from: old), !renamedInPlace { changed.append(view) }
            case .move:
                break   // order comes from the rows themselves
            }
        }
        displayedRows = result.rows

        layoutChrome()
        layoutRows(width: contentWidth)
        restore(anchor, renamed: result.renamed)

        if !result.applyNow.isEmpty { renderGeneration += 1 }
        rowsUpdatedLast = updated
        if highlight && !firstRender {
            let reduce = reduceMotion()
            for view in changed { view.flashHighlight(reduceMotion: reduce, schedule: schedule) }
        }
    }

    /// Re-run the deferral against the same target (the viewport moved, the selection cleared, the
    /// pane came back).
    private func recommit() {
        guard let presentation else { return }
        commit(presentation, highlight: false)
    }

    private func makeRowView(_ row: TrackerRow) -> TrackerRowView {
        let view = TrackerRowView(row: row)
        view.onToggleDone = { [weak self] section in self?.toggleDoneGroup(section: section) }
        view.onToggleNote = { [weak self] id in self?.toggleNote(item: id) }
        view.onToggleLog = { [weak self] in self?.toggleLog() }
        view.onCopyMarkdown = { [weak self] row in self?.copyMarkdown(for: row) }
        return view
    }

    // MARK: - Layout

    var contentWidth: CGFloat { max(clipView.bounds.width, 1) }

    override func layout() {
        super.layout()
        guard !isApplying else { return }
        let anchor = captureAnchor()
        layoutChrome()
        if contentWidth != laidOutWidth {
            layoutRows(width: contentWidth)
            restore(anchor, renamed: [:])
        }
    }

    /// Header, banner and strip stacked at the top; the scroll view takes the rest.
    private func layoutChrome() {
        let width = bounds.width
        var y: CGFloat = 0
        header.frame = NSRect(x: 0, y: y, width: width, height: TrackerHeaderView.height)
        y += TrackerHeaderView.height
        let bannerHeight = banner.preferredHeight
        banner.frame = NSRect(x: 0, y: y, width: width, height: bannerHeight)
        y += bannerHeight
        let stripHeight = strip.preferredHeight
        strip.frame = NSRect(x: 0, y: y, width: width, height: stripHeight)
        y += stripHeight
        let scrollFrame = NSRect(x: 0, y: y, width: width, height: max(bounds.height - y, 0))
        if scrollView.frame != scrollFrame {
            scrollView.frame = scrollFrame
            scrollView.tile()   // the clip's size now, not on the next layout pass
        }
        placeholder.frame = NSRect(x: TrackerRowView.hPad, y: y + 12, width: max(width - TrackerRowView.hPad * 2, 1), height: 16)
    }

    /// Stack the row views in display order at `width`.
    private func layoutRows(width: CGFloat) {
        laidOutWidth = width
        var y: CGFloat = 0
        for row in displayedRows {
            guard let view = rowViews[row.key] else { continue }
            let height = view.height(forWidth: width)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: max(y, clipView.bounds.height))
    }

    // MARK: - Anchoring

    private var rowFrames: [(key: String, frame: CGRect)] {
        displayedRows.compactMap { row in rowViews[row.key].map { (key: row.key, frame: $0.frame) } }
    }

    private func captureAnchor() -> TrackerViewportAnchor? {
        guard !displayedRows.isEmpty else { return nil }
        return TrackerViewportAnchor.capture(rows: rowFrames, viewport: clipView.bounds)
    }

    private func restore(_ anchor: TrackerViewportAnchor?, renamed: [String: String]) {
        let frames = Dictionary(rowFrames.map { ($0.key, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let top = anchor?.restoredTop(frames: frames, renamed: renamed,
                                      documentHeight: documentView.frame.height,
                                      viewportHeight: clipView.bounds.height) ?? 0
        guard abs(clipView.bounds.minY - top) > 0.01 || anchor == nil else { return }
        clipView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Keys of the rows intersecting the viewport now.
    func visibleKeys() -> Set<String> {
        let viewport = clipView.bounds
        return Set(rowFrames.filter { $0.frame.maxY > viewport.minY && $0.frame.minY < viewport.maxY }.map(\.key))
    }

    private func viewportMoved() {
        guard !isApplying, deferral.hasHeld else { return }
        recommit()
    }

    // MARK: - Selection

    private func currentSelectedKey() -> String? {
        guard let key = selectedKey, rowViews[key]?.selectedTextView != nil else { return nil }
        return key
    }

    private func selectionChanged(in view: TrackerTextView) {
        guard !isApplying, let key = rowViews.first(where: { view.isDescendant(of: $0.value) })?.key else { return }
        if view.hasSelection {
            // One selection in the pane at a time.
            for (other, rowView) in rowViews where other != key {
                for textView in rowView.allTextViews where textView.hasSelection {
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
            selectedKey = key
        } else if key == selectedKey, rowViews[key]?.selectedTextView == nil {
            selectedKey = nil
            if deferral.held.contains(where: { $0.kind == .selection }) { recommit() }
        }
    }

    // MARK: - Reopening and ticking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tickTimer?.invalidate()
        tickTimer = nil
        guard window != nil else { return }
        if let tickInterval {
            let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
        reopened()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        reopened()
    }

    /// The pane is on screen again: whatever was held folds now.
    private func reopened() {
        guard deferral.hasHeld else { return }
        deferral.releaseAll()
        recommit()
    }

    // MARK: - Copy as Markdown

    /// The whole board's markdown (the file's bytes for a clean file).
    func copyBoardMarkdown() {
        guard let board else { return }
        write(TrackerMarkdown.board(board))
    }

    /// A section's or an item's markdown, exactly as the file has it.
    func copyMarkdown(for row: TrackerRow) {
        guard let board else { return }
        let text: String?
        switch row.content {
        case .section(let section): text = TrackerMarkdown.section(section.id, in: board)
        default: text = row.item.flatMap { TrackerMarkdown.item($0.id, in: board) }
        }
        if let text { write(text) }
    }

    private func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Probes (read-only)

    /// `nostromo-app tracker-anchor`.
    func anchorSnapshot(windowIndex: Int) -> TrackerAnchorSnapshot {
        TrackerAnchorProbe.snapshot(tag: tag, window: windowIndex, clipBounds: clipView.bounds,
                                    documentHeight: documentView.frame.height, rows: rowFrames,
                                    held: deferral.held)
    }

    /// `nostromo-app tracker show`: what this pane shows.
    func showReport() -> [String: Any] {
        AppControlTracker.show(tag: tag, presentation: presentation, displayedRows: displayedRows,
                               visible: window != nil && !isHiddenOrHasHiddenAncestor, held: deferral.held,
                               renderGeneration: renderGeneration, rowsUpdatedLast: rowsUpdatedLast)
    }
}

/// The tracker's clip view: flipped, so its bounds' origin is the viewport top in the document.
final class TrackerClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - Header

/// Title, "updated 2 m ago", the filter and the committable badge, at a fixed height whatever they
/// say, so nothing in the header ever moves the content below it.
final class TrackerHeaderView: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 50

    var onFilter: ((TrackerFilter) -> Void)?
    var onCopyBoard: (() -> Void)?

    let titleLabel = NSTextField(labelWithString: "")
    let updatedLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    let filterControl = NSSegmentedControl(labels: TrackerFilter.allCases.map(\.label),
                                           trackingMode: .selectOne, target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = TrackerTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.font = TrackerTheme.metaFont
        updatedLabel.textColor = TrackerTheme.muted
        badgeLabel.font = TrackerTheme.metaFont
        badgeLabel.textColor = Theme.amber
        badgeLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, updatedLabel, badgeLabel] {
            label.refusesFirstResponder = true
            addSubview(label)
        }
        filterControl.controlSize = .small
        filterControl.font = TrackerTheme.metaFont
        filterControl.selectedSegment = 0
        filterControl.refusesFirstResponder = true
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        addSubview(filterControl)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    func update(_ header: TrackerHeader) {
        if titleLabel.stringValue != header.title { titleLabel.stringValue = header.title }
        if updatedLabel.stringValue != header.updatedText {
            updatedLabel.stringValue = header.updatedText
            needsLayout = true   // the badge sits after it (the header's own height never changes)
        }
        let badge = header.committableText ?? ""
        if badgeLabel.stringValue != badge { badgeLabel.stringValue = badge }
        badgeLabel.isHidden = badge.isEmpty
        toolTip = header.path
    }

    func select(_ filter: TrackerFilter) {
        filterControl.selectedSegment = TrackerFilter.allCases.firstIndex(of: filter) ?? 0
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        let all = TrackerFilter.allCases
        guard all.indices.contains(sender.selectedSegment) else { return }
        onFilter?(all[sender.selectedSegment])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(copyMenuItem())
        return menu
    }

    func copyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Copy as Markdown", action: #selector(copyBoard(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func copyBoard(_ sender: Any?) {
        onCopyBoard?()
    }

    override func layout() {
        super.layout()
        let h = TrackerRowView.hPad
        let filterSize = filterControl.fittingSize
        filterControl.frame = NSRect(x: max(bounds.width - h - filterSize.width, h), y: 6,
                                     width: filterSize.width, height: filterSize.height)
        titleLabel.frame = NSRect(x: h, y: 7, width: max(filterControl.frame.minX - h * 2, 1), height: 18)
        updatedLabel.sizeToFit()
        updatedLabel.frame = NSRect(x: h, y: 29, width: updatedLabel.frame.width, height: 15)
        let badgeX = updatedLabel.frame.maxX + 10
        badgeLabel.frame = NSRect(x: badgeX, y: 29, width: max(bounds.width - h - badgeX, 1), height: 15)
    }
}

// MARK: - Banner

/// The board's file is unreadable or gone; the content below is the last good version. Fixed height
/// while shown, nothing otherwise.
final class TrackerBannerView: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 36

    let label = NSTextField(wrappingLabelWithString: "")
    private(set) var banner: TrackerBannerRow?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.bannerFill.cgColor
        label.font = TrackerTheme.metaFont
        label.textColor = TrackerTheme.text
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.refusesFirstResponder = true
        label.isSelectable = false
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    var preferredHeight: CGFloat { banner == nil ? 0 : Self.height }

    func update(_ banner: TrackerBannerRow?) {
        guard banner != self.banner else { return }
        self.banner = banner
        label.stringValue = banner?.text ?? ""
        isHidden = banner == nil
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: TrackerRowView.hPad, y: 3, width: max(bounds.width - TrackerRowView.hPad * 2, 1), height: 30)
    }
}
