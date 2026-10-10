import Foundation

/// The tabs of the Teri surface, in display order. The raw value is the id used
/// by deep links and in the persisted view state.
enum TeriTab: String, Codable, CaseIterable {
    case picks
    case todos
    case jira
    case sentry
    case repoDocs = "repo_docs"

    var title: String {
        switch self {
        case .picks:    return "Picks"
        case .todos:    return "Todos"
        case .jira:     return "Jira"
        case .sentry:   return "Sentry"
        case .repoDocs: return "Repo docs"
        }
    }

    /// The work source behind the tab (nil for Picks, which are Teri's own).
    var source: WorkSource? {
        switch self {
        case .picks:    return nil
        case .todos:    return .todos
        case .jira:     return .jira
        case .sentry:   return .sentry
        case .repoDocs: return .repoDocs
        }
    }
}

/// What one tab remembers between visits and relaunches.
struct TeriTabViewState: Codable, Equatable {
    var filter = WorkFilter()
    var sort: WorkSortKey = .newest
    var collapsedGroups: [String] = []
    var selectedItemId: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filter          = try c.decodeIfPresent(WorkFilter.self, forKey: .filter) ?? WorkFilter()
        sort            = try c.decodeIfPresent(WorkSortKey.self, forKey: .sort) ?? .newest
        collapsedGroups = try c.decodeIfPresent([String].self, forKey: .collapsedGroups) ?? []
        selectedItemId  = try c.decodeIfPresent(String.self, forKey: .selectedItemId)
    }
}

/// Persisted state of the Teri surface (UserDefaults key `nostromo.teri.viewState.v1`).
/// Tabs are stored by name, so a tab this version does not know is skipped on
/// load rather than failing the whole state.
struct TeriViewState: Codable, Equatable {
    static let defaultsKey = "nostromo.teri.viewState.v1"

    var selectedTab: TeriTab?
    private(set) var tabs: [TeriTab: TeriTabViewState] = [:]

    init() {}

    subscript(tab: TeriTab) -> TeriTabViewState {
        get { tabs[tab] ?? TeriTabViewState() }
        set { tabs[tab] = newValue }
    }

    enum CodingKeys: String, CodingKey { case selectedTab, tabs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedTab = (try c.decodeIfPresent(String.self, forKey: .selectedTab)).flatMap(TeriTab.init(rawValue:))
        let raw = try c.decodeIfPresent([String: TeriTabViewState].self, forKey: .tabs) ?? [:]
        for (name, state) in raw {
            if let tab = TeriTab(rawValue: name) { tabs[tab] = state }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedTab?.rawValue, forKey: .selectedTab)
        try c.encode(Dictionary(uniqueKeysWithValues: tabs.map { ($0.key.rawValue, $0.value) }), forKey: .tabs)
    }

    /// The stored state, or an empty one when nothing (valid) is stored.
    static func load(from defaults: UserDefaults) -> TeriViewState {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(TeriViewState.self, from: data)
        else { return TeriViewState() }
        return state
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Holds the live `TeriViewState` and writes it to UserDefaults a short while
/// after the last change, so typing in the search field is not a disk write per
/// keystroke. Main thread only.
final class TeriViewStateStore {
    private(set) var state: TeriViewState
    private let defaults: UserDefaults
    private let debounce: TimeInterval
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults, debounce: TimeInterval = 0.5) {
        self.defaults = defaults
        self.debounce = debounce
        self.state = TeriViewState.load(from: defaults)
    }

    /// Apply `mutate` now; persist after the debounce.
    func update(_ mutate: (inout TeriViewState) -> Void) {
        let before = state
        mutate(&state)
        guard state != before else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    /// Persist right now (and cancel the pending save).
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        state.save(to: defaults)
    }
}
