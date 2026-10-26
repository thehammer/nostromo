import Foundation

/// Remembers when the user last looked at the Sentry tab, so issues first seen
/// since then can be marked "new".
///
/// More than one surface can show the tab at once (a second window, a recreated
/// surface), so showing and leaving are counted. Only the first show takes a
/// baseline (the time stored when nobody was looking: issues that arrive while
/// the tab is open stay "new"), and only the last leave stores a new time. Seeing
/// the tab again in a second window never wipes the markers of the first.
final class TeriSentryViewTracker {
    static let lastViewedKey = "nostromo.teri.sentryLastViewed"

    /// Nil until the tab has been shown once: nothing is "new" before that.
    private(set) var baseline: Date?

    /// How often the stored last-viewed time is refreshed while the tab is shown.
    static let persistInterval: TimeInterval = 60

    private let defaults: UserDefaults
    private let now: () -> Date
    private let scheduler: WorkScheduler
    private var visibleCount = 0
    private var cancelPeriodicPersist: (() -> Void)?

    init(defaults: UserDefaults, now: @escaping () -> Date = Date.init, scheduler: WorkScheduler = .main) {
        self.defaults = defaults
        self.now = now
        self.scheduler = scheduler
    }

    /// Showing does NOT store a time: if the app dies mid-view, the next baseline must
    /// still be the previous view, so issues from this session stay "new". The time is
    /// stored when the tab is left and, while it is shown, every `persistInterval`.
    func didShow() {
        visibleCount += 1
        guard visibleCount == 1 else { return }
        baseline = defaults.object(forKey: Self.lastViewedKey) as? Date
        schedulePersist()
    }

    func didLeave() {
        guard visibleCount > 0 else { return }
        visibleCount -= 1
        guard visibleCount == 0 else { return }
        cancelPeriodicPersist?()
        cancelPeriodicPersist = nil
        defaults.set(now(), forKey: Self.lastViewedKey)
    }

    /// Store the time now if the tab is shown, without leaving it. For a quit (or a window
    /// close) with the tab open: nothing else runs `didLeave` first, and without this the
    /// stored time is up to `persistInterval` stale and everything shows "new" next launch.
    func flush() {
        guard visibleCount > 0 else { return }
        defaults.set(now(), forKey: Self.lastViewedKey)
    }

    private func schedulePersist() {
        cancelPeriodicPersist = scheduler.schedule(Self.persistInterval) { [weak self] in
            guard let self, self.visibleCount > 0 else { return }
            self.defaults.set(self.now(), forKey: Self.lastViewedKey)
            self.schedulePersist()
        }
    }

    /// The user says everything so far has been seen: nothing is "new" until more arrives.
    func markSeen() {
        let seenAt = now()
        baseline = seenAt
        defaults.set(seenAt, forKey: Self.lastViewedKey)
    }

    func isNew(_ item: WorkItem) -> Bool {
        guard let baseline, let createdAt = item.createdAt else { return false }
        return createdAt > baseline
    }
}

/// The Sentry tab: every unresolved Sentry issue, newest activity first.
///
/// Two single-select controls narrow it, both remembered: Mine | Unassigned | All
/// (default Mine) and Production | All (default All). "Mine" is assigned directly to
/// the user, not to a team; "All" is every unresolved issue the daemon lists,
/// including issues assigned to others. An empty Mine shows the normal empty state
/// rather than falling back to All. "Production" means the issue had an event in
/// the production environment in the last 14 days; an issue the daemon did not see
/// there has no environment (which is not the same as non-production).
///
/// Rows read `ERROR  TypeError in FacesheetParser … 312 events / 24 h · 41 users ·
/// last seen 4 min ago  new`. (Sentry's issue list does not say which environment
/// an issue is in, so rows still show no environment; the Production | All toggle
/// filters on the daemon's production marker.)
enum TeriSentryTab {
    /// Replaceable so tests can inject a clock and isolated defaults.
    static var tracker = TeriSentryViewTracker(defaults: .standard)
    static var now: () -> Date = Date.init

    /// The `WorkItem.assignee` buckets the daemon tags issues with.
    static let mine = "me"
    static let unassigned = "unassigned"
    /// The `WorkItem.environment` the daemon sets on issues seen in production.
    static let production = "production"

    static let config = TeriTabConfig(
        tab: .sentry,
        sourceName: "Sentry",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: now()) },
            menuFacets: [.project],
            scopes: [
                WorkListScope(facet: .assignee,
                              options: [("Mine", [mine]), ("Unassigned", [unassigned]), ("All", [])],
                              accessibilityLabel: "Show"),
                WorkListScope(facet: .environment,
                              options: [("Production", [production]), ("All", [])],
                              accessibilityLabel: "Environment"),
            ],
            searchPlaceholder: "Filter issues"),
        emptyMessage: "No unresolved Sentry issues.",
        onShow: { tracker.didShow() },
        onLeave: { tracker.didLeave() },
        rowRefreshInterval: 60)

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

        let status = isNew ? "new" : ""

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
