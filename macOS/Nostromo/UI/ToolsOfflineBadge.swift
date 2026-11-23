import AppKit
import NostromoKit

// MARK: - ToolsOfflinePolicy

/// When to tell the operator that a running agent session has lost its Nostromo tools.
///
/// The session's `nostromo-mcp-bridge` is the process that carries every `mcp__nostromo__*` tool
/// call to the daemon. If its connection to the daemon is gone, the session keeps running but
/// can no longer call any of them. The daemon sends `session_bridge` on each change; this holds
/// the moment each tag went offline and answers "is it offline long enough to show?".
///
/// A tag is only ever tracked after the daemon reported a bridge for it, so a session that never
/// had one (a terminal pane, a daemon that predates the signal) is never offline here. Pure: the
/// clock is injected.
struct ToolsOfflinePolicy {
    /// A bridge reconnects within a second or two of a daemon restart; only a longer absence is
    /// worth the operator's attention.
    static let grace: TimeInterval = 10

    static let label = "Tools offline"
    static let accessibilityLabel = "Nostromo tools offline for this session"
    static let reconnectingLabel = "Reconnecting…"
    /// A click asks the session to reconnect the `nostromo` server at once (`session_mcp_v1`). The
    /// daemon also retries by itself, and a restart with `claude --continue` keeps the conversation.
    static let tooltip = "Nostromo tools are offline for this session. Click to reconnect them now. Nostromo also retries on its own; if this stays, restart the session with claude --continue."
    /// For a daemon without `session_mcp_v1`: nothing to click, so no invitation to.
    static let legacyTooltip = "Nostromo tools are offline for this session. Nostromo is asking the session to reconnect them; if this stays, restart the session with claude --continue."
    static let clickAccessibilityHelp = "Reconnects the Nostromo tools for this session."
    /// How long a click's failure notice stays in the badge.
    static let noticeDuration: TimeInterval = 8
    /// Least time between two clicks that send a reconnect.
    static let clickCooldown: TimeInterval = 5

    private var lostAt: [String: Date] = [:]
    /// Sessions that have stopped running. A bridge usually drops just *after* its session's
    /// process dies, so its "lost" report can arrive after the session ended and must not be
    /// held against a session that is not running.
    private var ended: Set<String> = []
    /// Bound on `ended`; past it the set is dropped (a late "lost" report may then count).
    private static let maxEnded = 1024

    /// The daemon reported `connected` for `tag`'s bridge.
    mutating func bridgeChanged(tag: String, connected: Bool, now: Date) {
        if connected {
            ended.remove(tag)
            lostAt.removeValue(forKey: tag)
        } else if lostAt[tag] == nil, !ended.contains(tag) {
            lostAt[tag] = now
        }
    }

    /// The session is no longer running (exited, stopped or crashed): there is nothing to be
    /// offline. A new process will report its own bridge.
    mutating func sessionEnded(tag: String) {
        if ended.count >= Self.maxEnded { ended.removeAll() }
        ended.insert(tag)
        lostAt.removeValue(forKey: tag)
    }

    /// The session's process is (again) running; its bridge reports count once more.
    mutating func sessionStarted(tag: String) {
        ended.remove(tag)
    }

    /// Forget everything: after the daemon connection drops, what was held is not the truth.
    mutating func reset() {
        lostAt.removeAll()
        ended.removeAll()
    }

    /// Tags whose bridge has been gone for more than `grace`.
    func offlineTags(now: Date) -> Set<String> {
        Set(lostAt.filter { now.timeIntervalSince($0.value) > Self.grace }.keys)
    }

    func isOffline(tag: String, now: Date) -> Bool {
        offlineTags(now: now).contains(tag)
    }

    /// When the next tag crosses the grace period (`nil`: none is waiting). Lets the owner
    /// schedule exactly one re-evaluation.
    func nextDeadline(now: Date) -> Date? {
        lostAt.values
            .map { $0.addingTimeInterval(Self.grace) }
            .filter { $0 >= now }
            .min()
    }
}

// MARK: - ToolsOfflineBadgeView

/// The muted "Tools offline" badge. Hidden until `apply(offline: true)`. Against a daemon with
/// `session_mcp_v1` it is a button: a click reconnects `nostromo` for the active session now.
///
/// Its label wraps and gives way first (low compression resistance), so a narrow window makes the
/// badge taller, never wider than the room it is given. Its colours are explicit: the app is pinned
/// to Dark Aqua and a system-drawn label would resolve dark-on-dark.
final class ToolsOfflineBadgeView: NSView {
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 2
    static let font = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let textColor = NSColor(white: 170 / 255, alpha: 1)
    static let fillColor = NSColor.white.withAlphaComponent(0.10)

    private let label = NSTextField(wrappingLabelWithString: ToolsOfflinePolicy.label)

    /// What the badge is saying: its name, a reconnect in flight, or why the last click failed.
    enum Mode: Equatable {
        case idle
        case reconnecting
        case failed(String)
    }

    private(set) var mode: Mode = .idle
    /// The session a click reconnects.
    var activeTag: () -> String? = { AppStore.shared.activeFocusSessionTag }
    var requests: McpRequests = .shared
    var now: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// Whether a press is a person's own (`HumanGesture`). A click, a key press or an Accessibility press
    /// that is not does nothing: only a person may ask a session to reconnect a server. Tests replace it.
    var permit: (NSView) -> HumanGestureVerdict = { HumanGesture.permit(NSApp?.currentEvent, control: $0) }
    private var nextClickAllowed = Date.distantPast
    private var noticeToken = 0

    /// A click does something only against a daemon that takes `session_mcp`.
    var isClickable: Bool { requests.isAvailable }
    override var acceptsFirstResponder: Bool { !isHidden && isClickable }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = Self.fillColor.cgColor
        appearance = NSAppearance(named: .darkAqua)
        isHidden = true

        label.font = Self.font
        label.textColor = Self.textColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        // The label gives way before anything around it does.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
        ])

        setAccessibilityElement(true)
        setAccessibilityLabel(ToolsOfflinePolicy.accessibilityLabel)
        refreshAffordance()
    }

    /// Show or hide the badge. Changes nothing else (no focus, no layout outside the badge). A badge
    /// that goes away forgets its reconnect state; one that comes back says its name again.
    func apply(offline: Bool) {
        isHidden = !offline
        if !offline { setMode(.idle) }
        refreshAffordance()
    }

    /// The tooltip and the accessibility role follow whether a click does anything.
    func refreshAffordance() {
        if isClickable {
            toolTip = ToolsOfflinePolicy.tooltip
            setAccessibilityRole(.button)
            setAccessibilityHelp(ToolsOfflinePolicy.clickAccessibilityHelp)
        } else {
            toolTip = ToolsOfflinePolicy.legacyTooltip
            setAccessibilityRole(.staticText)
            setAccessibilityHelp(ToolsOfflinePolicy.legacyTooltip)
        }
    }

    /// Ask the session to reconnect the `nostromo` server now. Ignored while a request is running, within
    /// 5 s of the last click, without an active session, and against a daemon without `session_mcp_v1`.
    func activate() {
        guard isClickable, !isHidden, mode != .reconnecting, now() >= nextClickAllowed,
              let tag = activeTag() else { return }
        nextClickAllowed = now().addingTimeInterval(ToolsOfflinePolicy.clickCooldown)
        setMode(.reconnecting)
        requests.request(tag: tag, action: "reconnect", server: McpPanelModel.nostromoServer) { [weak self] reply in
            self?.finish(reply)
        }
    }

    private func finish(_ reply: TaskReply<SessionMcpResultWire>) {
        guard mode == .reconnecting else { return }
        switch reply {
        case .answered(let wire) where wire.outcome == .ok:
            // The badge goes the normal way once the bridge reports connected.
            setMode(.idle)
        case .answered(let wire):
            setMode(.failed(McpPanelModel.failureText(wire)))
        case .timedOut:
            setMode(.failed("the daemon did not answer in time"))
        case .failed(let reason):
            setMode(.failed(reason))
        }
    }

    private func setMode(_ new: Mode) {
        mode = new
        noticeToken += 1
        switch new {
        case .idle:
            label.stringValue = ToolsOfflinePolicy.label
        case .reconnecting:
            label.stringValue = ToolsOfflinePolicy.reconnectingLabel
        case .failed(let reason):
            let text = "Reconnect failed: \(reason)"
            label.stringValue = text
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            let token = noticeToken
            schedule(ToolsOfflinePolicy.noticeDuration) { [weak self] in
                guard let self, self.noticeToken == token else { return }
                self.setMode(.idle)
            }
        }
    }

    /// The whole badge takes the click, not the label inside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isClickable, !isHidden, bounds.contains(convert(point, from: superview)) else { return super.hitTest(point) }
        return self
    }

    /// Press the badge for a person: `activate`, unless `permit` refuses the gesture.
    private func activateIfHuman() {
        if case .human = permit(self) { activate() }
    }

    override func mouseDown(with event: NSEvent) {
        if isClickable {
            activateIfHuman()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return, Enter and Space press it.
        if isClickable, [36, 76, 49].contains(event.keyCode) {
            activateIfHuman()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isClickable else { return false }
        activateIfHuman()
        return true
    }

    /// The text the badge shows.
    var text: String { label.stringValue }

    override func layout() {
        // A wrapping label needs the width it may wrap at before it can report a height.
        label.preferredMaxLayoutWidth = max(0, bounds.width - 2 * Self.horizontalPadding)
        super.layout()
    }
}
