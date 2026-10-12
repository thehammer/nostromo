import AppKit
import Combine

/// The Picks tab's entry in the tab strip. Picks are Teri's own selection rather
/// than a work source, so the tab has no `WorkListConfig`: `TeriSurfaceView` hosts
/// a `TeriPicksView` in its list pane instead.
enum TeriPicksTab {
    static let config = TeriTabConfig(
        tab: .picks,
        sourceName: "Picks",
        list: nil,
        emptyMessage: "Teri has not picked anything yet.")

    /// How long after an activation (tab shown, window key) a store change may still
    /// carry out the first-open request that could not go out at that moment.
    static let pendingRetryWindow: TimeInterval = 30
}

/// What one pick row shows.
struct PicksRowContent: Equatable {
    /// Glyph and word of the source ("◇ Jira").
    var sourceText: String
    var title: String
    var reason: String
    /// "done since" once the item was resolved at its source after Teri chose it.
    var doneSinceText: String?
    /// Title and reason are struck through (the item is done).
    var isStruck: Bool
    /// "Sent to <label>" while a live focus or job holds the item.
    var sentText: String?
    /// What VoiceOver reads.
    var accessibilityLabel: String
}

/// The Picks tab's list pane: a header (when the picks were made, Refresh picks,
/// "Refreshing…"), notes about unavailable sources and failures, and one row per
/// pick. It reads `WorkStore.picks`, never keeps a copy of its own beyond the
/// rows it draws, and asks the daemon for new picks through the store.
final class TeriPicksView: NSView {
    /// The user picked a row (nil: the selection went away).
    var onSelect: ((Pick?) -> Void)?
    /// The user clicked a row's "Sent to …" line: go to that focus or job (the newest marker).
    var onOpenSent: ((Pick, SentMarker) -> Void)?

    private(set) var selectedPickId: String?
    private(set) var visibleRows: [PicksRowContent] = []
    /// The newest live sent marker of each pick's item.
    private var sentMarkers: [String: SentMarker] = [:]

    private let store: WorkStore
    private let now: () -> Date
    private let calendar: Calendar
    private var cancellables = Set<AnyCancellable>()
    private var reloadScheduled = false
    private var isShowing = false
    /// The local day a first-open request was last SENT for: one per day per view.
    /// Set only once a frame actually went out.
    private var firstOpenDay: Date?
    /// When the activation (tab shown, window key) was whose first-open request could
    /// not go out yet (no connection, no way to send, no picks snapshot yet). A store
    /// change retries it only within [`TeriPicksTab.pendingRetryWindow`] of that
    /// activation, so an unattended reconnect never starts a generation; never from the clock.
    private var firstOpenPendingSince: Date?
    private var keyObserver: NSObjectProtocol?
    private var clockTimer: Timer?
    private var picks: [Pick] = []

    private let headerLabel = NSTextField(labelWithString: "")
    private let refreshingLabel = NSTextField(labelWithString: "Refreshing…")
    private let refreshButton = NSButton(title: "Refresh picks", target: nil, action: nil)
    private let unavailableLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let rowStack = NSStackView()
    private var rowViews: [PickRowView] = []

    init(store: WorkStore, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.store = store
        self.now = now
        self.calendar = calendar
        super.init(frame: .zero)
        buildViews()
        store.objectWillChange
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &cancellables)
        // A window coming to the front is a person arriving: the other moment
        // (with the tab becoming visible) a day's first picks may be requested.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = self.window, note.object as? NSWindow === window else { return }
            self.windowDidBecomeKey()
        }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        clockTimer?.invalidate()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Read

    /// "Generated 2 h ago", or "No picks yet".
    var headerText: String { headerLabel.stringValue }

    var isRefreshingVisible: Bool { !refreshingLabel.isHidden }
    var refreshingText: String? { isRefreshingVisible ? refreshingLabel.stringValue : nil }
    var isRefreshButtonEnabled: Bool { refreshButton.isEnabled }
    var refreshButtonTitle: String { refreshButton.title }
    /// The explicit foreground colour of the button's title.
    var refreshButtonTitleColor: NSColor? {
        refreshButton.attributedTitle.length == 0 ? nil
            : refreshButton.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
    var unavailableNote: String? { unavailableLabel.isHidden ? nil : unavailableLabel.stringValue }
    var errorNote: String? { errorLabel.isHidden ? nil : errorLabel.stringValue }
    var emptyStateText: String? { emptyLabel.isHidden ? nil : emptyLabel.stringValue }

    // MARK: Actions

    /// Ask the daemon for new picks, as the button does. Does nothing while the
    /// button is disabled (a generation is running, or the daemon is away).
    @objc func pressRefresh() {
        guard refreshButton.isEnabled else { return }
        store.refreshPicks(reason: "manual")
    }

    /// The tab became visible: ask for picks when today has none yet.
    func tabDidShow() {
        isShowing = true
        reload()
        requestFirstOpenPicksIfDue(activatedAt: now())
        clockTimer?.invalidate()
        // The header says how long ago: keep it true while the tab stays open.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.clockTick() }
    }

    func tabDidLeave() {
        isShowing = false
        firstOpenPendingSince = nil
        clockTimer?.invalidate()
        clockTimer = nil
    }

    /// What the 60 s timer does: keep the header's "2 h ago" true. It never asks
    /// for picks: a tab left open overnight with nobody there must not start an
    /// unattended generation at midnight.
    func clockTick() {
        reload(retryFirstOpen: false)
    }

    /// The text colours the row at `index` draws right now (source, title, reason,
    /// then "done since" and "Sent to" when present).
    func textColors(forRow index: Int) -> [NSColor] {
        rowViews.indices.contains(index) ? rowViews[index].textColors : []
    }

    /// Select `itemId`'s row (as a click does) and report it.
    func select(itemId: String) {
        guard let pick = picks.first(where: { $0.itemId == itemId }) else { return }
        selectedPickId = itemId
        updateSelectionHighlight()
        onSelect?(pick)
    }

    /// Give the keyboard to the rows (arrow keys move the selection).
    func focusRows() {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: moveSelection(by: 1)    // down
        case 126: moveSelection(by: -1)   // up
        case 36, 76:                         // Return, keypad Enter
            // ⌘Return: go to where the selected pick was sent.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                openSentOfSelection()
            } else {
                super.keyDown(with: event)
            }
        default: super.keyDown(with: event)
        }
    }

    /// ⌘Return on the selected pick: go to the focus or job its newest "Sent to …" names.
    /// False when the pick has none.
    @discardableResult
    func openSentOfSelection() -> Bool {
        guard let id = selectedPickId else { return false }
        return clickSent(itemId: id)
    }

    // MARK: Header wording

    /// "Generated just now", "5 min ago", "2 h ago" (same calendar day), "yesterday 14:05", "Oct 8 14:05".
    static func generatedText(_ generatedAt: Date, now: Date, calendar: Calendar) -> String {
        let elapsed = now.timeIntervalSince(generatedAt)
        if elapsed < 60 { return "Generated just now" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: generatedAt),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1:
            return elapsed < 3_600 ? "Generated \(Int(elapsed / 60)) min ago" : "Generated \(Int(elapsed / 3_600)) h ago"
        case 1:
            return "Generated yesterday " + TeriDateFormatters.string(from: generatedAt, pattern: "HH:mm", calendar: calendar)
        default:
            return "Generated " + TeriDateFormatters.string(from: generatedAt, pattern: "MMM d HH:mm", calendar: calendar)
        }
    }

    /// "Sentry unavailable; picks exclude Sentry", "Jira and Sentry …", "Todos, Jira and Sentry …".
    static func unavailableText(_ sources: [WorkSource]) -> String? {
        let order = WorkSource.allCases
        let names = Set(sources).sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }.map(\.displayName)
        let list: String
        switch names.count {
        case 0: return nil
        case 1: list = names[0]
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "\(list) unavailable; picks exclude \(list)"
    }

    // MARK: Build

    private func buildViews() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        headerLabel.font = Theme.statusFont
        headerLabel.textColor = Theme.fgMuted
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshingLabel.font = Theme.statusFont
        refreshingLabel.textColor = Theme.amber
        refreshingLabel.setAccessibilityLabel("Refreshing picks")
        refreshButton.target = self
        refreshButton.action = #selector(pressRefresh)
        refreshButton.bezelStyle = .recessed
        // Explicit colour, as the tab buttons have: the default title colour follows
        // the system appearance and goes dark on this always-dark surface.
        refreshButton.attributedTitle = NSAttributedString(string: "Refresh picks", attributes: [
            .foregroundColor: Theme.fg,
            .font: Theme.statusFont,
        ])
        refreshButton.setAccessibilityLabel("Refresh picks")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerLabel, refreshingLabel, spacer, refreshButton])
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 6, right: 10)

        for note in [unavailableLabel, errorLabel] {
            note.font = Theme.statusFont
            note.isHidden = true
            note.preferredMaxLayoutWidth = 400
        }
        unavailableLabel.textColor = Theme.amber
        errorLabel.textColor = Theme.redSweater
        emptyLabel.font = Theme.statusFont
        emptyLabel.textColor = Theme.fgMuted
        emptyLabel.isHidden = true

        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 2
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        let document = PicksFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            rowStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let column = NSStackView(views: [header, unavailableLabel, errorLabel, emptyLabel, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        var constraints = [
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        for view in [header, scroll] { constraints.append(view.widthAnchor.constraint(equalTo: column.widthAnchor)) }
        for note in [unavailableLabel, errorLabel, emptyLabel] {
            constraints.append(note.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -20))
        }
        NSLayoutConstraint.activate(constraints)
    }

    // MARK: Reload

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reload()
        }
    }

    private func reload(retryFirstOpen: Bool = true) {
        let snapshot = store.picks
        picks = snapshot?.items ?? []
        let rows = makeRows(picks)
        if rows != visibleRows || rowViews.count != rows.count {
            visibleRows = rows
            rebuildRows()
        }
        if let selectedPickId, !picks.contains(where: { $0.itemId == selectedPickId }) {
            self.selectedPickId = nil
            onSelect?(nil)
        }
        updateSelectionHighlight()

        let generating = snapshot?.generating ?? false
        headerLabel.stringValue = snapshot?.generatedAt.map {
            Self.generatedText($0, now: now(), calendar: calendar)
        } ?? "No picks yet"
        refreshingLabel.isHidden = !generating
        refreshButton.isEnabled = !generating && store.isConnected
        unavailableLabel.stringValue = Self.unavailableText(snapshot?.unavailableSources ?? []) ?? ""
        unavailableLabel.isHidden = unavailableLabel.stringValue.isEmpty
        errorLabel.stringValue = snapshot?.error ?? ""
        errorLabel.isHidden = snapshot?.error == nil
        emptyLabel.stringValue = TeriPicksTab.config.emptyMessage
        emptyLabel.isHidden = !(rows.isEmpty && !generating)
        dimIfDisconnected()
        if retryFirstOpen, let since = firstOpenPendingSince {
            if now().timeIntervalSince(since) <= TeriPicksTab.pendingRetryWindow {
                requestFirstOpenPicksIfDue(activatedAt: since)
            } else {
                firstOpenPendingSince = nil   // nobody was there to ask for it: only a new activation does
            }
        }
    }

    private func dimIfDisconnected() {
        alphaValue = store.isConnected ? 1 : 0.5
    }

    /// A window of this view came to the front.
    private func windowDidBecomeKey() {
        guard isShowing else { return }
        requestFirstOpenPicksIfDue(activatedAt: now())
    }

    /// The first time the tab is open on a day whose picks Teri has not made yet,
    /// ask the daemon to make them. Called when the tab is shown and when its
    /// window becomes key (plus store changes within `pendingRetryWindow` of one
    /// of those, while a request is pending), never from the clock. Once per local day per view, and the day counts as done
    /// only once the frame was sent, so a failed generation is never retried in a
    /// loop from here (the daemon keeps its own attempt state too; the button is
    /// for retrying).
    private func requestFirstOpenPicksIfDue(activatedAt: Date) {
        guard isShowing else {
            firstOpenPendingSince = nil
            return
        }
        guard let snapshot = store.picks else {
            firstOpenPendingSince = activatedAt   // the picks have not arrived yet
            return
        }
        firstOpenPendingSince = nil
        guard !snapshot.generating else { return }
        let today = calendar.startOfDay(for: now())
        guard firstOpenDay != today else { return }
        let isStale = snapshot.generatedAt.map { $0 < today } ?? true
        guard isStale else { return }
        if store.refreshPicks(reason: "first_open") {
            firstOpenDay = today
        } else {
            firstOpenPendingSince = activatedAt   // not connected, or nothing to send with: when that changes
        }
    }

    // MARK: Rows

    private func makeRows(_ picks: [Pick]) -> [PicksRowContent] {
        let ids = Set(picks.map(\.itemId))
        var sentMarkers: [String: [SentMarker]] = [:]
        for item in store.allItems where !item.sent.isEmpty && ids.contains(item.id) {
            sentMarkers[item.id] = item.sent
        }
        self.sentMarkers = sentMarkers.compactMapValues(\.last)
        return picks.map { pick in
            let sent = sentMarkers[pick.itemId].map(Self.sentText)
            let source = pick.source.displayName
            var spoken = [source, pick.title, pick.reason]
            if pick.doneSince { spoken.append("done since") }
            if let sent { spoken.append(sent) }
            return PicksRowContent(
                sourceText: "\(pick.source.glyph) \(source)",
                title: pick.title,
                reason: pick.reason,
                doneSinceText: pick.doneSince ? "done since" : nil,
                isStruck: pick.doneSince,
                sentText: sent,
                accessibilityLabel: spoken.joined(separator: ", "))
        }
    }

    /// "Sent to Fix webhook, Refund spike" for focuses, "Queued as Mother job" for jobs.
    private static func sentText(_ markers: [SentMarker]) -> String {
        let focusLabels = markers.filter { $0.kind != "mother_job" }.map(\.label)
        var parts: [String] = []
        if !focusLabels.isEmpty { parts.append("Sent to " + focusLabels.joined(separator: ", ")) }
        if markers.contains(where: { $0.kind == "mother_job" }) { parts.append("Queued as Mother job") }
        return parts.joined(separator: " · ")
    }

    /// Click the "Sent to …" line of `itemId`'s row (tests). False when it has none.
    @discardableResult
    func clickSent(itemId: String) -> Bool {
        guard let pick = picks.first(where: { $0.itemId == itemId }), let marker = sentMarkers[itemId] else { return false }
        onOpenSent?(pick, marker)
        return true
    }

    private func rebuildRows() {
        for view in rowViews { view.removeFromSuperview() }
        rowViews = visibleRows.enumerated().map { index, content in
            let row = PickRowView(content: content)
            row.onClick = { [weak self] in
                guard let self, self.picks.indices.contains(index) else { return }
                self.select(itemId: self.picks[index].itemId)
                self.window?.makeFirstResponder(self)
            }
            row.onSentClick = { [weak self] in
                guard let self, self.picks.indices.contains(index),
                      let marker = self.sentMarkers[self.picks[index].itemId] else { return }
                self.onOpenSent?(self.picks[index], marker)
            }
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
            return row
        }
    }

    private func updateSelectionHighlight() {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = picks.indices.contains(index) && picks[index].itemId == selectedPickId
        }
    }

    private func moveSelection(by delta: Int) {
        guard !picks.isEmpty else { return }
        let current = picks.firstIndex { $0.itemId == selectedPickId }
        let next = current.map { min(max($0 + delta, 0), picks.count - 1) } ?? (delta > 0 ? 0 : picks.count - 1)
        select(itemId: picks[next].itemId)
    }
}

// MARK: - Source wording

private extension WorkSource {
    var glyph: String {
        switch self {
        case .todos:    return "☐"
        case .repoDocs: return "▤"
        case .jira:     return "◇"
        case .sentry:   return "⚠"
        }
    }
}

extension WorkSource {
    /// Word for the source in notes and rows: "Todos", "Repo docs", "Jira", "Sentry".
    var displayName: String {
        switch self {
        case .todos:    return "Todos"
        case .repoDocs: return "Repo docs"
        case .jira:     return "Jira"
        case .sentry:   return "Sentry"
        }
    }
}

// MARK: - Row view

private final class PicksFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One pick: source and title on the first line, the reason (and markers) under it.
///
/// The selected row is filled with `Theme.bgBarActive` and draws its text in the
/// light colours that theme pins for that fill (all at least 5:1); the unselected
/// colours (muted grey, sage, cornflower) are for the dark surface only.
private final class PickRowView: NSView {
    var onClick: (() -> Void)?
    var onSentClick: (() -> Void)?
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            layer?.backgroundColor = isSelected ? Theme.bgBarActive.cgColor : NSColor.clear.cgColor
            applyColors()
        }
    }

    private let content: PicksRowContent
    private let source: NSTextField
    private let title: NSTextField
    private let reason: NSTextField
    private let doneSince: NSTextField?
    private let sent: NSTextField?

    /// Every text colour drawn now: source, title, reason, done-since and sent when present.
    var textColors: [NSColor] {
        [source.textColor, Self.color(of: title), Self.color(of: reason), doneSince?.textColor, sent?.textColor]
            .compactMap { $0 }
    }

    init(content: PicksRowContent) {
        self.content = content
        source = NSTextField(labelWithString: content.sourceText)
        title = NSTextField(labelWithString: "")
        reason = NSTextField(labelWithString: "")
        doneSince = content.doneSinceText.map { NSTextField(labelWithString: $0) }
        sent = content.sentText.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        source.font = Theme.statusFont
        source.setContentHuggingPriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var firstLine: [NSView] = [source, title]
        if let doneSince {
            doneSince.font = Theme.statusFont
            doneSince.setContentHuggingPriority(.required, for: .horizontal)
            firstLine.append(doneSince)
        }
        let top = NSStackView(views: firstLine)
        top.orientation = .horizontal
        top.spacing = 6

        reason.lineBreakMode = .byWordWrapping
        reason.maximumNumberOfLines = 0
        reason.preferredMaxLayoutWidth = 420
        var lines: [NSView] = [top, reason]
        if let sent {
            sent.font = Theme.statusFont
            lines.append(sent)
        }
        let column = NSStackView(views: lines)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applyColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(content.accessibilityLabel)
        // The "Sent to …" line is clickable; VoiceOver reaches it as a custom action on the row.
        if let sentText = content.sentText {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Go to: \(sentText)") { [weak self] in
                    guard let self, let onSentClick = self.onSentClick else { return false }
                    onSentClick()
                    return true
                },
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        if let sent, !sent.isHidden, sent.bounds.contains(sent.convert(event.locationInWindow, from: nil)) {
            onSentClick?()
        } else {
            onClick?()
        }
    }

    private func applyColors() {
        let selected = isSelected
        let muted = selected ? Theme.tabCaptionOnActive : Theme.fgMuted
        let primary = selected ? NSColor.white : Theme.fg
        source.textColor = muted
        doneSince?.textColor = selected ? Theme.fg : Theme.sage
        sent?.textColor = selected ? Theme.fg : Theme.cornflower
        title.attributedStringValue = Self.styled(content.title, struck: content.isStruck, font: Theme.tabFontBold, color: primary)
        reason.attributedStringValue = Self.styled(content.reason, struck: content.isStruck, font: Theme.tabFont, color: muted)
    }

    private static func color(of field: NSTextField) -> NSColor? {
        guard field.attributedStringValue.length > 0 else { return field.textColor }
        return field.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }

    private static func styled(_ text: String, struck: Bool, font: NSFont, color: NSColor) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if struck { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attributes)
    }
}
