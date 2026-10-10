import Foundation

// MARK: - FocusBadge

/// What a sidebar row shows for a focus beyond its label: an optional count pill, an
/// optional second-line summary, and whether the focus needs the operator right now.
struct FocusBadge: Equatable {
    enum Level: Equatable { case info, attention }

    var pill: String?
    var detail: String?
    var level: Level
    var accessibilityLabel: String

    init(pill: String? = nil, detail: String? = nil, level: Level = .info, accessibilityLabel: String) {
        self.pill = pill
        self.detail = detail
        self.level = level
        self.accessibilityLabel = accessibilityLabel
    }
}

// MARK: - FocusBadgeRegistry

/// Badges published per `(focus tag, source key)`, projected to one badge per tag.
/// Modeled on `AttentionRegistry`; any focus tag may publish, so dynamic focuses can
/// use it later.
struct FocusBadgeRegistry {
    private struct Key: Hashable {
        let tag: String
        let source: String
    }

    private var entries: [Key: FocusBadge] = [:]

    /// Publish (or replace) a source's badge for a tag; `nil` clears it.
    mutating func publish(tag: String, sourceKey: String, badge: FocusBadge?) {
        if let badge { entries[Key(tag: tag, source: sourceKey)] = badge } else { clear(tag: tag, sourceKey: sourceKey) }
    }

    mutating func clear(tag: String, sourceKey: String) {
        entries.removeValue(forKey: Key(tag: tag, source: sourceKey))
    }

    /// The tag's projected badge. Attention wins over info; the pill, detail and
    /// accessibility label come from ONE source (the first, by source key, that has a
    /// pill, else the first overall) so they never mix text from different sources.
    func badge(for tag: String) -> FocusBadge? {
        let mine = entries.filter { $0.key.tag == tag }.sorted { $0.key.source < $1.key.source }.map(\.value)
        guard var primary = mine.first(where: { $0.pill != nil }) ?? mine.first else { return nil }
        if mine.contains(where: { $0.level == .attention }) { primary.level = .attention }
        return primary
    }

    /// Tags whose projected badge is at attention level.
    var attentionTags: Set<String> {
        Set(entries.filter { $0.value.level == .attention }.map(\.key.tag))
    }
}

// MARK: - BadgeProviders

/// Pure functions from the Mac app's already-held data to a badge. No `AppStore`.
/// `nil` means "nothing to show". A failed or unauthenticated source never yields a
/// numeric count: it yields a word.
enum BadgeProviders {

    /// A meeting starting within this many seconds (or in progress) needs the operator.
    static let meetingAttentionWindow: TimeInterval = 10 * 60

    // MARK: Fred

    static func fred(mailbox: MailboxSnapshot?, calendar: CalendarSnapshot?, now: Date) -> FocusBadge? {
        guard mailbox != nil || calendar != nil else { return nil }

        var pill: String?
        var mailDetail: String?
        var mailWords: String?
        var unreadWords: String?
        if let mailbox {
            if mailbox.authPrompt != nil {
                pill = "!"; mailDetail = "Sign-in needed"; mailWords = "sign-in needed"
            } else if mailbox.error != nil || mailbox.stale {
                mailDetail = "Mail unavailable"; mailWords = "mail unavailable"
            } else if mailbox.unreadCount > 0 {
                pill = "\(mailbox.unreadCount)"; unreadWords = "\(mailbox.unreadCount) unread"
            }
        }

        let meeting = meetingLine(calendar, now: now)
        let detail = mailDetail ?? meeting?.detail
        let words = [unreadWords, mailWords, meeting?.words].compactMap { $0 }
        guard pill != nil || detail != nil else { return nil }
        return FocusBadge(pill: pill, detail: detail,
                          level: meeting?.attention == true ? .attention : .info,
                          accessibilityLabel: (["Fred"] + words).joined(separator: ", "))
    }

    private static func meetingLine(_ calendar: CalendarSnapshot?, now: Date) -> (detail: String, words: String, attention: Bool)? {
        guard let calendar else { return nil }
        if calendar.error != nil || calendar.stale {
            return ("Calendar unavailable", "calendar unavailable", false)
        }
        // Same rule as the Today pane: cancelled, declined and all-day events
        // are never "now" and never the next meeting.
        let live = calendar.events.filter { !["declined", "cancelled"].contains($0.status.lowercased()) && !$0.isAllDay }
        if let current = live.first(where: { e in
            guard let s = e.start, let end = e.end else { return false }
            return s <= now && now < end
        }) {
            return ("Now: \(current.title)", "meeting in progress \(current.title)", true)
        }
        let upcoming = live.compactMap { e in e.start.map { (e, $0) } }.filter { $0.1 > now }.min { $0.1 < $1.1 }
        guard let (event, start) = upcoming else {
            return ("No more meetings", "no more meetings", false)
        }
        let minutes = max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up)))
        let attention = start.timeIntervalSince(now) <= meetingAttentionWindow
        return ("Next: \(event.title) in \(shortDuration(minutes))",
                "next meeting \(event.title) in \(minutes) \(minutes == 1 ? "minute" : "minutes")", attention)
    }

    private static func shortDuration(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let (h, m) = (minutes / 60, minutes % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    // MARK: Mother

    static func mother(_ status: MotherStatus) -> FocusBadge? {
        let active = status.running + status.queued
        let parts: [(Int, String)] = [(status.running, "running"), (status.queued, "queued"),
                                      (status.awaiting, "awaiting"), (status.failed, "failed")]
        let shown = parts.filter { $0.0 > 0 }
        guard !shown.isEmpty else { return nil }
        return FocusBadge(
            pill: active > 0 ? "\(active)" : nil,
            detail: shown.map { "\($0.0) \($0.1)" }.joined(separator: " · "),
            level: status.awaiting > 0 || status.failed > 0 ? .attention : .info,
            accessibilityLabel: (["Mother"] + shown.map { "\($0.0) \($0.1)" }).joined(separator: ", "))
    }

    // MARK: Perri

    /// A stale, failed or still-loading queue never shows a count: the in-memory queue
    /// may be out of date. Stale/failed shows "!" (queue unavailable); loading shows nothing.
    static func perri(queueCount: Int, stale: Bool = false, error: String? = nil, loading: Bool = false) -> FocusBadge? {
        if error != nil || stale {
            return FocusBadge(pill: "!", accessibilityLabel: "Perri, queue unavailable")
        }
        guard !loading, queueCount > 0 else { return nil }
        return FocusBadge(pill: "\(queueCount)",
                          accessibilityLabel: "Perri, \(queueCount) \(queueCount == 1 ? "PR" : "PRs") waiting")
    }

    // MARK: Teri

    /// `calendar` decides what "today" is (the app passes America/Chicago).
    static func teri(todos: TeriTodosSnapshot?, now: Date, calendar: Calendar) -> FocusBadge? {
        guard let todos else { return nil }
        if todos.error != nil || todos.stale {
            return FocusBadge(detail: "Todos unavailable", accessibilityLabel: "Teri, todos unavailable")
        }
        let count = todos.items.count
        guard count > 0 else { return nil }

        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)
        let dues = todos.items.compactMap { $0.dueDate.map { String($0.prefix(10)) } }
        let overdue = dues.filter { $0 < today }.count
        let dueToday = dues.filter { $0 == today }.count

        var parts = ["\(count) \(count == 1 ? "todo" : "todos")"]
        if overdue > 0 { parts.append("\(overdue) overdue") }
        if dueToday > 0 { parts.append("\(dueToday) due today") }
        return FocusBadge(pill: "\(count)", detail: parts.joined(separator: " · "),
                          level: overdue > 0 ? .attention : .info,
                          accessibilityLabel: (["Teri"] + parts).joined(separator: ", "))
    }

    /// The calendar Teri's due dates are read in.
    static var chicago: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago") ?? .current
        return c
    }
}
