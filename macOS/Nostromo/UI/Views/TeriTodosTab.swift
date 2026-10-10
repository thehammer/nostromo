import Foundation

/// The Todos tab: Teri's own todo list. Rows are `P1 Title … Overdue by 2 days  Blocked`.
enum TeriTodosTab {
    static let config = TeriTabConfig(
        tab: .todos,
        sourceName: "Todos",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: Date(), calendar: .current) },
            chipFacet: .status,
            searchPlaceholder: "Filter todos"),
        emptyMessage: "Nothing to do. Add a todo by asking Teri.")

    /// What one todo row shows, relative to `now`.
    static func rowContent(for item: WorkItem, now: Date, calendar: Calendar) -> WorkRowContent {
        let due = dueText(for: item.due, now: now, calendar: calendar)
        let status = statusText(for: item.status)
        return WorkRowContent(
            priorityText: item.priority?.label,
            priorityRank: item.priority?.rank,
            title: item.title,
            dueText: due?.text,
            dueIsUrgent: due?.isUrgent ?? false,
            statusText: status,
            accessibilityLabel: accessibilityLabel(for: item, due: due?.text, status: status, now: now, calendar: calendar))
    }

    // MARK: - Pieces

    /// "Overdue by 2 days", "Due today", "Due Fri" (within a week), "Due Oct 29".
    static func dueText(for due: String?, now: Date, calendar: Calendar) -> (text: String, isUrgent: Bool)? {
        guard let due, let dueDay = day(from: due, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        switch days {
        case ..<0:
            return ("Overdue by \(-days) day\(days == -1 ? "" : "s")", true)
        case 0:
            return ("Due today", true)
        case 1...6:
            return ("Due \(format(dueDay, "EEE", calendar: calendar))", false)
        default:
            return ("Due \(format(dueDay, "MMM d", calendar: calendar))", false)
        }
    }

    private static func statusText(for status: String?) -> String? {
        switch status {
        case "blocked":     return "Blocked"
        case "in_progress": return "In progress"
        default:            return nil
        }
    }

    private static func accessibilityLabel(for item: WorkItem, due: String?, status: String?,
                                           now: Date, calendar: Calendar) -> String {
        var parts = ["Todo", item.title]
        if let priority = item.priority {
            parts.append("priority \(priority.rank), \(priority.label)")
        }
        if let due { parts.append(due.lowercased()) }
        if let status { parts.append(status.lowercased()) }
        if let created = item.createdAt ?? item.updatedAt {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: created),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            parts.append(days <= 0 ? "added today" : "\(days) day\(days == 1 ? "" : "s") old")
        }
        return parts.joined(separator: ", ")
    }

    private static func day(from iso: String, calendar: Calendar) -> Date? {
        let parts = iso.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
