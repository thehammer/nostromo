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
    let backgroundRow = TrackerBackgroundRow()
    /// The quiet one-line notice about an edit that did not happen (above the scroll view, like the banner).
    let notice = TrackerNoticeView()
    /// Takes keyboard focus after a mouse edit, so ⌘Z undoes it (see `focusSink`).
    let sink = TrackerFocusSink()
    let scrollView = NSScrollView()
    let clipView = TrackerClipView()
    let documentView = TrackerDocumentView()
    /// The line a drag draws between rows (an overlay: no row moves for it).
    let dropIndicator = TrackerDropIndicatorView()
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
    /// Turns the user's actions into `tracker_edit` ops, takes the answers and owns undo.
    private(set) var editing: TrackerItemEditing!
    /// The open inline editors (and the saves still waiting for their board), by item id.
    private(set) var editSessions: [String: TrackerEditSession] = [:]
    /// The open "+ Add item" fields, by section id.
    private(set) var addSessions: [String: TrackerAddSession] = [:]
    /// Names this pane on the dragging pasteboard: a drop from another pane or app is refused.
    let paneIdentity = UUID().uuidString
    /// A row of this pane is being dragged: the pane changes nothing until it ends.
    private(set) var isDragging = false
    private var renderDeferredByDrag = false
    /// The "Removed “…”" banner's title (nil when it is not showing).
    private var removalTitle: String?
    private var removalGeneration = 0
    /// How long "Removed … Undo" stays in the notice slot.
    static let removalBannerLifetime: TimeInterval = 10
    /// The open conflict or sensitive-data popover, if any.
    private(set) var activePopover: TrackerConflictPopover?
    /// The daemon takes pane edits (both features advertised): edit controls exist only then.
    private(set) var editEnabled = false

    /// Render probe (`tracker show`, PRD criterion 20): bumped by every render that changed a row.
    private(set) var renderGeneration = 0
    /// How many row views the last render built or updated.
    private(set) var rowsUpdatedLast = 0

    /// The focus's REPL pane, found through the focus view's leaf map (`DynamicFocusView` installs it);
    /// nil while it has none, which disables the summary row.
    var replProvider: () -> TrackerBackgroundListOpening? = { nil } {
        didSet { render() }   // the row is enabled while there is a REPL to open it from
    }

    private let store: TrackerStore
    private let decisions: TrackerDecisionProviding
    private let approvals: ApprovalStore
    private let background: BackgroundTaskStore
    private let actions: TrackerWaitingActions
    private let now: () -> Date
    private let reduceMotion: () -> Bool
    private let pasteboard: NSPasteboard
    /// Asks the daemon to open link `index` of an item (PR, ticket and file chips): `(tag, item id, index)`.
    private let openLinkInDaemon: (String, String, Int) -> Void
    /// Opens a URL chip in the browser (injected; tests record the call).
    private let openURL: (URL) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let timeZone: TimeZone
    private let tickInterval: TimeInterval?
    private let idleReleaseDelay: TimeInterval
    private let idleSchedule: (TimeInterval, @escaping () -> Void) -> Void
    private let pointerLocation: (() -> NSPoint?)?
    private let isMouseButtonDown: () -> Bool
    private let editSupported: () -> Bool
    /// The board each displayed item row's content came from. A row held back (a text selection, an open
    /// editor) keeps the version it was drawn from, so an edit of it names the version the user saw.
    private var rowBases: [String: TrackerBase] = [:]
    /// A restored item's new id: the pane follows it (scroll, expansion) once its row is on screen.
    private var followingItem: (id: String, version: UInt64)?
    /// Items the user's own edit changed: they are not highlighted when the confirming board arrives.
    private var ownEdits: [String: UInt64] = [:]
    /// Undo for text typed in an inline editor (never the pane's edit undo, never the window's).
    private let editorTextUndo = UndoManager()

    private var backgroundSummary = TrackerBackgroundSummary(chip: .hidden)
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Watches the window's first responder so a pending editor's focus request is forgotten once focus goes
    /// to something outside the pane's rows (the composer).
    private var responderObservation: NSKeyValueObservation?
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
    ///   - pasteboard: where Copy as Markdown and a command block's Copy write.
    ///   - schedule: runs work after a delay (the highlight's end); tests pass their own.
    ///   - tickInterval: how often relative times refresh; nil for none (tests call `tick()`).
    ///   - idleReleaseDelay: how long the pane must be idle before held rows are released.
    ///   - idleSchedule: runs the idle check after a delay (separate from `schedule`); tests pass their own.
    ///   - pointerLocation: the pointer in window coordinates; nil means the window's own.
    ///   - isMouseButtonDown: whether any mouse button is down; nothing is released meanwhile.
    ///   - editSupported: whether the daemon takes pane edits (the app passes its client's features); the
    ///     pane is read-only while this is false.
    ///   - editSender / editSchedule: where `tracker_edit` frames go, and the clock for their 5 s timeout.
    init(tag: String,
         store: TrackerStore = .shared,
         decisions: TrackerDecisionProviding = DecisionPresenter.shared,
         approvals: ApprovalStore = .shared,
         background: BackgroundTaskStore = .shared,
         actions: TrackerWaitingActions = .live,
         now: @escaping () -> Date = Date.init,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         pasteboard: NSPasteboard = .general,
         openLinkInDaemon: @escaping (String, String, Int) -> Void = { tag, item, index in
             AppStore.shared.client.sendTrackerOpenLink(tag: tag, itemId: item, linkIndex: index)
         },
         openURL: @escaping (URL) -> Void = { ActivationAudit.note("tracker-link:open-external-url"); NSWorkspace.shared.open($0) },
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
         isMouseButtonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons != 0 },
         editSupported: @escaping () -> Bool = { false },
         editSender: @escaping TrackerItemEditing.Sender = { tag, requestId, baseVersion, baseEpoch, ops in
             AppStore.shared.client.sendTrackerEdit(tag: tag, requestId: requestId, baseVersion: baseVersion,
                                                    baseEpoch: baseEpoch, ops: ops)
         },
         editSchedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.focusTag = tag
        self.store = store
        self.decisions = decisions
        self.approvals = approvals
        self.background = background
        self.actions = actions
        self.now = now
        self.reduceMotion = reduceMotion
        self.pasteboard = pasteboard
        self.openLinkInDaemon = openLinkInDaemon
        self.openURL = openURL
        self.schedule = schedule
        self.timeZone = timeZone
        self.tickInterval = tickInterval
        self.idleReleaseDelay = idleReleaseDelay
        self.idleSchedule = idleSchedule
        self.pointerLocation = pointerLocation
        self.isMouseButtonDown = isMouseButtonDown
        self.editSupported = editSupported
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        editing = TrackerItemEditing(
            tag: tag, results: store.editResults.eraseToAnyPublisher(), send: editSender, schedule: editSchedule,
            shownBase: { [weak self] ids in self?.shownBase(forItems: ids) ?? TrackerBase(version: 0, epoch: nil) },
            itemExists: { [weak self] id in self?.wireItem(id) != nil })
        editing.isCommandItem = { [weak self] id in self?.wireItem(id)?.kind == .command }
        editing.isWithheldItem = { [weak self] id in self?.wireItem(id)?.commandWithheld == true }
        editing.onNotice = { [weak self] text in self?.applyNotice(text ?? self?.openEditorRefusal()) }
        editing.onLookAgain = { [weak self] in self?.lookAgain() }
        editing.onConfirmed = { [weak self] ids, version in
            for id in ids { self?.ownEdits[id] = version }
        }
        editing.onRemoved = { [weak self] title in self?.removalChanged(title) }
        editing.itemSnapshot = { [weak self] id in self?.snapshot(of: id) }
        editing.itemPlace = { [weak self] id in self?.place(of: id) }
        editing.resolvePlace = { [weak self] hint in
            self?.placeNow(hint) ?? TrackerMoveDestination(section: hint.section, after: hint.above)
        }
        editing.boardVersion = { [weak self] in self?.board?.version ?? 0 }
        setUp()
        let myTag = tag
        store.changes
            .filter { $0 == myTag }
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        // Anything else that can wait on the person changes the strip and the summary row. A decision
        // answered elsewhere leaves within one delivery of its store; approvals and background work
        // arrive coalesced by their own stores (BA's at most 4 a second).
        decisions.decisionsChanged
            .filter { $0 == myTag }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        approvals.changes
            .filter { $0 == myTag }
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        background.changes
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

    /// The pane's own undo (tick, status, titles, details, conflict choices), never the window's, so the
    /// composer's typing undo is untouched. Text typed in an inline editor has its own undo.
    override var undoManager: UndoManager? {
        if let editor = window?.firstResponder as? NSTextView, editor.isDescendant(of: self) { return editorTextUndo }
        return editing.undoManager
    }

    // MARK: - Setup

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.background.cgColor

        header.onFilter = { [weak self] filter in self?.setFilter(filter) }
        header.onCopyBoard = { [weak self] in self?.copyBoardMarkdown() }
        header.onConflictChip = { [weak self] anchor, fromKeyboard in self?.showBoardConflicts(anchor: anchor, fromKeyboard: fromKeyboard) }
        sink.pane = self
        sink.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        addSubview(sink)
        addSubview(header)
        addSubview(banner)
        addSubview(notice)
        addSubview(strip)
        addSubview(backgroundRow)
        strip.onSelect = { [weak self] entry in self?.select(entry) }
        backgroundRow.onClick = { [weak self] in self?.openBackgroundList() }

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
        documentView.pane = self
        documentView.registerForDraggedTypes([TrackerRowView.dragType])
        documentView.addSubview(dropIndicator)
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
        // A drag changes nothing on screen: the board is shown when it ends.
        if isDragging {
            renderDeferredByDrag = true
            return
        }
        guard let board = store.board(for: focusTag) else { return }
        self.board = board
        syncEditing()
        closeSettledSessions()
        let list = background.list(for: focusTag)
        backgroundSummary = TrackerBackgroundSummary(list: list)
        let sources = TrackerWaitingSources.make(
            tag: focusTag,
            approvalsPending: approvals.pendingCount(tag: focusTag),
            decisions: decisions.pendingDecisions(tag: focusTag),
            tasks: background.state(for: focusTag)?.allTasks ?? [],
            seenEndedAtMs: background.seenMark(tag: focusTag))
        commit(TrackerPresenter.present(board: board, now: now(), filter: filter, folds: folds, sources: sources,
                                        timeZone: timeZone, editSupported: editEnabled),
               highlight: true)
        editing.boardApplied(version: board.version)
        refreshRowsOfLateOks()
        settleAddSessions()
        followIfReady()
    }

    /// A late ok that beat its board: once the board shows the saved version, the session's row is that item.
    private func refreshRowsOfLateOks() {
        guard let version = board?.version else { return }
        for (id, var session) in editSessions {
            if let needed = session.rowRefreshVersion, version >= needed, let saved = newestItem(id) {
                session.row = saved
                session.rowRefreshVersion = nil
                editSessions[id] = session
            }
        }
    }

    /// A click on a strip entry: go to what it names. A user act; nothing here answers anything.
    func select(_ entry: TrackerWaitingEntry) {
        switch entry.target {
        case .none:
            break
        case .boardItem(let id):
            scrollToItem(id)
        case .decision(let requestId):
            decisions.showDecision(requestId: requestId)
        case .approvals(let tag):
            actions.showApprovals(tag)
        case .backgroundTask:
            openBackgroundList()
        }
    }

    /// Scroll so the item's row is at the top (the filter goes to All when it hides the item).
    func scrollToItem(_ id: String) {
        let key = TrackerRow.itemKey(id)
        if rowViews[key] == nil, filter != .all { setFilter(.all) }
        guard let view = rowViews[key] else { return }
        let maxY = max(documentView.frame.height - clipView.bounds.height, 0)
        clipView.scroll(to: NSPoint(x: 0, y: min(max(view.frame.minY, 0), maxY)))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// The summary row's click: the focus's Background activity popover, from its input bar.
    func openBackgroundList() {
        replProvider()?.showBackgroundList()
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
        // A dirty details editor saves first (the focus-loss rule), then the row folds.
        if let session = editSessions[id], session.kind == .details, session.phase == .editing {
            rowViews[TrackerRow.itemKey(id)]?.commitEditor()
        }
        clearSelection(inItem: id)
        if folds.expandedItems.remove(id) == nil {
            folds.expandedItems.insert(id)
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
        header.update(target.header, showsConflicts: editEnabled)
        banner.update(target.banner)
        strip.update(target.strip)
        backgroundRow.update(backgroundSummary, enabled: replProvider() != nil)

        let result = deferral.resolve(displayed: displayedRows, target: target,
                                      visibleKeys: visible, heldKeys: heldKeys(),
                                      exempt: Set(editing.exemptItemIds.map { TrackerRow.itemKey($0) }))
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
                documentView.addSubview(view, positioned: .below, relativeTo: dropIndicator)
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
                if !row.differsOnlyInTime(from: old), !row.differsOnlyInFold(from: old), !renamedInPlace,
                   !isOwnConfirmedEdit(row) {
                    changed.append(view)
                }
            case .move:
                break   // order comes from the rows themselves
            }
        }
        displayedRows = result.rows
        noteRowBases(target: target)
        if let version = board?.version { ownEdits = ownEdits.filter { $0.value > version } }

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
        let view = TrackerRowView(row: row, commandPasteboard: pasteboard)
        view.onToggleDone = { [weak self] section in self?.toggleDoneGroup(section: section) }
        view.onToggleNote = { [weak self] id in self?.toggleNote(item: id) }
        view.onToggleLog = { [weak self] in self?.toggleLog() }
        view.onCopyMarkdown = { [weak self] row in self?.copyMarkdown(for: row) }
        view.onOpenLink = { [weak self] item, action in self?.openLink(item: item, action: action) }
        view.moveOptions = { [weak self] id in self?.moveOptions(for: id) ?? TrackerMoveOptions(canUp: false, canDown: false, sections: []) }
        view.dragPaneIdentity = paneIdentity
        view.editingEnabled = editEnabled
        view.onMove = { [weak self] id, request in self?.moveItem(id, request) }
        view.onRemove = { [weak self] id in self?.removeItem(id) }
        view.onBeginAdd = { [weak self] section in self?.beginAdd(section: section) }
        view.onCommitAdd = { [weak self] section, typed, byReturn in self?.commitAdd(section: section, typed: typed, byReturn: byReturn) }
        view.onCancelAdd = { [weak self] section in self?.cancelAdd(section: section) }
        view.onDragBegan = { [weak self] in self?.dragBegan() }
        view.onDragEnded = { [weak self] in self?.dragEnded() }
        view.onTick = { [weak self] id in self?.tick(item: id) }
        view.onSetStatus = { [weak self] id, wire in self?.setStatus(item: id, to: wire) }
        view.onBeginEdit = { [weak self] id, kind in self?.beginEdit(item: id, kind: kind) }
        view.onCommitEdit = { [weak self] id, kind, text in self?.commitEdit(item: id, kind: kind, text: text) }
        view.onCancelEdit = { [weak self] id, kind in self?.cancelEdit(item: id, kind: kind) }
        view.onFocusPendingEditor = { [weak self] id in self?.editSessions[id]?.editorWantsFocus = true }
        view.onFocusLeftPendingEditor = { [weak self] id in
            if self?.editSessions[id]?.phase == .saving { self?.editSessions[id]?.editorWantsFocus = false }
        }
        view.onShowConflict = { [weak self] id, anchor, fromKeyboard in
            self?.showConflicts(item: id, anchor: anchor, fromKeyboard: fromKeyboard)
        }
        view.onReviewSensitive = { [weak self] id, anchor, fromKeyboard in
            self?.reviewSensitive(item: id, anchor: anchor, fromKeyboard: fromKeyboard)
        }
        view.onEditorResized = { [weak self] in self?.relayoutRows() }
        return view
    }

    /// A link chip was clicked. The daemon opens PR, ticket and file links as a `show` (the detail
    /// region's tab; never the transcript); a URL goes to the browser. The pane itself does not move.
    func openLink(item: String, action: TrackerLinkAction) {
        switch action {
        case .openInPane(let index): openLinkInDaemon(focusTag, item, index)
        case .openURL(let url): openURL(url)
        case .inert: break
        }
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

    /// Header, banner, strip and background row stacked at the top; the scroll view takes the rest.
    private func layoutChrome() {
        let width = bounds.width
        var y: CGFloat = 0
        header.frame = NSRect(x: 0, y: y, width: width, height: TrackerHeaderView.height)
        y += TrackerHeaderView.height
        let bannerHeight = banner.preferredHeight
        banner.frame = NSRect(x: 0, y: y, width: width, height: bannerHeight)
        y += bannerHeight
        let noticeHeight = notice.preferredHeight
        notice.frame = NSRect(x: 0, y: y, width: width, height: noticeHeight)
        y += noticeHeight
        let stripHeight = strip.preferredHeight
        strip.frame = NSRect(x: 0, y: y, width: width, height: stripHeight)
        y += stripHeight
        let backgroundHeight = backgroundRow.preferredHeight
        backgroundRow.frame = NSRect(x: 0, y: y, width: width, height: backgroundHeight)
        y += backgroundHeight
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

    // MARK: - Editing

    /// The rows the deferral keeps as they are: the one holding a text selection, and every row with an
    /// open editor or a save still waiting for its board.
    private func heldKeys() -> Set<String> {
        var keys = Set(editSessions.keys.map { TrackerRow.itemKey($0) })
        if let selected = currentSelectedKey() { keys.insert(selected) }
        return keys
    }

    /// The daemon's board item `id`, whatever the view shows.
    private func wireItem(_ id: String) -> TrackerItemWire? {
        for node in board?.nodes ?? [] {
            if case .item(let item) = node, item.id == id { return item }
        }
        return nil
    }

    /// The item row the view shows for `id` (not a stub).
    private func shownItem(_ id: String) -> TrackerItemRow? {
        guard let content = rowViews[TrackerRow.itemKey(id)]?.row.content, case .item(let item) = content else { return nil }
        return item
    }

    /// The item as the newest board has it (a row held back, or one with an open editor, still shows an older one).
    private func newestItem(_ id: String) -> TrackerItemRow? {
        let key = TrackerRow.itemKey(id)
        guard let row = presentation?.rows.first(where: { $0.key == key }), case .item(let item) = row.content else { return nil }
        return item
    }

    /// The board as it is now.
    private func boardBase() -> TrackerBase {
        TrackerBase(version: board?.version ?? 0, epoch: board?.epoch.isEmpty == false ? board?.epoch : nil)
    }

    /// The board the row for `id` was drawn from (the newest board unless the row is held back).
    private func base(forItem id: String) -> TrackerBase {
        rowBases[TrackerRow.itemKey(id)] ?? boardBase()
    }

    /// The version of the board the rows for `ids` show (the oldest, when they differ); the newest board for
    /// rows not on screen. An undo is made against what the user sees, not against a board they have not seen.
    private func shownBase(forItems ids: [String]) -> TrackerBase {
        let bases = ids.compactMap { rowBases[TrackerRow.itemKey($0)] }
        return bases.min { $0.version < $1.version } ?? boardBase()
    }

    /// A row shows the board's current content unless the selection hold or an open editor keeps it
    /// back: only those keep an older base. A row the move-deferral merely keeps in place (a ticked item
    /// on its way to Done) already shows the new content, so it takes the board's current version.
    private func noteRowBases(target: TrackerPresentation) {
        let now = boardBase()
        let targets = Dictionary(target.rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let held = heldKeys()
        var next: [String: TrackerBase] = [:]
        for row in displayedRows where row.item != nil {
            let showsTheBoard = targets[row.key].map {
                $0 == row || row.differsOnlyInTime(from: $0) || row.differsOnlyInFold(from: $0)
            } ?? false   // no row for it in the board's view (folded away or gone): what it shows is older
            if held.contains(row.key), !showsTheBoard {
                next[row.key] = rowBases[row.key] ?? now
            } else {
                next[row.key] = now
            }
        }
        rowBases = next
    }

    /// The daemon says the view is out of date: show the board as it is now. Nothing stays held back: the
    /// reader asked to look again, so a text selection is let go too (the row it held shows the new content).
    func lookAgain() {
        for view in rowViews.values {
            for textView in view.allTextViews where textView.hasSelection {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        deferral.releaseAll()
        render()
    }

    /// Edit controls follow the daemon's features: on or off for every row at once.
    private func syncEditing() {
        let enabled = editSupported()
        guard enabled != editEnabled else { return }
        editEnabled = enabled
        for view in rowViews.values { view.editingEnabled = enabled }
        relayoutRows()
    }

    /// `item`'s own confirmed edit is not a change from elsewhere: no highlight.
    private func isOwnConfirmedEdit(_ row: TrackerRow) -> Bool {
        guard let id = row.item?.id else { return false }
        if editing.inFlightItemIds.contains(id) { return true }
        if let version = ownEdits[id], (board?.version ?? 0) >= version { return true }
        return false
    }

    func tick(item id: String) {
        guard editEnabled, let item = shownItem(id) else { return }
        userActed()
        editing.tick(item, base: base(forItem: id))
    }

    func setStatus(item id: String, to wire: String) {
        guard editEnabled, let item = shownItem(id) else { return }
        userActed()
        editing.setStatus(item, to: wire, base: base(forItem: id))
    }

    /// A mouse edit makes the sink first responder (so ⌘Z undoes it); a key press on a control in the
    /// pane keeps the focus it has. A tracker update never gets here.
    private func userActed() {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: documentView) { return }
        focusSink()
    }

    /// The pane's focus sink takes first responder; clicking back in the composer gives it back its text and selection.
    func focusSink() {
        guard let window else { return }
        sink.allowsFocus = true
        window.makeFirstResponder(sink)
        sink.allowsFocus = false
    }

    func performUndo() {
        let manager = editing.undoManager
        guard manager.canUndo else { return }
        manager.undo()
    }

    func performRedo() {
        let manager = editing.undoManager
        guard manager.canRedo else { return }
        manager.redo()
    }

    /// Open the title or details editor of an item (a double-click, the menu, the actions line or VoiceOver).
    /// Details first expand the row, and it stays expanded.
    func beginEdit(item id: String, kind: TrackerEditKind) {
        guard editEnabled, shownItem(id) != nil else { return }
        let key = TrackerRow.itemKey(id)
        if editSessions[id] != nil {
            rowViews[key]?.focusEditor()
            return
        }
        let prior = Self.focusOwner(window?.firstResponder)
        let role = rowViews[key]?.focusedControlRole()
        if kind == .details, !folds.expandedItems.contains(id) {
            clearSelection(inItem: id)
            folds.expandedItems.insert(id)
            render()
        }
        guard let view = rowViews[key], case .item(let current) = view.row.content else { return }
        let (prefill, boundLine) = Self.prefill(kind, for: current)
        editSessions[id] = TrackerEditSession(kind: kind, base: base(forItem: id), original: prefill, row: current,
                                              priorResponder: prior, priorRole: role)
        view.beginEditor(kind, text: prefill, boundLine: boundLine)
        relayoutRows()
    }

    /// The control that owns the field editor a text field is being edited in (the editor itself goes away
    /// when editing ends); any other responder is its own owner.
    private static func focusOwner(_ responder: NSResponder?) -> NSResponder? {
        if let text = responder as? NSTextView, text.isFieldEditor, let owner = text.delegate as? NSView { return owner }
        return responder
    }

    /// What an editor opens with: the raw title, or the raw body (for a legacy item the text after the title,
    /// a blank line, then the note; for a bound item without its source-owned first line).
    static func prefill(_ kind: TrackerEditKind, for item: TrackerItemRow) -> (text: String, boundLine: String?) {
        switch kind {
        case .title:
            return (TrackerTitle.editableTitle(text: item.editText), nil)
        case .details:
            var note = item.editNote ?? ""
            var boundLine: String?
            if item.bound != nil {
                let parts = note.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                boundLine = parts.first.map(String.init)
                note = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            }
            let body = [TrackerTitle.rawRest(text: item.editText), note].compactMap { $0 }.filter { !$0.isEmpty }
            return (body.joined(separator: "\n\n"), boundLine)
        }
    }

    /// Return, ⌘Return or focus loss: save if the text changed, else close.
    func commitEdit(item id: String, kind: TrackerEditKind, text: String) {
        guard var session = editSessions[id], session.kind == kind, session.phase == .editing else { return }
        let key = TrackerRow.itemKey(id)
        let view = rowViews[key]
        switch kind {
        case .title:
            let typed = TrackerTitle.normalizedTitle(text)
            if typed.isEmpty {
                closeSession(id)
                restorePriorFocus(session)
                editing.showNotice("A title can't be empty")
                render()
                return
            }
            if typed == session.original { cancelEdit(item: id, kind: kind); return }
        case .details:
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == session.original.trimmingCharacters(in: .whitespacesAndNewlines) {
                cancelEdit(item: id, kind: kind)
                return
            }
        }
        session.phase = .saving
        session.sentText = text
        session.refusal = nil
        editSessions[id] = session
        applyNotice(editing.notice ?? openEditorRefusal())
        view?.setEditorPending(true)
        restorePriorFocus(session)
        // Whether the pending editor itself holds focus now (focus did not go back to what had it before); a
        // later try to focus it while it is pending sets this too.
        session.editorWantsFocus = view?.editorOwnsFocus ?? false
        editSessions[id] = session
        let done: (TrackerItemEditing.Outcome) -> Void = { [weak self] outcome in self?.editFinished(id, outcome) }
        switch kind {
        case .title: editing.saveTitle(session.row, typed: text, base: session.base, completion: done)
        case .details: editing.saveDetails(session.row, typed: text, base: session.base, completion: done)
        }
    }

    /// Esc: nothing is sent.
    func cancelEdit(item id: String, kind: TrackerEditKind) {
        guard let session = editSessions[id], session.kind == kind, session.phase == .editing else { return }
        closeSession(id)
        restorePriorFocus(session)
        restoreRoleFocus(session)
        render()
    }

    private func editFinished(_ id: String, _ outcome: TrackerItemEditing.Outcome) {
        guard var session = editSessions[id] else { return }
        switch outcome {
        case .saved(let version, _):
            session.refusal = nil
            let view = rowViews[TrackerRow.itemKey(id)]
            if let sent = session.sentText, let typedNow = view?.editorText, typedNow != sent {
                // A late answer to a send that timed out, and the user has typed since: their newer text stays
                // in the editor as a fresh edit from what was saved.
                session.phase = .editing
                session.original = sent
                session.base = TrackerBase(version: version, epoch: boardBase().epoch)
                session.sentText = nil
                // The next save and its undo start from what was saved. If the board has not reached that
                // version yet (the ok beat its board), the row is refreshed when it does.
                if (board?.version ?? 0) >= version, let saved = newestItem(id) {
                    session.row = saved
                    session.rowRefreshVersion = nil
                } else {
                    session.rowRefreshVersion = version
                }
                editSessions[id] = session   // the editor is already open and editable: nothing to reopen
            } else {
                session.phase = .awaiting(version)
                editSessions[id] = session
                if closeSettledSessions() { render() }
            }
        case .failed(let message), .timedOut(let message):
            // The typed text is still in the editor: it opens up again, without taking focus, and the
            // reason stays on screen for as long as the editor is open.
            session.phase = .editing
            session.refusal = message
            editSessions[id] = session
            let view = rowViews[TrackerRow.itemKey(id)]
            view?.setEditorPending(false)
            // A backstop: if the editor had focus when the save started and the window is left holding it,
            // focus goes back to the editor. Never when the user had focus elsewhere.
            if session.editorWantsFocus, let window, window.firstResponder === window { view?.focusEditor() }
        }
        applyNotice(editing.notice ?? openEditorRefusal())
    }

    /// Why an editor that is open again could not save: kept on screen after the notice's own time is up.
    private func openEditorRefusal() -> String? {
        editSessions.sorted { $0.key < $1.key }.first { $0.value.phase == .editing && $0.value.refusal != nil }?.value.refusal
    }

    /// Close the editors whose save the board now shows (the board's version reached the result's).
    @discardableResult
    private func closeSettledSessions() -> Bool {
        guard let version = board?.version else { return false }
        var closed = false
        for (id, session) in editSessions {
            if case .awaiting(let needed) = session.phase, version >= needed {
                closeSession(id)
                restoreRoleFocus(session)
                closed = true
            }
        }
        return closed
    }

    private func closeSession(_ id: String) {
        editSessions.removeValue(forKey: id)
        rowViews[TrackerRow.itemKey(id)]?.endEditor()
        applyNotice(editing.notice ?? openEditorRefusal())
    }

    /// Focus goes back to whatever had it before the editor opened, unless the user has put it somewhere else.
    private func restorePriorFocus(_ session: TrackerEditSession) {
        restorePriorFocus(responder: session.priorResponder)
    }

    private func restorePriorFocus(responder: NSResponder?) {
        guard let window else { return }
        let current = window.firstResponder
        let editorHasFocus = current === window
            || ((current as? NSView).map { $0.isDescendant(of: documentView) } ?? false)
        guard editorHasFocus, let prior = responder as? NSView, prior.window === window,
              !prior.isDescendant(of: documentView) else { return }
        window.makeFirstResponder(prior)
    }

    /// A control of the row that had focus before the editor opened gets it back, on the rebuilt row.
    private func restoreRoleFocus(_ session: TrackerEditSession) {
        guard let role = session.priorRole, let window else { return }
        let current = window.firstResponder
        guard current === window || (current as? NSView)?.isDescendant(of: documentView) != false else { return }
        rowViews[TrackerRow.itemKey(session.row.id)]?.focusControl(role)
    }

    /// The editor state of each item the view has an editor or pending save for (`tracker show`).
    private func editingStates() -> [String: String] {
        editSessions.mapValues { session in
            session.phase == .editing ? session.kind.rawValue : "pending"
        }
    }

    // MARK: Structure: add, move, remove

    /// "+ Add item" was activated: its row becomes a title field with focus. Focus goes back to what had it
    /// when the field closes.
    func beginAdd(section: String) {
        guard editEnabled, let view = rowViews[TrackerRow.addKey(section)] else { return }
        if addSessions[section] == nil {
            addSessions[section] = TrackerAddSession(priorResponder: Self.focusOwner(window?.firstResponder))
        }
        view.beginAddField()
    }

    /// Return, or focus leaving the field. Text creates an item (and, after Return, the field stays open and
    /// empty for the next one); an empty field creates nothing (and closes when focus left).
    func commitAdd(section: String, typed: String, byReturn: Bool) {
        guard var session = addSessions[section], !session.inFlight else { return }
        let view = rowViews[TrackerRow.addKey(section)]
        let title = TrackerTitle.normalizedTitle(typed)
        guard !title.isEmpty else {
            if byReturn { view?.reopenAddField() } else { endAdd(section, restoreFocus: false) }
            return
        }
        let fitted = TrackerTitle.fitScalars(title)
        session.inFlight = true
        session.closeAfter = !byReturn
        session.sentText = typed
        session.awaiting = nil
        addSessions[section] = session
        view?.setAddPending(true)
        let after = TrackerMoves.lastItem(in: section, rows: displayedRows, filter: filter)
        editing.add(section: section, title: fitted.title, body: fitted.overflow, after: after, base: boardBase()) {
            [weak self] outcome in self?.addFinished(section, outcome)
        }
    }

    /// Esc: nothing is sent and the field closes.
    func cancelAdd(section: String) {
        guard let session = addSessions[section], !session.inFlight else { return }
        endAdd(section, restoreFocus: true)
    }

    private func addFinished(_ section: String, _ outcome: TrackerItemEditing.Outcome) {
        guard var session = addSessions[section] else { return }
        switch outcome {
        case .saved(let version, _):
            session.awaiting = version
            addSessions[section] = session
            settleAddSessions()
        case .failed, .timedOut:
            // The text is still in the field: it opens up again and the notice says why.
            session.inFlight = false
            addSessions[section] = session
            rowViews[TrackerRow.addKey(section)]?.setAddPending(false)
        }
    }

    /// The board that shows a created item is on screen: the field is empty for the next one, or closes.
    private func settleAddSessions() {
        guard let version = board?.version else { return }
        for (section, session) in addSessions {
            guard let needed = session.awaiting, version >= needed else { continue }
            if session.closeAfter {
                endAdd(section, restoreFocus: false)
                continue
            }
            var next = session
            next.inFlight = false
            next.awaiting = nil
            addSessions[section] = next
            guard let view = rowViews[TrackerRow.addKey(section)] else {
                addSessions.removeValue(forKey: section)
                continue
            }
            if view.addFieldText == session.sentText { view.resetAddField() } else { view.setAddPending(false) }
        }
    }

    private func endAdd(_ section: String, restoreFocus: Bool) {
        guard let session = addSessions.removeValue(forKey: section) else { return }
        rowViews[TrackerRow.addKey(section)]?.endAddField()
        if restoreFocus { restorePriorFocus(responder: session.priorResponder) }
    }

    /// What the Move menu, VoiceOver and the context menu offer for an item.
    func moveOptions(for id: String) -> TrackerMoveOptions {
        TrackerMoveOptions(
            canUp: TrackerMoves.up(id, rows: displayedRows, filter: filter) != nil,
            canDown: TrackerMoves.down(id, rows: displayedRows, filter: filter) != nil,
            sections: TrackerMoves.otherSections(of: id, rows: displayedRows, filter: filter).map { (id: $0.id, title: $0.title) })
    }

    /// Up or down past the next shown item, or to the end of another section.
    func moveItem(_ id: String, _ request: TrackerMoveRequest) {
        guard editEnabled, shownItem(id) != nil else { return }
        let destination: TrackerMoveDestination?
        switch request {
        case .up: destination = TrackerMoves.up(id, rows: displayedRows, filter: filter)
        case .down: destination = TrackerMoves.down(id, rows: displayedRows, filter: filter)
        case .toSection(let section): destination = TrackerMoves.toSection(section)
        }
        guard let destination else { return }
        userActed()
        editing.move(id, to: destination, base: base(forItem: id))
    }

    /// Remove an item. No dialog: the banner offers Undo for 10 s and ⌘Z keeps it for longer.
    func removeItem(_ id: String) {
        // Not while its editor is open or its edit is being saved: the edit would land on a removed item.
        guard editEnabled, shownItem(id) != nil, editSessions[id] == nil else { return }
        userActed()
        editing.remove(id, base: base(forItem: id))
    }

    /// The banner's Undo button.
    func undoRemoval() {
        userActed()
        editing.undoLatestRemoval()
    }

    private func removalChanged(_ title: String?) {
        removalGeneration += 1
        let generation = removalGeneration
        removalTitle = title.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 }
        applyNotice(editing.notice ?? openEditorRefusal())
        guard let title else { return }
        let spoken = "Removed \(title). Undo available."
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: spoken, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        schedule(Self.removalBannerLifetime) { [weak self] in
            guard let self, self.removalGeneration == generation else { return }
            self.removalTitle = nil
            self.applyNotice(self.editing.notice ?? self.openEditorRefusal())
        }
    }

    /// An item's exact markdown and place, from the board on screen (what Undo puts back).
    private func snapshot(of id: String) -> TrackerItemSnapshot? {
        guard let board, let source = TrackerMarkdown.item(id, in: board), let place = place(of: id) else { return nil }
        let title = shownItem(id)?.title ?? newestItem(id)?.title ?? wireItem(id)?.text ?? ""
        return TrackerItemSnapshot(title: title, source: source, place: place)
    }

    /// The section and both neighbours an item has in the rows on screen.
    private func place(of id: String) -> TrackerPlaceHint? {
        guard let section = shownItem(id)?.sectionId ?? newestItem(id)?.sectionId ?? wireItem(id)?.section else { return nil }
        return TrackerMoves.hint(of: id, rows: displayedRows, filter: filter, fallbackSection: section)
    }

    /// The place `hint` means on the board as it is now: a neighbour counts only while the daemon's newest
    /// board still has it in that section (the rows on screen may be holding back a change).
    private func placeNow(_ hint: TrackerPlaceHint) -> TrackerMoveDestination {
        TrackerMoves.place(hint, rows: displayedRows, filter: filter) { [weak self] id, section in
            self?.wireItem(id)?.section == section
        }
    }

    // MARK: Dragging

    /// A row of this pane started to be dragged: nothing changes on screen until it ends.
    func dragBegan() {
        isDragging = true
    }

    func dragEnded() {
        isDragging = false
        hideDropIndicator()
        guard renderDeferredByDrag else { return }
        renderDeferredByDrag = false
        render()
    }

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = TrackerRowView.dragPayload(info.draggingPasteboard) else {
            hideDropIndicator()
            return []
        }
        return dragMoved(payload: payload, at: documentView.convert(info.draggingLocation, from: nil))
    }

    func dragExited() {
        hideDropIndicator()
    }

    func performDrop(_ info: NSDraggingInfo) -> Bool {
        guard let payload = TrackerRowView.dragPayload(info.draggingPasteboard) else { return false }
        return dragDropped(payload: payload, at: documentView.convert(info.draggingLocation, from: nil))
    }

    /// The pointer is over `point` (document coordinates) with a dragged item: draw where it would land.
    func dragMoved(payload: (id: String, pane: String), at point: NSPoint) -> NSDragOperation {
        guard let drop = dropTarget(for: payload, at: point) else {
            hideDropIndicator()
            return []
        }
        showDropIndicator(drop.indicator)
        return .move
    }

    /// The item was dropped at `point`: the move is sent (nothing else changes until the daemon's board arrives).
    func dragDropped(payload: (id: String, pane: String), at point: NSPoint) -> Bool {
        defer { hideDropIndicator() }
        guard let drop = dropTarget(for: payload, at: point) else { return false }
        // No `userActed()`: a drop does not take the keyboard from the composer (the pane keeps whatever focus
        // it already had), so typing goes on. ⌘Z after a drop is the composer's own while it has focus.
        editing.move(payload.id, to: drop.destination, base: base(forItem: payload.id))
        return true
    }

    private func dropTarget(for payload: (id: String, pane: String), at point: NSPoint) -> TrackerDrop? {
        guard editEnabled, payload.pane == paneIdentity, shownItem(payload.id) != nil,
              let row = displayedRows.first(where: { rowViews[$0.key]?.frame.contains(point) == true }),
              let view = rowViews[row.key] else { return nil }
        return TrackerMoves.drop(payload.id, over: row.key, lowerHalf: point.y > view.frame.midY,
                                 rows: displayedRows, filter: filter)
    }

    private func showDropIndicator(_ indicator: TrackerDrop.Indicator) {
        let key: String, below: Bool
        switch indicator {
        case .above(let rowKey): (key, below) = (rowKey, false)
        case .below(let rowKey): (key, below) = (rowKey, true)
        }
        guard let frame = rowViews[key]?.frame else {
            hideDropIndicator()
            return
        }
        let edge = below ? frame.maxY : frame.minY
        dropIndicator.frame = NSRect(x: 0, y: edge - TrackerDropIndicatorView.thickness / 2, width: documentView.bounds.width,
                                     height: TrackerDropIndicatorView.thickness)
        dropIndicator.isHidden = false
    }

    private func hideDropIndicator() {
        dropIndicator.isHidden = true
    }

    // MARK: Conflicts and badges

    func showConflicts(item id: String, anchor: NSView, fromKeyboard: Bool) {
        guard editEnabled, let item = shownItem(id), !item.conflicts.isEmpty else { return }
        present(TrackerPopovers.item(item, now: now(), resolve: { [weak self] entry, keep in self?.resolve(entry, keep) }),
                from: anchor, fromKeyboard: fromKeyboard)
    }

    /// The header chip: every live conflict (with Show) and every removed item (Restore, Dismiss).
    func showBoardConflicts(anchor: NSView, fromKeyboard: Bool) {
        guard editEnabled, let board else { return }
        present(TrackerPopovers.board(board, now: now(),
                                      show: { [weak self] id in self?.scrollToItem(id) },
                                      resolve: { [weak self] entry, keep in self?.resolve(entry, keep) }),
                from: anchor, fromKeyboard: fromKeyboard)
    }

    func reviewSensitive(item id: String, anchor: NSView, fromKeyboard: Bool) {
        guard editEnabled, let item = shownItem(id), item.sensitive != nil else { return }
        present(TrackerPopovers.sensitive(item, share: { [weak self] in self?.clearBadge(item: id) },
                                          editDetails: { [weak self] in self?.beginEdit(item: id, kind: .details) }),
                from: anchor, fromKeyboard: fromKeyboard)
    }

    private func present(_ popover: TrackerConflictPopover, from anchor: NSView, fromKeyboard: Bool) {
        activePopover?.close()
        activePopover = popover
        popover.show(relativeTo: anchor, fromKeyboard: fromKeyboard)
    }

    func resolve(_ entry: TrackerConflictEntry, _ keep: TrackerConflictKeepWire) {
        userActed()
        editing.resolve(entry, keep: keep, base: base(forItem: entry.itemId)) { [weak self] outcome in
            // A removed item put back may come back under a new id: the pane follows it.
            if entry.isRemoval, keep == .losing, case .saved(let version, let created) = outcome, let id = created.first {
                self?.follow(restored: entry.itemId, as: id, version: version)
            }
        }
    }

    /// The restored item `old` is `new` now: it keeps the fold the reader had, and the pane scrolls to it once
    /// the board that holds it is on screen.
    private func follow(restored old: String, as new: String, version: UInt64) {
        if folds.expandedItems.remove(old) != nil { folds.expandedItems.insert(new) }
        followingItem = (new, version)
        followIfReady()
    }

    private func followIfReady() {
        guard let follow = followingItem, (board?.version ?? 0) >= follow.version, rowViews[TrackerRow.itemKey(follow.id)] != nil
        else { return }
        followingItem = nil
        scrollToItem(follow.id)
    }

    func clearBadge(item id: String) {
        userActed()
        editing.clearBadge(itemId: id, base: base(forItem: id))
    }

    // MARK: Chrome notice and layout

    /// Show or hide the notice above the board, keeping the reading line where it is on screen.
    private func applyNotice(_ text: String?) {
        let removal = removalTitle
        withChromeShift {
            if let text {
                notice.update(text)
            } else if let removal {
                notice.update("Removed “\(removal)”.", actionTitle: "Undo") { [weak self] in self?.undoRemoval() }
            } else {
                notice.update(nil)
            }
        }
    }

    /// Run `change` (which may change the chrome's height) and keep the reading position still.
    private func withChromeShift(_ change: () -> Void) {
        guard !isApplying else { change(); return }
        isApplying = true
        defer { isApplying = false }
        let anchor = captureAnchor()
        let scrollTop = scrollView.frame.minY
        let atVeryTop = clipView.bounds.minY <= 0.5
        change()
        layoutChrome()
        let shift = scrollView.frame.minY - scrollTop
        guard shift != 0 else { return }
        layoutRowsToFit()
        restore(anchor, renamed: [:], skipping: [], shift: atVeryTop ? 0 : shift, firstRender: false)
    }

    /// A row's height changed (an editor opened or grew): lay the rows out again, the reading line unmoved.
    private func relayoutRows() {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        let anchor = captureAnchor()
        layoutChrome()
        layoutRowsToFit()
        restore(anchor, renamed: [:], skipping: [], shift: 0, firstRender: false)
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
        responderObservation = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.firstResponderChanged() }
        }
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

    /// Focus went to a control outside the pane's rows (the composer): a pending editor that was only asked for
    /// focus (it refuses it while read-only) is no longer wanted there, so a late refusal must not pull focus
    /// back into it. Focus on the bare window, or in one of the rows, changes nothing.
    private func firstResponderChanged() {
        guard let window, let responder = Self.focusOwner(window.firstResponder), responder !== window else { return }
        if let view = responder as? NSView, view.isDescendant(of: documentView) { return }
        for (id, session) in editSessions where session.phase == .saving && session.editorWantsFocus {
            editSessions[id]?.editorWantsFocus = false
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
        writeToPasteboard(TrackerMarkdown.copyBoard(board))
    }

    /// A section's or an item's markdown, exactly as the file has it.
    func copyMarkdown(for row: TrackerRow) {
        guard let board else { return }
        let text: String?
        switch row.content {
        case .section(let section): text = TrackerMarkdown.copySection(section.id, in: board)
        default: text = row.item.flatMap { TrackerMarkdown.copyItem($0.id, in: board) }
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
                               renderGeneration: renderGeneration, rowsUpdatedLast: rowsUpdatedLast,
                               editEnabled: editEnabled, removedConflicts: board?.removedConflicts.count ?? 0,
                               editing: editingStates(), dragging: isDragging, notice: notice.spokenText)
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
    /// The conflict chip was pressed (the chip, from the keyboard).
    var onConflictChip: ((NSView, Bool) -> Void)?

    /// "N conflicts": unsettled conflicts on the board (live and removed items); nil when there are none.
    private(set) var conflictChip: TrackerChipButton?
    private(set) var conflictCount = 0

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

    func update(_ header: TrackerHeader, showsConflicts: Bool = false) {
        let count = showsConflicts ? header.conflictCount : 0
        if count != conflictCount {
            conflictCount = count
            conflictChip?.removeFromSuperview()
            conflictChip = nil
            if count > 0 {
                let text = count == 1 ? "1 conflict" : "\(count) conflicts"
                let chip = TrackerChipButton(text: text, color: Theme.amber, fill: TrackerTheme.badgeFill)
                chip.target = self
                chip.action = #selector(conflictChipPressed(_:))
                chip.setAccessibilityLabel("\(text): open the list")
                chip.toolTip = "Open the unsettled conflicts"
                addSubview(chip)
                conflictChip = chip
            }
            needsLayout = true
        }
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

    @objc private func conflictChipPressed(_ sender: NSView) {
        onConflictChip?(sender, window?.firstResponder === sender)
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
        var right = bounds.width - h
        if let chip = conflictChip {
            let w = chip.fittingWidth
            chip.frame = NSRect(x: max(right - w, h), y: 29, width: w, height: TrackerRowView.chipHeight)
            right = chip.frame.minX - 6
        }
        committableLabel.frame = NSRect(x: badgeX, y: 29, width: max(right - badgeX, 1), height: 15)
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

// MARK: - Structure support

/// The pane's document: a flipped view that takes the drop of a dragged item row. All the logic is the pane's.
final class TrackerDocumentView: NSView {
    override var isFlipped: Bool { true }

    weak var pane: TrackerPaneView?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pane?.dragUpdated(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pane?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        pane?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pane?.performDrop(sender) ?? false
    }
}

/// The drop indicator: a 2 pt line in the accent colour, drawn over the rows (never between them as a row).
final class TrackerDropIndicatorView: NSView {
    static let thickness: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.cornflower.cgColor
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One open "+ Add item" field: where focus goes when it closes, and where its create stands.
struct TrackerAddSession {
    weak var priorResponder: NSResponder?
    /// A create was sent and has no board yet: the field is read-only.
    var inFlight = false
    /// Focus left the field to create: the field closes afterwards (Return keeps it open).
    var closeAfter = false
    /// What was sent (the field is only emptied if it still holds this).
    var sentText: String?
    /// The create is confirmed: the field waits for a board with at least this version.
    var awaiting: UInt64?

    init(priorResponder: NSResponder?) {
        self.priorResponder = priorResponder
    }
}
