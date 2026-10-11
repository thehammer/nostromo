import AppKit
import Combine

// MARK: - Model

/// Everything Fred's surface renders. The surface never reads `AppStore`; the
/// bindings (`FredBindings`) copy the store's snapshots into this.
struct FredSurfaceModel {
    var mailbox: MailboxSnapshot?
    var calendar: CalendarSnapshot?
    /// False while the app is disconnected from nostromd: the panes keep their
    /// last data, dimmed, under a banner.
    var isConnected: Bool

    init(mailbox: MailboxSnapshot? = nil, calendar: CalendarSnapshot? = nil, isConnected: Bool = true) {
        self.mailbox = mailbox
        self.calendar = calendar
        self.isConnected = isConnected
    }
}

// MARK: - Pure presentation

/// Text and ordering rules for the Inbox and Today panes. Pure: every function
/// takes the clock and zone it needs, so the rules are testable without a view.
enum FredPresentation {

    /// Whether the snapshot's data (and counts) can be trusted enough to show.
    /// `stale` and `rateLimited` keep the last good data under a banner, but
    /// only when there is some: a throttled fetch that never read anything has
    /// no zero to show ("0 unread", "No meetings today").
    static func showsData(_ mailbox: MailboxSnapshot) -> Bool {
        showsData(mailbox.state, hasData: mailbox.updatedAt != nil || mailbox.unreadCount > 0 || !mailbox.items.isEmpty)
    }

    static func showsData(_ calendar: CalendarSnapshot) -> Bool {
        showsData(calendar.state, hasData: calendar.updatedAt != nil || !calendar.events.isEmpty)
    }

    private static func showsData(_ state: SourceState, hasData: Bool) -> Bool {
        switch state {
        case .fresh, .empty: return true
        case .stale, .rateLimited: return hasData
        default: return false
        }
    }

    // MARK: Inbox

    /// Unread first, then newest first. The daemon already sorts this way; the
    /// view does not rely on it.
    static func inboxItems(_ mailbox: MailboxSnapshot?) -> [MailboxItem] {
        guard let mailbox, showsData(mailbox) else { return [] }
        return mailbox.items.sorted { a, b in
            if a.isRead != b.isRead { return !a.isRead }
            return (a.receivedAt ?? .distantPast) > (b.receivedAt ?? .distantPast)
        }
    }

    static func inboxHeader(_ mailbox: MailboxSnapshot?) -> String {
        guard let mailbox, showsData(mailbox) else { return "Inbox" }
        return "Inbox · \(mailbox.unreadCount) unread"
    }

    /// "Alice Smith <alice@x.com>" → "Alice Smith"; anything else as is.
    static func senderName(_ from: String) -> String {
        guard let open = from.firstIndex(of: "<"), from.hasSuffix(">") else { return from }
        let name = from[..<open].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? from : name
    }

    static func relativeTime(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        if secs < 86_400 { return "\(secs / 3600) h ago" }
        if secs < 172_800 { return "yesterday" }
        return "\(secs / 86_400) d ago"
    }

    static func inboxSpokenLabel(_ item: MailboxItem, now: Date) -> String {
        var parts: [String] = []
        if !item.isRead { parts.append("Unread") }
        if item.vip { parts.append("VIP") }
        if item.isInvite { parts.append("Invite") }
        parts.append(senderName(item.from))
        parts.append(item.subject)
        let when = relativeTime(item.receivedAt, now: now)
        if !when.isEmpty { parts.append(when) }
        return parts.joined(separator: ", ")
    }

    // MARK: Today

    static func isCancelled(_ event: CalendarEvent) -> Bool {
        event.isCancelled || event.status.lowercased() == "cancelled"
    }

    private static func response(_ event: CalendarEvent) -> String {
        (event.status.isEmpty ? event.responseStatus : event.status).lowercased()
    }

    static func isDeclined(_ event: CalendarEvent) -> Bool { response(event) == "declined" }

    /// Today's events in time order (cancelled and declined ones included).
    static func todayEvents(_ calendar: CalendarSnapshot?) -> [CalendarEvent] {
        guard let calendar, showsData(calendar) else { return [] }
        return calendar.events.sorted {
            ($0.start ?? .distantPast, $0.end ?? .distantPast) < ($1.start ?? .distantPast, $1.end ?? .distantPast)
        }
    }

    /// Cancelled, declined and all-day events are never "now" or "next".
    private static func isLive(_ event: CalendarEvent) -> Bool {
        !isCancelled(event) && !isDeclined(event) && !event.isAllDay
    }

    static func isNow(_ event: CalendarEvent, at now: Date) -> Bool {
        guard isLive(event), let start = event.start, let end = event.end else { return false }
        return start <= now && now < end
    }

    static func todayHeader(_ calendar: CalendarSnapshot?) -> String {
        let events = todayEvents(calendar)
        guard !events.isEmpty else { return "Today" }
        let count = events.filter { !isCancelled($0) }.count
        return "Today · \(count) \(count == 1 ? "meeting" : "meetings")"
    }

    /// "Next: Eng sync in 12 min" / "No more meetings today" / "No meetings
    /// today"; `nil` when there is no trustworthy data to count down from.
    static func countdown(_ calendar: CalendarSnapshot?, now: Date) -> String? {
        guard let calendar, showsData(calendar) else { return nil }
        let events = todayEvents(calendar)
        if events.isEmpty { return "No meetings today" }
        let upcoming = events.filter { isLive($0) && ($0.start ?? .distantPast) > now }
        guard let next = upcoming.min(by: { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }),
              let start = next.start else { return "No more meetings today" }
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        return "Next: \(next.title) in \(duration(minutes))"
    }

    private static func duration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// The word for an event's status. Never colour alone.
    static func statusWord(_ event: CalendarEvent) -> String {
        if isCancelled(event) { return "Cancelled" }
        switch response(event) {
        case "accepted": return "Accepted"
        case "tentativelyaccepted", "tentative": return "Tentative"
        case "declined": return "Declined"
        case "organizer": return "Organizer"
        default: return "No response"
        }
    }

    /// "9:30–10:00 am", "11:30 am–12:30 pm", "All day".
    static func timeRange(_ event: CalendarEvent, in zone: TimeZone) -> String {
        if event.isAllDay { return "All day" }
        guard let start = event.start else { return "" }
        let s = clockParts(start, in: zone)
        guard let end = event.end else { return "\(s.time) \(s.meridiem)" }
        let e = clockParts(end, in: zone)
        if s.meridiem == e.meridiem { return "\(s.time)–\(e.time) \(e.meridiem)" }
        return "\(s.time) \(s.meridiem)–\(e.time) \(e.meridiem)"
    }

    /// "9:42 am".
    static func clockText(_ date: Date, in zone: TimeZone) -> String {
        let p = clockParts(date, in: zone)
        return "\(p.time) \(p.meridiem)"
    }

    private static func clockParts(_ date: Date, in zone: TimeZone) -> (time: String, meridiem: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        return (String(format: "%d:%02d", hour12, c.minute ?? 0), hour < 12 ? "am" : "pm")
    }

    static func todaySpokenLabel(_ event: CalendarEvent, now: Date, in zone: TimeZone) -> String {
        var parts: [String] = []
        if isNow(event, at: now) { parts.append("Now") }
        parts.append(event.title)
        parts.append(timeRange(event, in: zone))
        parts.append(statusWord(event))
        return parts.joined(separator: ", ")
    }
}

// MARK: - Scheduler

/// Timers the surface uses, injectable so tests fire them by hand instead of
/// waiting on the wall clock. Cancelling (or releasing) the token stops a job.
struct FredScheduler {
    var every: (_ interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable
    var after: (_ delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable

    static let live = FredScheduler(
        every: { interval, action in
            let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
            RunLoop.main.add(timer, forMode: .common)
            return AnyCancellable { timer.invalidate() }
        },
        after: { delay, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return AnyCancellable { item.cancel() }
        })
}

// MARK: - Surface

/// Fred's information surface: Inbox and Today side by side, rendered from the
/// daemon's snapshots without an agent turn. "Now", the next-meeting countdown
/// and relative times are recomputed from the injected clock every 30 s.
final class FredSurfaceView: NSView {

    /// Re-renders on assignment.
    var model: FredSurfaceModel {
        didSet { render() }
    }

    /// Subscriptions that feed `model`; owned here so they live exactly as long
    /// as the view (set by `FredBindings`).
    var subscriptions = Set<AnyCancellable>()

    /// Detail of the selected message or event, shown below the two lists
    /// (full width, so Inbox and Today both stay visible). Nil until a row is
    /// selected.
    private(set) var detailView: FredDetailView?

    private let clock: () -> Date
    private let pasteboard: NSPasteboard
    private let timeZone: TimeZone
    private let detailActions: FredDetailActions?
    private let scheduler: FredScheduler
    private var selectedItemId: String?
    private var isReloading = false
    private var clockJob: AnyCancellable?
    private var bannerJob: AnyCancellable?
    private var bannerGeneration = 0

    /// The result of the last "send to Fred", kept here (not in the detail view,
    /// which is replaced when the selection moves) so it is always shown. It
    /// clears itself after a few seconds.
    private(set) var seedBannerText: String?

    var selectedInboxRow: Int? { inboxPane.table.selectedRow >= 0 ? inboxPane.table.selectedRow : nil }
    var selectedTodayRow: Int? { todayPane.table.selectedRow >= 0 ? todayPane.table.selectedRow : nil }

    private let disconnectedBanner = SourceStateBanner()
    private let seedBanner = NSTextField(wrappingLabelWithString: "")
    private let inboxPane: FredPane
    private let todayPane: FredPane
    private let inboxRows = FredInboxRows()
    private let todayRows = FredTodayRows()

    private static let refreshInterval: TimeInterval = 30
    private static let bannerLifetime: TimeInterval = 8

    init(model: FredSurfaceModel,
         clock: @escaping () -> Date = { Date() },
         pasteboard: NSPasteboard = .general,
         timeZone: TimeZone = .current,
         scheduler: FredScheduler = .live,
         detail: FredDetailActions? = nil) {
        self.model = model
        self.detailActions = detail
        self.scheduler = scheduler
        self.clock = clock
        self.pasteboard = pasteboard
        self.timeZone = timeZone
        self.inboxPane = FredPane(idPrefix: "fred.inbox", title: "Inbox", sourceName: "Mail",
                                  emptyText: "No messages in your Inbox", showsCountdown: false)
        self.todayPane = FredPane(idPrefix: "fred.today", title: "Today", sourceName: "Calendar",
                                  emptyText: "No meetings today", showsCountdown: true)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        buildHierarchy()
        render()
    }

    required init?(coder: NSCoder) { fatalError("FredSurfaceView is built in code") }

    /// Re-evaluate "Now", the countdown and relative times against `clock()`.
    /// The view calls this itself every 30 s.
    func refreshClock() {
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clockJob = nil
        if window != nil { startClock() }
    }

    /// Start the 30 s repeating refresh (replacing any running one).
    func startClock() {
        clockJob = scheduler.every(Self.refreshInterval) { [weak self] in self?.refreshClock() }
    }

    // MARK: - Layout

    /// Hidden banners stay in the hierarchy (they just take no height), so the
    /// layout is explicit rather than an `NSStackView` that would detach them.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let bannerHeight: CGFloat = disconnectedBanner.isHidden ? 0 : Self.bannerHeight
        disconnectedBanner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bannerHeight)
        var top = bannerHeight
        if !seedBanner.isHidden {
            let h = seedBanner.sizeThatFits(NSSize(width: bounds.width - 20, height: .greatestFiniteMagnitude)).height + 8
            seedBanner.frame = NSRect(x: 0, y: top, width: bounds.width, height: h)
            top += h
        }
        let half = (bounds.width / 2).rounded(.down)
        let available = max(0, bounds.height - top)
        // With a selection the lists keep the top ~40% and the detail takes the rest.
        let listsHeight = detailView == nil ? available : max(Self.minListsHeight, (available * 0.4).rounded(.down))
        inboxPane.frame = NSRect(x: 0, y: top, width: half, height: min(available, listsHeight))
        todayPane.frame = NSRect(x: half + 1, y: top, width: max(0, bounds.width - half - 1),
                                 height: min(available, listsHeight))
        if let detailView {
            let y = top + min(available, listsHeight) + 1
            detailView.frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bounds.height - y))
        }
    }

    private static let minListsHeight: CGFloat = 140

    // MARK: - Selection

    /// Select Inbox row `row` as the user would (shows its detail).
    func selectInboxRow(_ row: Int) {
        select(row: row, in: inboxPane.table)
    }

    /// Select Today row `row` as the user would (shows its detail).
    func selectTodayRow(_ row: Int) {
        select(row: row, in: todayPane.table)
    }

    private func select(row: Int, in table: NSTableView) {
        guard row >= 0, row < table.numberOfRows else { return }
        isReloading = true   // the delegate callback would show the detail a second time
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isReloading = false
        showDetail(for: table)
    }

    private func showDetail(for table: NSTableView) {
        let row = table.selectedRow
        let other = table === inboxPane.table ? todayPane.table : inboxPane.table
        let subject: FredDetailSubject?
        if table === inboxPane.table {
            subject = inboxRows.items.indices.contains(row) ? .mail(inboxRows.items[row]) : nil
        } else {
            subject = todayRows.events.indices.contains(row) ? .event(todayRows.events[row]) : nil
        }
        guard let subject, let actions = detailActions else { return }
        other.deselectAll(nil)
        // Same item again (a click on the selected row, Return): keep the view,
        // its loaded detail and any prompt the user is editing.
        if detailView != nil, selectedItemId == subject.itemId { return }
        detailView?.removeFromSuperview()
        let view = FredDetailView(subject: subject, actions: reportingSeeds(actions))
        addSubview(view)
        detailView = view
        selectedItemId = subject.itemId
        needsLayout = true
    }

    /// `actions` with every seed result also reported to the surface, which
    /// outlives the detail view the user may have moved away from.
    private func reportingSeeds(_ actions: FredDetailActions) -> FredDetailActions {
        var wrapped = actions
        wrapped.seedFred = { [weak self] text, completion in
            actions.seedFred(text) { failure in
                completion(failure)
                self?.showSeedResult(failure)
            }
        }
        return wrapped
    }

    private func showSeedResult(_ failure: WorkError?) {
        let text: String
        if let failure {
            text = failure.code == "fred_not_running"
                ? FredDetailView.couldNotSeedNotRunning
                : "Couldn't send to Fred: \(failure.message)"
        } else {
            text = FredDetailView.sentToFred
        }
        seedBannerText = text
        seedBanner.stringValue = text
        seedBanner.textColor = failure == nil ? Theme.fgMuted : Theme.redSweater
        seedBanner.isHidden = false
        needsLayout = true
        bannerGeneration += 1
        let generation = bannerGeneration
        bannerJob = scheduler.after(Self.bannerLifetime) { [weak self] in
            guard let self, self.bannerGeneration == generation else { return }
            self.seedBannerText = nil
            self.seedBanner.isHidden = true
            self.needsLayout = true
        }
    }

    private func restoreSelection() {
        guard let id = selectedItemId else { return }
        isReloading = true
        defer { isReloading = false }
        if let row = inboxRows.items.firstIndex(where: { "mail:\($0.id)" == id }) {
            inboxPane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let row = todayRows.events.firstIndex(where: { "event:\($0.id)" == id }) {
            todayPane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    static let bannerHeight: CGFloat = 26

    private func buildHierarchy() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        disconnectedBanner.setAccessibilityIdentifier("fred.disconnected.banner")
        disconnectedBanner.allowsRetry = false
        addSubview(disconnectedBanner)
        seedBanner.font = .systemFont(ofSize: 11)
        seedBanner.isHidden = true
        seedBanner.setAccessibilityIdentifier("fred.seed.banner")
        addSubview(seedBanner)
        addSubview(inboxPane)
        addSubview(todayPane)

        inboxPane.table.dataSource = inboxRows
        inboxPane.table.delegate = inboxRows
        todayPane.table.dataSource = todayRows
        todayPane.table.delegate = todayRows
        for pane in [inboxPane, todayPane] {
            pane.table.onSelectionChange = { [weak self] table in
                guard let self, !self.isReloading else { return }
                self.showDetail(for: table)
            }
        }
        inboxPane.onCopy = { [weak self] code in self?.copy(code) }
        todayPane.onCopy = { [weak self] code in self?.copy(code) }
    }

    private func copy(_ code: String) {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }

    // MARK: - Render

    private func render() {
        // Reloading a table clears its selection and reports that as a change;
        // none of it is the user selecting something.
        isReloading = true
        defer { isReloading = false }
        let now = clock()
        let mailbox = model.mailbox
        let calendar = model.calendar

        if model.isConnected {
            disconnectedBanner.clear()
        } else {
            disconnectedBanner.showDisconnected()
        }
        let alpha: CGFloat = model.isConnected ? 1 : 0.5
        inboxPane.alphaValue = alpha
        todayPane.alphaValue = alpha
        needsLayout = true

        // Inbox
        let items = FredPresentation.inboxItems(mailbox)
        inboxRows.set(items, now: now)
        inboxPane.render(
            header: FredPresentation.inboxHeader(mailbox),
            trailing: nil,
            state: mailbox?.state,
            updatedAt: mailbox?.updatedAt,
            reason: mailbox?.error,
            retryAt: mailbox?.retryAt,
            prompt: mailbox?.state == .unauthenticated ? mailbox?.authPrompt : nil,
            hasRows: !items.isEmpty,
            showsEmptyMessage: mailbox.map { FredPresentation.showsData($0) && items.isEmpty } ?? false,
            now: now, zone: timeZone)

        // Today
        let events = FredPresentation.todayEvents(calendar)
        todayRows.set(events, now: now, zone: timeZone)
        let todayPrompt = calendar?.state == .unauthenticated ? (calendar?.authPrompt ?? mailbox?.authPrompt) : nil
        todayPane.render(
            header: FredPresentation.todayHeader(calendar),
            trailing: FredPresentation.countdown(calendar, now: now),
            state: calendar?.state,
            updatedAt: calendar?.updatedAt,
            reason: calendar?.error,
            retryAt: calendar?.retryAt,
            prompt: todayPrompt,
            hasRows: !events.isEmpty,
            showsEmptyMessage: calendar.map { FredPresentation.showsData($0) && events.isEmpty } ?? false,
            now: now, zone: timeZone)
        restoreSelection()
    }
}

// MARK: - Selectable table

/// Reports selection changes and treats Return as "open this row's detail".
final class FredTable: NSTableView {
    var onSelectionChange: ((FredTable) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0 {
            onSelectionChange?(self)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - One pane (header, banner / sign-in, rows)

private final class FredPane: NSView {

    let table = FredTable()
    var onCopy: ((String) -> Void)?

    private let sourceName: String
    private let showsCountdown: Bool
    private let headerLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let headerBar = NSView()
    private let banner = SourceStateBanner()
    private let signIn = FredSignInView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()

    private static let headerHeight: CGFloat = 26
    private static let signInHeight: CGFloat = 104
    private static let emptyHeight: CGFloat = 36

    init(idPrefix: String, title: String, sourceName: String, emptyText: String, showsCountdown: Bool) {
        self.sourceName = sourceName
        self.showsCountdown = showsCountdown
        super.init(frame: .zero)
        setAccessibilityIdentifier("\(idPrefix).pane")
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        headerBar.wantsLayer = true
        headerBar.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = Theme.fg
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setAccessibilityIdentifier("\(idPrefix).header")

        trailingLabel.font = .systemFont(ofSize: 11)
        trailingLabel.textColor = Theme.fgMuted
        trailingLabel.alignment = .right
        trailingLabel.lineBreakMode = .byTruncatingTail
        trailingLabel.setAccessibilityIdentifier("\(idPrefix).countdown")

        headerBar.addSubview(headerLabel)
        headerBar.addSubview(trailingLabel)

        banner.setAccessibilityIdentifier("\(idPrefix).banner")
        banner.allowsRetry = false

        signIn.setIdentifierPrefix("\(idPrefix).signin")
        signIn.onCopy = { [weak self] code in self?.onCopy?(code) }
        signIn.isHidden = true

        emptyLabel.stringValue = emptyText
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = Theme.fgMuted
        emptyLabel.setAccessibilityIdentifier("\(idPrefix).empty")
        emptyLabel.isHidden = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fred.col"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityIdentifier("\(idPrefix).table")
        table.setAccessibilityLabel("\(title) list")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        for v in [headerBar, banner, signIn, emptyLabel, scroll] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("FredPane is built in code") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = bounds.width
        var y: CGFloat = 0
        func place(_ view: NSView, height: CGFloat) {
            view.frame = NSRect(x: 0, y: y, width: w, height: view.isHidden ? 0 : height)
            y += view.isHidden ? 0 : height
        }
        place(headerBar, height: Self.headerHeight)
        headerBar.layoutSubtreeIfNeeded()
        let trailingWidth: CGFloat = trailingLabel.isHidden ? 0 : min(w * 0.6, max(0, w - 120))
        headerLabel.frame = NSRect(x: 10, y: 4, width: max(0, w - 20 - trailingWidth - 8), height: 18)
        trailingLabel.frame = NSRect(x: w - 10 - trailingWidth, y: 4, width: trailingWidth, height: 18)
        place(banner, height: FredSurfaceView.bannerHeight)
        place(signIn, height: Self.signInHeight)
        // The empty message sits where the rows would.
        emptyLabel.frame = NSRect(x: 10, y: y + 10, width: max(0, w - 20), height: 16)
        if !emptyLabel.isHidden { y += Self.emptyHeight }
        scroll.frame = NSRect(x: 0, y: y, width: w, height: scroll.isHidden ? 0 : max(0, bounds.height - y))
    }

    // swiftlint:disable:next function_parameter_count
    func render(header: String, trailing: String?, state: SourceState?, updatedAt: Date?, reason: String?, retryAt: Date?,
                prompt: DeviceFlowPrompt?, hasRows: Bool, showsEmptyMessage: Bool, now: Date, zone: TimeZone) {
        headerLabel.stringValue = header
        trailingLabel.stringValue = trailing ?? ""
        trailingLabel.isHidden = !showsCountdown
        trailingLabel.setAccessibilityLabel(trailing)

        if let prompt {
            banner.clear()
            signIn.show(prompt: prompt, now: now, zone: zone)
            signIn.isHidden = false
        } else {
            signIn.isHidden = true
            banner.show(state: state, updatedAt: updatedAt, reason: reason, retryAt: retryAt,
                        sourceName: sourceName, now: now)
        }

        emptyLabel.isHidden = !showsEmptyMessage
        scroll.isHidden = !hasRows
        table.reloadData()
        needsLayout = true
    }
}

// MARK: - Sign-in group

/// The device-flow prompt: verification URL (a link), the one-time code, a
/// Copy code button and the code's expiry.
private final class FredSignInView: NSView {

    var onCopy: ((String) -> Void)?

    private let intro = NSTextField(labelWithString: "Sign in to Microsoft 365")
    private let urlButton = NSButton(title: "", target: nil, action: nil)
    private let codeLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy code", target: nil, action: nil)
    private let expiryLabel = NSTextField(labelWithString: "")
    private var url: URL?
    private var code = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        intro.font = .systemFont(ofSize: 11)
        intro.textColor = Theme.fg
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 1

        urlButton.isBordered = false
        urlButton.alignment = .left
        urlButton.target = self
        urlButton.action = #selector(openURL)
        urlButton.setAccessibilityLabel("Open the Microsoft sign-in page")

        codeLabel.font = .monospacedSystemFont(ofSize: 16, weight: .semibold)
        codeLabel.textColor = Theme.fg
        codeLabel.isSelectable = true
        codeLabel.setAccessibilityLabel("One-time code")

        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.target = self
        copyButton.action = #selector(copyPressed)
        copyButton.setAccessibilityLabel("Copy code")

        expiryLabel.font = .systemFont(ofSize: 10)
        expiryLabel.textColor = Theme.fgMuted

        let codeRow = NSStackView(views: [codeLabel, copyButton])
        codeRow.orientation = .horizontal
        codeRow.spacing = 10
        codeRow.alignment = .centerY

        let stack = NSStackView(views: [intro, urlButton, codeRow, expiryLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("FredSignInView is built in code") }

    func setIdentifierPrefix(_ prefix: String) {
        setAccessibilityIdentifier(prefix)
        urlButton.setAccessibilityIdentifier("\(prefix).url")
        codeLabel.setAccessibilityIdentifier("\(prefix).code")
        copyButton.setAccessibilityIdentifier("\(prefix).copy")
        expiryLabel.setAccessibilityIdentifier("\(prefix).expiry")
    }

    func show(prompt: DeviceFlowPrompt, now: Date, zone: TimeZone) {
        url = URL(string: prompt.verificationUri)
        code = prompt.userCode
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: Theme.cornflower,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        if let url { attributes[.link] = url }
        urlButton.attributedTitle = NSAttributedString(string: prompt.verificationUri, attributes: attributes)
        codeLabel.stringValue = prompt.userCode
        let when = FredPresentation.clockText(prompt.expiresAt, in: zone)
        expiryLabel.stringValue = prompt.expiresAt > now ? "Expires at \(when)" : "Code expired at \(when)"
    }

    @objc private func openURL() {
        if let url { NSWorkspace.shared.open(url) }
    }

    @objc private func copyPressed() {
        onCopy?(code)
    }
}

// MARK: - Inbox rows

private final class FredInboxRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var items: [MailboxItem] = []
    private var now = Date()

    func set(_ items: [MailboxItem], now: Date) {
        self.items = items
        self.now = now
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let table = notification.object as? FredTable { table.onSelectionChange?(table) }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: FredInboxCell.reuseID, owner: nil) as? FredInboxCell)
            ?? FredInboxCell()
        cell.configure(items[row], now: now)
        return cell
    }
}

private final class FredInboxCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("fred.inbox.cell")

    private let dot = NSView()
    private let sender = NSTextField(labelWithString: "")
    private let subject = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let vip = NSTextField(labelWithString: "VIP")
    private let invite = NSTextField(labelWithString: "Invite")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        dot.setAccessibilityIdentifier("fred.row.unread")

        sender.lineBreakMode = .byTruncatingTail
        sender.textColor = Theme.fg
        sender.setAccessibilityIdentifier("fred.row.sender")
        sender.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for (tag, id) in [(vip, "fred.row.vip"), (invite, "fred.row.invite")] {
            tag.font = .systemFont(ofSize: 9, weight: .bold)
            tag.textColor = Theme.amber
            tag.setAccessibilityIdentifier(id)
            tag.setContentHuggingPriority(.required, for: .horizontal)
        }

        let senderRow = NSStackView(views: [sender, vip, invite])
        senderRow.orientation = .horizontal
        senderRow.spacing = 6
        senderRow.alignment = .firstBaseline

        subject.font = .systemFont(ofSize: 11)
        subject.textColor = Theme.fgMuted
        subject.lineBreakMode = .byTruncatingTail
        subject.setAccessibilityIdentifier("fred.row.subject")
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [senderRow, subject])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        time.font = .systemFont(ofSize: 10)
        time.textColor = Theme.fgMuted
        time.setAccessibilityIdentifier("fred.row.time")
        time.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [dot, text, time])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError("FredInboxCell is built in code") }

    func configure(_ item: MailboxItem, now: Date) {
        dot.isHidden = item.isRead
        sender.stringValue = FredPresentation.senderName(item.from)
        sender.font = item.isRead ? .systemFont(ofSize: 12) : .systemFont(ofSize: 12, weight: .semibold)
        subject.stringValue = item.subject
        time.stringValue = FredPresentation.relativeTime(item.receivedAt, now: now)
        vip.isHidden = !item.vip
        invite.isHidden = !item.isInvite
        setAccessibilityLabel(FredPresentation.inboxSpokenLabel(item, now: now))
    }
}

// MARK: - Today rows

private final class FredTodayRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var events: [CalendarEvent] = []
    private var now = Date()
    private var zone = TimeZone.current

    func set(_ events: [CalendarEvent], now: Date, zone: TimeZone) {
        self.events = events
        self.now = now
        self.zone = zone
    }

    func numberOfRows(in tableView: NSTableView) -> Int { events.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let table = notification.object as? FredTable { table.onSelectionChange?(table) }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard events.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: FredTodayCell.reuseID, owner: nil) as? FredTodayCell)
            ?? FredTodayCell()
        cell.configure(events[row], now: now, zone: zone)
        return cell
    }
}

private final class FredTodayCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("fred.today.cell")

    private let timeRange = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let nowTag = NSTextField(labelWithString: "Now")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseID
        wantsLayer = true

        timeRange.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeRange.textColor = Theme.fgMuted
        timeRange.setAccessibilityIdentifier("fred.row.timerange")
        timeRange.setContentHuggingPriority(.required, for: .horizontal)

        title.lineBreakMode = .byTruncatingTail
        title.textColor = Theme.fg
        title.setAccessibilityIdentifier("fred.row.title")
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        status.font = .systemFont(ofSize: 10)
        status.textColor = Theme.fgMuted
        status.setAccessibilityIdentifier("fred.row.status")

        nowTag.font = .systemFont(ofSize: 9, weight: .bold)
        nowTag.textColor = .black
        nowTag.drawsBackground = true
        nowTag.backgroundColor = .systemOrange
        nowTag.alignment = .center
        nowTag.setAccessibilityIdentifier("fred.row.now")
        nowTag.setContentHuggingPriority(.required, for: .horizontal)

        let top = NSStackView(views: [title, nowTag])
        top.orientation = .horizontal
        top.spacing = 6
        top.alignment = .firstBaseline

        let text = NSStackView(views: [top, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [timeRange, text])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeRange.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }

    required init?(coder: NSCoder) { fatalError("FredTodayCell is built in code") }

    func configure(_ event: CalendarEvent, now: Date, zone: TimeZone) {
        let isNow = FredPresentation.isNow(event, at: now)
        let cancelled = FredPresentation.isCancelled(event)
        let declined = FredPresentation.isDeclined(event)
        let dimmed = cancelled || declined

        timeRange.stringValue = FredPresentation.timeRange(event, in: zone)
        status.stringValue = FredPresentation.statusWord(event)
        nowTag.isHidden = !isNow
        layer?.backgroundColor = isNow ? NSColor.systemOrange.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor

        let font = NSFont.systemFont(ofSize: 12, weight: isNow ? .semibold : .regular)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: dimmed ? Theme.fgMuted : Theme.fg,
        ]
        if cancelled { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        title.attributedStringValue = NSAttributedString(string: event.title, attributes: attributes)

        setAccessibilityLabel(FredPresentation.todaySpokenLabel(event, now: now, in: zone))
    }
}
