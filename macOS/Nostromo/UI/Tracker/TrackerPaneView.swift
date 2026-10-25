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
/// - A hold never outlives the reader's attention (the release rule): it is also released by the
///   user collapsing a note ("less"), clearing the selection, clicking elsewhere, or the pane being
///   idle for `idleReleaseDelay` (20 s with no pointer, scroll, mouse-button or key activity in it).
///   None of those releases anything while a text selection exists, while the pointer is over a held
///   row or while a mouse button is down (a release then waits for the button to come up and happens
///   once if the conditions still hold); the idle check simply tries again one period later. The
///   exception is "less" on a note: an explicit action, it releases everything held even with the
///   pointer over a held row (that row included). "more" / "less" first clears the selection in
///   that row, so the toggle always shows.
///   Limits of the guards: the pointer guard covers held rows only, so an idle release can shift an
///   unheld row under the pointer (the viewport anchor keeps the top visible row steady); a mouse-up
///   anywhere in the pane outside the header counts as "clicking elsewhere", except on the scroller.
/// - It never takes keyboard focus on its own, never shows `Loading` over content and never
///   blanks: before the first board it shows a quiet "Waiting for the tracker…" that the board
///   replaces once.
/// - A changed row is highlighted for under a second; with Reduce Motion it is not highlighted.
final class TrackerPaneView: NSView {
    override var isFlipped: Bool { true }

    /// The focus whose board this shows (`NSView.tag` is AppKit's own Int).
    let focusTag: String

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
    private let idleReleaseDelay: TimeInterval
    private let idleSchedule: (TimeInterval, @escaping () -> Void) -> Void
    private let pointerLocation: (() -> NSPoint?)?
    private let isMouseButtonDown: () -> Bool

    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var tickTimer: Timer?
    private var isApplying = false
    private var laidOutWidth: CGFloat = -1
    private var selectedKey: String?
    /// The pane was out of any window for longer than a layout rebuild.
    private var wasAway = false
    /// Bumped by pointer, scroll and key activity in the pane; the idle check compares it.
    private var activityCount = 0
    private var idleCheckArmed = false
    private var clickMonitor: Any?
    /// A release was due while a mouse button was down; it is tried again when the button comes up.
    private var releasePending = false

    /// - Parameters:
    ///   - now: the clock relative times are drawn from.
    ///   - reduceMotion: whether to skip the change highlight.
    ///   - pasteboard: where Copy as Markdown writes.
    ///   - schedule: runs work after a delay (the highlight's end); tests pass their own.
    ///   - tickInterval: how often relative times refresh; nil for none (tests call `tick()`).
    ///   - idleReleaseDelay: how long the pane must be idle before held rows are released.
    ///   - idleSchedule: runs the idle check after a delay (separate from `schedule`); tests pass their own.
    ///   - pointerLocation: the pointer in window coordinates; nil means the window's own.
    ///   - isMouseButtonDown: whether any mouse button is down; nothing is released meanwhile.
    init(tag: String,
         store: TrackerStore = .shared,
         now: @escaping () -> Date = Date.init,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         pasteboard: NSPasteboard = .general,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         timeZone: TimeZone = .current,
         tickInterval: TimeInterval? = 30,
         idleReleaseDelay: TimeInterval = 20,
         idleSchedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         pointerLocation: (() -> NSPoint?)? = nil,
         isMouseButtonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 }) {
        self.focusTag = tag
        self.store = store
        self.now = now
        self.reduceMotion = reduceMotion
        self.pasteboard = pasteboard
        self.schedule = schedule
        self.timeZone = timeZone
        self.tickInterval = tickInterval
        self.idleReleaseDelay = idleReleaseDelay
        self.idleSchedule = idleSchedule
        self.pointerLocation = pointerLocation
        self.isMouseButtonDown = isMouseButtonDown
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
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
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
        // Plugging in a mouse switches overlay and legacy scrollers, which changes the clip's width.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.scrollView.tile()
                self?.needsLayout = true
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
        guard let board = store.board(for: focusTag) else { return }
        self.board = board
        commit(TrackerPresenter.present(board: board, now: now(), filter: filter, folds: folds, timeZone: timeZone),
               highlight: true)
    }

    /// Relative times moved on: refresh them (in place, no layout change, no highlight).
    func tick() {
        render()
    }

    /// The 30 s clock only runs while the pane can be seen: in a window, not hidden, no hidden ancestor.
    var isTickTimerRunning: Bool { tickTimer != nil }

    private func updateTickTimer() {
        let shouldRun = tickInterval != nil && window != nil && !isHiddenOrHasHiddenAncestor
        if !shouldRun {
            tickTimer?.invalidate()
            tickTimer = nil
        } else if tickTimer == nil, let tickInterval {
            let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
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

    /// The user clicked "more" or "less". A text selection in that row is cleared first (a selected
    /// row keeps its content, which would swallow the toggle). Collapsing is also an explicit release:
    /// whatever the board moved while the reader was looking folds away now.
    func toggleNote(item id: String) {
        clearSelection(inItem: id)
        if folds.expandedNotes.remove(id) == nil {
            folds.expandedNotes.insert(id)
        } else {
            deferral.releaseAll()
        }
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
        let scrollTop = scrollView.frame.minY
        let atVeryTop = clipView.bounds.minY <= 0.5
        header.update(target.header)
        banner.update(target.banner)
        strip.update(target.strip)

        let result = deferral.resolve(displayed: displayedRows, target: target,
                                      visibleKeys: visible, selectedKey: currentSelectedKey())
        presentation = target
        if deferral.hasHeld { armIdleCheck() }

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
        // The banner or the strip appearing or going pushes the scroll view's top by this much: the
        // reading position follows it, so the line being read stays where it is on screen. At the
        // very top (offset 0) there is no line being read below the fold: stay at the top.
        let chromeShift = scrollView.frame.minY - scrollTop
        let followShift = atVeryTop ? 0 : chromeShift
        if result.applyNow.isEmpty && chromeShift == 0 && contentWidth == laidOutWidth && !firstRender {
            rowsUpdatedLast = 0
            return   // nothing on screen changed (a re-check on scroll, an identical board)
        }
        layoutRowsToFit()
        let moved = Set(result.applyNow.compactMap { op -> String? in
            if case .move(let key, _) = op { return key }
            return nil
        })
        restore(anchor, renamed: result.renamed, skipping: moved, shift: followShift, firstRender: firstRender)

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
            layoutRowsToFit()
            restore(anchor, renamed: [:], skipping: [], shift: 0, firstRender: false)
        }
    }

    /// Lay the rows out at the clip's width; if that shows or hides the vertical scroller (which
    /// changes the clip's width with legacy scrollers), lay them out again at the width that results,
    /// so no later update finds them at a stale width.
    private func layoutRowsToFit() {
        layoutRows(width: contentWidth)
        scrollView.tile()
        if contentWidth != laidOutWidth { layoutRows(width: contentWidth) }
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
    ///
    /// Every row is measured, on screen or not (design contract §9: no virtualisation up to 500
    /// items). A measurement is a TextKit layout of a few lines, and a row caches its height per
    /// width, so a live divider drag costs one pass over the rows per width step; the 500-item
    /// board test (`testAFiveHundredItemBoard…`) puts a generous time budget on 30 such steps.
    /// Measuring only the rows near the viewport would leave the rows above it with guessed
    /// heights, which moves the reading anchor when they are measured later: not worth it here.
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

    /// Scroll so the anchored row is back where the reader saw it. Rows that changed their order
    /// (`skipping`) are not anchored to: following one would carry the whole viewport along with it.
    /// `shift` is how far the scroll view's top moved on screen. With no anchor the position stays,
    /// except on the first render, which starts at the top.
    private func restore(_ anchor: TrackerViewportAnchor?, renamed: [String: String], skipping: Set<String>,
                         shift: CGFloat, firstRender: Bool) {
        let frames = Dictionary(rowFrames.map { ($0.key, $0.frame) }, uniquingKeysWith: { first, _ in first })
        let maxTop = max(0, documentView.frame.height - clipView.bounds.height)
        let top: CGFloat
        if let anchor, let restored = anchor.restoredTop(frames: frames, renamed: renamed, skipping: skipping,
                                                          shift: shift, documentHeight: documentView.frame.height,
                                                          viewportHeight: clipView.bounds.height) {
            top = restored
        } else if firstRender {
            top = 0
        } else {
            top = min(max(0, clipView.bounds.minY + shift), maxTop)
        }
        guard abs(clipView.bounds.minY - top) > 0.01 || firstRender else { return }
        clipView.scroll(to: NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Keys of the rows intersecting the viewport now.
    func visibleKeys() -> Set<String> {
        guard !isHiddenOrHasHiddenAncestor else { return [] }   // a background tab holds nothing back
        let viewport = clipView.bounds
        return Set(rowFrames.filter { $0.frame.maxY > viewport.minY && $0.frame.minY < viewport.maxY }.map(\.key))
    }

    private func viewportMoved() {
        guard !isApplying, deferral.hasHeld else { return }
        activityCount &+= 1
        recommit()
    }

    // MARK: - Releasing holds

    /// Pointer, scroll or key activity in the pane: the idle period starts over.
    func registerActivity() {
        activityCount &+= 1
    }

    /// A click in the pane: it counts as activity and, with no selection and the pointer not over a
    /// held row, releases what is held.
    func registerClick() {
        registerActivity()
        releaseHeldIfQuiet()
    }

    /// Release every hold unless a text selection exists or the pointer is over a held row. While a
    /// mouse button is down nothing is released (rows would shift under a drag); the release waits
    /// for the button to come up.
    private func releaseHeldIfQuiet() {
        guard deferral.hasHeld, currentSelectedKey() == nil, !isPointerOverHeldRow else { return }
        guard !isMouseButtonDown() else {
            releasePending = true
            return
        }
        releasePending = false
        deferral.releaseAll()
        recommit()
    }

    /// While rows are held, check once per `idleReleaseDelay` whether the pane has been idle.
    private func armIdleCheck() {
        guard !idleCheckArmed else { return }
        idleCheckArmed = true
        let seen = activityCount
        idleSchedule(idleReleaseDelay) { [weak self] in self?.idleCheckFired(activityWhenArmed: seen) }
    }

    private func idleCheckFired(activityWhenArmed: Int) {
        idleCheckArmed = false
        guard deferral.hasHeld else { return }
        if activityCount == activityWhenArmed { releaseHeldIfQuiet() }
        if deferral.hasHeld { armIdleCheck() }   // activity, a selection or the pointer: try again later
    }

    /// The pointer is on a row the view is holding (its frame in the visible part of the pane).
    private var isPointerOverHeldRow: Bool {
        guard window != nil, let location = pointerLocation?() ?? window?.mouseLocationOutsideOfEventStream else {
            return false
        }
        let point = documentView.convert(location, from: nil)
        guard clipView.bounds.contains(point) else { return false }
        return deferral.held.contains { rowViews[$0.key]?.frame.contains(point) == true }
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    /// The local event monitor's entry point. `.mouseMoved` does not fire during a drag, so the
    /// button going down and every drag step count as activity here: a drag that holds still is
    /// not an idle pane.
    func observe(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inContent = bounds.contains(point) && !header.frame.contains(point)
        switch event.type {
        case .keyDown:
            if let responder = window.firstResponder as? NSView, responder.isDescendant(of: documentView) { registerActivity() }
        case .leftMouseDown, .leftMouseDragged:
            if inContent { registerActivity() }
        case .leftMouseUp:
            // A drag that began in the pane may end anywhere in the window.
            if releasePending {
                DispatchQueue.main.async { [weak self] in self?.releaseWhenButtonUp() }
            }
            guard inContent else { return }
            registerActivity()
            // The scroller is not "elsewhere": dragging its knob or clicking its track releases nothing.
            guard !isOnScroller(event) else { return }
            // After the event: a drag-select has started a selection by then.
            DispatchQueue.main.async { [weak self] in self?.registerClick() }
        default:
            guard inContent else { return }
            DispatchQueue.main.async { [weak self] in self?.registerClick() }
        }
    }

    private func isOnScroller(_ event: NSEvent) -> Bool {
        guard let scroller = scrollView.verticalScroller, !scroller.isHidden else { return false }
        return scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil))
    }

    /// The button came up after a release was held back: try it again, once.
    private func releaseWhenButtonUp() {
        guard releasePending, currentSelectedKey() == nil else { return }
        applySelectionCleared()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        registerActivity()
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
            // The selection is gone: its held content applies, and so does everything else held,
            // unless the pointer is still on a held row. Pressing the mouse in a selected row collapses
            // its selection to a caret in the middle of a gesture: nothing moves until the button is up.
            applySelectionCleared()
        }
    }

    /// The selection's hold ends now (and so does everything else held, unless the pointer is on a
    /// held row); with a mouse button down it waits for the button to come up.
    private func applySelectionCleared() {
        guard deferral.hasHeld else { return }
        guard !isMouseButtonDown() else {
            releasePending = true
            return
        }
        releasePending = false
        if !isPointerOverHeldRow { deferral.releaseAll() }
        recommit()
    }

    /// Clear the text selection in an item's row (or its `moving:` copy), without the notification
    /// path: the caller is about to change the row anyway.
    private func clearSelection(inItem id: String) {
        for key in [TrackerRow.itemKey(id), TrackerDeferral.movingPrefix + id] {
            guard let view = rowViews[key] else { continue }
            if key == selectedKey { selectedKey = nil }
            for textView in view.allTextViews where textView.hasSelection {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
    }

    // MARK: - Reopening and ticking

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTickTimer()
        if window != nil {
            installClickMonitor()
        } else if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        guard window != nil else {
            // A layout rebuild detaches the reused pane and puts it back within the same turn of
            // the run loop; only a pane still out of a window after that was really away.
            DispatchQueue.main.async { [weak self] in
                if let self, self.window == nil { self.wasAway = true }
            }
            return
        }
        if wasAway {
            wasAway = false
            reopened()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTickTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTickTimer()
        if tickTimer != nil { tick() }   // the times moved on while hidden
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
        writeToPasteboard(TrackerMarkdown.board(board))
    }

    /// A section's or an item's markdown, exactly as the file has it.
    func copyMarkdown(for row: TrackerRow) {
        guard let board else { return }
        let text: String?
        switch row.content {
        case .section(let section): text = TrackerMarkdown.section(section.id, in: board)
        default: text = row.item.flatMap { TrackerMarkdown.item($0.id, in: board) }
        }
        if let text { writeToPasteboard(text) }
    }

    private func writeToPasteboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Probes (read-only)

    /// `nostromo-app tracker-anchor`.
    func anchorSnapshot(windowIndex: Int) -> TrackerAnchorSnapshot {
        TrackerAnchorProbe.snapshot(tag: focusTag, window: windowIndex, clipBounds: clipView.bounds,
                                    documentHeight: documentView.frame.height, rows: rowFrames,
                                    held: deferral.held)
    }

    /// `nostromo-app tracker show`: what this pane shows.
    func showReport() -> [String: Any] {
        AppControlTracker.show(tag: focusTag, presentation: presentation, displayedRows: displayedRows,
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
    let committableLabel = NSTextField(labelWithString: "")
    let filterControl = NSSegmentedControl(labels: TrackerFilter.allCases.map(\.label),
                                           trackingMode: .selectOne, target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = TrackerTheme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.font = TrackerTheme.metaFont
        updatedLabel.textColor = TrackerTheme.muted
        committableLabel.font = TrackerTheme.metaFont
        committableLabel.textColor = Theme.amber
        committableLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, updatedLabel, committableLabel] {
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
        if committableLabel.stringValue != badge { committableLabel.stringValue = badge }
        committableLabel.isHidden = badge.isEmpty
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
        committableLabel.frame = NSRect(x: badgeX, y: 29, width: max(bounds.width - h - badgeX, 1), height: 15)
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
