import AppKit

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
    static let tooltip = "Nostromo tools are offline for this session. Run /mcp and reconnect nostromo, or restart the session."

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

/// The muted "Tools offline" badge. Hidden until `apply(offline: true)`.
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

        toolTip = ToolsOfflinePolicy.tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(ToolsOfflinePolicy.accessibilityLabel)
        setAccessibilityHelp(ToolsOfflinePolicy.tooltip)
    }

    /// Show or hide the badge. Changes nothing else (no focus, no layout outside the badge).
    func apply(offline: Bool) {
        isHidden = !offline
    }

    /// The text the badge shows.
    var text: String { label.stringValue }

    override func layout() {
        // A wrapping label needs the width it may wrap at before it can report a height.
        label.preferredMaxLayoutWidth = max(0, bounds.width - 2 * Self.horizontalPadding)
        super.layout()
    }
}
