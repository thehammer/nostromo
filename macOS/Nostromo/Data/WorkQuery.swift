import Foundation

// Filter / search / sort / group for work items (design contract §5).
//
// One definition, two engines: `src/data/work/query.rs` does the same for the
// MCP tools. Both are tested against `tests/fixtures/work_query_cases.json`, so
// a change here needs the same change there. Pure functions over value types;
// nothing here touches the main thread or the store.

/// Filters. Values within one list are ORed; different filters are ANDed. An
/// empty list means "no constraint".
struct WorkFilter: Equatable, Codable {
    var sources: [WorkSource] = []
    var kinds: [String] = []
    var repos: [String] = []
    var projects: [String] = []
    var statuses: [String] = []
    var environments: [String] = []
    /// `true`: only items that state a severity; `false`: only those that do not.
    var hasSeverity: Bool?
    /// Whitespace-separated terms; every term must match the title or body text.
    var query: String = ""

    enum CodingKeys: String, CodingKey {
        case sources, kinds, repos, projects, statuses, environments, query
        case hasSeverity = "has_severity"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources      = try c.decodeIfPresent([WorkSource].self, forKey: .sources) ?? []
        kinds        = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        repos        = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        projects     = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
        statuses     = try c.decodeIfPresent([String].self, forKey: .statuses) ?? []
        environments = try c.decodeIfPresent([String].self, forKey: .environments) ?? []
        hasSeverity  = try c.decodeIfPresent(Bool.self, forKey: .hasSeverity)
        query        = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
    }

    /// True when no filter and no search text is set.
    var isEmpty: Bool { self == WorkFilter() }
}

/// Within-group order for repo docs.
enum WorkSortKey: String, Codable {
    /// `created_at` newest first; undated last.
    case newest
    /// `created_at` oldest first; undated last.
    case oldest
    case title
}

/// A facet whose values are counted for filter chips.
enum WorkFacet: String, Codable {
    case source, kind, repo, project, status, environment
}

/// One group of the grouped list. `key` is nil for sources that are one flat list.
struct WorkGroup: Equatable {
    let key: String?
    let items: [WorkItem]
}

enum WorkQuery {

    /// Items matching `filter`, in input order.
    static func filter(_ items: [WorkItem], _ filter: WorkFilter) -> [WorkItem] {
        let terms = searchTerms(filter.query)
        return items.filter { matches($0, filter, terms) }
    }

    /// Sort and group already-filtered `items` of `source` for display.
    static func group(_ items: [WorkItem], source: WorkSource, sort: WorkSortKey = .newest) -> [WorkGroup] {
        if items.isEmpty { return [] }
        switch source {
        case .todos:
            return [WorkGroup(key: nil, items: sorted(items, by: compareTodos))]
        case .sentry:
            return [WorkGroup(key: nil, items: sorted(items) { dateDescending($0.updatedAt, $1.updatedAt) })]
        case .jira:
            return groupJira(items)
        case .repoDocs:
            return groupRepoDocs(items, sort: sort)
        }
    }

    /// Value → count of `facet` over the items that match every filter except
    /// the one on `facet` itself (the standard faceted-search behaviour). Items
    /// with no value for the facet are not counted.
    static func facetCounts(_ items: [WorkItem], filter: WorkFilter, facet: WorkFacet) -> [String: Int] {
        var relaxed = filter
        switch facet {
        case .source:      relaxed.sources = []
        case .kind:        relaxed.kinds = []
        case .repo:        relaxed.repos = []
        case .project:     relaxed.projects = []
        case .status:      relaxed.statuses = []
        case .environment: relaxed.environments = []
        }
        let terms = searchTerms(relaxed.query)
        var counts: [String: Int] = [:]
        for item in items where matches(item, relaxed, terms) {
            let value: String?
            switch facet {
            case .source:      value = item.source.rawValue
            case .kind:        value = item.kind
            case .repo:        value = item.repo
            case .project:     value = item.project
            case .status:      value = item.status
            case .environment: value = item.environment
            }
            if let value { counts[value, default: 0] += 1 }
        }
        return counts
    }

    // MARK: - Search text

    /// Case- and diacritic-insensitive form of `s`.
    static func fold(_ s: String) -> String {
        if s.utf8.allSatisfy({ $0 < 0x80 }) { return s.lowercased() }
        return s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The text a search term is matched against (see `WorkItem.searchIndex`).
    static func searchIndex(title: String, searchText: String) -> String {
        fold(title) + "\n" + fold(searchText)
    }

    private static func searchTerms(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: { $0.isWhitespace }).map { Array(fold(String($0)).utf8) }
    }

    private static func matchesTerms(_ item: WorkItem, _ terms: [[UInt8]]) -> Bool {
        if terms.isEmpty { return true }
        var haystack = item.searchIndex
        return haystack.withUTF8 { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return terms.allSatisfy { term in
                term.withUnsafeBufferPointer { needle in
                    guard let n = needle.baseAddress else { return true }
                    return memmem(base, buf.count, n, needle.count) != nil
                }
            }
        }
    }

    // MARK: - Field filters

    private static func matches(_ item: WorkItem, _ f: WorkFilter, _ terms: [[UInt8]]) -> Bool {
        matchesFields(item, f) && matchesTerms(item, terms)
    }

    private static func matchesFields(_ item: WorkItem, _ f: WorkFilter) -> Bool {
        func oneOf(_ wanted: [String], _ have: String?) -> Bool {
            wanted.isEmpty || (have.map(wanted.contains) ?? false)
        }
        return (f.sources.isEmpty || f.sources.contains(item.source))
            && (f.kinds.isEmpty || f.kinds.contains(item.kind))
            && oneOf(f.repos, item.repo)
            && oneOf(f.projects, item.project)
            && oneOf(f.statuses, item.status)
            && oneOf(f.environments, item.environment)
            && (f.hasSeverity.map { ($0) == (item.severity != nil) } ?? true)
    }

    // MARK: - Ordering

    /// Stable sort: ties keep input order.
    private static func sorted(_ items: [WorkItem], by compare: (WorkItem, WorkItem) -> Int) -> [WorkItem] {
        items.enumerated()
            .sorted { a, b in
                let c = compare(a.element, b.element)
                return c != 0 ? c < 0 : a.offset < b.offset
            }
            .map(\.element)
    }

    private static func compareRank(_ a: WorkItem, _ b: WorkItem) -> Int {
        compare(a.priority?.rank ?? Int.max, b.priority?.rank ?? Int.max)
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> Int {
        a < b ? -1 : (a > b ? 1 : 0)
    }

    /// Ascending, nil last.
    private static func ascendingNilLast<T: Comparable>(_ a: T?, _ b: T?) -> Int {
        comparePresent(a, b) { compare($0, $1) }
    }

    /// Newest first, nil last.
    private static func dateDescending(_ a: Date?, _ b: Date?) -> Int {
        comparePresent(a, b) { compare($1, $0) }
    }

    /// Compare present values with `order`; a missing value sorts after a present one.
    private static func comparePresent<T>(_ a: T?, _ b: T?, _ order: (T, T) -> Int) -> Int {
        switch (a, b) {
        case let (a?, b?): return order(a, b)
        case (_?, nil):    return -1
        case (nil, _?):    return 1
        case (nil, nil):   return 0
        }
    }

    private static func compareTitle(_ a: WorkItem, _ b: WorkItem) -> Int {
        compare(fold(a.title), fold(b.title))
    }

    private static func compareTodos(_ a: WorkItem, _ b: WorkItem) -> Int {
        let rank = compareRank(a, b)
        if rank != 0 { return rank }
        let due = ascendingNilLast(a.due, b.due)
        if due != 0 { return due }
        return compareTitle(a, b)
    }

    private static func groupJira(_ items: [WorkItem]) -> [WorkGroup] {
        func category(_ i: WorkItem) -> String {
            switch i.statusCategory {
            case "in_progress", "to_do": return i.statusCategory!
            default: return "other"
            }
        }
        return ["in_progress", "to_do", "other"].compactMap { key in
            let members = items.filter { category($0) == key }
            if members.isEmpty { return nil }
            let ordered = sorted(members) { a, b in
                let rank = compareRank(a, b)
                return rank != 0 ? rank : dateDescending(a.updatedAt, b.updatedAt)
            }
            return WorkGroup(key: key, items: ordered)
        }
    }

    private static func groupRepoDocs(_ items: [WorkItem], sort: WorkSortKey) -> [WorkGroup] {
        let byRepo = Dictionary(grouping: items) { $0.repo ?? "" }
        let compare: (WorkItem, WorkItem) -> Int
        switch sort {
        case .newest: compare = { dateDescending($0.createdAt, $1.createdAt) }
        case .oldest: compare = { ascendingNilLast($0.createdAt, $1.createdAt) }
        case .title:  compare = compareTitle
        }
        return byRepo
            .map { WorkGroup(key: $0.key, items: sorted($0.value, by: compare)) }
            .sorted { a, b in
                a.items.count != b.items.count ? a.items.count > b.items.count : (a.key ?? "") < (b.key ?? "")
            }
    }
}
