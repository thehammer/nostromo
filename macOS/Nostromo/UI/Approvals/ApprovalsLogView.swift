import AppKit
import NostromoKit

// AP5: the Approvals log, read-only.
//
// What is here: the store that asks the daemon for rows (`ApprovalsLogStore`, one request at a time because the
// replies carry no request id), the reader `bin/nostromo-app approvals log` uses (`ApprovalsLogReader`, the
// `tasks output` pattern: the first ask answers `loading`), how Show in transcript finds a pane
// (`ApprovalsTranscriptRevealing`), and the window's content (`ApprovalsLogView`).
//
// Nothing here edits, deletes or clears an entry: there is no such control, menu item, context menu or key
// command, and the daemon has no such request. Show in transcript is the only control that moves a transcript.

// MARK: - The store

/// What the log requests ask of the daemon connection. `NostromodClient` is the real one; tests pass a recorder.
protocol ApprovalsLogSending: AnyObject {
    func sendApprovalsLogQuery(tag: String?, outcome: String?, sinceMs: Int64?, limit: Int, cursor: String?)
    func sendApprovalsLogEntry(id: String)
}

extension NostromodClient: ApprovalsLogSending {}

/// How a log request ended.
enum ApprovalsLogReply<Answer> {
    case answered(Answer)
    /// The daemon said no (`not_operator_app`, `bad_cursor`, `unavailable`, …).
    case refused(String)
    case timedOut
    case failed(String)

    /// Words for the person.
    var problem: String? {
        switch self {
        case .answered: return nil
        case .refused(let code): return "The daemon refused the request (\(code))."
        case .timedOut: return "The daemon did not answer."
        case .failed(let reason): return reason
        }
    }
}

/// Request/response for the two log verbs, one in flight at a time (an `approvals_log_page` names no request,
/// so replies are matched to the oldest request): each request gets one completion that runs exactly once,
/// and a timeout. A late or duplicate answer is ignored. Main thread only.
final class ApprovalsLogStore {
    static let shared = ApprovalsLogStore()

    /// Above the daemon's own work; a read of 500 rows is fast.
    static let timeout: TimeInterval = 12
    /// Rows asked for per page.
    static let pageSize = 100

    /// The daemon connection; nil until `AppStore.start()` sets it.
    var sender: ApprovalsLogSending?

    private enum Kind {
        case query
        case entry(String)
    }

    private enum Ended {
        case page(ApprovalsLogPageFrame)
        case detail(ApprovalsLogDetailFrame)
        case refused(String)
        case timedOut
        case failed(String)
    }

    private final class Job {
        let kind: Kind
        let start: (ApprovalsLogSending) -> Void
        let finish: (Ended) -> Void

        init(kind: Kind, start: @escaping (ApprovalsLogSending) -> Void, finish: @escaping (Ended) -> Void) {
            self.kind = kind
            self.start = start
            self.finish = finish
        }
    }

    private var queue: [Job] = []
    private var inflight: Job?
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// `schedule` runs work after a delay on the main thread (tests pass a manual scheduler).
    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        self.schedule = schedule
    }

    /// How many requests wait for an answer (the one in flight included).
    var pendingCount: Int { queue.count + (inflight == nil ? 0 : 1) }

    /// One page, newest first. `completion` runs once.
    func query(tag: String?, outcome: String?, sinceMs: Int64?, limit: Int, cursor: String?,
               completion: @escaping (ApprovalsLogReply<ApprovalsLogPageFrame>) -> Void) {
        enqueue(Job(kind: .query, start: { sender in
            sender.sendApprovalsLogQuery(tag: tag, outcome: outcome, sinceMs: sinceMs, limit: limit, cursor: cursor)
        }, finish: { ended in
            switch ended {
            case .page(let page): completion(.answered(page))
            case .refused(let code): completion(.refused(code))
            case .timedOut: completion(.timedOut)
            case .failed(let reason): completion(.failed(reason))
            case .detail: completion(.failed("unexpected answer"))
            }
        }))
    }

    /// One entry in full (`id` is a request id or an entry id); nil when no entry has it. `completion` runs once.
    func entry(id: String, completion: @escaping (ApprovalsLogReply<ApprovalsLogDetail?>) -> Void) {
        enqueue(Job(kind: .entry(id), start: { sender in
            sender.sendApprovalsLogEntry(id: id)
        }, finish: { ended in
            switch ended {
            case .detail(let frame): completion(.answered(frame.detail))
            case .refused(let code): completion(.refused(code))
            case .timedOut: completion(.timedOut)
            case .failed(let reason): completion(.failed(reason))
            case .page: completion(.failed("unexpected answer"))
            }
        }))
    }

    /// Route a decoded daemon frame: the answers resolve the request in flight, anything else is ignored.
    func ingest(_ msg: ServerMsg) {
        guard let job = inflight else { return }
        switch (msg, job.kind) {
        case (.approvalsLogPage(let page), .query):
            complete(job, .page(page))
        case (.approvalsLogDetail(let detail), .entry(let id)) where detail.id == id:
            complete(job, .detail(detail))
        case (.approvalsLogRefused(let refusal), _):
            complete(job, .refused(refusal.code))
        default:
            break
        }
    }

    /// The daemon connection went away: nothing will answer, so fail every waiter now.
    func failPendingRequests(reason: String) {
        let waiting = (inflight.map { [$0] } ?? []) + queue
        inflight = nil
        queue.removeAll()
        for job in waiting { job.finish(.failed(reason)) }
    }

    private func enqueue(_ job: Job) {
        guard sender != nil else {
            job.finish(.failed("Not connected to the daemon."))
            return
        }
        queue.append(job)
        pump()
    }

    private func pump() {
        guard inflight == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        guard let sender else {
            job.finish(.failed("Not connected to the daemon."))
            pump()
            return
        }
        inflight = job
        job.start(sender)
        schedule(Self.timeout) { [weak self] in
            guard let self, self.inflight === job else { return }
            self.complete(job, .timedOut)
        }
    }

    private func complete(_ job: Job, _ ended: Ended) {
        guard inflight === job else { return }
        inflight = nil
        job.finish(ended)
        pump()
    }
}

// MARK: - `approvals log` over app-control

/// The reader `bin/nostromo-app approvals log` goes through: the first ask starts the read and answers
/// `loading`, and the script asks again. It reads through the same `ApprovalsLogStore` the window does.
/// An answer is kept a few seconds so the poll that follows finds it, then forgotten (the next ask reads afresh).
final class ApprovalsLogReader {
    static let shared = ApprovalsLogReader()

    static let keepSeconds: TimeInterval = 3

    enum Result {
        case loading
        case ready(ApprovalsLogPageFrame)
        case failed(String)
    }

    private struct Slot {
        var result: Result
        var at: Date
    }

    private var slots: [String: Slot] = [:]
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func read(tag: String?, outcome: String?, sinceMs: Int64?, limit: Int,
              store: ApprovalsLogStore = .shared) -> Result {
        let now = clock()
        let key = [tag ?? "", outcome ?? "", sinceMs.map(String.init) ?? "", String(limit)].joined(separator: "|")
        if let slot = slots[key] {
            if case .loading = slot.result { return .loading }
            if now.timeIntervalSince(slot.at) < Self.keepSeconds { return slot.result }
        }
        slots[key] = Slot(result: .loading, at: now)
        store.query(tag: tag, outcome: outcome, sinceMs: sinceMs, limit: limit, cursor: nil) { [weak self] reply in
            let result: Result
            if case .answered(let page) = reply { result = .ready(page) } else { result = .failed(reply.problem ?? "failed") }
            self?.slots[key] = Slot(result: result, at: self?.clock() ?? now)
        }
        // A request that failed at once (no connection) has already answered.
        return slots[key]?.result ?? .loading
    }
}

/// The JSON `approvals log` prints.
enum ApprovalsLogJSON {

    static func reply(_ result: ApprovalsLogReader.Result, redactSensitive: Bool) -> [String: Any] {
        switch result {
        case .loading:
            return ["state": "loading"]
        case .failed(let reason):
            return ["state": "error", "error": reason]
        case .ready(let page):
            return ["state": "ready",
                    "rows": page.rows.map { row(for: $0, redactSensitive: redactSensitive) },
                    "next_cursor": page.nextCursor.map { $0 as Any } ?? NSNull()]
        }
    }

    /// One row as the window shows it. A row of a sensitive focus carries `withheld: true` instead of its summary
    /// when `redactSensitive` (the real app; the same rule as `tasks output`).
    static func row(for row: ApprovalsLogRow, redactSensitive: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "row_id": row.rowId, "kind": row.kind.rawValue, "ts": row.ts, "entry_ids": row.entryIds,
            "outcome_text": ApprovalsLogText.outcomePhrase(row), "sensitive": row.sensitive,
        ]
        let optional: [(String, Any?)] = [
            ("tag", row.tag), ("session_id", row.sessionId), ("tool_use_id", row.toolUseId),
            ("request_id", row.requestId), ("agent", row.agent), ("tool_name", row.toolName),
            ("outcome", row.outcome), ("by_window", row.byWindow), ("latency_ms", row.latencyMs),
            ("refusal_code", row.refusalCode), ("rule_label", row.ruleLabel),
        ]
        for (key, value) in optional { if let value { out[key] = value } }
        if let sub = row.subagent {
            out["subagent"] = ["agent_id": sub.agentId, "agent_type": sub.agentType.map { $0 as Any } ?? NSNull()]
        }
        if row.sensitive && redactSensitive {
            out["withheld"] = true
            out["rule_label"] = nil
        } else {
            out["summary"] = row.summary
        }
        return out
    }
}

// MARK: - Show in transcript

/// How the window finds a focus's transcript pane and moves it to a call.
protocol ApprovalsTranscriptRevealing {
    /// The pane of `tag` holds the call `toolUseId` and can scroll to it.
    func canReveal(tag: String, toolUseId: String) -> Bool
    /// Select the focus and scroll its pane to the call. False, moving nothing, when it cannot.
    @discardableResult func reveal(tag: String, toolUseId: String) -> Bool
}

/// The real thing: panes are found through the open windows' views. The only code in the Approvals window
/// that moves a transcript.
struct LiveApprovalsTranscriptReveal: ApprovalsTranscriptRevealing {

    func canReveal(tag: String, toolUseId: String) -> Bool {
        if let pane = pane(tag: tag) { return pane.canRevealToolCall(toolUseId: toolUseId) }
        // Its pane is not on screen: selecting the focus puts it there.
        return focus(tag: tag) != nil
    }

    func reveal(tag: String, toolUseId: String) -> Bool {
        if let pane = pane(tag: tag) {
            if let focus = focus(tag: tag) { AppStore.shared.focusSelectionRequests.send(focus) }
            return pane.revealToolCall(toolUseId: toolUseId)
        }
        guard let focus = focus(tag: tag) else { return false }
        AppStore.shared.focusSelectionRequests.send(focus)
        // The pane appears once the selection is applied.
        DispatchQueue.main.async {
            if let pane = self.pane(tag: tag) { pane.revealToolCall(toolUseId: toolUseId) }
        }
        return true
    }

    private func focus(tag: String) -> Focus? {
        FocusStore.shared.focuses.first { $0.sessionTag == tag }
    }

    private func pane(tag: String) -> ReplView? {
        var found: ReplView?
        func walk(_ v: NSView) {
            guard found == nil else { return }
            if let pane = v as? ReplView, pane.focusTag == tag { found = pane; return }
            v.subviews.forEach(walk)
        }
        for window in NSApp.windows { if let content = window.contentView { walk(content) } }
        return found
    }
}

// MARK: - The window's content

/// What the window knows of one row's full entry.
enum ApprovalsLogDetailState: Equatable {
    case loading
    case loaded(ApprovalsLogDetail)
    case missing
    case failed(String)
}

/// The window's content: filters, the table (newest first) and, under an expanded row, the entry in full.
/// Every row is read-only; the one control a row has besides expanding is Show in transcript.
final class ApprovalsLogView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    static let rowHeight: CGFloat = 26
    static let barHeight: CGFloat = 36
    static let headerHeight: CGFloat = 20
    static let maxDetailHeight: CGFloat = 300
    /// How many pages a link's search reads before giving up (the call may be older than the log's first pages).
    static let maxLinkPages = 40

    /// Column widths, as fractions of the row.
    static let columns: [(title: String, fraction: CGFloat)] = [
        ("Time", 0.08), ("Focus", 0.12), ("Agent", 0.11), ("Tool", 0.07), ("Summary", 0.30),
        ("Outcome", 0.17), ("Answered in", 0.07), ("Latency", 0.08),
    ]

    private let store: ApprovalsLogStore
    private let revealer: ApprovalsTranscriptRevealing
    private let timeZone: TimeZone

    private(set) var pager = ApprovalsLogPager()
    private(set) var link: ApprovalsLogLink?
    private(set) var tagFilter: String?
    private(set) var outcomeFilter: ApprovalsLogOutcomeGroup?
    private(set) var expanded: Set<String> = []
    private(set) var details: [String: ApprovalsLogDetailState] = [:]
    private(set) var statusText = ""

    let focusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let outcomePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let linkLabel = NSTextField(labelWithString: "")
    let showAllButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    private let headerView = NSView()
    private var generation = 0
    private var linkPagesRead = 0
    private var knownTags: [String] = []

    init(store: ApprovalsLogStore = .shared, revealer: ApprovalsTranscriptRevealing = LiveApprovalsTranscriptReveal(),
         timeZone: TimeZone = .current) {
        self.store = store
        self.revealer = revealer
        self.timeZone = timeZone
        super.init(frame: NSRect(x: 0, y: 0, width: 980, height: 560))
        appearance = NSAppearance(named: .darkAqua)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Test and app-control surface

    /// The rows the table shows: the pager's, kept to those a link names.
    var visibleRows: [ApprovalsLogRow] {
        guard let link, link.isRowFilter else { return pager.rows }
        return pager.rows.filter(link.matches)
    }

    /// Every menu this window owns: the two filter pop-ups' (it has no menu bar items and no context menus).
    var allMenus: [NSMenu] { [focusPopup.menu, outcomePopup.menu].compactMap { $0 } }

    // MARK: Opening and filtering

    /// Show every row, or those `link` names; read the log afresh. Moves nothing outside this window.
    func apply(link: ApprovalsLogLink?) {
        self.link = link
        tagFilter = link?.tag
        outcomeFilter = nil
        expanded = []
        details = [:]
        syncControls()
        reload()
    }

    /// The focus filter changed (nil: every focus).
    func setFocusFilter(_ tag: String?) {
        guard tag != tagFilter else { return }
        tagFilter = tag
        if link?.tag != tag { link?.tag = tag }
        syncControls()
        reload()
    }

    /// The outcome filter changed (nil: every outcome).
    func setOutcomeFilter(_ group: ApprovalsLogOutcomeGroup?) {
        guard group != outcomeFilter else { return }
        outcomeFilter = group
        syncControls()
        reload()
    }

    /// Drop the link: every row again.
    func showAll() {
        link = nil
        syncControls()
        reloadTable()
        loadMoreIfNeeded()
    }

    /// Ask for the next page (when there is one and none is on its way). Scrolling near the end does this.
    func loadNextPage() {
        guard pager.canLoadMore else { return }
        fetch()
    }

    /// Read the first page again.
    func reload() {
        pager.reset()
        generation += 1
        linkPagesRead = 0
        statusText = "Loading…"
        reloadTable()
        fetch()
    }

    // MARK: Rows

    /// Expand or collapse a row: expanding asks the daemon for the entry in full. Moves nothing outside this window.
    func toggleExpanded(rowId: String) {
        if expanded.remove(rowId) != nil {
            reloadRow(rowId)
            return
        }
        expanded.insert(rowId)
        guard let row = pager.rows.first(where: { $0.rowId == rowId }) else { return }
        if case .loaded? = details[rowId] {} else {
            details[rowId] = .loading
            store.entry(id: row.requestId ?? row.entryIds.first ?? row.rowId) { [weak self] reply in
                guard let self else { return }
                switch reply {
                case .answered(let detail?): self.details[rowId] = .loaded(detail)
                case .answered(nil): self.details[rowId] = .missing
                default: self.details[rowId] = .failed(reply.problem ?? "failed")
                }
                self.reloadRow(rowId)
            }
        }
        reloadRow(rowId)
    }

    /// Show in transcript for a row: the one control here that moves a transcript.
    @discardableResult
    func showInTranscript(rowId: String) -> Bool {
        guard let row = pager.rows.first(where: { $0.rowId == rowId }), let tag = row.tag, let toolUseId = row.toolUseId
        else { return false }
        return revealer.reveal(tag: tag, toolUseId: toolUseId)
    }

    func canShowInTranscript(_ row: ApprovalsLogRow) -> Bool {
        guard let tag = row.tag, let toolUseId = row.toolUseId else { return false }
        return revealer.canReveal(tag: tag, toolUseId: toolUseId)
    }

    /// The detail text of an expanded row, as the row shows it (nil until loaded).
    func detailText(rowId: String) -> NSAttributedString? {
        guard case .loaded(let detail)? = details[rowId] else { return nil }
        return Self.detailText(detail)
    }

    // MARK: Fetching

    private func fetch() {
        guard !pager.isLoading, pager.cursorToSend != nil || !pager.hasLoadedFirstPage else { return }
        pager.beginLoading()
        let gen = generation
        store.query(tag: tagFilter, outcome: outcomeFilter?.rawValue, sinceMs: nil, limit: ApprovalsLogStore.pageSize,
                    cursor: pager.cursorToSend) { [weak self] reply in
            guard let self, gen == self.generation else { return }
            switch reply {
            case .answered(let page):
                self.pager.apply(page)
                if self.link?.isRowFilter == true { self.linkPagesRead += 1 }
                self.statusText = ""
                self.noteTags()
                self.reloadTable()
                self.loadMoreIfNeeded()
            default:
                self.pager.failed()
                self.statusText = reply.problem ?? "The log could not be read."
                self.updateStatus()
            }
        }
    }

    /// More rows when the last visible one is near the end of what is loaded, or when a link's rows have not
    /// been found yet.
    private func loadMoreIfNeeded() {
        guard pager.canLoadMore else { updateStatus(); return }
        if let link, link.isRowFilter {
            guard visibleRows.isEmpty, linkPagesRead < Self.maxLinkPages else { updateStatus(); return }
            fetch()
            return
        }
        let visible = tableView.rows(in: tableView.visibleRect)
        let lastVisible = visible.location + visible.length - 1
        if pager.shouldLoadMore(lastVisibleIndex: lastVisible) { fetch() } else { updateStatus() }
    }

    @objc private func scrolled(_ note: Notification) { loadMoreIfNeeded() }

    // MARK: Building

    private func build() {
        for popup in [focusPopup, outcomePopup] {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: 11)
            popup.target = self
            popup.refusesFirstResponder = true
        }
        focusPopup.action = #selector(focusPopupChanged)
        outcomePopup.action = #selector(outcomePopupChanged)
        focusPopup.setAccessibilityLabel("Focus filter")
        outcomePopup.setAccessibilityLabel("Outcome filter")
        outcomePopup.removeAllItems()
        outcomePopup.addItem(withTitle: "All outcomes")
        for group in ApprovalsLogOutcomeGroup.allCases { outcomePopup.addItem(withTitle: group.title) }

        linkLabel.font = .systemFont(ofSize: 11)
        linkLabel.textColor = ApprovalPalette.warning
        linkLabel.lineBreakMode = .byTruncatingTail
        showAllButton.title = "Show all"
        showAllButton.bezelStyle = .inline
        showAllButton.controlSize = .small
        showAllButton.font = .systemFont(ofSize: 11)
        showAllButton.target = self
        showAllButton.action = #selector(showAllPressed)
        showAllButton.refusesFirstResponder = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = ApprovalPalette.mutedText
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.alignment = .right

        for (index, column) in Self.columns.enumerated() {
            let label = NSTextField(labelWithString: column.title)
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = ApprovalPalette.mutedText
            label.tag = index
            headerView.addSubview(label)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAutomaticRowHeights = false
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = ApprovalPalette.cardBackground
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.gridStyleMask = []
        tableView.setAccessibilityLabel("Approvals log")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ApprovalPalette.cardBackground
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        for v in [focusPopup, outcomePopup, linkLabel, showAllButton, statusLabel, headerView, scrollView] as [NSView] {
            addSubview(v)
        }
        syncControls()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let barY = bounds.height - Self.barHeight + 6
        focusPopup.frame = NSRect(x: pad, y: barY, width: 170, height: 22)
        outcomePopup.frame = NSRect(x: focusPopup.frame.maxX + 8, y: barY, width: 170, height: 22)
        statusLabel.frame = NSRect(x: bounds.width - 260 - pad, y: barY + 2, width: 260, height: 16)
        let showAllWidth: CGFloat = showAllButton.isHidden ? 0 : 64
        let linkX = outcomePopup.frame.maxX + 12
        let linkWidth = max(0, statusLabel.frame.minX - linkX - showAllWidth - 12)
        linkLabel.frame = NSRect(x: linkX, y: barY + 2, width: linkWidth, height: 16)
        showAllButton.frame = NSRect(x: linkLabel.frame.maxX + 6, y: barY, width: showAllWidth, height: 22)
        let headerY = bounds.height - Self.barHeight - Self.headerHeight
        headerView.frame = NSRect(x: 0, y: headerY, width: bounds.width, height: Self.headerHeight)
        var x = pad
        let usable = bounds.width - 2 * pad
        for case let label as NSTextField in headerView.subviews {
            let fraction = Self.columns[label.tag].fraction
            label.frame = NSRect(x: x, y: 2, width: usable * fraction - 4, height: 14)
            x += usable * fraction
        }
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, headerY))
        tableView.tableColumns.first?.width = scrollView.contentSize.width
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if oldSize.width != bounds.width { tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<tableView.numberOfRows)) }
    }

    @objc private func focusPopupChanged() {
        let index = focusPopup.indexOfSelectedItem
        setFocusFilter(index <= 0 ? nil : focusPopup.titleOfSelectedItem)
    }

    @objc private func outcomePopupChanged() {
        let index = outcomePopup.indexOfSelectedItem
        setOutcomeFilter(index <= 0 ? nil : ApprovalsLogOutcomeGroup.allCases[index - 1])
    }

    @objc private func showAllPressed() { showAll() }

    /// Bring the controls in line with the filters and link.
    private func syncControls() {
        outcomePopup.selectItem(at: outcomeFilter.flatMap { ApprovalsLogOutcomeGroup.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        rebuildFocusPopup()
        let showsLink = link?.isRowFilter == true
        linkLabel.isHidden = !showsLink
        showAllButton.isHidden = !showsLink
        linkLabel.stringValue = showsLink ? "Showing: \(link?.description ?? "")" : ""
        needsLayout = true
    }

    private func noteTags() {
        let seen = Set(pager.rows.compactMap(\.tag))
        let merged = Set(knownTags).union(seen)
        if merged.count != knownTags.count { knownTags = merged.sorted(); rebuildFocusPopup() }
    }

    private func rebuildFocusPopup() {
        var tags = Set(knownTags)
        if let tagFilter { tags.insert(tagFilter) }
        focusPopup.removeAllItems()
        focusPopup.addItem(withTitle: "All focuses")
        for tag in tags.sorted() { focusPopup.addItem(withTitle: tag) }
        if let tagFilter { focusPopup.selectItem(withTitle: tagFilter) } else { focusPopup.selectItem(at: 0) }
    }

    private func updateStatus() {
        if statusText.isEmpty {
            let shown = visibleRows.count
            statusText = pager.hasLoadedFirstPage
                ? (shown == 0 ? "No entries" : "\(shown) shown" + (pager.nextCursor != nil ? ", more below" : ""))
                : ""
        }
        statusLabel.stringValue = statusText
        statusText = ""
    }

    private func reloadTable() {
        tableView.reloadData()
        updateStatus()
    }

    private func reloadRow(_ rowId: String) {
        guard let index = visibleRows.firstIndex(where: { $0.rowId == rowId }) else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let rows = visibleRows
        guard row < rows.count, expanded.contains(rows[row].rowId) else { return Self.rowHeight }
        return Self.rowHeight + expandedHeight(for: rows[row], width: tableView.bounds.width)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = visibleRows
        guard row < rows.count else { return nil }
        let data = rows[row]
        let cell = ApprovalsLogRowView(row: data, timeZone: timeZone)
        cell.isExpanded = expanded.contains(data.rowId)
        if cell.isExpanded {
            cell.setDetail(details[data.rowId] ?? .loading, text: detailText(rowId: data.rowId))
            cell.showButton.isEnabled = canShowInTranscript(data)
            cell.showButton.toolTip = cell.showButton.isEnabled
                ? "Scroll that focus's transcript to this call"
                : (data.toolUseId == nil ? "This entry names no tool call"
                   : "That transcript does not hold this call (any more)")
            cell.showButton.isHidden = data.toolUseId == nil || data.tag == nil
        }
        cell.onToggle = { [weak self] in self?.toggleExpanded(rowId: data.rowId) }
        cell.onShow = { [weak self] in self?.showInTranscript(rowId: data.rowId) }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        view.backgroundColor = row % 2 == 0 ? ApprovalPalette.cardBackground : ApprovalPalette.inputBackground
        return view
    }

    private func expandedHeight(for row: ApprovalsLogRow, width: CGFloat) -> CGFloat {
        guard let text = detailText(rowId: row.rowId) else { return 40 }
        let box = text.boundingRect(with: NSSize(width: max(100, width - 40), height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return min(Self.maxDetailHeight, ceil(box.height) + 44)
    }

    // MARK: The entry in full

    static let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// The entry in full, read-only. Invisible characters show as `⟨U+202E⟩` tokens in the warning colour: the
    /// daemon recorded them as tokens, and any that are still raw characters are turned into tokens here.
    static func detailText(_ d: ApprovalsLogDetail) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func section(_ title: String, _ body: String?) {
            guard let body, !body.isEmpty else { return }
            if out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: title + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: ApprovalPalette.mutedText,
            ]))
            out.append(ApprovalContextText.attributed(body, wraps: true, lineBreakMode: .byWordWrapping,
                                                      font: monoFont, color: ApprovalPalette.commandText))
            out.append(NSAttributedString(string: "\n"))
        }
        section("Input", d.input?.inputText)
        section("Description", d.displayText)
        section("Reason", d.reason?.displayText)
        section("Flags", d.flags?.displayText)
        section("Options offered", d.options?.displayText)
        section("Rule", d.rule?.displayText)
        section("Detail", d.detail)
        section("Refusal peer", d.peer?.displayText)
        section("Channel", d.channel)
        section("Control", d.control)
        if out.length == 0 { section("Entry", "\(d.event) \(d.id)") }
        colorTokens(in: out)
        return out
    }

    /// Paint every `⟨U+…⟩` token in the warning colour (those the daemon wrote into the text).
    private static func colorTokens(in text: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: "\u{27E8}U\\+[0-9A-Fa-f]{4,6}[^\u{27E9}\n]*\u{27E9}") else { return }
        let whole = NSRange(location: 0, length: (text.string as NSString).length)
        for match in regex.matches(in: text.string, range: whole) {
            text.addAttributes([.foregroundColor: ApprovalPalette.warning, .backgroundColor: ApprovalPalette.warningFill],
                               range: match.range)
        }
    }
}

// MARK: - One row

/// A row of the table: eight read-only labels, and below them, when expanded, the entry in full and Show in
/// transcript. A click anywhere on the row expands or collapses it.
final class ApprovalsLogRowView: NSView {
    let row: ApprovalsLogRow
    private let labels: [NSTextField]
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    let showButton = NSButton()

    var isExpanded = false { didSet { needsLayout = true } }
    var onToggle: (() -> Void)?
    var onShow: (() -> Void)?

    init(row: ApprovalsLogRow, timeZone: TimeZone) {
        self.row = row
        let texts = [
            ApprovalsLogText.time(row, timeZone: timeZone),
            row.tag ?? "",
            ApprovalsLogText.agentText(row),
            row.toolName ?? "",
            row.summary,
            ApprovalsLogText.outcomePhrase(row),
            row.byWindow ?? "",
            ApprovalsLogText.latency(row.latencyMs),
        ]
        let muted: Set<Int> = [0, 6, 7]
        labels = texts.enumerated().map { index, text in
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            ApprovalContextText.set(label, text, wraps: false, font: .systemFont(ofSize: 11),
                                    color: muted.contains(index) ? ApprovalPalette.mutedText : ApprovalPalette.commandText)
            label.toolTip = text.isEmpty ? nil : text
            return label
        }
        super.init(frame: .zero)
        labels[0].toolTip = ApprovalsLogText.utcTooltip(row.ts)
        labels.forEach(addSubview)
        detailLabel.isSelectable = true
        detailLabel.maximumNumberOfLines = 0
        detailLabel.isHidden = true
        addSubview(detailLabel)
        showButton.title = "Show in transcript"
        showButton.bezelStyle = .inline
        showButton.controlSize = .small
        showButton.font = .systemFont(ofSize: 11)
        showButton.target = self
        showButton.action = #selector(showPressed)
        showButton.refusesFirstResponder = true
        showButton.isHidden = true
        addSubview(showButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel([labels[0].stringValue, labels[3].stringValue, labels[4].stringValue, labels[5].stringValue]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The expanded part: the entry's text, or why there is none.
    func setDetail(_ state: ApprovalsLogDetailState, text: NSAttributedString?) {
        detailLabel.isHidden = false
        switch state {
        case .loading:
            detailLabel.stringValue = "Loading…"
            detailLabel.textColor = ApprovalPalette.mutedText
        case .loaded:
            if let text { detailLabel.attributedStringValue = text }
        case .missing:
            detailLabel.stringValue = "This entry is no longer in the log."
            detailLabel.textColor = ApprovalPalette.mutedText
        case .failed(let why):
            detailLabel.stringValue = why
            detailLabel.textColor = ApprovalPalette.warning
        }
    }

    /// The text the expanded part shows.
    var detailString: String { detailLabel.isHidden ? "" : detailLabel.stringValue }
    var detailAttributed: NSAttributedString { detailLabel.attributedStringValue }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let usable = bounds.width - 2 * pad
        var x = pad
        let top = bounds.height - ApprovalsLogView.rowHeight
        for (index, label) in labels.enumerated() {
            let fraction = ApprovalsLogView.columns[index].fraction
            label.frame = NSRect(x: x, y: top + 5, width: usable * fraction - 4, height: 16)
            x += usable * fraction
        }
        if isExpanded {
            let height = max(0, top - 6 - (showButton.isHidden ? 0 : 26))
            detailLabel.preferredMaxLayoutWidth = max(100, bounds.width - 2 * pad - 20)
            detailLabel.frame = NSRect(x: pad + 20, y: showButton.isHidden ? 4 : 30, width: max(100, bounds.width - 2 * pad - 20),
                                       height: height)
            showButton.frame = NSRect(x: pad + 20, y: 4, width: 130, height: 20)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the detail text selects it (it is a text field); anywhere else expands or collapses.
        let point = convert(event.locationInWindow, from: nil)
        if isExpanded, !detailLabel.isHidden, detailLabel.frame.contains(point) {
            super.mouseDown(with: event)
            return
        }
        onToggle?()
    }

    @objc private func showPressed() { onShow?() }
}
