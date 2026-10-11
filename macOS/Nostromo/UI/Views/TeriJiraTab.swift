import Foundation

/// The Jira tab: the user's unresolved assigned issues, grouped by status
/// category (In Progress, To Do, Other; the grouping and order come from
/// `WorkQuery`). A row reads `RM-12 Fix the webhook … Due Fri  In Review · updated 3 d ago`
/// with the priority name first. Project and status are multi-select filters.
///
/// Row text never depends on the minute: `WorkListView` caches a row's content
/// for the calendar day and nothing redraws it on a timer, so "updated 3 min ago"
/// would be wrong within minutes. "updated today 14:05", "yesterday" and
/// "N d ago" stay true for exactly as long as the cache lives.
enum TeriJiraTab {
    static let config = TeriTabConfig(
        tab: .jira,
        sourceName: "Jira",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: Date(), calendar: .current) },
            groupTitle: { groupTitle(forKey: $0.key) },
            menuFacets: [.project, .status],
            searchPlaceholder: "Filter Jira issues"),
        emptyMessage: "No Jira issues assigned to you.")

    /// What one issue row shows, relative to `now`: the due date in its own slot
    /// (urgent when overdue or due today), status and last update after it.
    static func rowContent(for item: WorkItem, now: Date, calendar: Calendar = .current) -> WorkRowContent {
        let key = issueKey(of: item)
        let title = key.isEmpty ? item.title : "\(key) \(item.title)"
        let due = TeriTodosTab.dueText(for: item.due, now: now, calendar: calendar)
        let updated = item.updatedAt.map { updatedText(since: $0, now: now, calendar: calendar) }
        let statusAndUpdate = [item.status, updated].compactMap { $0 }.joined(separator: " · ")
        var parts = ["Jira \(item.kind)", title]
        if let priority = item.priority { parts.append("priority \(priority.label)") }
        if let due { parts.append(due.text.lowercased()) }
        if let status = item.status { parts.append(status) }
        if let updated { parts.append(updated) }
        return WorkRowContent(
            priorityText: item.priority?.label,
            priorityRank: item.priority?.rank,
            title: title,
            dueText: due?.text,
            dueIsUrgent: due?.isUrgent ?? false,
            statusText: statusAndUpdate.isEmpty ? nil : statusAndUpdate,
            accessibilityLabel: parts.joined(separator: ", "))
    }

    /// "updated today 14:05", "updated yesterday", "updated 3 d ago": by calendar day.
    static func updatedText(since date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1:  return "updated today \(clock(date, calendar: calendar))"   // also clock skew into the future
        case 1:     return "updated yesterday"
        default:    return "updated \(days) d ago"
        }
    }

    /// 24-hour clock through the shared formatter cache (a list draws hundreds of rows).
    private static func clock(_ date: Date, calendar: Calendar) -> String {
        TeriDateFormatters.string(from: date, pattern: "HH:mm", calendar: calendar)
    }

    static func groupTitle(forKey key: String?) -> String {
        switch key {
        case "in_progress": return "In Progress"
        case "to_do":       return "To Do"
        default:            return "Other"
        }
    }

    /// `jira:RM-12` is `RM-12`.
    private static func issueKey(of item: WorkItem) -> String {
        item.id.hasPrefix("jira:") ? String(item.id.dropFirst("jira:".count)) : ""
    }
}
