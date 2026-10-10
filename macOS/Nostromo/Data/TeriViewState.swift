import AppKit

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
    /// Width of the list pane as a fraction of the split view (nil: the default layout).
    var splitFraction: Double?
    private(set) var tabs: [TeriTab: TeriTabViewState] = [:]

    init() {}

    subscript(tab: TeriTab) -> TeriTabViewState {
        get { tabs[tab] ?? TeriTabViewState() }
        set { tabs[tab] = newValue }
    }

    enum CodingKeys: String, CodingKey { case selectedTab, tabs, splitFraction }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedTab = (try c.decodeIfPresent(String.self, forKey: .selectedTab)).flatMap(TeriTab.init(rawValue:))
        splitFraction = try c.decodeIfPresent(Double.self, forKey: .splitFraction)
        let raw = try c.decodeIfPresent([String: TeriTabViewState].self, forKey: .tabs) ?? [:]
        for (name, state) in raw {
            if let tab = TeriTab(rawValue: name) { tabs[tab] = state }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedTab?.rawValue, forKey: .selectedTab)
        try c.encodeIfPresent(splitFraction, forKey: .splitFraction)
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
///
/// A pending save is never lost: it is written when the store goes away and
/// when the app terminates. Several surfaces (Teri windows) each hold a store
/// over the same defaults, so a write merges per key — only what THIS store
/// changed (the selected tab, one tab's sub-state, the split position) replaces
/// what is on disk, and another window's changes to other keys survive.
final class TeriViewStateStore {
    private(set) var state: TeriViewState
    private let defaults: UserDefaults
    private let debounce: TimeInterval
    private let scheduler: WorkScheduler
    private let center: NotificationCenter
    private var cancelPendingSave: (() -> Void)?
    private var dirty = Set<Key>()
    private var terminateObserver: NSObjectProtocol?

    /// One independently persisted piece of the state.
    private enum Key: Hashable {
        case selectedTab
        case splitFraction
        case tab(TeriTab)
    }

    init(defaults: UserDefaults, debounce: TimeInterval = 0.5, scheduler: WorkScheduler = .main,
         center: NotificationCenter = .default) {
        self.defaults = defaults
        self.debounce = debounce
        self.scheduler = scheduler
        self.center = center
        self.state = TeriViewState.load(from: defaults)
        terminateObserver = center.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let terminateObserver { center.removeObserver(terminateObserver) }
        flush()
    }

    /// Apply `mutate` now; persist after the debounce.
    func update(_ mutate: (inout TeriViewState) -> Void) {
        let before = state
        mutate(&state)
        guard state != before else { return }
        if state.selectedTab != before.selectedTab { dirty.insert(.selectedTab) }
        if state.splitFraction != before.splitFraction { dirty.insert(.splitFraction) }
        for tab in TeriTab.allCases where state[tab] != before[tab] { dirty.insert(.tab(tab)) }
        cancelPendingSave?()
        cancelPendingSave = scheduler.schedule(debounce) { [weak self] in self?.flush() }
    }

    /// Persist right now (and cancel the pending save).
    func flush() {
        cancelPendingSave?()
        cancelPendingSave = nil
        guard !dirty.isEmpty else { return }
        var merged = TeriViewState.load(from: defaults)
        for key in dirty {
            switch key {
            case .selectedTab:   merged.selectedTab = state.selectedTab
            case .splitFraction: merged.splitFraction = state.splitFraction
            case .tab(let tab):  merged[tab] = state[tab]
            }
        }
        dirty.removeAll()
        merged.save(to: defaults)
    }
}
