import Foundation
import Combine

/// A pull request a side-pane tab belongs to. Ordered by repo then number.
struct ReviewPR: Hashable, Comparable {
    let repo: String
    let number: Int

    static func < (a: ReviewPR, b: ReviewPR) -> Bool {
        a.repo == b.repo ? a.number < b.number : a.repo < b.repo
    }

    /// `owner/name` made of the characters GitHub allows; anything else cannot be a PR we open.
    private var hasValidRepo: Bool {
        repo.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    /// nil for a malformed repo string (no control is offered for it).
    var conversationURL: URL? { hasValidRepo ? URL(string: "https://github.com/\(repo)/pull/\(number)") : nil }
    var diffURL: URL? { hasValidRepo ? URL(string: "https://github.com/\(repo)/pull/\(number)/files") : nil }
}

/// What a tab shows. One tab per (PR, target) except `page` tabs, which a link or popup opened.
enum ReviewTarget: Hashable {
    case conversation
    case diff
    case ticket(String)
    /// A tab opened by a link or window.open; the Int is its open order.
    case page(Int)

    /// Sort rank within a PR: conversation, diff, tickets, pages.
    fileprivate var rank: Int {
        switch self {
        case .conversation: return 0
        case .diff: return 1
        case .ticket: return 2
        case .page: return 3
        }
    }
}

/// One side-pane tab. The web view is created lazily, the first time the tab is shown.
final class ReviewTab: ObservableObject, Identifiable {
    let id = UUID()
    let pr: ReviewPR
    let target: ReviewTarget
    let startURL: URL
    @Published var currentURL: URL
    @Published var title: String
    /// Set when the person typed text that is still unsent and the tab was kept past a PR change.
    @Published var unsent = false
    var lastFocused: Date
    /// Order a ticket appeared in when it was opened (kept for ordering tickets as given).
    var ticketOrder = 0
    /// The tab's web view and overlays; nil until first shown, and for a restored tab.
    var controller: ReviewTabController?

    init(pr: ReviewPR, target: ReviewTarget, startURL: URL, currentURL: URL? = nil, title: String? = nil,
         lastFocused: Date = Date()) {
        self.pr = pr
        self.target = target
        self.startURL = startURL
        self.currentURL = currentURL ?? startURL
        self.title = title ?? ReviewTab.defaultTitle(pr: pr, target: target)
        self.lastFocused = lastFocused
    }

    static func defaultTitle(pr: ReviewPR, target: ReviewTarget) -> String {
        switch target {
        case .conversation: return "#\(pr.number) Conversation"
        case .diff: return "#\(pr.number) Diff"
        case .ticket(let key): return key
        case .page: return "#\(pr.number)"
        }
    }

    /// `#4520 Diff` or a page tab's title.
    var label: String { title }

    /// Full description for tooltips and accessibility: PR and repo, plus the unsent mark.
    var fullDescription: String {
        "\(title), pull request \(pr.number) in \(pr.repo)" + (unsent ? ", unsent text" : "")
    }

    /// Whether the tab is a restored placeholder or never shown (no web view yet).
    var hasWebView: Bool { controller != nil }
}

/// The side pane's state for one Perri focus: tabs, the active tab, and the width. Shared by every
/// window showing the focus. It does not observe the queue, only the focus's pin.
final class ReviewPaneModel: ObservableObject {

    static let tabCap = 8
    static let defaultWidthFraction = 0.5

    let tag: String
    @Published private(set) var tabs: [ReviewTab] = []
    @Published private(set) var activeID: ReviewTab.ID?
    @Published var widthFraction: Double {
        didSet { persist() }
    }
    /// The PR the focus is reviewing now (its pin); nil when none.
    @Published private(set) var currentPin: ReviewPR?

    /// Whether the person typed unsent text in a tab. Defaults to asking the tab's web view; tests inject.
    var unsentCheck: (ReviewTab) async -> Bool = { tab in
        guard let controller = tab.controller else { return false }
        return await controller.hasUnsentInput()
    }

    /// Tabs build their web views through this (tests replace it).
    var environment = ReviewPaneEnvironment()
    /// Fires when the person (or a control) asked for a tab: the pane takes keyboard focus.
    let focusRequests = PassthroughSubject<Void, Never>()
    /// Which window's side pane view owns the web views right now (the most recently shown).
    @Published private(set) var presenterID: ObjectIdentifier?

    private let store: ReviewPaneStore?
    private var presenterOrder: [ObjectIdentifier] = []
    private var lastNonNilPin: ReviewPR?
    private var pageCounter = 0
    private var pinCancellable: AnyCancellable?

    init(tag: String, store: ReviewPaneStore? = nil) {
        self.tag = tag
        self.store = store
        let saved = store?.load(tag: tag)
        widthFraction = saved?.widthFraction ?? Self.defaultWidthFraction
        if let saved {
            for t in saved.tabs {
                let tab = ReviewTab(pr: ReviewPR(repo: t.repo, number: t.number), target: t.target,
                                    startURL: t.startURL, currentURL: t.lastURL, title: t.title)
                if case .page(let n) = t.target { pageCounter = max(pageCounter, n + 1) }
                tabs.append(tab)
            }
            sortTabs()
            if let i = saved.activeIndex, tabs.indices.contains(i) { activeID = tabs[i].id }
            else { activeID = tabs.first?.id }
        }
    }

    var activeTab: ReviewTab? { tabs.first { $0.id == activeID } }
    var isVisible: Bool { !tabs.isEmpty }

    // MARK: Opening and closing

    /// Opens (or focuses) the tab for (PR, target). An existing tab is focused as it is: no navigation.
    @discardableResult
    func open(pr: ReviewPR, target: ReviewTarget, url: URL? = nil, ticketOrder: Int = 0) -> ReviewTab {
        if let existing = tabs.first(where: { $0.pr == pr && $0.target == target }) {
            focus(existing)
            return existing
        }
        let start = url ?? Self.defaultURL(pr: pr, target: target)
        let tab = ReviewTab(pr: pr, target: target, startURL: start)
        tab.ticketOrder = ticketOrder
        insert(tab)
        focusRequests.send()
        Task { @MainActor in await self.enforceCap() }
        return tab
    }

    /// A tab for a page a link or popup opened inside `opener`'s PR. Always a new tab.
    @discardableResult
    func openPage(from opener: ReviewTab, url: URL, prepare: ((ReviewTab) -> Void)? = nil) -> ReviewTab {
        pageCounter += 1
        let tab = ReviewTab(pr: opener.pr, target: .page(pageCounter), startURL: url)
        prepare?(tab)   // a popup's controller must exist before the pane first sees the tab
        insert(tab)
        Task { @MainActor in await self.enforceCap() }
        return tab
    }

    func focus(_ tab: ReviewTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        tab.lastFocused = Date()
        if activeID != tab.id { activeID = tab.id }
        persist()
        focusRequests.send()
    }

    /// The most recently shown window's pane takes the web views.
    func claimPresenter(_ id: ObjectIdentifier) {
        presenterOrder.removeAll { $0 == id }
        presenterOrder.append(id)
        if presenterID != id { presenterID = id }
    }

    /// A pane left its window: it no longer holds the web views, and the previous window's pane (if any)
    /// takes them back instead of showing "open in another window" forever.
    func releasePresenter(_ id: ObjectIdentifier) {
        presenterOrder.removeAll { $0 == id }
        if presenterID == id { presenterID = presenterOrder.last }
    }

    /// Closes without asking. Moves focus to the neighbouring tab.
    func close(_ tab: ReviewTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        tab.controller?.teardown()
        tab.controller = nil
        if activeID == tab.id {
            activeID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            activeTab?.lastFocused = Date()
        }
        persist()
        focusRequests.send()
    }

    func closeOthers(than keep: ReviewTab) {
        for tab in tabs where tab.id != keep.id { close(tab) }
        focus(keep)
    }

    // MARK: Pin (PR change)

    /// Follows the focus's pin. The first value seen is not a change; a change to nil closes nothing.
    func follow(pins: AnyPublisher<ReviewPR?, Never>) {
        pinCancellable = pins.receive(on: DispatchQueue.main).sink { [weak self] pin in
            guard let self else { return }
            Task { @MainActor in await self.pinChanged(to: pin) }
        }
    }

    /// A PR change closes every tab not belonging to the new PR, except tabs with unsent text, which
    /// stay and get the mark.
    @MainActor
    func pinChanged(to pin: ReviewPR?) async {
        let previous = lastNonNilPin
        currentPin = pin
        guard let pin else { sortTabs(); return }
        lastNonNilPin = pin
        sortTabs()
        guard let previous, previous != pin else { return }
        for tab in tabs where tab.pr != pin {
            let unsent = await unsentCheck(tab)
            // The pin moved on while the probe ran: a newer change owns the tabs now (A -> B -> C must not
            // let B's task close C's new tabs).
            guard currentPin == pin else { return }
            if unsent { tab.unsent = true } else { close(tab) }
        }
    }

    // MARK: Cap

    /// Closes the least recently focused tab that is not active and not unsent while over the cap.
    /// If none qualifies the pane keeps showing more than the cap until one can go.
    @MainActor
    func enforceCap() async {
        while tabs.count > Self.tabCap {
            let candidates = tabs.filter { $0.id != activeID }.sorted { $0.lastFocused < $1.lastFocused }
            var evicted = false
            for tab in candidates {
                if await unsentCheck(tab) { tab.unsent = true; continue }
                close(tab)
                evicted = true
                break
            }
            if !evicted { return }
        }
    }

    // MARK: Helpers

    /// The default start page; `about:blank` (which the pane never loads) for a malformed repo.
    static func defaultURL(pr: ReviewPR, target: ReviewTarget) -> URL {
        let url: URL?
        switch target {
        case .conversation, .ticket, .page: url = pr.conversationURL
        case .diff: url = pr.diffURL
        }
        return url ?? URL(string: "about:blank") ?? URL(fileURLWithPath: "/")
    }

    private func insert(_ tab: ReviewTab) {
        tabs.append(tab)
        sortTabs()
        activeID = tab.id
        tab.lastFocused = Date()
        persist()
    }

    /// Content order: the PR under review first, then other PRs by (repo, number); within a PR:
    /// conversation, diff, tickets in the order given, pages in open order.
    private func sortTabs() {
        let pin = currentPin
        let sorted = tabs.sorted { a, b in
            let aPinned = a.pr == pin, bPinned = b.pr == pin
            if aPinned != bPinned { return aPinned }
            if a.pr != b.pr { return a.pr < b.pr }
            if a.target.rank != b.target.rank { return a.target.rank < b.target.rank }
            switch (a.target, b.target) {
            case (.ticket, .ticket): return a.ticketOrder < b.ticketOrder
            case (.page(let x), .page(let y)): return x < y
            default: return false
            }
        }
        if sorted.map(\.id) != tabs.map(\.id) { tabs = sorted }
    }

    /// Persists width and tabs. A restored model never creates web views, so this reads URLs only.
    func persist() {
        guard let store else { return }
        // A popup that began as about:blank has nothing to restore.
        let persisted = tabs.filter { $0.startURL.scheme != "about" }
        store.save(tag: tag, ReviewPaneStore.Saved(
            widthFraction: widthFraction,
            tabs: persisted.map { ReviewPaneStore.SavedTab(tab: $0, jiraSite: store.jiraSite()) },
            activeIndex: persisted.firstIndex { $0.id == activeID }))
    }
}

/// One `ReviewPaneModel` per focus tag, shared by every window.
final class ReviewPaneRegistry {
    static let shared = ReviewPaneRegistry(store: ReviewPaneStore())

    private var models: [String: ReviewPaneModel] = [:]
    private let store: ReviewPaneStore

    init(store: ReviewPaneStore) { self.store = store }

    func model(for tag: String) -> ReviewPaneModel {
        if let m = models[tag] { return m }
        let m = ReviewPaneModel(tag: tag, store: store)
        models[tag] = m
        return m
    }

    /// Drops a removed focus's model and saved state.
    func remove(tag: String) {
        models[tag]?.tabs.forEach { $0.controller?.teardown() }
        models[tag] = nil
        store.remove(tag: tag)
    }
}
