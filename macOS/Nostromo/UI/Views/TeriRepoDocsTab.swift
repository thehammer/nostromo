import Foundation

/// The Repo docs tab: every open bug, feature, idea, todo and wip folder filed
/// under the repos' `.claude/` directories, grouped by repo.
///
/// A group header reads `referral-monitor  144 · 74 bugs · 33 todos · …` (counts
/// under the current filters); a row reads `✖ Bug  Title … 3 days ago  Severity: high`.
enum TeriRepoDocsTab {
    static let config = TeriTabConfig(
        tab: .repoDocs,
        sourceName: "Repo docs",
        list: WorkListConfig(
            rowContent: { rowContent(for: $0, now: Date(), calendar: .current) },
            groupTitle: { groupTitle(repo: $0.key ?? "", items: $0.items) },
            chipFacet: .kind,
            chipTitle: { kinds[$0]?.chip ?? $0 },
            chipValues: kindOrder,
            hasSeverityToggle: true,
            menuFacets: [.repo],
            menuAllItemFacets: [.repo],
            sortOptions: [("Newest", .newest), ("Oldest", .oldest), ("Title", .title)],
            searchPlaceholder: "Filter docs"),
        emptyMessage: "No open bugs, features, ideas or todos in your repos.")

    // MARK: - Pieces

    /// What one doc row shows, relative to `now`.
    static func rowContent(for item: WorkItem, now: Date, calendar: Calendar) -> WorkRowContent {
        let kindWord = kinds[item.kind]?.word ?? item.kind.capitalized
        let filed = filedText(item.createdAt, now: now, calendar: calendar)
        return WorkRowContent(
            priorityText: item.priority?.label,
            priorityRank: item.priority?.rank,
            kindText: "\(kinds[item.kind]?.glyph ?? "•") \(kindWord)",
            title: item.title,
            dueText: filed,
            statusText: item.severity.map { "Severity: \(clipped($0))" },
            accessibilityLabel: accessibilityLabel(for: item, kindWord: kindWord, filed: filed))
    }

    /// `referral-monitor  144 · 74 bugs · 33 todos · 22 wip · 11 features · 4 ideas`:
    /// the count of each type that has any, largest first (ties in the order
    /// bug, feature, idea, todo, wip).
    static func groupTitle(repo: String, items: [WorkItem]) -> String {
        var counts: [String: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        let parts = kindOrder
            .compactMap { kind -> (kind: String, count: Int)? in counts[kind].map { (kind, $0) } }
            .enumerated()
            .sorted { a, b in a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset }
            .map { entry -> String in
                let kind = kinds[entry.element.kind]
                let word = entry.element.count == 1 ? kind?.singular : kind?.plural
                return "\(entry.element.count) \(word ?? entry.element.kind)"
            }
        return ([ "\(repo)  \(items.count)" ] + parts).joined(separator: " · ")
    }

    /// "today", "yesterday", "3 days ago", "2 weeks ago", "5 months ago", "2 years ago".
    static func filedText(_ created: Date?, now: Date, calendar: Calendar) -> String? {
        guard let created else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: created),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1:     return "today"
        case 1:        return "yesterday"
        case 2...13:   return "\(days) days ago"
        case 14...59:  return "\(days / 7) weeks ago"
        case 60...729: return "\(days / 30) months ago"
        default:       return "\(days / 365) years ago"
        }
    }

    // MARK: - Private

    private struct Kind {
        let glyph: String
        let word: String
        let singular: String
        let plural: String
        /// The label of its filter chip.
        let chip: String
    }

    private static let kindOrder = ["bug", "feature", "idea", "todo", "wip"]

    private static let kinds: [String: Kind] = [
        "bug":     Kind(glyph: "✖", word: "Bug",     singular: "bug",     plural: "bugs", chip: "Bugs"),
        "feature": Kind(glyph: "✚", word: "Feature", singular: "feature", plural: "features", chip: "Features"),
        "idea":    Kind(glyph: "✦", word: "Idea",    singular: "idea",    plural: "ideas", chip: "Ideas"),
        "todo":    Kind(glyph: "☐", word: "Todo",    singular: "todo",    plural: "todos", chip: "Todos"),
        "wip":     Kind(glyph: "◐", word: "WIP",     singular: "wip",     plural: "wip", chip: "WIP"),
    ]

    /// Row text for a severity: long free-form ones are cut.
    private static func clipped(_ severity: String) -> String {
        severity.count > 24 ? String(severity.prefix(24)) + "…" : severity
    }

    private static func accessibilityLabel(for item: WorkItem, kindWord: String, filed: String?) -> String {
        var parts = [kindWord, item.repo ?? "", item.title].filter { !$0.isEmpty }
        if let severity = item.severity { parts.append("severity \(severity)") }
        if let priority = item.priority { parts.append("priority \(priority.label)") }
        if let filed { parts.append("filed \(filed)") }
        return parts.joined(separator: ", ")
    }
}
