import Foundation

/// Remembers when the user last looked at the Sentry tab, so issues first seen
/// since then can be marked "new". The stored time moves when the tab is shown
/// and when the user leaves it; the baseline rows are compared with is the time
/// stored at the moment the tab was shown, so issues that arrive while it is
/// open are still "new".
final class TeriSentryViewTracker {
    static let lastViewedKey = "nostromo.teri.sentryLastViewed"

    /// Nil until the tab has been shown once: nothing is "new" before that.
    private(set) var baseline: Date?

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    func didShow() {
        baseline = defaults.object(forKey: Self.lastViewedKey) as? Date
        defaults.set(now(), forKey: Self.lastViewedKey)
    }

    func didLeave() {
        defaults.set(now(), forKey: Self.lastViewedKey)
    }

    func isNew(_ item: WorkItem) -> Bool {
        guard let baseline, let createdAt = item.createdAt else { return false }
        return createdAt > baseline
    }
}

/// The Sentry tab: unresolved issues assigned to the user plus fresh unassigned
/// errors, newest activity first. Rows read
/// `ERROR  TypeError in FacesheetParser … 312 events / 24 h · 41 users · last seen 4 min ago  new · production`.
enum TeriSentryTab {
    /// Replaceable so tests can inject a clock and isolated defaults.
    static var tracker = TeriSentryViewTracker(defaults: .standard)

    static let config = TeriTabConfig(
        tab: .sentry,
        sourceName: "Sentry",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: Date()) },
            menuFacets: [.project, .environment],
            searchPlaceholder: "Filter issues"),
        emptyMessage: "No unresolved Sentry issues.",
        onShow: { tracker.didShow() },
        onLeave: { tracker.didLeave() })

    /// What one issue row shows, relative to `now`.
    static func rowContent(for item: WorkItem, now: Date) -> WorkRowContent {
        let isNew = tracker.isNew(item)
        let events = item.metrics["events_24h"]
        let users = item.metrics["users"]
        let age = item.updatedAt.map { relativeAge(of: $0, now: now) }

        var summary: [String] = []
        if let events { summary.append("\(events) \(events == 1 ? "event" : "events") / 24 h") }
        if let users { summary.append("\(users) \(users == 1 ? "user" : "users")") }
        if let age { summary.append("last seen \(age.short)") }

        let status = [isNew ? "new" : nil, item.environment].compactMap { $0 }.joined(separator: " · ")

        var spoken = ["Sentry issue"]
        if let project = item.project { spoken.append(project) }
        spoken.append(item.title)
        if let events { spoken.append("\(events) \(events == 1 ? "event" : "events")") }
        if let age { spoken.append("last seen \(age.spoken)") }
        if isNew { spoken.append("new") }

        return WorkRowContent(
            priorityText: item.severity?.uppercased(),
            priorityRank: item.priority?.rank,
            title: item.title,
            dueText: summary.isEmpty ? nil : summary.joined(separator: " · "),
            statusText: status.isEmpty ? nil : status,
            accessibilityLabel: spoken.joined(separator: ", "))
    }

    /// "4 min ago" / "4 minutes ago".
    private static func relativeAge(of date: Date, now: Date) -> (short: String, spoken: String) {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return ("just now", "just now") }
        let units: (Int, String, String) =
            seconds < 3_600 ? (seconds / 60, "min", "minute")
            : seconds < 86_400 ? (seconds / 3_600, "h", "hour")
            : (seconds / 86_400, "d", "day")
        return ("\(units.0) \(units.1) ago", "\(units.0) \(units.2)\(units.0 == 1 ? "" : "s") ago")
    }
}
