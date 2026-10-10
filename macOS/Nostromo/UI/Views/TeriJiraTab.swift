import Foundation

/// The Jira tab: the user's unresolved assigned issues, grouped by status
/// category (In Progress, To Do, Other; the grouping and order come from
/// `WorkQuery`). A row reads `RM-12 Fix the webhook … updated 3 d ago  In Review`
/// with the priority name first. Project and status are multi-select filters.
enum TeriJiraTab {
    static let config = TeriTabConfig(
        tab: .jira,
        sourceName: "Jira",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: Date()) },
            groupTitle: { groupTitle(forKey: $0.key) },
            menuFacets: [.project, .status],
            searchPlaceholder: "Filter Jira issues"),
        emptyMessage: "No Jira issues assigned to you.")

    /// What one issue row shows, relative to `now`.
    static func rowContent(for item: WorkItem, now: Date) -> WorkRowContent {
        let key = issueKey(of: item)
        let title = key.isEmpty ? item.title : "\(key) \(item.title)"
        let updated = item.updatedAt.map { updatedText(since: $0, now: now) }
        var parts = ["Jira \(item.kind)", title]
        if let priority = item.priority { parts.append("priority \(priority.label)") }
        if let status = item.status { parts.append(status) }
        if let updated { parts.append(updated) }
        return WorkRowContent(
            priorityText: item.priority?.label,
            priorityRank: item.priority?.rank,
            title: title,
            dueText: updated,
            statusText: item.status,
            accessibilityLabel: parts.joined(separator: ", "))
    }

    /// "updated just now", "updated 5 min ago", "updated 3 h ago", "updated 3 d ago".
    static func updatedText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60:      return "updated just now"
        case ..<3_600:   return "updated \(seconds / 60) min ago"
        case ..<86_400:  return "updated \(seconds / 3_600) h ago"
        default:         return "updated \(seconds / 86_400) d ago"
        }
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
