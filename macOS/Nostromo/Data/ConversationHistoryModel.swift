import Foundation

/// The Resume tab's rows: grouping by local day, search, and the words each row shows. Pure: the clock,
/// calendar and entries are injected, so tests need no daemon and no UI.
struct ConversationHistoryModel {
    enum GroupKind: Int { case today, yesterday, earlierThisWeek, earlier, unavailable }

    struct Group: Equatable {
        let kind: GroupKind
        let title: String
        /// For `unavailable`, the count in the title ("Unavailable (N)").
        let rows: [ConversationEntryWire]
    }

    /// What one row says, as plain strings; the view only lays these out.
    struct RowText: Equatable {
        var title: String
        var detail: String          // agent · project · branch · model · last active
        var prs: String?            // "PR #1 · PR #2"
        var firstPrompt: String?    // quoted, or a fixed word
        var status: String?         // in words
        var accessibilityLabel: String
    }

    var entries: [ConversationEntryWire] = []
    var query: String = ""
    var now: () -> Date = Date.init
    var calendar: Calendar = .current
    /// Rows hidden by Remove, until the sheet closes (the daemon holds them soft-removed for undo).
    private(set) var hidden: Set<String> = []

    init(entries: [ConversationEntryWire] = [], query: String = "", now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current) {
        self.entries = entries
        self.query = query
        self.now = now
        self.calendar = calendar
    }

    mutating func hide(_ id: String) { hidden.insert(id) }
    mutating func unhide(_ id: String) { hidden.remove(id) }

    static func isUnavailable(_ status: ConversationStatusWire) -> Bool {
        switch status {
        case .unavailableDeleted, .unavailableUnreadable, .unknown: return true
        default: return false
        }
    }

    // MARK: Grouping

    /// Today / Yesterday / Earlier this week / Earlier, newest first, then the Unavailable group.
    var groups: [Group] {
        let words = Self.words(query)
        let visible = entries.filter { !hidden.contains($0.id) && Self.matches($0, words: words) }
            .sorted { $0.lastActiveMs > $1.lastActiveMs }
        var buckets: [GroupKind: [ConversationEntryWire]] = [:]
        for e in visible {
            let kind = Self.isUnavailable(e.status) ? GroupKind.unavailable : dayKind(of: e.lastActive)
            buckets[kind, default: []].append(e)
        }
        let titles: [(GroupKind, String)] = [(.today, "Today"), (.yesterday, "Yesterday"),
                                             (.earlierThisWeek, "Earlier this week"), (.earlier, "Earlier")]
        var out = titles.compactMap { kind, title in
            buckets[kind].map { Group(kind: kind, title: title, rows: $0) }
        }
        if let rows = buckets[.unavailable] {
            out.append(Group(kind: .unavailable, title: "Unavailable (\(rows.count))", rows: rows))
        }
        return out
    }

    /// Every row in display order (the order ↑/↓ walks).
    var flatRows: [ConversationEntryWire] { groups.flatMap { $0.rows } }

    private func dayKind(of date: Date) -> GroupKind {
        let today = now()
        if calendar.isDate(date, inSameDayAs: today) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(date, inSameDayAs: y) {
            return .yesterday
        }
        if date < today, calendar.isDate(date, equalTo: today, toGranularity: .weekOfYear) { return .earlierThisWeek }
        return .earlier
    }

    // MARK: Search

    static func words(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
    }

    /// Every word must occur, case-insensitively, in the title, agent, project, branch, a PR number or the
    /// first prompt. Nothing else is searched.
    static func matches(_ e: ConversationEntryWire, words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        var fields = [e.title, e.agent]
        if let p = e.projectName { fields.append(p) }
        if let b = e.branch { fields.append(b) }
        if let f = e.firstPrompt { fields.append(f) }
        fields.append(contentsOf: e.prNumbers.flatMap { ["\($0)", "#\($0)", "PR #\($0)"] })
        let hay = fields.map { $0.lowercased() }
        return words.allSatisfy { w in hay.contains { $0.contains(w) } }
    }

    // MARK: Words on a row

    func text(for e: ConversationEntryWire) -> RowText {
        let when = lastActiveText(e.lastActive)
        if e.sensitive {
            return RowText(title: e.title, detail: [e.agent, when].joined(separator: " · "), prs: nil,
                           firstPrompt: nil, status: "Sensitive",
                           accessibilityLabel: "\(e.title), \(e.agent), \(when), Sensitive")
        }
        var parts = [e.agent]
        if let p = e.projectName, !p.isEmpty { parts.append(p) }
        if let b = e.branch, !b.isEmpty { parts.append(b) }
        if let m = e.model, !m.isEmpty { parts.append(ModelPresentation.familyName(forModel: m)) }
        parts.append(when)
        let status = Self.statusText(e.status)
        let project = e.projectName ?? ""
        let label = ([e.title, e.agent] + (project.isEmpty ? [] : [project]) + [when] + (status.map { [$0] } ?? []))
            .joined(separator: ", ")
        return RowText(
            title: e.title,
            detail: parts.joined(separator: " · "),
            prs: e.prNumbers.isEmpty ? nil : e.prNumbers.map { "PR #\($0)" }.joined(separator: " · "),
            firstPrompt: Self.promptText(e),
            status: status,
            accessibilityLabel: label)
    }

    static func statusText(_ s: ConversationStatusWire) -> String? {
        switch s {
        case .running: return "running · switch to"
        case .unavailableDeleted: return "unavailable: Claude no longer has this conversation"
        case .unavailableUnreadable: return "unavailable: Can't read this conversation"
        case .folderGone(let worktree, _): return worktree ? "worktree gone" : "project gone"
        case .activeElsewhere: return "active elsewhere?"
        case .available: return nil
        case .unknown: return "unavailable: this version of Nostromo can't open it"
        }
    }

    /// The first prompt in quotes, or a fixed word for a withheld one; nothing for the rest.
    static func promptText(_ e: ConversationEntryWire) -> String? {
        if let p = e.firstPrompt, !p.isEmpty { return "\u{201C}\(p)\u{201D}" }
        guard let why = e.firstPromptWithheld else { return nil }
        if why == "image" { return "(image)" }
        if why.hasPrefix("command:") { return String(why.dropFirst("command:".count)) }
        return nil
    }

    /// Relative today (time of day), a date beyond.
    func lastActiveText(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        if calendar.isDate(date, inSameDayAs: now()) {
            f.dateStyle = .none; f.timeStyle = .short
        } else {
            f.dateStyle = .medium; f.timeStyle = .none
        }
        return f.string(from: date)
    }
}
